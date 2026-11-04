// 相册参数取证：`Thumbnail/get` 的 size 形态、`Browse.Item/set_favorite` 的 id 形态。
//
// 背景：`FotoApi` 里有的参数用 `js()`（JSON 编码 → `"xl"`），有的直接拼（`[1]`）。
// 这两种写法**不能靠猜**，必须在真 NAS 上分别试，看服务端吃哪一个。
//
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/photo_param_probe.dart
//
// 只做读取 + 一次可回滚的收藏切换（收藏 → 立刻改回）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/data/foto_api.dart';

const _table = [
  'SYNO.Foto.Browse.Item',
  'SYNO.Foto.Thumbnail',
  'SYNO.Foto.Setting.User',
];

void main() async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
  );
  print('== API 表 ==');
  for (final k in _table) {
    print('  $k → ${api.apiTable?[k]}');
  }

  final foto = FotoApi(api);

  print('\n== 个人空间照片（Browse.Item/list v?）==');
  final list = await foto.timeline(limit: 5);
  print('  条目数 = ${list.length}');
  for (final it in list.take(5)) {
    print(
      '  id=${it.id} name=${it.filename} type=${it.type} '
      'fav=${it.isFavorite} cache=${it.thumb.cacheKey}',
    );
  }
  if (list.isEmpty) {
    print('个人空间没有照片 → 后面的写入取证跳过');
    exit(0);
  }
  final probe = list.first;

  print('\n== Thumbnail/get 的 size 三种写法 ==');
  for (final size in ['xl', '"xl"', '"sm"']) {
    final bytes = await _tryBytes(api, foto, probe, size);
    print('  size=$size → $bytes');
  }

  print('\n== set_favorite 的 id 两种写法（改完立刻改回）==');
  for (final form in ['[${probe.id}]', '["${probe.id}"]']) {
    try {
      final data = await api.call(
        'SYNO.Foto.Browse.Item',
        'set_favorite',
        preferredVersion: 7,
        params: {'id': form, 'favorite': 'true'},
      );
      print('  id=$form → 成功 $data');
      // 立刻改回
      await api.call(
        'SYNO.Foto.Browse.Item',
        'set_favorite',
        preferredVersion: 7,
        params: {'id': form, 'favorite': '${probe.isFavorite}'},
      );
      print('    已回滚到 favorite=${probe.isFavorite}');
    } on DsmApiException catch (e) {
      print('  id=$form → 失败 code=${e.code} $e');
    }
  }

  print('\n== Browse.Item/list 里 id 的类型（官方回什么就是什么）==');
  final raw = await api.call(
    'SYNO.Foto.Browse.Item',
    'list',
    preferredVersion: 7,
    params: {
      'offset': '0',
      'limit': '1',
      'additional': jsonEncode(const ['thumbnail']),
    },
  );
  final items = (raw['list'] as List?) ?? const [];
  if (items.isNotEmpty) {
    final first = (items.first as Map).cast<String, dynamic>();
    print('  id runtimeType = ${first['id'].runtimeType} (${first['id']})');
  }

  final me = await foto.setting();
  print('\n== Setting.User/get（决定共享空间是否显示）==');
  print(
    '  team_space_permission=${me.teamSpacePermission} '
    'group_unit=${me.timelineGroupUnit} sort=${me.itemSortBy}/${me.sortDirection}',
  );
  exit(0);
}

Future<String> _tryBytes(
  DsmWebApi api,
  FotoApi foto,
  dynamic item,
  String size,
) async {
  final url = api.authenticatedUrl(api.apiPath('SYNO.Foto.Thumbnail'), {
    'api': 'SYNO.Foto.Thumbnail',
    'version': '2',
    'method': 'get',
    'id': '${item.id}',
    'type': size.startsWith('"') ? '"item"' : 'item',
    'size': size,
    'cache_key': '"${item.thumb.cacheKey}"',
  });
  try {
    final bytes = await api.getBytes(url);
    return '${bytes.length} 字节（PNG=${bytes.length > 4 && bytes[1] == 0x50}）';
  } catch (e) {
    return 'HTTP/异常：$e';
  }
}
