// 播放器**改版**的界面层测试（第 260 轮）：手势层 + 覆盖式控制条 + 在线字幕面板。
//
// 这一批只测"新加的东西"，既有 12 个 key 的既有用例不动（见
// `media_player_controls_ui_test.dart` / `media_player_page_test.dart`）：
//   ① 覆盖式控件：中间单击显隐、10s 自动隐藏；
//   ② 双击左/右 → ∓10s + 中央提示（`media-gesture-hud`）；
//   ③ 竖直滑动：右半调音量（真的调到适配器）、左半调亮度（遮罩 `media-dim-overlay`）；
//   ④ 在线字幕面板四种状态：可搜（有密钥提示）→ 结果 → 下载并落盘；
//      失败（403 → 可读原因 + 重试）；空结果（与失败分开）；
//   ⑤ 重启后按缓存把在线字幕挂回来（`online:<缓存文件名>`）。
//
// 假 HTTP + **内存缓存后端**注入 `subtitleSearchBundleProvider` ⇒ 不碰网络、
// 不碰平台通道，也**不碰磁盘**（见 `MemorySubtitleCacheBackend` 的注释：
// `testWidgets` 的假时钟推不动真磁盘 IO）。真磁盘那条路由
// `media_subtitle_search_test.dart` 覆盖。
//
// ★ 两个测试纪律（都是踩过的坑，别再犯）：
//   1. **有 `CircularProgressIndicator` 在屏上时绝不能 `pumpAndSettle()`**
//      —— 它永远转不完，`pumpAndSettle` 会一直等到 10 分钟超时（实测挂死过）；
//   2. 缓存后端用**内存实现**：真磁盘 IO 在 `testWidgets` 的假时钟里跑不完
//      （`runAsync` 里发起还会重入挂死），真磁盘那条路交给纯 Dart 的
//      `media_subtitle_search_test.dart`。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/media/media_playback_store.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_subtitle_search.dart';
import 'package:synhub/src/features/media/media_tracks.dart';

/// 完整控制的假适配器（只实现界面用到的那部分）
class _FakeFullAdapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  final _changes = StreamController<void>.broadcast();

  final seeks = <Duration>[];
  final skips = <Duration>[];
  final volumes = <double>[];
  final speeds = <double>[];

  /// 可写的位置（字幕覆盖层按它挑 cue）
  Duration positionValue = Duration.zero;
  bool playingValue = false;
  double volumeValue = 0.5;
  double speedValue = 1;
  MediaAspectMode aspectValue = MediaAspectMode.fit;

  @override
  List<MediaTrackInfo> audioTracks = const [];

  @override
  List<MediaTrackInfo> subtitleTracks = const [];

  @override
  String? embeddedSubtitleText;

  /// 让视图收到"播放器有变化"（内部 `setState`）
  void emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> load(MediaSource source) async {}

  @override
  Future<void> play() async {
    playingValue = true;
    emit();
  }

  @override
  Future<void> pause() async {
    playingValue = false;
    emit();
  }

  @override
  Future<void> seekTo(Duration position) async {
    positionValue = position;
    seeks.add(position);
    emit();
  }

  @override
  Future<void> skipBy(Duration offset) async => skips.add(offset);

  @override
  Future<void> setSpeed(double speed) async {
    speedValue = speed;
    speeds.add(speed);
  }

  @override
  Future<void> setVolume(double value) async {
    volumeValue = value;
    volumes.add(value);
  }

  @override
  Future<void> setMuted(bool value) async {}

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {}

  @override
  Future<void> playNext() async {}

  @override
  Future<void> playPrevious() async {}

  @override
  Future<void> selectAudioTrack(String? id) async {}

  @override
  Future<void> selectSubtitleTrack(String? id) async {
    if (id == null) embeddedSubtitleText = null;
  }

  @override
  Future<void> setAspectMode(MediaAspectMode mode) async {
    aspectValue = mode;
  }

  @override
  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Duration get position => positionValue;

  @override
  Duration? get duration => const Duration(seconds: 100);

  @override
  bool get playing => playingValue;

  @override
  bool get ready => true;

  @override
  double get speed => speedValue;

  @override
  String? get error => null;

  @override
  double get aspectRatio => 16 / 9;

  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(key: Key('fake-surface'), color: Colors.black);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  double get volume => volumeValue;

  @override
  bool get muted => false;

  @override
  int get playlistIndex => 0;

  @override
  int get playlistLength => 1;

  @override
  bool get hasPrevious => false;

  @override
  bool get hasNext => false;

  @override
  String? get selectedAudioTrackId => null;

  @override
  String? get selectedSubtitleTrackId => null;

  @override
  MediaAspectMode get aspectMode => aspectValue;
}

