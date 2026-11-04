// CBR（RAR 漫画包）接入的离线测试：解析 → 封面 → 阅读页 → 进度。
//
// 素材两块：
//   * **store 包**用自研最小写入器现场生成（`tool/make_rar_fixture.dart`），
//     便于控制页名/页序/嵌套目录/中文名；
//   * **压缩 / 加密 / 多卷 / 坏包**用官方 `rar` 本地生成的 base64 常量
//     （`support/rar_fixture_data.dart`），保证"真解压器解真压缩流"。
import 'dart:convert';
import 'dart:typed_data';

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
import 'package:synhub/src/data/local/book_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/book_cover.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/rar_archive.dart';

import '../tool/make_rar_fixture.dart';
import 'support/chat_harness.dart' show FakeTransport;
import 'support/rar_fixture_data.dart';

/// 1×1 透明 PNG（够 Flutter 解码）
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// 带标记的假"图片"（解析层只看扩展名；封面那条路还要求 ≥12 字节 + magic，
/// 所以这里给一个够长的 PNG 头 + 标记字节）
Uint8List _tag(int n) => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG magic
  n, n, n, n, // 标记
]);

/// 一个 RAR4 store 漫画包：3 页（p1/p2/p10）+ 文本 + 嵌套目录 + __MACOSX 干扰
Uint8List _comic4({bool macosx = false}) => buildRar4Fixture([
  RarFixtureEntry('readme.txt', Uint8List.fromList(utf8.encode('说明'))),
  if (macosx) RarFixtureEntry('__MACOSX/._p1.png', _tag(99)),
  RarFixtureEntry('漫画/', Uint8List(0)),
  RarFixtureEntry('漫画/第01话/p10.png', _tag(10)),
  RarFixtureEntry('漫画/第01话/p2.png', _tag(2)),
  RarFixtureEntry('漫画/第01话/p1.png', _tag(1)),
]);

Uint8List _comic5() => buildRar5Fixture([
  RarFixtureEntry('readme.txt', Uint8List.fromList(utf8.encode('说明'))),
  RarFixtureEntry('漫画/第01话/p10.png', _tag(10)),
  RarFixtureEntry('漫画/第01话/p2.png', _tag(2)),
  RarFixtureEntry('漫画/第01话/p1.png', _tag(1)),
]);

/// 阅读页用的真 PNG 包（三页内容一样，够翻页）
Uint8List _comicPng() => buildRar4Fixture([
  RarFixtureEntry('readme.txt', Uint8List.fromList(utf8.encode('说明'))),
  RarFixtureEntry('p1.png', _png),
  RarFixtureEntry('p2.png', _png),
  RarFixtureEntry('p3.png', _png),
]);

/// 只有文本、没有图片
Uint8List _noImages() => buildRar5Fixture([
  RarFixtureEntry('readme.txt', Uint8List.fromList(utf8.encode('没有图'))),
]);

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/books/$name',
  isDir: false,
  size: 2048,
  mtime: 1700000000000,
);

/// 打开阅读页（内存库 + 假传输）
Future<({ProviderContainer c, ChatDatabase db, FakeTransport t})> _open(
  WidgetTester tester,
  String name,
  List<int> bytes, {
  /// 复用上一轮的库（"关掉再打开"要能读到上次写的进度）
  ChatDatabase? db,
  /// 复用一个已配置好的传输桩（可以带"下载闸门"造真机时序）
  FakeTransport? t,
}) async {
  t ??= FakeTransport(const {}, {...FakeTransport.table});
  t.downloadBytes = bytes;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final reuse = db;
  db = db ?? ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(FileStationApi(api)),
    ],
  );
  addTearDown(() async {
    c.dispose();
    if (reuse == null) await db!.close(); // 复用的库由第一轮负责关
  });
  await tester.pumpWidget(_stage(c, name));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (c: c, db: db, t: t);
}

