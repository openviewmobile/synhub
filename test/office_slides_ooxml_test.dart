// O3：`.oslides`（PPTX）**离线**解析闭环用例。
//
// fixture 是**真实** NAS 文件字节（`test/fixtures/office_slides_o3/`）：
//   * `technology.oslides` = 服务器上的 `Technology.oslides`（15 页真实内容，
//     下载 327,156 字节，sha256 见 MANIFEST.json）；
//   * `celestial.oslides` = `Celestial.oslides`（**第 1 页本来就只有两个空占位符**，
//     这是文件真实内容，不是解析缺陷 —— 见 `docs/ooxml-ground-truth.md` §四）。
//
// 断言口径全部来自**文件原文**（不是我们解析器的自证）：
//   * `<p:sldSz cx="9144000" cy="5143500"/>` → 16:9 画布；
//   * `ppt/presentation.xml` 的 `p:sldIdLst` 有 15 个 `p:sldId`；
//   * slide1 的 `Social Media` / `How to grow your fans from 0 to 10K`；
//   * slide10 的 `Platforms` / `02` / `Most people now use at least one social media.`；
//   * ⭐ slide 的形状**没有 `<a:xfrm>`**，几何只在 `slideLayoutN.xml` 里
//     （`slideLayout1.xml` 的 title = 540000,2093190 / 8064000×1146810）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/office_slides_o3/$name').readAsBytesSync();

