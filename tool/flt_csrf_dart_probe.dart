// ignore_for_file: avoid_print
// 用纯 dart:io 复现"带 CSRF 令牌的压缩"，隔离 Dio/传输层的嫌疑。
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final base = Platform.environment['SYNO_NAS_URL']!;
  final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;

  Future<String> post(
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
    return await resp.transform(utf8.decoder).join();
  }

  final login = await post('$base/webapi/entry.cgi', {
    'api': 'SYNO.API.Auth',
    'version': '7',
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
  print('登录 OK sid=${sid.substring(0, 6)}… token=$tok');

  Future<void> compress(
    String label,
    String dest, {
    Map<String, String>? headers,
    bool tokenInQuery = false,
  }) async {
    final q = tokenInQuery ? '?SynoToken=${Uri.encodeQueryComponent(tok)}' : '';
    final r = await post('$base/webapi/entry.cgi$q', {
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
    }, headers: headers);
    print('$label → ${r.length > 120 ? r.substring(0, 120) : r}');
  }

  await compress('① 无令牌（对照）', '/home/dart-none.zip');
  await compress(
    '② 令牌放 header',
    '/home/dart-header.zip',
    headers: {'X-SYNO-TOKEN': tok},
  );
  await compress('③ 令牌放 query', '/home/dart-query.zip', tokenInQuery: true);

  // 清理
  for (final f in const [
    'dart-none.zip',
    'dart-header.zip',
    'dart-query.zip',
  ]) {
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
