// G2 批次：Audio Station 11 项缺口的离线验证（接口层 + 页面层）。
//
// 覆盖行：A7 A8 A10 A12 A14 A19 B6 B11 B12 D2 D4。
// 全部**离线 mock**（`FakeTransport`），不碰真机；真机只读证据见
// `docs/audio-gaps-implementation-report.md`。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/features/audio/audio_gaps_page.dart';
import 'package:synhub/src/features/audio/audio_offline_store.dart';
import 'package:drift/native.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatStoreProvider;
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/features/audio/audio_cast.dart';
import 'package:synhub/src/features/audio/audio_cast_page.dart';
import 'package:synhub/src/features/audio/audio_equalizer.dart';
import 'package:synhub/src/features/audio/audio_labels.dart';
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/media/audio_lyrics.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_remote_page.dart';
import 'package:synhub/src/features/audio/audio_song_page.dart';
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/media/media_playback_store.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _as = 'SYNO.AudioStation';

/// 能力表（含本批新增的 `Tag` / `Download`）。
const _asTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  // C4：远程播放器（真实 path/版本来自 `weblib/AudioStation/AudioStation.api`）
  '$_as.RemotePlayer': {
    'path': 'AudioStation/remote_player.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  '$_as.RemotePlayerStatus': {
    'path': 'AudioStation/remote_player_status.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
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
  '$_as.Playlist': {
    'path': 'AudioStation/playlist.cgi',
    'minVersion': 1,
    'maxVersion': 3,
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
  '$_as.Stream': {
    'path': 'AudioStation/stream.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  '$_as.Pin': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  // 真机 `SYNO.API.Info` 里 Tag 走 entry.cgi（webapi5 插件）。
  '$_as.Tag': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  '$_as.Download': {
    'path': 'AudioStation/download.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Map<String, dynamic> _song({
  String id = 'music_1',
  String title = '示例歌曲',
  String artist = '示例歌手',
  String album = '十一月的萧邦',
  Object rating = 0,
}) => {
  'id': id,
  'path': '/volume1/music/$title.mp3',
  'type': 'file',
  'title': title,
  'artist': artist,
  'album': album,
  'additional': {
    'song_tag': {
      'title': title,
      'artist': artist,
      'album': album,
      'album_artist': artist,
      'composer': artist,
      'genre': 'Pop',
      'year': 2005,
      'track': 3,
    },
    'song_audio': {
      'duration': 227,
      'bitrate': 320000,
      'frequency': 44100,
      'channel': 2,
      'filesize': 9090909,
    },
    'song_rating': {'rating': rating},
  },
};

/// 假播放器：既实现 [AudioStationPlayer]，也实现 [AudioGaplessControls]
/// （B12 需要的是"引擎支持 gapless"这条可选能力）。
class _GapFakePlayer implements AudioStationPlayer, AudioGaplessControls {
  final played = <String>[];
  final seeks = <Duration>[];
  final gaplessCalls = <bool>[];
  final _changes = StreamController<void>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  bool _playing = false;
  bool _gapless = true;
  String? _current;
  int _index = -1;
  List<AudioQueueEntry> _queue = const [];
  bool _shuffle = false;
  AudioRepeatMode _repeat = AudioRepeatMode.off;
  Duration _pos = Duration.zero;
  Duration? _dur;

  @override
  String? get currentUrl => _current;

  @override
  bool get playing => _playing;

  @override
  int get currentIndex => _index;

  @override
  int get queueLength => _queue.length;

  @override
  List<AudioQueueEntry> get queue => _queue;

  @override
  bool get shuffleEnabled => _shuffle;

  @override
  AudioRepeatMode get repeatMode => _repeat;

  @override
  Duration get position => _pos;

  @override
  Duration? get duration => _dur;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  bool get gaplessEnabled => _gapless;

  @override
  Future<void> setGapless(bool enabled) async {
    _gapless = enabled;
    gaplessCalls.add(enabled);
    _changes.add(null);
  }

  @override
  Future<void> play(String url) =>
      playQueue([AudioQueueEntry(id: url, url: url)]);

  @override
  Future<void> playQueue(
    List<AudioQueueEntry> entries, {
    int startIndex = 0,
  }) async {
    if (entries.isEmpty) return;
    _queue = entries;
    final start = startIndex.clamp(0, entries.length - 1);
    _index = start;
    _current = entries[start].url;
    played.add(_current!);
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _changes.add(null);
  }

  @override
  Future<void> resume() async {
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _current = null;
    _index = -1;
    _changes.add(null);
  }

  @override
  Future<void> next() async {
    if (_queue.isEmpty) return;
    _index = (_index + 1).clamp(0, _queue.length - 1);
    _current = _queue[_index].url;
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> previous() async {
    if (_queue.isEmpty) return;
    _index = (_index - 1).clamp(0, _queue.length - 1);
    _current = _queue[_index].url;
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _pos = position;
    _position.add(position);
  }

  @override
  Future<void> setShuffle(bool enabled) async {
    _shuffle = enabled;
    _changes.add(null);
  }

  @override
  Future<void> setRepeat(AudioRepeatMode mode) async {
    _repeat = mode;
    _changes.add(null);
  }
}

/// 把 [AudioSongDto] 变成 `Song.getinfo` 回包里的一条（r644 用）。
Map<String, dynamic> _songFor(AudioSongDto song) => {
  'id': song.id,
  'title': song.title,
  'artist': song.artist,
  'path': song.path,
  'type': 'file',
  'duration': 200,
  'filesize': 1000,
};

typedef _Harness = ({
  FakeTransport t,
  ProviderContainer c,
  _GapFakePlayer player,
  InMemoryAudioOfflineStore offline,
});

/// 计数用的假歌词源：永远返回**带时间轴**的一份（r472 自动匹配用）。
class _CountingTimedSource implements LyricsSource {
  int searches = 0;

  @override
  Future<List<LyricCandidate>> search(LyricsQuery query) async {
    searches++;
    return const <LyricCandidate>[
      LyricCandidate(
        id: 1,
        trackName: '示例歌曲',
        artistName: '示例歌手',
        syncedLyrics: '[00:01.00]first\n[00:05.00]second',
      ),
    ];
  }

  @override
  Future<LyricCandidate?> fetchById(int id) async => null;
}

Future<_Harness> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  List<Object> moreOverrides = const [],
  MediaPlaybackStore? store,
  /// ★ r644：按**请求参数**给不同回包（`Song.getinfo` 要按 id 返回不同的歌）。
  Map<String, dynamic>? Function(Map<String, dynamic> params)? onCall,
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._asTable})
    ..onCall = onCall;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final player = _GapFakePlayer();
  final offline = InMemoryAudioOfflineStore();
  final c = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(AudioStationApi(api)),
      audioStationPlayerProvider.overrideWithValue(player),
      audioOfflineStoreProvider.overrideWithValue(offline),
      mediaPlaybackStoreProvider.overrideWithValue(
        store ?? InMemoryMediaPlaybackStore(),
      ),
      ...moreOverrides,
    ].cast(),
  );
  addTearDown(c.dispose);
  // ★ 视口用真机竖向高度（≈800dp），**只加高不加宽**：单曲页第 274 轮多了一块
  // 播放视觉特效，600 高会把播放按钮/歌词段挤出懒加载视口 —— `find.byKey`
  // 默认跳过离屏子树、`tester.tap` 打在屏外会**静默不命中**
  // （本轮 audio_g2_test 5 条因此红过：按钮没点到 ⇒ 位置心跳根本没跑）。
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: c, player: player, offline: offline);
}

Map<String, dynamic> _call(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

/// 直接用接口层（不起页面）：假传输 + 已登录会话。
Future<({AudioStationApi api, FakeTransport t})> _api() async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._asTable});
  final web = DsmWebApi(t);
  await web.discover();
  await web.login(account: 'a', password: 'b');
  return (api: AudioStationApi(web), t: t);
}

