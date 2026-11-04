// 「已读成员 / 未读成员」页（对齐原版 `ReadStatusFragment` + `ReadStatusAdapter`）。
//
// 从消息长按菜单进（原版两个入口：`show_read_list` = 已读成员、
// `show_unread_list` = 未读成员），只在**自己发的**消息上、且服务端
// `allow_read_status` 打开时才显示。
//
// 数据来源：`SYNO.Chat.Post / get_read_status` **v6**，响应
// `{read_users: [...], unread_users: [...]}`，本页只展示其中一组。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../data/dto/user_dto.dart';
import 'chat_session_controller.dart';
import '../../core/user_facing_error.dart';

/// 一条消息的已读/未读名单（Riverpod family：postId → 名单）
final readStatusProvider =
    FutureProvider.family<({List<int> readUsers, List<int> unreadUsers}), int>((
      ref,
      postId,
    ) async {
      final api = ref.watch(chatSessionControllerProvider.notifier).chatApi;
      if (api == null) {
        throw StateError(currentText().profileEditNotConnected);
      }
      return api.fetchReadStatus(postId);
    });

class ReadStatusPage extends ConsumerStatefulWidget {
  const ReadStatusPage({
    super.key,
    required this.postId,
    this.readUsers = true,
  });

  final int postId;

  /// true = 看已读，false = 看未读（原版 `ReadStatusFragment.newInstance(postId, z)`）
  final bool readUsers;

  @override
  ConsumerState<ReadStatusPage> createState() => _ReadStatusPageState();
}

class _ReadStatusPageState extends ConsumerState<ReadStatusPage> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(readStatusProvider(widget.postId));
    final users = ref.watch(usersProvider).value ?? const <UserDto>[];
    final byId = {for (final u in users) u.userId: u};

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.readUsers
              ? context.t.chatActionReadUsers
              : context.t.chatActionUnreadUsers,
        ),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 36),
                const SizedBox(height: 8),
                Text(
                  context.t.chatReadStatusLoadFailed(
                    userFacingError(e),
                  ),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () =>
                      ref.invalidate(readStatusProvider(widget.postId)),
                  child: Text(context.t.photoRetry),
                ),
              ],
            ),
          ),
        ),
        data: (data) {
          final ids = widget.readUsers ? data.readUsers : data.unreadUsers;
          var list = <UserDto>[
            for (final id in ids)
              byId[id] ??
                  UserDto(
                    userId: id,
                    username: context.t.chatUserFallback(id),
                    type: 'human',
                  ),
          ];
          list.sort((a, b) => a.displayName.compareTo(b.displayName));
          final query = _filter.text.trim().toLowerCase();
          final shown = query.isEmpty
              ? list
              : list
                    .where(
                      (u) =>
                          u.displayName.toLowerCase().contains(query) ||
                          u.username.toLowerCase().contains(query),
                    )
                    .toList();

          if (ids.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.readUsers
                        ? Icons.done_all
                        : Icons.mark_chat_unread_outlined,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.readUsers
                        ? context.t.chatReadStatusNoReaders
                        : context.t.chatReadStatusAllRead,
                  ),
                ],
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  controller: _filter,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: context.t.chatSearchMembers,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.readUsers
                        ? context.t.chatReadStatusReadCount(shown.length)
                        : context.t.chatReadStatusUnreadCount(shown.length),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: shown.isEmpty
                    ? Center(child: Text(context.t.chatReadStatusNoMatch))
                    : ListView.separated(
                        itemCount: shown.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final u = shown[i];
                          return DesignRowTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.secondaryContainer,
                              child: Text(
                                u.displayName.isEmpty
                                    ? '?'
                                    : u.displayName.characters.first
                                          .toUpperCase(),
                              ),
                            ),
                            title: Text(u.displayName),
                            subtitle: u.username == u.displayName
                                ? null
                                : Text(u.username),
                            onTap: () => showModalBottomSheet<void>(
                              context: context,
                              showDragHandle: true,
                              builder: (ctx) => Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  0,
                                  20,
                                  24,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      u.displayName,
                                      style: Theme.of(ctx).textTheme.titleLarge,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      ctx.t.chatReadStatusAccountInfo(
                                        u.username,
                                        u.userId,
                                      ),
                                    ),
                                    Text(
                                      u.status.isEmpty
                                          ? ''
                                          : ctx.t.chatReadStatusUserStatus(
                                              u.status,
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
