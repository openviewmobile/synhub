// 列出 NAS 上 /home/Books（真机找一本**带目录的真实 EPUB** 来验 TOC）
// ignore_for_file: avoid_print
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
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
  final dir = args.isEmpty ? '/home/Books' : args.first;
  final r = await flt.listFolder(folderPath: dir, limit: 200);
  print('$dir (${r.total})');
  for (final e in r.entries) {
    print('  ${e.isDir ? "DIR " : "FILE"} ${e.name}  ${e.size}');
  }
  await api.logout();
  exit(0);
}
