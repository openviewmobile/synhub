// r403b 音频「歌词」**只读**探针（第二支）：把 `LyricsSearch.searchlyrics`
// 的参数形态逐个真机打一遍 —— 第一支探针里**所有**形态都回 `101`（badRequest），
// 而第一支**从未发过带 `artist` 的请求**（这些歌的 `artist` 字段是 null，
// 我的循环按"非空才发"处理）⇒ 先用**值矩阵**判"到底哪个参数是必需的"
// （仪器77：服务端说"缺参数"未必用 120 表达，`101` 也可能是参数问题）。
//
// 只读：`list` / `getlyrics` / `searchlyrics` / `getinfo`；**不碰 `setlyrics`**。
//
// 运行（口令只从环境来，不许落库）：
//   set -a; . ~/.synhub-nas.env; set +a
//   dart run tool/probe_r403b_lyrics_search_shapes.dart
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

/// 一条读数 = 一次真实调用；**实际发出的版本**打进读数（仪器76）。
Future<void> probe(
  DsmWebApi api,
  String name,
  String method,
  int version,
  Map<String, dynamic> params,
  String label,
) async {
  final tag = '[$name/$method v$version $label]';
  try {
    final data = await api.call(
      name,
      method,
      preferredVersion: version,
      params: params,
    );
    final s = jsonEncode(data);
    print('[r403b]$tag OK len=${s.length} ${_clip(s, 600)}');
  } catch (e) {
    print('[r403b]$tag ERR $e');
    if (e is DsmApiException) print('[r403b]$tag   raw=${jsonEncode(e.raw)}');
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
  await api.login(
    account: _env('SYNO_NAS_ACCOUNT', 'SYNO_ACCOUNT'),
    password: _env('SYNO_NAS_PASSWORD', 'SYNO_PASSWORD'),
    session: 'Chat',
  );
  print('[r403b] 登录成功（只读）');

  // ① 发现表里这两个 API 的 path / 版本范围（判"是不是客户端合成错误"）
  final table = api.apiTable;
  for (final k in const [
    'SYNO.AudioStation.Lyrics',
    'SYNO.AudioStation.LyricsSearch',
  ]) {
    final e = table?[k];
    print(
      '[r403b][SYNO.API.Info] $k entry=${e == null ? '（不在发现表里）' : 'path=${e.path} min=${e.minVersion} max=${e.maxVersion} requestFormat=${e.requestFormat}'}',
    );
  }

  // ② 目标歌的服务端元数据（`getinfo` v3）：artist/album 到底有没有值
  await probe(
    api,
    'SYNO.AudioStation.Song',
    'getinfo',
    3,
    {'id': 'music_28045', 'additional': 'song_tag,song_audio,song_rating'},
    'id=music_28045',
  );

  // ③ `searchlyrics` 值矩阵：**一次只动一个参数**，看 101 什么时候松开
  const t = 'Demo Song';
  const a = 'Demo Artist';
  final shapes = <(String, Map<String, dynamic>)>[
    ('只有 title', {'title': t}),
    ('title + artist', {'title': t, 'artist': a}),
    ('title + artist + limit', {'title': t, 'artist': a, 'limit': 1}),
    (
      'title + artist + limit + additional',
      {'title': t, 'artist': a, 'limit': 1, 'additional': 'full_lyrics'},
    ),
    (
      'title + artist + album',
      {'title': t, 'artist': a, 'album': '00s Love Songs'},
    ),
    ('只有 artist', {'artist': a}),
    ('keyword', {'keyword': t}),
    ('id（歌 id）', {'id': 'music_28045'}),
    ('title + artist + library', {'title': t, 'artist': a, 'library': 'shared'}),
    (
      'title + artist + limit + additional（v1）',
      {'title': t, 'artist': a, 'limit': 1, 'additional': 'full_lyrics'},
    ),
  ];
  for (final (label, params) in shapes) {
    final v = label.endsWith('（v1）') ? 1 : 2;
    final clean = {...params};
    await probe(
      api,
      'SYNO.AudioStation.LyricsSearch',
      'searchlyrics',
      v,
      clean,
      label,
    );
  }

  // ④ 对照：`getlyrics` 同一首歌（应回 1733 字符）——证明"读得到歌词"不是网络问题
  await probe(
    api,
    'SYNO.AudioStation.Lyrics',
    'getlyrics',
    2,
    {'id': 'music_28045'},
    'id=music_28045',
  );

  print('[r403b] 完成（只读）');
}
