// C3（NoteStation 补齐）的界面：导出面板 / 导入面板 / 网页剪藏 / 版本历史。
//
// 这里只做「确认 + 提示 + 进度」，真正的接口流程在 `note_c3_actions.dart`。
// 关键纪律：**每个危险动作（回滚 / 导入）都先弹确认框；取消 → 直接 return，
// 不碰任何 provider、不发任何请求**（用例 `note_c3_pages_test.dart` 有断言）。
//
// 另一个坑：bottom sheet 的 `Consumer` 里的 `ref` 在 sheet 关闭后就失效，
// 所以动作一律用**页面级**的 `ref`/`context`（函数参数），sheet 里的只用来 watch。
import '../../design/kit/design_kit.dart';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/note_c3_dto.dart';
import '../../data/dto/note_dto.dart';
import '../files/file_row.dart' show formatFileTime;
import 'note_body.dart';
import 'note_c3_actions.dart';
import 'note_c3_providers.dart';
import 'note_c3_text.dart';
import 'note_providers.dart';
import 'note_wave4_text.dart';

// ---------------------------------------------------------------- 文件选择

/// 选一个本地归档文件（`.nsx` / `.enex`）。测试里覆盖成假的。
typedef NoteArchivePicker =
    Future<({String path, String name})?> Function({
      required List<String> allowedExtensions,
    });

final noteArchivePickerProvider = Provider<NoteArchivePicker>(
  (ref) => pickNoteArchive,
);

Future<({String path, String name})?> pickNoteArchive({
  required List<String> allowedExtensions,
}) async {
  final f = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
  );
  if (f == null || f.path == null) return null;
  return (path: f.path!, name: f.name);
}

// ---------------------------------------------------------------- 可用性工具

/// 未检测（null）→ fail-open（可见）
bool _shows(NoteC3Availability? a, NoteC3Feature f) =>
    a == null ? true : a.shows(f);

/// 明确 `105`/`160` → 隐藏入口 + 提示
bool _denied(NoteC3Availability? a, NoteC3Feature f) => a?.isDenied(f) ?? false;

Widget _deniedTile(String label) => DesignRowTile(
  key: const Key('note-c3-denied'),
  enabled: false,
  leading: const Icon(Icons.lock_outline),
  title: Text(label),
  subtitle: Text(noteC3NoPermissionHintText()),
);

Widget _sessionTile() => DesignRowTile(
  key: const Key('note-c3-session'),
  leading: const Icon(Icons.schedule),
  title: Text(noteC3SessionText()),
);

Widget _sheetTitle(BuildContext ctx, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
  child: Align(
    alignment: Alignment.centerLeft,
    child: Text(text, style: Theme.of(ctx).textTheme.titleMedium),
  ),
);

// ---------------------------------------------------------------- 导出面板

/// 单条笔记的导出面板：Word（`Export.Word`）/ `.nsx`（`Export.Note`）。
Future<void> showNoteExportSheet(
  BuildContext context,
  WidgetRef ref,
  NoteDto note,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Consumer(
      builder: (ctx, r, _) {
        final a = r.watch(noteC3AvailabilityProvider).value;
        final tiles = <Widget>[
          if (_denied(a, NoteC3Feature.exportWord))
            _deniedTile(noteC3(NoteC3TextKeys.exportWord, '导出为 Word 文档'))
          else if (_shows(a, NoteC3Feature.exportWord))
            DesignRowTile(
              key: const Key('note-c3-export-word'),
              leading: const Icon(Icons.description_outlined),
              title: Text(noteC3(NoteC3TextKeys.exportWord, '导出为 Word 文档')),
              subtitle: Text(
                noteC3(NoteC3TextKeys.exportWordHint, '服务端生成 .docx'),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(
                  runNoteExport(context, ref, note, NoteExportFormat.word),
                );
              },
            ),
          if (_denied(a, NoteC3Feature.exportNote))
            _deniedTile(noteC3(NoteC3TextKeys.exportNote, '导出为归档 .nsx'))
          else if (_shows(a, NoteC3Feature.exportNote))
            DesignRowTile(
              key: const Key('note-c3-export-note'),
              leading: const Icon(Icons.archive_outlined),
              title: Text(noteC3(NoteC3TextKeys.exportNote, '导出为归档 .nsx')),
              subtitle: Text(
                noteC3(
                  NoteC3TextKeys.exportNoteHint,
                  'NoteStation 自己的归档格式（可再导入）',
                ),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(
                  runNoteExport(context, ref, note, NoteExportFormat.note),
                );
              },
            ),
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (a?.sessionExpired == true) _sessionTile(),
              _sheetTitle(ctx, noteC3(NoteC3TextKeys.exportTitle, '导出笔记')),
              if (tiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Text(noteC3NoPermissionText()),
                )
              else
                ...tiles,
            ],
          ),
        );
      },
    ),
  );
}

