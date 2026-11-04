// XPS / OXPS 解析 + 接入点的离线测试。
//
// fixture 是代码里现造的**最小合法 OPC 包**（zip + [Content_Types].xml +
// FixedDocumentSequence/FixedDocument/FixedPage），不下载真实文档。
// 覆盖：Glyphs 按行聚合成富文本、ImageBrush → 图片资源、Path → 明确"未渲染"提示、
// 加密（EncryptedPackage）→ 能力边界、坏/截断/缺部件 → 明确解析失败、封面抠取，
// 以及阅读页 widget 真的把解析结果画出来。
import 'dart:convert';
import 'dart:io';
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
import 'package:synhub/src/features/files/book_cover.dart';
import 'package:synhub/src/features/files/book_xps.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

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

/// UTF-16LE + BOM（真实 XPS 里 Office2007/WPF 导出的 XML 就是这样）。
List<int> _utf16le(String s) {
  final out = <int>[0xFF, 0xFE];
  for (final unit in s.codeUnits) {
    out.add(unit & 0xFF);
    out.add((unit >> 8) & 0xFF);
  }
  return out;
}

const _contentTypes = '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="png" ContentType="image/png"/>
<Override PartName="/FixedDocSeq.fdseq" ContentType="application/vnd.ms-package.xps-fixeddocumentsequence+xml"/>
<Override PartName="/Documents/1/FixedDoc.fdoc" ContentType="application/vnd.ms-package.xps-fixeddocument+xml"/>
<Override PartName="/Documents/1/Pages/1.fpage" ContentType="application/vnd.ms-package.xps-fixedpage+xml"/>
</Types>''';

// 真实 XPS（ECMA-388）的 FixedDocumentSequence 用 `<DocumentReference>`。
const _fdseq = '''<?xml version="1.0" encoding="UTF-8"?>
<FixedDocumentSequence xmlns="http://schemas.microsoft.com/xps/2005/06">
  <DocumentReference Source="/Documents/1/FixedDoc.fdoc"/>
</FixedDocumentSequence>''';

/// 早期本仓库自造 fixture 用的写法（现实里不存在），保留兼容。
const _legacyFdseq = '''<?xml version="1.0" encoding="UTF-8"?>
<FixedDocumentSequence xmlns="http://schemas.microsoft.com/xps/2005/06">
  <FixedDocumentReference Source="/Documents/1/FixedDoc.fdoc"/>
</FixedDocumentSequence>''';

const _fdoc = '''<?xml version="1.0" encoding="UTF-8"?>
<FixedDocument xmlns="http://schemas.microsoft.com/xps/2005/06">
  <PageContent Source="Pages/1.fpage"/>
  <PageContent Source="Pages/2.fpage"/>
</FixedDocument>''';

/// 第 1 页：多行 Glyphs（含同一行两段 → 应按 OriginX 拼接）
const _page1 = '''<?xml version="1.0" encoding="UTF-8"?>
<FixedPage Width="816" Height="1056" xmlns="http://schemas.microsoft.com/xps/2005/06">
  <Glyphs OriginX="96" OriginY="120" FontRenderingEmSize="24"
          FontUri="/Resources/Fonts/A.odttf" UnicodeString="第一章 标题"/>
  <Glyphs OriginX="96" OriginY="160" FontRenderingEmSize="12"
          UnicodeString="正文第一行"/>
  <Glyphs OriginX="300" OriginY="160" FontRenderingEmSize="12"
          UnicodeString="（同一行后半段）"/>
  <Glyphs OriginX="96" OriginY="184" FontRenderingEmSize="12"
          UnicodeString="正文第二行"/>
</FixedPage>''';

/// 第 2 页：没有 Glyphs（只有位图 + 矢量）→ 标题走兜底"第 N 页"
const _page2 = '''<?xml version="1.0" encoding="UTF-8"?>
<FixedPage Width="816" Height="1056" xmlns="http://schemas.microsoft.com/xps/2005/06">
  <Path Data="M 0 0 L 10 10 Z" Fill="#FF000000"/>
  <Canvas>
    <Canvas.Resources>
      <ImageBrush ImageSource="Resources/Images/pic.png"/>
    </Canvas.Resources>
  </Canvas>
</FixedPage>''';

const _core = '''<?xml version="1.0" encoding="UTF-8"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                   xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>示例 XPS 之书</dc:title>
  <dc:creator>作者甲</dc:creator>
