// 云端大模型客户端测试：**起真的 HTTP 服务器**打三种协议。
//
// 为什么不用 mock adapter：SSE 分块、`[DONE]` 缺失、事件名驱动（Anthropic）、
// 查询串鉴权（Gemini）、非 JSON 错误页 —— 这些坑只有走真 socket 才会暴露。
// 本地回环服务器够快，也不依赖外网（CI 可跑）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/ai/cloud_llm_client.dart';
import 'package:synhub/src/data/ai/cloud_provider.dart';

/// 收到的请求摘要，供断言用
class _Captured {
  String path = '';
  String method = '';
  Map<String, String> headers = {};
  Map<String, dynamic> body = {};
}

class _FakeServer {
  _FakeServer(this._handler);

  final Future<void> Function(HttpRequest req, _Captured cap) _handler;
  late final HttpServer _server;
  final captured = _Captured();

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final cap = _Captured()
        ..path = req.uri.toString()
        ..method = req.method;
      req.headers.forEach((k, v) => cap.headers[k] = v.join(','));
      final raw = await utf8.decoder.bind(req).join();
      if (raw.isNotEmpty) {
        try {
          cap.body = (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', v));
        } catch (_) {}
      }
      captured.path = cap.path;
      captured.method = cap.method;
      captured.headers = cap.headers;
      captured.body = cap.body;
      await _handler(req, cap);
    });
  }

  Future<void> stop() => _server.close(force: true);

  /// 逐块写 SSE（带 flush，模拟真实流式）
  static Future<void> sse(HttpRequest req, List<String> chunks) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    req.response.bufferOutput = false;
    for (final c in chunks) {
      req.response.write(c);
      await req.response.flush();
    }
    await req.response.close();
  }

  static Future<void> json(
    HttpRequest req,
    Object body, {
    int status = 200,
  }) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  static Future<void> text(
    HttpRequest req,
    String body, {
    int status = 200,
  }) async {
    req.response.statusCode = status;
    req.response.write(body);
    await req.response.close();
  }
}

CloudLlmConfig _cfg({
  CloudProtocol protocol = CloudProtocol.openai,
  String baseUrl = '',
  String key = 'k-test',
  String model = 'm-1',
}) => CloudLlmConfig(
  protocol: protocol,
  baseUrl: baseUrl,
  apiKey: key,
  model: model,
);

