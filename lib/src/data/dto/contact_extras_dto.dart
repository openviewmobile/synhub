// Synology Contacts：标签 / 群组 / 外部源 / 主体 / 导入预览的数据模型。
//
// 参数与回包形状的真机取样见 `docs/contacts-module-plan.md` §3.1（2026-09-21）：
//   * `Label/list` → `{"label":[{id,name,color,type,member:[],member_count}]}`
//     —— **`type:1` 是系统「Starred」，`type:0` 是用户标签**；
//   * `Addressbook/list_principal` → `{"principal":[{id,account_name,display_name,
//     type,is_shared,mode,status,member:[…]}]}`，`member` 是群组里的用户 id；
//   * `Addressbook/import_preview` → `{"contact":[{full_name,primary_mail,status}]}`；
//   * `Contact/list_group` → `{"group":[…], "total":n}`（本 NAS 上一直是空数组，
//     所以群组字段按**容错**解析：没有的字段一律给默认值，不猜形状）；
//   * `ExternalSource/list` → `{"external_sources":[…], "total":n}`（本 NAS 上为空，
//     同样容错解析；官方 bundle 里创建 CardDAV 源只发
//     `{is_sync, import_type, addressbook_id, addressbook_location, username, pwd}`）。
import 'dart:convert';

/// 标签（`SYNO.Contacts.Label`）
class LabelDto {
  const LabelDto({
    required this.id,
    required this.name,
    this.color = '',
    this.type = 0,
    this.memberIds = const [],
    this.memberCount = 0,
  });

  final String id;
  final String name;

  /// `#RRGGBB`（服务端有时给不带 `#` 的 6 位 hex，统一在这里补上）
  final String color;

  /// 1 = 系统「Starred」；0 = 用户标签
  final int type;

  final List<String> memberIds;
  final int memberCount;

  bool get isStarred => type == 1;

  /// 没有自定义颜色时给一个稳定的默认色（同一标签每次一样的颜色）
  String get displayColor {
    final c = color.trim();
    if (RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(c)) {
      return c.startsWith('#') ? c.toUpperCase() : '#${c.toUpperCase()}';
    }
    const palette = [
      '#4C8DFF',
      '#37B26C',
      '#F2A33C',
      '#E0567B',
      '#8E6BE0',
      '#2FA8A0',
    ];
    var h = 0;
    for (final unit in id.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }

  factory LabelDto.fromJson(Map<String, dynamic> json) => LabelDto(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? json['label_name'] ?? ''}',
    color: '${json['color'] ?? ''}',
    type: _int(json['type']),
    memberIds: _ids(json['member'] ?? json['member_ids']),
    memberCount: _int(json['member_count']),
  );

