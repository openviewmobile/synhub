// 自研 macOS 播放器桥（**AVPlayer / AVFoundation**）—— 与 Android
// `android/app/src/main/kotlin/com/openviewai/synhub/MediaPlayerBridge.kt` 的
// 通道契约**逐参数对齐**（通道名 / 方法名 / 参数名 / 返回键 / 事件字段）。
//
// 为什么必须自己写（而不是直接用 `video_player` 插件）：
//   * `video_player` 的 AVPlayer 走**系统默认 TLS 校验**，真 NAS 那种
//     "证书链合法但主机名不匹配"（`https://nas.example.com:5001`，
//     `CN=nas.example.com`）的流**握手必失败**；Dart 侧的 TrustStore
//     管不到原生栈（见 docs/platform-macos-audit.md §①.2）；
//   * 轨道选择 / 内封字幕 / 音量 / 画面比例 / 播放列表跳转 —— 插件不暴露。
//
// ## TLS 怎么解决（本文件的核心）
//
// 1. **只对目标主机改写 scheme**：`setTlsPolicy(host:fingerprint:)` 记下当前会话
//    那一台 NAS 主机；载入 URL 时，**只有 https 且 host 精确等于它**才把
//    `https://…` 改写成自定义 scheme `synhub-https://…` 交给
//    `AVURLAsset`（AVFoundation 对未知 scheme 会回调
//    `AVAssetResourceLoaderDelegate`，这是唯一能拦截 AVPlayer 取流的官方口子）。
// 2. 代理请求由**我们自己的 `URLSession`** 发出：`URLSessionDelegate` 的
//    `urlSession(_:didReceive:completionHandler:)` 里
//    * 目标主机 → 先按系统默认（证书链 **+ 主机名**）验；通过就放行；
//      * 不通过 → 用"**不校验主机名**的 SSL policy"再验一次链（等价 Android 的
//        `HostnameVerifier` 放宽：链仍由系统 CA 校验）；
//      * 还给了指纹 → 只对**这一枚**叶子证书 SHA-256 放行（自签场景，与 Dart
//        `TrustStore` / Android `PinnedTrustManager` 同一枚指纹）。
//    * 其余主机 → `performDefaultHandling`（原验证器，绝不放宽）。
// 3. 其余主机 / 非 https ⇒ 不改写，AVPlayer 自己直连，行为与插件一致。
//
// ## 画面怎么进 Flutter
//
// `AVPlayerItemVideoOutput` + `FlutterTexture`：主线程 60Hz 轮询视频输出，
// 有新帧就 `textureFrameAvailable`，`copyPixelBuffer` 回当前帧。Dart 侧仍然是
// `Texture(textureId:)` —— **契约不变**（不是 PlatformView）。
//
// ## 与 Android 的差异（如实记载）
//
//   * **内封字幕文本**：Android 用 Media3 `onCues` 给文本；这里用
//     `AVPlayerItemLegibleOutput` 给 `NSAttributedString`，只取 `string`，
//     多个 cue 用 `\n` 连接（形状一致；渲染仍由 Dart overlay 做）。
//   * **音频声道数 / codec 名**：AVFoundation 的 `AVMediaSelectionOption` 不暴露
//     `channelCount` / codec 串 ⇒ 这两项固定回 `0` / `""`（不编）。
//   * 其余方法名 / 参数名 / 事件键与 Kotlin **无差异**。
import AVFoundation
import CoreVideo
import Foundation
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

// MARK: - 平台收口（第 92 轮：同一份源码同时编进 macOS 与 iOS target）

/// `registrar` 的 API 形态两家不同：macOS 暴露 `messenger` / `textures`
/// **属性**，iOS 暴露同名**方法**。除了这一处，本文件其余内容两平台一字不差
/// —— 所以 iOS target **直接引用本文件**（见 `ios/Runner.xcodeproj/project.pbxproj`
/// 里 `sourceTree = SOURCE_ROOT` 的 `../macos/Runner/MediaPlayerBridge.swift`），
/// **不存在"两份实现各自漂移"**。
///
/// ⚠️ AVFoundation 在两家是同源的，但下面这一点**不要想当然**：
/// `AVAssetResourceLoaderDelegate` 在 iOS 上同样只在 delegate 被**强持有**时
/// 才回调（弱引用被 ARC 提前释放的症状是 `-1002 unsupported URL`，macOS 已踩过）。
/// 本文件的 `MediaResourceLoader` 由 `MediaPlayerBridge` 强持有，两平台一致。
#if os(macOS)
private func registrarMessenger(_ r: FlutterPluginRegistrar) -> FlutterBinaryMessenger {
  return r.messenger
}
private func registrarTextures(_ r: FlutterPluginRegistrar) -> FlutterTextureRegistry {
  return r.textures
}
#else
private func registrarMessenger(_ r: FlutterPluginRegistrar) -> FlutterBinaryMessenger {
  return r.messenger()
}
private func registrarTextures(_ r: FlutterPluginRegistrar) -> FlutterTextureRegistry {
  return r.textures()
}
#endif


