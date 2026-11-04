// 音频播放舞台的**歌词/控件**界面测试（假 VoicePlayer + 假歌词源，全程离线）。
//
// 为什么单独一个文件：`media_player_page_test.dart` 那些既有用例钉的是
// "播放/暂停/拖动/倍速/回退面板"的老行为（必须保持绿），而本文件钉的是第 260 轮
// **新加的三块**：
//   ① 逐行歌词：当前行高亮 + 随播放位置滚动 + **点某行跳转到该时间点**；
//   ② 歌词关联：自动搜一次 → 候选可换 → 失败给**可读原因 + 重试**；缓存命中不联网；
//   ③ 播放器新增控件：单曲循环、睡眠定时（以及律动可视化在页面上真的存在）。
//
// 三条纪律（都是本仓踩过的坑）：
//   * 不许出现**常驻动画**（`CircularProgressIndicator` 会让 `pumpAndSettle` 超时）；
//   * 断言要打在**可观测点**上（key）而不是"看起来像"；
//   * 涉及像素解码的异步必须走 `runAsync`（本文件没有，但注释留给后来人）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/chat/voice_message.dart'
    show VoicePlayer, voicePlayerProvider;
import 'package:synhub/src/features/media/audio_lyrics.dart';
import 'package:synhub/src/features/media/media_audio_stage.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/media_source.dart';
// ★ r411（DA66）：署名的**分隔符**必须跟着语言走（DA38 同族），
// 所以这里要能真的切到英文表。
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/data_text.dart';
import 'package:synhub/src/core/i18n/l10n.dart';

// ─────────────────────────────────────────────────────────────── 测试替身

/// 假播放器：状态由用例直接摆布，调用全记录。
class _FakePlayer implements VoicePlayer {
  final _changes = StreamController<void>.broadcast();

  final played = <String>[];
  int resumes = 0;
  int pauses = 0;
  final seeks = <Duration>[];
  final speeds = <double>[];

  Duration _position = Duration.zero;
  Duration? _duration = const Duration(seconds: 100);
  String? _currentUrl;
  bool _hasSource = false;

  set duration(Duration? v) => _duration = v;

  @override
  bool playing = false;

  @override
  double speed = 1;

  @override
  Duration? get duration => _duration;

  @override
  Duration get position => _position;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  String? get currentUrl => _currentUrl;

  @override
  bool get hasSource => _hasSource;

  void emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 模拟"播放位置推进"（真实链路里这是位置流每 200ms 的更新）
  void setPosition(Duration d) {
    _position = d;
    emit();
  }

  @override
  Future<void> play(String url) async {
    played.add(url);
    _currentUrl = url;
    _hasSource = true;
    _position = Duration.zero;
    playing = true;
    emit();
  }

  @override
  Future<void> resume() async {
    resumes++;
    playing = true;
    emit();
  }

  @override
  Future<void> pause() async {
    pauses++;
    playing = false;
    emit();
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _position = position;
    emit();
  }

  @override
  Future<void> setSpeed(double value) async {
    speeds.add(value);
    speed = value;
  }

  @override
  Future<void> stop() async {
    playing = false;
    _hasSource = false;
    emit();
  }

  void dispose() => _changes.close();
}

/// 假歌词源：要什么给什么，记录请求，可指定失败。
class _FakeLyricsSource implements LyricsSource {
  _FakeLyricsSource({this.results = const [], this.failWith});

  List<LyricCandidate> results;
  LyricsFailureKind? failWith;
  final searched = <LyricsQuery>[];
  final fetchedIds = <int>[];

  @override
  Future<List<LyricCandidate>> search(LyricsQuery query) async {
    searched.add(query);
    final f = failWith;
    if (f != null) throw LyricsFetchException(f);
    return results;
  }

  @override
  Future<LyricCandidate?> fetchById(int id) async {
    fetchedIds.add(id);
    for (final c in results) {
      if (c.id == id) return c;
    }
    return null;
  }
}

