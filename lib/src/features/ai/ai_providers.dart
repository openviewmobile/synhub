// 端侧 AI 的 provider 层。
//
// 三条约定：
//   1. **默认引擎是兜底引擎**（纯 Dart）——测试/低配/没下模型都能跑；
//      真机上装过模型才切到 `GemmaLlmEngine`（[aiEngineProvider] 里的
//      `_AiAutoEngine` 负责这个判断，且判断是异步的、失败即降级）。
//   2. 下载/删除模型只走这里，UI 不直接碰推理库。
//   3. 开关与偏好存本地设置（`ai_enabled` / `ai_wifi_only` / `ai_model_id`）。
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/provider_retry.dart';

import '../../core/settings/app_settings.dart'
    show SettingsService, settingsServiceProvider;
import '../../core/device/device_capability.dart';
import '../../core/platform/app_platform.dart';
import 'ai_device_fit.dart';
import 'ai_service.dart';
import 'cloud_engine.dart';
import 'cloud_settings.dart';
import 'llm_engine.dart';
import 'model_vault.dart';
import 'on_device_ai.dart';
import '../../core/user_facing_error.dart';

/// 端侧 AI 总开关（默认开）
final aiEnabledProvider = NotifierProvider<AiEnabledNotifier, bool>(
  AiEnabledNotifier.new,
);

class AiEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  Future<void> preload() async {
    final v = await ref.read(settingsServiceProvider).aiEnabled();
    if (!ref.mounted) return;
    state = v;
  }

  Future<void> set(bool v) async {
    state = v;
    await ref.read(settingsServiceProvider).setAiEnabled(v);
  }
}

/// 只在 WiFi 下载模型（默认开）
final aiWifiOnlyProvider = NotifierProvider<AiWifiOnlyNotifier, bool>(
  AiWifiOnlyNotifier.new,
);

class AiWifiOnlyNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  Future<void> preload() async {
    final v = await ref.read(settingsServiceProvider).aiWifiOnly();
    if (!ref.mounted) return;
    state = v;
  }

  Future<void> set(bool v) async {
    state = v;
    await ref.read(settingsServiceProvider).setAiWifiOnly(v);
  }
}

/// 选中的模型档位（null = 推荐档）
final aiModelChoiceProvider =
    NotifierProvider<AiModelChoiceNotifier, AiModelInfo?>(
      AiModelChoiceNotifier.new,
    );

class AiModelChoiceNotifier extends Notifier<AiModelInfo?> {
  @override
  AiModelInfo? build() => null;

  Future<void> preload() async {
    final id = await ref.read(settingsServiceProvider).aiModelId();
    if (!ref.mounted) return;
    state = aiModelById(id) ?? _defaultModel;
  }

  Future<void> select(AiModelInfo m) async {
    state = m;
    await ref.read(settingsServiceProvider).setAiModelId(m.id);
  }

  /// 这份模型（按 id 或文件名）**被删掉了** ⇒ 如果它正是当前档位，把选择一起作废。
  ///
  /// ★ 为什么必须动**状态**而不只是行内文案（D6 / §2.0.26 第 2 条）：
  /// `select()` 会把 id 持久化（`ai_model_id`），下次启动由 [preload] 恢复；
  /// 不在这里清掉的话，"当前档位"这个结论会一直指着一个**已经不存在的文件**，
  /// UI 只是把矛盾遮住（审计截图 `ai_11_ond.png`：页首"还没下载模型"、
  /// 行内却写 `In use`）。清成 `null` = 回到"未显式选择"，由
  /// [AiModelPage] 的推荐档兜底 + "装没装"（`has`）共同决定显示。
  ///
  /// 只在**确实删掉的是当前档位**时才写设置（其它情况一个字节都不碰）。
  Future<void> clearIfDeleted(String idOrFileName) async {
    final cur = state;
    if (cur == null) return;
    if (cur.id != idOrFileName && cur.fileName != idOrFileName) return;
    state = null;
    await ref.read(settingsServiceProvider).setAiModelId('');
  }
}

AiModelInfo get _defaultModel {
  for (final m in kOnDeviceModels) {
    if (m.recommended) return m;
  }
  return kOnDeviceModels.first;
}

