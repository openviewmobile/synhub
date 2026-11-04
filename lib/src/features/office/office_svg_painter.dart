// **自研 SVG 渲染器** —— `.oslides` 里的 `ppt/media/*.svg` 由本文件负责画出来。
//
// ## 为什么自研（而不是引三方包）
// 用户要求「所有格式都要支持，协议问题就采用自研的方式」。`.oslides`（标准 PPTX）
// 里的矢量图就是 `ppt/media/*.svg`，而 `pubspec.yaml` 本批禁改、仓库里也没有任何
// SVG 解码依赖 ⇒ **只能自研**：把 SVG 解析成 `Path` + 填充/描边描述，
// 再用 `CustomPainter` 画（不用 `Image`，不引三方包）。
//
// 本文件用的是仓库**已有**的 `package:xml/xml.dart` 做 XML 词法解析，
// **没有新增任何依赖**。
//
// ## 支持范围（**如实登记，不夸大**）
// * 路径命令：`M m L l H h V v C c S s Q q T t A a Z z`（含隐式重复参数、
//   科学计数法、`1.5.5` 这种省略分隔符的写法）；
// * `<g>` / `<a>` / 嵌套 `<svg>` 的属性继承：`fill`、`stroke`、`stroke-width`、
//   `fill-opacity`、`stroke-opacity`、`opacity`、`fill-rule`、
//   `stroke-linecap`、`stroke-linejoin`、`transform`；
// * `style="fill:#fff;stroke:#000"` 内联样式（优先级高于同名呈现属性，符合 CSS 规则）；
// * 基本形状：`<rect>`（含 `rx`/`ry` 圆角）、`<circle>`、`<ellipse>`、
//   `<line>`、`<polygon>`、`<polyline>`、`<path>`；
// * `viewBox` 缩放 + `preserveAspectRatio`（`none` 与 `xMin/xMid/xMax` ×
//   `YMin/YMid/YMax` 的 `meet`/`slice`）；
// * `transform`：`matrix translate scale rotate skewX skewY`（可串联）。
//
// ## 明确**不**支持（跳过，不假装）
// * `<title>` `<desc>` `<defs>` `<metadata>` `<style>` 一律忽略（**不渲染文字**）；
// * `<text>` / `<tspan>` 不渲染；
// * `<use>` / `<symbol>` / `<clipPath>` / `<mask>` / `<filter>` / `<marker>` 不解；
// * 渐变/图案（`fill="url(#grad)"`）**不解析** ⇒ 退化为**纯黑**填充（保证可见，不空白）；
// * `%` 长度按**裸数值**近似；CSS 类名/外部样式表不解析。
//
// ## 降级（硬要求）
// **任何**畸形输入（XML 不合法、空串、`d` 语法错误、NaN/Infinity 坐标、
// 巨大 viewBox、未知标签）都**只跳过**，**绝不抛异常**；整篇解析失败时
// [OfficeSvgDocument.isEmpty] 为 true，调用方**退回不画**（`SizedBox.shrink()`），
// 由 `.oslides` 阅读器决定是否出整页空态。
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:xml/xml.dart';

/// 一个媒体包内路径是不是**本渲染器支持**的 SVG（`*.svg`）。
///
/// `svgz`（gzip）与 `emf`/`wmf` 都**不在**支持范围内 —— 它们仍走"不画"降级。
bool isSvgMediaPart(String? part) {
  if (part == null) return false;
  return part.toLowerCase().endsWith('.svg');
}

/// 从包内字节解析 SVG（带缓存；渲染一页会调用多次，缓存避免重复解析）。
OfficeSvgDocument officeSvgDocumentFor(Uint8List bytes) {
  final cached = _documentCache[bytes];
  if (cached != null) return cached;
  final doc = OfficeSvgDocument.parse(_decode(bytes));
  _documentCache[bytes] = doc;
  return doc;
}

/// `Uint8List` 身份 → 解析结果（同一个 `deck.media` 字节对象只解析一次）。
final Expando<OfficeSvgDocument> _documentCache =
    Expando<OfficeSvgDocument>('officeSvgDocument');

String _decode(Uint8List bytes) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
    text = text.substring(1);
  }
  return text;
}

// ------------------------------------------------------------------ 模型

/// 一个**可直接绘制**的 SVG 图形：`Path` + 填充/描边 + 局部变换。
class OfficeSvgShape {
  OfficeSvgShape({
    required this.path,
    required this.subPathCount,
    required this.commandCount,
    required this.transform,
    this.fill,
    this.stroke,
    this.strokeWidth = 1,
    this.fillRule = PathFillType.nonZero,
    this.cap = StrokeCap.butt,
    this.join = StrokeJoin.miter,
  });

  /// 已解析的几何（在所在元素的用户坐标系里）。
  final Path path;

  /// 子路径数（每个 `M`/`m` 算一条；基本形状算 1 条）。
  final int subPathCount;

