// r703 媒体量测**探针入口**（Windows guest 专用，不进发布包）
//
// 为什么不是 `flutter test integration_test/... -d windows`：这台 4 GB 的
// Windows VM 上 `flutter test` 的 kernel_snapshot 会 OOM 崩掉（Dart VM 直接
// dump），而普通 `flutter build windows` 能过。所以把量测做成一个**独立
// entrypoint**，跑出来的 exe 自己把读数写进 `C:\src\media_probe.txt`。
//
// 跑法：
//   flutter build windows --debug -t tool/probe/r703_media_probe.dart
//   build\windows\x64\runner\Debug\synhub.exe
//
// 判据与 `integration_test/windows_media_probe_test.dart` 完全一致：
//   ① 音频 position 在涨；② 视频 adapter 是 Mpv、position 在涨、两帧像素不同且非纯色。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/media/media_player.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/native_video_player.dart';

const String kMediaDir = r'C:\src\media';
const String kAudioUri = 'file:///C:/src/media/tone.wav';
const String kVideoUri = 'file:///C:/src/media/sample.mp4';
const String kReportPath = r'C:\src\media_probe.txt';

final List<String> _lines = <String>[];

void _note(String line) {
  _lines.add(line);
  debugPrint('[r703probe] $line');
  try {
    File(kReportPath).writeAsStringSync('${_lines.join('\n')}\n');
  } on Object catch (e) {
    debugPrint('[r703probe] write failed: $e');
  }
}

({int colors, int lumaRange}) _stats(Uint8List rgba) {
  final Set<int> colors = <int>{};
  int lo = 255;
  int hi = 0;
  for (int i = 0; i + 3 < rgba.length; i += 4 * 97) {
    final int r = rgba[i];
    final int g = rgba[i + 1];
    final int b = rgba[i + 2];
    colors.add((r << 16) | (g << 8) | b);
    final int luma = (r * 299 + g * 587 + b * 114) ~/ 1000;
    if (luma < lo) lo = luma;
    if (luma > hi) hi = luma;
  }
  return (colors: colors.length, lumaRange: hi - lo);
}

int _diffBytes(Uint8List a, Uint8List b) {
  final int n = a.length < b.length ? a.length : b.length;
  int diff = 0;
  for (int i = 0; i < n; i += 4) {
    if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) diff++;
  }
  return diff;
}