/// 执行导出（带进度框），结束给 SnackBar。**导出不是危险操作，无需确认**。
Future<void> runNoteExport(
  BuildContext context,
  WidgetRef ref,
  NoteDto note,
  NoteExportFormat format,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  // 任务态：先"已提交导出任务"，服务端 `status.finish` 且下载落盘后才说"已导出到"。
  // **下载没成功前绝不显示完成**（任务口径：不谎报导出完成）。
  final submitted = noteWave4(
    NoteWave4TextKeys.exportSubmitted,
    '已提交导出任务，正在服务端生成…',
  );
  final progress = ValueNotifier<String>(submitted);
  var dialogOpen = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProgressDialog(label: progress),
    ).whenComplete(() => dialogOpen = false),
  );
  try {
    final name = await exportNoteFile(
      ref,
      note: note,
      format: format,
      // ★ 导出**不调起外部应用**：只落到本机下载目录（用户明确要求本机测试
      //   不要弹 Preview/QuickTime）。打开与否由用户自己决定。
      openAfter: false,
      onPoll: (n) => progress.value = n == 0 ? submitted : '$submitted ($n)',
    );
    if (dialogOpen) navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          noteWave4Fill(NoteWave4TextKeys.exportSaved, '已导出到 {name}', {
            'name': name,
          }),
        ),
      ),
    );
  } catch (e) {
    if (dialogOpen) navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          noteC3Fill(NoteC3TextKeys.exportFailed, '导出失败：{error}', {
            'error': describeNoteExportError(e),
          }),
        ),
      ),
    );
  } finally {
    progress.dispose();
  }
}

/// 笔记本导出到 NAS 目录（`Export.Notebook`）。
///
/// 它是唯一"写服务端目录"的导出：`dest` 由用户显式填（官方用 FileChooser 挑
/// 共享文件夹，见实现文档的「待取证」）。
Future<void> showNoteNotebookExportDialog(BuildContext context, WidgetRef ref) {
  final notebooks = ref.read(notebooksProvider).value ?? const <NotebookDto>[];
  return showDialog<void>(
    context: context,
    builder: (_) => _NotebookExportDialog(notebooks: notebooks),
  );
}

class _NotebookExportDialog extends ConsumerStatefulWidget {
  const _NotebookExportDialog({required this.notebooks});

  final List<NotebookDto> notebooks;

  @override
  ConsumerState<_NotebookExportDialog> createState() =>
      _NotebookExportDialogState();
}

