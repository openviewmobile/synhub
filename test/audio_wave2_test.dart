// 音频 **wave2**（DSaudio 对齐）—— 新增契约的离线验证。
//
// 事实来源（逐字对齐，不凭记忆）：
//   * `docs/audio-api-live.md` §1/§1.1/§1.2 —— 2026-09-22 真机取证：
//       - `Search:list` `{offset,limit}` → `{"albumTotal":1210,…}`；
//       - `Radio:list` → `{radios:[{id:"SHOUTcast",title:"SHOUTcast(TM)",
//         type:"container",url:""},…]}`（**首屏是容器**）；
//       - `Lyrics:getlyrics {id}` → `data.lyrics`（`get`/`list`/`getinfo` = 103）；
//       - `Cover:getcover` 必需 `album_name`+`album_artist_name`+`view`（用 `id` 404），
//         返回**二进制 JPEG**（不是 JSON）；
//       - 主 API 的 path 都在 `AudioStation/*.cgi`（**不是** `entry.cgi`；
//         用错 path 服务端回 102）。path 一律来自 `SYNO.API.Info`。
//
// 本文件覆盖：
//   ① path 必须来自 `SYNO.API.Info`（真实调用打到哪个 cgi）；
//   ② `Search:list` 的分页 + 五个 `*Total`；
//   ③ `Radio:list` 的容器/电台项分离；
//   ④ `Cover.getcover` 的线参（album_name/album_artist_name/view，不是 id）；
//   ⑤ `Lyrics.getlyrics` 的方法名（不是 get）；
//   ⑥ 电台页 + Genre/Folder 标签页的**空态与失败三态**（回归校验）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_cover.dart';
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_radio_page.dart';
import 'package:synhub/src/features/audio/audio_web_queue_page.dart';
import 'package:synhub/src/features/media/media_cover.dart';
import 'package:synhub/src/features/media/media_cover_provider.dart';
import 'package:synhub/src/features/media/media_cover_view.dart';
import 'package:synhub/src/features/media/media_source.dart' show MediaKind;

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _as = 'SYNO.AudioStation';

