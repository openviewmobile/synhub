// 单条笔记页（P1）：只读渲染正文 + 编辑 / 删除 / 版本历史入口。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import '../../design/design_palette.dart';
import '../../core/ui/adaptive_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';
import '../../core/i18n/data_text.dart';
import 'note_attachment_actions.dart';
import 'note_attachment_cache.dart';
import '../files/file_row.dart' show formatFileTime;
import 'note_body.dart';
import 'note_c3_pages.dart';
import 'note_c3_providers.dart';
import 'note_c3_text.dart';
import 'note_copy.dart';
import 'note_editor_page.dart';
import 'note_encryption.dart';
import 'note_html.dart' show notePlainText;
import 'note_info_sheet.dart';
import 'note_mail.dart';
import 'note_share_out.dart';
import 'note_providers.dart';
import 'note_reminder.dart';
import 'note_share_page.dart';
import 'note_sync.dart';
import 'note_tag_tree.dart';
import 'note_wave4_providers.dart';
import 'note_wave4_text.dart';
import 'note_wave5_text.dart';
import 'note_widgets.dart';

class NoteViewPage extends ConsumerStatefulWidget {
  const NoteViewPage({super.key, required this.note, this.fromCache = false});

  /// 列表里带过来的（可能没有正文，打开后 `noteDetailProvider` 再取全量）
  final NoteDto note;

  /// 列表本身就是从磁盘缓存来的（离线）→ 页面上要说明"这是缓存内容"
  final bool fromCache;

  @override
  ConsumerState<NoteViewPage> createState() => _NoteViewPageState();
}

class _NoteViewPageState extends ConsumerState<NoteViewPage> {
  /// 解密后的正文（加密笔记解锁成功后才有）。
  ///
  /// 不加进 provider：口令只活在内存里，页面关掉即失效（官方 Web 端同款行为）。
  String? _plain;

  /// 上次"自动解锁"用的口令指纹，避免每帧都试
  String? _autoTried;

