// 「笔记」页（P1 · NoteStation）：笔记本筛选 + 笔记列表 + 搜索 + 新建。
//
// 官方 DS note 的模型是"全量同步到本地再查"，我们这一步先做**一次拉回 +
// 本地过滤**（`visibleNotesProvider`），离线缓存留到真机对齐后再补。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/platform/app_platform.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/adaptive_layout.dart';
import '../../core/ui/app_states.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';
import '../chat/chat_session_controller.dart' show chatStoreProvider;
import 'note_adv_search_page.dart';
import 'note_adv_search_text.dart';
import 'note_c3_pages.dart';
import 'note_c3_providers.dart';
import 'note_c3_text.dart';
import 'note_editor_page.dart';
import 'note_fts_search_page.dart';
import 'note_gaps_text.dart';
import 'note_html.dart'
    show kSynoFontSizeLabels, kSynoFontSizes, notePlainText;
import 'note_joined_page.dart';
import '../../core/i18n/data_text.dart';
import 'note_shared_page.dart';
import 'note_theme_sheet.dart';
import 'note_picker.dart' show NotePickSource;
import 'note_providers.dart';
import 'note_recycle_page.dart';
import 'note_reminder.dart';
import 'note_reminder_host.dart';
import 'note_shelf_page.dart';
import 'note_shortcut_page.dart';
import 'note_smart_page.dart';
import 'note_sync.dart';
import 'note_tag_page.dart';
import 'note_background_sync_page.dart';
import 'note_todo_page.dart';
import 'note_view_page.dart';
import 'note_wave4_text.dart';
import 'note_wave5_text.dart';
import 'note_widgets.dart';
import '../../core/theme/app_theme.dart';

