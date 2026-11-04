// ★★★ ③Drive **D37「保存为扫描文件」的识别层 —— 自研实现**（第 243 轮）。
//
// ## 为什么是"自研模板识别"而不是接 MLKit
// 官方扫描走 MLKit（文档检测 → 透视矫正 → 增强 → 字符识别）。本仓库的
// 既定约束是**不引入三方模型依赖**，而"从零炼一个中文模型"在本轮预算内
// 不可能。于是把识别层做成**可插拔**（`ScanOcrEngine`，232 轮就留好了），
// 并提供**一个真的会识别**的自研引擎：
//
//   * 版面层复用 `segmentScanTextLines`（行 → 词块）；
//   * 词块内按**列投影**切字形；
//   * 每个字形重采样成 **5×7** 点阵，与内置点阵字模做**汉明距离**匹配；
//   * 只有最佳距离 ≤ 阈值才算识别，**平手/超阈一律输出 `?`**（不编造）；
//   * 一个字形都没匹配上时 `recognized=false`、`text` 全空（铁律不变）。
//
// ## 能力边界（如实写清，台账里同步标注）
// * 能认：**印刷体·点阵风格**的 `0-9 A-Z` 与少量符号（干净二值化图像上可靠）；
// * 不能认：**中文/手写/艺术字/严重倾斜或低分辨率**的字符 —— 需要模型，
//   这部分仍走"可插拔引擎"（真机上可换成 MLKit 实现，上层不用改）。
//
// 这不是"假装有 OCR"：字模、切分、匹配、阈值都是真算法，
// 且用例用**手画的位图**（不是从字模渲染出来的）来验证。
import 'package:image/image.dart' as img;

import 'drive_scan_ocr.dart';

