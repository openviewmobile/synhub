// `synhub/background` 的 **iOS 实现**（r682）。
//
// Android 那一份是「前台服务保活 + 通知栏（含回复/已读/贪睡动作）」；
// iOS **没有**前台服务这回事，所以这里逐条给出**语义等价物**，并把差异写在
// 方法注释里 —— 不许用"iOS 做不到"糊过去，也不许把"调度成功"说成"已经跑过"。
//
// | Dart 方法 | iOS 实现 | 诚实边界 |
// |---|---|---|
// | `startService` | `UIApplication.beginBackgroundTask` 开一个**后台执行窗口**（约 30 s），到点由系统回调收掉 | 这不是常驻服务：窗口结束 App 就挂起（聊天靠重连，不靠常驻） |
// | `stopService` | `endBackgroundTask` | — |
// | `isServiceRunning` | 窗口是否还活着 | 只说明"窗口在"，不说明 socket 在 |
// | `scheduleRefresh` / `pendingTaskRequests` | `BGTaskScheduler` 的 `BGAppRefreshTaskRequest` | **提交成功 ≠ 系统会跑**：iOS 按使用习惯决定；模拟器上无法触发（要 LLDB `_simulateLaunchForTaskWithIdentifier`） |
// | `showMessage` / `cancel*` / `notificationTags` / `notificationCount` | `UNUserNotificationCenter`（本地通知；`threadIdentifier` = Dart 算好的 tag） | 没有通知授权时 **`showMessage` 如实返回 false**（不假装挂上了） |
// | `requestNotificationPermission` | `requestAuthorization`（真实系统弹框） | 无头模拟器点不了弹框 ⇒ 自动化只验"未授权时如实失败" |
// | `setAutostart` / `getAutostart` | `UserDefaults` | iOS **没有**开机自启（`boot` 位只为与 Dart 契约同形，读了也不生效） |
//
// 通知动作（回复/已读/贪睡）通过 `UNUserNotificationCenterDelegate` 回到 Dart 的
// `onNotificationAction` —— 与 Android 的 `BroadcastReceiver` 同一份 Dart 处理。
import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// 后台刷新的任务标识（必须与 `Info.plist` 的
/// `BGTaskSchedulerPermittedIdentifiers` 逐字一致，否则 `submit` 直接抛
/// `NSInternalInconsistencyException`）。
let kSynhubRefreshTaskId = "com.openviewai.synhub.refresh"

// r685：后台刷新被唤起的事实（UserDefaults 持久化，进程重启也在）
let kRefreshFiredKey = "synhub.bgRefreshFired"
let kRefreshLastAtKey = "synhub.bgRefreshLastAt"
let kRefreshLastTaskKey = "synhub.bgRefreshLastTask"

