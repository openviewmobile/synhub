// 「我的 Drive → Office 文档只读预览」的探针（batch ③ Office L1）。
//
// 权威来源分两层：
//   1. NAS 上装的 **Synology Office SPK 3.8.0-22711**（`/tmp/spk/export_Office`）：
//      `SYNO.Office.File.extract`（v1，authLevel=1，普通用户可用）、
//      `SYNO.Office.Export/download`（v1，浏览器里是 **POST 表单 → 直接回文件字节**，
//      参数在 `path,object_id,password,format,ver` 里挑）；
//      只读路径的官方 URL 形如 `/oo/r/<link_id>`（`getOfficeURL`）。
//   2. 本探针 —— 在真机 NAS 上把这些参数的**实际效果**钉死（尤其"导出成 PDF"这条路，
//      因为我们要用 Flutter 现成的 PDF 渲染器吃掉它，而不是塞 WebView）。
//
// 跑法：
//   SYNO_NAS_URL=https://… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/office_probe.dart [probe|clean]
//
// 写操作只落在自己的 `drive-probe` 目录里，跑完删干净（含回收站）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

const probeDir = '/mydrive/drive-probe';

Future<DsmWebApi> _login() async {
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
    session: 'FileStation',
  );
  return api;
}

Future<Map<String, dynamic>> dump(
  DsmWebApi api,
  String name,
  String method, {
  Map<String, dynamic> params = const {},
  int? version,
  int cap = 400,
}) async {
  try {
    final data = await api.call(
      name,
      method,
      params: params,
      preferredVersion: version ?? 1,
    );
    final s = jsonEncode(data);
    print(
      '✔ $name/$method ${jsonEncode(params)} → '
      '${s.length > cap ? '${s.substring(0, cap)}…' : s}',
    );
    return data;
  } catch (e) {
    print('✘ $name/$method ${jsonEncode(params)} → $e');
    return const {};
  }
}

