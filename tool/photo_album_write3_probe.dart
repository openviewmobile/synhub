// 相册删除形态取证（第三轮）：为什么 delete 回 OK 但相册还在列表里？
//
// 第二轮结论：create v4 / add_item v4 / set_cover v5 / set_name v5 都钉死了。
// 这一轮只查 delete：换 {id:[..]}、NormalAlbum/delete、以及删完用 Album/get 验尸。
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

  Future<void> show(String tag) async {
    final albums = await foto.normalAlbums();
    print(
      '$tag：${albums.map((a) => "${a.id}:${a.name}(n=${a.itemCount})").join(", ")}',
    );
  }

  await show('起始');

  // 建一个新的，专门拿来试删
  await tryCall('Browse.NormalAlbum', 'create', 4, {'name': 'probe-del'});
  await show('建完 probe-del');
  final albums = await foto.normalAlbums();
  final target = albums.firstWhere((a) => a.name == 'probe-del');
  print('target id=${target.id} raw=${target.id.runtimeType}');

  print('\nA) Album/delete {id:裸}');
  print('   ${await tryCall('Browse.Album', 'delete', 5, {'id': target.id})}');
  await show('   之后');

  if ((await foto.normalAlbums()).any((a) => a.id == target.id)) {
    print('\nB) Album/delete {id:裸int}');
    print(
      '   ${await tryCall('Browse.Album', 'delete', 5, {'id': int.tryParse(target.id) ?? target.id})}',
    );
    await show('   之后');
  }

  if ((await foto.normalAlbums()).any((a) => a.id == target.id)) {
    print('\nC) Album/delete {id:[int]}');
    print(
      '   ${await tryCall('Browse.Album', 'delete', 5, {
        'id': [int.tryParse(target.id) ?? 0],
      })}',
    );
    await show('   之后');
  }

  if ((await foto.normalAlbums()).any((a) => a.id == target.id)) {
    print('\nD) Album/delete {id:"[int]"} + version 1');
    for (final v in [1, 2, 3, 4, 5]) {
      print(
        '   v$v → ${await tryCall('Browse.Album', 'delete', v, {'id': '[${target.id}]'})}',
      );
    }
    await show('   之后');
  }

  if ((await foto.normalAlbums()).any((a) => a.id == target.id)) {
    print('\nE) NormalAlbum/delete / purge 之类');
    for (final m in ['delete', 'purge', 'remove']) {
      for (final v in [4, 3]) {
        print(
          '   NormalAlbum/$m v$v → ${await tryCall('Browse.NormalAlbum', m, v, {'id': target.id})}',
        );
      }
    }
    await show('   之后');
  }

  // 验尸：Album/get 还认不认这个 id
  print(
    '\nAlbum/get 验尸：${await tryCall('Browse.Album', 'get', 5, {'id': '[${target.id}]'})}',
  );

  // 再试一次带 additional 的 list，看是不是"已删待清理"状态
  final raw = await tryCall('Browse.NormalAlbum', 'list', 3, {
    'offset': '0',
    'limit': '50',
    'additional': FotoApi.js(['thumbnail']),
  });
  print(
    '\nNormalAlbum/list 原始：${raw.length > 300 ? raw.substring(0, 300) : raw}',
  );
}
