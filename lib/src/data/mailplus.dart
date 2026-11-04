// MailPlus（Webmail 客户端）业务 API（**只做普通用户功能**）—— 在 [DsmWebApi]
// 之上把 `SYNO.MailClient.*` 收敛成强类型方法。
//
// ★ 权威事实来源：`docs/station-surveillance-mailplus-insight-research.md`
//   及其实现回填小节（本项目对 MailPlus-x86_64-4.1.0-22327.spk 的离线取证）。
//   本文件的 **api 名 / method / 版本 / 参数名** 逐字对齐**包内官方 Webmail
//   前端** `ui/mailclient.js` 的 `BaseWebAPIConfig.data`（registryKey → api/
//   method/version/build，build 体即权威参数形状）。**不要凭记忆改。**
//
// 已实现（普通用户；版本按**方法**选，不照 maxVersion 协商）：
//   * `Info.getinfo` **v2**（客户端 registry 钉的版本）/ `get_compound_info` v6
//   * `Mailbox.list` v7（`subscription` + `additional:["unread_count",
//     "draft_total_count"]`，root **`mailbox`**）
//   * `Label.list` v3（`additional:["unread_count"]`，root **`label`**）
//   * `Thread.list` v11（`condition` + `offset`/`limit`/`additional`，root
//     **`thread`**、`total`、`has_more`）· `Thread.get` v11
//   * `Message.get` v10 · `set_read` v10 · `set_star` v10 · `set_mailbox` v10
//   * `Draft.create` v7 · `Draft.send` v7
//   * `Attachment.download` 的 **URL 拼装**（本客户端不内置附件下载器）
//
// 明确**不做**（理由：管理员面 / 参数未取证 / 超出普通用户客户端范围）：
//   * `SYNO.MailPlusServer.*` 全部 71 个命名空间 —— **管理员控制台**
//     （域/配额/中继/DKIM/审核/隔离/迁移/集群/许可），research §3.8/§5
//   * `MailClient.CMSCertificate` / `Setting.Encryption`（S/MIME 证书导入）
//     / `Setting.Ai` / `MailMerge` / `MailTrack` / `PGPKey` / `MailRecall`
//     —— 写侧或需要额外配置，本批不做
//   * `MailClient.Mailbox.get` / `Label.get` / `Label.delete` /
//     `Thread.check_exist` / `Thread.list_exist_spam_rule`
//     —— **参数未取证**（research 实现回填小节的未核实清单），不做
//   * `MailClient.Attachment.upload*` / `download_dsm*` / `upload_sticker`
//     —— 需要 multipart 与 DSM 联动，本批只做**下载 URL**
//   * `MailClient.SearchHistory` / `Filter` / `Signature` / `SpamRule` /
//     `Sticker` / `Theme` / `UserPreference` —— 后置
//   * `SYNO.PersonMailAccount.*`（DSM 核心的"外部邮箱账号/代发"，含
//     Gmail/Outlook OAuth）—— 与本模块**不是同一命名空间**，单列一批
//
// ⚠️ 数据层：**不许** import flutter / package:flutter（要能被 `dart run tool/*.dart`
// 加载）；文案走 `dataText(key, 中文原文)`（见 docs/app-identity-and-i18n.md §4.6）。
library;

import 'dart:convert';

import '../core/i18n/data_text.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/mailplus_dto.dart';

/// `SYNO.MailClient.*` 的高层封装。**不持有传输** —— 传输由 [DsmWebApi] 管。
class MailPlusApi {
  MailPlusApi(DsmWebApi api) : api = api.withModule(TrafficModules.mailplus);

  final DsmWebApi api;

  // ------------------------------------------------------------ 常量（逐字）
  static const String apiInfo = 'SYNO.MailClient.Info';
  static const String apiMailbox = 'SYNO.MailClient.Mailbox';
  static const String apiLabel = 'SYNO.MailClient.Label';
  static const String apiThread = 'SYNO.MailClient.Thread';
  static const String apiMessage = 'SYNO.MailClient.Message';
  static const String apiDraft = 'SYNO.MailClient.Draft';
  static const String apiAttachment = 'SYNO.MailClient.Attachment';

