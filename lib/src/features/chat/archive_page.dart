// 归档频道页（`SYNO.Chat.Archive / list`，只认 `type="encrypted"`）。
//
// 归档 = 被归档的**加密频道**：`props.channel` 里带着封给我的 `channel_key_enc`，
// 所以能不能读取决于那把钥匙解不解得开（跟普通加密频道同一套判定）。
// 这台 NAS 上归档是空的，所以主要靠离线测试 + 空状态兜底。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../data/dto/archive_dto.dart';
import '../../data/e2ee/e2ee_service.dart';
import '../settings/e2ee_controller.dart';
import 'chat_session_controller.dart';
import '../../core/user_facing_error.dart';

/// `Archive/list` 的结果缓存（进页面拉一次，手动刷新）
final archivesProvider = FutureProvider<List<ArchiveDto>>((ref) async {
  return ref.read(chatSessionControllerProvider.notifier).listArchives();
});

class ArchivePage extends ConsumerWidget {
  const ArchivePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final archives = ref.watch(archivesProvider);
    // 解锁状态变了要重画（密钥状态会跟着变）
    ref.watch(e2eeControllerProvider);
    final e2ee = ref.read(e2eeControllerProvider.notifier);

    return DesignScaffold(
      appBar: AppBar(
        title: Text(context.t.meArchives),
        actions: [
          IconButton(
            tooltip: context.t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(archivesProvider),
          ),
        ],
      ),
      body: archives.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(context.t.botsLoadFailed(userFacingError(e)))),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.t.chatArchiveEmpty,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final a = list[i];
              final channel = a.channel;
              final state = e2ee.keyStateOf(channel);
              final (icon, color, text) = switch (state) {
                ChannelKeyState.ready => (
                  Icons.lock_open,
                  Theme.of(context).colorScheme.primary,
                  context.t.chatArchiveReadable,
                ),
                ChannelKeyState.locked => (
                  Icons.lock_clock,
                  Theme.of(context).colorScheme.tertiary,
                  context.t.chatArchiveLocked,
                ),
                ChannelKeyState.missing => (
                  Icons.report_gmailerrorred,
                  Theme.of(context).colorScheme.error,
                  context.t.chatArchiveKeyUnavailable,
                ),
                ChannelKeyState.notEncrypted => (
                  Icons.folder_outlined,
                  Theme.of(context).colorScheme.outline,
                  context.t.e2eeKeyStateNotEncrypted,
                ),
              };
              // DA1（r378 修）：`›` 原本对**所有**行都画，包括钥匙未就绪的行 ——
              // 那种行点下去去的是 E2EE 页（去设密钥），**不是**进频道。
              // 箭头形状必须与"点下去去哪"一致：进频道 = `›`；要先去设密钥 = 锁形 + 提示。
              final canOpenChannel =
                  state == ChannelKeyState.ready ||
                  state == ChannelKeyState.notEncrypted;
              return DesignRowTile(
                leading: Icon(icon, color: color),
                title: Text(
                  channel.name.isEmpty
                      ? context.t.chatChannelHash(channel.channelId)
                      : channel.name,
                ),
                subtitle: Text(
                  [
                    context.t.chatArchiveHashId(a.archiveId),
                    if (channel.members.isNotEmpty)
                      context.t.chatArchiveMemberCount(channel.members.length),
                    text,
                  ].join(' · '),
                ),
                trailing: canOpenChannel
                    ? const Icon(Icons.chevron_right)
                    : Tooltip(
                        message: context.t.chatArchiveUnlockHint,
                        child: const Icon(Icons.lock_outline),
                      ),
                onTap: canOpenChannel
                    ? () => context.push(AppRoutes.chatOf(channel.channelId))
                    : () => context.push(AppRoutes.e2ee),
              );
            },
          );
        },
      ),
    );
  }
}
