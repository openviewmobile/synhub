// 联系人详情卡片（底部弹层）+ 全部动作：星标 / 编辑 / 删除 / 标签 / 复制移动 / 隐藏。
//
// 详情数据来自 `Contact/get`（**v2**，只有它带 `additional.contact_detail` 的
// 多值邮箱电话、姓名构成、地址、备注）。列表项只有 `primary_mail`/`primary_tel`，
// 所以打开时先用列表项垫着（[fallback]），详情回来了再换。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/contact_dto.dart';
import '../../data/dto/contact_extras_dto.dart';
import 'contact_editor_page.dart';
import 'contacts_page.dart' show describeContactsError;
import 'contacts_providers.dart';
import '../../core/theme/app_theme.dart';

/// 打开详情弹层
Future<void> showContactDetailSheet(
  BuildContext context, {
  required ContactDto contact,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: DesignPalette.of(context).bg,
  builder: (_) => ContactDetailSheet(id: contact.id, fallback: contact),
);

class ContactDetailSheet extends ConsumerWidget {
  const ContactDetailSheet({
    super.key,
    required this.id,
    required this.fallback,
  });

  final String id;
  final ContactDto fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(contactDetailProvider(id));
    final c = async.value ?? fallback;
    final books = ref.watch(addressbooksProvider).value ?? const [];
    final labels = ref.watch(labelsProvider).value ?? const [];
    LabelDto? star;
    for (final l in labels) {
      if (l.isStarred) {
        star = l;
        break;
      }
    }
    final starred = star != null && c.labelIds.contains(star.id);
    var bookName = c.addressbookName;
    if (bookName.isEmpty) {
      for (final b in books) {
        if (b.id == c.addressbookId) bookName = b.name;
      }
    }

    final d = c.detail;
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        maxChildSize: 0.94,
        minChildSize: 0.4,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xl),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ContactsAvatar(contact: c, size: 56),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.fullName.isEmpty
                            ? context.t.contactUnnamed
                            : c.fullName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (d?.nickName.isNotEmpty ?? false)
                        Text(
                          context.t.contactDetailNickname(d!.nickName),
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
                        ),
                      if (c.subtitle.isNotEmpty)
                        Text(
                          c.subtitle,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
                        ),
                      if (bookName.isNotEmpty)
                        Text(
                          context.t.contactDetailAddressBook(bookName),
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
                        ),
                    ],
                  ),
                ),
                if (star != null)
                  IconButton(
                    tooltip: starred
                        ? context.t.driveUnstar
                        : context.t.noteStar,
                    icon: Icon(
                      starred ? Icons.star_rounded : Icons.star_border_rounded,
                      color: starred
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    onPressed: () => _guard(
                      context,
                      ref,
                      () => ref.read(contactActionsProvider).toggleStar(c),
                      starred
                          ? context.t.contactUnstarred
                          : context.t.sortTargetFavorite,
                    ),
                  ),
              ],
            ),
            if (async.isLoading)
              const Padding(
                padding: EdgeInsets.only(top: Gap.sm),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (c.labels.isNotEmpty) ...[
              const SizedBox(height: Gap.md),
              Wrap(
                spacing: Gap.xs,
                runSpacing: Gap.xs,
                children: [
                  for (var i = 0; i < c.labels.length; i++)
                    Chip(
                      label: Text(c.labels[i]),
                      backgroundColor: _labelColor(
                        labels,
                        c.labelIds,
                        i,
                      ).withValues(alpha: 0.18),
                    ),
                ],
              ),
            ],
            const SizedBox(height: Gap.md),
            if (d?.tel.isNotEmpty ?? false)
              _Line(
                icon: Icons.phone_outlined,
                values: d!.tel,
                onCopy: (v) => _copy(context, v),
              )
            else if (c.bestTel.isNotEmpty)
              _Line(
                icon: Icons.phone_outlined,
                values: [c.bestTel],
                onCopy: (v) => _copy(context, v),
              ),
            if (d?.mail.isNotEmpty ?? false)
              _Line(
                icon: Icons.mail_outline,
                values: d!.mail,
                onCopy: (v) => _copy(context, v),
              )
            else if (c.bestMail.isNotEmpty)
              _Line(
                icon: Icons.mail_outline,
                values: [c.bestMail],
                onCopy: (v) => _copy(context, v),
              ),
            if (d?.url.isNotEmpty ?? false)
              _Line(icon: Icons.link_outlined, values: d!.url),
            if (d?.im.isNotEmpty ?? false)
              _Line(icon: Icons.chat_bubble_outline, values: d!.im),
            if (d?.date.isNotEmpty ?? false)
              _Line(icon: Icons.event_outlined, values: d!.date),
            if (d?.adr.isNotEmpty ?? false)
              _Line(icon: Icons.place_outlined, values: d!.adr),
            if (d?.birthday.isNotEmpty ?? false)
              _Line(icon: Icons.cake_outlined, values: [d!.birthday]),
            if (d?.note.isNotEmpty ?? false)
              _Line(icon: Icons.notes_outlined, values: [d!.note]),
            if (async.hasError)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(
                  describeContactsError(async.error!, context.t),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            if (!c.isEditable && !async.isLoading)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, size: 16, color: DesignPalette.of(context).dim),
                    const SizedBox(width: Gap.xs),
                    Expanded(
                      child: Text(
                        context.t.contactReadOnlyNote,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: Gap.lg),
            _Actions(
              contact: c,
              onEdit: () async {
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => ContactEditorPage(
                      addressbookId: c.addressbookId,
                      existing: c,
                    ),
                  ),
                );
                if (saved == true && context.mounted) {
                  Navigator.of(context).maybePop();
                }
              },
            ),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(context.t.photoClose),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _labelColor(List<LabelDto> labels, List<String> ids, int index) {
    if (index < ids.length) {
      for (final l in labels) {
        if (l.id == ids[index]) return _parseColor(l.displayColor);
      }
    }
    return const Color(0xFF4C8DFF);
  }

  static Color _parseColor(String hex) {
    final v = int.tryParse(hex.replaceAll('#', ''), radix: 16);
    return v == null ? const Color(0xFF4C8DFF) : Color(0xFF000000 | v);
  }

  static void _copy(BuildContext context, String value) {
    // 不引第三方：用 ScaffoldMessenger 报个信，剪贴板走系统服务
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t.contactCopiedValue(value))),
    );
  }

  static Future<void> _guard(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() op,
    String okMsg,
  ) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await op();
      messenger.showSnackBar(SnackBar(content: Text(okMsg)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.calTodoActionFailed(describeContactsError(e, t))),
        ),
      );
    }
  }
}

