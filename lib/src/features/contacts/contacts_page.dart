// 联系人页（Synology Contacts）—— 浏览 + 搜索 + 增删改查入口 + 导入导出 + 管理 + CardDAV。
//
// 接口事实见 `lib/src/data/contacts_api.dart` 顶部注释；功能点逐条对齐官方网页版，
// 对照表在 `docs/contacts-module-plan.md`。
//
// 几个刻意的取舍：
//   * 搜索**同时**走服务端 `keyword`（少传数据）和本地过滤（即时、且离线也能用）；
//   * 星标就是"在系统 Starred 标签里"，所以列表右侧那颗星点一下就能改（真机验过）；
//   * 新建联系人归属哪个通讯录：选中了就用选中的，没选就让人挑一个。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/text_fit.dart';
import '../../data/contacts_api.dart';
import '../../data/dto/contact_dto.dart';
import '../../data/dto/contact_extras_dto.dart';
import 'carddav_sheet.dart';
import 'contact_detail_sheet.dart';
import 'contact_editor_page.dart';
import 'contact_import_page.dart';
import 'contacts_manage_page.dart';
import 'contacts_providers.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 搜索词同时进服务端与本地（本地是兜底：服务端只认它索引的字段）
  void _onKeyword(String v) =>
      ref.read(contactFilterProvider.notifier).setKeyword(v.trim());

  @override
  Widget build(BuildContext context) {
    final books = ref.watch(addressbooksProvider);
    final selected = ref.watch(selectedAddressbookProvider);
    final filter = ref.watch(contactFilterProvider);
    final labels = ref.watch(labelsProvider).value ?? const <LabelDto>[];
    final contacts = ref.watch(contactsProvider);
    // 列表不回头像（`Contact/list` 没有 photo 字段），官方网页客户端是拿
    // `Contact/get_photo` 按可见范围批量取、并缓存在 `ContactList.contactPhoto`。
    // 这里对当前已加载的一页做一次批量取图；失败/缺接口时退回姓名首字。
    final loaded = contacts.value ?? const <ContactDto>[];
    final photoCsv = contactPhotosKey([
      for (final c in loaded)
        if (c.id.isNotEmpty) c.id,
    ]);
    final photos = photoCsv.isEmpty
        ? const <String, String>{}
        : ref.watch(contactPhotosProvider(photoCsv)).value ??
              const <String, String>{};
    // 能力位降级：`SYNO.Contacts.Addressbook` 缺失时只藏「通讯录管理」入口，
    // 联系人浏览 / 增删改查照常可用。
    final canManageBooks = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.contacts, kContactsAddressbookApi);

    return Scaffold(
      backgroundColor: DesignPalette.of(context).bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newContact(books.value ?? const []),
        icon: const Icon(Icons.person_add_alt),
        label: Text(context.t.calNew),
      ),
      body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: context.t.calBack,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.t.wsContacts,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          // 装饰性副标题：**放得下就画，放不下整行不画**。
                          // r349 真机缺陷：原来是个裸 `Text`，CJK 可在任意两字之间折行 ⇒
                          // 真机上被劈成 `SYNOLOGY CONTACTS · 通讯录 / 标` + `签 / CardDAV`
                          // （词被切成两半，且头部长到三行）。
                          // 口径与日历页**同一份实现**（`core/ui/text_fit.dart`）。
                          FittedSubtitle(
                            text: context.t.contactHeaderTagline,
                            textKey: const Key('contacts-subtitle'),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: DesignPalette.of(context).dim, letterSpacing: 1.0),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: context.t.photoRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () {
                        ref.invalidate(addressbooksProvider);
                        ref.invalidate(labelsProvider);
                        ref.invalidate(contactsProvider);
                      },
                    ),
                    PopupMenuButton<String>(
                      tooltip: context.t.photoMore,
                      onSelected: (v) => _onMenu(v, books.value ?? const []),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'import',
                          child: DesignRowTile(
                            dense: true,
                            leading: const Icon(Icons.upload_file_outlined),
                            title: Text(context.t.contactImportVcfCsv),
                          ),
                        ),
                        if (canManageBooks)
                          PopupMenuItem(
                            value: 'manage',
                            child: DesignRowTile(
                              dense: true,
                              leading: const Icon(Icons.tune),
                              title: Text(context.t.contactManageBooksLabels),
                            ),
                          ),
                        PopupMenuItem(
                          value: 'carddav',
                          child: DesignRowTile(
                            dense: true,
                            leading: const Icon(Icons.qr_code_2),
                            title: Text(context.t.contactCarddavSync),
                          ),
                        ),
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'sort_name',
                          child: DesignRowTile(
                            dense: true,
                            leading: const Icon(Icons.sort_by_alpha),
                            title: Text(context.t.contactSortByName),
                            trailing: filter.sort == ContactSort.fullName
                                ? const Icon(Icons.check, size: 18)
                                : null,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'sort_company',
                          child: DesignRowTile(
                            dense: true,
                            leading: const Icon(Icons.business_outlined),
                            title: Text(context.t.contactSortByCompany),
                            trailing: filter.sort == ContactSort.company
                                ? const Icon(Icons.check, size: 18)
                                : null,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'sort_dir',
                          child: DesignRowTile(
                            dense: true,
                            leading: Icon(
                              filter.descending
                                  ? Icons.arrow_downward
                                  : Icons.arrow_upward,
                            ),
                            title: Text(
                              filter.descending
                                  ? context.t.contactSortAsc
                                  : context.t.contactSortDesc,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.md,
                  Gap.sm,
                  Gap.md,
                  Gap.xs,
                ),
                child: TextField(
                  controller: _search,
                  onChanged: _onKeyword,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: context.t.contactSearchHint,
                    suffixIcon: filter.keyword.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _search.clear();
                              _onKeyword('');
                            },
                          ),
                  ),
                ),
              ),
              // 第一行：通讯录（「全部」+ 每个通讯录）
              books.maybeWhen(
                data: (list) => list.isEmpty
                    ? const SizedBox.shrink()
                    : SizedBox(
                        height: 44,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(
                            horizontal: Gap.md,
                          ),
                          children: [
                            _BookChip(
                              label: context.t.noteAll,
                              count: null,
                              selected: selected == null,
                              onTap: () => ref
                                  .read(selectedAddressbookProvider.notifier)
                                  .select(null),
                            ),
                            for (final b in list)
                              _BookChip(
                                label: b.name,
                                count: b.memberCount,
                                selected: selected == b.id,
                                onTap: () => ref
                                    .read(selectedAddressbookProvider.notifier)
                                    .select(b.id),
                              ),
                          ],
                        ),
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
              // 第二行：星标 + 用户标签（点一下按标签过滤）
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  children: [
                    _BookChip(
                      label: context.t.contactStarredChip,
                      count: null,
                      selected:
                          _starId(labels) != null &&
                          filter.labelId == _starId(labels),
                      onTap: () {
                        final star = _starId(labels);
                        if (star != null) {
                          ref
                              .read(contactFilterProvider.notifier)
                              .setLabel(filter.labelId == star ? null : star);
                        }
                      },
                    ),
                    for (final l in labels.where((l) => !l.isStarred))
                      _BookChip(
                        label: l.name,
                        count: null,
                        selected: filter.labelId == l.id,
                        onTap: () => ref
                            .read(contactFilterProvider.notifier)
                            .setLabel(filter.labelId == l.id ? null : l.id),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: contacts.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => AppEmptyState(
                    icon: Icons.error_outline,
                    title: context.t.contactOpenFailed,
                    message: describeContactsError(e, context.t),
                    actionLabel: context.t.photoRetry,
                    onAction: () => ref.invalidate(contactsProvider),
                  ),
                  data: (all) {
                    final list = _filter(all, filter.keyword);
                    if (list.isEmpty && filter.keyword.isNotEmpty) {
                      return AppEmptyState(
                        icon: Icons.search_off,
                        title: context.t.contactNoMatch(filter.keyword),
                        message: context.t.contactNoMatchHint,
                      );
                    }
                    if (all.isEmpty) {
                      return AppEmptyState(
                        icon: Icons.contacts_outlined,
                        title: context.t.contactEmptyTitle,
                        message: context.t.contactEmptyBody,
                      );
                    }
                    return RefreshIndicator(
                      onRefresh: () async => ref.invalidate(contactsProvider),
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: Gap.xl * 2),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          color: DesignPalette.of(context).dim.withValues(alpha: 0.12),
                        ),
                        itemBuilder: (context, i) => _ContactRow(
                          contact: list[i],
                          starId: _starId(labels),
                          photo: photos[list[i].id],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
    );
  }

  static String? _starId(List<LabelDto> labels) {
    for (final l in labels) {
      if (l.isStarred) return l.id;
    }
    return null;
  }

  Future<void> _onMenu(String value, List<AddressbookDto> books) async {
    switch (value) {
      case 'import':
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => ContactImportPage(books: books)),
        );
      case 'manage':
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => const ContactsManagePage()),
        );
      case 'carddav':
        await showCardDavSheet(context);
      case 'sort_name':
        ref.read(contactFilterProvider.notifier).setSort(ContactSort.fullName);
      case 'sort_company':
        ref.read(contactFilterProvider.notifier).setSort(ContactSort.company);
      case 'sort_dir':
        final f = ref.read(contactFilterProvider);
        ref
            .read(contactFilterProvider.notifier)
            .setSort(f.sort, descending: !f.descending);
    }
  }

  /// 新建：选中的通讯录优先，其次让人挑一个（个人通讯录排前面）
  Future<void> _newContact(List<AddressbookDto> books) async {
    final t = context.t;
    final selected = ref.read(selectedAddressbookProvider);
    String? bookId = selected;
    if (bookId == null) {
      if (books.isEmpty) {
        _toast(t.contactNoBooks);
        return;
      }
      final sorted = [...books]
        ..sort((a, b) {
          int rank(AddressbookDto x) => x.type == 3
              ? 0
              : x.type == 2
              ? 2
              : 1;
          return rank(a).compareTo(rank(b));
        });
      if (!mounted) return;
      bookId = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: DesignPalette.of(context).bg,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              DesignRowTile(dense: true, title: Text(t.contactPickBookTitle)),
              for (final b in sorted)
                DesignRowTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(b.name),
                  subtitle: b.sharedFrom.isNotEmpty
                      ? Text(t.contactSharedFrom(b.sharedFrom))
                      : null,
                  onTap: () => Navigator.of(ctx).pop(b.id),
                ),
            ],
          ),
        ),
      );
    }
    if (bookId == null || !mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ContactEditorPage(addressbookId: bookId!),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 本地兜底过滤（服务端 `keyword` 只覆盖它索引的字段）
  List<ContactDto> _filter(List<ContactDto> all, String keyword) {
    if (keyword.isEmpty) return all;
    final k = keyword.toLowerCase();
    return all
        .where(
          (c) =>
              c.fullName.toLowerCase().contains(k) ||
              c.company.toLowerCase().contains(k) ||
              c.department.toLowerCase().contains(k) ||
              c.title.toLowerCase().contains(k) ||
              c.bestMail.toLowerCase().contains(k) ||
              c.bestTel.contains(k),
        )
        .toList();
  }
}

