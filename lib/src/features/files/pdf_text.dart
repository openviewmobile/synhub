// PDF **文字抽取**（`extractPdfText`）—— 与目录解析共用一个库（`part of`），
// 直接复用 `pdf_doc.dart` 里的 xref / 对象流 / Flate / PNG 预测器实现。
//
// 为什么需要它：AI 助手要"总结这份 PDF"，可 PDF 的正文对 `pdfx` 来说是**图片**
// （Android 侧走系统 `PdfRenderer`，只出位图、没有文字层）。没有文字就没得总结，
// 所以只能自己从内容流里把字抠出来。
//
// 这是**尽力而为**的抽取，不是排版还原：
//   * 覆盖真正会遇到的东西：`BT/ET` 文本块、`Tj`/`TJ`/`'`/`"` 四种显示算子、
//     `Td/TD/T*/TL/Tm` 的换行判断、简单字体的 WinAnsi/MacRoman + `/Differences`
//     字形名、Type0 复合字体的 Identity-H/V 双字节码 + `/ToUnicode` CMap
//     （`beginbfchar`/`beginbfrange`）—— 中文 PDF 的关键就在这里；
//   * 不做的：LZW/RunLength/CCITT/DCT 等过滤器（放弃该流）、加密文档（直接返回空）、
//     竖排细节、字距精修、表格/分栏重排、连字与断词。
//   * 契约：**绝不抛异常**，抽不到就返回空串，调用方（AI UI）据此如实说
//     "这份 PDF 没有可提取的文字（可能是扫描件）"。
part of 'pdf_doc.dart';

/// 最近一次文本抽取的失败/降级原因（调试用）
String? lastPdfTextError;

/// 一次最多抽多少字符（防止超大文档把内存和 AI 上下文撑爆）
const int kPdfTextMaxChars = 200000;

/// 抽 PDF 的文字。
///
/// [pageIndex] 为 null 表示整篇（按页顺序拼，页与页之间空一行）；
/// 给了就是**该页**（0 基，与 `PdfTocEntry.pageIndex` 同一套编号）。
String extractPdfText(
  Uint8List bytes, {
  int? pageIndex,
  int maxChars = kPdfTextMaxChars,
}) {
  if (pageIndex != null) {
    final pages = extractPdfPages(bytes, maxChars: maxChars);
    if (pageIndex < 0 || pageIndex >= pages.length) {
      lastPdfTextError = currentText().pdfPageOutOfRange(pages.length);
      return '';
    }
    return pages[pageIndex];
  }
  final pages = extractPdfPages(bytes, maxChars: maxChars);
  final joined = pages.where((p) => p.isNotEmpty).join('\n\n');
  // 单条算子可能一次吐出很长一段（比如整页一个 Tj），所以合并后再截一刀
  return joined.length > maxChars ? joined.substring(0, maxChars) : joined;
}

/// 按页抽（第 0 项 = 第 1 页）。空串 = 那一页抽不出文字。
///
/// 为什么要按页返回：AI 的"问这份 PDF"要按页给引用（`passagesOfBook` 需要
/// 分节文本），而且**一次解析**比"每页重新开一遍文档"快得多。
List<String> extractPdfPages(
  Uint8List bytes, {
  int maxChars = kPdfTextMaxChars,
}) {
  lastPdfTextError = null;
  if (bytes.length < 8) {
    lastPdfTextError = currentText().pdfTooShortBytes(bytes.length);
    return const [];
  }
  try {
    final doc = _PdfTextDoc(bytes);
    return doc.extractPages(maxChars: maxChars);
  } catch (e) {
    lastPdfTextError = currentText().pdfExtractFailed(userFacingError(e));
    return const [];
  }
}

/// 内容流里"当前用哪个字体"的最小信息集
class _FontInfo {
  _FontInfo({
    required this.twoByte,
    required this.toUnicode,
    required this.diff,
  });

