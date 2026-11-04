// 宿主侧**原始报文**探针（r395 第二轮）：DA23 / DA25 / DA42 三个留白项各取一次
// **服务端逐字回包**，不经过任何映射层（`DsmApiException` 的折算会丢信息）。
//
// 与 `probe_raw_error.dart` 的分工：第一轮已经读到
//   * DA23 `/teamdrivetest/#recycle` → **407**（v1/v2 一致、连打 3 次一致）
//   * DA25 `Storage.USB/list` v1    → **404**（假方法同 API → 103；兄弟 EUnit → 105）
// 本轮补的是**对照**（判语义只能靠对照，不能靠猜）：
//
//   ① DA23  ← 共享文件夹的 `#recycle`  vs  自己 home 的 `#recycle` vs 不存在的路径
//   ② DA25  ← 盘位共享是否存在（`list_share`）+ 该 API 是否允许普通用户
//   ③ DA42  ← `Search:start` 用 `/`（复现真机 600）vs `/home`（应成功）
//
// 用法（口令只从环境变量来，绝不落库、绝不回显）：
//   set -a; . ~/.synhub-nas.env; set +a
//   dart run tool/probe_raw_error2.dart
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

String _sum(String body) {
  final b = body.replaceAll(RegExp(r'"_sid"\s*:\s*"[^"]*"'), '"_sid":"<masked>"');
  try {
    final j = jsonDecode(b);
    if (j is Map) {
      final err = j['error'];
      final code = (err is Map ? err['code'] : null);
      final head = b.length > 300 ? '${b.substring(0, 300)}…' : b;
      return 'success=${j['success']}  error.code=$code   │ $head';
    }
  } on FormatException {
    // 非 JSON 原文照打
  }
  return '（非 JSON）${b.length > 300 ? b.substring(0, 300) : b}';
}

