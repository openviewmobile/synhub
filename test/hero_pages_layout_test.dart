// 英雄页与主列表页的**窄屏布局**回归网。
//
// 为什么单独测：登录页/连接页/频道列表页在这一轮做了大幅视觉改造
// （深空背景 + 能量核 + 科技边框 + 遥测行），最容易出的问题是
// **窄屏 / 矮屏下的溢出**（RenderFlex overflow）。真机上我只有一台 411dp 宽的
// 手机，靠这里用 360×640（最小的主流机型）与 320×568（更极端）兜住。
//
// 断言策略：
//   1. 渲染不许抛异常（溢出在测试里就是异常，`takeException()` 能抓到）；
//   2. 关键语义字符串必须在（改造不许丢原版能力）；
//   3. 窄屏下也要能滚动到底（内容没被裁死）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/login/login_page.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/servers/server_setup_page.dart';

import 'support/chat_harness.dart';

Widget _app(ProviderContainer c, Widget home, {ThemeData? theme}) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: theme, home: home),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 把测试视口设成手机尺寸（默认是 800×600 的"假屏幕"，看不出窄屏问题）
void _phone(WidgetTester tester, {Size size = const Size(360, 640)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  for (final size in const [Size(360, 640), Size(320, 568)]) {
    final tag = '${size.width.toInt()}×${size.height.toInt()}';

    testWidgets('连接页 $tag：科幻外壳不溢出，语义与能力齐全', (tester) async {
      _phone(tester, size: size);
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, const ServerSetupPage()));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      // 原版的入口与文案一个不能少（**临时/调试入口除外** —— r378 起 release 档没有）
      expect(find.text('星枢'), findsOneWidget);
      expect(find.text('连接到你的 NAS'), findsOneWidget);
      expect(find.text('QuickConnect ID'), findsWidgets); // 分段按钮 + 输入框标签
      expect(find.text('直接地址'), findsOneWidget);
      // r378：连接页是用户第一屏，调试/设计预览入口**必须不在**（kDevTools 默认 false）
      expect(find.text('打洞诊断工具'), findsNothing);
      expect(find.text('设计预览'), findsNothing);
      // 主行动核的语义标签
      expect(find.bySemanticsLabel(RegExp('连接')), findsWidgets);
    });

    testWidgets('登录页 $tag：三段输入 + 能量核不溢出', (tester) async {
      _phone(tester, size: size);
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, const LoginPage()));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('账号'), findsOneWidget);
      expect(find.text('密码'), findsOneWidget);
      expect(find.text('登录'), findsOneWidget);
    });

    testWidgets('频道列表 $tag：指挥台顶栏与列表行不溢出', (tester) async {
      _phone(tester, size: size);
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, const ChannelListPage()));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      // 顶栏核心动作（原版 tooltip 文案）
      expect(find.text('频道'), findsWidgets);
      expect(find.byTooltip('搜索消息'), findsOneWidget);
      expect(find.byTooltip('刷新'), findsOneWidget);
      expect(find.byTooltip('更多'), findsOneWidget);
    });
  }

  // 暗色主题：科幻层在暗色下最容易被"炫"过头（网格/星尘/辉光都会变强），
  // 所以三页在暗色下也必须渲染干净（无溢出、关键文案齐全）。
  for (final theme in {'暗色': AppTheme.dark(), '亮色': AppTheme.light()}.entries) {
    testWidgets('${theme.key}主题下三页渲染干净', (tester) async {
      _phone(tester);
      final h = await bootChat();
      for (final page in const [
        ServerSetupPage(),
        LoginPage(),
        ChannelListPage(),
      ]) {
        await tester.pumpWidget(_app(h.container, page, theme: theme.value));
        await _settle(tester);
        expect(tester.takeException(), isNull, reason: '${theme.key} · $page');
      }
    });
  }
}
