// PDF 文字抽取（`extractPdfText`）—— AI 助手要"总结这份 PDF"就必须先有文字。
//
// 素材全部在 Dart 里手拼（仓库里不放二进制）：简单字体的 WinAnsi、`/Differences`
// 字形名、Identity-H 复合字体 + `/ToUnicode` CMap（中文 PDF 的关键路径）、
// Flate 压缩内容流、以及各种"抽不出来"的情况。
import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/files/pdf_doc.dart';

/// 一个极简 PDF 构造器：只写我们需要的对象，编经典的 xref
class _Pdf {
  _Pdf();

  final _out = BytesBuilder();
  final _offsets = <int, int>{};

  // 解析器要求文件里有 `%PDF-` 头（没有就直接判为不认识的字节流），
  // 所有 PDF 构造器都必须带上它。
  void header() => _out.add(utf8.encode('%PDF-1.7\n%\xe2\xe3\xcf\xd3\n'));
  var _next = 1;

  int reserve() => _next++;

  void object(int n, String body) {
    if (_offsets.isEmpty) header();
    _offsets[n] = _out.length;
    _out.add(utf8.encode('$n 0 obj\n$body\nendobj\n'));
  }

  void stream(int n, String body, {bool flate = false}) {
    if (_offsets.isEmpty) header();
    _offsets[n] = _out.length;
    final raw = utf8.encode(body);
    final payload = flate ? ZLibEncoder().convert(raw) : raw;
    _out.add(utf8.encode('$n 0 obj\n<< /Length ${payload.length}'));
    if (flate) _out.add(utf8.encode(' /Filter /FlateDecode'));
    _out.add(utf8.encode(' >>\nstream\n'));
    _out.add(payload);
    _out.add(utf8.encode('\nendstream\nendobj\n'));
  }

  Uint8List finish(int root, int size) {
    final xref = _out.length;
    _out.add(utf8.encode('xref\n0 $size\n0000000000 65535 f \n'));
    for (var n = 1; n < size; n++) {
      final off = _offsets[n] ?? 0;
      _out.add(utf8.encode('${off.toString().padLeft(10, '0')} 00000 n \n'));
    }
    _out.add(
      utf8.encode(
        'trailer\n<< /Size $size /Root $root 0 R >>\n'
        'startxref\n$xref\n%%EOF\n',
      ),
    );
    return _out.toBytes();
  }
}

/// 一页、简单字体（Helvetica/WinAnsi），正文 `BT /F1 12 Tf 40 700 Td (...)Tj ET`
Uint8List simplePdf(String text, {bool flate = false}) {
  final p = _Pdf();
  p.object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  p.object(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  p.object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
    '/Resources << /Font << /F1 5 0 R >> >> >>',
  );
  p.stream(4, 'BT /F1 12 Tf 40 700 Td ($text) Tj ET', flate: flate);
  p.object(
    5,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
    '/Encoding /WinAnsiEncoding >>',
  );
  return p.finish(1, 6);
}

/// 多行 / 多段：`Td` 换行 + `TJ` 数组（含空格调整）
Uint8List multiLinePdf() {
  final p = _Pdf();
  p.object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  p.object(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  p.object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
    '/Resources << /Font << /F1 5 0 R >> >> >>',
  );
  // `Td` 是**相对上一行的位移**（规范如此），所以这里用 `0 -20 Td` 表示往下挪一行；
  // 真实现代 PDF 也是这么写的（或者用 `Tm` 给绝对矩阵）
  p.stream(4, '''
BT
/F1 12 Tf
40 700 Td (Hello) Tj
0 -20 Td [(World) -300 (Again)] TJ
0 -20 Td (Third line) Tj
ET
''');
  p.object(
    5,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
    '/Encoding /WinAnsiEncoding >>',
  );
  return p.finish(1, 6);
}

/// 两页，用来验证"只抽某一页"
Uint8List twoPagePdf() {
  final p = _Pdf();
  p.object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  p.object(2, '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>');
  p.object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 5 0 R '
    '/Resources << /Font << /F1 7 0 R >> >> >>',
  );
  p.object(
    4,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R '
    '/Resources << /Font << /F1 7 0 R >> >> >>',
  );
  p.stream(5, 'BT /F1 12 Tf 20 100 Td (PAGE ONE) Tj ET');
  p.stream(6, 'BT /F1 12 Tf 20 100 Td (PAGE TWO) Tj ET');
  p.object(
    7,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
    '/Encoding /WinAnsiEncoding >>',
  );
  return p.finish(1, 8);
}

/// Identity-H 复合字体 + `/ToUnicode`（中文 PDF 的真实样子）
Uint8List cidPdf() {
  final p = _Pdf();
  p.object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  p.object(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  p.object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
    '/Resources << /Font << /F1 5 0 R >> >> >>',
  );
  // <0001> = 中, <0002> = 文, <0003> = 测试
  p.stream(
    4,
    'BT /F1 12 Tf 40 700 Td <0001000200030004> Tj 40 680 Td <0005> Tj ET',
  );
  p.object(
    5,
    '<< /Type /Font /Subtype /Type0 /BaseFont /NotoSansSC '
    '/Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>',
  );
  p.object(6, '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /NotoSansSC >>');
  p.stream(7, '''
/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
1 begincodespacerange
<0000> <FFFF>
endcodespacerange
3 beginbfchar
<0001> <4E2D>
<0002> <6587>
<0003> <6D4B>
endbfchar
1 beginbfrange
<0004> <0006> <8BD5>
endbfrange
endcmap
''');
  return p.finish(1, 8);
}

