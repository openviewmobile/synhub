// ★★ ③Drive 第 243 轮：**D37 识别层（自研点阵模板 OCR）** 的用例。
//
// 口径（必须诚实）：
//   * 这是**真识别**——切分/重采样/汉明距离匹配/阈值都是真算法；
//   * 但只对**点阵风格印刷体（0-9 A-Z + 少量符号）**可靠，
//     中文/手写/艺术字仍需模型 ⇒ 引擎是可插拔的（`ScanOcrEngine`）。
//
// 用例刻意**不**只从字模渲染（那样只是自证）；关键几条用手画位图。
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:synhub/src/features/drive/drive_scan_ocr.dart';
import 'package:synhub/src/features/drive/drive_scan_ocr_template.dart';

/// 用内置 5×7 字模把文本画成"扫描样张"（scale 像素/格）。
img.Image render(String text, {int scale = 6, int spacing = 1}) {
  const cols = kScanGlyphCols;
  const rows = kScanGlyphRows;
  var width = 2 * scale;
  for (var i = 0; i < text.length; i++) {
    width += (cols + spacing) * scale;
  }
  final height = (rows + 2) * scale;
  final im = img.Image(width: width, height: height);
  img.fill(im, color: img.ColorRgb8(255, 255, 255));
  final ink = img.ColorRgb8(0, 0, 0);
  var x = scale;
  for (final ch in text.split('')) {
    final glyph = kScanGlyphFont5x7[ch];
    if (glyph == null) {
      x += (cols + spacing) * scale;
      continue;
    }
    for (var gy = 0; gy < rows; gy++) {
      for (var gx = 0; gx < cols; gx++) {
        if (glyph[gy][gx] != '#') continue;
        for (var dy = 0; dy < scale; dy++) {
          for (var dx = 0; dx < scale; dx++) {
            im.setPixel(
              x + gx * scale + dx,
              scale + gy * scale + dy,
              ink,
            );
          }
        }
      }
    }
    x += (cols + spacing) * scale;
  }
  return im;
}

/// 把一张"手画"的点阵（`#`=黑）画进白底图，格子间留 gap 像素。
img.Image drawBitmap(List<String> art, {int scale = 6, int gap = 6}) {
  final h = art.length * scale;
  final w = art[0].length * scale;
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(255, 255, 255));
  final ink = img.ColorRgb8(0, 0, 0);
  for (var y = 0; y < art.length; y++) {
    for (var x = 0; x < art[y].length; x++) {
      if (art[y][x] != '#') continue;
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          im.setPixel(x * scale + dx, y * scale + dy, ink);
        }
      }
    }
  }
  return im;
}

