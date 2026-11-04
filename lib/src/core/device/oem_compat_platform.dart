// OEM 保活事实的**原生桥**（Android）—— 只读采集 + 打开系统设置页。
//
// 与 Kotlin（`android/app/src/main/kotlin/com/openviewai/synhub/OemCompatBridge.kt`，
// MethodChannel `synhub/oem`）的接口：
//   Dart→原生：`status` → { supported, oem, manufacturer, brand, model, sdkInt, rom,
//                            autostartComponent, batteryOptimizationIgnored }
//              `openSettings` { target } → bool
//
// 三条纪律：
//   ① **只读**：`status` 只读 `Build` 字段 + `PackageManager.resolveActivity`，
//      不申请权限、不改设置、不启动 Activity；
//   ② **不猜组件**：`autostartComponent` 是原生**验真过**（能 resolve 到）的组件名；
//      探不到就是空串 ⇒ 界面只显示文字路径（见 `oem_guidance.dart` 的纪律③）；
//   ③ **全平台安全**：通道不在（桌面/单测/未挂插件）⇒ [supported] = false，
//      指引页仍可打开，只是没有可点的深链（如实降级，不假装）。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';

/// 原生侧报回来的 OEM 事实快照。
class OemCompatStatus {
  const OemCompatStatus({
    this.supported = false,
    this.oemId = '',
    this.manufacturer = '',
    this.brand = '',
    this.model = '',
    this.sdkInt = 0,
    this.rom = '',
    this.autostartComponent = '',
    this.batteryOptimizationIgnored = true,
  });

  /// 通道在不在（Android 且插件已挂）
  final bool supported;

  /// 稳定厂商 id（`OemVendor.id` 一一对应）
  final String oemId;

  final String manufacturer;
  final String brand;
  final String model;

  /// `Build.VERSION.SDK_INT`（0 = 读不到）
  final int sdkInt;

  /// ROM 版本串（`Build.DISPLAY`），只用于显示
  final String rom;

  /// **验真过**的自启动系统页组件名（`pkg/cls`）；空串 = 这台机器上没有
  final String autostartComponent;

  /// `PowerManager.isIgnoringBatteryOptimizations`
  final bool batteryOptimizationIgnored;

  /// 有没有可点的自启动深链
  bool get hasAutostartPage => autostartComponent.trim().isNotEmpty;

  /// 「本机」一行要显示的内容（厂商 + 型号 + ROM）
  String get deviceLine {
    final parts = <String>[
      if (manufacturer.trim().isNotEmpty) manufacturer.trim(),
      if (model.trim().isNotEmpty) model.trim(),
      if (rom.trim().isNotEmpty) rom.trim(),
    ];
    return parts.join(' · ');
  }

  static OemCompatStatus fromMap(Map<String, Object?>? map) {
    if (map == null) return const OemCompatStatus();
    String s(String k) => '${map[k] ?? ''}'.trim();
    return OemCompatStatus(
      supported: map['supported'] == true,
      oemId: s('oem'),
      manufacturer: s('manufacturer'),
      brand: s('brand'),
      model: s('model'),
      sdkInt: map['sdkInt'] is num ? (map['sdkInt']! as num).toInt() : 0,
      rom: s('rom'),
      autostartComponent: s('autostartComponent'),
      batteryOptimizationIgnored:
          map['batteryOptimizationIgnored'] == true,
    );
  }
}

/// OEM 桥（测试/桌面用 [UnsupportedOemCompatPlatform]）
abstract class OemCompatPlatform {
  Future<OemCompatStatus> status();

  /// 打开一个系统设置落点。`target` 用 `OemSettingsTarget.id`。
  /// 返回 false = 这台机器上打不开（**调用方必须如实提示**，不许静默）。
  Future<bool> openSettings(String target);
}

/// 桌面 / 未挂插件：一律"平台不支持"，绝不假装能打开。
class UnsupportedOemCompatPlatform implements OemCompatPlatform {
  const UnsupportedOemCompatPlatform();

  @override
  Future<OemCompatStatus> status() async => const OemCompatStatus();

  @override
  Future<bool> openSettings(String target) async => false;
}

/// Android 生产实现。
class MethodChannelOemCompatPlatform implements OemCompatPlatform {
  MethodChannelOemCompatPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kOemCompatChannel);

  final MethodChannel _channel;

  /// 第 55 轮：`synhub/oem` 只有 Kotlin 一份（国产 ROM 保活引导）⇒
  /// 宿主上不碰通道（返回"没有建议"）。
  static bool get _allowed => capabilityGateAllows(AppCapability.oemCompat);

  static void _logBlocked(String what) =>
      debugPrint(capabilityGateLog(AppCapability.oemCompat, 'oem.$what'));

  @override
  Future<OemCompatStatus> status() async {
    if (!_allowed) {
      _logBlocked('status');
      return const OemCompatStatus();
    }
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      return OemCompatStatus.fromMap(map);
    } on MissingPluginException {
      return const OemCompatStatus();
    } catch (_) {
      return const OemCompatStatus();
    }
  }

  @override
  Future<bool> openSettings(String target) async {
    if (!_allowed) {
      _logBlocked('openSettings');
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('openSettings', {
            'target': target,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// 通道名（与 Kotlin `OemCompatBridge.CHANNEL` 必须逐字一致）
const String kOemCompatChannel = 'synhub/oem';
