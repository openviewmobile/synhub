// ignore_for_file: avoid_print
// 真 NAS **只读**媒体清单探针（第 259 轮）。
//
// 目的：复现用户报的"从文件打开视频无法播放 / 音频一直无法播放"时，
// 先弄清**到底有哪些文件、什么扩展名**（格式清单是按扩展名判的）。
// 只发 `SYNO.FileStation.List:list`，**零变更动词**。
//
// 用法：
//   set -a; . /tmp/nas_cred.env; set +a
//   SYNO_NAS_URL=https://nas.example.com:5001 dart run tool/nas_find_media.dart
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const List<String> kRoots = ['/home'];

const Set<String> kVideo = {
  'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv', 'ts', 'm4v', '3gp', 'mpg',
  'mpeg', 'wmv', 'rm', 'rmvb', 'vob', 'ogv', 'm2ts', 'divx', 'asf',
};
const Set<String> kAudio = {
  'mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'wma', 'ape', 'wv',
  'dsf', 'dff', 'm4b', 'aiff', 'mid', 'midi', 'amr',
};

String _ext(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0) return '';
  return name.substring(i + 1).toLowerCase();
}

Future<void> main() async {
  final web = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await web.discover();
  await web.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'FileStation',
  );
  final fs = FileStationApi(web);
  final videos = <(String, int)>[];
  final audios = <(String, int)>[];
  final dirs = <String>[...kRoots];
  var visited = 0;
  while (dirs.isNotEmpty && visited < 300) {
    final dir = dirs.removeAt(0);
    visited++;
    FileListResult res;
    try {
      res = await fs.listFolder(folderPath: dir);
    } catch (e) {
      print('  跳过 $dir（${'$e'.split('\n').first}）');
      continue;
    }
    for (final f in res.entries) {
      final p = f.path;
      if (f.isDir) {
        // 不进回收站、不进 Synology 内部目录
        if (p.contains('#recycle') || p.contains('/@')) continue;
        if (dirs.length < 200) dirs.add(p);
      } else {
        final e = _ext(f.name);
        if (kVideo.contains(e)) videos.add((p, f.size ?? 0));
        if (kAudio.contains(e)) audios.add((p, f.size ?? 0));
      }
    }
  }
  print('\n扫描目录 $visited 个');
  print('\n===== 视频 ${videos.length} 个');
  for (final (p, s) in videos) {
    print('   ${(s / 1048576).toStringAsFixed(1)} MB  $p');
  }
  print('\n===== 音频 ${audios.length} 个');
  for (final (p, s) in audios.take(40)) {
    print('   ${(s / 1048576).toStringAsFixed(1)} MB  $p');
  }
  if (audios.length > 40) print('   …还有 ${audios.length - 40} 个');
  print('\n完成（全程只读）。');
}
