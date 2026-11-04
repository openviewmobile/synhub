// ★★ ③Drive 第 214 轮 **D84「休眠备份（专注备份和同步 / sleep mode）」** 的离线用例。
//
// 官方判据逐字（`SynologyDrive 3.9.0-1113` smali）：
//   * `SleepBackupUtil.hasOutDatedPBTask()`：`now - photoBackupStartTime > 0x5265c00`
//     **或**（`getQueueSize() > 0` 且服务没在跑）；
//   * `SleepBackupNotificationUtil.shouldPushNotification()`：`nextShowAt <= now`；
//   * `pushNotificationIfNecessary()`：`过时 && !正在跑 && 到点` → 发 + 推进时间；
//   * `updatePreferenceNotificationTimeAndBackOff()`：`nextShowAt = now + backoff`，
//     `backoff = min(backoff + 0x5265c00, 0xf731400)`（+24h，封顶 3 天）；
//   * `getSleepBackupNotificationBackOff()` 默认 `0x5265c00`（24h）；
//   * worker：`PeriodicWorkRequest("SleepTimeBackupWorker", 60min, flex 10min)`。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/downloads/download_notification_sink.dart';
import 'package:synhub/src/features/photos/sleep_backup.dart';
import 'package:synhub/src/features/photos/sleep_backup_platform.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/photos/sleep_backup_page.dart';

const int _h = 3600 * 1000;

class _FakeSink implements DownloadNotificationSink {
  _FakeSink({this.allowed = true});

  bool allowed;
  final List<({int id, String title, String text})> shown = [];

  @override
  Future<bool> available() async => allowed;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String text,
  }) async => shown.add((id: id, title: title, text: text));
}

