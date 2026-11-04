// Phase 9：频道管理（原版 `ChannelSettingFragment` + `ChannelManageFragment`）。
//
// 原版把「收藏 / 退出频道 / 归档 / 关闭」放在频道设置页里（归档和关闭还要再进
// 一层 `ChannelManageFragment`）。我们压成一个底部弹窗，**可见性规则逐条对齐**
// （见 `channel_manage_rules.dart`）：
//
//   * 收藏          → `Channel/star|unstar` v1
//   * 退出频道      → `Channel.Named/disjoin` v1
//   * 归档频道      → `Channel/archive` v2（v2 支持 + 有消息 + ACL_CHANNEL_ARCHIVE）
//   * 关闭会话/频道 → `Channel/close` v2（带 conn_id，不可逆）
//
// 二次确认文案也照原版：退出 = `confirm_disjoin_channel`、归档/关闭 = `confirm_operation`，
// 匿名会话的关闭标题是「关闭会话」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/settings/acl.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/user_dto.dart';
import 'channel_type_label.dart';
import 'channel_manage_rules.dart';
import 'channel_name.dart';
import 'chat_session_controller.dart';
import '../../core/user_facing_error.dart';

/// 弹「频道管理」底部面板。闭包里的 [onRemoved] 在频道被归档/关闭/退出后调用
/// （调用方负责退回列表页）。
Future<void> showChannelManageSheet(
  BuildContext context,
  WidgetRef ref,
  ChannelDto channel, {
  VoidCallback? onRemoved,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ChannelManageSheet(channel: channel, onRemoved: onRemoved),
  );
}

/// 从用户表里找"我自己"（`chat_sync_state` 里的 `my_user_id`），找不到按非访客算。
UserDto? _me(WidgetRef ref) {
  final myId = ref.read(chatSessionControllerProvider).myUserId;
  final users = ref.read(usersProvider).value;
  if (users == null || myId <= 0) return null;
  for (final u in users) {
    if (u.userId == myId) return u;
  }
  return null;
}

/// 原版 `User.isGuest()`：`dsm` 里的访客
bool isGuestUser(UserDto? user) {
  if (user == null) return false;
  return user.type == 'guest' || user.username.startsWith('guest_');
}

class _ChannelManageSheet extends ConsumerStatefulWidget {
  const _ChannelManageSheet({required this.channel, this.onRemoved});

  final ChannelDto channel;
  final VoidCallback? onRemoved;

  @override
  ConsumerState<_ChannelManageSheet> createState() =>
      _ChannelManageSheetState();
}

