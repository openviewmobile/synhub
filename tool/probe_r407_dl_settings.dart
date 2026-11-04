// r407 **只读**探针：下载设置页的服务端事实（T0 / T1 回读通道）。
//
// 判据（仪器㉓：先钉住"现在连的是谁"）：本探针**只调只读方法**
//   * `SYNO.DownloadStation2.Settings.AutoExtraction / get` v1 —— 设置页开关绑的字段；
//   * `SYNO.DownloadStation2.Package.Service / get` v2 —— 「Auto extract ✓/✗」能力位；
//   * `SYNO.DownloadStation2.Package.Info / get` v2 —— 套件版本；
//   * `SYNO.DownloadStation2.Package.Module / list` v2 —— 已装模块（BT / eMule）；
//   * `SYNO.DownloadStation2.Task / list` v2 —— 任务清单（含 eMule 类型探路）。
//   ⇒ 本文件里**没有任何变更动词**（没有 set/create/delete/…）。
//     真机上的写动词由 App 自己发出（设置页开关），本探针只负责**回读**。
//
// 用法：
//   set -a; . ~/.synhub-nas.env; set +a
//   export SYNO_ACCOUNT=$SYNO_NAS_ACCOUNT SYNO_PASSWORD=$SYNO_NAS_PASSWORD
//   dart run tool/probe_r407_dl_settings.dart get
//   dart run tool/probe_r407_dl_settings.dart tasks [emule|bt|all]
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

final HttpClient _client = HttpClient()
  ..badCertificateCallback = (_, __, ___) => true;

late String _base;
String _sid = '';

/// api → path（**必须**由能力表给；写死 entry.cgi 会被拒 —— r406 亲测）
final Map<String, String> _paths = {};

/// api → maxVersion（能力表给的版本上限，用来挑"最早包含该方法"的版本）
final Map<String, int> _maxVersions = {};

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
        final mx = v['maxVersion'];
        _maxVersions['${e.key}'] = mx is num ? mx.toInt() : 1;
      }
    }
  }
  print('能力表 path = $_paths');
  print('能力表 maxVersion = $_maxVersions');
}

Future<Map<String, dynamic>> _call(
  String api,
  String method, {
  Map<String, String> params = const {},
  int? version,
}) async {
  final path = _paths[api] ?? 'entry.cgi';
  final v = version ?? (_maxVersions[api] ?? 1);
  final req = await _client.postUrl(Uri.parse('$_base/webapi/$path'));
  req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
  req.write({
    'api': api,
    'version': '$v',
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

const _api = 'SYNO.DownloadStation2.Settings.AutoExtraction';
const _apiSvc = 'SYNO.DownloadStation2.Package.Service';
const _apiInfo = 'SYNO.DownloadStation2.Package.Info';
const _apiMod = 'SYNO.DownloadStation2.Package.Module';
const _apiTask = 'SYNO.DownloadStation2.Task';

Future<void> main(List<String> args) async {
  _base = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_ACCOUNT'] ??
      Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_PASSWORD'] ??
      Platform.environment['SYNO_NAS_PASSWORD']!;

  final login = await _call('SYNO.API.Auth', 'login',
      version: 6,
      params: {
        'account': account,
        'passwd': password,
        'session': 'DownloadStation',
        'format': 'sid',
      });
  if (login['success'] != true) {
    print('login 失败：$login');
    exit(1);
  }
  _sid = (login['data'] as Map)['sid'] as String;
  print('login ok（account=${account.substring(0, 1)}***）');
  await _resolvePaths(const [_api, _apiSvc, _apiInfo, _apiMod, _apiTask]);

  final mode = args.isEmpty ? 'get' : args[0];

  if (mode == 'get') {
    // ① 设置页开关绑的字段（App 的 get 也走这里：v1）
    final ax = await _call(_api, 'get', version: 1);
    print('AutoExtraction.get v1 → success=${ax['success']}');
    print('  逐字 data = ${jsonEncode(ax['data'])}');
    print('  逐字 error = ${jsonEncode(ax['error'])}');
    // ② 能力位（「Auto extract ✓/✗」那一行）
    final svc = await _call(_apiSvc, 'get', version: 2);
    print('Package.Service.get v2 → success=${svc['success']}');
    print('  逐字 data = ${jsonEncode(svc['data'])}');
    // ③ 套件版本
    final info = await _call(_apiInfo, 'get', version: 2);
    print('Package.Info.get v2 → success=${info['success']} '
        'data=${jsonEncode(info['data'])}');
    // ④ 已装模块（BT / eMule）
    final mods = await _call(_apiMod, 'list', version: 2);
    print('Package.Module.list v2 → success=${mods['success']}');
    final list = (mods['data'] as Map?)?['modules'];
    if (list is List) {
      for (final m in list) {
        final mm = m as Map;
        print('  folder=${mm['folder']} fn=${mm['fn']} '
            'id=${mm['id']} version=${mm['version']}');
      }
    } else {
      print('  逐字 data = ${jsonEncode(mods['data'])}');
    }
    return;
  }

  if (mode == 'tasks') {
    // eMule 支路的**只读**探路：先看 Task.list 能不能按 type 过滤。
    final type = args.length > 1 ? args[1] : 'all';
    final params = <String, String>{'offset': '0', 'limit': '100'};
    if (type != 'all') {
      // 官方前端形状：type=["emule"] / type=["bt"]（JSON 数组字符串）
      params['type'] = jsonEncode([type]);
    }
    final r = await _call(_apiTask, 'list', version: 2, params: params);
    print('Task.list v2 type=$type → success=${r['success']}');
    print('  逐字 data（截 800 字）= '
        '${jsonEncode(r['data']).substring(0, jsonEncode(r['data']).length.clamp(0, 800))}');
    print('  逐字 error = ${jsonEncode(r['error'])}');
    return;
  }

  print('未知模式 $mode（可用：get / tasks [type]）');
}
