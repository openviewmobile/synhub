// r688：**小组件点击的 scene 入口**（`synhubwidget://`）。
//
// ## 为什么需要这个类（实测过的坑，不是"以防万一"）
//
// 本 App 是 UIScene 架构（`Info.plist` 的 `UISceneDelegateClassName` 原本是
// Flutter 的 `FlutterSceneDelegate`）。按 Flutter 的设计，插件只要
// `registrar.addSceneDelegate(x)` 就能收到 `scene(_:openURLContexts:)` ——
// `ios/Runner/DeepLinkBridge.swift` 就是这么接 `synochat://` 的。
//
// r688 现场实测：**App 已在运行时 `xcrun simctl openurl …` 打进 `synhubwidget://`
// 和 `synochat://?…`，两条都没进到任何插件**（`log show --predicate 'process ==
// "Runner"'` 里既没有 `[widget]` 也没有 `[deeplink]` 的 `openURLContexts` 行；
// 系统侧 `lsd` 明确记录了 "Opening URL … with com.openviewai.synhub.ios"）。
// 冷启动那条（URL 挂在 `UISceneConnectionOptions` 上）反而正常。
//
// 也就是说"warm 深链"这一路在当前 Flutter 版本 + 隐式引擎组合下**静默不通**。
// 小组件的点击恰恰**几乎总是 warm**（用户在桌面点小组件时 App 多半在后台）⇒
// 不能指望 Flutter 的转发，必须自己接管 scene delegate：
//
//   * 本类子类化 `FlutterSceneDelegate`，只**多**做一件事：先看是不是
//     `synhubwidget://`，是就交给 `WidgetBridge.shared.handleWidgetURL`，
//     **不**再往下传（避免同一条 URL 被当成聊天深链）；
//   * 其余 URL（`synochat://` 等）**原样交回 `super`**，所以既有的深链行为
//     一点没改；
//   * 冷启动的 `willConnectTo` 同样先过一遍小组件 scheme。
//
// 这一层是"显式路由表"，与 Android 侧用**专用 action**（`ACTION_OPEN`）而不是
// 蹭 `synochat://` 是同一条设计：谁的地盘谁解析。

import Flutter
import UIKit

final class SynHubSceneDelegate: FlutterSceneDelegate {
  /// App 已在运行（前台/后台）时被点开。
  override func scene(
    _ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    var rest = Set<UIOpenURLContext>()
    for ctx in URLContexts {
      if WidgetBridge.shared.handleWidgetURL(ctx.url) { continue }
      rest.insert(ctx)
    }
    if !rest.isEmpty {
      super.scene(scene, openURLContexts: rest)
    }
  }

  /// 冷启动：URL 挂在连接选项上（小组件点击把 App 从**未运行**拉起来走这条）。
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    for ctx in connectionOptions.urlContexts where handleOnlyWidget(ctx.url) {}
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  /// 只吃小组件 scheme，别的**不动**（不能把 `synochat://` 的冷启动吃掉）。
  private func handleOnlyWidget(_ url: URL) -> Bool {
    WidgetBridge.shared.handleWidgetURL(url)
  }
}
