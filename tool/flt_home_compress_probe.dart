// ignore_for_file: avoid_print
// 只查 /home 下的压缩：换版本、换源类型、换虚拟/真实路径，找 105 的突破口。
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

  // 服务端广告的 Compress 版本区间
  print(
    '登录后 synotoken=${api.session?.synotoken} '
    'transport.synoToken=${api.transport.synoToken}',
  );
  final entry = api.apiTable?['SYNO.FileStation.Compress'];
  print(
    'Compress 版本区间: min=${entry?.minVersion} max=${entry?.maxVersion} '
    'path=${entry?.path}',
  );

  const dir = '/home/flt-hc-probe';
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
    params: {'folder_path': '/home', 'name': 'flt-hc-probe'},
  );
  final tmp = File('${Directory.systemTemp.path}/a.txt')
    ..writeAsStringSync('hi\n');
  await api.postMultipart(
    api.apiPath('SYNO.FileStation.Upload'),
    query: {'_sid': api.session!.sid},
    fields: {
      'api': 'SYNO.FileStation.Upload',
      'method': 'upload',
      'version': '3',
      'path': dir,
      'create_parents': 'false',
      'size': '${tmp.lengthSync()}',
      'overwrite': 'overwrite',
      'mtime': '${DateTime.now().millisecondsSinceEpoch}',
    },
    fileField: 'file',
    filePath: tmp.path,
    fileName: 'a.txt',
  );
  await api.call(
    'SYNO.FileStation.CreateFolder',
    'create',
    preferredVersion: 2,
    params: {'folder_path': dir, 'name': 'sub'},
  );

  // 真实路径
  String realDir = dir;
  try {
    final r = await api.call(
      'SYNO.FileStation.List',
      'list',
      preferredVersion: 2,
      params: {
        'folder_path': dir,
        'additional': FileEntryDto.encodePaths(['real_path']),
      },
    );
    realDir = '${(r['files'] as List).first['additional']['real_path']}';
    print('虚拟 $dir → 真实 $realDir');
  } catch (e) {
    print('取 real_path 失败: $e');
  }

  Future<void> attempt(
    String label,
    int version,
    String src,
    String dest,
  ) async {
    try {
      final r = await api.call(
        'SYNO.FileStation.Compress',
        'start',
        preferredVersion: version,
        params: {
          'path': FileEntryDto.encodePaths([src]),
          'dest_file_path': dest,
          'level': 'moderate',
          'mode': 'add',
          'format': 'zip',
        },
      );
      print('✅ $label → $r');
      try {
        await api.call(
          'SYNO.FileStation.Delete',
          'delete',
          preferredVersion: 2,
          params: {
            'path': FileEntryDto.encodePaths([dest]),
          },
        );
      } catch (_) {}
    } catch (e) {
      print('❌ $label → $e');
    }
  }

  // 1) 照抄 DSM 网页端的参数集（level=normal, mode=replace, 且一定带 password/codepage）
  for (final mode in const [
    'replace',
    'add',
    'update',
    'refresh',
    'freshen',
    'synchronize',
    '',
  ]) {
    for (final extra in const [true, false]) {
      final dest = '$dir/m-${mode.isEmpty ? 'none' : mode}-$extra.zip';
      try {
        final r = await api.call(
          'SYNO.FileStation.Compress',
          'start',
          preferredVersion: 3,
          params: {
            'path': FileEntryDto.encodePaths(['$dir/a.txt']),
            'dest_file_path': dest,
            'level': 'normal',
            'mode': mode,
            'format': 'zip',
            if (extra) 'password': '',
            if (extra) 'codepage': '',
          },
        );
        print('✅ mode=${mode.isEmpty ? "(不发)" : mode} extra=$extra → $r');
        try {
          await api.call(
            'SYNO.FileStation.Delete',
            'delete',
            preferredVersion: 2,
            params: {
              'path': FileEntryDto.encodePaths([dest]),
            },
          );
        } catch (_) {}
      } catch (e) {
        print('❌ mode=${mode.isEmpty ? "(不发)" : mode} extra=$extra → $e');
      }
    }
  }
  // 2) 源是文件夹
  await attempt('v3 文件夹→同目录', 3, '$dir/sub', '$dir/sub.zip');
  // 3) 源是父目录（压缩整个工作目录）
  await attempt('v3 目录自身→父目录', 3, dir, '/home/flt-hc-self.zip');
  // 4) 真实路径
  if (realDir != dir) {
    await attempt('v3 真实路径文件', 3, '$realDir/a.txt', '$realDir/real.zip');
  }
  // 6) 真实路径能不能列（/homes 是否可见）
  try {
    final r = await api.call(
      'SYNO.FileStation.List',
      'list',
      preferredVersion: 2,
      params: {'folder_path': realDir, 'limit': 5},
    );
    print('列真实路径 OK: total=${r['total']}');
  } catch (e) {
    print('列真实路径失败: $e');
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
    await api.call(
      'SYNO.FileStation.Delete',
      'delete',
      preferredVersion: 2,
      params: {
        'path': FileEntryDto.encodePaths(['/home/flt-hc-self.zip']),
      },
    );
  } catch (_) {}
  print('清理完成');
  api.transport.close();
  exit(0);
}
