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
  for (final folder in ['/home/Drive', '/home/Drive/My Drive']) {
    try {
      final r = await api.call('SYNO.FileStation.List', 'list', preferredVersion: 2,
          params: {'folder_path': folder, 'additional': '["size","type"]', 'limit': 100});
      final files = (r['files'] as List?) ?? const [];
      print('== $folder (${files.length})');
      for (final f in files.take(40)) {
        final m = f as Map;
        print('  ${m['name']}  type=${m['isdir'] == true ? 'DIR' : 'file'}');
      }
    } catch (e) {
      print('== $folder ERR $e');
    }
  }
}
