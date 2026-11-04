// Audio Station 页面层离线验证（阶段二 A 第二块）。
//
// 接口层用例在 `test/audio_station_test.dart`；这里只验：
//   * 页面把请求发对了（浏览/搜索/评分/收藏/取消收藏）；
//   * 空态与错误态**区分**套件未安装 / 无权限 / 网络失败；
//   * 流式 URL 走 doc §2.3 A-1b 的 `stream.cgi/0.<ext>` 形态，播放交给可注入播放器。
import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_detail_page.dart';
import 'package:synhub/src/features/audio/audio_cast_page.dart';
import 'package:synhub/src/features/audio/audio_equalizer.dart';
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/audio/audio_pins_page.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_search_page.dart';
import 'package:synhub/src/features/audio/audio_song_page.dart';
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/media/audio_lyrics.dart'
    show
        InMemoryLyricsCache,
        LyricCandidate,
        LyricsLookup,
        LyricsQuery,
        LyricsSource,
        audioLyricsPlainTextHintText,
        mediaLyricsLookupProvider;
import 'package:synhub/src/features/media/audio_lyrics_view.dart'
    show SyncedLyricsView;
import 'package:synhub/src/features/media/media_playback_store.dart';

import 'package:synhub/src/core/i18n/l10n.dart'
    show AppText, lookupAppTextSafe, setCurrentText;
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _as = 'SYNO.AudioStation';

/// 公开源（lrclib）的假实现：离线、不碰网络（DA55 用例用）。
class _FakeLyricsSource implements LyricsSource {
  _FakeLyricsSource(this.results);

  final List<LyricCandidate> results;

  /// 逐次记录查询 —— ★ r411（DA68）的判据就是"用户点了按钮到底有没有真打源站"，
  /// 光看屏上变化分不清"重搜了但结果一样"和"根本没搜"。
  final List<LyricsQuery> searched = [];

  @override
  Future<List<LyricCandidate>> search(LyricsQuery query) async {
    searched.add(query);
    return results;
  }

  @override
  Future<LyricCandidate?> fetchById(int id) async => null;
}

