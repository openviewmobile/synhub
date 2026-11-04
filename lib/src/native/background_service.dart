// Phase 8：Dart ↔ 原生「通知 + 前台服务」通道。
//
// 原生实现在 `android/app/src/main/kotlin/com/openviewai/synhub/`：
//   `ChatForegroundService`（保活）、`ChatNotifications`（通知与动作）、
//   `BackgroundBridge`（MethodChannel）。
//
// 这里是薄封装 + **可注入**（测试里塞一个假 Channel 就能验证发出去的参数形状），
// 非 Android 平台（macOS 单测、桌面端）统一降级成 no-op，不抛异常。
import 'dart:io';

import '../core/i18n/l10n.dart';
import '../core/platform/app_platform.dart';
import '../core/platform/desktop_notify_linux.dart';
import '../core/platform/desktop_notify_windows.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 原生通知动作（回传方向）
class NotificationAction {
  const NotificationAction({
    required this.action,
    required this.channelId,
    required this.postId,
    this.text = '',
  });

  /// `reply` / `markRead` / `snooze`
  final String action;
  final int channelId;
  final int postId;
  final String text;

  static const reply = 'reply';
  static const markRead = 'markRead';
  static const snooze = 'snooze';

  static NotificationAction? tryParse(Object? raw) {
    final map = switch (raw) {
      final Map m => m,
      _ => null,
    };
    if (map == null) return null;
    final rawAction = '${map['action'] ?? ''}';
    const names = {
      'com.openviewai.synhub.REPLY': reply,
      'com.openviewai.synhub.MARK_READ': markRead,
      'com.openviewai.synhub.SNOOZE': snooze,
      reply: reply,
      markRead: markRead,
      snooze: snooze,
    };
    final action = names[rawAction];
    if (action == null) return null;
    return NotificationAction(
      action: action,
      channelId: _int(map['channelId']),
      postId: _int(map['postId']),
      text: '${map['text'] ?? ''}',
    );
  }

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }
}

/// 一条待展示的消息通知（正文**已经在 Dart 侧解好密**）
class MessageNotification {
  const MessageNotification({
    required this.channelId,
    required this.postId,
    required this.title,
    required this.text,
    this.threadId = 0,
    this.lines = const <String>[],
    this.canReply = true,
  });

  final int channelId;
  final int postId;
  final String title;
  final String text;

  /// 话题 id（非话题消息为 0）。
  /// 原版的通知是**按 (频道, 话题) 聚合成一条**的（`NotificationTag`）。
  final int threadId;

  /// 聚合摘要里的明细行（旧→新，最多 5 条，原版 `InboxStyle.addLine`）
  final List<String> lines;

  /// 加密频道锁着时不给「回复」按钮（回不了密文）
  final bool canReply;

  /// 通知 id：与原版 `NotificationTag.getId()` 完全一致
  int get notificationId => notificationIdFor(channelId, threadId);

  /// 通知 tag：与原版 `NotificationTag.getName()` 完全一致（Gson 序列化）
  String get tag => notificationTagFor(channelId, threadId);

  Map<String, Object?> toMap() => {
    'channelId': channelId,
    'postId': postId,
    'threadId': threadId,
    'notificationId': notificationId,
    'tag': tag,
    'title': title,
    'text': text,
    'lines': lines,
    'canReply': canReply,
  };
}

/// 原版 `NotificationTag.getId()`：
/// `HashCodeBuilder(17, 31).append(channelId).append(threadId).toHashCode()`
/// （Apache commons：`total = total * 31 + value`；long 先做 `v ^ (v >>> 32)`）
int notificationIdFor(int channelId, int threadId) {
  int total = 17;
  total = _mul31(total) + _signed32(channelId);
  total = _mul31(total) + _signed32(threadId ^ (threadId >>> 32));
  return _signed32(total);
}

