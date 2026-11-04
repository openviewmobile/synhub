// A13「笔记信息」+ N3「来源链接查看 / 编辑」+ I2「改口令」入口。
//
// ★ 官方对齐目标（`fragments/InfoDialogFragment` + `res/layout/fragment_dialog_info.xml`）：
//   Android 的"笔记信息"对话框逐项是
//   `title / notebook / tags / ctime / mtime / [改口令] / source_url / history / location`
//   （`fragment_dialog_info.xml` 的 `TwoRowItem` 顺序，头部 `tworow:head="@string/..."`）。
//   官方 Web 的 `Info.Panel` 同构，且 `source_url` 是**可编辑文本框**
//   （`{xtype:"syno_textfield",fieldLabel:_T("info","source_url"),name:"source_url"}`），
//   保存走 `Info.Window.onClickOk` → `Note/set`。
//
//   * **大小**：官方接口**没有** size 字段，Android 自己算"近似大小"
//     ——`vos/api/NoteVo.java:14 getApproximateSize()`：
//     `1000 + len(title) + len(brief) + len(content) + attachment*100 + Σlen(tag)`。
//     这里逐字移植 [noteApproximateSize]（**不臆造新字段**）。
//   * **内部 id 一律不上屏**：`object_id` / `file_id` / `ver` hash / `tag_id`
//     只出现在 Key 与请求里，界面上一个都不显示。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/note_dto.dart';
import '../../data/note_crypto.dart';
import '../files/file_row.dart' show formatFileTime;
import 'note_encryption.dart';
import 'note_location.dart';
import 'note_location_sheet.dart';
import 'note_location_text.dart';
import 'note_providers.dart';
import 'note_wave5_text.dart';
import 'note_widgets.dart' show describeNoteError;

/// 官方 Android `NoteVo.getApproximateSize()` 的逐字移植（单位：字符近似值）。
///
/// 服务端不返回 size，这是**官方自己**的口径；我们照抄，不编新字段。
int noteApproximateSize(NoteDto note) {
  var size =
      1000 +
      note.title.length +
      note.brief.length +
      note.content.length +
      note.attachments.length * 100;
  for (final tag in note.tags) {
    size += tag.length;
  }
  return size;
}

/// 打开「笔记信息」面板。
Future<void> showNoteInfoSheet(
  BuildContext context,
  WidgetRef ref,
  NoteDto note,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => NoteInfoSheet(note: note),
);

class NoteInfoSheet extends ConsumerStatefulWidget {
  const NoteInfoSheet({super.key, required this.note});

  final NoteDto note;

  @override
  ConsumerState<NoteInfoSheet> createState() => _NoteInfoSheetState();
}

class _NoteInfoSheetState extends ConsumerState<NoteInfoSheet> {
  bool _busy = false;

