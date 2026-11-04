// synhub/device 的 **iOS 实现**（r681）。
//
// 为什么需要它：端侧大模型的档位（"这台机器能跑多大的模型"）靠
// `DeviceCapabilitySnapshot` 的**事实**算出来 —— 内存、核数、SoC、GPU、NPU、
// 剩余存储。Android 早就走 `DeviceModelBridge.kt` 的 `capability`；
// iOS 一直没有实现 ⇒ 通道调用落到 `MissingPluginException`，Dart 侧回落到
// `/proc`（iOS 上根本不存在）⇒ 内存 = 0 ⇒ 档位 `unknown`（不隐藏但也不推荐）。
//
// ## 与 Android 的 key 契约**逐字对齐**
//
// 同一个 channel（`synhub/device`）、同一个方法名（`capability` / `model`）、
// 同一批 key（`manufacturer` / `model` / `cpuCores` / `totalRamBytes` /
// `freeStorageBytes` / `glRenderer` / `openclLibrary` / `nnapiFeature` /
// `thermalStatus` …）—— Dart 侧 `DeviceCapabilitySnapshot.fromPlatformMap`
// 一份解析器吃两个平台。**iOS 没有对应物**的项按"如实留空/0/false"给，
// 绝不编造（例：`cpuMaxFreqKhz` iOS 不公开 ⇒ 0；`openclLibrary` iOS 没有
// OpenCL ⇒ false + 另给 `metalDevice`）。
//
// ## iOS 侧额外给的三个事实（Android 没有）
//
// * `isSimulator`：`targetEnvironment(simulator)`。**模拟器读到的内存是宿主的**
//   （`ProcessInfo.physicalMemory` 在模拟器里返回 Mac 的物理内存）⇒ 界面上必须
//   能区分"这是模拟器的数"，否则会得出"模拟器 = 旗舰机"的假结论。
// * `metalDevice`：`MTLCreateSystemDefaultDevice()?.name`（真 GPU 名字；
//   模拟器上会带 "Apple M… " 之类）。
// * `lowPowerMode`：低电量模式是 iOS 特有的**当下**功耗状态（不参与档位，只报告）。
//
// ## 只读纪律
//
// 不申请权限、不写文件、不联网。读的都是系统 API（`ProcessInfo` /
// `utsname` / `sysctl` / `URLResourceValues` / Metal / `os_proc_available_memory`）。
import Foundation
import Metal
import UIKit

final class DeviceCapabilityBridge: NSObject, FlutterPlugin {
  static let channelName = "synhub/device"

