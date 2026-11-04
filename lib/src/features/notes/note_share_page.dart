// 笔记共享（P1 尾巴）：公开分享 + 分享给 DSM 用户/群组。
//
// 官方取证（NAS 上装的 **NoteStation 2.6.10-3938**，`ui/notestation.js` 的
// 共享对话框 `setPermission` + `Share.Priv` store，逐字）：
//   * 打开共享总开关：`SYNO.NoteStation.Permission / set` v1 `{object_id, enabled:true}`
//     —— 官方在公开分享或加人**之前**都会先发这一条；
//   * 公开分享：`Permission.Public / set` v1 `{object_id, perm}`，`perm` 是
//     字符串枚举 **`"ro"` / `"rw"`**（同一份 JS 的 combobox：
//     `data:[{perm:"ro"},{perm:"rw"}]`）；取消用 `Permission.Public / delete {object_id}`；
//   * 分享给用户：`Permission.User / set` `{object_id, username, perm, uid}`；
//     群组：`Permission.Group / set` `{object_id, groupname, perm, gid}`；
//     取消：`Permission.User|Group / delete`（`username` 或 `uid` 都收）；
//   * 公开链接：`Shard.Link / get` v1 `{object_id, mode:"public"}` → `{url}`；
//   * 候选账号：`Share.Priv / list` **v2** `baseParams:{query:""}`，回包 `list[]`
//     （`{name, type}`，`type` 为 `"group"` 或用户）。
//
// ACL 数据来自笔记自身的 `acl` JSON 列（官方界面读的也是 `objectData.acl`：
// `dsm_user` 的 **key 是 uid**、值里才有 `name`/`perm`/`inherit`；`public` 同形）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/viewport_bound.dart';
import '../../data/dto/note_acl_dto.dart';
import '../../data/dto/note_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import 'note_providers.dart';

class NoteSharePage extends ConsumerStatefulWidget {
  const NoteSharePage({super.key, required this.note});

  final NoteDto note;

  @override
  ConsumerState<NoteSharePage> createState() => _NoteSharePageState();
}

class _NoteSharePageState extends ConsumerState<NoteSharePage> {
  late NoteAcl _acl = widget.note.acl;
  bool _busy = false;
  String? _link;
  bool _linkLoading = false;

  String get _objectId => widget.note.objectId;