const _asTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.AudioStation.Info': {
    'path': 'AudioStation/info.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
  'SYNO.AudioStation.Song': {
    'path': 'AudioStation/song.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Album': {
    'path': 'AudioStation/album.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Artist': {
    'path': 'AudioStation/artist.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.AudioStation.Genre': {
    'path': 'AudioStation/genre.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Folder': {
    'path': 'AudioStation/folder.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Playlist': {
    'path': 'AudioStation/playlist.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Lyrics': {
    'path': 'AudioStation/lyrics.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.AudioStation.LyricsSearch': {
    'path': 'AudioStation/lyrics_search.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.AudioStation.Stream': {
    'path': 'AudioStation/stream.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.AudioStation.Pin': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Map<String, dynamic> _song({
  String id = 'music_1',
  String title = '示例歌曲',
  String artist = '示例歌手',
  String album = '十一月的萧邦',
  String path = '/volume1/music/示例歌曲.mp3',
  Object rating = 0,
}) => {
  'id': id,
  'path': path,
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

/// 真机传输会把 `DioException` 包成 `DsmTransportException`
/// （见 `DirectTransport._postForm` / `TunnelTransport`），而
/// `FakeTransport.offlineKeys` 抛的是**裸** DioException，与真机不一致 ——
/// 这里按真机形态再包一层，免得"网络失败"落到 `describeAudioError` 的兜底分支。
class _NetFakeTransport extends FakeTransport {
  _NetFakeTransport(super.responses, super.apiTable);

  final offlineApis = <String>{};

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    final key = '${params['api']}.${params['method']}';
    if (offlineApis.contains(key)) {
      calls.add(params);
      throw DsmTransportException('connection error');
    }
    return super.postForm(path, params);
  }
}

/// 假播放器（`just_audio` 在 widget 测试里没有平台通道）。
///
/// 覆盖 P0-2 / P0-5 的全部接口面：队列（`playQueue` / `currentIndex` /
/// `next` / `previous`）、随机、循环、进度流与 `seek`。断言入口：
/// * [played] —— 每次起播的 URL（单曲 `play` 与队列起播都记录）；
/// * [playedQueues] —— 每次 `playQueue` 收到的队列（队列顺序断言用）；
/// * [seeks] —— `seek` 的落点。
class _FakePlayer implements AudioStationPlayer {
  final played = <String>[];
  final playedQueues = <List<AudioQueueEntry>>[];
  final seeks = <Duration>[];
  final _changes = StreamController<void>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  bool _playing = false;
  String? _current;
  int _index = -1;
  List<AudioQueueEntry> _queue = const [];
  bool _shuffle = false;
  AudioRepeatMode _repeat = AudioRepeatMode.off;
  Duration _pos = Duration.zero;
  Duration? _dur;

  /// true → `play`/`playQueue` 抛 [playError]（模拟 Media3 起播失败）
  bool failPlay = false;
  Object playError = Exception('decoder init failed');

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

  /// 测试里手动喂时长（模拟播放器报到总长）。
  void emitDuration(Duration? d) {
    _dur = d;
    _duration.add(d);
  }

  /// 测试里手动喂播放位置（模拟播放推进）。
  void emitPosition(Duration d) {
    _pos = d;
    _position.add(d);
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
    playedQueues.add(entries);
    _queue = entries;
    final start = startIndex.clamp(0, entries.length - 1);
    _index = start;
    played.add(entries[start].url);
    if (failPlay) throw playError;
    _current = entries[start].url;
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
    played.add(_current!);
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> previous() async {
    if (_queue.isEmpty) return;
    _index = (_index - 1).clamp(0, _queue.length - 1);
    _current = _queue[_index].url;
    played.add(_current!);
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    emitPosition(position);
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

/// 挂一个页面：假传输 + 覆盖音频模块的 API provider 与播放器。
/// r631：打开「歌曲信息」面板。
///
/// 技术参数（音质档位 / 流地址 / 评分 / 15 个字段）从播放器首屏搬进了这个面板
/// （用户 2026-10-23：技术参数收在菜单里）。凡是断言这些控件的用例，**先开面板**。
Future<void> _openSongInfo(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('as-qa-info')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.byKey(const Key('as-song-info-sheet')), findsOneWidget);
}

/// r631：关掉「歌曲信息」面板（面板是模态的，不关就点不到播放键）。
Future<void> _closeSongInfo(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('as-song-info-close')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<({_NetFakeTransport t, ProviderContainer c, _FakePlayer player})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  Set<String> offline = const {},
  bool noAs = false,
  bool login = true,
  List<Object> moreOverrides = const [],
  Map<String, dynamic>? Function(Map<String, dynamic> params)? onCall,
  // ★ r632：`english: true` ⇒ 真的把界面语言切成英文（**两把尺子一起切**：
  //   ① `MaterialApp.locale` + `AppText.delegate` → `context.t.*`；
  //   ② `setCurrentText(...)` → `dataText(...)` 的数据层译文表，见仪器㉑）。
  //   只切 delegate 会让"漏翻"永远测不出（`dataText` 走的是注入表，不是 delegate）。
  bool english = false,
}) async {
  if (english) {
    setCurrentText(lookupAppTextSafe(const Locale('en')));
    addTearDown(() => setCurrentText(lookupAppTextSafe(const Locale('zh'))));
  }
  final t = _NetFakeTransport(responses, {
    ...FakeTransport.table,
    if (!noAs) ..._asTable,
  });
  t.failures.addAll(failures);
  t.offlineApis.addAll(offline);
  t.onCall = onCall;
  final api = DsmWebApi(t);
  await api.discover();
  if (login) await api.login(account: 'a', password: 'b');
  final player = _FakePlayer();
  final c = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(AudioStationApi(api)),
      audioStationPlayerProvider.overrideWithValue(player),
      ...moreOverrides,
    ].cast(),
  );
  addTearDown(c.dispose);
  // ★ 视口用"真机竖向高度"（≈800dp），**只加高不加宽**（默认测试窗口是
  // 800x600；本仓 §2.0.9 同款教训）。
  //
  // 为什么必须加高：单曲页第 274 轮加了**播放视觉特效**块，600 高会把下面的
  // 歌词段/队列按钮挤到懒加载视口之外 —— `find.byKey` 默认跳过离屏子树，
  // 于是"功能没坏、测试找不到"（本轮 audio_page_test 12 条因此红过一次）。
  // 只加高：原先放得下的东西只会更放得下，不会引入新的溢出。
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        // ★ 只在 english 分支装 delegate：默认分支必须保持"没有本地化资源 ⇒
        //   回落中文"的旧行为，否则一百多条中文断言会集体变红（测试环境
        //   默认 locale 是 en_US，一装 delegate 就整页英文）。
        locale: english ? const Locale('en') : null,
        localizationsDelegates:
            english ? AppText.localizationsDelegates : null,
        // 默认分支照抄 `WidgetsApp` 自己的默认值（`[en_US]`），
        // 这样"没装 delegate"的老行为一个字都不变。
        supportedLocales:
            english ? AppText.supportedLocales : const [Locale('en', 'US')],
        home: page,
      ),
    ),
  );
  await tester.pump(); // postFrameCallback → load()
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: c, player: player);
}

Map<String, dynamic> _call(_NetFakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

void main() {
  group('音乐库：空态 / 错误态（区分未安装、无权限、网络）', () {
    testWidgets('一首歌都没有 → 空态', (tester) async {
      await _pump(tester, const AudioPage());
      expect(find.text('音乐库里还没有歌曲'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('套件未安装 → 明确说"没有安装"，不给重试按钮', (tester) async {
      await _pump(tester, const AudioPage(), noAs: true);
      expect(find.text('这台 NAS 没有安装 Audio Station'), findsOneWidget);
      expect(find.text('在 DSM「套件中心」安装 Audio Station 后即可使用'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(find.text('音乐库加载失败'), findsNothing);
      expect(find.byKey(const Key('as-not-installed')), findsOneWidget);
    });

    testWidgets('无权限（160）→ 说权限，不是"加载失败"', (tester) async {
      await _pump(tester, const AudioPage(), failures: {'$_as.Song.list': 160});
      expect(find.text('这个账号没有使用 Audio Station 的权限'), findsOneWidget);
      expect(find.text('请联系管理员授予 Audio Station 的访问权限'), findsOneWidget);
      expect(find.text('音乐库加载失败'), findsNothing);
      expect(find.byKey(const Key('as-no-privilege')), findsOneWidget);
    });

    testWidgets('网络失败 → 加载失败 + 重试（与未安装区分）', (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        offline: {'$_as.Song.list'},
      );
      expect(find.text('音乐库加载失败'), findsOneWidget);
      expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
      expect(find.text('这台 NAS 没有安装 Audio Station'), findsNothing);
      expect(find.text('这个账号没有使用 Audio Station 的权限'), findsNothing);

      // 网络恢复后点「重试」→ 正常出空态
      r.t.offlineApis.clear();
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('音乐库里还没有歌曲'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('r642 · DA236 点歌即播（带队列 ⇒ 上一首/下一首不再灰）', () {
    testWidgets('歌曲列表点歌 ⇒ 自动起播，队列 = 整页歌曲', (tester) async {
      // 真机修前（r641）：列表点歌只 push 详情页 —— 停在 0:00，
      // dump 里 `Previous enabled=false` / `Next enabled=false`
      // （队列为空 ⇒ 用户点了一首歌却只能听这一首）。
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {
            'songs': [
              _song(),
              _song(id: 'music_2', title: '晴天', path: '/v/music/晴天.mp3'),
            ],
            'total': 2,
          },
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': '[00:01]一群嗜血的蚂蚁'},
        },
      );
      expect(r.player.played, isEmpty, reason: '还没点歌时不该有播放请求');
      await tester.tap(find.byKey(const Key('as-song-music_1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(r.player.played, isNotEmpty, reason: 'DA236：点歌必须自己响');
      expect(
        r.player.playedQueues.first.length,
        2,
        reason: '队列必须是列表里的整页歌曲，否则上一首/下一首无从谈起',
      );
      // 主播放键已经是"暂停"形态（正在播）
      expect(find.byIcon(Icons.pause), findsWidgets);
      // 上一首 / 下一首不再是灰的
      final prev = tester.widget<IconButton>(find.byKey(const Key('as-prev')));
      final next = tester.widget<IconButton>(find.byKey(const Key('as-next')));
      expect(prev.onPressed, isNotNull);
      expect(next.onPressed, isNotNull);
      await tester.pump(const Duration(seconds: 6)); // 送走可能的计时器
    });

    testWidgets('反向：不传 autoPlay 的老入口（迷你条/直接跳转）仍然不自动播', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': '[00:01]一群嗜血的蚂蚁'},
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.player.played, isEmpty);
      expect(find.byIcon(Icons.play_arrow), findsWidgets);
    });

    testWidgets('反向：已经在放这首歌时再打开（autoPlay）不重复起播', (tester) async {
      final r = await _pump(
        tester,
        AudioSongDetailPage(
          songId: 'music_1',
          title: '示例歌曲',
          queue: [
            AudioSongDto(
              id: 'music_1',
              path: '/volume1/music/示例歌曲.mp3',
              title: '示例歌曲',
            ),
          ],
          autoPlay: true,
        ),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': '[00:01]一群嗜血的蚂蚁'},
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(r.player.played.length, 1, reason: '打开即起播只该发一次');
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('音乐库：列表 / 标签页 / 搜索', () {
    testWidgets('歌曲列表渲染，点开进单曲页（元数据 + 歌词）', (tester) async {
      await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {
            'songs': [_song()],
            'total': 1,
          },
          '$_as.Song.getinfo': {
            'songs': [_song(rating: 4)],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': '[00:01]一群嗜血的蚂蚁'},
        },
      );
      expect(find.text('示例歌曲'), findsOneWidget);
      expect(find.text('示例歌手 · 十一月的萧邦'), findsOneWidget);
      expect(find.textContaining('3:47'), findsOneWidget);

      await tester.tap(find.byKey(const Key('as-song-music_1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-lyrics')), findsOneWidget);
      expect(find.textContaining('一群嗜血的蚂蚁'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // ★ r403 DA51：真机上"没时间轴"那句提示**出现了两遍** ——
    // `SyncedLyricsView`（`audio_lyrics_view.dart:290`）已经印过一次，
    // 单曲页自己又印一次（同一帧 XML 里两个相邻 hint 文本节点、
    // 像素 `docs/evidence-r403/device/r403_02_lyrics_success.png`）。
    testWidgets('★ r403 DA51：没时间轴的歌词提示只出现一次', (tester) async {
      await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {
            'songs': [_song()],
            'total': 1,
          },
          '$_as.Song.getinfo': {
            'songs': [_song(rating: 4)],
          },
          // 纯文本（无时间轴）歌词 ⇒ 走"照实平铺 + 提示"那条分支
          '$_as.Lyrics.getlyrics': {
            'lyrics': 'Sample lyric line one\nSample lyric line two',
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-song-music_1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-lyrics')), findsOneWidget);
      expect(find.text('Sample lyric line one'), findsOneWidget);
      expect(
        find.text(audioLyricsPlainTextHintText()),
        findsOneWidget,
        reason: '修前 = 两遍（SyncedLyricsView 一次 + 单曲页自己一次）',
      );
      expect(tester.takeException(), isNull);
    });

    // ★ r631 DA213：全屏歌词页「只有署名、正文一个字都没有」。
    //   根因：`height: double.infinity` ⇒ 顶部留白 `height/2` 变无穷大 ⇒
    //   每行都被推出视口。判据必须落在**像素几何**上（构建出来不算过）。
    testWidgets('★ DA213 全屏歌词：正文真的在屏内，且能就地暂停', (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {
            'songs': [_song()],
            'total': 1,
          },
          '$_as.Song.getinfo': {
            'songs': [_song(rating: 4)],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': '[00:01]一群嗜血的蚂蚁\n[00:09]第二句'},
        },
      );
      await tester.tap(find.byKey(const Key('as-song-music_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-lyrics-expand')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('as-lyrics-full')), findsOneWidget);
      // ★ 结构性判据（反向验证过：注入 `height: double.infinity` ⇒ 这条当场红）：
      //   全屏页必须把**布局给的有限高度**传下去，不许再把"无穷"交给视图
      //   （无穷 ⇒ 顶部留白无穷 ⇒ 正文全被推出视口，真机就是这样一片空白）。
      final view = tester.widget<SyncedLyricsView>(
        find.byKey(const Key('as-lyrics-full')),
      );
      expect(
        view.height.isFinite,
        isTrue,
        reason: 'DA213：全屏歌词的视口高度必须是有限值（真机空白屏的根因）',
      );
      final line = find.byKey(const Key('as-lyrics-full-line-0'));
      expect(line, findsOneWidget, reason: 'DA213：全屏页必须真的把歌词行画出来');
      final rect = tester.getRect(line);
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(
        rect.top >= 0 && rect.bottom <= size.height,
        isTrue,
        reason: 'DA213：行必须在视口内（修前整屏空 ⇒ 外接 0 行可见），rect=$rect',
      );
      // 就地暂停：全屏页最常见的动作
      await tester.tap(find.byKey(const Key('as-lyrics-full-toggle')));
      await tester.pumpAndSettle();
      expect(r.t.calls, isNotEmpty);
    });

    // ★ r632：**同一页、换成英文界面**，文案必须整页跟着变。
    //   现场背景（r631 §8 的诚实缺口）：全屏歌词页只截到过中文；而 r631 的
    //   「歌曲信息」快捷入口用的是 `dataText(..., '歌曲信息')` —— 这个词
    //   **不在 `dataTextMap` 里**（该表是人工维护的子集），英文界面回落中文，
    //   真机就是这么印出「歌曲信息」的。r632 改用已登记的 `t.asSongInfo`，
    //   本用例是它的机器判据：英文界面下整页**一个汉字都不许出现**。
    testWidgets('★ 英文界面：全屏歌词页整页英文（含署名行与就地暂停的提示语）', (
      tester,
    ) async {
      // 用**ASCII 歌曲数据**（歌名/艺人来自服务器，不是界面文案）——
      // 否则「整页不许有 CJK」这条判据会把数据本身当漏翻，验证装置不诚实。
      final enSong = _song(
        title: 'Demo Song',
        artist: 'Demo Artist',
        album: '00s Love Songs',
        path: '/volume1/music/Demo Song.mp3',
      );
      await _pump(
        tester,
        const AudioPage(),
        english: true,
        responses: {
          '$_as.Song.list': {
            'songs': [enSong],
            'total': 1,
          },
          '$_as.Song.getinfo': {
            'songs': [enSong],
          },
          '$_as.Lyrics.getlyrics': {
            'lyrics': '[00:01]Sample lyric line one\n[00:09]Sample lyric line two',
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-song-music_1')));
      await tester.pumpAndSettle();
      // 快捷入口：r631 印的是中文「歌曲信息」，r632 起跟着语言走
      expect(
        find.text('Song info'),
        findsOneWidget,
        reason: '英文界面下「歌曲信息」入口必须是 Song info（r631 真机印的是中文）',
      );
      await tester.tap(find.byKey(const Key('as-lyrics-expand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-lyrics-full')), findsOneWidget);

      // 判据①：署名行是英文（`dataText` 那条路 —— dataTextMap 注入表）
      expect(find.textContaining('Lyrics source'), findsOneWidget);
      // 判据②：整页可见文案里**不许有 CJK**（漏翻会当场红，而不是靠人眼）
      final cjk = RegExp(r'[\u3400-\u9FFF\u3000-\u303F\uFF00-\uFFEF]');
      final offenders = <String>[];
      for (final e in find.byType(Text).evaluate()) {
        final data = (e.widget as Text).data;
        if (data != null && cjk.hasMatch(data)) offenders.add(data);
      }
      expect(
        offenders,
        isEmpty,
        reason: '英文界面下这些文案还是中文（漏翻）：$offenders',
      );
      // 判据③：就地暂停的**提示语**也走 `context.t`，必须是英文
      expect(
        find.byTooltip('Pause').evaluate().isNotEmpty ||
            find.byTooltip('Play').evaluate().isNotEmpty,
        isTrue,
        reason: '全屏歌词的播放/暂停提示语没跟着语言走',
      );
    });

    testWidgets('切到「专辑」标签 → Album.list（v3 + avg_rating）', (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Album.list': {
            'albums': [
              {'name': '十一月的萧邦', 'album_artist': '示例歌手', 'year': 2005},
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-tab-album')));
      await tester.pumpAndSettle();
      final call = _call(r.t, '$_as.Album', 'list');
      expect(call['version'], '3');
      expect(call['additional'], 'avg_rating');
      expect(find.text('十一月的萧邦'), findsOneWidget);
    });

    testWidgets('搜索：提交关键字 → Song.search，结果进列表', (tester) async {
      final r = await _pump(
        tester,
        const AudioSearchPage(),
        responses: {
          '$_as.Song.search': {
            'songs': [_song(title: '晴天')],
            'total': 1,
          },
        },
      );
      await tester.enterText(find.byKey(const Key('as-search-field')), '晴天');
      await tester.tap(find.byKey(const Key('as-search-go')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(r.t, '$_as.Song', 'search');
      expect(call['keyword'], '晴天');
      // 输入框里也有"晴天"，所以按结果项 key 断言而不是 find.text
      expect(find.byKey(const Key('as-song-music_1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('搜索没有结果 → 搜索空态（不是"加载失败"）', (tester) async {
      await _pump(tester, const AudioSearchPage(), responses: const {});
      await tester.enterText(find.byKey(const Key('as-search-field')), 'zzz');
      await tester.tap(find.byKey(const Key('as-search-go')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('没有找到匹配的音乐'), findsOneWidget);
    });
  });

  group('单曲页：评分 / 流式 URL / 播放 / 歌词', () {
    testWidgets('点第 4 颗星 → Song.setrating（id 逗号串、version=2）', (tester) async {
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
      await _openSongInfo(tester);
      await tester.tap(find.byKey(const Key('as-star-4')));
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(r.t, '$_as.Song', 'setrating');
      expect(call['version'], '2');
      expect(call['id'], 'music_1');
      expect(call['rating'], 4);
      expect(find.text('已设置评分'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // 送走 SnackBar 计时器
    });

    testWidgets('DA206 点当前星级 = 清除评分（setrating 收到 0）', (tester) async {
      // 真机 r615：评过 5 星之后再点第 5 颗星**什么都不变** —— 界面上没有任何
      // 回到"未评分"的入口，而 `Song.setrating` 本身就支持 `rating=0` 清除。
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song(rating: 5)],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await _openSongInfo(tester);
      // 先确认这颗星确实是"当前星级"
      expect(find.byIcon(Icons.star), findsNWidgets(5));
      await tester.tap(find.byKey(const Key('as-star-5')));
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(r.t, '$_as.Song', 'setrating');
      expect(call['rating'], 0, reason: '点当前星级必须发 rating=0');
      expect(find.text('已清除评分'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));

      // 反向：点**别的**星级仍然是设值（不是清除）
      await tester.tap(find.byKey(const Key('as-star-2')));
      await tester.pump(const Duration(milliseconds: 200));
      final call2 = _call(r.t, '$_as.Song', 'setrating');
      expect(call2['rating'], 2);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('流式 URL 是 stream.cgi/0.mp3 形态；播放走可注入播放器', (tester) async {
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
      await _openSongInfo(tester);
      final url = tester
          .widget<SelectableText>(find.byKey(const Key('as-stream-url')))
          .data!;
      expect(url.contains('/webapi/AudioStation/stream.cgi/0.mp3?'), isTrue);
      expect(url.contains('api=SYNO.AudioStation.Stream'), isTrue);
      // ★ 断言纠正（真机证据推翻旧值，不是放宽）：
      //   * 旧断言钉死 `version=2`；真机 §1.6 + 官方安卓 `ApiEnumerator.getPlayUrl`
      //     逐字是 `version=1`（`AudioStationApi.versionStream = 1`）。
      //   * 旧断言钉死 `sid=FAKE-SID` 且 `_sid=` 必须不存在 —— 那是抄官方 **Web 前端**
      //     `audio-core.js` 的 `st()`（浏览器里另带 DSM cookie）。真机 §1.6：
      //     `stream.cgi?…&sid=` → 105，`…&_sid=` → 206。客户端无 cookie，只能 `_sid=`。
      expect(url.contains('version=1'), isTrue);
      expect(url.contains('method=stream'), isTrue);
      expect(url.contains('&sid='), isFalse);

      // ★ r131（macOS 逐屏走查 D13，像素证据 `m11_audio_song.png`）：**界面上显示的是
      //   打码后的地址**。会话凭据（`_sid` / `SynoToken`）明文渲染成可选文本 + 复制按钮
      //   = 一张截图就交出会话，所以显示层一律打码；**播放用的仍是带令牌的原地址**。
      expect(url.contains('_sid=***'), isTrue, reason: url);
      expect(url.contains('SynoToken=***'), isTrue, reason: url);
      expect(url.contains('FAKE-SID'), isFalse, reason: '界面不许出现会话 id');
      expect(url.contains('FAKE-TOKEN'), isFalse, reason: '界面不许出现 CSRF 令牌');

      await _closeSongInfo(tester);
      await tester.tap(find.byKey(const Key('as-play')));
      await tester.pump(const Duration(milliseconds: 200));
      final played = r.player.played.single;
      expect(played.contains('_sid=FAKE-SID'), isTrue, reason: '播放必须用真令牌');
      expect(redactStreamUrl(played), url, reason: '显示文本 = 播放地址打码后的形态');
    });

    testWidgets('WMA 曲目 → 自动改用**服务端转码流**，并如实提示（用户报告的主用例）', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song(path: '/volume1/music/示例歌曲.wma')],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await _openSongInfo(tester);
      final url = tester
          .widget<SelectableText>(find.byKey(const Key('as-stream-url')))
          .data!;
      // 参数逐字对齐 docs/stage2-audio-download-api.md §2.3 A-1b 的转码形态
      expect(
        url.contains('/webapi/AudioStation/stream.cgi/0.wav?'),
        isTrue,
        reason: url,
      );
      expect(url.contains('method=transcode'), isTrue);
      expect(url.contains('format=wav'), isTrue);
      // ★ 断言纠正（真机 §1.7 结论 4）：官方普通播放**不发** `position`（只在
      //   Chromecast 时发 `position=0`）；旧断言钉死 `position=0` 与实现语义不符。
      //   seek 改用播放器自身的 HTTP Range（真机已证转码流也吃 Range）。
      expect(url.contains('position='), isFalse);
      // **不得**再走直传（修复前正是这里走 method=stream → 起播必失败）
      expect(url.contains('method=stream'), isFalse);
      // 如实告诉用户"放的不是原文件"
      expect(find.byKey(const Key('as-transcode-hint')), findsOneWidget);
      expect(find.textContaining('服务端转码'), findsWidgets);
      // 播放器拿到的是**同一条**转码 URL（但界面显示的是打码版，见 D13）
      await _closeSongInfo(tester);
      await tester.tap(find.byKey(const Key('as-play')));
      await tester.pump(const Duration(milliseconds: 200));
      final played = r.player.played.single;
      expect(played.contains('_sid=FAKE-SID'), isTrue, reason: played);
      expect(url.contains('FAKE-SID'), isFalse, reason: '界面不许出现会话 id');
      expect(redactStreamUrl(played), url, reason: '显示文本 = 播放地址打码后的形态');
    });

    testWidgets('WMA + 服务端声明 transcode_to_mp3 → 转成 mp3（不是 wav）', (
      tester,
    ) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Info.getinfo': {'transcode_to_mp3': true},
          '$_as.Song.getinfo': {
            'songs': [_song(path: '/volume1/music/示例歌曲.wma')],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await _openSongInfo(tester);
      final url = tester
          .widget<SelectableText>(find.byKey(const Key('as-stream-url')))
          .data!;
      expect(url.contains('/0.mp3?'), isTrue, reason: url);
      expect(url.contains('format=mp3'), isTrue);
    });

    testWidgets('MP3 曲目 → 仍走直传、**不**出现转码提示（能播的格式零误报）', (tester) async {
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
      await _openSongInfo(tester);
      final url = tester
          .widget<SelectableText>(find.byKey(const Key('as-stream-url')))
          .data!;
      expect(url.contains('method=stream'), isTrue);
      expect(url.contains('method=transcode'), isFalse);
      expect(find.byKey(const Key('as-transcode-hint')), findsNothing);
    });

    testWidgets('转码流起播失败 → 分类成"格式/转码路径"明确提示 + 重试（不落进泛化失败）', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song(path: '/volume1/music/示例歌曲.wma')],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      // Media3 对 ASF/未知容器的真实兜底串（`UnrecognizedInputFormatException`）
      r.player.failPlay = true;
      r.player.playError = Exception(
        'UnrecognizedInputFormatException: None of the available extractors '
        'could read the stream.',
      );
      await tester.tap(find.byKey(const Key('as-play')));
      await tester.pump(const Duration(milliseconds: 200));
      // 明确提示（不是一句 `播放失败: Exception…`）
      expect(find.byKey(const Key('as-play-failure')), findsOneWidget);
      expect(find.byKey(const Key('as-play-failure-detail')), findsOneWidget);
      final detail = tester
          .widget<Text>(find.byKey(const Key('as-play-failure-detail')))
          .data!;
      expect(detail.contains('这种格式通常不被系统解码器支持'), isTrue, reason: detail);
      // 重试入口在（不是崩掉、也不是死路）
      expect(find.byKey(const Key('as-play-retry')), findsOneWidget);
      expect(find.textContaining('重试的仍是服务端转码流'), findsOneWidget);
    });

    testWidgets('会话过期 / 网络中断**不得**被说成格式问题（分类不许混）', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song(path: '/volume1/music/示例歌曲.wma')],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      r.player.failPlay = true;
      r.player.playError = Exception('ERROR_CODE_IO_BAD_HTTP_STATUS: http=404');
      await tester.tap(find.byKey(const Key('as-play')));
      await tester.pump(const Duration(milliseconds: 200));
      final detail = tester
          .widget<Text>(find.byKey(const Key('as-play-failure-detail')))
          .data!;
      expect(detail.contains('服务器拒绝了这一条取流请求'), isTrue, reason: detail);
      expect(detail.contains('这种格式通常不被系统解码器支持'), isFalse);
    });

    testWidgets('没歌词 → 给"联网搜索歌词"，点了走 LyricsSearch', (tester) async {
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.LyricsSearch.searchlyrics': {'lyrics': '[00:09]搜到的歌词'},
        },
        // ★ r411（DA68）：这条用例钉的是**NAS 那一路**，公开源必须给假源 ——
        // 以前不 override 就会落到真的 `LrclibLyricsSource`（测试环境里
        // HttpClient 一律 400）⇒ 触发 `retryDelay` 的 700 ms 定时器；
        // 定时器是**时序相关**的：`_searchSynced` 里少一个 await 就会从
        // "来不及建定时器"变成"定时器挂着" ⇒ `A Timer is still pending`
        // 这条假红/假绿取决于异步跳数（本轮真被它红了一次）。
        moreOverrides: [
          mediaLyricsLookupProvider.overrideWithValue(
            LyricsLookup(
              source: _FakeLyricsSource(const []),
              cache: InMemoryLyricsCache(),
              retryDelay: Duration.zero,
            ),
          ),
        ],
      );
      expect(find.text('这首歌没有歌词'), findsOneWidget);
      await tester.tap(find.byKey(const Key('as-lyrics-search')));
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(r.t, '$_as.LyricsSearch', 'searchlyrics');
      expect(call['title'], '示例歌曲');
      expect(call['artist'], '示例歌手');
      expect(call['additional'], 'full_lyrics');
      expect(find.textContaining('搜到的歌词'), findsOneWidget);
    });

    // ★ r403 DA55：点一次按钮其实有**两条联网来源**（NAS 的 `LyricsSearch` 与公开源）。
    // 修前：NAS 那条先答"没有"就把提示条弹出来 —— 而公开源那一路其实已经拿到并
    // 显示了歌词 ⇒ "屏上正显示着歌词，却说联网没找到"。真机复验读数见
    // `docs/android-ui-audit-r403.md` §S5c。
    testWidgets('★ r403 DA55：屏上已有歌词 ⇒ 不许说"联网也没有找到歌词"', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          // NAS 那条：`200 {}`（答"没有"，不是失败）
          '$_as.LyricsSearch.searchlyrics': {'lyrics': ''},
        },
        moreOverrides: [
          mediaLyricsLookupProvider.overrideWithValue(
            LyricsLookup(
              source: _FakeLyricsSource([
                const LyricCandidate(
                  id: 1,
                  trackName: '示例歌曲',
                  artistName: '示例歌手',
                  duration: Duration(seconds: 227),
                  syncedLyrics: '[00:09.00]一群嗜血的蚂蚁',
                ),
              ]),
              cache: InMemoryLyricsCache(),
            ),
          ),
        ],
      );
      await tester.tap(find.byKey(const Key('as-lyrics-search')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('一群嗜血的蚂蚁'), findsWidgets);
      expect(
        find.text('联网也没有找到歌词'),
        findsNothing,
        reason: '修前：NAS 那条先说"没有"就弹提示条（而屏上明明有歌词）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('★ r403 DA55 反向面：两条都没有 ⇒ 才如实说"联网也没有找到歌词"', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.LyricsSearch.searchlyrics': {'lyrics': ''},
        },
        moreOverrides: [
          mediaLyricsLookupProvider.overrideWithValue(
            LyricsLookup(
              source: _FakeLyricsSource(const []),
              cache: InMemoryLyricsCache(),
            ),
          ),
        ],
      );
      await tester.tap(find.byKey(const Key('as-lyrics-search')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('联网也没有找到歌词'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('查不到单曲时给可重试的空态', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_x', title: '不存在'),
        responses: const {},
      );
      expect(find.text('歌曲信息加载失败'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    // ★★★ r411 DA66：**歌词署名**。r403 的诚实缺口原文：
    // 「屏上没有任何地方写"这是哪一条候选 / 来自哪个源"」。
    // 单曲页原来连一个候选都看不到（下面 DA67 那组），署名更无从谈起。
    group('★ r411 DA66：单曲页歌词署名', () {
      testWidgets('服务端那份（纯文本）⇒ 写 NAS 歌词库 + 无时间轴', (tester) async {
        await _pump(
          tester,
          const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
          responses: {
            '$_as.Song.getinfo': {
              'songs': [_song()],
            },
            '$_as.Lyrics.getlyrics': {'lyrics': '只有一句词\n又一勺沉默'},
          },
          moreOverrides: [
            mediaLyricsLookupProvider.overrideWithValue(
              LyricsLookup(
                source: _FakeLyricsSource(const []),
                cache: InMemoryLyricsCache(),
              ),
            ),
          ],
        );
        final line = tester.widget<Text>(
          find.byKey(const Key('as-lyrics-attribution')),
        );
        expect(line.data, '歌词来源：NAS 歌词库 · 不会自动滚动');
      });

      testWidgets('公开源那份 ⇒ 写明 lrclib + 曲名 + 歌手', (tester) async {
        await _pump(
          tester,
          const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
          responses: {
            '$_as.Song.getinfo': {
              'songs': [_song()],
            },
            '$_as.LyricsSearch.searchlyrics': {'lyrics': ''},
          },
          moreOverrides: [
            mediaLyricsLookupProvider.overrideWithValue(
              LyricsLookup(
                source: _FakeLyricsSource(const [
                  LyricCandidate(
                    id: 9,
                    trackName: '示例歌曲',
                    artistName: '示例歌手',
                    duration: Duration(seconds: 227),
                    syncedLyrics: '[00:09.00]一群嗜血的蚂蚁',
                  ),
                ]),
                cache: InMemoryLyricsCache(),
              ),
            ),
          ],
        );
        await tester.tap(find.byKey(const Key('as-lyrics-search')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final line = tester.widget<Text>(
          find.byKey(const Key('as-lyrics-attribution')),
        );
        expect(line.data, '歌词来源：lrclib.net 公开歌词库 · 示例歌曲 · 示例歌手');
      });

      // ★ 反向出处：**屏上显示的是哪一份，署名就得写哪一份**。
      // 公开源给的是**纯文本**（没时间轴），服务端那份**有时间轴** ⇒
      // `_displayed()` 选的是**服务端**那份 ⇒ 署名必须是 NAS，
      // 不许因为"最近搜到过公开源候选"就把功劳记到 lrclib 头上。
      testWidgets('公开源无时间轴、服务端有时间轴 ⇒ 署名必须写 NAS（跟屏上那份走）', (tester) async {
        await _pump(
          tester,
          const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
          responses: {
            '$_as.Song.getinfo': {
              'songs': [_song()],
            },
            '$_as.Lyrics.getlyrics': {'lyrics': '[00:09.00]服务端那段带时间的词'},
          },
          moreOverrides: [
            mediaLyricsLookupProvider.overrideWithValue(
              LyricsLookup(
                source: _FakeLyricsSource(const [
                  LyricCandidate(
                    id: 11,
                    trackName: '示例歌曲',
                    artistName: '示例歌手',
                    plainLyrics: '公开源只有纯文本',
                  ),
                ]),
                cache: InMemoryLyricsCache(),
              ),
            ),
          ],
        );
        await tester.tap(find.byKey(const Key('as-lyrics-search')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('服务端那段带时间的词'), findsWidgets);
        final line = tester.widget<Text>(
          find.byKey(const Key('as-lyrics-attribution')),
        );
        expect(line.data, startsWith('歌词来源：NAS 歌词库'));
        expect(
          line.data,
          isNot(contains('lrclib')),
          reason: '屏上是服务端那份，署名不能记到公开源头上',
        );
        expect(line.data, isNot(contains('不会自动滚动')));
      });
    });

    // ★★★ r411 DA67：单曲页原来**没有**「换一个歌词版本」入口
    // （文件预览页早就有）—— 同一个「歌词」功能两个入口能力不同。
    group('★ r411 DA67：单曲页的候选选择器', () {
      testWidgets('多条候选 ⇒ 出「换一个歌词版本」；选中即换正文', (tester) async {
        await _pump(
          tester,
          const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
          responses: {
            '$_as.Song.getinfo': {
              'songs': [_song()],
            },
            '$_as.LyricsSearch.searchlyrics': {'lyrics': ''},
          },
          moreOverrides: [
            mediaLyricsLookupProvider.overrideWithValue(
              LyricsLookup(
                source: _FakeLyricsSource(const [
                  LyricCandidate(
                    id: 21,
                    trackName: '示例歌曲',
                    artistName: '示例歌手',
                    duration: Duration(seconds: 227),
                    syncedLyrics: '[00:09.00]原唱那份',
                  ),
                  LyricCandidate(
                    id: 22,
                    trackName: '示例歌曲',
                    artistName: '翻唱歌手',
                    duration: Duration(seconds: 300),
                    syncedLyrics: '[00:09.00]翻唱那份',
                  ),
                ]),
                cache: InMemoryLyricsCache(),
              ),
            ),
          ],
        );
        // ★ r472 订正：打开页面会**自动**补一次带时间轴的公开源
        //   （用户 r468「歌词不随进度」的修法）⇒ 这里候选已经就位、
        //   「换一个歌词版本」是真的有候选才出现（不是假入口）。
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('as-lyrics-pick')), findsOneWidget);
        await tester.tap(find.byKey(const Key('as-lyrics-search')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('as-lyrics-pick')), findsOneWidget);
        await tester.tap(find.byKey(const Key('as-lyrics-pick')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('as-lyrics-candidates')), findsOneWidget);
        expect(find.byKey(const Key('as-lyrics-candidate-22')), findsOneWidget);
        await tester.tap(find.byKey(const Key('as-lyrics-candidate-22')));
        await tester.pumpAndSettle();
        expect(find.textContaining('翻唱那份'), findsWidgets);
        final line = tester.widget<Text>(
          find.byKey(const Key('as-lyrics-attribution')),
        );
        expect(line.data, contains('翻唱歌手'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('只有一条候选 ⇒ **不给**「换一个」（换了还是它）', (tester) async {
        await _pump(
          tester,
          const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
          responses: {
            '$_as.Song.getinfo': {
              'songs': [_song()],
            },
            '$_as.LyricsSearch.searchlyrics': {'lyrics': ''},
          },
          moreOverrides: [
            mediaLyricsLookupProvider.overrideWithValue(
              LyricsLookup(
                source: _FakeLyricsSource(const [
                  LyricCandidate(
                    id: 31,
                    trackName: '示例歌曲',
                    artistName: '示例歌手',
                    duration: Duration(seconds: 227),
                    syncedLyrics: '[00:09.00]只有这一份',
                  ),
                ]),
                cache: InMemoryLyricsCache(),
              ),
            ),
          ],
        );
        await tester.tap(find.byKey(const Key('as-lyrics-search')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('只有这一份'), findsWidgets);
        expect(find.byKey(const Key('as-lyrics-pick')), findsNothing);
      });
    });

    // ★★★ r411 DA68（真机撞到）：单曲页的「Search lyrics online」在**缓存命中**时
    // 直接短路 ⇒ 按钮点下去屏上毫无变化、候选**永远**是空的
    // （= 上一轮刚补的「换一个歌词版本」入口在真机上出不来）。
    // 真机读数：`docs/evidence-r411/device/r411_09_after_search.xml`
    // 与点按钮**前**那帧逐字相同（仍写着 `Using local cache`，无任何 pick 入口）。
    group('★ r411 DA68：单曲页显式重搜**不许**被缓存短路', () {
      /// 预置一份缓存（键 = 单曲页算出来的那个）
      String cacheKey() => const LyricsQuery(
        title: '示例歌曲',
        artist: '示例歌手',
        duration: Duration(seconds: 227),
        identity: 'music_1',
      ).cacheKey;

      final cachedCandidate = const LyricCandidate(
        id: 101,
        trackName: '示例歌曲',
        artistName: '示例歌手',
        syncedLyrics: '[00:09.00]缓存里那份',
      );

      testWidgets('缓存命中：打开页面**不联网**、署名标"已用本地缓存"', (tester) async {
        final cache = InMemoryLyricsCache();
        await cache.write(
          cacheKey(),
          jsonEncode({
            'version': LyricsLookup.cacheSchemaVersion,
            'chosen': cachedCandidate.toJson(),
          }),
        );
        final source = _FakeLyricsSource(const [
          LyricCandidate(
            id: 102,
            trackName: '示例歌曲',
            artistName: '示例歌手',
            syncedLyrics: '[00:09.00]网上那份',
          ),
        ]);
        await _pump(
          tester,
          const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
          responses: {
            '$_as.Song.getinfo': {
              'songs': [_song()],
            },
            '$_as.Lyrics.getlyrics': {'lyrics': ''},
          },
          moreOverrides: [
            mediaLyricsLookupProvider.overrideWithValue(
              LyricsLookup(source: source, cache: cache),
            ),
          ],
        );
        expect(find.textContaining('缓存里那份'), findsWidgets);
        final line = tester.widget<Text>(
          find.byKey(const Key('as-lyrics-attribution')),
        );
        expect(line.data, contains('已用本地缓存'));
        expect(
          source.searched,
          isEmpty,
          reason: '打开页面只读缓存、不联网（这是既有契约，没被 DA68 改掉）',
        );
      });

      testWidgets('点「Search lyrics online」⇒ 真的联网重搜 + 候选入口出来', (tester) async {
        final cache = InMemoryLyricsCache();
        await cache.write(
          cacheKey(),
          jsonEncode({
            'version': LyricsLookup.cacheSchemaVersion,
            'chosen': cachedCandidate.toJson(),
          }),
        );
        final source = _FakeLyricsSource(const [
          LyricCandidate(
            id: 201,
            trackName: '示例歌曲',
            artistName: '示例歌手',
            duration: Duration(seconds: 227),
            syncedLyrics: '[00:09.00]网上第一份',
          ),
          LyricCandidate(
            id: 202,
            trackName: '示例歌曲',
            artistName: '翻唱歌手',
            duration: Duration(seconds: 240),
            syncedLyrics: '[00:09.00]网上第二份',
          ),
        ]);
        await _pump(
          tester,
          const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
          responses: {
            '$_as.Song.getinfo': {
              'songs': [_song()],
            },
            '$_as.Lyrics.getlyrics': {'lyrics': ''},
          },
          moreOverrides: [
            mediaLyricsLookupProvider.overrideWithValue(
              LyricsLookup(source: source, cache: cache),
            ),
          ],
        );
        await tester.tap(find.byKey(const Key('as-lyrics-search')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          source.searched,
          hasLength(1),
          reason: '用户明确点了"联网搜歌词" ⇒ 必须真打一次源站',
        );
        expect(find.byKey(const Key('as-lyrics-pick')), findsOneWidget);
        // 新那份上屏；缓存标记也该消失（它已经不是缓存了）
        expect(find.textContaining('网上第一份'), findsWidgets);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('as-lyrics-attribution')))
              .data,
          isNot(contains('已用本地缓存')),
        );
      });

      // ★★★ r411 DA69（真机撞到）：**重搜不许把用户选过的版本静默改回**。
      // 真机读数：16:18 选了 `De Nederlandse Top 40 Van 2000`（缓存逐字），
      // 16:23 点一次「Search lyrics online」⇒ 屏上与**缓存**都被改回自动第一的
      // `Hitbreaker 2001/2 - CD2`。判据：屏上那份还在新候选里就该留着它。
      testWidgets('重搜：屏上那份**还在候选里** ⇒ 不许换成自动排名的另一份', (tester) async {
        final cache = InMemoryLyricsCache();
        await cache.write(
          cacheKey(),
          jsonEncode({
            'version': LyricsLookup.cacheSchemaVersion,
            'chosen': cachedCandidate.toJson(),
          }),
        );
        // 源站把**别人**排第一（id 401），而屏上那份（id 101）也在列表里
        final source = _FakeLyricsSource(const [
          LyricCandidate(
            id: 401,
            trackName: '示例歌曲',
            artistName: '示例歌手',
            syncedLyrics: '[00:09.00]自动排名第一那份',
          ),
          LyricCandidate(
            id: 101,
            trackName: '示例歌曲',
            artistName: '示例歌手',
            syncedLyrics: '[00:09.00]缓存里那份',
          ),
        ]);
        await _pump(
          tester,
          const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
          responses: {
            '$_as.Song.getinfo': {
              'songs': [_song()],
            },
            '$_as.Lyrics.getlyrics': {'lyrics': ''},
          },
          moreOverrides: [
            mediaLyricsLookupProvider.overrideWithValue(
              LyricsLookup(source: source, cache: cache),
            ),
          ],
        );
        await tester.tap(find.byKey(const Key('as-lyrics-search')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.textContaining('缓存里那份'),
          findsWidgets,
          reason: '重搜不许把屏上那份换成自动排名的另一份（DA69）',
        );
        expect(find.textContaining('自动排名第一那份'), findsNothing);
        // 第三腿：缓存里也**不许**被自动排名那份覆盖掉
        final raw = await cache.read(cacheKey());
        expect(raw, isNotNull);
        expect(
          jsonDecode(raw!)['chosen']['id'],
          101,
          reason: '用户选过的那份必须还在缓存里（真机上这里被改成了自动排名那份）',
        );
      });

      testWidgets('重搜**没搜到正文** ⇒ 屏上原有歌词不许弄丢，但候选留下', (tester) async {
        final cache = InMemoryLyricsCache();
        await cache.write(
          cacheKey(),
          jsonEncode({
            'version': LyricsLookup.cacheSchemaVersion,
            'chosen': cachedCandidate.toJson(),
          }),
        );
        // 两条候选**都没有正文** ⇒ `search()` 回 notFound，但候选列表还在
        final source = _FakeLyricsSource(const [
          LyricCandidate(id: 301, trackName: '别人的歌'),
          LyricCandidate(id: 302, trackName: '另一首别人的歌'),
        ]);
        await _pump(
          tester,
          const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
          responses: {
            '$_as.Song.getinfo': {
              'songs': [_song()],
            },
            '$_as.Lyrics.getlyrics': {'lyrics': ''},
          },
          moreOverrides: [
            mediaLyricsLookupProvider.overrideWithValue(
              LyricsLookup(source: source, cache: cache),
            ),
          ],
        );
        await tester.tap(find.byKey(const Key('as-lyrics-search')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.textContaining('缓存里那份'),
          findsWidgets,
          reason: '新搜到的没有正文 ⇒ 不许把屏上原有歌词弄丢',
        );
        expect(find.byKey(const Key('as-lyrics-pick')), findsOneWidget);
      });
    });
  });

  // P0-2 / P0-4 / P0-5 的页面层回归：队列、随机/循环、进度/seek、音质档位。
  // 这些行为在 `audio_player.dart` + `audio_song_page.dart` 已实现，这里钉住
  // "界面真的把用户操作下发给了播放器/URL"。
  group('单曲页：队列 / 随机 / 循环 / 进度 / 音质（P0）', () {
    AudioSongDto dto(String id, String title, {String? path}) =>
        AudioSongDto.fromJson(
          _song(id: id, title: title, path: path ?? '/m/$id.mp3'),
        );

    testWidgets('带队列打开 → 播整个队列、起播下标正确、next 推进', (tester) async {
      final queue = [
        dto('music_1', 'a'),
        dto('music_2', 'b'),
        dto('music_3', 'c'),
      ];
      final r = await _pump(
        tester,
        AudioSongDetailPage(
          songId: 'music_1',
          title: 'a',
          queue: queue,
          queueIndex: 1,
        ),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      // 队列位置提示：第 2 / 共 3
      expect(find.byKey(const Key('as-queue-position')), findsOneWidget);

      await tester.tap(find.byKey(const Key('as-play')));
      await tester.pump(const Duration(milliseconds: 200));
      final sent = r.player.playedQueues.single;
      expect(sent.length, 3, reason: '整个队列都要交给播放器');
      expect(sent.map((e) => e.id).toList(), ['music_1', 'music_2', 'music_3']);
      // 起播的是 queueIndex=1 的那条（不是永远第 0 条）
      expect(r.player.played.single, sent[1].url);
      // B5：**边下边播**的可证部分 —— 交给引擎的是 **Stream 直链 URL**
      // （`AudioStation/stream.cgi`，HTTP Range 由 ExoPlayer 发），
      // 且**没有任何 Download 族调用**（不存在"先整曲下载再播"）。
      expect(
        sent
            .map((e) => e.url)
            .every((u) => u.contains('/webapi/AudioStation/stream.cgi')),
        isTrue,
      );
      expect(
        r.t.calls.where((c) {
          final a = '${c['api']}';
          return a.contains('Download') ||
              '${c['method']}'.contains('download');
        }),
        isEmpty,
        reason: 'B5：播放路径不许先整曲下载',
      );

      // 下一首 → 播放器下标前进，页面跟着换歌
      await tester.tap(find.byKey(const Key('as-next')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(r.player.currentIndex, 2);
      expect(find.text('c'), findsWidgets);
    });

    testWidgets('队列超过服务端上限 → 按 playing_queue_max 截断', (tester) async {
      final queue = [for (var i = 0; i < 5; i++) dto('music_$i', 's$i')];
      final r = await _pump(
        tester,
        AudioSongDetailPage(
          songId: 'music_0',
          title: 's0',
          queue: queue,
          queueIndex: 0,
        ),
        responses: {
          '$_as.Info.getinfo': {'playing_queue_max': 3},
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await tester.tap(find.byKey(const Key('as-play')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(r.player.playedQueues.single.length, 3);
    });

    testWidgets('随机按钮 → setShuffle；循环按钮 off→all→one', (tester) async {
      final queue = [dto('music_1', 'a'), dto('music_2', 'b')];
      final r = await _pump(
        tester,
        AudioSongDetailPage(
          songId: 'music_1',
          title: 'a',
          queue: queue,
          queueIndex: 0,
        ),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      expect(r.player.shuffleEnabled, isFalse);
      await tester.tap(find.byKey(const Key('as-shuffle')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(r.player.shuffleEnabled, isTrue);

      expect(r.player.repeatMode, AudioRepeatMode.off);
      await tester.tap(find.byKey(const Key('as-repeat')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(r.player.repeatMode, AudioRepeatMode.all);
      await tester.tap(find.byKey(const Key('as-repeat')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(r.player.repeatMode, AudioRepeatMode.one);
    });

    testWidgets('进度条拖动 → player.seek（位置来自播放器）', (tester) async {
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
      r.player.emitDuration(const Duration(minutes: 4));
      await tester.pump(const Duration(milliseconds: 50));
      final slider = find.byKey(const Key('as-progress'));
      expect(slider, findsOneWidget);
      await tester.drag(slider, const Offset(120, 0));
      await tester.pump(const Duration(milliseconds: 50));
      expect(r.player.seeks, isNotEmpty, reason: '拖动结束必须下发 seek');
      expect(r.player.seeks.last, greaterThan(Duration.zero));
    });

    testWidgets('音质档位：选 320 kbps → 转码 URL 下发 bitrate=320000（P0-4）', (
      tester,
    ) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Info.getinfo': {'transcode_to_mp3': true},
          '$_as.Song.getinfo': {
            'songs': [_song(path: '/volume1/music/示例歌曲.wma')],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      await _openSongInfo(tester);
      // 默认档 128000 = 不发 bitrate 时的服务端默认输出（真机两者字节数相同）
      var url = tester
          .widget<SelectableText>(find.byKey(const Key('as-stream-url')))
          .data!;
      expect(url.contains('bitrate=128000'), isTrue, reason: url);

      await tester.tap(find.byKey(const Key('as-quality-320000')));
      await tester.pump(const Duration(milliseconds: 50));
      url = tester
          .widget<SelectableText>(find.byKey(const Key('as-stream-url')))
          .data!;
      expect(url.contains('bitrate=320000'), isTrue, reason: url);
    });

    testWidgets('直传（mp3）时档位不影响 URL：绝不发 bitrate', (tester) async {
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
      await _openSongInfo(tester);
      await tester.tap(find.byKey(const Key('as-quality-320000')));
      await tester.pump(const Duration(milliseconds: 50));
      final url = tester
          .widget<SelectableText>(find.byKey(const Key('as-stream-url')))
          .data!;
      expect(url.contains('method=stream'), isTrue);
      expect(url.contains('bitrate='), isFalse, reason: url);
    });

    // ★ 第 92 轮 iOS 迁移（真缺陷回归）：iPhone 16 的逻辑宽是 **393pt**，
    //   去掉左右留白后内容区只有 **337pt**；而「音质」那一行（`TelemetryLabel`
    //   + 128/192/320 三个 `ChoiceChip`）自然宽 **362pt**
    //   ⇒ 实测 `RenderFlex overflowed by 25 pixels on the right`（iOS 八模块
    //   走查 ⑦ 抓到，见 `docs/platform-ios.md` §4.5）。
    //   桌面 800x600 与既有用例的 420pt **恰好**放得下（420-56=364 ≥ 362），
    //   边界只差 2pt ⇒ 以前一直是绿的。
    //   **反向验证**：把宽度真的压到手机上，这一行不许溢出，且三档一个都不许少
    //   （不许用"藏起来/缩小点击区"的办法消掉溢出 —— AGENTS §2.0.10）。
    testWidgets('★ 反向：393pt（iPhone 16）下「音质」行不许溢出，且改成横向可滚动', (tester) async {
      tester.view.physicalSize = const Size(393 * 3, 852 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Info.getinfo': {'transcode_to_mp3': true},
          '$_as.Song.getinfo': {
            'songs': [_song(path: '/volume1/music/示例歌曲.wma')],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      expect(
        tester.takeException(),
        isNull,
        reason: '393pt 下不许有布局溢出（RenderFlex overflow 会以异常形式出现）',
      );
      // ★ DA113（r478）：常用动作原来**都不在单曲页**——队列在顶栏图标、
      //   投送/音效退回首屏再从「更多列表」菜单里找。现在播放键下方有一条
      //   快捷行；并且**睡眠定时不再重复给入口**（它已有自己一行）。
      expect(find.byKey(const Key('as-qa-queue')), findsOneWidget);
      expect(find.byKey(const Key('as-qa-cast')), findsOneWidget);
      expect(find.byKey(const Key('as-qa-effects')), findsOneWidget);
      // 音效：点了真的推路由（不是死入口）。
      // ⚠️ 不能用 `pumpAndSettle`：均衡器页有常驻动画（频谱），settle 会超时。
      await tester.tap(find.byKey(const Key('as-qa-effects')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AudioEqualizerPage), findsOneWidget);
      // 返回后再点投送。
      // 回退这里**可以** settle：均衡器页连同它的常驻动画一起出栈了。
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-qa-cast')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AudioCastPage), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      // 队列：打开的是本页自己的队列弹层（同一份状态，不是新页面）
      await tester.tap(find.byKey(const Key('as-qa-queue')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('as-queue-empty')).evaluate().isNotEmpty ||
            find.byKey(const Key('as-queue-list')).evaluate().isNotEmpty,
        isTrue,
        reason: 'DA113：队列入口必须打开队列弹层（空态或列表）',
      );
      // 把弹层收掉，否则后面的用例点不到底下的控件（弹层遮挡 = IgnorePointer）。
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      // ★ DA111（r475）：播放区原来是一个**没有任何内容的空渐变圆**
      //   （真机像素：占约 1/4 屏、零信息量，且与页头封面重复）。
      //   现在这一块是**真封面**（内嵌封面 → 服务器封面 → 图标占位），
      //   并且不再画那个圆（`as-visualizer` 从这一页移除）。
      expect(
        find.byKey(const Key('as-player-hero')),
        findsOneWidget,
        reason: 'DA111：播放区要有封面（r631 起升格为页头大封面）',
      );
      expect(
        find.byKey(const Key('as-visualizer')),
        findsNothing,
        reason: 'DA111：空渐变圆不许再回到播放区（封面已取代它）',
      );
      // ★ r631（沿用 DA109 的意图，判据升级）：技术信息**不再和播放器抢首屏**
      //   —— 它整块搬进了「歌曲信息」面板。判据（**未开面板时**）：页面上
      //   没有 `as-stream-url`；打开面板之后才有。
      expect(
        find.byKey(const Key('as-stream-url')),
        findsNothing,
        reason: 'r631：技术信息（流式 URL）不许出现在播放器首屏',
      );
      // ★ r631：后面要量的三档 chip 与流地址都在「歌曲信息」面板里
      //   （技术参数收进菜单）—— 先把面板打开，再逐项量几何。
      await _openSongInfo(tester);
      expect(find.byKey(const Key('as-stream-url')), findsOneWidget);
      // ★ DA110（r474）：三档音质 chip 的**最后一档**原来被屏幕右缘切掉
      //   （标签与 chip 挤同一行；虽然能横滑，但没有任何"还能滑"的提示 ⇒
      //   用户读到的是"只有两档"）。判据：第三档的**右边界**必须在屏内。
      final right320 = tester
          .getRect(find.byKey(const Key('as-quality-320000')))
          .right;
      expect(
        right320,
        lessThanOrEqualTo(
          tester.view.physicalSize.width / tester.view.devicePixelRatio,
        ),
        reason: 'DA110：320 kbps 档必须完整落在屏内（不能被右缘切掉）',
      );
      final row = find.byKey(const Key('as-quality-row'));
      expect(row, findsOneWidget, reason: '音质行要有可观测 key');
      // key 就挂在滚动容器**本身**上 ⇒ 不能再用 `find.descendant`（它不含自身）。
      expect(
        tester.widget(row),
        isA<SingleChildScrollView>(),
        reason: '放不下时要能横向滚动，而不是溢出',
      );
      expect(
        tester.widget<SingleChildScrollView>(row).scrollDirection,
        Axis.horizontal,
        reason: '必须是横向滚动',
      );
      for (final bps in const [128000, 192000, 320000]) {
        expect(
          find.byKey(Key('as-quality-$bps')),
          findsOneWidget,
          reason: '三档一个都不许少（$bps）',
        );
      }
      // 仍然可点（滚动容器不该吃掉点击）
      await tester.tap(find.byKey(const Key('as-quality-320000')));
      await tester.pump(const Duration(milliseconds: 50));
      final url = tester
          .widget<SelectableText>(find.byKey(const Key('as-stream-url')))
          .data!;
      expect(url.contains('bitrate=320000'), isTrue, reason: url);
    });

    // R7（后台播放 P0-3）：页面**只认 handler** —— handler 推来什么状态，页面就是
    // 什么状态；即使引擎一步没动。这是"两套状态打架"的回归门。
    testWidgets('R7：handler 推 playbackState/mediaItem → 页面换歌且按钮跟着变（引擎未动）', (
      tester,
    ) async {
      final queue = [dto('music_1', 'a'), dto('music_2', 'b')];
      final r = await _pump(
        tester,
        AudioSongDetailPage(
          songId: 'music_1',
          title: 'a',
          queue: queue,
          queueIndex: 0,
        ),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      final handler = r.c.read(audioHandlerProvider);
      // ① 模拟"通知栏/耳机开始播放"：只改 handler 的发布状态，引擎一步没动
      handler.mediaItem.add(
        const MediaItem(
          id: 'music_1',
          title: '示例歌曲',
          duration: Duration(seconds: 227),
        ),
      );
      handler.playbackState.add(
        PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: true,
          updatePosition: Duration.zero,
          queueIndex: 0,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 播放按钮 = 暂停（playing 来自 handler.playbackState）
      expect(find.byIcon(Icons.pause), findsOneWidget);
      // 引擎**没有被页面直接驱动**：下标仍是初始值
      expect(r.player.currentIndex, -1, reason: '页面不许绕过 handler 直接读/驱动引擎');

      // ② 模拟"通知栏/耳机在后台推进到第 2 首"：页面跟着换歌
      handler.mediaItem.add(
        const MediaItem(
          id: 'music_2',
          title: 'b',
          duration: Duration(seconds: 227),
        ),
      );
      handler.playbackState.add(
        PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: true,
          updatePosition: Duration.zero,
          queueIndex: 1,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 标题（AppBar）= 队列第 2 首
      expect(find.text('b'), findsWidgets);
      expect(handler.playbackState.value.queueIndex, 1);
      expect(r.player.currentIndex, -1);
    });

    testWidgets('R7：handler.pause()（= 耳机/系统暂停）→ 页面立刻回到播放图标', (tester) async {
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
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byIcon(Icons.pause), findsOneWidget);

      await r.c.read(audioHandlerProvider).pause();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(
        r.c.read(audioHandlerProvider).playbackState.value.playing,
        isFalse,
      );
    });

    testWidgets('R8：页面把续期回调注入 handler（用当前会话重拼带 _sid 的直链）', (tester) async {
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
      final handler = r.c.read(audioHandlerProvider);
      expect(handler.freshUrlFetcher, isNotNull, reason: '页面必须注入续期解析回调');
      final fresh = await handler.freshUrlFetcher!('music_1');
      expect(fresh.contains('stream.cgi'), isTrue);
      expect(fresh.contains('_sid=FAKE-SID'), isTrue);
    });
  });

  group('详情页：钻取 / 收藏', () {
    testWidgets('专辑详情 → Song.list 带 album + album_artist', (tester) async {
      final r = await _pump(
        tester,
        const AudioDetailPage.album(name: '十一月的萧邦', albumArtist: '示例歌手'),
        responses: {
          '$_as.Song.list': {
            'songs': [_song()],
            'total': 1,
          },
        },
      );
      final call = _call(r.t, '$_as.Song', 'list');
      expect(call['album'], '十一月的萧邦');
      expect(call['album_artist'], '示例歌手');
      expect(find.text('示例歌曲'), findsOneWidget);
    });

    testWidgets('点收藏 → Pin.pin（type=album + criteria）', (tester) async {
      final r = await _pump(
        tester,
        const AudioDetailPage.album(name: '十一月的萧邦', albumArtist: '示例歌手'),
        responses: {
          '$_as.Song.list': {
            'songs': [_song()],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-pin-add')));
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(r.t, '$_as.Pin', 'pin');
      expect(call['version'], '1');
      expect(
        call['items'],
        '[{"type":"album","criteria":{"album":"十一月的萧邦","album_artist":"示例歌手"},"name":"十一月的萧邦"}]',
      );
      expect(find.text('已加入收藏'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // 送走 SnackBar 计时器
    });

    testWidgets('播放列表详情 → Playlist.getinfo 的曲目渲染', (tester) async {
      final r = await _pump(
        tester,
        const AudioDetailPage.playlist(id: 'playlist_1', name: '通勤'),
        responses: {
          '$_as.Playlist.getinfo': {
            'playlists': [
              {
                'id': 'playlist_1',
                'name': '通勤',
                'additional': {
                  'songs': [
                    {
                      'id': 'music_1',
                      'path': '/m/a.mp3',
                      'title': 'a',
                      'additional': _song(title: 'a')['additional'],
                    },
                  ],
                  'songs_total': 1,
                },
              },
            ],
          },
        },
      );
      final call = _call(r.t, '$_as.Playlist', 'getinfo');
      expect(
        call['additional'],
        'songs_song_tag,songs_song_audio,songs_song_rating,sharing_info',
      );
      expect(find.text('a'), findsOneWidget);
    });
  });

  group('收藏页（Pin）', () {
    testWidgets('列出收藏；取消收藏 → Pin.unpin 发 items 数组', (tester) async {
      final r = await _pump(
        tester,
        const AudioPinsPage(),
        responses: {
          '$_as.Pin.list': {
            'items': [
              {
                'id': 'pin_1',
                'type': 'artist',
                'name': '示例歌手',
                'criteria': {'artist': '示例歌手'},
              },
            ],
            'total': 1,
          },
        },
      );
      expect(find.text('示例歌手'), findsWidgets);
      await tester.tap(find.byKey(const Key('as-unpin-pin_1')));
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(r.t, '$_as.Pin', 'unpin');
      expect(call['items'], '["pin_1"]');
      expect(call.containsKey('id'), isFalse);
      expect(find.text('已取消收藏'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // 送走 SnackBar 计时器
    });

    testWidgets('一条收藏都没有 → 空态 + 引导', (tester) async {
      await _pump(tester, const AudioPinsPage(), responses: const {});
      expect(find.text('还没有收藏'), findsOneWidget);
      expect(find.text('在专辑、艺术家、流派或播放列表上点「收藏」就会出现在这里'), findsOneWidget);
    });

    testWidgets('未安装 → 与"没有收藏"区分', (tester) async {
      await _pump(tester, const AudioPinsPage(), noAs: true);
      expect(find.text('这台 NAS 没有安装 Audio Station'), findsOneWidget);
      expect(find.text('还没有收藏'), findsNothing);
    });

    // P1-7 接线（此前 `Pin.rename` / `Pin.reorder` 只有数据层/测试引用）。
    testWidgets('重命名收藏 → Pin.rename（id + name）', (tester) async {
      final r = await _pump(
        tester,
        const AudioPinsPage(),
        responses: {
          '$_as.Pin.list': {
            'items': [
              {
                'id': 'pin_1',
                'type': 'artist',
                'name': '示例歌手',
                'criteria': {'artist': '示例歌手'},
              },
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.byKey(const Key('as-pin-rename-pin_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('as-pin-rename-field')),
        '我的示例歌手',
      );
      await tester.tap(find.byKey(const Key('as-pin-rename-confirm')));
      await tester.pump(const Duration(milliseconds: 200));
      final call = _call(r.t, '$_as.Pin', 'rename');
      expect(call['id'], 'pin_1');
      expect(call['name'], '我的示例歌手');
      expect(find.text('已重命名收藏'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // 送走 SnackBar 计时器
    });

    testWidgets('拖动排序 → Pin.reorder 按新次序下发', (tester) async {
      final r = await _pump(
        tester,
        const AudioPinsPage(),
        responses: {
          '$_as.Pin.list': {
            'items': [
              {
                'id': 'pin_1',
                'type': 'artist',
                'name': '示例歌手',
                'criteria': {'artist': '示例歌手'},
              },
              {
                'id': 'pin_2',
                'type': 'album',
                'name': '十一月的萧邦',
                'criteria': {'album': '十一月的萧邦'},
              },
            ],
            'total': 2,
          },
        },
      );
      // 显式拖动手柄：把第二项往上拖到第一项之前。
      // 逐帧 pump（`tester.drag` 的 down→move→up 一气呵成不给中间帧，
      // `ReorderableList` 需要在拖动中重建才认得落点）。
      final drag = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('as-pin-drag-pin_2'))),
      );
      await tester.pump();
      await drag.moveBy(const Offset(0, -80));
      await tester.pump();
      await drag.moveBy(const Offset(0, -80));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      final call = _call(r.t, '$_as.Pin', 'reorder');
      // ★ r398 真机定案：载荷是 **id 数组**（新次序），不是记录数组。
      //   旧断言比的是 `"album"`/`"artist"` 在字符串里的位置 ⇒ 它锁住的正是
      //   **修前在真机上必 117 的形态**（"用例全绿 + 真机全红"同时成立过）。
      expect(call['items'], '["pin_2","pin_1"]', reason: '${call['items']}');
      expect(call['limit'], -1);
    });

    // ★ r405：④ 残留「改名短路」—— 同名/空名必须**零请求**（连提示都不该有）。
    testWidgets('重命名：名称没改 → 不发 Pin.rename、不提示', (tester) async {
      final r = await _pump(
        tester,
        const AudioPinsPage(),
        responses: {
          '$_as.Pin.list': {
            'items': [
              {
                'id': 'pin_1',
                'type': 'artist',
                'name': '示例歌手',
                'criteria': {'artist': '示例歌手'},
              },
            ],
            'total': 1,
          },
        },
      );
      // ① 原样确认（名称与当前相同）
      await tester.tap(find.byKey(const Key('as-pin-rename-pin_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-pin-rename-confirm')));
      await tester.pump(const Duration(milliseconds: 200));
      // ② 清空后确认（空名）
      await tester.tap(find.byKey(const Key('as-pin-rename-pin_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('as-pin-rename-field')),
        '   ',
      );
      await tester.tap(find.byKey(const Key('as-pin-rename-confirm')));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        r.t.calls.where((c) => c['method'] == 'rename'),
        isEmpty,
        reason: '同名/空白名走短路，不许发请求（真机上会白改一次服务端）',
      );
      expect(find.text('已重命名收藏'), findsNothing);
    });

    // ★ r405：④ 残留「≥4 条长距离拖动」—— 4 条里把**最后一条拖到最前**，
    //   载荷必须是完整的 4 个 id 新次序（r398 定案：id 数组，不是记录数组）。
    testWidgets('4 条收藏：把第 4 条拖到第 1 位 → Pin.reorder 下发完整新次序', (tester) async {
      Map<String, dynamic> item(String id, String name) => {
        'id': id,
        'type': 'artist',
        'name': name,
        'criteria': {'artist': name},
      };
      final r = await _pump(
        tester,
        const AudioPinsPage(),
        responses: {
          '$_as.Pin.list': {
            'items': [
              item('pin_1', 'A'),
              item('pin_2', 'B'),
              item('pin_3', 'C'),
              item('pin_4', 'D'),
            ],
            'total': 4,
          },
        },
      );
      expect(find.byKey(const Key('as-pin-pin_4')), findsOneWidget);
      final from = tester.getCenter(find.byKey(const Key('as-pin-drag-pin_4')));
      final to = tester.getCenter(find.byKey(const Key('as-pin-drag-pin_1')));
      final drag = await tester.startGesture(from);
      await tester.pump();
      // 长距离：分多步移动（一次移动过大 ReorderableList 不重建落点）。
      const steps = 6;
      for (var i = 1; i <= steps; i++) {
        await drag.moveTo(
          Offset(from.dx, from.dy + (to.dy - from.dy) * i / steps),
        );
        await tester.pump();
      }
      await drag.up();
      await tester.pumpAndSettle();
      final call = _call(r.t, '$_as.Pin', 'reorder');
      expect(
        call['items'],
        '["pin_4","pin_1","pin_2","pin_3"]',
        reason: '${call['items']}',
      );
      expect(call['limit'], -1);
    });
  });

  // ==================================================================
  // W1-3 收尾：AS 播放队列持久化 + 按 id 回填（Song.getinfo）
  // ==================================================================
  group('单曲页：AS 队列持久化（按 id 回填）', () {
    /// 每次 `Song.getinfo` 按 id 回不同解析（模拟"有的歌被删了"）。
    ///
    /// 不在 [ids] 里的 id 回**空 data**（不是 null —— `FakeTransport` 里
    /// null 表示"这次不走动态回应"，会退回静态 responses）。
    Map<String, dynamic>? Function(Map<String, dynamic>) onlyTheseIds(
      Set<String> ids,
    ) => (params) {
      if (params['api'] != '$_as.Song' || params['method'] != 'getinfo') {
        return null;
      }
      final id = params['id'];
      if (id is! String || !ids.contains(id)) return <String, dynamic>{};
      return {
        'songs': [_song(id: id, title: id, path: '/m/$id.mp3')],
      };
    };

    testWidgets('快照包含这次打开的歌 → 整个队列按 id 回填（顺序保持、下标落在这首）', (tester) async {
      final store = InMemoryMediaPlaybackStore(
        audioQueue: AudioQueueSnapshot(
          items: [
            AudioQueueRef(id: 'music_3', title: 'c'),
            AudioQueueRef(id: 'music_1', title: 'a'),
            AudioQueueRef(id: 'music_2', title: 'b'),
          ],
          currentId: 'music_3',
        ),
      );
      final r = await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: 'a'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song(id: 'music_1', title: 'a')],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
        onCall: onlyTheseIds({'music_1', 'music_2', 'music_3'}),
        moreOverrides: [mediaPlaybackStoreProvider.overrideWithValue(store)],
      );
      // 队列回来了：快照 3 首、当前是第 2 条（music_1 的位置，不抢用户选择）
      expect(find.byKey(const Key('as-queue-position')), findsOneWidget);
      expect(find.text('2/3'), findsOneWidget);
      // 另外两首**只能**来自回填（页面自己只会 getinfo 当前这一首）
      final asked = r.t.calls
          .where((c) => c['api'] == '$_as.Song' && c['method'] == 'getinfo')
          .map((c) => c['id'])
          .toSet();
      expect(asked, containsAll(<String>['music_2', 'music_3']));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('回填失败（歌被删）→ 跳过那一首 + 告知，其余照常恢复、快照不清空', (tester) async {
      final store = InMemoryMediaPlaybackStore(
        audioQueue: AudioQueueSnapshot(
          items: [
            AudioQueueRef(id: 'music_1', title: 'a'),
            AudioQueueRef(id: 'gone', title: '被删的歌'),
            AudioQueueRef(id: 'music_3', title: 'c'),
          ],
          currentId: 'music_1',
        ),
      );
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: 'a'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song(id: 'music_1', title: 'a')],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
        onCall: onlyTheseIds({'music_1', 'music_3'}),
        moreOverrides: [mediaPlaybackStoreProvider.overrideWithValue(store)],
      );
      // 回填是异步链（3 次 getinfo）→ 再给一帧让 SnackBar 真的挂上去
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // 跳过 + 告知（不是静默丢、也不是把队列清空）
      expect(find.textContaining('已跳过'), findsOneWidget);
      expect(
        find.text('1/2'),
        findsOneWidget,
        reason: 'music_1 + music_3 仍是队列',
      );
      final saved = await store.loadAudioQueue();
      expect(saved!.items.map((e) => e.id), [
        'music_1',
        'gone',
        'music_3',
      ], reason: '恢复失败不得清掉已存快照（可能只是这会儿无权限/离线）');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('这次带了显式队列 → 不用快照覆盖用户点开的列表', (tester) async {
      final store = InMemoryMediaPlaybackStore(
        audioQueue: AudioQueueSnapshot(
          items: [
            AudioQueueRef(id: 'music_3', title: 'c'),
            AudioQueueRef(id: 'music_1', title: 'a'),
          ],
          currentId: 'music_3',
        ),
      );
      final r = await _pump(
        tester,
        AudioSongDetailPage(
          songId: 'music_1',
          title: 'a',
          queue: [AudioSongDto(id: 'music_1', title: 'a', path: '/m/1.mp3')],
        ),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song(id: 'music_1', title: 'a')],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
        onCall: onlyTheseIds({'music_1', 'music_3'}),
        moreOverrides: [mediaPlaybackStoreProvider.overrideWithValue(store)],
      );
      expect(find.byKey(const Key('as-queue-position')), findsNothing);
      final asked = r.t.calls
          .where((c) => c['api'] == '$_as.Song' && c['method'] == 'getinfo')
          .map((c) => c['id'])
          .toSet();
      expect(asked.contains('music_3'), isFalse, reason: '不该去回填别的歌');
    });

    testWidgets('起播成功 → 队列 + 起点落盘（只存 id，不存带 _sid 的直链）', (tester) async {
      final store = InMemoryMediaPlaybackStore();
      final r = await _pump(
        tester,
        AudioSongDetailPage(
          songId: 'music_1',
          title: 'a',
          queue: [
            AudioSongDto(id: 'music_1', title: 'a', path: '/m/1.mp3'),
            AudioSongDto(id: 'music_2', title: 'b', path: '/m/2.mp3'),
          ],
          queueIndex: 1,
        ),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song(id: 'music_1', title: 'a')],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
        onCall: onlyTheseIds({'music_1', 'music_2'}),
        moreOverrides: [mediaPlaybackStoreProvider.overrideWithValue(store)],
      );
      expect(await store.loadAudioQueue(), isNull, reason: '还没起播 → 不落盘');
      await tester.tap(find.byKey(const Key('as-play')));
      await tester.pump(const Duration(milliseconds: 200));
      final saved = await store.loadAudioQueue();
      expect(saved, isNotNull);
      expect(saved!.items.map((e) => e.id), ['music_1', 'music_2']);
      expect(saved.currentId, 'music_2', reason: '落的是本次起播的下标');
      expect(r.player.played, isNotEmpty);
    });
  });

  // ==================================================================
  // 收尾遗留 1：AS 播放队列的**常驻 AppBar 入口**
  //   与文件页「下载任务」入口（`file_browse_page.dart` 的
  //   `_DownloadTasksButton`）同性质：徽标显数量、点开才是列表、空态不空白、
  //   能力/会话不足时**隐藏**（原因由正文既有状态给出）。
  // ==================================================================
  group('单曲页：播放队列常驻入口（遗留 1）', () {
    AudioSongDto dto(String id, String title) =>
        AudioSongDto.fromJson(_song(id: id, title: title, path: '/m/$id.mp3'));

    testWidgets('带队列 → 入口在、徽标显示数量；点开列出整条队列（不是空白弹层）', (tester) async {
      final r = await _pump(
        tester,
        AudioSongDetailPage(
          songId: 'music_1',
          title: 'a',
          queue: [
            dto('music_1', 'a'),
            dto('music_2', 'b'),
            dto('music_3', 'c'),
          ],
          queueIndex: 1,
        ),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      expect(find.byKey(const Key('as-queue-entry')), findsOneWidget);
      final badge = find.byKey(const Key('as-queue-badge'));
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('3')),
        findsOneWidget,
        reason: '徽标要显示队列数量',
      );

      // ★ r524（DA167）：这两条**不是守卫**，只是"别越界"的回归保持 ——
      // 实测反向（去掉 `offset`）两向都绿 ⇒ 800 宽下 AppBar 的内边距不足以
      // 把徽标推出去，widget 环境**复现不了**真机那个偏移。
      // 真证据只有 `docs/evidence-r524/` 的真机像素。
      // 量的是徽标那个「数字」的矩形，不是 `Badge` 本身（`Badge` 的矩形等于
      // child，`offset` 只动数字 —— 第一版量错了，永远绿）。
      final dot = tester.getRect(
        find.descendant(of: badge, matching: find.text('3')),
      );
      final entry = tester.getRect(find.byKey(const Key('as-queue-entry')));
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      // 数字必须落在图标框的右上角"附近"：右边不越过图标右边界 +8，
      // 上边不低于图标上边界 -8（真机上原来飘高 ~17、右移 ~30）。
      expect(
        dot.right,
        lessThanOrEqualTo(entry.right + 8),
        reason: 'DA167：徽标右移出图标外（真机是悬在状态栏附近的红点）',
      );
      expect(
        dot.top,
        greaterThanOrEqualTo(entry.top - 8),
        reason: 'DA167：徽标飘到图标上方太高，不在角上',
      );
      expect(dot.left, lessThan(size.width - 8), reason: 'DA167：徽标跑到屏幕右边缘之外');

      await tester.tap(find.byKey(const Key('as-queue-entry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-queue-list')), findsOneWidget);
      expect(find.byKey(const Key('as-queue-item-music_1')), findsOneWidget);
      expect(find.byKey(const Key('as-queue-item-music_2')), findsOneWidget);
      expect(find.byKey(const Key('as-queue-item-music_3')), findsOneWidget);
      expect(r.player.played, isEmpty, reason: '打开队列 ≠ 起播');
    });

    testWidgets('空队列 → 入口在但无徽标；点开是空态（不是空白弹层）', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: 'a'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': 'l'},
        },
      );
      expect(find.byKey(const Key('as-queue-entry')), findsOneWidget);
      expect(find.byKey(const Key('as-queue-badge')), findsNothing);
      await tester.tap(find.byKey(const Key('as-queue-entry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-queue-empty')), findsOneWidget);
      expect(find.text('播放队列还是空的（当前是单曲播放）'), findsOneWidget);
    });

    testWidgets('套件未安装 → 入口隐藏，原因由正文的未安装空态给出', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: 'a'),
        noAs: true,
      );
      expect(find.byKey(const Key('as-queue-entry')), findsNothing);
      expect(find.byKey(const Key('as-not-installed')), findsOneWidget);
    });

    testWidgets('未连接会话（api==null）→ 入口隐藏，原因由正文的未连接空态给出', (tester) async {
      final c = ProviderContainer(
        overrides: [audioApiProvider.overrideWithValue(null)],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: AudioSongDetailPage(songId: 'music_1', title: 'a'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('as-queue-entry')), findsNothing);
      expect(find.text('未连接'), findsOneWidget);
      // 让恢复队列的异步链跑完，别把定时器留到用例结束
      await tester.pump(const Duration(seconds: 5));
    });
  });

  // ★ r639（**DA232**）：「0 秒不是未知」这条规则只修到**看得见的那一处**。
  //   真机 dump 抓到两处漏网：① 进度条的**读屏值**仍念 `— / 3:51`；
  //   ② 全屏歌词头上的位置仍画 `—`。机制已在（DA231 的
  //   `asPositionText`），但**不是所有路径都走了它**。
  group('r639 · DA232 零位读数：看得见与听得见必须一致', () {
    testWidgets('DA232 进度条读屏值在 0 秒念 0:00，不念破折号', (tester) async {
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
        },
      );
      await tester.tap(find.byKey(const Key('as-song-music_1')));
      await tester.pumpAndSettle();
      r.player.emitDuration(const Duration(minutes: 3, seconds: 51));
      await tester.pump(const Duration(milliseconds: 50));

      final slider = tester.widget<Slider>(
        find.byKey(const Key('as-progress')),
      );
      final spoken = slider.semanticFormatterCallback!(0);
      expect(
        spoken,
        startsWith('0:00'),
        reason: 'DA232：读屏念的是「播到哪儿」，0 秒必须念 0:00（修前是 `—`）',
      );
      expect(spoken, contains('3:51'), reason: 'DA232：总长仍在同一句里念出来');
      // 看得见的那一端也必须一致（同屏两个字面不许一方说 0:00、一方说 —）
      expect(
        tester
            .widget<Text>(find.byKey(const Key('as-progress-current')))
            .data,
        '0:00',
      );
      // 反向：拖到中段时读屏值必须跟着变，不许恒为 0:00
      expect(
        slider.semanticFormatterCallback!(120000),
        startsWith('2:00'),
        reason: 'DA232 反向：非零位置必须念真实位置',
      );
    });

    testWidgets('DA232 全屏歌词头部的「播到哪儿」在 0 秒写 0:00', (tester) async {
      final r = await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {
            'songs': [_song()],
            'total': 1,
          },
          '$_as.Song.getinfo': {
            'songs': [_song(rating: 4)],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': '[00:01]一群嗜血的蚂蚁\n[00:09]第二句'},
        },
      );
      await tester.tap(find.byKey(const Key('as-song-music_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-lyrics-expand')));
      await tester.pumpAndSettle();

      final label = tester.widget<Text>(
        find.byKey(const Key('as-lyrics-full-position')),
      );
      // ★ r643（DA238）：总时长知道 ⇒ 与单曲页同一种读数（`x / y`）
      expect(
        label.data,
        '0:00 / 3:47',
        reason: 'DA232：真机 dump 在这个位置读到 `—`（暂停/未起播时位置流不给值）；'
            'DA238：总时长必须跟单曲页一样写出来',
      );

      // 反向：位置真的推到 1:23 时，这里必须显示 1:23 而不是恒 0:00
      r.player.emitPosition(const Duration(minutes: 1, seconds: 23));
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('as-lyrics-full-position')))
            .data,
        '1:23 / 3:47',
      );
    });
  });

  // ★★★ r643（`DA237` / `DA238`）：界面上说「人话」——
  //   ① 术语「无时间轴 / No timeline」是人看不懂的实现词，改成「不会自动滚动」；
  //   ② 全屏歌词底部只有「播到哪儿」，没有总长（单曲页有）⇒ 同一件事两种读数。
  group('★ r643 DA237/DA238：歌词用人的话 + 全屏也有总长', () {
    testWidgets('DA237 候选行不跟唱时说「不会自动滚动」，不再出现术语', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.LyricsSearch.searchlyrics': {'lyrics': ''},
        },
        moreOverrides: [
          mediaLyricsLookupProvider.overrideWithValue(
            LyricsLookup(
              source: _FakeLyricsSource(const [
                LyricCandidate(
                  id: 31,
                  trackName: '示例歌曲',
                  artistName: '示例歌手',
                  duration: Duration(seconds: 227),
                  syncedLyrics: '[00:05.00]带时间的一份',
                ),
                LyricCandidate(
                  id: 32,
                  trackName: '示例歌曲（现场）',
                  artistName: '示例歌手',
                  duration: Duration(seconds: 230),
                  // 只有纯文本 ⇒ `hasSynced == false`
                ),
              ]),
              cache: InMemoryLyricsCache(),
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-lyrics-pick')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('as-lyrics-candidates')), findsOneWidget);
      expect(
        find.textContaining('不会自动滚动'),
        findsWidgets,
        reason: 'DA237：不跟唱这件事要用用户看得懂的说法写出来',
      );
      expect(
        find.textContaining('无时间轴'),
        findsNothing,
        reason: 'DA237 反向：术语不许再出现（修前这里就是「无时间轴」）',
      );
    });

    testWidgets('DA237 纯文本歌词的正文提示不说「时间轴」', (tester) async {
      await _pump(
        tester,
        const AudioSongDetailPage(songId: 'music_1', title: '示例歌曲'),
        responses: {
          '$_as.Song.getinfo': {
            'songs': [_song()],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': '一行词\n另一行词'},
        },
      );
      await tester.pumpAndSettle();
      final hint = tester.widget<Text>(
        find.byKey(const Key('lyrics-untimed-hint')),
      );
      expect(hint.data, contains('不会自动滚动'));
      expect(
        hint.data,
        isNot(contains('时间轴')),
        reason: 'DA237：提示里不许再出现「时间轴」这个实现术语',
      );
      expect(
        hint.data,
        contains('手动滑'),
        reason: 'DA237：要顺手告诉人该怎么做（自己滑）',
      );
    });

    testWidgets('DA238 总长未知 ⇒ 全屏歌词只写位置，不编 0:00 尾巴', (tester) async {
      final noDuration = _song();
      // 服务端没给 `song_audio.duration` 时就是 0 —— 这时不许画 `/ 0:00`
      (noDuration['additional'] as Map)['song_audio'] = {
        'bitrate': 320000,
        'frequency': 44100,
        'channel': 2,
        'filesize': 9090909,
      };
      await _pump(
        tester,
        const AudioPage(),
        responses: {
          '$_as.Song.list': {
            'songs': [noDuration],
            'total': 1,
          },
          '$_as.Song.getinfo': {
            'songs': [noDuration],
          },
          '$_as.Lyrics.getlyrics': {'lyrics': '[00:01]第一句\n[00:09]第二句'},
        },
      );
      await tester.tap(find.byKey(const Key('as-song-music_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('as-lyrics-expand')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('as-lyrics-full-position')))
            .data,
        '0:00',
        reason: 'DA238 反向：总长未知就只写位置（编一个 0:00 尾巴更糟）',
      );
    });
  });
}
