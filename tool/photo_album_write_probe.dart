// 相册写操作取证：新建相册 / 加照片 / 改封面 / 改名 / 删相册。
//
// 形态依据 Synology Photos SPK（1.9.1-10928）自带 Web UI 的调用点
// （`/tmp/spk/export_SynologyPhotos/ui/react_bundle.js`）：
//   * `SYNO.Foto.Browse.NormalAlbum/create`   {name, item?}          → {album:{id,name}}
//   * `SYNO.Foto.Browse.NormalAlbum/add_item` {id, item}             → 可能带 error_list
//   * `SYNO.Foto.Browse.Album/set_cover`      {id, id_item}
//   * `SYNO.Foto.Browse.Album/set_name`       {id, name}
//   * `SYNO.Foto.Browse.Album/delete`         {id:[...]}
// 版本按 NAS 的 `SYNO.API.Info`（Album 1-5 / NormalAlbum 1-4）逐档试，看哪档回 103。
//
// 跑完清场：删掉探针相册。
// ignore_for_file: avoid_print
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'dart:io';

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

  Future<Object?> t(
    String apiId,
    String method,
    List<int> versions, [
    Map<String, dynamic> p = const {},
  ]) async {
    Object? last;
    for (final v in versions) {
      try {
        final r = await api.call(
          'SYNO.Foto.$apiId',
          method,
          preferredVersion: v,
          params: p,
        );
        print('     v$v → OK $r');
        return r;
      } catch (e) {
        print('     v$v → $e');
        last = e;
      }
    }
    return last;
  }

  final items = await foto.timeline(limit: 3);
  print(
    '时间轴拿到 ${items.length} 张；第一张 id=${items.isEmpty ? "-" : items.first.id}',
  );
  final itemId = items.isEmpty ? null : items.first.id;

  print('\n① 新建相册（NormalAlbum/create）—— 先试参数形态');
  print('   a) 只有 name（裸串）');
  await t(
    'Browse.NormalAlbum',
    'create',
    const [4, 3, 2, 1],
    {'name': 'probe-album'},
  );
  print('   b) name 走 Gson 引号');
  await t(
    'Browse.NormalAlbum',
    'create',
    const [4, 3, 2, 1],
    {'name': FotoApi.js('probe-album')},
  );
  print('   c) name（裸串）+ item 数字数组');
  await t(
    'Browse.NormalAlbum',
    'create',
    const [4, 3, 2, 1],
    {'name': 'probe-album', if (itemId != null) 'item': '[$itemId]'},
  );
  print('   d) name（裸串）+ item 字符串数组');
  await t(
    'Browse.NormalAlbum',
    'create',
    const [4, 3, 2, 1],
    {
      'name': 'probe-album',
      if (itemId != null) 'item': FotoApi.js([itemId]),
    },
  );

  // 找出刚建的相册 id
  var albums = await foto.normalAlbums();
  final probe = albums.where((a) => a.name == 'probe-album').toList();
  print('   列表里找到：${probe.map((a) => "${a.id}:${a.name}").join(", ")}');
  if (probe.isEmpty) {
    print('❌ 相册没建出来，后续跳过');
    return;
  }
  final albumId = probe.first.id;

  print('\n② 加照片（NormalAlbum/add_item）');
  print(
    '   ${await t('Browse.NormalAlbum', 'add_item', const [4, 3, 2, 1], {
      'id': albumId,
      if (itemId != null) 'item': FotoApi.js([itemId]),
    })}',
  );

  print('\n③ 改封面（Album/set_cover）');
  print(
    '   ${await t('Browse.Album', 'set_cover', const [5, 4, 3, 2, 1], {'id': albumId, if (itemId != null) 'id_item': itemId})}',
  );

  print('\n④ 改名（Album/set_name）');
  print(
    '   ${await t('Browse.Album', 'set_name', const [5, 4, 3, 2, 1], {'id': albumId, 'name': 'probe-album-2'})}',
  );
  albums = await foto.normalAlbums();
  print(
    '   列表：${albums.where((a) => a.id == albumId).map((a) => a.name).join(",")}',
  );

  print('\n⑤ 删相册（Album/delete）');
  print(
    '   ${await t('Browse.Album', 'delete', const [5, 4, 3, 2, 1], {
      'id': FotoApi.js([albumId]),
    })}',
  );
  albums = await foto.normalAlbums();
  print('   剩下：${albums.map((a) => a.name).join(", ")}');
}