/// 假 HTTP（按 handler 回包；记录请求便于断言 URL/头部）
class _FakeHttp implements SubtitleHttp {
  _FakeHttp(this.handler);

  final Future<SubtitleHttpResponse> Function(
    Uri uri,
    Map<String, String> headers,
  )
  handler;

  final List<Uri> calls = [];

  @override
  Future<SubtitleHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
  }) {
    calls.add(uri);
    return handler(uri, headers);
  }
}

SubtitleHttpResponse _json(int code, String body) => SubtitleHttpResponse(
  statusCode: code,
  body: Uint8List.fromList(utf8.encode(body)),
  contentType: 'application/json',
);

SubtitleHttpResponse _srtResponse(String body) => SubtitleHttpResponse(
  statusCode: 200,
  body: Uint8List.fromList(utf8.encode(body)),
  contentType: 'text/srt',
);

const String _srt = '1\n'
    '00:00:01,000 --> 00:00:09,000\n'
    '在线字幕第一句\n';

/// OpenSubtitles 搜索应答（一条 en，带 legacy id ⇒ 下载走 dl.opensubtitles.org）
String _osSearchBody() => jsonEncode({
  'total_pages': 1,
  'total_count': 1,
  'page': 1,
  'data': [
    {
      'id': '1',
      'attributes': {
        'subtitle_id': '1',
        'language': 'en',
        'download_count': 42,
        'ratings': 8.0,
        'legacy_subtitle_id': 7803094,
        'release': 'Inception.2010.1080p',
        'files': [
          {'file_id': 1, 'cd_number': 1},
        ],
      },
    },
  ],
});

MediaSource _playable({String name = 'Inception.2010.mp4'}) => MediaSource(
  uri: 'https://fake.test/webapi/entry.cgi?api=SYNO.FileStation.Download',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: name,
  supportsRange: true,
);

FileEntryDto _entry(String name, {int size = 4096}) => FileEntryDto(
  name: name,
  path: '/home/$name',
  isDir: false,
  size: size,
  mtime: 1758100000,
);

SubtitleSearchBundle _bundle(
  Future<SubtitleHttpResponse> Function(Uri uri, Map<String, String> headers)
  handler, {
  SubtitleCacheStore? cache,
}) => SubtitleSearchBundle(
  service: SubtitleSearchService.defaults(http: _FakeHttp(handler)),
  cache: cache ?? SubtitleCacheStore(backend: MemorySubtitleCacheBackend()),
);

/// 起一个播放视图（可注入在线字幕依赖 / 播放记忆 / 目录条目）
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required _FakeFullAdapter adapter,
  MediaSource? source,
  FileEntryDto? entry,
  SubtitleSearchBundle? bundle,
  MediaPlaybackStore? store,
  CloudKeyStore? keyStore,
}) async {
  final container = ProviderContainer(
    overrides: [
      // 安全存储要走平台通道 ⇒ 测试里一律用内存实现（与本仓既有用例同一口径）
      cloudKeyStoreProvider.overrideWithValue(keyStore ?? MemoryCloudKeyStore()),
      mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
      if (bundle != null) subtitleSearchBundleProvider.overrideWithValue(bundle),
      if (store != null) mediaPlaybackStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: MediaPlayerView(source: source ?? _playable(), entry: entry),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return container;
}

/// 点一下画面中间（等过双击判定窗口，单击才会真的触发）
Future<void> _tapCenter(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 300));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 打开底部弹层（面板动画 250ms；这里不用 `pumpAndSettle`，见文件头纪律 2）
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('media-online-subtitle')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 反复 pump 直到 [finder] 命中（或帧数耗尽）—— 多跳异步链的稳定写法：
/// 固定推几帧会"今天过、明天不过"，这里以**状态出现**为准。
Future<bool> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int rounds = 40,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.pump(const Duration(milliseconds: 20));
  }
  return finder.evaluate().isNotEmpty;
}