LyricCandidate _cand({
  required int id,
  required String track,
  String artist = '',
  String album = '',
  Duration? duration,
  String? synced,
  String? plain,
}) => LyricCandidate(
  id: id,
  trackName: track,
  artistName: artist,
  albumName: album,
  duration: duration,
  syncedLyrics: synced,
  plainLyrics: plain,
);

/// 30 行带时间轴的歌词（每 4 秒一行）—— 用来"把当前行滑出视口"。
///
/// 三行那份在小面板里永远滚不远（内容不足一屏），测不到 DA239 的落点。
final String _kLongSynced = List<String>.generate(
  30,
  (i) => '[00:${(i * 4).toString().padLeft(2, '0')}.00]第${i + 1}句歌词',
).join('\n');

/// 三行带时间轴的歌词（1s / 5s / 9s）
const String _kSynced =
    '[00:01.00]第一行\n[00:05.00]第二行\n[00:09.00]第三行';

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/home/Music/$name',
  isDir: false,
  size: 4 * 1024 * 1024,
  mtime: 1758100000,
);

MediaSource _audioSource({bool supportsRange = true, String? uri}) => MediaSource(
  uri:
      uri ??
      'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download&_sid=S1',
  channel: MediaChannel.fileStation,
  kind: MediaKind.audio,
  displayName: 'song.mp3',
  supportsRange: supportsRange,
);

