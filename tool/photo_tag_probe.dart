// 相册标签现场核对器（只读 + 可选建标签）：把 NAS 对
// `SYNO.Foto.Browse.GeneralTag/{list,suggest,create}` 与
// `SYNO.Foto.Browse.Item/{get_tag}` 的**原始返回**打出来。
//
// 用途：离线测试只能钉住请求形态；现场报错/返回结构对不上时用它定位。
// 用法：
//   SYNO_NAS_URL=https://nas.example.com:5001 \
//   SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/photo_tag_probe.dart [新标签名]
//
// 注意：`GeneralTag` **没有删除接口**，带参数跑会在 NAS 上留下一个标签，
// 只在真机验收时用，跑完自己决定要不要留。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
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
  for (final key in [
    'SYNO.Foto.Browse.GeneralTag',
    'SYNO.FotoTeam.Browse.GeneralTag',
    'SYNO.Foto.Browse.Item',
    'SYNO.FotoTeam.Browse.Item',
  ]) {
    final e = table[key];
    print(
      '$key → '
      '${e == null ? "（该 NAS 没这个 api）" : "v${e.minVersion}-${e.maxVersion}"}',
    );
  }

  final foto = FotoApi(api);
  try {
    print('list(v当前) → ${jsonEncode(await foto.generalTags())}');
  } catch (e) {
    print('list 失败 → $e');
  }
  for (final v in [1, 2]) {
    try {
      final data = await api.call(
        'SYNO.Foto.Browse.GeneralTag',
        'list',
        preferredVersion: v,
      );
      print('list(v$v 原始) → ${jsonEncode(data)}');
    } catch (e) {
      print('list(v$v) 失败 → $e');
    }
  }

  // 跟 FotoApi.generalTags 完全一样的参数，看**原始返回**长什么样
  for (final v in [1, 2]) {
    try {
      final data = await api.call(
        'SYNO.Foto.Browse.GeneralTag',
        'list',
        preferredVersion: v,
        params: {'offset': '0', 'limit': '200'},
      );
      print('list(v$v, offset/limit 原始) → ${jsonEncode(data)}');
    } catch (e) {
      print('list(v$v, offset/limit) 失败 → $e');
    }
  }

  // 各种 list 变体 + suggest/get，看创建出来的 tag 到底藏哪
  for (final params in [
    {'offset': '0', 'limit': '200', 'sort_by': 'name', 'sort_direction': 'asc'},
    {'offset': '0', 'limit': '200', 'type': 'general'},
    {'keyword': 'huihub', 'limit': '20'},
  ]) {
    final method = params.containsKey('keyword') ? 'suggest' : 'list';
    try {
      final data = await api.call(
        'SYNO.Foto.Browse.GeneralTag',
        method,
        preferredVersion: 2,
        params: params,
      );
      print('$method($params) → ${jsonEncode(data)}');
    } catch (e) {
      print('$method($params) 失败 → $e');
    }
  }
  try {
    final data = await api.call(
      'SYNO.Foto.Browse.GeneralTag',
      'get',
      preferredVersion: 2,
      params: {'id': '[1]'},
    );
    print('get(id=[1]) → ${jsonEncode(data)}');
  } catch (e) {
    print('get(id=[1]) 失败 → $e');
  }

  final name = args.isEmpty ? null : args.first;
  if (name != null) {
    for (final v in [1, 2]) {
      try {
        final data = await api.call(
          'SYNO.Foto.Browse.GeneralTag',
          'create',
          preferredVersion: v,
          params: {'name': name},
        );
        print('create(v$v 原始) → ${jsonEncode(data)}');
        break;
      } catch (e) {
        print('create(v$v) 失败 → $e');
      }
    }
    try {
      print('list(建完) → ${jsonEncode(await foto.generalTags())}');
    } catch (e) {
      print('list(建完) 失败 → $e');
    }
  }
}
