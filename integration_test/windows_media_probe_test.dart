// Windows 站 · r703 音视频本地播放「量读数」探针（**只读，不碰 NAS**）
//
// 目的：给 `AppCapability.localMediaPlayback` 在 Windows 列的 available 找读数。
// 两条判据（缺一不可）：
//   ① 音频：`JustAudioStationPlayer` 播**本地文件**，`position` 必须 > 0 且**两次读数在涨**；
//   ② 视频：`createDefaultMediaPlayerAdapter()` 在 Windows 必须落到 libmpv 分支，
//      `ready` 之后 `position` 在涨，且 **`Player.screenshot()` 取到的两帧像素不同**、
//      每帧**不是纯色**（证明出的是真画面，不是黑屏/灰块）。
//      ★ **不许**用 `RepaintBoundary.toImage()` 判这一点：`Texture` 由引擎合成、
//      不进 layer tree 的栅格化，这么抓**必然全黑**（r703 现场踩过，全黑是仪器问题）。
//      窗口级的最终判据（跨进程 `CopyFromScreen`）见 `tool/probe/r703_video_window.dart`
//      与 `docs/evidence-r703-win/90_video_frame_{1,2}.png`。
//
// 媒体素材由宿主侧生成后放进 guest 的 `C:\src\media`（`tone.wav` 6s 440Hz、
// `sample.mp4` 320x240 testsrc 6s H.264+AAC），见 `docs/windows-page-coverage.md` §4.5。
//
// 跑法（guest 内）：
//   flutter test integration_test/windows_media_probe_test.dart -d windows

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/native_video_player.dart';

const String _mediaDir = r'C:\src\media';
const String _audioUri = 'file:///C:/src/media/tone.wav';
const String _videoUri = 'file:///C:/src/media/sample.mp4';
const String _reportPath = r'C:\src\media_probe.txt';

final List<String> _report = <String>[];

void _note(String line) {
  _report.add(line);
  debugPrint('[r703probe] $line');
}

void _flush() {
  try {
    File(_reportPath).writeAsStringSync('${_report.join('\n')}\n');
  } on Object catch (e) {
    debugPrint('[r703probe] report write failed: $e');
  }
}

