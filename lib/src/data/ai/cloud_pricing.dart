// 云端调用的 **token 用量与费用估算**（纯 Dart，数据层）。
//
// 三条立场（写下来免得以后自欺）：
//   1. **这是本机估算，不是服务商账单。** token 数优先取服务端回的 `usage`；
//      服务端没回时按字符数折算（标 `estimated`）。费用按内置单价表折算。
//      界面必须把这句话原样告诉用户。
//   2. **单价表会过期。** 各家调价很频繁，这里只收"公开列表价"里比较确定的一批，
//      认不出的模型一律**不计价**（`priced=false`），界面显示"单价未知"，
//      绝不拿一个猜的数字冒充费用。
//   3. **负数/缺字段不能把统计弄脏。** 所有 token 数先钳到 >= 0；
//      total 缺失或不小于组成项时按组成项重算。
//
// 与 `data_text.dart` 同一约束：**纯 Dart，不许 import flutter**。
import 'dart:convert';

/// 单价表的更新时间（只作展示；调价后要人工回来改这张表）
const String kCloudPricingUpdatedAt = '2026-09';

/// 一次调用的 token 用量
class CloudTokenUsage {
  const CloudTokenUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.reasoningTokens = 0,
    this.estimated = false,
  });

  final int promptTokens;
  final int completionTokens;

  /// 服务端给的总数；各协议有的给、有的不给（缺的时候下面会重算）
  final int totalTokens;

  /// 思考（reasoning）token：只有部分协议/网关会单独报
  final int reasoningTokens;

  /// token 数是不是**按字符数折算**出来的（服务端没回 usage）
  final bool estimated;

  static const CloudTokenUsage zero = CloudTokenUsage();

  /// 规整：负数钳成 0，total 缺失/过小时按输入+输出补上
  CloudTokenUsage sanitized() {
    final p = promptTokens < 0 ? 0 : promptTokens;
    final c = completionTokens < 0 ? 0 : completionTokens;
    final r = reasoningTokens < 0 ? 0 : reasoningTokens;
    var t = totalTokens < 0 ? 0 : totalTokens;
    if (t < p + c) t = p + c;
    return CloudTokenUsage(
      promptTokens: p,
      completionTokens: c,
      totalTokens: t,
      reasoningTokens: r,
      estimated: estimated,
    );
  }

  bool get isEmpty =>
      promptTokens == 0 &&
      completionTokens == 0 &&
      totalTokens == 0 &&
      reasoningTokens == 0;

  CloudTokenUsage operator +(CloudTokenUsage other) => CloudTokenUsage(
    promptTokens: promptTokens + other.promptTokens,
    completionTokens: completionTokens + other.completionTokens,
    totalTokens: totalTokens + other.totalTokens,
    reasoningTokens: reasoningTokens + other.reasoningTokens,
    estimated: estimated || other.estimated,
  );

  Map<String, dynamic> toJson() => {
    'prompt': promptTokens,
    'completion': completionTokens,
    'total': totalTokens,
    'reasoning': reasoningTokens,
    if (estimated) 'estimated': true,
  };

  factory CloudTokenUsage.fromJson(Map<String, dynamic> json) =>
      CloudTokenUsage(
        promptTokens: _int(json['prompt'] ?? json['prompt_tokens']),
        completionTokens: _int(json['completion'] ?? json['completion_tokens']),
        totalTokens: _int(json['total'] ?? json['total_tokens']),
        reasoningTokens: _int(
          json['reasoning'] ?? json['reasoning_tokens'] ?? json['thoughts'],
        ),
        estimated: json['estimated'] == true,
      );
}

