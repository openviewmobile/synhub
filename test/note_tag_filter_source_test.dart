// ★★★ r131（macOS 逐屏走查 D18）：**标签筛选的数据源必须与渲染标签的数据源是同一份**。
//
// 缺陷现场（真机像素，`docs/platform-macos-ui-audit.md` §1.1 第 46 行 / §3 D18）：
//   * `n11_note_view.png`：同一条笔记正文页带标签芯片 `test`；
//   * `n12_note_info.png`：信息页写 `Tags / test`；
//   * `n16_note_tag_filter.png`：点标签筛选却提示 `No tags yet`。
// ⇒ 界面与自己渲染的数据**互相打架**：筛选读服务端 `Tag:list`，渲染读笔记自带 `tags`，
//   服务端那份为空/失败时（`noteTagsProvider.value ?? []` 把错误也吞成"空"）就说"没标签"。
// 修法：`noteAllTagsProvider` = **服务端标签 ∪ 已加载笔记自带的标签**（§2.0.26 第 2 条），
//   并且把"取不到"与"没有"分开（前者换一句提示，不许说成 `No tags yet`）。
//
// 本文件的正/反用例（缺一不可）：
//   ① 服务端标签为空、笔记带 `test` ⇒ 筛选**必须**给出 `test`（这是缺陷本体）；
//   ② 服务端有标签、笔记没带 ⇒ 也要能给（不能只看笔记）；
//   ③ **两边都没有标签时 `No tags yet` 必须照旧出现** —— 不许把空态删掉（§2.0.29①）；
//   ④ 去重 + 排序（同一语义不许两份表示）；
//   ⑤ 服务端**失败**而笔记带标签 ⇒ 仍然给得出，但 `serverFailed=true`（不谎报"没有"）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/data/local/note_store.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/notes_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _noteTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.NoteStation.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Tag': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Map<String, dynamic> _apiNote(String id, String title, List<String> tags) => {
  'object_id': id,
  'title': title,
  'parent_id': 'nb1',
  'brief': '',
  'mtime': 1000,
  'ctime': 500,
  'ver': '1.0',
  'recycle': false,
  'encrypt': false,
  'has_content': true,
  // ★ 键是**单数** `tag`：`NoteDto.fromJson` 读的就是 `j['tag']`（NAS 的形态）。
  //   写成 `tags` 会让"笔记自带的标签"永远解析成空 —— 那正是 D18 的另一半根因。
  'tag': tags,
  'attachment': <String, dynamic>{},
};

Map<String, dynamic> _tag(String id, String title) => {
  'tag_id': id,
  'title': title,
  'note_count': 1,
};

Future<
  ({FakeTransport t, ProviderContainer c, NoteStore store})
