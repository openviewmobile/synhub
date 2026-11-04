// 本机**算力画像**：端侧大模型该给这台机器推荐什么、要不要把整个模块藏起来。
//
// ⚠️ 别和 `device_profile.dart` 搞混（两个不同的东西，第 253 轮改名避免歧义）：
//   * `device_profile.dart` 的 `DeviceProfile` = **界面效果的档位**
//     （毛玻璃/动效/网格，low/medium/high，只看核数+内存+SDK，同步读 `/proc`）；
//   * 本文件的 `DeviceCapability` = **端侧模型的算力依据**
//     （SoC/GPU/NPU/存储/低内存标记 + `unsupported` 档，异步走原生桥）。
//   两者在这台真机上结论一致（都是"高端"），但**规则与用途不同**，不要合并：
//   界面效果没有"这台机器不能显示毛玻璃"这种硬隐藏需求。
//
// ## 为什么要有它（用户 2026-09-25 明确要求）
//
// 原话：「端侧大模型这块需要加入对端硬件计算能力的评估，根据目前手机的 CPU 型号和算力、
// 内存大小、存储空间、是否 GPU/NPU 可用等维度来评估该手机适合使用什么大模型，
// 而不是一股脑地推荐超出该手机硬件计算能力的模型。一句话来说也就是你推荐的模型
// 必须根据手机设备而异，不同的手机看到的是不同的模型，不能所有手机统一下载使用
// 同一套模型。对于手机硬件能力实在太差的设备，需要将端侧大模型这个功能模块隐藏处理。」
//
// 因此这里做三件事：
//   ① **采集事实**：走原生桥 `synhub/device` 的 `capability` 方法
//      （`DeviceModelBridge.kt`：SoC/核数/内存/存储/GPU/NPU/热状态），
//      拿不到平台时回落到 `/proc/meminfo`、`/proc/cpuinfo`、`Platform.numberOfProcessors`；
//   ② **算档位**：把事实折成一个 [DeviceComputeTier]
//      （unsupported/entry/mainstream/high/flagship，以及"拿不到事实"时的 unknown）
//      —— 规则全在这个文件里，纯函数、可单测、可审计；
//   ③ **给理由**：每个结论都带 [DeviceCapability.notes]，界面上能如实告诉用户"为什么"。
//
// ## 事实来源与口径（别凭印象改）
//
// * **内存**用 `ActivityManager.MemoryInfo.totalMem`（Android 的"物理内存"，不是
//   `/proc/meminfo` 的 MemTotal —— 后者在部分机型上不含内核保留区，会偏小）；
// * **存储**用应用数据目录所在分区的 `StatFs.availableBytes`（模型是下到这里再入库的，
//   别的分区再大也用不上）；
// * **GPU** 用自建 EGL/GLES2 上下文读来的 `GL_RENDERER`（真的显卡名字，
//   `Adreno (TM) 650` / `Mali-G78` / `Immortalis-G715` …），不用 `Build.BOARD` 猜；
// * **OpenCL** 只查 `libOpenCL.so` 在不在标准路径 —— LiteRT-LM 的 GPU 委托走 OpenCL，
//   有没有这个库是最接近"GPU 后端能不能用"的廉价判据；查不到就按"没有"处理（保守）；
// * **NPU** 分两层：`hasSystemFeature("android.hardware.neuralnetworks")` 只说明
//   NNAPI 存在；**能不能真用上**要连 SoC 一起看（官方就有一个
//   `Qwen3-0.6B.mediatek.mt6993.litertlm` 是给 MT6993 的 a16w8 NPU 专用的）。
//   所以这里给的是 [NpuClass]，只有 `vendorSpecific` 才是"已知可用"。
// * **热状态**只是当下快照，**不参与**推荐（同一台机器边充电边跑就是另一个值）。
//
// ## 档位规则（阈值全部是常量，改这里就够了）
//
// 先按内存给一个基线档，再用 SoC 表**最多上/下调一档**：
//
// | 内存 | 基线档 |
// |---|---|
// | < [kMinSupportedRamBytes]（3 GB） | `unsupported` |
// | 3–4 GB | `entry` |
// | 4–6 GB | `mainstream` |
// | 6–8 GB | `high` |
// | ≥ 8 GB | `flagship` |
//
// 另有三条**硬否决**（直接 `unsupported`，与内存无关）：
// * `ActivityManager.isLowRamDevice == true`（系统自己说这是低内存机）；
// * CPU 核数 ≤ [kMinSupportedCores]（2）；
// * ABI 里没有 `arm64-v8a`（本仓只出 arm64，32 位机器根本装不了我们的包）。
//
// ★ 诚实边界：这套阈值是**工程下限**，不是官方文档给的数字。可对照的官方数字只有
// 模型卡上的实测内存占用（见 `docs/device-llm-capability.md`：Qwen3-0.6B mixed int4
// 在 GPU 后端峰值 585–1856 MB、CPU 后端约 2.9 GB），我们据此把"没有 OpenCL 的机器"
// 要求抬到 8 GB。真机验证记录在 `docs/device-verification.md`。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

