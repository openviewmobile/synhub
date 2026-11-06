// Drive 高级共享（AdvanceSharing）页（C1）：**管理与查看**这个条目的公开链接。
//
// 协议事实（原文见 [DriveApi] 与文档实施记录）：
//   * `AdvanceSharing/get` v1 `{path}` → `{sharing_link,url,role,
//     protect_password,due_date}`（`drive/synodrive_common.js:294847` /
//     `:294700`）；没开过时服务端回 **1036**（同处 `.catch`）→ 这里当
//     "还没有链接"，不是错误；
//   * `AdvanceSharing/update` v1 `{path,sharing_link,role,due_date}`
//     （`_onSaveLink`，`synodrive_common.js:296719`）；
//   * `AdvanceSharing/delete` v1 `{path,sharing_link}`（`_onRemoveLink`，`:_295900`）。
//
// 【取舍】按 `docs/workspace-expansion-evaluation.md` §641 的用户决定
// （"公开链接安全：**默认不给新建入口**，只做管理/查看"），本页**不提供
// "新建公开链接"按钮**；`AdvanceSharing/create` 只在协议层实现 + 用例覆盖
// （证据齐），UI 不暴露。既有的个人分享入口（`drive_share_page.dart` 的
// 成员邀请）保持不变，二者关系：**成员共享 = Sharing**，
// **匿名公开链接 = AdvanceSharing**，同一文件各管一条线，互相独立。
// `verify`（校验密码）**无参数原文** → 未实现（待取证）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_share_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../../dsm/webapi.dart' show DsmApiException;
import '../files/drive_providers.dart';
import '../files/file_row.dart' show formatFileTime;
import 'drive_c1_text.dart';
import 'drive_g4_text.dart';
import '../../core/theme/app_theme.dart';

/// AdvanceSharing 里"没开过公开链接"的错误码（官方前端按 1036 处理）
const int kAdvanceSharingNotFoundCode = 1036;

class DriveAdvanceSharingPage extends ConsumerWidget {
  const DriveAdvanceSharingPage({
    super.key,
    required this.path,
    required this.entryName,
  });

