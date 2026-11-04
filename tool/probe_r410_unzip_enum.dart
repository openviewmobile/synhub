// r410 **受控写窗口**探针：`Settings.AutoExtraction` 的 `unzip_location` 到底收哪些值。
//
// 为什么必须有它：真机上 App 发 `unzip_location=select_folder`
// （**官方 `ui/download.js` 的 radio inputValue 逐字**）被服务端拒了：
// `120 Invalid request parameter (unzip_location)`。反证出现**不许解释掉**
// （仪器㉒）⇒ 用探针把每个候选值**逐个**打一遍，看服务端逐字回什么，
// 最后**把所有字段还原成 T0** 并回读确认。
//
// ⚠️ 这是**写动词**探针（`set`），只在"枚举定性"这一个用途上使用：
//   ① 打之前先 `get` 记 T0；② 打完逐个 `get` 回读；③ 收尾**还原 T0** 再 `get`。
//
// 用法：
//   set -a; . ~/.synhub-nas.env; set +a
//   export SYNO_ACCOUNT=$SYNO_NAS_ACCOUNT SYNO_PASSWORD=$SYNO_NAS_PASSWORD
//   dart run tool/probe_r410_unzip_enum.dart enum [path]
//
// 原始 r407 只读探针：
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
  print('login ok');
  await _resolvePaths(const [_api]);

  Future<void> show(String tag) async {
    final r = await _call(_api, 'get', version: 1);
    print('$tag → data = ${jsonEncode(r['data'])}');
  }

  Future<void> set(String tag, Map<String, String> params) async {
    final r = await _call(_api, 'set', version: 1, params: params);
    print('$tag set $params → success=${r['success']} '
        'error=${jsonEncode(r['error'])}');
  }

  final mode = args.isEmpty ? 'enum' : args[0];
  if (mode == 'clear') {
    // T0 里 `unzip_to_path` 是**空串**；空串 set 返回 success 却**不回写**
    // ⇒ 逐个试"清空"的编码，看哪个真能把它写回空。
    print('=== 清空前 ===');
    await show('before');
    // 结论（实测）：**只有 JSON 空串 `""` 能把路径写回空**；裸空串返回
    // success 却**不回写**（服务端当参数缺失）。这里只发**该编码**收尾。
    await set('[final-restore]', {
      'unzip_location': 'true',
      'unzip_to_path': jsonEncode(''),
      'enable_unzip': 'false',
      'create_subfolder': 'false',
      'unzip_overwrite': 'false',
      'delete_archive': 'false',
    });
    await show('  [final-restore] 回读');
    print('=== 收尾 ===');
    await show('final');
    return;
  }
  if (mode != 'enum') {
    print('未知模式 $mode（可用：enum / clear）');
    return;
  }
  final path = args.length > 1 ? args[1] : 'home/Download';

  print('=== T0 ===');
  await show('T0 get');
  print('=== 逐个候选值（每次都带上 path，官方 allowBlank:false）===');
  // 服务端对**每一个**字符串都回 `reason:"type"`（不是 `value`）⇒ 类型不对。
  // 逐个候选**编码**打一遍（DSM 里数组/布尔/整数都出现过）。
  final candidates = <String, String>{
    'JSON 数组 ["select_folder"]': jsonEncode(['select_folder']),
    'JSON 数组 ["current_folder"]': jsonEncode(['current_folder']),
    '裸字符串（已知被拒）': 'select_folder',
    '整数 1': '1',
    '整数 0': '0',
    '布尔 true': 'true',
    '布尔 false': 'false',
  };
  for (final e in candidates.entries) {
    await set('[${e.key}]', {'unzip_location': e.value, 'unzip_to_path': path});
    await show('  [${e.key}] 回读');
  }
  print('=== 还原 T0：location=current_folder、path 清空、enable_unzip=false ===');
  // ★ 还原也必须用**服务端认的类型**（布尔）：`true` = current_folder。
  await set('[restore-loc=true]', {'unzip_location': 'true'});
  await set('[restore-path]', {'unzip_to_path': ''});
  await set('[restore-enableoff]', {'enable_unzip': 'false'});
  await set('[restore-subfolder]', {'create_subfolder': 'false'});
  await set('[restore-overwrite]', {'unzip_overwrite': 'false'});
  await set('[restore-delete]', {'delete_archive': 'false'});
  print('=== T2（必须逐字等于 T0）===');
  await show('T2 get');
}
