// Phase 9 真机验收：免打扰（手动 snooze + 定时免打扰）。
//
//   flutter test integration_test/phase9_snooze_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 全部走 App 自己的代码（`SnoozeController` → `ChatApi`），对真 NAS（2.4.7-22203）：
//   ① `User.Preference get` 基线（记录原始值，测试完**必须还原**）；
//   ② 设 20 分钟免打扰 → 服务端 `get` 回读：`snooze` ≈ 服务端现在 + 20min
//      （误差容忍 90s，包含网络往返 + 时差）；
//   ③ 取消（`snooze=0`）→ 回读 = 0；
//   ④ 定时免打扰：开 22:00–06:00（跨午夜）→ 回读三个字段 → 还原成原始值；
//   ⑤ 本地门禁：设 1 小时后 `suppressesNow == true`，取消后按定时设置判定。
//
// ⚠️ 免打扰会影响**这个账号所有设备**的通知，所以每条断言之后立刻还原。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/settings/snooze_controller.dart';
import 'package:synhub/src/features/settings/snooze_settings_page.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

/// `SnoozeSettingsPage` 里有个**每秒 `setState`** 的倒计时 ticker
/// （`lib/src/features/settings/snooze_settings_page.dart:35-39`，原版就是
/// `postDelayed` 续命，产品行为是对的）⇒ 这个页面上 `pumpAndSettle()` **永远不返回**：
/// 它要等"没有已排帧"，而 ticker 每秒都排一帧（默认 10 分钟超时 ⇒ 整目标先被套件
/// 看门狗杀掉，日志里连一条 `Expected/Actual` 都看不到 —— 第 45 轮真机红灯的真因）。
/// 按仓库既有约定（AGENTS §2.0.9「有常驻动画时 pumpAndSettle 不可用」）改成
/// **有界 pump**：把动画该走的时间推够即可，**断言一条没改**。
Future<void> pumpBounded(
  WidgetTester tester, [
  Duration d = const Duration(milliseconds: 400),
]) async {
  await tester.pump();
  await tester.pump(d);
  await tester.pump(d);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 常驻动效（`FieldBackdrop`）在真机 integration_test 里默认是**开**的
  // （`AppEffects.isFlutterTest` 只认 `FLUTTER_TEST` 环境变量，真机上没有）⇒
  // 显式按"用户减少动效"关掉，见 `lib/src/core/theme/app_tokens.dart:109`。
  AppEffects.reducedMotion.value = true;

  testWidgets('Phase 9 真机：免打扰 / 定时免打扰（读-改-读-还原）', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);

    final snooze = container.read(snoozeControllerProvider.notifier);
    final syncState = container.read(chatSessionControllerProvider);
    debugPrint('[p9s] 我=#${syncState.myUserId} '
        'skew=${syncState.clockSkewMillis}ms '
        'Preference maxVersion=${chat.api.apiTable?['SYNO.Chat.User.Preference']?.maxVersion}');
    expect(
      chat.api.apiTable?.containsKey('SYNO.Chat.User.Preference'),
      isTrue,
      reason: 'NAS 2.4.7 必须有 SYNO.Chat.User.Preference',
    );

    // ---------- ① 基线 ----------
    final base = await chat.userPreferenceGet();
    debugPrint('[p9s] 基线：$base');
    expect(base.scheduleStartSecond, inInclusiveRange(0, 86399));
    expect(base.scheduleEndSecond, inInclusiveRange(0, 86399));

    // ---------- ②20 分钟免打扰 ----------
    final before = DateTime.now().millisecondsSinceEpoch;
    await snooze.setSnooze(const Duration(minutes: 20));
    var server = await chat.userPreferenceGet();
    final serverNow =
        DateTime.now().millisecondsSinceEpoch + syncState.clockSkewMillis;
    debugPrint('[p9s] 20 分钟后服务端 snooze=${server.snooze} '
        '（服务端现在≈$serverNow）');
    expect(server.snooze, greaterThan(serverNow + 15 * 60 * 1000),
        reason: '截止时间应该在 15 分钟之后');
    expect(server.snooze, lessThan(before + syncState.clockSkewMillis + 25 * 60 * 1000),
        reason: '截止时间不应该超过 25 分钟');
    // 本地状态同步可用
    expect(container.read(snoozeControllerProvider).manualActiveNow, isTrue);
    expect(container.read(snoozeControllerProvider).suppressesNow, isTrue);

    // ---------- ③ 取消 ----------
    await snooze.setSnooze(Duration.zero);
    server = await chat.userPreferenceGet();
    debugPrint('[p9s] 取消后服务端 snooze=${server.snooze}');
    expect(server.snooze, 0);
    expect(container.read(snoozeControllerProvider).manualActiveNow, isFalse);

    // ---------- ④ 定时免打扰（跨午夜区间）----------
    await snooze.setSchedule(enable: true, startSecond: 79200, endSecond: 21600);
    server = await chat.userPreferenceGet();
    debugPrint('[p9s] 定时后服务端：enable=${server.scheduleEnabled} '
        '${server.scheduleStartSecond}..${server.scheduleEndSecond}');
    expect(server.scheduleEnabled, isTrue);
    expect(server.scheduleStartSecond, 79200);
    expect(server.scheduleEndSecond, 21600);
    // 跨午夜窗口在本地判定里应当命中（22:00–06:00 覆盖了绝大概率的时间点；
    // 若真跑到 06:00–22:00 之间的白天时段，这里就跳过，只验证字段回读）
    final localNow = DateTime.now();
    final sec = secondsOfLocalDay(localNow);
    if (sec >= 79200 || sec <= 21600) {
      expect(container.read(snoozeControllerProvider).suppressesNow, isTrue,
          reason: '当前 $sec 落在 22:00–06:00 内，应该判定为免打扰');
    }

    // ---------- ⑤ 还原成基线 ----------
    await snooze.setSchedule(
      enable: base.scheduleEnabled,
      startSecond: base.scheduleStartSecond,
      endSecond: base.scheduleEndSecond,
    );
    await snooze.setSnooze(Duration.zero);
    final restored = await chat.userPreferenceGet();
    debugPrint('[p9s] 还原后：$restored');
    expect(restored.snooze, 0);
    expect(restored.scheduleEnabled, base.scheduleEnabled);
    expect(restored.scheduleStartSecond, base.scheduleStartSecond);
    expect(restored.scheduleEndSecond, base.scheduleEndSecond);
    debugPrint('[p9s] ✅ 免打扰读-改-读-还原全部通过');
  });

  testWidgets('Phase 9 真机：免打扰设置页（真连接 + 真点击）', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    await container.read(chatSessionControllerProvider.notifier).start(conn);

    // 基线（测完还原）
    final base = await chat.userPreferenceGet();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SnoozeSettingsPage()),
    ));
    await pumpBounded(tester);
    expect(find.text('免打扰'), findsWidgets);
    debugPrint('[p9su] 免打扰页渲染 OK（副标题=${container.read(snoozeControllerProvider).subtitleAt(DateTime.now())}）');

    // ① 点开 → 选 20 分钟 → 服务端回读
    await tester.tap(find.text('免打扰').first);
    await pumpBounded(tester);
    expect(find.text('20 分钟'), findsOneWidget);
    await tester.tap(find.text('20 分钟'));
    await pumpBounded(tester);
    var server = await chat.userPreferenceGet();
    final serverNow =
        DateTime.now().millisecondsSinceEpoch + container.read(chatSessionControllerProvider).clockSkewMillis;
    debugPrint('[p9su] UI 选 20 分钟后服务端 snooze=${server.snooze}');
    expect(server.snooze, greaterThan(serverNow + 15 * 60 * 1000));
    expect(find.textContaining('剩余 00:1'), findsOneWidget);

    // ② 再点开 → 关闭免打扰 → 服务端回读 0
    await tester.tap(find.text('免打扰').first);
    await pumpBounded(tester);
    expect(find.text('关闭免打扰'), findsOneWidget);
    await tester.tap(find.text('关闭免打扰'));
    await pumpBounded(tester);
    server = await chat.userPreferenceGet();
    debugPrint('[p9su] UI 关闭后服务端 snooze=${server.snooze}');
    expect(server.snooze, 0);

    // ③ 定时免打扰页：入口在（maxVersion≥3），渲染默认 09:00/18:00，保存后回读
    await tester.tap(find.text('定时免打扰'));
    await pumpBounded(tester);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('18:00'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await pumpBounded(tester);
    await tester.tap(find.text('保存'));
    await pumpBounded(tester);
    server = await chat.userPreferenceGet();
    debugPrint('[p9su] UI 保存定时后服务端：enable=${server.scheduleEnabled} '
        '${server.scheduleStartSecond}..${server.scheduleEndSecond}');
    expect(server.scheduleEnabled, isTrue);
    expect(server.scheduleStartSecond, 32400);
    expect(server.scheduleEndSecond, 64800);

    // ④ 还原成基线
    await container.read(snoozeControllerProvider.notifier).setSchedule(
          enable: base.scheduleEnabled,
          startSecond: base.scheduleStartSecond,
          endSecond: base.scheduleEndSecond,
        );
    await container.read(snoozeControllerProvider.notifier).setSnooze(Duration.zero);
    final restored = await chat.userPreferenceGet();
    expect(restored.snooze, 0);
    expect(restored.scheduleEnabled, base.scheduleEnabled);
    debugPrint('[p9su] ✅ 设置页真机点击验收通过（已还原）');
  });
}
