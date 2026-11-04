// 文件 / 电子书（book_*、drive_on_demand、SAF 根标题）新增界面文案：
// **key + 中文原文**。
//
// 约定与 `filestation_c5_text.dart` / `filestation_webdav_text.dart` /
// `drive_p0_text.dart` 一致：`.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**，
// 所以新文案一律 `key + 中文原文`，走 `dataText`
// （`lib/src/core/i18n/data_text.dart`）。ARB 里补上同名 key 后，
// `setCurrentText` 注入的翻译表会自动把中文原文换成当前语言译文；
// 没补上时回落中文原文。纯 Dart 层（book_* 解析器）也能安全 import
// （`data_text.dart` 不依赖 flutter / dart:ui）。
//
// 带占位符的写法：**中文回落里保留原 `$var` 插值**，
// 英文模板用 `{name}`，调用方用 [fsTFill] 把 `{name}` 换成同一个值 ——
// 这样补 ARB 之前显示的是真实值（不是 `{name}`），补上之后英文也正确。
library;

import '../../core/i18n/data_text.dart';

/// 文件 / 电子书文案
String fsT(String key, String zh) => dataText(key, zh);

/// 带 `{name}` / `{count}` 等占位符的文案填充
String fsTFill(String key, String zh, Map<String, String> values) {
  var out = fsT(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}
