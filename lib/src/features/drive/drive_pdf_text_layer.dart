// ★★★ ③Drive **D61 最后一项：文字层联动** —— 第 245 轮：**自研 PDF 文本层抽取**。
//
// ## 为什么要自己抽
// "框选文字再高亮"要的是**字形坐标**：选中哪些字、每个字的框在哪，才能写出
// 规范的 `/Highlight` + `/QuadPoints`（按行给四边形），而不是拿一个粗略矩形充数。
// 本仓不引 PDF 引擎（`pdf` 只能写、`pdfrx` 只读渲染不给字形），所以这里自己抽：
//
//   ① 扫对象 → 找页对象（`/MediaBox`、`/Contents`、`/Resources /Font`）；
//   ② 解内容流（`/FlateDecode` → zlib）；
//   ③ 解释文本算子：`BT/ET`、`Tf`、`Td/TD/Tm/T*`、`Tj/TJ/'/"`、`Tc/Tw/Tz/TL`、
//      `q/Q/cm`（矩阵按 2D 仿射乘），用**字体宽度表**（`/FirstChar`+`/Widths`
//      +`/MissingWidth`）逐字推进；
//   ④ 按基线把 run 聚成**行**，给出**归一化、左上原点**的框与文本
//      （与批注模型同一坐标系，便于直接联动）。
//
// ## 能到什么程度（如实写清）
// * **能**：简单字体（Type1/TrueType + `/Widths`）的中/西文**定位**——
//   坐标是按宽度表算的，与渲染无关；我们导出的 PDF、官方 App 的 PDF 都属这一类；
// * **不能**：字体在**对象流**里、CID/Type0 复合字体（无 `/Widths`，
//   要走 `/W` + CMap）、内容流用 LZW/其他滤镜、Type3 位图字体。
//   这些情况**如实返回 `parsed=false` 并写明原因**，绝不猜坐标。
// * 说明：`.so`/引擎级排版（连字、竖排）不在范围内。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' as arch;

import 'drive_gaps_text.dart';