import '../platform/app_platform.dart';
import '../system_open.dart' show isTestEnvironment;

/// 端侧 AI 模块**最低**要求的内存（低于它：整个模块隐藏）。
const int kMinSupportedRamBytes = 3 * 1024 * 1024 * 1024;

/// 端侧 AI 模块**最低**要求的 CPU 核数（低于它：整个模块隐藏）。
const int kMinSupportedCores = 2;

/// 认得出来的 **64 位** ABI。
///
/// * `arm64-v8a` = Android（本仓只出这一档）；
/// * `arm64` = iOS（Apple 从 A7 起只有 arm64；模拟器在 Apple Silicon 上也是它）。
///
/// ★ 这张表的用途只有一个：判断"这台机器是不是 32 位"。**别**往里加
/// `x86_64`（那说明我们装错包了，反而该否决）。
const Set<String> kSupportedAbis = {'arm64-v8a', 'arm64'};

const int _gb = 1024 * 1024 * 1024;

/// 机器档位（决定"能看到哪些模型"）。
enum DeviceComputeTier {
  /// 太弱/不适用 ⇒ **整个端侧 AI 模块隐藏**。
  unsupported,

  /// 入门：只够跑最小那档（~170MB、230M 参数）。
  entry,

  /// 主流：能跑 0.6B int4（有 GPU 委托时）。
  mainstream,

  /// 高：0.6B 舒适，可考虑更大的。
  high,

  /// 旗舰：8 GB+ 且 SoC 属高端。
  flagship,

  /// **未判定**：这台机器上根本拿不到判档所需的事实（宿主/桌面/测试环境，
  /// `source == 'host'`）⇒ 不编任何具体档位。
  ///
  /// ★ 与 [unsupported] 的区别是**语义**上的，不是程度：
  ///   * `unsupported` = **有事实、结论是"太弱"** ⇒ 模块隐藏（fail-closed）；
  ///   * `unknown`   = **没有事实、不下结论** ⇒ 按 AGENTS §2.0.6 铁律②
  ///     "还没探测完不隐藏"，**不隐藏**。
  ///   宿主路径的模块可见性由 [DeviceCapability.ungatedHost] 独立保证，
  ///   所以这个值**不参与门控**；它只是把"不知道"如实说出来（界面画 `—`）。
  ///   `rank` 取 0（与 unsupported 同：真拿去比较时按"不够"处理，fail-closed）。
  unknown;

  /// 界面上显示的顺序（unsupported/unknown 不显示具体档位名）。
  int get rank => switch (this) {
    DeviceComputeTier.unsupported => 0,
    DeviceComputeTier.unknown => 0,
    DeviceComputeTier.entry => 1,
    DeviceComputeTier.mainstream => 2,
    DeviceComputeTier.high => 3,
    DeviceComputeTier.flagship => 4,
  };

  bool operator >=(DeviceComputeTier other) => rank >= other.rank;
}

/// NPU 可用性分类（**保守**：只有明确已知的厂商方案才算"可用"）。
enum NpuClass {
  /// 没有 NNAPI，或查询失败。
  none,

  /// 有 NNAPI（`android.hardware.neuralnetworks`），但不知道哪个 SoC 能用上。
  nnapiOnly,

  /// 已知该 SoC 有厂商专用 NPU 产物（例：MediaTek MT6993 的 a16w8 变体）。
  vendorSpecific,
}

/// 采集到的**原始事实**（一个字段对应桥里的一个 key；缺项都有中性默认值）。
@immutable
class DeviceCapabilitySnapshot {
  const DeviceCapabilitySnapshot({
    this.manufacturer = '',
    this.brand = '',
    this.model = '',
    this.socModel = '',
    this.socManufacturer = '',
    this.hardware = '',
    this.board = '',
    this.sdkInt = 0,
    this.release = '',
    this.abis = const [],
    this.cpuCores = 0,
    this.cpuFeatures = '',
    this.cpuMaxFreqKhz = 0,
    this.totalRamBytes = 0,
    this.availRamBytes = 0,
    this.lowMemory = false,
    this.lowRamDevice = false,
    this.freeStorageBytes = 0,
    this.totalStorageBytes = 0,
    this.glRenderer = '',
    this.glVendor = '',
    this.glVersion = '',
    this.openclLibrary = false,
    this.nnapiFeature = false,
    this.thermalStatus = -1,
    this.isSimulator = false,
    this.lowPowerMode = false,
    this.source = 'unknown',
  });

