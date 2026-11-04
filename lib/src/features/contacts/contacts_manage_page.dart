// 通讯录与标签管理（对齐官方网页版左侧「通讯录 / 标签」两栏的管理能力）。
//
// 覆盖：新建/重命名/删除通讯录、显示与隐藏、导出 vCard；新建/改名换色/删除标签、
// 导出标签（"组地址簿"）；共享信息**只读展示**。
//
// 共享为什么只读：服务端 `Addressbook/share_addressbook` 要
// `sharing_addressbook_config = [{id, mode, status}]`，而 `mode`/`status` 的取值
// 语义在 bundle 里没有可读的常量表（真机也不敢乱试，会把用户的共享关系改坏）。
// 所以这里把「共享自谁 / 共享给谁 / 有权限的主体」摆出来，改共享请到网页端。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/user_copy.dart';
import '../../data/dto/contact_dto.dart';
import '../../data/dto/contact_extras_dto.dart';
import 'contacts_page.dart' show describeContactsError;
import 'contacts_providers.dart';

/// 标签可选颜色（官方是取色器；这里给一排够用的）
const _kLabelColors = [
  '#4C8DFF',
  '#37B26C',
  '#F2A33C',
  '#E0567B',
  '#8E6BE0',
  '#2FA8A0',
  '#D9534F',
  '#8D6E63',
];

