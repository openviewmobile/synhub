// ★ r701 · `DA341`：**桌面托盘项**的接线（App 侧）。
//
// 这一层只做两件事，都是"应用之外不存在"的：
//   ① 起 `org.kde.StatusNotifierItem`（见 `status_notifier_linux.dart`）；
//   ② 托盘被点/菜单被点时，把**主窗口**叫到前台 —— 走系统窗口管理器（`wmctrl`，
//      退化为 `xdotool`），**不是**自己挪窗口位置那种假动作。
//
// 纪律：
//   * `wmctrl`/`xdotool` 都不在 / 调用失败 ⇒ 只记一次日志，**不抛、不拦启动**；
//   * 没有宿主（watcher）时 `start()` 返回 `null`，App 照常跑（容器里就是这样）；
//   * 这里**不**放"退出"动作：本仓没有保存状态后优雅退出的路径，
//     摆一个 `exit(0)` 的假退出只会让用户丢会话（见 `status_notifier_linux.dart` 头注）。
import 'package:flutter/foundation.dart';

import 'desktop_notify_linux.dart';
import 'status_notifier_linux.dart';

/// 起托盘项。拿不到宿主时返回 `null`（调用方不需要处理）。
///
/// [activate] 只给用例注入用；生产走 [raiseAppWindow]。
Future<StatusNotifierLinuxService?> startLinuxDesktopTray({
  String title = 'SynHub',
  Future<void> Function()? activate,
  String label = '',
}) async {
  if (kIsWeb) return null;
  return StatusNotifierLinuxService.start(
    callbacks: SniCallbacks(
      activate: activate ?? () async => raiseAppWindow(title),
    ),
    title: title,
    menuLabel: label,
  );
}