  /// `id:<file_id>` 或目录路径
  final String path;
  final String entryName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveAdvanceSharingProvider(path));
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-advance-sharing-page'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: t.calBack,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            driveC1(DriveC1TextKeys.advanceSharing, '高级共享'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            entryName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.labelSmall?.copyWith(color: hud.dim),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: t.photoRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () =>
                          ref.invalidate(driveAdvanceSharingProvider(path)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Text(
                  driveC1(
                    DriveC1TextKeys.advanceSharingIntro,
                    '匿名公开链接：拿到链接的人无需账号即可访问；成员共享请用「分享」。',
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) {
                    // 1036 = 这个条目还没有高级共享链接（官方同款语义）
                    if (e is DsmApiException &&
                        e.code == kAdvanceSharingNotFoundCode) {
                      return AppEmptyState(
                        icon: Icons.link_off,
                        title: driveC1(
                          DriveC1TextKeys.advanceSharingEmpty,
                          '还没有公开链接',
                        ),
                        // ★ DA196：这行原来也传 `advanceSharingIntro`，而页面顶部
                        //   已经用同一个 key 讲了一遍 ⇒ 真机上同一句话**上下各一次**。
                        //   空态只留标题，说明交给顶部的 intro。
                        message: null,
                      );
                    }
                    return AppEmptyState(
                      icon: Icons.error_outline,
                      title: t.driveNoPublicLink,
                      message: describeFileError(e),
                      actionLabel: t.photoRetry,
                      onAction: () =>
                          ref.invalidate(driveAdvanceSharingProvider(path)),
                    );
                  },
                  data: (info) => _Body(path: path, info: info),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.path, required this.info});

  final String path;
  final DriveAdvanceSharingDto info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final meta = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: hud.dim);
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        Text(t.drivePublicLink, style: themeLabel(context)),
        const SizedBox(height: Gap.xs),
        SelectableText(
          info.url,
          key: const Key('drive-advance-sharing-url'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: Gap.md),
        Text(
          '${t.driveChangePermission}: ${info.normalizedRole.labelText()}',
          key: const Key('drive-advance-sharing-role'),
          style: meta,
        ),
        if (info.hasPassword)
          Text(driveC1(DriveC1TextKeys.linkPasswordOn, '已设置访问密码'), style: meta),
        // D40：公开链接的**密码校验**。走 `AdvanceSharing.Public/auth` v1
        // （`AdvanceSharing/verify` 真机是管理员专属，见 [DriveApi] 注释）。
        if (info.hasPassword) ...[
          const SizedBox(height: Gap.md),
          _PasswordVerify(info: info),
        ],
        // ★ 第 60 轮 D39 UI：**设置 / 清除访问密码**。
        //
        // 官方把密码放在 `update` 的 `protect_password` 里发（明文，见
        // [DriveApi.updateAdvanceSharing] 的第 59 轮订正），并且
        // `get` 会**回显**它 —— 所以这里初值直接填服务端的现密码。
        const SizedBox(height: Gap.md),
        _ProtectPasswordEditor(info: info, path: path),
        const SizedBox(height: Gap.md),
        _LinkExpiryEditor(info: info, path: path),
        const SizedBox(height: Gap.md),
        Wrap(
          spacing: Gap.sm,
          children: [
            for (final role in const [
              DriveShareRole.viewer,
              DriveShareRole.commenter,
              DriveShareRole.editor,
            ])
              ChoiceChip(
                key: Key('drive-advance-sharing-role-${role.value}'),
                label: Text(role.labelText()),
                selected: info.normalizedRole == role,
                onSelected: (v) {
                  if (v) _setRole(context, ref, role);
                },
              ),
          ],
        ),
        const SizedBox(height: Gap.md),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('drive-advance-sharing-close'),
            icon: const Icon(Icons.link_off, size: 18),
            label: Text(driveC1(DriveC1TextKeys.closeLink, '关闭链接')),
            onPressed: () => _close(context, ref),
          ),
        ),
      ],
    );
  }

  TextStyle? themeLabel(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge;

  Future<void> _setRole(
    BuildContext context,
    WidgetRef ref,
    DriveShareRole role,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      // ★★ 第 60 轮修回归：`update` 是**全量覆盖**（官方语义，见
      // [DriveApi.updateAdvanceSharing]）。第 59 轮补上 `protect_password`
      // 与 `due_date` 的"总是发"之后，这里若只传 `role`，就会
      // **静默清掉用户的访问密码和有效期** —— 界面上只提示"权限已更新"，
      // 用户完全不会发现密码没了。
      //
      // 服务端 `AdvanceSharing/get` 会**回显** `protect_password`
      // （`ProtectionLinkDataVo.protect_password`），所以这里把它与
      // `due_date` 一起**原样回填**，才是官方那种"读-改-写"。
      await drive.updateAdvanceSharing(
        path: path,
        sharingLink: info.sharingLink,
        role: role,
        dueDate: info.dueDate,
        protectPassword: info.protectPassword,
      );
      ref.invalidate(driveAdvanceSharingProvider(path));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveC1Fill(DriveC1TextKeys.roleUpdated, '权限已更新为「{role}」', {
              'role': role.labelText(),
            }),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveC1Fill(DriveC1TextKeys.actionFailed, '操作失败：{error}', {
              'error': describeFileError(e),
            }),
          ),
        ),
      );
    }
  }

  Future<void> _close(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(driveC1(DriveC1TextKeys.closeLinkConfirm, '关闭公开链接？')),
        content: Text(
          driveC1(DriveC1TextKeys.closeLinkBody, '关闭后该公开链接立即失效，拿到链接的人将无法访问。'),
        ),
        actions: [
          TextButton(
            key: const Key('drive-advance-sharing-close-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('drive-advance-sharing-close-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(driveC1(DriveC1TextKeys.closeLink, '关闭链接')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.deleteAdvanceSharing(
        path: path,
        sharingLink: info.sharingLink,
      );
      ref.invalidate(driveAdvanceSharingProvider(path));
      messenger.showSnackBar(
        SnackBar(content: Text(driveC1(DriveC1TextKeys.linkClosed, '已关闭链接'))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveC1Fill(DriveC1TextKeys.actionFailed, '操作失败：{error}', {
              'error': describeFileError(e),
            }),
          ),
        ),
      );
    }
  }
}

/// D40：公开链接的**访问密码校验**输入区。
///
/// 走 `SYNO.SynologyDrive.AdvanceSharing.Public / auth` **v1**
/// （参数 `sharing_link` + `password`；原文与真机取证见
/// [DriveApi.authAdvanceSharingPassword]）。
///
/// 为什么要"校验密码"这个动作：官方公开分享页在访客输入密码后调同一条
/// `auth_adv_sharing`；这里把它做成拥有者可自查的能力——设了密码的链接在
/// App 内能确认"这个密码到底对不对"，而不是只能复制链接去浏览器试。
/// ★ 第 60 轮 D39：**访问密码编辑器**。
///
/// 关键纪律（都会"安静出错"，所以写清楚）：
/// * 保存时必须**带上当前的 role 与 dueDate** —— `update` 是全量覆盖，
///   漏传就会把它们清掉；
/// * 清空输入框后保存 = **清除密码**（官方语义：空串就是不设密码），
///   所以必须给用户明确的二次确认，不能让误删变成静默行为。
class _ProtectPasswordEditor extends ConsumerStatefulWidget {
  const _ProtectPasswordEditor({required this.info, required this.path});

  final DriveAdvanceSharingDto info;
  final String path;

  @override
  ConsumerState<_ProtectPasswordEditor> createState() =>
      _ProtectPasswordEditorState();
}

class _ProtectPasswordEditorState
    extends ConsumerState<_ProtectPasswordEditor> {
  late final TextEditingController _pw = TextEditingController(
    // 服务端回显的现密码（`ProtectionLinkDataVo.protect_password`）
    text: widget.info.protectPassword,
  );
  var _busy = false;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    final next = _pw.text.trim();
    // ★ 在**任何 await 之前**取 messenger：下面 `showDialog` 之后再用
    // `ScaffoldMessenger.of(context)` 会踩 `use_build_context_synchronously`
    // （widget 可能在对话框期间被销毁）。
    final messenger = ScaffoldMessenger.of(context);
    final clearing = next.isEmpty && widget.info.hasPassword;
    if (clearing) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(driveC1(DriveC1TextKeys.clearLinkPassword, '清除访问密码？')),
          content: Text(
            driveC1(
              DriveC1TextKeys.clearLinkPasswordHint,
              '清除后，任何拿到链接的人都能直接访问。',
            ),
          ),
          actions: [
            TextButton(
              key: const Key('drive-link-password-clear-cancel'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.t.actionCancel),
            ),
            TextButton(
              key: const Key('drive-link-password-clear-confirm'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                driveC1(DriveC1TextKeys.clearLinkPassword, '清除访问密码？'),
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await drive.updateAdvanceSharing(
        path: widget.path,
        sharingLink: widget.info.sharingLink,
        // ★ 必须带上当前 role / dueDate（全量覆盖）
        role: widget.info.normalizedRole,
        dueDate: widget.info.dueDate,
        protectPassword: next,
      );
      ref.invalidate(driveAdvanceSharingProvider(widget.path));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            next.isEmpty
                ? driveC1(DriveC1TextKeys.linkPasswordCleared, '已清除访问密码')
                : driveC1(DriveC1TextKeys.linkPasswordSaved, '访问密码已保存'),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(describeFileError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('drive-link-password-field'),
            controller: _pw,
            obscureText: true,
            decoration: InputDecoration(
              labelText: driveC1(DriveC1TextKeys.linkPassword, '访问密码'),
              helperText: driveC1(
                DriveC1TextKeys.linkPasswordHint,
                '留空并保存 = 不设密码',
              ),
            ),
          ),
        ),
        const SizedBox(width: Gap.sm),
        FilledButton(
          style: InlineButtonStyle.filled,
          key: const Key('drive-link-password-save'),
          onPressed: _busy ? null : _save,
          child: Text(context.t.actionSave),
        ),
      ],
    );
  }
}

