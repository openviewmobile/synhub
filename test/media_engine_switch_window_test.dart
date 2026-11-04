// ★ r678（`DA311`）：**换引擎的窗口对页面必须可见**。
//
// 现场（iOS · `.mkv`）：主引擎 AVFoundation 立刻报 `-11828 / NSOSStatusErrorDomain
// (-12847)`，libmpv 兜底往往一秒多就能出画面。页面若在主引擎报错的**那一帧**就把
// 致命面板挂上去，用户看到的是"明明能播，却写着解不开" —— r676 那张 mkv 面板正是
// 这么来的（当时还没有兜底引擎，面板是对的；现在有了兜底，面板就是假结论）。
//
// 三条判据（缺一不可）：
//   ① 换引擎窗口内：`error` 报 **null**（主引擎的错误属于"上一代"），
//      `engineSwitchPending == true`；
//   ② 窗口内页面**不许**出现 `MediaFallbackPanel`（不许抢先判死）；
//   ③ 兜底引擎就绪后：面板仍然没有、`usingFallbackEngine == true`、
//      之前记下的失败被撤掉（画面回到播放器）。
//
// 反向验证（去掉抑制）：把 `FallbackPlayerAdapter.error` 的 `_switching ? null`
// 去掉 ⇒ ① 红；把页面的 `switchWindow` 让路去掉 ⇒ ② 红。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/fallback_player_adapter.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';

MediaSource _mkv() => const MediaSource(
      uri: 'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download'
          '&mode=download&path=%2Fvideo%2FCitizen%2520Kane%2520(1941).mkv',
      channel: MediaChannel.fileStation,
      kind: MediaKind.video,
      displayName: 'Citizen Kane (1941).mkv',
      supportsRange: true,
    );

/// 假适配器：既能当主引擎（会报 `-11828`），也能当兜底引擎（就绪、有画面）。
class _FakeEngine
    implements
        MediaPlayerAdapter,
        MediaPlayerEngineSwitchable,
        MediaPlayerNeedsSurfaceWhileLoading,
        MediaPlayerFullControls {
  _FakeEngine({this.readyValue = true});

  final bool readyValue;
  final _changes = StreamController<void>.broadcast();

  String? errorValue;

  /// 载入闸门：兜底引擎"还在打开这个文件"的那段时间（真机上是 1～2 秒）
  Completer<void>? loadGate;

  /// 载入期是否需要纹理（libmpv = true；普通引擎 = false）
  @override
  bool needsSurfaceWhileLoading = false;

  /// 页面层的让路判据（由用例直接摆布；真实现是 `FallbackPlayerAdapter`）
  @override
  bool engineSwitchPending = false;

  @override
  bool usingFallbackEngine = false;

  /// 释放闸门：主引擎 `dispose()` 也要时间（真机上结束 AVPlayer 是异步的）。
  /// 有它才能把窗口**冻在「当前引擎还是主引擎」那一刻**去断言 ——
  /// 否则主引擎被换掉之后 `error` 天然是 null，测不出"抑制"这条机制。
  Completer<void>? disposeGate;
  bool playingValue = false;
  Duration positionValue = Duration.zero;
  bool disposed = false;
  double _volume = 1;
  bool _muted = false;
  double _speed = 1;
  MediaAspectMode _aspect = MediaAspectMode.fit;

  void emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> load(MediaSource source) async {
    final gate = loadGate;
    if (gate != null) await gate.future;
  }

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
    emit();
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
  }

  @override
  Future<void> dispose() async {
    final gate = disposeGate;
    if (gate != null) await gate.future;
    disposed = true;
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Duration get position => positionValue;

  @override
  Duration? get duration => const Duration(minutes: 2);

  @override
  bool get playing => playingValue;

  @override
  bool get ready => readyValue;

  @override
  double get speed => _speed;

  @override
  String? get error => errorValue;

  @override
  double get aspectRatio => 16 / 9;

  /// 画面用一个可判定的小方块表示：真出画时才在树里
  @override
  Widget buildSurface(BuildContext context) =>
      const SizedBox.expand(key: Key('fake-engine-surface'));

  @override
  Stream<void> get changes => _changes.stream;

  // ── MediaPlayerFullControls（只实现接口成员，行为为空/常量）──
  @override
  Future<void> skipBy(Duration offset) async {}

  @override
  Future<void> setVolume(double value) async {
    _volume = value;
  }

  @override
  double get volume => _volume;

  @override
  Future<void> setMuted(bool value) async {
    _muted = value;
  }

  @override
  bool get muted => _muted;

  @override
  Future<void> setPlaylist(List<MediaSource> items, int index) async {}

  @override
  int get playlistIndex => 0;

  @override
  int get playlistLength => 1;

  @override
  bool get hasPrevious => false;

  @override
  bool get hasNext => false;

  @override
  Future<void> playNext() async {}

  @override
  Future<void> playPrevious() async {}

  @override
  Future<void> setAspectMode(MediaAspectMode mode) async {
    _aspect = mode;
  }

  @override
  MediaAspectMode get aspectMode => _aspect;

  @override
  List<MediaTrackInfo> get audioTracks => const [];

  @override
  List<MediaTrackInfo> get subtitleTracks => const [];

  @override
  String? get selectedAudioTrackId => null;

  @override
  String? get selectedSubtitleTrackId => null;

  @override
  Future<void> selectAudioTrack(String? id) async {}

  @override
  Future<void> selectSubtitleTrack(String? id) async {}

  @override
  String? get embeddedSubtitleText => null;
}

