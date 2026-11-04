// 频道 VO —— 字段名逐一对齐 APK 的 `data/vo/chat/ChannelVo.java`
//
// 参考实测响应：test/fixtures/channel_list.json
//
// 解析原则：**宽容**。不同 version（1/2/4/5）返回的字段并不一致：
//   v1 没有 unread_thread / channel_order_time / member_count …
// 缺失一律取默认值，不要因为服务端版本低就炸掉整个列表。
library;

import 'dart:convert';

import 'user_dto.dart';

/// `SYNO.Chat.Channel` 的一个频道。
class ChannelDto {
  const ChannelDto({
    required this.channelId,
    this.name = '',
    this.purpose = '',
    this.type = '',
    this.encrypted = false,
    this.isJoined = false,
    this.isStar = false,
    this.unread = 0,
    this.unreadMention = 0,
    this.unreadComment = 0,
    this.unreadMentionComment = 0,
    this.unreadThread = const {},
    this.subscribes = const [],
    this.members = const [],
    this.brokenUsers = const [],
    this.channelKeyEnc = '',
    this.totalMemberCount = 0,
    this.creatorId = 0,
    this.userId = 0,
    this.invitorId = 0,
    this.user,
    this.lastPostAt = 0,
    this.lastViewAt = 0,
    this.lastViewCommentAt = 0,
    this.channelOrderTime = 0,
    this.hideGlobalAt = 0,
    this.lastHideAt = 0,
    this.notificationDesktop = '',
    this.notificationMobile = '',
    this.notificationMute = false,
    this.hashtags = const [],
  });

  final int channelId;
  final String name;
  final String purpose;

  /// `public` / `private` / `anonymous` / `chatbot` …
  final String type;
  final bool encrypted;
  final bool isJoined;
  final bool isStar;

  final int unread;
  final int unreadMention;
  final int unreadComment;
  final int unreadMentionComment;

  /// thread_id → 未读数（`unread_thread`，JSON 对象的 key 是字符串）
  final Map<int, int> unreadThread;

  /// 订阅的 thread/post id
  final List<int> subscribes;

  /// 成员 user_id 列表
  final List<int> members;

  /// 在这个频道里**解不开消息**的成员 user_id（`broken_users`）。
  ///
  /// 由服务端算并下发（`ChannelVo.broken_users`），也会被实时事件更新：
  /// `client.channel.brokenuser` 加一个、`channel.rescue` 减一个。
  /// 原版用它给成员列表标 ⚠、并让用户点一下去"修复"。
  final List<int> brokenUsers;

  final String channelKeyEnc;
  final int totalMemberCount;
  final int creatorId;

  /// 直聊/邀请场景的对端用户 id（`ChannelVo.userId`）
  final int userId;

  /// 谁把我拉进来的（`ChannelVo.invitorId`）
  final int invitorId;

  /// 服务端内联带的用户对象（`ChannelVo.user`，1:1 直聊时是对端）
  final UserDto? user;

  final int lastPostAt;
  final int lastViewAt;
  final int lastViewCommentAt;
  final int channelOrderTime;
  final int hideGlobalAt;
  final int lastHideAt;

  /// `all` / `mention` / `mention_subscribe` / `nothing` …
  final String notificationDesktop;
  final String notificationMobile;
  final bool notificationMute;

  /// 频道里用过的标签（本地缓存，来自 `Channel.Hashtag/list`，原版 `ChatChannel.hashtags`）。
  final List<String> hashtags;

  /// 会话列表排序用：优先 channel_order_time，缺失时退回 last_post_at。
  int get sortKey => channelOrderTime > 0 ? channelOrderTime : lastPostAt;

  /// 未读总数（未读 + 未读回复）—— 原版 `Channel.totalUnread()`
  int get totalUnread => unread + unreadComment;

  /// 原版 `Channel.isChatBot()`：**只看 type == "chatbot"**（synobot 不算）
  bool get isChatBotType => type == 'chatbot';

  /// 原版 `Channel.isConversation()`：**只看 type == "anonymous"**
  bool get isConversation => type == 'anonymous';

  bool get isPublicOrPrivate => type == 'public' || type == 'private';

  /// 通知粒度是不是"全部消息"（原版 `Channel.isNotificationTypeIsAll()`：
  /// `notification_mobile == "all"`，或 `== "by_admin_console"` 且服务端
  /// `notify_type == "all"`）。**频道没单独设置时是 `""`，不算 all。**
  bool notificationTypeIsAll(String serverDefaultNotificationType) =>
      notificationMobile == 'all' ||
      (notificationMobile == 'by_admin_console' &&
          serverDefaultNotificationType == 'all');

