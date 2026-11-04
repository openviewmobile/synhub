// 阅读器 E1（进度 / 书签 / 搜索 / 外观）离线测试。
//
// 覆盖三层：
//   * `BookStore`（Drift）—— 进度 upsert/去重/最近在读、书签增删改查；
//   * `searchBook`（纯 Dart）—— 跨章命中、片段、章内位置；
//   * 页面（widget）—— 工具菜单 → 搜索跳章、加书签、字号持久化、目录筛选、
//     打开时恢复上次读到的章节。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show DefaultTextBlockStyle, FlutterQuillLocalizations, QuillEditor;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/book_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/features/files/book_search.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/book_providers.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 三章、正文够长的 EPUB：第三章里有一个只出现一次的专有词 `Nebuchadnezzar`，
/// 用来验证"整本搜索 + 跨章跳转"。
Uint8List _book() {
  final archive = Archive();
  void add(String name, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  add('OEBPS/content.opf', '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>进度之书</dc:title><dc:creator>作者</dc:creator>
  </metadata>
  <manifest>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="text/ch3.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/></spine>
</package>''');
  add('OEBPS/text/ch1.xhtml', '''
<html><body><h1>第一章 起点</h1><p>这是第一章的正文，包含关键词 alpha。</p></body></html>''');
  add('OEBPS/text/ch2.xhtml', '''
<html><body><h1>第二章 继续</h1><p>第二章开头。</p>
${List.generate(60, (i) => '<p>第二章第 ${i + 1} 段，铺长度用。</p>').join()}
</body></html>''');
  add('OEBPS/text/ch3.xhtml', '''
<html><body><h1>第三章 收尾</h1><p>这一章提到 beta 和 Nebuchadnezzar 两个词。</p>
<p>再来一次 beta 看看能不能搜到两处。</p></body></html>''');
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _comic() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
    'q842iQAAAABJRU5ErkJggg==',
  );
  final archive = Archive();
  var i = 0;
  for (final name in ['c1.png', 'c2.png', 'c3.png']) {
    archive.addFile(ArchiveFile(name, png.length, png));
    i++;
  }
  expect(i, 3);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/books/$name',
  isDir: false,
  size: 2048,
  mtime: 1700000000000,
);

/// 打开阅读页（内存库 + 假传输）
Future<({ProviderContainer c, ChatDatabase db})> _open(
  WidgetTester tester,
  String name,
  List<int> bytes, {
  String? bookKey,
  Key? stageKey,
}) async {
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
            key: stageKey,
            entry: _entry(name),
            bytesUrl: 'https://nas/x',
            bookKey: bookKey,
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
  return (c: c, db: db);
}

/// 打开"阅读工具"菜单并点其中一项
Future<void> _tool(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('阅读工具'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// 当前 PageView 停在第几页（`page` 在未 attach 时是 null）
double? _pagerPage(WidgetTester tester) {
  final pv = tester.widget<PageView>(
    find.byKey(const Key('book-chapter-pager')),
  );
  return pv.controller?.page;
}

void main() {
  group('BookStore（进度）', () {
    late ChatDatabase db;
    late BookStore store;

    setUp(() {
      db = ChatDatabase(NativeDatabase.memory());
      store = BookStore(db);
    });
    tearDown(() => db.close());

    test('写进度 → 读回来；同位置重复写不刷新时间', () async {
      await store.saveProgress(
        bookKey: 'fs:/a.epub',
        title: 'A',
        format: 'EPUB',
        chapter: 2,
        scroll: 0.5,
        chapterCount: 10,
        now: DateTime(2026, 1, 1),
      );
      final p = await store.progressOf('fs:/a.epub');
      expect(p, isNotNull);
      expect(p!.chapter, 2);
      expect(p.scroll, closeTo(0.5, 0.001));
      expect(p.chapterCount, 10);
      expect(p.updatedAt, DateTime(2026, 1, 1).millisecondsSinceEpoch);
      // 整本进度 = (2 + 0.5) / 10
      expect(p.percent, closeTo(0.25, 0.001));

      // 位置没变 → 不写（updatedAt 不变）
      await store.saveProgress(
        bookKey: 'fs:/a.epub',
        title: 'A',
        format: 'EPUB',
        chapter: 2,
        scroll: 0.5,
        chapterCount: 10,
        now: DateTime(2026, 6, 6),
      );
      final again = await store.progressOf('fs:/a.epub');
      expect(again!.updatedAt, DateTime(2026, 1, 1).millisecondsSinceEpoch);

      // 位置变了 → 写（时间更新）
      await store.saveProgress(
        bookKey: 'fs:/a.epub',
        title: 'A',
        format: 'EPUB',
        chapter: 3,
        scroll: 0,
        chapterCount: 10,
        now: DateTime(2026, 6, 6),
      );
      final moved = await store.progressOf('fs:/a.epub');
      expect(moved!.chapter, 3);
      expect(moved.updatedAt, DateTime(2026, 6, 6).millisecondsSinceEpoch);
    });

    test('最近在读按时间倒序，且能单独清掉', () async {
      for (final (i, key) in ['a', 'b', 'c'].indexed) {
        await store.saveProgress(
          bookKey: 'fs:/$key',
          title: key,
          format: 'EPUB',
          chapter: i,
          scroll: 0,
          chapterCount: 3,
          now: DateTime(2026, 1, 1 + i),
        );
      }
      final recent = await store.recent();
      expect(recent.map((e) => e.title).toList(), ['c', 'b', 'a']);
      await store.clearProgress('fs:/c');
      expect((await store.recent()).map((e) => e.title).toList(), ['b', 'a']);
    });

    test('书签：按章节+位置排序，批注可改，可删，可整本清', () async {
      final id2 = await store.addMark(
        bookKey: 'k',
        chapter: 2,
        scroll: 0.1,
        excerpt: '第二章的句子',
      );
      final id1 = await store.addMark(
        bookKey: 'k',
        chapter: 0,
        scroll: 0.9,
        excerpt: '第一章的句子',
      );
      // 别的书的书签不该串进来
      await store.addMark(
        bookKey: 'other',
        chapter: 0,
        scroll: 0,
        excerpt: 'x',
      );

      var marks = await store.marksOf('k');
      expect(marks.map((m) => m.id).toList(), [id1, id2]);
      expect(marks.first.excerpt, '第一章的句子');
      expect(marks.first.hasNote, isFalse);

      await store.setMarkNote(id1, '我的批注');
      marks = await store.marksOf('k');
      expect(marks.first.note, '我的批注');
      expect(marks.first.hasNote, isTrue);

      await store.deleteMark(id1);
      marks = await store.marksOf('k');
      expect(marks.length, 1);
      expect(marks.single.id, id2);

      await store.clearMarks('k');
      expect(await store.marksOf('k'), isEmpty);
      expect((await store.marksOf('other')).length, 1);
    });
  });

  group('searchBook（书内搜索）', () {
    final book = BookContent(
      format: BookFormat.epub,
      title: 't',
      chapters: [
        BookChapter(title: '一', html: '<p>here is Alpha</p>'),
        BookChapter(title: '二', html: '<p>nothing</p>'),
        BookChapter(
          title: '三',
          html: '<p>beta then Nebuchadnezzar then beta</p>',
        ),
      ],
    );

    test('跨章命中 + 片段标出命中词', () {
      final hits = searchBook(book, 'beta');
      expect(hits.length, 2);
      expect(hits.every((h) => h.chapter == 2), isTrue);
      expect(hits.first.snippet, contains('「beta」'));
      expect(hits.first.ratio, inInclusiveRange(0, 1));
      expect(hits[1].start, greaterThan(hits[0].start));
    });

    test('大小写不敏感；空词无结果；limit 生效', () {
      expect(searchBook(book, 'ALPHA').single.chapter, 0);
      expect(searchBook(book, '   '), isEmpty);
      expect(searchBook(book, 'e', limit: 2).length, 2);
    });

    test('位置比例与纯文本长度对得上（用于滚动估算）', () {
      final hits = searchBook(book, 'Nebuchadnezzar');
      expect(hits.length, 1);
      final text = 'beta then Nebuchadnezzar then beta';
      expect(
        hits.single.ratio,
        closeTo(text.indexOf('Neb') / text.length, 0.001),
      );
    });
  });

  group('阅读页（进度 / 书签 / 搜索 / 外观）', () {
    testWidgets('打开时恢复上次读到的章节', (tester) async {
      final bytes = _book();
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
      // 先写一条"读到第二章"的进度
      await BookStore(db).saveProgress(
        bookKey: 'fs:/books/x.epub',
        title: '进度之书',
        format: 'EPUB',
        chapter: 1,
        scroll: 0,
        chapterCount: 3,
      );
      // ⚠️ **故意不预热 provider**：真机冷启动就是"进度还没读回来页面先画出来"，
      // 以前页面只读 `.value` → 永远恢复不了（测试预热过，反而一直是绿的）
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: FileBookStage(
                entry: _entry('x.epub'),
                bytesUrl: 'https://nas/x',
                bookKey: 'fs:/books/x.epub',
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
      await tester.pump(const Duration(milliseconds: 300));
      // 页脚显示"第 2/3 章"（1 基）
      expect(find.textContaining('第 2/3 章'), findsOneWidget);
    });

    testWidgets('翻章就落库（只翻不滚也要有进度）', (tester) async {
      final bytes = _book();
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
                entry: _entry('y.epub'),
                bytesUrl: 'https://nas/y',
                bookKey: 'fs:/books/y.epub',
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
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('下一章'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('第 2/3 章'), findsOneWidget);

      final saved = await BookStore(db).progressOf('fs:/books/y.epub');
      expect(saved, isNotNull, reason: '翻章也要写进度，不然重开永远回第一章');
      expect(saved!.chapter, 1);
    });

    testWidgets('工具菜单 → 书内搜索 → 命中跨章，点结果跳到那一章', (tester) async {
      final r = await _open(tester, 'x.epub', _book());
      await _tool(tester, '书内搜索');
      await tester.enterText(
        find.byKey(const Key('book-search-field')),
        'Nebuchadnezzar',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('book-search-list')), findsOneWidget);
      expect(find.textContaining('「Nebuchadnezzar」'), findsOneWidget);
      expect(find.textContaining('第 3 章'), findsWidgets);

      await tester.tap(find.textContaining('「Nebuchadnezzar」'));
      await tester.pumpAndSettle();
      expect(find.textContaining('第 3/3 章'), findsOneWidget);
      // ⚠️ 页脚是"当前索引"，不代表 pager 真的动了 —— 只断言页脚会漏掉
      // "跳章后正文还停在原来那一章"这个 bug（真机上被截图抓到过）
      expect(_pagerPage(tester), 2, reason: '跳章必须真的把 PageView 翻过去，而不只是改页脚');
      // 换章那一帧旧页还会报一次 scroll(0)，不能把进度写回第 1 章
      final saved = await BookStore(r.db).progressOf('fs:/books/x.epub');
      expect(saved?.chapter, 2, reason: '跳章后的进度必须是目标章');
    });

    testWidgets('DA202 搜索空态提示必须带水平内边距（不许贴屏边）', (tester) async {
      // 真机 r610：这两句提示原来由裸 `Center(child: Text)` 画，
      // 1148 px 宽上文字**从 x=1 起、右端被裁到 1125** —— 贴着屏幕边缘。
      //
      // ★ 判据写了两遍才对：
      //   ① 先写"量 Text 矩形离屏幕边 ≥16" —— **反向验证不咬**：
      //      宿主里这句提示只有 283 px 宽、居中放着，根本没贴边；
      //      钉成 375 宽后它**仍是一行**（17 px 高），还是贴不到边。
      //   ② 所以判据落在**规则**上：空态文案外层必须有 ≥16 的水平内边距。
      //      这既能咬住"裸 Center"，也不依赖字体/断行这种宿主与真机不同的东西。
      await _open(tester, 'x.epub', _book());
      await _tool(tester, '书内搜索');
      await tester.pumpAndSettle();

      var checked = 0;
      for (final finder in [
        find.textContaining('这一章'),
        find.textContaining('this chapter'),
      ]) {
        if (finder.evaluate().isEmpty) continue;
        checked++;

        // 往上找一圈，必须有水平内边距（`_PaddedCenter` 就是为这件事加的）
        var padded = false;
        var found = false;
        tester.element(finder).visitAncestorElements((el) {
          final w = el.widget;
          if (w is Padding && w.padding.horizontal >= Gap.lg - 0.01) {
            padded = true;
            found = true;
            return false;
          }
          return true;
        });
        expect(found, isTrue, reason: 'padding 没找到，用例本身错了');
        expect(padded, isTrue, reason: '空态提示外层没有任何水平内边距 ⇒ 真机上会贴屏边');

        // 而且文案本身不许超出可用宽度（内边距生效时这条必然成立）
        final rect = tester.getRect(finder);
        final screen = tester.getRect(find.byType(MaterialApp));
        expect(
          rect.left - screen.left,
          greaterThanOrEqualTo(Gap.lg - 0.01),
          reason: '左边距不足：left=${rect.left}，容器=${screen.left}',
        );
        expect(
          screen.right - rect.right,
          greaterThanOrEqualTo(Gap.lg - 0.01),
          reason: '右边距不足：right=${rect.right}，容器=${screen.right}',
        );
      }
      expect(checked, greaterThan(0), reason: '一句空态提示都没找到，用例没落在地上');
    });

    testWidgets('工具菜单 → 加书签 → 列表里出现，可删除', (tester) async {
      final r = await _open(tester, 'x.epub', _book());
      await _tool(tester, '书签 / 划线');
      expect(find.text('还没有书签'), findsOneWidget);

      await tester.tap(find.byKey(const Key('book-mark-add')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const Key('book-mark-list')), findsOneWidget);
      expect(find.text('还没有书签'), findsNothing);

      // 数据库里确实有一条
      final marks = await BookStore(r.db).marksOf('fs:/books/x.epub');
      expect(marks.length, 1);
      expect(marks.single.chapter, 0);
      expect(marks.single.excerpt, isNotEmpty);
    });

    testWidgets('阅读设置：字号加减落到设置里，行距/背景可切', (tester) async {
      final r = await _open(tester, 'x.epub', _book());
      await _tool(tester, '阅读设置');
      expect(find.text('16 px'), findsOneWidget);

      await tester.tap(find.byKey(const Key('book-font-bigger')));
      await tester.pumpAndSettle();
      expect(find.text('18 px'), findsOneWidget);
      expect(await r.c.read(settingsServiceProvider).readerFontSize(), 18);

      await tester.tap(find.byKey(const Key('book-font-smaller')));
      await tester.pumpAndSettle();
      expect(find.text('16 px'), findsOneWidget);
      expect(await r.c.read(settingsServiceProvider).readerFontSize(), 16);

      await tester.tap(find.text('1.7'));
      await tester.pumpAndSettle();
      expect(await r.c.read(settingsServiceProvider).readerLineHeight(), 1.7);

      await tester.tap(find.text('护眼'));
      await tester.pumpAndSettle();
      expect(await r.c.read(settingsServiceProvider).readerTheme(), 'sepia');
    });

    testWidgets('DA205 夜间模式的正文墨色必须跟着纸色翻过来（≥4.5:1）', (tester) async {
      // 真机 r614（Files → book.epub → 阅读设置 → Night）：纸变成 #0B0B0C，
      // 正文却还是亮色档的墨色 #0F172A ⇒ **1.10:1**，几乎看不见。
      // 根因：`DefaultStyles.getInstance(context)` 取的是外层亮色主题，
      // 块样式里已经写死墨色，外层那圈 `Theme(bodyColor:)` 改不动它。
      await _open(tester, 'x.epub', _book());
      await _tool(tester, '阅读设置');
      await tester.tap(find.text('夜间'));
      await tester.pumpAndSettle();

      final colors = readerColorsOf('night')!;
      final paper = Color(colors.bg);
      final ink = Color(colors.fg!);

      // ① 每一个可见文字的最终颜色都要与纸色算得上话
      var checked = 0;
      for (final el in find.byType(Text).evaluate()) {
        final w = el.widget as Text;
        final style = w.style ?? DefaultTextStyle.of(el).style;
        final color = style.color;
        if (color == null) continue;
        final ratio = DesignPalette.contrastRatio(color, paper);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: '「${w.data}」在夜间纸上只有 ${ratio.toStringAsFixed(2)}:1',
        );
        checked++;
      }
      expect(checked, greaterThan(0), reason: '一个字都没量到');

      // ② 编辑器自己的块样式必须真的带夜间墨色
      //    （只断言外层 Theme 不够：`DefaultStyles` 早就在**外层**亮色主题上算好颜色，
      //     这正是这条缺陷的根因）
      final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
      final styles = editor.config.customStyles!;
      for (final block in <DefaultTextBlockStyle?>[
        styles.h1,
        styles.h2,
        styles.h3,
        styles.paragraph,
        styles.quote,
      ]) {
        expect(
          block?.style.color,
          ink,
          reason: '块样式没换成夜间墨色：${block?.style.color}',
        );
      }
      expect(
        DesignPalette.contrastRatio(ink, paper),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('目录面板能按标题筛，筛不到给提示', (tester) async {
      await _open(tester, 'x.epub', _book());
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-toc-list')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('book-toc-filter')), '第三章');
      await tester.pumpAndSettle();
      expect(find.text('1/3 条'), findsOneWidget);
      // ⚠️ 只断言**目录列表里**的条目：页脚也会显示当前章标题（"第一章 起点"），
      // 直接 find.text 会把页脚那条也算进来。
      Finder inToc(String t) => find.descendant(
        of: find.byKey(const Key('book-toc-list')),
        matching: find.text(t),
      );
      expect(inToc('第三章 收尾'), findsOneWidget);
      expect(inToc('第一章 起点'), findsNothing);

      await tester.enterText(find.byKey(const Key('book-toc-filter')), '不存在');
      await tester.pumpAndSettle();
      expect(find.text('目录里没有「不存在」'), findsOneWidget);

      // 点目录条目跳章：pager 要真的翻过去（和搜索跳章同一个坑）
      await tester.enterText(find.byKey(const Key('book-toc-filter')), '第三章');
      await tester.pumpAndSettle();
      await tester.tap(inToc('第三章 收尾'));
      await tester.pumpAndSettle();
      expect(find.textContaining('第 3/3 章'), findsOneWidget);
      expect(_pagerPage(tester), 2, reason: '目录跳章也要真的翻页');
    });

    testWidgets('CBZ 翻页也记进度（按页数）', (tester) async {
      final r = await _open(tester, 'c.cbz', _comic());
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));

      final p = await BookStore(r.db).progressOf('fs:/books/c.cbz');
      expect(p, isNotNull);
      expect(p!.format, 'CBZ');
      // 3 页，翻到第 2 页 = 2/3
      expect(p.scroll, closeTo(2 / 3, 0.01));
    });
  });
}
