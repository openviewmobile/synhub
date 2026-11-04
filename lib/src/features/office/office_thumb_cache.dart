// Office 文档**自渲染缩略图**的缓存：内存 LRU + 磁盘 + **失败记忆**。
//
// ## 为什么需要它（与 `office_template_thumbs.dart` 的关系）
//
// 模板缩略图是**服务端给的 PNG 字节**（`SYNO.Office.Template.Thumb:get`），缓存只是
// 省一次请求；文档缩略图是**我们自己渲染**出来的（`office_doc_thumb.dart`：
// 首页 widget → `RepaintBoundary.toImage()` → PNG），**渲染是重活**（要解析模型、
// 构建 widget、光栅化）。所以这一层的职责比模板缩略图更重：
//
//   * 内存 LRU：滚动列表时同一张图反复进出视口**不能重渲染**（`memoryHits` 计数）；
//   * 磁盘：进程重启后仍然命中（key 里含 mtime/version，改过的文档自然换 key）；
//   * **失败记忆**：渲染失败/超时的 key 要记下来 —— 用户快速滚动时同一个坏文档
//     会被 build 很多次，不记住就会反复触发重渲染（既卡又永远失败）；
//   * 并发去重：同一 key 同时被两个列表项请求时只渲染一次。
//
// ## 与模板缩略图缓存一致的两条约定
//
//   * 磁盘目录用 `path_provider`；**单测没有该通道时自动降级成"只用内存"**
//     （不打扰用户，也不让单测去 mock 平台通道）；
//   * 失败记忆有上限（`failureCapacity`），否则长会话里坏 key 会无限增长。
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 缩略图缓存 key 的构成（`file_id/path` + `mtime/version` + `size` 档位）。
///
/// ★ **必须含"版本戳"**（`mtime` / `version` / 内容哈希）：只按路径缓存的话，
/// 用户覆盖同名文档后列表里会一直显示**旧图**（详见 `office_doc_thumb_test.dart`
/// 的反向验证用例）。
String officeThumbCacheKey({
  required String sourceKey,
  required String versionStamp,
  required String sizeTier,
}) => '$sourceKey|$versionStamp|$sizeTier';

/// Office 缩略图缓存：内存 LRU（[memoryCapacity] 张）+ 磁盘 + 失败记忆。
class OfficeThumbCache {
  OfficeThumbCache({
    this.memoryCapacity = 48,
    this.failureCapacity = 128,
    Future<Directory?> Function()? diskRoot,
  }) : _diskRoot = diskRoot;

  /// 进程内共享实例（父层也可以自建一个并用 provider 注入）。
  static OfficeThumbCache? shared;

  /// 默认共享实例（懒创建）。
  static OfficeThumbCache get instance => shared ??= OfficeThumbCache();

  /// 内存里最多缓存几张（LRU 淘汰最久未用的）。
  final int memoryCapacity;

  /// 失败记忆最多记多少条（LRU 淘汰）。
  final int failureCapacity;

  /// 磁盘根目录解析器；null = 用 `path_provider` 的临时目录。
  final Future<Directory?> Function()? _diskRoot;

  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  final LinkedHashMap<String, Object> _failed = LinkedHashMap<String, Object>();

  /// 失败记忆的**时间戳**与**有效期**（`ttl == Duration.zero` = 永久，直到进程结束）。
  ///
  /// 为什么要有效期：真机实测（第 261 轮）列表里 8 个 office 文档同时出图，
  /// 每个任务要跑 **两跳 NAS 往返 + 解析 + 光栅化**，1.8s 预算下**超时**很常见。
  /// 超时是**暂时**的，如果按"永久失败"记下来，这一行在本进程内就永远出不了图
  /// （用户看到的正是"office 行全是图标，等一分钟也不出"）。
  final Map<String, DateTime> _failedAt = <String, DateTime>{};
  final Map<String, Duration> _failedTtl = <String, Duration>{};
  final Map<String, Future<Uint8List?>> _inflight = {};

  /// 平台通道拿不到临时目录（单测/桌面）⇒ 只用内存，且只探测一次。
  bool _diskUnavailable = false;

  Future<void>? _lastDiskWrite;

  /// 命中计数（单测用来断言"缓存命中 ⇒ 不重渲染"）。
  int memoryHits = 0;
  int diskHits = 0;
  int failureHits = 0;
  int diskWrites = 0;

  /// 当前内存里的 key（按 LRU 顺序，最久未用在前）。
  Iterable<String> get memoryKeys => _memory.keys;

  /// 已被记住失败的 key。
  Iterable<String> get failedKeys => _failed.keys;

  /// 内存命中（并把该 key 移到 LRU 末尾）。
  Uint8List? memoryGet(String key) {
    final hit = _memory.remove(key);
    if (hit == null) return null;
    _memory[key] = hit;
    memoryHits++;
    return hit;
  }

  /// 是否已被记住失败（**过期即视为没失败**，让下一次重建重试）。
  bool hasFailed(String key) {
    if (!_failed.containsKey(key)) return false;
    final ttl = _failedTtl[key];
    if (ttl == null || ttl <= Duration.zero) return true;
    final at = _failedAt[key];
    if (at == null) return true;
    if (DateTime.now().difference(at) >= ttl) {
      _forgetFailure(key);
      return false;
    }
    return true;
  }

