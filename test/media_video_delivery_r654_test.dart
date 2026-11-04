// 视频播放器「交付级」两件事（r654）：
//   * `DA259` 画中画：按钮只在**真支持**时出现、点了按当前比例进小窗、
//     进小窗后**收起整套控件**（系统手势进入时 Dart 从来没调过 enter()）；
//   * `DA260` 音轨解不了：**先说明白**（会有画面没声音），再给"换一条音轨 /
//     用其他应用打开"两条出路，而不是让用户面对一个静音的视频。
//
// 判据都要能红：
//   ① 不支持的音轨被选中 ⇒ 出现提示条、文案里带编码、可换轨；
//   ② 反向：音轨都支持 ⇒ 不出现提示条（不许无病呻吟）；
//   ③ 未选中标记时"全都解不了"也算 ⇒ 出现；只坏一条且没选中它 ⇒ 不出现；
//   ④ 不支持的设备 ⇒ **不渲染**画中画按钮（不摆假入口）；
//   ⑤ 支持的设备 ⇒ 有按钮、点它用 aspectRatio 调 enter；
//   ⑥ 收到小窗事件 ⇒ 控制条消失；退出 ⇒ 回来；
//   ⑦ 通道层：`supported`/`enter` 参数/`setAutoEnter`/事件回调都走通；
//      非 Android 宿主（无插件）⇒ false，且**不抛**。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/media_tracks.dart';
import 'package:synhub/src/features/media/video_pip.dart';

MediaTrackInfo _track({
  required String id,
  required String codec,
  bool supported = true,
  bool selected = false,
}) => MediaTrackInfo(
  id: id,
  kind: MediaTrackKind.audio,
  codec: codec,
  channels: 2,
  isSelected: selected,
  isSupported: supported,
);

class _Adapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  _Adapter({this.tracks = const [], this.ratio = 16 / 9});

  final _changes = StreamController<void>.broadcast();
  final enters = <double>[];
  final audioSelections = <String?>[];
  final seeks = <Duration>[];
  List<MediaTrackInfo> tracks;
  double ratio;
  String? selectedAudio = 'audio:0:0';
  bool playingValue = true;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> load(MediaSource source) async {}

  @override
  Future<void> play() async {
    playingValue = true;
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    playingValue = false;
    _changes.add(null);
  }

  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> dispose() async {}

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 42);

  @override
  bool get playing => playingValue;

  @override
  bool get ready => true;

  @override
  double get speed => 1;

  @override
  String? get error => null;

  @override
  double get aspectRatio => ratio;

  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(color: Colors.black);

  @override
  Future<void> skipBy(Duration offset) async {}

  @override
  Future<void> setVolume(double value) async {}

  @override
  double get volume => 1;

  @override
  Future<void> setMuted(bool value) async {}

  @override
  bool get muted => false;

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
  List<MediaTrackInfo> get audioTracks => tracks;

  @override
  List<MediaTrackInfo> get subtitleTracks => const [];

  @override
  String? get selectedAudioTrackId => selectedAudio;

  @override
  String? get selectedSubtitleTrackId => null;

  @override
  Future<void> selectAudioTrack(String? id) async {
    audioSelections.add(id);
    selectedAudio = id;
    tracks = [
      for (final track in tracks)
        track.copyWith(isSelected: track.id == id),
    ];
    _changes.add(null);
  }

  @override
  Future<void> selectSubtitleTrack(String? id) async {}

  @override
  MediaAspectMode get aspectMode => MediaAspectMode.fit;

  @override
  Future<void> setAspectMode(MediaAspectMode mode) async {}

  @override
  String? get embeddedSubtitleText => null;
}

class _FakePip implements VideoPipController {
  _FakePip({this.support = true});

  final bool support;
  final _inPip = ValueNotifier<bool>(false);
  final enters = <double>[];
  final autoEnter = <bool>[];

  void emit(bool value) => _inPip.value = value;

  @override
  ValueListenable<bool> get inPictureInPicture => _inPip;

  @override
  Future<bool> supported() async => support;

  @override
  Future<bool> enter(double aspectRatio) async {
    enters.add(aspectRatio);
    return true;
  }

  @override
  Future<void> setAutoEnter(bool enabled) async => autoEnter.add(enabled);

  @override
  Future<void> dispose() async {}
}

