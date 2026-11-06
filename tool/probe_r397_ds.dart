// r397 只读探针：Download Station 任务状态 + `/home/Download` 目录回读。
//
// 目的（目标④「下载·清单成功态」的真机切片）：
//   * 真机把 `.torrent` 经 App 建任务 → 「选文件」清单页成功渲染；
//   * 本探针从**服务端侧**读两件事，给出口径独立的判据：
//       ① `SYNO.DownloadStation2.Task / list` v2 的逐字回包（status / size /
//          additional.detail 里的 error / 速度）；
//       ② `SYNO.FileStation.List / list` v2 读 `/home/Download`，看落盘文件
//          （名字 + 字节数 + mtime）。
//
// ★ 只读：不调用任何变更动词（set/delete/create/…）。登录会话名为 `FileStation`
//   （与 App 一致），跑完不 logout（与 r395 探针同口径，避免把 App 的会话挤掉）。
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_r397_ds.dart
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

String _clip(String s, [int n = 900]) =>
    s.length <= n ? s : '${s.substring(0, n)}…（共 ${s.length} 字节）';

Future<void> main() async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'];
  if (base == null || account == null || password == null) {
    stderr.writeln('缺少 SYNO_NAS_URL / SYNO_NAS_ACCOUNT / SYNO_NAS_PASSWORD');
    exit(2);
  }

  // ① 登录（会话名与 App 一致）
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
  final lj = jsonDecode(lb);
  final sid = (lj is Map && lj['data'] is Map) ? lj['data']['sid'] as String? : null;
  print('=== ① 登录 http=$ls success=${lj is Map ? lj['success'] : '?'} '
      'sid=${sid == null ? 'null' : '${sid.substring(0, 4)}…'}');
  if (sid == null) exit(3);

  // ② Download Station 任务列表（只读）
  final (ts, tb) = await _raw(base,
      api: 'SYNO.DownloadStation2.Task',
      method: 'list',
      version: 2,
      sid: sid,
      extra: {
        'offset': '0',
        'limit': '30',
        'additional': jsonEncode(const ['detail', 'transfer', 'file']),
      });
  print('\n=== ② Task/list v2 http=$ts');
  print(_clip(tb, 2400));

  // ③ /home/Download 目录回读（只读）
  for (final path in const ['/home/Download', '/home/Download/r397_bt_payload.bin']) {
    final (fs, fb) = await _raw(base,
        api: 'SYNO.FileStation.List',
        method: 'list',
        version: 2,
        sid: sid,
        extra: {
          'folder_path': path,
          'additional': jsonEncode(const ['size', 'time']),
        });
    print('\n=== ③ FileStation.List v2 folder_path=$path http=$fs');
    print(_clip(fb, 1200));
  }

  _client.close(force: true);
}
