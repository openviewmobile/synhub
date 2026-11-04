// ★★ ③Drive 第 226 轮 **D84 常驻 worker 的"回 Dart 复算"半边** 用例。
//
// ①后台复算逻辑（可注入偏好吗，全离线）；②与 Kotlin 的**跨语言契约一致性**
// （通道名、周期常量、callback key）—— 用读源码的方式钉住，防止两侧悄悄漂移。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

import 'package:synhub/src/features/photos/sleep_backup.dart';
import 'package:synhub/src/features/photos/sleep_backup_background.dart';
import 'package:synhub/src/features/photos/sleep_backup_worker.dart';

const int kHour = 3600 * 1000;

SleepBackupPrefs _prefs({
  bool enabled = true,
  int lastBackupAtMs = 0,
  int nextShowAtMs = 0,
  int backoffMs = 24 * kHour,
}) => SleepBackupPrefs(
  enabled: enabled,
  lastBackupAtMs: lastBackupAtMs,
  nextShowAtMs: nextShowAtMs,
  backoffMs: backoffMs,
);

void main() {
  // ★ 第 55 轮：这些用例验证的是**桥被调用时发什么载荷**（Android 语义），
  //   而能力层在 macOS 宿主上会正确地拦住 Android-only 桥 ⇒ 先把门打开
  //   （反向验证：门打开时确实去碰通道；见 `platform_capability_test.dart`）。
  setUp(() => debugForceCapabilityGate = true);
  tearDown(() => debugForceCapabilityGate = false);
  TestWidgetsFlutterBinding.ensureInitialized();

  group('D84 后台复算 · 判定', () {
    test('过时且到点 ⇒ show=true，并带回新的下次时间与退避', () async {
      final now = 100 * kHour;
      final r = await runSleepBackupCheckInBackground(
        {'queue_size': 4},
        loadPrefs: () async =>
            _prefs(lastBackupAtMs: now - 30 * kHour, nextShowAtMs: now - 1),
        nowMs: () => now,
      );
      expect(r['ok'], isTrue);
      expect(r['show'], isTrue);
      expect(r['outdated'], isTrue);
      expect(r['now_ms'], now);
      expect(r['next_show_at_ms'], greaterThan(now));
      // 官方退避是**递增**的：本次推送后 24h → 48h（封顶 3 天）
      expect(r['backoff_ms'], 48 * kHour);
      expect(r['title'], isNotEmpty);
    });

    test('未启用 ⇒ 不提醒（即使过时）', () async {
      final now = 100 * kHour;
      final r = await runSleepBackupCheckInBackground(
        const {},
        loadPrefs: () async => _prefs(
          enabled: false,
          lastBackupAtMs: now - 30 * kHour,
          nextShowAtMs: now - 1,
        ),
        nowMs: () => now,
      );
      expect(r['ok'], isTrue);
      expect(r['enabled'], isFalse);
      expect(r['show'], isFalse);
    });

    test('正在处理中 ⇒ 不打扰（官方判定的"processing 不弹"必须复算出来）', () async {
      final now = 100 * kHour;
      final r = await runSleepBackupCheckInBackground(
        {'processing': true, 'queue_size': 9},
        loadPrefs: () async =>
            _prefs(lastBackupAtMs: now - 30 * kHour, nextShowAtMs: now - 1),
        nowMs: () => now,
      );
      expect(r['show'], isFalse);
    });

    test('还没到 next_show ⇒ 不提醒', () async {
      final now = 100 * kHour;
      final r = await runSleepBackupCheckInBackground(
        const {},
        loadPrefs: () async =>
            _prefs(lastBackupAtMs: now - 30 * kHour, nextShowAtMs: now + kHour),
        nowMs: () => now,
      );
      expect(r['show'], isFalse);
      expect(r['show_at_ms'], now + kHour);
    });

    test('偏好读不出来（换机/Keystore 解不开）⇒ ok=false、show=false，不发假提醒', () async {
      final r = await runSleepBackupCheckInBackground(
        const {},
        loadPrefs: () async => throw StateError('keystore 解不开'),
      );
      expect(r['ok'], isFalse);
      expect(r['show'], isFalse);
      expect('${r['error']}', contains('keystore'));
    });

    test('参数里的文案会被用于提醒（原生只负责发）', () async {
      final now = 5 * kHour;
      final r = await runSleepBackupCheckInBackground(
        {'title': 'T1', 'text': 'X1'},
        loadPrefs: () async =>
            _prefs(lastBackupAtMs: now - 40 * kHour, nextShowAtMs: 0),
        nowMs: () => now,
      );
      expect(r['title'], 'T1');
      expect(r['text'], 'X1');
    });
  });

  group('D84 后台复算 · 计划与调度载荷', () {
    test('plan JSON 带上 queue_size/processing（原生原样带回给 Dart 复算）', () {
      final plan = planSleepBackupWorkerWake(
        prefs: _prefs(lastBackupAtMs: 0),
        runtime: const SleepBackupRuntime(queueSize: 7, processing: true),
        nowMs: 10 * kHour,
        title: 'T',
        text: 'X',
      );
      final j = Map<String, Object?>.from(jsonDecode(plan.encode()) as Map);
      expect(j['queue_size'], 7);
      expect(j['processing'], isTrue);
      expect(j['due_now'], isFalse, reason: '处理中 ⇒ 本次不该提醒');
    });

    test('调度时把 Dart 后台入口的 callback handle 交给原生', () async {
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('synhub/sleep_backup_worker'),
            (call) async {
              seen = call;
              return true;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('synhub/sleep_backup_worker'),
              null,
            ),
      );
      const s = MethodChannelSleepBackupWorker();
      await s.schedule(
        const SleepBackupWorkerPlan(
          showAtMs: 1,
          nextShowAtMs: 2,
          backoffMs: 3,
          title: 'T',
          text: 'X',
          outdated: true,
        ),
      );
      final args = seen!.arguments as Map;
      expect(args['callback'], isA<int>());
      expect(args['interval_minutes'], 60);
      expect(args['flex_minutes'], 10);
    });
  });

  group('D84 后台复算 · 与 Kotlin 的跨语言契约', () {
    late String kt;

    setUpAll(() {
      kt = File(
        'android/app/src/main/kotlin/com/openviewai/synhub/'
        'SleepBackupWorker.kt',
      ).readAsStringSync();
    });

    test('通道名两侧一致（前台调度 + 后台复算两条）', () {
      expect(kSleepBackupBackgroundChannel, 'synhub/sleep_backup_bg');
      expect(kt, contains('"$kSleepBackupBackgroundChannel"'));
      expect(kt, contains('"synhub/sleep_backup_worker"'));
    });

    test('周期常量两侧一致（60min / flex 10min）', () {
      expect(kSleepBackupWorkerIntervalMinutes, 60);
      expect(kSleepBackupWorkerFlexMinutes, 10);
      expect(kt, contains('INTERVAL_MINUTES = 60L'));
      expect(kt, contains('FLEX_MINUTES = 10L'));
    });

    test('worker 真的会回 Dart 复算（不是只用调度时的旧结论）', () {
      expect(kt, contains('runDartCheck'));
      expect(kt, contains('invokeMethod("check"'));
      expect(
        kt,
        contains('KEY_CALLBACK'),
        reason: '没有 callback handle 就没法回 Dart',
      );
    });
  });
}