  final String manufacturer;
  final String brand;
  final String model;
  final String socModel;
  final String socManufacturer;
  final String hardware;
  final String board;
  final int sdkInt;
  final String release;
  final List<String> abis;
  final int cpuCores;
  final String cpuFeatures;
  final int cpuMaxFreqKhz;
  final int totalRamBytes;
  final int availRamBytes;
  final bool lowMemory;
  final bool lowRamDevice;
  final int freeStorageBytes;
  final int totalStorageBytes;
  final String glRenderer;
  final String glVendor;
  final String glVersion;
  final bool openclLibrary;
  final bool nnapiFeature;

  /// `PowerManager.currentThermalStatus`（-1 = 取不到/系统太旧）。
  final int thermalStatus;

  /// ★ r681：**iOS 模拟器**（`targetEnvironment(simulator)`）。
  ///
  /// 为什么必须在快照里：模拟器的 `totalRamBytes` / `glRenderer` 读的是
  /// **宿主 Mac** 的事实 ⇒ 不把这位置标出来，"模拟器 = 旗舰机"会被当成设备结论。
  /// Android 那套桥没有这个字段 ⇒ 恒 `false`。
  final bool isSimulator;

  /// iOS 低电量模式（`ProcessInfo.isLowPowerModeEnabled`）—— **当下功耗状态**，
  /// 不参与档位/门控（与 `thermalStatus` 同档语义）。
  final bool lowPowerMode;

  /// 这份快照是哪来的：`platform` / `proc` / `none` / **`synthetic`**（报告与排错用）。
  final String source;

  /// ★ 第 448 轮：这份画像是**合成**的（QA 诊断文件在场），**不是**真实硬件。
  ///
  /// 判据只有**一个**：`source == 'synthetic'` —— 界面上"这是合成画像"的提示
  /// 与证据里的判据都取它，**不要**另立局部布尔（AGENTS §2.0.26 同型）。
  bool get syntheticProfile => source == 'synthetic';

  Map<String, Object?> toJson() => {
    'manufacturer': manufacturer,
    'brand': brand,
    'model': model,
    'socModel': socModel,
    'socManufacturer': socManufacturer,
    'hardware': hardware,
    'board': board,
    'sdkInt': sdkInt,
    'release': release,
    'abis': abis,
    'cpuCores': cpuCores,
    'cpuFeatures': cpuFeatures,
    'cpuMaxFreqKhz': cpuMaxFreqKhz,
    'totalRamBytes': totalRamBytes,
    'availRamBytes': availRamBytes,
    'lowMemory': lowMemory,
    'lowRamDevice': lowRamDevice,
    'freeStorageBytes': freeStorageBytes,
    'totalStorageBytes': totalStorageBytes,
    'glRenderer': glRenderer,
    'glVendor': glVendor,
    'glVersion': glVersion,
    'openclLibrary': openclLibrary,
    'nnapiFeature': nnapiFeature,
    'thermalStatus': thermalStatus,
    // r681：iOS 桥给的两项（Android 没有 ⇒ 恒 false，写回去无副作用）
    'isSimulator': isSimulator,
    'lowPowerMode': lowPowerMode,
    'source': source,
  };

