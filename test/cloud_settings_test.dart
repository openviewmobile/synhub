// 云端设置层 + 引擎装配测试：
//   * 厂商切换 / base URL / 模型 / 参数的落库与读回
//   * **key 只进安全存储**（用内存替身验证），切厂商互不串台
//   * 拉模型列表的三种结局（成功 / 失败 / 这家根本没有接口）
//   * 测试连接的成功与失败文案
//   * `CloudLlmEngine` 的 status / 未配置时的报错 / 取消
//   * 与 `AiService` 串起来：走云端时 `AiAnswer.engine == cloud`
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/data/ai/cloud_llm_client.dart';
import 'package:synhub/src/data/ai/cloud_provider.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/ai_providers.dart';
import 'package:synhub/src/features/ai/ai_service.dart';
import 'package:synhub/src/features/ai/cloud_engine.dart';
import 'package:synhub/src/features/ai/cloud_settings.dart';
import 'package:synhub/src/features/ai/llm_engine.dart';
import 'package:synhub/src/features/ai/on_device_ai.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider, chatStoreProvider;

/// 极简 OpenAI 兼容服务器：/models + /chat/completions（流式/非流式）
class _Server {
  late final HttpServer _server;
  int calls = 0;
  int lastStatus = 200;

  /// 每次请求的 body（按顺序），用来断言真正发出去的长度/参数
  final bodies = <Map<String, dynamic>>[];

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      calls++;
      final raw = await utf8.decoder.bind(req).join();
      if (req.uri.path.endsWith('/models')) {
        if (lastStatus != 200) {
          req.response.statusCode = lastStatus;
          req.response.write(
            jsonEncode({
              'error': {'message': 'nope'},
            }),
          );
          await req.response.close();
          return;
        }
        req.response.write(
          jsonEncode({
            'data': [
              {'id': 'm-small'},
              {'id': 'm-large'},
            ],
          }),
        );
        await req.response.close();
        return;
      }
      final body = raw.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', v));
      if (!req.uri.path.endsWith('/models')) bodies.add(body);
      if (body['stream'] == true) {
        req.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        req.response.bufferOutput = false;
        for (final piece in ['云端', '回答']) {
          req.response.write(
            'data: {"choices":[{"delta":{"content":"$piece"}}]}\n\n',
          );
          await req.response.flush();
        }
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
        return;
      }
      req.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '连接成功'},
            },
          ],
        }),
      );
      await req.response.close();
    });
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  Future<void> stop() => _server.close(force: true);
}

/// 假的云端客户端：小于 [limit] 的预算就抛"只出思考"（复现真机那个模型的行为）
class _ReasoningOnlyClient extends CloudLlmClient {
  _ReasoningOnlyClient({
    this.alwaysFail = false,
    this.finishReason = 'length',
    this.firstDelay = Duration.zero,
  });

  final bool alwaysFail;
  final String finishReason;

  /// 第一次调用先等一会儿（用来测"用户中途点了停止"）
  final Duration firstDelay;
  int calls = 0;
  final List<int> seenBudgets = [];

  @override
  Stream<String> stream({
    required CloudLlmConfig cfg,
    required String system,
    required String user,
    CancelToken? cancel,
    CloudStreamCollector? collect,
  }) async* {
    calls++;
    seenBudgets.add(cfg.maxTokens);
    if (calls == 1 && firstDelay > Duration.zero) {
      await Future<void>.delayed(firstDelay);
      // 真实 HTTP 被掐断后就是这样：什么都不发、也不报错
      if (cancel?.isCancelled == true) return;
    }
    if (alwaysFail || cfg.maxTokens < 4096) {
      throw CloudReasoningOnlyException(
        reasoningChars: 1704,
        finishReason: finishReason,
        budget: cfg.maxTokens,
      );
    }
    yield '答案';
  }
}

/// 只用来数"有没有发请求"的适配器（断言"这家没有列表接口就别发请求"）
Dio _countingDio(void Function() onCall) {
  final dio = Dio(BaseOptions(validateStatus: (_) => true));
  dio.httpClientAdapter = _CountingAdapter(onCall);
  return dio;
}

class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.onCall);

  final void Function() onCall;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onCall();
    return ResponseBody.fromString(
      '{"data":[]}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ProviderContainer _container(ChatDatabase db, {CloudKeyStore? keys}) {
  final container = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      cloudKeyStoreProvider.overrideWithValue(keys ?? MemoryCloudKeyStore()),
    ],
  );
  return container;
}