/// 一段文字（同一行）的归一化框 + 文本。左上原点，与批注模型一致。
class PdfTextSpan {
  const PdfTextSpan({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get centerY => (top + bottom) / 2;

  bool intersects(double l, double t, double r, double b) =>
      right > l && left < r && bottom > t && top < b;

  Map<String, Object?> toJson() => {
    'text': text,
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };
}

/// 一页的文本层。
class PdfTextLayerPage {
  const PdfTextLayerPage({
    required this.page,
    required this.spans,
    required this.parsed,
    this.reason = '',
  });

  final int page;
  final List<PdfTextSpan> spans;

  /// **是否真的解析成功**。`false` 时 `spans` 必为空 —— 绝不猜。
  final bool parsed;

  /// `parsed=false` 的原因（给 UI/日志）
  final String reason;

  static PdfTextLayerPage unparsed(int page, String reason) =>
      PdfTextLayerPage(page: page, spans: const [], parsed: false, reason: reason);

  Map<String, Object?> toJson() => {
    'page': page,
    'parsed': parsed,
    'reason': reason,
    'spans': [for (final s in spans) s.toJson()],
  };
}

/// 整个文档的文本层。
class PdfTextLayer {
  const PdfTextLayer({required this.pages, this.width = 0, this.height = 0});

  const PdfTextLayer.empty() : pages = const [], width = 0, height = 0;

  final List<PdfTextLayerPage> pages;
  final double width;
  final double height;

  bool get anyParsed => pages.any((p) => p.parsed);

  int get spanCount => pages.fold(0, (a, p) => a + p.spans.length);
}

/// 抽取失败（不是 PDF / 结构不认识）时的说明型异常。
class PdfTextLayerException implements Exception {
  const PdfTextLayerException(this.message);
  final String message;
  @override
  String toString() => 'PdfTextLayerException: $message';
}

// ───────────────────────────── 矩阵 ─────────────────────────────

/// 2D 仿射 `[a,b,c,d,e,f]`（PDF 约定）。
class _Mat {
  const _Mat(this.a, this.b, this.c, this.d, this.e, this.f);
  static const identity = _Mat(1, 0, 0, 1, 0, 0);
  final double a, b, c, d, e, f;

  /// `this × m`（PDF 里 `cm` 是"先应用参数、再应用当前 CTM"）
  _Mat mul(_Mat m) => _Mat(
    a * m.a + b * m.c,
    a * m.b + b * m.d,
    c * m.a + d * m.c,
    c * m.b + d * m.d,
    e * m.a + f * m.c + m.e,
    e * m.b + f * m.d + m.f,
  );

  double x(double px, double py) => a * px + c * py + e;
  double y(double px, double py) => b * px + d * py + f;

  /// 平移矩阵
  static _Mat translate(double tx, double ty) => _Mat(1, 0, 0, 1, tx, ty);

  double get scaleX => _hypot(a, b);
  double get scaleY => _hypot(c, d);
}

double _hypot(double x, double y) {
  final s = x * x + y * y;
  return s <= 0 ? 0 : s.isFinite ? _sqrt(s) : 0;
}

double _sqrt(double v) {
  if (v <= 0) return 0;
  var x = v;
  var y = 1.0;
  for (var i = 0; i < 32; i++) {
    y = (x + v / x) / 2;
    x = y;
  }
  return x;
}

// ───────────────────────── PDF 对象扫描 ─────────────────────────

class _Obj {
  const _Obj(this.number, this.offset, this.bodyEnd, this.dict, this.stream);
  final int number;
  final int offset;
  final int bodyEnd;
  final String dict;
  final List<int>? stream;
}

class _Doc {
  _Doc(this.text, this.bytes, this.objects, this.pageObjects);
  final String text;
  final Uint8List bytes;
  final Map<int, _Obj> objects;
  final List<int> pageObjects;
}

_Doc _openPdf(Uint8List bytes) {
  final text = latin1.decode(bytes, allowInvalid: true);
  if (!text.startsWith('%PDF-')) {
    throw const PdfTextLayerException('不是 PDF（缺少 %PDF- 头）');
  }
  final reObj = RegExp(r'^(\d{1,9})\s+(\d{1,5})\s+obj\b', multiLine: true);
  final objects = <int, _Obj>{};
  for (final m in reObj.allMatches(text)) {
    final n = int.parse(m.group(1)!);
    final headerEnd = text.indexOf('obj', m.start) + 3;
    final streamIdx = text.indexOf(RegExp(r'\bstream\b'), headerEnd);
    final endObjIdx = text.indexOf(RegExp(r'\bendobj\b'), headerEnd);
    final dictEnd = streamIdx >= 0 && (endObjIdx < 0 || streamIdx < endObjIdx)
        ? streamIdx
        : (endObjIdx >= 0 ? endObjIdx : text.length);
    final dict = text.substring(headerEnd, dictEnd);
    List<int>? stream;
    if (streamIdx >= 0 && (endObjIdx < 0 || streamIdx < endObjIdx)) {
      // stream 关键字后：CRLF 或 LF
      var s = streamIdx + 'stream'.length;
      if (text.startsWith('\r\n', s)) {
        s += 2;
      } else if (s < text.length && (text[s] == '\n' || text[s] == '\r')) {
        s += 1;
      }
      final lenMatch = RegExp(r'/Length\s+(\d+)').firstMatch(dict);
      final declared = lenMatch == null ? -1 : int.parse(lenMatch.group(1)!);
      var e = s + (declared >= 0 ? declared : 0);
      if (declared < 0 || e > bytes.length) e = bytes.length;
      stream = bytes.sublist(s, e);
    }
    objects[n] = _Obj(n, m.start, dictEnd, dict, stream);
  }
  final pages = <int>[];
  objects.forEach((n, o) {
    if (RegExp(r'/Type\s*/Page\b').hasMatch(o.dict) &&
        !RegExp(r'/Type\s*/Pages\b').hasMatch(o.dict)) {
      pages.add(n);
    }
  });
  return _Doc(text, bytes, objects, pages);
}

// ───────────────────────── 内容流解释 ─────────────────────────

class _Glyph {
  _Glyph(this.text, this.left, this.top, this.right, this.bottom);
  final String text;
  final double left, top, right, bottom;
  double get centerY => (top + bottom) / 2;
}

/// 字体：宽度表（1/1000 单位）。
class _Font {
  _Font(this.name, this.widths, this.firstChar, this.missingWidth, this.subtype);
  final String name;
  final List<double> widths;
  final int firstChar;
  final double missingWidth;
  final String subtype;

  /// 字体字典里**是否真的给了宽度表**。没有就别拿 missingWidth 硬算 ——
  /// CID/Type0 复合字体的宽度在 `/W` + CMap 里，硬算出来的框是**猜的**。
  bool get hasWidths => widths.isNotEmpty;

  double widthOf(int code) {
    final i = code - firstChar;
    if (i >= 0 && i < widths.length) return widths[i];
    return missingWidth;
  }

  static _Font parse(String body) {
    final name = RegExp(r'/BaseFont\s*/([A-Za-z0-9+\-,_]+)')
            .firstMatch(body)
            ?.group(1) ??
        '';
    final subtype = RegExp(r'/Subtype\s*/([A-Za-z0-9]+)')
            .firstMatch(body)
            ?.group(1) ??
        '';
    final first = int.tryParse(
          RegExp(r'/FirstChar\s+(\d+)').firstMatch(body)?.group(1) ?? '',
        ) ??
        0;
    final missing =
        double.tryParse(
          RegExp(r'/MissingWidth\s+(-?[\d.]+)').firstMatch(body)?.group(1) ?? '',
        ) ??
        500;
    final widths = <double>[];
    final wm = RegExp(r'/Widths\s*\[([^\]]*)\]', dotAll: true).firstMatch(body);
    if (wm != null) {
      for (final m in RegExp(r'-?[\d.]+').allMatches(wm.group(1)!)) {
        widths.add(double.parse(m.group(0)!));
      }
    }
    return _Font(name, widths, first, missing, subtype);
  }
}

List<int> _decodeStream(_Obj o) {
  final s = o.stream;
  if (s == null) return const [];
  final filter = o.dict;
  if (filter.contains('/FlateDecode')) {
    try {
      return arch.ZLibDecoder().decodeBytes(s);
    } catch (_) {
      return const [];
    }
  }
  if (filter.contains('/Filter')) return const []; // LZW/DCT/…：不支持
  return s;
}

/// 从页字典里取 `/Font` 资源映射（`/F6 6 0 R`）。
Map<String, int> _fontRefs(_Doc doc, String pageDict) {
  final out = <String, int>{};
  final i = pageDict.indexOf('/Font');
  if (i >= 0) {
    final sub = _balancedDict(pageDict, i);
    for (final m in RegExp(r'/([A-Za-z0-9#]+)\s+(\d+)\s+\d+\s+R').allMatches(sub)) {
      out[m.group(1)!] = int.parse(m.group(2)!);
    }
    if (out.isNotEmpty) return out;
  }
  // 页字典里没有（用 /Resources 间接引用）⇒ 退化为"全文件同名资源"
  for (final o in doc.objects.values) {
    for (final m in RegExp(r'/([A-Za-z0-9#]+)\s+(\d+)\s+\d+\s+R')
        .allMatches(o.dict)) {
      if (m.group(1)!.startsWith('F')) {
        out.putIfAbsent(m.group(1)!, () => int.parse(m.group(2)!));
      }
    }
  }
  return out;
}

String _balancedDict(String text, int from) {
  final start = text.indexOf('<<', from);
  if (start < 0) return '';
  var depth = 0;
  var i = start;
  while (i < text.length - 1) {
    if (text[i] == '<' && text[i + 1] == '<') {
      depth++;
      i += 2;
      continue;
    }
    if (text[i] == '>' && text[i + 1] == '>') {
      depth--;
      i += 2;
      if (depth == 0) return text.substring(start, i);
      continue;
    }
    i++;
  }
  return text.substring(start);
}

({double width, double height}) _mediaBox(String pageDict) {
  final m = RegExp(r'/MediaBox\s*\[([^\]]*)\]').firstMatch(pageDict);
  if (m == null) return (width: 612, height: 792);
  final v = RegExp(r'-?[\d.]+')
      .allMatches(m.group(1)!)
      .map((x) => double.parse(x.group(0)!))
      .toList();
  if (v.length < 4) return (width: 612, height: 792);
  return (width: (v[2] - v[0]).abs(), height: (v[3] - v[1]).abs());
}

/// 抽文本层（**不抛异常**，解析不了就 `parsed=false` + 原因）。
PdfTextLayer extractPdfTextLayer(Uint8List bytes) {
  final _Doc doc;
  try {
    doc = _openPdf(bytes);
  } on PdfTextLayerException catch (e) {
    return PdfTextLayer(
      pages: [PdfTextLayerPage.unparsed(0, e.message)],
      width: 0,
      height: 0,
    );
  }
  final out = <PdfTextLayerPage>[];
  var docW = 0.0;
  var docH = 0.0;
  for (var p = 0; p < doc.pageObjects.length; p++) {
    final pageObj = doc.objects[doc.pageObjects[p]]!;
    final media = _mediaBox(pageObj.dict);
    docW = docW == 0 ? media.width : docW;
    docH = docH == 0 ? media.height : docH;
    final fontRefs = _fontRefs(doc, pageObj.dict);
    final fonts = <String, _Font>{};
    for (final e in fontRefs.entries) {
      final fo = doc.objects[e.value];
      if (fo != null) fonts[e.key] = _Font.parse(fo.dict);
    }
    final contentRefs = _contentRefs(pageObj.dict);
    if (contentRefs.isEmpty) {
      out.add(PdfTextLayerPage.unparsed(p, '页对象没有 /Contents'));
      continue;
    }
    final glyphs = <_Glyph>[];
    var unsupported = '';
    for (final ref in contentRefs) {
      final co = doc.objects[ref];
      if (co == null) continue;
      final decoded = _decodeStream(co);
      if (decoded.isEmpty) {
        if (co.dict.contains('/Filter')) {
          unsupported = driveGap(
            'drivePdfTextLayerUnsupportedFilter',
            '内容流滤镜不支持（只做 /FlateDecode）',
          );
        }
        continue;
      }
      final r = _runContentStream(
        latin1.decode(Uint8List.fromList(decoded), allowInvalid: true),
        fonts,
        media,
      );
      glyphs.addAll(r.glyphs);
      if (r.unsupported.isNotEmpty) unsupported = r.unsupported;
    }
    if (glyphs.isEmpty) {
      out.add(
        PdfTextLayerPage.unparsed(
          p,
          unsupported.isEmpty ? '这一页没有可抽取的文字' : unsupported,
        ),
      );
      continue;
    }
    out.add(
      PdfTextLayerPage(
        page: p,
        spans: _mergeRuns(glyphs, media),
        parsed: true,
      ),
    );
  }
  return PdfTextLayer(pages: out, width: docW, height: docH);
}

List<int> _contentRefs(String pageDict) {
  final m = RegExp(r'/Contents\s*(\d+)\s+\d+\s+R').firstMatch(pageDict);
  if (m != null) return [int.parse(m.group(1)!)];
  final arr = RegExp(r'/Contents\s*\[([^\]]*)\]').firstMatch(pageDict);
  if (arr != null) {
    return [
      for (final x in RegExp(r'(\d+)\s+\d+\s+R').allMatches(arr.group(1)!))
        int.parse(x.group(1)!),
    ];
  }
  return const [];
}

/// 内容流解释结果（含"遇到的第一个不支持算子"）。
class _RunResult {
  const _RunResult(this.glyphs, this.unsupported);
  final List<_Glyph> glyphs;
  final String unsupported;
}

_RunResult _runContentStream(
  String content,
  Map<String, _Font> fonts,
  ({double width, double height}) media,
) {
  final glyphs = <_Glyph>[];
  var unsupported = '';
  final ctmStack = <_Mat>[const _Mat(1, 0, 0, 1, 0, 0)];
  var ctm = ctmStack.last;
  var tm = _Mat.identity;
  var tlm = _Mat.identity;
  var fontSize = 0.0;
  var charSpace = 0.0;
  var wordSpace = 0.0;
  var hScale = 1.0;
  var leading = 0.0;
  _Font? font;

  void showText(String s, {required _Mat base}) {
    // ★ 245 轮：字体没有宽度表 ⇒ **不猜坐标**（CID/Type0 的宽度在 /W + CMap）
    final f = font;
    if (f != null && !f.hasWidths) {
      if (unsupported.isEmpty) {
        unsupported = driveGapFill(
          'drivePdfTextLayerNoWidths',
          '字体 `{name}`（{subtype}）没有 /Widths，坐标不可靠 ⇒ 不解码',
          {'name': f.name, 'subtype': f.subtype},
        );
      }
      return;
    }
    var x = 0.0;
    final scale = fontSize * hScale * (base.d == 0 ? 1 : base.d);
    for (final code in s.codeUnits) {
      final w = (font?.widthOf(code) ?? 500) / 1000 * scale;
      final originX = base.x(x, 0);
      final originY = base.y(x, 0);
      final top = 1 - (originY + fontSize * base.d * 0.8) / media.height;
      final bottom = 1 - (originY - fontSize * base.d * 0.2) / media.height;
      glyphs.add(
        _Glyph(
          String.fromCharCode(code),
          (originX / media.width).clamp(0.0, 1.0),
          top.clamp(0.0, 1.0),
          ((originX + w) / media.width).clamp(0.0, 1.0),
          bottom.clamp(0.0, 1.0),
        ),
      );
      x += w + charSpace * base.d + (code == 0x20 ? wordSpace * base.d : 0);
    }
    // 让后续 `TJ` 数组里的数字调整有参照：返回推进量（由调用方用）
  }

  final tokens = _tokenize(content);
  final stack = <Object>[];
  for (final tk in tokens) {
    if (tk is _Op) {
      final op = tk.name;
      double dbl(int i) =>
          stack.length > i ? (stack[stack.length - 1 - i] as num).toDouble() : 0;
      switch (op) {
        case 'q':
          ctmStack.add(ctm);
          break;
        case 'Q':
          if (ctmStack.length > 1) {
            ctmStack.removeLast();
            ctm = ctmStack.last;
          }
          break;
        case 'cm':
          ctm = _Mat(dbl(5), dbl(4), dbl(3), dbl(2), dbl(1), dbl(0))
              .mul(ctm);
          break;
        case 'BT':
          tm = _Mat.identity;
          tlm = _Mat.identity;
          break;
        case 'ET':
          break;
        case 'Tf':
          if (stack.length >= 2) {
            final name = stack[stack.length - 2];
            fontSize = (stack.last as num).toDouble();
            if (name is String) font = fonts[name];
          }
          break;
        case 'Tc':
          charSpace = dbl(0);
          break;
        case 'Tw':
          wordSpace = dbl(0);
          break;
        case 'Tz':
          hScale = dbl(0) / 100;
          break;
        case 'TL':
          leading = dbl(0);
          break;
        case 'Td':
          tlm = _Mat.translate(dbl(1), dbl(0)).mul(tlm);
          tm = tlm;
          break;
        case 'TD':
          leading = -dbl(0);
          tlm = _Mat.translate(dbl(1), dbl(0)).mul(tlm);
          tm = tlm;
          break;
        case 'Tm':
          tm = _Mat(dbl(5), dbl(4), dbl(3), dbl(2), dbl(1), dbl(0));
          tlm = tm;
          break;
        case 'T*':
          tlm = _Mat.translate(0, -leading).mul(tlm);
          tm = tlm;
          break;
        case 'Tj':
          if (stack.isNotEmpty && stack.last is String) {
            showText(stack.last as String, base: tm.mul(ctm));
          }
          break;
        case "'":
          tlm = _Mat.translate(0, -leading).mul(tlm);
          tm = tlm;
          if (stack.isNotEmpty && stack.last is String) {
            showText(stack.last as String, base: tm.mul(ctm));
          }
          break;
        case '"':
          leading = -dbl(1);
          tlm = _Mat.translate(0, -leading).mul(tlm);
          tm = tlm;
          if (stack.isNotEmpty && stack.last is String) {
            showText(stack.last as String, base: tm.mul(ctm));
          }
          break;
        case 'TJ':
          if (stack.isNotEmpty && stack.last is List) {
            for (final e in stack.last as List) {
              if (e is String) {
                showText(e, base: tm.mul(ctm));
              }
              // 数字是字距微调：忽略（对"行内文字顺序"没影响，仅影响精度）
            }
          }
          break;
        default:
          if (!_knownOps.contains(op) && unsupported.isEmpty) {
            unsupported = driveGapFill(
              'drivePdfTextLayerUnknownOp',
              '遇到不支持的算子 `{op}`（坐标可能不全）',
              {'op': op},
            );
          }
      }
      stack.clear();
    } else {
      stack.add(tk);
    }
  }
  return _RunResult(glyphs, unsupported);
}

const _knownOps = {
  'q', 'Q', 'cm', 'BT', 'ET', 'Tf', 'Tc', 'Tw', 'Tz', 'TL', 'Td', 'TD', 'Tm',
  'T*', 'Tj', "'", '"', 'TJ', 'Tr', 'rg', 'RG', 'g', 'G', 'k', 'K', 'w', 'J',
  'j', 'M', 'd', 'ri', 'i', 'gs', 're', 'm', 'l', 'c', 'v', 'y', 'h', 'S', 's',
  'f', 'F', 'f*', 'B', 'B*', 'b', 'b*', 'n', 'W', 'W*', 'CS', 'cs', 'SC', 'sc',
  'SCN', 'scn', 'sh', 'Do', 'BI', 'ID', 'EI', 'BX', 'EX', 'MP', 'DP', 'BMC',
  'BDC', 'EMC',
};

class _Op {
  const _Op(this.name);
  final String name;
}

/// 极简内容流分词器：字符串、十六进制串、数组、名、数字、算子。
List<Object> _tokenize(String s) {
  final out = <Object>[];
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C) {
      i++;
      continue;
    }
    if (c == 0x25) {
      while (i < s.length && s.codeUnitAt(i) != 0x0A) {
        i++;
      }
      continue;
    }
    if (c == 0x28) {
      final sb = StringBuffer();
      i++;
      var depth = 1;
      while (i < s.length && depth > 0) {
        final ch = s.codeUnitAt(i);
        if (ch == 0x5C) {
          i++;
          if (i >= s.length) break;
          final e = s.codeUnitAt(i);
          switch (e) {
            case 0x6E:
              sb.write('\n');
            case 0x72:
              sb.write('\r');
            case 0x74:
              sb.write('\t');
            case 0x62:
              sb.write('\b');
            case 0x66:
              sb.write('\f');
            default:
              if (e >= 0x30 && e <= 0x37) {
                var oct = String.fromCharCode(e);
                var k = 0;
                while (k < 2 &&
                    i + 1 < s.length &&
                    s.codeUnitAt(i + 1) >= 0x30 &&
                    s.codeUnitAt(i + 1) <= 0x37) {
                  i++;
                  oct += String.fromCharCode(s.codeUnitAt(i));
                  k++;
                }
                sb.writeCharCode(int.parse(oct, radix: 8));
              } else {
                sb.writeCharCode(e);
              }
          }
          i++;
          continue;
        }
        if (ch == 0x28) depth++;
        if (ch == 0x29) {
          depth--;
          if (depth == 0) {
            i++;
            break;
          }
        }
        sb.writeCharCode(ch);
        i++;
      }
      out.add(sb.toString());
      continue;
    }
    if (c == 0x3C && i + 1 < s.length && s.codeUnitAt(i + 1) != 0x3C) {
      final end = s.indexOf('>', i);
      if (end < 0) break;
      final hex = s.substring(i + 1, end).replaceAll(RegExp(r'\s'), '');
      final sb = StringBuffer();
      for (var k = 0; k + 1 < hex.length; k += 2) {
        sb.writeCharCode(int.parse(hex.substring(k, k + 2), radix: 16));
      }
      out.add(sb.toString());
      i = end + 1;
      continue;
    }
    if (c == 0x5B) {
      out.add(const _ArrayStart());
      i++;
      continue;
    }
    if (c == 0x5D) {
      out.add(const _ArrayEnd());
      i++;
      continue;
    }
    if (c == 0x2F) {
      var j = i + 1;
      while (j < s.length && !_isDelim(s.codeUnitAt(j))) {
        j++;
      }
      out.add(s.substring(i + 1, j));
      i = j;
      continue;
    }
    if ((c >= 0x30 && c <= 0x39) ||
        c == 0x2B ||
        c == 0x2D ||
        c == 0x2E) {
      var j = i;
      while (j < s.length &&
          (RegExp(r'[0-9+\-.]').hasMatch(String.fromCharCode(s.codeUnitAt(j))))) {
        j++;
      }
      final n = double.tryParse(s.substring(i, j));
      if (n != null) out.add(n);
      i = j;
      continue;
    }
    if (c == 0x3C && i + 1 < s.length && s.codeUnitAt(i + 1) == 0x3C) {
      i += 2;
      continue;
    }
    if (c == 0x3E) {
      i += s.codeUnitAt(i + 1) == 0x3E ? 2 : 1;
      continue;
    }
    var j = i;
    while (j < s.length && !_isDelim(s.codeUnitAt(j))) {
      j++;
    }
    if (j == i) {
      i++;
      continue;
    }
    out.add(_Op(s.substring(i, j)));
    i = j;
  }
  // 把 `[ ... ]` 收成 List
  final merged = <Object>[];
  for (var k = 0; k < out.length; k++) {
    final e = out[k];
    if (e is _ArrayStart) {
      final arr = <Object>[];
      k++;
      while (k < out.length && out[k] is! _ArrayEnd) {
        arr.add(out[k]);
        k++;
      }
      merged.add(arr);
    } else if (e is! _ArrayEnd) {
      merged.add(e);
    }
  }
  return merged;
}

