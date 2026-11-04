// Bug B 的**页面层承重**用例：真机 Theora `.mkv` 是"内嵌播放器 + 全黑、没有任何
// 提示"（Media3 既不出首帧也不给 `onPlayerError`）。看门狗必须在"起播无进展"时
// 把错误交给**既有的** `MediaFallbackPanel`，文案走既有 `codecUnsupported`
// （"系统解码器不支持这个文件的编码"），而不是继续黑屏。
//
// 这里用的是**真实的** `NativeVideoPlayerAdapter` + 假 `PlayerBridge`，只把
// 看门狗窗口注入成 2s（默认 5s）—— 所以断言的是生产接线，不是假的适配器。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/native_video_player.dart';

/// 最小假桥：只回 texture id、吞掉 load/play，事件由测试注入。
class _FakeBridge implements PlayerBridge {
  final _events = StreamController<Map<Object?, Object?>>.broadcast();

  final loads = <Map<String, Object?>>[];
  int plays = 0;

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
  Future<void> playNext() async {}

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

/// `create()` 可以**卡住**的假桥：用来抓住"订阅已完成、播放器还没建"那一瞬
/// （`DA305` 的窗口）。
class _GatedCreateBridge extends _FakeBridge {
  _GatedCreateBridge(this._gate);

  final Completer<void> _gate;
  bool created = false;

