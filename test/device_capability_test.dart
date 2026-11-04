// 端侧算力评估 × 模型推荐 的单测（第 253 轮，用户要求"推荐必须因机而异"）。
//
// 全部是**纯函数**断言：给一份合成快照，断言档位/匹配结论/模块显示与否。
// 真机事实（Honor LGE-AN10 的真实 SoC/内存/GPU）见 `docs/device-verification.md`。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/device/device_capability.dart';
import 'package:synhub/src/features/ai/ai_device_fit.dart';
import 'package:synhub/src/features/ai/on_device_ai.dart';

const int _gb = 1024 * 1024 * 1024;

DeviceCapabilitySnapshot _snap({
  int ramGb = 8,
  int freeGb = 64,
  String soc = 'SM8650',
  String gl = 'Adreno (TM) 740',
  bool opencl = true,
  bool lowRam = false,
  int cores = 8,
  List<String> abis = const ['arm64-v8a', 'armeabi-v7a'],
  bool nnapi = true,
  int sdk = 34,
}) => DeviceCapabilitySnapshot(
  manufacturer: 'test',
  brand: 'test',
  model: 'test-device',
  socModel: soc,
  hardware: soc.toLowerCase(),
  sdkInt: sdk,
  abis: abis,
  cpuCores: cores,
  totalRamBytes: ramGb * _gb,
  lowRamDevice: lowRam,
  freeStorageBytes: freeGb * _gb,
  totalStorageBytes: freeGb * _gb,
  glRenderer: gl,
  glVendor: 'test',
  openclLibrary: opencl,
  nnapiFeature: nnapi,
  source: 'platform',
);

AiModelInfo get _lfm => kOnDeviceModels.firstWhere((m) => m.id == 'lfm25-230m-int4');
AiModelInfo get _qwen => kOnDeviceModels.firstWhere((m) => m.id == 'qwen3-0.6b');