// MARK: - 纹理（AVPlayerItemVideoOutput → FlutterTexture）

/// 把一个 `AVPlayerItemVideoOutput` 的帧画进 Flutter 纹理。
/// 线程约定：`poll` 在主线程；`copyPixelBuffer` 由 Flutter 光栅线程调 ⇒ 加锁。
final class MediaPlayerTexture: NSObject, FlutterTexture {
  private let registry: FlutterTextureRegistry
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var timer: Timer?
  private weak var output: AVPlayerItemVideoOutput?
  private weak var item: AVPlayerItem?

  private(set) var textureId: Int64 = -1

  /// 真的有新帧时回调（主线程）：桥据此更新首帧 / 视频尺寸状态
  var onNewFrame: ((Int, Int) -> Void)?

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  func register() -> Int64 {
    if textureId < 0 { textureId = registry.register(self) }
    return textureId
  }

  func bind(item: AVPlayerItem, output: AVPlayerItemVideoOutput) {
    self.item = item
    self.output = output
    lock.lock()
    latest = nil
    lock.unlock()
    startPolling()
  }

  func unbind() {
    stopPolling()
    item = nil
    output = nil
    lock.lock()
    latest = nil
    lock.unlock()
  }

  func release() {
    unbind()
    if textureId >= 0 {
      registry.unregisterTexture(textureId)
      textureId = -1
    }
  }

