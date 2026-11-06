// 频道成员页（对齐原版 `MemberFragment` + `MembersAdapter`）：
// 成员列表（头像首字母 + 昵称 + 账号名）、按名字过滤、E2EE 频道标 ⚠
// （点一下 → 确认 → `Channel/rescue` 重发频道密钥）、编辑模式批量踢人、
// 邀请新成员（加密频道逐个封一份频道密钥）。
//
// 与会话内菜单的联动：频道里有人 broken 时，聊天页菜单的「成员」会换成 ⚠ 图标
// （对应原版 `ChannelFragment` 的 `icon_member_warning`）。
import 'package:flutter/material.dart';
import '../../design/kit/design_kit.dart';
import '../../core/ui/adaptive_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/settings/acl.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/user_dto.dart';
import '../settings/e2ee_controller.dart';
import 'channel_create_controller.dart';
import 'chat_session_controller.dart';
import 'user_profile_sheet.dart';
import 'no_passphrase_dialog.dart';

class ChannelMembersPage extends ConsumerStatefulWidget {
  const ChannelMembersPage({super.key, required this.channelId});

  final int channelId;

  @override
  ConsumerState<ChannelMembersPage> createState() => _ChannelMembersPageState();
}

class _ChannelMembersPageState extends ConsumerState<ChannelMembersPage> {
  final _filter = TextEditingController();
  bool _editing = false;
  final Set<int> _selected = <int>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 进页面拉一次服务端成员表（`Channel/list` 不带成员，更不带 broken 列表）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(chatSessionControllerProvider.notifier)
          .syncChannelMembers(widget.channelId);
    });
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _rescue(UserDto user) async {
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.chatRescueKeyTitle),
        content: Text(
          t.chatRescueKeyConfirm(widget.channelId, user.displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.e2eeFix),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final done = await ref
        .read(e2eeControllerProvider.notifier)
        .rescueChannel(channelId: widget.channelId, userId: user.userId);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(done ? t.chatRescueKeyDone : t.chatRescueKeyFailed);
  }

  Future<void> _kick() async {
    if (_selected.isEmpty) return;
    final t = context.t;
    final byId = {for (final u in _usersById) u.userId: u};
    final names = _selected
        .map((id) => byId[id]?.displayName ?? '#$id')
        .join(t.chatRowNameSeparator);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.chatKickTitle),
        content: Text(t.chatKickConfirm(names)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.chatKickAction),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final done = await ref
        .read(chatSessionControllerProvider.notifier)
        .kickMembers(widget.channelId, _selected.toList());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.clear();
      _editing = false;
    });
    _toast(done ? t.chatKickDone : t.chatKickFailed);
  }

  Future<void> _invite(ChannelDto channel) async {
    final t = context.t;
    final picked = await Navigator.of(context).push<List<int>>(
      MaterialPageRoute(
        builder: (_) => _InviteMembersPage(
          channelId: widget.channelId,
          excludeIds: channel.members.toSet()
            ..add(
              ref.read(chatSessionControllerProvider.select((s) => s.myUserId)),
            ),
          encrypted: channel.encrypted,
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    final ctrl = ref.read(chatSessionControllerProvider.notifier);

    // 加密频道：先把"没设口令"的人挑出来（原版 `showNoPublicKeyUsers` →
    // `dialog_no_passphrase`），用户确认后把他们移出名单，剩下的照常邀请；
    // 勾了「通知他们」就调 `User / notify_encrypt` 提醒这些人。
    var toInvite = picked;
    if (channel.encrypted) {
      final noKey = await ref
          .read(channelCreateControllerProvider)
          .usersWithoutPublicKey(picked);
      if (noKey.isNotEmpty) {
        if (!mounted) return;
        final notify = await showNoPassphraseDialog(
          context,
          count: noKey.length,
        );
        if (notify == null) return; // 取消：整个邀请不动
        final exclude = noKey.map((u) => u.userId).toSet();
        toInvite = picked.where((id) => !exclude.contains(id)).toList();
        if (notify) await ctrl.notifyEncrypt(exclude.toList());
        if (toInvite.isEmpty) {
          if (mounted) _toast(t.chatInviteSkippedNoPassphrase);
          return;
        }
      }
    }

    setState(() => _busy = true);
    final done = await ctrl.inviteMembers(widget.channelId, toInvite);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(done ? t.chatInviteDone : t.chatInviteFailed);
  }

  List<UserDto> _usersById = const [];

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final channel = ref.watch(channelProvider(widget.channelId));
    final users = ref.watch(usersProvider).value ?? const <UserDto>[];
    final myId = ref.watch(
      chatSessionControllerProvider.select((s) => s.myUserId),
    );
    _usersById = users;

    final byId = {for (final u in users) u.userId: u};
    // 成员表以频道行里的 `members` 为准（`syncChannelMembers` 写回来的）
    final memberIds = channel?.members ?? const <int>[];
    var members = <UserDto>[
      for (final id in memberIds)
        byId[id] ??
            UserDto(
              userId: id,
              username: t.chatUserFallback(id),
              type: 'human',
            ),
    ];
    // 自己排最前，其余按显示名（原版是 DB 顺序，这里给个稳定顺序）
    members = members.toList()
      ..sort((a, b) {
        if (a.userId == myId) return -1;
        if (b.userId == myId) return 1;
        return a.displayName.compareTo(b.displayName);
      });

    final query = _filter.text.trim().toLowerCase();
    final shown = query.isEmpty
        ? members
        : members
              .where(
                (u) =>
                    u.displayName.toLowerCase().contains(query) ||
                    u.username.toLowerCase().contains(query),
              )
              .toList();

    final broken = (channel?.brokenUsers ?? const <int>[]).toSet();
    // watch（不是 read）：ACL 是登录后异步拉回来的，晚到也要让入口刷新
    final acl = ref.watch(myAclProvider);
    final canInvite = acl[kAclChannelInvite] ?? true; // 查不到即允许
    final canKick = acl[kAclChannelKick] ?? true;
    // 原版：匿名/synobot/chatbot 不给邀请；#1（我的空间）也不给；私有频道要 ACL
    final inviteAllowed =
        channel != null &&
        canInvite &&
        widget.channelId != 1 &&
        (channel.type == 'private' || channel.type == 'public') &&
        !channel.isChatBotType;
    final kickAllowed = channel != null && canKick && channel.type == 'private';

    return Scaffold(
      appBar: AppBar(
        title: Text(t.chatMembersTitle(shown.length)),
        actions: adaptiveActions([
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_editing)
            TextButton(
              onPressed: _selected.isEmpty ? null : _kick,
              child: Text(t.chatKickAction),
            )
          else ...[
            if (inviteAllowed)
              IconButton(
                tooltip: t.chatInviteTitle,
                icon: const Icon(Icons.person_add_alt),
                onPressed: () => _invite(channel),
              ),
            if (kickAllowed)
              IconButton(
                tooltip: t.calEditLabel,
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => setState(() => _editing = true),
              ),
          ],
          if (_editing)
            IconButton(
              tooltip: t.calEnvDone,
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _editing = false;
                _selected.clear();
              }),
            ),
        ]),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _filter,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: t.chatSearchMembers,
                border: const OutlineInputBorder(),
                suffixIcon: _filter.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(_filter.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (channel != null && broken.isNotEmpty)
            Container(
              width: double.infinity,
              color: theme.colorScheme.errorContainer,
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  const Icon(Icons.report_gmailerrorred_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.chatBrokenMembersBanner(broken.length),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: shown.isEmpty
                ? Center(child: Text(t.chatNoMembers))
                : ListView.separated(
                    itemCount: shown.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final u = shown[i];
                      final isMe = u.userId == myId;
                      final isBroken = broken.contains(u.userId);
                      final selectable =
                          _editing && !isMe && u.humanType != 'guest';
                      return DesignRowTile(
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.secondaryContainer,
                          child: Text(
                            (u.displayName.isEmpty ? u.username : u.displayName)
                                .characters
                                .first
                                .toUpperCase(),
                          ),
                        ),
                        title: Text(
                          isMe ? t.chatMemberMe(u.displayName) : u.displayName,
                        ),
                        subtitle: u.username == u.displayName
                            ? null
                            : Text(u.username),
                        // 原版 `MembersAdapter.descView`：加密频道里有公钥的人
                        // 会显示"已设置口令"
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (channel != null &&
                                channel.encrypted &&
                                u.publicKey.isEmpty &&
                                !isBroken)
                              Tooltip(
                                message: t.chatMemberNoE2eeKey,
                                child: const Icon(
                                  Icons.no_encryption_gmailerrorred,
                                  size: 18,
                                ),
                              ),
                            if (isBroken)
                              Tooltip(
                                message: t.chatMemberBrokenHint,
                                child: const Icon(
                                  Icons.report_gmailerrorred_outlined,
                                  color: Colors.orange,
                                ),
                              ),
                            if (selectable)
                              Checkbox(
                                value: _selected.contains(u.userId),
                                onChanged: (on) => setState(() {
                                  if (on == true) {
                                    _selected.add(u.userId);
                                  } else {
                                    _selected.remove(u.userId);
                                  }
                                }),
                              ),
                          ],
                        ),
                        onTap: _editing || isMe
                            ? null
                            : () => isBroken
                                  ? _rescue(u)
                                  : _showProfile(u, channel),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 成员资料弹窗 —— **与聊天正文里的 @提及共用同一个实现**
  /// （`user_profile_sheet.dart`，见 §2.0.8 ④：一个东西一套实现）。
  void _showProfile(UserDto u, ChannelDto? channel) {
    showUserProfileSheet(context, ref, user: u, channel: channel);
  }
}

/// 邀请成员：勾选不在频道里的用户（加密频道只列有公钥的人）。
class _InviteMembersPage extends ConsumerStatefulWidget {
  const _InviteMembersPage({
    required this.channelId,
    required this.excludeIds,
    required this.encrypted,
  });

  final int channelId;
  final Set<int> excludeIds;
  final bool encrypted;

  @override
  ConsumerState<_InviteMembersPage> createState() => _InviteMembersPageState();
}

class _InviteMembersPageState extends ConsumerState<_InviteMembersPage> {
  final Set<int> _picked = <int>{};
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final users = ref.watch(usersProvider).value ?? const <UserDto>[];
    final myId = ref.watch(
      chatSessionControllerProvider.select((s) => s.myUserId),
    );
    var candidates = users
        .where(
          (u) =>
              u.userId != myId &&
              !u.isDeleted &&
              u.type == 'human' &&
              !widget.excludeIds.contains(u.userId),
        )
        .toList();
    // 原版不在这里把人藏起来：没配口令的人照样能选，点了「邀请」之后再弹
    // `dialog_no_passphrase`（`showNoPublicKeyUsers`）确认"移出并继续 / 顺便通知他"。
    // 所以这里只排序，另外在行尾挂 ⚠ 提示（见下面的 `secondary`）。
    candidates.sort((a, b) => a.displayName.compareTo(b.displayName));
    final query = _filter.text.trim().toLowerCase();
    final shown = query.isEmpty
        ? candidates
        : candidates
              .where(
                (u) =>
                    u.displayName.toLowerCase().contains(query) ||
                    u.username.toLowerCase().contains(query),
              )
              .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(t.chatInviteTitle),
        actions: [
          TextButton(
            onPressed: _picked.isEmpty
                ? null
                : () => Navigator.of(context).pop(_picked.toList()),
            child: Text(t.chatInviteCount(_picked.length)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _filter,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: t.chatSearchUsers,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (widget.encrypted)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                t.chatInviteNoPassphraseHint,
                style: theme.textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: shown.isEmpty
                ? Center(child: Text(t.chatNoInvitableUsers))
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final u = shown[i];
                      return DesignCheckRow(
                        value: _picked.contains(u.userId),
                        onChanged: (on) => setState(() {
                          if (on == true) {
                            _picked.add(u.userId);
                          } else {
                            _picked.remove(u.userId);
                          }
                        }),
                        title: Text(u.displayName),
                        subtitle: u.username == u.displayName
                            ? null
                            : Text(u.username),
                        secondary: u.publicKey.isEmpty
                            ? Tooltip(
                                message: t.chatUserNoE2eeKey,
                                child: const Icon(Icons.warning_amber_outlined),
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
