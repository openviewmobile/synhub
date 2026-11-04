// FB3（FictionBook 3）解析 + 接入点的离线测试。
//
// 两层 fixture：
//   1. 代码里现造的**兼容形态**（zip + 旧实现的 `<FictionBook>` 根）—— 保证旧写法
//      不回归；
//   2. 代码里现造的**真实 OPC 形态**（`[Content_Types].xml` + `fb3-body` /
//      `fb3-description` + `_rels` 图片映射 + rels 发现的怪路径 part）—— 这是
//      `gribuser/FB3` 真实样本的结构，测试不依赖 /tmp 也能跑；
//   3. /tmp/ebook-samples 里的 6 份**真实 .fb3**（存在才跑）——端到端证据。
//
// 覆盖：part 发现（Content_Types/rels/约定路径/扫描）、元数据（title/main、
// fb3-relations subject、lang、封面 thumbnail）、section 摊平成章节 + 目录层级、
// 混合内容（裸文本 + emphasis/strong/sup）不丢字、rels 图片映射到包内资源、
// 表格、锚点、裸 XML + base64 <binary>，以及坏/截断/缺正文/加密 → 具体人话错误。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/book_cover.dart';
import 'package:synhub/src/features/files/book_fb3.dart';
import 'package:synhub/src/features/files/book_package.dart';
import 'package:synhub/src/features/files/book_xml.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';

/// 1×1 透明 PNG
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

// --------------------------------------------------------------- 兼容形态（旧根）

const _fb3Xml = '''<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.fictionbook.org/FictionBook3">
  <description>
    <title-info>
      <book-title>FB3 之书</book-title>
      <author><first-name>列夫</first-name><last-name>托尔斯泰</last-name></author>
    </title-info>
    <document-info>
      <author><nickname>制作者</nickname></author>
    </document-info>
  </description>
  <body>
    <section id="s1">
      <title><p>第一章 起点</p></title>
      <p>中文正文，包含<emphasis>强调</emphasis>与<strong>加粗</strong>。</p>
      <empty-line/>
      <image href="images/pic.png"/>
      <p><a href="#fn1">脚注</a></p>
      <section id="s2">
        <title><p>第一节 嵌套</p></title>
        <p id="fn1">这是脚注内容。</p>
      </section>
    </section>
    <section id="s3">
      <title><p>第二章 收尾</p></title>
      <p>结束。</p>
    </section>
  </body>
</FictionBook>''';

// --------------------------------------------------------------- 真实 OPC 形态

const _opcDescription = '''<?xml version="1.0" encoding="UTF-8"?>
<fb3-description xmlns="http://www.fictionbook.org/FictionBook3/description">
  <title><main>真实 OPC 之书</main><sub>副题不算书名</sub></title>
  <fb3-relations>
    <subject link="author" id="a1">
      <first-name>列夫</first-name><middle-name>尼古拉耶维奇</middle-name><last-name>托尔斯泰</last-name>
    </subject>
    <subject link="managing_editor" id="a2">
      <first-name>不该</first-name><last-name>出现</last-name>
    </subject>
  </fb3-relations>
  <lang>ru</lang>
</fb3-description>''';

const _opcBody = '''<?xml version="1.0" encoding="UTF-8"?>
<fb3-body xmlns="http://www.fictionbook.org/FictionBook3/body">
  <section id="s1">
    <title><p>第一章 起点</p></title>
    <p>正文<strong>粗</strong>与<sup>上标</sup>、<strikethrough>划掉</strikethrough>。</p>
    <p><img src="img1" alt="插图"/></p>
    <table>
      <title><p>表题</p></title>
      <tr><td><p>甲</p></td><th>乙</th></tr>
    </table>
    <p><a href="#fn1">脚注</a></p>
  </section>
  <section id="s2">
    <title><p>第二章</p></title>
    <p id="fn1">注释内容。</p>
  </section>
</fb3-body>''';

