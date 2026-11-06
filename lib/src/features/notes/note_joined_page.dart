// 「共享给我 / 加入的笔记本」入口（J5 / P0-10）。
//
// 官方证据：
//   * 抽屉项 `joined`（`R.string.joined` = "Joined Notebooks"）→
//     `fragments/JoinedListFragment`（`loaders/GenerateJoinedsLoader`）；
//   * 该 loader 的数据就是本地库里 **owner != 自己** 的笔记本 +
//     `individual_joined = true` 的单条笔记，按 owner 分组，
//     组头是 owner 名，组内第一条是 `R.string.all_joined_notes`（"Joined Notes"）；
//   * 列表项显示 `note_owner`（`by %1$s`）。
// 我们照这个模型：数据仍来自 `Notebook/list` / `Note/list`（我们已在解析
// `owner` / `individual_joined` / `individual_shared`），不新增服务端调用。
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

class NoteJoinedPage extends ConsumerWidget {
  const NoteJoinedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final joined = ref.watch(noteJoinedProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(title: Text(noteB(NoteBTextKeys.joined, '共享给我'))),
      body: joined.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppErrorView(
          title: noteB(NoteBTextKeys.joined, '共享给我'),
          detail: describeNoteError(e, context.t),
          onRetry: () => ref.invalidate(noteJoinedProvider),
        ),
        data: (data) {
          if (data.isEmpty) {
            return Center(
              child: Text(
                noteB(NoteBTextKeys.joinedEmpty, '还没有别人分享给你的内容'),
                style: TextStyle(color: hud.dim),
              ),
            );
          }
          return ListView(
            children: [
              if (data.notebooks.isNotEmpty) ...[
                _Header(text: noteB(NoteBTextKeys.joinedNotebooks, '加入的笔记本')),
                for (final nb in data.notebooks)
                  DesignRowTile(
                    key: Key('note-joined-notebook-${nb.objectId}'),
                    leading: Icon(Icons.menu_book_outlined, color: hud.dim),
                    title: Text(nb.displayTitle),
                    subtitle: nb.ownerName == null
                        ? null
                        : Text(
                            noteBFill(
                              NoteBTextKeys.joinedOwner,
                              '来自 {owner}',
                              {'owner': nb.ownerName!},
                            ),
                            style: TextStyle(color: hud.dim),
                          ),
                    onTap: () => Navigator.of(context, rootNavigator: true)
                        .push(
                          MaterialPageRoute<void>(
                            builder: (_) => NoteJoinedNotebookPage(
                              notebook: nb,
                            ),
                          ),
                        ),
                  ),
              ],
              if (data.notes.isNotEmpty) ...[
                _Header(text: noteB(NoteBTextKeys.joinedNotes, '加入的笔记')),
                for (final note in data.notes)
                  NoteRow(
                    key: Key('note-joined-note-${note.objectId}'),
                    note: note,
                    notebookTitle: note.ownerName,
                    onTap: () => Navigator.of(context, rootNavigator: true)
                        .push(
                          MaterialPageRoute<void>(
                            builder: (_) => NoteViewPage(note: note),
                          ),
                        ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 某个"加入的笔记本"下的笔记
class NoteJoinedNotebookPage extends ConsumerWidget {
  const NoteJoinedNotebookPage({super.key, required this.notebook});

  final NotebookDto notebook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final all = ref.watch(noteListProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(title: Text(notebook.displayTitle)),
      body: all.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppErrorView(
          title: notebook.displayTitle,
          detail: describeNoteError(e, context.t),
          onRetry: () => ref.invalidate(noteListProvider),
        ),
        data: (result) {
          final rows = result.notes
              .where((n) => !n.recycle && n.parentId == notebook.objectId)
              .toList();
          if (rows.isEmpty) {
            return Center(
              child: Text(
                context.t.noteEmptyNotebook,
                style: TextStyle(color: hud.dim),
              ),
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => Divider(height: 1, color: hud.line),
            itemBuilder: (context, i) {
              final note = rows[i];
              return NoteRow(
                note: note,
                onTap: () => Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NoteViewPage(note: note),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
    child: Text(
      text,
      style: TextStyle(
        color: DesignPalette.of(context).dim,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
    ),
  );
}
