// ★ 仪器147（r447）：**条件等待**替代固定睡眠 —— 治"偶发假红"的通用手法。
//
// 为什么要有它：`media_stream` / `photo_p0` / `file_download_tasks` / `drive_admin_api`
// 这四条偶发假红，根因都是**同一个形状**：
//   「先说等了 150ms（或 400ms、或两轮 microtask），再断言结果」。
// 全量并发时机器满载，真实异步（文件 IO / SharedPreferences / 原生桥 / 递归扫盘）
// 没在这段**墙钟**里跑完 ⇒ 断言看到的是"还没发生"，不是"错了"。
//
// 三条纪律（判据不许被"等久一点"稀释）：
//   ① 等的是**可观测条件**（调用记录 / 控件出现 / 状态位 / 文件字节），不是时长；
//   ② 超时**返回 false**、不抛异常 —— 让用例自己的断言去红，红的读数才是
//      "条件没达成"；helper 自己炸掉会把"没达成"伪装成"装置问题"；
//   ③ 真实异步只在 `runAsync` 里推进、帧与动画只在 `pump` 里推进 ⇒ 必须**交替**。
import 'package:flutter_test/flutter_test.dart';

/// 交替「真实异步小睡」与「推帧」，直到 [done] 为真或 [timeout] 到。
///
/// 返回 `true` = 条件达成（含进入时已达成）；`false` = 超时未达成。
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 10),
  Duration step = const Duration(milliseconds: 20),
}) async {
  if (done()) return true;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump(step);
    if (done()) return true;
  }
  await tester.pump();
  return done();
}

/// 等某个 Finder 找得到（控件出现 = 界面真的走到了那一步）。
Future<bool> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
  Duration step = const Duration(milliseconds: 20),
}) => pumpUntil(
  tester,
  () => finder.evaluate().isNotEmpty,
  timeout: timeout,
  step: step,
);

/// 等一个**真实异步判据**（读设置 / 读文件 / 查服务端回读）为真。
/// 例：等 `settings.streamingIllegalCertificate()` 真落盘成 `true`。
Future<bool> pumpUntilAsync(
  WidgetTester tester,
  Future<bool> Function() probe, {
  Duration timeout = const Duration(seconds: 10),
  Duration step = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final ok = await tester.runAsync(probe) ?? false;
    if (ok) return true;
    if (!DateTime.now().isBefore(deadline)) return false;
    await tester.pump(step);
  }
}

/// 纯 Dart 用例（没有 `WidgetTester`）用的条件等待 —— 同一套纪律。
Future<bool> pollUntilAsync(
  Future<bool> Function() probe, {
  Duration timeout = const Duration(seconds: 10),
  Duration step = const Duration(milliseconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (await probe()) return true;
    if (!DateTime.now().isBefore(deadline)) return false;
    await Future<void>.delayed(step);
  }
}