Map<String, List<int>> _opcFiles() => {
  '[Content_Types].xml': utf8.encode('''<?xml version="1.0"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="png" ContentType="image/png"/>
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Override PartName="/fb3/description.xml" ContentType="application/fb3-description+xml"/>
  <Override PartName="/fb3/body.xml" ContentType="application/fb3-body+xml"/>
</Types>'''),
  '_rels/.rels': utf8.encode('''<?xml version="1.0"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail" Target="fb3/img/cover.png"/>
  <Relationship Id="rId2" Type="http://www.fictionbook.org/FictionBook3/relationships/Book" Target="fb3/description.xml"/>
</Relationships>'''),
  'fb3/description.xml': utf8.encode(_opcDescription),
  'fb3/body.xml': utf8.encode(_opcBody),
  'fb3/_rels/body.xml.rels': utf8.encode('''<?xml version="1.0"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="img1" Type="http://www.fictionbook.org/FictionBook3/relationships/image" Target="img/pic.png"/>
</Relationships>'''),
  'fb3/img/pic.png': _png,
  'fb3/img/cover.png': _png,
};

void main() {
  // ================================================================ 兼容形态
  group('FB3 兼容形态（旧 <FictionBook> 根）', () {
    test('zip 容器：section 摊平成章节 + 目录层级 + 元数据', () {
      final bytes = _zip({
        'book.fb3': utf8.encode(_fb3Xml),
        'images/pic.png': _png,
      });
      final book = parseFb3Book(bytes, format: BookFormat.fb3);
      expect(book.format, BookFormat.fb3);
      expect(book.title, 'FB3 之书');
      expect(book.author, '列夫 托尔斯泰');
      expect(book.chapters, hasLength(3));
      expect(book.toc.map((e) => e.depth).toList(), [0, 1, 0]);
      expect(book.toc.map((e) => e.title).toList(), [
        '第一章 起点',
        '第一节 嵌套',
        '第二章 收尾',
      ]);
    });

    test('混合内容不丢裸文本：普通/强调/加粗都在', () {
      final bytes = _zip({
        'book.fb3': utf8.encode(_fb3Xml),
        'images/pic.png': _png,
      });
      final book = parseFb3Book(bytes, format: BookFormat.fb3);
      expect(
        book.chapters[0].html,
        contains('<p>中文正文，包含<em>强调</em>与<strong>加粗</strong>。</p>'),
      );
      // `<empty-line/>` 后面的图片没被吞掉
      expect(book.chapters[0].html, contains('<p><br></p>'));
      expect(book.chapters[0].html, contains('<img src="images/pic.png"'));
      expect(book.chapters[0].html, contains('<a href="#fn1">脚注</a>'));
      // 标题不重复出现在正文里（单独当章节标题）
      expect(book.chapters[0].html, isNot(contains('第一章 起点')));
      // 嵌套 section 是独立章节，正文里不重复
      expect(book.chapters[0].html, isNot(contains('脚注内容')));
    });

    test('图片进 resources；锚点能定位到章节', () {
      final bytes = _zip({
        'book.fb3': utf8.encode(_fb3Xml),
        'images/pic.png': _png,
      });
      final book = parseFb3Book(bytes, format: BookFormat.fb3);
      expect(book.resources.keys, contains('images/pic.png'));
      expect(book.anchors['#fn1'], 1);
      expect(book.anchorFor('', '#fn1'), 1);
    });

    test('裸 XML 的 .fb3（没有 zip 外壳）+ base64 <binary> 资源', () {
      final withBinary = _fb3Xml
          .replaceFirst(
            '<image href="images/pic.png"/>',
            '<image href="#bin1"/>',
          )
          .replaceFirst(
            '</body>',
            '<binary id="bin1" content-type="image/png">'
                '${base64.encode(_png)}</binary></body>',
          );
      final book = parseFb3Book(
        utf8.encode(withBinary),
        format: BookFormat.fb3,
      );
      expect(book.chapters, hasLength(3));
      expect(book.resources.keys, contains('bin1'));
      expect(book.resources['bin1'], _png);
    });

    test('没有 section 的书 → 整本当一章（书名兜底）', () {
      final noSections = '''<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.fictionbook.org/FictionBook3">
  <description><title-info><book-title>单节书</book-title></title-info></description>
  <body><p>只有一段正文。</p></body>
</FictionBook>''';
      final book = parseFb3Book(
        utf8.encode(noSections),
        format: BookFormat.fb3,
      );
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.title, '单节书');
      expect(book.chapters.first.generatedUnit, isNull);
      expect(book.chapters.first.html, contains('只有一段正文。'));
      // description 的文本不会被当成正文
      expect(book.chapters.first.html, isNot(contains('单节书')));
    });

    test('封面抠取：<cover> 指向的包内图片', () {
      final withCover = _fb3Xml.replaceFirst(
        '<body>',
        '<body><cover><image href="images/pic.png"/></cover>',
      );
      final bytes = _zip({
        'book.fb3': utf8.encode(withCover),
        'images/pic.png': _png,
      });
      expect(bookCoverSupported('fb3'), isTrue);
      final cover = fb3CoverBytes(bytes);
      expect(cover, _png);
      expect(bookCoverBytes('fb3', bytes), _png);
    });
  });

  // ================================================================ 真实 OPC 形态
  group('FB3 真实 OPC 形态（fb3-body + fb3-description + rels）', () {
    test('Content_Types 发现 part；元数据从 fb3-description 取', () {
      final book = parseFb3Book(_zip(_opcFiles()), format: BookFormat.fb3);
      expect(book.title, '真实 OPC 之书');
      // managing_editor 不是作者
      expect(book.author, '列夫 尼古拉耶维奇 托尔斯泰');
      expect(book.chapters, hasLength(2));
      expect(book.toc.map((e) => e.title).toList(), ['第一章 起点', '第二章']);
      expect(book.toc.map((e) => e.depth).toList(), [0, 0]);
    });

    test('rels 把 src="img1" 映射到包内真实路径', () {
      final book = parseFb3Book(_zip(_opcFiles()), format: BookFormat.fb3);
      expect(book.resources.keys, contains('fb3/img/pic.png'));
      expect(book.chapters[0].html, contains('<img src="fb3/img/pic.png"'));
    });

    test('行内标签 + 表格 + 锚点', () {
      final book = parseFb3Book(_zip(_opcFiles()), format: BookFormat.fb3);
      final html = book.chapters[0].html;
      expect(html, contains('<strong>粗</strong>'));
      expect(html, contains('<sup>上标</sup>'));
      expect(html, contains('<s>划掉</s>'));
      expect(html, contains('<table>'));
      expect(html, contains('表题'));
      expect(html, contains('甲'));
      expect(html, contains('乙'));
      expect(book.anchors['#fn1'], 1);
    });

    test('根 rels 的 thumbnail → 封面', () {
      final bytes = _zip(_opcFiles());
      expect(fb3CoverBytes(bytes), _png);
      expect(bookCoverBytes('fb3', bytes), _png);
    });

    test('rels 链发现的"怪路径"正文（无扩展名、目录大写/转义）', () {
      // 无 Content_Types：正文在 `pkg/../book`（无扩展名），描述在 `pkg/meta.xml`，
      // 靠根 rels 的 Book + meta.xml.rels 的 body 关系发现（Hardcore 样本同构）。
      final bytes = _zip({
        '_rels/.rels': utf8.encode('''<?xml version="1.0"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId2" Type="http://www.fictionbook.org/FictionBook3/relationships/Book" Target="pkg/meta.xml"/>
</Relationships>'''),
        'pkg/meta.xml': utf8.encode('''<?xml version="1.0"?>
<fb3-description xmlns="http://www.fictionbook.org/FictionBook3/description">
  <title><main>怪路径之书</main></title>
</fb3-description>'''),
        'pkg/_rels/meta.xml.rels': utf8.encode('''<?xml version="1.0"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId0" Type="http://www.fictionbook.org/FictionBook3/relationships/body" Target="../book"/>
</Relationships>'''),
        'book': utf8.encode('''<?xml version="1.0"?>
<fb3-body xmlns="http://www.fictionbook.org/FictionBook3/body">
  <section id="x1"><title><p>独章</p></title><p>正文一段。</p></section>
</fb3-body>'''),
      });
      final book = parseFb3Book(bytes, format: BookFormat.fb3);
      expect(book.title, '怪路径之书');
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.title, '独章');
      expect(book.chapters.first.html, contains('正文一段。'));
    });

    test('没有任何发现线索时扫描根元素找 part', () {
      final bytes = _zip({
        'desc_part': utf8.encode('''<?xml version="1.0"?>
<fb3-description xmlns="http://www.fictionbook.org/FictionBook3/description">
  <title><main>扫描之书</main></title>
</fb3-description>'''),
        'weird_body': utf8.encode('''<?xml version="1.0"?>
<fb3-body xmlns="http://www.fictionbook.org/FictionBook3/body">
  <section id="x1"><title><p>扫描章</p></title><p>扫描正文。</p></section>
</fb3-body>'''),
      });
      final book = parseFb3Book(bytes, format: BookFormat.fb3);
      expect(book.title, '扫描之书');
      expect(book.chapters.first.title, '扫描章');
      expect(book.chapters.first.html, contains('扫描正文。'));
    });

    test('probe 报告结构摘要', () {
      final p = fb3Probe(_zip(_opcFiles()));
      expect(p['ok'], isTrue);
      expect(p['zip'], isTrue);
      expect(p['fictionbook'], isTrue);
      expect(p['sections'], 2);
      expect(p['tables'], 1);
      expect(p['images'], 2);
      expect(p['title'], '真实 OPC 之书');
      expect(p['author'], '列夫 尼古拉耶维奇 托尔斯泰');
      expect(p['lang'], 'ru');
      expect(p['cover'], isTrue);
    });

    test('包装 section（只有子 section）不成空章', () {
      final bytes = _zip({
        '[Content_Types].xml': utf8.encode('''<?xml version="1.0"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Override PartName="/fb3/body.xml" ContentType="application/fb3-body+xml"/>
</Types>'''),
        'fb3/body.xml': utf8.encode('''<?xml version="1.0"?>
<fb3-body xmlns="http://www.fictionbook.org/FictionBook3/body">
  <section id="outer">
    <section id="inner"><title><p>真标题</p></title><p>内容。</p></section>
  </section>
</fb3-body>'''),
      });
      final book = parseFb3Book(bytes, format: BookFormat.fb3);
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.title, '真标题');
      expect(book.toc.first.depth, 0);
    });
  });

  // ================================================================ 错误路径
  group('FB3 错误路径（具体人话错误，不泛化）', () {
    test('非 zip 且根元素不对 → 明确说不是 FB3', () {
      final r = parseBook(BookFormat.fb3, utf8.encode('这不是一本书'));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
      expect(r.error, contains('不是 FB3'));
      expect(r.content.chapters, isEmpty);
    });

    test('zip 里没有正文部件 → 明确说缺 fb3-body', () {
      final r = parseBook(
        BookFormat.fb3,
        _zip({'readme.txt': utf8.encode('nope')}),
      );
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
      expect(r.error, contains('找不到正文部件'));
    });

    test('截断的 zip → 明确说压缩包损坏', () {
      final full = _zip(_opcFiles());
      final cut = Uint8List.sublistView(full, 0, full.length ~/ 2);
      final r = parseBook(BookFormat.fb3, cut);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
      expect(r.error, contains('压缩包损坏'));
      expect(r.content.chapters, isEmpty);
    });

    test('根元素是 <html> → 明确说不是 FB3', () {
      final r = parseBook(
        BookFormat.fb3,
        utf8.encode('<html><body>x</body></html>'),
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('不是 FB3'));
    });

    test('发现 OPC 加密 → 能力边界，明确不解密', () {
      final bytes = _zip({
        ..._opcFiles(),
        'META-INF/encryption.xml': utf8.encode('<encryption/>'),
      });
      final r = parseBook(BookFormat.fb3, bytes);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('加密'));
    });

    test('直接调 parseFb3Book 也抛 Fb3FormatException（不是笼统 FormatException）', () {
      expect(
        () => parseFb3Book(utf8.encode('坏数据'), format: BookFormat.fb3),
        throwsA(isA<Fb3FormatException>()),
      );
    });
  });

  // ================================================================ 真实样本
  //
  // 真实 FB3 样本（gribuser/FB3 官方规范仓库 `Examples/` + `api/perl/…/fb3_to_fb2`，
  // 由 Litres 的 FB3 工具链产出；样本不进仓库，只在 /tmp 存在时跑）。
  group('真实 FB3 样本（/tmp/ebook-samples，端到端）', () {
    const dir = '/tmp/ebook-samples';
    const samples = [
      'fb3_author_exists_193286.fb3',
      'fb3_table_title_189446.fb3',
      'fb3_marker_156543.fb3',
      'fb3_nightmare_example.fb3',
      'fb3_hardcore_structure.fb3',
      'fb3_anathomy_tutorial.fb3',
    ];
    File sample(String n) => File('$dir/$n');
    final missing = samples.any((n) => sample(n).existsSync())
        ? null
        : '真实 FB3 样本不存在（/tmp/ebook-samples）';

    test('6 份全部能打开：章节/标题/正文都非空', () {
      var seen = 0;
      for (final n in samples) {
        if (!sample(n).existsSync()) continue;
        seen++;
        final r = parseBook(BookFormat.fb3, sample(n).readAsBytesSync());
        expect(r.ok, isTrue, reason: '$n：${r.error}');
        expect(r.content.title.trim(), isNotEmpty, reason: n);
        expect(r.content.chapters, isNotEmpty, reason: n);
        final bodyChars = r.content.chapters.fold<int>(
          0,
          (a, c) => a + c.html.replaceAll(RegExp(r'<[^>]*>'), '').trim().length,
        );
        expect(bodyChars, greaterThan(5), reason: '$n 正文疑似为空');
      }
      expect(seen, 6);
    }, skip: missing);

    test('作者/语言从 fb3-description 正确取到', () {
      final a = fb3Probe(
        sample('fb3_author_exists_193286.fb3').readAsBytesSync(),
      );
      expect(a['title'], 'The Believer, Issue 111');
      expect(a['author'], 'Vendela Vida');
      expect(a['lang'], 'en');

      final m = fb3Probe(sample('fb3_marker_156543.fb3').readAsBytesSync());
      expect(m['title'], contains('ciuciubabkę'));
      expect(m['author'], 'Ewa Witkiewicz');
      expect(m['lang'], 'pl');

      final an = fb3Probe(
        sample('fb3_anathomy_tutorial.fb3').readAsBytesSync(),
      );
      expect(an['title'], 'Анатомия человека');
      expect(an['author'], contains('Сапин'));
      expect(an['author'], contains('Никитюк'));
      expect(an['lang'], 'ru');
    }, skip: missing);

    test('表格样本能取到表格', () {
      final book = parseBook(
        BookFormat.fb3,
        sample('fb3_table_title_189446.fb3').readAsBytesSync(),
      );
      expect(book.ok, isTrue, reason: book.error);
      expect(book.content.title, 'Gidy-gidy carousel');
      final html = book.content.chapters.map((c) => c.html).join();
      expect(html, contains('<table>'));
      expect(html, contains('<tr>'));
      expect(html, contains('<td'));
      expect(html, contains('one yes da'));
      expect(html, contains('TITLE one ok'));
    }, skip: missing);

    test('rels 图片映射：marker / nightmare / anathomy / hardcore', () {
      // marker：src="img_eaccff44-…" → fb3/img/… .jpg
      final marker = parseBook(
        BookFormat.fb3,
        sample('fb3_marker_156543.fb3').readAsBytesSync(),
      );
      expect(marker.ok, isTrue, reason: marker.error);
      const markerKey = 'fb3/img/img_eaccff44-b0bd-570c-beeb-8e28643c3aca.jpg';
      expect(marker.content.resources.keys, contains(markerKey));
      expect(
        marker.content.chapters.map((c) => c.html).join(),
        contains('src="$markerKey"'),
      );

      // nightmare：src="img4" → rels → fb3/img/_600400.jpg
      final nightmare = parseBook(
        BookFormat.fb3,
        sample('fb3_nightmare_example.fb3').readAsBytesSync(),
      );
      expect(nightmare.ok, isTrue, reason: nightmare.error);
      expect(nightmare.content.resources.keys, contains('fb3/img/_600400.jpg'));
      expect(
        nightmare.content.chapters.map((c) => c.html).join(),
        contains('src="fb3/img/_600400.jpg"'),
      );

      // anathomy：src="rId1" → rels → fb3/img/split.png
      final anatomy = parseBook(
        BookFormat.fb3,
        sample('fb3_anathomy_tutorial.fb3').readAsBytesSync(),
      );
      expect(anatomy.ok, isTrue, reason: anatomy.error);
      expect(anatomy.content.resources.keys, contains('fb3/img/split.png'));
      expect(
        anatomy.content.chapters.map((c) => c.html).join(),
        contains('src="fb3/img/split.png"'),
      );

      // hardcore：src="img7" → rels（目标带 ./ 的相对路径）→ Pictures/t11.png
      final hardcore = parseBook(
        BookFormat.fb3,
        sample('fb3_hardcore_structure.fb3').readAsBytesSync(),
      );
      expect(hardcore.ok, isTrue, reason: hardcore.error);
      expect(hardcore.content.resources.keys, contains('pictures/t11.png'));
      expect(
        hardcore.content.chapters.map((c) => c.html).join(),
        contains('src="pictures/t11.png"'),
      );
    }, skip: missing);

    test('nightmare（含表格/notes/内联图）不崩、内容残缺可控', () {
      final r = parseBook(
        BookFormat.fb3,
        sample('fb3_nightmare_example.fb3').readAsBytesSync(),
      );
      expect(r.ok, isTrue, reason: r.error);
      expect(r.content.chapters.length, greaterThanOrEqualTo(20));
      expect(r.content.resources.length, greaterThanOrEqualTo(20));
      final html = r.content.chapters.map((c) => c.html).join();
      expect(html, contains('<table>'));
      // 正文里真的有书里的字（不是只剩空壳）
      expect(html, contains('Секция со всякими хитрыми атрибутами'));
    }, skip: missing);

    test('有 rasters 封面的样本能取到封面（nightmare）', () {
      final bytes = sample('fb3_nightmare_example.fb3').readAsBytesSync();
      final cover = fb3CoverBytes(bytes);
      expect(cover, isNotNull);
      expect(looksLikeCoverImage(cover!), isTrue);
      expect(bookCoverBytes('fb3', bytes), isNotNull);
    }, skip: missing);

    test('封面只有 SVG 的样本：解析层给出 SVG，列表层明确退回图标', () {
      // Hardcore 的 thumbnail 是 cover/thumb.svg —— 解析层能定位，
      // 但 book_cover 只认光栅图，bookCoverBytes 返回 null（不硬塞给 Image.memory）
      final bytes = sample('fb3_hardcore_structure.fb3').readAsBytesSync();
      final cover = fb3CoverBytes(bytes);
      expect(cover, isNotNull);
      expect(cover!.length, greaterThan(0));
      expect(looksLikeCoverImage(cover), isFalse);
      expect(bookCoverBytes('fb3', bytes), isNull);
    }, skip: missing);

    test('硬核结构样本：怪路径/百分号转义/无扩展名 part 全部读开', () {
      final bytes = sample('fb3_hardcore_structure.fb3').readAsBytesSync();
      final r = parseBook(BookFormat.fb3, bytes);
      expect(r.ok, isTrue, reason: r.error);
      expect(r.content.title, 'Тестовая FB2 книга');
      expect(r.content.author, 'Илья Пономаренко');
      expect(r.content.chapters.length, greaterThanOrEqualTo(40));
      // 正文 part 在根目录、无扩展名：能读到内容而不是空壳
      expect(
        r.content.chapters.fold<int>(0, (a, c) => a + c.html.length),
        greaterThan(10000),
      );
    }, skip: missing);

    test('失败的结构原因：正文 part 根是 fb3-body（不是 FictionBook）', () {
      final files = unzipBookPackage(
        sample('fb3_nightmare_example.fb3').readAsBytesSync(),
        'FB3',
      );
      expect(files.containsKey('fb3/body.xml'), isTrue);
      expect(files.containsKey('fb3/description.xml'), isTrue);
      final body = parseBookXmlBytes(files['fb3/body.xml']!)!;
      final desc = parseBookXmlBytes(files['fb3/description.xml']!)!;
      expect(body.children.first.local, 'fb3-body');
      expect(desc.children.first.local, 'fb3-description');
      // 图片不是包内直路径，而是 rel Id（src="img4"）+ rels 映射到 img/…。
      expect(files.containsKey('fb3/_rels/body.xml.rels'), isTrue);
      final rels = parseBookXmlBytes(files['fb3/_rels/body.xml.rels']!)!;
      expect(rels.descendants('relationship'), isNotEmpty);
    }, skip: missing);
  });

  // ================================================================ 接入点
  group('FB3 接入点', () {
    test('扩展名 → 格式 → 可读', () {
      expect(bookFormatOf('fb3'), BookFormat.fb3);
      expect(bookFormatOf('FB3'), BookFormat.fb3);
      expect(isReadableBook('fb3'), isTrue);
      expect(BookFormat.fb3.label, 'FB3');
    });

    test('预览页把 .fb3 归到电子书（内嵌阅读）', () {
      final e = FileEntryDto(
        name: 'a.fb3',
        path: '/books/a.fb3',
        isDir: false,
        size: 2048,
        mtime: 1700000000000,
      );
      expect(filePreviewKind(e), FilePreviewKind.book);
      expect(canPreviewInline(e), isTrue);
    });
  });
}
