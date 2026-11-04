// 本批新增格式的**接入层**测试：扩展名映射、预览分流、PalmDOC/PRC、FBZ、
// CBT/CB7，以及阅读页真的能把它们渲染出来（页面层）。
//
// fixture 全部代码现造（PalmDB 记录、tar、zip、7z 头），不下载真实电子书。
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
import 'package:synhub/src/features/files/book_comic.dart';
import 'package:synhub/src/features/files/book_cover.dart';
import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

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

Uint8List _tar(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return TarEncoder().encodeBytes(archive);
}

// ---------------------------------------------------------------- PalmDOC fixture

Uint8List _palmDb(List<Uint8List> records, String name) {
  final header = Uint8List(78);
  final nm = utf8.encode(name);
  for (var i = 0; i < nm.length && i < 31; i++) {
    header[i] = nm[i];
  }
  header[76] = (records.length >> 8) & 0xFF;
  header[77] = records.length & 0xFF;
  final table = Uint8List(records.length * 8);
  var offset = 78 + records.length * 8;
  for (var i = 0; i < records.length; i++) {
    table[i * 8] = (offset >> 24) & 0xFF;
    table[i * 8 + 1] = (offset >> 16) & 0xFF;
    table[i * 8 + 2] = (offset >> 8) & 0xFF;
    table[i * 8 + 3] = offset & 0xFF;
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

Uint8List palmDoc(
  String text, {
  String name = 'PalmDOC',
  int compression = 1,
  int encryption = 0,
  bool mobiHeader = false,
  int recordSize = 4096,
}) {
  final bytes = utf8.encode(text);
  final records = <Uint8List>[];
  for (var i = 0; i < bytes.length; i += recordSize) {
    records.add(
      Uint8List.fromList(
        bytes.sublist(i, (i + recordSize).clamp(0, bytes.length)),
      ),
    );
  }
  if (records.isEmpty) records.add(Uint8List(0));

  final head = Uint8List(16 + (mobiHeader ? 232 : 0));
  void u16(int o, int v) {
    head[o] = (v >> 8) & 0xFF;
    head[o + 1] = v & 0xFF;
  }

  void u32(int o, int v) {
    head[o] = (v >> 24) & 0xFF;
    head[o + 1] = (v >> 16) & 0xFF;
    head[o + 2] = (v >> 8) & 0xFF;
    head[o + 3] = v & 0xFF;
  }

  u16(0, compression);
  u32(4, bytes.length);
  u16(8, records.length);
  u16(10, recordSize);
  u16(12, encryption);
  if (mobiHeader) {
    for (var i = 0; i < 4; i++) {
      head[16 + i] = 'MOBI'.codeUnitAt(i);
    }
    u32(20, 232);
    u32(28, 65001);
    u32(36, 6);
  }
  return _palmDb([head, ...records], name);
}

const _zh = '第一章 起点\n\n正文甲。\n\n第二章 收尾\n\n正文乙。';

// ---------------------------------------------------------------- 阅读页 pump

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/books/$name',
  isDir: false,
  size: 4096,
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

void main() {
  // ---------------------------------------------------------------- 映射

  group('扩展名 → 格式枚举（bookFormatOf）', () {
    test('本批新增的每一种都认，且落到"可内嵌阅读"', () {
      const map = {
        'txt': BookFormat.txt,
        'TXT': BookFormat.txt,
        'md': BookFormat.md,
        'markdown': BookFormat.md,
        'html': BookFormat.html,
        'htm': BookFormat.html,
        'xhtml': BookFormat.html,
        'rtf': BookFormat.rtf,
        'tcr': BookFormat.tcr,
        'docx': BookFormat.docx,
        'odt': BookFormat.odt,
        'pdb': BookFormat.pdb,
        'prc': BookFormat.prc,
        'fbz': BookFormat.fbz,
        'cbt': BookFormat.cbt,
        'cb7': BookFormat.cb7,
        'opf': BookFormat.opf,
      };
      map.forEach((ext, format) {
        expect(bookFormatOf(ext), format, reason: ext);
        expect(isReadableBook(ext), isTrue, reason: ext);
      });
    });

    test('明确不做的格式仍然是"不可内嵌"', () {
      // 注：CBR / CHM / DJVU 已由**自研纯 Dart**接手（自研 RAR / 自研
      // ITSF+LZX / 自研 BZZ+JB2+IW44）；`.lit`/`.snb`/`.rb` 也已接入
      // （容器识别已实现，正文在缺可交叉验证的公开规范时**明确报错**，
      // 见 book_lit/book_snb/book_rb 文件头）。当前真正没有实现、仍然
      // 走 `BookFormat.none`（不进内嵌阅读）的只剩 KFX。
      for (final ext in const ['kfx']) {
        expect(bookFormatOf(ext), BookFormat.none, reason: ext);
        expect(isReadableBook(ext), isFalse, reason: ext);
      }
      // 已接入的旧格式：能进内嵌阅读（正文可能明确报"不支持"）
      for (final ext in const ['lit', 'snb', 'rb']) {
        expect(bookFormatOf(ext), isNot(BookFormat.none), reason: ext);
        expect(isReadableBook(ext), isTrue, reason: ext);
      }
    });

    test('格式名走枚举 label（语言中立，没有新增 ARB key）', () {
      expect(BookFormat.txt.label, 'TXT');
      expect(BookFormat.md.label, 'MD');
      expect(BookFormat.html.label, 'HTML');
      expect(BookFormat.rtf.label, 'RTF');
      expect(BookFormat.tcr.label, 'TCR');
      expect(BookFormat.docx.label, 'DOCX');
      expect(BookFormat.odt.label, 'ODT');
      expect(BookFormat.pdb.label, 'PDB');
      expect(BookFormat.prc.label, 'PRC');
      expect(BookFormat.fbz.label, 'FBZ');
      expect(BookFormat.cbt.label, 'CBT');
      expect(BookFormat.cb7.label, 'CB7');
      expect(BookFormat.opf.label, 'OPF');
      // DJVU 的语言中立格式名（没有新增 ARB key）
      expect(BookFormat.djvu.label, 'DJVU');
    });

    test('预览分流：全部进 book（含从 text/office 挪过来的 txt/md/docx/odt/rtf）', () {
      for (final ext in const [
        'epub', 'fb2', 'cbz', 'mobi', 'azw', 'azw3', //
        'txt', 'md', 'markdown', 'html', 'htm', 'xhtml', 'rtf', 'tcr',
        'docx', 'odt', 'pdb', 'prc', 'fbz', 'cbt', 'cb7', 'opf',
        // DJVU 也进内嵌阅读（有位图走翻页器，只有文本层走富文本）
        'djvu', 'djv',
      ]) {
        expect(
          filePreviewKind(_entry('a.$ext')),
          FilePreviewKind.book,
          reason: ext,
        );
      }
      // 已经不再有"是电子书但交系统应用"的已知格式（DJVU 已拿下）
      // 代码类文本仍是文本预览，没被误伤
      expect(filePreviewKind(_entry('main.dart')), FilePreviewKind.text);
      expect(filePreviewKind(_entry('a.log')), FilePreviewKind.text);
      // ★ 第 67 轮 D62：`.xlsx` 走**内嵌网格**（`officeSheet`）—— 215 轮保持不动
      // （网格比正文流更适合表格）。
      expect(filePreviewKind(_entry('a.xlsx')), FilePreviewKind.officeSheet);
      // ★ 215 轮 D62：`.pptx`/`.ods`/`.odp` 改走**客户端只读查看器**
      // （按页/按表抽结构 + 图片），不再走服务端 `Office.File.extract` 纯文本。
      expect(filePreviewKind(_entry('a.pptx')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.ods')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.odp')), FilePreviewKind.book);
    });

    test('兜底书名 = 文件名去后缀', () {
      expect(bookTitleFromEntry(_entry('三体.epub')), '三体');
      expect(bookTitleFromEntry(_entry('a.b.txt')), 'a.b');
      expect(bookTitleFromEntry(_entry('noext')), 'noext');
    });

    test('新格式拿封面一律 null（不崩、不误认）', () {
      for (final ext in const ['txt', 'md', 'docx', 'odt', 'cb7', 'pdb']) {
        expect(
          bookCoverBytes(ext, Uint8List.fromList(List.filled(32, 1))),
          isNull,
        );
      }
    });
  });

  // ---------------------------------------------------------------- PDB/PRC

  group('PalmDOC / PRC（parsePalmDocBook）', () {
    test('无 MOBI 头的老 PalmDOC：直读正文 + 分章 + 数据库名当书名', () {
      final r = parseBook(BookFormat.pdb, palmDoc(_zh, name: 'PalmDOC 验证'));
      expect(r.ok, isTrue);
      expect(r.content.title, 'PalmDOC 验证');
      expect(r.content.chapters, hasLength(2));
      expect(r.content.chapters.first.html, contains('正文甲'));
    });

    test('换页符（\\x0c）也算分章标记', () {
      final text = '第一页正文。\x0c第二页正文。\x0c第三页正文。';
      final r = parseBook(BookFormat.pdb, palmDoc(text));
      expect(r.content.chapters, hasLength(3));
      expect(r.content.chapters[1].html, contains('第二页正文'));
    });

    test('PalmDOC LZ77（压缩类型 2）能被解出来', () {
      final raw = utf8.encode(_zh);
      // 手写一条压缩流：0x01 拷贝 + 单个 0x09..0x7F 字面量（最简单的合法流）
      final encoded = <int>[];
      for (final b in raw) {
        if (b <= 0x08) {
          encoded
            ..add(0x01)
            ..add(b);
        } else if (b <= 0x7F) {
          encoded.add(b);
        } else {
          encoded
            ..add(0x01)
            ..add(b);
        }
      }
      final r = parseBook(
        BookFormat.prc,
        palmDoc(_zh, compression: 2, recordSize: 1 << 20),
      );
      expect(r.ok, isTrue);
      // 上面那本按"无压缩"造，这里只保证压缩路径的 fixture 自洽：
      expect(utf8.decode(mobiPalmDocDecode(encoded)), _zh);
    });

    test('带 MOBI 头的 .prc：转交给 MOBI 解析器（format 仍是 PRC）', () {
      final r = parseBook(
        BookFormat.prc,
        palmDoc(_zh, name: 'PRC 验证', mobiHeader: true),
      );
      expect(r.ok, isTrue);
      expect(r.content.format, BookFormat.prc);
      expect(r.content.chapters, isNotEmpty);
    });

    test('DRM（encryptionType != 0）→ 明确报"不解密"', () {
      final r = parseBook(BookFormat.pdb, palmDoc(_zh, encryption: 2));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('DRM'));
    });

    test('HUFF/CDIC 压缩类型 → 明确报"不支持"，不输出乱码', () {
      final r = parseBook(BookFormat.pdb, palmDoc(_zh, compression: 17480));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('HUFF/CDIC'));
      expect(r.content.chapters, isEmpty);
    });

    test('坏 PDB（头不完整/记录数越界）→ parseFailed', () {
      expect(
        parseBook(BookFormat.pdb, List<int>.filled(10, 0)).errorKind,
        BookParseErrorKind.parseFailed,
      );
      final bad = Uint8List(78);
      bad[76] = 0xFF; // 记录数远超文件长度
      bad[77] = 0xFF;
      expect(
        parseBook(BookFormat.pdb, bad).errorKind,
        BookParseErrorKind.parseFailed,
      );
    });

    test('探针：palmDocProbe 能读出头部关键字段', () {
      final probe = palmDocProbe(palmDoc(_zh, name: 'X'));
      expect(probe['hasMobiHeader'], isFalse);
      expect(probe['compression'], 1);
      expect(probe['title'], 'X');
    });
  });

  // ---------------------------------------------------------------- FBZ

  group('FBZ（zip 里的 FB2）', () {
    const fb2 =
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
        '<description><title-info><book-title>FBZ 之书</book-title></title-info>'
        '</description><body>'
        '<section><title><p>第一章</p></title><p>甲</p></section>'
        '<section><title><p>第二章</p></title><p>乙</p></section>'
        '</body></FictionBook>';

    test('正常：书名/章节/目录都来自内层 FB2，format 回填 FBZ', () {
      final r = parseBook(BookFormat.fbz, _zip({'book.fb2': utf8.encode(fb2)}));
      expect(r.ok, isTrue);
      expect(r.content.format, BookFormat.fbz);
      expect(r.content.title, 'FBZ 之书');
      expect(r.content.chapters, hasLength(2));
      expect(r.content.toc, hasLength(2));
    });

    test('zip 里没有 .fb2 → parseFailed', () {
      final r = parseBook(
        BookFormat.fbz,
        _zip({'readme.txt': utf8.encode('x')}),
      );
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('坏 FBZ（不是 zip）→ parseFailed', () {
      final r = parseBook(BookFormat.fbz, List<int>.filled(64, 0x41));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });
  });

  // ---------------------------------------------------------------- CBT / CB7

  group('CBT / CB7（漫画包）', () {
    test('CBT（tar）：按自然序出页', () {
      final r = parseBook(
        BookFormat.cbt,
        _tar({'c/p2.png': _png, 'c/p10.png': _png, 'c/p1.png': _png}),
      );
      expect(r.ok, isTrue);
      expect(r.content.pages, hasLength(3));
      expect(r.content.format, BookFormat.cbt);
    });

    test('CBT 里没有图片 → parseFailed', () {
      final r = parseBook(BookFormat.cbt, _tar({'a.txt': utf8.encode('x')}));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('CB7（7z）→ 明确报"不支持 7z（无可用解压实现）"', () {
      final sevenZip = Uint8List.fromList([
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, //
        ...List.filled(32, 0x11),
      ]);
      final r = parseBook(BookFormat.cb7, sevenZip);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, '不支持 7z（无可用解压实现）');
      expect(r.content.pages, isEmpty);
    });

    test('不是 7z 的 .cb7 → parseFailed（不是"不支持"）', () {
      final r = parseBook(BookFormat.cb7, List<int>.filled(64, 0x7A));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('is7z 认文件头', () {
      expect(is7z([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]), isTrue);
      expect(is7z([0x50, 0x4B, 0x03, 0x04]), isFalse);
    });
  });

  // ---------------------------------------------------------------- 页面层

  group('阅读页（页面层）：新格式真的能渲染', () {
    testWidgets('TXT：章节标题 + 页脚章数 + 翻章', (tester) async {
      final text =
          '第一章 起点\n\n正文甲。\n\n第二章 发展\n\n正文乙。\n\n'
          '第三章 收尾\n\n正文丙。';
      await _pump(tester, _entry('novel.txt'), utf8.encode(text));
      expect(find.text('novel'), findsWidgets);
      expect(find.textContaining('第 1/3 章'), findsOneWidget);
      expect(find.textContaining('正文甲。', findRichText: true), findsWidgets);
      await tester.tap(find.text('下一章'));
      await tester.pumpAndSettle();
      expect(find.textContaining('第 2/3 章'), findsOneWidget);
      expect(find.textContaining('正文乙。', findRichText: true), findsWidgets);
    });

    testWidgets('Markdown：内联图渲染成 Image', (tester) async {
      final md =
          '# 图集\n\n![棋盘]'
          '(data:image/png;base64,${base64.encode(_png)})\n\n'
          '## 收尾\n\n结束。';
      await _pump(tester, _entry('pic.md'), utf8.encode(md));
      expect(find.textContaining('图集'), findsWidgets);
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('HTML：正文与外链都在页面上', (tester) async {
      const html =
          '<html><head><title>网页之书</title></head><body>'
          '<h1>第一章</h1><p>可见正文。</p>'
          '<p><a href="https://example.com/">外链</a></p>'
          '<h2>第二章</h2><p>收尾。</p></body></html>';
      await _pump(tester, _entry('page.html'), utf8.encode(html));
      expect(find.text('网页之书'), findsWidgets);
      expect(find.textContaining('可见正文。', findRichText: true), findsWidgets);
    });

    testWidgets('DOCX：标题 + 加粗正文渲染', (tester) async {
      final docx = _zip({
        'word/document.xml': utf8.encode(
          '<?xml version="1.0"?><w:document xmlns:w="http://x" '
          'xmlns:a="http://y"><w:body>'
          '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
          '<w:r><w:t>第一章 文档</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>加粗正文</w:t></w:r></w:p>'
          '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr>'
          '<w:r><w:t>第二节</w:t></w:r></w:p>'
          '<w:p><w:r><w:t>收尾</w:t></w:r></w:p>'
          '</w:body></w:document>',
        ),
      });
      await _pump(tester, _entry('doc.docx'), docx);
      expect(find.textContaining('第一章 文档'), findsWidgets);
      expect(find.textContaining('加粗正文', findRichText: true), findsWidgets);
    });

    testWidgets('CB7：给出"不支持 7z"的明确错误，而不是乱码', (tester) async {
      final sevenZip = Uint8List.fromList([
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, //
        ...List.filled(32, 0x11),
      ]);
      await _pump(tester, _entry('comic.cb7'), sevenZip);
      expect(find.textContaining('暂时不能内嵌阅读'), findsOneWidget);
      expect(find.textContaining('这种压缩/编码变体本阅读器还没实现'), findsOneWidget);
      expect(find.textContaining('7z'), findsNothing);
    });

    testWidgets('OPF（缺兄弟文件）：错误里说明缺的是正文文件', (tester) async {
      const opf =
          '<?xml version="1.0"?><package xmlns="http://www.idpf.org/'
          '2007/opf"><manifest><item id="c1" href="a.xhtml" '
          'media-type="application/xhtml+xml"/></manifest>'
          '<spine><itemref idref="c1"/></spine></package>';
      await _pump(tester, _entry('book.opf'), utf8.encode(opf));
      expect(find.textContaining('暂时不能内嵌阅读'), findsOneWidget);
      // ★ r316c：缺兄弟文件是**用户可行动**的能力边界 → 单独一类本地化文案
      expect(find.textContaining('缺配套文件'), findsOneWidget);
    });

    testWidgets('PalmDOC：正文能显示', (tester) async {
      await _pump(tester, _entry('old.pdb'), palmDoc(_zh, name: '旧书'));
      expect(find.textContaining('旧书'), findsWidgets);
      expect(find.textContaining('正文甲。', findRichText: true), findsWidgets);
    });

    testWidgets('坏 DOCX：显示"解析失败"，不显示乱码', (tester) async {
      await _pump(tester, _entry('bad.docx'), utf8.encode('这不是 zip'));
      expect(find.textContaining('解析失败'), findsOneWidget);
    });
  });
}
