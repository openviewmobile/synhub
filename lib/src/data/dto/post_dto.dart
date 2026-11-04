// 消息 VO —— 字段名逐一对齐 APK 的 `data/vo/chat/PostVo.java` 与实测响应。
//
// 参考实测：test/fixtures/post_list.json（`SYNO.Chat.Post / list` 原样落盘）
//
// 解析原则同 ChannelDto：**宽容**。`Post/list` 不带 `has` 时只返回精简字段，
// 带了 `has=["thread"]` / `file_props` / `reactions` 才会多出来，
// 所以除 `post_id`/`channel_id` 之外全部可缺省。
library;

import 'dart:convert';
import 'chatbot_attachment_dto.dart';

import 'file_prop_dto.dart';
import 'url_prop_dto.dart';
import 'vote_dto.dart';

/// `hashtags_additional` 的元素 —— **对象**，不是字符串。
///
/// 原版 `PostVo.hashtagsAdditional` 是 `HashtagVo[]`，每个元素形如
/// `{hashtag: "tag", user_id: 14}`（`data/vo/chat/HashtagVo.java`）。
/// 我们之前按 `List<String>` 解析，会把 `{...}` 拍成脏字符串。
class HashtagDto {
  const HashtagDto({required this.hashtag, this.userId = 0});

  final String hashtag;
  final int userId;

  static HashtagDto? tryParse(Object? raw) {
    if (raw is Map) {
      final tag = raw['hashtag'];
      if (tag is String && tag.isNotEmpty) {
        return HashtagDto(hashtag: tag, userId: PostDto._int(raw['user_id']));
      }
      return null;
    }
    // 容错：老服务端/老数据可能是裸字符串
    if (raw is String && raw.isNotEmpty) return HashtagDto(hashtag: raw);
    return null;
  }

  static List<HashtagDto> parseList(Object? raw) {
    if (raw is! List) return const [];
    return raw.map(tryParse).whereType<HashtagDto>().toList(growable: false);
  }

  @override
  String toString() => '#$hashtag';
}

class PostDto {
  const PostDto({
    required this.postId,
    required this.channelId,
    this.creatorId = 0,
    this.threadId = 0,
    this.type = 'normal',
    this.message = '',
    this.createAt = 0,
    this.updateAt = 0,
    this.deleteAt = 0,
    this.lastCommentAt = 0,
    this.lastPinAt = 0,
    this.commentCount = 0,
    this.isStar = false,
    this.isSticky = false,
    this.props = const {},
    this.encrypted = false,
    this.safeUrl = true,
    this.staticUrl = false,
    this.forwardType = 'none',
    this.botId = 0,
    this.botNickname = '',
    this.hashtags = const [],
    this.hashtagsAdditional = const <HashtagDto>[],
    this.mentions = const [],
    this.reactions = const [],
    this.urlProps = const [],
    this.fileProps,
    this.systemProps,
    this.tmpPostId = 0,
    this.state = 0,
  });

  final int postId;
  final int channelId;
  final int creatorId;

  /// 0 表示不是线程回复；否则是根消息 id
  final int threadId;

  /// `normal` / `system` / `file` / `vote` …
  final String type;
  final String message;

  final int createAt;
  final int updateAt;
  final int deleteAt;
  final int lastCommentAt;
  final int lastPinAt;
  final int commentCount;

  final bool isStar;
  final bool isSticky;

  /// `props` 原文（投票 `vote`、提醒 `remind_at` 都在里面）
  final Map<String, dynamic> props;

  /// `props.encrypted` —— E2EE 频道
  final bool encrypted;
  final bool safeUrl;
  final bool staticUrl;
  final String forwardType;

  /// 机器人消息的 `props.bot`（`BotVo{bot_id,nickname}`）。
  ///
  /// 只有**机器人/入站 webhook** 发的消息才有。原版用它来画头像
  /// （`ChannelViewBinder.java:214` 有 bot 就换成 `synobot_mini` 图标，
  /// 首字母也取 `bot.nickname`），见 `_PostTile` 的头像分支。
  final int botId;
  final String botNickname;

  bool get hasBot => botId > 0 || botNickname.isNotEmpty;

  final List<String> hashtags;

  /// 别人加的标签（`hashtags_additional`，带 `user_id`）
  final List<HashtagDto> hashtagsAdditional;

  /// `mentions` 里的 user_id
  final List<int> mentions;

  /// 原样保留（Phase 4 做 reaction UI 再建模）
  final List<Map<String, dynamic>> reactions;
  final List<Map<String, dynamic>> urlProps;