class _ChannelManageSheetState extends ConsumerState<_ChannelManageSheet> {
  int _postCount = 0;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final n = await ref
        .read(chatSessionControllerProvider.notifier)
        .postCountOf(widget.channel.channelId);
    if (mounted) {
      setState(() {
        _postCount = n;
        _loading = false;
      });
    }
  }

  ChannelManageRules get _rules => channelManageRules(
    channel: widget.channel,
    isGuest: isGuestUser(_me(ref)),
    hasPrivilege: (acl) => ref.read(myAclProvider)[acl] ?? true,
    canArchiveApi: ref
        .read(chatSessionControllerProvider.notifier)
        .supportsChannelV2,
    canPromoteApi: ref
        .read(chatSessionControllerProvider.notifier)
        .supportsPromoteAnonymous,
    postCount: _postCount,
  );

  Future<void> _run(Future<void> Function() action, String failLabel) async {
    if (_busy) return;
    final t = context.t;
    // 先抓好，await 之后再用 context 会被 lint 拦
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      navigator.pop();
      widget.onRemoved?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(t.chatManageFailed(failLabel, userFacingError(e)))),
      );
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(title),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 「将会话转换为专用频道」（原版 `PromoteChannelFragment`：两个输入框
  /// 「名称 / 描述」→ `Channel.Anonymous / promote` v2）。
  Future<void> _promote() async {
    final t = context.t;
    final result = await showDialog<({String name, String purpose})>(
      context: context,
      builder: (_) => const _PromoteDialog(),
    );
    if (result == null || !mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (result.name.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(t.chatManageNameRequired)));
      return;
    }
    final controller = ref.read(chatSessionControllerProvider.notifier);
    setState(() => _busy = true);
    try {
      await controller.promoteChannel(
        widget.channel.channelId,
        name: result.name,
        purpose: result.purpose,
      );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text(t.chatManagePromoted(result.name))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(t.chatManagePromoteFailed(userFacingError(e)))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final rules = _rules;
    final name = _channelTitle(widget.channel, t);
    final controller = ref.read(chatSessionControllerProvider.notifier);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DesignRowTile(
            title: Text(t.chatManageTitle(name)),
            subtitle: _loading
                ? Text(t.chatManageLoading)
                : Text(
                    // ★ r344 D55：开头原来是 `'${widget.channel.type}'`（裸枚举）
                    '${channelTypeLabel(widget.channel.type, t)}'
                    '${widget.channel.encrypted ? t.chatManageEncryptedSuffix : ''}'
                    '${t.chatManageLocalPosts(_postCount)}',
                  ),
          ),
          const Divider(height: 1),
          DesignSwitchRow(
            secondary: const Icon(Icons.star_outline),
            title: Text(t.chatFavoriteChannel),
            value: widget.channel.isStar,
            onChanged: rules.favoriteEnabled && !_busy
                ? (v) => _run(
                    () => controller.setChannelStar(
                      widget.channel.channelId,
                      star: v,
                    ),
                    t.chatFavoriteAction,
                  )
                : null,
          ),
          if (rules.showLeave)
            DesignRowTile(
              leading: const Icon(Icons.logout),
              title: Text(t.chatLeaveChannel),
              enabled: !_busy,
              onTap: () async {
                if (await _confirm(
                  t.chatLeaveChannel,
                  t.chatLeaveConfirm(name),
                )) {
                  await _run(
                    () => controller.leaveChannel(widget.channel.channelId),
                    t.chatLeaveChannel,
                  );
                }
              },
            ),
          if (rules.showArchive)
            DesignRowTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(t.meArchives),
              enabled: !_busy,
              onTap: () async {
                if (await _confirm(t.meArchives, t.chatArchiveConfirm(name))) {
                  if (_busy || !context.mounted) return;
                  final navigator = Navigator.of(context);
                  final messenger = ScaffoldMessenger.of(context);
                  setState(() => _busy = true);
                  try {
                    final applied = await controller.archiveChannel(
                      widget.channel.channelId,
                    );
                    if (!mounted) return;
                    if (applied) {
                      navigator.pop();
                      widget.onRemoved?.call();
                    } else {
                      setState(() => _busy = false);
                      messenger.showSnackBar(
                        SnackBar(content: Text(t.chatArchiveUnsupported)),
                      );
                    }
                  } catch (e) {
                    if (!mounted) return;
                    setState(() => _busy = false);
                    messenger.showSnackBar(
                      SnackBar(content: Text(t.chatArchiveFailed(userFacingError(e)))),
                    );
                  }
                }
              },
            ),
          if (rules.showPromote)
            DesignRowTile(
              leading: const Icon(Icons.upgrade_outlined),
              title: Text(t.chatPromoteTitle),
              enabled: !_busy,
              onTap: _promote,
            ),
          if (rules.showClose)
            DesignRowTile(
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                rules.labelIn(t),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              enabled: !_busy,
              onTap: () async {
                if (await _confirm(
                  rules.labelIn(t),
                  t.chatCloseConfirm(name),
                )) {
                  await _run(
                    () => controller.closeChannel(widget.channel.channelId),
                    rules.labelIn(t),
                  );
                }
              },
            ),
          if (!rules.hasAny)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(t.chatManageNoActions),
            ),
        ],
      ),
    );
  }
}

String _channelTitle(ChannelDto c, [AppText? text]) {
  final t = text ?? currentText();
  if (c.name.isNotEmpty) return c.name;
  return switch (c.type) {
    'anonymous' => t.chatConvTitle(c.channelId),
    'public' => t.chatPublicChannelTitle(c.channelId),
    'private' => t.chatPrivateChannelTitle(c.channelId),
    _ => t.chatChannelHash(c.channelId),
  };
}

/// 「将会话转换为专用频道」的输入框（控制器跟着路由生命周期走）
class _PromoteDialog extends StatefulWidget {
  const _PromoteDialog();

  @override
  State<_PromoteDialog> createState() => _PromoteDialogState();
}

class _PromoteDialogState extends State<_PromoteDialog> {
  final _name = TextEditingController();
  final _purpose = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _purpose.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // 原版 `PromoteChannelFragment.afterInputChanged`：空 → 必填；
    // 带空格/特殊字符 → error_invalid_name。合法才让点「转换」。
    final name = _name.text.trim();
    final error = name.isEmpty ? null : channelNameError(name);
    return AlertDialog(
      title: Text(t.chatPromoteTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: t.chatChannelName,
              errorText: error,
              helperText: t.chatChannelNameHelper,
            ),
          ),
          TextField(
            controller: _purpose,
            decoration: InputDecoration(labelText: t.calDescriptionOptional),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          onPressed: name.isEmpty || error != null
              ? null
              : () => Navigator.of(
                  context,
                ).pop((name: name, purpose: _purpose.text.trim())),
          child: Text(t.chatPromoteAction),
        ),
      ],
    );
  }
}
