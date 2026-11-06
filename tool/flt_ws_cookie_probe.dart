// ignore_for_file: avoid_print
// 用登录下发的 Set-Cookie（id + did + …）原样喂给 socket，看 119 是否消失。
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final base = Platform.environment['SYNO_NAS_URL']!;
  final http = HttpClient()..badCertificateCallback = (_, _, _) => true;
  final req = await http.postUrl(Uri.parse('$base/webapi/entry.cgi'));
  req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
  req.write(
    'api=SYNO.API.Auth&version=7&method=login'
    '&account=${Platform.environment['SYNO_ACCOUNT']}'
    '&passwd=${Uri.encodeQueryComponent(Platform.environment['SYNO_PASSWORD']!)}'
    '&session=Chat&format=cookie&enable_syno_token=yes',
  );
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  final cookies = (resp.headers['set-cookie'] ?? const <String>[])
      .map((c) => c.split(';').first)
      .toList();
  print(
    'format=cookie 登录响应: ${body.length > 160 ? body.substring(0, 160) : body}',
  );
  print('Set-Cookie: $cookies');

  String? cookieHeader;
  if (cookies.isNotEmpty) {
    cookieHeader = cookies.join('; ');
  } else {
    final d = (jsonDecode(body) as Map)['data'] as Map;
    cookieHeader = 'id=${d['sid']}';
  }
  print('socket 用 Cookie: $cookieHeader');

  final uri = Uri.parse(base).replace(
    scheme: 'wss',
    path: '/sc/socket.io/',
    queryParameters: {'EIO': '3', 'transport': 'websocket', 'client': 'mobile'},
  );
  final ws = await WebSocket.connect(
    uri.toString(),
    headers: {'Cookie': cookieHeader},
    customClient: http,
  );
  final frames = <String>[];
  final sub = ws.listen((f) {
    final s = f is String ? f : utf8.decode(f as List<int>);
    frames.add(s);
    print('  ← ${s.length > 120 ? '${s.substring(0, 120)}…' : s}');
    if (s.startsWith('0')) ws.add('40');
  }, onDone: () => print('  [ws 关闭]'));
  await Future<void>.delayed(const Duration(seconds: 8));
  print('共 ${frames.length} 帧');
  await sub.cancel();
  await ws.close();
  http.close(force: true);
  exit(0);
}
