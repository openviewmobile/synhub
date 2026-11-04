// MailPlus 邮件详情页（会话内所有邮件 + 已读/星标/移动）。
//
// 接口事实来源：`SYNO.MailClient.Thread.get` v11（root `thread` 数组）、
// `Message.get` v10（root `message` 数组，`body` 是 `{html,plain,truncated}` 对象）、
// `Message.set_read` / `set_star` / `set_mailbox` v10、`Mailbox.list` v7。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/mailplus_dto.dart';
import '../../data/mailplus.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'mail_labels.dart';
import 'mail_providers.dart';

class MailDetailPage extends ConsumerStatefulWidget {
  const MailDetailPage({super.key, required this.threadId});

  final String threadId;

  @override
  ConsumerState<MailDetailPage> createState() => _MailDetailPageState();
}

class _MailDetailPageState extends ConsumerState<MailDetailPage> {
  @override
  void initState() {
    super.initState();
    trackOnce(UsageModule.mailplus, UsageAction.open, objectType: 'mail');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final thread = ref.watch(mailThreadProvider(widget.threadId));
    final api = ref.watch(mailApiProvider);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(t.mailTitle),
        actions: [
          if (thread.value != null) ...[
            IconButton(
              key: const Key('mail-toggle-read'),
              tooltip: thread.value!.unread ? t.mailMarkRead : t.mailMarkUnread,
              icon: Icon(
                thread.value!.unread
                    ? Icons.drafts_outlined
                    : Icons.mark_email_unread_outlined,
              ),
              onPressed: () => _toggleRead(context, ref, thread.value!),
            ),
            IconButton(
              key: const Key('mail-toggle-star'),
              tooltip: thread.value!.star ? t.mailUnstar : t.mailStar,
              icon: Icon(thread.value!.star ? Icons.star : Icons.star_border),
              onPressed: () => _toggleStar(context, ref, thread.value!),
            ),
            IconButton(
              key: const Key('mail-move'),
              tooltip: t.mailMoveTo,
              icon: const Icon(Icons.drive_file_move_outline),
              onPressed: () => _move(context, ref, thread.value!),
            ),
          ],
        ],
      ),
      body: api == null || !api.installed
          ? AppEmptyState(
              key: const Key('mail-detail-not-installed'),
              icon: Icons.extension_off_outlined,
              title: t.mailErrNotInstalled,
              message: t.mailNotInstalledHint,
            )
          : thread.when(
              loading: () => const AppListSkeleton(),
              error: (e, _) => AppErrorView(
                key: const Key('mail-detail-error'),
                icon: Icons.error_outline,
                title: t.mailDetailFailed,
                detail: describeMailError(e),
                onRetry: () => ref.invalidate(mailThreadProvider(widget.threadId)),
              ),
              data: (th) => th == null || th.messages.isEmpty
                  ? AppEmptyState(
                      key: const Key('mail-detail-empty'),
                      icon: Icons.mark_email_read_outlined,
                      title: t.mailEmptyTitle,
                    )
                  : _Body(thread: th),
            ),
    );
  }

  Future<void> _toggleRead(
    BuildContext context,
    WidgetRef ref,
    MailThreadDto thread,
  ) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final primary = thread.primary;
    if (primary == null) return;
    try {
      await ref
          .read(mailActionsProvider)
          .setRead(primary.id, read: thread.unread);
      messenger.showSnackBar(SnackBar(content: Text(t.mailActionDone)));
      ref.invalidate(mailThreadProvider(widget.threadId));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.mailActionFailed(describeMailError(e)))),
      );
    }
  }

  Future<void> _toggleStar(
    BuildContext context,
    WidgetRef ref,
    MailThreadDto thread,
  ) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final primary = thread.primary;
    if (primary == null) return;
    try {
      await ref
          .read(mailActionsProvider)
          .setStar(primary.id, star: !thread.star);
      messenger.showSnackBar(SnackBar(content: Text(t.mailActionDone)));
      ref.invalidate(mailThreadProvider(widget.threadId));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.mailActionFailed(describeMailError(e)))),
      );
    }
  }

  Future<void> _move(
    BuildContext context,
    WidgetRef ref,
    MailThreadDto thread,
  ) async {
    final t = context.t;
    final primary = thread.primary;
    if (primary == null) return;
    final boxes = ref.read(mailMailboxesProvider).value ?? const [];
    if (boxes.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.mailLoadFailed)));
      return;
    }
    final picked = await showDialog<MailMailboxDto>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.mailMoveTo),
        children: [
          for (final b in boxes)
            SimpleDialogOption(
              key: Key('mail-move-target-${b.id}'),
              onPressed: () => Navigator.of(ctx).pop(b),
              child: Text(b.displayName.isNotEmpty ? b.displayName : b.path),
            ),
        ],
      ),
    );
    if (picked == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(mailActionsProvider).move(primary.id, picked.id);
      messenger.showSnackBar(SnackBar(content: Text(t.mailActionDone)));
      ref.invalidate(mailThreadProvider(widget.threadId));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.mailActionFailed(describeMailError(e)))),
      );
    }
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.thread});

  final MailThreadDto thread;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final msgs = thread.messages;
    // S2 能力位降级：缺 `SYNO.MailClient.Attachment` 时，模块照常（partial，
    // 不隐藏），但「附件」这一功能入口不可用 → 整个附件区不出现。
    final canAttachments = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.mailplus, kMailAttachmentApi);
    return ListView(
      key: const Key('mail-detail-body'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
      children: [
        Text(
          msgs.first.subject.isEmpty ? t.mailNoSubject : msgs.first.subject,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: Gap.sm),
        _MetaRow(label: t.mailFrom, value: msgs.first.from),
        _MetaRow(label: t.mailTo, value: msgs.first.to.join(', ')),
        if (msgs.first.cc.isNotEmpty)
          _MetaRow(label: t.mailCc, value: msgs.first.cc.join(', ')),
        _MetaRow(
          label: t.mailDate,
          value: mailTimeText(msgs.first.arrivalTime),
        ),
        const SizedBox(height: Gap.md),
        for (final m in msgs) ...[
          if (msgs.length > 1) Divider(color: DesignPalette.of(context).dim.withValues(alpha: 0.2)),
          if (canAttachments && m.attachments.isNotEmpty) ...[
            _Attachments(attachments: m.attachments),
            const SizedBox(height: Gap.md),
          ],
          SelectableText(
            m.displayBody.isEmpty ? t.mailNoBody : m.displayBody,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: Gap.lg),
        ],
      ],
    );
  }
}

class _Attachments extends StatelessWidget {
  const _Attachments({required this.attachments});

  final List<MailAttachmentDto> attachments;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TelemetryLabel(t.mailAttachments, size: 11, color: DesignPalette.of(context).dim),
        const SizedBox(height: Gap.xs),
        for (final a in attachments)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(Icons.attach_file, size: 14, color: DesignPalette.of(context).dim),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    a.name.isEmpty ? '—' : a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TelemetryLabel(mailSizeText(a.size), size: 10, color: DesignPalette.of(context).dim),
              ],
            ),
          ),
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: TelemetryLabel(label, size: 10, color: DesignPalette.of(context).dim),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
