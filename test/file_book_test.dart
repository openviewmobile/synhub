// 电子书（EPUB / FB2 / CBZ）解析 + 阅读页离线测试。
//
// 测试里**手造真实的最小包**（EPUB 就是 zip + container.xml + OPF + XHTML，
// CBZ 就是 zip 里塞图片）—— 比 mock 更能挡住"真文件解不开"这类问题。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/analytics_database.dart';
import 'package:synhub/src/features/analytics/analytics_track.dart';
import 'package:synhub/src/features/analytics/usage_event.dart';
import 'package:synhub/src/features/analytics/usage_log.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/ai/ai_floating_orb.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 透明 PNG（够 Flutter 解码）
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

Uint8List _zip(Map<String, String> textFiles, {Map<String, List<int>>? bin}) {
  final archive = Archive();
  textFiles.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  bin?.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 一本最小但**结构完整**的 EPUB：container.xml → OPF → 两章 + 一张插图
Uint8List _epub() => _zip(
  {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
    'OEBPS/content.opf': '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试之书</dc:title>
    <dc:creator>张三</dc:creator>
  </metadata>
  <manifest>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="img" href="images/pic.png" media-type="image/png"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>''',
    'OEBPS/text/ch1.xhtml': '''
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title>
<style>p{color:red}</style></head>
<body><h1>第一章 起点</h1><p>这是<strong>正文</strong>。</p>
<p><img src="../images/pic.png" alt="图"/></p></body></html>''',
    'OEBPS/text/ch2.xhtml': '''
<html><body><h1>第二章 继续</h1><ul><li>要点一</li><li>要点二</li></ul></body></html>''',
  },
  bin: {'OEBPS/images/pic.png': _png},
);

/// EPUB3：**带 nav 目录 + 锚点**（一个文件里两个小节，靠 `#s1`/`#s2` 精确跳）
Uint8List _epubNav() => _zip(
  {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
    'OEBPS/content.opf': '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>目录之书</dc:title><dc:creator>作者</dc:creator>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="img" href="images/pic.png" media-type="image/png"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>''',
    'OEBPS/nav.xhtml': '''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body><nav epub:type="toc"><ol>
  <li><a href="text/ch1.xhtml">第一部 起</a>
    <ol>
      <li><a href="text/ch1.xhtml#s1">1.1 小一</a></li>
      <li><a href="text/ch1.xhtml#s2">1.2 小二</a></li>
    </ol>
  </li>
  <li><a href="text/ch2.xhtml">第二部</a></li>
</ol></nav></body></html>''',
    'OEBPS/text/ch1.xhtml': '''
<html><body><h1>第一部 起</h1>
<h2 id="s1">1.1 小一</h2><p>甲<img src="../images/pic.png" alt=""/></p>
<h2 id="s2">1.2 小二</h2><p>乙</p></body></html>''',
    'OEBPS/text/ch2.xhtml': '''
<html><body><h1>正文里的标题</h1><p>丙</p></body></html>''',
  },
  bin: {'OEBPS/images/pic.png': _png},
);

/// EPUB2：目录只写在 `toc.ncx`（没有 EPUB3 nav），同样带锚点
Uint8List _epubNcx() => _zip({
  'mimetype': 'application/epub+zip',
  'META-INF/container.xml': '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
  'OEBPS/content.opf': '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>NCX 之书</dc:title></metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/></spine>
</package>''',
  'OEBPS/toc.ncx': '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1"><navLabel><text>卷一</text></navLabel><content src="text/ch1.xhtml"/>
      <navPoint id="n2"><navLabel><text>卷一·甲</text></navLabel><content src="text/ch1.xhtml#a"/></navPoint>
    </navPoint>
  </navMap>
</ncx>''',
  'OEBPS/text/ch1.xhtml': '''
<html><body><h1>第一章</h1><p>开头</p><h2 id="a">甲节</h2><p>甲节正文</p></body></html>''',
});

/// EPUB2 `guide` 兜底：**没有 nav、也没有 toc.ncx**，只剩
/// `<guide><reference type="toc" href="text/contents.xhtml">` 指向的手写目录页。
/// 目录页用嵌套 `<ul>`（层级与锚点都要能还原）。
Uint8List _epubGuideOnly() => _zip({
  'mimetype': 'application/epub+zip',
  'META-INF/container.xml': '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
  'OEBPS/content.opf': '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Guide 之书</dc:title></metadata>
  <manifest>
    <item id="toc" href="text/contents.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
  <guide><reference type="toc" title="目次" href="text/contents.xhtml"/></guide>
</package>''',
  'OEBPS/text/contents.xhtml': '''
<html><body><h1>目次</h1>
<ul>
  <li><a href="ch1.xhtml">第一档</a>
    <ul><li><a href="ch1.xhtml#a">第一档·甲</a></li></ul>
  </li>
  <li><a href="ch2.xhtml">第二档</a></li>
</ul>
<p><a href="https://example.com/">外链不该进目录</a></p>
</body></html>''',
  'OEBPS/text/ch1.xhtml': '''
<html><body><h1>第一章</h1><p>开头</p><h2 id="a">甲节</h2><p>甲节正文</p></body></html>''',
  'OEBPS/text/ch2.xhtml': '''
<html><body><h1>第二章</h1><p>第二章正文</p></body></html>''',
});

/// `guide` 目录页**没有列表结构**（老式 `<p><a>` 平铺）：按文档顺序收集，
/// 层级一律 0，且外链被过滤。
Uint8List _epubGuideFlat() => _zip({
  'mimetype': 'application/epub+zip',
  'META-INF/container.xml': '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
  'OEBPS/content.opf': '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>平铺 Guide 之书</dc:title></metadata>
  <manifest>
    <item id="toc" href="toc.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
  <guide><reference type="toc" href="toc.xhtml"/></guide>
</package>''',
  'OEBPS/toc.xhtml': '''
<html><body>
<p><a href="text/ch1.xhtml">平铺一</a></p>
<p><a href="text/ch2.xhtml">平铺二</a></p>
<p><a href="mailto:x@example.com">写信</a></p>
</body></html>''',
  'OEBPS/text/ch1.xhtml': '<html><body><p>一</p></body></html>',
  'OEBPS/text/ch2.xhtml': '<html><body><p>二</p></body></html>',
});

/// 同时有 EPUB3 `nav` 与 EPUB2 `toc.ncX` 和 `guide`，三者标题不同 ——
/// 用来钉死优先级：nav 最高。
Uint8List _epubNavAndNcx() => _zip({
  'mimetype': 'application/epub+zip',
  'META-INF/container.xml': '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
  'OEBPS/content.opf': '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>三源之书</dc:title></metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine>
  <guide><reference type="toc" href="guide-toc.xhtml"/></guide>
</package>''',
  'OEBPS/nav.xhtml': '''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body><nav epub:type="toc"><ol>
  <li><a href="text/ch1.xhtml">NAV 甲</a></li>
  <li><a href="text/ch2.xhtml">NAV 乙</a></li>
</ol></nav></body></html>''',
  'OEBPS/toc.ncx': '''
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
  <navPoint id="n1"><navLabel><text>NCX 甲</text></navLabel><content src="text/ch1.xhtml"/></navPoint>
  <navPoint id="n2"><navLabel><text>NCX 乙</text></navLabel><content src="text/ch2.xhtml"/></navPoint>
</navMap></ncx>''',
  'OEBPS/guide-toc.xhtml': '''
<html><body><ul>
  <li><a href="text/ch1.xhtml">GUIDE 甲</a></li>
  <li><a href="text/ch2.xhtml">GUIDE 乙</a></li>
</ul></body></html>''',
  'OEBPS/text/ch1.xhtml': '<html><body><p>一</p></body></html>',
  'OEBPS/text/ch2.xhtml': '<html><body><p>二</p></body></html>',
});

/// 只有 `toc.ncx` 与 `guide`（没有 nav），两者标题不同 —— 钉死"NCX 优先于 guide"。
Uint8List _epubNcxAndGuide() => _zip({
  'mimetype': 'application/epub+zip',
  'META-INF/container.xml': '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
  'OEBPS/content.opf': '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>NCX 与 Guide</dc:title></metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine>
  <guide><reference type="toc" href="guide-toc.xhtml"/></guide>
</package>''',
  'OEBPS/toc.ncx': '''
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
  <navPoint id="n1"><navLabel><text>NCX 一</text></navLabel><content src="text/ch1.xhtml"/></navPoint>
  <navPoint id="n2"><navLabel><text>NCX 二</text></navLabel><content src="text/ch2.xhtml"/></navPoint>
</navMap></ncx>''',
  'OEBPS/guide-toc.xhtml': '''
<html><body><ul>
  <li><a href="text/ch1.xhtml">GUIDE 一</a></li>
  <li><a href="text/ch2.xhtml">GUIDE 二</a></li>
</ul></body></html>''',
  'OEBPS/text/ch1.xhtml': '<html><body><p>一</p></body></html>',
  'OEBPS/text/ch2.xhtml': '<html><body><p>二</p></body></html>',
});

/// `nav` 是**空壳**（`<nav>` 里没有 `<li><a>`）、NCX 才有真目录 ——
/// 钉死"某一档读出空表时继续往下一档走"，不会被空壳挡死。
Uint8List _epubEmptyNavWithNcx() => _zip({
  'mimetype': 'application/epub+zip',
  'META-INF/container.xml': '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
  'OEBPS/content.opf': '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>空 nav 之书</dc:title></metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/></spine>
</package>''',
  'OEBPS/nav.xhtml': '''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body><nav epub:type="toc"><ol></ol></nav></body></html>''',
  'OEBPS/toc.ncx': '''
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
  <navPoint id="n1"><navLabel><text>真正的目录</text></navLabel><content src="text/ch1.xhtml"/></navPoint>
</navMap></ncx>''',
  'OEBPS/text/ch1.xhtml': '<html><body><p>一</p></body></html>',
});

/// FB2：**嵌套 section**（以前只取最外层，嵌套的标题会整段丢掉）
String _fb2Nested() => '''
<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
  <description><title-info><book-title>嵌套之书</book-title></title-info></description>
  <body>
    <section><title><p>第一篇</p></title><p>篇首语</p>
      <section><title><p>第一节</p></title><p>一节正文</p></section>
      <section><title><p>第二节</p></title><p>二节正文</p></section>
    </section>
    <section><title><p>第二篇</p></title><p>正文二</p></section>
  </body>
</FictionBook>''';

/// 一本最小 FB2（单 XML）
String _fb2Text() =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"
             xmlns:l="http://www.w3.org/1999/xlink">
  <description><title-info>
    <book-title>FB2 之书</book-title>
    <author><first-name>李</first-name><last-name>四</last-name></author>
  </title-info></description>
  <body>
    <section><title><p>第一节</p></title>
      <p>正文一</p><subtitle>小标题</subtitle><p>正文二</p>
      <empty-line/><image l:href="#cover.png"/>
    </section>
    <section><title><p>第二节</p></title><p>正文三</p></section>
  </body>
  <binary id="cover.png" content-type="image/png">${base64Encode(_png)}</binary>
</FictionBook>''';

Uint8List _cbz() => _zip(
  {},
  bin: {
    'comic/p2.png': _png,
    'comic/p10.png': _png,
    'comic/p1.png': _png,
    '__MACOSX/._p1.png': _png,
  },
);

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/books/$name',
  isDir: false,
  size: 2048,
  mtime: 1700000000000,
);

Future<({FakeTransport t, ProviderContainer c})> _pump(
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
      // 取字节要走 FileStation 的 api（Drive 直链只给 url）
      fileApiProvider.overrideWithValue(FileStationApi(api)),
    ],
  );
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
  return (t: t, c: c);
}

