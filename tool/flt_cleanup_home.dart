// ignore_for_file: avoid_print
// 清掉本轮压缩/令牌探针在 /home 留下的测试产物（只删明确属于探针的）。
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

const _mine = [
  '/home/ck-a.zip',
  '/home/ck-b.zip',
  '/home/ck-c.zip',
  '/home/curl-a.zip',
  '/home/curl-b.zip',
  '/home/curl-c.zip',
  '/home/curl-q.zip',
  '/home/curl-token.zip',
  '/home/curl-none.zip',
  '/home/dart-header.zip',
  '/home/dart-query.zip',
  '/home/dart-none.zip',
  '/home/layer-test.zip',
  '/home/layer-test2.zip',
  '/home/diag.zip',
  '/home/flt-archive-probe.zip',
  '/home/flt-archive-probe',
  '/home/flt-hc-probe',
  '/home/flt-p0.zip',
  '/home/flt-p0-56570',
];

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

  final list = await api.call(
    'SYNO.FileStation.List',
    'list',
    preferredVersion: 2,
    params: {'folder_path': '/home', 'limit': 200, 'additional': '["size"]'},
  );
  final present = <String>{
    for (final f in (list['files'] as List? ?? []))
      '/home/${(f as Map)['name']}',
  };
  final targets = _mine.where(present.contains).toList();
  print('要清理 ${targets.length} 项: $targets');
  if (targets.isNotEmpty) {
    final r = await api.call(
      'SYNO.FileStation.Delete',
      'delete',
      preferredVersion: 2,
      params: {'path': '["${targets.join('","')}"]'},
    );
    print('删除成功=$r');
  }
  await api.call(
    'SYNO.FileStation.BackgroundTask',
    'clear_finished',
    preferredVersion: 3,
    params: const {},
  );

  final after = await api.call(
    'SYNO.FileStation.List',
    'list',
    preferredVersion: 2,
    params: {'folder_path': '/home', 'limit': 200},
  );
  print('清理后 /home:');
  for (final f in (after['files'] as List? ?? [])) {
    final m = f as Map;
    print('  ${m['isdir'] == true ? 'DIR ' : 'FILE'} ${m['name']}');
  }
  api.transport.close();
  exit(0);
}