/// 一个**最小但合法**的 .docx（[Content_Types].xml + _rels + word/document.xml）
Uint8List minimalDocx(String text) {
  final archive = Archive();

  void add(String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('[Content_Types].xml', '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''');
  add('_rels/.rels', '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''');
  add('word/document.xml', '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>$text</w:t></w:r></w:p>
  </w:body>
</w:document>''');

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// FileStation 上传（放进 `/home/Drive/drive-probe`，Drive 守护进程会扫到）
Future<void> uploadDocx(DsmWebApi api, Uint8List bytes) async {
  final tmp = Directory.systemTemp.createTempSync('office-probe');
  final file = File('${tmp.path}/probe-doc.docx')..writeAsBytesSync(bytes);
  try {
    await api.postMultipart(
      api.apiPath('SYNO.FileStation.Upload'),
      query: {
        'api': 'SYNO.FileStation.Upload',
        'version': '2',
        'method': 'upload',
        'path': '/home/Drive/drive-probe',
        'create_parents': 'true',
        'overwrite': 'true',
      },
      fields: {
        'api': 'SYNO.FileStation.Upload',
        'version': '2',
        'method': 'upload',
        'path': '/home/Drive/drive-probe',
        'create_parents': 'true',
        'overwrite': 'true',
      },
      fileField: 'file',
      filePath: file.path,
    );
    print(
      '✔ 上传 probe-doc.docx（${bytes.length} 字节，FileStation → /home/Drive/drive-probe）',
    );
    // 落盘确认（Drive 的索引是异步的，先看磁盘上有没有）
    final fs = await api.call(
      'SYNO.FileStation.List',
      'list',
      preferredVersion: 2,
      params: {
        'folder_path': '/home/Drive/drive-probe',
        'additional': '["size"]',
      },
    );
    final names = ((fs['files'] as List?) ?? const [])
        .map((e) => '${(e as Map)['name']}(${e['size']})')
        .toList();
    print('   磁盘 /home/Drive/drive-probe：$names');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

Future<void> clean(DriveCtx ctx) async {
  final listed = await dump(
    ctx.api,
    'SYNO.SynologyDrive.Files',
    'list',
    version: 11,
    params: {'path': '/mydrive', 'offset': 0, 'limit': 100},
  );
  final items = ((listed['items'] as List?) ?? const [])
      .map((e) => (e as Map).cast<String, dynamic>())
      .where((e) => e['name'] == 'drive-probe')
      .toList();
  if (items.isNotEmpty) {
    print('== 删除 /mydrive/drive-probe ==');
    await dump(
      ctx.api,
      'SYNO.SynologyDrive.Files',
      'delete',
      version: 2,
      params: {
        'files': jsonEncode(['id:${items.single['file_id']}']),
        'permanent_delete': true,
      },
    );
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  final trash = await dump(
    ctx.api,
    'SYNO.SynologyDrive.Trash',
    'list',
    version: 1,
    params: {'path': '/mydrive', 'offset': 0, 'limit': 100},
  );
  final residues = ((trash['items'] as List?) ?? const []);
  if (residues.isEmpty) {
    print('== 回收站已空 ==');
    return;
  }
  print('== 清空回收站（${residues.length} 项，全是我的测试残留）==');
  await dump(
    ctx.api,
    'SYNO.SynologyDrive.Trash',
    'empty',
    version: 1,
    params: {'path': '/mydrive'},
  );
}

class DriveCtx {
  DriveCtx(this.api);
  final DsmWebApi api;
}

Future<void> main(List<String> argv) async {
  final mode = argv.isEmpty ? 'probe' : argv.first;
  final api = await _login();
  final ctx = DriveCtx(api);
  final drive = 'SYNO.SynologyDrive.Files';
  final office = 'SYNO.Office';

  if (mode == 'clean') {
    await clean(ctx);
    api.transport.close();
    exit(0);
  }

  print('== Office 套件是否可用 ==');
  await dump(api, '$office.Info', 'get');
  await dump(api, '$office.Info', 'get', version: 1, params: const {});

  print('== 准备一个 docx（自己造的最小 OOXML，FileStation 上传进 Drive）==');
  await dump(
    api,
    drive,
    'create',
    version: 2,
    params: {'path': probeDir, 'type': 'folder'},
  );
  await uploadDocx(api, minimalDocx('office probe 2026-09-18'));
  if (mode == 'seed') {
    print('== seed 模式：留在 Drive 里不动（App 里看一眼再跑 clean）==');
    api.transport.close();
    exit(0);
  }

  // Drive 守护进程扫盘要时间：轮询到它出现为止（最多 30 秒）
  var items = <Map<String, dynamic>>[];
  for (var i = 1; i <= 10; i++) {
    await Future<void>.delayed(const Duration(seconds: 3));
    final sub = await dump(
      api,
      drive,
      'list',
      version: 11,
      params: {'path': probeDir, 'offset': 0, 'limit': 100},
      cap: 120,
    );
    items = ((sub['items'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    print('   ${i * 3}s：Drive 看到 ${items.length} 项');
    if (items.isNotEmpty) break;
  }
  for (final it in items) {
    print(
      '   条目 ${it['name']} id=${it['file_id']} content=${it['content_type']} '
      'link=${it['permanent_link']}',
    );
  }
  final doc = items.where((e) => '${e['name']}'.endsWith('.docx')).toList();
  if (doc.isEmpty) {
    print('✘ 没扫到 docx，放弃；下面清掉探针目录');
    await clean(ctx);
    api.transport.close();
    exit(1);
  }
  final link = '${doc.single['permanent_link']}';

  print('== Office.File.extract：参数矩阵（link_id？path？id？）==');
  final relPath = '${doc.single['path']}';
  final matrix = <String, Map<String, dynamic>>{
    'link_id': {'link_id': link},
    'path(相对 /mydrive)': {'path': relPath},
    'display_path': {'path': '${doc.single['display_path']}'},
    'id:file_id': {'path': 'id:${doc.single['file_id']}'},
    'object_id': {'object_id': '${doc.single['file_id']}'},
  };
  final results = <String, String>{};
  for (final e in matrix.entries) {
    final r = await dump(
      api,
      '$office.File',
      'extract',
      params: e.value,
      cap: 160,
    );
    results[e.key] = '${r['data'] ?? ''}'.trim();
  }
  print('== extract 结果一览 ==');
  results.forEach((k, v) => print('   $k → ${v.isEmpty ? '(空/失败)' : v}'));

  print('== Office.Export/download（官方是 POST 表单 → 回文件字节）==');
  for (final e in <Map<String, dynamic>>[
    {'link_id': link, 'format': 'pdf'},
    {'path': relPath, 'format': 'pdf'},
    {'object_id': '${doc.single['file_id']}', 'format': 'pdf'},
    {'link_id': link, 'format': 'docx'},
  ]) {
    try {
      final body = await api.transport.postForm(api.apiPath('$office.Export'), {
        'api': '$office.Export',
        'version': '1',
        'method': 'download',
        ...e,
      });
      print('POST($e) → ${body.length} 字符 body=$body');
    } catch (err) {
      print('✘ POST($e) → $err');
    }
  }

  print('== 收尾：删探针目录 + 清回收站 ==');
  await clean(ctx);
  api.transport.close();
  exit(0);
}
