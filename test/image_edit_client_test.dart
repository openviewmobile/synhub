// 图生图客户端测试：**起真 HTTP server** 打三类协议（照 `cloud_llm_client_test.dart`）。
//
// 为什么不上 mock adapter：multipart 的 boundary/字段名、Gemini 的 `inline_data`
// 嵌套、A1111 的 data-URI —— 这些只有走真 socket 才能确认线格式与代码一致。
//
// 覆盖：A1/A2/B1 请求构造、响应解析（含"两种都认"）、错误矩阵（HTTP/网络/解析）、
// 以及"错误文案不泄漏 base64/URL/路径/提示词"的硬规矩。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:synhub/src/data/ai/image_edit_client.dart';
import 'package:synhub/src/data/ai/image_edit_prompts.dart';

/// 一张合法的测试图（PNG）
Uint8List _samplePng({int w = 32, int h = 24}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(10, 200, 90));
  return Uint8List.fromList(img.encodePng(image));
}

class _Captured {
  String path = '';
  String method = '';
  String contentType = '';
  Map<String, String> headers = {};
  Uint8List raw = Uint8List(0);
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
        ..method = req.method
        ..contentType = req.headers.contentType?.toString() ?? '';
      req.headers.forEach((k, v) => cap.headers[k] = v.join(','));
      final chunks = <int>[];
      await for (final c in req) {
        chunks.addAll(c);
      }
      cap.raw = Uint8List.fromList(chunks);
      captured
        ..path = cap.path
        ..method = cap.method
        ..contentType = cap.contentType
        ..headers = cap.headers
        ..raw = cap.raw;
      await _handler(req, cap);
    });
  }

  Future<void> stop() => _server.close(force: true);

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
    req.response.headers.contentType = ContentType.html;
    req.response.write(body);
    await req.response.close();
  }
}

/// multipart 解析（只用 dart:convert 的 latin1，不引新依赖）
class _Multipart {
  _Multipart(this.fields, this.files, this.partContentTypes);

  final Map<String, String> fields;
  final Map<String, Uint8List> files;
  final Map<String, String> partContentTypes;
}

_Multipart _parseMultipart(Uint8List raw, String contentType) {
  final m = RegExp(r'boundary=(.+)$').firstMatch(contentType.trim());
  expect(m, isNotNull, reason: 'multipart 必须带 boundary');
  var boundary = m!.group(1)!.trim();
  if (boundary.startsWith('"') && boundary.endsWith('"')) {
    boundary = boundary.substring(1, boundary.length - 1);
  }
  final s = latin1.decode(raw);
  final fields = <String, String>{};
  final files = <String, Uint8List>{};
  final cts = <String, String>{};
  for (final chunk in s.split('--$boundary')) {
    if (chunk.trim().isEmpty || chunk.startsWith('--')) continue;
    final headEnd = chunk.indexOf('\r\n\r\n');
    if (headEnd < 0) continue;
    final headers = chunk.substring(0, headEnd);
    var content = chunk.substring(headEnd + 4);
    if (content.endsWith('\r\n')) {
      content = content.substring(0, content.length - 2);
    }
    final name = RegExp(r'name="([^"]*)"').firstMatch(headers)?.group(1) ?? '';
    if (name.isEmpty) continue;
    final isFile = headers.contains('filename=');
    if (isFile) {
      files[name] = Uint8List.fromList(content.codeUnits);
      final ct = RegExp(
        r'content-type:\s*([^\r\n]+)',
        caseSensitive: false,
      ).firstMatch(headers)?.group(1);
      if (ct != null) cts[name] = ct.trim();
    } else {
      // 文本字段是 UTF-8（dio 默认带 charset=utf-8）
      fields[name] = utf8.decode(content.codeUnits, allowMalformed: true);
    }
  }
  return _Multipart(fields, files, cts);
}

ImageEditConfig _cfg({
  ImageEditBackend backend = ImageEditBackend.openAiImagesEdits,
  String baseUrl = '',
  String key = 'k-test',
  String model = 'gpt-image-1',
  String prompt = '提升清晰度',
  ImageEditStrength strength = ImageEditStrength.medium,
  int variants = 1,
}) => ImageEditConfig(
  backend: backend,
  baseUrl: baseUrl,
  apiKey: key,
  model: model,
  prompt: prompt,
  strength: strength,
  variants: variants,
);