class ContactsManagePage extends ConsumerWidget {
  const ContactsManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    // 能力位（C4）：`SYNO.Contacts.OU` 缺失 → **只隐藏「分组」这一个页签**
    // （通讯录 / 标签照常），**不隐藏联系人模块**（`partial`）。
    final canOu = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.contacts, kContactsOUApi);
    return DefaultTabController(
      length: canOu ? 3 : 2,
      child: Scaffold(
        backgroundColor: DesignPalette.of(context).bg,
        appBar: AppBar(
          title: Text(t.contactBooksAndLabels),
          bottom: TabBar(
            tabs: [
              Tab(text: t.contactAddressBooks),
              Tab(text: t.noteTags),
              if (canOu)
                Tab(
                  text: dataText('contactGroupsTab', '分组'),
                  key: const Key('contact-groups-tab'),
                ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            const _BooksTab(),
            const _LabelsTab(),
            if (canOu) const _GroupsTab(),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 通讯录

class _BooksTab extends ConsumerWidget {
  const _BooksTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final async = ref.watch(addressbooksProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new_book',
        onPressed: () => _createDialog(context, ref),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: Text(t.contactNewAddressBook),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        // 失败态必须与"空结果"分开、并保留重试入口（铁律②）：通讯录列表
        // 加载失败时用户原来只能看到一行错误文本、没有任何出路。
        error: (e, __) => AppErrorView(
          key: const Key('contact-books-error'),
          detail: describeContactsError(e, t),
          onRetry: () => ref.invalidate(addressbooksProvider),
        ),
        data: (books) => books.isEmpty
            ? Center(
                child: Text(
                  t.contactNoBooksYet,
                  style: TextStyle(color: DesignPalette.of(context).dim),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: Gap.xl * 2),
                children: [
                  for (final b in books) _BookTile(book: b, all: books),
                ],
              ),
      ),
    );
  }

  static Future<void> _createDialog(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final name = TextEditingController();
    var isPublic = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(t.contactNewAddressBook),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: t.sortByName,
                  isDense: true,
                ),
              ),
              DesignSwitchRow(
                contentPadding: EdgeInsets.zero,
                title: Text(t.contactBookPublic),
                value: isPublic,
                onChanged: (v) => setState(() => isPublic = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t.photoCreate),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(contactActionsProvider)
          .createAddressbook(name: name.text.trim(), isPublic: isPublic);
      messenger.showSnackBar(SnackBar(content: Text(t.contactBookCreated)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.calCreateFailed(describeContactsError(e, t)))),
      );
    }
  }
}

class _BookTile extends ConsumerWidget {
  const _BookTile({required this.book, required this.all});

/// 把一个"共享对象"的裸值解析成**给用户看的名字**；解析不出来就**不显示**。
///
/// * 已知的服务端内部群组 ⇒ 本地化名字（`所有人` / `Everyone`）；
/// * 其它内部标识符（`syno.*` / 含 `.internal.`）⇒ `null`（宁可不画，也不画内部串）；
/// * 正常名字 ⇒ 原样。
String? _shareeDisplayName(BuildContext context, String raw) {
  final v = raw.trim();
  if (v.isEmpty) return null;
  if (v == 'syno.contacts.internal.everyone') {
    return context.t.contactShareeEveryone;
  }
  if (looksLikeInternalIdentifier(v)) return null;
  return v;
}

  final AddressbookDto book;
  final List<AddressbookDto> all;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final principals = ref.watch(principalsProvider(book.id)).value ?? const [];
    // ★★★ 第 349 轮真机缺陷 D66：这个列表有**两个生产者** —— 服务端给的
    // `book.sharedWith`（裸值）与 principals 解析出的 `displayName`。
    // 真机上 `Team Contacts` 显示的是 `syno.contacts.internal.everyone`
    // —— **服务端内部群组标识当用户文案**（§2.0.47 家族第 8 处，且是**运行时值**
    // ⇒ 静态守卫看不见）。两个生产者**都必须过同一道显示解析**（§2.0.26），
    // 不许只在其中一条上打补丁。
    final sharedTo = <String>[
      if (book.sharedWith.isNotEmpty) book.sharedWith,
      for (final p in principals.where((p) => p.isShared)) p.displayName,
    ].map((raw) => _shareeDisplayName(context, raw)).whereType<String>().toList();
    return ExpansionTile(
      leading: Icon(
        book.type == 3
            ? Icons.person_outline
            : book.type == 4
            ? Icons.groups_outlined
            : Icons.lightbulb_outline,
      ),
      title: Text(book.name),
      subtitle: Text(
        [
          t.contactMemberCount(book.memberCount),
          book.type == 3
              ? t.contactBookPersonal
              : book.type == 4
              ? t.contactBookTeamPublic
              : t.contactBookSuggested,
          if (book.sharedFrom.isNotEmpty) t.contactSharedFrom(book.sharedFrom),
          if (sharedTo.isNotEmpty) t.contactSharedTo(sharedTo.join(context.t.listSeparator)),
        ].join(' · '),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
      ),
      childrenPadding: const EdgeInsets.only(
        left: Gap.md,
        right: Gap.md,
        bottom: Gap.sm,
      ),
      children: [
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.xs,
          children: [
            TextButton.icon(
              onPressed: () => _rename(context, ref),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text(t.photoRename),
            ),
            TextButton.icon(
              onPressed: () => _export(context, ref),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(t.contactExportVCard),
            ),
            TextButton.icon(
              onPressed: () => _delete(context, ref),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(t.dtoActionDelete),
            ),
          ],
        ),
        if (principals.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              t.contactSharePrincipals(
                principals.map((p) => p.displayName).join(context.t.listSeparator),
              ),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
            ),
          ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final c = TextEditingController(text: book.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.contactRenameAddressBook),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(labelText: t.sortByName, isDense: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.actionSave),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(contactActionsProvider)
          .renameAddressbook(id: book.id, name: c.text.trim());
      messenger.showSnackBar(SnackBar(content: Text(t.contactRenamed)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.photoRenameFailed(describeContactsError(e, t))),
        ),
      );
    }
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text(t.contactExportingBook(book.name))),
    );
    try {
      final path = await ref
          .read(contactActionsProvider)
          .exportAddressbook(book);
      await ref.read(contactActionsProvider).openExport(path);
      messenger.showSnackBar(
        SnackBar(content: Text(t.contactExportedTo(path))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.driveExportFailed(describeContactsError(e, t))),
        ),
      );
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.contactDeleteAddressBook),
        content: Text(t.contactDeleteBookConfirm(book.name, book.memberCount)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(contactActionsProvider).deleteAddressbook(book.id);
      messenger.showSnackBar(SnackBar(content: Text(t.contactBookDeleted)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.photoDeleteFailed(describeContactsError(e, t))),
        ),
      );
    }
  }
}

