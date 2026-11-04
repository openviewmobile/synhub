// ★★★ ③Drive **D37「扫描件」的自动裁边 / 透视矫正 / 增强** —— 第 225 轮。
//
// ## 官方对照
// 官方 Drive 的扫描件走 **Google MLKit** 的文档检测（Document Scanner）：
// 自动找纸张四角 → 透视矫正 → 增强（黑白/灰度/增亮）→ 可选 OCR 取文字。
// 第 216 轮我们把扫描页做出来了（多页导入、排序、删除、导出），但**不做图像处理**。
//
// ## 本轮做到哪儿（全 **纯 Dart**，可离线验证）
// * `detectDocumentQuad`：Sobel 梯度 + 四边投影找"纸张边界"（不依赖任何三方模型）；
// * `warpDocumentQuad`：四点透视（双线性采样）矫正成正视图；
// * `enhanceScanImage`：`autoLevels` / `gray` / `mono`（自适应阈值）三档；
// * `scanDocumentPipeline`：检测 → 矫正 → 增强 一条链。
//
// ## 仍未做（挂账，保持 🟠）
// * **OCR**：官方 MLKit 的文字识别没有对等实现（本仓库不做三方模型依赖）；
// * MLKit 的**边缘检测精度**（曲面/弱光/多页同框）我方算法达不到，属"能做到但更弱"。
// 这两条如实登记在台账里。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'drive_pdf_markup.dart' show Offset2;

/// 纸张四角（归一化 0..1，顺序：左上→右上→右下→左下）
class ScanQuad {
  const ScanQuad({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  final Offset2 topLeft;
  final Offset2 topRight;
  final Offset2 bottomRight;
  final Offset2 bottomLeft;

  /// 整幅（没检测出更好边界时的兜底）
  static const ScanQuad full = ScanQuad(
    topLeft: Offset2(0, 0),
    topRight: Offset2(1, 0),
    bottomRight: Offset2(1, 1),
    bottomLeft: Offset2(0, 1),
  );

  List<Offset2> get corners => [topLeft, topRight, bottomRight, bottomLeft];

  bool get isFull =>
      topLeft.dx == 0 &&
      topLeft.dy == 0 &&
      topRight.dx == 1 &&
      bottomRight.dx == 1 &&
      bottomRight.dy == 1 &&
      bottomLeft.dy == 1;

  Map<String, Object?> toJson() => {
    'tl': [topLeft.dx, topLeft.dy],
    'tr': [topRight.dx, topRight.dy],
    'br': [bottomRight.dx, bottomRight.dy],
    'bl': [bottomLeft.dx, bottomLeft.dy],
  };

  @override
  String toString() =>
      'ScanQuad(${topLeft.dx.toStringAsFixed(3)},${topLeft.dy.toStringAsFixed(3)} '
      '${topRight.dx.toStringAsFixed(3)},${topRight.dy.toStringAsFixed(3)} '
      '${bottomRight.dx.toStringAsFixed(3)},${bottomRight.dy.toStringAsFixed(3)} '
      '${bottomLeft.dx.toStringAsFixed(3)},${bottomLeft.dy.toStringAsFixed(3)})';
}

/// 把图转成灰度（Luma），并可选降采样到 [maxSide] 内（检测用，快很多）。
Float32List _gray(img.Image src, {int maxSide = 240}) {
  final scale = math.max(src.width, src.height) > maxSide
      ? maxSide / math.max(src.width, src.height)
      : 1.0;
  final w = math.max(1, (src.width * scale).round());
  final h = math.max(1, (src.height * scale).round());
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final sx = scale == 1.0 ? x : (x / scale).clamp(0, src.width - 1).toInt();
      final sy = scale == 1.0 ? y : (y / scale).clamp(0, src.height - 1).toInt();
      final p = src.getPixel(sx, sy);
      out[y * w + x] =
          0.299 * p.r.toDouble() + 0.587 * p.g.toDouble() + 0.114 * p.b.toDouble();
    }
  }
  return out;
}

