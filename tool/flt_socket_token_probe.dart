// ignore_for_file: avoid_print
// 定位：socket 带上 synotoken（Auth v7 才有的 CSRF 令牌）会不会握不上手。
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<bool> trySocket(
  String baseUrl,
  String sid,
  String? token,
  String label,
) async {
  final socket = ChatSocket(baseUrl: baseUrl, sid: sid, synotoken: token);
  var ready = false;
  for (var attempt = 1; attempt <= 2 && !ready; attempt++) {
    await socket.connect();
    try {
      await socket.waitReady(timeout: const Duration(seconds: 8));
      ready = true;
    } catch (_) {
      socket.disposeSocketOnly();
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  print(
    '$label → ready=$ready conn_id=${socket.connId} lastError=${socket.lastError}',
  );
  socket.dispose();
  return ready;
}

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  final s = await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'Chat',
  );
  print('token=${s.synotoken} sid=${s.sid.substring(0, 6)}…');
  await trySocket(url, s.sid, s.synotoken, '① 带 synotoken');
  final s2 = await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'Chat',
    version: 6,
  );
  print('v6 token=${s2.synotoken}');
  await trySocket(url, s2.sid, null, '② 不带 synotoken（同 sid）');
  await trySocket(url, s2.sid, s2.synotoken, '③ v6 的 synotoken');
  api.transport.close();
  exit(0);
}
