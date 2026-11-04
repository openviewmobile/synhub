// Drive「收藏集 / 收藏夹」页（D8，官方 `DriveCategory.Collection`）。
//
// 协议事实（逐条原文见 `data/dto/drive_collection_dto.dart` 与
// `data/drive_api.dart` 的方法注释）：
//   * 收藏集 = `SYNO.SynologyDrive.Labels` 上 `type` 为
//     `photo_album` / `document_folder` / `audio_playlist` / `video_playlist`
//     的条目（官方 `ApiSynoDriveLabels.setAsListCollection(FileGroup)`）；
//   * 列收藏集：`Labels/list` v2（读，**本批真机验过**，四个类型都回空表成功）；
//   * 建 / 改名 / 删：`Labels/create|update|delete`（**写方法：只写代码，
//     按 §5.1 一次都没调**）；
//   * 加入 / 移出成员：`Files/label` 的动作数组（`action: add|delete`，
//     复用已真机验证的 `DriveApi.setLabels`）；
//   * 收藏集里的文件：`Files/list_labelled` v2（读，标签页同款）。
//
// 危险操作（删收藏集、移出成员）一律二次确认；改名/新建不破坏数据。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_collection_dto.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../files/drive_providers.dart' show driveApiProvider;
import 'drive_collection_providers.dart';
import 'drive_collection_text.dart';

/// 收藏集入口是否可用（`Labels` 能力位）。
///
/// 真机这台 NAS 上 `Labels` 是 `minVersion 1 / maxVersion 3`
/// （`SYNO.API.Info` 只读探针），收藏集需要的 `type` 从 v2 起才有；
/// 老包（只到 v1）下入口仍在，交给服务端行为决定（fail-open，见
/// `drive_collection_providers.dart` 的说明）。
bool driveCollectionsAvailable(WidgetRef ref) => ref
    .watch(serviceAvailabilityProvider)
    .hasApi(StationService.drive, kDriveLabelsApi);

class DriveCollectionPage extends ConsumerStatefulWidget {
  const DriveCollectionPage({super.key});

  @override
  ConsumerState<DriveCollectionPage> createState() =>
      _DriveCollectionPageState();
}

class _DriveCollectionPageState extends ConsumerState<DriveCollectionPage> {
  /// 类型筛选：`null` = 全部类型（逐个类型拉，见 [_loadAll]）
  DriveCollectionType? _type;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final async = ref.watch(driveCollectionsProvider(_type));
    final total = async.value?.length ?? 0;
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-collection-page'),
            children: [
              _Header(
                title: driveCollection(DriveCollectionTextKeys.title, '收藏集'),
                subtitle: total == 0
                    ? driveCollection(
                        DriveCollectionTextKeys.emptyTitle,
                        '还没有收藏集',
                      )
                    : driveCollectionFill(
                        DriveCollectionTextKeys.count,
                        '{count} 个收藏集',
                        {'count': '$total'},
                      ),
                onRefresh: () =>
                    ref.invalidate(driveCollectionsProvider(_type)),
              ),
              _TypeFilter(
                selected: _type,
                onPick: (v) => setState(() => _type = v),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, __) => AppEmptyState(
                    icon: Icons.error_outline,
                    title: driveCollection(
                      DriveCollectionTextKeys.loadFailed,
                      '暂时取不到收藏集',
                    ),
                    message: describeFileError(e),
                    actionLabel: context.t.photoRetry,
                    onAction: () =>
                        ref.invalidate(driveCollectionsProvider(_type)),
                  ),
                  data: (items) => items.isEmpty
                      ? AppEmptyState(
                          icon: Icons.collections_bookmark_outlined,
                          title: driveCollection(
                            DriveCollectionTextKeys.emptyTitle,
                            '还没有收藏集',
                          ),
                          message: driveCollection(
                            DriveCollectionTextKeys.emptyBody,
                            '收藏集能把散在不同目录的文件聚在一起（照片 / 文档 / 音乐 / 视频四类）。',
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: items.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) => _CollectionRow(
                            collection: items[i],
                            onChanged: () => ref.invalidate(
                              driveCollectionsProvider(_type),
                            ),
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    key: const Key('drive-collection-create'),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(
                      driveCollection(
                        DriveCollectionTextKeys.create,
                        '新建收藏集',
                      ),
                    ),
                    onPressed: () => _create(context),
                  ),
                ),
              ),
            ],
          ),
        ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<_CreateDraft>(
      context: context,
      builder: (context) => const _CreateCollectionDialog(),
    );
    if (result == null) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.createCollection(name: result.name, type: result.type);
      ref.invalidate(driveCollectionsProvider(_type));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveCollectionFill(
              DriveCollectionTextKeys.created,
              '已新建「{name}」',
              {'name': result.name},
            ),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveCollectionFill(
              DriveCollectionTextKeys.actionFailed,
              '操作失败：{error}',
              {'error': describeFileError(e)},
            ),
          ),
          // 供测试断言"确实走的是用户语言，不是协议原文"
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}

