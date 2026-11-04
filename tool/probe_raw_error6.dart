// r395 第六轮探针：全局搜索页的**另外两个来源**（笔记 / 照片）的逐字回包。
//
// 为什么还要打这个：`Search:list` 那条链路已经证到"根 `/` + limit=200 是**成功**的"，
// 所以真机上那个 600 **未必**出在文件这一组 —— 页面里 `_onError` 是**共用**的
// （文件组和笔记组都会调它），必须把另外两组也读到，才能钉住 600 的出处。
//
// 参数逐字照抄 App 代码：
//   * 笔记：`SYNO.NoteStation.FTS/search` v1
//           `{keyword, offset:0, limit:50}`            （note_api.dart:761）
//   * 照片：`SYNO.Foto.Search.Search/list_item` v7
//           `{offset,limit,additional:[7 项],keyword}`  （foto_c2_api.dart:567）
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_raw_error6.dart
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

final HttpClient _client = HttpClient()
  ..badCertificateCallback = (_, __, ___) => true;

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
    if (sid != null) '_sid': sid,
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

String _sum(String body, {int cap = 320}) {
  final b = body.replaceAll(RegExp(r'"_sid"\s*:\s*"[^"]*"'), '"_sid":"<masked>"');
  try {
    final j = jsonDecode(b);
    if (j is Map) {
      final err = j['error'];
      final c = (err is Map ? err['code'] : null);
      final head = b.length > cap ? '${b.substring(0, cap)}…' : b;
      return 'success=${j['success']} code=$c   │ $head';
    }
  } on FormatException {
    // ignore
  }
  return '（非 JSON）${b.length > cap ? b.substring(0, cap) : b}';
}

Future<String?> _login(String base, String account, String password,
    String session) async {
  final (_, b) = await _raw(base,
      api: 'SYNO.API.Auth', method: 'login', version: 6,
      extra: {
        'account': account,
        'passwd': password,
        'session': session,
        'format': 'sid',
      });
  final j = jsonDecode(b) as Map<String, dynamic>;
  if (j['success'] != true) {
    print('   登录 session=$session → ${_sum(b)}');
    return null;
  }
  print('   登录 session=$session → success（sid 不回显）');
  return (j['data'] as Map)['sid'] as String;
}

Future<void> main() async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'];
  if (base == null || account == null || password == null) {
    stderr.writeln('缺少 SYNO_NAS_URL / SYNO_NAS_ACCOUNT / SYNO_NAS_PASSWORD');
    exit(2);
  }
  print('目标: $base  账号: $account（口令不回显）\n');

  final fs = await _login(base, account, password, 'FileStation');
  final note = await _login(base, account, password, 'NoteStation');
  final photo = await _login(base, account, password, 'SynologyPhotos');

  const keyword = 'Citizen';
  final tries = <(String, String?, String, String, int, Map<String, String>)>[
    ('笔记（FileStation 会话）', fs, 'SYNO.NoteStation.FTS', 'search', 1,
        {'keyword': keyword, 'offset': '0', 'limit': '50'}),
    ('笔记（NoteStation 会话）', note, 'SYNO.NoteStation.FTS', 'search', 1,
        {'keyword': keyword, 'offset': '0', 'limit': '50'}),
    ('照片（FileStation 会话）', fs, 'SYNO.Foto.Search.Search', 'list_item', 7,
        {
          'offset': '0',
          'limit': '30',
          'additional':
              '["thumbnail","resolution","orientation","video_convert","video_meta","address","favorite"]',
          'keyword': keyword,
        }),
    ('照片（SynologyPhotos 会话）', photo, 'SYNO.Foto.Search.Search', 'list_item',
        7, {
      'offset': '0',
      'limit': '30',
      'additional':
          '["thumbnail","resolution","orientation","video_convert","video_meta","address","favorite"]',
      'keyword': keyword,
    }),
  ];

  for (final (label, sid, api, method, ver, params) in tries) {
    if (sid == null) {
      print('── $label：无会话，跳过');
      continue;
    }
    final (h, b) = await _raw(base,
        api: api, method: method, version: ver, sid: sid, extra: params);
    print('── $label');
    print('   $api/$method v$ver');
    print('   HTTP $h │ ${_sum(b)}');
  }

  print('\n完成（逐字回包，未做映射）。');
  _client.close();
}
