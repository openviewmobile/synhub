// `synhub/share_text` ＋ `synhub/media_open` 的 **iOS 系统分享面板**实现（r687）。
//
// ## 为什么要有这一份
//
// Dart 侧早就有两条"把东西交给系统"的路：
//   * `lib/src/features/notes/note_share_out.dart` → 通道 `synhub/share_text`，
//     方法 `shareText {subject, text}`（官方 Note Station 的"分享笔记正文"）；
//   * `lib/src/features/files/file_link_share.dart` → 通道 `synhub/media_open`，
//     方法 `shareFiles {paths, text, subject, mime}`（多附件 `ACTION_SEND_MULTIPLE`）。
//
// 两条都**只有 Kotlin 实现**（`Intent.ACTION_SEND` / `ACTION_SEND_MULTIPLE`），
// iOS 上能力层如实报 `unavailable:not-implemented-on-host` ⇒ 笔记正文与附件
// 在 iOS 上分享不出去（`DA320`）。iOS 的语义等价物是 **`UIActivityViewController`**：
// 系统自己给"拷贝 / 信息 / 邮件 / 存储到文件 / 隔空投送"等一整套出口，我们只负责
// 把载荷与 popover 锚点摆对。
//
// ## 三条 iOS 特有的事实（照抄 Android 会错）
//
// ① **iPad 必须给 `popoverPresentationController` 的锚点**，否则运行时抛
//    `NSGenericException: UIPopoverPresentationController … must have a non-nil
//    sourceView or barButtonItem`。iPhone 上它是 sheet，不看这个属性 ⇒
//    "iPhone 好的、iPad 崩"是这一条最典型的形态。这里用宿主窗口的
//    `bounds.midX/midY` 当一个零尺寸锚点，并把 `permittedArrowDirections`
//    设为 `.down`（屏幕上永远合法）。
//
// ② **必须从"当前活着的" view controller 呈现**：`UIApplication.shared.keyWindow`
//    已废弃且在多 scene 下不可靠；本 App 是 UIScene 架构 ⇒ 取
//    `connectedScenes` 里第一个 `.foregroundActive` 的 `UIWindowScene`，
//    再沿 `rootViewController.presentedViewController` 走到最顶层。
//    从被覆盖的 VC 呈现会得到 "Attempt to present … which is already presenting"。
//
// ③ **`completionWithItemsHandler` 的回调线程不是主线程保证**（系统可能在自己的
//    队列上回），所以这里只做"关掉并清状态"，不碰 UIKit；Dart 侧也**不**把
//    "用户点了哪个 App"当成功判据 —— 面板**呈现成功**就回 true（与 Android
//    `startActivity` 的 `resolveActivity` 语义一致：能不能接是系统的事）。
//
// ## 与 Android 的一致之处
//
// * 只做"出站"：接收别的 App 分享进来是另一条通道（`synhub/share_intent`，r670 起）；
// * 参数非法（空文本 + 空文件）⇒ 回 `false`，**不假装拉起过**；
// * 附件路径不存在 / 建不出 `URL` ⇒ 同样回 `false`（Android 侧是 `content://` 失败）。

import Flutter
import UIKit

/// iOS 系统分享面板桥（`synhub/share_text` ＋ `synhub/media_open`）。
final class ShareBridge: NSObject, FlutterPlugin {
  static let shareTextChannel = "synhub/share_text"
  static let mediaOpenChannel = "synhub/media_open"

  /// 最近一次呈现的面板（仅在测试/连点时用来避免重复呈现）。
  private weak var lastPresenter: UIViewController?

  /// ★ 强引用单例（与 `DeepLinkBridge` 同因：registrar 的 delegate 集合是 weak）。
  static let shared = ShareBridge()

  private var shareTextChannel: FlutterMethodChannel?
  private var mediaOpenChannel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ShareBridge.shared
    let text = FlutterMethodChannel(
      name: shareTextChannel, binaryMessenger: registrar.messenger())
    let media = FlutterMethodChannel(
      name: mediaOpenChannel, binaryMessenger: registrar.messenger())
    instance.shareTextChannel = text
    instance.mediaOpenChannel = media
    registrar.addMethodCallDelegate(instance, channel: text)
    registrar.addMethodCallDelegate(instance, channel: media)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "shareText":
      let args = call.arguments as? [String: Any] ?? [:]
      let subject = (args["subject"] as? String) ?? ""
      let text = (args["text"] as? String) ?? ""
      guard !text.isEmpty else {
        result(false)  // 空载荷 ⇒ 不拉起
        return
      }
      var items: [Any] = [text]
      if !subject.isEmpty { items.insert(subject, at: 0) }
      present(items: items, result: result)

    case "shareFiles":
      let args = call.arguments as? [String: Any] ?? [:]
      let paths = (args["paths"] as? [String]) ?? []
      let text = (args["text"] as? String) ?? ""
      guard !paths.isEmpty else {
        result(false)
        return
      }
      let urls = paths.filter { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
      guard urls.count == paths.count, !urls.isEmpty else {
        // 有附件落不了盘 ⇒ 如实 false（Android 侧是 content:// 建不出）
        result(false)
        return
      }
      var items: [Any] = urls
      if !text.isEmpty { items.append(text) }
      present(items: items, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 呈现

  /// 呈现系统分享面板。`result(true)` = 面板真的摆上去了；`false` = 拿不到
  /// 可呈现的 view controller（例如 App 正在后台）。
  private func present(items: [Any], result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let host = Self.topViewController() else {
        result(false)
        return
      }
      if let last = self.lastPresenter, last === host,
        host.presentedViewController is UIActivityViewController
      {
        // 已经摆着一个 ⇒ 不叠第二个（连点两下会得到 "already presenting" 崩溃日志）
        result(true)
        return
      }
      let controller = UIActivityViewController(
        activityItems: items, applicationActivities: nil)
      // ① iPad 锚点：缺它必崩（见文件头 ①）
      if let pop = controller.popoverPresentationController {
        pop.sourceView = host.view
        pop.sourceRect = CGRect(
          x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
        pop.permittedArrowDirections = .down
      }
      controller.completionWithItemsHandler = { _, _, _, _ in
        // 只清状态；不把"用户选了哪个出口"当成功判据（见文件头 ③）
      }
      self.lastPresenter = host
      host.present(controller, animated: true) {
        result(true)
      }
    }
  }

  /// 取当前最顶层的 view controller（UIScene 架构下的正确取法，见文件头 ②）。
  static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let scene =
      scenes.first(where: { $0.activationState == .foregroundActive })
      ?? scenes.first
    let window =
      scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
    guard var top = window?.rootViewController else { return nil }
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }
}
