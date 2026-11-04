// 文件缩略图的缓存管线（P0.1）。
//
// 缩略图有三个和普通图片不一样的地方，所以单独做一层而不是直接用
// `Image.network`：
//   1. **量大**：一屏 20 个文件就是 20 个请求，滚动起来能上千；
//      必须限流（`maxConcurrent`）、必须去重（同一个 path 别并发请求两次）。
//   2. **会失效**：文件改名/覆盖/重新上传后缩略图必须换 —— 所以缓存键里
//      带 `mtime + size`（见 [thumbKey]），而不是只看路径。
//   3. **会失败**：太小的图、没有权限的文件、服务端没装缩略图依赖都会失败
//      （实测：文件不存在时 Thumb 回 404、Download 回 502，正文是 HTML）。
//      失败要记住（负缓存，别在滚动时反复撞），但不能写进磁盘缓存。
//
// 内存用 LRU + 字节上限；磁盘放 `<缓存目录>/file_thumbs/<hash>`，
// 命中磁盘时刷新 mtime，清理由设置页的「清空缓存」统一做。
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'media_key_hash.dart';

/// 真正去取缩略图的函数（`FileStationApi.thumbnailUrl` + `api.getBytes`）
typedef ThumbLoader = Future<Uint8List> Function(String path, String size);

/// 缓存键：路径 + 大小档 + 修改时间 + 文件大小。
///
/// 带 mtime/size 是为了**自动失效**：同名文件被覆盖后（mtime 变）或
/// 内容变了（size 变）就会走一个新的键，老图自然被淘汰。
String thumbKey(String path, {String size = 'small', int? mtime, int? bytes}) {
  final b = bytes == null ? '' : ':$bytes';
  final m = mtime == null ? '' : ':$mtime';
  return '$size|$path$m$b';
}

/// 缩略图缓存的命中情况（调试面板与测试用）
class ThumbStats {
  int hits = 0;

  /// 网络/磁盘都没命中，真去要了
  int misses = 0;

  /// 拿到图了
  int loaded = 0;

  /// 失败（含负缓存命中）
  int failures = 0;

  /// 被"同一个键正在请求中"合并掉的次数
  int deduped = 0;

  int get total => hits + misses;

  double get hitRate => total == 0 ? 0 : hits / total;

  @override
  String toString() =>
      'ThumbStats(命中 $hits/$total, 取回 $loaded, '
      '失败 $failures, 合并 $deduped)';
}

