// 云端大模型客户端：一套代码说三种协议。
//
//   * `openai`    —— `POST {base}/chat/completions`（Bearer）+ SSE `data: {choices[0].delta.content}`
//   * `anthropic` —— `POST {base}/messages`（x-api-key + anthropic-version）+ SSE `content_block_delta`
//   * `gemini`    —— `POST {base}/models/{model}:streamGenerateContent?alt=sse&key=…` + `candidates[].content.parts[].text`
//
// 三个键的决定（都是业界通行做法，写下来免得以后自己犯嘀咕）：
//   1. **流式优先**：助手是"边出边显示"的，非流式只在"测试连接"里用。
//   2. **不猜地址**：base URL 由用户/预设给全（含版本路径），客户端只拼端点后缀；
//      用户粘了整条 `/chat/completions` 也会被 [normalizeBaseUrl] 收拾掉。
//   3. **报错说人话**：401/403/404/429/超时/证书各自有专门文案，
//      并把服务端返回的 `error.message` 尽量带出来（不然用户只能看状态码）。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import '../../core/net/traffic_meter.dart';

import '../../core/i18n/data_text.dart';
import 'cloud_pricing.dart';
import 'cloud_provider.dart';

/// 拉回来的一个模型
class CloudModelInfo {
  const CloudModelInfo({required this.id, this.label = '', this.ownedBy = ''});

  final String id;
  final String label;
  final String ownedBy;

  String get display => label.isEmpty ? id : '$label · $id';
}

/// 一次云端调用的全部配置
class CloudLlmConfig {
  const CloudLlmConfig({
    required this.protocol,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature = 0.6,
    this.maxTokens = 1024,
    this.providerId = '',
    this.profileId = '',
  });

  final CloudProtocol protocol;
  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;
  final int maxTokens;

  /// 厂商 id（统计用；请求本身不关心）
  final String providerId;

  /// 配置方案 id（统计用；多套配置并存时用来区分是哪一套花的钱）
  final String profileId;

  /// 真正发出去的模型 id：**一定要 trim**。
  /// 真机上见过输入框里带尾随空格的值，`"mock-large "` 交给真厂商就是 404
  /// （模型不存在），而错误信息会误导用户去查地址。
  String get modelId => model.trim();

  /// 能不能发请求（base URL 与模型是硬要求；key 对本地服务可以为空）
  bool get usable => normalizeBaseUrl(baseUrl).isNotEmpty && modelId.isNotEmpty;

  CloudLlmConfig copyWith({
    String? model,
    double? temperature,
    int? maxTokens,
  }) => CloudLlmConfig(
    protocol: protocol,
    baseUrl: baseUrl,
    apiKey: apiKey,
    model: model ?? this.model,
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    providerId: providerId,
    profileId: profileId,
  );

  /// 打印/日志里用：**绝不带 key**
  @override
  String toString() =>
      'CloudLlmConfig(${protocol.id}, $baseUrl, model=$model, key=${apiKey.isEmpty ? '无' : '有'})';
}

/// 调用结果（非流式，给"测试连接"用）
class CloudCompletion {
  const CloudCompletion({
    required this.text,
    this.model = '',
    this.usage = '',
    this.thinking = '',
    this.tokens = CloudTokenUsage.zero,
  });

  final String text;
  final String model;

  /// 服务端原始 usage（JSON 串，保留给诊断/日志看）
  final String usage;

  /// 推理模型返回的思考内容（Claude/Gemini 原生思考块或
  /// OpenAI 兼容的 `reasoning_content` / `reasoning`）
  final String thinking;

  /// 结构化 token 用量
  final CloudTokenUsage tokens;
}

/// 流式生成时**顺便收集**的东西：思考正文、token 用量、结束原因。
///
/// 为什么用"收集器"而不是改 [CloudLlmClient.stream] 的返回类型：
/// `Stream<String>` 已经被引擎/服务/UI 三层依赖（正文流），改成事件流会
/// 牵动一大片；而思考内容与 usage 都是**旁路信息**，用一个可选对象带出来最省事。
class CloudStreamCollector {
  final StringBuffer _thinking = StringBuffer();

  CloudTokenUsage _usage = CloudTokenUsage.zero;
  bool _sawUsage = false;
  String finishReason = '';
  bool truncated = false;

  /// 累计的思考内容（多次尝试会自动拼接）
  String get thinking => _thinking.toString();

  int get thinkingChars => _thinking.length;

  bool get sawReasoning => _thinking.isNotEmpty;

  /// 服务端回的 token 用量（没回就是 [CloudTokenUsage.zero]，`sawUsage == false`）
  CloudTokenUsage get usage => _usage;

  /// 服务端到底有没有回 usage（决定要不要按字符数折算）
  bool get sawUsage => _sawUsage;

  void addThinking(String piece) {
    if (piece.isEmpty) return;
    _thinking.write(piece);
  }

