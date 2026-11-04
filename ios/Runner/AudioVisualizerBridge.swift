// `synhub/audio_visualizer` 的 **iOS 实现**（r689）：真频谱（来自本机播放输出）。
//
// ## 为什么是这个形态
//
// Android 那份（`AudioVisualizerBridge.kt`）用 `AudioRecord` 的
// **playback capture**（`MediaProjection` 时代的 `REMOTE_SUBMIX`）直接录"正在播的声音"。
// iOS **没有**对应的公开 API —— 想在 iOS 上拿到同一路音频，只有两条路：
//
//   ① `AVAudioEngine` + `installTap`：只能抓**我们自己引擎**的输出
//      （而本 App 的播放走 AVPlayer，不是 AVAudioEngine）；
//   ② **`MTAudioProcessingTap`**：挂在 `AVPlayerItem.audioMix` 上，
//      AVFoundation 会把**这一路音频**的 PCM 交给 tap 的 process 回调。
//      —— 这就是这里用的那条，也是 iOS 上唯一能抓"正在播的那一路"的口子。
//
// ## 三个 iOS 特有的事实（踩过才知道）
//
// ① **tap 必须在 item 播放前装好**：`AVPlayerItem.audioMix` 在起播后赋值**不保证
//    生效**（AVFoundation 只在装载时读一次）。所以不由"attach 时现装"，而是
//    **装载时**就装上（`SpectrumHub.installTapIfNeeded(on:)`，由
//    `MediaPlayerBridge.loadItem` 调），`attach` 只负责"打开水龙头"（bars>0）。
//    这也意味着：没人在看频谱时，process 回调**仍然**会被调（必须先
//    `MTAudioProcessingTapGetSourceAudio` 把音频交回去，否则**没声音**），
//    但会立刻返回、不做 FFT —— CPU 代价接近 0。
//
// ② **tap 的 process 回调跑在实时音频线程上**：那里不许 allocate、不许等锁太久、
//    不许碰 UIKit。所以：FFT 用**预分配**的 `vDSP` setup 与缓冲区；
//    算完只把 `[Float]` 丢到主队列再发给 Flutter。
//
// ③ **PCM 格式不一定是"交错 float32"**：AVFoundation 可能给非交错 float32，
//    也可能给交错。这里两种都处理（非交错取第 0 声道；交错按 stride 取）。
//    `mNumberBuffers == 0` / 位数不是 32 位时**直接跳过**（不猜）。
//
// ## 与 Android 的契约一致
//
// * `probe` → `{available, reason}`；
// * `attach {sessionId, bars}` → `{ok, reason}`；`detach` → 关掉；
// * 事件通道 `synhub/audio_visualizer/events` 发 **`List<double>`（长度 = bars，每项 0..1）**。
// * **没有 attach 成功就不会有事件**（Dart 侧据此回落推导动效，见
//   `audio_visualizer_source.dart`）——这一条与 Android 逐字一致。
//
// ★ 会话 id 的语义差异：iOS 上只有一个"当前播放"的音频，所以 `attach` 不校验
//   `sessionId` 是否等于某个原生对象（拿不到 AVPlayer 的会话号），只把它当
//   "Dart 侧的代数"回显。理由写在 `docs/platform-ios.md` §29。

import Accelerate
import AVFoundation
import Flutter

/// 频谱中枢：装着"要不要算/算几根/发给谁"，以及 tap 的 process 回调。
///
/// 单例：一个 App 同时只有一路音频输出（本 App 的播放设计就是这样），
/// 多路同时播的场景不存在。
final class SpectrumHub {
  static let shared = SpectrumHub()

  /// 当前要算几根柱子（0 = 不算，只把音频原样交回去）。
  private var bars = 0
  /// Flutter 事件 sink（事件通道 onListen 时装上，detach/onCancel 时清掉）。
  private var sink: FlutterEventSink?
  private let lock = NSLock()

  /// FFT 配置（`vDSP_create_fftsetup`），首次需要时建一次。
  private var fftSetup: FFTSetup?
  private let fftLog2n: vDSP_Length = 10  // 1024 点
  private var fftN: Int { 1 << Int(fftLog2n) }

  /// 预分配的 buffer（实时线程里不许 allocate）。
  private var realp = [Float](repeating: 0, count: 512)
  private var imagp = [Float](repeating: 0, count: 512)
  private var window = [Float](repeating: 0, count: 1024)
  private var magnitudes = [Float](repeating: 0, count: 512)
  private var smoothed: [Float] = []
  /// 进 FFT 的环形样本缓冲（跨回调累积，攒够 1024 点算一次）。
  private var pending: [Float] = []
  private var lastEmit: CFTimeInterval = 0