class _NotebookExportDialogState extends ConsumerState<_NotebookExportDialog> {
  final _dest = TextEditingController();
  String? _notebookId;
  bool _saveConfig = false;
  bool _exportTodo = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _notebookId = widget.notebooks.isEmpty
        ? null
        : widget.notebooks.first.objectId;
  }

  @override
  void dispose() {
    _dest.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final notebookId = _notebookId;
    if (notebookId == null) return;
    if (_dest.text.trim().isEmpty) {
      setState(
        () => _error = noteC3(NoteC3TextKeys.exportDestHint, '例如 /notes'),
      );
      return; // ★ 参数不全 → 零请求
    }
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final progress = ValueNotifier<String>(
      noteC3(NoteC3TextKeys.exportStarted, '正在导出…'),
    );
    var dialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ProgressDialog(label: progress),
      ).whenComplete(() => dialogOpen = false),
    );
    try {
      await exportNotebookToNas(
        ref,
        notebookId: notebookId,
        dest: _dest.text,
        saveConfig: _saveConfig,
        exportTodo: _exportTodo,
        onProgress: (st) => progress.value =
            '${noteC3(NoteC3TextKeys.exportStarted, '正在导出…')} ${st.percent}%',
      );
      if (dialogOpen) navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            noteC3(NoteC3TextKeys.exportNotebookDone, '已导出到 NAS 目录'),
          ),
        ),
      );
    } catch (e) {
      if (dialogOpen) navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            noteC3Fill(NoteC3TextKeys.exportFailed, '导出失败：{error}', {
              'error': describeNoteC3Error(e),
            }),
          ),
        ),
      );
    } finally {
      progress.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('note-c3-notebook-export-dialog'),
    title: Text(noteC3(NoteC3TextKeys.exportNotebook, '导出笔记本到 NAS')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.notebooks.isNotEmpty)
            DropdownButtonFormField<String>(
              isExpanded: true,
              key: const Key('note-c3-notebook-export-nb'),
              initialValue: _notebookId,
              decoration: InputDecoration(
                labelText: noteC3(NoteC3TextKeys.exportNotebook, '笔记本'),
              ),
              items: [
                for (final nb in widget.notebooks)
                  DropdownMenuItem(
                    value: nb.objectId,
                    child: Text(nb.displayTitle),
                  ),
              ],
              onChanged: (v) => setState(() => _notebookId = v),
            ),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('note-c3-notebook-export-dest'),
            controller: _dest,
            decoration: InputDecoration(
              labelText: noteC3(NoteC3TextKeys.exportDest, '目标目录'),
              hintText: noteC3(NoteC3TextKeys.exportDestHint, '例如 /notes'),
            ),
          ),
          DesignSwitchRow(
            key: const Key('note-c3-notebook-export-config'),
            value: _saveConfig,
            contentPadding: EdgeInsets.zero,
            title: Text(noteC3(NoteC3TextKeys.exportSaveConfig, '同时导出应用设置')),
            onChanged: (v) => setState(() => _saveConfig = v),
          ),
          DesignSwitchRow(
            key: const Key('note-c3-notebook-export-todo'),
            value: _exportTodo,
            contentPadding: EdgeInsets.zero,
            title: Text(noteC3(NoteC3TextKeys.exportTodo, '同时导出待办')),
            onChanged: (v) => setState(() => _exportTodo = v),
          ),
          if (_error != null)
            Text(
              _error!,
              key: const Key('note-c3-notebook-export-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const Key('note-c3-notebook-export-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.t.actionCancel),
      ),
      FilledButton(
        key: const Key('note-c3-notebook-export-ok'),
        onPressed: _run,
        child: Text(context.t.actionOk),
      ),
    ],
  );
}

// ---------------------------------------------------------------- 导入面板

