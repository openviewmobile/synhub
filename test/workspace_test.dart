// 工作台启动器测试（2026-09-19 改版）。
//
// 改版背景（用户拍板）：模块只会越来越多，所以**只保留启动器网格**、取消列表模式；
// 一屏放不下就左右滑动翻屏；搜索条**吸顶常驻**；排序**按使用习惯学习**。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_pages.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';
import 'package:synhub/src/features/shell/workspace_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真机比例（574×1246 逻辑像素）——默认 800×600 的测试视口会让磁贴挤成好几屏，
/// 反而看不出"一屏放得下"。
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  String? seedUsage,
  String? seedHidden,
  Size physical = const Size(1148, 2492),
}) async {
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  final db = ChatDatabase(NativeDatabase.memory());
  if (seedUsage != null) {
    await ChatStore(db).setSetting(kWorkspaceUsageKey, seedUsage);
  }
  if (seedHidden != null) {
    await ChatStore(db).setSetting(kWorkspaceHiddenKey, seedHidden);
  }
  final container = ProviderContainer(
    overrides: [chatDatabaseProvider.overrideWithValue(db)],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const WorkspaceTab(),
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
      ),
    ),
  );
  // 启动时 app.dart 会 preload 统计与"收起过哪些入口"；这里手动补上
  await container.read(workspaceUsageProvider.notifier).preload();
  await container.read(workspaceHiddenProvider.notifier).preload();
  await tester.pump();
  return container;
}

