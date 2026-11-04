// ignore_for_file: avoid_print
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url('https://nas.example.com:5001',
        dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  const pw = String.fromEnvironment('SYNO_NAS_PASSWORD');
  await api.login(account: 'demo_user', password: pw, session: 'FileStation');
  final drive = DriveApi(api);
  for (var i = 0; i < 3; i++) {
    final sw = Stopwatch()..start();
    try {
      final r = await drive.list();
      sw.stop();
      print('list#$i ok ms=${sw.elapsedMilliseconds} items=${r.items.length} total=${r.total}');
    } catch (e) {
      sw.stop();
      print('list#$i ERR ms=${sw.elapsedMilliseconds} $e');
    }
  }
  final sw2 = Stopwatch()..start();
  try {
    final r = await drive.listStarred();
    sw2.stop();
    print('starred ok ms=${sw2.elapsedMilliseconds} items=${r.items.length}');
  } catch (e) {
    sw2.stop();
    print('starred ERR ms=${sw2.elapsedMilliseconds} $e');
  }
}
