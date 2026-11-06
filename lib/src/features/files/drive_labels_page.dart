// Drive 标签页（P3）：标签管理 + 标签下的文件 + 给文件打标签。
//
// 官方对照与真机形状（`tool/drive_p3_probe.dart` / `drive_p3_shape2.dart`，
// 2026-09-19）：
//   * `Labels/list` v1：`type` 是 `personal_label`（不是 `label`）；
//   * `Labels/create|update|delete`：名字/id/颜色都要 **Gson 引号串**；
//   * `Files/label` v2 是**动作数组**：`[{"action":"add"|"delete","label_id":<int>}]`；
//   * `Files/list_labelled` v2：`label_id` 引号串 → 该标签下的文件。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/viewport_bound.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/drive_label_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import 'drive_providers.dart';
import 'file_row.dart' show formatFileTime;

/// 标签管理页（从「文件 → 我的 Drive → 更多 → 标签」进）
class DriveLabelsPage extends ConsumerStatefulWidget {
  const DriveLabelsPage({super.key});

  @override
  ConsumerState<DriveLabelsPage> createState() => _DriveLabelsPageState();
}

class _DriveLabelsPageState extends ConsumerState<DriveLabelsPage> {
  bool _busy = false;

  Future<void> _create() async {
    final t = context.t;
    final name = await _askName(context, title: t.noteNewTagHint);
    if (name == null || name.isEmpty) return;
    await _run(
      () => ref.read(driveApiProvider)!.createLabel(name),
      done: t.driveLabelCreated(name),
    );
  }

  Future<void> _rename(DriveLabelDto label) async {
    final t = context.t;
    final name = await _askName(
      context,
      title: t.noteRenameTag,
      initial: label.name,
    );
    if (name == null || name.isEmpty || name == label.name) return;
    await _run(
      () => ref
          .read(driveApiProvider)!
          .updateLabel(labelId: label.labelId, name: name),
      done: t.driveLabelRenamed(name),
    );
  }

