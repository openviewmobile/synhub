// 相册（Synology Photos 1.9.1-10928）只读探针：能力表 + 首页形状。
//
// 运行：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/foto_probe.dart
//
// 个人空间 = `SYNO.Foto.*`，共享空间 = `SYNO.FotoTeam.*`（官方 2.4.0-644 的
// `ApiName.kt` 里两个前缀就是这么分的）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> dump(
  DsmWebApi api,
  String name,
  String method, {
  Map<String, dynamic> params = const {},
  int? version,
}) async {
  try {
    final data = await api.call(name, method, params: params);
    final s = jsonEncode(data);
    print(
      '✔ $name/$method → ${s.length > 700 ? '${s.substring(0, 700)}…' : s}',
    );
  } catch (e) {
    print('✘ $name/$method → $e');
  }
}

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  final table = await api.discover();
  final foto = table.keys.where((k) => k.contains('Foto')).toList()..sort();
  print('== 相册相关 API 共 ${foto.length} 个 ==');
  for (final k in foto) {
    final v = table[k];
    print('  $k v${v?.minVersion}-${v?.maxVersion}');
  }
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'synofoto',
  );

  print('\n== 个人空间 ==');
  await dump(
    api,
    'SYNO.Foto.Browse.Item',
    'list',
    params: {
      'offset': 0,
      'limit': 5,
      'sort_by': 'takentime',
      'sort_direction': 'desc',
      'additional': '["thumbnail"]',
    },
  );
  await dump(
    api,
    'SYNO.Foto.Browse.Folder',
    'list',
    params: {'id': 0, 'offset': 0, 'limit': 5, 'additional': '["thumbnail"]'},
  );
  await dump(api, 'SYNO.Foto.Setting.User', 'get');
  await dump(
    api,
    'SYNO.Foto.Browse.Timeline',
    'list',
    params: {'offset': 0, 'limit': 5, 'additional': '["thumbnail"]'},
  );
  await dump(
    api,
    'SYNO.Foto.Browse.Album',
    'list',
    params: {'offset': 0, 'limit': 5},
  );
  await dump(
    api,
    'SYNO.Foto.Browse.NormalAlbum',
    'list',
    params: {'offset': 0, 'limit': 5},
  );
  await dump(
    api,
    'SYNO.Foto.Browse.Folder',
    'list',
    params: {'id': 0, 'offset': 0, 'limit': 5},
  );
  await dump(
    api,
    'SYNO.Foto.Browse.Person',
    'list',
    params: {'offset': 0, 'limit': 5},
  );
  await dump(
    api,
    'SYNO.Foto.Browse.GeneralTag',
    'list',
    params: {'offset': 0, 'limit': 5},
  );
  await dump(
    api,
    'SYNO.Foto.Browse.Item',
    'list',
    params: {'offset': 0, 'limit': 3, 'additional': '["thumbnail"]'},
  );

  print('\n== 共享空间 ==');
  await dump(
    api,
    'SYNO.FotoTeam.Browse.Timeline',
    'list',
    params: {'offset': 0, 'limit': 5, 'additional': '["thumbnail"]'},
  );
  await dump(
    api,
    'SYNO.FotoTeam.Browse.Album',
    'list',
    params: {'offset': 0, 'limit': 5},
  );
  await dump(
    api,
    'SYNO.FotoTeam.Browse.Folder',
    'list',
    params: {'id': 0, 'offset': 0, 'limit': 5},
  );

  print('\n== 缩略图 / 原图 URL（照抄官方 ConnectionManager 的拼接）==');
  final items = await api.call(
    'SYNO.Foto.Browse.Item',
    'list',
    params: {'offset': 0, 'limit': 2, 'additional': '["thumbnail"]'},
  );
  final list = (items['list'] as List?) ?? const [];
  if (list.isEmpty) {
    print('（个人空间没有照片，跳过）');
  } else {
    final first = Map<String, dynamic>.from(list.first as Map);
    final id = first['id'];
    final thumb = Map<String, dynamic>.from(
      ((first['additional'] as Map?)?['thumbnail'] as Map?) ?? {},
    );
    final cacheKey = '${thumb['cache_key']}';
    // 官方拼法：type/size/cache_key 都过 Gson（带引号），id 裸着
    final thumbUrl = api.authenticatedUrl(api.apiPath('SYNO.Foto.Thumbnail'), {
      'api': 'SYNO.Foto.Thumbnail',
      'version': '1',
      'method': 'get',
      'id': '$id',
      'type': jsonEncode('item'),
      'size': jsonEncode('sm'),
      'cache_key': jsonEncode(cacheKey),
    });
    try {
      final bytes = await api.getBytes(thumbUrl);
      print('缩略图 sm ${bytes.length} 字节 头部=${bytes.take(4).toList()}');
    } catch (e) {
      print('缩略图失败：$e');
    }
    final url = api.authenticatedUrl(api.apiPath('SYNO.Foto.Download'), {
      'api': 'SYNO.Foto.Download',
      'version': '1',
      'method': 'download',
      'id': jsonEncode(['$id']),
    });
    try {
      final bytes = await api.getBytes(url);
      print(
        '原图 ${first['filename']} ${bytes.length} 字节（filesize='
        '${first['filesize']}）',
      );
    } catch (e) {
      print('原图失败：$e');
    }
  }

  api.transport.close();
  exit(0);
}
