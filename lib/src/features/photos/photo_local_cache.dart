// ⑦相册 **P53 客户端图片/缩略图缓存**（容量上限 + 清理）。
//
// **取证（为什么这是"客户端"而不是 NAS 的事）** ——
// 官方安卓 APK（`Android-SynologyPhotos.2.4.0-644.ww.apk`，apktool）里：
//   * `PreferenceManager.CACHE_LIMIT = "cache_limit"`
//   * `R$array.cache_limit` / `cache_limit_value` / `R$integer.default_cache_limit_index`
//   * `R$layout.pref_clear_cache` / `R$id.clear_cache` / `R$drawable.bg_clear_cache_button`
//   * `R$string.str_cache_limit` / `str_clear_cache` / `str_clear_cache_alert_desc`
// ⇒ 官方有**本地缓存上限选择**与**清空缓存按钮**（还带二次确认说明文案）。
// 这是**纯客户端**行为：只动 App 自己的缓存目录，**不碰任何 NAS 接口**
// （NAS 侧的 `Download/get_cache_status|calculate_cache_size` 是另一回事，
//  只读展示，见 `photo_wave3_page.dart`；`Download/clear_cache` 是 NAS 侧写操作，
//  本模块**不涉及**，仍在待取证清单里）。
//
// 行为：容量上限用 **LRU（按最后修改时间）** 收敛 —— 超限就把最旧的文件删掉，
// 直到降到上限内。`0` = 不限制（官方 `dev_mode_cache_limit` 同款语义）。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/i18n/data_text.dart';

import 'photo_prefs_store.dart';

/// 本地上限可选项（字节）。`0` = 不限制。
const List<int> kPhotoLocalCacheLimitOptions = [
  0,
  200 * 1024 * 1024,
  500 * 1024 * 1024,
  1024 * 1024 * 1024,
];

/// 落盘 key（改字符串会让用户旧选择读不回来）。
const String kPhotoLocalCacheLimitSlot = 'photo_cache_limit_bytes_v1';

/// 默认上限：**500MB**（对应官方 `default_cache_limit_index` 的"中间档"语义）。
const int kPhotoLocalCacheDefaultLimit = 500 * 1024 * 1024;

/// 人读的档位名（UI 用；纯函数便于单测）。
String photoCacheLimitLabel(int bytes) {
  if (bytes <= 0) return dataText('cacheUnlimited', '不限制');
  if (bytes % (1024 * 1024 * 1024) == 0) {
    return '${bytes ~/ (1024 * 1024 * 1024)} GB';
  }
  return '${bytes ~/ (1024 * 1024)} MB';
}

/// 本地缓存的一次快照。
class PhotoLocalCacheStats {
  const PhotoLocalCacheStats({required this.bytes, required this.fileCount});

  final int bytes;
  final int fileCount;

  bool get isEmpty => fileCount == 0;

  @override
  String toString() => 'PhotoLocalCacheStats($fileCount files, $bytes bytes)';
}

/// App 自己的图片/缩略图缓存目录管理器。
///
/// 只依赖 [Directory] ⇒ **纯 Dart 可测**（临时目录里造真文件）。
class PhotoLocalCache {
  PhotoLocalCache({required this.root});

  /// 缓存根目录（不存在时按 0 处理，不创建、不抛）。
  final Directory root;

