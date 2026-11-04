// r401 只读探针：`SYNO.AudioStation.Radio.list` 的**逐字原始回包** —— 专查
// 「一个容器页里到底混不混 `type:"container"` 的行」。
//
// 为什么要查：`audio_radio_page.dart` 的写动词行号是这么算的 ——
//   `items.where((r) => !r.isContainer).indexWhere(...)`
// 而**服务端的行号**是"该 container 下所有行（含 container 行）的下标"。
// 两者**只在"该页没有 container 行"时才相等**。若某页混了 container 行，
// 那么在这个页面点第 k 行的"删除"，删掉的会是**服务端第 k 行**（可能是另一条）。
// ⇒ 这就是 DA47（错容器）的邻接形态：**错行号**。
//
// 只读：登录 + `Radio.list`（root / SHOUTcast / 各 genre / UserDefined / Favorite）。
// **不**调用 add/updateradios/search 任何写方法。
//
// 运行：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/probe_r401_radio_mix.dart [tag]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<Map<String, dynamic>> _list(
  DsmWebApi api,
  String? container, {
  int offset = 0,
  int limit = -1,
}) async {
  final params = <String, dynamic>{'offset': '$offset', 'limit': '$limit'};
  if (container != null) params['container'] = container;
  final raw = await api.call(
    'SYNO.AudioStation.Radio',
    'list',
    preferredVersion: 2,
    params: params,
  );
  return raw;
}

Future<void> main(List<String> args) async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'] ??
      Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'] ??
      Platform.environment['SYNO_PASSWORD'];
  final tag = args.isEmpty ? 'r401' : args.first;
  if (base == null || account == null || password == null) {
    print('需要 SYNO_NAS_URL / SYNO_NAS_ACCOUNT(+SYNO_ACCOUNT) / SYNO_NAS_PASSWORD(+SYNO_PASSWORD)');
    exit(2);
  }
  final api = DsmWebApi(
    DirectTransport.url(base, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');

  // ① root：拿容器清单（含 SHOUTcast 分类叶子的 id）
  final root = await _list(api, null);
  final rootRows = (root['radios'] as List?) ?? const [];
  print('[$tag][root] total=${root['total']} rows=${rootRows.length}');
  for (var i = 0; i < rootRows.length; i++) {
    print('[$tag][root] row[$i]=${jsonEncode(rootRows[i])}');
  }

  // ② 逐个容器：统计 container / station 行数，并打印前若干行
  final containers = <String?>[null, 'SHOUTcast'];
  for (final r in rootRows) {
    if (r is Map && r['type'] == 'container' && r['id'] is String) {
      final id = r['id'] as String;
      if (id != 'SHOUTcast' && id != 'UserDefined' && id != 'Favorite') {
        containers.add(id);
      }
    }
  }
  // SHOUTcast 分类叶子（root 只给 3 个容器，叶子 id 形如 `SHOUTcast_genre_<名>`）
  containers.addAll(const [
    'SHOUTcast_genre_Alternative',
    'SHOUTcast_genre_Classical',
    'SHOUTcast_genre_News',
    'SHOUTcast_genre_Talk',
    'UserDefined',
    'Favorite',
  ]);

  for (final c in containers) {
    final label = c ?? 'root';
    try {
      final raw = await _list(api, c);
      final rows = (raw['radios'] as List?) ?? const [];
      var nContainer = 0;
      var nStation = 0;
      var nOther = 0;
      final kinds = <String>[];
      for (final r in rows) {
        final type = (r is Map ? r['type'] : null)?.toString() ?? '';
        if (type == 'container') {
          nContainer++;
        } else if (type.isEmpty) {
          nOther++;
        } else {
          nStation++;
        }
        kinds.add(type.isEmpty ? '(空type)' : type);
      }
      final sample = rows.length > 3 ? rows.sublist(0, 3) : rows;
      print(
        '[$tag][$label] total=${raw['total']} rows=${rows.length} '
        'container=$nContainer station=$nStation 其它type=$nOther '
        'kinds=${kinds.take(8).join("|")}',
      );
      for (var i = 0; i < sample.length; i++) {
        print('[$tag][$label] row[$i]=${jsonEncode(sample[i])}');
      }
      if (rows.isEmpty && c != null) {
        print('[$tag][$label] raw=${jsonEncode(raw)}');
      }
    } catch (err) {
      print('[$tag][$label] ✘ ${err.runtimeType}: $err');
    }
  }

  // ③ 分页语义：在 UserDefined 上用 offset/limit 逐步取，看服务端行号的语义
  for (final probe in const [
    [0, 1],
    [1, 1],
    [0, 2],
  ]) {
    try {
      final raw = await _list(api, 'UserDefined',
          offset: probe[0], limit: probe[1]);
      final rows = (raw['radios'] as List?) ?? const [];
      print(
        '[$tag][UD offset=${probe[0]} limit=${probe[1]}] '
        'total=${raw['total']} rows=${rows.length} '
        'items=${jsonEncode(rows)}',
      );
    } catch (err) {
      print('[$tag][UD offset=${probe[0]} limit=${probe[1]}] ✘ $err');
    }
  }

  await api.logout(session: 'AudioStation');
  exit(0);
}