/// 类型筛选 chips（全部 + 四类）
class _TypeFilter extends StatelessWidget {
  const _TypeFilter({required this.selected, required this.onPick});

  final DriveCollectionType? selected;
  final ValueChanged<DriveCollectionType?> onPick;

  @override
  Widget build(BuildContext context) {
    final items = <(DriveCollectionType?, String)>[
      (null, driveCollection(DriveCollectionTextKeys.all, '全部')),
      for (final t in DriveCollectionType.values)
        (t, driveCollectionTypeLabel(t)),
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        key: const Key('drive-collection-filter'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: Gap.sm),
        itemBuilder: (context, i) {
          final (value, label) = items[i];
          return Center(
            child: ChoiceChip(
              key: Key('drive-collection-chip-${value?.apiValue ?? 'all'}'),
              label: Text(label),
              selected: selected == value,
              onSelected: (_) => onPick(value),
            ),
          );
        },
      ),
    );
  }
}

class _CollectionRow extends ConsumerWidget {
  const _CollectionRow({required this.collection, required this.onChanged});

  final DriveCollectionDto collection;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final type = collection.collectionType;
    final subtitle = [
      if (type != null) driveCollectionTypeLabel(type),
      driveCollectionFill(
        DriveCollectionTextKeys.count,
        '{count} 个收藏集',
        {'count': '${collection.fileCount}'},
      ),
    ].join(' · ');
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: Key('drive-collection-row-${collection.collectionId}'),
        leading: CircleAvatar(
          backgroundColor: Color(collection.colorValue).withValues(alpha: 0.25),
          child: const Icon(Icons.collections_bookmark_outlined, size: 20),
        ),
        title: Text(
          collection.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
        trailing: PopupMenuButton<String>(
          key: Key('drive-collection-menu-${collection.collectionId}'),
          onSelected: (v) => switch (v) {
            'rename' => _rename(context, ref),
            'delete' => _delete(context, ref),
            _ => null,
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'rename',
              child: Text(
                driveCollection(
                  DriveCollectionTextKeys.rename,
                  '重命名 / 改颜色',
                ),
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Text(
                driveCollection(DriveCollectionTextKeys.delete, '删除收藏集'),
              ),
            ),
          ],
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DriveCollectionFilesPage(collection: collection),
          ),
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final draft = await showDialog<_CreateDraft>(
      context: context,
      builder: (context) => _CreateCollectionDialog(
        initialName: collection.name,
        type: collection.collectionType ?? DriveCollectionType.document,
      ),
    );
    if (draft == null) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.updateCollection(
        collectionId: collection.collectionId,
        name: draft.name,
      );
      onChanged();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveCollectionFill(
              DriveCollectionTextKeys.renamed,
              '已改名为「{name}」',
              {'name': draft.name},
            ),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveCollectionFill(
              DriveCollectionTextKeys.actionFailed,
              '操作失败：{error}',
              {'error': describeFileError(e)},
            ),
          ),
        ),
      );
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          driveCollection(
            DriveCollectionTextKeys.deleteConfirm,
            '删除这个收藏集？',
          ),
        ),
        content: Text(
          driveCollectionFill(
            DriveCollectionTextKeys.deleteBody,
            '「{name}」会被删除；里面的文件本身不会被删除。',
            {'name': collection.name},
          ),
        ),
        actions: [
          TextButton(
            key: const Key('drive-collection-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('drive-collection-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              driveCollection(DriveCollectionTextKeys.delete, '删除收藏集'),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.deleteCollection(collection.collectionId);
      onChanged();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveCollection(DriveCollectionTextKeys.deleted, '收藏集已删除'),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveCollectionFill(
              DriveCollectionTextKeys.actionFailed,
              '操作失败：{error}',
              {'error': describeFileError(e)},
            ),
          ),
        ),
      );
    }
  }
}

/// 收藏集里的文件（只读列表 + 移出成员）。
class DriveCollectionFilesPage extends ConsumerWidget {
  const DriveCollectionFilesPage({super.key, required this.collection});