  /// 附件原始结构（`has=["file_props"]` 时才有）。
  ///
  /// ⚠️ 服务端给的是 **Map / List / JSON 字符串**都有可能（多个附件时是数组，
  /// 见 `FilePropDto.parseList`）。这里必须原样保留，只收 Map 会把附件整条丢掉
  /// —— 曾经就是这个 bug：`file_props` 是数组 → 附件全没了。
  final Object? fileProps;

  /// 附件（图片 / 文件 / 语音）。`file_props` 可能是：
  ///   * `[{...}]` 数组
  ///   * `{"file_prop": {...}}` 单个
  ///   * 上面两种被 JSON 字符串包一层
  List<FilePropDto> get attachments =>
      fileProps == null ? const [] : FilePropDto.parseList(fileProps);

  /// 系统消息（channel.join / channel.leave 之类）
  final Map<String, dynamic>? systemProps;

  /// 本地临时 id（乐观发送时用，`Post.tmpPostId()`）
  final int tmpPostId;

  /// 0 = 已同步；1 = 发送中；2 = 发送失败（对齐 APK 的 `Post.state()`）
  final int state;

  /// 链接预览（OG）：`url_props` 的强类型视图。
  ///
  /// ⚠️ 服务端是**异步**补这个字段的（发消息时是空数组），所以列表刷新/
  /// `post.update` 之后才会有值。
  List<UrlPropDto> get linkPreviews => UrlPropDto.parseList(urlProps);

  /// 这条消息要画的那一张预览卡片（第一条非 hidden 的；有附件就不画）。
  UrlPropDto? get linkPreview =>
      firstVisiblePreview(linkPreviews, hasAttachment: attachments.isNotEmpty);

  /// 机器人消息的「附件 + 按钮」（`props.attachments`）。
  ///
  /// 只有机器人/入站 webhook 发的消息才有；按钮点了走
  /// `SYNO.Chat.Post.Attachment / trigger`（见 [ChatbotAttachmentDto]）。
  List<ChatbotAttachmentDto> get chatbotAttachments =>
      ChatbotAttachmentDto.parseList(props['attachments']);

  /// 投票（`props.vote`，没有就是 null）
  VoteDto? get vote => VoteDto.tryParse(props['vote']);

  /// 提醒时间（`props.remind_at`，0 = 没设）
  int get remindAt => _int(props['remind_at']);

  bool get isSystem => type == 'system';
  bool get isDeleted => deleteAt > 0;
  bool get isPending => state != 0;
  bool get isThreadReply => threadId != 0 && threadId != postId;

  /// 系统消息的事件名（`channel.join` 等）
  String get systemEvent => '${systemProps?['event'] ?? ''}';

  /// 排序/游标用：先按时间，再按 id（实测 post_id 是 2³²+ 的大数，单调递增）
  int get sortKey => createAt * 1000000 + (postId % 1000000);

  PostDto copyWith({
    Map<String, dynamic>? props,
    int? postId,
    int? channelId,
    int? createAt,
    int? updateAt,
    int? deleteAt,
    String? message,
    int? commentCount,
    int? lastCommentAt,
    int? lastPinAt,
    int? threadId,
    bool? isStar,
    bool? isSticky,
    int? state,
    int? tmpPostId,
    List<String>? hashtags,
    List<int>? mentions,
    List<Map<String, dynamic>>? reactions,
    bool? encrypted,
  }) {
    return PostDto(
      props: props ?? this.props,
      postId: postId ?? this.postId,
      channelId: channelId ?? this.channelId,
      creatorId: creatorId,
      threadId: threadId ?? this.threadId,
      type: type,
      message: message ?? this.message,
      createAt: createAt ?? this.createAt,
      updateAt: updateAt ?? this.updateAt,
      deleteAt: deleteAt ?? this.deleteAt,
      lastCommentAt: lastCommentAt ?? this.lastCommentAt,
      lastPinAt: lastPinAt ?? this.lastPinAt,
      commentCount: commentCount ?? this.commentCount,
      isStar: isStar ?? this.isStar,
      isSticky: isSticky ?? this.isSticky,
      encrypted: encrypted ?? this.encrypted,
      safeUrl: safeUrl,
      staticUrl: staticUrl,
      forwardType: forwardType,
      botId: botId,
      botNickname: botNickname,
      hashtags: hashtags ?? this.hashtags,
      hashtagsAdditional: hashtagsAdditional,
      mentions: mentions ?? this.mentions,
      reactions: reactions ?? this.reactions,
      urlProps: urlProps,
      fileProps: fileProps,
      systemProps: systemProps,
      tmpPostId: tmpPostId ?? this.tmpPostId,
      state: state ?? this.state,
    );
  }

