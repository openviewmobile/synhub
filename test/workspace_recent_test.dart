// 工作台「最近常用」+ 阅读器「继续阅读」离线测试（阶段一收尾）。
//
// 三层：
//   * 存储与纯函数 —— `recordWorkspaceRecent` / `decodeWorkspaceRecent` /
//     `WorkspaceRecentNotifier`（去重、倒序、上限、容错、冷启动恢复）；
//   * 导航参数 —— `bookEntryForResume` / `bookProgressLabel`（重开一本书要喂给
//     阅读器的路径/扩展名/直链）；
//   * 页面（widget）—— 空态整块隐藏、最近常用卡片顺序、点按导航、继续阅读恢复进度。
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

import 'package:synhub/l10n/gen/app_localizations_zh.dart'
    show AppTextZh;
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/book_store.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/calendar/calendar_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/book_resume.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/notes/notes_page.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';
import 'package:synhub/src/features/shell/workspace_providers.dart'
    show kWorkspaceUsageKey;
import 'package:synhub/src/features/shell/workspace_recent.dart';

import 'support/chat_harness.dart' show FakeTransport, bootChat;

/// 三章的小 EPUB（只为了"恢复到第 2 章"这件事）
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
    <dc:title>继续阅读之书</dc:title><dc:creator>作者</dc:creator>
  </metadata>
  <manifest>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="text/ch3.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/></spine>
