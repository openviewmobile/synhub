// 「回收站」页（P1 · NoteStation）：`Note/list` 里 `recycle=true` 的条目 +
// 还原（`Note/restore`）/ 彻底删除（`Note/delete recycle=false`）。
//
// ⚠️ `Note/list` **不会**把回收站排除掉，官方也是在本地按 `recycle` 分组；
// 所以这里用同一个接口拉回来自己过滤。彻底删除不可恢复，必须先确认。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/note_dto.dart';
import '../files/file_row.dart' show formatFileTime;
import 'note_providers.dart';
import 'note_wave5_text.dart';
import 'note_widgets.dart';

class NoteRecyclePage extends ConsumerStatefulWidget {
  const NoteRecyclePage({super.key});

  @override
  ConsumerState<NoteRecyclePage> createState() => _NoteRecyclePageState();
}

class _NoteRecyclePageState extends ConsumerState<NoteRecyclePage> {
  final Set<String> _busy = {};

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final notes = ref.watch(noteRecycleProvider);
    final emptyBin = notes.value?.isEmpty ?? false;

    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(context.t.noteRecycle),
        actions: [
          if (!emptyBin)
            TextButton(
              onPressed: _busy.isEmpty ? _emptyAll : null,
              child: Text(context.t.actionClear),
            ),
          IconButton(
            tooltip: context.t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(noteRecycleProvider),
          ),
        ],
      ),
      body: notes.when(
        loading: () => const AppListSkeleton(),
        error: (e, __) => AppErrorView(
          title: context.t.noteOpenRecycleFailed,
          detail: describeNoteError(e, context.t),
          onRetry: () => ref.invalidate(noteRecycleProvider),
        ),
        data: (rows) => rows.isEmpty
            ? AppEmptyState(
                icon: Icons.delete_outline,
                title: context.t.noteRecycleEmpty,
                message: context.t.noteRecycleEmptyMessage,
              )
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(noteRecycleProvider);
                  await ref
                      .read(noteRecycleProvider.future)
                      .catchError((Object _) => const <NoteDto>[]);
                },
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, indent: Gap.lg, color: hud.line),
                  itemBuilder: (context, i) {
                    final note = rows[i];
                    return DesignRowTile(
                      leading: Icon(
                        Icons.sticky_note_2_outlined,
                        color: hud.dim,
                      ),
                      title: Text(
                        note.title.isEmpty
                            ? context.t.noteUntitled
                            : note.title,
                      ),
                      subtitle: Text(
                        note.brief.isEmpty
                            ? formatFileTime(note.mtime)
                            : note.brief,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: hud.dim, fontSize: 12),
                      ),
                      trailing: _busy.contains(note.objectId)
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : PopupMenuButton<String>(
                              tooltip: context.t.noteActions,
                              onSelected: (v) => v == 'restore'
                                  ? _restore(note)
                                  : _purge(note),
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'restore',
                                  child: Text(context.t.noteRecycleRestore),
                                ),
                                PopupMenuItem(
                                  value: 'purge',
                                  child: Text(context.t.notePurge),
                                ),
                              ],
                            ),
                    );
                  },
                ),
              ),
      ),
    );
  }

  void _refresh() {
    ref.invalidate(noteRecycleProvider);
    ref.invalidate(noteListProvider);
  }

  Future<void> _run(
    String id,
    Future<void> Function() action, {
    String? okText,
  }) async {
    final t = context.t;
    setState(() => _busy.add(id));
    try {
      await action();
      _refresh();
      if (okText != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(okText)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t.noteRecycleActionFailed(describeNoteError(e, t))),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _restore(NoteDto note) async {
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    await _run(
      note.objectId,
      () => api.restoreNote(note.objectId),
      okText: context.t.noteRestored,
    );
  }

  Future<void> _purge(NoteDto note) async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.notePurge),
        content: Text(
          t.notePurgeConfirm(note.title.isEmpty ? t.noteUntitled : note.title),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _run(
      note.objectId,
      () => api.deleteNote(note.objectId, recycle: false),
      okText: t.notePurged,
    );
  }

  Future<void> _emptyAll() async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    final rows = ref.read(noteRecycleProvider).value ?? const <NoteDto>[];
    if (api == null || rows.isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.noteRecycleCleanTitle),
        content: Text(t.noteRecycleCleanConfirm(rows.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.actionClear),
          ),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busy.add('*'));
    try {
      // A8：**批量清空**，不再逐条循环。
      //
      // ★ 取证（官方 Web `ui/notestation.js` 的 `emptyRecycleBin`）：
      //   ```js
      //   emptyRecycleBin:function(){var t=this.findAppWindow(),e=t.owned.recycle,o=[];
      //     0!==e.length&&t.getMsgBox().confirmDelete(...,function(t,i){
      //       "cancel"!==t&&(Ext.each(e,function(t){o.push(t)},this),
      //       this.deleteNoteAsync(o,{recycle:!1})...)}...)},
      //   ```
      //   即把**整筐 id 塞进一个数组**，走 `Note/delete` **v3** 的
      //   `object_id: [ … ]`（服务端 `.lib`：`Note` v3 的 `delete` 收数组；
      //   Android `DeleteNoteOperation` 是 v1 标量逐条的另一条实现）。
      //   本仓库 [NoteStationApi.deleteNotes] 已封装该形态，并在 v3 不可用时
      //   自动退回逐条（老服务端）。
      final result = await api.deleteNotes(
        rows.map((n) => n.objectId).toList(),
        recycle: false,
      );
      _refresh();
      if (mounted) {
        if (result.hasFailure) {
          // 不静默：明确报告"成功几条 / 失败几条"
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                noteWave5Fill(
                  NoteWave5TextKeys.emptyRecyclePartial,
                  '已清空 {ok} 条，{fail} 条失败',
                  {
                    'ok': '${result.succeeded}',
                    'fail': '${result.failed.length}',
                  },
                ),
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                noteWave5Fill(
                  NoteWave5TextKeys.emptyRecycleDone,
                  '已清空回收站（{count} 条）',
                  {'count': '${result.objectIds.length}'},
                ),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t.noteRecycleCleanFailed(describeNoteError(e, t))),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove('*'));
    }
  }
}