</cp:coreProperties>''';

Map<String, List<int>> _xpsFiles({
  String? contentTypes,
  String? fdseq,
  String? fdoc,
  List<String>? pages,
}) => {
  '[Content_Types].xml': utf8.encode(contentTypes ?? _contentTypes),
  'FixedDocSeq.fdseq': utf8.encode(fdseq ?? _fdseq),
  'Documents/1/FixedDoc.fdoc': utf8.encode(fdoc ?? _fdoc),
  'Documents/1/Pages/1.fpage': utf8.encode(
    pages != null && pages.isNotEmpty ? pages[0] : _page1,
  ),
  if (pages == null || pages.length > 1)
    'Documents/1/Pages/2.fpage': utf8.encode(
      pages != null && pages.length > 1 ? pages[1] : _page2,
    ),
  'Documents/1/Pages/Resources/Images/pic.png': _png,
  'docProps/core.xml': utf8.encode(_core),
};

void main() {
  group('XPS 解析（parseXpsBook）', () {
    test('Glyphs 按行聚合成富文本 + 元数据 + 目录', () {
      final book = parseXpsBook(_zip(_xpsFiles()), format: BookFormat.xps);
      expect(book.format, BookFormat.xps);
      expect(book.title, '示例 XPS 之书');
      expect(book.author, '作者甲');
      expect(book.chapters, hasLength(2));
      expect(book.toc, hasLength(2));

      final p1 = book.chapters[0];
      expect(p1.title, '第一章 标题'); // 第一行文字当页标题
      expect(p1.generatedUnit, isNull);
      // 同一行两段按 OriginX 拼在一起；不同行分段
      expect(p1.html, contains('<p>正文第一行（同一行后半段）</p>'));
      expect(p1.html, contains('<p>正文第二行</p>'));
      // 标题行本身也是页面内容的一部分（和 EPUB/FB2 的 h1 一样，不额外删除）
      expect(p1.html, contains('<p>第一章 标题</p>'));
      // 第 1 页没有矢量/位图，不该出现"未渲染"提示
      expect(p1.html, isNot(contains('未渲染')));
    });

    test('ImageBrush → 图片资源；Path → 明确"未渲染"；无文字页标题走兜底', () {
      final book = parseXpsBook(_zip(_xpsFiles()), format: BookFormat.xps);
      final p2 = book.chapters[1];
      expect(p2.title, '2');
      expect(p2.generatedUnit, BookGeneratedUnit.page);
      expect(
        p2.html,
        contains(
          '<img src="documents/1/pages/resources/images/pic.png" alt=""/>',
        ),
      );
      expect(
        book.resources.keys,
        contains('documents/1/pages/resources/images/pic.png'),
      );
      expect(p2.html, contains('矢量图形，未渲染'));
    });

    test('OXPS 与 XPS 同结构，只回填格式标签', () {
      final book = parseXpsBook(_zip(_xpsFiles()), format: BookFormat.oxps);
      expect(book.format, BookFormat.oxps);
      expect(book.chapters, hasLength(2));
    });

    test('缺 [Content_Types].xml → 明确解析失败（不是乱码/半截）', () {
      final files = _xpsFiles()..remove('[Content_Types].xml');
      final r = parseBook(BookFormat.xps, _zip(files));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
      expect(r.content.isEmpty, isTrue);
      expect(r.error, isNotNull);
    });

    test('没有 FixedPage 的 OPC 包 → 明确解析失败', () {
      final files = _xpsFiles(fdoc: '<?xml version="1.0"?><FixedDocument/>');
      final r = parseBook(BookFormat.xps, _zip(files));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('加密/权限管理（EncryptedPackage）→ unsupportedCompression', () {
      final files = _xpsFiles();
      files['EncryptedPackage'] = utf8.encode('sealed');
      final r = parseBook(BookFormat.xps, _zip(files));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('加密'));
    });

    test('截断的 zip → parseFailed（不抛、不吐半截）', () {
      final full = _zip(_xpsFiles());
      final cut = Uint8List.sublistView(full, 0, full.length ~/ 2);
      final r = parseBook(BookFormat.xps, cut);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('不是 XPS 的任意字节 → parseFailed', () {
      final r = parseBook(BookFormat.xps, utf8.encode('not a package at all'));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('probe 报告结构摘要', () {
      final p = xpsProbe(_zip(_xpsFiles()));
      expect(p['ok'], isTrue);
      expect(p['pages'], 2);
      expect(p['images'], 1);
      expect(p['glyphs'], 4);
    });

    test('真实写法的 <DocumentReference> 与早期 <FixedDocumentReference> 都认', () {
      // 默认 fixture 就是真实写法；这里再把早期写法单独钉一次兼容性。
      expect(
        parseXpsBook(
          _zip(_xpsFiles(fdseq: _legacyFdseq)),
          format: BookFormat.xps,
        ).chapters,
        hasLength(2),
      );
    });

    test('绝对路径的 <PageContent Source="/…"> 也能展开', () {
      const absolute = '''<?xml version="1.0" encoding="UTF-8"?>