/// 轮询到 [predicate] 为真或超时；返回是否命中。
Future<bool> _waitFor(
  FutureOr<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (await predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

Future<Uint8List> _grab(GlobalKey key) async {
  final object = key.currentContext!.findRenderObject()!;
  final boundary = object as RenderRepaintBoundary;
  final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
  final ByteData? bytes =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// 画面「有内容」的判据：采样点里不同颜色数 ≥ 8，且亮度极差 ≥ 40。
({int colors, int lumaRange}) _stats(Uint8List rgba) {
  final Set<int> colors = <int>{};
  int lo = 255;
  int hi = 0;
  for (int i = 0; i + 3 < rgba.length; i += 4 * 97) {
    final int r = rgba[i];
    final int g = rgba[i + 1];
    final int b = rgba[i + 2];
    colors.add((r << 16) | (g << 8) | b);
    final int luma = ((r * 299 + g * 587 + b * 114) ~/ 1000);
    if (luma < lo) lo = luma;
    if (luma > hi) hi = luma;
  }
  return (colors: colors.length, lumaRange: hi - lo);
}

int _diffBytes(Uint8List a, Uint8List b) {
  final int n = a.length < b.length ? a.length : b.length;
  int diff = 0;
  for (int i = 0; i < n; i += 4) {
    if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) {
      diff++;
    }
  }
  return diff;
}

Future<void> main() async {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  MediaKit.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(windows: true);

  setUpAll(() {
    _note('host=${Platform.operatingSystem} '
        'version=${Platform.operatingSystemVersion}');
    for (final String p in <String>[
      '$_mediaDir\\tone.wav',
      '$_mediaDir\\sample.mp4',
    ]) {
      final File f = File(p);
      _note('asset $p exists=${f.existsSync()} '
          'bytes=${f.existsSync() ? f.lengthSync() : 0}');
    }
    _flush();
  });

  tearDownAll(_flush);

  testWidgets('① 音频：本地 wav 进度真的在走', (WidgetTester tester) async {
    final AudioStationPlayer player = JustAudioStationPlayer();
    addTearDown(() async {
      await player.stop();
      final Object p2 = player;
      if (p2 is AudioEngineExtras) await p2.dispose();
    });

    final List<Object> audioErrors = <Object>[];
    final Object maybeExtras = player;
    if (maybeExtras is AudioEngineExtras) {
      maybeExtras.errors.listen(audioErrors.add);
    }

    await player.play(_audioUri);
    _note('audio engine=${player.runtimeType}');

    final bool started = await _waitFor(() => player.position > Duration.zero);
    final Duration p1 = player.position;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final Duration p2 = player.position;
    final Duration? dur = player.duration;
    _note('audio started=$started p1=${p1.inMilliseconds}ms '
        'p2=${p2.inMilliseconds}ms duration=${dur?.inMilliseconds}ms');
    _flush();

    expect(audioErrors, isEmpty, reason: 'audio 异步错误: $audioErrors');
    expect(started, isTrue, reason: '音频 20s 内 position 一直是 0');
    expect(p2.inMilliseconds, greaterThan(p1.inMilliseconds),
        reason: '音频 position 没在涨：p1=$p1 p2=$p2');
    expect(p2.inMilliseconds, greaterThan(300),
        reason: '音频只走了 ${p2.inMilliseconds}ms，太短');
  });

  testWidgets('② 视频：libmpv 出真帧且进度在走', (WidgetTester tester) async {
    final MediaPlayerAdapter adapter = createDefaultMediaPlayerAdapter();
    _note('video adapter=${adapter.runtimeType}');
    addTearDown(adapter.dispose);

    expect('${adapter.runtimeType}', contains('MpvPlayerAdapter'),
        reason: 'Windows 应落 libmpv 分支，实际 ${adapter.runtimeType}');

    await adapter.load(
      const MediaSource(
        uri: _videoUri,
        channel: MediaChannel.other,
        kind: MediaKind.video,
        displayName: 'r703 probe clip',
      ),
    );
    final bool ready = await _waitFor(() => adapter.ready);
    _note('video ready=$ready error=${adapter.error} '
        'aspect=${adapter.aspectRatio}');
    expect(adapter.error, isNull, reason: 'video error: ${adapter.error}');
    expect(ready, isTrue, reason: '20s 内视频没 ready');

    await adapter.play();

    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 320,
                height: 240,
                child: Builder(builder: adapter.buildSurface),
              ),
            ),
          ),
        ),
      ),
    );

    final bool moving = await _waitFor(() => adapter.position > Duration.zero);
    await tester.pump(const Duration(milliseconds: 200));
    final Duration v1 = adapter.position;

    final Uint8List frame1 = (await tester.runAsync(() => _grab(key)))!;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final Uint8List frame2 = (await tester.runAsync(() => _grab(key)))!;
    final Duration v2 = adapter.position;

    final ({int colors, int lumaRange}) s1 = _stats(frame1);
    final ({int colors, int lumaRange}) s2 = _stats(frame2);
    final int diff = _diffBytes(frame1, frame2);
    _note('video moving=$moving v1=${v1.inMilliseconds}ms '
        'v2=${v2.inMilliseconds}ms');
    _note('frame1 colors=${s1.colors} lumaRange=${s1.lumaRange}');
    _note('frame2 colors=${s2.colors} lumaRange=${s2.lumaRange}');
    _note('frameDiffPixels=$diff of ${frame1.length ~/ 4}');
    _flush();

    expect(moving, isTrue, reason: '视频 20s 内 position 一直是 0');
    expect(v2.inMilliseconds, greaterThan(v1.inMilliseconds),
        reason: '视频 position 没在涨：v1=$v1 v2=$v2');
    expect(s1.colors, greaterThanOrEqualTo(8),
        reason: '第一帧只有 ${s1.colors} 种颜色（疑似黑屏）');
    expect(s1.lumaRange, greaterThanOrEqualTo(40),
        reason: '第一帧亮度极差只有 ${s1.lumaRange}（疑似纯色）');
    expect(diff, greaterThan(200), reason: '两帧只差 $diff 个像素，画面像冻住了');
  });
}
