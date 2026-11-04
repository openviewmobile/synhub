// 相册模块 "wave3" 新增界面文案（照片 EXIF / 相册缓存状态与大小 / 相册列表显示偏好）：
// **key + 中文原文**。
//
// 与 `photo_p0_text.dart` / `photo_p1_text.dart` / `photo_c2_text.dart` /
// `photo_wave1_text.dart` / `photo_wave2_text.dart` 同一套约定：`.arb` 与
// `lib/l10n/gen/**` 在本批次**禁碰**，新文案走数据层的 `data_text.dart`
// （key + 中文原文；装了翻译器就出译文，否则回落中文）。每一条的 key 就是要
// 追加的 ARB key，清单见 `docs/photo-gaps-wave3.md` §5。
//
// 复用原则：能复用既有 key 的一律复用 —— "部分内容取不到"复用 wave2 的
// `photoWave2PartialUnavailable`，重试按钮复用 `photoRetry`。
import '../../core/i18n/data_text.dart';

/// 取 wave3 新文案（key 见 [PhotoWave3TextKeys]）
String photoWave3(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{size}` …）
String photoWave3Fill(String key, String zh, Map<String, String> values) {
  var out = photoWave3(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class PhotoWave3TextKeys {
  // ---- 照片 EXIF（`Browse.Item/get_exif` v1 + `id`）
  static const exifTitle = 'photoWave3ExifTitle';
  static const exifCamera = 'photoWave3ExifCamera';
  static const exifAperture = 'photoWave3ExifAperture';
  static const exifExposureTime = 'photoWave3ExifExposureTime';
  static const exifFocalLength = 'photoWave3ExifFocalLength';
  static const exifIso = 'photoWave3ExifIso';
  static const exifLens = 'photoWave3ExifLens';
  static const exifEmpty = 'photoWave3ExifEmpty';
  static const exifFailed = 'photoWave3ExifFailed';

  // ---- 相册设置入口（缓存 + 列表显示偏好）
  static const albumSettings = 'photoWave3AlbumSettings';

  // ---- P53 客户端本地缓存（容量上限 / 清理）
  static const cacheLimit = 'photoWave3CacheLimit';
  static const cacheLocalReading = 'photoWave3CacheLocalReading';
  static const cacheClear = 'photoWave3CacheClear';
  static const cacheClearDesc = 'photoWave3CacheClearDesc';
  static const cacheCleared = 'photoWave3CacheCleared';

  // ---- 相册缓存（`Download/get_cache_status|calculate_cache_size` v2，只读）
  static const cache = 'photoWave3Cache';
  static const cacheStatus = 'photoWave3CacheStatus';
  static const cacheStatusDone = 'photoWave3CacheStatusDone';
  static const cacheStatusProcessing = 'photoWave3CacheStatusProcessing';
  static const cacheStatusUnknown = 'photoWave3CacheStatusUnknown';
  static const cacheSize = 'photoWave3CacheSize';
  static const cacheSizeValue = 'photoWave3CacheSizeValue';
  static const cacheSizeUnavailable = 'photoWave3CacheSizeUnavailable';
  static const cacheReadOnly = 'photoWave3CacheReadOnly';

  // ---- 相册列表显示偏好（`Browse.Album/get_album_list_display` v3，只读）
  static const albumListDisplay = 'photoWave3AlbumListDisplay';
  static const albumDisplayAll = 'photoWave3AlbumDisplayAll';
  static const albumDisplayMine = 'photoWave3AlbumDisplayMine';
  static const albumDisplayUnknown = 'photoWave3AlbumDisplayUnknown';

  /// 通用"重新读取"（各只读小节用；与既有"重试"区分：这里是用户主动刷新）
  static const refresh = 'photoWave3Refresh';
}
