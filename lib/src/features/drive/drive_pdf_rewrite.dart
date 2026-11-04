// ★★★ ③Drive **D61「写回原文件」** —— 第 244 轮：**自研 PDF 增量更新**。
//
// ## 为什么必须自研
// `pdf` 包只能**构建新文档**，不能改已有 PDF。官方 Drive 阅读器是把批注写进
// **原 PDF 的对象图**（`/Annots`），所以别的阅读器打开原文件能看到/编辑批注。
// 231 轮我们在"导出的副本"上写了真正的注释对象（`/Square`/`/Ink`/`/Text`），
// 但那仍不是"改原文件"。本轮补上这一块：
//
//   ① 直接扫原文件对象头（`N 0 obj`）建偏移表 —— 不依赖 xref 是否完好，
//      也不要求解开 xref stream（PDF 1.5+ 常见）；
//   ② 找 `/Type /Catalog` 当 `/Root`，找 `/Type /Page` 依出现顺序映射页号；
//   ③ 复制原页对象字典（**逐字保留**），把新注释追加进 `/Annots`（已有则合并）；
//   ④ 新注释对象按 PDF 规范写：`/Highlight`（带 `/QuadPoints`）/`/Square` /
//      `/Ink`（`/InkList`）/`/Text`（`/Contents`）；
//   ⑤ 追加**经典 xref 表** + `trailer << /Prev <旧 startxref> >>` + `startxref` + `%%EOF`
//      —— 这是规范允许的增量更新形态（旧内容一字不动）。
//
// ## 边界（如实）
// * 只处理**经典 xref 表**的**追加**；加密 PDF（`/Encrypt`）明确拒绝，不硬写坏文件；
// * 不做对象流（ObjStm）解压：**只要页对象在文件里是明文对象**就行
//   （官方 App 自己的 PDF、以及我们导出的 PDF 都满足）。对象流里的页对象
//   目前会如实报 `PdfRewriteException`，**不假装成功**。
import 'dart:convert';
import 'dart:typed_data';

import 'drive_pdf_markup.dart';

/// 写回失败（不是 PDF / 加密 / 页对象在对象流里 / 页号越界 ……）
class PdfRewriteException implements Exception {
  const PdfRewriteException(this.message);
  final String message;
  @override
  String toString() => 'PdfRewriteException: $message';
}

/// 一种要写进 PDF 的注释（已按页做像素/点坐标换算）。
class PdfAnnotationSpec {
  const PdfAnnotationSpec({
    required this.page,
    required this.subtype,
    required this.rect,
    this.quadPoints = const [],
    this.inkLists = const [],
    this.contents = '',
    this.colorArgb = 0xFFFFD54F,
    this.author = 'Synology Chat Station',
    this.createdAtMs = 0,
  });

  /// 0 起页号
  final int page;

  /// `/Highlight` / `/Square` / `/Ink` / `/Text`
  final String subtype;

  /// PDF 坐标（左下原点，点数）：`[x0,y0,x1,y1]`
  final List<double> rect;

  /// `/QuadPoints`：每 8 个数一个四边形（PDF 规范顺序：左上、右上、左下、右下）
  final List<double> quadPoints;

  /// `/InkList`：每个笔画是一串 `x y`
  final List<List<double>> inkLists;

  /// `/Contents`（便签文字/批注内容）
  final String contents;

  final int colorArgb;
  final String author;
  final int createdAtMs;
}

