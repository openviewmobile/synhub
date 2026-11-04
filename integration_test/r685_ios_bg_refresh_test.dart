// r685（s285）· iOS 后台刷新「被唤起」这一段
//
// 系统侧在模拟器上做不到（`submit` → `BGTaskSchedulerErrorDomain:1`；
// `_simulateLaunchForTaskWithIdentifier` → "No task request … has been
// scheduled"，两条原始日志见 `docs/platform-ios.md` §22）。所以这里验的是
// **我们自己写的那一段**：handler 被调用时，① 持久计数 +1、② Dart 收到
// `onBackgroundRefresh` 事件。由宿主脚本用 LLDB 调
// `[[BackgroundBridge shared] handleRefreshLaunch:@"…"]` 触发（模拟器上
// 这是"能让 handler 真跑一遍"的唯一手段）。
//
// 判据：等宿主触发 → 计数从 0 变 1、taskId 对上、Dart 事件真的收到。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/native/background_service.dart';

const _kTaskId = 'com.openviewai.synhub.refresh';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('s285 后台刷新 handler：持久计数 + Dart 事件', (tester) async {
    final svc = BackgroundService();
    final got = Completer<String>();
    svc.setRefreshHandler((taskId) {
      if (!got.isCompleted) got.complete(taskId);
    });
    // 必须装一次 methodCallHandler，事件才会流到 Dart
    svc.setActionHandler((_) {});

    final before = await svc.refreshStats();
    // ignore: avoid_print
    print('[r685] ready fired=${before.fired} lastTask="${before.lastTaskId}"');

    // 等宿主脚本用 LLDB 触发（给足 120 s：脚本要先找到 pid）
    final taskId = await got.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => '',
    );
    final after = await svc.refreshStats();
    // ignore: avoid_print
    print('[r685] after fired=${after.fired} lastTask="${after.lastTaskId}" '
        'event="${taskId.isEmpty ? '<none>' : taskId}"');

    expect(taskId, _kTaskId, reason: 'Dart 侧必须收到 onBackgroundRefresh 事件');
    expect(after.fired, greaterThan(before.fired), reason: '持久计数必须 +1');
    expect(after.lastTaskId, _kTaskId, reason: '落盘的 taskId 必须是刷新任务');
    expect(after.lastAt, greaterThan(0), reason: '落盘时间戳必须有效');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
