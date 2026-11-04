// r668 / `DA294`：**"每秒会变的状态"不许改变布局** —— 行为判据（不只是静态扫描）。
//
// 背景：用户报「chat 的页面 channel 下面的连接状态变化太频繁，会导致页面跳动」
// 并明确说「安卓也有这个问题」。真机根因是**把实时相位直接绑到 `Text`**：
// 弱网重连时 `ready ↔ degraded` 一秒抖好几次，文案长度/折行数跟着变 ⇒ 整页上下跳。
//
// 本文件钉三件事（都用**渲染高度**判，不用"有没有动画"）：
//   ① 连续翻转 20 次（间隔远小于稳定窗口）⇒ 渲染高度**一像素都不变**，文案仍是旧值；
//   ② 停手后 700ms ⇒ 文案才更新（证明不是"永远不更新"的假修）；
//   ③ 同一状态内的文案变长（人数 8 → 8888）也**不改变高度**（定高单行 + 省略号）。
//
// 为什么这条用例对安卓同样有效：`channel_list_page.dart` 是**同一份共享 Dart 代码**
// （`app_shell_page.dart` 的 chat tab 直接 `const ChannelListPage()`，无平台分支），
// 所以"安卓页面跳动"修的就是这里。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/ui/debounced_status_line.dart';

const _ready = '实时通道已就绪';
const _down = '实时通道已断开，正在重连（第 2 次，已等 1s，最多 30s）';

Widget _host({
  required Object status,
  required String label,
  Color color = Colors.green,
  double fontSize = 11.5,
  Key textKey = const Key('status-text'),
}) => MaterialApp(
  home: Scaffold(
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上面放一段"标题"，下面放状态行 —— 高度变化会把下面的内容顶下去
        const SizedBox(height: 40, child: Text('聊天')),
        DebouncedStatusLine(
          status: status,
          label: label,
          color: color,
          fontSize: fontSize,
          textKey: textKey,
        ),
        const SizedBox(height: 8),
        const Text('下面的列表', key: Key('below')),
      ],
    ),
  ),
);

void main() {
  testWidgets('① 连续抖动 20 次：高度不变、文案不闪', (tester) async {
    await tester.pumpWidget(_host(status: 'ready', label: _ready));
    final h0 = tester.getSize(find.byType(DebouncedStatusLine)).height;
    final below0 = tester.getTopLeft(find.byKey(const Key('below'))).dy;

    // 每次只等 100ms（远小于 700ms 稳定窗口）——模拟真实抖动
    for (var i = 0; i < 10; i++) {
      await tester.pumpWidget(_host(status: 'degraded', label: _down));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(_host(status: 'ready', label: _ready));
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(tester.getSize(find.byType(DebouncedStatusLine)).height, h0,
        reason: '抖了 20 次高度就变了 ⇒ 用户看到的"页面跳动"没修好');
    expect(tester.getTopLeft(find.byKey(const Key('below'))).dy, below0,
        reason: '下面的内容被顶下去了 ⇒ 布局不变量被破坏');
    // 抖动期间界面应保持"稳定值"（不是每帧闪）
    expect(find.text(_ready), findsOneWidget);
    expect(find.text(_down), findsNothing);
  });

  testWidgets('② 停手 700ms 后文案才更新（不是永远不更新）', (tester) async {
    await tester.pumpWidget(_host(status: 'ready', label: _ready));
    await tester.pumpWidget(_host(status: 'degraded', label: _down));
    await tester.pump(const Duration(milliseconds: 699));
    expect(find.text(_ready), findsOneWidget, reason: '不到稳定窗口就上屏 = 还是在闪');
    await tester.pump(const Duration(milliseconds: 2));
    expect(find.text(_down), findsOneWidget, reason: '稳定之后必须上屏，否则是"卡住"');
  });

  testWidgets('③ 同状态内文案变长（人数刷新）也不改高度', (tester) async {
    await tester.pumpWidget(_host(status: 'ready', label: '3 个频道 · 8 位用户'));
    final h = tester.getSize(find.byType(DebouncedStatusLine)).height;
    await tester.pumpWidget(
      _host(status: 'ready', label: '128 个频道 · 8888 位用户（很长很长的文案，一定会折行）'),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(DebouncedStatusLine)).height, h,
        reason: '定高单行失效：长文案把行撑高了');
    // 单行 + 省略号：渲染出来的段落只有一行
    final text = tester.widget<Text>(find.byKey(const Key('status-text')));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('④ 系统字号放大到 2.0 时也不溢出（定高跟随 textScaler）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: _host(status: 'ready', label: _down),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '2.0 缩放下 RenderFlex 溢出');
  });
}
