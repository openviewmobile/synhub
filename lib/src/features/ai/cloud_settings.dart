// 云端大模型的设置状态（**多套配置并存 + 快速切换** / 厂商 / 地址 / key / 模型 / 参数）。
//
// 边界很明确：
//   * **key 只走 [CloudKeyStore]**（系统安全存储），这个类里只是"读出来用"，
//     不往普通偏好表里写；`debugPrint`/错误信息里也绝不带 key。
//   * 其余（配置列表、当前配置、厂商、base URL、模型、参数、模型列表缓存、
//     用量记录）走 `SettingsService`。
//   * 拉模型列表 / 测试连接都走这里，UI 只认 state（loading/error 也在 state 里），
//     这样"切到别的页面再回来"不会丢进度。
//
// 多套配置的语义（很重要，别搞混）：
//   * 一个 [CloudProfile] = 一套可命名的配置（厂商 + 地址 + 协议 + 模型 + 参数）；
//     **API Key 不在里面**，它在安全存储里以 profile.id 为槽位。
//   * `selectProvider(id)` = "我要用这家的（默认那套）配置"：有就切过去，
//     没有就用预设新建一套（id 就是 providerId，与老版本单套配置的 key 槽位一致）。
//   * `saveProfileAsNew(name)` = 把当前编辑中的配置**另存**为一套新配置，
//     于是同一家可以并存多套（例如两个中转地址）。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/settings/app_settings.dart'
    show SettingsService, settingsServiceProvider;
import '../../core/settings/cloud_key_store.dart';
import '../../data/ai/cloud_llm_client.dart';
import '../../data/ai/cloud_pricing.dart';
import '../../data/ai/cloud_profile.dart';
import '../../data/ai/cloud_provider.dart';

/// 服务档位：云端优先，端侧与内置摘要都保留
enum AiTier {
  cloud('cloud', '云端大模型'),
  onDevice('onDevice', '端侧模型'),
  extractive('auto', '内置摘要（无模型）');

  const AiTier(this.id, this.label);

  final String id;

  /// 中文标签（**回落**；界面走 [labelIn]）
  final String label;

  /// 本地化标签
  String labelIn(AppText t) => switch (this) {
    AiTier.cloud => t.aiTierCloud,
    AiTier.onDevice => t.aiEngineOnDevice,
    AiTier.extractive => t.aiEngineExtractive,
  };

  static AiTier fromId(String? id) => switch (id) {
    'onDevice' => AiTier.onDevice,
    'auto' => AiTier.extractive,
    _ => AiTier.cloud,
  };
}

@immutable
class CloudSettings {
  const CloudSettings({
    this.profiles = const [],
    this.activeProfileId = '',
    this.providerId = '',
    this.baseUrl = '',
    this.protocolId = 'openai',
    this.model = '',
    this.apiKey = '',
    this.temperature = 0.6,
    this.maxTokens = 1024,
    this.cachedModels = const [],
    this.loading = false,
    this.error = '',
    this.testing = false,
    this.testResult = '',
    this.usage = const [],
  });

  /// 已保存的配置（多套并存）；顺序 = 创建顺序
  final List<CloudProfile> profiles;

  /// 当前生效的配置 id（空 = 还没配置过）
  final String activeProfileId;

  /// 选中的厂商 id（空 = 还没选）
  final String providerId;

  /// 实际生效的 base URL（预设的默认值会写进来，用户可改）
  final String baseUrl;

  /// 自定义厂商的协议；预设厂商以预设为准
  final String protocolId;

  final String model;
  final String apiKey;
  final double temperature;
  final int maxTokens;

  /// 上次拉到的模型列表（离线也能选）
  final List<CloudModelInfo> cachedModels;

  // 三个"过程态"：拉列表 / 测试连接
  final bool loading;
  final String error;
  final bool testing;
  final String testResult;

  /// 本机留存的云端调用用量记录（最新的在最后）
  final List<CloudUsageRecord> usage;

  CloudProviderInfo get provider =>
      cloudProviderById(providerId) ?? kCloudProviders.last;

  CloudProtocol get protocol =>
      provider.isCustom ? CloudProtocol.fromId(protocolId) : provider.protocol;

  /// 配置是否完整到能发请求
  bool get configured => baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  /// 缺 key 的情况下，本地/自建服务仍然可用
  bool get needsKey => provider.needsKey;

  /// 当前生效的配置对象（没配置过就是 null）
  CloudProfile? get activeProfile {
    for (final p in profiles) {
      if (p.id == activeProfileId) return p;
    }
    return null;
  }

