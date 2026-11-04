// 投票卡片（Phase 6）。
//
// 渲染服务端给的 `post.props.vote`：
//   * 点选项投票（单选 = 换票，多选 = 加减票）—— 本地先乐观更新，
//     再调 `Vote/vote`（真机实测 `choice_ids` 要 JSON 数组）；
//   * 投票结束后只显示结果；
//   * 允许加选项时（`options.add_option`）多一个「添加选项」；
//   * 「看结果」拉 `Vote/get_choices`；
//   * **发起人 + 投票进行中**时右上角一个「更多」菜单：编辑投票 / 结束投票 / 删除投票
//     （原版 `ChannelViewBinder.bindVoteContent` 的 `moreView` + action sheet；
//     条件是 `creatorId == me && vote.isOpen()`）；
//   * `state == "delete"` 时整张卡片只显示「投票已删除」（原版 `voteDeleted`）；
//   * 卡片头显示「匿名 / 截止 xxx」（原版 `voteInfoView`，`[_SUBST_1_]` 换成日期）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/vote_dto.dart';
import 'channel_sort.dart' show userDisplayName;
import 'chat_session_controller.dart';
import 'vote_editor.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';

class VoteCard extends ConsumerStatefulWidget {
  const VoteCard({super.key, required this.post});

  final PostDto post;

  @override
  ConsumerState<VoteCard> createState() => _VoteCardState();
}

class _VoteCardState extends ConsumerState<VoteCard> {
  bool _busy = false;