/// `/Differences` 字形名（没有 ToUnicode 的简单字体靠它）
Uint8List differencesPdf() {
  final p = _Pdf();
  p.object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  p.object(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  p.object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
    '/Resources << /Font << /F1 5 0 R >> >> >>',
  );
  // 0x41 → /Alpha(名里没有就靠 uniXXXX)，0x42 → /uni4E2D，0x43 → 原样 Latin-1
  p.stream(4, 'BT /F1 12 Tf 40 700 Td (ABC) Tj ET');
  p.object(
    5,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Sym /Encoding '
    '<< /Type /Encoding /BaseEncoding /WinAnsiEncoding '
    '/Differences [65 /uni4E2D 66 /uni6587 67 /A] >> >>',
  );
  return p.finish(1, 6);
}

/// 扫描件的样子：只有图片，没有文字
Uint8List imageOnlyPdf() {
  final p = _Pdf();
  p.object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  p.object(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  p.object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
    '/Resources << /XObject << /Im1 5 0 R >> >> >>',
  );
  p.stream(4, 'q 612 0 0 792 0 0 cm /Im1 Do Q');
  p.stream(5, 'not-really-a-jpeg');
  return p.finish(1, 6);
}

Uint8List encryptedPdf() {
  final p = _Pdf();
  p.object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  p.object(2, '<< /Type /Pages /Kids [] /Count 0 >>');
  final bytes = p.finish(1, 3);
  // 直接在 trailer 上加 /Encrypt（够模拟"加密文档"这个判断）
  final s = String.fromCharCodes(bytes);
  return Uint8List.fromList(
    utf8.encode(s.replaceFirst('/Root 1 0 R', '/Root 1 0 R /Encrypt 9 0 R')),
  );
}

void main() {
  test('简单字体：WinAnsi 一页一段', () {
    final text = extractPdfText(simplePdf('Hello DSM'));
    expect(text, 'Hello DSM');
    expect(lastPdfTextError, isNull);
  });

  test('Flate 压缩的内容流也能读', () {
    expect(
      extractPdfText(simplePdf('Compressed body', flate: true)),
      'Compressed body',
    );
  });

  test('多行 + TJ 数组：按行分开，字距大到一定程度补空格', () {
    final text = extractPdfText(multiLinePdf());
    expect(text.split('\n'), ['Hello', 'World Again', 'Third line']);
  });

  test('两页文档：整篇按页拼，指定页码只抽那一页', () {
    final all = extractPdfText(twoPagePdf());
    expect(all, contains('PAGE ONE'));
    expect(all, contains('PAGE TWO'));
    // 页与页之间空一行
    expect(all.split('\n\n').length, 2);

    expect(extractPdfText(twoPagePdf(), pageIndex: 1), 'PAGE TWO');
    expect(extractPdfText(twoPagePdf(), pageIndex: 0), 'PAGE ONE');
  });

  test('Identity-H + ToUnicode：中文（bfchar 与 bfrange 两条路）', () {
    final text = extractPdfText(cidPdf());
    // <0001..0003> 走 bfchar，<0004..0006> 走 bfrange
    expect(text, contains('中文测'));
    expect(text, contains('试'));
  });

  test('/Differences 字形名：uniXXXX 认得出来，普通名字按 Latin-1', () {
    final text = extractPdfText(differencesPdf());
    expect(text, '中文A');
  });

  test('只有图片的"扫描件"：抽出来是空的，并留下原因', () {
    final text = extractPdfText(imageOnlyPdf());
    expect(text, isEmpty);
    expect(lastPdfTextError, contains('没有文字'));
  });

  test('加密文档：不尝试解密，返回空 + 原因', () {
    expect(extractPdfText(encryptedPdf()), isEmpty);
    expect(lastPdfTextError, contains('加密'));
  });

  test('垃圾字节 / 空 / 太短：绝不抛', () {
    expect(extractPdfText(Uint8List(0)), isEmpty);
    expect(extractPdfText(Uint8List.fromList(utf8.encode('garbage'))), isEmpty);
    expect(
      extractPdfText(
        Uint8List.fromList(List<int>.generate(5000, (i) => (i * 37) % 251)),
      ),
      isEmpty,
    );
    expect(lastPdfTextError, isNotNull);
  });

  test('maxChars 上限：不会无限长', () {
    final long = 'X' * 500;
    final text = extractPdfText(simplePdf(long), maxChars: 100);
    expect(text.length, lessThanOrEqualTo(100));
  });

  test('extractPdfPages：一次解析拿到每一页（AI 的按页引用要用）', () {
    final pages = extractPdfPages(twoPagePdf());
    expect(pages, ['PAGE ONE', 'PAGE TWO']);
    // 只有图片的扫描件：每页都是空串，不是崩
    expect(extractPdfPages(imageOnlyPdf()), ['']);
  });

  test('页码越界：空结果 + 原因', () {
    expect(extractPdfText(twoPagePdf(), pageIndex: 9), isEmpty);
    expect(lastPdfTextError, contains('越界'));
  });
}
