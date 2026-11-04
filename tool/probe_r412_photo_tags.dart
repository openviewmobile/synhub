// r412 相册「标签 / 人物」只读探针：把 NAS 对
// `SYNO.Foto[Team].Browse.GeneralTag/{list,count,get,suggest}` 与
// `SYNO.Foto[Team].Browse.Person/{list,count,get,suggest,list_face}`、
// `SYNO.Foto[Team].Browse.Item/{get_tag,list_with_filter}` 的**原始返回**逐条打出来。
//
// **本探针只发读方法**（list/count/get/suggest/list_face/get_tag/list_with_filter），
// 一个写动词都没有。
//
// 用法：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/probe_r412_photo_tags.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

String clip(Object? v, [int n = 500]) {
  final s = jsonEncode(v);
  return s.length > n ? '${s.substring(0, n)}…' : s;
}

Future<void> main() async {
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
  await api.login(account: account, password: password, session: 'Chat');

  final table = api.apiTable ?? const {};
  print('== 能力表 ==');
  for (final key in [
    'SYNO.Foto.Browse.GeneralTag',
    'SYNO.FotoTeam.Browse.GeneralTag',
    'SYNO.Foto.Browse.Person',
    'SYNO.FotoTeam.Browse.Person',
    'SYNO.Foto.Browse.Item',
    'SYNO.FotoTeam.Browse.Item',
    'SYNO.Foto.Setting.User',
  ]) {
    final e = table[key];
    print('$key → ${e == null ? "（无此 api）" : "v${e.minVersion}-${e.maxVersion}"}');
  }

  Future<void> call(
    String name,
    String method, {
    int? v,
    Map<String, dynamic> params = const {},
  }) async {
    final label = '$name/$method v=${v ?? "当前"} $params';
    try {
      final data = await api.call(
        name,
        method,
        preferredVersion: v ?? 1,
        params: params,
      );
      print('✔ $label → ${clip(data)}');
    } catch (e) {
      print('✘ $label → $e');
    }
  }

  for (final ns in ['SYNO.Foto', 'SYNO.FotoTeam']) {
    print('\n======== $ns （标签）========');
    final tag = '$ns.Browse.GeneralTag';
    await call(tag, 'count', v: 2);
    await call(tag, 'count', v: 1);
    await call(tag, 'list', v: 2, params: {'offset': 0, 'limit': 200});
    await call(tag, 'list', v: 1, params: {'offset': 0, 'limit': 200});
    // 官方 APK 的**逐字**调用形态（`ApiBrowseGeneralTag.API_VERSION = 1`，
    // `additional = json(["thumbnail"])`）—— 用来排除"我们少传了参数"。
    await call(tag, 'list', v: 1, params: {'offset': 0, 'limit': 500, 'additional': '["thumbnail"]'});
    await call(tag, 'list', v: 2, params: {'offset': 0, 'limit': 500, 'additional': '["thumbnail"]'});
    await call(tag, 'list', v: 1, params: {'offset': 0, 'limit': 500, 'additional': jsonEncode(['thumbnail'])});
    await call(tag, 'list', v: 1, params: {'offset': 0, 'limit': 20});
    await call(tag, 'list', v: 2, params: {'offset': 0, 'limit': 200, 'sort_by': 'name', 'sort_direction': 'asc'});
    await call(tag, 'get', v: 2, params: {'id': '[1]'});
    await call(tag, 'get', v: 2, params: {'id': '1'});
    await call(tag, 'suggest', v: 2, params: {'keyword': 'huihub', 'limit': 20});
    await call(tag, 'suggest', v: 2, params: {'keyword': 'huihubtag', 'limit': 20});
    await call(tag, 'suggest', v: 2, params: {'keyword': 'h', 'limit': 50});
    await call(tag, 'suggest', v: 2, params: {'keyword': '', 'limit': 50});
    await call(tag, 'suggest', v: 2, params: {'limit': 50});
    await call(tag, 'suggest', v: 2, params: {'keyword': 'zzz_none', 'limit': 20});

    print('\n======== $ns （人物 / 人脸）========');
    final person = '$ns.Browse.Person';
    await call(person, 'count', v: 1);
    await call(person, 'list', v: 1, params: {'offset': 0, 'limit': 100});
    await call(person, 'list', v: 1, params: {'offset': 0, 'limit': 100, 'show_hidden': true});
    await call(person, 'suggest', v: 3, params: {'keyword': 'a', 'limit': 20});
    await call(person, 'list_face', v: 1, params: {'id': '[1]'});
    await call(person, 'get', v: 1, params: {'id': '[1]'});

    print('\n======== $ns （条目 / 标签过滤）========');
    final item = '$ns.Browse.Item';
    await call(item, 'list_with_filter', v: 7, params: {'offset': 0, 'limit': 10, 'general_tag_id': '[1]'});
  }

  print('\n======== 相册个人设置（人脸开关）========');
  await call('SYNO.Foto.Setting.User', 'get');
  await call('SYNO.Foto.Setting.User', 'get', v: 2);

  print('\n======== suggest 枚举扫描 ========');
  await sweepSuggest();
}

// ---------------------------------------------------------------------------
// 追加（只读）：`suggest` 是不是**唯一的枚举途径**？逐前缀扫一遍 a-z0-9 与几个
// 可能的通配符，看这台 NAS 上到底有几个标签。全部是读方法。
Future<void> sweepSuggest() async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  final api = DsmWebApi(
    DirectTransport.url(base!, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account!, password: password!, session: 'Chat');
  final seen = <int, String>{};
  final keys = [
    for (var c = 0x61; c <= 0x7a; c++) String.fromCharCode(c),
    for (var c = 0x30; c <= 0x39; c++) String.fromCharCode(c),
    ' ', '%', '_', '*', 'a b', '.', '-',
  ];
  for (final k in keys) {
    try {
      final data = await api.call(
        'SYNO.Foto.Browse.GeneralTag',
        'suggest',
        preferredVersion: 2,
        params: {'keyword': k, 'limit': 100},
      );
      final list = (data['list'] as List?) ?? const [];
      for (final e in list) {
        final m = (e as Map).cast<String, dynamic>();
        seen[(m['id'] as num).toInt()] = '${m['name']}';
      }
      print('suggest(${jsonEncode(k)}) → ${clip(data, 200)}');
    } catch (e) {
      print('suggest(${jsonEncode(k)}) → 失败 $e');
    }
  }
  print('扫描到的标签集合 → ${jsonEncode(seen)}');
}
