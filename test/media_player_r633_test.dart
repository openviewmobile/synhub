// 播放器**人视角**修正（r633）—— **DA217**（暂停不许自动收控件）＋
// **DA218**（瞬时失败要给"重试"）。
//
// 现场（审计 + 真机）：
//   * DA217：暂停后盯 10 秒，整层控件消失 ⇒ 想暂停/拖进度/调字幕得先在画面
//     中间点一下把它们叫回来。用户暂停的动机十有八九**就是**要操作控件。
//   * DA218：Wi-Fi 切 4G、服务端短暂 5xx 时，回退面板只有「用其他应用打开 /
//     下载」，**没有"再试一次"** —— 用户唯一能做的动作不在屏上，只能退出重进
//     （还得重新找播放位置）。
//
// 判据（都能红）：
//   ① 在播 → 10s 后控件照旧收起（**不能**为了 DA217 把自动隐藏搞没了）；
//   ② 暂停 → 10s 后控件仍在；恢复播放 → 重新武装并再次收起；
//   ③ 网络类失败 → 面板有「重试」，点了会**重新装载**并回到原来的位置；
//   ④ 反向：解码器/格式类失败 → **不给**「重试」（那是假按钮）。
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

class _Adapter implements MediaPlayerAdapter, MediaPlayerFullControls {
  final _changes = StreamController<void>.broadcast();

  final loads = <String>[];
  final seeks = <Duration>[];
  Duration positionValue = Duration.zero;
  bool playingValue = false;
  Object? errorValue;
  double volumeValue = 0.5;
  double speedValue = 1;
  MediaAspectMode aspectValue = MediaAspectMode.fit;

  void emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> load(MediaSource source) async {
    loads.add(source.uri);
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

MediaSource _playable() => const MediaSource(
  uri: 'https://fake.test/webapi/entry.cgi?api=SYNO.FileStation.Download',
  channel: MediaChannel.fileStation,
  kind: MediaKind.video,
  displayName: 'Inception.2010.mp4',
  supportsRange: true,
);

Future<void> _pump(WidgetTester tester, _Adapter adapter) async {
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
        home: Scaffold(body: MediaPlayerView(source: _playable())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  group('DA217：暂停时控件不许自动消失', () {
    testWidgets('① 在播 → 10s 后照旧收起（自动隐藏没被搞坏）', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      // autoPlay=true ⇒ 已经在播
      expect(adapter.playingValue, isTrue);
      expect(find.byKey(const Key('media-progress')), findsOneWidget);

      await tester.pump(const Duration(seconds: 10, milliseconds: 200));
      expect(
        find.byKey(const Key('media-progress')),
        findsNothing,
        reason: '播放中 10s 不动 → 控件收回（既有行为，不许回归）',
      );
    });

    testWidgets('② 暂停 → 10s 后控件仍在；恢复播放 → 会再次收起', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      await adapter.pause();
      await tester.pump();

      await tester.pump(const Duration(seconds: 12));
      expect(
        find.byKey(const Key('media-progress')),
        findsOneWidget,
        reason: 'DA217：暂停时用户正要操作控件，不许把它们收走',
      );

      await adapter.play();
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      expect(
        find.byKey(const Key('media-progress')),
        findsNothing,
        reason: 'DA217：恢复播放后自动隐藏要重新生效（不许永久粘住）',
      );
    });

    testWidgets('③ 暂停后点控件（快进 10s）仍然有效，且不许被"收走"', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      await adapter.pause();
      await tester.pump();

      // 控件在 → 快进按钮可点（暂停时也要能用）
      expect(find.byKey(const Key('media-forward10')), findsOneWidget);
      await tester.tap(find.byKey(const Key('media-forward10')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      expect(
        find.byKey(const Key('media-progress')),
        findsOneWidget,
        reason: 'DA217：暂停态操作后也不许自动收起',
      );
    });
  });

  group('DA218：瞬时失败给"重试"', () {
    testWidgets('① 网络类失败 → 面板出现「重试」，点了重新装载并回到原位', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      // 先播到 42s（`_lastKnownPosition` 要记住它）
      adapter.positionValue = const Duration(seconds: 42);
      adapter.emit();
      await tester.pump();
      adapter.errorValue = Exception('SocketException: Failed host lookup');
      adapter.playingValue = false;
      adapter.emit();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final retry = find.byKey(const Key('media-session-retry'));
      expect(
        retry,
        findsOneWidget,
        reason: 'DA218：网络中断时用户唯一能做的动作（再试一次）必须在屏上',
      );
      final loadsBefore = adapter.loads.length;

      adapter.errorValue = null;
      await tester.tap(retry);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        adapter.loads.length,
        greaterThan(loadsBefore),
        reason: 'DA218：重试必须**真的重新装载**（旧版只走续期，等于什么都没做）',
      );
      expect(
        adapter.seeks,
        contains(const Duration(seconds: 42)),
        reason: 'DA218：重试后要回到原来的播放位置（不许从头开始）',
      );
    });

    testWidgets('② 反向：解码器/格式解不了 → 不给「重试」（假按钮）', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      adapter.errorValue = Exception('Decoder init failed: V_THEORA is not supported');
      adapter.playingValue = false;
      adapter.emit();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('media-session-retry')), findsNothing,
          reason: 'DA218：这个文件本身解不了，重试是假按钮');
    });
  });

  group('DA223：播放中的事件流不许把自动隐藏计时无限重置', () {
    testWidgets('① 在播时连续发位置事件，控件仍要在 10s 收走（真机回归）', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      expect(adapter.playingValue, isTrue);

      // 原生播放器在播时会持续发 changes（位置/缓冲/码率）。
      // r633 的写法是"每次在播都重新武装" ⇒ 计时被无限重置 ⇒ 真机 15 s 仍常驻。
      for (var i = 0; i < 9; i++) {
        adapter.positionValue = Duration(seconds: i + 1);
        adapter.emit();
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.byKey(const Key('media-progress')),
          findsOneWidget,
          reason: '10s 还没到，控件应当还在（t=${i + 1}s）',
        );
      }

      await tester.pump(const Duration(seconds: 1, milliseconds: 500));
      expect(
        find.byKey(const Key('media-progress')),
        findsNothing,
        reason: 'DA223：计时只认"起播边沿"，事件流不许把它一直往后推',
      );
    });

    testWidgets('② 反向：暂停事件流不会把控件收走（DA217 仍成立）', (tester) async {
      final adapter = _Adapter();
      await _pump(tester, adapter);
      await adapter.pause();
      await tester.pump();

      for (var i = 0; i < 12; i++) {
        adapter.positionValue = Duration(seconds: i);
        adapter.emit();
        await tester.pump(const Duration(seconds: 1));
      }
      expect(
        find.byKey(const Key('media-progress')),
        findsOneWidget,
        reason: 'DA223 与 DA217 同屏共存：暂停态再多事件也不收',
      );
    });
  });
}