class _ArrayStart {
  const _ArrayStart();
}

class _ArrayEnd {
  const _ArrayEnd();
}

bool _isDelim(int c) =>
    c == 0x20 ||
    c == 0x0A ||
    c == 0x0D ||
    c == 0x09 ||
    c == 0x0C ||
    c == 0x28 ||
    c == 0x29 ||
    c == 0x3C ||
    c == 0x3E ||
    c == 0x5B ||
    c == 0x5D ||
    c == 0x7B ||
    c == 0x7D ||
    c == 0x2F ||
    c == 0x25;

/// 把逐字框按**基线**聚成行（同一行内按 x 拼接，间距大就补空格）。
List<PdfTextSpan> _mergeRuns(
  List<_Glyph> glyphs,
  ({double width, double height}) media,
) {
  if (glyphs.isEmpty) return const [];
  final sorted = [...glyphs]
    ..sort((a, b) {
      final dy = a.bottom.compareTo(b.bottom);
      return dy != 0 ? dy : a.left.compareTo(b.left);
    });
  final lines = <List<_Glyph>>[];
  for (final g in sorted) {
    if (lines.isNotEmpty) {
      final last = lines.last;
      final ref = last.first;
      final h = (ref.bottom - ref.top).abs();
      final sameLine =
          (g.centerY - ref.centerY).abs() <= (h == 0 ? 0.01 : h * 0.6);
      if (sameLine) {
        last.add(g);
        continue;
      }
    }
    lines.add([g]);
  }
  final out = <PdfTextSpan>[];
  for (final line in lines) {
    line.sort((a, b) => a.left.compareTo(b.left));
    final sb = StringBuffer();
    var prevRight = double.nan;
    for (final g in line) {
      // 空格在 PDF 里通常**没有字形框**，只体现为"推进" ⇒ 判据要用
      // "相对字号"而不是"相对上一个字形宽"（244/245 轮实测：
      // `page` 与 `1` 之间的空隙恰好等于空格宽度 0.278×size，
      // 用 0.9×字形宽判会漏掉）。
      final lineH = (g.bottom - g.top).abs();
      if (!prevRight.isNaN &&
          lineH > 0 &&
          g.left - prevRight > lineH * 0.12) {
        sb.write(' ');
      }
      sb.write(g.text);
      prevRight = g.right;
    }
    out.add(
      PdfTextSpan(
        text: sb.toString(),
        left: line.map((g) => g.left).reduce((a, b) => a < b ? a : b),
        top: line.map((g) => g.top).reduce((a, b) => a < b ? a : b),
        right: line.map((g) => g.right).reduce((a, b) => a > b ? a : b),
        bottom: line.map((g) => g.bottom).reduce((a, b) => a > b ? a : b),
      ),
    );
  }
  return out;
}