  /// 已执行的绘制命令数（`M L C Q A Z` … 各算 1）。
  final int commandCount;

  /// 该图形的局部 `transform`（根用户坐标系 → 图形坐标系）。
  final OfficeSvgMatrix transform;

  /// 填充色（**已含 `fill-opacity` 与 `opacity`**）；null = 不填充。
  final Color? fill;

  /// 描边色（**已含 `stroke-opacity` 与 `opacity`**）；null = 不描边。
  final Color? stroke;

  final double strokeWidth;
  final PathFillType fillRule;
  final StrokeCap cap;
  final StrokeJoin join;

  bool get isVisible =>
      (fill != null) || (stroke != null && strokeWidth > 0 && stroke!.a > 0);
}

/// 一篇**已解析**的 SVG（只含本渲染器支持的图形）。
class OfficeSvgDocument {
  const OfficeSvgDocument({
    required this.viewBox,
    required this.preserveAspectRatio,
    required this.shapes,
  });

  /// 用户坐标系里的可视区（`viewBox`；缺省时为 `0 0 width height`）。
  final Rect viewBox;

  /// `preserveAspectRatio` 原文（默认 `xMidYMid meet`）。
  final String preserveAspectRatio;

  final List<OfficeSvgShape> shapes;

  /// 空文档（解析失败 / 没有任何可绘制内容）。调用方据此**退回不画**。
  static const OfficeSvgDocument empty = OfficeSvgDocument(
    viewBox: Rect.zero,
    preserveAspectRatio: 'xMidYMid meet',
    shapes: <OfficeSvgShape>[],
  );

  bool get isEmpty => shapes.isEmpty;

  int get shapeCount => shapes.length;

  int get subPathCount =>
      shapes.fold(0, (sum, s) => sum + s.subPathCount);

  int get commandCount => shapes.fold(0, (sum, s) => sum + s.commandCount);

  /// 解析 SVG 源码。**任何失败都返回 [empty]，绝不抛异常。**
  static OfficeSvgDocument parse(String source) {
    if (source.trim().isEmpty) return empty;
    try {
      final doc = XmlDocument.parse(source);
      final root = _findSvgRoot(doc.rootElement);
      if (root == null) return empty;
      return _SvgParser(root).run();
    } catch (_) {
      return empty;
    }
  }
}

XmlElement? _findSvgRoot(XmlElement? root) {
  if (root == null) return null;
  if (root.name.local.toLowerCase() == 'svg') return root;
  for (final d in root.descendantElements) {
    if (d.name.local.toLowerCase() == 'svg') return d;
  }
  return null;
}

// ------------------------------------------------------------------ 解析器

const double _kPi = math.pi;

class _SvgParser {
  _SvgParser(this.root);

  final XmlElement root;
  final List<OfficeSvgShape> shapes = <OfficeSvgShape>[];

  OfficeSvgDocument run() {
    final viewBox = _readViewBox(root);
    final par =
        _prop(root, 'preserveAspectRatio') ?? 'xMidYMid meet';
    _walk(root, _SvgStyle.initial, OfficeSvgMatrix.identity, 0);
    return OfficeSvgDocument(
      viewBox: viewBox,
      preserveAspectRatio: par,
      shapes: List<OfficeSvgShape>.unmodifiable(shapes),
    );
  }

  Rect _readViewBox(XmlElement el) {
    final raw = _prop(el, 'viewBox');
    if (raw != null) {
      final parts = _numbers(raw);
      if (parts.length >= 4) {
        final r = Rect.fromLTWH(parts[0], parts[1], parts[2], parts[3]);
        if (_finiteRect(r) && r.width > 0 && r.height > 0) return r;
      }
    }
    final w = _len(_prop(el, 'width'));
    final h = _len(_prop(el, 'height'));
    if (w != null && h != null && w > 0 && h > 0) {
      return Rect.fromLTWH(0, 0, w, h);
    }
    return Rect.zero;
  }

