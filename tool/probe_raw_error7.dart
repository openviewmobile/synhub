// r395 第七轮探针：**瞬时性**判定 —— 600 是"一次性太早"还是"永久失败"？
//
// 前几轮的疑点：同一根 `/`、同一份参数，有的变体回 600、有的回成功；
// 官方文案 600 = `search/no_search_cache`「暂时无法访问搜索结果。请再试一次。」——
// **字面就是"暂时"**。所以本探针：开一个任务后**连续轮询**，把每个时间点的 code 都记下来。
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_raw_error7.dart
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
      // ★ r395 修（本探针上一版在这里崩过：`int` 被当成 `bool` 用 ⇒ `type 'int'
      //   is not a subtype of type 'bool'`，exit=255、`/home` 那半段没读到）。
      //   三元写清楚，不靠运算符优先级。
      final String n;
      if (d is Map) {
        final files = d['files'];
        n = files is List ? 'files=${files.length}' : 'total=${d['total']}';
      } else {
        n = '';
      }
      return 'success=${j['success']} code=$c $n';
    }
  } on FormatException {
    // ignore
  }
  return '非 JSON';
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
  final appParams = {
    'offset': '0',
    'limit': '200',
    'sort_by': 'name',
    'sort_direction': 'asc',
    'additional': browse,
  };

  for (final root in const ['/', '/home']) {
    final (_, sb) = await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'start', version: 2,
        sid: sid, extra: {'folder_path': root, 'pattern': 'Citizen'});
    final tid = ((jsonDecode(sb) as Map)['data'] as Map)['taskid'].toString();
    print('── 根 = $root  taskid=$tid');
    print('   start: ${_code(sb)}   ${sb.length > 200 ? sb.substring(0, 200) : sb}');
    final sw = Stopwatch()..start();
    for (var i = 0; i < 12; i++) {
      final (h, b) = await _raw(base,
          api: 'SYNO.FileStation.Search', method: 'list', version: 2,
          sid: sid, extra: {'taskid': tid, ...appParams});
      print('   第 ${i + 1} 次轮询 @${sw.elapsedMilliseconds}ms  HTTP $h │ ${_code(b)}');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'stop', version: 2,
        sid: sid, extra: {'taskid': tid});
    await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'clean', version: 2,
        sid: sid, extra: {'taskid': tid});
    print('   已 stop+clean');
  }

  print('\n完成（逐字回包，未做映射）。');
  _client.close();
}
