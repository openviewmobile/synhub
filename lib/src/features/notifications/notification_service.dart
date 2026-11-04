// Phase 8：本地通知的**决策与内容**（Dart 侧）。
//
// 分工：
//   * Dart 决定「这条要不要提醒、提醒什么内容」——因为只有 Dart 有本地库、
//     有 E2EE 密钥，能解出加密频道的正文；
//   * 原生（`android/.../ChatNotifications.kt`）只负责画通知和处理动作。
//
// 对应原 App 的 `NotificationActionWorker` + `NotificationHelper`：
//   * 自己发的不提醒；系统事件不提醒；`notification_mute` 的频道不提醒；
//   * 正在看这个频道（且 App 在前台）不提醒；
//   * 加密频道锁着时给「🔒 无法解密」并**不给回复按钮**（回不了密文）；
//   * 动作：回复（走 sendMessage，加密频道自动加密）、已读（markRead）、
//     贪睡（**全局免打扰 1 小时**，与 `NotificationActionWorker.setSnooze` 一致）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_api.dart';
import '../../core/i18n/l10n.dart';
import '../../core/net/network_type.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/server_settings.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/server_settings_dto.dart';
import '../../data/dto/post_dto.dart';
import '../../data/e2ee/e2ee_service.dart';
import '../../native/background_service.dart';
import '../chat/chat_session_controller.dart';
import '../settings/e2ee_controller.dart';
import '../settings/snooze_controller.dart';

/// 通知栏「贪睡」动作的时长：原版 `NotificationActionWorker.setSnooze` 写死 **1 小时**，
/// 而且是调 `AccountManager.setSnooze(1h)`（**全局**免打扰，服务端存），
/// 不是"这条通知 1 小时后再弹一次"。我们照此实现（见 [NotificationService.snooze]）。
const Duration kSnoozeDuration = Duration(minutes: 60);

final backgroundServiceProvider = Provider<BackgroundService>((ref) {
  final service = BackgroundService();
  ref.onDispose(() {
    // 引擎销毁时别再把动作往一个已经没了的 handler 上送
    service.setActionHandler((_) {});
  });
  return service;
});

/// ★ r342 **D45**：常驻服务"在不在跑"必须是**实时查询**，
/// 不许用会话内存里的快照（那会跟系统真实状态不一致）。
///
/// **真机实证**：`adb install -r` 之后系统把上一进程的 `ChatForegroundService`
/// 又拉起来了（`dumpsys activity services` 里明明有 `ServiceRecord`），
/// 而会话快照仍是 `false` ⇒ `设置` 那行显示「前台服务未运行」，**跟系统说的相反**。
/// 快照只在两处更新（socket 就绪时、用户手动拨开关时），所以"服务在跑"这件事
/// 只要不是由这两条路发生的，界面就会说谎。
///
/// 现在**唯一来源**就是这个 provider：页面每次构建都问一次系统；
/// 回到前台时 `invalidate` 再问一次（见两个设置页的 `didChangeAppLifecycleState`）。
final foregroundServiceRunningProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  return ref.watch(backgroundServiceProvider).isRunning();
});

/// 当前网络类型（"预加载消息"的 Wi-Fi 门禁用；测试里覆盖成固定值）
final networkTypeProbeProvider = Provider<NetworkTypeProbe>(
  (ref) => MethodChannelNetworkTypeProbe(),
);

/// 一个 (频道, 话题) 上已提醒消息的聚合状态。
///
/// 原版把通知**按 (频道, 话题) 合成一条**：同一条通知原地更新，
/// 大标题是「N 条新消息 | 频道名」，明细是最新 5 条
/// （`PushNotificationUtils.getInboxStyleAndTitle` + `getFilteredNotificationVoList(5)`）。
class ChannelNotificationAgg {
  ChannelNotificationAgg(this.channelId, this.threadId, this.channelName);

  final int channelId;
  final int threadId;
  final String channelName;

  /// 已累计提醒的条数（原版 `num_new_message` 里的那个 N）
  int count = 0;

  /// 最新 5 条预览（旧 → 新）
  final List<String> lines = <String>[];

  /// InboxStyle 的大标题。
  ///
  /// 通知栏拿不到 widget context → 走 `platformText()`（跟**平台**语言）。
  /// 离线用例 `test/notification_aggregation_test.dart` 里把平台语言钉成 zh
  /// 再断言中文（`pd.localeTestValue`），这样两边都是真的在验东西。
  String get summaryTitle {
    final t = platformText();
    return channelName.isEmpty
        ? t.notifyAggTitle(count)
        : t.notifyAggTitleChannel(count, channelName);
  }