/// 把 `PdfMarkupDoc` 里的批注转成 PDF 注释对象（**归一化 → PDF 点坐标**）。
///
/// 坐标翻转：批注模型是左上原点归一化；PDF 注释是左下原点、单位为页点 ⇒
/// `y_pdf = height - y_topDown`。
List<PdfAnnotationSpec> pdfAnnotationSpecsFromDoc({
  required PdfMarkupDoc doc,
  required int page,
  required double width,
  required double height,
}) {
  final out = <PdfAnnotationSpec>[];
  for (final m in doc.marksForPage(page)) {
    final l = m.left * width;
    final t = m.top * height;
    final r = m.right * width;
    final b = m.bottom * height;
    final rect = [
      l.clamp(0, width).toDouble(),
      (height - b).clamp(0, height).toDouble(),
      r.clamp(0, width).toDouble(),
      (height - t).clamp(0, height).toDouble(),
    ];
    switch (m.kind) {
      case PdfMarkupKind.highlight:
        // ★ 244 轮：真的用 `/Highlight` + `/QuadPoints`（231 轮只能用 /Square 近似）
        // ★ 245 轮：若批注带**文字层联动**的四边形式（`m.quads`），就用它，
        //   并把 `/Rect` 取成这些四边形的**包围盒**（规范要求 Rect 覆盖注释）。
        final useQuads = m.quads.length >= 8;
        final q = useQuads ? m.quads : const <double>[];
        final pdfRect = useQuads
            ? [_minEvery(q, 0), _minEvery(q, 1), _maxEvery(q, 0), _maxEvery(q, 1)]
            : rect;
        out.add(
          PdfAnnotationSpec(
            page: page,
            subtype: '/Highlight',
            rect: pdfRect,
            quadPoints: useQuads
                ? q
                : [
                    rect[0], rect[3], // 左上
                    rect[2], rect[3], // 右上
                    rect[0], rect[1], // 左下
                    rect[2], rect[1], // 右下
                  ],
            // 没有用户备注时，用框选到的文字当 /Contents（官方批注也这么存）
            contents: m.note.isNotEmpty ? m.note : m.selectedText,
            colorArgb: m.color,
            createdAtMs: m.createdAtMs,
          ),
        );
      case PdfMarkupKind.ink:
        final pts = <double>[];
        for (var i = 0; i + 1 < m.points.length; i += 2) {
          pts.add(m.points[i] * width);
          pts.add(height - m.points[i + 1] * height);
        }
        out.add(
          PdfAnnotationSpec(
            page: page,
            subtype: '/Ink',
            rect: rect,
            inkLists: [pts],
            contents: m.note,
            colorArgb: m.color,
            createdAtMs: m.createdAtMs,
          ),
        );
      case PdfMarkupKind.note:
        out.add(
          PdfAnnotationSpec(
            page: page,
            subtype: '/Text',
            rect: rect,
            contents: m.note,
            colorArgb: m.color,
            createdAtMs: m.createdAtMs,
          ),
        );
    }
  }
  return out;
}

/// 一次增量更新的结果（诊断信息给用例/日志用）。
class PdfRewriteResult {
  const PdfRewriteResult({
    required this.bytes,
    required this.pageObjectNumbers,
    required this.appendedObjectNumbers,
    required this.previousStartXref,
    required this.newStartXref,
    required this.objectStreamPages,
    required this.usedFullRebuild,
  });

  final Uint8List bytes;

  /// 页号 → 原文件里的页对象号
  final List<int> pageObjectNumbers;
  final List<int> appendedObjectNumbers;
  final int previousStartXref;
  final int newStartXref;

  /// 页对象藏在对象流里、因此**没能写回**的页号（如实报告，不假装成功）
  final List<int> objectStreamPages;

  /// 是否用了"**重建整张经典 xref 表**"（无 `/Prev` 链）的写法。
  ///
  /// 为什么需要它：原文件若是 xref **流**（PDF 1.5+，`pdf` 包就是），
  /// "经典表 + `/Prev` 指向 xref 流"在 macOS CoreGraphics 下会报
  /// `failed to find start of cross-reference section` —— 注释照样能读出来，
  /// 但文件不够干净。重建整表（列出每个对象的真实偏移、不带 `/Prev`）
  /// 实测 CoreGraphics **零告警**（244 轮实验见 `docs/parity-final-gap-table.md` 附录 GX）。
  final bool usedFullRebuild;
}

/// 扫描出来的原文件信息。
class _PdfScan {
  _PdfScan({
    required this.objects,
    required this.hasObjStm,
    required this.pageObjects,
    required this.catalogObject,
    required this.startXref,
    required this.fileSize,
    required this.encrypted,
  });

  /// 对象号 → 对象头偏移
  final Map<int, int> objects;

  /// 是否含对象流（`/Type /ObjStm`）
  final bool hasObjStm;

  /// 依出现顺序的页对象号
  final List<int> pageObjects;
  final int catalogObject;
  final int startXref;
  final int fileSize;
  final bool encrypted;
  int get maxObject => objects.keys.fold(0, (a, b) => a > b ? a : b);
}

