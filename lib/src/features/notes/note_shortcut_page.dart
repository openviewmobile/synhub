// 「快捷方式」页（wave3 列表 + wave4 写入/跳转）：`SYNO.NoteStation.Shortcut` **v1**。
//
// 取证：
//   * 官方 Android `net/ApiNSShortcut.java`：`NAME = "SYNO.NoteStation.Shortcut"`、
//     `VERSION = 1`，方法 `list` / `set` / `delete`；
//   * 服务端 `webapi/SYNO.NoteStation.lib` 的 `Shortcut` 同样
//     `minVersion = maxVersion = 1`，`allowUser` 全含 `normal.*`（普通用户可调）；
//   * 回包逐字来自 `vos/api/ShortcutListVo.java` 的 `ShortcutsDataVo`：
//     `{offset, total, shortcuts:[{id, category, title, items, owner, acl}]}`；
//     **列表为空时没有 `shortcuts` 键**（真机 `{"data":{"offset":0,"total":0}}`）。
//
// wave4 补齐 F5 缺的两段（wave3 只做了只读列表）：
//   1. **写**：`set` / `delete`（参数形态见 `note_api.dart` 的 `setShortcut`，
//      值必须是 Gson 二次编码的 `object_id` / `tag_id`）；
//   2. **点击跳转**：按官方 Android `ShortcutListFragment.lambda$onCreateView$0`
//      —— notebook/stack/smart → 笔记本视图；note → 打开笔记；tag → 标签页。
//      跳转目标是 `items[]` 里的对象 id（`GenerateShortcutsLoader.create*` 的
//      `refObjectId` 就是这个值）。
//
// ⚠️ `id` / `items` 是服务端内部 id，**一律不上屏**（界面只用 `title`），
// 它们只出现在 Key 与测试断言里。
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
import 'note_shelf_page.dart';
import 'note_smart_page.dart';
import 'note_tag_page.dart';
import 'note_view_page.dart';
import 'note_wave4_providers.dart';
import 'note_wave4_text.dart';
import 'note_widgets.dart';

// ---------------------------------------------------------------- 动作层

/// 点击快捷方式 → 跳到它的目标（官方 Android `ShortcutListFragment` 的分支）。
///
/// 目标 id 取 `items[]` 的第一个；官方 `GenerateShortcutsLoader` 就是这么把
/// `items` 的值当对象 id 查的。拿不到目标就如实提示，**不猜**。
Future<void> openNoteShortcutTarget(
  BuildContext context,
  WidgetRef ref,
  ShortcutDto shortcut,
) async {
  final target = shortcut.itemIds.isNotEmpty ? shortcut.itemIds.first : '';
  void toastNoTarget() => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        noteWave4(NoteWave4TextKeys.shortcutNoTarget, '这个快捷方式没有可跳转的目标'),
      ),
    ),
  );

  if (shortcut.category == 'note') {
    if (target.isEmpty) {
      toastNoTarget();
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        // 列表条目没有正文，`NoteViewPage` 会按 id 去取全量（既有路径）
        builder: (_) =>
            NoteViewPage(note: NoteDto(objectId: target, title: shortcut.title)),
      ),
    );
    return;
  }
  if (shortcut.category == 'notebook') {
    if (target.isEmpty) {
      toastNoTarget();
      return;
    }
    // 回到笔记列表并选中该笔记本（官方是切到笔记本视图）
    ref.read(selectedNotebookProvider.notifier).select(target);
    Navigator.of(context).pop();
    return;
  }
  if (shortcut.category == 'stack') {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const NoteShelfPage()),
    );
    return;
  }
  if (shortcut.category == 'smart') {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const NoteSmartPage()),
    );
    return;
  }
  if (shortcut.category == 'tag') {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const NoteTagPage()),
    );
    return;
  }
  toastNoTarget();
}

// ---------------------------------------------------------------- 页面

