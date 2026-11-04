// ignore_for_file: avoid_print
// 清理真机上以 flt- 开头的临时目录/文件（P0 测试残留）。
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
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

  final data = await api.call(
    'SYNO.FileStation.List',
    'list_share',
    preferredVersion: 2,
    params: {'additional': '[]'},
  );
  final shares = (data['shares'] as List).cast<Map>();
  final home = shares.firstWhere(
    (s) => s['name'] == 'home',
    orElse: () => shares.first,
  );
  final listing = await api.call(
    'SYNO.FileStation.List',
    'list',
    preferredVersion: 2,
    params: {'folder_path': home['path'], 'limit': 500, 'additional': '[]'},
  );
  final entries = ((listing['files'] as List?) ?? const []).cast<Map>();
  final junk = entries
      .where((e) => '${e['name']}'.startsWith('flt-'))
      .map((e) => '${e['path']}')
      .toList();
  print('待清理：$junk');
  for (final p in junk) {
    try {
      await api.call(
        'SYNO.FileStation.Delete',
        'delete',
        preferredVersion: 2,
        params: {
          'path': FileEntryDto.encodePaths([p]),
          'recursive': true,
        },
      );
      print('已删 $p');
    } catch (e) {
      print('删 $p 失败：$e');
    }
  }
  api.transport.close();
  exit(0);
}
