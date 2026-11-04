// ignore_for_file: avoid_print
// 专项探针：taskid 到底是"裸字符串"还是 JSON 数组串（stop / status）。
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

  const dir = '/home/flt-task-probe';
  try {
    await api.call(
      'SYNO.FileStation.Delete',
      'delete',
      preferredVersion: 2,
      params: {
        'path': FileEntryDto.encodePaths([dir]),
        'recursive': true,
      },
    );
  } catch (_) {}
  await api.call(
    'SYNO.FileStation.CreateFolder',
    'create',
    preferredVersion: 2,
    params: {'folder_path': '/home', 'name': 'flt-task-probe'},
  );

  Future<String?> startDirSize() async {
    try {
      final r = await api.call(
        'SYNO.FileStation.DirSize',
        'start',
        preferredVersion: 2,
        params: {
          'path': FileEntryDto.encodePaths([dir]),
        },
      );
      return '${r['taskid']}';
    } catch (e) {
      print('DirSize.start !! $e');
      return null;
    }
  }

  final t1 = await startDirSize();
  print('taskid=$t1');
  if (t1 != null) {
    for (final label in ['裸字符串', 'JSON 数组']) {
      try {
        final r = await api.call(
          'SYNO.FileStation.DirSize',
          'status',
          preferredVersion: 2,
          params: {
            'taskid': label == '裸字符串' ? t1 : FileEntryDto.encodePaths([t1]),
          },
        );
        print('status($label) → $r');
      } catch (e) {
        print('status($label) !! $e');
      }
    }
    for (final label in ['裸字符串', 'JSON 数组']) {
      try {
        final r = await api.call(
          'SYNO.FileStation.DirSize',
          'stop',
          preferredVersion: 2,
          params: {
            'taskid': label == '裸字符串' ? t1 : FileEntryDto.encodePaths([t1]),
          },
        );
        print('stop($label) → $r');
      } catch (e) {
        print('stop($label) !! $e');
      }
    }
  }

  // 任务中心里能看到吗
  try {
    final r = await api.call(
      'SYNO.FileStation.BackgroundTask',
      'list',
      preferredVersion: 3,
      params: {'offset': 0, 'limit': 20},
    );
    print(
      'BackgroundTask.list → ${r.toString().substring(0, r.toString().length > 400 ? 400 : r.toString().length)}',
    );
  } catch (e) {
    print('BackgroundTask.list !! $e');
  }

  try {
    await api.call(
      'SYNO.FileStation.Delete',
      'delete',
      preferredVersion: 2,
      params: {
        'path': FileEntryDto.encodePaths([dir]),
        'recursive': true,
      },
    );
    print('清理 OK');
  } catch (e) {
    print('清理失败 $e');
  }
  api.transport.close();
  exit(0);
}
