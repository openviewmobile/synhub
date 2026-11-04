// ★★ ④笔记 第 237 轮：**F5「快捷方式 / 收藏」跳转路由**的离线用例。
//
// 官方 Android `ShortcutListFragment` 按 `category` 分流；`GenerateShortcutsLoader`
// 把 `items[]` 的值当对象 id。这一层此前**只有列表/写入的用例**，跳转没有 ⇒ 本轮补上。
//
// 六条路由 + 两条"拿不到目标就如实提示（不猜）"：note / notebook / stack /
// smart / tag / 未知 category。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drift/native.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_providers.dart'
    show selectedNotebookProvider;
import 'package:synhub/src/features/notes/note_shortcut_page.dart';
import 'package:synhub/src/features/notes/note_shelf_page.dart';
import 'package:synhub/src/features/notes/note_smart_page.dart';
import 'package:synhub/src/features/notes/note_tag_page.dart';
import 'package:synhub/src/features/notes/note_view_page.dart';

ShortcutDto _shortcut({
  required String category,
  List<String> items = const [],
  String title = '快捷方式',
}) => ShortcutDto(
  id: 's1',
  category: category,
  title: title,
  itemIds: items,
);

void main() {
  late ProviderContainer container;
  late List<Route<dynamic>> pushed;

  Future<void> boot(WidgetTester tester, ShortcutDto s) async {
    container = ProviderContainer(
      overrides: [
        chatDatabaseProvider.overrideWith((ref) {
          final db = ChatDatabase(NativeDatabase.memory());
          ref.onDispose(db.close);
          return db;
        }),
      ],
    );
    addTearDown(container.dispose);
    pushed = <Route<dynamic>>[];
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [_Observer(pushed)],
          // 必须是真的 Consumer 拿 `ref`（生产里就是页面自己的 ref）；
          // 用 container 强转 WidgetRef 会在运行时炸，跳转根本不发生（237 轮踩到）。
          home: Consumer(
            builder: (ctx, ref, _) => Scaffold(
              body: TextButton(
                key: const Key('go'),
                onPressed: () => openNoteShortcutTarget(ctx, ref, s),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('F5 快捷方式 · 跳转路由', () {
    testWidgets('category=note → 打开该笔记（拿 items[0] 当 id）', (tester) async {
      await boot(tester, _shortcut(category: 'note', items: ['n-9']));
      await tester.tap(find.byKey(const Key('go')));
      // ⚠️ 目标页自己有异步加载（转圈动画不会停）⇒ 不能 pumpAndSettle，
      //    只推固定几帧（237 轮踩到 timeout）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(NoteViewPage), findsOneWidget);
    });

    testWidgets('category=notebook → 选中该笔记本并返回', (tester) async {
      await boot(tester, _shortcut(category: 'notebook', items: ['nb-3']));
      await tester.tap(find.byKey(const Key('go')));
      // ⚠️ 目标页自己有异步加载（转圈动画不会停）⇒ 不能 pumpAndSettle，
      //    只推固定几帧（237 轮踩到 timeout）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(container.read(selectedNotebookProvider), 'nb-3');
      expect(pushed, isEmpty, reason: '笔记本是"选中"不是"压栈"');
    });

    for (final (cat, type) in <(String, Type)>[
      ('stack', NoteShelfPage),
      ('smart', NoteSmartPage),
      ('tag', NoteTagPage),
    ]) {
      testWidgets('category=$cat → 打开 $type', (tester) async {
        await boot(tester, _shortcut(category: cat));
        await tester.tap(find.byKey(const Key('go')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(type), findsOneWidget, reason: '$cat 应打开 $type');
      });
    }
  });

  group('F5 快捷方式 · 无目标 / 未知分类', () {
    testWidgets('★ note 但没有 items ⇒ 提示且**不跳转、不造假 id**', (tester) async {
      await boot(tester, _shortcut(category: 'note'));
      await tester.tap(find.byKey(const Key('go')));
      // ⚠️ 目标页自己有异步加载（转圈动画不会停）⇒ 不能 pumpAndSettle，
      //    只推固定几帧（237 轮踩到 timeout）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(NoteViewPage), findsNothing);
      expect(pushed, isEmpty);
    });

    testWidgets('★ notebook 但没有 items ⇒ 提示且不改选中项', (tester) async {
      await boot(tester, _shortcut(category: 'notebook'));
      await tester.tap(find.byKey(const Key('go')));
      // ⚠️ 目标页自己有异步加载（转圈动画不会停）⇒ 不能 pumpAndSettle，
      //    只推固定几帧（237 轮踩到 timeout）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(container.read(selectedNotebookProvider), isNot(''));
    });

    testWidgets('未知 category ⇒ 如实提示（不猜目标）', (tester) async {
      await boot(tester, _shortcut(category: 'whatever', items: ['x']));
      await tester.tap(find.byKey(const Key('go')));
      // ⚠️ 目标页自己有异步加载（转圈动画不会停）⇒ 不能 pumpAndSettle，
      //    只推固定几帧（237 轮踩到 timeout）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(pushed, isEmpty);
    });
  });
}

class _Observer extends NavigatorObserver {
  _Observer(this.pushed);

  final List<Route<dynamic>> pushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) pushed.add(route);
  }
}
