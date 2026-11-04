// 「思考内容」：解析层（三种协议的思考块 / usage）+ 界面层（折叠展示）。
//
// 离线：客户端走 `FakeCloudTransport`（Dio adapter 喂字节），页面走假引擎，
// **不碰网络**。
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/ai/cloud_llm_client.dart';
import 'package:synhub/src/data/ai/cloud_provider.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/ai_assistant_sheet.dart';
import 'package:synhub/src/features/ai/ai_providers.dart';
import 'package:synhub/src/features/ai/ai_service.dart';
import 'package:synhub/src/features/ai/on_device_ai.dart';
import 'package:synhub/src/features/ai/text_ai.dart';
import 'package:synhub/src/features/ai/cloud_engine.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;

import 'support/cloud_fake.dart';

CloudLlmConfig _cfg({
  CloudProtocol protocol = CloudProtocol.openai,
  String baseUrl = 'https://api.example.com/v1',
}) => CloudLlmConfig(
  protocol: protocol,
  baseUrl: baseUrl,
  apiKey: 'k-test',
  model: 'm-1',
);

Future<(List<String>, CloudStreamCollector)> _drain(
  FakeCloudTransport t, {
  CloudProtocol protocol = CloudProtocol.openai,
}) async {
  final collect = CloudStreamCollector();
  final out = await CloudLlmClient(dio: t.dio())
      .stream(
        cfg: _cfg(protocol: protocol),
        system: 's',
        user: 'u',
        collect: collect,
      )
      .toList();
  return (out, collect);
}

/// 假引擎：按给定内容产出，并可选地"只出思考"
class _ThinkingClient extends CloudLlmClient {
  _ThinkingClient({this.thinking = ''});

  final String thinking;

  @override
  Stream<String> stream({
    required CloudLlmConfig cfg,
    required String system,
    required String user,
    CancelToken? cancel,
    CloudStreamCollector? collect,
  }) async* {
    if (thinking.isNotEmpty) collect?.addThinking(thinking);
    yield '云端答案';
  }
}

