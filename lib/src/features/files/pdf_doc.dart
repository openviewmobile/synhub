// PDF 底层库（纯 Dart，直接读字节，零新依赖）：**目录（outline）+ 文字抽取**。
// 目录实现在本文件，文字抽取在同库的 `pdf_text.dart`（`part of`）里，
// 两者共用同一套 xref / 对象流 / 过滤器解码代码。
//
// 为什么自己写：本项目的 PDF 渲染走 `pdfx`（Android 是系统
// `android.graphics.pdf.PdfRenderer`，iOS/macOS 是 PDFKit），它只暴露
// `pagesCount` + `getPage`，**没有任何目录 API**（已核对 pub 缓存里的
// `pdfx-2.11.0/lib/src/renderer/interfaces/document.dart`）。我们也不想为了
// 一个侧边目录再塞一个原生 PDF 库（APK 体积、构建期还要下二进制）。
//
// 几条踩过坑之后的硬规矩：
//   * **绝不向调用方抛异常**。用户丢进来的 PDF 千奇百怪（截断、对象号错乱、
//     xref 损坏、加密、奇怪编码），解析不了就返回空表，UI 退化成"没有目录"——
//     比整个阅读页崩一下强得多。所以入口包 try/catch，递归有深度上限，
//     `/Next` 自指这类环用 visited 集合兜住。
//   * **先扫 `N G obj`，再读 xref，xref 优先覆盖**。很多工具产出的 xref 是坏的
//     但对象字节还在；反过来 xref 也可能把对象藏进对象流、或指向被覆盖的旧版本。
//     两边合并、xref 赢了才最宽容。
//   * 只实现"取目录"真正会遇到的过滤器（Flate + PNG/TIFF 预测器、ASCIIHex、
//     ASCII85）。LZW / DCT / JPX / CCITT 一律放弃，不值得为目录写图像解码器。
//   * 页码用 `/Root /Pages` 页树里 `/Type /Page` 的出现顺序算，**不能**拿对象号
//     当页序——真实文件里对象号顺序和页序经常不一致。
library;

import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import '../../core/i18n/l10n.dart';
import '../../core/user_facing_error.dart';

// 文本抽取（`extractPdfText`）也用这份 xref/流解码实现，所以做成 part。
// 好处：不用把 700 行底层代码复制一遍，也不用把私有成员暴露出去。
part 'pdf_text.dart';

/// 最近一次解析失败的原因，给日志/调试用。
///
/// 刻意做成顶层可空变量而不是把异常抛给调用方：`parsePdfToc` 的契约是"要么给
/// 目录，要么给空表"，调用方（阅读页）不需要 try/catch。写值只在单线程解析时
/// 发生，没有并发问题。
String? lastPdfTocError;

/// PDF 目录里的一条（拍平，靠 [depth] 表示层级，方便直接丢给 ListView）。
class PdfTocEntry {
  const PdfTocEntry({required this.title, required this.depth, this.pageIndex});

  final String title;

  /// 0 = 顶层
  final int depth;

  /// 0 基页码；定位不到（命名目标丢失/目标不是页面）→ null
  final int? pageIndex;
}

/// 从 PDF 字节里取目录。没有目录、加密、解析失败 → 返回空表（**不抛**）。
List<PdfTocEntry> parsePdfToc(Uint8List bytes) {
  lastPdfTocError = null;
  if (bytes.length < 8) {
    lastPdfTocError = currentText().pdfTooShortBytes(bytes.length);
    return const [];
  }
  try {
    return _PdfDoc(bytes).readOutline();
  } catch (e) {
    lastPdfTocError = currentText().pdfTocParseFailed(userFacingError(e));
    return const [];
  }
}

// ---------------------------------------------------------------------------
// 词法层：PDF 对象模型
// ---------------------------------------------------------------------------

/// 名字对象（`/Foo`）。和普通字符串必须区分开：`/Dest /chapter1` 是名字，
/// `(chapter1)` 是字符串，两者都是"命名目标"，但取值方式不同。
class _PdfName {
  const _PdfName(this.value);
  final String value;
}

/// 间接引用（`3 0 R`）。只存对象号，代次对我们取目录没意义。
class _PdfRef {
  const _PdfRef(this.num, this.gen);
  final int num;
  final int gen;
}

/// PDF 字符串。**先存原始字节、用到再解码**：同一串字节在 `/Title` 里要按
/// PDFDocEncoding/UTF-16 解，在名字树键里就该按字节值用，提前解码会丢信息。
class _PdfString {
  const _PdfString(this.bytes);
  final Uint8List bytes;
}

/// 流对象：字典 + 原始（未解压）字节。解压在真正要读内容时才做。
class _PdfStream {
  const _PdfStream(this.dict, this.raw);
  final Map<String, Object?> dict;
  final Uint8List raw;
}

/// 对象流里的一个槽位：哪个对象流、流内第几个对象。
typedef _ObjStmSlot = (int stmNum, int index);

class _PdfSyntaxException implements Exception {
  const _PdfSyntaxException(this.message);
  final String message;
  @override
  String toString() => 'PDF 语法错误：$message';
}

bool _isWhite(int c) =>
    c == 0x00 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20;

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isDelimiter(int c) =>
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