  /// 侧栏是否该藏起来（照抄原版 `Channel.hideAtSideBar()`）。
  ///
  /// `hide_global_at > 0`（全局隐藏）一定藏；`last_hide_at == 0` 没隐藏过；
  /// 否则**只要还有未读就重新冒出来**（原版"隐藏频道来新消息会回来"的行为）。
  /// 有发送失败的消息时不藏 —— 不然用户找不到重试入口。
  bool hideAtSideBar({
    bool hasFailedPost = false,
    String serverDefaultNotificationType = '',
  }) {
    if (hideGlobalAt > 0) return true;
    if (lastHideAt == 0) return false;
    if (hasFailedPost) return false;
    if (isChatBotType || isConversation) return totalUnread == 0;
    if (isPublicOrPrivate) {
      return (encrypted || notificationTypeIsAll(serverDefaultNotificationType))
          ? totalUnread == 0
          : unreadMention + unreadComment == 0;
    }
    return false;
  }

  bool get hasUnread => unread > 0 || unreadComment > 0;
  int get unreadTotal => unread + unreadComment;

  factory ChannelDto.fromJson(Map<String, dynamic> json) {
    final prefs = json['preferences'];
    final prefMap = prefs is Map
        ? Map<String, dynamic>.from(prefs)
        : const <String, dynamic>{};

    return ChannelDto(
      channelId: _int(json['channel_id']),
      name: _str(json['name']),
      purpose: _str(json['purpose']),
      type: _str(json['type']),
      encrypted: json['encrypted'] == true,
      isJoined: json['is_joined'] == true,
      isStar: json['is_star'] == true,
      unread: _int(json['unread']),
      unreadMention: _int(json['unread_mention']),
      unreadComment: _int(json['unread_comment']),
      unreadMentionComment: _int(json['unread_mention_comment']),
      unreadThread: _intMap(json['unread_thread']),
      subscribes: _intList(json['subscribes']),
      members: _intList(json['members']),
      // 服务端两种写法都见过：`broken_users`（列表或 JSON 字符串）
      brokenUsers: _intList(
        json['broken_users'] is String
            ? _tryJsonList(json['broken_users'])
            : json['broken_users'],
      ),
      channelKeyEnc: _str(json['channel_key_enc']),
      totalMemberCount: _int(json['total_member_count']),
      creatorId: _int(json['creator_id']),
      userId: _int(json['user_id']),
      invitorId: _int(json['invitor_id']),
      user: json['user'] is Map
          ? UserDto.fromJson(Map<String, dynamic>.from(json['user'] as Map))
          : null,
      lastPostAt: _int(json['last_post_at']),
      lastViewAt: _int(json['last_view_at']),
      lastViewCommentAt: _int(json['last_view_comment_at']),
      channelOrderTime: _int(json['channel_order_time']),
      hideGlobalAt: _int(json['hide_global_at']),
      lastHideAt: _int(json['last_hide_at']),
      notificationDesktop: _str(prefMap['notification_desktop']),
      notificationMobile: _str(prefMap['notification_mobile']),
      notificationMute: prefMap['notification_mute'] == true,
      // 服务端列表接口不下发，本地列自己维护；这里兼容一下万一有
      hashtags: _strList(json['hashtags']),
    );
  }