  /// 递归列出缓存文件；目录不存在回空表。
  Future<List<File>> files() async {
    if (!await root.exists()) return const [];
    final out = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) out.add(entity);
    }
    return out;
  }

  /// 当前占用（字节）与文件数。
  Future<PhotoLocalCacheStats> stats() async {
    final list = await files();
    var bytes = 0;
    for (final f in list) {
      try {
        bytes += await f.length();
      } catch (_) {
        // 单个文件读不到（被别的进程删了）→ 跳过，别让整次统计失败
      }
    }
    return PhotoLocalCacheStats(bytes: bytes, fileCount: list.length);
  }

  /// 清空缓存：删掉所有缓存**文件**（保留目录本身）。返回释放的字节数。
  Future<int> clear() async {
    final list = await files();
    var freed = 0;
    for (final f in list) {
      try {
        freed += await f.length();
        await f.delete();
      } catch (_) {
        // 删不掉的（占用中）跳过：宁可少释放，不许抛给 UI
      }
    }
    return freed;
  }

  /// 按上限收敛（**LRU**：最旧的先删）。返回释放的字节数。
  ///
  /// [maxBytes] <= 0 ⇒ 不限制，一个都不删（直接回 0）。
  Future<int> enforceLimit(int maxBytes) async {
    if (maxBytes <= 0) return 0;
    final list = await files();
    final sized = <(File, int, DateTime)>[];
    var total = 0;
    for (final f in list) {
      try {
        final len = await f.length();
        final ts = await f.lastModified();
        sized.add((f, len, ts));
        total += len;
      } catch (_) {}
    }
    if (total <= maxBytes) return 0;
    sized.sort((a, b) => a.$3.compareTo(b.$3)); // 最旧在前
    var freed = 0;
    for (final entry in sized) {
      if (total - freed <= maxBytes) break;
      try {
        await entry.$1.delete();
        freed += entry.$2;
      } catch (_) {}
    }
    return freed;
  }
}

// ---------------------------------------------------------------- 接线

/// 缓存根目录：App 缓存目录下的 `photo_cache/`（**只放相册自己的缓存**，
/// 不与别的模块共用根目录，清理时才不会误伤）。
final photoLocalCacheProvider = FutureProvider<PhotoLocalCache>((ref) async {
  final dir = await getTemporaryDirectory();
  return PhotoLocalCache(root: Directory('${dir.path}/photo_cache'));
});

/// 用户选的容量上限（字节；`0` = 不限制）。默认 [kPhotoLocalCacheDefaultLimit]。
class PhotoLocalCacheLimitNotifier extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    final raw = await ref.read(photoPrefsStoreProvider).read(
      kPhotoLocalCacheLimitSlot,
    );
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null || parsed < 0) return kPhotoLocalCacheDefaultLimit;
    // 只认已知档位：脏数据（手改/旧版本）就回默认，别把上限设成 1 字节
    return kPhotoLocalCacheLimitOptions.contains(parsed)
        ? parsed
        : kPhotoLocalCacheDefaultLimit;
  }

  Future<void> set(int bytes) async {
    state = AsyncData(bytes);
    await ref.read(photoPrefsStoreProvider).write(
      kPhotoLocalCacheLimitSlot,
      '$bytes',
    );
    // 立刻按新上限收敛（选小了就该马上见效，不是等下次启动）
    final cache = await ref.read(photoLocalCacheProvider.future);
    await cache.enforceLimit(bytes);
    ref.invalidate(photoLocalCacheStatsProvider);
  }
}

final photoLocalCacheLimitProvider =
    AsyncNotifierProvider<PhotoLocalCacheLimitNotifier, int>(
      PhotoLocalCacheLimitNotifier.new,
    );

/// 本机缓存占用（字节/文件数）。
final photoLocalCacheStatsProvider = FutureProvider<PhotoLocalCacheStats>((
  ref,
) async {
  final cache = await ref.watch(photoLocalCacheProvider.future);
  return cache.stats();
});

/// 清理动作（清空 + 重算占用）。
class PhotoLocalCacheActions {
  PhotoLocalCacheActions(this.ref);

  final Ref ref;

  /// 清空缓存，返回释放的字节数。
  Future<int> clear() async {
    final cache = await ref.read(photoLocalCacheProvider.future);
    final freed = await cache.clear();
    ref.invalidate(photoLocalCacheStatsProvider);
    return freed;
  }
}

final photoLocalCacheActionsProvider = Provider<PhotoLocalCacheActions>(
  PhotoLocalCacheActions.new,
);