void main() {
  /// 挂舞台：手机面（420x900 逻辑像素）—— 800x600 的默认窗口下封面会走紧凑模式，
  /// 歌词面板虽在但可视区偏小，这里按真机竖屏给尺寸，让交互断言打在真实布局上。
  Future<(_FakePlayer, _FakeLyricsSource, ProviderContainer)> pumpStage(
    WidgetTester tester, {
    _FakePlayer? player,
    _FakeLyricsSource? source,
    LyricsCache? cache,
    MediaSource? mediaSource,
    String fileName = 'Hey Jude.mp3',
  }) async {
    tester.view.physicalSize = const Size(1050, 2250);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);

    final p = player ?? _FakePlayer();
    final s = source ?? _FakeLyricsSource();
    addTearDown(p.dispose);
    final container = ProviderContainer(
      overrides: [
        voicePlayerProvider.overrideWithValue(p),
        mediaLyricsSourceProvider.overrideWithValue(s),
        mediaLyricsCacheProvider.overrideWithValue(cache ?? InMemoryLyricsCache()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: MediaAudioStage(
              entry: _entry(fileName),
              source: mediaSource ?? _audioSource(),
            ),
          ),
        ),
      ),
    );
    // 首帧 → 自动取歌词（缓存 → 联网）两跳异步
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    return (p, s, container);
  }

  /// 当前高亮行的文字（没有高亮行 → null）
  String? activeLine(WidgetTester tester) {
    final f = find.byKey(const Key('audio-lyrics-current'));
    if (f.evaluate().isEmpty) return null;
    return tester.widget<Text>(f).data;
  }

  group('逐行歌词：高亮 + 跟随 + 点击跳转', () {
    testWidgets('打开就自动取一次歌词，并渲染成逐行列表（不是一坨纯文本）',
        (tester) async {
      final source = _FakeLyricsSource(
        results: [
          _cand(
            id: 1,
            track: 'Hey Jude',
            duration: const Duration(seconds: 100),
            synced: _kSynced,
          ),
        ],
      );
      final (player, s, _) = await pumpStage(tester, source: source);

      // 只自动查一次（不重复打歌词源）
      expect(s.searched, hasLength(1));
      expect(s.searched.single.title, 'Hey Jude');
      // 逐行渲染：三行都在，且是可点的一行一个（ListView + itemExtent）
      expect(find.byKey(const Key('audio-lyrics')), findsOneWidget);
      expect(find.text('第一行'), findsOneWidget);
      expect(find.text('第二行'), findsOneWidget);
      expect(find.text('第三行'), findsOneWidget);
      // 位置 0 → 还没到第一行 ⇒ 不高亮任何一行
      expect(activeLine(tester), isNull);

      // 位置推进到 1s → 第一行高亮
      player.setPosition(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(activeLine(tester), '第一行');

      // 推进到 5.5s → 高亮第二行（随播放位置滚动）
      player.setPosition(const Duration(milliseconds: 5500));
      await tester.pumpAndSettle();
      expect(activeLine(tester), '第二行');

      // 推进到结尾 → 最后一行继续高亮，不越界
      player.setPosition(const Duration(seconds: 99));
      await tester.pumpAndSettle();
      expect(activeLine(tester), '第三行');
    });

    testWidgets('点某一行歌词 → seek 到该行时间（"点哪唱哪"）', (tester) async {
      final source = _FakeLyricsSource(
        results: [
          _cand(
            id: 1,
            track: 'Hey Jude',
            duration: const Duration(seconds: 100),
            synced: _kSynced,
          ),
        ],
      );
      final (player, _, _) = await pumpStage(tester, source: source);
      expect(player.seeks, isEmpty);

      await tester.tap(find.byKey(const Key('audio-lyrics-line-2')));
      await tester.pumpAndSettle();
      expect(player.seeks, [const Duration(seconds: 9)]);
    });

    testWidgets('时间顺序乱掉的歌词也会先排好（否则高亮会来回跳）', (tester) async {
      final source = _FakeLyricsSource(
        results: [
          _cand(
            id: 1,
            track: 'Hey Jude',
            duration: const Duration(seconds: 100),
            synced: '[00:09.00]晚\n[00:01.00]早',
          ),
        ],
      );
      final (player, _, _) = await pumpStage(tester, source: source);
      player.setPosition(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(activeLine(tester), '早');
    });

    testWidgets('没有时间轴的歌词：**照实显示** + 说明高亮不了（不假装能滚）',
        (tester) async {
      final source = _FakeLyricsSource(
        results: [
          _cand(
            id: 1,
            track: 'Hey Jude',
            duration: const Duration(seconds: 100),
            plain: '只有纯文本的歌词\n第二句',
          ),
        ],
      );
      await pumpStage(tester, source: source);
      expect(find.byKey(const Key('audio-lyrics-plain-hint')), findsOneWidget);
      expect(find.byKey(const Key('audio-lyrics-plain')), findsOneWidget);
      expect(find.byKey(const Key('audio-lyrics')), findsNothing);
      // 纯文本模式没有"当前行"
      expect(activeLine(tester), isNull);
    });

    testWidgets('来源不支持 Range：歌词行不可点（不给假的"点哪唱哪"）', (tester) async {
      final source = _FakeLyricsSource(
        results: [
          _cand(
            id: 1,
            track: 'Hey Jude',
            duration: const Duration(seconds: 100),
            synced: _kSynced,
          ),
        ],
      );
      final (player, _, _) = await pumpStage(
        tester,
        source: source,
        mediaSource: _audioSource(supportsRange: false),
      );
      final line = tester.widget<InkWell>(
        find.byKey(const Key('audio-lyrics-line-0')),
      );
      expect(line.onTap, isNull);
      await tester.tap(find.byKey(const Key('audio-lyrics-line-0')));
      await tester.pumpAndSettle();
      expect(player.seeks, isEmpty);
      // 同时：滑块的拖动也仍然禁用 + 有说明（既有行为不回归）
      expect(
        tester.widget<Slider>(find.byKey(const Key('audio-progress'))).onChanged,
        isNull,
      );
      expect(find.byKey(const Key('audio-no-seek-hint')), findsOneWidget);
    });
  });

  group('歌词关联：候选 / 重搜 / 失败 / 缓存', () {
    testWidgets('多个候选时可以换版本：弹层列出候选，选中即生效', (tester) async {
      final source = _FakeLyricsSource(
        results: [
          _cand(
            id: 11,
            track: 'Hey Jude',
            artist: '某人',
            duration: const Duration(seconds: 300),
            synced: '[00:01.00]别人唱的',
          ),
          _cand(
            id: 22,
            track: 'Hey Jude',
            artist: 'The Beatles',
            duration: const Duration(seconds: 100),
            synced: '[00:01.00]原唱的',
          ),
        ],
      );
      await pumpStage(tester, source: source);
      // 自动挑时长最接近的那份（100s）
      expect(find.text('原唱的'), findsOneWidget);

      await tester.tap(find.byKey(const Key('audio-lyrics-pick')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-lyrics-candidates')), findsOneWidget);
      // 候选里如实显示 曲名 · 歌手 · 时长
      expect(
        find.byKey(const Key('audio-lyrics-candidate-11')),
        findsOneWidget,
      );
      expect(find.textContaining('The Beatles'), findsWidgets);

      await tester.tap(find.byKey(const Key('audio-lyrics-candidate-11')));
      await tester.pumpAndSettle();
      // 明明白白换成用户选的那一份
      expect(find.text('别人唱的'), findsOneWidget);
      expect(find.text('原唱的'), findsNothing);
    });

    testWidgets('搜不到：给可读原因 + 重试入口；重试后能出歌词', (tester) async {
      final source = _FakeLyricsSource();
      await pumpStage(tester, source: source);
      expect(find.byKey(const Key('audio-lyrics-empty')), findsOneWidget);
      expect(find.text('没有找到这首歌的歌词'), findsOneWidget);
      expect(find.byKey(const Key('audio-lyrics-research')), findsOneWidget);

      // 用户点了重试：这次源站有了
      source.results = [
        _cand(
          id: 1,
          track: 'Hey Jude',
          duration: const Duration(seconds: 100),
          synced: _kSynced,
        ),
      ];
      await tester.tap(find.byKey(const Key('audio-lyrics-research')));
      await tester.pumpAndSettle();
      expect(find.text('第一行'), findsOneWidget);
      expect(source.searched, hasLength(2));
    });

    testWidgets('离线：说的是"网络不可用"（不是"没有这首歌"），可重试', (tester) async {
      final source = _FakeLyricsSource(failWith: LyricsFailureKind.offline);
      await pumpStage(tester, source: source);
      expect(find.text('网络不可用，无法联网搜歌词'), findsOneWidget);
      expect(find.text('没有找到这首歌的歌词'), findsNothing);
      expect(find.byKey(const Key('audio-lyrics-research')), findsOneWidget);
    });

    testWidgets('命中本地缓存：直接显示 + 标"已用本地缓存"，且**不联网**', (tester) async {
      final cache = InMemoryLyricsCache();
      // 预置一份缓存（键与舞台算出来的完全一致：曲名|歌手|秒数|路径）
      final query = lyricsQueryForFileName(
        'Hey Jude.mp3',
        duration: const Duration(seconds: 100),
        identity: '/home/Music/Hey Jude.mp3',
      );
      await cache.write(
        query.cacheKey,
        jsonEncode({
          'version': LyricsLookup.cacheSchemaVersion,
          'query': query.toJson(),
          'chosen': _cand(
            id: 1,
            track: 'Hey Jude',
            duration: const Duration(seconds: 100),
            synced: _kSynced,
          ).toJson(),
        }),
      );
      final source = _FakeLyricsSource(
        results: [
          _cand(
            id: 2,
            track: 'Hey Jude',
            duration: const Duration(seconds: 100),
            synced: '[00:01.00]网上那份',
          ),
        ],
      );
      await pumpStage(tester, source: source, cache: cache);
      expect(find.text('第一行'), findsOneWidget);
      // ★ r411（DA66）：「已用本地缓存」这条事实现在由**署名行**统一带出去
      // （原来是 header 里一个独立小标 ⇒ 同一件事两处表示，已合并）。
      final attribution = tester.widget<Text>(
        find.byKey(const Key('audio-lyrics-attribution')),
      );
      expect(attribution.data, contains('已用本地缓存'));
      expect(attribution.data, contains('lrclib.net 公开歌词库'));
      expect(
        source.searched,
        isEmpty,
        reason: '缓存命中就不该再打歌词源（省流量、离线可用）',
      );
    });
  });

  // ★★★ r411（DA66）：**歌词署名**。r403 记下的诚实缺口原文是
  // 「屏上没有任何地方写"这是哪一条候选 / 来自哪个源"」—— 本节把它钉住。
  group('★ r411 DA66：歌词署名（谁唱的 / 从哪来 / 有没有时间轴 / 是不是缓存）', () {
    testWidgets('公开源候选：写明源站 + 曲名 + 歌手 + 专辑；无时间轴要标出来', (tester) async {
      final source = _FakeLyricsSource(
        results: [
          _cand(
            id: 31,
            track: 'Demo Song',
            artist: 'Demo Artist',
            album: '00s Love Songs',
            duration: const Duration(seconds: 231),
            // **无时间轴**（纯文本）⇒ 署名必须自报这一点
            plain: 'Sample lyric line one\nSample lyric line two',
          ),
        ],
      );
      await pumpStage(tester, source: source, fileName: 'Demo Song.mp3');
      final line = tester.widget<Text>(
        find.byKey(const Key('audio-lyrics-attribution')),
      );
      expect(line.data, '歌词来源：lrclib.net 公开歌词库 · Demo Song · Demo Artist · 00s Love Songs · 不会自动滚动');
      // 有正文就不许再出现"没有找到"一类空态话
      expect(find.byKey(const Key('audio-lyrics-empty')), findsNothing);
    });

    testWidgets('服务端那份（没有公开候选）：署名必须写 NAS 歌词库，不许冒领 lrclib', (tester) async {
      // 文件预览页（本文件这个舞台）**只有公开源**一条路：一条候选都没有、
      // 公开源也没拿到 ⇒ 屏上没歌词 ⇒ 署名行不该画（见下一条用例）。
      // 「服务端那份」这条分支属于 Audio Station 单曲页（`test/audio_page_test.dart`）。
      final source = _FakeLyricsSource();
      await pumpStage(tester, source: source, fileName: 'Demo Song.mp3');
      expect(find.byKey(const Key('audio-lyrics-attribution')), findsNothing);
      expect(find.byKey(const Key('audio-lyrics-empty')), findsOneWidget);
    });

    testWidgets('换一个候选之后，署名**跟着换**（不是只换正文）', (tester) async {
      final source = _FakeLyricsSource(
        results: [
          _cand(
            id: 41,
            track: 'Hey Jude',
            artist: 'The Beatles',
            album: 'Past Masters',
            duration: const Duration(seconds: 100),
            synced: '[00:01.00]原唱的',
          ),
          _cand(
            id: 42,
            track: 'Hey Jude',
            artist: '某人',
            album: '翻唱集',
            duration: const Duration(seconds: 300),
            synced: '[00:01.00]别人唱的',
          ),
        ],
      );
      await pumpStage(tester, source: source);
      // 自动挑时长最接近的（100s = The Beatles）
      expect(
        tester.widget<Text>(find.byKey(const Key('audio-lyrics-attribution'))).data,
        contains('The Beatles'),
      );
      await tester.tap(find.byKey(const Key('audio-lyrics-pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio-lyrics-candidate-42')));
      await tester.pumpAndSettle();
      final after = tester.widget<Text>(
        find.byKey(const Key('audio-lyrics-attribution')),
      );
      expect(after.data, contains('某人'));
      expect(after.data, contains('翻唱集'));
      expect(after.data, isNot(contains('The Beatles')));
    });

    testWidgets('没有歌词时**不画**署名行（空态已经有一句话了）', (tester) async {
      final source = _FakeLyricsSource();
      await pumpStage(tester, source: source);
      expect(find.byKey(const Key('audio-lyrics-empty')), findsOneWidget);
      expect(find.byKey(const Key('audio-lyrics-attribution')), findsNothing);
    });

    test('纯函数：源站不给歌手/专辑时，**不许编**出来（只写真有的事实）', () {
      const c = LyricCandidate(
        id: 7,
        trackName: 'Untitled',
        syncedLyrics: '[00:01.00]x',
      );
      expect(
        audioLyricsAttributionText(chosen: c, fromCache: false, timed: true),
        '歌词来源：lrclib.net 公开歌词库 · Untitled',
      );
    });

    // ★ 分隔符必须跟着语言走：第一版把全角「：」硬编码在 lib 里 ⇒
    // 英文界面会印 `Lyrics source：…`（DA38 同族，且会被
    // `test/i18n_hardcoded_cjk_test.dart` 第六条抓红 —— 当轮实测抓到了）。
    test('英文界面：用半角「: 」且整行零 CJK', () {
      setCurrentText(AppTextEn());
      addTearDown(() => setCurrentText(AppTextZh()));
      const c = LyricCandidate(
        id: 8,
        trackName: 'Hey Jude',
        artistName: 'The Beatles',
        syncedLyrics: '[00:01.00]x',
      );
      final line = audioLyricsAttributionText(
        chosen: c,
        fromCache: false,
        timed: true,
      );
      expect(
        line,
        'Lyrics source: lrclib.net public lyrics · Hey Jude · The Beatles',
      );
      expect(
        RegExp(r'[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]').hasMatch(line),
        isFalse,
        reason: '英文界面不许出现中文或全角标点：$line',
      );
    });

    // ★ r644（DA242）：源站把专辑名给成一颗孤零零的 `•`（lrclib 对
    //   `Favorite Girl` 就是这样）⇒ 屏上会念成 `… · Justin Bieber · • · 已用本地缓存`。
    //   只由标点/空白组成的段**一律不进署名**；正常的专辑名照旧保留。
    test('DA242：只由标点组成的专辑名不许进署名（正常的照旧）', () {
      const bullet = LyricCandidate(
        id: 10,
        trackName: 'Favorite Girl',
        artistName: 'Justin Bieber',
        albumName: '•',
        syncedLyrics: '[00:01.00]x',
      );
      final line = audioLyricsAttributionText(
        chosen: bullet,
        fromCache: true,
        timed: true,
      );
      expect(
        line,
        '歌词来源：lrclib.net 公开歌词库 · Favorite Girl · Justin Bieber · 已用本地缓存',
      );
      expect(line.contains('· •'), isFalse);
      // 反向：真专辑名不许被这条规则误伤（含空格/斜杠的都还在）
      const normal = LyricCandidate(
        id: 11,
        trackName: 'Demo Song',
        artistName: 'Demo Artist',
        albumName: 'Hitbreaker 2001/2 - CD2',
        syncedLyrics: '[00:01.00]x',
      );
      expect(
        audioLyricsAttributionText(
          chosen: normal,
          fromCache: false,
          timed: true,
        ),
        contains('Hitbreaker 2001/2 - CD2'),
      );
    });

    test('反向验证：卸掉翻译器（≈ 漏登记）⇒ 回落中文，用例真抓得住', () {
      setDataTextResolver(null);
      addTearDown(() => setCurrentText(AppTextZh()));
      const c = LyricCandidate(id: 9, trackName: 'x', syncedLyrics: 'y');
      final line = audioLyricsAttributionText(
        chosen: c,
        fromCache: false,
        timed: true,
      );
      expect(line, startsWith('歌词来源：'));
    });
  });

  group('新增控件：单曲循环 / 睡眠定时 / 可视化', () {
    testWidgets('律动可视化在页面上真的存在（且不叫"频谱"）', (tester) async {
      await pumpStage(tester);
      expect(find.byKey(const Key('audio-visualizer')), findsOneWidget);
      expect(find.textContaining('频谱'), findsNothing);
    });

    testWidgets('单曲循环：播到结尾自动从头重播', (tester) async {
      final player = _FakePlayer();
      await pumpStage(tester, player: player);
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pumpAndSettle();
      expect(player.played, hasLength(1));

      // 打开单曲循环
      await tester.tap(find.byKey(const Key('audio-repeat-one')));
      await tester.pumpAndSettle();

      // 播到结尾（真实链路里位置流先到 duration，随后 completed 才异步复位）
      player.setPosition(const Duration(seconds: 100));
      await tester.pumpAndSettle();
      expect(player.seeks, contains(Duration.zero));
      expect(
        player.played,
        hasLength(2),
        reason: '单曲循环必须真的重新载入/续播，而不是只把位置归零',
      );
    });

    testWidgets('睡眠定时：能设置、显示在界面上、能取消', (tester) async {
      final player = _FakePlayer();
      await pumpStage(tester, player: player);
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('audio-sleep')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-sleep-15')), findsOneWidget);
      expect(find.byKey(const Key('audio-sleep-90')), findsOneWidget);

      await tester.tap(find.byKey(const Key('audio-sleep-15')));
      await tester.pumpAndSettle();
      // 已经设定 → 界面上有状态，且菜单里出现"取消"
      expect(find.byKey(const Key('audio-sleep-active')), findsOneWidget);
      expect(find.textContaining('15 分钟'), findsWidgets);

      await tester.tap(find.byKey(const Key('audio-sleep')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio-sleep-off')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-sleep-active')), findsNothing);
      // 取消定时**不该**顺手把播放也停掉
      expect(player.playing, isTrue);
    });

    testWidgets('倍速与进度条等既有可观测点没有回归', (tester) async {
      final player = _FakePlayer();
      await pumpStage(tester, player: player);
      final slider = tester.widget<Slider>(
        find.byKey(const Key('audio-progress')),
      );
      expect(slider.onChanged, isNotNull);
      slider.onChangeStart!(42000);
      slider.onChanged!(42000);
      slider.onChangeEnd!(42000);
      await tester.pumpAndSettle();
      expect(player.seeks, [const Duration(seconds: 42)]);

      await tester.tap(find.byKey(const Key('audio-speed')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x').last);
      await tester.pumpAndSettle();
      expect(player.speeds, contains(1.5));
    });
  });

  // ════════════════════════════════════════════════════════════════════
  // ★ r652（**DA253**）· 舞台歌词＝**同一个阅读器**
  //
  // 缺口（人视角）：同一份 LRC，单曲页/全屏歌词在 r644 之后有「滑走了能回到
  // 正在唱的那句」和边缘渐隐，**音频舞台那套自己写的 ListView 没有** ——
  // 同一个 App，两个入口对同一件事有两种行为。
  // 修法＝舞台改走 `SyncedLyricsView`（key 用参数对齐，宿主契约不变）。
  // ════════════════════════════════════════════════════════════════════
  group('DA253 舞台歌词与全屏/单曲页同一行为', () {
    testWidgets('舞台里也有「回到正在唱的那句」（滑走当前行才出现，点完自消）', (tester) async {
      final (player, _, _) = await pumpStage(
        tester,
        source: _FakeLyricsSource(
          results: [
            _cand(
              id: 7,
              track: 'Hey Jude',
              duration: const Duration(seconds: 200),
              synced: _kLongSynced,
            ),
          ],
        ),
      );
      // 第 5 秒 → 高亮第二行
      player.setPosition(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio-lyrics-current')), findsOneWidget);
      expect(
        find.byKey(const Key('lyrics-jump-to-active')),
        findsNothing,
        reason: '当前行还在视野里 ⇒ 不摆这个落点',
      );

      // 手动把歌词列表往下推（当前行被顶出视口顶部）
      await tester.drag(find.byKey(const Key('audio-lyrics')), const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const Key('lyrics-jump-to-active')),
        findsOneWidget,
        reason: '滑走了就要能回去 —— 这是 r644 给单曲页/全屏加的那件事',
      );

      await tester.tap(find.byKey(const Key('lyrics-jump-to-active')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('lyrics-jump-to-active')),
        findsNothing,
        reason: '回到当前句之后落点自己消失',
      );
      expect(find.byKey(const Key('audio-lyrics-current')), findsOneWidget);
    });

    testWidgets('边缘渐隐与全屏一致：内容两侧都有时才两侧渐隐', (tester) async {
      final (player, _, _) = await pumpStage(
        tester,
        source: _FakeLyricsSource(
          results: [
            _cand(
              id: 8,
              track: 'Hey Jude',
              duration: const Duration(seconds: 200),
              synced: _kLongSynced,
            ),
          ],
        ),
      );
      player.setPosition(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      // 渐隐遮罩**常驻**（r644 的教训：按需包会让列表重建、滚动归零）
      expect(find.byKey(const Key('lyrics-edge-fade')), findsOneWidget);
    });
  });
}