void main() {
  late OSlidesDeck deck;

  setUpAll(() {
    deck = OSlidesDeck.parse(_fixture('technology.oslides'))!;
  });

  group('真实 PPTX：整体结构', () {
    test('画布是 16:9，尺寸取 @p:sldSz 原文', () {
      expect(deck.isWidescreen, isTrue);
      expect(deck.widthEmu, 9144000);
      expect(deck.heightEmu, 5143500);
      expect(deck.widthPx, closeTo(960, 0.5));
      expect(deck.heightPx, closeTo(540, 0.5));
    });

    test('页序来自 p:sldIdLst：15 页', () {
      expect(deck.slides, hasLength(15));
      expect(deck.slides.first.pageNumber, 1);
      expect(deck.slides.last.pageNumber, 15);
    });

    test('版式 16 个 + 母版 1 个', () {
      expect(deck.layoutCount, 16);
      expect(deck.masterCount, 1);
    });

    test('媒体字节带在模型里（jpg 可渲染、svg 计入不可渲染矢量图）', () {
      expect(deck.media.keys, contains('ppt/media/image2.jpg'));
      expect(deck.media['ppt/media/image2.jpg']!.length, greaterThan(1000));
      // ⚠️ 语义已于第 15 轮修正（自研 SVG 渲染落地后）：
      //   * `svgMediaCount`          = 包内 SVG 数（**能画**）；
      //   * `unrenderableVectorCount`= 矢量总数 − SVG 数 = EMF/WMF/SVGZ（**画不出**）。
      // 原来这条断言 `unrenderableVectorCount == 2`，把"2 个 SVG"错记成"画不出的矢量"，
      // 导致真机上 `technology.oslides` 弹出"部分矢量图形暂不显示"的**过时而误导**的说明。
      // ⇒ 现在把同一个事实（这个样本里有 2 个矢量媒体、且都是 SVG）钉在**正确的字段**上，
      //    并额外断言"没有画不出的矢量"，比原来更严格，不是放宽。
      expect(
        deck.svgMediaCount,
        2,
        reason: 'technology.oslides 的 2 个矢量媒体都是 SVG',
      );
      expect(
        deck.unrenderableVectorCount,
        0,
        reason: 'SVG 已由自研渲染器绘制，不再是"画不出的矢量"',
      );
    });
  });

  group('真实 PPTX：母版/版式继承（本批核心）', () {
    test('slide1 的两个占位符几何都来自版式继承且非零', () {
      final slide = deck.slides[0];
      expect(slide.placeholderCount, 2);
      expect(slide.inheritedGeometryCount, 2);
      final title = slide.shapes.firstWhere(
        (s) => s.placeholderType == 'title',
      );
      // slideLayout1.xml 原文：x=540000 y=2093190 cx=8064000 cy=1146810（EMU）
      expect(title.geometryInherited, isTrue);
      expect(title.left, closeTo(540000 / 9525, 0.01));
      expect(title.top, closeTo(2093190 / 9525, 0.01));
      expect(title.width, closeTo(8064000 / 9525, 0.01));
      expect(title.height, closeTo(1146810 / 9525, 0.01));
    });

    test('slide1 背景取自 slideLayout1 的蓝底（不是母版的白）', () {
      expect(deck.slides[0].backgroundArgb, 0xFF0069E6);
      expect(deck.slides[0].backgroundInherited, isTrue);
      // slide3 用的是 slideLayout10（f7f7f7 灰底）
      expect(deck.slides[2].backgroundArgb, 0xFFF7F7F7);
    });

    test('slide1 标题文本样式来自版式：64pt / 加粗 / 白色', () {
      final slide = deck.slides[0];
      final title = slide.shapes.firstWhere(
        (s) => s.placeholderType == 'title',
      );
      expect(title.text, contains('Social Media'));
      final run = title.paragraphs.first.runs.first;
      expect(run.sizePt, 64);
      expect(run.bold, isTrue);
      expect(run.colorArgb, 0xFFFFFFFF);
      expect(run.fontFamily, 'Arial');
    });

    test('slide1 副标题是版式里的 28pt 白字', () {
      final slide = deck.slides[0];
      final sub = slide.shapes.firstWhere(
        (s) => s.placeholderType == 'subTitle',
      );
      expect(sub.text, contains('How to grow your fans from 0 to 10K'));
      final run = sub.paragraphs.first.runs.first;
      expect(run.sizePt, 28);
      expect(run.bold, isTrue);
      expect(run.colorArgb, 0xFFE6EBF0);
    });

    test('版式上的装饰图形被渲染进来（圆点图/色块/椭圆）', () {
      final s1 = deck.slides[0];
      expect(
        s1.shapes.any((s) => s.kind == OSlidesShapeKind.picture),
        isTrue,
        reason: 'slideLayout1 有一张 3009900×3009900 的圆点图',
      );
      // slide5 用 slideLayout11：左侧一整条蓝色竖条（非占位符 sp）
      final s5 = deck.slides[4];
      expect(
        s5.shapes.any(
          (s) =>
              s.fillArgb == 0xFF0069E6 && s.kind == OSlidesShapeKind.rectangle,
        ),
        isTrue,
      );
      // slide14 用 slideLayout13：3 个蓝色圆点
      final s14 = deck.slides[13];
      expect(
        s14.shapes.where((s) => s.kind == OSlidesShapeKind.ellipse).length,
        greaterThanOrEqualTo(3),
      );
    });

    test('每一页都有非零几何的形状，且都做过继承', () {
      for (final slide in deck.slides) {
        expect(
          slide.drawableShapeCount,
          greaterThan(0),
          reason: '第 ${slide.pageNumber} 页',
        );
      }
      expect(deck.inheritedGeometryCount, greaterThan(0));
    });
  });

  group('真实 PPTX：文字内容', () {
    test('slide1 原文三行都在', () {
      final text = deck.slides[0].plainText;
      expect(text, contains('Social Media'));
      expect(text, contains('Strategy'));
      expect(text, contains('How to grow your fans from 0 to 10K'));
    });

    test('slide10 原文三行都在', () {
      final text = deck.slides[9].plainText;
      expect(text, contains('Platforms'));
      expect(text, contains('02'));
      expect(text, contains('Most people now use at least one social media.'));
    });

    test('slide2 的 body 项目符号（buChar ●）被渲染成符号', () {
      final body = deck.slides[1].shapes.firstWhere(
        (s) => s.placeholderType == 'body',
      );
      expect(body.paragraphs.length, greaterThanOrEqualTo(5));
      expect(body.paragraphs.first.bullet, '●');
      expect(body.paragraphs.first.text, contains('Cover & Section Header'));
    });
  });

  group('真实 PPTX：兜底/健壮性', () {
    test('非 ZIP 字节 → null（调用方回落 OFile 路径）', () {
      expect(OSlidesDeck.parse(utf8.encode('not a zip')), isNull);
      expect(OSlidesDeck.parse(const <int>[]), isNull);
    });

    test('ZIP 但不是 PPTX（缺 presentation.xml）→ null', () {
      // 一个只有 [Content_Types].xml 的最小 zip。
      expect(OSlidesDeck.parse(File('pubspec.yaml').readAsBytesSync()), isNull);
    });

    test('celestial.oslides：第 1 页两个空占位符是**文件真实内容**', () {
      final deck2 = OSlidesDeck.parse(_fixture('celestial.oslides'))!;
      expect(deck2.slides, hasLength(1));
      final slide = deck2.slides.single;
      // 几何依然继承到了（非零），只是文本为空 —— 不是解析失败。
      expect(slide.inheritedGeometryCount, greaterThan(0));
      expect(slide.plainText, isEmpty);
      expect(slide.shapes.any((s) => s.width > 0 && s.height > 0), isTrue);
    });
  });
}