  /// 会话列表里频道名可能为空（匿名/直聊），用成员名兜底由上层负责。
  ChannelDto copyWith({
    String? name,
    String? purpose,
    bool? isJoined,
    bool? isStar,
    int? unread,
    int? unreadMention,
    int? unreadComment,
    int? unreadMentionComment,
    Map<int, int>? unreadThread,
    List<int>? subscribes,
    List<int>? members,
    List<int>? brokenUsers,
    int? totalMemberCount,
    int? lastPostAt,
    int? lastViewAt,
    int? lastViewCommentAt,
    int? channelOrderTime,
    int? hideGlobalAt,
    int? lastHideAt,
    String? channelKeyEnc,
    String? notificationDesktop,
    String? notificationMobile,
    bool? notificationMute,
    List<String>? hashtags,
  }) {
    return ChannelDto(
      channelId: channelId,
      name: name ?? this.name,
      purpose: purpose ?? this.purpose,
      type: type,
      encrypted: encrypted,
      isJoined: isJoined ?? this.isJoined,
      isStar: isStar ?? this.isStar,
      unread: unread ?? this.unread,
      unreadMention: unreadMention ?? this.unreadMention,
      unreadComment: unreadComment ?? this.unreadComment,
      unreadMentionComment: unreadMentionComment ?? this.unreadMentionComment,
      unreadThread: unreadThread ?? this.unreadThread,
      subscribes: subscribes ?? this.subscribes,
      members: members ?? this.members,
      brokenUsers: brokenUsers ?? this.brokenUsers,
      channelKeyEnc: channelKeyEnc ?? this.channelKeyEnc,
      totalMemberCount: totalMemberCount ?? this.totalMemberCount,
      creatorId: creatorId,
      lastPostAt: lastPostAt ?? this.lastPostAt,
      lastViewAt: lastViewAt ?? this.lastViewAt,
      lastViewCommentAt: lastViewCommentAt ?? this.lastViewCommentAt,
      channelOrderTime: channelOrderTime ?? this.channelOrderTime,
      hideGlobalAt: hideGlobalAt ?? this.hideGlobalAt,
      lastHideAt: lastHideAt ?? this.lastHideAt,
      notificationDesktop: notificationDesktop ?? this.notificationDesktop,
      notificationMobile: notificationMobile ?? this.notificationMobile,
      notificationMute: notificationMute ?? this.notificationMute,
      hashtags: hashtags ?? this.hashtags,
    );
  }
}

int _int(Object? v) => _intOrNull(v) ?? 0;

int? _intOrNull(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

String _str(Object? v) => v is String ? v : (v == null ? '' : '$v');

/// `broken_users` 有时是 JSON 字符串（原版本地库就是这么存的），先解一层。
List<int> _tryJsonList(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    return decoded is List ? _intList(decoded) : const [];
  } catch (_) {
    return const [];
  }
}

List<int> _intList(Object? v) {
  if (v is! List) return const [];
  final out = <int>[];
  for (final e in v) {
    final i = _intOrNull(e);
    if (i != null) out.add(i);
  }
  return out;
}

/// 标签列表：服务端直接给数组，本地库里存的是 JSON 字符串，两种都吃。
List<String> _strList(Object? v) {
  var list = v;
  if (list is String) {
    if (list.isEmpty) return const [];
    try {
      list = jsonDecode(list);
    } catch (_) {
      return const [];
    }
  }
  if (list is! List) return const [];
  return [
    for (final e in list)
      if ('$e'.isNotEmpty) '$e',
  ];
}

Map<int, int> _intMap(Object? v) {
  if (v is! Map) return const {};
  final out = <int, int>{};
  v.forEach((k, value) {
    final key = _intOrNull(k);
    final val = _intOrNull(value);
    if (key != null && val != null) out[key] = val;
  });
  return out;
}

/// 频道通知偏好（`SYNO.Chat.Channel.Preference / get` 的 `data.preferences`）
///
/// 原版 `data/model/ChannelPreference.java` + `NotificationPreferenceVo`。
/// ⚠️ 取值 `by_admin_console` 表示"跟随全局默认"，客户端要替换成自己的默认档位再展示。
class ChannelPreference {
  const ChannelPreference({
    this.notificationDesktop = '',
    this.notificationMobile = '',
    this.notificationMute = false,
    this.hashtags = const [],
  });

  final String notificationDesktop;
  final String notificationMobile;
  final bool notificationMute;

  /// 频道里用过的标签（本地缓存，来自 `Channel.Hashtag/list`，原版 `ChatChannel.hashtags`）。
  final List<String> hashtags;

  static ChannelPreference fromJson(Map<String, dynamic> json) {
    String str(Object? v) => v is String ? v : '';
    return ChannelPreference(
      notificationDesktop: str(json['notification_desktop']),
      notificationMobile: str(json['notification_mobile']),
      notificationMute: json['notification_mute'] == true,
    );
  }

  /// 是否"完全静音"（`none` 或服务端的 mute 标记）
  bool get isMuted => notificationMute || notificationMobile == 'none';

  ChannelPreference copyWith({
    String? notificationDesktop,
    String? notificationMobile,
    bool? notificationMute,
  }) => ChannelPreference(
    notificationDesktop: notificationDesktop ?? this.notificationDesktop,
    notificationMobile: notificationMobile ?? this.notificationMobile,
    notificationMute: notificationMute ?? this.notificationMute,
  );

  @override
  String toString() =>
      'ChannelPreference(mobile=$notificationMobile, mute=$notificationMute)';
}
