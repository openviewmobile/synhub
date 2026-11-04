// r408 **只读**探针：eMule 支路与「任务非空」的原始读数。
//
// 判据（仪器㉓：先钉住"现在连的是谁"）——本文件**只调只读方法**：
//   * `SYNO.DownloadStation2.Task / list` v2 —— 逐 type 过滤（all / bt / emule），
//     eMule 支路逐字照官方 aMule 面板形状 `additional=["detail","transfer"]`；
//   * `SYNO.DownloadStation2.Task.eMule / list_upload` v1 —— 上传列表（管理员专属）；
//   * `SYNO.DownloadStation2.Package.Service / get` v2 —— `enable_emule` 能力位；
//   * `SYNO.DownloadStation2.Package.Module / list` v2 —— 已装模块。
//   ⇒ 本文件里**没有任何变更动词**（没有 set/create/delete/…）。
//
// 用法：
//   set -a; . ~/.synhub-nas.env; set +a
//   export SYNO_ACCOUNT=$SYNO_NAS_ACCOUNT SYNO_PASSWORD=$SYNO_NAS_PASSWORD
//   dart run tool/probe_r408_emule.dart
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

const _apiTask = 'SYNO.DownloadStation2.Task';
const _apiEmuleUpload = 'SYNO.DownloadStation2.Task.eMule';
const _apiSvc = 'SYNO.DownloadStation2.Package.Service';
const _apiMod = 'SYNO.DownloadStation2.Package.Module';

void _dump(String label, Map<String, dynamic> r) {
  print('--- $label');
  print('success = ${r['success']}');
  print('error   = ${jsonEncode(r['error'])}');
  final data = r['data'];
  if (data is Map) {
    final total = data['total'];
    final offset = data['offset'];
    final tasks = data['tasks'];
    print('data.total=$total data.offset=$offset tasks 条数='
        '${tasks is List ? tasks.length : '（非 list：$tasks）'}');
    if (tasks is List) {
      for (var i = 0; i < tasks.length; i++) {
        final t = tasks[i];
        if (t is Map) {
          print('  [$i] id=${t['id']} type=${t['type']} '
              'status=${t['status']} title=${t['title']} '
              'size=${t['size']}');
          print('      additional 逐字 = ${jsonEncode(t['additional'])}');
        } else {
          print('  [$i] 非 map: $t');
        }
      }
    }
    // 其它键也逐字打出来（不许自己挑着看）
    for (final e in data.entries) {
      if (e.key == 'tasks') continue;
      print('data.${e.key} = ${jsonEncode(e.value)}');
    }
  } else {
    print('data 逐字 = ${jsonEncode(data)}');
  }
}

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
  print('login ok（account=${account.substring(0, 1)}***，'
      'sid 长度=${_sid.length}）');
  await _resolvePaths(const [_apiTask, _apiEmuleUpload, _apiSvc, _apiMod]);

  // ① 能力位 + 模块（先钉住"eMule 到底装没装"）
  print('=== 能力/模块（先钉住环境） ===');
  _dump('Package.Service.get v2', await _call(_apiSvc, 'get', version: 2));
  _dump('Package.Module.list v2', await _call(_apiMod, 'list', version: 2));

  // ② 三个 type 各读一遍（all / bt / emule），判据是"读到什么"
  print('=== Task.list v2 逐 type ===');
  for (final type in const ['all', 'bt', 'emule']) {
    final params = <String, String>{'offset': '0', 'limit': '100'};
    if (type != 'all') {
      params['type'] = jsonEncode([type]);
      params['additional'] = jsonEncode(['detail', 'transfer']);
    }
    _dump('Task.list v2 type=$type（params 逐字=${jsonEncode(params)}）',
        await _call(_apiTask, 'list', version: 2, params: params));
  }

  // ③ eMule 上传列表（管理员专属方法）—— 只读
  print('=== Task.eMule / list_upload v1 ===');
  _dump('Task.eMule.list_upload v1',
      await _call(_apiEmuleUpload, 'list_upload',
          version: 1, params: {'offset': '0', 'limit': '100'}));

  // ④ 直接问一下 emule 这个 method 存不存在（103 唯一否证）
  print('=== 方法存在性 oracle（103 = 不存在） ===');
  _dump('Task.list v1（对照片本）',
      await _call(_apiTask, 'list', version: 1, params: {'offset': '0', 'limit': '1'}));

  // ⑤ eMule 子系统的 API 究竟有没有（决定 App 上哪些入口该出现）
  print('=== eMule 子 API 的能力表 =（有 path 才算服务端提供）===');
  for (final api in const [
    'SYNO.DownloadStation2.eMule.Search',
    'SYNO.DownloadStation2.eMule.Server',
    'SYNO.DownloadStation2.eMule.Captcha',
    'SYNO.DownloadStation2.Task.BT',
    'SYNO.DownloadStation2.BTSearch',
  ]) {
    await _resolvePaths([api]);
  }
}
