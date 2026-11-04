import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/ui/adaptive_actions.dart';

/// 第 258 轮真机缺陷回归：**顶部工具条按钮重叠/误触**。
///
/// 真机现象（用户报障）：「返回键和搜索键的图标叠到一起了」「按钮铺满」。
/// 根因：动作数是条件渲染出来的，最多的一页 14 个 `IconButton`
/// （`photo_viewer_page` 的 `actions:`），48dp × 14 = 672dp ≫ 手机竖屏宽度；
/// `AppBar` 的 trailing 排不下就**继续往左长**，盖到 leading 上。
///
/// 本用例做**双向**验证（本仓规矩：证明用例真抓得住缺陷）：
/// * ③ 组用**修复前**的写法（裸 `actions: [14 个 IconButton]`）断言
///   **确实会盖住返回键** —— 证明"用例不是恒过"；
/// * ② 组用修复后的 `adaptiveActions([...])` 断言**任何宽度下都不重叠**。
void main() {
  const double barHeight = 56;

  /// 模拟真机那一页的动作集合：14 个 IconButton（photo_viewer 的形态）
  List<Widget> manyActions({int n = 14, VoidCallback? onAction}) => [
    for (var i = 0; i < n; i++)
      IconButton(
        key: Key('t-action-$i'),
        tooltip: 'action $i',
        icon: const Icon(Icons.circle_outlined),
        onPressed: onAction ?? () {},
      ),
  ];

  Future<void> pumpBar(
    WidgetTester tester, {
    required double width,
    required bool useStrip,
    int actions = 14,
    VoidCallback? onAction,
  }) async {
    tester.view.physicalSize = Size(width * 3, barHeight * 3 + 600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              key: const Key('t-back'),
              tooltip: '返回',
              icon: const Icon(Icons.arrow_back),
              onPressed: () {},
            ),
            title: const Text('标题'),
            actions: useStrip
                ? adaptiveActions(manyActions(n: actions, onAction: onAction))
                : manyActions(n: actions),
          ),
          body: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();
  }

  /// 行内还留着的动作矩形（按 key 找得到才算）
  List<Rect> actionRects(WidgetTester tester, int actions) => [
    for (var i = 0; i < actions; i++)
      if (find.byKey(Key('t-action-$i')).evaluate().isNotEmpty)
        tester.getRect(find.byKey(Key('t-action-$i'))),
  ];

  /// 折叠进 `⋮` 的个数（修复后：屏窄时必须 > 0）
  int overflowCount(WidgetTester tester) =>
      find.byKey(const Key('bar-overflow')).evaluate().length;

  group('① inlineCountFor（纯函数：宽度 → 行内格数）', () {
    test('手机竖屏宽度下只留少量行内（其余折叠/滚动）', () {
      // (w - reserve 112 - slot 48) / 48
      expect(AdaptiveActions.inlineCountFor(414, total: 14), 5);
      expect(AdaptiveActions.inlineCountFor(360, total: 14), 4);
      expect(AdaptiveActions.inlineCountFor(320, total: 14), 3);
      // 800x600（测试默认窗口）：13 格 ≥ 总数 ⇒ 全部行内（既有 key 断言不受影响）
      expect(AdaptiveActions.inlineCountFor(800, total: 14), 14,
          reason: '放得下就一格都不折 ⇒ 既有 key 断言不受影响');
      expect(AdaptiveActions.inlineCountFor(800, total: 9), 9);
    });

    test('极窄屏也不返回 0（否则按钮会被布局到容器外 = 画到返回键上）', () {
      expect(AdaptiveActions.inlineCountFor(100, total: 14), 1);
      expect(AdaptiveActions.inlineCountFor(0, total: 14), 1);
      expect(AdaptiveActions.inlineCountFor(-50, total: 14), 1);
    });

    test('maxInline 是硬上限；total 小于上限时不超过 total', () {
      expect(AdaptiveActions.inlineCountFor(1200, maxInline: 3, total: 14), 3);
      expect(AdaptiveActions.inlineCountFor(1200, total: 2), 2);
      expect(AdaptiveActions.inlineCountFor(1200, total: 0), 0);
    });
  });

  group('② 修复后：任何手机宽度下都不与返回键重叠、都在屏内', () {
    for (final width in <double>[320, 360, 414]) {
      testWidgets('${width.toInt()}dp：14 个动作不盖返回键、都在屏内', (tester) async {
        await pumpBar(tester, width: width, useStrip: true);
        final back = tester.getRect(find.byKey(const Key('t-back')));
        final rects = actionRects(tester, 14);
        expect(rects, isNotEmpty, reason: '至少要有动作按钮在树里');
        expect(
          overflowCount(tester),
          1,
          reason: '★ 屏窄时必须出现 ⋮ 折叠入口（否则就是把按钮排到屏外）',
        );

        for (final r in rects) {
          expect(
            back.overlaps(r),
            isFalse,
            reason: '★ 真机缺陷：动作按钮盖住了返回键。back=$back action=$r',
          );
          expect(
            r.left >= 0 && r.right <= width,
            isTrue,
            reason: '动作按钮必须完整落在屏内（否则点不到）：$r 宽=$width',
          );
        }
        // 动作之间也不许互相叠（否则同样误触）
        for (var i = 0; i < rects.length; i++) {
          for (var j = i + 1; j < rects.length; j++) {
            expect(rects[i].overlaps(rects[j]), isFalse,
                reason: '动作 $i 与 $j 重叠：${rects[i]} vs ${rects[j]}');
          }
        }
      });
    }

    testWidgets('宽度够时**不折叠**、原样一行（既有 key 断言因此不受影响）',
        (tester) async {
      await pumpBar(tester, width: 800, useStrip: true, actions: 14);
      expect(overflowCount(tester), 0, reason: '800dp 放得下 14×48 ⇒ 不该有 ⋮');
      final rects = actionRects(tester, 14);
      expect(rects, hasLength(14));
      for (var i = 1; i < rects.length; i++) {
        expect(rects[i - 1].right, lessThanOrEqualTo(rects[i].left + 0.01));
      }
    });

    testWidgets('折叠后点 ⋮ 仍能触达被折叠的动作（不是"消失"）', (tester) async {
      var hits = 0;
      await pumpBar(tester, width: 360, useStrip: true, actions: 8,
          onAction: () => hits++);
      final inline = actionRects(tester, 8).length;
      expect(inline, lessThan(8), reason: '360dp 放不下 8 个 ⇒ 有折叠');
      await tester.tap(find.byKey(const Key('bar-overflow')));
      await tester.pumpAndSettle();
      // 菜单里应列出被折叠的动作（key 为 bar-overflow-<i>）
      expect(find.byKey(const Key('bar-overflow-0')), findsOneWidget);
      await tester.tap(find.byKey(const Key('bar-overflow-0')));
      await tester.pumpAndSettle();
      expect(hits, 1, reason: '被折叠的动作必须真的能点到');
    });
  });

  group('③ 反向验证：修复前的写法**确实**会出问题（用例抓得住）', () {
    testWidgets('414dp + 14 个裸 IconButton ⇒ RenderFlex 溢出（= 真机重叠的来源）',
        (tester) async {
      await pumpBar(tester, width: 414, useStrip: false);
      final err = tester.takeException();
      expect(
        err,
        isNotNull,
        reason: '修复前必须报越界 —— 若这里为 null，说明用例抓不住真机缺陷',
      );
      expect('$err', contains('overflow'),
          reason: '真机表现就是这条溢出：trailing 排不下继续往左长，盖住返回键');
      // 复位，别把异常留给下一个用例
      tester.takeException();
    });

    testWidgets('同样 14 个动作**走 adaptiveActions** 就不溢出了（对照）',
        (tester) async {
      await pumpBar(tester, width: 414, useStrip: true);
      expect(tester.takeException(), isNull, reason: '修复后不应再有任何溢出');
    });
  });

  // ★ ④ 组是 r121 D7 顺带修掉的一条**静默丢动作**缺陷的守卫。
  //
  // `FoldingActions` 折叠时，落进"被折叠那段"的**复合控件**（非纯 `IconButton`）
  // 必须被换回行内 —— 因为它们没法生成溢出菜单项（菜单项只能从 `IconButton`
  // 的 `icon`/`tooltip`/`onPressed` 造出来）。原来的判据写死了泛型
  // `folded.whereType<PopupMenuButton<int>>()`：调用方传 `PopupMenuButton<String>`
  // 时既进不了 `complex`、又在 `folded.whereType<IconButton>()` 里被过滤掉
  // ⇒ **那个动作从工具条上彻底消失**（点不到、也不在 `⋮` 里）。
  //
  // 触发条件是"复合控件排在折叠段里"（`inline` 比它的下标小）。这里用
  // **417.45dp + reserve 240** 把 `inline` 压到 2，让它正好落进折叠段。
  group('④ 折叠不许丢掉复合控件（泛型不是 int 的菜单）', () {
    const double auditWidth = 1148 / 2.75; // r121 审计真机：1148×2492 @2.75

    Future<void> pumpMixed(WidgetTester tester) async {
      tester.view.physicalSize = Size(auditWidth * 3, 56 * 3 + 600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            appBar: AppBar(
              leading: const SizedBox(width: 56),
              title: const Text('下载'),
              actions: adaptiveActions(
                [
                  IconButton(
                    key: const Key('t-a0'),
                    icon: const Icon(Icons.circle_outlined),
                    onPressed: () {},
                  ),
                  IconButton(
                    key: const Key('t-a1'),
                    icon: const Icon(Icons.circle_outlined),
                    onPressed: () {},
                  ),
                  // ★ 泛型是 `<String>`（`download_page` 的
                  //   `ds-sort-menu`/`ds-batch-menu` 正是这个形态）
                  PopupMenuButton<String>(
                    key: const Key('t-string-menu'),
                    icon: const Icon(Icons.checklist),
                    onSelected: (_) {},
                    itemBuilder: (_) => const [],
                  ),
                  IconButton(
                    key: const Key('t-a2'),
                    icon: const Icon(Icons.circle_outlined),
                    onPressed: () {},
                  ),
                ],
                reserve: 240,
              ),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('落进折叠段的 `PopupMenuButton<String>` 必须仍在工具条上（不许静默消失）',
        (tester) async {
      await pumpMixed(tester);
      // 前提：这一组确实触发了折叠（否则用例量不到那条分支）
      expect(
        find.byKey(const Key('bar-overflow')),
        findsOneWidget,
        reason: '前提：417.45dp + reserve 240 下必须发生折叠',
      );
      expect(
        find.byKey(const Key('t-a2')),
        findsNothing,
        reason: '前提：排在后面的纯 IconButton 确实被折叠进 `⋮` 了',
      );
      expect(
        find.byKey(const Key('t-string-menu')),
        findsOneWidget,
        reason: '★ 复合控件不能丢：它没法进溢出菜单，丢了就等于这个动作消失'
            '（把判据改回 `whereType<PopupMenuButton<int>>()` 这一条会红）',
      );
      expect(tester.takeException(), isNull);
    });

    // ★ 最窄受测宽度 + **多个**复合控件：每一个都必须在（断言"存在"，
    //   不是"没重复"）。窄屏是最容易"折叠掉一半动作"的地方。
    testWidgets('320dp + 两个复合控件（其一排在折叠点之后）⇒ 两个都必须在行内',
        (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 56 * 3 + 600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            appBar: AppBar(
              leading: const SizedBox(width: 56),
              title: const Text('下载'),
              // 两个菜单分别放在折叠点前/后（第 4 个位置一定会被折到）
              actions: adaptiveActions(
                [
                  IconButton(
                    key: const Key('n-a0'),
                    icon: const Icon(Icons.circle_outlined),
                    onPressed: () {},
                  ),
                  PopupMenuButton<String>(
                    key: const Key('n-menu-1'),
                    icon: const Icon(Icons.sort),
                    onSelected: (_) {},
                    itemBuilder: (_) => const [],
                  ),
                  IconButton(
                    key: const Key('n-a1'),
                    icon: const Icon(Icons.circle_outlined),
                    onPressed: () {},
                  ),
                  PopupMenuButton<String>(
                    key: const Key('n-menu-2'),
                    icon: const Icon(Icons.checklist),
                    onSelected: (_) {},
                    itemBuilder: (_) => const [],
                  ),
                ],
                reserve: 160,
              ),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('bar-overflow')),
        findsOneWidget,
        reason: '前提：320dp 下确实发生了折叠',
      );
      for (final k in const ['n-menu-1', 'n-menu-2']) {
        expect(
          find.byKey(Key(k)),
          findsOneWidget,
          reason: '★ 最窄宽度下 $k（复合控件）也必须在 —— 折叠只能折 `IconButton`',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ⑤ ★★ 第 344 轮（D56）：**复合控件占的行内格子必须记进宽度预算**
  //
  // 真机缺陷（2026-10-10，相册大图页，375dp）：工具条上出现 **6 格**
  // （删除 / 幻灯片 / 加入相册 / 旋转 / 相册操作 / 更多），标题只剩约 39dp ⇒
  // 逐字渲染成 **一个字符** `2…`（文件名那一行整个看不见）。
  //
  // 根因：`FoldingActions` 按 `reserve`（默认 112dp）算 `inline`，但行内的
  // **复合控件（`PopupMenuButton`）恒不被折叠**、还会被"换回行内"（不许静默丢）
  // ⇒ 实际行宽 = `inline + fixed` 格，比预算**多 `fixed` 格**。
  // 修法：把 `fixed * slot` 记进 `reserve`、候选数减成"可折叠的那些"。
  //
  // 两条判据（都钉在"意图"上，不是钉实现）：
  //  ① 预算不变量：行内格数 + 复合控件格数 + 折叠格数 ≤ floor((w-reserve)/slot)；
  //  ② 用户可见意图：375dp 真机宽度下，**标题区至少 60dp**（够念出文件名）。
  // ★ 反向验证：把 `reserve + fixed * AdaptiveActions.slot` 改回 `reserve`
  //   这一组两条当场红（实测 ① 6 > 5、② 标题 23dp < 60dp）。
  group('⑤ 复合控件占的格子必须进预算（否则标题被挤成"一个字符"）', () {
    /// 相册大图页的真实形态：12 个 `IconButton` + 1 个 `PopupMenuButton`
    /// （`相册操作`），标题是**两行**（文件名 + 日期·第几张）。
    Future<void> pumpViewerLike(WidgetTester tester, {required double width}) async {
      tester.view.physicalSize = Size(width * 3, barHeight * 3 + 600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(),
          home: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                key: const Key('t-back'),
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back),
                onPressed: () {},
              ),
              title: Column(
                key: const Key('t-title'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Screenshot_20261010-092316.png',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('2026年10月10日 · 2/2', style: TextStyle(fontSize: 11)),
                ],
              ),
              actions: adaptiveActions([
                for (var i = 0; i < 12; i++)
                  IconButton(
                    key: Key('t-action-$i'),
                    tooltip: 'action $i',
                    icon: const Icon(Icons.circle_outlined),
                    onPressed: () {},
                  ),
                PopupMenuButton<String>(
                  key: const Key('t-menu'),
                  tooltip: '相册操作',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (_) {},
                  itemBuilder: (_) => const [],
                ),
              ]),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('375dp（本机真机宽度）：行宽不超预算，且标题 ≥ 60dp',
        (tester) async {
      const width = 375.0;
      await pumpViewerLike(tester, width: width);
      final inline = actionRects(tester, 12).length;
      final composite = find.byKey(const Key('t-menu')).evaluate().length;
      final overflow = overflowCount(tester);
      expect(composite, 1, reason: '前提：复合控件必须在行内（不许被折叠/丢弃）');
      expect(overflow, 1, reason: '前提：375dp 放不下 13 个 ⇒ 必须折叠');
      final budget =
          ((width - 112) / AdaptiveActions.slot).floor(); // reserve 默认 112
      final used = inline + composite + overflow;
      expect(
        used,
        lessThanOrEqualTo(budget),
        reason: '★ 行宽预算：inline($inline) + 复合($composite) + 折叠($overflow)'
            ' = $used 格 > 预算 $budget 格 ⇒ 多出来的格子是从标题身上抢的'
            '（真机就是这么把标题挤成 `2…` 的）',
      );
      final title = tester.getSize(find.byKey(const Key('t-title'))).width;
      expect(
        title,
        greaterThanOrEqualTo(60),
        reason: '★ 用户可见意图：标题区 $title dp < 60dp ⇒ 文件名念不出来'
            '（真机逐字只有 `2…`）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('800dp 测试窗口：一格都不折（既有 key 断言不受影响）',
        (tester) async {
      await pumpViewerLike(tester, width: 800);
      expect(overflowCount(tester), 0, reason: '800dp 放得下 12+1 ⇒ 不折叠');
      expect(actionRects(tester, 12), hasLength(12));
      expect(find.byKey(const Key('t-menu')), findsOneWidget);
    });
  });
}
