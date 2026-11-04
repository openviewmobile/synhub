// 生成**自造的最小电子书素材**（每种格式一个），供离线冒烟与真机验证使用。
// **不下载任何真实电子书**。
//
//   dart run tool/make_book_fixtures.dart [输出目录]
//
// 生成完会**立刻用解析层自检**（`parseBook`），所以这个脚本同时也是
// "解析器能读自己造的文件"的冒烟测试。纯 Dart，不依赖 flutter。
//
// 覆盖：TXT（UTF-8/GBK/UTF-16/Big5）、Markdown、HTML、RTF、TCR、DOCX、ODT、
// OPF（正常 + 缺文件）、PalmDOC（.pdb/.prc）、FBZ、CBT、CB7（7z，期望"不支持"）、
// 以及两个坏文件（假 DOCX、HUFF/CDIC 的 MOBI）。
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:synhub/src/features/files/book_charset_table.dart';
import 'package:synhub/src/features/files/file_book.dart';

// ---------------------------------------------------------------- PNG

List<int> _u32b(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

List<int> _asciiBytes(String s) => [for (final c in s.codeUnits) c];

/// 一张**肉眼可见**的棋盘 PNG（1×1 透明图在截图里看不出来）
Uint8List makePng(int w, int h, int rgb) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    for (var x = 0; x < w; x++) {
      final on = ((x ~/ 10) + (y ~/ 10)) % 2 == 0;
      raw.add(
        on
            ? [(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF]
            : [0x18, 0x18, 0x22],
      );
    }
  }
  final out = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  void chunk(String type, List<int> data) {
    out.add(_u32b(data.length));
    out.add(_asciiBytes(type));
    out.add(data);
    out.add(_u32b(getCrc32([..._asciiBytes(type), ...data])));
  }

  chunk('IHDR', [..._u32b(w), ..._u32b(h), 8, 2, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder().encode(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

// ---------------------------------------------------------------- zip / tar

Uint8List zipOf(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List tarOf(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return TarEncoder().encodeBytes(archive);
}

// ---------------------------------------------------------------- 各格式正文

const _zh =
    '第一章 认识的起点\n\n'
    '这是一本**自造**的最小纯文本样本，用来验证内嵌阅读器。\n'
    '第二行说明段落合并。\n\n'
    '第二章 中文与标记\n\n'
    '这一章用来验证章节标记。\n\n'
    '第三章的内容不是标题，只是一句话。\n\n'
    '第三章 收尾\n\n'
    '最后一段。';

// ---------------------------------------------------------------- PalmDOC

Uint8List palmDoc({
  required String text,
  required String name,
  int compression = 1,
  int recordSize = 4096,
  int encryption = 0,
}) {
  final bytes = utf8.encode(text);
  final records = <Uint8List>[];
  for (var i = 0; i < bytes.length; i += recordSize) {
    final end = (i + recordSize).clamp(0, bytes.length);
    records.add(Uint8List.fromList(bytes.sublist(i, end)));
  }
  if (records.isEmpty) records.add(Uint8List(0));
  if (compression == 2) {
    records
      ..clear()
      ..addAll([
        for (final r in _chunk(bytes, recordSize))
          Uint8List.fromList(palmDocEncode(r)),
      ]);
  }

  final rec0 = Uint8List(16);
  void u16(int o, int v) {
    rec0[o] = (v >> 8) & 0xFF;
    rec0[o + 1] = v & 0xFF;
  }

  void u32(int o, int v) {
    rec0[o] = (v >> 24) & 0xFF;
    rec0[o + 1] = (v >> 16) & 0xFF;
    rec0[o + 2] = (v >> 8) & 0xFF;
    rec0[o + 3] = v & 0xFF;
  }

  u16(0, compression);
  u32(4, bytes.length);
  u16(8, records.length);
  u16(10, recordSize);
  u16(12, encryption);
  return _palmDb([rec0, ...records], name);
}

List<Uint8List> _chunk(List<int> bytes, int size) {
  final out = <Uint8List>[];
  for (var i = 0; i < bytes.length; i += size) {
    out.add(
      Uint8List.fromList(bytes.sublist(i, (i + size).clamp(0, bytes.length))),
    );
  }
  return out.isEmpty ? [Uint8List(0)] : out;
}

/// 最简单的 PalmDOC 编码器：字面量 + 三元组以外的部分原样（0x09-0x7F 单字节）
List<int> palmDocEncode(List<int> bytes) {
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    // 0x01..0x08：原样拷贝这么多个字节
    if (i + 2 <= bytes.length) {
      final n = (bytes.length - i).clamp(1, 8);
      out.add(n);
      for (var k = 0; k < n; k++) {
        out.add(bytes[i + k]);
      }
      i += n;
      continue;
    }
    final b = bytes[i];
    if (b == 0x00) {
      out.add(0);
    } else if (b <= 0x08) {
      out.add(0x01);
      out.add(b);
    } else if (b <= 0x7F) {
      out.add(b);
    } else if (b >= 0xC0) {
      out.add(0xC0 | (b & 0x7F));
    } else {
      // 0x80..0xBF 单独出现：退化成"拷贝 1 字节"
      out.add(0x01);
      out.add(b);
    }
    i++;
  }
  return out;
}

Uint8List _palmDb(List<Uint8List> records, String name) {
  final header = Uint8List(78);
  final nm = utf8.encode(name);
  for (var i = 0; i < nm.length && i < 31; i++) {
    header[i] = nm[i];
  }
  for (var i = 0; i < 4; i++) {
    header[60 + i] = 'BOOK'.codeUnitAt(i);
  }
  for (var i = 0; i < 4; i++) {
    header[64 + i] = 'TEXt'.codeUnitAt(i);
  }
  header[76] = (records.length >> 8) & 0xFF;
  header[77] = records.length & 0xFF;

  final table = Uint8List(records.length * 8);
  var offset = 78 + records.length * 8;
  for (var i = 0; i < records.length; i++) {
    for (var k = 0; k < 4; k++) {
      table[i * 8 + k] = (offset >> (24 - 8 * k)) & 0xFF;
    }
    offset += records[i].length;
  }
  final out = BytesBuilder(copy: false)
    ..add(header)
    ..add(table);
  for (final r in records) {
    out.add(r);
  }
  return out.takeBytes();
}

/// HUFF/CDIC 的 MOBI（record 0 里 compression=17480）—— 期望"明确不支持"
Uint8List huffMobi() {
  final rec0 = Uint8List(16 + 232);
  void u16(int o, int v) {
    rec0[o] = (v >> 8) & 0xFF;
    rec0[o + 1] = v & 0xFF;
  }

  void u32(int o, int v) {
    rec0[o] = (v >> 24) & 0xFF;
    rec0[o + 1] = (v >> 16) & 0xFF;
    rec0[o + 2] = (v >> 8) & 0xFF;
    rec0[o + 3] = v & 0xFF;
  }

  u16(0, 17480); // compression = HUFF/CDIC
  u32(4, 100);
  u16(8, 1);
  u16(12, 0);
  for (var i = 0; i < 4; i++) {
    rec0[16 + i] = 'MOBI'.codeUnitAt(i);
  }
  u32(20, 232);
  u32(36, 6);
  u32(28, 65001);
  return _palmDb([rec0, Uint8List.fromList(List.filled(64, 0x5A))], 'HUFF 样本');
}

// ---------------------------------------------------------------- 文档夹具

Map<String, List<int>> docxFiles(Uint8List png) => {
  '[Content_Types].xml': utf8.encode(
    '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/'
    'package/2006/content-types"><Default Extension="xml" ContentType='
    '"application/xml"/></Types>',
  ),
  'word/document.xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/'
    '2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/'
    'relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/'
    'main"><w:body>'
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
    '<w:r><w:t>第一章 DOCX 验证</w:t></w:r></w:p>'
    '<w:p><w:r><w:t xml:space="preserve">这是一段</w:t></w:r>'
    '<w:r><w:rPr><w:b/></w:rPr><w:t>加粗</w:t></w:r>'
    '<w:r><w:t>与</w:t></w:r>'
    '<w:r><w:rPr><w:i/></w:rPr><w:t>斜体</w:t></w:r>'
    '<w:r><w:t>的正文。</w:t></w:r></w:p>'
    '<w:p><w:r><w:drawing><a:blip r:embed="rId9"/></w:drawing></w:r></w:p>'
    '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr>'
    '<w:r><w:t>第二节 表格</w:t></w:r></w:p>'
    '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>甲</w:t></w:r></w:p></w:tc>'
    '<w:tc><w:p><w:r><w:t>乙</w:t></w:r></w:p></w:tc></w:tr>'
    '<w:tr><w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc>'
    '<w:tc><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
    '</w:body></w:document>',
  ),
  'word/_rels/document.xml.rels': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/'
    'relationships"><Relationship Id="rId9" Type="http://schemas.openxml'
    'formats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>'
    '</Relationships>',
  ),
  'word/media/image1.png': png,
  'docProps/core.xml': utf8.encode(
    '<?xml version="1.0"?><cp:coreProperties xmlns:cp="http://schemas.openxml'
    'formats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl'
    '.org/dc/elements/1.1/"><dc:title>DOCX 验证之书</dc:title>'
    '</cp:coreProperties>',
  ),
};

Map<String, List<int>> odtFiles(Uint8List png) => {
  'mimetype': utf8.encode('application/vnd.oasis.opendocument.text'),
  'META-INF/manifest.xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:'
    'manifest:1.0" manifest:version="1.2">'
    '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type='
    '"text/xml"/></manifest:manifest>',
  ),
  'styles.xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:'
    'xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:'
    'style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">'
    '<office:styles>'
    '<style:style style:name="Heading_20_1" style:family="paragraph">'
    '<style:paragraph-properties/><text:outline-level>1</text:outline-level>'
    '</style:style>'
    '<style:style style:name="Bold_20_Text" style:family="text">'
    '<style:text-properties fo:font-weight="bold"/></style:style>'
    '</office:styles></office:document-styles>',
  ),
  'content.xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:'
    'xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
    'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
    'xmlns:xlink="http://www.w3.org/1999/xlink" '
    'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
    'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0">'
    '<office:body><office:text>'
    '<text:h text:outline-level="1">第一章 ODT 验证</text:h>'
    '<text:p>这是一段<text:span text:style-name="Bold_20_Text">加粗</text:span>'
    '的正文。</text:p>'
    '<text:p><draw:frame><draw:image xlink:href="Pictures/pic.png"/></draw:frame>'
    '</text:p>'
    '<text:p>外链：<text:a xlink:href="https://example.com/">示例</text:a></text:p>'
    '<text:h text:outline-level="2">第二节 表格</text:h>'
    '<table:table><table:table-row><table:table-cell><text:p>甲</text:p>'
    '</table:table-cell><table:table-cell><text:p>乙</text:p>'
    '</table:table-cell></table:table-row></table:table>'
    '</office:text></office:body></office:document-content>',
  ),
  'Pictures/pic.png': png,
};