void main() {
  setUpAll(() => HttpOverrides.global = null);

  group('CloudSettingsNotifier（云端配置）', () {
    test('默认：没选厂商、不可用、协议 openai、参数有默认值', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);

      final s = c.read(cloudSettingsProvider);
      expect(s.providerId, isEmpty);
      expect(s.configured, isFalse);
      expect(s.protocol, CloudProtocol.openai);
      expect(s.temperature, 0.6);
      expect(s.maxTokens, 1024);
    });

    test('选厂商带出预设地址与协议，并落库', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);

      await n.selectProvider('anthropic');
      var s = c.read(cloudSettingsProvider);
      expect(s.baseUrl, 'https://api.anthropic.com/v1');
      expect(s.protocol, CloudProtocol.anthropic);
      expect(s.provider.name, 'Anthropic Claude');

      final settings = SettingsService(c.read(chatStoreProvider));
      expect(await settings.aiCloudProviderId(), 'anthropic');
      expect(await settings.aiCloudBaseUrl(), 'https://api.anthropic.com/v1');
      expect(await settings.aiCloudProtocol(), 'anthropic');

      // 换一家：地址与协议跟着换，模型清空（免得把 A 家模型发给 B 家）
      await n.setModel('claude-x');
      await n.selectProvider('deepseek');
      s = c.read(cloudSettingsProvider);
      expect(s.baseUrl, 'https://api.deepseek.com/v1');
      expect(s.protocol, CloudProtocol.openai);
      expect(s.model, isEmpty);
    });

    test('自定义厂商：协议可选，地址留空等用户填', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);

      await n.selectProvider(kCustomProviderId, customProtocol: 'gemini');
      final s = c.read(cloudSettingsProvider);
      expect(s.provider.isCustom, isTrue);
      expect(s.baseUrl, isEmpty);
      expect(s.protocol, CloudProtocol.gemini);
      await n.setBaseUrl('https://my-gateway.example.com/v1');
      await n.setModel('my-model');
      expect(c.read(cloudSettingsProvider).configured, isTrue);
    });

    test('key 只进安全存储：切厂商互不串台、删除后读回为空', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MemoryCloudKeyStore();
      final c = _container(db, keys: store);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);

      await n.selectProvider('openai');
      await n.setKey('sk-openai-1');
      await n.selectProvider('deepseek');
      await n.setKey('sk-deepseek-1');

      expect(await store.read('openai'), 'sk-openai-1');
      expect(await store.read('deepseek'), 'sk-deepseek-1');

      await n.selectProvider('openai');
      expect(c.read(cloudSettingsProvider).apiKey, 'sk-openai-1');

      await n.setKey('');
      expect(await store.read('openai'), isNull);
      // 普通偏好表里**不该**出现 key
      final raw = await SettingsService(
        c.read(chatStoreProvider),
      ).aiCloudModelCache();
      expect(raw ?? '', isNot(contains('sk-')));
    });

    test('参数落库', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);

      await n.setTemperature(1.2);
      await n.setMaxTokens(2048);
      final settings = SettingsService(c.read(chatStoreProvider));
      expect(await settings.aiCloudTemperature(), 1.2);
      expect(await settings.aiCloudMaxTokens(), 2048);
    });

    test('preload 把上次的配置与 key 读回来', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MemoryCloudKeyStore();
      final c1 = _container(db, keys: store);
      final n1 = c1.read(cloudSettingsProvider.notifier);
      await n1.selectProvider('siliconflow');
      await n1.setModel('Qwen/Qwen3-8B');
      await n1.setKey('sk-sf');
      await n1.setTemperature(0.3);
      c1.dispose();

      final c2 = _container(db, keys: store);
      addTearDown(c2.dispose);
      await c2.read(cloudSettingsProvider.notifier).preload();
      final s = c2.read(cloudSettingsProvider);
      expect(s.providerId, 'siliconflow');
      expect(s.model, 'Qwen/Qwen3-8B');
      expect(s.apiKey, 'sk-sf');
      expect(s.temperature, 0.3);
      expect(s.configured, isTrue);
    });

    test('没有列表接口的厂商：不发请求，直接给出解释', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      var httpCalls = 0;
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          cloudKeyStoreProvider.overrideWithValue(MemoryCloudKeyStore()),
          cloudLlmClientProvider.overrideWithValue(
            CloudLlmClient(dio: _countingDio(() => httpCalls++)),
          ),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('zhipu');
      await n.refreshModels();
      expect(httpCalls, 0);
      expect(c.read(cloudSettingsProvider).error, contains('没有模型列表接口'));
      expect(c.read(cloudSettingsProvider).cachedModels, isEmpty);
    });

    test('拉模型列表成功 → 入 state 并缓存到本地', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);

      await n.selectProvider(kCustomProviderId);
      await n.setBaseUrl(server.baseUrl);
      await n.setKey('k');
      await n.refreshModels();

      final s = c.read(cloudSettingsProvider);
      expect(s.error, isEmpty);
      expect(s.cachedModels.map((m) => m.id), ['m-large', 'm-small']);
      final cached = await SettingsService(
        c.read(chatStoreProvider),
      ).aiCloudModelCache();
      expect(cached, contains('m-large'));
      expect(cached, contains(kCustomProviderId));
    });

    test('拉列表失败（401）→ 把原因写进 error', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final server = _Server()..lastStatus = 401;
      await server.start();
      addTearDown(server.stop);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider(kCustomProviderId);
      await n.setBaseUrl(server.baseUrl);
      await n.refreshModels();
      expect(c.read(cloudSettingsProvider).error, contains('401'));
    });

    test('测试连接：成功与失败各说各的话', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);

      // 没填完：不发请求
      expect(await n.test(), isFalse);
      expect(c.read(cloudSettingsProvider).testResult, contains('还没填完'));

      await n.selectProvider(kCustomProviderId);
      await n.setBaseUrl(server.baseUrl);
      await n.setModel('m-1');
      expect(await n.test(), isTrue);
      expect(c.read(cloudSettingsProvider).testResult, contains('通了'));

      await n.setBaseUrl('http://127.0.0.1:1/v1');
      expect(await n.test(), isFalse);
      expect(c.read(cloudSettingsProvider).testResult, contains('连不上'));
    });
  });

  group('CloudLlmEngine', () {
    test('没配好：status 说不支持，generate 报明确错误', () async {
      final engine = CloudLlmEngine(configOf: () => null);
      final st = await engine.status();
      expect(st.readiness, AiReadiness.unsupported);
      expect(st.detail, contains('云端还没配好'));

      await expectLater(
        engine.generate(const LlmPrompt(system: 's', user: 'u')).toList(),
        throwsA(
          isA<CloudLlmException>().having(
            (e) => e.message,
            'message',
            contains('AI 服务'),
          ),
        ),
      );
    });

    test('配好了：status 给出模型与协议，流式逐段出来、可取消', () async {
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      final cfg = CloudLlmConfig(
        protocol: CloudProtocol.openai,
        baseUrl: server.baseUrl,
        apiKey: 'k',
        model: 'm-1',
      );
      final engine = CloudLlmEngine(configOf: () => cfg);
      final st = await engine.status();
      expect(st.readiness, AiReadiness.ready);
      expect(st.modelName, 'm-1');
      expect(st.backend, 'OpenAI 兼容');

      final chunks = await engine
          .generate(const LlmPrompt(system: 'sys', user: 'hi'))
          .toList();
      expect(chunks.join(), '云端回答');

      // 取消不该抛异常
      engine.cancel();
      await engine.dispose();
    });
  });

  group('推理模型自动加大预算（用户实测的 deepseek-v4.1-flash 场景）', () {
    test('被预算截断且正文为空 → 自动加大到 4096 重试一次并出正文', () async {
      final client = _ReasoningOnlyClient();
      final engine = CloudLlmEngine(
        configOf: () => CloudLlmConfig(
          protocol: CloudProtocol.openai,
          baseUrl: 'https://example.com/v1',
          apiKey: 'k',
          model: 'deepseek-v4.1-flash',
          maxTokens: 1024,
        ),
        client: client,
      );
      final out = await engine
          .generate(const LlmPrompt(system: 's', user: 'u'))
          .join();
      expect(out, '答案');
      expect(client.calls, 2);
      expect(client.seenBudgets, [1024, 4096]);
      expect(engine.retriedBudget, 4096);
    });

    test('加大到上限仍然只有思考 → 报错里要说清"已经自动试过"', () async {
      final client = _ReasoningOnlyClient(alwaysFail: true);
      final engine = CloudLlmEngine(
        configOf: () => CloudLlmConfig(
          protocol: CloudProtocol.openai,
          baseUrl: 'https://example.com/v1',
          apiKey: 'k',
          model: 'deepseek-v4.1-flash',
          maxTokens: 8192,
        ),
        client: client,
      );
      await expectLater(
        engine.generate(const LlmPrompt(system: 's', user: 'u')).toList(),
        throwsA(
          isA<CloudLlmException>().having(
            (e) => e.message,
            'message',
            allOf(contains('加大'), contains('仍然没写出正文')),
          ),
        ),
      );
      expect(client.seenBudgets, [8192, 16384]);
    });

    test('用户点过停止就不重试（不偷偷再花钱）', () async {
      final client = _ReasoningOnlyClient(
        firstDelay: const Duration(milliseconds: 200),
      );
      final engine = CloudLlmEngine(
        configOf: () => CloudLlmConfig(
          protocol: CloudProtocol.openai,
          baseUrl: 'https://example.com/v1',
          apiKey: 'k',
          model: 'm',
          maxTokens: 1024,
        ),
        client: client,
      );
      final sub = engine
          .generate(const LlmPrompt(system: 's', user: 'u'))
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      engine.cancel();
      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      // 只发了一次请求，而且没有"自动加大预算"的第二次
      expect(client.calls, 1);
      expect(engine.retriedBudget, 0);
    });

    test('不是被预算截断（模型就是不给正文）→ 不重试，直接如实报错', () async {
      final client = _ReasoningOnlyClient(finishReason: 'stop');
      final engine = CloudLlmEngine(
        configOf: () => CloudLlmConfig(
          protocol: CloudProtocol.openai,
          baseUrl: 'https://example.com/v1',
          apiKey: 'k',
          model: 'm',
          maxTokens: 1024,
        ),
        client: client,
      );
      await expectLater(
        engine.generate(const LlmPrompt(system: 's', user: 'u')).toList(),
        throwsA(isA<CloudLlmException>()),
      );
      expect(client.calls, 1);
    });
  });

  group('云端长度预算（推理模型踩过的坑）', () {
    test('prompt 的小预算不覆盖用户在设置里配的最大长度', () async {
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      final engine = CloudLlmEngine(
        configOf: () => CloudLlmConfig(
          protocol: CloudProtocol.openai,
          baseUrl: server.baseUrl,
          apiKey: 'k',
          model: 'ds4.1-flash',
          maxTokens: 4096,
        ),
      );
      // 阅读器/笔记默认只给 512（试用按钮 256）：云端必须按用户配置来，
      // 否则推理模型会把预算全用在思考上 → 正文一个字都没有
      await AiService(
        engine,
      ).run(const AiRequest(kind: AiTaskKind.summary, text: '原文', title: 't'));
      expect(server.bodies.last['max_tokens'], 4096);
      expect(server.bodies.last['model'], 'ds4.1-flash');
    });

    test('反过来：用户配得比 prompt 还小就按 prompt 的（别把回答卡死）', () async {
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      final engine = CloudLlmEngine(
        configOf: () => CloudLlmConfig(
          protocol: CloudProtocol.openai,
          baseUrl: server.baseUrl,
          apiKey: 'k',
          model: 'm',
          maxTokens: 64,
        ),
      );
      await AiService(engine).run(
        const AiRequest(
          kind: AiTaskKind.summary,
          text: '原文',
          title: 't',
          maxOutputTokens: 512,
        ),
      );
      expect(server.bodies.last['max_tokens'], 512);
    });
  });

  group('与 AiService 串起来', () {
    test('云端出答案：engine 标为 cloud、modelName 来自配置', () async {
      final server = _Server();
      await server.start();
      addTearDown(server.stop);
      final engine = CloudLlmEngine(
        configOf: () => CloudLlmConfig(
          protocol: CloudProtocol.openai,
          baseUrl: server.baseUrl,
          apiKey: 'k',
          model: 'm-1',
        ),
      );
      final answer = await AiService(engine).run(
        const AiRequest(kind: AiTaskKind.summary, text: '一段原文', title: '测试'),
      );
      expect(answer.engine, AiEngineKind.cloud);
      expect(answer.text, contains('云端回答'));
      expect(answer.modelName, 'm-1');
    });

    test('云端失败 → AiFailure（UI 显示人话，不红屏）', () async {
      final engine = CloudLlmEngine(configOf: () => null);
      await expectLater(
        AiService(
          engine,
        ).run(const AiRequest(kind: AiTaskKind.summary, text: 'x', title: 't')),
        throwsA(isA<AiFailure>()),
      );
    });
  });

  group('档位装配', () {
    test('默认云端档；未配置时降级；配好后切回云端；端侧档位始终有独立引擎', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);

      expect(c.read(aiTierProvider), AiTier.cloud);
      // 云端档但没配好 → **降级**（助手入口不能变成报错页）
      expect(c.read(aiEngineProvider), isA<AiAutoEngine>());

      // 配好 base URL + 模型后立刻切回云端引擎
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider(kCustomProviderId);
      await n.setBaseUrl('https://example.com/v1');
      await n.setModel('m-1');
      expect(c.read(aiEngineProvider), isA<CloudLlmEngine>());

      await c.read(aiTierProvider.notifier).select(AiTier.onDevice);
      expect(c.read(aiEngineProvider), isA<AiAutoEngine>());
      // 装/删模型走的是独立的端侧引擎，云端档下也要能拿到
      expect(c.read(onDeviceEngineProvider), isA<AiAutoEngine>());

      await c.read(aiTierProvider.notifier).select(AiTier.extractive);
      expect(c.read(aiEngineProvider), isA<ExtractiveLlmEngine>());

      await c.read(aiTierProvider.notifier).select(AiTier.cloud);
      expect(c.read(aiEngineProvider), isA<CloudLlmEngine>());
      // 档位落库
      expect(
        await SettingsService(c.read(chatStoreProvider)).aiTier(),
        'cloud',
      );
    });
  });
}