  /// 这套配置有没有名字（界面回落成厂商名）
  bool get activeHasName => (activeProfile?.displayName ?? '').isNotEmpty;

  CloudLlmConfig get config => CloudLlmConfig(
    protocol: protocol,
    baseUrl: baseUrl,
    apiKey: apiKey,
    model: model,
    temperature: temperature,
    maxTokens: maxTokens,
    providerId: providerId,
    profileId: activeProfileId,
  );

  /// 用量汇总（全部时间窗）
  CloudUsageSummary get usageSummary => summarizeCloudUsage(usage);

  /// 某个时间窗（毫秒）起的用量汇总
  CloudUsageSummary usageSince(int? sinceMs) =>
      summarizeCloudUsage(usage, sinceMs: sinceMs);

  CloudSettings copyWith({
    List<CloudProfile>? profiles,
    String? activeProfileId,
    String? providerId,
    String? baseUrl,
    String? protocolId,
    String? model,
    String? apiKey,
    double? temperature,
    int? maxTokens,
    List<CloudModelInfo>? cachedModels,
    bool? loading,
    String? error,
    bool? testing,
    String? testResult,
    List<CloudUsageRecord>? usage,
  }) => CloudSettings(
    profiles: profiles ?? this.profiles,
    activeProfileId: activeProfileId ?? this.activeProfileId,
    providerId: providerId ?? this.providerId,
    baseUrl: baseUrl ?? this.baseUrl,
    protocolId: protocolId ?? this.protocolId,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    cachedModels: cachedModels ?? this.cachedModels,
    loading: loading ?? this.loading,
    error: error ?? this.error,
    testing: testing ?? this.testing,
    testResult: testResult ?? this.testResult,
    usage: usage ?? this.usage,
  );
}

final cloudSettingsProvider =
    NotifierProvider<CloudSettingsNotifier, CloudSettings>(
      CloudSettingsNotifier.new,
    );

class CloudSettingsNotifier extends Notifier<CloudSettings> {
  @override
  CloudSettings build() => const CloudSettings();

  SettingsService get _settings => ref.read(settingsServiceProvider);

  CloudKeyStore get _keys => ref.read(cloudKeyStoreProvider);

  CloudLlmClient get _client => ref.read(cloudLlmClientProvider);

  // -------------------------------------------------------------- 启动加载

