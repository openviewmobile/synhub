// AI 悬浮球：拖动 / 贴边吸附 / 收起隐藏 / 展开 / 点击。
//
// 三条必须钉死的行为（用户明确要求）：
//   1. 能拖到任意位置，松手**吸附到最近的左右边**；
//   2. 朝边缘一滑**收起**（只留一条把手），再朝外一滑（或点一下）**展开**；
//   3. 位置**跨会话保留**（落库），而且空白处**不拦手势**（不能挡住正文）。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/ai_floating_orb.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;

/// 一个 360x640 的宿主：正文区带一个可点的按钮，用来验证悬浮球不吃手势
Future<ProviderContainer> pumpOrb(
  WidgetTester tester, {
  required VoidCallback onTap,
  List<VoidCallback>? contentTaps,
}) async {
  final container = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWith((ref) {
        final db = ChatDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 640,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: TextButton(
                        onPressed: contentTaps == null
                            ? null
                            : () => contentTaps.first(),
                        child: const Text('正文按钮'),
                      ),
                    ),
                  ),
                  AiFloatingOrb(onTap: onTap),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// 球心坐标（找不到球就是测试自己坏了）
Offset orbCenter(WidgetTester tester) =>
    tester.getCenter(find.byTooltip('AI 助手').first);

/// **用户真正能点到的那一点**：球与它所在 Stack 的交集中心。
///
/// 收起状态时球有一大半在 Stack 之外（被 `Stack.clipBehavior` 裁掉），
/// 球心已经落在宿主之外、点不到 —— 手指只能按到露出来的那一条。
Offset orbTouchPoint(WidgetTester tester, Finder tooltip) {
  final ball = tester.getRect(tooltip);
  final box = tester.getRect(find.byType(AiFloatingOrb));
  final visible = ball.intersect(box);
  return visible.center;
}

void main() {
  test('状态编解码：坏数据回默认值，round-trip 不丢信息', () {
    expect(AiOrbState.parse(null), const AiOrbState());
    expect(AiOrbState.parse(''), const AiOrbState());
    expect(AiOrbState.parse('garbage'), const AiOrbState());
    expect(AiOrbState.parse('left|abc|1'), const AiOrbState());
    // 越界的比例会被夹回 0..1
    final clamped = AiOrbState.parse('left|9|1');
    expect(clamped.side, OrbSide.left);
    expect(clamped.t, 1.0);
    expect(clamped.collapsed, isTrue);

    const s = AiOrbState(side: OrbSide.left, t: 0.25, collapsed: true);
    expect(AiOrbState.parse(s.encode()), s);
  });

  testWidgets('点一下悬浮球 → 打开 AI（onTap 被调用）', (tester) async {
    var tapped = 0;
    await pumpOrb(tester, onTap: () => tapped++);
    await tester.tap(find.byTooltip('AI 助手').first);
    await tester.pumpAndSettle();
    expect(tapped, 1);
  });

  testWidgets('悬浮球不挡正文：它之外的区域照样能点', (tester) async {
    var content = 0;
    await pumpOrb(tester, onTap: () {}, contentTaps: [() => content++]);
    await tester.tap(find.text('正文按钮'));
    await tester.pumpAndSettle();
    expect(content, 1);
  });

  testWidgets('默认贴右边；往左拖过半屏松手 → 吸附到左边并落库', (tester) async {
    final c = await pumpOrb(tester, onTap: () {});
    // 默认在右侧（360 宽的容器里，球心 x 靠右）
    expect(c.read(aiOrbProvider).side, OrbSide.right);
    expect(orbCenter(tester).dx, greaterThan(180));

    await tester.drag(find.byTooltip('AI 助手').first, const Offset(-280, -120));
    await tester.pumpAndSettle();

    final state = c.read(aiOrbProvider);
    expect(state.side, OrbSide.left);
    expect(state.collapsed, isFalse);
    // 球现在在它自己那块区域（360 宽的正文区）的左半边
    final box = tester.getRect(find.byType(AiFloatingOrb));
    expect(orbCenter(tester).dx, lessThan(box.center.dx));
    // 落库：换一个容器读出来还在左边
    final raw = await c.read(settingsServiceProvider).aiOrbRaw();
    expect(AiOrbState.parse(raw).side, OrbSide.left);
  });

  testWidgets('真机式拖动：20 次小位移也能拖到左边（旧实现这里纹丝不动）', (tester) async {
    final c = await pumpOrb(tester, onTap: () {});
    final box = tester.getRect(find.byType(AiFloatingOrb));
    expect(c.read(aiOrbProvider).side, OrbSide.right);

    // 模拟手指：每次只移动十几像素，分 20 步 —— 真机 `input swipe` 就是这样，
    // 单步大位移的假手势测不出"换边判断用了单事件位移"这个 bug。
    final g = await tester.startGesture(
      tester.getCenter(find.byTooltip('AI 助手').first),
    );
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(-14, -5));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();

    expect(c.read(aiOrbProvider).side, OrbSide.left);
    // 眼下贴着左边缘（相对它自己那块区域）
    final ball = tester.getRect(find.byTooltip('AI 助手'));
    expect(ball.left - box.left, lessThan(ball.width));
    // 拖动过程中位置也跟着手指走（不是"贴边跳变"）：这里验证最终 t 变小了
    expect(c.read(aiOrbProvider).t, lessThan(0.62));
  });

  testWidgets('朝边缘一滑 → 收起成把手（只露一点）；点它 → 展开且不发 AI 请求', (tester) async {
    var tapped = 0;
    final c = await pumpOrb(tester, onTap: () => tapped++);

    // 从右边往右推 80px（朝边缘方向）→ 收起
    await tester.drag(find.byTooltip('AI 助手').first, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(c.read(aiOrbProvider).collapsed, isTrue);
    expect(find.byTooltip('展开 AI 助手'), findsOneWidget);
    expect(await c.read(settingsServiceProvider).aiOrbRaw(), contains('|1'));

    // 收起状态下点一下露出来的把手：只展开，不触发 AI
    await tester.tapAt(orbTouchPoint(tester, find.byTooltip('展开 AI 助手')));
    await tester.pumpAndSettle();
    expect(c.read(aiOrbProvider).collapsed, isFalse);
    expect(tapped, 0);
  });

  testWidgets('球已经贴在边缘时，再往边上推一把就能收起（真机可达距离只有 ~30dp）', (tester) async {
    final c = await pumpOrb(tester, onTap: () {});
    // 先把它拖到左边贴边
    await c
        .read(aiOrbProvider.notifier)
        .settle(const AiOrbState(side: OrbSide.left, t: 0.5));
    await tester.pumpAndSettle();
    expect(c.read(aiOrbProvider).collapsed, isFalse);

    // 再从当前位置往左边推 30dp（多步小位移，模拟真机手指）
    final g = await tester.startGesture(
      tester.getCenter(find.byTooltip('AI 助手').first),
    );
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(-9, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();

    expect(c.read(aiOrbProvider).collapsed, isTrue);
    expect(find.byTooltip('展开 AI 助手'), findsOneWidget);
  });

  testWidgets('把手状态朝外拖 → 展开（对称手感）', (tester) async {
    final c = await pumpOrb(tester, onTap: () {});
    await c
        .read(aiOrbProvider.notifier)
        .settle(const AiOrbState(side: OrbSide.right, t: 0.5, collapsed: true));
    await tester.pumpAndSettle();
    expect(c.read(aiOrbProvider).collapsed, isTrue);

    // 从把手往屏幕里拖 80px → 展开（从"能点到的那点"起手）
    await tester.dragFrom(
      orbTouchPoint(tester, find.byTooltip('展开 AI 助手')),
      const Offset(-80, 0),
    );
    await tester.pumpAndSettle();
    expect(c.read(aiOrbProvider).collapsed, isFalse);
  });

  testWidgets('落库的位置下次进来就生效（preload + 界面照它摆）', (tester) async {
    final c = await pumpOrb(tester, onTap: () {});
    await c.read(settingsServiceProvider).setAiOrbRaw('left|0.10|1');
    // 换一个 notifier 实例：模拟"下次进页面"
    c.invalidate(aiOrbProvider);
    await c.read(aiOrbProvider.notifier).preload();

    final state = c.read(aiOrbProvider);
    expect(state.side, OrbSide.left);
    expect(state.t, 0.10);
    expect(state.collapsed, isTrue);

    // 界面也按落库的位置摆：收起把手 + 贴左边
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开 AI 助手'), findsOneWidget);
    final box = tester.getRect(find.byType(AiFloatingOrb));
    final ball = tester.getRect(find.byTooltip('展开 AI 助手'));
    expect(ball.left, lessThan(box.left + 4)); // 贴左边（含 0.x 的取整误差）
    expect(ball.width, greaterThan(0)); // 露着，不是完全藏起来
  });

  testWidgets('拖到顶部/底部不会跑出容器（垂直比例被夹住）', (tester) async {
    final c = await pumpOrb(tester, onTap: () {});
    await tester.drag(find.byTooltip('AI 助手').first, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(c.read(aiOrbProvider).t, 0.0);

    await tester.drag(find.byTooltip('AI 助手').first, const Offset(0, 4000));
    await tester.pumpAndSettle();
    expect(c.read(aiOrbProvider).t, 1.0);
    // 球仍然完整可见（球心在容器内）
    final c0 = orbCenter(tester);
    expect(c0.dy, greaterThanOrEqualTo(0));
    expect(c0.dy, lessThanOrEqualTo(640));
  });
}