  @override
  void initState() {
    super.initState();
    // 本次会话里解过锁的，进来直接解，不再问口令
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoUnlock());
  }

  void _autoUnlock() {
    if (!mounted) return;
    final note = widget.note;
    if (!note.encrypt || _plain != null) return;
    final store = ref.read(noteUnlockStoreProvider);
    final known = store[note.objectId];
    if (known == null) return;
    if (_autoTried == known.password) return;
    _autoTried = known.password;
    final service = ref.read(noteEncryptionProvider);
    if (service == null) return;
    // 正文可能还在路上：等 detail 到了再试
    final full = widget.note.hasContent
        ? widget.note
        : ref.read(noteDetailProvider(widget.note.objectId)).value?.note;
    if (full == null || !full.hasContent) return;
    service
        .unlock(full, known.password)
        .then((plain) {
          if (!mounted) return;
          setState(() => _plain = plain);
        })
        .catchError((Object _) {
          // 自动解锁失败（口令变了之类）→ 交给手动输入
          store.forget(note.objectId);
        });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    // 列表条目带正文就直接用（服务端有时会一并返回），否则按 id 取
    final detail = widget.note.hasContent && widget.note.content.isNotEmpty
        ? null
        : ref.watch(noteDetailProvider(widget.note.objectId));
    final note = detail?.value?.note ?? widget.note;
    // 正文还没到手时，编辑/删除/版本一律禁掉：拿"没正文的条目"进编辑器
    // 再保存，会把服务端的正文清空（真机探针验证过这条路很危险）
    final busy = detail != null && !detail.hasValue;
    final notebooks =
        ref.watch(notebooksProvider).value ?? const <NotebookDto>[];
    final notebookTitle = notebooks
        .where((n) => n.objectId == note.parentId)
        .map((n) => n.displayTitle)
        .firstOrNull;
    // C3：导出/版本入口按能力位 + `105` 显隐（`partial`，绝不隐藏笔记模块本身）。
    // 未检测（null）→ fail-open。
    final c3 = ref.watch(noteC3AvailabilityProvider).value;
    final showsExport =
        c3 == null ||
        c3.shows(NoteC3Feature.exportWord) ||
        c3.shows(NoteC3Feature.exportNote);
    final showsVersion = c3 == null || c3.shows(NoteC3Feature.version);
    // F5：快捷方式入口按 `SYNO.NoteStation.Shortcut` 能力位降级（缺位 → 只藏
    // 这个入口；未检测 → fail-open，与 wave3 列表入口同一纪律）。
    final canShortcut = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.note, NoteStationApi.shortcutApi);
    final isShortcut =
        ref.watch(noteIsShortcutProvider(note.objectId)).value ?? false;

    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(
          note.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: adaptiveActions([
          // A13/N3/I2：「笔记信息」面板（大小 / 时间 / 来源 + 改口令入口）
          IconButton(
            key: const Key('note-info-entry'),
            tooltip: noteWave5(NoteWave5TextKeys.infoTitle, '笔记信息'),
            icon: const Icon(Icons.info_outline),
            onPressed: busy
                ? null
                : () => showNoteInfoSheet(context, ref, note),
          ),
          IconButton(
            tooltip: context.t.noteTags,
            icon: const Icon(Icons.sell_outlined),
            onPressed: busy ? null : () => _editTags(context, note),
          ),
          IconButton(
            tooltip: context.t.noteShare,
            icon: const Icon(Icons.share_outlined),
            onPressed: busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => NoteSharePage(note: note),
                    ),
                  ),
          ),
          // ★ J9（235 轮）：把**正文**交给系统分享面板（ACTION_SEND）
          //   —— 与 J7（邮件）并列的出口；入站那一半见 `note_share_clip.dart`。
          IconButton(
            key: const Key('note-share-out-entry'),
            // ★ r349（D72）：**必须**用 shareOut 这个独立 key ——
            //   以前这里传的是 `sendToEmail`，于是装上翻译后与下面那条邮件入口
            //   **同名**（⋮ 菜单里出现两条「发送到邮件」）。
            tooltip: noteMailText(NoteMailTextKeys.shareOut, '分享到其他应用'),
            icon: const Icon(Icons.ios_share),
            onPressed: busy || (note.encrypt && _plain == null)
                ? null
                : () => _shareOut(context, note),
          ),
          // J7：官方 `menu_note` 的 `email` —— 走系统邮件 intent
          // （`NoteFragment.sendMailHTML`：ACTION_SENDTO + `mailto:`）
          IconButton(
            key: const Key('note-email-entry'),
            tooltip: noteMailText(NoteMailTextKeys.sendToEmail, '发送到邮件'),
            icon: const Icon(Icons.mail_outline),
            // 加密笔记没解锁时正文是密文，发出去没有意义 —— 与"编辑"同一道门
            onPressed: busy || (note.encrypt && _plain == null)
                ? null
                : () => _sendToEmail(context, note),
          ),
          if (showsExport)
            IconButton(
              key: const Key('note-c3-export-button'),
              tooltip: noteC3(NoteC3TextKeys.export, '导出'),
              icon: const Icon(Icons.download_outlined),
              onPressed: busy
                  ? null
                  : () => showNoteExportSheet(context, ref, note),
            ),
          if (showsVersion)
            IconButton(
              key: const Key('note-c3-version-button'),
              tooltip: context.t.noteVersionHistory,
              icon: const Icon(Icons.history),
              onPressed: busy
                  ? null
                  : () => Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NoteVersionPage(note: note),
                      ),
                    ),
            ),
          PopupMenuButton<NoteCopyAction>(
            key: const Key('note-copy-menu'),
            enabled: !busy,
            tooltip: noteB(NoteBTextKeys.copy, '复制'),
            icon: const Icon(Icons.copy_outlined),
            onSelected: (action) =>
                runNoteCopyAction(context, ref, note, action),
            itemBuilder: (context) => [
              PopupMenuItem(
                key: const Key('note-copy-duplicate'),
                value: NoteCopyAction.duplicate,
                child: Text(noteB(NoteBTextKeys.copy, '复制笔记')),
              ),
              if (!note.encrypt)
                PopupMenuItem(
                  key: const Key('note-copy-to-encrypt'),
                  value: NoteCopyAction.toEncrypt,
                  child: Text(
                    noteB(NoteBTextKeys.copyToEncrypt, '复制到加密'),
                  ),
                ),
              if (note.encrypt) ...[
                PopupMenuItem(
                  key: const Key('note-copy-to-encrypt'),
                  value: NoteCopyAction.toEncrypt,
                  child: Text(
                    noteB(NoteBTextKeys.copyToEncrypt, '复制到加密'),
                  ),
                ),
                PopupMenuItem(
                  key: const Key('note-copy-to-plaintext'),
                  value: NoteCopyAction.toPlaintext,
                  child: Text(
                    noteB(NoteBTextKeys.copyToPlaintext, '复制到明文'),
                  ),
                ),
              ],
            ],
          ),
          if (canShortcut)
            IconButton(
              key: const Key('note-shortcut-toggle'),
              tooltip: isShortcut
                  ? noteWave4(NoteWave4TextKeys.shortcutRemove, '取消快捷方式')
                  : noteWave4(NoteWave4TextKeys.shortcutAdd, '加入快捷方式'),
              icon: Icon(
                isShortcut
                    ? Icons.bookmark_remove_outlined
                    : Icons.bookmark_add_outlined,
              ),
              onPressed: busy
                  ? null
                  : () => _toggleShortcut(context, note, isShortcut),
            ),
          IconButton(
            tooltip: context.t.dtoActionDelete,
            icon: const Icon(Icons.delete_outline),
            onPressed: busy ? null : () => _delete(context, note),
          ),
          if (note.encrypt)
            IconButton(
              tooltip: _plain == null
                  ? context.t.noteUnlockPrompt
                  : context.t.e2eeLock,
              icon: Icon(_plain == null ? Icons.lock_outline : Icons.lock_open),
              onPressed: _plain == null
                  ? () => _askPassword(context, note)
                  : () => _lock(context, note),
            ),
          IconButton(
            tooltip: context.t.calEditLabel,
            icon: const Icon(Icons.edit_outlined),
            onPressed: busy || (note.encrypt && _plain == null)
                ? null
                : () => _edit(context, note),
          ),
        ]),
      ),
      body: detail == null
          ? _body(
              context,
              note,
              notebookTitle,
              theme,
              hud,
              fromCache: widget.fromCache,
            )
          : detail.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, __) => AppErrorView(
                title: context.t.noteOpenFailed,
                detail: describeNoteError(e, context.t),
                onRetry: () =>
                    ref.invalidate(noteDetailProvider(widget.note.objectId)),
              ),
              data: (full) {
                // 全量到手后（也可能刚被别处解锁过）再试一次自动解锁
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _autoUnlock(),
                );
                return _body(
                  context,
                  full.note,
                  notebookTitle,
                  theme,
                  hud,
                  fromCache: full.fromCache || widget.fromCache,
                );
              },
            ),
    );
  }

  Widget _body(
    BuildContext context,
    NoteDto note,
    String? notebookTitle,
    ThemeData theme,
    DesignPalette hud, {
    bool fromCache = false,
  }) {
    final t = context.t;
    final meta = [
      if (notebookTitle != null) notebookTitle,
      if (note.mtime > 0) t.noteModifiedAt(formatFileTime(note.mtime)),
      if (note.ownerName != null) note.ownerName!,
      if (note.encrypt) t.noteEncryptedAes,
    ].join(' · ');
    if (note.encrypt && _plain == null) {
      return _lockedPanel(note);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (fromCache)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
            child: Text(
              t.noteOfflineCacheNotice,
              style: const TextStyle(fontSize: 11, color: Color(0xFF9AA0A6)),
            ),
          ),
        if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
            child: TelemetryLabel(meta, size: 10, color: hud.dim),
          ),
        if (note.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
            child: Wrap(
              spacing: Gap.xs,
              children: [
                for (final tag in note.tags)
                  Chip(
                    label: Text(tag),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ),
        // ★ 120 轮：附件条 —— 官方 NoteView 在正文上方列附件；
        //   点 = 用其他应用打开，长按 = 保存到"下载"（都在本地落盘之后）。
        if (note.attachments.isNotEmpty) _attachmentBar(context, note),
        // 正文自己滚（Quill 需要**有界**高度，别套 SingleChildScrollView）
        Expanded(
          child: NoteBody(html: _plain ?? note.content, note: note),
        ),
      ],
    );
  }

  /// 未解锁时显示的密码面板（对齐官方 Web 端的"输入口令"面板）。
  Widget _lockedPanel(NoteDto note) {
    final t = context.t;
    final hud = DesignPalette.of(context);
    final ctrl = TextEditingController();
    var busy = false;
    // 面板自己也要能提示（成功/失败），所以单独持有 ScaffoldMessenger
    final messenger = ScaffoldMessenger.of(context);
    return StatefulBuilder(
      builder: (panelContext, setPanelState) {
        Future<void> submit() async {
          final service = ref.read(noteEncryptionProvider);
          if (service == null) return;
          setPanelState(() => busy = true);
          try {
            final plain = await service.unlock(note, ctrl.text);
            if (!mounted) return;
            setState(() => _plain = plain);
          } on NotePasswordException {
            if (!mounted) return;
            setPanelState(() => busy = false);
            messenger.showSnackBar(
              SnackBar(content: Text(t.noteWrongPasswordRetry)),
            );
          } catch (e) {
            if (!mounted) return;
            setPanelState(() => busy = false);
            messenger.showSnackBar(
              SnackBar(
                content: Text(t.noteUnlockFailed(describeNoteError(e, t))),
              ),
            );
          }
        }

        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 40, color: hud.dim),
                const SizedBox(height: Gap.md),
                Text(
                  t.noteIsEncrypted,
                  style: Theme.of(panelContext).textTheme.titleMedium,
                ),
                const SizedBox(height: Gap.xs),
                Text(
                  t.notePasswordLocalOnly,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: hud.dim, fontSize: 12),
                ),
                const SizedBox(height: Gap.lg),
                TextField(
                  controller: ctrl,
                  obscureText: true,
                  autofocus: true,
                  maxLength: 32,
                  enabled: !busy,
                  decoration: InputDecoration(
                    labelText: t.notePasscode,
                    counterText: '',
                  ),
                  onSubmitted: (_) => submit(),
                ),
                const SizedBox(height: Gap.md),
                FilledButton.icon(
                  onPressed: busy ? null : submit,
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_open),
                  label: Text(t.e2eeUnlock),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 重新输入口令（工具栏那个锁图标）
  Future<void> _askPassword(BuildContext context, NoteDto note) async {
    final t = context.t;
    final full = note.hasContent
        ? note
        : ref.read(noteDetailProvider(note.objectId)).value?.note;
    if (full == null || !full.hasContent) return;
    final service = ref.read(noteEncryptionProvider);
    if (service == null) return;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.noteUnlockTitle),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          maxLength: 32,
          decoration: InputDecoration(
            labelText: t.notePasscode,
            counterText: '',
          ),
          onSubmitted: (_) => Navigator.of(ctx).pop(true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.e2eeUnlock),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final plain = await service.unlock(full, ctrl.text);
      if (!mounted) return;
      setState(() => _plain = plain);
    } on NotePasswordException {
      if (mounted) _toast(t.noteWrongPassword);
    } catch (e) {
      if (mounted) _toast(t.noteUnlockFailed(describeNoteError(e, t)));
    }
  }

  /// 上锁：清掉本地口令 + 通知服务端丢弃令牌
  Future<void> _lock(BuildContext context, NoteDto note) async {
    final t = context.t;
    final service = ref.read(noteEncryptionProvider);
    setState(() => _plain = null);
    _autoTried = null;
    await service?.lock(note.objectId);
    if (mounted) _toast(t.noteLocked);
  }

  /// 附件条（120 轮）。
  Widget _attachmentBar(BuildContext context, NoteDto note) {
    final hud = DesignPalette.of(context);
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: note.attachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final a = note.attachments.values.elementAt(i);
          return InkWell(
            key: Key('note-attachment-${a.fileId}'),
            onTap: () => _runAttachmentAction(context, note, a, open: true),
            onLongPress: () =>
                _runAttachmentAction(context, note, a, open: false),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: hud.surface,
                border: Border.all(color: hud.line),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(Icons.attach_file, size: 14, color: hud.dim),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      a.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: hud.dim, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 点 = 打开，长按 = 保存到"下载"。结果一律**如实提示**。
  Future<void> _runAttachmentAction(
    BuildContext context,
    NoteDto note,
    NoteAttachmentDto attachment, {
    required bool open,
  }) async {
    final api = ref.read(noteApiProvider);
    if (api == null) {
      _toast(noteMailText(NoteMailTextKeys.mailUnavailable, '没有可用的邮件应用。'));
      return;
    }
    final actions = ref.read(noteAttachmentActionsProvider);
    final outcome = open
        ? await actions.openWith(
            api: api,
            noteId: note.objectId,
            attachment: attachment,
          )
        : await actions.saveToDownloads(
            api: api,
            noteId: note.objectId,
            attachment: attachment,
          );
    if (!mounted) return;
    switch (outcome) {
      case NoteAttachmentActionOutcome.ok:
        _toast(
          open
              ? dataText(kNoteAttachmentOpened, '已交给系统打开')
              : dataText(kNoteAttachmentSaved, '已保存到"下载"'),
        );
      case NoteAttachmentActionOutcome.noBridge:
        _toast(dataText(kNoteAttachmentNoApp, '没有可用的应用'));
      case NoteAttachmentActionOutcome.failed:
        _toast(dataText(kNoteAttachmentFailed, '附件下载失败'));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// J9「分享出去」：正文 = 纯文本（加密笔记已解锁时用明文）。
  Future<void> _shareOut(BuildContext context, NoteDto note) async {
    final ok = await shareNoteOut(
      title: note.displayTitle,
      body: notePlainText(_plain ?? note.content),
    );
    if (!context.mounted || ok) return;
    // 没有可接收的 App / 通道不可用 —— 如实提示，不假装分享成功
    _toast(noteMailText(NoteMailTextKeys.mailUnavailable, '没有可用的分享目标。'));
  }

  /// J7「发送到邮件」：主题 = 笔记标题，正文 = 笔记正文的**纯文本**
  /// （加密笔记已解锁时用解密后的正文，与官方在 WebView 里取明文同效）。
  Future<void> _sendToEmail(BuildContext context, NoteDto note) async {
    final body = notePlainText(_plain ?? note.content);
    // ★ 119 轮：官方"有附件 → SEND_MULTIPLE"这一支**接上了** ——
    //   先把附件下到应用私有缓存（`Note/download` v1，118 轮实现），
    //   再交给邮件 runner；单个附件失败只跳过（与官方 prepareMailContent 同口径）。
    var attachments = const <String>[];
    final api = ref.read(noteApiProvider);
    if (note.attachments.isNotEmpty && api != null) {
      attachments = await downloadNoteAttachments(
        api: api,
        note: note,
        onError: (e) => debugPrint('[notes] 附件下载跳过：$e'),
      );
    }
    if (!context.mounted) return;
    final ok = await ref.read(noteMailProvider)(
      subject: note.displayTitle,
      body: body,
      attachments: attachments,
    );
    if (!context.mounted || ok) return;
    _toast(noteMailText(NoteMailTextKeys.mailUnavailable, '没有可用的邮件应用。'));
  }

  /// 编辑这条笔记的标签（`Note/set` 的 `tag` 参数 = 标签**标题**数组；
  /// 官方 Web 端也是这么干的，标签对象由服务端按标题隐式维护）
  Future<void> _editTags(BuildContext context, NoteDto note) async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final all = await ref
        .read(noteTagsProvider.future)
        .catchError((Object _) => const <TagDto>[]);
    if (!context.mounted) return;
    final picked = await showModalBottomSheet<List<String>?>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TagEditorSheet(
        all: all.map((t) => t.title).toList(),
        selected: note.tags,
      ),
    );
    if (picked == null) return;
    try {
      await api.setNote(objectId: note.objectId, ver: note.ver, tags: picked);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.noteTagFailed(describeNoteError(e, t)))),
        );
      }
      return;
    }
    ref.invalidate(noteDetailProvider(note.objectId));
    ref.invalidate(noteListProvider);
    ref.invalidate(noteTagsProvider);
  }

  Future<void> _edit(BuildContext context, NoteDto note) async {
    final t = context.t;
    final notebooks =
        ref.read(notebooksProvider).value ?? const <NotebookDto>[];
    // 加密笔记：编辑器只认明文，保存时再加密回去
    final plain = note.encrypt ? _plain : null;
    if (note.encrypt && plain == null) {
      _toast(t.noteUnlockToEdit);
      return;
    }
    final full = note.hasContent
        ? note
        : ref.read(noteDetailProvider(note.objectId)).value?.note;
    final saved = await Navigator.of(context, rootNavigator: true)
        .push<NoteDto>(
          MaterialPageRoute<NoteDto>(
            builder: (_) => NoteEditorPage(
              note: full == null
                  ? note
                  : full.copyWith(
                      content: plain ?? full.content,
                      hasContent: true,
                    ),
              notebooks: notebooks,
              plainHtml: plain,
              encryptPassword: note.encrypt
                  ? ref.read(noteUnlockStoreProvider)[note.objectId]?.password
                  : null,
            ),
          ),
        );
    if (saved != null) {
      ref.invalidate(noteDetailProvider(note.objectId));
      ref.invalidate(noteListProvider);
      // 加密笔记：编辑器回包的 `content` 是**明文**，直接用上；
      // 否则 `_plain` 会一直是解锁那一刻的旧值（`_autoUnlock` 见 `_plain != null`
      // 就早退），刚存进去的正文在详情页看起来"还是空的"。
      if (mounted) {
        setState(() {
          if (note.encrypt && saved.content.isNotEmpty) _plain = saved.content;
        });
      }
    }
  }

  /// F5：加入 / 取消快捷方式（`Shortcut/set|delete` v1）。写操作，失败如实报错。
  Future<void> _toggleShortcut(
    BuildContext context,
    NoteDto note,
    bool isShortcut,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    try {
      await setNoteShortcut(ref, note.objectId, add: !isShortcut);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            isShortcut
                ? noteWave4(NoteWave4TextKeys.shortcutRemoved, '已取消快捷方式')
                : noteWave4(NoteWave4TextKeys.shortcutAdded, '已加入快捷方式'),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            noteWave4Fill(
              NoteWave4TextKeys.shortcutFailed,
              '快捷方式操作失败：{error}',
              {'error': describeNoteError(e, t)},
            ),
          ),
        ),
      );
    }
  }

  Future<void> _delete(BuildContext context, NoteDto note) async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.noteDeleteTitle),
        content: Text(t.noteDeleteConfirm(note.displayTitle)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      if (api == null) {
        await deleteOffline(
          ref.read(noteStoreProvider),
          ref.read(noteSyncProvider.notifier),
          note.objectId,
        );
        ref.invalidate(noteListProvider);
        if (mounted) {
          messenger.showSnackBar(SnackBar(content: Text(t.noteDeletedOffline)));
          navigator.pop();
        }
        return;
      }
      await api.deleteNote(note.objectId);
      ref.invalidate(noteListProvider);
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(t.noteMovedToRecycle)));
        navigator.pop();
      }
    } catch (e) {
      if (isOfflineError(e)) {
        // 离线删除：本地先抹掉，入队等联网再推
        await deleteOffline(
          ref.read(noteStoreProvider),
          ref.read(noteSyncProvider.notifier),
          note.objectId,
        );
        ref.invalidate(noteListProvider);
        if (mounted) {
          messenger.showSnackBar(SnackBar(content: Text(t.noteDeletedOffline)));
          navigator.pop();
        }
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(t.noteDeleteFailed(describeNoteError(e, t)))),
      );
    }
  }
}

