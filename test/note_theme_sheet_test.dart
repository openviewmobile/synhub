// ★★★ 第 125 轮 / 台账 N6：主题（笔记内可达）。
//
// 官方取证：DSnote `res/values/strings.xml:860-862`
// `theme_dark` / `theme_default` / `theme_light`（Dark / System default / Light）
// —— 官方主题是**应用设置**，笔记模块内没有第二套主题体系。
// 我方主题本就是 App 级（`themeChoiceProvider` → `MaterialApp.themeMode`），
// 这里只补"笔记里点得到"的入口，**不新增第二套状态**。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/notes/note_theme_sheet.dart';

import 'support/chat_harness.dart' show FakeTransport;
import 'package:synhub/src/dsm/webapi.dart';

void main() {
  late ProviderContainer container;

  Future<void> boot() async {
    final t = FakeTransport(const {}, FakeTransport.table);
    final api = DsmWebApi(t);
    await api.discover();
    await api.login(account: 'a', password: 'b');
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
  }

  testWidgets('★ 三档齐全（跟随系统/浅色/深色），点哪档就写哪档', (tester) async {
    await boot();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _Host()),
      ),
    );
    await tester.tap(find.byKey(const Key('open-theme')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-theme-themeSystem')), findsOneWidget);
    expect(find.byKey(const Key('note-theme-themeLight')), findsOneWidget);
    expect(find.byKey(const Key('note-theme-themeDark')), findsOneWidget);

    await tester.tap(find.byKey(const Key('note-theme-themeDark')));
    await tester.pumpAndSettle();
    expect(container.read(themeChoiceProvider), AppThemeChoice.dark);

    // 落盘（不是只改内存）
    expect(
      await container.read(settingsServiceProvider).themeChoice(),
      AppThemeChoice.dark,
    );

    // 再打开：当前档位有标记，且能切回去
    await tester.tap(find.byKey(const Key('open-theme')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-theme-themeLight')));
    await tester.pumpAndSettle();
    expect(container.read(themeChoiceProvider), AppThemeChoice.light);
  });

  test('★ 官方三档与我们的枚举一一对应（`strings.xml:860-862`）', () {
    expect(AppThemeChoice.values.map((c) => c.mode), [
      ThemeMode.system,
      ThemeMode.light,
      ThemeMode.dark,
    ]);
  });
}

class _Host extends ConsumerWidget {
  const _Host();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Builder(
      builder: (ctx) => TextButton(
        key: const Key('open-theme'),
        onPressed: () => showNoteThemeSheetForTest(ctx),
        child: const Text('open'),
      ),
    ),
  );
}

/// 测试用薄封装：直接调正式入口（`ref` 从 `ProviderScope` 拿）。
Future<void> showNoteThemeSheetForTest(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);
  return showNoteThemeSheetImpl(context, container);
}
