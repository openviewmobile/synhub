// 服务端下发的能力/限制设置 —— `SYNO.Chat.Admin.Setting / get`（v4/v3/v1）
// 的响应，以及实时通道 `setting.update` 广播推来的同构载荷。
//
// 逆向依据：
//   data/AccountManager.java#lambda$fetchAdminSetting$90
//     fileSizeLimit * 1048576 → PreferencesHelper.setFileSizeLimit（**MB → 字节**）
//     allowEncryption / defaultNotificationType / allowGuest / allowReadStatus
//     / forceAdFullName / readonlyProfile / allowEditMessage(+time)
//   syno/chat/admin/Setting.java
//     API = "SYNO.Chat.Admin.Setting"，isSupportReadStatus = support(API, 3)
//     isSupportEditAllPost = support(API, 4)
//   data/vo/chat/SettingVo.java（字段名）
//
// ⚠️ 真机实测（2026-02，NAS 2.3.1）：`file_size_limit` 回 **0 = 不限制**，
// `allow_edit_message_time_within_min` 回 **-1 = 不限时间**，`notify_type` 回
// `mention_subscribe`（频道没单独设置时用它兜底）。

/// `SYNO.Chat.Admin.Setting / get` 的结果（只留我们用得上的字段，其余原样留档）
class ServerSettings {
  const ServerSettings({
    this.fileSizeLimitMb = 0,
    this.allowEncryption = true,
    this.allowGuest = false,
    this.allowEditMessage = true,
    this.editMessageTimeWithinMin = -1,
    this.allowReadStatus = true,
    this.defaultNotificationType = '',
    this.allowDsUpload = false,
    this.allowPcUpload = false,
    this.allowDriveUpload = false,
    this.hidePostUrlPreview = false,
    this.notificationRenderNickname = false,
    this.forceAdFullname = false,
    this.readonlyProfile = const [],
    this.jitsiBaseUrls = const [],
  });

  /// 单个附件的大小上限，**单位 MB**（0 = 不限制；原版乘 1048576 得字节）
  final int fileSizeLimitMb;

  /// 服务端是否允许加密频道（false 时原版直接抛 `HttpsRequiredException`
  /// 或禁用加密开关）
  final bool allowEncryption;

  /// 是否允许访客账号（我们暂无访客界面，仅留档）
  final bool allowGuest;

  /// 是否允许编辑**任意**自己发的消息（v4 才有；false 时只有最新一条可编辑）
  final bool allowEditMessage;

  /// 编辑窗口，**分钟**（-1 / <=0 = 不限时间）
  final int editMessageTimeWithinMin;

  /// 是否支持"已读回执"（v3 才有）
  final bool allowReadStatus;

  /// 频道没单独设置通知档位时用它（`notify_type`）
  final String defaultNotificationType;

  final bool allowDsUpload;
  final bool allowPcUpload;
  final bool allowDriveUpload;

  /// 频道里是不是不展开链接预览
  final bool hidePostUrlPreview;

  /// 通知里是否渲染昵称
  final bool notificationRenderNickname;

  final bool forceAdFullname;

  /// 不允许用户自己改的资料字段（`nickname` / `email` / `desc`）
  final List<String> readonlyProfile;

  final List<String> jitsiBaseUrls;

  /// 附件大小上限（字节）；0 = 不限制
  int get fileSizeLimitBytes =>
      fileSizeLimitMb <= 0 ? 0 : fileSizeLimitMb * 1048576;

  /// 编辑窗口（毫秒）；<=0 = 不限制
  int get editWindowMs =>
      editMessageTimeWithinMin <= 0 ? 0 : editMessageTimeWithinMin * 60000;

  factory ServerSettings.fromJson(Map<String, dynamic> json) {
    int intOf(String key, int fallback) {
      final v = json[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    bool boolOf(String key, bool fallback) {
      final v = json[key];
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) return v == 'true' || v == '1';
      return fallback;
    }

    List<String> strList(String key) => ((json[key] as List?) ?? const [])
        .map((e) => '$e')
        .toList(growable: false);

    return ServerSettings(
      fileSizeLimitMb: intOf('file_size_limit', 0),
      allowEncryption: boolOf('allow_encryption', true),
      allowGuest: boolOf('allow_guest', false),
      allowEditMessage: boolOf('allow_edit_message', true),
      editMessageTimeWithinMin: intOf('allow_edit_message_time_within_min', -1),
      allowReadStatus: boolOf('allow_read_status', true),
      defaultNotificationType: '${json['notify_type'] ?? ''}',
      allowDsUpload: boolOf('allow_ds_upload', false),
      allowPcUpload: boolOf('allow_pc_upload', false),
      allowDriveUpload: boolOf('allow_drive_upload', false),
      hidePostUrlPreview: boolOf('hide_post_url_preview', false),
      notificationRenderNickname: boolOf('notification_render_nickname', false),
      forceAdFullname: boolOf('force_ad_fullname', false),
      readonlyProfile: strList('readonly_profile'),
      jitsiBaseUrls: strList('jitsi_base_urls'),
    );
  }

  Map<String, dynamic> toJson() => {
    'file_size_limit': fileSizeLimitMb,
    'allow_encryption': allowEncryption,
    'allow_guest': allowGuest,
    'allow_edit_message': allowEditMessage,
    'allow_edit_message_time_within_min': editMessageTimeWithinMin,
    'allow_read_status': allowReadStatus,
    'notify_type': defaultNotificationType,
    'allow_ds_upload': allowDsUpload,
    'allow_pc_upload': allowPcUpload,
    'allow_drive_upload': allowDriveUpload,
    'hide_post_url_preview': hidePostUrlPreview,
    'notification_render_nickname': notificationRenderNickname,
    'force_ad_fullname': forceAdFullname,
    'readonly_profile': readonlyProfile,
    'jitsi_base_urls': jitsiBaseUrls,
  };

  /// 拿服务端设置去补一份"还不知道"的本地设置（`setting.update` 可能只带
  /// 部分字段 —— 原版也是逐字段覆盖，缺的保持原值）。
  ServerSettings merge(ServerSettings patch) => ServerSettings(
    fileSizeLimitMb: patch.fileSizeLimitMb,
    allowEncryption: patch.allowEncryption,
    allowGuest: patch.allowGuest,
    allowEditMessage: patch.allowEditMessage,
    editMessageTimeWithinMin: patch.editMessageTimeWithinMin,
    allowReadStatus: patch.allowReadStatus,
    defaultNotificationType: patch.defaultNotificationType.isEmpty
        ? defaultNotificationType
        : patch.defaultNotificationType,
    allowDsUpload: patch.allowDsUpload,
    allowPcUpload: patch.allowPcUpload,
    allowDriveUpload: patch.allowDriveUpload,
    hidePostUrlPreview: patch.hidePostUrlPreview,
    notificationRenderNickname: patch.notificationRenderNickname,
    forceAdFullname: patch.forceAdFullname,
    readonlyProfile: patch.readonlyProfile,
    jitsiBaseUrls: patch.jitsiBaseUrls.isEmpty
        ? jitsiBaseUrls
        : patch.jitsiBaseUrls,
  );

  @override
  String toString() =>
      'ServerSettings(file=$fileSizeLimitMb MB '
      'enc=$allowEncryption guest=$allowGuest edit=$allowEditMessage'
      '($editMessageTimeWithinMin min) read=$allowReadStatus '
      'notify=$defaultNotificationType)';
}
