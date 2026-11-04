// 编辑回写的真机探针（P1）：验证「HTML → Delta → HTML」往返之后，
//  ① 正文里的图片 `ref` 还在；② 保存时不带 `attachment` 也不会丢附件。
//
// 步骤：建一条临时笔记 → 传一张图 → Note/get → 转 Delta → 转回 HTML →
// Note/set（**不带** attachment）→ Note/get → 对比 → 删掉临时笔记。
//
// 用法：SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//       dart run tool/note_edit_roundtrip.dart [图片路径]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/notes/note_html.dart';

Future<void> main(List<String> args) async {
  final imagePath = args.isNotEmpty ? args.first : '/tmp/l1.png';
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'NoteStation',
  );
  final notes = NoteStationApi(api);

  final notebooks = await notes.listNotebooks();
  final notebook = notebooks.firstWhere(
    (n) => n.preset,
    orElse: () => notebooks.first,
  );
  print('记事本：${notebook.displayTitle} (${notebook.objectId})');

  final file = File(imagePath);
  final name = imagePath.split('/').last;
  final ref = noteAttachmentRef(name);
  final placeholder = '<p>$name</p>${noteImageHtml(ref)}';

  if (!file.existsSync()) {
    stderr.writeln('图片不存在：$imagePath');
    exit(2);
  }
  final created = await notes.createNote(
    title: '编辑回写探针',
    parentId: notebook.objectId,
    html: placeholder,
  );
  print('① 建笔记 ${created.objectId} ver=${created.ver}');

  final uploaded = await notes.uploadAttachments(
    objectId: created.objectId,
    ver: created.ver,
    files: [NoteAttachmentUpload(path: file.path, fileName: name, ref: ref)],
    html: placeholder,
  );
  print(
    '   上传回包：ver=${uploaded?.ver} 附件=${uploaded?.attachments.length}'
    ' content=${(uploaded?.content ?? "").length} 字节',
  );

  // ⚠️ `Note/set` 的回包**不带 content**（只有 ver/attachment/mtime），
  // 想拿正文必须再 `Note/get` 一次 —— 否则下一步"往返"会把正文当空串！
  final note = await notes.getNote(created.objectId);
  print('② 回读 ver=${note.ver} 附件=${note.attachments.length}');
  for (final a in note.attachments.values) {
    print('   file_id=${a.fileId} ${a.name} ${a.size}B ref=${a.ref}');
  }
  final content1 = note.content;
  print('③ Note/get content1 = $content1');

  // ④ 走客户端同一条转换链：HTML → Delta → HTML
  final resolver = NoteImageResolver.ofAttachments(note.attachments);
  final delta = noteHtmlToDelta(content1, resolver: resolver);
  final roundTripped = noteDeltaToNoteHtml(
    delta,
    refOf: (fileId) => note.attachments[fileId]?.ref,
  );
  print('④ 往返后      content2 = $roundTripped');

  // ⑤ 保存：**不带 attachment**（改文字时的常规保存）
  await notes.setNote(
    objectId: created.objectId,
    ver: note.ver,
    title: note.title,
    html: roundTripped,
  );
  final after = await notes.getNote(created.objectId);
  print('⑤ 保存后 ver=${after.ver} 附件=${after.attachments.length}');
  print('   服务端 content = ${after.content}');

  final thumb = await api.getBytes(
    notes.attachmentUrl(
      created.objectId,
      after.attachments.keys.first,
      thumb: true,
    ),
  );
  print(
    '   附件缩略图 ${thumb.length} 字节（PNG 头=${thumb.length > 8 && thumb[1] == 0x50}）',
  );

  final same = _normalize(after.content) == _normalize(roundTripped);
  final kept = after.attachments.length == note.attachments.length;
  final refKept = after.content.contains('ref="$ref"');
  print('');
  print('正文与服务端一致：${same ? '✅' : '❌'}');
  print('附件没丢：${kept ? '✅' : '❌'}');
  print('ref 没丢：${refKept ? '✅' : '❌'}');

  // ⑥ 收尾：删掉探针笔记（进回收站），不碰用户的笔记
  await notes.deleteNote(created.objectId);
  print('⑥ 探针笔记已删除');
  api.transport.close();
  exit(same && kept && refKept ? 0 : 1);
}

String _normalize(String html) => html.replaceAll(RegExp(r'\s+'), ' ').trim();
