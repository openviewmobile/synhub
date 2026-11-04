// r707：Windows 抽帧后端（libmpv `screenshot-raw`）的宿主侧判据。
//
// 这组用例只钉**纯 Dart 的那两半**：
//  ① "本宿主有没有这个后端"（桌面两家 true，其余 false）；
//  ② "有原始截图的字节之后怎么收尾"（原样回 / 等比缩 / 坏字节回 null）。
// 真起 libmpv 的那一半只能在 Windows guest 里量（`docs/evidence-r707-win/`），
// 单测里**不**假装它跑过 —— 与 r703 视频出帧的"同进程自证 = 假绿"同一条纪律。
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/mpv_video_frame_extractor.dart';

/// 造一张**真图片**（宽 [w] 高 [h]，左半红右半蓝，PNG 字节）。
Future<Uint8List> _makeImage(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w / 2, h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(w / 2, 0, w / 2, h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF0000FF),
  );
  final image = await recorder.endRecording().toImage(w, h);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('hostSupported()', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('桌面两家 = true', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(MpvVideoFrameExtractor.hostSupported(), isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(MpvVideoFrameExtractor.hostSupported(), isTrue);
    });

    test('手机两家 = false（那边走各自原生后端）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(MpvVideoFrameExtractor.hostSupported(), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(MpvVideoFrameExtractor.hostSupported(), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(MpvVideoFrameExtractor.hostSupported(), isFalse);
    });
  });

  group('extract() 的收尾', () {
    test('截图给 null / 空 ⇒ null（不抛）', () async {
      final a = MpvVideoFrameExtractor(screenshot: (_, {required atMs}) async => null);
      expect(await a.extract('/tmp/x.mp4'), isNull);
      final b = MpvVideoFrameExtractor(
        screenshot: (_, {required atMs}) async => Uint8List(0),
      );
      expect(await b.extract('/tmp/x.mp4'), isNull);
    });

    test('坏字节 ⇒ null（解码失败也不许甩异常给 UI）', () async {
      final e = MpvVideoFrameExtractor(
        screenshot: (_, {required atMs}) async => Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(await e.extract('/tmp/x.mp4'), isNull);
    });

    test('宽度不超上限 ⇒ 原样回，尺寸如实', () async {
      final png = await _makeImage(40, 20);
      String? seenPath;
      int? seenAt;
      final e = MpvVideoFrameExtractor(
        maxWidth: 320,
        screenshot: (path, {required atMs}) async {
          seenPath = path;
          seenAt = atMs;
          return png;
        },
      );
      final r = await e.extract('/tmp/a.mp4', atMs: 1500);
      expect(r, isNotNull);
      expect(r!.mime, 'image/png');
      expect(r.width, 40);
      expect(r.height, 20);
      expect(r.bytes, same(png));
      expect(seenPath, '/tmp/a.mp4');
      expect(seenAt, 1500);
    });

    test('宽度超上限 ⇒ 等比缩到上限宽（高度按比例）', () async {
      final png = await _makeImage(640, 320);
      final e = MpvVideoFrameExtractor(
        screenshot: (_, {required atMs}) async => png,
      );
      final r = await e.extract('/tmp/a.mp4', maxWidth: 160);
      expect(r, isNotNull);
      expect(r!.width, 160);
      expect(r.height, 80);
      expect(r.mime, 'image/png');
      // 缩放后必须是**真图片**（不是原字节的切片）
      final codec = await ui.instantiateImageCodec(r.bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 160);
      expect(frame.image.height, 80);
      frame.image.dispose();
      codec.dispose();
    });

    test('atMs 负数按 0 传下去（不把负时间喂给 libmpv）', () async {
      int? seenAt;
      final e = MpvVideoFrameExtractor(
        screenshot: (_, {required atMs}) async {
          seenAt = atMs;
          return null;
        },
      );
      await e.extract('/tmp/a.mp4', atMs: -5);
      expect(seenAt, 0);
    });
  });
}
