// r703 · `W-1` 的实验矩阵探针（Windows guest 专用，不进发布包）
//
// 要回答的问题：`VideoOutput.Resize` 恒 `0×0` 到底是
//   ① 视频输出这条路径在 x64 模拟的 ARM64 guest 上根本没站起来（环境），还是
//   ② 我们**没有把尺寸协商做对**（我们的代码问题）。
//
// 三条臂，同一条片子、同一台机、同一次进程：
//   A `default`  —— 生产路径的用法（默认 `VideoController`，不给尺寸）；
//   B `setSize`  —— 建完之后调 `VideoController.setSize(320,240)`（文档推荐的运行期尺寸协商）；
//   C `screenshot` —— 绕开纹理，直接取 libmpv 解出来的帧（`Player.screenshot()`）。
//   判据：`rect` 是否非 0、`screenshot` 的帧是否有内容、两帧是否不同。
//
// 跑法：
//   flutter build windows --debug -t tool/probe/r703_video_matrix.dart
//   build\windows\x64\runner\Debug\synhub.exe        （读 C:\src\video_matrix.txt）
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const String kVideoUri = 'file:///C:/src/media/sample.mp4';
const String kReportPath = r'C:\src\video_matrix.txt';

final List<String> _lines = <String>[];

void _note(String line) {
  _lines.add(line);
  debugPrint('[matrix] $line');
  try {
    File(kReportPath).writeAsStringSync('${_lines.join('\n')}\n');
  } on Object catch (e) {
    debugPrint('[matrix] write failed: $e');
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
  int d = 0;
  for (int i = 0; i < n; i++) {
    if (a[i] != b[i]) d++;
  }
  return d;
}

Future<Uint8List?> _decode(Uint8List encoded) async {
  final ui.Codec codec = await ui.instantiateImageCodec(encoded);
  final ui.FrameInfo frame = await codec.getNextFrame();
  final ByteData? data =
      await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  return data?.buffer.asUint8List();
}

Future<void> _waitFor(Future<bool> Function() test,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final DateTime t0 = DateTime.now();
  while (DateTime.now().difference(t0) < timeout) {
    if (await test()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<void> _arm(String name, {bool setSize = false}) async {
  final DateTime t0 = DateTime.now();
  Player? p;
  try {
    p = Player();
    final VideoController vc = VideoController(p);
    await p.open(Media(kVideoUri), play: true);
    await _waitFor(() async => p!.state.position > Duration.zero);
    _note('$name afterOpen rect=${vc.rect.value} id=${vc.id.value} '
        'params=${p.state.width}x${p.state.height} '
        'pos=${p.state.position.inMilliseconds}ms');
    if (setSize) {
      try {
        await vc.setSize(width: 320, height: 240)
            .timeout(const Duration(seconds: 10));
        _note('$name setSize returned ok');
      } on Object catch (e) {
        _note('$name setSize FAILED: $e');
      }
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    _note('$name after2s rect=${vc.rect.value} id=${vc.id.value} '
        'pos=${p.state.position.inMilliseconds}ms');
    // C 臂：绕开纹理，直接取解出来的帧。
    Uint8List? prev;
    for (int i = 0; i < 3; i++) {
      final Uint8List? shot =
          await p.screenshot(format: 'image/png'); // ignore: avoid_await_never
      if (shot == null) {
        _note('$name shot#$i null');
      } else {
        final Uint8List? rgba = await _decode(shot);
        if (rgba == null) {
          _note('$name shot#$i decode null bytes=${shot.length}');
        } else {
          final ({int colors, int lumaRange}) st = _stats(rgba);
          final int diff = prev == null ? 0 : _diffBytes(prev, rgba);
          _note('$name shot#$i bytes=${shot.length} '
              'px=${rgba.length ~/ 4} colors=${st.colors} '
              'luma=${st.lumaRange} diff=$diff');
          prev = rgba;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  } on Object catch (e) {
    _note('$name FAILED: $e');
  } finally {
    try {
      await p?.dispose();
    } on Object catch (_) {}
    _note('$name elapsed=${DateTime.now().difference(t0).inMilliseconds}ms');
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  unawaited(() async {
    _note('boot dart=${Platform.version}');
    await _arm('A_default');
    await _arm('B_setSize', setSize: true);
    _note('DONE');
    await Future<void>.delayed(const Duration(seconds: 30));
    exit(0);
  }());
  runApp(const MaterialApp(
    home: Scaffold(body: Center(child: Text('r703 video matrix'))),
  ));
}
