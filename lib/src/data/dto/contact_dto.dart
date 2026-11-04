// Synology Contacts 的数据模型。
//
// 真机回包形状（2026-09-18 实测，`docs/api-server-authoritative.md` §5.3）：
//   * `Addressbook/list` v1 `{offset,limit}` → `{"addressbook":[{...}], "total":n}`
//     —— **键是单数 `addressbook`**（不是 `addressbooks`），值是数组；
//   * `Contact/list` v2 `{offset,limit[,addressbook_id]}` → `{"contact":[{...}]}`
//     —— 同样是单数键 + 数组；
//   * `Contact/get` v2 `{ids:'[1]'}`（**JSON 数组字符串**）→ `{"contact":[…]}`，
//     每个元素多一个 `additional.contact_detail`（`mail[]` / `tel[]` / `name{}` / `note`）。
//
// 字段一律容错：服务端给 `null`、给数字、缺字段都不能让页面崩。
import 'dart:convert';

import 'contact_extras_dto.dart';

/// 通讯录（`Addressbook/list` 的一条）
class AddressbookDto {
  const AddressbookDto({
    required this.id,
    required this.name,
    this.type = 0,
    this.mode = 0,
    this.memberCount = 0,
    this.ownedShared = false,
    this.sharedFrom = '',
    this.sharedWith = '',
    this.uri = '',
    this.status = 0,
  });

  final String id;
  final String name;

  /// 真机实测（2026-09-21）：**2 = Suggested、3 = 个人、4 = 团队/公开**（只影响图标与分组）
  final int type;
  final int mode;
  final int memberCount;
  final bool ownedShared;
  final String sharedFrom;
  final String sharedWith;

  /// 通讯录的 uuid —— **CardDAV 地址的最后一段**（`/carddav/<user>/<uri>`）
  final String uri;

  /// `set_addressbook_display` 里的那个 `status`。
  ///
  /// ⚠️ 真机实测（2026-09-19）：**默认值是 2**，`set_addressbook_display` 只是把它
  /// 原样写回（0/1/2 都写进去了）。**0/1/2 各自代表什么没有确证** ——
  /// 千万别拿 `status != 0` 当"已隐藏"用（那样三本通讯录全被显示成"已隐藏"，
  /// 真机上已经踩过这个坑）。所以 UI 不展示、也不改它。
  final int status;

  bool get isShared =>
      mode == 3 || sharedFrom.isNotEmpty || sharedWith.isNotEmpty;

  factory AddressbookDto.fromJson(Map<String, dynamic> json) => AddressbookDto(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    type: _int(json['type']),
    mode: _int(json['mode']),
    memberCount: _int(json['member_count']),
    ownedShared: json['owned_shared'] == true,
    sharedFrom: '${json['shared_from'] ?? ''}',
    sharedWith: '${json['shared_with'] ?? ''}',
    uri: '${json['uri'] ?? ''}',
    status: _int(json['status']),
  );