/// ★ 第 61 轮 D39 收口：**链接有效期编辑器**。
///
/// ## 官方交互（`Android-SynologyDrive.3.9.0-1113`）
/// * 开关文案 `enable_expiration` = "Add expiration"
/// * 字段标题 `expire_field_title` = "Link expiration"
/// * 交互是 **DatePickerFragment → TimePickerFragment**（`FileRequestFragment`
///   `:1101` / `:1151`）⇒ 官方精确到**分钟**，不是"只想选一天"。
/// * 传输：`due_date` = **秒**（`dueDate.getTime() / 1000`，`:90`）；
///   **`0` = 不过期**（`dueDate != null ? … : 0L`）。
///
/// ## 与密码编辑器同一条纪律
/// `update` 是**全量覆盖** ⇒ 保存有效期时必须**回填 role 与当前密码**，
/// 否则又会静默清掉另一个字段（第 59/60 轮踩过的那一跤）。
class _LinkExpiryEditor extends ConsumerStatefulWidget {
  const _LinkExpiryEditor({required this.info, required this.path});

  final DriveAdvanceSharingDto info;
  final String path;

  @override
  ConsumerState<_LinkExpiryEditor> createState() => _LinkExpiryEditorState();
}

class _LinkExpiryEditorState extends ConsumerState<_LinkExpiryEditor> {
  var _busy = false;

