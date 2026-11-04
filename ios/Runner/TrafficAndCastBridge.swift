// iOS 侧的**三条只读/系统集成桥**（r689）：
//   * `synhub/traffic` :: `uidSnapshot` —— 网络计数（供 Dart 的"估算档"流量）
//   * `synhub/cast`    :: `availability` / `connect` / `play` / `disconnect`（AirPlay）
//
// 三条都放在一个文件里，是因为它们共用同一套"取最顶层 VC / 读系统状态"的小工具，
// 且都**只读**、都不申请权限。刻意与 `VideoFrameBridge.swift`（抽帧，走后台队列解码）
// 分开，免得一个文件里混两种线程模型。
//
// ─────────────────────────────────────────────────────────────────────────────
// ① 流量：iOS **没有**按 App（按 UID）的字节计数公开 API
//
// Android 的 `TrafficStats.getUidRxBytes(uid)` 在 iOS 上**没有对应物** —— 不是
// "我们没写"，是 Apple 从来没公开（`getifaddrs` 只给**接口级**累计：en0 / pdp_ip0 …；
// `NWPathMonitor` 只给连通性，不给字节）。所以这里：
//   * `uidRx` / `uidTx` / `mobileRx` / `mobileTx` 一律回 **-1**（"读不到" ≠ "没流量"），
//     与 Kotlin 侧 `mobileRx/Tx = -1` 是同一条纪律；
//   * `totalRx` / `totalTx` 给**整机所有接口求和**（这是 `getifaddrs` 真能给的）。
// Dart `DeviceTrafficSnapshot.supported` 要求 uid 两项 ≥ 0 ⇒ iOS 上"估算档"
// **如实地退化成不可用**，界面不许声称按 App 计量。这条差异记在
// `docs/ios-acceptance-ledger.md` §4 与 `docs/platform-ios.md` §28。
//
// ② 投屏：Android 那边是 Google Cast SDK（`CastContext` + `MediaRouter`）；
// iOS 的系统级对等物是 **AirPlay**（`AVRouteDetector` 检测有没有路由、
// `AVRoutePickerView` 是系统自己的"选输出"面板）。语义差异必须写清：
//   * `availability` → `{available: true, kind: "airplay", routesDetected: Bool}`
//     —— `available` 的意思是"这个平台支持投屏"，**不是**"附近有设备"；
//     有没有接收端看 `routesDetected`（模拟器上恒 false，如实）。
//   * `connect` → 摆出系统的 `AVRoutePickerView`（用户自己选设备），**不假装**选中了谁；
//   * `play` → AirPlay 下"播放"就是**保持本机播放**、由系统把音频路由过去 ⇒
//     只在**当前路由确实是 AirPlay** 时回 true，否则 false（不假装投送成功）；
//   * `disconnect` → 把系统路由拉回 `.builtInSpeaker`（`AVAudioSession`）。
//
// ③ 照片投送（`photoCast*`）在 iOS 上**没有等价物**（那是 Cast 的命名空间消息协议）
// ⇒ 如实回 `available=false`，Dart 侧走"本机不支持"的既有分支。

import AVFoundation
import AVKit
import Flutter
import UIKit

// MARK: - 流量（只读）

/// `synhub/traffic` 的 iOS 实现：**接口级**累计计数（没有按 App 的 API）。
final class TrafficBridge: NSObject, FlutterPlugin {
  static let channelName = "synhub/traffic"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = TrafficBridge()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "uidSnapshot" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let sample = Self.interfaces()
    // 键名与 Dart `DeviceTrafficSnapshot.fromMap` 逐字一致
    result([
      // ★ 没有按 App 的计数 API ⇒ 如实 -1（Dart 的 supported 会因此为 false）
      "uidRx": -1 as Int64,
      "uidTx": -1 as Int64,
      "mobileRx": -1 as Int64,
      "mobileTx": -1 as Int64,
      "totalRx": NSNumber(value: sample.rx),
      "totalTx": NSNumber(value: sample.tx),
      // 额外事实（Dart 侧当前不读，留给日志/排查）：整机移动数据单独一项
      "cellularRx": NSNumber(value: sample.cellularRx),
      "cellularTx": NSNumber(value: sample.cellularTx),
      "interfaces": sample.count,
    ])
  }

  /// 遍历 `getifaddrs` 的 `AF_LINK` 记录，累加 `ifi_ibytes` / `ifi_obytes`。
  ///
  /// 三个坑：
  ///  * 计数器是 **UInt32/64**，直接加进 `Int` 前要判类型（结构体里是 `u_long`）；
  ///  * `ifa_addr` 可能是 nil（接口没地址）；
  ///  * 回绕：接口级是 32 位计数的实现会在 4 GB 处翻回去 —— 这里按"只增"处理，
  ///    调用方（Dart）本来就会把**负差值**判成 idle 丢弃。
  static func interfaces() -> (
    rx: UInt64, tx: UInt64, cellularRx: UInt64, cellularTx: UInt64, count: Int
  ) {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var cellRx: UInt64 = 0
    var cellTx: UInt64 = 0
    var count = 0

    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else {
      return (0, 0, 0, 0, 0)
    }
    defer { freeifaddrs(head) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      guard let addr = entry.pointee.ifa_addr,
        addr.pointee.sa_family == UInt8(AF_LINK),
        let data = entry.pointee.ifa_data
      else { continue }
      let name = String(cString: entry.pointee.ifa_name)
      // 系统接口不算用户流量（lo0 / awdl0 / llw0 / utun* / bridge* 等）
      if name == "lo0" || name.hasPrefix("awdl") || name.hasPrefix("llw")
        || name.hasPrefix("utun") || name.hasPrefix("bridge") || name.hasPrefix("gif")
        || name.hasPrefix("stf")
      {
        continue
      }
      let stats = data.assumingMemoryBound(to: if_data.self).pointee
      let inBytes = UInt64(stats.ifi_ibytes)
      let outBytes = UInt64(stats.ifi_obytes)
      rx &+= inBytes
      tx &+= outBytes
      if name.hasPrefix("pdp_ip") {
        cellRx &+= inBytes
        cellTx &+= outBytes
      }
      count += 1
    }
    return (rx, tx, cellRx, cellTx, count)
  }
}