void main() {
  // flutter_test 会把 `HttpOverrides.global` 换成"所有请求返回 400"的桩，
  // 这里必须还原成真实现，否则本地回环服务器也连不上。
  setUpAll(() => HttpOverrides.global = null);

  group('base URL 收拾', () {
    test('去尾斜杠 / 去掉用户粘进来的整条端点', () {
      expect(normalizeBaseUrl(' https://a.com/v1/ '), 'https://a.com/v1');
      expect(
        normalizeBaseUrl('https://a.com/v1/chat/completions'),
        'https://a.com/v1',
      );
      expect(normalizeBaseUrl('https://a.com/v1/messages'), 'https://a.com/v1');
      expect(normalizeBaseUrl('https://a.com/v1/models/'), 'https://a.com/v1');
      expect(normalizeBaseUrl('https://a.com'), 'https://a.com');
    });

    test('打码只留头尾', () {
      expect(maskKey(''), '');
      expect(maskKey('short12'), 's••••');
      expect(maskKey('sk-abcdefghijklmn'), 'sk-••••klmn');
    });
  });

  group('模型兼容性（推理模型 / 网关怪癖，真机上报过"不兼容"）', () {
    test('推理模型只回 reasoning_content：不能静默空手而归，要说清原因', () async {
      final server = _FakeServer((req, cap) async {
        // 典型推理模型流：一堆 reasoning，正文一个字都没有（token 被思考吃光）
        await _FakeServer.sse(req, [
          'data: {"choices":[{"delta":{"reasoning_content":"让我想想……"}}]}\n\n',
          'data: {"choices":[{"delta":{"reasoning_content":"再想想……"}}]}\n\n',
          'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n',
          'data: [DONE]\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);
      await expectLater(
        CloudLlmClient()
            .stream(
              cfg: _cfg(baseUrl: server.baseUrl, model: 'ds4.1-flash'),
              system: 's',
              user: 'u',
            )
            .toList(),
        throwsA(
          // 专用异常：**用户文案**只带用户能懂的诊断量（预算多少、思考多少字）；
          // ★ r343 D52：`finish_reason` 是**协议枚举**，不再印进文案 ——
          //   但它一个都没丢：仍在异常对象的字段上（下面三条断言分开钉）。
          isA<CloudReasoningOnlyException>()
              .having((e) => e.message, 'message', contains('token 全用在思考上'))
              .having((e) => e.message, 'message', contains('字思考内容'))
              .having((e) => e.message, 'message', isNot(contains('finish_reason')))
              .having((e) => e.finishReason, 'finishReason', 'length')
              .having((e) => e.truncatedByBudget, 'truncatedByBudget', isTrue),
        ),
      );
    });

    test('推理内容照旧过滤，正文正常出（reasoning_content 不进正文）', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.sse(req, [
          'data: {"choices":[{"delta":{"reasoning_content":"思考"}}]}\n\n',
          'data: {"choices":[{"delta":{"content":"答案"}}]}\n\n',
          'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n',
          'data: [DONE]\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);
      final out = await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl, model: 'ds4.1-flash'),
            system: 's',
            user: 'u',
          )
          .join();
      expect(out, '答案');
    });

    test('被长度上限截断：正文保留，并追加一句可操作的提示', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.sse(req, [
          'data: {"choices":[{"delta":{"content":"前半段"}}]}\n\n',
          'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);
      final out = await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl, model: 'ds4.1-flash'),
            system: 's',
            user: 'u',
          )
          .join();
      expect(out, contains('前半段'));
      expect(out, contains('长度上限'));
    });

    test('网关无视 stream:true 直接回整段 JSON：也要能拿到正文', () async {
      final server = _FakeServer((req, cap) async {
        expect(cap.body['stream'], true);
        await _FakeServer.json(req, {
          'choices': [
            {
              'message': {'role': 'assistant', 'content': '我是非流式回包'},
            },
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      final out = await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl, model: 'ds4.1-flash'),
            system: 's',
            user: 'u',
          )
          .join();
      expect(out, '我是非流式回包');
    });

    test('网关回 200 但空 body：明确报错，不要静默', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.text(req, '');
      });
      await server.start();
      addTearDown(server.stop);
      await expectLater(
        CloudLlmClient()
            .stream(
              cfg: _cfg(baseUrl: server.baseUrl, model: 'ds4.1-flash'),
              system: 's',
              user: 'u',
            )
            .toList(),
        throwsA(isA<CloudLlmException>()),
      );
    });

    test('不认 max_tokens 的网关：自动改用 max_completion_tokens 重试', () async {
      final bodies = <Map<String, dynamic>>[];
      final server = _FakeServer((req, cap) async {
        bodies.add(cap.body);
        if (cap.body.containsKey('max_tokens')) {
          await _FakeServer.json(req, {
            'error': {'message': 'Unsupported parameter: max_tokens'},
          }, status: 400);
          return;
        }
        await _FakeServer.sse(req, [
          'data: {"choices":[{"delta":{"content":"第二次成了"}}]}\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);
      final out = await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl, model: 'ds4.1-flash'),
            system: 's',
            user: 'u',
          )
          .join();
      expect(out, '第二次成了');
      expect(bodies, hasLength(2));
      expect(bodies[0].containsKey('max_tokens'), isTrue);
      expect(bodies[1].containsKey('max_completion_tokens'), isTrue);
    });

    test('连 temperature 都不认：第三次去掉 temperature 也能成', () async {
      var calls = 0;
      final server = _FakeServer((req, cap) async {
        calls++;
        if (cap.body.containsKey('temperature')) {
          await _FakeServer.json(req, {
            'error': {'message': 'temperature is not supported for this model'},
          }, status: 400);
          return;
        }
        await _FakeServer.sse(req, [
          'data: {"choices":[{"delta":{"content":"成了"}}]}\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);
      final out = await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl, model: 'ds4.1-flash'),
            system: 's',
            user: 'u',
          )
          .join();
      expect(out, '成了');
      expect(calls, 3);
    });

    test('401/404 这类错误不做无意义重试（一次就抛）', () async {
      var calls = 0;
      final server = _FakeServer((req, cap) async {
        calls++;
        await _FakeServer.json(req, {
          'error': {'message': 'Invalid API key'},
        }, status: 401);
      });
      await server.start();
      addTearDown(server.stop);
      await expectLater(
        CloudLlmClient()
            .stream(
              cfg: _cfg(baseUrl: server.baseUrl, model: 'ds4.1-flash'),
              system: 's',
              user: 'u',
            )
            .toList(),
        throwsA(isA<CloudLlmException>()),
      );
      expect(calls, 1);
    });

    test('模型 id 带点号与斜杠都原样发出（不改写用户填的 id）', () async {
      final server = _FakeServer((req, cap) async {
        expect(cap.body['model'], 'ds4.1-flash');
        await _FakeServer.sse(req, [
          'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);
      await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl, model: 'ds4.1-flash'),
            system: 's',
            user: 'u',
          )
          .join();
      // OpenRouter 那种 `provider/model` 也要原样透传
      final server2 = _FakeServer((req, cap) async {
        expect(cap.body['model'], 'deepseek/ds4.1-flash');
        await _FakeServer.sse(req, [
          'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n',
        ]);
      });
      await server2.start();
      addTearDown(server2.stop);
      await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server2.baseUrl, model: 'deepseek/ds4.1-flash'),
            system: 's',
            user: 'u',
          )
          .join();
    });
  });

  group('厂商预设（与官方文档对齐的硬事实）', () {
    test('id 唯一、地址合法、自定义项没有默认地址', () {
      final ids = kCloudProviders.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final p in kCloudProviders) {
        if (p.isCustom) {
          expect(p.baseUrl, isEmpty);
          continue;
        }
        expect(p.baseUrl, startsWith('http'), reason: p.id);
        expect(Uri.tryParse(p.baseUrl), isNotNull, reason: p.id);
      }
    });

    test('没有模型列表接口的厂商必须标出来（否则按钮点了必 404）', () {
      for (final id in const ['zhipu', 'dashscope', 'hunyuan']) {
        expect(cloudProviderById(id)!.supportsModelList, isFalse, reason: id);
      }
      expect(cloudProviderById('deepseek')!.supportsModelList, isTrue);
    });

    test('本地/自建服务不强制 key', () {
      for (final id in const ['ollama', 'lmstudio', 'vllm']) {
        expect(cloudProviderById(id)!.needsKey, isFalse, reason: id);
      }
      expect(cloudProviderById('openai')!.needsKey, isTrue);
    });

    test('协议与地址符合各家文档（不是统一拼 /v1）', () {
      expect(cloudProviderById('anthropic')!.protocol, CloudProtocol.anthropic);
      expect(cloudProviderById('gemini')!.protocol, CloudProtocol.gemini);
      expect(cloudProviderById('gemini')!.baseUrl, endsWith('/v1beta'));
      expect(cloudProviderById('zhipu')!.baseUrl, endsWith('/api/paas/v4'));
      expect(
        cloudProviderById('dashscope')!.baseUrl,
        endsWith('/compatible-mode/v1'),
      );
      expect(cloudProviderById('qianfan')!.baseUrl, endsWith('/v2'));
    });
  });

  group('OpenAI 兼容协议', () {
    test('流式：请求形状对 + 逐段吐字 + [DONE] 结束', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.sse(req, [
          'data: {"choices":[{"delta":{"content":"你好"}}]}\n\n',
          'data: {"choices":[{"delta":{"content":"，世界"}}]}\n\n',
          'data: [DONE]\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);

      final chunks = await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl),
            system: '你是助理',
            user: '打个招呼',
          )
          .toList();

      expect(chunks, ['你好', '，世界']);
      expect(server.captured.method, 'POST');
      expect(server.captured.path, '/v1/chat/completions');
      expect(server.captured.headers['authorization'], 'Bearer k-test');
      final body = server.captured.body;
      expect(body['model'], 'm-1');
      expect(body['stream'], isTrue);
      final messages = body['messages'] as List;
      expect((messages.first as Map)['role'], 'system');
      expect((messages.last as Map)['role'], 'user');
      expect((messages.last as Map)['content'], '打个招呼');
    });

    test('没发 [DONE] 也要正常收尾（不少网关不发）', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.sse(req, [
          'data: {"choices":[{"delta":{"content":"半个"}}]}\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);
      final chunks = await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl),
            system: '',
            user: 'x',
          )
          .toList();
      expect(chunks, ['半个']);
    });

    test('reasoning_content（思维链）不进正文', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.sse(req, [
          'data: {"choices":[{"delta":{"reasoning_content":"我先想想"}}]}\n\n',
          'data: {"choices":[{"delta":{"content":"答案"}}]}\n\n',
          'data: [DONE]\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);
      final chunks = await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl),
            system: 's',
            user: 'u',
          )
          .toList();
      expect(chunks, ['答案']);
    });

    test('模型 id 带尾随空格：发出去前必须 trim（真机上见过）', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'choices': [
            {
              'message': {'content': 'ok'},
            },
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      await CloudLlmClient().complete(
        cfg: _cfg(baseUrl: server.baseUrl, model: ' mock-1 '),
      );
      expect(server.captured.body['model'], 'mock-1');
    });

    test('非流式：complete 取 message.content', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'model': 'm-1',
          'choices': [
            {
              'message': {'role': 'assistant', 'content': '连接成功'},
            },
          ],
          'usage': {'total_tokens': 7},
        });
      });
      await server.start();
      addTearDown(server.stop);
      final res = await CloudLlmClient().complete(
        cfg: _cfg(baseUrl: server.baseUrl),
      );
      expect(res.text, '连接成功');
      expect(res.usage, contains('7'));
    });

    test('模型列表：解析 data[]，空列表不报错', () async {
      final server = _FakeServer((req, cap) async {
        if (req.uri.path.endsWith('/models')) {
          await _FakeServer.json(req, {
            'data': [
              {'id': 'b-model', 'owned_by': 'org'},
              {'id': 'a-model'},
            ],
          });
          return;
        }
        await _FakeServer.json(req, {});
      });
      await server.start();
      addTearDown(server.stop);
      final list = await CloudLlmClient().models(
        cfg: _cfg(baseUrl: server.baseUrl),
      );
      expect(list.map((m) => m.id), ['a-model', 'b-model']);
      expect(list.first.ownedBy, '');

      final empty = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {'data': <Object>[]});
      });
      await empty.start();
      addTearDown(empty.stop);
      expect(
        await CloudLlmClient().models(cfg: _cfg(baseUrl: empty.baseUrl)),
        isEmpty,
      );
    });

    test('本地服务没填 key：补占位 Bearer（Ollama/vLLM 要求头存在）', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.sse(req, ['data: [DONE]\n\n']);
      });
      await server.start();
      addTearDown(server.stop);
      await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl, key: ''),
            system: '',
            user: 'x',
          )
          .toList();
      expect(server.captured.headers['authorization'], 'Bearer not-needed');
    });
  });

  group('Anthropic Messages 协议', () {
    test('流式：x-api-key + anthropic-version，按事件名取 delta.text', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.sse(req, [
          'event: message_start\n'
              'data: {"type":"message_start","message":{"id":"msg_1"}}\n\n',
          'event: content_block_delta\n'
              'data: {"type":"content_block_delta","index":0,'
              '"delta":{"type":"text_delta","text":"要点一"}}\n\n',
          'event: content_block_delta\n'
              'data: {"type":"content_block_delta","index":0,'
              '"delta":{"type":"text_delta","text":"；要点二"}}\n\n',
          'event: message_stop\ndata: {"type":"message_stop"}\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);

      final chunks = await CloudLlmClient()
          .stream(
            cfg: _cfg(
              protocol: CloudProtocol.anthropic,
              baseUrl: server.baseUrl,
            ),
            system: 'sys',
            user: 'hi',
          )
          .toList();

      expect(chunks, ['要点一', '；要点二']);
      final h = server.captured.headers;
      expect(h['x-api-key'], 'k-test');
      expect(h['anthropic-version'], CloudLlmClient.kAnthropicVersion);
      // max_tokens 对 Anthropic 是必填
      expect(server.captured.body['max_tokens'], isA<int>());
      expect(server.captured.body['system'], 'sys');
      expect(server.captured.path, '/v1/messages');
    });

    test('事件里的 error 会被报成失败（不会静默返回空）', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.sse(req, [
          'event: error\n'
              'data: {"type":"error","error":{"type":"overloaded_error",'
              '"message":"Overloaded"}}\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);
      expect(
        () => CloudLlmClient()
            .stream(
              cfg: _cfg(
                protocol: CloudProtocol.anthropic,
                baseUrl: server.baseUrl,
              ),
              system: 's',
              user: 'u',
            )
            .toList(),
        throwsA(
          isA<CloudLlmException>().having(
            (e) => e.message,
            'message',
            contains('Overloaded'),
          ),
        ),
      );
    });

    test('非流式与模型列表', () async {
      final server = _FakeServer((req, cap) async {
        if (req.uri.path.endsWith('/models')) {
          await _FakeServer.json(req, {
            'data': [
              {'id': 'claude-x', 'display_name': 'Claude X'},
            ],
          });
          return;
        }
        await _FakeServer.json(req, {
          'content': [
            {'type': 'text', 'text': '连接'},
            {'type': 'text', 'text': '成功'},
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      final cfg = _cfg(
        protocol: CloudProtocol.anthropic,
        baseUrl: server.baseUrl,
      );
      expect((await CloudLlmClient().complete(cfg: cfg)).text, '连接成功');
      final list = await CloudLlmClient().models(cfg: cfg);
      expect(list.single.id, 'claude-x');
      expect(list.single.label, 'Claude X');
    });
  });

  group('Google Gemini 协议', () {
    test('流式：key 走查询串、alt=sse、model 带 models/ 前缀', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.sse(req, [
          'data: {"candidates":[{"content":{"parts":[{"text":"摘要"}]}}]}\n\n',
          'data: {"candidates":[{"content":{"parts":[{"text":"如下"}]}}]}\n\n',
        ]);
      });
      await server.start();
      addTearDown(server.stop);

      final chunks = await CloudLlmClient()
          .stream(
            cfg: _cfg(
              protocol: CloudProtocol.gemini,
              baseUrl: server.baseUrl,
              model: 'gemini-2.0-flash',
            ),
            system: 'sys',
            user: 'hi',
          )
          .toList();

      expect(chunks, ['摘要', '如下']);
      expect(
        server.captured.path,
        '/v1/models/gemini-2.0-flash:streamGenerateContent?alt=sse&key=k-test',
      );
      final body = server.captured.body;
      expect(body['systemInstruction'], isNotNull);
      expect((body['generationConfig'] as Map)['maxOutputTokens'], isA<int>());
      expect((body['contents'] as List).first, contains('parts'));
    });

    test('模型列表：去掉 models/ 前缀', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'models': [
            {
              'name': 'models/gemini-2.5-flash',
              'displayName': 'Gemini 2.5 Flash',
            },
            {'name': 'models/gemini-2.5-pro'},
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      final list = await CloudLlmClient().models(
        cfg: _cfg(protocol: CloudProtocol.gemini, baseUrl: server.baseUrl),
      );
      expect(list.map((m) => m.id), ['gemini-2.5-flash', 'gemini-2.5-pro']);
      expect(list.first.label, 'Gemini 2.5 Flash');
    });

    test('非流式 generateContent', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '连接成功'},
                ],
              },
            },
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      final res = await CloudLlmClient().complete(
        cfg: _cfg(protocol: CloudProtocol.gemini, baseUrl: server.baseUrl),
      );
      expect(res.text, '连接成功');
      expect(server.captured.path, contains(':generateContent?key=k-test'));
    });
  });

  group('错误说人话', () {
    test('401 带出服务端 message', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'error': {
            'message': 'Incorrect API key provided',
            'type': 'invalid_request_error',
          },
        }, status: 401);
      });
      await server.start();
      addTearDown(server.stop);
      final e = await CloudLlmClient()
          .stream(
            cfg: _cfg(baseUrl: server.baseUrl),
            system: 's',
            user: 'u',
          )
          .toList()
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<CloudLlmException>());
      final msg = (e as CloudLlmException).message;
      expect(msg, contains('401'));
      expect(msg, contains('Incorrect API key provided'));
    });

    test('404 提示检查 base URL 与模型；非 JSON 错误页也能给出片段', () async {
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'error': {'message': 'model not found'},
        }, status: 404);
      });
      await server.start();
      addTearDown(server.stop);
      final cfg = _cfg(baseUrl: server.baseUrl);
      expect(
        () => CloudLlmClient().complete(cfg: cfg),
        throwsA(
          isA<CloudLlmException>().having(
            (e) => e.message,
            'message',
            allOf(contains('404'), contains('base URL')),
          ),
        ),
      );

      final html = _FakeServer((req, cap) async {
        await _FakeServer.text(
          req,
          '<html>502 Bad Gateway</html>',
          status: 502,
        );
      });
      await html.start();
      addTearDown(html.stop);
      expect(
        () => CloudLlmClient().complete(cfg: _cfg(baseUrl: html.baseUrl)),
        throwsA(
          isA<CloudLlmException>().having(
            (e) => e.message,
            'message',
            allOf(contains('502'), contains('Bad Gateway')),
          ),
        ),
      );
    });

    test('连不上本机端口：明确提示要用局域网 IP', () async {
      // 先占一个端口再关掉，保证这个端口没人监听
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(force: true);
      final e = await CloudLlmClient()
          .complete(
            cfg: CloudLlmConfig(
              protocol: CloudProtocol.openai,
              baseUrl: 'http://127.0.0.1:$port/v1',
              apiKey: 'k',
              model: 'm',
            ),
          )
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<CloudLlmException>());
      expect((e as CloudLlmException).message, contains('连不上'));
    });

    test('describeHttpError 覆盖常见码，describeCloudError 兜底', () {
      expect(describeHttpError(429, null), contains('限流'));
      expect(describeHttpError(500, null), contains('服务端错误'));
      expect(
        describeHttpError(400, '{"error":"bad param"}'),
        contains('bad param'),
      );
      expect(describeCloudError(StateError('x')), contains('x'));
    });
  });
}
