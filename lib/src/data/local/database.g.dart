// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ChannelRowsTable extends ChannelRows
    with TableInfo<$ChannelRowsTable, ChannelRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChannelRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _channelIdMeta = const VerificationMeta(
    'channelId',
  );
  @override
  late final GeneratedColumn<int> channelId = GeneratedColumn<int>(
    'channel_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _purposeMeta = const VerificationMeta(
    'purpose',
  );
  @override
  late final GeneratedColumn<String> purpose = GeneratedColumn<String>(
    'purpose',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _encryptedMeta = const VerificationMeta(
    'encrypted',
  );
  @override
  late final GeneratedColumn<bool> encrypted = GeneratedColumn<bool>(
    'encrypted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("encrypted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isJoinedMeta = const VerificationMeta(
    'isJoined',
  );
  @override
  late final GeneratedColumn<bool> isJoined = GeneratedColumn<bool>(
    'is_joined',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_joined" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isStarMeta = const VerificationMeta('isStar');
  @override
  late final GeneratedColumn<bool> isStar = GeneratedColumn<bool>(
    'is_star',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_star" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _unreadMeta = const VerificationMeta('unread');
  @override
  late final GeneratedColumn<int> unread = GeneratedColumn<int>(
    'unread',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _unreadMentionMeta = const VerificationMeta(
    'unreadMention',
  );
  @override
  late final GeneratedColumn<int> unreadMention = GeneratedColumn<int>(
    'unread_mention',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _unreadCommentMeta = const VerificationMeta(
    'unreadComment',
  );
  @override
  late final GeneratedColumn<int> unreadComment = GeneratedColumn<int>(
    'unread_comment',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _unreadMentionCommentMeta =
      const VerificationMeta('unreadMentionComment');
  @override
  late final GeneratedColumn<int> unreadMentionComment = GeneratedColumn<int>(
    'unread_mention_comment',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _unreadThreadMeta = const VerificationMeta(
    'unreadThread',
  );
  @override
  late final GeneratedColumn<String> unreadThread = GeneratedColumn<String>(
    'unread_thread',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _subscribesMeta = const VerificationMeta(
    'subscribes',
  );
  @override
  late final GeneratedColumn<String> subscribes = GeneratedColumn<String>(
    'subscribes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _membersMeta = const VerificationMeta(
    'members',
  );
  @override
  late final GeneratedColumn<String> members = GeneratedColumn<String>(
    'members',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _brokenUsersMeta = const VerificationMeta(
    'brokenUsers',
  );
  @override
  late final GeneratedColumn<String> brokenUsers = GeneratedColumn<String>(
    'broken_users',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _channelKeyEncMeta = const VerificationMeta(
    'channelKeyEnc',
  );
  @override
  late final GeneratedColumn<String> channelKeyEnc = GeneratedColumn<String>(
    'channel_key_enc',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _totalMemberCountMeta = const VerificationMeta(
    'totalMemberCount',
  );
  @override
  late final GeneratedColumn<int> totalMemberCount = GeneratedColumn<int>(
    'total_member_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _creatorIdMeta = const VerificationMeta(
    'creatorId',
  );
  @override
  late final GeneratedColumn<int> creatorId = GeneratedColumn<int>(
    'creator_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastPostAtMeta = const VerificationMeta(
    'lastPostAt',
  );
  @override
  late final GeneratedColumn<int> lastPostAt = GeneratedColumn<int>(
    'last_post_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastViewAtMeta = const VerificationMeta(
    'lastViewAt',
  );
  @override
  late final GeneratedColumn<int> lastViewAt = GeneratedColumn<int>(
    'last_view_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastViewCommentAtMeta = const VerificationMeta(
    'lastViewCommentAt',
  );
  @override
  late final GeneratedColumn<int> lastViewCommentAt = GeneratedColumn<int>(
    'last_view_comment_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _channelOrderTimeMeta = const VerificationMeta(
    'channelOrderTime',
  );
  @override
  late final GeneratedColumn<int> channelOrderTime = GeneratedColumn<int>(
    'channel_order_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _hideGlobalAtMeta = const VerificationMeta(
    'hideGlobalAt',
  );
  @override
  late final GeneratedColumn<int> hideGlobalAt = GeneratedColumn<int>(
    'hide_global_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastHideAtMeta = const VerificationMeta(
    'lastHideAt',
  );
  @override
  late final GeneratedColumn<int> lastHideAt = GeneratedColumn<int>(
    'last_hide_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _notificationDesktopMeta =
      const VerificationMeta('notificationDesktop');
  @override
  late final GeneratedColumn<String> notificationDesktop =
      GeneratedColumn<String>(
        'notification_desktop',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(''),
      );
  static const VerificationMeta _notificationMobileMeta =
      const VerificationMeta('notificationMobile');
  @override
  late final GeneratedColumn<String> notificationMobile =
      GeneratedColumn<String>(
        'notification_mobile',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(''),
      );
  static const VerificationMeta _notificationMuteMeta = const VerificationMeta(
    'notificationMute',
  );
  @override
  late final GeneratedColumn<bool> notificationMute = GeneratedColumn<bool>(
    'notification_mute',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("notification_mute" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _hashtagsMeta = const VerificationMeta(
    'hashtags',
  );
  @override
  late final GeneratedColumn<String> hashtags = GeneratedColumn<String>(
    'hashtags',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    channelId,
    name,
    purpose,
    type,
    encrypted,
    isJoined,
    isStar,
    unread,
    unreadMention,
    unreadComment,
    unreadMentionComment,
    unreadThread,
    subscribes,
    members,
    brokenUsers,
    channelKeyEnc,
    totalMemberCount,
    creatorId,
    lastPostAt,
    lastViewAt,
    lastViewCommentAt,
    channelOrderTime,
    hideGlobalAt,
    lastHideAt,
    notificationDesktop,
    notificationMobile,
    notificationMute,
    hashtags,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'channel_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<ChannelRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('channel_id')) {
      context.handle(
        _channelIdMeta,
        channelId.isAcceptableOrUnknown(data['channel_id']!, _channelIdMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('purpose')) {
      context.handle(
        _purposeMeta,
        purpose.isAcceptableOrUnknown(data['purpose']!, _purposeMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('encrypted')) {
      context.handle(
        _encryptedMeta,
        encrypted.isAcceptableOrUnknown(data['encrypted']!, _encryptedMeta),
      );
    }
    if (data.containsKey('is_joined')) {
      context.handle(
        _isJoinedMeta,
        isJoined.isAcceptableOrUnknown(data['is_joined']!, _isJoinedMeta),
      );
    }
    if (data.containsKey('is_star')) {
      context.handle(
        _isStarMeta,
        isStar.isAcceptableOrUnknown(data['is_star']!, _isStarMeta),
      );
    }
    if (data.containsKey('unread')) {
      context.handle(
        _unreadMeta,
        unread.isAcceptableOrUnknown(data['unread']!, _unreadMeta),
      );
    }
    if (data.containsKey('unread_mention')) {
      context.handle(
        _unreadMentionMeta,
        unreadMention.isAcceptableOrUnknown(
          data['unread_mention']!,
          _unreadMentionMeta,
        ),
      );
    }
    if (data.containsKey('unread_comment')) {
      context.handle(
        _unreadCommentMeta,
        unreadComment.isAcceptableOrUnknown(
          data['unread_comment']!,
          _unreadCommentMeta,
        ),
      );
    }
    if (data.containsKey('unread_mention_comment')) {
      context.handle(
        _unreadMentionCommentMeta,
        unreadMentionComment.isAcceptableOrUnknown(
          data['unread_mention_comment']!,
          _unreadMentionCommentMeta,
        ),
      );
    }
    if (data.containsKey('unread_thread')) {
      context.handle(
        _unreadThreadMeta,
        unreadThread.isAcceptableOrUnknown(
          data['unread_thread']!,
          _unreadThreadMeta,
        ),
      );
    }
    if (data.containsKey('subscribes')) {
      context.handle(
        _subscribesMeta,
        subscribes.isAcceptableOrUnknown(data['subscribes']!, _subscribesMeta),
      );
    }
    if (data.containsKey('members')) {
      context.handle(
        _membersMeta,
        members.isAcceptableOrUnknown(data['members']!, _membersMeta),
      );
    }
    if (data.containsKey('broken_users')) {
      context.handle(
        _brokenUsersMeta,
        brokenUsers.isAcceptableOrUnknown(
          data['broken_users']!,
          _brokenUsersMeta,
        ),
      );
    }
    if (data.containsKey('channel_key_enc')) {
      context.handle(
        _channelKeyEncMeta,
        channelKeyEnc.isAcceptableOrUnknown(
          data['channel_key_enc']!,
          _channelKeyEncMeta,
        ),
      );
    }
    if (data.containsKey('total_member_count')) {
      context.handle(
        _totalMemberCountMeta,
        totalMemberCount.isAcceptableOrUnknown(
          data['total_member_count']!,
          _totalMemberCountMeta,
        ),
      );
    }
    if (data.containsKey('creator_id')) {
      context.handle(
        _creatorIdMeta,
        creatorId.isAcceptableOrUnknown(data['creator_id']!, _creatorIdMeta),
      );
    }
    if (data.containsKey('last_post_at')) {
      context.handle(
        _lastPostAtMeta,
        lastPostAt.isAcceptableOrUnknown(
          data['last_post_at']!,
          _lastPostAtMeta,
        ),
      );
    }
    if (data.containsKey('last_view_at')) {
      context.handle(
        _lastViewAtMeta,
        lastViewAt.isAcceptableOrUnknown(
          data['last_view_at']!,
          _lastViewAtMeta,
        ),
      );
    }
    if (data.containsKey('last_view_comment_at')) {
      context.handle(
        _lastViewCommentAtMeta,
        lastViewCommentAt.isAcceptableOrUnknown(
          data['last_view_comment_at']!,
          _lastViewCommentAtMeta,
        ),
      );
    }
    if (data.containsKey('channel_order_time')) {
      context.handle(
        _channelOrderTimeMeta,
        channelOrderTime.isAcceptableOrUnknown(
          data['channel_order_time']!,
          _channelOrderTimeMeta,
        ),
      );
    }
    if (data.containsKey('hide_global_at')) {
      context.handle(
        _hideGlobalAtMeta,
        hideGlobalAt.isAcceptableOrUnknown(
          data['hide_global_at']!,
          _hideGlobalAtMeta,
        ),
      );
    }
    if (data.containsKey('last_hide_at')) {
      context.handle(
        _lastHideAtMeta,
        lastHideAt.isAcceptableOrUnknown(
          data['last_hide_at']!,
          _lastHideAtMeta,
        ),
      );
    }
    if (data.containsKey('notification_desktop')) {
      context.handle(
        _notificationDesktopMeta,
        notificationDesktop.isAcceptableOrUnknown(
          data['notification_desktop']!,
          _notificationDesktopMeta,
        ),
      );
    }
    if (data.containsKey('notification_mobile')) {
      context.handle(
        _notificationMobileMeta,
        notificationMobile.isAcceptableOrUnknown(
          data['notification_mobile']!,
          _notificationMobileMeta,
        ),
      );
    }
    if (data.containsKey('notification_mute')) {
      context.handle(
        _notificationMuteMeta,
        notificationMute.isAcceptableOrUnknown(
          data['notification_mute']!,
          _notificationMuteMeta,
        ),
      );
    }
    if (data.containsKey('hashtags')) {
      context.handle(
        _hashtagsMeta,
        hashtags.isAcceptableOrUnknown(data['hashtags']!, _hashtagsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {channelId};
  @override
  ChannelRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChannelRow(
      channelId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}channel_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      purpose: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}purpose'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      encrypted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}encrypted'],
      )!,
      isJoined: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_joined'],
      )!,
      isStar: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_star'],
      )!,
      unread: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread'],
      )!,
      unreadMention: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread_mention'],
      )!,
      unreadComment: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread_comment'],
      )!,
      unreadMentionComment: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unread_mention_comment'],
      )!,
      unreadThread: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}unread_thread'],
      )!,
      subscribes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subscribes'],
      )!,
      members: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}members'],
      )!,
      brokenUsers: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}broken_users'],
      )!,
      channelKeyEnc: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}channel_key_enc'],
      )!,
      totalMemberCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_member_count'],
      )!,
      creatorId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}creator_id'],
      )!,
      lastPostAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_post_at'],
      )!,
      lastViewAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_view_at'],
      )!,
      lastViewCommentAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_view_comment_at'],
      )!,
      channelOrderTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}channel_order_time'],
      )!,
      hideGlobalAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}hide_global_at'],
      )!,
      lastHideAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_hide_at'],
      )!,
      notificationDesktop: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notification_desktop'],
      )!,
      notificationMobile: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notification_mobile'],
      )!,
      notificationMute: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}notification_mute'],
      )!,
      hashtags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hashtags'],
      )!,
    );
  }

  @override
  $ChannelRowsTable createAlias(String alias) {
    return $ChannelRowsTable(attachedDatabase, alias);
  }
}

class ChannelRow extends DataClass implements Insertable<ChannelRow> {
  final int channelId;
  final String name;
  final String purpose;
  final String type;
  final bool encrypted;
  final bool isJoined;
  final bool isStar;
  final int unread;
  final int unreadMention;
  final int unreadComment;
  final int unreadMentionComment;

  /// thread_id → 未读数，JSON 文本
  final String unreadThread;

  /// 订阅的 thread/post id，JSON 数组文本
  final String subscribes;

  /// 成员 user_id 列表，JSON 数组文本
  final String members;

  /// 在这个频道里解不开消息的成员 user_id，JSON 数组文本
  /// （`client.channel.brokenuser` 加、`channel.rescue` 减）
  final String brokenUsers;
  final String channelKeyEnc;
  final int totalMemberCount;
  final int creatorId;
  final int lastPostAt;
  final int lastViewAt;
  final int lastViewCommentAt;
  final int channelOrderTime;
  final int hideGlobalAt;
  final int lastHideAt;
  final String notificationDesktop;
  final String notificationMobile;
  final bool notificationMute;

  /// 频道里用过的标签，JSON 数组文本。
  ///
  /// 对应原版 `ChatChannel.hashtags`：进频道时（`enter` 成功后）由
  /// `Channel.Hashtag/list` 拉回来落库（`AccountManager.lambda$fetchChannelHashtag$10`
  /// → `DatabaseHelper.setChannelHashtags`），发消息时输入框的 `#` 联想就读这一列。
  final String hashtags;
  const ChannelRow({
    required this.channelId,
    required this.name,
    required this.purpose,
    required this.type,
    required this.encrypted,
    required this.isJoined,
    required this.isStar,
    required this.unread,
    required this.unreadMention,
    required this.unreadComment,
    required this.unreadMentionComment,
    required this.unreadThread,
    required this.subscribes,
    required this.members,
    required this.brokenUsers,
    required this.channelKeyEnc,
    required this.totalMemberCount,
    required this.creatorId,
    required this.lastPostAt,
    required this.lastViewAt,
    required this.lastViewCommentAt,
    required this.channelOrderTime,
    required this.hideGlobalAt,
    required this.lastHideAt,
    required this.notificationDesktop,
    required this.notificationMobile,
    required this.notificationMute,
    required this.hashtags,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['channel_id'] = Variable<int>(channelId);
    map['name'] = Variable<String>(name);
    map['purpose'] = Variable<String>(purpose);
    map['type'] = Variable<String>(type);
    map['encrypted'] = Variable<bool>(encrypted);
    map['is_joined'] = Variable<bool>(isJoined);
    map['is_star'] = Variable<bool>(isStar);
    map['unread'] = Variable<int>(unread);
    map['unread_mention'] = Variable<int>(unreadMention);
    map['unread_comment'] = Variable<int>(unreadComment);
    map['unread_mention_comment'] = Variable<int>(unreadMentionComment);
    map['unread_thread'] = Variable<String>(unreadThread);
    map['subscribes'] = Variable<String>(subscribes);
    map['members'] = Variable<String>(members);
    map['broken_users'] = Variable<String>(brokenUsers);
    map['channel_key_enc'] = Variable<String>(channelKeyEnc);
    map['total_member_count'] = Variable<int>(totalMemberCount);
    map['creator_id'] = Variable<int>(creatorId);
    map['last_post_at'] = Variable<int>(lastPostAt);
    map['last_view_at'] = Variable<int>(lastViewAt);
    map['last_view_comment_at'] = Variable<int>(lastViewCommentAt);
    map['channel_order_time'] = Variable<int>(channelOrderTime);
    map['hide_global_at'] = Variable<int>(hideGlobalAt);
    map['last_hide_at'] = Variable<int>(lastHideAt);
    map['notification_desktop'] = Variable<String>(notificationDesktop);
    map['notification_mobile'] = Variable<String>(notificationMobile);
    map['notification_mute'] = Variable<bool>(notificationMute);
    map['hashtags'] = Variable<String>(hashtags);
    return map;
  }

  ChannelRowsCompanion toCompanion(bool nullToAbsent) {
    return ChannelRowsCompanion(
      channelId: Value(channelId),
      name: Value(name),
      purpose: Value(purpose),
      type: Value(type),
      encrypted: Value(encrypted),
      isJoined: Value(isJoined),
      isStar: Value(isStar),
      unread: Value(unread),
      unreadMention: Value(unreadMention),
      unreadComment: Value(unreadComment),
      unreadMentionComment: Value(unreadMentionComment),
      unreadThread: Value(unreadThread),
      subscribes: Value(subscribes),
      members: Value(members),
      brokenUsers: Value(brokenUsers),
      channelKeyEnc: Value(channelKeyEnc),
      totalMemberCount: Value(totalMemberCount),
      creatorId: Value(creatorId),
      lastPostAt: Value(lastPostAt),
      lastViewAt: Value(lastViewAt),
      lastViewCommentAt: Value(lastViewCommentAt),
      channelOrderTime: Value(channelOrderTime),
      hideGlobalAt: Value(hideGlobalAt),
      lastHideAt: Value(lastHideAt),
      notificationDesktop: Value(notificationDesktop),
      notificationMobile: Value(notificationMobile),
      notificationMute: Value(notificationMute),
      hashtags: Value(hashtags),
    );
  }

  factory ChannelRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChannelRow(
      channelId: serializer.fromJson<int>(json['channelId']),
      name: serializer.fromJson<String>(json['name']),
      purpose: serializer.fromJson<String>(json['purpose']),
      type: serializer.fromJson<String>(json['type']),
      encrypted: serializer.fromJson<bool>(json['encrypted']),
      isJoined: serializer.fromJson<bool>(json['isJoined']),
      isStar: serializer.fromJson<bool>(json['isStar']),
      unread: serializer.fromJson<int>(json['unread']),
      unreadMention: serializer.fromJson<int>(json['unreadMention']),
      unreadComment: serializer.fromJson<int>(json['unreadComment']),
      unreadMentionComment: serializer.fromJson<int>(
        json['unreadMentionComment'],
      ),
      unreadThread: serializer.fromJson<String>(json['unreadThread']),
      subscribes: serializer.fromJson<String>(json['subscribes']),
      members: serializer.fromJson<String>(json['members']),
      brokenUsers: serializer.fromJson<String>(json['brokenUsers']),
      channelKeyEnc: serializer.fromJson<String>(json['channelKeyEnc']),
      totalMemberCount: serializer.fromJson<int>(json['totalMemberCount']),
      creatorId: serializer.fromJson<int>(json['creatorId']),
      lastPostAt: serializer.fromJson<int>(json['lastPostAt']),
      lastViewAt: serializer.fromJson<int>(json['lastViewAt']),
      lastViewCommentAt: serializer.fromJson<int>(json['lastViewCommentAt']),
      channelOrderTime: serializer.fromJson<int>(json['channelOrderTime']),
      hideGlobalAt: serializer.fromJson<int>(json['hideGlobalAt']),
      lastHideAt: serializer.fromJson<int>(json['lastHideAt']),
      notificationDesktop: serializer.fromJson<String>(
        json['notificationDesktop'],
      ),
      notificationMobile: serializer.fromJson<String>(
        json['notificationMobile'],
      ),
      notificationMute: serializer.fromJson<bool>(json['notificationMute']),
      hashtags: serializer.fromJson<String>(json['hashtags']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'channelId': serializer.toJson<int>(channelId),
      'name': serializer.toJson<String>(name),
      'purpose': serializer.toJson<String>(purpose),
      'type': serializer.toJson<String>(type),
      'encrypted': serializer.toJson<bool>(encrypted),
      'isJoined': serializer.toJson<bool>(isJoined),
      'isStar': serializer.toJson<bool>(isStar),
      'unread': serializer.toJson<int>(unread),
      'unreadMention': serializer.toJson<int>(unreadMention),
      'unreadComment': serializer.toJson<int>(unreadComment),
      'unreadMentionComment': serializer.toJson<int>(unreadMentionComment),
      'unreadThread': serializer.toJson<String>(unreadThread),
      'subscribes': serializer.toJson<String>(subscribes),
      'members': serializer.toJson<String>(members),
      'brokenUsers': serializer.toJson<String>(brokenUsers),
      'channelKeyEnc': serializer.toJson<String>(channelKeyEnc),
      'totalMemberCount': serializer.toJson<int>(totalMemberCount),
      'creatorId': serializer.toJson<int>(creatorId),
      'lastPostAt': serializer.toJson<int>(lastPostAt),
      'lastViewAt': serializer.toJson<int>(lastViewAt),
      'lastViewCommentAt': serializer.toJson<int>(lastViewCommentAt),
      'channelOrderTime': serializer.toJson<int>(channelOrderTime),
      'hideGlobalAt': serializer.toJson<int>(hideGlobalAt),
      'lastHideAt': serializer.toJson<int>(lastHideAt),
      'notificationDesktop': serializer.toJson<String>(notificationDesktop),
      'notificationMobile': serializer.toJson<String>(notificationMobile),
      'notificationMute': serializer.toJson<bool>(notificationMute),
      'hashtags': serializer.toJson<String>(hashtags),
    };
  }

  ChannelRow copyWith({
    int? channelId,
    String? name,
    String? purpose,
    String? type,
    bool? encrypted,
    bool? isJoined,
    bool? isStar,
    int? unread,
    int? unreadMention,
    int? unreadComment,
    int? unreadMentionComment,
    String? unreadThread,
    String? subscribes,
    String? members,
    String? brokenUsers,
    String? channelKeyEnc,
    int? totalMemberCount,
    int? creatorId,
    int? lastPostAt,
    int? lastViewAt,
    int? lastViewCommentAt,
    int? channelOrderTime,
    int? hideGlobalAt,
    int? lastHideAt,
    String? notificationDesktop,
    String? notificationMobile,
    bool? notificationMute,
    String? hashtags,
  }) => ChannelRow(
    channelId: channelId ?? this.channelId,
    name: name ?? this.name,
    purpose: purpose ?? this.purpose,
    type: type ?? this.type,
    encrypted: encrypted ?? this.encrypted,
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
    creatorId: creatorId ?? this.creatorId,
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
  ChannelRow copyWithCompanion(ChannelRowsCompanion data) {
    return ChannelRow(
      channelId: data.channelId.present ? data.channelId.value : this.channelId,
      name: data.name.present ? data.name.value : this.name,
      purpose: data.purpose.present ? data.purpose.value : this.purpose,
      type: data.type.present ? data.type.value : this.type,
      encrypted: data.encrypted.present ? data.encrypted.value : this.encrypted,
      isJoined: data.isJoined.present ? data.isJoined.value : this.isJoined,
      isStar: data.isStar.present ? data.isStar.value : this.isStar,
      unread: data.unread.present ? data.unread.value : this.unread,
      unreadMention: data.unreadMention.present
          ? data.unreadMention.value
          : this.unreadMention,
      unreadComment: data.unreadComment.present
          ? data.unreadComment.value
          : this.unreadComment,
      unreadMentionComment: data.unreadMentionComment.present
          ? data.unreadMentionComment.value
          : this.unreadMentionComment,
      unreadThread: data.unreadThread.present
          ? data.unreadThread.value
          : this.unreadThread,
      subscribes: data.subscribes.present
          ? data.subscribes.value
          : this.subscribes,
      members: data.members.present ? data.members.value : this.members,
      brokenUsers: data.brokenUsers.present
          ? data.brokenUsers.value
          : this.brokenUsers,
      channelKeyEnc: data.channelKeyEnc.present
          ? data.channelKeyEnc.value
          : this.channelKeyEnc,
      totalMemberCount: data.totalMemberCount.present
          ? data.totalMemberCount.value
          : this.totalMemberCount,
      creatorId: data.creatorId.present ? data.creatorId.value : this.creatorId,
      lastPostAt: data.lastPostAt.present
          ? data.lastPostAt.value
          : this.lastPostAt,
      lastViewAt: data.lastViewAt.present
          ? data.lastViewAt.value
          : this.lastViewAt,
      lastViewCommentAt: data.lastViewCommentAt.present
          ? data.lastViewCommentAt.value
          : this.lastViewCommentAt,
      channelOrderTime: data.channelOrderTime.present
          ? data.channelOrderTime.value
          : this.channelOrderTime,
      hideGlobalAt: data.hideGlobalAt.present
          ? data.hideGlobalAt.value
          : this.hideGlobalAt,
      lastHideAt: data.lastHideAt.present
          ? data.lastHideAt.value
          : this.lastHideAt,
      notificationDesktop: data.notificationDesktop.present
          ? data.notificationDesktop.value
          : this.notificationDesktop,
      notificationMobile: data.notificationMobile.present
          ? data.notificationMobile.value
          : this.notificationMobile,
      notificationMute: data.notificationMute.present
          ? data.notificationMute.value
          : this.notificationMute,
      hashtags: data.hashtags.present ? data.hashtags.value : this.hashtags,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChannelRow(')
          ..write('channelId: $channelId, ')
          ..write('name: $name, ')
          ..write('purpose: $purpose, ')
          ..write('type: $type, ')
          ..write('encrypted: $encrypted, ')
          ..write('isJoined: $isJoined, ')
          ..write('isStar: $isStar, ')
          ..write('unread: $unread, ')
          ..write('unreadMention: $unreadMention, ')
          ..write('unreadComment: $unreadComment, ')
          ..write('unreadMentionComment: $unreadMentionComment, ')
          ..write('unreadThread: $unreadThread, ')
          ..write('subscribes: $subscribes, ')
          ..write('members: $members, ')
          ..write('brokenUsers: $brokenUsers, ')
          ..write('channelKeyEnc: $channelKeyEnc, ')
          ..write('totalMemberCount: $totalMemberCount, ')
          ..write('creatorId: $creatorId, ')
          ..write('lastPostAt: $lastPostAt, ')
          ..write('lastViewAt: $lastViewAt, ')
          ..write('lastViewCommentAt: $lastViewCommentAt, ')
          ..write('channelOrderTime: $channelOrderTime, ')
          ..write('hideGlobalAt: $hideGlobalAt, ')
          ..write('lastHideAt: $lastHideAt, ')
          ..write('notificationDesktop: $notificationDesktop, ')
          ..write('notificationMobile: $notificationMobile, ')
          ..write('notificationMute: $notificationMute, ')
          ..write('hashtags: $hashtags')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    channelId,
    name,
    purpose,
    type,
    encrypted,
    isJoined,
    isStar,
    unread,
    unreadMention,
    unreadComment,
    unreadMentionComment,
    unreadThread,
    subscribes,
    members,
    brokenUsers,
    channelKeyEnc,
    totalMemberCount,
    creatorId,
    lastPostAt,
    lastViewAt,
    lastViewCommentAt,
    channelOrderTime,
    hideGlobalAt,
    lastHideAt,
    notificationDesktop,
    notificationMobile,
    notificationMute,
    hashtags,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChannelRow &&
          other.channelId == this.channelId &&
          other.name == this.name &&
          other.purpose == this.purpose &&
          other.type == this.type &&
          other.encrypted == this.encrypted &&
          other.isJoined == this.isJoined &&
          other.isStar == this.isStar &&
          other.unread == this.unread &&
          other.unreadMention == this.unreadMention &&
          other.unreadComment == this.unreadComment &&
          other.unreadMentionComment == this.unreadMentionComment &&
          other.unreadThread == this.unreadThread &&
          other.subscribes == this.subscribes &&
          other.members == this.members &&
          other.brokenUsers == this.brokenUsers &&
          other.channelKeyEnc == this.channelKeyEnc &&
          other.totalMemberCount == this.totalMemberCount &&
          other.creatorId == this.creatorId &&
          other.lastPostAt == this.lastPostAt &&
          other.lastViewAt == this.lastViewAt &&
          other.lastViewCommentAt == this.lastViewCommentAt &&
          other.channelOrderTime == this.channelOrderTime &&
          other.hideGlobalAt == this.hideGlobalAt &&
          other.lastHideAt == this.lastHideAt &&
          other.notificationDesktop == this.notificationDesktop &&
          other.notificationMobile == this.notificationMobile &&
          other.notificationMute == this.notificationMute &&
          other.hashtags == this.hashtags);
}

class ChannelRowsCompanion extends UpdateCompanion<ChannelRow> {
  final Value<int> channelId;
  final Value<String> name;
  final Value<String> purpose;
  final Value<String> type;
  final Value<bool> encrypted;
  final Value<bool> isJoined;
  final Value<bool> isStar;
  final Value<int> unread;
  final Value<int> unreadMention;
  final Value<int> unreadComment;
  final Value<int> unreadMentionComment;
  final Value<String> unreadThread;
  final Value<String> subscribes;
  final Value<String> members;
  final Value<String> brokenUsers;
  final Value<String> channelKeyEnc;
  final Value<int> totalMemberCount;
  final Value<int> creatorId;
  final Value<int> lastPostAt;
  final Value<int> lastViewAt;
  final Value<int> lastViewCommentAt;
  final Value<int> channelOrderTime;
  final Value<int> hideGlobalAt;
  final Value<int> lastHideAt;
  final Value<String> notificationDesktop;
  final Value<String> notificationMobile;
  final Value<bool> notificationMute;
  final Value<String> hashtags;
  const ChannelRowsCompanion({
    this.channelId = const Value.absent(),
    this.name = const Value.absent(),
    this.purpose = const Value.absent(),
    this.type = const Value.absent(),
    this.encrypted = const Value.absent(),
    this.isJoined = const Value.absent(),
    this.isStar = const Value.absent(),
    this.unread = const Value.absent(),
    this.unreadMention = const Value.absent(),
    this.unreadComment = const Value.absent(),
    this.unreadMentionComment = const Value.absent(),
    this.unreadThread = const Value.absent(),
    this.subscribes = const Value.absent(),
    this.members = const Value.absent(),
    this.brokenUsers = const Value.absent(),
    this.channelKeyEnc = const Value.absent(),
    this.totalMemberCount = const Value.absent(),
    this.creatorId = const Value.absent(),
    this.lastPostAt = const Value.absent(),
    this.lastViewAt = const Value.absent(),
    this.lastViewCommentAt = const Value.absent(),
    this.channelOrderTime = const Value.absent(),
    this.hideGlobalAt = const Value.absent(),
    this.lastHideAt = const Value.absent(),
    this.notificationDesktop = const Value.absent(),
    this.notificationMobile = const Value.absent(),
    this.notificationMute = const Value.absent(),
    this.hashtags = const Value.absent(),
  });
  ChannelRowsCompanion.insert({
    this.channelId = const Value.absent(),
    this.name = const Value.absent(),
    this.purpose = const Value.absent(),
    this.type = const Value.absent(),
    this.encrypted = const Value.absent(),
    this.isJoined = const Value.absent(),
    this.isStar = const Value.absent(),
    this.unread = const Value.absent(),
    this.unreadMention = const Value.absent(),
    this.unreadComment = const Value.absent(),
    this.unreadMentionComment = const Value.absent(),
    this.unreadThread = const Value.absent(),
    this.subscribes = const Value.absent(),
    this.members = const Value.absent(),
    this.brokenUsers = const Value.absent(),
    this.channelKeyEnc = const Value.absent(),
    this.totalMemberCount = const Value.absent(),
    this.creatorId = const Value.absent(),
    this.lastPostAt = const Value.absent(),
    this.lastViewAt = const Value.absent(),
    this.lastViewCommentAt = const Value.absent(),
    this.channelOrderTime = const Value.absent(),
    this.hideGlobalAt = const Value.absent(),
    this.lastHideAt = const Value.absent(),
    this.notificationDesktop = const Value.absent(),
    this.notificationMobile = const Value.absent(),
    this.notificationMute = const Value.absent(),
    this.hashtags = const Value.absent(),
  });
  static Insertable<ChannelRow> custom({
    Expression<int>? channelId,
    Expression<String>? name,
    Expression<String>? purpose,
    Expression<String>? type,
    Expression<bool>? encrypted,
    Expression<bool>? isJoined,
    Expression<bool>? isStar,
    Expression<int>? unread,
    Expression<int>? unreadMention,
    Expression<int>? unreadComment,
    Expression<int>? unreadMentionComment,
    Expression<String>? unreadThread,
    Expression<String>? subscribes,
    Expression<String>? members,
    Expression<String>? brokenUsers,
    Expression<String>? channelKeyEnc,
    Expression<int>? totalMemberCount,
    Expression<int>? creatorId,
    Expression<int>? lastPostAt,
    Expression<int>? lastViewAt,
    Expression<int>? lastViewCommentAt,
    Expression<int>? channelOrderTime,
    Expression<int>? hideGlobalAt,
    Expression<int>? lastHideAt,
    Expression<String>? notificationDesktop,
    Expression<String>? notificationMobile,
    Expression<bool>? notificationMute,
    Expression<String>? hashtags,
  }) {
    return RawValuesInsertable({
      if (channelId != null) 'channel_id': channelId,
      if (name != null) 'name': name,
      if (purpose != null) 'purpose': purpose,
      if (type != null) 'type': type,
      if (encrypted != null) 'encrypted': encrypted,
      if (isJoined != null) 'is_joined': isJoined,
      if (isStar != null) 'is_star': isStar,
      if (unread != null) 'unread': unread,
      if (unreadMention != null) 'unread_mention': unreadMention,
      if (unreadComment != null) 'unread_comment': unreadComment,
      if (unreadMentionComment != null)
        'unread_mention_comment': unreadMentionComment,
      if (unreadThread != null) 'unread_thread': unreadThread,
      if (subscribes != null) 'subscribes': subscribes,
      if (members != null) 'members': members,
      if (brokenUsers != null) 'broken_users': brokenUsers,
      if (channelKeyEnc != null) 'channel_key_enc': channelKeyEnc,
      if (totalMemberCount != null) 'total_member_count': totalMemberCount,
      if (creatorId != null) 'creator_id': creatorId,
      if (lastPostAt != null) 'last_post_at': lastPostAt,
      if (lastViewAt != null) 'last_view_at': lastViewAt,
      if (lastViewCommentAt != null) 'last_view_comment_at': lastViewCommentAt,
      if (channelOrderTime != null) 'channel_order_time': channelOrderTime,
      if (hideGlobalAt != null) 'hide_global_at': hideGlobalAt,
      if (lastHideAt != null) 'last_hide_at': lastHideAt,
      if (notificationDesktop != null)
        'notification_desktop': notificationDesktop,
      if (notificationMobile != null) 'notification_mobile': notificationMobile,
      if (notificationMute != null) 'notification_mute': notificationMute,
      if (hashtags != null) 'hashtags': hashtags,
    });
  }

  ChannelRowsCompanion copyWith({
    Value<int>? channelId,
    Value<String>? name,
    Value<String>? purpose,
    Value<String>? type,
    Value<bool>? encrypted,
    Value<bool>? isJoined,
    Value<bool>? isStar,
    Value<int>? unread,
    Value<int>? unreadMention,
    Value<int>? unreadComment,
    Value<int>? unreadMentionComment,
    Value<String>? unreadThread,
    Value<String>? subscribes,
    Value<String>? members,
    Value<String>? brokenUsers,
    Value<String>? channelKeyEnc,
    Value<int>? totalMemberCount,
    Value<int>? creatorId,
    Value<int>? lastPostAt,
    Value<int>? lastViewAt,
    Value<int>? lastViewCommentAt,
    Value<int>? channelOrderTime,
    Value<int>? hideGlobalAt,
    Value<int>? lastHideAt,
    Value<String>? notificationDesktop,
    Value<String>? notificationMobile,
    Value<bool>? notificationMute,
    Value<String>? hashtags,
  }) {
    return ChannelRowsCompanion(
      channelId: channelId ?? this.channelId,
      name: name ?? this.name,
      purpose: purpose ?? this.purpose,
      type: type ?? this.type,
      encrypted: encrypted ?? this.encrypted,
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
      creatorId: creatorId ?? this.creatorId,
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

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (channelId.present) {
      map['channel_id'] = Variable<int>(channelId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (purpose.present) {
      map['purpose'] = Variable<String>(purpose.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (encrypted.present) {
      map['encrypted'] = Variable<bool>(encrypted.value);
    }
    if (isJoined.present) {
      map['is_joined'] = Variable<bool>(isJoined.value);
    }
    if (isStar.present) {
      map['is_star'] = Variable<bool>(isStar.value);
    }
    if (unread.present) {
      map['unread'] = Variable<int>(unread.value);
    }
    if (unreadMention.present) {
      map['unread_mention'] = Variable<int>(unreadMention.value);
    }
    if (unreadComment.present) {
      map['unread_comment'] = Variable<int>(unreadComment.value);
    }
    if (unreadMentionComment.present) {
      map['unread_mention_comment'] = Variable<int>(unreadMentionComment.value);
    }
    if (unreadThread.present) {
      map['unread_thread'] = Variable<String>(unreadThread.value);
    }
    if (subscribes.present) {
      map['subscribes'] = Variable<String>(subscribes.value);
    }
    if (members.present) {
      map['members'] = Variable<String>(members.value);
    }
    if (brokenUsers.present) {
      map['broken_users'] = Variable<String>(brokenUsers.value);
    }
    if (channelKeyEnc.present) {
      map['channel_key_enc'] = Variable<String>(channelKeyEnc.value);
    }
    if (totalMemberCount.present) {
      map['total_member_count'] = Variable<int>(totalMemberCount.value);
    }
    if (creatorId.present) {
      map['creator_id'] = Variable<int>(creatorId.value);
    }
    if (lastPostAt.present) {
      map['last_post_at'] = Variable<int>(lastPostAt.value);
    }
    if (lastViewAt.present) {
      map['last_view_at'] = Variable<int>(lastViewAt.value);
    }
    if (lastViewCommentAt.present) {
      map['last_view_comment_at'] = Variable<int>(lastViewCommentAt.value);
    }
    if (channelOrderTime.present) {
      map['channel_order_time'] = Variable<int>(channelOrderTime.value);
    }
    if (hideGlobalAt.present) {
      map['hide_global_at'] = Variable<int>(hideGlobalAt.value);
    }
    if (lastHideAt.present) {
      map['last_hide_at'] = Variable<int>(lastHideAt.value);
    }
    if (notificationDesktop.present) {
      map['notification_desktop'] = Variable<String>(notificationDesktop.value);
    }
    if (notificationMobile.present) {
      map['notification_mobile'] = Variable<String>(notificationMobile.value);
    }
    if (notificationMute.present) {
      map['notification_mute'] = Variable<bool>(notificationMute.value);
    }
    if (hashtags.present) {
      map['hashtags'] = Variable<String>(hashtags.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChannelRowsCompanion(')
          ..write('channelId: $channelId, ')
          ..write('name: $name, ')
          ..write('purpose: $purpose, ')
          ..write('type: $type, ')
          ..write('encrypted: $encrypted, ')
          ..write('isJoined: $isJoined, ')
          ..write('isStar: $isStar, ')
          ..write('unread: $unread, ')
          ..write('unreadMention: $unreadMention, ')
          ..write('unreadComment: $unreadComment, ')
          ..write('unreadMentionComment: $unreadMentionComment, ')
          ..write('unreadThread: $unreadThread, ')
          ..write('subscribes: $subscribes, ')
          ..write('members: $members, ')
          ..write('brokenUsers: $brokenUsers, ')
          ..write('channelKeyEnc: $channelKeyEnc, ')
          ..write('totalMemberCount: $totalMemberCount, ')
          ..write('creatorId: $creatorId, ')
          ..write('lastPostAt: $lastPostAt, ')
          ..write('lastViewAt: $lastViewAt, ')
          ..write('lastViewCommentAt: $lastViewCommentAt, ')
          ..write('channelOrderTime: $channelOrderTime, ')
          ..write('hideGlobalAt: $hideGlobalAt, ')
          ..write('lastHideAt: $lastHideAt, ')
          ..write('notificationDesktop: $notificationDesktop, ')
          ..write('notificationMobile: $notificationMobile, ')
          ..write('notificationMute: $notificationMute, ')
          ..write('hashtags: $hashtags')
          ..write(')'))
        .toString();
  }
}

class $UserRowsTable extends UserRows with TableInfo<$UserRowsTable, UserRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UserRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _nicknameMeta = const VerificationMeta(
    'nickname',
  );
  @override
  late final GeneratedColumn<String> nickname = GeneratedColumn<String>(
    'nickname',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _humanTypeMeta = const VerificationMeta(
    'humanType',
  );
  @override
  late final GeneratedColumn<String> humanType = GeneratedColumn<String>(
    'human_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _botTypeMeta = const VerificationMeta(
    'botType',
  );
  @override
  late final GeneratedColumn<String> botType = GeneratedColumn<String>(
    'bot_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _appIdMeta = const VerificationMeta('appId');
  @override
  late final GeneratedColumn<int> appId = GeneratedColumn<int>(
    'app_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _dsmUidMeta = const VerificationMeta('dsmUid');
  @override
  late final GeneratedColumn<int> dsmUid = GeneratedColumn<int>(
    'dsm_uid',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _avatarVersionMeta = const VerificationMeta(
    'avatarVersion',
  );
  @override
  late final GeneratedColumn<int> avatarVersion = GeneratedColumn<int>(
    'avatar_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _avatarColorMeta = const VerificationMeta(
    'avatarColor',
  );
  @override
  late final GeneratedColumn<String> avatarColor = GeneratedColumn<String>(
    'avatar_color',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _emailMeta = const VerificationMeta('email');
  @override
  late final GeneratedColumn<String> email = GeneratedColumn<String>(
    'email',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _publicKeyMeta = const VerificationMeta(
    'publicKey',
  );
  @override
  late final GeneratedColumn<String> publicKey = GeneratedColumn<String>(
    'public_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _privateKeyEncMeta = const VerificationMeta(
    'privateKeyEnc',
  );
  @override
  late final GeneratedColumn<String> privateKeyEnc = GeneratedColumn<String>(
    'private_key_enc',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _isDisabledMeta = const VerificationMeta(
    'isDisabled',
  );
  @override
  late final GeneratedColumn<bool> isDisabled = GeneratedColumn<bool>(
    'is_disabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_disabled" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isDeletedMeta = const VerificationMeta(
    'isDeleted',
  );
  @override
  late final GeneratedColumn<bool> isDeleted = GeneratedColumn<bool>(
    'is_deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _hasUrlMeta = const VerificationMeta('hasUrl');
  @override
  late final GeneratedColumn<bool> hasUrl = GeneratedColumn<bool>(
    'has_url',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_url" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _botPropsMeta = const VerificationMeta(
    'botProps',
  );
  @override
  late final GeneratedColumn<String> botProps = GeneratedColumn<String>(
    'bot_props',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _isAlwaysOfflineMeta = const VerificationMeta(
    'isAlwaysOffline',
  );
  @override
  late final GeneratedColumn<bool> isAlwaysOffline = GeneratedColumn<bool>(
    'is_always_offline',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_always_offline" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createAtMeta = const VerificationMeta(
    'createAt',
  );
  @override
  late final GeneratedColumn<int> createAt = GeneratedColumn<int>(
    'create_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _updateAtMeta = const VerificationMeta(
    'updateAt',
  );
  @override
  late final GeneratedColumn<int> updateAt = GeneratedColumn<int>(
    'update_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _deleteAtMeta = const VerificationMeta(
    'deleteAt',
  );
  @override
  late final GeneratedColumn<int> deleteAt = GeneratedColumn<int>(
    'delete_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    username,
    nickname,
    type,
    status,
    humanType,
    botType,
    appId,
    dsmUid,
    avatarVersion,
    avatarColor,
    email,
    description,
    publicKey,
    privateKeyEnc,
    isDisabled,
    isDeleted,
    hasUrl,
    botProps,
    isAlwaysOffline,
    createAt,
    updateAt,
    deleteAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'user_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<UserRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    }
    if (data.containsKey('nickname')) {
      context.handle(
        _nicknameMeta,
        nickname.isAcceptableOrUnknown(data['nickname']!, _nicknameMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('human_type')) {
      context.handle(
        _humanTypeMeta,
        humanType.isAcceptableOrUnknown(data['human_type']!, _humanTypeMeta),
      );
    }
    if (data.containsKey('bot_type')) {
      context.handle(
        _botTypeMeta,
        botType.isAcceptableOrUnknown(data['bot_type']!, _botTypeMeta),
      );
    }
    if (data.containsKey('app_id')) {
      context.handle(
        _appIdMeta,
        appId.isAcceptableOrUnknown(data['app_id']!, _appIdMeta),
      );
    }
    if (data.containsKey('dsm_uid')) {
      context.handle(
        _dsmUidMeta,
        dsmUid.isAcceptableOrUnknown(data['dsm_uid']!, _dsmUidMeta),
      );
    }
    if (data.containsKey('avatar_version')) {
      context.handle(
        _avatarVersionMeta,
        avatarVersion.isAcceptableOrUnknown(
          data['avatar_version']!,
          _avatarVersionMeta,
        ),
      );
    }
    if (data.containsKey('avatar_color')) {
      context.handle(
        _avatarColorMeta,
        avatarColor.isAcceptableOrUnknown(
          data['avatar_color']!,
          _avatarColorMeta,
        ),
      );
    }
    if (data.containsKey('email')) {
      context.handle(
        _emailMeta,
        email.isAcceptableOrUnknown(data['email']!, _emailMeta),
      );
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('public_key')) {
      context.handle(
        _publicKeyMeta,
        publicKey.isAcceptableOrUnknown(data['public_key']!, _publicKeyMeta),
      );
    }
    if (data.containsKey('private_key_enc')) {
      context.handle(
        _privateKeyEncMeta,
        privateKeyEnc.isAcceptableOrUnknown(
          data['private_key_enc']!,
          _privateKeyEncMeta,
        ),
      );
    }
    if (data.containsKey('is_disabled')) {
      context.handle(
        _isDisabledMeta,
        isDisabled.isAcceptableOrUnknown(data['is_disabled']!, _isDisabledMeta),
      );
    }
    if (data.containsKey('is_deleted')) {
      context.handle(
        _isDeletedMeta,
        isDeleted.isAcceptableOrUnknown(data['is_deleted']!, _isDeletedMeta),
      );
    }
    if (data.containsKey('has_url')) {
      context.handle(
        _hasUrlMeta,
        hasUrl.isAcceptableOrUnknown(data['has_url']!, _hasUrlMeta),
      );
    }
    if (data.containsKey('bot_props')) {
      context.handle(
        _botPropsMeta,
        botProps.isAcceptableOrUnknown(data['bot_props']!, _botPropsMeta),
      );
    }
    if (data.containsKey('is_always_offline')) {
      context.handle(
        _isAlwaysOfflineMeta,
        isAlwaysOffline.isAcceptableOrUnknown(
          data['is_always_offline']!,
          _isAlwaysOfflineMeta,
        ),
      );
    }
    if (data.containsKey('create_at')) {
      context.handle(
        _createAtMeta,
        createAt.isAcceptableOrUnknown(data['create_at']!, _createAtMeta),
      );
    }
    if (data.containsKey('update_at')) {
      context.handle(
        _updateAtMeta,
        updateAt.isAcceptableOrUnknown(data['update_at']!, _updateAtMeta),
      );
    }
    if (data.containsKey('delete_at')) {
      context.handle(
        _deleteAtMeta,
        deleteAt.isAcceptableOrUnknown(data['delete_at']!, _deleteAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId};
  @override
  UserRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UserRow(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}user_id'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      nickname: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}nickname'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      humanType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}human_type'],
      )!,
      botType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bot_type'],
      )!,
      appId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}app_id'],
      )!,
      dsmUid: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}dsm_uid'],
      )!,
      avatarVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}avatar_version'],
      )!,
      avatarColor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}avatar_color'],
      )!,
      email: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}email'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      )!,
      publicKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}public_key'],
      )!,
      privateKeyEnc: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}private_key_enc'],
      )!,
      isDisabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_disabled'],
      )!,
      isDeleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_deleted'],
      )!,
      hasUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_url'],
      )!,
      botProps: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bot_props'],
      )!,
      isAlwaysOffline: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_always_offline'],
      )!,
      createAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_at'],
      )!,
      updateAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}update_at'],
      )!,
      deleteAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delete_at'],
      )!,
    );
  }

  @override
  $UserRowsTable createAlias(String alias) {
    return $UserRowsTable(attachedDatabase, alias);
  }
}