void main() {
  // flutter_test 默认把 HttpOverrides 换成"全部 400"的桩，这里还原成真实现
  setUpAll(() => HttpOverrides.global = null);

  group('A1 OpenAI 兼容 images/edits（multipart 字段名逐字）', () {
    test('请求是 multipart，字段名含 image/prompt/n/size，图片是可还原的原字节', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        final mp = _parseMultipart(cap.raw, cap.contentType);
        expect(cap.method, 'POST');
        expect(cap.path, endsWith('/v1/images/edits'));
        expect(cap.contentType, contains('multipart/form-data'));
        // 字段名逐字（方案 §4.1 A1）
        for (final f in kOpenAiImageEditFieldNames) {
          expect(
            mp.fields.containsKey(f) || mp.files.containsKey(f),
            isTrue,
            reason: '缺字段 $f',
          );
        }
        expect(mp.files['image'], equals(input));
        expect(mp.partContentTypes['image'], contains('image/jpeg'));
        expect(mp.fields['prompt'], '提升清晰度');
        expect(mp.fields['n'], '1');
        expect(mp.fields['size'], 'auto');
        expect(mp.fields['response_format'], 'b64_json');
        await _FakeServer.json(req, {
          'data': [
            {'b64_json': base64Encode(input)},
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);

      final out = await ImageEditClient().edit(
        cfg: _cfg(baseUrl: server.baseUrl),
        imageBytes: input,
      );
      expect(out.ok, isTrue);
      expect(out.images.single, equals(input));
    });

    test('n=3 时 multipart 的 n 逐字为 3', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        final mp = _parseMultipart(cap.raw, cap.contentType);
        expect(mp.fields['n'], '3');
        await _FakeServer.json(req, {
          'data': [
            {'b64_json': base64Encode(input)},
            {'b64_json': base64Encode(input)},
            {'b64_json': base64Encode(input)},
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      final out = await ImageEditClient().edit(
        cfg: _cfg(baseUrl: server.baseUrl, variants: 3),
        imageBytes: input,
      );
      expect(out.okCount, 3);
    });

    test('只回 url 不采信：判失败、不下载、文案里没有那个主机名', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'data': [
            {'url': 'https://evil.example.com/a.png'},
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      await expectLater(
        ImageEditClient().edit(
          cfg: _cfg(baseUrl: server.baseUrl),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>()
              .having((e) => e.kind, 'kind', ImageEditErrorKind.urlOnlyResult)
              .having(
                (e) => e.message,
                'message',
                isNot(contains('evil.example')),
              ),
        ),
      );
    });

    test('部分变体失败：成功几张报几张，不把失败说成成功', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'data': [
            {'b64_json': base64Encode(input)},
            {'b64_json': base64Encode(utf8.encode('this is not an image'))},
            {'b64_json': base64Encode(input)},
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      final out = await ImageEditClient().edit(
        cfg: _cfg(baseUrl: server.baseUrl, variants: 3),
        imageBytes: input,
      );
      expect(out.partial, isTrue);
      expect(out.okCount, 2);
      expect(out.failed, 1);
      expect(out.warningKind, ImageEditErrorKind.partialVariants);
      expect(out.warningText(), contains('成功 2 张'));
      expect(out.warningText(), contains('失败 1 张'));
    });
  });

  group('A2 Gemini generateContent（JSON + inline_data）', () {
    test('请求体是 JSON，inline_data.mime_type/data 可还原；响应 camelCase 也认', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        expect(cap.method, 'POST');
        expect(
          cap.path,
          contains('/v1/models/gemini-2.5-flash:generateContent'),
        );
        // key 走查询串（这正是"404 只显示主机名"的原因）
        expect(cap.path, contains('key=k-test'));
        final body = jsonDecode(utf8.decode(cap.raw)) as Map<String, dynamic>;
        final parts =
            ((body['contents'] as List).first as Map)['parts'] as List;
        expect(parts.length, 2);
        expect((parts[0] as Map)['text'], isNotEmpty);
        final inline = (parts[1] as Map)['inline_data'] as Map;
        expect(inline['mime_type'], 'image/jpeg');
        expect(base64Decode(inline['data'] as String), equals(input));
        // 响应用 REST camelCase（Q6：两种都认）
        await _FakeServer.json(req, {
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'inlineData': {
                      'mimeType': 'image/jpeg',
                      'data': base64Encode(input),
                    },
                  },
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      final out = await ImageEditClient().edit(
        cfg: _cfg(
          backend: ImageEditBackend.geminiGenerateContent,
          baseUrl: server.baseUrl,
          model: 'gemini-2.5-flash',
        ),
        imageBytes: input,
      );
      expect(out.ok, isTrue);
      expect(out.images.single, equals(input));
    });

    test('响应用 proto 原名 inline_data 也认（两种都认）', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'inline_data': {
                      'mime_type': 'image/png',
                      'data': base64Encode(input),
                    },
                  },
                ],
              },
            },
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      final out = await ImageEditClient().edit(
        cfg: _cfg(
          backend: ImageEditBackend.geminiGenerateContent,
          baseUrl: server.baseUrl,
          model: 'gemini-2.5-flash',
        ),
        imageBytes: input,
      );
      expect(out.okCount, 1);
    });

    test('被安全策略掐断（finishReason=SAFETY）→ contentBlocked，不静默', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'candidates': [
            {
              'content': {'parts': <Object>[]},
              'finishReason': 'SAFETY',
            },
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      await expectLater(
        ImageEditClient().edit(
          cfg: _cfg(
            backend: ImageEditBackend.geminiGenerateContent,
            baseUrl: server.baseUrl,
            model: 'gemini-2.5-flash',
          ),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>().having(
            (e) => e.kind,
            'kind',
            ImageEditErrorKind.contentBlocked,
          ),
        ),
      );
    });
  });

  group('B1 A1111 img2img（init_images 只发 base64/data-URI）', () {
    test('init_images[0] 是 data-URI 且能还原原字节；强度=denoising_strength', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        expect(cap.path, endsWith('/v1/sdapi/v1/img2img'));
        final body = jsonDecode(utf8.decode(cap.raw)) as Map<String, dynamic>;
        final init = (body['init_images'] as List).cast<String>();
        expect(init.length, 1);
        // ⚠️ 安全硬规矩：绝不能是 URL
        expect(init[0].startsWith('http://'), isFalse);
        expect(init[0].startsWith('https://'), isFalse);
        expect(init[0].startsWith('data:image/jpeg;base64,'), isTrue);
        final b64 = init[0].substring('data:image/jpeg;base64,'.length);
        expect(base64Decode(b64), equals(input));
        expect(body['denoising_strength'], 0.6);
        expect(body['batch_size'], 2);
        expect(body['n_iter'], 1);
        await _FakeServer.json(req, {
          'images': [base64Encode(input), base64Encode(input)],
          'info': '{"prompt":"不该被采用"}',
        });
      });
      await server.start();
      addTearDown(server.stop);
      final out = await ImageEditClient().edit(
        cfg: _cfg(
          backend: ImageEditBackend.a1111Img2Img,
          baseUrl: server.baseUrl,
          key: '',
          model: '',
          strength: ImageEditStrength.strong,
          variants: 2,
        ),
        imageBytes: input,
      );
      expect(out.ok, isTrue);
      expect(out.okCount, 2);
    });

    test('强度弱/中/强 → denoising_strength 0.2/0.4/0.6', () {
      final input = _samplePng();
      for (final (s, d) in [
        (ImageEditStrength.weak, 0.2),
        (ImageEditStrength.medium, 0.4),
        (ImageEditStrength.strong, 0.6),
      ]) {
        final body = buildA1111Img2ImgBody(
          _cfg(
            backend: ImageEditBackend.a1111Img2Img,
            baseUrl: 'http://192.168.1.9:7860',
            key: '',
            model: '',
            strength: s,
          ),
          input,
        );
        expect(body['denoising_strength'], d);
      }
    });
  });

  group('错误矩阵：HTTP 状态码 → 确定类型 + 文案（不泄漏 URL/key）', () {
    Future<void> expectHttp(
      int code,
      ImageEditErrorKind kind, {
      String body = '{"error":{"message":"boom"}}',
    }) async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await _FakeServer.text(req, body, status: code);
      });
      await server.start();
      addTearDown(server.stop);
      await expectLater(
        ImageEditClient().edit(
          cfg: _cfg(
            backend: ImageEditBackend.geminiGenerateContent,
            baseUrl: server.baseUrl,
            model: 'gemini-x',
            key: 'sk-super-secret-key',
          ),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>()
              .having((e) => e.kind, 'kind', kind)
              .having(
                (e) => e.message,
                'message',
                isNot(contains('sk-super-secret-key')),
              ),
        ),
      );
    }

    test(
      '400 → requestRejected',
      () => expectHttp(400, ImageEditErrorKind.requestRejected),
    );
    test(
      '401 → keyInvalid',
      () => expectHttp(401, ImageEditErrorKind.keyInvalid),
    );
    test(
      '402 → insufficientBalance',
      () => expectHttp(402, ImageEditErrorKind.insufficientBalance),
    );
    test(
      '403 → noPermission',
      () => expectHttp(403, ImageEditErrorKind.noPermission),
    );
    test(
      '413 → bodyTooLarge',
      () => expectHttp(413, ImageEditErrorKind.bodyTooLarge),
    );
    test(
      '422 → paramsRejected',
      () => expectHttp(422, ImageEditErrorKind.paramsRejected),
    );
    test(
      '429 → rateLimited',
      () => expectHttp(429, ImageEditErrorKind.rateLimited),
    );
    test(
      '500/502 → serverError',
      () => expectHttp(502, ImageEditErrorKind.serverError),
    );

    test('404 只显示主机名，不显示完整 URL / 查询串 / key', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await _FakeServer.text(
          req,
          '{"error":{"message":"model not found"}}',
          status: 404,
        );
      });
      await server.start();
      addTearDown(server.stop);
      ImageEditException? caught;
      try {
        await ImageEditClient().edit(
          cfg: _cfg(
            backend: ImageEditBackend.geminiGenerateContent,
            baseUrl: server.baseUrl,
            model: 'gemini-x',
            key: 'sk-super-secret-key',
          ),
          imageBytes: input,
        );
      } on ImageEditException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.kind, ImageEditErrorKind.notFound);
      expect(caught.message, contains('127.0.0.1'));
      expect(caught.message, isNot(contains('/v1/models')));
      expect(caught.message, isNot(contains('key=')));
      expect(caught.message, isNot(contains('sk-super-secret-key')));
    });

    test('响应不是 JSON（HTML 网关页）→ notJson', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await _FakeServer.text(req, '<html><body>login</body></html>');
      });
      await server.start();
      addTearDown(server.stop);
      await expectLater(
        ImageEditClient().edit(
          cfg: _cfg(baseUrl: server.baseUrl),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>().having(
            (e) => e.kind,
            'kind',
            ImageEditErrorKind.notJson,
          ),
        ),
      );
    });

    test('200 但 base64 解出来不是图片 → invalidImageResult', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'data': [
            {'b64_json': base64Encode(utf8.encode('hello, not an image'))},
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      await expectLater(
        ImageEditClient().edit(
          cfg: _cfg(baseUrl: server.baseUrl),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>()
              .having(
                (e) => e.kind,
                'kind',
                ImageEditErrorKind.invalidImageResult,
              )
              .having((e) => e.message, 'no echo', isNot(contains('hello'))),
        ),
      );
    });

    test('0 字节图片 → emptyImageResult', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'data': [
            {'b64_json': ''},
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      await expectLater(
        ImageEditClient().edit(
          cfg: _cfg(baseUrl: server.baseUrl),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>().having(
            (e) => e.kind,
            'kind',
            ImageEditErrorKind.emptyImageResult,
          ),
        ),
      );
    });

    test('连不上本地端口 → localUnreachable（带主机名）', () async {
      final input = _samplePng();
      // 先占一个端口再关掉，确保没人监听
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close(force: true);
      ImageEditException? caught;
      try {
        await ImageEditClient().edit(
          cfg: _cfg(
            backend: ImageEditBackend.a1111Img2Img,
            baseUrl: 'http://127.0.0.1:$port',
            key: '',
            model: '',
          ),
          imageBytes: input,
        );
      } on ImageEditException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.kind, ImageEditErrorKind.localUnreachable);
      expect(caught.message, contains('127.0.0.1'));
    });

    test('生成超时（receiveTimeout）→ generateTimeout，与连接超时区分', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await _FakeServer.json(req, {
          'data': [
            {'b64_json': base64Encode(input)},
          ],
        });
      });
      await server.start();
      addTearDown(server.stop);
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(milliseconds: 150),
          validateStatus: (_) => true,
        ),
      );
      await expectLater(
        ImageEditClient(dio: dio).edit(
          cfg: _cfg(baseUrl: server.baseUrl),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>().having(
            (e) => e.kind,
            'kind',
            ImageEditErrorKind.generateTimeout,
          ),
        ),
      );
    });

    test('取消（已发出）→ cancelledBilling，如实说明可能计费', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await _FakeServer.json(req, {'data': <Object>[]});
      });
      await server.start();
      addTearDown(server.stop);
      final token = CancelToken();
      final fut = ImageEditClient().edit(
        cfg: _cfg(baseUrl: server.baseUrl),
        imageBytes: input,
        cancel: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      token.cancel('user');
      await expectLater(
        fut,
        throwsA(
          isA<ImageEditException>()
              .having(
                (e) => e.kind,
                'kind',
                ImageEditErrorKind.cancelledBilling,
              )
              .having((e) => e.message, 'message', contains('可能仍会计费')),
        ),
      );
    });
  });

  group('响应体自带 error → 不静默', () {
    test('200 + error.message → serverErrorBody 并带服务端 message', () async {
      final input = _samplePng();
      final server = _FakeServer((req, cap) async {
        await _FakeServer.json(req, {
          'error': {'message': 'bad size'},
        });
      });
      await server.start();
      addTearDown(server.stop);
      await expectLater(
        ImageEditClient().edit(
          cfg: _cfg(baseUrl: server.baseUrl),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>()
              .having((e) => e.kind, 'kind', ImageEditErrorKind.serverErrorBody)
              .having((e) => e.message, 'message', contains('bad size')),
        ),
      );
    });
  });

  group('提示词强度：A1/A2 用前缀改写，B1 用 denoising', () {
    test('弱/中/强 的前缀改写', () {
      expect(applyStrengthToPrompt(ImageEditStrength.medium, '提升清晰度'), '提升清晰度');
      expect(
        applyStrengthToPrompt(ImageEditStrength.weak, '提升清晰度'),
        startsWith('尽量轻微地'),
      );
      expect(
        applyStrengthToPrompt(ImageEditStrength.strong, '提升清晰度'),
        startsWith('大幅度重绘'),
      );
      expect(applyStrengthToPrompt(ImageEditStrength.weak, '  '), '');
    });
  });

  group('文本消毒：错误信息不得带 base64 / URL / 路径 / 提示词', () {
    test('sanitizeServerText 抹掉 key、提示词、链接、路径、超长 base64', () {
      final key = 'sk-super-secret-key';
      final prompt = '把背景换成纯白';
      final raw = {
        'error': {
          'message':
              'bad request for $key prompt=$prompt at '
              'https://api.example.com/v1/images?key=$key from '
              '/Users/someone/Photos/a.jpg data=${'A' * 300}',
        },
      };
      final out = sanitizeServerText(raw, secrets: [key, prompt]);
      expect(out, isNot(contains(key)));
      expect(out, isNot(contains(prompt)));
      expect(out, isNot(contains('https://')));
      expect(out, isNot(contains('/Users/someone')));
      expect(out, isNot(contains('A' * 120)));
      expect(out, contains('<链接已隐藏>'));
      expect(out, contains('<路径已隐藏>'));
      expect(out, contains('<数据已隐藏>'));
    });

    test('ImageEditConfig.toString() 不含 key，也不含查询串；提示词只记长度', () {
      final cfg = _cfg(
        backend: ImageEditBackend.geminiGenerateContent,
        baseUrl:
            'https://generativelanguage.googleapis.com/v1beta?key=leaked-token',
        key: 'sk-super-secret',
        prompt: '把这张照片改成插画风格',
      );
      final s = cfg.toString();
      expect(s, isNot(contains('sk-super-secret')));
      expect(s, isNot(contains('leaked-token')));
      expect(s, isNot(contains('插画')));
      expect(s, contains('promptChars='));
      expect(s, contains('generativelanguage.googleapis.com'));
    });

    test('redactUrl 丢 query 与 userInfo', () {
      expect(
        redactUrl('https://user:pw@h.example/v1?key=abc#frag'),
        'https://h.example/v1',
      );
    });
  });

  group('配置/参数校验', () {
    test('空提示词 → promptEmpty；超长 → promptTooLong', () async {
      final input = _samplePng();
      await expectLater(
        ImageEditClient().edit(
          cfg: _cfg(baseUrl: 'http://127.0.0.1:1', prompt: ''),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>().having(
            (e) => e.kind,
            'kind',
            ImageEditErrorKind.promptEmpty,
          ),
        ),
      );
      await expectLater(
        ImageEditClient().edit(
          cfg: _cfg(
            baseUrl: 'http://127.0.0.1:1',
            prompt: '长' * (kImageEditPromptMaxChars + 1),
          ),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>().having(
            (e) => e.kind,
            'kind',
            ImageEditErrorKind.promptTooLong,
          ),
        ),
      );
    });

    test('base URL 为空 → backendNotConfigured（不发请求）', () async {
      final input = _samplePng();
      await expectLater(
        ImageEditClient().edit(
          cfg: _cfg(baseUrl: ''),
          imageBytes: input,
        ),
        throwsA(
          isA<ImageEditException>().having(
            (e) => e.kind,
            'kind',
            ImageEditErrorKind.backendNotConfigured,
          ),
        ),
      );
    });
  });
}