/// 导入面板：`.nsx` / `.enex` / Evernote 账号。
Future<void> showNoteImportSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Consumer(
      builder: (ctx, r, _) {
        final a = r.watch(noteC3AvailabilityProvider).value;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (a?.sessionExpired == true) _sessionTile(),
              _sheetTitle(ctx, noteC3(NoteC3TextKeys.importTitle, '导入笔记')),
              _importTile(
                a,
                context,
                ref,
                feature: NoteC3Feature.importNotebook,
                keyName: 'note-c3-import-nsx',
                icon: Icons.archive_outlined,
                title: noteC3(NoteC3TextKeys.importNotebook, '从 .nsx 导入'),
                subtitle: noteC3(
                  NoteC3TextKeys.importNotebookHint,
                  'NoteStation 归档文件',
                ),
                extensions: const ['nsx'],
                kind: NoteImportKind.notebook,
              ),
              _importTile(
                a,
                context,
                ref,
                feature: NoteC3Feature.importEnex,
                keyName: 'note-c3-import-enex',
                icon: Icons.note_add_outlined,
                title: noteC3(NoteC3TextKeys.importEnex, '从 Evernote .enex 导入'),
                subtitle: noteC3(
                  NoteC3TextKeys.importEnexHint,
                  'Evernote 导出的 .enex 文件',
                ),
                extensions: const ['enex'],
                kind: NoteImportKind.enex,
              ),
              if (_denied(a, NoteC3Feature.importEvernote))
                _deniedTile(
                  noteC3(NoteC3TextKeys.importEvernote, '从 Evernote 账号导入'),
                )
              else if (_shows(a, NoteC3Feature.importEvernote))
                DesignRowTile(
                  key: const Key('note-c3-import-evernote'),
                  leading: const Icon(Icons.cloud_download_outlined),
                  title: Text(
                    noteC3(NoteC3TextKeys.importEvernote, '从 Evernote 账号导入'),
                  ),
                  subtitle: Text(
                    noteC3(
                      NoteC3TextKeys.importEvernoteHint,
                      '连接 Evernote 账号后选择笔记本',
                    ),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(
                      Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const NoteC3EvernoteImportPage(),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    ),
  );
}

Widget _importTile(
  NoteC3Availability? a,
  BuildContext pageContext,
  WidgetRef ref, {
  required NoteC3Feature feature,
  required String keyName,
  required IconData icon,
  required String title,
  required String subtitle,
  required List<String> extensions,
  required NoteImportKind kind,
}) {
  if (_denied(a, feature)) return _deniedTile(title);
  if (!_shows(a, feature)) return const SizedBox.shrink();
  return DesignRowTile(
    key: Key(keyName),
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    onTap: () {
      Navigator.of(pageContext).pop();
      unawaited(
        runNoteImport(pageContext, ref, kind: kind, extensions: extensions),
      );
    },
  );
}

/// 选文件 → **二次确认** → 上传并轮询。
///
/// 确认框取消 → 直接返回，**零请求**。
Future<void> runNoteImport(
  BuildContext context,
  WidgetRef ref, {
  required NoteImportKind kind,
  required List<String> extensions,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final picked = await ref.read(noteArchivePickerProvider)(
    allowedExtensions: extensions,
  );
  if (picked == null) return;
  if (!context.mounted) return;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('note-c3-import-confirm'),
      title: Text(noteC3(NoteC3TextKeys.import, '导入')),
      content: Text(
        noteC3(
          NoteC3TextKeys.importOverwriteHint,
          '导入会把文件里的笔记本/笔记并入当前账号，可能产生同名内容。确定继续？',
        ),
      ),
      actions: [
        TextButton(
          key: const Key('note-c3-import-cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(
          key: const Key('note-c3-import-ok'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(context.t.actionOk),
        ),
      ],
    ),
  );
  if (ok != true) return; // ★ 取消 → 零请求
  if (!context.mounted) return;

  final progress = ValueNotifier<String>(
    noteC3(NoteC3TextKeys.importing, '正在导入…'),
  );
  final cancel = NoteC3Cancel();
  var dialogOpen = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProgressDialog(
        label: progress,
        // ★ 长任务可取消：置位后轮询循环会调 `Import.<kind>/stop`
        onCancel: cancel.cancel,
      ),
    ).whenComplete(() => dialogOpen = false),
  );
  try {
    await importNoteArchive(
      ref,
      kind: kind,
      path: picked.path,
      fileName: picked.name,
      cancel: cancel,
      onProgress: (st) => progress.value = st.total <= 0
          ? noteC3(NoteC3TextKeys.importing, '正在导入…')
          : noteC3Fill(NoteC3TextKeys.importProgress, '正在导入… {percent}%', {
              'percent': '${st.percent}',
            }),
    );
    if (dialogOpen) navigator.pop();
    messenger.showSnackBar(
      SnackBar(content: Text(noteC3(NoteC3TextKeys.importDone, '导入完成'))),
    );
  } on NoteC3CancelledException {
    if (dialogOpen) navigator.pop();
    messenger.showSnackBar(
      SnackBar(content: Text(noteC3(NoteC3TextKeys.importCancelled, '已取消'))),
    );
  } catch (e) {
    if (dialogOpen) navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          noteC3Fill(NoteC3TextKeys.importFailed, '导入失败：{error}', {
            'error': describeNoteC3Error(e),
          }),
        ),
      ),
    );
  } finally {
    progress.dispose();
  }
}

// ---------------------------------------------------------------- 网页剪藏

/// 网页剪藏对话框：网址 + 标题 + 目标笔记本。
Future<void> showNoteClipDialog(BuildContext context, WidgetRef ref) {
  final notebooks = ref.read(notebooksProvider).value ?? const <NotebookDto>[];
  return showDialog<void>(
    context: context,
    builder: (_) => _ClipDialog(notebooks: notebooks),
  );
}

class _ClipDialog extends ConsumerStatefulWidget {
  const _ClipDialog({required this.notebooks});

  final List<NotebookDto> notebooks;

