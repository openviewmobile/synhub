// E2EE 设置页（Phase 7）：看状态、设置口令、解锁、换口令、清身份、修复频道。
//
// 对应原 App 的 `EncryptionSettingPresenter` / 设置里的「加密」分组。
import 'package:flutter/material.dart';

import '../../design/kit/design_kit.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/user_dto.dart';
import '../../data/e2ee/e2ee_service.dart';
import '../../core/settings/server_settings.dart';
import '../chat/chat_session_controller.dart';
import 'e2ee_controller.dart';

/// 把「我的公钥」**完整**复制进剪贴板。
///
/// ★ 为什么要这条：`_StatusCard` 里公钥是**单行省略号**显示（`maxLines: 1`）——
/// 它是全应用**唯一**展示公钥的地方，没有出口就等于"用户永远读不到自己的公钥"
/// （§2.0.18「截断即等于没读」）。复制的是 `state.publicKey` 原值，不是显示串。
void copyE2eePublicKey(BuildContext context, String key) {
  final trimmed = key.trim();
  if (trimmed.isEmpty) return;
  Clipboard.setData(ClipboardData(text: trimmed));
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(context.t.e2eePublicKeyCopied)));
}

class E2eePage extends ConsumerWidget {
  const E2eePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e2ee = ref.watch(e2eeControllerProvider);
    final channels = ref.watch(channelsProvider).value ?? const <ChannelDto>[];
    final byId = {for (final c in channels) c.channelId: c};
    final users = ref.watch(usersProvider).value ?? const <UserDto>[];
    final byUser = {for (final u in users) u.userId: u};
    // 服务端关了加密（`SYNO.Chat.Admin.Setting.allow_encryption`）时，
    // 原版 `fetchAdminSetting` 会直接抛 `HttpsRequiredException`；我们这里只提示
    // —— 已经建好的加密频道还是能读（密钥在本地）。
    final allowEncryption = ref.watch(serverSettingsProvider).allowEncryption;
    final t = context.t;

