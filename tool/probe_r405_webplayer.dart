// r405 探针：`SYNO.AudioStation.WebPlayer` 的**读**与**写**（写队列）。
//
// 背景：r405 目标④ 的残留之一是「`audio_web_queue_page` 队列**非空**时的排序/清空」——
// 而本 App **只读**这条队列（`getplaylist`），从不写它（源码注释逐字：
// 「未取证（不猜）：`updateplaylist`（写）」）。要验"非空渲染"就得先让服务端
// 队列非空 ⇒ 需要一条**外部**写入通道。
//
// 本探针的打法（**先问服务端，不猜**）：
//   1. 打印 `SYNO.AudioStation.WebPlayer` 在能力表里的版本/path；
//   2. `getplaylist` 无参 → 逐字原始回包（基线）；
//   3. `updateplaylist` **不带任何参数** → 期望 `120 {name:…,reason:"required"}`，
//      让服务端**自己报出**必填参数名（这是本仓一贯的 oracle 用法）；
//   4. `fill`：按 oracle 报出的名字逐个补齐，每次打印**逐字回包**；
//   5. `read`：只读回读；
//   6. `clear`：把队列还原成空（终态必须与基线逐字相同）。
//
// ⚠️ 这会改**服务端会话队列**（不是用户音乐库、不是收藏/评分），
//    且**每条分支结束后都必须还原成空**（`clear` + `read` 对账）。
// ⚠️ 口令只从环境变量来，**不落库**。
//
// 运行：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/probe_r405_webplayer.dart <mode> [tag]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

const _api = 'SYNO.AudioStation.WebPlayer';