  private init() {
    // Hann 窗：不做窗化时频谱会"漏"得到处都是，柱子会随音高乱跳。
    vDSP_hann_window(&window, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))
    pending.reserveCapacity(fftN * 2)
  }

  // ---------------------------------------------------------------- 对外开关

  /// 环形缓冲：**实时线程只写、后台定时器只读** ⇒ 两边都不加锁。
  ///
  /// ★ r689 的第一版把 FFT 直接放在 process 回调里，结果**只被调了一次**
  /// （`process #1` 之后音频线程再也不回调，电平恒 0）—— 实时音频线程里
  /// allocate / 取锁 / 跑 FFT 会把这条线程拖死。现在按苹果推荐的写法：
  /// 回调里**只做一次 memcpy**，FFT 交给 20 Hz 的 `DispatchSourceTimer`。
  private var ring = [Float](repeating: 0, count: 8192)
  private var ringWrite = 0
  private var ringFilled = 0
  /// ★ 来自 tap `prepare` 的 ASBD：**是不是非交错**。
  /// r689 的 bug：用 `buffers.count > 1` 判非交错 —— **单声道非交错也只有 1 个 buffer**
  /// ⇒ 被判成"交错"直接 return，环形缓冲永远是空的（`filled=0`，电平恒 0）。
  private var isNonInterleaved = true
  /// 声道数（交错时按它跨步取第 0 声道）
  private var channels = 1
  private var timer: DispatchSourceTimer?
  private let computeQueue = DispatchQueue(label: "synhub.spectrum.fft", qos: .utility)

  func setBars(_ n: Int) {
    let clamped = max(0, n)
    bars = clamped
    if smoothed.count != clamped { smoothed = [Float](repeating: 0, count: clamped) }
    if clamped > 0 {
      startTimerIfNeeded()
    } else {
      timer?.cancel()
      timer = nil
    }
  }

  func setSink(_ s: FlutterEventSink?) {
    sink = s
    if s == nil { setBars(0) }
  }

  func currentBars() -> Int { bars }

  private func startTimerIfNeeded() {
    if timer != nil { return }
    let t = DispatchSource.makeTimerSource(queue: computeQueue)
    t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
    t.setEventHandler { [weak self] in self?.tick() }
    t.resume()
    timer = t
    NSLog("[audio_visualizer] 频谱定时器已启动 bars=\(bars)")
  }

  /// 给一个**还没起播**的 item 装 tap（没有音轨就什么都不做）。
  ///
  /// 为什么异步：`loadTracks` 是 async 的，而 `loadItem` 是同步路径。
  /// 在 `replaceCurrentItem` 之后、`play` 之前把 `audioMix` 赋上就来得及
  /// （AVFoundation 在装载时读，实测模拟器 18.6 上生效）。
  func installTapIfNeeded(on item: AVPlayerItem) {
    item.asset.loadTracks(withMediaType: .audio) { [weak self, weak item] tracks, _ in
      guard let self = self, let item = item, let track = tracks?.first else { return }
      self.install(on: item, track: track)
    }
  }

  private func install(on item: AVPlayerItem, track: AVAssetTrack) {
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: Unmanaged.passUnretained(self).toOpaque(),
      init: tapInit,
      finalize: tapFinalize,
      prepare: tapPrepare,
      unprepare: tapUnprepare,
      process: tapProcess
    )
    // ★ 出参类型是 **`MTAudioProcessingTap?`**（不是 `Unmanaged<…>?`）——
    //   r689 编译期踩过：`&tapRef` 写成 Unmanaged 时 Swift 直接报
    //   "Cannot convert value of type 'Unmanaged<MTAudioProcessingTap>?'"。
    var createdTap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(
      kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects,
      &createdTap)
    guard status == noErr, let created = createdTap else {
      NSLog("[audio_visualizer] MTAudioProcessingTapCreate 失败 status=\(status)")
      return
    }
    let params = AVMutableAudioMixInputParameters(track: track)
    params.audioTapProcessor = created
    let mix = AVMutableAudioMix()
    mix.inputParameters = [params]
    item.audioMix = mix
    NSLog("[audio_visualizer] tap 已装在 item 上 track=\(track.trackID)")
  }

  /// 实时线程调用：**只 memcpy 进环形缓冲**（无 allocate、无锁、无日志）。
  fileprivate func setFormat(isNonInterleaved: Bool, channels: Int) {
    self.isNonInterleaved = isNonInterleaved
    self.channels = max(1, channels)
  }

  fileprivate func formatInfo() -> (isNonInterleaved: Bool, channels: Int) {
    (isNonInterleaved, channels)
  }

  /// 实时线程取样本的**唯一**入口：非交错（或单声道）直接抄；交错时按 [channels] 跨步。
  fileprivate func writeRing(
    _ samples: UnsafePointer<Float>, frames: Int, channels ch: Int, nonInterleaved: Bool
  ) {
    if nonInterleaved || ch <= 1 {
      writeRing(samples, count: frames)
      return
    }
    // 交错立体声：把第 0 声道抽出来（跨步取）—— 直接连续抄会把右声道混进来
    guard bars > 0, frames > 0 else { return }
    var mono = [Float](repeating: 0, count: frames)
    var i = 0
    while i < frames {
      mono[i] = samples[i * ch]
      i += 1
    }
    mono.withUnsafeBufferPointer { writeRing($0.baseAddress!, count: frames) }
  }

  fileprivate func writeRing(_ samples: UnsafePointer<Float>, count: Int) {
    guard bars > 0, count > 0 else { return }
    let cap = ring.count
    var n = min(count, cap)
    ring.withUnsafeMutableBufferPointer { buf in
      guard let base = buf.baseAddress else { return }
      if ringWrite + n <= cap {
        (base + ringWrite).update(from: samples, count: n)
      } else {
        let first = cap - ringWrite
        (base + ringWrite).update(from: samples, count: first)
        (base).update(from: samples + first, count: n - first)
      }
    }
    ringWrite = (ringWrite + n) % cap
    ringFilled = min(cap, ringFilled + n)
    if n == 0 { n = 0 }
  }

  // ---------------------------------------------------------------- FFT（后台定时器）

  #if DEBUG
    private var tickCount = 0
  #endif

  private func tick() {
    #if DEBUG
      tickCount += 1
      if tickCount % 200 == 0 {
        NSLog("[audio_visualizer] tick #\(tickCount) bars=\(bars) filled=\(ringFilled)")
      }
    #endif
    let n = fftN
    let needed = 2 * n  // 两次 FFT 的余量（重叠加窗）
    guard bars > 0, ringFilled >= n else { return }
    let take = min(needed, ringFilled)
    var samples = [Float](repeating: 0, count: take)
    let cap = ring.count
    let start = (ringWrite - take + cap * 2) % cap
    ring.withUnsafeBufferPointer { buf in
      guard let base = buf.baseAddress else { return }
      if start + take <= cap {
        samples.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: base + start, count: take) }
      } else {
        let first = cap - start
        samples.withUnsafeMutableBufferPointer { out in
          out.baseAddress!.update(from: base + start, count: first)
          (out.baseAddress! + first).update(from: base, count: take - first)
        }
      }
    }
    computeAndEmit(samples: samples)
  }

  private func computeAndEmit(samples: [Float]) {
    let n = fftN
    guard bars > 0, samples.count >= n else { return }
    if fftSetup == nil { fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2)) }
    guard let setup = fftSetup else { return }

    var windowed = [Float](repeating: 0, count: n)
    vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

    var real = [Float](repeating: 0, count: n / 2)
    var imag = [Float](repeating: 0, count: n / 2)
    real.withUnsafeMutableBufferPointer { rp in
      imag.withUnsafeMutableBufferPointer { ip in
        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        windowed.withUnsafeBufferPointer { wp in
          wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
          }
        }
        vDSP_fft_zrip(setup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
      }
    }

    let binCount = n / 2
    let barCount = bars
    guard barCount > 0 else { return }
    var levels = [Float](repeating: 0, count: barCount)
    let minBin = 1
    let maxBin = binCount - 1
    for b in 0..<barCount {
      let lo = minBin + Int(Double(maxBin - minBin) * pow(Double(b) / Double(barCount), 2.0))
      let hi = minBin + Int(Double(maxBin - minBin) * pow(Double(b + 1) / Double(barCount), 2.0))
      var sum: Float = 0
      var k = lo
      while k < max(lo + 1, hi) && k < binCount {
        sum += magnitudes[k]
        k += 1
      }
      let denom = Float(max(1, k - lo))
      let mag = sum / denom / Float(n)
      let db = 20 * log10(max(mag, 1e-7))
      var v = (db + 80) / 80
      v = min(1, max(0, v))
      let prev = smoothed[b]
      levels[b] = v > prev ? v : prev * 0.82 + v * 0.18
    }
    smoothed = levels

    let now = CACurrentMediaTime()
    if now - lastEmit < 0.05 { return }
    lastEmit = now
    guard let s = sink else { return }
    let payload: [Double] = levels.map { Double($0) }
    DispatchQueue.main.async { s(payload) }
  }
}

