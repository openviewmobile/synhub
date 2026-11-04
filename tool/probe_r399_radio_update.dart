// r399 现场探针：`SYNO.AudioStation.Radio` 的**写形态对照**（乐器71 风格）。
//
// 动机：同一 API 有两份官方实现，**参数名不一致**——
//   * 官方安卓 `RadioEditor.java` → `radio_json`（本仓实现照它）
//   * 官方 Web 前端 `app/audio-common.js` → **`radios_json`**，且语义是
//     「用这串 JSON **替换** `[offset, offset+limit)` 这一段」，
//     记录里**只有** `title/desc/url`（无 `id`）
// ⇒ 必须当场用真 NAS 判"哪一份能把动作做完"（§2.0.9 / 仪器72）。
//
// 用法（默认 `read` 只读）：
//   dart run tool/probe_r399_radio_update.dart read
//   dart run tool/probe_r399_radio_update.dart add  [title]
//   dart run tool/probe_r399_radio_update.dart edit_json    <offset> <limit>
//   dart run tool/probe_r399_radio_update.dart edit_jsons   <offset> <limit>
//   dart run tool/probe_r399_radio_update.dart del_json     <offset> <limit>
//   dart run tool/probe_r399_radio_update.dart del_jsons    <offset> <limit>
//   dart run tool/probe_r399_radio_update.dart del_all_jsons
//
// ⚠️ 写模式会真的改 NAS 上的自定义电台列表 ⇒ 只用于验收，**用完必须清干净**
// （`del_all_jsons` 或逐条删），并回读 `UserDefined` 与 T0 对照。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

late DsmWebApi api;

Future<Map<String, dynamic>> readContainer(String container) async {
  final raw = await api.call(
    'SYNO.AudioStation.Radio',
    'list',
    preferredVersion: 2,
    params: {'container': container, 'offset': '0', 'limit': '-1'},
  );
  return raw;
}

Future<void> dumpAll(String tag) async {
  for (final c in const ['UserDefined', 'Favorite']) {
    final raw = await readContainer(c);
    print('[$tag][$c] raw=${jsonEncode(raw)}');
  }
}

/// 官方前端形状：记录**只有** title/desc/url（无 id）。
List<Map<String, dynamic>> _keep(List<Map<String, dynamic>> items) => [
  for (final it in items)
    {
      'title': '${it['title'] ?? ''}',
      'desc': '${it['desc'] ?? ''}',
      'url': '${it['url'] ?? ''}',
    },
];

