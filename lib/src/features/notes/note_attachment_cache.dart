// 笔记附件的**本地缓存落点**（第 119 轮 / 台账 J9 的 UI 一半）。
//
// 为什么需要它：官方"有附件 → `ACTION_SEND_MULTIPLE`"那一支要求
// **本地文件路径 + FileProvider uri**（第 111 轮已把通道做好），
// 而附件在服务端（`Note/download` v1，第 118 轮已实现）⇒ 必须先落盘。
//
// 落点：应用文档目录下的 `note_attachments/<noteId>/<sanitized name>`。
//   * 放在**应用私有目录**（不用共享存储）：附件可能含隐私内容，
//     且 `file_paths.xml` 已把 `<files-path>` + `app_flutter` 授权给
//     FileProvider ⇒ 能在不额外申请权限的前提下分享出去；
//   * 文件名**净化**（只留 `[A-Za-z0-9._-]`，其余换 `_`）防目录穿越；
//   * 同名冲突加 `-<fileId前缀>` 后缀，避免两条附件互相覆盖。
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/user_facing_error.dart';
import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';

/// 附件名净化（纯函数，便于离线断言）。
///
/// 规则与仓库里照片备份的目录名净化**一致**（同一个"只留安全字符"口径），
/// 但**不共用代码**：那边是设备目录名，这里是文件名，语义不同。
String safeAttachmentName(String raw) {
  final sb = StringBuffer();
  for (final c in raw.runes) {
    // ① 控制字符与 NUL 直接丢；
    // ② 路径分隔符 + Windows 保留字符换 `_`（防目录穿越 / 跨平台落盘）；
    // ③ **其余原样保留** —— 中文/日文/空格/长名字都要留住，
    //    附件分享出去应该还是**原来的名字**（第 119 轮首版把中文吃成
    //    `2024.xlsx`，属"净化过度"，已修正）。
    if (c < 0x20 || c == 0x7f) continue;
    final ch = String.fromCharCode(c);
    sb.write(RegExp(r'[/\\:*?"<>|]').hasMatch(ch) ? '_' : ch);
  }
  // 去掉开头/结尾的 `.` 与 `_`：`..` 开头的相对路径、隐藏文件都不该出现
  final s = sb.toString().replaceAll(RegExp(r'^[._]+|[._\s]+$'), '');
  return s.isEmpty ? 'attachment' : s;
}

/// 一条附件的本地目标路径（纯函数）。
///
/// [fileId] 只取前 8 个安全字符做后缀，避免文件名过长。
String attachmentCachePath({
  required String rootDir,
  required String noteId,
  required String fileId,
  required String name,
}) {
  final suffix = fileId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  final tail = suffix.length > 8 ? suffix.substring(0, 8) : suffix;
  final fileName = tail.isEmpty
      ? safeAttachmentName(name)
      : '${safeAttachmentName(name)}-$tail';
  // 手写 `/` 拼接：Android/Linux 路径分隔符一致，且本函数要**纯**
  // （不引入 `package:path` 依赖，也不受宿主平台影响）
  return '$rootDir/${safeAttachmentName(noteId)}/$fileName';
}

/// 把一条附件下到本地缓存，返回本地路径。
///
/// [rootDir] 为空时用 `getApplicationDocumentsDirectory()`；
/// 用例可注入固定目录避免碰平台通道。
Future<String> downloadNoteAttachmentToCache({
  required NoteStationApi api,
  required String noteId,
  required NoteAttachmentDto attachment,
  String? rootDir,
  void Function(int received, int total)? onProgress,
}) async {
  final root = rootDir ?? (await getApplicationDocumentsDirectory()).path;
  final target = attachmentCachePath(
    rootDir: root,
    noteId: noteId,
    fileId: attachment.fileId,
    name: attachment.name,
  );
  final file = File(target);
  await file.parent.create(recursive: true);
  final bytes = await api.downloadAttachment(
    noteId,
    attachment.fileId,
    onProgress: onProgress,
  );
  await file.writeAsBytes(bytes, flush: true);
  return target;
}

/// 把一条笔记的**所有**附件下到缓存；单个失败**跳过**（不拖垮整批），
/// 返回成功落盘的路径列表。
///
/// 与官方 `prepareMailContent` 的口径一致：附件是"能带就带"，
/// 不是"有一个失败就整封邮件不发"。
Future<List<String>> downloadNoteAttachments({
  required NoteStationApi api,
  required NoteDto note,
  String? rootDir,
  void Function(String? error)? onError,
}) async {
  final out = <String>[];
  for (final a in note.attachments.values) {
    if (a.fileId.isEmpty) continue;
    try {
      out.add(
        await downloadNoteAttachmentToCache(
          api: api,
          noteId: note.objectId,
          attachment: a,
          rootDir: rootDir,
        ),
      );
    } catch (e) {
      onError?.call(userFacingError(e));
    }
  }
  return out;
}