/// 真机 `SYNO.API.Info` 里 AS 的条目形状（path **逐字**取自真机能力表 /
/// `webapi/AudioStation.api`，见 `docs/audio-api-live.md` §1 的 path 列）。
Map<String, Map<String, dynamic>> asTable({
  bool withRadio = true,
  bool withWebPlayer = true,
}) => {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  '$_as.Info': {
    'path': 'AudioStation/info.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
  '$_as.Song': {
    'path': 'AudioStation/song.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  '$_as.Album': {
    'path': 'AudioStation/album.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  '$_as.Artist': {
    'path': 'AudioStation/artist.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  '$_as.Composer': {
    'path': 'AudioStation/composer.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  '$_as.Genre': {
    'path': 'AudioStation/genre.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  '$_as.Folder': {
    'path': 'AudioStation/folder.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  '$_as.Search': {
    'path': 'AudioStation/search.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  '$_as.Lyrics': {
    'path': 'AudioStation/lyrics.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  '$_as.LyricsSearch': {
    'path': 'AudioStation/lyrics_search.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  '$_as.Cover': {
    'path': 'AudioStation/cover.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  if (withRadio)
    '$_as.Radio': {
      'path': 'AudioStation/radio.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
  if (withWebPlayer)
    '$_as.WebPlayer': {
      'path': 'AudioStation/web_player.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
  // 新 webapi5 代（synoapid）：path 由真机能力表定；官方前端走 entry.cgi。
  '$_as.Pin': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
};

/// 真机 `Radio:list` 的首屏回包（逐字，`docs/audio-api-live.md` §1）。
Map<String, dynamic> radiosPayload() => {
  'radios': [
    {
      'id': 'SHOUTcast',
      'title': 'SHOUTcast(TM)',
      'type': 'container',
      'url': '',
    },
    {
      'id': 'UserDefined',
      'title': 'User Defined',
      'type': 'container',
      'url': '',
    },
  ],
  'total': 2,
};

/// 真机 `WebPlayer:getplaylist` 的无参回包（逐字，`docs/audio-api-live.md` §6）。
Map<String, dynamic> webQueuePayload() => {
  'current': 0,
  'mode': 'normal',
  'shuffle': 0,
  'songs': <Object?>[],
  'timestamp': 1789993283,
  'total': 0,
};

/// 记录"真实 POST 打到了哪个 path"的假传输（FakeTransport 只记 params）。
///
/// 这是"path 来自 `SYNO.API.Info`"的**唯一硬证据** —— api 名谁都会传，
/// 打到哪个 cgi 才是契约。
class PathTransport extends FakeTransport {
  PathTransport(super.responses, super.apiTable);

  final List<({String path, Map<String, dynamic> params})> posted = [];

  /// 断网（`DsmTransportException`，与真机传输包装后一致）。
  final Set<String> offlineApis = {};

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    if (offlineApis.contains('${params['api']}.${params['method']}')) {
      calls.add(params);
      throw DsmTransportException('connection error');
    }
    posted.add((path: path, params: params));
    return super.postForm(path, params);
  }

  /// 某个 api 最后一次真实的 cgi path。
  String pathFor(String api) =>
      posted.lastWhere((e) => e.params['api'] == api).path;
}

Future<(AudioStationApi, PathTransport)> boot({
  Map<String, Map<String, dynamic>> responses = const {},
  bool withRadio = true,
  bool withWebPlayer = true,
}) async {
  final t = PathTransport(responses, {
    ...FakeTransport.table,
    ...asTable(withRadio: withRadio, withWebPlayer: withWebPlayer),
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (AudioStationApi(api), t);
}

Map<String, dynamic> callOf(PathTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

Future<({PathTransport t, ProviderContainer c})> pumpRadio(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>> responses = const {},
  bool withRadio = true,
  bool withWebPlayer = true,
  Set<String> offline = const {},
  String? container,
}) async {
  final t = PathTransport(responses, {
    ...FakeTransport.table,
    ...asTable(withRadio: withRadio, withWebPlayer: withWebPlayer),
  });
  t.offlineApis.addAll(offline);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final c = ProviderContainer(
    overrides: [audioApiProvider.overrideWithValue(AudioStationApi(api))],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: AudioRadioPage(container: container),
      ),
    ),
  );
  await tester.pump(); // postFrameCallback → load()
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: c);
}

/// 搭 `AudioPage`（音乐库）并返回假传输（供入口门控 + 各标签页回归用）。
Future<PathTransport> pumpLibrary(
  WidgetTester tester, {
  bool withRadio = true,
  bool withWebPlayer = true,
  Map<String, Map<String, dynamic>> responses = const {},
  Set<String> offline = const {},
}) async {
  final t = PathTransport(responses, {
    ...FakeTransport.table,
    ...asTable(withRadio: withRadio, withWebPlayer: withWebPlayer),
  });
  t.offlineApis.addAll(offline);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final c = ProviderContainer(
    overrides: [audioApiProvider.overrideWithValue(AudioStationApi(api))],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: AudioPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return t;
}

/// 搭服务端播放队列面板（`AudioWebQueuePage`）并返回假传输。
Future<PathTransport> pumpWebQueue(
  WidgetTester tester, {
  bool withWebPlayer = true,
  Map<String, Map<String, dynamic>> responses = const {},
  Set<String> offline = const {},
}) async {
  final t = PathTransport(responses, {
    ...FakeTransport.table,
    ...asTable(withWebPlayer: withWebPlayer),
  });
  t.offlineApis.addAll(offline);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final c = ProviderContainer(
    overrides: [audioApiProvider.overrideWithValue(AudioStationApi(api))],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: AudioWebQueuePage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return t;
}

/// 队列有内容的回包（r405：官方形态逐字 —— `songs` 记录 `{id,path,title,type}`）。
Map<String, dynamic> webQueueSongs(List<String> ids) => {
  'current': 0,
  'mode': 'normal',
  'shuffle': 0,
  'songs': [
    for (final id in ids)
      {
        'id': id,
        'path': '/music/music/$id.mp3',
        'title': 'T-$id',
        'type': 'file',
      },
  ],
  'timestamp': 1792037365,
  'total': ids.length,
};

/// 起一个**能推/弹**队列页的宿主（`autoDispose` 与下拉刷新都要"进页/停在页上"）。
///
/// 与 [pumpWebQueue] 的差别：`home` 是带 `open` 按钮的宿主页，队列页是 `push` 出来的
/// —— 只有这样 `ProviderContainer` 才会在弹出时把 `autoDispose` 的 provider 真正销毁。
Future<PathTransport> pumpWebQueuePushed(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>> responses = const {},
}) async {
  final t = PathTransport(responses, {
    ...FakeTransport.table,
    ...asTable(withWebPlayer: true),
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final c = ProviderContainer(
    overrides: [audioApiProvider.overrideWithValue(AudioStationApi(api))],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AudioWebQueuePage(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return t;
}

void main() {
  // ★ r405：服务端队列页的**新鲜度**（DA57）
  //
  // 真机读数：同一会话里"进页 → 外部把队列从 2 条改成 1 条 → 重新进页"，
  // 页面**仍渲染 2 行**（宿主 `getplaylist` 同刻 `total=1`）；冷启动后同一页读到 1 行
  // ⇒ 根因是 `audioWebPlayerQueueProvider` **整个会话缓存**、进页不重取。
  group('r405 服务端播放队列页：每次进页必须重取（DA57）', () {
    testWidgets('弹出后再进页读到的是**新**队列（autoDispose）', (tester) async {
      final t = await pumpWebQueuePushed(
        tester,
        responses: {
          '$_as.WebPlayer.getplaylist': webQueueSongs(['music_1', 'music_2']),
        },
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-webqueue-song-music_1')), findsOneWidget);
      expect(find.byKey(const Key('as-webqueue-song-music_2')), findsOneWidget);

      // 外部（DSM 网页播放器）把队列改成只剩 1 条。
      t.responses['$_as.WebPlayer.getplaylist'] = webQueueSongs(['music_2']);

      // 退出队列页（这一步必须把 provider 销毁）→ 再进页。
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('as-webqueue-song-music_1')),
        findsNothing,
        reason: '会话内缓存会让这里仍是旧的 2 行（DA57 原形态）',
      );
      expect(find.byKey(const Key('as-webqueue-song-music_2')), findsOneWidget);
      expect(
        t.calls.where((c) => c['method'] == 'getplaylist').length,
        2,
        reason: '两次进页 = 两次 getplaylist',
      );
    });

    testWidgets('停在页面上时下拉刷新能读到新队列', (tester) async {
      final t = await pumpWebQueuePushed(
        tester,
        responses: {
          '$_as.WebPlayer.getplaylist': webQueueSongs(['music_1']),
        },
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-webqueue-song-music_1')), findsOneWidget);

      t.responses['$_as.WebPlayer.getplaylist'] = webQueueSongs([
        'music_1',
        'music_2',
      ]);
      await tester.fling(
        find.byKey(const Key('as-webqueue-song-music_1')),
        const Offset(0, 320),
        1000,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('as-webqueue-song-music_2')), findsOneWidget);
      expect(t.calls.where((c) => c['method'] == 'getplaylist').length, 2);
    });

    testWidgets('空队列也能下拉刷新（空态也要有重取路径）', (tester) async {
      final t = await pumpWebQueuePushed(
        tester,
        responses: {'$_as.WebPlayer.getplaylist': webQueuePayload()},
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-webqueue-empty')), findsOneWidget);

      t.responses['$_as.WebPlayer.getplaylist'] = webQueueSongs(['music_9']);
      await tester.fling(
        find.byKey(const Key('as-webqueue-empty')),
        const Offset(0, 320),
        1000,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('as-webqueue-song-music_9')), findsOneWidget);
      expect(t.calls.where((c) => c['method'] == 'getplaylist').length, 2);
    });
  });

  // ① 路径：真实调用打到 `SYNO.API.Info` 给的 cgi（不是 entry.cgi）
  group('path 来自 SYNO.API.Info（音频主 API 都在 AudioStation/*.cgi）', () {
    test('真实调用打到正确 cgi；用 entry.cgi 的只有新 webapi5 的 Pin', () async {
      final (audio, t) = await boot(
        responses: {
          '$_as.Song.list': {'songs': [], 'total': 0},
          '$_as.Search.list': {'albums': [], 'albumTotal': 0},
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
          '$_as.Radio.list': radiosPayload(),
        },
      );
      await audio.listSongs();
      await audio.globalSearch(keyword: 'x');
      await audio.getLyrics('music_1');
      await audio.listRadios();

      expect(t.pathFor('$_as.Song'), 'AudioStation/song.cgi');
      expect(t.pathFor('$_as.Search'), 'AudioStation/search.cgi');
      expect(t.pathFor('$_as.Lyrics'), 'AudioStation/lyrics.cgi');
      expect(t.pathFor('$_as.Radio'), 'AudioStation/radio.cgi');
      for (final p in t.posted.map((e) => e.path)) {
        expect(p, isNot('entry.cgi'), reason: 'AS 主 API 不允许走 entry.cgi（102）');
      }
    });

    test(
      'cgiPath 优先能力表；静态兜底表全是 AudioStation/*.cgi（Search 不是 entry.cgi）',
      () async {
        final (audio, _) = await boot();
        expect(audio.cgiPath('$_as.Search'), 'AudioStation/search.cgi');
        expect(audio.cgiPath('$_as.Radio'), 'AudioStation/radio.cgi');

        for (final api in [
          AudioStationApi.apiInfo,
          AudioStationApi.apiAlbum,
          AudioStationApi.apiArtist,
          AudioStationApi.apiComposer,
          AudioStationApi.apiGenre,
          AudioStationApi.apiFolder,
          AudioStationApi.apiSong,
          AudioStationApi.apiStream,
          AudioStationApi.apiSearch,
          AudioStationApi.apiRadio,
          AudioStationApi.apiLyrics,
          AudioStationApi.apiCover,
          AudioStationApi.apiPlaylist,
        ]) {
          expect(
            AudioStationApi.cgiPaths[api],
            startsWith('AudioStation/'),
            reason: '$api 的静态兜底 path 必须是 AudioStation/*.cgi',
          );
        }
        // 新 webapi5 代不在老 `.api` 的 path 表里 —— 静态表**不编**，交给能力表。
        expect(
          AudioStationApi.cgiPaths.containsKey(AudioStationApi.apiPin),
          isFalse,
        );
      },
    );
  });

  // ② 搜索：方法名是 list（不是 search）+ 分页 + 各分类 *Total
  group('Search:list（不是 search）', () {
    test('方法名逐字是 list、v1、offset/limit 真发、五个 *Total 解出来', () async {
      final (audio, t) = await boot(
        responses: {
          '$_as.Search.list': {
            'albumTotal': 1210,
            'albums': [
              {
                'name': '00s Love Songs',
                'album_artist': 'Various Artists',
                'year': 2022,
              },
            ],
            'artistTotal': 300,
            'artists': [
              {'name': 'Demo Artist'},
            ],
            'genreTotal': 12,
            'composerTotal': 7,
            'songsTotal': 9000,
          },
        },
      );
      final r = await audio.globalSearch(
        keyword: 'love',
        offset: 25,
        limit: 25,
      );

      // ★ 方法名：真机是 `list`（`search` 是 Song 的，不是 Search 的）。
      final call = callOf(t, '$_as.Search', 'list');
      expect(call['version'], '1');
      expect(call['offset'], 25);
      expect(call['limit'], 25);
      expect(call['keyword'], 'love');
      // 五个分类键 == 关键字（官方 getSearchJsonObj 逐字）
      for (final k in ['album', 'artist', 'composer', 'genre', 'title']) {
        expect(call[k], 'love', reason: k);
      }
      // ★ 真机的 `*Total`（不是单一 total）
      expect(r.albumsTotal, 1210);
      expect(r.artistsTotal, 300);
      expect(r.genresTotal, 12);
      expect(r.composersTotal, 7);
      expect(r.songsTotal, 9000);
      expect(r.albums.single.name, '00s Love Songs');
      expect(r.isEmpty, isFalse);
    });

    test('服务端没给 *Total 时不撒谎：回落成本次条数', () async {
      final (audio, _) = await boot(
        responses: {
          '$_as.Search.list': {
            'albums': [
              {'name': 'A'},
            ],
          },
        },
      );
      final r = await audio.globalSearch(keyword: 'a');
      expect(r.albumsTotal, 1);
      expect(r.artistsTotal, 0);
    });
  });

  // ③ 电台：容器 ≠ 电台项
  group('Radio:list（容器与电台项必须分开）', () {
    test('DTO：type=container 是容器；显示名用 title，id 不上屏', () {
      final container = AudioRadioDto.fromJson({
        'id': 'SHOUTcast',
        'title': 'SHOUTcast(TM)',
        'type': 'container',
        'url': '',
      });
      expect(container.isContainer, isTrue);
      expect(container.hasStreamUrl, isFalse);
      expect(container.title, 'SHOUTcast(TM)');
      expect(container.id, 'SHOUTcast');

      final station = AudioRadioDto.fromJson({
        'id': 'radio_1',
        'title': 'Jazz Radio',
        'type': 'station',
        'url': 'http://example.com/jazz',
      });
      expect(station.isContainer, isFalse);
      expect(station.hasStreamUrl, isTrue);
    });

    test('listRadios：v2、root radios + total、无参不臆造 type/keyword', () async {
      final (audio, t) = await boot(
        responses: {'$_as.Radio.list': radiosPayload()},
      );
      final page = await audio.listRadios();

      final call = callOf(t, '$_as.Radio', 'list');
      expect(call['version'], '2');
      expect(call['offset'], 0);
      expect(call['limit'], AudioStationApi.pageSize);
      // 真机无参即回容器列表 → 没有 type/keyword 就不发
      expect(call.containsKey('type'), isFalse);
      expect(call.containsKey('keyword'), isFalse);

      expect(page.total, 2);
      expect(page.items.length, 2);
      expect(page.items.first.isContainer, isTrue);
      expect(page.items.first.title, 'SHOUTcast(TM)');
    });

    test('listRadios：给了 type 才发；★ `keyword` 参数已被 r441 删除（服务端忽略）', () async {
      final (audio, t) = await boot(
        responses: {'$_as.Radio.list': radiosPayload()},
      );
      await audio.listRadios(type: 'player_source_shoutcast', offset: 0, limit: 5);
      final call = callOf(t, '$_as.Radio', 'list');
      expect(call['type'], 'player_source_shoutcast');
      // ★ r441 订正（`DA95`）：修前这里断言 `list` 带 `keyword`，而真机（只读探针
      //   `tool/r441_radio_search_probe_test.dart`）证明服务端**完全忽略**它
      //   （`keyword=Jazz` 与无参**逐字同**：3 条根层容器、total=3）⇒ 参数已删，
      //   关键字只能走 `Radio.search`（见下面的 `searchRadios` 用例）。
      expect(call.containsKey('keyword'), isFalse);
      expect(call.containsKey('text'), isFalse);
    });

    test('searchRadios：走 Radio.search v2，**显式**带 offset/limit（不给就一条不回）', () async {
      final (audio, t) = await boot(
        responses: {'$_as.Radio.search': radiosPayload()},
      );
      final page = await audio.searchRadios(keyword: 'jazz', offset: 0, limit: 5);

      final call = callOf(t, '$_as.Radio', 'search');
      expect(call['version'], '2');
      expect(call['keyword'], 'jazz');
      // ★ r441 真机：不给 offset/limit ⇒ 服务端回 `radios: []` 而 `total` 照给 ⇒ 必须显式发。
      expect(call['offset'], 0);
      expect(call['limit'], 5);
      // ★ 真机：`container` 被服务端忽略（同结果、更慢）⇒ 不发。
      expect(call.containsKey('container'), isFalse);
      expect(page.total, 2);
      expect(page.items.length, 2);
    });

    test('searchRadios 走 search、listRadios 走 list —— 两条通道不串线', () async {
      final (audio, t) = await boot(
        responses: {
          '$_as.Radio.list': radiosPayload(),
          '$_as.Radio.search': radiosPayload(),
        },
      );
      await audio.listRadios();
      await audio.searchRadios(keyword: 'rock');
      expect(callOf(t, '$_as.Radio', 'list')['keyword'], isNull);
      expect(callOf(t, '$_as.Radio', 'search')['keyword'], 'rock');
    });
  });

  // ④ 封面：getcover 的线参（album_name+album_artist_name+view，不是 id）
  group('Cover.getcover 线参（真实 JPEG 通道）', () {
    test(
      'albumCoverUrl 用 album_name + album_artist_name + view；绝不发 id',
      () async {
        final (audio, _) = await boot();
        final url = audio.albumCoverUrl(
          '00s Love Songs',
          albumArtist: 'Various Artists',
        );

        expect(
          url.startsWith(
            'https://nas.example.com:5001/webapi/AudioStation/cover.cgi?',
          ),
          isTrue,
        );
        expect(url.contains('method=getcover'), isTrue);
        // 逐字用 `Uri.encodeQueryComponent` 拼（与实现同一个编码器：空格→`+`）
        expect(
          url.contains(
            'album_name=${Uri.encodeQueryComponent('00s Love Songs')}',
          ),
          isTrue,
          reason: url,
        );
        expect(
          url.contains(
            'album_artist_name=${Uri.encodeQueryComponent('Various Artists')}',
          ),
          isTrue,
          reason: url,
        );
        expect(url.contains('view=default'), isTrue);
        // ★ 用 id 会 404（真机三种形态全 404）。
        //   注意别用 `url.contains('id=')` —— `_sid=` 里也含 `id=`；
        //   这里解析查询串，只认真正的 `id` 参数。
        expect(
          Uri.parse(url).queryParameters.containsKey('id'),
          isFalse,
          reason: url,
        );
        // 二进制通道的鉴权：`_sid=`，不是 `sid=`
        expect(url.contains('_sid=FAKE-SID'), isTrue);
        expect(url.contains('?sid='), isFalse);
      },
    );

    test('album_artist_name 即使为空也在场（官方模板 {3} 恒拼）', () async {
      final (audio, _) = await boot();
      final url = audio.albumCoverUrl('Solo Album');
      expect(url.contains('album_artist_name='), isTrue, reason: url);
      expect(
        url.contains('album_name=${Uri.encodeQueryComponent('Solo Album')}'),
        isTrue,
        reason: url,
      );
    });
  });

  // ⑤ 歌词：方法名是 getlyrics（不是 get/list/getinfo）
  group('Lyrics.getlyrics（不是 get）', () {
    test('方法名逐字是 getlyrics、v2、参数 {id}、回包 data.lyrics', () async {
      final (audio, t) = await boot(
        responses: {
          '$_as.Lyrics.getlyrics': {
            'lyrics': 'Sample lyric line one\r\nSample lyric line two\r\n',
          },
        },
      );
      final text = await audio.getLyrics('music_28045');
      final call = callOf(t, '$_as.Lyrics', 'getlyrics');
      expect(call['version'], '2');
      expect(call['id'], 'music_28045');
      expect(text, contains('Sample lyric line one'));
      // 只发了 id（没有别的臆造参数）
      expect(call.containsKey('method'), isTrue);
      expect(t.pathFor('$_as.Lyrics'), 'AudioStation/lyrics.cgi');
    });
  });

  // ⑥ 电台页：容器/电台项分离 + 空态 + 失败三态
  group('电台页（容器/电台项分开 + 空态/三态）', () {
    testWidgets('容器与电台项分开渲染；显示 title；内部 id 不上屏', (tester) async {
      await pumpRadio(
        tester,
        responses: {
          '$_as.Radio.list': {
            'radios': [
              {
                'id': 'SHOUTcast',
                'title': 'SHOUTcast(TM)',
                'type': 'container',
                'url': '',
              },
              {
                'id': 'radio_1',
                'title': 'Jazz Radio',
                'type': 'station',
                'url': 'http://example.com/jazz',
              },
            ],
            'total': 2,
          },
        },
      );
      // 容器有独立 key，不会和电台项混
      expect(
        find.byKey(const Key('as-radio-container-SHOUTcast')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('as-radio-station-radio_1')), findsOneWidget);
      // 显示名用 title（不是 id）
      expect(find.text('SHOUTcast(TM)'), findsOneWidget);
      expect(find.text('SHOUTcast'), findsNothing, reason: 'id 是内部值，不上屏');
      expect(find.text('Jazz Radio'), findsOneWidget);
      // ★ r633（DA216）订正：容器身份由文件夹图标 + `>` 表达，不再给每行挂
      //   一句"电台分类"（一层里所有行同一句 = 没信息）。
      expect(
        find.text('电台分类'),
        findsNothing,
        reason: 'DA216：容器行不再挂填充词副标题',
      );
      // 容器没有被当成电台项
      expect(find.byKey(const Key('as-radio-station-SHOUTcast')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('真机首屏两条容器 → 全部按容器渲染，没有"电台项"', (tester) async {
      await pumpRadio(tester, responses: {'$_as.Radio.list': radiosPayload()});
      expect(
        find.byKey(const Key('as-radio-container-SHOUTcast')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('as-radio-container-UserDefined')),
        findsOneWidget,
      );
      expect(find.text('SHOUTcast(TM)'), findsOneWidget);
      expect(find.text('User Defined'), findsOneWidget);
      // 如实说明"只列表、不播放"在
      expect(find.byKey(const Key('as-radio-note')), findsOneWidget);
    });

    testWidgets('一台都没有 → 电台空态（不是"加载失败"、也不是未安装）', (tester) async {
      await pumpRadio(tester, responses: const {});
      expect(find.text('还没有电台'), findsOneWidget);
      expect(find.text('电台加载失败'), findsNothing);
      expect(find.text('这台 NAS 没有安装 Audio Station'), findsNothing);
    });

    // ---------------------------------------------------- C5 写：新建/改名/删除
    testWidgets('C5：新建自定义电台 → Radio/add {container,title,url,desc}', (
      tester,
    ) async {
      final r = await pumpRadio(
        tester,
        responses: {'$_as.Radio.list': radiosPayload()},
      );
      await tester.tap(find.byKey(const Key('as-radio-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('as-radio-title-field')),
        '我的电台',
      );
      await tester.enterText(
        find.byKey(const Key('as-radio-url-field')),
        'http://example.com/s.m3u',
      );
      await tester.enterText(
        find.byKey(const Key('as-radio-desc-field')),
        '测试用',
      );
      await tester.tap(find.byKey(const Key('as-radio-ok')));
      await tester.pumpAndSettle();
      final c = callOf(r.t, '$_as.Radio', 'add');
      expect(c['container'], 'UserDefined', reason: '官方常量逐字');
      expect(c['title'], '我的电台');
      expect(c['url'], 'http://example.com/s.m3u');
      expect(c['desc'], '测试用');
      expect(tester.takeException(), isNull);
    });

    testWidgets('C5：删除电台 → 段替换：该行替换成空（radios_json 为空数组）', (tester) async {
      // ★ r400：写动词只在**自定义电台页**给（DA47）⇒ 搭页必须带 container。
      final r = await pumpRadio(
        tester,
        container: 'UserDefined',
        responses: {
          '$_as.Radio.list': {
            'radios': [
              {
                'id': 'SHOUTcast',
                'title': 'SHOUTcast(TM)',
                'type': 'container',
                'url': '',
              },
              {
                'id': 'radio_1',
                'title': 'Jazz Radio',
                'type': 'station',
                'url': 'http://example.com/jazz',
              },
              {
                'id': 'radio_2',
                'title': 'Rock Radio',
                'type': 'station',
                'url': 'http://example.com/rock',
              },
            ],
            'total': 3,
          },
          '$_as.Radio.updateradios': const {},
        },
      );
      await tester.tap(find.byKey(const Key('as-radio-menu-radio_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-radio-delete-radio_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-radio-delete-ok')));
      await tester.pumpAndSettle();
      final c = callOf(r.t, '$_as.Radio', 'updateradios');
      expect(c['container'], 'UserDefined');
      // ★ r399（DA46）真机取证后的**官方 Web 前端**契约：段替换。
      //   行号 = 被删项在列表里的下标；limit=1；这一段替换成**空**。
      // ★★ r401 就地订正：这条期望原先写的是 `0`（"容器行不算电台项"）——
      //   那是**把过滤后的下标当服务端行号**，正是 r401 要拆掉的假设。
      //   夹具里第 0 行是一行容器（`SHOUTcast`），它**占**服务端的第 0 行
      //   ⇒ `radio_1` 是服务端第 **1** 行。（真机现网该页不混行，见
      //   `tool/probe_r401_radio_mix.dart`；这条夹具是"混排行"的合成用例。）
      expect(c['offset'], 1, reason: '容器行占第 0 行 ⇒ radio_1 是服务端第 1 行');
      expect(c['limit'], 1, reason: '单行动作 ⇒ 段长 1（不是"整段替换"）');
      expect(c['radios_json'], '[]', reason: '删除 = 这一段替换成空数组');
      expect(
        c.containsKey('radio_json'),
        isFalse,
        reason: '★ 真机只认 radios_json；发 radio_json 会被当"空段"替换（静默删除，DA46）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('C5：改名 → 段替换的 radios_json 里是新名字（无 id、段长 1）', (tester) async {
      // ★ r400：同上 —— 改名也只在自定义电台页可达。
      final r = await pumpRadio(
        tester,
        container: 'UserDefined',
        responses: {
          '$_as.Radio.list': {
            'radios': [
              {
                'id': 'radio_1',
                'title': '旧名',
                'type': 'station',
                'url': 'http://example.com/a',
              },
            ],
            'total': 1,
          },
          '$_as.Radio.updateradios': const {},
        },
      );
      await tester.tap(find.byKey(const Key('as-radio-menu-radio_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-radio-edit-radio_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('as-radio-title-field')),
        '新名',
      );
      await tester.tap(find.byKey(const Key('as-radio-ok')));
      await tester.pumpAndSettle();
      final c = callOf(r.t, '$_as.Radio', 'updateradios');
      expect(c['offset'], 0, reason: 'radio_1 是第 0 行');
      expect(c['limit'], 1);
      final json = c['radios_json'] as String;
      expect(json.contains('新名'), isTrue);
      expect(json.contains('旧名'), isFalse);
      expect(
        json.contains('http://example.com/a'),
        isTrue,
        reason: '未改字段必须原样回传（url 是电台的身份，不能被改名吞掉）',
      );
      // ★ r399（DA46）：记录里**不许**带 id —— 官方前端逐字只有 title/desc/url，
      //   且服务端语义是"用这段替换"，带 id 无意义（旧形状 `offset 0 / limit -1`
      //   在真机会把整个列表清空）。
      expect(json.contains('"id"'), isFalse, reason: '记录不带 id');
      expect(c.containsKey('radio_json'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('★ r399 行号取自**本页**容器的实例（改第 2 行 ⇒ offset=1）', (tester) async {
      // 真机教训：修前这里读的是 `allRadiosQuery`（`container: null` = 根层的
      // **另一个** family 实例）⇒ 拿不到本页的行 ⇒ 行号算不出来。
      // 这条用例用 `container:'UserDefined'` 搭页，若再读错实例就会露馅。
      final r = await pumpRadio(
        tester,
        container: 'UserDefined',
        responses: {
          '$_as.Radio.list': {
            'radios': [
              {
                'id': 'radio_1',
                'title': '第一台',
                'type': 'station',
                'url': 'http://example.com/1',
              },
              {
                'id': 'radio_2',
                'title': '第二台',
                'type': 'station',
                'url': 'http://example.com/2',
              },
            ],
            'total': 2,
          },
          '$_as.Radio.updateradios': const {},
        },
      );
      await tester.tap(find.byKey(const Key('as-radio-menu-radio_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-radio-edit-radio_2')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('as-radio-title-field')),
        '第二台改名',
      );
      await tester.tap(find.byKey(const Key('as-radio-ok')));
      await tester.pumpAndSettle();
      final c = callOf(r.t, '$_as.Radio', 'updateradios');
      expect(c['container'], 'UserDefined');
      expect(c['offset'], 1, reason: '改的是第 2 行 ⇒ 段起 1（行号来自本页列表）');
      expect(c['limit'], 1);
      final json = c['radios_json'] as String;
      expect(json.contains('第二台改名'), isTrue);
      expect(json.contains('第一台'), isFalse, reason: '段长 1：不许把别的行一起回传');
      expect(tester.takeException(), isNull);
    });

    testWidgets('★ r401：行号取**服务端行序**（混排页里容器行也占行号）', (tester) async {
      // 原理：`updateradios` 的 `offset` 是"该 container 下第几行"，而列表里的
      // **容器行同样占行号**（真机：根层 3 行全是容器、`SHOUTcast` 下 26 行全是
      // 分类容器）。修前这里先 `where((r) => !r.isContainer)` 再取下标 ⇒ 只要某个
      // 容器页混着容器行与电台行，发出去的行号就会**比服务端小**，
      // 结果就是"删第 k 行、删到了别的一条"（DA47 同族：错表 → 错行）。
      // 真机取证（`tool/probe_r401_radio_mix.dart`）：本 NAS 现网三种页面都不混，
      // 所以这条是**结构性加固**，靠这条用例把"取错行序"钉死。
      final r = await pumpRadio(
        tester,
        container: 'UserDefined',
        responses: {
          '$_as.Radio.list': {
            'radios': [
              // ① 混进来的一行容器（占服务端第 0 行）
              {
                'id': 'SHOUTcast',
                'title': 'SHOUTcast(TM)',
                'type': 'container',
                'url': '',
              },
              // ② 第 1 行
              {
                'id': 'radio_1',
                'title': '第一台',
                'type': 'station',
                'url': 'http://example.com/1',
              },
              // ③ 第 2 行 ← 要改的是它
              {
                'id': 'radio_2',
                'title': '第二台',
                'type': 'station',
                'url': 'http://example.com/2',
              },
            ],
            'total': 3,
          },
          '$_as.Radio.updateradios': const {},
        },
      );
      await tester.tap(find.byKey(const Key('as-radio-menu-radio_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-radio-edit-radio_2')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('as-radio-title-field')),
        '第二台改名',
      );
      await tester.tap(find.byKey(const Key('as-radio-ok')));
      await tester.pumpAndSettle();
      final c = callOf(r.t, '$_as.Radio', 'updateradios');
      expect(c['container'], 'UserDefined');
      // ★ 反向判据：若回过头去"先过滤容器行"，这里会变成 1（少一行）⇒ 必红。
      expect(c['offset'], 2, reason: '容器行占第 0 行 ⇒ radio_2 是服务端第 2 行');
      expect(c['limit'], 1);
      expect((c['radios_json'] as String).contains('第二台改名'), isTrue);
      expect(tester.takeException(), isNull);
    });

    // ------------------------------------- r400（DA47）容器作用域 + 收藏动作
    testWidgets('★ r400 DA47：收藏页的行菜单只有「取消收藏」——**没有**编辑/删除', (tester) async {
      // 真机缺陷现场：修前在 `My favorite radio` 页点"删除"，被删掉的是**同一个
      // 行号上的自定义电台**（`Favorite` 仍 2 条、`UserDefined` 1→0，且无提示）。
      await pumpRadio(
        tester,
        container: 'Favorite',
        responses: {
          '$_as.Radio.list': {
            'radios': [
              {
                'id': 'radio_fav1',
                'title': '收藏电台',
                'type': 'station',
                'url': 'http://example.com/fav',
              },
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-radio-menu-radio_fav1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('as-radio-unfav-radio_fav1')),
        findsOneWidget,
        reason: '收藏页给"取消收藏"',
      );
      expect(
        find.byKey(const Key('as-radio-edit-radio_fav1')),
        findsNothing,
        reason:
            '★ DA47：收藏页**不许**给改名 —— 写动词的 container 是 UserDefined，'
            '会改掉另一个列表里同一行号的电台',
      );
      expect(
        find.byKey(const Key('as-radio-delete-radio_fav1')),
        findsNothing,
        reason: '★ DA47：收藏页**不许**给删除（真机会删掉自定义电台）',
      );
      expect(
        find.byKey(const Key('as-radio-fav-radio_fav1')),
        findsNothing,
        reason: '已经是收藏了，不再给"加入收藏"',
      );
      // 顶栏"新建电台"也只在根层/自定义页给（`Radio/add` 的 container 恒为 UserDefined）。
      expect(find.byKey(const Key('as-radio-add')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('★ r400 DA47：内置电台（SHOUTcast 分类页）只有「加入收藏」', (tester) async {
      await pumpRadio(
        tester,
        container: 'Alternative',
        responses: {
          '$_as.Radio.list': {
            'radios': [
              {
                'id': 'radio_builtin',
                'title': '90.7 Magic FM',
                'type': 'station',
                'url': 'http://example.com/pls',
              },
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-radio-menu-radio_builtin')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('as-radio-fav-radio_builtin')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('as-radio-edit-radio_builtin')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('as-radio-delete-radio_builtin')),
        findsNothing,
        reason: '★ DA47：内置电台不属于任何用户容器，更不该给写动作',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '★ r400：加入收藏 → updateradios{container:Favorite, offset:-1, limit:0}',
      (tester) async {
        // 官方 Web 前端"加入收藏"逐字（r399 已在真 NAS 上验死：回 {}、total 0→1）。
        final r = await pumpRadio(
          tester,
          container: 'Alternative',
          responses: {
            '$_as.Radio.list': {
              'radios': [
                {
                  'id': 'radio_builtin',
                  'title': '90.7 Magic FM',
                  'type': 'station',
                  'url': 'http://example.com/pls',
                },
              ],
              'total': 1,
            },
            '$_as.Radio.updateradios': const {},
          },
        );
        await tester.tap(find.byKey(const Key('as-radio-menu-radio_builtin')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('as-radio-fav-radio_builtin')));
        await tester.pumpAndSettle();
        final c = callOf(r.t, '$_as.Radio', 'updateradios');
        expect(c['container'], 'Favorite');
        expect(c['offset'], -1, reason: '追加（官方前端逐字）');
        expect(c['limit'], 0, reason: '追加时段长为 0');
        final json = c['radios_json'] as String;
        expect(json.contains('90.7 Magic FM'), isTrue);
        expect(json.contains('http://example.com/pls'), isTrue);
        expect(json.contains('"id"'), isFalse, reason: '记录只带 title/desc/url');
        expect(c.containsKey('radio_json'), isFalse);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '★ r400：取消收藏 → 段替换{container:Favorite, offset:行号, limit:1, []}',
      (tester) async {
        // 真机对照：`offset:-1/limit:0` 去删会回 101 ⇒ 取消收藏必须也是"段替换"。
        final r = await pumpRadio(
          tester,
          container: 'Favorite',
          responses: {
            '$_as.Radio.list': {
              'radios': [
                {
                  'id': 'radio_fav1',
                  'title': '第一条收藏',
                  'type': 'station',
                  'url': 'http://example.com/1',
                },
                {
                  'id': 'radio_fav2',
                  'title': '第二条收藏',
                  'type': 'station',
                  'url': 'http://example.com/2',
                },
              ],
              'total': 2,
            },
            '$_as.Radio.updateradios': const {},
          },
        );
        await tester.tap(find.byKey(const Key('as-radio-menu-radio_fav2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('as-radio-unfav-radio_fav2')));
        await tester.pumpAndSettle();
        final c = callOf(r.t, '$_as.Radio', 'updateradios');
        expect(c['container'], 'Favorite', reason: '★ 写的是收藏容器，不是 UserDefined');
        expect(c['offset'], 1, reason: '第二条 ⇒ 段起 1（行号来自**本页**列表）');
        expect(c['limit'], 1);
        expect(c['radios_json'], '[]', reason: '取消收藏 = 这一段替换成空数组');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('能力表缺 Radio API → 未安装空态，且**不发** Radio.list 请求', (tester) async {
      final r = await pumpRadio(tester, withRadio: false, responses: const {});
      expect(find.byKey(const Key('as-not-installed')), findsOneWidget);
      expect(find.text('还没有电台'), findsNothing);
      expect(
        r.t.calls.any((c) => c['api'] == '$_as.Radio'),
        isFalse,
        reason: '缺能力位就不该发注定 102 的探测',
      );
    });

    testWidgets('网络失败 → 电台加载失败 + 重试（与空态/未安装区分）', (tester) async {
      final r = await pumpRadio(
        tester,
        offline: {'$_as.Radio.list'},
        responses: const {},
      );
      expect(find.text('电台加载失败'), findsOneWidget);
      expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
      expect(find.text('还没有电台'), findsNothing);

      r.t.offlineApis.clear();
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('还没有电台'), findsOneWidget);
    });

    testWidgets('无权限（160）→ 说权限，不是"加载失败"', (tester) async {
      final t = PathTransport(const {}, {...FakeTransport.table, ...asTable()})
        ..failures['$_as.Radio.list'] = 160;
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c = ProviderContainer(
        overrides: [audioApiProvider.overrideWithValue(AudioStationApi(api))],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: AudioRadioPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('as-no-privilege')), findsOneWidget);
      expect(find.text('这个账号没有使用 Audio Station 的权限'), findsOneWidget);
      expect(find.text('电台加载失败'), findsNothing);
    });
  });

  // ⑥b 音乐库入口门控 + Genre/Folder 标签页回归
  group('音乐库入口门控 + Genre/Folder 回归', () {
    testWidgets('有 Radio 能力位 → 电台入口在；点了进电台页', (tester) async {
      await pumpLibrary(
        tester,
        responses: {'$_as.Radio.list': radiosPayload()},
      );
      // ★ r482：电台入口从顶栏搬进「更多」菜单 ⇒ 先开菜单再点（判据不变）
      await tester.tap(find.byKey(const Key('as-home-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-radio')), findsOneWidget);
      await tester.tap(find.byKey(const Key('as-radio')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('as-radio-container-SHOUTcast')),
        findsOneWidget,
      );
    });

    testWidgets('能力表缺 Radio → 入口隐藏（缺失→隐藏，不发探测）', (tester) async {
      final t = await pumpLibrary(tester, withRadio: false);
      // 进菜单看：**菜单里也没有**（缺失→隐藏，且不发探测）
      await tester.tap(find.byKey(const Key('as-home-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-radio')), findsNothing);
      await tester.tapAt(const Offset(20, 20)); // 收菜单
      await tester.pumpAndSettle();
      expect(t.calls.any((c) => c['api'] == '$_as.Radio'), isFalse);
    });

    testWidgets('有 WebPlayer 能力位 → 队列入口在；点了进队列页', (tester) async {
      await pumpLibrary(
        tester,
        responses: {'$_as.WebPlayer.getplaylist': webQueuePayload()},
      );
      await tester.tap(find.byKey(const Key('as-home-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-webqueue')), findsOneWidget);
      await tester.tap(find.byKey(const Key('as-webqueue')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-webqueue-empty')), findsOneWidget);
    });

    testWidgets('能力表缺 WebPlayer → 队列入口隐藏，且不发探测', (tester) async {
      final t = await pumpLibrary(tester, withWebPlayer: false);
      await tester.tap(find.byKey(const Key('as-home-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-webqueue')), findsNothing);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(t.calls.any((c) => c['api'] == '$_as.WebPlayer'), isFalse);
    });

    testWidgets('Genre 标签页：空的流派 → 流派空态（回归）', (tester) async {
      await pumpLibrary(
        tester,
        responses: {
          '$_as.Genre.list': {'genres': [], 'total': 0},
        },
      );
      await tester.tap(find.byKey(const Key('as-tab-genre')));
      await tester.pumpAndSettle();
      expect(find.text('还没有流派'), findsOneWidget);
    });

    testWidgets('Folder 标签页：网络失败 → 音乐库加载失败 + 网络提示（回归）', (tester) async {
      await pumpLibrary(tester, offline: {'$_as.Folder.list'});
      await tester.tap(find.byKey(const Key('as-tab-folder')));
      await tester.pumpAndSettle();
      expect(find.text('音乐库加载失败'), findsOneWidget);
      expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
      expect(find.text('这个文件夹是空的'), findsNothing);
    });

    testWidgets('Folder 标签页：无权限（160）→ 权限文案，不是"加载失败"（回归）', (tester) async {
      final t = PathTransport(const {}, {...FakeTransport.table, ...asTable()})
        ..failures['$_as.Folder.list'] = 160;
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c = ProviderContainer(
        overrides: [audioApiProvider.overrideWithValue(AudioStationApi(api))],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: AudioPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('as-tab-folder')));
      await tester.pumpAndSettle();
      expect(find.text('这个账号没有使用 Audio Station 的权限'), findsOneWidget);
      expect(find.text('音乐库加载失败'), findsNothing);
    });
  });

  // ⑦ 作曲家（`Composer:list` 真机取证 → 与 Album/Artist/Genre 同级）
  group('作曲家（Composer）', () {
    test('listComposers：v2、root composers、path composer.cgi、真实作曲家名', () async {
      final (audio, t) = await boot(
        responses: {
          '$_as.Composer.list': {
            'composers': [
              {'name': 'Aaron Kamin'},
              {'name': 'Adam Levine'},
            ],
            'total': 2,
          },
        },
      );
      final page = await audio.listComposers();
      final call = callOf(t, '$_as.Composer', 'list');
      expect(call['version'], '2');
      expect(call['offset'], 0);
      expect(t.pathFor('$_as.Composer'), 'AudioStation/composer.cgi');
      expect(page.items.map((e) => e.name), ['Aaron Kamin', 'Adam Levine']);
      expect(page.total, 2);
    });

    test('能力表只给 v1 时收敛到 v1（真机 v1 已取证）', () async {
      final t = PathTransport(const {}, {
        ...FakeTransport.table,
        ...asTable(),
        '$_as.Composer': {
          'path': 'AudioStation/composer.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      await AudioStationApi(api).listComposers();
      expect(callOf(t, '$_as.Composer', 'list')['version'], '1');
      expect(t.pathFor('$_as.Composer'), 'AudioStation/composer.cgi');
    });

    test(
      'composerCoverUrl：getcover + composer_name（官方 getCgiImgMapping）',
      () async {
        final (audio, _) = await boot();
        final url = audio.composerCoverUrl('Aaron Kamin');
        expect(url.contains('/AudioStation/cover.cgi?'), isTrue, reason: url);
        expect(url.contains('method=getcover'), isTrue, reason: url);
        expect(
          url.contains(
            'composer_name=${Uri.encodeQueryComponent('Aaron Kamin')}',
          ),
          isTrue,
          reason: url,
        );
        // 作曲家走 getcover（维度键），不是 getsongcover（id）
        expect(
          Uri.parse(url).queryParameters.containsKey('id'),
          isFalse,
          reason: url,
        );
      },
    );

    testWidgets('作曲家标签页：真机作曲家上屏', (tester) async {
      await pumpLibrary(
        tester,
        responses: {
          '$_as.Composer.list': {
            'composers': [
              {'name': 'Aaron Kamin'},
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-tab-composer')));
      await tester.pumpAndSettle();
      expect(find.text('Aaron Kamin'), findsOneWidget);
    });

    testWidgets('作曲家标签页空态 → "还没有作曲家"（不借用"艺术家"）', (tester) async {
      await pumpLibrary(
        tester,
        responses: {
          '$_as.Composer.list': {'composers': [], 'total': 0},
        },
      );
      await tester.tap(find.byKey(const Key('as-tab-composer')));
      await tester.pumpAndSettle();
      expect(find.text('还没有作曲家'), findsOneWidget);
      expect(find.text('还没有艺术家'), findsNothing);
    });
  });

  // ⑧ 在线歌词搜索（`LyricsSearch:searchlyrics` 真机取证）
  group('在线歌词搜索（LyricsSearch:searchlyrics）', () {
    test('方法名逐字 searchlyrics、参数 title+artist、回包 data.lyrics', () async {
      final (audio, t) = await boot(
        responses: {
          '$_as.LyricsSearch.searchlyrics': {'lyrics': 'Sample lyric line one'},
        },
      );
      final text = await audio.searchLyrics(
        title: 'Demo Song',
        artist: 'Demo Artist',
      );
      final call = callOf(t, '$_as.LyricsSearch', 'searchlyrics');
      expect(call['version'], '2');
      expect(call['title'], 'Demo Song');
      expect(call['artist'], 'Demo Artist');
      expect(text, 'Sample lyric line one');
      expect(t.pathFor('$_as.LyricsSearch'), 'AudioStation/lyrics_search.cgi');
    });
  });

  // ⑨ 内嵌封面 = ID3 `APIC`（权威载体）+ 三级回落
  group('内嵌封面（ID3 APIC）+ 三级回落', () {
    test('曲目内嵌级：ID3v2.3 的 APIC 帧解析出真实图片（权威载体）', () {
      final bytes = _id3ApicTag(
        _png,
        mime: 'image/png',
        title: 'Demo Song',
        artist: 'Demo Artist',
      );
      final cover = extractMediaCover(
        MediaCoverBytes(prefix: bytes, fileSize: bytes.length),
        MediaKind.audio,
        'mp3',
      );
      expect(cover, isNotNull);
      expect(cover!.source, 'id3v2.3/APIC');
      expect(cover.mime, 'image/png');
      expect(cover.bytes, _png);
    });

    test('只有 TIT2/TPE1（没有 APIC）→ null，不吐垃圾', () {
      final bytes = _id3TextTag(title: 'Demo Song', artist: 'Demo Artist');
      expect(
        extractMediaCover(
          MediaCoverBytes(prefix: bytes, fileSize: bytes.length),
          MediaKind.audio,
          'mp3',
        ),
        isNull,
      );
    });

    testWidgets('三级回落 ① 有内嵌 APIC → 用内嵌，服务端封面不参与', (tester) async {
      await _pumpCover(
        tester,
        request: _coverKey(),
        cover: MediaCover(
          bytes: _png,
          mime: 'image/png',
          source: 'id3v2.3/APIC',
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('cover-server-fallback')), findsNothing);
    });

    testWidgets('三级回落 ② 没有内嵌 → 退服务器封面（Cover.getsongcover）', (tester) async {
      await _pumpCover(tester, request: _coverKey(), cover: null);
      expect(find.byKey(const Key('cover-server-fallback')), findsOneWidget);
    });

    testWidgets('三级回落 ③ 都拿不到 → 明确占位图标（不是空白）', (tester) async {
      // DA86（r427）：`AudioCoverImage` 现在必须拿会话/API 才能取封面字节
      // ⇒ 需要 ProviderScope（这里显式给"未连接"，仍旧只验占位分支）。
      await tester.pumpWidget(
        ProviderScope(
          overrides: [audioApiProvider.overrideWithValue(null)],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: AudioCoverImage(
                key: Key('cover-placeholder'),
                identity: 'music_1',
                url: null,
                fallbackIcon: Icons.music_note_outlined,
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('cover-placeholder')), findsOneWidget);
      expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  // ⑩ 服务端播放队列（`WebPlayer:getplaylist` 真机取证；真名不是 get）
  group('服务端播放队列（WebPlayer:getplaylist）', () {
    test('无参调用、方法名逐字 getplaylist、v1、path web_player.cgi', () async {
      final (audio, t) = await boot(
        responses: {'$_as.WebPlayer.getplaylist': webQueuePayload()},
      );
      final q = await audio.getWebPlayerQueue();
      final call = callOf(t, '$_as.WebPlayer', 'getplaylist');
      expect(call['version'], '1');
      // 真机无参 → 不许有臆造参数（只有 api/version/method/_sid）
      expect(call.keys.toSet(), {'api', 'version', 'method', '_sid'});
      expect(t.pathFor('$_as.WebPlayer'), 'AudioStation/web_player.cgi');
      expect(q.mode, 'normal');
      expect(q.shuffle, 0);
      expect(q.isShuffled, isFalse);
      expect(q.total, 0);
      expect(q.isEmpty, isTrue);
      expect(q.timestamp, 1789993283);
    });

    testWidgets('空队列 → 空态；mode/shuffle 如实展示；timestamp 不上屏', (tester) async {
      await pumpWebQueue(
        tester,
        responses: {'$_as.WebPlayer.getplaylist': webQueuePayload()},
      );
      expect(find.byKey(const Key('as-webqueue-empty')), findsOneWidget);
      expect(find.text('服务端播放队列是空的'), findsOneWidget);
      expect(find.text('顺序播放'), findsOneWidget);
      expect(find.text('随机播放：关'), findsOneWidget);
      // timestamp 是内部值 → 不上屏
      expect(find.textContaining('1789993283'), findsNothing);
    });

    testWidgets('非空队列 → title 上屏、id 不上屏；当前项有指示', (tester) async {
      await pumpWebQueue(
        tester,
        responses: {
          '$_as.WebPlayer.getplaylist': {
            'current': 1,
            'mode': 'normal',
            'shuffle': 1,
            'total': 2,
            'timestamp': 1789993283,
            'songs': [
              {'id': 'music_1', 'title': 'Demo Song', 'path': '/music/a.mp3'},
              {'id': 'music_2', 'title': 'Hello', 'path': '/music/b.mp3'},
            ],
          },
        },
      );
      expect(find.text('Demo Song'), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('music_1'), findsNothing, reason: 'id 是内部值，不上屏');
      expect(find.text('随机播放：开'), findsOneWidget);
      expect(find.byKey(const Key('as-webqueue-song-music_2')), findsOneWidget);
      // current=1 → 第二行有"正在播放"指示
      expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
      expect(find.byKey(const Key('as-webqueue-empty')), findsNothing);
    });

    testWidgets('能力表缺 WebPlayer → 不支持空态，且**不发**请求', (tester) async {
      final t = await pumpWebQueue(tester, withWebPlayer: false);
      expect(find.byKey(const Key('as-webqueue-unsupported')), findsOneWidget);
      expect(find.text('这台 NAS 的 Audio Station 不支持播放队列'), findsOneWidget);
      expect(
        t.calls.any((c) => c['api'] == '$_as.WebPlayer'),
        isFalse,
        reason: '缺能力位就不该发注定 102 的探测',
      );
    });

    testWidgets('网络失败 → 加载失败 + 重试（不渲染成空态）', (tester) async {
      final t = await pumpWebQueue(
        tester,
        offline: {'$_as.WebPlayer.getplaylist'},
      );
      expect(find.text('播放队列加载失败'), findsOneWidget);
      expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
      expect(find.byKey(const Key('as-webqueue-empty')), findsNothing);

      t.offlineApis.clear();
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('as-webqueue-empty')), findsOneWidget);
    });
  });
}

// ---------------------------------------------------------------- 内嵌封面夹具

/// 1×1 透明 PNG。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMB'
  'AQDJ/pLvAAAAAElFTkSuQmCC',
);

Uint8List _syncSafe(int n) => Uint8List.fromList([
  (n >> 21) & 0x7f,
  (n >> 14) & 0x7f,
  (n >> 7) & 0x7f,
  n & 0x7f,
]);

Uint8List _asciiBytes(String s) => Uint8List.fromList(ascii.encode(s));

/// ID3v2.3 帧：4 字节 id + 4 字节**非** syncsafe 长度 + 2 字节 flags + body。
Uint8List _frame(String id, Uint8List body) {
  final size = body.length;
  final b = BytesBuilder()
    ..add(_asciiBytes(id))
    ..add([
      (size >> 24) & 0xff,
      (size >> 16) & 0xff,
      (size >> 8) & 0xff,
      size & 0xff,
    ])
    ..add(const [0, 0])
    ..add(body);
  return b.toBytes();
}

Uint8List _id3Tag(List<Uint8List> frames) {
  final body = BytesBuilder();
  for (final f in frames) {
    body.add(f);
  }
  final bytes = body.toBytes();
  return Uint8List.fromList([
    0x49,
    0x44,
    0x33, // "ID3"
    0x03,
    0x00, // v2.3.0
    0x00, // flags
    ..._syncSafe(bytes.length),
    ...bytes,
  ]);
}

Uint8List _textFrame(String id, String text) =>
    _frame(id, Uint8List.fromList([0x00, ...latin1.encode(text)]));

/// APIC 帧体：enc=0(latin1) + mime + NUL + pictureType + 空描述 + NUL + 图字节。
Uint8List _apicFrame(String mime, Uint8List image, {int type = 3}) {
  final b = BytesBuilder()
    ..addByte(0x00)
    ..add(latin1.encode(mime))
    ..addByte(0x00)
    ..addByte(type)
    ..addByte(0x00) // 空描述 + NUL
    ..add(image);
  return _frame('APIC', b.toBytes());
}

Uint8List _id3ApicTag(
  Uint8List image, {
  String mime = 'image/png',
  String title = '',
  String artist = '',
}) => _id3Tag([
  if (title.isNotEmpty) _textFrame('TIT2', title),
  if (artist.isNotEmpty) _textFrame('TPE1', artist),
  _apicFrame(mime, image),
]);

Uint8List _id3TextTag({String title = '', String artist = ''}) => _id3Tag([
  if (title.isNotEmpty) _textFrame('TIT2', title),
  if (artist.isNotEmpty) _textFrame('TPE1', artist),
]);

MediaCoverKey _coverKey() => const MediaCoverKey(
  cacheKey: 'music_1|0|0',
  uri:
      'https://nas.example.com:5001/webapi/entry.cgi?api=SYNO.FileStation.Download',
  kind: MediaKind.audio,
  extension: 'mp3',
);

/// 复刻 `audio_song_page.dart` `_SongHeader` 的**三级回落**组合：
/// `MediaCoverImage(内嵌) → AudioCoverImage(服务器封面) → 图标占位`。
Future<void> _pumpCover(
  WidgetTester tester, {
  required MediaCoverKey? request,
  required MediaCover? cover,
}) async {
  final container = ProviderContainer(
    overrides: [mediaCoverProvider.overrideWith((ref, key) async => cover)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: MediaCoverImage(
            request: request,
            fallback: const AudioCoverImage(
              key: Key('cover-server-fallback'),
              identity: 'music_1',
              url:
                  'https://nas.example.com:5001/webapi/AudioStation/cover.cgi'
                  '?method=getsongcover&id=music_1',
              fallbackIcon: Icons.music_note_outlined,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}