Future<void> main(List<String> args) async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  if (base == null || account == null || password == null) {
    print('需要 SYNO_NAS_URL / SYNO_ACCOUNT / SYNO_PASSWORD');
    exit(2);
  }
  final mode = args.isEmpty ? 'read' : args[0];
  final tag = 'r399_$mode';
  api = DsmWebApi(
    DirectTransport.url(base, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');

  final table = api.apiTable ?? const {};
  final e = table['SYNO.AudioStation.Radio'];
  print(
    '[$tag] Radio → '
    '${e == null ? "（无此 api）" : "v${e.minVersion}-${e.maxVersion}"}',
  );

  Future<List<Map<String, dynamic>>> items() async {
    final raw = await readContainer('UserDefined');
    final list = raw['radios'];
    return [
      if (list is List)
        for (final x in list)
          if (x is Map) Map<String, dynamic>.from(x),
    ];
  }

  switch (mode) {
    case 'read':
      await dumpAll(tag);
      break;

    case 'add':
      final title = args.length > 1 ? args[1] : 'r399probe';
      final res = await api.call(
        'SYNO.AudioStation.Radio',
        'add',
        preferredVersion: 2,
        params: {
          'container': 'UserDefined',
          'title': title,
          'desc': 'r399 shape probe',
          'url': 'http://127.0.0.1:9/r399.mp3',
        },
      );
      print('[$tag] add raw=${jsonEncode(res)}');
      await dumpAll(tag);
      break;

    case 'edit_json':
    case 'edit_jsons':
    case 'del_json':
    case 'del_jsons': {
      final offset = int.parse(args[1]);
      final limit = int.parse(args[2]);
      final all = await items();
      // 该段的"新内容"：edit = 把第一条改名；del = 去掉第一条（保持其余）。
      // limit<=0 视为"整段"（本仓 App 发的就是 offset 0 / limit -1）。
      final end = limit <= 0 ? all.length : offset + limit;
      final seg = <Map<String, dynamic>>[
        for (var i = offset; i < end && i < all.length; i++) all[i],
      ];
      final payload = mode.startsWith('edit')
          ? <Map<String, dynamic>>[
              if (seg.isNotEmpty)
                {
                  ..._keep(seg)[0],
                  'title': 'r399edited',
                },
              for (var i = 1; i < seg.length; i++) _keep(seg)[i],
            ]
          : <Map<String, dynamic>>[
              for (var i = 1; i < seg.length; i++) _keep(seg)[i],
            ];
      final key = mode.endsWith('jsons') ? 'radios_json' : 'radio_json';
      final params = <String, dynamic>{
        'container': 'UserDefined',
        'offset': offset,
        'limit': limit,
        key: jsonEncode(payload),
      };
      print('[$tag] 发送 params=${jsonEncode(params)}');
      try {
        final res = await api.call(
          'SYNO.AudioStation.Radio',
          'updateradios',
          preferredVersion: 2,
          params: params,
        );
        print('[$tag] ✔ raw=${jsonEncode(res)}');
      } catch (err) {
        print('[$tag] ✘ ${err.runtimeType}: $err');
      }
      await dumpAll(tag);
      break;
    }

    case 'edit_appshape': {
      // ★ 本仓 App **当前真的会发**的形状（`_submitList` ⇒ `updateRadios`）：
      //   offset 0 / limit -1 / key `radio_json` / 整段列表且**带 id**。
      final all = await items();
      final payload = <Map<String, dynamic>>[
        for (var i = 0; i < all.length; i++)
          {
            'id': all[i]['id'],
            'title': i == 0 ? 'r399appshape' : '${all[i]['title']}',
            'url': all[i]['url'],
            'desc': all[i]['desc'],
          },
      ];
      final params = <String, dynamic>{
        'container': 'UserDefined',
        'offset': 0,
        'limit': -1,
        'radio_json': jsonEncode(payload),
      };
      print('[$tag] 发送（App 当前形状）params=${jsonEncode(params)}');
      try {
        final res = await api.call(
          'SYNO.AudioStation.Radio',
          'updateradios',
          preferredVersion: 2,
          params: params,
        );
        print('[$tag] ✔ raw=${jsonEncode(res)}');
      } catch (err) {
        print('[$tag] ✘ ${err.runtimeType}: $err');
      }
      await dumpAll(tag);
      break;
    }

    case 'del_all_jsons': {
      // 官方形状：整段（offset 0 / limit 全部）替换成"保留下来的记录"——
      // 这里全部删掉 ⇒ 空数组。
      final all = await items();
      final params = <String, dynamic>{
        'container': 'UserDefined',
        'offset': 0,
        'limit': all.length,
        'radios_json': jsonEncode(<Map<String, dynamic>>[]),
      };
      print('[$tag] 发送 params=${jsonEncode(params)}（原 ${all.length} 条）');
      try {
        final res = await api.call(
          'SYNO.AudioStation.Radio',
          'updateradios',
          preferredVersion: 2,
          params: params,
        );
        print('[$tag] ✔ raw=${jsonEncode(res)}');
      } catch (err) {
        print('[$tag] ✘ ${err.runtimeType}: $err');
      }
      await dumpAll(tag);
      break;
    }

    case 'fav_add':
    case 'fav_clear': {
      // 官方 Web 前端"加入收藏"逐字：
      //   {method:"updateradios", container:"Favorite", offset:-1, limit:0, radios_json:[…]}
      final payload = mode == 'fav_add'
          ? <Map<String, dynamic>>[
              {
                'title': args.length > 1 ? args[1] : 'r399fav',
                'desc': 'r399 favorite probe',
                'url': 'http://127.0.0.1:9/r399fav.mp3',
              },
            ]
          : <Map<String, dynamic>>[];
      final params = <String, dynamic>{
        'container': 'Favorite',
        'offset': -1,
        'limit': 0,
        'radios_json': jsonEncode(payload),
      };
      print('[$tag] 发送（官方 Favorite 形状）params=${jsonEncode(params)}');
      try {
        final res = await api.call(
          'SYNO.AudioStation.Radio',
          'updateradios',
          preferredVersion: 2,
          params: params,
        );
        print('[$tag] ✔ raw=${jsonEncode(res)}');
      } catch (err) {
        print('[$tag] ✘ ${err.runtimeType}: $err');
      }
      await dumpAll(tag);
      break;
    }

    case 'fav_del_range': {
      // 官方"删除"走的是**同一个**段替换（`onInetRadioDeleteRec` 对
      // UserDefined 与 Favorite 用同一段代码）⇒ container=Favorite、
      // offset/limit 指出被删的段、`radios_json` = 段内保留项（单条 ⇒ 空）。
      final params = <String, dynamic>{
        'container': 'Favorite',
        'offset': 0,
        'limit': 1,
        'radios_json': jsonEncode(<Map<String, dynamic>>[]),
      };
      print('[$tag] 发送 params=${jsonEncode(params)}');
      try {
        final res = await api.call(
          'SYNO.AudioStation.Radio',
          'updateradios',
          preferredVersion: 2,
          params: params,
        );
        print('[$tag] ✔ raw=${jsonEncode(res)}');
      } catch (err) {
        print('[$tag] ✘ ${err.runtimeType}: $err');
      }
      await dumpAll(tag);
      break;
    }

    default:
      print('未知模式 $mode');
  }

  await api.logout(session: 'AudioStation');
  exit(0);
}
