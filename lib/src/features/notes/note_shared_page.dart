// 「我分享出去的」页（第 117 轮 / 台账 J11）。
//
// 官方取证：`all_shared_notes` = "Shared Notes"（`res/values/strings.xml:41`）
// 与 `all_joined_notes` = "Joined Notes"（:39）是**两个**伪集合，
// 使用点是 `NotebookListAppWidgetAdapter`（小组件配置里可选这两个集合）。
// 我方此前只实现了"共享给我"（`note_joined_page.dart`），本页补另一半。
//
// 数据来源与「共享给我」**完全同源**（`Notebook.list` / `Note.list` 上的
// `individual_shared` + `owner`），**不新增任何服务端调用**。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/ui/app_states.dart';
import 'note_joined_page.dart' show NoteJoinedNotebookPage;
import 'note_providers.dart';
import 'note_reminder.dart';
import 'note_view_page.dart';
import 'note_widgets.dart';

class NoteSharedPage extends ConsumerWidget {
  const NoteSharedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final shared = ref.watch(noteSharedProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(title: Text(noteB(kNoteSharedTitle, '我分享的'))),
      body: shared.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, __) => AppErrorView(
          title: noteB(kNoteSharedTitle, '我分享的'),
          detail: describeNoteError(e, context.t),
          onRetry: () => ref.invalidate(noteSharedProvider),
        ),
        data: (data) {
          if (data.isEmpty) {
            return Center(
              child: Text(
                noteB(kNoteSharedEmpty, '还没有你分享出去的内容'),
                style: TextStyle(color: hud.dim),
              ),
            );
          }
          return ListView(
            children: [
              if (data.notebooks.isNotEmpty) ...[
                _Header(text: noteB(kNoteSharedNotebooks, '分享出去的笔记本')),
                for (final nb in data.notebooks)
                  DesignRowTile(
                    key: Key('note-shared-notebook-${nb.objectId}'),
                    leading: Icon(Icons.menu_book_outlined, color: hud.dim),
                    title: Text(nb.displayTitle),
                    onTap: () => Navigator.of(context, rootNavigator: true)
                        .push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                NoteJoinedNotebookPage(notebook: nb),
                          ),
                        ),
                  ),
              ],
              if (data.notes.isNotEmpty) ...[
                _Header(text: noteB(kNoteSharedNotes, '分享出去的笔记')),
                for (final note in data.notes)
                  NoteRow(
                    key: Key('note-shared-note-${note.objectId}'),
                    note: note,
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

class _Header extends StatelessWidget {
  const _Header({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          color: hud.dim,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 文案 key（ARB 缺 key 时回落中文原文）。
const String kNoteSharedTitle = 'noteSharedTitle';
const String kNoteSharedEmpty = 'noteSharedEmpty';
const String kNoteSharedNotebooks = 'noteSharedNotebooks';
const String kNoteSharedNotes = 'noteSharedNotes';
