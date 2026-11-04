// Drive 共享页（P3）：公开链接 + 成员权限。
//
// 官方对照与真机形状（`tool/drive_share_probe.dart`，2026-09-19 双向验证）：
//   * 公开链接：`Sharing/create_link` v1 `{path:'id:<file_id>'}` → `{url}`
//     （这个接口是"拿到或创建"，重复调用回同一个链接，所以进来直接调就好）；
//     ★ DA19（r380 修法）：这条通道**服务端没有撤销/删除方法**（r378 逐字查过
//     `SYNO.SynologyDrive.Sharing` 的 v1/v2 == `list`/`update`/`create_link`/
//     `use_link`/`sync_to_device`(+v2 `get_base_url`)），拿到的 URL 就是该文件的
//     **永久打开地址**。所以本页①**不再把它叫成可撤销的「公开链接」**，
//     ②撤销入口**指向真的能关的那条通道** = `AdvanceSharing` 的「关闭链接」
//     （[DriveAdvanceSharingPage]，见 `drive_advance_sharing_page.dart` 的 `_close`）。
//     绝不能在更名后仍暗示"这里能关"—— 那是新一轮的"会撒谎的文案"（AGENTS R8）。
//   * 成员：`Sharing/list` v1 → `{items:[{name,type,role,inherited,permission_id}]}`；
//   * 邀请/改权限/移除：`Sharing/update` v1 + `permissions` 动作数组；
//   * 成员搜索：`Share.Priv/list` v1（返回本 NAS 的用户/群组）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/design_palette.dart';
import '../../core/system_open.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/viewport_bound.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/drive_share_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../drive/drive_advance_sharing_page.dart';
import 'drive_providers.dart';

class DriveSharePage extends ConsumerStatefulWidget {
  const DriveSharePage({super.key, required this.entry});

  final DriveEntryDto entry;

  @override
  ConsumerState<DriveSharePage> createState() => _DriveSharePageState();
}

class _DriveSharePageState extends ConsumerState<DriveSharePage> {
  String? _link;
  bool _linkBusy = false;
  bool _linkFailed = false;
  bool _mutating = false;

  DriveEntryDto get _entry => widget.entry;