  Future<void> _save(int dueDateSeconds) async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    if (!mounted) return;
    setState(() => _busy = true);
    // ★ 任何 await 之前先取 messenger
    final messenger = ScaffoldMessenger.of(context);
    try {
      await drive.updateAdvanceSharing(
        path: widget.path,
        sharingLink: widget.info.sharingLink,
        // ★ 必须回填：全量覆盖，漏传即清零
        role: widget.info.normalizedRole,
        protectPassword: widget.info.protectPassword,
        dueDate: dueDateSeconds,
      );
      ref.invalidate(driveAdvanceSharingProvider(widget.path));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dueDateSeconds == 0
                ? driveC1(DriveC1TextKeys.linkExpiryCleared, '已取消有效期')
                : driveC1(DriveC1TextKeys.linkExpirySaved, '有效期已保存'),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 官方是 DatePicker → TimePicker 两步
  Future<void> _pick() async {
    final now = DateTime.now();
    final current = widget.info.hasExpiry
        ? DateTime.fromMillisecondsSinceEpoch(widget.info.dueDate * 1000)
        : now.add(const Duration(days: 7));
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 10),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null) return;
    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    await _save(picked.millisecondsSinceEpoch ~/ 1000);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final meta = Theme.of(context).textTheme.bodyMedium;
    return Row(
      children: [
        Expanded(
          child: Text(
            widget.info.hasExpiry
                ? driveC1Fill(DriveC1TextKeys.linkExpiry, '有效期至 {time}', {
                    'time': formatFileTime(widget.info.dueDate, t: t),
                  })
                : driveC1(DriveC1TextKeys.linkExpiryNone, '不过期'),
            key: const Key('drive-link-expiry-label'),
            style: meta,
          ),
        ),
        TextButton(
          key: const Key('drive-link-expiry-pick'),
          onPressed: _busy ? null : _pick,
          child: Text(
            widget.info.hasExpiry
                ? driveC1(DriveC1TextKeys.linkExpiryEdit, '修改有效期')
                : driveC1(DriveC1TextKeys.linkExpiryAdd, '添加有效期'),
          ),
        ),
        if (widget.info.hasExpiry)
          TextButton(
            key: const Key('drive-link-expiry-clear'),
            onPressed: _busy ? null : () => _save(0),
            child: Text(driveC1(DriveC1TextKeys.linkExpiryClear, '取消有效期')),
          ),
      ],
    );
  }
}

class _PasswordVerify extends ConsumerStatefulWidget {
  const _PasswordVerify({required this.info});

  final DriveAdvanceSharingDto info;

  @override
  ConsumerState<_PasswordVerify> createState() => _PasswordVerifyState();
}

class _PasswordVerifyState extends ConsumerState<_PasswordVerify> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  /// `null` = 还没验证过；`true`/`false` = 服务端裁判结果
  bool? _accepted;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          driveG4(DriveG4TextKeys.passwordVerifyTitle, '校验访问密码'),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: Gap.xs),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('drive-advance-sharing-password-input'),
                controller: _controller,
                obscureText: true,
                enabled: !_busy,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: driveG4(
                    DriveG4TextKeys.passwordVerifyHint,
                    '输入链接的访问密码',
                  ),
                ),
                onSubmitted: (_) => _verify(),
              ),
            ),
            const SizedBox(width: Gap.sm),
            FilledButton(
              style: InlineButtonStyle.filled,
              key: const Key('drive-advance-sharing-password-verify'),
              onPressed: _busy ? null : _verify,
              child: Text(
                driveG4(DriveG4TextKeys.passwordVerifyAction, '校验'),
              ),
            ),
          ],
        ),
        if (_accepted != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
              _accepted!
                  ? driveG4(DriveG4TextKeys.passwordVerifyOk, '密码正确')
                  : driveG4(DriveG4TextKeys.passwordVerifyBad, '密码不正确'),
              key: Key(
                _accepted!
                    ? 'drive-advance-sharing-password-ok'
                    : 'drive-advance-sharing-password-bad',
              ),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          ),
      ],
    );
  }

  Future<void> _verify() async {
    final password = _controller.text;
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            driveG4(DriveG4TextKeys.passwordVerifyEmpty, '请先输入密码'),
          ),
        ),
      );
      return;
    }
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _accepted = null;
    });
    try {
      final ok = await drive.authAdvanceSharingPassword(
        sharingLink: widget.info.sharingLink,
        password: password,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _accepted = ok;
      });
    } catch (e) {
      // 传输层错误：**不伪装成"密码错"**，明确报出来。
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveC1Fill(DriveC1TextKeys.actionFailed, '操作失败：{error}', {
              'error': describeFileError(e),
            }),
          ),
        ),
      );
    }
  }
}