// -------------------------------------------------------------------- 标签

class _LabelsTab extends ConsumerWidget {
  const _LabelsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final async = ref.watch(labelsProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new_label',
        onPressed: () => _editDialog(context, ref),
        icon: const Icon(Icons.new_label_outlined),
        label: Text(t.noteNewTagHint),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, __) => AppErrorView(
          key: const Key('contact-labels-error'),
          detail: describeContactsError(e, t),
          onRetry: () => ref.invalidate(labelsProvider),
        ),
        data: (labels) => ListView(
          padding: const EdgeInsets.only(bottom: Gap.xl * 2),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Gap.md,
                Gap.md,
                Gap.md,
                Gap.sm,
              ),
              child: Text(
                t.contactLabelsHelp,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
              ),
            ),
            for (final l in labels) _LabelTile(label: l),
          ],
        ),
      ),
    );
  }

  static Future<void> _editDialog(
    BuildContext context,
    WidgetRef ref, {
    LabelDto? existing,
  }) async {
    final t = context.t;
    final name = TextEditingController(text: existing?.name ?? '');
    var color = existing?.displayColor ?? _kLabelColors.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(existing == null ? t.noteNewTagHint : t.contactEditLabel),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: t.noteTagNameHint,
                  isDense: true,
                ),
              ),
              const SizedBox(height: Gap.md),
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  for (final c in _kLabelColors)
                    InkWell(
                      onTap: () => setState(() => color = c),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: _parse(c),
                          shape: BoxShape.circle,
                          border: color == c
                              ? Border.all(
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 3,
                                )
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t.actionSave),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(contactActionsProvider);
    try {
      if (existing == null) {
        await actions.createLabel(name: name.text.trim(), color: color);
      } else {
        await actions.setLabel(
          id: existing.id,
          name: name.text.trim(),
          color: color,
        );
      }
      messenger.showSnackBar(SnackBar(content: Text(t.actionSaved)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.noteSaveFailed(describeContactsError(e, t)))),
      );
    }
  }

  static Color _parse(String hex) {
    final v = int.tryParse(hex.replaceAll('#', ''), radix: 16);
    return v == null ? const Color(0xFF4C8DFF) : Color(0xFF000000 | v);
  }
}

class _LabelTile extends ConsumerWidget {
  const _LabelTile({required this.label});

  final LabelDto label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final color = _LabelsTab._parse(label.displayColor);
    return DesignRowTile(
      leading: CircleAvatar(backgroundColor: color, radius: 12),
      title: Text(label.name),
      subtitle: Text(
        label.isStarred
            ? t.contactSystemLabelMembers(label.memberCount)
            : t.contactMemberCount(label.memberCount),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
      ),
      trailing: label.isStarred
          ? Icon(Icons.lock_outline, size: 18, color: DesignPalette.of(context).dim)
          : PopupMenuButton<String>(
              onSelected: (v) async {
                final messenger = ScaffoldMessenger.of(context);
                final actions = ref.read(contactActionsProvider);
                try {
                  if (v == 'edit') {
                    await _LabelsTab._editDialog(context, ref, existing: label);
                    return;
                  }
                  if (v == 'export') {
                    final path = await actions.exportLabel(label);
                    await actions.openExport(path);
                    messenger.showSnackBar(
                      SnackBar(content: Text(t.contactExportedTo(path))),
                    );
                    return;
                  }
                  // delete
                  await actions.deleteLabel(label.id);
                  messenger.showSnackBar(
                    SnackBar(content: Text(t.contactLabelDeleted)),
                  );
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        t.calTodoActionFailed(describeContactsError(e, t)),
                      ),
                    ),
                  );
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'edit',
                  child: Text(t.contactRenameRecolor),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: Text(t.contactExportVCardGroup),
                ),
                PopupMenuItem(value: 'delete', child: Text(t.noteDeleteTag)),
              ],
            ),
    );
  }
}

// ------------------------------------------------------------------ 分组