  static List<AddressbookDto> listFromJson(Map<String, dynamic> data) {
    final raw = data['addressbook'] ?? data['addressbooks'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) AddressbookDto.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// 联系人（列表项 + 详情共用；详情多的字段放 [mail]/[tel]/[note]）
class ContactDto {
  const ContactDto({
    required this.id,
    required this.addressbookId,
    required this.fullName,
    this.company = '',
    this.department = '',
    this.title = '',
    this.primaryMail = '',
    this.primaryTel = '',
    this.isEditable = false,
    this.isHidden = false,
    this.photo = '',
    this.labels = const [],
    this.labelIds = const [],
    this.mail = const [],
    this.tel = const [],
    this.note = '',
    this.detail,
    this.addressbookName = '',
    this.addressbookOwner = '',
    this.addressbookCategory = '',
  });

  final String id;
  final String addressbookId;
  final String fullName;
  final String company;
  final String department;
  final String title;
  final String primaryMail;
  final String primaryTel;
  final bool isEditable;

  /// 被隐藏（团队通讯录里的用户记录可以隐藏）—— `is_hidden`
  final bool isHidden;

  /// 详情接口给的 `additional.contact_detail.photo`（空串 = 没有头像）
  final String photo;
  final List<String> labels;

  /// 标签 id（星标就是"在系统 Starred 标签里"，判星标要看 id 而不是名字）
  final List<String> labelIds;

  /// 详情接口才有的多值邮箱/电话（`mail[{data,is_readonly}]`）
  final List<String> mail;
  final List<String> tel;
  final String note;

  /// `additional.contact_detail`（编辑表单要用的完整字段）
  final ContactDetailDto? detail;

  /// 官方详情/列表在部分场景会给这几个（真机 `/get` 没给 → 全部可选）
  final String addressbookName;
  final String addressbookOwner;
  final String addressbookCategory;

  /// 列表/详情里第一个能用的邮箱、电话（列表项自带 `primary_*`）
  String get bestMail => primaryMail.isNotEmpty
      ? primaryMail
      : (mail.isNotEmpty ? mail.first : '');

  String get bestTel =>
      primaryTel.isNotEmpty ? primaryTel : (tel.isNotEmpty ? tel.first : '');

  /// 头像占位用的首字（中文取第一个字，英文取名字首字母）
  String get initials {
    final n = fullName.trim();
    if (n.isEmpty) return '?';
    return n.substring(0, 1).toUpperCase();
  }

  /// 副标题：单位/部门/职务里挑有的拼起来
  String get subtitle =>
      [company, department, title].where((s) => s.isNotEmpty).join(' · ');

  factory ContactDto.fromJson(Map<String, dynamic> json) {
    final add = (json['additional'] as Map?)?.cast<String, dynamic>() ?? {};
    final detail =
        (add['contact_detail'] as Map?)?.cast<String, dynamic>() ?? {};
    return ContactDto(
      id: '${json['id'] ?? ''}',
      addressbookId: '${json['addressbook_id'] ?? ''}',
      fullName: '${json['full_name'] ?? detail['full_name'] ?? ''}',
      company: '${json['company'] ?? ''}',
      department: '${json['department'] ?? ''}',
      title: '${json['title'] ?? ''}',
      primaryMail: '${json['primary_mail'] ?? ''}',
      primaryTel: '${json['primary_tel'] ?? ''}',
      isEditable: json['is_editable'] == true,
      isHidden: json['is_hidden'] == true,
      photo: '${detail['photo'] ?? json['photo'] ?? ''}',
      labels: _labelNames(add['label']),
      labelIds: _labelIds(add['label']),
      mail: _dataList(detail['mail']),
      tel: _dataList(detail['tel']),
      note: '${detail['note'] ?? ''}',
      detail: detail.isEmpty ? null : ContactDetailDto.fromJson(detail),
      addressbookName: '${json['addressbook_name'] ?? ''}',
      addressbookOwner: '${json['addressbook_owner'] ?? ''}',
      addressbookCategory: '${json['addressbook_category'] ?? ''}',
    );
  }

  /// `additional.label` 既可能是 `[]`、也可能是 `[{name:…}]` 或 `["标签"]`
  static List<String> _labelNames(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final e in raw) {
      if (e is String && e.isNotEmpty) {
        out.add(e);
      } else if (e is Map) {
        final n = e['name'] ?? e['label_name'];
        if (n is String && n.isNotEmpty) out.add(n);
      }
    }
    return out;
  }

  /// `additional.label` 里的标签 id（可能是 `[{id,name,type}]`）
  static List<String> _labelIds(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final e in raw) {
      if (e is Map) {
        final id = e['id'] ?? e['label_id'];
        if (id != null && '$id'.isNotEmpty) out.add('$id');
      }
    }
    return out;
  }

  /// `mail`/`tel` 是 `[{data:…, is_readonly:bool}]`
  static List<String> _dataList(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final e in raw) {
      if (e is String && e.isNotEmpty) {
        out.add(e);
      } else if (e is Map) {
        final d = e['data'] ?? e['value'];
        if (d is String && d.isNotEmpty) out.add(d);
      }
    }
    return out;
  }

  static List<ContactDto> listFromJson(Map<String, dynamic> data) {
    final raw = data['contact'] ?? data['contacts'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) ContactDto.fromJson(e.cast<String, dynamic>()),
    ];
  }
}

/// 联系人接口里到处是"数字或字符串"的 id，统一转字符串
int _int(Object? v) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v) ?? 0;
  if (v is num) return v.toInt();
  return 0;
}

/// （给测试用）把 id 列表编码成官方要的 JSON 数组字符串
String encodeContactIds(List<String> ids) =>
    jsonEncode([for (final id in ids) id]);
