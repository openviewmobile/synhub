// `synhub/video_frame` 的 **iOS 实现**（r689）：从本地视频文件抽一帧缩略图。
//
// ## 为什么要有这一份
//
// Dart 侧 `lib/src/core/media/video_frame_bridge.dart` 早就把契约定死了：
//   * `isSupported()` → `bool`
//   * `extractFrame {path, atMs, maxWidth}` → `{bytes, mime, width, height}`
// 而它一直**只有 Kotlin 实现**（`VideoFrameBridge.kt`，`MediaMetadataRetriever`），
// iOS 上能力层如实报 `unavailable:not-implemented-on-host`
// ⇒ 视频列表行在 iOS 上永远只有场记板占位图（`DA323`）。
//
// iOS 的等价物是 **`AVAssetImageGenerator`**（AVFoundation），语义几乎一对一：
//   `MediaMetadataRetriever.getFrameAtTime` ↔ `AVAssetImageGenerator.copyCGImage`
//   `Bitmap.compress(JPEG, 85)` ↔ `UIImage.jpegData(0.85)`
//
// ## 四条 iOS 特有的事实（照抄 Android 会错）
//
// ① **`maximumSize` 是"边界框"，不是"目标宽度"**。Android 的 `maxWidth` 语义是
//    "等比缩到宽度 ≤ maxWidth"。这里换算成 `CGSize(width: maxWidth, height: .max)`
//    才是等比缩放；直接给 `(maxWidth, maxWidth)` 会把竖屏视频压成方块。
//
// ② **必须显式要求"零容差"**，否则 generator 会给**最近的关键帧**
//    （可能差好几秒）。Android 的 `getFrameAtTime(atMs*1000)` 也是精确时间戳
//    语义（只是它内部同样可能回退到关键帧），这里对齐成 `.zero`。
//
// ③ **`copyCGImage` 是同步阻塞的**（解码一帧可能几十毫秒到几百毫秒），
//    绝不能在主线程调用 ⇒ 走后台队列，结果回主线程 `result(...)`。
//
// ④ **视频轨没有视频流**（纯音频文件）时 `copyCGImage` 抛 `AVError`，
//    这里**如实回 `false`**（Dart 侧把 null/false 当"抽不出来"回落占位图标），
//    不许编一张空图。
//
// ## 与 Android 的一致之处
//
// * **不需要任何权限**（只读本地文件；不碰相册、不碰摄像头）；
// * 返回的是 **JPEG**（`mime == "image/jpeg"`），与 Kotlin 的
//   `Bitmap.CompressFormat.JPEG, 85` 同一编码；
// * 输入是**本地路径**（Dart 侧先下头部若干 MB 到临时文件），网络不在这里做。

import AVFoundation
import Flutter
import UIKit

/// 视频首帧抽取桥（`synhub/video_frame`）。
final class VideoFrameBridge: NSObject, FlutterPlugin {
  static let channelName = "synhub/video_frame"

  /// 与 Dart `kVideoFrameDefaultMaxWidth` 一致（Dart 每次都会显式传，这里只是兜底）。
  static let defaultMaxWidth = 320

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = VideoFrameBridge()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      // AVAssetImageGenerator 在 iOS 上恒可用（模拟器同样有 AVFoundation 软件解码）。
      result(true)

    case "extractFrame":
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String, !path.isEmpty
      else {
        // 参数不对 ⇒ 与 Android 一致：回 false（不是 error，Dart 侧只看得到 null）
        result(false)
        return
      }
      let atMs = (args["atMs"] as? Int) ?? 0
      let maxWidth = max(1, (args["maxWidth"] as? Int) ?? Self.defaultMaxWidth)
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: url.path) else {
        NSLog("[video_frame] 文件不存在：\(url.path)")
        result(false)
        return
      }
      extract(url: url, atMs: atMs, maxWidth: maxWidth, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 后台解码一帧；**结果一律回主线程**（Flutter 的 `result` 不保证线程安全）。
  private func extract(
    url: URL, atMs: Int, maxWidth: Int, result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let asset = AVURLAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true  // 竖屏视频不歪
      // ② 精确时间戳（否则拿到最近关键帧，缩略图会对不上条目开头）
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      // ① 等比缩到 width ≤ maxWidth（高度给 .max 才是"边界框"语义）
      generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: .greatestFiniteMagnitude)

      let time = CMTime(value: CMTimeValue(max(0, atMs)), timescale: 1000)
      var actual = CMTime.zero
      let image: CGImage
      do {
        image = try generator.copyCGImage(at: time, actualTime: &actual)
      } catch {
        // ④ 纯音频 / 容器解不了 / 头部片段没有视频帧 ⇒ 如实 false
        NSLog("[video_frame] 抽帧失败 path=\(url.lastPathComponent) atMs=\(atMs) err=\(error)")
        DispatchQueue.main.async { result(false) }
        return
      }

      let uiImage = UIImage(cgImage: image)
      guard let jpeg = uiImage.jpegData(compressionQuality: 0.85) else {
        DispatchQueue.main.async { result(false) }
        return
      }
      let payload: [String: Any] = [
        // ★ Flutter 侧要求 Uint8List：Swift 里必须包成 FlutterStandardTypedData，
        //   直接塞 Data 会让 Dart 端 `raw['bytes'] is! Uint8List` ⇒ 解成 null。
        "bytes": FlutterStandardTypedData(bytes: jpeg),
        "mime": "image/jpeg",
        "width": image.width,
        "height": image.height,
      ]
      NSLog(
        "[video_frame] ok path=\(url.lastPathComponent) atMs=\(atMs) "
          + "\(image.width)x\(image.height) \(jpeg.count)B")
      DispatchQueue.main.async { result(payload) }
    }
  }
}