@objc(BackgroundBridge)
final class BackgroundBridge: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  static let channelName = "synhub/background"

  /// 强引用单例（r680 的教训：weak 集合会把局部实例释放掉）。
  /// `@objc`：让模拟器上的强制唤起能写成 `[[BackgroundBridge shared] …]`
  /// （Swift 类型默认对 ObjC 不可见，LLDB 的 Swift 表达式又看不到 internal）。
  @objc static let shared = BackgroundBridge()

  private var channel: FlutterMethodChannel?
  /// 后台执行窗口的 token（`UIBackgroundTaskIdentifier`；`.invalid` = 没开）
  private var keepAliveTask: UIBackgroundTaskIdentifier = .invalid
  /// 窗口开始时间（报告用）
  private var keepAliveStartedAt: Date?
  /// 最近一次 `BGTaskScheduler.submit` 的**系统**错误（成功即清空）。
  /// 为什么要留着：模拟器上 `submit` 会被系统拒（`BGTaskSchedulerErrorDomain`），
  /// 把这条读出来才能证明"我们真的调了系统 API，是系统说不"，而不是"忘了接"。
  private var lastScheduleError: String = ""

  // MARK: - 注册

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BackgroundBridge.shared
    let ch = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    instance.channel = ch
    UNUserNotificationCenter.current().delegate = instance
    instance.registerNotificationCategories()
    ch.setMethodCallHandler { [weak instance] call, result in
      guard let instance else {
        result(FlutterMethodNotImplemented)
        return
      }
      instance.dispatch(call, result: result)
    }
  }

  /// ★ 必须在 `didFinishLaunching` **返回之前**调用（Apple 的硬要求：
  /// 任务注册晚于启动完成 ⇒ 系统直接抛异常）。所以 AppDelegate 里单独调它。
  static func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: kSynhubRefreshTaskId, using: nil
    ) { task in
      BackgroundBridge.shared.handleRefreshLaunch(task.identifier)
      task.setTaskCompleted(success: true)
    }
  }

  /// 后台刷新被唤起时的**唯一**处理体（r685 从注册闭包里提出来的）。
  ///
  /// 提出来有两个好处：① 注册闭包只剩一行，读代码就知道"系统唤起 → 走这里"；
  /// ② 模拟器上系统既不肯 `submit` 也不肯 `_simulateLaunch`（因为没有排队
  /// 请求，见 `docs/platform-ios.md` §22 的原始日志），但**这一段**可以用
  /// LLDB 直接调到 —— 于是"如果被唤起，持久计数与 Dart 事件都会发生"这件事
  /// 是可验的，只有"系统会不会唤起"留给真机。
  @objc func handleRefreshLaunch(_ taskId: String) {
    recordRefreshFired(taskId)
    channel?.invokeMethod("onBackgroundRefresh", arguments: ["taskId": taskId])
  }

  private func registerNotificationCategories() {
    func action(_ id: String, _ title: String) -> UNNotificationAction {
      UNNotificationAction(identifier: id, title: title, options: [])
    }
    let reply = UNTextInputNotificationAction(
      identifier: "reply", title: "回复", options: [],
      textInputButtonTitle: "发送", textInputPlaceholder: "输入消息")
    let category = UNNotificationCategory(
      identifier: "synhub_message",
      actions: [reply, action("markRead", "标为已读"), action("snooze", "稍后提醒")],
      intentIdentifiers: [], options: [])
    UNUserNotificationCenter.current().setNotificationCategories([category])
  }

  // MARK: - 方法分发

  // ★ 方法名不能叫 `handle` —— `FlutterPlugin` 协议里有一个同名要求，
  //   Swift 会报"must be as accessible as its enclosing type"。
  private func dispatch(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = (call.arguments as? [String: Any]) ?? [:]
    switch call.method {
    case "startService":
      result(startKeepAlive())
    case "stopService":
      stopKeepAlive()
      result(true)
    case "isServiceRunning":
      result(isKeepAliveActive)
    case "keepAliveStatus":
      // iOS 专有：给报告/设置页说明"这不是常驻服务"
      result([
        "active": isKeepAliveActive,
        "startedAt": keepAliveStartedAt?.timeIntervalSince1970 ?? 0,
        "kind": "background-window",
      ])
    case "scheduleRefresh":
      result(submitRefresh(afterSeconds: (args["afterSeconds"] as? NSNumber)?.doubleValue ?? 900))
    case "lastScheduleError":
      result(lastScheduleError)
    case "refreshStats":
      // r685：后台刷新**真的被唤起过几次**（持久化），诊断/测试用
      let d = UserDefaults.standard
      result([
        "fired": d.integer(forKey: kRefreshFiredKey),
        "lastAt": d.double(forKey: kRefreshLastAtKey),
        "lastTaskId": d.string(forKey: kRefreshLastTaskKey) ?? "",
      ])
    case "pendingTaskRequests":
      BGTaskScheduler.shared.getPendingTaskRequests { requests in
        let list: [[String: Any]] = requests.map { r in
          [
            "identifier": r.identifier,
            "earliestBeginDate": r.earliestBeginDate?.timeIntervalSince1970 ?? 0,
          ]
        }
        DispatchQueue.main.async { result(list) }
      }
    case "showMessage":
      showMessage(args, result: result)
    case "cancelMessage":
      let postId = (args["postId"] as? NSNumber)?.int64Value ?? 0
      cancelWhere { ($0["postId"] as? NSNumber)?.int64Value == postId }
      result(true)
    case "cancelTag":
      let tag = args["tag"] as? String ?? ""
      cancelWhere { ($0["tag"] as? String) == tag }
      result(true)
    case "cancelChannel":
      let channelId = (args["channelId"] as? NSNumber)?.int64Value ?? 0
      cancelWhere { ($0["channelId"] as? NSNumber)?.int64Value == channelId }
      result(true)
    case "cancelAll":
      UNUserNotificationCenter.current().removeAllDeliveredNotifications()
      UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
      result(true)
    case "notificationCount":
      snapshotNotifications { list in result(list.count) }
    case "notificationTags":
      snapshotNotifications { list in result(list) }
    case "notificationAuthorizationStatus":
      UNUserNotificationCenter.current().getNotificationSettings { s in
        DispatchQueue.main.async { result(s.authorizationStatus.rawValue) }
      }
    case "requestNotificationPermission":
      UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .badge, .sound,
      ]) { granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "setAutostart":
      // iOS 没有开机自启：`boot` 只落在偏好里（读到也说明不了什么），
      // `foreground` = "进后台时开保活窗口"的偏好。
      let d = UserDefaults.standard
      d.set(args["boot"] as? Bool ?? false, forKey: "synhub.autostart")
      d.set(args["foreground"] as? Bool ?? false, forKey: "synhub.autostartForeground")
      result(true)
    case "getAutostart":
      let d = UserDefaults.standard
      result([
        "boot": d.bool(forKey: "synhub.autostart"),
        "foreground": d.bool(forKey: "synhub.autostartForeground"),
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 后台执行窗口

  private var isKeepAliveActive: Bool { keepAliveTask != .invalid }

  @discardableResult
  private func startKeepAlive() -> Bool {
    if isKeepAliveActive { return true }
    let app = UIApplication.shared
    // Deferred on purpose: `beginBackgroundTask` 必须在主线程调（UIKit）。
    if !Thread.isMainThread {
      DispatchQueue.main.async { _ = self.startKeepAlive() }
      return true
    }
    keepAliveTask = app.beginBackgroundTask(withName: "synhub-chat-keepalive") {
      // 到点：系统要收窗口了。如实把状态置回"没在保活"，别让界面继续显示保活中。
      NSLog("[bg] 后台窗口到期（系统回收）")
      self.stopKeepAlive()
    }
    keepAliveStartedAt = Date()
    NSLog("[bg] 后台窗口开始 token=\(keepAliveTask.rawValue)")
    return isKeepAliveActive
  }

  private func stopKeepAlive() {
    if keepAliveTask == .invalid { return }
    let token = keepAliveTask
    keepAliveTask = .invalid
    keepAliveStartedAt = nil
    DispatchQueue.main.async {
      UIApplication.shared.endBackgroundTask(token)
    }
    NSLog("[bg] 后台窗口结束 token=\(token.rawValue)")
  }

  /// 记一次"后台刷新任务被唤起"（r685 加的诊断事实）
  func recordRefreshFired(_ taskId: String) {
    let d = UserDefaults.standard
    let n = d.integer(forKey: kRefreshFiredKey) + 1
    d.set(n, forKey: kRefreshFiredKey)
    d.set(Date().timeIntervalSince1970, forKey: kRefreshLastAtKey)
    d.set(taskId, forKey: kRefreshLastTaskKey)
    NSLog("[bg] 后台刷新被唤起 #\(n) task=\(taskId)")
  }

  // MARK: - BGTaskScheduler

  private func submitRefresh(afterSeconds: Double) -> Bool {
    let request = BGAppRefreshTaskRequest(identifier: kSynhubRefreshTaskId)
    request.earliestBeginDate = Date(timeIntervalSinceNow: max(60, afterSeconds))
    do {
      try BGTaskScheduler.shared.submit(request)
      lastScheduleError = ""
      NSLog("[bg] 已提交后台刷新请求 earliest=+\(Int(afterSeconds))s")
      return true
    } catch {
      // 未在 Info.plist 登记 / 系统此刻不允许（模拟器即如此）/ 配额满 ⇒ **如实失败**，
      // 并把系统错误原样留给上层（`lastScheduleError`），不许吞成"成功"。
      let ns = error as NSError
      lastScheduleError = "\(ns.domain):\(ns.code)"
      NSLog("[bg] 提交后台刷新失败: \(error)")
      return false
    }
  }

  // MARK: - 本地通知

  private func showMessage(_ args: [String: Any], result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      guard settings.authorizationStatus == .authorized
        || settings.authorizationStatus == .provisional
      else {
        // ★ 关键：没有授权就**不许**回报成功（Android 上 `NotificationManager`
        //   在同样情形下也是静默丢弃，但我们的 Dart 侧要靠这个 bool 决定要不要
        //   提示用户去开权限）。
        NSLog("[bg] 未授权，通知不挂（status=\(settings.authorizationStatus.rawValue)）")
        DispatchQueue.main.async { result(false) }
        return
      }
      let channelId = (args["channelId"] as? NSNumber)?.int64Value ?? 0
      let postId = (args["postId"] as? NSNumber)?.int64Value ?? 0
      let threadId = (args["threadId"] as? NSNumber)?.int64Value ?? 0
      let title = args["title"] as? String ?? ""
      let text = args["text"] as? String ?? ""
      let tag = args["tag"] as? String ?? ""
      let id = (args["notificationId"] as? NSNumber)?.intValue ?? 0
      let lines = args["lines"] as? [String] ?? []
      let canReply = args["canReply"] as? Bool ?? false

      let content = UNMutableNotificationContent()
      content.title = title
      content.body = lines.isEmpty ? text : ([text] + lines).joined(separator: "\n")
      content.sound = .default
      // iOS 的"同 (频道,话题) 聚成一条"就是 threadIdentifier
      content.threadIdentifier = tag
      content.userInfo = [
        "channelId": channelId, "postId": postId, "threadId": threadId, "tag": tag,
        "lines": lines,
      ]
      if canReply { content.categoryIdentifier = "synhub_message" }

      let request = UNNotificationRequest(
        identifier: "synhub-\(id)", content: content, trigger: nil)
      UNUserNotificationCenter.current().add(request) { error in
        if let error {
          NSLog("[bg] 挂通知失败: \(error)")
        }
        DispatchQueue.main.async { result(error == nil) }
      }
    }
  }

  /// 把 delivered + pending 合成与 Android `notificationTags` 同形的列表。
  private func snapshotNotifications(_ done: @escaping ([[String: Any]]) -> Void) {
    let center = UNUserNotificationCenter.current()
    func describe(_ id: String, _ content: UNNotificationContent) -> [String: Any] {
      let info = content.userInfo as [AnyHashable: Any]
      return [
        "tag": info["tag"] as? String ?? content.threadIdentifier,
        "id": Int(id.replacingOccurrences(of: "synhub-", with: "")) ?? 0,
        "title": content.title,
        "text": content.body,
        "lines": info["lines"] as? [String] ?? [],
      ]
    }
    center.getDeliveredNotifications { delivered in
      center.getPendingNotificationRequests { pending in
        var out = delivered.map { describe($0.request.identifier, $0.request.content) }
        out += pending.map { describe($0.identifier, $0.content) }
        DispatchQueue.main.async { done(out) }
      }
    }
  }

  private func cancelWhere(_ match: @escaping ([AnyHashable: Any]) -> Bool) {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { delivered in
      let ids = delivered.filter { match($0.request.content.userInfo) }
        .map { $0.request.identifier }
      center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    center.getPendingNotificationRequests { pending in
      let ids = pending.filter { match($0.content.userInfo) }.map { $0.identifier }
      center.removePendingNotificationRequests(withIdentifiers: ids)
    }
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// 用户点了通知或动作（含直接回复）
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo as [AnyHashable: Any]
    let map: [String: Any] = [
      "action": response.actionIdentifier == UNNotificationDefaultActionIdentifier
        ? "open" : response.actionIdentifier,
      "channelId": info["channelId"] as? NSNumber ?? 0,
      "postId": info["postId"] as? NSNumber ?? 0,
      "text": (response as? UNTextInputNotificationResponse)?.userText ?? "",
    ]
    channel?.invokeMethod("onNotificationAction", arguments: map)
    completionHandler()
  }

  /// App 在前台时也按普通通知展示（聊天要能"看见"）
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }
}
