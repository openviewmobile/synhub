// Synology Contacts 客户端（`SYNO.Contacts.*`）—— 读 + 写 + 导入导出 + CardDAV。
//
// 参数形态以**真机**为准（2026-09-21，NAS nas.example.com / DSM 7.4，账号 demo_user），
// 逐条取证记录在 `docs/contacts-module-plan.md` §3.1；官方网页客户端的 bundle 抽取
// 见 `docs/recheck/contacts-webclient-params.md`。两者冲突时**以真机为准**。
//
// 几条容易踩的（都实测过）：
//   * 回包的键基本是**单数**：`addressbook` / `contact` / `label` / `group` /
//     `principal`，只有外部源是复数 `external_sources`；
//   * `Contact/get` 要 **v2**，`ids` 是 JSON 数组字符串；给 `id`/`contact_id` 都回 **120**；
//   * `Label/*` 全部 **v2**；`Label/list` 里 `type:1` 是系统「Starred」、`type:0` 是用户标签；
//   * **星标 = 给 Starred 标签加成员**（`Label/add_member {ids:[starId], contact_ids}`）；
//     `Contact/toggle_*` 是**显示/隐藏**（`is_hidden`），不是星标；
//   * `Addressbook/create` 的 `is_public` 必须是**小写** `'false'`/`'true'`（`'False'` → 120）；
//   * `Addressbook/import` 的目标通讯录 id 放**查询串**（`id`），而 `import_preview` 放
//     **表单字段** `addressbook_id`；两者都是 multipart，文件字段名 `file`；
//   * 导出（`Addressbook/export` / `Label/export`）回 `text/vcard` **字节**，
//     走带 `_sid` 的直链下载，不是 entry.cgi 的 JSON 接口；
//   * 嵌套值（`name{}` / `mail[]` / `ids[]`）一律 **JSON 字符串** —— 传输层是
//     form-urlencoded，服务端按 JSON 解析这些值（真机 round-trip 验过）。
import 'dart:convert';

import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/contact_dto.dart';
import 'dto/contact_extras_dto.dart';

/// `Contact/list` 的排序键（服务端只认这两个，真机验过）
enum ContactSort { fullName, company }

class ContactsApi {
  ContactsApi(DsmWebApi api) : api = api.withModule(TrafficModules.contacts);

  final DsmWebApi api;

