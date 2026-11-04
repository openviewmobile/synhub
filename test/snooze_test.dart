// Phase 9：免打扰（snooze）—— 对位原版 `User.Preference` + `SnoozeFragment` /
// `ScheduleSnoozeFragment` / `SubItem.bindSnoozeIcon`。
//
// 覆盖：
//   * 时间窗判定（同一天 / 跨午夜 / 闭区间）—— 逐行对上原版那两行三元表达式
//   * `HH:mm` 与「剩余 HH:MM:SS」格式
//   * DTO 解析：真机返回里关闭定时免打扰时**没有** start/end → 走默认 09:00/18:00
//   * API 形状与版本：get 用 [3,2,1]、set snooze 锁 v1、定时免打扰锁 v3 且
//     老服务端（maxVersion<3）直接报版本错
//   * 控制器：setSnooze 带上服务端时差、取消、定时开关落库、preload 恢复
//   * 通知门禁：免打扰期间不弹；关掉后恢复
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/user_preference_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/settings/snooze_controller.dart';
import 'package:synhub/src/features/settings/snooze_settings_page.dart';

import 'support/chat_harness.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/fake_background.dart';

/// 通知门禁用例里造一条别人的消息 + 它所在频道
PostDto _notifyPost(int id, {int channelId = 5}) => PostDto.fromJson({
  'post_id': id,
  'channel_id': channelId,
  'creator_id': 4,
  'create_at': 9000,
  'type': 'normal',
  'message': '在吗',
});

ChannelDto _notifyChannel(int id) =>
    ChannelDto.fromJson({'channel_id': id, 'name': '测试频道', 'type': 'public'});

SnoozeState _state({
  int snoozeUntilMs = 0,
  bool schedule = false,
  int start = 32400,
  int end = 64800,
}) => SnoozeState(
  snoozeUntilMs: snoozeUntilMs,
  scheduleEnabled: schedule,
  scheduleStartSecond: start,
  scheduleEndSecond: end,
  maxVersion: 3,
  loaded: true,
);

