// Drive「团队文件夹回收站」页（D12，官方 `DriveCategory.TeamFolderInRecycleBin`）。
//
// 协议事实（逐条原文见 `data/drive_api.dart` 的 `listFolderTrash`）：
//   * 团队文件夹回收站 = `Trash/list`（**读**），`path` 是
//     `UtilsForApi.computePathById(teamFolderId)` = `id:<team_folder_id>`
//     （官方 `ApiSynoDriveTrash.setAsList` 的 `isForFolder()` 分支）；
//   * 真机只读实测（本批）：
//     `Trash/list v2 {"path":"id:974457808523148038"}` → success（该目录误删项）；
//     `Trash/list v2 {"path":""}` → **1000 "list node failed"**（官方
//     `generateInstanceForTeamFolder(isRemoved=true)` 那条 path="" 分支在本机不可用，
//     ⇒ 本页**只做有 id 的那条**，空的 path 登记为待确认）。
//
// ⚠️ **写操作（还原 / 彻底删除）本批一次都没真调**（§5.1）：只实现代码 + 离线用例，
// 真机上只验"列表"这一只读部分。
// ⚠️ **没有"清空"按钮**：官方 `generateInstanceForEmptyRecycleBin` 对
// `isForTeamFolders()` **直接返回 null**（`DataSource.java:575-583`）
// ⇒ 官方没有团队文件夹级的"清空回收站"，我们也不加。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../files/drive_providers.dart'
    show driveApiProvider, driveTeamProvider;
import '../files/file_row.dart' show formatFileTime;
import 'drive_c1_text.dart';
import 'drive_recycle_providers.dart';
import 'drive_recycle_text.dart';