_PdfScan _scanPdf(Uint8List bytes) {
  final text = latin1.decode(bytes, allowInvalid: true);
  if (!text.startsWith('%PDF-')) {
    throw const PdfRewriteException('不是 PDF（缺少 %PDF- 头）');
  }
  final objects = <int, int>{};
  // 对象头：行首 `N G obj`
  final reObj = RegExp(
    r'^(\d{1,9})\s+(\d{1,5})\s+obj\b',
    multiLine: true,
  );
  for (final m in reObj.allMatches(text)) {
    final num = int.parse(m.group(1)!);
    // ★ 增量更新的文件里同一对象号可能出现多次；**最后一次**才有效
    // （244 轮用"第一次"时，二次追加会拿到旧页对象）。
    objects[num] = m.start;
  }
  final hasObjStm = RegExp(r'/Type\s*/ObjStm').hasMatch(text);
  final pageObjects = <int>[];
  var catalog = 0;
  objects.forEach((objNum, off) {
    final end = _objectBodyEnd(text, off);
    final body = text.substring(off, end);
    if (RegExp(r'/Type\s*/Page\b').hasMatch(body) &&
        !RegExp(r'/Type\s*/Pages\b').hasMatch(body)) {
      pageObjects.add(objNum);
    }
    if (RegExp(r'/Type\s*/Catalog\b').hasMatch(body)) {
      catalog = objNum;
    }
  });
  final startXref = _lastStartXref(text);
  return _PdfScan(
    objects: objects,
    hasObjStm: hasObjStm,
    pageObjects: pageObjects,
    catalogObject: catalog,
    startXref: startXref,
    fileSize: bytes.length,
    encrypted: RegExp(r'/Encrypt\b').hasMatch(text),
  );
}

int _lastStartXref(String text) {
  final re = RegExp(r'startxref\s+(\d{1,12})');
  final all = re.allMatches(text).toList();
  if (all.isEmpty) return -1;
  return int.parse(all.last.group(1)!);
}

/// 对象体（`obj` 之后到 `endobj` / `stream` 之前）的结束位置。
int _objectBodyEnd(String text, int offset) {
  final rest = text.substring(offset);
  final streamIdx = rest.indexOf(RegExp(r'\bstream\b'));
  final endObjIdx = rest.indexOf(RegExp(r'\bendobj\b'));
  if (streamIdx >= 0 && (endObjIdx < 0 || streamIdx < endObjIdx)) {
    return offset + streamIdx;
  }
  if (endObjIdx >= 0) return offset + endObjIdx;
  return text.length;
}

/// 原页对象的**字典原文**（逐字保留；含 `/Annots` 也不动）。
String _pageDictText(String text, int offset) {
  final bodyStart = text.indexOf('obj', offset);
  if (bodyStart < 0) throw const PdfRewriteException('页对象头损坏');
  var i = bodyStart + 3;
  // 跳过空白
  while (i < text.length && _isWs(text.codeUnitAt(i))) {
    i++;
  }
  if (i >= text.length || text[i] != '<') {
    throw const PdfRewriteException('页对象不是字典');
  }
  // 配平 `<< >>`（字典里可能嵌套字典/数组，但 `>>` 只会在 REST 结束）
  var depth = 0;
  var j = i;
  while (j < text.length - 1) {
    if (text[j] == '<' && text[j + 1] == '<') {
      depth++;
      j += 2;
      continue;
    }
    if (text[j] == '>' && text[j + 1] == '>') {
      depth--;
      j += 2;
      if (depth == 0) return text.substring(i, j);
      continue;
    }
    j++;
  }
  throw const PdfRewriteException('页对象字典没配平');
}

bool _isWs(int c) => c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09;

/// PDF 字符串。
///
/// * 全 ASCII ⇒ 普通 `(...)`（带转义）；
/// * 含非 ASCII ⇒ **整串**写成 `<FEFF....>`（BOM 只出现一次）。
///   ⚠️ 244 轮踩过：按"逐字符"写 `<FEFF4E2D><FEFF6587>` 会让阅读器拿到
///   一串独立的 1 字符串（PDFKit 直接原样显示十六进制），而不是"中文批注"。
String _pdfString(String s) {
  final hasNonAscii = s.runes.any((r) => r > 0x7E);
  if (hasNonAscii) {
    final b = StringBuffer('<FEFF');
    for (final rune in s.runes) {
      for (final u in _utf16Be(rune)) {
        b.write(u.toRadixString(16).padLeft(4, '0').toUpperCase());
      }
    }
    b.write('>');
    return b.toString();
  }
  final b = StringBuffer('(');
  for (final rune in s.runes) {
    switch (rune) {
      case 0x28:
        b.write(r'\(');
      case 0x29:
        b.write(r'\)');
      case 0x5C:
        b.write(r'\\');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      default:
        b.writeCharCode(rune);
    }
  }
  b.write(')');
  return b.toString();
}