Future<void> _pumpView(
  WidgetTester tester,
  MediaSource source, {
  required MediaPlayerAdapter adapter,
}) async {
  final container = ProviderContainer(
    overrides: [
      mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: MediaPlayerView(source: source)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  testWidgets('DA311 换引擎窗口：主引擎报 -11828 的那一秒不许挂致命面板，兜底就绪后回到画面',
      (tester) async {
    final primary = _FakeEngine();
    final fallback = _FakeEngine();

    /// 兜底引擎"载入"要花一点时间 —— 正是这段窗口在真机上是 1～2 秒
    var fallbackLoaded = false;
    final gate = Completer<void>();
    fallback.loadGate = gate;
    final disposeGate = Completer<void>();
    primary.disposeGate = disposeGate;
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () {
        fallbackLoaded = true;
        return fallback;
      },
    );

    await _pumpView(tester, _mkv(), adapter: adapter);

    // 主引擎报"容器解不开"（iOS 上 `.mkv` 的真实错误串）
    primary.errorValue =
        'AVFoundation -11828 / NSOSStatusErrorDomain(-12847) | '
        'cannot open matroska';
    primary.emit();
    await tester.pump();

    // ① 窗口内：error 被抑制、闩亮着
    expect(
      adapter.error,
      isNull,
      reason: '换引擎窗口内 `error` 必须是 null（主引擎的错误属于上一代）',
    );
    expect(
      adapter.engineSwitchPending,
      isTrue,
      reason: '换引擎窗口必须对页面可见（否则页面只能靠猜）',
    );

    // ② 窗口内：页面**不许**出现致命面板
    expect(
      find.byType(MediaFallbackPanel),
      findsNothing,
      reason: '兜底引擎还在载入，这一秒挂面板就是"明明能播却写着解不开"',
    );

    // 此刻**当前引擎仍是主引擎**（它的错误串还没被换掉）—— 这正是最危险的
    // 那一帧：如果没有抑制，`error` 会把 `-11828` 交给页面。
    expect(primary.disposed, isFalse, reason: '窗口必须还冻在主引擎上，否则测不出抑制');
    expect(
      adapter.error,
      isNull,
      reason: '主引擎还在窗口里，`-11828` 不许冒充当前引擎的结论',
    );

    // 主引擎释放完 → 兜底引擎才被建出来（真机顺序一致：先 dispose 再 new）
    disposeGate.complete();
    await tester.pump();
    expect(fallbackLoaded, isTrue, reason: '判死就该换引擎');

    // 兜底引擎就绪出画（真机上 = libmpv 解出 w/h）
    gate.complete();
    await tester.pump();
    fallback.errorValue = null;
    fallback.playingValue = true;
    fallback.emit();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // ③ 兜底就绪后：仍然没有面板，且换引擎这件事对页面可见
    expect(find.byType(MediaFallbackPanel), findsNothing);
    expect(adapter.usingFallbackEngine, isTrue);
    expect(adapter.engineSwitchPending, isFalse);
    expect(adapter.error, isNull);
    expect(
      find.byKey(const Key('fake-engine-surface')),
      findsOneWidget,
      reason: '当前引擎的画面必须真的挂到树上（libmpv 的出画前提）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('DA311 页面机制：`engineSwitchPending` 亮着时，即便 `error` 非空也不许挂面板',
      (tester) async {
    // 这一条**只**测页面的让路逻辑（不经过 `FallbackPlayerAdapter` 的 error 抑制）：
    // 假适配器同时给出"有错误" + "正在换引擎"，页面必须选后者。
    final engine = _FakeEngine()
      ..engineSwitchPending = true
      ..errorValue = 'AVFoundation -11828 / NSOSStatusErrorDomain(-12847)';
    await _pumpView(tester, _mkv(), adapter: engine);
    await tester.pump();

    expect(
      find.byType(MediaFallbackPanel),
      findsNothing,
      reason: '换引擎窗口内页面必须让路（否则会出现"明明能播却写着解不开"）',
    );

    // 窗口结束、错误还在 ⇒ 这时才是真结论
    engine.engineSwitchPending = false;
    engine.emit();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(
      find.byType(MediaFallbackPanel),
      findsOneWidget,
      reason: '窗口过完还有错误 ⇒ 面板必须出现（让路不许变成吞掉失败）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('DA311 载入期纹理：引擎说要就**载入中**也挂 media-video-surface（libmpv 没 vo 不解码）',
      (tester) async {
    // r677 探针实测：libmpv 没有 `vo` 时 `duration` 有、`videoParams` 永远 TIMEOUT；
    // 纹理一挂上，mkv/avi 都解出 `w=320 h=240`。所以载入分支必须给它 surface。
    final engine = _FakeEngine(readyValue: false)..needsSurfaceWhileLoading = true;
    await _pumpView(tester, _mkv(), adapter: engine);
    await tester.pump();

    expect(
      find.byKey(const Key('media-video-surface')),
      findsOneWidget,
      reason: '载入期间也要把纹理挂上（否则 libmpv 根本不解码）',
    );
    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason: '但用户侧仍必须是"载入中"',
    );

    await tester.pumpWidget(const SizedBox());
  });

  // ★ 反向前提单独一条（同一 `testWidgets` 里换适配器会复用 `MediaPlayerView`
  //   的 State ⇒ 旧适配器还在，量到的是上一棵树 —— r677 `DA308` 踩过同一坑）。
  testWidgets('DA311 载入期纹理 反向：不需要纹理的引擎照旧走封面/占位',
      (tester) async {
    final plain = _FakeEngine(readyValue: false);
    await _pumpView(tester, _mkv(), adapter: plain);
    await tester.pump();
    expect(
      find.byKey(const Key('media-video-surface')),
      findsNothing,
      reason: '这条证明判据不是恒真',
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('DA311 反向：窗口过完兜底也失败 ⇒ 面板照常出现（不许把真失败吞掉）',
      (tester) async {
    final primary = _FakeEngine();
    final fallback = _FakeEngine(readyValue: false);
    final adapter = FallbackPlayerAdapter(
      primary: primary,
      createFallback: () => fallback,
    );
    await _pumpView(tester, _mkv(), adapter: adapter);

    primary.errorValue = 'AVFoundation -11828 / NSOSStatusErrorDomain(-12847)';
    primary.emit();
    await tester.pump();
    expect(find.byType(MediaFallbackPanel), findsNothing);

    // 兜底引擎也解不开 ⇒ 这次必须是**真结论**，面板照出
    fallback.errorValue = 'mpv: could not open codec';
    fallback.emit();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byType(MediaFallbackPanel),
      findsOneWidget,
      reason: '两个引擎都解不开时，面板是唯一诚实结果（不许被窗口逻辑吞掉）',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