bool _isRegular(int c) => !_isWhite(c) && !_isDelimiter(c);

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

int _indexOfAscii(Uint8List data, String needle, int from) {
  final first = needle.codeUnitAt(0);
  for (var i = from; i + needle.length <= data.length; i++) {
    if (data[i] != first) continue;
    var ok = true;
    for (var j = 1; j < needle.length; j++) {
      if (data[i + j] != needle.codeUnitAt(j)) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

int _lastIndexOfAscii(Uint8List data, String needle) {
  for (var i = data.length - needle.length; i >= 0; i--) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (data[i + j] != needle.codeUnitAt(j)) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// 一个够用的 PDF 对象解析器：dict / array / name / number / string / ref /
/// bool / null。输入是字节 + 位置，方法原地推进 [pos]。
class _PdfLexer {
  _PdfLexer(this.data, this.pos, {this.resolveLength});

  final Uint8List data;
  int pos;
  final int? Function(Object? value)? resolveLength;

  bool get atEnd => pos >= data.length;
  int get peek => pos < data.length ? data[pos] : -1;

  void skipWs() {
    while (pos < data.length) {
      final c = data[pos];
      if (_isWhite(c)) {
        pos++;
      } else if (c == 0x25) {
        // 注释：吃到行尾（但不要把 \r\n 之外的东西也行尾化）
        while (pos < data.length && data[pos] != 0x0A && data[pos] != 0x0D) {
          pos++;
        }
      } else {
        return;
      }
    }
  }

  bool _matchAsciiAt(String s) {
    if (pos + s.length > data.length) return false;
    for (var i = 0; i < s.length; i++) {
      if (data[pos + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  bool _boundaryAfter(int end) => end >= data.length || !_isRegular(data[end]);

  bool peekKeyword(String kw) {
    final save = pos;
    skipWs();
    final ok = _matchAsciiAt(kw) && _boundaryAfter(pos + kw.length);
    pos = save;
    return ok;
  }

  bool matchKeyword(String kw) {
    skipWs();
    if (_matchAsciiAt(kw) && _boundaryAfter(pos + kw.length)) {
      pos += kw.length;
      return true;
    }
    return false;
  }

  void expectKeyword(String kw) {
    if (!matchKeyword(kw)) throw _PdfSyntaxException('期望关键字 $kw');
  }

  int? tryParseInt() {
    skipWs();
    final start = pos;
    if (pos < data.length && (data[pos] == 0x2B || data[pos] == 0x2D)) pos++;
    final digitsStart = pos;
    while (pos < data.length && _isDigit(data[pos])) {
      pos++;
    }
    if (pos == digitsStart) {
      pos = start;
      return null;
    }
    return int.tryParse(String.fromCharCodes(data, start, pos));
  }

  Object? parseObject() {
    skipWs();
    if (atEnd) throw const _PdfSyntaxException('对象意外结束');
    final c = data[pos];
    if (c == 0x2F) return _parseName();
    if (c == 0x28) return _parseLiteralString();
    if (c == 0x3C) {
      if (pos + 1 < data.length && data[pos + 1] == 0x3C) return _parseDict();
      return _parseHexString();
    }
    if (c == 0x5B) return _parseArray();
    if (c == 0x74) {
      expectKeyword('true');
      return true;
    }
    if (c == 0x66) {
      expectKeyword('false');
      return false;
    }
    if (c == 0x6E) {
      expectKeyword('null');
      return null;
    }
    if (c == 0x2B || c == 0x2D || c == 0x2E || _isDigit(c)) {
      return _parseNumberOrRef();
    }
    throw _PdfSyntaxException('未知对象起始字节 0x${c.toRadixString(16)}');
  }

  _PdfName _parseName() {
    pos++; // 跳过 '/'
    final bytes = <int>[];
    while (pos < data.length && _isRegular(data[pos])) {
      final c = data[pos];
      if (c == 0x23 && pos + 2 < data.length) {
        final h1 = _hexValue(data[pos + 1]);
        final h2 = _hexValue(data[pos + 2]);
        if (h1 >= 0 && h2 >= 0) {
          bytes.add((h1 << 4) | h2);
          pos += 3;
          continue;
        }
      }
      bytes.add(c);
      pos++;
    }
    return _PdfName(latin1.decode(Uint8List.fromList(bytes)));
  }

  _PdfString _parseLiteralString() {
    pos++; // 跳过 '('
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
          case 0x72:
            out.add(0x0D);
          case 0x74:
            out.add(0x09);
          case 0x62:
            out.add(0x08);
          case 0x66:
            out.add(0x0C);
          case 0x28:
            out.add(0x28);
          case 0x29:
            out.add(0x29);
          case 0x5C:
            out.add(0x5C);
          case 0x0A:
            break; // 反斜杠 + 换行 = 续行，什么都不加
          case 0x0D:
            if (pos < data.length && data[pos] == 0x0A) pos++;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var v = e - 0x30;
              var n = 1;
              while (n < 3 && pos < data.length) {
                final d = data[pos];
                if (d < 0x30 || d > 0x37) break;
                v = (v << 3) + (d - 0x30);
                pos++;
                n++;
              }
              out.add(v & 0xFF);
            } else {
              out.add(e); // 未知转义：按规范丢掉反斜杠
            }
        }
      } else if (c == 0x28) {
        depth++;
        out.add(c);
      } else if (c == 0x29) {
        depth--;
        if (depth == 0) break;
        out.add(c);
      } else {
        out.add(c);
      }
    }
    return _PdfString(Uint8List.fromList(out));
  }

  _PdfString _parseHexString() {
    pos++; // 跳过 '<'
    final out = <int>[];
    var hi = -1;
    while (pos < data.length) {
      final c = data[pos++];
      if (c == 0x3E) break;
      final v = _hexValue(c);
      if (v < 0) continue; // 空白和其他杂字符直接忽略
      if (hi < 0) {
        hi = v;
      } else {
        out.add((hi << 4) | v);
        hi = -1;
      }
    }
    if (hi >= 0) out.add(hi << 4); // 奇数个 hex 位：末尾补 0
    return _PdfString(Uint8List.fromList(out));
  }

  List<Object?> _parseArray() {
    pos++; // 跳过 '['
    final out = <Object?>[];
    while (true) {
      skipWs();
      if (atEnd) throw const _PdfSyntaxException('数组未闭合');
      if (data[pos] == 0x5D) {
        pos++;
        return out;
      }
      out.add(parseObject());
      if (out.length > 100000) throw const _PdfSyntaxException('数组过大');
    }
  }

  Map<String, Object?> _parseDict() {
    pos += 2; // 跳过 '<<'
    final out = <String, Object?>{};
    while (true) {
      skipWs();
      if (atEnd) throw const _PdfSyntaxException('字典未闭合');
      if (data[pos] == 0x3E && pos + 1 < data.length && data[pos + 1] == 0x3E) {
        pos += 2;
        return out;
      }
      final key = parseObject();
      if (key is! _PdfName) throw const _PdfSyntaxException('字典键不是名字');
      out[key.value] = parseObject();
    }
  }

  Object? _parseNumberOrRef() {
    final start = pos;
    final value = _parseNumber();
    // 引用检测：数字 数字 R。仅在第一个数是整数时才可能。
    if (value is int) {
      final save = pos;
      skipWs();
      if (pos < data.length && _isDigit(data[pos])) {
        final second = tryParseInt();
        if (second != null) {
          skipWs();
          if (pos < data.length &&
              data[pos] == 0x52 && // 'R'
              _boundaryAfter(pos + 1)) {
            pos++;
            return _PdfRef(value, second);
          }
        }
      }
      pos = save;
    }
    if (pos == start) throw const _PdfSyntaxException('数字解析失败');
    return value;
  }

  num _parseNumber() {
    final start = pos;
    if (pos < data.length && (data[pos] == 0x2B || data[pos] == 0x2D)) pos++;
    while (pos < data.length && _isDigit(data[pos])) {
      pos++;
    }
    var isReal = false;
    if (pos < data.length && data[pos] == 0x2E) {
      isReal = true;
      pos++;
      while (pos < data.length && _isDigit(data[pos])) {
        pos++;
      }
    }
    if (pos < data.length && (data[pos] == 0x65 || data[pos] == 0x45)) {
      final save = pos;
      pos++;
      if (pos < data.length && (data[pos] == 0x2B || data[pos] == 0x2D)) pos++;
      if (pos < data.length && _isDigit(data[pos])) {
        isReal = true;
        while (pos < data.length && _isDigit(data[pos])) {
          pos++;
        }
      } else {
        pos = save;
      }
    }
    final text = String.fromCharCodes(data, start, pos);
    if (!isReal) {
      final i = int.tryParse(text);
      if (i != null) return i;
    }
    final d = double.tryParse(text);
    if (d == null) throw _PdfSyntaxException('非法数字 "$text"');
    return d;
  }
}

// ---------------------------------------------------------------------------
// 文档层：对象访问、xref、对象流、过滤器、页树、目录
// ---------------------------------------------------------------------------

class _PdfDoc {
  _PdfDoc(this.bytes) {
    _scanRawObjects();
  }

  final Uint8List bytes;

  /// 裸扫出来的 `N G obj` 偏移。xref 坏掉/缺失时的兜底。
  final Map<int, int> _rawOffsets = {};

  /// xref 声明的位置（经典表 type 1 / XRef 流 type 1）。权威，优先于裸扫。
  final Map<int, int> _xrefOffsets = {};

  /// 在对象流里的对象：对象号 → 槽位。
  final Map<int, _ObjStmSlot> _objStmSlots = {};

  final Map<int, Object?> _cache = {};
  final Map<int, Map<int, Object?>?> _objStmCache = {};
  final Set<int> _resolving = {};
  final Map<int, int> _pageIndexByRef = {};

  Map<String, Object?>? _trailer;
  Map<String, Object?>? _catalog;
  Map<String, Object?>? _namedDests;
  bool _namedDestsBuilt = false;

  // --- 对外流程 ---

  List<PdfTocEntry> readOutline() {
    _loadXref();
    final trailer = _trailer;
    if (trailer != null && trailer['Encrypt'] != null) {
      lastPdfTocError = currentText().pdfEncrypted;
      return const [];
    }
    _catalog = _findCatalog();
    if (_catalog == null) {
      lastPdfTocError = currentText().pdfNoCatalog;
      return const [];
    }
    if (_catalog!['Encrypt'] != null) {
      lastPdfTocError = currentText().pdfEncrypted;
      return const [];
    }
    _buildPageTree();
    _buildNamedDests();
    return _extractOutline();
  }

  // --- 原始扫描：`N G obj` ---

  void _scanRawObjects() {
    final n = bytes.length;
    for (var i = 0; i + 3 < n; i++) {
      if (bytes[i] != 0x6F || bytes[i + 1] != 0x62 || bytes[i + 2] != 0x6A) {
        continue;
      }
      if (!_isWhite(bytes[i + 3]) && !_isDelimiter(bytes[i + 3])) continue;
      // 往前找 "N G obj" 的两个数字，前面必须是空白/分隔符/文件头。
      var j = i - 1;
      while (j >= 0 && _isWhite(bytes[j])) {
        j--;
      }
      final genEnd = j + 1;
      while (j >= 0 && _isDigit(bytes[j])) {
        j--;
      }
      final genStart = j + 1;
      if (genStart >= genEnd) continue;
      while (j >= 0 && _isWhite(bytes[j])) {
        j--;
      }
      final numEnd = j + 1;
      while (j >= 0 && _isDigit(bytes[j])) {
        j--;
      }
      final numStart = j + 1;
      if (numStart >= numEnd) continue;
      if (j >= 0 && !_isWhite(bytes[j]) && !_isDelimiter(bytes[j])) continue;
      final num = int.tryParse(String.fromCharCodes(bytes, numStart, numEnd));
      if (num == null) continue;
      // "N G obj" 里 N 的十进制位数不影响偏移（偏移从数字开头算）。
      final gen = int.tryParse(String.fromCharCodes(bytes, genStart, genEnd));
      if (gen == null) continue;
      // 同一个对象号重复出现（增量更新）时保留**最先**扫到的，避免把压缩流里
      // 偶然出现的 "1 0 obj" 当成对象。
      _rawOffsets.putIfAbsent(num, () => numStart);
    }
  }

  // --- xref ---

  void _loadXref() {
    final sx = _findLastStartXref();
    if (sx != null) _parseXrefAt(sx, <int>{});
    _trailer ??= _findLastTrailerDict();
  }

  int? _findLastStartXref() {
    final at = _lastIndexOfAscii(bytes, 'startxref');
    if (at < 0) return null;
    final lex = _PdfLexer(bytes, at + 'startxref'.length);
    return lex.tryParseInt();
  }

  Map<String, Object?>? _findLastTrailerDict() {
    final at = _lastIndexOfAscii(bytes, 'trailer');
    if (at < 0) return null;
    try {
      final lex = _PdfLexer(
        bytes,
        at + 'trailer'.length,
        resolveLength: _resolveLength,
      );
      final value = lex.parseObject();
      return value is Map<String, Object?> ? value : null;
    } catch (_) {
      return null;
    }
  }

  void _parseXrefAt(int offset, Set<int> seen) {
    if (offset <= 0 || offset >= bytes.length) return;
    if (!seen.add(offset)) return; // /Prev 成环
    final lex = _PdfLexer(bytes, offset, resolveLength: _resolveLength);
    Map<String, Object?>? sectionTrailer;
    if (lex.peekKeyword('xref')) {
      lex.expectKeyword('xref');
      sectionTrailer = _parseClassicXref(lex);
    } else {
      // XRef 流：一个普通间接对象，但里面的字典就是 trailer。
      try {
        final obj = _parseIndirectObjectAt(offset);
        if (obj is _PdfStream && _nameOf(obj.dict['Type']) == 'XRef') {
          _applyXrefStream(obj);
          sectionTrailer = obj.dict;
        }
      } catch (_) {
        return;
      }
    }
    if (sectionTrailer == null) return;
    // 从 startxref 出发先到的是**最新**的 section，先到先得。
    _trailer ??= sectionTrailer;
    final xrefStm = _intOf(resolve(sectionTrailer['XRefStm']));
    if (xrefStm != null) _parseXrefAt(xrefStm, seen);
    final prev = _intOf(resolve(sectionTrailer['Prev']));
    if (prev != null) _parseXrefAt(prev, seen);
  }

  Map<String, Object?>? _parseClassicXref(_PdfLexer lex) {
    while (true) {
      lex.skipWs();
      if (lex.atEnd) return null;
      if (lex.peekKeyword('trailer')) {
        lex.expectKeyword('trailer');
        final value = lex.parseObject();
        return value is Map<String, Object?> ? value : null;
      }
      final start = lex.tryParseInt();
      final count = lex.tryParseInt();
      if (start == null || count == null || count < 0) return null;
      for (var i = 0; i < count; i++) {
        lex.skipWs();
        final f1 = lex.tryParseInt();
        final f2 = lex.tryParseInt();
        lex.skipWs();
        final typeChar = lex.peek;
        if (typeChar == 0x6E || typeChar == 0x66) lex.pos++;
        if (f1 == null || f2 == null) return null;
        if (typeChar == 0x66) continue; // free
        _xrefOffsets.putIfAbsent(start + i, () => f1);
      }
    }
  }

  void _applyXrefStream(_PdfStream stream) {
    final dict = stream.dict;
    final widths = <int>[];
    final wValue = resolve(dict['W']);
    if (wValue is List) {
      for (final e in wValue) {
        widths.add(_intOf(resolve(e)) ?? 0);
      }
    }
    while (widths.length < 3) {
      widths.add(0);
    }
    final rowLength = widths[0] + widths[1] + widths[2];
    if (rowLength <= 0) return;
    final data = _decodeStream(stream);
    if (data == null) return;
    final size = _intOf(resolve(dict['Size'])) ?? 0;
    final index = <int>[];
    final indexValue = resolve(dict['Index']);
    if (indexValue is List) {
      for (final e in indexValue) {
        index.add(_intOf(resolve(e)) ?? 0);
      }
    }
    if (index.isEmpty) {
      index.addAll([0, size]);
    }
    var p = 0;
    for (var s = 0; s + 1 < index.length; s += 2) {
      final start = index[s];
      final count = index[s + 1];
      for (var i = 0; i < count; i++) {
        if (p + rowLength > data.length) return;
        final type = widths[0] == 0 ? 1 : _readBigEndian(data, p, widths[0]);
        final f2 = widths[1] == 0
            ? 0
            : _readBigEndian(data, p + widths[0], widths[1]);
        final f3 = widths[2] == 0
            ? 0
            : _readBigEndian(data, p + widths[0] + widths[1], widths[2]);
        p += rowLength;
        final num = start + i;
        if (type == 1) {
          if (f2 > 0) _xrefOffsets.putIfAbsent(num, () => f2);
        } else if (type == 2) {
          _objStmSlots.putIfAbsent(num, () => (f2, f3));
        }
      }
    }
  }

  static int _readBigEndian(Uint8List data, int start, int width) {
    var v = 0;
    for (var i = 0; i < width; i++) {
      v = (v << 8) | data[start + i];
    }
    return v;
  }

  // --- 对象访问 ---

  Object? resolve(Object? obj) {
    if (obj is _PdfRef) return _resolveRef(obj.num);
    return obj;
  }

  Map<String, Object?>? _resolveDict(Object? obj) {
    final value = resolve(obj);
    return value is Map<String, Object?> ? value : null;
  }

  Object? _resolveRef(int num) {
    if (_cache.containsKey(num)) return _cache[num];
    if (!_resolving.add(num)) return null; // 循环引用
    Object? value;
    try {
      final slot = _objStmSlots[num];
      if (slot != null) {
        value = _loadObjStm(slot.$1)?[num];
      } else {
        final offset = _xrefOffsets[num] ?? _rawOffsets[num];
        if (offset != null && offset > 0 && offset < bytes.length) {
          value = _parseIndirectObjectAt(offset);
        }
      }
    } catch (_) {
      value = null;
    } finally {
      _resolving.remove(num);
    }
    _cache[num] = value;
    return value;
  }

  Object? _parseIndirectObjectAt(int offset) {
    final lex = _PdfLexer(bytes, offset, resolveLength: _resolveLength);
    final num = lex.tryParseInt();
    final gen = lex.tryParseInt();
    if (num == null || gen == null) throw const _PdfSyntaxException('对象头非法');
    lex.expectKeyword('obj');
    final value = lex.parseObject();
    if (value is Map<String, Object?> && lex.matchKeyword('stream')) {
      return _readStream(lex, value);
    }
    return value;
  }

  int? _resolveLength(Object? value) {
    final resolved = resolve(value);
    return _intOf(resolved);
  }

  _PdfStream _readStream(_PdfLexer lex, Map<String, Object?> dict) {
    // `stream` 关键字后面规范要求跟 CRLF 或 LF，但那一个 EOL 不属于数据。
    if (lex.pos < bytes.length && bytes[lex.pos] == 0x0D) lex.pos++;
    if (lex.pos < bytes.length && bytes[lex.pos] == 0x0A) lex.pos++;
    final start = lex.pos;
    final length = _intOf(resolve(dict['Length']));
    if (length != null && length >= 0 && start + length <= bytes.length) {
      return _PdfStream(
        dict,
        Uint8List.sublistView(bytes, start, start + length),
      );
    }
    // /Length 缺失或说谎（真实文件里不少见）：退回到找 endstream。
    final at = _indexOfAscii(bytes, 'endstream', start);
    var end = at < 0 ? bytes.length : at;
    if (end > start && bytes[end - 1] == 0x0A) end--;
    if (end > start && bytes[end - 1] == 0x0D) end--;
    return _PdfStream(dict, Uint8List.sublistView(bytes, start, end));
  }

  // --- 对象流 ---

  Map<int, Object?>? _loadObjStm(int stmNum) {
    if (_objStmCache.containsKey(stmNum)) return _objStmCache[stmNum];
    _objStmCache[stmNum] = null; // 防递归
    final stream = _resolveRef(stmNum);
    if (stream is! _PdfStream) return null;
    final data = _decodeStream(stream);
    if (data == null) return null;
    final count = _intOf(resolve(stream.dict['N']));
    final first = _intOf(resolve(stream.dict['First']));
    if (count == null || first == null || first < 0 || first > data.length) {
      return null;
    }
    // 前 First 字节是 "objnum offset" 对（offset 相对 First）。
    final headerLex = _PdfLexer(data, 0);
    final pairs = <(int, int)>[];
    for (var i = 0; i < count; i++) {
      final num = headerLex.tryParseInt();
      final off = headerLex.tryParseInt();
      if (num == null || off == null) break;
      pairs.add((num, off));
    }
    final parsed = <int, Object?>{};
    for (final (num, off) in pairs) {
      final at = first + off;
      if (at < 0 || at >= data.length) continue;
      try {
        final lex = _PdfLexer(data, at);
        parsed[num] = lex.parseObject();
      } catch (_) {
        // 单个对象坏了不影响其它对象
      }
    }
    _objStmCache[stmNum] = parsed;
    return parsed;
  }

  // --- 过滤器 ---

  Uint8List? _decodeStream(_PdfStream stream) {
    var data = stream.raw;
    final filters = <String>[];
    final filterValue = resolve(stream.dict['Filter'] ?? stream.dict['F']);
    if (filterValue is _PdfName) {
      filters.add(filterValue.value);
    } else if (filterValue is List) {
      for (final e in filterValue) {
        final r = resolve(e);
        if (r is _PdfName) filters.add(r.value);
      }
    }
    final parms = <Map<String, Object?>?>[];
    final parmsValue = resolve(stream.dict['DecodeParms'] ?? stream.dict['DP']);
    if (parmsValue is Map<String, Object?>) {
      parms.add(parmsValue);
    } else if (parmsValue is List) {
      for (final e in parmsValue) {
        final r = resolve(e);
        parms.add(r is Map<String, Object?> ? r : null);
      }
    }
    for (var i = 0; i < filters.length; i++) {
      final parm = i < parms.length ? parms[i] : null;
      switch (filters[i]) {
        case 'FlateDecode':
        case 'Fl':
          final inflated = _inflate(data);
          if (inflated == null) return null;
          data = _applyPredictor(inflated, parm);
        case 'ASCIIHexDecode':
        case 'AHx':
          data = _asciiHexDecode(data);
        case 'ASCII85Decode':
        case 'A85':
          data = _ascii85Decode(data);
        case 'Crypt':
          continue; // 空加密的恒等过滤器
        default:
          // LZW / DCT / JPX / CCITT / RunLength：不做，让调用方退化。
          return null;
      }
    }
    return data;
  }

  Uint8List? _inflate(Uint8List data) {
    // 有些生成器写出来的 Flate 流没有 zlib 头（raw deflate），两种都试。
    for (final raw in const [false, true]) {
      try {
        return Uint8List.fromList(ZLibDecoder(raw: raw).convert(data));
      } catch (_) {
        continue; // 换另一种再试
      }
    }
    return null;
  }

  Uint8List _applyPredictor(Uint8List data, Map<String, Object?>? parms) {
    if (parms == null) return data;
    final predictor = _intOf(resolve(parms['Predictor'])) ?? 1;
    if (predictor < 2) return data;
    final colors = _intOf(resolve(parms['Colors'])) ?? 1;
    final bits = _intOf(resolve(parms['BitsPerComponent'])) ?? 8;
    final columns = _intOf(resolve(parms['Columns'])) ?? 1;
    final bpp = ((colors * bits) + 7) ~/ 8;
    final rowLength = ((colors * bits * columns) + 7) ~/ 8;
    if (rowLength <= 0 || bpp <= 0) return data;
    if (predictor == 2) return _tiffPredictor(data, bpp, rowLength);
    // PNG 预测器（10..15）：每行前面有一个 filter type 字节。
    final out = BytesBuilder();
    var previous = Uint8List(rowLength);
    var p = 0;
    while (p + 1 + rowLength <= data.length) {
      final type = data[p++];
      final row = Uint8List.fromList(data.sublist(p, p + rowLength));
      p += rowLength;
      switch (type) {
        case 0:
          break;
        case 1:
          for (var i = bpp; i < rowLength; i++) {
            row[i] = (row[i] + row[i - bpp]) & 0xFF;
          }
        case 2:
          for (var i = 0; i < rowLength; i++) {
            row[i] = (row[i] + previous[i]) & 0xFF;
          }
        case 3:
          for (var i = 0; i < rowLength; i++) {
            final left = i >= bpp ? row[i - bpp] : 0;
            row[i] = (row[i] + ((left + previous[i]) >> 1)) & 0xFF;
          }
        case 4:
          for (var i = 0; i < rowLength; i++) {
            final a = i >= bpp ? row[i - bpp] : 0;
            final b = previous[i];
            final c = i >= bpp ? previous[i - bpp] : 0;
            row[i] = (row[i] + _paeth(a, b, c)) & 0xFF;
          }
        default:
          // 未知 filter type：当作 none，至少别把行搞乱
          break;
      }
      out.add(row);
      previous = row;
    }
    if (p < data.length) out.add(Uint8List.sublistView(data, p));
    return out.takeBytes();
  }

  static int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs();
    final pb = (p - b).abs();
    final pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
  }

  Uint8List _tiffPredictor(Uint8List data, int bpp, int rowLength) {
    if (rowLength <= 0) return data;
    for (var row = 0; row + rowLength <= data.length; row += rowLength) {
      for (var i = bpp; i < rowLength; i++) {
        data[row + i] = (data[row + i] + data[row + i - bpp]) & 0xFF;
      }
    }
    return data;
  }

  Uint8List _asciiHexDecode(Uint8List data) {
    final out = <int>[];
    var hi = -1;
    for (final c in data) {
      if (c == 0x3E) break; // '>'
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

  Uint8List _ascii85Decode(Uint8List data) {
    final out = <int>[];
    var tuple = 0;
    var count = 0;
    for (final c in data) {
      if (c == 0x7E) break; // '~' 结束
      if (_isWhite(c)) continue;
      if (c == 0x7A && count == 0) {
        out.addAll(const [0, 0, 0, 0]); // 'z' = 四个 0
        continue;
      }
      if (c < 0x21 || c > 0x75) continue;
      tuple = tuple * 85 + (c - 0x21);
      count++;
      if (count == 5) {
        for (var s = 24; s >= 0; s -= 8) {
          out.add((tuple >> s) & 0xFF);
        }
        tuple = 0;
        count = 0;
      }
    }
    if (count > 0) {
      final produced = <int>[];
      for (var i = count; i < 5; i++) {
        tuple = tuple * 85 + 84;
      }
      for (var s = 24; s >= 0; s -= 8) {
        produced.add((tuple >> s) & 0xFF);
      }
      out.addAll(produced.take(count - 1)); // 尾部不足 5 个字符只出 count-1 字节
    }
    return Uint8List.fromList(out);
  }

  // --- 目录/页树/命名目标 ---

  Map<String, Object?>? _findCatalog() {
    final root = _resolveDict(_trailer?['Root']);
    if (root != null) return root;
    // trailer 没了（xref 全坏）时，裸扫的对象里找 /Type /Catalog。
    final candidates = <int>{..._xrefOffsets.keys, ..._rawOffsets.keys};
    for (final num in candidates) {
      final value = _resolveRef(num);
      if (value is Map<String, Object?> &&
          _nameOf(value['Type']) == 'Catalog') {
        return value;
      }
    }
    return null;
  }

  void _buildPageTree() {
    _pageIndexByRef.clear();
    final pagesRef = _catalog?['Pages'];
    var counter = 0;
    final visited = <int>{};
    void walk(Object? node, int depth) {
      if (depth > 64) return;
      if (node is _PdfRef && !visited.add(node.num)) return;
      final dict = _resolveDict(node);
      if (dict == null) return;
      final type = _nameOf(dict['Type']);
      final kids = dict['Kids'];
      if (type == 'Page' || (type == null && kids == null)) {
        if (node is _PdfRef) {
          _pageIndexByRef.putIfAbsent(node.num, () => counter);
        }
        counter++;
        return;
      }
      if (kids is List) {
        for (final kid in kids) {
          walk(kid, depth + 1);
        }
      }
    }

    walk(pagesRef, 0);
  }

  void _buildNamedDests() {
    if (_namedDestsBuilt) return;
    _namedDestsBuilt = true;
    final map = <String, Object?>{};
    // 老式的 catalog /Dests 字典：名字 → 目标
    final dests = _resolveDict(_catalog?['Dests']);
    if (dests != null) {
      map.addAll(dests);
    }
    // 新式的 /Names /Dests 名字树
    final names = _resolveDict(_catalog?['Names']);
    final tree = _resolveDict(names?['Dests']);
    if (tree != null) _walkNameTree(tree, map, <int>{}, 0);
    _namedDests = map;
  }

  void _walkNameTree(
    Map<String, Object?> node,
    Map<String, Object?> out,
    Set<int> visited,
    int depth,
  ) {
    if (depth > 32) return;
    final names = node['Names'];
    if (names is List) {
      for (var i = 0; i + 1 < names.length; i += 2) {
        final key = _nameKeyOf(names[i]);
        if (key != null) out.putIfAbsent(key, () => names[i + 1]);
      }
    }
    final kids = node['Kids'];
    if (kids is List) {
      for (final kid in kids) {
        if (kid is _PdfRef && !visited.add(kid.num)) continue;
        final child = _resolveDict(kid);
        if (child != null) _walkNameTree(child, out, visited, depth + 1);
      }
    }
  }

  String? _nameKeyOf(Object? obj) {
    if (obj is _PdfName) return obj.value;
    if (obj is _PdfString) return latin1.decode(obj.bytes);
    return null;
  }

  List<PdfTocEntry> _extractOutline() {
    final outlines = _resolveDict(_catalog?['Outlines']);
    if (outlines == null) return const [];
    final entries = <PdfTocEntry>[];
    final visited = <int>{};
    void walk(Object? node, int depth) {
      var current = node;
      var guard = 0;
      // 用 /Next 链走兄弟（不是 /Count 猜），visited 挡住自指/互指的环。
      while (current != null && guard++ < 20000) {
        if (current is _PdfRef && !visited.add(current.num)) break;
        final item = _resolveDict(current);
        if (item == null) break;
        final title = _decodeText(item['Title']);
        if (title != null && title.trim().isNotEmpty) {
          final dest = item.containsKey('Dest')
              ? item['Dest']
              : _actionDest(item['A']);
          entries.add(
            PdfTocEntry(
              title: title,
              depth: depth,
              pageIndex: _resolveDestPage(dest),
            ),
          );
        }
        if (depth + 1 < 64) {
          final first = item['First'];
          if (first != null) walk(first, depth + 1);
        }
        current = item['Next'];
      }
    }

    walk(outlines['First'], 0);
    return entries;
  }

  /// `/A << /S /GoTo /D ... >>` 里的 /D；其它动作类型（GoToR/URI/JavaScript
  /// 等）不入目录，返回 null。
  Object? _actionDest(Object? action) {
    final dict = _resolveDict(action);
    if (dict == null) return null;
    if (_nameOf(dict['S']) != 'GoTo') return null;
    return dict['D'];
  }

  int? _resolveDestPage(Object? dest, [int depth = 0]) {
    if (dest == null || depth > 16) return null;
    // /Dest 也可能是个间接引用，指向数组/字典/名字目标。
    if (dest is _PdfRef) return _resolveDestPage(resolve(dest), depth + 1);
    if (dest is List) {
      if (dest.isEmpty) return null;
      // 这里**不能先 resolve**：解引用会返回页字典，页对象号就丢了。
      final first = dest.first;
      if (first is _PdfRef) return _pageIndexByRef[first.num];
      if (first is int) return first - 1; // 整数是 1 基页码
      final resolved = resolve(first);
      if (resolved is _PdfRef) return _pageIndexByRef[resolved.num];
      if (resolved is int) return resolved - 1;
      return null;
    }
    if (dest is Map<String, Object?>) {
      // 显式目标字典 /D，或命名目标在名字树里写成字典
      if (dest.containsKey('D')) return _resolveDestPage(dest['D'], depth + 1);
      return null;
    }
    if (dest is _PdfName) return _resolveNamedDest(dest.value, depth);
    if (dest is _PdfString) {
      final key = latin1.decode(dest.bytes);
      return _resolveNamedDest(key, depth);
    }
    return null;
  }

  int? _resolveNamedDest(String name, int depth) {
    if (depth > 16) return null;
    final dest = _namedDests?[name];
    if (dest == null) return null;
    // 命名目标的值本身也可能是另一个名字（少见），带深度上限防环。
    return _resolveDestPage(dest, depth + 1);
  }

  // --- 文本解码 ---

  String? _decodeText(Object? obj) {
    if (obj is! _PdfString) return null;
    final b = obj.bytes;
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      return _decodeUtf16(b, 2, true);
    }
    if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
      return _decodeUtf16(b, 2, false);
    }
    // 没有 BOM：很多工具直接塞 UTF-8 字节，先按严格 UTF-8 试；不是就走
    // PDFDocEncoding（≈ Latin-1 + 少量特殊码位）。
    try {
      return const Utf8Decoder(allowMalformed: false).convert(b);
    } catch (_) {
      return _decodePdfDoc(b);
    }
  }

  static String _decodeUtf16(Uint8List b, int start, bool bigEndian) {
    final units = <int>[];
    for (var i = start; i + 1 < b.length; i += 2) {
      units.add(bigEndian ? (b[i] << 8) | b[i + 1] : (b[i + 1] << 8) | b[i]);
    }
    return String.fromCharCodes(units);
  }

  static String _decodePdfDoc(Uint8List b) {
    final sb = StringBuffer();
    for (final c in b) {
      final special = _pdfDocSpecial[c];
      sb.writeCharCode(special ?? c);
    }
    return sb.toString();
  }
}

String? _nameOf(Object? obj) => obj is _PdfName ? obj.value : null;

int? _intOf(Object? obj) {
  if (obj is int) return obj;
  if (obj is double) return obj.toInt();
  return null;
}

/// PDFDocEncoding 里与 Latin-1 不同的码位（PDF 规范 Annex D.2）。
///
/// 只列真正有差异的部分：0x18..0x1F 的变音符号、0x80..0x9F 的排版符号、
/// 以及 0xA0 的欧元。其余字节按 Latin-1 直通——对中文没帮助，但至少不会乱码成
/// 问号，真正的 CJK 文字在 PDF 里通常是 UTF-16 或 UTF-8（上面已分别处理）。
const Map<int, int> _pdfDocSpecial = {
  0x18: 0x02D8,
  0x19: 0x02C7,
  0x1A: 0x02C6,
  0x1B: 0x02D9,
  0x1C: 0x02DD,
  0x1D: 0x02DB,
  0x1E: 0x02DA,
  0x1F: 0x02DC,
  0x80: 0x2022,
  0x81: 0x2020,
  0x82: 0x2021,
  0x83: 0x2026,
  0x84: 0x2014,
  0x85: 0x2013,
  0x86: 0x0192,
  0x87: 0x2044,
  0x88: 0x2039,
  0x89: 0x203A,
  0x8A: 0x2212,
  0x8B: 0x2030,
  0x8C: 0x201E,
  0x8D: 0x201C,
  0x8E: 0x201D,
  0x8F: 0x2018,
  0x90: 0x2019,
  0x91: 0x201A,
  0x92: 0x2122,
  0x93: 0xFB01,
  0x94: 0xFB02,
  0x95: 0x0141,
  0x96: 0x0152,
  0x97: 0x0160,
  0x98: 0x0178,
  0x99: 0x017D,
  0x9A: 0x0131,
  0x9B: 0x0142,
  0x9C: 0x0153,
  0x9D: 0x0161,
  0x9E: 0x017E,
  0xA0: 0x20AC,
};