List<int> _utf16Be(int rune) {
  if (rune <= 0xFFFF) return [rune];
  final v = rune - 0x10000;
  return [0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)];
}

String _pdfDate(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms == 0 ? 0 : ms, isUtc: true);
  String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  final off = ms == 0 ? '+00\'00' : 'Z';
  return "D:${p(t.year, 4)}${p(t.month)}${p(t.day)}${p(t.hour)}${p(t.minute)}${p(t.second)}$off";
}

String _num(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '').replaceFirst(
    RegExp(r'\.$'),
    '',
  );
}

String _colorOps(int argb) {
  final r = ((argb >> 16) & 0xFF) / 255;
  final g = ((argb >> 8) & 0xFF) / 255;
  final b = (argb & 0xFF) / 255;
  return '/C [${_num(r)} ${_num(g)} ${_num(b)}]';
}

/// 把注释写进**原 PDF**（增量更新，原内容一字不动）。
///
/// * `bytes` —— 原 PDF
/// * `specs` —— 要追加的注释（页码 0 起）
PdfRewriteResult appendPdfAnnotations({
  required Uint8List bytes,
  required List<PdfAnnotationSpec> specs,
}) {
  final scan = _scanPdf(bytes);
  if (scan.hasObjStm) {
    // 对象流里的对象没法用"明文对象扫描"定位 —— 此时退回**经典表 + /Prev**
    // 的最小增量形态（页对象若在对象流里，下面会因找不到而报错）。
  }
  if (scan.encrypted) {
    throw const PdfRewriteException('加密 PDF（/Encrypt）不支持写回，拒绝硬改');
  }
  if (scan.catalogObject == 0) {
    throw const PdfRewriteException('找不到 /Type /Catalog，拒绝猜对象号');
  }
  final text = latin1.decode(bytes, allowInvalid: true);
  final byPage = <int, List<PdfAnnotationSpec>>{};
  for (final s in specs) {
    byPage.putIfAbsent(s.page, () => []).add(s);
  }
  final objectStreamPages = <int>[];
  for (final p in byPage.keys) {
    if (p < 0 || p >= scan.pageObjects.length) {
      throw PdfRewriteException(
        '页号越界：$p（原文件只有 ${scan.pageObjects.length} 页）',
      );
    }
  }
  if (byPage.isEmpty) {
    return PdfRewriteResult(
      bytes: bytes,
      pageObjectNumbers: scan.pageObjects,
      appendedObjectNumbers: const [],
      previousStartXref: scan.startXref,
      newStartXref: scan.startXref,
      objectStreamPages: const [],
      usedFullRebuild: false,
    );
  }

  var nextObj = scan.maxObject + 1;
  final buf = BytesBuilder(copy: false);
  buf.add(bytes);
  var offset = bytes.length;
  void write(String s) {
    final b = utf8.encode(s);
    buf.add(b);
    offset += b.length;
  }

  /// 新对象号 → "obj 文本"（先算好，写的时候才知道偏移）
  final newObjects = <int, String>{};

  // ① 页对象：复制原字典 + 合并 /Annots
  for (final entry in byPage.entries) {
    final pageNo = entry.key;
    final pageObj = scan.pageObjects[pageNo];
    final dict = _pageDictText(text, scan.objects[pageObj]!);
    final annotRefs = <String>[];
    for (final _ in entry.value) {
      annotRefs.add('${nextObj++} 0 R');
    }
    final patched = _withAnnots(dict, annotRefs);
    newObjects[pageObj] = patched;
  }

  // ② 注释对象本体
  var annotNum = scan.maxObject + 1;
  final annotObjects = <int, String>{};
  for (final entry in byPage.entries) {
    for (final s in entry.value) {
      final n = annotNum++;
      annotObjects[n] = _annotBody(
        s,
        pageObj: scan.pageObjects[entry.key],
      );
    }
  }
  newObjects.addAll(annotObjects);

  // ③ 逐个写对象，记录新偏移
  final xrefEntries = <int, int>{};
  final numbers = newObjects.keys.toList()..sort();
  for (final n in numbers) {
    xrefEntries[n] = offset;
    write('$n 0 obj\n${newObjects[n]}\nendobj\n');
  }

  // ④ xref：**默认重建整张经典表**（列出每个对象的真实偏移，不带 `/Prev`）。
  //
  // 为什么不走"最小增量表 + /Prev 指向旧 xref 流"：实测 macOS CoreGraphics 会报
  // `failed to find start of cross-reference section`（注释仍能读，但文件不干净）。
  // 重建整表后 CoreGraphics 零告警。含对象流（ObjStm）的文件退回增量形态，
  // 因为对象流里的对象我们定位不到，重建整表会漏条目。
  final xrefOffset = offset;
  final sb = StringBuffer('xref\n');
  if (!scan.hasObjStm) {
    final all = <int, int>{...scan.objects, ...xrefEntries};
    final numbers = all.keys.toList()..sort();
    // 对象 0 必须是空闲头（规范要求）
    sb.write('0 1\n0000000000 65535 f \n');
    var i = 0;
    while (i < numbers.length) {
      var j = i;
      while (j + 1 < numbers.length && numbers[j + 1] == numbers[j] + 1) {
        j++;
      }
      if (numbers[i] == 0) {
        // 0 已单独写过：跳过它，只写后面的连续段
        i++;
        if (i > j) continue;
      }
      sb.write('${numbers[i]} ${j - i + 1}\n');
      for (var k = i; k <= j; k++) {
        sb.write(
          '${all[numbers[k]]!.toString().padLeft(10, '0')} 00000 n \n',
        );
      }
      i = j + 1;
    }
    final size = numbers.isEmpty ? 1 : numbers.last + 1;
    sb.write('trailer\n<< /Size $size /Root ${scan.catalogObject} 0 R >>\n');
  } else {
    final numbers = xrefEntries.keys.toList()..sort();
    var i = 0;
    while (i < numbers.length) {
      var j = i;
      while (j + 1 < numbers.length && numbers[j + 1] == numbers[j] + 1) {
        j++;
      }
      sb.write('${numbers[i]} ${j - i + 1}\n');
      for (var k = i; k <= j; k++) {
        sb.write(
          '${xrefEntries[numbers[k]]!.toString().padLeft(10, '0')} 00000 n \n',
        );
      }
      i = j + 1;
    }
    final size = (numbers.isEmpty ? scan.maxObject : numbers.last) + 1;
    sb.write('trailer\n<< /Size $size /Root ${scan.catalogObject} 0 R');
    if (scan.startXref >= 0) sb.write(' /Prev ${scan.startXref}');
    sb.write(' >>\n');
  }
  sb.write('startxref\n$xrefOffset\n%%EOF\n');
  write(sb.toString());

  return PdfRewriteResult(
    bytes: buf.toBytes(),
    pageObjectNumbers: scan.pageObjects,
    appendedObjectNumbers: numbers,
    previousStartXref: scan.startXref,
    newStartXref: xrefOffset,
    objectStreamPages: objectStreamPages,
    usedFullRebuild: !scan.hasObjStm,
  );
}

