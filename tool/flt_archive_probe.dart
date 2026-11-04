// ignore_for_file: avoid_print
// 专项探针：Compress.start / Extract.start 到底要哪些参数、取什么值。
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

  const dir = '/home/flt-archive-probe';
  const file = '$dir/a.txt';
  // 准备
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
    params: {'folder_path': '/home', 'name': 'flt-archive-probe'},
  );
  final tmp = File('${Directory.systemTemp.path}/a.txt')
    ..writeAsStringSync('hello archive probe\n');
  final raw = await api.postMultipart(
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
  print('上传: ${raw.substring(0, raw.length > 120 ? 120 : raw.length)}');

  Future<void> tryCompress(String level, String mode, String format) async {
    final dest = '$dir/p-$level-$mode-$format.zip';
    try {
      final r = await api.call(
        'SYNO.FileStation.Compress',
        'start',
        preferredVersion: 3,
        params: {
          'path': FileEntryDto.encodePaths([file]),
          'dest_file_path': dest,
          'level': level,
          'mode': mode,
          'format': format,
        },
      );
      print('compress level=$level mode=$mode format=$format → OK $r');
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
      print('compress level=$level mode=$mode format=$format → !! $e');
    }
  }

  for (final level in const [
    'moderate',
    'normal',
    'best',
    'fastest',
    'store',
  ]) {
    await tryCompress(level, 'add', 'zip');
  }
  for (final mode in const ['update', 'refresh']) {
    await tryCompress('moderate', mode, 'zip');
  }
  for (final format in const ['7z', 'tar', 'zip']) {
    await tryCompress('moderate', 'add', format);
  }

  // 先造一个确定的 zip（用刚才成功的参数）
  var zip = '';
  for (final level in const [
    'moderate',
    'normal',
    'best',
    'fastest',
    'store',
  ]) {
    try {
      final dest = '$dir/ok-$level.zip';
      await api.call(
        'SYNO.FileStation.Compress',
        'start',
        preferredVersion: 3,
        params: {
          'path': FileEntryDto.encodePaths([file]),
          'dest_file_path': dest,
          'level': level,
          'mode': 'add',
          'format': 'zip',
        },
      );
      zip = dest;
      print('用于解压的 zip: $dest (level=$level)');
      break;
    } catch (_) {}
  }
  if (zip.isEmpty) {
    print('没有成功的压缩参数，停止');
    api.transport.close();
    exit(0);
  }
  await Future<void>.delayed(const Duration(seconds: 2));

  for (final codepage in const ['enu', 'chs', 'cht', 'utf-8', '']) {
    try {
      final r = await api.call(
        'SYNO.FileStation.Extract',
        'start',
        preferredVersion: 2,
        params: {
          'file_path': zip,
          'dest_folder_path':
              '$dir/out-${codepage.isEmpty ? "none" : codepage}',
          'overwrite': true,
          'keep_dir': true,
          'create_subfolder': true,
          if (codepage.isNotEmpty) 'codepage': codepage,
        },
      );
      print('extract codepage=${codepage.isEmpty ? "(不发)" : codepage} → OK $r');
    } catch (e) {
      print('extract codepage=${codepage.isEmpty ? "(不发)" : codepage} → !! $e');
    }
  }

  // 归档内容清单
  try {
    final r = await api.call(
      'SYNO.FileStation.Extract',
      'list',
      preferredVersion: 2,
      params: {'file_path': zip, 'offset': 0, 'limit': 50},
    );
    print(
      'Extract.list = ${r.toString().substring(0, r.toString().length > 300 ? 300 : r.toString().length)}',
    );
  } catch (e) {
    print('Extract.list !! $e');
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