/// 头像：有 photo（data URL）就显示图，否则显示姓名首字。
///
/// [photo] 是**列表批量取图**（`Contact/get_photo`）的结果覆盖：`Contact/list`
/// 不回头像，所以列表要先用 `contactPhotosProvider` 取回来再塞进来；
/// 详情页传 null（详情接口自己有 `additional.contact_detail.photo`）。
class ContactsAvatar extends StatelessWidget {
  const ContactsAvatar({
    super.key,
    required this.contact,
    this.size = 40,
    this.photo,
  });

  final ContactDto contact;
  final double size;
  final String? photo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final raw = (photo != null && photo!.isNotEmpty) ? photo! : contact.photo;
    final bytes = decodePhotoDataUrl(raw);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.primary.withValues(alpha: 0.18),
        image: bytes == null
            ? null
            : DecorationImage(image: MemoryImage(bytes), fit: BoxFit.cover),
      ),
      child: bytes != null
          ? null
          : Text(
              contact.initials,
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: size * 0.4,
              ),
            ),
    );
  }
}

/// 详情里的动作条
class _Actions extends ConsumerWidget {
  const _Actions({required this.contact, required this.onEdit});

  final ContactDto contact;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editable = contact.isEditable;
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      children: [
        FilledButton.tonalIcon( style: InlineButtonStyle.filled,
          onPressed: editable ? onEdit : null,
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: Text(context.t.calEditLabel),
        ),
        OutlinedButton.icon( style: InlineButtonStyle.outlined,
          onPressed: () => _openLabelPicker(context, ref, contact),
          icon: const Icon(Icons.sell_outlined, size: 18),
          label: Text(context.t.noteTags),
        ),
        OutlinedButton.icon( style: InlineButtonStyle.outlined,
          onPressed: () => _openMovePicker(context, ref, contact),
          icon: const Icon(Icons.drive_file_move_outline, size: 18),
          label: Text(context.t.contactCopyMove),
        ),
        OutlinedButton.icon( style: InlineButtonStyle.outlined,
          onPressed: () => _toggleHidden(context, ref, contact),
          icon: Icon(
            contact.isHidden
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            size: 18,
          ),
          label: Text(
            contact.isHidden ? context.t.contactUnhide : context.t.contactHide,
          ),
        ),
        OutlinedButton.icon(
          // ★ r330：原来这里只给了前景色 ⇒ 宽度仍是主题里的 `Size.fromHeight(48)`
          //   （无限宽）⇒ 在 `Wrap` 里**静默撑满整行**。收宽度与颜色**两件都要**。
          style: InlineButtonStyle.outlined.copyWith(
            foregroundColor: WidgetStatePropertyAll(
              Theme.of(context).colorScheme.error,
            ),
          ),
          onPressed: () => _confirmDelete(context, ref, contact),
          icon: const Icon(Icons.delete_outline, size: 18),
          label: Text(context.t.dtoActionDelete),
        ),
      ],
    );
  }

  Future<void> _toggleHidden(
    BuildContext context,
    WidgetRef ref,
    ContactDto c,
  ) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(contactActionsProvider).setHidden([
        c.id,
      ], hidden: !c.isHidden);
      messenger.showSnackBar(
        SnackBar(
          content: Text(c.isHidden ? t.contactUnhidden : t.contactHidden),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.calTodoActionFailed(describeContactsError(e, t))),
        ),
      );
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    ContactDto c,
  ) async {
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.contactDeleteTitle),
        content: Text(t.contactDeleteConfirm(c.fullName)),
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
    final nav = Navigator.of(context);
    try {
      await ref.read(contactActionsProvider).deleteContacts([c.id]);
      messenger.showSnackBar(SnackBar(content: Text(t.driveDeleted)));
      nav.maybePop();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.photoDeleteFailed(describeContactsError(e, t))),
        ),
      );
    }
  }

  /// 标签多选（差集 = 加哪些、删哪些）
  Future<void> _openLabelPicker(
    BuildContext context,
    WidgetRef ref,
    ContactDto c,
  ) async {
    final t = context.t;
    final labels = await ref.read(labelsProvider.future);
    if (!context.mounted) return;
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      backgroundColor: DesignPalette.of(context).bg,
      builder: (ctx) => _LabelPicker(
        labels: labels.where((l) => !l.isStarred).toList(),
        selected: c.labelIds.where((id) {
          return labels.any((l) => l.id == id && !l.isStarred);
        }).toSet(),
      ),
    );
    if (picked == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(contactActionsProvider);
    try {
      for (final l in labels.where((l) => !l.isStarred)) {
        final had = c.labelIds.contains(l.id);
        final want = picked.contains(l.id);
        if (want == had) continue;
        await actions.setLabelMembers(
          labelId: l.id,
          contactIds: [c.id],
          add: want,
        );
      }
      messenger.showSnackBar(SnackBar(content: Text(t.driveLabelsUpdated)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            t.contactLabelsUpdateFailed(describeContactsError(e, t)),
          ),
        ),
      );
    }
  }

  /// 复制/移动到别的通讯录（不带当前这个）
  Future<void> _openMovePicker(
    BuildContext context,
    WidgetRef ref,
    ContactDto c,
  ) async {
    final t = context.t;
    final books = (await ref.read(
      addressbooksProvider.future,
    )).where((b) => b.id != c.addressbookId).toList();
    if (!context.mounted) return;
    if (books.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.contactNoOtherBook)));
      return;
    }
    final choice = await showModalBottomSheet<({String id, bool copy})>(
      context: context,
      backgroundColor: DesignPalette.of(context).bg,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            DesignRowTile(dense: true, title: Text(t.contactPickTargetBook)),
            for (final b in books)
              DesignRowTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(b.name),
                subtitle: Text(t.contactMemberCount(b.memberCount)),
                onTap: () => Navigator.of(ctx).pop((id: b.id, copy: true)),
                onLongPress: () =>
                    Navigator.of(ctx).pop((id: b.id, copy: false)),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final actions = ref.read(contactActionsProvider);
      if (choice.copy) {
        await actions.copyTo(targetId: choice.id, contactIds: [c.id]);
      } else {
        await actions.moveTo(destId: choice.id, contactIds: [c.id]);
      }
      messenger.showSnackBar(
        SnackBar(content: Text(choice.copy ? t.fileCopied : t.contactMoved)),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            choice.copy
                ? t.contactCopyFailed(describeContactsError(e, t))
                : t.contactMoveFailed(describeContactsError(e, t)),
          ),
        ),
      );
    }
  }
}