class UserRow extends DataClass implements Insertable<UserRow> {
  final int userId;
  final String username;
  final String nickname;
  final String type;
  final String status;
  final String humanType;
  final String botType;
  final int appId;
  final int dsmUid;
  final int avatarVersion;
  final String avatarColor;
  final String email;
  final String description;
  final String publicKey;
  final String privateKeyEnc;
  final bool isDisabled;
  final bool isDeleted;
  final bool hasUrl;

  /// 机器人附加信息 JSON：`slash_props` / `chatbot_props` / `bot_props`
  /// （`bot_type = slash` 的斜杠命令、chatbot 的欢迎语都在这里）。
  /// 原来只建了 botType 一列，斜杠命令读回来就没了 —— 跟消息的 props 同一类坑。
  final String botProps;
  final bool isAlwaysOffline;
  final int createAt;
  final int updateAt;
  final int deleteAt;
  const UserRow({
    required this.userId,
    required this.username,
    required this.nickname,
    required this.type,
    required this.status,
    required this.humanType,
    required this.botType,
    required this.appId,
    required this.dsmUid,
    required this.avatarVersion,
    required this.avatarColor,
    required this.email,
    required this.description,
    required this.publicKey,
    required this.privateKeyEnc,
    required this.isDisabled,
    required this.isDeleted,
    required this.hasUrl,
    required this.botProps,
    required this.isAlwaysOffline,
    required this.createAt,
    required this.updateAt,
    required this.deleteAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<int>(userId);
    map['username'] = Variable<String>(username);
    map['nickname'] = Variable<String>(nickname);
    map['type'] = Variable<String>(type);
    map['status'] = Variable<String>(status);
    map['human_type'] = Variable<String>(humanType);
    map['bot_type'] = Variable<String>(botType);
    map['app_id'] = Variable<int>(appId);
    map['dsm_uid'] = Variable<int>(dsmUid);
    map['avatar_version'] = Variable<int>(avatarVersion);
    map['avatar_color'] = Variable<String>(avatarColor);
    map['email'] = Variable<String>(email);
    map['description'] = Variable<String>(description);
    map['public_key'] = Variable<String>(publicKey);
    map['private_key_enc'] = Variable<String>(privateKeyEnc);
    map['is_disabled'] = Variable<bool>(isDisabled);
    map['is_deleted'] = Variable<bool>(isDeleted);
    map['has_url'] = Variable<bool>(hasUrl);
    map['bot_props'] = Variable<String>(botProps);
    map['is_always_offline'] = Variable<bool>(isAlwaysOffline);
    map['create_at'] = Variable<int>(createAt);
    map['update_at'] = Variable<int>(updateAt);
    map['delete_at'] = Variable<int>(deleteAt);
    return map;
  }

  UserRowsCompanion toCompanion(bool nullToAbsent) {
    return UserRowsCompanion(
      userId: Value(userId),
      username: Value(username),
      nickname: Value(nickname),
      type: Value(type),
      status: Value(status),
      humanType: Value(humanType),
      botType: Value(botType),
      appId: Value(appId),
      dsmUid: Value(dsmUid),
      avatarVersion: Value(avatarVersion),
      avatarColor: Value(avatarColor),
      email: Value(email),
      description: Value(description),
      publicKey: Value(publicKey),
      privateKeyEnc: Value(privateKeyEnc),
      isDisabled: Value(isDisabled),
      isDeleted: Value(isDeleted),
      hasUrl: Value(hasUrl),
      botProps: Value(botProps),
      isAlwaysOffline: Value(isAlwaysOffline),
      createAt: Value(createAt),
      updateAt: Value(updateAt),
      deleteAt: Value(deleteAt),
    );
  }

  factory UserRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UserRow(
      userId: serializer.fromJson<int>(json['userId']),
      username: serializer.fromJson<String>(json['username']),
      nickname: serializer.fromJson<String>(json['nickname']),
      type: serializer.fromJson<String>(json['type']),
      status: serializer.fromJson<String>(json['status']),
      humanType: serializer.fromJson<String>(json['humanType']),
      botType: serializer.fromJson<String>(json['botType']),
      appId: serializer.fromJson<int>(json['appId']),
      dsmUid: serializer.fromJson<int>(json['dsmUid']),
      avatarVersion: serializer.fromJson<int>(json['avatarVersion']),
      avatarColor: serializer.fromJson<String>(json['avatarColor']),
      email: serializer.fromJson<String>(json['email']),
      description: serializer.fromJson<String>(json['description']),
      publicKey: serializer.fromJson<String>(json['publicKey']),
      privateKeyEnc: serializer.fromJson<String>(json['privateKeyEnc']),
      isDisabled: serializer.fromJson<bool>(json['isDisabled']),
      isDeleted: serializer.fromJson<bool>(json['isDeleted']),
      hasUrl: serializer.fromJson<bool>(json['hasUrl']),
      botProps: serializer.fromJson<String>(json['botProps']),
      isAlwaysOffline: serializer.fromJson<bool>(json['isAlwaysOffline']),
      createAt: serializer.fromJson<int>(json['createAt']),
      updateAt: serializer.fromJson<int>(json['updateAt']),
      deleteAt: serializer.fromJson<int>(json['deleteAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<int>(userId),
      'username': serializer.toJson<String>(username),
      'nickname': serializer.toJson<String>(nickname),
      'type': serializer.toJson<String>(type),
      'status': serializer.toJson<String>(status),
      'humanType': serializer.toJson<String>(humanType),
      'botType': serializer.toJson<String>(botType),
      'appId': serializer.toJson<int>(appId),
      'dsmUid': serializer.toJson<int>(dsmUid),
      'avatarVersion': serializer.toJson<int>(avatarVersion),
      'avatarColor': serializer.toJson<String>(avatarColor),
      'email': serializer.toJson<String>(email),
      'description': serializer.toJson<String>(description),
      'publicKey': serializer.toJson<String>(publicKey),
      'privateKeyEnc': serializer.toJson<String>(privateKeyEnc),
      'isDisabled': serializer.toJson<bool>(isDisabled),
      'isDeleted': serializer.toJson<bool>(isDeleted),
      'hasUrl': serializer.toJson<bool>(hasUrl),
      'botProps': serializer.toJson<String>(botProps),
      'isAlwaysOffline': serializer.toJson<bool>(isAlwaysOffline),
      'createAt': serializer.toJson<int>(createAt),
      'updateAt': serializer.toJson<int>(updateAt),
      'deleteAt': serializer.toJson<int>(deleteAt),
    };
  }

  UserRow copyWith({
    int? userId,
    String? username,
    String? nickname,
    String? type,
    String? status,
    String? humanType,
    String? botType,
    int? appId,
    int? dsmUid,
    int? avatarVersion,
    String? avatarColor,
    String? email,
    String? description,
    String? publicKey,
    String? privateKeyEnc,
    bool? isDisabled,
    bool? isDeleted,
    bool? hasUrl,
    String? botProps,
    bool? isAlwaysOffline,
    int? createAt,
    int? updateAt,
    int? deleteAt,
  }) => UserRow(
    userId: userId ?? this.userId,
    username: username ?? this.username,
    nickname: nickname ?? this.nickname,
    type: type ?? this.type,
    status: status ?? this.status,
    humanType: humanType ?? this.humanType,
    botType: botType ?? this.botType,
    appId: appId ?? this.appId,
    dsmUid: dsmUid ?? this.dsmUid,
    avatarVersion: avatarVersion ?? this.avatarVersion,
    avatarColor: avatarColor ?? this.avatarColor,
    email: email ?? this.email,
    description: description ?? this.description,
    publicKey: publicKey ?? this.publicKey,
    privateKeyEnc: privateKeyEnc ?? this.privateKeyEnc,
    isDisabled: isDisabled ?? this.isDisabled,
    isDeleted: isDeleted ?? this.isDeleted,
    hasUrl: hasUrl ?? this.hasUrl,
    botProps: botProps ?? this.botProps,
    isAlwaysOffline: isAlwaysOffline ?? this.isAlwaysOffline,
    createAt: createAt ?? this.createAt,
    updateAt: updateAt ?? this.updateAt,
    deleteAt: deleteAt ?? this.deleteAt,
  );
  UserRow copyWithCompanion(UserRowsCompanion data) {
    return UserRow(
      userId: data.userId.present ? data.userId.value : this.userId,
      username: data.username.present ? data.username.value : this.username,
      nickname: data.nickname.present ? data.nickname.value : this.nickname,
      type: data.type.present ? data.type.value : this.type,
      status: data.status.present ? data.status.value : this.status,
      humanType: data.humanType.present ? data.humanType.value : this.humanType,
      botType: data.botType.present ? data.botType.value : this.botType,
      appId: data.appId.present ? data.appId.value : this.appId,
      dsmUid: data.dsmUid.present ? data.dsmUid.value : this.dsmUid,
      avatarVersion: data.avatarVersion.present
          ? data.avatarVersion.value
          : this.avatarVersion,
      avatarColor: data.avatarColor.present
          ? data.avatarColor.value
          : this.avatarColor,
      email: data.email.present ? data.email.value : this.email,
      description: data.description.present
          ? data.description.value
          : this.description,
      publicKey: data.publicKey.present ? data.publicKey.value : this.publicKey,
      privateKeyEnc: data.privateKeyEnc.present
          ? data.privateKeyEnc.value
          : this.privateKeyEnc,
      isDisabled: data.isDisabled.present
          ? data.isDisabled.value
          : this.isDisabled,
      isDeleted: data.isDeleted.present ? data.isDeleted.value : this.isDeleted,
      hasUrl: data.hasUrl.present ? data.hasUrl.value : this.hasUrl,
      botProps: data.botProps.present ? data.botProps.value : this.botProps,
      isAlwaysOffline: data.isAlwaysOffline.present
          ? data.isAlwaysOffline.value
          : this.isAlwaysOffline,
      createAt: data.createAt.present ? data.createAt.value : this.createAt,
      updateAt: data.updateAt.present ? data.updateAt.value : this.updateAt,
      deleteAt: data.deleteAt.present ? data.deleteAt.value : this.deleteAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UserRow(')
          ..write('userId: $userId, ')
          ..write('username: $username, ')
          ..write('nickname: $nickname, ')
          ..write('type: $type, ')
          ..write('status: $status, ')
          ..write('humanType: $humanType, ')
          ..write('botType: $botType, ')
          ..write('appId: $appId, ')
          ..write('dsmUid: $dsmUid, ')
          ..write('avatarVersion: $avatarVersion, ')
          ..write('avatarColor: $avatarColor, ')
          ..write('email: $email, ')
          ..write('description: $description, ')
          ..write('publicKey: $publicKey, ')
          ..write('privateKeyEnc: $privateKeyEnc, ')
          ..write('isDisabled: $isDisabled, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('hasUrl: $hasUrl, ')
          ..write('botProps: $botProps, ')
          ..write('isAlwaysOffline: $isAlwaysOffline, ')
          ..write('createAt: $createAt, ')
          ..write('updateAt: $updateAt, ')
          ..write('deleteAt: $deleteAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    userId,
    username,
    nickname,
    type,
    status,
    humanType,
    botType,
    appId,
    dsmUid,
    avatarVersion,
    avatarColor,
    email,
    description,
    publicKey,
    privateKeyEnc,
    isDisabled,
    isDeleted,
    hasUrl,
    botProps,
    isAlwaysOffline,
    createAt,
    updateAt,
    deleteAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UserRow &&
          other.userId == this.userId &&
          other.username == this.username &&
          other.nickname == this.nickname &&
          other.type == this.type &&
          other.status == this.status &&
          other.humanType == this.humanType &&
          other.botType == this.botType &&
          other.appId == this.appId &&
          other.dsmUid == this.dsmUid &&
          other.avatarVersion == this.avatarVersion &&
          other.avatarColor == this.avatarColor &&
          other.email == this.email &&
          other.description == this.description &&
          other.publicKey == this.publicKey &&
          other.privateKeyEnc == this.privateKeyEnc &&
          other.isDisabled == this.isDisabled &&
          other.isDeleted == this.isDeleted &&
          other.hasUrl == this.hasUrl &&
          other.botProps == this.botProps &&
          other.isAlwaysOffline == this.isAlwaysOffline &&
          other.createAt == this.createAt &&
          other.updateAt == this.updateAt &&
          other.deleteAt == this.deleteAt);
}

class UserRowsCompanion extends UpdateCompanion<UserRow> {
  final Value<int> userId;
  final Value<String> username;
  final Value<String> nickname;
  final Value<String> type;
  final Value<String> status;
  final Value<String> humanType;
  final Value<String> botType;
  final Value<int> appId;
  final Value<int> dsmUid;
  final Value<int> avatarVersion;
  final Value<String> avatarColor;
  final Value<String> email;
  final Value<String> description;
  final Value<String> publicKey;
  final Value<String> privateKeyEnc;
  final Value<bool> isDisabled;
  final Value<bool> isDeleted;
  final Value<bool> hasUrl;
  final Value<String> botProps;
  final Value<bool> isAlwaysOffline;
  final Value<int> createAt;
  final Value<int> updateAt;
  final Value<int> deleteAt;
  const UserRowsCompanion({
    this.userId = const Value.absent(),
    this.username = const Value.absent(),
    this.nickname = const Value.absent(),
    this.type = const Value.absent(),
    this.status = const Value.absent(),
    this.humanType = const Value.absent(),
    this.botType = const Value.absent(),
    this.appId = const Value.absent(),
    this.dsmUid = const Value.absent(),
    this.avatarVersion = const Value.absent(),
    this.avatarColor = const Value.absent(),
    this.email = const Value.absent(),
    this.description = const Value.absent(),
    this.publicKey = const Value.absent(),
    this.privateKeyEnc = const Value.absent(),
    this.isDisabled = const Value.absent(),
    this.isDeleted = const Value.absent(),
    this.hasUrl = const Value.absent(),
    this.botProps = const Value.absent(),
    this.isAlwaysOffline = const Value.absent(),
    this.createAt = const Value.absent(),
    this.updateAt = const Value.absent(),
    this.deleteAt = const Value.absent(),
  });
  UserRowsCompanion.insert({
    this.userId = const Value.absent(),
    this.username = const Value.absent(),
    this.nickname = const Value.absent(),
    this.type = const Value.absent(),
    this.status = const Value.absent(),
    this.humanType = const Value.absent(),
    this.botType = const Value.absent(),
    this.appId = const Value.absent(),
    this.dsmUid = const Value.absent(),
    this.avatarVersion = const Value.absent(),
    this.avatarColor = const Value.absent(),
    this.email = const Value.absent(),
    this.description = const Value.absent(),
    this.publicKey = const Value.absent(),
    this.privateKeyEnc = const Value.absent(),
    this.isDisabled = const Value.absent(),
    this.isDeleted = const Value.absent(),
    this.hasUrl = const Value.absent(),
    this.botProps = const Value.absent(),
    this.isAlwaysOffline = const Value.absent(),
    this.createAt = const Value.absent(),
    this.updateAt = const Value.absent(),
    this.deleteAt = const Value.absent(),
  });
  static Insertable<UserRow> custom({
    Expression<int>? userId,
    Expression<String>? username,
    Expression<String>? nickname,
    Expression<String>? type,
    Expression<String>? status,
    Expression<String>? humanType,
    Expression<String>? botType,
    Expression<int>? appId,
    Expression<int>? dsmUid,
    Expression<int>? avatarVersion,
    Expression<String>? avatarColor,
    Expression<String>? email,
    Expression<String>? description,
    Expression<String>? publicKey,
    Expression<String>? privateKeyEnc,
    Expression<bool>? isDisabled,
    Expression<bool>? isDeleted,
    Expression<bool>? hasUrl,
    Expression<String>? botProps,
    Expression<bool>? isAlwaysOffline,
    Expression<int>? createAt,
    Expression<int>? updateAt,
    Expression<int>? deleteAt,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (username != null) 'username': username,
      if (nickname != null) 'nickname': nickname,
      if (type != null) 'type': type,
      if (status != null) 'status': status,
      if (humanType != null) 'human_type': humanType,
      if (botType != null) 'bot_type': botType,
      if (appId != null) 'app_id': appId,
      if (dsmUid != null) 'dsm_uid': dsmUid,
      if (avatarVersion != null) 'avatar_version': avatarVersion,
      if (avatarColor != null) 'avatar_color': avatarColor,
      if (email != null) 'email': email,
      if (description != null) 'description': description,
      if (publicKey != null) 'public_key': publicKey,
      if (privateKeyEnc != null) 'private_key_enc': privateKeyEnc,
      if (isDisabled != null) 'is_disabled': isDisabled,
      if (isDeleted != null) 'is_deleted': isDeleted,
      if (hasUrl != null) 'has_url': hasUrl,
      if (botProps != null) 'bot_props': botProps,
      if (isAlwaysOffline != null) 'is_always_offline': isAlwaysOffline,
      if (createAt != null) 'create_at': createAt,
      if (updateAt != null) 'update_at': updateAt,
      if (deleteAt != null) 'delete_at': deleteAt,
    });
  }

  UserRowsCompanion copyWith({
    Value<int>? userId,
    Value<String>? username,
    Value<String>? nickname,
    Value<String>? type,
    Value<String>? status,
    Value<String>? humanType,
    Value<String>? botType,
    Value<int>? appId,
    Value<int>? dsmUid,
    Value<int>? avatarVersion,
    Value<String>? avatarColor,
    Value<String>? email,
    Value<String>? description,
    Value<String>? publicKey,
    Value<String>? privateKeyEnc,
    Value<bool>? isDisabled,
    Value<bool>? isDeleted,
    Value<bool>? hasUrl,
    Value<String>? botProps,
    Value<bool>? isAlwaysOffline,
    Value<int>? createAt,
    Value<int>? updateAt,
    Value<int>? deleteAt,
  }) {
    return UserRowsCompanion(
      userId: userId ?? this.userId,
      username: username ?? this.username,
      nickname: nickname ?? this.nickname,
      type: type ?? this.type,
      status: status ?? this.status,
      humanType: humanType ?? this.humanType,
      botType: botType ?? this.botType,
      appId: appId ?? this.appId,
      dsmUid: dsmUid ?? this.dsmUid,
      avatarVersion: avatarVersion ?? this.avatarVersion,
      avatarColor: avatarColor ?? this.avatarColor,
      email: email ?? this.email,
      description: description ?? this.description,
      publicKey: publicKey ?? this.publicKey,
      privateKeyEnc: privateKeyEnc ?? this.privateKeyEnc,
      isDisabled: isDisabled ?? this.isDisabled,
      isDeleted: isDeleted ?? this.isDeleted,
      hasUrl: hasUrl ?? this.hasUrl,
      botProps: botProps ?? this.botProps,
      isAlwaysOffline: isAlwaysOffline ?? this.isAlwaysOffline,
      createAt: createAt ?? this.createAt,
      updateAt: updateAt ?? this.updateAt,
      deleteAt: deleteAt ?? this.deleteAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (nickname.present) {
      map['nickname'] = Variable<String>(nickname.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (humanType.present) {
      map['human_type'] = Variable<String>(humanType.value);
    }
    if (botType.present) {
      map['bot_type'] = Variable<String>(botType.value);
    }
    if (appId.present) {
      map['app_id'] = Variable<int>(appId.value);
    }
    if (dsmUid.present) {
      map['dsm_uid'] = Variable<int>(dsmUid.value);
    }
    if (avatarVersion.present) {
      map['avatar_version'] = Variable<int>(avatarVersion.value);
    }
    if (avatarColor.present) {
      map['avatar_color'] = Variable<String>(avatarColor.value);
    }
    if (email.present) {
      map['email'] = Variable<String>(email.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (publicKey.present) {
      map['public_key'] = Variable<String>(publicKey.value);
    }
    if (privateKeyEnc.present) {
      map['private_key_enc'] = Variable<String>(privateKeyEnc.value);
    }
    if (isDisabled.present) {
      map['is_disabled'] = Variable<bool>(isDisabled.value);
    }
    if (isDeleted.present) {
      map['is_deleted'] = Variable<bool>(isDeleted.value);
    }
    if (hasUrl.present) {
      map['has_url'] = Variable<bool>(hasUrl.value);
    }
    if (botProps.present) {
      map['bot_props'] = Variable<String>(botProps.value);
    }
    if (isAlwaysOffline.present) {
      map['is_always_offline'] = Variable<bool>(isAlwaysOffline.value);
    }
    if (createAt.present) {
      map['create_at'] = Variable<int>(createAt.value);
    }
    if (updateAt.present) {
      map['update_at'] = Variable<int>(updateAt.value);
    }
    if (deleteAt.present) {
      map['delete_at'] = Variable<int>(deleteAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UserRowsCompanion(')
          ..write('userId: $userId, ')
          ..write('username: $username, ')
          ..write('nickname: $nickname, ')
          ..write('type: $type, ')
          ..write('status: $status, ')
          ..write('humanType: $humanType, ')
          ..write('botType: $botType, ')
          ..write('appId: $appId, ')
          ..write('dsmUid: $dsmUid, ')
          ..write('avatarVersion: $avatarVersion, ')
          ..write('avatarColor: $avatarColor, ')
          ..write('email: $email, ')
          ..write('description: $description, ')
          ..write('publicKey: $publicKey, ')
          ..write('privateKeyEnc: $privateKeyEnc, ')
          ..write('isDisabled: $isDisabled, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('hasUrl: $hasUrl, ')
          ..write('botProps: $botProps, ')
          ..write('isAlwaysOffline: $isAlwaysOffline, ')
          ..write('createAt: $createAt, ')
          ..write('updateAt: $updateAt, ')
          ..write('deleteAt: $deleteAt')
          ..write(')'))
        .toString();
  }
}

class $PostRowsTable extends PostRows with TableInfo<$PostRowsTable, PostRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PostRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _postIdMeta = const VerificationMeta('postId');
  @override
  late final GeneratedColumn<int> postId = GeneratedColumn<int>(
    'post_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _channelIdMeta = const VerificationMeta(
    'channelId',
  );
  @override
  late final GeneratedColumn<int> channelId = GeneratedColumn<int>(
    'channel_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _creatorIdMeta = const VerificationMeta(
    'creatorId',
  );
  @override
  late final GeneratedColumn<int> creatorId = GeneratedColumn<int>(
    'creator_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _threadIdMeta = const VerificationMeta(
    'threadId',
  );
  @override
  late final GeneratedColumn<int> threadId = GeneratedColumn<int>(
    'thread_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('normal'),
  );
  static const VerificationMeta _messageMeta = const VerificationMeta(
    'message',
  );
  @override
  late final GeneratedColumn<String> message = GeneratedColumn<String>(
    'message',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _createAtMeta = const VerificationMeta(
    'createAt',
  );
  @override
  late final GeneratedColumn<int> createAt = GeneratedColumn<int>(
    'create_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _updateAtMeta = const VerificationMeta(
    'updateAt',
  );
  @override
  late final GeneratedColumn<int> updateAt = GeneratedColumn<int>(
    'update_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _deleteAtMeta = const VerificationMeta(
    'deleteAt',
  );
  @override
  late final GeneratedColumn<int> deleteAt = GeneratedColumn<int>(
    'delete_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastCommentAtMeta = const VerificationMeta(
    'lastCommentAt',
  );
  @override
  late final GeneratedColumn<int> lastCommentAt = GeneratedColumn<int>(
    'last_comment_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastPinAtMeta = const VerificationMeta(
    'lastPinAt',
  );
  @override
  late final GeneratedColumn<int> lastPinAt = GeneratedColumn<int>(
    'last_pin_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _commentCountMeta = const VerificationMeta(
    'commentCount',
  );
  @override
  late final GeneratedColumn<int> commentCount = GeneratedColumn<int>(
    'comment_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isStarMeta = const VerificationMeta('isStar');
  @override
  late final GeneratedColumn<bool> isStar = GeneratedColumn<bool>(
    'is_star',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_star" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isStickyMeta = const VerificationMeta(
    'isSticky',
  );
  @override
  late final GeneratedColumn<bool> isSticky = GeneratedColumn<bool>(
    'is_sticky',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_sticky" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _encryptedMeta = const VerificationMeta(
    'encrypted',
  );
  @override
  late final GeneratedColumn<bool> encrypted = GeneratedColumn<bool>(
    'encrypted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("encrypted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _safeUrlMeta = const VerificationMeta(
    'safeUrl',
  );
  @override
  late final GeneratedColumn<bool> safeUrl = GeneratedColumn<bool>(
    'safe_url',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("safe_url" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _staticUrlMeta = const VerificationMeta(
    'staticUrl',
  );
  @override
  late final GeneratedColumn<bool> staticUrl = GeneratedColumn<bool>(
    'static_url',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("static_url" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _forwardTypeMeta = const VerificationMeta(
    'forwardType',
  );
  @override
  late final GeneratedColumn<String> forwardType = GeneratedColumn<String>(
    'forward_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('none'),
  );
  static const VerificationMeta _hashtagsMeta = const VerificationMeta(
    'hashtags',
  );
  @override
  late final GeneratedColumn<String> hashtags = GeneratedColumn<String>(
    'hashtags',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _hashtagsAdditionalMeta =
      const VerificationMeta('hashtagsAdditional');
  @override
  late final GeneratedColumn<String> hashtagsAdditional =
      GeneratedColumn<String>(
        'hashtags_additional',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('[]'),
      );
  static const VerificationMeta _mentionsMeta = const VerificationMeta(
    'mentions',
  );
  @override
  late final GeneratedColumn<String> mentions = GeneratedColumn<String>(
    'mentions',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _reactionsMeta = const VerificationMeta(
    'reactions',
  );
  @override
  late final GeneratedColumn<String> reactions = GeneratedColumn<String>(
    'reactions',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _urlPropsMeta = const VerificationMeta(
    'urlProps',
  );
  @override
  late final GeneratedColumn<String> urlProps = GeneratedColumn<String>(
    'url_props',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _filePropsMeta = const VerificationMeta(
    'fileProps',
  );
  @override
  late final GeneratedColumn<String> fileProps = GeneratedColumn<String>(
    'file_props',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _systemPropsMeta = const VerificationMeta(
    'systemProps',
  );
  @override
  late final GeneratedColumn<String> systemProps = GeneratedColumn<String>(
    'system_props',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _propsMeta = const VerificationMeta('props');
  @override
  late final GeneratedColumn<String> props = GeneratedColumn<String>(
    'props',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _tmpPostIdMeta = const VerificationMeta(
    'tmpPostId',
  );
  @override
  late final GeneratedColumn<int> tmpPostId = GeneratedColumn<int>(
    'tmp_post_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<int> state = GeneratedColumn<int>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _dedupeKeyMeta = const VerificationMeta(
    'dedupeKey',
  );
  @override
  late final GeneratedColumn<String> dedupeKey = GeneratedColumn<String>(
    'dedupe_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    postId,
    channelId,
    creatorId,
    threadId,
    type,
    message,
    createAt,
    updateAt,
    deleteAt,
    lastCommentAt,
    lastPinAt,
    commentCount,
    isStar,
    isSticky,
    encrypted,
    safeUrl,
    staticUrl,
    forwardType,
    hashtags,
    hashtagsAdditional,
    mentions,
    reactions,
    urlProps,
    fileProps,
    systemProps,
    props,
    tmpPostId,
    state,
    dedupeKey,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'post_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<PostRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('post_id')) {
      context.handle(
        _postIdMeta,
        postId.isAcceptableOrUnknown(data['post_id']!, _postIdMeta),
      );
    }
    if (data.containsKey('channel_id')) {
      context.handle(
        _channelIdMeta,
        channelId.isAcceptableOrUnknown(data['channel_id']!, _channelIdMeta),
      );
    } else if (isInserting) {
      context.missing(_channelIdMeta);
    }
    if (data.containsKey('creator_id')) {
      context.handle(
        _creatorIdMeta,
        creatorId.isAcceptableOrUnknown(data['creator_id']!, _creatorIdMeta),
      );
    }
    if (data.containsKey('thread_id')) {
      context.handle(
        _threadIdMeta,
        threadId.isAcceptableOrUnknown(data['thread_id']!, _threadIdMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('message')) {
      context.handle(
        _messageMeta,
        message.isAcceptableOrUnknown(data['message']!, _messageMeta),
      );
    }
    if (data.containsKey('create_at')) {
      context.handle(
        _createAtMeta,
        createAt.isAcceptableOrUnknown(data['create_at']!, _createAtMeta),
      );
    }
    if (data.containsKey('update_at')) {
      context.handle(
        _updateAtMeta,
        updateAt.isAcceptableOrUnknown(data['update_at']!, _updateAtMeta),
      );
    }
    if (data.containsKey('delete_at')) {
      context.handle(
        _deleteAtMeta,
        deleteAt.isAcceptableOrUnknown(data['delete_at']!, _deleteAtMeta),
      );
    }
    if (data.containsKey('last_comment_at')) {
      context.handle(
        _lastCommentAtMeta,
        lastCommentAt.isAcceptableOrUnknown(
          data['last_comment_at']!,
          _lastCommentAtMeta,
        ),
      );
    }
    if (data.containsKey('last_pin_at')) {
      context.handle(
        _lastPinAtMeta,
        lastPinAt.isAcceptableOrUnknown(data['last_pin_at']!, _lastPinAtMeta),
      );
    }
    if (data.containsKey('comment_count')) {
      context.handle(
        _commentCountMeta,
        commentCount.isAcceptableOrUnknown(
          data['comment_count']!,
          _commentCountMeta,
        ),
      );
    }
    if (data.containsKey('is_star')) {
      context.handle(
        _isStarMeta,
        isStar.isAcceptableOrUnknown(data['is_star']!, _isStarMeta),
      );
    }
    if (data.containsKey('is_sticky')) {
      context.handle(
        _isStickyMeta,
        isSticky.isAcceptableOrUnknown(data['is_sticky']!, _isStickyMeta),
      );
    }
    if (data.containsKey('encrypted')) {
      context.handle(
        _encryptedMeta,
        encrypted.isAcceptableOrUnknown(data['encrypted']!, _encryptedMeta),
      );
    }
    if (data.containsKey('safe_url')) {
      context.handle(
        _safeUrlMeta,
        safeUrl.isAcceptableOrUnknown(data['safe_url']!, _safeUrlMeta),
      );
    }
    if (data.containsKey('static_url')) {
      context.handle(
        _staticUrlMeta,
        staticUrl.isAcceptableOrUnknown(data['static_url']!, _staticUrlMeta),
      );
    }
    if (data.containsKey('forward_type')) {
      context.handle(
        _forwardTypeMeta,
        forwardType.isAcceptableOrUnknown(
          data['forward_type']!,
          _forwardTypeMeta,
        ),
      );
    }
    if (data.containsKey('hashtags')) {
      context.handle(
        _hashtagsMeta,
        hashtags.isAcceptableOrUnknown(data['hashtags']!, _hashtagsMeta),
      );
    }
    if (data.containsKey('hashtags_additional')) {
      context.handle(
        _hashtagsAdditionalMeta,
        hashtagsAdditional.isAcceptableOrUnknown(
          data['hashtags_additional']!,
          _hashtagsAdditionalMeta,
        ),
      );
    }
    if (data.containsKey('mentions')) {
      context.handle(
        _mentionsMeta,
        mentions.isAcceptableOrUnknown(data['mentions']!, _mentionsMeta),
      );
    }
    if (data.containsKey('reactions')) {
      context.handle(
        _reactionsMeta,
        reactions.isAcceptableOrUnknown(data['reactions']!, _reactionsMeta),
      );
    }
    if (data.containsKey('url_props')) {
      context.handle(
        _urlPropsMeta,
        urlProps.isAcceptableOrUnknown(data['url_props']!, _urlPropsMeta),
      );
    }
    if (data.containsKey('file_props')) {
      context.handle(
        _filePropsMeta,
        fileProps.isAcceptableOrUnknown(data['file_props']!, _filePropsMeta),
      );
    }
    if (data.containsKey('system_props')) {
      context.handle(
        _systemPropsMeta,
        systemProps.isAcceptableOrUnknown(
          data['system_props']!,
          _systemPropsMeta,
        ),
      );
    }
    if (data.containsKey('props')) {
      context.handle(
        _propsMeta,
        props.isAcceptableOrUnknown(data['props']!, _propsMeta),
      );
    }
    if (data.containsKey('tmp_post_id')) {
      context.handle(
        _tmpPostIdMeta,
        tmpPostId.isAcceptableOrUnknown(data['tmp_post_id']!, _tmpPostIdMeta),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    }
    if (data.containsKey('dedupe_key')) {
      context.handle(
        _dedupeKeyMeta,
        dedupeKey.isAcceptableOrUnknown(data['dedupe_key']!, _dedupeKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_dedupeKeyMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PostRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PostRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      postId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}post_id'],
      )!,
      channelId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}channel_id'],
      )!,
      creatorId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}creator_id'],
      )!,
      threadId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}thread_id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      message: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message'],
      )!,
      createAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_at'],
      )!,
      updateAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}update_at'],
      )!,
      deleteAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delete_at'],
      )!,
      lastCommentAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_comment_at'],
      )!,
      lastPinAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_pin_at'],
      )!,
      commentCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}comment_count'],
      )!,
      isStar: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_star'],
      )!,
      isSticky: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_sticky'],
      )!,
      encrypted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}encrypted'],
      )!,
      safeUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}safe_url'],
      )!,
      staticUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}static_url'],
      )!,
      forwardType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}forward_type'],
      )!,
      hashtags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hashtags'],
      )!,
      hashtagsAdditional: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hashtags_additional'],
      )!,
      mentions: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mentions'],
      )!,
      reactions: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reactions'],
      )!,
      urlProps: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}url_props'],
      )!,
      fileProps: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_props'],
      )!,
      systemProps: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}system_props'],
      )!,
      props: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}props'],
      )!,
      tmpPostId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tmp_post_id'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}state'],
      )!,
      dedupeKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dedupe_key'],
      )!,
    );
  }

  @override
  $PostRowsTable createAlias(String alias) {
    return $PostRowsTable(attachedDatabase, alias);
  }
}

