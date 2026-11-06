// r397 探针（**含写动词，仅作用于本机自建的探针任务 `dbid_352`**）：
// pause → resume，用来强制 BT 客户端**重新尝试 web seed**。
//
// 背景（逐字读数）：任务状态 `status=2`（Waiting）、`total_peers=0`、
// `downloaded_pieces=0`；宿主 web seed 日志确实收到 **4 次来自 NAS
// nas.example.com 的 GET**（21:09:13/15/17/19），但当时服务器对 `Range`
// 一律回 `200` 整文件 ⇒ 客户端分片对齐不了。改成 `206`（支持 Range）后
// 客户端不再重试 ⇒ 本探针 pause+resume 让它重试。
//
// ★ 写动词清单（仅此两个，目标是**本轮自建**的探针任务）：
//   `SYNO.DownloadStation2.Task / pause`、`/ resume`（v2）。
//   不删任何用户数据；清理另做（见台账 §S6）。
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_r397_ds_resume.dart
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

final HttpClient _client = HttpClient()
  ..badCertificateCallback = (_, _, _) => true;

Future<(int, String)> _raw(
  String base, {
  required String api,
  required String method,
  required int version,
  String? sid,
  Map<String, String> extra = const {},
}) async {
  final form = <String, String>{
    'api': api,
    'method': method,
    'version': '$version',
    '_sid': ?sid,
    ...extra,
  };
  final req = await _client.postUrl(Uri.parse('$base/webapi/entry.cgi'));
  req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
  req.write(form.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}')
      .join('&'));
  final res = await req.close();
  return (res.statusCode, await res.transform(utf8.decoder).join());
}

const String kTaskId = 'dbid_352';

Future<void> main() async {
  final base = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_NAS_PASSWORD']!;

  final (ls, lb) = await _raw(base,
      api: 'SYNO.API.Auth',
      method: 'login',
      version: 6,
      extra: {
        'account': account,
        'passwd': password,
        'session': 'FileStation',
        'format': 'sid',
      });
  final sid = (jsonDecode(lb) as Map)['data']['sid'] as String;
  print('登录 http=$ls（sid 取到）');

  for (final m in const ['pause', 'resume']) {
    final (s, b) = await _raw(base,
        api: 'SYNO.DownloadStation2.Task',
        method: m,
        version: 2,
        sid: sid,
        extra: {'id': jsonEncode(const [kTaskId])});
    print('\n=== Task/$m v2 http=$s\n$b');
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  _client.close(force: true);
}