  final DriveCollectionDto collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final async = ref.watch(
      driveCollectionFilesProvider(collection.collectionId),
    );
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-collection-files-page'),
            children: [
              _Header(
                title: collection.name,
                subtitle: collection.collectionType == null
                    ? ''
                    : driveCollectionTypeLabel(collection.collectionType!),
                onRefresh: () => ref.invalidate(
                  driveCollectionFilesProvider(collection.collectionId),
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, __) => AppEmptyState(
                    icon: Icons.error_outline,
                    title: driveCollection(
                      DriveCollectionTextKeys.filesLoadFailed,
                      '暂时取不到收藏集里的文件',
                    ),
                    message: describeFileError(e),
                    actionLabel: context.t.photoRetry,
                    onAction: () => ref.invalidate(
                      driveCollectionFilesProvider(collection.collectionId),
                    ),
                  ),
                  data: (data) => data.items.isEmpty
                      ? AppEmptyState(
                          icon: Icons.folder_open_outlined,
                          title: driveCollection(
                            DriveCollectionTextKeys.filesEmptyTitle,
                            '这个收藏集还是空的',
                          ),
                          message: driveCollection(
                            DriveCollectionTextKeys.filesEmptyBody,
                            '在文件列表里选择「加入收藏集」把文件放进来。',
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: data.items.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) => _CollectionFileRow(
                            entry: data.items[i],
                            collectionId: collection.collectionId,
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

class _CollectionFileRow extends ConsumerWidget {
  const _CollectionFileRow({required this.entry, required this.collectionId});

  final DriveEntryDto entry;
  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final subtitle = [
      if (entry.isDir) '—' else entry.humanSize,
      if (entry.owner.isNotEmpty) entry.owner,
    ].join(' · ');
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: Key('drive-collection-file-${entry.fileId}'),
        leading: Icon(
          entry.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
          size: 20,
          color: hud.dim,
        ),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
        trailing: IconButton(
          key: Key('drive-collection-file-remove-${entry.fileId}'),
          tooltip: driveCollection(
            DriveCollectionTextKeys.removeFromCollection,
            '移出收藏集',
          ),
          icon: const Icon(Icons.playlist_remove, size: 20),
          onPressed: () => _remove(context, ref),
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          driveCollection(
            DriveCollectionTextKeys.removeConfirm,
            '移出这个收藏集？',
          ),
        ),
        content: Text(
          driveCollectionFill(
            DriveCollectionTextKeys.removeBody,
            '「{name}」会从收藏集里移出；文件本身不会被删除。',
            {'name': entry.name},
          ),
        ),
        actions: [
          TextButton(
            key: const Key('drive-collection-remove-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('drive-collection-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              driveCollection(
                DriveCollectionTextKeys.removeFromCollection,
                '移出收藏集',
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      await drive.removeFilesFromCollection(
        fileIds: [entry.fileId],
        collectionId: collectionId,
      );
      ref.invalidate(driveCollectionFilesProvider(collectionId));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveCollection(DriveCollectionTextKeys.removed, '已移出收藏集'),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            driveCollectionFill(
              DriveCollectionTextKeys.actionFailed,
              '操作失败：{error}',
              {'error': describeFileError(e)},
            ),
          ),
        ),
      );
    }
  }
}

class _CreateDraft {
  const _CreateDraft(this.name, this.type);

  final String name;
  final DriveCollectionType type;
}

class _CreateCollectionDialog extends StatefulWidget {
  const _CreateCollectionDialog({this.initialName = '', this.type});

  final String initialName;
  final DriveCollectionType? type;

  @override
  State<_CreateCollectionDialog> createState() =>
      _CreateCollectionDialogState();
}

class _CreateCollectionDialogState extends State<_CreateCollectionDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late DriveCollectionType _type =
      widget.type ?? DriveCollectionType.document;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final isRename = widget.initialName.isNotEmpty;
    return AlertDialog(
      title: Text(
        isRename
            ? driveCollection(DriveCollectionTextKeys.renameTitle, '重命名收藏集')
            : driveCollection(DriveCollectionTextKeys.createTitle, '新建收藏集'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('drive-collection-name-field'),
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              hintText: driveCollection(
                DriveCollectionTextKeys.nameHint,
                '收藏集名字',
              ),
            ),
          ),
          if (!isRename) ...[
            const SizedBox(height: Gap.md),
            Wrap(
              spacing: Gap.sm,
              children: [
                for (final t2 in DriveCollectionType.values)
                  ChoiceChip(
                    key: Key('drive-collection-new-type-${t2.apiValue}'),
                    label: Text(driveCollectionTypeLabel(t2)),
                    selected: _type == t2,
                    onSelected: (_) => setState(() => _type = t2),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('drive-collection-dialog-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          key: const Key('drive-collection-dialog-save'),
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop(_CreateDraft(name, _type));
          },
          child: Text(
            isRename
                ? driveCollection(DriveCollectionTextKeys.rename, '重命名')
                : driveCollection(DriveCollectionTextKeys.create, '新建'),
          ),
        ),
      ],
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
