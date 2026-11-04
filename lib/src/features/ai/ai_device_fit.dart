// 端侧模型 **× 本机算力** 的匹配规则：这台机器上该看到哪些模型、模块要不要整个藏起来。
//
// 分工（别混）：
//   * `core/device/device_capability.dart` —— **采集事实 + 判档位**（不认识 AI）；
//   * 本文件 —— **模型对硬件的要求** 与 **匹配结论**（纯逻辑，可单测）；
//   * `ai_model_page.dart` —— 只负责把结论画出来 + 挡住不该装的安装动作。
//
// ## 每个模型的硬件门槛是怎么定的（★别凭印象改，改动要同步 docs/device-llm-capability.md）
//
// 官方模型卡给了**实测内存占用**（这是我们唯一能拿到的权威数字）：
//
//   * `qwen3_0_6b_mixed_int4.litertlm`（474.61 MiB，上下文 2048）
//     - GPU(OpenCL) 后端：峰值私有内存 **585 MB ~ 1856 MB**（Samsung SM-S937U1 / vivo / TECNO）
//     - CPU 后端：峰值 **约 2.9 GB**
//     - ⇒ 有 GPU 委托：6 GB 内存的机器够（585MB 峰值 + 系统 + 我们 App 自己）；
//       **没有** GPU 委托：要 8 GB（2.9GB 只是模型，CPU 解码还只有 8~13 tok/s）
//   * `LFM2.5-230M_int4.litertlm`（176.7 MB）
//     - 官方卡在 Galaxy S26 / Pixel 8a 上 GPU 与 CPU 两条腿都实测可跑；
//     - 体量 1/3 ⇒ 内存门槛取**模块下限本身**（3 GB），即"能显示模块就能跑它"。
//
// 存储门槛 = `sizeBytes × [kModelStorageMultiplier] + [kModelStorageMarginBytes]`：
// 下载写 `.part` 再改名、入库是移动（同盘不额外占），1.3 倍是给临时文件和
// "下到一半"留的余量；200 MB 是给运行时/日志的余量。
// **已经在保管库里的模型不再要存储空间**（`alreadyInVault`）—— 那正是保管库的意义。
import 'package:flutter/foundation.dart';

import '../../core/device/device_capability.dart';
import 'on_device_ai.dart';

// `AiModelRequirement` 定义在 `on_device_ai.dart`（目录要引用它；
// 写在这里会与目录互相 import），本文件只用它的规则。

/// 存储余量系数（见文件头注释）。
const double kModelStorageMultiplier = 1.3;

/// 存储固定余量（字节）。
const int kModelStorageMarginBytes = 200 * 1024 * 1024;

/// 为什么这个模型不推荐给本机。
enum AiFitBlocker {
  /// 整机太弱（模块被隐藏）。
  moduleHidden,

  /// 机器档位不够。
  ///
  /// ★ 第 145 轮：`hardwareUndetermined`（`tier == unknown`）时也走这一维，但含义是
  /// **"未判定"**而非"不够" —— 界面必须按 `tier == unknown` 换成"无法验证"的文案，
  /// 不许把 `unknown` 渲染成「档位不足」。
  tier,

  /// 内存不够。
  ram,

  /// 可用存储不够（保管库里已有则不算）。
  storage,

  /// 需要本机没有的 NPU。
  npu,
}

/// 一个模型在本机上的匹配结论。
@immutable
class AiModelFit {
  const AiModelFit({
    required this.model,
    required this.eligible,
    required this.blockers,
    required this.requiredRamBytes,
    required this.requiredStorageBytes,
  });

  final AiModelInfo model;

  /// 能不能在本机使用（界面只把 `eligible` 的模型放进"推荐"区）。
  final bool eligible;

  final List<AiFitBlocker> blockers;

  /// 本机实际生效的内存下限（已按 GPU 情况选过）。
  final int requiredRamBytes;

  /// 本机实际需要的**额外**存储（保管库已有则为 0）。
  final int requiredStorageBytes;

  /// 差多少（用于文案）：正数表示不足的字节数。
  int ramShortfall(DeviceCapability p) =>
      (requiredRamBytes - p.totalRamBytes).clamp(0, 1 << 62);

  int storageShortfall(DeviceCapability p) =>
      (requiredStorageBytes - p.freeStorageBytes).clamp(0, 1 << 62);
}

/// 目录里登记过要求的模型（`requirement != null`）。
///
/// 用户自己填 URL 的模型没有要求 ⇒ 不做判据，一律放行（那是用户自担的选择）。
List<AiModelInfo> modelsWithRequirement([List<AiModelInfo>? catalog]) =>
    (catalog ?? kOnDeviceModels).where((m) => m.requirement != null).toList();

/// 逐个模型算匹配（顺序与入参一致）。
///
/// [vaultFileNames]：保管库里**已有**的文件名 —— 有的话就不再卡存储。
List<AiModelFit> fitModelsFor(
  DeviceCapability profile, {
  List<AiModelInfo>? catalog,
  Set<String> vaultFileNames = const {},
}) {
  final list = catalog ?? kOnDeviceModels;
  return [
    for (final m in list)
      _fitOne(profile, m, alreadyInVault: vaultFileNames.contains(m.fileName)),
  ];
}

