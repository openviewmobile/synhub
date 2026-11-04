// TXT / Markdown / HTML / RTF / TCR 解析 + 接入点的离线测试。
//
// fixture 全部是**代码里现造**的（含 GBK/Big5/UTF-16/GB18030 的字节序列、
// data: 内联图、最小 RTF、TCR 紧凑流），不下载任何真实电子书。
// 覆盖：编码探测（正常 + 判不出来的保守回落）、分章/分块、段落与样式、
// 图片资源、外链保留，以及坏文件必须给"明确错误"而不是乱码。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/book_encoding.dart';
import 'package:synhub/src/features/files/book_text.dart';
import 'package:synhub/src/features/files/file_book.dart';

/// 1×1 透明 PNG（够 magic number 判定 + Flutter 解码）
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

String _pngDataUri() => 'data:image/png;base64,${base64.encode(_png)}';

void main() {
  // ---------------------------------------------------------------- 编码探测

  group('编码探测与解码（book_encoding.dart）', () {
    test('UTF-8 带 BOM：剥掉 BOM，按 UTF-8 解', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('中文正文')];
      final r = detectAndDecodeBookText(bytes);
      expect(r.text, '中文正文');
      expect(r.encoding, BookTextEncoding.utf8);
    });

    test('UTF-16 LE / BE 带 BOM', () {
      final le = [0xFF, 0xFE, 0x2D, 0x4E, 0x87, 0x65];
      final be = [0xFE, 0xFF, 0x4E, 0x2D, 0x65, 0x87];
      expect(detectAndDecodeBookText(le).text, '中文');
      expect(detectAndDecodeBookText(le).encoding, BookTextEncoding.utf16le);
      expect(detectAndDecodeBookText(be).text, '中文');
      expect(detectAndDecodeBookText(be).encoding, BookTextEncoding.utf16be);
    });

    test('无 BOM 的 UTF-16：靠"隔字节 0x00 分布"保守识别', () {
      // 'Hello world' 的 UTF-16LE
      final le = <int>[];
      for (final u in 'Hello world'.codeUnits) {
        le
          ..add(u & 0xFF)
          ..add((u >> 8) & 0xFF);
      }
      final r = detectAndDecodeBookText(le);
      expect(r.text, 'Hello world');
      expect(r.encoding, BookTextEncoding.utf16le);
    });

    test('无 BOM 的 UTF-16 LE 全汉字（没有 0x00）：不能当 GB18030 解成乱码', () {
      // 改动前的真实行为：这段被判成 GB18030，产出 `-N噀Km諎ck噀匭筟`。
      final le = <int>[];
      for (final u in '中文测试正文内容'.codeUnits) {
        le
          ..add(u & 0xFF)
          ..add((u >> 8) & 0xFF);
      }
      final r = detectAndDecodeBookText(le);
      expect(r.text, '中文测试正文内容');
      expect(r.encoding, BookTextEncoding.utf16le);
    });

    test('无 BOM 的 UTF-16 BE 全汉字同样能认出来', () {
      final be = <int>[];
      for (final u in '中文测试正文内容'.codeUnits) {
        be
          ..add((u >> 8) & 0xFF)
          ..add(u & 0xFF);
      }
      final r = detectAndDecodeBookText(be);
      expect(r.text, '中文测试正文内容');
      expect(r.encoding, BookTextEncoding.utf16be);
    });

    test('回归：16 字节的 GBK 正文不会被新的 UTF-16 判据抢走', () {
      const gbk = [
        0xD6, 0xD0, 0xCE, 0xC4, 0xD5, 0xFD, 0xCE, 0xC4, //
        0xB2, 0xE2, 0xCA, 0xD4, 0xC4, 0xDA, 0xC8, 0xDD,
      ];
      final r = detectAndDecodeBookText(gbk);
      expect(r.text, '中文正文测试内容');
      expect(r.encoding, BookTextEncoding.gb18030);
    });

    test('纯 ASCII：走 UTF-8', () {
      final r = detectAndDecodeBookText(utf8.encode('plain ascii'));
      expect(r.encoding, BookTextEncoding.utf8);
      expect(r.text, 'plain ascii');
    });

    test('GBK：中文正确解出，不经过 UTF-8 容错', () {
      final gbk = [0xD6, 0xD0, 0xCE, 0xC4, 0xA1, 0xA3];
      final r = detectAndDecodeBookText(gbk);
      expect(r.text, '中文。');
      expect(r.encoding, BookTextEncoding.gb18030);
      expect(r.text.contains('\uFFFD'), isFalse);
    });

    test('Big5：繁体中文正确解出', () {
      final big5 = [0xA4, 0xA4, 0xA4, 0xE5];
      expect(decodeBig5(big5, strict: true), '中文');
    });

    test('GB18030 四字节区（0x81 0x30 0x81 0x30 → U+0080）', () {
      final out = decodeGb18030([0x81, 0x30, 0x81, 0x30], strict: true);
      expect(out, String.fromCharCode(0x80));
    });

    test('非法 GB18030 序列：strict 报 null，宽松给 U+FFFD', () {
      final bad = [0x84, 0x39, 0xA4, 0x38];
      expect(decodeGb18030(bad, strict: true), isNull);
      expect(decodeGb18030(bad, strict: false), contains('\uFFFD'));
    });

    test('完全认不出来的字节：回落 UTF-8 容错，绝不抛异常', () {
      final junk = List<int>.filled(64, 0xFF);
      final r = detectAndDecodeBookText(junk);
      expect(r.encoding, BookTextEncoding.utf8Lossy);
      expect(r.text, isNotEmpty);
    });

    test('截断的 GBK（只有首字节）：不崩，产出替换符', () {
      expect(decodeGb18030([0xD6], strict: true), isNull);
      expect(decodeBookText([0xD6]), isNotEmpty);
    });
  });

  // ---------------------------------------------------------------- TXT

  group('TXT（parseTxtBook / parseBook）', () {
    test('章节标记行分章：标题、目录、正文都对', () {
      const text =
          '第一章 起点\n\n正文甲。\n\n第二章 发展\n\n正文乙。\n\n'
          '第三章 收尾\n\n正文丙。';
      final book = parseTxtBook(utf8.encode(text), format: BookFormat.txt);
      expect(book.chapters, hasLength(3));
      expect(book.toc, hasLength(3));
      expect(book.toc[0].title, '第一章 起点');
      expect(book.chapters[1].html, contains('正文乙'));
      expect(book.chapters[2].title, '第三章 收尾');
    });

    test('带标点的"伪标题"不算章节（第三章的内容不是标题。）', () {
      const text = '正文开头。\n\n第三章的内容不是标题，只是一句话。\n\n结尾。';
      final book = parseTxtBook(utf8.encode(text), format: BookFormat.txt);
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.title, '正文');
      expect(book.chapters.first.html, contains('第三章的内容不是标题'));
    });

    test('没有章节标记：单章「正文」，空行分段并保留换行', () {
      const text = '第一段第一行\n第一段第二行\n\n第二段';
      final book = parseTxtBook(utf8.encode(text), format: BookFormat.txt);
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.generatedUnit, BookGeneratedUnit.body);
      expect(book.chapters.first.html, contains('第一段第一行<br>第一段第二行'));
      expect(book.chapters.first.html, contains('第二段'));
    });

    test('HTML 特殊字符被转义（不会把正文当标签）', () {
      final book = parseTxtBook(
        utf8.encode('<script>alert(1)</script> & <b>'),
        format: BookFormat.txt,
      );
      expect(book.chapters.first.html, contains('&lt;script&gt;'));
      expect(book.chapters.first.html.contains('<script>'), isFalse);
    });

    test('超大文件按大小切块，正文不丢', () {
      // > kTextSplitThreshold 的无标记正文
      final buf = StringBuffer();
      for (var i = 0; i < 4000; i++) {
        buf.write('段落 $i ${'x' * 100}\n\n');
      }
      final text = buf.toString();
      final book = parseTxtBook(utf8.encode(text), format: BookFormat.txt);
      expect(book.chapters.length, greaterThan(1));
      expect(book.chapters.first.generatedUnit, BookGeneratedUnit.section);
      final joined = book.chapters.map((c) => c.html).join();
      expect(joined, contains('段落 0 '));
      expect(joined, contains('段落 3999 '));
    });

    test('GBK 的 TXT 走同一条路，标题不乱码', () {
      // "第一章 GBK" 的 GBK 字节
      final bytes = <int>[0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x20, 0x41];
      final book = parseTxtBook(bytes, format: BookFormat.txt);
      expect(book.title, '第一章 A');
      expect(book.author, contains('gb18030'));
    });

    test('空文件：不抛异常，产出空正文', () {
      final r = parseBook(BookFormat.txt, const []);
      expect(r.ok, isTrue);
      expect(r.content.chapters, hasLength(1));
      expect(r.content.chapters.first.html, isEmpty);
    });

    test('parseBook 兜底书名（调用方给的文件名）', () {
      final r = parseBook(
        BookFormat.txt,
        utf8.encode('没有章节标记的正文'),
        title: '三体',
      );
      expect(r.content.title, '三体');
    });
  });

  // ---------------------------------------------------------------- Markdown

  group('Markdown（parseMarkdownBook）', () {
    test('标题分章 + 列表/引用/代码块保留', () {
      const text = '''
# 第一章 起点

这是一段**加粗**的正文。

- 甲
- 乙

> 引用一行

```dart
print('code');
```

## 第二章 收尾

结束。
''';
      final book = parseMarkdownBook(utf8.encode(text), format: BookFormat.md);
      expect(book.title, '第一章 起点');
      expect(book.chapters, hasLength(2));
      expect(book.chapters.first.html, contains('<strong>加粗</strong>'));
      expect(book.chapters.first.html, contains('<li>'));
      expect(book.chapters.first.html, contains('<blockquote>'));
      expect(book.chapters.first.html, contains('code'));
    });

    test('表格尽力而为：单元格文字留在正文里', () {
      const text = '# 表\n\n| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |\n';
      final book = parseMarkdownBook(utf8.encode(text), format: BookFormat.md);
      expect(book.chapters.first.html, contains('甲'));
      expect(book.chapters.first.html, contains('2'));
    });

    test('data: 内联图 → 资源；外链保留 href', () {
      final text =
          '# 图\n\n![棋盘](${_pngDataUri()})\n\n'
          '[示例](https://example.com/)\n';
      final book = parseMarkdownBook(utf8.encode(text), format: BookFormat.md);
      expect(book.resources, hasLength(1));
      expect(book.resources.values.first, _png);
      expect(book.chapters.first.html, contains('https://example.com/'));
    });

    test('相对图片：没有兄弟文件时保留原 src、不进资源表', () {
      const text = '# 图\n\n![本地](images/a.png)\n';
      final book = parseMarkdownBook(utf8.encode(text), format: BookFormat.md);
      expect(book.resources, isEmpty);
      expect(book.chapters.first.html, contains('images/a.png'));
    });

    test('相对图片：给了兄弟文件就变成书内资源', () {
      const text = '# 图\n\n![本地](images/a.png)\n';
      final book = parseMarkdownBook(
        utf8.encode(text),
        format: BookFormat.md,
        siblings: {'images/a.png': _png},
      );
      expect(book.resources, hasLength(1));
      expect(book.resources['images/a.png'], _png);
      expect(book.chapters.first.html, contains('src="images/a.png"'));
    });

    test('坏 Markdown（未闭合代码块）：仍然出正文，不抛异常', () {
      final book = parseMarkdownBook(
        utf8.encode('# 标题\n\n```dart\n没闭合'),
        format: BookFormat.md,
      );
      expect(book.chapters, isNotEmpty);
      expect(book.title, '标题');
    });
  });

  // ---------------------------------------------------------------- HTML

  group('HTML（parseHtmlBook）', () {
    test('title 当书名；style/script 剥掉；h1/h2 分章', () {
      const html = '''
<html><head><title>HTML 之书</title><style>p{color:red}</style>
<script>alert(1)</script></head>
<body><h1>第一章</h1><div><p>正文甲</p></div>
<h2>第二章</h2><p>正文乙</p></body></html>''';
      final book = parseHtmlBook(utf8.encode(html), format: BookFormat.html);
      expect(book.title, 'HTML 之书');
      expect(book.chapters, hasLength(2));
      expect(book.chapters.first.html, contains('正文甲'));
      expect(book.chapters.first.html.contains('alert'), isFalse);
      expect(book.chapters.first.html.contains('color:red'), isFalse);
    });

    test('深容器（div 套 div）也能摊平分章', () {
      const html =
          '<body><div><div><h1>一</h1><p>a</p></div>'
          '<div><h1>二</h1><p>b</p></div></div></body>';
      final book = parseHtmlBook(utf8.encode(html), format: BookFormat.html);
      expect(book.chapters, hasLength(2));
      expect(book.toc[1].title, '二');
    });

    test('data: 内联图进资源；相对图有兄弟文件时进资源', () {
      final html =
          '<body><h1>图</h1>'
          '<img src="${_pngDataUri()}"/>'
          '<img src="pic/b.png"/></body>';
      final book = parseHtmlBook(
        utf8.encode(html),
        format: BookFormat.html,
        siblings: {'pic/b.png': _png},
      );
      expect(book.resources, hasLength(2));
      expect(book.chapters.first.html, contains('pic/b.png'));
    });

    test('外链保留为可点链接（href 不动）', () {
      const html =
          '<body><h1>x</h1>'
          '<p><a href="https://example.com/a">外</a></p></body>';
      final book = parseHtmlBook(utf8.encode(html), format: BookFormat.html);
      expect(
        book.chapters.first.html,
        contains('href="https://example.com/a"'),
      );
    });

    test('没有标题标签时，用调用方给的兜底书名', () {
      final book = parseHtmlBook(
        utf8.encode('<body><p>正文</p></body>'),
        format: BookFormat.html,
        title: '无题',
      );
      expect(book.title, '无题');
    });

    test('坏 HTML（标签未闭合/空 body）：不抛异常', () {
      final book = parseHtmlBook(
        utf8.encode('<body><p>只有一段'),
        format: BookFormat.html,
      );
      expect(book.chapters, isNotEmpty);
      expect(book.chapters.first.html, contains('只有一段'));
    });
  });

  // ---------------------------------------------------------------- RTF

  group('RTF（parseRtfBook）', () {
    test('段落 + 加粗章标题 + 字体/颜色表整组跳过', () {
      const rtf =
          r'{\rtf1\ansi\ansicpg1252'
          r'{\fonttbl{\f0\fnil Arial;}}'
          r'{\colortbl;\red0\green0\blue0;}'
          r'\pard\b 第一章 起点\b0\par '
          r'\pard 正文甲。\par '
          r'\pard\b 第二章 收尾\b0\par \pard 正文乙。\par}';
      final book = parseRtfBook(utf8.encode(rtf), format: BookFormat.rtf);
      expect(book.chapters, hasLength(2));
      expect(book.toc.first.title, '第一章 起点');
      expect(book.chapters.first.html, contains('正文甲'));
      // 字体表的内容不能当正文
      expect(book.chapters.first.html.contains('Arial'), isFalse);
    });

    test('\\uN unicode 转义 + 回落字符跳过', () {
      const rtf = r'{\rtf1\ansi\uc1\pard A\u20013?B\u25991?C\par}';
      final book = parseRtfBook(utf8.encode(rtf), format: BookFormat.rtf);
      expect(book.chapters.first.html, contains('A中B文C'));
    });

    test("\\'hh 代码页转义：ansicpg936 按 GBK 解", () {
      const rtf = r"{\rtf1\ansi\ansicpg936\pard \'d6\'d0\'ce\'c4\par}";
      final book = parseRtfBook(utf8.encode(rtf), format: BookFormat.rtf);
      expect(book.chapters.first.html, contains('中文'));
    });

    test("\\'hh 代码页转义：ansicpg1252 的弯引号", () {
      const rtf = r"{\rtf1\ansi\ansicpg1252\pard \'93hi\'94\par}";
      final book = parseRtfBook(utf8.encode(rtf), format: BookFormat.rtf);
      expect(book.chapters.first.html, contains('\u201Chi\u201D'));
    });

    test('斜体与加粗都产出标签', () {
      const rtf = r'{\rtf1\pard a\b B\b0 \i C\i0 d\par}';
      final book = parseRtfBook(utf8.encode(rtf), format: BookFormat.rtf);
      expect(book.chapters.first.html, contains('<strong>B</strong>'));
      expect(book.chapters.first.html, contains('<em>C</em>'));
    });

    test('坏 RTF（缺右括号 / 纯乱码）：不抛异常，能出正文', () {
      final book = parseRtfBook(
        utf8.encode(r'{\rtf1\pard 没闭合的正文'),
        format: BookFormat.rtf,
      );
      expect(book.chapters, isNotEmpty);
      expect(book.chapters.first.html, contains('没闭合的正文'));
    });

    test('完全没有段落标记时是单章', () {
      final book = parseRtfBook(
        utf8.encode(r'{\rtf1\pard 一整段文字}'),
        format: BookFormat.rtf,
      );
      expect(book.chapters, hasLength(1));
    });
  });

  // ---------------------------------------------------------------- TCR

  group('TCR（decodeTcr / parseTcrBook）', () {
    test('字面量 + 重复扩展 + `!!` 文件头', () {
      final decoded = decodeTcr([
        0x21,
        0x21, // !!
        ...asciiBytes('ab'),
        0x84,
        0x61, // 'a' × 4
        0x7A,
      ]);
      expect(utf8.decode(decoded), 'abaaaaz');
    });

    test('高字节后没有字符（截断）：停，不补字节', () {
      expect(decodeTcr([0x41, 0x8A]).length, 1);
    });

    test('TCR → 书：分章和编码都正确', () {
      // "第一章 一\n\n正文。" 的 UTF-8，用最朴素的字面量编码（<4 的连续重复）
      final encoded = tcrEncode('第一章 起点\n\n正文甲。\n\n第二章 收尾\n\n正文乙。');
      final book = parseTcrBook(encoded, format: BookFormat.tcr);
      expect(book.chapters, hasLength(2));
      expect(book.title, '第一章 起点');
      expect(book.chapters.last.html, contains('正文乙'));
    });

    test('空 TCR：不抛异常', () {
      final r = parseBook(BookFormat.tcr, asciiBytes('!!'));
      expect(r.ok, isTrue);
    });
  });

  // ---------------------------------------------------------------- 分章工具

  group('分章工具（bookChapterize）', () {
    test('只有一个标题段时不按标题切，退回单章', () {
      final blocks = [
        BookBlock('<h2>唯一标题</h2>', title: '唯一标题', heading: true),
        BookBlock('<p>正文</p>'),
      ];
      final r = bookChapterize(blocks, format: BookFormat.txt);
      expect(r.chapters, hasLength(1));
      expect(r.chapters.first.html, contains('唯一标题'));
    });

    test('两个及以上标题段：每段一章且目录对齐', () {
      final blocks = [
        BookBlock('<h2>甲</h2>', title: '甲', heading: true),
        BookBlock('<p>a</p>'),
        BookBlock('<h2>乙</h2>', title: '乙', heading: true),
        BookBlock('<p>b</p>'),
      ];
      final r = bookChapterize(blocks, format: BookFormat.txt);
      expect(r.chapters, hasLength(2));
      expect(r.toc.map((e) => e.title), ['甲', '乙']);
      expect(r.toc[1].chapterIndex, 1);
    });
  });
}

List<int> asciiBytes(String s) => [for (final c in s.codeUnits) c];

/// 最小 TCR 编码器：`<0x80` 原样；`>=0x80` 用 `0x81 + 字节`（长度 1 的扩展）。
/// 这样编码出来的流**一定**能被 `decodeTcr` 还原，正好覆盖"高位是长度+字符"。
List<int> tcrEncode(String text) {
  final out = <int>[0x21, 0x21];
  for (final b in utf8.encode(text)) {
    if (b & 0x80 == 0) {
      out.add(b);
    } else {
      out
        ..add(0x81)
        ..add(b);
    }
  }
  return out;
}