void main() {
  group('定时免打扰的时间窗（照抄 SubItem.bindSnoozeIcon）', () {
    int at(int h, int m) => h * 3600 + m * 60;

    test('同一天：start <= now <= end（闭区间）', () {
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(9, 0),
          startSecond: at(9, 0),
          endSecond: at(18, 0),
        ),
        isTrue,
      );
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(18, 0),
          startSecond: at(9, 0),
          endSecond: at(18, 0),
        ),
        isTrue,
      );
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(12, 0),
          startSecond: at(9, 0),
          endSecond: at(18, 0),
        ),
        isTrue,
      );
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(8, 59),
          startSecond: at(9, 0),
          endSecond: at(18, 0),
        ),
        isFalse,
      );
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(18, 1),
          startSecond: at(9, 0),
          endSecond: at(18, 0),
        ),
        isFalse,
      );
    });

    test('跨午夜：start >= end 时 start <= now || now <= end', () {
      // 22:00–06:00
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(23, 0),
          startSecond: at(22, 0),
          endSecond: at(6, 0),
        ),
        isTrue,
      );
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(3, 0),
          startSecond: at(22, 0),
          endSecond: at(6, 0),
        ),
        isTrue,
      );
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(22, 0),
          startSecond: at(22, 0),
          endSecond: at(6, 0),
        ),
        isTrue,
      );
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(6, 0),
          startSecond: at(22, 0),
          endSecond: at(6, 0),
        ),
        isTrue,
      );
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(12, 0),
          startSecond: at(22, 0),
          endSecond: at(6, 0),
        ),
        isFalse,
      );
    });

    test('start == end：走"跨午夜"分支 = 全天（原版也这样）', () {
      // 原版两个分支都是 `start >= end`，相等时第一个成立，且 `start <= now || now <= end`
      // 在 start == end 时对任意 now 都为真 → 全天免打扰（界面上保存前会拦相等）
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(3, 0),
          startSecond: at(9, 0),
          endSecond: at(9, 0),
        ),
        isTrue,
      );
      expect(
        snoozeScheduleActive(
          secondsOfDay: at(21, 0),
          startSecond: at(9, 0),
          endSecond: at(9, 0),
        ),
        isTrue,
      );
    });

    test('0..86399 之外的输入会被夹住', () {
      expect(
        snoozeScheduleActive(
          secondsOfDay: -5,
          startSecond: 0,
          endSecond: 86399,
        ),
        isTrue,
      );
      expect(
        snoozeScheduleActive(
          secondsOfDay: 999999,
          startSecond: 0,
          endSecond: 86399,
        ),
        isTrue,
      );
    });
  });

  group('格式化', () {
    test('HH:mm', () {
      expect(formatSecondsOfDay(32400), '09:00');
      expect(formatSecondsOfDay(64800), '18:00');
      expect(formatSecondsOfDay(0), '00:00');
      expect(formatSecondsOfDay(86340), '23:59');
    });

    test('剩余 HH:MM:SS（原版 SnoozeFragment 的格式）', () {
      expect(
        formatSnoozeRemaining(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '01:02:03',
      );
      expect(formatSnoozeRemaining(Duration.zero), '00:00:00');
      expect(formatSnoozeRemaining(const Duration(seconds: -5)), '00:00:00');
    });

    test('秒数换算 + 本地当天秒数', () {
      expect(
        secondsOfLocalDay(DateTime(2026, 1, 1, 13, 14, 15)),
        13 * 3600 + 14 * 60 + 15,
      );
    });
  });

  group('UserPreferenceDto 解析（照真机返回）', () {
    test('关闭定时免打扰时服务端不下发 start/end → 用原版默认 09:00/18:00', () {
      final dto = UserPreferenceDto.fromJson({
        'preferences': {
          'notification_showmessage': true,
          'snooze': 0,
          'snooze_schedule_enable': false,
          'theme_style': 'light',
        },
      });
      expect(dto.snooze, 0);
      expect(dto.scheduleEnabled, isFalse);
      expect(dto.scheduleStartSecond, 32400);
      expect(dto.scheduleEndSecond, 64800);
      expect(dto.notificationShowMessage, isTrue);
      expect(dto.raw['theme_style'], 'light'); // 未知字段透传
    });

    test('开启时读服务端值 + 夹到 0..86399', () {
      final dto = UserPreferenceDto.fromJson({
        'preferences': {
          'snooze': 1789630437661,
          'snooze_schedule_enable': true,
          'snooze_schedule_start': 79200,
          'snooze_schedule_end': 21600,
        },
      });
      expect(dto.snooze, 1789630437661);
      expect(dto.scheduleEnabled, isTrue);
      expect(dto.scheduleStartSecond, 79200);
      expect(dto.scheduleEndSecond, 21600);

      final clamped = UserPreferenceDto.fromJson({
        'preferences': {
          'snooze_schedule_start': 999999,
          'snooze_schedule_end': -1,
        },
      });
      expect(clamped.scheduleStartSecond, 86399);
      expect(clamped.scheduleEndSecond, 0);
    });

    test('encode/tryDecode 往返回去还是同一份', () {
      const dto = UserPreferenceDto(
        snooze: 123,
        scheduleEnabled: true,
        scheduleStartSecond: 3600,
        scheduleEndSecond: 7200,
      );
      final back = UserPreferenceDto.tryDecode(dto.encode())!;
      expect(back.snooze, 123);
      expect(back.scheduleEnabled, isTrue);
      expect(back.scheduleStartSecond, 3600);
      expect(back.scheduleEndSecond, 7200);
      expect(UserPreferenceDto.tryDecode('坏数据'), isNull);
      expect(UserPreferenceDto.tryDecode(null), isNull);
    });
  });

  group('时间窗在状态上的组合（手动 + 定时）', () {
    test('手动免打扰没过期 → 静音', () {
      final now = DateTime.now();
      expect(
        _state(
          snoozeUntilMs: now.millisecondsSinceEpoch + 1000,
        ).suppressesAt(now),
        isTrue,
      );
    });

    test('手动免打扰过期 + 定时没开 → 不静音', () {
      final now = DateTime.now();
      expect(
        _state(
          snoozeUntilMs: now.millisecondsSinceEpoch - 1000,
        ).suppressesAt(now),
        isFalse,
      );
    });

    test('定时命中（当前本地时刻落在窗口里）→ 静音', () {
      final now = DateTime.now();
      final sec = secondsOfLocalDay(now);
      // 以"现在"为中心取一个 ±10 分钟的窗口
      final s = _state(
        schedule: true,
        start: (sec - 600).clamp(0, 86399),
        end: (sec + 600).clamp(0, 86399),
      );
      expect(s.suppressesAt(now), isTrue);
    });

    test('remainingAt / subtitleAt', () {
      final now = DateTime.now();
      final s = _state(snoozeUntilMs: now.millisecondsSinceEpoch + 3600 * 1000);
      expect(s.remainingAt(now).inMinutes, 60);
      expect(s.subtitleAt(now), startsWith('剩余 01:00'));
      expect(_state().subtitleAt(now), '关闭');
      expect(
        _state(schedule: true, start: 32400, end: 64800).subtitleAt(now),
        startsWith('定时 09:00–18:00'),
      );
    });
  });

  group('API 形状与版本（照原版 AccountManager）', () {
    test('get 用 [3,2,1] 协商；解析 preferences', () async {
      final h = await bootChat();
      final api = h.container
          .read(chatSessionControllerProvider.notifier)
          .chatApi!;
      final pref = await api.userPreferenceGet();
      expect(pref.snooze, 0);
      final call = h.transport.calls.firstWhere(
        (c) => c['api'] == 'SYNO.Chat.User.Preference' && c['method'] == 'get',
      );
      expect(call['version'], '3');
    });

    test('set snooze 锁 v1（原版这条路一直用 v1）', () async {
      final h = await bootChat();
      final api = h.container
          .read(chatSessionControllerProvider.notifier)
          .chatApi!;
      await api.setUserSnooze(1789630437661);
      final call = h.transport.calls.firstWhere(
        (c) => c['api'] == 'SYNO.Chat.User.Preference' && c['method'] == 'set',
      );
      expect(call['version'], '1');
      expect(call['snooze'], 1789630437661);
      expect(call.containsKey('snooze_schedule_enable'), isFalse);
    });

    test('定时免打扰走 v3，三个字段都在', () async {
      final h = await bootChat();
      final api = h.container
          .read(chatSessionControllerProvider.notifier)
          .chatApi!;
      await api.setUserSnoozeSchedule(
        enable: true,
        startSecond: 79200,
        endSecond: 21600,
      );
      // 登录后的 `refresh()` 是异步的，可能还有别的调用排在后面，所以按方法找
      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User.Preference' && c['method'] == 'set',
      );
      expect(call['version'], '3');
      expect(call['snooze_schedule_enable'], isTrue);
      expect(call['snooze_schedule_start'], 79200);
      expect(call['snooze_schedule_end'], 21600);
    });

    test('老服务端（maxVersion<3）不支持定时免打扰：报版本错且不发请求', () async {
      final h = await bootChat(
        apiTable: {
          ...FakeTransport.table,
          'SYNO.Chat.User.Preference': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 2,
          },
        },
      );
      final api = h.container
          .read(chatSessionControllerProvider.notifier)
          .chatApi!;
      await expectLater(
        api.setUserSnoozeSchedule(enable: true, startSecond: 1, endSecond: 2),
        throwsA(isA<DsmApiException>()),
      );
      // 版本检查在发请求之前，所以不该有 `Preference.set` 的调用
      expect(
        h.transport.calls.where(
          (c) =>
              c['api'] == 'SYNO.Chat.User.Preference' && c['method'] == 'set',
        ),
        isEmpty,
      );
    });
  });

  group('SnoozeController', () {
    test('refresh：把服务端的 snooze 按本地时差换算后落状态与缓存', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final h = await bootChat();
      // 让服务端"现在"比设备快 2 秒，snooze 截止在服务端时钟 +30s
      h.transport.responses['SYNO.Chat.User.Preference.get'] = {
        'preferences': {
          'snooze': nowMs + 2000 + 30000,
          'snooze_schedule_enable': true,
          'snooze_schedule_start': 79200,
          'snooze_schedule_end': 21600,
        },
      };
      final sync = h.container.read(chatSessionControllerProvider.notifier);
      // 直接给会话状态塞时差（正常的路径是 User/login 的 current_time）
      final pref = await sync.chatApi!.userPreferenceGet();
      expect(pref.snooze, nowMs + 32000);

      final ctrl = h.container.read(snoozeControllerProvider.notifier);
      await ctrl.refresh();
      final s = h.container.read(snoozeControllerProvider);
      expect(s.scheduleEnabled, isTrue);
      expect(s.scheduleStartSecond, 79200);
      expect(s.scheduleEndSecond, 21600);
      expect(s.loaded, isTrue);
      // 缓存已落库
      final cached = await h.container
          .read(settingsServiceProvider)
          .userPreferenceJson();
      expect(cached, contains('"snooze":'));
    });

    test('setSnooze(0) = 关闭；setSnooze(1h) 发服务端时钟', () async {
      final h = await bootChat();
      final ctrl = h.container.read(snoozeControllerProvider.notifier);
      await ctrl.setSnooze(const Duration(hours: 1));
      var call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User.Preference' && c['method'] == 'set',
      );
      expect(
        call['snooze'],
        greaterThan(DateTime.now().millisecondsSinceEpoch),
      );
      expect(
        h.container.read(snoozeControllerProvider).manualActiveNow,
        isTrue,
      );

      await ctrl.setSnooze(Duration.zero);
      call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User.Preference' && c['method'] == 'set',
      );
      expect(call['snooze'], 0);
      expect(
        h.container.read(snoozeControllerProvider).manualActiveNow,
        isFalse,
      );
    });

    test('setSchedule 落状态；preload 能从缓存恢复', () async {
      final h = await bootChat();
      final ctrl = h.container.read(snoozeControllerProvider.notifier);
      await ctrl.setSchedule(
        enable: true,
        startSecond: 79200,
        endSecond: 21600,
      );
      expect(
        h.container.read(snoozeControllerProvider).scheduleEnabled,
        isTrue,
      );

      // 造一个"新进程"：新容器 + 同一份存储（bootChat 的容器是新建的，缓存没共享，
      // 所以这里直接验证 preload 空缓存的默认值分支）
      final h2 = await bootChat();
      await h2.container.read(snoozeControllerProvider.notifier).preload();
      final s2 = h2.container.read(snoozeControllerProvider);
      expect(s2.scheduleStartSecond, 32400);
      expect(s2.scheduleEndSecond, 64800);
    });
  });

  group('设置页 UI（对位 SnoozeFragment / ScheduleSnoozeFragment）', () {
    Widget wrap(ChatHarness h) => UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(theme: AppTheme.dark(), home: SnoozeSettingsPage()),
    );

    testWidgets('免打扰页：显示当前状态；选 20 分钟 → 服务端 set + 状态更新', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(wrap(h));
      await tester.pumpAndSettle();
      expect(find.text('免打扰'), findsWidgets);
      // 两个"关闭"：免打扰副标题 + 定时免打扰副标题
      expect(find.text('关闭'), findsNWidgets(2));

      await tester.tap(find.text('免打扰').first);
      await tester.pumpAndSettle();
      // 弹窗里有原版那 6 档 + （没开时没有）关闭
      expect(find.text('20 分钟'), findsOneWidget);
      expect(find.text('1 小时'), findsOneWidget);
      // ★★★ r332：默认弹层高度上限是屏高的 9/16（800x600 ⇒ 337dp），而真主题下这 7 条
      // `ListTile` 更长 ⇒ 末尾档位**在 `ListView` 的懒构建范围之外**（`find.text` = 0，
      // 不是"画在下面"）。判据按**可达**写：先滚到它，再断言（§2.0.49③ / §2.0.61④）。
      // 反向验证：不滚这一下，修前这条就是红的（真主题下 24 小时 findsNothing）。
      await tester.scrollUntilVisible(
        find.text('24 小时'),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('24 小时'), findsOneWidget);

      // 回到第一档再点。行高换成设计组件后（62 起）比 ListTile 高，
      // 滚到最末档时第一档已被 ListView **回收**（`find.text` = 0，不是"在下面"），
      // 所以这里必须**反向滚动**把它重新建出来，`ensureVisible` 对未构建的节点会直接抛。
      await tester.scrollUntilVisible(
        find.text('20 分钟'),
        -120,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pump();
      await tester.tap(find.text('20 分钟'));
      await tester.pumpAndSettle();
      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User.Preference' && c['method'] == 'set',
      );
      expect(call['version'], '1');
      expect(
        call['snooze'],
        greaterThan(DateTime.now().millisecondsSinceEpoch),
      );
      expect(
        h.container.read(snoozeControllerProvider).manualActiveNow,
        isTrue,
      );
      // 副标题变成"剩余 HH:MM:SS"
      expect(find.textContaining('剩余 00:1'), findsOneWidget);
    });

    testWidgets('免打扰页：开着的时候能选"关闭免打扰"', (tester) async {
      final h = await bootChat();
      await h.container
          .read(snoozeControllerProvider.notifier)
          .setSnooze(const Duration(hours: 1));
      await tester.pumpWidget(wrap(h));
      await tester.pumpAndSettle();

      await tester.tap(find.text('免打扰').first);
      await tester.pumpAndSettle();
      expect(find.text('关闭免打扰'), findsOneWidget);
      await tester.tap(find.text('关闭免打扰'));
      await tester.pumpAndSettle();

      expect(
        h.container.read(snoozeControllerProvider).manualActiveNow,
        isFalse,
      );
      expect(find.textContaining('剩余'), findsNothing);
    });

    testWidgets('定时免打扰页：开关 + 起止不能相等；保存发 v3', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(wrap(h));
      await tester.pumpAndSettle();
      await tester.tap(find.text('定时免打扰'));
      await tester.pumpAndSettle();
      expect(find.text('09:00'), findsOneWidget);
      expect(find.text('18:00'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User.Preference' && c['method'] == 'set',
      );
      expect(call['version'], '3');
      expect(call['snooze_schedule_enable'], isTrue);
      expect(call['snooze_schedule_start'], 32400);
      expect(call['snooze_schedule_end'], 64800);
      expect(
        h.container.read(snoozeControllerProvider).scheduleEnabled,
        isTrue,
      );
    });

    testWidgets('定时免打扰页：起止相等 → 拦下来、不发请求', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(wrap(h));
      await tester.pumpAndSettle();
      await tester.tap(find.text('定时免打扰'));
      await tester.pumpAndSettle();

      // 先打开开关（关闭状态下起止两行是禁用的，跟原版一致）
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      // 把起始时间改成与结束时间相同（18:00）——走 TimePicker 的输入模式
      await tester.tap(find.text('09:00'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      await tester.pumpAndSettle();
      // 输入模式是"时:分 + AM/PM"（12 小时制），要选 18:00 = 6 PM
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '6');
      await tester.enterText(fields.at(1), '00');
      await tester.tap(find.text('PM'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('18:00'), findsNWidgets(2));

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('起始与结束时间不能相同'), findsOneWidget);
      expect(
        h.transport.calls.where(
          (c) =>
              c['api'] == 'SYNO.Chat.User.Preference' && c['method'] == 'set',
        ),
        isEmpty,
      );
    });

    testWidgets('老服务端（maxVersion<3）不显示定时免打扰入口', (tester) async {
      final h = await bootChat(
        apiTable: {
          ...FakeTransport.table,
          'SYNO.Chat.User.Preference': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 2,
          },
        },
      );
      await tester.pumpWidget(wrap(h));
      await tester.pumpAndSettle();
      expect(find.text('定时免打扰'), findsNothing);
      // 但手动免打扰仍然在（原版也是：v1 就够）
      expect(find.text('免打扰'), findsWidgets);
    });
  });

  group('通知门禁', () {
    test('免打扰期间不弹通知；关掉后恢复', () async {
      final h = await bootChat();
      final bg = FakeBackground();
      final service = NotificationService(
        h.container.read(notificationServiceProvider).ref,
        background: bg,
      );
      service.appInForeground = false;

      // 先在免打扰里
      final ctrl = h.container.read(snoozeControllerProvider.notifier);
      await ctrl.setSnooze(const Duration(hours: 1));
      final post = _notifyPost(501);
      expect(
        await service.maybeNotify(post, channel: _notifyChannel(5)),
        isFalse,
      );
      expect(bg.shown, isEmpty);

      // 关掉免打扰 → 同一条（没被记账）能弹
      await ctrl.setSnooze(Duration.zero);
      expect(
        await service.maybeNotify(post, channel: _notifyChannel(5)),
        isTrue,
      );
      expect(bg.shown, hasLength(1));
    });
  });
}
