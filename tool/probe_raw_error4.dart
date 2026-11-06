// r395 第四轮探针：把 DA42 的 **600** 钉在**具体参数**上。
//
// 已知（前几轮逐字读数）：
//   * `Search:start` 传 `/` → **成功**，带 `has_not_index_share:true`（不是 600）；
//   * `Search:list` 只传 `taskid/limit/offset` → 也**成功**（不是 600）。
//   ⇒ 真机上的 600 必然来自**别的参数组合**。App 的 `searchResults()` 实际发的是
//     `taskid / offset / limit / sort_by / sort_direction / additional`（六个），
//     其中 `additional = [size,time,mount_point_type,worm_share,owner,perm]`。
//   本探针逐个"加参数"，看 600 在哪一步出现 —— 这叫**读到**，不叫推断。
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_raw_error4.dart
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
      return 'success=${j['success']} code=$c';
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
  print('目标: $base  账号: $account（口令不回显）');

  // 开一个 `/` 根的搜索任务（全局搜索页发的就是这条）
  final (_, sb) = await _raw(base,
      api: 'SYNO.FileStation.Search', method: 'start', version: 2,
      sid: sid, extra: const {'folder_path': '/', 'pattern': 'Citizen'});
  print('start(folder_path=/) → ${_code(sb)}   ${sb.length > 200 ? sb.substring(0, 200) : sb}');
  final tid = ((jsonDecode(sb) as Map)['data'] as Map)['taskid'].toString();

  const browse = '["size","time","mount_point_type","worm_share","owner","perm"]';
  final variants = <(String, Map<String, String>)>[
    ('① 只 taskid（基线）', const {'taskid': ''}),
    ('② +limit/offset', const {'limit': '200', 'offset': '0'}),
    ('③ +sort_by/sort_direction（= App 除 additional 外全量）',
        const {'limit': '200', 'offset': '0', 'sort_by': 'name', 'sort_direction': 'asc'}),
    ('④ App 全量（含 6 个 additional）', const {
      'limit': '200',
      'offset': '0',
      'sort_by': 'name',
      'sort_direction': 'asc',
      'additional': browse,
    }),
    ('⑤ 只 +additional（不含 sort）', const {'additional': browse}),
    ('⑥ additional 只留 size,time', const {'additional': '["size","time"]'}),
    ('⑦ additional 只留 worm_share（可疑项）', const {'additional': '["worm_share"]'}),
    ('⑧ additional 只留 mount_point_type', const {'additional': '["mount_point_type"]'}),
    ('⑨ +sort_by=name 单独', const {'sort_by': 'name'}),
    ('⑩ +sort_direction=asc 单独', const {'sort_direction': 'asc'}),
  ];
  for (final (label, extra) in variants) {
    final params = <String, String>{
      for (final e in extra.entries) e.key: e.key == 'taskid' ? tid : e.value,
    };
    final (h, b) = await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'list', version: 2,
        sid: sid, extra: params);
    print('── $label');
    print('   HTTP $h │ ${_code(b)}   ${b.length > 240 ? '${b.substring(0, 240)}…' : b}');
  }

  final (_, s1) = await _raw(base,
      api: 'SYNO.FileStation.Search', method: 'stop', version: 2,
      sid: sid, extra: {'taskid': tid});
  final (_, c1) = await _raw(base,
      api: 'SYNO.FileStation.Search', method: 'clean', version: 2,
      sid: sid, extra: {'taskid': tid});
  print('清理 taskid=$tid  stop=${_code(s1)}  clean=${_code(c1)}');
  print('\n完成（逐字回包，未做映射）。');
  _client.close();
}