Future<DsmWebApi> _login() async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  if (base == null || account == null || password == null) {
    print('需要 SYNO_NAS_URL / SYNO_ACCOUNT / SYNO_PASSWORD');
    exit(2);
  }
  final api = DsmWebApi(
    DirectTransport.url(base, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');
  return api;
}

Future<void> _read(DsmWebApi api, String tag) async {
  try {
    final raw = await api.call(_api, 'getplaylist');
    print('[$tag] getplaylist raw=${jsonEncode(raw)}');
    final songs = raw['songs'];
    print(
      '[$tag] rootKeys=${(raw.keys.toList()..sort()).join(",")} '
      'total=${raw['total']} current=${raw['current']} mode=${raw['mode']} '
      'shuffle=${raw['shuffle']} songs=${songs is List ? songs.length : "非 List"}',
    );
    if (songs is List) {
      for (var i = 0; i < songs.length; i++) {
        final e = songs[i];
        if (e is Map) {
          print('[$tag] song[$i] keys=${(e.keys.toList()..map((k) => k.toString())).toList()..sort()}');
        }
        print('[$tag] song[$i]=${jsonEncode(e)}');
      }
    }
  } catch (e) {
    print('[$tag] getplaylist ERR $e');
  }
}

/// 不带参数调用 → 让服务端报出必填参数名。
Future<void> _oracle(DsmWebApi api, String tag) async {
  try {
    final raw = await api.call(_api, 'updateplaylist');
    print('[$tag] updateplaylist(无参) raw=${jsonEncode(raw)}');
  } catch (e) {
    print('[$tag] updateplaylist(无参) ERR $e');
  }
}

Future<void> _call(DsmWebApi api, String tag, Map<String, String> params) async {
  print('[$tag] → $params');
  try {
    final raw = await api.call(_api, 'updateplaylist', params: params);
    print('[$tag] ← raw=${jsonEncode(raw)}');
  } catch (e) {
    print('[$tag] ← ERR $e');
  }
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'read' : args.first;
  final tag = args.length > 1 ? args[1] : 'r405w';
  final api = await _login();
  final e = (api.apiTable ?? const {})[_api];
  print('[$tag] $_api → v${e?.minVersion}-${e?.maxVersion} path=${e?.path ?? "-"}');

  switch (mode) {
    case 'read':
      await _read(api, tag);
    case 'songs':
      // 只读：取 2 首歌的 `id`/`path`，给 `fill` 当输入。
      final raw = await api.call(
        'SYNO.AudioStation.Song',
        'list',
        preferredVersion: 3,
        params: {
          'additional': 'song_tag,song_audio',
          'offset': '0',
          'limit': '2',
        },
      );
      final items = raw['songs'] ?? raw['items'];
      print('[$tag] Song.list rootKeys=${(raw.keys.toList()..sort()).join(",")} '
          'n=${items is List ? items.length : "非 List"}');
      if (items is List) {
        for (final e in items) {
          if (e is Map) {
            print('[$tag] song id=${e['id']} path=${e['path']} title=${e['title']}');
          }
        }
      }
    case 'oracle':
      await _read(api, tag);
      await _oracle(api, tag);
      await _read(api, tag);
    case 'fill':
      // 候选形态（逐个补，每步都读回包）：
      // 官方 Web Player 的队列 = songs(JSON 数组) + current + mode + shuffle。
      final ids = args.length > 2 ? args[2] : '';
      final paths = args.length > 3 ? args[3] : '';
      final songs = <Map<String, String>>[];
      if (ids.isNotEmpty) {
        final idList = ids.split(',');
        final pathList = paths.split(',');
        for (var i = 0; i < idList.length; i++) {
          songs.add({
            'id': idList[i],
            if (i < pathList.length && pathList[i].isNotEmpty) 'path': pathList[i],
          });
        }
      }
      await _call(api, tag, {
        'songs': jsonEncode(songs),
        'current': '0',
        'mode': 'normal',
        'shuffle': '0',
        'updated_index': '-1',
      });
      await _read(api, tag);
    case 'official':
      // ★ 官方 Web 前端的**逐字**形态（来源：AudioStation-7.2.1-6006 的
      //   `app/audio-common.js` `onPlayingQueueCommit` + `app/audio-utils.js`
      //   `getWebAPIParams`/`getSongIdList`）：
      //     api=SYNO.AudioStation.WebPlayer & method=updateplaylist & version=1
      //     library=<browse_personal_library ? … : "shared">  id=__SYNO_WEB_PLAYER__
      //     offset / limit / play / updated_index / songs(=**逗号连接的 id 串**)
      //     keep_shuffle_order / containers_json / force_reload
      //   ⚠️ `songs` **不是**记录数组 —— 是 `getSongIdList()` 拼出来的 id 串。
      final ids = args.length > 2 ? args[2] : '';
      final library = args.length > 3 ? args[3] : 'shared';
      final raw = await api.call(
        'SYNO.AudioStation.Song',
        'list',
        preferredVersion: 3,
        params: {'additional': 'song_tag', 'offset': '0', 'limit': '400'},
      );
      final items = (raw['songs'] ?? raw['items']) as List?;
      final known = <String>{};
      for (final e in items ?? const []) {
        if (e is Map && e['id'] != null) known.add(e['id'].toString());
      }
      final want = ids.split(',').where((e) => e.isNotEmpty).toList();
      for (final id in want) {
        print('[$tag] 目标 $id 在本馆里=${known.contains(id)}');
      }
      await _call(api, tag, {
        'library': library,
        'id': '__SYNO_WEB_PLAYER__',
        'offset': '0',
        'limit': '-1',
        'play': 'false',
        'songs': want.join(','),
        'updated_index': '-1',
        'keep_shuffle_order': 'false',
      });
      await _read(api, tag);
    case 'playat':
      // 让服务端把 `current` 指到第 N 条（验"标记跟着 current 走，而不是恒在第一行"）。
      final idx = args.length > 2 ? args[2] : '1';
      final library = args.length > 3 ? args[3] : 'shared';
      await _call(api, tag, {
        'library': library,
        'id': '__SYNO_WEB_PLAYER__',
        'offset': idx,
        'limit': '1',
        'play': 'true',
        'updated_index': idx,
        'keep_shuffle_order': 'false',
      });
      await _read(api, tag);
    case 'del':
      // 段删除：`songs` 空 + `offset`/`limit` 指一段（r405 实测语义）。
      final off = args.length > 2 ? args[2] : '0';
      final lim = args.length > 3 ? args[3] : '1000';
      final library = args.length > 4 ? args[4] : 'shared';
      await _call(api, tag, {
        'library': library,
        'id': '__SYNO_WEB_PLAYER__',
        'offset': off,
        'limit': lim,
        'play': 'false',
        'updated_index': '-1',
        'keep_shuffle_order': 'false',
      });
      await _read(api, tag);
    case 'officialclear':
      final library = args.length > 2 ? args[2] : 'shared';
      await _call(api, tag, {
        'library': library,
        'id': '__SYNO_WEB_PLAYER__',
        'offset': '0',
        'limit': '-1',
        'play': 'false',
        'songs': '',
        'updated_index': '-1',
        'keep_shuffle_order': 'false',
      });
      await _read(api, tag);
    case 'fillids':
      // 只给 id，路径在本探针内用 Song.list 查（不手抄路径）。
      final want = (args.length > 2 ? args[2] : '').split(',').where((e) => e.isNotEmpty).toList();
      final listRaw = await api.call(
        'SYNO.AudioStation.Song',
        'list',
        preferredVersion: 3,
        params: {'additional': 'song_tag', 'offset': '0', 'limit': '400'},
      );
      final items = (listRaw['songs'] ?? listRaw['items']) as List?;
      final byId = <String, Map>{};
      for (final e in items ?? const []) {
        if (e is Map && e['id'] != null) byId[e['id'].toString()] = e;
      }
      final songs = <Map<String, String>>[];
      for (final id in want) {
        final rec = byId[id];
        print('[$tag] 找 $id → ${rec == null ? "没找到" : rec['path']}');
        songs.add({
          'id': id,
          if (rec != null && rec['path'] != null) 'path': rec['path'].toString(),
          if (rec != null && rec['title'] != null) 'title': rec['title'].toString(),
        });
      }
      await _call(api, tag, {
        'songs': jsonEncode(songs),
        'current': '0',
        'mode': 'normal',
        'shuffle': '0',
        'updated_index': '-1',
      });
      await _read(api, tag);
    case 'clear':
      await _call(api, tag, {
        'songs': '[]',
        'current': '0',
        'mode': 'normal',
        'shuffle': '0',
        'updated_index': '-1',
      });
      await _read(api, tag);
    default:
      print('未知 mode：$mode（可选 read / oracle / fill / clear）');
  }
  await api.logout(session: 'AudioStation');
  exit(0);
}
