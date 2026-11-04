import Cocoa
import FlutterMacOS

/// macOS 的「安全作用域书签」桥（Dart 侧对应 `core/platform/fs_bookmark.dart`）。
///
/// ## 为什么需要它
/// App 沙箱下，用户在保存面板里选的**容器外**目录只拿到**一次性**扩展
/// （`com.apple.security.files.user-selected.read-write`）：进程重启后又写不进去。
/// 想"记住上次选的目录"，只能走官方的**安全作用域书签** ——
/// 把书签串存起来，下次 `URL(resolvingBookmarkData:options:.withSecurityScope)`
/// 解回来，并**显式** `startAccessingSecurityScopedResource()`。
///
/// ## 通道契约（**与 Dart 侧逐字对应，改一处必须改两处**）
///   * 通道 `synhub/fsbookmark`
///   * `isSupported` → `Bool`（恒 true：桥在 = 支持；entitlement 没批时
///     `create` 会回 `{error}`，那是**如实**的失败，不是"不支持"）
///   * `create`      ← `{path}`     → `{bookmark, path}` | `{error}`
///   * `startAccess` ← `{bookmark}` → `{path, started, stale}` | `{error}`
///   * `stopAccess`  ← `{bookmark}` → `Bool`
///
/// ## 纪律
/// * `startAccessingSecurityScopedResource()` 的结果**成对**记录在
///   `startedBookmarks` 里，`stopAccess` 只对**真的开起来过**的那些调 stop
///   （系统不允许重复开口：同一个 URL 开两次时第二次返回 false，
///   那时**不该**在 stop 里减引用 —— 否则会把别人的扩展关掉）。
/// * 本桥只做"书签 ↔ 路径"和"开/关扩展"，**不碰文件内容**
///   （拷贝仍由 Dart 侧 `dart:io` 做，落点判据也在那边回读）。
/// * 没有任何网络、没有凭据、没有把路径写到桥外。
final class FsBookmarkBridge: NSObject {
  static let shared = FsBookmarkBridge()
  static let channelName = "synhub/fsbookmark"

  /// bookmark(base64) → 真的开起来过的 URL（stop 时成对关闭）。
  private var startedBookmarks: [String: URL] = [:]

  func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: registrar.messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isSupported":
      result(true)

    case "create":
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "114", message: "path required", details: nil))
        return
      }
      let url = URL(fileURLWithPath: path).standardizedFileURL
      do {
        let data = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        result(["bookmark": data.base64EncodedString(), "path": url.path])
      } catch {
        // 没有 `files.bookmarks.app-scope` entitlement、或目录不存在时会走到这里。
        result(["error": "\(error)"])
      }

    case "startAccess":
      guard let b64 = args["bookmark"] as? String, !b64.isEmpty else {
        result(FlutterError(code: "114", message: "bookmark required", details: nil))
        return
      }
      guard let data = Data(base64Encoded: b64) else {
        result(["error": "bookmark is not base64"])
        return
      }
      var stale = false
      do {
        let url = try URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &stale)
        // 已经开过的书签不重复开（系统的引用计数语义：第二次返回 false）。
        var started = true
        if startedBookmarks[b64] == nil {
          started = url.startAccessingSecurityScopedResource()
          if started { startedBookmarks[b64] = url }
        }
        result(["path": url.path, "started": started, "stale": stale])
      } catch {
        result(["error": "\(error)"])
      }

    case "stopAccess":
      guard let b64 = args["bookmark"] as? String, !b64.isEmpty else {
        result(FlutterError(code: "114", message: "bookmark required", details: nil))
        return
      }
      if let url = startedBookmarks.removeValue(forKey: b64) {
        url.stopAccessingSecurityScopedResource()
      }
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
