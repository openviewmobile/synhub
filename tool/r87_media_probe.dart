// r87 最小复现探针（**只读**）：登录真 NAS，打印
//   ① Audio Station 直传流 URL（音频那条 -1202 的入口）
//   ② /home/Video 里第一个 mp4 的 File Station 直链（视频那条的入口）
// 把这两条 URL 交给 `tool/r87_tls_repro.swift`（原生 AVFoundation/URLSession）
// 做"默认严格校验失败 / scoped 放宽成功"的对照。
//
//   SYNO_NAS_URL=https://nas.example.com:5001 SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/r87_media_probe.dart
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  if (url == null || account == null || password == null) {
    stderr.writeln('需要 SYNO_NAS_URL / SYNO_ACCOUNT / SYNO_PASSWORD');
    exit(2);
  }
  final web = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await web.discover();
  await web.login(account: account, password: password, session: 'Chat');

  final audio = AudioStationApi(web);
  final page = await audio.listSongs(limit: 1);
  if (page.items.isEmpty) {
    stderr.writeln('AUDIO none');
  } else {
    final song = page.items.first;
    stdout.writeln('AUDIO_ID ${song.id}');
    stdout.writeln('AUDIO_URL ${audio.streamUrl(song)}');
  }

  final fs = FileStationApi(web);
  final folder = await fs.listFolder(folderPath: '/home/Video', limit: 100);
  for (final e in folder.entries) {
    if (e.isDir) continue;
    final lower = e.name.toLowerCase();
    if (lower.endsWith('.mp4')) {
      stdout.writeln('VIDEO_NAME ${e.name}');
      stdout.writeln(
        'VIDEO_URL ${fs.downloadUrl(['/home/Video/${e.name}'], mode: 'open')}',
      );
      break;
    }
  }

  web.transport.close();
  exit(0);
}