>
_boot({
  required List<Map<String, dynamic>> tags,
  required List<Map<String, dynamic>> notes,
  bool tagApiFails = false,
  bool offline = false,
}) async {
  final t = FakeTransport({
    'SYNO.NoteStation.Note.list': {'notes': notes, 'total': notes.length},
    'SYNO.NoteStation.Notebook.list': {
      'notebooks': [
        {'object_id': 'nb1', 'title': 'My notebook', 'preset': false},
      ],
    },
    // ★ 注意：真机像素里服务端标签列表就是**空**的 —— 用例①正是这个形态。
    'SYNO.NoteStation.Tag.list': {'tags': tags},
  }, {...FakeTransport.table, ..._noteTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = NoteStore(db);
  final c = ProviderContainer(
    overrides: [
      // offline：没有 api ⇒ `noteListProvider` / `noteTagFilteredListProvider`
      // 走**本地缓存回落**那条路（G4 的本地 AND/OR 过滤就是在这里生效的）。
      noteApiProvider.overrideWithValue(offline ? null : NoteStationApi(api)),
      chatDatabaseProvider.overrideWithValue(db),
      if (tagApiFails)
        noteTagsProvider.overrideWith(
          (ref) async => throw StateError('tag api down'),
        ),
    ],
  );
  addTearDown(c.dispose);
  return (t: t, c: c, store: store);
}

Future<List<String>> _allTags(ProviderContainer c) async =>
    (await c.read(noteAllTagsProvider.future)).tags;

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: child,
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
  await tester.pump(const Duration(milliseconds: 120));
}

/// 打开标签筛选面板。窄屏下入口可能被折进 `⋮`（§2.0.10③），
/// 所以先试直接点图标，点不到再走溢出菜单里那个同名项。
Future<void> _openTagFilter(WidgetTester tester) async {
  final entry = find.byKey(const Key('note-tag-filter-entry'));
  if (entry.hitTestable().evaluate().isNotEmpty) {
    await tester.tap(entry, warnIfMissed: false);
  } else {
    await tester.tap(find.byIcon(Icons.more_vert).first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(
      find.byKey(const Key('note-tag-filter-menu')),
      warnIfMissed: false,
    );
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('D18 标签筛选数据源（provider 级）', () {
    test('① 服务端标签为空、笔记自带 test ⇒ 筛选必须给得出 test（缺陷本体）', () async {
      final b = await _boot(
        tags: const [],
        notes: [_apiNote('n1', 'test', ['test'])],
      );
      await b.c.read(noteListProvider.future);
      expect(await _allTags(b.c), ['test']);
      // 反向（旧写法）：只看服务端那一份 ⇒ 空 ⇒ 界面会说 `No tags yet`。
      final legacy = (await b.c.read(noteTagsProvider.future))
          .map((t) => t.title)
          .toList();
      expect(legacy, isEmpty, reason: '旧写法必须被判为"没有标签"');
    });

    test('② 服务端有标签、笔记没带 ⇒ 照样能筛（不能只看笔记自带）', () async {
      final b = await _boot(
        tags: [_tag('t1', 'work')],
        notes: [_apiNote('n1', 'a', const [])],
      );
      expect(await _allTags(b.c), ['work']);
    });

    test('③ 两边都没有标签 ⇒ 结果为空（`No tags yet` 才会出现，见 UI 用例）', () async {
      final b = await _boot(
        tags: const [],
        notes: [_apiNote('n1', 'a', const [])],
      );
      expect(await _allTags(b.c), isEmpty);
    });

    test('④ 去重 + 排序 + 去空白：同一标签不出现两次', () async {
      final b = await _boot(
        tags: [_tag('t1', 'work'), _tag('t2', 'test'), _tag('t3', '  ')],
        notes: [_apiNote('n1', 'a', ['test', 'zz', ''])],
      );
      expect(await _allTags(b.c), ['test', 'work', 'zz']);
    });

    test('⑤ 服务端标签接口**失败**、笔记带标签 ⇒ 仍给得出，且标记"没取到"', () async {
      final b = await _boot(
        tags: const [],
        notes: [_apiNote('n1', 'a', ['test'])],
        tagApiFails: true,
      );
      final src = await b.c.read(noteAllTagsProvider.future);
      expect(src.tags, ['test']);
      expect(src.serverFailed, isTrue, reason: '"取不到"不许静默成"没有"');
    });
  });

  group('D18 筛选结果：带该标签的必须出现、不带该标签的必须不出现', () {
    NoteDto note(String id, List<String> tags) =>
        NoteDto(objectId: id, title: id, tags: tags);

    test('① AND 单标签：带 test 的出现，不带的消失', () {
      final notes = [
        note('n1', ['test']),
        note('n2', ['other']),
        note('n3', ['test', 'work']),
      ];
      final r = filterNotesByTags(notes, ['test'], NoteStationApi.tagOperatorAnd);
      expect(r.map((n) => n.objectId), ['n1', 'n3']);
      expect(
        r.any((n) => n.objectId == 'n2'),
        isFalse,
        reason: '不带 test 的笔记**必须不出现**',
      );
    });

    test('② AND 多标签：差一个标签就必须不出现', () {
      final notes = [
        note('n1', ['test', 'work']),
        note('n2', ['test']),
        note('n3', ['work']),
      ];
      final r = filterNotesByTags(
        notes,
        ['test', 'work'],
        NoteStationApi.tagOperatorAnd,
      );
      expect(r.map((n) => n.objectId), ['n1']);
    });

    test('③ OR：含其一即留下（这是"另一套语义"，不能被 AND 顺手改掉）', () {
      final notes = [
        note('n1', ['test']),
        note('n2', ['work']),
        note('n3', ['nope']),
      ];
      final r = filterNotesByTags(notes, ['test', 'work'], 'or');
      expect(r.map((n) => n.objectId), ['n1', 'n2']);
      expect(r.any((n) => n.objectId == 'n3'), isFalse);
    });

    test('④ provider 级（离线回落）：筛 test 时列表里只剩带 test 的那条', () async {
      final b = await _boot(
        tags: const [],
        notes: const [],
        offline: true,
      );
      await b.store.mergeNoteList([
        note('n1', ['test']),
        note('n2', ['other']),
      ]);
      b.c.read(noteFilterTagsProvider.notifier).set(['test']);
      final r = await b.c.read(noteTagFilteredListProvider.future);
      expect(r.notes.map((n) => n.objectId), ['n1']);
      // 反向：筛一个谁都没有的标签 ⇒ 必须是空列表，**不许**退回"全部"
      b.c.read(noteFilterTagsProvider.notifier).set(['nobody-has-this']);
      final empty = await b.c.read(noteTagFilteredListProvider.future);
      expect(empty.notes, isEmpty);
    });
  });

  group('D18 标签筛选（UI 级）', () {
    testWidgets('① 笔记带 test 时：面板列出 test，且**不**出现 No tags yet', (tester) async {
      final b = await _boot(
        tags: const [],
        notes: [_apiNote('n1', 'test', ['test'])],
      );
      await _pump(tester, b.c, const NotesPage());
      await tester.pump(const Duration(milliseconds: 200));

      await _openTagFilter(tester);
      expect(
        find.byKey(const Key('note-tag-filter-sheet')),
        findsOneWidget,
        reason: '筛选面板必须打开（旧行为：服务端标签为空 ⇒ 直接弹 No tags yet，面板根本不出现）',
      );
      expect(
        find.byKey(const Key('note-tag-filter-test')),
        findsOneWidget,
        reason: '面板里必须有笔记自带的 test 标签',
      );
      expect(find.text('No tags yet'), findsNothing);
      expect(find.text('还没有标签'), findsNothing);
    });

    testWidgets('③ 两边都没有标签时：`No tags yet` **必须照旧出现**（空态不许删）', (
      tester,
    ) async {
      final b = await _boot(
        tags: const [],
        notes: [_apiNote('n1', 'a', const [])],
      );
      await _pump(tester, b.c, const NotesPage());
      await tester.pump(const Duration(milliseconds: 200));

      await _openTagFilter(tester);
      expect(
        find.byKey(const Key('note-tag-filter-sheet')),
        findsNothing,
        reason: '没有标签就不该打开空面板',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byType(SnackBar),
        findsOneWidget,
        reason: '空态说明必须留在原地（§2.0.29①：不许顺手删干净）',
      );
      final text = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Text),
            ),
          )
          .map((w) => w.data ?? '')
          .join(' ');
      expect(
        text.contains('No tags yet') || text.contains('还没有标签'),
        isTrue,
        reason: '实际提示：$text',
      );
    });

    testWidgets('⑤ 服务端标签接口失败但不空：给的是"没取到"而不是"没有标签"', (tester) async {
      final b = await _boot(
        tags: const [],
        notes: [_apiNote('n1', 'a', const [])],
        tagApiFails: true,
      );
      await _pump(tester, b.c, const NotesPage());
      await tester.pump(const Duration(milliseconds: 200));

      await _openTagFilter(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SnackBar), findsOneWidget);
      final text = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Text),
            ),
          )
          .map((w) => w.data ?? '')
          .join(' ');
      expect(
        text.contains('No tags yet') || text.contains('还没有标签'),
        isFalse,
        reason: '取不到时不许说成"没有标签"（实际提示：$text）',
      );
      expect(text.trim(), isNotEmpty);
    });
  });
}
