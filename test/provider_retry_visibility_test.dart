// Riverpod 3 会**对失败做指数退避自动重试**（只重试 `Exception` 子类；见
// `riverpod-3.4.3/lib/src/core/provider_container.dart:983` 的 `defaultRetry`），
// 我们的网络 / API 层抛的正是自定义 `Exception` ⇒ 不加 `retry: noRetry` 时，
// 失败会被重试最多 10 次（累计二十余秒），界面在这期间**停在骨架屏**，
// 等于"把失败渲染成空 / 无限转圈"。
//
// 这个套件是那个缺陷的**判别性**回归：
//   * 失败态用例断言"**重试窗口内**已经出现错误态（重试按钮）"，而**不是**
//     "最终会失败" —— 后者抓不到"停在骨架屏"；
//   * 用 `tester.pump(2500ms)` 停在退避窗口（200/400/800/1600ms）之内断言；
//   * 末尾的阳性对照证明这套断言确实能抓到"停在 loading"。
//
// 被覆盖的真实 provider（都来自本批补齐 `retry:` 的文件）：
//   * `aiReadinessProvider`（ai/ai_providers.dart）
//   * `noteReminderStatusProvider`（notes/note_reminder_platform.dart）
//   * `cacheUsageProvider`（settings/settings_page.dart）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/cache_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart'
    show cacheServiceProvider;
import 'package:synhub/src/features/ai/ai_providers.dart';
import 'package:synhub/src/features/ai/llm_engine.dart';
import 'package:synhub/src/features/ai/on_device_ai.dart';
import 'package:synhub/src/features/notes/note_reminder_platform.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/settings/settings_page.dart'
    show cacheUsageProvider;

/// 把 `AsyncValue` 按"页面语义"渲染：data / loading（骨架屏）/ error（重试按钮）。
class _AsyncProbe<T> extends ConsumerWidget {
  const _AsyncProbe(this.provider);

  final FutureProvider<T> provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(provider)
        .when(
          data: (_) => const Text('data'),
          loading: () => const Text('loading'),
          error: (_, _) =>
              TextButton(onPressed: () {}, child: const Text('retry')),
        );
  }
}

/// 起探针并在**退避窗口内**停下。
Future<void> _pumpIntoRetryWindow(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.pump(); // 让 create 的异步体先跑一次
  // 停在默认退避窗口（200/400/800/1600ms…）之内：这时若还在重试，
  // 界面就仍是 loading —— 这正是本缺陷的判别点。
  await tester.pump(const Duration(milliseconds: 2500));
}

void _expectFailureVisible() {
  expect(
    find.text('loading'),
    findsNothing,
    reason: '界面停在骨架屏 = 把失败渲染成空 / 无限转圈（本缺陷要修的就是这个）',
  );
  expect(
    find.text('retry'),
    findsOneWidget,
    reason: '失败必须在重试窗口内可见（错误态 / 重试按钮），重试交给用户点按钮',
  );
}

// ------------------------------------------------------------------ 假依赖
// ⚠️ 必须让**被策 provider 自己的 body** 抛 `Exception`（而不是让被 watch 的
// provider 抛）—— provider 之间的错误会被包成 `ProviderException`，而 Riverpod
// 恰好**不**重试它，那样就复现不出本缺陷。

class _ThrowingEngine implements LlmEngine {
  @override
  AiEngineKind get kind => AiEngineKind.extractive;

  @override
  Future<LlmStatus> status() async => throw Exception('boom: engine.status');

  @override
  Stream<String> generate(LlmPrompt prompt) => throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

class _ThrowingReminderPlatform implements NoteReminderPlatform {
  @override
  Future<NoteReminderStatus> status() async =>
      throw Exception('boom: platform.status');

  @override
  Future<NoteReminderStatus> requestPermissions() => status();

  @override
  Future<bool> schedule(NoteReminderPlan plan) =>
      throw Exception('boom: platform.schedule');

  @override
  Future<void> cancelAll() => throw Exception('boom: platform.cancelAll');

  @override
  void dispose() {}
}

class _ThrowingCacheService extends CacheService {
  @override
  Future<CacheUsage> usage({int limitBytes = 0}) async =>
      throw Exception('boom: cache.usage');
}

/// 阳性对照：**没有** `retry: noRetry` 的 `FutureProvider`。
final _defaultRetryProvider = FutureProvider<int>((ref) async {
  throw Exception('boom: default retry');
});

void main() {
  testWidgets('aiReadinessProvider：读取失败立刻可见', (tester) async {
    await _pumpIntoRetryWindow(
      tester,
      ProviderScope(
        overrides: [aiEngineProvider.overrideWithValue(_ThrowingEngine())],
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: _AsyncProbe(aiReadinessProvider)),
        ),
      ),
    );
    _expectFailureVisible();
  });

  testWidgets('noteReminderStatusProvider：读取失败立刻可见', (tester) async {
    await _pumpIntoRetryWindow(
      tester,
      ProviderScope(
        overrides: [
          noteReminderPlatformProvider.overrideWithValue(
            _ThrowingReminderPlatform(),
          ),
        ],
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: _AsyncProbe(noteReminderStatusProvider)),
        ),
      ),
    );
    _expectFailureVisible();
  });

  testWidgets('cacheUsageProvider：读取失败立刻可见', (tester) async {
    await _pumpIntoRetryWindow(
      tester,
      ProviderScope(
        overrides: [
          cacheServiceProvider.overrideWithValue(_ThrowingCacheService()),
        ],
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: _AsyncProbe(cacheUsageProvider)),
        ),
      ),
    );
    _expectFailureVisible();
  });

  testWidgets('阳性对照：不写 retry 的 provider 在窗口内仍停在 loading', (tester) async {
    await _pumpIntoRetryWindow(
      tester,
      ProviderScope(
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: _AsyncProbe(_defaultRetryProvider)),
        ),
      ),
    );
    // 这条**故意断言"缺陷行为"**：它证明上面的 `findsNothing`/`findsOneWidget`
    // 不是空断言 —— 一旦去掉真实的 `retry: noRetry`，同一套断言就会红。
    expect(find.text('loading'), findsOneWidget);
    expect(find.text('retry'), findsNothing);
  });
}
