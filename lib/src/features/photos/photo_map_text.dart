// 相册「地点 → 在地图中打开」（第一期 · 方案 A）新增界面文案：**key + 中文原文**。
//
// 同一套约定（见 `photo_p1_text.dart` / `photo_c2_text.dart`）：`.arb` 与
// `lib/l10n/gen/**` 本批次**禁碰**，新文案走数据层的 `dataText.dart`
// （key + 中文原文；装了翻译器就出译文，否则回落中文）。
// 每一条 key 就是要追加的 ARB key，`zh/en` 清单见
// `docs/photo-map-evaluation.md` §8。
import '../../core/i18n/data_text.dart';

/// 取本批新文案（key 见 [PhotoMapTextKeys]）
String photoMap(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{name}` / `{lat}` / `{lon}` / `{service}` / `{region}`）
String photoMapFill(String key, String zh, Map<String, String> values) {
  var out = photoMap(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class PhotoMapTextKeys {
  /// 地点列表项上的按钮/气泡标题
  static const open = 'photoMapOpen';
  static const sheetTitle = 'photoMapSheetTitle';

  /// 坐标 / 地名两类提示（**必须如实说明**）
  static const nameOnlyHint = 'photoMapNameOnlyHint';
  static const preciseHint = 'photoMapPreciseHint';

  /// 有坐标时的提示（**默认不展示坐标数字**，合规要求；数字只在"复制坐标"里给）
  static const preciseNoNumbersHint = 'photoMapPreciseNoNumbersHint';
  static const nothingHint = 'photoMapNothingHint';

  /// 服务选择
  static const serviceLabel = 'photoMapServiceLabel';
  static const serviceAuto = 'photoMapServiceAuto';
  static const serviceGoogle = 'photoMapServiceGoogle';
  static const serviceAmap = 'photoMapServiceAmap';
  static const serviceTencent = 'photoMapServiceTencent';
  static const serviceBaidu = 'photoMapServiceBaidu';
  static const autoResolved = 'photoMapAutoResolved';
  static const regionHint = 'photoMapRegionHint';

  /// 动作
  static const openAction = 'photoMapOpenAction';
  static const copyName = 'photoMapCopyName';
  static const copied = 'photoMapCopied';
  static const failed = 'photoMapFailed';
  static const fallbackNote = 'photoMapFallbackNote';
  static const preciseBadge = 'photoMapPreciseBadge';
  static const nameSearchBadge = 'photoMapNameSearchBadge';

  /// 坐标是敏感个人信息 → **默认不展示数字**；用户主动点"复制坐标"才把
  /// `lat,lon` 放进剪贴板（不在界面上渲染）。
  static const copyCoord = 'photoMapCopyCoord';

  /// 「境外服务 + 精确坐标」的一次性告知（**数据出境**；只有 Google 会弹）
  static const overseasConsentTitle = 'photoMapOverseasConsentTitle';
  static const overseasConsentBody = 'photoMapOverseasConsentBody';
  static const overseasConsentAgree = 'photoMapOverseasConsentAgree';
  static const overseasConsentRefuse = 'photoMapOverseasConsentRefuse';
}
