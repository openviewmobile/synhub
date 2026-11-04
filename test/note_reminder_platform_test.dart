// Android 平台批 A：系统级待办提醒（AlarmManager + 通知渠道 `dsnote`）的离线用例。
//
// 覆盖三块：
//   ① `NoteReminderPlan` 纯计算（官方取消语义 / 单位换算只有一处 / 未来才排）；
//   ② MethodChannel 桥的载荷（`scheduleTodos` 发什么、平台缺失时返回 false）；
//   ③ `TodoReminderScheduler` 的「平台优先 + 明确回落前台 Timer」；
//   ④ 原生侧（Kotlin/manifest）**源级断言** —— Kotlin 无法离线单测，这里只钉死
//      关键调用/权限/接收器是否真的写进源码，真机判据见 docs/android-platform-a.md。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/features/notes/note_reminder.dart';
import 'package:synhub/src/features/notes/note_reminder_platform.dart';
import 'package:synhub/src/features/notes/note_reminder_service.dart';

const String kManifestPath = 'android/app/src/main/AndroidManifest.xml';
const String kPluginPath =
    'android/app/src/main/kotlin/com/openviewai/synhub/NoteReminderPlugin.kt';
const String kShareBridgePath =
    'android/app/src/main/kotlin/com/openviewai/synhub/ShareIntentBridge.kt';

TodoDto _todo({
  String id = 't1',
  String title = '写周报',
  bool done = false,
  int dueDate = -1,
  int reminderOffset = -1,
}) => TodoDto(
  objectId: id,
  title: title,
  done: done,
  dueDate: dueDate,
  reminderOffset: reminderOffset,
);

DateTime _at(int y, int m, int d, [int hh = 0, int mm = 0]) =>
    DateTime(y, m, d, hh, mm);

/// 离线假平台：记录收到的 plan，按 [result] 决定"排没排上"。
class _FakePlatform implements NoteReminderPlatform {
  _FakePlatform({this.result = true, NoteReminderStatus? status})
    : _status =
          status ??
          const NoteReminderStatus(
            supported: true,
            notificationsGranted: true,
            exactAlarmAllowed: true,
          );

  final bool result;
  final NoteReminderStatus _status;

  final List<NoteReminderPlan> plans = [];
  int requestCount = 0;

  @override
  Future<NoteReminderStatus> status() async => _status;

  @override
  Future<NoteReminderStatus> requestPermissions() async {
    requestCount++;
    return _status;
  }

  @override
  Future<bool> schedule(NoteReminderPlan plan) async {
    plans.add(plan);
    return result;
  }

  @override
  Future<void> cancelAll() async {}

  @override
  void dispose() {}
}

