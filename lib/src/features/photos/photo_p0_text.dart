// 相册 P0（删除/回收站提示、批量结果、视频画质）新增界面文案：
// **key + 中文原文**。
//
// 与 C2（`photo_c2_text.dart`）同一套约定：`.arb` 与 `lib/l10n/gen/**`
// 在本批次**禁碰**，所以新文案走数据层的 `dataText.dart`（key + 中文原文；
// 装了翻译器就出译文，否则回落中文）。每一条的 key 就是要追加的 ARB key，
// 清单见 `docs/photo-p0-implementation.md` 的「ARB key 清单」。
//
// 复用原则：能复用既有 `photo*` key 的（删除失败/下载成功/已加入相册…）
// **一律复用 `context.t`**，本文件只放"确实没有的"那几条。
import '../../core/i18n/data_text.dart';

/// 取 P0 新文案（key 见 [PhotoP0TextKeys]）
String photoP0(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{count}` / `{ok}` / `{fail}` / `{name}` …）
String photoP0Fill(String key, String zh, Map<String, String> values) {
  var out = photoP0(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class PhotoP0TextKeys {
  // 多选栏
  static const actionDownload = 'photoP0ActionDownload';
  static const actionFavorite = 'photoP0ActionFavorite';
  static const actionUnfavorite = 'photoP0ActionUnfavorite';
  static const actionAddToAlbum = 'photoP0ActionAddToAlbum';
  // P18/P19：智能相册（人物/场景）的写操作
  static const actionSetCover = 'photoP0ActionSetCover';
  static const actionShare = 'photoP0ActionShare';
  static const shareDone = 'photoP0ShareDone';
  static const actionRemoveSmart = 'photoP0ActionRemoveSmart';
  static const personRename = 'photoP0PersonRename';
  static const personRenamed = 'photoP0PersonRenamed';
  static const coverSet = 'photoP0CoverSet';
  static const removeSmartConfirm = 'photoP0RemoveSmartConfirm';
  static const removeSmartBody = 'photoP0RemoveSmartBody';
  static const removeSmartDone = 'photoP0RemoveSmartDone';
  static const actionRemoveFromAlbum = 'photoP0ActionRemoveFromAlbum';

  // 删除
  static const deleteTitle = 'photoP0DeleteTitle';
  static const deleteBody = 'photoP0DeleteBody';
  static const deletedCount = 'photoP0DeletedCount';

  // 批量结果反馈（成功 N / 失败 M）
  static const batchResult = 'photoP0BatchResult';
  static const batchAllFailed = 'photoP0BatchAllFailed';

  // 批量下载
  static const downloadZipReady = 'photoP0DownloadZipReady';
  static const downloadZipEmpty = 'photoP0DownloadZipEmpty';

  // 视频画质三档（官方 `array/video_quality` / `video_quality_value`）
  static const videoQuality = 'photoP0VideoQuality';
  static const videoQualityAuto = 'photoP0VideoQualityAuto';
  static const videoQualityFirst = 'photoP0VideoQualityFirst';
  static const videoSpeedFirst = 'photoP0VideoSpeedFirst';
  static const videoQualityApplied = 'photoP0VideoQualityApplied';

  // 人物页「正在整理」进度（接线 `Browse.Person/get_migration_status`）
  static const personMigratingProgress = 'photoP0PersonMigratingProgress';

  // 人物可见性开关（`Person/show`）与投送（P65）
  static const personShow = 'photoP0PersonShow';
  static const personHide = 'photoP0PersonHide';
  static const castUnknownDevice = 'photoP0CastUnknownDevice';
  static const castToScreen = 'photoP0CastToScreen';
  static const castStop = 'photoP0CastStop';
}
