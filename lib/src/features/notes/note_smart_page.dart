// 智能 / 条件笔记本（F6 / P0-6）。
//
// 官方条件集（[E1] `res/layout/fragment_dialog_smart_notebook.xml` +
// [E2] `vos/api/SmartVo.java` 的 `QueryVo`）：keyword / note_title /
// date from-to（mtime）/ tag（+ `tag_and_operator` = and|or）/ notebook。
// 服务端 API：`SYNO.NoteStation.Smart` **v1** 的 create/list/set/delete/get
// （`net/ApiNSSmart.java`），`create` 收 `title` + `query` + `commit_msg`
// （`callables/operations/CreateSmartOperation.java`）。
//
// 未取证的字段**一律不做**：`SmartVo` 里没有"按 ctime 筛"的官方 UI 证据时
// 我们只把 ctime 当本地匹配的隐藏能力留着，界面只暴露官方有的那几项。
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
import 'note_view_page.dart';
import 'note_widgets.dart';

class NoteSmartPage extends ConsumerWidget {
  const NoteSmartPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final smarts = ref.watch(smartNotebooksProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(noteB(NoteBTextKeys.smart, '智能笔记本')),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('note-smart-new'),
        onPressed: () => showNoteSmartEditor(context, ref, null),
        icon: const Icon(Icons.add),
        label: Text(noteB(NoteBTextKeys.smartNew, '新建智能笔记本')),
      ),
      body: smarts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppErrorView(
          title: noteB(NoteBTextKeys.smart, '智能笔记本'),
          detail: describeNoteError(e, context.t),
          onRetry: () => ref.invalidate(smartNotebooksProvider),
        ),
        data: (rows) => rows.isEmpty
            ? Center(
                child: Text(
                  noteB(NoteBTextKeys.smartEmpty, '还没有智能笔记本'),
                  style: TextStyle(color: hud.dim),
                ),
              )
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: hud.line),
                itemBuilder: (context, i) {
                  final smart = rows[i];
                  return DesignRowTile(
                    key: Key('note-smart-${smart.objectId}'),
                    leading: Icon(Icons.filter_alt_outlined, color: hud.dim),
                    title: Text(smart.displayTitle),
                    subtitle: Text(
                      smart.query.isEmpty
                          ? noteB(
                              NoteBTextKeys.smartNoConditions,
                              '没有筛选条件',
                            )
                          : smart.query.describe(),
                      style: TextStyle(color: hud.dim),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(context, rootNavigator: true)
                        .push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                NoteSmartNotesPage(smart: smart),
                          ),
                        ),
                    onLongPress: () =>
                        showNoteSmartEditor(context, ref, smart),
                  );
                },
              ),
      ),
    );
  }
}

/// 一个智能笔记本命中的笔记列表
class NoteSmartNotesPage extends ConsumerWidget {
  const NoteSmartNotesPage({super.key, required this.smart});

  final SmartNotebookDto smart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final notes = ref.watch(smartNotesProvider(smart.query));
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(title: Text(smart.displayTitle)),
      body: notes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppErrorView(
          title: smart.displayTitle,
          detail: describeNoteError(e, context.t),
          onRetry: () => ref.invalidate(smartNotesProvider(smart.query)),
        ),
        data: (rows) => rows.isEmpty
            ? Center(
                child: Text(
                  noteB(NoteBTextKeys.smartEmpty, '还没有智能笔记本'),
                  style: TextStyle(color: hud.dim),
                ),
              )
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: hud.line),
                itemBuilder: (context, i) {
                  final note = rows[i];
                  return NoteRow(
                    note: note,
                    onTap: () => Navigator.of(context, rootNavigator: true)
                        .push(
                          MaterialPageRoute<void>(
                            builder: (_) => NoteViewPage(note: note),
                          ),
                        ),
                  );
                },
              ),
      ),
    );
  }
}