  static DeviceCapabilitySnapshot fromPlatformMap(
    Map<Object?, Object?> m, {
    String source = 'platform',
  }) {
    T? pick<T>(String k) {
      final v = m[k];
      return v is T ? v : null;
    }

    final abis = (m['abis'] as List?)?.whereType<String>().toList() ?? const [];
    return DeviceCapabilitySnapshot(
      manufacturer: pick<String>('manufacturer') ?? '',
      brand: pick<String>('brand') ?? '',
      model: pick<String>('model') ?? '',
      socModel: pick<String>('socModel') ?? '',
      socManufacturer: pick<String>('socManufacturer') ?? '',
      hardware: pick<String>('hardware') ?? '',
      board: pick<String>('board') ?? '',
      sdkInt: pick<int>('sdkInt') ?? 0,
      release: pick<String>('release') ?? '',
      abis: abis,
      cpuCores: pick<int>('cpuCores') ?? 0,
      cpuFeatures: pick<String>('cpuFeatures') ?? '',
      cpuMaxFreqKhz: (pick<num>('cpuMaxFreqKhz') ?? 0).toInt(),
      totalRamBytes: (pick<num>('totalRamBytes') ?? 0).toInt(),
      availRamBytes: (pick<num>('availRamBytes') ?? 0).toInt(),
      lowMemory: pick<bool>('lowMemory') ?? false,
      lowRamDevice: pick<bool>('lowRamDevice') ?? false,
      freeStorageBytes: (pick<num>('freeStorageBytes') ?? 0).toInt(),
      totalStorageBytes: (pick<num>('totalStorageBytes') ?? 0).toInt(),
      glRenderer: pick<String>('glRenderer') ?? '',
      glVendor: pick<String>('glVendor') ?? '',
      glVersion: pick<String>('glVersion') ?? '',
      openclLibrary: pick<bool>('openclLibrary') ?? false,
      nnapiFeature: pick<bool>('nnapiFeature') ?? false,
      thermalStatus: (pick<num>('thermalStatus') ?? -1).toInt(),
      isSimulator: pick<bool>('isSimulator') ?? false,
      lowPowerMode: pick<bool>('lowPowerMode') ?? false,
      source: source,
    );
  }
}

/// 采集入口的类型（便于测试注入假数据）。
typedef DeviceCapabilityProbe =
    Future<DeviceCapabilitySnapshot> Function();

const MethodChannel _deviceChannel = MethodChannel('synhub/device');

/// ★ 第 448 轮：**QA 合成画像**的文件名（放在应用私有支持目录里）。
///
/// 为什么需要它：本机是 8 GB / 8 核 / arm64 ⇒ 按规则永远是 `high`，
/// 「弱机 ⇒ 端侧模块隐藏」这条分支**在这台真机上不可能自然出现**
/// （`docs/device-llm-capability.md` §6.3 记的正是这个开口）。
/// 于是把"喂一张假的硬件事实"做成**一次性、显式、可撤**的诊断入口：
/// 私有目录里有这个文件 ⇒ 用它；没有 ⇒ 走真实硬件（**默认路径不变**）。
const String kQaSyntheticCapabilityFileName = 'qa_device_capability.json';

/// 读取 QA 合成画像；**没有文件/解析失败一律回 `null`（＝走真实硬件）**。
///
/// 三条纪律：
///   ① 只在**应用私有目录**里找（别的应用写不进去；不读共享存储）；
///   ② 只在**手机宿主**上生效（调用方 `probeDeviceCapability` 已经先判了宿主）；
///   ③ 打上 `source: 'synthetic'` ⇒ 界面上会**明说这是合成画像**，不冒充真机事实。
Future<DeviceCapabilitySnapshot?> readQaSyntheticCapability({
  Directory? dir,
  String fileName = kQaSyntheticCapabilityFileName,
}) async {
  try {
    final base = dir ?? await getApplicationSupportDirectory();
    final f = File('${base.path}/$fileName');
    if (!f.existsSync()) return null;
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is! Map) return null;
    return DeviceCapabilitySnapshot.fromPlatformMap(
      raw.cast<Object?, Object?>(),
      source: 'synthetic',
    );
  } catch (_) {
    // 坏 JSON / 没有权限 / 平台没有支持目录 ⇒ 当作"没有画像"，绝不抛给上层。
    return null;
  }
}

/// 真机走原生桥；失败/测试环境回落 `/proc`。
Future<DeviceCapabilitySnapshot> probeDeviceCapability() async {
  if (!_isMobileHost) {
    // 桌面/测试宿主：这里**没有**手机硬件这一说，别拿 `/proc` 的残缺数据
    // 去猜一个档位 —— 能力门控只对手机生效（`source: 'host'`）。
    return const DeviceCapabilitySnapshot(source: 'host');
  }
  // ★ 第 448 轮：QA 合成画像**优先于**原生桥（只在手机宿主、只在文件在场时）。
  final qa = await readQaSyntheticCapability();
  if (qa != null) return qa;
  if (!isTestEnvironment &&
      !kIsWeb &&
      capabilityGateAllows(AppCapability.deviceHardwareInfo)) {
    try {
      final raw = await _deviceChannel.invokeMapMethod<Object?, Object?>(
        'capability',
      );
      if (raw != null && raw.isNotEmpty) {
        return DeviceCapabilitySnapshot.fromPlatformMap(raw);
      }
    } on MissingPluginException {
      // 桌面/未注册：往下回落
    } on PlatformException {
      // 原生侧出错：往下回落
    }
  }
  return readProcCapabilitySnapshot();
}

