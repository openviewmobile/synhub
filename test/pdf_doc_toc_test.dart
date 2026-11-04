// PDF 目录解析器离线测试。
//
// 测试里**在 Dart 里拼真实 PDF 字节**（手写对象、经典 xref 表、XRef 流、对象流、
// 压缩流、PNG 预测器），不提交二进制 fixture —— 这样每个字节的意图都在源码里
// 可读，也能精确构造"页对象号乱序""/Next 自指""截断"这些真实文件里偶发、
// 却很难找到样本的情况。
import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/pdf_doc.dart';

/// 累加字节 + 记每个对象的偏移，方便手造经典 xref / XRef 流。
class _Builder {
  final BytesBuilder _out = BytesBuilder();
  final Map<int, int> offsets = {};

  int get length => _out.length;

  void raw(String s) => _out.add(ascii.encode(s));

  void rawBytes(List<int> bytes) => _out.add(bytes);

  void object(int num, String body) {
    offsets[num] = _out.length;
    raw('$num 0 obj\n$body\nendobj\n');
  }

  void objectBytes(int num, List<int> body) {
    offsets[num] = _out.length;
    raw('$num 0 obj\n');
    rawBytes(body);
    raw('\nendobj\n');
  }

  Uint8List take() => _out.takeBytes();
}

Uint8List _flate(List<int> data) =>
    Uint8List.fromList(ZLibEncoder().convert(data));

/// raw deflate（**没有 zlib 头**）：有些生成器就这么写，解析器必须能退到它。
Uint8List _rawDeflate(List<int> data) =>
    Uint8List.fromList(ZLibEncoder(raw: true).convert(data));

String _asciiHexEncode(List<int> data) =>
    '${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}>';

String _ascii85Encode(List<int> data) {
  final out = StringBuffer();
  for (var i = 0; i < data.length; i += 4) {
    final chunk = data.sublist(i, i + 4 > data.length ? data.length : i + 4);
    final n = chunk.length;
    var tuple = 0;
    for (var j = 0; j < 4; j++) {
      tuple = (tuple << 8) | (j < n ? chunk[j] : 0);
    }
    if (n == 4 && tuple == 0) {
      out.write('z');
      continue;
    }
    final chars = List<int>.filled(5, 0);
    var t = tuple;
    for (var j = 4; j >= 0; j--) {
      chars[j] = t % 85;
      t ~/= 85;
    }
    for (var j = 0; j < n + 1; j++) {
      out.writeCharCode(chars[j] + 0x21);
    }
  }
  out.write('~>');
  return out.toString();
}

/// PNG Up 预测器编码（filter type 2）：`/Predictor 12 /Columns rowLength`。
Uint8List _pngUpEncode(Uint8List rows, int rowLength) {
  final out = BytesBuilder();
  var previous = Uint8List(rowLength);
  for (var r = 0; r + rowLength <= rows.length; r += rowLength) {
    final row = rows.sublist(r, r + rowLength);
    out.addByte(2);
    final encoded = Uint8List(rowLength);
    for (var i = 0; i < rowLength; i++) {
      encoded[i] = (row[i] - previous[i]) & 0xFF;
    }
    out.add(encoded);
    previous = row;
  }
  return out.takeBytes();
}

/// 造一个对象流的内容：前 `First` 字节是 "objnum offset" 对，后面是对象字节。
(Uint8List, int) _objStmBody(List<(int, String)> objects) {
  final header = StringBuffer();
  final bodies = <Uint8List>[];
  var offset = 0;
  for (final (num, src) in objects) {
    header.write('$num $offset ');
    final body = ascii.encode(src);
    bodies.add(body);
    offset += body.length;
  }
  final headerBytes = ascii.encode(header.toString());
  final out = BytesBuilder()..add(headerBytes);
  for (final body in bodies) {
    out.add(body);
  }
  return (out.takeBytes(), headerBytes.length);
}

List<int> _streamBody(String dict, List<int> data) => [
  ...ascii.encode('$dict\nstream\n'),
  ...data,
  ...ascii.encode('\nendstream'),
];

