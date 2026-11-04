// MailPlus（Webmail 客户端）DTO —— `SYNO.MailClient.*` 的返回形状。
//
// ★ 事实来源（全部可在解包目录 `/tmp/spk/ex_MailPlus` 里 grep 到原文）：
//   * `ui/mailclient.js` 的官方 Ext store / JsonReader 声明：
//     - `Model.MailboxStore`：`root:"mailbox"`, `totalProperty:"total"`,
//       `fields:["id","path","is_own","owner","my_permission","subscribed",
//                "additional","owner_valid","has_expired"]`；
//     - `Model.LabelStore`：`root:"label"`, `fields:["id","full_name","name",
//       "display_name","path","parent_id","background_color","text_color",
//       "additional"]`；
//     - `Model.BaseThreadReader`：`root:"thread"`, `totalProperty:"total"`,
//       `fields:["id","star","label","message","draft","unread","replied",
//       "forwarded","last_modified","is_mail_merge",
//       "ai_summary_generated_time","filtered_message"]`，另读 `has_more`；
//     - 邮件（Message/Draft）字段表：`id,arrival_time,attachment,bcc,body,
//       body_preview,cc,email,from,last_modified,mailbox_id,read,star,subject,
//       thread_id,rfc_message_id,operation_ids`（Draft 多 `is_draft`）。
//   * 地址在线上是 RFC822 字符串（`ui/mailclient.js` 的
//     `formatAddrsOfMsgToNormal` / `rfc822AddrToNormalAddr`）。
//   * 附件键名来自 `ui/mailclient.js` 的附件项构造（`msg_path`,`part_id`,
//     `md5`,`msg_id`,`id`,`name`,`size`,`content_id`）。
//
// ⚠️ 本文件属**数据层**：不许 import flutter / package:flutter —— 要能被
// `dart run tool/*.dart`（纯 Dart VM）加载。文案由界面层给。
library;

/// `Mailbox.list` v7 回包 `mailbox[]` 的一项。
class MailMailboxDto {
  const MailMailboxDto({
    required this.id,
    this.path = '',
    this.isOwn = false,
    this.owner = '',
    this.myPermission = 0,
    this.subscribed = true,
    this.ownerValid = true,
    this.hasExpired = false,
    this.unreadCount = 0,
    this.draftCount = 0,
  });

  final String id;

  /// 邮箱路径（官方用它推导层级：`mailbox` 的 `path`；`/` 或 `.` 分隔）。
  final String path;
  final bool isOwn;
  final String owner;
  final int myPermission;
  final bool subscribed;
  final bool ownerValid;
  final bool hasExpired;

  /// `additional.unread_count`。
  final int unreadCount;

  /// `additional.draft_total_count`。
  final int draftCount;

  /// 显示名（官方 `_getDisplayName` 取路径末段，邮箱路径分隔符是 `.`）。
  String get displayName => _pathTail(path, '.');

  factory MailMailboxDto.fromJson(Map<String, dynamic> json) {
    final add = json['additional'];
    final a = add is Map ? Map<String, dynamic>.from(add) : const {};
    return MailMailboxDto(
      id: _str(json['id']),
      path: _str(json['path']),
      isOwn: _bool(json['is_own']),
      owner: _str(json['owner']),
      myPermission: _int(json['my_permission']),
      subscribed: _bool(json['subscribed'], fallback: true),
      ownerValid: _bool(json['owner_valid'], fallback: true),
      hasExpired: _bool(json['has_expired']),
      unreadCount: _int(a['unread_count']),
      draftCount: _int(a['draft_total_count']),
    );
  }
}

/// `Label.list` v3 回包 `label[]` 的一项。
class MailLabelDto {
  const MailLabelDto({
    required this.id,
    this.name = '',
    this.displayName = '',
    this.fullName = '',
    this.path = '',
    this.parentId = '0',
    this.backgroundColor = '',
    this.textColor = '',
    this.unreadCount = 0,
  });

  final String id;
  final String name;
  final String displayName;
  final String fullName;
  final String path;
  final String parentId;
  final String backgroundColor;
  final String textColor;
  final int unreadCount;

  String get label => displayName.isNotEmpty
      ? displayName
      : (name.isNotEmpty
            ? name
            : (fullName.isNotEmpty ? fullName : _pathTail(path, '/')));

  factory MailLabelDto.fromJson(Map<String, dynamic> json) {
    final add = json['additional'];
    final a = add is Map ? Map<String, dynamic>.from(add) : const {};
    final path = _str(json['path']);
    return MailLabelDto(
      id: _str(json['id']),
      name: _str(json['name']),
      // 官方前端在 `load` 监听里用 `path` 末段**覆盖** display_name。
      displayName: _str(json['display_name']).isEmpty
          ? _pathTail(path, '/')
          : _str(json['display_name']),
      fullName: _str(json['full_name']),
      path: path,
      parentId: _str(json['parent_id']),
      backgroundColor: _str(json['background_color']),
      textColor: _str(json['text_color']),
      unreadCount: _int(a['unread_count']),
    );
  }
}

