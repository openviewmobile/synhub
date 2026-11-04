// macOS 原生媒体**传输层**（TLS 政策 + 自定义 scheme 的取流代理）。
//
// 为什么单独一个文件（而不是塞在 `MediaPlayerBridge.swift` 里）：
//   * 这一层**不依赖 Flutter**（只用 AVFoundation / Foundation / CryptoKit）⇒
//     可以被 `swiftc` 单独编成一个命令行复现程序，对本文件里的
//     "自签 + 主机名不匹配" 那条 TLS 分支做**真机级最小佐证**；
//   * 桥（通道/事件/纹理）在 `MediaPlayerBridge.swift`，只依赖这一层的公开类型。
//
// 与 Android `MediaPlayerBridge.kt` 的 `setTlsPolicy` / `PinnedTrustManager`
// **逐语义对齐**（详见文件内注释）。
import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

// MARK: - TLS 政策（与 Kotlin `setTlsPolicy` 一一对应）

/// 当前会话那一台 NAS 主机的 TLS 政策。**窄**：只放宽一个精确主机名。
final class MediaTlsPolicy {
  static let shared = MediaTlsPolicy()

  /// 自定义 scheme：AVFoundation 不认，于是回调 `AVAssetResourceLoaderDelegate`
  static let proxyScheme = "synhub-https"

  private let lock = NSLock()
  private var host: String?
  private var fingerprint: String?
  /// 最近一次"被我们拒掉的证书"的原因。
  ///
  /// 为什么要有它：挑战被 `cancelAuthenticationChallenge` 之后，URLSession
  /// 只回一个 `NSURLErrorCancelled(-999) | cancelled`，看不出是证书问题
  /// ⇒ Dart 的 `classifyPlayerError` 会把它误判成"解码失败"。
  private var rejection: String?

  private init() {}

  /// `host == nil` ⇒ **还原**平台默认（登出 / 断连 / 切服务器时下发）。
  func set(host: String?, fingerprint: String?) {
    let h = (host?.isEmpty == true) ? nil : host
    let fp = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
    lock.lock()
    self.host = h
    self.fingerprint = (fp?.isEmpty == true) ? nil : fp?.uppercased()
    self.rejection = nil
    lock.unlock()
  }

  /// 记一条拒绝原因（`tls cert rejected` 前缀是**故意**的：Dart 侧
  /// `classifyPlayerError` 见到 `tls`/`cert` 会归到"证书不受信任"）。
  func noteRejection(host: String) {
    lock.lock()
    rejection = "tls cert rejected: host=\(host)"
    lock.unlock()
  }

  /// 取走一次拒绝原因（取完即清，避免把上一次的错重复报到下一次播放）。
  func consumeRejection() -> String? {
    lock.lock()
    defer { lock.unlock() }
    let r = rejection
    rejection = nil
    return r
  }

  var current: (host: String?, fingerprint: String?) {
    lock.lock()
    defer { lock.unlock() }
    return (host, fingerprint)
  }

  /// 这个绝对 URL 要不要走"自定义 scheme + 我们自己的 URLSession"。
  /// 只对**当前政策主机**的 https 生效（其余主机一个字节都不经过我们）。
  func needsProxy(_ url: URL) -> Bool {
    guard let h = current.host, !h.isEmpty else { return false }
    return url.scheme?.lowercased() == "https" && url.host == h
  }

  /// `https://…` → `synhub-https://…`
  static func proxyURL(_ url: URL) -> URL? {
    var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
    c?.scheme = proxyScheme
    return c?.url
  }

  /// `synhub-https://…` → `https://…`
  static func originURL(_ url: URL) -> URL? {
    guard url.scheme == proxyScheme else { return nil }
    var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
    c?.scheme = "https"
    return c?.url
  }
}