/// 点"开始搜索"并等真正跑完（跑完前后都有 IO）
Future<void> _runSearch(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('media-subtitle-search-run')));
  await tester.pump();
  // 搜索本身是纯 Future（假 http），**没有磁盘 IO** ⇒ 普通 pump 就能推完
  await tester.pump(const Duration(milliseconds: 400));
}

/// r630：字幕/音轨/比例/倍速已每进「播放设置」面板 ⇒ 先开面板
Future<void> _openSettingsSheet(WidgetTester tester) async {
  if (find.byKey(const Key('media-settings-sheet')).evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const Key('media-settings')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('覆盖式控件：单击显隐 + 自动隐藏', () {
    testWidgets('中间单击隐藏、再单击显示；手势层存在', (tester) async {
      final adapter = _FakeFullAdapter();
      await _pump(tester, adapter: adapter);

      expect(find.byKey(const Key('media-gesture-layer')), findsOneWidget);
      expect(find.byKey(const Key('media-progress')), findsOneWidget);

      await _tapCenter(tester);
      expect(
        find.byKey(const Key('media-progress')),
        findsNothing,
        reason: '单击画面中间要把控件收起来',
      );

      await _tapCenter(tester);
      expect(find.byKey(const Key('media-progress')), findsOneWidget);
    });

    testWidgets('10s 不动自动隐藏（kMediaControlsAutoHide）', (tester) async {
      await _pump(tester, adapter: _FakeFullAdapter());
      expect(find.byKey(const Key('media-progress')), findsOneWidget);
      await tester.pump(const Duration(seconds: 10, milliseconds: 100));
      expect(find.byKey(const Key('media-progress')), findsNothing);
    });

    testWidgets('顶栏"隐藏控件"按钮也能收起', (tester) async {
      await _pump(tester, adapter: _FakeFullAdapter());
      expect(find.byKey(const Key('media-top-bar')), findsOneWidget);
      await tester.tap(find.byKey(const Key('media-hide-controls')));
      await tester.pump();
      expect(find.byKey(const Key('media-progress')), findsNothing);
    });
  });

  group('双击 ±10s + 中央提示', () {
    testWidgets('左半双击 → 快退 10s（真的调到适配器），并出现提示', (tester) async {
      final adapter = _FakeFullAdapter();
      await _pump(tester, adapter: adapter);

      await tester.tapAt(const Offset(100, 300));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(const Offset(100, 300));
      await tester.pump(const Duration(milliseconds: 40));

      expect(adapter.skips, [const Duration(seconds: -10)]);
      expect(find.byKey(const Key('media-gesture-hud')), findsOneWidget);
      expect(find.text('快退 10 秒'), findsOneWidget);
    });

    testWidgets('右半双击 → 快进 10s', (tester) async {
      final adapter = _FakeFullAdapter();
      await _pump(tester, adapter: adapter);

      await tester.tapAt(const Offset(700, 300));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(const Offset(700, 300));
      await tester.pump(const Duration(milliseconds: 40));

      expect(adapter.skips, [const Duration(seconds: 10)]);
      expect(find.text('快进 10 秒'), findsOneWidget);
    });

    testWidgets('提示 900ms 后自己消失（不是常驻动画）', (tester) async {
      await _pump(tester, adapter: _FakeFullAdapter());
      await tester.tapAt(const Offset(700, 300));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(const Offset(700, 300));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byKey(const Key('media-gesture-hud')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.byKey(const Key('media-gesture-hud')), findsNothing);
    });
  });

  group('竖直滑动：右半音量 / 左半亮度', () {
    testWidgets('右半上滑 → 音量变大，提示"音量"', (tester) async {
      final adapter = _FakeFullAdapter();
      await _pump(tester, adapter: adapter);
      final before = adapter.volume;
      // 先把控件收起来：底部控制条（进度/音量 Slider）会吃掉落在它上面的手势，
      // 真机同理 —— 控制条区域归控件，画面空白区才归手势层。
      await _tapCenter(tester);
      expect(find.byKey(const Key('media-progress')), findsNothing);

      await tester.dragFrom(const Offset(700, 400), const Offset(0, -150));
      // ★ 必须推过 40ms：`DoubleTapGestureRecognizer` 在 pointer-down 时挂了
      // 一个 40ms 的倒计时，测试收尾会因为"还有 Timer 在跑"报
      // `A Timer is still pending even after the widget tree was disposed`。
      await tester.pump(const Duration(milliseconds: 60));

      expect(adapter.volumes, isNotEmpty, reason: '必须真的把音量给了适配器');
      expect(adapter.volumes.last, greaterThan(before));
      expect(find.textContaining('音量'), findsOneWidget);
    });

    testWidgets('左半上滑 → 亮度遮罩出现（播放器内调光），提示"亮度"', (tester) async {
      await _pump(tester, adapter: _FakeFullAdapter());
      expect(find.byKey(const Key('media-dim-overlay')), findsNothing);
      await _tapCenter(tester);

      // ★ 向下拖才是"变暗"：向上 = 更亮（`_dimOpacity = (1 - next) * kMediaMaxDim`，
      // 初始 `next = 1` ⇒ 向上只会把遮罩压到 0，正是本轮第一版写反的地方）
      await tester.dragFrom(const Offset(100, 200), const Offset(0, 250));
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.byKey(const Key('media-dim-overlay')), findsOneWidget);
      expect(find.textContaining('亮度'), findsOneWidget);
    });
  });

  group('在线字幕面板', () {
    testWidgets('入口：没配密钥 → 明确写"未配置密钥"；搜索框 / 语言档都在', (tester) async {
      await _pump(
        tester,
        adapter: _FakeFullAdapter(),
        bundle: _bundle((_, _) async => _json(200, _osSearchBody())),
      );

      await _openSheet(tester);
      expect(find.byKey(const Key('media-subtitle-search-sheet')), findsOneWidget);
      expect(find.byKey(const Key('media-subtitle-search-field')), findsOneWidget);
      expect(find.byKey(const Key('media-subtitle-key-field')), findsOneWidget);
      expect(find.byKey(const Key('media-subtitle-key-missing')), findsOneWidget);
      for (final mode in ['chinese', 'english', 'any']) {
        expect(
          find.byKey(Key('media-subtitle-lang-$mode')),
          findsOneWidget,
          reason: '缺语言档 $mode',
        );
      }
    });

    testWidgets('搜到结果 → 点一条 → 下载、落盘、挂上外挂字幕', (tester) async {
      final bundle = _bundle(
        (uri, _) async => uri.host == 'dl.opensubtitles.org'
            ? _srtResponse(_srt)
            : _json(200, _osSearchBody()),
      );
      final adapter = _FakeFullAdapter();
      final entry = _entry('Inception.2010.mp4');
      final store = InMemoryMediaPlaybackStore();
      await _pump(
        tester,
        adapter: adapter,
        bundle: bundle,
        entry: entry,
        store: store,
      );

      await _openSheet(tester);
      await _runSearch(tester);

      expect(find.byKey(const Key('media-subtitle-result-0')), findsOneWidget);
      expect(find.byKey(const Key('media-subtitle-search-loading')), findsNothing);

      await tester.tap(find.byKey(const Key('media-subtitle-result-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 面板自己关了；缓存里必须真的落了文件
      expect(find.byKey(const Key('media-subtitle-search-sheet')), findsNothing);
      final files = await bundle.cache.list();
      expect(files, hasLength(1));
      expect(files.single.fileName, endsWith('.srt'));
      // "记住这个文件上次用的字幕"：必须写进播放记忆（值就是 `online:<缓存文件名>`）
      final memKey = mediaSubtitleMemoryKey(
        path: entry.path,
        size: entry.size,
      )!;
      expect(
        await store.loadSubtitle(memKey),
        'online:${files.single.fileName}',
        reason: '在线字幕必须被记住，重启后才能回读',
      );

      // 真的挂上了：把位置推到 cue 窗口内，字幕文本必须出来
      adapter.positionValue = const Duration(seconds: 3);
      adapter.emit();
      await tester.pump();
      expect(find.byKey(const Key('media-subtitle-text')), findsOneWidget);
      expect(find.text('在线字幕第一句'), findsOneWidget);

      // 字幕菜单里也要能看到"在线字幕"这一项
      await _openSettingsSheet(tester);
  await tester.tap(find.byKey(const Key('media-subtitle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('在线字幕'), findsWidgets);
    });

    testWidgets('被拒（403）→ 可读原因 + 重试入口，不是静默失败', (tester) async {
      await _pump(
        tester,
        adapter: _FakeFullAdapter(),
        bundle: _bundle(
          (_, _) async =>
              _json(403, '{"message":"You cannot consume this service"}'),
        ),
      );

      await _openSheet(tester);
      await _runSearch(tester);

      // 逐源失败 → "全都失败" + **可读原因**（每个源一行）+ 重试
      expect(find.byKey(const Key('media-subtitle-search-empty')), findsOneWidget);
      expect(find.textContaining('所有在线字幕源都失败了'), findsOneWidget);
      expect(
        find.byKey(const Key('media-subtitle-search-retry')),
        findsOneWidget,
        reason: '失败必须给重试',
      );
      expect(find.textContaining('API Key'), findsWidgets);
      // 逐源失败原因也列出来（OpenSubtitles + Gestdown）
      expect(find.textContaining('OpenSubtitles'), findsWidgets);
      expect(find.textContaining('Gestdown'), findsWidgets);
    });

    testWidgets('源都成功但没结果 → "没找到"，与"失败"分开', (tester) async {
      await _pump(
        tester,
        adapter: _FakeFullAdapter(),
        bundle: _bundle((_, _) async => _json(200, '{"data":[],"total_count":0}')),
      );

      await _openSheet(tester);
      await _runSearch(tester);

      expect(find.byKey(const Key('media-subtitle-search-empty')), findsOneWidget);
      expect(find.byKey(const Key('media-subtitle-search-error')), findsNothing);
      expect(find.textContaining('没有找到'), findsOneWidget);
    });
  });

  group('在线字幕的记忆与恢复', () {
    testWidgets('重启后按缓存文件名把在线字幕挂回来', (tester) async {
      final bundle = _bundle((_, _) async => _json(200, '{"data":[]}'));
      const cacheName = 'subtitle_restore.opensubtitles.1.srt';
      await bundle.cache.write(fileName: cacheName, bytes: utf8.encode(_srt));

      final entry = _entry('restore.mp4');
      final key = mediaSubtitleMemoryKey(path: entry.path, size: entry.size);
      expect(key, isNotNull);
      final store = InMemoryMediaPlaybackStore(
        subtitles: {key!: 'online:$cacheName'},
      );

      final adapter = _FakeFullAdapter();
      await _pump(
        tester,
        adapter: adapter,
        entry: entry,
        bundle: bundle,
        store: store,
      );
      // `_bootstrap` 收尾才恢复字幕：`loadSubtitle → cache.load → _selectSubtitle`
      // 是一条多跳异步链 ⇒ pump 到**字幕菜单里出现它**为准
      adapter.positionValue = const Duration(seconds: 3);
      // 覆盖层是在 build 里按 `adapter.position` 取 cue 的 ⇒ 必须让视图**重建**一次
      adapter.emit();
      await _pumpUntil(tester, find.byKey(const Key('media-subtitle')));
      expect(await _pumpUntil(tester, find.text('在线字幕第一句')), isTrue,
          reason: '记住的在线字幕必须被读回来并渲染');
      // ★ `media-subtitle-text` 这个 key 在**覆盖层本身**上（`_SubtitleOverlay`），
      //   没字幕时它也照样在树上 ⇒ 只能断言**文本内容**，断言 key 等于没断言。
      await _openSettingsSheet(tester);
  await tester.tap(find.byKey(const Key('media-subtitle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('在线字幕'),
        findsWidgets,
        reason: '字幕菜单里必须有回读回来的在线字幕',
      );
      expect(
        find.text('在线字幕第一句'),
        findsOneWidget,
        reason: '记住的在线字幕必须被读回来并渲染',
      );
    });

    testWidgets('缓存文件不在 → 老老实实不挂，不崩不假装', (tester) async {
      final bundle = _bundle((_, _) async => _json(200, '{"data":[]}'));
      final entry = _entry('gone.mp4');
      final key = mediaSubtitleMemoryKey(path: entry.path, size: entry.size)!;
      final store = InMemoryMediaPlaybackStore(
        subtitles: {key: 'online:subtitle_gone.opensubtitles.9.srt'},
      );

      final adapter = _FakeFullAdapter();
      await _pump(
        tester,
        adapter: adapter,
        entry: entry,
        bundle: bundle,
        store: store,
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(MediaPlayerView), findsOneWidget);
      adapter.positionValue = const Duration(seconds: 3);
      adapter.emit();
      await _pumpUntil(tester, find.text('在线字幕第一句'), rounds: 25);
      expect(
        find.text('在线字幕第一句'),
        findsNothing,
        reason: '缓存没了就不能假装有字幕',
      );
    });
  });

  group('全屏页的顶栏', () {
    testWidgets('AppBar 有文件名 + 在线字幕入口，点它会打开面板', (tester) async {
      final container = ProviderContainer(
        overrides: [
          cloudKeyStoreProvider.overrideWithValue(MemoryCloudKeyStore()),
          mediaPlayerAdapterFactoryProvider.overrideWithValue(
            _FakeFullAdapter.new,
          ),
          subtitleSearchBundleProvider.overrideWithValue(
            _bundle((_, _) async => _json(200, _osSearchBody())),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: MediaPlayerPage(source: _playable(name: 'clip-h264.mp4')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      // ★ r650（DA250）：全屏页**不再有常驻 AppBar**（它会永久吃掉约 80dp 画面）。
      //   返回/标题/更多改成播放器内的浮层顶栏，与控制条一起显隐。
      expect(
        find.byType(AppBar),
        findsNothing,
        reason: 'DA250：全屏页不许有常驻 AppBar（画面被永久压掉一截）',
      );
      final topBar = find.byKey(const Key('media-top-bar'));
      expect(topBar, findsOneWidget);
      // ★ r645（DA245）：浮层顶栏也不写容器扩展名
      expect(
        find.descendant(of: topBar, matching: find.text('clip-h264')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: topBar, matching: find.text('clip-h264.mp4')),
        findsNothing,
        reason: 'DA245：扩展名属于「播放设置 / 文件信息」，不许顶在标题上',
      );
      // 返回入口必须在浮层里（AppBar 没了，返回不能跟着没）
      expect(find.byKey(const Key('media-top-back')), findsOneWidget);

      // ★ r650（DA250）：画面**从窗口顶边开始**（没有 AppBar 压着），
      //   也就是「全屏就是全屏」—— chrome 只能是浮层。
      final surface = tester.getRect(find.byKey(const Key('media-video-surface')));
      expect(
        surface.top,
        lessThanOrEqualTo(0.5),
        reason: 'DA250：全屏页不许有常驻顶栏把画面往下推',
      );
      expect(
        surface.height,
        tester.view.physicalSize.height / tester.view.devicePixelRatio,
        reason: 'DA250：画面要吃满整个窗口高度',
      );
      // 浮层里的返回键真的能退页
      expect(find.byKey(const Key('media-top-back')), findsOneWidget);

      // 在线字幕入口在控制条上（`media-online-subtitle`），点它仍能开面板
      await tester.tap(find.byKey(const Key('media-online-subtitle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('media-subtitle-search-sheet')),
        findsOneWidget,
      );
    });
  });
}