  void _walk(XmlElement el, _SvgStyle inherited, OfficeSvgMatrix xf, int depth) {
    // 深度/数量硬上限：畸形/超深文档也不会拖垮渲染。
    if (depth > 64 || shapes.length > 20000) return;
    var name = el.name.local.toLowerCase();
    try {
      if (name == 'svg' || name == 'g' || name == 'a') {
        final style = inherited.resolve(el);
        final t = xf.multiply(_parseTransform(_prop(el, 'transform')));
        for (final child in el.childElements) {
          _walk(child, style, t, depth + 1);
        }
        return;
      }
      if (name == 'path' ||
          name == 'rect' ||
          name == 'circle' ||
          name == 'ellipse' ||
          name == 'line' ||
          name == 'polygon' ||
          name == 'polyline') {
        if (_prop(el, 'display')?.toLowerCase() == 'none') return;
        final visibility = _prop(el, 'visibility')?.toLowerCase();
        if (visibility == 'hidden' || visibility == 'collapse') return;
        final style = inherited.resolve(el);
        if (style.fill == null &&
            (style.stroke == null || style.strokeWidth <= 0)) {
          return; // 透明又无描边 → 不占位
        }
        final t = xf.multiply(_parseTransform(_prop(el, 'transform')));
        final built = _build(name, el);
        // 只有"真的画得出东西"才算：至少 1 条子路径 + 至少 1 条**绘制**命令
        // （只有 `M`/`Z` 的路径不产生任何像素，不能算"解析出来了"）。
        if (built == null || built.subPaths <= 0 || built.drawing <= 0) return;
        final fill = _applyOpacity(style.fill, style.fillOpacity * style.opacity);
        final stroke =
            _applyOpacity(style.stroke, style.strokeOpacity * style.opacity);
        if (fill == null && stroke == null) return;
        shapes.add(
          OfficeSvgShape(
            path: built.path..fillType = style.fillRule,
            subPathCount: built.subPaths,
            commandCount: built.commands,
            transform: t,
            fill: fill,
            stroke: stroke,
            strokeWidth: style.strokeWidth,
            fillRule: style.fillRule,
            cap: style.cap,
            join: style.join,
          ),
        );
        return;
      }
      // title / desc / defs / metadata / style / use / text / … → 跳过。
    } catch (_) {
      // 单个元素出错只跳过该元素，绝不让整篇变空或抛出。
    }
    // 未识别的元素仍下钻（有些导出会把图形包在非标准容器里）。
    if (name != 'defs' && name != 'clippath' && name != 'mask') {
      final t = xf.multiply(_parseTransform(_prop(el, 'transform')));
      for (final child in el.childElements) {
        _walk(child, inherited, t, depth + 1);
      }
    }
  }

  _BuiltPath? _build(String name, XmlElement el) {
    switch (name) {
      case 'path':
        final d = _prop(el, 'd');
        if (d == null || d.trim().isEmpty) return null;
        return _parsePathData(d);
      case 'rect':
        final x = _len(_prop(el, 'x')) ?? 0;
        final y = _len(_prop(el, 'y')) ?? 0;
        final w = _len(_prop(el, 'width'));
        final h = _len(_prop(el, 'height'));
        if (w == null || h == null || w <= 0 || h <= 0) return null;
        final path = Path();
        final rx = _len(_prop(el, 'rx'));
        final ry = _len(_prop(el, 'ry'));
        final rxr = math.min(rx ?? ry ?? 0, w / 2);
        final ryr = math.min(ry ?? rx ?? 0, h / 2);
        if (rxr > 0 && ryr > 0) {
          path.addRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, y, w, h),
              Radius.elliptical(rxr, ryr),
            ),
          );
        } else {
          path.addRect(Rect.fromLTWH(x, y, w, h));
        }
        return _BuiltPath(path, 1, 1, 1);
      case 'circle':
        final cx = _len(_prop(el, 'cx')) ?? 0;
        final cy = _len(_prop(el, 'cy')) ?? 0;
        final r = _len(_prop(el, 'r'));
        if (r == null || r <= 0) return null;
        final path = Path()
          ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
        return _BuiltPath(path, 1, 1, 1);
      case 'ellipse':
        final cx = _len(_prop(el, 'cx')) ?? 0;
        final cy = _len(_prop(el, 'cy')) ?? 0;
        final rx = _len(_prop(el, 'rx'));
        final ry = _len(_prop(el, 'ry'));
        if (rx == null || ry == null || rx <= 0 || ry <= 0) return null;
        final path = Path()
          ..addOval(
            Rect.fromCenter(
              center: Offset(cx, cy),
              width: rx * 2,
              height: ry * 2,
            ),
          );
        return _BuiltPath(path, 1, 1, 1);
      case 'line':
        final x1 = _len(_prop(el, 'x1')) ?? 0;
        final y1 = _len(_prop(el, 'y1')) ?? 0;
        final x2 = _len(_prop(el, 'x2')) ?? 0;
        final y2 = _len(_prop(el, 'y2')) ?? 0;
        final path = Path()
          ..moveTo(x1, y1)
          ..lineTo(x2, y2);
        return _BuiltPath(path, 1, 2, 2);
      case 'polygon':
      case 'polyline':
        final pts = _numbers(_prop(el, 'points') ?? '');
        if (pts.length < 4) return null;
        final path = Path();
        path.moveTo(pts[0], pts[1]);
        var commands = 1;
        for (var i = 2; i + 1 < pts.length; i += 2) {
          path.lineTo(pts[i], pts[i + 1]);
          commands++;
        }
        if (name == 'polygon') {
          path.close();
          commands++;
        }
        return _BuiltPath(path, 1, commands, commands);
    }
    return null;
  }
}

