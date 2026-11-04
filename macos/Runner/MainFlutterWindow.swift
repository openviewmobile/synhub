import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // r284：**取证用**窗口尺寸钩子（逻辑点）。两种来源，缺省 ⇒ 行为不变：
    //   ① 环境变量 `SYNHUB_WINDOW_SIZE=1280x860`；
    //   ② 容器内文件 `<home>/tmp/synhub_window_size.txt`（同上格式）。
    //      为什么要有 ②：`flutter test -d macos` 是用 `open`（LaunchServices）
    //      拉起 App 的，**不继承 shell 环境变量** —— r284 实测环境变量那一路
    //      拿到的仍是 800x600（默认窗口）。文件那一路由 `tool/r284_macos_files.sh`
    //      在启动前写好（App 沙箱的 home 就是容器 Data 目录）。
    //
    // 用法/纪律：本机没有 Screen Recording / Accessibility 的 TCC 授权 ⇒
    // `osascript`(System Events) 改不了窗口尺寸、`screencapture` 也拍不了屏，
    // 于是"宽屏双栏 / 窄屏单列"的真像素只能靠**真的把窗口设成那个尺寸**再
    // 用 `RenderRepaintBoundary.toImage()` 自渲染（见
    // `integration_test/r284_macos_files_panes_test.dart` 与 `tool/r284_macos_files.sh`）。
    // 没有任何新通道、没有网络、没有凭据。
    var sizeSpec =
      ProcessInfo.processInfo.environment["SYNHUB_WINDOW_SIZE"] ?? ""
    if sizeSpec.isEmpty {
      let f = (NSHomeDirectory() as NSString)
        .appendingPathComponent("tmp/synhub_window_size.txt")
      sizeSpec =
        ((try? String(contentsOfFile: f, encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var applied = "none"
    if !sizeSpec.isEmpty {
      let parts = sizeSpec.lowercased().split(separator: "x")
      if parts.count == 2,
         let w = Double(parts[0]), let h = Double(parts[1]),
         w >= 200, h >= 200 {
        // 放到下一轮 runloop：`contentViewController` 与 nib 的 frame 都要先落定，
        // 否则会被随后的布局覆盖（r284 实测：在 awakeFromNib 里同步设，
        // Dart 侧读到的仍是 nib 的 800x600）。
        DispatchQueue.main.async {
          self.setContentSize(NSSize(width: w, height: h))
          self.center()
        }
        applied = "\(w)x\(h)"
      }
    }
    // 诊断落点（只读，写在容器 tmp；跑完由 tool/r284_macos_files.sh 打印）
    let dbg = (NSHomeDirectory() as NSString)
      .appendingPathComponent("tmp/r284_window_hook.txt")
    try? "home=\(NSHomeDirectory())\nspec=\(sizeSpec)\napplied=\(applied)\n"
      .write(toFile: dbg, atomically: true, encoding: .utf8)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 自研 macOS 原生桥（Swift；Android 侧对应 Kotlin 的 30 条 `synhub/*` 通道）。
    //
    // 本轮先接媒体播放器（`synhub/player` + `synhub/player_events`）——
    // 它是 macOS 上唯一能播"证书链合法但主机名不匹配"那条真 NAS 流的实现
    // （AVPlayer + `AVAssetResourceLoaderDelegate` + `URLSession` 的 serverTrust
    // 放行，见 `MediaPlayerBridge.swift` 文件头）。
    //
    // 注意：**注册 ≠ Dart 会用它**。Dart 侧默认仍让 macOS 走 `video_player`
    // （未在真 NAS 上验证过播放前不拿用户当小白鼠），开关见
    // `MediaTlsPolicy.macosNativePlayerEnabled` / `--dart-define=SYNHUB_MACOS_NATIVE_PLAYER=true`。
    let registrar = flutterViewController.registrar(forPlugin: "SynHubMediaPlayerBridge")
    MediaPlayerBridge.shared.register(with: registrar)

    // r328（backlog §3.4）：**安全作用域书签** —— "记住用户上次选的保存目录"。
    // 只编进 macOS target ⇒ Dart 侧能力位 `fsBookmark` 只在 macOS 那一行 available，
    // 其余宿主是 `bridge-missing`（如实）。entitlement 见两份 entitlements。
    let bookmarkRegistrar = flutterViewController.registrar(forPlugin: "SynHubFsBookmarkBridge")
    FsBookmarkBridge.shared.register(with: bookmarkRegistrar)

    super.awakeFromNib()
  }
}
