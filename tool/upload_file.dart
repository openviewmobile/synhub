// 把本地文件传上 NAS（真机验证用）。用法：
//   dart run tool/upload_file.dart <本地路径> <NAS 目录>
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
  final local = args[0];
  final folder = args.length > 1 ? args[1] : '/home';
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
  final flt = FileStationApi(api);
  final name = local.split('/').last;
  await flt.upload(folderPath: folder, filePath: local, fileName: name);
  final r = await flt.listFolder(folderPath: folder, limit: 100);
  print('$folder：${[for (final e in r.entries) e.name].join(", ")}');
  await api.logout();
  exit(0);
}
