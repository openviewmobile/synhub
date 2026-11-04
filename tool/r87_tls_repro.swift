// r87 最小复现（原生层，宿主 CLI）：把真 NAS 的两条流 URL 分别交给
//   ① 平台默认 TLS（严格主机名）URLSession   → 预期 -1202
//   ② MediaTrustDelegate（scoped：精确主机 + 链仍系统校验）URLSession → 预期 206
//   ③ AVURLAsset + MediaResourceLoader（= App 内自研 AVPlayer 桥同一条路）
//      → 打 AVPlayerItem.status / error，看它到底卡在哪
//
// 编译（不需要 Flutter）：
//   swiftc -O -o /tmp/r87_tls_repro \
//     macos/Runner/MediaPlayerTransport.swift tool/r87_tls_repro.swift
// 运行：
//   /tmp/r87_tls_repro "<https URL>"
//
// 为什么单独做：App 内 `NSLog` 在 `flutter test -d macos` 里不出现在统一日志，
// AVFoundation 的错误又常被统一日志 `<private>` 掉；这条 CLI 能把**原文**打出来。
import AVFoundation
import Foundation

let tag = "r87"

func log(_ s: String) {
  FileHandle.standardError.write(("[" + tag + "] " + s + "\n").data(using: .utf8)!)
}

func hostPort(_ url: URL) -> String {
  let p = url.port.map { ":\($0)" } ?? ""
  return (url.host ?? "?") + p
}

func defaultSessionFetch(_ url: URL, _ done: @escaping (String) -> Void) {
  var request = URLRequest(url: url)
  request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
  let task = URLSession.shared.dataTask(with: request) { data, response, error in
    if let error = error {
      done("ERROR \(MediaPlayerError.describe(error))")
      return
    }
    let http = response as? HTTPURLResponse
    done("HTTP \(http?.statusCode ?? -1) bytes=\(data?.count ?? 0)")
  }
  task.resume()
}

func policySessionFetch(_ url: URL, _ done: @escaping (String) -> Void) {
  let config = URLSessionConfiguration.ephemeral
  config.timeoutIntervalForRequest = 30
  let session = URLSession(
    configuration: config, delegate: MediaTrustDelegate(), delegateQueue: nil)
  var request = URLRequest(url: url)
  request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
  let task = session.dataTask(with: request) { data, response, error in
    if let error = error {
      done("ERROR \(MediaPlayerError.describe(error))")
      return
    }
    let http = response as? HTTPURLResponse
    done("HTTP \(http?.statusCode ?? -1) bytes=\(data?.count ?? 0)")
  }
  task.resume()
}

/// `AVAssetResourceLoader.delegate` 是**弱引用**：这里显式强持有，
/// 否则 delegate 在异步加载开始前就被 ARC 释放（实测症状：`-1002 unsupported URL`）。
var keepAlive: [Any] = []

/// ③ 完全照 `MediaPlayerBridge.loadItem` 那条路：自定义 scheme + 资源加载器。
func avAssetPlayback(_ url: URL, _ done: @escaping (String) -> Void) {
  guard let proxied = MediaTlsPolicy.proxyURL(url) else {
    done("proxyURL failed")
    return
  }
  let asset = AVURLAsset(url: proxied)
  let loader = MediaResourceLoader()
  loader.onFailure = { message in log("resourceLoader onFailure: \(message)") }
  keepAlive.append(loader)
  asset.resourceLoader.setDelegate(
    loader, queue: DispatchQueue(label: "r87.resource"))
  let item = AVPlayerItem(asset: asset)
  // ★ 与 App 桥一致：挂 `AVPlayerItemVideoOutput`，看**真帧**能不能出来
  //   （App 的致命面板正是"窗口内没有首帧"触发的）。
  let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
  ])
  item.add(output)
  let player = AVPlayer(playerItem: item)
  var ticks = 0
  var frames = 0
  var lastWH = "0x0"
  let timer = Timer(timeInterval: 0.5, repeats: true) { t in
    ticks += 1
    if item.status == .readyToPlay {
      player.play()
      let time = item.currentTime()
      if output.hasNewPixelBuffer(forItemTime: time),
        let buf = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
      {
        frames += 1
        lastWH = "\(CVPixelBufferGetWidth(buf))x\(CVPixelBufferGetHeight(buf))"
      }
      if ticks >= 8 {
        t.invalidate()
        let pos = CMTimeGetSeconds(player.currentTime())
        done(String(format: "READY pos=%.2fs duration=%.2fs frames=%d wh=%@",
                    pos.isFinite ? pos : -1,
                    CMTimeGetSeconds(item.duration).isFinite ? CMTimeGetSeconds(item.duration) : -1,
                    frames, lastWH))
      }
      return
    }
    if item.status == .failed {
      t.invalidate()
      let err = item.error ?? NSError(domain: "r87", code: 0)
      done("FAILED \(MediaPlayerError.describe(err))")
      return
    }
    if ticks >= 30 {
      t.invalidate()
      done("TIMEOUT status=\(item.status.rawValue) isPlayable=\(asset.isPlayable)")
    }
  }
  RunLoop.main.add(timer, forMode: .common)
}

// ------------------------------------------------------------------ main

let args = CommandLine.arguments
guard args.count >= 2, let url = URL(string: args[1]) else {
  log("usage: r87_tls_repro <url> [--host H] [--fp SHA256]")
  exit(2)
}
var hostOverride: String?
var fingerprintOverride: String?
var argIndex = 2
while argIndex < args.count {
  switch args[argIndex] {
  case "--host":
    argIndex += 1
    if argIndex < args.count { hostOverride = args[argIndex] }
  case "--fp":
    argIndex += 1
    if argIndex < args.count { fingerprintOverride = args[argIndex] }
  default:
    break
  }
  argIndex += 1
}
let host = hostOverride ?? url.host ?? ""
MediaTlsPolicy.shared.set(host: host, fingerprint: fingerprintOverride)
log("target host=\(hostPort(url)) scheme=\(url.scheme ?? "?")")
log("policy needsProxy=\(MediaTlsPolicy.shared.needsProxy(url))")

var pending = 3
func finish(_ label: String, _ result: String) {
  print("\(label): \(result)")
  pending -= 1
  if pending == 0 { exit(0) }
}

defaultSessionFetch(url) { finish("A_DEFAULT", $0) }
policySessionFetch(url) { finish("B_POLICY", $0) }
avAssetPlayback(url) { finish("C_AVASSET", $0) }

RunLoop.main.run(until: Date().addingTimeInterval(60))
log("TIMEOUT waiting")
exit(3)