/// 检测纸张四角。
///
/// 思路（不依赖模型，纯投影）：
///   ① Sobel 求梯度幅值；② 对每行/每列求"梯度能量"；
///   ③ 从四条边往里扫，找**第一个超过阈值**的位置（阈值 = 均值 + [k]×标准差）；
///   ④ 得到四条边线后取交点（矩形假设 ⇒ 直接组角）。
/// 找不到就回 [ScanQuad.full]（**绝不假装检测成功**）。
ScanQuad detectDocumentQuad(img.Image source, {double k = 1.2}) {
  final g = _gray(source);
  final w = source.width > 240 || source.height > 240
      ? math.max(1, (source.width * (240 / math.max(source.width, source.height))).round())
      : source.width;
  final h = source.width > 240 || source.height > 240
      ? math.max(1, (source.height * (240 / math.max(source.width, source.height))).round())
      : source.height;
  if (w < 8 || h < 8) return ScanQuad.full;

  // 每行/列的梯度能量（横向梯度按行汇总，纵向按列汇总）
  final rowEnergy = Float32List(h);
  final colEnergy = Float32List(w);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      double at(int xx, int yy) => g[yy * w + xx];
      final gx = (at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1)) -
          (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1));
      final gy = (at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1)) -
          (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1));
      final mag = math.sqrt(gx * gx + gy * gy);
      rowEnergy[y] += mag;
      colEnergy[x] += mag;
    }
  }

  double mean(Float32List a) {
    var s = 0.0;
    for (final v in a) {
      s += v;
    }
    return s / a.length;
  }

  double std(Float32List a, double m) {
    var s = 0.0;
    for (final v in a) {
      final d = v - m;
      s += d * d;
    }
    return math.sqrt(s / a.length);
  }

  int? findEdge(Float32List a, {required bool fromStart}) {
    final m = mean(a);
    final s = std(a, m);
    final thr = m + k * s;
    if (fromStart) {
      for (var i = 1; i < a.length - 1; i++) {
        if (a[i] > thr && a[i] >= a[i - 1] && a[i] >= a[i + 1]) return i;
      }
    } else {
      for (var i = a.length - 2; i > 0; i--) {
        if (a[i] > thr && a[i] >= a[i - 1] && a[i] >= a[i + 1]) return i;
      }
    }
    return null;
  }

  final top = findEdge(rowEnergy, fromStart: true);
  final bottom = findEdge(rowEnergy, fromStart: false);
  final left = findEdge(colEnergy, fromStart: true);
  final right = findEdge(colEnergy, fromStart: false);
  if (top == null || bottom == null || left == null || right == null) {
    return ScanQuad.full;
  }
  if (top >= bottom || left >= right) return ScanQuad.full;

  double nx(int v, int total) => (v / total).clamp(0.0, 1.0);
  return ScanQuad(
    topLeft: Offset2(nx(left, w), nx(top, h)),
    topRight: Offset2(nx(right, w), nx(top, h)),
    bottomRight: Offset2(nx(right, w), nx(bottom, h)),
    bottomLeft: Offset2(nx(left, w), nx(bottom, h)),
  );
}

/// 双线性采样（[x]/[y] 允许小数）
img.Color _sample(img.Image src, double x, double y) {
  final x0 = x.floor().clamp(0, src.width - 1);
  final y0 = y.floor().clamp(0, src.height - 1);
  final x1 = (x0 + 1).clamp(0, src.width - 1);
  final y1 = (y0 + 1).clamp(0, src.height - 1);
  final fx = (x - x0).clamp(0.0, 1.0);
  final fy = (y - y0).clamp(0.0, 1.0);
  final a = src.getPixel(x0, y0);
  final b = src.getPixel(x1, y0);
  final c = src.getPixel(x0, y1);
  final d = src.getPixel(x1, y1);
  double ch(num p00, num p10, num p01, num p11) =>
      p00 * (1 - fx) * (1 - fy) +
      p10 * fx * (1 - fy) +
      p01 * (1 - fx) * fy +
      p11 * fx * fy;
  return img.ColorRgba8(
    ch(a.r, b.r, c.r, d.r).round().clamp(0, 255),
    ch(a.g, b.g, c.g, d.g).round().clamp(0, 255),
    ch(a.b, b.b, c.b, d.b).round().clamp(0, 255),
    255,
  );
}

/// 四点透视矫正：把 [quad] 围起来的区域拉成 [outWidth] × 自适应高度的正视图。
///
/// 用**逆映射 + 双线性采样**（不依赖 OpenCV/三方库）。宽度按上下边长度取大者，
/// 高度按左右边长度取大者，保持原始长宽比。
img.Image warpDocumentQuad(
  img.Image source,
  ScanQuad quad, {
  int? outWidth,
  int maxSide = 2000,
}) {
  final w = source.width.toDouble();
  final h = source.height.toDouble();
  final tl = Offset2(quad.topLeft.dx * w, quad.topLeft.dy * h);
  final tr = Offset2(quad.topRight.dx * w, quad.topRight.dy * h);
  final br = Offset2(quad.bottomRight.dx * w, quad.bottomRight.dy * h);
  final bl = Offset2(quad.bottomLeft.dx * w, quad.bottomLeft.dy * h);

  double len(Offset2 a, Offset2 b) {
    final dx = a.dx - b.dx;
    final dy = a.dy - b.dy;
    return math.sqrt(dx * dx + dy * dy);
  }

  var ow = outWidth ?? math.max(len(tl, tr), len(bl, br)).round();
  var oh = math.max(len(tl, bl), len(tr, br)).round();
  if (ow < 1) ow = 1;
  if (oh < 1) oh = 1;
  final longest = math.max(ow, oh);
  if (longest > maxSide) {
    final s = maxSide / longest;
    ow = math.max(1, (ow * s).round());
    oh = math.max(1, (oh * s).round());
  }
  final out = img.Image(width: ow, height: oh);
  for (var y = 0; y < oh; y++) {
    final v = oh == 1 ? 0.0 : y / (oh - 1);
    // 左边、右边上的点
    final lx = tl.dx + (bl.dx - tl.dx) * v;
    final ly = tl.dy + (bl.dy - tl.dy) * v;
    final rx = tr.dx + (br.dx - tr.dx) * v;
    final ry = tr.dy + (br.dy - tr.dy) * v;
    for (var x = 0; x < ow; x++) {
      final u = ow == 1 ? 0.0 : x / (ow - 1);
      out.setPixel(
        x,
        y,
        _sample(source, lx + (rx - lx) * u, ly + (ry - ly) * u),
      );
    }
  }
  return out;
}

