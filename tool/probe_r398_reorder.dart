// r398 根因探针：`SYNO.AudioStation.Pin / reorder` 在真机上回 **117** —— 到底是
// 参数形状不对，还是方法本身在这个 NAS 上不可用？
//
// 用法：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/probe_r398_reorder.dart <mode>
//
// mode（每种都**先读 list，再取"当前两条记录"，再按该形状下发 reorder**，
// 每次下发后立刻回读 list，把服务端顺序逐字打出来）：
//   repro    = 我们 App 现在发的形状：`items` 是 `[{type,criteria,name}]`（**无 id**）+ offset/limit
//   withid   = `items` 带 **id**：`[{id,type,criteria,name}]` + offset/limit
//   nooffset = `items` 带 id，**不带** offset/limit
//   ids      = `items` 是 **id 数组**（像 unpin 那样）
//
// ⚠️ 写动词：`reorder` 会改**收藏顺序**。本探针只用于本轮自建的两条收藏
// （`r398album` / `101 Dalmatians…`），收尾会全部 `unpin` ⇒ 不残留。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  final mode = args.isEmpty ? 'repro' : args.first;
  if (base == null || account == null || password == null) {
    print('需要 SYNO_NAS_URL / SYNO_ACCOUNT / SYNO_PASSWORD');
    exit(2);
  }
  final api = DsmWebApi(
    DirectTransport.url(base, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');

  Future<List<Map<String, dynamic>>> list() async {
    final raw = await api.call(
      'SYNO.AudioStation.Pin',
      'list',
      params: {'offset': '0', 'limit': '-1'},
    );
    final items = raw['items'];
    return [
      if (items is List)
        for (final e in items)
          if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  Future<void> show(String tag) async {
    final items = await list();
    print('[$tag] total=${items.length} order=${items.map((e) => e['id']).toList()}');
    for (final e in items) {
      print('[$tag]   ${jsonEncode(e)}');
    }
  }

  await show('$mode·before');
  final cur = await list();
  if (cur.length < 2) {
    print('[$mode] 只有 ${cur.length} 条收藏，没法测重排 —— 先建两条再来。');
    exit(3);
  }
  // 目标次序 = 原次序倒过来（这样"成功"与"没生效"一眼能分）
  final target = cur.reversed.toList();

  final Map<String, dynamic> params;
  switch (mode) {
    case 'repro':
      params = {
        'items': jsonEncode([
          for (final e in target)
            {
              'type': e['type'],
              'criteria': e['criteria'],
              'name': e['name'],
            },
        ]),
        'offset': '0',
        'limit': '-1',
      };
    case 'withid':
      params = {
        'items': jsonEncode([
          for (final e in target)
            {
              'id': e['id'],
              'type': e['type'],
              'criteria': e['criteria'],
              'name': e['name'],
            },
        ]),
        'offset': '0',
        'limit': '-1',
      };
    case 'nooffset':
      params = {
        'items': jsonEncode([
          for (final e in target)
            {
              'id': e['id'],
              'type': e['type'],
              'criteria': e['criteria'],
              'name': e['name'],
            },
        ]),
      };
    case 'ids':
      params = {
        'items': jsonEncode([for (final e in target) e['id']]),
      };
    case 'idsoffset':
      // ★ 官方 Android 客户端（DSaudio.apk → ApiEnumerator.reorder）逐字：
      //   `items` = Gson(idList)（**id 字符串数组**）、`offset` = 0、`limit` = -1
      params = {
        'items': jsonEncode([for (final e in target) e['id']]),
        'offset': '0',
        'limit': '-1',
      };
    default:
      print('未知 mode: $mode');
      exit(2);
  }

  print('[$mode] 下发参数（逐字）: ${jsonEncode(params)}');
  try {
    final raw = await api.call(
      'SYNO.AudioStation.Pin',
      'reorder',
      preferredVersion: 1,
      params: params,
    );
    print('[$mode] ✔ 回包=${jsonEncode(raw)}');
  } catch (e) {
    final code = e is DsmApiException ? e.code : null;
    print('[$mode] ✘ 失败 code=$code raw=$e');
  }
  await show('$mode·after');
  await api.logout(session: 'AudioStation');
  exit(0);
}
