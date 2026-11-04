// 相册「谁在 NAS 上」核对器：打印个人空间的相册（id / 名字 / 类型 / 张数）。
// 用途：App 里新建/改名/加照片/删相册之后，从服务端确认（两向验证）。
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
  final albums = await foto.normalAlbums();
  print('个人空间普通相册 ${albums.length} 个：');
  for (final a in albums) {
    final items = await foto.albumItems(a.id);
    print(
      '  • id=${a.id}  name=${a.name}  type=${a.type}  '
      '张数=${items.length}  itemCount=${a.itemCount}  '
      'cover=${a.cover?.cacheKey ?? "-"}',
    );
  }
}