void main() {
  group('使用统计（排序的数据来源）', () {
    final t0 = DateTime(2026, 10, 25, 12);
    UsageStat stat(double score, {DateTime? at}) =>
        UsageStat(score: score, at: at ?? t0);

    test('用得多的排前面，同档保持默认顺序（稳定）', () {
      const items = ['a', 'b', 'c', 'd'];
      final sorted = sortByUsage(items, (s) => s, {
        'c': stat(4),
        'b': stat(1),
      }, now: t0);
      expect(sorted, ['c', 'b', 'a', 'd']);
    });

    test('没有统计时就是默认顺序', () {
      const items = ['a', 'b', 'c'];
      expect(sortByUsage(items, (s) => s, const {}, now: t0), ['a', 'b', 'c']);
    });

    // ---------------------------------------------------------- r661 时段加权

    test('半衰期：7 天前的一次点击只值今天的一半', () {
      final old = UsageStat(score: 4, at: t0.subtract(kUsageHalfLife));
      expect(old.scoreAt(t0), closeTo(2, 1e-9));
      // 14 天前 ⇒ 1/4
      final older = UsageStat(score: 4, at: t0.subtract(kUsageHalfLife * 2));
      expect(older.scoreAt(t0), closeTo(1, 1e-9));
      // 未来/同一时刻不放大
      expect(UsageStat(score: 3, at: t0).scoreAt(t0), 3);
      expect(
        UsageStat(score: 3, at: t0.add(const Duration(days: 3))).scoreAt(t0),
        3,
        reason: '时间戳比现在还晚时不许把分数放大',
      );
    });

    test('冷下去：上个月的老习惯让位给刚用过的模块', () {
      const items = ['old', 'new', 'rest'];
      final sorted = sortByUsage(items, (s) => s, {
        // 90 天前用了 20 次 ⇒ 等效 20 * 0.5^(90/7) ≈ 0.03
        'old': UsageStat(score: 20, at: t0.subtract(const Duration(days: 90))),
        'new': UsageStat(score: 1, at: t0),
      }, now: t0);
      expect(sorted.first, 'new', reason: '近期的 1 次要压过 90 天前的 20 次');
    });

    test('分档迟滞：差不到 25% 的两个模块不换位（这就是"图标乱跳"的修法）', () {
      const items = ['a', 'b'];
      List<String> order(double a, double b) =>
          sortByUsage(items, (s) => s, {'a': stat(a), 'b': stat(b)}, now: t0);
      // 同一档（相差 20%）：b 的原始分更高也不许把 a 顶下去
      expect(order(1.0, 1.2), ['a', 'b']);
      // 跨档（高出一倍）：这时才真的换位 —— 证明"不换位"不是"永远不排序"
      expect(order(1.0, 2.0), ['b', 'a']);
    });

    test('跨档才换位：高出 25% 以上才真的往前挪', () {
      const items = ['a', 'b'];
      final sorted = sortByUsage(items, (s) => s, {
        'a': stat(1.0),
        'b': stat(2.0),
      }, now: t0);
      expect(sorted, ['b', 'a']);
    });

    test('老数据迁移：整数次数补上时刻并回写（否则老数据永不衰减）', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await ChatStore(db).setSetting(kWorkspaceUsageKey, '{"audio":96}');
      final c = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(c.dispose);
      final now = DateTime(2026, 10, 25, 12);
      await c.read(workspaceUsageProvider.notifier).preload(now: now);
      final stat = c.read(workspaceUsageProvider)['audio']!;
      expect(stat.score, 96);
      expect(stat.at, now, reason: '老数据当作"最后一次使用就是现在"');
      // 落库已改成新格式（有 s/t），下次启动不用再迁移
      final raw = await ChatStore(db).setting(kWorkspaceUsageKey);
      expect(jsonDecode(raw!)['audio']['t'], now.millisecondsSinceEpoch);
    });

    test('老的整数次数照样能读（当作此刻的等分数，不清用户数据）', () {
      final usage = decodeWorkspaceUsage('{"file":2,"notes":1}');
      expect(usage['file']!.score, 2);
      expect(usage['file']!.at, isNull);
      expect(usage, hasLength(2));
    });

    test('编码/解码：分数+时刻往返一致，坏值不炸', () {
      final usage = {
        'file': stat(3.5),
        'notes': stat(0.25, at: t0.subtract(const Duration(days: 2))),
      };
      final back = decodeWorkspaceUsage(encodeWorkspaceUsage(usage));
      expect(back['file']!.score, closeTo(3.5, 1e-9));
      expect(back['notes']!.score, closeTo(0.25, 1e-9));
      expect(back['notes']!.at, usage['notes']!.at);
      // 垃圾值
      expect(decodeWorkspaceUsage('{"a":{"s":0},"b":{"s":-1},"c":{"s":"x"}}'),
          isEmpty);
      expect(decodeWorkspaceUsage('{"a":{"s":2}}')['a']!.at, isNull);
      expect(decodeWorkspaceUsage('[]'), isEmpty);
    });

    test('重复点击只影响自己的名次，不打乱其他人', () {
      const items = ['a', 'b', 'c'];
      final once = sortByUsage(items, (s) => s, {'c': stat(1)}, now: t0);
      final twice = sortByUsage(items, (s) => s, {
        'c': stat(2),
        'a': stat(1),
      }, now: t0);
      expect(once, ['c', 'a', 'b']);
      expect(twice, ['c', 'a', 'b']);
    });

    test('解析：空/垃圾值都不炸（非正数直接丢掉）', () {
      expect(decodeWorkspaceUsage(''), isEmpty);
      expect(decodeWorkspaceUsage(null), isEmpty);
      expect(decodeWorkspaceUsage('不是 JSON'), isEmpty);
      expect(decodeWorkspaceUsage('{"a":0,"b":-3,"c":"5"}'), isEmpty);
    });

    test('解析"收起过哪些入口"：正常/空/垃圾值都不炸', () {
      expect(decodeWorkspaceHidden('["photos"]'), {'photos'});
      expect(decodeWorkspaceHidden('[]'), isEmpty);
      expect(decodeWorkspaceHidden(null), isEmpty);
      expect(decodeWorkspaceHidden('不是 JSON'), isEmpty);
      expect(decodeWorkspaceHidden('{"a":1}'), isEmpty, reason: '只接受数组');
      expect(decodeWorkspaceHidden('["a","",  "b"]'), {'a', 'b'});
    });

    test('收起/还原都会落库，冷启动能恢复', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(c.dispose);
      await c.read(workspaceHiddenProvider.notifier).hide(['photos', 'chat']);
      expect(c.read(workspaceHiddenProvider), {'photos', 'chat'});
      expect(jsonDecode((await ChatStore(db).setting(kWorkspaceHiddenKey))!), [
        'chat',
        'photos',
      ]);

      final fresh = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(fresh.dispose);
      await fresh.read(workspaceHiddenProvider.notifier).preload();
      expect(fresh.read(workspaceHiddenProvider), {'photos', 'chat'});

      await fresh.read(workspaceHiddenProvider.notifier).showAll();
      expect(fresh.read(workspaceHiddenProvider), isEmpty);
      expect(
        jsonDecode((await ChatStore(db).setting(kWorkspaceHiddenKey))!),
        isEmpty,
      );
    });

    test('点一次就落库（下次冷启动还能记住）', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      final now = DateTime(2026, 10, 25, 12);
      await container
          .read(workspaceUsageProvider.notifier)
          .record('notes', now: now);
      await container
          .read(workspaceUsageProvider.notifier)
          .record('notes', now: now);
      await container
          .read(workspaceUsageProvider.notifier)
          .record('files', now: now);
      expect(container.read(workspaceUsageProvider)['notes']!.score, 2);
      expect(container.read(workspaceUsageProvider)['files']!.score, 1);

      // 落库的是"分数 + 时刻"，不是裸次数
      final raw = await ChatStore(db).setting(kWorkspaceUsageKey);
      expect(jsonDecode(raw!), {
        'notes': {'s': 2.0, 't': now.millisecondsSinceEpoch},
        'files': {'s': 1.0, 't': now.millisecondsSinceEpoch},
      });

      // 新容器 preload 回来 = 冷启动能恢复
      final fresh = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(fresh.dispose);
      await fresh.read(workspaceUsageProvider.notifier).preload();
      expect(fresh.read(workspaceUsageProvider)['notes']!.score, 2);
      expect(fresh.read(workspaceUsageProvider)['files']!.score, 1);
      expect(
        fresh.read(workspaceUsageProvider)['notes']!.at,
        now,
      );
    });
  });

  group('启动器（只有网格）', () {
    testWidgets('铺出模块磁贴；列表模式与切换按钮都没了', (tester) async {
      await _pump(tester);
      for (final label in ['文件', '笔记', '相册', '联系人', '日历', '后台任务']) {
        expect(find.text(label), findsOneWidget, reason: '缺少磁贴：$label');
      }
      // 列表模式专属的东西全部消失
      expect(find.byTooltip('切换到列表（全部入口）'), findsNothing);
      expect(find.byTooltip('切换到网格（模块视图）'), findsNothing);
      expect(find.text('模块'), findsNothing);
      expect(find.text('即将接入'), findsNothing);
      expect(find.text('收藏'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点磁贴真的跳：笔记 → 笔记页；文件 → 文件 Tab', (tester) async {
      final c = await _pump(tester);
      await tester.tap(find.text('笔记'));
      await tester.pumpAndSettle();
      expect(find.text('笔记'), findsWidgets);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('文件'));
      await tester.pump();
      // 文件磁贴是切 tab（不是推页面）
      expect(c.read(appTabProvider), AppTab.files);
    });

    testWidgets('点一下就记一次使用统计', (tester) async {
      final c = await _pump(tester);
      await tester.tap(find.text('日历'));
      await tester.pumpAndSettle();
      expect(c.read(workspaceUsageProvider)['calendar']!.score, 1);
    });

    // DA276：用户 2026-10-25 报「工作台图标会漂」—— 排序从"累计次数"改成
    // "时段加权（7 天半衰期）＋ 25% 分档迟滞"，并在本会话内定格。
    testWidgets('★ DA276 本次运行期间点完不换位（图标不许从手指底下漂走）', (tester) async {
      // 文件与笔记同档（都是 3 分），默认顺序文件在前；点一次笔记
      // （3 → 4，已跨档、本该越过文件）之后**先后顺序一格都不许动**
      // —— 这正是用户报的"图标会漂"的修法。
      final c = await _pump(tester, seedUsage: '{"files":3,"notes":3}');
      // 按**磁贴 id** 定位（「最近使用」区里也有同名文字，按文案找会撞车）；
      // 比相对名次而不是绝对坐标：点开一个模块会让上面的「最近使用」长高、
      // 整块网格下移 —— 那是真实内容，不算漂。
      const ids = ['files', 'notes', 'photos', 'contacts', 'calendar'];
      List<String> gridOrder() {
        final pos = {
          for (final id in ids)
            id: tester.getTopLeft(find.byKey(Key('ws-tile-$id'))),
        };
        return ids.toList()
          ..sort((a, b) {
            final pa = pos[a]!, pb = pos[b]!;
            final byY = pa.dy.compareTo(pb.dy);
            return byY != 0 ? byY : pa.dx.compareTo(pb.dx);
          });
      }

      final before = gridOrder();
      await tester.tap(find.byKey(const Key('ws-tile-notes')));
      await tester.pumpAndSettle();
      // 统计确实加上去了（3 → 4，已经跨档；只是本会话的排序不动）
      // 3 分是种子（时刻＝preload 那一刻），点上 1 次后略带衰减 ⇒ 约 4
      expect(c.read(workspaceUsageProvider)['notes']!.score, closeTo(4, 1e-3));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        gridOrder(),
        before,
        reason: '点完一次之后，磁贴的先后顺序一格都不该变',
      );
    });

    testWidgets('按使用习惯排：常用的浮到第一屏第一位', (tester) async {
      await _pump(tester, seedUsage: '{"search":9}');
      // "搜索文件"默认在最后，统计 9 次后应该排到最前
      final first = tester.getTopLeft(find.text('搜索文件'));
      final other = tester.getTopLeft(find.text('文件'));
      expect(first.dy, lessThanOrEqualTo(other.dy));
      expect(first.dx, lessThanOrEqualTo(other.dx + 1));
    });
  });

  group('吸顶搜索条', () {
    testWidgets('输入即筛模块；清除后回到全部', (tester) async {
      await _pump(tester);
      await tester.enterText(find.byKey(const Key('ws-search')), '日');
      await tester.pump();
      expect(find.text('日历'), findsOneWidget);
      expect(find.text('相册'), findsNothing);
      expect(find.text('笔记'), findsNothing);

      await tester.tap(find.byKey(const Key('ws-search-clear')));
      await tester.pump();
      expect(find.text('相册'), findsOneWidget);
      expect(find.text('笔记'), findsOneWidget);
    });

    testWidgets('筛选着点进去，回来是完整启动器（不留筛选态）', (tester) async {
      await _pump(tester);
      await tester.enterText(find.byKey(const Key('ws-search')), '笔');
      await tester.pump();
      expect(find.text('相册'), findsNothing);
      await tester.tap(find.text('笔记'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      // 回到启动器：筛选态已清，所有模块都在
      expect(find.text('相册'), findsOneWidget);
      // 点过"笔记"之后它还会出现在顶部的「最近常用」横滑条里 → 文案出现两次
      expect(find.text('笔记'), findsWidgets);
      expect(find.text('日历'), findsOneWidget);
    });

    testWidgets('没命中就提示，并给一个"去文件里搜"的出口', (tester) async {
      await _pump(tester);
      await tester.enterText(find.byKey(const Key('ws-search')), 'zzz');
      await tester.pump();
      expect(find.text('没有匹配的模块'), findsOneWidget);
      await tester.tap(find.text('在文件里搜索「zzz」'));
      await tester.pumpAndSettle();
      expect(find.byType(FileSearchPage), findsOneWidget);
    });

    testWidgets('回车直接进文件搜索（带关键词）', (tester) async {
      await _pump(tester);
      await tester.enterText(find.byKey(const Key('ws-search')), 'report');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      final page = tester.widget<FileSearchPage>(find.byType(FileSearchPage));
      expect(page.initialQuery, 'report');
    });
  });

  group('分屏（模块多了左右滑）', () {
    testWidgets('一屏放不下：出现屏点，左滑到第二屏能看到剩下的模块', (tester) async {
      // 小视口制造"放不下"：400×600 逻辑像素
      await _pump(tester, physical: const Size(800, 1200));
      expect(find.byKey(const Key('ws-pager')), findsOneWidget);
      // 第一屏有前面几个模块，最后一个模块在第二屏
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('搜索文件'), findsNothing);
      // 屏点出现（≥2 屏）
      expect(find.byKey(const Key('ws-dot-0')), findsOneWidget);
      expect(find.byKey(const Key('ws-dot-1')), findsOneWidget);

      await tester.drag(
        find.byKey(const Key('ws-pager')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('搜索文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已被「使用分析」收起的入口不上第一屏，但还能搜到、也能一键还原', (tester) async {
      final c = await _pump(tester, seedHidden: '["photos","calendar"]');
      expect(find.text('相册'), findsNothing, reason: '收起的不该出现');
      expect(find.text('日历'), findsNothing);
      expect(find.text('已收起 2 个没用过的模块'), findsOneWidget);

      // 搜索不受影响（藏起来的也能搜到，不然就成了"功能消失"）
      await tester.enterText(find.byType(TextField), '相册');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('相册'), findsWidgets);

      // 清空搜索 → 点「显示全部」还原
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('显示全部'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('相册'), findsWidgets);
      expect(find.text('已收起 2 个没用过的模块'), findsNothing);
      expect(c.read(workspaceHiddenProvider), isEmpty);
    });

    testWidgets('一屏放得下就不显示屏点（不占地方）', (tester) async {
      // 2026-09-21：工作台曾新增 office / drive 两个磁贴（共 13 个），在这个
      // 真机比例下会溢出到第二屏。2026-09-22 用户拍板撤掉这两个磁贴 → 回到
      // 11 个入口，实测**一屏放得下**，所以这条"不变量"用例不再需要靠
      // `seedHidden` 人工腾地方：直接跑 11 入口本身就是放得下的（见下面
      // 「如实记录」用例）。
      await _pump(tester);
      expect(find.byKey(const Key('ws-dot-0')), findsNothing);
      expect(find.byKey(const Key('ws-dot-1')), findsNothing);
      expect(find.text('文件'), findsOneWidget);
    });

    testWidgets('如实记录：真机比例（574×1246）下 11 个入口回到一屏', (tester) async {
      // 与上面那条用例同一个视口（`_pump` 默认 1148×2492 @2.0 = 574×1246，就是
      // R5/R6 真机的逻辑尺寸）。
      //
      // 历史（可追溯，别把结论当"改测试凑绿"）：2026-09-21 工作台扩容到 13 个
      // 入口（多出 office / drive），这个比例下**确实翻第二屏**，当时的用例
      // 如实钉住了"屏点出现"。2026-09-22 用户拍板「Office 的入口在 Drive 里」
      // → 撤掉 office / drive 两个磁贴，回到 11 个入口；同一个视口下**重新实测**
      // 放得下 → 屏点消失、所有入口都在第一屏。这里钉的是**新的事实**，
      // 不是把断言删掉。
      await _pump(tester);
      expect(
        find.byKey(const Key('ws-dot-0')),
        findsNothing,
        reason: '11 个入口在真机比例下放得下 → 不该出现屏点',
      );
      expect(find.byKey(const Key('ws-dot-1')), findsNothing);
      // 撤掉的两个入口确实不在工作台
      expect(find.byKey(const Key('ws-tile-office')), findsNothing);
      expect(find.byKey(const Key('ws-tile-drive')), findsNothing);
      // 11 个入口一个不少
      for (final id in [
        'files',
        'notes',
        'photos',
        'contacts',
        'calendar',
        'tasks',
        'search',
        'downloads',
        'audio',
        'surveillance',
        'mailplus',
      ]) {
        expect(
          find.byKey(Key('ws-tile-$id')),
          findsOneWidget,
          reason: '11 入口之一：$id',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });

  test('FakeTransport 仍是可用的注入点（保证测试不碰真网络）', () {
    final t = FakeTransport(const {}, {...FakeTransport.table});
    expect(t.calls, isEmpty);
  });
}
