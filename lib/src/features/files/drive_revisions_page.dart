// Drive 版本历史页（P3）：`Revisions/list|restore|download`（全是 v1）。
//
// 官方对照（`drive_bundle.js` 的版本面板）：
//   * 列表每行显示"版本时间 · 大小 · 编辑人"，最新一条标"当前"；
//   * 操作是 **下载这个版本** 与 **恢复到这个版本**；恢复本身会再生成一个新版本；
//   * 官方对 Synology Office 文档**不走 Revisions**，而是 `Office.Node.Version`
//     （文档自己的版本、可命名、可恢复、可单独导出）—— 本页现在两种都支持：
//     `.odoc/.osheet/.oslides` 进 Office 版本，其它文件走 Drive 的 Revisions。
import '../../design/kit/design_kit.dart';
import 'dart:io';
import '../../design/design_palette.dart';
import '../../core/net/traffic_meter.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/system_open.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/drive_revision_dto.dart';
import '../../data/dto/office_version_dto.dart';
import '../../data/office_api.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../servers/session_controller.dart';
import 'drive_providers.dart';
import 'file_sheets.dart' show promptFileName;
import 'office_export.dart';
import 'office_providers.dart';
import 'file_providers.dart' show fileDownloadDirectory;
import 'file_row.dart' show formatFileTime;

class DriveRevisionsPage extends ConsumerStatefulWidget {
  const DriveRevisionsPage({super.key, required this.entry});

  final DriveEntryDto entry;

  @override
  ConsumerState<DriveRevisionsPage> createState() => _DriveRevisionsPageState();
}

class _DriveRevisionsPageState extends ConsumerState<DriveRevisionsPage> {
  bool _busy = false;

  DriveEntryDto get _entry => widget.entry;

