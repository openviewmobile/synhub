// `synhub/iosfsexport` —— iOS 的「用户现选目录」（A 轨）。
//
// 为什么需要它、以及为什么"选目录"与"写文件"要拆成两次调用，
// 见 Dart 侧 `lib/src/core/platform/ios_fs_export.dart` 的文件头（那里是权威说明）。
// 这里只记 iOS 特有的三条硬事实：
//
// ① **`getDirectoryPath` 在 iOS 上不存在**（`file_picker` 的 desktop-only API）
//    ⇒ 不接这条桥，iOS 上「存到本机」永远只能落 App 容器里的 downloads
//    （那是 B 轨，能用，但**与官方 App 的能力有差距**：官方能存进用户自选的
//      iCloud Drive / On My iPhone 目录）。
//
// ② **安全作用域是"进程级"的**：`startAccessingSecurityScopedResource()` 之后，
//    整进程（含 Dart 的 `dart:io`）都能写那个目录 ⇒ 所以 copy 仍由 Dart 做
//    （命名/不覆盖策略只有一份实现，不许在 Swift 里复制第二份）。
//
// ③ iOS **没有** macOS 那种 app-scope bookmark 免弹窗续期
//    ⇒ 每次保存都要用户点一次（这是系统语义，不是我们的欠缺）：
//    所以这里**不假装记住目录**，也**不写任何持久化**。
//
// ★ 与 macOS 那份桥（`macos/Runner/FsBookmarkBridge.swift`）的区别：
//   那份给的是"跨启动的书签"，这份给的是"本次有效的 token"。
//   两者都要**成对**关闭，否则长时间运行后系统会拒绝再开。

import Flutter
import UIKit
import UniformTypeIdentifiers

/// iOS 文件夹选择器 + 安全作用域句柄。
final class IosFsExportBridge: NSObject {
  /// 通道只有一个、选择器也只有一个（`UIDocumentPickerViewController` 是模态的）
  /// ⇒ 用单例把"等待中的 FlutterResult"和"已开的授权"挂在同一个地方。
  static let shared = IosFsExportBridge()

  /// 正在等用户点选的 FlutterResult（一次只可能有一个）。
  private var pending: FlutterResult?

  /// token → 已开的目录 URL（`release` 时关掉并移除）。
  private var scopes: [String: URL] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "synhub/iosfsexport",
      binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      IosFsExportBridge.shared.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      // 桥随 iOS target 编译进去 ⇒ 能走到这里就是"在"（与 Kotlin 桥同口径的
      // 静态事实；真正的可用性还要看有没有可呈现的 window，那是 pickDirectory 的事）。
      result(true)

    case "pickDirectory":
      presentPicker(result)

    case "release":
      let args = call.arguments as? [String: Any]
      let token = (args?["token"] as? String) ?? ""
      if let url = scopes.removeValue(forKey: token) {
        url.stopAccessingSecurityScopedResource()
      }
      // token 不认识也回成功：关闭是**尽力而为**的收尾动作，
      // 让它抛错会把"已经存好了"的一次保存弄成失败（Dart 侧也不看返回值）。
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 弹 `.folder` 的文档选择器。
  private func presentPicker(_ result: @escaping FlutterResult) {
    // 已经有一次在选择中 ⇒ 明确报错，别把两个 result 叠在一个 pending 上
    // （叠了就会有一个 Dart Future 永远不完成 ⇒ 界面卡住，比报错更坏）。
    if pending != nil {
      result(
        FlutterError(
          code: "picker_busy", message: "已经有一个目录选择面板在等待用户操作",
          details: nil))
      return
    }
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
      let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?
        .rootViewController
    else {
      result(
        FlutterError(
          code: "no_scene", message: "没有可用的 window（App 可能不在前台）",
          details: nil))
      return
    }

    // iOS 15 起 `forOpeningContentTypes:` 是标准 API（本 target 的
    // `IPHONEOS_DEPLOYMENT_TARGET = 15.0`）⇒ 不需要 `documentTypes:` 那条老路。
    // `asCopy: false` ⇒ **给原地 URL**（拿路径去写盘；复制模式给的是临时副本，
    // 写入不会落到用户选的地方 —— 那会变成"假成功"）。
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [UTType.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    pending = result
    root.present(picker, animated: true)
  }

  /// 取出并清空等待中的 result（两个 delegate 回调共用）。
  private func takePending() -> FlutterResult? {
    let r = pending
    pending = nil
    return r
  }
}

extension IosFsExportBridge: UIDocumentPickerDelegate {
  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    guard let result = takePending() else { return }
    guard let url = urls.first else {
      // 理论上不会（选中才有这个回调），但"没 URL"必须当成取消，
      // 不能回一个空路径让 Dart 去写盘。
      result(["cancelled": true])
      return
    }
    let scoped = url.startAccessingSecurityScopedResource()
    let token = UUID().uuidString
    scopes[token] = url
    result(["path": url.path, "token": token, "scoped": scoped])
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    // 取消 = 这次没得用（Dart 侧按"退 B 轨"处理，**不是**失败/报错）。
    takePending()?(["cancelled": true])
  }
}
