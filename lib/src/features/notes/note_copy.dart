// 笔记复制 / 复制到加密 / 复制到明文（A9/A10 / P0-5）。
//
// [E2] 官方 `callables/operations/CopyNoteOperation.copyNote`：
//   `SYNO.NoteStation.Note / copy` **v1**，参数
//   `object_id` / `title` / `parent_id`（都 Gson 编码），加密态转换再加
//   `encrypt` + `content`：
//     * 明文 → 加密 / 加密 → 加密：`encrypt=true`，`content` = **客户端加密后的密文**
//     * 加密 → 明文：`encrypt=false`，`content` = **客户端解密后的明文**
//   普通复制（官方 `EncAction.NONE`）不发这两个字段。
// 官方入口：`NoteFragment` / `NoteBaseAdapter` 的 `copymove("copy", …)` →
// `CopyMoveDialogFragment`，菜单项 `copy` / `copy_to_encrypt` /
// `copy_to_unencrypt`（`menu_note.xml`）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/settings/app_settings.dart';
import '../../data/dto/note_dto.dart';
import '../../data/note_crypto.dart';
import 'note_encryption.dart';
import 'note_leave_encrypt.dart';
import 'note_providers.dart';
import 'note_reminder.dart';
import 'note_widgets.dart';

/// 复制动作
enum NoteCopyAction {
  /// 普通复制（`Note/copy`，不发 encrypt/content）
  duplicate,

  /// 复制到加密（明文→加密 / 加密→加密）
  toEncrypt,

  /// 复制到明文（加密→明文）
  toPlaintext,
}

/// 复制一份标题：官方是「原标题 + 后缀」，这里用同款
String copiedNoteTitle(String title) {
  final base = title.trim().isEmpty
      ? noteB(NoteBTextKeys.copyTitle, '无标题笔记')
      : title.trim();
  return '$base${noteB(NoteBTextKeys.copySuffix, '（副本）')}';
}

/// 执行复制动作；成功返回新笔记 id，取消/失败返回 null。
///
/// * [action] == duplicate / toEncrypt：明文正文用 `note.content`；
/// * [action] == toPlaintext：需要笔记已解锁（或现输口令）；
/// * 加密→加密：先用旧口令解出明文，再用新口令加密。
Future<String?> runNoteCopyAction(
  BuildContext context,
  WidgetRef ref,
  NoteDto note,
  NoteCopyAction action,
) async {
  final api = ref.read(noteApiProvider);
  if (api == null) return null;
  final t = context.t;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final title = copiedNoteTitle(note.title);
  final parentId = note.parentId.isEmpty ? null : note.parentId;
  try {
    switch (action) {
      case NoteCopyAction.duplicate:
        final id = await api.copyNote(
          note.objectId,
          parentId: parentId,
          title: title,
        );
        ref.invalidate(noteListProvider);
        messenger?.showSnackBar(
          SnackBar(content: Text(noteB(NoteBTextKeys.copyDone, '已复制'))),
        );
        return id;
      case NoteCopyAction.toEncrypt:
        final password = await askNoteCopyPassword(
          context,
          title: noteB(NoteBTextKeys.copyToEncrypt, '复制到加密'),
        );
        if (password == null || !context.mounted) return null;
        final String plain;
        if (note.encrypt) {
          // 加密 → 加密：用旧口令解出明文
          final unlock = await _unlockPlain(context, ref, note);
          if (unlock == null) return null;
          plain = unlock;
        } else {
          plain = note.content;
        }
        final cipher = NoteCrypto.encryptContent(plain, password);
        final id = await api.copyNote(
          note.objectId,
          parentId: parentId,
          title: title,
          encrypt: true,
          content: cipher,
        );
        ref.invalidate(noteListProvider);
        messenger?.showSnackBar(
          SnackBar(content: Text(noteB(NoteBTextKeys.copyDone, '已复制'))),
        );
        return id;
      case NoteCopyAction.toPlaintext:
        if (!note.encrypt) {
          // 明文笔记没有"复制到明文"这个动作（官方菜单也不显示）
          return null;
        }
        // ★ I5：官方 `delete_attachments_when_leave_encrypt`
        //   —— 有附件时先弹确认框（默认勾选沿用上次的选择），
        //   复制成功后再删**原加密笔记**的附件（明文笔记带不了加密附件）。
        final settings = ref.read(settingsServiceProvider);
        final remembered = await settings.leaveEncryptDeleteAttachments();
        var deleteAttachments = false;
        if (shouldAskDeleteAttachments(note.attachments.length)) {
          if (!context.mounted) return null;
          final choice = await askLeaveEncryptAttachments(
            context,
            attachmentCount: note.attachments.length,
            remembered: remembered,
          );
          if (choice == null || !choice.proceed) return null;
          deleteAttachments = choice.deleteAttachments;
          // 记住选择（官方就是这个偏好的用途）
          await settings.setLeaveEncryptDeleteAttachments(deleteAttachments);
        }
        if (!context.mounted) return null; // 上面 await 过（偏好/弹框）
        final plain = await _unlockPlain(context, ref, note);
        if (plain == null) return null;
        final id = await api.copyNote(
          note.objectId,
          parentId: parentId,
          title: title,
          encrypt: false,
          content: plain,
        );
        if (deleteAttachments && note.attachments.isNotEmpty) {
          try {
            await api.deleteNoteAttachments(
              objectId: note.objectId,
              ver: note.ver,
              fileIds: note.attachments.keys.toList(growable: false),
              encrypt: true,
            );
          } catch (_) {
            // 删附件失败不该把"复制成功"变成失败；提示一句
            messenger?.showSnackBar(
              SnackBar(
                content: Text(
                  noteB(
                    NoteBTextKeys.copyFailed,
                    '复制失败：{error}',
                  ).replaceAll('{error}', 'delete_attachments'),
                ),
              ),
            );
          }
        }
        ref.invalidate(noteListProvider);
        messenger?.showSnackBar(
          SnackBar(content: Text(noteB(NoteBTextKeys.copyDone, '已复制'))),
        );
        return id;
    }
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          noteBFill(NoteBTextKeys.copyFailed, '复制失败：{error}', {
            'error': describeNoteError(e, t),
          }),
        ),
      ),
    );
    return null;
  }
}

