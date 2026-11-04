// 云端大模型引擎：把 [CloudLlmClient] 适配成 [LlmEngine]。
//
// 这样做的好处：**功能层一行都不用改**（阅读器/笔记/文档预览只认 `LlmEngine`），
// 云端与端侧可以互换；`AiRequest` → prompt → 流式文本 → `AiService.finish` 的
// 后处理（要点拆解、引用解析）全部复用。
//
// 这一轮多了三件事（都不改 `LlmEngine` 接口）：
//   1. **思考内容**收进 [lastThinking]，UI 折叠展示（以前只数字数）；
//   2. **token 用量**收进 [lastUsage]，并通过 [onUsage] 上报给设置层记账；
//   3. 服务端没回 usage 时按字符数折算（引擎这边算，统计里标「估算」）。
import 'dart:async';
import 'dart:math' as math;

import '../../core/i18n/l10n.dart';
import '../../data/ai/cloud_llm_client.dart';
import '../../data/ai/cloud_pricing.dart';
import 'llm_engine.dart';
import 'on_device_ai.dart';

/// 云端引擎：每次生成都用当前配置现取（用户在设置里改了立刻生效）
class CloudLlmEngine implements LlmEngine {
  CloudLlmEngine({required this.configOf, CloudLlmClient? client})
    : client = client ?? CloudLlmClient();

  final CloudLlmClient client;

  /// 取当前配置（provider/url/key/model/参数）——由 provider 层提供，
  /// 避免把 Riverpod 依赖塞进数据/引擎层
  final CloudLlmConfig? Function() configOf;

  CancelTokenHolder? _last;

  /// 上一次生成里模型给的思考正文（可折叠展示；空串 = 没有）
  String lastThinking = '';

  /// 上一次生成（最后一次尝试）的 token 用量
  CloudTokenUsage lastUsage = CloudTokenUsage.zero;

  /// 每次调用结束上报一次（设置层拿它记账）
  void Function(CloudUsageRecord record)? onUsage;

  @override
  AiEngineKind get kind => AiEngineKind.cloud;

  @override
  Future<LlmStatus> status() async {
    final cfg = configOf();
    if (cfg == null || !cfg.usable) {
      return LlmStatus(
        readiness: AiReadiness.unsupported,
        detail: currentText().aiCloudNotConfiguredHint,
      );
    }
    return LlmStatus(
      readiness: AiReadiness.ready,
      modelName: cfg.model,
      modelId: cfg.model,
      // 协议名走数据层文案（批次 2d：中英可切）
      backend: cfg.protocol.labelText,
      detail: cfg.baseUrl,
    );
  }

  @override
  Stream<String> generate(LlmPrompt prompt) {
    final cfg = configOf();
    if (cfg == null || !cfg.usable) {
      return Stream<String>.error(
        CloudLlmException(currentText().aiCloudNotConfigured),
      );
    }
    final holder = CancelTokenHolder();
    _last = holder;
    // 每次生成都清零：UI 只关心"这一次"有没有自动加大过 / 思考了什么
    retriedBudget = 0;
    lastThinking = '';
    lastUsage = CloudTokenUsage.zero;
    return _run(
      holder,
      // ⚠️ 取**两者较大值**：prompt 里带的 `maxOutputTokens`（阅读器/笔记默认 512、
      // 试用按钮 256）以前会直接覆盖用户在「高级参数」里配的值；对**推理模型**
      // （如 ds4.1-flash 这类）来说，512 个 token 会被思考过程吃光 → 正文一个字
      // 都没有，用户看到的却是"没反应"，误以为是模型不兼容。
      cfg.copyWith(maxTokens: math.max(cfg.maxTokens, prompt.maxOutputTokens)),
      prompt,
    );
  }

