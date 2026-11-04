// 平台能力层的 **Riverpod 接口**（第 279 轮）。
//
// 拆成单独文件是为了让 `app_platform.dart` 保持**纯 Dart**（不 import flutter_riverpod）
// —— 这样 `dart run tool/...` 的宿主探针也能直接用那套纯函数判断。
//
// 三层读法（各司其职，别混用）：
//
//   * `appHostProvider`        —— 同步，宿主是谁；
//   * `appCapabilitiesProvider` —— 同步，**静态**能力表（需要探测的是 `unknown`）；
//                                 界面若只想知道"要不要显示入口"，读它 + 把
//                                 `unknown` 当"先显示、等探测"，别当 `false`；
//   * `probedCapabilitiesProvider` —— 异步，把 `unknown` 问完之后的完整表；
//                                 **诊断面板 / 需要明确原因**的地方读它。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_platform.dart';

/// 当前宿主（同步；单测可用 [debugForceAppHost] 覆盖）。
final appHostProvider = Provider<AppHost>((ref) => currentAppHost);

/// 静态能力表（同步；`unknown` = 还要探测）。
final appCapabilitiesProvider = Provider<AppPlatformCapabilities>(
  (ref) => staticCapabilitiesFor(ref.watch(appHostProvider)),
);

/// 探测完成的能力表（异步）。
///
/// 失败/超时的条目会留在 `unknown`（**不降级成 unavailable**）——
/// "没问出来"和"问了说不能"是两件事（AGENTS §2.0.17 的三态口径）。
final probedCapabilitiesProvider = FutureProvider<AppPlatformCapabilities>(
  (ref) => probeAppCapabilities(base: ref.watch(appCapabilitiesProvider)),
  retry: (_, _) => null,
);

/// 单项能力的状态（便利读法；**同步**版，`unknown` 就是还没探测）。
///
/// 需要"探测后"的结论时请用 [probedCapabilityProvider]。
final capabilityStatusProvider = Provider.family<CapabilityStatus, AppCapability>(
  (ref, capability) => ref.watch(appCapabilitiesProvider).statusOf(capability),
);

/// 单项能力的**探测后**状态（异步 family）。
final probedCapabilityProvider =
    FutureProvider.family<CapabilityStatus, AppCapability>((ref, capability) async {
      final caps = await ref.watch(probedCapabilitiesProvider.future);
      return caps.statusOf(capability);
    }, retry: (_, _) => null);
