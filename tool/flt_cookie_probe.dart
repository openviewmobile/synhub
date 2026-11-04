// ignore_for_file: avoid_print
// 验证：带上登录下发的 cookie（尤其是 id=…）会不会让 CSRF 校验失败。
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final base = Platform.environment['SYNO_NAS_URL']!;
  final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;

  Future<(String, List<String>)> post(
    String url,
    Map<String, String> body, {
    Map<String, String>? headers,
  }) async {
    final req = await client.postUrl(Uri.parse(url));
    headers?.forEach(req.headers.set);
    req.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
    );
    req.write(
      body.entries
          .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'),
    );
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    return (text, resp.headers['set-cookie'] ?? const <String>[]);
  }

  final (login, cookies) = await post('$base/webapi/entry.cgi', {
    'api': 'SYNO.API.Auth',
    'version': Platform.environment['AUTH_VERSION'] ?? '7',
    'method': 'login',
    'account': Platform.environment['SYNO_ACCOUNT']!,
    'passwd': Platform.environment['SYNO_PASSWORD']!,
    'session': 'FileStation',
    'format': 'sid',
    'enable_syno_token': 'yes',
  });
  final data = (jsonDecode(login) as Map)['data'] as Map;
  final sid = data['sid'] as String;
  final tok = data['synotoken'] as String;
  print(
    '登录 OK，服务端下发 cookie: ${cookies.map((c) => c.split(';').first).toList()}',
  );

  Future<void> compress(
    String label,
    String dest, {
    bool withCookie = false,
  }) async {
    final r = await post(
      '$base/webapi/entry.cgi',
      {
        'api': 'SYNO.FileStation.Compress',
        'method': 'start',
        'version': '3',
        'path': '["/home/Photos"]',
        'dest_file_path': dest,
        'level': 'normal',
        'mode': 'replace',
        'format': 'zip',
        'password': '',
        'codepage': '',
        '_sid': sid,
      },
      headers: {
        'X-SYNO-TOKEN': tok,
        if (withCookie)
          'Cookie': cookies.map((c) => c.split(';').first).join('; '),
      },
    );
    print('$label → $r');
  }

  await compress('① 带头、不带 cookie', '/home/ck-a.zip');
  await compress('② 带头、带登录 cookie', '/home/ck-b.zip', withCookie: true);
  // ③ 令牌只放 query（对照 curl 的成功用例）
  final r3 = await post(
    '$base/webapi/entry.cgi?SynoToken=${Uri.encodeQueryComponent(tok)}',
    {
      'api': 'SYNO.FileStation.Compress',
      'method': 'start',
      'version': '3',
      'path': '["/home/Photos"]',
      'dest_file_path': '/home/ck-c.zip',
      'level': 'normal',
      'mode': 'replace',
      'format': 'zip',
      '_sid': sid,
    },
  );
  print('③ 令牌放 query → $r3');

  for (final f in const ['ck-a.zip', 'ck-b.zip', 'ck-c.zip']) {
    await post('$base/webapi/entry.cgi', {
      'api': 'SYNO.FileStation.Delete',
      'method': 'delete',
      'version': '2',
      'path': '["/home/$f"]',
      '_sid': sid,
    });
  }
  print('清理完成');
  client.close(force: true);
  exit(0);
}