/// 团队文件夹回收站入口页：先列团队文件夹，点一个进去看它的回收站。
class DriveTeamTrashPage extends ConsumerWidget {
  const DriveTeamTrashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final async = ref.watch(driveTeamProvider('team'));
    final total = async.value?.total ?? 0;
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-team-trash-page'),
            children: [
              _Header(
                title: driveRecycle(
                  DriveRecycleTextKeys.title,
                  '团队文件夹回收站',
                ),
                subtitle: total == 0
                    ? driveRecycle(
                        DriveRecycleTextKeys.noTeamFolders,
                        '没有团队文件夹',
                      )
                    : driveRecycleFill(
                        DriveRecycleTextKeys.count,
                        '{count} 个团队文件夹',
                        {'count': '$total'},
                      ),
                onRefresh: () => ref.invalidate(driveTeamProvider('team')),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    driveRecycle(
                      DriveRecycleTextKeys.pickFolder,
                      '选一个团队文件夹，查看并还原里面误删的文件',
                    ),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: hud.dim),
                  ),
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, __) => AppEmptyState(
                    icon: Icons.error_outline,
                    title: driveRecycle(
                      DriveRecycleTextKeys.loadFailed,
                      '暂时取不到团队文件夹',
                    ),
                    message: describeFileError(e),
                    actionLabel: context.t.photoRetry,
                    onAction: () => ref.invalidate(driveTeamProvider('team')),
                  ),
                  data: (data) => data.items.isEmpty
                      ? AppEmptyState(
                          icon: Icons.groups_outlined,
                          title: driveRecycle(
                            DriveRecycleTextKeys.noTeamFolders,
                            '没有团队文件夹',
                          ),
                          message: driveRecycle(
                            DriveRecycleTextKeys.noTeamFoldersBody,
                            '这个账号还没有可用的团队文件夹，所以没有团队文件夹回收站可看。',
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: data.items.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) =>
                              _TeamFolderRow(entry: data.items[i]),
                        ),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _TeamFolderRow extends StatelessWidget {
  const _TeamFolderRow({required this.entry});

  final DriveEntryDto entry;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: Key('drive-team-trash-folder-${entry.fileId}'),
        leading: Icon(Icons.folder_shared_outlined, size: 20, color: hud.dim),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: entry.owner.isEmpty
            ? null
            : Text(
                entry.owner,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: hud.dim),
              ),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DriveFolderTrashPage(
              folderId: entry.fileId,
              folderName: entry.name,
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个团队文件夹的回收站：列表 + 还原 + 彻底删除（写操作只写代码，不真调）。
class DriveFolderTrashPage extends ConsumerWidget {
  const DriveFolderTrashPage({
    super.key,
    required this.folderId,
    required this.folderName,
  });

  final String folderId;
  final String folderName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final async = ref.watch(driveFolderTrashProvider(folderId));
    final total = async.value?.total ?? 0;
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-folder-trash-page'),
            children: [
              _Header(
                title: folderName,
                subtitle: total == 0
                    ? driveRecycle(
                        DriveRecycleTextKeys.emptyTitle,
                        '回收站是空的',
                      )
                    : driveRecycleFill(
                        DriveRecycleTextKeys.itemCount,
                        '{count} 个已删除项',
                        {'count': '$total'},
                      ),
                onRefresh: () =>
                    ref.invalidate(driveFolderTrashProvider(folderId)),
              ),
              // 官方对团队文件夹没有"清空回收站"（`generateInstanceForEmptyRecycleBin`
              // 在 `isForTeamFolders()` 时返回 null）⇒ 这里明说，不放按钮。
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    driveRecycle(
                      DriveRecycleTextKeys.noEmptyAction,
                      '团队文件夹回收站不支持"清空"（与官方一致）；可以逐条还原或彻底删除。',
                    ),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: hud.dim),
                  ),
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, __) => AppEmptyState(
                    icon: Icons.error_outline,
                    title: driveRecycle(
                      DriveRecycleTextKeys.loadFailed,
                      '暂时取不到团队文件夹',
                    ),
                    message: describeFileError(e),
                    actionLabel: context.t.photoRetry,
                    onAction: () =>
                        ref.invalidate(driveFolderTrashProvider(folderId)),
                  ),
                  data: (data) => data.items.isEmpty
                      ? AppEmptyState(
                          icon: Icons.delete_outline,
                          title: driveRecycle(
                            DriveRecycleTextKeys.emptyTitle,
                            '回收站是空的',
                          ),
                          message: driveRecycle(
                            DriveRecycleTextKeys.emptyBody,
                            '这个团队文件夹里没有被删除的文件。',
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: data.items.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) => _FolderTrashRow(
                            entry: data.items[i],
                            folderId: folderId,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _FolderTrashRow extends ConsumerWidget {
  const _FolderTrashRow({required this.entry, required this.folderId});

  final DriveEntryDto entry;
  final String folderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final theme = Theme.of(context);
    final subtitle = [
      if (entry.displayPath.isNotEmpty)
        '${driveC1(DriveC1TextKeys.originalPath, '原位置')}: ${entry.displayPath}',
      if (entry.recycledTime > 0)
        '${driveC1(DriveC1TextKeys.deletedAt, '删除于')}: '
            '${formatFileTime(entry.recycledTime, t: t)}',
      if (!entry.isDir) entry.humanSize,
      if (entry.owner.isNotEmpty) entry.owner,
    ].join(' · ');
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: Key('drive-folder-trash-row-${entry.fileId}'),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: Key('drive-folder-trash-restore-${entry.fileId}'),
              tooltip: t.driveRestore,
              icon: const Icon(Icons.restore, size: 20),
              onPressed: () => _restore(context, ref),
            ),
            IconButton(
              key: Key('drive-folder-trash-delete-forever-${entry.fileId}'),
              tooltip: driveC1(DriveC1TextKeys.deleteForever, '永久删除'),
              icon: Icon(Icons.delete_forever, size: 20, color: hud.dim),
              onPressed: () => _deleteForever(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      // 写方法：与个人回收站同一条 `Revisions/restore`（官方把回收站"恢复"
      // 接到这里）。本批不真调，只由离线用例断言参数形状。
      await drive.restoreTrash(fileIds: [entry.fileId]);
      ref.invalidate(driveFolderTrashProvider(folderId));
      messenger.showSnackBar(
        SnackBar(content: Text(driveC1(DriveC1TextKeys.restored, '已恢复'))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveC1Fill(DriveC1TextKeys.restoreOneFailed, '恢复失败：{error}', {
              'error': describeFileError(e),
            }),
          ),
        ),
      );
    }
  }

  Future<void> _deleteForever(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(driveC1(DriveC1TextKeys.deleteForeverConfirm, '永久删除？')),
        content: Text(
          driveC1Fill(
            DriveC1TextKeys.deleteForeverBody,
            '「{name}」会被彻底删除，无法恢复。',
            {'name': entry.name},
          ),
        ),
        actions: [
          TextButton(
            key: const Key('drive-folder-trash-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('drive-folder-trash-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(driveC1(DriveC1TextKeys.deleteForever, '永久删除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.deleteFromTrash(trashFileIds: [entry.fileId]);
      ref.invalidate(driveFolderTrashProvider(folderId));
      messenger.showSnackBar(
        SnackBar(content: Text(t.driveDeletedItem(entry.name))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveC1Fill(
              DriveC1TextKeys.deleteForeverFailed,
              '永久删除失败：{error}',
              {'error': describeFileError(e)},
            ),
          ),
        ),
      );
    }
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
    final t = context.t;
    return Padding(
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
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                Text(
                  subtitle,
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
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}