  @override
  void initState() {
    super.initState();
    // 官方 Web 端也是进面板就拿链接（重复调用回同一个 URL）
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLink());
  }

  Future<void> _loadLink() async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    setState(() {
      _linkBusy = true;
      _linkFailed = false;
    });
    try {
      final url = await drive.createShareLink(fileId: _entry.fileId);
      if (mounted) setState(() => _link = url);
    } catch (_) {
      if (mounted) setState(() => _linkFailed = true);
    } finally {
      if (mounted) setState(() => _linkBusy = false);
    }
  }

  Future<void> _invite() async {
    final t = context.t;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    final picked = await showModalBottomSheet<DriveShareChange>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _InviteSheet(),
    );
    if (picked == null || !mounted) return;
    await _apply([picked], done: t.driveSharedWith(picked.name));
  }

  Future<void> _changeRole(DriveShareDto share) async {
    final t = context.t;
    final role = await showModalBottomSheet<DriveShareRole>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _RoleSheet(current: share.role),
    );
    if (role == null || role == share.role || !mounted) return;
    await _apply([
      DriveShareChange.invite(name: share.name, type: share.type, role: role),
    ], done: t.driveRoleChanged(share.name, role.labelText()));
  }

  Future<void> _remove(DriveShareDto share) async {
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.driveRemoveShareConfirm),
        content: Text(t.driveRemoveShareBody(share.name, _entry.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.driveRemoveShareAction),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _apply([
      DriveShareChange.remove(name: share.name, type: share.type),
    ], done: t.driveRemovedShare(share.name));
  }

  Future<void> _apply(
    List<DriveShareChange> changes, {
    required String done,
  }) async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _mutating = true);
    try {
      await drive.updateShares(fileId: _entry.fileId, changes: changes);
      ref.invalidate(driveSharesProvider(_entry.fileId));
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _copyLink() async {
    final link = _link;
    if (link == null || link.isEmpty) return;
    final t = context.t;
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.noteLinkCopied)));
    }
  }

  Future<void> _openLink() async {
    final link = _link;
    if (link == null || link.isEmpty) return;
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    // 测试环境不启动浏览器（见 `core/system_open.dart`）
    if (isTestEnvironment) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// DA19：把"撤销"交给真的能撤销的那条通道（`AdvanceSharing` 的「关闭链接」）。
  /// 本页**只做跳转**，不做任何删除类调用（服务端这条通道本来就没有撤销方法）。
  Future<void> _managePublicSharing() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DriveAdvanceSharingPage(
          path: _entry.pathId,
          entryName: _entry.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final shares = ref.watch(driveSharesProvider(_entry.fileId));
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.md,
                  Gap.sm,
                  Gap.sm,
                  Gap.sm,
                ),
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
                            t.noteShare,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            t.driveFileHud(_entry.name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: hud.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: t.driveInvite,
                      icon: const Icon(Icons.person_add_alt),
                      onPressed: _mutating ? null : _invite,
                    ),
                  ],
                ),
              ),
              if (_mutating) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: Gap.xl),
                  children: [
                    _SectionTitle(text: t.drivePermanentLink, hud: hud),
                    if (_linkBusy)
                      const Padding(
                        padding: EdgeInsets.all(Gap.md),
                        child: LinearProgressIndicator(minHeight: 2),
                      )
                    else if (_linkFailed)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                t.driveNoPublicLink,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: hud.dim,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _loadLink,
                              child: Text(t.photoRetry),
                            ),
                          ],
                        ),
                      )
                    else if (_link != null && _link!.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                        child: SelectableText(
                          _link!,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                        child: Row(
                          children: [
                            TextButton.icon(
                              onPressed: _copyLink,
                              icon: const Icon(Icons.copy, size: 18),
                              label: Text(t.noteCopyLink),
                            ),
                            TextButton.icon(
                              onPressed: _openLink,
                              icon: const Icon(Icons.open_in_new, size: 18),
                              label: Text(t.driveOpenInBrowser),
                            ),
                          ],
                        ),
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                        child: Text(
                          t.driveRefreshForLink,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                      ),
                    // DA19：把"这条链接能不能关"说明白，并把撤销入口指到真的能关的地方
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Gap.md,
                        Gap.sm,
                        Gap.md,
                        0,
                      ),
                      child: Text(
                        t.drivePermanentLinkNote,
                        key: const Key('drive-permanent-link-note'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hud.dim,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const Key('drive-manage-public-sharing'),
                          onPressed: _managePublicSharing,
                          icon: const Icon(Icons.link_off, size: 18),
                          label: Text(t.driveManagePublicSharing),
                        ),
                      ),
                    ),
                    _SectionTitle(text: t.driveSharedWithSection, hud: hud),
                    shares.when(
                      // 骨架是 ListView，套在外层 ListView 里必须给高度
                      loading: () =>
                          const SizedBox(height: 220, child: AppListSkeleton()),
                      error: (e, __) => AppErrorView(
                        title: t.driveSharesLoadFailed,
                        detail: describeFileError(e),
                        onRetry: () =>
                            ref.invalidate(driveSharesProvider(_entry.fileId)),
                      ),
                      data: (list) => list.isEmpty
                          ? AppEmptyState(
                              icon: Icons.group_outlined,
                              title: t.driveNoShares,
                              message: t.driveNoSharesMessage,
                              compact: true,
                            )
                          : Column(
                              children: [
                                for (final s in list)
                                  Material(
                                    type: MaterialType.transparency,
                                    child: DesignRowTile(
                                      leading: Icon(
                                        s.isGroup
                                            ? Icons.groups_outlined
                                            : Icons.person_outline,
                                        color: hud.dim,
                                      ),
                                      title: Text(
                                        s.name,
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                      subtitle: Text(
                                        [
                                          s.isGroup ? t.noteGroup : t.noteUser,
                                          s.role.labelText(),
                                          if (s.inherited)
                                            t.driveInheritedFromParent,
                                        ].join(' · '),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(color: hud.dim),
                                      ),
                                      trailing: s.inherited
                                          ? null
                                          : Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                IconButton(
                                                  tooltip:
                                                      t.driveChangePermission,
                                                  icon: const Icon(
                                                    Icons.tune,
                                                    size: 20,
                                                  ),
                                                  onPressed: _mutating
                                                      ? null
                                                      : () => _changeRole(s),
                                                ),
                                                IconButton(
                                                  tooltip:
                                                      t.driveRemoveShareAction,
                                                  icon: const Icon(
                                                    Icons
                                                        .person_remove_alt_1_outlined,
                                                    size: 20,
                                                  ),
                                                  onPressed: _mutating
                                                      ? null
                                                      : () => _remove(s),
                                                ),
                                              ],
                                            ),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text, required this.hud});

  final String text;
  final DesignPalette hud;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.lg, Gap.md, Gap.xs),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: hud.dim),
    ),
  );
}