  static PostDto fromJson(Map<String, dynamic> json) {
    final props = _map(json['props']);
    final forward = _map(props['forward']);

    return PostDto(
      postId: _int(json['post_id']),
      channelId: _int(json['channel_id']),
      creatorId: _int(json['creator_id']),
      threadId: _int(json['thread_id']),
      type: _str(json['type'], 'normal'),
      message: _str(json['message']),
      createAt: _int(json['create_at']),
      updateAt: _int(json['update_at']),
      deleteAt: _int(json['delete_at']),
      lastCommentAt: _int(json['last_comment_at']),
      lastPinAt: _int(json['last_pin_at']),
      commentCount: _int(json['comment_count']),
      isStar: _bool(json['is_star']),
      isSticky: _bool(json['is_sticky']),
      props: props,
      encrypted: _bool(props['encrypted']),
      // `PropVo.safeUrl` 的默认值是 **true**（安全链接，客户端要做域名校验），
      // 字段缺失时不能当 false
      safeUrl: props.containsKey('safe_url') ? _bool(props['safe_url']) : true,
      staticUrl: _bool(props['static_url']),
      forwardType: _str(forward['type'], 'none'),
      botId: _int(_map(props['bot'])['bot_id']),
      botNickname: _str(_map(props['bot'])['nickname']),
      hashtags: _strList(json['hashtags']),
      hashtagsAdditional: HashtagDto.parseList(json['hashtags_additional']),
      mentions: _mentionIds(json['mentions']),
      reactions: _mapList(json['reactions']),
      urlProps: _mapList(json['url_props']),
      fileProps: _rawJson(json['file_props']),
      systemProps: json['system_props'] is Map
          ? Map<String, dynamic>.from(json['system_props'] as Map)
          : null,
      // 服务端不认识 tmp_post_id，但会**回带 mobile_token**（我们发的就是本地临时 id），
      // 多设备对账靠它 —— 见 docs/phase3-protocol.md §2。
      // 回带形态可能是数字，也可能是带引号的字符串（我们发过去时 JSON 编码过），都认。
      tmpPostId: _int(json['tmp_post_id']) > 0
          ? _int(json['tmp_post_id'])
          : _tokenInt(json['mobile_token']),
      state: _int(json['state']),
    );
  }

  // ------------------------------------------------------------ 内部

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  /// `mobile_token` 的宽容解析：`1234` / `"1234"` / `""` 都要能处理
  static int _tokenInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.replaceAll('"', '').trim()) ?? 0;
    return 0;
  }

  /// 原样保留 JSON（字符串就地解一次，方便直存本地库）
  static Object? _rawJson(Object? v) {
    if (v == null) return null;
    if (v is String) {
      if (v.isEmpty) return null;
      try {
        return jsonDecode(v);
      } catch (_) {
        return v;
      }
    }
    return v;
  }

  static String _str(Object? v, [String fallback = '']) =>
      v is String ? v : (v == null ? fallback : '$v');

  static bool _bool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == 'true' || v == '1';
    return false;
  }

  static List<String> _strList(Object? v) {
    if (v is! List) return const [];
    return v.map((e) => '$e').toList();
  }

  static List<int> _mentionIds(Object? v) {
    if (v is! List) return const [];
    // ⚠️★ **不能写 `> 0`**（第 37 轮修的真实 bug）。
    //
    // `mentions` 里除了真人 id，还有两个**合法伪用户**：
    // `@channel` → **-2**、`@here` → **-1**
    // （`autocomplete.dart:143-144` 与原版 `ChatUtil.atMention` 一致；
    //  APK 里 `at_channel`/`AT_CHANNEL`/`at_here`/`AT_HERE` 四个字符串可证）。
    //
    // 而 `rich_text.parseMessage` 是**按下标**把 `mentions[i]` 配给文本里第 i 个
    // `@xxx` 的。一旦在这里把 -2/-1 丢掉，下标整体前移 ⇒
    // 文本 `@channel @bob` + 服务端 `[-2, 3]` 会渲染成
    // **`@channel` 高亮成 bob、`@bob` 完全不高亮**（两个都错，且方向相反）。
    // `usernames`（按 `@名字` 查表）救不了：它只由真实用户构造，没有 `channel`/`here`。
    //
    // 只丢 **0** —— 它表示"没解析出 id"（缺 `user_id` / 非数字），不是合法用户。
    return v.map(_mentionId).where((e) => e != 0).toList();
  }

  /// `mentions` 里可能是 `{"user_id": 3}`，也可能直接是数字
  static int _mentionId(Object? v) {
    if (v is Map) return _int(v['user_id']);
    return _int(v);
  }

  static List<Map<String, dynamic>> _mapList(Object? v) {
    if (v is! List) return const [];
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : const {};
}
