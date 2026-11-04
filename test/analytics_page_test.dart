// 「使用分析」页 + 埋点入口的离线验证。
//
// 页面这一层要证明的是：结论/统计真的来自**库里的数据**、开关能关、
// 导出/清空真的作用在库上；埋点入口（`track` / `trackOnce`）在
// 有 ref / 没 ref 两种场景下都能落库，且失败不抛。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/local/analytics_database.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/analytics/analytics_page.dart';
import 'package:synhub/src/features/analytics/analytics_providers.dart';
import 'package:synhub/src/features/analytics/analytics_track.dart';
import 'package:synhub/src/features/analytics/usage_analysis.dart';
import 'package:synhub/src/features/analytics/usage_event.dart';
import 'package:synhub/src/features/analytics/usage_log.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/shell/workspace_providers.dart';
import 'support/switch_rows.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AnalyticsDatabase db;
  late UsageLog log;

  setUp(() async {
    db = AnalyticsDatabase.memory();
    log = UsageLog(db);
    await log.load();
    setGlobalUsageLog(log);
  });

  tearDown(() async {
    setGlobalUsageLog(null);
    log.dispose();
    await db.close();
  });

  /// 造 [count] 条像样的历史（够触发"结论"的样本门槛）。
  ///
  /// ⚠️ 必须放在 `tester.runAsync` 里：widget 测试跑在假时钟里，drift 的
  /// 真磁盘/内存 IO（batch + prune）在假时钟下不会推进 → await 直接挂死。
  Future<void> seed(WidgetTester tester, {int count = 60}) async {
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        log.record(
          i % 3 == 0 ? UsageModule.files : UsageModule.notes,
          i % 4 == 0 ? UsageAction.preview : UsageAction.open,
          objectType: i % 2 == 0 ? '.pdf' : 'note',
          at: DateTime(2026, 9, 1 + (i ~/ 20), 9 + (i % 8)),
        );
      }
      await log.flush();
      expect(await log.eventCount(), count);
    });
  }

  Future<void> mountPage(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: UsageAnalyticsPage()),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    // 这一页是"卡片长列表"，600px 的默认画布只够看到最上面几张卡；
    // 给一个高画布，让所有卡片都参与布局（否则 ListView 懒构建，
    // 断言会误判成"没有这条结论"）
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 「收起入口」这条策略要写本地设置 → 需要业务库；给个内存库
    final policyDb = ChatDatabase(NativeDatabase.memory());
    addTearDown(policyDb.close);
    final container = ProviderContainer(
      overrides: [
        analyticsDatabaseProvider.overrideWithValue(db),
        chatDatabaseProvider.overrideWithValue(policyDb),
      ],
    );
    addTearDown(container.dispose);
    // 页面里有两个 FutureProvider（统计 + 结论），都要等库读完：
    // 多 pump 几轮，别让断言撞在骨架屏上
    await mountPage(tester, container);
    return container;
  }

  testWidgets('空库：只给"还没有记录"这条结论，开关默认开', (tester) async {
    await pumpPage(tester);
    expect(find.text('使用分析'), findsOneWidget);
    // 空库也有"数据量"这一条（它明确说"还没有记录"），但不该有习惯类结论
    expect(find.textContaining('已有 0 条使用记录'), findsOneWidget);
    expect(find.textContaining('还没有记录'), findsOneWidget);
    expect(find.textContaining('最常用：'), findsNothing);
    expect(find.text('记录本地使用日志'), findsOneWidget);
  });

  testWidgets('有数据：显示结论卡片 + 统计数字 + 原始事件', (tester) async {
    await seed(tester);
    await pumpPage(tester);

    // 结论里一定有"最常用"（可信度高，在最上面）
    expect(find.textContaining('最常用'), findsWidgets);
    expect(find.textContaining('已有 60 条使用记录'), findsOneWidget);
    // 统计 chips
    expect(find.textContaining('事件 60'), findsWidgets);

    // 展开原始事件：只显示"模块 · 动作 · 类型"，没有内容
    await tester.tap(find.text('看原始事件'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.textContaining('文件 · 预览'), findsWidgets);
  });

  testWidgets('结论卡片可点开看统计口径', (tester) async {
    await seed(tester);
    await pumpPage(tester);
    // ⚠️ 用 `最常用：` 精确定位**卡片标题**：别的卡片的"建议"里也有"最常用"
    // 这个词（时段那条），点错卡片就看错 evidence 了
    await tester.tap(find.textContaining('最常用：').first);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.text('统计口径'), findsOneWidget);
    expect(find.textContaining('distribution'), findsOneWidget);
  });

  testWidgets('重进页面会重算：先 0 条，用了一会儿再进能看到新数据', (tester) async {
    // 真机踩到的坑：统计/结论 provider 不是 autoDispose，第一次打开算出的 0
    // 会一直留着，明明记了事件还是显示 0 → 页面打开时主动 invalidate。
    // 这里用**同一个 container** 模拟"退出去再用一会儿再进来"。
    final container = await pumpPage(tester);
    expect(find.textContaining('已有 0 条'), findsOneWidget);

    await seed(tester, count: 25);

    // 下树再上树 = 重进页面
    await tester.pumpWidget(const SizedBox());
    await mountPage(tester, container);

    expect(find.textContaining('已有 0 条'), findsNothing);
    expect(find.textContaining('已有 25 条使用记录'), findsOneWidget);
  });

  testWidgets('结论 → 策略：一键收起没用过的入口，且能还原', (tester) async {
    // 25 条全是 文件/笔记 → photos/contacts/calendar/chat/search 都没用过
    await seed(tester, count: 25);
    final container = await pumpPage(tester);

    expect(find.textContaining('收起这'), findsOneWidget);
    await tester.tap(find.textContaining('收起这'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final hidden = container.read(workspaceHiddenProvider);
    expect(hidden, isNotEmpty);
    expect(hidden, isNot(contains('files')), reason: '用过的不能收');
    expect(find.textContaining('已收起'), findsOneWidget);

    // 还原
    await tester.tap(find.textContaining('已收起'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(container.read(workspaceHiddenProvider), isEmpty);
    expect(find.textContaining('收起这'), findsOneWidget);
  });

  testWidgets('关掉开关：不再记录新事件，但旧数据还在', (tester) async {
    await seed(tester, count: 24);
    final container = await pumpPage(tester);

    await tester.tap(switchRowFinder);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.textContaining('已关闭'), findsOneWidget);
    // 关了也还能导出/清空（页面自己承诺"可以导出或清空"）
    expect(find.text('导出 JSON'), findsOneWidget);
    expect(find.text('清空'), findsOneWidget);
    expect(find.textContaining('看原始事件'), findsOneWidget);
    // 结论/统计那两块收起来了
    expect(find.textContaining('最常用：'), findsNothing);

    // 开关状态：内存里是 false，库里也落了 '0'
    expect(container.read(analyticsEnabledProvider), isFalse);
    final meta = await tester.runAsync(
      () => db.select(db.analyticsMetaRows).get(),
    );
    expect(meta!.firstWhere((r) => r.key == kMetaEnabled).value, '0');

    // 测试实例自己的开关也仍然是"开"（它是独立对象），但**页面那个**已经关了：
    // 用页面 provider 的 log 记一笔，条数不该变
    final pageLog = container.read(usageLogProvider);
    pageLog.record(UsageModule.chat, UsageAction.open);
    await tester.runAsync(() => pageLog.flush());
    await tester.runAsync(() => log.flush());
    final count = await tester.runAsync(() => log.eventCount());
    expect(count, 24);
  });

  testWidgets('清空：确认后事件和结论都归零', (tester) async {
    await seed(tester, count: 30);
    await pumpPage(tester);
    await tester.tap(find.text('清空'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('清空使用记录？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    final count = await tester.runAsync(() => log.eventCount());
    expect(count, 0);
    // 页面清空后会重新跑一次分析：结论表里只剩下"还没有记录"这一条
    final left = await tester.runAsync(() => log.savedInsights());
    expect(left!.map((i) => i.kind), everyElement(InsightKind.volume));
  });

  testWidgets('导出：把脱敏 JSON 复制到剪贴板', (tester) async {
    await seed(tester, count: 21);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpPage(tester);
    await tester.tap(find.text('导出 JSON'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(copied, isNotNull);
    expect(copied, contains('synhub.usage/1'));
    expect(copied, contains('"events"'));
  });

  group('埋点入口', () {
    testWidgets('track(ref, …) 落到库里', (tester) async {
      final container = ProviderContainer(
        overrides: [analyticsDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      late WidgetRef captured;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Consumer(
              builder: (context, ref, _) {
                captured = ref;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      // 埋点走**全局单例**（setUp 里注入的就是测试这个 log），所以直接读它
      track(
        captured,
        UsageModule.photos,
        UsageAction.switchSection,
        objectType: 'albums',
      );
      await tester.runAsync(() => log.flush());
      final rows = await tester.runAsync(() => log.recent());
      final e = rows!.single;
      expect(e.module, UsageModule.photos);
      expect(e.objectType, 'albums');
    });

    test('trackOnce 在没有 ref 时也能记（全局单例）', () async {
      expect(usageTrackingArmed, isTrue);
      trackOnce(UsageModule.calendar, UsageAction.open);
      await log.flush();
      expect(await log.eventCount(), 1);

      setGlobalUsageLog(null);
      trackOnce(UsageModule.calendar, UsageAction.open);
      await log.flush();
      expect(await log.eventCount(), 1); // 没单例 → 静默丢弃，不抛
    });

    test('trackFile 只留扩展名', () async {
      final container = ProviderContainer(
        overrides: [analyticsDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final ref = container.read(usageLogProvider);
      expect(ref, isNotNull);
      trackOnce(
        UsageModule.files,
        UsageAction.upload,
        objectType: trackObjectOf('客户合同.pdf'),
      );
      await log.flush();
      final e = (await log.recent()).single;
      expect(e.objectType, '.pdf');
      expect(e.objectType.contains('客户'), isFalse);
    });
  });

  // ── 第 275 轮：新增分析维度（按模块 / 采用 / 视图 / 失败原因 / 时长）──────
  testWidgets('统计区：按模块 / 采用 / 视图偏好 / 失败原因 / 时长 都来自库里数据', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 9000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final policyDb = ChatDatabase(NativeDatabase.memory());
    addTearDown(policyDb.close);
    final container = ProviderContainer(
      overrides: [
        analyticsDatabaseProvider.overrideWithValue(db),
        chatDatabaseProvider.overrideWithValue(policyDb),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      // 视图偏好：相册时间线 10 次 + 栅格 4 次
      for (var i = 0; i < 10; i++) {
        log.record(
          UsageModule.photos,
          UsageAction.switchView,
          objectType: 'timeline',
          at: DateTime(2026, 9, 1, 9, i),
        );
      }
      for (var i = 0; i < 4; i++) {
        log.record(
          UsageModule.photos,
          UsageAction.switchView,
          objectType: 'grid',
          at: DateTime(2026, 9, 1, 10, i),
        );
      }
      // 时长：媒体播放 2 次，各 120s / 180s
      for (final ms in [120000, 180000]) {
        log.record(
          UsageModule.media,
          UsageAction.complete,
          objectType: 'video',
          value: ms,
          detail: const {UsageDetailKeys.preset: 'play'},
          at: DateTime(2026, 9, 1, 11),
        );
      }
      // 失败原因：6 次解码失败
      for (var i = 0; i < 6; i++) {
        log.recordFailure(
          UsageModule.media,
          UsageAction.play,
          objectType: 'video',
          reason: UsageFailureReason.decode,
          at: DateTime(2026, 9, 1, 12, i),
        );
      }
      log.record(
        UsageModule.files,
        UsageAction.open,
        at: DateTime(2026, 9, 1, 13),
      );
      await log.flush();
    });

    await mountPage(tester, container);

    // 按模块：files 一行（且 share 能算出来）
    expect(find.byKey(const Key('usage-mod-files')), findsOneWidget);
    expect(find.byKey(const Key('usage-mod-media')), findsOneWidget);
    // 功能采用标题
    expect(find.byKey(const Key('usage-adoption')), findsOneWidget);
    expect(find.textContaining('已采用'), findsOneWidget);
    // 视图偏好：相册 · 时间线 10 次
    expect(find.byKey(const Key('usage-view-photos.timeline')), findsOneWidget);
    expect(find.textContaining('时间线'), findsWidgets);
    // 失败原因：影音 · 解码或渲染失败 6 次（可查询的原因码）
    expect(find.byKey(const Key('usage-fail-media.decode')), findsOneWidget);
    expect(find.textContaining('解码或渲染失败'), findsWidgets);
    // 时长：播放平均 3 分钟（(120+180)/2 s = 150s → 3min）
    expect(find.byKey(const Key('usage-dur-media.play')), findsOneWidget);
    expect(find.textContaining('平均 3 分钟'), findsOneWidget);
    // 统计范围可见
    expect(find.textContaining('统计范围'), findsOneWidget);
  });

  testWidgets('空库：新维度显示"还没有"而不是空白', (tester) async {
    tester.view.physicalSize = const Size(1400, 9000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPage(tester);
    expect(find.text('还没有视图或选项切换记录'), findsOneWidget);
    expect(find.text('没有失败记录'), findsOneWidget);
    expect(find.text('还没有可统计的时长记录'), findsOneWidget);
    expect(find.text('所有模块都至少用过一次'), findsNothing);
  });

  // ── 第 260 轮错误态回归：统计读取失败不能"凭空消失" ──────────────
  // 原来 error 分支渲染 `SizedBox.shrink()`：小标题在、内容没了，
  // 用户看不到原因、也没有重试入口（失败被静默吞掉）。
  testWidgets('统计读取失败 → 明确错误态 + 重试；点重试真的重新取', (tester) async {
    var calls = 0;
    // 用可控开关（首帧可能被 invalidate 多次，只有开关能稳定制造"当前是错误态"）
    var failing = true;
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final policyDb = ChatDatabase(NativeDatabase.memory());
    addTearDown(policyDb.close);
    final container = ProviderContainer(
      overrides: [
        analyticsDatabaseProvider.overrideWithValue(db),
        chatDatabaseProvider.overrideWithValue(policyDb),
        usageStatsProvider.overrideWith((ref) async {
          calls++;
          if (failing) throw Exception('simulated stats failure');
          return computeUsageStats(const []);
        }),
      ],
    );
    addTearDown(container.dispose);

    await mountPage(tester, container);

    expect(
      find.byKey(const Key('usage-stats-error')),
      findsOneWidget,
      reason: '★ 失败必须给错误态，不能渲染成"什么都没有"',
    );
    expect(find.textContaining('重试'), findsWidgets, reason: '★ 必须给重试入口');
    final before = calls;

    failing = false;
    await tester.tap(find.textContaining('重试').first);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(calls, greaterThan(before), reason: '★★ 点重试必须真的重新取统计');
    expect(find.byKey(const Key('usage-stats-error')), findsNothing);
  });
}
