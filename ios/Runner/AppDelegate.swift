import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // r682：`BGTaskScheduler` 的任务注册**必须**在启动完成之前做完（Apple 硬要求，
    // 晚于 `didFinishLaunching` 返回再注册 ⇒ 系统直接抛
    // `NSInternalInconsistencyException`）。所以它在方法通道注册之前先跑。
    BackgroundBridge.registerBackgroundTasks()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 隐式引擎起来之后再注册插件与自研桥。
  ///
  /// ★ 为什么是这里（第 92 轮踩过）：Flutter 3.4x 起 iOS 模板迁到
  /// **UIScene + `FlutterImplicitEngineDelegate`**，构造函数里已经**拿不到**
  /// `window?.rootViewController as? FlutterViewController` 那套老写法
  /// （`MainFlutterWindow` 在 iOS 上根本不存在）。`didInitializeImplicitFlutterEngine`
  /// 给的 `engineBridge.pluginRegistry` 就是当前的 `FlutterPluginRegistry`，
  /// 从它 `registrar(forPlugin:)` 拿到的 registrar 与插件用的是同一套
  /// `messenger` / `textures`，因此自研播放器的通道与纹理注册都成立。
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 自研 iOS 原生桥（Swift）—— 与 macOS **同一份源码**
    // （`macos/Runner/MediaPlayerBridge.swift` + `MediaPlayerTransport.swift`，
    //  经 `ios/Runner.xcodeproj/project.pbxproj` 的 `SOURCE_ROOT` 相对路径直接引用）。
    //
    // 它解决的是插件解决不了的那一件事：真 NAS 的证书**链合法但主机名不匹配**
    // （`https://nas.example.com:5001`，`CN=nas.example.com`）⇒
    // AVFoundation 用系统默认校验必报 `-1202`（macOS 已实测，见
    // `docs/platform-macos.md` §3.7.7）。Dart 侧 `DioFactory` 的放宽
    // **不会**传导到原生栈，所以原生侧必须自己按同一套 scoped 政策取流。
    //
    // 注意：**注册 ≠ Dart 会用它**。Dart 侧开关见
    // `MediaTlsPolicy.iosNativePlayerEnabled`
    // （`--dart-define=SYNHUB_IOS_NATIVE_PLAYER=false` 可退回插件）。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubMediaPlayerBridge")
    {
      MediaPlayerBridge.shared.register(with: registrar)
    }

    // r333：「存到本机」的 **A 轨**（用户现选目录）—— `UIDocumentPickerViewController`
    // 的 `.folder` 形态 + 安全作用域。没有这条桥时 iOS 只能落 B 轨
    // （App 容器里的 downloads），而 `file_picker` 的 `getDirectoryPath`
    // 在 iOS 上是 desktop-only ⇒ 光靠插件补不上这个差距。
    // Dart 侧：`lib/src/core/platform/ios_fs_export.dart`；
    // 接线点：`media_store_save.dart` 的 provider（**只在 iOS 宿主**构造）。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubIosFsExport")
    {
      IosFsExportBridge.register(with: registrar)
    }

    // r681：**端侧 AI 的硬件事实**（`synhub/device` 的 iOS 实现）。
    // 这条桥只读（ProcessInfo / sysctl / Metal / URLResourceValues），
    // 给 Dart 侧 `probeDeviceCapability()` 算端侧模型档位用。
    // 之前 iOS 上这个通道没有实现 ⇒ 内存只能读 `/proc`（iOS 不存在）⇒
    // 档位恒 `unknown`；现在读的是真事实（模拟器上要配合 `isSimulator` 看）。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubDeviceCapability")
    {
      DeviceCapabilityBridge.register(with: registrar)
    }

    // r682：**后台执行 + 本地通知**（`synhub/background` 的 iOS 实现）。
    // Android 那份是"前台服务保活 + 通知栏动作"；iOS 语义等价物 =
    // `beginBackgroundTask` 的后台执行窗口 + `UNUserNotificationCenter`
    // （含直接回复/已读/贪睡动作）+ `BGTaskScheduler` 的一次性刷新机会。
    // 逐条差异写在 `ios/Runner/BackgroundBridge.swift` 文件头的表里。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubBackground")
    {
      BackgroundBridge.register(with: registrar)
    }

    // r688：**主屏小组件**（`synhub/widget`）。WidgetKit 扩展是独立进程，
    // 只能读 App Group 的 UserDefaults ⇒ 这里负责把 Dart 的快照写进去，
    // 并用专用 scheme `synhubwidget://` 接小组件点击（细节见文件头三条差异）。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubWidget")
    {
      WidgetBridge.register(with: registrar)
    }

    // r689：**视频抽帧**（`synhub/video_frame`）。Android 是
    // `MediaMetadataRetriever.getFrameAtTime`；iOS 的等价物是
    // `AVAssetImageGenerator.copyCGImage`（零容差 + `maximumSize` 等比缩）。
    // 之前 iOS 没有这份实现 ⇒ 视频列表行永远只有场记板占位图（`DA323`）。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubVideoFrame")
    {
      VideoFrameBridge.register(with: registrar)
    }

    // r689：**网络计数**（`synhub/traffic`）＋ **投屏**（`synhub/cast`）。
    // ★ 两者都是"语义等价物"，不是照抄：
    //   * iOS **没有按 App 的字节计数 API** ⇒ uid 两项如实 -1，只给接口级总和
    //     （Dart 的 `supported` 会因此为 false，"估算档"如实地不可用）；
    //   * 投屏在 iOS 上是 **AirPlay**（`AVRouteDetector` + `AVRoutePickerView`），
    //     没有"把 URL 交给接收端"这一步 ⇒ `play` 只在当前路由真是 AirPlay 时回 true。
    // 逐条差异写在 `ios/Runner/TrafficAndCastBridge.swift` 文件头。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubTrafficAndCast")
    {
      TrafficBridge.register(with: registrar)
      CastBridge.register(with: registrar)
    }

    // r689：**真频谱**（`synhub/audio_visualizer` ＋ `/events`）。
    // iOS 没有 Android 的 playback capture ⇒ 用 **`MTAudioProcessingTap`** 抓
    // 正在播的那一路 PCM（tap 由 `MediaPlayerBridge` 在装载 item 时装上，
    // 这里只负责"开不开水龙头"）。逐条差异见 `AudioVisualizerBridge.swift` 文件头。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubAudioVisualizer")
    {
      AudioVisualizerBridge.register(with: registrar)
    }

    // r687：**系统分享面板**（`synhub/share_text` ＋ `synhub/media_open`）
    // Android 那两条是 `ACTION_SEND` / `ACTION_SEND_MULTIPLE`；iOS 的等价物是
    // `UIActivityViewController`（系统自己给"拷贝/信息/邮件/存储到文件/隔空投送"）。
    // 三条 iOS 特有事实（iPad 必须给 popover 锚点、必须从活着的 VC 呈现、
    // 回调线程不保证）写在 `ios/Runner/ShareBridge.swift` 文件头。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubShare")
    {
      ShareBridge.register(with: registrar)
    }

    // r680：**聊天深链**（`synochat://` 等四条 scheme，`Info.plist` 的
    // `CFBundleURLTypes` 与这里成对，缺一条系统就不会把链接交过来）。
    // 细节（为什么还要 `addSceneDelegate`、冷启动的 URL 在哪）见
    // `ios/Runner/DeepLinkBridge.swift` 文件头。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubDeepLink")
    {
      DeepLinkBridge.register(with: registrar)
    }