  /// 复合字体（Type0 / Identity-H、Identity-V）：一个字符 = 2 字节
  final bool twoByte;

  /// 码点 → Unicode（来自 `/ToUnicode` CMap）；没有就是 null
  final Map<int, String>? toUnicode;

  /// 简单字体的 `/Encoding /Differences`：字节 → Unicode
  final Map<int, String>? diff;

  static final _FontInfo latin = _FontInfo(
    twoByte: false,
    toUnicode: null,
    diff: null,
  );
}

class _PdfTextDoc extends _PdfDoc {
  _PdfTextDoc(super.bytes);

  final Map<String, _FontInfo> _fontCache = {};

  /// 初始化：解 xref、找 catalog、建页树。返回 false 表示没法抽（加密/没 catalog）
  bool _prepare() {
    _loadXref();
    final trailer = _trailer;
    if (trailer != null && trailer['Encrypt'] != null) {
      lastPdfTextError = currentText().pdfEncrypted;
      return false;
    }
    final catalog = _findCatalog();
    if (catalog == null) {
      lastPdfTextError = currentText().pdfNoCatalog;
      return false;
    }
    if (catalog['Encrypt'] != null) {
      lastPdfTextError = currentText().pdfEncrypted;
      return false;
    }
    _catalog = catalog;
    _buildPageTree();
    return true;
  }

  /// 每页一段文字（空串 = 那一页没有可抽的文字）
  List<String> extractPages({int maxChars = kPdfTextMaxChars}) {
    if (!_prepare()) return const [];
    final pages = _collectPageRefs();
    if (pages.isEmpty) {
      lastPdfTextError = currentText().pdfNoPages;
      return const [];
    }
    final out = <String>[];
    var total = 0;
    for (final ref in pages) {
      if (total >= maxChars) {
        out.add('');
        continue;
      }
      final text = _pageText(ref, maxChars: maxChars - total);
      total += text.length;
      out.add(text);
    }
    if (total == 0 && lastPdfTextError == null) {
      lastPdfTextError = currentText().pdfNoTextStreams;
    }
    return out;
  }

  /// 页树里的页面对象号（按阅读顺序）
  List<int> _collectPageRefs() {
    final refs = <int>[];
    final visited = <int>{};
    void walk(Object? node, int depth) {
      if (depth > 64) return;
      if (node is _PdfRef && !visited.add(node.num)) return;
      final dict = _resolveDict(node);
      if (dict == null) return;
      final type = _nameOf(dict['Type']);
      final kids = dict['Kids'];
      if (type == 'Page' || (type == null && kids == null)) {
        if (node is _PdfRef) refs.add(node.num);
        return;
      }
      if (kids is List) {
        for (final kid in kids) {
          walk(kid, depth + 1);
        }
      }
    }

    walk(_catalog?['Pages'], 0);
    return refs;
  }

  Uint8List _pageTextBytes(int pageNum, {required int maxChars}) {
    final page = _resolveDict(_PdfRef(pageNum, 0));
    if (page == null) return _empty;
    _fontCache.clear();
    _loadFonts(page['Resources']);
    final contents = page['Contents'];
    final chunks = <Uint8List>[];
    void addStream(Object? value) {
      final resolved = resolve(value);
      if (resolved is _PdfStream) {
        final data = _decodeStream(resolved);
        if (data != null && data.isNotEmpty) chunks.add(data);
      }
    }

    if (contents is List) {
      for (final c in contents) {
        addStream(c);
      }
    } else {
      addStream(contents);
    }
    if (chunks.isEmpty) return _empty;
    final total = chunks.fold<int>(0, (n, c) => n + c.length);
    final all = Uint8List(total);
    var at = 0;
    for (final c in chunks) {
      all.setRange(at, at + c.length, c);
      at += c.length;
    }
    return all;
  }

