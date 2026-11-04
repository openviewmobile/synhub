// 通知与后台设置页的 UI 回归网（"深空座舱 · 开关矩阵"改造后）。
//
// 为什么单独测：这一页从 `ListTile + Switch` 换成了 分组切角面板 + 矩阵行，
// 最容易出的是**窄屏溢出**（RenderFlex overflow）与**语义串丢失**。
// 断言策略：
//   1. 渲染不抛异常（溢出在测试里就是异常，`takeException()` 能抓到）；
//   2. 真机脚本 / `test/notification_test.dart` 依赖的中文语义串一个不少；
//   3. 窄屏 360×640 下也不溢出。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';
import 'package:synhub/src/features/settings/notification_settings_page.dart';

import 'support/chat_harness.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/fake_background.dart';

Future<void> _pumpPage(WidgetTester tester, ChatHarness h) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: ProviderScope(
        overrides: [
          backgroundServiceProvider.overrideWithValue(FakeBackground()),
        ],
        child: MaterialApp(theme: AppTheme.dark(), home: NotificationSettingsPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ★ r693（DA334）：`FOREGROUND` / `BOOT` 两段现在**按能力位 fail-closed**
  //   （桌面宿主没有 `synhub/background` 桥 ⇒ 不摆那两个死开关）。本文件要验的是
  //   "矩阵渲染 + 语义串 + 窄屏不溢出"，跑在 macOS 宿主上 ⇒ 必须先把门放开，
  //   否则验的是一份没有那两段的页面。**门本身的开关行为**由
  //   `desktop_mobile_only_gates_test.dart` 双向钉住（那边才是判据）。
  void openGate() {
    debugForceCapabilityGate = true;
    addTearDown(() => debugForceCapabilityGate = false);
  }

  testWidgets('通知与后台：分组矩阵渲染，语义串齐全', (tester) async {
    openGate();
    final h = await bootChat();
    await _pumpPage(tester, h);

    expect(tester.takeException(), isNull);
    // 标题 + 三行关键开关/动作
    expect(find.text('通知与后台'), findsOneWidget);
    expect(find.text('前台常驻服务'), findsOneWidget);
    expect(find.text('开机自启'), findsOneWidget);
    expect(find.text('发一条测试通知'), findsOneWidget);
    // 分组头：r470 起按设计稿只上中文类目名（英文代号不再上屏）；
    // 且「启动」不能叫「开机自启」—— 否则和下面那一行同名，用户读到两个一样的词。
    expect(find.text('前台服务'), findsOneWidget);
    expect(find.text('启动'), findsOneWidget);
    expect(find.text('通知自检'), findsOneWidget);
    // 状态副标题沿用原文案
    expect(find.text('未运行（只在 App 前台收消息）'), findsOneWidget);

    // 免打扰入口在折叠线下，滚下去再看（ListView 懒构建）
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 分组头也叫「免打扰」，所以这里只要求"至少一处"
    expect(find.text('免打扰'), findsWidgets);
    expect(find.text('免打扰'), findsWidgets);
  });

  testWidgets('通知与后台 360×640：窄屏滚动到底也不溢出', (tester) async {
    openGate();
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final h = await bootChat();
    await _pumpPage(tester, h);

    expect(tester.takeException(), isNull);
    expect(find.text('前台常驻服务'), findsOneWidget);
    expect(find.text('开机自启'), findsOneWidget);
    expect(find.text('发一条测试通知'), findsOneWidget);

    // 滚到底，逼后面几组也过一次布局
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
