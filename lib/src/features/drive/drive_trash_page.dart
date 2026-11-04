// Drive 回收站页（C1）：列表（名称 / 原路径 / 删除时间 / 大小）+ 恢复 +
// 永久删除 + 清空 + 容量。
//
// 协议事实（逐条原文见 [DriveApi] 与 docs/workspace-expansion-evaluation.md
// 实施记录「C1 · Drive」）：
//   * 列表 `Trash/list` v1，参数 `path` + `offset`/`limit` + `sort_by`
//     （官方默认 `recycled_time DESC`）；条目字段里有 `recycled_time` /
//     `display_path`（官方 `ViewStore.Recycle` 的列定义）；
//   * 容量 `Trash/get_size` v2，参数 `{path}`（本仓库真机验证）；
//   * 清空 `Trash/empty` v1，参数 `{path}`；
//   * **恢复**走 `Revisions/restore` v1（官方把回收站"恢复"接到这里），
//     参数 `files` + `conflict_action`（可选 `to_parent_folder`）；
//   * **永久删除**（本页只对本页列出的**回收站条目**做）走 `Files/delete` v2 +
//     **`permanent:true`**，参数用 `Trash/list` 回的条目 `file_id`。真机 A/B
//     （`docs/live-write-verification.md` §7）：`permanent:true` **只对回收站
//     条目有效**（从回收站永久消失）；`permanent_delete:true` 服务端**根本不
//     识别**（等同普通删除，会把条目录回回收站）；对**活动文件**发
//     `permanent:true` 则是**静默 no-op**（既不删也不进回收站）。
//     ⇒ 所以"彻底删除"是**两步**：先在文件列表里普通删除（进回收站，文案已写
//     "会进 Drive 回收站，之后还能恢复"），再到本页对**回收站条目 id** 发
//     `permanent:true`。本页的"永久删除"文案与这个真实行为一致。
//
// 危险操作（永久删除、清空）一律二次确认；恢复不破坏数据、不弹确认
// （与官方右键菜单一致：官方只对删除/清空确认）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../../data/drive_api.dart';
import '../files/drive_providers.dart';
import '../files/file_row.dart' show formatFileTime;
import 'drive_c1_text.dart';

/// 回收站入口是否可用（`Trash` 能力位）
bool driveTrashAvailable(WidgetRef ref) => ref
    .watch(serviceAvailabilityProvider)
    .hasApi(StationService.drive, kDriveTrashApi);

class DriveTrashPage extends ConsumerWidget {
  const DriveTrashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveTrashProvider(kDriveRoot));
    final size = ref.watch(driveTrashSizeProvider(kDriveRoot)).value ?? 0;
    final total = async.value?.total ?? 0;
    final header = total == 0
        ? t.driveTrashEmpty
        : '${t.driveTrashCount(total)}'
              '${size > 0 ? ' · ${t.driveTrashUsage(_bytes(size))}' : ''}';
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-trash-page'),
            children: [
              _Header(
                title: t.noteRecycle,
                subtitle: header,
                onRefresh: () {
                  ref.invalidate(driveTrashProvider(kDriveRoot));
                  ref.invalidate(driveTrashSizeProvider(kDriveRoot));
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('drive-trash-empty'),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: Text(
                      t.noteRecycleCleanTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () => _confirmEmpty(context, ref),
                  ),
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, __) => AppEmptyState(
                    icon: Icons.error_outline,
                    title: t.noteOpenRecycleFailed,
                    message: describeFileError(e),
                    actionLabel: t.photoRetry,
                    onAction: () =>
                        ref.invalidate(driveTrashProvider(kDriveRoot)),
                  ),
                  data: (data) => data.items.isEmpty
                      ? AppEmptyState(
                          icon: Icons.delete_outline,
                          title: t.driveTrashEmpty,
                          message: t.driveTrashEmptyMessage,
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: data.items.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) =>
                              _TrashRow(entry: data.items[i]),
                        ),
                ),
              ),
            ],
          ),
        ),
    );
  }

  Future<void> _confirmEmpty(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.driveEmptyTrashConfirm),
        content: Text(t.driveEmptyTrashBody),
        actions: [
          TextButton(
            key: const Key('drive-trash-empty-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('drive-trash-empty-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.driveEmptyTrashAction),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.emptyTrash(path: kDriveRoot);
      ref.invalidate(driveTrashProvider(kDriveRoot));
      ref.invalidate(driveTrashSizeProvider(kDriveRoot));
      messenger.showSnackBar(SnackBar(content: Text(t.driveTrashEmptied)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.driveEmptyTrashFailed(describeFileError(e)))),
      );
    }
  }

  static String _bytes(int b) {
    if (b < 1024) return '$b B';
    const u = ['KB', 'MB', 'GB', 'TB'];
    var v = b / 1024;
    var i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${u[i]}';
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

class _TrashRow extends ConsumerWidget {
  const _TrashRow({required this.entry});

  final DriveEntryDto entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final theme = Theme.of(context);
    // 名称 / 原路径 / 删除时间 / 大小 —— 四样都要（原路径与删除时间来自
    // `display_path` / `recycled_time`，见 DriveEntryDto 注释）。
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
        key: Key('drive-trash-row-${entry.fileId}'),
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
              key: Key('drive-trash-restore-${entry.fileId}'),
              tooltip: t.driveRestore,
              icon: const Icon(Icons.restore, size: 20),
              onPressed: () => _restore(context, ref),
            ),
            IconButton(
              key: Key('drive-trash-delete-forever-${entry.fileId}'),
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
      await drive.restoreTrash(fileIds: [entry.fileId]);
      ref.invalidate(driveTrashProvider(kDriveRoot));
      ref.invalidate(driveTrashSizeProvider(kDriveRoot));
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
    // 危险操作：二次确认（取消 = 什么都不做）
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
            key: const Key('drive-trash-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('drive-trash-delete-confirm'),
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
      // 本页条目已经躺在回收站里：用它的 `file_id` 发 `permanent:true` 才是
      // 真机能把它从回收站清掉的形态（`permanent_delete` 服务端不认）。
      await drive.deleteFromTrash(trashFileIds: [entry.fileId]);
      ref.invalidate(driveTrashProvider(kDriveRoot));
      ref.invalidate(driveTrashSizeProvider(kDriveRoot));
      messenger.showSnackBar(
        SnackBar(content: Text(t.driveDeletedItem(entry.name))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveC1Fill(DriveC1TextKeys.deleteForeverFailed, '永久删除失败：{error}', {
              'error': describeFileError(e),
            }),
          ),
        ),
      );
    }
  }
}
