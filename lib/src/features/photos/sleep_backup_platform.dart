// ★★ ③Drive D84（214 轮）：「专注备份和同步」的原生出口（屏幕调暗 / 保持常亮）。
//
// 通道 `synhub/sleep_backup`（Kotlin 侧 `SleepBackupBridge.kt`）：
//   * `setScreenBrightness` `{value: double}`
//   * `clearScreenBrightness`
//   * `setKeepScreenOn` `{on: bool}`
//
// 与仓库其它原生桥同一纪律：**单测/桌面环境没有这条通道** ⇒
// `MissingPluginException` 直接吞掉（fail-soft：调不了亮度不该让备份页崩），
// 但**不假装做过** —— 返回值如实反映是否真的调到。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform/app_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 一个"窗口亮度/常亮"的出口。
abstract class SleepBackupScreen {
  /// 覆盖当前窗口亮度（0.0~1.0）。返回是否真的生效。
  Future<bool> dim(double value);

  /// 恢复跟随系统亮度。
  Future<bool> clearDim();

  /// 备份期间保持屏幕常亮（官方 `sleepmode_keep_forground_desc` 的机制面）。
  Future<bool> keepScreenOn(bool on);

  /// ★ 249 轮：**把窗口的真实状态读回来**（给真机取证用）。
  ///
  /// "通道回了 true"只证明调用成功，不证明系统真的改了；这里从
  /// Kotlin 侧读回 `Window` 的 `FLAG_KEEP_SCREEN_ON` 与 `screenBrightness`，
  /// 于是真机用例可以断言**看到的状态**，而不是"我说我调了"。
  Future<SleepBackupScreenStatus> status();
}

/// 原生窗口状态快照（249 轮真机取证用）。
class SleepBackupScreenStatus {
  const SleepBackupScreenStatus({required this.keepScreenOn, this.brightness});

  /// `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON` 是否置位
  final bool keepScreenOn;

  /// 窗口亮度覆盖值；`null` = 跟随系统（`BRIGHTNESS_OVERRIDE_NONE`）
  final double? brightness;
}

/// 走方法通道的真实实现。
class MethodChannelSleepBackupScreen implements SleepBackupScreen {
  const MethodChannelSleepBackupScreen();

  static const MethodChannel _channel = MethodChannel(
    'synhub/sleep_backup',
  );

  @override
  Future<bool> dim(double value) => _invoke('setScreenBrightness', {
    'value': value,
  });

  @override
  Future<bool> clearDim() => _invoke('clearScreenBrightness', null);

  @override
  Future<bool> keepScreenOn(bool on) => _invoke('setKeepScreenOn', {'on': on});

  /// 第 55 轮：`synhub/sleep_backup` 只有 Kotlin 一份 ⇒ 宿主上能力层报
  /// `unavailable:not-implemented-on-host`，**不碰通道**。
  static bool get _allowed => capabilityGateAllows(AppCapability.sleepBackup);

  @override
  Future<SleepBackupScreenStatus> status() async {
    if (!_allowed) {
      debugPrint(capabilityGateLog(AppCapability.sleepBackup, 'sleep_backup.status'));
      return const SleepBackupScreenStatus(keepScreenOn: false);
    }
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('getStatus');
      if (m == null) return const SleepBackupScreenStatus(keepScreenOn: false);
      final v = m['screen_brightness'];
      return SleepBackupScreenStatus(
        keepScreenOn: m['keep_screen_on'] == true,
        brightness: v is num ? v.toDouble() : null,
      );
    } on PlatformException {
      return const SleepBackupScreenStatus(keepScreenOn: false);
    } on MissingPluginException {
      return const SleepBackupScreenStatus(keepScreenOn: false);
    }
  }

  Future<bool> _invoke(String method, Map<String, Object?>? args) async {
    if (!_allowed) {
      debugPrint(capabilityGateLog(AppCapability.sleepBackup, 'sleep_backup.$method'));
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>(method, args);
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // 没有原生通道（单测/桌面）⇒ 如实回 false，不假装调到了。
      return false;
    }
  }
}

/// 内存实现（页面用例记录调用；生产不用）。
class RecordingSleepBackupScreen implements SleepBackupScreen {
  final List<double> dims = [];
  final List<bool> keepOns = [];
  int clears = 0;

  /// 模拟"这个环境没有原生通道"（用例断言 fail-soft）。
  bool available = true;

  /// ★ 249 轮：内存实现也维护"当前状态"，与原生读回语义一致
  double? lastBrightness;
  bool keepOn = false;

  @override
  Future<SleepBackupScreenStatus> status() async => SleepBackupScreenStatus(
    keepScreenOn: keepOn,
    brightness: lastBrightness,
  );

  @override
  Future<bool> dim(double value) async {
    if (!available) return false;
    dims.add(value);
    lastBrightness = value;
    return true;
  }

  @override
  Future<bool> clearDim() async {
    if (!available) return false;
    clears += 1;
    lastBrightness = null;
    return true;
  }

  @override
  Future<bool> keepScreenOn(bool on) async {
    if (!available) return false;
    keepOns.add(on);
    keepOn = on;
    return true;
  }
}

final sleepBackupScreenProvider = Provider<SleepBackupScreen>(
  (ref) => const MethodChannelSleepBackupScreen(),
);
