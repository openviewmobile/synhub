// 用户资料弹窗 —— 点 @提及 / 点频道成员时打开的那一面。
//
// 权威来源：官方 `ProfileFragment` / `ProfilePresenter`（Android-SynologyChat
// 2.11.1-607）：
//   * 资料数据来自**本地用户表**（`AccountManager.queryUser(userId)` →
//     `DatabaseHelper.queryUser`），字段就是 `UserVo` + `ProfileVo`
//     （`username` / `nickname` / `email` / `description` / `timezone` /
//     `key_pair` …）—— 不是另起一个接口；
//   * 底部动作按钮 = 「发消息」→ `ProfilePresenter.initiateAnonymous(userId)`
//     → `AccountManager.initiateAnonymous` → **`SYNO.Chat.Channel.Anonymous /
//     initiate` v1**（`user_ids` / `channel_key_encs` / `encrypted`），
//     成功后 `initiateSuccess(channelId)` 直接把频道推给聊天页。
//
// 这里把弹窗抽成**一个**实现，让「频道成员页」与「聊天正文里的 @提及」
// 两个入口共用（§2.0.8 ④：同一份东西不要两套实现）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../core/settings/acl.dart';
import '../../core/user_facing_error.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/user_dto.dart';
import 'chat_session_controller.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';

/// 打开某个用户的资料弹窗。
///
/// [channel] 非空时会多显示一行"在这个频道里"的状态（加密频道 broken 提示）。
/// [resolved] = false 时只显示名字 + "资料不可用"（服务端查不到这个人，
/// 例如提及里的 `@u:<id>` 指向一个已删除/不可见的账号）——**不装死**。
Future<void> showUserProfileSheet(
  BuildContext context,
  WidgetRef ref, {
  required UserDto user,
  ChannelDto? channel,
  bool resolved = true,
}) {
  // analytics: opening a profile sheet (page only, no user identity)
  trackView(UsageModule.chat, screen: 'profile');
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => _UserProfileSheet(
      ref: ref,
      user: user,
      channel: channel,
      resolved: resolved,
      outerContext: context,
    ),
  );
}

/// 资料查不到时的诚实空态：显示提及里那个名字 + 明确原因。
Future<void> showUnavailableUserProfile(
  BuildContext context, {
  required String name,
  int userId = 0,
}) {
  // analytics: the unavailable-profile empty state is the same profile surface
  trackView(UsageModule.chat, screen: 'profile');
  final t = context.t;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name.isEmpty ? t.chatUserFallback(userId) : name,
            style: Theme.of(ctx).textTheme.titleLarge,
          ),
          if (userId > 0) const SizedBox(height: 4),
          if (userId > 0) Text(t.chatProfileAccount(name, userId)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.person_off_outlined,
                size: 18,
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  t.chatProfileUnavailable,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _UserProfileSheet extends StatefulWidget {
  const _UserProfileSheet({
    required this.ref,
    required this.user,
    required this.channel,
    required this.resolved,
    required this.outerContext,
  });

  final WidgetRef ref;
  final UserDto user;
  final ChannelDto? channel;
  final bool resolved;
  final BuildContext outerContext;

  @override
  State<_UserProfileSheet> createState() => _UserProfileSheetState();
}

class _UserProfileSheetState extends State<_UserProfileSheet> {
  bool _busy = false;

  /// 「发消息」= `Channel.Anonymous / initiate`（与成员页同一条链路）。
  Future<void> _startChat() async {
    final t = widget.outerContext.t;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(widget.outerContext);
    setState(() => _busy = true);
    int channelId;
    try {
      channelId = await widget.ref
          .read(chatSessionControllerProvider.notifier)
          .startAnonymousConversation(widget.user.userId);
    } catch (e) {
      trackOnceFailure(
        UsageModule.chat,
        UsageAction.create,
        objectType: 'dm',
        reason: 'initiate_failed',
        error: e,
      );
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(t.chatStartChatFailed(userFacingError(e)))),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (channelId <= 0) {
      trackOnceFailure(
        UsageModule.chat,
        UsageAction.create,
        objectType: 'dm',
        reason: 'no_channel',
      );
      messenger.showSnackBar(
        SnackBar(content: Text(t.chatStartChatNoChannel(widget.user.displayName))),
      );
      return;
    }
    // analytics: starting a DM succeeded (object type only)
    trackOnce(UsageModule.chat, UsageAction.create, objectType: 'dm');
    navigator.pop();
    final outer = widget.outerContext;
    if (outer.mounted) outer.push(AppRoutes.chatOf(channelId));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final u = widget.user;
    final channel = widget.channel;
    // `channel_anonymous` ACL：没有权限就不给「发消息」开一对一的入口
    // （原版 `DrawerPresenter.java:67` / `ForwardConversationsFragment.java:121`）
    final canAnonymous = widget.ref.hasPrivilege(kAclChannelAnonymous);
    final isMe =
        u.userId == widget.ref.read(chatSessionControllerProvider).myUserId;
    final tz = u.timezoneUtc;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(u.displayName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(t.chatProfileAccount(u.username, u.userId)),
          if (u.email.isNotEmpty) Text(t.chatProfileEmail(u.email)),
          if (u.description.isNotEmpty) Text(t.chatProfileBio(u.description)),
          if (tz.isNotEmpty) Text(t.chatProfileTimezone(tz)),
          const SizedBox(height: 4),
          Text(
            u.publicKey.isEmpty
                ? t.chatProfileE2eeUnset
                : t.chatProfileE2eeSet,
          ),
          if (channel != null && channel.encrypted)
            Text(
              (channel.brokenUsers.contains(u.userId))
                  ? t.chatProfileInChannelBroken
                  : t.chatProfileInChannelOk,
            ),
          // 点自己 → 直接去编辑资料（原版 ProfileFragment 对自己也这样）
          if (isMe) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.outerContext.push(AppRoutes.profileEdit);
                },
                icon: const Icon(Icons.edit_outlined),
                label: Text(t.chatEditProfile),
              ),
            ),
          ] else ...[
            // 对别人 → 「发消息」开一对一（原版 `ProfileFragment` 的
            // `initiateAnonymous(userId)`；已存在就直接进去）。
            if (canAnonymous) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : _startChat,
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: Text(t.chatSendMessage),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