/// 带限流 + LRU + 负缓存的缩略图缓存
class ThumbCache {
  ThumbCache({
    required this.loader,
    Future<Directory?> Function()? directory,
    this.memoryBytes = 16 << 20,
    this.maxConcurrent = 4,
    this.negativeTtl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _directory = directory,
       _now = now ?? DateTime.now;

  final ThumbLoader loader;

  /// 磁盘缓存目录（返回 null 表示只用内存，测试/无缓存目录的场合）
  final Future<Directory?> Function()? _directory;

  /// 内存上限（字节）；超出后按 LRU 淘汰。0 = 不缓存到内存
  final int memoryBytes;

  /// 同时在飞的请求数上限
  final int maxConcurrent;

  /// 失败后多久内不再重试
  final Duration negativeTtl;

  final DateTime Function() _now;

  final ThumbStats stats = ThumbStats();

  /// LRU：`LinkedHashMap` 的插入顺序就是"最近使用"顺序
  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();
  int _memoryUsed = 0;

  /// 正在请求中的键（同一张图被列表重复要时合并成一个请求）
  final Map<String, Future<Uint8List?>> _inflight = {};

  /// 负缓存：键 → 失败时间
  final Map<String, DateTime> _failed = {};

  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue();

  int get memoryUsed => _memoryUsed;
  int get memoryCount => _memory.length;

  bool get isMemoryEmpty => _memory.isEmpty;

  /// 取一张缩略图；失败返回 null（调用方展示占位图标即可）。
  ///
  /// [key] 用 [thumbKey] 生成；[path]/[size] 交给 [loader]。
  Future<Uint8List?> get(String key, String path, {String size = 'small'}) {
    // ① 内存
    final cached = _memory.remove(key);
    if (cached != null) {
      _memory[key] = cached; // 重新插到队尾 = 标记为最近使用
      stats.hits++;
      return Future.value(cached);
    }
    // ② 负缓存（刚失败过，别在滚动时反复撞）
    final failedAt = _failed[key];
    if (failedAt != null) {
      if (_now().difference(failedAt) < negativeTtl) {
        stats.failures++;
        return Future.value(null);
      }
      _failed.remove(key);
    }
    // ③ 同一个键正在请求 → 合并
    final running = _inflight[key];
    if (running != null) {
      stats.deduped++;
      return running;
    }
    stats.misses++;
    final future = _load(key, path, size);
    _inflight[key] = future;
    return future.whenComplete(() => _inflight.remove(key));
  }

  Future<Uint8List?> _load(String key, String path, String size) async {
    // ④ 磁盘
    final fromDisk = await _readDisk(key);
    if (fromDisk != null) {
      stats.hits++;
      stats.misses--; // 磁盘命中不算 miss
      _putMemory(key, fromDisk);
      return fromDisk;
    }
    // ⑤ 真的去取
    await _acquire();
    try {
      final bytes = await loader(path, size);
      if (bytes.isEmpty) {
        _failed[key] = _now();
        stats.failures++;
        return null;
      }
      stats.loaded++;
      _putMemory(key, bytes);
      unawaited(_writeDisk(key, bytes));
      return bytes;
    } catch (_) {
      // 失败不落盘、不留内存，但记一下负缓存
      _failed[key] = _now();
      stats.failures++;
      return null;
    } finally {
      _release();
    }
  }

  // ------------------------------------------------------------ 内存 LRU

  void _putMemory(String key, Uint8List bytes) {
    if (memoryBytes <= 0 || bytes.length > memoryBytes) return;
    final old = _memory.remove(key);
    if (old != null) _memoryUsed -= old.length;
    _memory[key] = bytes;
    _memoryUsed += bytes.length;
    while (_memoryUsed > memoryBytes && _memory.isNotEmpty) {
      final victim = _memory.keys.first;
      final removed = _memory.remove(victim);
      _memoryUsed -= removed?.length ?? 0;
    }
  }

  /// 清内存（退到后台/内存告急时可以叫）
  void clearMemory() {
    _memory.clear();
    _memoryUsed = 0;
  }

  /// 忘掉所有失败记录（下拉刷新时叫，让失败的文件再试一次）
  void clearFailures() => _failed.clear();

  // ------------------------------------------------------------ 磁盘

  Future<Directory?> _ensureDir() async {
    final dir = await _directory?.call();
    if (dir == null) return null;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Uint8List?> _readDisk(String key) async {
    try {
      final dir = await _ensureDir();
      if (dir == null) return null;
      final file = File('${dir.path}/${_fileName(key)}');
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      // 刷新 mtime：设置页按"最久未用"清理磁盘缓存
      unawaited(file.setLastModified(_now()));
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null; // 缓存读失败永远不该影响功能
    }
  }

  Future<void> _writeDisk(String key, Uint8List bytes) async {
    try {
      final dir = await _ensureDir();
      if (dir == null) return;
      await File(
        '${dir.path}/${_fileName(key)}',
      ).writeAsBytes(bytes, flush: false);
    } catch (_) {
      // 忽略：磁盘满了/没权限都不该让缩略图瘸掉
    }
  }

  /// 清磁盘缓存，返回删掉的字节数
  Future<int> clearDisk() async {
    var freed = 0;
    try {
      final dir = await _ensureDir();
      if (dir == null) return 0;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        freed += await e.length();
        await e.delete();
      }
    } catch (_) {
      // 忽略
    }
    return freed;
  }

  /// 文件名：FNV-1a 64bit 的十六进制 + 长度（避免不同键撞名）
  ///
  /// ★ 第 335 轮：哈希搬到 [fnv1a64Hex]（**唯一实现**，且 64 位语义在 JS 上也精确）
  /// —— 原来这里与 `video_frame_thumb.dart` 各写一份，且用 64 位字面量让
  /// `flutter build web` 编不过。输出与原实现逐字节相同。
  static String _fileName(String key) =>
      '${fnv1a64Hex(key)}_${key.length}.thumb';

  // ------------------------------------------------------------ 并发限流

  Future<void> _acquire() async {
    if (_running < maxConcurrent) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      // 直接把名额让给排队的人，不先减再加（避免"醒来又发现没位置"）
      _waiting.removeFirst().complete();
      return;
    }
    _running--;
  }
}