  /// 抹掉一条失败记忆（三个表一起，避免只删一个留下幽灵）。
  void _forgetFailure(String key) {
    _failed.remove(key);
    _failedAt.remove(key);
    _failedTtl.remove(key);
  }

  /// 记住的原因（错误对象；只有 [hasFailed] 为真时有意义）。
  Object? failureReason(String key) => _failed[key];

  /// 记住一次失败（再次请求该 key 时**直接放弃，不再重渲染**）。
  ///
  /// [ttl] 默认 `Duration.zero` = 永久（渲染器明确报了错，重试无意义）；
  /// **超时**这类"可能只是这次慢"的失败请传一个正数（见 [kOfficeThumbTimeoutRetry]）。
  void markFailed(String key, Object error, {Duration ttl = Duration.zero}) {
    _forgetFailure(key);
    _failed[key] = error;
    _failedAt[key] = DateTime.now();
    _failedTtl[key] = ttl;
    while (_failed.length > failureCapacity) {
      _forgetFailure(_failed.keys.first);
    }
  }

  /// 主动作废某个 key（内存 + 磁盘 + 失败记忆）。用户改完文档后可调用。
  Future<void> invalidate(String key) async {
    _memory.remove(key);
    _forgetFailure(key);
    _inflight.remove(key);
    final file = await _diskFile(key);
    if (file != null && file.existsSync()) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // 磁盘删不掉不影响正确性（下次 put 会覆盖）。
      }
    }
  }

  /// 清空（内存 + 失败记忆；磁盘尽量清）。
  Future<void> clear() async {
    _memory.clear();
    _failed.clear();
    _failedAt.clear();
    _failedTtl.clear();
    _inflight.clear();
    final dir = await _diskDirectory();
    if (dir != null && dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 同上：清不掉就留着，key 变了自然会失效。
      }
    }
  }

  /// 同一 key 的并发去重：没有在飞的 future 时用 [task] 建一个。
  ///
  /// ★ 踩过的坑（单测当场抓住，不是理论风险）：**不能**写成
  /// `task().whenComplete(() => _inflight.remove(key))` ——
  /// `Map<String, Future<...>>.remove` 返回的正是**那个 future 本身**，
  /// 而 `whenComplete` 的回调一旦返回 Future 就会**等它完成**，
  /// 于是变成"自己等自己" ⇒ 该 future **永不完成**（调用方全部挂死）。
  /// 回调必须写成块体（返回 `void`），并且**原样返回 [task] 自己的 future**。
  Future<Uint8List?> inflight(String key, Future<Uint8List?> Function() task) {
    final running = _inflight[key];
    if (running != null) return running;
    final future = task();
    _inflight[key] = future;
    unawaited(
      future.whenComplete(() {
        _inflight.remove(key);
      }),
    );
    return future;
  }

  /// 写入（内存 + 磁盘）。
  ///
  /// **内存写完就算成功**：磁盘那一步是 `unawaited` 的 —— 缩略图必须立刻能显示，
  /// 不能因为磁盘慢/平台通道卡住而拖住 UI（本轮实测：测试环境下
  /// `getTemporaryDirectory()` 拿不到结果，`await` 它会让图片永远不出现）。
  /// 磁盘写失败**不算错误**（下次进程重启后重渲染而已）。
  Future<void> put(String key, Uint8List bytes) async {
    _remember(key, bytes);
    final write = _writeDisk(key, bytes);
    _lastDiskWrite = write;
    unawaited(write);
  }

  /// 等最后一次磁盘写入落盘（单测/退出前用；生产路径**不需要**等）。
  Future<void> flushDisk() async {
    final pending = _lastDiskWrite;
    if (pending != null) await pending;
  }

  Future<void> _writeDisk(String key, Uint8List bytes) async {
    final file = await _diskFile(key);
    if (file == null) return;
    try {
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes, flush: false);
      diskWrites++;
    } on FileSystemException {
      // 忽略：内存已经命中。
    }
  }

  void _remember(String key, Uint8List bytes) {
    _failed.remove(key);
    _memory.remove(key);
    _memory[key] = bytes;
    while (_memory.length > memoryCapacity) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// 磁盘命中（没有磁盘目录时返回 null）。
  Future<Uint8List?> diskGet(String key) async {
    final file = await _diskFile(key);
    if (file == null || !file.existsSync()) return null;
    try {
      final bytes = file.readAsBytesSync();
      if (bytes.isEmpty) return null;
      diskHits++;
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  Future<Directory?> _diskDirectory() async {
    final custom = _diskRoot;
    if (custom != null) return custom();
    // 只探测一次：平台通道不可用时（单测/桌面）后面的调用直接走内存，
    // 不再每次 `await` 一个不会回来的平台调用。
    if (_diskUnavailable) return null;
    try {
      final temp = await getTemporaryDirectory();
      final dir = Directory('${temp.path}/office_thumbs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } on Object {
      // 单测环境没有 path_provider 平台通道 ⇒ 降级成"只用内存"。
      _diskUnavailable = true;
      return null;
    }
  }

  Future<File?> _diskFile(String key) async {
    final dir = await _diskDirectory();
    if (dir == null) return null;
    final name = base64Url
        .encode(utf8.encode(key))
        .replaceAll('=', '');
    return File('${dir.path}/$name.png');
  }
}