// ★ 编译条件用 `targetEnvironment(simulator)` 而不是 `#if DEBUG`：
//   本仓库的 **Runner target 的 Debug 配置并没有定义 `DEBUG`**
//   （`project.pbxproj:518` 的 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`
//   只挂在 **RunnerTests** target 上）⇒ 用 `#if DEBUG` 这段会被**静默编译掉**
//   （r283 实测：通道报 `MissingPluginException`，二进制里 `strings` 也搜不到）。
//   `targetEnvironment(simulator)` 是标准支持的编译条件，且**模拟器产物不会出货**
//   （发布的 iOS 包是 `iphoneos` 构建）⇒ "生产零影响"比 `#if DEBUG` 更硬。
#if targetEnvironment(simulator)
    // ─────────────────────────────── r283：**仅模拟器**的方向测试钩子
    //
    // 为什么需要它（实测）：iPad 上本 App **支持多任务**（Info.plist 没有
    // `UIRequiresFullScreen`）⇒ 按 Apple 的规则，iPadOS **忽略**
    // `supportedInterfaceOrientations` 的方向掩码 ⇒
    // `SystemChrome.setPreferredOrientations` **无法**把 iPad 窗口转过去
    // （r283 实测：请求 landscapeLeft 后 `MediaQuery.size` 仍是 834×1210）。
    // 真旋转只能走 scene 的官方通道 `requestGeometryUpdate`。
    //
    // 通道名带 `test_` 前缀，Dart 侧只有 integration_test 会用。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SynHubTestOrientation")
    {
      let channel = FlutterMethodChannel(
        name: "synhub/test_orientation",
        binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "rotate",
          let args = call.arguments as? [String: Any],
          let mask = args["mask"] as? Int
        else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        else {
          result(FlutterError(code: "no_scene", message: nil, details: nil))
          return
        }
        if #available(iOS 16.0, *) {
          // 成功路径**没有**回调；失败路径有 ⇒ 用一个 once 标志把错误名
          // 原样回给 Dart（否则"转不过去"会被静默当成成功）。
          var finished = false
          func finish(_ body: @escaping () -> Void) {
            if finished { return }
            finished = true
            body()
          }
          // Xcode 27 / iOS 27 SDK 的重命名链（编译器原文，逐级）：
          //   'UIWindowSceneGeometryPreferencesIOS' has been renamed to
          //     'UIWindowSceneGeometryPreferences.iOS'
          //   'UIWindowSceneGeometryPreferences' has been renamed to
          //     'UIWindowScene.GeometryPreferences'
          // ⇒ 最终名是 `UIWindowScene.GeometryPreferences.iOS`
          let prefs = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: UIInterfaceOrientationMask(
              rawValue: UInt(truncatingIfNeeded: mask)))
          for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
          }
          scene.requestGeometryUpdate(prefs) { error in
            NSLog("[r283] requestGeometryUpdate error: \(error)")
            DispatchQueue.main.async {
              finish {
                result(
                  FlutterError(
                    code: "geometry_update_failed",
                    message: error.localizedDescription,
                    details: String(describing: error)))
              }
            }
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            finish { result(true) }
          }
        } else {
          result(false)
        }
      }
    }
#endif
  }
}