/// 从服务端 `usage` 对象里抽 token（三种协议的字段名都在这里）
CloudTokenUsage cloudUsageFromJson(Object? raw) {
  if (raw is! Map) return CloudTokenUsage.zero;
  final m = raw.map((k, v) => MapEntry('$k', v));
  // OpenAI/DeepSeek：`prompt_tokens` / `completion_tokens` / `total_tokens`
  // Anthropic：`input_tokens` / `output_tokens`
  // Gemini：`promptTokenCount` / `candidatesTokenCount` / `totalTokenCount`
  final prompt = _firstInt([
    m['prompt_tokens'],
    m['input_tokens'],
    m['promptTokenCount'],
  ]);
  final completion = _firstInt([
    m['completion_tokens'],
    m['output_tokens'],
    m['candidatesTokenCount'],
  ]);
  final total = _firstInt([m['total_tokens'], m['totalTokenCount']]);
  // 思考 token：OpenAI 兼容在 `completion_tokens_details.reasoning_tokens`，
  // Gemini 在 `thoughtsTokenCount`
  var reasoning = _firstInt([m['thoughtsTokenCount'], m['reasoning_tokens']]);
  final details = m['completion_tokens_details'] ?? m['output_tokens_details'];
  if (details is Map) {
    reasoning += _int(details['reasoning_tokens']);
  }
  return CloudTokenUsage(
    promptTokens: prompt,
    completionTokens: completion,
    totalTokens: total,
    reasoningTokens: reasoning,
  ).sanitized();
}

int _firstInt(List<Object?> values) {
  for (final v in values) {
    final n = _maybeInt(v);
    if (n != null) return n;
  }
  return 0;
}

/// 只认标量；嵌套对象（`prompt_tokens_details` 之类）不在这里当 token 数用
int? _maybeInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

int _int(Object? v) => _maybeInt(v) ?? 0;

/// **服务端没回 usage 时的兜底**：按字符数折算 token。
///
/// 口径（粗略，但比"直接记 0"有用）：CJK 字符约 1 token/字；其余字符约
/// 4 字符/token。结果标 `estimated: true`，界面会带「估算」标记。
CloudTokenUsage estimateUsageFromText({
  required String promptText,
  required String completionText,
  int reasoningChars = 0,
}) {
  final p = _estimateTokens(promptText);
  final c =
      _estimateTokens(completionText) +
      (reasoningChars < 0 ? 0 : reasoningChars);
  return CloudTokenUsage(
    promptTokens: p,
    completionTokens: c,
    totalTokens: p + c,
    reasoningTokens: reasoningChars <= 0 ? 0 : reasoningChars,
    estimated: true,
  ).sanitized();
}

int _estimateTokens(String s) {
  var cjk = 0;
  var other = 0;
  for (final r in s.runes) {
    if (_isCjk(r)) {
      cjk++;
    } else {
      other++;
    }
  }
  return cjk + (other / 4).ceil();
}

bool _isCjk(int r) =>
    (r >= 0x3040 && r <= 0x30ff) || // 日文假名
    (r >= 0x3400 && r <= 0x4dbf) || // CJK 扩展 A
    (r >= 0x4e00 && r <= 0x9fff) || // CJK 基本区
    (r >= 0xf900 && r <= 0xfaff) || // CJK 兼容
    (r >= 0xac00 && r <= 0xd7af); // 韩文

/// 一个模型的公开列表价（USD / 1M tokens）
class CloudModelPrice {
  const CloudModelPrice({
    required this.match,
    required this.inputPerM,
    required this.outputPerM,
  });

  /// 匹配用的片段（小写包含匹配；**最长匹配优先**，所以 `gpt-4o-mini`
  /// 不会被 `gpt-4o` 抢走）
  final String match;
  final double inputPerM;
  final double outputPerM;
}

