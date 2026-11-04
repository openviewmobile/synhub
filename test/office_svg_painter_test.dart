// **自研 SVG 渲染器**（`office_svg_painter.dart`）的**接口层**用例。
//
// 两部分：
//   1. **官方真样本**（`test/fixtures/office_slides_o3/technology.oslides` 里的
//      `ppt/media/image1.svg` / `image3.svg`）——断言解析出的
//      `Path` 子路径数 / 命令数 / 继承样式，全部对齐文件原文；
//   2. **构造样本（非官方样本）**——补齐真样本没有的命令（`L H V Q A …`）、
//      基本形状、`transform`、`style` 内联样式、`preserveAspectRatio`，
//      以及**畸形/空/NaN/巨大 viewBox 不抛异常**的健壮性。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/features/office/office_svg_painter.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/office_slides_o3/$name').readAsBytesSync();

void main() {
  group('官方真样本：Technology.oslides 的 ppt/media/*.svg', () {
    late OSlidesDeck deck;

    setUpAll(() {
      deck = OSlidesDeck.parse(_fixture('technology.oslides'))!;
    });

    test('image1.svg：viewBox 316x316、1 个 path、144 个子路径 / 864 条命令', () {
      final bytes = deck.media['ppt/media/image1.svg'];
      expect(bytes, isNotNull);
      final doc = officeSvgDocumentFor(bytes!);
      expect(doc.isEmpty, isFalse);
      expect(doc.viewBox, const Rect.fromLTWH(0, 0, 316, 316));
      // 文件原文：1 个 <g> + 1 个 <path>；`M=144 C=576 Z=144`。
      expect(doc.shapes, hasLength(1));
      expect(doc.subPathCount, 144);
      expect(doc.commandCount, 864);
      final shape = doc.shapes.single;
      expect(shape.subPathCount, 144);
      expect(shape.commandCount, 864);
      // `<g fill-opacity="0.1">` + `<path fill="#000000">` ⇒ 黑色 10% 透明。
      expect(shape.fill, isNotNull);
      expect((shape.fill!.r * 255).round(), 0);
      expect((shape.fill!.g * 255).round(), 0);
      expect((shape.fill!.b * 255).round(), 0);
      expect(shape.fill!.a, closeTo(0.1, 0.002));
      // `<g fill-rule="evenodd">` ⇒ 奇偶填充。
      expect(shape.fillRule, PathFillType.evenOdd);
      // `<g stroke="none">` ⇒ 不描边。
      expect(shape.stroke, isNull);
    });

    test('image3.svg：fill #E6EBF0、无不透明度衰减、同样 144 个子路径', () {
      final bytes = deck.media['ppt/media/image3.svg'];
      expect(bytes, isNotNull);
      final doc = officeSvgDocumentFor(bytes!);
      expect(doc.shapes, hasLength(1));
      expect(doc.subPathCount, 144);
      expect(doc.commandCount, 864);
      final shape = doc.shapes.single;
      expect((shape.fill!.r * 255).round(), 0xE6);
      expect((shape.fill!.g * 255).round(), 0xEB);
      expect((shape.fill!.b * 255).round(), 0xF0);
      expect(shape.fill!.a, closeTo(1, 0.002));
      expect(shape.fillRule, PathFillType.evenOdd);
    });

    test('真样本经 officeSvgDocumentFor 走缓存且确实产出可绘制图形', () {
      final bytes = deck.media['ppt/media/image1.svg']!;
      final a = officeSvgDocumentFor(bytes);
      final b = officeSvgDocumentFor(bytes);
      expect(identical(a, b), isTrue);
      expect(a.isEmpty, isFalse);
    });
  });

  group('构造样本（非官方样本）：基本形状与命令覆盖', () {
    test('rect / circle / ellipse / line / polygon / polyline 各产出 1 个图形', () {
      const svg = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <rect x="0" y="0" width="10" height="10" fill="#ff0000"/>
  <circle cx="50" cy="50" r="5" fill="#00ff00"/>
  <ellipse cx="20" cy="20" rx="4" ry="6" fill="#abcdef"/>
  <line x1="0" y1="0" x2="10" y2="10" stroke="#0000ff" stroke-width="2"/>
  <polygon points="0,0 10,0 10,10" fill="#123456"/>
  <polyline points="0,0 5,5 10,0" fill="none" stroke="#654321"/>
</svg>''';
      final doc = OfficeSvgDocument.parse(svg);
      expect(doc.shapeCount, 6);
      expect(doc.subPathCount, 6);
      // line = M + L(2)；polygon = M + 2L + Z(4)；polyline = M + 2L(3)；
      // rect / circle / ellipse 各 1。
      expect(doc.commandCount, 1 + 1 + 1 + 2 + 4 + 3);
    });

    test('圆角 rect（rx/ry）不抛异常且仍是一个图形', () {
      const svg =
          '<svg viewBox="0 0 10 10"><rect width="10" height="10" rx="2" ry="3" fill="#000"/></svg>';
      final doc = OfficeSvgDocument.parse(svg);
      expect(doc.shapeCount, 1);
    });

    test('path：M L H V C S Q T A Z 全部命令都被接受（构造样本，非官方样本）', () {
      const svg =
          '<svg viewBox="0 0 100 100">'
          '<path d="M0 0 L10 0 H20 V20 C21 21 22 22 23 23 S24 24 25 25 '
          'Q26 26 27 27 T28 28 A5 5 0 0 1 35 35 Z" fill="#000000"/></svg>';
      final doc = OfficeSvgDocument.parse(svg);
      expect(doc.shapeCount, 1);
      final shape = doc.shapes.single;
      expect(shape.subPathCount, 1);
      // M L H V C S Q T A Z = 10 条命令。
      expect(shape.commandCount, 10);
    });

    test('相对命令与隐式重复参数（m/l/c/z）被接受', () {
      const svg =
          '<svg viewBox="0 0 10 10"><path d="m0 0 1 1 2 2 3 3z" fill="#000"/></svg>';
      final doc = OfficeSvgDocument.parse(svg);
      expect(doc.shapeCount, 1);
      // m + 三个隐式 l + z = 5。
      expect(doc.shapes.single.commandCount, 5);
    });

    test('title 被忽略，不产生图形', () {
      const svg =
          '<svg viewBox="0 0 10 10">'
          '<title>Combined Shape</title><desc>x</desc>'
          '<rect width="10" height="10" fill="#000"/></svg>';
      final doc = OfficeSvgDocument.parse(svg);
      expect(doc.shapeCount, 1);
    });

    test('<g> 的 fill/stroke/stroke-width/fill-rule/transform 被子元素继承', () {
      const svg =
          '<svg viewBox="0 0 100 100">'
          '<g fill="#112233" stroke="#445566" stroke-width="3" '
          'fill-rule="evenodd" transform="translate(1,2) scale(2)">'
          '<rect x="0" y="0" width="5" height="5"/></g></svg>';
      final doc = OfficeSvgDocument.parse(svg);
      final shape = doc.shapes.single;
      expect((shape.fill!.r * 255).round(), 0x11);
      expect((shape.stroke!.r * 255).round(), 0x44);
      expect(shape.strokeWidth, 3);
      expect(shape.fillRule, PathFillType.evenOdd);
      // transform 已解析（非恒等）。
      expect(shape.transform.isIdentity, isFalse);
    });

    test('内联 style 覆盖同名呈现属性（CSS 优先级）', () {
      const svg =
          '<svg viewBox="0 0 10 10">'
          '<rect width="10" height="10" fill="#ff0000" style="fill:#00ff00"/></svg>';
      final doc = OfficeSvgDocument.parse(svg);
      final shape = doc.shapes.single;
      expect((shape.fill!.g * 255).round(), 0xFF);
      expect((shape.fill!.r * 255).round(), 0x00);
    });

    test('fill="none" 且无描边 → 不产生图形（不是空白，是不占位）', () {
      const svg =
          '<svg viewBox="0 0 10 10"><rect width="10" height="10" fill="none"/></svg>';
      final doc = OfficeSvgDocument.parse(svg);
      expect(doc.isEmpty, isTrue);
    });
  });

  group('构造样本（非官方样本）：降级与健壮性（绝不抛异常）', () {
    test('空串 / 纯空白 → empty', () {
      expect(OfficeSvgDocument.parse('').isEmpty, isTrue);
      expect(OfficeSvgDocument.parse('   \n  ').isEmpty, isTrue);
    });

    test('畸形 XML（未闭合标签）→ empty，不抛异常', () {
      expect(OfficeSvgDocument.parse('<svg').isEmpty, isTrue);
      expect(
        OfficeSvgDocument.parse('<svg><g><path d="M0 0 L1 1"/></svg>').isEmpty,
        isTrue,
      );
      expect(OfficeSvgDocument.parse('not xml at all').isEmpty, isTrue);
    });

    test('根节点不是 svg 但内嵌 svg → 仍能解析', () {
      const svg =
          '<root><svg viewBox="0 0 10 10"><rect width="10" height="10" fill="#000"/></svg></root>';
      expect(OfficeSvgDocument.parse(svg).shapeCount, 1);
    });

    test('NaN / Infinity 坐标 → 不抛异常（parse 失败的部分被丢弃）', () {
      expect(
        OfficeSvgDocument.parse(
          '<svg viewBox="0 0 10 10"><path d="M NaN NaN L 5 5" fill="#000"/></svg>',
        ).isEmpty,
        isTrue,
      );
      expect(
        OfficeSvgDocument.parse(
          '<svg viewBox="0 0 10 10"><path d="M0 0 L1e999 1e999" fill="#000"/></svg>',
        ).isEmpty,
        isTrue,
      );
      expect(
        OfficeSvgDocument.parse(
          '<svg viewBox="0 0 10 10"><rect width="NaN" height="5" fill="#000"/></svg>',
        ).isEmpty,
        isTrue,
      );
    });

    test('巨大 viewBox（1e9）不抛异常且正常产出图形', () {
      final doc = OfficeSvgDocument.parse(
        '<svg viewBox="0 0 1000000000 1000000000">'
        '<path d="M0 0 L10 10" fill="#000"/></svg>',
      );
      expect(doc.shapeCount, 1);
      expect(doc.viewBox.width, 1e9);
    });

    test('未知标签/属性 → 跳过，已知图形仍被解析', () {
      const svg =
          '<svg viewBox="0 0 10 10">'
          '<foo bar="1"><baz/></foo>'
          '<rect width="10" height="10" fill="#000" data-x="1"/></svg>';
      final doc = OfficeSvgDocument.parse(svg);
      expect(doc.shapeCount, 1);
    });

    test('未知 fill 颜色 / 渐变 url() 退化为可见（不空白）', () {
      final a = OfficeSvgDocument.parse(
        '<svg viewBox="0 0 10 10"><rect width="10" height="10" fill="url(#g)"/></svg>',
      );
      expect(a.shapeCount, 1);
      expect(a.shapes.single.fill, isNotNull);
      final b = OfficeSvgDocument.parse(
        '<svg viewBox="0 0 10 10"><rect width="10" height="10" fill="notacolor"/></svg>',
      );
      expect(b.shapeCount, 1);
    });

    test('缺失/零尺寸 viewBox → 仍可按原始坐标绘制', () {
      final doc = OfficeSvgDocument.parse(
        '<svg><rect width="10" height="10" fill="#000"/></svg>',
      );
      expect(doc.shapeCount, 1);
      expect(doc.viewBox, Rect.zero);
    });

    test('preserveAspectRatio="none" 与 align 变体不抛异常', () {
      for (final par in const [
        'none',
        'xMinYMin meet',
        'xMaxYMax slice',
        'xMidYMid meet',
      ]) {
        final doc = OfficeSvgDocument.parse(
          '<svg viewBox="0 0 10 10" preserveAspectRatio="$par">'
          '<rect width="10" height="10" fill="#000"/></svg>',
        );
        expect(doc.shapeCount, 1, reason: par);
      }
    });

    test('畸形 d（半截命令）→ 保留已解析的绘制命令，不抛异常', () {
      // `M0 0 L5 5` 已完整绘制，尾部的 `L`（缺参数）被安全丢弃。
      final doc = OfficeSvgDocument.parse(
        '<svg viewBox="0 0 10 10"><path d="M0 0 L5 5 L" fill="#000"/></svg>',
      );
      expect(doc.shapeCount, 1);
      expect(doc.shapes.single.subPathCount, 1);
      expect(doc.shapes.single.commandCount, 2);
    });

    test('只有 M / Z（画不出像素）→ 视为无可绘制内容', () {
      expect(
        OfficeSvgDocument.parse(
          '<svg viewBox="0 0 10 10"><path d="M0 0 Z" fill="#000"/></svg>',
        ).isEmpty,
        isTrue,
      );
      expect(
        OfficeSvgDocument.parse(
          '<svg viewBox="0 0 10 10"><path d="M0 0" fill="#000"/></svg>',
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('绘制层：几何真实存在（不是"解析了但画成空白"）', () {
    // 说明：本环境 `Picture.toImage` 会挂起（无可用 GPU/光栅化后端），
    // 因此这里改用**不依赖 GPU 的强证据**：Path 子路径度量 + 包围盒。
    // 空白 SVG 不可能有 144 条**非零长度**的子路径，也不可能铺满 316x316。
    test('image1.svg 的 Path 含 144 条非退化子路径且铺满 316x316', () {
      final deck = OSlidesDeck.parse(_fixture('technology.oslides'))!;
      final doc = officeSvgDocumentFor(deck.media['ppt/media/image1.svg']!);
      final shape = doc.shapes.single;
      final metrics = shape.path.computeMetrics().toList();
      expect(metrics, hasLength(144));
      var total = 0.0;
      for (final m in metrics) {
        expect(m.length, greaterThan(0), reason: '每个小圆点都必须有真实周长');
        total += m.length;
      }
      expect(total, greaterThan(1000));
      final bounds = shape.path.getBounds();
      expect(bounds.width, greaterThan(0));
      expect(bounds.height, greaterThan(0));
      expect(bounds.left, closeTo(0, 1));
      expect(bounds.top, closeTo(0, 1));
      expect(bounds.right, closeTo(316, 1));
      expect(bounds.bottom, closeTo(316, 1));
    });

    test('绘制 316x316（含 preserveAspectRatio 变体）不抛异常', () {
      final deck = OSlidesDeck.parse(_fixture('technology.oslides'))!;
      final doc = officeSvgDocumentFor(deck.media['ppt/media/image1.svg']!);
      for (final size in const [Size(316, 316), Size(100, 200), Size(1, 1)]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        OfficeSvgPainter(doc).paint(canvas, size);
        recorder.endRecording().dispose();
      }
    });

    test('空文档绘制不抛异常', () {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      OfficeSvgPainter(
        OfficeSvgDocument.empty,
      ).paint(canvas, const Size(10, 10));
      recorder.endRecording().dispose();
    });
  });
}