class _BuiltPath {
  _BuiltPath(this.path, this.subPaths, this.commands, this.drawing);
  final Path path;
  final int subPaths;
  final int commands;

  /// **绘制**命令数（不含 `M`；`L/C/Q/A/Z` 都算）。只有 `M` 的路径画不出像素。
  final int drawing;
}

// ------------------------------------------------------------- 路径数据解析

/// 解析 `d`。畸形输入**返回已解析的部分**（绝不抛异常）。
_BuiltPath _parsePathData(String d) {
  final path = Path();
  final scan = _Scanner(d);
  var subPaths = 0;
  var commands = 0;
  var closes = 0;
  var curX = 0.0, curY = 0.0, startX = 0.0, startY = 0.0;
  double? lastC2x, lastC2y, lastQx, lastQy;
  String? prev;
  String? cmd;

  outer:
  while (true) {
    scan.skipSep();
    if (scan.atEnd) break;
    final letter = scan.peekCommandLetter();
    if (letter != null) {
      scan.advance();
      cmd = letter;
    }
    if (cmd == null) {
      scan.advance();
      continue;
    }
    if (commands > 5000000) break;
    final rel = cmd == cmd.toLowerCase();
    final up = cmd.toUpperCase();

    switch (up) {
      case 'M':
      case 'L':
        final x = scan.number();
        final y = scan.number();
        if (x == null || y == null) break outer;
        final px = rel ? curX + x : x;
        final py = rel ? curY + y : y;
        if (!_finite(px) || !_finite(py)) break outer;
        if (up == 'M') {
          path.moveTo(px, py);
          subPaths++;
          startX = px;
          startY = py;
        } else {
          path.lineTo(px, py);
        }
        curX = px;
        curY = py;
        commands++;
        prev = up;
        // M 后续的隐式坐标对按 L 处理（SVG 规范）。
        if (up == 'M') cmd = rel ? 'l' : 'L';
        break;
      case 'H':
        final x = scan.number();
        if (x == null) break outer;
        final px = rel ? curX + x : x;
        if (!_finite(px)) break outer;
        path.lineTo(px, curY);
        curX = px;
        commands++;
        prev = up;
        break;
      case 'V':
        final y = scan.number();
        if (y == null) break outer;
        final py = rel ? curY + y : y;
        if (!_finite(py)) break outer;
        path.lineTo(curX, py);
        curY = py;
        commands++;
        prev = up;
        break;
      case 'C':
        final x1 = scan.number();
        final y1 = scan.number();
        final x2 = scan.number();
        final y2 = scan.number();
        final x = scan.number();
        final y = scan.number();
        if (x1 == null || y1 == null || x2 == null || y2 == null ||
            x == null || y == null) {
          break outer;
        }
        final c1x = rel ? curX + x1 : x1;
        final c1y = rel ? curY + y1 : y1;
        final c2x = rel ? curX + x2 : x2;
        final c2y = rel ? curY + y2 : y2;
        final px = rel ? curX + x : x;
        final py = rel ? curY + y : y;
        if (!_finite(c1x) || !_finite(c1y) || !_finite(c2x) || !_finite(c2y) ||
            !_finite(px) || !_finite(py)) {
          break outer;
        }
        path.cubicTo(c1x, c1y, c2x, c2y, px, py);
        lastC2x = c2x;
        lastC2y = c2y;
        curX = px;
        curY = py;
        commands++;
        prev = up;
        break;
      case 'S':
        final x2 = scan.number();
        final y2 = scan.number();
        final x = scan.number();
        final y = scan.number();
        if (x2 == null || y2 == null || x == null || y == null) break outer;
        final c2x = rel ? curX + x2 : x2;
        final c2y = rel ? curY + y2 : y2;
        final px = rel ? curX + x : x;
        final py = rel ? curY + y : y;
        if (!_finite(c2x) || !_finite(c2y) || !_finite(px) || !_finite(py)) {
          break outer;
        }
        final c1x = (prev == 'C' || prev == 'S') && lastC2x != null
            ? 2 * curX - lastC2x
            : curX;
        final c1y = (prev == 'C' || prev == 'S') && lastC2y != null
            ? 2 * curY - lastC2y
            : curY;
        path.cubicTo(c1x, c1y, c2x, c2y, px, py);
        lastC2x = c2x;
        lastC2y = c2y;
        curX = px;
        curY = py;
        commands++;
        prev = up;
        break;
      case 'Q':
        final x1 = scan.number();
        final y1 = scan.number();
        final x = scan.number();
        final y = scan.number();
        if (x1 == null || y1 == null || x == null || y == null) break outer;
        final c1x = rel ? curX + x1 : x1;
        final c1y = rel ? curY + y1 : y1;
        final px = rel ? curX + x : x;
        final py = rel ? curY + y : y;
        if (!_finite(c1x) || !_finite(c1y) || !_finite(px) || !_finite(py)) {
          break outer;
        }
        path.quadraticBezierTo(c1x, c1y, px, py);
        lastQx = c1x;
        lastQy = c1y;
        curX = px;
        curY = py;
        commands++;
        prev = up;
        break;
      case 'T':
        final x = scan.number();
        final y = scan.number();
        if (x == null || y == null) break outer;
        final px = rel ? curX + x : x;
        final py = rel ? curY + y : y;
        if (!_finite(px) || !_finite(py)) break outer;
        final c1x = (prev == 'Q' || prev == 'T') && lastQx != null
            ? 2 * curX - lastQx
            : curX;
        final c1y = (prev == 'Q' || prev == 'T') && lastQy != null
            ? 2 * curY - lastQy
            : curY;
        path.quadraticBezierTo(c1x, c1y, px, py);
        lastQx = c1x;
        lastQy = c1y;
        curX = px;
        curY = py;
        commands++;
        prev = up;
        break;
      case 'A':
        final rx = scan.number();
        final ry = scan.number();
        final rot = scan.number();
        final large = scan.number();
        final sweep = scan.number();
        final x = scan.number();
        final y = scan.number();
        if (rx == null || ry == null || rot == null || large == null ||
            sweep == null || x == null || y == null) {
          break outer;
        }
        final px = rel ? curX + x : x;
        final py = rel ? curY + y : y;
        if (!_finite(px) || !_finite(py)) break outer;
        final arx = rx.abs();
        final ary = ry.abs();
        if (arx <= 0 || ary <= 0) {
          path.lineTo(px, py);
        } else {
          try {
            path.arcToPoint(
              Offset(px, py),
              radius: Radius.elliptical(arx, ary),
              rotation: rot * _kPi / 180,
              largeArc: large != 0,
              clockwise: sweep != 0,
            );
          } catch (_) {
            path.lineTo(px, py);
          }
        }
        curX = px;
        curY = py;
        commands++;
        prev = up;
        break;
      case 'Z':
        path.close();
        curX = startX;
        curY = startY;
        commands++;
        closes++;
        prev = up;
        cmd = null; // Z 不带参数，避免隐式重复导致死循环
        break;
      default:
        // 未知命令字母：丢弃该字母后继续，绝不抛异常。
        cmd = null;
        break;
    }
  }
  // `subPaths` = `M`/`m` 数、`closes` = `Z`/`z` 数；两者都不产生像素，
  // 减去它们才是"真正绘制"的命令数（只有 `M Z` 的路径画不出任何东西）。
  return _BuiltPath(path, subPaths, commands, commands - subPaths - closes);
}

