// 话题（thread）页 —— 原 App 里的 "Comments" 面板。
//
// 关键结论（反编译 CommentsFragment/CommentsPresenter）：
//   回复就是**带 `thread_id` 的普通消息**（`Post/create` + `is_thread=true`），
//   没有独立的 comment API；话题未读用 `SYNO.Chat.Post.Subscribe/view` 上报，
//   服务端回 `last_view_comment_at`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/user_dto.dart';
import 'chat_session_controller.dart';
import 'post_actions_sheet.dart';
import 'rich_text.dart';
import '../../core/ui/app_states.dart';
import '../../core/user_facing_error.dart';

/// 某话题的回复流（新的在前）
final threadRepliesProvider =
    StreamProvider.family<List<PostDto>, ({int channelId, int parentId})>(
      (ref, key) => ref
          .watch(chatStoreProvider)
          .watchPosts(key.channelId, threadId: key.parentId, limit: 200),
    );

class ThreadPage extends ConsumerStatefulWidget {
  const ThreadPage({
    super.key,
    required this.channelId,
    required this.parentPostId,
  });

  final int channelId;
  final int parentPostId;

  @override
  ConsumerState<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends ConsumerState<ThreadPage> {
  final _input = TextEditingController();
  bool _sending = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      await ref
          .read(chatSessionControllerProvider.notifier)
          .loadThreadReplies(widget.channelId, widget.parentPostId);
    } catch (_) {
      // 拉不到就用本地已有的
    }
    await ref
        .read(chatSessionControllerProvider.notifier)
        .markThreadRead(widget.channelId, threadId: widget.parentPostId);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await ref
        .read(chatSessionControllerProvider.notifier)
        .sendThreadReply(widget.channelId, widget.parentPostId, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) {
      _input.clear();
      FocusScope.of(context).unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = (channelId: widget.channelId, parentId: widget.parentPostId);
    final replies = ref.watch(threadRepliesProvider(key));
    final parent = ref
        .watch(postsProvider(widget.channelId))
        .value
        ?.where((p) => p.postId == widget.parentPostId)
        .firstOrNull;
    final users = ref.watch(usersProvider).value ?? const <UserDto>[];
    final userMap = <int, UserDto>{for (final u in users) u.userId: u};
    final sync = ref.watch(chatSessionControllerProvider);
    final canWrite = sync.connId != null && sync.connId!.isNotEmpty;

    final channel = ref.watch(channelProvider(widget.channelId));
    // 我订阅了没有：`channel.subscribes` 里是话题 id
    // （主消息自己就是话题，所以用 parentPostId 判）
    final subscribed =
        channel?.subscribes.contains(widget.parentPostId) ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.chatThreadTitle),
        actions: [
          IconButton(
            tooltip: context.t.chatThreadMarkAllRead,
            icon: const Icon(Icons.done_all),
            onPressed: () => ref
                .read(chatSessionControllerProvider.notifier)
                .markThreadRead(
                  widget.channelId,
                  threadId: widget.parentPostId,
                ),
          ),
          IconButton(
            tooltip: subscribed
                ? context.t.chatThreadUnsubscribe
                : context.t.chatThreadSubscribe,
            icon: Icon(
              subscribed
                  ? Icons.notifications_active
                  : Icons.notifications_none,
            ),
            onPressed: () async {
              final t = context.t;
              final messenger = ScaffoldMessenger.of(context);
              final ok = await ref
                  .read(chatSessionControllerProvider.notifier)
                  .setPostSubscribed(
                    widget.channelId,
                    widget.parentPostId,
                    subscribed: !subscribed,
                  );
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    ok
                        ? (subscribed
                              ? t.chatThreadUnsubscribed
                              : t.chatThreadSubscribe)
                        : t.chatActionFailed,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (parent != null)
            // 「原帖」引用块：被引用消息长度不可控，2.0 缩放下这一段能比整屏
            // 还高，把下面的回复列表和输入框挤出屏幕（实测溢出 285px）。
            // 给它一个**相对视口的高度上限**，超出部分自己在块内滚动：
            // 信息一条不丢，也不会再顶爆外层的 Column。
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.4,
              ),
              child: Container(
                width: double.infinity,
                color: theme.colorScheme.surfaceContainerHighest,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.t.chatThreadOriginalMessage,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      MessageText(
                        parent.message,
                        mentions: parent.mentions,
                        mentionNames: mentionNamesById(users),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: replies.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              // ★ 以前只给一行错误文本、没有重试：流断了以后这一屏就死了
              //   （连"重新加载"都没有，只能退出话题再进来）。
              error: (e, __) => AppErrorView(
                key: const Key('thread-replies-error'),
                detail: userFacingError(e),
                onRetry: () => ref.invalidate(threadRepliesProvider(key)),
              ),
              data: (list) {
                if (list.isEmpty) {
                  return Center(child: Text(context.t.chatThreadNoReplies));
                }
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final reply = list[i];
                    final sender = userMap[reply.creatorId];
                    return _ReplyTile(
                      reply: reply,
                      senderName:
                          sender?.displayName ??
                          context.t.chatUserFallback(reply.creatorId),
                      mine: reply.creatorId == sync.myUserId,
                      mentionNames: mentionNamesById(users),
                      onLongPress: () => _onLongPress(reply),
                    );
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: canWrite,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: canWrite
                            ? context.t.chatThreadReplyHint
                            : context.t.chatRealtimeNotReady,
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: canWrite && !_sending ? _send : null,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onLongPress(PostDto reply) async {
    final sync = ref.read(chatSessionControllerProvider);
    final mine = reply.creatorId == sync.myUserId;
    final action = await showPostActionsSheet(
      context,
      post: reply,
      mine: mine,
      canWrite: sync.connId?.isNotEmpty ?? false,
      isThreadReply: true,
      // 话题内置顶（`Post/stick` v2）：能力关闭或已 407 → 不暴露入口
      allowStick: sync.supportsStick && !sync.stickUnsupported,
    );
    if (action == null || !mounted) return;
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    switch (action) {
      case PostAction.copy:
        await copyPostMessage(context, reply.message);
      case PostAction.delete:
        await ctrl.deleteMessage(widget.channelId, reply.postId);
      case PostAction.star:
        await ctrl.setStar(widget.channelId, reply.postId, star: true);
      case PostAction.unstar:
        await ctrl.setStar(widget.channelId, reply.postId, star: false);
      case PostAction.stick:
        await _toggleStick(reply, stick: true);
      case PostAction.unstick:
        await _toggleStick(reply, stick: false);
      case PostAction.react:
        final emoji = await showReactionPicker(context);
        if (emoji != null) {
          await ctrl.setReaction(
            widget.channelId,
            reply.postId,
            on: true,
            stickerName: emoji,
          );
        }
      default:
        break;
    }
  }

  /// 话题内置顶 / 取消（`Post/stick` v2）—— 失败给明确提示，不静默
  Future<void> _toggleStick(PostDto reply, {required bool stick}) async {
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    final ok = await ctrl.setStick(widget.channelId, reply.postId, stick: stick);
    if (!mounted || ok) return;
    final unsupported = ref
        .read(chatSessionControllerProvider)
        .stickUnsupported;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          unsupported
              ? dataText('chatStickUnsupported', '服务端未开启话题内置顶')
              : dataText('chatStickFailed', '话题内置顶失败，请重试。'),
        ),
      ),
    );
  }
}

class _ReplyTile extends StatelessWidget {
  const _ReplyTile({
    required this.reply,
    required this.senderName,
    required this.mine,
    required this.mentionNames,
    required this.onLongPress,
  });

  final PostDto reply;
  final String senderName;
  final bool mine;
  final Map<int, String> mentionNames;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              senderName,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: mine
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: MessageText(
                reply.message,
                mentions: reply.mentions,
                mentionNames: mentionNames,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (reply.isStar)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.star, size: 12, color: Colors.amber),
              ),
          ],
        ),
      ),
    );
  }
}
