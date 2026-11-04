// r403d 音频「歌词」**只读**探针（第四支）：DA52 的"服务端到底要多久"再用
// **没查过的曲目对**复核一次（避免第一支探针把 NAS 的联网缓存捂热导致误判）。
//
// 问题：r403c 实测 `searchLyrics(Demo Song, Demo Artist)` 要 **15.5–16.0 s**；
// 但真机上（修复版）点「Search lyrics online」时按钮 **< 2 s** 就恢复可用 ——
// 需要判：是"NAS 那边缓存了/热了就快"，还是"客户端根本没等"。
// 所以这里对**此前从未查过的两组**逐次计时（每组连打两次，第二次可看缓存效果）。
//
// 只读：`searchlyrics` / `getlyrics`；**不碰 `setlyrics`**。
//
// 运行：
//   set -a; . ~/.synhub-nas.env; set +a
//   dart run tool/probe_r403d_lyrics_latency_fresh.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

String _env(String primary, String legacy) {
  final v = Platform.environment[primary];
  if (v != null && v.isNotEmpty) return v;
  final l = Platform.environment[legacy];
  if (l != null && l.isNotEmpty) return l;
  stderr.writeln('缺环境变量 $primary（或 $legacy）');
  exit(2);
}

Future<void> main() async {
  final web = DsmWebApi(
    DirectTransport.url(
      _env('SYNO_NAS_URL', 'SYNO_URL'),
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await web.discover();
  await web.login(
    account: _env('SYNO_NAS_ACCOUNT', 'SYNO_ACCOUNT'),
    password: _env('SYNO_NAS_PASSWORD', 'SYNO_PASSWORD'),
    session: 'Chat',
  );
  print('[r403d] 登录成功（只读）');
  final as = AudioStationApi(web);

  const pairs = [
    ('Shape of My Heart', 'Backstreet Boys'),
    ('Just the Way You Are', 'Bruno Mars'),
    ('Pretty Boy', 'M2M'),
  ];
  for (final (title, artist) in pairs) {
    for (var i = 1; i <= 2; i++) {
      final sw = Stopwatch()..start();
      var len = -1;
      Object? raw;
      try {
        final s = await as.searchLyrics(title: title, artist: artist);
        len = s.length;
      } catch (e) {
        raw = e is DsmApiException ? e.raw : '$e';
      }
      sw.stop();
      print(
        '[r403d] searchLyrics(title=$title, artist=$artist) #$i '
        'elapsed=${sw.elapsedMilliseconds}ms len=$len raw=$raw',
      );
    }
  }
  print('[r403d] 完成（只读）');
}