/// 在原页字典里加/并 `/Annots`。
String _withAnnots(String dict, List<String> refs) {
  final add = refs.join(' ');
  final m = RegExp(r'/Annots\s*\[([^\]]*)\]').firstMatch(dict);
  if (m != null) {
    final existing = m.group(1)!.trim();
    final merged = existing.isEmpty ? add : '$existing $add';
    return dict.replaceRange(
      m.start,
      m.end,
      '/Annots [$merged]',
    );
  }
  final m2 = RegExp(r'/Annots\s+(\d+)\s+\d+\s+R').firstMatch(dict);
  if (m2 != null) {
    // 引用到别处的数组：不破坏它，改成显式数组（把原引用也带上）
    return dict.replaceRange(
      m2.start,
      m2.end,
      '/Annots [${m2.group(1)} 0 R $add]',
    );
  }
  // 直接插在字典末尾
  final close = dict.lastIndexOf('>>');
  return '${dict.substring(0, close)}/Annots [$add] ${dict.substring(close)}';
}

String _annotBody(PdfAnnotationSpec s, {required int pageObj}) {
  final sb = StringBuffer('<< /Type /Annot /Subtype ${s.subtype}');
  sb.write(' /Rect [${s.rect.map(_num).join(' ')}]');
  if (s.quadPoints.isNotEmpty) {
    sb.write(' /QuadPoints [${s.quadPoints.map(_num).join(' ')}]');
  }
  if (s.inkLists.isNotEmpty) {
    sb.write(
      ' /InkList [${s.inkLists.map((l) => '[${l.map(_num).join(' ')}]').join(' ')}]',
    );
  }
  sb.write(' ${_colorOps(s.colorArgb)}');
  if (s.subtype == '/Highlight') sb.write(' /CA 0.4');
  if (s.subtype == '/Text') sb.write(' /Name /Comment');
  sb.write(' /F 4');
  sb.write(' /T ${_pdfString(s.author)}');
  if (s.contents.isNotEmpty) sb.write(' /Contents ${_pdfString(s.contents)}');
  sb.write(' /M ${_pdfString(_pdfDate(s.createdAtMs))}');
  sb.write(' /P $pageObj 0 R');
  sb.write(' >>');
  return sb.toString();
}

