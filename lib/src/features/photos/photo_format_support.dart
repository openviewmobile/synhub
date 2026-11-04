// 相册**格式支持**判定：HEIC/HEIF、RAW/DNG、AVIF（P15 / P16）。
//
// 官方证据（`photo-parity-audit.md:132-133`）：
//   * HEIC/HEIF：官方**不自己解码**，靠服务端 Image Assistant / AME 生成 JPEG
//     预览；拿不到时给"生成预览"引导（`str_ame_defect_alert_title` /
//     `str_auto_generate_thumbnail_desc` / `str_ame_need_to_reindex_*`）；
//   * RAW / ProRAW / DNG / AVIF：官方**没有任何用户字符串**（不承诺），只有
//     Image Assistant 的兜底文案 `str_ame_unsupported_format_message`。
//
// 所以本文件做两件事：
//   1. 按扩展名分类：需要服务端预览（HEIC/HEIF）/ 不承诺显示（RAW 家族 + AVIF）；
//   2. 给出该显示哪一条兜底文案的 key。
//
// 判定只看**扩展名**：不看魔术字节（`foto_api.dart` 里的 `looksLikeImage` 负责
// 更硬的"这是不是图片"判断），因为这里回答的是"该给用户哪句解释"。
//
// ⚠️ 本文件属 **UI 层**（`features/photos/**`）：下面的 [photoG1] 直接读当前语言的
// `AppText`，所以**不能**被 `lib/src/data/**` / `lib/src/dsm/**` 引用，也不能被
// 纯 Dart 探针（`tool/*.dart`）加载 —— 那些地方只认 `dataText(key, 中文原文)`。
library;

import '../../../l10n/gen/app_localizations.dart' show AppText;
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart' show currentText;

/// 需要 NAS 先生成 JPEG 预览的格式（HEIC / HEIF）。
const Set<String> kPhotoServerPreviewExtensions = <String>{'heic', 'heif'};

/// RAW 家族（含 Apple ProRAW 的 `.dng`）。
///
/// 官方对 RAW **不承诺**显示，这里只用来给兜底文案 —— 不是"我们支持"。
const Set<String> kPhotoRawExtensions = <String>{
  'dng',
  'arw',
  'srf',
  'sr2',
  'cr2',
  'cr3',
  'crw',
  'nef',
  'nrw',
  'raf',
  'orf',
  'rw2',
  'raw',
  'pef',
  'srw',
  'x3f',
  '3fr',
  'fff',
  'mrw',
  'erf',
  'kdc',
  'dcr',
  'rwl',
};

/// AVIF（新一代容器；官方同样无用户字符串）。
const Set<String> kPhotoAvifExtensions = <String>{'avif', 'avifs'};

/// 应用内**本来就能显示**的常见格式（图片 + 视频）。
///
/// 这些扩展名不触发"格式不支持"兜底 —— 它们取不到图只可能是网络/会话/文件本身
/// 的问题，乱扣"格式不支持"的帽子会把用户带偏。
const Set<String> kPhotoDisplayableExtensions = <String>{
  'jpg',
  'jpeg',
  'jpe',
  'png',
  'gif',
  'webp',
  'bmp',
  'tif',
  'tiff',
  'btf',
  'mp4',
  'm4v',
  'mov',
  'avi',
  'mkv',
  'webm',
  '3gp',
  '3g2',
  'mts',
  'm2ts',
  'ts',
  'mpg',
  'mpeg',
  'wmv',
};

