// 用户 VO —— 字段名对齐 APK 的 `data/vo/chat/UserVo.java` 与 `ProfileVo.java`
//
// 参考实测响应：test/fixtures/compound_users.json（Human/Bot 两段）
//
// 注意：`user_props` 里才是昵称/头像颜色/邮箱等资料，`user_id`/`username` 在顶层。
library;

/// `SYNO.Chat.User` 的一个用户。
class UserDto {
  const UserDto({
    required this.userId,
    this.username = '',
    this.nickname = '',
    this.type = '',
    this.status = '',
    this.humanType = '',
    this.botType = '',
    this.appId = 0,
    this.dsmUid = 0,
    this.avatarVersion = 0,
    this.avatarColor = '',
    this.email = '',
    this.description = '',
    this.publicKey = '',
    this.privateKeyEnc = '',
    this.isDisabled = false,
    this.isDeleted = false,
    this.hasUrl = false,
    this.isAlwaysOffline = false,
    this.slashCmd = '',
    this.slashDescription = '',
    this.slashUrl = '',
    this.slashUsage = '',
    this.chatbotHideFromUser = false,
    this.chatbotPurpose = '',
    this.chatbotWelcomeNote = '',
    this.botIsSystem = false,
    this.botStickerName = '',
    this.createAt = 0,
    this.updateAt = 0,
    this.deleteAt = 0,
    this.userProps = const <String, dynamic>{},
  });

  final int userId;

  /// 登录名
  final String username;

  /// 显示名（可能为空，此时退回 [username]）
  final String nickname;

  /// `human` / `bot`
  final String type;

  /// `online` / `offline` / `away` …
  final String status;

  /// `dsm` / `guest` …
  final String humanType;

  final String botType;
  final int appId;

  /// DSM 侧的 uid（user_id 是 Chat 侧 id）
  final int dsmUid;
  final int avatarVersion;
  final String avatarColor;
  final String email;
  final String description;

  /// E2EE 公钥 / 加密后的私钥（Phase 7 用）
  final String publicKey;
  final String privateKeyEnc;

  final bool isDisabled;
  final bool isDeleted;
  final bool hasUrl;
  final bool isAlwaysOffline;

  /// 斜杠命令（`slash_props`，只有 `bot_type = "slash"` 的机器人有）
  /// 例：`cmd=jiitsi` / `description=webhook_builtin:desc_conference_jitsi`
  final String slashCmd;
  final String slashDescription;
  final String slashUrl;
  final String slashUsage;

  /// chatbot 的附加信息（`chatbot_props`）
  final bool chatbotHideFromUser;
  final String chatbotPurpose;
  final String chatbotWelcomeNote;

  /// `bot_props.is_system` —— synobot 这类系统机器人
  final bool botIsSystem;

  /// `bot_props.sticker_name` —— 机器人头像用的贴纸名
  final String botStickerName;

  /// `user_props` 原文（`avatar_color` / `email` / `description` / `key_pair` /
  /// `preference` / `timezone` / `timezoneUTC` …）。
  /// 原版把这些拆成 `users` 表的列；我们按需从原文里取（时区、偏好都在里面）。
  final Map<String, dynamic> userProps;

  /// 服务端下发的 IANA 时区（`user_props.timezoneUTC`）。
  /// 注意是**驼峰** key：`libsynochatcore.so` 里的 record 字段名就是 `timezoneUTC`，
  /// 真机 `User/list` 返回 `"timezoneUTC":"Asia/Shanghai"`。
  String get timezoneUtc => userProps['timezoneUTC'] is String
      ? userProps['timezoneUTC'] as String
      : '';

  final int createAt;
  final int updateAt;
  final int deleteAt;

  bool get isBot => type == 'bot';

  /// 斜杠命令机器人（`/jitsi` 之类）
  bool get isSlashBot => botType == 'slash' && slashCmd.isNotEmpty;

  /// 能发起一对一对话的机器人（chatbot / broadcast / synobot）
  bool get isChatbot => isBot && !isSlashBot;

  /// 界面上是否要列到"机器人"列表里
  /// （`hide_from_user` 的是通知类机器人，原 App 也不直接列）
  bool get isListedBot =>
      isBot && !isSlashBot && !chatbotHideFromUser && !isDeleted;
  bool get isOnline => status == 'online';

  /// 界面上该显示的名字
  String get displayName => nickname.isNotEmpty ? nickname : username;

  factory UserDto.fromJson(Map<String, dynamic> json) {
    final props = json['user_props'];
    final p = props is Map
        ? Map<String, dynamic>.from(props)
        : const <String, dynamic>{};
    final slashRaw = json['slash_props'];
    final slash = slashRaw is Map
        ? Map<String, dynamic>.from(slashRaw)
        : const <String, dynamic>{};
    final chatbotRaw = json['chatbot_props'];
    final chatbot = chatbotRaw is Map
        ? Map<String, dynamic>.from(chatbotRaw)
        : const <String, dynamic>{};
    final botRaw = json['bot_props'];
    final bot = botRaw is Map
        ? Map<String, dynamic>.from(botRaw)
        : const <String, dynamic>{};
    final keyPair = p['key_pair'];
    final kp = keyPair is Map
        ? Map<String, dynamic>.from(keyPair)
        : const <String, dynamic>{};

    return UserDto(
      userId: _int(json['user_id']),
      username: _str(json['username']),
      nickname: _str(json['nickname']),
      type: _str(json['type']),
      status: _str(json['status']),
      humanType: _str(json['human_type']),
      botType: _str(json['bot_type']),
      appId: _int(json['app_id']),
      dsmUid: _int(json['dsm_uid']),
      avatarVersion: _int(json['avatar_version']),
      avatarColor: _str(p['avatar_color']),
      email: _str(p['email']),
      description: _str(p['description']),
      publicKey: _str(kp['public_key']),
      privateKeyEnc: _str(kp['private_key_enc']),
      isDisabled: json['is_disabled'] == true,
      isDeleted: json['deleted'] == true,
      hasUrl: json['has_url'] == true,
      isAlwaysOffline: p['is_always_offline'] == true,
      slashCmd: _str(slash['cmd']),
      slashDescription: _str(slash['description']),
      slashUrl: _str(slash['url']),
      slashUsage: _str(slash['usage']),
      chatbotHideFromUser: chatbot['hide_from_user'] == true,
      chatbotPurpose: _str(chatbot['purpose']),
      chatbotWelcomeNote: _str(chatbot['welcome_note']),
      botIsSystem: bot['is_system'] == true,
      botStickerName: _str(bot['sticker_name']),
      createAt: _int(json['create_at']),
      updateAt: _int(json['update_at']),
      deleteAt: _int(json['delete_at']),
      userProps: p,
    );
  }

  /// 从 `client.broadcast`/`user.update` 的载荷构造（字段与 User.list 一致）
  static UserDto? tryFromBroadcast(Object? data) {
    if (data is! Map) return null;
    final map = Map<String, dynamic>.from(data);
    final id = _int(map['user_id']);
    if (id == 0) return null;
    return UserDto.fromJson(map);
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
