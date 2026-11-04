// ignore_for_file: avoid_print
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      'https://nas.example.com:5001',
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  const nasPassword = String.fromEnvironment('SYNO_NAS_PASSWORD');
  if (nasPassword.isEmpty) {
    print('缺少口令：dart run --define=SYNO_NAS_PASSWORD=… tool/flt_apis.dart');
    return;
  }
  await api.login(
    account: 'demo_user',
    password: nasPassword,
    session: 'Chat',
  );
  for (final e in (api.apiTable ?? {}).entries) {
    if (e.key.contains('Note') || e.key.contains('Office')) {
      print(
        '${e.key.padRight(42)} path=${e.value.path} '
        'v${e.value.minVersion}-${e.value.maxVersion}',
      );
    }
  }
}