/// SVG 数字扫描器。
class _Scanner {
  _Scanner(this.s);
  final String s;
  int i = 0;

  bool get atEnd => i >= s.length;

  void advance() => i++;

  void skipSep() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x2C) {
        i++;
      } else {
        break;
      }
    }
  }

  String? peekCommandLetter() {
    skipSep();
    if (atEnd) return null;
    final c = s[i];
    if ((c.codeUnitAt(0) >= 0x41 && c.codeUnitAt(0) <= 0x5A) ||
        (c.codeUnitAt(0) >= 0x61 && c.codeUnitAt(0) <= 0x7A)) {
      return c;
    }
    return null;
  }

  double? number() {
    skipSep();
    if (atEnd) return null;
    final start = i;
    if (s[i] == '+' || s[i] == '-') i++;
    var sawDigit = false;
    while (i < s.length && _isDigit(s.codeUnitAt(i))) {
      i++;
      sawDigit = true;
    }
    if (i < s.length && s[i] == '.') {
      i++;
      while (i < s.length && _isDigit(s.codeUnitAt(i))) {
        i++;
        sawDigit = true;
      }
    }
    if (!sawDigit) {
      i = start;
      return null;
    }
    if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
      final expStart = i;
      i++;
      if (i < s.length && (s[i] == '+' || s[i] == '-')) i++;
      var expDigit = false;
      while (i < s.length && _isDigit(s.codeUnitAt(i))) {
        i++;
        expDigit = true;
      }
      if (!expDigit) i = expStart;
    }
    final v = double.tryParse(s.substring(start, i));
    if (v == null || !v.isFinite) {
      i = start;
      return null;
    }
    return v;
  }
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

// ---------------------------------------------------------------- 样式/颜色

class _SvgStyle {
  const _SvgStyle({
    required this.fill,
    required this.stroke,
    required this.strokeWidth,
    required this.fillOpacity,
    required this.strokeOpacity,
    required this.opacity,
    required this.fillRule,
    required this.cap,
    required this.join,
  });

  final Color? fill;
  final Color? stroke;
  final double strokeWidth;
  final double fillOpacity;
  final double strokeOpacity;
  final double opacity;
  final PathFillType fillRule;
  final StrokeCap cap;
  final StrokeJoin join;