class _FakeTimer implements TodoTimerHandle {
  _FakeTimer(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool cancelled = false;

  void fire() {
    if (cancelled) return;
    callback();
  }

  @override
  void cancel() => cancelled = true;
}

void main() {
  // ★ 第 55 轮：这些用例验证的是**桥被调用时发什么载荷**（Android 语义），
  //   而能力层在 macOS 宿主上会正确地拦住 Android-only 桥 ⇒ 先把门打开
  //   （反向验证：门打开时确实去碰通道；见 `platform_capability_test.dart`）。
  setUp(() => debugForceCapabilityGate = true);
  tearDown(() => debugForceCapabilityGate = false);
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NoteReminderPlan · 官方取消语义', () {
    test('dueDate<=0（官方 -1）/ offset==-1 / 已完成 → 全部进 cancelledIds', () {
      final now = _at(2026, 9, 21, 9, 0);
      final plan = NoteReminderPlan.from([
        _todo(id: 'noDue', dueDate: -1, reminderOffset: 0),
        _todo(id: 'zeroDue', dueDate: 0, reminderOffset: 0),
        _todo(
          id: 'off',
          dueDate: now.millisecondsSinceEpoch + 600000,
          reminderOffset: -1,
        ),
        _todo(
          id: 'done',
          done: true,
          dueDate: now.millisecondsSinceEpoch + 600000,
          reminderOffset: 0,
        ),
      ], clock: () => now);
      expect(plan.alarms, isEmpty);
      expect(plan.cancelledIds.toSet(), {'noDue', 'zeroDue', 'off', 'done'});
    });

    test('只有"还没到点"的才排闹钟（官方只在未来才 setExact）', () {
      final now = _at(2026, 9, 21, 9, 0);
      final plan = NoteReminderPlan.from([
        _todo(
          id: 'future',
          dueDate: now.millisecondsSinceEpoch + 3600 * 1000,
          reminderOffset: 1800,
        ),
        _todo(
          id: 'past',
          dueDate: now.millisecondsSinceEpoch - 1000,
          reminderOffset: 0,
        ),
      ], clock: () => now);
      expect(plan.alarms.map((a) => a.id), ['future']);
      expect(plan.cancelledIds, ['past']);
      expect(
        plan.alarms.single.fireAtMillis,
        now.millisecondsSinceEpoch + 1800 * 1000,
      );
    });
  });

  group('NoteReminderPlan · 单位换算（只有一处）', () {
    test('fireAtMillis = 截止(毫秒) - 提前量(秒)*1000，不是把秒当毫秒', () {
      final plan = NoteReminderPlan.from([
        _todo(
          id: 'hour',
          title: '交房租',
          dueDate: 1700000000000,
          reminderOffset: 3600,
        ),
      ], clock: () => _at(2020, 1, 1));
      final alarm = plan.alarms.single;
      expect(alarm.fireAtMillis, 1700000000000 - 3600000);
      // 换算只发生在 planner（fireAtMillis），桥与 Kotlin 都不再做一次
      expect(
        TodoReminderPlanner.fireAtMillis(
          _todo(dueDate: 1700000000000, reminderOffset: 3600),
        ),
        alarm.fireAtMillis,
      );
      // 桥送出去的 dueDate 仍是毫秒原值、offset 仍是秒原值（供原生取消判定）
      expect(alarm.dueDateMillis, 1700000000000);
      expect(alarm.reminderOffsetSeconds, 3600);
    });

    test('计划里带全部待办快照（原生响铃时自己按 done/due 过滤逾期）', () {
      final plan = NoteReminderPlan.from(
        [
          _todo(id: 'a', title: 'A', dueDate: 1700000000000, reminderOffset: 0),
          _todo(id: 'b', title: 'B', dueDate: -1),
          _todo(id: 'c', title: 'C', done: true, dueDate: 1700000000000),
        ],
        settings: const TodoOverdueSettings(enabled: true, hour: 7, minute: 30),
        clock: () => _at(2020, 1, 1),
      );
      expect(plan.todos.map((t) => t.id), ['a', 'b', 'c']);
      expect(plan.todos.map((t) => t.done), [false, false, true]);
      expect(plan.overdueEnabled, isTrue);
      expect(plan.overdueHour, 7);
      expect(plan.overdueMinute, 30);
    });
  });

  group('MethodChannel 桥', () {
    late MethodChannel channel;
    late MethodChannelNoteReminderPlatform platform;
    late List<MethodCall> calls;
    var seq = 0;

    setUp(() {
      channel = MethodChannel('synhub/note_reminder.test.${seq++}');
      platform = MethodChannelNoteReminderPlatform(channel);
      calls = [];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('scheduleTodos 把 plan 原样送出（alarms/cancelIds/todos/overdue）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      final plan = NoteReminderPlan.from(
        [
          _todo(
            id: 'future',
            title: 'F',
            dueDate: 1700000000000,
            reminderOffset: 3600,
          ),
          _todo(id: 'off', dueDate: 1700000000000, reminderOffset: -1),
        ],
        settings: const TodoOverdueSettings(enabled: true, hour: 8, minute: 15),
        clock: () => _at(2020, 1, 1),
      );
      expect(await platform.schedule(plan), isTrue);
      expect(calls.single.method, 'scheduleTodos');
      final args = calls.single.arguments as Map<Object?, Object?>;
      final alarms = args['alarms'] as List<Object?>;
      expect(alarms.length, 1);
      final first = alarms.single as Map<Object?, Object?>;
      expect(first['id'], 'future');
      expect(first['fireAtMillis'], 1699996400000);
      expect(args['cancelIds'], ['off']);
      expect((args['todos'] as List<Object?>).length, 2);
      expect(args['overdueEnabled'], isTrue);
      expect(args['overdueHour'], 8);
      expect(args['overdueMinute'], 15);
    });

    test('通道缺失（纯桌面/单测）→ schedule 返回 false，绝不假装成功', () async {
      final bare = MethodChannel('synhub/note_reminder.absent');
      final p = MethodChannelNoteReminderPlatform(bare);
      expect(
        await p.schedule(
          const NoteReminderPlan(alarms: [], cancelledIds: [], todos: []),
        ),
        isFalse,
      );
    });

    test(
      'status 解析 supported/notificationsGranted/exactAlarmAllowed',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'status');
              return {
                'supported': true,
                'notificationsGranted': false,
                'exactAlarmAllowed': false,
              };
            });
        final s = await platform.status();
        expect(s.supported, isTrue);
        expect(s.notificationsGranted, isFalse);
        expect(s.exactAlarmAllowed, isFalse);
        // 未授权精确闹钟 / 通知 → 不许静默当成 ready
        expect(s.ready, isFalse);
      },
    );

    test('通道缺失时 status 是"不支持"，设置页据此回落前台文案', () async {
      final s = await MethodChannelNoteReminderPlatform(
        MethodChannel('synhub/note_reminder.absent2'),
      ).status();
      expect(s.supported, isFalse);
      expect(s.ready, isFalse);
    });
  });

  group('TodoReminderScheduler · 平台优先 + 明确回落', () {
    test('平台成功 → 不排前台 Timer（否则会响两遍）', () async {
      final platform = _FakePlatform();
      final timers = <_FakeTimer>[];
      final scheduler = TodoReminderScheduler(
        onEvent: (_) {},
        clock: () => _at(2026, 9, 21, 9, 0),
        timerFactory: (d, cb) {
          final t = _FakeTimer(d, cb);
          timers.add(t);
          return t;
        },
        platform: platform,
      );
      scheduler.update([
        _todo(
          id: 'x',
          dueDate: _at(2026, 9, 21, 10, 0).millisecondsSinceEpoch,
          reminderOffset: 0,
        ),
      ]);
      await pumpEventQueue();
      expect(platform.plans.length, 1);
      expect(platform.plans.single.alarms.single.id, 'x');
      expect(scheduler.platformScheduled, isTrue);
      expect(timers, isEmpty);
    });

    test('平台说"不行"（通道缺失/未授权）→ 回落到前台 Timer（回落路径不许删）', () async {
      final platform = _FakePlatform(result: false);
      final timers = <_FakeTimer>[];
      final events = <TodoReminderEvent>[];
      final now = _at(2026, 9, 21, 9, 0);
      final scheduler = TodoReminderScheduler(
        onEvent: events.add,
        clock: () => now,
        timerFactory: (d, cb) {
          final t = _FakeTimer(d, cb);
          timers.add(t);
          return t;
        },
        platform: platform,
      );
      scheduler.update(
        [
          _todo(
            id: 'x',
            dueDate: now.millisecondsSinceEpoch + 3600 * 1000,
            reminderOffset: 1800,
          ),
        ],
        settings: const TodoOverdueSettings(enabled: true, hour: 9, minute: 0),
      );
      await pumpEventQueue();
      expect(scheduler.platformScheduled, isFalse);
      // 1 条待办 + 1 个每日逾期（与批次 B 行为一致）
      expect(timers.length, 2);
      timers.first.fire();
      expect(events.single.todo!.objectId, 'x');
    });

    test('没有平台（批次 B 原样）→ 直接用前台 Timer', () {
      final timers = <_FakeTimer>[];
      final scheduler = TodoReminderScheduler(
        onEvent: (_) {},
        clock: () => _at(2026, 9, 21, 9, 0),
        timerFactory: (d, cb) {
          final t = _FakeTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      scheduler.update([
        _todo(
          id: 'x',
          dueDate: _at(2026, 9, 21, 10, 0).millisecondsSinceEpoch,
          reminderOffset: 0,
        ),
      ]);
      expect(timers.length, 1);
      expect(scheduler.platformScheduled, isFalse);
    });
  });

  group('AndroidManifest · 系统级提醒权限与接收器', () {
    late final String manifest;

    setUpAll(() {
      manifest = File(kManifestPath).readAsStringSync();
    });

    test(
      'SCHEDULE_EXACT_ALARM / POST_NOTIFICATIONS / RECEIVE_BOOT_COMPLETED 都在',
      () {
        for (final p in const [
          'android.permission.SCHEDULE_EXACT_ALARM',
          'android.permission.POST_NOTIFICATIONS',
          'android.permission.RECEIVE_BOOT_COMPLETED',
        ]) {
          expect(manifest, contains(p), reason: '缺少 $p');
        }
      },
    );

    test('三个 receiver 都注册：单条闹钟 / 逾期汇总 / 开机重排', () {
      for (final r in const [
        '.NoteReminderReceiver',
        '.NoteReminderOverdueReceiver',
        '.NoteReminderBootReceiver',
      ]) {
        expect(manifest, contains('android:name="$r"'), reason: '缺少 $r');
      }
      final boot = RegExp(
        r'<receiver\b(?:(?!</receiver>).)*?android:name="\.NoteReminderBootReceiver"(?:(?!</receiver>).)*?</receiver>',
        dotAll: true,
      ).firstMatch(manifest);
      expect(boot, isNotNull);
      expect(boot!.group(0), contains('android.intent.action.BOOT_COMPLETED'));
      expect(
        boot.group(0),
        contains('android.intent.action.MY_PACKAGE_REPLACED'),
      );
    });
  });

  group('Kotlin 源级断言（无法离线单测，真机判据见 docs/android-platform-a.md）', () {
    late final String plugin;
    late final String shareBridge;

    setUpAll(() {
      plugin = File(kPluginPath).readAsStringSync();
      shareBridge = File(kShareBridgePath).readAsStringSync();
    });

    test('Plugin：精确闹钟 + 不精确降级 + 每日重复 + 官方渠道 dsnote', () {
      expect(plugin, contains('setExactAndAllowWhileIdle'));
      expect(plugin, contains('canScheduleExactAlarms'));
      // 精确闹钟未授权时的**降级**（不是静默失败）
      expect(plugin, contains('setAndAllowWhileIdle'));
      // 官方 setInexactRepeating(..., 24h)
      expect(plugin, contains('setInexactRepeating'));
      expect(plugin, contains('AlarmManager.INTERVAL_DAY'));
      expect(plugin, contains('"dsnote"'));
      // 官方取消语义：dueDate<=0（我们的 -1）或 offset == -1 → 撤销
      expect(plugin, contains('due <= 0L || offset == -1'));
      // 通知发不出去 → 明确返回 false，让 Dart 回落
      expect(plugin, contains('return false'));
    });

    test('分享桥：ACTION_SEND_MULTIPLE 收全部附件，不是只取第一个', () {
      expect(shareBridge, contains('Intent.ACTION_SEND_MULTIPLE'));
      expect(shareBridge, contains('getParcelableArrayListExtra'));
      expect(shareBridge, contains('uris.addAll(many)'));
      // 只取第一个 / 截断成 1 个是 bug
      expect(
        RegExp(
          r'uris\.take\(1\)|\.first\(\)\s*\)|take\(1\)',
        ).hasMatch(shareBridge),
        isFalse,
        reason: '多文件分享不能只取第一个',
      );
      // 三类 intent 都要有：单文件 / 多文件 / 文本
      expect(shareBridge, contains('Intent.ACTION_SEND'));
      expect(shareBridge, contains('Intent.EXTRA_TEXT'));
      expect(shareBridge, contains('Intent.EXTRA_STREAM'));
    });
  });
}