  void add(String line) {
    count++;
    lines.add(line);
    while (lines.length > kMaxNotificationLines) {
      lines.removeAt(0);
    }
  }

  String get latest => lines.isEmpty ? '' : lines.last;
}

/// 聚合摘要里最多几条明细（原版取 5 条）
const int kMaxNotificationLines = 5;

class NotificationService {
  NotificationService(this.ref, {BackgroundService? background})
    : background = background ?? ref.read(backgroundServiceProvider);

  final Ref ref;
  final BackgroundService background;

  /// 当前正在看的频道（前台时该频道的消息不弹通知）
  int? activeChannelId;

  /// App 是否在前台
  bool appInForeground = true;

  /// 已提醒过的消息（socket 重连会重放历史事件，别重复弹）
  final Set<int> _notified = <int>{};

  /// 每个 (频道, 话题) 的聚合状态；key = `'$channelId:$threadId'`
  final Map<String, ChannelNotificationAgg> _agg =
      <String, ChannelNotificationAgg>{};

  /// 已提醒过的消息数（测试用）
  int get notifiedCount => _notified.length;

  /// 正在预加载的频道（同一频道不并发拉）
  final Set<int> _prefetching = <int>{};

  /// 「预加载失败过」的节流位（原版 `skip_post_preview_mode`）：
  /// 失败后先别反复重试，等 [clearSkipPostPreview]（登录/同步成功）再放开。
  bool _skipPostPreview = false;

  /// 预加载被节流中（测试用）
  bool get skipPostPreview => _skipPostPreview;

  /// 放开预加载节流（原版 `LoginPresenter` / `SyncWorker` 成功时清）
  void clearSkipPostPreview() => _skipPostPreview = false;

  int _myUserId = 0;

  /// 某个 (频道, 话题) 当前的聚合（测试用）
  ChannelNotificationAgg? aggregateFor(int channelId, {int threadId = 0}) =>
      _agg['$channelId:$threadId'];

  void reset() {
    _notified.clear();
    _agg.clear();
    _prefetching.clear();
    _skipPostPreview = false;
  }

  /// 判断并（必要时）弹一条通知。返回是否真的弹了。
  Future<bool> maybeNotify(
    PostDto post, {
    ChannelDto? channel,
    String? senderName,
  }) async {
    final sync = ref.read(chatSessionControllerProvider);
    _myUserId = sync.myUserId;
    if (post.creatorId == _myUserId) return false; // 自己发的不提醒
    if (post.isSystem || post.type == 'system') return false;
    // 去重只在**真的弹了**之后记账：否则前台被压掉的那条会白白占掉名额，
    // 退到后台再来的同一条就永远不提醒了（踩过）。
    if (post.postId > 0 && _notified.contains(post.postId)) return false;
    // 前台不弹：列表本来就实时刷新；后台才需要通知（原 App 的行为）
    if (appInForeground) return false;

    final resolved = channel ?? await _channelOf(post.channelId);
    if (resolved == null) return false;
    // 免打扰（手动 snooze + 定时免打扰）：原版靠**服务端不推推送**静音，
    // 我们走本地通知，所以在这里自己判一次（判定逻辑与原版 `SubItem` 同一套）。
    if (ref.read(snoozeControllerProvider).suppressesAt(DateTime.now())) {
      debugPrint('[p8] 免打扰中，不弹通知（#${post.postId}）');
      return false;
    }
    // 频道级通知档位（`Channel.Preference`，跟原版 `notification_mobile` 同一套取值）
    if (!_allowsNotification(
      resolved,
      post,
      _myUserId,
      settings: ref.read(serverSettingsProvider),
    )) {
      return false;
    }

    final shown = await _notify(post, resolved, senderName: senderName);
    if (shown && post.postId > 0) _notified.add(post.postId);
    // 原版弹完通知会挂一个 `PostPreviewWorker` 把该频道前后各 40 条拉下来
    // （`PushNotificationUtils.notifyReceivedMessage` 最后一行）
    if (shown) unawaited(maybePrefetchPosts(resolved.channelId));
    return shown;
  }

