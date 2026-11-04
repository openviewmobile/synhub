// N4（位置 / 地理标签）的新界面文案：**key + 中文原文**。
//
// 与 wave2/wave3/wave4/wave5/C3 各批同一套约定：`.arb` 与 `lib/l10n/gen/**`
// 在本批次**禁碰**，新文案走数据层的 `dataText.dart`（key + 中文原文；装了
// 翻译器出译文，否则回落中文）。每条的 key 就是要追加的 ARB key。
//
// ★ 已有文案一律复用既有 key，不重复造：
//   * 取消 / 保存 / 确定 → `t.actionCancel` / `t.actionSave` / `t.actionOk`
//   * 「无位置」占位 → `noteWave5(NoteWave5TextKeys.infoUnset)`
//   * 「操作失败：{error}」→ `noteWave5(NoteWave5TextKeys.unlockFailed)`
//
// ★ 与官方文案逐字对齐的几条（源：SPK `ui/texts/chs/strings` 的 `[info]`/`[search]`）：
//   `location` = "位置"、`set_coordinates` = "设置位置"、
//   `delete_gps` = "删除 GPS 信息"、`delete_gps_message` = "已成功删除 GPS 信息"、
//   `search.no_search_result` = "未找到相符项目。"
import '../../core/i18n/data_text.dart';

/// 取 N4 新文案
String noteLocation(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{error}` / `{lat}` / `{lng}` …）
String noteLocationFill(String key, String zh, Map<String, String> values) {
  var out = noteLocation(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步由编排者照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class NoteLocationTextKeys {
  // ---- 展示（官方 Web `Info.Panel` 的 `location_display` 行）----
  /// 官方 `info.location` = "位置"
  static const location = 'noteN4Location';

  // ---- 编辑（官方 Web `Info.Map.Window` / APK `MapDialogFragment`）----
  /// 官方 `info.set_coordinates` = "设置位置"（窗口标题）
  static const setLocation = 'noteN4SetLocation';

  /// 官方 `info.delete_gps` = "删除 GPS 信息"
  static const deleteGps = 'noteN4DeleteGps';

  /// 官方 `info.delete_gps_message` = "已成功删除 GPS 信息"
  static const deleteGpsMessage = 'noteN4DeleteGpsMessage';

  /// 位置名称输入框的说明（官方是 AutoCompleteTextView，可自由输入）
  static const locationNameHint = 'noteN4LocationNameHint';

  /// 搜索入口（官方 `Info.Map.SearchField`，`queryParam:"query"`）
  static const searchPlace = 'noteN4SearchPlace';

  /// 搜索输入框占位
  static const searchPlaceHint = 'noteN4SearchPlaceHint';

  /// 搜索中
  static const searching = 'noteN4Searching';

  /// 官方 `search.no_search_result` = "未找到相符项目。"
  static const noSearchResult = 'noteN4NoSearchResult';

  /// 官方 Web `Geolocation.getCurrentGPS()` / Android `execGPS()` 的入口
  static const useCurrentLocation = 'noteN4UseCurrentLocation';

  /// 没定位权限（`LocationPermission.denied`）
  static const locationPermissionDenied = 'noteN4LocationPermissionDenied';

  /// 平台没有定位能力（`LocationPermission.unsupported`）
  static const locationUnsupported = 'noteN4LocationUnsupported';

  /// 定位服务总开关没开 / 这次取不到坐标
  static const locationUnavailable = 'noteN4LocationUnavailable';

  /// 还没有中心点就没法搜附近（官方要先有地图中心）
  static const searchNeedsCenter = 'noteN4SearchNeedsCenter';

  /// 位置已保存
  static const locationSaved = 'noteN4LocationSaved';

  /// 保存失败（占位符 `{error}`）
  static const saveFailed = 'noteN4SaveFailed';

  /// 搜索结果里"用这条"的按钮提示
  static const useThisPlace = 'noteN4UseThisPlace';
}