/// 「分组」页签：联系人分组（`Contact/list_group`）的显示/隐藏 + 成员，
/// 以及（可选能力位）组织单位（`SYNO.Contacts.OU/list`）**只读**树。
///
/// 证据（官方网页客户端 `ui/static/js/main.js`）：
///   * 取分组：`Ht(Hn.send,"listGroup",{addressbook_id:t})`，元素字段
///     `{id,name,member_count,is_hidden,path}`（`MD()` 的合并段原文）；
///   * 分组显隐：`Ht(Hn.send,"toggleGroup",{ids,is_hidden})`；
///   * 成员显隐：`Ht(Hn.send,"toggleMember",{id,is_hidden})`（**裸 `id`**）；
///   * 组织单位：`Ht(Hn.send,"listOrganizationUnit",{limit,offset,addressbook_id})`，
///     元素 `{id,dn,principal}`（`ID()`）。
///
/// 为什么组织单位**只读**：`ou` 项里**没有** `is_hidden`（官方 `ID()` 给出的
/// 字段只有 `id/dn/principal`），拿不到当前显隐状态就不能做一个状态正确的开关
/// —— 盲写会比没有这个功能更糟。分组（`list_group`）有 `is_hidden`，所以那一层
/// 可以安全地做开关。
class _GroupsTab extends ConsumerStatefulWidget {
  const _GroupsTab();

  @override
  ConsumerState<_GroupsTab> createState() => _GroupsTabState();
}