/// 内置单价表。**只收比较确定的公开列表价**，认不出来就返回 null（不计价）。
///
/// ⚠️ 时效：更新于 [kCloudPricingUpdatedAt]，各家调价频繁，**必须**在界面
/// 明确标注"本地估算、以官方账单为准"。要改就改这一张表。
const List<CloudModelPrice> kCloudModelPrices = [
  // OpenAI
  CloudModelPrice(match: 'gpt-4o-mini', inputPerM: 0.15, outputPerM: 0.60),
  CloudModelPrice(match: 'gpt-4o', inputPerM: 2.50, outputPerM: 10.00),
  CloudModelPrice(match: 'gpt-4.1-mini', inputPerM: 0.40, outputPerM: 1.60),
  CloudModelPrice(match: 'gpt-4.1', inputPerM: 2.00, outputPerM: 8.00),
  CloudModelPrice(match: 'o4-mini', inputPerM: 1.10, outputPerM: 4.40),
  CloudModelPrice(match: 'o3-mini', inputPerM: 1.10, outputPerM: 4.40),
  // Anthropic
  CloudModelPrice(match: 'claude-3-5-haiku', inputPerM: 0.80, outputPerM: 4.00),
  CloudModelPrice(match: 'claude-haiku-4-5', inputPerM: 1.00, outputPerM: 5.00),
  CloudModelPrice(
    match: 'claude-3-5-sonnet',
    inputPerM: 3.00,
    outputPerM: 15.00,
  ),
  CloudModelPrice(
    match: 'claude-3-7-sonnet',
    inputPerM: 3.00,
    outputPerM: 15.00,
  ),
  CloudModelPrice(match: 'claude-sonnet-4', inputPerM: 3.00, outputPerM: 15.00),
  // Google
  CloudModelPrice(match: 'gemini-2.0-flash', inputPerM: 0.10, outputPerM: 0.40),
  CloudModelPrice(match: 'gemini-2.5-flash', inputPerM: 0.30, outputPerM: 2.50),
  CloudModelPrice(match: 'gemini-2.5-pro', inputPerM: 1.25, outputPerM: 10.00),
  // DeepSeek
  CloudModelPrice(
    match: 'deepseek-reasoner',
    inputPerM: 0.55,
    outputPerM: 2.19,
  ),
  CloudModelPrice(match: 'deepseek-chat', inputPerM: 0.27, outputPerM: 1.10),
];

/// 按模型 id 查单价（**最长片段优先**；大小写不敏感）
CloudModelPrice? cloudPriceFor(String model) {
  final m = model.trim().toLowerCase();
  if (m.isEmpty) return null;
  CloudModelPrice? best;
  for (final p in kCloudModelPrices) {
    if (!m.contains(p.match)) continue;
    if (best == null || p.match.length > best.match.length) best = p;
  }
  return best;
}

/// base URL 指向本机/局域网 → 自建服务，按"免费"计（本地不算钱）
bool cloudIsLocalEndpoint(String baseUrl) {
  final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
  if (host == 'localhost' || host == '127.0.0.1' || host == '0.0.0.0') {
    return true;
  }
  if (host == '::1' || host == '[::1]') return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  if (a == null || b == null) return false;
  if (a == 10) return true;
  if (a == 192 && b == 168) return true;
  // RFC 1918：172.16.0.0 – 172.31.255.255
  if (a == 172 && b >= 16 && b <= 31) return true;
  return false;
}

/// 一次估价的结论
class CloudCostQuote {
  const CloudCostQuote({required this.usd, required this.priced});

  final double usd;

  /// 有没有单价可依（false = 界面显示"单价未知"，不算进总额）
  final bool priced;

  static const CloudCostQuote unknown = CloudCostQuote(usd: 0, priced: false);
}

/// 估算一次调用的费用
CloudCostQuote estimateCloudCost({
  required String model,
  required CloudTokenUsage usage,
  String baseUrl = '',
}) {
  final u = usage.sanitized();
  if (cloudIsLocalEndpoint(baseUrl)) {
    return const CloudCostQuote(usd: 0, priced: true);
  }
  final price = cloudPriceFor(model);
  if (price == null) return CloudCostQuote.unknown;
  final usd =
      u.promptTokens / 1000000 * price.inputPerM +
      u.completionTokens / 1000000 * price.outputPerM;
  return CloudCostQuote(usd: usd, priced: true);
}

/// 一次云端调用的用量记录（本地留存，用来做统计）
class CloudUsageRecord {
  const CloudUsageRecord({
    required this.atMs,
    required this.usage,
    this.profileId = '',
    this.providerId = '',
    this.model = '',
    this.protocolId = '',
    this.kind = '',
    this.elapsedMs = 0,
    this.costUsd = 0,
    this.priced = false,
    this.ok = true,
    this.imageCount = 0,
  });

