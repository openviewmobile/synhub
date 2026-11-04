// 把 NAS 上的图片作为**笔记附件**传进 Note Station（P1 的"插图"链路验证）。
//
// 这条链路完全照官方实现走（我们不做"私有 API"）：
//
//   1. `SYNO.NoteStation.Notebook/list` → 空则 `Notebook/create` v1
//      （`title` + `ctime`，字段抄反编译的 `CreateNotebookOperation`）
//   2. `SYNO.NoteStation.Note/create` v1 → 拿 `object_id` / `ver`
//   3. `SYNO.NoteStation.Note/set` **v2 + multipart**：正文里带
//      `<img … ref="…">` 占位，`attachment` 里每个附件用
//      `{action:create, name:<文件名 hashCode>, format:raw, ref, convert}`
//      —— 与 Android `SetNoteOperationV2` + `ApiRequest` 逐字对应
//      （multipart 字段名也是文件名 hashCode，`filename=` 才是真名）
//   4. `SYNO.NoteStation.Note/get` 回读，确认正文/附件/版本号
//
// 用法：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/note_upload.dart --files=/home/l1.png,/home/nf.png \
//     --title='l1.png / nf.png' [--notebook='我的记事本'] [--keep]
//
// `--keep` 时不删临时文件（默认下到 /tmp 后删掉）。
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> argv) async {
  final args = _args(argv);
  final url = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_ACCOUNT']!;
  final password = Platform.environment['SYNO_PASSWORD']!;
  final paths = (args['files'] ?? '').split(',').where((s) => s.isNotEmpty);
  final title = args['title'] ?? '图片笔记';
  final notebookTitle = args['notebook'] ?? '我的记事本';
  if (paths.isEmpty) {
    stderr.writeln('要传哪些文件？--files=/home/a.png,/home/b.png');
    exit(2);
  }

  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  final session = await api.login(
    account: account,
    password: password,
    session: 'NoteStation',
  );
  print('① 登录 OK（session=NoteStation，sid=${session.sid.substring(0, 4)}…）');

  // ---- 记事本：没有就按官方默认名建一个
  final fs = FileStationApi(api);
  final notes = NoteStationApi(api);
  var notebooks = await notes.listNotebooks();
  print('② 记事本 ${notebooks.length} 个');
  for (final nb in notebooks) {
    print('   ${nb.objectId}  ${nb.title}  ver=${nb.ver}');
  }
  if (notebooks.isEmpty) {
    final id = await notes.createNotebook(notebookTitle);
    notebooks = await notes.listNotebooks();
    print('   已新建「$notebookTitle」→ $id');
  }
  final notebook = notebooks.first;

  // ---- 先把图片从 FileStation 下到本地（官方的 raw 上传就是读本地文件）
  final tmpDir = Directory.systemTemp.createTempSync('note-upload-');
  final localFiles = <({String path, String name, int size})>[];
  for (final remote in paths) {
    final name = remote.split('/').last;
    final local = File('${tmpDir.path}/$name');
    final bytes = await api.getBytes(
      fs.downloadUrl([remote], mode: 'download'),
    );
    await local.writeAsBytes(bytes);
    localFiles.add((path: local.path, name: name, size: bytes.length));
    print('③ 下载 $remote → ${local.path}（${bytes.length} 字节）');
  }

  // ---- 建笔记（正文先带占位 img）
  final refs = <String, String>{}; // 文件名 → ref
  for (final f in localFiles) {
    // 官方 Web 端的 ref = base64(时间戳 + 文件名)（`genUniqueImageRef`）
    refs[f.name] = base64Encode(
      utf8.encode('${DateTime.now().millisecondsSinceEpoch}${f.name}'),
    );
  }
  final html = StringBuffer();
  for (final f in localFiles) {
    html.write('<p>${f.name}</p>');
    html.write(
      '<img class="syno-notestation-image-object" '
      'src="webman/3rdparty/NoteStation/images/transparent.gif" '
      'data-mce-src="webman/3rdparty/NoteStation/images/transparent.gif" '
      'ref="${refs[f.name]}" adjust="true">',
    );
  }
  final created = await notes.createNote(
    title: title,
    parentId: notebook.objectId,
    html: html.toString(),
  );
  print('④ 新建笔记 ${created.objectId}（ver=${created.ver}）');

  // ---- 上传附件（multipart，字段名 = 文件名 hashCode）
  final updated = await notes.uploadAttachments(
    objectId: created.objectId,
    ver: created.ver,
    html: html.toString(),
    title: title,
    files: [
      for (final f in localFiles)
        NoteAttachmentUpload(
          path: f.path,
          fileName: f.name,
          mimeType: 'image/png',
          convert: true, // 让服务端生成缩略图
          ref: refs[f.name],
        ),
    ],
    onProgress: (sent, total) => print('   上传中 $sent/$total'),
  );
  print('⑤ 上传完成 → ver=${updated?.ver}');
  final attachments = updated?.attachments ?? const {};
  for (final a in attachments.values) {
    print(
      '   file_id=${a.fileId} name=${a.name} size=${a.size} '
      '${a.width}x${a.height} md5=${a.md5} type=${a.type} ref=${a.ref}',
    );
  }

  // ---- 回读：正文最终形态（ref 会被服务端换成 content_id）
  final full = await notes.getNote(created.objectId);
  print('⑥ Note/get 回读');
  print(
    '   title=${full.title} ver=${full.ver} '
    'attachment=${full.attachments.length} 条',
  );
  print('   ---- content ----');
  print(full.content);
  print('   ---- /content ----');

  // ---- 附件直链能不能取到字节（缩略图 + 原图）
  for (final id in attachments.keys) {
    for (final thumb in [true, false]) {
      final u = notes.attachmentUrl(created.objectId, id, thumb: thumb);
      try {
        final bytes = await api.getBytes(u);
        print(
          '   下载 ${thumb ? "thumb" : "raw  "} ${bytes.length} 字节 '
          'magic=${_magic(bytes)}',
        );
      } catch (e) {
        print('   下载 ${thumb ? "thumb" : "raw  "} 失败: $e');
      }
    }
  }

  if (args['keep'] != 'true') {
    tmpDir.deleteSync(recursive: true);
  } else {
    print('   临时目录保留：${tmpDir.path}');
  }
  api.transport.close();
  exit(0);
}

String _magic(List<int> b) {
  if (b.length < 4) return '-';
  if (b[0] == 0x89 && b[1] == 0x50) return 'PNG';
  if (b[0] == 0xFF && b[1] == 0xD8) return 'JPEG';
  return b.take(4).map((e) => e.toRadixString(16)).join();
}

Map<String, String> _args(List<String> argv) {
  final out = <String, String>{};
  for (final a in argv) {
    if (!a.startsWith('--')) continue;
    final i = a.indexOf('=');
    if (i < 0) {
      out[a.substring(2)] = 'true';
    } else {
      out[a.substring(2, i)] = a.substring(i + 1);
    }
  }
  return out;
}
