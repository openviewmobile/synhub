// 机器人列表（Phase 6）。
//
// 机器人就是 `type = "bot"` 的 user（`SYNO.Chat.User / list`），服务端按
// `bot_type` 分类：`synobot` / `slash` / `broadcast` / `chatbot`。
//   * `slash` 是斜杠命令（`/jitsi`），不进这个列表；
//   * `hide_from_user` 的（Synology Drive 之类通知机器人）也不列；
//   * 点一个机器人 → `SYNO.Chat.Channel.Chatbot / initiate` 建/取一对一频道。
import 'package:flutter/material.dart';

import '../../design/kit/design_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../data/dto/user_dto.dart';
import '../chat/chat_session_controller.dart';
import '../../core/user_facing_error.dart';

/// 界面上要展示的机器人（斜杠命令和隐藏的排除掉）
final listedBotsProvider = FutureProvider<List<UserDto>>((ref) async {
  final users = await ref.watch(chatStoreProvider).allUsers();
  final blocked = await ref
      .watch(chatSessionControllerProvider.notifier)
      .blockedBots();
  return users
      .where((u) => u.isListedBot && !blocked.contains(u.userId))
      .toList()
    ..sort((a, b) => a.displayName.compareTo(b.displayName));
});

class BotsPage extends ConsumerWidget {
  const BotsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(listedBotsProvider);
    final t = context.t;
    return DesignScaffold(
      appBar: AppBar(title: Text(t.botsTitle)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(t.botsLoadFailed(userFacingError(e)))),
        data: (bots) {
          if (bots.isEmpty) return Center(child: Text(t.botsEmpty));
          return ListView.separated(
            itemCount: bots.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final bot = bots[i];
              return DesignRowTile(
                leading: CircleAvatar(
                  radius: 20,
                  backgroundColor: _avatarColor(bot),
                  child: Text(
                    bot.displayName.isEmpty
                        ? '?'
                        : bot.displayName.characters.first.toUpperCase(),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                title: Text(bot.displayName),
                subtitle: Text(_botKind(t, bot)),
                onTap: () => _openChat(context, ref, bot),
              );
            },
          );
        },
      ),
    );
  }

  static Color _avatarColor(UserDto bot) {
    final hex = bot.avatarColor;
    if (hex.startsWith('#') && hex.length == 7) {
      final v = int.tryParse(hex.substring(1), radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return Colors.blueGrey;
  }

  static String _botKind(AppText t, UserDto bot) => switch (bot.botType) {
    'synobot' => t.botsKindSynobot,
    'broadcast' => t.botsKindBroadcast,
    'chatbot' =>
      bot.chatbotPurpose.isNotEmpty ? bot.chatbotPurpose : t.botsKindChatbot,
    _ => t.botsTitle,
  };

  Future<void> _openChat(
    BuildContext context,
    WidgetRef ref,
    UserDto bot,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final openFailed = context.t.botsOpenFailed;
    final channelId = await ref
        .read(chatSessionControllerProvider.notifier)
        .initiateChatbot(bot.userId);
    if (channelId <= 0) {
      messenger.showSnackBar(SnackBar(content: Text(openFailed)));
      return;
    }
    router.push(AppRoutes.chatAt(channelId, 0));
  }
}
