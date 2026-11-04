// ignore_for_file: avoid_print
// 普通用户 demo_user 到底能用哪些写操作（逐一实测返回码）。
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

  const dir = '/home/flt-perm-probe';
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

  Future<void> probe(
    String label,
    String apiName,
    String method,
    Map<String, dynamic> params, [
    int v = 2,
  ]) async {
    try {
      final r = await api.call(
        apiName,
        method,
        preferredVersion: v,
        params: params,
      );
      print('$label → OK $r');
    } catch (e) {
      print('$label → !! $e');
    }
  }

  await probe('CreateFolder', 'SYNO.FileStation.CreateFolder', 'create', {
    'folder_path': '/home',
    'name': 'flt-perm-probe',
  });
  final f = File('${Directory.systemTemp.path}/p.txt')..writeAsStringSync('x');
  final up = await api.postMultipart(
    api.apiPath('SYNO.FileStation.Upload'),
    query: {'_sid': api.session!.sid},
    fields: {
      'api': 'SYNO.FileStation.Upload',
      'method': 'upload',
      'version': '3',
      'path': dir,
      'create_parents': 'false',
      'size': '${f.lengthSync()}',
      'overwrite': 'overwrite',
      'mtime': '${DateTime.now().millisecondsSinceEpoch}',
    },
    fileField: 'file',
    filePath: f.path,
    fileName: 'p.txt',
  );
  print('Upload → ${up.contains('"success":true')}');

  await probe('Rename', 'SYNO.FileStation.Rename', 'rename', {
    'path': FileEntryDto.encodePaths(['$dir/p.txt']),
    'name': FileEntryDto.encodePaths(['q.txt']),
  });
  await probe('CopyMove.copy', 'SYNO.FileStation.CopyMove', 'start', {
    'path': FileEntryDto.encodePaths(['$dir/q.txt']),
    'dest_folder_path': dir,
    'remove_src': false,
    'overwrite': true,
  }, 3);
  await probe('CopyMove.move', 'SYNO.FileStation.CopyMove', 'start', {
    'path': FileEntryDto.encodePaths(['$dir/q.txt']),
    'dest_folder_path': '$dir/sub',
    'remove_src': true,
    'overwrite': true,
    'create_parents': true,
  }, 3);
  await probe('DirSize', 'SYNO.FileStation.DirSize', 'start', {
    'path': FileEntryDto.encodePaths([dir]),
  });
  await probe('Compress', 'SYNO.FileStation.Compress', 'start', {
    'path': FileEntryDto.encodePaths(['$dir/q.txt']),
    'dest_file_path': '$dir/a.zip',
    'level': 'moderate',
    'mode': 'add',
    'format': 'zip',
  }, 3);
  await probe('Extract(list)', 'SYNO.FileStation.Extract', 'list', {
    'file_path': '/home/Drive/x.zip',
    'offset': 0,
    'limit': 10,
  });
  await probe('MD5', 'SYNO.FileStation.MD5', 'start', {
    'path': FileEntryDto.encodePaths(['$dir/q.txt']),
  });
  await probe('Favorite.add', 'SYNO.FileStation.Favorite', 'add', {
    'path': dir,
    'name': 'probe',
  });
  await probe('Favorite.list', 'SYNO.FileStation.Favorite', 'list', {
    'offset': 0,
    'limit': 10,
    'status_filter': 'all',
  });
  await probe('Favorite.delete', 'SYNO.FileStation.Favorite', 'delete', {
    'path': FileEntryDto.encodePaths([dir]),
  });
  await probe('Sharing.list', 'SYNO.FileStation.Sharing', 'list', {
    'offset': 0,
    'limit': 10,
  }, 3);
  await probe('Delete', 'SYNO.FileStation.Delete', 'delete', {
    'path': FileEntryDto.encodePaths([dir]),
    'recursive': true,
  });
  api.transport.close();
  exit(0);
}
