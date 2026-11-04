// 联系人模块的 provider 层。
//
// 事实来源：`lib/src/data/contacts_api.dart`（参数形态全部真机取证，
// 见 `docs/contacts-module-plan.md` §3.1）。
// Riverpod 3 默认的指数退避会让错误页永远出不来，所以统一 `retry: _noRetry`。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/contacts_api.dart';
import '../../data/dto/contact_dto.dart';
import '../../data/dto/contact_extras_dto.dart';
import '../servers/session_controller.dart';
import 'contacts_actions.dart';

/// Riverpod 3：返回 null = 不重试（和相册/笔记模块同口径）
Duration? _noRetry(int retryCount, Object error) => null;

/// 「未连接」哨兵：错误文案由 `describeContactsError` 按当前语言映射，
/// 所以抛出的 message 用**语言无关的标记**（不直接显示给用户）。
const String kContactsNotConnected = 'contacts_not_connected';

/// 「这台 NAS 没有 Starred 标签」的哨兵（同上，由 `describeContactsError` 出文案）。
const String kContactsNoStarredLabel = 'contacts_no_starred_label';

/// 联系人 API（未连接为 null → 页面说"未连接"而不是崩）
final contactsApiProvider = Provider<ContactsApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : ContactsApi(conn.api);
});

/// 通讯录列表（`Addressbook/list`）
final addressbooksProvider = FutureProvider.autoDispose<List<AddressbookDto>>((
  ref,
) async {
  final api = ref.watch(contactsApiProvider);
  if (api == null) throw StateError(kContactsNotConnected);
  return api.addressbooks();
}, retry: _noRetry);

/// 当前选中的通讯录（`null` = 全部）
final selectedAddressbookProvider =
    NotifierProvider<SelectedAddressbookNotifier, String?>(
      SelectedAddressbookNotifier.new,
    );

class SelectedAddressbookNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

/// 列表筛选条件（标签 / 关键字 / 排序）。通讯录选择单独放在
/// [selectedAddressbookProvider]（沿用原有语义，别的地方也在读）。
class ContactFilter {
  const ContactFilter({
    this.labelId,
    this.keyword = '',
    this.sort = ContactSort.fullName,
    this.descending = false,
  });

  final String? labelId;
  final String keyword;
  final ContactSort sort;
  final bool descending;

  ContactFilter copyWith({
    String? labelId,
    bool clearLabel = false,
    String? keyword,
    ContactSort? sort,
    bool? descending,
  }) => ContactFilter(
    labelId: clearLabel ? null : (labelId ?? this.labelId),
    keyword: keyword ?? this.keyword,
    sort: sort ?? this.sort,
    descending: descending ?? this.descending,
  );

  @override
  bool operator ==(Object other) =>
      other is ContactFilter &&
      other.labelId == labelId &&
      other.keyword == keyword &&
      other.sort == sort &&
      other.descending == descending;

  @override
  int get hashCode => Object.hash(labelId, keyword, sort, descending);
}

final contactFilterProvider =
    NotifierProvider<ContactFilterNotifier, ContactFilter>(
      ContactFilterNotifier.new,
    );

class ContactFilterNotifier extends Notifier<ContactFilter> {
  @override
  ContactFilter build() => const ContactFilter();

  void setLabel(String? labelId) =>
      state = state.copyWith(labelId: labelId, clearLabel: labelId == null);

  void setKeyword(String keyword) => state = state.copyWith(keyword: keyword);

  void setSort(ContactSort sort, {bool? descending}) =>
      state = state.copyWith(sort: sort, descending: descending);

  void clear() => state = const ContactFilter();
}

/// 联系人列表（通讯录 + 筛选条件；搜索与排序都由**服务端**做）
final contactsProvider = FutureProvider.autoDispose<List<ContactDto>>((
  ref,
) async {
  final api = ref.watch(contactsApiProvider);
  if (api == null) throw StateError(kContactsNotConnected);
  final filter = ref.watch(contactFilterProvider);
  return api.contacts(
    addressbookId: ref.watch(selectedAddressbookProvider),
    labelId: filter.labelId,
    keyword: filter.keyword,
    sort: filter.sort,
    descending: filter.descending,
  );
}, retry: _noRetry);

/// 联系人详情（`Contact/get` v2，`ids` 是 JSON 数组字符串）
final contactDetailProvider = FutureProvider.autoDispose
    .family<ContactDto?, String>((ref, id) async {
      final api = ref.watch(contactsApiProvider);
      if (api == null) throw StateError(kContactsNotConnected);
      return api.contact(id);
    }, retry: _noRetry);

