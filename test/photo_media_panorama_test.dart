// P14 · 360 全景 —— 接口层 + 页面层离线用例。
//
// 断言的是**具体行为**，不是"控件存在"：
//   * 视角数学：中心光线 → 纹理中心；拖动 → **视角矩阵**变化且方向正确；
//   * 真渲染：同一张等距柱状图，**不同视角渲染出的像素真的不同**，
//     而同一视角两次渲染逐字节相同（证明差异来自视角、不是噪声）；
//   * 页面层：拖动 → 控制器矩阵变化 + 提示收起 + 复位能回去；
//   * 全景视频：按**平面**播放且出现明确说明条（如实降级，不假装球面）。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_media_kinds.dart';
import 'package:synhub/src/features/photos/photo_panorama_math.dart';
import 'package:synhub/src/features/photos/photo_panorama_view.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';
import 'package:synhub/src/core/media/zoom_stage.dart' show ZoomStage;

import 'package:synhub/src/core/theme/app_theme.dart';
import 'photo_media_harness.dart';

void main() {
  group('① 类型识别（服务端 type 字符串 → FotoMediaKind）', () {
    test('360 的两种条目类型都认出来（官方 ImageType: photo360 / video360）', () {
      expect(FotoMediaKind.fromWire('photo360'), FotoMediaKind.photo360);
      expect(FotoMediaKind.fromWire('video360'), FotoMediaKind.video360);
      expect(FotoMediaKind.fromWire('panorama'), FotoMediaKind.panorama);
      // 大小写/空格容错（服务端字段理论上小写，但归类不该因为空白翻车）
      expect(FotoMediaKind.fromWire(' PHOTO360 '), FotoMediaKind.photo360);
    });

    test('video360 也是**视频**（官方 isVideo() = VIDEO || VIDEO360）', () {
      expect(FotoMediaKind.fromWire('video').isVideo, isTrue);
      expect(FotoMediaKind.fromWire('video360').isVideo, isTrue);
      expect(FotoMediaKind.fromWire('photo360').isVideo, isFalse);
    });

    test('360 判定只认 photo360/video360（官方 is360 不含 panorama）', () {
      expect(FotoMediaKind.fromWire('photo360').is360, isTrue);
      expect(FotoMediaKind.fromWire('video360').is360, isTrue);
      expect(FotoMediaKind.fromWire('photo').is360, isFalse);
      // 旧口径 `panorama` 可作全景渲染，但不进官方 is360
      expect(FotoMediaKind.fromWire('panorama').is360, isFalse);
      expect(FotoMediaKind.fromWire('panorama').isPanoramaPhoto, isTrue);
    });

    test('"360" 是**相册键**不是条目类型（真机实测 list/count 全版本拒收它）', () {
      expect(kFotoPanoramaAlbumTypeKey, '360');
      // 条目类型解析里，"360" 认不出来 → 回落 unknown（当普通照片，不隐藏）
      expect(FotoMediaKind.fromWire('360'), FotoMediaKind.unknown);
      expect(FotoMediaKind.fromWire('360').is360, isFalse);
      expect(FotoMediaKind.unknown.isStillImage, isTrue);
    });

    test(
      'DTO 侧：photo360 → isPanoramaPhoto；video360 → isVideo 且 isPanoramaVideo',
      () {
        final photo = FotoItemDto.fromJson(
          photoMediaItem('1', type: 'photo360', filename: 'PANO_1.jpg'),
        );
        expect(photo.isPanoramaPhoto, isTrue);
        expect(photo.isVideo, isFalse);

        final video = FotoItemDto.fromJson(
          photoMediaItem('2', type: 'video360', filename: 'PANO_1.mp4'),
        );
        expect(video.isVideo, isTrue);
        expect(video.isPanoramaVideo, isTrue);
        expect(video.isPanoramaPhoto, isFalse);
      },
    );
  });

  group('② 视角数学（纯 Dart）', () {
    test('默认视角：屏幕正中 → 纹理正中 (0.5, 0.5)', () {
      final c = PanoramaViewController();
      final uv = c.equirectAt(100, 50, const math.Point<double>(200, 100));
      expect(uv.u, closeTo(0.5, 1e-9));
      expect(uv.v, closeTo(0.5, 1e-9));
    });

    test('射线 → 纹理：+Z 正中、+X 是 u=0.75、+Y 是天顶 v=0', () {
      final c = PanoramaViewController();
      final center = c.rayToEquirect(0, 0, 1);
      expect(center.u, closeTo(0.5, 1e-9));
      expect(center.v, closeTo(0.5, 1e-9));

      // λ = atan2(1, 0) = π/2 → u = (π/2)/(2π) + 0.5 = 0.75
      final east = c.rayToEquirect(1, 0, 0);
      expect(east.u, closeTo(0.75, 1e-9));
      expect(east.v, closeTo(0.5, 1e-9));

      // φ = asin(1) = π/2 → v = 0.5 - 0.5 = 0（天顶）
      final up = c.rayToEquirect(0, 1, 0);
      expect(up.v, closeTo(0.0, 1e-9));
    });

    test('拖动改变**视角矩阵**，且水平拖动只动 yaw 分量', () {
      final c = PanoramaViewController();
      final before = c.rotationMatrix;
      c.dragBy(-100, 0);
      final after = c.rotationMatrix;
      expect(after, isNot(equals(before)));
      // R 的第 2 行是 [0, cos(pitch), -sin(pitch)]：pitch 没动 → 逐字不变
      expect(after.sublist(3, 6), equals(before.sublist(3, 6)));
      // 向左拖（dx<0）→ yaw 增大（画面左移 = 视角右转）
      expect(c.yaw, greaterThan(0));
      expect(closeToZero(c.pitch), isTrue);
    });

    test('垂直拖动只动 pitch 分量，且钳制在 ±(π/2-ε)（不许翻过头）', () {
      final c = PanoramaViewController();
      c.dragBy(0, 100000);
      expect(c.pitch, closeTo(kPanoramaMaxPitch, 1e-9));
      expect(c.pitch, lessThan(3.141592653589793 / 2));
      c.dragBy(0, -100000);
      expect(c.pitch, closeTo(-kPanoramaMaxPitch, 1e-9));
    });

    test('经度归一化到 (-π, π]：拖很多圈不会无限增长', () {
      final c = PanoramaViewController();
      for (var i = 0; i < 200; i++) {
        c.dragBy(-500, 0);
      }
      expect(c.yaw, greaterThan(-3.141592653589793));
      expect(c.yaw, lessThanOrEqualTo(3.141592653589793));
    });

    test('缩放：张开手指视场变小，且有上下限；复位回默认', () {
      final c = PanoramaViewController();
      c.zoomBy(2);
      expect(c.fov, closeTo(kPanoramaDefaultFov / 2, 1e-9));
      c.zoomBy(0.25);
      expect(c.fov, closeTo(kPanoramaMaxFov, 1e-9));
      c.zoomBy(1000);
      expect(c.fov, closeTo(kPanoramaMinFov, 1e-9));
      c.reset();
      expect(c.fov, closeTo(kPanoramaDefaultFov, 1e-9));
      expect(c.yaw, 0);
      expect(c.pitch, 0);
    });

    test('非法尺寸 / 非法方向不抛异常（绘制期间的异常会让整帧黑掉）', () {
      final c = PanoramaViewController();
      expect(c.equirectAt(10, 10, const math.Point<double>(0, 0)).u, 0.5);
      expect(
        c.equirectAt(10, 10, const math.Point<double>(double.nan, 10)).u,
        0.5,
      );
      expect(c.rayToEquirect(0, 0, 0).u, 0.5);
    });
  });

  group('③ 真·球面重投影（像素级）', () {
    testWidgets('不同视角渲染出的像素**真的不同**；同视角两次逐字节相同', (tester) async {
      final pixels = await tester.runAsync(() async {
        final bytes = equirectProbePngBytes;
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final image = frame.image;
        Future<Uint8List> render(PanoramaViewController c) async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          PanoramaMeshPainter(
            image: image,
            controller: c,
          ).paint(canvas, const Size(200, 120));
          final rendered = await recorder.endRecording().toImage(200, 120);
          final data = await rendered.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          rendered.dispose();
          return data!.buffer.asUint8List();
        }

        final base = PanoramaViewController();
        final first = await render(base);
        // 同一视角、**另一份等价控制器** → 必须逐字节相同
        final repeat = await render(PanoramaViewController());
        // 换视角（水平转 120px）→ 必须不同
        final turned = PanoramaViewController()..dragBy(-120, 0);
        final second = await render(turned);
        // 换俯仰 → 也必须不同
        final tilted = PanoramaViewController()..dragBy(0, 90);
        final third = await render(tilted);
        image.dispose();
        return (first: first, repeat: repeat, second: second, third: third);
      });
      expect(pixels, isNotNull);
      expect(pixels!.first, isNotEmpty);
      // ① 同视角可复现（差异不是随机噪声）
      expect(pixels.repeat, equals(pixels.first));
      // ② 拖动视角 → 画面真的变了（这才叫"球面重投影"，不是拉伸平面图）
      expect(pixels.second, isNot(equals(pixels.first)));
      // ③ 俯仰变化同样作用于渲染
      expect(pixels.third, isNot(equals(pixels.first)));
    });
  });

  group('④ 页面层：拖动改视角 / 提示收起 / 复位', () {
    testWidgets('拖动 → 控制器矩阵变化、回调收到新角度、提示条收起', (tester) async {
      final controller = PanoramaViewController();
      PanoramaViewAngles? seen;
      // 用 `tester.runAsync` 解图后**注入**：widget test 的 FakeAsync 区里
      // `decodeImageFromList` 这类引擎真异步永远不会完成（本批踩过，见 harness 注释）。
      final image = await decodeProbeImage(tester);
      addTearDown(image.dispose);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: PanoramaView(
              image: image,
              controller: controller,
              onAnglesChanged: (a) => seen = a,
            ),
          ),
        ),
      );
      await settlePhotoMedia(tester);
      expect(find.byKey(const Key('photo-pano-canvas')), findsOne);
      expect(find.byKey(const Key('photo-pano-hint')), findsOne);
      final before = controller.rotationMatrix;

      await tester.drag(
        find.byKey(const Key('photo-pano-gesture')),
        const Offset(-120, 0),
      );
      await settlePhotoMedia(tester);

      expect(controller.rotationMatrix, isNot(equals(before)));
      expect(seen, isNotNull);
      expect(seen!.yaw, isNot(0));
      // 拖过之后提示收起（拖动即开始浏览）
      expect(find.byKey(const Key('photo-pano-hint')), findsNothing);
    });

    testWidgets('复位按钮 → 视角回到初始值，并通知外部', (tester) async {
      final controller = PanoramaViewController()..dragBy(-200, 60);
      var resetCalled = 0;
      final image = await decodeProbeImage(tester);
      addTearDown(image.dispose);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: PanoramaView(
              image: image,
              controller: controller,
              onReset: () => resetCalled++,
            ),
          ),
        ),
      );
      await settlePhotoMedia(tester);
      expect(controller.yaw, isNot(0));
      await tester.tap(find.byKey(const Key('photo-pano-reset')));
      await settlePhotoMedia(tester);
      expect(controller.yaw, 0);
      expect(controller.pitch, 0);
      expect(resetCalled, 1);
    });

    testWidgets('解不出来的字节 → 明确失败层（不是黑屏、不是假动画）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: PanoramaView(bytes: Uint8List.fromList(const [1, 2, 3, 4])),
          ),
        ),
      );
      await settlePhotoMedia(tester);
      expect(find.byKey(const Key('photo-pano-error')), findsOne);
      expect(find.byKey(const Key('photo-pano-canvas')), findsNothing);
    });
  });

  group('⑤ 查看器接线：photo360 走球面；video360 按平面 + 明确说明', () {
    testWidgets('① photo360 → 走 PanoramaView，**不**走普通大图的 ZoomStage', (
      tester,
    ) async {
      final items = photoMediaItems([
        photoMediaItem('1', type: 'photo360', filename: 'PANO_1.jpg'),
        photoMediaItem('2', type: 'photo', filename: 'IMG_2.jpg'),
      ]);
      await pumpPhotoMedia(tester, PhotoViewerPage(items: items));
      // 360 分支被选中：PanoramaView 在，普通大图的仿射缩放舞台不在。
      // （球面重投影**真的渲染**由 ③ 的像素级用例证明；这里证明的是接线选对了分支。）
      expect(find.byKey(const Key('photo-pano-1')), findsOne);
      expect(find.byType(ZoomStage), findsNothing);
      // 视图内部此时在解码（widget test 里引擎真异步不完成）→ 至少不是失败层
      expect(find.byKey(const Key('photo-pano-error')), findsNothing);
    });

    testWidgets('② video360 → 当视频处理（有播放入口），并出现"不支持球面"说明条', (tester) async {
      final items = photoMediaItems([
        photoMediaItem('2', type: 'video360', filename: 'PANO_2.mp4'),
      ]);
      await pumpPhotoMedia(tester, PhotoViewerPage(items: items));
      expect(find.byKey(const Key('photo-pano-video-notice')), findsOne);
      // 被当成视频 → 画质入口出现（静图不会有）
      expect(find.byKey(const Key('photo-video-quality')), findsOne);
    });

    testWidgets('③ 普通 photo / video 不出现全景相关控件（不误伤）', (tester) async {
      final items = photoMediaItems([
        photoMediaItem('3', type: 'photo', filename: 'IMG_3.jpg'),
      ]);
      await pumpPhotoMedia(tester, PhotoViewerPage(items: items));
      expect(find.byKey(const Key('photo-pano-video-notice')), findsNothing);
      expect(find.byKey(const Key('photo-pano-canvas')), findsNothing);
      expect(find.byKey(const Key('photo-pano-3')), findsNothing);
    });
  });
}

/// `closeToZero` 的小工具（避免为一条断言引入 matcher 依赖）。
bool closeToZero(double v) => v.abs() < 1e-9;
