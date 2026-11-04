// ignore_for_file: avoid_print
// 探针：压缩/解压在哪些位置可用（判断 105 是"全局应用权限"还是"某个共享的自定义权限"）。
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

  final shares = await api.call(
    'SYNO.FileStation.List',
    'list_share',
    preferredVersion: 2,
    params: {'offset': 0, 'limit': 50},
  );
  final dirs = <String>[
    '/home',
    for (final f in (shares['shares'] as List? ?? const []))
      '${(f as Map)['path']}',
  ];
  print('候选位置: $dirs');

  for (final dir in dirs) {
    // 1. 自己能不能写
    String writable;
    try {
      final r = await api.call(
        'SYNO.FileStation.CheckPermission',
        'write',
        preferredVersion: 3,
        params: {'path': dir, 'filename': 'flt-priv-probe.tmp'},
      );
      writable = '${r['is_writable']}';
    } catch (e) {
      writable = '? $e';
    }

    // 2. 造一个目录 + 文件，试压缩
    final probeDir = '$dir/flt-priv-probe';
    final name = 'flt-priv-probe';
    var compress = '-';
    var extract = '-';
    try {
      await api.call(
        'SYNO.FileStation.Delete',
        'delete',
        preferredVersion: 2,
        params: {
          'path': FileEntryDto.encodePaths([probeDir]),
          'recursive': true,
        },
      );
    } catch (_) {}
    try {
      await api.call(
        'SYNO.FileStation.CreateFolder',
        'create',
        preferredVersion: 2,
        params: {'folder_path': dir, 'name': name},
      );
      final tmp = File('${Directory.systemTemp.path}/p.txt')
        ..writeAsStringSync('x\n');
      await api.postMultipart(
        api.apiPath('SYNO.FileStation.Upload'),
        query: {'_sid': api.session!.sid},
        fields: {
          'api': 'SYNO.FileStation.Upload',
          'method': 'upload',
          'version': '3',
          'path': probeDir,
          'create_parents': 'false',
          'size': '${tmp.lengthSync()}',
          'overwrite': 'overwrite',
          'mtime': '${DateTime.now().millisecondsSinceEpoch}',
        },
        fileField: 'file',
        filePath: tmp.path,
        fileName: 'p.txt',
      );
      try {
        final r = await api.call(
          'SYNO.FileStation.Compress',
          'start',
          preferredVersion: 3,
          params: {
            'path': FileEntryDto.encodePaths(['$probeDir/p.txt']),
            'dest_file_path': '$probeDir/p.zip',
            'level': 'moderate',
            'mode': 'add',
            'format': 'zip',
          },
        );
        compress = 'OK ${r['taskid']}';
      } catch (e) {
        compress = '!! $e';
      }
      try {
        await api.call(
          'SYNO.FileStation.Extract',
          'start',
          preferredVersion: 2,
          params: {
            'file_path': '$probeDir/p.zip',
            'dest_folder_path': probeDir,
          },
        );
        extract = 'OK';
      } catch (e) {
        extract = '!! $e';
      }
    } catch (e) {
      compress = 'setup failed: $e';
    }
    try {
      await api.call(
        'SYNO.FileStation.Delete',
        'delete',
        preferredVersion: 2,
        params: {
          'path': FileEntryDto.encodePaths([probeDir]),
          'recursive': true,
        },
      );
    } catch (_) {}
    print('$dir | writable=$writable | compress=$compress | extract=$extract');
  }
  api.transport.close();
  exit(0);
}
