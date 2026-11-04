// `synhub/deep_link` —— iOS 侧的**聊天深链**接收（与 Android `DeepLinkBridge.kt` 同构）。
//
// ## 为什么要有这一份（r680）
//
// 到 r679 为止，iOS 的 `Info.plist` **没有 `CFBundleURLTypes`** ⇒ 系统根本不会把
// `synochat://…` 交给本 App，`lib/src/features/chat/chat_deep_link.dart` 那条
// MethodChannel 在 iOS 上永远拿不到东西（能力层也如实报
// `unavailable:not-implemented-on-host`）。这一份把 iOS 补齐。
//
// ## 三条 iOS 特有的事实（照抄 Android 会错）
//
// ① **没有 Intent extras**：官方 Android 用 `intent.getStringExtra("address")`
//    取地址、`"account"` 取账号；iOS 的等价物是 **URL 查询串**。所以这里把
//    `synochat://?address=…&account=…` 的 query 解析出来，仍按
//    `address` / `account` 两个键交给 Dart（Dart 侧解析器**不用改**，
//    它本来就把这两个键当"原生给的载荷"）。
//
// ② **本 App 是 UIScene 架构**（`Info.plist` 的 `UISceneDelegateClassName =
//    FlutterSceneDelegate`）⇒ iOS 13+ 的 URL **不再走** `application(_:open:)`，
//    而是走 `scene(_:openURLContexts:)`。要靠 Flutter 的
//    `FlutterSceneLifeCycleDelegate`（`registrar.addSceneDelegate`）才收得到；
//    只实现 `application(_:open:)` 会出现"冷启动能收、前台收不到"的半死状态。
//    这里两条都注册（`application(_:open:)` 仍保留给没有 scene 的场景 / iOS 12）。
//
// ③ **冷启动的 URL 在 `UISceneConnectionOptions` 里**：用户点一个
//    `synochat://` 链接把 App 从**未运行**拉起来时，`openURLContexts` 不会被调用，
//    URL 挂在 `scene(_:willConnectTo:options:)` 的 `connectionOptions.urlContexts` 上
//    ⇒ 这条也接，否则"冷启动深链"这条最常见的路径恰好不通。
//
// ## 与 Android 的一致之处
//
// * 只认官方那**四条** scheme（真机 `dumpsys` 实测，见 Dart 侧文件头）；
// * 不声明、也不消费 `synology-chat://`（那是官方 AppAuth 的 OAuth 回跳，
//   本 App 没有 OIDC 登录，声明了只会误导）；
// * 取走即清（`getPending` 消费一次就没了），并在存下时主动 `onDeepLink`
//   提醒前台页面。

import Flutter
import UIKit

/// iOS 聊天深链桥。
final class DeepLinkBridge: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  static let channelName = "synhub/deep_link"

  /// 官方四条 scheme（与 Android `DeepLinkBridge.schemes` 逐字一致）。
  private static let schemes: Set<String> = [
    "synochat", "synochats", "synochatGuest", "synochatsGuest",
  ]

  private var channel: FlutterMethodChannel?

  /// 待处理载荷（`getPending` 取走即清）。
  private var pending: [String: Any]?

  /// ★ **必须是强引用的单例**：Flutter 的 `addApplicationDelegate:` /
  /// `addSceneDelegate:` 都往 **weak** 集合里放（`NSHashTable` weakObjects），
  /// 局部 `let instance` 一返回就被释放 ⇒ 通道 handler 里的 `[weak instance]`
  /// 立刻变 nil，Dart 侧看到的正是 `MissingPluginException`（r680 首次构建实测）。
  static let shared = DeepLinkBridge()

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = DeepLinkBridge.shared
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    instance.channel = channel
    channel.setMethodCallHandler { [weak instance] call, result in
      guard let instance else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "getPending":
        // 取走即清：同一条链接不会被消费两次
        result(instance.pending)
        instance.pending = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // ② 前台/后台的 URL 事件（UIScene）
    registrar.addSceneDelegate(instance)
    // 没有 scene 时的兜底（iOS 12 / 单场景退化）
    registrar.addApplicationDelegate(instance)
#if targetEnvironment(simulator)
    instance.registerTestHook(with: registrar)
#endif
  }

