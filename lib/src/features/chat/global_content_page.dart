// 跨频道内容面板 —— 四 tab：话题 / 书签 / 提醒 / 定时消息。
//
// ⚠️ 证据说明（务必同 `docs/chat-p0b-implementation.md` 一起读）：
//   * 官方 `TabBookmarkFragment`（`TabBookmarkFragment.java`）虽然把
//     threads / bookmark / reminder / schedule_post 四个 tab 放在一起，
//     但它的 `newInstance(int channelId, int index)` **必须带 channelId**，
//     `ViewPagerAdapter.getItem` 也是按频道构造子 Fragment —— 它是**单频道**的
//     四 tab 面板，**不是**跨频道聚合。审计 §2.6 把它写成"首页右上角全局入口"
//     与反编译原文不符，本批据实纠正。
//   * 因此本页是**我们自加的编排**（跨频道），但每个 tab 的取数都走**有原文的**
//     接口：
//       - 话题：`Post/search` + `has:["subscribe"]`，不带 `in` → 天然跨频道；
//         官方后备路径就是它（`CommentsPresenter.fetchAllSubscribedPosts` 的
//         `onErrorReturn` → `searchSubscribes(has:[ACTION_SUBSCRIBE])`），
//         服务端 `SearchControl::HandleSubscribe`。
//       - 书签：`Post/search` + `has:["star"]`，不带 `in` —— 官方
//         `BookmarkPresenter.getHas()` = `["star"]`，服务端 `SearchControl::HasStar`。
//       - 提醒：`Post/Reminder/list` 的 `channel_id` **必填**
//         （`WebApiService.listReminder` 签名 + `user_reminders.channel_id` 非空），
//         服务端没有跨频道接口 → 本机对已加入频道**逐个拉再合并**。
//       - 定时：同理（`Schedule/list` 的 `channel_id` 必填，
//         `schedule_posts.channel_id` NOT NULL）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../data/chat_api.dart';
import '../../data/chat_error_text.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/vote_dto.dart';
import 'channel_content_page.dart' show formatPostTime;
import 'channel_scheduled_page.dart';
import 'chat_session_controller.dart';

/// 话题 tab：跨频道订阅话题（父贴）。
///
/// `Post/search has:["subscribe"]`，**不带 `in`** —— 服务端按我的订阅过滤，
/// 结果里有父贴也有回复，这里只留父贴（对齐官方 `post.isParent()` 过滤）。
final globalThreadsProvider = FutureProvider<List<PostDto>>((ref) async {
  final api = ref.watch(chatApiProvider);
  if (api == null) return const [];
  final result = await api.searchPosts(
    const PostSearchQuery(has: ['subscribe'], limit: 50),
  );
  final out = <PostDto>[];
  for (final raw in result.posts) {
    final dto = PostDto.fromJson(Map<String, dynamic>.from(raw));
    if (dto.postId > 0 && !dto.isThreadReply) out.add(dto);
  }
  out.sort((a, b) => b.createAt.compareTo(a.createAt));
  return out;
});

/// 书签 tab：跨频道星标消息。`Post/search has:["star"]`，不带 `in`。
final globalBookmarksProvider = FutureProvider<List<PostDto>>((ref) async {
  final api = ref.watch(chatApiProvider);
  if (api == null) return const [];
  final result = await api.searchPosts(
    const PostSearchQuery(has: ['star'], limit: 50),
  );
  final out = <PostDto>[];
  for (final raw in result.posts) {
    final dto = PostDto.fromJson(Map<String, dynamic>.from(raw));
    if (dto.postId > 0) out.add(dto);
  }
  out.sort((a, b) => b.createAt.compareTo(a.createAt));
  return out;
});

/// 提醒 tab：本机对每个已加入频道调 `Reminder/list` 后合并（服务端没有跨频道
/// 接口）。单个频道失败跳过，不让整页变错误态。
///
/// 直接调控制器（而不是套 `remindersProvider(channelId).future`）：这套
/// Riverpod 上嵌套 provider 的 `.future` 在"先成功首帧/再报错"两种边界都可能
/// 不 complete（本批 falsification 期间实测），跨频道 fan-out 不能赌它。
final globalRemindersProvider = FutureProvider<List<PostDto>>((ref) async {
  final channels = await _joinedChannels(ref);
  final ctrl = ref.read(chatSessionControllerProvider.notifier);
  final out = <PostDto>[];
  for (final c in channels) {
    try {
      out.addAll(await ctrl.listReminders(c.channelId));
    } catch (_) {
      // 该频道拉不到就跳过（保留其它频道的）
    }
  }
  out.sort((a, b) => a.remindAt.compareTo(b.remindAt));
  return out;
});