/// 只读回读：把 PDF 里某页的注释对象**解析回来**（用例与诊断用）。
List<PdfAnnotationInfo> readPdfAnnotations({
  required Uint8List bytes,
  required int page,
}) {
  final scan = _scanPdf(bytes);
  if (page < 0 || page >= scan.pageObjects.length) {
    throw PdfRewriteException('页号越界：$page');
  }
  final text = latin1.decode(bytes, allowInvalid: true);
  final dict = _pageDictText(text, scan.objects[scan.pageObjects[page]]!);
  final m = RegExp(r'/Annots\s*\[([^\]]*)\]').firstMatch(dict);
  if (m == null) return const [];
  final refs = RegExp(r'(\d+)\s+\d+\s+R')
      .allMatches(m.group(1)!)
      .map((x) => int.parse(x.group(1)!))
      .toList();
  final out = <PdfAnnotationInfo>[];
  for (final r in refs) {
    final off = scan.objects[r];
    if (off == null) continue;
    final body = text.substring(off, _objectBodyEnd(text, off));
    final sub = RegExp(r'/Subtype\s*(/\w+)').firstMatch(body)?.group(1) ?? '';
    final rect = RegExp(r'/Rect\s*\[([^\]]*)\]').firstMatch(body)?.group(1) ?? '';
    final contents = RegExp(r'/Contents\s*\((.*?)\)(?=\s*/|$)')
        .firstMatch(body)
        ?.group(1);
    out.add(
      PdfAnnotationInfo(
        objectNumber: r,
        subtype: sub,
        rect: rect
            .trim()
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .map(double.parse)
            .toList(),
        contents: contents ?? '',
        hasQuadPoints: body.contains('/QuadPoints'),
        hasInkList: body.contains('/InkList'),
      ),
    );
  }
  return out;
}

/// 回读出来的一条注释。
class PdfAnnotationInfo {
  const PdfAnnotationInfo({
    required this.objectNumber,
    required this.subtype,
    required this.rect,
    required this.contents,
    required this.hasQuadPoints,
    required this.hasInkList,
  });

  final int objectNumber;
  final String subtype;
  final List<double> rect;
  final String contents;
  final bool hasQuadPoints;
  final bool hasInkList;

  Map<String, Object?> toJson() => {
    'obj': objectNumber,
    'subtype': subtype,
    'rect': rect,
    'contents': contents,
    'quadPoints': hasQuadPoints,
    'inkList': hasInkList,
  };
}

/// 四边形列表里第 `k` 列（0=x,1=y）的最小/最大值 —— 用来算 `/Rect` 包围盒。
double _minEvery(List<double> quads, int k) {
  var v = double.infinity;
  for (var i = k; i < quads.length; i += 2) {
    if (quads[i] < v) v = quads[i];
  }
  return v;
}

double _maxEvery(List<double> quads, int k) {
  var v = -double.infinity;
  for (var i = k; i < quads.length; i += 2) {
    if (quads[i] > v) v = quads[i];
  }
  return v;
}
