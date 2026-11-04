// 订阅话题列表页 —— 对齐官方 `CommentsFragment`（频道菜单里的 "Threads"）。
//
// 官方证据（反编译 2.11.1）：
//   * 入口：`res/menu/menu_channel.xml @+id/threads`；`ChannelFragment.java:645-646`
//     `mCallbacks.showThreads(mChannelId)` → `MainActivity.java:974-975`
//     `showTabBookmarkFragment(channelId, 0)`。
//   * 列表：`CommentsPresenter.fetchAllSubscribedPosts` →
//     `AccountManager.fetchThreadList(channelId, offset, limit, related_comment_count=1)`
//     （`SYNO.Chat.Post / thread_list` v5）；失败时 `onErrorReturn` 降级到
//     `searchSubscribes(..., has:["subscribe"], sort_by=last_comment_at)`。
//   * 空态原文：`comments_empty` "No subscribed discussion threads."。
//
// 我们的取数封在 `ChatSessionController.listSubscribedThreads`（同样主/备两条路）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/user_dto.dart';
import 'channel_content_page.dart' show formatPostTime;
import 'chat_session_controller.dart';
import '../../core/user_facing_error.dart';

/// 某频道里"我订阅的话题"（父贴）
final subscribedThreadsProvider = FutureProvider.family<List<PostDto>, int>(
  (ref, channelId) => ref
      .watch(chatSessionControllerProvider.notifier)
      .listSubscribedThreads(channelId),
);

class SubscribedThreadsPage extends ConsumerWidget {
  const SubscribedThreadsPage({super.key, required this.channelId});

  final int channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(subscribedThreadsProvider(channelId));
    final users = ref.watch(usersProvider).value ?? const <UserDto>[];
    final userMap = <int, UserDto>{for (final u in users) u.userId: u};
    final mine = ref.watch(chatSessionControllerProvider).myUserId;
    return Scaffold(
      appBar: AppBar(
        title: Text(dataText('chatSubscribedThreadsTitle', '订阅话题')),
        actions: [
          IconButton(
            tooltip: context.t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(subscribedThreadsProvider(channelId)),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.t.botsLoadFailed(userFacingError(e)), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () =>
                    ref.invalidate(subscribedThreadsProvider(channelId)),
                child: Text(context.t.photoRetry),
              ),
            ],
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Text(dataText('chatNoSubscribedThreads', '还没有订阅的话题')),
            );
          }
          return RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(subscribedThreadsProvider(channelId)),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final post = list[i];
                final sender = userMap[post.creatorId];
                return DesignRowTile(
                  leading: const Icon(Icons.forum_outlined),
                  title: Text(
                    post.message.isEmpty
                        ? dataText('chatPostNoBody', '（无正文）')
                        : post.message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${post.creatorId == mine ? context.t.chatAuthorMe : (sender?.displayName ?? context.t.chatUserFallback(post.creatorId))}'
                    ' · ${formatPostTime(post.createAt)}'
                    ' · ${context.t.chatReplyCount(post.commentCount)}',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 16),
                  onTap: () => context.push(
                    AppRoutes.threadOf(channelId, post.postId),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