  /// SVG 默认：填充**黑**、无描边、1px 描边宽、不透明、`nonzero`。
  static const _SvgStyle initial = _SvgStyle(
    fill: Color(0xFF000000),
    stroke: null,
    strokeWidth: 1,
    fillOpacity: 1,
    strokeOpacity: 1,
    opacity: 1,
    fillRule: PathFillType.nonZero,
    cap: StrokeCap.butt,
    join: StrokeJoin.miter,
  );

  _SvgStyle resolve(XmlElement el) {
    var f = fill;
    final rawFill = _prop(el, 'fill');
    if (rawFill != null) f = _paintColor(rawFill);

    var s = stroke;
    final rawStroke = _prop(el, 'stroke');
    if (rawStroke != null) s = _paintColor(rawStroke);

    var sw = strokeWidth;
    final rawSw = _len(_prop(el, 'stroke-width'));
    if (rawSw != null && rawSw >= 0) sw = rawSw;

    final fo = _clamp01(_len(_prop(el, 'fill-opacity')) ?? fillOpacity);
    final so = _clamp01(_len(_prop(el, 'stroke-opacity')) ?? strokeOpacity);
    final op = _clamp01(_len(_prop(el, 'opacity')) ?? opacity);

    var rule = fillRule;
    if (_prop(el, 'fill-rule')?.toLowerCase() == 'evenodd') {
      rule = PathFillType.evenOdd;
    } else if (_prop(el, 'fill-rule')?.toLowerCase() == 'nonzero') {
      rule = PathFillType.nonZero;
    }

    var c = cap;
    switch (_prop(el, 'stroke-linecap')?.toLowerCase()) {
      case 'round':
        c = StrokeCap.round;
      case 'square':
        c = StrokeCap.square;
      case 'butt':
        c = StrokeCap.butt;
    }
    var j = join;
    switch (_prop(el, 'stroke-linejoin')?.toLowerCase()) {
      case 'round':
        j = StrokeJoin.round;
      case 'bevel':
        j = StrokeJoin.bevel;
      case 'miter':
        j = StrokeJoin.miter;
    }

    return _SvgStyle(
      fill: f,
      stroke: s,
      strokeWidth: sw,
      fillOpacity: fo,
      strokeOpacity: so,
      opacity: op,
      fillRule: rule,
      cap: c,
      join: j,
    );
  }
}

/// 呈现属性 / 内联 `style` 取值。**内联样式优先**（CSS 规则）。
String? _prop(XmlElement el, String name) {
  final style = el.getAttribute('style');
  if (style != null && style.contains(':')) {
    for (final decl in style.split(';')) {
      final idx = decl.indexOf(':');
      if (idx <= 0) continue;
      if (decl.substring(0, idx).trim().toLowerCase() == name) {
        final v = decl.substring(idx + 1).trim();
        if (v.isNotEmpty) return v;
      }
    }
  }
  final v = el.getAttribute(name);
  final t = v?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// `fill`/`stroke` 取值 → 颜色。
/// * `none` / `transparent` → null（不画）；
/// * `url(#…)`（渐变/图案，未解析）与 `currentColor` → **退化为纯黑**（保证可见）；
/// * 无法识别的值 → 黑（而不是空白）。
Color? _paintColor(String raw) {
  final v = raw.trim().toLowerCase();
  if (v == 'none' || v == 'transparent') return null;
  if (v.startsWith('url(') || v == 'currentcolor') {
    return const Color(0xFF000000);
  }
  return _parseColor(v) ?? const Color(0xFF000000);
}

Color? _parseColor(String v) {
  if (v.startsWith('#')) {
    var hex = v.substring(1);
    if (hex.length == 3 || hex.length == 4) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length == 6) return _fromHex(hex, 255);
    if (hex.length == 8) {
      // SVG #RRGGBBAA（前 6 位色、后 2 位 alpha）。
      final a = int.tryParse(hex.substring(6, 8), radix: 16);
      return _fromHex(hex.substring(0, 6), a ?? 255);
    }
    return null;
  }
  final rgb = RegExp(
    r'^rgba?\(([^)]*)\)$',
  ).firstMatch(v);
  if (rgb != null) {
    final parts = _numbers(rgb.group(1)!);
    if (parts.length >= 3) {
      final r = parts[0].clamp(0, 255).round();
      final g = parts[1].clamp(0, 255).round();
      final b = parts[2].clamp(0, 255).round();
      var a = 255;
      if (parts.length >= 4) {
        final av = parts[3];
        a = (av <= 1 ? av * 255 : av).clamp(0, 255).round();
      }
      return Color.fromARGB(a, r, g, b);
    }
  }
  return _namedColors[v];
}

Color _fromHex(String hex, int alpha) {
  final v = int.tryParse(hex, radix: 16);
  if (v == null) return const Color(0xFF000000);
  return Color.fromARGB(
    alpha,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  );
}