/// 错误文案：联系人没装 / 没权限时别让用户看代码
///
/// [text] 是界面语言文案表；缺省 `currentText()`（中文回落，老调用者照旧）。
String describeContactsError(Object e, [AppText? text]) {
  final t = text ?? currentText();
  final s = e.toString();
  if (s.contains('102')) return t.contactErrNotInstalled;
  if (s.contains('103')) return t.contactErrVersionUnsupported;
  if (s.contains('105')) return t.contactErrNoPermission;
  if (s.contains('120')) return t.contactErrParamRejected;
  if (s.contains('1015')) return t.contactErrBookNotFound;
  if (s.contains(kContactsNotConnected)) return t.contactErrOffline;
  if (s.contains(kContactsNoStarredLabel)) return t.contactErrNoStarredLabel;
  if (s.contains('SocketException') || s.contains('Connection')) {
    return t.contactErrNetwork;
  }
  return t.calTodoActionFailed(s);
}

class _BookChip extends StatelessWidget {
  const _BookChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: Gap.sm),
      child: Material(
        // ★ `DA186`：不透明 `primarySoft`（半透明叠底会掉到 4.4:1）
        color: selected
            ? p.primarySoft
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.capsule),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.capsule),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.md,
              vertical: 8,
            ),
            child: Text(
              count == null ? label : '$label${count! > 0 ? ' $count' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: selected ? p.primary : null,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContactRow extends ConsumerWidget {
  const _ContactRow({required this.contact, required this.starId, this.photo});

  final ContactDto contact;
  final String? starId;

  /// `Contact/get_photo` 批量取回的头像（data URL）；null/空 → 姓名首字
  final String? photo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final starred = starId != null && contact.labelIds.contains(starId);
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        leading: ContactsAvatar(contact: contact, photo: photo),
        title: Text(
          contact.fullName.isEmpty ? t.contactUnnamed : contact.fullName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [
            if (contact.subtitle.isNotEmpty) contact.subtitle,
            if (contact.bestTel.isNotEmpty) contact.bestTel,
            if (contact.bestMail.isNotEmpty) contact.bestMail,
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
        ),
        trailing: starId == null
            ? const Icon(Icons.chevron_right, size: 18)
            : IconButton(
                tooltip: starred ? t.driveUnstar : t.noteStar,
                icon: Icon(
                  starred ? Icons.star_rounded : Icons.star_border_rounded,
                  color: starred
                      ? Theme.of(context).colorScheme.primary
                      : DesignPalette.of(context).dim,
                ),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    await ref.read(contactActionsProvider).toggleStar(contact);
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          starred ? t.contactUnstarred : t.sortTargetFavorite,
                        ),
                      ),
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
              ),
        onTap: () {
          // 使用日志：打开联系人详情（不记姓名）
          trackOnce(
            UsageModule.contacts,
            UsageAction.open,
            objectType: 'contact',
          );
          showContactDetailSheet(context, contact: contact);
        },
      ),
    );
  }
}