  @override
  void initState() {
    super.initState();
    // 已经开着公开分享的笔记：进来就把链接取好（官方分享面板也是即开即显示）
    if (_acl.hasPublic) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadLink());
    }
  }

  void _refreshNote() {
    ref.invalidate(noteDetailProvider(_objectId));
  }

  /// 写操作统一走这里：成功后重新 `getNote`，用服务端回的 `acl` 覆盖本地状态
  /// （官方 `afterAclChanged` 也是拿到新 `acl` 再刷界面）
  Future<void> _apply(Future<void> Function() action, String okText) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action();
      _refreshNote();
      final api = ref.read(noteApiProvider);
      if (api != null) {
        try {
          final fresh = await api.getNote(_objectId);
          if (mounted) setState(() => _acl = fresh.acl);
        } catch (_) {
          // 拉不到就保持乐观状态，不打扰
        }
      }
      messenger.showSnackBar(SnackBar(content: Text(okText)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.noteShareFailed(describeFileError(e)))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPublic(NoteSharePerm? perm) async {
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    if (perm == null) {
      await _apply(
        () => api.deletePublicPermission(_objectId),
        context.t.notePublicShareOff,
      );
    } else {
      await _apply(
        () => api.setPublicPermission(objectId: _objectId, perm: perm),
        context.t.notePublicShareOn(perm.labelText()),
      );
      await _loadLink();
    }
  }

  Future<void> _loadLink() async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    setState(() => _linkLoading = true);
    try {
      final url = await api.publicShareUrl(_objectId);
      if (mounted) setState(() => _link = url.isEmpty ? null : url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.noteShareLinkFailed(describeFileError(e)))),
        );
      }
    } finally {
      if (mounted) setState(() => _linkLoading = false);
    }
  }

  Future<void> _addPrincipal() async {
    final t = context.t;
    final picked = await showModalBottomSheet<({String name, String type})>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _PrincipalSheet(),
    );
    if (picked == null || !mounted) return;
    final perm = await showModalBottomSheet<NoteSharePerm>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _PermSheet(),
    );
    if (perm == null || !mounted) return;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final isGroup = picked.type == 'group';
    await _apply(
      () => isGroup
          ? api.setGroupPermission(
              objectId: _objectId,
              groupname: picked.name,
              perm: perm,
            )
          : api.setUserPermission(
              objectId: _objectId,
              username: picked.name,
              perm: perm,
            ),
      isGroup
          ? t.noteSharedWithGroup(picked.name, perm.labelText())
          : t.noteSharedWithUser(picked.name, perm.labelText()),
    );
  }

  Future<void> _removeEntry(NoteAclEntry entry) async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    await _apply(
      () => entry.isGroup
          ? api.deleteGroupPermission(
              objectId: _objectId,
              groupname: entry.name,
              gid: entry.id,
            )
          : api.deleteUserPermission(
              objectId: _objectId,
              username: entry.name,
              uid: entry.id,
            ),
      t.noteShareRemoved(entry.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final shareable = widget.note.canShare;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(context.t.noteShare),
        actions: [
          if (!shareable)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Center(
                child: Text(
                  context.t.noteEncryptedNoShare,
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ),
            ),
        ],
      ),
      body: !shareable
            ? AppEmptyState(
                icon: Icons.lock_outline,
                title: context.t.noteEncryptedNoShare,
                message: context.t.noteEncryptedNoShareMessage,
              )
            // FieldBackdrop 底层是个 ColoredBox，ListTile 要求中间有个 Material
            // 才肯画背景/水波（Flutter 的断言就是这么定的）
            : Material(
                type: MaterialType.transparency,
                child: ListView(
                  padding: const EdgeInsets.only(bottom: Gap.xl),
                  children: [
                    if (_busy) const LinearProgressIndicator(minHeight: 2),
                    _sectionTitle(context, context.t.notePublicShare),
                    DesignSwitchRow(
                      key: const Key('note-share-public-switch'),
                      value: _acl.hasPublic,
                      onChanged: _busy
                          ? null
                          : (on) =>
                                _setPublic(on ? NoteSharePerm.readOnly : null),
                      title: Text(context.t.noteAnyoneWithLink),
                      subtitle: Text(
                        _acl.hasPublic
                            ? context.t.noteCurrentPerm(
                                _acl.publicPerm!.labelText(),
                              )
                            : context.t.notePublicOffHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hud.dim,
                        ),
                      ),
                    ),
                    if (_acl.hasPublic) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                        child: SegmentedButton<NoteSharePerm>(
                          key: const Key('note-share-public-perm'),
                          segments: [
                            for (final p in NoteSharePerm.values)
                              ButtonSegment(
                                value: p,
                                label: Text(p.labelText()),
                                icon: Icon(
                                  p == NoteSharePerm.readOnly
                                      ? Icons.visibility_outlined
                                      : Icons.edit_outlined,
                                ),
                              ),
                          ],
                          selected: {_acl.publicPerm!},
                          onSelectionChanged: _busy
                              ? null
                              : (s) => _setPublic(s.first),
                        ),
                      ),
                      DesignRowTile(
                        leading: Icon(
                          Icons.link,
                          color: _link == null
                              ? hud.dim
                              : theme.colorScheme.primary,
                        ),
                        title: Text(
                          _link ??
                              (_linkLoading
                                  ? context.t.noteGettingLink
                                  : context.t.noteNoLink),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: context.t.noteCopyLink,
                              icon: const Icon(Icons.copy_all_outlined),
                              onPressed: _link == null
                                  ? null
                                  : () async {
                                      await Clipboard.setData(
                                        ClipboardData(text: _link!),
                                      );
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            context.t.noteLinkCopied,
                                          ),
                                        ),
                                      );
                                    },
                            ),
                            IconButton(
                              tooltip: context.t.noteRefetchLink,
                              icon: const Icon(Icons.refresh),
                              onPressed: _linkLoading ? null : _loadLink,
                            ),
                          ],
                        ),
                      ),
                    ],
                    const Divider(height: Gap.lg),
                    _sectionTitle(context, context.t.noteSharedWith),
                    if (_acl.users.isEmpty && _acl.groups.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Gap.md,
                          0,
                          Gap.md,
                          Gap.sm,
                        ),
                        child: Text(
                          context.t.noteNoIndividualShare,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                      ),
                    for (final e in [..._acl.users, ..._acl.groups])
                      DesignRowTile(
                        key: Key(
                          'note-share-${e.isGroup ? 'group' : 'user'}-${e.name}',
                        ),
                        leading: Icon(
                          e.isGroup
                              ? Icons.groups_outlined
                              : Icons.person_outline,
                          color: hud.dim,
                        ),
                        title: Text(e.name),
                        subtitle: Text(
                          [
                            e.isGroup
                                ? context.t.noteGroup
                                : context.t.noteUser,
                            e.perm.labelText(),
                            if (e.inherit) context.t.noteInherited,
                          ].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: context.t.noteStopSharing,
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: _busy ? null : () => _removeEntry(e),
                        ),
                      ),
                    DesignRowTile(
                      key: const Key('note-share-add'),
                      leading: Icon(Icons.person_add_alt, color: hud.dim),
                      title: Text(context.t.noteAddUserGroup),
                      onTap: _busy ? null : _addPrincipal,
                    ),
                  ],
                ),
              ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: hud.dim),
      ),
    );
  }
}

