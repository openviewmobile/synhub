// ignore_for_file: avoid_print
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
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
  for (final spec in [
    [
      'SYNO.FileStation.Info',
      'get',
      {'additional': '["support_virtual_folder","support_sharing"]'},
    ],
    ['SYNO.FileStation.Settings', 'list', {}],
    ['SYNO.FileStation.VFS', 'list', {}],
    ['SYNO.Core.AppPriv', 'list', {}],
    ['SYNO.Core.CurrentUser', 'get', {}],
  ]) {
    try {
      final r = await api.call(
        spec[0] as String,
        spec[1] as String,
        preferredVersion: 3,
        params: (spec[2] as Map).cast<String, dynamic>(),
      );
      print(
        '${spec[0]}.${spec[1]} → ${r.toString().substring(0, r.toString().length > 700 ? 700 : r.toString().length)}',
      );
    } catch (e) {
      print('${spec[0]}.${spec[1]} !! $e');
    }
  }
  api.transport.close();
  exit(0);
}