  /// 客户端 registry 钉的版本（**不是** .lib 的 maxVersion：
  /// 例 `Attachment` 的 .lib 是 v8，客户端写死 v7）。
  static const int infoVersion = 2;
  static const int mailboxVersion = 7;
  static const int labelVersion = 3;
  static const int threadVersion = 11;
  static const int messageVersion = 10;
  static const int draftVersion = 7;
  static const int attachmentDownloadVersion = 8;
  static const int attachmentUploadVersion = 7;

  /// 官方分页大小（Webmail 默认一页 30 封）。
  static const int pageSize = 30;

  /// `Thread.list` 的 `additional` 取值（SO 字面量之一）。
  static const String additionalWithRecipient = 'with_recipient';

  /// `Message.get` 的 `additional`（官方 `getMessageEx` 的两种形态）。
  static const List<String> messageAdditionalDefault = [
    'blockquote',
    'truncated',
  ];
  static const List<String> messageAdditionalWithImages = [
    'blockquote',
    'truncated',
    'block_external_image',
  ];

  /// `Draft.create` 的 `draft_type`（官方常量）。
  static const int draftTypeNewThread = 0;
  static const int draftTypeReply = 1;
  static const int draftTypeForward = 2;

  // ------------------------------------------------------------ 能力 / 版本

  /// 候选版本里挑一个服务器真正支持的（与其它模块同规则）。
  int negotiate(String apiName, List<int> candidates) {
    final entry = api.apiTable?[apiName];
    if (entry == null || candidates.isEmpty) {
      return candidates.isEmpty ? 1 : candidates.first;
    }
    final within = candidates.where(
      (c) => c >= entry.minVersion && c <= entry.maxVersion,
    );
    if (within.isNotEmpty) return within.reduce((a, b) => a > b ? a : b);
    return entry.maxVersion < candidates.last
        ? entry.maxVersion
        : entry.minVersion;
  }

  /// 服务器是否声明了某 API（`SYNO.API.Info` 实测表）。
  ///
  /// 表为空（未 discover）时按"未知"处理，返回 true —— 交给调用时的错误兜底。
  bool hasApi(String apiName) {
    final table = api.apiTable;
    if (table == null) return true;
    return table.containsKey(apiName);
  }

  /// **套件未安装**的强判据：能力表里没有 `SYNO.MailClient.Info`。
  ///
  /// 与"有 API 但没权限（105/160）"和"网络不通"区分开，界面才能给对的空态
  /// （任务书硬要求：不要一律"加载失败"）。
  bool get installed => hasApi(apiInfo);

  // ------------------------------------------------------------ 能力探测

  /// `Info / getinfo`（客户端钉 **v2**，无参数）。
  ///
  /// ⚠️ 回包字段未逐字取证 → 原样返回，不做 DTO（宁可少解析也不乱解析）。
  Future<Map<String, dynamic>> getInfo() => api.call(
    apiInfo,
    'getinfo',
    preferredVersion: negotiate(apiInfo, const [infoVersion]),
  );

  // ------------------------------------------------------------ 邮箱 / 标签

  /// `Mailbox / list`（v7）—— 邮箱树。
  ///
  /// 参数逐字对齐 `Model.MailboxStore.baseParams`：
  /// `{subscription:false, additional:["unread_count","draft_total_count"]}`
  /// （+ `conversation_view`）；回包 root **`mailbox`**、total **`total`**。
  Future<List<MailMailboxDto>> listMailboxes({
    bool conversationView = false,
  }) async {
    final data = await api.call(
      apiMailbox,
      'list',
      preferredVersion: negotiate(apiMailbox, const [mailboxVersion]),
      params: {
        'subscription': false,
        'additional': jsonEncode(const ['unread_count', 'draft_total_count']),
        if (conversationView) 'conversation_view': true,
      },
    );
    final raw = data['mailbox'] ?? data['mailboxes'];
    return <MailMailboxDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) MailMailboxDto.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// `Label / list`（v3）—— 标签列表。
  ///
  /// 参数逐字对齐 `Model.LabelStore.baseParams`：`{additional:["unread_count"]}`；
  /// 回包 root **`label`**、total **`total`**。
  Future<List<MailLabelDto>> listLabels({bool conversationView = false}) async {
    final data = await api.call(
      apiLabel,
      'list',
      preferredVersion: negotiate(apiLabel, const [labelVersion]),
      params: {
        'additional': jsonEncode(const ['unread_count']),
        if (conversationView) 'conversation_view': true,
      },
    );
    final raw = data['label'] ?? data['labels'];
    return <MailLabelDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) MailLabelDto.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  // ------------------------------------------------------------ 会话 / 邮件

