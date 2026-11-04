// ignore_for_file: avoid_print
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
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
  for (final p in ['/home', '/home/Drive']) {
    try {
      final r = await flt.listFolder(folderPath: p);
      print(
        '$p: ${[for (final e in r.entries) '${e.name}(${e.isDir ? "d" : "f"})'].join(", ")}',
      );
    } catch (e) {
      print('$p 失败：$e');
    }
  }
  await api.logout();
  exit(0);
}
