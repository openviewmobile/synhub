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
  final before = await api.call(
    'SYNO.FileStation.BackgroundTask',
    'list',
    preferredVersion: 3,
    params: {'offset': 0, 'limit': 100},
  );
  print('清理前任务数=${before['total']}');
  try {
    await api.call(
      'SYNO.FileStation.BackgroundTask',
      'clear_finished',
      preferredVersion: 3,
      params: const {},
    );
    print('clear_finished OK');
  } catch (e) {
    print('clear_finished !! $e');
  }
  final after = await api.call(
    'SYNO.FileStation.BackgroundTask',
    'list',
    preferredVersion: 3,
    params: {'offset': 0, 'limit': 100},
  );
  print('清理后任务数=${after['total']}');
  api.transport.close();
  exit(0);
}
