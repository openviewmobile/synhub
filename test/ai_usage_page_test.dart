// 「AI 用量与费用」页（界面层，离线）。
//
// 只管展示与交互：数字本身在 `ai_usage_test.dart` 里验。这里盯的是
// **"本地估算、不是账单"这句话有没有摆在眼前**，以及时间窗、分组、
// 清空这些操作真的动了数据。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/ai/cloud_pricing.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/ai_usage_page.dart';
import 'package:synhub/src/features/ai/cloud_settings.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider, chatStoreProvider;

Future<ProviderContainer> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      cloudKeyStoreProvider.overrideWithValue(MemoryCloudKeyStore()),
    ],
  );
  addTearDown(c.dispose);
  await c.read(cloudSettingsProvider.notifier).preload();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        localizationsDelegates: AppText.localizationsDelegates,
        supportedLocales: AppText.supportedLocales,
        home: const AiUsagePage(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return c;
}

CloudUsageRecord _rec({
  required int atMs,
  required String model,
  int prompt = 0,
  int completion = 0,
  double cost = 0,
  bool priced = true,
  bool estimated = false,
}) => CloudUsageRecord(
  atMs: atMs,
  usage: CloudTokenUsage(
    promptTokens: prompt,
    completionTokens: completion,
    totalTokens: prompt + completion,
    estimated: estimated,
  ),
  model: model,
  costUsd: cost,
  priced: priced,
);

Future<void> _seed(ProviderContainer c, List<CloudUsageRecord> list) async {
  final n = c.read(cloudSettingsProvider.notifier);
  for (final r in list) {
    await n.recordUsage(r);
  }
}

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final old = DateTime.now()
      .subtract(const Duration(days: 20))
      .millisecondsSinceEpoch;

  testWidgets('没有记录：空态 + 两段"这只是本地估算"的说明', (tester) async {
    await _pump(tester);
    expect(find.text('用量与费用'), findsOneWidget);
    expect(find.text('还没有云端调用记录'), findsOneWidget);
    expect(find.textContaining('用云端模型跑一次总结'), findsOneWidget);
    // 免责说明必须在第一屏（不能只在文档里）
    expect(find.textContaining('这不是服务商的账单'), findsOneWidget);
    expect(find.textContaining('单价表更新于'), findsOneWidget);
  });

  testWidgets('有记录：合计卡 + 按模型 + 按日期', (tester) async {
    final c = await _pump(tester);
    await _seed(c, [
      _rec(
        atMs: now,
        model: 'gpt-4o-mini',
        prompt: 1000,
        completion: 500,
        cost: 0.00045,
      ),
      _rec(
        atMs: now,
        model: 'deepseek-reasoner',
        prompt: 2000,
        completion: 800,
        // 单价未知的记录**不带费用**（真机上报价也不会给这个模型估价）
        priced: false,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('还没有云端调用记录'), findsNothing);
    expect(find.text('2 次调用'), findsOneWidget);
    expect(find.text('输入 token：3000'), findsOneWidget);
    expect(find.text('输出 token：1300'), findsOneWidget);
    expect(find.text('合计 token：4300'), findsOneWidget);
    // 单价未知的要单独列出来（不能混进合计当 0）
    expect(find.text('1 次未计价（单价未知）'), findsOneWidget);
    // 有计价记录时，费用格给真实数字（小额给 4 位小数，不是约 US$0）
    expect(find.textContaining('约 US\$0.000'), findsWidgets);
    expect(find.text('按模型'), findsOneWidget);
    expect(find.text('按日期'), findsOneWidget);
    expect(find.textContaining('gpt-4o-mini'), findsWidgets);
    expect(find.textContaining('deepseek-reasoner'), findsWidgets);
    // 日期分组用的是 YYYY-MM-DD
    final dayKey = cloudUsageDayKey(now);
    expect(find.text(dayKey), findsOneWidget);
  });

  testWidgets('全部单价未知：费用格显示「单价未知」，不能写成约 US\$0（真机误导过）', (tester) async {
    final c = await _pump(tester);
    await _seed(c, [
      _rec(
        atMs: now,
        model: 'deepseek-v4.1-flash',
        prompt: 134,
        completion: 1478,
        priced: false,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('合计 token：1612'), findsOneWidget);
    expect(find.text('1 次未计价（单价未知）'), findsOneWidget);
    expect(find.text('单价未知'), findsWidgets);
    expect(find.text('约 US\$0'), findsNothing);
  });

  testWidgets('token 是估算的会单独标出来', (tester) async {
    final c = await _pump(tester);
    await _seed(c, [
      _rec(
        atMs: now,
        model: 'gpt-4o-mini',
        prompt: 10,
        completion: 5,
        estimated: true,
        cost: 0.000001,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('其中 1 次的 token 是估算'), findsOneWidget);
  });

  testWidgets('时间窗：切到"近 7 天"就把 20 天前的调用排除掉', (tester) async {
    final c = await _pump(tester);
    await _seed(c, [
      _rec(
        atMs: now,
        model: 'gpt-4o-mini',
        prompt: 100,
        completion: 0,
        cost: 0.001,
      ),
      _rec(atMs: old, model: 'old-model', prompt: 5000, completion: 0, cost: 1),
    ]);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('2 次调用'), findsOneWidget);

    await tester.tap(find.text('近 7 天'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('1 次调用'), findsOneWidget);
    expect(find.text('输入 token：100'), findsOneWidget);
    expect(find.textContaining('old-model'), findsNothing);
  });

  testWidgets('清空：先确认，确认后记录清掉、KV 也清掉', (tester) async {
    final c = await _pump(tester);
    await _seed(c, [
      _rec(atMs: now, model: 'gpt-4o-mini', prompt: 10, cost: 0.0001),
    ]);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    // 确认框里明确"不影响服务商账单"
    expect(find.textContaining('不影响服务商那边的账单'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('还没有云端调用记录'), findsOneWidget);
    expect(c.read(cloudSettingsProvider).usage, isEmpty);
    final raw = await SettingsService(c.read(chatStoreProvider)).aiCloudUsage();
    expect(raw, anyOf(isNull, isEmpty));
  });

  testWidgets('取消清空：记录还在（防误触）', (tester) async {
    final c = await _pump(tester);
    await _seed(c, [
      _rec(atMs: now, model: 'gpt-4o-mini', prompt: 10, cost: 0.0001),
    ]);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(c.read(cloudSettingsProvider).usage, hasLength(1));
    expect(find.text('1 次调用'), findsOneWidget);
  });

  testWidgets('英文环境：标题与免责说明也是英文（批次 2d）', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final db = ChatDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final c = ProviderContainer(
      overrides: [
        chatDatabaseProvider.overrideWithValue(db),
        cloudKeyStoreProvider.overrideWithValue(MemoryCloudKeyStore()),
      ],
    );
    addTearDown(c.dispose);
    await c.read(cloudSettingsProvider.notifier).preload();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('en'),
          localizationsDelegates: AppText.localizationsDelegates,
          supportedLocales: AppText.supportedLocales,
          home: const AiUsagePage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Usage & cost'), findsOneWidget);
    expect(find.text('No cloud calls recorded yet'), findsOneWidget);
    expect(find.textContaining('not your provider bill'), findsOneWidget);
  });
}
