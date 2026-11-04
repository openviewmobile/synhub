// 相册写操作取证（第四轮）：`NormalAlbum/delete_item`（从相册移除照片）+ 清场。
//
// 已钉死的形态（真机，NAS 版本：Album 1-5 / NormalAlbum 1-4）：
//   create     v4 {name, item:"[int]"}      → {album:{id,…}, error_list}
//   add_item   v4 {id:裸, item:"[int]"}     → {error_list}
//   set_cover  v5 {id:裸, id_item:裸}       → {}
//   set_name   v5 {id:裸, name}             → {}
//   delete     v5 {id:"[int]"}              → {}   ← **必须数组串**，裸 id 静默无效
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'FileStation',
  );
  final foto = FotoApi(api);

  Future<String> tryCall(
    String apiId,
    String method,
    int v,
    Map<String, dynamic> p,
  ) async {
    try {
      final r = await api.call(
        'SYNO.Foto.$apiId',
        method,
        preferredVersion: v,
        params: p,
      );
      return 'OK $r';
    } catch (e) {
      return '$e';
    }
  }

  final items = await foto.timeline(limit: 3);
  final itemIds = items
      .map((e) => int.tryParse(e.id) ?? -1)
      .where((e) => e > 0)
      .toList();
  print('照片：$itemIds');

  // 建一个干净的探针相册 + 两张照片
  await tryCall('Browse.NormalAlbum', 'create', 4, {
    'name': 'probe-delitem',
    'item': '[${itemIds.join(",")}]',
  });
  final album = (await foto.normalAlbums()).firstWhere(
    (a) => a.name == 'probe-delitem',
  );
  print(
    '相册 ${album.id}，先看里面：'
    '${(await foto.albumItems(album.id)).map((e) => e.id).join(",")}',
  );

  print('\n① delete_item 形态矩阵（移除 ${itemIds.first}）');
  for (final e in {
    'id=裸, item=int数组串': {'id': album.id, 'item': '[${itemIds.first}]'},
    'id=裸, item=裸': {'id': album.id, 'item': '${itemIds.first}'},
    'id=数组串, item=数组串': {'id': '[${album.id}]', 'item': '[${itemIds.first}]'},
  }.entries) {
    final before = (await foto.albumItems(album.id)).length;
    final r = await tryCall('Browse.NormalAlbum', 'delete_item', 4, e.value);
    final after = (await foto.albumItems(album.id)).length;
    print('   ${e.key} → $r（$before 张 → $after 张）');
    if (after < before) break;
  }

  print('\n② 清场（delete 必须数组串）');
  for (final a in await foto.normalAlbums()) {
    print(
      '   ${a.id}:${a.name} → ${await tryCall('Browse.Album', 'delete', 5, {'id': '[${a.id}]'})}',
    );
  }
  print(
    '最终相册：${(await foto.normalAlbums()).map((a) => "${a.id}:${a.name}").join(", ")}',
  );
}