  String _pageText(int pageNum, {required int maxChars}) {
    final data = _pageTextBytes(pageNum, maxChars: maxChars);
    if (data.isEmpty) return '';
    final text = _ContentReader(data, _fontCache).readText(maxChars: maxChars);
    return text.length > maxChars ? text.substring(0, maxChars) : text;
  }

  static final Uint8List _empty = Uint8List(0);

  // ---------------------------------------------------------------- 字体

  void _loadFonts(Object? resources) {
    final res = _resolveDict(resources);
    final fonts = _resolveDict(res?['Font']);
    if (fonts == null) return;
    for (final entry in fonts.entries) {
      final info = _fontInfo(fonts[entry.key]);
      if (info != null) _fontCache[entry.key] = info;
    }
    // 页级资源里可能还嵌着 XObject 的字体（表单域），这里不追，够用了
  }

  _FontInfo? _fontInfo(Object? fontRef) {
    final font = _resolveDict(fontRef);
    if (font == null) return null;
    final subtype = _nameOf(font['Subtype']);
    final isType0 = subtype == 'Type0';
    // Identity-H/V 之外还有别的 CMap，但真实文件里几乎只有这一个；
    // 不是 Identity 的按"单字节"处理（宁可少抽点，也别抽出乱码）
    var twoByte = false;
    if (isType0) {
      final enc = _nameOf(font['Encoding']);
      twoByte = enc == 'Identity-H' || enc == 'Identity-V' || enc == null;
    }
    Map<int, String>? toUnicode;
    final cmapStream = resolve(font['ToUnicode']);
    if (cmapStream is _PdfStream) {
      final cmapBytes = _decodeStream(cmapStream);
      if (cmapBytes != null) toUnicode = _parseToUnicode(cmapBytes);
    }
    Map<int, String>? diff;
    if (!isType0) {
      final enc = _resolveDict(font['Encoding']);
      final diffs = enc?['Differences'];
      if (diffs is List) diff = _parseDifferences(diffs);
    }
    return _FontInfo(twoByte: twoByte, toUnicode: toUnicode, diff: diff);
  }

  /// `/Encoding /Differences [ 65 /Alpha 66 /Beta ]` → 字节 → Unicode
  Map<int, String> _parseDifferences(List<Object?> diffs) {
    final out = <int, String>{};
    var code = 0;
    for (final item in diffs) {
      final resolved = resolve(item);
      if (resolved is num) {
        code = resolved.toInt();
        continue;
      }
      final name = _nameOf(resolved);
      if (name == null) continue;
      final ch = _glyphNameToUnicode(name);
      if (ch != null) out[code] = ch;
      code++;
    }
    return out;
  }