// ───────────────────── 选中 → 高亮四边形（联动） ─────────────────────

/// 一次"框选文字"的结果：按行合并的四边形（**PDF 坐标**：左下原点）+
/// 选中的文本。
class PdfTextSelection {
  const PdfTextSelection({required this.quads, required this.text, required this.rect});

  /// 每行一个四边形，每 8 个数：左上、右上、左下、右下（PDF 规范顺序）
  final List<double> quads;
  final String text;

  /// 整块的 PDF 坐标矩形 `[x0,y0,x1,y1]`
  final List<double> rect;

  bool get isEmpty => quads.isEmpty;
}

/// 把归一化（左上原点）的框选区域映射成 `/Highlight` 的四边形 + 文本。
///
/// `pageWidth/Height` 是页点尺寸；`spans` 来自 [extractPdfTextLayer]。
PdfTextSelection pdfTextSelectionToQuote({
  required List<PdfTextSpan> spans,
  required double left,
  required double top,
  required double right,
  required double bottom,
  required double pageWidth,
  required double pageHeight,
}) {
  final l = left < right ? left : right;
  final r = left < right ? right : left;
  final t = top < bottom ? top : bottom;
  final b = top < bottom ? bottom : top;
  final hit = [
    for (final s in spans)
      if (s.intersects(l, t, r, b)) s,
  ];
  if (hit.isEmpty) {
    return const PdfTextSelection(quads: [], text: '', rect: []);
  }
  // 按行（y 带）分组
  final byLine = <List<PdfTextSpan>>[];
  for (final s in hit) {
    var placed = false;
    for (final line in byLine) {
      final ref = line.first;
      final h = (ref.bottom - ref.top).abs();
      if ((s.centerY - ref.centerY).abs() <= (h == 0 ? 0.01 : h * 0.6)) {
        line.add(s);
        placed = true;
        break;
      }
    }
    if (!placed) byLine.add([s]);
  }
  byLine.sort((a, b2) => a.first.top.compareTo(b2.first.top));
  final quads = <double>[];
  final words = <String>[];
  for (final line in byLine) {
    line.sort((a, b2) => a.left.compareTo(b2.left));
    final ll = line.map((s) => s.left).reduce((a, b2) => a < b2 ? a : b2);
    final rr = line.map((s) => s.right).reduce((a, b2) => a > b2 ? a : b2);
    final tt = line.map((s) => s.top).reduce((a, b2) => a < b2 ? a : b2);
    final bb = line.map((s) => s.bottom).reduce((a, b2) => a > b2 ? a : b2);
    // 归一化(左上) → PDF 点(左下)
    final x0 = ll * pageWidth;
    final x1 = rr * pageWidth;
    final y1 = pageHeight - tt * pageHeight; // 上
    final y0 = pageHeight - bb * pageHeight; // 下
    quads.addAll([x0, y1, x1, y1, x0, y0, x1, y0]);
    words.add(line.map((s) => s.text).join(' '));
  }
  final allL = hit.map((s) => s.left).reduce((a, b2) => a < b2 ? a : b2);
  final allR = hit.map((s) => s.right).reduce((a, b2) => a > b2 ? a : b2);
  final allT = hit.map((s) => s.top).reduce((a, b2) => a < b2 ? a : b2);
  final allB = hit.map((s) => s.bottom).reduce((a, b2) => a > b2 ? a : b2);
  return PdfTextSelection(
    quads: quads,
    text: words.join(' '),
    rect: [
      allL * pageWidth,
      pageHeight - allB * pageHeight,
      allR * pageWidth,
      pageHeight - allT * pageHeight,
    ],
  );
}
