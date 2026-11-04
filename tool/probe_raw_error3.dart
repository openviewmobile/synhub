// r395 第三轮探针：两个**决定性对照**
//
// ① DA25 的 404 到底是"没插盘"还是别的？
//    第二轮读到 `list_share` 里有 **usbshare1**（共享存在），而 `USB/list` v1 回 404。
//    本探针读 `/usbshare1` 的 **real_path / mount 信息 / 内容**：
//      * real_path 指向 `/volumeUSB*` ⇒ 真的插着 USB 盘 ⇒ 404 **不是**"没设备"；
//      * real_path 指向 `/volume1/usbshare1` ⇒ 那只是个普通共享名 ⇒ 404 与"没插盘"不矛盾。
//
// ② DA42 的 600 出在哪一步？
//    第二轮 `Search:start` 传 `/` 时**成功**返回，但带 `has_not_index_share:true`；
//    官方前端把 600 映射成 `search/no_search_cache`（"暂时无法访问搜索结果"）
//    ⇒ 600 更像出在**取结果**（`Search:list`）那一步。
//    本探针对**同一个任务**分别读 `start` 与 `list`，把 600 钉在具体方法上。
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_raw_error3.dart
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
  req.headers.contentType = ContentType(
    'application',
    'x-www-form-urlencoded',
  );
  req.write(form.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}')
      .join('&'));
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  return (res.statusCode, body);
}

String _sum(String body, {int cap = 420}) {
  final b = body.replaceAll(RegExp(r'"_sid"\s*:\s*"[^"]*"'), '"_sid":"<masked>"');
  try {
    final j = jsonDecode(b);
    if (j is Map) {
      final err = j['error'];
      final code = (err is Map ? err['code'] : null);
      final head = b.length > cap ? '${b.substring(0, cap)}…' : b;
      return 'success=${j['success']}  error.code=$code   │ $head';
    }
  } on FormatException {
    // 原文照打
  }
  return '（非 JSON）${b.length > cap ? b.substring(0, cap) : b}';
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

  final (_, loginBody) = await _raw(base,
      api: 'SYNO.API.Auth', method: 'login', version: 6,
      extra: {
        'account': account,
        'passwd': password,
        'session': 'FileStation',
        'format': 'sid',
      });
  final loginJson = jsonDecode(loginBody) as Map<String, dynamic>;
  if (loginJson['success'] != true) {
    stderr.writeln('登录失败: ${_sum(loginBody)}');
    exit(1);
  }
  final sid = (loginJson['data'] as Map)['sid'] as String;
  print('登录: success=true（sid 不回显）');

  // ── ① DA25：usbshare1 是不是一个真的 USB 挂载 ───────────────────────
  print('\n=== ① DA25：`/usbshare1` 到底是什么 ===');
  final (_, sharesBody) = await _raw(base,
      api: 'SYNO.FileStation.List', method: 'list_share', version: 2,
      sid: sid,
      extra: const {
        'additional': '["real_path","mount_point_type","volume_status","time"]',
      });
  try {
    final j = jsonDecode(sharesBody) as Map<String, dynamic>;
    for (final s in ((j['data'] as Map)['shares'] as List).cast<Map>()) {
      print('── share name=${s['name']}  path=${s['path']}');
      print('   additional=${jsonEncode(s['additional'])}');
    }
  } on FormatException {
    print('── list_share 非 JSON：${_sum(sharesBody)}');
  }
  for (final p in const ['/usbshare1', '/']) {
    final (h, b) = await _raw(base,
        api: 'SYNO.FileStation.List', method: 'list', version: 2,
        sid: sid,
        extra: {'folder_path': p, 'additional': '["real_path","type","size"]'});
    print('── list $p');
    print('   HTTP $h │ ${_sum(b, cap: 700)}');
  }

  // ── ② DA42：600 出在 start 还是 list ───────────────────────────────
  print('\n=== ② DA42：同一个搜索任务，`start` 与 `list` 分开读 ===');
  for (final (label, root) in const [
    ('A 根 `/`（全局搜索页现在发的就是这条）', '/'),
    ('B `/home`（Files 搜索页已回落的那条）', '/home'),
  ]) {
    final (h, b) = await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'start', version: 2,
        sid: sid,
        extra: {'folder_path': root, 'pattern': 'Citizen'});
    print('── $label');
    print('   start HTTP $h │ ${_sum(b)}');
    String? tid;
    try {
      final j = jsonDecode(b);
      if (j is Map && j['data'] is Map) {
        final t = (j['data'] as Map)['taskid'];
        tid = t?.toString();
      }
    } on FormatException {
      tid = null;
    }
    if (tid == null) {
      print('   ⇒ start 没给 taskid，跳过 list');
      continue;
    }
    // 立刻读一次 + 1.5 s 后再读一次（判 600 是"索引没建好"的瞬时态还是稳定态）
    for (final (tag, delay) in const [
      ('立刻', Duration.zero),
      ('等 1.5 s', Duration(milliseconds: 1500)),
    ]) {
      await Future<void>.delayed(delay);
      final (h2, b2) = await _raw(base,
          api: 'SYNO.FileStation.Search', method: 'list', version: 2,
          sid: sid,
          extra: {'taskid': tid, 'limit': '20', 'offset': '0'});
      print('   list（$tag）HTTP $h2 │ ${_sum(b2, cap: 600)}');
    }
    final (_, s1) = await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'stop', version: 2,
        sid: sid, extra: {'taskid': tid});
    final (_, c1) = await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'clean', version: 2,
        sid: sid, extra: {'taskid': tid});
    print('   清理 taskid=$tid  stop=${_sum(s1, cap: 120)}  clean=${_sum(c1, cap: 120)}');
  }

  print('\n完成（逐字回包，未做映射）。');
  _client.close();
}