/// 无平台通道时的回落：**只读 `/proc`**（Android/Linux 上够用；其它系统给空）。
///
/// 这里刻意**不假装**能拿到 GPU/NPU：拿不到就是空/false，档位规则会按保守处理。
Future<DeviceCapabilitySnapshot> readProcCapabilitySnapshot() async {
  if (kIsWeb) return const DeviceCapabilitySnapshot(source: 'none');
  try {
    var totalRam = 0;
    final meminfo = File('/proc/meminfo');
    if (meminfo.existsSync()) {
      for (final line in meminfo.readAsLinesSync()) {
        if (line.startsWith('MemTotal:')) {
          final kb = int.tryParse(
            line.replaceAll(RegExp(r'[^0-9]'), ''),
          );
          if (kb != null) totalRam = kb * 1024;
        }
      }
    }
    var hardware = '';
    var features = '';
    final cpuinfo = File('/proc/cpuinfo');
    if (cpuinfo.existsSync()) {
      for (final line in cpuinfo.readAsLinesSync()) {
        if (hardware.isEmpty &&
            (line.startsWith('Hardware') || line.startsWith('model name'))) {
          hardware = _afterColon(line);
        }
        if (features.isEmpty &&
            (line.startsWith('Features') || line.startsWith('flags'))) {
          features = _afterColon(line);
        }
      }
    }
    var maxFreq = 0;
    final freq = File('/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq');
    if (freq.existsSync()) {
      maxFreq = int.tryParse(freq.readAsStringSync().trim()) ?? 0;
    }
    var free = 0;
    var total = 0;
    try {
      final dir = Directory.systemTemp;
      // 用 `stat` 拿不了剩余空间，这里用 `df` 的 POSIX 输出（Android 上一定有）
      final r = Process.runSync('df', ['-k', dir.path]);
      if (r.exitCode == 0) {
        final lines = (r.stdout as String).trim().split('\n');
        if (lines.length >= 2) {
          final cols = lines[1].split(RegExp(r'\s+'));
          if (cols.length >= 4) {
            final kbFree = int.tryParse(cols[3]) ?? 0;
            final kbTotal = int.tryParse(cols[1]) ?? 0;
            free = kbFree * 1024;
            total = kbTotal * 1024;
          }
        }
      }
    } catch (_) {
      // 拿不到就算了，保持 0
    }
    return DeviceCapabilitySnapshot(
      hardware: hardware,
      cpuCores: Platform.numberOfProcessors,
      cpuFeatures: features,
      cpuMaxFreqKhz: maxFreq,
      totalRamBytes: totalRam,
      availRamBytes: totalRam,
      freeStorageBytes: free,
      totalStorageBytes: total,
      source: 'proc',
    );
  } catch (_) {
    return const DeviceCapabilitySnapshot(source: 'none');
  }
}

/// 只有 Android/iOS 才做端侧算力门控。
///
/// 第 279 轮：改问平台能力层（`AppHost.isMobile`），口径与
/// `ai_providers.dart` 的 `aiPlatformSupported` 严格一致 ——
/// 桌面宿主一律 `source: 'host'`（**不编**手机硬件事实，AGENTS §2.0.6 第 3 条）。
bool get _isMobileHost => currentAppHost.isMobile;