  /// 启动时读回来（配置列表 + key 从安全存储取 + 用量记录）
  ///
  /// **老配置迁移**：以前把单套配置拆在 5 个 KV 键里。这里发现"没有配置列表"
  /// 但老键有值时，就把它们收成第一套配置，且 id 用老 providerId —— 于是
  /// 安全存储里 `ai_cloud_key_<providerId>` 原样命中，**老用户升级后不丢配置、
  /// 也不用重填 key**。
  Future<void> preload() async {
    final s = _settings;
    var profiles = decodeCloudProfiles(await s.aiCloudProfiles());
    var activeId = await s.aiCloudActiveProfile() ?? '';
    if (profiles.isEmpty) {
      final legacyProvider = await s.aiCloudProviderId() ?? '';
      final legacyBase = await s.aiCloudBaseUrl() ?? '';
      final legacyModel = await s.aiCloudModel() ?? '';
      final legacyProtocol = await s.aiCloudProtocol();
      final legacyTemp = await s.aiCloudTemperature();
      final legacyMax = await s.aiCloudMaxTokens();
      profiles = migrateLegacyCloudProfile(
        providerId: legacyProvider,
        baseUrl: legacyBase,
        protocolId: legacyProtocol,
        model: legacyModel,
        temperature: legacyTemp,
        maxTokens: legacyMax,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      if (profiles.isNotEmpty) activeId = profiles.first.id;
    }
    if (profiles.isNotEmpty && !profiles.any((p) => p.id == activeId)) {
      activeId = profiles.first.id;
    }
    final usage = decodeCloudUsage(await s.aiCloudUsage());
    final cachedAll = _decode(await s.aiCloudModelCache());

    CloudProfile? active;
    for (final p in profiles) {
      if (p.id == activeId) active = p;
    }

    if (active == null) {
      if (!ref.mounted) return;
      state = CloudSettings(
        profiles: profiles,
        activeProfileId: activeId,
        cachedModels: const [],
        usage: usage,
      );
      return;
    }

    final key = await _readKey(active);
    if (!ref.mounted) return;
    state = CloudSettings(
      profiles: profiles,
      activeProfileId: activeId,
      providerId: active.providerId,
      baseUrl: active.baseUrl,
      protocolId: active.protocolId,
      model: active.model,
      apiKey: key,
      temperature: active.temperature,
      maxTokens: active.maxTokens,
      cachedModels: cachedAll[active.providerId] ?? const [],
      usage: usage,
    );
    // 迁移出来的配置要落库一次（否则每次启动都重算）
    await _persist(profiles: profiles, activeId: activeId);
  }

  // ------------------------------------------------------------ 多套配置

  /// 切到某个厂商的**默认那套**配置；没有就按预设新建
  Future<void> selectProvider(
    String id, {
    String customProtocol = 'openai',
  }) async {
    final preset = cloudProviderById(id);
    final profiles = [...state.profiles];
    final existing = _defaultProfileFor(profiles, id);
    if (existing != null) {
      await _activate(existing, profiles);
      return;
    }
    final profile = CloudProfile(
      id: id.isEmpty ? kCustomProviderId : id,
      providerId: id,
      protocolId: preset?.isCustom == true
          ? customProtocol
          : (preset?.protocol.id ?? 'openai'),
      baseUrl: preset?.baseUrl ?? '',
      model: '',
      temperature: state.temperature,
      maxTokens: state.maxTokens,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    profiles.add(profile);
    await _activate(profile, profiles);
  }

  /// 切换到已保存的某一套配置（**一键切换**）
  Future<void> switchProfile(String id) async {
    final profiles = state.profiles;
    CloudProfile? target;
    for (final p in profiles) {
      if (p.id == id) target = p;
    }
    if (target == null) return;
    await _activate(target, profiles);
  }

  /// 把**当前编辑中的配置**另存为一套新配置（同一家可以并存多套）
  ///
  /// 返回新配置的 id（失败返回空串）。
  Future<String> saveProfileAsNew(String name) async {
    if (state.providerId.trim().isEmpty && state.baseUrl.trim().isEmpty) {
      state = state.copyWith(error: currentText().aiProfileNeedProvider);
      return '';
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final id = makeProfileId(
      providerId: state.providerId,
      nowMs: nowMs,
      existing: state.profiles.map((p) => p.id),
    );
    final profile = CloudProfile(
      id: id,
      name: name.trim(),
      providerId: state.providerId,
      protocolId: state.protocolId,
      baseUrl: state.baseUrl,
      model: state.model,
      temperature: state.temperature,
      maxTokens: state.maxTokens,
      createdAtMs: nowMs,
    );
    final profiles = [...state.profiles, profile];
    // key 跟着新配置走（写进新槽位；原来那套的 key 不动）
    if (state.providerId.isNotEmpty && state.apiKey.isNotEmpty) {
      await _keys.write(id, state.apiKey);
    }
    await _persist(profiles: profiles, activeId: id);
    if (!ref.mounted) return id;
    state = state.copyWith(
      profiles: profiles,
      activeProfileId: id,
      error: '',
      testResult: '',
    );
    return id;
  }

  /// 重命名某套配置
  Future<void> renameProfile(String id, String name) async {
    final profiles = [
      for (final p in state.profiles)
        if (p.id == id) p.copyWith(name: name.trim()) else p,
    ];
    await _persist(profiles: profiles, activeId: state.activeProfileId);
    if (!ref.mounted) return;
    state = state.copyWith(profiles: profiles);
  }

  /// 删除一套配置（它自己的 key 槽位也一并从安全存储删掉）
  Future<void> deleteProfile(String id) async {
    if (state.profiles.length <= 1) {
      // 只剩一套时删除 = 抵赖：宁可如实说，也别让状态变成"没有配置"
      state = state.copyWith(error: currentText().aiProfileKeepOne);
      return;
    }
    final profiles = [
      for (final p in state.profiles)
        if (p.id != id) p,
    ];
    await _keys.delete(id);
    if (state.activeProfileId == id) {
      await _activate(profiles.first, profiles);
      return;
    }
    await _persist(profiles: profiles, activeId: state.activeProfileId);
    if (!ref.mounted) return;
    state = state.copyWith(profiles: profiles, error: '');
  }

  /// 当前配置的显示名（用户命名优先，否则厂商名）
  String profileLabel(CloudProfile p, AppText t) {
    if (p.displayName.isNotEmpty) return p.displayName;
    final preset = cloudProviderById(p.providerId);
    if (preset == null) return t.aiProfileUntitled;
    return preset.nameText;
  }

  CloudProfile? _defaultProfileFor(List<CloudProfile> profiles, String id) {
    final pid = id.isEmpty ? kCustomProviderId : id;
    for (final p in profiles) {
      if (p.id == pid) return p;
    }
    return null;
  }

  /// 把某个 profile 设为当前配置（读它的 key + 列表缓存，写入 state 与 KV）
  Future<void> _activate(
    CloudProfile profile,
    List<CloudProfile> profiles,
  ) async {
    final key = await _readKey(profile);
    final cached = _decode(await _settings.aiCloudModelCache());
    if (!ref.mounted) return;
    state = state.copyWith(
      profiles: profiles,
      activeProfileId: profile.id,
      providerId: profile.providerId,
      baseUrl: profile.baseUrl,
      protocolId: profile.protocolId,
      model: profile.model,
      apiKey: key,
      temperature: profile.temperature,
      maxTokens: profile.maxTokens,
      cachedModels: cached[profile.providerId] ?? const [],
      error: '',
      testResult: '',
    );
    await _persist(profiles: profiles, activeId: profile.id);
  }

  // ------------------------------------------------------------ 编辑当前配置

  Future<void> setBaseUrl(String v) async {
    state = state.copyWith(baseUrl: v, error: '', testResult: '');
    await _persistActive();
  }

  Future<void> setProtocol(String id) async {
    state = state.copyWith(protocolId: id, error: '', testResult: '');
    await _persistActive();
  }

  Future<void> setModel(String v) async {
    state = state.copyWith(model: v, error: '', testResult: '');
    await _persistActive();
  }

  Future<void> setKey(String v) async {
    state = state.copyWith(apiKey: v, error: '', testResult: '');
    if (state.providerId.isEmpty) return;
    // 写自己的槽位（`profile.id`）。
    //
    // ⚠️ 只在"这套配置就是该厂商的默认配置"（`id == providerId`）时才写
    // providerId 槽位：那是**老版本兼容槽位**，同一厂商并存多套时若也双写，
    // 后一套会把前一套的 key 覆盖掉（切回去就读到别人的 key 了）。
    // 老 key 的兼容只在**读**的时候做（见 `_readKey`）。
    final pid = state.activeProfileId;
    if (pid.isEmpty) {
      await _keys.write(state.providerId, v);
    } else {
      await _keys.write(pid, v);
      if (pid == state.providerId) {
        await _keys.write(state.providerId, v);
      }
    }
  }

  Future<void> setTemperature(double v) async {
    state = state.copyWith(temperature: v);
    await _persistActive();
  }

  Future<void> setMaxTokens(int v) async {
    state = state.copyWith(maxTokens: v);
    await _persistActive();
  }

  // ---------------------------------------------------------------- 用量

  /// 记一次云端调用的 token/费用（失败也会记账：失败也烧 token）
  Future<void> recordUsage(CloudUsageRecord record) async {
    final list = appendCloudUsage(state.usage, record);
    if (ref.mounted) state = state.copyWith(usage: list);
    await _settings.setAiCloudUsage(encodeCloudUsage(list));
  }

  /// 清空本机用量记录（服务商那边的账单不受影响，文案里要说清）
  Future<void> clearUsage() async {
    if (ref.mounted) state = state.copyWith(usage: const []);
    await _settings.setAiCloudUsage('');
  }

  // ---------------------------------------------------------------- 网络

  /// 拉模型列表（失败就把"为什么"写进 error，UI 引导手填）
  Future<void> refreshModels() async {
    if (!state.provider.supportsModelList) {
      // 智谱/百炼这种官方就没有列表接口的，别发一个注定 404 的请求
      state = state.copyWith(
        error: currentText().aiNoModelListNamed(state.provider.name),
      );
      return;
    }
    if (!state.configured && state.baseUrl.trim().isEmpty) {
      state = state.copyWith(error: currentText().aiPickProviderFirst);
      return;
    }
    state = state.copyWith(loading: true, error: '');
    try {
      final list = await _client.models(cfg: state.config);
      if (!ref.mounted) return;
      if (list.isEmpty) {
        state = state.copyWith(
          loading: false,
          error: currentText().aiNoModelListReturned,
        );
        return;
      }
      state = state.copyWith(loading: false, cachedModels: list);
      await _cacheModels(state.providerId, list);
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(loading: false, error: describeCloudError(e));
    }
  }

  /// 测试连接：发一条极短的非流式请求
  Future<bool> test() async {
    if (!state.configured) {
      state = state.copyWith(testResult: currentText().aiTestIncomplete);
      return false;
    }
    state = state.copyWith(testing: true, testResult: '');
    try {
      final res = await _client.complete(cfg: state.config);
      if (!ref.mounted) return false;
      // 测试连接也烧 token，如实记账（kind=test）
      await _recordCompletion(res, kind: 'test');
      if (!ref.mounted) return false;
      final text = res.text.trim().replaceAll('\n', ' ');
      state = state.copyWith(
        testing: false,
        testResult: text.isEmpty
            ? currentText().aiTestNoText
            : currentText().aiTestOk(
                text.length > 40 ? '${text.substring(0, 40)}…' : text,
              ),
      );
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(testing: false, testResult: describeCloudError(e));
      return false;
    }
  }

  /// 把一次非流式调用记进用量（服务端没回 usage 就按字符数估算）
  Future<void> _recordCompletion(
    CloudCompletion res, {
    required String kind,
  }) async {
    var usage = res.tokens.sanitized();
    if (usage.isEmpty) {
      usage = estimateUsageFromText(
        promptText: 'test',
        completionText: res.text,
        reasoningChars: res.thinking.length,
      );
    }
    final quote = estimateCloudCost(
      model: state.model,
      usage: usage,
      baseUrl: state.baseUrl,
    );
    await recordUsage(
      CloudUsageRecord(
        atMs: DateTime.now().millisecondsSinceEpoch,
        usage: usage,
        profileId: state.activeProfileId,
        providerId: state.providerId,
        model: state.model,
        protocolId: state.protocolId,
        kind: kind,
        costUsd: quote.usd,
        priced: quote.priced,
      ),
    );
  }

  // ---------------------------------------------------------------- 内部

  /// 把当前编辑里的字段写回"当前配置"，并落库
  Future<void> _persistActive() async {
    final id = state.activeProfileId;
    if (id.isEmpty) {
      // 还没选厂商/没配置过：只落老键，等真的选了厂商再建 profile
      await _writeLegacy();
      return;
    }
    final profiles = [
      for (final p in state.profiles)
        if (p.id == id)
          p.copyWith(
            providerId: state.providerId,
            protocolId: state.protocolId,
            baseUrl: state.baseUrl,
            model: state.model,
            temperature: state.temperature,
            maxTokens: state.maxTokens,
          )
        else
          p,
    ];
    await _persist(
      profiles: profiles,
      activeId: id,
      nextStateProfiles: profiles,
    );
  }

  /// 落库：配置列表 + 当前 id + 老键（兼容旧代码/旧测试的读取点）
  Future<void> _persist({
    required List<CloudProfile> profiles,
    required String activeId,
    List<CloudProfile>? nextStateProfiles,
  }) async {
    await _settings.setAiCloudProfiles(encodeCloudProfiles(profiles));
    await _settings.setAiCloudActiveProfile(activeId);
    if (nextStateProfiles != null && ref.mounted) {
      state = state.copyWith(profiles: nextStateProfiles);
    }
    await _writeLegacy();
  }

  /// 老键同步写（老版本读法 / 老单测读法仍成立）
  Future<void> _writeLegacy() async {
    final s = _settings;
    await s.setAiCloudProviderId(state.providerId);
    await s.setAiCloudBaseUrl(state.baseUrl);
    await s.setAiCloudProtocol(state.protocolId);
    await s.setAiCloudModel(state.model);
    await s.setAiCloudTemperature(state.temperature);
    await s.setAiCloudMaxTokens(state.maxTokens);
  }

  /// 读某套配置的 key：先看它自己的槽位，再回落"厂商"槽位（老版本兼容）
  Future<String> _readKey(CloudProfile profile) async {
    final own = await _keys.read(profile.id);
    if (own != null && own.isNotEmpty) return own;
    if (profile.id == profile.providerId) return own ?? '';
    final legacy = await _keys.read(profile.providerId);
    return legacy ?? '';
  }

  Future<void> _cacheModels(
    String providerId,
    List<CloudModelInfo> list,
  ) async {
    final all = _decode(await _settings.aiCloudModelCache());
    all[providerId] = list;
    await _settings.setAiCloudModelCache(
      jsonEncode({
        for (final e in all.entries)
          e.key: [
            for (final m in e.value) {'id': m.id, 'label': m.label},
          ],
      }),
    );
  }

  Map<String, List<CloudModelInfo>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, List<CloudModelInfo>>{};
      decoded.forEach((k, v) {
        if (v is List) {
          out['$k'] = [
            for (final one in v)
              if (one is Map)
                CloudModelInfo(
                  id: '${one['id'] ?? ''}',
                  label: '${one['label'] ?? ''}',
                ),
          ];
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }
}

/// 客户端单例（mock 在测试里覆盖它即可）
final cloudLlmClientProvider = Provider<CloudLlmClient>(
  (ref) => CloudLlmClient(),
);
