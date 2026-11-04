// ★★ ③Drive 第 215 轮 **D62「通用查看器（pptx/xlsx/odt/ods/odp）」** 的离线用例。
//
// 官方做法：Drive 用**本地 `uv.html`**（UniversalViewer 的 WebView）渲染 Office；
// 我们是**纯 Dart 阅读器**：解容器 → 抽结构 → 复用既有的分章/渲染管线
// （表格 → `<table>`，幻灯片/页 → 分章）。
//
// fixture **全部代码现造**（zip + 最小 XML），不下载真实文档、不碰网络。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/book_office.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const _xlsxShared = '''
<ss:worksheet xmlns:ss="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <si><t>姓名</t></si>
  <si><t>数量</t></si>
  <si><t>苹果</t></si>
  <si><t>香蕉</t></si>
</ss:worksheet>''';

const _xlsxWorkbook = '''
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheets>
    <sheet name="库存" sheetId="1" r:id="rId1"
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>
    <sheet name="销量" sheetId="2" r:id="rId2"
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>
  </sheets>
</workbook>''';

const _xlsxSheet1 = '''
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
    <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>12</v></c></row>
    <row r="3"><c r="A3" t="s"><v>3</v></c><c r="C3" t="inlineStr"><is><t>备注</t></is></c></row>
  </sheetData>
</worksheet>''';

const _xlsxSheet2 = '''
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1" t="s"><v>0</v></c></row>
  </sheetData>
</worksheet>''';

const _pptxSlide = '''
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <p:cSld><p:spTree>
    <p:sp><p:txBody>
      <a:p><a:r><a:t>TITLE-TEXT</a:t></a:r></a:p>
      <a:p><a:r><a:t>BODY-TEXT</a:t></a:r></a:p>
    </p:txBody></p:sp>
  </p:spTree></p:cSld>
</p:sld>''';

const _odsContent = '''
<office:document-content
  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
  xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
  <office:body><office:spreadsheet>
    <table:table table:name="预算">
      <table:table-row>
        <table:table-cell office:value-type="string"><text:p>项目</text:p></table:table-cell>
        <table:table-cell office:value-type="string"><text:p>金额</text:p></table:table-cell>
      </table:table-row>
      <table:table-row>
        <table:table-cell office:value-type="string"><text:p>服务器</text:p></table:table-cell>
        <table:table-cell office:value-type="float" office:value="9200"></table:table-cell>
      </table:table-row>
    </table:table>
  </office:spreadsheet></office:body>
</office:document-content>''';

const _odpContent = '''
<office:document-content
  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
  xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
  <office:body><office:presentation>
    <draw:page draw:name="封面">
      <draw:frame><draw:text-box><text:p>季度总结</text:p></draw:text-box></draw:frame>
    </draw:page>
    <draw:page draw:name="数据">
      <draw:frame><draw:text-box><text:p>增长 20%</text:p></draw:text-box></draw:frame>
    </draw:page>
  </office:presentation></office:body>
