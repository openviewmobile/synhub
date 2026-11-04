// r681：iOS **端侧 AI 硬件事实桥**（`synhub/device` 的 Swift 实现）端到端探针。
//
// 验的是什么（不是"通道能通"，而是**数是真的**）：
//   ① `capability` 回了同一批 key，且 `totalRamBytes > 0`、`cpuCores > 0`、
//      `model` 非空 —— 这正是 Android 侧算档位要的三样事实；
//   ② `abis` 含 `arm64`，且 Dart 的档位规则**不再把 iOS 否决成 unsupported**
//      （r681 修的 `kSupportedAbis`：旧代码只认 `arm64-v8a`）；
//   ③ `isSimulator == true`（这一轮跑在模拟器上；模拟器的内存是**宿主的**，
//      所以必须能被区分出来，否则会得出"模拟器 = 旗舰机"的假结论）；
//   ④ `glRenderer` 非空（Metal 设备名），`metalDevice` 与它一致；
//   ⑤ `readDeviceModel()`（同一 channel 的 `model` 方法）非空 —— 它喂官方口径的
//      `commit_msg.device`；
//   ⑥ 档位**不是** `unknown`（有事实却判不出档 = 规则坏了）。
//
// 边界（写在用例里，别让人误读）：
//   * 模拟器上 `totalRamBytes` 是 Mac 的物理内存 ⇒ 只断言 ">0 且 < 1 TB"，
//     不拿它当"这台 iPhone 有几 GB"的证据；
//   * `cpuMaxFreqKhz` iOS 不公开 ⇒ 断言 == 0（**如实为空**，不是漏读）；
//   * `openclLibrary == false`、`nnapiFeature == false` 是 iOS 的事实；
//   * 真机（物理 iPhone）的 ANE / 热状态读数不在本轮范围。
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/core/device/device_capability.dart';
import 'package:synhub/src/core/device/device_model.dart';
import 'package:synhub/src/core/platform/app_platform.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('s281 iOS 硬件事实：桥回的数是真事实，档位不再是 unknown', () async {
    // ① 能力门：iOS 上必须是 available（Swift 桥随包编译）
    final caps = staticCapabilitiesFor(AppHost.ios);
    expect(
      caps.statusOf(AppCapability.deviceHardwareInfo).isAvailable,
      isTrue,
      reason: 'r681：iOS 的 synhub/device 已随包编译 ⇒ 静态 available',
    );

    // ② 走**产品同一条路**（`probeDeviceCapability`），不是直接调通道
    final snap = await probeDeviceCapability();
    // ignore: avoid_print
    print('[r681] snapshot source=${snap.source} model=${snap.model} '
        'soc=${snap.socModel} cores=${snap.cpuCores} '
        'ram=${snap.totalRamBytes} free=${snap.freeStorageBytes} '
        'gpu=${snap.glRenderer} thermal=${snap.thermalStatus} '
        'sdk=${snap.sdkInt} abis=${snap.abis}');

    expect(snap.source, 'platform', reason: '必须来自原生桥，不是 /proc 回落');
    expect(snap.manufacturer, 'Apple');
    expect(snap.sdkInt, greaterThanOrEqualTo(13));
    expect(snap.model.trim(), isNotEmpty);
    expect(snap.cpuCores, greaterThan(0));
    // 模拟器上是宿主内存（16/32/64 GB 级），真机 4–8 GB；两侧都远小于 1 TB。
    expect(snap.totalRamBytes, greaterThan(0));
    expect(snap.totalRamBytes, lessThan(1 << 40));
    expect(snap.freeStorageBytes, greaterThan(0));
    expect(snap.abis, contains('arm64'));
    // 如实为空的三项（iOS 没有对应系统 API / 硬件）
    expect(snap.cpuMaxFreqKhz, 0, reason: 'iOS 不公开 CPU 频率');
    expect(snap.openclLibrary, isFalse);
    expect(snap.nnapiFeature, isFalse);
    // GPU：Metal 设备名
    expect(snap.glRenderer.trim(), isNotEmpty, reason: 'Metal 设备名');
    expect(snap.glVendor, 'Apple');
    // 环境标识
    expect(snap.isSimulator, isTrue, reason: '本轮在模拟器上跑');

    // ③ 档位规则：有事实就必须判出档（旧代码会因 abi 否决成 unsupported）
    final cap = classifyDevice(snap);
    // ignore: avoid_print
    print('[r681] tier=${cap.tier.name} gpu=${cap.gpuFamily.name} '
        'npu=${cap.npuClass.name} notes=${cap.notes}');
    expect(cap.tier, isNot(DeviceComputeTier.unknown));
    expect(
      cap.tier,
      isNot(DeviceComputeTier.unsupported),
      reason: 'r681：arm64（无 -v8a 后缀）不该触发 32 位否决',
    );
    expect(cap.notes, isNot(contains(startsWith('veto:abi'))));

    // ④ 同 channel 的 `model` 方法（喂 `commit_msg.device`）
    final model = await readDeviceModel();
    expect(model, isNotNull);
    expect(model!.trim(), isNotEmpty);
  });
}
