// 宿主侧**原始报文**探针：直接打 `/webapi/entry.cgi`，打印服务端**逐字回包**
// （HTTP 状态 + 完整 JSON，尤其是 `error.code`）。
//
// ★ 为什么不用仓里的 `DsmWebApi`：它会把错误**折算**成自己的枚举
//   （DA23 的 `407` 就是被折算成"请求过于频繁"的）。本探针要的正是**折算之前**的原文，
//   所以自己拼 `api/method/version/_sid`，不经过任何映射层。
//
// 用法（口令只从环境变量来，绝不落库；也不会被打印）：
//   set -a; . ~/.synhub-nas.env; set +a
//   dart run tool/probe_raw_error.dart
//
// 目标（对应用户要求的"从 NAS 侧捞一次原始 error.code"）：
//   ① DA23：`SYNO.FileStation.List/list` 打 `/teamdrivetest`（对照）与
//           `/teamdrivetest/#recycle`（真机报错的那条），并顺带清点
//           `SYNO.API.Info` 里所有 Recycle 相关 API。
//   ② DA25：`SYNO.Core.ExternalDevice.Storage.USB/list` v1（含与不含 `additional`），
//           外加兄弟 `Storage.EUnit/list` 作对照。
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

final HttpClient _client = HttpClient()
  ..badCertificateCallback = (_, _, _) => true;

/// 打一发原始请求，返回 (httpStatus, 原始正文)。
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

/// 只显示 `error.code` 与 `success`，外加正文前 400 字（sid 一律打码）。
String _summarize(String body) {
  var b = body.replaceAll(RegExp(r'"_sid"\s*:\s*"[^"]*"'), '"_sid":"<masked>"');
  try {
    final j = jsonDecode(b);
    if (j is Map) {
      final err = j['error'];
      final code = (err is Map ? err['code'] : null);
      final head = b.length > 400 ? '${b.substring(0, 400)}…' : b;
      return 'success=${j['success']}  error.code=$code\n     正文: $head';
    }
  } on FormatException {
    // 非 JSON（例如 HTML 登录墙 / 502）—— 原文照打。
  }
  final head = b.length > 400 ? '${b.substring(0, 400)}…' : b;
  return '（非 JSON）正文: $head';
}

Future<void> _show(
  String base,
  String label,
  Map<String, String> Function() mk, {
  String? sid,
  required String api,
  required String method,
  required int version,
}) async {
  final (http, body) = await _raw(
    base,
    api: api,
    method: method,
    version: version,
    sid: sid,
    extra: mk(),
  );
  print('── $label');
  print('   api=$api method=$method version=$version');
  print('   HTTP $http │ ${_summarize(body)}');
}

Future<void> main() async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'];
  if (base == null || account == null || password == null) {
    stderr.writeln(
      '缺少 SYNO_NAS_URL / SYNO_NAS_ACCOUNT / SYNO_NAS_PASSWORD（请先 source ~/.synhub-nas.env）',
    );
    exit(2);
  }
  print('目标: $base  账号: $account（口令不回显）\n');

  // 登录（FileStation 会话）
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
  print('登录: HTTP $loginHttp │ ${_summarize(loginBody)}');
  final loginJson = jsonDecode(loginBody) as Map<String, dynamic>;
  if (loginJson['success'] != true) {
    stderr.writeln('登录失败，后续不跑（这就是原始回包，别再猜）');
    exit(1);
  }
  final sid = (loginJson['data'] as Map)['sid'] as String;

  // ── ① DA23：`#recycle` ──────────────────────────────────────────────
  print('\n=== ① DA23：共享文件夹里的 `#recycle` ===');
  await _show(
    base,
    '对照：teamdrivetest 本体（应成功）',
    () => {'folder_path': '/teamdrivetest'},
    sid: sid,
    api: 'SYNO.FileStation.List',
    method: 'list',
    version: 2,
  );
  await _show(
    base,
    '正题：/teamdrivetest/#recycle（真机报错的那条）',
    () => {'folder_path': '/teamdrivetest/#recycle'},
    sid: sid,
    api: 'SYNO.FileStation.List',
    method: 'list',
    version: 2,
  );
  // 再打两次：看 407 是不是**瞬时**限流（App 里 Retry 三次都同句）
  for (var i = 1; i <= 2; i++) {
    await _show(
      base,
      '正题重试 #$i（间隔 3 s，判 407 是否瞬时）',
      () => {'folder_path': '/teamdrivetest/#recycle'},
      sid: sid,
      api: 'SYNO.FileStation.List',
      method: 'list',
      version: 2,
    );
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  // v1 形态对照（版本协商是不是因素）
  await _show(
    base,
    '版本对照：同一个路径用 v1',
    () => {'folder_path': '/teamdrivetest/#recycle'},
    sid: sid,
    api: 'SYNO.FileStation.List',
    method: 'list',
    version: 1,
  );
  // 共享文件夹清单（`#recycle` 到底是不是一个"共享文件夹"级对象）
  await _show(
    base,
    '对照组：list_share（普通用户看到的根）',
    () => {'additional': '["real_path","owner","time"]'},
    sid: sid,
    api: 'SYNO.FileStation.List',
    method: 'list_share',
    version: 2,
  );
  // 哪些 Recycle 相关 API 真的存在
  final (_, infoBody) = await _raw(
    base,
    api: 'SYNO.API.Info',
    method: 'query',
    version: 1,
    extra: {'query': 'all'},
  );
  final info = jsonDecode(infoBody) as Map<String, dynamic>;
  final data = (info['data'] as Map).cast<String, dynamic>();
  final recy = data.keys
      .where((k) => k.toLowerCase().contains('recycle'))
      .toList()
    ..sort();
  print('\n── SYNO.API.Info 里含 Recycle 的 API（${recy.length} 个）');
  for (final k in recy) {
    print('   $k → ${jsonEncode(data[k])}');
  }

  // ── ② DA25：USB 列表 ───────────────────────────────────────────────
  print('\n=== ② DA25：外接设备（U 盘）列表 ===');
  await _show(
    base,
    '正题：USB/list v1 + additional=["partitions"]（= App 的报文形态）',
    () => {'additional': '["partitions"]'},
    sid: sid,
    api: 'SYNO.Core.ExternalDevice.Storage.USB',
    method: 'list',
    version: 1,
  );
  await _show(
    base,
    '对照：USB/list v1 **无参**',
    () => {},
    sid: sid,
    api: 'SYNO.Core.ExternalDevice.Storage.USB',
    method: 'list',
    version: 1,
  );
  await _show(
    base,
    '对照：假方法（应 103，证明 API/方法存在性判据有效）',
    () => {},
    sid: sid,
    api: 'SYNO.Core.ExternalDevice.Storage.USB',
    method: '__bogus__',
    version: 1,
  );
  await _show(
    base,
    '对照：兄弟 API Storage.EUnit/list v1（此前读到 105）',
    () => {},
    sid: sid,
    api: 'SYNO.Core.ExternalDevice.Storage.EUnit',
    method: 'list',
    version: 1,
  );
  await _show(
    base,
    '正题（管理员门控对照）：Storage.USB/list v1 用 **FileStation** 会话',
    () => {'additional': '["partitions"]'},
    sid: sid,
    api: 'SYNO.Core.ExternalDevice.Storage.USB',
    method: 'list',
    version: 1,
  );
  print('\n完成。以上正文都是**服务端逐字回包**，未做任何映射。');
  _client.close();
}