    return Scaffold(
      appBar: AppBar(title: Text(t.setE2ee)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (!allowEncryption)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.report_gmailerrorred_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.e2eeDisabledBanner,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          _StatusCard(state: e2ee),
          const Divider(),
          if (!e2ee.configured)
            DesignRowTile(
              leading: const Icon(Icons.key_outlined),
              title: Text(t.e2eeSetupPasscode),
              subtitle: Text(t.e2eeSetupPasscodeHint),
              onTap: () => _setupDialog(context, ref),
            )
          else ...[
            if (!e2ee.unlocked)
              DesignRowTile(
                leading: const Icon(Icons.lock_open),
                title: Text(t.e2eeUnlock),
                subtitle: Text(t.e2eeUnlockHint),
                onTap: () => _unlockDialog(context, ref),
              )
            else
              DesignRowTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(t.e2eeLock),
                subtitle: Text(t.e2eeLockHint),
                onTap: () => ref.read(e2eeControllerProvider.notifier).lock(),
              ),
            DesignRowTile(
              leading: const Icon(Icons.password),
              title: Text(t.e2eeChangePasscode),
              onTap: () => _changePasscodeDialog(context, ref),
            ),
            DesignRowTile(
              leading: const Icon(Icons.sync),
              title: Text(t.e2eeSyncMembers),
              subtitle: Text(t.e2eeSyncMembersHint),
              onTap: () async {
                final ctrl = ref.read(chatSessionControllerProvider.notifier);
                final enc = byId.values.where((c) => c.encrypted).toList();
                var n = 0;
                for (final c in enc) {
                  if (await ctrl.syncChannelMembers(c.channelId)) n++;
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(t.e2eeSyncedChannels(n))),
                  );
                }
              },
            ),
            DesignRowTile(
              leading: const Icon(Icons.autorenew),
              title: Text(t.e2eeRenewKey),
              subtitle: Text(t.e2eeRenewKeyHint),
              onTap: () => _renewKeyDialog(context, ref),
            ),
            DesignRowTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: Text(t.e2eeReuploadKeys),
              subtitle: Text(t.e2eeReuploadKeysHint),
              onTap: () async {
                final ok = await ref
                    .read(e2eeControllerProvider.notifier)
                    .reuploadMyChannelKeys();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(ok ? t.e2eeUploaded : t.e2eeUploadFailed),
                    ),
                  );
                }
              },
            ),
            DesignRowTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(t.e2eeResetIdentity),
              subtitle: Text(t.e2eeResetIdentityHint),
              onTap: () => _resetDialog(context, ref),
            ),
          ],
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              t.e2eeChannelsSection,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          if (byId.isEmpty)
            DesignRowTile(title: Text(t.e2eeNoChannels))
          else
            ...byId.values.where((c) => c.encrypted).map((c) {
              final keyState = ref
                  .read(e2eeControllerProvider.notifier)
                  .keyStateOf(c);
              // 服务端算出来的"这个频道里谁解不开"（实时事件维护）
              final broken = c.brokenUsers;
              final subtitle = StringBuffer(_keyStateLabel(t, keyState));
              if (broken.isNotEmpty) {
                final names = broken
                    .map((id) => byUser[id]?.displayName ?? '#$id')
                    .join(t.listSeparator);
                subtitle.write('\n${t.e2eeBrokenUsers(names)}');
              }
              return DesignRowTile(
                isThreeLine: broken.isNotEmpty,
                leading: Icon(
                  broken.isNotEmpty
                      ? Icons.report_gmailerrorred_outlined
                      : (keyState == ChannelKeyState.ready
                            ? Icons.lock
                            : Icons.lock_open),
                ),
                title: Text(
                  c.name.isEmpty
                      ? t.e2eeConversationNumbered(c.channelId)
                      : c.name,
                ),
                subtitle: Text(subtitle.toString()),
                trailing: (keyState == ChannelKeyState.ready && broken.isEmpty)
                    ? null
                    : TextButton(
                        onPressed: () => _rescueDialog(context, ref, c),
                        child: Text(t.e2eeFix),
                      ),
              );
            }),
          if (byId.values.every((c) => !c.encrypted))
            DesignRowTile(
              title: Text(t.e2eeNoneEncrypted),
              subtitle: Text(t.e2eeNoneEncryptedHint),
            ),
        ],
      ),
    );
  }

  static String _keyStateLabel(AppText t, ChannelKeyState s) => switch (s) {
    ChannelKeyState.ready => t.e2eeKeyStateReady,
    ChannelKeyState.locked => t.e2eeKeyStateLocked,
    ChannelKeyState.missing => t.e2eeKeyStateMissing,
    ChannelKeyState.notEncrypted => t.e2eeKeyStateNotEncrypted,
  };

  Future<void> _setupDialog(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final passcode = await _askPasscode(
      context,
      title: t.e2eeSetupPasscode,
      confirm: true,
    );
    if (passcode == null) return;
    final ok = await ref.read(e2eeControllerProvider.notifier).setup(passcode);
    if (context.mounted) {
      final err = ref.read(e2eeControllerProvider).error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? t.e2eeEnabled : t.actionSetFailed(err ?? ''))),
      );
    }
  }

  Future<void> _unlockDialog(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final passcode = await _askPasscode(
      context,
      title: t.e2eeEnterPasscode,
      confirm: false,
    );
    if (passcode == null) return;
    final notifier = ref.read(e2eeControllerProvider.notifier);
    final ok = await notifier.unlock(passcode);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? t.e2eeUnlocked
                : ref.read(e2eeControllerProvider).error ?? t.e2eeUnlockFailed,
          ),
        ),
      );
    }
  }

  Future<void> _changePasscodeDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final t = context.t;
    final oldPass = await _askPasscode(
      context,
      title: t.e2eeCurrentPasscode,
      confirm: false,
    );
    if (oldPass == null || !context.mounted) return;
    final newPass = await _askPasscode(
      context,
      title: t.e2eeNewPasscode,
      confirm: true,
    );
    if (newPass == null) return;
    final ok = await ref
        .read(e2eeControllerProvider.notifier)
        .changePasscode(oldPasscode: oldPass, newPasscode: newPass);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? t.e2eePasscodeUpdated : t.e2eeChangeFailedOld),
        ),
      );
    }
  }

  /// 「更换密钥对」（原版 `title_renew_key` / `btn_renew_key` /
  /// `desc_renew_key`：换完才能继续用之前的加密频道）。
  Future<void> _renewKeyDialog(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.e2eeRenewKeyConfirmTitle),
        content: Text(t.e2eeRenewKeyConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.actionContinue),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    final pass = await _askPasscode(
      context,
      title: t.e2eeCurrentPasscode,
      confirm: false,
    );
    if (pass == null || !context.mounted) return;
    final ok = await ref
        .read(e2eeControllerProvider.notifier)
        .renewKeyPair(passcode: pass);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? t.e2eeRenewedOk : t.e2eeRenewFailed)),
      );
    }
  }

  Future<void> _resetDialog(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.e2eeResetConfirmTitle),
        content: Text(t.e2eeResetConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.e2eeResetAction),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await ref.read(e2eeControllerProvider.notifier).reset();
  }

  Future<void> _rescueDialog(
    BuildContext context,
    WidgetRef ref,
    ChannelDto channel,
  ) async {
    final t = context.t;
    final users = ref.read(usersProvider).value ?? const [];
    // 优先列出**服务端标了 broken**的人（那才是真的要修的），其余的也留着 ——
    // 原版成员列表里点 ⚠ 的人就走这条路
    final candidates =
        users.where((u) => u.publicKey.isNotEmpty).toList(growable: false)
          ..sort((a, b) {
            final ab = channel.brokenUsers.contains(a.userId) ? 0 : 1;
            final bb = channel.brokenUsers.contains(b.userId) ? 0 : 1;
            return ab.compareTo(bb);
          });
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.e2eeNoPublicKeys)));
      return;
    }
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.e2eeRescueWho(channel.channelId)),
        children: [
          for (final u in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, u.userId),
              child: Text(
                '${u.nickname.isNotEmpty ? u.nickname : u.username} (#${u.userId})'
                '${channel.brokenUsers.contains(u.userId) ? t.e2eeRescueBrokenTag : ""}',
              ),
            ),
        ],
      ),
    );
    if (picked == null) return;
    final ok = await ref
        .read(e2eeControllerProvider.notifier)
        .rescueChannel(channelId: channel.channelId, userId: picked);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? t.e2eeKeysResent : t.e2eeRescueFailed)),
      );
    }
  }

  /// 一句口令输入的通用弹窗。
  ///
  /// [confirm] 为真时要求输两遍并比对（设置/改口令）。
  Future<String?> _askPasscode(
    BuildContext context, {
    required String title,
    required bool confirm,
  }) async {
    final t = context.t;
    final first = TextEditingController();
    final second = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: first,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(labelText: t.e2eePasscode),
                validator: (v) =>
                    (v == null || v.isEmpty) ? t.e2eePasscodeRequired : null,
              ),
              if (confirm) ...[
                const SizedBox(height: 8),
                TextFormField(
                  controller: second,
                  obscureText: true,
                  decoration: InputDecoration(labelText: t.passcodeRepeat),
                  validator: (v) => v == first.text ? null : t.passcodeMismatch,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(ctx, first.text);
            },
            child: Text(t.actionOk),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});

  final E2eeState state;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (icon, text) = switch ((state.configured, state.unlocked)) {
      (false, _) => (Icons.no_encryption_gmailerrorred, t.e2eeStatusOff),
      (true, false) => (Icons.lock, t.e2eeStatusLocked),
      (true, true) => (Icons.verified_user, t.e2eeStatusUnlocked),
    };
    return DesignRowTile(
      leading: Icon(icon, size: 36),
      title: Text(text),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.publicKey.isNotEmpty)
            // ★ 单行省略号是**显示**取舍；公钥必须能完整取走 ⇒ 挂复制入口
            //（复制的是 `state.publicKey` 原值，见 `copyE2eePublicKey`）。
            InkWell(
              key: const Key('e2ee-copy-public-key'),
              onTap: () => copyE2eePublicKey(context, state.publicKey),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      t.e2eePublicKey(state.publicKey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.copy_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          if (state.brokenChannels.isNotEmpty)
            Text(
              t.e2eeBrokenChannelCount(state.brokenChannels.length),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (state.busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