/// 定时消息 tab：同提醒，逐个频道合并。
final globalScheduledProvider = FutureProvider<List<ScheduledPostDto>>((
  ref,
) async {
  final channels = await _joinedChannels(ref);
  final ctrl = ref.read(chatSessionControllerProvider.notifier);
  final out = <ScheduledPostDto>[];
  for (final c in channels) {
    try {
      out.addAll(await ctrl.listScheduledPosts(c.channelId));
    } catch (_) {
      // 同上
    }
  }
  out.sort((a, b) => a.sendAt.compareTo(b.sendAt));
  return out;
});

/// 已加入频道（按 `channel_order_time`/`last_post_at` 排好的顺序）。
///
/// `ref.watch(channelsProvider)` 用来在频道表变化时重建；
/// **值本身直接读本地库**：`channelsProvider` 是 StreamProvider，
/// 首帧 `.value` 可能还是 null（drift 的 `watch()` 要等一个事件循环），
/// 用 `.future` 在这套 Riverpod 上会一直挂住（见本批测试）。
Future<List<ChannelDto>> _joinedChannels(Ref ref) async {
  ref.watch(channelsProvider);
  final all = await ref.read(chatStoreProvider).allChannels();
  return all.where((c) => c.isJoined).toList();
}

class GlobalContentPage extends ConsumerWidget {
  const GlobalContentPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(dataText('chatGlobalPanelTitle', '跨频道内容')),
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              Tab(
                icon: const Icon(Icons.forum_outlined, size: 18),
                text: dataText('chatGlobalTabThreads', '话题'),
              ),
              Tab(
                icon: const Icon(Icons.star_border, size: 18),
                text: dataText('chatBookmarks', '书签'),
              ),
              Tab(
                icon: const Icon(Icons.alarm, size: 18),
                text: dataText('chatGlobalTabReminders', '提醒'),
              ),
              Tab(
                icon: const Icon(Icons.schedule_send_outlined, size: 18),
                text: dataText('chatGlobalTabScheduled', '定时'),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: context.t.photoRefresh,
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.invalidate(globalThreadsProvider);
                ref.invalidate(globalBookmarksProvider);
                ref.invalidate(globalRemindersProvider);
                ref.invalidate(globalScheduledProvider);
              },
            ),
          ],
        ),
        body: TabBarView(
          children: [
            _ThreadsTab(),
            _BookmarksTab(),
            _RemindersTab(),
            _ScheduledTab(),
          ],
        ),
      ),
    );
  }
}

/// 频道名（跨频道列表每行都要标）
String _channelLabel(Map<int, ChannelDto> channels, int channelId) {
  final c = channels[channelId];
  if (c == null) return '#$channelId';
  return c.name.isNotEmpty ? c.name : '#$channelId';
}

Map<int, ChannelDto> _channelMap(WidgetRef ref) {
  final list = ref.watch(channelsProvider).value ?? const <ChannelDto>[];
  return {for (final c in list) c.channelId: c};
}

/// 提醒/定时两 tab 的小字提示：跨频道是**本机汇总**，官方没有跨频道接口。
class _FanoutNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: Text(
      dataText('chatGlobalFanoutNote', '本页由本机逐个频道汇总（服务端该接口按频道查询）'),
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}

class _ThreadsTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(globalThreadsProvider);
    final channels = _channelMap(ref);
    return _AsyncList<PostDto>(
      async: async,
      empty: dataText('chatNoSubscribedThreads', '还没有订阅的话题'),
      onRetry: () => ref.invalidate(globalThreadsProvider),
      itemBuilder: (context, post) => DesignRowTile(
        leading: const Icon(Icons.forum_outlined),
        title: Text(
          post.message.isEmpty
              ? dataText('chatPostNoBody', '（无正文）')
              : post.message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${_channelLabel(channels, post.channelId)}'
          ' · ${formatPostTime(post.createAt)}'
          ' · ${context.t.chatReplyCount(post.commentCount)}',
        ),
        trailing: const Icon(Icons.chevron_right, size: 16),
        onTap: () =>
            context.push(AppRoutes.threadOf(post.channelId, post.postId)),
      ),
    );
  }
}

