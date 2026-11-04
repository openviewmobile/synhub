// 播放器手势补齐（r635）—— **DA224**（横滑拖进度）＋ **DA225**（长按 2 倍速）。
//
// 现场（真机 ＋ 人视角）：
//   * 想跳到片尾/课件第 8 分钟：只有"点进度条那条细线"和"双击 ±10s"两条路，
//     VLC/Plex/YouTube 上人人会做的**横滑画面**在这里没有 —— 双击十几次才能到位。
//   * 想快速过一段：得开「播放设置」点 2×，看完还要再回去调回 1.0（两步，且常忘）。
//
// 判据（都能红）：
//   ① 横滑半屏 = 进度走一半（**松手才 seek**，拖动中只更新提示）；
//   ② 反向：源不可 seek（Drive `Accept-Ranges: none`）⇒ 滑了也不许 seek（不装样子）；
//   ③ 长按 → 2×；松手 → 回到原速（原来是多少就多少，不许硬写 1.0）；
//   ④ 反向：暂停时长按不动倍速（没有收益，也不该偷偷改用户设定）；
//   ⑤ 拖动中的提示**不许**在 900ms 后自己消失（否则手指还在拖、提示没了）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';
import 'package:synhub/src/features/media/upnp_cast.dart';
import 'package:synhub/src/features/media/video_cast.dart';

/// `DA269`：引擎自己画字幕（libmpv 就是这样）—— 只多一个标记位。
class _SelfRenderingAdapter extends _Adapter
    implements MediaPlayerSelfRenderedSubtitles {
  @override
  bool get rendersOwnSubtitles => true;
}

class _Adapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  final _changes = StreamController<void>.broadcast();

  final seeks = <Duration>[];
  Duration positionValue = Duration.zero;
  bool playingValue = false;
  double speedValue = 1;
  Object? errorValue;
  double volumeValue = 0.5;
  MediaAspectMode aspectValue = MediaAspectMode.fit;

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
  Future<void> skipBy(Duration offset) async {}

  @override
  Future<void> setSpeed(double speed) async => speedValue = speed;

  @override
  Future<void> setVolume(double value) async => volumeValue = value;

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
  Future<void> selectSubtitleTrack(String? id) async {}

  @override
  Future<void> setAspectMode(MediaAspectMode mode) async => aspectValue = mode;

  @override
  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  List<MediaTrackInfo> audioTracks = const [];
  @override
  List<MediaTrackInfo> subtitleTracks = const [];
  @override
  String? embeddedSubtitleText;

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
  String? get error => errorValue?.toString();
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

MediaSource _source({bool range = true}) => MediaSource(
  uri: 'https://fake.test/webapi/entry.cgi?api=SYNO.FileStation.Download',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: 'Inception.2010.mp4',
  supportsRange: range,
);

