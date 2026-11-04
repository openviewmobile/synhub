// 字幕样式（位置 + 背景条）的**持久化**与**兜底引擎生效**（r656 · `DA270`/`DA271`）。
//
// 现场（两个，都在 r655 交付后一眼看出来）：
//   * `DA270`：位置/背景条存在页面 State 里 ⇒ 退出去回个消息再进来，
//     调好的 +80 又贴回控制条，每次重看都要再点两下；
//   * `DA271`：`DA269` 当时把这三行在 libmpv 路径上一刀切藏了。可 libmpv
//     **完全听得懂** `sub-margin-y` / `sub-border-style` —— 藏起来不是"诚实"，
//     是少给了一半能力。
//
// 判据（都能红）：
//   ① 存了再读回来一模一样（新建 store 实例也读得到 ⇒ 真落盘，不是进程内记忆）；
//   ② 非法值吸附到最近档位（37→40、-5→0、999→120、NaN→0），坏 JSON 回默认；
//   ③ `mpvSubtitleProperties` 的换算：位置走**像素级** `sub-margin-y`，
//      背景条 = `opaque-box` + 半透明黑（不是整屏黑底）；
//   ④ 换引擎（主 → 兜底）时样式**跟着过去**（否则一换引擎字幕就跳回底部）；
//   ⑤ 反向：主引擎（自家浮层画字幕）没实现 styling —— 不发、不假装设上了；
//   ⑥ 进页面用上次的档位；改一次存一次。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/fallback_player_adapter.dart';
import 'package:synhub/src/features/media/media_playback_store.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';
import 'package:synhub/src/features/media/mpv_player_adapter.dart';

/// 能听懂"位置/背景条"的假引擎（`DA271` 的正支）。
class _StylingAdapter extends _Adapter implements MediaPlayerSubtitleStyling {
  final styles = <({int offsetPx, bool background})>[];

  @override
  Future<void> setSubtitleStyle({
    required int offsetPx,
    required bool background,
  }) async {
    styles.add((offsetPx: offsetPx, background: background));
  }
}

/// 只声明"字幕是我画的"、却**不**实现 styling 的引擎（`DA269` 的反向守卫）。
class _SelfRenderingAdapter extends _Adapter
    implements MediaPlayerSelfRenderedSubtitles {
  @override
  bool get rendersOwnSubtitles => true;
}

class _Adapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  final _changes = StreamController<void>.broadcast();

  @override
  List<MediaTrackInfo> audioTracks = const [];
  @override
  List<MediaTrackInfo> subtitleTracks = const [];
  @override
  String? embeddedSubtitleText;
  String? subtitleTrackId;

  void emitChange() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> load(MediaSource source) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Future<void> skipBy(Duration offset) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double value) async {}

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
  Future<void> selectSubtitleTrack(String? id) async => subtitleTrackId = id;

  @override
  Future<void> setAspectMode(MediaAspectMode mode) async {}

  @override
  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => const Duration(seconds: 100);
  @override
  bool get playing => false;
  @override
  bool get ready => true;
  @override
  double get speed => 1;
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
  double get volume => 0.5;
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
  String? get selectedSubtitleTrackId => subtitleTrackId;
  @override
  MediaAspectMode get aspectMode => MediaAspectMode.fit;
}

MediaSource _source() => MediaSource(
  uri: 'https://fake.test/webapi/entry.cgi?api=SYNO.FileStation.Download',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: 'Inception.2010.mkv',
  supportsRange: true,
);

