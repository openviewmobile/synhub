// 联系人的写操作（增删改查 / 星标 / 复制移动 / 标签 / 通讯录管理 / 导入导出 / CardDAV）。
//
// 抽成类的理由和文件模块的 `FileActionsController` 一样：这些动作在「详情页、
// 列表长按菜单、管理页」三处都要用，各自写一份必然在"成功提示/失败提示/刷新
// 哪些 provider"上长出三套口径。
//
// 所有方法**不弹 UI**（除了导出后开文件这一件事）—— 提示交给调用方，
// 这样测试里可以直接断言"调了哪个 API、参数是什么"。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/system_open.dart';

import '../../data/contacts_api.dart';
import '../../data/dto/contact_dto.dart';
import '../../data/dto/contact_extras_dto.dart';
import '../files/file_providers.dart' show fileDownloadDirectory;
import 'contacts_providers.dart';

class ContactActions {
  ContactActions(this._ref);

  final Ref _ref;

  ContactsApi get _api {
    final api = _ref.read(contactsApiProvider);
    if (api == null) throw StateError(kContactsNotConnected);
    return api;
  }

  /// 写完之后要刷新的东西：列表、标签、通讯录（保持"改完立刻能看到"）
  void _refresh() {
    _ref.invalidate(contactsProvider);
    _ref.invalidate(labelsProvider);
    _ref.invalidate(addressbooksProvider);
    _ref.invalidate(externalSourcesProvider);
    _ref.invalidate(organizationUnitsProvider);
  }

  // ------------------------------------------------------------------ 星标

  /// 星标 = 给系统「Starred」标签加/删成员（真机验过；`toggle_person` 是隐藏）
  Future<void> toggleStar(ContactDto contact) async {
    final labels = await _ref.read(labelsProvider.future);
    LabelDto? star;
    for (final l in labels) {
      if (l.isStarred) {
        star = l;
        break;
      }
    }
    if (star == null) {
      throw StateError(kContactsNoStarredLabel);
    }
    final starred = contact.labelIds.contains(star.id);
    if (starred) {
      await _api.removeLabelMembers(
        labelIds: [star.id],
        contactIds: [contact.id],
      );
    } else {
      await _api.addLabelMembers(labelIds: [star.id], contactIds: [contact.id]);
    }
    _refresh();
  }

  /// 给一批联系人打/去某个标签
  Future<void> setLabelMembers({
    required String labelId,
    required List<String> contactIds,
    required bool add,
  }) async {
    if (add) {
      await _api.addLabelMembers(labelIds: [labelId], contactIds: contactIds);
    } else {
      await _api.removeLabelMembers(
        labelIds: [labelId],
        contactIds: contactIds,
      );
    }
    _refresh();
  }

  // -------------------------------------------------------------- 联系人写

  Future<String> createContact({
    required String addressbookId,
    required ContactInput input,
  }) async {
    final id = await _api.createContact(
      addressbookId: addressbookId,
      input: input,
    );
    _refresh();
    return id;
  }

  Future<void> setContact({
    required String id,
    required ContactInput input,
  }) async {
    await _api.setContact(id: id, input: input);
    _refresh();
  }

  Future<void> deleteContacts(List<String> ids) async {
    await _api.deleteContacts(ids);
    _refresh();
  }

  /// 显示 / 隐藏（团队通讯录里的用户记录）
  Future<void> setHidden(List<String> ids, {required bool hidden}) async {
    await _api.setContactsHidden(ids, hidden: hidden);
    _refresh();
  }

  /// 组织单位（分组）节点的显示 / 隐藏（`Contact/toggle_group`）
  Future<void> setGroupHidden(
    List<String> ids, {
    required bool hidden,
  }) async {
    await _api.setGroupsHidden(ids, hidden: hidden);
    _refresh();
  }

  /// 组织单位里**单个联系人**的显示 / 隐藏（`Contact/toggle_member`，参数是裸 `id`）
  Future<void> setGroupMemberHidden(
    String id, {
    required bool hidden,
  }) async {
    await _api.setGroupMemberHidden(id, hidden: hidden);
    _refresh();
  }

  /// 复制 / 移动到别的通讯录
  Future<void> copyTo({
    required String targetId,
    required List<String> contactIds,
  }) async {
    await _api.copyContacts(targetId: targetId, contactIds: contactIds);
    _refresh();
  }

  Future<void> moveTo({
    required String destId,
    required List<String> contactIds,
  }) async {
    await _api.moveContacts(destId: destId, contactIds: contactIds);
    _refresh();
  }

  // -------------------------------------------------------------- 通讯录写