/// 账号/群组搜索弹层（`Share.Priv/list` v2）
class _PrincipalSheet extends ConsumerStatefulWidget {
  const _PrincipalSheet();

  @override
  ConsumerState<_PrincipalSheet> createState() => _PrincipalSheetState();
}

class _PrincipalSheetState extends ConsumerState<_PrincipalSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final async = ref.watch(noteSharePrincipalsProvider(_query));
    return SafeArea(
      child: Material(
        color: hud.surface2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: hud.line, width: 1),
        ),
        child: Container(
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
                  key: const Key('note-share-search'),
                  controller: _controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: context.t.noteSearchDsmAccount,
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
                      context.t.noteAccountSearchFailed(describeFileError(e)),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: hud.dim),
                    ),
                  ),
                  data: (list) => list.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(Gap.lg),
                          child: Text(context.t.noteNoMatchingAccount),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final p in list)
                              DesignRowTile(
                                leading: Icon(
                                  p.type == 'group'
                                      ? Icons.groups_outlined
                                      : Icons.person_outline,
                                  color: hud.dim,
                                ),
                                title: Text(p.name),
                                subtitle: Text(
                                  p.type == 'group'
                                      ? context.t.noteGroup
                                      : context.t.noteUser,
                                ),
                                onTap: () => Navigator.of(context).pop(p),
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

/// 权限选择弹层（官方 `perm` 枚举：只读 `ro` / 可编辑 `rw`）
class _PermSheet extends StatelessWidget {
  const _PermSheet();

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return SafeArea(
      child: Material(
        color: hud.surface2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: hud.line, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in NoteSharePerm.values)
              DesignRowTile(
                key: Key('note-share-perm-${p.code}'),
                leading: Icon(
                  p == NoteSharePerm.readOnly
                      ? Icons.visibility_outlined
                      : Icons.edit_outlined,
                  color: hud.dim,
                ),
                title: Text(p.labelText()),
                subtitle: Text(
                  p == NoteSharePerm.readOnly
                      ? context.t.notePermReadOnlyDesc
                      : context.t.notePermReadWriteDesc,
                ),
                onTap: () => Navigator.of(context).pop(p),
              ),
          ],
        ),
      ),
    );
  }
}
