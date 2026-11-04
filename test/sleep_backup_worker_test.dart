// ★★ ③Drive 第 222 轮 **D84「休眠备份」60min 常驻 worker** 的用例。
//
// 覆盖：官方周期常量、唤醒计划（过时/未过时/处理中/退避）、JSON 往返、
// 通道契约（`schedule`/`cancel`/`isScheduled` 的实参）、记录型替身。
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

import 'package:synhub/src/features/photos/sleep_backup.dart';
import 'package:synhub/src/features/photos/sleep_backup_worker.dart';

const int kHour = 3600 * 1000;

SleepBackupPrefs _prefs({
  int lastBackupAtMs = 0,
  int nextShowAtMs = 0,
  int backoffMs = 24 * kHour,
}) => SleepBackupPrefs(
  lastBackupAtMs: lastBackupAtMs,
  nextShowAtMs: nextShowAtMs,
  backoffMs: backoffMs,
);

SleepBackupRuntime _rt({int queueSize = 0, bool processing = false}) =>
    SleepBackupRuntime(queueSize: queueSize, processing: processing);

void main() {
  // ★ 第 55 轮：这些用例验证的是**桥被调用时发什么载荷**（Android 语义），
  //   而能力层在 macOS 宿主上会正确地拦住 Android-only 桥 ⇒ 先把门打开
  //   （反向验证：门打开时确实去碰通道；见 `platform_capability_test.dart`）。
  setUp(() => debugForceCapabilityGate = true);
  tearDown(() => debugForceCapabilityGate = false);
  TestWidgetsFlutterBinding.ensureInitialized();

  group('D84 常驻 worker · 常量', () {
    test('60min / flex 10min，且与官方判定用的周期一致', () {
      expect(kSleepBackupWorkerIntervalMinutes, 60);
      expect(kSleepBackupWorkerFlexMinutes, 10);
      expect(
        kSleepBackupWorkerIntervalMinutes,
        kSleepBackupCheckIntervalMinutes,
        reason: 'Dart 前台定时器与原生周期任务必须是同一个周期',
      );
    });
  });

  group('D84 常驻 worker · 唤醒计划', () {
    test('24h 没过时 ⇒ showAt 落在 nextShowAt（不提前打扰）', () {
      final now = 100 * kHour;
      final plan = planSleepBackupWorkerWake(
        prefs: _prefs(lastBackupAtMs: now - 1000, nextShowAtMs: now + 5 * kHour),
        runtime: _rt(),
        nowMs: now,
        title: 'T',
        text: 'X',
      );
      expect(plan.outdated, isFalse);
      expect(plan.showAtMs, now + 5 * kHour);
    });

    test('过时（>24h）且已到点 ⇒ 立刻可提醒', () {
      final now = 100 * kHour;
      final plan = planSleepBackupWorkerWake(
        prefs: _prefs(lastBackupAtMs: now - 25 * kHour, nextShowAtMs: now - 1),
        runtime: _rt(queueSize: 3),
        nowMs: now,
        title: 'T',
        text: 'X',
      );
      expect(plan.outdated, isTrue);
      expect(plan.showAtMs, now, reason: '到点就是 now，worker 一醒就发');
    });

    test('正在处理中 ⇒ 不打扰（showAt 推迟到 nextShowAt）', () {
      final now = 100 * kHour;
      final plan = planSleepBackupWorkerWake(
        prefs: _prefs(lastBackupAtMs: now - 30 * kHour, nextShowAtMs: now + kHour),
        runtime: _rt(queueSize: 9, processing: true),
        nowMs: now,
        title: 'T',
        text: 'X',
      );
      expect(plan.showAtMs, now + kHour);
    });

    test('退避值随判定带回（worker 只负责到点发）', () {
      final now = 10 * kHour;
      final plan = planSleepBackupWorkerWake(
        prefs: _prefs(lastBackupAtMs: now, backoffMs: 48 * kHour),
        runtime: _rt(queueSize: 1),
        nowMs: now,
        title: 'T',
        text: 'X',
      );
      // 官方退避封顶 3 天（`0xf731400`）⇒ 传 48h 会被夹到 72h
      expect(plan.backoffMs, 72 * kHour);
      expect(plan.nextShowAtMs, greaterThan(now));
    });

    test('JSON 往返（原生按这个字段名读）', () {
      const plan = SleepBackupWorkerPlan(
        showAtMs: 11,
        nextShowAtMs: 22,
        backoffMs: 33,
        title: '标题',
        text: '正文',
        outdated: true,
      );
      final back = SleepBackupWorkerPlan.fromJson(
        Map<String, Object?>.from(jsonDecode(plan.encode()) as Map),
      );
      expect(back.showAtMs, 11);
      expect(back.nextShowAtMs, 22);
      expect(back.backoffMs, 33);
      expect(back.title, '标题');
      expect(back.text, '正文');
      expect(back.outdated, isTrue);
    });
  });

  group('D84 常驻 worker · 通道契约', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('synhub/sleep_backup_worker'),
            (call) async {
              calls.add(call);
              return true;
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('synhub/sleep_backup_worker'),
            null,
          );
    });

    test('schedule 带上周期常量与 plan 字符串', () async {
      const s = MethodChannelSleepBackupWorker();
      final ok = await s.schedule(
        const SleepBackupWorkerPlan(
          showAtMs: 1,
          nextShowAtMs: 2,
          backoffMs: 3,
          title: 'T',
          text: 'X',
          outdated: false,
        ),
      );
      expect(ok, isTrue);
      expect(calls.single.method, 'schedule');
      final args = calls.single.arguments as Map;
      expect(args['interval_minutes'], 60);
      expect(args['flex_minutes'], 10);
      expect('${args['plan']}', contains('"show_at_ms":1'));
    });

    test('cancel / isScheduled 走同名方法', () async {
      const s = MethodChannelSleepBackupWorker();
      await s.cancel();
      await s.isScheduled();
      expect(calls.map((c) => c.method), ['cancel', 'isScheduled']);
    });

    test('记录型替身记录计划并可取消', () async {
      final r = RecordingSleepBackupWorkerScheduler();
      await r.schedule(
        const SleepBackupWorkerPlan(
          showAtMs: 1,
          nextShowAtMs: 2,
          backoffMs: 3,
          title: 'T',
          text: 'X',
          outdated: true,
        ),
      );
      expect(await r.isScheduled(), isTrue);
      expect(r.plans.single.title, 'T');
      await r.cancel();
      expect(await r.isScheduled(), isFalse);
      expect(r.calls, ['schedule', 'isScheduled', 'cancel', 'isScheduled']);
    });
  });
}