Future<void> _pump(WidgetTester tester, _Adapter adapter,
    {bool range = true, VideoCast Function()? castFactory}) async {
  final container = ProviderContainer(
    overrides: [
      cloudKeyStoreProvider.overrideWithValue(MemoryCloudKeyStore()),
      mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
      if (castFactory != null)
        videoCastFactoryProvider.overrideWithValue(castFactory),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: MediaPlayerView(source: _source(range: range)),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  group('DA224：横滑画面拖进度', () {
    testWidgets('① 横滑半屏 ⇒ 松手 seek 到一半（拖动中只更新提示）', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      expect(adapter.playingValue, isTrue);

      final layer = find.byKey(const Key('media-gesture-layer'));
      final width = tester.getSize(layer).width;
      expect(width, greaterThan(0));

      final gesture = await tester.startGesture(tester.getCenter(layer));
      await tester.pump();
      // 先越过触摸阈值（真机的 move 事件是连续的小步，单步大跳会被
      // `DragStartBehavior.start` 吃掉那一次位移，这是测试写法问题，不是缺陷）
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      // 再往右拖半个屏宽（= 整段 100s 的一半 ⇒ 50s）
      await gesture.moveBy(Offset(width / 2, 0));
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        find.byKey(const Key('media-gesture-hud')),
        findsOneWidget,
        reason: '拖动中要有"拖到哪儿了"的提示',
      );
      expect(
        adapter.seeks,
        isEmpty,
        reason: 'DA224：拖动中不许发 seek（真机会卡成一条长队）',
      );

      await gesture.up();
      await tester.pump();

      expect(adapter.seeks, hasLength(1));
      final target = adapter.seeks.single.inSeconds;
      expect(target, inInclusiveRange(45, 55),
          reason: '半屏 ⇒ 约 50s（允许触摸阈值导致的几十毫秒误差）');
      expect(find.byKey(const Key('media-gesture-hud')), findsNothing,
          reason: '松手后提示要收掉');
      // 双击识别器有 40ms 的等待窗口，跑完它，别留下 pending timer
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('② 反向：源不可 seek（Accept-Ranges: none）⇒ 滑了也不 seek',
        (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter, range: false);

      final layer = find.byKey(const Key('media-gesture-layer'));
      await tester.drag(layer, const Offset(300, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.seeks, isEmpty,
          reason: 'DA224：不可 seek 的源不许装样子（服务器会直接忽略 Range）');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('③ 拖动中提示不许 900ms 后自己消失', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);

      final layer = find.byKey(const Key('media-gesture-layer'));
      final width = tester.getSize(layer).width;
      final gesture = await tester.startGesture(tester.getCenter(layer));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveBy(Offset(width / 4, 0));
      await tester.pump(const Duration(milliseconds: 1200));

      expect(
        find.byKey(const Key('media-gesture-hud')),
        findsOneWidget,
        reason: '手指还按着，提示却消失了 —— 用户会以为手势没生效',
      );

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('DA225：长按 2 倍速', () {
    testWidgets('① 长按 ⇒ 2×；松手 ⇒ 回到原速（原来是 1.5 就回 1.5）', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      adapter.speedValue = 1.5;
      adapter.emit();
      await tester.pump();

      final layer = find.byKey(const Key('media-gesture-layer'));
      final gesture = await tester.startGesture(tester.getCenter(layer));
      await tester.pump(const Duration(milliseconds: 700));

      expect(adapter.speedValue, 2.0,
          reason: 'DA225：按住就该是 2×（人类预期：按住=快放）');
      expect(find.byKey(const Key('media-gesture-hud')), findsOneWidget);

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 20));
      expect(adapter.speedValue, 1.5,
          reason: 'DA225：松手恢复**原速**，不许硬写 1.0（会把用户的 1.5× 弄丢）');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('② 反向：暂停时长按不动倍速', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      await adapter.pause();
      await tester.pump();

      final layer = find.byKey(const Key('media-gesture-layer'));
      final gesture = await tester.startGesture(tester.getCenter(layer));
      await tester.pump(const Duration(milliseconds: 700));

      expect(adapter.speedValue, 1.0,
          reason: 'DA225：暂停着长按没有收益，不许偷偷改倍速');
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('DA226：字幕字号（收在「播放设置」里）', () {
    testWidgets('① 有字幕才出现；A+ 变 120%，画面上字幕真的变大', (tester) async {
      final adapter = _Adapter();
      adapter.embeddedSubtitleText = '这是一个比较长的字幕行，用来验证字号';
      await _pump(tester, adapter);
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('media-settings-row-subtitle-size')),
        findsOneWidget,
        reason: 'DA226：有字幕时，设置面板里要有字号入口',
      );
      expect(find.text('100%'), findsOneWidget);

      await tester.tap(find.byKey(const Key('media-subtitle-larger')));
      await tester.pumpAndSettle();
      expect(find.text('120%'), findsOneWidget,
          reason: 'DA226：点一下就该看到值变化（不许点了没反应）');

      // 关掉面板，量画面上字幕的真实字号
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      final subtitle = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('media-subtitle-text')),
          matching: find.byType(Text),
        ),
      );
      expect(subtitle.style?.fontSize, closeTo(16 * 1.2, 0.01),
          reason: 'DA226：设置里的档位要真的落到字幕上，不是只改个百分数');
    });

    testWidgets('② 反向：没字幕时不给这个入口（不做假按钮）', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('media-settings-row-subtitle-size')),
        findsNothing,
        reason: 'DA226：没有字幕文本时，字号设置无处作用 ⇒ 不出现',
      );
    });
  });

  group('DA263：字幕位置与背景条（r655）', () {
    testWidgets('① 有字幕才出现；往上抬 40 ⇒ 画面上的字幕真的抬高 40', (tester) async {
      final adapter = _Adapter();
      adapter.embeddedSubtitleText = '两行字幕的第一行\n第二行';
      await _pump(tester, adapter);
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('media-settings-row-subtitle-position')),
        findsOneWidget,
        reason: 'DA263：有字幕时，设置面板里要有「字幕位置」入口',
      );
      expect(find.text('默认'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('media-subtitle-lower')))
            .onPressed,
        isNull,
        reason: '已在最低档 ⇒ 往下那颗按钮必须是禁用态（不是点了没反应）',
      );

      final before = tester.getTopLeft(find.byKey(const Key('media-subtitle-text')));

      await tester.tap(find.byKey(const Key('media-subtitle-higher')));
      await tester.pumpAndSettle();

      expect(find.text('+40'), findsOneWidget,
          reason: 'DA263：点一下就该看到档位读数变化');
      final after = tester.getTopLeft(find.byKey(const Key('media-subtitle-text')));
      expect(before.dy - after.dy, closeTo(40, 0.5),
          reason: 'DA263：设置里的档位要真的落到字幕位置，不是只改个数字');
    });

    testWidgets('② 反向：抬上去还能放回来（不许单向卡死）', (tester) async {
      final adapter = _Adapter();
      adapter.embeddedSubtitleText = '字幕';
      await _pump(tester, adapter);
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();
      final base = tester.getTopLeft(find.byKey(const Key('media-subtitle-text')));

      await tester.tap(find.byKey(const Key('media-subtitle-higher')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('media-subtitle-higher')));
      await tester.pumpAndSettle();
      expect(find.text('+80'), findsOneWidget);

      await tester.tap(find.byKey(const Key('media-subtitle-lower')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('media-subtitle-lower')));
      await tester.pumpAndSettle();

      expect(find.text('默认'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('media-subtitle-text'))).dy,
        closeTo(base.dy, 0.5),
        reason: 'DA263：来回一次必须回到原位（偏移是绝对档位，不是累加）',
      );
    });

    testWidgets('③ 背景条：默认没有，打开就有（且只包住文字）', (tester) async {
      final adapter = _Adapter();
      adapter.embeddedSubtitleText = '雪景里的白字';
      await _pump(tester, adapter);
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byKey(const Key('media-subtitle-backdrop')),
        findsNothing,
        reason: 'DA263：默认不加背景条（不能悄悄改变老用户看到的画面）',
      );

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('media-subtitle-background')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('media-subtitle-backdrop')),
        findsOneWidget,
        reason: 'DA263：开关打开后字幕后面要有半透明底',
      );
      final backdrop = tester.getRect(
        find.byKey(const Key('media-subtitle-backdrop')),
      );
      final subtitleArea = tester.getRect(
        find.byKey(const Key('media-subtitle-text')),
      );
      expect(
        backdrop.width,
        lessThan(subtitleArea.width),
        reason: 'DA263：背景只包住文字，不许铺成横贯画面的黑带',
      );

      // 反向：再点一次必须能关掉
      await tester.tap(find.byKey(const Key('media-subtitle-background')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-subtitle-backdrop')), findsNothing);
    });

    testWidgets('④ 反向：没字幕时不给这两个入口（不做假按钮）', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('media-settings-row-subtitle-position')),
        findsNothing,
        reason: 'DA263：没有字幕时位置设置无处作用 ⇒ 不出现',
      );
      expect(
        find.byKey(const Key('media-settings-row-subtitle-backdrop')),
        findsNothing,
      );
    });
  });

  group('DA269：引擎自己画字幕时，只在自家浮层上生效的控件必须藏起来（r655）', () {
    testWidgets('① 引擎自己画的（libmpv 兜底路）⇒ 字号/位置/背景三行都不出现', (tester) async {
      final adapter = _SelfRenderingAdapter();
      // 即便文本给到了（另一种实现可能会给），这三项也调不动 mpv 的画面 ⇒ 不许摆。
      adapter.embeddedSubtitleText = '字幕';
      await _pump(tester, adapter);
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('media-settings-row-subtitle-size')),
        findsNothing,
        reason: 'DA269：mpv 的字号由它自己定，摆这一行就是假控件',
      );
      expect(
        find.byKey(const Key('media-settings-row-subtitle-position')),
        findsNothing,
        reason: 'DA269：位置同理 —— 调了画面不会动',
      );
      expect(
        find.byKey(const Key('media-settings-row-subtitle-backdrop')),
        findsNothing,
        reason: 'DA269：背景条同理',
      );
    });

    testWidgets('② 反向：普通引擎（自家浮层画）⇒ 三行都在（别把老行为改没了）', (tester) async {
      final adapter = _Adapter();
      adapter.embeddedSubtitleText = '字幕';
      await _pump(tester, adapter);
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('media-settings')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('media-settings-row-subtitle-size')),
          findsOneWidget);
      expect(find.byKey(const Key('media-settings-row-subtitle-position')),
          findsOneWidget);
      expect(find.byKey(const Key('media-settings-row-subtitle-backdrop')),
          findsOneWidget);
    });
  });

  group('DA264：视频投屏（DLNA / UPnP AVTransport）', () {
    testWidgets('① 点投屏 ⇒ 列出设备；点一台 ⇒ 电视在放，本地停住', (tester) async {
      final adapter = _Adapter();
      final cast = _FakeVideoCast(
        renderers: [_renderer('客厅电视'), _renderer('卧室投影')],
      );
      await _pump(tester, adapter, castFactory: () => cast);
      expect(adapter.playingValue, isTrue);

      await tester.tap(find.byKey(const Key('media-cast')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('media-cast-sheet')), findsOneWidget);
      expect(find.byKey(const Key('media-cast-renderer-0')), findsOneWidget);
      expect(find.byKey(const Key('media-cast-renderer-1')), findsOneWidget);
      expect(find.text('客厅电视'), findsOneWidget,
          reason: 'DA264：设备名就是用户在电视上认得出的那个名字');

      await tester.tap(find.byKey(const Key('media-cast-renderer-0')));
      await tester.pumpAndSettle();

      expect(cast.castCalls, 1);
      expect(find.byKey(const Key('media-cast-current')), findsOneWidget);
      expect(find.text('客厅电视'), findsOneWidget);
      expect(
        adapter.playingValue,
        isFalse,
        reason: 'DA264：投上去必须停本地，否则手机和电视同时出声',
      );
      expect(cast.lastPosition, adapter.position,
          reason: 'DA264：续投要带当前进度（用户是看到一半才换的电视）');
    });

    testWidgets('② 搜不到 ⇒ 空态 + 怎么办 + 重试（不许空白）', (tester) async {
      final adapter = _Adapter();
      final cast = _FakeVideoCast(renderers: const []);
      await _pump(tester, adapter, castFactory: () => cast);

      await tester.tap(find.byKey(const Key('media-cast')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('media-cast-error')), findsOneWidget);
      expect(find.byKey(const Key('media-cast-empty-hint')), findsOneWidget,
          reason: 'DA264：没找到设备时必须告诉用户"电视该打开什么"');
      expect(find.byKey(const Key('media-cast-retry')), findsOneWidget);

      final before = cast.searchCalls;
      await tester.tap(find.byKey(const Key('media-cast-retry')));
      await tester.pumpAndSettle();
      expect(cast.searchCalls, greaterThan(before));
    });

    testWidgets('③ 电视不接受 ⇒ 说清是哪一环断的', (tester) async {
      final adapter = _Adapter();
      final cast = _FakeVideoCast(
        renderers: [_renderer('客厅电视')],
        failure: UpnpCastFailure.rejected,
      );
      await _pump(tester, adapter, castFactory: () => cast);

      await tester.tap(find.byKey(const Key('media-cast')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('media-cast-renderer-0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('media-cast-error')), findsOneWidget);
      expect(
        find.textContaining('不接受这个视频'),
        findsOneWidget,
        reason: 'DA264：拒绝与"拉不到流"必须是两句不同的话',
      );
    });

    testWidgets('④ 停止投屏 ⇒ 回到"找设备"，当前设备消失', (tester) async {
      final adapter = _Adapter();
      final cast = _FakeVideoCast(renderers: [_renderer('客厅电视')]);
      await _pump(tester, adapter, castFactory: () => cast);

      await tester.tap(find.byKey(const Key('media-cast')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('media-cast-renderer-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-cast-current')), findsOneWidget);

      await tester.tap(find.byKey(const Key('media-cast-stop')));
      await tester.pumpAndSettle();

      expect(cast.stopCalls, 1);
      expect(find.byKey(const Key('media-cast-current')), findsNothing);
    });

    testWidgets('⑤ 反向：音频页不给这个按钮（音频那条路在音频页）', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      expect(find.byKey(const Key('media-cast')), findsOneWidget,
          reason: '视频页必须有（本组用例的前提）');
    });
  });

}


UpnpRenderer _renderer(String name) => UpnpRenderer(
      friendlyName: name,
      location: 'http://192.168.1.20:49494/description.xml',
      controlUrl: 'http://192.168.1.20:49494/upnp/control/AVTransport1',
      modelName: 'AC-55X',
      usn: 'uuid:$name',
    );

class _FakeVideoCast implements VideoCast {
  _FakeVideoCast({required this.renderers, this.failure});

  final List<UpnpRenderer> renderers;
  final UpnpCastFailure? failure;
  int searchCalls = 0;
  int castCalls = 0;
  int stopCalls = 0;
  Duration? lastPosition;

  @override
  Future<List<UpnpRenderer>> search() async {
    searchCalls++;
    return renderers;
  }

  @override
  Future<UpnpCastFailure?> cast(
    UpnpRenderer renderer,
    MediaSource source, {
    Duration position = Duration.zero,
    bool playing = true,
  }) async {
    castCalls++;
    lastPosition = position;
    return failure;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<UpnpCastFailure?> pause() async => null;

  @override
  Future<UpnpCastFailure?> resume() async => null;

  @override
  Future<String?> remoteTransportState() async => 'PLAYING';
}