  private func startPolling() {
    stopPolling()
    let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      self?.poll()
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func stopPolling() {
    timer?.invalidate()
    timer = nil
  }

  private func poll() {
    guard let item = item, let output = output else { return }
    let time = item.currentTime()
    guard output.hasNewPixelBuffer(forItemTime: time),
      let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    else { return }
    lock.lock()
    latest = buffer
    lock.unlock()
    if textureId >= 0 { registry.textureFrameAvailable(textureId) }
    onNewFrame?(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }
}

// MARK: - 播放器桥

/// `synhub/player`（MethodChannel）+ `synhub/player_events`（EventChannel）。
/// 整个 App 同时只有一个实例（与 Android 一致）。
final class MediaPlayerBridge: NSObject, FlutterStreamHandler {
  static let shared = MediaPlayerBridge()

  static let channelName = "synhub/player"
  static let eventName = "synhub/player_events"

  private static let tag = "SynologyChatPlayer"
  /// 位置/状态事件间隔（250ms，与 Kotlin `TICK_MS` 一致）
  private static let tickMs = 250

  private var registry: FlutterTextureRegistry?
  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?

  private var player: AVPlayer?
  private var texture: MediaPlayerTexture?
  private var sink: FlutterEventSink?

  private var tickTimer: Timer?
  private var statusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var bufferEmptyObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var failObserver: NSObjectProtocol?
  private var legibleOutput: AVPlayerItemLegibleOutput?
  private var legibleDelegate: LegibleDelegate?

  /// ⚠️ `AVAssetResourceLoader` 对 delegate 是**弱引用**：不在这里强持有的话
  /// 加载器当场被释放 ⇒ 自定义 scheme 的请求永远没人应答（真机上就是黑屏）。
  private var resourceLoader: MediaResourceLoader?

  // 通道侧要回读的状态（音量为 0–100 的整数，和 Dart 的 0–1 换算）
  private var volume = 100
  private var mutedValue = false
  private var speed = 1.0
  private var aspect = "fit"
  private var videoWidth = 0
  private var videoHeight = 0
  private var lastError: String?
  private var firstFrameRendered = false
  private var ended = false
  private var playIntent = false

  private var urls: [String] = []
  private var index = 0

  /// ★ r676（`DA306`）：**播放器代数**。
  ///
  /// 为什么必须有：这个桥是**进程内单例**（一个 EventChannel、一个 `sink`），
  /// 而每个页面各自 `create()` 一次。`onListen` 会在**订阅那一刻**把"当前播放器"
  /// 的状态推出去 —— 那时还是**上一条视频**的播放器（`position`/`duration`/
  /// `videoWidth`/`firstFrame` 全是它的）。Dart 侧原来靠"`create()` 返回前收到
  /// 的事件全丢"来过滤，但**投递顺序不保证**：这条快照完全可能在 `create()`
  /// 返回**之后**才被处理 ⇒ 过滤失效 ⇒ 新页面把上一条的"有画面证据"装到自己
  /// 头上（`_hasVideoOutput = true`）⇒ 看门狗被取消 ⇒ iOS 上 `.mkv` 永远黑屏
  /// 且**永远不给兜底面板**（r675 三张截图一模一样就是这个）。
  ///
  /// 代数是**单调递增**的：`create()` 一开始就 +1，于是"上一代"的任何在途事件
  /// 都能被 Dart 侧无条件丢弃（判据是事件自己的身份，不是到达时间）。
  private var generation = 0

  private override init() { super.init() }

  // MARK: 注册

  func register(with registrar: FlutterPluginRegistrar) {
    // 两平台 registrar 形态不同 —— 统一走文件头的 `registrarTextures` /
    // `registrarMessenger` 收口（`#if os(macOS)`），其余逻辑一字不差。
    registry = registrarTextures(registrar)
    let messenger = registrarMessenger(registrar)
    let method = FlutterMethodChannel(
      name: Self.channelName, binaryMessenger: messenger)
    method.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    methodChannel = method
    let events = FlutterEventChannel(name: Self.eventName, binaryMessenger: messenger)
    events.setStreamHandler(self)
    eventChannel = events
  }

  // MARK: EventChannel

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    emitState()
    emitTracks()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // MARK: MethodChannel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create":
      result(create())
    case "generation":
      // ★ r676（`DA306`）：Dart 侧在 `create()` 之后取一次，作为"我这一代"的
      //   身份；此后所有 `generation` 不等于它的事件一律丢弃。
      result(generation)
    case "load":
      result(
        load(
          urls: args["urls"] as? [String] ?? [],
          index: intArg(args["index"]) ?? 0,
          autoplay: args["autoplay"] as? Bool ?? false,
          volume: doubleArg(args["volume"]) ?? 1.0,
          muted: args["muted"] as? Bool ?? false,
          speed: doubleArg(args["speed"]) ?? 1.0,
          aspect: args["aspect"] as? String ?? "fit"))
    case "setTlsPolicy":
      MediaTlsPolicy.shared.set(
        host: args["host"] as? String, fingerprint: args["fingerprint"] as? String)
      result(true)
    case "play":
      // 与 Kotlin 对称：播到结尾后再 play() 是 no-op ⇒ 先回到起点
      if ended, let player = player {
        ended = false
        player.seek(to: .zero)
      }
      playIntent = true
      player?.playImmediately(atRate: Float(speed))
      emitState()
      result(true)
    case "pause":
      playIntent = false
      player?.pause()
      emitState()
      result(true)
    case "seekTo":
      seekTo(ms: int64Arg(args["positionMs"]) ?? 0)
      result(true)
    case "setSpeed":
      speed = doubleArg(args["speed"]) ?? 1.0
      if playIntent { player?.rate = Float(speed) }
      emitState()
      result(true)
    case "setVolume":
      volume = Int((((doubleArg(args["volume"]) ?? 1.0) * 100).rounded()))
      volume = min(max(volume, 0), 100)
      if volume > 0 && mutedValue { mutedValue = false }
      applyVolume()
      emitState()
      result(true)
    case "setMuted":
      mutedValue = args["muted"] as? Bool ?? false
      applyVolume()
      emitState()
      result(true)
    case "next":
      step(delta: 1)
      result(true)
    case "previous":
      step(delta: -1)
      result(true)
    case "selectTrack":
      selectTrack(kind: args["kind"] as? String ?? "audio", id: args["id"] as? String)
      result(true)
    case "setAspectMode":
      // 画面比例由 Dart 侧的 FittedBox 应用（画面是纹理）；这里只回读状态
      aspect = args["aspect"] as? String ?? "fit"
      emitState()
      result(true)
    case "dispose":
      releasePlayer()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func intArg(_ raw: Any?) -> Int? {
    if let n = raw as? NSNumber { return n.intValue }
    if let s = raw as? String { return Int(s) }
    return nil
  }

  private func int64Arg(_ raw: Any?) -> Int64? {
    if let n = raw as? NSNumber { return n.int64Value }
    if let s = raw as? String { return Int64(s) }
    return nil
  }

  private func doubleArg(_ raw: Any?) -> Double? {
    if let n = raw as? NSNumber { return n.doubleValue }
    if let s = raw as? String { return Double(s) }
    return nil
  }

  // MARK: 创建 / 释放

  private func create() -> Int64 {
    // ★ r676（`DA306`）：换播放器 = 换代数 ⇒ 旧播放器的在途事件立即作废
    generation &+= 1
    releasePlayer()
    guard let registry = registry else {
      NSLogDiag("%@ 创建失败：FlutterTextureRegistry 还没 attach", Self.tag)
      return -1
    }
    let tex = MediaPlayerTexture(registry: registry)
    let id = tex.register()
    tex.onNewFrame = { [weak self] width, height in
      self?.handleNewFrame(width: width, height: height)
    }
    texture = tex
    videoWidth = 0
    videoHeight = 0
    lastError = nil
    firstFrameRendered = false
    ended = false
    playIntent = false
    let p = AVPlayer()
    p.actionAtItemEnd = .pause
    p.allowsExternalPlayback = false
    player = p
    return id
  }

  private func releasePlayer() {
    stopTicking()
    playIntent = false
    teardownItemObservers()
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
    texture?.release()
    texture = nil
    urls = []
    index = 0
    videoWidth = 0
    videoHeight = 0
    firstFrameRendered = false
    ended = false
    lastError = nil
  }

  // MARK: 载入

  private func load(
    urls: [String], index: Int, autoplay: Bool, volume: Double, muted: Bool, speed: Double,
    aspect: String
  ) -> Bool {
    guard let player = player else { return false }
    guard !urls.isEmpty else { return false }
    self.urls = urls
    self.index = min(max(index, 0), urls.count - 1)
    // 换文件重试时把上一次的错误 / 首帧状态清掉（与 Kotlin 一致）
    lastError = nil
    firstFrameRendered = false
    ended = false
    videoWidth = 0
    videoHeight = 0
    self.volume = min(max(Int((volume * 100).rounded()), 0), 100)
    mutedValue = muted
    self.speed = speed
    self.aspect = aspect
    _ = player
    loadItem(at: self.index, autoplay: autoplay)
    applyVolume()
    startTicking()
    emitState()
    emitTracks()
    return true
  }

  private func loadItem(at index: Int, autoplay: Bool) {
    guard let player = player, index >= 0, index < urls.count else { return }
    // ★ r675（`DA304`）：`URL(string:)` 对**未转义**的 URL 返回 nil —— 文件名里
    //   有空格（`Citizen Kane (1941).mkv`）或中文（`60招基础街球S01E01.AVI`）时
    //   就是这样。旧代码 `guard ... else { return }` **静默返回**：既不换条目、
    //   也不报错 ⇒ 上一支视频继续播、新页面顶着它的标题和进度（r675 真机三张
    //   截图一模一样，全是上一支 mp4 的 `00:03/10:12`）。
    //   现在：先按"整条串"转义一次；再不行就当成**明确的播放错误**上报
    //   （Dart 侧走既有「编码不支持/播放失败」回退面板），绝不允许静默。
    let raw = urls[index]
    let url = URL(string: raw)
      ?? URL(string: raw.addingPercentEncoding(
        withAllowedCharacters: .urlFragmentAllowed) ?? raw)
    guard let url = url else {
      lastError = "invalid-url: cannot build URL from the given media source"
      NSLogDiag("%@ 载入失败：URL 不合法 %@", Self.tag, raw)
      emitState()
      return
    }
    teardownItemObservers()
    texture?.unbind()
    // 与 Kotlin `onMediaItemTransition` 对齐：换条目先清字幕文本，
    // 否则会短暂显示上一条的字幕（首次 load 也发，语义与 ExoPlayer 一致）
    send(["kind": "cues", "text": ""])

    let asset: AVURLAsset
    if MediaTlsPolicy.shared.needsProxy(url), let proxied = MediaTlsPolicy.proxyURL(url) {
      asset = AVURLAsset(url: proxied)
      // 自定义 scheme 才会回调这个 delegate（AVFoundation 唯一可拦截的口子）
      let loader = MediaResourceLoader()
      loader.onFailure = { [weak self] message in
        guard let self = self else { return }
        // 传输层能说清原因（TLS 拒绝 / HTTP 状态 / 网络错）时**以它为准**，
        // 别让用户只看到 AVFoundation 的通用 -11800（那会被分类成"解码失败"）
        self.lastError = message
        self.emitState()
      }
      resourceLoader = loader
      asset.resourceLoader.setDelegate(
        loader, queue: DispatchQueue(label: "synhub.player.resource"))
    } else {
      asset = AVURLAsset(url: url)
      resourceLoader = nil
    }
    let item = AVPlayerItem(asset: asset)
    // ★ r689：给这一条装**频谱 tap**（`ios/Runner/AudioVisualizerBridge.swift`）。
    //   必须在**起播前**赋 `audioMix`（AVFoundation 只在装载时读一次），所以挂在
    //   item 刚建出来的位置、而不是 Dart 调 `attach` 的时候。
    //   没人看频谱时 process 回调只把音频原样交回去（不做 FFT）⇒ CPU 代价≈0。
    //   `SpectrumHub` 只被 iOS 的 `AudioVisualizerBridge` 用 —— **它是 iOS 目标的
    //   符号**（`ios/Runner/AudioVisualizerBridge.swift`），macOS 目标里根本没有这个类。
    //   ★ D31（r715）：这里原来无条件调用 ⇒ **macOS 一编译就报
    //   `cannot find 'SpectrumHub' in scope`**，整个 macOS 构建红（r689 合入后
    //   再没人重建过 macOS，所以一直到 r715 才被 `tool/r131_macos_audit.sh` 撞出来）。
    #if os(iOS)
    SpectrumHub.shared.installTapIfNeeded(on: item)
    #endif
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ])
    item.add(output)
    if let tex = texture { tex.bind(item: item, output: output) }

    // 内封字幕文本（Android 是 Media3 `onCues`）
    let legible = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
    let delegate = LegibleDelegate { [weak self] text in
      self?.send(["kind": "cues", "text": text])
    }
    legible.setDelegate(delegate, queue: DispatchQueue.main)
    item.add(legible)
    legibleOutput = legible
    legibleDelegate = delegate

    statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
      guard let self = self else { return }
      switch item.status {
      case .readyToPlay:
        self.applyVideoSizeFromItem()
        self.emitState()
        self.emitTracks()
      case .failed:
        self.lastError = MediaPlayerError.describe(
          item.error ?? MediaPlayerError.plain("unknown AVPlayerItem failure"))
        NSLogDiag("%@ 播放失败：%@", Self.tag, self.lastError ?? "")
        self.emitState()
      default:
        self.emitState()
      }
    }
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] _, _ in
      self?.emitState()
    }
    bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) {
      [weak self] _, _ in
      self?.emitState()
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] note in
      guard let self = self, let finished = note.object as? AVPlayerItem,
        finished === self.player?.currentItem
      else { return }
      if self.index + 1 < self.urls.count {
        // 与 ExoPlayer 的默认自动续播一致：播完自动下一条（Dart 侧据此走
        // "自动续播"的看门狗分支）
        self.index += 1
        self.firstFrameRendered = false
        self.videoWidth = 0
        self.videoHeight = 0
        self.ended = false
        self.loadItem(at: self.index, autoplay: self.playIntent)
        self.emitState()
        self.emitTracks()
      } else {
        self.ended = true
        self.emitState()
      }
    }
    failObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
    ) { [weak self] note in
      guard let self = self else { return }
      let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
      self.lastError = MediaPlayerError.describe(
        error ?? MediaPlayerError.plain("playback failed to end"))
      NSLogDiag("%@ 播放失败：%@", Self.tag, self.lastError ?? "")
      self.emitState()
    }

    player.replaceCurrentItem(with: item)
    ended = false
    if autoplay {
      playIntent = true
      player.playImmediately(atRate: Float(speed))
    } else {
      playIntent = false
      player.pause()
    }
    NSLogDiag("%@ 载入 media[%d] %@", Self.tag, index, Self.describeURL(url))
  }

  private func teardownItemObservers() {
    statusObservation?.invalidate()
    statusObservation = nil
    timeControlObservation?.invalidate()
    timeControlObservation = nil
    bufferEmptyObservation?.invalidate()
    bufferEmptyObservation = nil
    if let o = endObserver { NotificationCenter.default.removeObserver(o) }
    endObserver = nil
    if let o = failObserver { NotificationCenter.default.removeObserver(o) }
    failObserver = nil
    legibleOutput = nil
    legibleDelegate = nil
    resourceLoader = nil
  }

  /// 只读的取流诊断：白名单查询参数 + `_sid`/`SynoToken` 的**有无**（绝不含凭据）。
  private static let diagnosticParams = [
    "api", "method", "version", "id", "type", "quality", "unit_id", "item_id", "size",
    "cache_key", "use_mov", "mode",
  ]

  private static func describeURL(_ url: URL) -> String {
    var parts: [String] = []
    let last = (url.path as NSString).lastPathComponent
    if !last.isEmpty { parts.append("path=\(last)") }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    var map: [String: String] = [:]
    for item in items { map[item.name] = item.value ?? "" }
    for key in diagnosticParams {
      if let v = map[key] { parts.append("\(key)=\(v)") }
    }
    parts.append("sid=" + ((map["_sid"]?.isEmpty == false) ? "yes" : "no"))
    parts.append("token=" + ((map["SynoToken"]?.isEmpty == false) ? "yes" : "no"))
    return parts.joined(separator: " ")
  }

  // MARK: 播放控制

  private func applyVolume() {
    player?.isMuted = mutedValue
    player?.volume = mutedValue ? 0 : Float(volume) / 100
  }

  private func seekTo(ms: Int64) {
    guard let player = player else { return }
    var target = ms
    if target < 0 { target = 0 }
    if let total = durationMs(), total > 0 && target > total { target = total }
    ended = false
    player.seek(
      to: CMTime(value: CMTimeValue(target), timescale: 1000),
      toleranceBefore: .zero, toleranceAfter: .zero)
    emitState()
  }

  private func step(delta: Int) {
    let target = index + delta
    guard target >= 0, target < urls.count else { return }
    index = target
    firstFrameRendered = false
    videoWidth = 0
    videoHeight = 0
    lastError = nil
    ended = false
    loadItem(at: index, autoplay: playIntent)
    emitState()
    emitTracks()
  }

  private func handleNewFrame(width: Int, height: Int) {
    var changed = false
    if !firstFrameRendered {
      firstFrameRendered = true
      changed = true
    }
    if width > 0, height > 0, width != videoWidth || height != videoHeight {
      videoWidth = width
      videoHeight = height
      changed = true
    }
    if changed { emitState() }
  }

  private func applyVideoSizeFromItem() {
    guard let size = player?.currentItem?.presentationSize, size.width > 0, size.height > 0
    else { return }
    let w = Int(size.width.rounded())
    let h = Int(size.height.rounded())
    if w > 0, h > 0, w != videoWidth || h != videoHeight {
      videoWidth = w
      videoHeight = h
      emitState()
    }
  }

  // MARK: 轨道

  private func selectTrack(kind: String, id: String?) {
    guard let item = player?.currentItem else { return }
    let characteristic: AVMediaCharacteristic = kind == "subtitle" ? .legible : .audible
    guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
    else { return }
    if id == nil || id?.isEmpty == true {
      item.select(nil, in: group)
      emitTracks()
      return
    }
    guard let option = selectionOption(group: group, id: id!) else { return }
    item.select(option, in: group)
    emitTracks()
  }

  private func selectionOption(group: AVMediaSelectionGroup, id: String) -> AVMediaSelectionOption? {
    // id 形状：`audio:<group>:<index>`（与 Kotlin 一致）；group 对 AVFoundation
    // 恒为 0（每种 characteristic 只有一个 group），但只要 index 对得上就认。
    let parts = id.split(separator: ":")
    guard parts.count == 3, let idx = Int(parts[2]), idx >= 0, idx < group.options.count
    else { return nil }
    return group.options[idx]
  }

  private func emitTracks() {
    guard let item = player?.currentItem else {
      // ★ r676（`DA306`）：轨道事件也带代数（单例桥的旧事件可能晚到）
      send(["kind": "tracks", "audio": [], "subtitle": [], "generation": generation])
      return
    }
    let audio = trackMaps(item: item, characteristic: .audible, kind: "audio")
    let subtitle = trackMaps(item: item, characteristic: .legible, kind: "subtitle")
    send([
      "kind": "tracks", "audio": audio, "subtitle": subtitle,
      "generation": generation,
    ])
  }

  private func trackMaps(item: AVPlayerItem, characteristic: AVMediaCharacteristic, kind: String)
    -> [[String: Any]]
  {
    guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
    else { return [] }
    let selected = item.currentMediaSelection.selectedMediaOption(in: group)
    var out: [[String: Any]] = []
    for (i, option) in group.options.enumerated() {
      out.append([
        "id": "\(kind):0:\(i)",
        "kind": kind,
        "label": option.displayName,
        "language": option.locale?.identifier ?? "",
        // AVFoundation 的 AVMediaSelectionOption 不暴露 codec 串 / 声道数
        "codec": "",
        "channels": 0,
        "default": option == group.defaultOption,
        "selected": option == selected,
        "group": 0,
        "index": i,
      ])
    }
    return out
  }

  // MARK: 事件

  private func startTicking() {
    stopTicking()
    let t = Timer(timeInterval: Double(Self.tickMs) / 1000.0, repeats: true) { [weak self] _ in
      self?.emitState()
    }
    RunLoop.main.add(t, forMode: .common)
    tickTimer = t
  }

  private func stopTicking() {
    tickTimer?.invalidate()
    tickTimer = nil
  }

  private func durationMs() -> Int64? {
    guard let d = player?.currentItem?.duration, d.isNumeric else { return nil }
    let seconds = CMTimeGetSeconds(d)
    guard seconds.isFinite, seconds > 0 else { return nil }
    return Int64((seconds * 1000).rounded())
  }

  private var buffering: Bool {
    guard let item = player?.currentItem else { return false }
    if player?.timeControlStatus == .waitingToPlayAtSpecifiedRate { return true }
    return item.isPlaybackBufferEmpty
  }

  private func emitState() {
    guard sink != nil else { return }
    let positionMs: Int64 = {
      guard let t = player?.currentTime(), t.isNumeric else { return 0 }
      let s = CMTimeGetSeconds(t)
      guard s.isFinite, s >= 0 else { return 0 }
      return Int64((s * 1000).rounded())
    }()
    let ready = player?.currentItem?.status == .readyToPlay
    let playing = player?.timeControlStatus == .playing
    send([
      "kind": "state",
      "positionMs": positionMs,
      "durationMs": durationMs() ?? 0,
      "playing": playing,
      "ready": ready,
      "buffering": buffering,
      "ended": ended,
      "index": index,
      "count": urls.count,
      "volume": volume,
      "muted": mutedValue,
      "speed": speed,
      "aspect": aspect,
      "videoWidth": videoWidth,
      "videoHeight": videoHeight,
      "firstFrame": firstFrameRendered,
      "error": lastError ?? "",
      "generation": generation,
    ])
  }

  private func send(_ payload: [String: Any]) {
    let sink = self.sink
    guard let sink = sink else { return }
    if Thread.isMainThread {
      sink(payload)
    } else {
      DispatchQueue.main.async { sink(payload) }
    }
  }
}

/// `AVPlayerItemLegibleOutput` 的 delegate：把内封字幕的 `NSAttributedString`
/// 拍平成一段文本（形状与 Kotlin 的 `emitCues` 一致：多个 cue 用 `\n` 连）。
private final class LegibleDelegate: NSObject, AVPlayerItemLegibleOutputPushDelegate {
  private let onText: (String) -> Void
  init(onText: @escaping (String) -> Void) {
    self.onText = onText
    super.init()
  }

  func legibleOutput(
    _ output: AVPlayerItemLegibleOutput,
    didOutputAttributedStrings strings: [NSAttributedString],
    nativeSampleBuffers: [Any],
    forItemTime itemTime: CMTime
  ) {
    let text = strings.map { $0.string }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n")
    onText(text)
  }
}