void main() {
  // ============================================================ 纯函数 / 存储
  group('A10/B6 本地收听记录（纯函数 + 存储）', () {
    test('audioMarkPlayed：命中 +1、刷新时间、清空旧断点', () {
      final r = audioMarkPlayed(
        const AudioPlayRecord(
          id: 'music_1',
          title: '示例歌曲',
          count: 2,
          lastPlayedMs: 100,
          positionMs: 5000,
          durationMs: 9000,
        ),
        id: 'music_1',
        nowMs: 777,
      );
      expect(r.count, 3);
      expect(r.lastPlayedMs, 777);
      expect(r.positionMs, 0, reason: '重新起播 → 旧断点作废');
      expect(r.durationMs, 0);
      expect(r.title, '示例歌曲');
    });

    test('audioMarkPosition：只改断点，不改命中次数', () {
      final r = audioMarkPosition(
        const AudioPlayRecord(id: 'music_1', count: 2, lastPlayedMs: 100),
        id: 'music_1',
        positionMs: 60000,
        durationMs: 200000,
      );
      expect(r.count, 2);
      expect(r.lastPlayedMs, 100);
      expect(r.positionMs, 60000);
      expect(r.durationMs, 200000);
    });

    test('audioResumePositionMs：太靠前 / 贴近结尾 / 无记录 都不续播', () {
      expect(audioResumePositionMs(null), 0);
      expect(
        audioResumePositionMs(
          const AudioPlayRecord(id: 'a', positionMs: 9000, durationMs: 999999),
        ),
        0,
        reason: '不到 10 秒不值得续',
      );
      expect(
        audioResumePositionMs(
          const AudioPlayRecord(id: 'a', positionMs: 95000, durationMs: 100000),
        ),
        0,
        reason: '距结尾 < 15 秒 → 一打开就是"放完了"',
      );
      expect(
        audioResumePositionMs(
          const AudioPlayRecord(id: 'a', positionMs: 60000, durationMs: 200000),
        ),
        60000,
      );
      expect(
        audioResumePositionMs(
          const AudioPlayRecord(id: 'a', positionMs: 60000),
        ),
        60000,
        reason: '总长未知时只做下限判断',
      );
    });

    test('audioRecentlyPlayed / audioMostPlayed 的排序与过滤', () {
      const a = AudioPlayRecord(id: 'a', count: 1, lastPlayedMs: 300);
      const b = AudioPlayRecord(id: 'b', count: 5, lastPlayedMs: 100);
      const c = AudioPlayRecord(id: 'c', count: 0, lastPlayedMs: 0);
      expect(audioRecentlyPlayed([a, b, c]).map((r) => r.id).toList(), [
        'a',
        'b',
      ], reason: '没播放过的（lastPlayedMs=0）不进最近播放');
      expect(audioMostPlayed([a, b, c]).map((r) => r.id).toList(), [
        'b',
        'a',
      ], reason: 'hit_count 倒序（官方 hit_count DESC 同语义）');
    });

    test('InMemoryMediaPlaybackStore：history 读写往返', () async {
      final s = InMemoryMediaPlaybackStore();
      expect(await s.loadAudioHistory(), isEmpty);
      await s.saveAudioHistory({
        'music_1': const AudioPlayRecord(
          id: 'music_1',
          title: '示例歌曲',
          count: 2,
          lastPlayedMs: 1,
          positionMs: 2,
          durationMs: 3,
        ),
      });
      final back = await s.loadAudioHistory();
      expect(back['music_1']!.count, 2);
      expect(back['music_1']!.positionMs, 2);
      expect(back['music_1']!.title, '示例歌曲');
    });

    test('AppMediaPlaybackStore：history 落 JSON 并原样读回（注入临时文件）', () async {
      final dir = await Directory.systemTemp.createTemp('as_g2_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/media_playback.json');
      final s = AppMediaPlaybackStore(fileResolver: () async => file);
      await s.saveAudioHistory({
        'music_1': const AudioPlayRecord(
          id: 'music_1',
          title: '示例歌曲',
          count: 3,
          lastPlayedMs: 10,
          positionMs: 20,
          durationMs: 30,
        ),
      });
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect((raw['audioHistory'] as Map)['music_1']['count'], 3);
      final fresh = AppMediaPlaybackStore(fileResolver: () async => file);
      final back = await fresh.loadAudioHistory();
      expect(back['music_1']!.positionMs, 20);
      // 清空 → JSON 里不留空对象
      await fresh.saveAudioHistory({});
      final raw2 =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(raw2.containsKey('audioHistory'), isFalse);
    });
  });

  // ============================================================ 接口层
  group('A7 最近添加（Album.list sort_by=time DESC limit=50）', () {
    test('请求参数逐字对齐官方 ApiEnumerator 且能解析', () async {
      final r = await _api();
      final page = await r.api.listAlbums(
        sortBy: 'time',
        descending: true,
        limit: audioRecentlyAddedLimit,
      );
      final call = _call(r.t, '$_as.Album', 'list');
      expect(call['sort_by'], 'time');
      expect(call['sort_direction'], 'DESC');
      expect(call['limit'], audioRecentlyAddedLimit);
      expect(page.total, 0);
    });
  });

  group('A8 Random100（Song.list sort_by=random limit=100）', () {
    test('请求参数逐字对齐官方 ApiEnumerator', () async {
      final r = await _api();
      await r.api.listSongs(
        sortBy: 'random',
        limit: audioRandom100Limit,
        offset: 0,
      );
      final call = _call(r.t, '$_as.Song', 'list');
      expect(call['sort_by'], 'random');
      expect(call['limit'], audioRandom100Limit);
    });
  });

  group('A12 首字母过滤（filter=<字母>）', () {
    test('Album.list 带 filter', () async {
      final r = await _api();
      await r.api.listAlbums(filter: 'A');
      expect(_call(r.t, '$_as.Album', 'list')['filter'], 'A');
    });

    test('Artist.list 带 filter', () async {
      final r = await _api();
      await r.api.listArtists(filter: 'A');
      expect(_call(r.t, '$_as.Artist', 'list')['filter'], 'A');
    });

    test('filter 为空 / null 时**不发**该参数', () async {
      final r = await _api();
      await r.api.listAlbums();
      expect(_call(r.t, '$_as.Album', 'list').containsKey('filter'), isFalse);
    });
  });

  group('A19 在线标签（Tag.list v1 需 album + album_artist）', () {
    test('两个必填参数都发，并解析 items', () async {
      final r = await _api();
      final res = await r.api.tagList(
        album: 'Best In Me',
        albumArtist: 'Demo Song',
      );
      final call = _call(r.t, '$_as.Tag', 'list');
      expect(call['version'], '1');
      expect(call['album'], 'Best In Me');
      expect(call['album_artist'], 'Demo Song');
      expect(res.isEmpty, isTrue);
    });

    test('tagInfo 失败（1100）→ null 而不是抛', () async {
      final t = FakeTransport(
        {'$_as.Tag.getinfo': const {}},
        {...FakeTransport.table, ..._asTable},
      );
      t.failures['$_as.Tag.getinfo'] = 1100;
      final web = DsmWebApi(t);
      await web.discover();
      await web.login(account: 'a', password: 'b');
      final api = AudioStationApi(web);
      expect(await api.tagInfo(type: 'song', id: 'music_1'), isNull);
      expect(_call(t, '$_as.Tag', 'getinfo')['type'], 'song');
    });
  });

  group('D4 分享（Song.getsharing / setsharing v2）', () {
    test('getSharing 失败（405）→ null（界面给"未开启共享"）', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._asTable});
      t.failures['$_as.Song.getsharing'] = 405;
      final web = DsmWebApi(t);
      await web.discover();
      await web.login(account: 'a', password: 'b');
      expect(await AudioStationApi(web).getSharing('music_1'), isNull);
    });

    test('getSharing 成功 → 解析 enable_sharing + url', () async {
      final r = await _api();
      final info = await r.api.getSharing('music_1');
      expect(_call(r.t, '$_as.Song', 'getsharing')['id'], 'music_1');
      expect(info, isNotNull);
      expect(info!.url, '');
    });

    test('setSharing 发 enable_sharing 布尔', () async {
      final r = await _api();
      await r.api.setSharing('music_1', enable: true);
      final call = _call(r.t, '$_as.Song', 'setsharing');
      expect(call['version'], '2');
      expect(call['id'], 'music_1');
      expect(call['enable_sharing'], true);
    });
  });

  group('D2 打包下载（Download.download v1）', () {
    test(
      'downloadUrl：download.cgi + method=download + 逗号串 id + _sid',
      () async {
        final r = await _api();
        final url = r.api.downloadUrl([
          'music_1',
          'music_2',
        ], now: DateTime.fromMillisecondsSinceEpoch(1700000000000));
        expect(url.contains('/webapi/AudioStation/download.cgi?'), isTrue);
        expect(url.contains('api=SYNO.AudioStation.Download'), isTrue);
        expect(url.contains('version=1'), isTrue);
        expect(url.contains('method=download'), isTrue);
        expect(url.contains('id=music_1%2Cmusic_2'), isTrue);
        expect(url.contains('_sid='), isTrue);
      },
    );

    test('downloadBytes 走 getBytes（可拿到字节）', () async {
      final r = await _api();
      r.t.downloadBytes = [0x50, 0x4B, 0x03, 0x04, 9];
      final bytes = await r.api.downloadBytes(['music_1']);
      expect(bytes, [0x50, 0x4B, 0x03, 0x04, 9]);
      // DA86（r427）后，封面图也走 `getBytes`（同一个字节通道）⇒ 断言必须
      // 收敛到**下载接口本身**，否则会被展示请求污染（假红/假绿都危险）。
      final dl = r.t.downloads
          .where((u) => !u.contains('SYNO.AudioStation.Cover'))
          .toList();
      expect(dl.single.contains('method=download'), isTrue);
    });

    test('looksLikeServerStub：真机 17 字节 {"success": true} 是桩；zip 不是', () {
      expect(looksLikeServerStub(utf8.encode('{"success": true}')), isTrue);
      expect(looksLikeServerStub(const []), isTrue);
      expect(looksLikeServerStub([0x50, 0x4B, 0x03, 0x04]), isFalse);
    });
  });

  // ============================================================ 页面层
  group('A7/A8/A10 页面入口（首页「更多」菜单）', () {
    testWidgets('A7：最近添加页发 sort_by=time 并渲染专辑', (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Album.list': {
            'albums': [
              {'name': '十一月的萧邦', 'album_artist': '示例歌手'},
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-home-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-home-recently-added')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final call = _call(r.t, '$_as.Album', 'list');
      expect(call['sort_by'], 'time');
      expect(call['sort_direction'], 'DESC');
      expect(call['limit'], 50);
      expect(find.byKey(const Key('as-recently-added-list')), findsOneWidget);
      expect(find.text('十一月的萧邦'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('A8：随机 100 首页发 sort_by=random limit=100 并可点开单曲', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {
            'songs': [_song()],
            'total': 1,
          },
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await tester.tap(find.byKey(const Key('as-home-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-home-random-100')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final call = _call(r.t, '$_as.Song', 'list');
      expect(call['sort_by'], 'random');
      expect(call['limit'], 100);
      expect(find.byKey(const Key('as-random-100-list')), findsOneWidget);
      await tester.tap(find.byKey(const Key('as-random-song-music_1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AudioSongDetailPage), findsOneWidget);
    });

    testWidgets('A10：最近/最常播放读本地记录并分档排序', (tester) async {
      final store = InMemoryMediaPlaybackStore(
        audioHistory: {
          'music_a': const AudioPlayRecord(
            id: 'music_a',
            title: 'A',
            count: 1,
            lastPlayedMs: 900,
          ),
          'music_b': const AudioPlayRecord(
            id: 'music_b',
            title: 'B',
            count: 7,
            lastPlayedMs: 100,
          ),
        },
      );
      final r = await _pump(
        tester,
        const AudioPlayedPage(mode: AudioPlayedMode.recently),
        store: store,
      );
      expect(find.byKey(const Key('as-played-list-recently')), findsOneWidget);
      final tiles = tester
          .widgetList<DesignRowTile>(find.byType(DesignRowTile))
          .map((t) => (t.title as Text).data)
          .toList();
      expect(tiles, ['A', 'B'], reason: '最近播放按时间倒序');
      expect(find.byKey(const Key('as-played-music_b')), findsOneWidget);

      await _pump(
        tester,
        const AudioPlayedPage(mode: AudioPlayedMode.most),
        store: store,
      );
      await tester.pump(const Duration(milliseconds: 200));
      final mostTiles = tester
          .widgetList<DesignRowTile>(find.byType(DesignRowTile))
          .map((t) => (t.title as Text).data)
          .toList();
      expect(mostTiles, ['B', 'A'], reason: '最常播放按 hit_count 倒序');
      expect(r.c, isNotNull);
    });

    testWidgets('A10：没有记录 → 空态（不是空白页）', (tester) async {
      await _pump(tester, const AudioPlayedPage(mode: AudioPlayedMode.most));
      expect(find.byKey(const Key('as-played-empty-most')), findsOneWidget);
    });
  });

  group('A12 首字母索引条', () {
    testWidgets('专辑页点 A → Album.list 带 filter=A；再点 A → 取消', (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Album.list': {
            'albums': [
              {'name': 'Abbey Road', 'album_artist': 'The Beatles'},
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-tab-album')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-alpha-album')), findsOneWidget);
      await tester.tap(find.byKey(const Key('as-alpha-album-A')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_call(r.t, '$_as.Album', 'list')['filter'], 'A');
      // 再点同一个字母 = 取消过滤
      await tester.tap(find.byKey(const Key('as-alpha-album-A')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_call(r.t, '$_as.Album', 'list').containsKey('filter'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('歌曲页**没有**首字母条（官方 filter 只对 Album/Artist）', (tester) async {
      await _pump(tester, const AudioPage());
      expect(find.byKey(const Key('as-alpha-album')), findsNothing);
      expect(find.byKey(const Key('as-alpha-artist')), findsNothing);
    });
  });

  group('★ r644 DA241：换歌之后歌词面板必须跟着换', () {
    /// 真机（2026-10-23）：屏上曲名已是 `Demo Song`，署名却仍是**上一首**的
    /// `Favorite Girl · Justin Bieber`（像素 `docs/evidence-r644/09_stale_lyrics_after_switch.png`）。
    /// 根因：`_LyricsSection` 的 State 存着 `_lookup`（以及"已查过缓存/已自动匹配"
    /// 两个标记），换歌只换 `widget.song`、同一棵元素原地复用 ⇒ 上一首的歌词留着。
    testWidgets('① 上一首的歌词不许留在下一首的屏上', (tester) async {
      const a = AudioSongDto(
        id: 'music_1',
        path: '/m/a.mp3',
        title: '第一首',
        artist: '甲',
      );
      const b = AudioSongDto(
        id: 'music_2',
        path: '/m/b.mp3',
        title: '第二首',
        artist: '乙',
      );
      // 只为第一首准备缓存：切到第二首之后，屏上就不该再有这份正文。
      final cache = InMemoryLyricsCache({
        const LyricsQuery(
          title: '第一首',
          artist: '甲',
          duration: Duration(seconds: 200),
          identity: 'music_1',
        ).cacheKey: jsonEncode({
          'version': LyricsLookup.cacheSchemaVersion,
          'chosen': {
            'id': 7,
            'trackName': '第一首',
            'artistName': '甲',
            'duration': 200.0,
            'syncedLyrics': '[00:01.00]STALE-LINE\n[00:05.00]second',
          },
        }),
      });
      await _pump(
        tester,
        const AudioSongDetailPage(
          songId: 'music_1',
          title: '第一首',
          queue: [a, b],
        ),
        responses: {
          '$_as.Lyrics.getlyrics': {'lyrics': ''},
        },
        onCall: (params) {
          if (params['id'] == 'music_2') {
            return {
              'songs': [_songFor(b)],
            };
          }
          if (params['id'] == 'music_1') {
            return {
              'songs': [_songFor(a)],
            };
          }
          return null;
        },
        moreOverrides: [
          mediaLyricsSourceProvider.overrideWithValue(_CountingTimedSource()),
          mediaLyricsCacheProvider.overrideWithValue(cache),
        ],
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('STALE-LINE'), findsOneWidget, reason: '前提：第一首的缓存歌词在屏上');

      // ★ 真机现象（2026-10-23）走的是"原地换歌"：`widget.song` 变了但元素没重建，
      //   `_LyricsSection` 的 State 被复用 ⇒ 第一首的歌词留在第二首屏上。
      //   这里来回切两次（第一次把两个 provider 都预热，第二次才是真机的稳态）。
      Future<void> switchTo(String id) async {
        await tester.tap(find.byKey(const Key('as-queue-entry')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(Key('as-queue-item-$id')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      await switchTo('music_2');
      expect(
        find.text('STALE-LINE'),
        findsNothing,
        reason: 'DA241：换歌之后上一首的歌词必须消失（否则就是张冠李戴）',
      );
      await switchTo('music_1');
      expect(
        find.text('STALE-LINE'),
        findsOneWidget,
        reason: '回到第一首，它的缓存歌词该回来',
      );
      await switchTo('music_2');
      expect(
        find.text('STALE-LINE'),
        findsNothing,
        reason: 'DA241 反向：不带 key 时 State 会被复用 ⇒ 上一首的歌词又留在屏上',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('r472 · 歌词自动匹配（用户 r468「歌词不随进度」）', () {
    testWidgets('服务端只有纯文本 → 打开单曲页**静默**补一次公开源', (tester) async {
      final source = _CountingTimedSource();
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          // 服务端给的是**纯文本**（没有时间轴）—— 这正是真机上 Demo Song 的情形
          '$_as.Lyrics.getlyrics': {'lyrics': 'first line\nsecond line'},
        },
        moreOverrides: [
          mediaLyricsSourceProvider.overrideWithValue(source),
          mediaLyricsCacheProvider.overrideWithValue(InMemoryLyricsCache()),
        ],
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        source.searches,
        greaterThanOrEqualTo(1),
        reason: 'r472：纯文本歌词下，打开页面要静默补一次带时间轴的公开源',
      );
      expect(tester.takeException(), isNull, reason: '自动匹配失败/异常都不许冒到界面');
    });

    testWidgets('★ 反向：服务端已是带时间轴歌词 → **不多打一次网络**', (tester) async {
      final source = _CountingTimedSource();
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': '[00:01.00]first\n[00:05.00]second'},
        },
        moreOverrides: [
          mediaLyricsSourceProvider.overrideWithValue(source),
          mediaLyricsCacheProvider.overrideWithValue(InMemoryLyricsCache()),
        ],
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        source.searches,
        0,
        reason: 'r472：屏上已经有时间轴了，就不该再联网（省流量、也避免换来换去）',
      );
    });
  });

  group('A14 多选批量评分', () {
    testWidgets('长按进多选 → 批量评分发逗号串 id', (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {
            'songs': [_song(), _song(id: 'music_2', title: '晴天')],
            'total': 2,
          },
        },
      );
      expect(find.byKey(const Key('as-selection-bar')), findsNothing);
      await tester.longPress(find.byKey(const Key('as-song-music_1')));
      await tester.pump();
      expect(find.byKey(const Key('as-selection-bar')), findsOneWidget);
      expect(find.text('已选 1 首'), findsOneWidget);
      await tester.tap(find.byKey(const Key('as-selection-star-4')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final call = _call(r.t, '$_as.Song', 'setrating');
      expect(call['id'], 'music_1');
      expect(call['rating'], 4);
      expect(call['version'], '2');
      // 评完退出多选
      expect(find.byKey(const Key('as-selection-bar')), findsNothing);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('多选态下点一行是"勾选"而不是打开单曲页', (tester) async {
      await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {
            'songs': [_song(), _song(id: 'music_2', title: '晴天')],
            'total': 2,
          },
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
        },
      );
      await tester.longPress(find.byKey(const Key('as-song-music_1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('as-song-music_2')));
      await tester.pump();
      expect(find.text('已选 2 首'), findsOneWidget);
      expect(find.byType(AudioSongDetailPage), findsNothing);
      await tester.tap(find.byKey(const Key('as-selection-cancel')));
      await tester.pump();
      expect(find.byKey(const Key('as-selection-bar')), findsNothing);
    });
  });

  group('A19 在线标签段（单曲页）', () {
    testWidgets('点查询 → Tag.list 带 album+album_artist 并渲染标签', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
          '$_as.Tag.list': {
            'items': [
              {
                'album': '十一月的萧邦',
                'album_artist': '示例歌手',
                'cover': '',
                'genre': ['Mandopop'],
                'release_url': 'https://api.discogs.com/releases/1',
                'year': '2005',
              },
            ],
            'total': 1,
          },
        },
      );
      // 在线标签段在页面最下面（ListView 惰性构建）→ 先滚到它。
      //
      // ★ 第 263 轮定位：`find.byType(Scrollable).first` **本来就是对的**
      //   （页面里 4 个 Scrollable 中，标签段的祖先链只有 1 个 —— 身体
      //   `ListView`，`AxisDirection.down`，rect=(0,56,800,1400)，max=112）。
      //   真正的问题是 **滚完没推进一帧**：`scrollUntilVisible` 只在
      //   `dragUntilVisible` 的**拖动循环**里 pump，而标签段早在
      //   `ListView` 的 cacheExtent 内就 build 出来了（`exists=1`）⇒
      //   循环一次都不跑，末尾只调 `Scrollable.ensureVisible`
      //   （零时长 = `jumpTo`）——**不 pump**。于是 `position.pixels` 已是
      //   112、渲染树却仍停在旧偏移：`tap` 按旧布局算出 Offset(742.9, 1408.0)，
      //   而屏高 1400 ⇒ 落在屏外静默不命中（A19 红的根因）。
      //   ⇒ 滚动后补一帧，并当场断言"真的可命中"（钉机制，不钉结果文本）。
      // ★ r631：在线标签段从"页面最下面"搬进了「歌曲信息」面板（技术/管理内容
      //   收进菜单）。所以先开面板，再在**面板自己的滚动容器**里滚到它。
      await tester.tap(find.byKey(const Key('as-qa-info')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('as-song-info-sheet')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('as-tag-search')),
        400,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('as-song-info-sheet')),
              matching: find.byType(Scrollable),
            )
            .last,
      );
      await tester.pump();
      expect(
        find.byKey(const Key('as-tag-search')).hitTestable(),
        findsOneWidget,
        reason: '滚到之后必须真的可命中，否则 tap 打在屏外（见上注释）',
      );
      expect(find.byKey(const Key('as-tag-hint')), findsOneWidget);
      expect(
        r.t.calls.any((c) => c['api'] == '$_as.Tag'),
        isFalse,
        reason: '不点不查（不平白联网）',
      );
      await tester.tap(find.byKey(const Key('as-tag-search')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final call = _call(r.t, '$_as.Tag', 'list');
      expect(call['album'], '十一月的萧邦');
      expect(call['album_artist'], '示例歌手');
      expect(find.byKey(const Key('as-tag-list')), findsOneWidget);
      expect(find.text('十一月的萧邦'), findsWidgets);
    });

    testWidgets('缺 album_artist → 整段不渲染（发了也只会 101）', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [
              {
                ..._song(),
                'additional': {
                  'song_tag': {'album': '只有专辑名'},
                },
              },
            ],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      expect(find.byKey(const Key('as-tag-search')), findsNothing);
    });
  });

  group('B6 断点续播', () {
    testWidgets('起播时 seek 回上次位置，并把命中次数 +1', (tester) async {
      final store = InMemoryMediaPlaybackStore(
        audioHistory: {
          'music_1': const AudioPlayRecord(
            id: 'music_1',
            title: '示例歌曲',
            count: 2,
            lastPlayedMs: 111,
            positionMs: 60000,
            durationMs: 200000,
          ),
        },
      );
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        store: store,
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await tester.tap(find.byKey(const Key('as-play')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.player.seeks, contains(const Duration(minutes: 1)));
      final rec = (await store.loadAudioHistory())['music_1']!;
      expect(rec.count, 3, reason: '每次起播命中 +1');
      expect(rec.positionMs, 0, reason: '重新从断点开始播 → 旧断点清掉');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('位置 5 秒落一次盘（心跳）', (tester) async {
      final store = InMemoryMediaPlaybackStore();
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        store: store,
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await tester.tap(find.byKey(const Key('as-play')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 播放器喂一个真实位置，再推进 5 秒心跳
      await r.player.seek(const Duration(seconds: 42));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      final rec = (await store.loadAudioHistory())['music_1']!;
      expect(rec.positionMs, 42000);
      expect(rec.durationMs, 0);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('B11 睡眠定时（纯客户端）', () {
    testWidgets('设置 15 分钟 → 显示剩余；取消 → 复位', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      expect(find.textContaining('睡眠定时'), findsOneWidget);
      await tester.tap(find.byKey(const Key('as-sleep-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-sleep-15')));
      await tester.pump();
      expect(find.text('睡眠定时 · 15:00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('as-sleep-cancel')));
      await tester.pump();
      expect(find.text('睡眠定时'), findsOneWidget);
    });

    testWidgets('到点 → 暂停播放 + 提示', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await tester.tap(find.byKey(const Key('as-play')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.player.playing, isTrue);
      r.c
          .read(audioSleepTimerProvider.notifier)
          .start(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(r.player.playing, isFalse);
      expect(find.byKey(const Key('as-sleep-done')), findsOneWidget);
      expect(r.c.read(audioSleepTimerProvider), isNull);
      await tester.pump(const Duration(seconds: 5));
    });

    // ★ DA31（r386 真机撞到 / 同轮修）：上一条用例之所以"绿"，是因为**播放页一直挂着**
    // —— `ref.listen` 顺手把播放暂停了。真机上用户一旦离开播放页（页面 State 销毁），
    // 那条监听就没了，而 `audioSleepTimerProvider` 是**常驻**的：定时器照走，
    // 到点却没人暂停（真机读数见 `docs/android-ui-audit-r386.md` §S4）。
    // 这条用例**故意一个 widget 都不挂**，只用 container + provider，钉死
    // "暂停必须由计时器自己完成"。
    // ★ DA73（r413 **真机**撞到 / 当轮修）：DA31 只把"暂停"搬进常驻控制器，
    // **"复位"仍写在页面的 `ref.listen` 里** ⇒ 到点那一刻页面不在场就没人消费
    // `Duration.zero`：再进单曲页会看到一个**早已到点、实际没有定时器在跑**的假状态
    // （真机像素逐字 `Sleep timer · --` ＋ 仍在的 `Cancel`）。
    // 这条用例把"到点时页面没挂载 → 之后再进页面"整条路径走一遍。
    testWidgets('★ DA73：到点时页面没挂载 ⇒ 之后再进单曲页必须复位（不许停在 `--` + Cancel）', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      // ① 设 2 秒，行里出现 `Cancel`
      r.c
          .read(audioSleepTimerProvider.notifier)
          .start(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const Key('as-sleep-cancel')), findsOneWidget);
      // ② **卸载页面**（模拟用户离开单曲页，但容器/常驻 provider 还在）
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      // ③ 到点：页面不在场
      await tester.pump(const Duration(seconds: 3));
      expect(
        r.c.read(audioSleepTimerProvider),
        Duration.zero,
        reason: '前置：到点状态确实产生了',
      );
      // ④ 再进单曲页（**同一个容器**）
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: r.c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      // ⑤ 判据：复位（没有 Cancel、标签回到纯 `睡眠定时`）且**不重播旧提示**
      expect(find.byKey(const Key('as-sleep-cancel')), findsNothing);
      expect(find.text('睡眠定时'), findsOneWidget);
      expect(find.byKey(const Key('as-sleep-done')), findsNothing);
      expect(r.c.read(audioSleepTimerProvider), isNull);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('★ DA31：播放页没挂载时，睡眠定时到点也必须暂停播放', (tester) async {
      final player = _GapFakePlayer();
      final c = ProviderContainer(
        overrides: [
          audioStationPlayerProvider.overrideWithValue(player),
        ].cast(),
      );
      addTearDown(c.dispose);
      // 先让播放器处于播放态（不经过任何页面）
      await player.play('https://nas/stream/music_1.mp3');
      expect(player.playing, isTrue, reason: '前置：播放器在放');

      c.read(audioSleepTimerProvider.notifier).start(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(
        player.playing,
        isFalse,
        reason: 'DA31：没有任何页面挂着时，到点也必须暂停',
      );
      expect(c.read(audioSleepTimerProvider), Duration.zero);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('B12 无缝播放', () {
    testWidgets('默认开：进页面把 gapless=true 推给引擎；关掉 → 推 false', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      expect(r.player.gaplessCalls, [true]);
      expect(r.c.read(audioGaplessProvider), isTrue);
      r.c.read(audioGaplessProvider.notifier).setEnabled(false);
      await tester.pump();
      expect(r.player.gaplessCalls, [true, false]);
      expect(r.player.gaplessEnabled, isFalse);
    });
  });

  group('D2 下载（能力位门控 + 桩识别 + 落盘）', () {
    testWidgets('服务端未开启下载 → 明确说，且**不发**请求', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
          '$_as.Info.getinfo': {
            'settings': {'enable_download': false},
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-song-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-song-download')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('as-download-disabled')), findsOneWidget);
      // 能力位关 ⇒ 不许发**下载类**请求；封面（`Cover.*`）是展示所需，不在其列
      final dl = r.t.downloads
          .where((u) => !u.contains('SYNO.AudioStation.Cover'))
          .toList();
      expect(dl, isEmpty, reason: '能力位关 → 不发注定无载荷的请求（封面除外）');
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('D6：歌曲菜单"在 File Station 中显示"→ 打开该曲所在目录',
        (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await tester.tap(find.byKey(const Key('as-song-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-song-show-in-files')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // `_song()` 的 path 是 /volume1/music/<title>.mp3 ⇒ 目录应为 /volume1/music
      final page = tester.widget<FileBrowsePage>(find.byType(FileBrowsePage));
      expect(page.initialPath, '/volume1/music');
      expect(tester.takeException(), isNull);
      // 清掉 FileStation 侧的异步加载，避免测试尾部报未处理异常
      await tester.pump(const Duration(seconds: 4));
      r.t.calls.clear();
    });

    testWidgets('服务端返回桩（JSON 而非 zip）→ 如实说，不写假文件', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
          '$_as.Info.getinfo': {'audio_enable_download': true},
        },
      );
      r.t.downloadBytes = utf8.encode('{"success": true}');
      await tester.tap(find.byKey(const Key('as-song-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-song-download')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('as-download-nocontent')), findsOneWidget);
      expect(await r.offline.ids(), isEmpty);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('真 zip 字节 → 落盘 + 提示 + 离线集合更新', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
          '$_as.Info.getinfo': {'audio_enable_download': true},
        },
      );
      r.t.downloadBytes = [0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4];
      await tester.tap(find.byKey(const Key('as-song-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-song-download')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('as-download-ok')), findsOneWidget);
      expect(await r.offline.ids(), contains('music_1'));
      // 下载完 → 页面上出现"已下载到本机"标记（离线集合驱动）
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('as-downloaded-badge')), findsOneWidget);
      expect(
        r.t.downloads
            .where((u) => !u.contains('SYNO.AudioStation.Cover'))
            .single
            .contains('AudioStation/download.cgi'),
        isTrue,
      );
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('D4 分享（单曲页）', () {
    testWidgets('privilege.sharing=false → 弹窗说明未开启', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
          '$_as.Info.getinfo': {
            'privilege': {'sharing': false},
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-song-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-song-share')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-share-no-privilege')), findsOneWidget);
      // ★ r343 D52：这里原先断言的是**泄漏原文**（`privilege.sharing=false`）——
      //   用例把缺陷钉住了（§2.0.29 同族："修复自带的用例红了 ⇒ 修复没完成"）。
      //   现在断言用户文案，并**反向**断言服务端字段名不许出现在界面上；
      //   原始字段值仍在 `Info.getinfo` 回包/日志里（修的是文案不是数据）。
      expect(find.textContaining('服务端未开启共享'), findsOneWidget);
      expect(find.textContaining('privilege.sharing'), findsNothing);
    });

    testWidgets('sharing=true + 已有链接 → 弹窗给出 URL', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
          '$_as.Info.getinfo': {
            'privilege': {'sharing': true},
          },
          '$_as.Song.getsharing': {
            'enable_sharing': true,
            'url': 'https://nas.example/audio/shared/music_1',
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-song-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-song-share')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-share-dialog')), findsOneWidget);
      expect(
        find.text('https://nas.example/audio/shared/music_1'),
        findsOneWidget,
      );
      expect(_call(r.t, '$_as.Song', 'getsharing')['id'], 'music_1');
      expect(find.text('关闭共享'), findsOneWidget);
    });
  });

  // ==================================================== C6 播放列表写（UI）
  group('C6 播放列表写入口（create / rename / delete）', () {
    Future<void> openPlaylistTab(WidgetTester tester, _Harness r) async {
      await tester.tap(find.byKey(const Key('as-tab-playlist')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    testWidgets('C6：首页菜单「新建播放列表」→ 发 Playlist/create（空表）', (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Playlist.list': {
            'playlists': [
              {'id': 'pl_1', 'name': '示例歌曲合集', 'type': 'normal'},
            ],
            'total': 1,
          },
          '$_as.Playlist.create': {
            'playlists': [
              {'id': 'pl_new', 'name': '新列表'},
            ],
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-home-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-home-new-playlist')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('as-playlist-name-field')),
        '新列表',
      );
      await tester.tap(find.byKey(const Key('as-playlist-name-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final call = _call(r.t, '$_as.Playlist', 'create');
      expect(call['name'], '新列表');
      expect(call['library'], 'personal');
      expect(call['songs'], '', reason: '官方"新建"先建空表');
      expect(tester.takeException(), isNull);
    });

    testWidgets('C6：播放列表行菜单 → 重命名（Playlist/rename {id,new_name}）',
        (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Playlist.list': {
            'playlists': [
              {'id': 'pl_1', 'name': '旧名字', 'type': 'normal'},
            ],
            'total': 1,
          },
          '$_as.Playlist.rename': const {},
        },
      );
      await openPlaylistTab(tester, r);
      await tester.tap(find.byKey(const Key('as-playlist-menu-pl_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-playlist-rename-pl_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('as-playlist-name-field')),
        '新名字',
      );
      await tester.tap(find.byKey(const Key('as-playlist-name-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final call = _call(r.t, '$_as.Playlist', 'rename');
      expect(call['id'], 'pl_1');
      expect(call['new_name'], '新名字');
      expect(tester.takeException(), isNull);
    });

    testWidgets('C6：播放列表行菜单 → 删除（二次确认后发 Playlist/delete）',
        (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Playlist.list': {
            'playlists': [
              {'id': 'pl_2', 'name': '要删的', 'type': 'normal'},
            ],
            'total': 1,
          },
          '$_as.Playlist.delete': const {},
        },
      );
      await openPlaylistTab(tester, r);
      await tester.tap(find.byKey(const Key('as-playlist-menu-pl_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-playlist-delete-pl_2')));
      await tester.pumpAndSettle();
      // 二次确认
      expect(find.textContaining('要删的'), findsWidgets);
      await tester.tap(find.byKey(const Key('as-playlist-delete-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_call(r.t, '$_as.Playlist', 'delete')['id'], 'pl_2');
      expect(tester.takeException(), isNull);
    });
  });

  // ==================================== r442 加歌（`Playlist/updatesongs` 追加用法）
  group('r442 单曲页「加入播放列表」', () {
    testWidgets('★ r442：菜单入口 → 选列表 → `updatesongs(offset=已有曲数, limit=0)` ＋ 成功提示',
        (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Playlist.list': {
            'playlists': [
              {'id': 'pl_1', 'name': '示例歌曲集', 'library': 'personal'},
              {'id': 'pl_2', 'name': '共享集', 'library': 'shared'},
            ],
            'total': 2,
          },
          '$_as.Playlist.getinfo': {
            'playlists': [
              {
                'id': 'pl_1',
                'name': '示例歌曲集',
                'additional': {
                  'songs': [
                    {'id': 'music_9'},
                    {'id': 'music_8'},
                    {'id': 'music_7'},
                  ],
                  'songs_total': 3,
                },
              },
            ],
          },
          '$_as.Playlist.updatesongs': const {},
        },
      );
      await tester.tap(find.byKey(const Key('as-song-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-song-add-to-playlist')));
      await tester.pumpAndSettle();
      // 选择器把两个库的列表都列出来（智能列表排除）
      expect(find.byKey(const Key('as-playlist-pick-pl_1')), findsOneWidget);
      expect(find.byKey(const Key('as-playlist-pick-pl_2')), findsOneWidget);
      await tester.tap(find.byKey(const Key('as-playlist-pick-pl_1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final u = _call(r.t, '$_as.Playlist', 'updatesongs');
      expect(u['id'], 'pl_1');
      expect(u['offset'], 3, reason: 'offset = `songs_total`（真机契约）');
      expect(u['limit'], 0);
      expect(u['songs'], 'music_1');
      expect(find.textContaining('已加入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('★★★ DA96：重复加歌 ⇒ 提示「有重复的歌曲」，**不是**「账号已锁定」',
        (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Playlist.list': {
            'playlists': [
              {'id': 'pl_1', 'name': '示例歌曲集', 'library': 'personal'},
            ],
            'total': 1,
          },
          '$_as.Playlist.getinfo': {
            'playlists': [
              {
                'id': 'pl_1',
                'name': '示例歌曲集',
                'additional': {
                  'songs': [
                    {'id': 'music_1'},
                  ],
                  'songs_total': 1,
                },
              },
            ],
          },
          '$_as.Playlist.updatesongs': const {},
        },
      );
      // 真机读数：重复加同一首 ⇒ `{"error":{"code":411}}`（`AUDIO_ERR_DUPLICATE_SONGS`）
      r.t.failures['$_as.Playlist.updatesongs'] = 411;
      await tester.tap(find.byKey(const Key('as-song-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-song-add-to-playlist')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-playlist-pick-pl_1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('有重复的歌曲'), findsOneWidget);
      expect(
        find.textContaining('账号已锁定'),
        findsNothing,
        reason: 'DA96：修前这里是通用表的 Auth 文案 —— 与事实相反',
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ================================================== A11 音乐库切换（个人/共享）
  group('A11 音乐库切换 → 所有 *.list 带 library=', () {
    testWidgets('A11：切到「共享音乐库」后歌曲/专辑/播放列表都发 library=shared',
        (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {'songs': [_song()], 'total': 1},
          '$_as.Playlist.list': {'playlists': [], 'total': 0},
        },
      );
      // 初始：不带 library
      expect(_call(r.t, '$_as.Song', 'list').containsKey('library'), isFalse);
      // 切到共享库
      await tester.tap(find.byKey(const Key('as-library-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-library-shared')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.c.read(audioLibraryProvider), AudioLibrary.shared,
          reason: 'provider state should change');
      expect(_call(r.t, '$_as.Song', 'list')['library'], 'shared');
      // 播放列表标签页也带 library
      await tester.tap(find.byKey(const Key('as-tab-playlist')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_call(r.t, '$_as.Playlist', 'list')['library'], 'shared');
      expect(tester.takeException(), isNull);
    });

    testWidgets('A11：切回「个人音乐库」发 library=personal', (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {'songs': [_song()], 'total': 1},
        },
      );
      await tester.tap(find.byKey(const Key('as-library-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-library-personal')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_call(r.t, '$_as.Song', 'list')['library'], 'personal');
      // 再切回默认 → 不带该参数
      await tester.tap(find.byKey(const Key('as-library-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-library-default')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_call(r.t, '$_as.Song', 'list').containsKey('library'), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  // ============================ A17 智能列表：官方 Android 只能改名（须回传规则）
  group('A17 智能播放列表改名（updatesmart 回传规则）', () {
    testWidgets('A17：智能列表改名 → 先 getinfo(rules) 再 updatesmart（不是 rename）',
        (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Playlist.list': {
            'playlists': [
              {'id': 'smart_1', 'name': '高评分', 'type': 'smart'},
            ],
            'total': 1,
          },
          '$_as.Playlist.getinfo': {
            'playlists': [
              {
                'id': 'smart_1',
                'name': '高评分',
                'type': 'smart',
                'additional': {
                  'rules_conjunction': 'and',
                  'rules': [
                    {'field': 'rating', 'operator': 'greater', 'value': '3'},
                  ],
                },
              },
            ],
          },
          '$_as.Playlist.updatesmart': const {},
          '$_as.Playlist.rename': const {},
        },
      );
      await tester.tap(find.byKey(const Key('as-tab-playlist')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-playlist-menu-smart_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-playlist-rename-smart_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('as-playlist-name-field')),
        '更高评分',
      );
      await tester.tap(find.byKey(const Key('as-playlist-name-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final info = _call(r.t, '$_as.Playlist', 'getinfo');
      expect(info['additional'], 'rules');
      final up = _call(r.t, '$_as.Playlist', 'updatesmart');
      expect(up['id'], 'smart_1');
      expect(up['new_name'], '更高评分');
      expect(up['conj_rule'], 'and', reason: '规则必须原样回传');
      expect(up['rules_json'], '[{"field":"rating","operator":"greater","value":"3"}]');
      // 绝不能走普通 rename
      final renameCalls =
          r.t.calls.where((c) => c['api'] == '$_as.Playlist' && c['method'] == 'rename');
      expect(renameCalls, isEmpty, reason: '智能列表不能用普通 rename');
      expect(tester.takeException(), isNull);
    });
  });

  // ------------------------------------------- C4 远程播放器（NAS 侧发现/控制）
  group('C4 远程播放器页（RemotePlayer list/control）', () {
    testWidgets('C4：列出设备并点 play → control {id, action:play}', (tester) async {
      final r = await _pump(
        tester,
        const AudioRemotePage(),
        responses: {
          '$_as.RemotePlayer.list': {
            'players': [
              {'id': 'p1', 'name': 'Living Room TV'},
            ],
          },
          '$_as.RemotePlayer.control': const {},
        },
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('as-remote-list')), findsOneWidget);
      expect(find.text('Living Room TV'), findsOneWidget);
      await tester.tap(find.byKey(const Key('as-remote-play-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final c = _call(r.t, '$_as.RemotePlayer', 'control');
      expect(c['id'], 'p1');
      expect(c['action'], 'play');
      expect(tester.takeException(), isNull);
    });

    testWidgets('C1：推当前曲目 → updateplaylist 官方形态（PLAY_NOW 语义）',
        (tester) async {
      final r = await _pump(
        tester,
        const AudioRemotePage(),
        responses: {
          '$_as.RemotePlayer.list': {
            'players': [
              {'id': 'p1', 'name': 'TV', 'type': 'upnp'},
            ],
          },
          '$_as.RemotePlayer.updateplaylist': const {},
        },
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 本机"正在播放"的曲目：streamUrl 必然带 id=<song.id>
      await r.player.playQueue([
        const AudioQueueEntry(
          id: 'music_9',
          url: 'https://nas:5001/webapi/AudioStation/stream.cgi'
              '?api=SYNO.AudioStation.Stream&version=1&method=stream&id=music_9',
        ),
      ]);
      await tester.pump();
      await tester.tap(find.byKey(const Key('as-remote-push-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final c = _call(r.t, '$_as.RemotePlayer', 'updateplaylist');
      expect(c['id'], 'p1');
      expect(c['songs'], 'music_9');
      expect(c['offset'], 0);
      expect(c['limit'], 1);
      // 148 轮起：队列可用 ⇒ 走官方整队列语义（updated_index=-1）
      expect(c['updated_index'], -1);
      expect(c['keep_shuffle_order'], 'false');

      final ctl = _call(r.t, '$_as.RemotePlayer', 'control');
      expect(ctl['id'], 'p1');
      expect(
        ctl['action'],
        'play',
        reason: 'DA104：推完必须让远端开始播，别只改队列',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('C1：只有单曲（无队列）→ 回退推当前曲目，id 取自 URL',
        (tester) async {
      final r = await _pump(
        tester,
        const AudioRemotePage(),
        responses: {
          '$_as.RemotePlayer.list': {
            'players': [
              {'id': 'p1', 'name': 'TV'},
            ],
          },
          '$_as.RemotePlayer.updateplaylist': const {},
        },
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await r.player.play(
        'https://nas/webapi/AudioStation/stream.cgi?api=SYNO.AudioStation.Stream'
        '&method=stream&id=music_7',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('as-remote-push-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final c = _call(r.t, '$_as.RemotePlayer', 'updateplaylist');
      expect(c['songs'], 'music_7');
      expect(c['limit'], 1);
      expect(c['updated_index'], 0, reason: '回退路径＝当前曲目成为第 0 首');

      final ctl = _call(r.t, '$_as.RemotePlayer', 'control');
      expect(ctl['id'], 'p1');
      expect(
        ctl['action'],
        'play',
        reason: 'DA104：推完必须让远端开始播，别只改队列',
      );
    });

    testWidgets('C1：有队列 → 推**整队列**（官方 PLAY_NOW 语义）', (tester) async {
      final r = await _pump(
        tester,
        const AudioRemotePage(),
        responses: {
          '$_as.RemotePlayer.list': {
            'players': [
              {'id': 'p1', 'name': 'TV'},
            ],
          },
          '$_as.RemotePlayer.updateplaylist': const {},
        },
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await r.player.playQueue([
        const AudioQueueEntry(
          id: 'music_1',
          url: 'https://nas/webapi/AudioStation/stream.cgi?id=music_1',
        ),
        const AudioQueueEntry(
          id: 'music_2',
          url: 'https://nas/webapi/AudioStation/stream.cgi?id=music_2',
        ),
      ]);
      await tester.pump();
      await tester.tap(find.byKey(const Key('as-remote-push-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final c = _call(r.t, '$_as.RemotePlayer', 'updateplaylist');
      expect(c['songs'], 'music_1,music_2');
      expect(c['limit'], 2);
      expect(c['updated_index'], -1);
      expect(c['keep_shuffle_order'], 'false');

      final ctl = _call(r.t, '$_as.RemotePlayer', 'control');
      expect(ctl['id'], 'p1');
      expect(
        ctl['action'],
        'play',
        reason: 'DA104：推完必须让远端开始播，别只改队列',
      );
    });

    testWidgets('DA104 反向：`updateplaylist` 失败时**不许**再发 play',
        (tester) async {
      final r = await _pump(
        tester,
        const AudioRemotePage(),
        responses: {
          '$_as.RemotePlayer.list': {
            'players': [
              {'id': 'p1', 'name': 'TV'},
            ],
          },
          '$_as.RemotePlayer.updateplaylist': const {},
        },
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await r.player.play(
        'https://nas/webapi/AudioStation/stream.cgi?api=SYNO.AudioStation.Stream'
        '&method=stream&id=music_7',
      );
      await tester.pump();
      r.t.failures['$_as.RemotePlayer.updateplaylist'] = 400;
      await tester.tap(find.byKey(const Key('as-remote-push-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        r.t.calls.where((c) => c['method'] == 'control'),
        isEmpty,
        reason: 'DA104 反向：队列没设成，就不许把"播"发出去',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('C1：本机没在播 → 如实提示，**不发**请求', (tester) async {
      final r = await _pump(
        tester,
        const AudioRemotePage(),
        responses: {
          '$_as.RemotePlayer.list': {
            'players': [
              {'id': 'p1', 'name': 'TV'},
            ],
          },
        },
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('as-remote-push-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('本机当前没有正在播放的曲目'), findsOneWidget);
      expect(
        r.t.calls.where((c) => c['method'] == 'updateplaylist'),
        isEmpty,
        reason: '没在播就不许凑一个假 id 发出去',
      );
    });

    testWidgets('C2：按官方 ApiRemotePlayerType 显示类型（airplay/upnp/usb）',
        (tester) async {
      await _pump(
        tester,
        const AudioRemotePage(),
        responses: {
          // ★ 根键 `players` 现已取证：`ApiRemotePlayerResponseDataVo.players`
          //   （`ApiRemotePlayerResponseVo.java:15-18`）。
          '$_as.RemotePlayer.list': {
            'players': [
              {'id': 'p1', 'name': 'TV', 'type': 'airplay'},
              {'id': 'p2', 'name': 'Box', 'type': 'upnp'},
              {'id': 'p3', 'name': 'DAC', 'type': 'usb'},
              {'id': 'p4', 'name': 'Unknown', 'type': 'future_type'},
            ],
          },
        },
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('as-remote-type-0')), findsOneWidget);
      expect(find.text('AirPlay'), findsOneWidget);
      expect(find.text('DLNA / UPnP'), findsOneWidget);
      expect(find.text('USB'), findsOneWidget);
      expect(find.text('future_type'), findsOneWidget,
          reason: '未知类型原样显示，不猜');
      expect(tester.takeException(), isNull);
    });

    testWidgets('C4：没有设备 → 空态（不是"加载失败"）', (tester) async {
      await _pump(
        tester,
        const AudioRemotePage(),
        responses: {'$_as.RemotePlayer.list': const {'players': []}},
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('as-remote-empty')), findsOneWidget);
      expect(find.text('远程播放器加载失败'), findsNothing);
    });
  });

  // ------------------------------------------------------ B10 均衡器（客户端）
  group('B10 均衡器（本机偏好 + 平台通道契约）', () {
    test('B10：本机不支持 → 零调用，不假装生效', () async {
      final bridge = _FakeEq(available: false);
      final c = ProviderContainer(
        overrides: [
          audioEqualizerBridgeProvider.overrideWithValue(bridge),
          // 设置持久化走内存库（path_provider 在纯 Dart 测试里不存在）
          chatStoreProvider.overrideWithValue(
            ChatStore(ChatDatabase(NativeDatabase.memory())),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(audioEqualizerProvider.notifier).preload();
      final st = c.read(audioEqualizerProvider);
      expect(st.loaded, isTrue);
      expect(st.available, isFalse);
      expect(bridge.applied, isEmpty, reason: '没能力就不发通道调用');
      // 没能力时 setEnabled 也不该发通道调用
      await c.read(audioEqualizerProvider.notifier).setEnabled(true);
      expect(bridge.applied, isEmpty);
    });

    test('B10：预设由平台枚举 → 选择后按名称下发（含 enabled）', () async {
      final bridge = _FakeEq(
        available: true,
        presets: const ['Normal', 'Rock'],
      );
      final c = ProviderContainer(
        overrides: [
          audioEqualizerBridgeProvider.overrideWithValue(bridge),
          chatStoreProvider.overrideWithValue(
            ChatStore(ChatDatabase(NativeDatabase.memory())),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(audioEqualizerProvider.notifier).preload();
      expect(c.read(audioEqualizerProvider).presets, ['Normal', 'Rock']);
      await c.read(audioEqualizerProvider.notifier).setEnabled(true);
      await c.read(audioEqualizerProvider.notifier).selectPreset('Rock');
      expect(bridge.applied.last['enabled'], isTrue);
      expect(bridge.applied.last['preset'], 'Rock');
      expect(c.read(audioEqualizerProvider).preset, 'Rock');
    });

    // ★ r368 修复点：EQ 必须挂在**正在播放那一路的 audio session** 上。
    // 写死 session 0（全局输出混音）在真机 LGE-AN10 / Android 12 上回
    // `ERROR_NO_INIT`（见 docs/android-ui-audit-r350.md 的 logcat 原文与
    // 本轮 `android-acceptance-closure.md`），而本机确实带着 equalizer。
    test('B10：把播放会话 id 透传到平台通道（caps + apply）', () async {
      final bridge = _FakeEq(available: true, presets: const ['Rock']);
      final c = ProviderContainer(
        overrides: [
          audioEqualizerBridgeProvider.overrideWithValue(bridge),
          audioStationPlayerProvider.overrideWithValue(
            _FakeSessionPlayer(4242),
          ),
          chatStoreProvider.overrideWithValue(
            ChatStore(ChatDatabase(NativeDatabase.memory())),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(audioEqualizerProvider.notifier).preload();
      expect(bridge.capsSessions, [4242], reason: '探测能力时要带上真会话');
      expect(c.read(audioEqualizerProvider).available, isTrue);
      await c.read(audioEqualizerProvider.notifier).setEnabled(true);
      expect(bridge.appliedSessions.last, 4242, reason: '下发时也要带同一个会话');
    });

    test('B10：没在播（会话 0）时不炸，按全局会话探测', () async {
      final bridge = _FakeEq(available: false);
      final c = ProviderContainer(
        overrides: [
          audioEqualizerBridgeProvider.overrideWithValue(bridge),
          audioStationPlayerProvider.overrideWithValue(
            _FakeSessionPlayer(null),
          ),
          chatStoreProvider.overrideWithValue(
            ChatStore(ChatDatabase(NativeDatabase.memory())),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(audioEqualizerProvider.notifier).preload();
      expect(bridge.capsSessions, [0]);
      expect(c.read(audioEqualizerProvider).available, isFalse);
      expect(bridge.applied, isEmpty);
    });

    // ★ 368：原生管道优先 —— 不依赖 Dart 拿到会话 id。
    test('B10：有原生均衡器 → 走原生管道，不碰平台通道', () async {
      final bridge = _FakeEq(available: false);
      final player = _FakeNativeEqPlayer();
      final c = ProviderContainer(
        overrides: [
          audioEqualizerBridgeProvider.overrideWithValue(bridge),
          audioStationPlayerProvider.overrideWithValue(player),
          chatStoreProvider.overrideWithValue(
            ChatStore(ChatDatabase(NativeDatabase.memory())),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(audioEqualizerProvider.notifier).preload();
      final st = c.read(audioEqualizerProvider);
      expect(player.infoCalls, 1);
      expect(st.available, isTrue, reason: '原生管道拿得到频段就算可用');
      expect(st.presets, isEmpty, reason: '原生管道不暴露平台预设名，不许编造');
      expect(bridge.capsSessions, isEmpty, reason: '原生这条路不该再碰平台通道');
      await c.read(audioEqualizerProvider.notifier).setEnabled(true);
      expect(player.enabledCalls, [true]);
      await c.read(audioEqualizerProvider.notifier).setEnabled(false);
      expect(player.enabledCalls, [true, false]);
      expect(bridge.applied, isEmpty);
    });

    test('B10：原生均衡器还没起播（拿不到参数）→ 回落平台通道，不假装可用', () async {
      final bridge = _FakeEq(available: true, presets: const ['Rock']);
      final player = _FakeNativeEqPlayer(available: false);
      final c = ProviderContainer(
        overrides: [
          audioEqualizerBridgeProvider.overrideWithValue(bridge),
          audioStationPlayerProvider.overrideWithValue(player),
          chatStoreProvider.overrideWithValue(
            ChatStore(ChatDatabase(NativeDatabase.memory())),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(audioEqualizerProvider.notifier).preload();
      final st = c.read(audioEqualizerProvider);
      expect(player.infoCalls, 1);
      expect(bridge.capsSessions, [0], reason: '回落平台通道（没会话就用 0）');
      expect(st.available, isTrue, reason: '回落那条路说可用才算可用');
      expect(st.presets, ['Rock']);
      expect(player.enabledCalls, isEmpty);
    });
  });

  // ------------------------------------------- C3 Chromecast（页面/入口行为）
  group('C3 Chromecast 页', () {
    testWidgets('C3：本机不支持 → 如实说明，且不出现投送按钮', (tester) async {
      final bridge = _FakeCast(available: false);
      await _pump(
        tester,
        const AudioCastPage(),
        moreOverrides: [audioCastBridgeProvider.overrideWithValue(bridge)],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('as-cast-unsupported')), findsOneWidget);
      expect(find.byKey(const Key('as-cast-current')), findsNothing);
      expect(bridge.calls, isEmpty, reason: '不可用时零调用');
    });

    testWidgets('C3：连接设备后才能投送；投的是本机当前曲目 URL',
        (tester) async {
      final bridge = _FakeCast(
        available: true,
        devices: const [
          {'id': 'd1', 'name': '客厅电视'},
        ],
      );
      final r = await _pump(
        tester,
        const AudioCastPage(),
        moreOverrides: [audioCastBridgeProvider.overrideWithValue(bridge)],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 未连接 → 投送按钮禁用
      var btn = tester.widget<FilledButton>(
        find.byKey(const Key('as-cast-current')),
      );
      expect(btn.onPressed, isNull, reason: '没连设备不许投送');
      await tester.tap(find.byKey(const Key('as-cast-connect-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.player.currentUrl, isNull);
      await r.player.play(
        'https://nas/webapi/AudioStation/stream.cgi?id=music_5',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('as-cast-current')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final play = bridge.calls.lastWhere((e) => e['m'] == 'play');
      expect(play['url'], 'https://nas/webapi/AudioStation/stream.cgi?id=music_5');
      expect(tester.takeException(), isNull);
    });
  });

  // ------------------------------------------------- C3 Chromecast（Dart 契约）
  group('C3 Chromecast（可用性探测 + 投送，不假装）', () {
    test('C3：本机不支持 → 连接/投送全部零调用', () async {
      final bridge = _FakeCast(available: false);
      final c = ProviderContainer(
        overrides: [audioCastBridgeProvider.overrideWithValue(bridge)],
      );
      addTearDown(c.dispose);
      await c.read(audioCastProvider.notifier).preload();
      final st = c.read(audioCastProvider);
      expect(st.loaded, isTrue);
      expect(st.available, isFalse);
      expect(await c.read(audioCastProvider.notifier).connect('d1'), isFalse);
      expect(await c.read(audioCastProvider.notifier).play('u'), isFalse);
      expect(bridge.calls, isEmpty, reason: '没能力就不许发通道调用');
    });

    test('C3：有设备 → 连接后投送（设备 id 与媒体 URL 逐字下发）', () async {
      final bridge = _FakeCast(
        available: true,
        devices: const [
          {'id': 'd1', 'name': '客厅电视'},
          {'id': 'd2', 'name': '卧室音箱'},
        ],
      );
      final c = ProviderContainer(
        overrides: [audioCastBridgeProvider.overrideWithValue(bridge)],
      );
      addTearDown(c.dispose);
      await c.read(audioCastProvider.notifier).preload();
      final st = c.read(audioCastProvider);
      expect(st.devices.map((d) => d.id).toList(), ['d1', 'd2']);
      expect(st.devices.first.name, '客厅电视');
      expect(await c.read(audioCastProvider.notifier).connect('d2'), isTrue);
      expect(c.read(audioCastProvider).connectedId, 'd2');
      // 未连接前不许投送
      expect(bridge.calls.map((e) => e['m']).toList(), ['connect']);
      expect(
        await c.read(audioCastProvider.notifier).play(
          'https://nas/webapi/AudioStation/stream.cgi?id=music_1',
          positionSeconds: 7,
        ),
        isTrue,
      );
      final play = bridge.calls.last;
      expect(play['m'], 'play');
      expect(play['url'], 'https://nas/webapi/AudioStation/stream.cgi?id=music_1');
      expect(play['positionSeconds'], 7);
      await c.read(audioCastProvider.notifier).disconnect();
      expect(c.read(audioCastProvider).connectedId, isNull);
      expect(bridge.calls.last['m'], 'disconnect');
    });
  });

  // ------------------------------------- r638 · DA231（进度零位不是破折号）
  group('r638 · DA231 进度左端读数', () {
    testWidgets('还没起播 ⇒ 左端是 `0:00`（不是 `—`），右端仍是总长', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      final cur = tester.widget<Text>(
        find.byKey(const Key('as-progress-current')),
      );
      expect(
        cur.data,
        '0:00',
        reason: 'DA231：「在开头」不是「不知道播到哪儿」',
      );
      final total = tester.widget<Text>(
        find.byKey(const Key('as-progress-remaining')),
      );
      expect(total.data, isNot('0:00'), reason: '右端是总长，不跟着归零');
    });

    test('DA231：`asPositionText` 把 0 与"未知"分开', () {
      expect(asPositionText(Duration.zero), '0:00');
      expect(asPositionText(const Duration(seconds: 83)), '1:23');
      expect(asPositionText(const Duration(seconds: 3725)), '1:02:05');
      // 防御：负数（seek 越界/引擎初值）也算"在开头"，不许印 `—`
      expect(asPositionText(const Duration(seconds: -3)), '0:00');
    });
  });
}

class _FakeEq implements AudioEqualizerBridge {
  _FakeEq({required this.available, this.presets = const []});

  final bool available;
  final List<String> presets;
  final List<Map<String, dynamic>> applied = [];
  final List<int> capsSessions = [];
  final List<int> appliedSessions = [];

  @override
  Future<Map<String, dynamic>> caps({int session = 0}) async {
    capsSessions.add(session);
    return {
      'available': available,
      'presets': presets,
    };
  }

  @override
  Future<void> apply({
    required bool enabled,
    String? preset,
    List<int>? bandLevels,
    int session = 0,
  }) async {
    appliedSessions.add(session);
    applied.add({
      'enabled': enabled,
      if (preset != null) 'preset': preset,
      if (bandLevels != null) 'bands': bandLevels,
    });
  }
}

/// 只补 `AudioSpectrumSession` 那一段的播放器假实现（其余走"不支持"实现）。
class _FakeSessionPlayer extends UnsupportedAudioStationPlayer
    implements AudioSpectrumSession {
  _FakeSessionPlayer(this._session);

  final int? _session;

  @override
  int? get androidAudioSessionId => _session;

  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream<int?>.empty();
}

/// ★ 368：带**原生均衡器**能力的播放器假实现
/// （`available=false` = 平台还没回参数，等同"没起播"）。
class _FakeNativeEqPlayer extends UnsupportedAudioStationPlayer
    implements AudioEqualizerControls {
  _FakeNativeEqPlayer({this.available = true});

  final bool available;
  final List<bool> enabledCalls = [];
  int infoCalls = 0;

  @override
  Future<AudioEqualizerInfo?> equalizerInfo() async {
    infoCalls++;
    if (!available) return null;
    return AudioEqualizerInfo(
      minDecibels: -15,
      maxDecibels: 15,
      centerFrequencies: [for (var i = 0; i < 10; i++) 31.25 * (2 << i)],
    );
  }

  @override
  Future<void> setEqualizerEnabled(bool enabled) async =>
      enabledCalls.add(enabled);
}

class _FakeCast implements AudioCastBridge {
  _FakeCast({required this.available, this.devices = const []});

  final bool available;
  final List<Map<String, dynamic>> devices;
  final List<Map<String, dynamic>> calls = [];

  @override
  Future<Map<String, dynamic>> availability() async => {
    'available': available,
    'devices': devices,
  };

  @override
  Future<void> connect(String deviceId) async =>
      calls.add({'m': 'connect', 'id': deviceId});

  @override
  Future<void> play(String mediaUrl, {int? positionSeconds}) async => calls.add({
    'm': 'play',
    'url': mediaUrl,
    if (positionSeconds != null) 'positionSeconds': positionSeconds,
  });

  @override
  Future<void> disconnect() async => calls.add({'m': 'disconnect'});
}