/// 解出加密笔记的明文：已解锁直接用，未解锁就现问口令。
Future<String?> _unlockPlain(
  BuildContext context,
  WidgetRef ref,
  NoteDto note,
) async {
  final service = ref.read(noteEncryptionProvider);
  final cached = ref.read(noteUnlockStoreProvider)[note.objectId];
  if (cached != null) {
    try {
      return NoteCrypto.decryptContent(note.content, cached.password);
    } on NoteDecryptException {
      // 缓存口令失效 → 重新问
    }
  }
  if (service == null) return null;
  final password = await askNoteCopyPassword(
    context,
    title: noteB(NoteBTextKeys.copyPassword, '输入笔记口令'),
  );
  if (password == null) return null;
  try {
    return await service.unlock(note, password);
  } on NotePasswordException {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.t.noteWrongPasswordRetry)),
      );
    }
    return null;
  }
}

/// 口令输入框（返回 null = 取消）
Future<String?> askNoteCopyPassword(
  BuildContext context, {
  required String title,
}) {
  final ctrl = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const Key('note-copy-password'),
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          decoration: InputDecoration(
            labelText: context.t.notePasscode,
            errorText: error,
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('note-copy-password-ok'),
            onPressed: () {
              final v = ctrl.text;
              final msg = NoteEncryptionService.validatePassword(v);
              if (msg != null) {
                setDialogState(() => error = msg);
                return;
              }
              Navigator.of(context).pop(v);
            },
            child: Text(context.t.actionSave),
          ),
        ],
      ),
    ),
  );
}

/// ★ I5 确认框：退出加密（复制到明文）时是否同时删除附件。
///
/// 官方证据：偏好 `delete_attachments_when_leave_encrypt` +
/// 文案 `delete_attachments_when_leave_encrypt_confirm`。
/// 返回 `null` = 取消整个动作。
Future<LeaveEncryptChoice?> askLeaveEncryptAttachments(
  BuildContext context, {
  required int attachmentCount,
  required bool remembered,
}) {
  var checked = defaultDeleteAttachments(
    attachmentCount: attachmentCount,
    remembered: remembered,
  );
  return showDialog<LeaveEncryptChoice>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        key: const Key('note-leave-encrypt-dialog'),
        title: Text(noteB(NoteBTextKeys.copyToPlaintext, '复制到明文')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              noteBFill(NoteBTextKeys.copyToPlaintext, '这篇笔记有 {n} 个附件。', {
                'n': '$attachmentCount',
              }),
            ),
            const SizedBox(height: 8),
            // ⚠️ 不用 CheckboxListTile（没有 Material 祖先时会有 ink 告警，
            //    布局审计会判缺陷）——沿用 Row + Checkbox。
            Row(
              children: [
                Checkbox(
                  key: const Key('note-leave-encrypt-delete-attachments'),
                  value: checked,
                  onChanged: (v) => setDialogState(() => checked = v ?? false),
                ),
                Expanded(
                  child: Text(
                    noteB(
                      NoteBTextKeys.copyToPlaintext,
                      '同时删除原笔记的附件（加密附件在明文笔记里没有意义）',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('note-leave-encrypt-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(noteB('noteLeaveEncryptCancel', '取消')),
          ),
          FilledButton(
            key: const Key('note-leave-encrypt-ok'),
            onPressed: () => Navigator.of(
              context,
            ).pop((proceed: true, deleteAttachments: checked)),
            child: Text(noteB('noteLeaveEncryptOk', '确定')),
          ),
        ],
      ),
    ),
  );
}
