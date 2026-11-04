// r395 第八轮探针：USB/list 的 404 是否与**调用形态**有关（对照组：官方前端那一种）。
//
// 动机：官方 FileStation 前端从不直呼这个 API，而是把它塞进
// `SYNO.Entry.Request/request` 的 `compound` 里（`FileBrowser.js` 的 `initExtDeviceInfo`）。
// 若"直呼 → 404 / compound → 有设备"，那就是**调用形态**问题，App 可以改。
// 另外试**不同会话名**（FileStation / Core）——`allow_other_apis` 是按会话资源文件给的。
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_raw_error8.dart
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

String _sum(String body, {int cap = 400}) {
  final b = body.replaceAll(RegExp(r'"_sid"\s*:\s*"[^"]*"'), '"_sid":"<masked>"');
  return b.length > cap ? '${b.substring(0, cap)}…' : b;
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
    print('   登录 session=$session 失败: ${_sum(b, cap: 160)}');
    return null;
  }
  print('   登录 session=$session → success');
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
  final core = await _login(base, account, password, 'Core');

  const api = 'SYNO.Core.ExternalDevice.Storage.USB';
  const officialAdditional = '["dev_type","product","status","partitions"]';

  // ① 直呼（FileStation 会话）—— 基线
  if (fs != null) {
    final (h, b) = await _raw(base,
        api: api, method: 'list', version: 1, sid: fs,
        extra: const {'additional': '["partitions"]'});
    print('── ① 直呼 USB/list v1（FileStation 会话）HTTP $h │ ${_sum(b)}');
  }

  // ② 官方形态：compound 包一层（`SYNO.Entry.Request/request`）
  if (fs != null) {
    final compound = jsonEncode([
      {
        'api': api,
        'version': 1,
        'method': 'list',
        'additional': ['dev_type', 'product', 'status', 'partitions'],
      },
    ]);
    final (h, b) = await _raw(base,
        api: 'SYNO.Entry.Request', method: 'request', version: 1, sid: fs,
        extra: {'compound': compound});
    print('── ② compound（官方前端形态，FileStation 会话）HTTP $h │ ${_sum(b, cap: 700)}');
    final (h2, b2) = await _raw(base,
        api: 'SYNO.Entry.Request', method: 'request', version: 1, sid: fs,
        extra: {
          'compound': jsonEncode([
            {
              'api': api,
              'version': 1,
              'method': 'list',
              'additional': ['partitions'],
            },
            {
              'api': 'SYNO.Core.ExternalDevice.Storage.eSATA',
              'version': 1,
              'method': 'list',
              'additional': ['partitions'],
            },
          ]),
        });
    print('── ②b compound 两连（USB + eSATA）HTTP $h2 │ ${_sum(b2, cap: 700)}');
  }

  // ③ 换个会话名（Core）直呼
  if (core != null) {
    final (h, b) = await _raw(base,
        api: api, method: 'list', version: 1, sid: core,
        extra: const {'additional': officialAdditional});
    print('── ③ 直呼（Core 会话）HTTP $h │ ${_sum(b)}');
  }

  // ④ 再确认一次"盘确实在"（同一分钟内）：list_share 里的 usbshare1 + 内容
  final (h4, b4) = await _raw(base,
      api: 'SYNO.FileStation.List', method: 'list_share', version: 2, sid: fs,
      extra: const {'additional': '["real_path"]'});
  try {
    final j = jsonDecode(b4) as Map<String, dynamic>;
    for (final s in ((j['data'] as Map)['shares'] as List).cast<Map>()) {
      if ('${s['name']}'.contains('usb')) {
        print('── ④ 同分钟复核：share=${s['name']} additional=${jsonEncode(s['additional'])}');
      }
    }
  } on FormatException {
    print('── ④ list_share 非 JSON：${_sum(b4)}');
  }

  print('\n完成（逐字回包，未做映射）。');
  _client.close();
}