/// 这一台机器能不能跑端侧推理（Android/iOS 才试；桌面/测试宿主直接兜底）
///
/// 第 279 轮：从裸 `Platform.isAndroid || Platform.isIOS` 改成问平台能力层，
/// **语义一字不动**（手机 = 可试；桌面 = 不可试，原因 `needs-mobile-host`）。
///
/// ★ 与"档位要不要藏"是两件事（AGENTS §2.0.6 第 2/3 条）：
///   这里答的是"端侧**引擎**能不能起"，答"不能"只影响安装/列已装模型；
///   **档位可见性**由 `aiModuleVisibleProvider` 决定 —— 桌面宿主上
///   `DeviceCapability.source == 'host'` ⇒ `ungatedHost` ⇒ 档位**照常显示**，
///   不会被这里硬藏掉。
///
/// 桌面（尤其 macOS）想真跑端侧模型的排期见 `docs/multi-platform-roadmap.md`：
/// `flutter_gemma` 有桌面插件（启动日志 `[FlutterGemmaDesktop] Plugin registered`），
/// 但本仓用的 `.litertlm` 后端与 llama-binding 路径是否可用**还没验证** ⇒
/// 本轮诚实地记 `unavailable:not-implemented-on-host`，**不假装能用**。
bool get aiPlatformSupported {
  final caps = AppPlatformCapabilities.current();
  return caps.host.isMobile && caps.mayTry(AppCapability.deviceHardwareInfo);
}

/// "自动"引擎：真机 + 已装模型 → 端侧模型；否则兜底。
///
/// 判断是懒的、失败的：探测一次，之后记住结论（探测本身要起原生引擎，
/// 不该每次开弹层都做一遍）。
class AiAutoEngine implements LlmEngine {
  AiAutoEngine();

  final ExtractiveLlmEngine _fallback = ExtractiveLlmEngine();
  GemmaLlmEngine? _gemma;
  LlmEngine? _resolved;

  /// 最近一次探测出来的状态（UI 展示用）
  LlmStatus _last = LlmStatus(
    readiness: AiReadiness.unsupported,
    detail: currentText().aiNotProbed,
  );

  LlmStatus get lastStatus => _last;

  Future<LlmEngine> _pick() async {
    final cached = _resolved;
    if (cached != null) return cached;
    if (!aiPlatformSupported) {
      _last = LlmStatus(
        readiness: AiReadiness.unsupported,
        detail: currentText().aiPlatformExtractive,
      );
      _resolved = _fallback;
      return _fallback;
    }
    final g = _gemma ??= GemmaLlmEngine();
    final st = await g.status();
    _last = st;
    if (st.readiness == AiReadiness.ready) {
      _resolved = g;
      return g;
    }
    // 引擎在、模型没下：**仍然用兜底**（功能不断），另外把状态如实报给 UI
    _resolved = _fallback;
    return _fallback;
  }

  /// 强制重新探测（装完/删完模型后调）
  void invalidate() {
    _resolved = null;
    _gemma = null;
  }

  GemmaLlmEngine get gemma => _gemma ??= GemmaLlmEngine();

  @override
  AiEngineKind get kind => _resolved is GemmaLlmEngine
      ? AiEngineKind.onDeviceModel
      : AiEngineKind.extractive;

  @override
  Future<LlmStatus> status() async {
    await _pick();
    return _last;
  }

  @override
  Stream<String> generate(LlmPrompt prompt) async* {
    final engine = await _pick();
    yield* engine.generate(prompt);
  }

  @override
  Future<void> dispose() async {
    await _gemma?.dispose();
    await _fallback.dispose();
  }
}

/// 服务档位（云端 / 端侧 / 内置摘要）
final aiTierProvider = NotifierProvider<AiTierNotifier, AiTier>(
  AiTierNotifier.new,
);

class AiTierNotifier extends Notifier<AiTier> {
  @override
  AiTier build() => AiTier.cloud;

  Future<void> preload() async {
    final v = AiTier.fromId(await ref.read(settingsServiceProvider).aiTier());
    if (!ref.mounted) return;
    state = v;
  }

  Future<void> select(AiTier v) async {
    state = v;
    await ref.read(settingsServiceProvider).setAiTier(v.id);
  }
}