  Future<void> _restore(DriveRevisionDto rev) async {
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.driveRestoreConfirm),
        content: Text(
          t.driveRestoreRevBody(
            formatFileTime(rev.modifiedTime, t: t),
            rev.humanSize,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.driveRestore),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await drive.restoreRevision(
        fileId: _entry.fileId,
        versionId: rev.versionId,
      );
      ref.invalidate(driveRevisionsProvider(_entry.fileId));
      messenger.showSnackBar(SnackBar(content: Text(t.driveRestoredPending)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(DriveRevisionDto rev, {bool openAfter = false}) async {
    final t = context.t;
    final drive = ref.read(driveApiProvider);
    final api = ref
        .read(sessionControllerProvider)
        .connection
        ?.api
        .withModule(TrafficModules.drive);
    if (drive == null || api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final bytes = await api.getBytes(
        drive.revisionDownloadUrl(
          fileId: _entry.fileId,
          versionId: rev.versionId,
        ),
      );
      final dir = await fileDownloadDirectory();
      final base = _entry.name;
      final dot = base.lastIndexOf('.');
      final named = dot <= 0
          ? '$base.v${rev.versionId}'
          : '${base.substring(0, dot)}.v${rev.versionId}${base.substring(dot)}';
      final file = File('${dir.path}/$named');
      await file.writeAsBytes(bytes);
      if (openAfter) await ref.read(systemOpenProvider)(file.path);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            openAfter ? t.photoOpenedWith(named) : t.driveDownloaded(named),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.fileDownloadFailed(describeFileError(e)))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    // Synology Office 原生文档（`.odoc/.osheet/.oslides`）走 Office 自己的版本历史：
    // 官方 Drive 的版本面板对这类文件是直接跳 `/oo/r/<permanent_link>`，不用 Revisions。
    if (isOfficeNativeName(_entry.name) && _entry.permanentLink.isNotEmpty) {
      return _OfficeVersionsPage(entry: _entry);
    }
    final async = ref.watch(driveRevisionsProvider(_entry.fileId));
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            children: [
              _Header(
                title: t.noteVersionHistory,
                subtitle: t.driveFileHud(_entry.name),
                onRefresh: () {
                  ref.invalidate(driveRevisionsProvider(_entry.fileId));
                },
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: async.when(
                  loading: () => const AppListSkeleton(),
                  error: (e, _) => AppErrorView(
                    title: t.driveRevisionsOpenFailed,
                    detail: describeFileError(e),
                    onRetry: () =>
                        ref.invalidate(driveRevisionsProvider(_entry.fileId)),
                  ),
                  data: (revs) => revs.isEmpty
                      ? AppEmptyState(
                          icon: Icons.history,
                          title: t.noteNoVersions,
                          message: t.driveNoRevisionsMessage,
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: revs.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) {
                            final rev = revs[i];
                            final current =
                                rev.isCurrent(_entry.versionId) ||
                                (i == 0 && _entry.versionId.isEmpty);
                            return DesignRowTile(
                              leading: Icon(
                                current
                                    ? Icons.check_circle
                                    : Icons.history_outlined,
                                color: current
                                    ? Theme.of(context).colorScheme.primary
                                    : hud.dim,
                              ),
                              title: Text(
                                [
                                  formatFileTime(rev.modifiedTime, t: t),
                                  if (current) t.driveVersionCurrent,
                                ].join(' · '),
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              subtitle: Text(
                                [
                                  rev.humanSize,
                                  if (rev.editorLabel.isNotEmpty)
                                    rev.editorLabel,
                                  t.driveVersionId(rev.versionId),
                                ].join(' · '),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: hud.dim),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: t.driveDownloadVersion,
                                    icon: const Icon(Icons.download_outlined),
                                    onPressed: _busy
                                        ? null
                                        : () => _download(rev),
                                  ),
                                  if (!current)
                                    IconButton(
                                      tooltip: t.driveRestoreVersion,
                                      icon: const Icon(Icons.restore),
                                      onPressed: _busy
                                          ? null
                                          : () => _restore(rev),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onRefresh,
  });

  final String title;
  final String subtitle;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.sm),
      child: Row(
        children: [
          IconButton(
            tooltip: context.t.calBack,
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: hud.dim,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: context.t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------- Synology Office 版本
//
// `SYNO.Office.Node.Version` v1（`get list restore rename`，普通用户可用）：
//   * 列表：`{path:'id:<file_id>', additional:{uid,name,nickname}, limit, offset}`
//     → `versions`（字段 `author version mtime editors last_version ver_name
//     commit_msg`）；本仓库在 `Node.Version:list` 上真机验过的形态就是
//     **`path=id:<file_id>`**；
//   * 恢复：`{path:'id:<file_id>', ver}`；
//   * 命名：`{object_id, ver, ver_name, overwrite:true}`（**只有** `object_id`）；
//   * 导出某个版本：`Office.Export/download {path:'id:<file_id>', format, ver}`，
//     `format` 是**目标扩展名**（真机唯一验过 `format:"xlsx"`）。
//
// ⚠️ 写入批次真机纠错（`docs/live-write-verification.md` §4#12/#13）：
//   * `Office.Node` 族**没有 `list`**（→ `103`），也没人调用它；
//   * `Node:get {object_id}` → `1000`；真参数是 **`path`**。所以我们解析内部 id
//     只发 `{path:'id:<file_id>', basic:true}`，`permanent_link` **不再**被当作
//     `object_id` 备用形态（旧兜底已删）。
//
// `object_id` 与 `link_id` 是 Office 库里的**两列**（见 `office_api.dart` 头注释）：
// `object_id` 形如 `1028_35AO…`（内部 id），`permanent_link` 才是 Drive 的 `link_id`。
class _OfficeVersionsPage extends ConsumerStatefulWidget {
  const _OfficeVersionsPage({required this.entry});

  final DriveEntryDto entry;

  @override
  ConsumerState<_OfficeVersionsPage> createState() =>
      _OfficeVersionsPageState();
}

class _OfficeVersionsPageState extends ConsumerState<_OfficeVersionsPage> {
  bool _busy = false;

  /// 文档内部 id（`1028_…`）：`rename` 只认它 —— 由 `Office.Node/get`
  /// （**只发 `path`**，真机 `object_id` 入参回 `1000`）解析，
  /// 进页面就解析一次（解析失败只影响"命名版本"这一个动作）
  String? _nodeId;

  DriveEntryDto get _entry => widget.entry;

  @override
  void initState() {
    super.initState();
    _resolveNodeId();
  }

  Future<String?> _resolveNodeId() async {
    if (_nodeId != null) return _nodeId;
    try {
      final id = await ref
          .read(officeApiProvider)
          ?.resolveObjectId(fileId: _entry.fileId);
      if (mounted && id != null) setState(() => _nodeId = id);
      return id;
    } catch (_) {
      // 解析失败不打扰用户（只有"命名版本"会用不了）
      return null;
    }
  }

  String get _versionKey => _entry.fileId;

  void _refresh() => ref.invalidate(officeNodeVersionsProvider(_versionKey));

  /// 导出这个版本（官方 `downloadOffice({format:'ms', ver})`）。
  ///
  /// 走 `OfficeApi.exportBytes`（**POST 表单**）：参数放查询串上服务端不认
  /// `format`（真机实测 2026-09-20）。`format` 发的是**目标扩展名**（真机唯一
  /// 验过的形状是 `format:"xlsx"`，见 [officeExportServerFormat]，`ms` 只是官方
  /// 前端的档位名），落盘名按官方 `EXPORT_EXTENSION` 换后缀并标版本号。
  Future<void> _download(OfficeVersionDto ver, {bool openAfter = false}) async {
    final t = context.t;
    final office = ref.read(officeApiProvider);
    if (office == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final bytes = await office.exportBytes(
        fileId: _entry.fileId,
        format: officeExportServerFormat(_entry.name, 'ms'),
        version: ver.version,
        fileName: _entry.name,
      );
      final dir = await fileDownloadDirectory();
      // 导出文件名按官方 `EXPORT_EXTENSION` 换成 docx/xlsx/pptx，再标上版本号
      final exported = exportFileName(_entry.name);
      final dot = exported.lastIndexOf('.');
      final named = dot <= 0
          ? '$exported.v${ver.version}'
          : '${exported.substring(0, dot)}.v${ver.version}'
                '${exported.substring(dot)}';
      final file = File('${dir.path}/$named');
      await file.writeAsBytes(bytes);
      officeProbeBytes(named, bytes);
      if (openAfter) await ref.read(systemOpenProvider)(file.path);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            openAfter ? t.photoOpenedWith(named) : t.driveExported(named),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.driveExportFailed(describeFileError(e)))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(OfficeVersionDto ver) async {
    final t = context.t;
    final office = ref.read(officeApiProvider);
    if (office == null) return;
    final at = ver.modifiedTime;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.driveRestoreConfirm),
        content: Text(
          at == null
              ? t.driveOfficeRestoreBody(ver.label)
              : t.driveOfficeRestoreBodyAt(
                  ver.label,
                  formatFileTime(at.millisecondsSinceEpoch ~/ 1000, t: t),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.driveRestore),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await office.restoreNodeVersion(
        fileId: _entry.fileId,
        version: ver.version,
      );
      _refresh();
      messenger.showSnackBar(SnackBar(content: Text(t.driveRestoredPending)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.driveRestoreFailed(describeFileError(e)))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 给版本命名（官方 `history:create_version_name` / `change_version_name`）
  ///
  /// ⚠️ `rename` 只认 `object_id`（官方白名单里没有 `path`），所以先把文档内部
  /// id 解析出来；解析不到就**不发请求**，直接说明原因（真机上就是靠这条排掉
  /// 了 `114 缺少必需参数`）。
  Future<void> _rename(OfficeVersionDto ver) async {
    final t = context.t;
    final office = ref.read(officeApiProvider);
    if (office == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final nodeId = await _resolveNodeId();
    if (nodeId == null || nodeId.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(t.driveNoNodeId)));
      return;
    }
    if (!mounted) return;
    final name = await promptFileName(
      context,
      title: ver.hasName ? t.driveVersionNameEdit : t.driveVersionNameNew,
      actionLabel: t.actionSave,
      initial: ver.verName,
      hintText: t.driveVersionNameHint,
      helperText: t.driveVersionNameHelper,
    );
    if (name == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await office.renameNodeVersion(
        objectId: nodeId,
        version: ver.version,
        verName: name,
      );
      _refresh();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            name.isEmpty
                ? t.driveVersionAutoRestored
                : t.driveVersionNamed(name),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.driveVersionRenameFailed(describeFileError(e))),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(officeNodeVersionsProvider(_versionKey));
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            children: [
              _Header(
                title: t.noteVersionHistory,
                subtitle: t.driveOfficeHud(_entry.name),
                onRefresh: _refresh,
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: async.when(
                  loading: () => const AppListSkeleton(),
                  error: (e, _) => AppErrorView(
                    title: t.driveRevisionsOpenFailed,
                    detail: describeFileError(e),
                    onRetry: _refresh,
                  ),
                  data: (vers) => vers.isEmpty
                      ? AppEmptyState(
                          icon: Icons.history,
                          title: t.noteNoVersions,
                          message: t.driveOfficeNoRevisionsMessage,
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: vers.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) {
                            final ver = vers[i];
                            final meta = [
                              if (ver.modifiedTime != null)
                                formatFileTime(
                                  ver.modifiedTime!.millisecondsSinceEpoch ~/
                                      1000,
                                  t: t,
                                ),
                              if (ver.author.isNotEmpty) ver.author,
                              if (ver.editors.length > 1)
                                t.driveVersionEditors(ver.editors.length),
                              if (ver.firstVersion) t.driveVersionFirst,
                            ].join(' · ');
                            return DesignRowTile(
                              key: Key('office-version-${ver.version}'),
                              leading: Icon(
                                ver.hasName
                                    ? Icons.bookmark
                                    : Icons.history_outlined,
                                color: ver.hasName
                                    ? Theme.of(context).colorScheme.primary
                                    : hud.dim,
                              ),
                              title: Text(
                                ver.label,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (meta.isNotEmpty)
                                    Text(
                                      meta,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: hud.dim),
                                    ),
                                  if (ver.commitMsg.isNotEmpty)
                                    Text(
                                      ver.commitMsg,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: hud.dim),
                                    ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: t.driveNameVersion,
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: _busy
                                        ? null
                                        : () => _rename(ver),
                                  ),
                                  // 官方 UI 不拿 `listable` 控界面（它是服务端字段，
                                  // 只在 .so 里出现），所以这里也一律给导出；失败会报错
                                  IconButton(
                                    tooltip: t.driveExportVersion,
                                    icon: const Icon(Icons.download_outlined),
                                    onPressed: _busy
                                        ? null
                                        : () => _download(ver),
                                  ),
                                  IconButton(
                                    tooltip: t.driveRestoreVersion,
                                    icon: const Icon(Icons.restore),
                                    onPressed: _busy
                                        ? null
                                        : () => _restore(ver),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
    );
  }
}
