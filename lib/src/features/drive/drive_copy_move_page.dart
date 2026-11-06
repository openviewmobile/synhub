// 复制 / 移动到…（P0-7）。目标目录选择 + **同名冲突按官方三步走**。
//
// 官方原文（逐条对应，不许硬编码）：
//   1. 请求：`Files/copy` / `Files/move` **v2**
//      （APK `ApiSynoDriveFiles.java:557-565/579-587`；Web 描述符
//      `copy_files`/`move_files` = v2，`synodrive_common.js:18`），
//      参数 `files`（JSON 数组串）+ `to_parent_folder`（`id:<folder_id>`）
//      + `conflict_action`。
//   2. **同名冲突探测**：官方 Web `mvcpNode` 先发 `{dry_run:true}`（**不带**
//      `conflict_action`），回包 `result[]` 里带 `src_info`/`dst_info`/
//      `dst_locked_by_others`/`renamed`；只有存在"可处理的冲突"才弹框
//      （`needToShowConflictDialog` 会把 `dst_locked_by_others` 的项滤掉），
//      否则直接按默认动作发正式请求（`synodrive_common.js:20`）。
//      —— 我们用 [DriveApi.probeCopyMove] 走同一条路。
//   3. **冲突动作**：官方默认 `autorename`（`doMvcpNode` 的
//      `t.conflict_action=o||"autorename"`；APK 也是硬编码 `autorename`），
//      另两个官方常量 `overwrite` / `stop`（`ApiSynoDriveFiles.java:44-46`）。
//      官方**从不静默覆盖**同名文件：不选 `overwrite` 就不会覆盖。
//   4. `change_name`：只有 move 的白名单里有（`synodrive_common.js:20`），
//      本批不做"移动并改名"，故不发。
//
// ⚠️ 简报里的 `dest_folder` / `accurate_progress` 在 APK 与 SPK 全量检索中
// **不存在**（零命中）→ 不实现，见 `docs/drive-p0-implementation.md` 的"证不到"。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/drive_api.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/drive_move_conflict_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../files/drive_browse_view.dart'
    show driveEntryAsFile, refreshDriveViews;
import '../files/drive_providers.dart';
import '../files/file_thumb.dart' show FileIconTile;
import 'drive_gaps_text.dart' show DriveGapTextKeys, driveGap;
import 'drive_p0_text.dart';

/// 复制 / 移动的目标目录选择页
class DriveCopyMovePage extends ConsumerStatefulWidget {
  const DriveCopyMovePage({
    super.key,
    required this.entries,
    required this.move,
  });

  /// 要操作的文件/文件夹（官方 `files` 是多个）
  final List<DriveEntryDto> entries;
  final bool move;

  @override
  ConsumerState<DriveCopyMovePage> createState() => _DriveCopyMovePageState();
}

class _DriveCopyMovePageState extends ConsumerState<DriveCopyMovePage> {
  final List<({String id, String name, String pathId})> _stack = [
    (
      id: '',
      name: driveGap(DriveGapTextKeys.scopeMyDriveTitle, '我的文件'),
      pathId: kDriveRoot,
    ),
  ];
  bool _busy = false;

