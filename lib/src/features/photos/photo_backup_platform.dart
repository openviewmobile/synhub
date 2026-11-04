// 相册备份的**原生桥**：WorkManager 排程 / 状态 / 互斥标志。
//
// 与 Kotlin 的接口（MethodChannel `synhub/photo_backup`，
// 原生侧见 `android/app/src/main/kotlin/com/openviewai/synhub/PhotoBackupPlugin.kt`）：
//   Dart→原生：status / registerCallback / setSchedule / runNow / cancel /
//              reportForeground / requestIgnoreBatteryOptimization
//   原生→Dart：**没有**实时回调 —— 后台真正干活是在一个新的 FlutterEngine 里
//              跑 `photo_backup_background.dart` 的 entrypoint，Kotlin 只等结果。
//
// 全平台可用：通道不在（桌面/未挂插件/单测）→ [supported] 为 false，
// 排程返回 false，**界面按"仅应用打开时备份"如实降级**（不静默失败）。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform/app_platform.dart';

import 'photo_backup_queue.dart';

/// 原生侧的备份状态快照。
class PhotoBackupPlatformStatus {
  const PhotoBackupPlatformStatus({
    this.supported = false,
    this.scheduled = false,
    this.charging = false,
    this.screenInteractive = true,
    this.notificationsGranted = true,
    this.batteryOptimizationIgnored = true,
    this.deviceName = '',
    this.lastResult = '',
    this.destination = PhotoBackupDestination.synologyPhotos,
    this.enabled = false,
    this.chargeOnly = false,
    this.screenOffOnly = false,
    this.wifiOnly = false,
  });

  /// 通道在不在
  final bool supported;

  /// WorkManager 里有没有排上（周期 or 单次）
  final bool scheduled;
  final bool charging;
  final bool screenInteractive;
  final bool notificationsGranted;

  /// 电池优化白名单（官方也会引导；不在名单里后台不稳定）
  final bool batteryOptimizationIgnored;

  /// 设备名（`Build.MODEL`；Drive 落点的设备子目录用它）
  final String deviceName;

  /// 上次后台跑完的一句话结果（可为空）
  final String lastResult;

  final PhotoBackupDestination destination;
  final bool enabled;
  final bool chargeOnly;
  final bool screenOffOnly;
  final bool wifiOnly;

  static PhotoBackupPlatformStatus fromMap(Map<String, Object?>? map) {
    if (map == null) return const PhotoBackupPlatformStatus();
    bool b(String k, {bool fallback = false}) => map[k] is bool
        ? map[k]! as bool
        : (map[k] == null ? fallback : map[k] == true);
    return PhotoBackupPlatformStatus(
      supported: b('supported'),
      scheduled: b('scheduled'),
      charging: b('charging'),
      screenInteractive: b('screenInteractive', fallback: true),
      notificationsGranted: b('notificationsGranted', fallback: true),
      batteryOptimizationIgnored: b(
        'batteryOptimizationIgnored',
        fallback: true,
      ),
      deviceName: '${map['deviceName'] ?? ''}',
      lastResult: '${map['lastResult'] ?? ''}',
      destination: PhotoBackupDestination.fromId(map['destination'] as String?),
      enabled: b('enabled'),
      chargeOnly: b('chargeOnly'),
      screenOffOnly: b('screenOffOnly'),
      wifiOnly: b('wifiOnly'),
    );
  }
}

/// 原生桥（测试里替换成假实现）。
abstract class PhotoBackupPlatform {
  /// 当前状态；通道缺失时回 [PhotoBackupPlatformStatus] 的默认（`supported=false`）
  Future<PhotoBackupPlatformStatus> status();

  /// 把后台 entrypoint 的 callback handle 交给原生（用 `PluginUtilities` 取）
  Future<bool> registerCallback(int handle);

  /// 按选项排/撤 WorkManager（充电、Wi-Fi、网络约束都在原生侧落地）
  Future<bool> setSchedule({
    required bool enabled,
    required bool chargeOnly,
    required bool screenOffOnly,
    required bool wifiOnly,
    required PhotoBackupDestination destination,
  });

  /// 立刻排一次（不等周期）
  Future<bool> runNow();

