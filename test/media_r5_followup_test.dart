// R5 真机观察到的**三个媒体瑕疵**的离线承重（2026-09-21 真机批次 `a17a40f7…`）：
//
//   1. **面板/顶栏标题取错对象**：用户在播放列表里点「下一个」切到 `theora.mkv`
//      后，回退面板与顶栏标题仍显示打开播放器时的 `clip-h264.mp4`。标题必须来自
//      **当前播放项**（换集、自动续播、索引变化都要跟随）。
//   2. **末尾重播需点两次**：拖到/播到 `01:00` → 点播放 → 第一次只归零不出声，
//      再点一次才起播（`ExoPlayerImpl: Init`）。一次点击就必须从 `00:00` 起播；
//      视频（`MediaPlayerView._toggle`）与音频（`MediaAudioStage._toggle`）两条链路
//      都覆盖，且"暂停态中点播放"不许被误判成重播。
//   3. **自动续播到无解码器条目 → 全黑且没有任何提示**（真实漏报路径）：自动续播
//      进入的条目在看门狗窗口内零画面证据时必须给**非阻塞**提示；同时保持既有
//      取舍（长片"位置在推进 → 抑制上报"，绝不误伤可解码文件）。
//
// 第 3 项用**真实** `NativeVideoPlayerAdapter` + 假 `PlayerBridge`（只注入短窗口），
// 所以断言的是生产接线；第 1、2 项用假适配器/假 VoicePlayer，只把"真机竞争"建模进
// 去（completed 态、位置 tick 偏差）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/chat/voice_message.dart'
    show VoicePlayer, voicePlayerProvider;
import 'package:synhub/src/features/media/media_audio_stage.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/native_video_player.dart';

// ─────────────────────────────────────────────────────────────── 假适配器

/// 完整控制的假适配器（对应自研原生播放器）：可摆布 `index` / `count`。
class _FakeFullAdapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  final _changes = StreamController<void>.broadcast();

  final loaded = <String>[];
  final seeks = <Duration>[];
  int plays = 0;
  int pauses = 0;
  int nexts = 0;

  Duration _position = Duration.zero;
  Duration? _duration = const Duration(seconds: 100);
  bool _playing = false;
  final bool _ready = true;
  int _index = 0;
  int _count = 1;
  String? _error;

  set position(Duration v) => _position = v;
  set duration(Duration? v) => _duration = v;
  set index(int v) => _index = v;
  set count(int v) => _count = v;

  void emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 模拟"播放器运行中报错"（面板入口；标题要写当前播放项）
  void failWith(String message) {
    _error = message;
    emit();
  }

  @override
  Future<void> load(MediaSource source) async {
    loaded.add(source.uri);
    _error = null;
  }

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {
    _count = items.length;
    _index = index;
  }

  @override
  Future<void> play() async {
    plays++;
    _playing = true;
    emit();
  }

  @override
  Future<void> pause() async {
    pauses++;
    _playing = false;
    emit();
  }

  @override
  Future<void> seekTo(Duration position) async {
    _position = position;
    seeks.add(position);
    emit();
  }

  @override
  Future<void> skipBy(Duration offset) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> setMuted(bool value) async {}
  @override
  Future<void> playNext() async => nexts++;
  @override
  Future<void> playPrevious() async {}
  @override
  Future<void> selectAudioTrack(String? id) async {}
  @override
  Future<void> selectSubtitleTrack(String? id) async {}
  @override
  Future<void> setAspectMode(MediaAspectMode mode) async {}

  @override
  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Duration get position => _position;
  @override
  Duration? get duration => _duration;
  @override
  bool get playing => _playing;
  @override
  bool get ready => _ready;
  @override
  double get speed => 1;
  @override
  String? get error => _error;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(key: Key('fake-full-surface'), color: Colors.black);
  @override
  Stream<void> get changes => _changes.stream;
  @override
  double get volume => 1;
  @override
  bool get muted => false;
  @override
  int get playlistIndex => _index;
  @override
  int get playlistLength => _count;
  @override
  bool get hasPrevious => _count > 1 && _index > 0;
  @override
  bool get hasNext => _count > 1 && _index < _count - 1;
  @override
  List<MediaTrackInfo> get audioTracks => const [];
  @override
  List<MediaTrackInfo> get subtitleTracks => const [];
  @override
  String? get selectedAudioTrackId => null;
  @override
  String? get selectedSubtitleTrackId => null;
  @override
  MediaAspectMode get aspectMode => MediaAspectMode.fit;
  @override
  String? get embeddedSubtitleText => null;
}