class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  bool _searching = false;
  final _searchCtrl = TextEditingController();

  /// A12 多选模式：进入后行首出现勾选框，AppBar 变选择工具栏。
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  /// 宽屏（`AppWindowSize.expanded`）右栏要显示的笔记。
  ///
  /// 窄屏恒为 `null`：窄屏点行**依旧 push 路由**（见 [_onNoteTap]），
  /// 这样"返回栈正确"这条既有行为逐字节不变（r283 折叠/Pad 适配）。
  NoteDto? _wideNote;
  bool _wideFromCache = false;

  @override
  void initState() {
    super.initState();
    // 进页面就同步一次（拉全量 + 推离线改动）。放在帧后是为了不打断首帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(noteSyncProvider.notifier).sync();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _enterSelection(String id) => setState(() {
    _selecting = true;
    _selectedIds
      ..clear()
      ..add(id);
  });

  void _exitSelection() => setState(() {
    _selecting = false;
    _selectedIds.clear();
  });

  void _toggleSelected(String id) => setState(() {
    if (!_selectedIds.remove(id)) _selectedIds.add(id);
  });

  void _selectAll(List<NoteDto> rows) => setState(() {
    _selectedIds
      ..clear()
      ..addAll(rows.map((n) => n.objectId));
  });

  void _invertSelection(List<NoteDto> rows) => setState(() {
    final next = <String>{};
    for (final n in rows) {
      if (!_selectedIds.contains(n.objectId)) next.add(n.objectId);
    }
    _selectedIds
      ..clear()
      ..addAll(next);
  });

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final notes = ref.watch(visibleNotesProvider);
    final notebooks = ref.watch(notebooksProvider);
    final all = ref.watch(noteListProvider);
    final selected = ref.watch(selectedNotebookProvider);
    // 能力位降级：`SYNO.NoteStation.Todo` 缺失时只藏「待办」入口，笔记模块照常可用。
    final canTodo = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.note, kNoteTodoApi);
    // wave3：快捷方式入口按 `SYNO.NoteStation.Shortcut` 能力位降级
    // （缺位 → 只藏这一个入口；未检测 → fail-open，见 hasApi 的纪律）。
    final canShortcut = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.note, NoteStationApi.shortcutApi);
    // wave4：全文检索入口按 `SYNO.NoteStation.FTS` 能力位降级（缺位只藏该入口）。
    final canFts = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.note, NoteStationApi.ftsApi);
    // A14：是否把已归档的笔记本也列出来（本地视图开关）
    final includeArchived = ref.watch(noteIncludeArchivedProvider);
    // F9：列表 / 网格（官方 Web `view_by`：snippet / card）
    final viewMode = ref.watch(noteViewModeProvider);
    // G4：标签过滤
    final filterTags = ref.watch(noteFilterTagsProvider);
    final titles = {
      for (final nb in notebooks.value ?? const <NotebookDto>[])
        nb.objectId: nb.displayTitle,
    };
    // C3：导入 / 剪藏入口按能力位 + `105` 显隐；未检测（null）→ fail-open。
    final c3 = ref.watch(noteC3AvailabilityProvider).value;
    final showsImport =
        c3 == null ||
        c3.shows(NoteC3Feature.importEnex) ||
        c3.shows(NoteC3Feature.importNotebook) ||
        c3.shows(NoteC3Feature.importEvernote);
    final showsClip = c3 == null || c3.shows(NoteC3Feature.clipper);
    final showsExportNotebook =
        c3 == null || c3.shows(NoteC3Feature.exportNotebook);
    // C9/G5：附件文本搜索的能力位（`Note` v4）；开关的**本地值**单独读，
    // 这样即使服务端能力位还没读到，设置项也能反映用户的选择。
    final canAttachSearch =
        ref.read(noteApiProvider)?.supportsAttachmentText() ?? false;
    final attachSearchPref =
        ref.watch(noteAttachmentSearchPrefProvider).value ?? false;
    final rows = notes.value ?? const <NoteDto>[];

    // ★ r283 折叠/Pad 适配：`page` 是**既有单列页**（窄屏时逐字节不变地返回）。
    //   `AdaptiveScaffold` 只在 expanded（>=700dp，见 adaptive_layout.dart
    //   §一）或**有竖向折痕**时才把它
    //   放进左栏并并排右栏；其余情况原样返回 `page`（见 adaptive_layout.dart
    //   文件头 §四「窄屏等价性」）。
    final page = Scaffold(
      key: const Key('note-wide-master'),
      backgroundColor: hud.bg,
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                key: const Key('note-selection-close'),
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              )
            : null,
        title: _selecting
            ? Text(
                noteGapsFill(
                  NoteGapsTextKeys.selectedCount,
                  '已选 {count} 项',
                  {'count': '${_selectedIds.length}'},
                ),
                key: const Key('note-selection-count'),
              )
            : _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: context.t.noteSearchHint,
                  border: InputBorder.none,
                ),
                onChanged: (v) => ref.read(noteKeywordProvider.notifier).set(v),
              )
            : Text(context.t.wsNotes),
        actions: _selecting
            // ★ `? [` 会被 Dart 解析成 null-aware 索引（`a?[i]`）⇒ 显式写类型
            ? <Widget>[
                IconButton(
                  key: const Key('note-selection-all'),
                  tooltip: noteGaps(NoteGapsTextKeys.selectAll, '全选'),
                  icon: const Icon(Icons.select_all),
                  onPressed: rows.isEmpty ? null : () => _selectAll(rows),
                ),
                IconButton(
                  key: const Key('note-selection-invert'),
                  tooltip: noteGaps(
                    NoteGapsTextKeys.invertSelection,
                    '反选',
                  ),
                  icon: const Icon(Icons.flip_to_back),
                  onPressed: rows.isEmpty ? null : () => _invertSelection(rows),
                ),
                IconButton(
                  key: const Key('note-selection-delete'),
                  tooltip: noteGaps(NoteGapsTextKeys.batchDelete, '批量删除'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () => _batchDelete(rows),
                ),
                IconButton(
                  key: const Key('note-selection-move'),
                  tooltip: noteGaps(NoteGapsTextKeys.batchMove, '批量移动'),
                  icon: const Icon(Icons.drive_file_move_outline),
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () => _batchMove(rows),
                ),
              ]
            : <Widget>[
                IconButton(
                  key: const Key('note-sort-entry'),
                  tooltip: noteGaps(NoteGapsTextKeys.sort, '排序'),
                  icon: const Icon(Icons.sort),
                  onPressed: _showSortSheet,
                ),
                // F9：列表 / 网格切换（官方 Web `btn_note_display_mode`）
                IconButton(
                  key: const Key('note-view-toggle'),
                  tooltip: viewMode == NoteViewMode.card
                      ? noteWave5(NoteWave5TextKeys.viewList, '列表视图')
                      : noteWave5(NoteWave5TextKeys.viewGrid, '网格视图'),
                  icon: Icon(
                    viewMode == NoteViewMode.card
                        ? Icons.view_list_outlined
                        : Icons.grid_view_outlined,
                  ),
                  onPressed: () =>
                      ref.read(noteViewModeProvider.notifier).toggle(),
                ),
                // G4：标签 + 操作符筛选（有选中标签时高亮）
                IconButton(
                  key: const Key('note-tag-filter-entry'),
                  tooltip: noteWave5(NoteWave5TextKeys.filterByTags, '按标签筛选'),
                  icon: Badge(
                    isLabelVisible: filterTags.isNotEmpty,
                    label: Text('${filterTags.length}'),
                    child: Icon(
                      filterTags.isEmpty
                          ? Icons.sell_outlined
                          : Icons.sell,
                    ),
                  ),
                  onPressed: _showTagFilterSheet,
                ),
                IconButton(
                  tooltip: _searching
                      ? context.t.noteCloseSearch
                      : context.t.noteSearchNotes,
                  icon: Icon(_searching ? Icons.close : Icons.search),
                  onPressed: () {
                    setState(() => _searching = !_searching);
                    if (!_searching) {
                      _searchCtrl.clear();
                      ref.read(noteKeywordProvider.notifier).set('');
                    }
                  },
                ),
                IconButton(
                  tooltip: context.t.photoRefresh,
                  icon: const Icon(Icons.refresh),
                  onPressed: () {
                    ref.invalidate(noteListProvider);
                    ref.invalidate(notebooksProvider);
                  },
                ),
                PopupMenuButton<String>(
                  tooltip: context.t.photoMore,
                  onSelected: (value) {
                    if (value == 'todo') {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(builder: (_) => const NoteTodoPage()),
                );
              } else if (value == 'bgSync') {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const NoteBackgroundSyncPage(),
                  ),
                );
              } else if (value == 'tags') {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(builder: (_) => const NoteTagPage()),
                );
              } else if (value == 'shortcut') {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const NoteShortcutPage(),
                  ),
                );
              } else if (value == 'recycle') {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const NoteRecyclePage(),
                  ),
                );
              } else if (value == 'newNotebook') {
                _createNotebook();
              } else if (value == 'sync') {
                ref.read(noteSyncProvider.notifier).sync();
              } else if (value == 'import') {
                showNoteImportSheet(context, ref);
              } else if (value == 'clip') {
                showNoteClipDialog(context, ref);
              } else if (value == 'exportNotebook') {
                showNoteNotebookExportDialog(context, ref);
              } else if (value == 'smart') {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(builder: (_) => const NoteSmartPage()),
                );
              } else if (value == 'joined') {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(builder: (_) => const NoteJoinedPage()),
                );
              } else if (value == 'theme') {
                // N6：笔记内可达的主题入口（写同一个 App 级偏好）
                showNoteThemeSheet(context, ref);
              } else if (value == 'shared') {
                // ★ 117 轮 J11：官方的另一半伪集合 "Shared Notes"
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(builder: (_) => const NoteSharedPage()),
                );
              } else if (value == 'shelf') {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(builder: (_) => const NoteShelfPage()),
                );
              } else if (value == 'attachmentSearch') {
                _toggleAttachmentSearch(!attachSearchPref);
              } else if (value == 'defaultFontSize') {
                _chooseDefaultFontSize();
              } else if (value == 'fts') {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const NoteFtsSearchPage(),
                  ),
                );
              } else if (value == 'advSearch') {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const NoteAdvSearchPage(),
                  ),
                );
              } else if (value == 'newCamera') {
                _createNote(context, initialPickSource: NotePickSource.camera);
              } else if (value == 'newVideo') {
                _createNote(context, initialPickSource: NotePickSource.video);
              } else if (value == 'includeArchived') {
                // A14：切换"显示已归档"（`Notebook/list` 的 `filter.archive`）
                ref
                    .read(noteIncludeArchivedProvider.notifier)
                    .set(!includeArchived);
              } else if (value == 'tagFilter') {
                _showTagFilterSheet();
              } else if (value == 'clearTagFilter') {
                ref.read(noteFilterTagsProvider.notifier).clear();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'sync', child: Text(context.t.noteSyncMenu)),
              if (canTodo)
                PopupMenuItem(
                  value: 'todo',
                  child: Text(context.t.noteTodoTitle),
                ),
              PopupMenuItem(value: 'tags', child: Text(context.t.noteTags)),
              PopupMenuItem(
                value: 'recycle',
                child: Text(context.t.noteRecycle),
              ),
              // C9/G5：附件文本搜索开关（`Note` v4 才有 get_attachment_text；
              // 关闭时不发任何请求，见 noteAttachmentSearchEnabledProvider）
              if (canAttachSearch)
                CheckedPopupMenuItem<String>(
                  value: 'attachmentSearch',
                  key: const Key('note-attachment-search-toggle'),
                  checked: attachSearchPref,
                  child: Text(
                    noteGaps(NoteGapsTextKeys.attachmentSearch, '搜索附件文本'),
                  ),
                ),
              // N7：默认字号（官方 key `default_font_size`）
              PopupMenuItem(
                value: 'defaultFontSize',
                key: const Key('note-default-font-size-entry'),
                child: Text(
                  noteGaps(NoteGapsTextKeys.defaultFontSize, '默认字号'),
                ),
              ),
              // C3：导入 / 网页剪藏（各自按能力位 + `105` 显隐）
              if (showsImport)
                PopupMenuItem(
                  value: 'import',
                  key: const Key('note-c3-import-entry'),
                  child: Text(noteC3(NoteC3TextKeys.import, '导入')),
                ),
              if (showsClip)
                PopupMenuItem(
                  value: 'clip',
                  key: const Key('note-c3-clip-entry'),
                  child: Text(noteC3(NoteC3TextKeys.clip, '网页剪藏')),
                ),
              if (showsExportNotebook)
                PopupMenuItem(
                  value: 'exportNotebook',
                  key: const Key('note-c3-export-notebook-entry'),
                  child: Text(
                    noteC3(NoteC3TextKeys.exportNotebook, '导出笔记本到 NAS'),
                  ),
                ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'smart',
                key: const Key('note-smart-entry'),
                child: Text(noteB(NoteBTextKeys.smart, '智能笔记本')),
              ),
              PopupMenuItem(
                value: 'joined',
                key: const Key('note-joined-entry'),
                child: Text(noteB(NoteBTextKeys.joined, '共享给我')),
              ),
              PopupMenuItem(
                value: 'shelf',
                key: const Key('note-shelf-entry'),
                child: Text(noteB(NoteBTextKeys.shelf, 'Shelf 分层')),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'newNotebook',
                child: Text(context.t.noteNewNotebook),
              ),
              // wave3：快捷方式（`Shortcut/list`）。放在菜单末尾是为了**不打乱**
              // 既有条目的位置（800×600 的测试窗口里菜单本就接近满屏）。
              if (canShortcut)
                PopupMenuItem(
                  value: 'shortcut',
                  key: const Key('note-shortcut-entry'),
                  child: Text(noteB(NoteBTextKeys.shortcut, '快捷方式')),
                ),
              // ---- wave4（放在末尾：不改动既有条目的位置/可点性）----
              // G1：全文检索（服务端 FTS）—— 能力位缺失只藏这一项。
              if (canFts)
                PopupMenuItem(
                  value: 'fts',
                  key: const Key('note-fts-entry'),
                  child: Text(
                    noteWave4(NoteWave4TextKeys.ftsEntry, '全文检索'),
                  ),
                ),
              // C5：官方抽屉的「从相机/视频新建」（新笔记 → 立刻调起相机）。
              PopupMenuItem(
                value: 'newCamera',
                key: const Key('note-new-camera-entry'),
                child: Text(
                  noteWave4(NoteWave4TextKeys.newFromCamera, '拍照新建'),
                ),
              ),
              PopupMenuItem(
                value: 'newVideo',
                key: const Key('note-new-video-entry'),
                child: Text(
                  noteWave4(NoteWave4TextKeys.newFromVideo, '录像新建'),
                ),
              ),
              // ---- wave5 ----
              // A14：是否显示已归档的笔记本（官方默认过滤掉；这个开关纯本地）。
              CheckedPopupMenuItem<String>(
                value: 'includeArchived',
                key: const Key('note-include-archived-toggle'),
                checked: includeArchived,
                child: Text(
                  noteWave5(NoteWave5TextKeys.showArchived, '显示已归档笔记本'),
                ),
              ),
              // G4：标签 + 操作符筛选（选中时也可从这里清除）
              PopupMenuItem(
                value: 'tagFilter',
                key: const Key('note-tag-filter-menu'),
                child: Text(
                  noteWave5(NoteWave5TextKeys.filterByTags, '按标签筛选'),
                ),
              ),
              if (filterTags.isNotEmpty)
                PopupMenuItem(
                  value: 'clearTagFilter',
                  key: const Key('note-tag-filter-clear'),
                  child: Text(
                    noteWave5(NoteWave5TextKeys.clearTagFilter, '清除标签筛选'),
                  ),
                ),
              // ---- G3：高级搜索（放在**最末**，避免改动既有条目的位置）----
              PopupMenuItem(
                value: 'advSearch',
                key: const Key('note-adv-entry'),
                child: Text(noteAdv(NoteAdvTextKeys.entry, '高级搜索')),
              ),
              // 第 115 轮 M3 收尾：后台同步开关（官方 resume/pauseSyncService）
              // ★ r693 DA333：这条走的是**安卓 WorkManager 桥**（`synhub/note_sync`），
              //   桌面宿主上没有桥 ⇒ 开关点了永远"设置失败"，页内文案还写着
              //   「Android 会在后台拉取…」。按能力位 fail-closed：桌面**不摆入口**。
              if (capabilityGateAllows(AppCapability.scheduledNoteSync))
                PopupMenuItem(
                  value: 'bgSync',
                  child: Text(noteB(kNoteBackgroundSyncTitle, '后台同步')),
                ),
              PopupMenuItem(
                value: 'shared',
                key: const Key('note-shared-entry'),
                child: Text(noteB(kNoteSharedTitle, '我分享的')),
              ),
              PopupMenuItem(
                value: 'theme',
                key: const Key('note-theme-entry'),
                child: Text(dataText('noteThemeTitle', '主题')),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _createNote(context),
              icon: const Icon(Icons.add),
              label: Text(context.t.noteNewNote),
            ),
      body: NoteReminderHost(
        child: Column(
          children: [
          const NoteConflictBanner(),
          const NoteOfflineBanner(),
          if (notebooks.hasValue)
            NotebookChips(
              notebooks: notebooks.value ?? const [],
              selected: selected,
              onSelect: (id) =>
                  ref.read(selectedNotebookProvider.notifier).select(id),
              countOf: (id) => noteCountOf(all.value?.notes ?? const [], id),
              onLongPress: (nb) => _manageNotebook(nb),
            ),
          const SizedBox(height: Gap.sm),
          Expanded(
            child: notes.when(
              loading: () => const AppListSkeleton(),
              error: (e, _) => AppErrorView(
                title: context.t.noteOpenNotesFailed,
                detail: describeNoteError(e, context.t),
                onRetry: () {
                  ref.invalidate(noteListProvider);
                  ref.invalidate(notebooksProvider);
                },
              ),
              data: (visible) => RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(noteListProvider);
                  await ref
                      .read(noteListProvider.future)
                      .catchError(
                        (Object _) => NoteListResult(const <NoteDto>[]),
                      );
                },
                child: visible.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: 320,
                            child: AppEmptyState(
                              icon: Icons.sticky_note_2_outlined,
                              title: _emptyTitle(
                                context,
                                selected,
                                all.value?.notes,
                              ),
                              message: context.t.noteEmptyCreateHint,
                            ),
                          ),
                        ],
                      )
                    : viewMode == NoteViewMode.card
                    // F9：网格视图（官方 Web `note_card` / `view_by:"card"`）
                    ? GridView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 220,
                              mainAxisSpacing: Gap.sm,
                              crossAxisSpacing: Gap.sm,
                              childAspectRatio: 0.95,
                            ),
                        itemCount: visible.length,
                        itemBuilder: (context, i) {
                          final note = visible[i];
                          return NoteGridCard(
                            note: note,
                            notebookTitle: titles[note.parentId],
                            selectable: _selecting,
                            selected: _selectedIds.contains(note.objectId),
                            onLongPress: () => _enterSelection(note.objectId),
                            onTap: () => _onNoteTap(
                              note,
                              all.value?.fromCache ?? false,
                            ),
                          );
                        },
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          indent: Gap.lg * 2,
                          color: hud.line,
                        ),
                        itemBuilder: (context, i) {
                          final note = visible[i];
                          final isSelected = _selectedIds.contains(
                            note.objectId,
                          );
                          return NoteRow(
                            key: Key('note-row-${note.objectId}'),
                            note: note,
                            notebookTitle: titles[note.parentId],
                            selectable: _selecting,
                            selected: isSelected,
                            onLongPress: () =>
                                _enterSelection(note.objectId),
                            onTap: () => _onNoteTap(
                              note,
                              all.value?.fromCache ?? false,
                            ),
                          );
                        },
                      ),
              ),
            ),
          ),
        ],
        ),
      ),
    );

    return AdaptiveScaffold(
      master: page,
      dividerColor: hud.line,
      // 右栏只在 expanded（或折痕分栏）时才被插进树里；窄屏传了也不建。
      // `note-wide-region` 是**右栏区域**的稳定 key（与"选中/未选中"无关），
      // 用例用它量"两个区域矩形同时在屏内且不重叠"这个**机制量**。
      detail: SizedBox.expand(
        key: const Key('note-wide-region'),
        child: _wideNote == null
            ? const _NoteWideEmpty()
            : _NoteWideDetail(note: _wideNote!, fromCache: _wideFromCache),
      ),
    );
  }

  // ---------------------------------------------------- F9 视图 / G4 标签筛选

  /// 打开一条笔记（列表行与网格卡片共用）。
  ///
  /// ★ r283（折叠/Pad）：**宽屏走右栏、窄屏走 push 路由**。
  /// 判据是机制量 —— 窗口宽度分级（`appWindowSizeOf`），不是"有没有右栏
  /// widget"，也不是"某元素在不在屏内"（§2.0.30②）。
  /// 窄屏分支与改动前**逐字节相同**：仍是
  /// `Navigator.of(context, rootNavigator: true).push(MaterialPageRoute…)`。
  void _onNoteTap(NoteDto note, bool fromCache) {
    if (_selecting) {
      _toggleSelected(note.objectId);
      return;
    }
    track(ref, UsageModule.notes, UsageAction.open, objectType: 'note');
    if (appWindowSizeOf(MediaQuery.sizeOf(context)).isExpanded) {
      setState(() {
        _wideNote = note;
        _wideFromCache = fromCache;
      });
      return;
    }
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => NoteViewPage(note: note, fromCache: fromCache),
      ),
    );
  }

  /// G4：标签 + 操作符筛选面板。
  ///
  /// 选中的标签与 `tag_operator`（`and`/`or`）会**透传给 `Note/list`**
  /// （官方 Web `query_params` 就是这么发的），不是本地假装过滤。
  Future<void> _showTagFilterSheet() async {
    // ★ r131 D18：筛选的标签来源 = `noteAllTagsProvider`
    //   （服务端标签 ∪ 笔记自带标签）= **正文页渲染标签用的同一份数据**；
    //   不再单独读 `noteTagsProvider`（那正是"两份表示"的来源）。
    final source = await ref.read(noteAllTagsProvider.future);
    if (!mounted) return;
    if (source.tags.isEmpty) {
      // ★ "取不到"与"没有"必须分开说：服务端那份失败时不许说「没有标签」。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            source.serverFailed
                ? context.t.noteTagsUnavailable
                : context.t.noteNoTagsYet,
          ),
        ),
      );
      return;
    }
    final picked = await showModalBottomSheet<({List<String> tags, String op})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _TagFilterSheet(
        all: source.tags,
        initial: ref.read(noteFilterTagsProvider),
        initialOperator: ref.read(noteTagOperatorProvider),
      ),
    );
    if (picked == null) return;
    ref.read(noteFilterTagsProvider.notifier).set(picked.tags);
    ref.read(noteTagOperatorProvider.notifier).set(picked.op);
    ref.invalidate(noteTagFilteredListProvider);
  }

  // ---------------------------------------------------- F7 排序 / N7 字号

  /// 排序选择（官方 Web `sort_info`：`title`/`ctime`/`mtime` × `asc`/`desc`）。
  Future<void> _showSortSheet() async {
    final current = ref.read(noteSortProvider);
    final picked = await showModalBottomSheet<NoteSort>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, Gap.sm),
                child: Text(
                  noteGaps(NoteGapsTextKeys.sort, '排序'),
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              for (final (by, label, key) in [
                (
                  'title',
                  noteGaps(NoteGapsTextKeys.sortByTitle, '按标题'),
                  'note-sort-title',
                ),
                (
                  'ctime',
                  noteGaps(NoteGapsTextKeys.sortByCtime, '按创建时间'),
                  'note-sort-ctime',
                ),
                (
                  'mtime',
                  noteGaps(NoteGapsTextKeys.sortByMtime, '按修改时间'),
                  'note-sort-mtime',
                ),
              ])
                DesignRowTile(
                  key: Key(key),
                  leading: Icon(
                    current.by == by
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(label),
                  onTap: () =>
                      Navigator.of(ctx).pop(current.withBy(by)),
                ),
              const Divider(height: 1),
              for (final (dir, label, key) in [
                ('asc', noteGaps(NoteGapsTextKeys.sortAsc, '升序'), 'note-sort-asc'),
                (
                  'desc',
                  noteGaps(NoteGapsTextKeys.sortDesc, '降序'),
                  'note-sort-desc',
                ),
              ])
                DesignRowTile(
                  key: Key(key),
                  leading: Icon(
                    current.direction == dir
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(label),
                  onTap: () =>
                      Navigator.of(ctx).pop(current.withDirection(dir)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final notifier = ref.read(noteSortProvider.notifier);
    if (picked.by != current.by) notifier.setBy(picked.by);
    if (picked.direction != current.direction) {
      notifier.setDirection(picked.direction);
    }
  }

  /// N7：默认字号设置（7 档，落 KV key `default_font_size`）。
  Future<void> _chooseDefaultFontSize() async {
    final current = ref.read(noteDefaultFontSizeProvider);
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        key: const Key('note-default-font-size-dialog'),
        title: Text(noteGaps(NoteGapsTextKeys.defaultFontSize, '默认字号')),
        children: [
          for (var i = 0; i < kSynoFontSizes.length; i++)
            SimpleDialogOption(
              key: Key('note-default-font-${kSynoFontSizes[i]}'),
              onPressed: () => Navigator.of(ctx).pop(kSynoFontSizes[i]),
              child: Row(
                children: [
                  Icon(
                    current == kSynoFontSizes[i]
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: Gap.sm),
                  Text(kSynoFontSizeLabels[i]),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await ref.read(noteDefaultFontSizeProvider.notifier).set(picked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          noteGaps(NoteGapsTextKeys.defaultFontSizeSet, '默认字号已保存'),
        ),
      ),
    );
  }

  // ---------------------------------------------------- C9/G5 附件文本搜索

  /// 打开/关闭附件文本搜索：本地 KV + 服务端 `Setting/set search_attachment`。
  ///
  /// 关闭时搜索路径**一个附件请求都不发**（见
  /// `noteAttachmentSearchEnabledProvider`），也不会报错。
  Future<void> _toggleAttachmentSearch(bool enabled) async {
    final store = ref.read(chatStoreProvider);
    await store.setSetting(kNoteAttachmentSearchKey, enabled ? 'true' : 'false');
    final api = ref.read(noteApiProvider);
    if (api != null && api.supportsAttachmentText()) {
      try {
        await api.setSearchAttachment(enabled);
      } catch (_) {
        // 服务端不认识这个设置字段 / 无权限：本地开关照常生效，不报错
      }
    }
    ref.invalidate(noteAttachmentSearchPrefProvider);
    ref.invalidate(noteAttachmentSearchEnabledProvider);
    ref.invalidate(noteListProvider);
  }

  // ---------------------------------------------------- A12 多选批量

  List<String> _selectedFrom(List<NoteDto> visible) => visible
      .where((n) => _selectedIds.contains(n.objectId))
      .map((n) => n.objectId)
      .toList();

  /// 批量删除（`Note/delete` v3 `object_id` 数组；老服务端逐条回退）。
  Future<void> _batchDelete(List<NoteDto> visible) async {
    final ids = _selectedFrom(visible);
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(noteGaps(NoteGapsTextKeys.batchDelete, '批量删除')),
        content: Text(
          noteGapsFill(NoteGapsTextKeys.batchDeleteConfirm, '确定删除选中的 {count} 条笔记吗？', {
            'count': '${ids.length}',
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    try {
      final r = await api.deleteNotes(ids, recycle: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            r.hasFailure
                ? noteGapsFill(
                    NoteGapsTextKeys.batchPartial,
                    '已删除 {ok} 条，失败 {fail} 条',
                    {'ok': '${r.succeeded}', 'fail': '${r.failed.length}'},
                  )
                : noteGapsFill(
                    NoteGapsTextKeys.batchDeleted,
                    '已删除 {count} 条笔记',
                    {'count': '${ids.length}'},
                  ),
          ),
        ),
      );
      _exitSelection();
      ref.invalidate(noteListProvider);
      ref.invalidate(notebooksProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            noteGapsFill(NoteGapsTextKeys.batchFailed, '批量操作失败：{error}', {
              'error': describeNoteError(e, context.t),
            }),
          ),
        ),
      );
    }
  }

  /// 批量移动到其它笔记本（`Note/set` v3 `object_id` 数组；回包 `errors[]`
  /// 逐条回报失败项）。
  Future<void> _batchMove(List<NoteDto> visible) async {
    final ids = _selectedFrom(visible);
    if (ids.isEmpty) return;
    final notebooks = ref.read(notebooksProvider).value ?? const <NotebookDto>[];
    if (notebooks.isEmpty) return;
    final target = await showModalBottomSheet<NotebookDto>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, Gap.sm),
              child: Text(
                noteGaps(NoteGapsTextKeys.batchMoveTitle, '移动到笔记本'),
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (final nb in notebooks)
              DesignRowTile(
                key: Key('note-move-target-${nb.objectId}'),
                leading: const Icon(Icons.folder_outlined),
                title: Text(nb.displayTitle),
                onTap: () => Navigator.of(ctx).pop(nb),
              ),
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    try {
      final r = await api.moveNotes(ids, parentId: target.objectId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            r.hasFailure
                ? noteGapsFill(
                    NoteGapsTextKeys.batchPartial,
                    '已移动 {ok} 条，失败 {fail} 条',
                    {'ok': '${r.succeeded}', 'fail': '${r.failed.length}'},
                  )
                : noteGapsFill(
                    NoteGapsTextKeys.batchMoved,
                    '已移动 {count} 条笔记',
                    {'count': '${ids.length}'},
                  ),
          ),
        ),
      );
      _exitSelection();
      ref.invalidate(noteListProvider);
      ref.invalidate(notebooksProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            noteGapsFill(NoteGapsTextKeys.batchFailed, '批量操作失败：{error}', {
              'error': describeNoteError(e, context.t),
            }),
          ),
        ),
      );
    }
  }

  String _emptyTitle(
    BuildContext context,
    String? selected,
    List<NoteDto>? all,
  ) {
    final t = context.t;
    if (ref.read(noteKeywordProvider).trim().isNotEmpty) {
      return t.noteEmptySearch;
    }
    if (selected != null) return t.noteEmptyNotebook;
    if ((all ?? const []).isEmpty) return t.noteEmptyAll;
    return t.noteEmptyGeneric;
  }

  Future<String?> _askTitle(String title, {String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: context.t.noteNotebookName),
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

  /// 新建笔记本（`Notebook/create` v1）
  Future<void> _createNotebook() async {
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final title = await _askTitle(context.t.noteNewNotebook);
    if (title == null || title.isEmpty || !mounted) return;
    try {
      await api.createNotebook(title);
      ref.invalidate(notebooksProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.t.noteNotebookCreateFailed(
                describeNoteError(e, context.t),
              ),
            ),
          ),
        );
      }
    }
  }

  /// 长按笔记本：重命名 / 删除（预置笔记本不允许删，服务端也会拒）
  Future<void> _manageNotebook(NotebookDto nb) async {
    // A14：归档入口**只在服务端有 `Notebook.Polling` 能力位时出现**
    // （缺位时不显示——点了必然失败，见 [canArchive]）。
    final canArchive = ref
        .read(serviceAvailabilityProvider)
        .hasApi(StationService.note, NoteStationApi.notebookPollingApi);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DesignRowTile(title: Text(nb.displayTitle)),
            const Divider(height: 1),
            DesignRowTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: Text(context.t.photoRename),
              onTap: () => Navigator.of(context).pop('rename'),
            ),
            if (canArchive)
              DesignRowTile(
                key: const Key('note-notebook-archive'),
                leading: Icon(
                  nb.archive ? Icons.unarchive_outlined : Icons.archive_outlined,
                ),
                title: Text(
                  nb.archive
                      ? noteWave5(NoteWave5TextKeys.unarchive, '取消归档')
                      : noteWave5(NoteWave5TextKeys.archive, '归档'),
                ),
                onTap: () => Navigator.of(context).pop('archive'),
              ),
            if (!nb.preset)
              DesignRowTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(context.t.noteDeleteNotebookWithNotes),
                onTap: () => Navigator.of(context).pop('delete'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    if (action == 'archive') {
      // 归档/取消归档＝`Notebook.Polling/archive` v1（带 task 轮询），
      // **不是** `Notebook/set` 的字段（`SetNotebookOperation` 只有
      // object_id/title/stack）。
      try {
        await api.archiveNotebook(nb.objectId, enable: !nb.archive);
        ref.invalidate(notebooksProvider);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                nb.archive
                    ? noteWave5(NoteWave5TextKeys.unarchived, '已取消归档')
                    : noteWave5(NoteWave5TextKeys.archived, '已归档'),
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                noteWave5Fill(
                  NoteWave5TextKeys.archiveFailed,
                  '归档失败：{error}',
                  {'error': describeNoteError(e, context.t)},
                ),
              ),
            ),
          );
        }
      }
      return;
    }
    if (action == 'rename') {
      final title = await _askTitle(
        context.t.noteRenameNotebook,
        initial: nb.title,
      );
      if (title == null || title.isEmpty || title == nb.title || !mounted) {
        return;
      }
      try {
        await api.renameNotebook(nb.objectId, title: title, ver: nb.ver);
        ref.invalidate(notebooksProvider);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.t.noteNotebookUpdateFailed(describeNoteError(e)),
              ),
            ),
          );
        }
      }
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t.noteDeleteNotebook),
        content: Text(context.t.noteDeleteNotebookConfirm(nb.displayTitle)),
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
    if (yes != true || !mounted) return;
    try {
      await api.deleteNotebook(nb.objectId);
      if (ref.read(selectedNotebookProvider) == nb.objectId) {
        ref.read(selectedNotebookProvider.notifier).select(null);
      }
      ref.invalidate(notebooksProvider);
      ref.invalidate(noteListProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.t.noteNotebookDeleteFailed(
                describeNoteError(e, context.t),
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _createNote(
    BuildContext context, {
    NotePickSource? initialPickSource,
  }) async {
    final notebooks =
        ref.read(notebooksProvider).value ?? const <NotebookDto>[];
    final note = await Navigator.of(context, rootNavigator: true).push<NoteDto>(
      MaterialPageRoute<NoteDto>(
        builder: (_) => NoteEditorPage(
          notebooks: notebooks,
          // C5：从相机/视频新建 —— 编辑器首帧后自动调起拍摄/选视频。
          initialPickSource: initialPickSource,
        ),
      ),
    );
    if (note != null && mounted) {
      ref.invalidate(noteListProvider);
      ref.invalidate(notebooksProvider);
    }
  }
}

/// G4：标签 + 操作符（AND/OR）筛选面板。
///
/// 取值只可能是 `and` / `or`：官方 Web `AdvancedSearch` 的勾选框
/// `tag_operator`（不勾 = `"or"`，勾上 = `"and"`）。
class _TagFilterSheet extends StatefulWidget {
  const _TagFilterSheet({
    required this.all,
    required this.initial,
    required this.initialOperator,
  });

  final List<String> all;
  final List<String> initial;
  final String initialOperator;

  @override
  State<_TagFilterSheet> createState() => _TagFilterSheetState();
}

class _TagFilterSheetState extends State<_TagFilterSheet> {
  late final Set<String> _picked = {...widget.initial};
  late String _operator = widget.initialOperator;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      key: const Key('note-tag-filter-sheet'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              noteWave5(NoteWave5TextKeys.filterByTags, '按标签筛选'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.xs),
            SegmentedButton<String>(
              key: const Key('note-tag-operator'),
              segments: [
                ButtonSegment(
                  value: NoteStationApi.tagOperatorOr,
                  label: Text(
                    noteWave5(NoteWave5TextKeys.tagOperatorOr, '任一标签（OR）'),
                  ),
                ),
                ButtonSegment(
                  value: NoteStationApi.tagOperatorAnd,
                  label: Text(
                    noteWave5(NoteWave5TextKeys.tagOperatorAnd, '全部标签（AND）'),
                  ),
                ),
              ],
              selected: {_operator},
              onSelectionChanged: (s) => setState(() => _operator = s.first),
            ),
            const SizedBox(height: Gap.sm),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final tag in widget.all)
                      DesignCheckRow(
                        key: Key('note-tag-filter-$tag'),
                        dense: true,
                        value: _picked.contains(tag),
                        title: Text(tag),
                        onChanged: (v) => setState(() {
                          if (v) {
                            _picked.add(tag);
                          } else {
                            _picked.remove(tag);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                TextButton(
                  key: const Key('note-tag-filter-reset'),
                  onPressed: () => setState(_picked.clear),
                  child: Text(
                    noteWave5(NoteWave5TextKeys.clearTagFilter, '清除标签筛选'),
                  ),
                ),
                const Spacer(),
                FilledButton(
                  style: InlineButtonStyle.filled,
                  key: const Key('note-tag-filter-apply'),
                  onPressed: () => Navigator.of(context).pop((
                    tags: _picked.toList(growable: false),
                    op: _operator,
                  )),
                  child: Text(context.t.actionSave),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 宽屏右栏（r283）
//
// 只在**宽屏（expanded）或竖向折痕分栏**时被 `AdaptiveScaffold` 插进树里；
// 窄屏（compact/medium）连 build 都不会发生 ⇒ 窄屏行为/渲染子树与改动前一致。

/// 宽屏右栏：**未选中笔记**时的占位（纯静态，不含任何可点内容）。
class _NoteWideEmpty extends StatelessWidget {
  const _NoteWideEmpty();

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Container(
      key: const Key('note-wide-empty'),
      color: hud.bg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sticky_note_2_outlined, size: 48, color: hud.dim),
          const SizedBox(height: Gap.sm),
          Text(
            context.t.noteEmptyGeneric,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// 宽屏右栏：**笔记预览**（只读）。
///
/// 设计纪律：
///   * **不复制** `NoteViewPage` 的整页逻辑 —— 右栏只渲染"标题 / 笔记本 /
///     正文纯文本"这几项，且**不做任何写操作**；
///   * 「打开」把 `NoteViewPage` 推到**根路由**，因此宽屏与窄屏最终去到的是
///     **同一个页面**（§2.0.8④「入口不同不许走到不同实现」）；
///   * 字号一律用主题既有档位，**不新设字号**（§2.0.18）；
///   * `noteDetailProvider` 取值失败/未返回时回落列表已有的 `brief`，
///     **不弹错误视图**（列表页不该因为右栏取不到正文就变成错误页）。
class _NoteWideDetail extends ConsumerWidget {
  const _NoteWideDetail({required this.note, required this.fromCache});

  final NoteDto note;
  final bool fromCache;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final detail = ref.watch(noteDetailProvider(note.objectId));
    final full = detail.value?.note ?? note;
    final text = full.content.isNotEmpty && full.hasContent
        ? notePlainText(full.content)
        : full.brief;
    final notebookTitle = ref
        .watch(notebooksProvider)
        .value
        ?.where((n) => n.objectId == full.parentId)
        .map((n) => n.displayTitle)
        .firstOrNull;

    return Scaffold(
      key: const Key('note-wide-detail'),
      backgroundColor: hud.bg,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          full.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const Key('note-wide-open'),
            tooltip: context.t.fileOpen,
            icon: const Icon(Icons.open_in_new),
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => NoteViewPage(note: note, fromCache: fromCache),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          if (notebookTitle != null)
            Text(notebookTitle, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: Gap.sm),
          if (text.trim().isEmpty)
            Text(
              context.t.noteEmptyGeneric,
              style: Theme.of(context).textTheme.bodyMedium,
            )
          else
            Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