  Future<bool> cancel();

  /// 前台正在备份时告诉原生 —— 后台 Worker 看到它就直接退出（互斥，防双跑）
  Future<void> reportForeground(bool running);

  /// 拉起"忽略电池优化"设置页；返回当前是否已在白名单
  Future<bool> requestIgnoreBatteryOptimization();
}

/// 桌面/未挂插件时的实现：一律"平台不支持"，绝不假装排上了。
class UnsupportedPhotoBackupPlatform implements PhotoBackupPlatform {
  const UnsupportedPhotoBackupPlatform();

  @override
  Future<PhotoBackupPlatformStatus> status() async =>
      const PhotoBackupPlatformStatus();

  @override
  Future<bool> registerCallback(int handle) async => false;

  @override
  Future<bool> setSchedule({
    required bool enabled,
    required bool chargeOnly,
    required bool screenOffOnly,
    required bool wifiOnly,
    required PhotoBackupDestination destination,
  }) async => false;

  @override
  Future<bool> runNow() async => false;

  @override
  Future<bool> cancel() async => false;

  @override
  Future<void> reportForeground(bool running) async {}

  @override
  Future<bool> requestIgnoreBatteryOptimization() async => false;
}

/// Android 生产实现。
class MethodChannelPhotoBackupPlatform implements PhotoBackupPlatform {
  MethodChannelPhotoBackupPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kPhotoBackupChannel);

  final MethodChannel _channel;

  /// 第 55 轮：`synhub/photo_backup[_bg]` 只有 Kotlin 一份（WorkManager）⇒
  /// 宿主上能力层报 `unavailable:not-implemented-on-host`，**不碰通道**。
  static bool get _allowed => capabilityGateAllows(AppCapability.photoBackup);

  static void _logBlocked(String what) => debugPrint(
    capabilityGateLog(AppCapability.photoBackup, 'photo_backup.$what'),
  );

  @override
  Future<PhotoBackupPlatformStatus> status() async {
    if (!_allowed) {
      _logBlocked('status');
      return const PhotoBackupPlatformStatus();
    }
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      return PhotoBackupPlatformStatus.fromMap(map);
    } on MissingPluginException {
      return const PhotoBackupPlatformStatus();
    } catch (_) {
      return const PhotoBackupPlatformStatus();
    }
  }

  @override
  Future<bool> registerCallback(int handle) async {
    if (!_allowed) {
      _logBlocked('registerCallback');
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('registerCallback', {
            'handle': handle,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> setSchedule({
    required bool enabled,
    required bool chargeOnly,
    required bool screenOffOnly,
    required bool wifiOnly,
    required PhotoBackupDestination destination,
  }) async {
    if (!_allowed) {
      _logBlocked('setSchedule');
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('setSchedule', {
            'enabled': enabled,
            'chargeOnly': chargeOnly,
            'screenOffOnly': screenOffOnly,
            'wifiOnly': wifiOnly,
            'destination': destination.id,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> runNow() async {
    if (!_allowed) {
      _logBlocked('runNow');
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('runNow') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> cancel() async {
    if (!_allowed) {
      _logBlocked('cancel');
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('cancel') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> reportForeground(bool running) async {
    if (!_allowed) {
      _logBlocked('reportForeground');
      return;
    }
    try {
      await _channel.invokeMethod<bool>('reportForeground', {
        'running': running,
      });
    } on MissingPluginException {
      // 平台不支持就无所谓互斥（后台本来也不会跑）
    } catch (_) {
      // 同上：这个标志只是优化，丢了不影响正确性
    }
  }

  @override
  Future<bool> requestIgnoreBatteryOptimization() async {
    if (!_allowed) {
      _logBlocked('requestIgnoreBatteryOptimization');
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimization',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// 通道名（原生侧同名字面量，改一处必须改两处）
const String kPhotoBackupChannel = 'synhub/photo_backup';

/// 后台 isolate 的通道名
const String kPhotoBackupBackgroundChannel = 'synhub/photo_backup_bg';

/// 后台 entrypoint 的函数名（`PluginUtilities.getCallbackHandle` 用）
const String kPhotoBackupCallbackName = 'photoBackupBackgroundMain';
