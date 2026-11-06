// r406 只读探针：BT 搜索的**数据源表**与**单源结果**。
//
// 判据（仪器㉓：先钉住"现在连的是谁"）：所有调用都是**只读**的
//   * `SYNO.DownloadStation.BTSearch / getModule` v1 —— 数据源（enabled）清单；
//   * `SYNO.DownloadStation.BTSearch / start` + `/ list` —— 开一次检索会话并翻页。
//   （`start` 会在服务端起一个搜索会话，属**只读语义**：不改任何任务/文件；
//     App 自己也这么用；会话由服务端自行回收。）
//
// 用法：
//   set -a; . ~/.synhub-nas.env; set +a
//   export SYNO_ACCOUNT=$SYNO_NAS_ACCOUNT SYNO_PASSWORD=$SYNO_NAS_PASSWORD
//   dart run tool/probe_r406_bt_sources.dart modules
//   dart run tool/probe_r406_bt_sources.dart search ubuntu [每源只打前 N 条]
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

final HttpClient _client = HttpClient()
  ..badCertificateCallback = (_, _, _) => true;

late String _base;
String _sid = '';

/// api → path（**必须**由能力表给；写死 entry.cgi 会被拒 —— r406 亲测）
final Map<String, String> _paths = {};

Future<void> _resolvePaths(List<String> apis) async {
  final req = await _client.postUrl(Uri.parse('$_base/webapi/query.cgi'));
  req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
  req.write({
    'api': 'SYNO.API.Info',
    'version': '1',
    'method': 'query',
    'query': apis.join(','),
  }.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&'));
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  final d = (jsonDecode(body) as Map)['data'];
  if (d is Map) {
    for (final e in d.entries) {
      final v = e.value;
      if (v is Map && v['path'] is String) {
        _paths['${e.key}'] = v['path'] as String;
      }
    }
  }
  print('能力表 path = $_paths');
}

Future<Map<String, dynamic>> _call(
  String api,
  String method,
  Map<String, String> params,
) async {
  final path = _paths[api] ?? 'entry.cgi';
  final req = await _client.postUrl(Uri.parse('$_base/webapi/$path'));
  req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
  req.write({
    'api': api,
    'version': '1',
    'method': method,
    if (_sid.isNotEmpty) '_sid': _sid,
    ...params,
  }.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&'));
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  return jsonDecode(body) as Map<String, dynamic>;
}

Future<void> main(List<String> args) async {
  _base = Platform.environment['SYNO_NAS_URL']!;
  final account =
      Platform.environment['SYNO_ACCOUNT'] ?? Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password =
      Platform.environment['SYNO_PASSWORD'] ?? Platform.environment['SYNO_NAS_PASSWORD']!;

  final login = await _call('SYNO.API.Auth', 'login', {
    'account': account,
    'passwd': password,
    'session': 'DownloadStation',
    'format': 'sid',
    'version': '6',
  });
  if (login['success'] != true) {
    print('login 失败：$login');
    exit(1);
  }
  _sid = (login['data'] as Map)['sid'] as String;
  print('login ok（account=${account.substring(0, 1)}***）');
  await _resolvePaths(const [
    'SYNO.DownloadStation.BTSearch',
    'SYNO.DownloadStation2.BTSearch',
  ]);

  final mode = args.isEmpty ? 'modules' : args[0];
  const api = 'SYNO.DownloadStation.BTSearch';

  if (mode == 'modules') {
    final r = await _call(api, 'getModule', const {});
    final mods = ((r['data'] as Map?)?['modules'] as List?) ?? const [];
    print('getModule → success=${r['success']} 模块数=${mods.length}');
    for (final m in mods) {
      final mm = m as Map;
      print('  id=${mm['module_id'] ?? mm['id']}\t'
          'title=${mm['module_title'] ?? mm['title'] ?? mm['displayname']}\t'
          'enabled=${mm['enabled']}');
    }
    return;
  }

  // search <keyword>
  final kw = args.length > 1 ? args[1] : 'ubuntu';
  final start = await _call(api, 'start', {'keyword': kw});
  print('start({keyword:$kw}) → ${jsonEncode(start)}');
  if (start['success'] != true) return;
  final taskid = ((start['data'] as Map)['taskid'] ?? (start['data'] as Map)['id'])
      .toString();
  print('taskid=$taskid');

  // 轮询直到 finished（服务端语义与 App 相同：finished 表示抓完）
  var total = 0;
  var items = <Map<String, dynamic>>[];
  for (var i = 0; i < 40; i++) {
    final r = await _call(api, 'list', {
      'taskid': taskid,
      'offset': '0',
      'limit': '100',
    });
    if (r['success'] != true) {
      print('list 失败：${jsonEncode(r)}');
      break;
    }
    final d = r['data'] as Map;
    total = (d['total'] as num?)?.toInt() ?? 0;
    items = [
      for (final e in (d['items'] as List? ?? const []))
        Map<String, dynamic>.from(e as Map),
    ];
    print('  第 ${i + 1} 次 list：finished=${d['finished']} '
        'items=${items.length} total=$total');
    if (d['finished'] == true) break;
    await Future<void>.delayed(const Duration(seconds: 5));
  }

  final byModule = <String, int>{};
  final byTitle = <String, int>{};
  for (final e in items) {
    byModule['${e['module_id']}'] = (byModule['${e['module_id']}'] ?? 0) + 1;
    byTitle['${e['module_title']}'] = (byTitle['${e['module_title']}'] ?? 0) + 1;
  }
  print('抓完：items=${items.length} total=$total');
  print('按 module_id 统计 = $byModule');
  print('按 module_title 统计 = $byTitle');
  print('首条逐字 = ${jsonEncode(items.isEmpty ? {} : items.first)}');
}
