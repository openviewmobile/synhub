// 端侧 AI 的界面测试：模型管理页 + 助手弹层。
//
// 全部走**兜底引擎**（`ExtractiveLlmEngine`）——测试宿主上 `Platform.isAndroid`
// 为假，`AiAutoEngine` 不会去碰原生推理库，所以这些用例在 CI 里也能稳定跑。
// 真机上的模型路径见 `docs/on-device-ai-integration.md`。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/ai_assistant_sheet.dart';
import 'package:synhub/src/features/ai/ai_model_page.dart';
import 'package:synhub/src/features/ai/ai_providers.dart';
import 'package:synhub/src/data/ai/cloud_llm_client.dart';
import 'package:synhub/src/data/ai/cloud_provider.dart';
import 'package:synhub/src/features/ai/cloud_engine.dart';
import 'package:synhub/src/features/ai/ai_service.dart';
import 'package:synhub/src/features/ai/cloud_settings.dart';
import 'package:synhub/src/features/ai/text_ai.dart';
import 'package:synhub/src/features/ai/on_device_ai.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;

Future<ProviderContainer> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [chatDatabaseProvider.overrideWithValue(db)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

/// 把档位切到端侧（新页面默认是"云端大模型"，端侧目录只在端侧档显示）。
///
/// ⚠️ 必须走 `tester.runAsync`：`select()` 会写 Drift，而 `testWidgets` 的
/// fake async 里等真实 I/O 的 Future 会**永远挂住**（这里踩过）。
Future<void> _useOnDevice(WidgetTester tester, ProviderContainer c) async {
  await tester.runAsync(
    () => c.read(aiTierProvider.notifier).select(AiTier.onDevice),
  );
  await tester.pump(const Duration(milliseconds: 200));
}

const _text =
    '端侧模型跑在手机上。原文不需要离开设备，隐私收益是确定的。'
    '量化能把 0.6B 的模型压到 600MB 以内，代价是准确率略降。';

/// 云端假客户端：可以"卡住"（测生成中的文案），也可以按预算决定要不要先只出思考
class _SlowCloudClient extends CloudLlmClient {
  bool pending = false;
  final _chunks = <String>[];
  Completer<void>? _gate;

  CloudLlmConfig? lastCfg;

  void finish() => _gate?.complete();

  @override
  Stream<String> stream({
    required CloudLlmConfig cfg,
    required String system,
    required String user,
    CancelToken? cancel,
    CloudStreamCollector? collect,
  }) async* {
    lastCfg = cfg;
    if (pending) {
      _gate = Completer<void>();
      await _gate!.future;
    }
    for (final c in _chunks) {
      yield c;
    }
    yield '云端答案';
  }
}

/// 预算小于 4096 就先抛"只出思考"（复现 deepseek-v4.1-flash 的真机行为）
class _BudgetHungryClient extends CloudLlmClient {
  @override
  Stream<String> stream({
    required CloudLlmConfig cfg,
    required String system,
    required String user,
    CancelToken? cancel,
    CloudStreamCollector? collect,
  }) async* {
    if (cfg.maxTokens < 4096) {
      throw CloudReasoningOnlyException(
        reasoningChars: 1704,
        finishReason: 'length',
        budget: cfg.maxTokens,
      );
    }
    yield '云端答案';
  }
}

void main() {
  group('端侧 AI 模型页', () {
    testWidgets('三档切换；端侧档铺出模型、体积、推荐标记与隐私说明', (tester) async {
      final c = await _pump(tester, const AiModelPage());
      expect(find.text('AI 服务'), findsOneWidget);
      expect(find.text('云端大模型'), findsOneWidget);
      expect(find.text('端侧模型'), findsOneWidget);
      // 默认云端档：端侧目录不显示，避免堆一堆用不上的东西
      expect(find.text('LFM2.5 230M（int4）'), findsNothing);

      await _useOnDevice(tester, c);
      expect(find.text('端侧 AI 模型'), findsNothing);
      expect(find.text('启用 AI 助手'), findsOneWidget);
      expect(find.text('只在 WiFi 下载模型'), findsOneWidget);
      expect(find.text('LFM2.5 230M（int4）'), findsOneWidget);
      expect(find.text('Qwen3 0.6B'), findsOneWidget);
      expect(find.text('推荐'), findsOneWidget);
      expect(find.textContaining('MB'), findsWidgets);
      expect(find.text('原文不出手机'), findsOneWidget);
    });

    testWidgets('非移动平台 + 端侧档：老实说用内置摘要，不假装有模型', (tester) async {
      final c = await _pump(tester, const AiModelPage());
      await _useOnDevice(tester, c);
      // 测试宿主是桌面平台 → 状态卡直接说明
      expect(find.textContaining('不支持'), findsWidgets);
      expect(find.textContaining('这台设备用「内置摘要」'), findsOneWidget);
    });

    testWidgets('云端档：没配好时给出下一步，且不假装能用', (tester) async {
      final c = await _pump(tester, const AiModelPage());
      expect(find.textContaining('还没配好云端'), findsOneWidget);
      expect(find.text('选择厂商'), findsOneWidget);
      expect(find.text('测试连接'), findsOneWidget);
      // 选一家厂商：预设地址自动带出来
      await tester.runAsync(
        () => c.read(cloudSettingsProvider.notifier).selectProvider('deepseek'),
      );
      await tester.pump(const Duration(milliseconds: 200));
      // 厂商名现在会出现两处：顶部「配置方案」一览 + 厂商卡片
      // （多套配置并存后，"当前用的是哪一套"要一眼可见）
      expect(find.text('DeepSeek 深度求索'), findsWidgets);
      expect(find.text('切换'), findsOneWidget);
      expect(find.textContaining('api.deepseek.com'), findsWidgets);
    });

    testWidgets('开关会落库（冷启动能恢复）', (tester) async {
      final c = await _pump(tester, const AiModelPage());
      await _useOnDevice(tester, c);
      expect(c.read(aiEnabledProvider), isTrue);
      await tester.tap(find.text('启用 AI 助手'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.read(aiEnabledProvider), isFalse);
      final db = c.read(chatDatabaseProvider);
      expect(await ChatStore(db).setting('ai_enabled'), 'false');

      await tester.tap(find.text('只在 WiFi 下载模型'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.read(aiWifiOnlyProvider), isFalse);
      expect(await ChatStore(db).setting('ai_wifi_only'), 'false');
    });

    testWidgets('试用：贴一段文字 → 出要点，并如实标注是"内置摘要"', (tester) async {
      final c = await _pump(tester, const AiModelPage());
      await tester.runAsync(
        () => c.read(aiTierProvider.notifier).select(AiTier.extractive),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField).first, _text);
      await tester.tap(find.text('试一句'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(find.textContaining('内置摘要（无模型）'), findsWidgets);
      expect(find.textContaining('- '), findsWidgets);
    });
  });

  group('AI 助手弹层', () {
    Future<void> pumpSheet(WidgetTester tester, ProviderContainer c) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: AiAssistantSheet(
                title: '《测试书》 · 第 1 章',
                build: (kind, question) {
                  // 真实调用方（阅读器/笔记）在问书时会先做一次检索
                  if (kind == AiTaskKind.askBook) {
                    return withRetrieval(
                      AiRequest(
                        kind: kind,
                        text: _text,
                        title: '测试书',
                        question: question,
                      ),
                      passagesOfBook('测试书', const ['第 1 章'], [_text]),
                    );
                  }
                  return AiRequest(
                    kind: kind,
                    text: _text,
                    title: '测试书',
                    question: question,
                  );
                },
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
    }

    testWidgets('云端档生成中/出错时不能写成"端侧模型"（真机误导过）', (tester) async {
      final client = _SlowCloudClient();
      final engine = CloudLlmEngine(
        configOf: () => const CloudLlmConfig(
          protocol: CloudProtocol.openai,
          baseUrl: 'https://example.com/v1',
          apiKey: 'k',
          model: 'deepseek-v4.1-flash',
        ),
        client: client,
      );
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          aiServiceProvider.overrideWithValue(AiService(engine)),
        ],
      );
      addTearDown(c.dispose);
      // 先让流慢下来，抓"生成中"的那一帧
      client.pending = true;
      await pumpSheet(tester, c);
      expect(find.textContaining('云端模型正在生成…'), findsOneWidget);
      expect(find.textContaining('端侧模型正在生成'), findsNothing);

      // 放行 → 出答案 + 自动加大预算的说明
      client.pending = false;
      client.finish();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(find.textContaining('云端答案'), findsWidgets);
    });

    testWidgets('自动加大预算重试过就要如实标出来（不偷偷多花钱）', (tester) async {
      final engine = CloudLlmEngine(
        configOf: () => const CloudLlmConfig(
          protocol: CloudProtocol.openai,
          baseUrl: 'https://example.com/v1',
          apiKey: 'k',
          model: 'deepseek-v4.1-flash',
          maxTokens: 1024,
        ),
        client: _BudgetHungryClient(),
      );
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          aiServiceProvider.overrideWithValue(AiService(engine)),
        ],
      );
      addTearDown(c.dispose);
      await pumpSheet(tester, c);
      expect(find.textContaining('已自动加大到 4096 重试'), findsOneWidget);
      expect(find.textContaining('云端答案'), findsWidgets);
    });

    testWidgets('打开就自动总结，并显示引擎档位与"装端侧模型"入口', (tester) async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(c.dispose);
      await pumpSheet(tester, c);

      expect(find.textContaining('AI 助手 · 总结'), findsOneWidget);
      expect(find.text('《测试书》 · 第 1 章'), findsOneWidget);
      expect(find.text('内置摘要（无模型）'), findsOneWidget);
      expect(find.textContaining('端侧模型跑在手机上'), findsWidgets);
      expect(find.text('装端侧模型'), findsOneWidget);
      // 出完了应该有"复制"
      expect(find.text('复制'), findsOneWidget);
    });

    testWidgets('问这本书：输入问题 → 出答案并列出依据的原文', (tester) async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(c.dispose);
      await pumpSheet(tester, c);

      await tester.tap(find.text('问这本书'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField).first, '隐私收益是什么');
      await tester.tap(find.text('提问'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(find.text('依据的原文'), findsOneWidget);
      expect(find.textContaining('隐私'), findsWidgets);
    });

    testWidgets('关掉总开关不影响弹层本身（引擎仍可用兜底）', (tester) async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(c.dispose);
      await c.read(aiEnabledProvider.notifier).set(false);
      await pumpSheet(tester, c);
      expect(find.textContaining('AI 助手'), findsOneWidget);
      expect(find.textContaining('端侧模型跑在手机上'), findsWidgets);
    });
  });

  group('云端多套配置（界面）', () {
    testWidgets('一览显示当前配置；弹层里能一键切到另一套', (tester) async {
      final c = await _pump(tester, const AiModelPage());
      await tester.runAsync(() async {
        final n = c.read(cloudSettingsProvider.notifier);
        await n.selectProvider('openai');
        await n.setModel('gpt-4o-mini');
        // 另存为第二套，并把第二套的模型改掉（这样切换前后模型不同）
        await n.saveProfileAsNew('公司中转');
        await n.setModel('gpt-4o');
      });
      await tester.pump(const Duration(milliseconds: 200));

      // 一览：当前这套的名字 + "切换" + 套数
      expect(find.text('公司中转'), findsOneWidget);
      expect(find.text('切换'), findsOneWidget);
      expect(find.textContaining('共 2 套'), findsWidgets);

      await tester.tap(find.text('切换'));
      await tester.pumpAndSettle();
      expect(find.text('配置方案'), findsOneWidget);
      expect(find.textContaining('key 仍只放在系统安全存储里'), findsOneWidget);
      // 两套都列出来：默认那套回落成厂商名「OpenAI」
      expect(find.text('OpenAI'), findsWidgets);

      // 点未选中的那行（圆点是空心的）→ 切过去，模型跟着换
      // 切换会读安全存储 + 偏好表：fake async 里等不到这些 Future，
      // 必须在 runAsync 里让真实 I/O 跑完（同 `_useOnDevice` 的理由）
      final row = find.ancestor(
        of: find.byIcon(Icons.radio_button_unchecked),
        matching: find.byType(DesignRowTile),
      );
      await tester.runAsync(() async {
        await tester.tap(row);
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(cloudSettingsProvider).model, 'gpt-4o-mini');
      expect(find.text('公司中转'), findsNothing);
    });

    testWidgets('另存为新配置：填名字 → 落库 → 一览变成新的那套', (tester) async {
      final c = await _pump(tester, const AiModelPage());
      await tester.runAsync(
        () => c.read(cloudSettingsProvider.notifier).selectProvider('deepseek'),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('切换'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('存为新配置'));
      await tester.pumpAndSettle();
      expect(find.text('例如：公司中转 / 家里的 Ollama'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '备用中转',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(c.read(cloudSettingsProvider).profiles, hasLength(2));
      expect(find.text('备用中转'), findsWidgets);

      // 删除只剩一套时会被拒绝：这里正好验证"守卫还在"
      final n = c.read(cloudSettingsProvider.notifier);
      final first = c.read(cloudSettingsProvider).profiles.first.id;
      await tester.runAsync(() => n.deleteProfile(first));
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.read(cloudSettingsProvider).profiles, hasLength(1));
    });
  });
}
