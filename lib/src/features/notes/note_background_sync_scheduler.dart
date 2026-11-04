// 笔记后台同步的 Dart 侧排程（第 114 轮 M3）。
//
// 与原生 `NoteSyncPlugin`（`synhub/note_sync`）对话：
//   registerCallback(handle) → 原生记住 `noteBackgroundSyncMain`
//   enable()/disable()       → 排/停 WorkManager 周期任务
//   syncNow()                → 立刻补跑一次
//
// 纪律：**测试/桌面环境不碰通道**（全部返回"不可用"，不抛）；
// 开关是**原生存的**（与官方 `resumeSyncService/pauseSyncService` 同理），
// Dart 只在启动时登记一次 handle 并尊重开关。
import 'dart:ui' show PluginUtilities;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/system_open.dart' show isTestEnvironment;
import 'note_background_sync.dart';

const MethodChannel _channel = MethodChannel('synhub/note_sync');

/// 后台入口的 callback handle（原生要它才能起 headless 引擎）。
int? noteBackgroundSyncCallbackHandle() {
  final handle = PluginUtilities.getCallbackHandle(noteBackgroundSyncMain);
  return handle?.toRawHandle();
}

/// 启动时登记一次：把 entrypoint handle 交给原生（失败静默）。
Future<bool> registerNoteBackgroundSync() async {
  if (isTestEnvironment || !capabilityGateAllows(AppCapability.scheduledNoteSync)) return false;
  final handle = noteBackgroundSyncCallbackHandle();
  if (handle == null) return false;
  try {
    final ok = await _channel.invokeMethod<bool>('registerCallback', {
          'handle': handle,
        }) ??
        false;
    if (!ok) return false;
    // 排程是**幂等**的（原生 `ExistingPeriodicWorkPolicy.KEEP`）：
    // 用户关过就**不排**（尊重开关），开着则确保周期任务在。
    final enabled = await _channel.invokeMethod<bool>('isEnabled') ?? false;
    if (enabled) await _channel.invokeMethod<bool>('enable');
    return true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 开关后台同步（原生持久化；关掉**不动**已同步数据）。
Future<bool> setNoteBackgroundSyncEnabled({required bool enabled}) async {
  if (isTestEnvironment || !capabilityGateAllows(AppCapability.scheduledNoteSync)) return false;
  try {
    return await _channel.invokeMethod<bool>(enabled ? 'enable' : 'disable') ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 读原生持有的开关状态（页面初始化用）。测试/桌面 ⇒ null（未知）。
Future<bool?> noteBackgroundSyncEnabled() async {
  if (isTestEnvironment || !capabilityGateAllows(AppCapability.scheduledNoteSync)) return null;
  try {
    return await _channel.invokeMethod<bool>('isEnabled');
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// 立刻补跑一次后台同步（"立即同步"/开机补跑）。
Future<bool> triggerNoteBackgroundSyncNow({String reason = 'manual'}) async {
  if (isTestEnvironment || !capabilityGateAllows(AppCapability.scheduledNoteSync)) return false;
  try {
    return await _channel.invokeMethod<bool>('syncNow', {
          'reason': reason,
        }) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 排程桥的**可注入封装**（页面只认它；用例替换成记录调用的假实现）。
///
/// 为什么要有它：真实的三个函数在 `isTestEnvironment` 下**故意短路**
/// （不碰平台通道），所以 widget 用例没法用 mock channel 观察 UI 行为。
/// 这一层把"页面 → 桥"的解耦出来，测试注入假桥即可。
class NoteBackgroundSyncBridge {
  const NoteBackgroundSyncBridge();

  Future<bool?> enabled() => noteBackgroundSyncEnabled();

  Future<bool> setEnabled({required bool enabled}) =>
      setNoteBackgroundSyncEnabled(enabled: enabled);

  Future<bool> syncNow({String reason = 'manual'}) =>
      triggerNoteBackgroundSyncNow(reason: reason);

  Future<bool> register() => registerNoteBackgroundSync();
}

final noteBackgroundSyncBridgeProvider =
    Provider<NoteBackgroundSyncBridge>((ref) => const NoteBackgroundSyncBridge());