  String get _pathId => _stack.last.pathId;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final title = widget.move
        ? driveP0(DriveP0TextKeys.moveTo, '移动到…')
        : driveP0(DriveP0TextKeys.copyTo, '复制到…');
    final async = ref.watch(driveListProvider(_pathId));
    return Scaffold(
      key: const Key('drive-copy-move-page'),
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          tooltip: t.calBack,
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_stack.length > 1) {
              setState(() => _stack.removeLast());
            } else {
              Navigator.of(context).maybePop();
            }
          },
        ),
        actions: [
          TextButton(
            key: const Key('drive-copy-move-here'),
            onPressed: _busy ? null : _confirm,
            child: Text(
              widget.move
                  ? driveP0(DriveP0TextKeys.moveHere, '移动到这里')
                  : driveP0(DriveP0TextKeys.copyHere, '复制到这里'),
            ),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppEmptyState(
          icon: Icons.error_outline,
          title: driveP0(DriveP0TextKeys.folderOpenFailed, '打不开这个文件夹'),
          message: describeFileError(e),
          actionLabel: t.photoRetry,
          onAction: () => ref.invalidate(driveListProvider(_pathId)),
        ),
        // 只列目录（官方的目标选择也是一棵树，文件不可选）
        data: (data) {
          final dirs = [for (final e in data.items) if (e.isDir) e];
          if (dirs.isEmpty) {
            return AppEmptyState(
              icon: Icons.folder_open,
              title: driveP0(DriveP0TextKeys.folderEmptyTitle, '这个文件夹是空的'),
              message: driveP0(
                DriveP0TextKeys.copyMovePick,
                '没有子文件夹可以进；可以直接用右上角的目标',
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: Gap.xl),
            itemCount: dirs.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: hud.dim.withValues(alpha: 0.12),
            ),
            itemBuilder: (context, i) => DesignRowTile(
              key: Key('drive-copy-move-dir-${dirs[i].fileId}'),
              leading: SizedBox(
                width: 40,
                height: 40,
                child: FileIconTile(
                  entry: driveEntryAsFile(dirs[i]),
                  size: 40,
                  iconSize: 20,
                ),
              ),
              title: Text(dirs[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => setState(
                () => _stack.add((
                  id: dirs[i].fileId,
                  name: dirs[i].name,
                  pathId: dirs[i].pathId,
                )),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirm() async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // 目标是根目录时先取根节点的 file_id（`to_parent_folder` 要 `id:<id>`）
    var folderId = _stack.last.id;
    setState(() => _busy = true);
    try {
      if (folderId.isEmpty) {
        folderId = (await drive.get(path: kDriveRoot)).fileId;
      }
      // 自己不能进自己：把"源里有这个目录"挡在前面（官方 ChooseFolderFragment
      // 也有同样的"别把自己塞进自己"校验；我们不新造服务端行为，纯客户端拦截）
      final ids = {for (final e in widget.entries) e.fileId};
      if (ids.contains(folderId)) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              driveP0(DriveP0TextKeys.copyMoveSameFolder, '不能选择自己作为目标位置'),
            ),
          ),
        );
        return;
      }
      final fileIds = [for (final e in widget.entries) e.fileId];
      // ---- 官方 Web 的 dry_run 冲突探测（见文件头 2.）
      final conflicts = await drive.probeCopyMove(
        fileIds: fileIds,
        toParentFolderId: folderId,
        move: widget.move,
      );
      var action = DriveConflictAction.autorename;
      if (conflicts.isNotEmpty) {
        final chosen = await _askConflict(t, conflicts);
        if (chosen == null) return; // 取消
        action = chosen;
      }
      if (!mounted) return;
      await drive.copyOrMove(
        fileIds: fileIds,
        toParentFolderId: folderId,
        move: widget.move,
        conflictAction: action,
      );
      refreshDriveViews(ref);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveP0Fill(
              DriveP0TextKeys.copyMoveDone,
              '已完成：{count} 项',
              {'count': '${widget.entries.length}'},
            ),
          ),
        ),
      );
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveP0Fill(DriveP0TextKeys.copyMoveFailed, '操作失败：{error}', {
              'error': describeFileError(e),
            }),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 同名冲突：只给官方那三个 `conflict_action`，默认 `autorename`
  Future<String?> _askConflict(
    AppText t,
    List<DriveMoveConflict> conflicts,
  ) => showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('drive-copy-move-conflict'),
      title: Text(
        driveP0(DriveP0TextKeys.copyMoveConflictTitle, '目标位置有同名文件'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            driveP0Fill(
              DriveP0TextKeys.copyMoveConflictBody,
              '{count} 个文件与目标位置重名，请选择处理方式。',
              {'count': '${conflicts.length}'},
            ),
          ),
          const SizedBox(height: Gap.sm),
          for (final c in conflicts.take(5))
            Text(
              c.renamed.isEmpty
                  ? '· ${c.sourceName}'
                  : '· ${c.sourceName} → ${c.renamed}',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('drive-conflict-stop'),
          onPressed: () => Navigator.of(ctx).pop(DriveConflictAction.stop),
          child: Text(driveP0(DriveP0TextKeys.conflictStop, '跳过')),
        ),
        TextButton(
          key: const Key('drive-conflict-overwrite'),
          onPressed: () => Navigator.of(ctx).pop(DriveConflictAction.overwrite),
          child: Text(driveP0(DriveP0TextKeys.conflictOverwrite, '覆盖')),
        ),
        FilledButton(
          key: const Key('drive-conflict-autorename'),
          onPressed: () =>
              Navigator.of(ctx).pop(DriveConflictAction.autorename),
          child: Text(driveP0(DriveP0TextKeys.conflictAutorename, '自动重命名')),
        ),
      ],
    ),
  );
}