/// 标签列表（`Label/list` v2；含系统「Starred」）
final labelsProvider = FutureProvider.autoDispose<List<LabelDto>>((ref) async {
  final api = ref.watch(contactsApiProvider);
  if (api == null) throw StateError(kContactsNotConnected);
  return api.labels();
}, retry: _noRetry);

/// 群组列表（`Contact/list_group`）
final groupsProvider = FutureProvider.autoDispose
    .family<List<GroupDto>, String>((ref, addressbookId) async {
      final api = ref.watch(contactsApiProvider);
      if (api == null) throw StateError(kContactsNotConnected);
      return api.groups(addressbookId: addressbookId);
    }, retry: _noRetry);

/// 组织单位（`SYNO.Contacts.OU/list`）—— 官方左侧「组织单位」树的原始数据。
///
/// 参数（`limit/offset/addressbook_id`）取自官方网页客户端 `main.js` 的唯一调用
/// 点；真机不带 `addressbook_id` 回 120（见 `docs/live-nas-verification.md` §6.2）。
final organizationUnitsProvider = FutureProvider.autoDispose
    .family<List<OuDto>, String>((ref, addressbookId) async {
      final api = ref.watch(contactsApiProvider);
      if (api == null) throw StateError(kContactsNotConnected);
      return api.organizationUnits(addressbookId: addressbookId);
    }, retry: _noRetry);

/// 某个分组里的联系人（`Contact/list` + `group_id`，官方同口径）
final groupMembersProvider = FutureProvider.autoDispose
    .family<List<ContactDto>, String>((ref, groupId) async {
      final api = ref.watch(contactsApiProvider);
      if (api == null) throw StateError(kContactsNotConnected);
      return api.contacts(groupId: groupId, limit: 200);
    }, retry: _noRetry);

/// 头像批量取图（`Contact/get_photo` v1）的 family key。
///
/// 为什么不用 `List<String>` 当 family 参数：Dart 的 `List` 是**引用相等**，
/// 每次 `build` 生成的新 list 都会命中一个新 family 实例 → 无限重取。
/// 拼成 CSV 字符串就有值相等语义。
String contactPhotosKey(List<String> ids) => ids.join(',');

/// 列表头像（`Contact/get_photo` v1）。
///
/// 官方网页客户端的口径（`/tmp/spk/export_Contacts/ui/static/js/main.js`）：
/// * 表：`getContactPhoto:{api:"SYNO.Contacts.Contact",method:"get_photo",version:1}`；
/// * 调用点：`Ht(Hn.send,"getContactPhoto",{contact_ids:t})` —— `contact_ids` 是
///   **JSON 数组串**（和 `Contact/get` 的 `ids` 同族）；
/// * 按需取：`l=intersection(已有缓存的 key, ids)`，只请求 `difference` 的那批；
///   列表滚动时取"可见范围 + 星标"，回包 `photo.forEach(e=>s[e.id]=e.photo)`。
///
/// 失败**不报错**：退回姓名首字（改造前的行为），不因为头像拿不到就让整个
/// 联系人列表变错误页。
final contactPhotosProvider = FutureProvider.autoDispose
    .family<Map<String, String>, String>((ref, csv) async {
      final ids = csv.isEmpty
          ? const <String>[]
          : csv.split(',').where((e) => e.isNotEmpty).toList();
      if (ids.isEmpty) return const {};
      final api = ref.watch(contactsApiProvider);
      if (api == null) throw StateError(kContactsNotConnected);
      try {
        return await api.photos(ids);
      } catch (_) {
        return const {};
      }
    }, retry: _noRetry);

/// 外部源 / CardDAV 账号（`ExternalSource/list`）
final externalSourcesProvider =
    FutureProvider.autoDispose<List<ExternalSourceDto>>((ref) async {
      final api = ref.watch(contactsApiProvider);
      if (api == null) throw StateError(kContactsNotConnected);
      return api.externalSources();
    }, retry: _noRetry);

/// 可共享主体（`Addressbook/list_principal`）
final principalsProvider = FutureProvider.autoDispose
    .family<List<PrincipalDto>, String>((ref, addressbookId) async {
      final api = ref.watch(contactsApiProvider);
      if (api == null) throw StateError(kContactsNotConnected);
      return api.principals(addressbookId: addressbookId);
    }, retry: _noRetry);

/// 联系人账号信息（`Info/get`；CardDAV 地址要用账号名）
final contactsInfoProvider =
    FutureProvider.autoDispose<({String account, String displayName})>((
      ref,
    ) async {
      final api = ref.watch(contactsApiProvider);
      if (api == null) throw StateError(kContactsNotConnected);
      return api.info();
    }, retry: _noRetry);

/// 写操作集合
final contactActionsProvider = Provider<ContactActions>(ContactActions.new);