</package>''');
  add(
    'OEBPS/text/ch1.xhtml',
    '<html><body><h1>第一章</h1><p>开头。</p></body></html>',
  );
  add(
    'OEBPS/text/ch2.xhtml',
    '<html><body><h1>第二章</h1>${List.generate(40, (i) => '<p>第 ${i + 1} 段。</p>').join()}</body></html>',
  );
  add(
    'OEBPS/text/ch3.xhtml',
    '<html><body><h1>第三章</h1><p>收尾。</p></body></html>',
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 打开工作台（真机比例，避免磁贴被挤成好几屏）
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  String? seedRecent,
  String? seedUsage,
  List<({String key, String title, int chapter, double scroll})> books =
      const [],
  List<Object> overrides = const [],
  Size physical = const Size(1148, 2492),
}) async {
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  if (seedRecent != null) {
    await ChatStore(db).setSetting(kWorkspaceRecentKey, seedRecent);
  }
  if (seedUsage != null) {
    await ChatStore(db).setSetting(kWorkspaceUsageKey, seedUsage);
  }
  for (final b in books) {
    await BookStore(db).saveProgress(
      bookKey: b.key,
      title: b.title,
      format: 'EPUB',
      chapter: b.chapter,
      scroll: b.scroll,
      chapterCount: 3,
    );
  }
  final container = ProviderContainer(
    overrides: <Object>[
      chatDatabaseProvider.overrideWithValue(db),
      ...overrides,
    ].cast(),
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const WorkspaceTab(),
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
  await container.read(workspaceRecentProvider.notifier).preload();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

/// 当前 PageView 停在第几页（`page` 未 attach 时是 null）
double? _pagerPage(WidgetTester tester) {
  final pv = tester.widget<PageView>(
    find.byKey(const Key('book-chapter-pager')),
  );
  return pv.controller?.page;
}

void main() {
  group('「最近常用」存储（纯函数）', () {
    test('记一次 = 放到最前；多次记录按时间倒序', () {
      var list = recordWorkspaceRecent(const [], 'notes', 100);
      list = recordWorkspaceRecent(list, 'files', 200);
      expect([for (final e in list) e.id], ['files', 'notes']);
      expect([for (final e in list) e.at], [200, 100]);
    });

    test('同一模块只留最新一条（去重，不是累加）', () {
      var list = recordWorkspaceRecent(const [], 'notes', 100);
      list = recordWorkspaceRecent(list, 'files', 200);
      list = recordWorkspaceRecent(list, 'notes', 300);
      expect([for (final e in list) e.id], ['notes', 'files']);
      expect(list.first.at, 300);
      expect(list, hasLength(2));
    });

    test('时间相同也不乱：后记的在前（稳定排序）', () {
      var list = recordWorkspaceRecent(const [], 'a', 100);
      list = recordWorkspaceRecent(list, 'b', 100);
      list = recordWorkspaceRecent(list, 'c', 100);
      expect([for (final e in list) e.id], ['c', 'b', 'a']);
    });

    test('超过上限只留最新的 N 条', () {
      var list = <WorkspaceRecent>[];
      for (var i = 0; i < 25; i++) {
        list = recordWorkspaceRecent(list, 'm$i', i);
      }
      expect(list, hasLength(kWorkspaceRecentLimit));
      expect(list.first.id, 'm24');
      expect(list.last.id, 'm${25 - kWorkspaceRecentLimit}');
    });

    test('空 id 不记（不会污染列表）', () {
      final list = recordWorkspaceRecent(const [], '  ', 1);
      expect(list, isEmpty);
    });

    test('decode：正常 JSON 会重排 + 去重 + 截断', () {
      final raw = jsonEncode([
        {'id': 'a', 'at': 1},
        {'id': 'b', 'at': 3},
        {'id': 'a', 'at': 5},
        {'id': 'c', 'at': 2},
      ]);
      final list = decodeWorkspaceRecent(raw);
      expect([for (final e in list) e.id], ['a', 'b', 'c']);
      expect(list.first.at, 5);
    });

    test('decode：垃圾/非数组/缺字段都不炸，坏条目直接丢', () {
      expect(decodeWorkspaceRecent(null), isEmpty);
      expect(decodeWorkspaceRecent(''), isEmpty);
      expect(decodeWorkspaceRecent('不是 JSON'), isEmpty);
      expect(decodeWorkspaceRecent('{"a":1}'), isEmpty);
      expect(decodeWorkspaceRecent('[{"at":1}]'), isEmpty);
      expect(decodeWorkspaceRecent('[{"id":"a"}]'), isEmpty);
      expect(decodeWorkspaceRecent('[{"id":"a","at":-1}]'), isEmpty);
      // 数字串认；空 id 丢
      expect(decodeWorkspaceRecent('[{"id":"a","at":"7"},{"id":"","at":1}]'), [
        const WorkspaceRecent(id: 'a', at: 7),
      ]);
    });

    test('encode/decode 往返一致', () {
      final list = [
        const WorkspaceRecent(id: 'calendar', at: 42),
        const WorkspaceRecent(id: 'notes', at: 7),
      ];
      expect(decodeWorkspaceRecent(encodeWorkspaceRecent(list)), list);
    });

    test('record 落库，冷启动 preload 能恢复', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(c.dispose);
      await c
          .read(workspaceRecentProvider.notifier)
          .record('notes', now: DateTime(2026, 1, 1));
      await c
          .read(workspaceRecentProvider.notifier)
          .record('files', now: DateTime(2026, 1, 2));
      expect(
        [for (final e in c.read(workspaceRecentProvider)) e.id],
        ['files', 'notes'],
      );

      final fresh = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(fresh.dispose);
      await fresh.read(workspaceRecentProvider.notifier).preload();
      expect(
        [for (final e in fresh.read(workspaceRecentProvider)) e.id],
        ['files', 'notes'],
      );

      await fresh.read(workspaceRecentProvider.notifier).clear();
      expect(fresh.read(workspaceRecentProvider), isEmpty);
      expect(await ChatStore(db).setting(kWorkspaceRecentKey), '');
    });

    test('Zzz 旧值/坏值 preload 不炸', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await ChatStore(db).setSetting(kWorkspaceRecentKey, '坏数据');
      final c = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(c.dispose);
      await c.read(workspaceRecentProvider.notifier).preload();
      expect(c.read(workspaceRecentProvider), isEmpty);
    });
  });

  group('继续阅读：进度 → 阅读器参数（纯函数）', () {
    BookProgress progress({
      String key = 'fs:/books/x.epub',
      String title = '进度之书',
      String format = 'EPUB',
      int chapter = 1,
      double scroll = 0,
      int count = 3,
      String url = '',
    }) => BookProgress(
      bookKey: key,
      title: title,
      format: format,
      chapter: chapter,
      scroll: scroll,
      chapterCount: count,
      updatedAt: 0,
      sourceUrl: url,
    );

    test('FileStation 来源：路径还原成 path，扩展名从文件名来', () {
      final e = bookEntryForResume(progress());
      expect(e.path, '/books/x.epub');
      expect(e.name, 'x.epub');
      expect(e.extension, 'epub');
    });

    test('Drive 来源：path 用 bookKey 本身，扩展名从 format 补', () {
      final e = bookEntryForResume(
        progress(key: 'drive:ABCDEF', title: '在驱动上的书', url: 'https://nas/d'),
      );
      expect(e.path, 'drive:ABCDEF');
      expect(e.name, '在驱动上的书.epub');
      expect(e.extension, 'epub');
    });

    test('书名空 / 格式空时的回落也不崩', () {
      final e = bookEntryForResume(
        progress(key: 'drive:Z', title: '  ', format: ''),
      );
      expect(e.name, 'drive:Z');
      expect(e.extension, '');
    });

    test('章节文案：1 基 + 百分比（章数未知只给百分比）', () {
      final t = AppTextZh();
      expect(
        bookProgressLabel(t, progress(chapter: 1, count: 3)),
        contains('第 2/3 章'),
      );
      expect(bookProgressLabel(t, progress(chapter: 1, count: 0)), '已读 0%');
      // ★ r316c：漫画这类**没有章**的书（`chapterCount == 0`）原来恒 0%，
      // 读到第 3/4 页冷启动卡片还写「0% read」⇒ 章数未知时用 `scroll` 当百分比。
      expect(
        bookProgressLabel(
          t,
          progress(key: 'fs:/books/c.cbr', format: 'CBR', chapter: 0, scroll: 0.75, count: 0),
        ),
        '已读 75%',
      );
      expect(
        bookProgressLabel(t, progress(chapter: 1, scroll: 0.5, count: 4)),
        contains('38%'),
      );
    });
  });

  group('BookStore：进度里的"重开定位串"', () {
    test('Drive 直链会随进度落库，重复写同位置也不会丢', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = BookStore(db);
      await store.saveProgress(
        bookKey: 'drive:AAAA',
        title: '驱动书',
        format: 'EPUB',
        chapter: 1,
        scroll: 0.2,
        chapterCount: 5,
        sourceUrl: 'https://nas/d/f/AAAA',
        now: DateTime(2026, 1, 1),
      );
      final p = await store.progressOf('drive:AAAA');
      expect(p!.sourceUrl, 'https://nas/d/f/AAAA');
      // 同位置再写（不带直链）→ 直链保留（只增不减）
      await store.saveProgress(
        bookKey: 'drive:AAAA',
        title: '驱动书',
        format: 'EPUB',
        chapter: 1,
        scroll: 0.2,
        chapterCount: 5,
        now: DateTime(2026, 2, 2),
      );
      expect(
        (await store.progressOf('drive:AAAA'))!.sourceUrl,
        'https://nas/d/f/AAAA',
      );
      // 最近在读也带上它
      final recent = await store.recent();
      expect(recent.single.sourceUrl, 'https://nas/d/f/AAAA');
    });
  });

  group('工作台页面：最近常用', () {
    testWidgets('没有任何记录时整块隐藏（不留空白）', (tester) async {
      await _pump(tester);
      expect(find.text('最近常用'), findsNothing);
      expect(find.text('继续阅读'), findsNothing);
      expect(find.byKey(const Key('ws-recent-list')), findsNothing);
      expect(find.byKey(const Key('ws-continue-list')), findsNothing);
      // 启动器本身照常
      expect(find.text('文件'), findsOneWidget);
    });

    testWidgets('有记录就出横滑条，顺序 = 最近使用的倒序', (tester) async {
      await _pump(
        tester,
        seedRecent: jsonEncode([
          {'id': 'calendar', 'at': 100},
          {'id': 'notes', 'at': 300},
          {'id': 'files', 'at': 200},
        ]),
      );
      expect(find.text('最近常用'), findsOneWidget);
      expect(find.byKey(const Key('ws-recent-list')), findsOneWidget);
      final notes = tester.getTopLeft(find.byKey(const Key('ws-recent-notes')));
      final files = tester.getTopLeft(find.byKey(const Key('ws-recent-files')));
      final calendar = tester.getTopLeft(
        find.byKey(const Key('ws-recent-calendar')),
      );
      expect(notes.dx, lessThan(files.dx));
      expect(files.dx, lessThan(calendar.dx));
    });

    testWidgets('聊天也能出现在最近常用里（不在网格但可点）', (tester) async {
      final c = await _pump(
        tester,
        seedRecent: jsonEncode([
          {'id': 'chat', 'at': 500},
        ]),
      );
      expect(find.byKey(const Key('ws-recent-chat')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ws-recent-chat')));
      await tester.pump();
      expect(c.read(appTabProvider), AppTab.chat);
    });

    testWidgets('点最近的模块卡：跳过去 + 记一次 + 浮到最前', (tester) async {
      final c = await _pump(
        tester,
        seedRecent: jsonEncode([
          {'id': 'notes', 'at': 100},
          {'id': 'calendar', 'at': 200},
        ]),
      );
      await tester.tap(find.byKey(const Key('ws-recent-notes')));
      await tester.pumpAndSettle();
      expect(find.byType(NotesPage), findsOneWidget);
      // 回来后 notes 应该已经是最新的
      expect(c.read(workspaceRecentProvider).first.id, 'notes');
    });

    testWidgets('点最近的"日历"卡直达日历页', (tester) async {
      await _pump(
        tester,
        seedRecent: jsonEncode([
          {'id': 'calendar', 'at': 100},
        ]),
      );
      await tester.tap(find.byKey(const Key('ws-recent-calendar')));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarPage), findsOneWidget);
    });

    testWidgets('从网格点模块也会记进最近常用（真的打开才算）', (tester) async {
      final c = await _pump(tester);
      expect(c.read(workspaceRecentProvider), isEmpty, reason: '刚渲染不算打开');
      await tester.tap(find.text('日历'));
      await tester.pumpAndSettle();
      expect(c.read(workspaceRecentProvider).first.id, 'calendar');
    });

    testWidgets('搜索时不留动态分区', (tester) async {
      await _pump(
        tester,
        seedRecent: jsonEncode([
          {'id': 'notes', 'at': 100},
        ]),
      );
      expect(find.byKey(const Key('ws-recent-list')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('ws-search')), '日');
      await tester.pump();
      expect(find.byKey(const Key('ws-recent-list')), findsNothing);
    });

    testWidgets('被"收起"的模块仍能出现在最近常用（最近 = 意图，不受收起影响）', (tester) async {
      await _pump(
        tester,
        seedRecent: jsonEncode([
          {'id': 'photos', 'at': 100},
        ]),
      );
      expect(find.byKey(const Key('ws-recent-photos')), findsOneWidget);
    });
  });

  group('工作台页面：继续阅读', () {
    testWidgets('有进度就出卡片：书名 + 第几章/百分比', (tester) async {
      await _pump(
        tester,
        books: [
          (key: 'fs:/books/x.epub', title: '进度之书', chapter: 1, scroll: 0.5),
        ],
      );
      expect(find.text('继续阅读'), findsOneWidget);
      expect(find.byKey(const Key('ws-continue-list')), findsOneWidget);
      expect(find.text('进度之书'), findsWidgets);
      // (1 + 0.5) / 3 = 50%
      expect(find.textContaining('第 2/3 章 · 50%'), findsOneWidget);
    });

    testWidgets('点卡片直接开阅读器，并恢复到上次那一章', (tester) async {
      final transport = FakeTransport(const {}, {...FakeTransport.table});
      transport.downloadBytes = _book();
      final api = DsmWebApi(transport);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      await _pump(
        tester,
        books: [
          (key: 'fs:/books/x.epub', title: '进度之书', chapter: 1, scroll: 0),
        ],
        overrides: [fileApiProvider.overrideWithValue(FileStationApi(api))],
      );
      await tester.tap(find.byKey(const Key('ws-continue-fs:/books/x.epub')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      // 页脚 1 基显示第 2/3 章 = 真的恢复到了上次那一章
      expect(find.textContaining('第 2/3 章'), findsWidgets);
      expect(_pagerPage(tester), 1);
    });

    testWidgets('Drive 的书：把落库的直链喂给阅读器（不用再查目录）', (tester) async {
      final transport = FakeTransport(const {}, {...FakeTransport.table});
      transport.downloadBytes = _book();
      final api = DsmWebApi(transport);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await BookStore(db).saveProgress(
        bookKey: 'drive:LINK1',
        title: '驱动上的书',
        format: 'EPUB',
        chapter: 1,
        scroll: 0,
        chapterCount: 3,
        sourceUrl: 'https://nas/d/f/LINK1',
      );
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
            home: const WorkspaceTab(),
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
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('ws-continue-drive:LINK1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final stage = tester.widget<FileBookStage>(find.byType(FileBookStage));
      expect(stage.bookKey, 'drive:LINK1');
      expect(stage.bytesUrl, 'https://nas/d/f/LINK1');
      expect(stage.entry.path, 'drive:LINK1');
      expect(stage.entry.extension, 'epub');
    });
  });

  group('底栏 tab 也算"打开过"', () {
    testWidgets('切到聊天/文件会记进最近常用（初始默认 tab 不算）', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: const MaterialApp(home: AppShellPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        h.container.read(workspaceRecentProvider),
        isEmpty,
        reason: '冷启动落在聊天 tab 不是"用户打开"',
      );
      await tester.tap(find.byIcon(Icons.folder_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.container.read(workspaceRecentProvider).first.id, 'files');
      await tester.tap(find.byIcon(Icons.forum_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.container.read(workspaceRecentProvider).first.id, 'chat');
    });
  });
}
