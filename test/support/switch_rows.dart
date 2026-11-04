// 开关行的定位助手（r469；★ r512 起全仓 37 处 `SwitchListTile` 已换成 `DesignSwitchRow`，
// 这个 finder 就是 `DA155` 的落点：换皮不许打红「按类型找控件」的用例）。
//
// 设置/免打扰等页面的行已换成设计组件 `DesignSwitchRow`（视觉来自
// `design/spec/*.json`），但它的 API 与 `SwitchListTile` 同名同义。
// 用例只关心"这一行里的开关"，不该因为换皮而失效 —— 所以这里统一成
// 一个"两种类型都算"的 finder，避免每个文件各写一份。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/design/kit/design_kit.dart';

/// 行容器：`SwitchListTile`（旧）或 `DesignSwitchRow`（设计组件）。
final Finder switchRowFinder = find.byWidgetPredicate(
  (Widget w) => w is SwitchListTile || w is DesignSwitchRow,
);

/// 勾选行容器：`CheckboxListTile`（旧）或 `DesignCheckRow`（设计组件）。
/// r513 起 15 处已全部换皮（`DA156`），这个 finder 留给"两种类型都算"的断言。
final Finder checkboxRowFinder = find.byWidgetPredicate(
  (Widget w) => w is CheckboxListTile || w is DesignCheckRow,
);