// MARK: - tap 的 C 回调

private func hub(_ tap: MTAudioProcessingTap) -> SpectrumHub? {
  // ★ `MTAudioProcessingTapGetStorage` 返回的是**非可选**的
  //   `UnsafeMutableRawPointer`（Swift 里没给 optional 语义）⇒ 不能 `guard let`，
  //   只用"空指针"判一下（r689 编译期踩过：`Initializer for conditional binding ...`）。
  let raw = MTAudioProcessingTapGetStorage(tap)
  if raw == UnsafeMutableRawPointer(bitPattern: 0) { return nil }
  return Unmanaged<SpectrumHub>.fromOpaque(raw).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
  tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { _ in }

private let tapPrepare: MTAudioProcessingTapPrepareCallback = {
  tap, _, formatPointer in
  guard let h = hub(tap) else { return }
  let asbd = formatPointer.pointee
  let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
  NSLog(
    "[audio_visualizer] tap prepare rate=\(asbd.mSampleRate) "
      + "ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) "
      + "nonInterleaved=\(nonInterleaved)")
  h.setFormat(isNonInterleaved: nonInterleaved, channels: Int(asbd.mChannelsPerFrame))
  h.setBars(h.currentBars())  // 重算平滑数组
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

/// 诊断计数（r689 排查用；只在 `#if DEBUG` 里使用 —— release 档不编译这块）。
private var processCalls: Int = 0

private let tapProcess: MTAudioProcessingTapProcessCallback = {
  tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
  // ★ ① 必须把音频交回去，否则**没声音**
  let status = MTAudioProcessingTapGetSourceAudio(
    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
  #if DEBUG
    // 诊断只在 debug 档打（release 的实时线程里连日志都不该有）
    processCalls += 1
    if processCalls % 100 == 0 {
      let bufs = UnsafeMutableAudioBufferListPointer(bufferListInOut)
      NSLog(
        "[audio_visualizer] process #\(processCalls) status=\(status) "
          + "out=\(numberFramesOut.pointee) buffers=\(bufs.count) "
          + "bytes=\(bufs.count > 0 ? bufs[0].mDataByteSize : 0)")
    }
  #endif
  guard status == noErr else { return }
  guard let h = hub(tap), h.currentBars() > 0 else { return }

  let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
  guard buffers.count > 0, let first = buffers[0].mData else { return }
  let frames = Int(numberFramesOut.pointee)
  guard frames > 0 else { return }
  // ③ 只处理 32 位 float（AVFoundation 的 tap 恒给这个格式；不是就跳过，不猜）
  guard buffers[0].mNumberChannels > 0, buffers[0].mDataByteSize >= UInt32(frames * 4) else {
    return
  }
  let samples = first.assumingMemoryBound(to: Float.self)
  // ★ 判"交错"只认 prepare 里的 ASBD 标志，**不许**看 `buffers.count`
  //   （单声道非交错也只有 1 个 buffer —— r689 就栽在这里，电平恒 0）。
  let fmt = h.formatInfo()
  h.writeRing(
    samples,
    frames: min(frames, Int(buffers[0].mDataByteSize) / 4),
    channels: fmt.channels,
    nonInterleaved: fmt.isNonInterleaved)
}

// MARK: - 通道

/// `synhub/audio_visualizer` ＋ `synhub/audio_visualizer/events`。
final class AudioVisualizerBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
  static let channelName = "synhub/audio_visualizer"
  static let eventsName = "synhub/audio_visualizer/events"

  static let shared = AudioVisualizerBridge()
  private var sink: FlutterEventSink?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(
      name: eventsName, binaryMessenger: registrar.messenger())
    events.setStreamHandler(shared)
    registrar.addMethodCallDelegate(shared, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "probe":
      // 平台支持（tap 能装）——"支持"不等于"现在有声音"，attach 之后还要有播放。
      result(["available": true, "reason": "ok"])
    case "attach":
      let bars = (call.arguments as? [String: Any])?["bars"] as? Int ?? 0
      let sessionId = (call.arguments as? [String: Any])?["sessionId"] as? Int ?? 0
      guard bars > 0 else {
        result(["ok": false, "reason": "bad-bars"])
        return
      }
      guard sessionId > 0 else {
        result(["ok": false, "reason": "no-session-id"])
        return
      }
      SpectrumHub.shared.setBars(bars)
      NSLog("[audio_visualizer] attach sessionId=\(sessionId) bars=\(bars)")
      result(["ok": true, "reason": "ok", "sessionId": sessionId])
    case "detach":
      SpectrumHub.shared.setBars(0)
      NSLog("[audio_visualizer] detach")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    SpectrumHub.shared.setSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    SpectrumHub.shared.setSink(nil)
    return nil
  }
}
