// 频道的标签列表（Phase 6）：`SYNO.Chat.Channel.Hashtag / list` v1 → `{hashtags:[...]}`。
// 点一个标签 → 跳到搜索页按该标签过滤（`SearchQuery(hashtags:[tag])`）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import 'chat_session_controller.dart';
import '../../core/user_facing_error.dart';

final channelHashtagsProvider = FutureProvider.family<List<String>, int>((
  ref,
  channelId,
) {
  return ref
      .watch(chatSessionControllerProvider.notifier)
      .channelHashtags(channelId);
});

class ChannelHashtagsPage extends ConsumerWidget {
  const ChannelHashtagsPage({super.key, required this.channelId});

  final int channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(channelHashtagsProvider(channelId));
    return Scaffold(
      appBar: AppBar(title: Text(context.t.noteTags)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(context.t.botsLoadFailed(userFacingError(e)))),
        data: (tags) {
          if (tags.isEmpty) {
            return Center(child: Text(context.t.chatHashtagsEmpty));
          }
          return ListView(
            children: [
              for (final tag in tags)
                DesignRowTile(
                  leading: const Icon(Icons.tag),
                  title: Text('#$tag'),
                  onTap: () => context.push(AppRoutes.searchName, extra: tag),
                ),
            ],
          );
        },
      ),
    );
  }
}