#if targetEnvironment(simulator)
  // ─────────────────────────── r680：**仅模拟器**的"按一次链接"钩子
  //
  // 为什么需要它：iOS 18 的模拟器上，`xcrun simctl openurl` 会先弹一个
  // **系统确认框**（「Open in “SynHub”?」）—— 没有人点「Open」，URL 就停在
  // SpringBoard，scene delegate **一次都不会被调用**。无头模拟器点不了那个按钮
  // （本机没有 `Simulator.app`）⇒ 自动化里这条"真人点链接"的入口只能由 App 自己发起。
  //
  // 这里调的是**真的系统 API** `UIApplication.shared.open(_:)`：
  // SpringBoard 照样要做 scheme → App 的解析，再把 URL 经
  // `scene(_:openURLContexts:)` 交回来。也就是说 **除了"谁点了这一下"**，
  // 其余全部是真实的系统链路（不是绕过 scene delegate 直接调 handler）。
  //
  // 通道名带 `test_` 前缀，Dart 侧只有 integration_test 会用；
  // 且 `#if targetEnvironment(simulator)` ⇒ 真机产物里这段根本不存在。
  static let testChannelName = "synhub/test_deeplink"

  private func registerTestHook(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: DeepLinkBridge.testChannelName, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "open",
        let args = call.arguments as? [String: Any],
        let raw = args["url"] as? String,
        let url = URL(string: raw)
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      UIApplication.shared.open(url, options: [:]) { ok in
        result(ok)
      }
    }
  }
#endif

  // MARK: - 载荷解析（纯函数，便于对照 Dart 侧解析器）

  /// `URL` → 通道载荷；不是那四条 scheme ⇒ `nil`（不消费）。
  ///
  /// 官方 Android 只认 extras，不看 URI 的 host/path；iOS 上 host/path 同样
  /// **不被读取**（`synochat://x/y?address=…` 与 `synochat://?address=…` 等价）。
  static func payload(for url: URL) -> [String: Any]? {
    guard let scheme = url.scheme, schemes.contains(scheme) else { return nil }
    var out: [String: Any] = ["scheme": scheme, "uri": url.absoluteString]
    if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems
    {
      for item in items {
        switch item.name {
        case "address": out["address"] = item.value ?? ""
        case "account": out["account"] = item.value ?? ""
        default: break  // 未知键忽略（与官方只读两个 extra 一致）
        }
      }
    }
    return out
  }

  /// 存下载荷并提醒 Dart 侧"有新深链"。
  private func handle(_ url: URL) {
    guard let payload = DeepLinkBridge.payload(for: url) else {
      NSLog("[deeplink] 忽略非聊天深链：\(url.absoluteString)")
      return
    }
    pending = payload
    NSLog("[deeplink] 收到 \(payload["scheme"] ?? "?") 深链")
    channel?.invokeMethod("onDeepLink", arguments: nil)
  }

  // MARK: - FlutterSceneLifeCycleDelegate

  /// ③ 冷启动：URL 挂在连接选项上
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    NSLog("[deeplink] willConnectTo urls=\(connectionOptions?.urlContexts.count ?? 0)")
    var handled = false
    for context in connectionOptions?.urlContexts ?? [] {
      handle(context.url)
      handled = true
    }
    return handled
  }

  /// ② App 已在运行（前台或后台）时点链接
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>)
    -> Bool
  {
    NSLog("[deeplink] openURLContexts n=\(URLContexts.count)")
    var handled = false
    for context in URLContexts {
      if DeepLinkBridge.payload(for: context.url) != nil { handled = true }
      handle(context.url)
    }
    return handled
  }

  // MARK: - UIApplicationDelegate（无 scene 时的兜底）

  func application(
    _ application: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard DeepLinkBridge.payload(for: url) != nil else { return false }
    handle(url)
    return true
  }
}