  int _negotiate(String apiName, List<int> candidates) {
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

  int _v(String apiName, List<int> candidates) =>
      _negotiate(apiName, candidates);

  // ------------------------------------------------------------------ 读

  /// `Addressbook/list`（v1）—— 通讯录列表。
  Future<List<AddressbookDto>> addressbooks({
    int offset = 0,
    int limit = 100,
  }) async {
    final data = await api.call(
      'SYNO.Contacts.Addressbook',
      'list',
      preferredVersion: _v('SYNO.Contacts.Addressbook', const [1]),
      params: {'offset': '$offset', 'limit': '$limit'},
    );
    return AddressbookDto.listFromJson(data);
  }

  /// `Contact/list`（v2 优先）—— 联系人列表；支持服务端搜索 / 排序 / 按标签、群组过滤。
  Future<List<ContactDto>> contacts({
    String? addressbookId,
    String? labelId,
    String? groupId,
    String keyword = '',
    ContactSort sort = ContactSort.fullName,
    bool descending = false,
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.Contacts.Contact',
      'list',
      preferredVersion: _v('SYNO.Contacts.Contact', const [2, 1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'sort_by': sort == ContactSort.company ? 'company' : 'full_name',
        'sort_direction': descending ? 'desc' : 'asc',
        if (addressbookId != null && addressbookId.isNotEmpty)
          'addressbook_id': addressbookId,
        if (labelId != null && labelId.isNotEmpty) 'label_id': labelId,
        if (groupId != null && groupId.isNotEmpty) 'group_id': groupId,
        // 服务端搜索：`keyword` 是 JSON **数组**
        if (keyword.trim().isNotEmpty) 'keyword': jsonEncode([keyword.trim()]),
      },
    );
    return ContactDto.listFromJson(data);
  }

  /// `Contact/get`（**v2**）—— 单个联系人详情。
  ///
  /// 真机口径：参数名是 `ids`、值是 JSON 数组字符串（`'[1]'`），回包的键是数组
  /// `contact`（即使只查一个）。给 `id` / `contact_id` 都回 120。
  Future<ContactDto?> contact(String id) async {
    final data = await api.call(
      'SYNO.Contacts.Contact',
      'get',
      preferredVersion: _v('SYNO.Contacts.Contact', const [2, 1]),
      params: {
        'ids': encodeContactIds([id]),
      },
    );
    final list = ContactDto.listFromJson(data);
    return list.isEmpty ? null : list.first;
  }

  /// `Contact/get_photo`（v1）—— **参数是 `contact_ids`**（`ids`/`id` 都回 120）。
  ///
  /// 回 `{photo:[{id, photo}]}`，`photo` 是 data URL（没头像就是空串）。
  Future<Map<String, String>> photos(List<String> contactIds) async {
    if (contactIds.isEmpty) return const {};
    final data = await api.call(
      'SYNO.Contacts.Contact',
      'get_photo',
      preferredVersion: _v('SYNO.Contacts.Contact', const [1]),
      params: {'contact_ids': encodeContactIds(contactIds)},
    );
    final raw = data['photo'];
    final out = <String, String>{};
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          final id = '${e['id'] ?? ''}';
          final p = '${e['photo'] ?? ''}';
          if (id.isNotEmpty && p.isNotEmpty) out[id] = p;
        }
      }
    }
    return out;
  }

  /// `Label/list`（**v2**）
  Future<List<LabelDto>> labels({String? addressbookId}) async {
    final data = await api.call(
      'SYNO.Contacts.Label',
      'list',
      preferredVersion: _v('SYNO.Contacts.Label', const [2, 1]),
      params: {
        if (addressbookId != null && addressbookId.isNotEmpty)
          'addressbook_id': addressbookId,
      },
    );
    return LabelDto.listFromJson(data);
  }

  /// `Contact/list_group`（v1）
  Future<List<GroupDto>> groups({required String addressbookId}) async {
    final data = await api.call(
      'SYNO.Contacts.Contact',
      'list_group',
      preferredVersion: _v('SYNO.Contacts.Contact', const [1]),
      params: {'addressbook_id': addressbookId},
    );
    return GroupDto.listFromJson(data);
  }

  /// `Contact/list_group` 之外的**组织单位**树：`SYNO.Contacts.OU/list`（v1）。
  ///
  /// 参数原文（官方 `ui/static/js/main.js` 的 `LD()`）：
  /// `{limit:100, offset:0, addressbook_id:t}` —— 真机不带 `addressbook_id`
  /// 直接回 **120**（`docs/live-nas-verification.md` §6.2），所以是必填。
  /// 回包键是 `ou`（官方 `ID()` 读 `e.ou`）。
  Future<List<OuDto>> organizationUnits({
    required String addressbookId,
    int offset = 0,
    int limit = 100,
  }) async {
    final data = await api.call(
      'SYNO.Contacts.OU',
      'list',
      preferredVersion: _v('SYNO.Contacts.OU', const [1]),
      params: {
        'limit': '$limit',
        'offset': '$offset',
        'addressbook_id': addressbookId,
      },
    );
    return OuDto.listFromJson(data);
  }

  /// `ExternalSource/list`（v1）—— 外部源 / CardDAV 账号（**只读**）。
  ///
  /// 官方 `main.js` 里唯一调用点的参数是 **`{}`**
  /// （`Ht(Hn.send,"listExternalSource",{})`）——不传任何过滤条件。
  /// 真机回 `{"external_sources":[],"total":0}` = **未配置**，是正常空态。
  ///
  /// ⚠️ **`ExternalSource/get` 未实现**：方法表里有（`SYNO.Contacts.so` 的
  /// `external_source::Get_v1`），但官方 JS **没有任何调用点**，参数名取不到；
  /// 真机对任意猜测入参回 **120**（且 `errors` 是空对象，不回显参数名），
  /// 见 `docs/live-nas-verification.md` §6.2。按"无原文证据不实现"的纪律登记为
  /// 待取证；列表项已经带全 UI 需要的字段（`source`/`status`/`username`/
  /// `update_time`），所以没有它也能完成"列表 + 状态"的只读能力。
  Future<List<ExternalSourceDto>> externalSources() async {
    final data = await api.call(
      'SYNO.Contacts.ExternalSource',
      'list',
      preferredVersion: _v('SYNO.Contacts.ExternalSource', const [1]),
      params: const {},
    );
    return ExternalSourceDto.listFromJson(data);
  }

  /// `Addressbook/list_principal`（v1）—— 能共享给谁（用户 / 群组）
  Future<List<PrincipalDto>> principals({required String addressbookId}) async {
    final data = await api.call(
      'SYNO.Contacts.Addressbook',
      'list_principal',
      preferredVersion: _v('SYNO.Contacts.Addressbook', const [1]),
      params: {'limit': '100', 'offset': '0', 'addressbook_id': addressbookId},
    );
    return PrincipalDto.listFromJson(data);
  }

  /// `Info/get`（**只有 v1**）—— 当前主体（账号/显示名）。
  Future<({String account, String displayName})> info() async {
    final data = await api.call(
      'SYNO.Contacts.Info',
      'get',
      preferredVersion: _v('SYNO.Contacts.Info', const [1]),
      params: const {},
    );
    final p = (data['principal'] as Map?)?.cast<String, dynamic>() ?? {};
    return (
      account: '${p['account_name'] ?? ''}',
      displayName: '${p['display_name'] ?? ''}',
    );
  }

  // ------------------------------------------------------------- 联系人写

  /// `Contact/create`（v1）—— **扁平字段 + addressbook_id**；回 `{id}`。
  Future<String> createContact({
    required String addressbookId,
    required ContactInput input,
  }) async {
    final data = await api.call(
      'SYNO.Contacts.Contact',
      'create',
      preferredVersion: _v('SYNO.Contacts.Contact', const [1]),
      params: {'addressbook_id': addressbookId, ...input.toParams()},
    );
    return '${data['id'] ?? ''}';
  }

  /// `Contact/set`（v1）—— `id` + 要改的字段
  Future<void> setContact({
    required String id,
    required ContactInput input,
  }) async {
    await api.call(
      'SYNO.Contacts.Contact',
      'set',
      preferredVersion: _v('SYNO.Contacts.Contact', const [1]),
      params: {'id': id, ...input.toParams()},
    );
  }

  /// `Contact/delete`（v1）
  Future<void> deleteContacts(List<String> ids) async {
    if (ids.isEmpty) return;
    await api.call(
      'SYNO.Contacts.Contact',
      'delete',
      preferredVersion: _v('SYNO.Contacts.Contact', const [1]),
      params: {'ids': encodeContactIds(ids)},
    );
  }

  /// `Contact/toggle_person`（v1）—— **显示/隐藏**（不是星标）
  Future<void> setContactsHidden(
    List<String> ids, {
    required bool hidden,
  }) async {
    if (ids.isEmpty) return;
    await api.call(
      'SYNO.Contacts.Contact',
      'toggle_person',
      preferredVersion: _v('SYNO.Contacts.Contact', const [1]),
      params: {
        'ids': encodeContactIds(ids),
        'is_hidden': hidden ? 'true' : 'false',
      },
    );
  }

  /// `Contact/toggle_group`（v1）—— 组织单位 / 群组节点的**显示/隐藏**。
  ///
  /// 参数原文（官方 `main.js` 的 `toggleGroup(ids, isHidden)`：
  /// `{ids:t, isHidden:n}`，saga 里 `Ht(Hn.send,"toggleGroup",{ids,is_hidden})`）
  /// ⇒ `{ids, is_hidden}`，`ids` 是 JSON 数组串（与 `toggle_person` 同口径）。
  Future<void> setGroupsHidden(List<String> ids, {required bool hidden}) async {
    if (ids.isEmpty) return;
    await api.call(
      'SYNO.Contacts.Contact',
      'toggle_group',
      preferredVersion: _v('SYNO.Contacts.Contact', const [1]),
      params: {
        'ids': encodeContactIds(ids),
        'is_hidden': hidden ? 'true' : 'false',
      },
    );
  }

  /// `Contact/toggle_member`（v1）—— 组织单位里**单个联系人**的显示/隐藏。
  ///
  /// 参数原文（官方 `main.js` 的 `MO()`：`Ht(Hn.send,"toggleMember",{id:t,is_hidden:n})`）
  /// ⇒ **`id` 是裸标量**（不是数组，和 `toggle_person` 不同），`is_hidden` 布尔。
  Future<void> setGroupMemberHidden(String id, {required bool hidden}) async {
    if (id.isEmpty) return;
    await api.call(
      'SYNO.Contacts.Contact',
      'toggle_member',
      preferredVersion: _v('SYNO.Contacts.Contact', const [1]),
      params: {'id': id, 'is_hidden': hidden ? 'true' : 'false'},
    );
  }

  // ------------------------------------------------------------- 通讯录写

  /// `Addressbook/create`（v1）—— `is_public` 必须**小写**；回 `{id}`。
  Future<String> createAddressbook({
    required String name,
    bool isPublic = false,
  }) async {
    final data = await api.call(
      'SYNO.Contacts.Addressbook',
      'create',
      preferredVersion: _v('SYNO.Contacts.Addressbook', const [1]),
      params: {'name': name, 'is_public': isPublic ? 'true' : 'false'},
    );
    return '${data['id'] ?? ''}';
  }

  /// `Addressbook/set`（v1）—— 改名
  Future<void> setAddressbook({
    required String id,
    required String name,
  }) async {
    await api.call(
      'SYNO.Contacts.Addressbook',
      'set',
      preferredVersion: _v('SYNO.Contacts.Addressbook', const [1]),
      params: {'id': id, 'name': name},
    );
  }

  /// `Addressbook/delete`（v1）
  Future<void> deleteAddressbook(String id) async {
    await api.call(
      'SYNO.Contacts.Addressbook',
      'delete',
      preferredVersion: _v('SYNO.Contacts.Addressbook', const [1]),
      params: {
        'ids': encodeContactIds([id]),
      },
    );
  }

  /// `Addressbook/copy_member`（v1）—— 复制到 `targetId` 指定的通讯录
  Future<void> copyContacts({
    required String targetId,
    required List<String> contactIds,
  }) async {
    if (contactIds.isEmpty) return;
    await api.call(
      'SYNO.Contacts.Addressbook',
      'copy_member',
      preferredVersion: _v('SYNO.Contacts.Addressbook', const [1]),
      params: {'id': targetId, 'contact_ids': encodeContactIds(contactIds)},
    );
  }

  /// `Addressbook/move_member`（v1）—— 移动到 `destId`（参数名是 `dest_id`）
  Future<void> moveContacts({
    required String destId,
    required List<String> contactIds,
  }) async {
    if (contactIds.isEmpty) return;
    await api.call(
      'SYNO.Contacts.Addressbook',
      'move_member',
      preferredVersion: _v('SYNO.Contacts.Addressbook', const [1]),
      params: {'dest_id': destId, 'contact_ids': encodeContactIds(contactIds)},
    );
  }

  /// `Addressbook/set_addressbook_display`（v1）—— 显示/隐藏与顺序。
  ///
  /// 真机口径：`addressbook_display_config` 是**数组**，元素
  /// `{addressbook_id, status}`（`status:0` 正常显示，非 0 隐藏）。
  Future<void> setAddressbookDisplay(
    List<({String id, int status})> config,
  ) async {
    if (config.isEmpty) return;
    await api.call(
      'SYNO.Contacts.Addressbook',
      'set_addressbook_display',
      preferredVersion: _v('SYNO.Contacts.Addressbook', const [1]),
      params: {
        'addressbook_display_config': jsonEncode([
          for (final c in config) {'addressbook_id': c.id, 'status': c.status},
        ]),
      },
    );
  }

  /// `Addressbook/share_addressbook`（v1）—— 共享给用户/群组。
  ///
  /// `sharing_addressbook_config` 的元素键是 **`id`**（主体 id，不是 principal_id）：
  /// `{id, mode, status}`。本 App 第一版只做"看谁被共享了 + 取消共享"，
  /// 完整共享 UI 见 `docs/contacts-module-plan.md`。
  Future<void> shareAddressbook({
    required String addressbookId,
    required List<({String principalId, int mode, int status})> config,
  }) async {
    await api.call(
      'SYNO.Contacts.Addressbook',
      'share_addressbook',
      preferredVersion: _v('SYNO.Contacts.Addressbook', const [1]),
      params: {
        'addressbook_id': addressbookId,
        'sharing_addressbook_config': jsonEncode([
          for (final c in config)
            {'id': c.principalId, 'mode': c.mode, 'status': c.status},
        ]),
      },
    );
  }

  // ----------------------------------------------------------------- 标签

  /// `Label/create`（v2）—— `color` 是 6 位 hex；回 `{id}`
  Future<String> createLabel({
    required String name,
    required String color,
  }) async {
    final data = await api.call(
      'SYNO.Contacts.Label',
      'create',
      preferredVersion: _v('SYNO.Contacts.Label', const [2]),
      params: {'name': name, 'color': _hex(color)},
    );
    return '${data['id'] ?? ''}';
  }

  /// `Label/set`（v2）—— 改名 / 换色
  Future<void> setLabel({
    required String id,
    required String name,
    required String color,
  }) async {
    await api.call(
      'SYNO.Contacts.Label',
      'set',
      preferredVersion: _v('SYNO.Contacts.Label', const [2]),
      params: {'id': id, 'name': name, 'color': _hex(color)},
    );
  }

  /// `Label/delete`（v2）
  Future<void> deleteLabel(String id) async {
    await api.call(
      'SYNO.Contacts.Label',
      'delete',
      preferredVersion: _v('SYNO.Contacts.Label', const [2]),
      params: {
        'ids': encodeContactIds([id]),
      },
    );
  }

  /// `Label/add_member`（v2）—— **星标**就是给系统 Starred 标签加成员
  Future<void> addLabelMembers({
    required List<String> labelIds,
    required List<String> contactIds,
  }) async {
    if (labelIds.isEmpty || contactIds.isEmpty) return;
    await api.call(
      'SYNO.Contacts.Label',
      'add_member',
      preferredVersion: _v('SYNO.Contacts.Label', const [2]),
      params: {
        'ids': encodeContactIds(labelIds),
        'contact_ids': encodeContactIds(contactIds),
      },
    );
  }

  /// `Label/remove_member`（v2）
  Future<void> removeLabelMembers({
    required List<String> labelIds,
    required List<String> contactIds,
  }) async {
    if (labelIds.isEmpty || contactIds.isEmpty) return;
    await api.call(
      'SYNO.Contacts.Label',
      'remove_member',
      preferredVersion: _v('SYNO.Contacts.Label', const [2]),
      params: {
        'ids': encodeContactIds(labelIds),
        'contact_ids': encodeContactIds(contactIds),
      },
    );
  }

  // ------------------------------------------------------------- 导入导出

  /// `Addressbook/import_preview`（v1，multipart）—— 只预览，不写库。
  ///
  /// 真机口径：目标通讯录放**表单字段 `addressbook_id`**（放 `id` 回 120）。
  Future<List<ImportPreviewDto>> importPreview({
    required String filePath,
    required String fileName,
    String? addressbookId,
  }) async {
    final raw = await api.postMultipart(
      api.apiPath('SYNO.Contacts.Addressbook'),
      query: _uploadQuery('import_preview'),
      fields: {
        if (addressbookId != null && addressbookId.isNotEmpty)
          'addressbook_id': addressbookId,
      },
      fileField: 'file',
      filePath: filePath,
      fileName: fileName,
      mimeType: 'text/vcard',
    );
    final data = api.decodeData(
      raw,
      'SYNO.Contacts.Addressbook.import_preview',
    );
    return ImportPreviewDto.listFromJson(data);
  }

  /// `Addressbook/import`（v1，multipart）—— 真导入；回新建的联系人 id。
  ///
  /// 真机口径：目标通讯录放**查询串 `id`**（放表单 `addressbook_id` 回 120）。
  Future<List<String>> importVCard({
    required String filePath,
    required String fileName,
    required String addressbookId,
  }) async {
    final raw = await api.postMultipart(
      api.apiPath('SYNO.Contacts.Addressbook'),
      query: {..._uploadQuery('import'), 'id': addressbookId},
      fields: const {},
      fileField: 'file',
      filePath: filePath,
      fileName: fileName,
      mimeType: 'text/vcard',
    );
    final data = api.decodeData(raw, 'SYNO.Contacts.Addressbook.import');
    final ids = data['contact_ids'] ?? data['ids'];
    if (ids is List) return [for (final e in ids) '$e'];
    return const [];
  }

  /// `Addressbook/export`（v1）—— 回 **`text/vcard` 字节**
  Future<List<int>> exportAddressbook(String id) =>
      _export('SYNO.Contacts.Addressbook', const [1], id);

  /// `Label/export`（**v2**）—— 回 `text/vcard` 字节（"组/标签地址簿"导出）
  Future<List<int>> exportLabel(String id) =>
      _export('SYNO.Contacts.Label', const [2], id);

  Future<List<int>> _export(String apiName, List<int> versions, String id) {
    final url = api.authenticatedUrl(api.apiPath(apiName), {
      'api': apiName,
      'version': '${_v(apiName, versions)}',
      'method': 'export',
      'id': id,
    });
    if (url.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.internalError,
        method: '$apiName.export',
      );
    }
    return api.getBytes(url);
  }

  // -------------------------------------------------------- 外部源 / CardDAV

  /// `ExternalSource/create_carddav`（v1）—— 添加外部 CardDAV 账号。
  ///
  /// 官方口径（bundle 抽取）：`is_sync`、`import_type`、`addressbook_id`、
  /// `addressbook_location`(URL)、`username`、`pwd`；`import_type`：0 = 新建通讯录，
  /// 1 = 导入到已有通讯录（此时 `addressbook_id` 指定目标）。
  Future<void> createCardDav({
    required String location,
    required String username,
    required String password,
    int importType = 0,
    bool isSync = true,
    String? addressbookId,
  }) async {
    await api.call(
      'SYNO.Contacts.ExternalSource',
      'create_carddav',
      preferredVersion: _v('SYNO.Contacts.ExternalSource', const [1]),
      params: {
        'is_sync': isSync ? 'true' : 'false',
        'import_type': '$importType',
        if (addressbookId != null && addressbookId.isNotEmpty)
          'addressbook_id': addressbookId,
        'addressbook_location': location,
        'username': username,
        'pwd': password,
      },
    );
  }

  /// `ExternalSource/set_carddav`（v1）—— 改地址/账号/密码（无 is_sync/import_type）
  Future<void> setCardDav({
    required String addressbookId,
    required String location,
    required String username,
    required String password,
  }) async {
    await api.call(
      'SYNO.Contacts.ExternalSource',
      'set_carddav',
      preferredVersion: _v('SYNO.Contacts.ExternalSource', const [1]),
      params: {
        'addressbook_id': addressbookId,
        'addressbook_location': location,
        'username': username,
        'pwd': password,
      },
    );
  }

  /// `ExternalSource/refresh`（v1）—— **手动同步**（官方没有"同步间隔"设置）
  Future<void> syncExternalSource(String addressbookId) async {
    await api.call(
      'SYNO.Contacts.ExternalSource',
      'refresh',
      preferredVersion: _v('SYNO.Contacts.ExternalSource', const [1]),
      params: {'addressbook_id': addressbookId},
    );
  }

  // --------------------------------------------------------------- 小工具

  /// 上传类接口的查询串（真机验过：`html5upload=true` + 参数走查询串）。
  Map<String, dynamic> _uploadQuery(String method) => {
    'api': 'SYNO.Contacts.Addressbook',
    'version': '${_v('SYNO.Contacts.Addressbook', const [1])}',
    'method': method,
    'html5upload': 'true',
  };

  /// CardDAV 地址（**与官方网页版逐字一致**，从 bundle 里读出来的）：
  ///
  /// ```js
  /// short   = `${origin}/carddav/${user}`          // iOS / macOS 用这条
  /// general = `${origin}/carddav/${user}/${uri}`   // 其他客户端（绑定具体通讯录）
  /// ```
  ///
  /// `user` 里的 `\` 要转义成 `@@`（官方 `user.replace("\\", "@@")`）。
  ({String short, String general}) cardDavUrls({
    required String account,
    String addressbookUri = '',
    String? originOverride,
  }) {
    final origin = (originOverride ?? api.baseUrl).replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final user = account.replaceAll(r'\', '@@');
    final general = addressbookUri.isEmpty
        ? '$origin/carddav/$user'
        : '$origin/carddav/$user/$addressbookUri';
    return (short: '$origin/carddav/$user', general: general);
  }

  /// `#RRGGBB` / `RRGGBB` → `RRGGBB`（官方客户端发的是不带 `#` 的 6 位）
  static String _hex(String color) =>
      color.replaceAll('#', '').trim().toUpperCase();
}