  @override
  Future<int> create() async {
    await _gate.future;
    created = true;
    return super.create();
  }
}

MediaSource _video([String name = 'theora.mkv']) => MediaSource(
  uri: 'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download&_sid=S',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: name,
  supportsRange: true,
);

/// 挂一个用**真实适配器**的 `MediaPlayerView`；返回假桥 + 适配器。
Future<(_FakeBridge, NativeVideoPlayerAdapter)> _pump(
  WidgetTester tester,
) async {
  final bridge = _FakeBridge();
  addTearDown(bridge.close);
  final adapter = NativeVideoPlayerAdapter(
    bridge: bridge,
    watchdogTimeout: const Duration(seconds: 2),
  );
  final container = ProviderContainer(
    overrides: [
      mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(adapter.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(body: MediaPlayerView(source: _video())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return (bridge, adapter);
}

void main() {
  testWidgets('看门狗：prepare 后无首帧无错误 → 出现「编码不支持」回退面板', (tester) async {
    final (bridge, adapter) = await _pump(tester);
    expect(bridge.loads, hasLength(1), reason: '已经交给原生载入');
    expect(bridge.plays, 1, reason: 'autoPlay 已经请求播放 → 看门狗在计时');
    expect(adapter.error, isNull);
    expect(find.byType(MediaFallbackPanel), findsNothing, reason: '窗口内还是黑屏播放器');

    // 窗口（2s）到点：既没有 onPlayerError，也没有首帧/尺寸
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(find.byType(MediaFallbackPanel), findsOneWidget);
    expect(find.text('播放失败'), findsOneWidget);
    expect(find.textContaining('系统解码器不支持这个文件的编码'), findsOneWidget);
    expect(find.text('用其他应用打开'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);

    // 让页面 dispose，别把适配器的订阅/计时器留到测试结束
    await tester.pumpWidget(const SizedBox());
  });

  // ★ r675（`DA303`）：iOS 上 mkv/avi 是"音频在放、画面永远没有"——
  //   `AVPlayer` 照常 `readyToPlay`、位置一路推进，但零画面证据。
  //   旧判据在"位置在推进且没播到结尾"时**无限**再看一轮 ⇒ 用户对着黑屏+声音
  //   等到片尾（真机三张截图一模一样）。现在：用户点选的条目最多忍 3 个窗口。
  testWidgets('DA303：时钟在推但零画面 ⇒ 有界判死（不是无限黑屏）', (tester) async {
    final (bridge, adapter) = await _pump(tester);
    // 一条有视频轨的条目（不是"没有视频轨"那条正证据），时长 10 分钟
    bridge.emit({
      'kind': 'tracks',
      'videoCount': 1,
      'audio': <Object?>[],
      'subtitle': <Object?>[],
    });
    // 每 250ms 一个 tick，位置持续前进（= 音频在放、画面没有）
    var posMs = 0;
    Future<void> tick() async {
      posMs += 3000;
      bridge.emit({
        'kind': 'state',
        'playing': true,
        'ready': true,
        'positionMs': posMs,
        'durationMs': 600000,
        'buffering': false,
      });
    }

    // 3 个窗口（每个 2s）内不该判死
    for (var w = 0; w < 2; w++) {
      for (var i = 0; i < 8; i++) {
        await tick();
        await tester.pump(const Duration(milliseconds: 250));
      }
    }
    expect(adapter.error, isNull,
        reason: '前两个窗口属于"慢起播/冷缓存"的合理宽限');
    expect(find.byType(MediaFallbackPanel), findsNothing);

    // 第 3 个窗口到点 ⇒ 必须给出**既有**回退面板（原因 + 用其他应用打开 + 下载）
    for (var i = 0; i < 8; i++) {
      await tick();
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(adapter.error, isNotNull,
        reason: '★ DA303：位置一直在推也必须判死（否则永远黑屏）');
    expect(find.byType(MediaFallbackPanel), findsOneWidget);
    expect(find.textContaining('系统解码器不支持这个文件的编码'), findsOneWidget);
    expect(find.text('用其他应用打开'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  // ★ r675（`DA303`）的第二种现场（iOS `.mkv`/`.AVI`）：**一直 buffering、
  //   从没进 READY、也不报错** —— 旧判据"慢速网络再看一轮"没有上界 ⇒ 永远黑屏。
  //   阈值是 2 倍窗口（慢起播宽容度），到点必须给既有回退面板。
  testWidgets('DA303②：一直 buffering 无 READY ⇒ 2 倍窗口后判死', (tester) async {
    final (bridge, adapter) = await _pump(tester);
    bridge.emit({
      'kind': 'tracks',
      'videoCount': 1,
      'audio': <Object?>[],
      'subtitle': <Object?>[],
    });
    // 持续 buffering，位置不动、ready 永远 false
    Future<void> bufferingTick() async {
      bridge.emit({
        'kind': 'state',
        'playing': false,
        'ready': false,
        'positionMs': 0,
        'buffering': true,
      });
    }

    // 第一个窗口（2s）到点：只算"再看一轮"，不许判死
    await bufferingTick();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(adapter.error, isNull, reason: '慢网络起播的合理宽容');
    expect(find.byType(MediaFallbackPanel), findsNothing);

    // 继续 buffering 到 2 倍窗口（= 第 4 个窗口）之后 ⇒ 必须判死
    for (var i = 0; i < 4; i++) {
      await bufferingTick();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
    }
    expect(adapter.error, isNotNull,
        reason: '★ DA303②：一直 buffering 必须判死（否则永远是残帧黑屏）');
    expect(find.byType(MediaFallbackPanel), findsOneWidget);
    expect(find.textContaining('系统解码器不支持这个文件的编码'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  // ★ r675（`DA304`）：iOS 桥对**含空格/中文**的文件名建不出 `URL` 时，旧代码
  //   `guard ... else { return }` **静默返回**（不换条目、不报错）⇒ 上一支视频
  //   继续播、新页面顶着它的标题与进度。现在桥必须报一条**明确错误**
  //   （`invalid-url:`），Dart 侧走既有回退面板 —— 这条用例钉的正是这条契约：
  //   "原生报 error ⇒ 一定不是黑屏，一定给原因 + 出路"。
  testWidgets('DA304：原生报 invalid-url ⇒ 既有回退面板（不许静默黑屏）',
      (tester) async {
    final (bridge, adapter) = await _pump(tester);
    bridge.emit({
      'kind': 'error',
      'message': 'invalid-url: cannot build URL from the given media source',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(adapter.error, isNotNull);
    expect(find.byType(MediaFallbackPanel), findsOneWidget);
    expect(find.text('用其他应用打开'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  // ★ r675（`DA305`）：iOS/macOS 桥是**进程内单例**（一个 EventChannel、`create()`
  //   才换新播放器）。订阅发生在 `create()` **之前**，`onListen` 立刻把**上一条**
  //   视频的状态（`index`/`position`/`duration`）推过来。旧代码照单全收 ⇒ 新页面
  //   顶着上一支视频的名字与进度（r675 真机三张截图一模一样，标题/进度都是
  //   上一支 mp4 的）。
  //
  //   这条用例把"订阅已完成、`create()` 还没回"那一瞬**卡住**，在窗口内推一条
  //   "上一条的残影"，断言它一条都不许进。
  test('DA305：自己的播放器还没建时，收到的事件一条都不许用', () async {
    final gate = Completer<void>();
    final bridge = _GatedCreateBridge(gate);
    addTearDown(bridge.close);
    final adapter = NativeVideoPlayerAdapter(
      bridge: bridge,
      watchdogTimeout: const Duration(seconds: 2),
    );
    addTearDown(adapter.dispose);

    final loading = adapter.load(_video());
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(bridge.created, isFalse, reason: 'create 还卡在闸门上');
    // 上一条视频的"残影"：时长 10:12、已经播到 00:09、播放列表下标 3
    bridge.emit({
      'kind': 'state',
      'playing': true,
      'ready': true,
      'positionMs': 9000,
      'durationMs': 612000,
      'index': 3,
      'buffering': false,
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(adapter.position, Duration.zero,
        reason: '★ DA305：还没有自己的播放器 ⇒ 上一条的位置不许进来');
    expect(adapter.duration, isNull, reason: '上一条的时长也不许进来');
    expect(adapter.playlistIndex, 0, reason: '上一条的列表下标也不许进来');

    gate.complete();
    await loading;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(adapter.position, Duration.zero);
    expect(adapter.playlistIndex, 0);
  });

  testWidgets('首帧正常到达（H.264 等）→ 不出现回退面板，播放器界面保留', (tester) async {
    final (bridge, adapter) = await _pump(tester);
    bridge.emit({'kind': 'state', 'firstFrame': true, 'videoWidth': 160});
    await tester.pump();

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(adapter.error, isNull, reason: '看到首帧就必须解除看门狗');
    expect(find.byType(MediaFallbackPanel), findsNothing);
    expect(find.byKey(const Key('media-play-pause')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('播放列表自动续播下一条 → 页面不得出现「编码不支持」面板（H.264 不能被拖累）', (tester) async {
    // R4 真机形态：上一条 H.264 已经出过画面（尺寸/首帧都到），片尾 Media3
    // 自动续播下一条（原生清尺寸/首帧 + index 变化）。页面标题仍是上一条的名字，
    // 所以这里一旦弹面板就会表现为"能播的 H.264 被判成编码不支持"。
    final (bridge, adapter) = await _pump(tester);
    bridge.emit({
      'kind': 'state',
      'positionMs': 100,
      'videoWidth': 160,
      'videoHeight': 120,
      'firstFrame': true,
    });
    await tester.pump();
    expect(find.byType(MediaFallbackPanel), findsNothing);

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

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(adapter.error, isNull, reason: '自动换集不许给下一条装表');
    expect(find.byType(MediaFallbackPanel), findsNothing);
    expect(find.textContaining('系统解码器不支持这个文件的编码'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('真实播放错误优先：报的是它自己的文案，不是看门狗', (tester) async {
    final (bridge, adapter) = await _pump(tester);
    bridge.emit({
      'kind': 'state',
      'error': 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED: socket closed',
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(adapter.error, contains('NETWORK_CONNECTION_FAILED'));
    expect(find.byType(MediaFallbackPanel), findsOneWidget);
    expect(find.textContaining('网络'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('r438：本条零画面证据 ⇒ 上一条留在 surface 上的残帧必须被盖黑', (tester) async {
    // r437 真机读数：自动续播到"只有音轨、没有视频流"的条目时，顶栏已经是**新条目**、
    // 提示条也在，而画面区仍是**上一条的最后一帧**（`px(574,1400)=(0,0,244)` 纯蓝）。
    // 提示说的是"本条播不了"，画面却是上一条 —— 观感自相矛盾，用户会以为播错了东西。
    // 本用例守的是：这种状态下画面区必须被**不透光的黑**整块盖住（音频照旧在播）。
    final (bridge, adapter) = await _pump(tester);

    // ① 上一条真的出过画（尺寸/首帧都到）⇒ **不许**盖黑
    bridge.emit({
      'kind': 'state',
      'positionMs': 100,
      'videoWidth': 160,
      'videoHeight': 120,
      'firstFrame': true,
    });
    await tester.pump();
    expect(
      find.byKey(const Key('media-no-picture-blackout')),
      findsNothing,
      reason: '有画面证据时绝不许盖黑（否则正常播放全被吃掉）',
    );

    // ② 片尾自动续播到"零画面证据"的下一条（原生清尺寸/首帧 + index 变化）
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
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    // 先自证"真的进了零画面状态"，否则下面的断言是假绿（仪器⑯）
    expect(
      adapter.hasNoPictureContinuationNotice,
      isTrue,
      reason: '没进"零画面证据"状态的话，本用例什么都没验到',
    );
    expect(find.byKey(const Key('media-continuation-notice')), findsOneWidget,
        reason: '非阻塞提示条必须还在（盖的是画面，不是提示）');

    final blackout = find.byKey(const Key('media-no-picture-blackout'));
    final surface = find.byKey(const Key('media-video-surface'));
    expect(blackout, findsOneWidget, reason: '零画面时必须盖黑上一条的残帧');
    expect(surface, findsOneWidget, reason: 'surface 仍要在树里（音频还在播，不许拆掉播放器）');
    // 盖住的是**整个**画面区（与 surface 同矩形），不是一小条
    expect(tester.getRect(blackout), tester.getRect(surface));
    final box = tester.widget<ColoredBox>(blackout);
    expect(box.color, Colors.black);
    expect(box.color.a, 1.0, reason: '必须不透光：半透明的黑挡不住残帧');

    await tester.pumpWidget(const SizedBox());
  });
}