  @override
  ConsumerState<_ClipDialog> createState() => _ClipDialogState();
}

class _ClipDialogState extends ConsumerState<_ClipDialog> {
  final _url = TextEditingController();
  final _title = TextEditingController();
  String? _notebookId;

  /// 官方设置键 `clipper_retrieve_type` 的两个取值（[E2] `ClipperService`）
  String _retrieveType = 'simplified';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _notebookId = widget.notebooks.isEmpty
        ? null
        : widget.notebooks.first.objectId;
  }

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!isValidClipUrl(_url.text)) {
      setState(
        () => _error = noteC3(
          NoteC3TextKeys.clipInvalidUrl,
          '请输入以 http:// 或 https:// 开头的网址',
        ),
      );
      return; // ★ 校验失败 → 零请求
    }
    final notebookId = _notebookId;
    if (notebookId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await clipWebPage(
        ref,
        url: _url.text,
        title: _title.text.isEmpty ? _url.text : _title.text,
        notebookId: notebookId,
        retrieveType: _retrieveType,
      );
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            noteC3(
              NoteC3TextKeys.clipSaved,
              '已提交剪藏：服务端会按所选模式抓取正文，稍后同步到列表。',
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeNoteC3Error(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('note-c3-clip-dialog'),
      title: Text(noteC3(NoteC3TextKeys.clipTitle, '剪藏网页')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('note-c3-clip-url'),
              controller: _url,
              autofocus: true,
              decoration: InputDecoration(
                labelText: noteC3(NoteC3TextKeys.clipUrl, '网页地址'),
                hintText: 'https://',
              ),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              key: const Key('note-c3-clip-name'),
              controller: _title,
              decoration: InputDecoration(
                labelText: noteC3(NoteC3TextKeys.clipName, '标题'),
              ),
            ),
            const SizedBox(height: Gap.md),
            if (widget.notebooks.isNotEmpty)
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: const Key('note-c3-clip-notebook'),
                initialValue: _notebookId,
                decoration: InputDecoration(
                  labelText: noteC3(NoteC3TextKeys.clipNotebook, '保存到笔记本'),
                ),
                items: [
                  for (final nb in widget.notebooks)
                    DropdownMenuItem(
                      value: nb.objectId,
                      child: Text(nb.displayTitle),
                    ),
                ],
                onChanged: (v) => setState(() => _notebookId = v),
              ),
            const SizedBox(height: Gap.sm),
            // 官方设置 `clipper_retrieve_type`：简 / 全（映射到 clipper_mode）
            SegmentedButton<String>(
              key: const Key('note-c3-clip-mode'),
              segments: [
                ButtonSegment(
                  value: 'simplified',
                  label: Text(
                    noteC3(NoteC3TextKeys.clipModeSimple, '简化正文'),
                  ),
                ),
                ButtonSegment(
                  value: 'whole',
                  label: Text(noteC3(NoteC3TextKeys.clipModeFull, '完整网页')),
                ),
              ],
              selected: {_retrieveType},
              onSelectionChanged: (s) =>
                  setState(() => _retrieveType = s.first),
            ),
            const SizedBox(height: Gap.sm),
            Text(
              // ★ r343 D52：原文案把四个服务端参数名当说明文字
              // （`clipper_url`/`clipper_mode`/`clipper_user_agent`/`source_url`）。
              // 用户要知道的是"服务端会去抓这个网页、并记下来源网址"。
              noteC3(
                NoteC3TextKeys.clipHint,
                // ★ r343 D53：上一版（27 字）在真机上把弹层内容顶出首屏
                // （`content` 是 `SingleChildScrollView` ⇒ 可滚动、非硬截断，
                // 但首屏只画到 `…保存来源`）。按 §2.0.18 **改文案**到一行放得下。
                '由 NAS 抓取网页正文，并保存来源网址',
              ),
              style: TextStyle(color: DesignPalette.of(context).dim, fontSize: 12),
            ),
            if (_error != null) ...[
              const SizedBox(height: Gap.sm),
              Text(
                _error!,
                key: const Key('note-c3-clip-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('note-c3-clip-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(
          key: const Key('note-c3-clip-ok'),
          onPressed: _busy ? null : _save,
          child: Text(context.t.actionOk),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 版本历史

/// 历史版本页（列表）。官方是弹窗（`Info.History.Window`），这里做成整页，
/// 好放下预览。
/// 版本历史一行给**人看**的标题：官方 `Info.History.Window` 的表格列就是
/// `modify_time` / `username` / `device_name`，**没有 version 列**。
///
/// ⚠️ 版本 `version`（hash）与 `id` 都是服务端内部标识，一律**不上屏**；
/// 界面上只出现时间 / 作者 / 设备（见任务口径与 `note-parity-audit.md`）。
String noteVersionWhenLabel(NoteVersionDto v) {
  final when = formatFileTime(v.mtime);
  if (when.isNotEmpty) return when;
  // 时间读不到时给一个**没有内部 id** 的兜底标签，绝不用 hash 顶上去
  return noteC3(NoteC3TextKeys.versionLabel, '版本');
}

class NoteVersionPage extends ConsumerWidget {
  const NoteVersionPage({super.key, required this.note});

  final NoteDto note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final versions = ref.watch(noteVersionsTypedProvider(note.objectId));
    return Scaffold(
      appBar: AppBar(title: Text(noteC3(NoteC3TextKeys.versionTitle, '版本历史'))),
      body: versions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppErrorView(
          title: t.noteHistoryFailed,
          // 用 C3 的错误映射：`105`/`160` → 无权限文案（`describeNoteError`
          // 只认 `160`，105 会掉到通用描述里）
          detail: describeNoteC3Error(e),
          onRetry: () =>
              ref.invalidate(noteVersionsTypedProvider(note.objectId)),
        ),
        data: (rows) => rows.isEmpty
            ? AppEmptyState(
                icon: Icons.history,
                title: noteC3(NoteC3TextKeys.versionEmpty, '没有历史版本'),
                compact: true,
              )
            : ListView.builder(
                itemCount: rows.length,
                itemBuilder: (ctx, i) {
                  final v = rows[i];
                  return DesignRowTile(
                    key: Key('note-c3-version-${v.version}'),
                    leading: const Icon(Icons.history),
                    title: Text(
                      noteVersionWhenLabel(v),
                      key: const Key('note-c3-version-when'),
                    ),
                    subtitle: Text(noteVersionSubtitle(v)),
                    onTap: () =>
                        Navigator.of(context, rootNavigator: true).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                NoteVersionPreviewPage(note: note, version: v),
                          ),
                        ),
                    trailing: TextButton(
                      key: Key('note-c3-restore-${v.version}'),
                      onPressed: () =>
                          confirmRestoreVersion(context, ref, note, v),
                      child: Text(noteC3(NoteC3TextKeys.versionRestore, '恢复')),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// 单个历史版本的预览页（标题 + 正文 + 恢复 / 复制为新笔记）。
class NoteVersionPreviewPage extends ConsumerWidget {
  const NoteVersionPreviewPage({
    super.key,
    required this.note,
    required this.version,
  });

  final NoteDto note;
  final NoteVersionDto version;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final key = (objectId: note.objectId, ver: version.version);
    final detail = ref.watch(noteVersionDetailProvider(key));
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${note.displayTitle} · ${noteVersionWhenLabel(version)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const Key('note-c3-preview-copy'),
            tooltip: noteC3(NoteC3TextKeys.versionCopyToNew, '复制为新笔记'),
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () => unawaited(copyVersion(context, ref)),
          ),
          IconButton(
            key: const Key('note-c3-preview-restore'),
            tooltip: noteC3(NoteC3TextKeys.versionRestore, '恢复'),
            icon: const Icon(Icons.restore),
            onPressed: () =>
                unawaited(confirmRestoreVersion(context, ref, note, version)),
          ),
        ],
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppErrorView(
          title: t.noteOpenFailed,
          detail: describeNoteC3Error(e),
          onRetry: () => ref.invalidate(noteVersionDetailProvider(key)),
        ),
        data: (d) => NoteBody(html: d.note.content, note: d.note),
      ),
    );
  }

  Future<void> copyVersion(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await copyVersionToNewNote(
        ref,
        note: note,
        ver: version.version,
        title: '${note.displayTitle} - ${noteVersionWhenLabel(version)}',
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(noteC3(NoteC3TextKeys.versionCopyToNew, '已复制为新笔记')),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeNoteC3Error(e))));
    }
  }
}

/// 回滚的**二次确认**。取消 → 零请求。
Future<void> confirmRestoreVersion(
  BuildContext context,
  WidgetRef ref,
  NoteDto note,
  NoteVersionDto version,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('note-c3-restore-confirm'),
      title: Text(noteC3(NoteC3TextKeys.versionRestoreConfirm, '恢复到这个版本？')),
      content: Text(
        noteC3Fill(
          NoteC3TextKeys.versionRestoreBody,
          '当前内容会被 {version} 这一版覆盖（旧内容仍保留在历史里）。确定恢复？',
          {'version': noteVersionWhenLabel(version)},
        ),
      ),
      actions: [
        TextButton(
          key: const Key('note-c3-restore-cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(
          key: const Key('note-c3-restore-ok'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(context.t.actionOk),
        ),
      ],
    ),
  );
  if (ok != true) return; // ★ 取消 → 零请求
  try {
    await restoreNoteVersion(
      ref,
      objectId: note.objectId,
      ver: version.version,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(noteC3(NoteC3TextKeys.versionRestored, '已恢复到该版本')),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          noteC3Fill(NoteC3TextKeys.versionRestoreFailed, '恢复失败：{error}', {
            'error': describeNoteC3Error(e),
          }),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Evernote 云导入

/// 从 Evernote 账号导入（官方 `Import.Evernote` 向导的离线可实现子集）：
/// `get_oauth_url` → 浏览器授权 → `check_oauth_token` 轮询 →
/// `prepare_notebooks(_status)` → `list_notebooks` → 选一个 →
/// `add_import_task` + `import` → 轮询 `get_status`。
class NoteC3EvernoteImportPage extends ConsumerStatefulWidget {
  const NoteC3EvernoteImportPage({super.key, this.serverName = ''});

  /// `get_oauth_url` 的 `server` 参数（官方 `getServerName()`）
  final String serverName;

  @override
  ConsumerState<NoteC3EvernoteImportPage> createState() =>
      _NoteC3EvernoteImportPageState();
}

class _NoteC3EvernoteImportPageState
    extends ConsumerState<NoteC3EvernoteImportPage> {
  NoteEvernoteStatusDto? _status;
  List<NoteEvernoteNotebookDto> _notebooks = const [];
  String? _error;
  bool _busy = false;

  /// `add_import_task` 的 `merge_notebook`（官方向导的同名开关）
  bool _mergeNotebook = false;

  /// `Import.Evernote / import_lock` → `{lock}`（非空表示服务端导入被锁）
  String _lock = '';

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    setState(() => _busy = true);
    try {
      final st = await api.evernoteStatus();
      // `import_lock` 是官方向导会先看的互斥位；拿不到不算错
      String lock = '';
      try {
        lock = await api.evernoteImportLock();
      } catch (_) {
        lock = '';
      }
      if (!mounted) return;
      setState(() {
        _status = st;
        _lock = lock;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeNoteC3Error(e);
        _busy = false;
      });
    }
  }

  /// 打开系统浏览器完成 Evernote 授权（官方 `window.open(get_oauth_url)`）。
  Future<void> _openOAuth() async {
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final url = api.evernoteOAuthUrl(widget.serverName);
    final ok = await ref.read(noteUrlOpenerProvider)(Uri.parse(url));
    if (!mounted) return;
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            noteC3Fill(
              NoteC3TextKeys.importEvernoteBrowserFailed,
              '打不开浏览器，请手动访问：{url}',
              {'url': url},
            ),
          ),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          noteC3(
            NoteC3TextKeys.importEvernoteHint,
            '已在浏览器打开 Evernote 授权页；完成后回到本页点「刷新」。',
          ),
        ),
      ),
    );
  }

  Future<void> _prepare() async {
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    setState(() => _busy = true);
    try {
      await api.evernotePrepareNotebooks();
      for (var i = 0; i < noteC3MaxPolls; i++) {
        final done = await api.evernotePrepareNotebooksStatus();
        if (done) break;
        await Future<void>.delayed(ref.read(noteC3PollIntervalProvider));
      }
      final list = await api.evernoteListNotebooks();
      if (!mounted) return;
      setState(() {
        _notebooks = list;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeNoteC3Error(e);
        _busy = false;
      });
    }
  }

  Future<void> _import(NoteEvernoteNotebookDto nb) async {
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.evernoteAddImportTask(
        notebookGuid: nb.guid,
        mergeNotebook: _mergeNotebook,
      );
      await api.startEvernoteImport();
      messenger.showSnackBar(
        SnackBar(content: Text(noteC3(NoteC3TextKeys.importing, '正在导入…'))),
      );
      await _refresh();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            noteC3Fill(NoteC3TextKeys.importFailed, '导入失败：{error}', {
              'error': describeNoteC3Error(e),
            }),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = _status;
    return Scaffold(
      appBar: AppBar(
        title: Text(noteC3(NoteC3TextKeys.importEvernote, '从 Evernote 账号导入')),
      ),
      body: _error != null
          ? AppErrorView(
              // `noteC3ImportFailed` 在 ARB 里带 `{error}`：必须用 Fill 替换，
              // 否则装了翻译表后会显示「导入失败：{error}」。错误正文就在这里，
              // 不必再用 detail 重复一遍。
              title: noteC3Fill(
                NoteC3TextKeys.importFailed,
                '导入失败：{error}',
                {'error': _error!},
              ),
              onRetry: () {
                setState(() => _error = null);
                unawaited(_refresh());
              },
            )
          : ListView(
              padding: const EdgeInsets.all(Gap.lg),
              children: [
                if (_busy) const LinearProgressIndicator(),
                DesignRowTile(
                  key: const Key('note-c3-evernote-auth'),
                  leading: const Icon(Icons.login),
                  title: Text(noteC3(NoteC3TextKeys.importEvernote, '授权')),
                  subtitle: Text(
                    st == null
                        ? '—'
                        : 'token=${st.token} notebooks=${st.notebookCount - st.notebookLeft}'
                              '${_lock.isEmpty ? '' : '  lock=$_lock'}',
                  ),
                  // 审计 §6.3：原来只在 SnackBar 里显示链接、**不打开浏览器**。
                  // 现在真的调用系统浏览器打开 `get_oauth_url`。
                  onTap: _busy ? null : () => unawaited(_openOAuth()),
                ),
                DesignSwitchRow(
                  key: const Key('note-c3-evernote-merge'),
                  value: _mergeNotebook,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _mergeNotebook = v),
                  title: Text(
                    noteC3(NoteC3TextKeys.importEvernoteMerge, '合并同名笔记本'),
                  ),
                  subtitle: Text(
                    noteC3(
                      NoteC3TextKeys.importEvernoteMergeHint,
                      'add_import_task 的 merge_notebook 参数',
                    ),
                  ),
                ),
                if (_lock.isNotEmpty)
                  DesignRowTile(
                    key: const Key('note-c3-evernote-lock'),
                    leading: const Icon(Icons.lock_outline),
                    title: Text(
                      noteC3Fill(
                        NoteC3TextKeys.importEvernoteLock,
                        '服务端导入被锁定：{lock}',
                        {'lock': _lock},
                      ),
                    ),
                  ),
                DesignRowTile(
                  key: const Key('note-c3-evernote-prepare'),
                  leading: const Icon(Icons.refresh),
                  title: Text(noteC3(NoteC3TextKeys.importApplying, '准备笔记本')),
                  onTap: _busy ? null : () => unawaited(_prepare()),
                ),
                for (final nb in _notebooks)
                  DesignRowTile(
                    key: Key('note-c3-evernote-nb-${nb.guid}'),
                    leading: const Icon(Icons.book_outlined),
                    title: Text(nb.displayName),
                    onTap: _busy ? null : () => unawaited(_import(nb)),
                  ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------- 进度框

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.label, this.onCancel});

  final ValueNotifier<String> label;

  /// 非空时给一个「取消」按钮（导入这类长任务可中途收手）
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => AlertDialog(
    content: Row(
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: Gap.lg),
        Expanded(
          child: ValueListenableBuilder<String>(
            valueListenable: label,
            builder: (_, v, _) => Text(v),
          ),
        ),
      ],
    ),
    actions: [
      if (onCancel != null)
        TextButton(
          key: const Key('note-c3-progress-cancel'),
          onPressed: onCancel,
          child: Text(noteC3(NoteC3TextKeys.importStop, '取消导入')),
        ),
    ],
  );
}
