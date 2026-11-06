// r397 清理探针（**写动词**，只作用于本轮自建产物）：
//   `SYNO.FileStation.Delete / start` —— 把 /home/Download/r397_bt_payload.bin
//   删进回收站（与 App 的删除语义一致），跑完回读目录确认。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
final HttpClient c = HttpClient()..badCertificateCallback = (_, _, _) => true;
Future<(int, String)> raw(String base, Map<String, String> f) async {
  final r = await c.postUrl(Uri.parse('$base/webapi/entry.cgi'));
  r.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
  r.write(f.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&'));
  final res = await r.close();
  return (res.statusCode, await res.transform(utf8.decoder).join());
}
void main() async {
  final base = Platform.environment['SYNO_NAS_URL']!;
  final (_, lb) = await raw(base, {
    'api': 'SYNO.API.Auth', 'method': 'login', 'version': '6',
    'account': Platform.environment['SYNO_NAS_ACCOUNT']!,
    'passwd': Platform.environment['SYNO_NAS_PASSWORD']!,
    'session': 'FileStation', 'format': 'sid',
  });
  final sid = (jsonDecode(lb) as Map)['data']['sid'] as String;
  const p = '/home/Download/r397_bt_payload.bin';
  final (s1, b1) = await raw(base, {
    'api': 'SYNO.FileStation.Delete', 'method': 'start', 'version': '2', '_sid': sid,
    'path': jsonEncode(const [p]),
  });
  print('=== Delete/start v2 http=$s1\n$b1');
  await Future<void>.delayed(const Duration(seconds: 5));
  final (s2, b2) = await raw(base, {
    'api': 'SYNO.FileStation.List', 'method': 'list', 'version': '2', '_sid': sid,
    'folder_path': '/home/Download', 'additional': jsonEncode(const ['size']),
  });
  print('\n=== 回读 /home/Download http=$s2\n$b2');
  c.close(force: true);
}
