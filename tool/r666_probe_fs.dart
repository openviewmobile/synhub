// ignore_for_file: avoid_print
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url('https://nas.example.com:5001',
        dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  const pw = String.fromEnvironment('SYNO_NAS_PASSWORD');
  await api.login(account: 'demo_user', password: pw, session: 'FileStation');
  Future<void> ls(String p) async {
    try {
      final r = await api.call('SYNO.FileStation.List', 'list',
          preferredVersion: 2,
          params: {'folder_path': p, 'additional': '["type"]', 'limit': 50});
      final names = ((r['files'] as List?) ?? const [])
          .map((e) => '${(e as Map)['name']}${e['isdir'] == true ? "/" : ""}')
          .join(', ');
      print('$p → ${names.isEmpty ? "(空)" : names}');
    } catch (e) {
      print('$p ERR $e');
    }
  }

  await ls('/');
  await ls('/home/Video');
  await ls('/video');
  await ls('/docker');
  await ls('/docker/#recycle');
}
