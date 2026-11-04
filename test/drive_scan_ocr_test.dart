// ★★ ③Drive 第 232 轮 **D37 版面层（文字行/词块切分）+ 识别层接口** 用例。
//
// 关键不是"切得像"，而是：
//   * 合成图上**行数/顺序/坐标**可精确断言；
//   * 空页、纯噪声不产生假行；
//   * **内置引擎必须如实说"没识别"**（`recognized=false` 且 `text` 全空）——
//     编造识别结果是本轮最不能犯的错，所以专门有一条用例把它钉死。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:synhub/src/features/drive/drive_scan_ocr.dart';

img.Image _blank(int w, int h) => img.Image(width: w, height: h)
  ..clear(img.ColorRgb8(255, 255, 255));

void _bar(img.Image im, int x0, int y0, int x1, int y1) {
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      im.setPixel(x, y, img.ColorRgb8(0, 0, 0));
    }
  }
}

/// 一行"文字"：三个词块 + 词间空格
void _textLine(img.Image im, int y0, int height, int width) {
  var x = 10;
  for (var i = 0; i < 3; i++) {
    _bar(im, x, y0, x + 20, y0 + height - 1);
    x += 20 + 8; // 词间 8px 空隙
  }
}

void main() {
  group('D37 版面层 · 行切分', () {
    test('三行文字 ⇒ 三行，自上而下编号；坐标归一化且在 0~1', () {
      final im = _blank(200, 300);
      _textLine(im, 30, 20, 200);
      _textLine(im, 120, 20, 200);
      _textLine(im, 210, 20, 200);
      final layout = segmentScanTextLines(im);
      expect(layout.lines, hasLength(3));
      expect(layout.lines.map((l) => l.order), [0, 1, 2]);
      final tops = layout.lines.map((l) => l.top).toList();
      expect(tops, orderedEquals([...tops]..sort()));
      for (final l in layout.lines) {
        expect(l.left, inInclusiveRange(0, 1));
        expect(l.top, inInclusiveRange(0, 1));
        expect(l.right, inInclusiveRange(0, 1));
        expect(l.bottom, inInclusiveRange(0, 1));
        expect(l.right, greaterThan(l.left));
        expect(l.bottom, greaterThan(l.top));
      }
      // 第一行大约在 y=30/300 到 50/300
      expect(layout.lines.first.top, closeTo(0.10, 0.03));
      expect(layout.lines.first.bottom, closeTo(0.17, 0.03));
    });

    test('空白页 ⇒ 零行（不无中生有）', () {
      final layout = segmentScanTextLines(_blank(200, 200));
      expect(layout.lines, isEmpty);
    });

    test('零星噪点 ⇒ 被最小行高过滤掉，不算文字行', () {
      final im = _blank(200, 200);
      _bar(im, 100, 100, 102, 101); // 2px 高
      final layout = segmentScanTextLines(im, minLineHeightRatio: 0.02);
      expect(layout.lines, isEmpty);
    });

    test('行内切词块：三块 + 两个 8px 空隙 ⇒ 3 个词块', () {
      final im = _blank(200, 120);
      _textLine(im, 40, 20, 200);
      final layout = segmentScanTextLines(im);
      expect(layout.lines, hasLength(1));
      expect(layout.lines.single.words, hasLength(3));
      final ws = layout.lines.single.words;
      for (var i = 1; i < ws.length; i++) {
        expect(
          ws[i].left,
          greaterThan(ws[i - 1].right),
          reason: '词块必须按 x 递增且不重叠',
        );
      }
    });

    test('一行很长的连续黑带 ⇒ 只有 1 个词块（不硬切）', () {
      final im = _blank(200, 120);
      _bar(im, 10, 40, 190, 59);
      final layout = segmentScanTextLines(im);
      expect(layout.lines, hasLength(1));
      expect(layout.lines.single.words, hasLength(1));
    });

    test('行带内 1 像素断点不会被劈成两行（扫描噪声）', () {
      final im = _blank(200, 120);
      _bar(im, 10, 40, 190, 58);
      // 第 50 行抽掉一个像素宽的行（模拟噪声断点）
      for (var x = 10; x <= 190; x++) {
        im.setPixel(x, 50, img.ColorRgb8(255, 255, 255));
      }
      final layout = segmentScanTextLines(im);
      expect(layout.lines, hasLength(1), reason: '1px 断点不该断行');
    });

    test('版面可序列化（搜索结果/文字层要用 JSON）', () {
      final im = _blank(200, 120);
      _textLine(im, 40, 20, 200);
      final j = segmentScanTextLines(im).toJson();
      expect(j['width'], 200);
      expect(j['height'], 120);
      final lines = j['lines'] as List;
      expect(lines, hasLength(1));
      expect((lines.first as Map)['words'], hasLength(3));
    });
  });

  group('D37 识别层 · 诚实边界', () {
    test('内置引擎：recognized=false、text 全空 —— **绝不编造识别结果**', () async {
      final im = _blank(200, 120);
      _textLine(im, 40, 20, 200);
      final r = await const ScanLayoutOnlyEngine().recognize(im);
      expect(r.engineId, 'layout-only');
      expect(r.recognized, isFalse);
      expect(r.text, hasLength(r.layout.lines.length));
      expect(
        r.text.every((t) => t.isEmpty),
        isTrue,
        reason: '没识别就必须是空串；写任何字符都是编造',
      );
      expect(scanSearchableText(r), isEmpty);
      expect(r.toJson()['recognized'], isFalse);
    });

    test('接口可插拔：假引擎能填文字，上层不改（将来接 MLKit/自研模型）', () async {
      final r = await _FakeEngine().recognize(_blank(200, 120));
      expect(r.recognized, isTrue);
      expect(scanSearchableText(r), '第一行\n第二行');
      expect(r.engineId, 'fake');
    });
  });

  group('D37 版面层 · 真实照片路径', () {
    test('带噪点/灰底的合成"扫描页"仍只切出文字行', () {
      final rnd = math.Random(7);
      final im = _blank(240, 320);
      for (var y = 0; y < 320; y++) {
        for (var x = 0; x < 240; x++) {
          final v = 245 - rnd.nextInt(12); // 纸面微噪声
          im.setPixel(x, y, img.ColorRgb8(v, v, v));
        }
      }
      _textLine(im, 60, 18, 240);
      _textLine(im, 140, 18, 240);
      final layout = segmentScanTextLines(im);
      expect(layout.lines, hasLength(2));
      expect(layout.lines.first.top, lessThan(layout.lines.last.top));
    });
  });
}

class _FakeEngine implements ScanOcrEngine {
  @override
  String get id => 'fake';

  @override
  Future<ScanOcrResult> recognize(img.Image source) async => ScanOcrResult(
    layout: segmentScanTextLines(source),
    text: const ['第一行', '第二行'],
    engineId: id,
    recognized: true,
  );
}
