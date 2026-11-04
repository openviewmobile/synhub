// 真机/真服务联调探针：用**线上那份客户端/引擎代码**打用户实际配置的中转地址。
//
// 为什么不是 curl：用户报"配上 deepseek-v4.1-flash 不兼容"，必须用同一套
// Dio 传输配置（头、gzip、ResponseType.stream、SSE 解析）复现，才能判断是
// 传输层、模型层还是预算问题。
//
// 跑法（key 从环境变量进，不写进仓库、不打印）：
//   RELAY_KEY=$(cat /tmp/relay_key.txt) flutter test tool/relay_probe.dart
//
// 注意：这个文件在 `tool/` 下，**不属于默认 test/ 套件**（要显式指定路径）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/ai/cloud_llm_client.dart';
import 'package:synhub/src/data/ai/cloud_provider.dart';
import 'package:synhub/src/features/ai/cloud_engine.dart';
import 'package:synhub/src/features/ai/llm_engine.dart';

const _base = 'https://nas.example.com:8083/v1';
const _model = 'deepseek-v4.1-flash';

String get _key => Platform.environment['RELAY_KEY'] ?? '';

const _system =
    '你是一个装在手机本地的阅读助手。'
    '回答必须使用简体中文，只依据我给你的原文，不要编造原文里没有的信息；'
    '如果原文不足以回答，就直接说"原文里没有提到"。 你要把原文概括成几条要点，每条不超过 40 字。';

String _user(String text, {String title = 'A Clash of Kings'}) =>
    '《$title》 的下面这段内容，请用 3-5 条要点概括（每行一条，用「- 」开头）：\n\n$text';

String _chapter(int chars) {
  const base =
      'Lord Janos gave Tyrion a wary look, then laughed and wagged a wedge of cheese at him. '
      '“You’re a sly one, Tyrion. Thought you could trick me, did you? It takes more than wine and cheese '
      'to make Janos Slynt tell more than he should.” Tyrion broke off a nibble of the cheese. '
      'It was sharp indeed, and veined with wine; very choice. ';
  final b = StringBuffer();
  while (b.length < chars) {
    b.write(base);
  }
  return b.toString().substring(0, chars);
}

CloudLlmConfig _cfg({int maxTokens = 1024}) => CloudLlmConfig(
  protocol: CloudProtocol.openai,
  baseUrl: _base,
  apiKey: _key,
  model: _model,
  temperature: 0.4,
  maxTokens: maxTokens,
);

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('原始 Dio：看真实响应头（gzip? chunked? content-type?）', () async {
    final dio = Dio(BaseOptions(validateStatus: (_) => true));
    final res = await dio.post<ResponseBody>(
      '$_base/chat/completions',
      data: jsonEncode({
        'model': _model,
        'messages': [
          {'role': 'system', 'content': _system},
          {'role': 'user', 'content': _user(_chapter(6000))},
        ],
        'stream': true,
        'temperature': 0.4,
        'max_tokens': 1024,
      }),
      options: Options(
        headers: {
          'Authorization': 'Bearer $_key',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.stream,
      ),
    );
    // ignore: avoid_print
    print('[probe] status=${res.statusCode} headers=${res.headers.map}');
    final stream = res.data!.stream;
    var bytes = 0;
    var text = '';
    await for (final chunk in stream) {
      bytes += chunk.length;
      if (text.length < 200) {
        text += utf8.decode(chunk, allowMalformed: true);
      }
      if (bytes > 4000) break;
    }
    // ignore: avoid_print
    print(
      '[probe] first bytes=$bytes head=${text.substring(0, text.length.clamp(0, 160))}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  for (final chars in [60, 6000]) {
    test('引擎（含自动加大预算）：输入 $chars 字', () async {
      final engine = CloudLlmEngine(configOf: () => _cfg());
      final sw = Stopwatch()..start();
      final chunks = <String>[];
      var error = '';
      try {
        await for (final piece
            in engine
                .generate(
                  LlmPrompt(system: _system, user: _user(_chapter(chars))),
                )
                .timeout(const Duration(seconds: 240))) {
          chunks.add(piece);
        }
      } catch (e) {
        error = '$e';
      }
      sw.stop();
      final all = chunks.join();
      // ignore: avoid_print
      print(
        '[probe] chars=$chars chunks=${chunks.length} out=${all.length} '
        'ms=${sw.elapsedMilliseconds} retried=${engine.retriedBudget} error=$error',
      );
      // ignore: avoid_print
      print(
        '[probe] out=${all.replaceAll('\n', ' ').substring(0, all.length.clamp(0, 220))}',
      );
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}