  final int atMs;
  final CloudTokenUsage usage;
  final String profileId;
  final String providerId;
  final String model;
  final String protocolId;

  /// 任务种类（summary / askBook / translate / test / probe…），按需展示
  final String kind;
  final int elapsedMs;
  final double costUsd;

  /// 单价是否已知
  final bool priced;

  /// 这次调用成功与否（失败也会有 token 消耗，所以照样记）
  final bool ok;

  /// **图生图专用**：这次请求要计费的**图片张数**（token 调用恒为 0）。
  /// 一次出 n 张就记 n，所以"变体数计入单日额度"由它保证（方案 §7.2）。
  final int imageCount;

  CloudUsageRecord sanitized() {
    final u = usage.sanitized();
    var cost = costUsd;
    if (cost.isNaN || cost < 0) cost = 0;
    return CloudUsageRecord(
      atMs: atMs,
      usage: u,
      profileId: profileId,
      providerId: providerId,
      model: model,
      protocolId: protocolId,
      kind: kind,
      elapsedMs: elapsedMs < 0 ? 0 : elapsedMs,
      costUsd: cost,
      priced: priced,
      ok: ok,
      imageCount: imageCount < 0 ? 0 : imageCount,
    );
  }

  Map<String, dynamic> toJson() => {
    'at': atMs,
    'usage': usage.toJson(),
    'profile': profileId,
    'provider': providerId,
    'model': model,
    if (protocolId.isNotEmpty) 'protocol': protocolId,
    if (kind.isNotEmpty) 'kind': kind,
    if (elapsedMs > 0) 'ms': elapsedMs,
    'cost': costUsd,
    if (priced) 'priced': true,
    if (!ok) 'ok': false,
    if (imageCount > 0) 'images': imageCount,
  };

  factory CloudUsageRecord.fromJson(Map<String, dynamic> json) =>
      CloudUsageRecord(
        atMs: _int(json['at']),
        usage: CloudTokenUsage.fromJson(
          (json['usage'] is Map)
              ? (json['usage'] as Map).map((k, v) => MapEntry('$k', v))
              : const {},
        ),
        profileId: '${json['profile'] ?? ''}',
        providerId: '${json['provider'] ?? ''}',
        model: '${json['model'] ?? ''}',
        protocolId: '${json['protocol'] ?? ''}',
        kind: '${json['kind'] ?? ''}',
        elapsedMs: _int(json['ms']),
        costUsd: json['cost'] is num ? (json['cost'] as num).toDouble() : 0,
        priced: json['priced'] == true,
        ok: json['ok'] != false,
        // 向后兼容：老记录没有这个字段 → 0（容错解码，照其它字段的风格）
        imageCount: _int(json['images'] ?? json['image_count']),
      ).sanitized();
}

/// 本地留存的调用记录条数上限（超出丢最旧的；只是统计，不追求全量）
const int kCloudUsageMaxRecords = 500;

String encodeCloudUsage(List<CloudUsageRecord> list) =>
    jsonEncode([for (final r in list) r.toJson()]);

List<CloudUsageRecord> decodeCloudUsage(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  final out = <CloudUsageRecord>[];
  for (final one in decoded) {
    if (one is! Map) continue;
    out.add(CloudUsageRecord.fromJson(one.map((k, v) => MapEntry('$k', v))));
  }
  return out;
}

/// 往列表里追加一条，**超过上限丢最旧的**
List<CloudUsageRecord> appendCloudUsage(
  List<CloudUsageRecord> list,
  CloudUsageRecord record, {
  int max = kCloudUsageMaxRecords,
}) {
  final out = [...list, record.sanitized()];
  if (max > 0 && out.length > max) {
    return out.sublist(out.length - max);
  }
  return out;
}

/// 汇总数字
class CloudUsageTotals {
  const CloudUsageTotals({
    this.calls = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.reasoningTokens = 0,
    this.costUsd = 0,
    this.estimatedCalls = 0,
    this.unpricedCalls = 0,
  });