/// 阅读页的完整挂载树 —— 抽出来是为了让"关掉再打开"能用**同一个 db/容器**重挂。
Widget _stage(ProviderContainer c, String name) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(
      body: FileBookStage(entry: _entry(name), bytesUrl: 'https://nas/x'),
    ),
    localizationsDelegates: const [
      FlutterQuillLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: FlutterQuillLocalizations.supportedLocales,
  ),
);

void main() {
  group('CBR 格式识别（列表/预览归类）', () {
    test('扩展名 → BookFormat.cbr，标签 CBR', () {
      expect(bookFormatOf('cbr'), BookFormat.cbr);
      expect(BookFormat.cbr.label, 'CBR');
      expect(isComicBook(BookFormat.cbr), isTrue);
      expect(isComicBook(BookFormat.cbz), isTrue);
      expect(isComicBook(BookFormat.epub), isFalse);
    });

    test('预览页归到"书"这一类（不再是"其他"）', () {
      expect(filePreviewKind(_entry('comic.cbr')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('scan.CBR')), FilePreviewKind.book);
    });

    test('列表承认 CBR 有封面可抠', () {
      expect(bookCoverSupported('cbr'), isTrue);
      expect(bookCoverSupported('CBR'), isTrue);
    });
  });

  group('CBR 解析', () {
    test('RAR4：只收图片、跳过 __MACOSX、按自然序（p1 < p2 < p10）', () {
      final r = parseBook(BookFormat.cbr, _comic4(macosx: true));
      expect(r.ok, isTrue, reason: r.error ?? '');
      final pages = r.content.pages;
      expect(pages, hasLength(3));
      expect(pages[0], _tag(1));
      expect(pages[1], _tag(2));
      expect(pages[2], _tag(10));
      expect(r.content.format, BookFormat.cbr);
    });

    test('RAR5：同一套结果', () {
      final r = parseBook(BookFormat.cbr, _comic5());
      expect(r.ok, isTrue, reason: r.error ?? '');
      expect([for (final p in r.content.pages) p[8]], [1, 2, 10]);
    });

    test('RAR 2.0（unpackver 20）**只存储**的包也当漫画读（版本号不拦存储型）', () {
      // 真实世界里 `rar -ma2` 只存储打的包到处都是：METHOD=0x30 与 UNP_VER 无关，
      // 不能因为版本号就把整包判成"不支持"。
      final bytes = buildRar4Fixture([
        RarFixtureEntry('p1.png', _tag(1)),
        RarFixtureEntry('p2.png', _tag(2)),
      ], unpackVersion: 20);
      final r = parseBook(BookFormat.cbr, bytes);
      expect(r.ok, isTrue, reason: r.error ?? '');
      expect([for (final p in r.content.pages) p[8]], [1, 2]);
    });

    test('Windows 打包的反斜杠路径也当漫画读（归一化成 /）', () {
      final bytes = buildRar4Fixture([
        RarFixtureEntry(r'第01话\p1.png', _tag(1)),
        RarFixtureEntry(r'第01话\p2.png', _tag(2)),
      ]);
      final r = parseBook(BookFormat.cbr, bytes);
      expect(r.ok, isTrue, reason: r.error ?? '');
      expect([for (final p in r.content.pages) p[8]], [1, 2]);
    });

    test('压缩包（官方 rar 生成）也能解析成漫画页', () {
      for (final b64 in [kRar4Comp, kRar5Comp, kRar4Solid, kRar5Solid]) {
        final r = parseBook(BookFormat.cbr, rarFixtureBytes(b64));
        expect(r.ok, isTrue, reason: r.error ?? '');
        expect(r.content.pages, hasLength(4));
        for (final p in r.content.pages) {
          expect(p.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        }
      }
    });

    test('没有图片 → 解析失败而不是空白阅读页', () {
      final r = parseBook(BookFormat.cbr, _noImages());
      expect(r.ok, isFalse);
      // 解析层给的是"坏文件"大类；具体原因留给 diagnostics，界面不硬塞技术细节
      expect(r.errorKind, BookParseErrorKind.parseFailed);
      expect(r.content.pages, isEmpty);
    });

    test('加密包 → "不支持压缩变体"的明确提示（不当成坏文件）', () {
      for (final b64 in [kRar4Enc, kRar5Enc]) {
        final r = parseBook(BookFormat.cbr, rarFixtureBytes(b64));
        expect(r.ok, isFalse);
        expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
        expect(r.error, contains('密码'));
      }
    });

    test('多卷包 → 同样给明确提示', () {
      final r = parseBook(BookFormat.cbr, rarFixtureBytes(kRar4VolPart1));
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('多卷'));
    });

    test('截断 / 数据被改坏 → 报坏文件，不吐半截数据', () {
      final trunc = parseBook(BookFormat.cbr, rarFixtureBytes(kRar4Trunc));
      expect(trunc.ok, isFalse);
      expect(trunc.errorKind, BookParseErrorKind.parseFailed);

      final corrupt = parseBook(BookFormat.cbr, rarFixtureBytes(kRar5Corrupt));
      expect(corrupt.ok, isFalse);
      expect(corrupt.errorKind, BookParseErrorKind.parseFailed);
      // 自研解压层确实报了 CRC（parseBook 对外只给大类，这里直接问底层）
      expect(
        () => RarArchive.open(rarFixtureBytes(kRar5Corrupt)).extract(),
        throwsA(
          isA<RarFormatException>().having(
            (e) => e.message,
            'message',
            contains('CRC'),
          ),
        ),
      );
    });
  });

  group('CBR 封面', () {
    test('抠第一张图（自然序），不是字典序的 p10', () {
      final cover = bookCoverBytes('cbr', _comic4());
      expect(cover, _tag(1));
    });

    test('加密 / 没图 / 根本不是 RAR → 返回 null（列表退回图标）', () {
      expect(bookCoverBytes('cbr', rarFixtureBytes(kRar4Enc)), isNull);
      expect(bookCoverBytes('cbr', _noImages()), isNull);
      expect(bookCoverBytes('cbr', utf8.encode('not a rar')), isNull);
    });

    test('截断包：拿不到封面就 null，拿到必须是**完整**首页（不吐半截）', () {
      final full = bookCoverBytes('cbr', rarFixtureBytes(kRar4Comp));
      expect(full, isNotNull);
      final cut = bookCoverBytes('cbr', rarFixtureBytes(kRar4Trunc));
      // 用 matcher 做**逐字节**比较（Uint8List 的 `==` 是同一性）
      expect(cut, anyOf(isNull, equals(full)));
    });

    test('压缩包封面 = 解出来的第一页', () {
      final cover = bookCoverBytes('cbr', rarFixtureBytes(kRar5Comp));
      expect(cover, isNotNull);
      expect(cover!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      final pages = parseBook(
        BookFormat.cbr,
        rarFixtureBytes(kRar5Comp),
      ).content.pages;
      expect(cover, pages.first);
    });
  });

  group('CBR 阅读页（和 CBZ 同一个漫画视图）', () {
    testWidgets('按页翻，页脚格式标签是 CBR', (tester) async {
      await _open(tester, 'comic.cbr', _comicPng());
      expect(find.text('CBR · 1/3'), findsOneWidget);

      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle();
      expect(find.text('CBR · 2/3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('翻页进度落库（format=CBR，按页数算）', (tester) async {
      final r = await _open(tester, 'comic.cbr', _comicPng());
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));

      final p = await BookStore(r.db).progressOf('fs:/books/comic.cbr');
      expect(p, isNotNull);
      expect(p!.format, 'CBR');
      // 漫画没有"章"，chapterCount 记 0 是既有约定（和 CBZ 一致）
      expect(p.chapterCount, 0);
      // 3 页，翻到第 2 页 = 2/3
      expect(p.scroll, closeTo(2 / 3, 0.01));
    });

    // ★★★ r316c 真机缺陷守卫：漫画只有 `pages`、没有 `chapters`，曾经
    // `_applySaved()` 在 `chapters.isEmpty` 处早退 ⇒ **存了进度却永远回第 1 页**。
    // 真机逐字：停在 `CBR · 2/4` 关掉 → 重开 `CBR · 1/4`。
    // 这条用例必须"关掉再打开"（同一个库），否则测不到恢复路径。
    testWidgets('★ 重开回到上次那页（不是永远第 1 页）', (tester) async {
      final r = await _open(tester, 'comic.cbr', _comicPng());
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('CBR · 2/3'), findsOneWidget);

      // 拆掉阅读页（新的 State ⇒ 会重新走 initState 的进度读取）
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(_stage(r.c, 'comic.cbr'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final shown = tester
          .widgetList<Text>(find.byType(Text))
          .map((e) => e.data ?? '')
          .where((e) => e.startsWith('CBR'))
          .toList();
      expect(
        find.text('CBR · 2/3'),
        findsOneWidget,
        reason:
            'r316c：漫画的阅读位置必须恢复（原来因 chapters 为空而永远 1/3）；'
            '实际页脚 = $shown',
      );
      expect(tester.takeException(), isNull);
    });

    // ⚠️ 这条只覆盖"**同容器、字节已缓存**"的重开路径（解析同步完成，比进度还早），
    // 因此它对"漫画分支漏调 `_applySaved()`"这个缺口**没有鉴别力**
    // —— 反向验证时去掉修复它照样绿。真正的判据是下面那条"新容器 + 下载闸门"。
    testWidgets('重开（同容器缓存命中）也回到上次那页', (tester) async {
      final r = await _open(tester, 'comic.cbr', _comicPng());
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('CBR · 2/3'), findsOneWidget);

      // 拆掉阅读页（新的 State ⇒ 重新走 initState 的进度读取）
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      // 闸住下载：进度先回来、解析后完成 —— 与真机同序
      r.t.holdDownloads = true;
      await tester.pumpWidget(_stage(r.c, 'comic.cbr'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      r.t.releaseDownloads();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final shown = tester
          .widgetList<Text>(find.byType(Text))
          .map((e) => e.data ?? '')
          .where((e) => e.startsWith('CBR'))
          .toList();
      expect(
        find.text('CBR · 2/3'),
        findsOneWidget,
        reason: '真机时序下也要恢复；实际页脚 = $shown',
      );
      expect(tester.takeException(), isNull);
    });

    // ★★★ r316c 第六处（**真机时序**的守卫，且必须"新容器"）：
    // 同一个容器第二次挂载会命中 `fileBytesProvider` 缓存 ⇒ 解析**同步**完成、
    // 比进度还早，测不出缺口（我第一版就是这么写的，反向验证时"去掉修复仍然绿"，
    // 当场暴露了假守卫）。真机是**新页面 + 新请求**：必须用新容器 + 闸住下载。
    testWidgets('★ 解析晚于进度（真机时序·新容器）也必须恢复', (tester) async {
      final r1 = await _open(tester, 'comic.cbr', _comicPng());
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('CBR · 2/3'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      // 新容器（不复用 provider 缓存）+ 下载闸门：进度先回来、解析后完成
      final t2 = FakeTransport(const {}, {...FakeTransport.table});
      t2.holdDownloads = true;
      await _open(tester, 'comic.cbr', _comicPng(), db: r1.db, t: t2);

      await tester.pump(const Duration(milliseconds: 200)); // 进度读回
      t2.releaseDownloads();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final shown = tester
          .widgetList<Text>(find.byType(Text))
          .map((e) => e.data ?? '')
          .where((e) => e.startsWith('CBR'))
          .toList();
      expect(
        find.text('CBR · 2/3'),
        findsOneWidget,
        reason: '真机时序（下载/解析晚于进度读取）下也要恢复；实际页脚 = $shown',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('加密 CBR：给能看懂的提示 + 引导下载', (tester) async {
      await _open(tester, 'secret.cbr', rarFixtureBytes(kRar4Enc));
      expect(find.textContaining('暂时不能内嵌阅读'), findsOneWidget);
      expect(find.textContaining('其他应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
