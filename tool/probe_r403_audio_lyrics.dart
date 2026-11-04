// r403 音频「歌词」**只读**探针：把 `Lyrics.getlyrics` / `LyricsSearch.searchlyrics`
// 的服务端**原始回包**逐条读出来，给"歌词成功态"找一个真实存在的对象。
//
// 背景（r391 诚实留白）：真机上打开某首 mp3，`Lyrics` 区自动一次 + 手点 `Search lyrics`
// 一次都只得到 `No lyrics found for this song` ⇒ 当时只验到**空态**，成功态"补不了"。
// 本轮先问服务端：**到底哪首歌在 NAS 侧有歌词**（`docs/audio-api-live.md` §1 记过
// `getlyrics` 曾回"Sample lyric line one…"真实歌词）——有了对象，成功态才可能被真机复验。
//
// 只读：只调 `list` / `getlyrics` / `searchlyrics`（`getlyrics` 是**读**，不是写；
// **不碰 `setlyrics`**，仪器㉒：写动词前先钉死"现在连的是谁"）。
//
// ⚠️ 仪器76：本文件的 `dump()` **真的把 `version` 传给 `api.call`** 并把实际版本打进读数；
// 凡 `120`/`103` 一律先回看探针发了什么，别急着写缺陷。
//
// 运行（口令只从环境来，不许落库）：
//   set -a; . ~/.synhub-nas.env; set +a
//   dart run tool/probe_r403_audio_lyrics.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

String _env(String primary, String legacy) {
  final v = Platform.environment[primary];
  if (v != null && v.isNotEmpty) return v;
  final l = Platform.environment[legacy];
  if (l != null && l.isNotEmpty) return l;
  stderr.writeln('缺环境变量 $primary（或 $legacy）');
  exit(2);
}

String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

Future<void> dump(
  DsmWebApi api,
  String name,
  String method, {
  Map<String, dynamic> params = const {},
  int version = 1,
  String label = '',
}) async {
  final tag = '[$name/$method v$version${label.isEmpty ? '' : ' $label'}]';
  try {
    final data = await api.call(
      name,
      method,
      preferredVersion: version,
      params: params,
    );
    final s = jsonEncode(data);
    print('[r403]$tag len=${s.length} ${_clip(s, 700)}');
    return;
  } catch (e) {
    print('[r403]$tag ERROR $e');
    if (e is DsmApiException) {
      print('[r403]$tag   raw=${jsonEncode(e.raw)}');
    }
  }
}

/// 120 oracle：空参/半参调用会把"缺哪个参数"点名出来。
Future<void> oracle(
  DsmWebApi api,
  String name,
  String method, {
  int version = 1,
  Map<String, dynamic> params = const {},
}) async {
  try {
    final data = await api.call(
      name,
      method,
      preferredVersion: version,
      params: params,
    );
    print('[r403][oracle $name/$method v$version] OK ${_clip(jsonEncode(data), 500)}');
  } catch (e) {
    print('[r403][oracle $name/$method v$version] ERR $e');
    if (e is DsmApiException) {
      print('[r403][oracle $name/$method v$version]   raw=${jsonEncode(e.raw)}');
    }
  }
}

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      _env('SYNO_NAS_URL', 'SYNO_URL'),
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  // 会话名 = App 逐字用的那个；用别的会 402（仪器㉒）。
  await api.login(
    account: _env('SYNO_NAS_ACCOUNT', 'SYNO_ACCOUNT'),
    password: _env('SYNO_NAS_PASSWORD', 'SYNO_PASSWORD'),
    session: 'Chat',
  );
  print('[r403] 登录成功（本探针只读）');

  // ① AudioStation 自身版本（判"服务端有没有这个套件/版本"）
  await dump(api, 'SYNO.AudioStation.Info', 'getinfo', version: 6);

  // ② 曲库：哪首歌在 NAS 的库里（`Song/list` v3，root = data.songs）
  final songs = <Map<String, dynamic>>[];
  for (final lib in ['personal', 'shared']) {
    try {
      final data = await api.call(
        'SYNO.AudioStation.Song',
        'list',
        preferredVersion: 3,
        params: {
          'additional': 'song_tag,song_audio,song_rating',
          'offset': 0,
          'limit': 60,
          'library': lib,
        },
      );
      final list = (data['songs'] as List?)?.whereType<Map>().toList() ?? [];
      print('[r403][Song/list v3 library=$lib] total=${data['total']} '
          'songs=${list.length}');
      for (final s in list) {
        final m = Map<String, dynamic>.from(s);
        final id = m['id'];
        if (id == null) continue;
        songs.add(m);
        print('[r403]   song id=$id title="${m['title']}" '
            'artist="${m['artist']}" album="${m['album']}" '
            'path="${m['path']}"');
      }
    } catch (e) {
      print('[r403][Song/list v3 library=$lib] ERROR $e');
      if (e is DsmApiException) print('[r403]   raw=${jsonEncode(e.raw)}');
    }
  }

  // ③ 逐首读 `getlyrics`（**读**）：找出 NAS 侧真的有歌词的那些歌
  print('[r403] === Lyrics/getlyrics 逐首（v2，参数 {id}） ===');
  final withLyrics = <String, String>{};
  for (final s in songs.take(60)) {
    final id = '${s['id']}';
    String lyrics = '';
    try {
      final data = await api.call(
        'SYNO.AudioStation.Lyrics',
        'getlyrics',
        preferredVersion: 2,
        params: {'id': id},
      );
      lyrics = '${data['lyrics'] ?? ''}';
    } catch (e) {
      print('[r403][getlyrics v2 id=$id] ERROR $e');
      if (e is DsmApiException) print('[r403]   raw=${jsonEncode(e.raw)}');
      continue;
    }
    final oneLine = lyrics.replaceAll('\r', '').replaceAll('\n', ' | ');
    print('[r403][getlyrics v2 id=$id] len=${lyrics.length} '
        'title="${s['title']}" artist="${s['artist']}" :: ${_clip(oneLine, 160)}');
    if (lyrics.trim().isNotEmpty) {
      withLyrics[id] = lyrics;
    }
  }
  print('[r403] === 有歌词的歌：${withLyrics.length} / ${songs.length} ===');
  for (final e in withLyrics.entries) {
    print('[r403]   ✔ id=${e.key} len=${e.value.length}');
  }

  // ④ 联网搜歌词（`LyricsSearch.searchlyrics` v2）：
  //    ①先打参数 oracle（判必填到底要什么）；②再按 App 逐字参数打真歌。
  print('[r403] === LyricsSearch/searchlyrics v2 oracle ===');
  await oracle(api, 'SYNO.AudioStation.LyricsSearch', 'searchlyrics', version: 2);
  await oracle(
    api,
    'SYNO.AudioStation.LyricsSearch',
    'searchlyrics',
    version: 2,
    params: {'title': 'Demo Song'},
  );
  for (final s in songs.take(8)) {
    final title = '${s['title']}';
    final artist = '${s['artist']}';
    if (title.isEmpty || title == 'null') continue;
    await dump(
      api,
      'SYNO.AudioStation.LyricsSearch',
      'searchlyrics',
      version: 2,
      params: {
        'title': title,
        if (artist.isNotEmpty && artist != 'null') 'artist': artist,
        'limit': 1,
        'additional': 'full_lyrics',
      },
      label: 'title="$title" artist="$artist"',
    );
  }

  print('[r403] 完成（只读；未调用任何写动词）');
}