  final int calls;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int reasoningTokens;
  final double costUsd;

  /// 有几次的 token 是**估算**出来的
  final int estimatedCalls;

  /// 有几次**没有单价**（费用未计入 [costUsd]）
  final int unpricedCalls;

  static const CloudUsageTotals zero = CloudUsageTotals();
}

/// 一个分组（按模型 / 按日期）的汇总
class CloudUsageBucket {
  const CloudUsageBucket({required this.key, required this.totals});

  final String key;
  final CloudUsageTotals totals;
}

/// 整份统计
class CloudUsageSummary {
  const CloudUsageSummary({
    required this.overall,
    required this.byModel,
    required this.byDay,
  });

  final CloudUsageTotals overall;

  /// 按模型（费用从高到低）
  final List<CloudUsageBucket> byModel;

  /// 按日期（新到旧）
  final List<CloudUsageBucket> byDay;

  static const CloudUsageSummary empty = CloudUsageSummary(
    overall: CloudUsageTotals.zero,
    byModel: [],
    byDay: [],
  );
}

CloudUsageTotals _totalsOf(List<CloudUsageRecord> list) {
  var calls = 0;
  var p = 0;
  var c = 0;
  var t = 0;
  var r = 0;
  var cost = 0.0;
  var estimated = 0;
  var unpriced = 0;
  for (final raw in list) {
    final rec = raw.sanitized();
    calls++;
    p += rec.usage.promptTokens;
    c += rec.usage.completionTokens;
    t += rec.usage.totalTokens;
    r += rec.usage.reasoningTokens;
    cost += rec.costUsd;
    if (rec.usage.estimated) estimated++;
    if (!rec.priced) unpriced++;
  }
  return CloudUsageTotals(
    calls: calls,
    promptTokens: p,
    completionTokens: c,
    totalTokens: t,
    reasoningTokens: r,
    costUsd: cost,
    estimatedCalls: estimated,
    unpricedCalls: unpriced,
  );
}

/// 按时间窗 / 模型汇总。传 `sinceMs` 只看那之后；传 `model` 只看某个模型。
CloudUsageSummary summarizeCloudUsage(
  List<CloudUsageRecord> records, {
  int? sinceMs,
  String? model,
}) {
  final filtered = <CloudUsageRecord>[];
  for (final raw in records) {
    final rec = raw.sanitized();
    if (sinceMs != null && rec.atMs < sinceMs) continue;
    if (model != null && model.trim().isNotEmpty && rec.model != model) {
      continue;
    }
    filtered.add(rec);
  }
  final byModelMap = <String, List<CloudUsageRecord>>{};
  final byDayMap = <String, List<CloudUsageRecord>>{};
  for (final rec in filtered) {
    final mk = rec.model.trim().isEmpty ? '—' : rec.model;
    byModelMap.putIfAbsent(mk, () => []).add(rec);
    byDayMap.putIfAbsent(cloudUsageDayKey(rec.atMs), () => []).add(rec);
  }
  final byModel =
      [
        for (final e in byModelMap.entries)
          CloudUsageBucket(key: e.key, totals: _totalsOf(e.value)),
      ]..sort((a, b) {
        final c = b.totals.costUsd.compareTo(a.totals.costUsd);
        return c != 0 ? c : b.totals.calls.compareTo(a.totals.calls);
      });
  final byDay = [
    for (final e in byDayMap.entries)
      CloudUsageBucket(key: e.key, totals: _totalsOf(e.value)),
  ]..sort((a, b) => b.key.compareTo(a.key));
  return CloudUsageSummary(
    overall: _totalsOf(filtered),
    byModel: byModel,
    byDay: byDay,
  );
}

/// 本地日期键 `YYYY-MM-DD`（按设备时区）
String cloudUsageDayKey(int atMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(atMs);
  final m = d.month < 10 ? '0${d.month}' : '${d.month}';
  final day = d.day < 10 ? '0${d.day}' : '${d.day}';
  return '${d.year}-$m-$day';
}
