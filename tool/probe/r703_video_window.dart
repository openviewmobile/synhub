// r703 · `W-1` 的**窗口像素**探针（Windows guest 专用，不进发布包）
//
// 为什么还要一条：`RepaintBoundary.toImage()` **拍不到 `Texture`**（纹理由引擎合成，
// 不进 layer tree 的栅格化），用它判"画面出没出来"必然全黑 —— 那是仪器问题。
// 这一条改成"窗口真的把画面画在屏幕上"，由 guest 内 `CopyFromScreen` 取屏
// （跨进程取证，同 r701 Linux 的纪律）。
//
// 判据：两次取屏里该窗口区域 colors > 1、且两次之间像素有变化。
//
// 跑法：
//   flutter build windows --debug -t tool/probe/r703_video_window.dart
//   build\windows\x64\runner\Debug\synhub.exe   （就绪后写 C:\src\video_window_ready.txt）
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const String kVideoUri = 'file:///C:/src/media/sample.mp4';
const String kReadyPath = r'C:\src\video_window_ready.txt';
const String kLogPath = r'C:\src\video_window_log.txt';

void _log(String s) {
  try {
    File(kLogPath).writeAsStringSync('$s\n', mode: FileMode.append);
  } on Object catch (_) {}
  debugPrint('[win] $s');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  _log('boot');
  runApp(const MaterialApp(home: _VideoWindow()));
}

class _VideoWindow extends StatefulWidget {
  const _VideoWindow();
  @override
  State<_VideoWindow> createState() => _VideoWindowState();
}

class _VideoWindowState extends State<_VideoWindow> {
  VideoController? _controller;

  @override
  void initState() {
    super.initState();
    _log('initState');
    // 先在窗口里把自己画出来，再建播放器（上一版在 runApp 之前建，窗口根本不出现）。
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    try {
      _log('create player');
      final Player player = Player();
      final VideoController controller = VideoController(player);
      _log('player created; opening');
      await player.open(Media(kVideoUri), play: true);
      await player.setPlaylistMode(PlaylistMode.loop);
      _log('opened pos=${player.state.position.inMilliseconds}ms '
          'params=${player.state.width}x${player.state.height}');
      setState(() => _controller = controller);
      final DateTime t0 = DateTime.now();
      while (DateTime.now().difference(t0) < const Duration(seconds: 30)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (player.state.position > const Duration(milliseconds: 800)) break;
      }
      File(kReadyPath).writeAsStringSync(
        'ready pos=${player.state.position.inMilliseconds}ms '
        'rect=${controller.rect.value} id=${controller.id.value} '
        'params=${player.state.width}x${player.state.height}\n',
      );
      _log('ready written');
    } on Object catch (e) {
      _log('FAILED: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SizedBox(
          width: 480,
          height: 360,
          child: _controller == null
              ? const ColoredBox(color: Color(0xFF101010))
              : Video(controller: _controller!),
        ),
      ),
    );
  }
}
