// CHM（ITSF + ITSP/PMGL + LZX）解析 + 接入点的离线测试。
//
// **fixture 全部由 `tool/make_chm_fixture.dart` 现场生成**（自研最小写入器：
// ITSF v3 头 + ITSP + PMGL 目录 + LZX **未压缩块** 内容流 + LZXC + ResetTable），
// 不下载任何真实 CHM —— 真实书的覆盖率交给真机那一步，这里负责把
// **接口与算法** 钉死：容器解析、v2/v3 头、目录树、存储空间、LZX 未压缩块往返、
// 多块/重置区间、截断与能力边界（必须给清晰错误，不许吐乱码或半截内容）、
// hhc 三层目录、中文三种编码、图片内联、封面，以及阅读页 widget。
//
// ⚠️ 边界（如实说明）：本文件**证明不了 verbatim/aligned 压缩块**——那需要一份
// 真实 CHM 才能端到端验证（自造 fixture 只覆盖未压缩块）。解码实现见
// `chm_archive.dart`，边界声明也写在那里。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/book_chm.dart';
import 'package:synhub/src/features/files/book_cover.dart';
import 'package:synhub/src/features/files/chm_archive.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import '../tool/make_chm_fixture.dart';
import 'support/chat_harness.dart' show FakeTransport;

// ============================================================ fixture

/// MSCompressed 数据空间的三个内部条目（chm_archive 里是私有的，这里按规范写死）
const String _contentUnit = '::DataSpace/Storage/MSCompressed/Content';
const String _controlUnit = '::DataSpace/Storage/MSCompressed/ControlData';
const String _resetUnit =
    '::DataSpace/Storage/MSCompressed/Transform/'
    '{7FC28940-9D31-11D0-9B27-00A0C91E9C7C}/InstanceData/ResetTable';

Uint8List _good() => buildChmFixture(chmFixtureFiles());

/// 把 ITSF 头改成 v2（0x58）：data_offset 不再是字段，而是 dir_offset + dir_len
Uint8List _v2(Uint8List good) {
  final b = Uint8List.fromList(good);
  b[4] = 2;
  b[5] = 0;
  b[6] = 0;
  b[7] = 0;
  b[8] = 0x58;
  b[9] = 0;
  b[10] = 0;
  b[11] = 0;
  return b;
}

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/books/$name',
  isDir: false,
  size: 37187,
  mtime: 1700000000000,
);

