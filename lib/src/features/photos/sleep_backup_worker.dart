// ★★★ ③Drive **D84「休眠备份」的 60 分钟常驻 worker** —— 第 222 轮（Dart 半边）。
//
// ## 官方对照
// 官方休眠备份有一个 **60 分钟周期 / flex 10 分钟**的常驻 worker
// （常量已在 `sleep_backup.dart` 逐字对齐：`kSleepBackupCheckIntervalMinutes`），
// 周期性地算一次"要不要提醒用户继续备份"。
//
// 第 214 轮做了：判定/退避/提醒/状态页/倒计时/调暗常亮（Dart + 原生窗口）。
// **本轮补的是"真的常驻"**：把判定结果交给 Android **WorkManager 周期任务**，
// App 不在前台也按 60min 触发。
//
// ## 分工（为什么不用 headless FlutterEngine 回 Dart）
// `sleep_backup.dart` 里已经有 `runSleepBackupReminderCheck` 的**纯判定**部分；
// 本轮的做法是：**调度时**在前台算好"何时该提醒 + 提醒文案"（官方 zh-CN 逐字），
// 交给原生 worker；worker 只负责**到点发通知 + 记录 prefs**。
// 这样 worker 不需要在 headless engine 里重新注册 `shared_preferences` 插件，
// 也不会出现"第二套判定逻辑"——判定仍然只有 Dart 这一份。
//
// ⚠️ 诚实边界：与官方"worker 内回 Dart 复算"不同，我方是**调度时算好**
// （周期内状态变了要等下一次前台刷新才会重算）—— 登记在台账，不冒充一致。
import 'dart:convert';

import 'dart:ui' show PluginUtilities;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';

import 'sleep_backup_background.dart';

import 'sleep_backup.dart';

/// 官方 worker 周期（分钟）——与 [kSleepBackupCheckIntervalMinutes] 必须一致。
const int kSleepBackupWorkerIntervalMinutes = 60;

/// 官方 worker 的 flex（分钟）。
const int kSleepBackupWorkerFlexMinutes = 10;

/// 交给原生 worker 的"唤醒计划"（Kotlin 侧按它发通知）。
class SleepBackupWorkerPlan {
  const SleepBackupWorkerPlan({
    required this.showAtMs,
    required this.nextShowAtMs,
    required this.backoffMs,
    required this.title,
    required this.text,
    required this.outdated,
    this.dueNow = false,
    this.queueSize = 0,
    this.processing = false,
  });

  /// 到点（>=）才发提醒；已经是"该提醒"就是 now
  final int showAtMs;

  /// 发完后的下次可提醒时间（官方退避）
  final int nextShowAtMs;
  final int backoffMs;
  final String title;
  final String text;
  final bool outdated;

  /// 官方判定在**本次计算时**是否就该提醒（后台复算时用这个，而不是旧结论）
  final bool dueNow;

  /// 传给原生 worker 的运行时快照（worker 回 Dart 复算时原样带回来）
  final int queueSize;
  final bool processing;

  Map<String, Object?> toJson() => {
    'show_at_ms': showAtMs,
    'next_show_at_ms': nextShowAtMs,
    'backoff_ms': backoffMs,
    'title': title,
    'text': text,
    'outdated': outdated,
    'due_now': dueNow,
    'queue_size': queueSize,
    'processing': processing,
  };

  static SleepBackupWorkerPlan fromJson(Map<String, Object?> j) =>
      SleepBackupWorkerPlan(
        showAtMs: (j['show_at_ms'] as num?)?.toInt() ?? 0,
        nextShowAtMs: (j['next_show_at_ms'] as num?)?.toInt() ?? 0,
        backoffMs: (j['backoff_ms'] as num?)?.toInt() ?? 0,
        title: '${j['title'] ?? ''}',
        text: '${j['text'] ?? ''}',
        outdated: j['outdated'] == true,
        dueNow: j['due_now'] == true,
        queueSize: (j['queue_size'] as num?)?.toInt() ?? 0,
        processing: j['processing'] == true,
      );

  String encode() => jsonEncode(toJson());
}

