// ignore_for_file: avoid_print
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
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
  final tasks = await api.call(
    'SYNO.FileStation.BackgroundTask',
    'list',
    preferredVersion: 3,
    params: {'offset': 0, 'limit': 20},
  );
  for (final t in (tasks['tasks'] as List? ?? [])) {
    final m = t as Map;
    print(
      '任务 ${m['api']} ${m['taskid']} finished=${m['finished']} '
      'progress=${m['progress']} path=${m['path']}',
    );
  }
  final list = await api.call(
    'SYNO.FileStation.List',
    'list',
    preferredVersion: 2,
    params: {'folder_path': '/home', 'limit': 100, 'additional': '["size"]'},
  );
  for (final f in (list['files'] as List? ?? [])) {
    final m = f as Map;
    print(
      '  ${m['isdir'] == true ? 'DIR ' : 'FILE'} ${m['name']} '
      '${m['additional']?['size'] ?? m['size']}',
    );
  }
  api.transport.close();
  exit(0);
}
