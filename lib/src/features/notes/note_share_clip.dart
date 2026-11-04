// J8/L2：把系统分享面板送进来的载荷**剪藏成一条笔记**（纯 Dart）。
//
// 官方 DS note 的 Android 分享目标：`AndroidManifest.xml:89-98` 已声明
// `SEND */*`（见 `chat_share_intent_test.dart` 的清单断言），官方
// `ShareActivity` 读 `EXTRA_TEXT` / `EXTRA_STREAM`。我们此前只路由到 Chat，
// 这里补「剪藏到笔记」分支：
//   * 文本含 http(s) URL → 走官方网页剪藏（`Note.Ghost/create` v2，回退
//     `Note/create`，见 `note_c3_actions.clipWebPage`）；
//   * 纯文本 → `Note/create` 建一条明文笔记（正文 `<p>…</p>`，HTML 转义）；
//   * 图片/其它文件 → `Note/create` 建笔记后走 `Note/set` **multipart**
//     附件形态（`uploadAttachments`，与编辑器同一条链路）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';
import '../chat/share_intent.dart';
import 'note_c3_actions.dart';
import 'note_gaps_text.dart';
import 'note_html.dart' show noteAttachmentRef, noteImageHtml;
import 'note_providers.dart';

/// 分享剪藏失败（没有可用笔记本 / 未连接 / 服务端拒绝）
class NoteShareClipException implements Exception {
  const NoteShareClipException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 从候选笔记本里挑默认落点：**预设笔记本优先**，否则第一条。
String? defaultNotebookIdForClip(List<NotebookDto> notebooks) {
  if (notebooks.isEmpty) return null;
  for (final nb in notebooks) {
    if (nb.preset) return nb.objectId;
  }
  return notebooks.first.objectId;
}

/// 文本里第一条 http(s) URL（没有则 null）
String? firstUrlIn(String text) {
  final m = RegExp('https?://[^\\s<>"\']+').firstMatch(text);
  return m?.group(0);
}

/// HTML 转义（正文要进 `Note/create` 的 `content`）
String escapeNoteHtml(String raw) => raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _plainTextToNoteHtml(String text) {
  final paragraphs = text
      .split(RegExp(r'\r?\n'))
      .where((p) => p.trim().isNotEmpty)
      .map((p) => '<p>${escapeNoteHtml(p)}</p>')
      .join();
  return paragraphs.isEmpty ? '<p></p>' : paragraphs;
}

/// 把一次系统分享剪藏成笔记，返回新笔记 id（剪藏入队时可能为空串）。
Future<String> clipSharedPayloadToNote(
  WidgetRef ref,
  ShareIntentData data, {
  String? notebookId,
}) async {
  final api = ref.read(noteApiProvider);
  if (api == null) {
    throw NoteShareClipException(
      noteGaps(NoteGapsTextKeys.shareClipFailed, '分享剪藏失败，请稍后再试。'),
    );
  }
  final notebooks = await _loadNotebooks(ref);
  final target = notebookId ?? defaultNotebookIdForClip(notebooks);
  if (target == null || target.isEmpty) {
    throw NoteShareClipException(
      noteGaps(
        NoteGapsTextKeys.shareClipNoNotebook,
        '没有可用的笔记本，无法剪藏到笔记。',
      ),
    );
  }

  final text = data.text.trim();
  final subject = data.subject.trim();

  // ① 纯文本 / URL，且没有附件 → 走剪藏
  if (!data.hasFiles) {
    final url = firstUrlIn(text);
    if (url != null && isValidClipUrl(url)) {
      return clipWebPage(
        ref,
        url: url,
        title: subject.isNotEmpty ? subject : url,
        notebookId: target,
        tags: const [],
      );
    }
    final created = await api.createNote(
      title: subject.isNotEmpty
          ? subject
          : noteGaps(NoteGapsTextKeys.shareClipTitle, '分享的文本'),
      parentId: target,
      html: _plainTextToNoteHtml(text),
    );
    ref.invalidate(noteListProvider);
    return created.objectId;
  }

  // ② 有附件（图片/文件）→ 新建笔记 + `Note/set` multipart 附件
  final title = subject.isNotEmpty
      ? subject
      : (text.isNotEmpty
            ? text.split(RegExp(r'\r?\n')).first
            : noteGaps(NoteGapsTextKeys.shareClipTitle, '分享的文本'));
  final html = text.isEmpty ? '<p></p>' : _plainTextToNoteHtml(text);
  final created = await api.createNote(
    title: title,
    parentId: target,
    html: html,
  );
  // 图片进正文（`<img ref>`），其它文件只作为附件 —— 与编辑器一致。
  //
  // ★ 241 轮修：此前只把 `ref` 塞进附件元数据，**正文里从没写 `<img ref>`**
  //   ⇒ 分享进来的图片"上传了但正文看不见"（与上面的注释、与官方
  //   `ShareActivity` 的行为都不符）。现在同一个 ref 既进元数据也进正文。
  final uploads = <NoteAttachmentUpload>[];
  final body = StringBuffer(html);
  for (final f in data.files) {
    final isImage = _imageLike(f.mime);
    final ref = isImage ? noteAttachmentRef(f.name) : null;
    if (isImage) body.write(noteImageHtml(ref!));
    uploads.add(
      NoteAttachmentUpload(
        path: f.path,
        fileName: f.name,
        mimeType: f.mime.isEmpty ? null : f.mime,
        ref: ref,
        // 非图片不需要缩略图
        convert: isImage,
      ),
    );
  }
  await api.uploadAttachments(
    objectId: created.objectId,
    ver: created.ver,
    files: uploads,
    html: body.toString(),
    title: title,
  );
  ref.invalidate(noteListProvider);
  return created.objectId;
}

bool _imageLike(String mime) => mime.toLowerCase().startsWith('image/');

/// 拉一次笔记本列表（剪藏入口可能还没被 UI watch 过，`.value` 会是 null）。
Future<List<NotebookDto>> _loadNotebooks(WidgetRef ref) async {
  try {
    return await ref.read(notebooksProvider.future);
  } catch (_) {
    return const <NotebookDto>[];
  }
}
