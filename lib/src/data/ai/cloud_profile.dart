// 云端大模型的**多套配置（profile）**模型与持久化格式。
//
// 为什么要有这一层：以前是"一家一套配置"，用户想在工作用的中转、家里的
// Ollama、官方的 DeepSeek 之间来回切，就得每次重填 base URL / 模型 / key。
// 这一层把"一套可命名的配置"独立出来，支持并存 + 一键切换。
//
// 设计要点：
//   * **纯 Dart**：只依赖 dart:convert，能被 `dart run tool/*.dart` 加载
//     （与 `data_text.dart` 同一约束，见 docs/app-identity-and-i18n.md §4.6）。
//   * **API Key 不在 profile 里**：只在安全存储（`CloudKeyStore`）里，
//     以 profile.id 为槽位；profile 对象里连 key 的片段都不留。
//   * **老配置能迁移**：老版本把单套配置拆在 5 个 KV 键里
//     （`ai_cloud_provider` / `ai_cloud_base_url` / …），
//     [migrateLegacyCloudProfile] 把它们收成第一套 profile，
//     且 **id 就用老的 providerId** —— 这样安全存储里老的 key 槽位原样命中，
//     老用户升级后不用重填 key。
import 'dart:convert';

/// KV 键：配置列表（JSON 数组）与当前选中的 profile id
const String kCloudProfilesKey = 'ai_cloud_profiles';
const String kCloudActiveProfileKey = 'ai_cloud_active_profile';

/// 一套云端配置（不含 API Key）
class CloudProfile {
  const CloudProfile({
    required this.id,
    this.name = '',
    this.providerId = '',
    this.protocolId = 'openai',
    this.baseUrl = '',
    this.model = '',
    this.temperature = 0.6,
    this.maxTokens = 1024,
    this.createdAtMs = 0,
  });

  /// 稳定标识。老配置迁移出来的 profile，**id 就等于当年的 providerId**
  /// （安全存储里的 key 槽位因此不用动）。
  final String id;

  /// 用户取的名字；空串表示"没命名"，界面回落成厂商名。
  final String name;

  /// `kCloudProviders` 里的厂商 id
  final String providerId;

  /// 自定义厂商的协议；预设厂商以预设为准（这里同样记着，方便离线还原）
  final String protocolId;

  final String baseUrl;
  final String model;
  final double temperature;
  final int maxTokens;

  /// 创建时间（毫秒），只用于稳定排序与生成 id
  final int createdAtMs;

  /// 够不够发请求（base URL + 模型）
  bool get configured => baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  /// 显示名：用户命名的优先；没命名返回空串，由界面回落厂商名
  String get displayName => name.trim();

  CloudProfile copyWith({
    String? id,
    String? name,
    String? providerId,
    String? protocolId,
    String? baseUrl,
    String? model,
    double? temperature,
    int? maxTokens,
    int? createdAtMs,
  }) => CloudProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    providerId: providerId ?? this.providerId,
    protocolId: protocolId ?? this.protocolId,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    createdAtMs: createdAtMs ?? this.createdAtMs,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'providerId': providerId,
    'protocolId': protocolId,
    'baseUrl': baseUrl,
    'model': model,
    'temperature': temperature,
    'maxTokens': maxTokens,
    'createdAtMs': createdAtMs,
  };

  /// 容错解码：字段缺失/类型不对都退回默认值（宁可丢一点，不要让设置页崩）
  factory CloudProfile.fromJson(Map<String, dynamic> json) => CloudProfile(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    providerId: '${json['providerId'] ?? json['provider'] ?? ''}',
    protocolId: '${json['protocolId'] ?? 'openai'}',
    baseUrl: '${json['baseUrl'] ?? ''}',
    model: '${json['model'] ?? ''}',
    temperature: _asDouble(json['temperature'], 0.6),
    maxTokens: _asInt(json['maxTokens'], 1024),
    createdAtMs: _asInt(json['createdAtMs'], 0),
  );

  /// 日志里用：**绝不带 key**（key 本来就不在这里，这里只是明确一下）
  @override
  String toString() =>
      'CloudProfile($id, $providerId, model=$model, url=$baseUrl)';
}

double _asDouble(Object? v, double fallback) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

int _asInt(Object? v, int fallback) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

/// 把配置列表编码成 KV 里存的 JSON 串
String encodeCloudProfiles(List<CloudProfile> list) =>
    jsonEncode([for (final p in list) p.toJson()]);

/// 解码配置列表。**坏数据一律忽略**（只丢坏的那条，不整表丢）。
List<CloudProfile> decodeCloudProfiles(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  final out = <CloudProfile>[];
  for (final one in decoded) {
    if (one is! Map) continue;
    final p = CloudProfile.fromJson(one.map((k, v) => MapEntry('$k', v)));
    if (p.id.trim().isEmpty) continue;
    out.add(p);
  }
  return out;
}

/// 老版本的单套配置 → 配置列表（**迁移路径**）。
///
/// 规则：
///   * 五个字段全空 → 返回空表（新装用户，不需要造空 profile）；
///   * 否则收成一条 profile，**id 用当年的 providerId**（这样安全存储里
///     `ai_cloud_key_<providerId>` 这个槽位原样命中，key 不用重填）；
///   * providerId 为空但填了地址（例如用户只填了自定义地址）→ 用 `custom` 当 id。
List<CloudProfile> migrateLegacyCloudProfile({
  String providerId = '',
  String baseUrl = '',
  String protocolId = 'openai',
  String model = '',
  double temperature = 0.6,
  int maxTokens = 1024,
  required int nowMs,
}) {
  final pid = providerId.trim();
  final hasAny =
      pid.isNotEmpty || baseUrl.trim().isNotEmpty || model.trim().isNotEmpty;
  if (!hasAny) return const [];
  final id = pid.isEmpty ? 'custom' : pid;
  return [
    CloudProfile(
      id: id,
      name: '',
      providerId: id,
      protocolId: protocolId.trim().isEmpty ? 'openai' : protocolId.trim(),
      baseUrl: baseUrl,
      model: model,
      temperature: temperature,
      maxTokens: maxTokens,
      createdAtMs: nowMs,
    ),
  ];
}

/// 生成一套新配置的 id。
///
/// 规则：`<providerId>-<时间戳>`；同一毫秒重复时补序号，
/// 保证**同一厂商可以并存多套**且 id 稳定（切换/删除都靠它）。
String makeProfileId({
  required String providerId,
  required int nowMs,
  Iterable<String> existing = const [],
}) {
  final base = providerId.trim().isEmpty ? 'custom' : providerId.trim();
  final taken = existing.toSet();
  var candidate = '$base-$nowMs';
  var n = 2;
  while (taken.contains(candidate)) {
    candidate = '$base-$nowMs-$n';
    n++;
  }
  return candidate;
}

/// 老配置迁移出来时用的 id（等于 providerId），新建 profile 时用它判断
/// "这个厂商是否已经有一套默认配置了"。
bool isDefaultProfileIdFor(String profileId, String providerId) =>
    profileId == (providerId.trim().isEmpty ? 'custom' : providerId.trim());
