// 诊断页 + App 外壳的 widget 冒烟测试
//
// autoRun: false —— 不触发原生库加载与真实网络请求，保证测试隔离。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/diagnostics/diag_page.dart';

void main() {
  // 根组件 `SynologyChatApp` 的语言默认"跟随系统"：测试环境默认 en-US，
  // 钉成中文才跟"中文设备"的真机默认体验一致（其余页面测试走无 delegate 的
  // 中文回落，不受影响）。
  setUp(() {
    // `locale` 和 `locales` 都要钉：语言协商读的是 `locales`
    final pd = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
    pd.localeTestValue = const Locale('zh');
    pd.localesTestValue = const [Locale('zh')];
  });
  tearDown(() {
    final pd = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
    pd.clearLocaleTestValue();
    pd.clearLocalesTestValue();
  });

  group('诊断页', () {
    testWidgets('渲染出标题、输入框与按钮', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), home: DiagPage(autoRun: false)),
      );

      expect(find.text('空洞穿透诊断'), findsOneWidget);
      // ★ D9（r719）：没跑过时按钮是「运行诊断」，不是自相矛盾的「重跑诊断」
      expect(find.text('运行诊断'), findsOneWidget);
      expect(find.text('重跑诊断'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('QuickConnect ID'), findsOneWidget);
    });

    testWidgets('autoRun=false 时不产生任何诊断结果', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), home: DiagPage(autoRun: false)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // 没有诊断行，也没有进度条
      expect(find.byType(ListView), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });

  group('App 外壳', () {
    testWidgets('启动落在「添加服务器」页，含两种录入方式', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: SynologyChatApp()));
      await tester.pumpAndSettle();

      // 应用身份：中文环境是「星枢」（ARB 的 appName）
      expect(find.text('星枢'), findsOneWidget);
      expect(find.text('QuickConnect ID'), findsWidgets);
      expect(find.text('直接地址'), findsOneWidget);
      expect(find.text('连接'), findsOneWidget);
    });

    testWidgets('主题为 Material 3 且标题正确', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: SynologyChatApp()));
      await tester.pumpAndSettle();

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.title, '星枢');
      expect(app.theme?.useMaterial3, isTrue);
      expect(app.darkTheme, isNotNull);
    });

    testWidgets('r378：默认档（= release）没有临时/调试入口', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: SynologyChatApp()));
      await tester.pumpAndSettle();

      // 原用例断言"必须有诊断入口"，那是**上线红线**（用户 2026-10-13 要求：
      // 最终安装包隐藏所有临时页面）⇒ 断言反转为"默认档一个都不许有"。
      expect(find.text('打洞诊断工具'), findsNothing);
      expect(find.text('设计预览'), findsNothing);
    });
  });
}
