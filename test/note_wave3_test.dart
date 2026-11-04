// NoteStation **wave3**（DSnote 对齐）离线套件。
//
// 覆盖本批新增/修正的服务端契约（**全部逐字来自真机取证 / 官方反编译**）：
//   * `SYNO.NoteStation.Todo / list_timeout`（v1/v2 同名方法）——
//     回包 `{count, offset, total, todos?}`，**空时没有 `todos`**；
//   * `SYNO.NoteStation.Shortcut / list` **v1** —— 回包
//     `{offset, total, shortcuts?}`（`ShortcutListVo.ShortcutsDataVo`）；
//   * `SYNO.NoteStation.Share.Priv / list` —— v1 `user_list[]`（裸字符串）
//     与 v2 `list[{name,type}]` **两种形态都要吃**；
//   * `SYNO.NoteStation.Smart / list` 与 `Tag / list` 的空/真形态回归。
//
// UI 侧：待办页的「已超时」计数/列表、快捷方式页、以及入口能力位门控。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_shortcut_page.dart';
import 'package:synhub/src/features/notes/note_todo_page.dart';
import 'package:synhub/src/features/notes/notes_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真机 `SYNO.API.Info` 快照子集（Todo/Smart/Shortcut/Share.Priv 都够用）。
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
  'SYNO.NoteStation.Todo': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Smart': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Shortcut': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Share.Priv': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

Future<NoteStationApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return NoteStationApi(api);
}

FakeTransport _transport(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, Map<String, dynamic>> extraTable = const {},
}) => FakeTransport(responses, {
  ...FakeTransport.table,
  ..._noteTable,
  ...extraTable,
});

// ---------------------------------------------------------------- 装配（UI）