// ============================================================ 阅读页 pump

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
  // ---------------------------------------------------------------- 接入
  group('格式接入（扩展名 → 解析器 → 预览分流）', () {
    test('.chm / .djvu 都落到"内嵌阅读"', () {
      expect(bookFormatOf('chm'), BookFormat.chm);
      expect(bookFormatOf('CHM'), BookFormat.chm);
      expect(isReadableBook('chm'), isTrue);
      expect(filePreviewKind(_entry('a.chm')), FilePreviewKind.book);
      expect(canPreviewInline(_entry('a.chm')), isTrue);
      expect(bookCoverSupported('chm'), isTrue);
      // DJVU 也由自研纯 Dart 接手（`book_djvu.dart` 那一批）
      expect(bookFormatOf('djvu'), BookFormat.djvu);
      expect(isReadableBook('djvu'), isTrue);
      expect(filePreviewKind(_entry('a.djvu')), FilePreviewKind.book);
      expect(bookCoverSupported('djvu'), isTrue);
    });

    test('格式名语言中立（没有新增 ARB key）', () {
      expect(BookFormat.chm.label, 'CHM');
    });

    test('parseBook 按格式分派，format 回填 chm', () {
      final r = parseBook(BookFormat.chm, _good());
      expect(r.ok, isTrue);
      expect(r.content.format, BookFormat.chm);
      expect(r.content.chapters, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------- 容器
  group('ITSF 容器 + ITSP/PMGL 目录树', () {
    test('v3 头字段与目录条目都能读出来', () {
      final good = _good();
      final a = ChmArchive.open(good);
      expect(a.version, 3);
      expect(a.blockLen, 0x1000);
      expect(a.langId, 0x0804);
      expect(a.dataOffset, a.dirOffset + a.dirLen);

      final probe = chmProbe(good);
      expect(probe.containsKey('error'), isFalse);
      expect(probe['version'], 3);
      expect(probe['hasSystem'], isTrue);
      expect(probe['entries'], greaterThanOrEqualTo(10));
      expect(probe['compressedEntries'], greaterThanOrEqualTo(6));
    });

    test('v2 头（0x58）也认：data_offset = dir_offset + dir_len', () {
      final v2 = _v2(_good());
      final a = ChmArchive.open(v2);
      expect(a.version, 2);
      expect(a.dataOffset, a.dirOffset + a.dirLen);
      final r = parseChmBook(v2, format: BookFormat.chm);
      expect(r.ok, isTrue);
      expect(r.content.chapters.length, 7);
      expect(r.content.title, 'CHM 验证之书');
    });

    test('存储空间：内部文件/数据空间在 space 0，正文页在 space 1', () {
      final a = ChmArchive.open(_good());
      expect(a.find('/#SYSTEM')!.space, 0);
      expect(a.find('/toc.hhc')!.space, 1);
      expect(a.find('/index.htm')!.space, 1);
      expect(a.find('/guide/ch1.htm')!.space, 1);
      expect(a.find('/images/logo.png')!.space, 1);
      expect(a.find(_contentUnit)!.space, 0);
      expect(a.find(_controlUnit)!.space, 0);
      expect(a.find(_resetUnit)!.space, 0);
    });

    test('PMGL 条目大小写不敏感、容忍前导斜杠', () {
      final a = ChmArchive.open(_good());
      expect(a.find('INDEX.HTM') != null, isTrue);
      expect(a.find('/Guide/CH1.htm') != null, isTrue);
      expect(a.find('/guide/ch1.htm')!.normalized, 'guide/ch1.htm');
      expect(a.find('/nope.htm'), isNull);
    });

    test('签名不符 / 截断 → ChmFormatException（不是"空书"）', () {
      final broken = Uint8List.fromList(_good());
      broken[0] = 0x58;
      expect(() => ChmArchive.open(broken), throwsA(isA<ChmFormatException>()));
      final good = _good();
      expect(
        () => ChmArchive.open(Uint8List.sublistView(good, 0, 0x40)),
        throwsA(isA<ChmFormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------- LZX
  group('LZX 解压（CHM 变体）', () {
    test('未压缩块往返：写入器 → 解码器逐字节还原', () {
      final content = Uint8List.fromList([for (var i = 0; i < 256; i++) i]);
      final stream = lzxUncompressedStream(
        content,
        blockLen: 64,
        resetEvery: 2,
      );
      final first = chmLzxDecodeBlock(stream, windowBits: 15, outLen: 64);
      expect(first, equals(content.sublist(0, 64)));
      // 第二个块：同一个解码器接着喂（跨块状态必须保留）
      final dec = ChmLzxDecoder(windowBits: 15);
      expect(dec.decodeChunk(stream, 64), equals(content.sublist(0, 64)));
      expect(
        dec.decodeChunk(
          Uint8List.sublistView(stream, _uncompressedBlockBytes(64)),
          64,
        ),
        equals(content.sublist(64, 128)),
      );
    });

    test('多块 + 重置区间：跨块/跨文件偏移精确还原', () {
      final big1 = Uint8List.fromList(utf8.encode('第一块内容${'A' * 20000}尾标记甲'));
      final big2 = Uint8List.fromList(utf8.encode('第二块内容${'B' * 20000}尾标记乙'));
      // blockLen=4096、resetField=1 → 解码侧每 8 块重置一次（写入侧自动对齐）
      expect(big1.length + big2.length, greaterThan(0x1000 * 8));
      final bytes = buildChmFixture(
        [ChmFixtureFile('big1.htm', big1), ChmFixtureFile('big2.htm', big2)],
        blockLen: 0x1000,
        resetField: 1,
      );
      final a = ChmArchive.open(bytes);
      expect(a.read(a.find('/big1.htm')!), equals(big1));
      expect(a.read(a.find('/big2.htm')!), equals(big2));
    });

    test('CHM 里每个压缩条目解出来的字节和原文完全一致', () {
      final a = ChmArchive.open(_good());
      for (final f in chmFixtureFiles()) {
        final e = a.find(f.path);
        expect(e, isNotNull, reason: f.path);
        expect(a.read(e!), equals(f.data), reason: f.path);
      }
      // 顺带钉一下：GBK 页面在**磁盘上**确实是 GBK 字节（不是 UTF-8）
      final gbk = a.read(a.find('/guide/ch2.htm')!);
      expect(gbk, containsAllInOrder(gbkEncode('雨点打在窗台上，噼里啪啦响个不停。')));
    });

    test('截断的 LZX 流 → 明确报错，不吐半截内容', () {
      final content = Uint8List.fromList([for (var i = 0; i < 128; i++) i]);
      final stream = lzxUncompressedStream(
        content,
        blockLen: 64,
        resetEvery: 4,
      );
      final cut = Uint8List.sublistView(stream, 0, stream.length - 30);
      final dec = ChmLzxDecoder(windowBits: 15);
      expect(dec.decodeChunk(stream, 64), equals(content.sublist(0, 64)));
      expect(
        () => dec.decodeChunk(
          Uint8List.sublistView(cut, _uncompressedBlockBytes(64)),
          64,
        ),
        throwsA(isA<ChmFormatException>()),
      );
    });

    test('未实现的块类型 → ChmUnsupportedException（不是乱码）', () {
      final bytes = buildChmFixture(chmFixtureFiles(), blockType: 4);
      final a = ChmArchive.open(bytes);
      expect(
        () => a.read(a.find('/index.htm')!),
        throwsA(isA<ChmUnsupportedException>()),
      );
      final r = parseChmBook(bytes, format: BookFormat.chm);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('块类型 4'));
    });

    test('LZXC 版本 / 窗口做不到 → ChmUnsupportedException', () {
      final v3 = buildChmFixture(chmFixtureFiles(), lzxcVersion: 3);
      final a3 = ChmArchive.open(v3);
      expect(
        () => a3.read(a3.find('/index.htm')!),
        throwsA(isA<ChmUnsupportedException>()),
      );
      final r3 = parseChmBook(v3, format: BookFormat.chm);
      expect(r3.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r3.error, contains('LZXC 版本 3'));

      // windowField=0x200 → 0x200*0x8000 = 2^24 字节窗口，超出 2^21 上限
      final bigWindow = buildChmFixture(chmFixtureFiles(), windowField: 0x200);
      final r = parseChmBook(bigWindow, format: BookFormat.chm);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('窗口'));
    });

    test('窗口为 0 → 坏文件（parseFailed），不是"不支持"', () {
      final zero = buildChmFixture(chmFixtureFiles(), windowField: 0);
      final r = parseChmBook(zero, format: BookFormat.chm);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });
  });

  // ---------------------------------------------------------------- 内容
  group('内容抽取（hhc 目录 / 中文 / 图片）', () {
    test('#SYSTEM：书名 / 默认首页 / hhc 路径', () {
      final c = parseChmBook(_good(), format: BookFormat.chm).content;
      expect(c.title, 'CHM 验证之书');
      expect(c.chapters.first.href, 'index.htm');
    });

    test('hhc 三层嵌套 → BookTocEntry 层级 + 精确章节下标', () {
      final c = parseChmBook(_good(), format: BookFormat.chm).content;
      expect(c.chapters.length, 7);
      expect(c.toc.map((e) => e.title).toList(), chmFixtureTocTitles);
      expect(c.toc.map((e) => e.depth).toList(), chmFixtureTocDepths);
      expect(c.toc.map((e) => e.chapterIndex).toList(), [1, 2, 3, 4, 5, 6]);
      expect(c.anchors['guide/ch1.htm#sec1'], 2);
      expect(c.anchors['guide/ch1.htm#sec2'], 3);
      expect(c.chapters[2].html, contains('1.1 小节：锚点'));
      expect(c.chapters[3].html, contains('1.1.1 更深的锚点'));
    });

    test('中文 UTF-8 / GBK / UTF-16LE 正文都不乱码', () {
      final c = parseChmBook(_good(), format: BookFormat.chm).content;
      expect(c.chapters[0].html, contains('示例 CHM 手册'));
      expect(c.chapters[0].html, contains('自造的最小 CHM'));
      expect(c.chapters[1].html, contains('风从海上来，带着一点咸味。'));
      expect(c.chapters[4].html, contains('雨点打在窗台上，噼里啪啦响个不停。'));
      expect(c.chapters[5].html, contains('这一页用 GBK 存'));
      expect(c.chapters[6].html, contains('深夜的灯还亮着'));
      for (final ch in c.chapters) {
        expect(ch.html, isNot(contains('\uFFFD')), reason: ch.href);
        expect(ch.html, isNot(contains('\u0000')));
      }
    });

    test('Windows-1252（ANSI）hhc/正文：0x92 解成右单引号而不是 U+FFFD', () {
      // 真实样本 python2718.chm（python.org PSF）的 .hhc 与 403/513 个正文页就是
      // CP1252：0x92 = U+2019。通用探测只认 UTF-8/UTF-16/GB18030/Big5，
      // 这些字节会一路落到 `utf-8(lossy)` → 正文冒 `�`（bug）。
      final hhc = <int>[
        ...asciiBytes(
          '<HTML><BODY><UL><LI><OBJECT type="text/sitemap">'
          '<param name="Name" value="What',
        ),
        0x92, // CP1252 右单引号
        ...asciiBytes(
          's New"><param name="Local" value="index.htm">'
          '</OBJECT></UL></BODY></HTML>',
        ),
      ];
      final page = <int>[
        ...asciiBytes('<html><body><h1>What'),
        0x92,
        ...asciiBytes('s New</h1><p>It'),
        0x92,
        ...asciiBytes('s fine. \x93quoted\x94 & \x96 dash</p></body></html>'),
      ];
      final bytes = buildChmFixture([
        ChmFixtureFile('toc.hhc', Uint8List.fromList(hhc)),
        ChmFixtureFile('index.htm', Uint8List.fromList(page)),
      ]);
      final r = parseChmBook(bytes, format: BookFormat.chm);
      expect(r.ok, isTrue);
      expect(r.content.toc.first.title, 'What\u2019s New');
      expect(r.content.chapters.first.title, 'What\u2019s New');
      expect(r.content.chapters.first.html, contains('It\u2019s fine'));
      expect(r.content.chapters.first.html, contains('\u201Cquoted\u201D'));
      expect(r.content.chapters.first.html, contains('\u2013 dash'));
      expect(r.content.chapters.first.html, isNot(contains('\uFFFD')));
    });

    test('页内链接 / 锚点表可跳转（anchorFor）', () {
      final c = parseChmBook(_good(), format: BookFormat.chm).content;
      expect(c.anchorFor('index.htm', 'guide/ch1.htm'), isNull); // 无锚点
      expect(c.anchorFor('guide/ch2.htm', '#sec1'), 5);
      expect(c.anchorFor('guide/ch1.htm', 'ch1.htm#sec2'), 3);
      expect(c.anchorFor('guide/ch1.htm', 'https://x/y#z'), isNull);
    });

    test('图片内联进 resources，img src 改写成书根路径', () {
      final c = parseChmBook(_good(), format: BookFormat.chm).content;
      expect(c.resources.keys, contains('images/logo.png'));
      final png = c.resources['images/logo.png']!;
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(c.chapters[0].html, contains('src="images/logo.png"'));
      // `../images/logo.png` 也要归一到书根
      expect(c.chapters[3].html, contains('src="images/logo.png"'));
    });

    test('封面：从默认首页第一张图取到 PNG；坏书 → null', () {
      final good = _good();
      final cover = chmCoverBytes(good);
      expect(cover, isNotNull);
      expect(cover!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(bookCoverBytes('chm', good), isNotNull);
      expect(
        bookCoverBytes('chm', Uint8List.sublistView(good, 0, 0x40)),
        isNull,
      );
    });

    test('没有 hhc 时 toc 为空、按章节列（阅读器自己兜底）', () {
      final bytes = buildChmFixture([
        ChmFixtureFile(
          'index.htm',
          Uint8List.fromList(utf8.encode('<h1>A</h1>')),
        ),
        ChmFixtureFile('p2.htm', Uint8List.fromList(utf8.encode('<h1>B</h1>'))),
      ], hhcPath: null);
      final c = parseChmBook(bytes, format: BookFormat.chm).content;
      expect(c.toc, isEmpty);
      expect(c.chapters.length, 2);
      expect(c.chapters.first.href, 'index.htm');
    });
  });

  // ---------------------------------------------------------------- 坏文件
  group('坏文件 / 能力边界（不许输出乱码或半截）', () {
    test('尾部截断 → parseFailed', () {
      final good = _good();
      final r = parseChmBook(
        Uint8List.sublistView(good, 0, good.length - 64),
        format: BookFormat.chm,
      );
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
      expect(r.content.chapters, isEmpty);
    });

    test('坏签名 → parseFailed（不是抛异常到界面）', () {
      final broken = Uint8List.fromList(_good());
      broken[0] = 0x58;
      final r = parseChmBook(broken, format: BookFormat.chm);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('目录里没有正文 → parseFailed 而不是"空书 ok"', () {
      final bytes = buildChmFixture([
        ChmFixtureFile('images/only.png', makePng(8, 8, 0x112233)),
      ]);
      final r = parseChmBook(bytes, format: BookFormat.chm);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.parseFailed);
    });

    test('探针：能读的报 ok，不能读的报 kind', () {
      expect(chmBookProbe(_good())['ok'], isTrue);
      final bad = chmBookProbe(
        buildChmFixture(chmFixtureFiles(), blockType: 4),
      );
      expect(bad['ok'], isFalse);
      expect(bad['kind'], 'unsupportedCompression');
      expect(chmProbe(const <int>[])['error'], isNotNull);
      expect(chmBookProbe(const <int>[])['ok'], isFalse);
    });
  });

  // ---------------------------------------------------------------- 阅读页
  group('阅读页（CHM 走和 EPUB 同一套 BookContent）', () {
    testWidgets('CHM：显示书名 / 章节 / 正文 / 插图，翻章可用', (tester) async {
      final b = await _pump(tester, _entry('book.chm'), _good());
      expect(find.text('CHM 验证之书'), findsOneWidget);
      expect(find.textContaining('第 1/7 章'), findsOneWidget);
      expect(
        find.textContaining('示例 CHM 手册', findRichText: true),
        findsWidgets,
      );
      expect(find.byType(Image), findsWidgets);
      expect(find.textContaining('缺失图片'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('下一章'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('第 2/7 章'), findsOneWidget);
      expect(find.textContaining('风从海上来', findRichText: true), findsWidgets);
      expect(b.t.downloads, isNotEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('CHM：目录面板读的是 hhc 原书目录，三层条目点得动', (tester) async {
      await _pump(tester, _entry('toc.chm'), _good());
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-toc-list')), findsOneWidget);
      expect(find.text('6 条 · 原书目录'), findsOneWidget);
      expect(find.text('1.1.1 更深的锚点'), findsWidgets);

      await tester.tap(find.text('第二章 落雨了').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('第 5/7 章'), findsOneWidget);
      expect(find.textContaining('雨点打在窗台上', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('CHM 能力边界：给"不支持"提示，不红屏', (tester) async {
      final bytes = buildChmFixture(chmFixtureFiles(), blockType: 4);
      await _pump(tester, _entry('bad.chm'), bytes);
      expect(find.textContaining('这个格式还不支持内嵌阅读'), findsOneWidget);
      // ★★★ r316c：能力边界按**类型**说本地化的话（"这种压缩/编码变体还没实现"），
      // 解析层的技术串（`LZX 块类型 4`）只进日志 —— 英文设备上曾经因此中英混串。
      expect(find.textContaining('这种压缩/编码变体本阅读器还没实现'), findsOneWidget);
      expect(
        find.textContaining('LZX 块类型 4'),
        findsNothing,
        reason: 'r316c：诊断串不许当用户文案（原文进 debugPrint）',
      );
      expect(tester.takeException(), isNull);
    });
  });

  // 真实样本（python.org 官方 Python 2.7.18 帮助文件，PSF 许可）只在 /tmp 存在时跑，
  // 6 MB 样本**不进仓库**。它钉住 LZX 的 verbatim/aligned 路径与内容抽取：
  // 下面的 sha256 是用独立实现 7z 解出的 oracle 值（命令见 docs/ebook-reader-plan.md §7.7）。
  group('真实样本端到端（/tmp/ebook-samples/python2718.chm）', () {
    final sample = File('/tmp/ebook-samples/python2718.chm');
    final missing = sample.existsSync()
        ? null
        : '真实样本 /tmp/ebook-samples/python2718.chm 不存在';

    test('LZX 解出的代表文件与 7z oracle 逐字节一致（verbatim/aligned 路径）', () async {
      final bytes = await sample.readAsBytes();
      final a = ChmArchive.open(bytes);
      expect(a.version, 3);

      // 内容流走 verbatim/aligned 块；这三个文件覆盖大/中/小与 hhc
      const known = {
        '#SYSTEM':
            '66bd4fbd81600f14122f60b77e6feedd60d060a462fa5a4264d2efd29ee57654',
        'genindex-M.html':
            '1f8f40fb9ae5c111d21e122f78a82a371d5b5464477b6a45cc50733238924dd2',
        'library/stdtypes.html':
            '92511e4ccd6731102e6b279a5bf360462b37f8fca22c338bede281525cdd7646',
        'python2718.hhc':
            '509c87ac3500cfc4f3c592197700078d02c5956ae84d3c66d21bb052a663b517',
      };
      for (final e in known.entries) {
        final entry = a.find(e.key);
        expect(entry, isNotNull, reason: e.key);
        expect(_sha256(a.read(entry!)), e.value, reason: e.key);
      }

      // 全部压缩条目都要能解出来（S 集合：任一坏块都会抛）
      var compressed = 0;
      for (final entry in a.entries) {
        if (entry.isDir || entry.space != 1 || entry.length <= 0) continue;
        expect(a.read(entry).length, entry.length, reason: entry.path);
        compressed++;
      }
      expect(compressed, greaterThan(500));

      // 内容抽取层 + CP1252 修正
      final r = parseChmBook(bytes, format: BookFormat.chm);
      expect(r.ok, isTrue);
      expect(r.content.title, 'Python 2.7.18 documentation');
      expect(r.content.chapters.length, greaterThan(900));
      final all = r.content.chapters.map((c) => c.html).join();
      expect(all.contains('\uFFFD'), isFalse, reason: 'CP1252 没解码会冒出替换字符');
      expect(all, contains('What\u2019s New'));
    }, skip: missing);
  });
}

String _sha256(List<int> b) => SHA256Digest()
    .process(b is Uint8List ? b : Uint8List.fromList(b))
    .map((x) => x.toRadixString(16).padLeft(2, '0'))
    .join();

/// 一个 4 字节块头 + 12 字节 R0R1R2 + blockLen 原始数据（偶数长度不补字节）
int _uncompressedBlockBytes(int blockLen) {
  var n = 4 + 12 + blockLen;
  if (blockLen.isOdd) n += 1;
  return n;
}
