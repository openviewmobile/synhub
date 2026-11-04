// 频道里跟"时间"有关的两个列表（Phase 6）：
//   * 定时消息 `SYNO.Chat.Post.Schedule / list` → `{schedule_posts:[...]}`
//   * 提醒     `SYNO.Chat.Post.Reminder / list` → `{posts:[...]}`（时间在 props.remind_at）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../data/chat_error_text.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/vote_dto.dart';
import 'chat_session_controller.dart';

/// 定时消息的"版本号"：服务端 `post.schedule.set/delete` 广播打进来时 +1。
///
/// 原版是 `SchedulePostEvent` 走 EventBus 直接改界面列表；我们让
/// [scheduledPostsProvider] `watch` 它 —— 控制器不去 invalidate 那个 provider
/// （那会绕成 `provider → 控制器 → provider` 的循环依赖，Riverpod 会直接报错）。
final scheduleRevisionProvider =
    NotifierProvider.family<ScheduleRevision, int, int>(ScheduleRevision.new);

class ScheduleRevision extends Notifier<int> {
  ScheduleRevision(this.channelId);

  final int channelId;

  @override
  int build() => 0;

  void bump() => state = state + 1;
}

/// 拉定时消息列表
final scheduledPostsProvider =
    FutureProvider.family<List<ScheduledPostDto>, int>((ref, channelId) {
      // 版本号变了就重拉
      ref.watch(scheduleRevisionProvider(channelId));
      return ref
          .watch(chatSessionControllerProvider.notifier)
          .listScheduledPosts(channelId);
    });

/// 拉提醒列表
final remindersProvider = FutureProvider.family<List<PostDto>, int>((
  ref,
  channelId,
) {
  return ref
      .watch(chatSessionControllerProvider.notifier)
      .listReminders(channelId);
});

String formatDateTime(int millis) {
  if (millis <= 0) return '-';
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}/${two(d.month)}/${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class ScheduledMessagesPage extends ConsumerWidget {
  const ScheduledMessagesPage({super.key, required this.channelId});

  final int channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(scheduledPostsProvider(channelId));
    return Scaffold(
      appBar: AppBar(title: Text(context.t.chatScheduledTitle)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 401/402 在聊天侧语义未取证 → 「未知错误 + 原始码」，不猜文案
              Text(context.t.botsLoadFailed(describeChatWave1Error(e))),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () =>
                    ref.invalidate(scheduledPostsProvider(channelId)),
                child: Text(context.t.photoRetry),
              ),
            ],
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(child: Text(context.t.chatScheduledEmpty));
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = list[i];
              return DesignRowTile(
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
                  context.t.chatScheduledSendAt(formatDateTime(s.sendAt)),
                ),
                trailing: IconButton(
                  tooltip: context.t.actionCancel,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await ref
                        .read(chatSessionControllerProvider.notifier)
                        .deleteScheduledPost(s.cronjobId);
                    ref.invalidate(scheduledPostsProvider(channelId));
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class RemindersPage extends ConsumerWidget {
  const RemindersPage({super.key, required this.channelId});

  final int channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(remindersProvider(channelId));
    return Scaffold(
      appBar: AppBar(title: Text(context.t.notifyReminderTitle)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 401/402 在聊天侧语义未取证 → 「未知错误 + 原始码」，不猜文案
              Text(context.t.botsLoadFailed(describeChatWave1Error(e))),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => ref.invalidate(remindersProvider(channelId)),
                child: Text(context.t.photoRetry),
              ),
            ],
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(child: Text(context.t.chatRemindersEmpty));
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final post = list[i];
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
                  context.t.chatReminderAt(formatDateTime(post.remindAt)),
                ),
                trailing: IconButton(
                  tooltip: context.t.chatReminderCancel,
                  icon: const Icon(Icons.alarm_off_outlined),
                  onPressed: () async {
                    await ref
                        .read(chatSessionControllerProvider.notifier)
                        .clearReminder(channelId: channelId, post: post);
                    ref.invalidate(remindersProvider(channelId));
                  },
                ),
                onTap: () =>
                    context.push(AppRoutes.chatAt(channelId, post.postId)),
              );
            },
          );
        },
      ),
    );
  }
}