/// 邀请弹层：搜账号 → 选角色 → 返回一条 [DriveShareChange]
class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet();

  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pick(String name, String type) async {
    final role = await showModalBottomSheet<DriveShareRole>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _RoleSheet(current: DriveShareRole.viewer),
    );
    if (role == null || !mounted) return;
    Navigator.of(
      context,
    ).pop(DriveShareChange.invite(name: name, type: type, role: role));
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(drivePrincipalsProvider(_query));
    return SafeArea(
      child: Material(
        color: hud.surface2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: hud.line, width: 1),
        ),
        child: Container(
          // 弹层里的列表要有**有界高度**：`Column(min)`+`Flexible`+`ListView`
          // 在没有高度约束时会直接布局报错（测试里抓到的）
          constraints: BoxConstraints(
            // P2-9：0.7 是经验系数，加安全上下界（见 viewport_bound.dart）
            maxHeight: boundedViewportHeight(
              MediaQuery.sizeOf(context).height,
              0.7,
            ),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: t.driveSearchPrincipalsHint,
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
              Flexible(
                child: async.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(Gap.lg),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                  error: (e, __) => Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Text(
                      t.driveSearchPrincipalsFailed(describeFileError(e)),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: hud.dim),
                    ),
                  ),
                  data: (list) => list.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(Gap.lg),
                          child: Text(t.driveNoMatchingAccount),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final p in list)
                              DesignRowTile(
                                // 选择器是"扫一眼就点"的清单 ⇒ 用紧凑档
                                dense: true,
                                leading: Icon(
                                  p.type == 'group'
                                      ? Icons.groups_outlined
                                      : Icons.person_outline,
                                  color: hud.dim,
                                ),
                                title: Text(
                                  p.nickname.isEmpty
                                      ? p.name
                                      : t.drivePrincipalWithNickname(
                                          p.name,
                                          p.nickname,
                                        ),
                                ),
                                subtitle: Text(
                                  p.type == 'group' ? t.noteGroup : t.noteUser,
                                ),
                                onTap: () => _pick(p.name, p.type),
                              ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 角色选择弹层
class _RoleSheet extends StatelessWidget {
  const _RoleSheet({required this.current});

  final DriveShareRole current;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    return SafeArea(
      child: Material(
        color: hud.surface2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: hud.line, width: 1),
        ),
        child: Container(
          // 六个角色在小屏/测试画布上会超出默认弹层高度 → 给上界 + 可滚动
          constraints: BoxConstraints(
            // P2-9：0.7 是经验系数，加安全上下界（见 viewport_bound.dart）
            maxHeight: boundedViewportHeight(
              MediaQuery.sizeOf(context).height,
              0.7,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Text(
                  t.driveChoosePermission,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in DriveShareRole.values)
                      DesignRowTile(
                        // 六个角色要在弹层里一屏排下 ⇒ 紧凑档
                        dense: true,
                        leading: Icon(
                          r == current
                              ? Icons.radio_button_checked
                              : Icons.circle_outlined,
                          color: r == current
                              ? Theme.of(context).colorScheme.primary
                              : hud.dim,
                        ),
                        title: Text(r.labelText()),
                        onTap: () => Navigator.of(context).pop(r),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Gap.md),
            ],
          ),
        ),
      ),
    );
  }
}
