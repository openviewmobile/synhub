// `synhub/widget` —— iOS 的**主屏小组件桥**（r688）。
//
// ## Dart 侧契约（与 Kotlin `SynologyWidgetBridge` 逐字同构）
//
//   * `pushSnapshot({snapshot: String})` → **Bool**
//     把快照 JSON 落进 App Group 并 `reloadAllTimelines()`；
//     `false` = JSON 不认识 / 写不进去（Dart 侧安静降级，与 Android 一致）。
//   * `requestRefresh()` → **Bool**：按已落盘快照重画。
//   * `takePendingTarget()` → **String?**：取走"由小组件点击带来的落点"（取走即清）。
//
//   反向事件：`onWidgetAction`（无参）—— App 已在前台时又点了一次小组件。
//
// ## 与 Android 的三处结构性差异（照抄会错）
//
// ① **落盘位置**：Android 共享文件系统；iOS 的扩展是独立进程，只能读
//    **App Group** 的 `UserDefaults`（suite 名 `group.com.openviewai.synhub.ios`，
//    与 `ios/Widget/SynHubHomeWidget.swift` 的 `SynHubWidgetStore` 逐个字符一致）。
//    ⇒ 两边的 entitlements 都必须声明同一个 group，缺一边就"App 写得进、扩展读不到"。
//
// ② **点击通道**：Android 用显式 Intent（`ACTION_OPEN`）刻意不蹭 `synochat://`；
//    iOS 的等价物是 `.widgetURL` —— 这里用**专用** scheme
//    `synhubwidget://open?target=…`，由本文件的 scene 分支解析，
//    绝不进 `DeepLinkBridge` 的聊天深链（那会污染"登录到某台 NAS"的语义）。
//
// ③ **刷新时机**：Android 直接 `updateAppWidget`；iOS 只能"请求"系统：
//    `WidgetCenter.shared.reloadAllTimelines()`。系统怎么调度、多久刷一次
//    由 WidgetKit 决定 ⇒ 界面上"刚推的快照没立刻变"是**系统的预算**，不是丢数据。

import Flutter
import UIKit
import WidgetKit

/// iOS 主屏小组件桥。
final class WidgetBridge: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  static let channelName = "synhub/widget"

  /// ★ App Group 名：与 `ios/Widget/SynHubHomeWidget.swift`（`SynHubWidgetStore.appGroup`）
  /// 与两份 `.entitlements` 逐字一致。改一处必须同改四处。
  static let appGroup = "group.com.openviewai.synhub.ios"
  static let snapshotKey = "snapshot"

  /// 专用点击 scheme（见文件头 ②）。`Info.plist` 的 `CFBundleURLTypes` 里也有一份。
  static let widgetScheme = "synhubwidget"

  /// ★ 强引用单例：`addSceneDelegate` 收的是 weak 集合（与 `DeepLinkBridge` 同因）。
  static let shared = WidgetBridge()

  private var channel: FlutterMethodChannel?
  private var pendingTarget: String?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = WidgetBridge.shared
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addSceneDelegate(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pushSnapshot":
      let args = call.arguments as? [String: Any] ?? [:]
      let json = (args["snapshot"] as? String) ?? ""
      let ok = save(json)
      if ok { reload() }
      result(ok)
    case "requestRefresh":
      reload()
      result(true)
    case "takePendingTarget":
      let t = pendingTarget
      pendingTarget = nil
      result(t)
    #if DEBUG
    // 仅 DEBUG：**模拟一次小组件点击**（把 `synhubwidget://…` 直接喂给解析器）。
    //
    // 为什么需要它（r688 现场）：无头模拟器上 `xcrun simctl openurl` 每次都会先弹
    // 系统确认框「要在「星樞」中打開嗎？」（像素证据
    // `docs/evidence-r687-690-ios/r688_openurl_confirm_alert.png`），而验收机上没人
    // 能点「打開」⇒ URL 永远到不了 App。这条钩子只证明**解析与落点语义**
    // （`synhubwidget://open?target=…` → `pendingTarget` → 取走即清），
    // **不**证明 UIKit 的 URL 投递；投递那一段如实记"环境不可得"。
    case "simulateWidgetURL":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let raw = args["url"] as? String, let url = URL(string: raw) else {
        result(false)
        return
      }
      result(handleWidgetURL(url))
    #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 写快照。只做"能不能落盘"的判断：JSON 解析不出结构 ⇒ false（不写脏数据）。
  private func save(_ json: String) -> Bool {
    guard !json.isEmpty, let data = json.data(using: .utf8) else { return false }
    guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return false }
    guard let defaults = UserDefaults(suiteName: Self.appGroup) else { return false }
    defaults.set(json, forKey: Self.snapshotKey)
    return defaults.synchronize()
  }

  private func reload() {
    if #available(iOS 14.0, *) {
      WidgetCenter.shared.reloadAllTimelines()
    }
  }

  // MARK: - 小组件点击（专用 scheme）

  /// 处理 `synhubwidget://open?target=…`。返回 true = 这一条**归我管**。
  @discardableResult
  func handleWidgetURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == Self.widgetScheme else { return false }
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let target = comps?.queryItems?.first(where: { $0.name == "target" })?.value
      ?? "home"
    pendingTarget = target
    channel?.invokeMethod("onWidgetAction", arguments: nil)
    NSLog("[widget] 小组件点击 target=\(target)")
    return true
  }

  // MARK: - FlutterSceneLifeCycleDelegate

  // ★ 签名必须与 `FlutterSceneLifeCycleDelegate` **逐字一致**（含 `-> Bool` 与
  //   `UIScene.ConnectionOptions?`）。协议方法全是 `@objc optional` ⇒ 签名写错
  //   **不会编译报错，只是永远不被调用**（与 r683 那条"Swift 类不给 @objc 时
  //   LLDB 静默返回 nil"同一类坑；r688 第一次跑就撞上：App 能起、通道能推快照，
  //   唯独点击落点恒 null）。
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    var handled = false
    for ctx in connectionOptions?.urlContexts ?? [] where handleWidgetURL(ctx.url) {
      handled = true
    }
    return handled
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>)
    -> Bool
  {
    var handled = false
    for ctx in URLContexts where handleWidgetURL(ctx.url) { handled = true }
    return handled
  }
}