  /// ★ 强引用单例：Flutter 的 delegate / 通道 handler 组合里只要有一处
  /// 是 weak，局部实例就会被立刻释放（r680 在 `DeepLinkBridge` 上踩过
  /// `MissingPluginException` 那个坑）。规范：原生桥一律 `static let shared`。
  static let shared = DeviceCapabilityBridge()

  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = DeviceCapabilityBridge.shared
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    instance.channel = channel
    channel.setMethodCallHandler { [weak instance] call, result in
      guard let instance else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "capability":
        result(instance.capability())
      case "model":
        result(instance.deviceModelIdentifier())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - 设备身份

  /// `utsname.machine`（真机是 `iPhone16,1` 这种；模拟器上也是宿主的架构名，
  /// 所以模拟器改读 `SIMULATOR_MODEL_IDENTIFIER`）。
  private func machineIdentifier() -> String {
    #if targetEnvironment(simulator)
      if let sim = ProcessInfo.processInfo.environment[
        "SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty
      {
        return sim
      }
    #endif
    var info = utsname()
    uname(&info)
    let raw = withUnsafeBytes(of: &info.machine) { buf -> String in
      let bytes = buf.prefix(while: { $0 != 0 })
      return String(decoding: bytes, as: UTF8.self)
    }
    return raw
  }

  /// 给 Dart `readDeviceModel()` 用（`noteCommitDeviceFrom` 那个"官方口径 device"）。
  ///
  /// 真机取 `hw.model`（`iPhone17,1` 这种产品型号），取不到退回 `machineIdentifier`。
  /// ★ 模拟器上 `hw.model` 是**宿主 Mac** 的型号（实测 `Mac16,9`）⇒ 不许拿它冒充
  /// 设备型号，改读 `SIMULATOR_MODEL_IDENTIFIER`（`machineIdentifier()` 已处理）。
  private func deviceModelIdentifier() -> String {
    #if targetEnvironment(simulator)
      return machineIdentifier()
    #else
      if let hw = sysctlString("hw.model"), !hw.isEmpty { return hw }
      return machineIdentifier()
    #endif
  }

  /// 从 `iPhone16,1` 反查 Apple 的对外 SoC 名。
  ///
  /// ★ 这是**映射表不是探测**：iOS 没有 `Build.SOC_MODEL` 那种 API。
  /// 表里没有的机型返回空串（宁可空着，也不猜）。
  /// 维护口径：只收 Apple 公开过的对应关系（A15/A16/A17 Pro/A18 …）。
  private func appleSocModel(for machine: String) -> String {
    let table: [String: String] = [
      // iPhone 12 / 13 / 14 / 15 / 16 家族（含 Pro / Plus / mini）
      "iPhone13,1": "A14 Bionic", "iPhone13,2": "A14 Bionic",
      "iPhone13,3": "A14 Bionic", "iPhone13,4": "A14 Bionic",
      "iPhone14,2": "A15 Bionic", "iPhone14,3": "A15 Bionic",
      "iPhone14,4": "A15 Bionic", "iPhone14,5": "A15 Bionic",
      "iPhone14,6": "A15 Bionic", "iPhone14,7": "A15 Bionic",
      "iPhone14,8": "A15 Bionic",
      "iPhone15,2": "A16 Bionic", "iPhone15,3": "A16 Bionic",
      "iPhone15,4": "A16 Bionic", "iPhone15,5": "A16 Bionic",
      "iPhone16,1": "A17 Pro", "iPhone16,2": "A17 Pro",
      "iPhone17,1": "A18 Pro", "iPhone17,2": "A18 Pro",
      "iPhone17,3": "A18", "iPhone17,4": "A18",
      // iPad（端侧 AI 也在 iPad 上跑，别一律当 iPhone）
      "iPad13,18": "A14 Bionic", "iPad13,19": "A14 Bionic",
      "iPad14,1": "A15 Bionic", "iPad14,2": "A15 Bionic",
      "iPad13,8": "M1", "iPad13,9": "M1", "iPad13,10": "M1", "iPad13,11": "M1",
      "iPad14,3": "M2", "iPad14,4": "M2", "iPad14,5": "M2", "iPad14,6": "M2",
      "iPad16,3": "M4", "iPad16,4": "M4",
    ]
    return table[machine] ?? ""
  }

  // MARK: - sysctl 小工具

  private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
      return nil
    }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
  }

