// 笔记编辑器（P1）：`flutter_quill` 富文本 + 标题 + 笔记本选择 + 保存。
//
// 保存路径：Delta → NoteStation HTML（`noteDeltaToNoteHtml`）→ `Note/set`
// （新建走 `Note/create`）。`ver` 是乐观锁，编辑已有笔记时必须回传——
// 服务端那边有人改过就会冲突，这里把冲突翻成人话提示。
//
// **两种编辑模式**（`_mdMode`）：
//   * 富文本（默认）：`flutter_quill`，所见即所得，与官方 Web 编辑器同源（HTML）；
//   * Markdown：纯文本源码 + 预览。保存时走 `markdownToNoteHtml` —— 正文是
//     "渲染好的 HTML + 注释里的源码"，官方端看排版、我们这边能无损拿回源码。
//     详见 `note_markdown.dart` 顶部（含真机取证结论）。
import '../../design/kit/design_kit.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../design/design_palette.dart';
import '../../core/ui/adaptive_actions.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/i18n/l10n.dart';
import '../../core/media/camera_support.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../ai/ai_assistant_sheet.dart';
import '../ai/ai_service.dart';
import '../ai/on_device_ai.dart';
import '../ai/text_ai.dart';
import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';
import '../../data/note_crypto.dart';
import '../../dsm/webapi.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'note_body.dart';
import 'note_audio_record.dart';
import 'note_c3_actions.dart';
import 'note_c3_text.dart';
import 'note_drawing_page.dart';
import 'note_drawing_text.dart';
import 'note_encryption.dart';
import 'note_gaps_text.dart';
import 'note_sync.dart';
import 'note_html.dart';
import 'note_link.dart';
import 'note_markdown.dart';
import 'note_nas_picker.dart';
import 'note_picker.dart';
import 'note_providers.dart';
import 'note_widgets.dart';
import '../../core/user_facing_error.dart';

class NoteEditorPage extends ConsumerStatefulWidget {
  const NoteEditorPage({
    super.key,
    this.note,
    this.notebooks = const [],
    this.plainHtml,
    this.encryptPassword,
    this.initialPickSource,
  });

  /// 传了就是编辑，不传就是新建
  final NoteDto? note;
  final List<NotebookDto> notebooks;

  /// 加密笔记**解密后的正文**（编辑器只认明文，保存时再加密回去）
  final String? plainHtml;

  /// 加密笔记当前会话里的口令；新建加密笔记时为 null（用 `_newPassword`）
  final String? encryptPassword;

  /// 进页面后**自动打开**的来源（`camera` / `video`）。
  ///
  /// 官方 DS note 抽屉里的「从相机新建 / 从视频新建」（新笔记 → 立刻调起相机）
  /// 就走这里：`notes_page.dart` 的新建入口传 `NotePickSource.camera` /
  /// `NotePickSource.video`，编辑器首帧后直接进对应的选择/拍摄流程。
  final NotePickSource? initialPickSource;

