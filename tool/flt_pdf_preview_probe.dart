// 真机「内嵌 PDF 预览」验收的辅助工具（keeper）：
//   1) 把本机的样例 PDF 上传到 NAS 的某个目录；
//   2) 列出该目录确认它在那儿（App 里能看到才会去点）；
//   3) 结束时可 `clean` 把它删掉（`SYNO.FileStation.Delete`），不留垃圾。
//
// 用法：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/flt_pdf_preview_probe.dart seed  /home   /tmp/sample.pdf
//   …                                                                 clean /home sample.pdf
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<FileStationApi> _login() async {
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
  return FileStationApi(api);
}

void main(List<String> args) async {
  final mode = args.isEmpty ? 'seed' : args[0];
  final fs = await _login();
  if (mode == 'seed') {
    final folder = args.length > 1 ? args[1] : '/home';
    final local = args.length > 2 ? args[2] : '/tmp/pdf_probe_sample.pdf';
    final name = local.split('/').last;
    final id = await fs.upload(
      folderPath: folder,
      filePath: local,
      fileName: name,
      conflict: UploadConflictPolicy.overwrite,
    );
    print('已上传 $name → $folder（upload id=$id）');
    final list = await fs.listFolder(folderPath: folder, limit: 200);
    for (final e in list.entries) {
      if (e.name == name) print('目录里确认存在：${e.path} (${e.humanSize})');
    }
  } else if (mode == 'clean') {
    final folder = args.length > 1 ? args[1] : '/home';
    final name = args.length > 2 ? args[2] : 'pdf_probe_sample.pdf';
    await fs.deleteItems(['$folder/$name']);
    final list = await fs.listFolder(folderPath: folder, limit: 200);
    print('删除后目录：${list.entries.map((e) => e.name).toList()}');
  }
  fs.api.transport.close();
  exit(0);
}
