// r408 **写侧**探针：`Task/create` 的参数形状矩阵（找 120 的根因，拿原始 error.code）。
//
// 为什么必须写：App 的"链接浏览器 → 添加到下载"在真机上对 **ed2k 与 .torrent URL
// 都返回 120**（`Invalid request parameter`），而服务端 120 不会告诉我们**哪个参数**
// 不合格。要定性只能逐形状试一次，看**哪一个形状被接受**。
//
// 纪律：
//   * 只建**冒烟任务**（`https://example.com/nothing.torrent` 这类不可能真下的地址）；
//   * 每次成功后**立刻记下 task id**，收尾**按 id 删净**（r377：证明不了是自己造的不许删）；
//   * 收尾打印 `Task.list` 读回，必须回到 0。
//
// 用法：
//   set -a; . ~/.synhub-nas.env; set +a
//   export SYNO_ACCOUNT=$SYNO_NAS_ACCOUNT SYNO_PASSWORD=$SYNO_NAS_PASSWORD
//   dart run tool/probe_r408_create_shape.dart
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

final HttpClient _client = HttpClient()
  ..badCertificateCallback = (_, _, _) => true;

late String _base;
String _sid = '';
final Map<String, String> _paths = {};
final Map<String, int> _maxVersions = {};

const _apiTask = 'SYNO.DownloadStation2.Task';

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
  await _resolvePaths(const [_apiTask]);
  print('login ok；path=${_paths[_apiTask]} maxVersion=${_maxVersions[_apiTask]}');

  final link = args.isNotEmpty ? args[0] : 'https://example.com/nothing.torrent';
  print('冒烟链接（逐字）= $link');

  // 形状矩阵：`type` 带不带引号 × `create_list` 的类型
  final shapes = <String, Map<String, String>>{
    'A type=plain, create_list=false(bool)': {
      'type': 'url',
      'url': jsonEncode([link]),
      'create_list': 'false',
    },
    'B type=quoted, create_list=false(bool)': {
      'type': jsonEncode('url'),
      'url': jsonEncode([link]),
      'create_list': 'false',
    },
    'C type=quoted, create_list=quoted': {
      'type': jsonEncode('url'),
      'url': jsonEncode([link]),
      'create_list': jsonEncode(false),
    },
    'D type=plain, 无 create_list': {
      'type': 'url',
      'url': jsonEncode([link]),
    },
    'E type=url, url=裸串（非 JSON 数组）': {
      'type': 'url',
      'url': link,
      'create_list': 'false',
    },
  };

  final createdIds = <String>[];
  for (final e in shapes.entries) {
    final r = await _call(_apiTask, 'create',
        version: _maxVersions[_apiTask] ?? 2, params: e.value);
    print('--- $e');
    print('    params 逐字 = ${jsonEncode(e.value)}');
    print('    success=${r['success']} error=${jsonEncode(r['error'])} '
        'data=${jsonEncode(r['data'])}');
    final data = r['data'];
    if (r['success'] == true && data is Map) {
      final ids = data['task_id'] ?? data['id'] ?? data['list_id'];
      print('    task_id/list_id = ${jsonEncode(ids)}');
      final list = ids is List ? ids : (ids == null ? const [] : [ids]);
      for (final id in list) {
        createdIds.add('$id');
      }
    }
    // 只有成功才继续（避免把同一形状反复试；失败必须换形状）
  }

  // 读回：这次到底建出来几条，分别是什么
  print('=== 读回（type=all） ===');
  final lst = await _call(_apiTask, 'list',
      version: _maxVersions[_apiTask] ?? 2,
      params: {'offset': '0', 'limit': '100'});
  print('success=${lst['success']} data=${jsonEncode(lst['data'])}');

  // ---- 第二轮：补上服务端**明确点名**的必填项 `destination`
  print('=== 第二轮：补 destination（服务端点名的必填项） ===');
  await _resolvePaths(const ['SYNO.DownloadStation2.Settings.Location']);
  final loc = await _call('SYNO.DownloadStation2.Settings.Location', 'get',
      version: 1);
  print('Location.get → success=${loc['success']} '
      'data=${jsonEncode(loc['data'])}');
  final dest = '${(loc['data'] as Map?)?['default_destination'] ?? ''}';
  print('取到的 default_destination（逐字）= "$dest"');

  if (dest.isEmpty) {
    print('服务端没给默认目录 ⇒ 这一轮无法继续（如实记录，不猜）');
  } else {
    final destShapes = <String, Map<String, String>>{
      'F destination=JSON 串（带引号）': {
        'type': 'url',
        'url': jsonEncode([link]),
        'destination': jsonEncode(dest),
        'create_list': 'false',
      },
      'G destination=裸串': {
        'type': 'url',
        'url': jsonEncode([link]),
        'destination': dest,
        'create_list': 'false',
      },
    };
    for (final e in destShapes.entries) {
      final r = await _call(_apiTask, 'create',
          version: _maxVersions[_apiTask] ?? 2, params: e.value);
      print('--- $e');
      print('    params 逐字 = ${jsonEncode(e.value)}');
      print('    success=${r['success']} error=${jsonEncode(r['error'])} '
          'data=${jsonEncode(r['data'])}');
      final data = r['data'];
      if (r['success'] == true && data is Map) {
        final ids = data['task_id'] ?? data['id'];
        print('    task_id = ${jsonEncode(ids)}');
        if (ids is List) {
          for (final id in ids) {
            createdIds.add('$id');
          }
        } else if (ids != null) {
          createdIds.add('$ids');
        }
      }
      // 建出来一条就够定性了，后面的形状不再试（避免留垃圾）
      if (createdIds.isNotEmpty) break;
    }
  }

  // 收尾：按 id 删净（**只删自己刚建的**）
  if (createdIds.isEmpty) {
    print('没有建出任何任务（createdIds 为空）⇒ 无可删');
  } else {
    print('收尾删除（只删刚建的 id）= $createdIds');
    final del = await _call(_apiTask, 'delete',
        version: _maxVersions[_apiTask] ?? 2,
        params: {'id': jsonEncode(createdIds)});
    print('delete success=${del['success']} error=${jsonEncode(del['error'])} '
        'data=${jsonEncode(del['data'])}');
  }
  final after = await _call(_apiTask, 'list',
      version: _maxVersions[_apiTask] ?? 2,
      params: {'offset': '0', 'limit': '100'});
  print('=== 收尾读回（应为 total=0） ===');
  print('success=${after['success']} data=${jsonEncode(after['data'])}');
}