  Future<String> createAddressbook({
    required String name,
    bool isPublic = false,
  }) async {
    final id = await _api.createAddressbook(name: name, isPublic: isPublic);
    _refresh();
    return id;
  }

  Future<void> renameAddressbook({
    required String id,
    required String name,
  }) async {
    await _api.setAddressbook(id: id, name: name);
    _refresh();
  }

  Future<void> deleteAddressbook(String id) async {
    await _api.deleteAddressbook(id);
    _refresh();
  }

  /// 通讯录显示配置（`Addressbook/set_addressbook_display`）。
  ///
  /// ⚠️ 只保留接口：真机验过它会把 `[{addressbook_id, status}]` 原样写回，但
  /// **`status` 的 0/1/2 含义没有确证**（默认值是 2），所以 UI 暂时不调它 ——
  /// 盲改用户的显示配置比"没有这个功能"更糟。
  Future<void> setDisplay(List<({String id, int status})> config) async {
    await _api.setAddressbookDisplay(config);
    _refresh();
  }

  /// 共享配置（第一版：把"已共享给谁"整体提交，用于取消共享/调整权限）
  Future<void> share({
    required String addressbookId,
    required List<({String principalId, int mode, int status})> config,
  }) async {
    await _api.shareAddressbook(addressbookId: addressbookId, config: config);
    _refresh();
  }

  // ------------------------------------------------------------------ 标签

  Future<String> createLabel({
    required String name,
    required String color,
  }) async {
    final id = await _api.createLabel(name: name, color: color);
    _refresh();
    return id;
  }

  Future<void> setLabel({
    required String id,
    required String name,
    required String color,
  }) async {
    await _api.setLabel(id: id, name: name, color: color);
    _refresh();
  }

  Future<void> deleteLabel(String id) async {
    await _api.deleteLabel(id);
    _refresh();
  }

  // -------------------------------------------------------------- 导入导出

  /// 导入预览（不写库）
  Future<List<ImportPreviewDto>> previewImport({
    required String filePath,
    required String fileName,
    String? addressbookId,
  }) => _api.importPreview(
    filePath: filePath,
    fileName: fileName,
    addressbookId: addressbookId,
  );

  /// 真导入，返回新建的联系人 id
  Future<List<String>> importVCard({
    required String filePath,
    required String fileName,
    required String addressbookId,
  }) async {
    final ids = await _api.importVCard(
      filePath: filePath,
      fileName: fileName,
      addressbookId: addressbookId,
    );
    _refresh();
    return ids;
  }

  /// 导出通讯录为 vCard 文件，返回本地路径（`docs/downloads/…vcf`）
  Future<String> exportAddressbook(AddressbookDto book) async {
    final bytes = await _api.exportAddressbook(book.id);
    return _writeExport(
      bytes,
      _vcfName(currentText().contactExportBookName(book.name)),
    );
  }

  /// 导出标签（"组地址簿"）为 vCard，返回本地路径
  Future<String> exportLabel(LabelDto label) async {
    final bytes = await _api.exportLabel(label.id);
    return _writeExport(
      bytes,
      _vcfName(currentText().contactExportLabelName(label.name)),
    );
  }

  /// 导出后交给系统"打开/分享"（Android 上会弹应用选择器）。
  ///
  /// 走 `system_open.dart`：**测试环境 no-op**（不要拿假 vcf 去喂 mac 的
  /// 默认应用），打开结果只用来给文案。
  Future<void> openExport(String path) => defaultSystemOpen(path);

  Future<String> _writeExport(List<int> bytes, String fileName) async {
    final dir = await fileDownloadDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 文件名里不能有 `/` `\` `:` 之类；顺带补 `.vcf`
  static String _vcfName(String raw) {
    final safe = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '')
        .replaceAll('-', '')
        .replaceAll('T', '_');
    return '${safe}_$stamp.vcf';
  }

  // -------------------------------------------------------- 外部源 / CardDAV

  Future<void> createCardDav({
    required String location,
    required String username,
    required String password,
    int importType = 0,
    bool isSync = true,
    String? addressbookId,
  }) async {
    await _api.createCardDav(
      location: location,
      username: username,
      password: password,
      importType: importType,
      isSync: isSync,
      addressbookId: addressbookId,
    );
    _refresh();
  }

  Future<void> syncExternalSource(String addressbookId) async {
    await _api.syncExternalSource(addressbookId);
    _refresh();
  }

  /// CardDAV 地址（iOS 用 short、其他客户端用 general）
  ({String short, String general}) cardDavUrls({
    required String account,
    String addressbookUri = '',
  }) => _api.cardDavUrls(account: account, addressbookUri: addressbookUri);
}
