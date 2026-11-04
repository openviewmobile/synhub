// ignore_for_file: avoid_print
// 专项探针：Extract.list 的真实形状 + Extract.start 的 codepage 行为。
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

  const dir = '/home/flt-extract-probe';
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
    params: {'folder_path': '/home', 'name': 'flt-extract-probe'},
  );

  final zip = File('/tmp/fltzip/plain.zip');
  final raw = await api.postMultipart(
    api.apiPath('SYNO.FileStation.Upload'),
    query: {'_sid': api.session!.sid},
    fields: {
      'api': 'SYNO.FileStation.Upload',
      'method': 'upload',
      'version': '3',
      'path': dir,
      'create_parents': 'false',
      'size': '${zip.lengthSync()}',
      'overwrite': 'overwrite',
      'mtime': '${DateTime.now().millisecondsSinceEpoch}',
    },
    fileField: 'file',
    filePath: zip.path,
    fileName: 'plain.zip',
  );
  print('上传 zip: ${raw.length > 90 ? raw.substring(0, 90) : raw}');

  // ① Extract.list 的真实形状
  try {
    final r = await api.call(
      'SYNO.FileStation.Extract',
      'list',
      preferredVersion: 2,
      params: {'file_path': '$dir/plain.zip', 'offset': 0, 'limit': 50},
    );
    print('Extract.list → $r');
  } catch (e) {
    print('Extract.list !! $e');
  }

  // ② Extract.start：codepage 各版本
  //    ⚠️ 目标目录**必须已存在**：不存在时服务端回 408（= 路径不存在），
  //    这个码不在"参数错"那一类里，很容易被误判成权限问题。
  for (final cp in const ['', 'utf8', 'chs', 'enu']) {
    final dest = '$dir/out-${cp.isEmpty ? "none" : cp}';
    await api.call(
      'SYNO.FileStation.CreateFolder',
      'create',
      preferredVersion: 2,
      params: {'folder_path': dir, 'name': 'out-${cp.isEmpty ? "none" : cp}'},
    );
    final params = <String, dynamic>{
      'file_path': '$dir/plain.zip',
      'dest_folder_path': dest,
      'overwrite': true,
      'keep_dir': true,
      'create_subfolder': false,
      if (cp.isNotEmpty) 'codepage': cp,
    };
    try {
      final r = await api.call(
        'SYNO.FileStation.Extract',
        'start',
        preferredVersion: 2,
        params: params,
      );
      print('Extract.start codepage=${cp.isEmpty ? "(不发)" : cp} → $r');
    } catch (e) {
      print('Extract.start codepage=${cp.isEmpty ? "(不发)" : cp} !! $e');
    }
  }

  await Future<void>.delayed(const Duration(seconds: 3));
  // ③ 各 codepage 解出来的文件名
  for (final cp in const ['none', 'utf8', 'chs', 'enu']) {
    try {
      final l = await api.call(
        'SYNO.FileStation.List',
        'list',
        preferredVersion: 2,
        params: {
          'folder_path': '$dir/out-$cp',
          'limit': 50,
          'additional': '["size"]',
        },
      );
      final names = ((l['files'] as List?) ?? const [])
          .map((e) => (e as Map)['name'])
          .toList();
      print('out-$cp 内容: $names');
    } catch (e) {
      print('out-$cp 打不开: $e');
    }
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