  /// 「收到消息通知时预加载消息」（原版 `PostPreviewWorker.fetchServerPostIfNecessary`）。
  ///
  /// 判定顺序逐行对齐：
  ///   1. 档位 `CLOSE` → 不做；
  ///   2. 网络类型取不到（原版 `getCurrentNetworkType() == null`）→ 不做；
  ///   3. `ONLY_WIFI` 时只有 Wi-Fi 才做（`WIFI_AND_OTHER` 连移动数据也做）；
  ///   4. 上次失败还没被"同步成功"清掉（`skip_post_preview_mode`）→ 不做；
  ///   5. 拉 40+40 条并**替换**本地主列表；失败记上节流位。
  ///
  /// 返回是否真的发起了预加载（测试用）。
  Future<bool> maybePrefetchPosts(int channelId) async {
    if (channelId <= 0) return false;
    final mode = ref.read(postPreviewModeProvider);
    if (mode == PostPreviewMode.close) return false;
    if (_skipPostPreview || _prefetching.contains(channelId)) return false;
    final net = await ref.read(networkTypeProbeProvider).current();
    // 判不出来 / 没网：都不做（保守，别偷偷跑流量）
    if (net == NetworkType.unknown || net == NetworkType.none) return false;
    if (mode == PostPreviewMode.onlyWifi && !net.isWifi) return false;

    _prefetching.add(channelId);
    try {
      final n = await ref
          .read(chatSessionControllerProvider.notifier)
          .prefetchChannelPosts(channelId);
      if (n < 0) {
        _skipPostPreview = true;
        debugPrint('[p9] 预加载失败，暂时不再预加载（# $channelId）');
      } else {
        debugPrint('[p9] 预加载频道 #$channelId 消息 $n 条（$net / $mode）');
      }
      return n >= 0;
    } finally {
      _prefetching.remove(channelId);
    }
  }

  /// 频道档位是否允许为这条消息弹通知。
  ///
  /// 取值来自原版 `Common.java:142-146`：
  ///   * `none`                      → 不弹
  ///   * `mention`                   → 只有 @我 才弹
  ///   * `mention_subscribe`         → @我 或"我订阅的话题"才弹
  ///   * `all` / 空 / `by_admin_console` → 弹
  ///
  /// 还剩下的取舍：`by_admin_console`（跟随全局默认档位）在服务端才解析得出来，
  /// 这里**按"弹"处理**（fail-open），免得管理员配了默认提醒反而收不到。
  static bool _allowsNotification(
    ChannelDto channel,
    PostDto post,
    int myUserId, {
    ServerSettings? settings,
  }) {
    if (channel.notificationMute) return false;
    // `by_admin_console` / 空 = 跟随服务端下发的默认档位
    // （`SYNO.Chat.Admin.Setting` 的 `notify_type`，真机实测 `mention_subscribe`）
    var level = channel.notificationMobile;
    if (level.isEmpty || level == 'by_admin_console') {
      level = settings?.defaultNotificationType ?? '';
    }
    switch (level) {
      case ChatApi.notificationNone:
        return false;
      case ChatApi.notificationMention:
        return mentionsMe(post, myUserId);
      case ChatApi.notificationMentionSubscribe:
        // "@我，以及我订阅的话题" —— 订阅关系在 `channel.subscribes`
        // （`post.subscribe` 广播落库，见 ChatStore.setSubscribed）。
        // 频道里的回复算话题：拿 thread_id 判，主消息本身就是话题时拿 post_id。
        return mentionsMe(post, myUserId) ||
            channel.subscribes.contains(
              post.threadId > 0 ? post.threadId : post.postId,
            );
      default:
        return true;
    }
  }

  /// 供离线测试直接验证档位矩阵（生产代码走 [maybeNotify]）
  @visibleForTesting
  static bool allowsNotificationForTest(
    ChannelDto channel,
    PostDto post,
    int myUserId, {
    ServerSettings? settings,
  }) => _allowsNotification(channel, post, myUserId, settings: settings);

  /// `@我` 判定：服务端 `posts.mentions` 是 user_id 数组；
  /// 老版本还会在 `hashtags_additional` 里带 `{hashtag, user_id}`。
  static bool mentionsMe(PostDto post, int myUserId) {
    if (myUserId <= 0) return false;
    if (post.mentions.contains(myUserId)) return true;
    return post.hashtagsAdditional.any((h) => h.userId == myUserId);
  }