Color? _applyOpacity(Color? c, double opacity) {
  if (c == null) return null;
  final a = _clamp01(c.a * _clamp01(opacity));
  return c.withValues(alpha: a);
}

double _clamp01(double v) {
  if (!v.isFinite) return 1;
  return v.clamp(0.0, 1.0);
}

/// 常用颜色名（覆盖绝大多数图标 SVG；未列出的名字退化为黑）。
const Map<String, Color> _namedColors = <String, Color>{
  'black': Color(0xFF000000),
  'white': Color(0xFFFFFFFF),
  'red': Color(0xFFFF0000),
  'green': Color(0xFF008000),
  'blue': Color(0xFF0000FF),
  'yellow': Color(0xFFFFFF00),
  'gray': Color(0xFF808080),
  'grey': Color(0xFF808080),
  'silver': Color(0xFFC0C0C0),
  'orange': Color(0xFFFFA500),
  'purple': Color(0xFF800080),
  'navy': Color(0xFF000080),
  'teal': Color(0xFF008080),
  'olive': Color(0xFF808000),
  'maroon': Color(0xFF800000),
  'lime': Color(0xFF00FF00),
  'aqua': Color(0xFF00FFFF),
  'cyan': Color(0xFF00FFFF),
  'fuchsia': Color(0xFFFF00FF),
  'magenta': Color(0xFFFF00FF),
};

// ------------------------------------------------------------------ 变换

/// 2D 仿射变换（`[a c e; b d f]`）。
///
/// 之所以公开而不是私有：它是 [OfficeSvgShape.transform] 的类型，
/// 出现在公共 API 签名里（分析器的 `library_private_types_in_public_api`）。
class OfficeSvgMatrix {
  const OfficeSvgMatrix(this.a, this.b, this.c, this.d, this.e, this.f);

  static const OfficeSvgMatrix identity = OfficeSvgMatrix(1, 0, 0, 1, 0, 0);

  final double a, b, c, d, e, f;

  bool get isIdentity =>
      a == 1 && b == 0 && c == 0 && d == 1 && e == 0 && f == 0;

  /// `this ∘ o`（先应用 `o`，再应用 `this`）。
  OfficeSvgMatrix multiply(OfficeSvgMatrix o) => OfficeSvgMatrix(
    a * o.a + c * o.b,
    b * o.a + d * o.b,
    a * o.c + c * o.d,
    b * o.c + d * o.d,
    a * o.e + c * o.f + e,
    b * o.e + d * o.f + f,
  );

  /// 4x4 列主序（`Path.transform` / `Canvas.transform` 要的格式）。
  Float64List get storage => Float64List.fromList(<double>[
    a, b, 0, 0, //
    c, d, 0, 0, //
    e, f, 1, 0, //
    0, 0, 0, 1, //
  ]);
}

final RegExp _transformRe = RegExp(r'([a-zA-Z]+)\s*\(([^)]*)\)');

OfficeSvgMatrix _parseTransform(String? raw) {
  if (raw == null || raw.trim().isEmpty) return OfficeSvgMatrix.identity;
  var m = OfficeSvgMatrix.identity;
  try {
    for (final match in _transformRe.allMatches(raw)) {
      final name = match.group(1)!.toLowerCase();
      final args = _numbers(match.group(2)!);
      switch (name) {
        case 'matrix':
          if (args.length >= 6) {
            m = m.multiply(OfficeSvgMatrix(args[0], args[1], args[2], args[3], args[4], args[5]));
          }
        case 'translate':
          final tx = args.isNotEmpty ? args[0] : 0.0;
          final ty = args.length > 1 ? args[1] : 0.0;
          m = m.multiply(OfficeSvgMatrix(1, 0, 0, 1, tx, ty));
        case 'scale':
          final sx = args.isNotEmpty ? args[0] : 1.0;
          final sy = args.length > 1 ? args[1] : sx;
          m = m.multiply(OfficeSvgMatrix(sx, 0, 0, sy, 0, 0));
        case 'rotate':
          final deg = args.isNotEmpty ? args[0] : 0.0;
          final rad = deg * _kPi / 180;
          final cos = math.cos(rad), sin = math.sin(rad);
          final r = OfficeSvgMatrix(cos, sin, -sin, cos, 0, 0);
          if (args.length >= 3) {
            final cx = args[1], cy = args[2];
            m = m
                .multiply(OfficeSvgMatrix(1, 0, 0, 1, cx, cy))
                .multiply(r)
                .multiply(OfficeSvgMatrix(1, 0, 0, 1, -cx, -cy));
          } else {
            m = m.multiply(r);
          }
        case 'skewx':
          final deg = args.isNotEmpty ? args[0] : 0.0;
          m = m.multiply(OfficeSvgMatrix(1, 0, math.tan(deg * _kPi / 180), 1, 0, 0));
        case 'skewy':
          final deg = args.isNotEmpty ? args[0] : 0.0;
          m = m.multiply(OfficeSvgMatrix(1, math.tan(deg * _kPi / 180), 0, 1, 0, 0));
        default:
          break;
      }
    }
  } catch (_) {
    return OfficeSvgMatrix.identity;
  }
  return m;
}

