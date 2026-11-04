// 相册**媒体增强批次**（P13 实况/动态照片 · P14 360 全景 · P36 编辑日期）
// 新增界面文案：**key + 中文原文**。
//
// 与 `photo_p0_text.dart` / `photo_p1_text.dart` / `photo_c2_text.dart` 同一套约定：
// 本批次**不改** `lib/l10n/*.arb` 与 `lib/l10n/gen/**`（ARB 是跨批次共享文件，
// 同批还有其它批次在跑；gen 代码不在本批次可碰范围内），所以文案走数据层的
// `dataText.dart`（key + 中文原文；装了翻译器就出译文，否则回落中文）。
//
// 下面 [PhotoMediaTextKeys] 的每一条 key 就是**下一步要追加进 ARB 的 key**，
// 清单已写进 `docs/photo-media-live-pano-date-report.md` 的「ARB key 清单」。
//
// 复用原则：官方原文能直译的就直译，能复用既有 `photo*` key 的一律复用。
import '../../core/i18n/data_text.dart';

/// 取本批新文案（key 见 [PhotoMediaTextKeys]）。
String photoMedia(String key, String zh) => dataText(key, zh);

/// 带占位符的填充（`{name}` / `{error}` / `{time}` …）。
String photoMediaFill(String key, String zh, Map<String, String> values) {
  var out = photoMedia(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key。
abstract final class PhotoMediaTextKeys {
  // ---------------------------------------------------------------- P13 实况/动态
  //
  // 官方字符串（APK `strings_en.txt`）：
  //   `string/str_motion_photo = Motion Photo`（:8737）
  //   `string/str_suggestion_live_motion = Live Photo/Motion Photo`（:8998）
  //   `action/switch_live_photo` / `action/switch_motion_photo`（Web 工具栏按钮标题）
  //   `string/str_edit_motion_alert_content`（:8537）
  static const liveBadge = 'photoMediaLiveBadge';
  static const motionBadge = 'photoMediaMotionBadge';
  static const livePlayTooltip = 'photoMediaLivePlayTooltip';
  static const liveStopTooltip = 'photoMediaLiveStopTooltip';
  static const liveUnavailable = 'photoMediaLiveUnavailable';
  static const liveLongPressHint = 'photoMediaLiveLongPressHint';
  static const livePlaybackFailed = 'photoMediaLivePlaybackFailed';

  // ---------------------------------------------------------------- P14 360 全景
  //
  // 官方字符串（APK `strings_en.txt`）：
  //   `str_360Photo_Click_Indicator = Tap and drag the 360 photo.`（:8275）
  //   `str_360Photo_Disable_Click_Indicator = Unable to load the 360 photo.`（:8276）
  //   `str_360Video_Click_Indicator = Tap to play the 360 video.`（:8277）
  static const panoPhotoHint = 'photoMediaPanoPhotoHint';
  static const panoPhotoFailed = 'photoMediaPanoPhotoFailed';
  static const panoResetView = 'photoMediaPanoResetView';
  static const panoBadge = 'photoMediaPanoBadge';
  static const panoVideoBadge = 'photoMediaPanoVideoBadge';
  /// ⚠️ 官方**没有**这一条：官方全景视频走 Google VR 原生球面渲染
  /// （`Video360Activity` + `libpano_video_renderer.so`），本仓播放器不做球面，
  /// 所以必须**自己如实说明**降级，不许假装在放球面。
  static const panoVideoFlatNotice = 'photoMediaPanoVideoFlatNotice';

  // ---------------------------------------------------------------- P36 编辑日期
  //
  // 官方资源（APK）：`layout/sheet_edit_date`、`id/btn_edit_date`、
  // `string/str_edit_date_title`、`ui/dateeditor/EditDateSheet` +
  // `EditDateViewModel`（改名/换时间的**两个独立字段**：日期 + 时刻）。
  static const editDateTitle = 'photoMediaEditDateTitle';
  static const editDateAction = 'photoMediaEditDateAction';
  /// 查看器 AppBar 的**入口**文案（「编辑日期时间」）。
  ///
  /// ⚠️ 与 [editDateAction] **必须是两个 key**：前者是入口标题、
  /// 后者是弹层里的提交按钮（「保存」）。曾经共用一个 key
  /// ⇒ 任何译文都会让其中一处显示错的意思。
  static const editDateMenuAction = 'photoMediaEditDateMenuAction';
  static const editDateField = 'photoMediaEditDateField';
  static const editTimeField = 'photoMediaEditTimeField';
  static const editDateConfirmTitle = 'photoMediaEditDateConfirmTitle';
  static const editDateConfirmBody = 'photoMediaEditDateConfirmBody';
  static const editDateSaved = 'photoMediaEditDateSaved';
  static const editDateFailed = 'photoMediaEditDateFailed';
  static const editDateInvalid = 'photoMediaEditDateInvalid';
  static const editDateUnsupported = 'photoMediaEditDateUnsupported';
}