Future<void> _pump(
  WidgetTester tester,
  _Adapter adapter, {
  required MediaPlaybackStore store,
}) async {
  final container = ProviderContainer(
    overrides: [
      cloudKeyStoreProvider.overrideWithValue(MemoryCloudKeyStore()),
      mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
      mediaPlaybackStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: MediaPlayerView(source: _source())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('DA270：字幕位置/背景条要被记住（跨播放会话）', () {
    test('① 存了再读回来一模一样（新实例也读得到 ⇒ 真落盘）', () async {
      final dir = await Directory.systemTemp.createTemp('r656_store');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/media_playback.json');

      final a = AppMediaPlaybackStore(fileResolver: () async => file);
      await a.saveSubtitleStyle(
        const MediaSubtitleStyle(offset: 80, background: true),
      );

      // 换一个**全新的** store 实例：证明读的是文件，不是进程内内存
      final b = AppMediaPlaybackStore(fileResolver: () async => file);
      final read = await b.loadSubtitleStyle();
      expect(read.offset, 80);
      expect(read.background, isTrue);

      // 反向：没存过 ⇒ 默认（原样 + 无背景条）
      final c = AppMediaPlaybackStore(
        fileResolver: () async => File('${dir.path}/missing.json'),
      );
      expect(await c.loadSubtitleStyle(), MediaSubtitleStyle.defaults);
    });

    test('② 非法值吸附到最近档位；坏 JSON 回默认（不许让偏好问题打断播放）', () async {
      expect(normalizeMediaSubtitleOffset(37), 40);
      expect(normalizeMediaSubtitleOffset(-5), 0);
      expect(normalizeMediaSubtitleOffset(999), 120);
      expect(normalizeMediaSubtitleOffset(double.nan), 0);
      expect(normalizeMediaSubtitleOffset(double.infinity), 0);
      expect(normalizeMediaSubtitleOffset(0), 0);

      expect(mediaSubtitleStyleFromJson(null), MediaSubtitleStyle.defaults);
      expect(mediaSubtitleStyleFromJson('junk'), MediaSubtitleStyle.defaults);
      expect(
        mediaSubtitleStyleFromJson({'offset': 'x', 'background': 1}),
        MediaSubtitleStyle.defaults,
      );
      expect(
        mediaSubtitleStyleFromJson({'offset': 79, 'background': true}),
        const MediaSubtitleStyle(offset: 80, background: true),
      );
    });

    testWidgets('③ 进页面就是上次的档位；改一次存一次', (tester) async {
      final store = InMemoryMediaPlaybackStore();
      await store.saveSubtitleStyle(
        const MediaSubtitleStyle(offset: 80, background: true),
      );
      final adapter = _Adapter();
      adapter.embeddedSubtitleText = '字幕';
      await _pump(tester, adapter, store: store);
      await tester.pump(const Duration(milliseconds: 50));

      // 上次是 +80 ⇒ 字幕已经被抬起来了（不是"打开又回到默认"）
      final restored = tester
          .getTopLeft(find.byKey(const Key('media-subtitle-text')))
          .dy;

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();
      expect(find.text('+80'), findsOneWidget,
          reason: 'DA270：进页面就该是上次调好的档位');

      await tester.tap(find.byKey(const Key('media-subtitle-higher')));
      await tester.pumpAndSettle();
      expect(
        (await store.loadSubtitleStyle()).offset,
        120,
        reason: 'DA270：改一次就要落盘（不然下次又是旧的）',
      );

      await tester.tap(find.byKey(const Key('media-subtitle-background')));
      await tester.pumpAndSettle();
      expect(
        (await store.loadSubtitleStyle()).background,
        isFalse,
        reason: 'DA270：背景条开关同样要落盘（上次开着的，这次再点就关）',
      );
      expect(restored, lessThan(600), reason: '抬过的字幕还在画面上半部分');
    });
  });

  group('DA271：兜底引擎（libmpv）上这两项也要真生效', () {
    test('① mpv 属性换算：像素→百分比（相对播放窗口）+ 只包住文字的半透明底', () {
      // ★ r656 真机教训：这台机器的 libmpv 不认 `sub-margin-y`（设了不动），
      //   认的是 `sub-pos` 百分比 ⇒ 必须按**播放窗口高度**把像素换算过去。
      final off = mpvSubtitleProperties(offsetPx: 0, background: false);
      expect(off['sub-pos'], '100', reason: '默认贴底');
      expect(off['sub-border-style'], 'outline-and-shadow');
      expect(off['sub-back-color'], '#FF000000');

      // 窗口 2090px（真机这一页的播放区实测），抬 80px ⇒ 100 − 80×100/2090 = 96.17
      final on = mpvSubtitleProperties(
        offsetPx: 80,
        background: true,
        windowHeightPx: 2090,
      );
      expect(on['sub-pos'], '96.17',
          reason: 'DA271：+80 要真的抬 80 像素（百分比按窗口高度换算，不许瞎猜）');
      expect(on['sub-border-style'], 'opaque-box',
          reason: 'DA271：背景条只包住文字，不是整屏黑底');
      expect(on['sub-back-color'], '#80000000',
          reason: 'DA271：半透明黑 —— 与自家浮层的观感一致');

      // 不知道窗口高度（还没出画）⇒ 不许乱抬
      expect(mpvSubtitleProperties(offsetPx: 80, background: false)['sub-pos'], '100');
      // 负偏移没有语义 ⇒ 归零
      expect(
        mpvSubtitleProperties(offsetPx: -30, background: false, windowHeightPx: 1000)['sub-pos'],
        '100',
      );
      expect(
        mpvSubtitleProperties(offsetPx: 400, background: false, windowHeightPx: 1000)['sub-pos'],
        '60.00',
        reason: '抬得再狠也不许把字幕顶出画面（clamp 到 0）',
      );
    });

    test('② 换引擎（主 → 兜底）时样式跟着过去', () async {
      final primary = _Adapter();
      final fallback = _StylingAdapter();
      final adapter = FallbackPlayerAdapter(
        primary: primary,
        createFallback: () => fallback,
      );
      addTearDown(adapter.dispose);

      await adapter.setSubtitleStyle(offsetPx: 80, background: true);
      // 主引擎不是 styling 引擎 ⇒ 没设上（也不该抛）
      expect(fallback.styles, isEmpty);

      // 让主引擎报一条"全都解不了"的音轨 ⇒ 触发换引擎
      primary.audioTracks = const [
        MediaTrackInfo(
          id: '1',
          kind: MediaTrackKind.audio,
          label: 'ac3',
          isSupported: false,
        ),
      ];
      await adapter.load(_source());
      primary.emitChange();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(adapter.activeAdapter, same(fallback));
      expect(fallback.styles, isNotEmpty,
          reason: 'DA271：换到 mpv 的同一刻就要把位置/背景交过去');
      expect(fallback.styles.last.offsetPx, 80);
      expect(fallback.styles.last.background, isTrue);
    });

    testWidgets('③ 兜底引擎（mpv 那种）上位置/背景两行要摆出来，字号仍然不摆', (tester) async {
      final adapter = _StylingAdapter();
      await _pump(tester, adapter, store: InMemoryMediaPlaybackStore());
      await tester.pump(const Duration(milliseconds: 50));

      // 真机上 mpv 是"选了字幕轨之后才画"，文本不上报 ⇒ 用"有选中轨"当判据
      adapter.subtitleTrackId = '2';
      adapter.emitChange();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('media-settings-row-subtitle-position')),
        findsOneWidget,
        reason: 'DA271：mpv 听得懂 sub-margin-y ⇒ 这一行不许再藏',
      );
      expect(
        find.byKey(const Key('media-settings-row-subtitle-backdrop')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('media-settings-row-subtitle-size')),
        findsNothing,
        reason: '字号仍由 mpv 决定 ⇒ 继续藏（宁可少给，不给假控件）',
      );

      await tester.tap(find.byKey(const Key('media-subtitle-higher')));
      await tester.pumpAndSettle();
      expect(adapter.styles.last.offsetPx, 40,
          reason: 'DA271：点"往上"要真的交给引擎，不是只改读数');
    });

    testWidgets('④ 反向：只说"我画字幕"却听不懂的引擎 ⇒ 两行都不摆（DA269 不回退）',
        (tester) async {
      final adapter = _SelfRenderingAdapter();
      await _pump(tester, adapter, store: InMemoryMediaPlaybackStore());
      await tester.pump(const Duration(milliseconds: 50));

      adapter.subtitleTrackId = '2';
      adapter.embeddedSubtitleText = '字幕';
      adapter.emitChange();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('media-settings-row-subtitle-position')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('media-settings-row-subtitle-backdrop')),
        findsNothing,
      );
    });
  });
}
