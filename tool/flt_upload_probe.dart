// ignore_for_file: avoid_print
// 专项探针：FileStation 上传为什么超时（真机 + 真 NAS）。
import 'dart:io';
import 'dart:typed_data';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
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
  final fs = FileStationApi(api);

  // 目标目录：/home 下建一个临时目录
  const dir = '/home/flt-upload-probe';
  try {
    await fs.deleteItems([dir]);
  } catch (_) {}
  await fs.createFolder(folderPath: '/home', name: 'flt-upload-probe');

  final bytes = Uint8List.fromList(
    List<int>.generate(8 * 1024, (i) => i & 0xff),
  );
  final tmp = File('${Directory.systemTemp.path}/flt-up.bin')
    ..writeAsBytesSync(bytes);

  for (final version in const [3, 2]) {
    final sw = Stopwatch()..start();
    try {
      final raw = await api.postMultipart(
        api.apiPath('SYNO.FileStation.Upload'),
        query: {
          'api': 'SYNO.FileStation.Upload',
          'version': '$version',
          'method': 'upload',
          '_sid': api.session!.sid,
          'path': dir,
          'create_parents': true,
          'overwrite': true,
        },
        fields: const {},
        fileField: 'file',
        filePath: tmp.path,
        fileName: 'flt-up-v$version.bin',
        onProgress: (a, b) => print('    progress $a/$b'),
      );
      print('--- v$version OK in ${sw.elapsedMilliseconds}ms raw=$raw');
    } catch (e) {
      print('--- v$version !! in ${sw.elapsedMilliseconds}ms: $e');
    }
  }

  // 用 API 层的封装再试一次
  try {
    final sw = Stopwatch()..start();
    final id = await fs.upload(
      folderPath: dir,
      filePath: tmp.path,
      fileName: 'flt-up-api.bin',
    );
    print('--- FileStationApi.upload OK in ${sw.elapsedMilliseconds}ms id=$id');
  } catch (e) {
    print('--- FileStationApi.upload !! $e');
  }

  final listing = await fs.listFolder(folderPath: dir, limit: 20);
  print(
    '--- 目录内容: ${listing.entries.map((e) => '${e.name}(${e.size})').toList()}',
  );

  try {
    await fs.deleteItems([dir]);
    print('--- 清理 OK');
  } catch (e) {
    print('--- 清理失败 $e');
  }
  api.transport.close();
  exit(0);
}