Future<void> _show(
  String base,
  String label, {
  required String api,
  required String method,
  required int version,
  String? sid,
  Map<String, String> extra = const {},
}) async {
  final (http, body) = await _raw(
    base,
    api: api,
    method: method,
    version: version,
    sid: sid,
    extra: extra,
  );
  print('── $label');
  print('   $api/$method v$version  ${extra.isEmpty ? '（无参）' : jsonEncode(extra)}');
  print('   HTTP $http │ ${_sum(body)}');
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

  final (loginHttp, loginBody) = await _raw(
    base,
    api: 'SYNO.API.Auth',
    method: 'login',
    version: 6,
    extra: {
      'account': account,
      'passwd': password,
      'session': 'FileStation',
      'format': 'sid',
    },
  );
  print('登录: HTTP $loginHttp │ ${_sum(loginBody)}');
  final loginJson = jsonDecode(loginBody) as Map<String, dynamic>;
  if (loginJson['success'] != true) {
    stderr.writeln('登录失败，后续不跑');
    exit(1);
  }
  final sid = (loginJson['data'] as Map)['sid'] as String;

  // ── ① DA23 对照三连 ──────────────────────────────────────────────────
  print('\n=== ① DA23：`#recycle` 权限语义对照 ===');
  await _show(base, 'A 共享文件夹本体（应成功）',
      api: 'SYNO.FileStation.List', method: 'list', version: 2,
      sid: sid, extra: const {'folder_path': '/teamdrivetest'});
  await _show(base, 'B 共享文件夹的 #recycle（真机报错那条）',
      api: 'SYNO.FileStation.List', method: 'list', version: 2,
      sid: sid, extra: const {'folder_path': '/teamdrivetest/#recycle'});
  await _show(base, 'C 自己 home 的 #recycle（若成功 ⇒ 差异在"谁的回收站"）',
      api: 'SYNO.FileStation.List', method: 'list', version: 2,
      sid: sid, extra: const {'folder_path': '/homes/demo_user/#recycle'});
  await _show(base, 'C2 home 别名 /home 的 #recycle',
      api: 'SYNO.FileStation.List', method: 'list', version: 2,
      sid: sid, extra: const {'folder_path': '/home/#recycle'});
  await _show(base, 'C3 自己 home 本体（应成功）',
      api: 'SYNO.FileStation.List', method: 'list', version: 2,
      sid: sid, extra: const {'folder_path': '/homes/demo_user'});
  await _show(base, 'D 不存在的路径（对照：不存在 与 无权限 是两个码吗）',
      api: 'SYNO.FileStation.List', method: 'list', version: 2,
      sid: sid, extra: const {'folder_path': '/teamdrivetest/__nope__'});
  await _show(base, 'E 另一个共享文件夹的 #recycle',
      api: 'SYNO.FileStation.List', method: 'list', version: 2,
      sid: sid, extra: const {'folder_path': '/docker/#recycle'});

  // ── ② DA25：盘位共享 & API 契约 ─────────────────────────────────────
  print('\n=== ② DA25：外接设备 ===');
  final (_, shareBody) = await _raw(
    base,
    api: 'SYNO.FileStation.List',
    method: 'list_share',
    version: 2,
    sid: sid,
    extra: const {'additional': '["real_path","mount_point_type"]'},
  );
  var usbShares = <String>[];
  try {
    final j = jsonDecode(shareBody) as Map<String, dynamic>;
    final shares = ((j['data'] as Map)['shares'] as List).cast<Map>();
    print('── 本机共享文件夹清单（${shares.length} 条）');
    for (final s in shares) {
      final name = s['name'];
      final add = s['additional'];
      final mpt = (add is Map ? add['mount_point_type'] : null);
      print('   name=$name  path=${s['path']}  mount_point_type=$mpt');
      if ('$name'.toLowerCase().contains('usb') ||
          '$name'.toLowerCase().contains('sata') ||
          '$mpt' != null) {
        usbShares.add('$name');
      }
    }
  } on FormatException {
    print('── list_share 非 JSON：${_sum(shareBody)}');
  }
  print('   ⇒ 含 usb/sata/挂载类型的共享：${usbShares.isEmpty ? "（无）" : usbShares.join(", ")}');

  await _show(base, 'USB/list v1（App 的报文形态）',
      api: 'SYNO.Core.ExternalDevice.Storage.USB', method: 'list', version: 1,
      sid: sid, extra: const {'additional': '["partitions"]'});
  await _show(base, 'USB/list v1（官方前端形态：4 个 additional）',
      api: 'SYNO.Core.ExternalDevice.Storage.USB', method: 'list', version: 1,
      sid: sid,
      extra: const {
        'additional': '["dev_type","product","status","partitions"]',
      });
  await _show(base, 'USB/list v2（版本协商对照）',
      api: 'SYNO.Core.ExternalDevice.Storage.USB', method: 'list', version: 2,
      sid: sid, extra: const {'additional': '["partitions"]'});

  final (_, infoBody) = await _raw(
    base,
    api: 'SYNO.API.Info',
    method: 'query',
    version: 1,
    extra: const {'query': 'all'},
  );
  final info = jsonDecode(infoBody) as Map<String, dynamic>;
  final data = (info['data'] as Map).cast<String, dynamic>();
  print('\n── SYNO.API.Info 里 ExternalDevice 存储 API 的逐字声明');
  for (final k in data.keys.where((k) => k.contains('ExternalDevice'))) {
    print('   $k → ${jsonEncode(data[k])}');
  }

  // ── ③ DA42：`Search:start` 的 600 ──────────────────────────────────
  print('\n=== ③ DA42：FileStation 搜索的错误码 600 ===');
  final tasks = <String>[];
  for (final (label, root) in const [
    ('A folder_path="/"（复现真机 600 的那条）', '/'),
    ('B folder_path=""（空串对照）', ''),
    ('C folder_path="/home"（App 里已回落的那条）', '/home'),
  ]) {
    final (h, b) = await _raw(
      base,
      api: 'SYNO.FileStation.Search',
      method: 'start',
      version: 2,
      sid: sid,
      extra: {'folder_path': root, 'pattern': 'Citizen'},
    );
    print('── $label');
    print('   HTTP $h │ ${_sum(b)}');
    try {
      final j = jsonDecode(b) as Map<String, dynamic>;
      final tid = (j['data'] as Map?)?['taskid'];
      if (tid != null) tasks.add('$tid');
    } on FormatException {
      // ignore
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  // 只读回收：把自己建过的搜索任务停掉并清掉（不留服务端垃圾）
  for (final t in tasks) {
    final (h1, b1) = await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'stop', version: 2,
        sid: sid, extra: {'taskid': t});
    final (h2, b2) = await _raw(base,
        api: 'SYNO.FileStation.Search', method: 'clean', version: 2,
        sid: sid, extra: {'taskid': t});
    print('── 清理 taskid=$t  stop HTTP $h1 ${_sum(b1)}');
    print('                   clean HTTP $h2 ${_sum(b2)}');
  }

  print('\n完成。以上正文都是**服务端逐字回包**，未做任何映射。');
  _client.close();
}