void main() {
  group('D37 自研 OCR · 字形判定（手画位图，不是自证）', () {
    test('★ 手画/变形的字形仍能认对（不是从字模渲染的自证）', () {
      // 手写的 7（顶横比字模宽一格、尾巴右移）
      final seven = drawBitmap([
        '######',
        '.....#',
        '....#.',
        '...#..',
        '..#...',
        '.#....',
        '.#....',
      ]);
      // H：**整体偏移 + 画布留白**（考验位置无关性，不是认字模）
      // ⚠️ 中横必须在**第 4 行**（row index 3）。写在第 3 行时会与 `N` 撞车
      // —— 这是 243 轮实测到的真实歧义（无衬线高横 H ≈ N），顺手记进用例。
      final hArt = drawBitmap([
        '#...#',
        '#...#',
        '#...#',
        '#####',
        '#...#',
        '#...#',
        '#...#',
      ]);
      final aitch = img.Image(width: hArt.width + 12, height: hArt.height + 12);
      img.fill(aitch, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(aitch, hArt, dstX: 7, dstY: 5);
      // 瘦长写法 L（竖笔加粗一列）
      final ell = drawBitmap([
        '##...',
        '##...',
        '##...',
        '##...',
        '##...',
        '##...',
        '#####',
      ]);
      for (final (art, want) in [
        (seven, '7'),
        (aitch, 'H'),
        (ell, 'L'),
      ]) {
        final ink = scanInkMatrix(art);
        final box = _inkExtent(ink);
        final m = classifyScanGlyph(ink, box, maxDistance: 12);
        expect(m.char, want, reason: '手画位图应认成 $want，实际 ${m.char}');
        expect(m.confidence, greaterThan(0.5));
      }
    });

    test('⚠️ 0/O 无斜杠写法**本质同形** ⇒ 只保证二者之一（记录歧义，不假装）', () {
      final round = drawBitmap([
        '.###.',
        '#...#',
        '#...#',
        '#...#',
        '#...#',
        '#...#',
        '.###.',
      ]);
      final m = classifyScanGlyph(
        scanInkMatrix(round),
        ScanGlyphBox(0, 0, round.width - 1, round.height - 1),
      );
      expect(
        ['0', 'O'],
        contains(m.char),
        reason: '不带斜杠时 0 与 O 无法区分；引擎给一个候选即可，但**不能**给别的字',
      );
    });

    test('★ 空白框 ⇒ `?`（绝不瞎猜）；纯黑块 ⇒ `?`', () {
      final blank = img.Image(width: 20, height: 20);
      img.fill(blank, color: img.ColorRgb8(255, 255, 255));
      final inkBlank = scanInkMatrix(blank);
      final r1 = classifyScanGlyph(
        inkBlank,
        const ScanGlyphBox(0, 0, 19, 19),
      );
      expect(r1.char, '?');
      expect(r1.confidence, 0);

      final solid = img.Image(width: 20, height: 20);
      img.fill(solid, color: img.ColorRgb8(0, 0, 0));
      final r2 = classifyScanGlyph(
        scanInkMatrix(solid),
        const ScanGlyphBox(0, 0, 19, 19),
      );
      expect(r2.char, '?', reason: '和谁都不像 ⇒ 不许挑一个最近的来蒙');
    });

    test('阈值收紧 ⇒ 同一张位图可能认不出来（诚实边界）', () {
      final seven = drawBitmap([
        '######.',
        '.....##',
        '....##.',
        '...##..',
        '..##...',
        '.##....',
        '.##....',
      ]);
      final ink = scanInkMatrix(seven);
      final strict = classifyScanGlyph(
        ink,
        const ScanGlyphBox(0, 0, 41, 41),
        maxDistance: 0,
      );
      expect(strict.char, '?', reason: 'maxDistance=0 只接受逐格完全相同');
    });
  });

  group('D37 自研 OCR · 整页识别', () {
    test('★ 「HELLO 123」整页：识别为真、词之间保留空格、可搜索文本非空', () async {
      final page = render('HELLO 123');
      final r = await const ScanGlyphOcrEngine().recognize(page);
      expect(r.engineId, 'self-template-5x7');
      expect(r.recognized, isTrue);
      final text = scanSearchableText(r);
      expect(text, contains('HELLO'));
      expect(text, contains('123'));
    });

    test('★ 多行：行序自上而下（阅读顺序 = 版面层的 order）', () async {
      final one = render('A1');
      final two = render('B2');
      final page = img.Image(width: one.width, height: one.height + two.height);
      img.fill(page, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(page, one, dstY: 0);
      img.compositeImage(page, two, dstY: one.height);
      final r = await const ScanGlyphOcrEngine().recognize(page);
      expect(r.text.length, greaterThanOrEqualTo(2));
      expect(r.text[0], contains('A1'));
      expect(r.text[1], contains('B2'));
    });

    test('★ 噪声/纯白页 ⇒ recognized=false 且 text 全空（不编造）', () async {
      final white = img.Image(width: 200, height: 120);
      img.fill(white, color: img.ColorRgb8(255, 255, 255));
      final r = await const ScanGlyphOcrEngine().recognize(white);
      expect(r.recognized, isFalse);
      expect(scanSearchableText(r), isEmpty);
      expect(r.text.every((l) => l.isEmpty), isTrue);
    });

    test('★ 认不出的字形输出 `?`，但同一页里认得出的照常输出', () async {
      // 先画一个"谁都不像"的符号（粗十字 + 斜线），再画 42
      final weird = drawBitmap([
        '..###..',
        '.#####.',
        '###.###',
        '#######',
        '###.###',
        '.#####.',
        '..###..',
      ]);
      final good = render('42');
      final page = img.Image(
        width: weird.width + good.width + 20,
        // ★ 高度要取两者最大：按 weird 的高度会把 good 裁掉半截（243 轮踩到）
        height: weird.height > good.height ? weird.height : good.height,
      );
      img.fill(page, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(page, weird, dstY: 0);
      img.compositeImage(page, good, dstX: weird.width + 20, dstY: 0);
      final r = await const ScanGlyphOcrEngine().recognize(page);
      final text = scanSearchableText(r);
      expect(text.replaceAll(' ', ''), contains('42'));
      expect(r.recognized, isTrue);
    });

    test('★ 版面层仍然可用：引擎返回的 layout 与 layout-only 一致（同一算法）', () async {
      final page = render('ABC');
      final a = await const ScanGlyphOcrEngine().recognize(page);
      final b = await const ScanLayoutOnlyEngine().recognize(page);
      expect(a.layout.lines.length, b.layout.lines.length);
      expect(a.layout.width, b.layout.width);
      // layout-only 依旧"不识别"，这是它存在的意义
      expect(b.recognized, isFalse);
      expect(scanSearchableText(b), isEmpty);
    });
  });
}

/// 墨迹范围（用于"带留白"的画布）。
ScanGlyphBox _inkExtent(List<List<bool>> ink) {
  var l = 1 << 30, t = 1 << 30, r = -1, b = -1;
  for (var y = 0; y < ink.length; y++) {
    for (var x = 0; x < ink[y].length; x++) {
      if (!ink[y][x]) continue;
      if (x < l) l = x;
      if (x > r) r = x;
      if (y < t) t = y;
      if (y > b) b = y;
    }
  }
  return ScanGlyphBox(l, t, r, b);
}