String _normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// SoC → 档位调整（`-1` 降一档 / `0` 不动 / `+1` 升一档）。
///
/// 表是**人工登记**的（写死型号前缀），依据是该型号的公开定位；查不到就 0（不动）。
/// ★ 改这张表要同时改 `docs/device-llm-capability.md` 里的说明。
int socTierAdjustment(DeviceCapabilitySnapshot s) {
  final candidates = [s.socModel, s.hardware, s.board]
      .map(_normalize)
      .where((x) => x.isNotEmpty)
      .toList();
  if (candidates.isEmpty) return 0;
  bool any(List<String> prefixes) => candidates.any(
    (c) => prefixes.any(c.startsWith),
  );

  // 旗舰/高端 SoC（升一档，最多到 flagship）
  if (any(const [
    'sm8750', 'sm8650', 'sm8550', 'sm8475', // Snapdragon 8 Gen 3/2/1/+
    'sm8450', 'sm8350', 'sm8250', 'sm8150', // 骁龙 8 Gen 1 / 888 / 865 / 855
    'sm8850', 'sm8845', // Snapdragon 8 Elite 世代
    'mt6991', 'mt6993', 'mt6989', 'mt6985', 'mt6983', // 天玑 9400/9300/9200/9000
    'tensor', 'gs201', 'gs301', // Google Tensor 全系偏高端
    'exynos2400', 'exynos2300', 'exynos2200', 's5e9', // Exynos 高端
    'kirin9000', 'kirin9010', 'kirin9020', 'hi3', // 麒麟旗舰
    // ★ r681：Apple 侧（iOS 桥给的是 `SoC 名`，不是 machine id）
    //   A14 及更早不升；A15/A16 中立；A17 Pro / A18 / M 系列升一档。
    'a17pro', 'a18', 'a18pro', 'm1', 'm2', 'm3', 'm4',
  ])) {
    return 1;
  }
  // 入门 SoC（降一档）
  if (any(const [
    'sm4250', 'sm4350', 'sm4450', 'sm6115', 'sm6125', 'sm6225', // 骁龙 4xx/6xx
    'mt6765', 'mt6768', 'mt6769', 'mt6833', 'mt6853', // Helio G / 天玑 6xx-7xx 低端
    'ums', 'unisoc', 'sc98', 't606', 't610', 't612', 't616', // 紫光展锐
    'exynos850', 'exynos1330', 'exynos1280',
    'kirin710', 'kirin810', 'kirin820',
    // ★ r681：Apple 老机型（A12/A13 一代）降一档 —— 它们大多 3–4 GB 内存，
    //   与"entry/mainstream"的边界正好重合，降档只是把标签摆正。
    'a12', 'a13',
  ])) {
    return -1;
  }
  return 0;
}

/// GPU 家族（从 `GL_RENDERER` 认；认不出就 `unknown`）。
enum GpuFamily { adreno, mali, immortalis, xclipse, powerVr, apple, unknown }

GpuFamily gpuFamilyOf(String glRenderer) {
  final r = _normalize(glRenderer);
  if (r.isEmpty) return GpuFamily.unknown;
  if (r.contains('adreno')) return GpuFamily.adreno;
  if (r.contains('immortalis')) return GpuFamily.immortalis;
  if (r.contains('mali')) return GpuFamily.mali;
  if (r.contains('xclipse')) return GpuFamily.xclipse;
  if (r.contains('powervr') || r.contains('rogue') || r.contains('dseries')) {
    return GpuFamily.powerVr;
  }
  if (r.contains('apple') || r.contains('metal')) return GpuFamily.apple;
  return GpuFamily.unknown;
}

/// 这台机器的**结论**：档位 + 各类能力 + 给用户看的理由。
@immutable
class DeviceCapability {
  const DeviceCapability({
    required this.snapshot,
    required this.tier,
    required this.gpuFamily,
    required this.npuClass,
    required this.notes,
    this.ungatedHost = false,
  });

  final DeviceCapabilitySnapshot snapshot;
  final DeviceComputeTier tier;
  final GpuFamily gpuFamily;
  final NpuClass npuClass;

  /// 人类可读的判断依据（界面"本机能力"卡片直接用；**不本地化**，
  /// 界面按 key 换文案 —— 这里存的是稳定 token + 原始值）。
  final List<String> notes;

  /// 宿主/测试环境（非手机）：**不做**端侧能力门控（见 [classifyDevice]）。
  final bool ungatedHost;

  int get totalRamBytes => snapshot.totalRamBytes;
  int get freeStorageBytes => snapshot.freeStorageBytes;
  int get cpuCores => snapshot.cpuCores;

  /// 有没有可用的 GPU 计算后端（LiteRT-LM 走 OpenCL）。
  bool get hasGpuCompute =>
      snapshot.openclLibrary && gpuFamily != GpuFamily.unknown;

  /// 模块是否显示（unsupported ⇒ 隐藏；宿主环境不受此门控）。
  bool get moduleVisible =>
      ungatedHost || tier != DeviceComputeTier.unsupported;

