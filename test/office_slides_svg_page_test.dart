// **自研 SVG 渲染器接入 `.oslides`** 的**页面层**用例。
//
// 夹具是**官方真样本** `test/fixtures/office_slides_o3/technology.oslides`：
//   * slide0 的形状 `pic-0-0` 就是版式继承来的 `ppt/media/image1.svg`，
//     `isVectorImage == true`，几何 604,112 @ 316x316（EMU/9525）；
//   * 这正是 WPS / Microsoft Office 会画、而我们此前"有意不画"的那个图形。
//
// ## 本文件锁住的不变量
// 1. 真样本 slide0 的 SVG **确实产出了自研绘制 widget**（明确的 Key），
//    且尺寸 == 形状逻辑尺寸 316x316（等比缩放由外层 `Transform.scale` 完成，
//    不影响布局尺寸）；
// 2. **接口层**断言的自研解析结果（144 个子路径）确实被送到了画笔上；
// 3. 缩略图路径**同样受益**（与主画布同一条 `_shapeContent`）；
// 4. ⭐ **反向确认**：把矢量换成不支持的 `.emf`、或换成畸形 SVG 时，
//    自研 SVG widget **不存在**，且整页空态照旧出现 —— 证明"能画才画，
//    画不出就退回不画"，而不是把所有矢量一律当成画得出来。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/features/office/office_slides_deck_view.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_svg_painter.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/office_slides_o3/$name').readAsBytesSync();

Widget _host(Widget child) => MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));

/// 构造一份"只有一张图片形状"的极小演示文稿（用于降级/反向确认）。
OSlidesDeck _pictureOnlyDeck({required String part, required Uint8List bytes}) {
  return OSlidesDeck(
    slides: <OSlidesDeckSlide>[
      OSlidesDeckSlide(
        order: 0,
        shapes: <OSlidesDeckShape>[
          OSlidesDeckShape(
            id: 'pic',
            kind: OSlidesShapeKind.picture,
            preset: 'rect',
            left: 100,
            top: 100,
            width: 316,
            height: 316,
            rotationDegrees: 0,
            geometryInherited: false,
            imagePart: part,
          ),
        ],
        backgroundArgb: 0xFFFFFFFF,
        backgroundInherited: false,
        notes: '',
        placeholderCount: 0,
        inheritedGeometryCount: 0,
        degradations: const <String>[],
      ),
    ],
    widthPx: 960,
    heightPx: 540,
    widthEmu: 9144000,
    heightEmu: 5143500,
    layoutCount: 0,
    masterCount: 0,
    media: <String, Uint8List>{part: bytes},
    unrenderableVectorCount: 0,
    unsupportedObjectCount: 0,
    degradations: const <String>[],
  );
}

void main() {
  late OSlidesDeck deck;
  late Uint8List svgBytes;

  setUpAll(() {
    deck = OSlidesDeck.parse(_fixture('technology.oslides'))!;
    svgBytes = deck.media['ppt/media/image1.svg']!;
  });

  group('官方真样本：slide0 的 SVG 被自研渲染器画出来', () {
    test('前置事实：slide0 z=0 就是 image1.svg（316x316）', () {
      final shape = deck.slides[0].shapes[0];
      expect(shape.kind, OSlidesShapeKind.picture);
      expect(shape.imagePart, 'ppt/media/image1.svg');
      expect(shape.isVectorImage, isTrue);
      expect(shape.width, closeTo(316, 0.01));
      expect(shape.height, closeTo(316, 0.01));
    });

    testWidgets('★ 主画布出现自研 SVG widget，尺寸 == 316x316', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: deck)));
      await tester.pump();
      final svg = find.byKey(const Key('office-slides-svg-0-0'));
      expect(svg, findsOneWidget);
      expect(tester.getSize(svg), const Size(316, 316));
      // 它确实是自研画笔，而不是别的东西。
      final paint = tester.widget<CustomPaint>(
        find.descendant(of: svg, matching: find.byType(CustomPaint)),
      );
      final painter = paint.painter;
      expect(painter, isA<OfficeSvgPainter>());
      expect((painter! as OfficeSvgPainter).document.subPathCount, 144);
    });

    testWidgets('缩略图路径同样受益（thumb-svg-0-0 存在）', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: deck)));
      await tester.pump();
      expect(
        find.byKey(const Key('office-slides-thumb-svg-0-0')),
        findsOneWidget,
      );
    });

    testWidgets('SVG 已画出来 → 不出现整页空态', (tester) async {
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: deck)));
      await tester.pump();
      expect(find.byKey(const Key('office-slides-blank-0')), findsNothing);
    });
  });

  group('反向确认：画不出时仍然"退回不画"、不崩不假画', () {
    // ⭐ 这两条是**旧行为的复现**：旧的 `_picture` 对 `isVectorImage` 一律返回
    // `SizedBox.shrink()`，旧的 `_blankAfterRender` 也一律把矢量当成"画不出来"。
    // 因此若有人把接入改回去，下面"存在自研 widget / 不存在空态"的正向断言会失败；
    // 而这里的降级断言会继续成立 —— 两边一起，锁住"能画才画"。

    testWidgets('★ SVG-only 页面：自研 widget 存在，且**不出现空态**（旧行为会出空态）', (
      tester,
    ) async {
      final only = _pictureOnlyDeck(
        part: 'ppt/media/image1.svg',
        bytes: svgBytes,
      );
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: only)));
      await tester.pump();
      expect(find.byKey(const Key('office-slides-svg-0-0')), findsOneWidget);
      expect(find.byKey(const Key('office-slides-blank-0')), findsNothing);
    });

    testWidgets('不支持的矢量（.emf）：不产出自研 widget，照旧出整页空态', (tester) async {
      final only = _pictureOnlyDeck(
        part: 'ppt/media/image1.emf',
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: only)));
      await tester.pump();
      expect(find.byKey(const Key('office-slides-svg-0-0')), findsNothing);
      expect(find.byKey(const Key('office-slides-blank-0')), findsOneWidget);
    });

    testWidgets('畸形 SVG：不产出自研 widget，照旧出整页空态（绝不崩）', (tester) async {
      final only = _pictureOnlyDeck(
        part: 'ppt/media/broken.svg',
        bytes: Uint8List.fromList(utf8.encode('<svg><g><path d="M0 0 ')),
      );
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: only)));
      await tester.pump();
      expect(find.byKey(const Key('office-slides-svg-0-0')), findsNothing);
      expect(find.byKey(const Key('office-slides-blank-0')), findsOneWidget);
    });

    testWidgets('空 SVG（只有 title）：不产出自研 widget，照旧出整页空态', (tester) async {
      final only = _pictureOnlyDeck(
        part: 'ppt/media/empty.svg',
        bytes: Uint8List.fromList(
          utf8.encode('<svg viewBox="0 0 10 10"><title>t</title></svg>'),
        ),
      );
      await tester.pumpWidget(_host(OfficeSlidesDeckView(deck: only)));
      await tester.pump();
      expect(find.byKey(const Key('office-slides-svg-0-0')), findsNothing);
      expect(find.byKey(const Key('office-slides-blank-0')), findsOneWidget);
    });
  });
}