Future<ProviderContainer> _pumpSheet(
  WidgetTester tester,
  CloudLlmEngine engine, {
  // 默认锁中文：测试宿主的平台语言是 en，不锁的话 delegate 会解析成英文
  Locale locale = const Locale('zh'),
}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      aiServiceProvider.overrideWithValue(AiService(engine)),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: locale,
        localizationsDelegates: AppText.localizationsDelegates,
        supportedLocales: AppText.supportedLocales,
        home: Scaffold(
          body: AiAssistantSheet(
            title: '《测试书》 · 第 1 章',
            build: (kind, question) => AiRequest(
              kind: kind,
              text: '端侧模型跑在手机上。原文不需要离开设备。',
              title: '测试书',
              question: question,
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  return c;
}

void main() {
  group('思考块解析（三种协议，离线假传输）', () {
    test('OpenAI 兼容：reasoning_content 进思考、正文只有 content', () async {
      final t = FakeCloudTransport(
        sse: [
          '{"choices":[{"delta":{"reasoning_content":"我先"}}]}',
          '{"choices":[{"delta":{"reasoning_content":"想一下"}}]}',
          '{"choices":[{"delta":{"content":"答案"}}]}',
          '{"choices":[{"delta":{},"finish_reason":"stop"}]}',
        ],
      );
      final (out, collect) = await _drain(t);
      expect(out.join(), '答案');
      expect(collect.thinking, '我先想一下');
      expect(collect.sawReasoning, isTrue);
    });

    test('OpenAI 兼容：中转用的 reasoning 字段也认', () async {
      final t = FakeCloudTransport(
        sse: [
          '{"choices":[{"delta":{"reasoning":"推理中"}}]}',
          '{"choices":[{"delta":{"content":"正文"}}]}',
        ],
      );
      final (out, collect) = await _drain(t);
      expect(out.join(), '正文');
      expect(collect.thinking, '推理中');
    });

    test('Claude：thinking_delta 进思考，text_delta 进正文；signature 不当思考', () async {
      final t = FakeCloudTransport(
        sse: [
          '{"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":0}}}',
          '{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"先看原文"}}',
          '{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"abc"}}',
          '{"type":"content_block_delta","delta":{"type":"text_delta","text":"答案是 A"}}',
          '{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}',
        ],
      );
      final (out, collect) = await _drain(t, protocol: CloudProtocol.anthropic);
      expect(out.join(), '答案是 A');
      expect(collect.thinking, '先看原文');
      expect(collect.finishReason, 'end_turn');
      expect(collect.usage.promptTokens, 12);
      expect(collect.usage.completionTokens, 7);
    });

    test('Gemini：thought:true 的 part 不当正文，但进思考区', () async {
      final t = FakeCloudTransport(
        sse: [
          '{"candidates":[{"content":{"parts":[{"text":"内心独白","thought":true}]}}]}',
          '{"candidates":[{"content":{"parts":[{"text":"正式回答"}]}}]}',
          '{"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":9,"thoughtsTokenCount":3,"totalTokenCount":14}}',
        ],
      );
      final (out, collect) = await _drain(t, protocol: CloudProtocol.gemini);
      expect(out.join(), '正式回答');
      expect(out.join(), isNot(contains('内心独白')));
      expect(collect.thinking, '内心独白');
      expect(collect.usage.totalTokens, 14);
      expect(collect.usage.reasoningTokens, 3);
    });

    test('没有思考块时：思考区为空（界面据此不显示折叠区）', () async {
      final t = FakeCloudTransport(
        sse: ['{"choices":[{"delta":{"content":"就是普通回答"}}]}'],
      );
      final (out, collect) = await _drain(t);
      expect(out.join(), '就是普通回答');
      expect(collect.thinking, isEmpty);
      expect(collect.sawReasoning, isFalse);
    });

    test('只有思考没有正文：抛 CloudReasoningOnlyException，且思考已收下', () async {
      final t = FakeCloudTransport(
        sse: [
          '{"choices":[{"delta":{"reasoning_content":"想了很多"}}]}',
          '{"choices":[{"delta":{},"finish_reason":"length"}]}',
        ],
      );
      final collect = CloudStreamCollector();
      Object? err;
      await CloudLlmClient(dio: t.dio())
          .stream(cfg: _cfg(), system: 's', user: 'u', collect: collect)
          .drain<void>()
          .catchError((Object e) {
            err = e;
          });
      expect(err, isA<CloudReasoningOnlyException>());
      expect((err! as CloudReasoningOnlyException).truncatedByBudget, isTrue);
      expect(collect.thinking, '想了很多');
    });

    test('OpenAI usage 在最后一帧：collector 收得到', () async {
      final t = FakeCloudTransport(
        sse: [
          '{"choices":[{"delta":{"content":"hi"}}]}',
          '{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":4,"total_tokens":15,"completion_tokens_details":{"reasoning_tokens":2}}}',
        ],
      );
      final (_, collect) = await _drain(t);
      expect(collect.sawUsage, isTrue);
      expect(collect.usage.promptTokens, 11);
      expect(collect.usage.completionTokens, 4);
      expect(collect.usage.reasoningTokens, 2);
    });

    test('Gemini 式的**累计快照** usage 不会被加两遍', () async {
      final t = FakeCloudTransport(
        sse: [
          '{"candidates":[{"content":{"parts":[{"text":"a"}]}}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2,"totalTokenCount":7}}',
          '{"candidates":[{"content":{"parts":[{"text":"b"}]}}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":9,"totalTokenCount":14}}',
        ],
      );
      final (_, collect) = await _drain(t, protocol: CloudProtocol.gemini);
      expect(collect.usage.promptTokens, 5);
      expect(collect.usage.completionTokens, 9);
      expect(collect.usage.totalTokens, 14);
    });

    test('第一个候选 body 带 stream_options.include_usage；网关不认时自动换一个不带的重试', () async {
      final t = FakeCloudTransport(
        status: 400,
        errorBodies: [
          // 第一次：网关不认 stream_options → 触发"换 body 重试"
          '{"error":{"message":"Unknown field: stream_options is not supported"}}',
          // 第二次：普通 400（不再是参数问题）→ 不再重试
          '{"error":{"message":"still bad"}}',
        ],
      );
      final collect = CloudStreamCollector();
      final client = CloudLlmClient(dio: t.dio());
      // 第一次 400（参数类）→ 换 body；第二次仍是我们自己造的状态码，
      // 这里只验"确实重试了、且第二次的 body 里没有 stream_options"
      Object? err;
      await client
          .stream(cfg: _cfg(), system: 's', user: 'u', collect: collect)
          .drain<void>()
          .catchError((Object e) {
            err = e;
          });
      expect(err, isA<CloudLlmException>());
      expect(t.calls, 2);
      expect(t.bodies.first['stream_options'], {'include_usage': true});
      expect(t.bodies[1].containsKey('stream_options'), isFalse);
    });

    test('非流式 complete()：思考与 usage 一并带回来', () async {
      final t = FakeCloudTransport(
        nonStream: {
          'choices': [
            {
              'message': {'content': '连接成功', 'reasoning_content': '先判断这是测试'},
            },
          ],
          'usage': {
            'prompt_tokens': 3,
            'completion_tokens': 6,
            'total_tokens': 9,
          },
        },
      );
      final res = await CloudLlmClient(dio: t.dio()).complete(cfg: _cfg());
      expect(res.text, '连接成功');
      expect(res.thinking, '先判断这是测试');
      expect(res.tokens.totalTokens, 9);
      expect(res.usage, contains('prompt_tokens'));
    });

    test('非流式（网关无视 stream:true）也认思考块', () async {
      final t = FakeCloudTransport(
        nonStream: {
          'choices': [
            {
              'message': {'content': '正文', 'reasoning_content': '非流式里的思考'},
            },
          ],
        },
      );
      final collect = CloudStreamCollector();
      final out = await CloudLlmClient(
        dio: t.dio(),
      ).stream(cfg: _cfg(), system: 's', user: 'u', collect: collect).toList();
      expect(out.join(), '正文');
      expect(collect.thinking, '非流式里的思考');
    });

    test('端侧 ` thinking` 段：正文剥掉、思考正文摘得出来', () {
      expect(extractThinkingText(' thinking先算一下</think>答案是 42'), '先算一下');
      expect(extractThinkingText('没有思考标记'), isEmpty);
      // 多段思考拼起来
      expect(
        extractThinkingText(' thinkingA</think>正文 thinkingB</think>'),
        'AB',
      );
    });
  });

  group('思考内容折叠区（界面）', () {
    testWidgets('有思考：默认折叠不露出内容，点开后可见、可复制', (tester) async {
      final engine = CloudLlmEngine(
        configOf: _cfg,
        client: _ThinkingClient(thinking: '我先看原文，再总结要点。'),
      );
      await _pumpSheet(tester, engine);
      expect(find.text('展开思考过程'), findsOneWidget);
      expect(find.textContaining('我先看原文'), findsNothing);
      await tester.tap(find.text('展开思考过程'));
      await tester.pumpAndSettle();
      expect(find.textContaining('我先看原文'), findsOneWidget);
      expect(find.text('复制思考内容'), findsOneWidget);
      expect(find.text('收起思考过程'), findsOneWidget);
    });

    testWidgets('没有思考块：不显示折叠区（不凭空造一个空盒子）', (tester) async {
      final engine = CloudLlmEngine(configOf: _cfg, client: _ThinkingClient());
      await _pumpSheet(tester, engine);
      expect(find.textContaining('云端答案'), findsWidgets);
      expect(find.text('展开思考过程'), findsNothing);
    });

    testWidgets('中英切换：折叠区标题跟着走（批次 2d）', (tester) async {
      setCurrentText(AppTextEn());
      addTearDown(() => setCurrentText(AppTextZh()));
      final engine = CloudLlmEngine(
        configOf: _cfg,
        client: _ThinkingClient(thinking: 'reasoning here'),
      );
      await _pumpSheet(tester, engine, locale: const Locale('en'));
      expect(find.text('Show reasoning'), findsOneWidget);
      expect(find.text('展开思考过程'), findsNothing);
    });
  });
}