Future<({FakeTransport t, ProviderContainer container})> _boot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, Map<String, dynamic>> extraTable = const {},
  ServiceAvailabilitySnapshot? availability,
}) async {
  final t = _transport(responses, extraTable: extraTable);
  final api = await _api(t);
  final container = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(api),
      chatDatabaseProvider.overrideWith((ref) {
        final db = ChatDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      if (availability != null)
        serviceAvailabilityProvider.overrideWith(
          () => _FixedAvailability(availability),
        ),
    ],
  );
  addTearDown(container.dispose);
  return (t: t, container: container);
}

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values) s: AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 1, 1),
    );

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child, {
  double textScale = 1.0,
}) async {
  Widget home = child;
  if (textScale != 1.0) {
    home = MediaQuery(
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child,
    );
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: home,
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
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  // ============================================================ 服务端契约
  group('Todo/list_timeout（v1/v2 同名方法）', () {
    test('空回包逐字：没有 todos，count/offset/total 为 0', () async {
      final t = _transport({
        'SYNO.NoteStation.Todo.list_timeout': {
          'count': 0,
          'offset': 0,
          'total': 0,
        },
      });
      final api = await _api(t);
      final r = await api.listTimeoutTodos();
      expect(r.todos, isEmpty);
      expect(r.count, 0);
      expect(r.isEmpty, isTrue);

      final call = t.calls.last;
      expect(call['api'], 'SYNO.NoteStation.Todo');
      expect(call['method'], 'list_timeout');
      expect('${call['version']}', '2', reason: '服务端 Todo maxVersion=2');
    });

    test('分页 offset/limit 原样发出，非空回包解出 todos', () async {
      final t = _transport({
        'SYNO.NoteStation.Todo.list_timeout': {
          'count': 2,
          'offset': 10,
          'total': 7,
          'todos': [
            {'object_id': 'T1', 'title': '过期一', 'due_date': 1700000000000},
            {'object_id': 'T2', 'title': '过期二', 'due_date': 1690000000000},
          ],
        },
      });
      final api = await _api(t);
      final r = await api.listTimeoutTodos(offset: 10, limit: 20);
      expect(r.count, 2);
      expect(r.total, 7);
      expect(r.todos.map((e) => e.title), ['过期一', '过期二']);

      final call = t.calls.last;
      expect('${call['offset']}', '10');
      expect('${call['limit']}', '20');
    });

    test('方法名写错（listTimeout）就不是服务端契约', () async {
      final t = _transport({});
      final api = await _api(t);
      await api.listTimeoutTodos();
      final call = t.calls.last;
      expect(call['method'], 'list_timeout');
      expect(call['method'], isNot('listTimeout'));
      expect(call['method'], isNot('list'));
    });
  });

  group('Shortcut/list v1', () {
    test('空回包逐字：没有 shortcuts，offset/total 为 0', () async {
      final t = _transport({
        'SYNO.NoteStation.Shortcut.list': {'offset': 0, 'total': 0},
      });
      final api = await _api(t);
      final rows = await api.listShortcuts();
      expect(rows, isEmpty);

      final call = t.calls.last;
      expect(call['api'], 'SYNO.NoteStation.Shortcut');
      expect(call['method'], 'list');
      expect('${call['version']}', '1');
      expect(call.containsKey('filter'), isFalse, reason: '官方复合调用不带参数');
    });

    test('真形态：id/category/title/items 逐字解', () async {
      final t = _transport({
        'SYNO.NoteStation.Shortcut.list': {
          'offset': 0,
          'total': 1,
          'shortcuts': [
            {
              'id': '1028_nb1',
              'category': 'notebook',
              'title': '工作',
              'items': ['1028_n1', '1028_n2'],
            },
          ],
        },
      });
      final api = await _api(t);
      final rows = await api.listShortcuts();
      expect(rows.length, 1);
      expect(rows.first.id, '1028_nb1');
      expect(rows.first.category, 'notebook');
      expect(rows.first.title, '工作');
      expect(rows.first.itemCount, 2);
    });
  });

  group('Share.Priv/list 两种回包形态', () {
    test('v1：user_list 裸字符串 → 全部当用户', () async {
      final t = _transport(
        {
          'SYNO.NoteStation.Share.Priv.list': {
            'offset': 0,
            'total': 4,
            'user_list': ['admin', 'demo_admin', 'demo_user', 'demo_user_b'],
          },
        },
        extraTable: {
          'SYNO.NoteStation.Share.Priv': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      final api = await _api(t);
      final list = await api.sharePrincipals(query: 'fi');
      expect(list.map((e) => e.name), [
        'admin',
        'demo_admin',
        'demo_user',
        'demo_user_b',
      ]);
      expect(list.every((e) => e.type == 'user'), isTrue);

      final call = t.calls.last;
      expect('${call['version']}', '1');
    });

    test('v2：list[{name,type}] 原样解（含群组）', () async {
      final t = _transport({
        'SYNO.NoteStation.Share.Priv.list': {
          'offset': 0,
          'total': 2,
          'list': [
            {'name': 'demo_user', 'type': 'user'},
            {'name': 'users', 'type': 'group'},
          ],
        },
      });
      final api = await _api(t);
      final list = await api.sharePrincipals(query: 'ku');
      expect(list.length, 2);
      expect(list.last.name, 'users');
      expect(list.last.type, 'group');
      final call = t.calls.last;
      expect('${call['version']}', '2');
    });

    test('两种形态同时出现时都要收（去重、保序）', () async {
      final t = _transport({
        'SYNO.NoteStation.Share.Priv.list': {
          'total': 3,
          'user_list': ['admin', 'demo_user'],
          'list': [
            {'name': 'admin', 'type': 'user'},
            {'name': 'users', 'type': 'group'},
          ],
        },
      });
      final api = await _api(t);
      final list = await api.sharePrincipals();
      expect(list.map((e) => '${e.type}:${e.name}'), [
        'user:admin',
        'user:demo_user',
        'group:users',
      ]);
    });
  });

  group('Smart/list 与 Tag/list 回归（本批只读，不改形态）', () {
    test('Smart/list 空回包 {offset,total} → 空列表，不抛', () async {
      final t = _transport({
        'SYNO.NoteStation.Smart.list': {'offset': 0, 'total': 0},
      });
      final api = await _api(t);
      expect(await api.listSmartNotebooks(), isEmpty);
      final call = t.calls.last;
      expect(call['api'], 'SYNO.NoteStation.Smart');
      expect(call['method'], 'list');
      expect('${call['version']}', '1');
      expect(call['field'], '{"query":true}');
    });

    test('Tag/list 真字段：tag_id 是内部 id、title 才是标题', () async {
      final t = _transport({
        'SYNO.NoteStation.Tag.list': {
          'tags': [
            {
              'category': 'tag',
              'items': ['1028_R9e9u0SSQfyWJYplAK9h5'],
              'tag_id': 'test@1028',
              'title': 'test',
            },
          ],
        },
      });
      final api = await _api(t);
      final tags = await api.listTags();
      expect(tags.length, 1);
      expect(tags.first.tagId, 'test@1028');
      expect(tags.first.title, 'test');
      expect(tags.first.category, 'tag');
      expect(tags.first.count, 1);
    });
  });

  // ============================================================ UI 行为
  group('待办页：已超时计数 / 列表（Todo/list_timeout）', () {
    testWidgets('显示计数；点开只列服务端判定的超时项', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Todo.list': {
          'todos': [
            {'object_id': 'T1', 'title': '买牛奶', 'done': false},
          ],
        },
        'SYNO.NoteStation.Todo.list_timeout': {
          'count': 1,
          'offset': 0,
          'total': 1,
          'todos': [
            {
              'object_id': 'T2',
              'title': '交周报',
              'done': false,
              'due_date': 1600000000000,
            },
          ],
        },
      });
      await _pump(tester, b.container, const NoteTodoPage());

      expect(find.text('买牛奶'), findsOneWidget);
      expect(find.text('已超时 1'), findsOneWidget, reason: '计数来自 list_timeout');

      await tester.tap(find.text('已超时 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('交周报'), findsOneWidget);
      expect(find.text('买牛奶'), findsNothing, reason: '超时视图只列 list_timeout 的返回');
      expect(tester.takeException(), isNull);
    });

    testWidgets('无超时项时仍是空态文案', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Todo.list': {'todos': <dynamic>[]},
        'SYNO.NoteStation.Todo.list_timeout': {
          'count': 0,
          'offset': 0,
          'total': 0,
        },
      });
      await _pump(tester, b.container, const NoteTodoPage());
      expect(find.text('已超时 0'), findsOneWidget);
      await tester.tap(find.text('已超时 0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('没有已超时的待办'), findsOneWidget);
    });

    testWidgets('窄屏 360x640 + x2.0 字号：筛选 chip 不换行溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final b = await _boot({
        'SYNO.NoteStation.Todo.list': {
          'todos': [
            {'object_id': 'T1', 'title': '买牛奶', 'done': false},
          ],
        },
        'SYNO.NoteStation.Todo.list_timeout': {
          'count': 3,
          'offset': 0,
          'total': 3,
          'todos': <dynamic>[],
        },
      });
      await _pump(tester, b.container, const NoteTodoPage(), textScale: 2.0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.takeException(),
        isNull,
        reason: 'AppBar 的 44px 槽里 chip 不能换行',
      );
    });
  });

  group('快捷方式页：列表 + 空态（Shortcut/list）', () {
    testWidgets('列表只上屏 title / 分类，不显示内部 id', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Shortcut.list': {
          'offset': 0,
          'total': 2,
          'shortcuts': [
            {
              'id': '1028_nb1',
              'category': 'notebook',
              'title': '工作',
              'items': ['1028_n1'],
            },
            {
              'id': '1028_s1',
              'category': 'smart',
              'title': '本周',
              'items': <dynamic>[],
            },
          ],
        },
      });
      await _pump(tester, b.container, const NoteShortcutPage());

      expect(find.text('工作'), findsOneWidget);
      expect(find.text('笔记本'), findsOneWidget);
      expect(find.text('本周'), findsOneWidget);
      expect(find.text('智能笔记本'), findsOneWidget);
      // 内部 id / items 一律不上屏
      expect(find.text('1028_nb1'), findsNothing);
      expect(find.text('1028_s1'), findsNothing);
      expect(find.text('1028_n1'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空回包 → 空态', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Shortcut.list': {'offset': 0, 'total': 0},
      });
      await _pump(tester, b.container, const NoteShortcutPage());
      expect(find.text('还没有快捷方式'), findsOneWidget);
    });
  });

  group('入口能力位门控（Shortcut 缺失 → 入口隐藏）', () {
    testWidgets('能力表没有 Shortcut 时不显示入口', (tester) async {
      final b = await _boot({
        'SYNO.NoteStation.Note.list': {'notes': <dynamic>[], 'total': 0},
        'SYNO.NoteStation.Notebook.list': {
          'notebooks': <dynamic>[],
          'total': 0,
        },
      }, availability: _snap({'SYNO.NoteStation.Note'}));
      await _pump(tester, b.container, const NotesPage());

      await tester.tap(find.byTooltip('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('快捷方式'), findsNothing);
      expect(find.byKey(const Key('note-shortcut-entry')), findsNothing);
    });

    testWidgets('能力表有 Shortcut 时入口出现', (tester) async {
      final b = await _boot(
        {
          'SYNO.NoteStation.Note.list': {'notes': <dynamic>[], 'total': 0},
          'SYNO.NoteStation.Notebook.list': {
            'notebooks': <dynamic>[],
            'total': 0,
          },
        },
        availability: _snap({
          'SYNO.NoteStation.Note',
          'SYNO.NoteStation.Shortcut',
        }),
      );
      await _pump(tester, b.container, const NotesPage());

      await tester.tap(find.byTooltip('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('note-shortcut-entry')), findsOneWidget);
    });
  });
}