  NoteDto get _note => widget.note;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final notebooks =
        ref.watch(notebooksProvider).value ?? const <NotebookDto>[];
    final notebookTitle = notebooks
        .where((n) => n.objectId == _note.parentId)
        .map((n) => n.displayTitle)
        .firstOrNull;
    final src = _note.sourceUrl ?? '';
    return SafeArea(
      key: const Key('note-info-sheet'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              noteWave5(NoteWave5TextKeys.infoTitle, '笔记信息'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.sm),
            // ⚠️ 只显示**标题**，不显示 object_id（内部 id 不上屏）
            _row(
              hud,
              noteWave5(NoteWave5TextKeys.infoNotebook, '笔记本'),
              notebookTitle ?? noteWave5(NoteWave5TextKeys.infoUnset, '—'),
            ),
            _row(
              hud,
              noteWave5(NoteWave5TextKeys.infoCreated, '创建时间'),
              _note.ctime > 0 ? formatFileTime(_note.ctime) : '—',
            ),
            _row(
              hud,
              noteWave5(NoteWave5TextKeys.infoModified, '修改时间'),
              _note.mtime > 0 ? formatFileTime(_note.mtime) : '—',
              key: const Key('note-info-modified'),
            ),
            // 官方 `getApproximateSize()` 口径
            _row(
              hud,
              noteWave5(NoteWave5TextKeys.infoSize, '大小（近似）'),
              '${noteApproximateSize(_note)} B',
              key: const Key('note-info-size'),
            ),
            if (_note.tags.isNotEmpty)
              _row(
                hud,
                noteWave5(NoteWave5TextKeys.infoTags, '标签'),
                _note.tags.join(context.t.listSeparator),
              ),
            if ((_note.ownerName ?? '').isNotEmpty)
              _row(
                hud,
                noteWave5(NoteWave5TextKeys.infoOwner, '所有者'),
                _note.ownerName!,
              ),
            if (_note.encrypt)
              _row(
                hud,
                noteWave5(NoteWave5TextKeys.infoEncrypted, '加密'),
                t.noteEncrypted,
              ),
            // ---- N4：位置（官方 `Info.Panel` 的 `location_display` 行）----
            // 能力位缺 `SYNO.NoteStation.Info` → 整个入口隐藏；未检测 → fail-open。
            if (ref.watch(noteLocationCapabilityProvider)) ...[
              Row(
                children: [
                  Expanded(
                    child: _row(
                      hud,
                      noteLocation(NoteLocationTextKeys.location, '位置'),
                      noteLocationDisplayText(
                            _note.location,
                            _note.latitude,
                            _note.longitude,
                          ).isEmpty
                          ? noteWave5(NoteWave5TextKeys.infoUnset, '—')
                          : noteLocationDisplayText(
                              _note.location,
                              _note.latitude,
                              _note.longitude,
                            ),
                      key: const Key('note-info-location'),
                    ),
                  ),
                  IconButton(
                    key: const Key('note-info-location-edit'),
                    tooltip: noteLocation(
                      NoteLocationTextKeys.setLocation,
                      '设置位置',
                    ),
                    icon: const Icon(Icons.place_outlined),
                    onPressed: _busy
                        ? null
                        : () => showNoteLocationSheet(context, ref, _note),
                  ),
                ],
              ),
            ],
            const Divider(height: Gap.lg),
            // ---- N3：来源链接（查看 + 编辑 + 打开）----
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        noteWave5(
                          NoteWave5TextKeys.infoSource,
                          '来源链接',
                        ),
                        style: TextStyle(color: hud.dim, fontSize: 11),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        src.isEmpty
                            ? noteWave5(
                                NoteWave5TextKeys.infoUnset,
                                '—',
                              )
                            : src,
                        key: const Key('note-info-source'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (src.isNotEmpty)
                  IconButton(
                    key: const Key('note-info-source-open'),
                    tooltip: noteWave5(
                      NoteWave5TextKeys.sourceUrlOpen,
                      '打开链接',
                    ),
                    icon: const Icon(Icons.open_in_new),
                    onPressed: _busy ? null : () => _openSource(src),
                  ),
                IconButton(
                  key: const Key('note-info-source-edit'),
                  tooltip: noteWave5(
                    NoteWave5TextKeys.sourceUrlEdit,
                    '编辑来源链接',
                  ),
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _busy ? null : _editSource,
                ),
              ],
            ),
            // ---- I2：改口令（只有加密笔记才有这个入口）----
            if (_note.encrypt) ...[
              const Divider(height: Gap.lg),
              OutlinedButton.icon(
                key: const Key('note-info-change-password'),
                onPressed: _busy ? null : _changePassword,
                icon: const Icon(Icons.password),
                label: Text(
                  noteWave5(NoteWave5TextKeys.changePassword, '改口令'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(
    DesignPalette hud,
    String label,
    String value, {
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Gap.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(color: hud.dim, fontSize: 11),
          ),
        ),
        Expanded(child: Text(value, key: key)),
      ],
    ),
  );

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openSource(String url) async {
    final t = context.t;
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _toast(noteWave5(NoteWave5TextKeys.sourceUrlInvalid, '链接格式不对'));
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        _toast(noteWave5(NoteWave5TextKeys.sourceUrlOpenFailed, '打不开这个链接'));
      }
    } catch (e) {
      if (mounted) {
        _toast(
          noteWave5Fill(
            NoteWave5TextKeys.sourceUrlOpenFailedDetail,
            '打不开这个链接：{error}',
            {'error': describeNoteError(e, t)},
          ),
        );
      }
    }
  }

