// DOCX / ODT / OPF 解析 + 接入点的离线测试。
//
// fixture 都是代码里现造的**最小合法容器**（zip + XML），不下载真实文档。
// 覆盖：段落/标题样式/粗斜体/表格/图片关系、ODT 的 draw:image/链接/加密标记、
// OPF 的 manifest+spine+兄弟文件，以及三类坏文件必须"明确报错"。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/book_office.dart';
import 'package:synhub/src/features/files/book_text.dart';

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

const _docxHead =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><w:body>';
const _docxTail = '</w:body></w:document>';

Map<String, List<int>> _docx(Map<String, String> body, {List<int>? png}) => {
  'word/document.xml': utf8.encode('$_docxHead${body['main']}$_docxTail'),
  if (body['rels'] != null)
    'word/_rels/document.xml.rels': utf8.encode(body['rels']!),
  'word/media/image1.png': ?png,
  if (body['core'] != null) 'docProps/core.xml': utf8.encode(body['core']!),
};

void main() {
  // ---------------------------------------------------------------- DOCX

  group('DOCX（parseDocxBook）', () {
    test('标题样式分章 + 粗斜体 + 表格 + 图片关系', () {
      final files = _docx({
        'main':
            '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
            '<w:r><w:t>第一章 起点</w:t></w:r></w:p>'
            '<w:p><w:r><w:t>普通</w:t></w:r>'
            '<w:r><w:rPr><w:b/></w:rPr><w:t>加粗</w:t></w:r>'
            '<w:r><w:rPr><w:i/></w:rPr><w:t>斜体</w:t></w:r></w:p>'
            '<w:p><w:r><w:drawing><a:blip r:embed="rId9"/></w:drawing></w:r></w:p>'
            '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr>'
            '<w:r><w:t>第二节 表</w:t></w:r></w:p>'
            '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>甲</w:t></w:r></w:p></w:tc>'
            '<w:tc><w:p><w:r><w:t>乙</w:t></w:r></w:p></w:tc></w:tr></w:tbl>',
        'rels':
            '<?xml version="1.0"?><Relationships xmlns="http://schemas.'
            'openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId9" Target="media/image1.png" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/'
            'relationships/image"/></Relationships>',
        'core':
            '<?xml version="1.0"?><cp:coreProperties xmlns:cp="http://'
            'schemas.openxmlformats.org/package/2006/metadata/core-properties"'
            ' xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:title>DOCX 之书</dc:title></cp:coreProperties>',
      }, png: _png);
      final book = parseDocxBook(_zip(files), format: BookFormat.docx);
      expect(book.title, '第一章 起点'); // 首个标题比 core.xml 更贴近正文
      expect(book.chapters, hasLength(2));
      expect(book.toc.first.title, '第一章 起点');
      expect(book.chapters.first.html, contains('<strong>加粗</strong>'));
      expect(book.chapters.first.html, contains('<em>斜体</em>'));
      expect(book.resources.keys.first, 'word/media/image1.png');
      expect(book.chapters.first.html, contains('word/media/image1.png'));
      // 表格在「第二节 表」那一章里
      expect(book.chapters.last.html, contains('<table>'));
      expect(book.chapters.last.html, contains('甲'));
    });

    test('外链关系（Target 是 URL）保留成 <a href>', () {
      final files = _docx({
        'main':
            '<w:p><w:hyperlink r:id="rId2">'
            '<w:r><w:t>示例</w:t></w:r></w:hyperlink></w:p>',
        'rels':
            '<?xml version="1.0"?><Relationships xmlns="http://schemas.'
            'openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId2" Target="https://example.com/a" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/'
            'relationships/hyperlink"/></Relationships>',
      });
      final book = parseDocxBook(_zip(files), format: BookFormat.docx);
      expect(
        book.chapters.first.html,
        contains('href="https://example.com/a"'),
      );
    });

    test('找不到的关系（r:embed 指向缺失的 rId）：不画空图、不崩', () {
      final files = _docx({
        'main':
            '<w:p><w:r><w:drawing><a:blip r:embed="rId404"/>'
            '</w:drawing></w:r><w:r><w:t>文字还在</w:t></w:r></w:p>',
      });
      final book = parseDocxBook(_zip(files), format: BookFormat.docx);
      expect(book.chapters.first.html.contains('<img'), isFalse);
      expect(book.chapters.first.html, contains('文字还在'));
    });

    test('没有文档标题样式时，core.xml 的书名兜底', () {
      final files = _docx({
        'main': '<w:p><w:r><w:t>只有正文</w:t></w:r></w:p>',
        'core':
            '<?xml version="1.0"?><cp:coreProperties xmlns:cp="http://x" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:title>核心书名</dc:title></cp:coreProperties>',
      });
      final book = parseDocxBook(_zip(files), format: BookFormat.docx);
      expect(book.title, '核心书名');
    });

    test('坏 DOCX（不是 zip）→ parseFailed，绝不输出乱码', () {
      final r = parseBook(BookFormat.docx, utf8.encode('这不是一个 zip'));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
      expect(r.content.chapters, isEmpty);
    });

    test('zip 里缺 word/document.xml → parseFailed', () {
      final r = parseBook(
        BookFormat.docx,
        _zip({'hello.txt': utf8.encode('x')}),
      );
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });
  });

  // ---------------------------------------------------------------- ODT

  const odtManifest =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:'
      'xmlns:manifest:1.0" manifest:version="1.2">'
      '<manifest:file-entry manifest:full-path="content.xml" '
      'manifest:media-type="text/xml"/></manifest:manifest>';

  const odtEncryptedManifest =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:'
      'xmlns:manifest:1.0">'
      '<manifest:file-entry manifest:full-path="content.xml" '
      'manifest:media-type="text/xml">'
      '<manifest:encryption-data '
      'manifest:checksum-type="SHA1/1K"/></manifest:file-entry>'
      '</manifest:manifest>';

  const odtStyles =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:'
      'xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:'
      'style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">'
      '<office:styles>'
      '<style:style style:name="Heading_20_1" style:family="paragraph">'
      '<text:outline-level>1</text:outline-level></style:style>'
      '<style:style style:name="Bold_20_Text" style:family="text">'
      '<style:text-properties fo:font-weight="bold"/></style:style>'
      '</office:styles></office:document-styles>';

  String odtContent(String body) =>
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:'
      'xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:'
      'text:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"'
      ' xmlns:xlink="http://www.w3.org/1999/xlink" '
      'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">'
      '<office:body><office:text>$body</office:text></office:body>'
      '</office:document-content>';

  group('ODT（parseOdtBook）', () {
    test('text:h/text:p 分章 + 加粗 span + 链接 + 表格 + 图片', () {
      final files = {
        'mimetype': utf8.encode('application/vnd.oasis.opendocument.text'),
        'META-INF/manifest.xml': utf8.encode(odtManifest),
        'styles.xml': utf8.encode(odtStyles),
        'content.xml': utf8.encode(
          odtContent(
            '<text:h text:outline-level="1">第一章 起点</text:h>'
            '<text:p>普通<text:span text:style-name="Bold_20_Text">加粗</text:span>'
            '正文</text:p>'
            '<text:p><draw:frame><draw:image xlink:href="Pictures/p.png"/>'
            '</draw:frame></text:p>'
            '<text:p>链接<text:a xlink:href="https://example.com/">示例</text:a>'
            '</text:p>'
            '<text:h text:outline-level="2">第二节 表</text:h>'
            '<table:table><table:table-row><table:table-cell><text:p>甲</text:p>'
            '</table:table-cell><table:table-cell><text:p>乙</text:p>'
            '</table:table-cell></table:table-row></table:table>',
          ),
        ),
        'Pictures/p.png': _png,
      };
      final book = parseOdtBook(_zip(files), format: BookFormat.odt);
      expect(book.chapters, hasLength(2));
      expect(book.toc.first.title, '第一章 起点');
      expect(book.chapters.first.html, contains('<strong>加粗</strong>'));
      expect(book.chapters.first.html, contains('pictures/p.png'));
      expect(book.resources, hasLength(1));
      expect(book.chapters.first.html, contains('href="https://example.com/"'));
      expect(book.chapters.last.html, contains('<table>'));
      expect(book.chapters.last.html, contains('甲'));
    });

    test('text:p 用 Heading 样式（outline-level）也分章', () {
      final files = {
        'META-INF/manifest.xml': utf8.encode(odtManifest),
        'styles.xml': utf8.encode(odtStyles),
        'content.xml': utf8.encode(
          odtContent(
            '<text:p text:style-name="Heading_20_1">甲章</text:p><text:p>a</text:p>'
            '<text:p text:style-name="Heading_20_1">乙章</text:p><text:p>b</text:p>',
          ),
        ),
      };
      final book = parseOdtBook(_zip(files), format: BookFormat.odt);
      expect(book.chapters, hasLength(2));
      expect(book.toc.map((e) => e.title), ['甲章', '乙章']);
    });

    test('text:s / text:tab / text:line-break 保留空格与换行', () {
      final files = {
        'META-INF/manifest.xml': utf8.encode(odtManifest),
        'content.xml': utf8.encode(
          odtContent(
            '<text:p>a<text:s text:c="3"/>b<text:tab/>c'
            '<text:line-break/>d</text:p>',
          ),
        ),
      };
      final book = parseOdtBook(_zip(files), format: BookFormat.odt);
      final html = book.chapters.first.html;
      expect(html, contains('a   b'));
      expect(html, contains('<br>'));
    });

    test('加密 ODT（manifest 标 encryption-data）→ 明确报"不支持"', () {
      final files = {
        'META-INF/manifest.xml': utf8.encode(odtEncryptedManifest),
        'content.xml': utf8.encode(odtContent('<text:p>x</text:p>')),
      };
      final r = parseBook(BookFormat.odt, _zip(files));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('encryption-data'));
    });

    test('缺 content.xml → parseFailed', () {
      final r = parseBook(
        BookFormat.odt,
        _zip({'META-INF/manifest.xml': utf8.encode(odtManifest)}),
      );
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('坏 ODT（不是 zip）→ parseFailed', () {
      final r = parseBook(BookFormat.odt, List<int>.filled(64, 0x41));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });
  });

  // ---------------------------------------------------------------- OPF

  const opfXml =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/'
      '1.1/"><dc:title>散装之书</dc:title><dc:creator>作者</dc:creator>'
      '</metadata><manifest>'
      '<item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="img" href="images/p.png" media-type="image/png"/>'
      '</manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine>'
      '</package>';

  group('OPF（parseOpfBook）', () {
    test('给了兄弟文件：spine 顺序 → 章节 + 目录 + 书名/作者 + 图片资源', () {
      final siblings = {
        'text/ch1.xhtml': Uint8List.fromList(
          utf8.encode('<html><body><h1>第一章</h1><p>甲</p></body></html>'),
        ),
        'text/ch2.xhtml': Uint8List.fromList(
          utf8.encode('<html><body><h1>第二章</h1><p>乙</p></body></html>'),
        ),
        'images/p.png': _png,
      };
      final book = parseOpfBook(
        utf8.encode(opfXml),
        format: BookFormat.opf,
        siblings: siblings,
      );
      expect(book.title, '散装之书');
      expect(book.author, '作者');
      expect(book.chapters, hasLength(2));
      expect(book.chapters.first.href, 'text/ch1.xhtml');
      expect(book.chapters.last.html, contains('乙'));
      expect(book.resources, contains('images/p.png'));
    });

    test('没给兄弟文件 → 明确报"缺正文文件"（不是乱码）', () {
      final r = parseBook(BookFormat.opf, utf8.encode(opfXml));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('缺 2'));
    });

    test('spine 为空且 manifest 没有正文 → parseFailed', () {
      const empty =
          '<?xml version="1.0"?><package xmlns="http://www.idpf.org/'
          '2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>空</dc:title></metadata><manifest/><spine/></package>';
      final r = parseBook(BookFormat.opf, utf8.encode(empty));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('坏 OPF（不是 XML）→ parseFailed', () {
      final r = parseBook(BookFormat.opf, utf8.encode('not xml at all <<<'));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('normalizeBookPath / opfDir 的基本行为', () {
      expect(normalizeBookPath('a/b/../c.png'), 'a/c.png');
      expect(normalizeBookPath('./x.png'), 'x.png');
      expect(opfDir('OEBPS/content.opf'), 'OEBPS/');
      expect(opfDir('content.opf'), '');
    });
  });
}