// ------------------------------------------------------------------ 绘制

/// 把 [document] 画进 `size`：`viewBox` → `size` 等比/拉伸映射 + 形状绘制。
class OfficeSvgPainter extends CustomPainter {
  const OfficeSvgPainter(this.document);

  final OfficeSvgDocument document;

  @override
  void paint(Canvas canvas, Size size) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0 ||
        document.isEmpty) {
      return;
    }
    final matrix = _viewMatrix(size);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final shape in document.shapes) {
      if (!shape.isVisible) continue;
      final m = matrix.multiply(shape.transform);
      canvas.save();
      if (!m.isIdentity) canvas.transform(m.storage);
      final fill = shape.fill;
      if (fill != null && fill.a > 0) {
        canvas.drawPath(
          shape.path,
          Paint()
            ..style = PaintingStyle.fill
            ..color = fill
            ..isAntiAlias = true,
        );
      }
      final stroke = shape.stroke;
      if (stroke != null && stroke.a > 0 && shape.strokeWidth > 0) {
        canvas.drawPath(
          shape.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = stroke
            ..strokeWidth = shape.strokeWidth
            ..strokeCap = shape.cap
            ..strokeJoin = shape.join
            ..isAntiAlias = true,
        );
      }
      canvas.restore();
    }
    canvas.restore();
  }

  /// `viewBox` → 目标尺寸的映射（含 `preserveAspectRatio`）。
  OfficeSvgMatrix _viewMatrix(Size size) {
    final vb = document.viewBox;
    if (!vb.width.isFinite || !vb.height.isFinite ||
        vb.width <= 0 || vb.height <= 0) {
      return OfficeSvgMatrix.identity; // 没有可用 viewBox：按原始坐标画
    }
    final sx = size.width / vb.width;
    final sy = size.height / vb.height;
    final par = document.preserveAspectRatio.trim().toLowerCase();
    if (par.startsWith('none')) {
      return OfficeSvgMatrix(sx, 0, 0, sy, -vb.left * sx, -vb.top * sy);
    }
    final slice = par.contains('slice');
    final scale = slice ? math.max(sx, sy) : math.min(sx, sy);
    final align = _parseAlign(par);
    final freeX = size.width - vb.width * scale;
    final freeY = size.height - vb.height * scale;
    return OfficeSvgMatrix(
      scale,
      0,
      0,
      scale,
      -vb.left * scale + freeX * align.$1,
      -vb.top * scale + freeY * align.$2,
    );
  }

  /// `xMidYMid` → `(0.5, 0.5)`；`xMin`→0，`xMax`→1。
  (double, double) _parseAlign(String par) {
    var fx = 0.5, fy = 0.5;
    final first = par.split(RegExp(r'\s+')).first;
    final x = RegExp(r'x(Min|Mid|Max)').firstMatch(first);
    final y = RegExp(r'Y(Min|Mid|Max)').firstMatch(first);
    if (x != null) {
      switch (x.group(1)) {
        case 'Min':
          fx = 0;
        case 'Max':
          fx = 1;
        default:
          fx = 0.5;
      }
    }
    if (y != null) {
      switch (y.group(1)) {
        case 'Min':
          fy = 0;
        case 'Max':
          fy = 1;
        default:
          fy = 0.5;
      }
    }
    return (fx, fy);
  }

  @override
  bool shouldRepaint(OfficeSvgPainter oldDelegate) =>
      !identical(oldDelegate.document, document);
}

/// 便捷 widget：把一篇 SVG 填满可用空间（`.oslides` 里的图片形状用它）。
class OfficeSvgView extends StatelessWidget {
  const OfficeSvgView({super.key, required this.document});

  final OfficeSvgDocument document;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: OfficeSvgPainter(document),
      child: const SizedBox.expand(),
    );
  }
}

// ------------------------------------------------------------------ 小工具

bool _finite(double v) => v.isFinite;

bool _finiteRect(Rect r) =>
    r.left.isFinite &&
    r.top.isFinite &&
    r.width.isFinite &&
    r.height.isFinite;

double? _len(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?').firstMatch(raw);
  if (m == null) return null;
  final v = double.tryParse(m.group(0)!);
  if (v == null || !v.isFinite) return null;
  return v;
}

/// 抽出一串数字（空格/逗号分隔）。
List<double> _numbers(String raw) {
  final out = <double>[];
  for (final m in RegExp(r'[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?')
      .allMatches(raw)) {
    final v = double.tryParse(m.group(0)!);
    if (v != null && v.isFinite) out.add(v);
  }
  return out;
}
