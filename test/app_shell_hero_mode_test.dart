// r695 · `DA336` 守卫：**保活的 tab 不许把各自的 FAB 一起塞进同一条路由的 Hero 收集里**。
//
// 现场（`/src/walk_r695.log` 第 740 行起）：走查连续打开几个带 `FloatingActionButton`
// 的模块页之后，**任何**一次路由转场都会在 scheduler 回调里抛：
//
//   There are multiple heroes that share the same tag within a subtree.
//   In this case, multiple heroes had the following tag: <default FloatingActionButton tag>
//
// 根因：`AppShellPage` 用 `IndexedStack` 把 5 个 tab **全部保活**；其中聊天频道列表、
// 文件站、相册、笔记、下载各自的 `Scaffold` 都摆了 FAB（都没给 `heroTag`）。
// Hero 收集只看"当前路由子树"，不看 tab 是不是可见 ⇒ 同一条规则里有 ≥2 个默认 FAB。
//
// 修法：shell 给**非当前 tab** 套 `HeroMode(enabled: false)` —— 看不见的 tab 不参与
// Hero 配对（`HeroMode` 是 Flutter 为这种"同时活着但只有一个可见"的场景准备的正规开关）。
//
// 这条用例两个方向都钉：
//   ① 结构：`HeroMode` 的个数 == 可见 tab 数，且只有当前下标那一个 `enabled == true`；
//   ② 机制：同一路由里两个默认 FAB ⇒ 推路由必抛；给非当前项套 `HeroMode(enabled:false)`
//      后不抛 —— 这条是**反向验证**（先证明"坏条件真的会抛"，再证明"修法真的压住"）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';

import 'support/chat_harness.dart';

Key _dock(AppTab t) => Key('dock-${t.name}');

Widget _fabScaffold(String label) => Scaffold(
      body: Center(child: Text(label)),
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        child: const Icon(Icons.add),
      ),
    );

Future<void> _select(WidgetTester tester, AppTab t) async {
  final f = find.byKey(_dock(t));
  expect(f, findsOneWidget, reason: '底栏没有 ${t.name} 的入口');
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('DA336 ① 非当前 tab 的 Hero 一律关掉（结构）', (tester) async {
    final h = await bootChat();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(theme: AppTheme.dark(), home: const AppShellPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 先切两个"各自带 FAB"的 tab：聊天列表 → 文件站
    await _select(tester, AppTab.chat);
    await _select(tester, AppTab.files);

    final stack = tester.widget<IndexedStack>(
      find.byKey(const Key('app-shell-stack')),
    );
    final tabs = stack.children.length;
    expect(tabs, greaterThanOrEqualTo(2), reason: '这条用例至少要两个保活 tab');
    // ★ 必须 `skipOffstage: false`：`IndexedStack` 的非当前 tab 是 **offstage**
    //   （挂着但不画），而 Hero 收集**照样会走进 offstage 子树** —— 这正是本缺陷
    //   的来源。默认 `skipOffstage: true` 会把它们藏掉，判据当场变假绿。
    final modes = tester
        .widgetList<HeroMode>(find.byType(HeroMode, skipOffstage: false))
        .toList();
    expect(modes.length, tabs, reason: '每个可见 tab 都要被 HeroMode 包住');
    expect(modes.where((m) => m.enabled).length, 1,
        reason: '同一时刻只许当前 tab 参与 Hero 配对');
    expect(tester.takeException(), isNull);
  });

  testWidgets('DA336 ② 反向验证：同一路由里两个默认 FAB ⇒ 推路由必抛 hero 断言；'
      '给非当前项套 HeroMode(enabled:false) 后不抛（机制）', (tester) async {
    Widget stack({required bool guarded}) => MaterialApp(
          theme: AppTheme.dark(),
          home: IndexedStack(
            index: 0,
            children: <Widget>[
              for (var i = 0; i < 2; i++)
                if (guarded && i != 0)
                  HeroMode(enabled: false, child: _fabScaffold('tab$i'))
                else
                  _fabScaffold('tab$i'),
            ],
          ),
        );

    // ① 不套 HeroMode：两个默认 FAB 同在一个路由子树里
    await tester.pumpWidget(stack(guarded: false));
    await tester.pump();
    final nav1 = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav1.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('probe'))),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNotNull,
        reason: '两个默认 FAB 同路由时必须抛（否则下面的"修好了"没有意义）');

    // ② 套 HeroMode：非当前项不参与 Hero 配对
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(stack(guarded: true));
    await tester.pump();
    final nav2 = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav2.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('probe2'))),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: 'HeroMode(enabled:false) 必须消掉这条断言');
    expect(find.text('probe2'), findsOneWidget);
  });
}