/// 本机**可用**（推荐显示）的模型。
List<AiModelInfo> eligibleModelsFor(
  DeviceCapability profile, {
  List<AiModelInfo>? catalog,
  Set<String> vaultFileNames = const {},
}) {
  if (!profile.moduleVisible) return const [];
  return fitModelsFor(
    profile,
    catalog: catalog,
    vaultFileNames: vaultFileNames,
  ).where((f) => f.eligible).map((f) => f.model).toList();
}

/// 端侧 AI 模块要不要显示（**唯一的判定入口**）。
///
/// 规则：本机档位不是 `unsupported` 且**至少有一个**登记过要求的模型可用。
/// 只靠档位还不够：例如一台 3 GB 的机器档位是 `entry`，而目录里将来若只剩
/// 需要 6 GB 的模型时，模块就该藏起来而不是给一个"点进去全是灰的"页面。
bool aiModuleVisibleFor(
  DeviceCapability profile, {
  List<AiModelInfo>? catalog,
  Set<String> vaultFileNames = const {},
}) {
  if (profile.ungatedHost) return true; // 宿主：不门控
  if (!profile.moduleVisible) return false;
  // ★ 第 145 轮：**事实不足 ≠ 硬件不行**。`tier == unknown`（宿主，或拿不到内存
  //   的移动端，如 iOS）时 `_fitOne` 会同时给出 `tier`/`ram` 两个 blocker，但那两个
  //   都源于"没读到"、不是"读到了、太小" ⇒ 若照旧走下面的 `any(...)`，模块会因为
  //   "没有数据"被隐藏，缺陷原地复发（§2.0.6②：**未判定不许隐藏**）。
  if (profile.tier == DeviceComputeTier.unknown) return true;
  // ★ 存储不足**不算**硬件不行：磁盘满是可以马上清的，所以只被存储挡住的模型
  //   仍然让模块显示（页面会把它列进"本机不适用"并说清缺多少空间），
  //   真正的弱机（内存/核数/ABI）才隐藏整块。
  return fitModelsFor(
    profile,
    catalog: catalog,
    vaultFileNames: vaultFileNames,
  ).any((f) => f.eligible || _onlyStorageBlocked(f));
}

bool _onlyStorageBlocked(AiModelFit f) =>
    f.blockers.isNotEmpty && f.blockers.every((b) => b == AiFitBlocker.storage);

AiModelFit _fitOne(
  DeviceCapability p,
  AiModelInfo m, {
  required bool alreadyInVault,
}) {
  final req = m.requirement;
  // 宿主/测试环境：不在手机能力上做判据（档位数字仍算出来给界面显示）
  if (p.ungatedHost) {
    return AiModelFit(
      model: m,
      eligible: true,
      blockers: const [],
      requiredRamBytes: req?.minRamBytesFor(p) ?? 0,
      requiredStorageBytes: req == null
          ? 0
          : (m.sizeBytes * kModelStorageMultiplier).ceil() +
                kModelStorageMarginBytes,
    );
  }
  final blockers = <AiFitBlocker>[];
  if (req == null) {
    // 没登记要求的（用户自填 URL）不判：给一个"按最小模型算"的展示值
    return AiModelFit(
      model: m,
      eligible: true,
      blockers: const [],
      requiredRamBytes: 0,
      requiredStorageBytes: 0,
    );
  }
  final needRam = req.minRamBytesFor(p);
  final needStorage = alreadyInVault
      ? 0
      : (m.sizeBytes * kModelStorageMultiplier).ceil() + kModelStorageMarginBytes;

  if (!p.moduleVisible) blockers.add(AiFitBlocker.moduleHidden);
  if (p.hardwareUndetermined) {
    // ★ 第 145 轮：**未判定 ≠ 不够**。档位与内存都**没有事实** ⇒ 一句话都不许下：
    //   "机器档位不足"/"内存不足（需 X 本机 Y）"都是"没有数据却给结论"（§2.0.26），
    //   而且 `Y` 会画成 `0 GB` —— 那正是 B2 同一个病。
    //   ⇒ 不加 `ram` blocker（差多少根本算不出来），只留 `tier` 这一维表示
    //   "档位判据未通过"，界面再按 `tier == unknown` 如实说"**无法验证是否适配**"。
    //   ★ 仍然 **fail-closed**：`eligible` 保持 `false` ⇒ 不发起下载（但理由不是"本机不行"）。
    //   ★ 复用既有维度、不新增第三种表示（§2.0.26 规矩 2：判据唯一来源 = `tier`）。
    blockers.add(AiFitBlocker.tier);
  } else {
    if (p.tier.rank < req.minTier.rank) blockers.add(AiFitBlocker.tier);
    if (p.totalRamBytes < needRam) blockers.add(AiFitBlocker.ram);
  }
  if (!alreadyInVault && p.freeStorageBytes > 0 &&
      p.freeStorageBytes < needStorage) {
    blockers.add(AiFitBlocker.storage);
  }
  if (req.requiresNpu &&
      !p.hardwareUndetermined &&
      p.npuClass != NpuClass.vendorSpecific) {
    // NPU 同理：没读到事实时也不许断言"本机没有厂商 NPU"。
    blockers.add(AiFitBlocker.npu);
  }
  return AiModelFit(
    model: m,
    eligible: blockers.isEmpty,
    blockers: blockers,
    requiredRamBytes: needRam,
    requiredStorageBytes: needStorage,
  );
}