</office:document-content>''';

String _allHtml(BookContent c) => c.chapters.map((ch) => ch.html).join('\n');

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/office/$name',
  isDir: false,
  size: 4096,
  mtime: 1700000000000,
);

/// 阅读页 pump（与 `file_book_formats_test.dart` 同一套离线夹具）。
Future<void> _pumpReader(
  WidgetTester tester,
  FileEntryDto entry,
  List<int> bytes,
) async {
  final t = FakeTransport(const {}, {...FakeTransport.table});
  t.downloadBytes = bytes;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(FileStationApi(api)),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: FileBookStage(entry: entry, bytesUrl: 'https://nas/x'),
        ),
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('D62 · 扩展名接入', () {
    test('xlsx / pptx / ods / odp 都认得（大小写不敏感）', () {
      expect(bookFormatOf('xlsx'), BookFormat.xlsx);
      expect(bookFormatOf('XLSX'), BookFormat.xlsx);
      expect(bookFormatOf('pptx'), BookFormat.pptx);
      expect(bookFormatOf('ods'), BookFormat.ods);
      expect(bookFormatOf('odp'), BookFormat.odp);
      expect(isReadableBook('xlsx'), isTrue);
      expect(isReadableBook('pptx'), isTrue);
      expect(isReadableBook('ods'), isTrue);
      expect(isReadableBook('odp'), isTrue);
    });

    test('docx / odt 仍然认得（回归）', () {
      expect(bookFormatOf('docx'), BookFormat.docx);
      expect(bookFormatOf('odt'), BookFormat.odt);
    });
  });

  group('D62 · XLSX', () {
    final bytes = _zip({
      'xl/sharedStrings.xml': utf8.encode(_xlsxShared),
      'xl/workbook.xml': utf8.encode(_xlsxWorkbook),
      'xl/worksheets/sheet1.xml': utf8.encode(_xlsxSheet1),
      'xl/worksheets/sheet2.xml': utf8.encode(_xlsxSheet2),
    });

    test('两张表 → 两章，标题用 workbook.xml 里的表名', () {
      final c = parseXlsxBook(bytes, format: BookFormat.xlsx);
      expect(c.title, '库存');
      expect(c.chapters.length, 2);
      expect(c.toc.map((e) => e.title), containsAll(['库存', '销量']));
    });

    test('共享字符串 / 数值 / 内联字符串都取到，且列位不错位', () {
      final c = parseXlsxBook(bytes, format: BookFormat.xlsx);
      final html = _allHtml(c);
      expect(html, contains('姓名'));
      expect(html, contains('数量'));
      expect(html, contains('苹果'));
      expect(html, contains('12'));
      expect(html, contains('备注'));
      // 第三行的 `C3` 内联串 ⇒ B3 必须留空占位（否则 C 会顶到第二列）
      expect(
        html,
        contains('<tr><td>香蕉</td><td></td><td>备注</td></tr>'),
        reason: '列位必须按 A1 记法还原，不能顺次挤在一起',
      );
    });

    test('缺工作表 ⇒ 明确报错，不是静默空书', () {
      expect(
        () => parseXlsxBook(_zip({'xl/x.xml': utf8.encode('<a/>')}),
            format: BookFormat.xlsx),
        throwsA(isA<FormatException>()),
      );
    });

    test('parseBook 全链路（走注册表分发）', () {
      final r = parseBook(BookFormat.xlsx, bytes);
      expect(r.error, isNull);
      expect(r.content.chapters.length, 2);
    });
  });

  group('D62 · PPTX', () {
    final bytes = _zip({
      'ppt/slides/slide1.xml': utf8.encode(
        _pptxSlide.replaceAll('TITLE-TEXT', '年度汇报').replaceAll('BODY-TEXT', '第一页正文'),
      ),
      'ppt/slides/slide2.xml': utf8.encode(
        _pptxSlide.replaceAll('TITLE-TEXT', '第二页标题').replaceAll('BODY-TEXT', '第二页正文'),
      ),
      'docProps/core.xml': utf8.encode(
        '<cp:coreProperties xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>季度汇报</dc:title></cp:coreProperties>',
      ),
      'ppt/media/image1.png': const [0x89, 0x50, 0x4E, 0x47],
    });

    test('每页一章，正文文本按顺序抽出，标题取 docProps', () {
      final c = parsePptxBook(bytes, format: BookFormat.pptx);
      expect(c.title, '季度汇报');
      expect(c.chapters.length, 2);
      final html = _allHtml(c);
      expect(html, contains('第 1 页'));
      expect(html, contains('第 2 页'));
      expect(html, contains('年度汇报'));
      expect(html, contains('第一页正文'));
      expect(html, contains('第二页正文'));
      // 图片资源进 resources（阅读器可内嵌）
      expect(c.resources.keys.any((k) => k.endsWith('image1.png')), isTrue);
    });

    test('没有幻灯片 ⇒ 明确报错', () {
      expect(
        () => parsePptxBook(_zip({'ppt/x.txt': utf8.encode('x')}),
            format: BookFormat.pptx),
        throwsA(isA<FormatException>()),
      );
    });

    test('parseBook 全链路', () {
      final r = parseBook(BookFormat.pptx, bytes);
      expect(r.error, isNull);
      expect(r.content.chapters.length, 2);
    });
  });

  group('D62 · 阅读页真的渲染出来（不是只解析成功）', () {
    testWidgets('XLSX：表名与单元格文本出现在阅读页上', (tester) async {
      final bytes = _zip({
        'xl/sharedStrings.xml': utf8.encode(_xlsxShared),
        'xl/workbook.xml': utf8.encode(_xlsxWorkbook),
        'xl/worksheets/sheet1.xml': utf8.encode(_xlsxSheet1),
        'xl/worksheets/sheet2.xml': utf8.encode(_xlsxSheet2),
      });
      await _pumpReader(tester, _entry('库存.xlsx'), bytes);
      // 章节目录/正文里应出现表名与单元格
      expect(find.textContaining('库存'), findsWidgets);
      expect(
        find.textContaining('姓名', findRichText: true),
        findsWidgets,
        reason: 'HTML 正文由 RichText 渲染（同 file_book_formats_test 的取法）',
      );
      expect(find.textContaining('苹果', findRichText: true), findsWidgets);
    });

    testWidgets('ODP：幻灯片文本出现在阅读页上', (tester) async {
      final bytes = _zip({'content.xml': utf8.encode(_odpContent)});
      await _pumpReader(tester, _entry('汇报.odp'), bytes);
      expect(find.textContaining('季度总结', findRichText: true), findsWidgets);
    });
  });

  group('D62 · ODS / ODP', () {
    test('ODS：表名成章 + 单元格（文本/数值）进 table', () {
      final bytes = _zip({'content.xml': utf8.encode(_odsContent)});
      final c = parseOdfBook(bytes, format: BookFormat.ods);
      expect(c.chapters.length, 1);
      // 单张表只有 1 个标题块 ⇒ 分章器按既有规则收成一章（标题兜底"正文"），
      // 表名仍在正文里（下面断言）；**多表/多页**时才有目录（见 ODP 那条）。
      expect(c.toc, isEmpty);
      final html = _allHtml(c);
      expect(html, contains('预算'), reason: '表名要出现在正文里');
      expect(html, contains('项目'));
      expect(html, contains('服务器'));
      expect(html, contains('9200'), reason: 'office:value 的数值也要显示');
      expect(html, contains('<table>'));
    });

    test('ODP：每页一章，页名成标题', () {
      final bytes = _zip({'content.xml': utf8.encode(_odpContent)});
      final c = parseOdfBook(bytes, format: BookFormat.odp);
      expect(c.chapters.length, 2);
      expect(c.toc.map((e) => e.title), containsAll(['封面', '数据']));
      final html = _allHtml(c);
      expect(html, contains('季度总结'));
      expect(html, contains('增长 20%'));
    });

    test('加密 ODF（manifest 有 encryption-data）⇒ 明确不支持，不吐乱码', () {
      final bytes = _zip({
        'content.xml': utf8.encode(_odpContent),
        'META-INF/manifest.xml': utf8.encode(
          '<manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">'
          '<encryption-data/></manifest>',
        ),
      });
      expect(
        () => parseOdfBook(bytes, format: BookFormat.odp),
        throwsA(isA<BookUnsupportedException>()),
      );
    });

    test('缺 content.xml ⇒ 明确报错', () {
      final bytes = _zip({'mimetype': utf8.encode('application/vnd.oasis')});
      expect(
        () => parseOdfBook(bytes, format: BookFormat.ods),
        throwsA(isA<FormatException>()),
      );
    });

    test('parseBook 全链路（ods / odp）', () {
      final ods = parseBook(
        BookFormat.ods,
        _zip({'content.xml': utf8.encode(_odsContent)}),
      );
      expect(ods.error, isNull);
      final odp = parseBook(
        BookFormat.odp,
        _zip({'content.xml': utf8.encode(_odpContent)}),
      );
      expect(odp.error, isNull);
      expect(odp.content.chapters.length, 2);
    });
  });
}