Future<bool> _waitFor(
  FutureOr<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (await predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(windows: true);
  _note('boot ${Platform.operatingSystem} ${Platform.version}');
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatefulWidget {
  const _ProbeApp();

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  final GlobalKey _key = GlobalKey();
  MediaPlayerAdapter? _adapter;
  VideoController? _rawController;
  bool _videoLoaded = false;
  String _status = 'starting';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    await _audio();
    await _video();
    _note('DONE');
    await Future<void>.delayed(const Duration(seconds: 45));
    exit(0);
  }

  Future<void> _audio() async {
    final AudioStationPlayer player = JustAudioStationPlayer();
    final List<Object> errors = <Object>[];
    final Object extras = player;
    if (extras is AudioEngineExtras) extras.errors.listen(errors.add);
    try {
      await player.play(kAudioUri);
      final bool started =
          await _waitFor(() => player.position > Duration.zero);
      final Duration p1 = player.position;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final Duration p2 = player.position;
      _note('audio engine=${player.runtimeType} started=$started '
          'p1=${p1.inMilliseconds}ms p2=${p2.inMilliseconds}ms '
          'duration=${player.duration?.inMilliseconds}ms errors=${errors.length}');
    } on Object catch (e) {
      _note('audio FAILED: $e');
    } finally {
      await player.stop();
      if (extras is AudioEngineExtras) await extras.dispose();
    }
  }

  /// 原型：**显式给 VideoController 尺寸**再播同一条片子。
  ///
  /// 动机：`MpvPlayerAdapter` 内部用的是默认 `VideoController`（不给 width/height），
  /// 这台 VM 上 `VideoOutput.Resize` 一直是 `0x0`、纹理因此全黑。若显式给
  /// 320x240 就能出画面，说明缺的是"尺寸"这一环（那就是我们的代码问题，不是环境）。
  Future<void> _rawSurface() async {
    try {
      final Player p = Player();
      final VideoController vc = VideoController(
        p,
        configuration: const VideoControllerConfiguration(
          width: 320,
          height: 240,
        ),
      );
      _rawController = vc;
      await p.open(Media(kVideoUri), play: true);
      final bool ok = await _waitFor(() => p.state.position > Duration.zero);
      _note('raw surface playing=$ok textureId=${vc.id} '
          'videoParams=${p.state.width}x${p.state.height}');
      setState(() {});
    } on Object catch (e) {
      _note('raw surface FAILED: $e');
    }
  }

  Future<void> _video() async {
    await _rawSurface();
    final MediaPlayerAdapter adapter = createDefaultMediaPlayerAdapter();
    _note('video adapter=${adapter.runtimeType}');
    _adapter = adapter;
    try {
      await adapter.load(
        const MediaSource(
          uri: kVideoUri,
          channel: MediaChannel.other,
          kind: MediaKind.video,
          displayName: 'r703 probe clip',
        ),
      );
      final bool ready = await _waitFor(() => adapter.ready);
      _note('video ready=$ready error=${adapter.error} '
          'aspect=${adapter.aspectRatio.toStringAsFixed(3)}');
      if (!ready) return;
      setState(() {
        _videoLoaded = true;
        _status = 'playing';
      });
      await adapter.play();
      final bool moving =
          await _waitFor(() => adapter.position > Duration.zero);
      setState(() => _status = 'capturing');
      // 纹理是**跟着视频参数建**的：先 0x0，拿到 dw/dh 才 Resize。所以按帧轮询，
      // 每 300 ms 抓一次，直到抓到"有内容"的帧（最多 20 次）。
      Uint8List? best;
      int bestColors = 0;
      int bestLuma = 0;
      int bestDiff = 0;
      final List<String> trace = <String>[];
      Uint8List? prev;
      for (int i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final Uint8List? frame = await _grab();
        if (frame == null) {
          trace.add('grab#$i=null');
          continue;
        }
        final ({int colors, int lumaRange}) st = _stats(frame);
        final int diff = prev == null ? 0 : _diffBytes(prev, frame);
        trace.add('grab#$i colors=${st.colors} luma=${st.lumaRange} '
            'diff=$diff');
        if (st.colors > bestColors) {
          bestColors = st.colors;
          bestLuma = st.lumaRange;
          best = frame;
        }
        if (diff > bestDiff) bestDiff = diff;
        prev = frame;
      }
      final Duration v2 = adapter.position;
      _note('video moving=$moving v1=${adapter.position.inMilliseconds}ms '
          'v2=${v2.inMilliseconds}ms');
      _note('video frame trace: ${trace.join(' | ')}');
      _note('video best colors=$bestColors lumaRange=$bestLuma '
          'maxFrameDiff=$bestDiff of ${best == null ? 0 : best.length ~/ 4}');
    } on Object catch (e) {
      _note('video FAILED: $e');
    } finally {
      await adapter.dispose();
    }
  }

  Future<Uint8List?> _grab() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final RenderObject? object = _key.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) return null;
    final ui.Image image = await object.toImage(pixelRatio: 1.0);
    final ByteData? bytes =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return bytes?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(_status, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 12),
              if (_rawController != null)
                SizedBox(
                  width: 320,
                  height: 240,
                  child: Video(controller: _rawController!),
                ),
              const SizedBox(height: 12),
              RepaintBoundary(
                key: _key,
                child: SizedBox(
                  width: 320,
                  height: 240,
                  child: _videoLoaded && _adapter != null
                      ? Builder(builder: _adapter!.buildSurface)
                      : const ColoredBox(color: Colors.black12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
