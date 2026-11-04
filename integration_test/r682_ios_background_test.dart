// r682：iOS **后台执行 + 本地通知**桥（`synhub/background` 的 Swift 实现）端到端探针。
//
// 验的是什么（每条都对着一个"iOS 与 Android 语义不同"的点）：
//   ① 能力层放行 `backgroundExecution` / `localNotifications`（Swift 桥随包编译）；
//   ② `start()` 开的是**后台执行窗口**（`beginBackgroundTask`）：`isRunning()` 变 true，
//      `keepAliveStatus()` 的 `kind == 'background-window'`（**不是**常驻前台服务），
//      `stop()` 之后变 false —— 两侧都量，防"恒真"；
//   ③ `scheduleRefresh()` 真把 `BGAppRefreshTaskRequest` 提交进系统，且
//      `pendingTaskRequests()` 能读回来（读的是 `BGTaskScheduler` 的**系统状态**）；
//   ④ 通知授权未决时：`notificationAuthorizationStatus() == 0`（notDetermined）
//      且 `showMessage()` **如实返回 false**（不许假装挂上）；`notificationCount()` 为 0；
//   ⑤ 开机自启位在 `UserDefaults` 里能存能读（iOS 上 `boot` 语义无效，只为契约同形）。
//
// 边界（必须一起读）：
//   * 通知**授权弹框**要人来点，无头模拟器点不了 ⇒ 本用例**不**调
//     `requestNotificationPermission()`（它会挂起等应答），只验"未授权时如实失败"；
//     真机上点一次「允许」之后的横幅/角标/点开回 Dart，不在本轮证据里。
//   * `BGAppRefreshTask` 的**实际触发**由系统按使用习惯排，模拟器无法触发
//     （要 LLDB 的 `_simulateLaunchForTaskWithIdentifier`）⇒ 这里只证"提交成功且
//     在系统队列里"，不证"跑过一次"。
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/native/background_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('s282 iOS 后台执行窗口：开始/状态/结束都是真状态', () async {
    final caps = staticCapabilitiesFor(AppHost.ios);
    expect(caps.can(AppCapability.backgroundExecution), isTrue);
    expect(caps.can(AppCapability.localNotifications), isTrue);

    final bg = BackgroundService();
    expect(bg.isSupported, isTrue);

    // 起点：没有窗口
    expect(await bg.isRunning(), isFalse, reason: '还没 start');

    expect(await bg.start(title: 'r682', text: 'probe'), isTrue);
    expect(await bg.isRunning(), isTrue);
    final status = await bg.keepAliveStatus();
    // ignore: avoid_print
    print('[r682] keepAlive=$status');
    expect(status, isNotNull, reason: 'iOS 专有状态必须回（Android 才没有）');
    expect(status!['kind'], 'background-window');
    expect(status['active'], isTrue);
    expect((status['startedAt'] as num).toDouble(), greaterThan(0));

    expect(await bg.stop(), isTrue);
    expect(await bg.isRunning(), isFalse, reason: 'stop 之后必须真的没了');
    final after = await bg.keepAliveStatus();
    expect(after!['active'], isFalse);
  });

  test('s282 iOS 后台刷新：真调了 BGTaskScheduler，结果与系统答复一致', () async {
    final bg = BackgroundService();
    final submitted = await bg.scheduleRefresh(afterSeconds: 60);
    final pending = await bg.pendingTaskRequests();
    final err = await bg.lastScheduleError();
    // ignore: avoid_print
    print('[r682] submitted=$submitted pending=$pending err=$err');

    if (submitted) {
      // 真机（或被系统接受）的路径：队列里必须读得到它
      expect(pending, isNotEmpty, reason: '提交成功却不出现 ⇒ 任务 id 有问题');
      final ids = pending
          .map((e) => (e as Map)['identifier'])
          .whereType<String>()
          .toList();
      expect(ids, contains('com.openviewai.synhub.refresh'));
      expect(err ?? '', isEmpty);
    } else {
      // ★ 模拟器的真实答复：`BGTaskSchedulerErrorDomain:1`（unavailable）。
      //   这条断言的意义是"我们真的把请求交给了系统、并把它的拒绝原样带回来"，
      //   而不是"忘了接 / 吞掉错误假装成功"。
      expect(err ?? '', startsWith('BGTaskSchedulerErrorDomain:'),
          reason: '失败必须带系统错误码，否则说明没真调系统 API');
      expect(pending, isEmpty);
    }
  });

  test('s282 iOS 通知：未授权时如实失败（不许假装挂上）', () async {
    final bg = BackgroundService();
    final auth = await bg.notificationAuthorizationStatus();
    // ignore: avoid_print
    print('[r682] notificationAuth=$auth');
    expect(auth, 0, reason: '干净安装的模拟器 = notDetermined；若已被人点过会不是 0');

    final ok = await bg.show(
      const MessageNotification(
        channelId: 7,
        postId: 11,
        title: 'r682 探针',
        text: '未授权不该挂上',
        canReply: true,
      ),
    );
    expect(ok, isFalse, reason: '没有授权时 add() 会失败 —— 必须把这个失败往上交');
    expect(await bg.activeCount(), 0);
    expect(await bg.activeTags(), isEmpty);
  });

  test('s282 iOS 开机自启位：UserDefaults 能存能读（boot 语义无效但契约同形）', () async {
    final bg = BackgroundService();
    expect(await bg.setAutostart(boot: true, foreground: true), isTrue);
    var got = await bg.getAutostart();
    expect(got.boot, isTrue);
    expect(got.foreground, isTrue);
    // 反向：改回 false 再读（防"恒真"）
    expect(await bg.setAutostart(boot: false, foreground: false), isTrue);
    got = await bg.getAutostart();
    expect(got.boot, isFalse);
    expect(got.foreground, isFalse);
  });
}
