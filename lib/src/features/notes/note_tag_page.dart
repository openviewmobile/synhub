// 「标签」页（P1 · NoteStation）：`Tag/list` + 重命名 / 删除 + **子标签树**。
//
// 官方 Web 端的标签是全局对象（`tag_id` 形如 `标签名@uid`），笔记通过
// `Note/set` 的 `tag: [标题]` 挂标签 —— 所以这里管理的是"标签对象"，
// 笔记上的增删在笔记详情页做。
//
// ★ F4（子标签）：**服务端没有父子字段**（`Tag/set` v1 只收 `tag_id`+`title`，
//   见 `note_tag_tree.dart` 顶部的取证）。嵌套完全是标题里的 `/` 分层约定，
//   客户端用 `parseTagStructure` 那套函数建树。所以这里只做**展示成树**
//   + 折叠开关；真正的"建子标签"在笔记的标签编辑器里（拼 `父/子` 标题）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/note_dto.dart';
import 'note_providers.dart';
import 'note_tag_tree.dart';
import 'note_wave5_text.dart';
import 'note_widgets.dart';

class NoteTagPage extends ConsumerStatefulWidget {
  const NoteTagPage({super.key});

  @override
  ConsumerState<NoteTagPage> createState() => _NoteTagPageState();
}

class _NoteTagPageState extends ConsumerState<NoteTagPage> {
  final Set<String> _busy = {};

  /// 官方标签菜单的 `tag_show_mode`（"show_subtag"）：默认**折叠**子标签。
  bool _showSubTags = false;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final tags = ref.watch(noteTagsProvider);
    final hasSubTags = (tags.value ?? const <TagDto>[]).any(
      (t) => t.title.contains(kNoteTagSeparator),
    );

    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(context.t.noteTags),
        actions: [
          // F4：官方 `tag_show_mode` / `show_subtag` 的等价开关
          if (hasSubTags)
            IconButton(
              key: const Key('note-tag-show-subtags'),
              tooltip: noteWave5(NoteWave5TextKeys.showSubTags, '显示子标签'),
              icon: Icon(_showSubTags ? Icons.account_tree : Icons.list_alt),
              onPressed: () => setState(() => _showSubTags = !_showSubTags),
            ),
          IconButton(
            tooltip: context.t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(noteTagsProvider),
          ),
        ],
      ),
      body: tags.when(
        loading: () => const AppListSkeleton(),
        error: (e, __) => AppErrorView(
          title: context.t.noteOpenTagsFailed,
          detail: describeNoteError(e, context.t),
          onRetry: () => ref.invalidate(noteTagsProvider),
        ),
        data: (rows) => rows.isEmpty
            ? AppEmptyState(
                icon: Icons.sell_outlined,
                title: context.t.noteNoTagsYet,
                // 服务端没有"建空标签"的接口（`Tag/set` 不带 tag_id 直接 101），
                // 标签是跟着笔记的 `tag` 数组隐式创建的
                message: context.t.noteTagCreateHint,
              )
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(noteTagsProvider);
                  await ref
                      .read(noteTagsProvider.future)
                      .catchError((Object _) => const <TagDto>[]);
                },
                child: _buildTree(context, hud, rows),
              ),
      ),
    );
  }

  /// F4：把扁平标签列表渲染成缩进的树（标题 `/` 分层）。
  ///
  /// 找不到父标签的（例如只有 `a/b` 而没有 `a`）按**根**处理 —— 与服务端一致，
  /// 不凭标题臆造一个不存在的标签对象。
  Widget _buildTree(BuildContext context, DesignPalette hud, List<TagDto> rows) {
    final byTitle = {for (final t in rows) t.title: t};
    final tree = buildNoteTagTree(
      rows.map((t) => (title: t.title, count: t.count)),
    );
    final flat = flattenNoteTagTree(tree, showSubTags: _showSubTags);
    final visible = flat.where((e) => e.visible).toList();
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: visible.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, indent: Gap.lg, color: hud.line),
      itemBuilder: (context, i) {
        final entry = visible[i];
        final tag = byTitle[entry.node.fullTitle];
        return DesignRowTile(
          key: Key('note-tag-${entry.node.fullTitle}'),
          contentPadding: EdgeInsets.only(
            left: Gap.lg + entry.depth * Gap.lg,
            right: Gap.sm,
          ),
          leading: Icon(
            entry.depth == 0 ? Icons.sell_outlined : Icons.subdirectory_arrow_right,
            color: hud.dim,
            size: entry.depth == 0 ? 24 : 18,
          ),
          title: Text(entry.node.title),
          subtitle: Text(
            context.t.noteTagCount(entry.node.count),
            style: TextStyle(color: hud.dim, fontSize: 12),
          ),
          trailing: tag == null || _busy.contains(tag.tagId)
              ? null
              : PopupMenuButton<String>(
                  tooltip: context.t.noteActions,
                  onSelected: (v) =>
                      v == 'rename' ? _rename(tag) : _delete(tag),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(context.t.photoRename),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(context.t.dtoActionDelete),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Future<String?> _ask(String title, {String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: context.t.noteTagNameHint),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: Text(context.t.actionSave),
          ),
        ],
      ),
    );
  }

  Future<void> _run(String id, Future<void> Function() action) async {
    final t = context.t;
    setState(() => _busy.add(id));
    try {
      await action();
      ref.invalidate(noteTagsProvider);
      ref.invalidate(noteListProvider);
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

  Future<void> _rename(TagDto tag) async {
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final title = await _ask(context.t.noteRenameTag, initial: tag.title);
    if (title == null || title.isEmpty || title == tag.title) return;
    await _run(tag.tagId, () => api.renameTag(tagId: tag.tagId, title: title));
  }

  Future<void> _delete(TagDto tag) async {
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t.noteDeleteTag),
        content: Text(context.t.noteDeleteTagConfirm(tag.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _run(tag.tagId, () async {
      try {
        await api.deleteTag(tag.tagId);
      } catch (e) {
        // 真机实测：最后一个引用被摘掉后服务端可能已经把标签回收了，
        // 这时再删会拿到 1003 之类的"对象不存在"错误 —— 当成已删除。
        if (!_looksGone(e)) rethrow;
      }
    });
  }

  bool _looksGone(Object e) {
    final s = '$e';
    return s.contains('1003') || s.contains('1002') || s.contains('1007');
  }
}