/// 我们自己的 `URLSession` 的信任决策（**只放宽目标主机**）。
final class MediaTrustDelegate: NSObject, URLSessionDelegate {
  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let (targetHost, fingerprint) = MediaTlsPolicy.shared.current
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust,
      let host = targetHost,
      challenge.protectionSpace.host == host
    else {
      // 非目标主机（或不是服务器信任挑战）⇒ 一律原验证器
      completionHandler(.performDefaultHandling, nil)
      return
    }
    // ① 系统默认：证书链 + 主机名，全过 ⇒ 直接放行（比放宽更严）
    if SecTrustEvaluateWithError(trust, nil) {
      completionHandler(.useCredential, URLCredential(trust: trust))
      return
    }
    let pinned = fingerprint.flatMap { fp in Self.leafSHA256(trust).map { $0 == fp } } ?? false
    // ② 链可信、只是主机名不匹配 ⇒ 等价 Android 的 HostnameVerifier 放宽
    if Self.evaluateRelaxingHostname(trust) && (fingerprint == nil || pinned) {
      NSLogDiag("SynologyChatPlayer TLS 政策：主机名校验放宽（仅 %@），信任链已由系统验证", host)
      completionHandler(.useCredential, URLCredential(trust: trust))
      return
    }
    // ③ 自签：链验不过，但指纹与首连信任库里那一枚一致 ⇒ 只钉住这一枚
    if pinned {
      NSLogDiag("SynologyChatPlayer TLS 政策：指纹钉住放行（仅 %@）", host)
      completionHandler(.useCredential, URLCredential(trust: trust))
      return
    }
    NSLogDiag("SynologyChatPlayer TLS 政策：拒绝 %@ 的证书（链与指纹都没过）", host)
    MediaTlsPolicy.shared.noteRejection(host: host)
    completionHandler(.cancelAuthenticationChallenge, nil)
  }

  /// 用"**不校验主机名**的 SSL policy"重新验一遍证书链（系统锚点不变）。
  static func evaluateRelaxingHostname(_ trust: SecTrust) -> Bool {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return false }
    var relaxed: SecTrust?
    let status = SecTrustCreateWithCertificates(
      chain as CFArray, SecPolicyCreateSSL(true, nil), &relaxed)
    guard status == errSecSuccess, let r = relaxed else { return false }
    return SecTrustEvaluateWithError(r, nil)
  }

  /// 叶子证书的 SHA-256（大写十六进制，与 Dart `TrustStore` 同格式）。
  static func leafSHA256(_ trust: SecTrust) -> String? {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let leaf = chain.first
    else { return nil }
    let der = SecCertificateCopyData(leaf) as Data
    return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
  }
}

// MARK: - r87 诊断落盘

/// 把原生侧的 NSLog 同时写进 App 容器 tmp 的 `player-diag.log`。
///
/// 为什么需要（r87 实测）：`flutter test -d macos` **不转发** App 的 `NSLog`
/// 到测试输出，统一日志里 AVFoundation 的错误又常被 `<private>` 掉 ⇒
/// "自研桥放不出来"这种结论拿不到原文。这个 helper 让原生侧的关键路径
/// 一定能被读到（路径 = `Directory.systemTemp`，与走查截图同一个容器目录）。
func NSLogDiag(_ format: String, _ args: CVarArg...) {
  let message = String(format: format, arguments: args)
  NSLog("%@", message)
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("player-diag.log")
  let line = "\(Date()) \(message)\n"
  if let data = line.data(using: .utf8) {
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }
}

// MARK: - 资源加载代理（自定义 scheme → URLSession）