  @override
  ConsumerState<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends ConsumerState<NoteEditorPage> {
  late final TextEditingController _title = TextEditingController(
    text: widget.note?.title ?? '',
  );
  String? _notebookId;
  bool _saving = false;
  bool _preview = false;

  /// Markdown 模式（源码编辑 + 预览）。`_mdText` 只在 Markdown 模式下有意义。
  bool _mdMode = false;
  final TextEditingController _mdText = TextEditingController();

  /// 新建时要用的加密口令（null = 不加密）
  String? _newPassword;

  /// 这条笔记是不是加密的（编辑已有笔记看它的 `encrypt`，新建看有没有口令）
  bool get _encrypting =>
      _newPassword != null || (widget.note?.encrypt ?? false);

  /// 当前口令
  String? get _password => _newPassword ?? widget.encryptPassword;

  /// 真正在编辑的那份笔记。
  ///
  /// ⚠️ 列表条目**没有正文**（`content` 只在 `Note/get` 里给），而
  /// `Note/set` 的回包同样不带正文 —— 万一拿"没正文的笔记"进编辑器，
  /// 一保存就会把服务端的正文清空。所以这里只认"有正文"的那份，
  /// 没有就按 id 去取（`_loading` 期间不给编辑）。
  NoteDto? _note;
  quill.QuillController? _body;
  String? _installedFor;

  /// 已经应用到新笔记正文上的默认字号（N7，防重复 format）。
  String? _appliedDefaultFont;

  /// 「刚插入、还没上传」的图。Delta 里的值是 `ref`（不是 `file_id`），
  /// 保存时先 `Note/set` multipart 传上去，再把值换成服务端给的 `file_id`。
  ///
  /// ⚠️ `ref` 必须**插入时生成一次**并存下来：`noteAttachmentRef` 里带时间戳，
  /// 每次调用结果都不同 —— 现算会导致"预览找不到图、上传对不上 ref"。
  ///
  /// [painting] = 这条是手绘导出的 PNG：正文里要带官方
  /// `syno-dsnote-painting-object` class（见 `note_html.dart`），上传链路完全一样。
  final List<({NotePickedImage image, String ref, bool painting})> _pending = [];

  /// 「刚选、还没上传」的**普通文件**附件（官方 `add_attachment`）。
  ///
  /// 与图片不同：普通文件**不进正文**（官方也不进，只作为附件元数据），
  /// 所以这里不需要 `ref` 占位，上传后出现在附件列表里。
  final List<NotePickedImage> _pendingFiles = [];

  /// `ref` → 本地路径（渲染待上传图片时用）
  Map<String, String> get _localPreviews => {
    for (final p in _pending) p.ref: p.image.path,
  };

  /// 正文里**手绘对象**的 Delta 图片值（`ref` 或已上传后的 `file_id`）。
  ///
  /// 手绘与普通图片在正文里只差 `syno-dsnote-painting-object` class，而 Quill 的
  /// image embed 不支持自定义键（`Embeddable.fromJson` 断言只有一个键），所以
  /// 标记只能**在编辑器内存里**跟着 `ref` 走；加载笔记时从 HTML 读回来
  /// （[notePaintingRefsFromHtml]），保存时再交给 `isPainting` 写回 class。
  Set<String> _paintingValues = {};

  bool get _isNew => widget.note == null;

  /// Delta 里的图片值 → 服务端正文里的 `ref`。
  ///
  /// 两种值：已上传的是附件 `file_id`（查附件表拿 `ref`）；刚插入还没上传的
  /// 本身就是 `ref`，原样返回。
  String? _refOf(String value) {
    if (_pending.any((p) => p.ref == value)) return value;
    return _note?.attachments[value]?.ref;
  }

  @override
  void initState() {
    super.initState();
    final incoming = widget.note;
    final parent = incoming?.parentId ?? '';
    _notebookId = parent.isNotEmpty
        ? parent
        : (widget.notebooks.isEmpty ? null : widget.notebooks.first.objectId);
    if (incoming == null || incoming.hasContent) _install(incoming);
    // C5：官方抽屉「从相机/视频新建」—— 首帧后自动进入拍摄/选视频流程。
    final initial = widget.initialPickSource;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _body == null) return;
        unawaited(_runPickSource(initial));
      });
    }
  }

  /// 用一份笔记（重新）建正文控制器。必须有正文，否则拒绝安装。
  void _install(NoteDto? note) {
    if (note != null && !note.hasContent) return;
    // 带 Markdown 标记的笔记：直接进 Markdown 模式，并把源码原样放回编辑框
    final raw = note?.encrypt == true
        ? (widget.plainHtml ?? '')
        : (note?.content ?? '');
    final source = markdownSourceFromHtml(raw);
    _mdMode = source != null;
    if (_mdMode) _mdText.text = source!;
    // 手绘标记：只能从正文 HTML 的 `syno-dsnote-painting-object` 读回来
    _paintingValues = notePaintingRefsFromHtml(raw);
    _body?.dispose();
    final delta = noteHtmlToDelta(
      // 加密笔记传进来的 `content` 是密文，正文用解密后的 `plainHtml`；
      // 明文 `content` 就直接用
      note?.encrypt == true ? (widget.plainHtml ?? '') : (note?.content ?? ''),
      resolver: NoteImageResolver.ofAttachments(note?.attachments ?? const {}),
    );
    _body = quill.QuillController(
      document: quill.Document.fromJson(delta),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _installedFor = note?.objectId;
    _note = note;
    if (note != null && _title.text.isEmpty) _title.text = note.title;
    // N7：新建笔记用默认字号（官方 `default_font_size`，默认 x-small）。
    if (note == null) {
      _applyDefaultFontSize(ref.read(noteDefaultFontSizeProvider));
    }
  }

  /// 把默认字号作为**新笔记正文**的基础字号（N7）。
  ///
  /// 只在"新建、且已有正文"时套用，避免覆盖已有笔记里服务端存着的字号 class。
  /// `quillSizeForSynoFont` 把官方 7 档映射成 Quill 的 small/normal/large/huge
  /// （`normal`/`small` 档官方与 Quill 默认一致 → 不改动）。
  void _applyDefaultFontSize(String synoClass) {
    if (_appliedDefaultFont == synoClass) return;
    _appliedDefaultFont = synoClass;
    final body = _body;
    if (body == null) return;
    final size = quillSizeForSynoFont(synoClass);
    if (size == null) return;
    final len = body.document.length;
    if (len <= 1) return;
    body.formatText(
      0,
      len - 1,
      quill.Attribute.fromKeyValue(quill.Attribute.size.key, size)!,
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _mdText.dispose();
    _body?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    // N7：KV 里的默认字号是异步读出来的，读到后对新笔记补套一次。
    ref.listen(noteDefaultFontSizeProvider, (_, next) {
      if (_isNew) _applyDefaultFontSize(next);
    });
    // 编辑已有笔记但手上那份没正文 → 先取全量（取的过程中不给编辑）
    final incoming = widget.note;
    if (incoming != null && !incoming.hasContent) {
      final detail = ref.watch(noteDetailProvider(incoming.objectId));
      final loaded = detail.value?.note;
      if (loaded == null) {
        return Scaffold(
          backgroundColor: hud.bg,
          appBar: AppBar(title: Text(incoming.displayTitle)),
          // ★ 以前不看 `detail.hasError`：取正文失败时 value 永远 null ⇒
          //   编辑器永久转圈，用户既看不到原因也退不出去（只能杀进程）。
          body: detail.hasError
              ? AppErrorView(
                  key: const Key('note-editor-detail-error'),
                  detail: userFacingError(detail.error!),
                  onRetry: () =>
                      ref.invalidate(noteDetailProvider(incoming.objectId)),
                )
              : const Center(child: CircularProgressIndicator()),
        );
      }
      if (_installedFor != loaded.objectId) _install(loaded);
    }
    final body = _body;
    if (body == null) {
      return Scaffold(
        backgroundColor: hud.bg,
        appBar: AppBar(title: Text(context.t.noteEditNote)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    // C9/G5：附件文本预览的开关（watch 住，附件面板才有最新值）
    final attachTextEnabled =
        ref.watch(noteAttachmentSearchEnabledProvider).value ?? false;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(_isNew ? context.t.noteNewNote : context.t.noteEditNote),
        actions: adaptiveActions([
          // 端侧 AI：总结这条笔记 / 就着它提问（原文不出本机）
          IconButton(
            tooltip: context.t.noteAiAssistant,
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: _saving ? null : _openAi,
          ),
          IconButton(
            tooltip: _mdMode
                ? context.t.noteMarkdownImageHint
                : context.t.noteInsertImage,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            // Markdown 模式里的图片走语法（`![](url)`），不再走 NoteStation 附件上传
            onPressed: _saving || _mdMode ? null : _pickImages,
          ),
          // 附件列表：下载 / 删除（官方 `attachment_list` + `option_attachment`）
          IconButton(
            key: const Key('note-editor-attachments'),
            tooltip: noteC3(NoteC3TextKeys.editorAttachments, '附件'),
            icon: const Icon(Icons.attachment_outlined),
            onPressed: () => _openAttachments(attachTextEnabled),
          ),
          if (_isNew)
            IconButton(
              tooltip: _encrypting
                  ? context.t.noteStopEncrypt
                  : context.t.noteEncryptNote,
              icon: Icon(_encrypting ? Icons.lock : Icons.lock_open),
              onPressed: _saving || _pending.isNotEmpty ? null : _toggleEncrypt,
            ),
          if (!_isNew && _encrypting)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: Icon(Icons.lock, size: 18, color: hud.dim),
            ),
          IconButton(
            tooltip: _preview
                ? context.t.noteContinueEditing
                : context.t.notePreview,
            icon: Icon(
              _preview ? Icons.edit_outlined : Icons.visibility_outlined,
            ),
            onPressed: () => setState(() => _preview = !_preview),
          ),
          IconButton(
            tooltip: _mdMode
                ? context.t.noteBackToRich
                : context.t.noteUseMarkdown,
            icon: Icon(_mdMode ? Icons.article_outlined : Icons.code),
            onPressed: _saving ? null : _toggleMarkdown,
          ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(context.t.actionSave),
          ),
        ]),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
            child: TextField(
              controller: _title,
              style: Theme.of(context).textTheme.titleMedium,
              decoration: InputDecoration(
                hintText: context.t.calEventTitleLabel,
                border: InputBorder.none,
              ),
            ),
          ),
          if (widget.notebooks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined, size: 16, color: hud.dim),
                  const SizedBox(width: Gap.xs),
                  DropdownButton<String>(
                    key: const Key('note-editor-notebook'),
                    value: _notebookId,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final nb in widget.notebooks)
                        DropdownMenuItem(
                          value: nb.objectId,
                          child: Text(nb.displayTitle),
                        ),
                    ],
                    onChanged: (v) => setState(() => _notebookId = v),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: _mdMode
                ? (_preview
                      ? NoteBody(
                          html: markdownToNoteHtml(_mdText.text),
                          note: _note,
                          localPreviews: const {},
                        )
                      : _MarkdownSourceField(controller: _mdText))
                : _preview
                ? NoteBody(
                    html: noteDeltaToNoteHtml(
                      body.document.toDelta().toJson(),
                      refOf: _refOf,
                    ),
                    note: _note,
                    localPreviews: _localPreviews,
                  )
                : Column(
                    children: [
                      quill.QuillSimpleToolbar(
                        controller: body,
                        config: quill.QuillSimpleToolbarConfig(
                          multiRowsDisplay: false,
                          showFontFamily: false,
                          // 字号走官方 `synofontsize` 7 档（自定义按钮），
                          // 不用 Quill 自带 3 档
                          showFontSize: false,
                          // 笔记内查找（官方 menu_editor 的 find_previous/next）
                          showSearchButton: true,
                          // 上下标（官方 CMD_SUBSCRIPT / CMD_SUPERSCRIPT）
                          showSubscript: true,
                          showSuperscript: true,
                          // 4 向对齐（官方 CMD_JUSTIFY_*）
                          showAlignmentButtons: true,
                          // 标题档位用官方 formatblock 对话框（div + h1..h6），
                          // Quill 自带下拉只有 h1..h3 + header
                          showHeaderStyle: false,
                          showIndent: true,
                          showClearFormat: true,
                          customButtons: [
                            _toolbarButton(
                              key: 'note-toolbar-format-block',
                              icon: Icons.format_size,
                              tooltip: noteC3(
                                NoteC3TextKeys.editorFormatBlock,
                                '段落样式',
                              ),
                              onPressed: _chooseFormatBlock,
                            ),
                            _toolbarButton(
                              key: 'note-toolbar-synofontsize',
                              icon: Icons.text_fields,
                              tooltip: noteC3(NoteC3TextKeys.editorFontSize, '字号'),
                              onPressed: _chooseFontSize,
                            ),
                            _toolbarButton(
                              key: 'note-toolbar-note-link',
                              icon: Icons.link,
                              tooltip: noteC3(
                                NoteC3TextKeys.editorNoteLink,
                                '笔记链接',
                              ),
                              onPressed: _insertNoteLink,
                            ),
                            _toolbarButton(
                              key: 'note-toolbar-hr',
                              icon: Icons.horizontal_rule,
                              tooltip: noteC3(
                                NoteC3TextKeys.editorHorizontalRule,
                                '分割线',
                              ),
                              onPressed: _insertHorizontalRule,
                            ),
                            _toolbarButton(
                              key: 'note-toolbar-attachment',
                              icon: Icons.attach_file,
                              tooltip: noteC3(
                                NoteC3TextKeys.editorFileAttachment,
                                '添加文件附件',
                              ),
                              onPressed: _pickFiles,
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: quill.QuillEditor.basic(
                          controller: body,
                          config: quill.QuillEditorConfig(
                            scrollable: true,
                            autoFocus: false,
                            expands: true,
                            padding: const EdgeInsets.all(Gap.lg),
                            // ⚠️ 编辑器也必须给图片 embed builder：只读渲染给了、
                            // 编辑器没给的话，打开带图笔记会抛
                            // `Embeddable type "image" is not supported`
                            // 整块变 ErrorBox（真机踩过）
                            embedBuilders: [
                              NoteImageEmbedBuilder(
                                objectId: _note?.objectId ?? '',
                                attachments: _note?.attachments ?? const {},
                                localPreviews: _localPreviews,
                              ),
                              // 分割线（自定义块 embed `{'hr': ''}`）
                              const NoteHrEmbedBuilder(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 新建笔记时开/关"加密"。
  ///
  /// 开：弹口令输入（两次，与官方 Web 端 `pwd` + `confirm_password` 一致）。
  /// 关：清掉口令 —— ⚠️ 只能在**还没保存过**的时候关；已保存的加密笔记要取消加密
  /// 在官方 Web 端是"另存为不加密"（`copy`），这里不提供，避免误把密文存坏。
  Future<void> _toggleEncrypt() async {
    if (_encrypting) {
      setState(() => _newPassword = null);
      _toast(context.t.noteEncryptionOffToast);
      return;
    }
    final pwd = await _askNewPassword();
    if (pwd == null || !mounted) return;
    setState(() => _newPassword = pwd);
    _toast(context.t.noteEncryptionOnToast);
  }

  /// 让用户输两遍口令（官方 Web 端的 `pwd` + `confirm_password`）
  Future<String?> _askNewPassword() async {
    final pwd = TextEditingController();
    final confirm = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t.noteSetPasscode),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pwd,
              obscureText: true,
              autofocus: true,
              maxLength: 32,
              decoration: InputDecoration(
                labelText: context.t.notePasscode,
                counterText: '',
              ),
            ),
            TextField(
              controller: confirm,
              obscureText: true,
              maxLength: 32,
              decoration: InputDecoration(
                labelText: context.t.notePasscodeConfirm,
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () {
              final a = pwd.text, b = confirm.text;
              final invalid = NoteEncryptionService.validatePassword(a, ctx.t);
              if (invalid != null) {
                ScaffoldMessenger.of(
                  ctx,
                ).showSnackBar(SnackBar(content: Text(invalid)));
                return;
              }
              if (a != b) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(ctx.t.notePasscodeMismatch)),
                );
                return;
              }
              Navigator.of(ctx).pop(a);
            },
            child: Text(ctx.t.actionOk),
          ),
        ],
      ),
    );
    return result;
  }

  /// 保存前把正文变成"服务端要存的东西"：加密笔记存密文并带上解锁令牌。
  Future<({String html, bool encrypt, String? token})> _contentForSave(
    NoteStationApi api,
    String plainHtml, {
    String? objectId,
  }) async {
    if (!_encrypting) {
      return (html: plainHtml, encrypt: false, token: null);
    }
    final password = _password;
    if (password == null || password.isEmpty) {
      throw StateError(currentText().notePasscodeMissing);
    }
    String? token;
    if (objectId != null) {
      final service = ref.read(noteEncryptionProvider);
      token = await service?.ensureToken(objectId);
      if (token == null || token.isEmpty) {
        token = await api.createEncryptToken(
          objectId: objectId,
          password: password,
        );
      }
    }
    return (
      html: NoteCrypto.encryptContent(plainHtml, password),
      encrypt: true,
      token: token,
    );
  }

  // ------------------------------------------- 批次 A：格式补齐（对照官方 CMD_*）

  /// 自定义工具栏按钮（`QuillToolbarCustomButtonOptions`）
  quill.QuillToolbarCustomButtonOptions _toolbarButton({
    required String key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) => quill.QuillToolbarCustomButtonOptions(
    icon: Icon(icon, key: Key(key), size: 18),
    tooltip: tooltip,
    onPressed: onPressed,
  );

  /// 段落样式对话框 —— 官方 `formatblock`（`dialog_font_format.xml`：
  /// `content` = `div`、`h1`..`h6`）。
  Future<void> _chooseFormatBlock() async {
    final body = _body;
    if (body == null) return;
    final labels = <(int, String)>[
      (0, noteC3(NoteC3TextKeys.editorContent, '正文')),
      (1, 'H1'),
      (2, 'H2'),
      (3, 'H3'),
      (4, 'H4'),
      (5, 'H5'),
      (6, 'H6'),
    ];
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        key: const Key('note-format-block-dialog'),
        title: Text(noteC3(NoteC3TextKeys.editorFormatBlock, '段落样式')),
        children: [
          for (final (level, label) in labels)
            SimpleDialogOption(
              key: Key('note-format-block-$level'),
              onPressed: () => Navigator.of(ctx).pop(level),
              child: Text(label),
            ),
        ],
      ),
    );
    if (picked == null) return;
    body.formatSelection(
      picked == 0
          ? quill.Attribute.header
          : quill.Attribute.fromKeyValue('header', picked)!,
    );
  }

  /// 字号对话框 —— 官方 `synofontsize` 7 档（`EditorToolBar.showFontSizeChooser`）。
  Future<void> _chooseFontSize() async {
    final body = _body;
    if (body == null) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        key: const Key('note-font-size-dialog'),
        title: Text(noteC3(NoteC3TextKeys.editorFontSize, '字号')),
        children: [
          for (var i = 0; i < kSynoFontSizes.length; i++)
            SimpleDialogOption(
              key: Key('note-font-size-${kSynoFontSizes[i]}'),
              onPressed: () => Navigator.of(ctx).pop(kSynoFontSizes[i]),
              child: Text(kSynoFontSizeLabels[i]),
            ),
        ],
      ),
    );
    if (picked == null) return;
    // 官方把字号存成 `syno-fontsize-*` class；这里就把它当 `size` 的值
    body.formatSelection(
      quill.Attribute.fromKeyValue(quill.Attribute.size.key, picked)!,
    );
  }

  /// 分割线 —— 官方 `CMD_HORIZONTAL_RULE="inserthorizontalrule"`。
  void _insertHorizontalRule() {
    final body = _body;
    if (body == null) return;
    final at = body.selection.isValid
        ? body.selection.baseOffset
        : body.document.length - 1;
    setState(() {
      // 前后各补一个换行：块级 embed 必须独占一行
      body.replaceText(at, 0, '\n', null);
      body.replaceText(at + 1, 0, quill.BlockEmbed('hr', ''), null);
      body.replaceText(at + 2, 0, '\n', null);
    });
  }

  /// 笔记链接 —— 官方 `CMD_CREATE_LINK` + `NoteLinkDialogFragment`：
  /// URI 形态 `notestation://local/self/<noteId>`，链接文字是目标笔记标题。
  Future<void> _insertNoteLink() async {
    final body = _body;
    if (body == null) return;
    // `noteListProvider` 是 autoDispose 的 FutureProvider：`ref.read` 只会拿到
    // AsyncLoading（value 为 null，候选就空了），必须 await `.future`；
    // 拉失败（离线等）时退回已有的缓存值
    List<NoteDto> notes;
    try {
      notes = (await ref.read(noteListProvider.future)).notes;
    } catch (_) {
      notes = ref.read(noteListProvider).value?.notes ?? const <NoteDto>[];
    }
    final candidates = notes
        .where((n) => !n.recycle && n.objectId != _note?.objectId)
        .toList();
    if (candidates.isEmpty) {
      _toast(noteC3(NoteC3TextKeys.editorNoteLinkEmpty, '没有可链接的其它笔记'));
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<NoteDto>(
      context: context,
      builder: (ctx) => SimpleDialog(
        key: const Key('note-note-link-dialog'),
        title: Text(noteC3(NoteC3TextKeys.editorNoteLinkTitle, '链接到笔记')),
        children: [
          for (final n in candidates.take(50))
            SimpleDialogOption(
              key: Key('note-note-link-${n.objectId}'),
              onPressed: () => Navigator.of(ctx).pop(n),
              child: Text(n.displayTitle),
            ),
        ],
      ),
    );
    if (picked == null) return;
    final uri = noteLinkUri(picked.objectId);
    final at = body.selection.isValid
        ? body.selection.baseOffset
        : body.document.length - 1;
    final text = picked.displayTitle;
    setState(() {
      body.replaceText(
        at,
        0,
        text,
        TextSelection.collapsed(offset: at + text.length),
      );
      body.formatText(
        at,
        text.length,
        quill.Attribute.fromKeyValue(quill.Attribute.link.key, uri),
      );
    });
  }

  /// 任意文件附件 —— 官方 `add_attachment`。非图片**不进正文**（避免裂图），
  /// 只加入待上传列表，保存时 multipart 上传。
  Future<void> _pickFiles() async {
    List<NotePickedImage> picked;
    try {
      picked = await ref.read(noteFilePickerProvider)();
    } catch (e) {
      _toast(
        noteC3Fill(NoteC3TextKeys.messageWithError, '{message}：{error}', {
          'message': noteC3(NoteC3TextKeys.editorFilePickFailed, '选择文件失败'),
          'error': '$e',
        }),
      );
      return;
    }
    if (picked.isEmpty || !mounted) return;
    setState(() => _pendingFiles.addAll(picked));
    _toast(
      '${noteC3(NoteC3TextKeys.editorFileAttachment, '添加文件附件')} · '
      '${picked.length}',
    );
  }

  /// 附件列表：下载 / 删除（官方 `attachment_list` + `option_attachment remove`）
  Future<void> _openAttachments(bool attachTextEnabled) async {
    final note = _note;
    if (note == null || note.attachments.isEmpty) {
      _toast(noteC3(NoteC3TextKeys.editorAttachmentEmpty, '这条笔记还没有附件'));
      return;
    }
    // C9/G5：附件文本预览（`Note/get_attachment_text` v4）——
    // 只在开关打开（本地 ∧ 服务端能力位）时出现；关掉即隐藏、不报错。
    final canViewText =
        attachTextEnabled &&
        (ref.read(noteApiProvider)?.supportsAttachmentText() ?? false);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Text(noteC3(NoteC3TextKeys.editorAttachments, '附件')),
            ),
            for (final a in note.attachments.values)
              Tooltip(
                message: noteC3(
                  NoteC3TextKeys.editorAttachmentDownload,
                  '下载并打开',
                ),
                child: DesignRowTile(
                  key: Key('note-attachment-${a.fileId}'),
                  leading: Icon(
                    a.isImage ? Icons.image_outlined : Icons.insert_drive_file,
                  ),
                  title: Text(a.name),
                  subtitle: Text(a.displaySize),
                  onTap: () => unawaited(_downloadAttachment(a)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (canViewText && !a.isImage)
                        IconButton(
                          key: Key('note-attachment-text-${a.fileId}'),
                          tooltip: noteGaps(
                            NoteGapsTextKeys.attachmentView,
                            '查看文本',
                          ),
                          icon: const Icon(Icons.text_snippet_outlined),
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            unawaited(_viewAttachmentText(a));
                          },
                        ),
                      IconButton(
                        key: Key('note-attachment-delete-${a.fileId}'),
                        tooltip: noteC3(
                          NoteC3TextKeys.editorAttachmentDelete,
                          '删除附件',
                        ),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          unawaited(_deleteAttachment(a));
                        },
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// C9/G5：取附件正文预览（`Note/get_attachment_text` v4）并弹只读对话框。
  Future<void> _viewAttachmentText(NoteAttachmentDto a) async {
    final note = _note;
    final api = ref.read(noteApiProvider);
    if (note == null || api == null) return;
    String text;
    try {
      text = await api.attachmentText(note.objectId, a.fileId);
    } catch (e) {
      if (!mounted) return;
      _toast(
        noteGapsFill(
          NoteGapsTextKeys.attachmentTextFailed,
          '读取附件文本失败：{error}',
          {'error': userFacingError(e)},
        ),
      );
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: Key('note-attachment-text-dialog-${a.fileId}'),
        title: Text(a.name),
        content: SingleChildScrollView(
          child: SelectableText(
            text.trim().isEmpty
                ? noteGaps(NoteGapsTextKeys.attachmentTextEmpty, '（没有可预览的文本）')
                : text,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.t.actionOk),
          ),
        ],
      ),
    );
  }

  /// 下载附件到本机临时目录并交给系统打开
  Future<void> _downloadAttachment(NoteAttachmentDto a) async {
    final note = _note;
    final api = ref.read(noteApiProvider);
    if (note == null || api == null) return;
    try {
      final bytes = await api.api.getBytes(
        api.attachmentUrl(note.objectId, a.fileId),
      );
      final dir = await getTemporaryDirectory();
      final safe = a.name.replaceAll(RegExp(r'[^\w.\-\u4e00-\u9fa5]'), '_');
      final file = File('${dir.path}/$safe');
      await file.writeAsBytes(bytes);
      await ref.read(noteC3SystemOpenProvider)(file.path);
    } catch (e) {
      if (!mounted) return;
      _toast(
        noteC3Fill(NoteC3TextKeys.messageWithError, '{message}：{error}', {
          'message': noteC3(
            NoteC3TextKeys.editorAttachmentDownloadFailed,
            '附件下载失败',
          ),
          'error': '$e',
        }),
      );
    }
  }

  /// 删除附件（二次确认 → `Note/set` v2 的 `attachment[action=delete]`）
  Future<void> _deleteAttachment(NoteAttachmentDto a) async {
    final note = _note;
    final api = ref.read(noteApiProvider);
    if (note == null || api == null) return;
    final t = context.t;
    final ok = await _ask(
      title: noteC3(NoteC3TextKeys.editorAttachmentDelete, '删除附件'),
      message: noteC3(
        NoteC3TextKeys.editorAttachmentDeleteConfirm,
        '确定删除附件「{name}」吗？',
      ).replaceAll('{name}', a.name),
      confirm: t.dtoActionDelete,
    );
    if (ok != true || !mounted) return;
    final attachments = Map<String, NoteAttachmentDto>.from(note.attachments)
      ..remove(a.fileId);
    try {
      final updated = await api.deleteNoteAttachments(
        objectId: note.objectId,
        ver: note.ver,
        fileIds: [a.fileId],
        encrypt: note.encrypt ? true : null,
      );
      final merged = updated ?? await api.getNote(note.objectId);
      // 只借回新的 `ver`：`Note/get` 会把**还没生效**的附件又读回来，
      // 不能把它并回去（否则 UI 上删了又出现）
      setState(() {
        _note = note.copyWith(
          ver: merged.ver.isEmpty ? note.ver : merged.ver,
          attachments: attachments,
        );
      });
    } catch (e) {
      if (!mounted) return;
      _toast(
        noteC3Fill(NoteC3TextKeys.messageWithError, '{message}：{error}', {
          'message': noteC3(
            NoteC3TextKeys.editorAttachmentDeleteFailed,
            '附件删除失败',
          ),
          'error': '$e',
        }),
      );
    }
  }

  /// 插入图片：选来源 → 选图 → 以 `ref` 占位插进正文（保存时才上传）。
  /// 末项「手绘」打开绘图板（导出 PNG 后同样以 `ref` 占位走附件上传）。
  Future<void> _pickImages() async {
    final body = _body;
    if (body == null) return;
    final paintingEnabled = ref.read(notePaintingAvailableProvider);
    final source = await showModalBottomSheet<NotePickSource>(
      context: context,
      builder: (context) => SafeArea(
        // 可滚动：入口变多后小屏（默认 800×600 测试窗口）不会 RenderFlex 溢出
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DesignRowTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(context.t.notePickFromLibrary),
                onTap: () => Navigator.of(context).pop(NotePickSource.gallery),
              ),
              // ★ DA293：桌面端（macOS/Windows/Linux）没有相机实现 ⇒ 不摆
              //   "拍照"（假控件），否则点了只会抛 UnimplementedError。
              if (kCameraCaptureSupported)
                DesignRowTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: Text(context.t.noteTakePhoto),
                  onTap: () => Navigator.of(context).pop(NotePickSource.camera),
                ),
              // C4 录音 / C5 录像：官方 "+" 菜单
              // `create_attachment_when_audio_recording` + 相机录像
              DesignRowTile(
                key: const Key('note-record-audio-entry'),
                leading: const Icon(Icons.mic_none),
                title: Text(noteGaps(NoteGapsTextKeys.recordAudio, '录音')),
                subtitle: Text(
                  noteGaps(
                    NoteGapsTextKeys.recordAudioFileName,
                    '录成 .3gp 作为附件',
                  ),
                ),
                onTap: () => Navigator.of(context).pop(NotePickSource.audio),
              ),
              if (kCameraCaptureSupported)
                DesignRowTile(
                  key: const Key('note-record-video-entry'),
                  leading: const Icon(Icons.videocam_outlined),
                  title: Text(noteGaps(NoteGapsTextKeys.recordVideo, '录像')),
                  onTap: () => Navigator.of(context).pop(NotePickSource.video),
                ),
              DesignRowTile(
                leading: const Icon(Icons.attach_file),
                title: Text(context.t.notePickFromFiles),
                onTap: () => Navigator.of(context).pop(NotePickSource.file),
              ),
              DesignRowTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(context.t.notePickFromNas),
                subtitle: Text(context.t.noteFileStationImages),
                onTap: () => Navigator.of(context).pop(NotePickSource.nas),
              ),
              // 手绘：只在能力位在位时出现；缺失时**隐藏入口 + 原因**（降级门控）
              if (paintingEnabled)
                DesignRowTile(
                  key: const Key('note-drawing-entry'),
                  leading: const Icon(Icons.draw_outlined),
                  title: Text(
                    noteDrawingText(NoteDrawingTextKeys.entry, '手绘'),
                  ),
                  subtitle: Text(
                    noteDrawingText(
                      NoteDrawingTextKeys.entryHint,
                      '画一张图并作为手绘附件插入',
                    ),
                  ),
                  onTap: () =>
                      Navigator.of(context).pop(NotePickSource.painting),
                )
              else
                DesignRowTile(
                  key: const Key('note-drawing-entry-unavailable'),
                  enabled: false,
                  leading: const Icon(Icons.draw_outlined),
                  title: Text(
                    noteDrawingText(NoteDrawingTextKeys.unavailable, '手绘不可用'),
                  ),
                  subtitle: Text(
                    noteDrawingText(
                      NoteDrawingTextKeys.unavailableHint,
                      // ★★ r348 D60：同上，兜底串不许印 `SYNO.NoteStation.Note`。
                      '当前服务器缺少笔记附件接口，无法上传手绘',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;
    await _runPickSource(source);
  }

  /// 真正执行一个来源（C5 的自动入口也复用这一段，行为与手动选来源完全一致）。
  Future<void> _runPickSource(NotePickSource source) async {
    final t = context.t;
    if (source == NotePickSource.painting) {
      await _openDrawing();
      return;
    }
    // C4 录音：面板录完拿到 .3gp 临时文件，作为普通附件
    if (source == NotePickSource.audio) {
      await _recordAudio();
      return;
    }

    List<NotePickedImage> picked;
    if (source == NotePickSource.nas) {
      picked = await pickNasImages(context, ref);
    } else {
      try {
        picked = await ref.read(noteLocalPickerProvider)(source);
      } catch (e) {
        _toast(t.noteImagePickFailed(userFacingError(e)));
        return;
      }
    }
    if (picked.isEmpty || !mounted) return;
    // C5 录像：视频**不进正文** image embed，作为普通文件附件上传
    if (source == NotePickSource.video) {
      setState(() => _pendingFiles.addAll(picked));
      return;
    }
    _insertImages(picked);
  }

  /// C4：弹录音面板；完成 → 把 `.3gp` 加进待上传的普通附件列表。
  Future<void> _recordAudio() async {
    final path = await showNoteAudioRecordSheet(context, ref);
    if (path == null || !mounted) return;
    final name = path.split(RegExp(r'[/\\]')).last;
    setState(
      () => _pendingFiles.add(
        NotePickedImage(path: path, name: name, mimeType: 'audio/3gpp'),
      ),
    );
  }

  /// 打开绘图板；用户"插入"后拿到导出的 PNG，按手绘插入正文（待上传）。
  Future<void> _openDrawing() async {
    final picked = await Navigator.of(context).push<NotePickedImage>(
      MaterialPageRoute(builder: (_) => const NoteDrawingPage()),
    );
    if (picked == null || !mounted) return;
    _insertImages([picked], painting: true);
  }

  /// 把选好的图以 `ref` 为值插进正文末尾（每张独占一段）。
  ///
  /// [painting] = 手绘：Delta 的 image embed 上多带一个 `painting` 标记，
  /// 回写正文时才会带上官方 `syno-dsnote-painting-object` class。
  void _insertImages(List<NotePickedImage> images, {bool painting = false}) {
    final body = _body;
    if (body == null) return;
    setState(() {
      for (final img in images) {
        final ref = noteAttachmentRef(img.name);
        _pending.add((image: img, ref: ref, painting: painting));
        if (painting) _paintingValues.add(ref);
        final at = body.document.length - 1; // 末尾换行之前
        body.replaceText(at, 0, quill.BlockEmbed.image(ref), null);
        body.replaceText(at + 1, 0, '\n', null);
      }
    });
  }

  /// Delta 图片值（`ref`/`file_id`）是不是手绘对象
  bool _isPaintingValue(String value) {
    if (_paintingValues.contains(value)) return true;
    final ref = _refOf(value);
    return ref != null && _paintingValues.contains(ref);
  }

  /// 把正文里"待上传"的图片值（`ref`）换成服务端返回的附件 `file_id`。
  ///
  /// 每个 `image` embed 在 Delta 里长度都是 1，所以按 offset 从后往前
  /// `replaceText(index, 1, …)` 不会错位。
  void _rewritePendingEmbeds(Map<String, String> refToFileId) {
    final body = _body;
    if (body == null || refToFileId.isEmpty) return;
    // offset → (file_id, 是否手绘)：手绘标记必须跟着值一起换成 file_id
    final targets = <int, ({String fileId, bool painting})>{};
    var offset = 0;
    for (final op in body.document.toDelta().toList()) {
      final data = op.data;
      if (data is Map && data['image'] != null) {
        final old = '${data['image']}';
        final fileId = refToFileId[old];
        if (fileId != null) {
          targets[offset] = (
            fileId: fileId,
            painting: _paintingValues.contains(old),
          );
        }
      }
      offset += op.length ?? 0;
    }
    for (final entry in targets.entries.toList().reversed) {
      // 值换成 `file_id` 后，手绘标记也要跟着走（下次保存仍能写回 class）
      if (entry.value.painting) _paintingValues.add(entry.value.fileId);
      body.replaceText(
        entry.key,
        1,
        quill.BlockEmbed.image(entry.value.fileId),
        null,
      );
    }
  }

  /// 正文的落库形态：Markdown 模式写"源码标记 + 渲染好的 HTML"，富文本模式
  /// 写 NoteStation HTML。**两种模式的保存接口完全一样**（`Note/create|set` 的
  /// `content`），服务端不需要知道我们用了哪种编辑器。
  String _deltaHtml() => _mdMode
      ? markdownToNoteHtml(_mdText.text)
      : noteDeltaToNoteHtml(
          _body!.document.toDelta().toJson(),
          refOf: _refOf,
          isPainting: _isPaintingValue,
        );

  /// 富文本 → Markdown 模式：把**当前内容的 HTML 原样**放进源码框。
  ///
  /// 不硬做"HTML → Markdown"反解（那是有损的）：Markdown 允许原样嵌 HTML，
  /// 所以把 HTML 当源码放进去 → 预览/保存的结果和原来**一模一样**，用户再
  /// 一点点把 HTML 改写成 Markdown 语法即可，不会丢格式。
  /// 当前笔记的纯文本（Markdown 模式取源码框；富文本取 Delta 的纯文本）
  String _plainBody() {
    if (_mdMode) return _mdText.text.trim();
    return _body?.document.toPlainText().trim() ?? '';
  }

  void _openAi() {
    final t = context.t;
    final text = _plainBody();
    final title = _title.text.trim().isEmpty
        ? t.noteThisNote
        : _title.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.noteSummaryEmpty)));
      return;
    }
    showAiAssistant(
      context,
      title: title,
      tasks: const [AiTaskKind.summary, AiTaskKind.askBook],
      build: (kind, question) {
        if (kind == AiTaskKind.askBook) {
          final passages = passagesOfBook(title, [t.notePassageBody], [text]);
          return withRetrieval(
            AiRequest(kind: kind, text: text, title: title, question: question),
            passages,
          );
        }
        return AiRequest(kind: kind, text: text, title: title);
      },
    );
  }

  Future<void> _toggleMarkdown() async {
    final t = context.t;
    if (!_mdMode) {
      // 空笔记（新建、或只按过回车）不塞 `<p><br></p>` 这种占位 —— 它会被
      // Markdown 当成"裸 HTML 块"开头，把后面几行都吞进 HTML 块里不转换
      // （真机踩过）。有正文时补一个空行，把 HTML 块**封口**，用户接着写的
      // Markdown 才会正常渲染。
      final plain = _body!.document.toPlainText().trim();
      final seed = plain.isEmpty ? '' : '${_deltaHtml()}\n\n';
      final ok = await _ask(
        title: t.noteUseMarkdownTitle,
        message: seed.isEmpty
            ? t.noteUseMarkdownKeepSource
            : t.noteUseMarkdownImport,
        confirm: t.calStartLabel,
      );
      if (ok != true) return;
      setState(() {
        _mdText.text = seed;
        _mdMode = true;
        // 进 Markdown 模式**先给源码框**（不是预览）：用户是来改源码的；
        // 另外新建笔记的"空正文"也会渲染成 `<p><br></p>` 这种非空串，
        // 用它判断要不要预览会直接把源码框藏起来（测试踩过）
        _preview = false;
      });
      return;
    }
    final ok = await _ask(
      title: t.noteBackToRichTitle,
      message: t.noteBackToRichMessage,
      confirm: t.noteBackToRichConfirm,
    );
    if (ok != true) return;
    _installFromHtml(markdownToNoteHtml(_mdText.text));
    setState(() {
      _mdMode = false;
      _preview = false;
    });
  }

  /// 用一段 HTML 重建富文本控制器（切回富文本时用）
  void _installFromHtml(String html) {
    _body?.dispose();
    final delta = noteHtmlToDelta(
      html,
      resolver: NoteImageResolver.ofAttachments(_note?.attachments ?? const {}),
    );
    _body = quill.QuillController(
      document: quill.Document.fromJson(delta),
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  Future<bool?> _ask({
    required String title,
    required String message,
    required String confirm,
  }) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirm),
        ),
      ],
    ),
  );

  /// 上传"刚插入、还没上传"的图片。
  ///
  /// 官方 App 没有独立的附件上传接口：图片是跟着 `Note/set` **multipart** 一起
  /// 传的（见 `docs/api-server-authoritative.md` §17.3）。所以这里
  /// ① 先确保笔记存在（新建的话先 `Note/create`）→ ② 用**带 `ref` 占位**的正文
  /// 调 `uploadAttachments` → ③ 把正文里的占位 `ref` 换成服务端返回的 `file_id`。
  Future<NoteDto> _uploadPending(NoteStationApi api, String title) async {
    var note = _note;
    if (note == null) {
      final notebookId = _notebookId;
      if (notebookId == null || notebookId.isEmpty) {
        throw DsmApiException(120, method: 'Note/create');
      }
      final draft = _deltaHtml();
      final encrypted = await _contentForSave(api, draft);
      final created = await api.createNote(
        title: title,
        parentId: notebookId,
        html: encrypted.html,
        encrypt: encrypted.encrypt,
      );
      note = NoteDto(
        objectId: created.objectId,
        title: title,
        parentId: notebookId,
        ver: created.ver,
        content: draft,
        hasContent: true,
      );
      _note = note;
      track(
        ref,
        UsageModule.notes,
        UsageAction.create,
        detail: {'kind': 'note', 'bytes': draft.length},
      );
    }
    final uploads = [
      for (final p in _pending)
        NoteAttachmentUpload(
          path: p.image.path,
          fileName: p.image.name,
          ref: p.ref,
          mimeType: p.image.mimeType,
        ),
      // 普通文件附件：官方也是同一批 `attachment[]`，只是**不进正文**
      for (final f in _pendingFiles)
        NoteAttachmentUpload(
          path: f.path,
          fileName: f.name,
          mimeType: f.mimeType,
          // 非图片不需要服务端生成缩略图
          convert: false,
        ),
    ];
    final forUpload = await _contentForSave(
      api,
      _deltaHtml(),
      objectId: note.objectId,
    );
    final uploaded = await api.uploadAttachments(
      objectId: note.objectId,
      ver: note.ver,
      files: uploads,
      html: forUpload.html,
      title: title,
      encrypt: forUpload.encrypt ? true : null,
      token: forUpload.token,
    );
    // `Note/set` 回包只有 ver + attachment（没有正文），够用了
    final merged = uploaded ?? await api.getNote(note.objectId);
    note = note.copyWith(
      ver: merged.ver.isEmpty ? note.ver : merged.ver,
      attachments: {...note.attachments, ...merged.attachments},
    );
    _note = note;
    _rewritePendingEmbeds({
      for (final a in merged.attachments.values)
        if (a.ref.isNotEmpty) a.ref: a.fileId,
    });
    _pending.clear();
    _pendingFiles.clear();
    return note;
  }

  Future<void> _save() async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    final title = _title.text.trim();
    if (api == null) {
      // 冷启动就没连上（离线浏览）：直接走本地缓存 + 队列
      setState(() => _saving = true);
      try {
        await _saveOffline(title);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    try {
      if (_pending.isNotEmpty || _pendingFiles.isNotEmpty) {
        await _uploadPending(api, title);
      }

      final html = _deltaHtml();
      var note = _note;
      if (note == null) {
        final notebookId = _notebookId;
        if (notebookId == null || notebookId.isEmpty) {
          _toast(t.noteSelectNotebookFirst);
          return;
        }
        final payload = await _contentForSave(api, html);
        // 大笔记 / 加密笔记走 `Note.Polling`（官方 Web 对加密笔记就是这么发的，
        // 见 `note_api.dart` 的说明）：`Note/set` 直连在超大正文上会超时
        final created =
            NoteStationApi.needsPolling(
              html: payload.html,
              encrypt: payload.encrypt,
            )
            ? await api.createNotePolling(
                title: title,
                parentId: notebookId,
                html: payload.html,
                encrypt: payload.encrypt,
              )
            : null;
        final createdSimple = created == null
            ? await api.createNote(
                title: title,
                parentId: notebookId,
                html: payload.html,
                encrypt: payload.encrypt,
              )
            : (objectId: created.objectId, ver: created.ver);
        if (!mounted) return;
        // 新加密笔记：把口令放进内存解锁表，接着编辑不用再输
        if (payload.encrypt && _password != null) {
          ref
              .read(noteUnlockStoreProvider)
              .keep(
                createdSimple.objectId,
                NoteUnlock(
                  password: _password!,
                  token: '',
                  expiresAt: DateTime.now(),
                ),
              );
        }
        navigator.pop(
          NoteDto(
            objectId: createdSimple.objectId,
            title: title,
            parentId: notebookId,
            ver: createdSimple.ver,
            // 回给列表的是**明文**（那份数据只用于内存展示/再进编辑器）
            content: payload.encrypt ? html : payload.html,
            hasContent: true,
            encrypt: payload.encrypt,
          ),
        );
        return;
      }
      final payload = await _contentForSave(api, html, objectId: note.objectId);
      final usePolling = NoteStationApi.needsPolling(
        html: payload.html,
        encrypt: payload.encrypt,
        token: payload.token,
      );
      final updated = usePolling
          ? await api.setNotePolling(
              objectId: note.objectId,
              ver: note.ver,
              title: title,
              html: payload.html,
              encrypt: payload.encrypt ? true : null,
              token: payload.token,
              brief: payload.encrypt ? '' : null,
              parentId: _notebookId,
              mtime: noteEpochSeconds(),
            )
          : await api.setNote(
              objectId: note.objectId,
              ver: note.ver,
              title: title,
              html: payload.html,
              encrypt: payload.encrypt ? true : null,
              token: payload.token,
              // 加密笔记没有摘要（官方 Web 端也是 `brief:""`）
              brief: payload.encrypt ? '' : null,
              parentId: _notebookId,
              mtime: noteEpochSeconds(),
            );
      // 行为偏好：编辑并保存一条笔记（只记动作 + 类型，不记标题/正文）
      trackOnce(UsageModule.notes, UsageAction.edit, objectType: 'note');
      if (!mounted) return;
      final fallback = note.copyWith(
        title: title,
        // 回给列表的是明文
        content: payload.encrypt ? html : payload.html,
        parentId: _notebookId,
        hasContent: true,
        encrypt: payload.encrypt,
        mtime: noteEpochSeconds(),
      );
      // ★ 加密笔记**只能**回 [fallback]：`updated` 是从服务端 `getNote` 拿回来的，
      //   它的 `content` 是**密文**（服务端存的就是密文）。详情页 `_plain` 要的是
      //   明文，回密文会让正文显示成一串 `U2FsdGVk…`。
      navigator.pop(
        (updated?.content.isEmpty ?? true) || payload.encrypt
            ? fallback
            : updated,
      );
    } catch (e) {
      if (isOfflineError(e)) {
        await _saveOffline(title);
        return;
      }
      trackOnceFailure(
        UsageModule.notes,
        UsageAction.edit,
        objectType: 'note',
        reason: e is StateError ? 'passcode_required' : 'save_failed',
        error: e,
      );
      _toast(
        e is StateError
            ? t.noteSaveEncryptNeedsPasscode
            : t.noteSaveFailed(describeNoteError(e, t)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 断网时保存：落本地库 + 入队（联网后由 `NoteSyncNotifier.flushPending` 推）。
  ///
  /// ⚠️ 附件没上传成功的图片在这里只留在**本地正文**里（`file:///` 之类），
  /// 提示用户联网后重新保存一次 —— 官方 App 也是"同步失败留着下次再推"。
  Future<void> _saveOffline(String title) async {
    final t = context.t;
    final store = ref.read(noteStoreProvider);
    final sync = ref.read(noteSyncProvider.notifier);
    final notebookId = _notebookId ?? '';
    final html = _deltaHtml();
    // 加密笔记离线保存的是**密文**（口令只在内存里）
    var content = html;
    if (_encrypting) {
      final password = _password;
      if (password == null || password.isEmpty) {
        _toast(t.noteSaveEncryptNeedsPasscode);
        return;
      }
      content = NoteCrypto.encryptContent(html, password);
    }
    final id = await saveOffline(
      store,
      sync,
      objectId: _note?.objectId,
      title: title,
      parentId: notebookId,
      html: content,
      ver: _note?.ver ?? '0',
      encrypt: _encrypting,
    );
    if (!mounted) return;
    ref.invalidate(noteListProvider);
    _toast(t.noteSavedOffline);
    Navigator.of(context).pop(
      NoteDto(
        objectId: id,
        title: title,
        parentId: notebookId,
        ver: _note?.ver ?? '0',
        content: html,
        hasContent: true,
        encrypt: _encrypting,
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Markdown 源码输入框（等宽字体 + 语法提示 + 快捷键工具栏）。
class _MarkdownSourceField extends StatelessWidget {
  const _MarkdownSourceField({required this.controller});

  final TextEditingController controller;

  /// 快捷键工具栏上的片段：标签 / 悬停提示 / 插入的文本。
  ///
  /// `H1` / `\`\`\`` / 表格模板里的 `a`、`b` 是语法本身（语言无关），不翻译。
  static List<(String, String, String)> _snippets(AppText t) => [
    ('H1', t.noteMdH1Tip, t.noteMdH1Text),
    (t.noteMdBold, t.noteMdBoldTip, t.noteMdBoldText),
    (t.noteMdList, t.noteMdListTip, t.noteMdListText),
    (t.noteMdTodo, t.noteMdTodoTip, t.noteMdTodoText),
    (t.noteMdQuote, t.noteMdQuoteTip, t.noteMdQuoteText),
    (t.noteMdCode, '```', t.noteMdCodeText),
    (t.noteMdTable, '| a | b |', '| a | b |\n| --- | --- |\n| 1 | 2 |\n'),
    (t.noteMdLink, t.noteMdLinkTip, t.noteMdLinkText),
  ];

  void _insert(String text) {
    final value = controller.value;
    final start = value.selection.isValid
        ? value.selection.start
        : value.text.length;
    final end = value.selection.isValid
        ? value.selection.end
        : value.text.length;
    final next = value.text.replaceRange(start, end, text);
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
            children: [
              for (final (label, tip, text) in _snippets(context.t))
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 4,
                  ),
                  child: Tooltip(
                    message: tip,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                        minimumSize: const Size(0, 32),
                      ),
                      onPressed: () => _insert(text),
                      child: Text(label),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: TextField(
              controller: controller,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                height: 1.5,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: context.t.noteMdHint,
                hintStyle: TextStyle(color: hud.dim.withValues(alpha: 0.6)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