/// 假音频播放器：**刻意复刻** just_audio 的 `ProcessingState.completed` 语义 ——
/// 置位后 `resume()` 不出声（第一次点击只归零、要再点一次的真机形态），
/// `seek(0)` 才复位。
class _FakeVoicePlayer implements VoicePlayer {
  final _changes = StreamController<void>.broadcast();

  final played = <String>[];
  final seeks = <Duration>[];
  int pauses = 0;
  int stops = 0;
  int resumes = 0;

  Duration _position = Duration.zero;

  @override
  String? currentUrl;

  @override
  bool get hasSource => _hasSource;
  bool _hasSource = false;

  @override
  bool playing = false;

  @override
  double speed = 1;

  @override
  Duration? duration = const Duration(seconds: 60);

  /// just_audio `ProcessingState.completed`（真机 R5-7 的第一次点击就是这个状态）
  bool completed = false;

  @override
  Duration get position => _position;

  @override
  Stream<void> get changes => _changes.stream;

  /// 复刻"异步的 completed 处理"：位置还在末尾、但播放器已不可出声
  void markCompleted() {
    completed = true;
    playing = false;
    _changes.add(null);
  }

  @override
  Future<void> play(String url) async {
    played.add(url);
    currentUrl = url;
    _hasSource = true;
    // 重载来源 = 回到 0（just_audio `setUrl` 的语义）
    _position = Duration.zero;
    playing = true;
    completed = false;
    _changes.add(null);
  }

  @override
  Future<void> resume() async {
    if (!_hasSource) return;
    resumes++;
    if (completed) return; // completed 态：play() 不重新出声
    playing = true;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    pauses++;
    playing = false;
    _changes.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    seeks.add(position);
    if (position == Duration.zero) completed = false;
    _changes.add(null);
  }

  @override
  Future<void> setSpeed(double value) async => speed = value;

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
    _hasSource = false;
    _changes.add(null);
  }
}

/// 最小假桥（第 3 项用真实适配器）：只回 texture id、吞掉 load/play，事件由测试注入。
class _FakeBridge implements PlayerBridge {
  final _events = StreamController<Map<Object?, Object?>>.broadcast();

  final loads = <Map<String, Object?>>[];
  int plays = 0;
  int nexts = 0;

  @override
  Future<int> create() async => 7;

  @override
  Future<void> load({
    required List<String> urls,
    required int index,
    required bool autoplay,
    required double volume,
    required bool muted,
    required double speed,
    required String aspect,
  }) async {
    loads.add({'urls': urls, 'index': index, 'autoplay': autoplay});
  }

  @override
  Future<void> play() async => plays++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekTo(int positionMs) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> playNext() async => nexts++;
  @override
  Future<void> playPrevious() async {}
  @override
  Future<void> selectTrack({required String kind, String? id}) async {}
  @override
  Future<void> setAspectMode(String code) async {}
  @override
  Future<void> dispose() async {}

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  void emit(Map<String, Object?> event) => _events.add(event);
  void close() => _events.close();
}

// ─────────────────────────────────────────────────────────────── 夹具

MediaSource _video(String name, {String? uri}) => MediaSource(
  uri:
      uri ??
      'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download&_sid=S',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: name,
  supportsRange: true,
);

MediaSource _audio(String name) => MediaSource(
  uri: 'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download&_sid=S',
  channel: MediaChannel.fileStation,
  kind: MediaKind.audio,
  displayName: name,
  supportsRange: true,
);

/// 音频舞台需要一个目录条目（封面/大小/时间显示用）。
FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/home/$name',
  isDir: false,
  size: 4096,
  mtime: 1758100000,
);