  Stream<String> _run(
    CancelTokenHolder holder,
    CloudLlmConfig cfg,
    LlmPrompt prompt,
  ) async* {
    final sw = Stopwatch()..start();
    // 收集器**每次 HTTP 调用一个**（usage 按次记账，避免重试后重复计数）；
    // 思考正文累加到 [lastThinking]（重试的两次思考都留着，用户想看全过程）。
    final collector = CloudStreamCollector();
    final buf = StringBuffer();
    try {
      try {
        // ⚠️ 这里必须用 `await for` + `yield`，**不能**用 `yield*`：
        // `yield*` 会把被委托流的错误**直接转给外层订阅者**，不经过本函数的
        // try/catch（实测：`yield*` 下 catch 不执行，自动加大预算的补救整个失效）。
        await for (final piece in client.stream(
          cfg: cfg,
          system: prompt.system,
          user: prompt.user,
          cancel: holder.token,
          collect: collector,
        )) {
          buf.write(piece);
          yield piece;
        }
        _afterAttempt(
          cfg,
          collector,
          buf.toString(),
          prompt,
          sw.elapsedMilliseconds,
        );
      } on CloudReasoningOnlyException catch (e) {
        // 这一次也烧了 token（思考就是 token），如实记账再决定要不要重试
        _afterAttempt(
          cfg,
          collector,
          buf.toString(),
          prompt,
          sw.elapsedMilliseconds,
        );
        // **推理模型的自动补救**（用户实测：`deepseek-v4.1-flash` 把 1024 个
        // token 全用在思考上，正文为空）。服务端把思考也算进 `max_tokens`，
        // 这时唯一需要的"兼容"就是**给足预算**。只在这三种情况下自动重试：
        //   1. 确实是被预算截断（`finish_reason=length`）；
        //   2. 还有加大空间（没到上限）；
        //   3. 用户没点"停止"。
        if (!e.truncatedByBudget ||
            cfg.maxTokens >= kCloudReasoningRetryCeiling ||
            holder.token.isCancelled) {
          rethrow;
        }
        final bigger = (cfg.maxTokens * 4).clamp(
          4096,
          kCloudReasoningRetryCeiling,
        );
        retriedBudget = bigger;
        // 告诉上层"这个模型需要更大的预算"（上层把它落库，下次就不用再浪费一次调用；
        // 每次自动重试都要多花一次钱 + 多等几秒，能记住就别重来）
        onAutoEscalate?.call(bigger);
        final retryCfg = cfg.copyWith(maxTokens: bigger);
        final retryCollector = CloudStreamCollector();
        final retryBuf = StringBuffer();
        try {
          await for (final piece in client.stream(
            cfg: retryCfg,
            system: prompt.system,
            user: prompt.user,
            cancel: holder.token,
            collect: retryCollector,
          )) {
            retryBuf.write(piece);
            yield piece;
          }
          _afterAttempt(
            retryCfg,
            retryCollector,
            retryBuf.toString(),
            prompt,
            sw.elapsedMilliseconds,
          );
        } on CloudReasoningOnlyException catch (e2) {
          _afterAttempt(
            retryCfg,
            retryCollector,
            retryBuf.toString(),
            prompt,
            sw.elapsedMilliseconds,
          );
          // 加大到上限还是"只有思考"：如实说明已经试过，别让用户以为我们没管
          throw CloudLlmException(
            currentText().aiBudgetExhausted(e2.message, cfg.maxTokens, bigger),
          );
        }
      }
    } finally {
      // 跑完/被打断都要把句柄放掉，否则下一次"停止"会掐错请求
      if (identical(_last, holder)) _last = null;
    }
  }

  /// 一次调用收尾：把思考并进 [lastThinking]、把 token 上报给设置层记账
  void _afterAttempt(
    CloudLlmConfig cfg,
    CloudStreamCollector collector,
    String text,
    LlmPrompt prompt,
    int elapsedMs,
  ) {
    if (collector.thinking.isNotEmpty) lastThinking += collector.thinking;
    // 服务端没回 usage（很多网关不回）就按字符数折算，标记 estimated
    final usage = collector.sawUsage
        ? collector.usage.sanitized()
        : estimateUsageFromText(
            promptText: '${prompt.system}\n${prompt.user}',
            completionText: text,
            reasoningChars: collector.thinkingChars,
          );
    lastUsage = usage;
    final report = onUsage;
    if (report == null) return;
    if (usage.isEmpty && text.trim().isEmpty && collector.thinking.isEmpty) {
      return;
    }
    final quote = estimateCloudCost(
      model: cfg.modelId,
      usage: usage,
      baseUrl: cfg.baseUrl,
    );
    report(
      CloudUsageRecord(
        atMs: DateTime.now().millisecondsSinceEpoch,
        usage: usage,
        profileId: cfg.profileId,
        providerId: cfg.providerId,
        model: cfg.modelId,
        protocolId: cfg.protocol.id,
        elapsedMs: elapsedMs < 0 ? 0 : elapsedMs,
        costUsd: quote.usd,
        priced: quote.priced,
        ok: text.trim().isNotEmpty,
      ),
    );
  }

  /// 上一次生成里，因为"只在思考"而自动加大到的预算（0 = 没发生过）
  ///
  /// UI 用它如实告诉用户"已经自动加大长度重试过了"，而不是默默多花一次 token。
  int retriedBudget = 0;

  /// 自动加大预算时的回调（budget = 加大到多少）
  void Function(int budget)? onAutoEscalate;

  /// 自动加大预算的上限（再大就只报错，让用户自己决定）
  static const int kCloudReasoningRetryCeiling = 16384;

  /// 用户点了"停止"：立刻掐断 HTTP（不然还在后台跑、继续烧 token）
  void cancel() {
    _last?.cancel();
    _last = null;
  }

  @override
  Future<void> dispose() async {
    cancel();
  }
}
