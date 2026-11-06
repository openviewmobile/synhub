// r395 第五轮探针：`Search:list` 的参数矩阵 —— 每个变体**开新任务**，互不污染。
//
// 上一轮读到（同一任务连续打）：
//   * 只发 `taskid`        → **600**
//   * 任何"多一个参数"的组合 → **400**
//   * 而更早一轮 `limit=20&offset=0` → **成功**
// ⇒ 说明 600/400 与**参数本身**强相关，必须**逐变体开新任务**重测（同任务连打会互相污染）。
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_raw_error5.dart
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
  final body = await res.transform(utf8.decoder).join();
  return (res.statusCode, body);
}

String _code(String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final err = j['error'];
      final c = (err is Map ? err['code'] : null);
      final d = j['data'];
      final extra = d is Map
          ? ' data.keys=${d.keys.toList()} total=${d['total']} finished=${d['finished']}'
          : '';
      return 'success=${j['success']} code=$c$extra';
    }
  } on FormatException {
    // ignore
  }
  return '非 JSON: ${body.length > 120 ? body.substring(0, 120) : body}';
}

Future<void> main() async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'];
  if (base == null || account == null || password == null) {
    stderr.writeln('缺少 SYNO_NAS_URL / SYNO_NAS_ACCOUNT / SYNO_NAS_PASSWORD');
    exit(2);
  }
  final (_, lb) = await _raw(base,
      api: 'SYNO.API.Auth', method: 'login', version: 6,
      extra: {
        'account': account,
        'passwd': password,
        'session': 'FileStation',
        'format': 'sid',
      });
  final lj = jsonDecode(lb) as Map<String, dynamic>;
  if (lj['success'] != true) {
    stderr.writeln('登录失败');
    exit(1);
  }
  final sid = (lj['data'] as Map)['sid'] as String;
  print('目标: $base  账号: $account（口令不回显）\n');

  const browse = '["size","time","mount_point_type","worm_share","owner","perm"]';

  final cases = <(String, String, Map<String, String>)>[
    ('/', '① 只 taskid', const {}),
    ('/', '② limit=20 offset=0', const {'limit': '20', 'offset': '0'}),
    ('/', '③ limit=100 offset=0', const {'limit': '100', 'offset': '0'}),
    ('/', '④ limit=200 offset=0', const {'limit': '200', 'offset': '0'}),
    ('/', '⑤ limit=0 offset=0', const {'limit': '0', 'offset': '0'}),
    ('/', '⑥ offset=0（无 limit）', const {'offset': '0'}),
    ('/', '⑦ 只 additional', const {'additional': browse}),
    ('/', '⑧ limit=200 + additional',
        const {'limit': '200', 'offset': '0', 'additional': browse}),
    ('/', '⑨ App 全量但 limit=100', const {
      'limit': '100',
      'offset': '0',
      'sort_by': 'name',
      'sort_direction': 'asc',
      'additional': browse,
    }),
    ('/home', '⑩ 对照：/home + limit=200', const {'limit': '200', 'offset': '0'}),
    ('/home', '⑪ 对照：/home + 只 taskid', const {}),
    ('/home', '⑫ 对照：/home + App 全量(limit=200)', const {
      'limit': '200',
      'offset': '0',
      'sort_by': 'name',
      'sort_direction': 'asc',
      'additional': browse,
    }),
  ];

  for (final (root, label, params) in cases) {
    final (_, sb) = await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'start', version: 2,
        sid: sid, extra: {'folder_path': root, 'pattern': 'Citizen'});
    String? tid;
    try {
      tid = ((jsonDecode(sb) as Map)['data'] as Map)['taskid'].toString();
    } on FormatException {
      tid = null;
    }
    if (tid == null) {
      print('── [$root] $label\n   start 未给 taskid：${_code(sb)}');
      continue;
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final (h, b) = await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'list', version: 2,
        sid: sid, extra: {'taskid': tid, ...params});
    print('── [$root] $label   ${params.isEmpty ? '（只有 taskid）' : jsonEncode(params)}');
    print('   HTTP $h │ ${_code(b)}');
    await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'stop', version: 2,
        sid: sid, extra: {'taskid': tid});
    await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'clean', version: 2,
        sid: sid, extra: {'taskid': tid});
  }

  print('\n完成（逐字回包，未做映射）。');
  _client.close();
}