  /// `Thread / list`（v11）—— 邮件列表（会话视图）。
  ///
  /// 参数逐字对齐官方调用点（`ui/mailclient.js`）：
  /// `{condition:[{name,value,not_operator?}], offset, limit, additional}`
  /// （+ `conversation_view`）；回包 root **`thread`**、total **`total`**、
  /// 分页游标 **`has_more`**。
  ///
  /// `condition` 的 `name` 取值域（官方 `Condition`）：
  /// `mailbox` / `label` / `keyword` / `unread` / `starred` / `has_attachment`
  /// / `larger` / `smaller` / `before` / `after` / `priority`。
  /// `mailbox` 的 value 是**邮箱路径**（官方 `getRealMailboxPath`）。
  Future<MailThreadPage> listThreads({
    String? mailboxPath,
    String? labelPath,
    String? keyword,
    bool unreadOnly = false,
    bool starredOnly = false,
    bool hasAttachmentOnly = false,
    int offset = 0,
    int limit = pageSize,
    bool withRecipient = false,
    bool conversationView = false,
  }) async {
    final conditions = <Map<String, dynamic>>[
      if (mailboxPath != null && mailboxPath.isNotEmpty)
        {'name': 'mailbox', 'value': mailboxPath},
      if (labelPath != null && labelPath.isNotEmpty)
        {'name': 'label', 'value': labelPath},
      if (keyword != null && keyword.trim().isNotEmpty)
        {'name': 'keyword', 'value': keyword.trim()},
      if (unreadOnly) {'name': 'unread', 'value': 'true'},
      if (starredOnly) {'name': 'starred', 'value': 'true'},
      if (hasAttachmentOnly) {'name': 'has_attachment', 'value': 'true'},
    ];
    final data = await api.call(
      apiThread,
      'list',
      preferredVersion: negotiate(apiThread, const [threadVersion]),
      params: {
        'condition': jsonEncode(conditions),
        'offset': offset,
        'limit': limit,
        'additional': jsonEncode(
          withRecipient ? const [additionalWithRecipient] : const <String>[],
        ),
        if (conversationView) 'conversation_view': true,
      },
    );
    final raw = data['thread'] ?? data['threads'];
    final items = <MailThreadDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) MailThreadDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return MailThreadPage(
      items: items,
      total: _intOf(data['total'], items.length),
      hasMore: data['has_more'] == true,
      offset: offset,
    );
  }

  /// `Thread / get`（v11）—— 整个会话（含所有邮件）。
  ///
  /// ⚠️ 回包 root 是 **`thread`（数组）**（官方 `Model.BaseThreadReader`，
  /// 与 `Thread.list` **同一个 reader**；`Thread/get` 的调用点读
  /// `resp.thread[0].id`）——不是把 `data` 本身当会话。
  Future<MailThreadDto?> getThread(
    String id, {
    bool conversationView = false,
  }) async {
    final data = await api.call(
      apiThread,
      'get',
      preferredVersion: negotiate(apiThread, const [threadVersion]),
      params: {'id': id, if (conversationView) 'conversation_view': true},
    );
    final raw = data['thread'];
    final first = raw is List
        ? (raw.isEmpty ? null : raw.first)
        : (raw is Map ? raw : null);
    if (first is! Map) return null;
    return MailThreadDto.fromJson(Map<String, dynamic>.from(first));
  }

  /// `Message / get`（v10）—— 单封邮件正文。
  ///
  /// ⚠️ 回包 root 是 **`message`（数组）**（官方读 `resp.message[0]`）。
  /// `additional` 逐字对齐官方 `getMessageWithExtImg` / `getMessageWithoutExtImg`。
  Future<MailMessageDto?> getMessage(
    String id, {
    bool blockExternalImage = false,
  }) async {
    final data = await api.call(
      apiMessage,
      'get',
      preferredVersion: negotiate(apiMessage, const [messageVersion]),
      params: {
        // 官方 `getMessage({id:e,...})` 传标量；另一处传 `[id]`，两种都实测过。
        'id': id,
        'additional': jsonEncode(
          blockExternalImage
              ? messageAdditionalWithImages
              : messageAdditionalDefault,
        ),
      },
    );
    final raw = data['message'];
    final first = raw is List
        ? (raw.isEmpty ? null : raw.first)
        : (raw is Map ? raw : null);
    if (first is! Map) return null;
    return MailMessageDto.fromJson(Map<String, dynamic>.from(first));
  }

  /// `Message / set_read`（v10）—— 已读/未读。
  Future<void> setRead(String id, {required bool read}) => api.call(
    apiMessage,
    'set_read',
    preferredVersion: negotiate(apiMessage, const [messageVersion]),
    params: {'id': id, 'read': read},
  );

  /// `Message / set_star`（v10）—— 星标（`star` 为 0/1）。
  Future<void> setStar(String id, {required bool star}) => api.call(
    apiMessage,
    'set_star',
    preferredVersion: negotiate(apiMessage, const [messageVersion]),
    params: {'id': id, 'star': star ? 1 : 0},
  );

  /// `Message / set_mailbox`（v10）—— 移动到别的邮箱。
  Future<void> setMailbox(String id, String mailboxId) => api.call(
    apiMessage,
    'set_mailbox',
    preferredVersion: negotiate(apiMessage, const [messageVersion]),
    params: {'id': id, 'mailbox_id': mailboxId},
  );

  // ------------------------------------------------------------ 写信

  /// `Draft / create`（v7）—— 建草稿。
  ///
  /// 字段逐字对齐官方 `_getDraftParam`：`from,to,cc,bcc,subject,body,
  /// attachment,temp_attachment,draft_type,refer_to,enable_read_request,
  /// enable_delivery_request`。
  Future<String> createDraft({
    String from = '',
    List<String> to = const [],
    List<String> cc = const [],
    List<String> bcc = const [],
    String subject = '',
    String body = '',
    List<String> attachmentIds = const [],
    int draftType = draftTypeNewThread,
    String referTo = '',
    bool enableReadRequest = false,
    bool enableDeliveryRequest = false,
  }) async {
    final data = await api.call(
      apiDraft,
      'create',
      preferredVersion: negotiate(apiDraft, const [draftVersion]),
      params: {
        if (from.isNotEmpty) 'from': from,
        'to': jsonEncode(to),
        'cc': jsonEncode(cc),
        'bcc': jsonEncode(bcc),
        'subject': subject,
        'body': body,
        'attachment': jsonEncode(attachmentIds),
        'temp_attachment': jsonEncode(const <String>[]),
        'draft_type': draftType,
        if (referTo.isNotEmpty) 'refer_to': referTo,
        'enable_read_request': enableReadRequest,
        'enable_delivery_request': enableDeliveryRequest,
      },
    );
    return '${data['id'] ?? ''}';
  }

  /// `Draft / send`（v7）—— 发送草稿（`{id}` + 可选 `copy_to`/`schedule_time`）。
  Future<void> sendDraft(String id) => api.call(
    apiDraft,
    'send',
    preferredVersion: negotiate(apiDraft, const [draftVersion]),
    params: {'id': id},
  );

  // ------------------------------------------------------------ 附件（URL）

  /// 附件下载端点的 path：`<cgi path>/SYNO.MailClient.Attachment`
  /// （官方 `getBaseURL("SYNO.MailClient.Attachment","download",8,…)`）。
  String attachmentDownloadPath() {
    final base = api.apiPath(apiAttachment);
    if (base.endsWith('/$apiAttachment')) return base;
    return '$base/$apiAttachment';
  }

  /// 附件下载 URL。
  ///
  /// 参数逐字对齐官方 `getAttachmentDownloadUrl`：
  ///   * 有 `md5` → `{md5}`；
  ///   * 否则 `{msg_path, part_id[, is_cms=1]}`；
  ///   * 带票据时 `{uid, file_hash, download_token}`；
  ///   * `type` = `original` | `thumb`。
  String attachmentDownloadUrl(
    MailAttachmentDto att, {
    String type = 'original',
    String uid = '',
    String fileHash = '',
    String downloadToken = '',
  }) => api.authenticatedUrl(attachmentDownloadPath(), {
    'api': apiAttachment,
    'version': '$attachmentDownloadVersion',
    'method': 'download',
    if (att.md5.isNotEmpty)
      'md5': att.md5
    else ...{
      if (att.msgPath.isNotEmpty) 'msg_path': att.msgPath,
      if (att.partId.isNotEmpty) 'part_id': att.partId,
    },
    if (uid.isNotEmpty) 'uid': uid,
    if (fileHash.isNotEmpty) 'file_hash': fileHash,
    if (downloadToken.isNotEmpty) 'download_token': downloadToken,
    if (type == 'original' || type == 'thumb') 'type': type,
  });
}