/// 取小写扩展名（无扩展名 / 以点结尾 → 空串）。
String photoFileExtension(String filename) {
  final name = filename.trim();
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// 这个文件是不是"需要服务端预览"的格式（HEIC/HEIF）。
bool photoNeedsServerPreview(String filename) =>
    kPhotoServerPreviewExtensions.contains(photoFileExtension(filename));

/// 这个文件是不是官方**不承诺**机内显示的格式（RAW 家族 / AVIF）。
bool photoFormatNotPromised(String filename) {
  final ext = photoFileExtension(filename);
  return kPhotoRawExtensions.contains(ext) ||
      kPhotoAvifExtensions.contains(ext);
}

/// 该文件对应哪条**兜底文案**（对齐官方 `str_ame_unsupported_format_message`）。
///
/// 返回 `null` = 无兜底文案（普通 JPEG/PNG/视频…）。
String? photoFormatFallbackText(String filename) {
  final ext = photoFileExtension(filename);
  if (kPhotoRawExtensions.contains(ext)) {
    return photoG1(
      PhotoG1TextKeys.formatUnsupportedRaw,
      '这个 RAW/DNG 文件暂时无法在应用内显示',
    );
  }
  if (kPhotoAvifExtensions.contains(ext)) {
    return photoG1(
      PhotoG1TextKeys.formatUnsupportedAvif,
      '这个 AVIF 文件暂时无法在应用内显示',
    );
  }
  if (kPhotoServerPreviewExtensions.contains(ext)) {
    return photoG1(PhotoG1TextKeys.heicPreviewTitle, '这张 HEIC 照片还没有预览');
  }
  // 本来就能显示的常见格式 → **不给"格式不支持"**（取不到图是别的原因）
  if (ext.isEmpty || kPhotoDisplayableExtensions.contains(ext)) return null;
  // 认不出的扩展名：给通用兜底（官方也是"unsupported format"一句）
  return photoG1(
    PhotoG1TextKeys.formatUnsupportedGeneric,
    '这个格式暂时无法在应用内显示，可以下载后用其他应用打开',
  );
}

/// 本批（G1）新增的 ARB key（**append-only**）。
abstract final class PhotoG1TextKeys {
  // ---------------- P4 网格密度
  static const gridDensity = 'photoGridDensity';
  static const gridDensityLarge = 'photoGridDensityLarge';
  static const gridDensityMedium = 'photoGridDensityMedium';
  static const gridDensitySmall = 'photoGridDensitySmall';
  static const gridDensityTiny = 'photoGridDensityTiny';
  static const gridDensityApplied = 'photoGridDensityApplied';

  // ---------------- P15 HEIC 预览引导
  static const heicPreviewTitle = 'photoHeicPreviewTitle';
  static const heicPreviewBody = 'photoHeicPreviewBody';
  static const heicPreviewAction = 'photoHeicPreviewAction';
  static const heicPreviewConfirmTitle = 'photoHeicPreviewConfirmTitle';
  static const heicPreviewConfirmBody = 'photoHeicPreviewConfirmBody';
  static const heicPreviewRequested = 'photoHeicPreviewRequested';
  static const heicPreviewFailed = 'photoHeicPreviewFailed';
  static const heicRegenerating = 'photoHeicRegenerating';

  // ---------------- P16 RAW / AVIF 兜底
  static const formatUnsupportedRaw = 'photoFormatUnsupportedRaw';
  static const formatUnsupportedAvif = 'photoFormatUnsupportedAvif';
  static const formatUnsupportedGeneric = 'photoFormatUnsupportedGeneric';
  static const formatUnsupportedBody = 'photoFormatUnsupportedBody';
  static const formatUnsupportedBadge = 'photoFormatUnsupportedBadge';

  // ---------------- P24 最近搜索
  static const searchHistoryTitle = 'photoSearchHistoryTitle';
  static const searchHistoryClear = 'photoSearchHistoryClear';
  static const searchHistoryCleared = 'photoSearchHistoryCleared';

  // ---------------- P25 全局搜索含照片
  static const globalSearchGroup = 'photoGlobalSearchGroup';
  static const globalSearchFailed = 'photoGlobalSearchFailed';
  static const globalSearchCount = 'photoGlobalSearchCount';

  // ---------------- P29 删除撤销
  static const deleteUndoPending = 'photoDeleteUndoPending';
  static const deleteUndoAction = 'photoDeleteUndoAction';
  static const deleteUndone = 'photoDeleteUndone';

  // ---------------- P48 播放设置
  static const playbackSettings = 'photoPlaybackSettings';
  static const playbackHttp = 'photoPlaybackHttp';
  static const playbackHttpDesc = 'photoPlaybackHttpDesc';
  static const playbackHttpPort = 'photoPlaybackHttpPort';
  static const playbackPortInvalid = 'photoPlaybackPortInvalid';
  static const playbackCert = 'photoPlaybackCert';
  static const playbackCertDesc = 'photoPlaybackCertDesc';

  // ---------------- P49 幻灯片
  static const slideshow = 'photoSlideshow';
  static const slideshowSettings = 'photoSlideshowSettings';
  static const slideshowSpeed = 'photoSlideshowSpeed';
  static const slideshowOrder = 'photoSlideshowOrder';
  static const slideshowShuffle = 'photoSlideshowShuffle';
  static const slideshowSequential = 'photoSlideshowSequential';
  static const slideshowStart = 'photoSlideshowStart';
  static const slideshowStop = 'photoSlideshowStop';
  static const slideshowNoPhotos = 'photoSlideshowNoPhotos';
  static const slideshowSeconds = 'photoSlideshowSeconds';
  static const slideshowInterval = 'photoSlideshowInterval';
  static const slideshowStarted = 'photoSlideshowStarted';
}

/// G1 新文案的 `key → 当前语言译文` 表。
///
/// 为什么不走 `dataTextMap`（`lib/src/core/i18n/l10n.dart`）：那张表是**手工维护**
/// 的，而 G1 的文件白名单不含 `lib/src/core/**`。这里直接在**本批次自己的文件**里
/// 把新 key 接到生成的 `AppText` getter 上：效果一样（英文不再回落成中文），
/// 而且新增 key 的改动只落在 G1 自己的文件里 —— 不会跟并行批次抢同一张表。
Map<String, String> _g1TextTable(AppText t) => {
  for (final e in <String, String>{
    PhotoG1TextKeys.gridDensity: t.photoGridDensity,
    PhotoG1TextKeys.gridDensityLarge: t.photoGridDensityLarge,
    PhotoG1TextKeys.gridDensityMedium: t.photoGridDensityMedium,
    PhotoG1TextKeys.gridDensitySmall: t.photoGridDensitySmall,
    PhotoG1TextKeys.gridDensityTiny: t.photoGridDensityTiny,
    PhotoG1TextKeys.gridDensityApplied: t.photoGridDensityApplied('{label}'),
    PhotoG1TextKeys.heicPreviewTitle: t.photoHeicPreviewTitle,
    PhotoG1TextKeys.heicPreviewBody: t.photoHeicPreviewBody,
    PhotoG1TextKeys.heicPreviewAction: t.photoHeicPreviewAction,
    PhotoG1TextKeys.heicPreviewConfirmTitle: t.photoHeicPreviewConfirmTitle,
    PhotoG1TextKeys.heicPreviewConfirmBody: t.photoHeicPreviewConfirmBody,
    PhotoG1TextKeys.heicPreviewRequested: t.photoHeicPreviewRequested,
    PhotoG1TextKeys.heicPreviewFailed: t.photoHeicPreviewFailed('{reason}'),
    PhotoG1TextKeys.heicRegenerating: t.photoHeicRegenerating('{count}'),
    PhotoG1TextKeys.formatUnsupportedRaw: t.photoFormatUnsupportedRaw,
    PhotoG1TextKeys.formatUnsupportedAvif: t.photoFormatUnsupportedAvif,
    PhotoG1TextKeys.formatUnsupportedGeneric: t.photoFormatUnsupportedGeneric,
    PhotoG1TextKeys.formatUnsupportedBody: t.photoFormatUnsupportedBody,
    PhotoG1TextKeys.formatUnsupportedBadge: t.photoFormatUnsupportedBadge,
    PhotoG1TextKeys.searchHistoryTitle: t.photoSearchHistoryTitle,
    PhotoG1TextKeys.searchHistoryClear: t.photoSearchHistoryClear,
    PhotoG1TextKeys.searchHistoryCleared: t.photoSearchHistoryCleared,
    PhotoG1TextKeys.globalSearchGroup: t.photoGlobalSearchGroup,
    PhotoG1TextKeys.globalSearchFailed: t.photoGlobalSearchFailed('{reason}'),
    PhotoG1TextKeys.globalSearchCount: t.photoGlobalSearchCount('{count}'),
    PhotoG1TextKeys.deleteUndoPending: t.photoDeleteUndoPending(
      '{seconds}',
      '{count}',
    ),
    PhotoG1TextKeys.deleteUndoAction: t.photoDeleteUndoAction,
    PhotoG1TextKeys.deleteUndone: t.photoDeleteUndone,
    PhotoG1TextKeys.playbackSettings: t.photoPlaybackSettings,
    PhotoG1TextKeys.playbackHttp: t.photoPlaybackHttp,
    PhotoG1TextKeys.playbackHttpDesc: t.photoPlaybackHttpDesc,
    PhotoG1TextKeys.playbackHttpPort: t.photoPlaybackHttpPort,
    PhotoG1TextKeys.playbackPortInvalid: t.photoPlaybackPortInvalid,
    PhotoG1TextKeys.playbackCert: t.photoPlaybackCert,
    PhotoG1TextKeys.playbackCertDesc: t.photoPlaybackCertDesc,
    PhotoG1TextKeys.slideshow: t.photoSlideshow,
    PhotoG1TextKeys.slideshowSettings: t.photoSlideshowSettings,
    PhotoG1TextKeys.slideshowSpeed: t.photoSlideshowSpeed,
    PhotoG1TextKeys.slideshowOrder: t.photoSlideshowOrder,
    PhotoG1TextKeys.slideshowShuffle: t.photoSlideshowShuffle,
    PhotoG1TextKeys.slideshowSequential: t.photoSlideshowSequential,
    PhotoG1TextKeys.slideshowStart: t.photoSlideshowStart,
    PhotoG1TextKeys.slideshowStop: t.photoSlideshowStop,
    PhotoG1TextKeys.slideshowNoPhotos: t.photoSlideshowNoPhotos,
    PhotoG1TextKeys.slideshowSeconds: t.photoSlideshowSeconds('{seconds}'),
    PhotoG1TextKeys.slideshowInterval: t.photoSlideshowInterval(
      '{seconds}',
      '{order}',
    ),
    PhotoG1TextKeys.slideshowStarted: t.photoSlideshowStarted,
  }.entries)
    if (e.value.isNotEmpty) e.key: e.value,
};

Object? _g1TableOwner;
Map<String, String> _g1Table = const {};

/// 取 G1 新文案（key + 中文原文；当前语言的表里没有就回落中文原文）。
String photoG1(String key, String zh) {
  final t = currentText();
  if (!identical(t, _g1TableOwner)) {
    _g1TableOwner = t;
    _g1Table = _g1TextTable(t);
  }
  final v = _g1Table[key];
  return (v == null || v.isEmpty) ? dataText(key, zh) : v;
}

/// 带占位符的填充（`{count}` / `{seconds}` / `{reason}` / `{label}` …）。
String photoG1Fill(String key, String zh, Map<String, String> values) {
  var out = photoG1(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}