class NoteShortcutPage extends ConsumerWidget {
  const NoteShortcutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final shortcuts = ref.watch(noteShortcutsProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(noteB(NoteBTextKeys.shortcut, '快捷方式')),
        actions: [
          IconButton(
            tooltip: context.t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(noteShortcutsProvider),
          ),
        ],
      ),
      body: shortcuts.when(
        loading: () => const AppListSkeleton(),
        error: (e, __) => AppErrorView(
          title: noteB(NoteBTextKeys.shortcutLoadFailed, '快捷方式加载失败'),
          detail: describeNoteError(e, context.t),
          onRetry: () => ref.invalidate(noteShortcutsProvider),
        ),
        data: (rows) => rows.isEmpty
            ? AppEmptyState(
                icon: Icons.bookmark_border,
                title: noteB(NoteBTextKeys.shortcutEmpty, '还没有快捷方式'),
                message: noteB(
                  NoteBTextKeys.shortcutEmptyHint,
                  '服务端还没有为这个账号保存任何快捷方式',
                ),
              )
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(noteShortcutsProvider);
                  await ref
                      .read(noteShortcutsProvider.future)
                      .catchError((Object _) => const <ShortcutDto>[]);
                },
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, indent: Gap.lg, color: hud.line),
                  itemBuilder: (context, i) {
                    final shortcut = rows[i];
                    return DesignRowTile(
                      key: Key('note-shortcut-${shortcut.id}'),
                      leading: Icon(
                        _categoryIcon(shortcut.category),
                        color: hud.dim,
                      ),
                      title: Text(shortcut.displayTitle),
                      subtitle: Text(
                        shortcutCategoryLabel(shortcut.category),
                        style: TextStyle(color: hud.dim, fontSize: 12),
                      ),
                      onTap: () =>
                          openNoteShortcutTarget(context, ref, shortcut),
                      trailing: IconButton(
                        key: Key('note-shortcut-delete-${shortcut.id}'),
                        tooltip: noteWave4(
                          NoteWave4TextKeys.shortcutRemove,
                          '取消快捷方式',
                        ),
                        icon: const Icon(Icons.bookmark_remove_outlined),
                        onPressed: () =>
                            confirmDeleteNoteShortcut(context, ref, shortcut),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

/// 取消快捷方式的确认框；取消 → 零请求（与其它危险动作同一纪律）。
Future<void> confirmDeleteNoteShortcut(
  BuildContext context,
  WidgetRef ref,
  ShortcutDto shortcut,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final t = context.t;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('note-shortcut-delete-confirm'),
      title: Text(noteWave4(NoteWave4TextKeys.shortcutRemove, '取消快捷方式')),
      content: Text(
        noteWave4Fill(
          NoteWave4TextKeys.shortcutDeleteConfirm,
          '确定取消「{name}」这个快捷方式吗？',
          {'name': shortcut.displayTitle},
        ),
      ),
      actions: [
        TextButton(
          key: const Key('note-shortcut-delete-cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(
          key: const Key('note-shortcut-delete-ok'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(context.t.actionOk),
        ),
      ],
    ),
  );
  if (ok != true) return; // ★ 取消 → 零请求
  try {
    await deleteNoteShortcut(ref, shortcut);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          noteWave4(NoteWave4TextKeys.shortcutRemoved, '已取消快捷方式'),
        ),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          noteWave4Fill(NoteWave4TextKeys.shortcutFailed, '快捷方式操作失败：{error}', {
            'error': describeNoteError(e, t),
          }),
        ),
      ),
    );
  }
}

/// `category` → 界面文案（官方 `ShortcutDao.Category`：notebook/note/tag/
/// stack/smart；未知值走 [NoteBTextKeys.shortcutCategoryOther]，**不显示原始值**）。
String shortcutCategoryLabel(String category) =>
    switch (category) {
      'notebook' => noteB(NoteBTextKeys.shortcutCategoryNotebook, '笔记本'),
      'note' => noteB(NoteBTextKeys.shortcutCategoryNote, '笔记'),
      'tag' => noteB(NoteBTextKeys.shortcutCategoryTag, '标签'),
      'stack' => noteB(NoteBTextKeys.shortcutCategoryStack, '分层'),
      'smart' => noteB(NoteBTextKeys.shortcutCategorySmart, '智能笔记本'),
      _ => noteB(NoteBTextKeys.shortcutCategoryOther, '其它'),
    };

IconData _categoryIcon(String category) => switch (category) {
  'notebook' => Icons.folder_outlined,
  'note' => Icons.sticky_note_2_outlined,
  'tag' => Icons.sell_outlined,
  'stack' => Icons.layers_outlined,
  'smart' => Icons.filter_alt_outlined,
  _ => Icons.bookmark_border,
};