/// 新建 / 编辑对话框（`Smart/create` / `Smart/set`）
Future<void> showNoteSmartEditor(
  BuildContext context,
  WidgetRef ref,
  SmartNotebookDto? existing,
) async {
  final api = ref.read(noteApiProvider);
  if (api == null) return;
  final notebooks = ref.read(notebooksProvider).value ?? const <NotebookDto>[];
  final nameCtrl = TextEditingController(text: existing?.title ?? '');
  final keywordCtrl = TextEditingController(
    text: existing?.query.keyword ?? '',
  );
  final titleCtrl = TextEditingController(text: existing?.query.title ?? '');
  final tagCtrl = TextEditingController(
    text: existing?.query.tags.join(', ') ?? '',
  );
  var parentIds = {...?existing?.query.parentIds};
  var tagAnd = existing?.query.tagAndOperator ?? false;
  var mtimeStart = existing?.query.mtimeStart;
  var mtimeEnd = existing?.query.mtimeEnd;
  var saving = false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        Future<void> save() async {
          if (nameCtrl.text.trim().isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  noteB(NoteBTextKeys.smartNameRequired, '请填写名称'),
                ),
              ),
            );
            return;
          }
          setDialogState(() => saving = true);
          final query = NoteSmartQuery(
            parentIds: parentIds.toList(),
            tags: tagCtrl.text
                .split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList(),
            title: _nullIfEmpty(titleCtrl.text),
            keyword: _nullIfEmpty(keywordCtrl.text),
            mtimeStart: mtimeStart,
            mtimeEnd: mtimeEnd,
            tagAndOperator: tagAnd,
          );
          final messenger = ScaffoldMessenger.of(context);
          final navigator = Navigator.of(context);
          final l10n = context.t;
          try {
            if (existing == null) {
              await api.createSmartNotebook(
                title: nameCtrl.text.trim(),
                query: query,
              );
            } else {
              await api.updateSmartNotebook(
                objectId: existing.objectId,
                title: nameCtrl.text.trim(),
                query: query,
              );
            }
            ref.invalidate(smartNotebooksProvider);
            navigator.pop();
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  noteB(NoteBTextKeys.smartSaved, '智能笔记本已保存'),
                ),
              ),
            );
          } catch (e) {
            setDialogState(() => saving = false);
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  noteBFill(
                    NoteBTextKeys.smartFailed,
                    '保存失败：{error}',
                    {'error': describeNoteError(e, l10n)},
                  ),
                ),
              ),
            );
          }
        }

        return AlertDialog(
          title: Text(
            existing == null
                ? noteB(NoteBTextKeys.smartNew, '新建智能笔记本')
                : noteB(NoteBTextKeys.smartEdit, '编辑智能笔记本'),
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('note-smart-name'),
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: noteB(NoteBTextKeys.smartName, '名称'),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  TextField(
                    key: const Key('note-smart-keyword'),
                    controller: keywordCtrl,
                    decoration: InputDecoration(
                      labelText: noteB(NoteBTextKeys.smartKeyword, '关键词'),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  TextField(
                    key: const Key('note-smart-title'),
                    controller: titleCtrl,
                    decoration: InputDecoration(
                      labelText: noteB(
                        NoteBTextKeys.smartNoteTitle,
                        '标题包含',
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  TextField(
                    key: const Key('note-smart-tags'),
                    controller: tagCtrl,
                    decoration: InputDecoration(
                      labelText: noteB(
                        NoteBTextKeys.smartTags,
                        '标签（逗号分隔）',
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  DesignSwitchRow(
                    key: const Key('note-smart-and'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      tagAnd
                          ? noteB(NoteBTextKeys.smartTagAnd, '标签：同时包含')
                          : noteB(NoteBTextKeys.smartTagOr, '标签：包含任一'),
                    ),
                    value: tagAnd,
                    onChanged: (v) => setDialogState(() => tagAnd = v),
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      noteB(NoteBTextKeys.smartNotebooks, '限定笔记本'),
                    ),
                    children: [
                      for (final nb in notebooks)
                        DesignCheckRow(
                          key: Key('note-smart-nb-${nb.objectId}'),
                          dense: true,
                          title: Text(nb.displayTitle),
                          value: parentIds.contains(nb.objectId),
                          onChanged: (v) => setDialogState(() {
                            if (v == true) {
                              parentIds.add(nb.objectId);
                            } else {
                              parentIds.remove(nb.objectId);
                            }
                          }),
                        ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          mtimeStart == null
                              ? noteB(NoteBTextKeys.smartDateFrom, '修改时间从')
                              : TodoReminderPlanner.formatDueDate(mtimeStart!),
                        ),
                      ),
                      IconButton(
                        key: const Key('note-smart-date-from'),
                        icon: const Icon(Icons.event),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (picked == null) return;
                          setDialogState(
                            () => mtimeStart = noteEpochSeconds(
                              DateTime(picked.year, picked.month, picked.day),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          mtimeEnd == null
                              ? noteB(NoteBTextKeys.smartDateTo, '修改时间到')
                              : TodoReminderPlanner.formatDueDate(mtimeEnd!),
                        ),
                      ),
                      IconButton(
                        key: const Key('note-smart-date-to'),
                        icon: const Icon(Icons.event),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (picked == null) return;
                          setDialogState(
                            () => mtimeEnd = noteEpochSeconds(
                              DateTime(
                                picked.year,
                                picked.month,
                                picked.day,
                                23,
                                59,
                                59,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                key: const Key('note-smart-delete'),
                onPressed: saving
                    ? null
                    : () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(
                              noteB(NoteBTextKeys.smartDelete, '删除智能笔记本'),
                            ),
                            content: Text(
                              noteBFill(
                                NoteBTextKeys.smartDeleteConfirm,
                                '确定删除「{name}」吗？',
                                {'name': existing.title},
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: Text(context.t.actionCancel),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: Text(context.t.dtoActionDelete),
                              ),
                            ],
                          ),
                        );
                        if (yes != true || !context.mounted) return;
                        final navigator = Navigator.of(context);
                        await api.deleteSmartNotebook(existing.objectId);
                        ref.invalidate(smartNotebooksProvider);
                        navigator.pop();
                      },
                child: Text(context.t.dtoActionDelete),
              ),
            TextButton(
              onPressed: saving ? null : () => Navigator.of(context).pop(),
              child: Text(context.t.actionCancel),
            ),
            FilledButton(
              key: const Key('note-smart-save'),
              onPressed: saving ? null : save,
              child: Text(context.t.actionSave),
            ),
          ],
        );
      },
    ),
  );
  // 注意：不在这里 `dispose()` 这几个 controller —— `showDialog` 返回时对话框
  // 还在做退场动画，控件仍挂在树上，提前 dispose 会触发
  // "A TextEditingController was used after being disposed"。
  // 与 `note_view_page._lockedPanel` 一样交给 GC（ChangeNotifier 无系统资源）。
}

String? _nullIfEmpty(String s) => s.trim().isEmpty ? null : s.trim();