/// 内置 5×7 点阵字模（`#` = 有墨）。索引键就是它代表的字符。
const Map<String, List<String>> kScanGlyphFont5x7 = {
  '0': ['.###.', '#...#', '#..##', '#.#.#', '##..#', '#...#', '.###.'],
  '1': ['..#..', '.##..', '..#..', '..#..', '..#..', '..#..', '.###.'],
  '2': ['.###.', '#...#', '....#', '...#.', '..#..', '.#...', '#####'],
  '3': ['#####', '...#.', '..#..', '...#.', '....#', '#...#', '.###.'],
  '4': ['...#.', '..##.', '.#.#.', '#..#.', '#####', '...#.', '...#.'],
  '5': ['#####', '#....', '####.', '....#', '....#', '#...#', '.###.'],
  '6': ['..##.', '.#...', '#....', '####.', '#...#', '#...#', '.###.'],
  '7': ['#####', '....#', '...#.', '..#..', '.#...', '.#...', '.#...'],
  '8': ['.###.', '#...#', '#...#', '.###.', '#...#', '#...#', '.###.'],
  '9': ['.###.', '#...#', '#...#', '.####', '....#', '...#.', '.##..'],
  'A': ['..#..', '.#.#.', '#...#', '#...#', '#####', '#...#', '#...#'],
  'B': ['####.', '#...#', '#...#', '####.', '#...#', '#...#', '####.'],
  'C': ['.###.', '#...#', '#....', '#....', '#....', '#...#', '.###.'],
  'D': ['###..', '#..#.', '#...#', '#...#', '#...#', '#..#.', '###..'],
  'E': ['#####', '#....', '#....', '####.', '#....', '#....', '#####'],
  'F': ['#####', '#....', '#....', '####.', '#....', '#....', '#....'],
  'G': ['.###.', '#...#', '#....', '#.###', '#...#', '#...#', '.###.'],
  'H': ['#...#', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'],
  'I': ['.###.', '..#..', '..#..', '..#..', '..#..', '..#..', '.###.'],
  'J': ['..###', '...#.', '...#.', '...#.', '...#.', '#..#.', '.##..'],
  'K': ['#...#', '#..#.', '#.#..', '##...', '#.#..', '#..#.', '#...#'],
  'L': ['#....', '#....', '#....', '#....', '#....', '#....', '#####'],
  'M': ['#...#', '##.##', '#.#.#', '#.#.#', '#...#', '#...#', '#...#'],
  'N': ['#...#', '##..#', '#.#.#', '#..##', '#...#', '#...#', '#...#'],
  'O': ['.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
  'P': ['####.', '#...#', '#...#', '####.', '#....', '#....', '#....'],
  'Q': ['.###.', '#...#', '#...#', '#...#', '#.#.#', '#..#.', '.##.#'],
  'R': ['####.', '#...#', '#...#', '####.', '#.#..', '#..#.', '#...#'],
  'S': ['.###.', '#...#', '#....', '.###.', '....#', '#...#', '.###.'],
  'T': ['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..'],
  'U': ['#...#', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
  'V': ['#...#', '#...#', '#...#', '#...#', '#...#', '.#.#.', '..#..'],
  'W': ['#...#', '#...#', '#...#', '#.#.#', '#.#.#', '##.##', '#...#'],
  'X': ['#...#', '#...#', '.#.#.', '..#..', '.#.#.', '#...#', '#...#'],
  'Y': ['#...#', '#...#', '.#.#.', '..#..', '..#..', '..#..', '..#..'],
  'Z': ['#####', '....#', '...#.', '..#..', '.#...', '#....', '#####'],
  '-': ['.....', '.....', '.....', '#####', '.....', '.....', '.....'],
  '.': ['.....', '.....', '.....', '.....', '.....', '.##..', '.##..'],
  ':': ['.....', '.##..', '.##..', '.....', '.##..', '.##..', '.....'],
  '/': ['....#', '....#', '...#.', '..#..', '.#...', '#....', '#....'],
  '?': ['.###.', '#...#', '....#', '...#.', '..#..', '.....', '..#..'],
  ' ': ['.....', '.....', '.....', '.....', '.....', '.....', '.....'],
};

/// 字模尺寸（识别时把任意字形重采样到这个网格）。
const int kScanGlyphCols = 5;
const int kScanGlyphRows = 7;

/// 一个字形框 + 判定结果（诊断用，UI 可拿它标"哪些字没认出来"）。
class ScanGlyphMatch {
  const ScanGlyphMatch({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.char,
    required this.confidence,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;

  /// 匹配到的字符；没匹配上时是 `?`（**不代表服务端/官方结果**）
  final String char;

  /// 1 - 汉明距离/格数；`?` 时为 0
  final double confidence;

  bool get unknown => char == '?';

  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
    'char': char,
    'confidence': confidence,
  };
}

/// 自研模板识别引擎：真识别，但**只在点阵风格印刷体上可靠**。
class ScanGlyphOcrEngine implements ScanOcrEngine {
  const ScanGlyphOcrEngine({
    this.threshold = 160,
    this.cellCoverage = 0.38,
    this.maxDistance = 9,
    this.glyphPad = 0,
  });

  /// 二值化阈值（越小越"只认深墨"）
  final int threshold;

  /// 重采样时，格子里墨点占比 ≥ 它才算这一格有墨
  final double cellCoverage;

  /// 与字模的最大允许汉明距离（35 格中允许错几格）
  final int maxDistance;

  /// 字形框向外扩几像素（吞掉抗锯齿边缘）
  final int glyphPad;

  @override
  String get id => 'self-template-5x7';

  @override
  Future<ScanOcrResult> recognize(img.Image source) async {
    final layout = segmentScanTextLines(source, threshold: threshold);
    final ink = scanInkMatrix(source, threshold: threshold);
    final text = <String>[];
    var matched = 0;
    for (final line in layout.lines) {
      final box = _linePixelBox(line, source);
      if (box == null) {
        text.add('');
        continue;
      }
      final words = _splitGlyphs(ink, box, gap: _glyphGap(source.width));
      final buf = StringBuffer();
      for (var i = 0; i < words.length; i++) {
        if (i > 0) buf.write(' ');
        for (final g in words[i]) {
          final m = classifyScanGlyph(
            ink,
            g,
            cellCoverage: cellCoverage,
            glyphPad: glyphPad,
            maxDistance: maxDistance,
          );
          buf.write(m.char);
          if (!m.unknown) matched++;
        }
      }
      text.add(buf.toString());
    }
    return ScanOcrResult(
      layout: layout,
      text: text,
      engineId: id,
      // ★ 一个字形都没认出来 ⇒ 如实返回"没有识别"（不把 '?' 当结果）
      recognized: matched > 0,
    );
  }
}

/// 二值化：`true` = 有墨。与版面层同一口径。
List<List<bool>> scanInkMatrix(img.Image source, {int threshold = 160}) {
  final w = source.width;
  final h = source.height;
  if (w <= 0 || h <= 0) return const [];
  return List<List<bool>>.generate(
    h,
    (y) => List<bool>.generate(w, (x) {
      final p = source.getPixel(x, y);
      final luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      return luma < threshold;
    }, growable: false),
    growable: false,
  );
}

/// 一个字形的像素框（闭区间）。
class ScanGlyphBox {
  const ScanGlyphBox(this.left, this.top, this.right, this.bottom);
  final int left;
  final int top;
  final int right;
  final int bottom;
  int get width => right - left + 1;
  int get height => bottom - top + 1;
}

/// 把字形重采样成 5×7 布尔网格。
///
/// ★ 必须**等比缩放 + 居中**，不能直接拉伸到 5 列：像 `1` 这种实际只有
/// 3 列墨的字形，硬拉到 5 列会与字模对不上（243 轮第一版就栽在这，
/// `1`/`3` 全变成 `?`）。
List<List<bool>> resampleScanGlyph(
  List<List<bool>> ink,
  ScanGlyphBox box, {
  double cellCoverage = 0.38,
  int pad = 0,
}) {
  final l = (box.left - pad).clamp(0, ink.isEmpty ? 0 : ink[0].length - 1);
  final t = (box.top - pad).clamp(0, ink.length - 1);
  final r = (box.right + pad).clamp(0, ink.isEmpty ? 0 : ink[0].length - 1);
  final b = (box.bottom + pad).clamp(0, ink.length - 1);
  final bw = r - l + 1;
  final bh = b - t + 1;
  final out = List<List<bool>>.generate(
    kScanGlyphRows,
    (_) => List<bool>.filled(kScanGlyphCols, false, growable: false),
    growable: false,
  );
  if (bw <= 0 || bh <= 0) return out;
  // 先按高度贴到 7 行；太宽就改用宽度贴到 5 列
  var gw = (bw * kScanGlyphRows / bh).round().clamp(1, kScanGlyphCols);
  var gh = kScanGlyphRows;
  if ((bw * kScanGlyphRows / bh).round() > kScanGlyphCols) {
    gw = kScanGlyphCols;
    gh = (bh * kScanGlyphCols / bw).round().clamp(1, kScanGlyphRows);
  }
  final offX = (kScanGlyphCols - gw) ~/ 2;
  final offY = (kScanGlyphRows - gh) ~/ 2;
  for (var gy = 0; gy < gh; gy++) {
    final y0 = t + (bh * gy / gh).floor();
    final y1 = t + (bh * (gy + 1) / gh).ceil();
    for (var gx = 0; gx < gw; gx++) {
      final x0 = l + (bw * gx / gw).floor();
      final x1 = l + (bw * (gx + 1) / gw).ceil();
      var on = 0;
      var total = 0;
      for (var y = y0; y < y1 && y <= b; y++) {
        if (y < 0 || y >= ink.length) continue;
        for (var x = x0; x < x1 && x <= r; x++) {
          if (x < 0 || x >= ink[y].length) continue;
          total++;
          if (ink[y][x]) on++;
        }
      }
      if (total == 0) continue;
      out[offY + gy][offX + gx] = on / total >= cellCoverage;
    }
  }
  return out;
}

/// 认一个字形。匹配不上（超阈值/平手）返回 `?` + confidence 0 —— **不猜**。
ScanGlyphMatch classifyScanGlyph(
  List<List<bool>> ink,
  ScanGlyphBox box, {
  double cellCoverage = 0.38,
  int glyphPad = 0,
  int maxDistance = maxScanGlyphDistance,
}) {
  final grid = resampleScanGlyph(
    ink,
    box,
    cellCoverage: cellCoverage,
    pad: glyphPad,
  );
  // 一格墨都没有 ⇒ 这不是字符（空白块）。**不能**匹配成空格模板：
  // OCR 里"空白"不是"空格字符"（243 轮踩到）。
  if (!grid.any((row) => row.any((on) => on))) {
    return ScanGlyphMatch(
      left: box.left,
      top: box.top,
      right: box.right,
      bottom: box.bottom,
      char: '?',
      confidence: 0,
    );
  }
  String? best;
  var bestDist = 1 << 30;
  var tied = false;
  kScanGlyphFont5x7.forEach((ch, rows) {
    var d = 0;
    for (var y = 0; y < kScanGlyphRows; y++) {
      for (var x = 0; x < kScanGlyphCols; x++) {
        final want = rows[y][x] == '#';
        if (want != grid[y][x]) d++;
      }
    }
    if (d < bestDist) {
      bestDist = d;
      best = ch;
      tied = false;
    } else if (d == bestDist) {
      tied = true;
    }
  });
  final unknown = best == null || bestDist > maxDistance || tied;
  final conf = unknown ? 0.0 : 1 - bestDist / (kScanGlyphRows * kScanGlyphCols);
  return ScanGlyphMatch(
    left: box.left,
    top: box.top,
    right: box.right,
    bottom: box.bottom,
    char: unknown ? '?' : best!,
    confidence: conf.toDouble(),
  );
}

/// [`classifyScanGlyph`] 的默认阈值（与 `ScanGlyphOcrEngine.maxDistance` 默认一致）。
const int maxScanGlyphDistance = 9;

/// 行（归一化框）→ 像素框。
ScanGlyphBox? _linePixelBox(ScanTextLine line, img.Image src) {
  final l = (line.left * src.width).floor().clamp(0, src.width - 1);
  final t = (line.top * src.height).floor().clamp(0, src.height - 1);
  final r = (line.right * src.width).ceil().clamp(0, src.width - 1);
  final b = (line.bottom * src.height).ceil().clamp(0, src.height - 1);
  if (r <= l || b <= t) return null;
  return ScanGlyphBox(l, t, r - 1, b - 1);
}

/// 字形之间的列间隙阈值（相对宽度，至少 1 像素）。
int _glyphGap(int width) => (width * 0.004).round().clamp(1, width);

/// 在给定像素框内按**列投影**切字形，再按"字形间距"归词，返回 `[词][字形]`。
///
/// 词界判据：相邻字形框的空隙 > `0.8 × 中位字形宽` ⇒ 断词。
/// （只看"固定像素间隙"会把手写字距不均的页切碎；用中位宽做尺度自适应。）
List<List<ScanGlyphBox>> _splitGlyphs(
  List<List<bool>> ink,
  ScanGlyphBox box, {
  required int gap,
}) {
  final cols = <bool>[];
  for (var x = box.left; x <= box.right; x++) {
    var has = false;
    for (var y = box.top; y <= box.bottom; y++) {
      if (ink[y][x]) {
        has = true;
        break;
      }
    }
    cols.add(has);
  }
  // ① 列投影 → 字形框（墨迹列连续段）
  final glyphs = <ScanGlyphBox>[];
  var runStart = -1;
  var runEnd = -1;
  var space = 0;
  void flush() {
    if (runStart < 0) return;
    final b = _inkBox(
      ink,
      box.left + runStart,
      box.left + runEnd,
      box.top,
      box.bottom,
    );
    if (b != null) glyphs.add(b);
    runStart = -1;
    runEnd = -1;
  }

  for (var i = 0; i < cols.length; i++) {
    if (cols[i]) {
      if (runStart < 0) runStart = i;
      runEnd = i;
      space = 0;
    } else {
      space++;
      if (runStart >= 0 && space >= gap) flush();
    }
  }
  flush();
  if (glyphs.isEmpty) return const [];

  // ② 归词：中位字形宽做尺度
  final widths = glyphs.map((g) => g.width).toList()..sort();
  final medianW = widths[widths.length ~/ 2].toDouble();
  final wordGap = (medianW * 0.8).clamp(2.0, double.infinity);
  final words = <List<ScanGlyphBox>>[];
  var current = <ScanGlyphBox>[];
  for (final g in glyphs) {
    if (current.isNotEmpty) {
      final prev = current.last;
      final gapPx = g.left - prev.right - 1;
      if (gapPx > wordGap) {
        words.add(current);
        current = <ScanGlyphBox>[];
      }
    }
    current.add(g);
  }
  if (current.isNotEmpty) words.add(current);
  return words;
}

/// 列区间内真实的墨迹行范围（字形高度由内容决定，不用整行高度）。
ScanGlyphBox? _inkBox(
  List<List<bool>> ink,
  int left,
  int right,
  int top,
  int bottom,
) {
  var t = -1;
  var b = -1;
  for (var y = top; y <= bottom; y++) {
    for (var x = left; x <= right; x++) {
      if (ink[y][x]) {
        if (t < 0) t = y;
        b = y;
        break;
      }
    }
  }
  if (t < 0 || b < 0) return null;
  return ScanGlyphBox(left, t, right, b);
}