const fb2Xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"
 xmlns:l="http://www.w3.org/1999/xlink">
 <description><title-info><book-title>FBZ 验证之书</book-title>
 <author><first-name>自</first-name><last-name>造</last-name></author>
 </title-info></description>
 <body><section><title><p>第一章 FBZ</p></title>
 <p>这是包在 zip 里的 FB2。</p></section>
 <section><title><p>第二章 收尾</p></title><p>结束。</p></section></body>
</FictionBook>''';

const rtfText =
    r'''{\rtf1\ansi\ansicpg936\uc1 {\fonttbl{\f0\fnil SimSun;}}'''
    r'''{\colortbl;\red0\green0\blue0;}'''
    r'''\pard\b 第一章 RTF 验证\b0\par '''
    r'''\pard 这是一段正文，包含 \'d6\'d0\'ce\'c4 的中文转义，'''
    r'''以及 unicode 转义 \u20013?\u25991? 两个字。\par '''
    r'''\pard 第二段带 \b 加粗\b0 和 \i 斜体\i0。\par '''
    r'''\pard\b 第二章 收尾\b0\par \pard 最后一段。\par}''';

const mdText = '''
# Markdown 验证

这是一本**自造**的 Markdown 样本。

## 列表与引用

- 第一项
- 第二项

> 引用一行。

```dart
print('code block');
```

| 甲 | 乙 |
| --- | --- |
| 1 | 2 |

![棋盘](data:image/png;base64,PLACEHOLDER_PNG)

## 收尾

外链：[示例](https://example.com/)
''';

const htmlText = '''
<!DOCTYPE html>
<html><head><title>HTML 验证之书</title>
<style>p{color:red}</style></head>
<body>
<h1>第一章 HTML 验证</h1>
<div><p>这是<b>加粗</b>的正文，包含外链
<a href="https://example.com/">示例</a>。</p></div>
<p><img src="data:image/png;base64,PLACEHOLDER_PNG" alt="棋盘"/></p>
<h2>第二章 收尾</h2>
<p>结束。</p>
</body></html>
''';

// ---------------------------------------------------------------- main

class _Case {
  _Case(this.name, this.bytes, {this.expectError = false, this.note = ''});
  final String name;
  final Uint8List bytes;
  final bool expectError;
  final String note;
}

Future<void> main(List<String> args) async {
  final dir = Directory(args.isEmpty ? '/tmp/book-verify' : args.first);
  await dir.create(recursive: true);
  final png = makePng(240, 120, 0x4F8CFF);
  final pngB64 = base64.encode(png);

  // TCR：把纯文本编成"字面量 + 重复"的紧凑流
  Uint8List tcrOf(String text) {
    final bytes = utf8.encode(text);
    final out = <int>[];
    out.addAll(_asciiBytes('!!')); // 老式文件头标记
    var i = 0;
    while (i < bytes.length) {
      var run = 1;
      while (i + run < bytes.length &&
          bytes[i + run] == bytes[i] &&
          run < 127) {
        run++;
      }
      if (run >= 4) {
        out.add(0x80 | run);
        out.add(bytes[i]);
        i += run;
      } else {
        for (var k = 0; k < run; k++) {
          final b = bytes[i + k];
          if (b & 0x80 != 0) {
            out.add(0x81);
            out.add(b);
          } else {
            out.add(b);
          }
        }
        i += run;
      }
    }
    return Uint8List.fromList(out);
  }

  final opfXml = utf8.encode('''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
 <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>散装 EPUB（OPF）验证</dc:title><dc:creator>自造</dc:creator>
 </metadata>
 <manifest>
  <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
  <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
 </manifest>
 <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>''');

  final cases = <_Case>[
    _Case('sample.txt', Uint8List.fromList(utf8.encode(_zh))),
    _Case(
      'sample-gbk.txt',
      Uint8List.fromList(
        gbkEncode('第一章 GBK 验证\n\n这是用 GBK 编码存下来的正文。\n\n第二章 收尾\n\n结束。'),
      ),
      note: 'GBK',
    ),
    _Case(
      'sample-utf16.txt',
      Uint8List.fromList([
        0xFF,
        0xFE,
        ..._utf16le('第一章 UTF-16 验证\n\n这是 UTF-16LE 编码的正文。'),
      ]),
      note: 'UTF-16LE',
    ),
    _Case(
      'sample.md',
      Uint8List.fromList(
        utf8.encode(mdText.replaceAll('PLACEHOLDER_PNG', pngB64)),
      ),
    ),
    _Case(
      'sample.html',
      Uint8List.fromList(
        utf8.encode(htmlText.replaceAll('PLACEHOLDER_PNG', pngB64)),
      ),
    ),
    _Case('sample.rtf', Uint8List.fromList(utf8.encode(rtfText))),
    _Case('sample.tcr', tcrOf(_zh)),
    _Case('sample.docx', zipOf(docxFiles(png))),
    _Case('sample.odt', zipOf(odtFiles(png))),
    _Case('sample.pdb', palmDoc(text: _zh, name: 'PalmDOC 验证')),
    _Case(
      'sample.prc',
      palmDoc(text: _zh, name: 'PRC 验证', compression: 2),
      note: 'PalmDOC LZ77',
    ),
    _Case('sample.fbz', zipOf({'book.fb2': utf8.encode(fb2Xml)})),
    _Case(
      'sample.cbt',
      tarOf({
        'comic/p2.png': png,
        'comic/p10.png': makePng(240, 120, 0xFFAA33),
      }),
    ),
    _Case(
      'sample.cb7',
      Uint8List.fromList([
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, //
        ...List.filled(64, 0x11),
      ]),
      expectError: true,
      note: '期望"不支持 7z"',
    ),
    _Case(
      'bad-docx.docx',
      Uint8List.fromList(utf8.encode('这不是一个 zip')),
      expectError: true,
      note: '坏文件',
    ),
    _Case(
      'bad-huff.mobi',
      huffMobi(),
      expectError: true,
      note: 'HUFF/CDIC 期望"不支持"',
    ),
    _Case(
      'sample.opf',
      Uint8List.fromList(opfXml),
      expectError: true,
      note: '缺兄弟 XHTML → 明确报错',
    ),
  ];

  var failures = 0;
  for (final c in cases) {
    final path = '${dir.path}/${c.name}';
    await File(path).writeAsBytes(c.bytes);
    final r = parseBook(bookFormatOf(c.name.split('.').last), c.bytes);
    final ok = c.expectError ? !r.ok : r.ok;
    final detail = c.expectError
        ? '期望失败 → ${r.errorKind?.name}: ${r.error}'
        : '章 ${r.content.chapters.length} / 目录 ${r.content.toc.length} / '
              '图 ${r.content.resources.length} / 页 ${r.content.pages.length} / '
              '书名「${r.content.title}」';
    print('${ok ? "OK " : "!! "}$path  ${c.bytes.length} B  $detail');
    if (!ok) failures++;
  }

  print('\n共 ${cases.length} 个素材，失败 $failures 个');
  exit(failures == 0 ? 0 : 1);
}

// ---------------------------------------------------------------- 编码工具

List<int> _utf16le(String s) {
  final out = <int>[];
  for (final u in s.codeUnits) {
    out.add(u & 0xFF);
    out.add((u >> 8) & 0xFF);
  }
  return out;
}

/// GBK 编码：反查解析层自带的 GBK 解码表（`kGbkTwoByteTable`），
/// 所以 fixture 能覆盖**任意**表里收录的汉字，不需要另抄一张编码表。
List<int> gbkEncode(String s) {
  final reverse = <int, int>{};
  for (var i = 0; i < kGbkTwoByteTable.length; i++) {
    final cp = kGbkTwoByteTable.codeUnitAt(i);
    if (cp == 0xFFFD) continue;
    final lead = 0x81 + i ~/ 190;
    final ti = i % 190;
    final trail = ti <= 62 ? 0x40 + ti : 0x80 + (ti - 63);
    reverse.putIfAbsent(cp, () => (lead << 8) | trail);
  }
  final out = <int>[];
  for (final rune in s.runes) {
    if (rune < 0x80) {
      out.add(rune);
      continue;
    }
    final pair = reverse[rune];
    if (pair == null) {
      out.add(0x3F); // 表里没有 → '?'
      continue;
    }
    out
      ..add(pair >> 8)
      ..add(pair & 0xFF);
  }
  return out;
}