  Future<void> _run(Future<bool> Function() action, String failText) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await action();
      if (!ok && mounted) _toast(failText);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// 「看结果」：拉最新票数 → 开结果面板（票数 + 占比 + 投票人）。
  ///
  /// 官方的两个 Fragment 都对齐了：
  ///   * `VoteResultFragment`（每个选项的票数与占比）；
  ///   * `VoteUsersFragment`（某个选项的投票人，参数就是 `userIds`）。
  Future<void> _showResults(PostDto post) async {
    final t = context.t;
    if (_busy) return;
    setState(() => _busy = true);
    List<VoteChoiceDto> choices;
    try {
      choices = await ref
          .read(chatSessionControllerProvider.notifier)
          .loadVoteChoices(post);
    } catch (e) {
      trackOnceFailure(
        UsageModule.chat,
        UsageAction.view,
        objectType: 'poll_results',
        reason: 'load_choices',
        error: e,
      );
      if (mounted) _toast(t.chatVoteRefreshFailed);
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    // analytics: viewing the poll results sheet (page only)
    trackView(UsageModule.chat, screen: 'poll_results');
    await showVoteResultsSheet(context, ref, post: post, choices: choices);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    final myUserId = ref.watch(chatSessionControllerProvider).myUserId;
    // 从本地库取最新的一条（投票后 props 会被写回）
    final post =
        ref
            .watch(postsProvider(widget.post.channelId))
            .value
            ?.where((p) => p.postId == widget.post.postId)
            .firstOrNull ??
        widget.post;
    final vote = post.vote;
    if (vote == null) return const SizedBox.shrink();

    final mine = vote.chosenBy(myUserId);
    final deleted = vote.state == VoteState.deleted;
    final closed = !vote.isOpen;
    final total = vote.totalVotes;
    final isOwner = post.creatorId == myUserId;
    // 原版：`post.creatorId == me && vote.isOpen()` 才显示「更多」
    final canManage = isOwner && vote.isOpen;

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.how_to_vote_outlined,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(t.chatFilterVote, style: theme.textTheme.labelMedium),
              const SizedBox(width: 8),
              // 原版卡片头不带「多选/匿名」标签：匿名和截止时间统一在下面那行
              // `voteInfoView` 里（`anonymous_vote` | `terminate_at`）
              if (closed)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    t.chatVoteClosed,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              const Spacer(),
              if (!deleted)
                Text(
                  t.chatVoteTotalVotes(total),
                  style: theme.textTheme.labelSmall,
                ),
              if (canManage)
                SizedBox(
                  height: 24,
                  width: 24,
                  child: PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    tooltip: t.photoMore,
                    onSelected: (v) => _onMenu(v, post, vote, myUserId),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: Text(t.chatVoteEditTitle),
                      ),
                      PopupMenuItem(
                        value: 'close',
                        child: Text(t.chatVoteCloseAction),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(t.chatVoteDeleteTitle),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          // 原版 `voteInfoView`：匿名 / 截止时间，用 ` | ` 连接
          if (!deleted && _infoLine(vote, t).isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              _infoLine(vote, t),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 6),
          if (deleted)
            Text(
              t.chatVoteDeleted,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...[
            for (final c in vote.choices)
              _ChoiceRow(
                choice: c,
                ratio: vote.ratioOf(c),
                selected: mine.contains(c.id),
                closed: closed,
                showCount: closed || mine.isNotEmpty || total > 0,
                onTap: closed || _busy
                    ? null
                    : () => _run(
                        () => ctrl.castVote(
                          channelId: post.channelId,
                          post: post,
                          choiceIds: _nextChoiceIds(vote, mine, c.id),
                        ),
                        t.chatVoteFailed,
                      ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                if (vote.addOption && !closed)
                  TextButton(
                    onPressed: _busy ? null : () => _addOption(post),
                    child: Text(t.chatVoteAddOption),
                  ),
                const Spacer(),
                TextButton(
                  // 「看结果」= 官方 `VoteResultFragment`：**先拉最新票数再开结果面板**。
                  // 以前这里只是静默刷新一次卡片 —— 没人投过票时卡片上的票数本来
                  // 就不显示，于是"点了没反应"（用户报告第 5 条）。
                  onPressed: _busy ? null : () => _showResults(post),
                  child: Text(t.chatVoteViewResults),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 卡片头那行「匿名 | 截止 …」（原版 `anonymous_vote` / `terminate_at`）
  String _infoLine(VoteDto vote, AppText t) {
    final parts = <String>[
      if (vote.anonymous) t.chatVoteAnonymous,
      if (vote.expireAt > 0)
        t.chatVoteEndsAt(
          DateTime.fromMillisecondsSinceEpoch(
            vote.expireAt,
          ).toString().substring(0, 16),
        ),
    ];
    return parts.join(' | ');
  }

  /// 「更多」菜单（编辑 / 结束 / 删除）
  Future<void> _onMenu(
    String action,
    PostDto post,
    VoteDto vote,
    int myUserId,
  ) async {
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    final t = context.t;
    switch (action) {
      case 'edit':
        // 原版 `EditVoteFragment.showPost`：`editable = 总票数 == 0`
        final draft = await showVoteEditor(
          context,
          initial: VoteDraft.fromVote(post.message, vote),
          editable: vote.totalVotes == 0,
          title: t.chatVoteEditTitle,
          submitLabel: t.actionSave,
        );
        if (draft == null || !mounted) return;
        await _run(
          () => ctrl.editVote(
            channelId: post.channelId,
            post: post,
            message: draft.message,
            choices: draft.choices,
            multiple: draft.multiple,
            anonymous: draft.anonymous,
            addOption: draft.addOption,
            expireAt: draft.expireAt,
          ),
          t.chatVoteEditFailed,
        );
      case 'close':
        await _run(
          () => ctrl.closeVote(channelId: post.channelId, post: post),
          t.chatVoteCloseFailed,
        );
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(t.chatVoteDeleteTitle),
            content: Text(t.chatVoteDeleteConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(t.actionCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(t.dtoActionDelete),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;
        await _run(
          () => ctrl.deleteVote(channelId: post.channelId, post: post),
          t.chatVoteDeleteFailed,
        );
    }
  }

  /// 单选：再点已选项 = 取消，点别的 = 换票；多选：加减
  List<String> _nextChoiceIds(VoteDto vote, Set<String> mine, String choiceId) {
    if (vote.multiple) {
      final next = {...mine};
      next.contains(choiceId) ? next.remove(choiceId) : next.add(choiceId);
      return next.toList();
    }
    return mine.contains(choiceId) ? const [] : [choiceId];
  }

  Future<void> _addOption(PostDto post) async {
    final t = context.t;
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.chatVoteAddOption),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.chatVoteChoiceHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(t.chatAdd),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    await _run(
      () =>
          ctrl.addVoteOption(channelId: post.channelId, post: post, text: text),
      t.chatVoteAddOptionFailed,
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.choice,
    required this.ratio,
    required this.selected,
    required this.closed,
    required this.showCount,
    this.onTap,
  });

  final VoteChoiceDto choice;
  final double ratio;
  final bool selected;
  final bool closed;
  final bool showCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          choice.text,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (showCount)
                        Text(
                          '${choice.count}',
                          style: theme.textTheme.labelSmall,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: showCount ? ratio : 0,
                    minHeight: 4,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「投票结果」面板（官方 `VoteResultFragment` + `VoteUsersFragment` 的合一视图）。
///
/// 为什么不是只刷新卡片：官方点「View results」是**打开一个结果页**
/// （`fragment_vote_result` / `item_vote_result`），而卡片上的票数在
/// "没人投票且我没投"时本来就不显示 ⇒ 只刷新等于没有任何可见反馈。
Future<void> showVoteResultsSheet(
  BuildContext context,
  WidgetRef ref, {
  required PostDto post,
  required List<VoteChoiceDto> choices,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _VoteResultsSheet(post: post, choices: choices),
);

class _VoteResultsSheet extends ConsumerStatefulWidget {
  const _VoteResultsSheet({required this.post, required this.choices});

  final PostDto post;
  final List<VoteChoiceDto> choices;

  @override
  ConsumerState<_VoteResultsSheet> createState() => _VoteResultsSheetState();
}

class _VoteResultsSheetState extends ConsumerState<_VoteResultsSheet> {
  /// userId → 显示名（`VoteUsersFragment` 要给人看的是名字，不是 id）
  Map<int, String> _names = const {};
  bool _loadingNames = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadNames());
  }

  Future<void> _loadNames() async {
    final vote = widget.post.vote;
    // 匿名投票不显示投票人（官方 anonymous_vote 的语义）
    if (vote == null || vote.anonymous) return;
    final ids = <int>{
      for (final c in widget.choices) ...c.voters,
    }.toList();
    if (ids.isEmpty) return;
    final api = ref.read(chatApiProvider);
    if (api == null) return;
    setState(() => _loadingNames = true);
    try {
      final users = await api.listUsersByIds(ids);
      if (mounted) {
        setState(() {
          _names = {for (final u in users) u.userId: userDisplayName(u)};
        });
      }
    } catch (_) {
      // 名字拿不到不影响票数展示，静默降级成 id
    } finally {
      if (mounted) setState(() => _loadingNames = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    final vote = widget.post.vote;
    final anonymous = vote?.anonymous ?? false;
    final total = widget.choices.fold<int>(0, (n, c) => n + c.count);
    final maxCount = widget.choices.fold<int>(
      0,
      (n, c) => c.count > n ? c.count : n,
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.chatVoteResultsTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  t.chatVoteTotalVotes(total),
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (widget.choices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(t.chatVoteNoVotes),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final c in widget.choices)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      c.text,
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ),
                                  Text(
                                    '${c.count}',
                                    style: theme.textTheme.labelMedium,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              LinearProgressIndicator(
                                value: maxCount <= 0 ? 0 : c.count / maxCount,
                                minHeight: 5,
                              ),
                              if (anonymous)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    t.chatVoteAnonymous,
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                )
                              else if (c.voters.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    _loadingNames
                                        ? t.chatManageLoading
                                        : c.voters
                                              .map(
                                                (id) =>
                                                    _names[id] ?? 'user $id',
                                              )
                                              .join(t.chatRowNameSeparator),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
