// ignore_for_file: avoid_print
// 裸 websocket 看服务端到底回了什么帧（定位 client.init 收不到的原因）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final base = Platform.environment['SYNO_NAS_URL']!;
  final http = HttpClient()..badCertificateCallback = (_, _, _) => true;

  final login =
      await (await http.postUrl(Uri.parse('$base/webapi/entry.cgi'))
            ..headers.contentType = ContentType(
              'application',
              'x-www-form-urlencoded',
            )
            ..write(
              'api=SYNO.API.Auth&version=${Platform.environment['AUTH_VERSION'] ?? '7'}&method=login&account=${Platform.environment['SYNO_ACCOUNT']}'
              '&passwd=${Uri.encodeQueryComponent(Platform.environment['SYNO_PASSWORD']!)}'
              '&session=Chat&format=sid&enable_syno_token=yes',
            ))
          .close()
          .then((r) => r.transform(utf8.decoder).join());
  final d = (jsonDecode(login) as Map)['data'] as Map;
  final sid = d['sid'] as String;
  final tok = d['synotoken'] as String;
  print('sid=${sid.substring(0, 6)}… token=$tok');

  final client = Platform.environment['WS_CLIENT'] ?? 'mobile';
  final uri = Uri.parse(base).replace(
    scheme: 'wss',
    path: '/sc/socket.io/',
    queryParameters: {
      'EIO': '3',
      'transport': 'websocket',
      'client': client,
      if (client == 'browser') 'version_ui': '2.4.7',
      if (Platform.environment['TOKEN_IN_QUERY'] == 'yes') 'SynoToken': tok,
    },
  );
  print('连 $uri');
  final ws = await WebSocket.connect(
    uri.toString(),
    headers: {
      'Cookie': [
        'id=$sid',
        if (Platform.environment['SEND_TOKEN'] != 'no') 'synotoken=$tok',
      ].join('; '),
    },
    customClient: http,
  );
  print('ws 已打开');
  final frames = <String>[];
  final sub = ws.listen(
    (f) {
      final s = f is String ? f : utf8.decode(f as List<int>);
      frames.add(s);
      print('  ← ${s.length > 160 ? '${s.substring(0, 160)}…' : s}');
      if (s.startsWith('0')) ws.add('40');
    },
    onDone: () => print('  [ws 关闭]'),
    onError: (Object e) => print('  [ws 错误] $e'),
  );
  await Future<void>.delayed(const Duration(seconds: 12));
  print('共 ${frames.length} 帧');
  await sub.cancel();
  await ws.close();
  http.close(force: true);
  exit(0);
}