class PostRow extends DataClass implements Insertable<PostRow> {
  /// 本地自增主键：乐观发送时 `post_id` 还是 0，只有 `tmp_post_id` 可用，
  /// 不能拿 post_id 当主键。
  final int id;
  final int postId;
  final int channelId;
  final int creatorId;
  final int threadId;
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
  final bool encrypted;
  final bool safeUrl;
  final bool staticUrl;
  final String forwardType;
  final String hashtags;
  final String hashtagsAdditional;
  final String mentions;
  final String reactions;
  final String urlProps;
  final String fileProps;
  final String systemProps;

  /// `props` 原文 JSON：投票（`vote`）、提醒（`remind_at`）等都在里面。
  /// 之前只挑了 encrypted/safe_url 几个字段建列，投票就没地方放了。
  final String props;
  final int tmpPostId;

  /// 0 = 已同步；1 = 发送中；2 = 发送失败
  final int state;

  /// 去重键：服务端消息 `p:<post_id>`，本地待发消息 `t:<tmp_post_id>`。
  ///
  /// 为什么不直接对 `(channel_id, post_id)` 建唯一索引：**待发消息的 post_id 是 0**，
  /// 同一频道里两条待发消息会互撞（真踩过 UNIQUE constraint failed）。
  final String dedupeKey;
  const PostRow({
    required this.id,
    required this.postId,
    required this.channelId,
    required this.creatorId,
    required this.threadId,
    required this.type,
    required this.message,
    required this.createAt,
    required this.updateAt,
    required this.deleteAt,
    required this.lastCommentAt,
    required this.lastPinAt,
    required this.commentCount,
    required this.isStar,
    required this.isSticky,
    required this.encrypted,
    required this.safeUrl,
    required this.staticUrl,
    required this.forwardType,
    required this.hashtags,
    required this.hashtagsAdditional,
    required this.mentions,
    required this.reactions,
    required this.urlProps,
    required this.fileProps,
    required this.systemProps,
    required this.props,
    required this.tmpPostId,
    required this.state,
    required this.dedupeKey,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['post_id'] = Variable<int>(postId);
    map['channel_id'] = Variable<int>(channelId);
    map['creator_id'] = Variable<int>(creatorId);
    map['thread_id'] = Variable<int>(threadId);
    map['type'] = Variable<String>(type);
    map['message'] = Variable<String>(message);
    map['create_at'] = Variable<int>(createAt);
    map['update_at'] = Variable<int>(updateAt);
    map['delete_at'] = Variable<int>(deleteAt);
    map['last_comment_at'] = Variable<int>(lastCommentAt);
    map['last_pin_at'] = Variable<int>(lastPinAt);
    map['comment_count'] = Variable<int>(commentCount);
    map['is_star'] = Variable<bool>(isStar);
    map['is_sticky'] = Variable<bool>(isSticky);
    map['encrypted'] = Variable<bool>(encrypted);
    map['safe_url'] = Variable<bool>(safeUrl);
    map['static_url'] = Variable<bool>(staticUrl);
    map['forward_type'] = Variable<String>(forwardType);
    map['hashtags'] = Variable<String>(hashtags);
    map['hashtags_additional'] = Variable<String>(hashtagsAdditional);
    map['mentions'] = Variable<String>(mentions);
    map['reactions'] = Variable<String>(reactions);
    map['url_props'] = Variable<String>(urlProps);
    map['file_props'] = Variable<String>(fileProps);
    map['system_props'] = Variable<String>(systemProps);
    map['props'] = Variable<String>(props);
    map['tmp_post_id'] = Variable<int>(tmpPostId);
    map['state'] = Variable<int>(state);
    map['dedupe_key'] = Variable<String>(dedupeKey);
    return map;
  }

  PostRowsCompanion toCompanion(bool nullToAbsent) {
    return PostRowsCompanion(
      id: Value(id),
      postId: Value(postId),
      channelId: Value(channelId),
      creatorId: Value(creatorId),
      threadId: Value(threadId),
      type: Value(type),
      message: Value(message),
      createAt: Value(createAt),
      updateAt: Value(updateAt),
      deleteAt: Value(deleteAt),
      lastCommentAt: Value(lastCommentAt),
      lastPinAt: Value(lastPinAt),
      commentCount: Value(commentCount),
      isStar: Value(isStar),
      isSticky: Value(isSticky),
      encrypted: Value(encrypted),
      safeUrl: Value(safeUrl),
      staticUrl: Value(staticUrl),
      forwardType: Value(forwardType),
      hashtags: Value(hashtags),
      hashtagsAdditional: Value(hashtagsAdditional),
      mentions: Value(mentions),
      reactions: Value(reactions),
      urlProps: Value(urlProps),
      fileProps: Value(fileProps),
      systemProps: Value(systemProps),
      props: Value(props),
      tmpPostId: Value(tmpPostId),
      state: Value(state),
      dedupeKey: Value(dedupeKey),
    );
  }

  factory PostRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PostRow(
      id: serializer.fromJson<int>(json['id']),
      postId: serializer.fromJson<int>(json['postId']),
      channelId: serializer.fromJson<int>(json['channelId']),
      creatorId: serializer.fromJson<int>(json['creatorId']),
      threadId: serializer.fromJson<int>(json['threadId']),
      type: serializer.fromJson<String>(json['type']),
      message: serializer.fromJson<String>(json['message']),
      createAt: serializer.fromJson<int>(json['createAt']),
      updateAt: serializer.fromJson<int>(json['updateAt']),
      deleteAt: serializer.fromJson<int>(json['deleteAt']),
      lastCommentAt: serializer.fromJson<int>(json['lastCommentAt']),
      lastPinAt: serializer.fromJson<int>(json['lastPinAt']),
      commentCount: serializer.fromJson<int>(json['commentCount']),
      isStar: serializer.fromJson<bool>(json['isStar']),
      isSticky: serializer.fromJson<bool>(json['isSticky']),
      encrypted: serializer.fromJson<bool>(json['encrypted']),
      safeUrl: serializer.fromJson<bool>(json['safeUrl']),
      staticUrl: serializer.fromJson<bool>(json['staticUrl']),
      forwardType: serializer.fromJson<String>(json['forwardType']),
      hashtags: serializer.fromJson<String>(json['hashtags']),
      hashtagsAdditional: serializer.fromJson<String>(
        json['hashtagsAdditional'],
      ),
      mentions: serializer.fromJson<String>(json['mentions']),
      reactions: serializer.fromJson<String>(json['reactions']),
      urlProps: serializer.fromJson<String>(json['urlProps']),
      fileProps: serializer.fromJson<String>(json['fileProps']),
      systemProps: serializer.fromJson<String>(json['systemProps']),
      props: serializer.fromJson<String>(json['props']),
      tmpPostId: serializer.fromJson<int>(json['tmpPostId']),
      state: serializer.fromJson<int>(json['state']),
      dedupeKey: serializer.fromJson<String>(json['dedupeKey']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'postId': serializer.toJson<int>(postId),
      'channelId': serializer.toJson<int>(channelId),
      'creatorId': serializer.toJson<int>(creatorId),
      'threadId': serializer.toJson<int>(threadId),
      'type': serializer.toJson<String>(type),
      'message': serializer.toJson<String>(message),
      'createAt': serializer.toJson<int>(createAt),
      'updateAt': serializer.toJson<int>(updateAt),
      'deleteAt': serializer.toJson<int>(deleteAt),
      'lastCommentAt': serializer.toJson<int>(lastCommentAt),
      'lastPinAt': serializer.toJson<int>(lastPinAt),
      'commentCount': serializer.toJson<int>(commentCount),
      'isStar': serializer.toJson<bool>(isStar),
      'isSticky': serializer.toJson<bool>(isSticky),
      'encrypted': serializer.toJson<bool>(encrypted),
      'safeUrl': serializer.toJson<bool>(safeUrl),
      'staticUrl': serializer.toJson<bool>(staticUrl),
      'forwardType': serializer.toJson<String>(forwardType),
      'hashtags': serializer.toJson<String>(hashtags),
      'hashtagsAdditional': serializer.toJson<String>(hashtagsAdditional),
      'mentions': serializer.toJson<String>(mentions),
      'reactions': serializer.toJson<String>(reactions),
      'urlProps': serializer.toJson<String>(urlProps),
      'fileProps': serializer.toJson<String>(fileProps),
      'systemProps': serializer.toJson<String>(systemProps),
      'props': serializer.toJson<String>(props),
      'tmpPostId': serializer.toJson<int>(tmpPostId),
      'state': serializer.toJson<int>(state),
      'dedupeKey': serializer.toJson<String>(dedupeKey),
    };
  }

  PostRow copyWith({
    int? id,
    int? postId,
    int? channelId,
    int? creatorId,
    int? threadId,
    String? type,
    String? message,
    int? createAt,
    int? updateAt,
    int? deleteAt,
    int? lastCommentAt,
    int? lastPinAt,
    int? commentCount,
    bool? isStar,
    bool? isSticky,
    bool? encrypted,
    bool? safeUrl,
    bool? staticUrl,
    String? forwardType,
    String? hashtags,
    String? hashtagsAdditional,
    String? mentions,
    String? reactions,
    String? urlProps,
    String? fileProps,
    String? systemProps,
    String? props,
    int? tmpPostId,
    int? state,
    String? dedupeKey,
  }) => PostRow(
    id: id ?? this.id,
    postId: postId ?? this.postId,
    channelId: channelId ?? this.channelId,
    creatorId: creatorId ?? this.creatorId,
    threadId: threadId ?? this.threadId,
    type: type ?? this.type,
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
    safeUrl: safeUrl ?? this.safeUrl,
    staticUrl: staticUrl ?? this.staticUrl,
    forwardType: forwardType ?? this.forwardType,
    hashtags: hashtags ?? this.hashtags,
    hashtagsAdditional: hashtagsAdditional ?? this.hashtagsAdditional,
    mentions: mentions ?? this.mentions,
    reactions: reactions ?? this.reactions,
    urlProps: urlProps ?? this.urlProps,
    fileProps: fileProps ?? this.fileProps,
    systemProps: systemProps ?? this.systemProps,
    props: props ?? this.props,
    tmpPostId: tmpPostId ?? this.tmpPostId,
    state: state ?? this.state,
    dedupeKey: dedupeKey ?? this.dedupeKey,
  );
  PostRow copyWithCompanion(PostRowsCompanion data) {
    return PostRow(
      id: data.id.present ? data.id.value : this.id,
      postId: data.postId.present ? data.postId.value : this.postId,
      channelId: data.channelId.present ? data.channelId.value : this.channelId,
      creatorId: data.creatorId.present ? data.creatorId.value : this.creatorId,
      threadId: data.threadId.present ? data.threadId.value : this.threadId,
      type: data.type.present ? data.type.value : this.type,
      message: data.message.present ? data.message.value : this.message,
      createAt: data.createAt.present ? data.createAt.value : this.createAt,
      updateAt: data.updateAt.present ? data.updateAt.value : this.updateAt,
      deleteAt: data.deleteAt.present ? data.deleteAt.value : this.deleteAt,
      lastCommentAt: data.lastCommentAt.present
          ? data.lastCommentAt.value
          : this.lastCommentAt,
      lastPinAt: data.lastPinAt.present ? data.lastPinAt.value : this.lastPinAt,
      commentCount: data.commentCount.present
          ? data.commentCount.value
          : this.commentCount,
      isStar: data.isStar.present ? data.isStar.value : this.isStar,
      isSticky: data.isSticky.present ? data.isSticky.value : this.isSticky,
      encrypted: data.encrypted.present ? data.encrypted.value : this.encrypted,
      safeUrl: data.safeUrl.present ? data.safeUrl.value : this.safeUrl,
      staticUrl: data.staticUrl.present ? data.staticUrl.value : this.staticUrl,
      forwardType: data.forwardType.present
          ? data.forwardType.value
          : this.forwardType,
      hashtags: data.hashtags.present ? data.hashtags.value : this.hashtags,
      hashtagsAdditional: data.hashtagsAdditional.present
          ? data.hashtagsAdditional.value
          : this.hashtagsAdditional,
      mentions: data.mentions.present ? data.mentions.value : this.mentions,
      reactions: data.reactions.present ? data.reactions.value : this.reactions,
      urlProps: data.urlProps.present ? data.urlProps.value : this.urlProps,
      fileProps: data.fileProps.present ? data.fileProps.value : this.fileProps,
      systemProps: data.systemProps.present
          ? data.systemProps.value
          : this.systemProps,
      props: data.props.present ? data.props.value : this.props,
      tmpPostId: data.tmpPostId.present ? data.tmpPostId.value : this.tmpPostId,
      state: data.state.present ? data.state.value : this.state,
      dedupeKey: data.dedupeKey.present ? data.dedupeKey.value : this.dedupeKey,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PostRow(')
          ..write('id: $id, ')
          ..write('postId: $postId, ')
          ..write('channelId: $channelId, ')
          ..write('creatorId: $creatorId, ')
          ..write('threadId: $threadId, ')
          ..write('type: $type, ')
          ..write('message: $message, ')
          ..write('createAt: $createAt, ')
          ..write('updateAt: $updateAt, ')
          ..write('deleteAt: $deleteAt, ')
          ..write('lastCommentAt: $lastCommentAt, ')
          ..write('lastPinAt: $lastPinAt, ')
          ..write('commentCount: $commentCount, ')
          ..write('isStar: $isStar, ')
          ..write('isSticky: $isSticky, ')
          ..write('encrypted: $encrypted, ')
          ..write('safeUrl: $safeUrl, ')
          ..write('staticUrl: $staticUrl, ')
          ..write('forwardType: $forwardType, ')
          ..write('hashtags: $hashtags, ')
          ..write('hashtagsAdditional: $hashtagsAdditional, ')
          ..write('mentions: $mentions, ')
          ..write('reactions: $reactions, ')
          ..write('urlProps: $urlProps, ')
          ..write('fileProps: $fileProps, ')
          ..write('systemProps: $systemProps, ')
          ..write('props: $props, ')
          ..write('tmpPostId: $tmpPostId, ')
          ..write('state: $state, ')
          ..write('dedupeKey: $dedupeKey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    postId,
    channelId,
    creatorId,
    threadId,
    type,
    message,
    createAt,
    updateAt,
    deleteAt,
    lastCommentAt,
    lastPinAt,
    commentCount,
    isStar,
    isSticky,
    encrypted,
    safeUrl,
    staticUrl,
    forwardType,
    hashtags,
    hashtagsAdditional,
    mentions,
    reactions,
    urlProps,
    fileProps,
    systemProps,
    props,
    tmpPostId,
    state,
    dedupeKey,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PostRow &&
          other.id == this.id &&
          other.postId == this.postId &&
          other.channelId == this.channelId &&
          other.creatorId == this.creatorId &&
          other.threadId == this.threadId &&
          other.type == this.type &&
          other.message == this.message &&
          other.createAt == this.createAt &&
          other.updateAt == this.updateAt &&
          other.deleteAt == this.deleteAt &&
          other.lastCommentAt == this.lastCommentAt &&
          other.lastPinAt == this.lastPinAt &&
          other.commentCount == this.commentCount &&
          other.isStar == this.isStar &&
          other.isSticky == this.isSticky &&
          other.encrypted == this.encrypted &&
          other.safeUrl == this.safeUrl &&
          other.staticUrl == this.staticUrl &&
          other.forwardType == this.forwardType &&
          other.hashtags == this.hashtags &&
          other.hashtagsAdditional == this.hashtagsAdditional &&
          other.mentions == this.mentions &&
          other.reactions == this.reactions &&
          other.urlProps == this.urlProps &&
          other.fileProps == this.fileProps &&
          other.systemProps == this.systemProps &&
          other.props == this.props &&
          other.tmpPostId == this.tmpPostId &&
          other.state == this.state &&
          other.dedupeKey == this.dedupeKey);
}

class PostRowsCompanion extends UpdateCompanion<PostRow> {
  final Value<int> id;
  final Value<int> postId;
  final Value<int> channelId;
  final Value<int> creatorId;
  final Value<int> threadId;
  final Value<String> type;
  final Value<String> message;
  final Value<int> createAt;
  final Value<int> updateAt;
  final Value<int> deleteAt;
  final Value<int> lastCommentAt;
  final Value<int> lastPinAt;
  final Value<int> commentCount;
  final Value<bool> isStar;
  final Value<bool> isSticky;
  final Value<bool> encrypted;
  final Value<bool> safeUrl;
  final Value<bool> staticUrl;
  final Value<String> forwardType;
  final Value<String> hashtags;
  final Value<String> hashtagsAdditional;
  final Value<String> mentions;
  final Value<String> reactions;
  final Value<String> urlProps;
  final Value<String> fileProps;
  final Value<String> systemProps;
  final Value<String> props;
  final Value<int> tmpPostId;
  final Value<int> state;
  final Value<String> dedupeKey;
  const PostRowsCompanion({
    this.id = const Value.absent(),
    this.postId = const Value.absent(),
    this.channelId = const Value.absent(),
    this.creatorId = const Value.absent(),
    this.threadId = const Value.absent(),
    this.type = const Value.absent(),
    this.message = const Value.absent(),
    this.createAt = const Value.absent(),
    this.updateAt = const Value.absent(),
    this.deleteAt = const Value.absent(),
    this.lastCommentAt = const Value.absent(),
    this.lastPinAt = const Value.absent(),
    this.commentCount = const Value.absent(),
    this.isStar = const Value.absent(),
    this.isSticky = const Value.absent(),
    this.encrypted = const Value.absent(),
    this.safeUrl = const Value.absent(),
    this.staticUrl = const Value.absent(),
    this.forwardType = const Value.absent(),
    this.hashtags = const Value.absent(),
    this.hashtagsAdditional = const Value.absent(),
    this.mentions = const Value.absent(),
    this.reactions = const Value.absent(),
    this.urlProps = const Value.absent(),
    this.fileProps = const Value.absent(),
    this.systemProps = const Value.absent(),
    this.props = const Value.absent(),
    this.tmpPostId = const Value.absent(),
    this.state = const Value.absent(),
    this.dedupeKey = const Value.absent(),
  });
  PostRowsCompanion.insert({
    this.id = const Value.absent(),
    this.postId = const Value.absent(),
    required int channelId,
    this.creatorId = const Value.absent(),
    this.threadId = const Value.absent(),
    this.type = const Value.absent(),
    this.message = const Value.absent(),
    this.createAt = const Value.absent(),
    this.updateAt = const Value.absent(),
    this.deleteAt = const Value.absent(),
    this.lastCommentAt = const Value.absent(),
    this.lastPinAt = const Value.absent(),
    this.commentCount = const Value.absent(),
    this.isStar = const Value.absent(),
    this.isSticky = const Value.absent(),
    this.encrypted = const Value.absent(),
    this.safeUrl = const Value.absent(),
    this.staticUrl = const Value.absent(),
    this.forwardType = const Value.absent(),
    this.hashtags = const Value.absent(),
    this.hashtagsAdditional = const Value.absent(),
    this.mentions = const Value.absent(),
    this.reactions = const Value.absent(),
    this.urlProps = const Value.absent(),
    this.fileProps = const Value.absent(),
    this.systemProps = const Value.absent(),
    this.props = const Value.absent(),
    this.tmpPostId = const Value.absent(),
    this.state = const Value.absent(),
    required String dedupeKey,
  }) : channelId = Value(channelId),
       dedupeKey = Value(dedupeKey);
  static Insertable<PostRow> custom({
    Expression<int>? id,
    Expression<int>? postId,
    Expression<int>? channelId,
    Expression<int>? creatorId,
    Expression<int>? threadId,
    Expression<String>? type,
    Expression<String>? message,
    Expression<int>? createAt,
    Expression<int>? updateAt,
    Expression<int>? deleteAt,
    Expression<int>? lastCommentAt,
    Expression<int>? lastPinAt,
    Expression<int>? commentCount,
    Expression<bool>? isStar,
    Expression<bool>? isSticky,
    Expression<bool>? encrypted,
    Expression<bool>? safeUrl,
    Expression<bool>? staticUrl,
    Expression<String>? forwardType,
    Expression<String>? hashtags,
    Expression<String>? hashtagsAdditional,
    Expression<String>? mentions,
    Expression<String>? reactions,
    Expression<String>? urlProps,
    Expression<String>? fileProps,
    Expression<String>? systemProps,
    Expression<String>? props,
    Expression<int>? tmpPostId,
    Expression<int>? state,
    Expression<String>? dedupeKey,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (postId != null) 'post_id': postId,
      if (channelId != null) 'channel_id': channelId,
      if (creatorId != null) 'creator_id': creatorId,
      if (threadId != null) 'thread_id': threadId,
      if (type != null) 'type': type,
      if (message != null) 'message': message,
      if (createAt != null) 'create_at': createAt,
      if (updateAt != null) 'update_at': updateAt,
      if (deleteAt != null) 'delete_at': deleteAt,
      if (lastCommentAt != null) 'last_comment_at': lastCommentAt,
      if (lastPinAt != null) 'last_pin_at': lastPinAt,
      if (commentCount != null) 'comment_count': commentCount,
      if (isStar != null) 'is_star': isStar,
      if (isSticky != null) 'is_sticky': isSticky,
      if (encrypted != null) 'encrypted': encrypted,
      if (safeUrl != null) 'safe_url': safeUrl,
      if (staticUrl != null) 'static_url': staticUrl,
      if (forwardType != null) 'forward_type': forwardType,
      if (hashtags != null) 'hashtags': hashtags,
      if (hashtagsAdditional != null) 'hashtags_additional': hashtagsAdditional,
      if (mentions != null) 'mentions': mentions,
      if (reactions != null) 'reactions': reactions,
      if (urlProps != null) 'url_props': urlProps,
      if (fileProps != null) 'file_props': fileProps,
      if (systemProps != null) 'system_props': systemProps,
      if (props != null) 'props': props,
      if (tmpPostId != null) 'tmp_post_id': tmpPostId,
      if (state != null) 'state': state,
      if (dedupeKey != null) 'dedupe_key': dedupeKey,
    });
  }

  PostRowsCompanion copyWith({
    Value<int>? id,
    Value<int>? postId,
    Value<int>? channelId,
    Value<int>? creatorId,
    Value<int>? threadId,
    Value<String>? type,
    Value<String>? message,
    Value<int>? createAt,
    Value<int>? updateAt,
    Value<int>? deleteAt,
    Value<int>? lastCommentAt,
    Value<int>? lastPinAt,
    Value<int>? commentCount,
    Value<bool>? isStar,
    Value<bool>? isSticky,
    Value<bool>? encrypted,
    Value<bool>? safeUrl,
    Value<bool>? staticUrl,
    Value<String>? forwardType,
    Value<String>? hashtags,
    Value<String>? hashtagsAdditional,
    Value<String>? mentions,
    Value<String>? reactions,
    Value<String>? urlProps,
    Value<String>? fileProps,
    Value<String>? systemProps,
    Value<String>? props,
    Value<int>? tmpPostId,
    Value<int>? state,
    Value<String>? dedupeKey,
  }) {
    return PostRowsCompanion(
      id: id ?? this.id,
      postId: postId ?? this.postId,
      channelId: channelId ?? this.channelId,
      creatorId: creatorId ?? this.creatorId,
      threadId: threadId ?? this.threadId,
      type: type ?? this.type,
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
      safeUrl: safeUrl ?? this.safeUrl,
      staticUrl: staticUrl ?? this.staticUrl,
      forwardType: forwardType ?? this.forwardType,
      hashtags: hashtags ?? this.hashtags,
      hashtagsAdditional: hashtagsAdditional ?? this.hashtagsAdditional,
      mentions: mentions ?? this.mentions,
      reactions: reactions ?? this.reactions,
      urlProps: urlProps ?? this.urlProps,
      fileProps: fileProps ?? this.fileProps,
      systemProps: systemProps ?? this.systemProps,
      props: props ?? this.props,
      tmpPostId: tmpPostId ?? this.tmpPostId,
      state: state ?? this.state,
      dedupeKey: dedupeKey ?? this.dedupeKey,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (postId.present) {
      map['post_id'] = Variable<int>(postId.value);
    }
    if (channelId.present) {
      map['channel_id'] = Variable<int>(channelId.value);
    }
    if (creatorId.present) {
      map['creator_id'] = Variable<int>(creatorId.value);
    }
    if (threadId.present) {
      map['thread_id'] = Variable<int>(threadId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (message.present) {
      map['message'] = Variable<String>(message.value);
    }
    if (createAt.present) {
      map['create_at'] = Variable<int>(createAt.value);
    }
    if (updateAt.present) {
      map['update_at'] = Variable<int>(updateAt.value);
    }
    if (deleteAt.present) {
      map['delete_at'] = Variable<int>(deleteAt.value);
    }
    if (lastCommentAt.present) {
      map['last_comment_at'] = Variable<int>(lastCommentAt.value);
    }
    if (lastPinAt.present) {
      map['last_pin_at'] = Variable<int>(lastPinAt.value);
    }
    if (commentCount.present) {
      map['comment_count'] = Variable<int>(commentCount.value);
    }
    if (isStar.present) {
      map['is_star'] = Variable<bool>(isStar.value);
    }
    if (isSticky.present) {
      map['is_sticky'] = Variable<bool>(isSticky.value);
    }
    if (encrypted.present) {
      map['encrypted'] = Variable<bool>(encrypted.value);
    }
    if (safeUrl.present) {
      map['safe_url'] = Variable<bool>(safeUrl.value);
    }
    if (staticUrl.present) {
      map['static_url'] = Variable<bool>(staticUrl.value);
    }
    if (forwardType.present) {
      map['forward_type'] = Variable<String>(forwardType.value);
    }
    if (hashtags.present) {
      map['hashtags'] = Variable<String>(hashtags.value);
    }
    if (hashtagsAdditional.present) {
      map['hashtags_additional'] = Variable<String>(hashtagsAdditional.value);
    }
    if (mentions.present) {
      map['mentions'] = Variable<String>(mentions.value);
    }
    if (reactions.present) {
      map['reactions'] = Variable<String>(reactions.value);
    }
    if (urlProps.present) {
      map['url_props'] = Variable<String>(urlProps.value);
    }
    if (fileProps.present) {
      map['file_props'] = Variable<String>(fileProps.value);
    }
    if (systemProps.present) {
      map['system_props'] = Variable<String>(systemProps.value);
    }
    if (props.present) {
      map['props'] = Variable<String>(props.value);
    }
    if (tmpPostId.present) {
      map['tmp_post_id'] = Variable<int>(tmpPostId.value);
    }
    if (state.present) {
      map['state'] = Variable<int>(state.value);
    }
    if (dedupeKey.present) {
      map['dedupe_key'] = Variable<String>(dedupeKey.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PostRowsCompanion(')
          ..write('id: $id, ')
          ..write('postId: $postId, ')
          ..write('channelId: $channelId, ')
          ..write('creatorId: $creatorId, ')
          ..write('threadId: $threadId, ')
          ..write('type: $type, ')
          ..write('message: $message, ')
          ..write('createAt: $createAt, ')
          ..write('updateAt: $updateAt, ')
          ..write('deleteAt: $deleteAt, ')
          ..write('lastCommentAt: $lastCommentAt, ')
          ..write('lastPinAt: $lastPinAt, ')
          ..write('commentCount: $commentCount, ')
          ..write('isStar: $isStar, ')
          ..write('isSticky: $isSticky, ')
          ..write('encrypted: $encrypted, ')
          ..write('safeUrl: $safeUrl, ')
          ..write('staticUrl: $staticUrl, ')
          ..write('forwardType: $forwardType, ')
          ..write('hashtags: $hashtags, ')
          ..write('hashtagsAdditional: $hashtagsAdditional, ')
          ..write('mentions: $mentions, ')
          ..write('reactions: $reactions, ')
          ..write('urlProps: $urlProps, ')
          ..write('fileProps: $fileProps, ')
          ..write('systemProps: $systemProps, ')
          ..write('props: $props, ')
          ..write('tmpPostId: $tmpPostId, ')
          ..write('state: $state, ')
          ..write('dedupeKey: $dedupeKey')
          ..write(')'))
        .toString();
  }
}

class $KeyValueRowsTable extends KeyValueRows
    with TableInfo<$KeyValueRowsTable, KeyValueRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KeyValueRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'key_value_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<KeyValueRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  KeyValueRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KeyValueRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $KeyValueRowsTable createAlias(String alias) {
    return $KeyValueRowsTable(attachedDatabase, alias);
  }
}

class KeyValueRow extends DataClass implements Insertable<KeyValueRow> {
  final String key;
  final String value;
  const KeyValueRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  KeyValueRowsCompanion toCompanion(bool nullToAbsent) {
    return KeyValueRowsCompanion(key: Value(key), value: Value(value));
  }

  factory KeyValueRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KeyValueRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  KeyValueRow copyWith({String? key, String? value}) =>
      KeyValueRow(key: key ?? this.key, value: value ?? this.value);
  KeyValueRow copyWithCompanion(KeyValueRowsCompanion data) {
    return KeyValueRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KeyValueRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KeyValueRow &&
          other.key == this.key &&
          other.value == this.value);
}

class KeyValueRowsCompanion extends UpdateCompanion<KeyValueRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const KeyValueRowsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KeyValueRowsCompanion.insert({
    required String key,
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : key = Value(key);
  static Insertable<KeyValueRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KeyValueRowsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return KeyValueRowsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KeyValueRowsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FileEntryRowsTable extends FileEntryRows
    with TableInfo<$FileEntryRowsTable, FileEntryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FileEntryRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentPathMeta = const VerificationMeta(
    'parentPath',
  );
  @override
  late final GeneratedColumn<String> parentPath = GeneratedColumn<String>(
    'parent_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _isDirMeta = const VerificationMeta('isDir');
  @override
  late final GeneratedColumn<bool> isDir = GeneratedColumn<bool>(
    'is_dir',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_dir" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _mtimeMeta = const VerificationMeta('mtime');
  @override
  late final GeneratedColumn<int> mtime = GeneratedColumn<int>(
    'mtime',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _crtimeMeta = const VerificationMeta('crtime');
  @override
  late final GeneratedColumn<int> crtime = GeneratedColumn<int>(
    'crtime',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _ownerMeta = const VerificationMeta('owner');
  @override
  late final GeneratedColumn<String> owner = GeneratedColumn<String>(
    'owner',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _groupMeta = const VerificationMeta('group');
  @override
  late final GeneratedColumn<String> group = GeneratedColumn<String>(
    'group',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _realPathMeta = const VerificationMeta(
    'realPath',
  );
  @override
  late final GeneratedColumn<String> realPath = GeneratedColumn<String>(
    'real_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _mountPointTypeMeta = const VerificationMeta(
    'mountPointType',
  );
  @override
  late final GeneratedColumn<String> mountPointType = GeneratedColumn<String>(
    'mount_point_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _canReadMeta = const VerificationMeta(
    'canRead',
  );
  @override
  late final GeneratedColumn<bool> canRead = GeneratedColumn<bool>(
    'can_read',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("can_read" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _canWriteMeta = const VerificationMeta(
    'canWrite',
  );
  @override
  late final GeneratedColumn<bool> canWrite = GeneratedColumn<bool>(
    'can_write',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("can_write" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _canExecuteMeta = const VerificationMeta(
    'canExecute',
  );
  @override
  late final GeneratedColumn<bool> canExecute = GeneratedColumn<bool>(
    'can_execute',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("can_execute" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _disableDownloadMeta = const VerificationMeta(
    'disableDownload',
  );
  @override
  late final GeneratedColumn<bool> disableDownload = GeneratedColumn<bool>(
    'disable_download',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("disable_download" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isWormShareMeta = const VerificationMeta(
    'isWormShare',
  );
  @override
  late final GeneratedColumn<bool> isWormShare = GeneratedColumn<bool>(
    'is_worm_share',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_worm_share" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _wormStateMeta = const VerificationMeta(
    'wormState',
  );
  @override
  late final GeneratedColumn<String> wormState = GeneratedColumn<String>(
    'worm_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _cachedAtMeta = const VerificationMeta(
    'cachedAt',
  );
  @override
  late final GeneratedColumn<int> cachedAt = GeneratedColumn<int>(
    'cached_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    path,
    parentPath,
    name,
    isDir,
    size,
    mtime,
    crtime,
    owner,
    group,
    realPath,
    mountPointType,
    description,
    canRead,
    canWrite,
    canExecute,
    disableDownload,
    isWormShare,
    wormState,
    cachedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'file_entry_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<FileEntryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('parent_path')) {
      context.handle(
        _parentPathMeta,
        parentPath.isAcceptableOrUnknown(data['parent_path']!, _parentPathMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('is_dir')) {
      context.handle(
        _isDirMeta,
        isDir.isAcceptableOrUnknown(data['is_dir']!, _isDirMeta),
      );
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    }
    if (data.containsKey('mtime')) {
      context.handle(
        _mtimeMeta,
        mtime.isAcceptableOrUnknown(data['mtime']!, _mtimeMeta),
      );
    }
    if (data.containsKey('crtime')) {
      context.handle(
        _crtimeMeta,
        crtime.isAcceptableOrUnknown(data['crtime']!, _crtimeMeta),
      );
    }
    if (data.containsKey('owner')) {
      context.handle(
        _ownerMeta,
        owner.isAcceptableOrUnknown(data['owner']!, _ownerMeta),
      );
    }
    if (data.containsKey('group')) {
      context.handle(
        _groupMeta,
        group.isAcceptableOrUnknown(data['group']!, _groupMeta),
      );
    }
    if (data.containsKey('real_path')) {
      context.handle(
        _realPathMeta,
        realPath.isAcceptableOrUnknown(data['real_path']!, _realPathMeta),
      );
    }
    if (data.containsKey('mount_point_type')) {
      context.handle(
        _mountPointTypeMeta,
        mountPointType.isAcceptableOrUnknown(
          data['mount_point_type']!,
          _mountPointTypeMeta,
        ),
      );
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('can_read')) {
      context.handle(
        _canReadMeta,
        canRead.isAcceptableOrUnknown(data['can_read']!, _canReadMeta),
      );
    }
    if (data.containsKey('can_write')) {
      context.handle(
        _canWriteMeta,
        canWrite.isAcceptableOrUnknown(data['can_write']!, _canWriteMeta),
      );
    }
    if (data.containsKey('can_execute')) {
      context.handle(
        _canExecuteMeta,
        canExecute.isAcceptableOrUnknown(data['can_execute']!, _canExecuteMeta),
      );
    }
    if (data.containsKey('disable_download')) {
      context.handle(
        _disableDownloadMeta,
        disableDownload.isAcceptableOrUnknown(
          data['disable_download']!,
          _disableDownloadMeta,
        ),
      );
    }
    if (data.containsKey('is_worm_share')) {
      context.handle(
        _isWormShareMeta,
        isWormShare.isAcceptableOrUnknown(
          data['is_worm_share']!,
          _isWormShareMeta,
        ),
      );
    }
    if (data.containsKey('worm_state')) {
      context.handle(
        _wormStateMeta,
        wormState.isAcceptableOrUnknown(data['worm_state']!, _wormStateMeta),
      );
    }
    if (data.containsKey('cached_at')) {
      context.handle(
        _cachedAtMeta,
        cachedAt.isAcceptableOrUnknown(data['cached_at']!, _cachedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {path};
  @override
  FileEntryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FileEntryRow(
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      parentPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_path'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      isDir: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_dir'],
      )!,
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      )!,
      mtime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}mtime'],
      )!,
      crtime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}crtime'],
      )!,
      owner: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner'],
      )!,
      group: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group'],
      )!,
      realPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}real_path'],
      )!,
      mountPointType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mount_point_type'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      )!,
      canRead: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}can_read'],
      )!,
      canWrite: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}can_write'],
      )!,
      canExecute: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}can_execute'],
      )!,
      disableDownload: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}disable_download'],
      )!,
      isWormShare: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_worm_share'],
      )!,
      wormState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}worm_state'],
      )!,
      cachedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cached_at'],
      )!,
    );
  }

  @override
  $FileEntryRowsTable createAlias(String alias) {
    return $FileEntryRowsTable(attachedDatabase, alias);
  }
}

class FileEntryRow extends DataClass implements Insertable<FileEntryRow> {
  final String path;

  /// 所属目录（列表接口的 `folder_path`）
  final String parentPath;
  final String name;
  final bool isDir;
  final int size;

  /// 秒级时间戳（FileStation 给的就是秒）
  final int mtime;
  final int crtime;
  final String owner;
  final String group;
  final String realPath;
  final String mountPointType;
  final String description;
  final bool canRead;
  final bool canWrite;
  final bool canExecute;
  final bool disableDownload;
  final bool isWormShare;

  /// WORM 状态线上值（`additional.worm_state`，0..9 的下标）。
  ///
  /// 为什么不直接存 `wormLocked` 布尔：官方 `WormVo.State` 里"锁定"只是
  /// `value & 32` 的一位，过期态（64/65）同样不可删改但语义不同，缓存原文比
  /// 缓存推导结果更抗变化。空串 = **未知**（老库升上来 / 服务端没给这个字段），
  /// 读取时还原成 `FileEntryDto.wormState == null` → [FileEntryDto.wormLocked]
  /// 为 false，保持 C5 的 fail-open（未知不拦）。
  final String wormState;

  /// 这行是什么时候抓下来的（毫秒）—— UI 用它显示"缓存于 …"
  final int cachedAt;
  const FileEntryRow({
    required this.path,
    required this.parentPath,
    required this.name,
    required this.isDir,
    required this.size,
    required this.mtime,
    required this.crtime,
    required this.owner,
    required this.group,
    required this.realPath,
    required this.mountPointType,
    required this.description,
    required this.canRead,
    required this.canWrite,
    required this.canExecute,
    required this.disableDownload,
    required this.isWormShare,
    required this.wormState,
    required this.cachedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['path'] = Variable<String>(path);
    map['parent_path'] = Variable<String>(parentPath);
    map['name'] = Variable<String>(name);
    map['is_dir'] = Variable<bool>(isDir);
    map['size'] = Variable<int>(size);
    map['mtime'] = Variable<int>(mtime);
    map['crtime'] = Variable<int>(crtime);
    map['owner'] = Variable<String>(owner);
    map['group'] = Variable<String>(group);
    map['real_path'] = Variable<String>(realPath);
    map['mount_point_type'] = Variable<String>(mountPointType);
    map['description'] = Variable<String>(description);
    map['can_read'] = Variable<bool>(canRead);
    map['can_write'] = Variable<bool>(canWrite);
    map['can_execute'] = Variable<bool>(canExecute);
    map['disable_download'] = Variable<bool>(disableDownload);
    map['is_worm_share'] = Variable<bool>(isWormShare);
    map['worm_state'] = Variable<String>(wormState);
    map['cached_at'] = Variable<int>(cachedAt);
    return map;
  }

  FileEntryRowsCompanion toCompanion(bool nullToAbsent) {
    return FileEntryRowsCompanion(
      path: Value(path),
      parentPath: Value(parentPath),
      name: Value(name),
      isDir: Value(isDir),
      size: Value(size),
      mtime: Value(mtime),
      crtime: Value(crtime),
      owner: Value(owner),
      group: Value(group),
      realPath: Value(realPath),
      mountPointType: Value(mountPointType),
      description: Value(description),
      canRead: Value(canRead),
      canWrite: Value(canWrite),
      canExecute: Value(canExecute),
      disableDownload: Value(disableDownload),
      isWormShare: Value(isWormShare),
      wormState: Value(wormState),
      cachedAt: Value(cachedAt),
    );
  }

  factory FileEntryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FileEntryRow(
      path: serializer.fromJson<String>(json['path']),
      parentPath: serializer.fromJson<String>(json['parentPath']),
      name: serializer.fromJson<String>(json['name']),
      isDir: serializer.fromJson<bool>(json['isDir']),
      size: serializer.fromJson<int>(json['size']),
      mtime: serializer.fromJson<int>(json['mtime']),
      crtime: serializer.fromJson<int>(json['crtime']),
      owner: serializer.fromJson<String>(json['owner']),
      group: serializer.fromJson<String>(json['group']),
      realPath: serializer.fromJson<String>(json['realPath']),
      mountPointType: serializer.fromJson<String>(json['mountPointType']),
      description: serializer.fromJson<String>(json['description']),
      canRead: serializer.fromJson<bool>(json['canRead']),
      canWrite: serializer.fromJson<bool>(json['canWrite']),
      canExecute: serializer.fromJson<bool>(json['canExecute']),
      disableDownload: serializer.fromJson<bool>(json['disableDownload']),
      isWormShare: serializer.fromJson<bool>(json['isWormShare']),
      wormState: serializer.fromJson<String>(json['wormState']),
      cachedAt: serializer.fromJson<int>(json['cachedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'path': serializer.toJson<String>(path),
      'parentPath': serializer.toJson<String>(parentPath),
      'name': serializer.toJson<String>(name),
      'isDir': serializer.toJson<bool>(isDir),
      'size': serializer.toJson<int>(size),
      'mtime': serializer.toJson<int>(mtime),
      'crtime': serializer.toJson<int>(crtime),
      'owner': serializer.toJson<String>(owner),
      'group': serializer.toJson<String>(group),
      'realPath': serializer.toJson<String>(realPath),
      'mountPointType': serializer.toJson<String>(mountPointType),
      'description': serializer.toJson<String>(description),
      'canRead': serializer.toJson<bool>(canRead),
      'canWrite': serializer.toJson<bool>(canWrite),
      'canExecute': serializer.toJson<bool>(canExecute),
      'disableDownload': serializer.toJson<bool>(disableDownload),
      'isWormShare': serializer.toJson<bool>(isWormShare),
      'wormState': serializer.toJson<String>(wormState),
      'cachedAt': serializer.toJson<int>(cachedAt),
    };
  }

  FileEntryRow copyWith({
    String? path,
    String? parentPath,
    String? name,
    bool? isDir,
    int? size,
    int? mtime,
    int? crtime,
    String? owner,
    String? group,
    String? realPath,
    String? mountPointType,
    String? description,
    bool? canRead,
    bool? canWrite,
    bool? canExecute,
    bool? disableDownload,
    bool? isWormShare,
    String? wormState,
    int? cachedAt,
  }) => FileEntryRow(
    path: path ?? this.path,
    parentPath: parentPath ?? this.parentPath,
    name: name ?? this.name,
    isDir: isDir ?? this.isDir,
    size: size ?? this.size,
    mtime: mtime ?? this.mtime,
    crtime: crtime ?? this.crtime,
    owner: owner ?? this.owner,
    group: group ?? this.group,
    realPath: realPath ?? this.realPath,
    mountPointType: mountPointType ?? this.mountPointType,
    description: description ?? this.description,
    canRead: canRead ?? this.canRead,
    canWrite: canWrite ?? this.canWrite,
    canExecute: canExecute ?? this.canExecute,
    disableDownload: disableDownload ?? this.disableDownload,
    isWormShare: isWormShare ?? this.isWormShare,
    wormState: wormState ?? this.wormState,
    cachedAt: cachedAt ?? this.cachedAt,
  );
  FileEntryRow copyWithCompanion(FileEntryRowsCompanion data) {
    return FileEntryRow(
      path: data.path.present ? data.path.value : this.path,
      parentPath: data.parentPath.present
          ? data.parentPath.value
          : this.parentPath,
      name: data.name.present ? data.name.value : this.name,
      isDir: data.isDir.present ? data.isDir.value : this.isDir,
      size: data.size.present ? data.size.value : this.size,
      mtime: data.mtime.present ? data.mtime.value : this.mtime,
      crtime: data.crtime.present ? data.crtime.value : this.crtime,
      owner: data.owner.present ? data.owner.value : this.owner,
      group: data.group.present ? data.group.value : this.group,
      realPath: data.realPath.present ? data.realPath.value : this.realPath,
      mountPointType: data.mountPointType.present
          ? data.mountPointType.value
          : this.mountPointType,
      description: data.description.present
          ? data.description.value
          : this.description,
      canRead: data.canRead.present ? data.canRead.value : this.canRead,
      canWrite: data.canWrite.present ? data.canWrite.value : this.canWrite,
      canExecute: data.canExecute.present
          ? data.canExecute.value
          : this.canExecute,
      disableDownload: data.disableDownload.present
          ? data.disableDownload.value
          : this.disableDownload,
      isWormShare: data.isWormShare.present
          ? data.isWormShare.value
          : this.isWormShare,
      wormState: data.wormState.present ? data.wormState.value : this.wormState,
      cachedAt: data.cachedAt.present ? data.cachedAt.value : this.cachedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FileEntryRow(')
          ..write('path: $path, ')
          ..write('parentPath: $parentPath, ')
          ..write('name: $name, ')
          ..write('isDir: $isDir, ')
          ..write('size: $size, ')
          ..write('mtime: $mtime, ')
          ..write('crtime: $crtime, ')
          ..write('owner: $owner, ')
          ..write('group: $group, ')
          ..write('realPath: $realPath, ')
          ..write('mountPointType: $mountPointType, ')
          ..write('description: $description, ')
          ..write('canRead: $canRead, ')
          ..write('canWrite: $canWrite, ')
          ..write('canExecute: $canExecute, ')
          ..write('disableDownload: $disableDownload, ')
          ..write('isWormShare: $isWormShare, ')
          ..write('wormState: $wormState, ')
          ..write('cachedAt: $cachedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    path,
    parentPath,
    name,
    isDir,
    size,
    mtime,
    crtime,
    owner,
    group,
    realPath,
    mountPointType,
    description,
    canRead,
    canWrite,
    canExecute,
    disableDownload,
    isWormShare,
    wormState,
    cachedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FileEntryRow &&
          other.path == this.path &&
          other.parentPath == this.parentPath &&
          other.name == this.name &&
          other.isDir == this.isDir &&
          other.size == this.size &&
          other.mtime == this.mtime &&
          other.crtime == this.crtime &&
          other.owner == this.owner &&
          other.group == this.group &&
          other.realPath == this.realPath &&
          other.mountPointType == this.mountPointType &&
          other.description == this.description &&
          other.canRead == this.canRead &&
          other.canWrite == this.canWrite &&
          other.canExecute == this.canExecute &&
          other.disableDownload == this.disableDownload &&
          other.isWormShare == this.isWormShare &&
          other.wormState == this.wormState &&
          other.cachedAt == this.cachedAt);
}

class FileEntryRowsCompanion extends UpdateCompanion<FileEntryRow> {
  final Value<String> path;
  final Value<String> parentPath;
  final Value<String> name;
  final Value<bool> isDir;
  final Value<int> size;
  final Value<int> mtime;
  final Value<int> crtime;
  final Value<String> owner;
  final Value<String> group;
  final Value<String> realPath;
  final Value<String> mountPointType;
  final Value<String> description;
  final Value<bool> canRead;
  final Value<bool> canWrite;
  final Value<bool> canExecute;
  final Value<bool> disableDownload;
  final Value<bool> isWormShare;
  final Value<String> wormState;
  final Value<int> cachedAt;
  final Value<int> rowid;
  const FileEntryRowsCompanion({
    this.path = const Value.absent(),
    this.parentPath = const Value.absent(),
    this.name = const Value.absent(),
    this.isDir = const Value.absent(),
    this.size = const Value.absent(),
    this.mtime = const Value.absent(),
    this.crtime = const Value.absent(),
    this.owner = const Value.absent(),
    this.group = const Value.absent(),
    this.realPath = const Value.absent(),
    this.mountPointType = const Value.absent(),
    this.description = const Value.absent(),
    this.canRead = const Value.absent(),
    this.canWrite = const Value.absent(),
    this.canExecute = const Value.absent(),
    this.disableDownload = const Value.absent(),
    this.isWormShare = const Value.absent(),
    this.wormState = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FileEntryRowsCompanion.insert({
    required String path,
    this.parentPath = const Value.absent(),
    this.name = const Value.absent(),
    this.isDir = const Value.absent(),
    this.size = const Value.absent(),
    this.mtime = const Value.absent(),
    this.crtime = const Value.absent(),
    this.owner = const Value.absent(),
    this.group = const Value.absent(),
    this.realPath = const Value.absent(),
    this.mountPointType = const Value.absent(),
    this.description = const Value.absent(),
    this.canRead = const Value.absent(),
    this.canWrite = const Value.absent(),
    this.canExecute = const Value.absent(),
    this.disableDownload = const Value.absent(),
    this.isWormShare = const Value.absent(),
    this.wormState = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : path = Value(path);
  static Insertable<FileEntryRow> custom({
    Expression<String>? path,
    Expression<String>? parentPath,
    Expression<String>? name,
    Expression<bool>? isDir,
    Expression<int>? size,
    Expression<int>? mtime,
    Expression<int>? crtime,
    Expression<String>? owner,
    Expression<String>? group,
    Expression<String>? realPath,
    Expression<String>? mountPointType,
    Expression<String>? description,
    Expression<bool>? canRead,
    Expression<bool>? canWrite,
    Expression<bool>? canExecute,
    Expression<bool>? disableDownload,
    Expression<bool>? isWormShare,
    Expression<String>? wormState,
    Expression<int>? cachedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (path != null) 'path': path,
      if (parentPath != null) 'parent_path': parentPath,
      if (name != null) 'name': name,
      if (isDir != null) 'is_dir': isDir,
      if (size != null) 'size': size,
      if (mtime != null) 'mtime': mtime,
      if (crtime != null) 'crtime': crtime,
      if (owner != null) 'owner': owner,
      if (group != null) 'group': group,
      if (realPath != null) 'real_path': realPath,
      if (mountPointType != null) 'mount_point_type': mountPointType,
      if (description != null) 'description': description,
      if (canRead != null) 'can_read': canRead,
      if (canWrite != null) 'can_write': canWrite,
      if (canExecute != null) 'can_execute': canExecute,
      if (disableDownload != null) 'disable_download': disableDownload,
      if (isWormShare != null) 'is_worm_share': isWormShare,
      if (wormState != null) 'worm_state': wormState,
      if (cachedAt != null) 'cached_at': cachedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FileEntryRowsCompanion copyWith({
    Value<String>? path,
    Value<String>? parentPath,
    Value<String>? name,
    Value<bool>? isDir,
    Value<int>? size,
    Value<int>? mtime,
    Value<int>? crtime,
    Value<String>? owner,
    Value<String>? group,
    Value<String>? realPath,
    Value<String>? mountPointType,
    Value<String>? description,
    Value<bool>? canRead,
    Value<bool>? canWrite,
    Value<bool>? canExecute,
    Value<bool>? disableDownload,
    Value<bool>? isWormShare,
    Value<String>? wormState,
    Value<int>? cachedAt,
    Value<int>? rowid,
  }) {
    return FileEntryRowsCompanion(
      path: path ?? this.path,
      parentPath: parentPath ?? this.parentPath,
      name: name ?? this.name,
      isDir: isDir ?? this.isDir,
      size: size ?? this.size,
      mtime: mtime ?? this.mtime,
      crtime: crtime ?? this.crtime,
      owner: owner ?? this.owner,
      group: group ?? this.group,
      realPath: realPath ?? this.realPath,
      mountPointType: mountPointType ?? this.mountPointType,
      description: description ?? this.description,
      canRead: canRead ?? this.canRead,
      canWrite: canWrite ?? this.canWrite,
      canExecute: canExecute ?? this.canExecute,
      disableDownload: disableDownload ?? this.disableDownload,
      isWormShare: isWormShare ?? this.isWormShare,
      wormState: wormState ?? this.wormState,
      cachedAt: cachedAt ?? this.cachedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (parentPath.present) {
      map['parent_path'] = Variable<String>(parentPath.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (isDir.present) {
      map['is_dir'] = Variable<bool>(isDir.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (mtime.present) {
      map['mtime'] = Variable<int>(mtime.value);
    }
    if (crtime.present) {
      map['crtime'] = Variable<int>(crtime.value);
    }
    if (owner.present) {
      map['owner'] = Variable<String>(owner.value);
    }
    if (group.present) {
      map['group'] = Variable<String>(group.value);
    }
    if (realPath.present) {
      map['real_path'] = Variable<String>(realPath.value);
    }
    if (mountPointType.present) {
      map['mount_point_type'] = Variable<String>(mountPointType.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (canRead.present) {
      map['can_read'] = Variable<bool>(canRead.value);
    }
    if (canWrite.present) {
      map['can_write'] = Variable<bool>(canWrite.value);
    }
    if (canExecute.present) {
      map['can_execute'] = Variable<bool>(canExecute.value);
    }
    if (disableDownload.present) {
      map['disable_download'] = Variable<bool>(disableDownload.value);
    }
    if (isWormShare.present) {
      map['is_worm_share'] = Variable<bool>(isWormShare.value);
    }
    if (wormState.present) {
      map['worm_state'] = Variable<String>(wormState.value);
    }
    if (cachedAt.present) {
      map['cached_at'] = Variable<int>(cachedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FileEntryRowsCompanion(')
          ..write('path: $path, ')
          ..write('parentPath: $parentPath, ')
          ..write('name: $name, ')
          ..write('isDir: $isDir, ')
          ..write('size: $size, ')
          ..write('mtime: $mtime, ')
          ..write('crtime: $crtime, ')
          ..write('owner: $owner, ')
          ..write('group: $group, ')
          ..write('realPath: $realPath, ')
          ..write('mountPointType: $mountPointType, ')
          ..write('description: $description, ')
          ..write('canRead: $canRead, ')
          ..write('canWrite: $canWrite, ')
          ..write('canExecute: $canExecute, ')
          ..write('disableDownload: $disableDownload, ')
          ..write('isWormShare: $isWormShare, ')
          ..write('wormState: $wormState, ')
          ..write('cachedAt: $cachedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $NoteCacheRowsTable extends NoteCacheRows
    with TableInfo<$NoteCacheRowsTable, NoteCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NoteCacheRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountKeyMeta = const VerificationMeta(
    'accountKey',
  );
  @override
  late final GeneratedColumn<String> accountKey = GeneratedColumn<String>(
    'account_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _objectIdMeta = const VerificationMeta(
    'objectId',
  );
  @override
  late final GeneratedColumn<String> objectId = GeneratedColumn<String>(
    'object_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _notebookIdMeta = const VerificationMeta(
    'notebookId',
  );
  @override
  late final GeneratedColumn<String> notebookId = GeneratedColumn<String>(
    'notebook_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _briefMeta = const VerificationMeta('brief');
  @override
  late final GeneratedColumn<String> brief = GeneratedColumn<String>(
    'brief',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _hasContentMeta = const VerificationMeta(
    'hasContent',
  );
  @override
  late final GeneratedColumn<bool> hasContent = GeneratedColumn<bool>(
    'has_content',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_content" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _attachmentsJsonMeta = const VerificationMeta(
    'attachmentsJson',
  );
  @override
  late final GeneratedColumn<String> attachmentsJson = GeneratedColumn<String>(
    'attachments_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _encryptMeta = const VerificationMeta(
    'encrypt',
  );
  @override
  late final GeneratedColumn<bool> encrypt = GeneratedColumn<bool>(
    'encrypt',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("encrypt" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _recycleMeta = const VerificationMeta(
    'recycle',
  );
  @override
  late final GeneratedColumn<bool> recycle = GeneratedColumn<bool>(
    'recycle',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("recycle" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _verMeta = const VerificationMeta('ver');
  @override
  late final GeneratedColumn<String> ver = GeneratedColumn<String>(
    'ver',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _ctimeMeta = const VerificationMeta('ctime');
  @override
  late final GeneratedColumn<int> ctime = GeneratedColumn<int>(
    'ctime',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _mtimeMeta = const VerificationMeta('mtime');
  @override
  late final GeneratedColumn<int> mtime = GeneratedColumn<int>(
    'mtime',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _ownerNameMeta = const VerificationMeta(
    'ownerName',
  );
  @override
  late final GeneratedColumn<String> ownerName = GeneratedColumn<String>(
    'owner_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _syncedAtMeta = const VerificationMeta(
    'syncedAt',
  );
  @override
  late final GeneratedColumn<int> syncedAt = GeneratedColumn<int>(
    'synced_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountKey,
    objectId,
    notebookId,
    title,
    brief,
    content,
    hasContent,
    tagsJson,
    attachmentsJson,
    encrypt,
    recycle,
    ver,
    ctime,
    mtime,
    ownerName,
    dirty,
    syncedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'note_cache_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<NoteCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_key')) {
      context.handle(
        _accountKeyMeta,
        accountKey.isAcceptableOrUnknown(data['account_key']!, _accountKeyMeta),
      );
    }
    if (data.containsKey('object_id')) {
      context.handle(
        _objectIdMeta,
        objectId.isAcceptableOrUnknown(data['object_id']!, _objectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_objectIdMeta);
    }
    if (data.containsKey('notebook_id')) {
      context.handle(
        _notebookIdMeta,
        notebookId.isAcceptableOrUnknown(data['notebook_id']!, _notebookIdMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('brief')) {
      context.handle(
        _briefMeta,
        brief.isAcceptableOrUnknown(data['brief']!, _briefMeta),
      );
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    }
    if (data.containsKey('has_content')) {
      context.handle(
        _hasContentMeta,
        hasContent.isAcceptableOrUnknown(data['has_content']!, _hasContentMeta),
      );
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
      );
    }
    if (data.containsKey('attachments_json')) {
      context.handle(
        _attachmentsJsonMeta,
        attachmentsJson.isAcceptableOrUnknown(
          data['attachments_json']!,
          _attachmentsJsonMeta,
        ),
      );
    }
    if (data.containsKey('encrypt')) {
      context.handle(
        _encryptMeta,
        encrypt.isAcceptableOrUnknown(data['encrypt']!, _encryptMeta),
      );
    }
    if (data.containsKey('recycle')) {
      context.handle(
        _recycleMeta,
        recycle.isAcceptableOrUnknown(data['recycle']!, _recycleMeta),
      );
    }
    if (data.containsKey('ver')) {
      context.handle(
        _verMeta,
        ver.isAcceptableOrUnknown(data['ver']!, _verMeta),
      );
    }
    if (data.containsKey('ctime')) {
      context.handle(
        _ctimeMeta,
        ctime.isAcceptableOrUnknown(data['ctime']!, _ctimeMeta),
      );
    }
    if (data.containsKey('mtime')) {
      context.handle(
        _mtimeMeta,
        mtime.isAcceptableOrUnknown(data['mtime']!, _mtimeMeta),
      );
    }
    if (data.containsKey('owner_name')) {
      context.handle(
        _ownerNameMeta,
        ownerName.isAcceptableOrUnknown(data['owner_name']!, _ownerNameMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('synced_at')) {
      context.handle(
        _syncedAtMeta,
        syncedAt.isAcceptableOrUnknown(data['synced_at']!, _syncedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountKey, objectId};
  @override
  NoteCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NoteCacheRow(
      accountKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_key'],
      )!,
      objectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}object_id'],
      )!,
      notebookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notebook_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      brief: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}brief'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      hasContent: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_content'],
      )!,
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      )!,
      attachmentsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attachments_json'],
      )!,
      encrypt: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}encrypt'],
      )!,
      recycle: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}recycle'],
      )!,
      ver: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ver'],
      )!,
      ctime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ctime'],
      )!,
      mtime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}mtime'],
      )!,
      ownerName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_name'],
      )!,
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      syncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_at'],
      )!,
    );
  }

  @override
  $NoteCacheRowsTable createAlias(String alias) {
    return $NoteCacheRowsTable(attachedDatabase, alias);
  }
}

class NoteCacheRow extends DataClass implements Insertable<NoteCacheRow> {
  /// ★ N5（236 轮）：这条缓存属于**哪个 NAS 账号**（多 NAS 共用同一个库文件，
  /// 不隔离就会出现 A 的笔记在 B 登录时被 diff 当成「服务端删了」或被同 id 覆盖）。
  /// 默认空串 = 老库 / 未登录（兼容 v13 及以前）。
  final String accountKey;
  final String objectId;
  final String notebookId;
  final String title;
  final String brief;

  /// 明文正文；加密笔记这里是**密文**（解密只在内存里做）
  /// 明文正文；加密笔记这里是**密文**（解密只在内存里做）
  final String content;

  /// 正文是否已抓过（空字符串 ≠ "没有正文"，比如空笔记）
  final bool hasContent;
  final String tagsJson;
  final String attachmentsJson;
  final bool encrypt;
  final bool recycle;
  final String ver;
  final int ctime;
  final int mtime;
  final String ownerName;

  /// 本地有未上传的改动（离线编辑过）
  final bool dirty;

  /// 这行是什么时候同步下来的（毫秒）
  final int syncedAt;
  const NoteCacheRow({
    required this.accountKey,
    required this.objectId,
    required this.notebookId,
    required this.title,
    required this.brief,
    required this.content,
    required this.hasContent,
    required this.tagsJson,
    required this.attachmentsJson,
    required this.encrypt,
    required this.recycle,
    required this.ver,
    required this.ctime,
    required this.mtime,
    required this.ownerName,
    required this.dirty,
    required this.syncedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_key'] = Variable<String>(accountKey);
    map['object_id'] = Variable<String>(objectId);
    map['notebook_id'] = Variable<String>(notebookId);
    map['title'] = Variable<String>(title);
    map['brief'] = Variable<String>(brief);
    map['content'] = Variable<String>(content);
    map['has_content'] = Variable<bool>(hasContent);
    map['tags_json'] = Variable<String>(tagsJson);
    map['attachments_json'] = Variable<String>(attachmentsJson);
    map['encrypt'] = Variable<bool>(encrypt);
    map['recycle'] = Variable<bool>(recycle);
    map['ver'] = Variable<String>(ver);
    map['ctime'] = Variable<int>(ctime);
    map['mtime'] = Variable<int>(mtime);
    map['owner_name'] = Variable<String>(ownerName);
    map['dirty'] = Variable<bool>(dirty);
    map['synced_at'] = Variable<int>(syncedAt);
    return map;
  }

  NoteCacheRowsCompanion toCompanion(bool nullToAbsent) {
    return NoteCacheRowsCompanion(
      accountKey: Value(accountKey),
      objectId: Value(objectId),
      notebookId: Value(notebookId),
      title: Value(title),
      brief: Value(brief),
      content: Value(content),
      hasContent: Value(hasContent),
      tagsJson: Value(tagsJson),
      attachmentsJson: Value(attachmentsJson),
      encrypt: Value(encrypt),
      recycle: Value(recycle),
      ver: Value(ver),
      ctime: Value(ctime),
      mtime: Value(mtime),
      ownerName: Value(ownerName),
      dirty: Value(dirty),
      syncedAt: Value(syncedAt),
    );
  }

  factory NoteCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NoteCacheRow(
      accountKey: serializer.fromJson<String>(json['accountKey']),
      objectId: serializer.fromJson<String>(json['objectId']),
      notebookId: serializer.fromJson<String>(json['notebookId']),
      title: serializer.fromJson<String>(json['title']),
      brief: serializer.fromJson<String>(json['brief']),
      content: serializer.fromJson<String>(json['content']),
      hasContent: serializer.fromJson<bool>(json['hasContent']),
      tagsJson: serializer.fromJson<String>(json['tagsJson']),
      attachmentsJson: serializer.fromJson<String>(json['attachmentsJson']),
      encrypt: serializer.fromJson<bool>(json['encrypt']),
      recycle: serializer.fromJson<bool>(json['recycle']),
      ver: serializer.fromJson<String>(json['ver']),
      ctime: serializer.fromJson<int>(json['ctime']),
      mtime: serializer.fromJson<int>(json['mtime']),
      ownerName: serializer.fromJson<String>(json['ownerName']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      syncedAt: serializer.fromJson<int>(json['syncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountKey': serializer.toJson<String>(accountKey),
      'objectId': serializer.toJson<String>(objectId),
      'notebookId': serializer.toJson<String>(notebookId),
      'title': serializer.toJson<String>(title),
      'brief': serializer.toJson<String>(brief),
      'content': serializer.toJson<String>(content),
      'hasContent': serializer.toJson<bool>(hasContent),
      'tagsJson': serializer.toJson<String>(tagsJson),
      'attachmentsJson': serializer.toJson<String>(attachmentsJson),
      'encrypt': serializer.toJson<bool>(encrypt),
      'recycle': serializer.toJson<bool>(recycle),
      'ver': serializer.toJson<String>(ver),
      'ctime': serializer.toJson<int>(ctime),
      'mtime': serializer.toJson<int>(mtime),
      'ownerName': serializer.toJson<String>(ownerName),
      'dirty': serializer.toJson<bool>(dirty),
      'syncedAt': serializer.toJson<int>(syncedAt),
    };
  }

  NoteCacheRow copyWith({
    String? accountKey,
    String? objectId,
    String? notebookId,
    String? title,
    String? brief,
    String? content,
    bool? hasContent,
    String? tagsJson,
    String? attachmentsJson,
    bool? encrypt,
    bool? recycle,
    String? ver,
    int? ctime,
    int? mtime,
    String? ownerName,
    bool? dirty,
    int? syncedAt,
  }) => NoteCacheRow(
    accountKey: accountKey ?? this.accountKey,
    objectId: objectId ?? this.objectId,
    notebookId: notebookId ?? this.notebookId,
    title: title ?? this.title,
    brief: brief ?? this.brief,
    content: content ?? this.content,
    hasContent: hasContent ?? this.hasContent,
    tagsJson: tagsJson ?? this.tagsJson,
    attachmentsJson: attachmentsJson ?? this.attachmentsJson,
    encrypt: encrypt ?? this.encrypt,
    recycle: recycle ?? this.recycle,
    ver: ver ?? this.ver,
    ctime: ctime ?? this.ctime,
    mtime: mtime ?? this.mtime,
    ownerName: ownerName ?? this.ownerName,
    dirty: dirty ?? this.dirty,
    syncedAt: syncedAt ?? this.syncedAt,
  );
  NoteCacheRow copyWithCompanion(NoteCacheRowsCompanion data) {
    return NoteCacheRow(
      accountKey: data.accountKey.present
          ? data.accountKey.value
          : this.accountKey,
      objectId: data.objectId.present ? data.objectId.value : this.objectId,
      notebookId: data.notebookId.present
          ? data.notebookId.value
          : this.notebookId,
      title: data.title.present ? data.title.value : this.title,
      brief: data.brief.present ? data.brief.value : this.brief,
      content: data.content.present ? data.content.value : this.content,
      hasContent: data.hasContent.present
          ? data.hasContent.value
          : this.hasContent,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
      attachmentsJson: data.attachmentsJson.present
          ? data.attachmentsJson.value
          : this.attachmentsJson,
      encrypt: data.encrypt.present ? data.encrypt.value : this.encrypt,
      recycle: data.recycle.present ? data.recycle.value : this.recycle,
      ver: data.ver.present ? data.ver.value : this.ver,
      ctime: data.ctime.present ? data.ctime.value : this.ctime,
      mtime: data.mtime.present ? data.mtime.value : this.mtime,
      ownerName: data.ownerName.present ? data.ownerName.value : this.ownerName,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      syncedAt: data.syncedAt.present ? data.syncedAt.value : this.syncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NoteCacheRow(')
          ..write('accountKey: $accountKey, ')
          ..write('objectId: $objectId, ')
          ..write('notebookId: $notebookId, ')
          ..write('title: $title, ')
          ..write('brief: $brief, ')
          ..write('content: $content, ')
          ..write('hasContent: $hasContent, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('attachmentsJson: $attachmentsJson, ')
          ..write('encrypt: $encrypt, ')
          ..write('recycle: $recycle, ')
          ..write('ver: $ver, ')
          ..write('ctime: $ctime, ')
          ..write('mtime: $mtime, ')
          ..write('ownerName: $ownerName, ')
          ..write('dirty: $dirty, ')
          ..write('syncedAt: $syncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountKey,
    objectId,
    notebookId,
    title,
    brief,
    content,
    hasContent,
    tagsJson,
    attachmentsJson,
    encrypt,
    recycle,
    ver,
    ctime,
    mtime,
    ownerName,
    dirty,
    syncedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NoteCacheRow &&
          other.accountKey == this.accountKey &&
          other.objectId == this.objectId &&
          other.notebookId == this.notebookId &&
          other.title == this.title &&
          other.brief == this.brief &&
          other.content == this.content &&
          other.hasContent == this.hasContent &&
          other.tagsJson == this.tagsJson &&
          other.attachmentsJson == this.attachmentsJson &&
          other.encrypt == this.encrypt &&
          other.recycle == this.recycle &&
          other.ver == this.ver &&
          other.ctime == this.ctime &&
          other.mtime == this.mtime &&
          other.ownerName == this.ownerName &&
          other.dirty == this.dirty &&
          other.syncedAt == this.syncedAt);
}

class NoteCacheRowsCompanion extends UpdateCompanion<NoteCacheRow> {
  final Value<String> accountKey;
  final Value<String> objectId;
  final Value<String> notebookId;
  final Value<String> title;
  final Value<String> brief;
  final Value<String> content;
  final Value<bool> hasContent;
  final Value<String> tagsJson;
  final Value<String> attachmentsJson;
  final Value<bool> encrypt;
  final Value<bool> recycle;
  final Value<String> ver;
  final Value<int> ctime;
  final Value<int> mtime;
  final Value<String> ownerName;
  final Value<bool> dirty;
  final Value<int> syncedAt;
  final Value<int> rowid;
  const NoteCacheRowsCompanion({
    this.accountKey = const Value.absent(),
    this.objectId = const Value.absent(),
    this.notebookId = const Value.absent(),
    this.title = const Value.absent(),
    this.brief = const Value.absent(),
    this.content = const Value.absent(),
    this.hasContent = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.attachmentsJson = const Value.absent(),
    this.encrypt = const Value.absent(),
    this.recycle = const Value.absent(),
    this.ver = const Value.absent(),
    this.ctime = const Value.absent(),
    this.mtime = const Value.absent(),
    this.ownerName = const Value.absent(),
    this.dirty = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NoteCacheRowsCompanion.insert({
    this.accountKey = const Value.absent(),
    required String objectId,
    this.notebookId = const Value.absent(),
    this.title = const Value.absent(),
    this.brief = const Value.absent(),
    this.content = const Value.absent(),
    this.hasContent = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.attachmentsJson = const Value.absent(),
    this.encrypt = const Value.absent(),
    this.recycle = const Value.absent(),
    this.ver = const Value.absent(),
    this.ctime = const Value.absent(),
    this.mtime = const Value.absent(),
    this.ownerName = const Value.absent(),
    this.dirty = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : objectId = Value(objectId);
  static Insertable<NoteCacheRow> custom({
    Expression<String>? accountKey,
    Expression<String>? objectId,
    Expression<String>? notebookId,
    Expression<String>? title,
    Expression<String>? brief,
    Expression<String>? content,
    Expression<bool>? hasContent,
    Expression<String>? tagsJson,
    Expression<String>? attachmentsJson,
    Expression<bool>? encrypt,
    Expression<bool>? recycle,
    Expression<String>? ver,
    Expression<int>? ctime,
    Expression<int>? mtime,
    Expression<String>? ownerName,
    Expression<bool>? dirty,
    Expression<int>? syncedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountKey != null) 'account_key': accountKey,
      if (objectId != null) 'object_id': objectId,
      if (notebookId != null) 'notebook_id': notebookId,
      if (title != null) 'title': title,
      if (brief != null) 'brief': brief,
      if (content != null) 'content': content,
      if (hasContent != null) 'has_content': hasContent,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (attachmentsJson != null) 'attachments_json': attachmentsJson,
      if (encrypt != null) 'encrypt': encrypt,
      if (recycle != null) 'recycle': recycle,
      if (ver != null) 'ver': ver,
      if (ctime != null) 'ctime': ctime,
      if (mtime != null) 'mtime': mtime,
      if (ownerName != null) 'owner_name': ownerName,
      if (dirty != null) 'dirty': dirty,
      if (syncedAt != null) 'synced_at': syncedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NoteCacheRowsCompanion copyWith({
    Value<String>? accountKey,
    Value<String>? objectId,
    Value<String>? notebookId,
    Value<String>? title,
    Value<String>? brief,
    Value<String>? content,
    Value<bool>? hasContent,
    Value<String>? tagsJson,
    Value<String>? attachmentsJson,
    Value<bool>? encrypt,
    Value<bool>? recycle,
    Value<String>? ver,
    Value<int>? ctime,
    Value<int>? mtime,
    Value<String>? ownerName,
    Value<bool>? dirty,
    Value<int>? syncedAt,
    Value<int>? rowid,
  }) {
    return NoteCacheRowsCompanion(
      accountKey: accountKey ?? this.accountKey,
      objectId: objectId ?? this.objectId,
      notebookId: notebookId ?? this.notebookId,
      title: title ?? this.title,
      brief: brief ?? this.brief,
      content: content ?? this.content,
      hasContent: hasContent ?? this.hasContent,
      tagsJson: tagsJson ?? this.tagsJson,
      attachmentsJson: attachmentsJson ?? this.attachmentsJson,
      encrypt: encrypt ?? this.encrypt,
      recycle: recycle ?? this.recycle,
      ver: ver ?? this.ver,
      ctime: ctime ?? this.ctime,
      mtime: mtime ?? this.mtime,
      ownerName: ownerName ?? this.ownerName,
      dirty: dirty ?? this.dirty,
      syncedAt: syncedAt ?? this.syncedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountKey.present) {
      map['account_key'] = Variable<String>(accountKey.value);
    }
    if (objectId.present) {
      map['object_id'] = Variable<String>(objectId.value);
    }
    if (notebookId.present) {
      map['notebook_id'] = Variable<String>(notebookId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (brief.present) {
      map['brief'] = Variable<String>(brief.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (hasContent.present) {
      map['has_content'] = Variable<bool>(hasContent.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (attachmentsJson.present) {
      map['attachments_json'] = Variable<String>(attachmentsJson.value);
    }
    if (encrypt.present) {
      map['encrypt'] = Variable<bool>(encrypt.value);
    }
    if (recycle.present) {
      map['recycle'] = Variable<bool>(recycle.value);
    }
    if (ver.present) {
      map['ver'] = Variable<String>(ver.value);
    }
    if (ctime.present) {
      map['ctime'] = Variable<int>(ctime.value);
    }
    if (mtime.present) {
      map['mtime'] = Variable<int>(mtime.value);
    }
    if (ownerName.present) {
      map['owner_name'] = Variable<String>(ownerName.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (syncedAt.present) {
      map['synced_at'] = Variable<int>(syncedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NoteCacheRowsCompanion(')
          ..write('accountKey: $accountKey, ')
          ..write('objectId: $objectId, ')
          ..write('notebookId: $notebookId, ')
          ..write('title: $title, ')
          ..write('brief: $brief, ')
          ..write('content: $content, ')
          ..write('hasContent: $hasContent, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('attachmentsJson: $attachmentsJson, ')
          ..write('encrypt: $encrypt, ')
          ..write('recycle: $recycle, ')
          ..write('ver: $ver, ')
          ..write('ctime: $ctime, ')
          ..write('mtime: $mtime, ')
          ..write('ownerName: $ownerName, ')
          ..write('dirty: $dirty, ')
          ..write('syncedAt: $syncedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $NotebookCacheRowsTable extends NotebookCacheRows
    with TableInfo<$NotebookCacheRowsTable, NotebookCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotebookCacheRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountKeyMeta = const VerificationMeta(
    'accountKey',
  );
  @override
  late final GeneratedColumn<String> accountKey = GeneratedColumn<String>(
    'account_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _objectIdMeta = const VerificationMeta(
    'objectId',
  );
  @override
  late final GeneratedColumn<String> objectId = GeneratedColumn<String>(
    'object_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _presetMeta = const VerificationMeta('preset');
  @override
  late final GeneratedColumn<bool> preset = GeneratedColumn<bool>(
    'preset',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("preset" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _archiveMeta = const VerificationMeta(
    'archive',
  );
  @override
  late final GeneratedColumn<bool> archive = GeneratedColumn<bool>(
    'archive',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("archive" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _verMeta = const VerificationMeta('ver');
  @override
  late final GeneratedColumn<String> ver = GeneratedColumn<String>(
    'ver',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _mtimeMeta = const VerificationMeta('mtime');
  @override
  late final GeneratedColumn<int> mtime = GeneratedColumn<int>(
    'mtime',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _syncedAtMeta = const VerificationMeta(
    'syncedAt',
  );
  @override
  late final GeneratedColumn<int> syncedAt = GeneratedColumn<int>(
    'synced_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountKey,
    objectId,
    title,
    preset,
    archive,
    ver,
    mtime,
    syncedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'notebook_cache_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<NotebookCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_key')) {
      context.handle(
        _accountKeyMeta,
        accountKey.isAcceptableOrUnknown(data['account_key']!, _accountKeyMeta),
      );
    }
    if (data.containsKey('object_id')) {
      context.handle(
        _objectIdMeta,
        objectId.isAcceptableOrUnknown(data['object_id']!, _objectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_objectIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('preset')) {
      context.handle(
        _presetMeta,
        preset.isAcceptableOrUnknown(data['preset']!, _presetMeta),
      );
    }
    if (data.containsKey('archive')) {
      context.handle(
        _archiveMeta,
        archive.isAcceptableOrUnknown(data['archive']!, _archiveMeta),
      );
    }
    if (data.containsKey('ver')) {
      context.handle(
        _verMeta,
        ver.isAcceptableOrUnknown(data['ver']!, _verMeta),
      );
    }
    if (data.containsKey('mtime')) {
      context.handle(
        _mtimeMeta,
        mtime.isAcceptableOrUnknown(data['mtime']!, _mtimeMeta),
      );
    }
    if (data.containsKey('synced_at')) {
      context.handle(
        _syncedAtMeta,
        syncedAt.isAcceptableOrUnknown(data['synced_at']!, _syncedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountKey, objectId};
  @override
  NotebookCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NotebookCacheRow(
      accountKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_key'],
      )!,
      objectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}object_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      preset: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}preset'],
      )!,
      archive: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}archive'],
      )!,
      ver: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ver'],
      )!,
      mtime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}mtime'],
      )!,
      syncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_at'],
      )!,
    );
  }

  @override
  $NotebookCacheRowsTable createAlias(String alias) {
    return $NotebookCacheRowsTable(attachedDatabase, alias);
  }
}

class NotebookCacheRow extends DataClass
    implements Insertable<NotebookCacheRow> {
  /// ★ N5（236 轮）：这条缓存属于**哪个 NAS 账号**（多 NAS 共用同一个库文件，
  /// 不隔离就会出现 A 的笔记在 B 登录时被 diff 当成「服务端删了」或被同 id 覆盖）。
  /// 默认空串 = 老库 / 未登录（兼容 v13 及以前）。
  final String accountKey;
  final String objectId;
  final String title;
  final bool preset;
  final bool archive;
  final String ver;
  final int mtime;
  final int syncedAt;
  const NotebookCacheRow({
    required this.accountKey,
    required this.objectId,
    required this.title,
    required this.preset,
    required this.archive,
    required this.ver,
    required this.mtime,
    required this.syncedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_key'] = Variable<String>(accountKey);
    map['object_id'] = Variable<String>(objectId);
    map['title'] = Variable<String>(title);
    map['preset'] = Variable<bool>(preset);
    map['archive'] = Variable<bool>(archive);
    map['ver'] = Variable<String>(ver);
    map['mtime'] = Variable<int>(mtime);
    map['synced_at'] = Variable<int>(syncedAt);
    return map;
  }

  NotebookCacheRowsCompanion toCompanion(bool nullToAbsent) {
    return NotebookCacheRowsCompanion(
      accountKey: Value(accountKey),
      objectId: Value(objectId),
      title: Value(title),
      preset: Value(preset),
      archive: Value(archive),
      ver: Value(ver),
      mtime: Value(mtime),
      syncedAt: Value(syncedAt),
    );
  }

  factory NotebookCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NotebookCacheRow(
      accountKey: serializer.fromJson<String>(json['accountKey']),
      objectId: serializer.fromJson<String>(json['objectId']),
      title: serializer.fromJson<String>(json['title']),
      preset: serializer.fromJson<bool>(json['preset']),
      archive: serializer.fromJson<bool>(json['archive']),
      ver: serializer.fromJson<String>(json['ver']),
      mtime: serializer.fromJson<int>(json['mtime']),
      syncedAt: serializer.fromJson<int>(json['syncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountKey': serializer.toJson<String>(accountKey),
      'objectId': serializer.toJson<String>(objectId),
      'title': serializer.toJson<String>(title),
      'preset': serializer.toJson<bool>(preset),
      'archive': serializer.toJson<bool>(archive),
      'ver': serializer.toJson<String>(ver),
      'mtime': serializer.toJson<int>(mtime),
      'syncedAt': serializer.toJson<int>(syncedAt),
    };
  }

  NotebookCacheRow copyWith({
    String? accountKey,
    String? objectId,
    String? title,
    bool? preset,
    bool? archive,
    String? ver,
    int? mtime,
    int? syncedAt,
  }) => NotebookCacheRow(
    accountKey: accountKey ?? this.accountKey,
    objectId: objectId ?? this.objectId,
    title: title ?? this.title,
    preset: preset ?? this.preset,
    archive: archive ?? this.archive,
    ver: ver ?? this.ver,
    mtime: mtime ?? this.mtime,
    syncedAt: syncedAt ?? this.syncedAt,
  );
  NotebookCacheRow copyWithCompanion(NotebookCacheRowsCompanion data) {
    return NotebookCacheRow(
      accountKey: data.accountKey.present
          ? data.accountKey.value
          : this.accountKey,
      objectId: data.objectId.present ? data.objectId.value : this.objectId,
      title: data.title.present ? data.title.value : this.title,
      preset: data.preset.present ? data.preset.value : this.preset,
      archive: data.archive.present ? data.archive.value : this.archive,
      ver: data.ver.present ? data.ver.value : this.ver,
      mtime: data.mtime.present ? data.mtime.value : this.mtime,
      syncedAt: data.syncedAt.present ? data.syncedAt.value : this.syncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NotebookCacheRow(')
          ..write('accountKey: $accountKey, ')
          ..write('objectId: $objectId, ')
          ..write('title: $title, ')
          ..write('preset: $preset, ')
          ..write('archive: $archive, ')
          ..write('ver: $ver, ')
          ..write('mtime: $mtime, ')
          ..write('syncedAt: $syncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountKey,
    objectId,
    title,
    preset,
    archive,
    ver,
    mtime,
    syncedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NotebookCacheRow &&
          other.accountKey == this.accountKey &&
          other.objectId == this.objectId &&
          other.title == this.title &&
          other.preset == this.preset &&
          other.archive == this.archive &&
          other.ver == this.ver &&
          other.mtime == this.mtime &&
          other.syncedAt == this.syncedAt);
}

class NotebookCacheRowsCompanion extends UpdateCompanion<NotebookCacheRow> {
  final Value<String> accountKey;
  final Value<String> objectId;
  final Value<String> title;
  final Value<bool> preset;
  final Value<bool> archive;
  final Value<String> ver;
  final Value<int> mtime;
  final Value<int> syncedAt;
  final Value<int> rowid;
  const NotebookCacheRowsCompanion({
    this.accountKey = const Value.absent(),
    this.objectId = const Value.absent(),
    this.title = const Value.absent(),
    this.preset = const Value.absent(),
    this.archive = const Value.absent(),
    this.ver = const Value.absent(),
    this.mtime = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotebookCacheRowsCompanion.insert({
    this.accountKey = const Value.absent(),
    required String objectId,
    this.title = const Value.absent(),
    this.preset = const Value.absent(),
    this.archive = const Value.absent(),
    this.ver = const Value.absent(),
    this.mtime = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : objectId = Value(objectId);
  static Insertable<NotebookCacheRow> custom({
    Expression<String>? accountKey,
    Expression<String>? objectId,
    Expression<String>? title,
    Expression<bool>? preset,
    Expression<bool>? archive,
    Expression<String>? ver,
    Expression<int>? mtime,
    Expression<int>? syncedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountKey != null) 'account_key': accountKey,
      if (objectId != null) 'object_id': objectId,
      if (title != null) 'title': title,
      if (preset != null) 'preset': preset,
      if (archive != null) 'archive': archive,
      if (ver != null) 'ver': ver,
      if (mtime != null) 'mtime': mtime,
      if (syncedAt != null) 'synced_at': syncedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotebookCacheRowsCompanion copyWith({
    Value<String>? accountKey,
    Value<String>? objectId,
    Value<String>? title,
    Value<bool>? preset,
    Value<bool>? archive,
    Value<String>? ver,
    Value<int>? mtime,
    Value<int>? syncedAt,
    Value<int>? rowid,
  }) {
    return NotebookCacheRowsCompanion(
      accountKey: accountKey ?? this.accountKey,
      objectId: objectId ?? this.objectId,
      title: title ?? this.title,
      preset: preset ?? this.preset,
      archive: archive ?? this.archive,
      ver: ver ?? this.ver,
      mtime: mtime ?? this.mtime,
      syncedAt: syncedAt ?? this.syncedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountKey.present) {
      map['account_key'] = Variable<String>(accountKey.value);
    }
    if (objectId.present) {
      map['object_id'] = Variable<String>(objectId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (preset.present) {
      map['preset'] = Variable<bool>(preset.value);
    }
    if (archive.present) {
      map['archive'] = Variable<bool>(archive.value);
    }
    if (ver.present) {
      map['ver'] = Variable<String>(ver.value);
    }
    if (mtime.present) {
      map['mtime'] = Variable<int>(mtime.value);
    }
    if (syncedAt.present) {
      map['synced_at'] = Variable<int>(syncedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotebookCacheRowsCompanion(')
          ..write('accountKey: $accountKey, ')
          ..write('objectId: $objectId, ')
          ..write('title: $title, ')
          ..write('preset: $preset, ')
          ..write('archive: $archive, ')
          ..write('ver: $ver, ')
          ..write('mtime: $mtime, ')
          ..write('syncedAt: $syncedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TodoCacheRowsTable extends TodoCacheRows
    with TableInfo<$TodoCacheRowsTable, TodoCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TodoCacheRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _accountKeyMeta = const VerificationMeta(
    'accountKey',
  );
  @override
  late final GeneratedColumn<String> accountKey = GeneratedColumn<String>(
    'account_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _objectIdMeta = const VerificationMeta(
    'objectId',
  );
  @override
  late final GeneratedColumn<String> objectId = GeneratedColumn<String>(
    'object_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _commentMeta = const VerificationMeta(
    'comment',
  );
  @override
  late final GeneratedColumn<String> comment = GeneratedColumn<String>(
    'comment',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _doneMeta = const VerificationMeta('done');
  @override
  late final GeneratedColumn<bool> done = GeneratedColumn<bool>(
    'done',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("done" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _starMeta = const VerificationMeta('star');
  @override
  late final GeneratedColumn<bool> star = GeneratedColumn<bool>(
    'star',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("star" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _priorityMeta = const VerificationMeta(
    'priority',
  );
  @override
  late final GeneratedColumn<int> priority = GeneratedColumn<int>(
    'priority',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _dueDateMeta = const VerificationMeta(
    'dueDate',
  );
  @override
  late final GeneratedColumn<int> dueDate = GeneratedColumn<int>(
    'due_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _reminderOffsetMeta = const VerificationMeta(
    'reminderOffset',
  );
  @override
  late final GeneratedColumn<int> reminderOffset = GeneratedColumn<int>(
    'reminder_offset',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _noteIdMeta = const VerificationMeta('noteId');
  @override
  late final GeneratedColumn<String> noteId = GeneratedColumn<String>(
    'note_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _syncedAtMeta = const VerificationMeta(
    'syncedAt',
  );
  @override
  late final GeneratedColumn<int> syncedAt = GeneratedColumn<int>(
    'synced_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    accountKey,
    objectId,
    title,
    comment,
    done,
    star,
    priority,
    dueDate,
    reminderOffset,
    noteId,
    parentId,
    dirty,
    syncedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'todo_cache_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<TodoCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('account_key')) {
      context.handle(
        _accountKeyMeta,
        accountKey.isAcceptableOrUnknown(data['account_key']!, _accountKeyMeta),
      );
    }
    if (data.containsKey('object_id')) {
      context.handle(
        _objectIdMeta,
        objectId.isAcceptableOrUnknown(data['object_id']!, _objectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_objectIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('comment')) {
      context.handle(
        _commentMeta,
        comment.isAcceptableOrUnknown(data['comment']!, _commentMeta),
      );
    }
    if (data.containsKey('done')) {
      context.handle(
        _doneMeta,
        done.isAcceptableOrUnknown(data['done']!, _doneMeta),
      );
    }
    if (data.containsKey('star')) {
      context.handle(
        _starMeta,
        star.isAcceptableOrUnknown(data['star']!, _starMeta),
      );
    }
    if (data.containsKey('priority')) {
      context.handle(
        _priorityMeta,
        priority.isAcceptableOrUnknown(data['priority']!, _priorityMeta),
      );
    }
    if (data.containsKey('due_date')) {
      context.handle(
        _dueDateMeta,
        dueDate.isAcceptableOrUnknown(data['due_date']!, _dueDateMeta),
      );
    }
    if (data.containsKey('reminder_offset')) {
      context.handle(
        _reminderOffsetMeta,
        reminderOffset.isAcceptableOrUnknown(
          data['reminder_offset']!,
          _reminderOffsetMeta,
        ),
      );
    }
    if (data.containsKey('note_id')) {
      context.handle(
        _noteIdMeta,
        noteId.isAcceptableOrUnknown(data['note_id']!, _noteIdMeta),
      );
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    if (data.containsKey('synced_at')) {
      context.handle(
        _syncedAtMeta,
        syncedAt.isAcceptableOrUnknown(data['synced_at']!, _syncedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {accountKey, objectId};
  @override
  TodoCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TodoCacheRow(
      accountKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_key'],
      )!,
      objectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}object_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      comment: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}comment'],
      )!,
      done: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}done'],
      )!,
      star: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}star'],
      )!,
      priority: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}priority'],
      )!,
      dueDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}due_date'],
      )!,
      reminderOffset: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reminder_offset'],
      )!,
      noteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note_id'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      )!,
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
      syncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_at'],
      )!,
    );
  }

  @override
  $TodoCacheRowsTable createAlias(String alias) {
    return $TodoCacheRowsTable(attachedDatabase, alias);
  }
}

class TodoCacheRow extends DataClass implements Insertable<TodoCacheRow> {
  /// ★ N5（236 轮）：这条缓存属于**哪个 NAS 账号**（多 NAS 共用同一个库文件，
  /// 不隔离就会出现 A 的笔记在 B 登录时被 diff 当成「服务端删了」或被同 id 覆盖）。
  /// 默认空串 = 老库 / 未登录（兼容 v13 及以前）。
  final String accountKey;
  final String objectId;
  final String title;
  final String comment;
  final bool done;
  final bool star;
  final int priority;
  final int dueDate;
  final int reminderOffset;
  final String noteId;
  final String parentId;
  final bool dirty;
  final int syncedAt;
  const TodoCacheRow({
    required this.accountKey,
    required this.objectId,
    required this.title,
    required this.comment,
    required this.done,
    required this.star,
    required this.priority,
    required this.dueDate,
    required this.reminderOffset,
    required this.noteId,
    required this.parentId,
    required this.dirty,
    required this.syncedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['account_key'] = Variable<String>(accountKey);
    map['object_id'] = Variable<String>(objectId);
    map['title'] = Variable<String>(title);
    map['comment'] = Variable<String>(comment);
    map['done'] = Variable<bool>(done);
    map['star'] = Variable<bool>(star);
    map['priority'] = Variable<int>(priority);
    map['due_date'] = Variable<int>(dueDate);
    map['reminder_offset'] = Variable<int>(reminderOffset);
    map['note_id'] = Variable<String>(noteId);
    map['parent_id'] = Variable<String>(parentId);
    map['dirty'] = Variable<bool>(dirty);
    map['synced_at'] = Variable<int>(syncedAt);
    return map;
  }

  TodoCacheRowsCompanion toCompanion(bool nullToAbsent) {
    return TodoCacheRowsCompanion(
      accountKey: Value(accountKey),
      objectId: Value(objectId),
      title: Value(title),
      comment: Value(comment),
      done: Value(done),
      star: Value(star),
      priority: Value(priority),
      dueDate: Value(dueDate),
      reminderOffset: Value(reminderOffset),
      noteId: Value(noteId),
      parentId: Value(parentId),
      dirty: Value(dirty),
      syncedAt: Value(syncedAt),
    );
  }

  factory TodoCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TodoCacheRow(
      accountKey: serializer.fromJson<String>(json['accountKey']),
      objectId: serializer.fromJson<String>(json['objectId']),
      title: serializer.fromJson<String>(json['title']),
      comment: serializer.fromJson<String>(json['comment']),
      done: serializer.fromJson<bool>(json['done']),
      star: serializer.fromJson<bool>(json['star']),
      priority: serializer.fromJson<int>(json['priority']),
      dueDate: serializer.fromJson<int>(json['dueDate']),
      reminderOffset: serializer.fromJson<int>(json['reminderOffset']),
      noteId: serializer.fromJson<String>(json['noteId']),
      parentId: serializer.fromJson<String>(json['parentId']),
      dirty: serializer.fromJson<bool>(json['dirty']),
      syncedAt: serializer.fromJson<int>(json['syncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'accountKey': serializer.toJson<String>(accountKey),
      'objectId': serializer.toJson<String>(objectId),
      'title': serializer.toJson<String>(title),
      'comment': serializer.toJson<String>(comment),
      'done': serializer.toJson<bool>(done),
      'star': serializer.toJson<bool>(star),
      'priority': serializer.toJson<int>(priority),
      'dueDate': serializer.toJson<int>(dueDate),
      'reminderOffset': serializer.toJson<int>(reminderOffset),
      'noteId': serializer.toJson<String>(noteId),
      'parentId': serializer.toJson<String>(parentId),
      'dirty': serializer.toJson<bool>(dirty),
      'syncedAt': serializer.toJson<int>(syncedAt),
    };
  }

  TodoCacheRow copyWith({
    String? accountKey,
    String? objectId,
    String? title,
    String? comment,
    bool? done,
    bool? star,
    int? priority,
    int? dueDate,
    int? reminderOffset,
    String? noteId,
    String? parentId,
    bool? dirty,
    int? syncedAt,
  }) => TodoCacheRow(
    accountKey: accountKey ?? this.accountKey,
    objectId: objectId ?? this.objectId,
    title: title ?? this.title,
    comment: comment ?? this.comment,
    done: done ?? this.done,
    star: star ?? this.star,
    priority: priority ?? this.priority,
    dueDate: dueDate ?? this.dueDate,
    reminderOffset: reminderOffset ?? this.reminderOffset,
    noteId: noteId ?? this.noteId,
    parentId: parentId ?? this.parentId,
    dirty: dirty ?? this.dirty,
    syncedAt: syncedAt ?? this.syncedAt,
  );
  TodoCacheRow copyWithCompanion(TodoCacheRowsCompanion data) {
    return TodoCacheRow(
      accountKey: data.accountKey.present
          ? data.accountKey.value
          : this.accountKey,
      objectId: data.objectId.present ? data.objectId.value : this.objectId,
      title: data.title.present ? data.title.value : this.title,
      comment: data.comment.present ? data.comment.value : this.comment,
      done: data.done.present ? data.done.value : this.done,
      star: data.star.present ? data.star.value : this.star,
      priority: data.priority.present ? data.priority.value : this.priority,
      dueDate: data.dueDate.present ? data.dueDate.value : this.dueDate,
      reminderOffset: data.reminderOffset.present
          ? data.reminderOffset.value
          : this.reminderOffset,
      noteId: data.noteId.present ? data.noteId.value : this.noteId,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
      syncedAt: data.syncedAt.present ? data.syncedAt.value : this.syncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TodoCacheRow(')
          ..write('accountKey: $accountKey, ')
          ..write('objectId: $objectId, ')
          ..write('title: $title, ')
          ..write('comment: $comment, ')
          ..write('done: $done, ')
          ..write('star: $star, ')
          ..write('priority: $priority, ')
          ..write('dueDate: $dueDate, ')
          ..write('reminderOffset: $reminderOffset, ')
          ..write('noteId: $noteId, ')
          ..write('parentId: $parentId, ')
          ..write('dirty: $dirty, ')
          ..write('syncedAt: $syncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    accountKey,
    objectId,
    title,
    comment,
    done,
    star,
    priority,
    dueDate,
    reminderOffset,
    noteId,
    parentId,
    dirty,
    syncedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TodoCacheRow &&
          other.accountKey == this.accountKey &&
          other.objectId == this.objectId &&
          other.title == this.title &&
          other.comment == this.comment &&
          other.done == this.done &&
          other.star == this.star &&
          other.priority == this.priority &&
          other.dueDate == this.dueDate &&
          other.reminderOffset == this.reminderOffset &&
          other.noteId == this.noteId &&
          other.parentId == this.parentId &&
          other.dirty == this.dirty &&
          other.syncedAt == this.syncedAt);
}

class TodoCacheRowsCompanion extends UpdateCompanion<TodoCacheRow> {
  final Value<String> accountKey;
  final Value<String> objectId;
  final Value<String> title;
  final Value<String> comment;
  final Value<bool> done;
  final Value<bool> star;
  final Value<int> priority;
  final Value<int> dueDate;
  final Value<int> reminderOffset;
  final Value<String> noteId;
  final Value<String> parentId;
  final Value<bool> dirty;
  final Value<int> syncedAt;
  final Value<int> rowid;
  const TodoCacheRowsCompanion({
    this.accountKey = const Value.absent(),
    this.objectId = const Value.absent(),
    this.title = const Value.absent(),
    this.comment = const Value.absent(),
    this.done = const Value.absent(),
    this.star = const Value.absent(),
    this.priority = const Value.absent(),
    this.dueDate = const Value.absent(),
    this.reminderOffset = const Value.absent(),
    this.noteId = const Value.absent(),
    this.parentId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TodoCacheRowsCompanion.insert({
    this.accountKey = const Value.absent(),
    required String objectId,
    this.title = const Value.absent(),
    this.comment = const Value.absent(),
    this.done = const Value.absent(),
    this.star = const Value.absent(),
    this.priority = const Value.absent(),
    this.dueDate = const Value.absent(),
    this.reminderOffset = const Value.absent(),
    this.noteId = const Value.absent(),
    this.parentId = const Value.absent(),
    this.dirty = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : objectId = Value(objectId);
  static Insertable<TodoCacheRow> custom({
    Expression<String>? accountKey,
    Expression<String>? objectId,
    Expression<String>? title,
    Expression<String>? comment,
    Expression<bool>? done,
    Expression<bool>? star,
    Expression<int>? priority,
    Expression<int>? dueDate,
    Expression<int>? reminderOffset,
    Expression<String>? noteId,
    Expression<String>? parentId,
    Expression<bool>? dirty,
    Expression<int>? syncedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (accountKey != null) 'account_key': accountKey,
      if (objectId != null) 'object_id': objectId,
      if (title != null) 'title': title,
      if (comment != null) 'comment': comment,
      if (done != null) 'done': done,
      if (star != null) 'star': star,
      if (priority != null) 'priority': priority,
      if (dueDate != null) 'due_date': dueDate,
      if (reminderOffset != null) 'reminder_offset': reminderOffset,
      if (noteId != null) 'note_id': noteId,
      if (parentId != null) 'parent_id': parentId,
      if (dirty != null) 'dirty': dirty,
      if (syncedAt != null) 'synced_at': syncedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TodoCacheRowsCompanion copyWith({
    Value<String>? accountKey,
    Value<String>? objectId,
    Value<String>? title,
    Value<String>? comment,
    Value<bool>? done,
    Value<bool>? star,
    Value<int>? priority,
    Value<int>? dueDate,
    Value<int>? reminderOffset,
    Value<String>? noteId,
    Value<String>? parentId,
    Value<bool>? dirty,
    Value<int>? syncedAt,
    Value<int>? rowid,
  }) {
    return TodoCacheRowsCompanion(
      accountKey: accountKey ?? this.accountKey,
      objectId: objectId ?? this.objectId,
      title: title ?? this.title,
      comment: comment ?? this.comment,
      done: done ?? this.done,
      star: star ?? this.star,
      priority: priority ?? this.priority,
      dueDate: dueDate ?? this.dueDate,
      reminderOffset: reminderOffset ?? this.reminderOffset,
      noteId: noteId ?? this.noteId,
      parentId: parentId ?? this.parentId,
      dirty: dirty ?? this.dirty,
      syncedAt: syncedAt ?? this.syncedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (accountKey.present) {
      map['account_key'] = Variable<String>(accountKey.value);
    }
    if (objectId.present) {
      map['object_id'] = Variable<String>(objectId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (comment.present) {
      map['comment'] = Variable<String>(comment.value);
    }
    if (done.present) {
      map['done'] = Variable<bool>(done.value);
    }
    if (star.present) {
      map['star'] = Variable<bool>(star.value);
    }
    if (priority.present) {
      map['priority'] = Variable<int>(priority.value);
    }
    if (dueDate.present) {
      map['due_date'] = Variable<int>(dueDate.value);
    }
    if (reminderOffset.present) {
      map['reminder_offset'] = Variable<int>(reminderOffset.value);
    }
    if (noteId.present) {
      map['note_id'] = Variable<String>(noteId.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (syncedAt.present) {
      map['synced_at'] = Variable<int>(syncedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TodoCacheRowsCompanion(')
          ..write('accountKey: $accountKey, ')
          ..write('objectId: $objectId, ')
          ..write('title: $title, ')
          ..write('comment: $comment, ')
          ..write('done: $done, ')
          ..write('star: $star, ')
          ..write('priority: $priority, ')
          ..write('dueDate: $dueDate, ')
          ..write('reminderOffset: $reminderOffset, ')
          ..write('noteId: $noteId, ')
          ..write('parentId: $parentId, ')
          ..write('dirty: $dirty, ')
          ..write('syncedAt: $syncedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $NotePendingRowsTable extends NotePendingRows
    with TableInfo<$NotePendingRowsTable, NotePendingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotePendingRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _accountKeyMeta = const VerificationMeta(
    'accountKey',
  );
  @override
  late final GeneratedColumn<String> accountKey = GeneratedColumn<String>(
    'account_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _objectIdMeta = const VerificationMeta(
    'objectId',
  );
  @override
  late final GeneratedColumn<String> objectId = GeneratedColumn<String>(
    'object_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    accountKey,
    kind,
    objectId,
    payloadJson,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'note_pending_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<NotePendingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('account_key')) {
      context.handle(
        _accountKeyMeta,
        accountKey.isAcceptableOrUnknown(data['account_key']!, _accountKeyMeta),
      );
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('object_id')) {
      context.handle(
        _objectIdMeta,
        objectId.isAcceptableOrUnknown(data['object_id']!, _objectIdMeta),
      );
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  NotePendingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NotePendingRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      accountKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_key'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      objectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}object_id'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $NotePendingRowsTable createAlias(String alias) {
    return $NotePendingRowsTable(attachedDatabase, alias);
  }
}

class NotePendingRow extends DataClass implements Insertable<NotePendingRow> {
  final int id;

  /// ★ N5：这条待推送动作属于**哪个 NAS 账号**（推错账号 = 把 A 的改动写到 B）
  final String accountKey;

  /// `create` / `set` / `delete` / `todo_set` / `todo_create` / `todo_delete`
  final String kind;
  final String objectId;

  /// 请求参数（JSON）
  final String payloadJson;
  final int createdAt;
  const NotePendingRow({
    required this.id,
    required this.accountKey,
    required this.kind,
    required this.objectId,
    required this.payloadJson,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['account_key'] = Variable<String>(accountKey);
    map['kind'] = Variable<String>(kind);
    map['object_id'] = Variable<String>(objectId);
    map['payload_json'] = Variable<String>(payloadJson);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  NotePendingRowsCompanion toCompanion(bool nullToAbsent) {
    return NotePendingRowsCompanion(
      id: Value(id),
      accountKey: Value(accountKey),
      kind: Value(kind),
      objectId: Value(objectId),
      payloadJson: Value(payloadJson),
      createdAt: Value(createdAt),
    );
  }

  factory NotePendingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NotePendingRow(
      id: serializer.fromJson<int>(json['id']),
      accountKey: serializer.fromJson<String>(json['accountKey']),
      kind: serializer.fromJson<String>(json['kind']),
      objectId: serializer.fromJson<String>(json['objectId']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'accountKey': serializer.toJson<String>(accountKey),
      'kind': serializer.toJson<String>(kind),
      'objectId': serializer.toJson<String>(objectId),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  NotePendingRow copyWith({
    int? id,
    String? accountKey,
    String? kind,
    String? objectId,
    String? payloadJson,
    int? createdAt,
  }) => NotePendingRow(
    id: id ?? this.id,
    accountKey: accountKey ?? this.accountKey,
    kind: kind ?? this.kind,
    objectId: objectId ?? this.objectId,
    payloadJson: payloadJson ?? this.payloadJson,
    createdAt: createdAt ?? this.createdAt,
  );
  NotePendingRow copyWithCompanion(NotePendingRowsCompanion data) {
    return NotePendingRow(
      id: data.id.present ? data.id.value : this.id,
      accountKey: data.accountKey.present
          ? data.accountKey.value
          : this.accountKey,
      kind: data.kind.present ? data.kind.value : this.kind,
      objectId: data.objectId.present ? data.objectId.value : this.objectId,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NotePendingRow(')
          ..write('id: $id, ')
          ..write('accountKey: $accountKey, ')
          ..write('kind: $kind, ')
          ..write('objectId: $objectId, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, accountKey, kind, objectId, payloadJson, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NotePendingRow &&
          other.id == this.id &&
          other.accountKey == this.accountKey &&
          other.kind == this.kind &&
          other.objectId == this.objectId &&
          other.payloadJson == this.payloadJson &&
          other.createdAt == this.createdAt);
}

class NotePendingRowsCompanion extends UpdateCompanion<NotePendingRow> {
  final Value<int> id;
  final Value<String> accountKey;
  final Value<String> kind;
  final Value<String> objectId;
  final Value<String> payloadJson;
  final Value<int> createdAt;
  const NotePendingRowsCompanion({
    this.id = const Value.absent(),
    this.accountKey = const Value.absent(),
    this.kind = const Value.absent(),
    this.objectId = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  NotePendingRowsCompanion.insert({
    this.id = const Value.absent(),
    this.accountKey = const Value.absent(),
    required String kind,
    this.objectId = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.createdAt = const Value.absent(),
  }) : kind = Value(kind);
  static Insertable<NotePendingRow> custom({
    Expression<int>? id,
    Expression<String>? accountKey,
    Expression<String>? kind,
    Expression<String>? objectId,
    Expression<String>? payloadJson,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (accountKey != null) 'account_key': accountKey,
      if (kind != null) 'kind': kind,
      if (objectId != null) 'object_id': objectId,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  NotePendingRowsCompanion copyWith({
    Value<int>? id,
    Value<String>? accountKey,
    Value<String>? kind,
    Value<String>? objectId,
    Value<String>? payloadJson,
    Value<int>? createdAt,
  }) {
    return NotePendingRowsCompanion(
      id: id ?? this.id,
      accountKey: accountKey ?? this.accountKey,
      kind: kind ?? this.kind,
      objectId: objectId ?? this.objectId,
      payloadJson: payloadJson ?? this.payloadJson,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (accountKey.present) {
      map['account_key'] = Variable<String>(accountKey.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (objectId.present) {
      map['object_id'] = Variable<String>(objectId.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotePendingRowsCompanion(')
          ..write('id: $id, ')
          ..write('accountKey: $accountKey, ')
          ..write('kind: $kind, ')
          ..write('objectId: $objectId, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $BookProgressRowsTable extends BookProgressRows
    with TableInfo<$BookProgressRowsTable, BookProgressRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookProgressRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookKeyMeta = const VerificationMeta(
    'bookKey',
  );
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
    'book_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _formatMeta = const VerificationMeta('format');
  @override
  late final GeneratedColumn<String> format = GeneratedColumn<String>(
    'format',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _chapterMeta = const VerificationMeta(
    'chapter',
  );
  @override
  late final GeneratedColumn<int> chapter = GeneratedColumn<int>(
    'chapter',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _scrollMeta = const VerificationMeta('scroll');
  @override
  late final GeneratedColumn<double> scroll = GeneratedColumn<double>(
    'scroll',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _chapterCountMeta = const VerificationMeta(
    'chapterCount',
  );
  @override
  late final GeneratedColumn<int> chapterCount = GeneratedColumn<int>(
    'chapter_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sourceUrlMeta = const VerificationMeta(
    'sourceUrl',
  );
  @override
  late final GeneratedColumn<String> sourceUrl = GeneratedColumn<String>(
    'source_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    bookKey,
    title,
    format,
    chapter,
    scroll,
    chapterCount,
    updatedAt,
    sourceUrl,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'book_progress_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<BookProgressRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_key')) {
      context.handle(
        _bookKeyMeta,
        bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_bookKeyMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('format')) {
      context.handle(
        _formatMeta,
        format.isAcceptableOrUnknown(data['format']!, _formatMeta),
      );
    }
    if (data.containsKey('chapter')) {
      context.handle(
        _chapterMeta,
        chapter.isAcceptableOrUnknown(data['chapter']!, _chapterMeta),
      );
    }
    if (data.containsKey('scroll')) {
      context.handle(
        _scrollMeta,
        scroll.isAcceptableOrUnknown(data['scroll']!, _scrollMeta),
      );
    }
    if (data.containsKey('chapter_count')) {
      context.handle(
        _chapterCountMeta,
        chapterCount.isAcceptableOrUnknown(
          data['chapter_count']!,
          _chapterCountMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('source_url')) {
      context.handle(
        _sourceUrlMeta,
        sourceUrl.isAcceptableOrUnknown(data['source_url']!, _sourceUrlMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookKey};
  @override
  BookProgressRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookProgressRow(
      bookKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_key'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      format: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}format'],
      )!,
      chapter: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}chapter'],
      )!,
      scroll: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}scroll'],
      )!,
      chapterCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}chapter_count'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      sourceUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_url'],
      )!,
    );
  }

  @override
  $BookProgressRowsTable createAlias(String alias) {
    return $BookProgressRowsTable(attachedDatabase, alias);
  }
}

class BookProgressRow extends DataClass implements Insertable<BookProgressRow> {
  final String bookKey;

  /// 书名（只为了在"继续阅读"里显示；不参与逻辑）
  final String title;

  /// 文件扩展名 / 来源，用来恢复时挑对渲染器
  final String format;
  final int chapter;
  final double scroll;
  final int chapterCount;

  /// 最后读的时间（毫秒）
  final int updatedAt;

  /// "这本书怎么再打开"的定位串（v11）。
  ///
  /// FileStation 来源的书不用它（`bookKey` 里的路径就够了）；Drive 来源的书
  /// 需要它 —— 进阅读器时由 `FileBookStage.bytesUrl` 把现成的鉴权直链记下来，
  /// 工作台「继续阅读」才能不查目录、直接恢复到上次那一章。
  final String sourceUrl;
  const BookProgressRow({
    required this.bookKey,
    required this.title,
    required this.format,
    required this.chapter,
    required this.scroll,
    required this.chapterCount,
    required this.updatedAt,
    required this.sourceUrl,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_key'] = Variable<String>(bookKey);
    map['title'] = Variable<String>(title);
    map['format'] = Variable<String>(format);
    map['chapter'] = Variable<int>(chapter);
    map['scroll'] = Variable<double>(scroll);
    map['chapter_count'] = Variable<int>(chapterCount);
    map['updated_at'] = Variable<int>(updatedAt);
    map['source_url'] = Variable<String>(sourceUrl);
    return map;
  }

  BookProgressRowsCompanion toCompanion(bool nullToAbsent) {
    return BookProgressRowsCompanion(
      bookKey: Value(bookKey),
      title: Value(title),
      format: Value(format),
      chapter: Value(chapter),
      scroll: Value(scroll),
      chapterCount: Value(chapterCount),
      updatedAt: Value(updatedAt),
      sourceUrl: Value(sourceUrl),
    );
  }

  factory BookProgressRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookProgressRow(
      bookKey: serializer.fromJson<String>(json['bookKey']),
      title: serializer.fromJson<String>(json['title']),
      format: serializer.fromJson<String>(json['format']),
      chapter: serializer.fromJson<int>(json['chapter']),
      scroll: serializer.fromJson<double>(json['scroll']),
      chapterCount: serializer.fromJson<int>(json['chapterCount']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      sourceUrl: serializer.fromJson<String>(json['sourceUrl']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookKey': serializer.toJson<String>(bookKey),
      'title': serializer.toJson<String>(title),
      'format': serializer.toJson<String>(format),
      'chapter': serializer.toJson<int>(chapter),
      'scroll': serializer.toJson<double>(scroll),
      'chapterCount': serializer.toJson<int>(chapterCount),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'sourceUrl': serializer.toJson<String>(sourceUrl),
    };
  }

  BookProgressRow copyWith({
    String? bookKey,
    String? title,
    String? format,
    int? chapter,
    double? scroll,
    int? chapterCount,
    int? updatedAt,
    String? sourceUrl,
  }) => BookProgressRow(
    bookKey: bookKey ?? this.bookKey,
    title: title ?? this.title,
    format: format ?? this.format,
    chapter: chapter ?? this.chapter,
    scroll: scroll ?? this.scroll,
    chapterCount: chapterCount ?? this.chapterCount,
    updatedAt: updatedAt ?? this.updatedAt,
    sourceUrl: sourceUrl ?? this.sourceUrl,
  );
  BookProgressRow copyWithCompanion(BookProgressRowsCompanion data) {
    return BookProgressRow(
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
      title: data.title.present ? data.title.value : this.title,
      format: data.format.present ? data.format.value : this.format,
      chapter: data.chapter.present ? data.chapter.value : this.chapter,
      scroll: data.scroll.present ? data.scroll.value : this.scroll,
      chapterCount: data.chapterCount.present
          ? data.chapterCount.value
          : this.chapterCount,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      sourceUrl: data.sourceUrl.present ? data.sourceUrl.value : this.sourceUrl,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookProgressRow(')
          ..write('bookKey: $bookKey, ')
          ..write('title: $title, ')
          ..write('format: $format, ')
          ..write('chapter: $chapter, ')
          ..write('scroll: $scroll, ')
          ..write('chapterCount: $chapterCount, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('sourceUrl: $sourceUrl')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    bookKey,
    title,
    format,
    chapter,
    scroll,
    chapterCount,
    updatedAt,
    sourceUrl,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookProgressRow &&
          other.bookKey == this.bookKey &&
          other.title == this.title &&
          other.format == this.format &&
          other.chapter == this.chapter &&
          other.scroll == this.scroll &&
          other.chapterCount == this.chapterCount &&
          other.updatedAt == this.updatedAt &&
          other.sourceUrl == this.sourceUrl);
}

class BookProgressRowsCompanion extends UpdateCompanion<BookProgressRow> {
  final Value<String> bookKey;
  final Value<String> title;
  final Value<String> format;
  final Value<int> chapter;
  final Value<double> scroll;
  final Value<int> chapterCount;
  final Value<int> updatedAt;
  final Value<String> sourceUrl;
  final Value<int> rowid;
  const BookProgressRowsCompanion({
    this.bookKey = const Value.absent(),
    this.title = const Value.absent(),
    this.format = const Value.absent(),
    this.chapter = const Value.absent(),
    this.scroll = const Value.absent(),
    this.chapterCount = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.sourceUrl = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BookProgressRowsCompanion.insert({
    required String bookKey,
    this.title = const Value.absent(),
    this.format = const Value.absent(),
    this.chapter = const Value.absent(),
    this.scroll = const Value.absent(),
    this.chapterCount = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.sourceUrl = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : bookKey = Value(bookKey);
  static Insertable<BookProgressRow> custom({
    Expression<String>? bookKey,
    Expression<String>? title,
    Expression<String>? format,
    Expression<int>? chapter,
    Expression<double>? scroll,
    Expression<int>? chapterCount,
    Expression<int>? updatedAt,
    Expression<String>? sourceUrl,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookKey != null) 'book_key': bookKey,
      if (title != null) 'title': title,
      if (format != null) 'format': format,
      if (chapter != null) 'chapter': chapter,
      if (scroll != null) 'scroll': scroll,
      if (chapterCount != null) 'chapter_count': chapterCount,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (sourceUrl != null) 'source_url': sourceUrl,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BookProgressRowsCompanion copyWith({
    Value<String>? bookKey,
    Value<String>? title,
    Value<String>? format,
    Value<int>? chapter,
    Value<double>? scroll,
    Value<int>? chapterCount,
    Value<int>? updatedAt,
    Value<String>? sourceUrl,
    Value<int>? rowid,
  }) {
    return BookProgressRowsCompanion(
      bookKey: bookKey ?? this.bookKey,
      title: title ?? this.title,
      format: format ?? this.format,
      chapter: chapter ?? this.chapter,
      scroll: scroll ?? this.scroll,
      chapterCount: chapterCount ?? this.chapterCount,
      updatedAt: updatedAt ?? this.updatedAt,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (chapter.present) {
      map['chapter'] = Variable<int>(chapter.value);
    }
    if (scroll.present) {
      map['scroll'] = Variable<double>(scroll.value);
    }
    if (chapterCount.present) {
      map['chapter_count'] = Variable<int>(chapterCount.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (sourceUrl.present) {
      map['source_url'] = Variable<String>(sourceUrl.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BookProgressRowsCompanion(')
          ..write('bookKey: $bookKey, ')
          ..write('title: $title, ')
          ..write('format: $format, ')
          ..write('chapter: $chapter, ')
          ..write('scroll: $scroll, ')
          ..write('chapterCount: $chapterCount, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('sourceUrl: $sourceUrl, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BookMarkRowsTable extends BookMarkRows
    with TableInfo<$BookMarkRowsTable, BookMarkRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookMarkRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _bookKeyMeta = const VerificationMeta(
    'bookKey',
  );
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
    'book_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chapterMeta = const VerificationMeta(
    'chapter',
  );
  @override
  late final GeneratedColumn<int> chapter = GeneratedColumn<int>(
    'chapter',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _scrollMeta = const VerificationMeta('scroll');
  @override
  late final GeneratedColumn<double> scroll = GeneratedColumn<double>(
    'scroll',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _excerptMeta = const VerificationMeta(
    'excerpt',
  );
  @override
  late final GeneratedColumn<String> excerpt = GeneratedColumn<String>(
    'excerpt',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    bookKey,
    chapter,
    scroll,
    excerpt,
    note,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'book_mark_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<BookMarkRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('book_key')) {
      context.handle(
        _bookKeyMeta,
        bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_bookKeyMeta);
    }
    if (data.containsKey('chapter')) {
      context.handle(
        _chapterMeta,
        chapter.isAcceptableOrUnknown(data['chapter']!, _chapterMeta),
      );
    }
    if (data.containsKey('scroll')) {
      context.handle(
        _scrollMeta,
        scroll.isAcceptableOrUnknown(data['scroll']!, _scrollMeta),
      );
    }
    if (data.containsKey('excerpt')) {
      context.handle(
        _excerptMeta,
        excerpt.isAcceptableOrUnknown(data['excerpt']!, _excerptMeta),
      );
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  BookMarkRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookMarkRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      bookKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_key'],
      )!,
      chapter: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}chapter'],
      )!,
      scroll: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}scroll'],
      )!,
      excerpt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}excerpt'],
      )!,
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $BookMarkRowsTable createAlias(String alias) {
    return $BookMarkRowsTable(attachedDatabase, alias);
  }
}

class BookMarkRow extends DataClass implements Insertable<BookMarkRow> {
  final int id;
  final String bookKey;
  final int chapter;

  /// 章内滚动百分比（0..1）
  final double scroll;

  /// 摘录的原文（书签本身也存一段上下文，列表里能认出来）
  final String excerpt;

  /// 用户写的批注（空 = 纯书签）
  final String note;
  final int createdAt;
  const BookMarkRow({
    required this.id,
    required this.bookKey,
    required this.chapter,
    required this.scroll,
    required this.excerpt,
    required this.note,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['book_key'] = Variable<String>(bookKey);
    map['chapter'] = Variable<int>(chapter);
    map['scroll'] = Variable<double>(scroll);
    map['excerpt'] = Variable<String>(excerpt);
    map['note'] = Variable<String>(note);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  BookMarkRowsCompanion toCompanion(bool nullToAbsent) {
    return BookMarkRowsCompanion(
      id: Value(id),
      bookKey: Value(bookKey),
      chapter: Value(chapter),
      scroll: Value(scroll),
      excerpt: Value(excerpt),
      note: Value(note),
      createdAt: Value(createdAt),
    );
  }

  factory BookMarkRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookMarkRow(
      id: serializer.fromJson<int>(json['id']),
      bookKey: serializer.fromJson<String>(json['bookKey']),
      chapter: serializer.fromJson<int>(json['chapter']),
      scroll: serializer.fromJson<double>(json['scroll']),
      excerpt: serializer.fromJson<String>(json['excerpt']),
      note: serializer.fromJson<String>(json['note']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'bookKey': serializer.toJson<String>(bookKey),
      'chapter': serializer.toJson<int>(chapter),
      'scroll': serializer.toJson<double>(scroll),
      'excerpt': serializer.toJson<String>(excerpt),
      'note': serializer.toJson<String>(note),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  BookMarkRow copyWith({
    int? id,
    String? bookKey,
    int? chapter,
    double? scroll,
    String? excerpt,
    String? note,
    int? createdAt,
  }) => BookMarkRow(
    id: id ?? this.id,
    bookKey: bookKey ?? this.bookKey,
    chapter: chapter ?? this.chapter,
    scroll: scroll ?? this.scroll,
    excerpt: excerpt ?? this.excerpt,
    note: note ?? this.note,
    createdAt: createdAt ?? this.createdAt,
  );
  BookMarkRow copyWithCompanion(BookMarkRowsCompanion data) {
    return BookMarkRow(
      id: data.id.present ? data.id.value : this.id,
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
      chapter: data.chapter.present ? data.chapter.value : this.chapter,
      scroll: data.scroll.present ? data.scroll.value : this.scroll,
      excerpt: data.excerpt.present ? data.excerpt.value : this.excerpt,
      note: data.note.present ? data.note.value : this.note,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookMarkRow(')
          ..write('id: $id, ')
          ..write('bookKey: $bookKey, ')
          ..write('chapter: $chapter, ')
          ..write('scroll: $scroll, ')
          ..write('excerpt: $excerpt, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, bookKey, chapter, scroll, excerpt, note, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookMarkRow &&
          other.id == this.id &&
          other.bookKey == this.bookKey &&
          other.chapter == this.chapter &&
          other.scroll == this.scroll &&
          other.excerpt == this.excerpt &&
          other.note == this.note &&
          other.createdAt == this.createdAt);
}

class BookMarkRowsCompanion extends UpdateCompanion<BookMarkRow> {
  final Value<int> id;
  final Value<String> bookKey;
  final Value<int> chapter;
  final Value<double> scroll;
  final Value<String> excerpt;
  final Value<String> note;
  final Value<int> createdAt;
  const BookMarkRowsCompanion({
    this.id = const Value.absent(),
    this.bookKey = const Value.absent(),
    this.chapter = const Value.absent(),
    this.scroll = const Value.absent(),
    this.excerpt = const Value.absent(),
    this.note = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  BookMarkRowsCompanion.insert({
    this.id = const Value.absent(),
    required String bookKey,
    this.chapter = const Value.absent(),
    this.scroll = const Value.absent(),
    this.excerpt = const Value.absent(),
    this.note = const Value.absent(),
    this.createdAt = const Value.absent(),
  }) : bookKey = Value(bookKey);
  static Insertable<BookMarkRow> custom({
    Expression<int>? id,
    Expression<String>? bookKey,
    Expression<int>? chapter,
    Expression<double>? scroll,
    Expression<String>? excerpt,
    Expression<String>? note,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bookKey != null) 'book_key': bookKey,
      if (chapter != null) 'chapter': chapter,
      if (scroll != null) 'scroll': scroll,
      if (excerpt != null) 'excerpt': excerpt,
      if (note != null) 'note': note,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  BookMarkRowsCompanion copyWith({
    Value<int>? id,
    Value<String>? bookKey,
    Value<int>? chapter,
    Value<double>? scroll,
    Value<String>? excerpt,
    Value<String>? note,
    Value<int>? createdAt,
  }) {
    return BookMarkRowsCompanion(
      id: id ?? this.id,
      bookKey: bookKey ?? this.bookKey,
      chapter: chapter ?? this.chapter,
      scroll: scroll ?? this.scroll,
      excerpt: excerpt ?? this.excerpt,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
    }
    if (chapter.present) {
      map['chapter'] = Variable<int>(chapter.value);
    }
    if (scroll.present) {
      map['scroll'] = Variable<double>(scroll.value);
    }
    if (excerpt.present) {
      map['excerpt'] = Variable<String>(excerpt.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BookMarkRowsCompanion(')
          ..write('id: $id, ')
          ..write('bookKey: $bookKey, ')
          ..write('chapter: $chapter, ')
          ..write('scroll: $scroll, ')
          ..write('excerpt: $excerpt, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $PhotoBackupTargetRowsTable extends PhotoBackupTargetRows
    with TableInfo<$PhotoBackupTargetRowsTable, PhotoBackupTargetRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PhotoBackupTargetRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _destinationMeta = const VerificationMeta(
    'destination',
  );
  @override
  late final GeneratedColumn<String> destination = GeneratedColumn<String>(
    'destination',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _doneKeysMeta = const VerificationMeta(
    'doneKeys',
  );
  @override
  late final GeneratedColumn<String> doneKeys = GeneratedColumn<String>(
    'done_keys',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _lastFinishedAtMeta = const VerificationMeta(
    'lastFinishedAt',
  );
  @override
  late final GeneratedColumn<int> lastFinishedAt = GeneratedColumn<int>(
    'last_finished_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _targetRefMeta = const VerificationMeta(
    'targetRef',
  );
  @override
  late final GeneratedColumn<String> targetRef = GeneratedColumn<String>(
    'target_ref',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _targetNameMeta = const VerificationMeta(
    'targetName',
  );
  @override
  late final GeneratedColumn<String> targetName = GeneratedColumn<String>(
    'target_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    destination,
    doneKeys,
    lastFinishedAt,
    targetRef,
    targetName,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'photo_backup_target_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<PhotoBackupTargetRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('destination')) {
      context.handle(
        _destinationMeta,
        destination.isAcceptableOrUnknown(
          data['destination']!,
          _destinationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_destinationMeta);
    }
    if (data.containsKey('done_keys')) {
      context.handle(
        _doneKeysMeta,
        doneKeys.isAcceptableOrUnknown(data['done_keys']!, _doneKeysMeta),
      );
    }
    if (data.containsKey('last_finished_at')) {
      context.handle(
        _lastFinishedAtMeta,
        lastFinishedAt.isAcceptableOrUnknown(
          data['last_finished_at']!,
          _lastFinishedAtMeta,
        ),
      );
    }
    if (data.containsKey('target_ref')) {
      context.handle(
        _targetRefMeta,
        targetRef.isAcceptableOrUnknown(data['target_ref']!, _targetRefMeta),
      );
    }
    if (data.containsKey('target_name')) {
      context.handle(
        _targetNameMeta,
        targetName.isAcceptableOrUnknown(data['target_name']!, _targetNameMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {destination};
  @override
  PhotoBackupTargetRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PhotoBackupTargetRow(
      destination: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}destination'],
      )!,
      doneKeys: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}done_keys'],
      )!,
      lastFinishedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_finished_at'],
      )!,
      targetRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_ref'],
      )!,
      targetName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_name'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $PhotoBackupTargetRowsTable createAlias(String alias) {
    return $PhotoBackupTargetRowsTable(attachedDatabase, alias);
  }
}

class PhotoBackupTargetRow extends DataClass
    implements Insertable<PhotoBackupTargetRow> {
  /// `drive` / `synology_photos`
  final String destination;

  /// 已成功备份的 `DeviceMediaAsset.stableKey` / 抽样 MD5，JSON 数组文本
  final String doneKeys;

  /// 上次跑完的时间（毫秒；0 = 这个落点从没跑完过）
  final int lastFinishedAt;

  /// 目标定位串：Photos = `Browse.Folder` 的真实 id；Drive = 目录路径
  final String targetRef;

  /// 给人看的目标名（相册名 / 目录名）
  final String targetName;

  /// 这一行最后改动时间（毫秒）
  final int updatedAt;
  const PhotoBackupTargetRow({
    required this.destination,
    required this.doneKeys,
    required this.lastFinishedAt,
    required this.targetRef,
    required this.targetName,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['destination'] = Variable<String>(destination);
    map['done_keys'] = Variable<String>(doneKeys);
    map['last_finished_at'] = Variable<int>(lastFinishedAt);
    map['target_ref'] = Variable<String>(targetRef);
    map['target_name'] = Variable<String>(targetName);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  PhotoBackupTargetRowsCompanion toCompanion(bool nullToAbsent) {
    return PhotoBackupTargetRowsCompanion(
      destination: Value(destination),
      doneKeys: Value(doneKeys),
      lastFinishedAt: Value(lastFinishedAt),
      targetRef: Value(targetRef),
      targetName: Value(targetName),
      updatedAt: Value(updatedAt),
    );
  }

  factory PhotoBackupTargetRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PhotoBackupTargetRow(
      destination: serializer.fromJson<String>(json['destination']),
      doneKeys: serializer.fromJson<String>(json['doneKeys']),
      lastFinishedAt: serializer.fromJson<int>(json['lastFinishedAt']),
      targetRef: serializer.fromJson<String>(json['targetRef']),
      targetName: serializer.fromJson<String>(json['targetName']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'destination': serializer.toJson<String>(destination),
      'doneKeys': serializer.toJson<String>(doneKeys),
      'lastFinishedAt': serializer.toJson<int>(lastFinishedAt),
      'targetRef': serializer.toJson<String>(targetRef),
      'targetName': serializer.toJson<String>(targetName),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  PhotoBackupTargetRow copyWith({
    String? destination,
    String? doneKeys,
    int? lastFinishedAt,
    String? targetRef,
    String? targetName,
    int? updatedAt,
  }) => PhotoBackupTargetRow(
    destination: destination ?? this.destination,
    doneKeys: doneKeys ?? this.doneKeys,
    lastFinishedAt: lastFinishedAt ?? this.lastFinishedAt,
    targetRef: targetRef ?? this.targetRef,
    targetName: targetName ?? this.targetName,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  PhotoBackupTargetRow copyWithCompanion(PhotoBackupTargetRowsCompanion data) {
    return PhotoBackupTargetRow(
      destination: data.destination.present
          ? data.destination.value
          : this.destination,
      doneKeys: data.doneKeys.present ? data.doneKeys.value : this.doneKeys,
      lastFinishedAt: data.lastFinishedAt.present
          ? data.lastFinishedAt.value
          : this.lastFinishedAt,
      targetRef: data.targetRef.present ? data.targetRef.value : this.targetRef,
      targetName: data.targetName.present
          ? data.targetName.value
          : this.targetName,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PhotoBackupTargetRow(')
          ..write('destination: $destination, ')
          ..write('doneKeys: $doneKeys, ')
          ..write('lastFinishedAt: $lastFinishedAt, ')
          ..write('targetRef: $targetRef, ')
          ..write('targetName: $targetName, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    destination,
    doneKeys,
    lastFinishedAt,
    targetRef,
    targetName,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PhotoBackupTargetRow &&
          other.destination == this.destination &&
          other.doneKeys == this.doneKeys &&
          other.lastFinishedAt == this.lastFinishedAt &&
          other.targetRef == this.targetRef &&
          other.targetName == this.targetName &&
          other.updatedAt == this.updatedAt);
}

class PhotoBackupTargetRowsCompanion
    extends UpdateCompanion<PhotoBackupTargetRow> {
  final Value<String> destination;
  final Value<String> doneKeys;
  final Value<int> lastFinishedAt;
  final Value<String> targetRef;
  final Value<String> targetName;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const PhotoBackupTargetRowsCompanion({
    this.destination = const Value.absent(),
    this.doneKeys = const Value.absent(),
    this.lastFinishedAt = const Value.absent(),
    this.targetRef = const Value.absent(),
    this.targetName = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PhotoBackupTargetRowsCompanion.insert({
    required String destination,
    this.doneKeys = const Value.absent(),
    this.lastFinishedAt = const Value.absent(),
    this.targetRef = const Value.absent(),
    this.targetName = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : destination = Value(destination);
  static Insertable<PhotoBackupTargetRow> custom({
    Expression<String>? destination,
    Expression<String>? doneKeys,
    Expression<int>? lastFinishedAt,
    Expression<String>? targetRef,
    Expression<String>? targetName,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (destination != null) 'destination': destination,
      if (doneKeys != null) 'done_keys': doneKeys,
      if (lastFinishedAt != null) 'last_finished_at': lastFinishedAt,
      if (targetRef != null) 'target_ref': targetRef,
      if (targetName != null) 'target_name': targetName,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PhotoBackupTargetRowsCompanion copyWith({
    Value<String>? destination,
    Value<String>? doneKeys,
    Value<int>? lastFinishedAt,
    Value<String>? targetRef,
    Value<String>? targetName,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return PhotoBackupTargetRowsCompanion(
      destination: destination ?? this.destination,
      doneKeys: doneKeys ?? this.doneKeys,
      lastFinishedAt: lastFinishedAt ?? this.lastFinishedAt,
      targetRef: targetRef ?? this.targetRef,
      targetName: targetName ?? this.targetName,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (destination.present) {
      map['destination'] = Variable<String>(destination.value);
    }
    if (doneKeys.present) {
      map['done_keys'] = Variable<String>(doneKeys.value);
    }
    if (lastFinishedAt.present) {
      map['last_finished_at'] = Variable<int>(lastFinishedAt.value);
    }
    if (targetRef.present) {
      map['target_ref'] = Variable<String>(targetRef.value);
    }
    if (targetName.present) {
      map['target_name'] = Variable<String>(targetName.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PhotoBackupTargetRowsCompanion(')
          ..write('destination: $destination, ')
          ..write('doneKeys: $doneKeys, ')
          ..write('lastFinishedAt: $lastFinishedAt, ')
          ..write('targetRef: $targetRef, ')
          ..write('targetName: $targetName, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$ChatDatabase extends GeneratedDatabase {
  _$ChatDatabase(QueryExecutor e) : super(e);
  $ChatDatabaseManager get managers => $ChatDatabaseManager(this);
  late final $ChannelRowsTable channelRows = $ChannelRowsTable(this);
  late final $UserRowsTable userRows = $UserRowsTable(this);
  late final $PostRowsTable postRows = $PostRowsTable(this);
  late final $KeyValueRowsTable keyValueRows = $KeyValueRowsTable(this);
  late final $FileEntryRowsTable fileEntryRows = $FileEntryRowsTable(this);
  late final $NoteCacheRowsTable noteCacheRows = $NoteCacheRowsTable(this);
  late final $NotebookCacheRowsTable notebookCacheRows =
      $NotebookCacheRowsTable(this);
  late final $TodoCacheRowsTable todoCacheRows = $TodoCacheRowsTable(this);
  late final $NotePendingRowsTable notePendingRows = $NotePendingRowsTable(
    this,
  );
  late final $BookProgressRowsTable bookProgressRows = $BookProgressRowsTable(
    this,
  );
  late final $BookMarkRowsTable bookMarkRows = $BookMarkRowsTable(this);
  late final $PhotoBackupTargetRowsTable photoBackupTargetRows =
      $PhotoBackupTargetRowsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    channelRows,
    userRows,
    postRows,
    keyValueRows,
    fileEntryRows,
    noteCacheRows,
    notebookCacheRows,
    todoCacheRows,
    notePendingRows,
    bookProgressRows,
    bookMarkRows,
    photoBackupTargetRows,
  ];
}

typedef $$ChannelRowsTableCreateCompanionBuilder =
    ChannelRowsCompanion Function({
      Value<int> channelId,
      Value<String> name,
      Value<String> purpose,
      Value<String> type,
      Value<bool> encrypted,
      Value<bool> isJoined,
      Value<bool> isStar,
      Value<int> unread,
      Value<int> unreadMention,
      Value<int> unreadComment,
      Value<int> unreadMentionComment,
      Value<String> unreadThread,
      Value<String> subscribes,
      Value<String> members,
      Value<String> brokenUsers,
      Value<String> channelKeyEnc,
      Value<int> totalMemberCount,
      Value<int> creatorId,
      Value<int> lastPostAt,
      Value<int> lastViewAt,
      Value<int> lastViewCommentAt,
      Value<int> channelOrderTime,
      Value<int> hideGlobalAt,
      Value<int> lastHideAt,
      Value<String> notificationDesktop,
      Value<String> notificationMobile,
      Value<bool> notificationMute,
      Value<String> hashtags,
    });
typedef $$ChannelRowsTableUpdateCompanionBuilder =
    ChannelRowsCompanion Function({
      Value<int> channelId,
      Value<String> name,
      Value<String> purpose,
      Value<String> type,
      Value<bool> encrypted,
      Value<bool> isJoined,
      Value<bool> isStar,
      Value<int> unread,
      Value<int> unreadMention,
      Value<int> unreadComment,
      Value<int> unreadMentionComment,
      Value<String> unreadThread,
      Value<String> subscribes,
      Value<String> members,
      Value<String> brokenUsers,
      Value<String> channelKeyEnc,
      Value<int> totalMemberCount,
      Value<int> creatorId,
      Value<int> lastPostAt,
      Value<int> lastViewAt,
      Value<int> lastViewCommentAt,
      Value<int> channelOrderTime,
      Value<int> hideGlobalAt,
      Value<int> lastHideAt,
      Value<String> notificationDesktop,
      Value<String> notificationMobile,
      Value<bool> notificationMute,
      Value<String> hashtags,
    });

class $$ChannelRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $ChannelRowsTable> {
  $$ChannelRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get purpose => $composableBuilder(
    column: $table.purpose,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get encrypted => $composableBuilder(
    column: $table.encrypted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isJoined => $composableBuilder(
    column: $table.isJoined,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isStar => $composableBuilder(
    column: $table.isStar,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unread => $composableBuilder(
    column: $table.unread,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unreadMention => $composableBuilder(
    column: $table.unreadMention,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unreadComment => $composableBuilder(
    column: $table.unreadComment,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unreadMentionComment => $composableBuilder(
    column: $table.unreadMentionComment,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get unreadThread => $composableBuilder(
    column: $table.unreadThread,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subscribes => $composableBuilder(
    column: $table.subscribes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get members => $composableBuilder(
    column: $table.members,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get brokenUsers => $composableBuilder(
    column: $table.brokenUsers,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get channelKeyEnc => $composableBuilder(
    column: $table.channelKeyEnc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalMemberCount => $composableBuilder(
    column: $table.totalMemberCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get creatorId => $composableBuilder(
    column: $table.creatorId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastPostAt => $composableBuilder(
    column: $table.lastPostAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastViewAt => $composableBuilder(
    column: $table.lastViewAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastViewCommentAt => $composableBuilder(
    column: $table.lastViewCommentAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get channelOrderTime => $composableBuilder(
    column: $table.channelOrderTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get hideGlobalAt => $composableBuilder(
    column: $table.hideGlobalAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastHideAt => $composableBuilder(
    column: $table.lastHideAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notificationDesktop => $composableBuilder(
    column: $table.notificationDesktop,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notificationMobile => $composableBuilder(
    column: $table.notificationMobile,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get notificationMute => $composableBuilder(
    column: $table.notificationMute,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hashtags => $composableBuilder(
    column: $table.hashtags,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ChannelRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $ChannelRowsTable> {
  $$ChannelRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get purpose => $composableBuilder(
    column: $table.purpose,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get encrypted => $composableBuilder(
    column: $table.encrypted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isJoined => $composableBuilder(
    column: $table.isJoined,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isStar => $composableBuilder(
    column: $table.isStar,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unread => $composableBuilder(
    column: $table.unread,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unreadMention => $composableBuilder(
    column: $table.unreadMention,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unreadComment => $composableBuilder(
    column: $table.unreadComment,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unreadMentionComment => $composableBuilder(
    column: $table.unreadMentionComment,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get unreadThread => $composableBuilder(
    column: $table.unreadThread,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subscribes => $composableBuilder(
    column: $table.subscribes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get members => $composableBuilder(
    column: $table.members,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get brokenUsers => $composableBuilder(
    column: $table.brokenUsers,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get channelKeyEnc => $composableBuilder(
    column: $table.channelKeyEnc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalMemberCount => $composableBuilder(
    column: $table.totalMemberCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get creatorId => $composableBuilder(
    column: $table.creatorId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastPostAt => $composableBuilder(
    column: $table.lastPostAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastViewAt => $composableBuilder(
    column: $table.lastViewAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastViewCommentAt => $composableBuilder(
    column: $table.lastViewCommentAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get channelOrderTime => $composableBuilder(
    column: $table.channelOrderTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get hideGlobalAt => $composableBuilder(
    column: $table.hideGlobalAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastHideAt => $composableBuilder(
    column: $table.lastHideAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notificationDesktop => $composableBuilder(
    column: $table.notificationDesktop,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notificationMobile => $composableBuilder(
    column: $table.notificationMobile,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get notificationMute => $composableBuilder(
    column: $table.notificationMute,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hashtags => $composableBuilder(
    column: $table.hashtags,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ChannelRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $ChannelRowsTable> {
  $$ChannelRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get channelId =>
      $composableBuilder(column: $table.channelId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get purpose =>
      $composableBuilder(column: $table.purpose, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<bool> get encrypted =>
      $composableBuilder(column: $table.encrypted, builder: (column) => column);

  GeneratedColumn<bool> get isJoined =>
      $composableBuilder(column: $table.isJoined, builder: (column) => column);

  GeneratedColumn<bool> get isStar =>
      $composableBuilder(column: $table.isStar, builder: (column) => column);

  GeneratedColumn<int> get unread =>
      $composableBuilder(column: $table.unread, builder: (column) => column);

  GeneratedColumn<int> get unreadMention => $composableBuilder(
    column: $table.unreadMention,
    builder: (column) => column,
  );

  GeneratedColumn<int> get unreadComment => $composableBuilder(
    column: $table.unreadComment,
    builder: (column) => column,
  );

  GeneratedColumn<int> get unreadMentionComment => $composableBuilder(
    column: $table.unreadMentionComment,
    builder: (column) => column,
  );

  GeneratedColumn<String> get unreadThread => $composableBuilder(
    column: $table.unreadThread,
    builder: (column) => column,
  );

  GeneratedColumn<String> get subscribes => $composableBuilder(
    column: $table.subscribes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get members =>
      $composableBuilder(column: $table.members, builder: (column) => column);

  GeneratedColumn<String> get brokenUsers => $composableBuilder(
    column: $table.brokenUsers,
    builder: (column) => column,
  );

  GeneratedColumn<String> get channelKeyEnc => $composableBuilder(
    column: $table.channelKeyEnc,
    builder: (column) => column,
  );

  GeneratedColumn<int> get totalMemberCount => $composableBuilder(
    column: $table.totalMemberCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get creatorId =>
      $composableBuilder(column: $table.creatorId, builder: (column) => column);

  GeneratedColumn<int> get lastPostAt => $composableBuilder(
    column: $table.lastPostAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastViewAt => $composableBuilder(
    column: $table.lastViewAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastViewCommentAt => $composableBuilder(
    column: $table.lastViewCommentAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get channelOrderTime => $composableBuilder(
    column: $table.channelOrderTime,
    builder: (column) => column,
  );

  GeneratedColumn<int> get hideGlobalAt => $composableBuilder(
    column: $table.hideGlobalAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastHideAt => $composableBuilder(
    column: $table.lastHideAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notificationDesktop => $composableBuilder(
    column: $table.notificationDesktop,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notificationMobile => $composableBuilder(
    column: $table.notificationMobile,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get notificationMute => $composableBuilder(
    column: $table.notificationMute,
    builder: (column) => column,
  );

  GeneratedColumn<String> get hashtags =>
      $composableBuilder(column: $table.hashtags, builder: (column) => column);
}

class $$ChannelRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $ChannelRowsTable,
          ChannelRow,
          $$ChannelRowsTableFilterComposer,
          $$ChannelRowsTableOrderingComposer,
          $$ChannelRowsTableAnnotationComposer,
          $$ChannelRowsTableCreateCompanionBuilder,
          $$ChannelRowsTableUpdateCompanionBuilder,
          (
            ChannelRow,
            BaseReferences<_$ChatDatabase, $ChannelRowsTable, ChannelRow>,
          ),
          ChannelRow,
          PrefetchHooks Function()
        > {
  $$ChannelRowsTableTableManager(_$ChatDatabase db, $ChannelRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChannelRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChannelRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChannelRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> channelId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> purpose = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<bool> encrypted = const Value.absent(),
                Value<bool> isJoined = const Value.absent(),
                Value<bool> isStar = const Value.absent(),
                Value<int> unread = const Value.absent(),
                Value<int> unreadMention = const Value.absent(),
                Value<int> unreadComment = const Value.absent(),
                Value<int> unreadMentionComment = const Value.absent(),
                Value<String> unreadThread = const Value.absent(),
                Value<String> subscribes = const Value.absent(),
                Value<String> members = const Value.absent(),
                Value<String> brokenUsers = const Value.absent(),
                Value<String> channelKeyEnc = const Value.absent(),
                Value<int> totalMemberCount = const Value.absent(),
                Value<int> creatorId = const Value.absent(),
                Value<int> lastPostAt = const Value.absent(),
                Value<int> lastViewAt = const Value.absent(),
                Value<int> lastViewCommentAt = const Value.absent(),
                Value<int> channelOrderTime = const Value.absent(),
                Value<int> hideGlobalAt = const Value.absent(),
                Value<int> lastHideAt = const Value.absent(),
                Value<String> notificationDesktop = const Value.absent(),
                Value<String> notificationMobile = const Value.absent(),
                Value<bool> notificationMute = const Value.absent(),
                Value<String> hashtags = const Value.absent(),
              }) => ChannelRowsCompanion(
                channelId: channelId,
                name: name,
                purpose: purpose,
                type: type,
                encrypted: encrypted,
                isJoined: isJoined,
                isStar: isStar,
                unread: unread,
                unreadMention: unreadMention,
                unreadComment: unreadComment,
                unreadMentionComment: unreadMentionComment,
                unreadThread: unreadThread,
                subscribes: subscribes,
                members: members,
                brokenUsers: brokenUsers,
                channelKeyEnc: channelKeyEnc,
                totalMemberCount: totalMemberCount,
                creatorId: creatorId,
                lastPostAt: lastPostAt,
                lastViewAt: lastViewAt,
                lastViewCommentAt: lastViewCommentAt,
                channelOrderTime: channelOrderTime,
                hideGlobalAt: hideGlobalAt,
                lastHideAt: lastHideAt,
                notificationDesktop: notificationDesktop,
                notificationMobile: notificationMobile,
                notificationMute: notificationMute,
                hashtags: hashtags,
              ),
          createCompanionCallback:
              ({
                Value<int> channelId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> purpose = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<bool> encrypted = const Value.absent(),
                Value<bool> isJoined = const Value.absent(),
                Value<bool> isStar = const Value.absent(),
                Value<int> unread = const Value.absent(),
                Value<int> unreadMention = const Value.absent(),
                Value<int> unreadComment = const Value.absent(),
                Value<int> unreadMentionComment = const Value.absent(),
                Value<String> unreadThread = const Value.absent(),
                Value<String> subscribes = const Value.absent(),
                Value<String> members = const Value.absent(),
                Value<String> brokenUsers = const Value.absent(),
                Value<String> channelKeyEnc = const Value.absent(),
                Value<int> totalMemberCount = const Value.absent(),
                Value<int> creatorId = const Value.absent(),
                Value<int> lastPostAt = const Value.absent(),
                Value<int> lastViewAt = const Value.absent(),
                Value<int> lastViewCommentAt = const Value.absent(),
                Value<int> channelOrderTime = const Value.absent(),
                Value<int> hideGlobalAt = const Value.absent(),
                Value<int> lastHideAt = const Value.absent(),
                Value<String> notificationDesktop = const Value.absent(),
                Value<String> notificationMobile = const Value.absent(),
                Value<bool> notificationMute = const Value.absent(),
                Value<String> hashtags = const Value.absent(),
              }) => ChannelRowsCompanion.insert(
                channelId: channelId,
                name: name,
                purpose: purpose,
                type: type,
                encrypted: encrypted,
                isJoined: isJoined,
                isStar: isStar,
                unread: unread,
                unreadMention: unreadMention,
                unreadComment: unreadComment,
                unreadMentionComment: unreadMentionComment,
                unreadThread: unreadThread,
                subscribes: subscribes,
                members: members,
                brokenUsers: brokenUsers,
                channelKeyEnc: channelKeyEnc,
                totalMemberCount: totalMemberCount,
                creatorId: creatorId,
                lastPostAt: lastPostAt,
                lastViewAt: lastViewAt,
                lastViewCommentAt: lastViewCommentAt,
                channelOrderTime: channelOrderTime,
                hideGlobalAt: hideGlobalAt,
                lastHideAt: lastHideAt,
                notificationDesktop: notificationDesktop,
                notificationMobile: notificationMobile,
                notificationMute: notificationMute,
                hashtags: hashtags,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ChannelRowsTable, ChannelRow>(table),
                  BaseReferences<_$ChatDatabase, $ChannelRowsTable, ChannelRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ChannelRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $ChannelRowsTable,
      ChannelRow,
      $$ChannelRowsTableFilterComposer,
      $$ChannelRowsTableOrderingComposer,
      $$ChannelRowsTableAnnotationComposer,
      $$ChannelRowsTableCreateCompanionBuilder,
      $$ChannelRowsTableUpdateCompanionBuilder,
      (
        ChannelRow,
        BaseReferences<_$ChatDatabase, $ChannelRowsTable, ChannelRow>,
      ),
      ChannelRow,
      PrefetchHooks Function()
    >;
typedef $$UserRowsTableCreateCompanionBuilder =
    UserRowsCompanion Function({
      Value<int> userId,
      Value<String> username,
      Value<String> nickname,
      Value<String> type,
      Value<String> status,
      Value<String> humanType,
      Value<String> botType,
      Value<int> appId,
      Value<int> dsmUid,
      Value<int> avatarVersion,
      Value<String> avatarColor,
      Value<String> email,
      Value<String> description,
      Value<String> publicKey,
      Value<String> privateKeyEnc,
      Value<bool> isDisabled,
      Value<bool> isDeleted,
      Value<bool> hasUrl,
      Value<String> botProps,
      Value<bool> isAlwaysOffline,
      Value<int> createAt,
      Value<int> updateAt,
      Value<int> deleteAt,
    });
typedef $$UserRowsTableUpdateCompanionBuilder =
    UserRowsCompanion Function({
      Value<int> userId,
      Value<String> username,
      Value<String> nickname,
      Value<String> type,
      Value<String> status,
      Value<String> humanType,
      Value<String> botType,
      Value<int> appId,
      Value<int> dsmUid,
      Value<int> avatarVersion,
      Value<String> avatarColor,
      Value<String> email,
      Value<String> description,
      Value<String> publicKey,
      Value<String> privateKeyEnc,
      Value<bool> isDisabled,
      Value<bool> isDeleted,
      Value<bool> hasUrl,
      Value<String> botProps,
      Value<bool> isAlwaysOffline,
      Value<int> createAt,
      Value<int> updateAt,
      Value<int> deleteAt,
    });

class $$UserRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $UserRowsTable> {
  $$UserRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nickname => $composableBuilder(
    column: $table.nickname,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get humanType => $composableBuilder(
    column: $table.humanType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get botType => $composableBuilder(
    column: $table.botType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get appId => $composableBuilder(
    column: $table.appId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dsmUid => $composableBuilder(
    column: $table.dsmUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get avatarVersion => $composableBuilder(
    column: $table.avatarVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get avatarColor => $composableBuilder(
    column: $table.avatarColor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get email => $composableBuilder(
    column: $table.email,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get publicKey => $composableBuilder(
    column: $table.publicKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get privateKeyEnc => $composableBuilder(
    column: $table.privateKeyEnc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDisabled => $composableBuilder(
    column: $table.isDisabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDeleted => $composableBuilder(
    column: $table.isDeleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasUrl => $composableBuilder(
    column: $table.hasUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get botProps => $composableBuilder(
    column: $table.botProps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isAlwaysOffline => $composableBuilder(
    column: $table.isAlwaysOffline,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createAt => $composableBuilder(
    column: $table.createAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updateAt => $composableBuilder(
    column: $table.updateAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deleteAt => $composableBuilder(
    column: $table.deleteAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$UserRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $UserRowsTable> {
  $$UserRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nickname => $composableBuilder(
    column: $table.nickname,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get humanType => $composableBuilder(
    column: $table.humanType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get botType => $composableBuilder(
    column: $table.botType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get appId => $composableBuilder(
    column: $table.appId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dsmUid => $composableBuilder(
    column: $table.dsmUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get avatarVersion => $composableBuilder(
    column: $table.avatarVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get avatarColor => $composableBuilder(
    column: $table.avatarColor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get email => $composableBuilder(
    column: $table.email,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get publicKey => $composableBuilder(
    column: $table.publicKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get privateKeyEnc => $composableBuilder(
    column: $table.privateKeyEnc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDisabled => $composableBuilder(
    column: $table.isDisabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDeleted => $composableBuilder(
    column: $table.isDeleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasUrl => $composableBuilder(
    column: $table.hasUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get botProps => $composableBuilder(
    column: $table.botProps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isAlwaysOffline => $composableBuilder(
    column: $table.isAlwaysOffline,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createAt => $composableBuilder(
    column: $table.createAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updateAt => $composableBuilder(
    column: $table.updateAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deleteAt => $composableBuilder(
    column: $table.deleteAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$UserRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $UserRowsTable> {
  $$UserRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get nickname =>
      $composableBuilder(column: $table.nickname, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get humanType =>
      $composableBuilder(column: $table.humanType, builder: (column) => column);

  GeneratedColumn<String> get botType =>
      $composableBuilder(column: $table.botType, builder: (column) => column);

  GeneratedColumn<int> get appId =>
      $composableBuilder(column: $table.appId, builder: (column) => column);

  GeneratedColumn<int> get dsmUid =>
      $composableBuilder(column: $table.dsmUid, builder: (column) => column);

  GeneratedColumn<int> get avatarVersion => $composableBuilder(
    column: $table.avatarVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get avatarColor => $composableBuilder(
    column: $table.avatarColor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get email =>
      $composableBuilder(column: $table.email, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<String> get publicKey =>
      $composableBuilder(column: $table.publicKey, builder: (column) => column);

  GeneratedColumn<String> get privateKeyEnc => $composableBuilder(
    column: $table.privateKeyEnc,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isDisabled => $composableBuilder(
    column: $table.isDisabled,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isDeleted =>
      $composableBuilder(column: $table.isDeleted, builder: (column) => column);

  GeneratedColumn<bool> get hasUrl =>
      $composableBuilder(column: $table.hasUrl, builder: (column) => column);

  GeneratedColumn<String> get botProps =>
      $composableBuilder(column: $table.botProps, builder: (column) => column);

  GeneratedColumn<bool> get isAlwaysOffline => $composableBuilder(
    column: $table.isAlwaysOffline,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createAt =>
      $composableBuilder(column: $table.createAt, builder: (column) => column);

  GeneratedColumn<int> get updateAt =>
      $composableBuilder(column: $table.updateAt, builder: (column) => column);

  GeneratedColumn<int> get deleteAt =>
      $composableBuilder(column: $table.deleteAt, builder: (column) => column);
}

class $$UserRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $UserRowsTable,
          UserRow,
          $$UserRowsTableFilterComposer,
          $$UserRowsTableOrderingComposer,
          $$UserRowsTableAnnotationComposer,
          $$UserRowsTableCreateCompanionBuilder,
          $$UserRowsTableUpdateCompanionBuilder,
          (UserRow, BaseReferences<_$ChatDatabase, $UserRowsTable, UserRow>),
          UserRow,
          PrefetchHooks Function()
        > {
  $$UserRowsTableTableManager(_$ChatDatabase db, $UserRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UserRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UserRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UserRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> userId = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> nickname = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> humanType = const Value.absent(),
                Value<String> botType = const Value.absent(),
                Value<int> appId = const Value.absent(),
                Value<int> dsmUid = const Value.absent(),
                Value<int> avatarVersion = const Value.absent(),
                Value<String> avatarColor = const Value.absent(),
                Value<String> email = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<String> publicKey = const Value.absent(),
                Value<String> privateKeyEnc = const Value.absent(),
                Value<bool> isDisabled = const Value.absent(),
                Value<bool> isDeleted = const Value.absent(),
                Value<bool> hasUrl = const Value.absent(),
                Value<String> botProps = const Value.absent(),
                Value<bool> isAlwaysOffline = const Value.absent(),
                Value<int> createAt = const Value.absent(),
                Value<int> updateAt = const Value.absent(),
                Value<int> deleteAt = const Value.absent(),
              }) => UserRowsCompanion(
                userId: userId,
                username: username,
                nickname: nickname,
                type: type,
                status: status,
                humanType: humanType,
                botType: botType,
                appId: appId,
                dsmUid: dsmUid,
                avatarVersion: avatarVersion,
                avatarColor: avatarColor,
                email: email,
                description: description,
                publicKey: publicKey,
                privateKeyEnc: privateKeyEnc,
                isDisabled: isDisabled,
                isDeleted: isDeleted,
                hasUrl: hasUrl,
                botProps: botProps,
                isAlwaysOffline: isAlwaysOffline,
                createAt: createAt,
                updateAt: updateAt,
                deleteAt: deleteAt,
              ),
          createCompanionCallback:
              ({
                Value<int> userId = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> nickname = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> humanType = const Value.absent(),
                Value<String> botType = const Value.absent(),
                Value<int> appId = const Value.absent(),
                Value<int> dsmUid = const Value.absent(),
                Value<int> avatarVersion = const Value.absent(),
                Value<String> avatarColor = const Value.absent(),
                Value<String> email = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<String> publicKey = const Value.absent(),
                Value<String> privateKeyEnc = const Value.absent(),
                Value<bool> isDisabled = const Value.absent(),
                Value<bool> isDeleted = const Value.absent(),
                Value<bool> hasUrl = const Value.absent(),
                Value<String> botProps = const Value.absent(),
                Value<bool> isAlwaysOffline = const Value.absent(),
                Value<int> createAt = const Value.absent(),
                Value<int> updateAt = const Value.absent(),
                Value<int> deleteAt = const Value.absent(),
              }) => UserRowsCompanion.insert(
                userId: userId,
                username: username,
                nickname: nickname,
                type: type,
                status: status,
                humanType: humanType,
                botType: botType,
                appId: appId,
                dsmUid: dsmUid,
                avatarVersion: avatarVersion,
                avatarColor: avatarColor,
                email: email,
                description: description,
                publicKey: publicKey,
                privateKeyEnc: privateKeyEnc,
                isDisabled: isDisabled,
                isDeleted: isDeleted,
                hasUrl: hasUrl,
                botProps: botProps,
                isAlwaysOffline: isAlwaysOffline,
                createAt: createAt,
                updateAt: updateAt,
                deleteAt: deleteAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$UserRowsTable, UserRow>(table),
                  BaseReferences<_$ChatDatabase, $UserRowsTable, UserRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$UserRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $UserRowsTable,
      UserRow,
      $$UserRowsTableFilterComposer,
      $$UserRowsTableOrderingComposer,
      $$UserRowsTableAnnotationComposer,
      $$UserRowsTableCreateCompanionBuilder,
      $$UserRowsTableUpdateCompanionBuilder,
      (UserRow, BaseReferences<_$ChatDatabase, $UserRowsTable, UserRow>),
      UserRow,
      PrefetchHooks Function()
    >;
typedef $$PostRowsTableCreateCompanionBuilder =
    PostRowsCompanion Function({
      Value<int> id,
      Value<int> postId,
      required int channelId,
      Value<int> creatorId,
      Value<int> threadId,
      Value<String> type,
      Value<String> message,
      Value<int> createAt,
      Value<int> updateAt,
      Value<int> deleteAt,
      Value<int> lastCommentAt,
      Value<int> lastPinAt,
      Value<int> commentCount,
      Value<bool> isStar,
      Value<bool> isSticky,
      Value<bool> encrypted,
      Value<bool> safeUrl,
      Value<bool> staticUrl,
      Value<String> forwardType,
      Value<String> hashtags,
      Value<String> hashtagsAdditional,
      Value<String> mentions,
      Value<String> reactions,
      Value<String> urlProps,
      Value<String> fileProps,
      Value<String> systemProps,
      Value<String> props,
      Value<int> tmpPostId,
      Value<int> state,
      required String dedupeKey,
    });
typedef $$PostRowsTableUpdateCompanionBuilder =
    PostRowsCompanion Function({
      Value<int> id,
      Value<int> postId,
      Value<int> channelId,
      Value<int> creatorId,
      Value<int> threadId,
      Value<String> type,
      Value<String> message,
      Value<int> createAt,
      Value<int> updateAt,
      Value<int> deleteAt,
      Value<int> lastCommentAt,
      Value<int> lastPinAt,
      Value<int> commentCount,
      Value<bool> isStar,
      Value<bool> isSticky,
      Value<bool> encrypted,
      Value<bool> safeUrl,
      Value<bool> staticUrl,
      Value<String> forwardType,
      Value<String> hashtags,
      Value<String> hashtagsAdditional,
      Value<String> mentions,
      Value<String> reactions,
      Value<String> urlProps,
      Value<String> fileProps,
      Value<String> systemProps,
      Value<String> props,
      Value<int> tmpPostId,
      Value<int> state,
      Value<String> dedupeKey,
    });

class $$PostRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $PostRowsTable> {
  $$PostRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get postId => $composableBuilder(
    column: $table.postId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get creatorId => $composableBuilder(
    column: $table.creatorId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createAt => $composableBuilder(
    column: $table.createAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updateAt => $composableBuilder(
    column: $table.updateAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deleteAt => $composableBuilder(
    column: $table.deleteAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastCommentAt => $composableBuilder(
    column: $table.lastCommentAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastPinAt => $composableBuilder(
    column: $table.lastPinAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get commentCount => $composableBuilder(
    column: $table.commentCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isStar => $composableBuilder(
    column: $table.isStar,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isSticky => $composableBuilder(
    column: $table.isSticky,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get encrypted => $composableBuilder(
    column: $table.encrypted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get safeUrl => $composableBuilder(
    column: $table.safeUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get staticUrl => $composableBuilder(
    column: $table.staticUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get forwardType => $composableBuilder(
    column: $table.forwardType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hashtags => $composableBuilder(
    column: $table.hashtags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hashtagsAdditional => $composableBuilder(
    column: $table.hashtagsAdditional,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mentions => $composableBuilder(
    column: $table.mentions,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reactions => $composableBuilder(
    column: $table.reactions,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get urlProps => $composableBuilder(
    column: $table.urlProps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileProps => $composableBuilder(
    column: $table.fileProps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get systemProps => $composableBuilder(
    column: $table.systemProps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get props => $composableBuilder(
    column: $table.props,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tmpPostId => $composableBuilder(
    column: $table.tmpPostId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dedupeKey => $composableBuilder(
    column: $table.dedupeKey,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PostRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $PostRowsTable> {
  $$PostRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get postId => $composableBuilder(
    column: $table.postId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get creatorId => $composableBuilder(
    column: $table.creatorId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get threadId => $composableBuilder(
    column: $table.threadId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createAt => $composableBuilder(
    column: $table.createAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updateAt => $composableBuilder(
    column: $table.updateAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deleteAt => $composableBuilder(
    column: $table.deleteAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastCommentAt => $composableBuilder(
    column: $table.lastCommentAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastPinAt => $composableBuilder(
    column: $table.lastPinAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get commentCount => $composableBuilder(
    column: $table.commentCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isStar => $composableBuilder(
    column: $table.isStar,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isSticky => $composableBuilder(
    column: $table.isSticky,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get encrypted => $composableBuilder(
    column: $table.encrypted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get safeUrl => $composableBuilder(
    column: $table.safeUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get staticUrl => $composableBuilder(
    column: $table.staticUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get forwardType => $composableBuilder(
    column: $table.forwardType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hashtags => $composableBuilder(
    column: $table.hashtags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hashtagsAdditional => $composableBuilder(
    column: $table.hashtagsAdditional,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mentions => $composableBuilder(
    column: $table.mentions,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reactions => $composableBuilder(
    column: $table.reactions,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get urlProps => $composableBuilder(
    column: $table.urlProps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileProps => $composableBuilder(
    column: $table.fileProps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get systemProps => $composableBuilder(
    column: $table.systemProps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get props => $composableBuilder(
    column: $table.props,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tmpPostId => $composableBuilder(
    column: $table.tmpPostId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dedupeKey => $composableBuilder(
    column: $table.dedupeKey,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PostRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $PostRowsTable> {
  $$PostRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get postId =>
      $composableBuilder(column: $table.postId, builder: (column) => column);

  GeneratedColumn<int> get channelId =>
      $composableBuilder(column: $table.channelId, builder: (column) => column);

  GeneratedColumn<int> get creatorId =>
      $composableBuilder(column: $table.creatorId, builder: (column) => column);

  GeneratedColumn<int> get threadId =>
      $composableBuilder(column: $table.threadId, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get message =>
      $composableBuilder(column: $table.message, builder: (column) => column);

  GeneratedColumn<int> get createAt =>
      $composableBuilder(column: $table.createAt, builder: (column) => column);

  GeneratedColumn<int> get updateAt =>
      $composableBuilder(column: $table.updateAt, builder: (column) => column);

  GeneratedColumn<int> get deleteAt =>
      $composableBuilder(column: $table.deleteAt, builder: (column) => column);

  GeneratedColumn<int> get lastCommentAt => $composableBuilder(
    column: $table.lastCommentAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastPinAt =>
      $composableBuilder(column: $table.lastPinAt, builder: (column) => column);

  GeneratedColumn<int> get commentCount => $composableBuilder(
    column: $table.commentCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isStar =>
      $composableBuilder(column: $table.isStar, builder: (column) => column);

  GeneratedColumn<bool> get isSticky =>
      $composableBuilder(column: $table.isSticky, builder: (column) => column);

  GeneratedColumn<bool> get encrypted =>
      $composableBuilder(column: $table.encrypted, builder: (column) => column);

  GeneratedColumn<bool> get safeUrl =>
      $composableBuilder(column: $table.safeUrl, builder: (column) => column);

  GeneratedColumn<bool> get staticUrl =>
      $composableBuilder(column: $table.staticUrl, builder: (column) => column);

  GeneratedColumn<String> get forwardType => $composableBuilder(
    column: $table.forwardType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get hashtags =>
      $composableBuilder(column: $table.hashtags, builder: (column) => column);

  GeneratedColumn<String> get hashtagsAdditional => $composableBuilder(
    column: $table.hashtagsAdditional,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mentions =>
      $composableBuilder(column: $table.mentions, builder: (column) => column);

  GeneratedColumn<String> get reactions =>
      $composableBuilder(column: $table.reactions, builder: (column) => column);

  GeneratedColumn<String> get urlProps =>
      $composableBuilder(column: $table.urlProps, builder: (column) => column);

  GeneratedColumn<String> get fileProps =>
      $composableBuilder(column: $table.fileProps, builder: (column) => column);

  GeneratedColumn<String> get systemProps => $composableBuilder(
    column: $table.systemProps,
    builder: (column) => column,
  );

  GeneratedColumn<String> get props =>
      $composableBuilder(column: $table.props, builder: (column) => column);

  GeneratedColumn<int> get tmpPostId =>
      $composableBuilder(column: $table.tmpPostId, builder: (column) => column);

  GeneratedColumn<int> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get dedupeKey =>
      $composableBuilder(column: $table.dedupeKey, builder: (column) => column);
}

class $$PostRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $PostRowsTable,
          PostRow,
          $$PostRowsTableFilterComposer,
          $$PostRowsTableOrderingComposer,
          $$PostRowsTableAnnotationComposer,
          $$PostRowsTableCreateCompanionBuilder,
          $$PostRowsTableUpdateCompanionBuilder,
          (PostRow, BaseReferences<_$ChatDatabase, $PostRowsTable, PostRow>),
          PostRow,
          PrefetchHooks Function()
        > {
  $$PostRowsTableTableManager(_$ChatDatabase db, $PostRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PostRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PostRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PostRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> postId = const Value.absent(),
                Value<int> channelId = const Value.absent(),
                Value<int> creatorId = const Value.absent(),
                Value<int> threadId = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> message = const Value.absent(),
                Value<int> createAt = const Value.absent(),
                Value<int> updateAt = const Value.absent(),
                Value<int> deleteAt = const Value.absent(),
                Value<int> lastCommentAt = const Value.absent(),
                Value<int> lastPinAt = const Value.absent(),
                Value<int> commentCount = const Value.absent(),
                Value<bool> isStar = const Value.absent(),
                Value<bool> isSticky = const Value.absent(),
                Value<bool> encrypted = const Value.absent(),
                Value<bool> safeUrl = const Value.absent(),
                Value<bool> staticUrl = const Value.absent(),
                Value<String> forwardType = const Value.absent(),
                Value<String> hashtags = const Value.absent(),
                Value<String> hashtagsAdditional = const Value.absent(),
                Value<String> mentions = const Value.absent(),
                Value<String> reactions = const Value.absent(),
                Value<String> urlProps = const Value.absent(),
                Value<String> fileProps = const Value.absent(),
                Value<String> systemProps = const Value.absent(),
                Value<String> props = const Value.absent(),
                Value<int> tmpPostId = const Value.absent(),
                Value<int> state = const Value.absent(),
                Value<String> dedupeKey = const Value.absent(),
              }) => PostRowsCompanion(
                id: id,
                postId: postId,
                channelId: channelId,
                creatorId: creatorId,
                threadId: threadId,
                type: type,
                message: message,
                createAt: createAt,
                updateAt: updateAt,
                deleteAt: deleteAt,
                lastCommentAt: lastCommentAt,
                lastPinAt: lastPinAt,
                commentCount: commentCount,
                isStar: isStar,
                isSticky: isSticky,
                encrypted: encrypted,
                safeUrl: safeUrl,
                staticUrl: staticUrl,
                forwardType: forwardType,
                hashtags: hashtags,
                hashtagsAdditional: hashtagsAdditional,
                mentions: mentions,
                reactions: reactions,
                urlProps: urlProps,
                fileProps: fileProps,
                systemProps: systemProps,
                props: props,
                tmpPostId: tmpPostId,
                state: state,
                dedupeKey: dedupeKey,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> postId = const Value.absent(),
                required int channelId,
                Value<int> creatorId = const Value.absent(),
                Value<int> threadId = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> message = const Value.absent(),
                Value<int> createAt = const Value.absent(),
                Value<int> updateAt = const Value.absent(),
                Value<int> deleteAt = const Value.absent(),
                Value<int> lastCommentAt = const Value.absent(),
                Value<int> lastPinAt = const Value.absent(),
                Value<int> commentCount = const Value.absent(),
                Value<bool> isStar = const Value.absent(),
                Value<bool> isSticky = const Value.absent(),
                Value<bool> encrypted = const Value.absent(),
                Value<bool> safeUrl = const Value.absent(),
                Value<bool> staticUrl = const Value.absent(),
                Value<String> forwardType = const Value.absent(),
                Value<String> hashtags = const Value.absent(),
                Value<String> hashtagsAdditional = const Value.absent(),
                Value<String> mentions = const Value.absent(),
                Value<String> reactions = const Value.absent(),
                Value<String> urlProps = const Value.absent(),
                Value<String> fileProps = const Value.absent(),
                Value<String> systemProps = const Value.absent(),
                Value<String> props = const Value.absent(),
                Value<int> tmpPostId = const Value.absent(),
                Value<int> state = const Value.absent(),
                required String dedupeKey,
              }) => PostRowsCompanion.insert(
                id: id,
                postId: postId,
                channelId: channelId,
                creatorId: creatorId,
                threadId: threadId,
                type: type,
                message: message,
                createAt: createAt,
                updateAt: updateAt,
                deleteAt: deleteAt,
                lastCommentAt: lastCommentAt,
                lastPinAt: lastPinAt,
                commentCount: commentCount,
                isStar: isStar,
                isSticky: isSticky,
                encrypted: encrypted,
                safeUrl: safeUrl,
                staticUrl: staticUrl,
                forwardType: forwardType,
                hashtags: hashtags,
                hashtagsAdditional: hashtagsAdditional,
                mentions: mentions,
                reactions: reactions,
                urlProps: urlProps,
                fileProps: fileProps,
                systemProps: systemProps,
                props: props,
                tmpPostId: tmpPostId,
                state: state,
                dedupeKey: dedupeKey,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PostRowsTable, PostRow>(table),
                  BaseReferences<_$ChatDatabase, $PostRowsTable, PostRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PostRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $PostRowsTable,
      PostRow,
      $$PostRowsTableFilterComposer,
      $$PostRowsTableOrderingComposer,
      $$PostRowsTableAnnotationComposer,
      $$PostRowsTableCreateCompanionBuilder,
      $$PostRowsTableUpdateCompanionBuilder,
      (PostRow, BaseReferences<_$ChatDatabase, $PostRowsTable, PostRow>),
      PostRow,
      PrefetchHooks Function()
    >;
typedef $$KeyValueRowsTableCreateCompanionBuilder =
    KeyValueRowsCompanion Function({
      required String key,
      Value<String> value,
      Value<int> rowid,
    });
typedef $$KeyValueRowsTableUpdateCompanionBuilder =
    KeyValueRowsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$KeyValueRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $KeyValueRowsTable> {
  $$KeyValueRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KeyValueRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $KeyValueRowsTable> {
  $$KeyValueRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KeyValueRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $KeyValueRowsTable> {
  $$KeyValueRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$KeyValueRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $KeyValueRowsTable,
          KeyValueRow,
          $$KeyValueRowsTableFilterComposer,
          $$KeyValueRowsTableOrderingComposer,
          $$KeyValueRowsTableAnnotationComposer,
          $$KeyValueRowsTableCreateCompanionBuilder,
          $$KeyValueRowsTableUpdateCompanionBuilder,
          (
            KeyValueRow,
            BaseReferences<_$ChatDatabase, $KeyValueRowsTable, KeyValueRow>,
          ),
          KeyValueRow,
          PrefetchHooks Function()
        > {
  $$KeyValueRowsTableTableManager(_$ChatDatabase db, $KeyValueRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KeyValueRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KeyValueRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KeyValueRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KeyValueRowsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KeyValueRowsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KeyValueRowsTable, KeyValueRow>(table),
                  BaseReferences<
                    _$ChatDatabase,
                    $KeyValueRowsTable,
                    KeyValueRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KeyValueRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $KeyValueRowsTable,
      KeyValueRow,
      $$KeyValueRowsTableFilterComposer,
      $$KeyValueRowsTableOrderingComposer,
      $$KeyValueRowsTableAnnotationComposer,
      $$KeyValueRowsTableCreateCompanionBuilder,
      $$KeyValueRowsTableUpdateCompanionBuilder,
      (
        KeyValueRow,
        BaseReferences<_$ChatDatabase, $KeyValueRowsTable, KeyValueRow>,
      ),
      KeyValueRow,
      PrefetchHooks Function()
    >;
typedef $$FileEntryRowsTableCreateCompanionBuilder =
    FileEntryRowsCompanion Function({
      required String path,
      Value<String> parentPath,
      Value<String> name,
      Value<bool> isDir,
      Value<int> size,
      Value<int> mtime,
      Value<int> crtime,
      Value<String> owner,
      Value<String> group,
      Value<String> realPath,
      Value<String> mountPointType,
      Value<String> description,
      Value<bool> canRead,
      Value<bool> canWrite,
      Value<bool> canExecute,
      Value<bool> disableDownload,
      Value<bool> isWormShare,
      Value<String> wormState,
      Value<int> cachedAt,
      Value<int> rowid,
    });
typedef $$FileEntryRowsTableUpdateCompanionBuilder =
    FileEntryRowsCompanion Function({
      Value<String> path,
      Value<String> parentPath,
      Value<String> name,
      Value<bool> isDir,
      Value<int> size,
      Value<int> mtime,
      Value<int> crtime,
      Value<String> owner,
      Value<String> group,
      Value<String> realPath,
      Value<String> mountPointType,
      Value<String> description,
      Value<bool> canRead,
      Value<bool> canWrite,
      Value<bool> canExecute,
      Value<bool> disableDownload,
      Value<bool> isWormShare,
      Value<String> wormState,
      Value<int> cachedAt,
      Value<int> rowid,
    });

class $$FileEntryRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $FileEntryRowsTable> {
  $$FileEntryRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentPath => $composableBuilder(
    column: $table.parentPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDir => $composableBuilder(
    column: $table.isDir,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mtime => $composableBuilder(
    column: $table.mtime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get crtime => $composableBuilder(
    column: $table.crtime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get owner => $composableBuilder(
    column: $table.owner,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get group => $composableBuilder(
    column: $table.group,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get realPath => $composableBuilder(
    column: $table.realPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mountPointType => $composableBuilder(
    column: $table.mountPointType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get canRead => $composableBuilder(
    column: $table.canRead,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get canWrite => $composableBuilder(
    column: $table.canWrite,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get canExecute => $composableBuilder(
    column: $table.canExecute,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get disableDownload => $composableBuilder(
    column: $table.disableDownload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isWormShare => $composableBuilder(
    column: $table.isWormShare,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get wormState => $composableBuilder(
    column: $table.wormState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FileEntryRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $FileEntryRowsTable> {
  $$FileEntryRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentPath => $composableBuilder(
    column: $table.parentPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDir => $composableBuilder(
    column: $table.isDir,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mtime => $composableBuilder(
    column: $table.mtime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get crtime => $composableBuilder(
    column: $table.crtime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get owner => $composableBuilder(
    column: $table.owner,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get group => $composableBuilder(
    column: $table.group,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get realPath => $composableBuilder(
    column: $table.realPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mountPointType => $composableBuilder(
    column: $table.mountPointType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get canRead => $composableBuilder(
    column: $table.canRead,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get canWrite => $composableBuilder(
    column: $table.canWrite,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get canExecute => $composableBuilder(
    column: $table.canExecute,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get disableDownload => $composableBuilder(
    column: $table.disableDownload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isWormShare => $composableBuilder(
    column: $table.isWormShare,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get wormState => $composableBuilder(
    column: $table.wormState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FileEntryRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $FileEntryRowsTable> {
  $$FileEntryRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get parentPath => $composableBuilder(
    column: $table.parentPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<bool> get isDir =>
      $composableBuilder(column: $table.isDir, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<int> get mtime =>
      $composableBuilder(column: $table.mtime, builder: (column) => column);

  GeneratedColumn<int> get crtime =>
      $composableBuilder(column: $table.crtime, builder: (column) => column);

  GeneratedColumn<String> get owner =>
      $composableBuilder(column: $table.owner, builder: (column) => column);

  GeneratedColumn<String> get group =>
      $composableBuilder(column: $table.group, builder: (column) => column);

  GeneratedColumn<String> get realPath =>
      $composableBuilder(column: $table.realPath, builder: (column) => column);

  GeneratedColumn<String> get mountPointType => $composableBuilder(
    column: $table.mountPointType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get canRead =>
      $composableBuilder(column: $table.canRead, builder: (column) => column);

  GeneratedColumn<bool> get canWrite =>
      $composableBuilder(column: $table.canWrite, builder: (column) => column);

  GeneratedColumn<bool> get canExecute => $composableBuilder(
    column: $table.canExecute,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get disableDownload => $composableBuilder(
    column: $table.disableDownload,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isWormShare => $composableBuilder(
    column: $table.isWormShare,
    builder: (column) => column,
  );

  GeneratedColumn<String> get wormState =>
      $composableBuilder(column: $table.wormState, builder: (column) => column);

  GeneratedColumn<int> get cachedAt =>
      $composableBuilder(column: $table.cachedAt, builder: (column) => column);
}

class $$FileEntryRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $FileEntryRowsTable,
          FileEntryRow,
          $$FileEntryRowsTableFilterComposer,
          $$FileEntryRowsTableOrderingComposer,
          $$FileEntryRowsTableAnnotationComposer,
          $$FileEntryRowsTableCreateCompanionBuilder,
          $$FileEntryRowsTableUpdateCompanionBuilder,
          (
            FileEntryRow,
            BaseReferences<_$ChatDatabase, $FileEntryRowsTable, FileEntryRow>,
          ),
          FileEntryRow,
          PrefetchHooks Function()
        > {
  $$FileEntryRowsTableTableManager(_$ChatDatabase db, $FileEntryRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FileEntryRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FileEntryRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FileEntryRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> path = const Value.absent(),
                Value<String> parentPath = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<bool> isDir = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<int> mtime = const Value.absent(),
                Value<int> crtime = const Value.absent(),
                Value<String> owner = const Value.absent(),
                Value<String> group = const Value.absent(),
                Value<String> realPath = const Value.absent(),
                Value<String> mountPointType = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<bool> canRead = const Value.absent(),
                Value<bool> canWrite = const Value.absent(),
                Value<bool> canExecute = const Value.absent(),
                Value<bool> disableDownload = const Value.absent(),
                Value<bool> isWormShare = const Value.absent(),
                Value<String> wormState = const Value.absent(),
                Value<int> cachedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FileEntryRowsCompanion(
                path: path,
                parentPath: parentPath,
                name: name,
                isDir: isDir,
                size: size,
                mtime: mtime,
                crtime: crtime,
                owner: owner,
                group: group,
                realPath: realPath,
                mountPointType: mountPointType,
                description: description,
                canRead: canRead,
                canWrite: canWrite,
                canExecute: canExecute,
                disableDownload: disableDownload,
                isWormShare: isWormShare,
                wormState: wormState,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String path,
                Value<String> parentPath = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<bool> isDir = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<int> mtime = const Value.absent(),
                Value<int> crtime = const Value.absent(),
                Value<String> owner = const Value.absent(),
                Value<String> group = const Value.absent(),
                Value<String> realPath = const Value.absent(),
                Value<String> mountPointType = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<bool> canRead = const Value.absent(),
                Value<bool> canWrite = const Value.absent(),
                Value<bool> canExecute = const Value.absent(),
                Value<bool> disableDownload = const Value.absent(),
                Value<bool> isWormShare = const Value.absent(),
                Value<String> wormState = const Value.absent(),
                Value<int> cachedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FileEntryRowsCompanion.insert(
                path: path,
                parentPath: parentPath,
                name: name,
                isDir: isDir,
                size: size,
                mtime: mtime,
                crtime: crtime,
                owner: owner,
                group: group,
                realPath: realPath,
                mountPointType: mountPointType,
                description: description,
                canRead: canRead,
                canWrite: canWrite,
                canExecute: canExecute,
                disableDownload: disableDownload,
                isWormShare: isWormShare,
                wormState: wormState,
                cachedAt: cachedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$FileEntryRowsTable, FileEntryRow>(table),
                  BaseReferences<
                    _$ChatDatabase,
                    $FileEntryRowsTable,
                    FileEntryRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FileEntryRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $FileEntryRowsTable,
      FileEntryRow,
      $$FileEntryRowsTableFilterComposer,
      $$FileEntryRowsTableOrderingComposer,
      $$FileEntryRowsTableAnnotationComposer,
      $$FileEntryRowsTableCreateCompanionBuilder,
      $$FileEntryRowsTableUpdateCompanionBuilder,
      (
        FileEntryRow,
        BaseReferences<_$ChatDatabase, $FileEntryRowsTable, FileEntryRow>,
      ),
      FileEntryRow,
      PrefetchHooks Function()
    >;
typedef $$NoteCacheRowsTableCreateCompanionBuilder =
    NoteCacheRowsCompanion Function({
      Value<String> accountKey,
      required String objectId,
      Value<String> notebookId,
      Value<String> title,
      Value<String> brief,
      Value<String> content,
      Value<bool> hasContent,
      Value<String> tagsJson,
      Value<String> attachmentsJson,
      Value<bool> encrypt,
      Value<bool> recycle,
      Value<String> ver,
      Value<int> ctime,
      Value<int> mtime,
      Value<String> ownerName,
      Value<bool> dirty,
      Value<int> syncedAt,
      Value<int> rowid,
    });
typedef $$NoteCacheRowsTableUpdateCompanionBuilder =
    NoteCacheRowsCompanion Function({
      Value<String> accountKey,
      Value<String> objectId,
      Value<String> notebookId,
      Value<String> title,
      Value<String> brief,
      Value<String> content,
      Value<bool> hasContent,
      Value<String> tagsJson,
      Value<String> attachmentsJson,
      Value<bool> encrypt,
      Value<bool> recycle,
      Value<String> ver,
      Value<int> ctime,
      Value<int> mtime,
      Value<String> ownerName,
      Value<bool> dirty,
      Value<int> syncedAt,
      Value<int> rowid,
    });

class $$NoteCacheRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $NoteCacheRowsTable> {
  $$NoteCacheRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get brief => $composableBuilder(
    column: $table.brief,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasContent => $composableBuilder(
    column: $table.hasContent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attachmentsJson => $composableBuilder(
    column: $table.attachmentsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get encrypt => $composableBuilder(
    column: $table.encrypt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get recycle => $composableBuilder(
    column: $table.recycle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ver => $composableBuilder(
    column: $table.ver,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ctime => $composableBuilder(
    column: $table.ctime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mtime => $composableBuilder(
    column: $table.mtime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerName => $composableBuilder(
    column: $table.ownerName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NoteCacheRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $NoteCacheRowsTable> {
  $$NoteCacheRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get brief => $composableBuilder(
    column: $table.brief,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasContent => $composableBuilder(
    column: $table.hasContent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attachmentsJson => $composableBuilder(
    column: $table.attachmentsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get encrypt => $composableBuilder(
    column: $table.encrypt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get recycle => $composableBuilder(
    column: $table.recycle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ver => $composableBuilder(
    column: $table.ver,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ctime => $composableBuilder(
    column: $table.ctime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mtime => $composableBuilder(
    column: $table.mtime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerName => $composableBuilder(
    column: $table.ownerName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NoteCacheRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $NoteCacheRowsTable> {
  $$NoteCacheRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get objectId =>
      $composableBuilder(column: $table.objectId, builder: (column) => column);

  GeneratedColumn<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get brief =>
      $composableBuilder(column: $table.brief, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<bool> get hasContent => $composableBuilder(
    column: $table.hasContent,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);

  GeneratedColumn<String> get attachmentsJson => $composableBuilder(
    column: $table.attachmentsJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get encrypt =>
      $composableBuilder(column: $table.encrypt, builder: (column) => column);

  GeneratedColumn<bool> get recycle =>
      $composableBuilder(column: $table.recycle, builder: (column) => column);

  GeneratedColumn<String> get ver =>
      $composableBuilder(column: $table.ver, builder: (column) => column);

  GeneratedColumn<int> get ctime =>
      $composableBuilder(column: $table.ctime, builder: (column) => column);

  GeneratedColumn<int> get mtime =>
      $composableBuilder(column: $table.mtime, builder: (column) => column);

  GeneratedColumn<String> get ownerName =>
      $composableBuilder(column: $table.ownerName, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<int> get syncedAt =>
      $composableBuilder(column: $table.syncedAt, builder: (column) => column);
}

class $$NoteCacheRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $NoteCacheRowsTable,
          NoteCacheRow,
          $$NoteCacheRowsTableFilterComposer,
          $$NoteCacheRowsTableOrderingComposer,
          $$NoteCacheRowsTableAnnotationComposer,
          $$NoteCacheRowsTableCreateCompanionBuilder,
          $$NoteCacheRowsTableUpdateCompanionBuilder,
          (
            NoteCacheRow,
            BaseReferences<_$ChatDatabase, $NoteCacheRowsTable, NoteCacheRow>,
          ),
          NoteCacheRow,
          PrefetchHooks Function()
        > {
  $$NoteCacheRowsTableTableManager(_$ChatDatabase db, $NoteCacheRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NoteCacheRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NoteCacheRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NoteCacheRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountKey = const Value.absent(),
                Value<String> objectId = const Value.absent(),
                Value<String> notebookId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> brief = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<bool> hasContent = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<String> attachmentsJson = const Value.absent(),
                Value<bool> encrypt = const Value.absent(),
                Value<bool> recycle = const Value.absent(),
                Value<String> ver = const Value.absent(),
                Value<int> ctime = const Value.absent(),
                Value<int> mtime = const Value.absent(),
                Value<String> ownerName = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<int> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NoteCacheRowsCompanion(
                accountKey: accountKey,
                objectId: objectId,
                notebookId: notebookId,
                title: title,
                brief: brief,
                content: content,
                hasContent: hasContent,
                tagsJson: tagsJson,
                attachmentsJson: attachmentsJson,
                encrypt: encrypt,
                recycle: recycle,
                ver: ver,
                ctime: ctime,
                mtime: mtime,
                ownerName: ownerName,
                dirty: dirty,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> accountKey = const Value.absent(),
                required String objectId,
                Value<String> notebookId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> brief = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<bool> hasContent = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<String> attachmentsJson = const Value.absent(),
                Value<bool> encrypt = const Value.absent(),
                Value<bool> recycle = const Value.absent(),
                Value<String> ver = const Value.absent(),
                Value<int> ctime = const Value.absent(),
                Value<int> mtime = const Value.absent(),
                Value<String> ownerName = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<int> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NoteCacheRowsCompanion.insert(
                accountKey: accountKey,
                objectId: objectId,
                notebookId: notebookId,
                title: title,
                brief: brief,
                content: content,
                hasContent: hasContent,
                tagsJson: tagsJson,
                attachmentsJson: attachmentsJson,
                encrypt: encrypt,
                recycle: recycle,
                ver: ver,
                ctime: ctime,
                mtime: mtime,
                ownerName: ownerName,
                dirty: dirty,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$NoteCacheRowsTable, NoteCacheRow>(table),
                  BaseReferences<
                    _$ChatDatabase,
                    $NoteCacheRowsTable,
                    NoteCacheRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NoteCacheRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $NoteCacheRowsTable,
      NoteCacheRow,
      $$NoteCacheRowsTableFilterComposer,
      $$NoteCacheRowsTableOrderingComposer,
      $$NoteCacheRowsTableAnnotationComposer,
      $$NoteCacheRowsTableCreateCompanionBuilder,
      $$NoteCacheRowsTableUpdateCompanionBuilder,
      (
        NoteCacheRow,
        BaseReferences<_$ChatDatabase, $NoteCacheRowsTable, NoteCacheRow>,
      ),
      NoteCacheRow,
      PrefetchHooks Function()
    >;
typedef $$NotebookCacheRowsTableCreateCompanionBuilder =
    NotebookCacheRowsCompanion Function({
      Value<String> accountKey,
      required String objectId,
      Value<String> title,
      Value<bool> preset,
      Value<bool> archive,
      Value<String> ver,
      Value<int> mtime,
      Value<int> syncedAt,
      Value<int> rowid,
    });
typedef $$NotebookCacheRowsTableUpdateCompanionBuilder =
    NotebookCacheRowsCompanion Function({
      Value<String> accountKey,
      Value<String> objectId,
      Value<String> title,
      Value<bool> preset,
      Value<bool> archive,
      Value<String> ver,
      Value<int> mtime,
      Value<int> syncedAt,
      Value<int> rowid,
    });

class $$NotebookCacheRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $NotebookCacheRowsTable> {
  $$NotebookCacheRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get preset => $composableBuilder(
    column: $table.preset,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get archive => $composableBuilder(
    column: $table.archive,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ver => $composableBuilder(
    column: $table.ver,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mtime => $composableBuilder(
    column: $table.mtime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NotebookCacheRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $NotebookCacheRowsTable> {
  $$NotebookCacheRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get preset => $composableBuilder(
    column: $table.preset,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get archive => $composableBuilder(
    column: $table.archive,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ver => $composableBuilder(
    column: $table.ver,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mtime => $composableBuilder(
    column: $table.mtime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotebookCacheRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $NotebookCacheRowsTable> {
  $$NotebookCacheRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get objectId =>
      $composableBuilder(column: $table.objectId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<bool> get preset =>
      $composableBuilder(column: $table.preset, builder: (column) => column);

  GeneratedColumn<bool> get archive =>
      $composableBuilder(column: $table.archive, builder: (column) => column);

  GeneratedColumn<String> get ver =>
      $composableBuilder(column: $table.ver, builder: (column) => column);

  GeneratedColumn<int> get mtime =>
      $composableBuilder(column: $table.mtime, builder: (column) => column);

  GeneratedColumn<int> get syncedAt =>
      $composableBuilder(column: $table.syncedAt, builder: (column) => column);
}

class $$NotebookCacheRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $NotebookCacheRowsTable,
          NotebookCacheRow,
          $$NotebookCacheRowsTableFilterComposer,
          $$NotebookCacheRowsTableOrderingComposer,
          $$NotebookCacheRowsTableAnnotationComposer,
          $$NotebookCacheRowsTableCreateCompanionBuilder,
          $$NotebookCacheRowsTableUpdateCompanionBuilder,
          (
            NotebookCacheRow,
            BaseReferences<
              _$ChatDatabase,
              $NotebookCacheRowsTable,
              NotebookCacheRow
            >,
          ),
          NotebookCacheRow,
          PrefetchHooks Function()
        > {
  $$NotebookCacheRowsTableTableManager(
    _$ChatDatabase db,
    $NotebookCacheRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotebookCacheRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotebookCacheRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NotebookCacheRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> accountKey = const Value.absent(),
                Value<String> objectId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<bool> preset = const Value.absent(),
                Value<bool> archive = const Value.absent(),
                Value<String> ver = const Value.absent(),
                Value<int> mtime = const Value.absent(),
                Value<int> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotebookCacheRowsCompanion(
                accountKey: accountKey,
                objectId: objectId,
                title: title,
                preset: preset,
                archive: archive,
                ver: ver,
                mtime: mtime,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> accountKey = const Value.absent(),
                required String objectId,
                Value<String> title = const Value.absent(),
                Value<bool> preset = const Value.absent(),
                Value<bool> archive = const Value.absent(),
                Value<String> ver = const Value.absent(),
                Value<int> mtime = const Value.absent(),
                Value<int> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotebookCacheRowsCompanion.insert(
                accountKey: accountKey,
                objectId: objectId,
                title: title,
                preset: preset,
                archive: archive,
                ver: ver,
                mtime: mtime,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$NotebookCacheRowsTable, NotebookCacheRow>(table),
                  BaseReferences<
                    _$ChatDatabase,
                    $NotebookCacheRowsTable,
                    NotebookCacheRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotebookCacheRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $NotebookCacheRowsTable,
      NotebookCacheRow,
      $$NotebookCacheRowsTableFilterComposer,
      $$NotebookCacheRowsTableOrderingComposer,
      $$NotebookCacheRowsTableAnnotationComposer,
      $$NotebookCacheRowsTableCreateCompanionBuilder,
      $$NotebookCacheRowsTableUpdateCompanionBuilder,
      (
        NotebookCacheRow,
        BaseReferences<
          _$ChatDatabase,
          $NotebookCacheRowsTable,
          NotebookCacheRow
        >,
      ),
      NotebookCacheRow,
      PrefetchHooks Function()
    >;
typedef $$TodoCacheRowsTableCreateCompanionBuilder =
    TodoCacheRowsCompanion Function({
      Value<String> accountKey,
      required String objectId,
      Value<String> title,
      Value<String> comment,
      Value<bool> done,
      Value<bool> star,
      Value<int> priority,
      Value<int> dueDate,
      Value<int> reminderOffset,
      Value<String> noteId,
      Value<String> parentId,
      Value<bool> dirty,
      Value<int> syncedAt,
      Value<int> rowid,
    });
typedef $$TodoCacheRowsTableUpdateCompanionBuilder =
    TodoCacheRowsCompanion Function({
      Value<String> accountKey,
      Value<String> objectId,
      Value<String> title,
      Value<String> comment,
      Value<bool> done,
      Value<bool> star,
      Value<int> priority,
      Value<int> dueDate,
      Value<int> reminderOffset,
      Value<String> noteId,
      Value<String> parentId,
      Value<bool> dirty,
      Value<int> syncedAt,
      Value<int> rowid,
    });

class $$TodoCacheRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $TodoCacheRowsTable> {
  $$TodoCacheRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get comment => $composableBuilder(
    column: $table.comment,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get done => $composableBuilder(
    column: $table.done,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get star => $composableBuilder(
    column: $table.star,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dueDate => $composableBuilder(
    column: $table.dueDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reminderOffset => $composableBuilder(
    column: $table.reminderOffset,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get noteId => $composableBuilder(
    column: $table.noteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TodoCacheRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $TodoCacheRowsTable> {
  $$TodoCacheRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get comment => $composableBuilder(
    column: $table.comment,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get done => $composableBuilder(
    column: $table.done,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get star => $composableBuilder(
    column: $table.star,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dueDate => $composableBuilder(
    column: $table.dueDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reminderOffset => $composableBuilder(
    column: $table.reminderOffset,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get noteId => $composableBuilder(
    column: $table.noteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TodoCacheRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $TodoCacheRowsTable> {
  $$TodoCacheRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get objectId =>
      $composableBuilder(column: $table.objectId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get comment =>
      $composableBuilder(column: $table.comment, builder: (column) => column);

  GeneratedColumn<bool> get done =>
      $composableBuilder(column: $table.done, builder: (column) => column);

  GeneratedColumn<bool> get star =>
      $composableBuilder(column: $table.star, builder: (column) => column);

  GeneratedColumn<int> get priority =>
      $composableBuilder(column: $table.priority, builder: (column) => column);

  GeneratedColumn<int> get dueDate =>
      $composableBuilder(column: $table.dueDate, builder: (column) => column);

  GeneratedColumn<int> get reminderOffset => $composableBuilder(
    column: $table.reminderOffset,
    builder: (column) => column,
  );

  GeneratedColumn<String> get noteId =>
      $composableBuilder(column: $table.noteId, builder: (column) => column);

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  GeneratedColumn<int> get syncedAt =>
      $composableBuilder(column: $table.syncedAt, builder: (column) => column);
}

class $$TodoCacheRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $TodoCacheRowsTable,
          TodoCacheRow,
          $$TodoCacheRowsTableFilterComposer,
          $$TodoCacheRowsTableOrderingComposer,
          $$TodoCacheRowsTableAnnotationComposer,
          $$TodoCacheRowsTableCreateCompanionBuilder,
          $$TodoCacheRowsTableUpdateCompanionBuilder,
          (
            TodoCacheRow,
            BaseReferences<_$ChatDatabase, $TodoCacheRowsTable, TodoCacheRow>,
          ),
          TodoCacheRow,
          PrefetchHooks Function()
        > {
  $$TodoCacheRowsTableTableManager(_$ChatDatabase db, $TodoCacheRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TodoCacheRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TodoCacheRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TodoCacheRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> accountKey = const Value.absent(),
                Value<String> objectId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> comment = const Value.absent(),
                Value<bool> done = const Value.absent(),
                Value<bool> star = const Value.absent(),
                Value<int> priority = const Value.absent(),
                Value<int> dueDate = const Value.absent(),
                Value<int> reminderOffset = const Value.absent(),
                Value<String> noteId = const Value.absent(),
                Value<String> parentId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<int> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TodoCacheRowsCompanion(
                accountKey: accountKey,
                objectId: objectId,
                title: title,
                comment: comment,
                done: done,
                star: star,
                priority: priority,
                dueDate: dueDate,
                reminderOffset: reminderOffset,
                noteId: noteId,
                parentId: parentId,
                dirty: dirty,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> accountKey = const Value.absent(),
                required String objectId,
                Value<String> title = const Value.absent(),
                Value<String> comment = const Value.absent(),
                Value<bool> done = const Value.absent(),
                Value<bool> star = const Value.absent(),
                Value<int> priority = const Value.absent(),
                Value<int> dueDate = const Value.absent(),
                Value<int> reminderOffset = const Value.absent(),
                Value<String> noteId = const Value.absent(),
                Value<String> parentId = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<int> syncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TodoCacheRowsCompanion.insert(
                accountKey: accountKey,
                objectId: objectId,
                title: title,
                comment: comment,
                done: done,
                star: star,
                priority: priority,
                dueDate: dueDate,
                reminderOffset: reminderOffset,
                noteId: noteId,
                parentId: parentId,
                dirty: dirty,
                syncedAt: syncedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TodoCacheRowsTable, TodoCacheRow>(table),
                  BaseReferences<
                    _$ChatDatabase,
                    $TodoCacheRowsTable,
                    TodoCacheRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TodoCacheRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $TodoCacheRowsTable,
      TodoCacheRow,
      $$TodoCacheRowsTableFilterComposer,
      $$TodoCacheRowsTableOrderingComposer,
      $$TodoCacheRowsTableAnnotationComposer,
      $$TodoCacheRowsTableCreateCompanionBuilder,
      $$TodoCacheRowsTableUpdateCompanionBuilder,
      (
        TodoCacheRow,
        BaseReferences<_$ChatDatabase, $TodoCacheRowsTable, TodoCacheRow>,
      ),
      TodoCacheRow,
      PrefetchHooks Function()
    >;
typedef $$NotePendingRowsTableCreateCompanionBuilder =
    NotePendingRowsCompanion Function({
      Value<int> id,
      Value<String> accountKey,
      required String kind,
      Value<String> objectId,
      Value<String> payloadJson,
      Value<int> createdAt,
    });
typedef $$NotePendingRowsTableUpdateCompanionBuilder =
    NotePendingRowsCompanion Function({
      Value<int> id,
      Value<String> accountKey,
      Value<String> kind,
      Value<String> objectId,
      Value<String> payloadJson,
      Value<int> createdAt,
    });

class $$NotePendingRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $NotePendingRowsTable> {
  $$NotePendingRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NotePendingRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $NotePendingRowsTable> {
  $$NotePendingRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotePendingRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $NotePendingRowsTable> {
  $$NotePendingRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get accountKey => $composableBuilder(
    column: $table.accountKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get objectId =>
      $composableBuilder(column: $table.objectId, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$NotePendingRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $NotePendingRowsTable,
          NotePendingRow,
          $$NotePendingRowsTableFilterComposer,
          $$NotePendingRowsTableOrderingComposer,
          $$NotePendingRowsTableAnnotationComposer,
          $$NotePendingRowsTableCreateCompanionBuilder,
          $$NotePendingRowsTableUpdateCompanionBuilder,
          (
            NotePendingRow,
            BaseReferences<
              _$ChatDatabase,
              $NotePendingRowsTable,
              NotePendingRow
            >,
          ),
          NotePendingRow,
          PrefetchHooks Function()
        > {
  $$NotePendingRowsTableTableManager(
    _$ChatDatabase db,
    $NotePendingRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotePendingRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotePendingRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NotePendingRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> accountKey = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> objectId = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
              }) => NotePendingRowsCompanion(
                id: id,
                accountKey: accountKey,
                kind: kind,
                objectId: objectId,
                payloadJson: payloadJson,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> accountKey = const Value.absent(),
                required String kind,
                Value<String> objectId = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
              }) => NotePendingRowsCompanion.insert(
                id: id,
                accountKey: accountKey,
                kind: kind,
                objectId: objectId,
                payloadJson: payloadJson,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$NotePendingRowsTable, NotePendingRow>(table),
                  BaseReferences<
                    _$ChatDatabase,
                    $NotePendingRowsTable,
                    NotePendingRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotePendingRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $NotePendingRowsTable,
      NotePendingRow,
      $$NotePendingRowsTableFilterComposer,
      $$NotePendingRowsTableOrderingComposer,
      $$NotePendingRowsTableAnnotationComposer,
      $$NotePendingRowsTableCreateCompanionBuilder,
      $$NotePendingRowsTableUpdateCompanionBuilder,
      (
        NotePendingRow,
        BaseReferences<_$ChatDatabase, $NotePendingRowsTable, NotePendingRow>,
      ),
      NotePendingRow,
      PrefetchHooks Function()
    >;
typedef $$BookProgressRowsTableCreateCompanionBuilder =
    BookProgressRowsCompanion Function({
      required String bookKey,
      Value<String> title,
      Value<String> format,
      Value<int> chapter,
      Value<double> scroll,
      Value<int> chapterCount,
      Value<int> updatedAt,
      Value<String> sourceUrl,
      Value<int> rowid,
    });
typedef $$BookProgressRowsTableUpdateCompanionBuilder =
    BookProgressRowsCompanion Function({
      Value<String> bookKey,
      Value<String> title,
      Value<String> format,
      Value<int> chapter,
      Value<double> scroll,
      Value<int> chapterCount,
      Value<int> updatedAt,
      Value<String> sourceUrl,
      Value<int> rowid,
    });

class $$BookProgressRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $BookProgressRowsTable> {
  $$BookProgressRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookKey => $composableBuilder(
    column: $table.bookKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chapter => $composableBuilder(
    column: $table.chapter,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get scroll => $composableBuilder(
    column: $table.scroll,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chapterCount => $composableBuilder(
    column: $table.chapterCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceUrl => $composableBuilder(
    column: $table.sourceUrl,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BookProgressRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $BookProgressRowsTable> {
  $$BookProgressRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get bookKey => $composableBuilder(
    column: $table.bookKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chapter => $composableBuilder(
    column: $table.chapter,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get scroll => $composableBuilder(
    column: $table.scroll,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chapterCount => $composableBuilder(
    column: $table.chapterCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceUrl => $composableBuilder(
    column: $table.sourceUrl,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BookProgressRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $BookProgressRowsTable> {
  $$BookProgressRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get bookKey =>
      $composableBuilder(column: $table.bookKey, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get format =>
      $composableBuilder(column: $table.format, builder: (column) => column);

  GeneratedColumn<int> get chapter =>
      $composableBuilder(column: $table.chapter, builder: (column) => column);

  GeneratedColumn<double> get scroll =>
      $composableBuilder(column: $table.scroll, builder: (column) => column);

  GeneratedColumn<int> get chapterCount => $composableBuilder(
    column: $table.chapterCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get sourceUrl =>
      $composableBuilder(column: $table.sourceUrl, builder: (column) => column);
}

class $$BookProgressRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $BookProgressRowsTable,
          BookProgressRow,
          $$BookProgressRowsTableFilterComposer,
          $$BookProgressRowsTableOrderingComposer,
          $$BookProgressRowsTableAnnotationComposer,
          $$BookProgressRowsTableCreateCompanionBuilder,
          $$BookProgressRowsTableUpdateCompanionBuilder,
          (
            BookProgressRow,
            BaseReferences<
              _$ChatDatabase,
              $BookProgressRowsTable,
              BookProgressRow
            >,
          ),
          BookProgressRow,
          PrefetchHooks Function()
        > {
  $$BookProgressRowsTableTableManager(
    _$ChatDatabase db,
    $BookProgressRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookProgressRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookProgressRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookProgressRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookKey = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> format = const Value.absent(),
                Value<int> chapter = const Value.absent(),
                Value<double> scroll = const Value.absent(),
                Value<int> chapterCount = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<String> sourceUrl = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BookProgressRowsCompanion(
                bookKey: bookKey,
                title: title,
                format: format,
                chapter: chapter,
                scroll: scroll,
                chapterCount: chapterCount,
                updatedAt: updatedAt,
                sourceUrl: sourceUrl,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookKey,
                Value<String> title = const Value.absent(),
                Value<String> format = const Value.absent(),
                Value<int> chapter = const Value.absent(),
                Value<double> scroll = const Value.absent(),
                Value<int> chapterCount = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<String> sourceUrl = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BookProgressRowsCompanion.insert(
                bookKey: bookKey,
                title: title,
                format: format,
                chapter: chapter,
                scroll: scroll,
                chapterCount: chapterCount,
                updatedAt: updatedAt,
                sourceUrl: sourceUrl,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BookProgressRowsTable, BookProgressRow>(table),
                  BaseReferences<
                    _$ChatDatabase,
                    $BookProgressRowsTable,
                    BookProgressRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BookProgressRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $BookProgressRowsTable,
      BookProgressRow,
      $$BookProgressRowsTableFilterComposer,
      $$BookProgressRowsTableOrderingComposer,
      $$BookProgressRowsTableAnnotationComposer,
      $$BookProgressRowsTableCreateCompanionBuilder,
      $$BookProgressRowsTableUpdateCompanionBuilder,
      (
        BookProgressRow,
        BaseReferences<_$ChatDatabase, $BookProgressRowsTable, BookProgressRow>,
      ),
      BookProgressRow,
      PrefetchHooks Function()
    >;
typedef $$BookMarkRowsTableCreateCompanionBuilder =
    BookMarkRowsCompanion Function({
      Value<int> id,
      required String bookKey,
      Value<int> chapter,
      Value<double> scroll,
      Value<String> excerpt,
      Value<String> note,
      Value<int> createdAt,
    });
typedef $$BookMarkRowsTableUpdateCompanionBuilder =
    BookMarkRowsCompanion Function({
      Value<int> id,
      Value<String> bookKey,
      Value<int> chapter,
      Value<double> scroll,
      Value<String> excerpt,
      Value<String> note,
      Value<int> createdAt,
    });

class $$BookMarkRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $BookMarkRowsTable> {
  $$BookMarkRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bookKey => $composableBuilder(
    column: $table.bookKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chapter => $composableBuilder(
    column: $table.chapter,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get scroll => $composableBuilder(
    column: $table.scroll,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get excerpt => $composableBuilder(
    column: $table.excerpt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BookMarkRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $BookMarkRowsTable> {
  $$BookMarkRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bookKey => $composableBuilder(
    column: $table.bookKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chapter => $composableBuilder(
    column: $table.chapter,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get scroll => $composableBuilder(
    column: $table.scroll,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get excerpt => $composableBuilder(
    column: $table.excerpt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BookMarkRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $BookMarkRowsTable> {
  $$BookMarkRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get bookKey =>
      $composableBuilder(column: $table.bookKey, builder: (column) => column);

  GeneratedColumn<int> get chapter =>
      $composableBuilder(column: $table.chapter, builder: (column) => column);

  GeneratedColumn<double> get scroll =>
      $composableBuilder(column: $table.scroll, builder: (column) => column);

  GeneratedColumn<String> get excerpt =>
      $composableBuilder(column: $table.excerpt, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$BookMarkRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $BookMarkRowsTable,
          BookMarkRow,
          $$BookMarkRowsTableFilterComposer,
          $$BookMarkRowsTableOrderingComposer,
          $$BookMarkRowsTableAnnotationComposer,
          $$BookMarkRowsTableCreateCompanionBuilder,
          $$BookMarkRowsTableUpdateCompanionBuilder,
          (
            BookMarkRow,
            BaseReferences<_$ChatDatabase, $BookMarkRowsTable, BookMarkRow>,
          ),
          BookMarkRow,
          PrefetchHooks Function()
        > {
  $$BookMarkRowsTableTableManager(_$ChatDatabase db, $BookMarkRowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookMarkRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookMarkRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookMarkRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> bookKey = const Value.absent(),
                Value<int> chapter = const Value.absent(),
                Value<double> scroll = const Value.absent(),
                Value<String> excerpt = const Value.absent(),
                Value<String> note = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
              }) => BookMarkRowsCompanion(
                id: id,
                bookKey: bookKey,
                chapter: chapter,
                scroll: scroll,
                excerpt: excerpt,
                note: note,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String bookKey,
                Value<int> chapter = const Value.absent(),
                Value<double> scroll = const Value.absent(),
                Value<String> excerpt = const Value.absent(),
                Value<String> note = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
              }) => BookMarkRowsCompanion.insert(
                id: id,
                bookKey: bookKey,
                chapter: chapter,
                scroll: scroll,
                excerpt: excerpt,
                note: note,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BookMarkRowsTable, BookMarkRow>(table),
                  BaseReferences<
                    _$ChatDatabase,
                    $BookMarkRowsTable,
                    BookMarkRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BookMarkRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $BookMarkRowsTable,
      BookMarkRow,
      $$BookMarkRowsTableFilterComposer,
      $$BookMarkRowsTableOrderingComposer,
      $$BookMarkRowsTableAnnotationComposer,
      $$BookMarkRowsTableCreateCompanionBuilder,
      $$BookMarkRowsTableUpdateCompanionBuilder,
      (
        BookMarkRow,
        BaseReferences<_$ChatDatabase, $BookMarkRowsTable, BookMarkRow>,
      ),
      BookMarkRow,
      PrefetchHooks Function()
    >;
typedef $$PhotoBackupTargetRowsTableCreateCompanionBuilder =
    PhotoBackupTargetRowsCompanion Function({
      required String destination,
      Value<String> doneKeys,
      Value<int> lastFinishedAt,
      Value<String> targetRef,
      Value<String> targetName,
      Value<int> updatedAt,
      Value<int> rowid,
    });
typedef $$PhotoBackupTargetRowsTableUpdateCompanionBuilder =
    PhotoBackupTargetRowsCompanion Function({
      Value<String> destination,
      Value<String> doneKeys,
      Value<int> lastFinishedAt,
      Value<String> targetRef,
      Value<String> targetName,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$PhotoBackupTargetRowsTableFilterComposer
    extends Composer<_$ChatDatabase, $PhotoBackupTargetRowsTable> {
  $$PhotoBackupTargetRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get destination => $composableBuilder(
    column: $table.destination,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get doneKeys => $composableBuilder(
    column: $table.doneKeys,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastFinishedAt => $composableBuilder(
    column: $table.lastFinishedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetRef => $composableBuilder(
    column: $table.targetRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetName => $composableBuilder(
    column: $table.targetName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PhotoBackupTargetRowsTableOrderingComposer
    extends Composer<_$ChatDatabase, $PhotoBackupTargetRowsTable> {
  $$PhotoBackupTargetRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get destination => $composableBuilder(
    column: $table.destination,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get doneKeys => $composableBuilder(
    column: $table.doneKeys,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastFinishedAt => $composableBuilder(
    column: $table.lastFinishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetRef => $composableBuilder(
    column: $table.targetRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetName => $composableBuilder(
    column: $table.targetName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PhotoBackupTargetRowsTableAnnotationComposer
    extends Composer<_$ChatDatabase, $PhotoBackupTargetRowsTable> {
  $$PhotoBackupTargetRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get destination => $composableBuilder(
    column: $table.destination,
    builder: (column) => column,
  );

  GeneratedColumn<String> get doneKeys =>
      $composableBuilder(column: $table.doneKeys, builder: (column) => column);

  GeneratedColumn<int> get lastFinishedAt => $composableBuilder(
    column: $table.lastFinishedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get targetRef =>
      $composableBuilder(column: $table.targetRef, builder: (column) => column);

  GeneratedColumn<String> get targetName => $composableBuilder(
    column: $table.targetName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$PhotoBackupTargetRowsTableTableManager
    extends
        RootTableManager<
          _$ChatDatabase,
          $PhotoBackupTargetRowsTable,
          PhotoBackupTargetRow,
          $$PhotoBackupTargetRowsTableFilterComposer,
          $$PhotoBackupTargetRowsTableOrderingComposer,
          $$PhotoBackupTargetRowsTableAnnotationComposer,
          $$PhotoBackupTargetRowsTableCreateCompanionBuilder,
          $$PhotoBackupTargetRowsTableUpdateCompanionBuilder,
          (
            PhotoBackupTargetRow,
            BaseReferences<
              _$ChatDatabase,
              $PhotoBackupTargetRowsTable,
              PhotoBackupTargetRow
            >,
          ),
          PhotoBackupTargetRow,
          PrefetchHooks Function()
        > {
  $$PhotoBackupTargetRowsTableTableManager(
    _$ChatDatabase db,
    $PhotoBackupTargetRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PhotoBackupTargetRowsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$PhotoBackupTargetRowsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$PhotoBackupTargetRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> destination = const Value.absent(),
                Value<String> doneKeys = const Value.absent(),
                Value<int> lastFinishedAt = const Value.absent(),
                Value<String> targetRef = const Value.absent(),
                Value<String> targetName = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PhotoBackupTargetRowsCompanion(
                destination: destination,
                doneKeys: doneKeys,
                lastFinishedAt: lastFinishedAt,
                targetRef: targetRef,
                targetName: targetName,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String destination,
                Value<String> doneKeys = const Value.absent(),
                Value<int> lastFinishedAt = const Value.absent(),
                Value<String> targetRef = const Value.absent(),
                Value<String> targetName = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PhotoBackupTargetRowsCompanion.insert(
                destination: destination,
                doneKeys: doneKeys,
                lastFinishedAt: lastFinishedAt,
                targetRef: targetRef,
                targetName: targetName,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $PhotoBackupTargetRowsTable,
                    PhotoBackupTargetRow
                  >(table),
                  BaseReferences<
                    _$ChatDatabase,
                    $PhotoBackupTargetRowsTable,
                    PhotoBackupTargetRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PhotoBackupTargetRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$ChatDatabase,
      $PhotoBackupTargetRowsTable,
      PhotoBackupTargetRow,
      $$PhotoBackupTargetRowsTableFilterComposer,
      $$PhotoBackupTargetRowsTableOrderingComposer,
      $$PhotoBackupTargetRowsTableAnnotationComposer,
      $$PhotoBackupTargetRowsTableCreateCompanionBuilder,
      $$PhotoBackupTargetRowsTableUpdateCompanionBuilder,
      (
        PhotoBackupTargetRow,
        BaseReferences<
          _$ChatDatabase,
          $PhotoBackupTargetRowsTable,
          PhotoBackupTargetRow
        >,
      ),
      PhotoBackupTargetRow,
      PrefetchHooks Function()
    >;

class $ChatDatabaseManager {
  final _$ChatDatabase _db;
  $ChatDatabaseManager(this._db);
  $$ChannelRowsTableTableManager get channelRows =>
      $$ChannelRowsTableTableManager(_db, _db.channelRows);
  $$UserRowsTableTableManager get userRows =>
      $$UserRowsTableTableManager(_db, _db.userRows);
  $$PostRowsTableTableManager get postRows =>
      $$PostRowsTableTableManager(_db, _db.postRows);
  $$KeyValueRowsTableTableManager get keyValueRows =>
      $$KeyValueRowsTableTableManager(_db, _db.keyValueRows);
  $$FileEntryRowsTableTableManager get fileEntryRows =>
      $$FileEntryRowsTableTableManager(_db, _db.fileEntryRows);
  $$NoteCacheRowsTableTableManager get noteCacheRows =>
      $$NoteCacheRowsTableTableManager(_db, _db.noteCacheRows);
  $$NotebookCacheRowsTableTableManager get notebookCacheRows =>
      $$NotebookCacheRowsTableTableManager(_db, _db.notebookCacheRows);
  $$TodoCacheRowsTableTableManager get todoCacheRows =>
      $$TodoCacheRowsTableTableManager(_db, _db.todoCacheRows);
  $$NotePendingRowsTableTableManager get notePendingRows =>
      $$NotePendingRowsTableTableManager(_db, _db.notePendingRows);
  $$BookProgressRowsTableTableManager get bookProgressRows =>
      $$BookProgressRowsTableTableManager(_db, _db.bookProgressRows);
  $$BookMarkRowsTableTableManager get bookMarkRows =>
      $$BookMarkRowsTableTableManager(_db, _db.bookMarkRows);
  $$PhotoBackupTargetRowsTableTableManager get photoBackupTargetRows =>
      $$PhotoBackupTargetRowsTableTableManager(_db, _db.photoBackupTargetRows);
}