  /// ★ r132（iOS 逐屏走查）：**内存事实没读到**（不是"内存是 0"）。
  ///
  /// iOS 上没有 `/proc/meminfo`、也还没有硬件桥 ⇒ 快照里 `totalRamBytes == 0`，
  /// 界面照原样画就成了「RAM 0 MB / Tier Unsupported / 端侧 AI 已隐藏」+
  /// 「本机只有 0 GB 内存」——把"探测失败"说成了"设备事实"（AGENTS §2.0.6②③）。
  ///
  /// ★★ 口径（第 142 轮裁决，AGENTS §2.0.26）：**"结论"只有一个事实来源**
  /// = [tier]（`DeviceComputeTier.unknown` = 不下结论）。这里是**派生只读视图**，
  /// 用来回答"内存这一项的事实有没有拿到"（快照层），**不是**第二种结论表示，
  /// 也**不**参与门控（门控只看 `tier`）。两边的关系：
  ///   * `tier == unknown` —— 整机不下结论（宿主 `source == 'host'`，
  ///     或移动端连内存事实都没拿到，如 iOS；第 145 轮起**两条路都归到 unknown**，
  ///     所以模块**不再被 `unsupported` 连带隐藏**）；
  ///   * `ramUnknown` —— 内存这一项的展示粒度（宿主，或 iOS 这类没有硬件桥的移动端）。
  /// 若哪天不需要"内存这一项"的展示粒度，这个 getter 应当直接删掉。
  bool get ramUnknown => snapshot.totalRamBytes <= 0;

  /// ★ 第 145 轮：**硬件事实是否"未判定"** —— 可读的**派生名字**，判据仍是 [tier]。
  ///
  /// `true` = 我们没有足够的本机事实去下任何档位结论（宿主没有任何手机事实；
  /// iOS 这类平台拿不到 `/proc`，也还没有硬件探测桥）。**不等于"设备很差"**。
  ///
  /// ★★ 规矩（AGENTS §2.0.26 规矩 2）：这不是第二个存储字段、也永远**不参与门控**
  /// 或判可用性 —— 那些只看 `tier`（`unknown` = 不下结论）。同 [ramUnknown]：
  /// 如果哪天不再需要可读名字，就该直接删掉。
  ///
  /// ★ 边界：`ramUnknown == true` 而 `tier != unknown` 理论上**不该**出现
  /// （内存没读到 ⇒ `_ramBaselineTier` 就给 `unknown`）。万一出现（例如将来
  /// 换了别的判据来源），**一律以 `tier` 为准**，不要拿这个 getter 去反推结论。
  bool get hardwareUndetermined => tier == DeviceComputeTier.unknown;

  double get totalRamGb => totalRamBytes / _gb;
  double get freeStorageGb => freeStorageBytes / _gb;

  /// 「SoC 型号」标签：优先 `SOC_MODEL`，回落 hardware/board，再回落品牌+型号。
  String get socLabel {
    for (final v in [
      snapshot.socModel,
      snapshot.hardware,
      snapshot.board,
    ]) {
      if (v.trim().isNotEmpty) return v.trim();
    }
    return '${snapshot.brand} ${snapshot.model}'.trim();
  }

  String get gpuLabel =>
      snapshot.glRenderer.trim().isEmpty ? '' : snapshot.glRenderer.trim();

  @override
  String toString() =>
      'DeviceCapability(${tier.name}, ram=${totalRamGb.toStringAsFixed(1)}GB, '
      'soc=$socLabel, gpu=${gpuFamily.name}, npu=${npuClass.name})';
}