  private func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
  }

  private func sysctlFlag(_ name: String) -> Bool {
    (sysctlInt(name) ?? 0) != 0
  }

  // MARK: - 能力快照

  private func capability() -> [String: Any] {
    let info = ProcessInfo.processInfo
    let device = UIDevice.current
    let machine = machineIdentifier()
    var out: [String: Any] = [:]

    // ── 设备身份 ────────────────────────────────────────────────
    out["manufacturer"] = "Apple"
    out["brand"] = "Apple"
    out["model"] = deviceModelIdentifier()
    out["device"] = machine
    out["board"] = machine
    out["hardware"] = machine
    out["socModel"] = appleSocModel(for: machine)
    out["socManufacturer"] = "Apple"
    out["sdkInt"] = Int(info.operatingSystemVersion.majorVersion)
    out["release"] = info.operatingSystemVersionString
    // iOS 只有 arm64（模拟器上是 arm64 的宿主架构）。这里给 `arm64`，
    // Dart 侧的"32 位机器"否决规则已同步接受 `arm64`（r681）。
    out["abis"] = ["arm64"]

    // ── CPU ────────────────────────────────────────────────────
    out["cpuCores"] = info.activeProcessorCount
    // `hw.optional.*`：与 Android `/proc/cpuinfo` 的 features 同语义（"有哪些指令扩展"）。
    var features: [String] = ["arm64"]
    if sysctlFlag("hw.optional.neon") { features.append("neon") }
    if sysctlFlag("hw.optional.armv8_1_atomics") { features.append("atomics") }
    if sysctlFlag("hw.optional.armv8_2_fhm") { features.append("fp16") }
    if sysctlFlag("hw.optional.arm.FEAT_DotProd") { features.append("dotprod") }
    if sysctlFlag("hw.optional.arm.FEAT_I8MM") { features.append("i8mm") }
    out["cpuFeatures"] = features.joined(separator: " ")
    // ★ iOS **不公开** CPU 频率（没有 `cpufreq` 那种 sysfs）；如实给 0。
    out["cpuMaxFreqKhz"] = 0

    // ── 内存 ────────────────────────────────────────────────────
    // 模拟器里 `physicalMemory` 返回**宿主 Mac** 的物理内存
    // （所以配合 `isSimulator` 一起看，别把它当归档事实）。
    let totalRam = info.physicalMemory
    out["totalRamBytes"] = totalRam
    let avail = os_proc_available_memory()
    out["availRamBytes"] = avail > 0 ? Int(avail) : 0
    out["lowMemory"] = false  // iOS 由 jetsam 管，没有 Android 那个标志位
    // iOS 没有 `isLowRamDevice`；按"物理内存 < 3 GB"给一个**可解释**的等价物，
    // 与 Dart 侧 `kMinSupportedRamBytes` 同阈值（改阈值要两边一起改）。
    out["lowRamDevice"] = totalRam > 0 && totalRam < 3 * 1024 * 1024 * 1024

    // ── 存储（App 数据目录所在卷） ────────────────────────────────
    var free: Int64 = 0
    var total: Int64 = 0
    let home = URL(fileURLWithPath: NSHomeDirectory())
    if let values = try? home.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
    ]) {
      free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
      total = Int64(values.volumeTotalCapacity ?? 0)
    }
    out["freeStorageBytes"] = free
    out["totalStorageBytes"] = total

    // ── GPU ────────────────────────────────────────────────────
    // Android 报的是 `GL_RENDERER`/`GL_VENDOR`/`GL_VERSION`；iOS 上对应的事实是
    // **Metal 设备**（`MTLCreateSystemDefaultDevice()`），所以同一个 key 放 GPU 名字，
    // 另外单给 `metalDevice` / `metalFamily`，让报告能说清事实来源。
    let gpu = MTLCreateSystemDefaultDevice()
    out["glRenderer"] = gpu?.name ?? ""
    out["glVendor"] = gpu == nil ? "" : "Apple"
    out["glVersion"] = gpu == nil ? "" : "Metal"
    out["metalDevice"] = gpu?.name ?? ""
    out["metalFamily"] = gpu == nil ? "" : "Apple GPU"

    // ── 加速后端 ────────────────────────────────────────────────
    out["openclLibrary"] = false  // iOS 不提供 OpenCL（LiteRT-LM 的 GPU 委托在 iOS 走 Metal）
    out["nnapiFeature"] = false  // iOS 没有 NNAPI；对应物是 Core ML / ANE，见下
    out["coremlAvailable"] = NSClassFromString("MLModel") != nil
    #if targetEnvironment(simulator)
      out["neuralEngine"] = false  // 模拟器没有 ANE 硬件
    #else
      // 真机：A12 及以后都有 Neural Engine（`hasNeuralEngine` 没有公开 API，
      // 这里用"有 Core ML 且非模拟器"表达"框架在"，**不**声称算力）。
      out["neuralEngine"] = NSClassFromString("MLModel") != nil
    #endif

    // ── 热 / 功耗（当下快照，不参与档位） ─────────────────────────
    out["thermalStatus"] = thermalStatusCode(info.thermalState)
    out["lowPowerMode"] = info.isLowPowerModeEnabled

    // ── 环境标识（iOS 独有；让报告能区分模拟器与真机） ─────────────
    #if targetEnvironment(simulator)
      out["isSimulator"] = true
    #else
      out["isSimulator"] = false
    #endif
    out["platform"] = "ios"
    return out
  }

  /// 把 `ProcessInfo.ThermalState` 折成与 Android `currentThermalStatus` 同量级的
  /// 0…3（Android 的常量是 `NONE=0/ LIGHT=1 / MODERATE=2 / SEVERE=3 / CRITICAL=4`，
  /// iOS 只有四档，所以 critical 给 3 **并在 Dart 侧按"≥3 = 严重"读**）。
  private func thermalStatusCode(_ state: ProcessInfo.ThermalState) -> Int {
    switch state {
    case .nominal: return 0
    case .fair: return 1
    case .serious: return 2
    case .critical: return 3
    @unknown default: return -1
    }
  }
}
