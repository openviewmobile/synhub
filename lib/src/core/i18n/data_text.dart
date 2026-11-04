// 数据层文案：**key + 中文原文**。
//
// 为什么不直接用 `AppText`（`l10n.dart` / 生成代码）：数据层
// （`lib/src/dsm/**`、`lib/src/data/**`）必须能被 `dart run tool/*.dart`
// 用**纯 Dart VM** 直接加载 —— `tool/` 下的探针都 import 这些文件，
// 见 docs/phase7-protocol.md 与 docs/re-toolchain.md。
//
// 而 `l10n.dart` 依赖 `package:flutter/widgets.dart` → `dart:ui`，
// 纯 Dart 平台没有 `dart:ui`（`Dart library 'dart:ui' is not available on
// this platform.`）。所以数据层**一个 Flutter 符号都不能碰**。
//
// 依赖方向因此反过来：
//   * 数据层只认 `key + 中文原文`，通过 [dataText] 取译文；
//   * 翻译由 **Flutter 层**在语言变化时通过 [setDataTextResolver] 注入
//     （见 `lib/src/core/i18n/l10n.dart` 的 `setCurrentText`）；
//   * 没装翻译器（纯 Dart 探针、普通单测）就**回落中文原文**。
//
// 本文件**不许** import flutter / dart:ui / package:flutter（含 foundation）。
library;

/// 数据层翻译器：给定 ARB key 与中文原文，返回当前语言的译文。
typedef DataTextResolver = String Function(String key, String zh);

DataTextResolver? _resolver;

/// 安装（或卸载，传 null）翻译器。只有 Flutter 层该调。
void setDataTextResolver(DataTextResolver? r) => _resolver = r;

/// 取 [key] 对应的译文；没装翻译器、或翻译表里没有该 key 就回落 [zh]。
String dataText(String key, String zh) => _resolver?.call(key, zh) ?? zh;