/// **生效档位**：本机跑不了端侧模型时，端侧档位自动让位给云端。
///
/// 为什么要有它（第 253 轮）：用户可能在一台机器上选过"端侧"，之后换机/降级，
/// 或本机档位判成 `unsupported` —— 那时若还照着存下来的 `onDevice` 走，
/// 引擎会去加载一个本机跑不动的模型（慢、被杀、白耗电）。
/// 这里统一兜住：端侧不可用 ⇒ 按云端走，而云端没配好时
/// [aiEngineProvider] 还会继续降级到"内置摘要"，功能不会消失。
final effectiveAiTierProvider = Provider<AiTier>((ref) {
  final tier = ref.watch(aiTierProvider);
  if (tier == AiTier.onDevice && !ref.watch(aiModuleVisibleProvider)) {
    return AiTier.cloud;
  }
  return tier;
});

/// 端侧引擎（**始终存在**）：装/删模型、列已装模型都走它。
///
/// 它和 [aiEngineProvider] 分开是有原因的：档位切到"云端"时，安装管理仍然要能
/// 操作端侧模型；如果共用一个 provider，"云端档下卸载端侧模型"就会找不到引擎。
final onDeviceEngineProvider = Provider<AiAutoEngine>((ref) {
  final engine = AiAutoEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

/// 当前生效的引擎（按档位挑；云端没配好就自动降级，功能不会消失）
///
/// 降级链：cloud（未配置）→ 端侧模型（没装）→ 内置摘要。
final aiEngineProvider = Provider<LlmEngine>((ref) {
  final tier = ref.watch(effectiveAiTierProvider);
  switch (tier) {
    case AiTier.cloud:
      // 选了云端但还没配好（没填 key/模型）时**降级**，而不是抛错：
      // 助手是"打开就要出东西"的入口，报"云端没配好"等于功能消失。
      // 降级链与端侧档一致：装了端侧模型就用端侧，否则内置摘要。
      final configured = ref.watch(
        cloudSettingsProvider.select((s) => s.configured),
      );
      if (!configured) return ref.watch(onDeviceEngineProvider);
      final engine = CloudLlmEngine(
        // 每次生成都现读配置：用户在设置里改完立刻生效，不用重启
        configOf: () => ref.read(cloudSettingsProvider).config,
      );
      // 推理模型把预算花光时引擎会自动加大重试；这里把新预算**记到设置里**，
      // 下次生成直接用大预算（省掉一次白花的调用和几秒等待）
      engine.onAutoEscalate = (budget) {
        ref.read(cloudSettingsProvider.notifier).setMaxTokens(budget);
      };
      // 每次调用（含自动重试的那次）都记一笔 token/费用 —— 多花的钱要看得见
      engine.onUsage = (record) {
        ref.read(cloudSettingsProvider.notifier).recordUsage(record);
      };
      ref.onDispose(engine.dispose);
      return engine;
    case AiTier.onDevice:
      return ref.watch(onDeviceEngineProvider);
    case AiTier.extractive:
      return ExtractiveLlmEngine();
  }
});

/// 任务服务（UI 只认它）
final aiServiceProvider = Provider<AiService>((ref) {
  return AiService(ref.watch(aiEngineProvider));
});

/// 引擎状态（异步探测一次）
///
/// 注意：`GemmaLlmEngine.status()` 只能报"装了什么"，而用户可能在装了两个
/// 档位之后手动切过 —— 所以这里用**用户选中的档位**覆盖显示名，
/// 免得状态卡说 A、实际用的是 B（真机验证时差点被这个误导）。
final aiReadinessProvider = FutureProvider<LlmStatus>((ref) async {
  final engine = ref.watch(aiEngineProvider);
  final status = await engine.status();
  // ⚠️ 只有**端侧引擎**才需要这个覆盖。云端引擎的 modelName 来自配置，
  // 被端侧模型名盖掉会出现"当前模型：Qwen3 0.6B · 后端 OpenAI 兼容"
  // 这种自相矛盾的状态（真机上就这么显示过）。
  if (engine.kind != AiEngineKind.onDeviceModel) return status;
  final choice = ref.watch(aiModelChoiceProvider);
  final installed = ref.watch(aiInstalledModelsProvider).value ?? const [];
  if (choice == null || !installed.contains(choice.fileName)) return status;
  if (status.readiness != AiReadiness.ready) return status;
  return LlmStatus(
    readiness: status.readiness,
    modelName: choice.displayName,
    modelId: choice.id,
    backend: status.backend,
    detail: status.detail,
  );
}, retry: noRetry);

/// 已装模型文件名列表
final aiInstalledModelsProvider = FutureProvider<List<String>>((ref) async {
  if (!aiPlatformSupported) return const [];
  return ref.watch(onDeviceEngineProvider).gemma.installedFiles();
}, retry: noRetry);

/// 某个模型装没装
final aiModelInstalledProvider = Provider.family<bool, String>((ref, fileName) {
  final list = ref.watch(aiInstalledModelsProvider).value ?? const [];
  return list.contains(fileName);
});

/// 离线保管库里的模型清单（端侧模型页据此显示"重装免下载"徽标）。
///
/// 保管理念见 `model_vault.dart`：模型另外存一份到 `Android/media/<包名>/models`，
/// 卸载/重装 App 不会删掉它 ⇒ 再测端侧功能不用重新下载（省流量）。
final aiVaultEntriesProvider = FutureProvider<List<VaultEntry>>((ref) async {
  if (!aiPlatformSupported) return const [];
  return ModelVault.list();
}, retry: noRetry);

/// 保管库总占用（MB/GB 展示）
final aiVaultBytesProvider = FutureProvider<int>((ref) async {
  if (!aiPlatformSupported) return 0;
  return ModelVault.totalBytes();
}, retry: noRetry);

/// 保管库在手机上的实际路径（诊断用；取不到给空串）
final aiVaultLocationProvider = FutureProvider<String>((ref) async {
  if (!aiPlatformSupported) return '';
  return ModelVault.locationLabel();
}, retry: noRetry);

/// 本机算力画像（**端侧模型按机器而异**的依据）。
///
/// 探测一次、进程内缓存：原生桥只读 `Build`/`/proc`/`EGL`，不做 IO 写。
/// 采集坏了也不抛：`classifyDevice` 对未知值一律保守（档位 `unsupported`）。
final deviceCapabilityProvider = FutureProvider<DeviceCapability>((ref) async {
  return classifyDevice(await probeDeviceCapability());
}, retry: noRetry);

/// 保管库里已有的文件名（用来免掉"存储空间"这条门槛）。
final aiVaultFileNamesProvider = Provider<Set<String>>((ref) {
  final entries = ref.watch(aiVaultEntriesProvider).value ?? const <VaultEntry>[];
  return {for (final e in entries) e.fileName};
});

/// 每个登记过要求的模型在本机的匹配结论（含被挡住的原因）。
final aiModelFitsProvider = Provider<List<AiModelFit>>((ref) {
  final profile = ref.watch(deviceCapabilityProvider).value;
  if (profile == null) return const [];
  return fitModelsFor(profile, vaultFileNames: ref.watch(aiVaultFileNamesProvider));
});

/// 本机可用的模型（界面"推荐"区只列这些）。
final aiEligibleModelsProvider = Provider<List<AiModelInfo>>((ref) {
  return ref
      .watch(aiModelFitsProvider)
      .where((f) => f.eligible)
      .map((f) => f.model)
      .toList();
});

/// **端侧 AI 模块要不要显示** —— 全仓唯一判定入口。
///
/// 两条纪律（第 253 轮踩过坑后定下来的，别改）：
///   ① **有结论时 fail-closed**：画像说 `unsupported`（<3GB / 低内存机 / 核数太少 /
///      非 arm64）⇒ 模块隐藏，不给"点进去必然报错"的入口；
///      ★ 第 145 轮修正：**"内存读不到"不在这一档** —— 那是 `unknown`（未判定），
///      不得当 `unsupported` 用（旧注释把两者混在一起，iOS 就因此被隐藏）；
///   ② **还没结论时不隐藏**：探测是异步 Future，只有一帧之内就回来，但**不得**
///      在"尚未探测"时把端侧档位吞掉 —— 那会让 `effectiveAiTierProvider` 在冷启动的
///      一瞬间把"端侧"悄悄换成云端（`test/cloud_settings_test.dart` 就是因为这个红的）。
///      未探测 ≠ 判定为弱机；真弱机探测完立刻隐藏。
/// 判定规则在 `ai_device_fit.dart`：`tier == unknown`（未判定）⇒ 直接可见；
/// 否则要求"至少有一个模型可用（或只被存储挡住）"。
final aiModuleVisibleProvider = Provider<bool>((ref) {
  final profile = ref.watch(deviceCapabilityProvider).value;
  if (profile == null) return true; // 见 ②
  return aiModuleVisibleFor(profile, vaultFileNames: ref.watch(aiVaultFileNamesProvider));
});

/// 下载/删除模型的控制器（进度 + 错误都在这）
final aiModelInstallProvider =
    NotifierProvider<AiModelInstallNotifier, AiModelInstallState>(
      AiModelInstallNotifier.new,
    );

@immutable
class AiModelInstallState {
  const AiModelInstallState({
    this.modelId = '',
    this.percent = 0,
    this.busy = false,
    this.error = '',
    this.viaMirror = false,
    this.viaVault = false,
  });

  final String modelId;
  final int percent;
  final bool busy;
  final String error;

  /// 正在走 hf-mirror 镜像（直连不通时的兜底）
  final bool viaMirror;

  /// ★ 这次安装是**直接复用本机离线保管库**的模型，没有走网络（省流量）
  final bool viaVault;

  bool get installing => busy && percent < 100;

  AiModelInstallState copyWith({
    String? modelId,
    int? percent,
    bool? busy,
    String? error,
    bool? viaMirror,
    bool? viaVault,
  }) => AiModelInstallState(
    modelId: modelId ?? this.modelId,
    percent: percent ?? this.percent,
    busy: busy ?? this.busy,
    error: error ?? this.error,
    viaMirror: viaMirror ?? this.viaMirror,
    viaVault: viaVault ?? this.viaVault,
  );
}

class AiModelInstallNotifier extends Notifier<AiModelInstallState> {
  @override
  AiModelInstallState build() => const AiModelInstallState();

  /// 下载并安装（进度写进 state；出错记 error 不抛）
  Future<bool> install(AiModelInfo info) async {
    if (state.busy) return false;
    // ★ 硬件门槛守卫（第 253 轮）：界面已经不列不该装的模型，这里再挡一层
    //   —— deep link / 旧偏好 / 云端档位下的误触都绕不过去。
    //   保管库里已有该文件时**不算**存储不足（那是零网络原地装载）。
    final profile = ref.read(deviceCapabilityProvider).value;
    if (profile != null) {
      AiModelFit? fit;
      for (final f in fitModelsFor(
        profile,
        vaultFileNames: ref.read(aiVaultFileNamesProvider),
      )) {
        if (f.model.id == info.id) fit = f;
      }
      if (fit != null && !fit.eligible) {
        state = state.copyWith(
          modelId: info.id,
          // ★ 第 145 轮：fail-closed 但**理由要真**。`tier == unknown`（拿不到本机事实）
          //   时拦下载的原因是"**无法验证是否适配**"，不是"本机硬件不满足要求" ——
          //   后者是"没有数据却给结论"。判据只看 `tier`。
          error: profile.hardwareUndetermined
              ? currentText().aiDeviceModelUnverifiable
              : currentText().aiDeviceModelBlocked,
          busy: false,
        );
        return false;
      }
    }
    if (!aiPlatformSupported) {
      state = state.copyWith(
        modelId: info.id,
        error: currentText().aiPlatformUnsupported,
        busy: false,
      );
      return false;
    }
    state = AiModelInstallState(modelId: info.id, percent: 0, busy: true);
    final engine = ref.read(onDeviceEngineProvider);
    try {
      await for (final p in engine.gemma.install(info)) {
        // 约定（`GemmaLlmEngine.install`）：
        //   `kInstallFromVault`（-1000）= 直接来自**离线保管库**，零网络；
        //   其它负数 = 正在走 hf-mirror 镜像下载。
        final fromVault = p == kInstallFromVault;
        state = state.copyWith(
          percent: fromVault ? 100 : p.abs(),
          busy: !fromVault && p.abs() < 100,
          viaMirror: !fromVault && p < 0,
          viaVault: fromVault,
        );
      }
      engine.invalidate();
      ref.invalidate(aiReadinessProvider);
      ref.invalidate(aiInstalledModelsProvider);
      // 装完（无论是下载还是复用缓存）都刷新保管库视图
      ref.invalidate(aiVaultEntriesProvider);
      ref.invalidate(aiVaultBytesProvider);
      await ref.read(aiModelChoiceProvider.notifier).select(info);
      state = AiModelInstallState(percent: 100, viaVault: state.viaVault);
      return true;
    } catch (e) {
      state = state.copyWith(busy: false, error: _humanize(e));
      return false;
    }
  }

  /// 删掉一个**不在目录里**的历史模型文件（例如换过转换版本后留下的旧档）
  Future<bool> removeOrphan(String fileName) async {
    final engine = ref.read(onDeviceEngineProvider);
    state = AiModelInstallState(modelId: fileName, busy: true);
    try {
      await engine.gemma.uninstallFile(fileName);
      engine.invalidate();
      ref.invalidate(aiReadinessProvider);
      ref.invalidate(aiInstalledModelsProvider);
      // 删的正好是当前档位 ⇒ 选择一起作废（D6；见 `clearIfDeleted` 的注释）
      await ref.read(aiModelChoiceProvider.notifier).clearIfDeleted(fileName);
      state = const AiModelInstallState();
      return true;
    } catch (e) {
      state = state.copyWith(busy: false, error: _humanize(e));
      return false;
    }
  }

  /// 清空离线保管库（用户显式要求"彻底删掉，别占空间"）。
  ///
  /// 返回释放的字节数（0 = 本来就空）。**只删缓存副本**，不影响已装模型。
  Future<int> purgeVaultCache() async {
    final engine = ref.read(onDeviceEngineProvider);
    state = const AiModelInstallState(busy: true);
    try {
      final freed = await engine.gemma.purgeVault();
      ref.invalidate(aiVaultEntriesProvider);
      ref.invalidate(aiVaultBytesProvider);
      state = const AiModelInstallState();
      return freed;
    } catch (e) {
      state = state.copyWith(busy: false, error: _humanize(e));
      return 0;
    }
  }

  Future<bool> remove(AiModelInfo info) async {
    final engine = ref.read(onDeviceEngineProvider);
    state = AiModelInstallState(modelId: info.id, busy: true);
    try {
      await engine.gemma.uninstall(info);
      engine.invalidate();
      ref.invalidate(aiReadinessProvider);
      ref.invalidate(aiInstalledModelsProvider);
      // 删的正好是当前档位 ⇒ 选择一起作废（D6；见 `clearIfDeleted` 的注释）
      await ref.read(aiModelChoiceProvider.notifier).clearIfDeleted(info.id);
      state = const AiModelInstallState();
      return true;
    } catch (e) {
      state = state.copyWith(busy: false, error: _humanize(e));
      return false;
    }
  }

  String _humanize(Object error) {
    // 分类需要原文（只在内部用，不进界面）；
    // 真正给用户的兜底走全仓唯一出口。
    final raw = '$error';
    if (raw.contains('SocketException') || raw.contains('Connection')) {
      return currentText().aiDownloadFailedNetwork;
    }
    if (raw.contains('No space') || raw.contains('ENOSPC')) {
      return currentText().aiDownloadFailedStorage;
    }
    if (raw.contains('403') || raw.contains('401')) {
      return currentText().aiDownloadFailedAuth;
    }
    return currentText().aiDownloadFailed(userFacingError(error));
  }
}

/// 启动时把偏好读进来（`app.dart` 里 preload；`WidgetRef`/`Ref` 都能传）
Future<void> preloadAiSettings(dynamic ref) async {
  await ref.read(aiEnabledProvider.notifier).preload();
  await ref.read(aiWifiOnlyProvider.notifier).preload();
  await ref.read(aiModelChoiceProvider.notifier).preload();
  await ref.read(aiTierProvider.notifier).preload();
  await ref.read(cloudSettingsProvider.notifier).preload();
}

/// 设置服务的便捷入口（给不需要 watch 的地方）
SettingsService settingsOf(dynamic ref) => ref.read(settingsServiceProvider);