class _BookmarksTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(globalBookmarksProvider);
    final channels = _channelMap(ref);
    return _AsyncList<PostDto>(
      async: async,
      empty: dataText('chatNoBookmarks', '还没有星标消息'),
      onRetry: () => ref.invalidate(globalBookmarksProvider),
      itemBuilder: (context, post) => DesignRowTile(
        leading: const Icon(Icons.star, color: Colors.amber),
        title: Text(
          post.message.isEmpty
              ? dataText('chatPostNoBody', '（无正文）')
              : post.message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${_channelLabel(channels, post.channelId)}'
          ' · ${formatPostTime(post.createAt)}',
        ),
        trailing: IconButton(
          tooltip: context.t.driveUnstar,
          icon: const Icon(Icons.bookmark_remove_outlined),
          onPressed: () async {
            final ok = await ref
                .read(chatSessionControllerProvider.notifier)
                .setStar(post.channelId, post.postId, star: false);
            if (!context.mounted) return;
            if (ok) {
              ref.invalidate(globalBookmarksProvider);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    dataText(
                      'chatBookmarkRemoveFailed',
                      '取消星标失败，请重试。',
                    ),
                  ),
                ),
              );
            }
          },
        ),
        onTap: () => context.push(
          AppRoutes.chatAt(post.channelId, post.postId),
        ),
      ),
    );
  }
}

class _RemindersTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(globalRemindersProvider);
    final channels = _channelMap(ref);
    return Column(
      children: [
        _FanoutNote(),
        Expanded(
          child: _AsyncList<PostDto>(
            async: async,
            empty: context.t.chatRemindersEmpty,
            onRetry: () => ref.invalidate(globalRemindersProvider),
            itemBuilder: (context, post) {
              final overdue =
                  post.remindAt > 0 &&
                  post.remindAt < DateTime.now().millisecondsSinceEpoch;
              return DesignRowTile(
                leading: Icon(
                  overdue ? Icons.alarm_on : Icons.alarm,
                  color: overdue ? Theme.of(context).colorScheme.error : null,
                ),
                title: Text(
                  post.message.isEmpty
                      ? context.t.chatPostNoBody
                      : post.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${_channelLabel(channels, post.channelId)}'
                  ' · ${context.t.chatReminderAt(formatDateTime(post.remindAt))}',
                ),
                trailing: IconButton(
                  tooltip: context.t.chatReminderCancel,
                  icon: const Icon(Icons.alarm_off_outlined),
                  onPressed: () async {
                    await ref
                        .read(chatSessionControllerProvider.notifier)
                        .clearReminder(channelId: post.channelId, post: post);
                    ref.invalidate(globalRemindersProvider);
                  },
                ),
                onTap: () => context.push(
                  AppRoutes.chatAt(post.channelId, post.postId),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ScheduledTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(globalScheduledProvider);
    final channels = _channelMap(ref);
    return Column(
      children: [
        _FanoutNote(),
        Expanded(
          child: _AsyncList<ScheduledPostDto>(
            async: async,
            empty: context.t.chatScheduledEmpty,
            onRetry: () => ref.invalidate(globalScheduledProvider),
            itemBuilder: (context, s) => DesignRowTile(
              leading: Icon(
                s.isPending ? Icons.schedule : Icons.hourglass_bottom,
                color: s.isPending
                    ? null
                    : Theme.of(context).colorScheme.error,
              ),
              title: Text(
                s.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_channelLabel(channels, s.channelId)}'
                ' · ${context.t.chatScheduledSendAt(formatDateTime(s.sendAt))}',
              ),
              trailing: IconButton(
                tooltip: context.t.actionCancel,
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await ref
                      .read(chatSessionControllerProvider.notifier)
                      .deleteScheduledPost(s.cronjobId);
                  ref.invalidate(globalScheduledProvider);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// loading / error / empty / list 四态的统一渲染
class _AsyncList<T> extends StatelessWidget {
  const _AsyncList({
    required this.async,
    required this.empty,
    required this.onRetry,
    required this.itemBuilder,
  });

  final AsyncValue<List<T>> async;
  final String empty;
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T item) itemBuilder;

  @override
  Widget build(BuildContext context) => async.when(
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (e, _) => Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 提醒/定时 tab 的 401/402 聊天语义未取证 → 「未知错误 + 原始码」
          Text(
            context.t.botsLoadFailed(describeChatWave1Error(e)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: onRetry,
            child: Text(context.t.photoRetry),
          ),
        ],
      ),
    ),
    data: (list) {
      if (list.isEmpty) return Center(child: Text(empty));
      return RefreshIndicator(
        onRefresh: () async => onRetry(),
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => itemBuilder(context, list[i]),
        ),
      );
    },
  );
}