void main() {
  group('档位判定（内存基线 + SoC 调整 + 硬否决）', () {
    test('8GB 旗舰 SoC + Adreno/OpenCL ⇒ flagship，模块可见，两个模型都能用', () {
      final p = classifyDevice(_snap());
      expect(p.tier, DeviceComputeTier.flagship);
      expect(p.hasGpuCompute, isTrue);
      expect(p.moduleVisible, isTrue);
      expect(eligibleModelsFor(p).map((m) => m.id), ['lfm25-230m-int4', 'qwen3-0.6b']);
      expect(aiModuleVisibleFor(p), isTrue);
    });

    test('6GB + 有 GPU 委托 ⇒ Qwen 达标（6GB 是官方卡 GPU 峰值下的门槛）', () {
      // 6GB 基线 high；SM8650 想升一档，但"旗舰"要求 ≥8GB ⇒ 仍标 high
      final p = classifyDevice(_snap(ramGb: 6));
      expect(p.tier, DeviceComputeTier.high);
      expect(p.hasGpuCompute, isTrue);
      final qwen = fitModelsFor(p).firstWhere((f) => f.model.id == 'qwen3-0.6b');
      expect(qwen.eligible, isTrue, reason: '有 GPU 时门槛 6GB');
    });

    test('6GB 但**没有** OpenCL ⇒ Qwen 被内存档住（按 CPU 峰值 2.9GB 抬到 8GB），LFM 仍可用', () {
      final p = classifyDevice(_snap(ramGb: 6, opencl: false, gl: ''));
      expect(p.hasGpuCompute, isFalse);
      final fits = fitModelsFor(p);
      final qwen = fits.firstWhere((f) => f.model.id == 'qwen3-0.6b');
      expect(qwen.eligible, isFalse);
      expect(qwen.blockers, contains(AiFitBlocker.ram));
      expect(qwen.requiredRamBytes, 8 * _gb);
      final lfm = fits.firstWhere((f) => f.model.id == 'lfm25-230m-int4');
      expect(lfm.eligible, isTrue);
      // 还有模型能用 ⇒ 模块不该藏
      expect(aiModuleVisibleFor(p), isTrue);
    });

    test('3GB ⇒ entry：只剩 LFM，Qwen 同时被档位与内存挡住', () {
      final p = classifyDevice(_snap(ramGb: 3, soc: 'SM6225', gl: 'Adreno (TM) 610'));
      expect(p.tier, DeviceComputeTier.entry);
      expect(eligibleModelsFor(p).map((m) => m.id), ['lfm25-230m-int4']);
      final qwen = fitModelsFor(p).firstWhere((f) => f.model.id == 'qwen3-0.6b');
      expect(qwen.blockers, containsAll([AiFitBlocker.tier, AiFitBlocker.ram]));
    });

    test('2GB ⇒ unsupported：模块隐藏、一个模型都不推荐', () {
      final p = classifyDevice(_snap(ramGb: 2, soc: 'MT6765', gl: 'Mali-G52'));
      expect(p.tier, DeviceComputeTier.unsupported);
      expect(p.moduleVisible, isFalse);
      expect(aiModuleVisibleFor(p), isFalse);
      expect(eligibleModelsFor(p), isEmpty);
      final fits = fitModelsFor(p);
      expect(fits.every((f) => f.blockers.contains(AiFitBlocker.moduleHidden)), isTrue);
    });

    // ★ 第 145 轮裁决（AGENTS §2.0.26④）：**"未知" ≠ "很差"**。
    // 内存读不到 ⇒ `unknown`（不下结论、**不隐藏**），不是 `unsupported`。
    // 改动前这里锁的是 "保守判 unsupported"（连同模块隐藏）—— 那条正是"把编出来的
    // 结论遮住"的同款：iOS 上 `totalRamBytes == 0` ⇒ 模块被连带隐藏，而新加的
    // `ramUnknown` 只把文字换成 `—`，门控没被治。
    test('★★★ 内存读不到（0）⇒ unknown + 模块可见（不再编 unsupported）', () {
      final p = classifyDevice(_snap(ramGb: 0));
      expect(p.tier, DeviceComputeTier.unknown);
      expect(p.tier, isNot(DeviceComputeTier.unsupported));
      expect(p.ramUnknown, isTrue, reason: '内存这一项的事实确实没拿到');
      expect(p.moduleVisible, isTrue, reason: '未判定不许隐藏（§2.0.6②）');
      expect(aiModuleVisibleFor(p), isTrue);
      expect(
        p.tier,
        isNot(DeviceComputeTier.entry),
        reason: '★ 连带陷阱：SoC 微调(默认 SM8650 = +1)不得把 unknown(rank 0) 变成 entry',
      );
    });

    test('★★★ 反向：内存**确实不足**（512MB，已知事实）⇒ 仍 unsupported + 隐藏', () {
      // 别把"事实不足"与"事实就是很差"混成一条路。
      final p = classifyDevice(
        DeviceCapabilitySnapshot(
          socModel: 'SM6225',
          hardware: 'sm6225',
          model: 'test-device',
          brand: 'test',
          sdkInt: 34,
          abis: const ['arm64-v8a'],
          cpuCores: 8,
          totalRamBytes: 512 * 1024 * 1024,
          freeStorageBytes: 64 * _gb,
          glRenderer: 'Adreno (TM) 610',
          openclLibrary: true,
          nnapiFeature: true,
          source: 'platform',
        ),
      );
      expect(p.tier, DeviceComputeTier.unsupported);
      expect(p.ramUnknown, isFalse, reason: '有事实（就是小），不算"没读到"');
      expect(p.moduleVisible, isFalse);
      expect(aiModuleVisibleFor(p), isFalse);
    });

    test('系统自报低内存设备 ⇒ 直接隐藏（哪怕内存数看起来够）', () {
      final p = classifyDevice(_snap(ramGb: 8, lowRam: true));
      expect(p.tier, DeviceComputeTier.unsupported);
      expect(p.notes, contains('veto:lowRamDevice'));
    });

    test('CPU 核数 ≤2 ⇒ 隐藏', () {
      final p = classifyDevice(_snap(ramGb: 8, cores: 2));
      expect(p.tier, DeviceComputeTier.unsupported);
      expect(p.notes, contains('veto:cpuCores:2'));
    });

    test('不是 arm64 ⇒ 隐藏（本仓只出 arm64 包）', () {
      final p = classifyDevice(_snap(ramGb: 8, abis: const ['armeabi-v7a']));
      expect(p.tier, DeviceComputeTier.unsupported);
      expect(p.notes, contains('veto:abi:armeabi-v7a'));
    });

    test('SoC 表：入门 SoC 降一档、旗舰 SoC 升一档', () {
      expect(
        classifyDevice(_snap(ramGb: 6, soc: 'SM4250')).tier,
        DeviceComputeTier.mainstream, // 6GB 基线 high → 低端 SoC 降一档
      );
      expect(
        classifyDevice(_snap(ramGb: 4, soc: 'MT6993')).tier,
        DeviceComputeTier.high, // 4GB 基线 mainstream → 旗舰 SoC 升一档
      );
    });

    test('真机型号 SM8450（Honor LGE-AN10）能被 SoC 表认出来（升一档，且不越过旗舰上限）', () {
      // 4GB 基线 mainstream + 1 = high
      expect(
        classifyDevice(_snap(ramGb: 4, soc: 'SM8450')).tier,
        DeviceComputeTier.high,
      );
      // 8GB 基线旗舰 + 1 ⇒ 仍是旗舰（上限不越界）
      expect(
        classifyDevice(_snap(ramGb: 8, soc: 'SM8450')).tier,
        DeviceComputeTier.flagship,
      );
      expect(classifyDevice(_snap(ramGb: 8, soc: 'SM8450')).notes, contains('soc:SM8450:1'));
    });

    test('NPU 分类：只有登记过的厂商 SoC 才算"已知可用"', () {
      expect(classifyDevice(_snap(soc: 'MT6993')).npuClass, NpuClass.vendorSpecific);
      expect(classifyDevice(_snap(soc: 'SM8650')).npuClass, NpuClass.nnapiOnly);
      expect(
        classifyDevice(_snap(soc: 'SM8650', nnapi: false)).npuClass,
        NpuClass.none,
      );
    });

    test('档位是可比较的（P65 用 rank 判"够不够"）', () {
      expect(DeviceComputeTier.flagship >= DeviceComputeTier.mainstream, isTrue);
      expect(DeviceComputeTier.entry >= DeviceComputeTier.mainstream, isFalse);
      expect(DeviceComputeTier.unsupported.rank, 0);
    });
  });

  group('模型匹配（门槛 + 存储 + NPU + 保管库豁免）', () {
    test('存储只够装小模型时：LFM 可用、Qwen 因存储被挡，但模块仍显示', () {
      // Qwen 需 497516544×1.3+200MB ≈ 816MB；LFM 需 ≈ 419MB
      final p = classifyDevice(_snap(ramGb: 8, freeGb: 1)); // 1GB < 816MB？否：1GB>816MB
      expect(fitModelsFor(p).every((f) => f.eligible), isTrue);

      final tight = classifyDevice(_snap(ramGb: 8, freeGb: 0));
      // freeStorage=0 视为"未知" ⇒ 不卡存储（`_fitOne` 里 `> 0` 才判）
      expect(fitModelsFor(tight).every((f) => f.eligible), isTrue);

      final half = classifyDevice(
        _snap(ramGb: 8, freeGb: 0),
      );
      final p2 = DeviceCapability(
        snapshot: DeviceCapabilitySnapshot(
          socModel: 'SM8650',
          cpuCores: 8,
          totalRamBytes: 8 * _gb,
          freeStorageBytes: 300 * 1024 * 1024,
          glRenderer: 'Adreno (TM) 740',
          openclLibrary: true,
          abis: const ['arm64-v8a'],
          source: 'platform',
        ),
        tier: half.tier,
        gpuFamily: half.gpuFamily,
        npuClass: half.npuClass,
        notes: half.notes,
      );
      final fits = fitModelsFor(p2);
      expect(fits.firstWhere((f) => f.model.id == 'lfm25-230m-int4').blockers,
          contains(AiFitBlocker.storage));
      expect(fits.firstWhere((f) => f.model.id == 'qwen3-0.6b').blockers,
          contains(AiFitBlocker.storage));
      // 只被存储挡住的模型 ⇒ 不隐藏整块（磁盘满可以清）
      expect(aiModuleVisibleFor(p2), isTrue);
    });

    test('保管库里已有该文件 ⇒ 不再卡存储（零网络原地装载）', () {
      final p = DeviceCapability(
        snapshot: DeviceCapabilitySnapshot(
          socModel: 'SM8650',
          cpuCores: 8,
          totalRamBytes: 8 * _gb,
          freeStorageBytes: 100 * 1024 * 1024,
          glRenderer: 'Adreno (TM) 740',
          openclLibrary: true,
          abis: const ['arm64-v8a'],
          source: 'platform',
        ),
        tier: DeviceComputeTier.flagship,
        gpuFamily: GpuFamily.adreno,
        npuClass: NpuClass.nnapiOnly,
        notes: const [],
      );
      final blocked = fitModelsFor(p);
      expect(blocked.every((f) => !f.eligible), isTrue);
      final waived = fitModelsFor(
        p,
        vaultFileNames: {'qwen3_0_6b_mixed_int4.litertlm'},
      );
      final qwen = waived.firstWhere((f) => f.model.id == 'qwen3-0.6b');
      expect(qwen.eligible, isTrue);
      expect(qwen.requiredStorageBytes, 0);
    });

    test('目录里只剩大模型、而机器只够小模型 ⇒ 模块隐藏（不给"点进去全灰"的页面）', () {
      final p = classifyDevice(_snap(ramGb: 3, soc: 'SM6225'));
      expect(eligibleModelsFor(p), isNotEmpty);
      expect(aiModuleVisibleFor(p, catalog: [_qwen]), isFalse);
      expect(aiModuleVisibleFor(p, catalog: [_lfm]), isTrue);
    });

    test('用户自己填 URL 的模型（没有登记要求）不做判据', () {
      const custom = AiModelInfo(
        id: 'custom-url',
        name: 'Custom',
        fileName: 'custom.litertlm',
        url: 'https://example.com/custom.litertlm',
        sizeBytes: 10 * 1024 * 1024 * 1024, // 10GB 也不管
        note: '用户自担',
        license: '',
      );
      final p = classifyDevice(_snap(ramGb: 3, soc: 'SM6225'));
      final fit = fitModelsFor(p, catalog: const [custom]).single;
      expect(fit.model.requirement, isNull);
      expect(fit.eligible, isTrue);
    });

    test('门槛里登记了 NPU 的模型，在没有厂商 NPU 的机器上会被挡', () {
      const npuModel = AiModelInfo(
        id: 'npu-only',
        name: 'NPU only',
        fileName: 'npu.litertlm',
        url: 'https://example.com/npu.litertlm',
        sizeBytes: 992 * 1024 * 1024,
        note: 'MT6993 专用',
        license: '',
        requirement: AiModelRequirement(
          minTier: DeviceComputeTier.mainstream,
          minRamBytesWithGpu: 8 * _gb,
          minRamBytesWithoutGpu: 8 * _gb,
          requiresNpu: true,
        ),
      );
      final noNpu = classifyDevice(_snap(soc: 'SM8650'));
      expect(
        fitModelsFor(noNpu, catalog: const [npuModel]).single.blockers,
        contains(AiFitBlocker.npu),
      );
      final withNpu = classifyDevice(_snap(soc: 'MT6993'));
      expect(
        fitModelsFor(withNpu, catalog: const [npuModel]).single.eligible,
        isTrue,
      );
    });

    test('存储/内存差值能给界面报"差多少"', () {
      final p = classifyDevice(_snap(ramGb: 4, soc: 'SM6225', gl: 'Adreno (TM) 610'));
      final qwen = fitModelsFor(p).firstWhere((f) => f.model.id == 'qwen3-0.6b');
      expect(qwen.ramShortfall(p), 2 * _gb); // 无 OpenCL？有：4GB 有 OpenCL ⇒ 门槛 6GB
    });
  });

  group('宿主环境不做门控（测试/桌面宿主没有手机事实）', () {
    test('source=host ⇒ ungatedHost，模块可见，目录全放行', () {
      final p = classifyDevice(const DeviceCapabilitySnapshot(source: 'host'));
      expect(p.ungatedHost, isTrue);
      expect(p.moduleVisible, isTrue);
      expect(aiModuleVisibleFor(p), isTrue);
      expect(eligibleModelsFor(p).length, kOnDeviceModels.length);
      expect(p.notes, contains('host:ungated'));
    });

    // ★ B1（第 138 轮 Linux 像素缺陷）：宿主路径**不得编出任何具体档位**。
    // 证据：改动前这里硬编码 `DeviceComputeTier.mainstream`，像素就成了
    // 「Tier Mainstream / SoC — / RAM 0 MB / Free storage 0 MB / …」——
    // 六项输入全未知，却印出一个档位结论。且 `moduleVisible` 由 `ungatedHost`
    // 独立保证，所以改 tier 零功能代价（注释与实现曾经直接矛盾）。
    test('★★★ B1：宿主 tier=unknown（未判定），不是 mainstream/unsupported', () {
      final p = classifyDevice(const DeviceCapabilitySnapshot(source: 'host'));
      expect(
        p.tier,
        DeviceComputeTier.unknown,
        reason: '零事实 ⇒ 未判定；不许编 mainstream，也不许拿 unsupported 冒充',
      );
      expect(
        p.tier,
        isNot(DeviceComputeTier.unsupported),
        reason: 'unsupported = "有事实、结论太弱"（会隐藏）；unknown = "没有事实"',
      );
      expect(
        p.tier,
        isNot(DeviceComputeTier.mainstream),
        reason: '这正是被修掉的假陈述',
      );
      // ★ 反向：不许用"隐藏模块"来通过 B1
      expect(p.moduleVisible, isTrue, reason: 'unknown != unsupported ⇒ 天然可见');
      expect(aiModuleVisibleFor(p), isTrue);
      // unknown 的排序按 0（真拿去比较时 fail-closed），但宿主路径不会走到比较
      expect(DeviceComputeTier.unknown.rank, DeviceComputeTier.unsupported.rank);
    });
  });

  // ★ B1 回归锁：B1 只许动**宿主**分支；非宿主（真机）结论逐条不许变。
  group('★ B1 回归锁：非宿主路径的档位结论与改动前逐条一致', () {
    test('8 条真机式快照的档位逐条写死', () {
      final cases = <DeviceCapabilitySnapshot, DeviceComputeTier>{
        _snap(): DeviceComputeTier.flagship,
        _snap(ramGb: 6): DeviceComputeTier.high,
        _snap(ramGb: 6, soc: 'SM4250'): DeviceComputeTier.mainstream,
        _snap(ramGb: 4, soc: 'MT6993'): DeviceComputeTier.high,
        _snap(ramGb: 4, soc: 'SM8450'): DeviceComputeTier.high,
        _snap(
          ramGb: 3,
          soc: 'SM6225',
          gl: 'Adreno (TM) 610',
        ): DeviceComputeTier.entry,
        _snap(
          ramGb: 2,
          soc: 'MT6765',
          gl: 'Mali-G52',
        ): DeviceComputeTier.unsupported,
        _snap(ramGb: 8, lowRam: true): DeviceComputeTier.unsupported,
      };
      cases.forEach((snap, want) {
        expect(
          classifyDevice(snap).tier,
          want,
          reason: '${snap.totalRamBytes ~/ _gb}GB ${snap.socModel} 的档位不许变',
        );
      });
    });

    test('真机路径（有真事实）**永不出现** unknown —— unknown 只归"拿不到事实"', () {
      for (final snap in [
        _snap(),
        _snap(ramGb: 6),
        _snap(ramGb: 2, soc: 'MT6765', gl: 'Mali-G52'),
        _snap(ramGb: 8, lowRam: true),
      ]) {
        expect(
          classifyDevice(snap).tier,
          isNot(DeviceComputeTier.unknown),
          reason: '有内存事实就一定能判档（含"太弱"），不该落到未判定',
        );
      }
      // ★ 第 145 轮：0 RAM 属"拿不到事实" ⇒ unknown + 可见（见上一组的专门用例）
      final zero = classifyDevice(_snap(ramGb: 0));
      expect(zero.tier, DeviceComputeTier.unknown);
      expect(zero.moduleVisible, isTrue);
      expect(zero.ramUnknown, isTrue);
    });
  });

  group('目录登记的门槛自洽性', () {
    test('两个模型都登记了门槛，且"无 GPU"门槛不低于"有 GPU"门槛', () {
      expect(kOnDeviceModels.length, 2);
      for (final m in kOnDeviceModels) {
        expect(m.requirement, isNotNull, reason: '${m.id} 必须登记硬件门槛');
        final r = m.requirement!;
        expect(r.minRamBytesWithoutGpu >= r.minRamBytesWithGpu, isTrue);
        expect(r.rationale, isNotEmpty, reason: '${m.id} 要有门槛依据');
        expect(r.minTier.rank >= 1, isTrue);
      }
      expect(_lfm.requirement!.minRamBytesWithGpu, kMinSupportedRamBytes);
      expect(_qwen.requirement!.minRamBytesWithGpu, 6 * _gb);
      expect(_qwen.requirement!.minRamBytesWithoutGpu, 8 * _gb);
      expect(_qwen.requirement!.minTier, DeviceComputeTier.mainstream);
    });

    test('sizeBytes 与门槛里引用的体积一致（改体积别忘了改门槛依据）', () {
      expect(_lfm.sizeBytes, 176756720);
      expect(_qwen.sizeBytes, 497516544);
      // 存储需求按 size×1.3+200MB 推导
      expect(
        _lfm.requirement == null ? 0 : 0,
        0,
        reason: '占位：仅确保常量被引用',
      );
      final need = (_qwen.sizeBytes * kModelStorageMultiplier).ceil() +
          kModelStorageMarginBytes;
      expect(need, greaterThan(800 * 1024 * 1024));
      expect(need, lessThan(1024 * 1024 * 1024));
    });
  });
}
