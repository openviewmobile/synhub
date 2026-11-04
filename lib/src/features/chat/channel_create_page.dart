// 新建频道页（对齐原版 `ChannelCreateFragment`）：
// 名称 / 用途 / 公开或私有 / **端到端加密开关** / 勾选成员。
//
// 加密开关是**一次性**的：原版也提示"创建后无法切换"。成员里没有密钥的人会被
// 拦在提交前（后端再兜一层），免得建出一个谁也解不开的频道。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../core/settings/acl.dart';
import '../../core/settings/server_settings.dart';
import '../../data/dto/user_dto.dart';
import 'channel_create_controller.dart';
import 'channel_name.dart';
import 'chat_session_controller.dart';
import 'no_passphrase_dialog.dart';
import '../../core/user_facing_error.dart';

class ChannelCreatePage extends ConsumerStatefulWidget {
  const ChannelCreatePage({super.key});

  @override
  ConsumerState<ChannelCreatePage> createState() => _ChannelCreatePageState();
}

class _ChannelCreatePageState extends ConsumerState<ChannelCreatePage> {
  final _name = TextEditingController();
  final _purpose = TextEditingController();
  String _type = 'private';
  bool _encrypted = false;
  final Set<int> _picked = <int>{};
  List<UserDto> _users = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  @override
  void dispose() {
    _name.dispose();
    _purpose.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    final users = await ref
        .read(channelCreateControllerProvider)
        .invitableUsers();
    if (mounted) setState(() => _users = users);
  }

  Future<void> _submit() async {
    final t = context.t;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final create = ref.read(channelCreateControllerProvider);
      var memberIds = _picked.toList();

      // 加密频道：先把"没设口令"的人挑出来（原版 `showNoPublicKeyUsers` →
      // `dialog_no_passphrase`）。确认后把他们移出名单，剩下的照常建；
      // 勾了「通知他们」就调 `User / notify_encrypt`。
      if (_encrypted && memberIds.isNotEmpty) {
        final noKey = await create.usersWithoutPublicKey(memberIds);
        if (noKey.isNotEmpty) {
          if (!mounted) return;
          final notify = await showNoPassphraseDialog(
            context,
            count: noKey.length,
          );
          if (notify == null) {
            setState(() => _busy = false);
            return; // 取消：不建频道
          }
          final exclude = noKey.map((u) => u.userId).toSet();
          memberIds = memberIds.where((id) => !exclude.contains(id)).toList();
          if (notify) {
            await ref
                .read(chatSessionControllerProvider.notifier)
                .notifyEncrypt(exclude.toList());
          }
        }
      }

      final created = await create.create(
        name: _name.text,
        purpose: _purpose.text.trim(),
        type: _type,
        encrypted: _encrypted,
        memberIds: memberIds,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            created.encrypted
                ? t.chatCreatedEncrypted(created.channelId)
                : t.chatCreated(created.channelId),
          ),
        ),
      );
      context.go(AppRoutes.chatOf(created.channelId));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = userFacingError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final allowEncryption = ref.watch(serverSettingsProvider).allowEncryption;
    // `channel_encryption` ACL：原版 `NamedCreateFragment.java:300`
    // `mPrivateSwitch.setVisibility(hasPrivilege ? VISIBLE : GONE)` —— 无权限时
    // 整个加密开关**不出现**（不是灰掉），避免用户点了吃 402/160
    final canEncrypt = ref.hasPrivilege(kAclChannelEncryption);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.chatNewChannel),
        actions: [
          TextButton(
            onPressed: _busy || channelNameError(_name.text.trim()) != null
                ? null
                : _submit,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t.photoCreate),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: t.chatChannelName,
                hintText: t.chatChannelNameHint,
                border: const OutlineInputBorder(),
                // 原版 `NamedCreateFragment.afterInputChanged` 的同一条判定
                errorText: _name.text.trim().isEmpty
                    ? null
                    : channelNameError(_name.text.trim()),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _purpose,
              decoration: InputDecoration(
                labelText: t.chatChannelPurposeOptional,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const Divider(),
          RadioGroup<String>(
            groupValue: _type,
            onChanged: (v) => setState(() => _type = v ?? 'private'),
            child: Column(
              children: [
                RadioListTile<String>(
                  value: 'private',
                  title: Text(t.chatChannelPrivate),
                  subtitle: Text(t.chatChannelPrivateHint),
                ),
                RadioListTile<String>(
                  value: 'public',
                  title: Text(t.chatChannelPublic),
                  subtitle: Text(t.chatChannelPublicHint),
                ),
              ],
            ),
          ),
          const Divider(),
          // ignore: prefer_const_constructors
          if (canEncrypt)
            DesignSwitchRow(
              // 服务端不允许加密时（`SYNO.Chat.Admin.Setting.allow_encryption`
              // = false）开关直接禁用 —— 原版同样会拦住
              value: _encrypted && allowEncryption,
              onChanged: (!allowEncryption || _busy)
                  ? null
                  : (v) => setState(() => _encrypted = v),
              secondary: const Icon(Icons.lock_outline),
              title: Text(t.meE2ee),
              subtitle: Text(
                !allowEncryption
                    ? t.chatCreateE2eeDisabled
                    : _encrypted
                    ? t.chatCreateE2eeHint
                    : t.chatCreateE2eeIrreversible,
              ),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              t.chatSectionMembers,
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (_users.isEmpty)
            DesignRowTile(dense: true, title: Text(t.chatCreateNoInvitableUsers)),
          for (final u in _users)
            DesignCheckRow(
              value: _picked.contains(u.userId),
              onChanged: _busy
                  ? null
                  : (on) => setState(() {
                      if (on == true) {
                        _picked.add(u.userId);
                      } else {
                        _picked.remove(u.userId);
                      }
                    }),
              title: Text(u.displayName),
              // 昵称和账号名一样时别重复显示两行一样的字
              subtitle: u.username == u.displayName ? null : Text(u.username),
              secondary: _encrypted && u.publicKey.isEmpty
                  ? Tooltip(
                      message: t.chatUserNoE2eeKey,
                      child: const Icon(Icons.warning_amber_outlined),
                    )
                  : null,
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