  void mergeUsage(CloudTokenUsage one) {
    final u = one.sanitized();
    if (u.isEmpty) return;
    _sawUsage = true;
    final cur = _usage;
    // 两种服务端都可能出现：
    //   * **增量**（OpenAI 最后一帧、Anthropic 把 input/output 拆两帧）→ 相加；
    //   * **累计快照**（Gemini 流式可能每帧给到目前为止的总数）→ 替换，否则会加两遍。
    // 判据：新值各项都不小于旧值、且至少有一项变大 → 当成快照。
    final grew =
        u.promptTokens > cur.promptTokens ||
        u.completionTokens > cur.completionTokens ||
        u.totalTokens > cur.totalTokens;
    final notSmaller =
        u.promptTokens >= cur.promptTokens &&
        u.completionTokens >= cur.completionTokens &&
        u.totalTokens >= cur.totalTokens;
    _usage = (grew && notSmaller) ? u : cur + u;
  }

  void noteFinishReason(String reason) {
    if (reason.isEmpty) return;
    finishReason = reason;
    if (reason == 'length' || reason == 'max_tokens') truncated = true;
  }
}

class CloudLlmClient {
  CloudLlmClient({Dio? dio})
    : _dio = tagDioWithModule(
        dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                // 大模型"想"得久，接收超时给宽一点；真正的卡死靠取消按钮兜
                receiveTimeout: const Duration(seconds: 120),
                sendTimeout: const Duration(seconds: 30),
                // 4xx/5xx 我们自己解析 body，不抛成 DioException 的兜底路径
                validateStatus: (_) => true,
              ),
            ),
        TrafficModules.ai,
      );

  final Dio _dio;

  static const String kAnthropicVersion = '2023-06-01';

  // ---------------------------------------------------------------- 流式生成

  /// 逐段吐文本；出错抛 [CloudLlmException]（带好文案）
  ///
  /// [collect] 是**旁路收集器**：思考正文、token 用量、finish_reason 都会
  /// 写进去（用于「思考内容折叠展示」与「token/费用统计」）。
  Stream<String> stream({
    required CloudLlmConfig cfg,
    required String system,
    required String user,
    CancelToken? cancel,
    CloudStreamCollector? collect,
  }) {
    final base = normalizeBaseUrl(cfg.baseUrl);
    return switch (cfg.protocol) {
      CloudProtocol.openai => _sse(
        cfg: cfg,
        method: 'POST',
        url: '$base/chat/completions',
        // ⚠️ 这里不做"一次定型"的 body：**有的模型不认 `max_tokens`/`temperature`**
        // （推理模型常见：o 系列、部分 DeepSeek 兼容网关会 400
        // "Unsupported parameter"）。所以给出**候选 body 序列**，
        // `_sse` 遇到"参数类 400"就自动换下一个再试（见 `_isParamError`）。
        bodies: [
          {
            'model': cfg.modelId,
            'messages': [
              if (system.trim().isNotEmpty)
                {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
            'stream': true,
            'temperature': cfg.temperature,
            'max_tokens': cfg.maxTokens,
            // 让 OpenAI 官方在流式最后一帧带上 usage（不带就按字符数估算，
            // 统计里会标「估算」）。有的网关不认这个字段 → 会被参数重试丢掉。
            'stream_options': {'include_usage': true},
          },
          // 新接口名（OpenAI 官方已把 max_tokens 换成 max_completion_tokens）
          {
            'model': cfg.modelId,
            'messages': [
              if (system.trim().isNotEmpty)
                {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
            'stream': true,
            'temperature': cfg.temperature,
            'max_completion_tokens': cfg.maxTokens,
          },
          // 连 temperature 都不认的（部分推理模型只接受默认温度）
          {
            'model': cfg.modelId,
            'messages': [
              if (system.trim().isNotEmpty)
                {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
            'stream': true,
            'max_completion_tokens': cfg.maxTokens,
          },
        ],
        cancel: cancel,
        pickDelta: _openAiDelta,
        collect: collect,
      ),
      CloudProtocol.anthropic => _sse(
        cfg: cfg,
        method: 'POST',
        url: '$base/messages',
        headers: _anthropicHeaders(cfg),
        bodies: [
          {
            'model': cfg.modelId,
            'max_tokens': cfg.maxTokens,
            'system': system,
            'messages': [
              {'role': 'user', 'content': user},
            ],
            'stream': true,
            'temperature': cfg.temperature,
          },
        ],
        cancel: cancel,
        pickDelta: _anthropicDelta,
        collect: collect,
      ),
      CloudProtocol.gemini => _sse(
        cfg: cfg,
        method: 'POST',
        url:
            '$base/models/${Uri.encodeComponent(cfg.modelId)}'
            ':streamGenerateContent?alt=sse&key=${Uri.encodeQueryComponent(cfg.apiKey)}',
        bodies: [
          {
            if (system.trim().isNotEmpty)
              'systemInstruction': {
                'parts': [
                  {'text': system},
                ],
              },
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': user},
                ],
              },
            ],
            'generationConfig': {
              'temperature': cfg.temperature,
              'maxOutputTokens': cfg.maxTokens,
            },
          },
        ],
        cancel: cancel,
        pickDelta: _geminiDelta,
        collect: collect,
      ),
    };
  }

  /// 非流式一次问完（"测试连接"用；也方便将来做"标题生成"这类短任务）
  Future<CloudCompletion> complete({
    required CloudLlmConfig cfg,
    String? system,
    String? user,
    CancelToken? cancel,
  }) async {
    // 默认提示语走数据层文案（可中英切换）；显式传参的调用方不受影响
    final sys = system ?? dataText('aiCompleteSystemDefault', '你是简洁的助手。');
    final usr = user ?? dataText('aiCompleteUserDefault', '只回三个字：连接成功');
    final base = normalizeBaseUrl(cfg.baseUrl);
    final (url, body, headers) = switch (cfg.protocol) {
      CloudProtocol.openai => (
        '$base/chat/completions',
        {
          'model': cfg.modelId,
          'messages': [
            if (sys.trim().isNotEmpty) {'role': 'system', 'content': sys},
            {'role': 'user', 'content': usr},
          ],
          'temperature': cfg.temperature,
          'max_tokens': 64,
        },
        _headers(cfg),
      ),
      CloudProtocol.anthropic => (
        '$base/messages',
        {
          'model': cfg.modelId,
          'max_tokens': 64,
          'system': sys,
          'messages': [
            {'role': 'user', 'content': usr},
          ],
        },
        {..._headers(cfg), ..._anthropicHeaders(cfg)},
      ),
      CloudProtocol.gemini => (
        '$base/models/${Uri.encodeComponent(cfg.modelId)}'
            ':generateContent?key=${Uri.encodeQueryComponent(cfg.apiKey)}',
        {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': usr},
              ],
            },
          ],
          'generationConfig': {'maxOutputTokens': 64},
        },
        _headers(cfg),
      ),
    };
    final res = await _send(
      method: 'POST',
      url: url,
      body: body,
      headers: headers,
      cancel: cancel,
    );
    final data = _asMap(res.data);
    final text = switch (cfg.protocol) {
      CloudProtocol.openai => _openAiText(data),
      CloudProtocol.anthropic => _anthropicText(data),
      CloudProtocol.gemini => _geminiText(data),
    };
    // OpenAI/Anthropic 用 `usage`；Gemini 用 `usageMetadata`
    final usageRaw = data['usage'] ?? data['usageMetadata'];
    return CloudCompletion(
      text: text,
      model: '${data['model'] ?? cfg.modelId}',
      usage: usageRaw == null ? '' : jsonEncode(usageRaw),
      thinking: _nonStreamThinking(data, cfg.protocol),
      tokens: cloudUsageFromJson(usageRaw),
    );
  }

  // ---------------------------------------------------------------- 模型列表

  /// 拉模型列表。**没有这个接口的厂商**（或权限不够）会抛异常，
  /// 由 UI 退化成"手填模型 id + 常见模型建议"。
  Future<List<CloudModelInfo>> models({
    required CloudLlmConfig cfg,
    CancelToken? cancel,
  }) async {
    final base = normalizeBaseUrl(cfg.baseUrl);
    final (url, headers) = switch (cfg.protocol) {
      CloudProtocol.openai => ('$base/models', _headers(cfg)),
      CloudProtocol.anthropic => (
        '$base/models?limit=100',
        {..._headers(cfg), ..._anthropicHeaders(cfg)},
      ),
      CloudProtocol.gemini => (
        '$base/models?pageSize=200&key=${Uri.encodeQueryComponent(cfg.apiKey)}',
        _headers(cfg),
      ),
    };
    final res = await _send(
      method: 'GET',
      url: url,
      headers: headers,
      cancel: cancel,
      // 列表接口不该等太久，等不到就让用户手填
      timeout: const Duration(seconds: 20),
    );
    final data = _asMap(res.data);
    final raw = switch (cfg.protocol) {
      CloudProtocol.gemini => data['models'],
      _ => data['data'] ?? data['models'],
    };
    final out = <CloudModelInfo>[];
    if (raw is List) {
      for (final one in raw) {
        final m = _asMap(one);
        var id = '${m['id'] ?? m['name'] ?? m['model'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        // Gemini 回来的是 `models/gemini-2.0-flash`
        if (cfg.protocol == CloudProtocol.gemini && id.startsWith('models/')) {
          id = id.substring('models/'.length);
        }
        out.add(
          CloudModelInfo(
            id: id,
            label: '${m['display_name'] ?? m['displayName'] ?? ''}',
            ownedBy: '${m['owned_by'] ?? m['ownedBy'] ?? ''}',
          ),
        );
      }
    }
    out.sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    return out;
  }

  // ---------------------------------------------------------------- 内部实现

  Map<String, String> _headers(CloudLlmConfig cfg) => {
    'Content-Type': 'application/json',
    // 本地/自建服务（Ollama、vLLM）的 OpenAI 兼容层要求**有这个头**但会忽略取值，
    // 所以没填 key 时补一个占位值 —— 比完全不发更兼容（实测坑）。
    'Authorization':
        'Bearer ${cfg.apiKey.trim().isEmpty ? 'not-needed' : cfg.apiKey.trim()}',
  };

  Map<String, String> _anthropicHeaders(CloudLlmConfig cfg) => {
    if (cfg.apiKey.trim().isNotEmpty) 'x-api-key': cfg.apiKey.trim(),
    'anthropic-version': kAnthropicVersion,
  };

  Future<Response<dynamic>> _send({
    required String method,
    required String url,
    Object? body,
    Map<String, String>? headers,
    CancelToken? cancel,
    Duration? timeout,
  }) async {
    try {
      final res = await _dio.request<dynamic>(
        url,
        data: body == null ? null : jsonEncode(body),
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain,
          receiveTimeout: timeout,
        ),
        cancelToken: cancel,
      );
      final code = res.statusCode ?? 0;
      if (code < 200 || code >= 300) {
        throw CloudLlmException(describeHttpError(code, res.data, url: url));
      }
      final raw = res.data;
      if (raw is String) {
        return Response<dynamic>(
          data: jsonDecode(raw),
          statusCode: code,
          requestOptions: res.requestOptions,
        );
      }
      return res;
    } on CloudLlmException {
      rethrow;
    } on DioException catch (e) {
      throw CloudLlmException(describeDioError(e));
    } on FormatException catch (e) {
      // 拿回来的不是 JSON（例如网页/网关错误页）
      throw CloudLlmException(
        dataText(
          'aiErrNotJson',
          '服务端返回的不是 JSON（可能被网关或登录页拦截了）：{error}',
        ).replaceAll('{error}', '$e'),
      );
    }
  }

  /// SSE：一行行收，凑齐 `data:` 再解析
  Stream<String> _sse({
    required CloudLlmConfig cfg,
    required String method,
    required String url,
    required List<Map<String, dynamic>> bodies,
    required String Function(Map<String, dynamic>) pickDelta,
    Map<String, String>? headers,
    CancelToken? cancel,
    CloudStreamCollector? collect,
  }) async* {
    final h = {..._headers(cfg), ...?headers};
    Response<ResponseBody> res;
    // 参数兼容重试：从第一个 body 开始，遇到"参数类 400"就换下一个
    var lastError = '';
    var attempt = 0;
    while (true) {
      final body = bodies[attempt];
      try {
        res = await _dio.request<ResponseBody>(
          url,
          data: jsonEncode(body),
          options: Options(
            method: method,
            headers: h,
            responseType: ResponseType.stream,
          ),
          cancelToken: cancel,
        );
      } on DioException catch (e) {
        throw CloudLlmException(describeDioError(e));
      }
      final attemptCode = res.statusCode ?? 0;
      if (attemptCode >= 200 && attemptCode < 300) break;
      final errBody = await _drain(res.data?.stream);
      lastError = describeHttpError(attemptCode, errBody, url: url);
      // 只有"参数不被支持"这一类才值得换 body 重试；401/404/429 重试没意义
      if (attemptCode == 400 &&
          attempt + 1 < bodies.length &&
          _isParamError(errBody)) {
        attempt++;
        continue;
      }
      throw CloudLlmException(lastError);
    }
    final code = res.statusCode ?? 0;
    final stream = res.data?.stream;
    if (code < 200 || code >= 300) {
      // 错误体也是（可能是）JSON，读出来给用户看
      final body = await _drain(stream);
      throw CloudLlmException(describeHttpError(code, body, url: url));
    }
    if (stream == null) {
      throw CloudLlmException(
        dataText('aiErrNoStream', '服务端没有返回内容（可能这个模型不支持流式）'),
      );
    }

    final lines = utf8.decoder.bind(stream).transform(const LineSplitter());
    var sawAny = false;
    // 有的网关**无视 `stream:true`**，直接回一整段 JSON（非 SSE）→ 一个 `data:` 行
    // 都没有。以前这种会被静默丢掉（sawAny=false 且 errorBuf 为空）→ 用户看到
    // "什么都没发生"。所以要把非 SSE 的 body 攒起来，最后按各协议的
    // **非流式形状**兜底解析一次。
    final rawBuf = StringBuffer();
    final errorBuf = StringBuffer();
    var truncated = false;
    var finishReason = '';
    // 思考内容：**本地也记一份**（没传 collect 时不能连"只出思考"都判断不出来）
    var sawReasoning = false;
    var reasoningChars = 0;
    // 有没有**任何** `data:` 行（含 `[DONE]`）。用来区分两种"空回答"：
    //   * 一个 data 行都没有 → 网关根本没按 SSE 说话（要报错）
    //   * 有 data 行但没正文 → 模型真的没给内容（交给 UI 说人话，不算传输错误）
    var sawData = false;
    await for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith(':')) continue;
      // `event: xxx` 我们不看（Anthropic 的增量只看 data 里的 type 字段）
      if (!t.startsWith('data:')) {
        // 非 SSE 的正文（整段 JSON）：留着兜底
        if (rawBuf.length < 200000) rawBuf.writeln(line);
        continue;
      }
      final payload = t.substring(5).trim();
      sawData = true;
      if (payload == '[DONE]') break;
      Map<String, dynamic> json;
      try {
        json = _asMap(jsonDecode(payload));
      } catch (_) {
        // 半截/心跳行：跳过，但也留进兜底缓冲（可能是"整段 JSON 被拆成几行"）
        if (rawBuf.length < 200000) rawBuf.writeln(payload);
        continue;
      }
      // 协议内联错误（Anthropic 用 `{"type":"error",...}`）
      if ('${json['type']}' == 'error' || json['error'] != null) {
        errorBuf.write(_errorText(json) ?? payload);
        continue;
      }
      final reason = _finishReason(json);
      if (reason.isNotEmpty) finishReason = reason;
      if (reason == 'length' || reason == 'max_tokens') truncated = true;
      // **思考内容**：以前只数字数（诊断用），现在把正文也收进收集器，
      // 让 UI 能折叠展示（Claude/Gemini 原生思考块 + OpenAI 兼容的
      // `reasoning_content` / `reasoning` 都认）。
      final thinking = _reasoningText(json);
      if (thinking.isNotEmpty) {
        sawReasoning = true;
        reasoningChars += thinking.length;
        collect?.addThinking(thinking);
      }
      // **token 用量**：有的在最后一帧（OpenAI + stream_options），
      // Anthropic 在 message_start/message_delta，Gemini 每帧都带 usageMetadata。
      final usage = _usageOf(json);
      if (usage != null) collect?.mergeUsage(usage);
      final delta = pickDelta(json);
      if (delta.isNotEmpty) {
        sawAny = true;
        yield delta;
      }
    }
    if (collect != null) {
      collect.noteFinishReason(finishReason);
      if (truncated) collect.truncated = true;
    }
    if (!sawAny && errorBuf.isNotEmpty) {
      throw CloudLlmException(
        dataText(
          'aiErrModelError',
          '模型返回了错误：{message}',
        ).replaceAll('{message}', errorBuf.toString().trim()),
      );
    }
    if (!sawAny) {
      // 非 SSE 兜底：把整段 body 当非流式回包解析
      final raw = rawBuf.toString();
      final fallback = _nonStreamText(raw, cfg.protocol);
      if (fallback.isNotEmpty) {
        sawAny = true;
        yield fallback;
      }
      // 非流式回包里也可能带思考和 usage —— 一起收走
      final map = _nonStreamMap(raw);
      if (map.isNotEmpty) {
        final thinking = _nonStreamThinking(map, cfg.protocol);
        if (thinking.isNotEmpty) {
          sawReasoning = true;
          reasoningChars += thinking.length;
          collect?.addThinking(thinking);
        }
        final usage = _usageOf(map);
        if (usage != null) collect?.mergeUsage(usage);
      }
    }
    if (!sawAny && sawReasoning) {
      // **推理模型的典型坑**：token 全花在 reasoning 上，正文一个字都没出。
      // 以前这里静默结束 → UI 看着像"没反应"，用户以为模型不兼容。
      // 抛专用异常，让引擎层能"加大预算自动重试一次"（见 CloudReasoningOnlyException）。
      throw CloudReasoningOnlyException(
        reasoningChars: reasoningChars,
        finishReason: finishReason,
        budget: cfg.maxTokens,
      );
    }
    if (!sawAny && !sawData) {
      throw CloudLlmException(
        dataText('aiErrNoContent', '模型没有返回任何内容（网关可能忽略了流式请求；换个模型或检查地址）'),
      );
    }
    // 走到这里说明"有 SSE 但没有正文"：不报错（有些模型确实回空），
    // UI 会显示"模型没有给出内容"并给出下一步建议
    if (truncated) {
      // 有正文但被长度上限截断：明确告诉用户，别让他以为模型"答一半坏了"
      yield dataText(
        'aiTruncatedNote',
        '\n\n（回答已达长度上限被截断，可在「AI 服务 → 高级参数」调大最大长度）',
      );
    }
  }

  /// 一帧里的 usage（没有就返回 null）
  static CloudTokenUsage? _usageOf(Map<String, dynamic> json) {
    // Anthropic 的 `message_start` 把 usage 放在 `message.usage` 里
    final raw =
        json['usage'] ??
        json['usageMetadata'] ??
        _asMap(json['message'])['usage'];
    if (raw == null) return null;
    final u = cloudUsageFromJson(raw);
    return u.isEmpty ? null : u;
  }

  /// 非 SSE 整段 body → Map（解析不了返回空 Map）
  static Map<String, dynamic> _nonStreamMap(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const {};
    try {
      return _asMap(jsonDecode(trimmed));
    } catch (_) {
      try {
        return _asMap(jsonDecode(trimmed.replaceAll(RegExp(r'\s+'), '')));
      } catch (_) {
        return const {};
      }
    }
  }

  /// 非 SSE（整段 JSON）兜底解析：按三种协议各自的非流式形状取正文
  static String _nonStreamText(String raw, CloudProtocol protocol) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    // 可能被拆成多行（SSE 网关把 JSON 一行行写），先把行拼起来再解析
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      try {
        decoded = jsonDecode(trimmed.replaceAll(RegExp(r'\s+'), ''));
      } catch (_) {
        return '';
      }
    }
    final map = _asMap(decoded);
    if (map.isEmpty) return '';
    switch (protocol) {
      case CloudProtocol.openai:
        final choices = map['choices'];
        if (choices is List && choices.isNotEmpty) {
          final msg = _asMap(_asMap(choices.first)['message']);
          final content = msg['content'];
          if (content is String) return content;
          if (content is List) {
            final buf = StringBuffer();
            for (final p in content) {
              final m = _asMap(p);
              if (m['text'] is String) buf.write(m['text']);
            }
            return buf.toString();
          }
        }
        return '';
      case CloudProtocol.anthropic:
        final content = map['content'];
        if (content is List) {
          final buf = StringBuffer();
          for (final p in content) {
            final m = _asMap(p);
            if (m['text'] is String) buf.write(m['text']);
          }
          return buf.toString();
        }
        return '';
      case CloudProtocol.gemini:
        final candidates = map['candidates'];
        if (candidates is List && candidates.isNotEmpty) {
          final parts = _asMap(
            _asMap(_asMap(candidates.first)['content']),
          )['parts'];
          if (parts is List) {
            final buf = StringBuffer();
            for (final p in parts) {
              final m = _asMap(p);
              // 思考块不进正文（与流式 `_geminiDelta` 同一口径）
              if (m['thought'] == true) continue;
              if (m['text'] is String) buf.write(m['text']);
            }
            return buf.toString();
          }
        }
        return '';
    }
  }

  /// 这一帧里的**思考内容正文**（空串表示这一帧没有思考内容）
  ///
  /// 字段名各家不一样：DeepSeek/中转用 `reasoning_content`，用户实测的
  /// 中转（one-api + vLLM，模型 `deepseek-v4.1-flash`）用的是 `reasoning`；
  /// Anthropic 是 thinking block，Gemini 是 `thought: true` 的 part。
  static String _reasoningText(Map<String, dynamic> json) {
    final buf = StringBuffer();
    final choices = json['choices'];
    if (choices is List && choices.isNotEmpty) {
      final delta = _asMap(_asMap(choices.first)['delta']);
      for (final k in const [
        'reasoning_content',
        'reasoning',
        'thinking',
        'reasoning_details',
      ]) {
        final v = delta[k];
        if (v is String) {
          buf.write(v);
        } else if (v is List) {
          for (final item in v) {
            final m = _asMap(item);
            final t = m['text'] ?? m['content'];
            if (t is String) buf.write(t);
          }
        } else if (v is Map) {
          final t = _asMap(v)['text'];
          if (t is String) buf.write(t);
        }
      }
    }
    if ('${json['type']}' == 'content_block_delta') {
      final d = _asMap(json['delta']);
      // Anthropic：`{"type":"thinking_delta","thinking":"…"}`
      // （`signature_delta` 是校验串，不能当思考正文）
      if ('${d['type']}'.contains('thinking') && d['thinking'] is String) {
        buf.write('${d['thinking']}');
      }
    }
    final candidates = json['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final parts = _asMap(
        _asMap(_asMap(candidates.first)['content']),
      )['parts'];
      if (parts is List) {
        for (final p in parts) {
          final m = _asMap(p);
          if (m['thought'] == true && m['text'] is String) {
            buf.write('${m['text']}');
          }
        }
      }
    }
    return buf.toString();
  }

  /// 非流式回包里的思考内容（整段 JSON 兜底路径用）
  static String _nonStreamThinking(
    Map<String, dynamic> data,
    CloudProtocol protocol,
  ) {
    final buf = StringBuffer();
    switch (protocol) {
      case CloudProtocol.openai:
        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty) {
          final msg = _asMap(_asMap(choices.first)['message']);
          for (final k in const [
            'reasoning_content',
            'reasoning',
            'thinking',
            'reasoning_details',
          ]) {
            final v = msg[k];
            if (v is String) {
              buf.write(v);
            } else if (v is List) {
              for (final item in v) {
                final t = _asMap(item)['text'];
                if (t is String) buf.write(t);
              }
            }
          }
        }
      case CloudProtocol.anthropic:
        final content = data['content'];
        if (content is List) {
          for (final p in content) {
            final m = _asMap(p);
            if ('${m['type']}'.contains('thinking') &&
                m['thinking'] is String) {
              buf.write('${m['thinking']}');
            }
          }
        }
      case CloudProtocol.gemini:
        final candidates = data['candidates'];
        if (candidates is List && candidates.isNotEmpty) {
          final parts = _asMap(
            _asMap(_asMap(candidates.first)['content']),
          )['parts'];
          if (parts is List) {
            for (final p in parts) {
              final m = _asMap(p);
              if (m['thought'] == true && m['text'] is String) {
                buf.write('${m['text']}');
              }
            }
          }
        }
    }
    return buf.toString();
  }

  /// 取 `finish_reason` / `stop_reason`（三种协议的字段名都在这）
  static String _finishReason(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is List && choices.isNotEmpty) {
      final r = _asMap(choices.first)['finish_reason'];
      if (r is String) return r;
    }
    final sr = json['stop_reason'];
    if (sr is String) return sr;
    // Anthropic 把 stop_reason 放在 `message_delta.delta` 里
    final d = _asMap(json['delta']);
    if (d['stop_reason'] is String) return '${d['stop_reason']}';
    final candidates = json['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final r = _asMap(candidates.first)['finishReason'];
      if (r is String) return r;
    }
    return '';
  }

  /// 这个 400 是不是"参数不被支持"（只有这种才值得换 body 重试）
  static bool _isParamError(String body) {
    final t = body.toLowerCase();
    return t.contains('max_tokens') ||
        t.contains('max_completion_tokens') ||
        t.contains('temperature') ||
        // `stream_options`/`include_usage` 也有网关不认 —— 换了 body 就好了
        // （候选 body 序列里第一个带它、后面两个不带）
        t.contains('stream_options') ||
        t.contains('stream options') ||
        t.contains('include_usage') ||
        t.contains('unsupported parameter') ||
        t.contains('unknown parameter') ||
        t.contains('unknown field') ||
        t.contains('unrecognized');
  }

  Future<String> _drain(Stream<List<int>>? stream) async {
    if (stream == null) return '';
    final buf = StringBuffer();
    await for (final chunk in utf8.decoder.bind(stream)) {
      buf.write(chunk);
      if (buf.length > 4000) {
        break; // 错误页别读太多
      }
    }
    return buf.toString();
  }

  // --- 三种协议的增量字段 ---

  static String _openAiDelta(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is List && choices.isNotEmpty) {
      final c = _asMap(choices.first);
      final delta = _asMap(c['delta']);
      final piece = delta['content'] ?? c['text'];
      if (piece is String) return piece;
      // 有的网关把 content 给成数组（多模态分片）
      if (piece is List) {
        final buf = StringBuffer();
        for (final p in piece) {
          final m = _asMap(p);
          if (m['text'] is String) buf.write(m['text']);
        }
        return buf.toString();
      }
    }
    return '';
  }

  static String _anthropicDelta(Map<String, dynamic> json) {
    if ('${json['type']}' == 'content_block_delta') {
      final d = _asMap(json['delta']);
      final t = d['text'];
      if (t is String) return t;
    }
    return '';
  }

  static String _geminiDelta(Map<String, dynamic> json) {
    final cands = json['candidates'];
    if (cands is List && cands.isNotEmpty) {
      final parts = _asMap(_asMap(cands.first)['content'])['parts'];
      if (parts is List) {
        final buf = StringBuffer();
        for (final p in parts) {
          final m = _asMap(p);
          // ⚠️ `thought: true` 是 Gemini 的思考块：**不能当正文渲染**
          // （正文走 pickDelta，思考走 collect.thinking / 折叠区）
          if (m['thought'] == true) continue;
          final t = m['text'];
          if (t is String) buf.write(t);
        }
        return buf.toString();
      }
    }
    return '';
  }

  static String _openAiText(Map<String, dynamic> data) {
    final choices = data['choices'];
    if (choices is List && choices.isNotEmpty) {
      final c = _asMap(choices.first);
      final msg = _asMap(c['message']);
      final t = msg['content'] ?? c['text'];
      if (t is String) return t;
    }
    return '';
  }

  static String _anthropicText(Map<String, dynamic> data) {
    final content = data['content'];
    if (content is List) {
      final buf = StringBuffer();
      for (final p in content) {
        final t = _asMap(p)['text'];
        if (t is String) buf.write(t);
      }
      return buf.toString();
    }
    return '';
  }

  static String _geminiText(Map<String, dynamic> data) {
    final cands = data['candidates'];
    if (cands is List && cands.isNotEmpty) {
      final parts = _asMap(_asMap(cands.first)['content'])['parts'];
      if (parts is List) {
        final buf = StringBuffer();
        for (final p in parts) {
          final t = _asMap(p)['text'];
          if (t is String) buf.write(t);
        }
        return buf.toString();
      }
    }
    return '';
  }

  static Map<String, dynamic> _asMap(Object? o) {
    if (o is Map) return o.map((k, v) => MapEntry('$k', v));
    return const {};
  }

  static String? _errorText(Map<String, dynamic> json) {
    final err = json['error'];
    if (err is String) return err;
    final m = _asMap(err);
    for (final k in const ['message', 'msg', 'type', 'code']) {
      final v = m[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }
}

/// 取消句柄：引擎层不用认识 dio，也能把正在跑的请求掐掉
class CancelTokenHolder {
  final CancelToken _token = CancelToken();

  CancelToken get token => _token;

  bool get isCancelled => _token.isCancelled;

  void cancel([String? reason]) {
    if (!_token.isCancelled) {
      _token.cancel(reason ?? dataText('aiCancelReason', '用户取消'));
    }
  }
}

class CloudLlmException implements Exception {
  CloudLlmException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 模型把预算全花在思考上、**正文一个字都没有**。
///
/// 真机实测（用户配置的中转 + `deepseek-v4.1-flash`）：同一段 60 字的原文，
/// 系统提示里要求"每条不超过 40 字"时，模型用了整整 1024 个 reasoning token
/// 还没开始写正文 —— 服务端把思考也算进 `max_tokens`，于是
/// `finish_reason=length`、`content` 为空。这不是网络问题，也不是模型不兼容，
/// **只需要更大的预算**；所以引擎层拿到这个异常会自动加大长度重试一次。
class CloudReasoningOnlyException extends CloudLlmException {
  CloudReasoningOnlyException({
    required this.reasoningChars,
    required this.finishReason,
    required this.budget,
  }) : super(
         _isBudgetCut(finishReason)
             // 被预算截断：最需要的就是"给足预算"，文案要说得能对症下药
             ? dataText(
                     'aiReasoningOnlyBudget',
                     // ★ r343 D52：原文案把服务端字段名与取值印给用户
                     // （`finish_reason=length`）。{chars} 是用户能理解的量，
                     // {reason} 是协议枚举 ⇒ 只留前者；后者仍在日志/诊断里。
                     '模型把 {budget} token 全用在思考上，没写出正文'
                         '（收到 {chars} 字思考内容）',
                   )
                   .replaceAll('{budget}', '$budget')
                   .replaceAll('{chars}', '$reasoningChars')
             // 没被截断却只有思考：多半这个模型就不爱直接出正文，换模型更实际
             : dataText(
                 'aiReasoningOnlyPlain',
                 '模型只回了思考过程，没有正文（收到 {chars} 字思考内容）',
               ).replaceAll('{chars}', '$reasoningChars'),
       );

  /// 收到的思考内容字符数（文案里如实报；思考正文另走可折叠 UI）
  final int reasoningChars;

  /// 服务端给的 `finish_reason`（推理被预算截断时是 `length`）
  final String finishReason;

  /// 这次请求允许的输出 token 上限
  final int budget;

  static bool _isBudgetCut(String reason) =>
      reason == 'length' || reason == 'max_tokens';

  /// 是否"被预算截断"—— 只有这种加大预算才可能救回来
  bool get truncatedByBudget => _isBudgetCut(finishReason);
}

/// HTTP 状态码 → 人话（并把服务端给的 message 带出来）
///
/// 文案走数据层 key + 中文原文（批次 2d），参数用 `{tail}` / `{code}` / `{url}`
/// 模板填值。没装翻译器时与老版本文案**逐字一致**（老断言因此不用改）。
String describeHttpError(int code, Object? body, {String url = ''}) {
  final server = _serverMessage(body);
  final tail = server.isEmpty ? '' : '：$server';
  String fill(String key, String zh, {String extra = ''}) => dataText(key, zh)
      .replaceAll('{tail}', tail)
      .replaceAll('{code}', '$code')
      .replaceAll('{url}', extra);
  return switch (code) {
    400 => fill('aiErrRequestRejected', '请求被拒绝（400）{tail}'),
    401 => fill('aiErrKeyInvalid', 'API Key 无效或已过期（401）{tail}'),
    402 => fill('aiErrInsufficientBalance', '余额不足（402）{tail}'),
    403 => fill('aiErrNoPermission', '没有权限或被区域限制（403）{tail}'),
    404 => fill(
      'aiErrNotFound',
      '地址或模型不存在（404）{tail} —— 检查 base URL 与模型 id{url}',
      extra: url.isEmpty ? '' : '（请求：$url）',
    ),
    413 => fill('aiErrBodyTooLarge', '请求体太大（413）{tail}'),
    422 => fill('aiErrParamsRejected', '参数不被接受（422）{tail}'),
    429 => fill('aiErrRateLimited', '触发限流或额度用尽（429），等一会儿再试{tail}'),
    >= 500 => fill('aiErrServer', '服务端错误（{code}）{tail}'),
    _ => fill('aiErrRequestFailed', '请求失败（{code}）{tail}'),
  };
}

String _serverMessage(Object? body) {
  if (body == null) return '';
  Object? parsed = body;
  if (body is String) {
    final t = body.trim();
    if (t.isEmpty) return '';
    try {
      parsed = jsonDecode(t);
    } catch (_) {
      // 不是 JSON：多半是网关/HTML 错误页，只留一小段
      return t.length > 160 ? '${t.substring(0, 160)}…' : t;
    }
  }
  if (parsed is Map) {
    final m = parsed.map((k, v) => MapEntry('$k', v));
    final direct = CloudLlmClient._errorText(m);
    if (direct != null) return direct;
    final msg = m['message'] ?? m['msg'] ?? m['detail'];
    if (msg is String) return msg;
  }
  return '';
}

/// 网络层异常 → 人话
String describeDioError(DioException e) {
  final host = e.requestOptions.uri.host;
  final isLocal =
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host.startsWith('192.168.') ||
      host.startsWith('10.') ||
      host == '0.0.0.0';
  String at(String key, String zh) =>
      dataText(key, zh).replaceAll('{host}', host);
  return switch (e.type) {
    DioExceptionType.connectionTimeout || DioExceptionType.sendTimeout => at(
      'aiErrConnectTimeout',
      '连接超时：连不上 {host}（检查网络、代理或地址）',
    ),
    DioExceptionType.receiveTimeout => dataText(
      'aiErrWaitTimeout',
      '等待响应超时：模型太久没回数据（可以换个更快的模型）',
    ),
    DioExceptionType.badCertificate => dataText(
      'aiErrBadCertificate',
      '证书校验失败（自签名证书需要信任后才能连）',
    ),
    DioExceptionType.cancel => dataText('aiErrCancelled', '已取消'),
    DioExceptionType.connectionError =>
      isLocal
          ? at(
              'aiErrLocalService',
              '连不上 {host}：如果这是本机服务，手机要填电脑/服务器的**局域网 IP**，'
                  '不能用 localhost',
            )
          : at('aiErrUnreachable', '连不上 {host}：网络不通或被拦截（国内直连国外服务通常需要代理）'),
    // 兜底也要带出底层原因（SocketException/HttpException），
    // 不然用户只看到"unknown" —— 这个错我们真踩过
    _ => dataText(
      'aiErrUnknown',
      '请求出错：{error}',
    ).replaceAll('{error}', '${e.error ?? e.message ?? e.type.name}'),
  };
}

/// 由 [CloudLlmClient] 把 HTTP 层错误换成这个（UI 只认它）
String describeCloudError(Object error) {
  if (error is CloudLlmException) return error.message;
  if (error is DioException) return describeDioError(error);
  return '$error';
}