  Future<void> _recolor(DriveLabelDto label) async {
    final t = context.t;
    const palette = [
      '#ff3b30',
      '#ff9500',
      '#ffcc00',
      '#34c759',
      '#00c7be',
      '#007aff',
      '#5856d6',
      '#af52de',
      '#8e8e93',
    ];
    final color = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ColorSheet(current: label.color, palette: palette),
    );
    if (color == null || color == label.color) return;
    await _run(
      () => ref
          .read(driveApiProvider)!
          .updateLabel(labelId: label.labelId, color: color),
      done: t.driveLabelColorUpdated,
    );
  }

  Future<void> _delete(DriveLabelDto label) async {
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.driveDeleteLabelConfirm),
        content: Text(t.driveDeleteLabelBody(label.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(
      () => ref.read(driveApiProvider)!.deleteLabel(label.labelId),
      done: t.driveLabelDeleted(label.name),
    );
  }

  Future<void> _run(
    Future<Object?> Function() action, {
    required String done,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(driveLabelsProvider);
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final labels = ref.watch(driveLabelsProvider);
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
                            t.noteTags,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            t.driveLabelsHud,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: hud.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: t.noteNewTagHint,
                      icon: const Icon(Icons.add),
                      onPressed: _busy ? null : _create,
                    ),
                  ],
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: labels.when(
                  loading: () => const AppListSkeleton(),
                  error: (e, _) => AppErrorView(
                    title: t.driveLabelsLoadFailed,
                    detail: describeFileError(e),
                    onRetry: () => ref.invalidate(driveLabelsProvider),
                  ),
                  data: (list) => list.isEmpty
                      ? AppEmptyState(
                          icon: Icons.sell_outlined,
                          title: t.noteNoTagsYet,
                          message: t.driveNoLabelsManageMessage,
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: list.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) {
                            final l = list[i];
                            return Material(
                              type: MaterialType.transparency,
                              child: DesignRowTile(
                                leading: Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: Color(l.colorValue),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                title: Text(
                                  l.name,
                                  style: theme.textTheme.bodyMedium,
                                ),
                                subtitle: Text(
                                  l.isShared
                                      ? t.driveSharedLabel
                                      : t.drivePersonalLabel,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: hud.dim,
                                  ),
                                ),
                                onTap: () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    builder: (_) => DriveLabelledPage(label: l),
                                  ),
                                ),
                                trailing: PopupMenuButton<String>(
                                  tooltip: t.photoMore,
                                  onSelected: (v) {
                                    switch (v) {
                                      case 'rename':
                                        _rename(l);
                                      case 'color':
                                        _recolor(l);
                                      case 'delete':
                                        _delete(l);
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      value: 'rename',
                                      child: Text(t.photoRename),
                                    ),
                                    PopupMenuItem(
                                      value: 'color',
                                      child: Text(t.driveChangeColor),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text(t.dtoActionDelete),
                                    ),
                                  ],
                                ),
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

/// 某个标签下的文件（`Files/list_labelled`）
class DriveLabelledPage extends ConsumerWidget {
  const DriveLabelledPage({super.key, required this.label});

  final DriveLabelDto label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final files = ref.watch(driveLabelledProvider(label.labelId));
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
                    Container(
                      width: 14,
                      height: 14,
                      margin: const EdgeInsets.only(right: Gap.sm),
                      decoration: BoxDecoration(
                        color: Color(label.colorValue),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label.name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            t.driveLabelsHudFiles,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: hud.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: t.photoRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () =>
                          ref.invalidate(driveLabelledProvider(label.labelId)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: files.when(
                  loading: () => const AppListSkeleton(),
                  error: (e, _) => AppErrorView(
                    title: t.driveLabelOpenFailed,
                    detail: describeFileError(e),
                    onRetry: () =>
                        ref.invalidate(driveLabelledProvider(label.labelId)),
                  ),
                  data: (data) => data.items.isEmpty
                      ? AppEmptyState(
                          icon: Icons.folder_open,
                          title: t.driveLabelNoFiles,
                          message: t.driveLabelNoFilesMessage,
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: data.items.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) {
                            final e = data.items[i];
                            return Material(
                              type: MaterialType.transparency,
                              child: DesignRowTile(
                                leading: Icon(
                                  e.isDir
                                      ? Icons.folder_outlined
                                      : Icons.insert_drive_file_outlined,
                                  color: hud.dim,
                                ),
                                title: Text(
                                  e.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium,
                                ),
                                subtitle: Text(
                                  [
                                    if (e.isDir) t.photoFolder else e.humanSize,
                                    if (e.modifiedTime > 0)
                                      formatFileTime(e.modifiedTime, t: t),
                                  ].join(' · '),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: hud.dim,
                                  ),
                                ),
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

/// 给一个文件挑标签（多选）。返回是否改动过。
///
/// 入口在 Drive 文件行的「⋮ → 标签」。当前已打的标签直接用列表项里的
/// `labels`（`Files/list` 回的就是标签对象），不用再加一次请求。
Future<bool> showDriveLabelPicker(
  BuildContext context,
  WidgetRef ref,
  DriveEntryDto entry,
) async {
  final drive = ref.read(driveApiProvider);
  if (drive == null) return false;
  final t = context.t;
  final picked = await showModalBottomSheet<List<DriveLabelChange>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _LabelPickerSheet(entry: entry),
  );
  if (picked == null || picked.isEmpty || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await drive.setLabels(fileIds: [entry.fileId], changes: picked);
    messenger.showSnackBar(SnackBar(content: Text(t.driveLabelsUpdated)));
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(describeFileError(e))));
    return false;
  }
}

class _LabelPickerSheet extends ConsumerStatefulWidget {
  const _LabelPickerSheet({required this.entry});

  final DriveEntryDto entry;

  @override
  ConsumerState<_LabelPickerSheet> createState() => _LabelPickerSheetState();
}

class _LabelPickerSheetState extends ConsumerState<_LabelPickerSheet> {
  late final Set<String> _on = {for (final l in widget.entry.labels) l.labelId};

  /// 新建标签并直接勾上。
  ///
  /// ⚠️ 真机踩过：这个弹层里**内嵌**一个 `TextField` 是点不聚焦的（软键盘不弹、
  /// `input text` 也进不去），所以改成和"标签管理页"同一个对话框（`autofocus`），
  /// 两个入口的创建体验也就一致了。
  Future<void> _createAndToggle() async {
    final t = context.t;
    final name = await _askName(context, title: t.noteNewTagHint);
    if (name == null || name.isEmpty || !mounted) return;
    final drive = ref.read(driveApiProvider);
    if (drive == null) return;
    try {
      final created = await drive.createLabel(name);
      ref.invalidate(driveLabelsProvider);
      if (mounted) setState(() => _on.add(created.labelId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(describeFileError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final labels = ref.watch(driveLabelsProvider);
    return SafeArea(
      child: Material(
        color: hud.surface2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: hud.line, width: 1),
        ),
        child: Container(
          // 有界高度（见 `drive_share_page.dart` 同一条经验）
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
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.driveLabelPickerTitle(widget.entry.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        final changes = <DriveLabelChange>[
                          for (final l in widget.entry.labels)
                            if (!_on.contains(l.labelId))
                              DriveLabelChange.remove(l.labelId),
                          for (final id in _on)
                            if (!widget.entry.labels.any(
                              (l) => l.labelId == id,
                            ))
                              DriveLabelChange.add(id),
                        ];
                        Navigator.of(context).pop(changes);
                      },
                      child: Text(t.actionSave),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: labels.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(Gap.lg),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Text(
                      t.driveLabelPickerReadFailed(describeFileError(e)),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: hud.dim),
                    ),
                  ),
                  data: (list) => ListView(
                    shrinkWrap: true,
                    children: [
                      for (final l in list)
                        DesignCheckRow(
                          value: _on.contains(l.labelId),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _on.add(l.labelId);
                            } else {
                              _on.remove(l.labelId);
                            }
                          }),
                          secondary: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: Color(l.colorValue),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          title: Text(l.name),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Gap.md,
                          Gap.sm,
                          Gap.md,
                          Gap.md,
                        ),
                        child: TextButton.icon(
                          onPressed: _createAndToggle,
                          icon: const Icon(Icons.add),
                          label: Text(t.driveCreateLabelAndCheck),
                        ),
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

class _ColorSheet extends StatelessWidget {
  const _ColorSheet({required this.current, required this.palette});

  final String current;
  final List<String> palette;

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
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Text(
                context.t.driveChooseColor,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Wrap(
                spacing: Gap.md,
                runSpacing: Gap.md,
                children: [
                  for (final c in palette)
                    InkWell(
                      onTap: () => Navigator.of(context).pop(c),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Color(
                            DriveLabelDto.fromJson({'color': c}).colorValue,
                          ),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c == current
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Gap.lg),
          ],
        ),
      ),
    );
  }
}

Future<String?> _askName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  final t = context.t;
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 32,
        decoration: InputDecoration(hintText: t.noteTagNameHint),
        onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: Text(t.actionOk),
        ),
      ],
    ),
  );
}
