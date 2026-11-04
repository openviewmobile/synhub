// 把"引擎 + prompt + 解析"捏成一个对 UI 友好的服务。
//
// UI 只调两件事：
//   * `stream(req)` —— 拿到逐段文本，边出边显示；
//   * `finish(raw, req)` —— 出完了，把原始输出解析成要点/引用，包成 [AiAnswer]。
import 'dart:async';

import '../../data/ai/cloud_llm_client.dart';
import '../../data/ai/cloud_pricing.dart';
import 'ai_prompts.dart';
import 'cloud_engine.dart';
import 'llm_engine.dart';
import 'on_device_ai.dart';
import 'text_ai.dart';
import '../../core/user_facing_error.dart';

class AiService {
  AiService(this.engine);

  final LlmEngine engine;

  /// 当前引擎档位（UI 用它把错误文案分档说人话）
  AiEngineKind get engineKind => engine.kind;

  /// 上一次生成里云端是否"因为只在思考而自动加大过长度"（0 = 没有）
  ///
  /// 多花了一次调用，所以要如实告诉用户（见 `cloud_engine.dart` 的
  /// `CloudReasoningOnlyException` 自动补救）。
  int get lastRetriedBudget {
    final e = engine;
    return e is CloudLlmEngine ? e.retriedBudget : 0;
  }

  /// 上一次生成里模型给的**思考正文**（云端引擎才有；UI 折叠展示用）
  ///
  /// 端侧的 ` thinking` 段由 `text_ai.dart` 的 `extractThinkingText` 从原始
  /// 输出里摘，不走这里。
  String get lastThinking {
    final e = engine;
    return e is CloudLlmEngine ? e.lastThinking : '';
  }

  /// 上一次生成的 token 用量（云端引擎才有）
  CloudTokenUsage get lastUsage {
    final e = engine;
    return e is CloudLlmEngine ? e.lastUsage : CloudTokenUsage.zero;
  }

  /// 逐段生成（UI 直接把这些段拼起来显示；结束后再调 [finish]）
  Stream<String> stream(AiRequest req, {String language = '中文'}) {
    return engine
        .generate(
          LlmPrompt(
            system: aiSystemPrompt(req.kind),
            user: aiUserPrompt(req, language: language),
            maxOutputTokens: req.maxOutputTokens,
          ),
        )
        .handleError((Object e) {
          // 生成中途失败（掉内存、模型损坏、云端 401/超时）不要把异常抛到 UI 层，
          // 让 UI 显示"这次没答上来"而不是红屏。
          // 云端错误的文案由 `describeCloudError` 统一给出（401/404/超时各有说法）。
          throw AiFailure(e is CloudLlmException ? e.message : userFacingError(e));
        });
  }

  /// 用户点"停止"：除了取消订阅，还要**掐掉云端那条 HTTP 请求**
  /// （否则它还在后台跑，白烧 token）
  void cancel() {
    final e = engine;
    if (e is CloudLlmEngine) e.cancel();
  }

  /// 把原始输出整理成结论（要点的前缀剥掉、引用解析出来）
  Future<AiAnswer> finish(
    String raw,
    AiRequest req, {
    required int elapsedMs,
    LlmStatus? status,
  }) async {
    final st = status ?? await engine.status();
    final clean = stripModelNoise(raw);
    final isExtractive = engine.kind == AiEngineKind.extractive;
    var text = clean;
    if (req.kind == AiTaskKind.summary ||
        (isExtractive && req.kind == AiTaskKind.askBook)) {
      final bullets = parseBullets(clean);
      if (bullets.isNotEmpty) {
        text = bullets.map((b) => '- $b').join('\n');
      }
    }
    return AiAnswer(
      text: text.trim(),
      engine: engine.kind,
      kind: req.kind,
      passages: req.contexts,
      elapsedMs: elapsedMs,
      modelName: st.modelName,
      truncated: clampInput(req.text).truncated,
    );
  }

  /// 一次跑完（不流式）——给"测试按钮"和单测用
  Future<AiAnswer> run(AiRequest req, {String language = '中文'}) async {
    final sw = Stopwatch()..start();
    final buf = StringBuffer();
    await for (final chunk in stream(req, language: language)) {
      buf.write(chunk);
    }
    sw.stop();
    return finish(buf.toString(), req, elapsedMs: sw.elapsedMilliseconds);
  }
}

/// AI 调用失败（模型不可用等）——UI 据此说人话
class AiFailure implements Exception {
  AiFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 把请求的"可信度"/展示信息补齐：`askBook` 要先检索再问
AiRequest withRetrieval(AiRequest req, List<AiPassage> all) {
  if (req.kind != AiTaskKind.askBook) return req;
  return AiRequest(
    kind: req.kind,
    text: req.text,
    title: req.title,
    question: req.question,
    contexts: rankPassages(req.question, all),
    language: req.language,
    maxOutputTokens: req.maxOutputTokens,
  );
}
