// 相册写操作取证（第二轮）：把 add_item / delete 的参数形态试出来。
//
// 第一轮结论（真机）：
//   * `Browse.NormalAlbum/create` **v4** `{name, item:"[int,...]"}` → `{album:{id,...}}`
//     （`item` 用**数字**数组；字符串数组 → 120）
//   * `Browse.Album/set_name` **v5** `{id:裸id, name}` → `{}`
//   * `Browse.Album/set_cover` 第一轮 804（照片还没进相册）
//
// 这一轮试 add_item / delete 的各种组合，最后把探针相册删干净。
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

  // 清掉第一轮留下的探针相册
  final existing = await foto.normalAlbums();
  for (final a in existing.where((a) => a.name.startsWith('probe-album'))) {
    await tryCall('Browse.Album', 'delete', 5, {'id': a.id});
  }
  var albums = await foto.normalAlbums();
  print('清场后相册：${albums.map((a) => "${a.id}:${a.name}").join(", ")}');

  final items = await foto.timeline(limit: 3);
  final ids = items
      .map((e) => int.tryParse(e.id) ?? -1)
      .where((e) => e > 0)
      .toList();
  print('时间轴 item ids = $ids');
  if (ids.isEmpty) return;
  final itemId = ids.first;

  // 建一个探针相册（v4 + 数字数组）
  await tryCall('Browse.NormalAlbum', 'create', 4, {'name': 'probe-album'});
  albums = await foto.normalAlbums();
  final album = albums.firstWhere((a) => a.name == 'probe-album');
  print('探针相册 id=${album.id}');

  print('\n② add_item 形态矩阵（相册 ${album.id}，照片 $itemId）');
  final variants = <String, Map<String, dynamic>>{
    'id=裸, item=int数组串': {'id': album.id, 'item': '[$itemId]'},
    'id=裸, item=裸': {'id': album.id, 'item': '$itemId'},
    'id=数组串, item=数组串': {'id': '[${album.id}]', 'item': '[$itemId]'},
    'id=裸, item=数组串, version=3': {'id': album.id, 'item': '[$itemId]'},
  };
  for (final e in variants.entries) {
    final v = e.key.contains('version=3') ? 3 : 4;
    print(
      '   ${e.key} → ${await tryCall('Browse.NormalAlbum', 'add_item', v, e.value)}',
    );
    final inAlbum = await foto.albumItems(album.id, limit: 5);
    print('      相册里现在 ${inAlbum.length} 张');
    if (inAlbum.isNotEmpty) break;
  }

  print('\n③ 改封面（照片已进相册）');
  for (final idForm in [album.id, '[${album.id}]']) {
    final r = await tryCall('Browse.Album', 'set_cover', 5, {
      'id': idForm,
      'id_item': '$itemId',
    });
    print('   id=$idForm → $r');
  }

  print('\n④ delete 形态矩阵');
  final made = <String>[];
  for (final e in {
    'id=裸': {'id': album.id},
    'id=裸数字': {'id': album.id},
    'id=数组串': {'id': '[${album.id}]'},
  }.entries) {
    // 每个形态先建一个自己的相册，避免第一个就删成功导致后面测不到
    if (made.isEmpty) {
      made.add(album.id);
    }
    print(
      '   ${e.key} → ${await tryCall('Browse.Album', 'delete', 5, e.value)}',
    );
  }
  albums = await foto.normalAlbums();
  print('   剩下：${albums.map((a) => "${a.id}:${a.name}").join(", ")}');

  // 彻底清场
  for (final a in (await foto.normalAlbums()).where(
    (a) => a.name.startsWith('probe-album'),
  )) {
    print(
      '   清 ${a.id} → ${await tryCall('Browse.Album', 'delete', 5, {'id': a.id})}',
    );
  }
  albums = await foto.normalAlbums();
  print('最终相册：${albums.map((a) => "${a.id}:${a.name}").join(", ")}');
}