/// 把 `synhub-https://` 的取流请求翻译成真正的 `https://` 请求（走我们的 URLSession）。
/// 必须正确处理 `Range`：AVFoundation 全靠分段请求做 seek / moov 探测。
final class MediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  private let session: URLSession
  private let lock = NSLock()
  private var pending: [ObjectIdentifier: Pending] = [:]

  /// 传输层失败原因（TLS 拒绝 / HTTP 状态 / 网络错）。桥把它直接写进
  /// `lastError` 上报 —— AVFoundation 对这些只会回一个通用的 `-11800`，
  /// Dart 的 `classifyPlayerError` 认不出（会误判成"解码失败"）。
  var onFailure: ((String) -> Void)?

  private final class Pending {
    let request: AVAssetResourceLoadingRequest
    var task: URLSessionDataTask?
    var cancelled = false
    init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
  }

  override init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60 * 60
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(
      configuration: config, delegate: MediaTrustDelegate(), delegateQueue: nil)
    super.init()
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard let url = loadingRequest.request.url,
      let origin = MediaTlsPolicy.originURL(url)
    else { return false }
    let p = Pending(loadingRequest)
    if let dr = loadingRequest.dataRequest {
      NSLogDiag(
        "SynologyChatPlayer 取流请求 offset=%lld length=%d allToEnd=%d contentInfo=%d",
        dr.requestedOffset, dr.requestedLength, dr.requestsAllDataToEndOfResource ? 1 : 0,
        loadingRequest.contentInformationRequest != nil ? 1 : 0)
    }
    lock.lock()
    pending[ObjectIdentifier(loadingRequest)] = p
    lock.unlock()
    start(p, origin: origin)
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    lock.lock()
    let p = pending.removeValue(forKey: ObjectIdentifier(loadingRequest))
    p?.cancelled = true
    lock.unlock()
    p?.task?.cancel()
  }

  private func start(_ p: Pending, origin: URL) {
    var request = URLRequest(url: origin)
    if let dr = p.request.dataRequest {
      let offset = dr.requestedOffset
      let length = dr.requestedLength
      if dr.requestsAllDataToEndOfResource {
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
      } else if length > 0 {
        request.setValue(
          "bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
      } else if offset > 0 {
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
      }
    }
    let task = session.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self else { return }
      self.lock.lock()
      let removed = self.pending.removeValue(forKey: ObjectIdentifier(p.request))
      self.lock.unlock()
      if p.cancelled || removed == nil { return }
      if let error = error {
        // 只认"我们自己发起的取消"（didCancel 已经把 p.cancelled 立起来）；
        // TLS 挑战被拒时 URLSession 也回 -999，那种**必须**往下报错，
        // 否则资源请求会永远挂着、AVPlayer 既不失败也不出帧。
        if p.cancelled { return }
        // 证书是我们自己拒的 ⇒ 用**那条**原因（比 URLSession 的 -999 有信息量）
        let detail = MediaTlsPolicy.shared.consumeRejection()
          ?? MediaPlayerError.describe(error)
        NSLogDiag("SynologyChatPlayer 取流失败：%@", detail)
        self.onFailure?(detail)
        p.request.finishLoading(with: MediaPlayerError.network(error))
        return
      }
      guard let http = response as? HTTPURLResponse else {
        p.request.finishLoading(with: MediaPlayerError.plain("no http response"))
        return
      }
      NSLogDiag(
        "SynologyChatPlayer 取流响应 http=%d mime=%@ len=%lld range=%@",
        http.statusCode, http.mimeType ?? "-", http.expectedContentLength,
        http.value(forHTTPHeaderField: "Content-Range") ?? "-")
      if http.statusCode >= 400 {
        // 与 Kotlin 的 `bad_http_status` 摘要对齐（Dart `classifyPlayerError` 认它）
        let detail = "bad_http_status http=\(http.statusCode) contentType=\(http.mimeType ?? "")"
        self.onFailure?(detail)
        p.request.finishLoading(with: MediaPlayerError.plain(detail))
        return
      }
      if let cir = p.request.contentInformationRequest {
        if let id = Self.contentIdentifier(mime: http.mimeType, origin: origin) {
          cir.contentType = id
        }
        cir.isByteRangeAccessSupported =
          http.statusCode == 206
          || (http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes")
        if let total = Self.totalLength(http) { cir.contentLength = total }
      }
      if let data = data, let dr = p.request.dataRequest {
        var payload = data
        // 服务端不认 Range 回了 200（整段）⇒ 自己按请求偏移切片，别把整段塞回去
        if http.statusCode == 200, dr.requestedOffset > 0,
          dr.requestedOffset < Int64(data.count)
        {
          payload = data.subdata(in: Int(dr.requestedOffset)..<data.count)
        }
        dr.respond(with: payload)
      }
      p.request.finishLoading()
    }
    p.task = task
    task.resume()
  }

  /// 给 AVFoundation 的**内容类型**。
  ///
  /// ## 为什么不能直接把服务端 mime 交出去（r87 真机取证）
  ///
  /// 真 NAS 的 `SYNO.FileStation.Download&…&mode=download`（App 里
  /// `resolveFileStationSource` 用的就是这个默认 mode）回的是
  /// `Content-Type: application/octet-stream` —— 同一条 URL 只把 `mode` 换成
  /// `open`，服务端就回 `video/mp4`（宿主 curl + 本文件 CLI 双向实测）。
  /// 把 `octet-stream` 交给 `AVPlayerItem`，AVFoundation 回
  /// `AVFoundation -11828 | Cannot Open | NSOSStatusErrorDomain(-12847)` ——
  /// 这不是证书问题（证书那一步已经用本文件的 scoped 政策放行了）。
  ///
  /// 兜底顺序：具体 mime → 查询串 `path=["./x.mp4"]` / `path=/x.mp4` 的扩展名
  /// → URL 路径扩展名 → 通用 mime。扩展名解析成 `UTType` 后交给
  /// `AVAssetResourceLoadingContentInformationRequest.contentType`。
  private static func contentIdentifier(mime: String?, origin: URL) -> String? {
    if let mime = mime, !mime.isEmpty {
      let lower = mime.lowercased()
      let generic =
        lower == "application/octet-stream" || lower == "binary/octet-stream"
      if !generic, let type = UTType(mimeType: mime) { return type.identifier }
    }
    if let ext = mediaExtension(origin: origin), let type = UTType(filenameExtension: ext) {
      return type.identifier
    }
    if let mime = mime, let type = UTType(mimeType: mime) { return type.identifier }
    return nil
  }

  /// 取 `path=` 查询参数（JSON 数组字符串或裸路径）或 URL 路径的扩展名。
  private static func mediaExtension(origin: URL) -> String? {
    let items = URLComponents(url: origin, resolvingAgainstBaseURL: false)?.queryItems ?? []
    for item in items where item.name == "path" {
      guard let raw = item.value, !raw.isEmpty else { continue }
      var name = raw
      if raw.hasPrefix("["), let data = raw.data(using: .utf8),
        let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
        let first = arr.first
      {
        name = first
      }
      let ext = (name as NSString).pathExtension
      if !ext.isEmpty { return ext }
    }
    let ext = origin.pathExtension
    return ext.isEmpty ? nil : ext
  }

  /// `206` 的 `Content-Range: bytes 0-1/12345` → 12345；否则用 `Content-Length`。
  private static func totalLength(_ http: HTTPURLResponse) -> Int64? {
    if let cr = http.value(forHTTPHeaderField: "Content-Range"),
      let slash = cr.lastIndex(of: "/"),
      let total = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    {
      return total
    }
    let len = http.expectedContentLength
    return len > 0 ? len : nil
  }
}