String _utf16beHex(String text) {
  final bytes = <int>[0xFE, 0xFF];
  for (final unit in text.codeUnits) {
    bytes.addAll([(unit >> 8) & 0xFF, unit & 0xFF]);
  }
  return bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

/// 经典 xref 表 PDF：[objects] 是对象号 → 对象体（不含 `N 0 obj`/`endobj`）。
/// 值是 [String] 时按文本写，是 `List<int>` 时按原始字节写（流对象用）。
Uint8List _classicPdf(
  Map<int, Object> objects, {
  int root = 1,
  String extraTrailer = '',
}) {
  final b = _Builder();
  b.raw('%PDF-1.7\n');
  // 二进制注释行：承诺文件里有非 ASCII 字节（真实 PDF 基本都有）。
  b.rawBytes(const [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
  final nums = objects.keys.toList()..sort();
  for (final n in nums) {
    final body = objects[n]!;
    if (body is String) {
      b.object(n, body);
    } else {
      b.objectBytes(n, body as List<int>);
    }
  }
  final xrefPos = b.length;
  final maxNum = nums.last;
  b.raw('xref\n0 ${maxNum + 1}\n');
  b.raw('0000000000 65535 f \n');
  for (var i = 1; i <= maxNum; i++) {
    final offset = b.offsets[i];
    if (offset == null) {
      b.raw('0000000000 65535 f \n');
    } else {
      b.raw('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
  }
  b.raw('trailer\n<< /Size ${maxNum + 1} /Root $root 0 R $extraTrailer >>\n');
  b.raw('startxref\n$xrefPos\n%%EOF\n');
  return b.take();
}

const _catalogWithOutline = '<< /Type /Catalog /Pages 2 0 R /Outlines 5 0 R >>';
const _pages1 = '<< /Type /Pages /Kids [3 0 R] /Count 1 >>';
const _page1 = '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>';

/// XRef 流 PDF：普通对象走 type 1，[objStmObjectNums] 里的对象走 type 2。
///
/// [objStmBody] 是 ObjStm 对象（号 [objStmNum]）的完整对象体字节
/// （dict + `stream` + 编码后的数据），调用方自己决定用什么过滤器。
Uint8List _xrefStreamPdf({
  required Map<int, String> objects,
  required List<int> objStmBody,
  required List<int> objStmObjectNums,
  int rootNum = 1,
  int objStmNum = 4,
}) {
  final b = _Builder();
  b.raw('%PDF-1.5\n');
  final nums = objects.keys.toList()..sort();
  for (final n in nums) {
    b.object(n, objects[n]!);
  }
  b.objectBytes(objStmNum, objStmBody);

  var maxNum = objStmNum;
  for (final n in <int>[...nums, ...objStmObjectNums]) {
    if (n > maxNum) maxNum = n;
  }
  final xrefNum = maxNum + 1;
  final size = xrefNum + 1;
  final xrefOffset = b.length;

  const rowLength = 7; // /W [1 4 2]
  final rows = BytesBuilder();
  void addRow(int type, int f2, int f3) {
    rows.addByte(type);
    for (var shift = 24; shift >= 0; shift -= 8) {
      rows.addByte((f2 >> shift) & 0xFF);
    }
    rows.addByte((f3 >> 8) & 0xFF);
    rows.addByte(f3 & 0xFF);
  }

  addRow(0, 0, 65535);
  for (var n = 1; n < size; n++) {
    if (n == xrefNum) {
      addRow(1, xrefOffset, 0);
      continue;
    }
    final slot = objStmObjectNums.indexOf(n);
    if (slot >= 0) {
      addRow(2, objStmNum, slot);
      continue;
    }
    final offset = b.offsets[n];
    if (offset == null) {
      addRow(0, 0, 65535);
    } else {
      addRow(1, offset, 0);
    }
  }
  final xrefFlate = _flate(_pngUpEncode(rows.takeBytes(), rowLength));
  b.objectBytes(
    xrefNum,
    _streamBody(
      '<< /Type /XRef /Size $size /W [1 4 2] /Index [0 $size] /Root $rootNum 0 R '
      '/Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns $rowLength >> '
      '/Length ${xrefFlate.length} >>',
      xrefFlate,
    ),
  );
  b.raw('startxref\n$xrefOffset\n%%EOF\n');
  return b.take();
}

void _expectEntries(
  List<PdfTocEntry> actual,
  List<(String, int, int?)> expected,
) {
  expect(actual.length, expected.length, reason: '条目数不对：$actual');
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].title, expected[i].$1, reason: '第 $i 条标题');
    expect(actual[i].depth, expected[i].$2, reason: '第 $i 条 depth');
    expect(actual[i].pageIndex, expected[i].$3, reason: '第 $i 条页码');
  }
}

void main() {
  setUp(() => lastPdfTocError = null);

  test('经典 xref + 3 层嵌套 + 页对象号乱序 + 字符串转义/PDFDocEncoding', () {
    // 页对象号是 20/10/30，但页序是 20 → 10 → 30：不能拿对象号当页序。
    final bytes = _classicPdf({
      1: _catalogWithOutline,
      2: '<< /Type /Pages /Kids [20 0 R 10 0 R 30 0 R] /Count 3 >>',
      20: _page1,
      10: _page1,
      30: _page1,
      5: '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 4 >>',
      // 标题里同时考：转义括号、反斜杠、八进制 UTF-8 中文
      6:
          '<< /Title (Chapter \\(1\\) \\\\ \\346\\226\\207) '
          '/Parent 5 0 R /Dest [20 0 R /Fit] /First 7 0 R >>',
      // Latin-1 的 é（0xE9 = \\351）
      7:
          '<< /Title (Caf\\351) /Parent 6 0 R /Dest [30 0 R /XYZ 0 200 0] '
          '/First 9 0 R /Next 8 0 R >>',
      9: '<< /Title (Deep) /Parent 7 0 R /Dest [20 0 R /Fit] >>',
      8: '<< /Title (Second) /Parent 6 0 R /Dest [10 0 R /Fit] >>',
    });

    final entries = parsePdfToc(bytes);

    // 顺序 = 父 → 子（/First）→ 再走兄弟（/Next）；depth 用 /First 递归算。
    _expectEntries(entries, [
      ('Chapter (1) \\ 文', 0, 0),
      ('Café', 1, 2),
      ('Deep', 2, 0),
      ('Second', 1, 1),
    ]);
  });

  test('XRef 流（PNG 预测器 12）+ 对象流：目录字典藏在 ObjStm 里', () {
    const outlinesSrc =
        '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>';
    const itemSrc =
        '<< /Title (Chapter One) /Parent 5 0 R /Dest [3 0 R /Fit] >>';
    final (objStmData, first) = _objStmBody([(5, outlinesSrc), (6, itemSrc)]);
    final encoded = _flate(objStmData);

    final bytes = _xrefStreamPdf(
      objects: {1: _catalogWithOutline, 2: _pages1, 3: _page1},
      objStmBody: _streamBody(
        '<< /Type /ObjStm /N 2 /First $first /Filter /FlateDecode '
        '/Length ${encoded.length} >>',
        encoded,
      ),
      objStmObjectNums: const [5, 6],
    );

    _expectEntries(parsePdfToc(bytes), [('Chapter One', 0, 0)]);
  });

  test('/A /GoTo + 命名目标（catalog /Dests 字典）', () {
    final bytes = _classicPdf({
      1:
          '<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R '
          '/Dests << /chapter1 [3 0 R /XYZ 0 200 0] >> >>',
      2: _pages1,
      3: _page1,
      4: '<< /Type /Outlines /First 5 0 R /Last 5 0 R /Count 1 >>',
      5:
          '<< /Title (Intro) /Parent 4 0 R '
          '/A << /S /GoTo /D (chapter1) >> >>',
    });

    _expectEntries(parsePdfToc(bytes), [('Intro', 0, 0)]);
  });

  test('命名目标名字树：/Names /Dests + /Kids 递归', () {
    final bytes = _classicPdf({
      1:
          '<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R '
          '/Names << /Dests 6 0 R >> >>',
      2: _pages1,
      3: _page1,
      4: '<< /Type /Outlines /First 5 0 R /Last 5 0 R /Count 1 >>',
      5: '<< /Title (Part Two) /Parent 4 0 R /Dest /chap2 >>',
      6: '<< /Kids [7 0 R] >>',
      7: '<< /Limits [(a) (z)] /Names [(chap2) [3 0 R /Fit]] >>',
    });

    _expectEntries(parsePdfToc(bytes), [('Part Two', 0, 0)]);
  });

  test('UTF-16BE 标题（中文）不乱码', () {
    final title = '第一章 起点';
    final bytes = _classicPdf({
      1: _catalogWithOutline,
      2: _pages1,
      3: _page1,
      5: '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>',
      6:
          '<< /Title <${_utf16beHex(title)}> /Parent 5 0 R '
          '/Dest [3 0 R /Fit] >>',
    });

    _expectEntries(parsePdfToc(bytes), [(title, 0, 0)]);
  });

  test('整数目标（1 基页码）', () {
    final bytes = _classicPdf({
      1: '<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R >>',
      2: '<< /Type /Pages /Kids [3 0 R 7 0 R] /Count 2 >>',
      3: _page1,
      7: _page1,
      4: '<< /Type /Outlines /First 5 0 R /Last 5 0 R /Count 1 >>',
      5: '<< /Title (ByNumber) /Parent 4 0 R /Dest [2 /Fit] >>',
    });

    _expectEntries(parsePdfToc(bytes), [('ByNumber', 0, 1)]);
  });

  test('间接 /Dest（引用指向目标数组）', () {
    final bytes = _classicPdf({
      1: _catalogWithOutline,
      2: _pages1,
      3: _page1,
      5: '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>',
      6: '<< /Title (IndirectDest) /Parent 5 0 R /Dest 9 0 R >>',
      9: '[3 0 R /Fit]',
    });

    _expectEntries(parsePdfToc(bytes), [('IndirectDest', 0, 0)]);
  });

  test('经典 xref + /Prev 链：增量更新后取新对象', () {
    const freshItems =
        '<< /Title (New Title) /Parent 4 0 R /Dest [3 0 R /Fit] >>';
    const oldItems =
        '<< /Title (Old Title) /Parent 4 0 R /Dest [3 0 R /Fit] >>';

    final b = _Builder();
    b.raw('%PDF-1.4\n');
    // 这里 outlines 是对象 4、条目是对象 5（普通对象号），
    // 所以 catalog 不能复用指向 5 的 `_catalogWithOutline`。
    b.object(1, '<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R >>');
    b.object(2, _pages1);
    b.object(3, _page1);
    b.object(4, '<< /Type /Outlines /First 5 0 R /Last 5 0 R /Count 1 >>');
    b.object(5, oldItems);

    final firstXref = b.length;
    b.raw('xref\n0 5\n0000000000 65535 f \n');
    for (var i = 1; i <= 4; i++) {
      b.raw('${b.offsets[i]!.toString().padLeft(10, '0')} 00000 n \n');
    }
    b.raw('trailer\n<< /Size 5 /Root 1 0 R >>\n');
    b.raw('startxref\n$firstXref\n%%EOF\n');

    // 增量更新：覆盖对象 5，只写一个 subsection，用 /Prev 指回旧表。
    b.object(5, freshItems);
    final secondXref = b.length;
    b.raw('xref\n5 1\n${b.offsets[5]!.toString().padLeft(10, '0')} 00000 n \n');
    b.raw('trailer\n<< /Size 5 /Root 1 0 R /Prev $firstXref >>\n');
    b.raw('startxref\n$secondXref\n%%EOF\n');

    _expectEntries(parsePdfToc(b.take()), [('New Title', 0, 0)]);
  });

  test('对象流：raw deflate（无 zlib 头）+ 间接 /Length', () {
    const outlinesSrc =
        '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>';
    const itemSrc =
        '<< /Title (RawDeflate) /Parent 5 0 R /Dest [3 0 R /Fit] >>';
    final (objStmData, first) = _objStmBody([(5, outlinesSrc), (6, itemSrc)]);
    final encoded = _rawDeflate(objStmData);

    final bytes = _xrefStreamPdf(
      objects: {
        1: _catalogWithOutline,
        2: _pages1,
        3: _page1,
        // /Length 走间接引用：对象 8 是个普通整数对象
        8: '${encoded.length}',
      },
      objStmBody: _streamBody(
        '<< /Type /ObjStm /N 2 /First $first /Filter /FlateDecode '
        '/Length 8 0 R >>',
        encoded,
      ),
      objStmObjectNums: const [5, 6],
    );

    _expectEntries(parsePdfToc(bytes), [('RawDeflate', 0, 0)]);
  });

  test('ASCIIHexDecode 对象流', () {
    const outlinesSrc =
        '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>';
    const itemSrc =
        '<< /Title (HexFiltered) /Parent 5 0 R /Dest [3 0 R /Fit] >>';
    final (objStmData, first) = _objStmBody([(5, outlinesSrc), (6, itemSrc)]);
    final encoded = ascii.encode(_asciiHexEncode(objStmData));

    final bytes = _xrefStreamPdf(
      objects: {1: _catalogWithOutline, 2: _pages1, 3: _page1},
      objStmBody: _streamBody(
        '<< /Type /ObjStm /N 2 /First $first /Filter /ASCIIHexDecode '
        '/Length ${encoded.length} >>',
        encoded,
      ),
      objStmObjectNums: const [5, 6],
    );

    _expectEntries(parsePdfToc(bytes), [('HexFiltered', 0, 0)]);
  });

  test('ASCII85Decode 对象流', () {
    const outlinesSrc =
        '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>';
    const itemSrc =
        '<< /Title (A85Filtered) /Parent 5 0 R /Dest [3 0 R /Fit] >>';
    final (objStmData, first) = _objStmBody([(5, outlinesSrc), (6, itemSrc)]);
    final encoded = ascii.encode(_ascii85Encode(objStmData));

    final bytes = _xrefStreamPdf(
      objects: {1: _catalogWithOutline, 2: _pages1, 3: _page1},
      objStmBody: _streamBody(
        '<< /Type /ObjStm /N 2 /First $first /Filter /ASCII85Decode '
        '/Length ${encoded.length} >>',
        encoded,
      ),
      objStmObjectNums: const [5, 6],
    );

    _expectEntries(parsePdfToc(bytes), [('A85Filtered', 0, 0)]);
  });

  test('没有目录 → 空表', () {
    final bytes = _classicPdf({
      1: '<< /Type /Catalog /Pages 2 0 R >>',
      2: _pages1,
      3: _page1,
    });
    expect(parsePdfToc(bytes), isEmpty);
  });

  test('/Encrypt → 空表（不解密）', () {
    final bytes = _classicPdf({
      1: _catalogWithOutline,
      2: _pages1,
      3: _page1,
      5: '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>',
      6: '<< /Title (Secret) /Parent 5 0 R /Dest [3 0 R /Fit] >>',
      9: '<< /Filter /Standard /V 2 /R 3 /O (x) /U (y) /P -1 >>',
    }, extraTrailer: '/Encrypt 9 0 R');
    expect(parsePdfToc(bytes), isEmpty);
    expect(lastPdfTocError, contains('加密'));
  });

  test('垃圾字节 → 空表，不抛', () {
    expect(
      parsePdfToc(Uint8List.fromList(utf8.encode('not a pdf at all'))),
      isEmpty,
    );
    expect(parsePdfToc(Uint8List.fromList(const [])), isEmpty);
    final noise = Uint8List.fromList(
      List<int>.generate(4096, (i) => (i * 37 + 11) % 256),
    );
    expect(parsePdfToc(noise), isEmpty);
  });

  test('截断文件 → 不抛（结果可为空/不完整）', () {
    final bytes = _classicPdf({
      1: _catalogWithOutline,
      2: _pages1,
      3: _page1,
      5: '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>',
      6: '<< /Title (Cut) /Parent 5 0 R /Dest [3 0 R /Fit] >>',
    });
    expect(
      () => parsePdfToc(Uint8List.sublistView(bytes, 0, bytes.length ~/ 2)),
      returnsNormally,
    );
    expect(
      () => parsePdfToc(Uint8List.sublistView(bytes, 0, bytes.length - 20)),
      returnsNormally,
    );
  });

  test('/Next 自指 → 不挂死', () {
    final bytes = _classicPdf({
      1: _catalogWithOutline,
      2: _pages1,
      3: _page1,
      5: '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>',
      6: '<< /Title (Loop) /Parent 5 0 R /Next 6 0 R /Dest [3 0 R /Fit] >>',
    });
    _expectEntries(parsePdfToc(bytes), [('Loop', 0, 0)]);
  });

  test('超深嵌套 → 有深度上限，不爆栈', () {
    final objects = <int, String>{
      1: _catalogWithOutline,
      2: _pages1,
      3: _page1,
      5: '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 100 >>',
    };
    for (var i = 0; i < 100; i++) {
      final num = 6 + i;
      final next = i < 99 ? ' /First ${num + 1} 0 R' : '';
      objects[num] =
          '<< /Title (L$i) /Parent ${num - 1} 0 R$next /Dest [3 0 R /Fit] >>';
    }
    final entries = parsePdfToc(_classicPdf(objects));
    expect(entries, isNotEmpty);
    expect(entries.length, lessThanOrEqualTo(64));
    expect(entries.last.depth, lessThanOrEqualTo(63));
  });

  test('裸扫兜底：xref 损坏但对象字节还在，仍能取到目录', () {
    // 把 startxref 指向一个不存在的偏移，并把 xref 表也删掉：只能靠裸扫
    // `N G obj` + 扫 /Catalog 兜底。
    final good = _classicPdf({
      1: _catalogWithOutline,
      2: _pages1,
      3: _page1,
      5: '<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>',
      6: '<< /Title (Recovered) /Parent 5 0 R /Dest [3 0 R /Fit] >>',
    });
    final text = latin1.decode(good);
    final broken = latin1.encode(
      text.replaceAll('startxref\n', 'startxref\n99999999 # '),
    );
    final entries = parsePdfToc(Uint8List.fromList(broken));
    _expectEntries(entries, [('Recovered', 0, 0)]);
  });
}