enum ScanEnhanceMode { none, autoLevels, gray, mono }

/// 增强：`autoLevels` 拉对比（2%~98% 分位）、`gray` 转灰度、`mono` 自适应阈值。
img.Image enhanceScanImage(img.Image source, ScanEnhanceMode mode) {
  if (mode == ScanEnhanceMode.none) return source;
  final out = img.Image(width: source.width, height: source.height);
  final hist = List<int>.filled(256, 0);
  final gray = Uint8List(source.width * source.height);
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final p = source.getPixel(x, y);
      final l = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
      gray[y * source.width + x] = l;
      hist[l] += 1;
    }
  }
  final total = gray.length;
  int lo = 0, hi = 255, acc = 0;
  for (var i = 0; i < 256; i++) {
    acc += hist[i];
    if (acc >= total * 0.02) {
      lo = i;
      break;
    }
  }
  acc = 0;
  for (var i = 255; i >= 0; i--) {
    acc += hist[i];
    if (acc >= total * 0.02) {
      hi = i;
      break;
    }
  }
  if (hi <= lo) hi = math.min(255, lo + 1);
  // ⚠️ 纸面几乎均匀时 hi≈lo ⇒ 硬拉对比会把整页拉成 0（用例当场抓到）。
  // 分位区间太窄就**不动它**，而不是造出一张全黑图。
  final range = hi - lo;
  final stretch = range > 4;

  // 局部均值（`mono` 的自适应阈值用 9×9 窗口）
  final mean = Uint8List(source.width * source.height);
  const r = 4;
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      var s = 0, n = 0;
      for (var dy = -r; dy <= r; dy++) {
        for (var dx = -r; dx <= r; dx++) {
          final xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= source.width || yy >= source.height) {
            continue;
          }
          s += gray[yy * source.width + xx];
          n += 1;
        }
      }
      mean[y * source.width + x] = (s / n).round().clamp(0, 255);
    }
  }

  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final i = y * source.width + x;
      final src = source.getPixel(x, y);
      final l = gray[i];
      if (mode == ScanEnhanceMode.mono) {
        final v = l > mean[i] - 8 ? 255 : 0;
        out.setPixel(x, y, img.ColorRgba8(v, v, v, 255));
      } else if (mode == ScanEnhanceMode.gray) {
        final v = (stretch ? ((l - lo) * 255) / range : l.toDouble())
            .round()
            .clamp(0, 255);
        out.setPixel(x, y, img.ColorRgba8(v, v, v, 255));
      } else {
        final v = (stretch ? ((l - lo) * 255) / range : l.toDouble())
            .round()
            .clamp(0, 255);
        final ratio = l == 0 ? 0.0 : v / l;
        out.setPixel(
          x,
          y,
          img.ColorRgba8(
            (src.r * ratio).round().clamp(0, 255),
            (src.g * ratio).round().clamp(0, 255),
            (src.b * ratio).round().clamp(0, 255),
            255,
          ),
        );
      }
    }
  }
  return out;
}

class ScanProcessResult {
  const ScanProcessResult({
    required this.image,
    required this.quad,
    required this.detected,
  });

  final img.Image image;
  final ScanQuad quad;

  /// 是否**真的**检测到边界（false ⇒ 用了整幅兜底，调用方应如实告知用户）
  final bool detected;
}

/// 一条链：检测 → 矫正 → 增强（[quad] 传入则跳过检测）。
ScanProcessResult scanDocumentPipeline(
  img.Image source, {
  ScanQuad? quad,
  ScanEnhanceMode mode = ScanEnhanceMode.autoLevels,
  int? outWidth,
}) {
  final q = quad ?? detectDocumentQuad(source);
  final detected = quad != null || !q.isFull;
  var out = q.isFull ? source : warpDocumentQuad(source, q, outWidth: outWidth);
  out = enhanceScanImage(out, mode);
  return ScanProcessResult(image: out, quad: q, detected: detected);
}