void main() {
  group('D84 · 常量必须与官方十六进制一致', () {
    test('24h / 3 天 / 周期 / 弹性 / 默认退避', () {
      expect(kSleepBackupDayMs, 0x5265c00);
      expect(kSleepBackupBackoffMaxMs, 0xf731400);
      expect(kSleepBackupBackoffDefaultMs, 0x5265c00);
      expect(kSleepBackupCheckIntervalMinutes, 60);
      expect(kSleepBackupCheckFlexMinutes, 10);
    });
  });

  group('D84 · 过时判据（官方 hasOutDatedPBTask）', () {
    test('超过 24 小时没备份 ⇒ 过时', () {
      expect(
        sleepBackupOutdated(nowMs: 100 * _h, lastBackupAtMs: 100 * _h - _h),
        isFalse,
        reason: '刚好 1 小时前跑过 → 不过时',
      );
      expect(
        sleepBackupOutdated(
          nowMs: 100 * _h,
          lastBackupAtMs: 100 * _h - (24 * _h + 1),
        ),
        isTrue,
      );
      // 边界：正好 24 小时（官方是 `> 0x5265c00`，不是 >=）
      expect(
        sleepBackupOutdated(nowMs: 100 * _h, lastBackupAtMs: 76 * _h),
        isFalse,
      );
    });

    test('队列有积压且没在跑 ⇒ 过时；在跑就不算', () {
      expect(
        sleepBackupOutdated(
          nowMs: 100 * _h,
          lastBackupAtMs: 100 * _h,
          queueSize: 3,
          processing: false,
        ),
        isTrue,
      );
      expect(
        sleepBackupOutdated(
          nowMs: 100 * _h,
          lastBackupAtMs: 100 * _h,
          queueSize: 3,
          processing: true,
        ),
        isFalse,
      );
    });

    test('从没备份过（lastBackupAt = 0）⇒ 过时', () {
      expect(sleepBackupOutdated(nowMs: 1 * _h, lastBackupAtMs: 0), isTrue);
    });
  });

  group('D84 · 退避（官方 updatePreferenceNotificationTimeAndBackOff）', () {
    test('+24h 递增，封顶 3 天', () {
      expect(sleepBackupNextBackoff(kSleepBackupDayMs), 2 * kSleepBackupDayMs);
      expect(sleepBackupNextBackoff(2 * kSleepBackupDayMs), 3 * kSleepBackupDayMs);
      expect(
        sleepBackupNextBackoff(3 * kSleepBackupDayMs),
        3 * kSleepBackupDayMs,
        reason: '封顶 0xf731400（3 天）',
      );
      expect(
        sleepBackupNextBackoff(kSleepBackupBackoffMaxMs),
        kSleepBackupBackoffMaxMs,
      );
    });
  });

  group('D84 · 提醒决策（官方 pushNotificationIfNecessary）', () {
    test('过时 + 没在跑 + 到点 ⇒ 发，并把时间推进 now+backoff', () {
      final now = 500 * _h;
      final d = decideSleepBackupReminder(
        nowMs: now,
        nextShowAtMs: now - 1,
        backoffMs: kSleepBackupDayMs,
        outdated: true,
        processing: false,
      );
      expect(d.push, isTrue);
      expect(d.nextShowAtMs, now + kSleepBackupDayMs);
      expect(d.backoffMs, 2 * kSleepBackupDayMs);
    });

    test('没到点 ⇒ 不发，且状态原样（不偷偷改）', () {
      final now = 500 * _h;
      final d = decideSleepBackupReminder(
        nowMs: now,
        nextShowAtMs: now + 1,
        backoffMs: 2 * kSleepBackupDayMs,
        outdated: true,
        processing: false,
      );
      expect(d.push, isFalse);
      expect(d.nextShowAtMs, now + 1);
      expect(d.backoffMs, 2 * kSleepBackupDayMs);
    });

    test('没过时 / 正在跑 ⇒ 不发（官方两个前置条件）', () {
      final now = 500 * _h;
      for (final d in [
        decideSleepBackupReminder(
          nowMs: now,
          nextShowAtMs: 0,
          backoffMs: kSleepBackupDayMs,
          outdated: false,
          processing: false,
        ),
        decideSleepBackupReminder(
          nowMs: now,
          nextShowAtMs: 0,
          backoffMs: kSleepBackupDayMs,
          outdated: true,
          processing: true,
        ),
      ]) {
        expect(d.push, isFalse);
      }
    });

    test('退避为 0（没存过）时按官方默认 24h 起算', () {
      final now = 500 * _h;
      final d = decideSleepBackupReminder(
        nowMs: now,
        nextShowAtMs: 0,
        backoffMs: 0,
        outdated: true,
        processing: false,
      );
      expect(d.push, isTrue);
      expect(d.nextShowAtMs, now + kSleepBackupDayMs);
      expect(d.backoffMs, 2 * kSleepBackupDayMs);
    });

    test('第一次提醒 → 第二次要等 24h（退避生效）', () {
      var prefs = const SleepBackupPrefs(lastBackupAtMs: 0);
      final t0 = 1000 * _h;
      final d1 = decideSleepBackupReminder(
        nowMs: t0,
        nextShowAtMs: prefs.nextShowAtMs,
        backoffMs: prefs.backoffMs,
        outdated: true,
        processing: false,
      );
      expect(d1.push, isTrue);
      prefs = prefs.copyWith(
        nextShowAtMs: d1.nextShowAtMs,
        backoffMs: d1.backoffMs,
      );
      // 一小时后：不过时了（刚提醒过？不 —— 过时是独立判据），但**没到点**
      final d2 = decideSleepBackupReminder(
        nowMs: t0 + _h,
        nextShowAtMs: prefs.nextShowAtMs,
        backoffMs: prefs.backoffMs,
        outdated: true,
        processing: false,
      );
      expect(d2.push, isFalse);
    });
  });

  group('D84 · 持久化（官方 PreferenceUtilities 三个键）', () {
    test('JSON 键名与官方 SharedPreferences 键一致', () {
      const p = SleepBackupPrefs(
        enabled: true,
        nextShowAtMs: 11,
        backoffMs: 22,
        lastBackupAtMs: 33,
      );
      final j = p.toJson();
      expect(j['next_show_sleep_backup_notification_time'], 11);
      expect(j['sleep_backup_notification_backoff'], 22);
      // 回归：读回一致
      final back = SleepBackupPrefs.fromJson(
        (jsonDecode(jsonEncode(j)) as Map).cast<String, dynamic>(),
      );
      expect(back.enabled, isTrue);
      expect(back.nextShowAtMs, 11);
      expect(back.backoffMs, 22);
      expect(back.lastBackupAtMs, 33);
    });

    test('存储为空/垃圾 ⇒ 默认值（enabled=false，退避 24h）', () async {
      final store = MemorySleepBackupStore();
      final p = await store.read();
      expect(p.enabled, isFalse);
      expect(p.backoffMs, kSleepBackupBackoffDefaultMs);
      expect(p.nextShowAtMs, 0);
    });

    test('notifier：setEnabled / markBackupFinished / 决策应用 / 立刻试用', () async {
      final store = MemorySleepBackupStore();
      final c = ProviderContainer(
        overrides: [sleepBackupStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(sleepBackupPrefsProvider.notifier);

      await n.setEnabled(true);
      expect(c.read(sleepBackupPrefsProvider).enabled, isTrue);
      expect(store.prefs.enabled, isTrue);

      await n.markBackupFinished(1234);
      expect(store.prefs.lastBackupAtMs, 1234);

      await n.applyReminderDecision(
        const SleepBackupReminderDecision(
          push: true,
          nextShowAtMs: 99,
          backoffMs: 88,
        ),
      );
      expect(store.prefs.nextShowAtMs, 99);
      expect(store.prefs.backoffMs, 88);

      await n.armReminderNow();
      expect(store.prefs.nextShowAtMs, 0);
      expect(store.prefs.enabled, isTrue, reason: '其它字段不许被清掉');
    });

    test('preload 把落盘的读回内存', () async {
      final store = MemorySleepBackupStore(
        const SleepBackupPrefs(
          enabled: true,
          nextShowAtMs: 7,
          lastBackupAtMs: 8,
        ),
      );
      final c = ProviderContainer(
        overrides: [sleepBackupStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      expect(c.read(sleepBackupPrefsProvider).enabled, isFalse);
      await c.read(sleepBackupPrefsProvider.notifier).preload();
      expect(c.read(sleepBackupPrefsProvider).enabled, isTrue);
      expect(c.read(sleepBackupPrefsProvider).nextShowAtMs, 7);
    });
  });

  group('D84 · 检查编排（发 + 落盘 / 不发不落盘）', () {
    test('到点且过时 ⇒ push 一次并 persist 一次', () async {
      var pushed = 0;
      SleepBackupReminderDecision? persisted;
      final d = await runSleepBackupReminderCheck(
        prefs: const SleepBackupPrefs(lastBackupAtMs: 0),
        runtime: const SleepBackupRuntime(queueSize: 5),
        nowMs: 10 * _h,
        push: () async => pushed++,
        persist: (x) async => persisted = x,
      );
      expect(d.push, isTrue);
      expect(pushed, 1);
      expect(persisted, isNotNull);
      expect(persisted!.nextShowAtMs, 10 * _h + kSleepBackupDayMs);
    });

    test('没过时 ⇒ 既不发也不落盘', () async {
      var pushed = 0;
      var persisted = 0;
      final now = 10 * _h;
      final d = await runSleepBackupReminderCheck(
        prefs: SleepBackupPrefs(lastBackupAtMs: now - _h),
        runtime: const SleepBackupRuntime(),
        nowMs: now,
        push: () async => pushed++,
        persist: (_) async => persisted++,
      );
      expect(d.push, isFalse);
      expect(pushed, 0);
      expect(persisted, 0);
    });
  });

  group('D84 · 视图汇总（页面显示什么）', () {
    test('状态优先级：在跑 > 错误停止 > 完成', () {
      final now = 10 * _h;
      const prefs = SleepBackupPrefs(lastBackupAtMs: 0);
      expect(
        SleepBackupView.of(
          prefs: prefs,
          runtime: const SleepBackupRuntime(processing: true),
          nowMs: now,
        ).statusText,
        '正在备份和同步...',
      );
      expect(
        SleepBackupView.of(
          prefs: prefs,
          runtime: const SleepBackupRuntime(errors: ['a.docx']),
          nowMs: now,
        ).statusText,
        '备份和同步已停止',
      );
      expect(
        SleepBackupView.of(
          prefs: prefs,
          runtime: const SleepBackupRuntime(
            status: SleepBackupStatus.processing,
          ),
          nowMs: now,
        ).statusText,
        '备份和同步已完成',
        reason: '跑完（processing=false）但上次是 processing ⇒ 已完成',
      );
    });

    test('倒计时文案逐字对齐官方资源', () {
      expect(
        SleepBackupView.of(
          prefs: const SleepBackupPrefs(),
          runtime: const SleepBackupRuntime(countdownSeconds: 5),
          nowMs: 1,
        ).countdownText,
        '屏幕将在 5 秒内后变暗。',
      );
      expect(
        SleepBackupView.of(
          prefs: const SleepBackupPrefs(),
          runtime: const SleepBackupRuntime(),
          nowMs: 1,
        ).countdownText,
        isEmpty,
      );
    });
  });

  group('D84 · 页面', () {
    Future<void> pump(
      WidgetTester tester,
      ProviderContainer c,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: SleepBackupPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('三种状态文案 + 剩余量 + 引导三条（逐字官方）', (tester) async {
      final c = ProviderContainer(
        overrides: [
          sleepBackupStoreProvider.overrideWithValue(MemorySleepBackupStore()),
          sleepBackupRuntimeProvider.overrideWithValue(
            const SleepBackupRuntime(
              queueSize: 42,
              processing: true,
              status: SleepBackupStatus.processing,
              errors: ['photo-1.jpg', 'photo-2.jpg'],
              countdownSeconds: 3,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      await pump(tester, c);
      expect(find.text('正在备份和同步...'), findsOneWidget);
      expect(find.text('还剩 42 个文件待备份'), findsOneWidget);
      expect(find.text(kSleepBackupStopDesc), findsOneWidget);
      expect(find.text('· photo-1.jpg'), findsOneWidget);
      for (final line in kSleepBackupGuideLines) {
        expect(find.text(line), findsOneWidget, reason: line);
        // ★ r353 DA9：引导**不许**让用户去操作"别的 App"（官方原文是自指，
        //   照抄会让用户找不到那个 App —— 本机确实没装 Synology Drive）。
        expect(line.contains('Synology Drive'), isFalse, reason: line);
      }
      // 自证：这条判据不是"永远为空"（真机缺陷原文形态必须会被抓到）
      expect('Synology Drive will run tasks while the screen is dimmed.'.contains('Synology Drive'), isTrue);
      // 倒计时是**活的**：3 → 2（1 秒后）
      expect(find.text('屏幕将在 3 秒内后变暗。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('屏幕将在 2 秒内后变暗。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const Key('sleep-backup-countdown')), findsNothing);
    });

    testWidgets('启用/停用按钮互斥且落盘', (tester) async {
      final store = MemorySleepBackupStore();
      final c = ProviderContainer(
        overrides: [sleepBackupStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      await pump(tester, c);
      expect(find.text('未启用'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sleep-backup-enable')));
      await tester.pump();
      expect(find.text('已启用（状态会带给提醒调度）'), findsOneWidget);
      expect(store.prefs.enabled, isTrue);
      await tester.tap(find.byKey(const Key('sleep-backup-disable')));
      await tester.pump();
      expect(find.text('未启用'), findsOneWidget);
      expect(store.prefs.enabled, isFalse);
    });

    testWidgets('"试用提醒"：过时 → 走通知桥；标题是我方 App 名（DA9 去第三方品牌）', (tester) async {
      final sink = _FakeSink();
      final store = MemorySleepBackupStore();
      final c = ProviderContainer(
        overrides: [
          sleepBackupStoreProvider.overrideWithValue(store),
          sleepBackupNotificationSinkProvider.overrideWithValue(sink),
          sleepBackupRuntimeProvider.overrideWithValue(
            const SleepBackupRuntime(queueSize: 9),
          ),
        ],
      );
      addTearDown(c.dispose);
      await pump(tester, c);
      await tester.tap(find.byKey(const Key('sleep-backup-test-reminder')));
      await tester.pump();
      expect(sink.shown, hasLength(1));
      // ★ r353 DA9：官方资源里这条是**自指**（`sleepmode_notification_titile` = "Synology Drive 提醒"），
      //   移植后必须改成我方 App 名 —— 否则本机（**没装 Synology Drive**）会弹出顶着别家 App 名的通知。
      expect(sink.shown.single.title, 'SynHub 提醒');
      expect(
        sink.shown.single.text,
        '还有未完成的任务。前往更多 > 备份和同步任务，启用专注备份和同步以利用闲置时间运行任务。',
      );
      // 发过之后退避推进（官方 updatePreferenceNotificationTimeAndBackOff）
      expect(store.prefs.nextShowAtMs, greaterThan(0));
      expect(store.prefs.backoffMs, 2 * kSleepBackupDayMs);
    });

    testWidgets('启用 + 正在跑 ⇒ 调暗屏幕并保持常亮；停用 ⇒ 恢复（官方 handleScreenDimming）', (
      tester,
    ) async {
      final screen = RecordingSleepBackupScreen();
      final store = MemorySleepBackupStore(
        const SleepBackupPrefs(enabled: true, lastBackupAtMs: 1),
      );
      final c = ProviderContainer(
        overrides: [
          sleepBackupStoreProvider.overrideWithValue(store),
          sleepBackupScreenProvider.overrideWithValue(screen),
          sleepBackupRuntimeProvider.overrideWithValue(
            const SleepBackupRuntime(processing: true, queueSize: 3),
          ),
        ],
      );
      addTearDown(c.dispose);
      await pump(tester, c);
      expect(screen.dims, isNotEmpty, reason: '跑起来就该调暗');
      expect(screen.dims.last, 0.02);
      expect(screen.keepOns, [true]);

      // 停用 ⇒ 亮度还给系统
      await tester.tap(find.byKey(const Key('sleep-backup-disable')));
      await tester.pump();
      expect(screen.clears, 1);
      expect(screen.keepOns.last, isFalse);

      // 销毁页面再恢复一次（幂等：已经恢复过就不再动）
      await tester.pumpWidget(const SizedBox());
      expect(screen.clears, 1);
    });

    testWidgets('原生通道不可用 ⇒ fail-soft，页面照样能用', (tester) async {
      final screen = RecordingSleepBackupScreen()..available = false;
      final c = ProviderContainer(
        overrides: [
          sleepBackupStoreProvider.overrideWithValue(
            MemorySleepBackupStore(
              const SleepBackupPrefs(enabled: true, lastBackupAtMs: 1),
            ),
          ),
          sleepBackupScreenProvider.overrideWithValue(screen),
          sleepBackupRuntimeProvider.overrideWithValue(
            const SleepBackupRuntime(processing: true),
          ),
        ],
      );
      addTearDown(c.dispose);
      await pump(tester, c);
      expect(find.text('正在备份和同步...'), findsOneWidget);
      expect(screen.dims, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('没通知权限时不假装发过（界面如实说）', (tester) async {
      final sink = _FakeSink(allowed: false);
      final c = ProviderContainer(
        overrides: [
          sleepBackupStoreProvider.overrideWithValue(MemorySleepBackupStore()),
          sleepBackupNotificationSinkProvider.overrideWithValue(sink),
          sleepBackupRuntimeProvider.overrideWithValue(
            const SleepBackupRuntime(queueSize: 1),
          ),
        ],
      );
      addTearDown(c.dispose);
      await pump(tester, c);
      await tester.tap(find.byKey(const Key('sleep-backup-test-reminder')));
      await tester.pump();
      expect(sink.shown, isEmpty);
      expect(
        find.textContaining('系统没给通知权限'),
        findsOneWidget,
        reason: '没权限必须如实说，不能假装发了',
      );
    });
  });
}
