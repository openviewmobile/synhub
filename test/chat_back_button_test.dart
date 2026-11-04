// DA288（r667）：桌面/宽屏聊天详情**必须有返回入口**。
//
// 现场（真 NAS · Linux 站，窗口 1280×720，证据 `/tmp/r666_linux_ui/11_dm_chat_mention.png`）：
// 进入频道/会话后，`AppBar` 的 `leading` 被**头像独占**，Flutter 的自动返回箭头
// 因此不会出现；而详情页**不显示底部导航**，`Escape` / `Alt+←` 也都不响应
// ⇒ 用户（以及自动化）进去就出不来，只能重启 App。
//
// 修法：`leading` 改成一个 Row —— 路由可 pop 时先放 `chat-back`，再放头像。
// 两条判据：① 可 pop ⇒ 有 `chat-back`，点它真的回到上一页；
//          ② 不可 pop（作为根路由）⇒ **不摆**（避免多一个点了没反应的按钮）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/chat/chat_page.dart';

import 'support/chat_harness.dart';

Widget _app(ProviderContainer c, Widget home) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: home),
);

void main() {
  testWidgets('DA288 频道详情：可 pop 时给 chat-back，点它回到上一页', (tester) async {
    final h = await bootChat();
    await tester.pumpWidget(
      _app(
        h.container,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ChatPage(channelId: 5),
                  ),
                ),
                child: const Text('open-channel'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-channel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const Key('chat-back')),
      findsOneWidget,
      reason: 'DA288：桌面能进来就必须能出去',
    );

    await tester.tap(find.byKey(const Key('chat-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.text('open-channel'),
      findsOneWidget,
      reason: 'DA288：点 chat-back 必须真的 pop 回上一页',
    );
    expect(find.byKey(const Key('chat-back')), findsNothing);
  });

  testWidgets('DA288 反向：作为根路由（不可 pop）时不摆 chat-back', (tester) async {
    final h = await bootChat();
    await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const Key('chat-back')),
      findsNothing,
      reason: '不可 pop 时摆一个点了没反应的返回键 = 假控件',
    );
  });
}