// ---------------------------------------------------------------- 错误分类

/// 失败的**大类**：界面据此给出不同的空态/图标/标题。
enum MailFailureKind {
  /// 这台 NAS 没装（或没启用）MailPlus（能力表里没有该 API）。
  notInstalled,

  /// 装了，但这账号没有权限（`105` / `160` / `402` / `408`）。
  noPrivilege,

  /// 会话过期，需要重新登录。
  sessionExpired,

  /// 连不上（断网/隧道未起/证书问题）。
  network,

  /// 其它（业务错误、参数错误……）。
  other,
}

/// 把异常归到 [MailFailureKind]（判据与 [describeMailError] 一致）。
MailFailureKind mailFailureKind(Object error) {
  if (error is DsmTransportException) return MailFailureKind.network;
  if (error is! DsmApiException) return MailFailureKind.other;
  switch (error.code) {
    case DsmErrorCode.apiNotFound:
    case DsmErrorCode.methodNotFound:
    case DsmErrorCode.notSupportedVersion:
    case DsmErrorCode.noMatchLibEntry:
      return MailFailureKind.notInstalled;
    case DsmErrorCode.noPermission:
    case DsmErrorCode.noAppPrivilege:
    case 402: // error_privilege_not_enough
    case 408: // error_privilege_not_enough
      return MailFailureKind.noPrivilege;
    case DsmErrorCode.sessionTimeout:
    case DsmErrorCode.sidNotFound:
      return MailFailureKind.sessionExpired;
    case 1202: // api_error:connection_error
    case 2100: // api_error:imap_connection_failed
    case 500: // api_error:smtp_connection_failed
      return MailFailureKind.network;
    default:
      return MailFailureKind.other;
  }
}

