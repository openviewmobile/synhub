// MailPlus 邮件列表页（阶段二 A 最后一批，只做普通用户功能）。
//
// 接口事实来源：`docs/station-surveillance-mailplus-insight-research.md`
//   * 邮箱树 = `SYNO.MailClient.Mailbox.list` v7（root `mailbox`）；
//   * 列表 = `SYNO.MailClient.Thread.list` v11（root `thread` + `total` + `has_more`，
//     `condition:[{name:"mailbox",value:<path>}]`）。
//
// 页面结构对齐现有模块（见 `features/downloads/download_page.dart`、
// `features/surveillance/surv_page.dart`）：邮箱筛选 · 触底分页 · 下拉刷新 ·
// 空态/错误态（**区分套件未安装/无权限/网络失败**，未安装不给"重试"）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/mailplus_dto.dart';
import '../../data/mailplus.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'mail_compose_page.dart';
import 'mail_detail_page.dart';
import 'mail_labels.dart';
import 'mail_providers.dart';

class MailPage extends ConsumerStatefulWidget {
  const MailPage({super.key});

  @override
  ConsumerState<MailPage> createState() => _MailPageState();
}

class _MailPageState extends ConsumerState<MailPage> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    trackView(UsageModule.mailplus, screen: 'inbox');
    // build 里不能发请求，首帧之后再拉。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(mailThreadListProvider.notifier).load();
    });
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
        ref.read(mailThreadListProvider.notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = ref.watch(mailThreadListProvider);
    final api = ref.watch(mailApiProvider);
    final mailboxes = ref.watch(mailMailboxesProvider);
    // 邮箱树回来后，默认选中 INBOX（或第一条）——只做一次。
    ref.listen(mailMailboxesProvider, (_, next) {
      final list = next.value;
      if (list == null || list.isEmpty) return;
      if (ref.read(mailSelectedMailboxProvider) != null) return;
      final inbox = list.firstWhere(
        (b) => b.path.toUpperCase() == 'INBOX',
        orElse: () => list.first,
      );
      ref.read(mailSelectedMailboxProvider.notifier).select(inbox.path);
      ref.read(mailThreadListProvider.notifier).load();
    });
    return DesignScaffold(
      appBar: AppBar(
        title: Text(t.mailTitle),
        actions: [
          IconButton(
            key: const Key('mail-refresh'),
            tooltip: t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(mailMailboxesProvider);
              ref.read(mailThreadListProvider.notifier).refresh();
            },
          ),
        ],
      ),
      floatingActionButton: api != null && api.installed
          ? FloatingActionButton.extended(
              key: const Key('mail-compose'),
              onPressed: () => _openCompose(context),
              icon: const Icon(Icons.edit_outlined),
              label: Text(t.mailCompose),
            )
          : null,
      body: Column(
        children: [
          _MailboxBar(
            boxes: mailboxes.value ?? const [],
            selected: ref.watch(mailSelectedMailboxProvider),
            onSelect: (path) {
              ref.read(mailSelectedMailboxProvider.notifier).select(path);
              ref.read(mailThreadListProvider.notifier).load();
            },
          ),
          Expanded(child: _body(context, state, api)),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    MailThreadListState state,
    MailPlusApi? api,
  ) {
    final t = context.t;
    // 1) 还没连接会话
    if (state.apiMissing || api == null) {
      return AppEmptyState(
        key: const Key('mail-no-session'),
        icon: Icons.cloud_off,
        title: t.setNotConnected,
        message: t.mailNotInstalledHint,
      );
    }
    // 2) 套件未安装：给结论 + 引导套件中心，**不给**"重试"
    if (state.failure == MailFailureKind.notInstalled) {
      return AppEmptyState(
        key: const Key('mail-not-installed'),
        icon: Icons.extension_off_outlined,
        title: t.mailErrNotInstalled,
        message: t.mailNotInstalledHint,
      );
    }
    // 3) 无权限
    if (state.failure == MailFailureKind.noPrivilege && state.items.isEmpty) {
      return AppEmptyState(
        key: const Key('mail-no-privilege'),
        icon: Icons.lock_outline,
        title: t.mailErrNoPrivilege,
        message: t.mailNoPrivilegeHint,
      );
    }
    // 4) 首次加载
    if (state.loading && !state.loaded) return const AppListSkeleton();
    // 5) 失败（网络/其它）—— 这里才给"重试"
    if (state.failure != null && state.items.isEmpty) {
      final network =
          state.failure == MailFailureKind.network ||
          state.failure == MailFailureKind.sessionExpired;
      return AppErrorView(
        key: const Key('mail-error'),
        icon: network ? Icons.wifi_off : Icons.error_outline,
        title: t.mailThreadsFailed,
        detail: state.errorText,
        onRetry: () => ref.read(mailThreadListProvider.notifier).load(),
      );
    }
    // 6) 空态
    if (state.items.isEmpty) {
      return AppEmptyState(
        key: const Key('mail-empty'),
        icon: Icons.mark_email_unread_outlined,
        title: t.mailEmptyTitle,
        message: t.mailEmptyMessage,
      );
    }
    // 7) 列表
    return RefreshIndicator(
      onRefresh: () => ref.read(mailThreadListProvider.notifier).refresh(),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        controller: _scroll,
        padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.xxl),
        itemCount: state.items.length + 1,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          color: DesignPalette.of(context).dim.withValues(alpha: 0.12),
        ),
        itemBuilder: (context, i) {
          if (i == state.items.length) return const _ListFooter();
          return _ThreadRow(thread: state.items[i]);
        },
      ),
    );
  }

  Future<void> _openCompose(BuildContext context) async {
    final sent = await Navigator.of(
      context,
      rootNavigator: true,
    ).push<bool>(MaterialPageRoute(builder: (_) => const MailComposePage()));
    if (sent == true) await ref.read(mailThreadListProvider.notifier).refresh();
  }
}