class _LabelPicker extends StatefulWidget {
  const _LabelPicker({required this.labels, required this.selected});

  final List<LabelDto> labels;
  final Set<String> selected;

  @override
  State<_LabelPicker> createState() => _LabelPickerState();
}

class _LabelPickerState extends State<_LabelPicker> {
  late final Set<String> _sel = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Text(
              context.t.contactLabelPickerTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (widget.labels.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(
                context.t.contactNoLabelsHint,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final l in widget.labels)
                  DesignCheckRow(
                    value: _sel.contains(l.id),
                    title: Text(l.name),
                    secondary: CircleAvatar(
                      radius: 10,
                      backgroundColor: _parse(l.displayColor),
                    ),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _sel.add(l.id);
                      } else {
                        _sel.remove(l.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.t.actionCancel),
                ),
                const SizedBox(width: Gap.sm),
                FilledButton(
                  style: InlineButtonStyle.filled,
                  onPressed: () => Navigator.of(context).pop(_sel),
                  child: Text(context.t.actionOk),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Color _parse(String hex) {
    final v = int.tryParse(hex.replaceAll('#', ''), radix: 16);
    return v == null ? const Color(0xFF4C8DFF) : Color(0xFF000000 | v);
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.values, this.onCopy});

  final IconData icon;
  final List<String> values;
  final void Function(String value)? onCopy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: DesignPalette.of(context).dim),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final v in values)
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          v,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      if (onCopy != null)
                        IconButton(
                          tooltip: context.t.dtoActionCopy,
                          icon: const Icon(Icons.copy, size: 16),
                          onPressed: () => onCopy!(v),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