class _GroupsTabState extends ConsumerState<_GroupsTab> {
  String? _bookId;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final async = ref.watch(addressbooksProvider);
    final canOu = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.contacts, kContactsOUApi);

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, __) => AppErrorView(
        key: const Key('contact-groups-error'),
        detail: describeContactsError(e, t),
        onRetry: () => ref.invalidate(addressbooksProvider),
      ),
      data: (books) {
        if (books.isEmpty) {
          return Center(
            child: Text(
              t.contactNoBooksYet,
              style: TextStyle(color: DesignPalette.of(context).dim),
            ),
          );
        }
        // 默认选**团队/公开**通讯录（type 4）—— 官方取分组的地址簿就是它
        // （`i.addressbook.findIndex(function(e){return e.type===Oi})`，`Oi=4`）
        AddressbookDto book = books.first;
        for (final b in books) {
          if (b.id == _bookId) book = b;
        }
        if (_bookId == null) {
          for (final b in books) {
            if (b.type == 4) {
              book = b;
              break;
            }
          }
        }
        final groups = ref.watch(groupsProvider(book.id));
        final ous = canOu ? ref.watch(organizationUnitsProvider(book.id)) : null;

        return ListView(
          padding: const EdgeInsets.only(bottom: Gap.xl * 2),
          children: [
            if (books.length > 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: const Key('contact-groups-book'),
                  initialValue: book.id,
                  decoration: InputDecoration(
                    labelText: t.contactAddressBooks,
                    isDense: true,
                  ),
                  items: [
                    for (final b in books)
                      DropdownMenuItem(value: b.id, child: Text(b.name)),
                  ],
                  onChanged: (v) => setState(() => _bookId = v),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
              child: Text(
                dataText('contactGroupsSection', '联系人分组'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            groups.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.md),
                child: LinearProgressIndicator(minHeight: 2),
              ),
              error: (e, __) => Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.lg,
                  vertical: Gap.sm,
                ),
                child: AppEmptyState(
                  key: const Key('contact-groups-section-error'),
                  icon: Icons.cloud_off,
                  title: t.photoLoadFailed,
                  message: describeContactsError(e, t),
                  actionLabel: t.photoRetry,
                  onAction: () => ref.invalidate(groupsProvider(book.id)),
                  compact: true,
                ),
              ),
              // 空分组列表同样是**正常空态**（官方本机 `group:[]`）
              data: (list) => list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Gap.lg,
                        vertical: Gap.sm,
                      ),
                      child: Text(
                        dataText('contactNoGroups', '这个通讯录里还没有分组。'),
                        style: TextStyle(color: DesignPalette.of(context).dim),
                      ),
                    )
                  : Column(
                      children: [
                        for (final g in list)
                          _GroupTile(group: g, key: Key('contact-group-${g.id}')),
                      ],
                    ),
            ),
            if (ous != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
                child: Text(
                  dataText('contactOuSection', '组织单位（只读）'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ous.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: Gap.md),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
                error: (e, __) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Gap.lg,
                    vertical: Gap.sm,
                  ),
                  child: AppEmptyState(
                    key: const Key('contact-ou-section-error'),
                    icon: Icons.cloud_off,
                    title: t.photoLoadFailed,
                    message: describeContactsError(e, t),
                    actionLabel: t.photoRetry,
                    onAction: () =>
                        ref.invalidate(organizationUnitsProvider(book.id)),
                    compact: true,
                  ),
                ),
                data: (list) => list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Gap.lg,
                          vertical: Gap.sm,
                        ),
                        child: Text(
                          dataText('contactNoOu', '没有组织单位（或这台 NAS 未接入目录服务）。'),
                          style: TextStyle(color: DesignPalette.of(context).dim),
                        ),
                      )
                    : Column(
                        children: [
                          for (final ou in list)
                            DesignRowTile(
                              dense: true,
                              contentPadding: EdgeInsets.only(
                                left: Gap.lg + 12.0 * (ou.depth - 1).clamp(0, 6),
                                right: Gap.lg,
                              ),
                              leading: const Icon(
                                Icons.account_tree_outlined,
                                size: 18,
                              ),
                              title: Text(
                                ou.name.isEmpty ? ou.dn : ou.name,
                              ),
                              subtitle: Text(
                                '${ou.dn} · ${ou.principalIds.length}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 一个分组的显示/隐藏开关 + 展开看成员
class _GroupTile extends ConsumerStatefulWidget {
  const _GroupTile({required this.group, super.key});

  final GroupDto group;

  @override
  ConsumerState<_GroupTile> createState() => _GroupTileState();
}

class _GroupTileState extends ConsumerState<_GroupTile> {
  var _busy = false;

  Future<void> _toggle(bool hidden) async {
    setState(() => _busy = true);
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(contactActionsProvider)
          .setGroupHidden([widget.group.id], hidden: hidden);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.calTodoActionFailed(describeContactsError(e, t)))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final g = widget.group;
    return ExpansionTile(
      title: Text(g.name.isEmpty ? g.id : g.name),
      subtitle: Text('${g.memberCount}'),
      trailing: Switch(
        value: !g.isHidden,
        onChanged: _busy ? null : (v) => _toggle(!v),
      ),
      children: [
        ref
            .watch(groupMembersProvider(g.id))
            .when(
              loading: () => const Padding(
                padding: EdgeInsets.all(Gap.md),
                child: LinearProgressIndicator(minHeight: 2),
              ),
              error: (e, __) => Padding(
                padding: const EdgeInsets.all(Gap.sm),
                child: AppEmptyState(
                  key: const Key('contact-group-members-error'),
                  icon: Icons.cloud_off,
                  title: t.photoLoadFailed,
                  message: describeContactsError(e, t),
                  actionLabel: t.photoRetry,
                  onAction: () =>
                      ref.invalidate(groupMembersProvider(widget.group.id)),
                  compact: true,
                ),
              ),
              data: (members) => members.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Text(dataText('contactNoGroupMembers', '这个分组没有成员。')),
                    )
                  : Column(
                      children: [
                        for (final m in members)
                          DesignRowTile(
                            dense: true,
                            title: Text(m.fullName),
                            subtitle: m.primaryMail.isEmpty
                                ? null
                                : Text(m.primaryMail),
                            trailing: Switch(
                              value: !m.isHidden,
                              onChanged: _busy
                                  ? null
                                  : (v) => _toggleMember(m.id, hidden: !v),
                            ),
                          ),
                      ],
                    ),
            ),
      ],
    );
  }

  Future<void> _toggleMember(String id, {required bool hidden}) async {
    setState(() => _busy = true);
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(contactActionsProvider)
          .setGroupMemberHidden(id, hidden: hidden);
      ref.invalidate(groupMembersProvider(widget.group.id));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.calTodoActionFailed(describeContactsError(e, t)))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
