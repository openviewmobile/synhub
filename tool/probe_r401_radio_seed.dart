// r401 探针（**会写**，但只写本轮自造的数据）：给「网络电台 · 自定义电台」造 N 条测试电台，
// 供真机验「**第二屏的行号是否仍对准服务端行号**」，并在轮末**段替换批量删净**。
//
// 为什么需要 N > 25：App 的电台分页 `pageSize = 25`（`AudioStationApi.pageSize`），
// `loadMore` 发的是 `offset = 已加载行数`。要验"第 26/27 行（第二屏）的行号"，
// 就必须让列表**真的超过一屏**。
//
// 子命令：
//   seed <n>   —— `Radio.add` × n（容器 `UserDefined`，标题 `r401s01…r401sNN`）
//   list       —— 只读：root / UserDefined / Favorite 三段原始回包（含每行逐字）
//   wipe       —— **段替换批量删除**：`updateradios {offset:0, limit:total, radios_json:'[]'}`
//                 （若残余非空，再逐行 `limit:1` 兜底删）
//
// 运行：
//   SYNO_NAS_URL=… SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… \
//     dart run tool/probe_r401_radio_seed.dart r401 <子命令> [n]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String _tagPrefix = 'r401';

Future<Map<String, dynamic>> _call(
  DsmWebApi api,
  String method,
  Map<String, dynamic> params,
) async {
  return api.call(
    'SYNO.AudioStation.Radio',
    method,
    preferredVersion: 2,
    params: params,
  );
}

Future<void> _dump(DsmWebApi api, String tag) async {
  for (final container in const [null, 'UserDefined', 'Favorite']) {
    final label = container ?? 'root';
    final params = <String, dynamic>{'offset': '0', 'limit': '-1'};
    if (container != null) params['container'] = container;
    try {
      final raw = await _call(api, 'list', params);
      final rows = (raw['radios'] as List?) ?? const [];
      print('[$tag][$label] raw=${jsonEncode(raw)}');
      print('[$tag][$label] total=${raw['total']} rows=${rows.length}');
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        final id = (r is Map) ? r['id'] : null;
        final title = (r is Map) ? r['title'] : null;
        print('[$tag][$label] row[$i] id=$id title=$title');
      }
    } catch (err) {
      print('[$tag][$label] ✘ ${err.runtimeType}: $err');
    }
  }
}

Future<void> main(List<String> args) async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'] ??
      Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'] ??
      Platform.environment['SYNO_PASSWORD'];
  final tag = args.isNotEmpty ? args[0] : _tagPrefix;
  final cmd = args.length > 1 ? args[1] : 'list';
  final n = args.length > 2 ? int.tryParse(args[2]) ?? 27 : 27;
  if (base == null || account == null || password == null) {
    print('需要 SYNO_NAS_URL / SYNO_NAS_ACCOUNT / SYNO_NAS_PASSWORD');
    exit(2);
  }
  final api = DsmWebApi(
    DirectTransport.url(base, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');

  switch (cmd) {
    case 'seed':
      for (var i = 1; i <= n; i++) {
        final title = '${_tagPrefix}s${i.toString().padLeft(2, '0')}';
        final url = 'http://127.0.0.1:9/$title';
        try {
          final raw = await _call(api, 'add', {
            'container': 'UserDefined',
            'title': title,
            'url': url,
            'desc': _tagPrefix,
          });
          print('[$tag][add $i/$n] $title raw=${jsonEncode(raw)}');
        } catch (err) {
          print('[$tag][add $i/$n] $title ✘ ${err.runtimeType}: $err');
        }
      }
      await _dump(api, '$tag/after-seed');
      break;
    case 'list':
      await _dump(api, tag);
      break;
    case 'wipe':
      final before = await _call(api, 'list', {
        'container': 'UserDefined',
        'offset': '0',
        'limit': '-1',
      });
      final rows = (before['radios'] as List?) ?? const [];
      final total = rows.length;
      print('[$tag][wipe] before total=${before['total']} rows=$total');
      if (total > 0) {
        // ★ 一次性段替换清空：`limit = 行数`（官方"批量删除"形态）
        final raw = await _call(api, 'updateradios', {
          'container': 'UserDefined',
          'offset': 0,
          'limit': total,
          'radios_json': '[]',
        });
        print('[$tag][wipe] batch raw=${jsonEncode(raw)}');
      }
      var after = await _call(api, 'list', {
        'container': 'UserDefined',
        'offset': '0',
        'limit': '-1',
      });
      print('[$tag][wipe] after-batch total=${after['total']} '
          'raw=${jsonEncode(after)}');
      // 兜底：万一批量清不掉，逐行 limit:1 删（本轮自造数据）
      var guard = 0;
      while (((after['radios'] as List?) ?? const []).isNotEmpty &&
          guard < 60) {
        guard++;
        final raw = await _call(api, 'updateradios', {
          'container': 'UserDefined',
          'offset': 0,
          'limit': 1,
          'radios_json': '[]',
        });
        after = await _call(api, 'list', {
          'container': 'UserDefined',
          'offset': '0',
          'limit': '-1',
        });
        print('[$tag][wipe] fallback#$guard raw=${jsonEncode(raw)} '
            'total=${after['total']}');
      }
      await _dump(api, '$tag/after-wipe');
      break;
    default:
      print('未知子命令：$cmd（可用 seed / list / wipe）');
  }

  await api.logout(session: 'AudioStation');
  exit(0);
}