Future<ProviderContainer> _pumpView(
  WidgetTester tester,
  MediaSource source, {
  required MediaPlayerAdapterFactory factory,
  List<MediaSource>? playlist,
  int playlistIndex = 0,
  VoidCallback? onOpenExternal,
}) async {
  final container = ProviderContainer(
    overrides: [mediaPlayerAdapterFactoryProvider.overrideWithValue(factory)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: MediaPlayerView(
            source: source,
            playlist: playlist,
            playlistIndex: playlistIndex,
            onOpenExternal: onOpenExternal,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return container;
}

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  required MediaSource source,
  required List<MediaSource> playlist,
  required MediaPlayerAdapterFactory factory,
}) async {
  final container = ProviderContainer(
    overrides: [mediaPlayerAdapterFactoryProvider.overrideWithValue(factory)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: MediaPlayerPage(
          source: source,
          playlist: playlist,
          playlistIndex: 0,
          onOpenExternal: () {},
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return container;
}

Future<void> _dragSliderTo(WidgetTester tester, Key key, double value) async {
  final slider = tester.widget<Slider>(find.byKey(key));
  slider.onChangeStart!(value);
  slider.onChanged!(value);
  slider.onChangeEnd!(value);
  await tester.pumpAndSettle();
}

/// ★ r650（`DA250`）：全屏页没有 AppBar 了，「顶栏」= 播放器内的浮层顶栏
/// （`media-top-bar`，与底部控制条一起显隐）。断言意图不变：**顶栏必须写当前播放项**。
Finder _inAppBar(Finder matching) => find.descendant(
  of: find.byKey(const Key('media-top-bar')),
  matching: matching,
);

Finder _inPanel(Finder matching) =>
    find.descendant(of: find.byType(MediaFallbackPanel), matching: matching);

void main() {
  // ───────────────────────────────── 1. 标题跟随"当前播放项" ─────────────
  group('标题跟随当前播放项（R5 面板/顶栏写了打开时的文件名）', () {
    testWidgets('① 用户「下一个」→ 顶栏与回退面板都显示新条目', (tester) async {
      final a = _video('clip-h264.mp4', uri: 'https://nas/clip-h264.mp4');
      final b = _video('theora.mkv', uri: 'https://nas/theora.mkv');
      final adapter = _FakeFullAdapter()
        ..count = 2
        ..index = 0;
      await _pumpPage(
        tester,
        source: a,
        playlist: [a, b],
        factory: () => adapter,
      );
      // ★ r645（DA245）：顶栏一律不带容器扩展名（判据仍是「顶栏 == 当前播放项」）
      expect(_inAppBar(find.text('clip-h264')), findsOneWidget);
      expect(_inAppBar(find.text('theora')), findsNothing);

      // 用户点「下一个」：真机上 index 事件随后由原生回报
      await tester.tap(find.byKey(const Key('media-next')));
      await tester.pump();
      expect(adapter.nexts, 1);
      adapter.index = 1;
      adapter.emit();
      await tester.pump();

      expect(_inAppBar(find.text('theora')), findsOneWidget);
      expect(
        _inAppBar(find.text('clip-h264')),
        findsNothing,
        reason: 'R5：切集后顶栏不能再写打开播放器时的文件名',
      );

      // 下一条无解码器 → 回退面板也必须写当前这条
      adapter.failWith('Decoder init failed');
      await tester.pumpAndSettle();
      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(_inPanel(find.text('theora.mkv')), findsOneWidget);
      expect(_inPanel(find.text('clip-h264.mp4')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('② 自动续播（用户没点选）→ 标题同样跟随', (tester) async {
      final a = _video('a.mp4', uri: 'https://nas/a.mp4');
      final b = _video('b.mp4', uri: 'https://nas/b.mp4');
      final adapter = _FakeFullAdapter()
        ..count = 2
        ..index = 0;
      await _pumpPage(
        tester,
        source: a,
        playlist: [a, b],
        factory: () => adapter,
      );

      // 自动续播：没有点任何按钮，只有 index 变化
      adapter.index = 1;
      adapter.emit();
      await tester.pump();
      // 广播流的投递在微任务里 → 再 pump 一帧让标题重建
      await tester.pump();

      expect(_inAppBar(find.text('b')), findsOneWidget);
      expect(_inAppBar(find.text('a')), findsNothing);
      expect(adapter.nexts, 0, reason: '自动续播不是用户换集');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('③ 播放列表只有一条 → 不回归（标题仍是本条）', (tester) async {
      final a = _video('solo.mp4', uri: 'https://nas/solo.mp4');
      final adapter = _FakeFullAdapter()..count = 1;
      await _pumpPage(tester, source: a, playlist: [a], factory: () => adapter);
      expect(_inAppBar(find.text('solo')), findsOneWidget);

      adapter.failWith('Decoder init failed');
      await tester.pumpAndSettle();
      expect(_inPanel(find.text('solo.mp4')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    // ★ DA30（r384 真机撞到 / r385 修）：**全屏入口**又踩了 R5 同一个坑 ——
    // 面板/顶栏在 R5 之后改成了取 `_currentSource`，但 `_openFullscreen()`
    // 仍然把 `widget.source`（打开播放器时那一条）推给 `MediaPlayerPage`。
    // 真机形态：自动续播到 `60招基础街球S01E01.AVI` 后点「全屏」，
    // 全屏页标题与画面都退回第一集 `01_1._The_Rate_...mp4` 的片头。
    testWidgets('★ DA30：换集后点「全屏」→ 推的是当前那一集 + 同一份列表与下标', (
      tester,
    ) async {
      final a = _video('第一集.mp4', uri: 'https://nas/e1.mp4');
      final b = _video('第二集.mp4', uri: 'https://nas/e2.mp4');
      var created = 0;
      final embedded = _FakeFullAdapter()
        ..count = 2
        ..index = 0;
      final pushed = <_FakeFullAdapter>[];
      MediaPlayerAdapter makeAdapter() {
        created++;
        if (created == 1) return embedded;
        final adapter = _FakeFullAdapter();
        pushed.add(adapter);
        return adapter;
      }

      await _pumpView(
        tester,
        a,
        factory: makeAdapter,
        playlist: [a, b],
        playlistIndex: 0,
      );
      // 自动续播/「下一个」之后，原生回报的下标变成 1
      embedded.index = 1;
      embedded.emit();
      await tester.pump();

      await tester.tap(find.byKey(const Key('media-fullscreen')));
      await tester.pumpAndSettle();

      final page = tester.widget<MediaPlayerPage>(find.byType(MediaPlayerPage));
      expect(
        page.source.displayName,
        '第二集.mp4',
        reason: 'DA30：全屏必须接着**当前播放项**，不许退回打开播放器时那一集',
      );
      expect(page.source.uri, b.uri);
      expect(page.playlist?.map((s) => s.displayName).toList(), [
        '第一集.mp4',
        '第二集.mp4',
      ]);
      expect(page.playlistIndex, 1, reason: '下标要指到当前这一条');
      // ★ r647（DA247）：全屏页**借**同一个适配器 ⇒ 不再新建实例、也不暂停；
      // 「当前是哪一条」由这个共享适配器说了算（`index = 1` 已经在上面设过）。
      expect(pushed, isEmpty, reason: '全屏页不新建适配器');
      expect(page.adapter, same(embedded), reason: '全屏页借的就是预览页那一个');
      expect(embedded.playlistIndex, 1);
      expect(embedded.playlistLength, 2);
      expect(embedded.pauses, 0, reason: '进出全屏是"接着看"，不许暂停');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('★ DA30 反向：没换集时全屏仍推第一条（不许为了修复改坏老路径）', (
      tester,
    ) async {
      final a = _video('第一集.mp4', uri: 'https://nas/e1.mp4');
      final b = _video('第二集.mp4', uri: 'https://nas/e2.mp4');
      var created = 0;
      MediaPlayerAdapter makeAdapter() {
        created++;
        return _FakeFullAdapter()
          ..count = 2
          ..index = 0;
      }

      await _pumpView(
        tester,
        a,
        factory: makeAdapter,
        playlist: [a, b],
        playlistIndex: 0,
      );
      await tester.tap(find.byKey(const Key('media-fullscreen')));
      await tester.pumpAndSettle();
      final page = tester.widget<MediaPlayerPage>(find.byType(MediaPlayerPage));
      expect(page.source.uri, a.uri);
      expect(page.playlistIndex, 0);
      expect(created, 1, reason: '内嵌 + 全屏共用同一个适配器实例（r647 DA247）');

      await tester.pumpWidget(const SizedBox());
    });
  });

  // ───────────────────────────────── 2. 末尾重播一次点击 ─────────────────
  group('末尾重播：一次点击即从 00:00 起播', () {
    testWidgets('视频：片尾一个位置 tick 的偏差也要 seekTo(0)', (tester) async {
      final adapter = _FakeFullAdapter()
        ..duration = const Duration(seconds: 100);
      await _pumpView(tester, _video('clip.mp4'), factory: () => adapter);
      // 先暂停（autoPlay 已经请求过播放）
      await tester.tap(find.byKey(const Key('media-play-pause')));
      await tester.pump();
      expect(adapter.playing, isFalse);
      // 原生位置事件 250ms 一 tick：末帧最后一个 tick 落在 duration 之前
      adapter.position =
          const Duration(seconds: 99) + const Duration(milliseconds: 800);
      adapter.emit();
      await tester.pump();

      await tester.tap(find.byKey(const Key('media-play-pause')));
      await tester.pump();
      await tester.pump();

      expect(
        adapter.seeks.last,
        Duration.zero,
        reason: '在片尾点一次播放就必须 seekTo(0)，不能等第二次点击',
      );
      expect(adapter.position, Duration.zero);
      expect(find.text('00:00'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('音频：拖到末尾 + completed 态 → 一次点击就出声（R5-7）', (tester) async {
      final player = _FakeVoicePlayer();
      final container = ProviderContainer(
        overrides: [voicePlayerProvider.overrideWithValue(player)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: MediaAudioStage(
                entry: _entry('audiotone.wav'),
                source: _audio('audiotone.wav'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 起播（载入来源）
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.played, hasLength(1));
      expect(player.playing, isTrue);

      // 拖到末尾（60s）：_onDragEnd 记下"下一次点播放 = 从头重播"
      await _dragSliderTo(tester, const Key('audio-progress'), 60 * 1000);
      expect(player.seeks.last, const Duration(seconds: 60));

      // 真机竞争窗口：completed 已置位，但异步的 stop()+seek(0) 还没跑
      player.markCompleted();
      await tester.pump();

      // **第一次**（也是唯一一次）点击播放
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      await tester.pump();

      expect(player.playing, isTrue, reason: 'R5-7：第一次点击就要真正起播，不能"只归零不出声"');
      expect(player.position, Duration.zero, reason: '末尾重播从 00:00 起');
      expect(player.played, hasLength(1), reason: '末尾重播不许重载来源（不许新建 ExoPlayer）');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('暂停态中点播放 → 不触发重播（既有行为不回归）', (tester) async {
      final player = _FakeVoicePlayer();
      final container = ProviderContainer(
        overrides: [voicePlayerProvider.overrideWithValue(player)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: MediaAudioStage(
                entry: _entry('song.mp3'),
                source: _audio('song.mp3'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      // 拖到 50%（还没到末尾）
      await _dragSliderTo(tester, const Key('audio-progress'), 30 * 1000);
      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(player.pauses, greaterThanOrEqualTo(1));

      await tester.tap(find.byKey(const Key('audio-play-pause')));
      await tester.pump();
      expect(
        player.seeks.where((s) => s == Duration.zero),
        isEmpty,
        reason: '半途暂停后续播不许 seek(0)（只有片尾重播才有）',
      );
      expect(player.position, const Duration(seconds: 30));

      await tester.pumpWidget(const SizedBox());
    });
  });

  // ───────────────────────────────── 3. 自动续播零画面证据 → 非阻塞提示 ──
  group('自动续播到无画面条目：非阻塞提示（不许静默黑屏，也不许误伤）', () {
    Future<(_FakeBridge, NativeVideoPlayerAdapter)> pumpReal(
      WidgetTester tester,
    ) async {
      final bridge = _FakeBridge();
      addTearDown(bridge.close);
      final adapter = NativeVideoPlayerAdapter(
        bridge: bridge,
        watchdogTimeout: const Duration(seconds: 2),
        // R7-5 冷缓存修正：非阻塞提示判死前多一轮**确认窗口**。测试注入 1s，
        // 于是"窗口 2s + 确认 1s" = 3s 后才会提示（真无解码器仍会提示）。
        continuationConfirmGrace: const Duration(seconds: 1),
      );
      addTearDown(adapter.dispose);
      final a = _video('clip-h264.mp4', uri: 'https://nas/clip-h264.mp4');
      final b = _video('theora.mkv', uri: 'https://nas/theora.mkv');
      await _pumpView(
        tester,
        a,
        playlist: [a, b],
        factory: () => adapter,
        onOpenExternal: () {},
      );
      // 上一条真的出过画面（尺寸 + 首帧）
      bridge.emit({
        'kind': 'state',
        'positionMs': 100,
        'videoWidth': 160,
        'videoHeight': 120,
        'firstFrame': true,
      });
      await tester.pump();
      return (bridge, adapter);
    }

    testWidgets('① 自动续播 + 零画面证据 → 顶栏提示出现，且不是致命面板', (tester) async {
      final (bridge, adapter) = await pumpReal(tester);
      expect(adapter.error, isNull);

      // 片尾自动续播：原生清尺寸/首帧 + index 变化（不是用户点选）
      bridge.emit({
        'kind': 'state',
        'positionMs': 0,
        'durationMs': 5000,
        'firstFrame': false,
        'videoWidth': 0,
        'videoHeight': 0,
        'index': 1,
        'count': 2,
      });
      await tester.pump();

      await tester.pump(const Duration(seconds: 4));
      await tester.pump();

      expect(
        find.byKey(const Key('media-continuation-notice')),
        findsOneWidget,
        reason: 'R5：自动续播到无解码器条目绝不能静默黑屏（R7-11 不回归）',
      );
      expect(
        find.byType(MediaFallbackPanel),
        findsNothing,
        reason: '这是非阻塞提示，不许退化成致命面板',
      );
      expect(adapter.error, isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('② 自动续播到可解码条目 → 不得出现提示（防误伤）', (tester) async {
      final (bridge, adapter) = await pumpReal(tester);
      bridge.emit({
        'kind': 'state',
        'positionMs': 0,
        'durationMs': 5000,
        'firstFrame': false,
        'videoWidth': 0,
        'videoHeight': 0,
        'index': 1,
        'count': 2,
      });
      await tester.pump();
      // 下一条真的出画面
      bridge.emit({'kind': 'state', 'firstFrame': true, 'videoWidth': 160});
      await tester.pump();

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(find.byKey(const Key('media-continuation-notice')), findsNothing);
      expect(find.byType(MediaFallbackPanel), findsNothing);
      expect(adapter.error, isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('③ 用户手动「下一个」到无解码器 → 仍是既有的致命面板', (tester) async {
      final (bridge, adapter) = await pumpReal(tester);
      await tester.tap(find.byKey(const Key('media-next')));
      await tester.pump();
      bridge.emit({
        'kind': 'state',
        'positionMs': 0,
        'durationMs': 5000,
        'index': 1,
        'count': 2,
      });
      await tester.pump();

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(find.textContaining('系统解码器不支持这个文件的编码'), findsOneWidget);
      expect(find.byKey(const Key('media-continuation-notice')), findsNothing);
      // 面板写的是**当前**这一条（theora），不是打开时的 clip
      expect(_inPanel(find.text('theora.mkv')), findsOneWidget);
      expect(_inPanel(find.text('clip-h264.mp4')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('⑤ R7-5 冷缓存误报：确认窗口内出画 → 不弹提示（真无解码器仍弹，见①）', (tester) async {
      final (bridge, adapter) = await pumpReal(tester);
      // 自动续播到**可解码**的下一条，但首帧比 5s/2s 窗口晚到（冷缓存）
      bridge.emit({
        'kind': 'state',
        'positionMs': 0,
        'durationMs': 5000,
        'firstFrame': false,
        'videoWidth': 0,
        'videoHeight': 0,
        'index': 1,
        'count': 2,
      });
      await tester.pump();
      // 第一个窗口（2s）到点：进入**确认窗口**，此刻**不许**弹提示
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        find.byKey(const Key('media-continuation-notice')),
        findsNothing,
        reason: '判死前再确认一轮：窗口到点不等于"没有解码器"',
      );
      // 确认窗口内首帧到了（冷缓存跑次的实际形态）→ 撤销
      bridge.emit({'kind': 'state', 'firstFrame': true, 'videoWidth': 160});
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();

      expect(
        find.byKey(const Key('media-continuation-notice')),
        findsNothing,
        reason: '已出画绝不能误报"自动续播无画面"',
      );
      expect(find.byType(MediaFallbackPanel), findsNothing);
      expect(adapter.error, isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('④ 长片位置在推进、还没到结尾 → 提示与面板都不出现（既有取舍保持）', (tester) async {
      final (bridge, adapter) = await pumpReal(tester);
      bridge.emit({
        'kind': 'state',
        'positionMs': 0,
        'durationMs': 60000,
        'index': 1,
        'count': 2,
      });
      await tester.pump();
      // 60s 长片：窗口到点时位置才 2s，远没到结尾
      bridge.emit({
        'kind': 'state',
        'positionMs': 2000,
        'durationMs': 60000,
        'playing': true,
        'buffering': false,
      });
      await tester.pump();

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(adapter.error, isNull);
      expect(find.byType(MediaFallbackPanel), findsNothing);
      expect(
        find.byKey(const Key('media-continuation-notice')),
        findsNothing,
        reason: '宁可漏报也不误伤可解码文件：推进中的长片不给提示',
      );

      await tester.pumpWidget(const SizedBox());
    });
  });
}
