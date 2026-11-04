// ★★★ ③Drive **D84「休眠备份」常驻 worker 的 Dart 回调半边** —— 第 226 轮。
//
// 第 222 轮把 60min 常驻任务做起来了，但**判定是"调度时算好"的**：
// 周期内状态变了（例如备份刚跑完、或队列积压），worker 到点仍按旧结论发提醒。
// 官方是 worker **内部回 Dart 复算**。
//
// 本轮补上这条链（与相册 `photo_backup_background.dart` 同构）：
//
//   Kotlin `SleepBackupWorker.doWork()`
//     → 起一个 headless `FlutterEngine` + `executeDartCallback`（本文件 entrypoint）
//     → 通道 `synhub/sleep_backup_bg` 调 `check`
//     → 这里**用前台同一套判定**（`planSleepBackupWorkerWake`）**重新算一遍**
//     → 返回 `{ok, show, title, text, next_show_at_ms, ...}`
//     → Kotlin 只在 `show == true` 时发通知，并把新的退避写回
//
// ⚠️ 与 222 轮一样，**真机未验**（Kotlin 侧未跑 Gradle/真机；本文件与判定逻辑
// 有离线用例钉住）。
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/i18n/data_text.dart';
import '../../core/platform/app_platform.dart';
import 'sleep_backup.dart';
import 'sleep_backup_worker.dart';

/// 后台通道名（与 Kotlin `SleepBackupWorker.BG_CHANNEL` 一致）
const String kSleepBackupBackgroundChannel = 'synhub/sleep_backup_bg';

/// 后台入口。函数名与 `SleepBackupWorker` 里注册的 callback handle 对应。
@pragma('vm:entry-point')
void sleepBackupBackgroundMain() {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kSleepBackupBackgroundChannel);
  // 第 55 轮：后台通道只有 Android 侧注册；能力层不放行就不监听。
  if (!capabilityGateAllows(AppCapability.sleepBackup)) {
    debugPrint(
      capabilityGateLog(AppCapability.sleepBackup, 'sleep_backup_bg.subscribe'),
    );
    return;
  }
  channel.setMethodCallHandler((call) async {
    if (call.method != 'check') return null;
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    return runSleepBackupCheckInBackground(args);
  });
}

/// 后台复算一轮并返回可序列化结果。
///
/// [loadPrefs] 是给用例的注入缝：默认真读落盘的偏好（Android Keystore 封存）；
/// 单测喂假实现，把"参数解析 + 判定复用 + 结果序列化"钉住，
/// 不用真的起 isolate。
Future<Map<String, Object?>> runSleepBackupCheckInBackground(
  Map<String, Object?> args, {
  Future<SleepBackupPrefs> Function()? loadPrefs,
  int Function()? nowMs,
}) async {
  final now = (nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();
  final runtime = SleepBackupRuntime(
    queueSize: (args['queue_size'] as num?)?.toInt() ?? 0,
    processing: args['processing'] == true,
  );
  try {
    final prefs =
        await (loadPrefs ?? openSleepBackupBackgroundPrefs)();
    final plan = planSleepBackupWorkerWake(
      prefs: prefs,
      runtime: runtime,
      nowMs: now,
      title: '${args['title'] ?? dataText('sleepBackupWorkerTitle', 'SynHub 休眠备份')}',
      text: '${args['text'] ?? dataText('sleepBackupWorkerText', '为了让备份继续，请保持 App 在前台并让屏幕常亮。')}',
    );
    // ★ 关键：**是否该提醒**在后台重新判一次（而不是沿用调度时的结论）
    final show = prefs.enabled && now >= plan.showAtMs && plan.dueNow;
    return <String, Object?>{
      'ok': true,
      'show': show,
      'now_ms': now,
      'show_at_ms': plan.showAtMs,
      'next_show_at_ms': plan.nextShowAtMs,
      'backoff_ms': plan.backoffMs,
      'outdated': plan.outdated,
      'enabled': prefs.enabled,
      'title': plan.title,
      'text': plan.text,
    };
  } catch (e) {
    // 偏好读不出来（换机/重装/Keystore 解不开）⇒ 如实报错，**不发假提醒**
    return <String, Object?>{'ok': false, 'show': false, 'error': '$e'};
  }
}

/// 后台读偏好：与前台同一个 store（`SecureSleepBackupStore`）。
Future<SleepBackupPrefs> openSleepBackupBackgroundPrefs() async {
  final store = SecureSleepBackupStore();
  return store.read();
}