/// 算"下一次常驻唤醒要不要提醒"。
///
/// 复用 `sleep_backup.dart` 的官方判定（`decideSleepBackupReminder` +
/// `sleepBackupOutdated`），**不新造第二套判据**。
SleepBackupWorkerPlan planSleepBackupWorkerWake({
  required SleepBackupPrefs prefs,
  required SleepBackupRuntime runtime,
  required int nowMs,
  required String title,
  required String text,
}) {
  final outdated = sleepBackupOutdated(
    nowMs: nowMs,
    lastBackupAtMs: prefs.lastBackupAtMs,
    queueSize: runtime.queueSize,
    processing: runtime.processing,
  );
  final d = decideSleepBackupReminder(
    nowMs: nowMs,
    nextShowAtMs: prefs.nextShowAtMs,
    backoffMs: prefs.backoffMs,
    outdated: outdated,
    processing: runtime.processing,
  );
  return SleepBackupWorkerPlan(
    showAtMs: d.push ? nowMs : (prefs.nextShowAtMs > nowMs ? prefs.nextShowAtMs : nowMs),
    nextShowAtMs: d.nextShowAtMs,
    backoffMs: d.backoffMs,
    title: title,
    text: text,
    outdated: outdated,
    dueNow: d.push,
    queueSize: runtime.queueSize,
    processing: runtime.processing,
  );
}

/// 原生周期任务通道（Kotlin `SleepBackupWorker` + `SleepBackupScheduler`）。
abstract class SleepBackupWorkerScheduler {
  Future<bool> schedule(SleepBackupWorkerPlan plan);
  Future<bool> cancel();
  Future<bool> isScheduled();
}

class MethodChannelSleepBackupWorker implements SleepBackupWorkerScheduler {
  const MethodChannelSleepBackupWorker();

  static const MethodChannel _channel = MethodChannel(
    'synhub/sleep_backup_worker',
  );

  /// 第 55 轮：`synhub/sleep_backup_worker` 只有 Kotlin 一份（WorkManager）⇒
  /// 宿主上不碰通道（能力层报 `not-implemented-on-host`）。
  static bool get _allowed => capabilityGateAllows(AppCapability.sleepBackup);

  @override
  Future<bool> schedule(SleepBackupWorkerPlan plan) async {
    if (!_allowed) {
      debugPrint(
        capabilityGateLog(AppCapability.sleepBackup, 'sleep_backup_worker.schedule'),
      );
      return false;
    }
    return await _channel.invokeMethod<bool>('schedule', {
          'interval_minutes': kSleepBackupWorkerIntervalMinutes,
          'flex_minutes': kSleepBackupWorkerFlexMinutes,
          'plan': plan.encode(),
          // ★ 226 轮：把 Dart 后台入口的 handle 交给原生（worker 到点回 Dart 复算）
          'callback':
              PluginUtilities.getCallbackHandle(sleepBackupBackgroundMain)
                  ?.toRawHandle() ??
              0,
        }) ??
        false;
  }

  @override
  Future<bool> cancel() async {
    if (!_allowed) {
      debugPrint(
        capabilityGateLog(AppCapability.sleepBackup, 'sleep_backup_worker.cancel'),
      );
      return false;
    }
    return await _channel.invokeMethod<bool>('cancel') ?? false;
  }

  @override
  Future<bool> isScheduled() async {
    if (!_allowed) {
      debugPrint(
        capabilityGateLog(AppCapability.sleepBackup, 'sleep_backup_worker.isScheduled'),
      );
      return false;
    }
    return await _channel.invokeMethod<bool>('isScheduled') ?? false;
  }
}

/// 记录型（用例/离线环境用）。
class RecordingSleepBackupWorkerScheduler implements SleepBackupWorkerScheduler {
  final plans = <SleepBackupWorkerPlan>[];
  final calls = <String>[];
  bool scheduled = false;

  @override
  Future<bool> schedule(SleepBackupWorkerPlan plan) async {
    calls.add('schedule');
    plans.add(plan);
    scheduled = true;
    return true;
  }

  @override
  Future<bool> cancel() async {
    calls.add('cancel');
    scheduled = false;
    return true;
  }

  @override
  Future<bool> isScheduled() async {
    calls.add('isScheduled');
    return scheduled;
  }
}

final sleepBackupWorkerSchedulerProvider =
    Provider<SleepBackupWorkerScheduler>(
      (ref) => const MethodChannelSleepBackupWorker(),
      name: 'sleepBackupWorkerScheduler',
    );