/// 邮件附件。
class MailAttachmentDto {
  const MailAttachmentDto({
    this.id = '',
    this.name = '',
    this.size = 0,
    this.partId = '',
    this.msgPath = '',
    this.msgId = '',
    this.md5 = '',
    this.contentId = '',
    this.url = '',
    this.inline = false,
  });

  final String id;
  final String name;
  final int size;
  final String partId;
  final String msgPath;
  final String msgId;
  final String md5;
  final String contentId;

  /// 服务端给的**预签名地址**（官方 `UrlBuilder` 优先用它短路下载）。
  final String url;

  /// 是否是正文内嵌图片。
  final bool inline;

  /// 稳定的本地 id（官方 `createItemConfig` 的判据顺序）。
  String get key {
    if (msgPath.isNotEmpty && partId.isNotEmpty) return '$msgPath$partId';
    if (md5.isNotEmpty) return md5;
    if (msgId.isNotEmpty && partId.isNotEmpty) return '$msgId$partId';
    return id;
  }

  factory MailAttachmentDto.fromJson(Map<String, dynamic> json) =>
      MailAttachmentDto(
        id: _str(json['id']),
        name: _str(json['name']).isEmpty
            ? _str(json['filename'])
            : _str(json['name']),
        size: _int(json['size']) == 0
            ? _int(json['filesize'])
            : _int(json['size']),
        partId: _str(json['part_id']),
        msgPath: _str(json['msg_path']),
        msgId: _str(json['msg_id']),
        md5: _str(json['md5']),
        contentId: _str(json['content_id']).isEmpty
            ? _str(json['cid'])
            : _str(json['content_id']),
        url: _str(json['url']),
        inline: _bool(json['inline']),
      );
}

/// 一封邮件（`Message.get` v10 / thread 内嵌 message）。
class MailMessageDto {
  const MailMessageDto({
    required this.id,
    this.subject = '',
    this.from = '',
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.body = '',
    this.bodyHtml = '',
    this.bodyPlain = '',
    this.bodyPreview = '',
    this.arrivalTime = 0,
    this.mailboxId = '',
    this.threadId = '',
    this.rfcMessageId = '',
    this.read = false,
    this.star = false,
    this.attachments = const [],
  });

  final String id;
  final String subject;

  /// 发件人（线上是 RFC822 字符串）。
  final String from;
  final List<String> to;
  final List<String> cc;
  final List<String> bcc;

  /// 正文 —— 线上 `body` 是**对象** `{html, plain, truncated, blockquote?, style?}`
  /// （官方 `MessageLib.MsgStore` + `_fixUndefinedBody`），也可能直接是字符串。
  /// [body] 是给"纯展示"用的合并文本（html 优先），另留 [bodyHtml] / [bodyPlain]。
  final String body;
  final String bodyHtml;
  final String bodyPlain;
  final String bodyPreview;
  final int arrivalTime;
  final String mailboxId;
  final String threadId;
  final String rfcMessageId;
  final bool read;
  final bool star;
  final List<MailAttachmentDto> attachments;

  bool get hasAttachment => attachments.isNotEmpty;

  /// 可显示正文：优先 `body`，退回 `body_preview`。
  String get displayBody => body.isNotEmpty ? body : bodyPreview;

  DateTime? get arrivalAt => arrivalTime > 0
      ? DateTime.fromMillisecondsSinceEpoch(arrivalTime * 1000)
      : null;

  factory MailMessageDto.fromJson(Map<String, dynamic> json) {
    final rawAtt = json['attachment'] ?? json['attachments'];
    final rawBody = json['body'];
    final bodyMap = rawBody is Map
        ? Map<String, dynamic>.from(rawBody)
        : const <String, dynamic>{};
    final bodyHtml = _str(bodyMap['html']);
    final bodyPlain = _str(bodyMap['plain']);
    final bodyText = rawBody is String
        ? rawBody
        : (bodyHtml.isNotEmpty
              ? bodyHtml
              : (bodyPlain.isNotEmpty
                    ? bodyPlain
                    : _str(bodyMap['truncated'])));
    return MailMessageDto(
      id: _str(json['id']),
      subject: _str(json['subject']),
      from: _addr(json['from']),
      to: _addrList(json['to']),
      cc: _addrList(json['cc']),
      bcc: _addrList(json['bcc']),
      body: bodyText,
      bodyHtml: bodyHtml,
      bodyPlain: bodyPlain,
      bodyPreview: _str(json['body_preview']),
      arrivalTime: _int(json['arrival_time']),
      mailboxId: _str(json['mailbox_id']),
      threadId: _str(json['thread_id']),
      rfcMessageId: _str(json['rfc_message_id']),
      read: _bool(json['read']),
      star: _bool(json['star']),
      attachments: <MailAttachmentDto>[
        if (rawAtt is List)
          for (final e in rawAtt)
            if (e is Map)
              MailAttachmentDto.fromJson(Map<String, dynamic>.from(e)),
      ],
    );
  }
}