/// Windows 的通知组名（= 频道）：让"整个频道已读"能一次撤干净。
///
/// 用 `ch<频道号>` 而不是裸数字，是为了在**开发者自己**用 PowerShell 排查时一眼看懂
/// （`History.RemoveGroup('ch271', <aumid>)`）。
String windowsNotificationGroupFor(int channelId) => 'ch$channelId';

/// 原版 `NotificationTag.getName()`：`{"channel_id":N,"thread_id":T}`
String notificationTagFor(int channelId, int threadId) =>
    '{"channel_id":$channelId,"thread_id":$threadId}';

/// Java int 溢出语义（Dart 的 int 是 64 位）
int _mul31(int v) => _signed32(v * 31);

int _signed32(int v) {
  final u = v & 0xFFFFFFFF;
  return u >= 0x80000000 ? u - 0x100000000 : u;
}

class BackgroundService {
  BackgroundService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'synhub/background';

  final MethodChannel _channel;

  /// 原生→Dart 的通知动作回调（`setActionHandler` 注册）
  void Function(NotificationAction action)? _onAction;

  /// 只有 Android 有原生实现；其它平台全部降级。
  ///
  /// 还要确认 Flutter binding 在（纯 Dart 单测里没有 binding，`invokeMethod`
  /// 会直接抛断言 —— 那种环境下必须当"不支持"处理）。
  bool get isSupported {
    // 第 55 轮：`synhub/background` 只有 Android 侧实现 ⇒ 走能力层。
    // ⚠️ 旧写法 `defaultTargetPlatform != TargetPlatform.android` 在
    // `flutter test` 里恒为 false（测试绑定把 defaultTargetPlatform 固定成
    // android）⇒ 单测中它曾"支持"；能力层看的是**真宿主**（测试里 = macos）
    // ⇒ 单测里 `isSupported == false`，提醒因此走前台 Timer 回落。
    // 这在真机上语义不变（Android=true / 桌面=false），差别只在测试宿主，
    // 已在 `test/chat_global_panel_test.dart` 显式 dispose 容器收尾。
    if (!capabilityGateAllows(AppCapability.backgroundExecution)) return false;
    try {
      ServicesBinding.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 原生→Dart 的"后台刷新机会"回调（iOS `BGAppRefreshTask` 的 handler）
  void Function(String taskId)? _onRefresh;

  void setActionHandler(void Function(NotificationAction action) handler) {
    _onAction = handler;
    if (!isSupported) return;
    try {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onBackgroundRefresh') {
          final args = call.arguments;
          final taskId = args is Map ? (args['taskId'] as String? ?? '') : '';
          _onRefresh?.call(taskId);
          return null;
        }
        if (call.method != 'onNotificationAction') return null;
        final action = NotificationAction.tryParse(call.arguments);
        if (action != null) _onAction?.call(action);
        return null;
      });
    } catch (_) {
      // 没 messenger（未初始化 binding）：收不到原生动作，不影响其它功能
    }
  }

  /// 注册"后台刷新机会"回调（iOS 专有；其它平台不会触发）
  void setRefreshHandler(void Function(String taskId) handler) {
    _onRefresh = handler;
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // 原生侧没接上（比如跑在不含新代码的旧 APK 上）：不致命
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      // binding 没初始化之类的环境问题
      return null;
    }
  }

  /// 拉起前台常驻服务（保持 socket）
  Future<bool> start({String? title, String? text}) async =>
      await _invoke<bool>('startService', {
        'title': title ?? platformAppName(),
        'text': text ?? platformText().keepAliveText,
      }) ??
      false;

  Future<bool> stop() async => await _invoke<bool>('stopService') ?? false;

  Future<bool> isRunning() async =>
      await _invoke<bool>('isServiceRunning') ?? false;

  Future<bool> show(MessageNotification notification) async {
    // ★ r693：Linux 走 **桌面通知**（`org.freedesktop.Notifications`）。
    //   以前这里是裸 MethodChannel ⇒ Linux 上没有实现，永远 `false`
    //   （面板上"发送测试通知"必然报"没发出去"）。现在真发：
    //   `notify-send` 把消息交给会话总线的通知守护进程。
    //   缺客户端时 [LinuxDesktopNotifier.show] 返回 false，**不假装成功**。
    if (!kIsWeb && Platform.isLinux) {
      return const LinuxDesktopNotifier().show(
        title: notification.title,
        body: notification.text,
        appName: platformAppName(),
      );
    }
    // ★ r709：Windows 走 **WinRT toast**（`desktop_notify_windows.dart`）。
    //   以前这里同样是裸 MethodChannel ⇒ Windows 上永远 `false`。
    //   AUMID 推导不出来（免安装 dev 版）时 [WindowsDesktopNotifier.show]
    //   返回 false，**不假装成功**。
    if (!kIsWeb && Platform.isWindows) {
      // ★ r710：把 Android 的 identity `(tag, id)` 映射到 Windows 的
      //   `(Tag, Group)`：Tag = 原版 `NotificationTag.getName()`
      //   （`{"channel_id":N,"thread_id":T}`），Group = 频道 ⇒
      //   `cancelTag` / `cancelChannel` 才**撤得掉具体那一条**。
      return const WindowsDesktopNotifier().show(
        title: notification.title,
        body: notification.text,
        appName: platformAppName(),
        tag: notification.tag,
        group: windowsNotificationGroupFor(notification.channelId),
      );
    }
    return await _invoke<bool>('showMessage', notification.toMap()) ?? false;
  }

  Future<bool> cancel(int postId) async {
    // ★ r710：Windows 上**做不到**（如实 false，不假装）：toast 的 identity 是
    //   `(Tag, Group)`，而这里只有 postId（Android 用 `NotificationManager.cancel(id)`，
    //   那个 id 是 `notificationIdFor(channel, thread)` 的哈希）。要按 postId 撤，
    //   得先建一张 postId→(tag,group) 的内存表；目前没有调用方需要，故不建。
    return await _invoke<bool>('cancelMessage', {'postId': postId}) ?? false;
  }

  /// 撤掉某个 (频道, 话题) 的通知（原版 `NotificationHelper.cancelNotification(tag)`）
  Future<bool> cancelTag(int channelId, {int threadId = 0}) async {
    // ★ r710：Windows 按 `(Tag, Group)` 撤（`History.Remove`）。
    if (!kIsWeb && Platform.isWindows) {
      return const WindowsDesktopNotifier().remove(
        tag: notificationTagFor(channelId, threadId),
        group: windowsNotificationGroupFor(channelId),
      );
    }
    return await _invoke<bool>('cancelTag', {
          'channelId': channelId,
          'threadId': threadId,
          'notificationId': notificationIdFor(channelId, threadId),
          'tag': notificationTagFor(channelId, threadId),
        }) ??
        false;
  }

  /// 撤掉整个频道的通知（所有话题）——"这个频道已读"就用它
  Future<bool> cancelChannel(int channelId) async {
    // ★ r710：Windows 撤整组（`History.RemoveGroup`）。
    if (!kIsWeb && Platform.isWindows) {
      return const WindowsDesktopNotifier().remove(
        group: windowsNotificationGroupFor(channelId),
      );
    }
    return await _invoke<bool>('cancelChannel', {'channelId': channelId}) ??
        false;
  }

  Future<bool> cancelAll() async {
    // ★ r693：Linux 交给通知守护进程（`dunstctl close-all`）；没有就返回 false。
    if (!kIsWeb && Platform.isLinux) {
      return const LinuxDesktopNotifier().clearAll();
    }
    if (!kIsWeb && Platform.isWindows) {
      return const WindowsDesktopNotifier().clearAll();
    }
    return await _invoke<bool>('cancelAll') ?? false;
  }

  /// 当前挂着的通知条数（集成测试用）
  Future<int> activeCount() async =>
      await _invoke<int>('notificationCount') ?? 0;

  /// 当前挂着的通知明细（集成测试用：验"同频道只一条 + InboxStyle 明细"）
  Future<
    List<({String tag, int id, String title, String text, List<String> lines})>
  >
  activeTags() async {
    final raw = await _invoke<List<Object?>>('notificationTags') ?? const [];
    return raw.map((e) {
      final m = (e as Map).cast<String, Object?>();
      return (
        tag: (m['tag'] as String?) ?? '',
        id: (m['id'] as num?)?.toInt() ?? 0,
        title: (m['title'] as String?) ?? '',
        text: (m['text'] as String?) ?? '',
        lines: ((m['lines'] as List?) ?? const [])
            .map((x) => x.toString())
            .toList(),
      );
    }).toList();
  }

  /// Android 13+ 的 POST_NOTIFICATIONS 运行时权限（原生侧弹系统框）
  Future<bool> requestNotificationPermission() async =>
      await _invoke<bool>('requestNotificationPermission') ?? false;

  /// 开机自启开关（原生 SharedPreferences）
  Future<bool> setAutostart({
    required bool boot,
    bool foreground = false,
  }) async =>
      await _invoke<bool>('setAutostart', {
        'boot': boot,
        'foreground': foreground,
      }) ??
      false;

  // ── r682：iOS 专有（Android 侧 `notImplemented` ⇒ 这里回 null/false） ──
  //
  // iOS 没有前置服务，`start()` 开的是**后台执行窗口**（约 30 s）。这三条让
  // 报告/集成测试能看清"窗口在不在""任务提交成功没有"，而不是把 `start()==true`
  // 读成"常驻保活成功"。

  /// `{active, startedAt, kind}`；iOS 之外恒 `null`。
  Future<Map<Object?, Object?>?> keepAliveStatus() async =>
      await _invoke<Map<Object?, Object?>>('keepAliveStatus');

  /// 提交一次 `BGAppRefreshTask`（iOS 技能；Android 侧无此方法）。
  Future<bool> scheduleRefresh({int afterSeconds = 900}) async =>
      await _invoke<bool>('scheduleRefresh', {'afterSeconds': afterSeconds}) ??
      false;

  /// 最近一次 `scheduleRefresh` 的**系统**错误（`domain:code`，成功为空串）。
  Future<String?> lastScheduleError() async =>
      await _invoke<String>('lastScheduleError');

  /// 后台刷新任务**真的被唤起过几次**（r685，iOS 专有，持久化在 UserDefaults）。
  ///
  /// 为什么要有它：模拟器上 `submit` 会被系统拒，通知授权也点不了；唯一能
  /// 证明"handler 真跑了"的就是这份计数（配合 Xcode 的
  /// `_simulateLaunchForTaskWithIdentifier` 强制唤起）。
  Future<({int fired, double lastAt, String lastTaskId})> refreshStats() async {
    final raw = await _invoke<Map<Object?, Object?>>('refreshStats');
    return (
      fired: (raw?['fired'] as num?)?.toInt() ?? 0,
      lastAt: (raw?['lastAt'] as num?)?.toDouble() ?? 0,
      lastTaskId: (raw?['lastTaskId'] as String?) ?? '',
    );
  }

  /// 已提交但还没跑的后台刷新请求（iOS 专有）。
  Future<List<Object?>> pendingTaskRequests() async =>
      await _invoke<List<Object?>>('pendingTaskRequests') ?? const [];

  /// 通知授权状态原始值：0 notDetermined / 1 denied / 2 authorized /
  /// 3 provisional / 4 ephemeral（iOS 专有）。
  Future<int?> notificationAuthorizationStatus() async =>
      await _invoke<int>('notificationAuthorizationStatus');

  Future<({bool boot, bool foreground})> getAutostart() async {
    final raw = await _invoke<Map<Object?, Object?>>('getAutostart');
    return (boot: raw?['boot'] == true, foreground: raw?['foreground'] == true);
  }
}
