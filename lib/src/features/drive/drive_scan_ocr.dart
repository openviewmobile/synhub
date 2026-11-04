// ★★★ ③Drive **D37「扫描件文字层」的诚实半边** —— 第 232 轮。
//
// ## 官方做法
// 官方扫描用 **MLKit**：文档检测 → 透视矫正 → 增强 → **OCR 文字识别**，
// 识别结果能当文字层（可搜索/可复制）。
//
// ## 本轮做到哪儿（以及为什么不是"完整 OCR"）
// 从零自己写一个中英文识别器是不现实的（要字形样本/模型/训练），
// 而本仓库的既定约束是**不引入三方模型依赖**（用户对电子书的要求是"协议不通就自研"，
// 但 OCR 没有可"自研"出来的轻量等价物）。
// 所以本轮把 OCR 拆成**两层**，把能确定做对的那层做实：
//
//   ① **版面层（本轮实现）**：二值化 → 行投影切**文字行** → 行内投影切**词块**，
//      给出归一化坐标与阅读顺序。这一层不需要任何模型，且是 OCR 的前置。
//   ② **识别层（本轮只留接口）**：`ScanOcrEngine`。内置实现
//      [ScanLayoutOnlyEngine] **如实**声明 `recognized = false`、`text = ''`
//      —— **绝不编造识别结果**。将来接 MLKit（Android）或自研小模型时
//      只要实现这个接口，上层（搜索/复制/文字层导出）不用改。
//
// 这样 D37 的差距被**收窄并说清**：缺的是"字符识别"，不是整条链。
import 'package:image/image.dart' as img;

/// 一行（或一个词块）的归一化框 + 阅读顺序
class ScanTextLine {
  const ScanTextLine({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.order,
    this.words = const [],
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  /// 阅读顺序（0 起，自上而下）
  final int order;

  /// 行内切出来的词块框（同一坐标系）
  final List<ScanTextBlock> words;

  double get width => right - left;
  double get height => bottom - top;
  double get centerY => (top + bottom) / 2;

  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
    'order': order,
    'words': [for (final w in words) w.toJson()],
  };
}

class ScanTextBlock {
  const ScanTextBlock({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };
}

class ScanLayout {
  const ScanLayout({required this.lines, required this.width, required this.height});

  final List<ScanTextLine> lines;
  final int width;
  final int height;

  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    'lines': [for (final l in lines) l.toJson()],
  };
}

/// 识别结果。**`recognized` 为 false 时 `text` 必须为空** —— 这是铁律。
class ScanOcrResult {
  const ScanOcrResult({
    required this.layout,
    required this.text,
    required this.engineId,
    required this.recognized,
  });

  final ScanLayout layout;
  final List<String> text;
  final String engineId;
  final bool recognized;

  Map<String, Object?> toJson() => {
    'engine': engineId,
    'recognized': recognized,
    'lines': text,
    'layout': layout.toJson(),
  };
}

abstract class ScanOcrEngine {
  String get id;

  Future<ScanOcrResult> recognize(img.Image source);
}

/// 内置实现：**只做版面，不做识别**（`recognized=false`、`text` 全空）。
///
/// 为什么要有这个"什么都不识别"的引擎：它让上层与用例能真的跑通，
/// 同时把"我方没有 OCR"这件事**写在返回值里**，而不是含糊过去。
class ScanLayoutOnlyEngine implements ScanOcrEngine {
  const ScanLayoutOnlyEngine();

  @override
  String get id => 'layout-only';

  @override
  Future<ScanOcrResult> recognize(img.Image source) async {
    final layout = segmentScanTextLines(source);
    return ScanOcrResult(
      layout: layout,
      text: List<String>.filled(layout.lines.length, ''),
      engineId: id,
      recognized: false,
    );
  }
}

/// 版面分析：切文字行（再切词块）。纯 Dart、确定性强。
ScanLayout segmentScanTextLines(
  img.Image source, {
  int threshold = 160,
  double minLineHeightRatio = 0.012,
  double wordGapRatio = 0.012,
}) {
  final w = source.width;
  final h = source.height;
  if (w <= 0 || h <= 0) {
    return const ScanLayout(lines: [], width: 0, height: 0);
  }
  // ① 二值化：深色为"有内容"
  final ink = List<List<bool>>.generate(
    h,
    (y) => List<bool>.generate(w, (x) {
      final p = source.getPixel(x, y);
      final luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      return luma < threshold;
    }),
    growable: false,
  );

  // ② 行投影：找连续"有内容"的行带（带内允许极窄空隙，避免一行被切成两半）
  final rowInk = List<int>.generate(h, (y) {
    var c = 0;
    for (var x = 0; x < w; x++) {
      if (ink[y][x]) c++;
    }
    return c;
  });
  final minRowInk = (w * 0.002).ceil().clamp(1, w);
  final minLineHeight = (h * minLineHeightRatio).round().clamp(2, h);
  final bands = <List<int>>[];
  var start = -1;
  var gap = 0;
  for (var y = 0; y < h; y++) {
    final has = rowInk[y] >= minRowInk;
    if (has) {
      if (start < 0) start = y;
      gap = 0;
    } else if (start >= 0) {
      gap += 1;
      // 允许 1 像素空行（扫描噪声），超过就断
      if (gap > 1) {
        bands.add([start, y - gap]);
        start = -1;
        gap = 0;
      }
    }
  }
  if (start >= 0) bands.add([start, h - 1]);

  final lines = <ScanTextLine>[];
  final wordGap = (w * wordGapRatio).round().clamp(1, w);
  for (final b in bands) {
    final top = b[0];
    final bottom = b[1];
    if (bottom - top + 1 < minLineHeight) continue; // 太扁的当噪声
    // 行的左右边界
    var left = w;
    var right = 0;
    for (var y = top; y <= bottom; y++) {
      for (var x = 0; x < w; x++) {
        if (!ink[y][x]) continue;
        if (x < left) left = x;
        if (x > right) right = x;
      }
    }
    if (right <= left) continue;
    // ③ 行内列投影切词块
    final words = <ScanTextBlock>[];
    var ws = -1;
    var wgap = 0;
    for (var x = left; x <= right; x++) {
      var has = false;
      for (var y = top; y <= bottom; y++) {
        if (ink[y][x]) {
          has = true;
          break;
        }
      }
      if (has) {
        if (ws < 0) ws = x;
        wgap = 0;
      } else if (ws >= 0) {
        wgap += 1;
        if (wgap >= wordGap) {
          words.add(
            ScanTextBlock(
              left: ws / w,
              top: top / h,
              right: (x - wgap) / w,
              bottom: (bottom + 1) / h,
            ),
          );
          ws = -1;
          wgap = 0;
        }
      }
    }
    if (ws >= 0) {
      words.add(
        ScanTextBlock(
          left: ws / w,
          top: top / h,
          right: (right + 1) / w,
          bottom: (bottom + 1) / h,
        ),
      );
    }
    lines.add(
      ScanTextLine(
        left: left / w,
        top: top / h,
        right: (right + 1) / w,
        bottom: (bottom + 1) / h,
        order: lines.length,
        words: words,
      ),
    );
  }
  return ScanLayout(lines: lines, width: w, height: h);
}

/// 把版面 + 每行文字拼成**可搜索文本**（识别层没做时返回空串，不编造）。
String scanSearchableText(ScanOcrResult result) =>
    result.recognized ? result.text.join('\n') : '';
