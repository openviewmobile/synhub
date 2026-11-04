// ★★ ③Drive 第 225 轮 **D37 扫描件自动裁边/矫正/增强** 用例（全离线，纯 Dart）。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:synhub/src/features/drive/drive_pdf_markup.dart' show Offset2;
import 'package:synhub/src/features/drive/drive_scan_enhance.dart';

/// 造一张"深色桌面 + 白色纸张"的合成图（纸张边框留 [margin] 像素）。
img.Image _pageOnDesk({
  int w = 200,
  int h = 260,
  int margin = 30,
  int paper = 235,
  int desk = 40,
}) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final inside =
          x >= margin && x < w - margin && y >= margin && y < h - margin;
      final v = inside ? paper : desk;
      im.setPixel(x, y, img.ColorRgba8(v, v, v, 255));
    }
  }
  return im;
}

void main() {
  group('D37 扫描 · 四角检测', () {
    test('深底白纸 ⇒ 四角落在纸张边界附近（归一化）', () {
      final im = _pageOnDesk(w: 200, h: 260, margin: 30);
      final q = detectDocumentQuad(im);
      expect(q.isFull, isFalse, reason: '这种合成图必须能检测出来');
      expect(q.topLeft.dx, closeTo(30 / 200, 0.08));
      expect(q.topLeft.dy, closeTo(30 / 260, 0.08));
      expect(q.bottomRight.dx, closeTo(170 / 200, 0.08));
      expect(q.bottomRight.dy, closeTo(230 / 260, 0.08));
    });

    test('纯色图（没有任何边界）⇒ 如实回整幅兜底，不假装检测成功', () {
      final flat = img.Image(width: 120, height: 120);
      for (var y = 0; y < 120; y++) {
        for (var x = 0; x < 120; x++) {
          flat.setPixel(x, y, img.ColorRgba8(128, 128, 128, 255));
        }
      }
      expect(detectDocumentQuad(flat).isFull, isTrue);
    });

    test('极大尺寸会被降采样检测（不超时）', () {
      final big = _pageOnDesk(w: 900, h: 1200, margin: 120);
      final q = detectDocumentQuad(big);
      expect(q.isFull, isFalse);
      expect(q.topLeft.dx, closeTo(120 / 900, 0.06));
    });
  });

  group('D37 扫描 · 透视矫正', () {
    test('整幅矫正 ⇒ 尺寸不变、内容不变', () {
      final im = _pageOnDesk(w: 100, h: 100, margin: 10);
      final out = warpDocumentQuad(im, ScanQuad.full);
      expect(out.width, 100);
      expect(out.height, 100);
      expect(out.getPixel(50, 50).r.toInt(), 235);
    });

    test('只取纸面 ⇒ 输出尺寸贴合纸张、四角都是纸色、没有桌面色', () {
      final im = _pageOnDesk(w: 200, h: 200, margin: 40);
      final q = detectDocumentQuad(im);
      final out = warpDocumentQuad(im, q);
      expect(out.width, lessThan(200));
      expect(out.height, lessThan(200));
      final corners = [
        out.getPixel(1, 1),
        out.getPixel(out.width - 2, 1),
        out.getPixel(1, out.height - 2),
        out.getPixel(out.width - 2, out.height - 2),
      ];
      for (final c in corners) {
        expect(c.r.toInt(), greaterThan(180), reason: '矫正后四角应该是纸');
      }
    });

    test('长边上限生效（大图不会产出超大位图）', () {
      final im = _pageOnDesk(w: 800, h: 1000, margin: 100);
      final out = warpDocumentQuad(im, ScanQuad.full, maxSide: 300);
      expect(math.max(out.width, out.height), 300);
    });
  });

  group('D37 扫描 · 增强', () {
    test('autoLevels 拉开对比：灰底纸变得更亮/更黑分明', () {
      final im = img.Image(width: 40, height: 40);
      for (var y = 0; y < 40; y++) {
        for (var x = 0; x < 40; x++) {
          final v = x < 20 ? 110 : 150; // 低对比
          im.setPixel(x, y, img.ColorRgba8(v, v, v, 255));
        }
      }
      final out = enhanceScanImage(im, ScanEnhanceMode.autoLevels);
      final left = out.getPixel(5, 20).r.toInt();
      final right = out.getPixel(35, 20).r.toInt();
      expect(left, lessThan(110));
      expect(right, greaterThan(150));
      expect(right - left, greaterThan(40), reason: '对比必须被拉开');
    });

    test('gray 三通道相同；mono 只有 0/255 两档', () {
      final im = _pageOnDesk(w: 60, h: 60, margin: 15);
      final g = enhanceScanImage(im, ScanEnhanceMode.gray);
      for (final p in [g.getPixel(5, 5), g.getPixel(30, 30)]) {
        expect(p.r, p.g);
        expect(p.g, p.b);
      }
      final m = enhanceScanImage(im, ScanEnhanceMode.mono);
      final seen = <int>{};
      for (var y = 0; y < m.height; y++) {
        for (var x = 0; x < m.width; x++) {
          seen.add(m.getPixel(x, y).r.toInt());
        }
      }
      expect(seen.difference({0, 255}), isEmpty, reason: '二值化只允许 0/255');
    });

    test('none ⇒ 原图原样返回', () {
      final im = _pageOnDesk(w: 20, h: 20, margin: 5);
      expect(identical(enhanceScanImage(im, ScanEnhanceMode.none), im), isTrue);
    });
  });

  group('D37 扫描 · 一条链', () {
    test('自动检测 + 矫正 + 增强：detected=true，尺寸变小且对比更强', () {
      final im = _pageOnDesk(w: 240, h: 320, margin: 40, paper: 200, desk: 60);
      final r = scanDocumentPipeline(im);
      expect(r.detected, isTrue);
      expect(r.image.width, lessThan(240));
      expect(r.image.width, greaterThan(150), reason: '不该把纸裁没了');
      final center = r.image.getPixel(r.image.width ~/ 2, r.image.height ~/ 2);
      expect(center.r.toInt(), greaterThan(180));
    });

    test('指定 quad ⇒ 不再检测（detected=true 且按传进来的框矫正）', () {
      final im = _pageOnDesk(w: 100, h: 100, margin: 10);
      final out = scanDocumentPipeline(
        im,
        quad: const ScanQuad(
          topLeft: Offset2(0.25, 0.25),
          topRight: Offset2(0.75, 0.25),
          bottomRight: Offset2(0.75, 0.75),
          bottomLeft: Offset2(0.25, 0.75),
        ),
        mode: ScanEnhanceMode.none,
        outWidth: 50,
      );
      expect(out.detected, isTrue);
      expect(out.image.width, 50);
      expect(out.quad.toJson()['tl'], [0.25, 0.25]);
    });
  });
}
