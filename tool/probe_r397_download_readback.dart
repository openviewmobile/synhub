// r397 只读回读：把 NAS 上刚落盘的 `r397_bt_payload.bin` **取回宿主机**并比对
// sha256（判据 = 与宿主夹具逐字节相同）。这是"下载成功态"的**独立第二通道**：
// 一条是 App 界面像素/`dump`，一条是文件字节本身。
//
// ★ 只读：`SYNO.FileStation.List / list` + `SYNO.FileStation.Download / download`
//   （后者是 GET 取字节，不改服务端）。
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_r397_download_readback.dart
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

final HttpClient _client = HttpClient()
  ..badCertificateCallback = (_, _, _) => true;

Future<(int, String)> _form(String base, Map<String, String> f) async {
  final req = await _client.postUrl(Uri.parse('$base/webapi/entry.cgi'));
  req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
  req.write(f.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}')
      .join('&'));
  final res = await req.close();
  return (res.statusCode, await res.transform(utf8.decoder).join());
}

Future<void> main() async {
  final base = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_NAS_PASSWORD']!;

  final (_, lb) = await _form(base, {
    'api': 'SYNO.API.Auth',
    'method': 'login',
    'version': '6',
    'account': account,
    'passwd': password,
    'session': 'FileStation',
    'format': 'sid',
  });
  final sid = (jsonDecode(lb) as Map)['data']['sid'] as String;

  const path = '/home/Download/r397_bt_payload.bin';

  // ① 元数据（名字/大小/时间）
  final (ls, lb2) = await _form(base, {
    'api': 'SYNO.FileStation.List',
    'method': 'getinfo',
    'version': '2',
    '_sid': sid,
    'path': jsonEncode(const [path]),
    'additional': jsonEncode(const ['size', 'time', 'hash']),
  });
  print('=== ① FileStation.List/getinfo v2 http=$ls\n$lb2');

  // ② 取字节（Download 走 GET + _sid 查询串）
  final uri = Uri.parse('$base/webapi/entry.cgi').replace(queryParameters: {
    'api': 'SYNO.FileStation.Download',
    'method': 'download',
    'version': '2',
    '_sid': sid,
    'path': jsonEncode(const [path]),
    'mode': 'download',
  });
  final res = await (await _client.getUrl(uri)).close();
  final out = File('/tmp/r397bt/r397_bt_payload.returned.bin');
  final sink = out.openWrite();
  var n = 0;
  await for (final chunk in res) {
    sink.add(chunk);
    n += chunk.length;
  }
  await sink.close();
  print('\n=== ② FileStation.Download/download http=${res.statusCode} '
      'bytes=$n → ${out.path}');

  final payload = Platform.environment['R397_EXPECT_SHA256'];
  if (payload != null) {
    print('期望 sha256 = $payload');
  }
  _client.close(force: true);
}