  static List<LabelDto> listFromJson(Map<String, dynamic> data) {
    final raw = data['label'] ?? data['labels'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) LabelDto.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// 联系人分组（`Contact/list_group`）。
///
/// 字段证据：官方网页客户端 `ui/static/js/main.js` 的 `MD()` ——
/// `Ht(Hn.send,"listGroup",{addressbook_id:…})` 之后
/// ```js
/// u.group.forEach((function(e){i.addressbook.push({id:e.id,name:e.name,
///   type:yi,mode:…,member_count:e.member_count,…,is_hidden:e.is_hidden,path:e.path})}))
/// ```
/// ⇒ 每项 `{id, name, member_count, is_hidden, path}`。本 NAS 的
/// `list_group` 一直回空数组（`{"group":[], "total":0}`，见
/// `docs/contacts-module-plan.md` §3），所以非空形状按官方 JS 的字段名解析。
class GroupDto {
  const GroupDto({
    required this.id,
    required this.name,
    this.memberCount = 0,
    this.addressbookId = '',
    this.isHidden = false,
    this.path = '',
  });

  final String id;
  final String name;
  final int memberCount;
  final String addressbookId;

  /// 官方 `is_hidden`（`Contact/toggle_group` 改的就是它）
  final bool isHidden;

  /// 官方 `path`（组织单位路径；普通分组为空）
  final String path;

  factory GroupDto.fromJson(Map<String, dynamic> json) => GroupDto(
    id: '${json['id'] ?? json['group_id'] ?? ''}',
    name: '${json['name'] ?? json['group_name'] ?? ''}',
    memberCount: _int(json['member_count']),
    addressbookId: '${json['addressbook_id'] ?? ''}',
    isHidden: json['is_hidden'] == true,
    path: '${json['path'] ?? ''}',
  );

  static List<GroupDto> listFromJson(Map<String, dynamic> data) {
    final raw = data['group'] ?? data['groups'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) GroupDto.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// 外部源 / CardDAV 账号（`ExternalSource/list`）。
///
/// ## 字段与状态语义（两处都是打包产物里的**明文 JS**原文）
///
/// 1. 列表项 → 内部模型的映射，`SYNO.Contacts` 网页客户端
///    `ui/static/js/main.js` 的 `kD()`：
///
/// ```js
/// function kD(e,t){t.external_sources.forEach(function(t){
///   var n=e.find(function(e){return t.addressbook_id===e.id});
///   n&&(n.source=t.source, n.sync_status=t.status,
///        n.user_name=t.username, n.last_update=t.update_time);
/// })}
/// ```
///   ⇒ `ExternalSource/list` 每一项给
///   `addressbook_id` / `source` / `status` / `username` / `update_time`
///   （`source` 是字符串 `carddav`/`google`/`outlook`/`yahoo`/`book`；
///   `update_time` 是 **epoch 秒**，见下）。
///
/// 2. `status` 取值，同一个 `main.js` 的 `renderLastUpdate()`：
///
/// ```js
/// n.renderLastUpdate=function(e,t){
///   return e===ji ? ui("account_setting_dialog","status_fail")     // ji = -1
///        : e===Gi ? ui("account_setting_dialog","status_process")  // Gi =  1
///        : new Date(1e3*t).format("m/d/Y g:i a")                   // 0 → 上次更新时间
/// }
/// ```
///   常量表原文（同文件）：`... Mi=-1, Li=1, Fi=2, ji=-1, Gi=1;`
///   ⇒ `-1` = 同步失败（`status_fail`）、`1` = 正在处理（`status_process`）、
///   `0`（及其它无样本取值）= 正常，展示 `update_time` 的"上次更新"。
///   官方文案（`ui/texts/chs/strings` 的 `[account_setting_dialog]`）：
///   `last_update="上次更新"`、`status_fail="失败"`、`status_process="正在处理"`；
///   `enu` 依次为 `Last update` / `Failed` / `Processing`。
///
/// ⚠️ 除 `-1/1/0` 外的取值本机没有样本，一律按"正常"处理，**不猜**中间态。
class ExternalSourceDto {
  const ExternalSourceDto({
    required this.addressbookId,
    this.source = '',
    this.location = '',
    this.username = '',
    this.status = 0,
    this.isSync = false,
    this.lastSyncTime = '',
    this.updateTime = 0,
  });

  /// 官方 `status` 取值（`ji` / `Gi`，见类注释）
  static const int statusFailed = -1;
  static const int statusProcessing = 1;

  final String addressbookId;

  /// `carddav` / `google` / `outlook` / `yahoo` / `book`
  final String source;

  /// CardDAV 的服务器地址。`list` 回包里**没有**这一项（只有 `create/set` 发），
  /// 留着是为了兼容服务端将来回显与 UI 展示
  final String location;
  final String username;

  /// 见类注释：`-1` 失败 / `1` 处理中 / `0` 正常
  final int status;

  /// `ExternalSource/list` 不回 `is_sync`（官方映射里没有这一项）→ 只容错解析，
  /// **不作为门控**
  final bool isSync;

  /// 上次同步时间的**原样字符串**（服务端现在给 epoch 秒，见 [updateTime]）
  final String lastSyncTime;

  /// `update_time`：**epoch 秒**（官方 `new Date(1e3*t)`）
  final int updateTime;

  bool get isCardDav => source.toLowerCase().contains('carddav');
  bool get isGoogle => source.toLowerCase() == 'google';
  bool get isOutlook => source.toLowerCase() == 'outlook';

  /// 同步失败（`status == -1`）
  bool get hasFailed => status == statusFailed;

  /// 正在处理（`status == 1`）
  bool get isProcessing => status == statusProcessing;

  /// 上次同步时间（epoch 秒 → 本地时间）；`null` = 服务端没给
  DateTime? get lastUpdatedAt => updateTime > 0
      ? DateTime.fromMillisecondsSinceEpoch(updateTime * 1000)
      : null;

  factory ExternalSourceDto.fromJson(Map<String, dynamic> json) =>
      ExternalSourceDto(
        addressbookId: '${json['addressbook_id'] ?? json['id'] ?? ''}',
        source: '${json['source'] ?? json['type'] ?? ''}',
        location: '${json['addressbook_location'] ?? json['location'] ?? ''}',
        username: '${json['username'] ?? ''}',
        status: _int(json['status']),
        isSync: json['is_sync'] == true,
        lastSyncTime: '${json['update_time'] ?? json['last_update'] ?? ''}',
        updateTime: _int(json['update_time'] ?? json['last_update']),
      );

  /// 空列表是**正常状态**（本机真机 `list` 就回
  /// `{"external_sources":[],"total":0}`，见 `docs/live-nas-verification.md` §6.2），
  /// **不是错误**：`[]` 与"键缺失"都给空列表。
  static List<ExternalSourceDto> listFromJson(Map<String, dynamic> data) {
    final raw = data['external_sources'] ?? data['external_source'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) ExternalSourceDto.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// 组织单位（`SYNO.Contacts.OU/list`）—— 官方网页版左侧"组织单位"树的原始数据。
///
/// 形状与调用都取自官方 `ui/static/js/main.js` 里唯一一处调用与消费：
///
/// ```js
/// // 调用（LD）：参数就这三个
/// Ht(Hn.send,"listOrganizationUnit",{limit:100,offset:0,addressbook_id:t})
/// // 消费（ID）：每项有 id/dn/principal，树按 dn 拼
/// function ID(e,t){ ... var n={},r=e.ou, ...
///   r.forEach((function(e){ ... n[i]={id:"ou".concat(e.id),children:[],
///     name:l,principal:e.principal.filter(...)} ... })) }
/// ```
///
/// ⇒ 每项至少 `id`、`dn`（如 `OU=Sales,DC=example,DC=com`）、`principal`（用户 id）；
/// 层级由 `dn` 里的 `OU=` 段推出，**服务端不给 name**（display name 是 `dn` 里最靠左
/// 的 `OU=` 段）。真机（`docs/live-nas-verification.md` §6.2）：不带
/// `addressbook_id` 直接回 **120** ⇒ `addressbook_id` 必填。
class OuDto {
  const OuDto({
    required this.id,
    this.dn = '',
    this.name = '',
    this.principalIds = const [],
  });

  final String id;

  /// 可分辨名称，例：`OU=Sales,OU=HQ,DC=example,DC=com`
  final String dn;

  /// `dn` 最靠左的 `OU=` 段（服务端不回 name）
  final String name;

  /// 该 OU 下的用户 id（官方 `principal`）
  final List<String> principalIds;

  /// 上一级 OU 的 `dn`（`dn` 去掉最左一段）；空 = 根
  String get parentDn {
    final i = dn.indexOf(',');
    return i < 0 ? '' : dn.substring(i + 1);
  }

  /// `dn` 的 `OU=` 段数（层级深度）
  int get depth => RegExp(r'OU=', caseSensitive: false).allMatches(dn).length;

  factory OuDto.fromJson(Map<String, dynamic> json) {
    final dn = '${json['dn'] ?? ''}';
    return OuDto(
      id: '${json['id'] ?? ''}',
      dn: dn,
      name: ouNameFromDn(dn),
      principalIds: _ids(json['principal']),
    );
  }

  /// `dn` 最靠左的 `OU=` 段：`OU=Sales,OU=HQ,DC=x` → `Sales`。
  ///
  /// 值里的**转义逗号/反斜杠**要按官方 `replace(/\\([\S\s])/g,"$1")` 还原，
  /// 所以不能简单地在第一个 `,` 处截断（`OU=Sa\,les,DC=x` 的名字是 `Sa,les`）。
  static String ouNameFromDn(String dn) {
    final m = RegExp(r'^\s*OU=', caseSensitive: false).matchAsPrefix(dn);
    if (m == null) return '';
    final buf = StringBuffer();
    var i = m.end;
    while (i < dn.length) {
      final c = dn[i];
      if (c == r'\' && i + 1 < dn.length) {
        buf.write(dn[i + 1]);
        i += 2;
        continue;
      }
      if (c == ',') break;
      buf.write(c);
      i++;
    }
    return buf.toString().trim();
  }

  static List<OuDto> listFromJson(Map<String, dynamic> data) {
    final raw = data['ou'] ?? data['ous'] ?? data['organization_unit'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) OuDto.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// 可共享主体（用户 / 群组）：`Addressbook/list_principal`
class PrincipalDto {
  const PrincipalDto({
    required this.id,
    required this.accountName,
    required this.displayName,
    this.type = 0,
    this.isShared = false,
    this.memberIds = const [],
  });

  final String id;
  final String accountName;
  final String displayName;

  /// 2 = 群组（真机：`syno.contacts.internal.everyone` type=2）
  final int type;
  final bool isShared;
  final List<String> memberIds;

  bool get isGroup => type == 2;

  factory PrincipalDto.fromJson(Map<String, dynamic> json) => PrincipalDto(
    id: '${json['id'] ?? ''}',
    accountName: '${json['account_name'] ?? json['name'] ?? ''}',
    displayName: '${json['display_name'] ?? json['account_name'] ?? ''}',
    type: _int(json['type']),
    isShared: json['is_shared'] == true,
    memberIds: _ids(json['member']),
  );

  static List<PrincipalDto> listFromJson(Map<String, dynamic> data) {
    final raw = data['principal'] ?? data['principals'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) PrincipalDto.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// 导入预览的一条：`Addressbook/import_preview`
class ImportPreviewDto {
  const ImportPreviewDto({
    required this.fullName,
    this.primaryMail = '',
    this.status = 0,
  });

  final String fullName;
  final String primaryMail;

  /// 真机取样都是 1；官方 UI 用它区分"新增 / 重复"（按"有邮箱且非新增"显示重复）
  final int status;

  /// 是否可能已存在（官方口径：非新增状态）
  bool get maybeDuplicate => status != 1;

  factory ImportPreviewDto.fromJson(Map<String, dynamic> json) =>
      ImportPreviewDto(
        fullName: '${json['full_name'] ?? json['name'] ?? ''}',
        primaryMail: '${json['primary_mail'] ?? ''}',
        status: _int(json['status']),
      );

  static List<ImportPreviewDto> listFromJson(Map<String, dynamic> data) {
    final raw = data['contact'] ?? data['contacts'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) ImportPreviewDto.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// 联系人可编辑字段（新建 / 编辑共用）。
///
/// 官方编辑器口径（bundle 里的默认对象 + 真机 round-trip）：
/// `full_name`、`name{given,family,prefix,suffix,additional}`、
/// `mail[]`/`tel[]`/`url[]`/`date[]`/`im[]`（元素 `{data}`）、`adr[]`（元素 `{data:{…}}`）、
/// `company`、`department`、`title`、`birthday`、`note`、`photo`。
class ContactInput {
  const ContactInput({
    this.fullName = '',
    this.givenName = '',
    this.familyName = '',
    this.prefix = '',
    this.suffix = '',
    this.additionalName = '',
    this.nickName = '',
    this.mail = const [],
    this.tel = const [],
    this.url = const [],
    this.im = const [],
    this.date = const [],
    this.adr = const [],
    this.company = '',
    this.department = '',
    this.title = '',
    this.birthday = '',
    this.note = '',
    this.photo = '',
  });

  final String fullName;
  final String givenName;
  final String familyName;
  final String prefix;
  final String suffix;
  final String additionalName;
  final String nickName;
  final List<String> mail;
  final List<String> tel;
  final List<String> url;
  final List<String> im;
  final List<String> date;

  /// 每条是 `{street, city, state, postal_code, country}` 拍平后的一个字符串（换行分隔）
  final List<String> adr;
  final String company;
  final String department;
  final String title;
  final String birthday;
  final String note;

  /// data URL（`data:image/png;base64,…`）；空 = 不改
  final String photo;

  /// 表单值：**嵌套结构一律 JSON 字符串**（我们的传输层是 form-urlencoded，
  /// 服务端按 JSON 解析这些值 —— 真机验过 `name{}`/`mail[]`/`tel[]` round-trip）。
  Map<String, String> toParams() {
    final out = <String, String>{
      'full_name': fullName,
      'name': jsonEncode({
        'given_name': givenName,
        'family_name': familyName,
        'prefix': prefix,
        'suffix': suffix,
        'additional_name': additionalName,
      }),
      if (nickName.isNotEmpty) 'nick_name': nickName,
      'mail': jsonEncode([
        for (final v in _nonEmpty(mail)) {'data': v},
      ]),
      'tel': jsonEncode([
        for (final v in _nonEmpty(tel)) {'data': v},
      ]),
      'url': jsonEncode([
        for (final v in _nonEmpty(url)) {'data': v},
      ]),
      'im': jsonEncode([
        for (final v in _nonEmpty(im)) {'data': v},
      ]),
      'date': jsonEncode([
        for (final v in _nonEmpty(date)) {'data': v},
      ]),
      'adr': jsonEncode([
        for (final v in _nonEmpty(adr))
          {
            'data': {'street': v},
          },
      ]),
      'company': company,
      'department': department,
      'title': title,
      'birthday': birthday,
      'note': note,
      if (photo.isNotEmpty) 'photo': photo,
    };
    return out;
  }

  static List<String> _nonEmpty(List<String> xs) => [
    for (final x in xs)
      if (x.trim().isNotEmpty) x.trim(),
  ];

  ContactInput copyWith({
    String? fullName,
    String? givenName,
    String? familyName,
    String? prefix,
    String? suffix,
    String? additionalName,
    String? nickName,
    List<String>? mail,
    List<String>? tel,
    List<String>? url,
    List<String>? im,
    List<String>? date,
    List<String>? adr,
    String? company,
    String? department,
    String? title,
    String? birthday,
    String? note,
    String? photo,
  }) => ContactInput(
    fullName: fullName ?? this.fullName,
    givenName: givenName ?? this.givenName,
    familyName: familyName ?? this.familyName,
    prefix: prefix ?? this.prefix,
    suffix: suffix ?? this.suffix,
    additionalName: additionalName ?? this.additionalName,
    nickName: nickName ?? this.nickName,
    mail: mail ?? this.mail,
    tel: tel ?? this.tel,
    url: url ?? this.url,
    im: im ?? this.im,
    date: date ?? this.date,
    adr: adr ?? this.adr,
    company: company ?? this.company,
    department: department ?? this.department,
    title: title ?? this.title,
    birthday: birthday ?? this.birthday,
    note: note ?? this.note,
    photo: photo ?? this.photo,
  );

  factory ContactInput.fromDetail(ContactDetailDto d) => ContactInput(
    fullName: d.fullName,
    givenName: d.givenName,
    familyName: d.familyName,
    prefix: d.prefix,
    suffix: d.suffix,
    additionalName: d.additionalName,
    nickName: d.nickName,
    mail: d.mail,
    tel: d.tel,
    url: d.url,
    im: d.im,
    date: d.date,
    adr: d.adr,
    company: d.company,
    department: d.department,
    title: d.title,
    birthday: d.birthday,
    note: d.note,
    photo: d.photo,
  );
}

/// 详情里的可编辑字段（`additional.contact_detail`）
class ContactDetailDto {
  const ContactDetailDto({
    this.fullName = '',
    this.givenName = '',
    this.familyName = '',
    this.prefix = '',
    this.suffix = '',
    this.additionalName = '',
    this.nickName = '',
    this.mail = const [],
    this.tel = const [],
    this.url = const [],
    this.im = const [],
    this.date = const [],
    this.adr = const [],
    this.company = '',
    this.department = '',
    this.title = '',
    this.birthday = '',
    this.note = '',
    this.photo = '',
  });

  final String fullName;
  final String givenName;
  final String familyName;
  final String prefix;
  final String suffix;
  final String additionalName;
  final String nickName;
  final List<String> mail;
  final List<String> tel;
  final List<String> url;
  final List<String> im;
  final List<String> date;
  final List<String> adr;
  final String company;
  final String department;
  final String title;
  final String birthday;
  final String note;
  final String photo;

  factory ContactDetailDto.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ContactDetailDto(
      fullName: '${json['full_name'] ?? ''}',
      givenName: '${name['given_name'] ?? ''}',
      familyName: '${name['family_name'] ?? ''}',
      prefix: '${name['prefix'] ?? ''}',
      suffix: '${name['suffix'] ?? ''}',
      additionalName: '${name['additional_name'] ?? ''}',
      nickName: '${json['nick_name'] ?? ''}',
      mail: _dataList(json['mail']),
      tel: _dataList(json['tel']),
      url: _dataList(json['url']),
      im: _dataList(json['im']),
      date: _dataList(json['date']),
      adr: _adrList(json['adr']),
      company: '${json['company'] ?? ''}',
      department: '${json['department'] ?? ''}',
      title: '${json['title'] ?? ''}',
      birthday: '${json['birthday'] ?? ''}',
      note: '${json['note'] ?? ''}',
      photo: '${json['photo'] ?? ''}',
    );
  }
}

/// `[{data:…, is_readonly:bool}]` → `[data]`
List<String> _dataList(Object? raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final e in raw) {
    if (e is String && e.isNotEmpty) {
      out.add(e);
    } else if (e is Map) {
      final d = e['data'] ?? e['value'];
      if (d is String && d.isNotEmpty) {
        out.add(d);
      }
    }
  }
  return out;
}

/// `adr` 的元素是 `{data:{street,city,state,postal_code,country}}` → 拼一行给人看
List<String> _adrList(Object? raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final e in raw) {
    if (e is String && e.isNotEmpty) {
      out.add(e);
      continue;
    }
    if (e is! Map) continue;
    final d = e['data'];
    if (d is String && d.isNotEmpty) {
      out.add(d);
    } else if (d is Map) {
      final parts = [
        for (final k in ['street', 'city', 'state', 'postal_code', 'country'])
          if ('${d[k] ?? ''}'.trim().isNotEmpty) '${d[k]}'.trim(),
      ];
      if (parts.isNotEmpty) out.add(parts.join(', '));
    }
  }
  return out;
}

List<String> _ids(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e != null && '$e'.isNotEmpty) '$e',
  ];
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v) ?? 0;
  if (v is num) return v.toInt();
  return 0;
}