// MARK: - 错误串（对齐 Dart `classifyPlayerError` 的三类失败）

enum MediaPlayerError {
  static func plain(_ message: String) -> NSError {
    NSError(
      domain: "SynHubMediaPlayer", code: -1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }

  static func network(_ error: Error) -> NSError {
    plain(describe(error))
  }

  /// AVFoundation / URLSession 的错误链摘要（**永不包含 URL 与凭据**）。
  static func describe(_ error: Error) -> String {
    var parts: [String] = []
    var current: NSError? = error as NSError
    var depth = 0
    while let e = current, depth < 5 {
      if e.domain == NSURLErrorDomain {
        let code = URLError.Code(rawValue: e.code)
        switch code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
          .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
          .clientCertificateRejected:
          parts.append("tls cert rejected (\(e.code))")
        default:
          parts.append("\(e.domain)(\(e.code))")
        }
      } else if e.domain == AVFoundationErrorDomain {
        parts.append("AVFoundation \(e.code)")
      } else {
        parts.append("\(e.domain)(\(e.code))")
      }
      if let msg = e.userInfo[NSLocalizedDescriptionKey] as? String, !msg.isEmpty {
        parts.append(scrub(msg))
      }
      current = e.userInfo[NSUnderlyingErrorKey] as? NSError
      depth += 1
    }
    return parts.joined(separator: " | ")
  }

  private static func scrub(_ text: String) -> String {
    var out = text
    for pattern in ["https?://\\S+"] {
      if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
        out = re.stringByReplacingMatches(
          in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<url>")
      }
    }
    return String(out.prefix(160))
  }
}