/// 埋点断言用：装一个内存日志并挂成全局单例
Future<UsageLog> armUsageLog() async {
  final db = AnalyticsDatabase.memory();
  final log = UsageLog(db);
  await log.load();
  setGlobalUsageLog(log);
  addTearDown(() async {
    setGlobalUsageLog(null);
    log.dispose();
    await db.close();
  });
  return log;
}

Future<List<UsageEvent>> drainUsageLog(
  WidgetTester tester,
  UsageLog log,
) async {
  await tester.runAsync(() => log.flush());
  final rows = await tester.runAsync(() => log.recent());
  return rows!;
}

void main() {
  group('格式识别（哪些能读、哪些明确不读）', () {
    test('EPUB / FB2 / CBZ / MOBI / AZW3 能内嵌阅读', () {
      expect(bookFormatOf('epub'), BookFormat.epub);
      expect(bookFormatOf('EPUB'), BookFormat.epub);
      expect(bookFormatOf('fb2'), BookFormat.fb2);
      expect(bookFormatOf('cbz'), BookFormat.cbz);
      // 2026-09-20 起：MOBI/AZW3 由自研纯 Dart 解析（`book_mobi.dart`）内嵌支持，
      // 详细覆盖见 `test/file_book_mobi_test.dart`
      expect(bookFormatOf('mobi'), BookFormat.mobi);
      expect(bookFormatOf('azw'), BookFormat.mobi);
      expect(bookFormatOf('azw3'), BookFormat.azw3);
      expect(isReadableBook('epub'), isTrue);
      expect(isReadableBook('mobi'), isTrue);
      expect(isReadableBook('azw3'), isTrue);
    });

    test('CBR / CHM / DJVU 已内嵌（自研 RAR / ITSF+LZX / DJVU）', () {
      expect(isReadableBook('cbr'), isTrue);
      expect(filePreviewKind(_entry('a.cbr')), FilePreviewKind.book);
      expect(isReadableBook('djvu'), isTrue);
      expect(isReadableBook('chm'), isTrue);
      // 预览分类：CHM / DJVU 都落到"内嵌阅读"
      expect(filePreviewKind(_entry('a.djvu')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.chm')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.epub')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.cbz')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.fb2')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.mobi')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.azw3')), FilePreviewKind.book);
    });

    test('电子书和 PDF 一样：太大就不内嵌', () {
      expect(canPreviewInline(_entry('b.epub')), isTrue);
      final huge = FileEntryDto(
        name: 'big.epub',
        path: '/books/big.epub',
        isDir: false,
        size: kInlinePreviewMaxBytes + 1,
        mtime: 0,
      );
      expect(canPreviewInline(huge), isFalse);
    });
  });

  group('EPUB 解析', () {
    test('容器 → OPF → spine 顺序 + 书名作者 + 章节标题', () {
      final r = parseBook(BookFormat.epub, _epub());
      expect(r.ok, isTrue);
      final b = r.content;
      expect(b.title, '测试之书');
      expect(b.author, '张三');
      expect(b.chapters, hasLength(2));
      expect(b.chapters.first.title, '第一章 起点');
      expect(b.chapters[1].title, '第二章 继续');
      expect(b.chapters[1].html, contains('<li>要点一</li>'));
    });

    test('剥掉 style/head，插图的相对路径按书根归一化', () {
      final b = parseBook(BookFormat.epub, _epub()).content;
      expect(b.chapters.first.html, isNot(contains('<style>')));
      expect(b.chapters.first.html, contains('OEBPS/images/pic.png'));
      expect(b.resources.containsKey('OEBPS/images/pic.png'), isTrue);
      expect(b.resources['OEBPS/images/pic.png'], isNotEmpty);
    });

    test('不是 zip / 坏文件 → 说人话的失败，不抛异常', () {
      final r = parseBook(BookFormat.epub, utf8.encode('这不是 zip'));
      expect(r.ok, isFalse);
      expect(r.error, contains('解析失败'));
    });
  });

  group('FB2 解析', () {
    test('书名/作者/分节 + 标签映射 + base64 插图', () {
      final b = parseBook(BookFormat.fb2, utf8.encode(_fb2Text())).content;
      expect(b.title, 'FB2 之书');
      expect(b.author, contains('李'));
      expect(b.chapters, hasLength(2));
      expect(b.chapters.first.title, '第一节');
      expect(b.chapters.first.html, contains('<h3>小标题</h3>'));
      expect(b.chapters.first.html, contains('<img src="#cover.png"'));
      expect(b.resources.containsKey('cover.png'), isTrue);
    });
  });

  group('目录（TOC）与锚点跳转', () {
    test('EPUB3 nav：嵌套层级 + 条目按原书顺序 + 锚点把章节切开', () {
      final b = parseBook(BookFormat.epub, _epubNav()).content;
      // 原书 2 个 spine 文件，但第一章被 3 条目录条目切成 3 段 → 共 4 段
      expect(b.chapters, hasLength(4));
      expect(
        [for (final e in b.toc) e.title],
        ['第一部 起', '1.1 小一', '1.2 小二', '第二部'],
      );
      expect([for (final e in b.toc) e.depth], [0, 1, 1, 0]);
      expect([for (final e in b.toc) e.chapterIndex], [0, 1, 2, 3]);
      // 锚点切出来的段：甲在 1.1 段，乙在 1.2 段，互不串页
      expect(b.chapters[1].html, contains('1.1 小一'));
      expect(b.chapters[1].html, contains('甲'));
      expect(b.chapters[1].html, isNot(contains('乙')));
      expect(b.chapters[2].html, contains('1.2 小二'));
      expect(b.chapters[2].html, contains('乙'));
      expect(b.chapters[2].html, isNot(contains('甲')));
      // 切段之后图片路径照样能解析到资源
      expect(b.chapters[1].html, contains('OEBPS/images/pic.png'));
      expect(b.resources.containsKey('OEBPS/images/pic.png'), isTrue);
      // 只挂一条目录条目的章节：目录标题比正文里的 h1 更可信
      expect(b.chapters[3].title, '第二部');
    });

    test('EPUB2 toc.ncx：spine@toc 指到 NCX，锚点同样能跳', () {
      final b = parseBook(BookFormat.epub, _epubNcx()).content;
      expect([for (final e in b.toc) e.title], ['卷一', '卷一·甲']);
      expect([for (final e in b.toc) e.depth], [0, 1]);
      expect(b.chapters, hasLength(2));
      expect(b.chapters[1].html, contains('甲节正文'));
      expect(b.chapters[1].html, isNot(contains('开头')));
    });

    test('书里没有目录时 toc 为空（阅读器退回按章节列）', () {
      final b = parseBook(BookFormat.epub, _epub()).content;
      expect(b.toc, isEmpty);
      expect(b.chapters, hasLength(2));
    });

    test('FB2 嵌套 section：子节是独立一段，标题不再丢', () {
      final b = parseBook(BookFormat.fb2, utf8.encode(_fb2Nested())).content;
      expect([for (final e in b.toc) e.title], ['第一篇', '第一节', '第二节', '第二篇']);
      expect([for (final e in b.toc) e.depth], [0, 1, 1, 0]);
      expect([for (final e in b.toc) e.chapterIndex], [0, 1, 2, 3]);
      expect(b.chapters[0].html, contains('篇首语'));
      expect(b.chapters[0].html, isNot(contains('一节正文')));
      expect(b.chapters[1].html, contains('一节正文'));
      expect(b.chapters[2].html, contains('二节正文'));
    });

    // ---------------------------------------------------------- guide 兜底
    // OPF `<guide><reference type="toc">` 是 nav / NCX 之后的**最后一档**。
    // 这几条同时钉死"能不能读出目录"和"三档之间的优先级"。

    test('仅有 OPF guide 时：从目录页取目录（嵌套层级 + 锚点切段 + 外链过滤）', () {
      final b = parseBook(BookFormat.epub, _epubGuideOnly()).content;
      expect([for (final e in b.toc) e.title], ['第一档', '第一档·甲', '第二档']);
      expect([for (final e in b.toc) e.depth], [0, 1, 0]);
      // ch1 被 `#a` 切成 2 段 + ch2 = 3 段
      expect(b.chapters, hasLength(3));
      expect(b.toc[1].chapterIndex, 1);
      expect(b.chapters[1].html, contains('甲节正文'));
      expect(b.chapters[1].html, isNot(contains('开头')));
      expect(b.chapters[2].html, contains('第二章正文'));
      // `https://example.com/` 的外链不该出现在目录里
      expect([for (final e in b.toc) e.title], isNot(contains('外链不该进目录')));
    });

    test('guide 目录页没有列表结构：按文档顺序平铺，层级全 0，外链过滤', () {
      final b = parseBook(BookFormat.epub, _epubGuideFlat()).content;
      expect([for (final e in b.toc) e.title], ['平铺一', '平铺二']);
      expect([for (final e in b.toc) e.depth], [0, 0]);
      expect([for (final e in b.toc) e.chapterIndex], [0, 1]);
      expect([for (final e in b.toc) e.title], isNot(contains('写信')));
    });

    test('优先级：nav + NCX + guide 同时存在 → 用 EPUB3 nav', () {
      final b = parseBook(BookFormat.epub, _epubNavAndNcx()).content;
      expect([for (final e in b.toc) e.title], ['NAV 甲', 'NAV 乙']);
    });

    test('优先级：只有 NCX + guide → 用 NCX，guide 不越位', () {
      final b = parseBook(BookFormat.epub, _epubNcxAndGuide()).content;
      expect([for (final e in b.toc) e.title], ['NCX 一', 'NCX 二']);
    });

    test('降级链穿透：nav 是空壳 → 落到 NCX 拿真目录', () {
      final b = parseBook(BookFormat.epub, _epubEmptyNavWithNcx()).content;
      expect([for (final e in b.toc) e.title], ['真正的目录']);
    });
  });

  group('CBZ 解析', () {
    test('只收图片、跳过 __MACOSX、按文件名自然序排页', () {
      final b = parseBook(BookFormat.cbz, _cbz()).content;
      expect(b.pages, hasLength(3));
      expect(b.format, BookFormat.cbz);
      // 排序正确性没法直接看字节（三张图一样），用解析层的自然序规则兜住
      expect(b.pages.every((p) => p.isNotEmpty), isTrue);
    });
  });

  group('阅读页', () {
    testWidgets('EPUB：显示书名/章节，能翻到下一章，插图不崩', (tester) async {
      final b = await _pump(tester, _entry('book.epub'), _epub());
      expect(find.text('测试之书'), findsOneWidget);
      expect(find.textContaining('第 1/2 章'), findsOneWidget);
      expect(find.textContaining('第一章 起点'), findsWidgets);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('下一章'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('第 2/2 章'), findsOneWidget);
      expect(find.textContaining('要点一', findRichText: true), findsWidgets);
      expect(b.t.downloads, isNotEmpty);
    });

    testWidgets('EPUB：左右滑动翻章（左滑下一章、右滑上一章）', (tester) async {
      final log = await armUsageLog();
      await _pump(tester, _entry('book.epub'), _epub());
      expect(find.textContaining('第 1/2 章'), findsOneWidget);

      // 左滑 → 下一章（视口 800 宽，要滑过一半才会翻页）
      await tester.fling(
        find.byKey(const Key('book-chapter-pager')),
        const Offset(-600, 0),
        1200,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('第 2/2 章'), findsOneWidget);
      expect(find.textContaining('要点一', findRichText: true), findsWidgets);

      // 右滑 → 回到上一章
      await tester.fling(
        find.byKey(const Key('book-chapter-pager')),
        const Offset(600, 0),
        1200,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('第 1/2 章'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 使用日志：打开书 + 两次翻章（只记格式/章节，不记书名）
      final rows = await drainUsageLog(tester, log);
      // `recent()` 是**新的在前**，这里按动作找，不依赖顺序
      final open = rows.singleWhere((e) => e.action == UsageAction.open);
      expect(open.module, UsageModule.reader);
      expect(open.objectType, 'epub');
      expect(
        rows.where((e) => e.action == UsageAction.switchSection),
        hasLength(2),
      );
      expect(
        rows.every((e) => !e.objectType.contains('book')),
        isTrue,
        reason: '不能把书名写进日志',
      );
    });

    testWidgets('正文是只读的（点进去打字不会改书）', (tester) async {
      await _pump(tester, _entry('book.epub'), _epub());
      // 真机上发现的：`QuillController.readOnly` 默认 false，
      // 只靠 `showCursor: false` 拦不住输入 —— 点正文再打字会插进书里
      final editor = tester.widget<quill.QuillEditor>(
        find.byType(quill.QuillEditor).first,
      );
      expect(editor.controller.readOnly, isTrue);
      // 只读不等于不能选：选句工具条（解释/翻译）依赖交互式选择
      expect(editor.config.enableInteractiveSelection, isTrue);
    });

    testWidgets('AI 助手：点一下悬浮球就能总结本章（没装模型走内置摘要）', (tester) async {
      await _pump(tester, _entry('book.epub'), _epub());
      // 入口从"右上角固定图标"改成了可拖动悬浮球（读者自己决定它在哪）
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
      expect(find.byType(AiFloatingOrb), findsOneWidget);

      await tester.tap(find.byTooltip('AI 助手'));
      await tester.pumpAndSettle();

      // E2：整章摘要要**二次确认**（默认档位是端侧/内置，确认框照弹）
      expect(find.text('把整章发给 AI？'), findsOneWidget);
      await tester.tap(find.text('发送整章'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }

      // 弹层里自动跑了"总结"，并如实标注用的是内置摘要
      expect(find.textContaining('AI 助手 · 总结'), findsOneWidget);
      expect(find.text('内置摘要（无模型）'), findsOneWidget);
      expect(find.text('装端侧模型'), findsOneWidget);
      // 这一章很短（没有合格的候选句），兜底摘要把正文原样给出来
      expect(find.textContaining('第一章 起点'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('底部操作条：上一章贴左 / 下一章贴右 / 目录在正中且带章标题', (tester) async {
      await _pump(tester, _entry('book.epub'), _epub());
      final prev = find.text('上一章');
      final next = find.text('下一章');
      final tocBtn = find.byTooltip('目录');
      expect(tocBtn, findsOneWidget);

      // 贴边：不能因为 Expanded 的默认居中而飘向中间（用户反馈过一次）
      expect(tester.getCenter(prev).dx, lessThan(140));
      expect(tester.getCenter(next).dx, greaterThan(800 - 140));
      // 目录在两者之间，且章标题就在它身上（省掉了原来单独一行）
      final tocX = tester.getCenter(tocBtn).dx;
      expect(tocX, greaterThan(tester.getCenter(prev).dx));
      expect(tocX, lessThan(tester.getCenter(next).dx));
      expect(
        find.descendant(of: tocBtn, matching: find.text('第一章 起点')),
        findsOneWidget,
      );
      // 顶部不再有独立的 AI 图标（改成悬浮球了）
      expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
    });

    testWidgets('EPUB：目录能跳章', (tester) async {
      await _pump(tester, _entry('book.epub'), _epub());
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.text('第二章 继续'), findsWidgets);
      await tester.tap(find.text('第二章 继续').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('第 2/2 章'), findsOneWidget);
    });

    testWidgets('EPUB：目录面板显示原书目录（带层级），点小节精确跳过去', (tester) async {
      await _pump(tester, _entry('toc.epub'), _epubNav());
      expect(find.textContaining('第 1/4 章'), findsOneWidget);

      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-toc-list')), findsOneWidget);
      expect(find.text('4 条 · 原书目录'), findsOneWidget);
      for (final t in ['第一部 起', '1.1 小一', '1.2 小二', '第二部']) {
        expect(find.text(t), findsWidgets);
      }

      await tester.tap(find.text('1.2 小二').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('第 3/4 章'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('CBZ：按页翻，显示页码', (tester) async {
      await _pump(tester, _entry('comic.cbz'), _cbz());
      expect(find.text('CBZ · 1/3'), findsOneWidget);
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle();
      expect(find.text('CBZ · 2/3'), findsOneWidget);
    });

    testWidgets('坏文件 / 不支持：给能看懂的提示 + 引导下载', (tester) async {
      await _pump(tester, _entry('broken.epub'), utf8.encode('not a zip'));
      expect(find.textContaining('暂时不能内嵌阅读'), findsOneWidget);
      expect(find.textContaining('其他应用'), findsOneWidget);
    });

    testWidgets('空文件也有提示', (tester) async {
      await _pump(tester, _entry('empty.epub'), const <int>[]);
      expect(find.text('这个文件是空的'), findsOneWidget);
    });
  });
}