/// 标签多选面板：既有标签打勾 + 现场新建（新标签直接以标题交给服务端）
class _TagEditorSheet extends StatefulWidget {
  const _TagEditorSheet({required this.all, required this.selected});

  final List<String> all;
  final List<String> selected;

  @override
  State<_TagEditorSheet> createState() => _TagEditorSheetState();
}

class _TagEditorSheetState extends State<_TagEditorSheet> {
  late final Set<String> _picked = {...widget.selected};
  late final List<String> _all = [
    ...widget.all,
    // 笔记上已有、但标签表里还没出现的（少见，容错）
    ...widget.selected.where((t) => !widget.all.contains(t)),
  ];
  final _newTag = TextEditingController();

  /// F4：新建标签时选的**父标签**（空 = 顶层）。
  ///
  /// 官方没有 `parent_tag_id`：子标签就是标题里的 `/` 分层
  /// （`combineToFullTag(parent, child)`），见 `note_tag_tree.dart`。
  String _parent = '';

  @override
  void dispose() {
    _newTag.dispose();
    super.dispose();
  }

  void _add() {
    final t = _newTag.text.trim();
    if (t.isEmpty) return;
    // F4：选了父标签就把标题拼成 `父/子`（官方 `combineToFullTag`）
    final full = _parent.isEmpty ? t : combineNoteTag(_parent, t);
    setState(() {
      if (!_all.contains(full)) _all.add(full);
      _picked.add(full);
      _newTag.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DesignRowTile(
              title: Text(context.t.noteTags),
              trailing: TextButton(
                onPressed: () => Navigator.of(context).pop(_picked.toList()),
                child: Text(context.t.calEnvDone),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('note-tag-new-field'),
                      controller: _newTag,
                      decoration: InputDecoration(
                        hintText: context.t.noteNewTagHint,
                        isDense: true,
                        border: InputBorder.none,
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  IconButton(
                    key: const Key('note-tag-add'),
                    tooltip: context.t.noteAddTag,
                    icon: const Icon(Icons.add),
                    onPressed: _add,
                  ),
                ],
              ),
            ),
            // F4：把新标签建成某个已有标签的子标签（标题 `/` 分层）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Row(
                children: [
                  Text(
                    noteWave5(NoteWave5TextKeys.subTagOf, '父标签'),
                    style: TextStyle(color: hud.dim, fontSize: 12),
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: DropdownButton<String>(
                      key: const Key('note-tag-parent'),
                      isExpanded: true,
                      value: _parent,
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(
                            noteWave5(NoteWave5TextKeys.topLevel, '（顶层）'),
                          ),
                        ),
                        for (final tag in _all)
                          DropdownMenuItem(value: tag, child: Text(tag)),
                      ],
                      onChanged: (v) => setState(() => _parent = v ?? ''),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: _all.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(Gap.xl),
                      child: Text(
                        context.t.noteNoTagsYet,
                        style: TextStyle(color: hud.dim),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final tag in _all)
                          DesignCheckRow(
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
          ],
        ),
      ),
    );
  }
}


/// 附件动作文案 key（ARB 缺 key 回落中文原文）。
const String kNoteAttachmentOpened = 'noteAttachmentOpened';
const String kNoteAttachmentSaved = 'noteAttachmentSaved';
const String kNoteAttachmentNoApp = 'noteAttachmentNoApp';
const String kNoteAttachmentFailed = 'noteAttachmentFailed';
