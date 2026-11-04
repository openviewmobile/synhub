// 个人资料页（`SYNO.Personal.Profile / get`，**只读**）。
//
// ## 为什么做这一页
// 真机只读实测（`docs/device-readonly-verification-evidence-r16.md` §12）：
// ```console
// SYNO.Personal.Profile/get  path=entry.cgi  v1..3  （无参）
//   → {"id":"a83c54f9-4b31-424e-b82b-9653697f921f",
//      "email":"","emails":[],"nickName":"","isGuest":false}
// ```
// 本仓此前对 `SYNO.Personal.Profile` **零引用**（只有 `Personal.Profile.Photo /
// delete` 那条删头像的写路径），所以设置里的「我的账号」原来只有一行
// `user_id = N`，看不到昵称/邮箱/账号类型。本页补上。
//
// ## 三条硬规则
// 1. **只读**：本页只发 `get`，没有任何写动作（规程 §5.1）。
// 2. **空值如实**：真机实测这台 NAS 的 `nickName` / `email` 都是**空串**、
//    `emails` 是**空数组** —— 界面显示"未设置"，**绝不编造**昵称/邮箱。
// 3. **不绕能力表**：path/version 全部交给 `DsmWebApi.call` + `negotiate`
//    （规程 §1.4 / §5.3）；API 缺失或未登录时给空态，不发必然失败的死请求。
//
// ## 与「编辑资料」的关系
// 本页**不是**编辑页。编辑仍走既有的 `ProfileEditPage`
// （`SYNO.Chat.User / set`，写路径，属别的批次）。本页只读展示。
import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/app_states.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/user_facing_error.dart';
import '../../data/personal_api.dart';
import '../servers/session_controller.dart';
import 'settings_gaps_text.dart';

String _gap(String key, String zh) => settingsGap(key, zh);

/// 个人资料的 API 层；未连接时为 null（页面给"未登录"空态，而不是崩）。
final personalApiProvider = Provider<PersonalApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : PersonalApi(conn.api);
});

/// 当前账号资料。失败原样抛出，由页面渲染成错误态 + 重试。
final personalProfileProvider = FutureProvider.autoDispose<PersonalProfileDto>((
  ref,
) {
  final api = ref.watch(personalApiProvider);
  if (api == null) {
    throw StateError(
      _gap(SettingsGapTextKeys.profileNotLoggedIn, '未登录，无法读取个人资料'),
    );
  }
  return api.profile();
});

/// 「账号信息」页：昵称 / 邮箱 / 账号类型，**只读**。
class PersonalProfilePage extends ConsumerWidget {
  const PersonalProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(personalProfileProvider);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(_gap(SettingsGapTextKeys.profileTitle, '账号信息')),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppEmptyState(
          key: const Key('personal-profile-error'),
          icon: Icons.info_outline,
          title: _gap(SettingsGapTextKeys.profileLoadFailed, '资料加载失败'),
          message: e is StateError
              ? e.message
              : userFacingError(
                  e,
                  fallback: _gap(
                    SettingsGapTextKeys.profileLoadFailed,
                    '资料加载失败',
                  ),
                ),
          actionLabel: _gap(SettingsGapTextKeys.profileRetry, '重试'),
          onAction: () => ref.invalidate(personalProfileProvider),
        ),
        data: (p) => _ProfileBody(profile: p),
      ),
    );
  }
}

class _ProfileBody extends StatelessWidget {
  const _ProfileBody({required this.profile});

  final PersonalProfileDto profile;

  @override
  Widget build(BuildContext context) {
    final unset = _gap(SettingsGapTextKeys.profileUnset, '未设置');
    final emails = profile.validEmails;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: Gap.md),
      children: [
        // 昵称 —— 服务端为空串 ⇒ 如实显示"未设置"
        _ProfileRow(
          key: const Key('personal-profile-nickname'),
          icon: Icons.person_outline,
          label: _gap(SettingsGapTextKeys.profileNickname, '昵称'),
          value: profile.hasNickName ? profile.nickName : unset,
          muted: !profile.hasNickName,
        ),
        // 主邮箱 —— 服务端为空串 ⇒ 如实显示"未设置"
        _ProfileRow(
          key: const Key('personal-profile-email'),
          icon: Icons.alternate_email,
          label: _gap(SettingsGapTextKeys.profileEmail, '邮箱'),
          value: profile.hasEmail ? profile.email : unset,
          muted: !profile.hasEmail,
        ),
        // `emails` 是数组，可能为空 —— 空态**明说**，不静默省略
        if (emails.isNotEmpty)
          _ProfileRow(
            key: const Key('personal-profile-emails'),
            icon: Icons.mark_email_read_outlined,
            label: _gap(SettingsGapTextKeys.profileOtherEmails, '其他邮箱'),
            value: emails.join('\n'),
          )
        else
          _ProfileRow(
            key: const Key('personal-profile-emails-empty'),
            icon: Icons.mark_email_read_outlined,
            label: _gap(SettingsGapTextKeys.profileOtherEmails, '其他邮箱'),
            value: _gap(SettingsGapTextKeys.profileNoEmail, '未绑定邮箱'),
            muted: true,
          ),
        _ProfileRow(
          key: const Key('personal-profile-account-type'),
          icon: Icons.badge_outlined,
          label: _gap(SettingsGapTextKeys.profileAccountType, '账号类型'),
          value: profile.isGuest
              ? _gap(SettingsGapTextKeys.profileGuest, '访客账号')
              : _gap(SettingsGapTextKeys.profileMember, '普通账号'),
        ),
        if (profile.isGuest)
          Padding(
            key: const Key('personal-profile-guest-hint'),
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
            child: Text(
              _gap(
                SettingsGapTextKeys.profileGuestHint,
                '当前登录的是访客账号，可用功能以管理员授权为准。',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// 一行资料（图标 + 标签 + 值）；[muted] = 值是"未设置"这类占位说明。
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.muted = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: hud.dim),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelMedium),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: muted ? hud.dim : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