  Future<void> _editSource() async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final ctrl = TextEditingController(text: _note.sourceUrl ?? '');
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(noteWave5(NoteWave5TextKeys.sourceUrlEdit, '编辑来源链接')),
        content: TextField(
          key: const Key('note-info-source-field'),
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: noteWave5(
              NoteWave5TextKeys.sourceUrlHint,
              'https://…',
            ),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('note-info-source-save'),
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(t.actionSave),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      // 官方 Web：`/^(\/|http[s]?:\/\/)/i` 才认；否则补 `http://`
      final normalized = _normalizeSourceUrl(picked);
      await api.setNote(
        objectId: _note.objectId,
        ver: _note.ver,
        sourceUrl: normalized,
      );
      ref.invalidate(noteDetailProvider(_note.objectId));
      ref.invalidate(noteListProvider);
      _toast(noteWave5(NoteWave5TextKeys.sourceUrlSaved, '来源链接已保存'));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _toast(
        noteWave5Fill(
          NoteWave5TextKeys.unlockFailed,
          '操作失败：{error}',
          {'error': describeNoteError(e, t)},
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePassword() async {
    final t = context.t;
    final service = ref.read(noteEncryptionProvider);
    if (service == null) return;
    // 正文没同步下来就没法在本地重加密（官方 Android 也会先弹
    // `error_note_not_sync`）
    if (!_note.hasContent || _note.content.isEmpty) {
      _toast(
        noteWave5(
          NoteWave5TextKeys.changePasswordNoContent,
          '笔记正文还没同步下来，暂时不能改口令',
        ),
      );
      return;
    }
    var oldPassword = '';
    final newPassword = await showDialog<String>(
      context: context,
      builder: (ctx) => _ChangePasswordDialog(
        onOldPassword: (v) => oldPassword = v,
      ),
    );
    if (newPassword == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await service.changePassword(
        _note,
        oldPassword: oldPassword,
        newPassword: newPassword,
      );
      ref.invalidate(noteListProvider);
      ref.invalidate(noteDetailProvider(_note.objectId));
      _toast(noteWave5(NoteWave5TextKeys.changePasswordDone, '口令已修改'));
      if (mounted) Navigator.of(context).pop();
    } on NoteDecryptException {
      _toast(t.noteWrongPassword);
    } on NotePasswordException {
      _toast(t.noteWrongPassword);
    } catch (e) {
      _toast(
        noteWave5Fill(
          NoteWave5TextKeys.changePasswordFailed,
          '改口令失败：{error}',
          {'error': describeNoteError(e, t)},
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 官方 Web `getInfoData` 的规范化：不以 `/` 或 `http(s)://` 开头就补 `http://`。
String _normalizeSourceUrl(String raw) {
  if (raw.isEmpty) return '';
  final ok = raw.startsWith('/') || RegExp(r'^https?://', caseSensitive: false).hasMatch(raw);
  return ok ? raw : 'http://$raw';
}

/// 改口令对话框：旧口令 / 新口令 / 确认新口令。
///
/// 通过 [onOldPassword] 把旧口令回填给调用方（官方 Android
/// `ChangePasswordDialogFragment` 也是三个输入框）。
class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.onOldPassword});

  final void Function(String) onOldPassword;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final t = context.t;
    // 先做官方同款校验：非空 + 两次一致 + 长度上限
    if (_old.text.isEmpty) {
      setState(
        () => _error = noteWave5(
          NoteWave5TextKeys.passwordRequired,
          '请输入当前口令',
        ),
      );
      return;
    }
    if (_new.text.isEmpty) {
      setState(
        () => _error = noteWave5(
          NoteWave5TextKeys.newPasswordRequired,
          '请输入新口令',
        ),
      );
      return;
    }
    if (_new.text != _confirm.text) {
      setState(
        () => _error = noteWave5(
          NoteWave5TextKeys.passwordMismatch,
          '两次输入的新口令不一致',
        ),
      );
      return;
    }
    if (_new.text == _old.text) {
      setState(
        () => _error = noteWave5(
          NoteWave5TextKeys.passwordUnchanged,
          '新口令和当前口令一样',
        ),
      );
      return;
    }
    final msg = NoteEncryptionService.validatePassword(_new.text, t);
    if (msg != null) {
      setState(() => _error = msg);
      return;
    }
    widget.onOldPassword(_old.text);
    Navigator.of(context).pop(_new.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('note-change-password-dialog'),
      title: Text(
        noteWave5(NoteWave5TextKeys.changePasswordTitle, '修改笔记口令'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('note-change-password-old'),
            controller: _old,
            obscureText: true,
            autofocus: true,
            maxLength: 32,
            decoration: InputDecoration(
              labelText: noteWave5(
                NoteWave5TextKeys.oldPassword,
                '当前口令',
              ),
              counterText: '',
              errorText: _error,
            ),
          ),
          TextField(
            key: const Key('note-change-password-new'),
            controller: _new,
            obscureText: true,
            maxLength: 32,
            decoration: InputDecoration(
              labelText: noteWave5(
                NoteWave5TextKeys.newPassword,
                '新口令',
              ),
              counterText: '',
            ),
          ),
          TextField(
            key: const Key('note-change-password-confirm'),
            controller: _confirm,
            obscureText: true,
            maxLength: 32,
            decoration: InputDecoration(
              labelText: noteWave5(
                NoteWave5TextKeys.confirmPassword,
                '确认新口令',
              ),
              counterText: '',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(
          key: const Key('note-change-password-ok'),
          onPressed: _submit,
          child: Text(context.t.actionSave),
        ),
      ],
    );
  }
}