/// 把快照折成档位。**纯函数**（同一份快照永远同一个结论，便于断言）。
DeviceCapability classifyDevice(DeviceCapabilitySnapshot s) {
  // 宿主/测试环境（`source == 'host'`）：不判档、不否决、模块视为可见。
  // 理由：能力门控是**手机**的事；宿主上拿不到手机事实，就不该编一个结论。
  // ⇒ 档位用 [DeviceComputeTier.unknown]（**未判定**），**不是** mainstream
  //   （第 138 轮 Linux 像素缺陷：零数据却印出 `Tier: Mainstream`）。
  //   注意这里**不是** `unsupported`：那是"有事实、结论太弱"，会让模块隐藏；
  //   "还没探测完"不许隐藏（AGENTS §2.0.6 铁律②）。可见性另由 `ungatedHost` 保证。
  if (s.source == 'host') {
    return const DeviceCapability(
      snapshot: DeviceCapabilitySnapshot(source: 'host'),
      tier: DeviceComputeTier.unknown,
      gpuFamily: GpuFamily.unknown,
      npuClass: NpuClass.none,
      notes: ['host:ungated'],
      ungatedHost: true,
    );
  }
  final notes = <String>[];
  var tier = _ramBaselineTier(s.totalRamBytes);
  notes.add('ram:${s.totalRamBytes}');

  var vetoed = false;
  if (s.lowRamDevice) {
    vetoed = true;
    notes.add('veto:lowRamDevice');
  }
  if (s.cpuCores > 0 && s.cpuCores <= kMinSupportedCores) {
    vetoed = true;
    notes.add('veto:cpuCores:${s.cpuCores}');
  }
  // ★ r681：这条例的**原意**是"32 位机器装不了我们的包"，不是"只认 Android 的
  //   ABI 字符串"。iOS 报的是 `arm64`（没有 `-v8a` 后缀）⇒ 旧写法会把**每一台
  //   iPhone** 都否决成 `unsupported`（模块整块隐藏）。改成"认得任何一种 64 位
  //   ABI 即通过"，判据仍是"是不是 32 位"。
  if (s.abis.isNotEmpty && !s.abis.any(kSupportedAbis.contains)) {
    vetoed = true;
    notes.add('veto:abi:${s.abis.join('/')}');
  }

  final adjust = socTierAdjustment(s);
  // ★ 只有**真的判出了档位**才做 SoC 微调：`unsupported`（已知事实不足）与
  // `unknown`（未判定）都排除。否则 `unknown.rank(0) + 1 = 1 = entry`，
  // 等于换个地方又把"不下结论"编成了具体档位（第 145 轮的连带陷阱）。
  if (adjust != 0 &&
      tier != DeviceComputeTier.unsupported &&
      tier != DeviceComputeTier.unknown) {
    var target = tier.rank + adjust;
    // 升档**不能**升到旗舰：旗舰 = ≥8GB **且** 高端 SoC。6GB 的机器哪怕 SoC 再强
    // 也不该被叫作旗舰（模型门槛不受影响，但标签必须对得上事实）。
    if (adjust > 0 && s.totalRamBytes < 8 * _gb && target > 3) target = 3;
    tier = _tierFromRank(target.clamp(1, 4));
    notes.add('soc:${s.socModel.isEmpty ? s.hardware : s.socModel}:$adjust');
  }
  if (vetoed) tier = DeviceComputeTier.unsupported;

  // ★ r681：模拟器的硬件读数是**宿主的** ⇒ 结论旁边必须写明。
  if (s.isSimulator) notes.add('simulator:host-facts');
  if (s.lowPowerMode) notes.add('low-power-mode');
  final gpu = gpuFamilyOf(s.glRenderer);
  notes.add('gpu:${gpu.name}${s.openclLibrary ? '+opencl' : ''}');
  final npu = _npuClassOf(s);
  notes.add('npu:${npu.name}');
  if (s.freeStorageBytes > 0) notes.add('free:${s.freeStorageBytes}');

  return DeviceCapability(
    snapshot: s,
    tier: tier,
    gpuFamily: gpu,
    npuClass: npu,
    notes: notes,
  );
}

DeviceComputeTier _ramBaselineTier(int ramBytes) {
  // ★ 第 145 轮：**"未知" ≠ "很差"**。`0` 只说明"没读到"（iOS 没有 `/proc`、
  // 也还没有硬件桥），断言 `unsupported` 就是"没有数据却编一个结论" —— 宿主分支
  // 曾犯同一个错（硬编码 mainstream）。而且 `unsupported` 会连带把模块隐藏掉，
  // 于是"探测不到"被说成了"设备不行"（AGENTS §2.0.6②：**未判定不许隐藏**）。
  if (ramBytes <= 0) return DeviceComputeTier.unknown;
  if (ramBytes < kMinSupportedRamBytes) return DeviceComputeTier.unsupported;
  if (ramBytes < 4 * _gb) return DeviceComputeTier.entry;
  if (ramBytes < 6 * _gb) return DeviceComputeTier.mainstream;
  if (ramBytes < 8 * _gb) return DeviceComputeTier.high;
  return DeviceComputeTier.flagship;
}

DeviceComputeTier _tierFromRank(int rank) => switch (rank) {
  0 => DeviceComputeTier.unsupported,
  1 => DeviceComputeTier.entry,
  2 => DeviceComputeTier.mainstream,
  3 => DeviceComputeTier.high,
  _ => DeviceComputeTier.flagship,
};

NpuClass _npuClassOf(DeviceCapabilitySnapshot s) {
  if (!s.nnapiFeature) return NpuClass.none;
  // 已知有厂商专用 NPU 产物的 SoC（保守：只登记我们**见过实物产物**的）
  final candidates = [s.socModel, s.hardware].map(_normalize);
  final knownNpu = candidates.any(
    (c) => c.startsWith('mt6993') || c.startsWith('mt6991'),
  );
  return knownNpu ? NpuClass.vendorSpecific : NpuClass.nnapiOnly;
}

String _afterColon(String line) {
  final i = line.indexOf(':');
  return i < 0 ? '' : line.substring(i + 1).trim();
}