  /// `/ToUnicode` CMap：只需要 `beginbfchar`/`endbfchar`、`beginbfrange`/`endbfrange`
  ///
  /// 注意两个坑（都踩过）：
  ///   * CMap 里真正写的是 `3 beginbfchar`（**前面带条数**），拿 `startsWith`
  ///     判断会一个都匹配不到，于是所有码点都映射不出来 → 抽出来是空串；
  ///   * 目标串是**字节序列**不是整数：`<00480065>` 是 "He"，当成 int 再转回
  ///     十六进制会丢掉前导 0，多位字符就散了。
  Map<int, String> _parseToUnicode(Uint8List data) {
    final out = <int, String>{};
    final text = String.fromCharCodes(data);
    final lines = text.split(RegExp(r'[\r\n]+'));
    var mode = '';
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('%')) continue;
      if (line.contains('begincodespacerange')) {
        mode = '';
        continue;
      }
      if (line.contains('endcodespacerange') ||
          line.contains('endcmap') ||
          line.contains('usecmap')) {
        mode = '';
        continue;
      }
      if (line.contains('beginbfchar')) {
        mode = 'char';
        continue;
      }
      if (line.contains('endbfchar')) {
        mode = '';
        continue;
      }
      if (line.contains('beginbfrange')) {
        mode = 'range';
        continue;
      }
      if (line.contains('endbfrange')) {
        mode = '';
        continue;
      }
      if (mode == 'char') {
        final parts = _hexGroups(line);
        if (parts.length >= 2) {
          out[_bytesToCode(parts[0])] = _bytesToString(parts[1]);
        }
      } else if (mode == 'range') {
        // <lo> <hi> <dst> 或 <lo> <hi> [ <d0> <d1> ... ]
        final brace = line.indexOf('[');
        if (brace < 0) {
          final parts = _hexGroups(line);
          if (parts.length >= 3) {
            final lo = _bytesToCode(parts[0]);
            final hi = _bytesToCode(parts[1]);
            final dst = parts[2];
            final start = _bytesToCode(dst);
            final suffix = _bytesToString(
              dst.length > 2 ? dst.sublist(2) : Uint8List(0),
            );
            for (var c = lo; c <= hi && c - lo < 65536; c++) {
              out[c] = String.fromCharCode(start + (c - lo)) + suffix;
            }
          }
        } else {
          final head = _hexGroups(line.substring(0, brace));
          if (head.length >= 2) {
            final lo = _bytesToCode(head[0]);
            final body = line.substring(brace + 1, line.lastIndexOf(']'));
            final items = _hexGroups(body);
            for (var i = 0; i < items.length; i++) {
              out[lo + i] = _bytesToString(items[i]);
            }
          }
        }
      }
    }
    return out;
  }

  /// 一行里所有的 `<...>` 十六进制串（按出现顺序，逐串给字节）
  List<Uint8List> _hexGroups(String line) {
    final out = <Uint8List>[];
    final re = RegExp(r'<([0-9A-Fa-f\s]*)>');
    for (final m in re.allMatches(line)) {
      final hex = m.group(1)!.replaceAll(RegExp(r'\s'), '');
      if (hex.isEmpty) continue;
      final bytes = <int>[];
      for (var i = 0; i + 1 < hex.length; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      if (hex.length.isOdd) {
        bytes.add(int.parse(hex.substring(hex.length - 1), radix: 16) << 4);
      }
      out.add(Uint8List.fromList(bytes));
    }
    return out;
  }

  /// 字节序列 → 码点（大端，最多 4 字节）
  int _bytesToCode(Uint8List bytes) {
    var v = 0;
    for (final b in bytes) {
      v = (v << 8) | b;
    }
    return v;
  }

  /// 字节序列 → 字符串（UTF-16BE；奇数长度按单字节 Latin-1 兜底）
  String _bytesToString(Uint8List bytes) {
    if (bytes.length.isOdd) {
      // 少见：单字节目标，按 UTF-16BE 补 0 更可能对
      final padded = Uint8List(bytes.length + 1)
        ..setRange(1, bytes.length + 1, bytes);
      return _bytesToString(padded);
    }
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  /// 常见字形名 → Unicode（只列真正会遇到的；查不到就退回 Latin-1）
  String? _glyphNameToUnicode(String name) {
    if (name.length == 1) return name;
    const table = <String, String>{
      'space': ' ',
      'quotesingle': "'",
      'quotedbl': '"',
      'hyphen': '-',
      'period': '.',
      'comma': ',',
      'colon': ':',
      'semicolon': ';',
      'parenleft': '(',
      'parenright': ')',
      'bracketleft': '[',
      'bracketright': ']',
      'slash': '/',
      'backslash': '\\',
      'percent': '%',
      'plus': '+',
      'equal': '=',
      'underscore': '_',
      'ampersand': '&',
      'asterisk': '*',
      'at': '@',
      'numbersign': '#',
      'dollar': r'$',
      'exclam': '!',
      'question': '?',
      'quoteright': '\u2019',
      'quoteleft': '\u2018',
      'quotedblleft': '\u201C',
      'quotedblright': '\u201D',
      'endash': '\u2013',
      'emdash': '\u2014',
      'ellipsis': '\u2026',
      'bullet': '\u2022',
      'degree': '\u00B0',
      'fi': 'fi',
      'fl': 'fl',
    };
    final hit = table[name];
    if (hit != null) return hit;
    // `uni4E2D` / `u4E2D` 形式
    final uni = RegExp(r'^uni([0-9A-Fa-f]{4})$').firstMatch(name);
    if (uni != null) {
      return String.fromCharCode(int.parse(uni.group(1)!, radix: 16));
    }
    final u = RegExp(r'^u([0-9A-Fa-f]{4,6})$').firstMatch(name);
    if (u != null) {
      return String.fromCharCode(int.parse(u.group(1)!, radix: 16));
    }
    return null;
  }
}

/// 内容流读取器：只认"显示文字"那一小撮算子，其余跳过
class _ContentReader {
  _ContentReader(this.data, this.fonts);

  final Uint8List data;
  final Map<String, _FontInfo> fonts;

  int pos = 0;

  /// 当前字体（`Tf` 设的）
  _FontInfo current = _FontInfo.latin;

  /// 当前文字落点（**累计**坐标：`Td/TD` 是相对上一次的位移，不是绝对坐标，
  /// 当成绝对值比就会永远判不出换行 —— 真踩过）
  double _tx = 0;
  double _ty = 0;
  bool _firstBlock = true;

  final StringBuffer _out = StringBuffer();

  static bool _isWhiteByte(int c) =>
      c == 0x00 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0C ||
      c == 0x0D ||
      c == 0x20;

  String readText({required int maxChars}) {
    final operands = <Object?>[];
    while (pos < data.length && _out.length < maxChars) {
      _skipWsAndComments();
      if (pos >= data.length) break;
      final c = data[pos];
      if (c == 0x28) {
        operands.add(_PdfString(_readLiteralString()));
        continue;
      }
      if (c == 0x3C) {
        if (pos + 1 < data.length && data[pos + 1] == 0x3C) {
          _skipDict();
          continue;
        }
        operands.add(_PdfString(_readHexString()));
        continue;
      }
      if (c == 0x5B) {
        operands.add(_readArray());
        continue;
      }
      if (c == 0x2F) {
        operands.add(_PdfName(_readName()));
        continue;
      }
      if (c == 0x5D || c == 0x3E || c == 0x29) {
        pos++;
        continue;
      }
      if (c == 0x7B || c == 0x7D) {
        // PostScript 函数的 { }，内容流里不该出现，跳过
        pos++;
        continue;
      }
      final token = _readToken();
      if (token.isEmpty) {
        pos++;
        continue;
      }
      final num = _asNumber(token);
      if (num != null) {
        operands.add(num);
        continue;
      }
      _operator(token, operands);
      operands.clear();
    }
    return _finish();
  }

  void _operator(String op, List<Object?> operands) {
    switch (op) {
      case 'BT':
        _firstBlock = true;
        _tx = 0;
        _ty = 0;
        break;
      case 'Tf':
        if (operands.length >= 2) {
          final name = operands[operands.length - 2];
          if (name is _PdfName) {
            current = fonts[name.value] ?? _FontInfo.latin;
          }
        }
        break;
      case 'Td':
      case 'TD':
        if (operands.length >= 2) {
          final dy = _num(operands[operands.length - 1]);
          final dx = _num(operands[operands.length - 2]);
          _move(dx, dy);
        }
        break;
      case 'Tm':
        if (operands.length >= 6) {
          final dy = _num(operands[operands.length - 1]);
          final dx = _num(operands[operands.length - 2]);
          _move(dx, dy, absolute: true);
        }
        break;
      case 'T*':
        _newline();
        break;
      case 'Tj':
      case "'":
      case '"':
        if (op != 'Tj') _newline();
        final s = operands.isEmpty ? null : operands.last;
        if (s is _PdfString) _show(s.bytes);
        break;
      case 'TJ':
        final arr = operands.isEmpty ? null : operands.last;
        if (arr is List) {
          for (final item in arr) {
            if (item is _PdfString) {
              _show(item.bytes);
            } else if (item is num) {
              // TJ 里的数字是"要减掉的千分之一 em"：负得越多 = 字距越大，
              // 大到一定程度基本就是空格
              if (item < -120) _out.write(' ');
            }
          }
        }
        break;
    }
  }

  /// [absolute] = true 用于 `Tm`（矩阵直接给绝对位置），否则按相对位移累计
  void _move(double dx, double dy, {bool absolute = false}) {
    final nx = absolute ? dx : _tx + dx;
    final ny = absolute ? dy : _ty + dy;
    final ddx = nx - _tx;
    final ddy = ny - _ty;
    if (!_firstBlock && (ddy < -0.1 || ddx < -1)) {
      _newline();
    } else if (!_firstBlock && ddx > 6) {
      // 同一行里明显右移 = 分栏/制表，给个空格
      _out.write(' ');
    }
    _firstBlock = false;
    _tx = nx;
    _ty = ny;
  }

  void _newline() {
    if (_out.isEmpty) return;
    final s = _out.toString();
    if (!s.endsWith('\n')) _out.write('\n');
  }

  void _show(Uint8List bytes) {
    final text = _decodeString(bytes);
    if (text.isEmpty) return;
    _out.write(text);
  }

  /// 按当前字体的编码把字节串变成字符串
  String _decodeString(Uint8List bytes) {
    final cmap = current.toUnicode;
    if (current.twoByte) {
      final out = StringBuffer();
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        final code = (bytes[i] << 8) | bytes[i + 1];
        // 单字节的 CMap（不太常见）也兜一下
        if (code == 0 && bytes[i + 1] != 0) {
          out.write(_decodeSimple(bytes[i]));
          continue;
        }
        final mapped = cmap?[code];
        out.write(mapped ?? '');
      }
      if (bytes.length.isOdd) out.write(_decodeSimple(bytes.last));
      return out.toString();
    }
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(_decodeSimple(b));
    }
    return out.toString();
  }

  String _decodeSimple(int b) {
    final mapped = current.diff?[b] ?? current.toUnicode?[b];
    if (mapped != null) return mapped;
    if (b == 0) return '';
    // PDFDocEncoding 与 Latin-1 在可打印区一致，够用
    return String.fromCharCode(b);
  }

  String _finish() {
    final lines = _out
        .toString()
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return lines.join('\n');
  }

  // -------------------------------------------------------------- 词法

  void _skipWsAndComments() {
    while (pos < data.length) {
      final c = data[pos];
      if (_isWhiteByte(c)) {
        pos++;
        continue;
      }
      if (c == 0x25) {
        while (pos < data.length && data[pos] != 0x0A && data[pos] != 0x0D) {
          pos++;
        }
        continue;
      }
      break;
    }
  }

  String _readToken() {
    final start = pos;
    while (pos < data.length &&
        !_isWhiteByte(pos < data.length ? data[pos] : 0)) {
      final c = data[pos];
      if (c == 0x28 ||
          c == 0x29 ||
          c == 0x3C ||
          c == 0x3E ||
          c == 0x5B ||
          c == 0x5D ||
          c == 0x7B ||
          c == 0x7D ||
          c == 0x2F ||
          c == 0x25) {
        break;
      }
      pos++;
    }
    if (pos == start && pos < data.length) pos++;
    return String.fromCharCodes(data.sublist(start, pos));
  }

  String _readName() {
    pos++; // '/'
    final start = pos;
    while (pos < data.length) {
      final c = data[pos];
      if (_isWhiteByte(c) ||
          c == 0x2F ||
          c == 0x28 ||
          c == 0x29 ||
          c == 0x3C ||
          c == 0x3E ||
          c == 0x5B ||
          c == 0x5D ||
          c == 0x7B ||
          c == 0x7D ||
          c == 0x25) {
        break;
      }
      pos++;
    }
    return String.fromCharCodes(data.sublist(start, pos));
  }

  Uint8List _readLiteralString() {
    pos++; // '('
    final out = <int>[];
    var depth = 1;
    while (pos < data.length) {
      final c = data[pos++];
      if (c == 0x5C) {
        if (pos >= data.length) break;
        final e = data[pos++];
        switch (e) {
          case 0x6E:
            out.add(0x0A);
            break;
          case 0x72:
            out.add(0x0D);
            break;
          case 0x74:
            out.add(0x09);
            break;
          case 0x62:
            out.add(0x08);
            break;
          case 0x66:
            out.add(0x0C);
            break;
          case 0x28:
          case 0x29:
          case 0x5C:
            out.add(e);
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var v = e - 0x30;
              for (var i = 0; i < 2 && pos < data.length; i++) {
                final d = data[pos];
                if (d < 0x30 || d > 0x37) break;
                v = v * 8 + (d - 0x30);
                pos++;
              }
              out.add(v & 0xFF);
            } else if (e == 0x0A) {
              // 续行
            } else if (e == 0x0D) {
              if (pos < data.length && data[pos] == 0x0A) pos++;
            } else {
              out.add(e);
            }
        }
        continue;
      }
      if (c == 0x28) {
        depth++;
        out.add(c);
        continue;
      }
      if (c == 0x29) {
        depth--;
        if (depth == 0) break;
        out.add(c);
        continue;
      }
      out.add(c);
    }
    return Uint8List.fromList(out);
  }

  Uint8List _readHexString() {
    pos++; // '<'
    final out = <int>[];
    var hi = -1;
    while (pos < data.length) {
      final c = data[pos++];
      if (c == 0x3E) break;
      final v = _hexValue(c);
      if (v < 0) continue;
      if (hi < 0) {
        hi = v;
      } else {
        out.add((hi << 4) | v);
        hi = -1;
      }
    }
    if (hi >= 0) out.add(hi << 4);
    return Uint8List.fromList(out);
  }

  static int _hexValue(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }

  List<Object?> _readArray() {
    pos++; // '['
    final out = <Object?>[];
    while (pos < data.length) {
      _skipWsAndComments();
      if (pos >= data.length) break;
      final c = data[pos];
      if (c == 0x5D) {
        pos++;
        break;
      }
      if (c == 0x28) {
        out.add(_PdfString(_readLiteralString()));
        continue;
      }
      if (c == 0x3C) {
        out.add(_PdfString(_readHexString()));
        continue;
      }
      if (c == 0x5B) {
        out.add(_readArray());
        continue;
      }
      final token = _readToken();
      if (token.isEmpty) {
        pos++;
        continue;
      }
      final n = _asNumber(token);
      out.add(n ?? token);
    }
    return out;
  }

  void _skipDict() {
    pos += 2; // '<<'
    var depth = 1;
    while (pos < data.length) {
      final c = data[pos];
      if (c == 0x3C && pos + 1 < data.length && data[pos + 1] == 0x3C) {
        depth++;
        pos += 2;
        continue;
      }
      if (c == 0x3E && pos + 1 < data.length && data[pos + 1] == 0x3E) {
        depth--;
        pos += 2;
        if (depth == 0) return;
        continue;
      }
      if (c == 0x28) {
        _readLiteralString();
        continue;
      }
      if (c == 0x3C) {
        _readHexString();
        continue;
      }
      pos++;
    }
  }

  static num? _asNumber(String token) {
    if (token.isEmpty) return null;
    final first = token.codeUnitAt(0);
    final numeric =
        (first >= 0x30 && first <= 0x39) ||
        first == 0x2D ||
        first == 0x2B ||
        first == 0x2E;
    if (!numeric) return null;
    return double.tryParse(token) ?? int.tryParse(token);
  }

  static double _num(Object? value) => value is num ? value.toDouble() : 0;
}
