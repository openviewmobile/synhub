// 笔记本层级 Shelf（F2 / P0-7）。
//
// ⚠️ 审计 U2 的答案（本批取证）：官方 APK 里**没有** `SYNO.NoteStation.Stack`
// 命名空间，Shelf 就是 `SYNO.NoteStation.Notebook / set` **v2** 的 `stack` 字段：
//   * `net/ApiNSNotebook.java`：`VERSION_2_STACK = 2`；
//   * `callables/operations/SetNotebookOperation.java`：`putParam("stack", …)`；
//   * `loaders/GenerateStacksLoader.java`：从本地 `stack` 去重出 Shelf 列表
//     （`stack collate nocase asc`）。
// 因为 `CreateNotebookOperation` **不发** `stack`，"空 Shelf"在服务端不存在 ——
// 只有把笔记本 `set stack` 之后 Shelf 才出现，所以这里不做"先建空 Shelf"。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/note_dto.dart';
import 'note_providers.dart';
import 'note_reminder.dart';
import 'note_widgets.dart';

/// 未归入任何 Shelf 的笔记本在界面上的分组名
const String kNoteNoShelf = '__none__';

/// 把笔记本按 `stack` 分组（`null`/空 → [kNoteNoShelf]）。
/// Shelf 名按 `nocase` 升序、组内按标题 `nocase` 升序（官方 loader 同款）。
Map<String, List<NotebookDto>> groupNotebooksByStack(
  List<NotebookDto> notebooks,
) {
  final map = <String, List<NotebookDto>>{};
  for (final nb in notebooks) {
    final stack = (nb.stack ?? '').trim();
    map.putIfAbsent(stack.isEmpty ? kNoteNoShelf : stack, () => []).add(nb);
  }
  for (final list in map.values) {
    list.sort(
      (a, b) =>
          a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase()),
    );
  }
  return map;
}

/// 现有 Shelf 名（不含"未分组"），按 nocase 升序
List<String> shelfNames(List<NotebookDto> notebooks) {
  final names = <String>{};
  for (final nb in notebooks) {
    final s = (nb.stack ?? '').trim();
    if (s.isNotEmpty) names.add(s);
  }
  final out = names.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return out;
}

/// 把笔记本放进 Shelf（`Notebook/set` v2 的 `stack`）；空 = 移出。
Future<bool> setNotebookShelf(
  BuildContext context,
  WidgetRef ref,
  NotebookDto notebook, {
  required String? stack,
}) async {
  final api = ref.read(noteApiProvider);
  if (api == null) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = context.t;
  try {
    await api.setNotebookStack(notebook.objectId, stack: stack);
    ref.invalidate(notebooksProvider);
    messenger?.showSnackBar(
      SnackBar(content: Text(noteB(NoteBTextKeys.shelfDone, '已更新 Shelf'))),
    );
    return true;
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text(describeNoteError(e, l10n))),
    );
    return false;
  }
}

class NoteShelfPage extends ConsumerWidget {
  const NoteShelfPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final notebooks = ref.watch(notebooksProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(title: Text(noteB(NoteBTextKeys.shelf, 'Shelf 分层'))),
      body: notebooks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, __) => AppErrorView(
          title: noteB(NoteBTextKeys.shelf, 'Shelf 分层'),
          detail: describeNoteError(e, context.t),
          onRetry: () => ref.invalidate(notebooksProvider),
        ),
        data: (all) {
          if (all.isEmpty) {
            return Center(
              child: Text(
                noteB(NoteBTextKeys.shelfEmpty, '还没有笔记本'),
                style: TextStyle(color: hud.dim),
              ),
            );
          }
          final groups = groupNotebooksByStack(all);
          final keys = groups.keys.toList()
            ..sort((a, b) {
              // "未分组"永远在最后
              if (a == kNoteNoShelf) return 1;
              if (b == kNoteNoShelf) return -1;
              return a.toLowerCase().compareTo(b.toLowerCase());
            });
          return ListView(
            children: [
              for (final key in keys)
                ExpansionTile(
                  key: Key('note-shelf-$key'),
                  initiallyExpanded: true,
                  title: Text(
                    key == kNoteNoShelf
                        ? noteB(NoteBTextKeys.shelf, '笔记本')
                        : key,
                  ),
                  subtitle: Text(
                    '${groups[key]!.length}',
                    style: TextStyle(color: hud.dim),
                  ),
                  children: [
                    for (final nb in groups[key]!)
                      DesignRowTile(
                        key: Key('note-shelf-nb-${nb.objectId}'),
                        dense: true,
                        title: Text(nb.displayTitle),
                        trailing: key == kNoteNoShelf
                            ? null
                            : IconButton(
                                key: Key('note-shelf-remove-${nb.objectId}'),
                                tooltip: noteB(
                                  NoteBTextKeys.shelfRemove,
                                  '移出 Shelf',
                                ),
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () => setNotebookShelf(
                                  context,
                                  ref,
                                  nb,
                                  stack: null,
                                ),
                              ),
                        onTap: () {
                          ref
                              .read(selectedNotebookProvider.notifier)
                              .select(nb.objectId);
                          Navigator.of(context).pop();
                        },
                        onLongPress: () =>
                            _moveToShelf(context, ref, nb, all),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('note-shelf-add'),
        onPressed: () => _pickNotebook(context, ref),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: Text(noteB(NoteBTextKeys.shelfAdd, '加入 Shelf')),
      ),
    );
  }

  Future<void> _pickNotebook(BuildContext context, WidgetRef ref) async {
    final all = ref.read(notebooksProvider).value ?? const <NotebookDto>[];
    final nb = await showModalBottomSheet<NotebookDto>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final n in all)
              DesignRowTile(
                title: Text(n.displayTitle),
                subtitle: (n.stack ?? '').isEmpty ? null : Text(n.stack!),
                onTap: () => Navigator.of(context).pop(n),
              ),
          ],
        ),
      ),
    );
    if (nb == null || !context.mounted) return;
    await _moveToShelf(context, ref, nb, all);
  }

  Future<void> _moveToShelf(
    BuildContext context,
    WidgetRef ref,
    NotebookDto notebook,
    List<NotebookDto> all,
  ) async {
    final existing = shelfNames(all);
    final ctrl = TextEditingController(text: notebook.stack ?? '');
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(noteB(NoteBTextKeys.shelfAdd, '加入 Shelf')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('note-shelf-name'),
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: noteB(NoteBTextKeys.shelfName, 'Shelf 名称'),
              ),
            ),
            if (existing.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Wrap(
                  spacing: Gap.xs,
                  children: [
                    for (final name in existing)
                      ActionChip(
                        key: Key('note-shelf-existing-$name'),
                        label: Text(name),
                        onPressed: () => Navigator.of(context).pop(name),
                      ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('note-shelf-save'),
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: Text(context.t.actionSave),
          ),
        ],
      ),
    );
    // 退场动画期间 TextField 还在树上，不能立刻 dispose（见 note_smart_page 同款说明）
    if (picked == null || !context.mounted) return;
    await setNotebookShelf(
      context,
      ref,
      notebook,
      stack: picked.isEmpty ? null : picked,
    );
  }
}