/// 顶部邮箱筛选条。
class _MailboxBar extends StatelessWidget {
  const _MailboxBar({
    required this.boxes,
    required this.selected,
    required this.onSelect,
  });

  final List<MailMailboxDto> boxes;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (boxes.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        itemCount: boxes.length,
        separatorBuilder: (_, _) => const SizedBox(width: Gap.xs),
        itemBuilder: (context, i) {
          final b = boxes[i];
          final on = b.path == selected;
          final label = b.displayName.isNotEmpty ? b.displayName : b.path;
          return Center(
            child: ChoiceChip(
              key: Key('mail-mailbox-${b.id}'),
              selected: on,
              onSelected: (_) => onSelect(b.path),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label),
                  if (b.unreadCount > 0) ...[
                    const SizedBox(width: Gap.xs),
                    TelemetryLabel(
                      '${b.unreadCount}',
                      size: 10,
                      color: DesignPalette.of(context).dim,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 一行会话。
class _ThreadRow extends ConsumerWidget {
  const _ThreadRow({required this.thread});

  final MailThreadDto thread;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final theme = Theme.of(context);
    final subject = thread.subject.isEmpty ? t.mailNoSubject : thread.subject;
    return DesignRowTile(
      key: Key('mail-thread-${thread.id}'),
      leading: Icon(
        thread.unread
            ? Icons.mark_email_unread_outlined
            : Icons.mark_email_read_outlined,
        color: thread.unread ? theme.colorScheme.primary : DesignPalette.of(context).dim,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              subject,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: thread.unread ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (thread.star)
            Icon(Icons.star, size: 14, color: theme.colorScheme.primary),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              mailThreadSubtitle(thread),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (thread.hasAttachment)
            Padding(
              padding: const EdgeInsets.only(left: Gap.xs),
              child: Icon(Icons.attach_file, size: 14, color: DesignPalette.of(context).dim),
            ),
        ],
      ),
      trailing: TelemetryLabel(
        mailTimeText(thread.lastModified),
        size: 10,
        color: DesignPalette.of(context).dim,
      ),
      onTap: () => Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(builder: (_) => MailDetailPage(threadId: thread.id)),
      ),
    );
  }
}

/// 列表底部：分页进度 / "没有更多"。
class _ListFooter extends ConsumerWidget {
  const _ListFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final state = ref.watch(mailThreadListProvider);
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Gap.md),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (!state.hasMore && state.items.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.md),
        child: Center(
          child: TelemetryLabel(
            t.mailThreadCount(state.total),
            size: 10,
            color: DesignPalette.of(context).dim,
          ),
        ),
      );
    }
    return const SizedBox(height: Gap.xxl);
  }
}
