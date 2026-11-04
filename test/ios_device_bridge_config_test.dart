// r681：iOS **端侧 AI 硬件事实桥**的**静态接线**守卫。
//
// 这一组用例只读文件（不需要模拟器、不需要构建），守的是"原生桥最易漏的那一步：
// 注册"（AGENTS §2.0.55–2.0.64 常驻第③条：pbxproj 漏 `Sources` / 漏 registrar
// **不报错**，只在运行期表现为 `MissingPluginException`）。
//
// 覆盖：
//   * Swift 实现存在，且 `static let shared`（r680 的 weak 集合教训）；
//   * 通道名/方法名与 Dart 侧一致（`synhub/device` / `capability` / `model`）；
//   * key 与 Android 侧同批（Dart 一份解析器吃两端）；
//   * `project.pbxproj`：`PBXFileReference` + `PBXBuildFile` + group + **Sources**；
//   * `AppDelegate.swift`：`registrar(forPlugin:)` + `register(with:)` 成对；
//   * 能力层：iOS 列把 `deviceHardwareInfo` 报成 available。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/device/device_capability.dart';
import 'package:synhub/src/core/platform/app_platform.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('DA315 iOS 硬件事实桥（端侧 AI 档位）', () {
    const swift = 'ios/Runner/DeviceCapabilityBridge.swift';

    test('Swift 实现存在，且用强引用单例（weak 集合会把局部实例释放掉）', () {
      expect(File(swift).existsSync(), isTrue);
      final src = _read(swift);
      expect(src, contains('static let shared = DeviceCapabilityBridge()'));
      expect(src, contains('FlutterPlugin'));
      // 通道与两个方法名（Dart 侧 `MethodChannel('synhub/device')`）
      expect(src, contains('"synhub/device"'));
      expect(src, contains('case "capability"'));
      expect(src, contains('case "model"'));
    });

    test('key 与 Android 桥同批（Dart 一份解析器吃两端）', () {
      final src = _read(swift);
      for (final key in const [
        'manufacturer',
        'brand',
        'model',
        'device',
        'board',
        'hardware',
        'socModel',
        'sdkInt',
        'release',
        'abis',
        'cpuCores',
        'cpuFeatures',
        'cpuMaxFreqKhz',
        'totalRamBytes',
        'availRamBytes',
        'lowMemory',
        'lowRamDevice',
        'freeStorageBytes',
        'totalStorageBytes',
        'glRenderer',
        'glVendor',
        'glVersion',
        'openclLibrary',
        'nnapiFeature',
        'thermalStatus',
      ]) {
        expect(src, contains('"$key"'), reason: '缺 key: $key');
      }
      // r681 新增的 iOS 两项（Dart 侧快照已接）
      expect(src, contains('"isSimulator"'));
      expect(src, contains('"lowPowerMode"'));
    });

    test('pbxproj：文件引用 + build file + group + **Sources 编译相位**缺一不可', () {
      final proj = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(proj, contains('AA96F0010000000000000001'));
      expect(proj, contains('AA96B0010000000000000001'));
      expect(
        proj,
        contains('DeviceCapabilityBridge.swift in Sources'),
        reason: '漏了 Sources 相位 ⇒ 运行时 MissingPluginException',
      );
      // 引用 count：fileRef + buildFile + group + Sources = 4 处以上
      expect('DeviceCapabilityBridge'.allMatches(proj).length,
          greaterThanOrEqualTo(4));
    });

    test('AppDelegate：registrar 与 register 成对（漏 registrar = 桥不生效）', () {
      final app = _read('ios/Runner/AppDelegate.swift');
      expect(app, contains('forPlugin: "SynHubDeviceCapability"'));
      expect(app, contains('DeviceCapabilityBridge.register(with: registrar)'));
    });

    test('能力层：iOS 的 deviceHardwareInfo 是 available（不再是 remain probe）', () {
      final caps = staticCapabilitiesFor(AppHost.ios);
      expect(caps.statusOf(AppCapability.deviceHardwareInfo).isAvailable, isTrue);
      expect(caps.can(AppCapability.deviceHardwareInfo), isTrue);
    });
  });

  group('DA315 档位规则：ABI 否决只认"32 位"', () {
    test('`arm64`（iOS 的写法）不被否决；`arm64-v8a` 也一样', () {
      for (final abi in const ['arm64', 'arm64-v8a']) {
        final cap = classifyDevice(
          DeviceCapabilitySnapshot(
            totalRamBytes: 6 * 1024 * 1024 * 1024,
            cpuCores: 6,
            abis: [abi],
            source: 'platform',
          ),
        );
        expect(cap.tier, DeviceComputeTier.high, reason: abi);
        expect(cap.notes, isNot(contains('veto:abi:$abi')));
      }
    });

    test('★ 反向：32 位 ABI（armeabi-v7a）仍然被否决（规则没被放宽）', () {
      final cap = classifyDevice(
        DeviceCapabilitySnapshot(
          totalRamBytes: 6 * 1024 * 1024 * 1024,
          cpuCores: 8,
          abis: const ['armeabi-v7a', 'armeabi'],
          source: 'platform',
        ),
      );
      expect(cap.tier, DeviceComputeTier.unsupported);
      expect(cap.notes, contains('veto:abi:armeabi-v7a/armeabi'));
    });

    test('★ 反向：`x86_64`（装错包）也算 32 位那一侧（不许放行）', () {
      final cap = classifyDevice(
        DeviceCapabilitySnapshot(
          totalRamBytes: 8 * 1024 * 1024 * 1024,
          cpuCores: 8,
          abis: const ['x86_64'],
          source: 'platform',
        ),
      );
      expect(cap.tier, DeviceComputeTier.unsupported);
    });

    test('★ 反向：ABI 为空（老桥不给）不否决 —— "没读到" ≠ "32 位"', () {
      final cap = classifyDevice(
        DeviceCapabilitySnapshot(
          totalRamBytes: 4 * 1024 * 1024 * 1024,
          cpuCores: 8,
          source: 'platform',
        ),
      );
      expect(cap.tier, DeviceComputeTier.mainstream);
      expect(cap.notes.where((n) => n.startsWith('veto:abi')), isEmpty);
    });
  });

  group('DA315 iOS SoC 调档（Apple 表）', () {
    DeviceCapability forSoc(String soc) => classifyDevice(
          DeviceCapabilitySnapshot(
            socModel: soc,
            totalRamBytes: 6 * 1024 * 1024 * 1024,
            cpuCores: 6,
            abis: const ['arm64'],
            source: 'platform',
          ),
        );

    test('A17 Pro / A18 升一档（6 GB 基线 high，仍 high；4 GB 基线升到 high）', () {
      final small = classifyDevice(
        DeviceCapabilitySnapshot(
          socModel: 'A17 Pro',
          totalRamBytes: 4 * 1024 * 1024 * 1024,
          cpuCores: 6,
          abis: const ['arm64'],
          source: 'platform',
        ),
      );
      expect(small.tier, DeviceComputeTier.high);
      expect(small.notes, contains('soc:A17 Pro:1'));
    });

    test('A15 中立（不升不降）', () {
      final cap = forSoc('A15 Bionic');
      expect(cap.tier, DeviceComputeTier.high);
      expect(cap.notes.where((n) => n.startsWith('soc:')), isEmpty);
    });

    test('A12 / A13 降一档（4 GB 基线 mainstream ⇒ entry）', () {
      final cap = classifyDevice(
        DeviceCapabilitySnapshot(
          socModel: 'A13 Bionic',
          totalRamBytes: 4 * 1024 * 1024 * 1024,
          cpuCores: 6,
          abis: const ['arm64'],
          source: 'platform',
        ),
      );
      expect(cap.tier, DeviceComputeTier.entry);
      expect(cap.notes, contains('soc:A13 Bionic:-1'));
    });

    test('★ 反向：Android 的老结论没被 Apple 表影响（SM8550 仍 +1）', () {
      final cap = forSoc('SM8550');
      expect(cap.notes, contains('soc:SM8550:1'));
    });
  });

  group('DA315 模拟器标识（读数是宿主的，必须能被区分）', () {
    test('isSimulator ⇒ notes 里带 `simulator:host-facts`', () {
      final cap = classifyDevice(
        DeviceCapabilitySnapshot(
          totalRamBytes: 32 * 1024 * 1024 * 1024,
          cpuCores: 10,
          abis: const ['arm64'],
          isSimulator: true,
          source: 'platform',
        ),
      );
      expect(cap.notes, contains('simulator:host-facts'));
      expect(cap.tier, DeviceComputeTier.flagship);
    });

    test('★ 反向：真机（isSimulator=false）不带那条 note', () {
      final cap = classifyDevice(
        DeviceCapabilitySnapshot(
          totalRamBytes: 8 * 1024 * 1024 * 1024,
          cpuCores: 6,
          abis: const ['arm64'],
          source: 'platform',
        ),
      );
      expect(cap.notes, isNot(contains('simulator:host-facts')));
    });

    test('round-trip：toPlatformMap / fromPlatformMap 不丢这两项', () {
      const s = DeviceCapabilitySnapshot(
        isSimulator: true,
        lowPowerMode: true,
        totalRamBytes: 1 << 33,
        source: 'platform',
      );
      final back = DeviceCapabilitySnapshot.fromPlatformMap(s.toJson());
      expect(back.isSimulator, isTrue);
      expect(back.lowPowerMode, isTrue);
      expect(back.totalRamBytes, 1 << 33);
    });
  });
}
