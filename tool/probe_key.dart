// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      const String.fromEnvironment('SYNO_NAS_URL'),
      dio: DioFactory.create(),
    ),
  );
  await api.discover();
  await api.login(
    account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
    password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
    session: 'Chat',
  );
  final me = await api.call(
    'SYNO.Chat.User',
    'get',
    preferredVersion: 2,
    params: {'user_id': '14'},
  );
  print(
    'user_props.key_pair = ${jsonEncode((me['user_props'] as Map)['key_pair'])}',
  );
  final list = await api.call(
    'SYNO.Chat.User',
    'list',
    preferredVersion: 3,
    params: {'type': jsonEncode('human')},
  );
  for (final u in (list['users'] as List)) {
    final m = u as Map;
    final kp = (m['user_props'] as Map?)?['key_pair'];
    print(
      '  #${m['user_id']} ${m['nickname']}/${m['username']} type=${m['type']} key=${jsonEncode(kp)}',
    );
  }
}