  /// 直接弹（贪睡到点重弹、或测试驱动）——不再走一遍过滤
  Future<bool> _notify(
    PostDto post,
    ChannelDto channel, {
    String? senderName,
  }) async {
    final e2ee = ref.read(e2eeControllerProvider.notifier);
    final locked =
        channel.encrypted && e2ee.keyStateOf(channel) != ChannelKeyState.ready;
    final body = channel.encrypted
        ? e2ee.displayMessage(channel, post.message)
        : _preview(post);
    final name = senderName ?? await _senderName(post.creatorId);
    final t = platformText();
    final singleTitle = channel.name.isNotEmpty
        ? (name.isEmpty ? channel.name : '$name · ${channel.name}')
        : (name.isEmpty ? t.notifyNewMessage : name);
    final preview = body.isEmpty ? t.notifyEmptyMessage : body;

    // 按 (频道, 话题) 聚合：第 2 条起改成「N 条新消息 | 频道名」+ InboxStyle 明细
    final agg = _agg.putIfAbsent(
      '${channel.channelId}:${post.threadId}',
      () => ChannelNotificationAgg(
        channel.channelId,
        post.threadId,
        channel.name,
      ),
    );
    agg.add(preview);
    return background.show(
      MessageNotification(
        channelId: channel.channelId,
        postId: post.postId,
        threadId: post.threadId,
        title: agg.count > 1 ? agg.summaryTitle : singleTitle,
        text: agg.latest,
        lines: List<String>.of(agg.lines),
        canReply: !locked,
      ),
    );
  }

  /// 通知里点了「回复」
  Future<void> onReply(int channelId, String text, {int postId = 0}) async {
    final body = text.trim();
    if (body.isEmpty) return;
    await ref
        .read(chatSessionControllerProvider.notifier)
        .sendMessage(channelId, body);
    await markRead(channelId);
  }

  /// 通知里点了「已读」：原版同款 —— 标记已读后**把这个频道的通知全撤掉**
  /// （`PushNotificationUtils.shouldClearNotification`）
  Future<void> markRead(int channelId) async {
    await ref.read(chatSessionControllerProvider.notifier).markRead(channelId);
    await clearChannel(channelId);
  }

  /// 撤掉某频道所有话题的通知与聚合状态
  Future<void> clearChannel(int channelId) async {
    // 无条件通知原生：进程可能重启过，`_agg` 是空的但系统里通知还在
    await background.cancelChannel(channelId);
    _agg.removeWhere((k, _) => k.startsWith('$channelId:'));
  }

  /// 通知里点了「贪睡」：**全局免打扰 1 小时**（服务端 `User.Preference set`），
  /// 并把这条通知撤掉 —— 与原版 `NotificationActionWorker.setSnooze` 完全一致。
  ///
  /// 返回是否设置成功（离线时抛异常 → false）。
  Future<bool> snooze(int channelId, {Duration? duration}) async {
    try {
      await ref
          .read(snoozeControllerProvider.notifier)
          .setSnooze(duration ?? kSnoozeDuration);
      await clearChannel(channelId);
      debugPrint('[p8] 贪睡 → 全局免打扰 ${duration ?? kSnoozeDuration}');
      return true;
    } catch (e) {
      debugPrint('[p8] 贪睡失败：$e');
      return false;
    }
  }

  /// 处理原生回传的动作
  Future<void> handleAction(NotificationAction action) async {
    switch (action.action) {
      case NotificationAction.reply:
        await onReply(action.channelId, action.text, postId: action.postId);
      case NotificationAction.markRead:
        await markRead(action.channelId);
      case NotificationAction.snooze:
        await snooze(action.channelId);
    }
  }

  /// 收到新消息事件 → 走一遍过滤
  Future<void> onPostEvent(PostDto post) => maybeNotify(post);

  // ------------------------------------------------------------ 内部

  Future<ChannelDto?> _channelOf(int channelId) async {
    final store = ref.read(chatStoreProvider);
    for (final c in await store.allChannels()) {
      if (c.channelId == channelId) return c;
    }
    return null;
  }

  /// 按 (频道, 消息) 取本地记录（通知动作里要拿它渲染/去重）
  Future<PostDto?> postOf(int channelId, int postId) async =>
      ref.read(chatStoreProvider).postById(channelId, postId);

  Future<String> _senderName(int userId) async {
    final store = ref.read(chatStoreProvider);
    for (final u in await store.allUsers()) {
      if (u.userId == userId) return u.displayName;
    }
    return '';
  }

  /// 非加密频道也用一份像样的预览（附件/投票等没有正文）
  String _preview(PostDto post) {
    if (post.message.trim().isNotEmpty) return post.message;
    final t = platformText();
    final att = post.attachments;
    if (att.isNotEmpty) return t.notifyAttachment(att.first.label);
    if (post.vote != null) {
      return t.notifyPollOptions(post.vote!.choices.length);
    }
    return '';
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService(ref);
});
