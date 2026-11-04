// 本机设备型号（官方 DSnote 的 `commit_msg.device` = `Build.MODEL`）。
//
// 为什么要有它（台账 L6）：我方 `commit_msg.device` 一直硬编码 `"Flutter"`，
// 官方报的是真实型号 ⇒ 版本历史里的"来源设备"标签与官方**不一致**。
// 这里读原生桥（`synhub/device`）拿真型号，拿不到才回落。
//
// 三条纪律：
//   ① **只读**：不申请权限、不写任何东西；
//   ② **测试/桌面不碰平台**：`isTestEnvironment` 下直接回落，
//      免得单测里出现 MissingPluginException；
//   ③ 回落值保持旧行为 `'Flutter'`，**不假装**是某台具体设备。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';
import '../system_open.dart' show isTestEnvironment;

const MethodChannel _deviceChannel = MethodChannel('synhub/device');

/// 读原生 `Build.MODEL`；不可用/空白 ⇒ null。
Future<String?> readDeviceModel() async {
  // 第 79 轮：碰通道前先过能力门（`deviceHardwareInfo` 在桌面宿主上是
  // `needsMobileHost` ⇒ unavailable，别去撞 MissingPluginException）。
  if (isTestEnvironment ||
      kIsWeb ||
      !capabilityGateAllows(AppCapability.deviceHardwareInfo)) {
    return null;
  }
  try {
    final model = await _deviceChannel.invokeMethod<String>('model');
    final trimmed = (model ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// 官方口径的 `commit_msg.device`：真型号，拿不到用 [fallback]。
///
/// 纯函数（便于离线断言），不做 IO。
String noteCommitDeviceFrom(String? platformModel, {String fallback = 'Flutter'}) {
  final trimmed = (platformModel ?? '').trim();
  return trimmed.isEmpty ? fallback : trimmed;
}