/// MailPlus 错误 → 可读文案。
///
/// 错误码表**逐字**取自包内官方前端 `ui/mailclient.js` 的
/// `NNN:_T("api_error","…")` 常量（104 条里的普通用户相关子集 + 通用 WebAPI 码）。
String describeMailError(Object error) {
  if (error is DsmTransportException) {
    return dataText('mailErrNetwork', '网络连接失败，请检查网络后重试');
  }
  if (error is! DsmApiException) return '$error';
  switch (error.code) {
    // 通用 WebAPI 码
    case DsmErrorCode.apiNotFound: // 102
    case DsmErrorCode.methodNotFound: // 103
    case DsmErrorCode.notSupportedVersion: // 104
    case DsmErrorCode.noMatchLibEntry: // 121
      return dataText('mailErrNotInstalled', '这台 NAS 没有安装 MailPlus');
    case DsmErrorCode.noPermission: // 105
    case DsmErrorCode.noAppPrivilege: // 160
      return dataText('mailErrNoPrivilege', '这个账号没有使用 MailPlus 的权限');
    case DsmErrorCode.sessionTimeout: // 106
      return dataText('errLoginExpired', '登录已过期，请重新登录');
    case DsmErrorCode.sidNotFound: // 119
      return dataText('errSidNotFound', '登录状态无效，请重新登录');
    // MailClient 业务码（ui/mailclient.js 的错误表）
    case 120: // error_invalid
      return dataText('mailErrInvalid', '请求无效');
    case 400: // error_unknown_desc
      return dataText('mailErrUnknownDesc', 'MailPlus 返回了未知错误');
    case 401: // mailbox_not_exist
    case 422:
    case 423:
      return dataText('mailErrMailboxNotExist', '邮箱不存在');
    case 402: // error_privilege_not_enough
    case 408:
      return dataText('mailErrNoPrivilege', '这个账号没有使用 MailPlus 的权限');
    case 405: // error_no_enough_space
    case 1601: // draft_volume_quota
      return dataText('mailErrNoSpace', '存储空间不足');
    case 406: // invalid_account
      return dataText('mailErrInvalidAccount', '邮箱账号无效');
    case 407: // database_operation_failed
      return dataText('mailErrDatabase', '服务端数据库操作失败');
    case 409: // version_mismatch
      return dataText('mailErrVersionMismatch', '客户端与服务端版本不匹配');
    case 410: // database_is_upgrading
      return dataText('mailErrUpgrading', 'MailPlus 正在升级，请稍后再试');
    case 420: // mailbox_name_too_long
      return dataText('mailErrMailboxNameTooLong', '邮箱名过长');
    case 421: // mailbox_name_duplicated
      return dataText('mailErrMailboxDuplicated', '邮箱名重复');
    case 440: // label_name_too_long
      return dataText('mailErrLabelNameTooLong', '标签名过长');
    case 441: // label_name_duplicated
      return dataText('mailErrLabelDuplicated', '标签名重复');
    case 442: // label_not_exist
      return dataText('mailErrLabelNotExist', '标签不存在');
    case 480: // draft_not_exist
      return dataText('mailErrDraftNotExist', '草稿不存在（可能已发送或删除）');
    case 500: // smtp_connection_failed
      return dataText('mailErrSmtpConnection', '连接发信服务器失败');
    case 501: // smtp_authentication_failed
      return dataText('mailErrSmtpAuth', '发信服务器认证失败');
    case 503: // contain_illegal_attachment
      return dataText('mailErrIllegalAttachment', '邮件包含不被允许的附件');
    case 505: // recipient_not_available
      return dataText('mailErrRecipientUnavailable', '收件人不可用');
    case 506: // send_quota_reached
      return dataText('mailErrSendQuota', '已达到发送配额上限');
    case 507: // no_recipient
      return dataText('mailNeedRecipient', '请至少填写一个收件人');
    case 510: // daily_data_flow_exceed
      return dataText('mailErrDailyFlow', '已超出当日流量上限');
    case 512: // smtp_send_local_only
      return dataText('mailErrSendLocalOnly', '当前配置只允许向本域发送邮件');
    case 600: // auth_is_required
      return dataText('mailErrAuthRequired', '需要先完成账号认证');
    case 1803: // shared_mailbox_disabled_by_admin
      return dataText('mailErrSharedDisabled', '共享邮箱已被管理员停用');
    case 1804: // attachment_storage_disabled_by_admin
      return dataText('mailErrAttachmentDisabled', '附件存储已被管理员停用');
    case 2100: // imap_connection_failed
      return dataText('mailErrImapConnection', '连接收信服务器失败');
    default:
      return dataText(
        'mailErrUnknown',
        '未知错误（{code}）',
      ).replaceAll('{code}', '${error.code}');
  }
}

int _intOf(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}