// MARK: - 投屏（AirPlay）

/// `synhub/cast` 的 iOS 实现。
///
/// ★ 与 Android 的**语义差异**（不是"少做了功能"）：Cast SDK 是"发现设备 →
/// 选定 → 把媒体 URL 交给接收端自己拉"，AirPlay 是"系统把**当前这路**音频/视频
/// 路由到接收端" ⇒ iOS 上不存在"把 URL 交给远端播放"这一步。
final class CastBridge: NSObject, FlutterPlugin {
  static let channelName = "synhub/cast"

  /// 系统自带的路由探测（`multipleRoutesDetected` 就是"附近有 AirPlay 设备"）。
  private let detector = AVRouteDetector()

  /// 强引用（与其它桥同因：registrar 的 delegate 是 weak）。
  static let shared = CastBridge()

  private weak var routePicker: AVRoutePickerView?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(shared, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "availability", "photoCastAvailability":
      // 航空播放恒"平台支持"；有没有接收端看 routesDetected。
      // 照片投送（Cast 命名空间消息）在 iOS 上没有等价物 ⇒ 如实 false。
      let isPhoto = call.method == "photoCastAvailability"
      let payload: [String: Any] = isPhoto
        ? ["available": false, "kind": "unsupported", "reason": "no-cast-namespace-on-ios"]
        : [
          "available": true,
          "kind": "airplay",
          "routesDetected": detector.multipleRoutesDetected,
          // Android 的 devices 是 {id,name}；AirPlay 的设备名由系统面板给，
          // 我们读不到（`AVRouteDetector` 只给"有没有"）⇒ 空表，不编名字。
          "devices": [[String: Any]](),
        ]
      result(payload)

    case "connect":
      presentRoutePicker(result: result)

    case "play":
      // AirPlay 下"投送"= 系统把当前输出路由过去；只有真的在 AirPlay 上才算成功。
      let onAirPlay = Self.currentOutputIsAirPlay()
      NSLog("[cast] play onAirPlay=\(onAirPlay)")
      result(onAirPlay)

    case "disconnect":
      // 把路由拉回本机扬声器（异步，失败也回 true：UI 语义是"已请求"）。
      do {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        result(true)
      } catch {
        NSLog("[cast] disconnect err=\(error)")
        result(false)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 摆系统自己的 AirPlay 面板（popover）。**不假装**选中了哪台设备。
  private func presentRoutePicker(result: @escaping FlutterResult) {
    guard let host = Self.topViewController() else {
      result(false)
      return
    }
    let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 240, height: 44))
    picker.tintColor = .label
    routePicker = picker

    let vc = UIViewController()
    vc.view.backgroundColor = .systemBackground
    vc.view.addSubview(picker)
    picker.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      picker.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
      picker.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
      picker.widthAnchor.constraint(equalToConstant: 240),
      picker.heightAnchor.constraint(equalToConstant: 44),
    ])
    vc.preferredContentSize = CGSize(width: 280, height: 96)
    vc.modalPresentationStyle = .popover
    if let pop = vc.popoverPresentationController {
      // iPad 必崩点（与 `ShareBridge` 同一条）：没有 sourceView 会抛 NSGenericException
      pop.sourceView = host.view
      pop.sourceRect = CGRect(
        x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
      pop.permittedArrowDirections = .down
    }
    host.present(vc, animated: true) {
      // 面板本身是系统 UI，用户选谁由系统决定 ⇒ 呈现成功即"已提供出口"
      result(true)
    }
  }

  /// 当前输出路由里有没有 AirPlay。
  static func currentOutputIsAirPlay() -> Bool {
    AVAudioSession.sharedInstance().currentRoute.outputs.contains {
      $0.portType == .airPlay
    }
  }

  /// 活着的 scene 里最顶层的 VC（与 `ShareBridge` 同一套取法）。
  static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
    else { return nil }
    var top = window.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
