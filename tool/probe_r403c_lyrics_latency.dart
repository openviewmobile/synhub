// r403c 音频「歌词」**只读**探针（第三支）：用**App 自己的** `AudioStationApi`
// 走 App 自己的参数形态，带**逐次耗时**，判"真机上那句 `Failed to search lyrics online`
// 到底是 101（参数）还是超时（服务端联网慢）"。
//
// 背景读数：
//   * 第一支探针：`searchlyrics` 各种形态全 `101`（当时**从未发 artist**）；
//   * 第二支探针：`title` 单独 → `101`；`title + artist` → `200 {}`（**两个都必填**）；
//   * 真机点「Search lyrics online」：页面出现**另一份**（带时间轴的）歌词 —— 公开源
//     （lrclib）那一档拿到了东西；同时弹出 `Failed to search lyrics online`
//     = `asLyricsSearchFailed` ⇒ **服务端那一路抛异常了**（不是"空"⇒空会显示
//     `No lyrics found online either`）。所以要判：是 101 还是超时。
//
// 只读：`searchlyrics`（服务端只是"去查"）、`getlyrics`、`Song/getinfo`；**不碰 `setlyrics`**。
//
// 运行：
//   set -a; . ~/.synhub-nas.env; set +a
//   dart run tool/probe_r403c_lyrics_latency.dart
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

Future<void> timed(String label, Future<void> Function() body) async {
  final sw = Stopwatch()..start();
  try {
    await body();
  } catch (e) {
    print('[r403c]$label elapsed=${sw.elapsedMilliseconds}ms ERR $e');
    if (e is DsmApiException) print('[r403c]$label   raw=$e.raw');
    return;
  }
  print('[r403c]$label elapsed=${sw.elapsedMilliseconds}ms OK');
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
  print('[r403c] 登录成功（只读）');
  final as = AudioStationApi(web);

  // ① App 逐字形态：title + artist（真机这首歌的 tag.artist = Demo Artist）
  for (var i = 1; i <= 3; i++) {
    var len = -1;
    await timed('searchLyrics(title=Demo Song, artist=Demo Artist) #$i', () async {
      final s = await as.searchLyrics(title: 'Demo Song', artist: 'Demo Artist');
      len = s.length;
    });
    print('[r403c]   ↳ 回包 lyrics 长度 = $len');
  }

  // ② App 在**没有 artist** 时发的形态（`artist: null` ⇒ 参数里根本没有 artist）
  var len2 = -1;
  await timed('searchLyrics(title=Demo Song) 无 artist', () async {
    final s = await as.searchLyrics(title: 'Demo Song');
    len2 = s.length;
  });
  print('[r403c]   ↳ 回包 lyrics 长度 = $len2');

  // ③ 对照：服务端本地歌词（不联网），应很快且非空
  await timed('getLyrics(music_28045)', () async {
    final s = await as.getLyrics('music_28045');
    print('[r403c]   ↳ len=${s.length} head=${s.split('\r\n').take(3).join(' | ')}');
  });

  // ④ 服务端联网搜索对**别的歌**的表现（判"是不是只有英文歌查不到"）
  for (final t in const ['月亮代表我的心', 'Love Story']) {
    await timed('searchLyrics(title=$t, artist=Taylor Swift)', () async {
      final s = await as.searchLyrics(title: t, artist: 'Taylor Swift');
      print('[r403c]   ↳ len=${s.length}');
    });
  }

  print('[r403c] 完成（只读）');
}