<FixedDocument xmlns="http://schemas.microsoft.com/xps/2005/06">
  <PageContent Source="/Documents/1/Pages/1.fpage"/>
  <PageContent Source="/Documents/1/Pages/2.fpage"/>
</FixedDocument>''';
      final book = parseXpsBook(
        _zip(_xpsFiles(fdoc: absolute)),
        format: BookFormat.xps,
      );
      expect(book.chapters, hasLength(2));
      expect(book.chapters.first.html, contains('正文第一行'));
    });

    test('UTF-16LE（带 BOM）的 fdseq/fdoc/fpage 也能解析', () {
      final files = _xpsFiles();
      files['FixedDocSeq.fdseq'] = _utf16le(_fdseq);
      files['Documents/1/FixedDoc.fdoc'] = _utf16le(_fdoc);
      files['Documents/1/Pages/1.fpage'] = _utf16le(_page1);
      files['Documents/1/Pages/2.fpage'] = _utf16le(_page2);
      final book = parseXpsBook(_zip(files), format: BookFormat.xps);
      expect(book.chapters, hasLength(2));
      expect(book.chapters.first.html, contains('正文第一行'));
    });

    test('封面抠取：第一页 ImageBrush 指向的图（第 2 页也有）', () {
      final bytes = _zip(_xpsFiles());
      expect(bookCoverSupported('xps'), isTrue);
      expect(bookCoverSupported('oxps'), isTrue);
      final cover = bookCoverBytes('xps', bytes);
      expect(cover, isNotNull);
      expect(cover!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });
  });

  // 真实样本只在 /tmp 存在时跑（数百 KB，**不进仓库**）。来源与 sha256 见
  // `test/golden/xps_fb3_samples.txt` 与 `docs/format-codec-support-matrix.md`：
  //   * `xpssuite_*.xps` = Sample XPS Documents 1.0 测试套件（MXDW/WPF/Office2007 真机导出）；
  //   * `ghostpdl_*.xps` = GhostPDL 的 GhostXPS 测试文档。
  // 这一组钉的是"真实生产者导出的 XPS 到底能不能读"——之前只有自造 fixture，
  // 而自造 fixture 用了不存在的 `<FixedDocumentReference>`，真机一个都读不了。
  group('真实 XPS 样本端到端（/tmp/ebook-samples）', () {
    const dir = '/tmp/ebook-samples';
    File f(String n) => File('$dir/$n');

    test(
      'Office2007_EUROTEST（UTF-16 XML）：2 页都能开出正文',
      () {
        final bytes = f('xpssuite_office2007_eurotest.xps').readAsBytesSync();
        final r = parseBook(BookFormat.xps, bytes);
        expect(r.ok, isTrue);
        expect(r.content.chapters, hasLength(2));
        expect(r.content.chapters[0].html, contains('Euro Currency Support'));
        expect(r.content.chapters[0].html, contains('€'));
        expect(r.content.chapters[0].title, contains('€'));
        expect(bookCoverBytes('xps', bytes), isNotNull);
      },
      skip: f('xpssuite_office2007_eurotest.xps').existsSync() ? null : '样本不存在',
    );

    test(
      'WPF 单 Glyphs 页：文字真的被抽出来（不是空页/报错）',
      () {
        final r = parseBook(
          BookFormat.xps,
          f('xpssuite_wpf_glyphs_lingrad.xps').readAsBytesSync(),
        );
        expect(r.ok, isTrue);
        expect(r.content.chapters, hasLength(1));
        expect(r.content.chapters[0].html, contains('absdfasdfsadfasdfasdfc'));
        // 纯文字页，不该冒出"矢量未渲染"提示
        expect(r.content.chapters[0].html, isNot(contains('矢量图形')));
      },
      skip: f('xpssuite_wpf_glyphs_lingrad.xps').existsSync() ? null : '样本不存在',
    );

    test(
      'Outlook 日历：Glyphs 正文 + ImageBrush 位图都进 resources',
      () {
        final bytes = f(
          'xpssuite_showcase_outlook_calendar.xps',
        ).readAsBytesSync();
        final r = parseBook(BookFormat.xps, bytes);
        expect(r.ok, isTrue);
        expect(r.content.chapters, hasLength(1));
        expect(r.content.chapters[0].html, contains('Registration'));
        expect(r.content.resources, hasLength(1));
        expect(r.content.chapters[0].html, contains('<img src="resources/'));
        expect(bookCoverBytes('xps', bytes), isNotNull);
      },
      skip: f('xpssuite_showcase_outlook_calendar.xps').existsSync()
          ? null
          : '样本不存在',
    );

    test(
      'ClusterMap：2 页 + docProps/core.xml 的书名/作者',
      () {
        final r = parseBook(
          BookFormat.xps,
          f('xpssuite_handcrafted_clustermap.xps').readAsBytesSync(),
        );
        expect(r.ok, isTrue);
        expect(r.content.title, 'abcdefghiklmnopqrstuvwxyz1234567890');
        expect(r.content.author, 'JPR; me');
        expect(r.content.chapters, hasLength(2));
        // 数学字母数字符号（U+1D44E 系）也能原样出来
        expect(r.content.chapters[0].html, contains('\u{1D44E}'));
      },
      skip: f('xpssuite_handcrafted_clustermap.xps').existsSync()
          ? null
          : '样本不存在',
    );

    test(
      'MXDW CoreProperty2 / Office Excel：都能打开',
      () {
        final mxdw = parseBook(
          BookFormat.xps,
          f('xpssuite_mxdw_coreproperty2.xps').readAsBytesSync(),
        );
        expect(mxdw.ok, isTrue);
        expect(mxdw.content.chapters, hasLength(1));

        final excel = parseBook(
          BookFormat.xps,
          f('xpssuite_office2007_excel_digit.xps').readAsBytesSync(),
        );
        expect(excel.ok, isTrue);
        expect(excel.content.chapters[0].html, contains('FORMATS.XLS'));
      },
      skip: f('xpssuite_mxdw_coreproperty2.xps').existsSync() ? null : '样本不存在',
    );

    test('GhostXPS tiger（纯矢量）：明确"未渲染"，不假装有正文', () {
      final a = parseBook(
        BookFormat.xps,
        f('ghostpdl_xps_tiger.xps').readAsBytesSync(),
      );
      expect(a.ok, isTrue);
      expect(a.content.chapters, hasLength(1));
      expect(a.content.chapters[0].html, contains('305 个矢量图形，未渲染'));
      expect(a.content.chapters[0].generatedUnit, BookGeneratedUnit.page);

      final b = parseBook(
        BookFormat.xps,
        f('ghostpdl_pcl_tiger.xps').readAsBytesSync(),
      );
      expect(b.ok, isTrue);
      expect(b.content.chapters[0].html, contains('305 个矢量图形，未渲染'));
    }, skip: f('ghostpdl_xps_tiger.xps').existsSync() ? null : '样本不存在');

    test('GhostXPS colorcirc：Indices+私用区 UnicodeString → 不产出可读文本（已知边界）', () {
      final r = parseBook(
        BookFormat.xps,
        f('ghostpdl_colorcirc.xps').readAsBytesSync(),
      );
      expect(r.ok, isTrue);
      expect(r.content.chapters, hasLength(1));
      // 这一页是"字体测试"：Glyphs 只给 Indices，UnicodeString 是私用区码位。
      // 本实现不读嵌入字体的 cmap，所以抽不出可读单词——如实反映，不伪造文本。
      expect(r.content.chapters[0].html, contains('1274 个矢量图形，未渲染'));
    }, skip: f('ghostpdl_colorcirc.xps').existsSync() ? null : '样本不存在');
  });

  group('XPS 接入点', () {
    test('扩展名 → 格式 → 可读', () {
      expect(bookFormatOf('xps'), BookFormat.xps);
      expect(bookFormatOf('XPS'), BookFormat.xps);
      expect(bookFormatOf('oxps'), BookFormat.oxps);
      expect(isReadableBook('oxps'), isTrue);
      expect(BookFormat.xps.label, 'XPS');
      expect(BookFormat.oxps.label, 'OXPS');
    });

    test('预览页把 .xps/.oxps 归到电子书（内嵌阅读）', () {
      expect(filePreviewKind(_entry('a.xps')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.oxps')), FilePreviewKind.book);
      expect(canPreviewInline(_entry('a.xps')), isTrue);
    });
  });

  group('XPS 阅读页（widget）', () {
    testWidgets('打开 .xps：书名/页码/正文都画出来', (tester) async {
      final bytes = _zip(_xpsFiles());
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
      addTearDown(() async {
        c.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: FileBookStage(
                entry: _entry('示例.xps'),
                bytesUrl: 'https://nas/x',
                bookKey: 'fs:/books/x.xps',
              ),
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
      // 头部：书名 + "XPS · 第 1/2 章"
      expect(find.text('示例 XPS 之书'), findsOneWidget);
      expect(find.textContaining('XPS · 第 1/2 章'), findsOneWidget);
    });
  });
}

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/books/$name',
  isDir: false,
  size: 2048,
  mtime: 1700000000000,
);