MediaSource _source() => MediaSource(
  uri:
      'https://fake.test/webapi/entry.cgi?api=SYNO.FileStation.Download&_sid=1',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: 'movie.mkv',
  supportsRange: true,
);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Adapter adapter, {
  VideoPipController? pip,
}) async {
  final container = ProviderContainer(
    overrides: [
      cloudKeyStoreProvider.overrideWithValue(MemoryCloudKeyStore()),
      mediaPlayerAdapterFactoryProvider.overrideWithValue(() => adapter),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: MediaPlayerView(
            source: _source(),
            autoPlay: false,
            pip: pip,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return container;
}

void main() {
  group('DA260：音轨本机解不了', () {
    testWidgets('① 选中的音轨不支持 ⇒ 提示条带编码 + 可换轨', (tester) async {
      final adapter = _Adapter(
        tracks: [
          _track(id: 'audio:0:0', codec: 'ac-3', supported: false, selected: true),
          _track(id: 'audio:0:1', codec: 'mp4a.40.2'),
        ],
      );
      await _pump(tester, adapter);

      expect(find.byKey(const Key('media-audio-unsupported')), findsOneWidget);
      expect(
        find.textContaining('ac-3', findRichText: true),
        findsOneWidget,
        reason: '要说清是哪条编码，不然用户不知道换哪条',
      );
      expect(
        find.byKey(const Key('media-audio-unsupported-switch')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('media-audio-unsupported-switch')));
      await tester.pumpAndSettle();
      // 打开的是音轨面板：两条都在，且坏的那条带「本机不支持」
      expect(find.text('#1 · ac-3 · 2 ch · 本机不支持'), findsOneWidget);
    });

    testWidgets('② 反向：音轨都支持 ⇒ 不出现提示条', (tester) async {
      final adapter = _Adapter(
        tracks: [_track(id: 'audio:0:0', codec: 'mp4a.40.2', selected: true)],
      );
      await _pump(tester, adapter);
      expect(find.byKey(const Key('media-audio-unsupported')), findsNothing);
    });

    testWidgets('③ 没给选中标记时：全都解不了才报', (tester) async {
      final allBad = _Adapter(
        tracks: [
          _track(id: 'audio:0:0', codec: 'dts', supported: false),
          _track(id: 'audio:0:1', codec: 'eac3', supported: false),
        ],
      );
      allBad.selectedAudio = null;
      await _pump(tester, allBad);
      expect(find.byKey(const Key('media-audio-unsupported')), findsOneWidget);

    });

    testWidgets('③b 只有一条坏、还没选中它 ⇒ 不打扰', (tester) async {
      final partlyBad = _Adapter(
        tracks: [
          _track(id: 'audio:0:0', codec: 'dts', supported: false),
          _track(id: 'audio:0:1', codec: 'mp4a.40.2'),
        ],
      );
      partlyBad.selectedAudio = null;
      await _pump(tester, partlyBad);
      expect(
        find.byKey(const Key('media-audio-unsupported')),
        findsNothing,
        reason: '只有一条坏、还没选中它 ⇒ 不该打扰用户',
      );
    });

    test('④ 模型：缺 supported 键按 true；toMap 往返不丢', () {
      expect(
        MediaTrackInfo.fromMap({'id': 'audio:0:0', 'kind': 'audio'}).isSupported,
        isTrue,
      );
      expect(
        MediaTrackInfo.fromMap({
          'id': 'audio:0:0',
          'kind': 'audio',
          'supported': false,
        }).isSupported,
        isFalse,
      );
      final back = MediaTrackInfo.fromMap(
        _track(id: 'audio:0:1', codec: 'ac-3', supported: false).toMap(),
      );
      expect(back.isSupported, isFalse);
      expect(back.codec, 'ac-3');
    });
  });

  group('DA259：画中画', () {
    testWidgets('⑤ 不支持 ⇒ 不渲染按钮', (tester) async {
      final pip = _FakePip(support: false);
      await _pump(
        tester,
        _Adapter(tracks: [_track(id: 'audio:0:0', codec: 'aac')]),
        pip: pip,
      );
      expect(find.byKey(const Key('media-pip')), findsNothing);
    });

    testWidgets('⑥ 支持 ⇒ 有按钮，点它按实际比例进小窗', (tester) async {
      final pip = _FakePip();
      await _pump(
        tester,
        _Adapter(ratio: 2.39, tracks: [_track(id: 'audio:0:0', codec: 'aac')]),
        pip: pip,
      );
      expect(find.byKey(const Key('media-pip')), findsOneWidget);
      await tester.tap(find.byKey(const Key('media-pip')));
      await tester.pump();
      expect(pip.enters, [closeTo(2.39, 0.001)]);
    });

    testWidgets('⑦ 小窗事件 ⇒ 控件收起；退出 ⇒ 恢复', (tester) async {
      final pip = _FakePip();
      await _pump(
        tester,
        _Adapter(tracks: [_track(id: 'audio:0:0', codec: 'aac')]),
        pip: pip,
      );
      expect(find.byKey(const Key('media-play-pause')), findsOneWidget);

      pip.emit(true);
      await tester.pump();
      expect(
        find.byKey(const Key('media-play-pause')),
        findsNothing,
        reason: '小窗里画整套控件＝视频被挤成一条缝',
      );

      pip.emit(false);
      await tester.pump();
      expect(find.byKey(const Key('media-play-pause')), findsOneWidget);
    });

    testWidgets('⑦b 小窗里点画面 ⇒ 不许 seek（让系统处理放大/关闭）', (tester) async {
      final pip = _FakePip();
      final adapter = _Adapter(
        tracks: [_track(id: 'audio:0:0', codec: 'aac')],
      );
      await _pump(tester, adapter, pip: pip);
      pip.emit(true);
      await tester.pump();
      // 点画面右半（正常是 +10s 快进）
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('media-video-surface'))) +
            const Offset(60, 0),
      );
      await tester.pump();
      expect(
        adapter.seeks,
        isEmpty,
        reason: 'DA261：小窗里我们的手势会先吃掉点击，系统"放大"键就点不动',
      );
    });

    testWidgets('⑧ 播放/暂停的边沿驱动自动进入开关', (tester) async {
      final pip = _FakePip();
      final adapter = _Adapter(
        tracks: [_track(id: 'audio:0:0', codec: 'aac')],
      );
      await _pump(tester, adapter, pip: pip);
      // 边沿：停→播 才开，播→停 就关（初始 `_wasPlaying=false`，所以先 play）
      await adapter.play();
      await tester.pump();
      await adapter.pause();
      await tester.pump();
      await adapter.play();
      await tester.pump();
      expect(pip.autoEnter, containsAllInOrder([true, false, true]));
    });
  });

  group('DA277：退出播放器后小窗不许再冒出来', () {
    testWidgets('① 播放中 pop 掉播放器 ⇒ 自动进入小窗必须关掉', (tester) async {
      final pip = _FakePip();
      final adapter = _Adapter(tracks: [_track(id: 'audio:0:0', codec: 'aac')]);
      await _pump(tester, adapter, pip: pip);
      await adapter.play();
      await tester.pump();
      expect(
        pip.autoEnter.last,
        isTrue,
        reason: '前提：播放中自动进入是开着的（这是它该有的样子）',
      );

      // 用户退出播放器：整页被 pop 掉 ⇒ dispose
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(
        pip.autoEnter.last,
        isFalse,
        reason:
            'DA277：页面没了还留着"自动进入小窗" ⇒ 用户在工作台按 Home，'
            '系统仍会把整个 App 缩成小窗（画面里根本没有视频）',
      );
    });

    testWidgets('② 从小窗放大回来（仍在播）⇒ 自动进入要重新生效', (tester) async {
      final pip = _FakePip();
      final adapter = _Adapter(tracks: [_track(id: 'audio:0:0', codec: 'aac')]);
      await _pump(tester, adapter, pip: pip);
      await adapter.play();
      await tester.pump();
      pip.emit(true);
      await tester.pump();
      // 原生在出小窗时会把 autoEnter 清掉并重设参数；Dart 侧缓存必须跟着作废，
      // 否则"放大回全屏、继续播、再按 Home"就再也不缩窗了（功能回退）。
      pip.emit(false);
      await tester.pump();
      expect(
        pip.autoEnter.last,
        isTrue,
        reason: '还在播 ⇒ 自动进入应当是开着的（与系统播放器一致）',
      );
    });

    testWidgets('③ 反向：暂停中从小窗回来 ⇒ 自动进入仍是关着', (tester) async {
      final pip = _FakePip();
      final adapter = _Adapter(tracks: [_track(id: 'audio:0:0', codec: 'aac')]);
      await _pump(tester, adapter, pip: pip);
      await adapter.play();
      await tester.pump();
      await adapter.pause();
      await tester.pump();
      pip.emit(true);
      await tester.pump();
      pip.emit(false);
      await tester.pump();
      expect(pip.autoEnter.last, isFalse, reason: '暂停时想退出去聊天，画面不该跟着走');
    });
  });

  group('DA259：通道层', () {
    const channel = MethodChannel('synhub/video_pip');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('⑨ supported / enter 参数 / setAutoEnter / 事件', () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'supported':
            return true;
          case 'enter':
          case 'setAutoEnter':
            return true;
        }
        return null;
      });

      final pip = SystemVideoPip(channel: channel);
      addTearDown(pip.dispose);
      expect(await pip.supported(), isTrue);
      expect(await pip.enter(16 / 9), isTrue);
      await pip.setAutoEnter(true);

      final enter = calls.firstWhere((c) => c.method == 'enter');
      expect(enter.arguments, {'width': 16, 'height': 9});
      final auto = calls.firstWhere((c) => c.method == 'setAutoEnter');
      expect(auto.arguments, {'enabled': true});

      // 原生 → Dart 的事件
      await messenger.handlePlatformMessage(
        'synhub/video_pip',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onPipModeChanged', true),
        ),
        (_) {},
      );
      expect(pip.inPictureInPicture.value, isTrue);
    });

    test('⑩ 没有插件（非 Android 宿主）⇒ false，不抛', () async {
      final pip = SystemVideoPip(channel: channel);
      addTearDown(pip.dispose);
      expect(await pip.supported(), isFalse);
      expect(await pip.enter(1.5), isFalse);
      await pip.setAutoEnter(true); // 不抛即通过
    });
  });
}