/// `Thread.list` v11 回包 `thread[]` 的一项。
class MailThreadDto {
  const MailThreadDto({
    required this.id,
    this.star = false,
    this.unreadCount = 0,
    this.replied = false,
    this.forwarded = false,
    this.draft = false,
    this.lastModified = 0,
    this.labelIds = const [],
    this.messages = const [],
  });

  final String id;
  final bool star;

  /// 会话里未读的条数（官方 `ThreadStorePostProcessor` 里 `unread` 是**计数**，
  /// 不是布尔；`{name:"unread",convert:…}` 也只做真假判断）。
  final int unreadCount;
  final bool replied;
  final bool forwarded;
  final bool draft;
  final int lastModified;

  /// `label` 字段在线上是**对象数组**（每项有 `id`），也可能是裸 id。
  final List<String> labelIds;

  /// `message` 字段在线上是消息数组（官方对 `t.message` 做 forEach 归一化）。
  final List<MailMessageDto> messages;

  /// 列表行用的"代表邮件"（最后一条，与官方列表右栏一致）。
  MailMessageDto? get primary => messages.isEmpty ? null : messages.last;

  String get subject => primary?.subject ?? '';
  String get from => primary?.from ?? '';
  String get preview => primary?.bodyPreview ?? '';
  bool get hasAttachment => messages.any((m) => m.hasAttachment);

  /// 是否未读（计数 > 0）。
  bool get unread => unreadCount > 0;

  DateTime? get lastModifiedAt => lastModified > 0
      ? DateTime.fromMillisecondsSinceEpoch(lastModified * 1000)
      : null;

  factory MailThreadDto.fromJson(Map<String, dynamic> json) {
    final rawMsg = json['message'];
    final msgs = <MailMessageDto>[];
    if (rawMsg is List) {
      for (final e in rawMsg) {
        if (e is Map) {
          msgs.add(MailMessageDto.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    } else if (rawMsg is Map) {
      msgs.add(MailMessageDto.fromJson(Map<String, dynamic>.from(rawMsg)));
    }
    return MailThreadDto(
      id: _str(json['id']),
      star: _bool(json['star']),
      unreadCount: _int(json['unread']),
      replied: _bool(json['replied']),
      forwarded: _bool(json['forwarded']),
      draft: _bool(json['draft']),
      lastModified: _int(json['last_modified']),
      labelIds: _idsOf(json['label']),
      messages: msgs,
    );
  }
}

/// 分页包装（`total` + `has_more`）。
class MailThreadPage {
  const MailThreadPage({
    this.items = const [],
    this.total = 0,
    this.hasMore = false,
    this.offset = 0,
  });

  final List<MailThreadDto> items;
  final int total;
  final bool hasMore;
  final int offset;
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

String _str(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num || v is bool) return '$v';
  return '';
}

bool _bool(Object? v, {bool fallback = false}) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == '1') return true;
    if (s == 'false' || s == '0') return false;
  }
  return fallback;
}

/// 地址字段可能是字符串、`{name,email}` map、或**地址数组**（官方
/// `Format.toEmail(i.from)` 说明 `from` 也可能是裸字符串，两种都要吃）。
String _addr(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is List) return v.isEmpty ? '' : _addr(v.first);
  if (v is Map) {
    final name = _str(v['name']);
    final email = _str(v['email']);
    if (name.isEmpty) return email;
    if (email.isEmpty) return name;
    return '$name <$email>';
  }
  return _str(v);
}

/// 地址列表：字符串（逗号分隔）、单元素、或列表。
List<String> _addrList(Object? v) {
  if (v == null) return const [];
  if (v is List) {
    return [
      for (final e in v)
        if (_addr(e) case final s when s.isNotEmpty) s,
    ];
  }
  final s = _addr(v);
  if (s.isEmpty) return const [];
  return [s];
}

/// id 列表：`label` 字段在线上是**对象数组**（每项有 `id`），也可能是裸 id。
List<String> _idsOf(Object? v) {
  if (v == null) return const [];
  if (v is List) {
    return [
      for (final e in v)
        if (_idOf(e) case final s when s.isNotEmpty) s,
    ];
  }
  final s = _idOf(v);
  return s.isEmpty ? const [] : [s];
}

String _idOf(Object? v) {
  if (v is Map) return _str(v['id']);
  return _str(v);
}

/// 路径末段（官方前端用 `path` 派生 `name`/`display_name`）。
String _pathTail(String path, String separator) {
  final p = path.trim();
  if (p.isEmpty) return '';
  final i = p.lastIndexOf(separator);
  return i < 0 ? p : p.substring(i + 1);
}
