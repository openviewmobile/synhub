// AI 服务设置页（**三档**：云端大模型 / 端侧模型 / 内置摘要）+ 试用。
//
// 为什么改成"档位制"而不是只做端侧模型：
//   * 实测下来端侧小模型的中文总结能力"形同鸡肋"，主力应该是云端；
//   * 但端侧与内置摘要各自的优点（隐私、离线、零配置）不能丢，
//     所以三档都留着，用户自己选，功能在任何一档下都不会消失；
//   * 云端没配好时 `aiEngineProvider` 会自动降级，不会出现"点了没反应"。
//
// 端侧部分的几个刻意设计（沿用原版思路）：
//   * 说清"模型跑在本机、不联网、不上传" —— 端侧 AI 的卖点就是隐私；
//   * 下载前把**体积**写清楚（几百 MB），并默认"只在 WiFi 下载"；
//   * 试用框：任何档位都能点，能立刻感觉到差别。
import '../../design/kit/design_kit.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/device/device_capability.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import 'ai_cloud_panel.dart';
import 'ai_device_fit.dart';
import 'ai_providers.dart';
import 'ai_service.dart';
import 'ai_usage_page.dart';
import 'cloud_settings.dart';
import 'llm_engine.dart';
import 'model_vault.dart';
import 'on_device_ai.dart';
import 'server_ai_channel.dart';
import '../../core/user_facing_error.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';

class AiModelPage extends ConsumerStatefulWidget {
  const AiModelPage({super.key});

  @override
  ConsumerState<AiModelPage> createState() => _AiModelPageState();
}

class _AiModelPageState extends ConsumerState<AiModelPage> {
  final _probe = TextEditingController();
  String _probeOut = '';
  String _probeEngine = '';
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    trackView(UsageModule.ai, screen: 'model_page');
    // 打开模型页时，把宿主机 push 进"收件箱"的模型搬进保管库
    // （端侧模型很大：能复用就绝不再下一遍）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final engine = ref.read(onDeviceEngineProvider);
      final moved = await engine.gemma.importVaultInbox();
      if (moved > 0 && mounted) {
        ref.invalidate(aiVaultEntriesProvider);
        ref.invalidate(aiVaultBytesProvider);
      }
    });
  }

  @override
  void dispose() {
    _probe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final enabled = ref.watch(aiEnabledProvider);
    final wifiOnly = ref.watch(aiWifiOnlyProvider);
    final readiness = ref.watch(aiReadinessProvider);
    final installed = ref.watch(aiInstalledModelsProvider).value ?? const [];
    final choice = ref.watch(aiModelChoiceProvider) ?? _recommended();
    final install = ref.watch(aiModelInstallProvider);
    // 离线保管库：卡片上打"重装免下载"徽标，并提供"清空缓存"入口
    final vault = ref.watch(aiVaultEntriesProvider).value ?? const <VaultEntry>[];
    final vaultBytes = ref.watch(aiVaultBytesProvider).value ?? 0;
    final vaultPath = ref.watch(aiVaultLocationProvider).value ?? '';

    final tier = ref.watch(effectiveAiTierProvider);
    // 本机算力（第 253 轮）：端侧模型**按机器而异**，硬门槛见 `ai_device_fit.dart`
    final profile = ref.watch(deviceCapabilityProvider).value;
    final moduleVisible = ref.watch(aiModuleVisibleProvider);
    final fits = ref.watch(aiModelFitsProvider);
    final eligible = ref.watch(aiEligibleModelsProvider);
    final cloud = ref.watch(cloudSettingsProvider);

    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        backgroundColor: hud.bg,
        title: Text(context.t.aiServiceTitle),
      ),
      body: ListView(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          children: [
            // 开关
            Material(
              type: MaterialType.transparency,
              child: DesignSwitchRow(
                value: enabled,
                onChanged: (v) => ref.read(aiEnabledProvider.notifier).set(v),
                title: Text(context.t.aiEnable),
                subtitle: Text(context.t.aiEnableHint),
              ),
            ),
            if (tier == AiTier.onDevice)
              Material(
                type: MaterialType.transparency,
                child: DesignSwitchRow(
                  value: wifiOnly,
                  onChanged: (v) =>
                      ref.read(aiWifiOnlyProvider.notifier).set(v),
                  title: Text(context.t.aiWifiOnly),
                  subtitle: Text(context.t.aiWifiOnlyHint),
                ),
              ),

            // 本机能力（第 253 轮）：**先告诉用户这台机器能跑什么**，
            // 而不是把所有模型一股脑列出来。硬件太弱时这里还会说明
            // "端侧档位已隐藏"以及为什么（见 `ai_device_fit.dart`）。
            _capabilityCard(theme, hud, profile, moduleVisible),

            // 档位
            _sectionTitle(theme, hud, context.t.aiWhichTier),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: SegmentedButton<AiTier>(
                segments: [
                  for (final t in AiTier.values)
                    // 本机跑不了端侧模型时，**端侧档位整段不出现**
                    // （用户 2026-09-25：硬件太差就把端侧大模型模块隐藏）
                    if (t != AiTier.onDevice || moduleVisible)
                      ButtonSegment(
                        value: t,
                        label: Text(
                          t.labelIn(context.t),
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                ],
                selected: {tier},
                onSelectionChanged: (v) {
                  trackSelect(
                    UsageModule.ai,
                    switch (v.first) {
                      AiTier.cloud => 'cloud',
                      AiTier.onDevice => 'on_device',
                      AiTier.extractive => 'builtin',
                    },
                    kind: 'model',
                  );
                  ref.read(aiTierProvider.notifier).select(v.first);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
              child: Text(switch (tier) {
                AiTier.cloud =>
                  cloud.configured
                      ? (cloud.model.isEmpty
                            ? context.t.aiTierCloudConfigured(
                                cloud.provider.nameText,
                              )
                            : context.t.aiTierCloudConfiguredModel(
                                cloud.provider.nameText,
                                cloud.model,
                              ))
                      : context.t.aiTierCloudNotConfigured,
                AiTier.onDevice => context.t.aiTierOnDeviceDesc,
                AiTier.extractive => context.t.aiTierExtractiveDesc,
              }, style: theme.textTheme.bodySmall?.copyWith(color: hud.dim)),
            ),

            // NAS 端 AI Console（服务端通道）—— **可选增强**：
            // 只有 `SYNO.AI.Completion` 在位才出现；缺失即整体隐藏，
            // 端侧 / 云端引擎不受影响（见 `server_ai_channel.dart`）。
            if (ref.watch(serverAiChannelProvider).generation) ...[
              // ★ r342 D46：段标题原来是硬编码英文 `'NAS AI Console'` ⇒ 中文界面里
              //   一行英文（§2.0.13 同型）。改成与卡片同源的本地化串。
              _sectionTitle(theme, hud, context.t.aiServerChannelTitle),
              const ServerAiChannelCard(),
            ],

            // ★ 第 255 轮：相册「AI 美化（图生图）」的设置卡**已从这里移走**
            // （用户 2026-09-25：「图生图设置怎么和大语言模型设置混在一起了？
            // 能否拆开独立配置？」）。它现在有独立的入口与页面：
            //   设置 → 隐私 → AI 美化（图生图）
            //   → `features/photos/photo_ai_edit_settings_page.dart`
            // 本页只留"聊天用哪个模型"（档位 / 云端 / 端侧目录 / NAS AI Console）。

            if (tier == AiTier.cloud) ...[
              _sectionTitle(theme, hud, context.t.aiCloudConfig),
              const AiCloudPanel(),
              _sectionTitle(theme, hud, context.t.aiUsageTitle),
              _usageTile(theme, hud, cloud),
            ] else if (tier == AiTier.onDevice) ...[
              _sectionTitle(theme, hud, context.t.aiOnDeviceConfig),
            ] else
              _sectionTitle(theme, hud, context.t.aiExtractiveTitle),

            // 状态（跟随当前档位）
            _card(
              theme,
              hud,
              icon: switch (tier) {
                AiTier.cloud => Icons.cloud_outlined,
                AiTier.onDevice => Icons.memory,
                AiTier.extractive => Icons.bolt,
              },
              // 档位不同，"就绪"的含义不同：云端是"网络那侧配好了"，
              // 端侧是"模型在本机装好了"。写死"端侧模型就绪"会在云端档自相矛盾。
              title: readiness.when(
                data: (s) => _statusTitle(context.t, tier, s),
                loading: () => context.t.aiChecking,
                error: (e, __) => context.t.aiCheckFailed(userFacingError(e)),
              ),
              body: readiness.maybeWhen(
                data: (s) => s.readiness == AiReadiness.ready
                    ? (s.backend.isEmpty
                          ? context.t.aiCurrentModel(
                              s.modelName.isEmpty
                                  ? context.t.aiInstalled
                                  : s.modelName,
                            )
                          : context.t.aiCurrentModelBackend(
                              s.modelName.isEmpty
                                  ? context.t.aiInstalled
                                  : s.modelName,
                              s.backend,
                            ))
                    : (s.detail.isEmpty
                          ? context.t.aiModelLocalOnly
                          : s.detail),
                orElse: () => context.t.aiModelLocalOnly,
              ),
              child: readiness.maybeWhen(
                data: (s) => s.readiness == AiReadiness.unsupported
                    ? Text(
                        context.t.aiUnsupportedHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hud.dim,
                        ),
                      )
                    : null,
                orElse: () => null,
              ),
            ),

            // 端侧目录只在端侧档位显示；切到云端时页面别塞一堆用不上的东西
            if (tier == AiTier.onDevice && moduleVisible) ...[
              _sectionTitle(theme, hud, context.t.aiModelTiers),
              // ★ 只列**本机跑得动**的：不同手机看到不同模型是设计要求，
              //   不是过滤 bug（用户 2026-09-25）。
              for (final m in eligible) ...[
                _modelCard(theme, hud, m, installed, install, choice, vault),
              ],
              // 被硬件挡住的模型：不混进推荐区，但**说清楚为什么**
              // （藏着不说 = 用户以为我们少了模型）
              ..._blockedModels(theme, hud, fits, profile),

              // 换过转换版本后留下的历史文件：目录里已经没有它们，
              // 但还占着几百 MB（真机验证时踩到过：旧 Qwen3 文件白占 614MB）
              ..._orphanFiles(theme, hud, installed),

              // 离线保管库（省流量的关键）：说清"模型另存了一份、
              // 卸载重装不会被删"，并给一个显式的"清空"入口。
              _vaultCard(theme, hud, vaultBytes, vaultPath),

              _sectionTitle(theme, hud, context.t.aiWhyLocal),
              _card(
                theme,
                hud,
                icon: Icons.lock_outline,
                title: context.t.aiTextStaysLocal,
                body: context.t.aiTextStaysLocalBody,
              ),
            ] else if (tier == AiTier.extractive)
              _card(
                theme,
                hud,
                icon: Icons.bolt,
                title: context.t.aiNoConfigNeeded,
                body: context.t.aiNoConfigNeededBody,
              ),

            _sectionTitle(theme, hud, context.t.aiTryIt),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _probe,
                    maxLines: 4,
                    minLines: 2,
                    decoration: InputDecoration(
                      hintText: context.t.aiTryHint,
                      filled: true,
                      fillColor: hud.surface2,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: hud.line),
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  Row(
                    children: [
                      // ⚠️ 主题里 FilledButton 的 minimumSize 是 `Size.fromHeight(48)`
                      // （全宽按钮），放进 Row 必须给宽度，否则渲染层直接报
                      // "BoxConstraints forces an infinite width"
                      SizedBox(
                        width: 132,
                        child: FilledButton.icon(
                          onPressed: _probing ? null : _runProbe,
                          icon: _probing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.play_arrow, size: 18),
                          label: Text(context.t.aiTryAction),
                        ),
                      ),
                      const SizedBox(width: Gap.sm),
                      if (_probeEngine.isNotEmpty)
                        Text(
                          _probeEngine,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                    ],
                  ),
                  if (_probeOut.isNotEmpty) ...[
                    const SizedBox(height: Gap.sm),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(Gap.md),
                      decoration: BoxDecoration(
                        color: hud.surface2,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: hud.line),
                      ),
                      child: SelectableText(
                        _probeOut,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: Gap.xl),
          ],
        ),
    );
  }

  /// 状态卡的标题：把"哪一档"和"什么状态"分开说
  String _statusTitle(AppText t, AiTier tier, LlmStatus s) {
    if (s.readiness != AiReadiness.ready) return s.readiness.labelIn(t);
    return switch (tier) {
      AiTier.cloud => t.aiCloudReady,
      AiTier.onDevice => t.aiOnDeviceReady,
      AiTier.extractive => t.aiExtractiveReady,
    };
  }

  /// 「用量与费用」入口：一行摘要 + 点进去看按模型/按日期的汇总
  ///
  /// 摘要里明确带"本地估算"的口径由详情页负责；这里给的是本机记录的数字。
  Widget _usageTile(ThemeData theme, DesignPalette hud, CloudSettings cloud) {
    final t = cloud.usageSummary.overall;
    final cost = (t.unpricedCalls > 0 && t.costUsd == 0)
        ? context.t.aiUsageCostUnknown
        : t.costUsd == 0
        ? context.t.aiUsageCost('US\$0')
        : context.t.aiUsageCost(
            'US\$${t.costUsd < 0.01 ? t.costUsd.toStringAsFixed(4) : t.costUsd.toStringAsFixed(2)}',
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Material(
        color: hud.surface,
        borderRadius: BorderRadius.circular(12),
        child: DesignRowTile(
          onTap: () => Navigator.of(
            context,
          ).push<void>(MaterialPageRoute(builder: (_) => const AiUsagePage())),
          leading: Icon(
            Icons.receipt_long_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          title: Text(
            context.t.aiUsageEntry,
            style: theme.textTheme.bodyMedium,
          ),
          subtitle: Text(
            t.calls == 0
                ? context.t.aiUsageEmptyHint
                : '${context.t.aiUsageCalls(t.calls)} · '
                      '${context.t.aiUsageTotalTokens(t.totalTokens)} · $cost',
            style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
        ),
      ),
    );
  }

  /// 推荐档：**先在本机可用的模型里找**（第 253 轮）。
  ///
  /// 一台 4GB 机器上"推荐档"必须是 LFM 230M，而不是目录里标了 recommended
  /// 但本机跑不动的 Qwen —— 那正是用户说的"不能所有手机推同一套模型"。
  AiModelInfo _recommended() {
    final eligible = ref.read(aiEligibleModelsProvider);
    for (final m in eligible) {
      if (m.recommended) return m;
    }
    if (eligible.isNotEmpty) return eligible.first;
    // 本机一个都跑不了（模块已隐藏）：仍回落到目录里的推荐档，
    // 避免 `!` 空断言；这个值只用于"没有偏好"时的占位显示。
    for (final m in kOnDeviceModels) {
      if (m.recommended) return m;
    }
    return kOnDeviceModels.first;
  }

  Future<void> _runProbe() async {
    final text = _probe.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _probing = true;
      _probeOut = '';
      _probeEngine = '';
    });
    final service = ref.read(aiServiceProvider);
    try {
      final answer = await service.run(
        AiRequest(
          kind: AiTaskKind.summary,
          text: text,
          title: context.t.aiTryIt,
          maxOutputTokens: 256,
        ),
      );
      trackOnce(
        UsageModule.ai,
        UsageAction.complete,
        objectType: AiTaskKind.summary.id,
        detail: {UsageDetailKeys.kind: service.engineKind.id},
      );
      if (!mounted) return;
      setState(() {
        _probeOut = answer.text;
        _probeEngine =
            '${answer.engine.labelIn(context.t)}'
            '${answer.modelName.isEmpty ? '' : ' · ${answer.modelName}'}'
            ' · ${answer.elapsedMs}ms';
      });
    } on AiFailure catch (e) {
      // 失败只记异常类型当原因码，绝不记 message（可能带 host/key）
      trackOnceFailure(
        UsageModule.ai,
        UsageAction.complete,
        objectType: AiTaskKind.summary.id,
        reason: e.runtimeType.toString(),
        error: e,
      );
      if (!mounted) return;
      setState(() => _probeOut = context.t.aiProbeFailed(e.message));
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Widget _sectionTitle(ThemeData theme, DesignPalette hud, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.lg, Gap.md, Gap.sm),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(color: hud.dim),
      ),
    );
  }

  /// 本机能力卡：SoC / 内存 / 存储 / GPU / NPU / 档位 + （必要时）隐藏说明。
  Widget _capabilityCard(
    ThemeData theme,
    DesignPalette hud,
    DeviceCapability? profile,
    bool moduleVisible,
  ) {
    final t = context.t;
    if (profile == null) {
      return _card(
        theme,
        hud,
        icon: Icons.memory,
        title: t.aiDeviceCapabilityTitle,
        body: t.aiChecking,
      );
    }
    // ★ r131/r133（macOS+Linux 走查实拍）：桌面宿主上 `classifyDevice` 回的是
    //   `ungatedHost: true` + `tier == DeviceComputeTier.unknown`（**未判定**；
    //   r133 之前这里硬编码的是占位档位 `mainstream`）+ 空快照。
    //   原来照原样画，像素就成了「Tier Mainstream / SoC — / RAM 0 MB /
    //   Free storage 0 MB / GPU No OpenCL detected / NPU No NNAPI」——
    //   一边给出档位结论，一边全是取不到值的占位，自相矛盾。
    //   口径（AGENTS §2.0.6③）：宿主上**不判档、不编数字**，如实说明；
    //   模块**照旧可见**（宿主不门控，`moduleVisible` 由 `ungatedHost` 保证），
    //   所以这里只改「怎么说」，不改可见性。
    final host = profile.ungatedHost;
    // ★ r132（iOS 逐屏走查实拍）：iOS 上既没有 `/proc/meminfo`、也还没有硬件桥
    //   ⇒ 快照里全是 0，像素就成了「Tier Unsupported / RAM 0 MB / Free storage
    //   0 MB / GPU No OpenCL」，隐藏说明还写「本机只有 0 GB 内存」——
    //   把**探测失败**说成了**设备事实**。与 r131 的宿主口径一致（AGENTS §2.0.6②③）：
    //   读不到就画 `—`、并如实说明"该平台没提供硬件信息"，**不编数字**。
    //   模块仍然隐藏（iOS 没有端侧引擎，隐藏是对的，错的只是"为什么"）。
    // ★ "读不到事实"只有**一个**判据：`profile.ramUnknown`（快照层：内存读不到）。
    //   宿主天然在内（宿主快照 RAM 就是 0）⇒ **不要**再叠一个 `host || …` 的局部
    //   布尔，那正是"同一语义两套表示"（AGENTS §2.0.26）。
    //   ★ `ramUnknown` 与 `tier == DeviceComputeTier.unknown` 不是一回事：
    //     * `tier == unknown` = 整机**不下结论**（只有宿主，`ungatedHost`）；
    //     * `ramUnknown`      = **内存事实没读到**（宿主，或移动端没有硬件桥，如 iOS）。
    //   非宿主但读不到内存**不再**判 `unsupported`：`_ramBaselineTier(0)`
    //   回 `unknown`（§2.0.6②：探测失败 ≠ 硬件不行）⇒ **不隐藏**，界面照
    //   `ramUnknown` 画 `—`；这里只改"怎么说"，不改门控。
    final rows = <List<String>>[
      [
        t.aiDeviceTierLabel,
        profile.ramUnknown ? '—' : _tierLabel(t, profile.tier),
      ],
      [
        t.aiDeviceSocLabel,
        profile.ramUnknown || profile.socLabel.isEmpty ? '—' : profile.socLabel,
      ],
      [
        t.aiDeviceRamLabel,
        profile.ramUnknown ? '—' : _bytes(profile.totalRamBytes),
      ],
      [
        t.aiDeviceStorageLabel,
        profile.ramUnknown ? '—' : _bytes(profile.freeStorageBytes),
      ],
      [
        t.aiDeviceGpuLabel,
        profile.ramUnknown || profile.gpuLabel.isEmpty
            ? (profile.ramUnknown ? '—' : t.aiDeviceGpuNone)
            : '${profile.gpuLabel}${profile.snapshot.openclLibrary ? ' · OpenCL' : ''}',
      ],
      [
        t.aiDeviceNpuLabel,
        profile.ramUnknown
            ? '—'
            : switch (profile.npuClass) {
                NpuClass.none => t.aiDeviceNpuNone,
                NpuClass.nnapiOnly => t.aiDeviceNpuNnapi,
                NpuClass.vendorSpecific => t.aiDeviceNpuVendor,
              },
      ],
    ];
    return _card(
      theme,
      hud,
      // ★ 这个 key 是给回归用例用的：宿主上"不许编数字"只能在**这张卡内**断言，
      //   页面别处也有合法的 `0 MB`（模型体积），全页扫会误报。
      key: const Key('ai-device-capability-card'),
      icon: Icons.memory,
      title: t.aiDeviceCapabilityTitle,
      body: t.aiDeviceCapabilityHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: Gap.sm),
          // ★ r133（Linux 2560x1440 像素）：标签列原来是写死的 `SizedBox(width: 76)`，
          //   装不下最长的英文标签「Free storage」（其余五个标签都在 76 内，
          //   所以**只有它**折成两行）。改用 `IntrinsicColumnWidth`：标签列按
          //   **最长标签**自己定宽 ⇒ 任何语言都不折行，也不必为某个语种硬编码宽度
          //   （更不许改字号，见 AGENTS §2.0.18）。
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.top,
            children: [
              for (final r in rows)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.sm, bottom: 2),
                      child: Text(
                        r[0],
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hud.dim,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(r[1], style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
            ],
          ),
          // ★ r448：这份画像来自 **QA 诊断文件**（`qa_device_capability.json`）时
          //   必须**明说**——这张卡的全部意义就是"如实说本机是什么"，
          //   拿一张合成画像冒充真实硬件，比不显示更糟（r131/r132/r133 同族教训）。
          //   判据只有一个：`snapshot.syntheticProfile`（＝ `source == 'synthetic'`）。
          if (profile.snapshot.syntheticProfile) ...[
            const SizedBox(height: Gap.sm),
            Text(
              t.aiDeviceSyntheticProfile,
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          ],
          if (host) ...[
            const SizedBox(height: Gap.sm),
            Text(
              t.aiDeviceHostUnknown,
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          ] else if (profile.ramUnknown) ...[
            // 手机宿主但探不到硬件（r132：iOS）⇒ 如实说是"读不到"，不是"太弱"。
            const SizedBox(height: Gap.sm),
            Text(
              t.aiDeviceProbeUnknown,
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          ],
          if (!moduleVisible) ...[
            const SizedBox(height: Gap.sm),
            Container(
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: hud.line),
                color: hud.surface,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.visibility_off_outlined, size: 16, color: hud.dim),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          t.aiDeviceModuleHidden,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.aiDeviceModuleHiddenBody(_hiddenReason(profile)),
                    style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 被硬件挡住的模型：单独一段列出来 + 说明原因（不混进推荐区）。
  List<Widget> _blockedModels(
    ThemeData theme,
    DesignPalette hud,
    List<AiModelFit> fits,
    DeviceCapability? profile,
  ) {
    final blocked = fits.where((f) => !f.eligible).toList();
    if (blocked.isEmpty) return const [];
    return [
      _sectionTitle(
        theme,
        hud,
        // ★ 第 145 轮：`unknown` 时连**段标题**都不许下"不适用"的判词
        //   （我们是"没法验证"，不是"验过了、不行"）。
        (profile != null && profile.hardwareUndetermined)
            ? context.t.aiBlockedModelsTitleUndetermined(blocked.length)
            : context.t.aiBlockedModelsTitle(blocked.length),
      ),
      for (final f in blocked)
        _card(
          theme,
          hud,
          icon: Icons.block_outlined,
          title: f.model.displayName,
          body: _blockedReason(profile, f),
        ),
    ];
  }

  String _blockedReason(DeviceCapability? p, AiModelFit f) {
    final t = context.t;
    // ★ 第 145 轮：**未判定 ≠ 不够**。`tier == unknown` 时一个判词都不许出现 ——
    //   「机器档位不足」「内存不足（需 X 本机 0 GB）」「本机不适配」全是"没有数据却给结论"
    //   （§2.0.26），而且那个 `0 GB` 就是 B2。判据只认 `tier`，所以在这里**一处收口**，
    //   不管将来 `_fitOne` 再加什么 blocker，都不可能漏出判词。
    if (p != null && p.hardwareUndetermined) {
      return t.aiBlockedReasonUndetermined;
    }
    final parts = <String>[];
    for (final b in f.blockers) {
      parts.add(switch (b) {
        AiFitBlocker.moduleHidden => t.aiBlockedReasonModuleHidden,
        AiFitBlocker.tier => t.aiBlockedReasonTier,
        AiFitBlocker.ram => t.aiBlockedReasonRam(
          _gbText(f.requiredRamBytes),
          _gbText(p?.totalRamBytes ?? 0),
        ),
        AiFitBlocker.storage => t.aiBlockedReasonStorage(
          _bytes(f.requiredStorageBytes),
          _bytes(p?.freeStorageBytes ?? 0),
        ),
        AiFitBlocker.npu => t.aiBlockedReasonNpu,
      });
    }
    return parts.join(t.holidayNoteSep);
  }

  /// 为什么整块被隐藏（逐条否决原因，如实列出）。
  String _hiddenReason(DeviceCapability p) {
    final t = context.t;
    final s = p.snapshot;
    final parts = <String>[];
    if (s.lowRamDevice) parts.add(t.aiDeviceVetoLowRam);
    if (s.cpuCores > 0 && s.cpuCores <= kMinSupportedCores) {
      parts.add(t.aiDeviceVetoCores(s.cpuCores));
    }
    if (s.abis.isNotEmpty && !s.abis.contains('arm64-v8a')) {
      parts.add(t.aiDeviceVetoAbi);
    }
    if (p.ramUnknown) {
      // 内存没读到 ⇒ 不能说"本机只有 0 GB"（r132：iOS 逐屏走查）。原因照实写。
      parts.add(t.aiDeviceProbeUnknown);
    } else if (s.totalRamBytes < kMinSupportedRamBytes) {
      parts.add(t.aiDeviceVetoRam(_gbText(s.totalRamBytes)));
    }
    if (parts.isEmpty) parts.add(t.aiBlockedReasonModuleHidden);
    return parts.join(t.holidayNoteSep);
  }

  String _tierLabel(AppText t, DeviceComputeTier tier) => switch (tier) {
    // `unknown` = 没有事实、不下结论（宿主/探不到）⇒ 画 `—`（同枚举里的口径）。
    DeviceComputeTier.unknown => '—',
    DeviceComputeTier.unsupported => t.aiDeviceTierUnsupported,
    DeviceComputeTier.entry => t.aiDeviceTierEntry,
    DeviceComputeTier.mainstream => t.aiDeviceTierMainstream,
    DeviceComputeTier.high => t.aiDeviceTierHigh,
    DeviceComputeTier.flagship => t.aiDeviceTierFlagship,
  };

  static String _gbText(int bytes) {
    if (bytes <= 0) return '0';
    final gb = bytes / (1024 * 1024 * 1024);
    return gb >= 10 ? gb.toStringAsFixed(0) : gb.toStringAsFixed(1);
  }

  /// 字节 → 人类可读。**`<= 0` 一律 `—`**：这个字段的 `0` 是"取不到"，
  /// 不是"真的是 0"，画成 `0 MB` 等于编了一个测量值（B2；iOS D5 同症）。
  /// 能力卡那两行另有 `ramUnknown` 兜底，这里再兜一层是给"内存读到了、
  /// 但存储没读到"的情况（`StatFs` 失败 / 分区取不到）。
  static String _bytes(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).round()} MB';
  }

  Widget _card(
    ThemeData theme,
    DesignPalette hud, {
    required IconData icon,
    required String title,
    required String body,
    Widget? child,
    Key? key,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: hud.line, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                  ),
                  if (child != null) ...[const SizedBox(height: Gap.xs), child],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 目录外的历史模型文件（可删）
  /// 离线保管库卡片：占用 + 位置 + 一键清空。
  ///
  /// 为什么值得在 UI 里露出来：模型动辄几百 MB，用户删掉模型页上的条目
  /// （`remove`）**不会**动这份缓存 —— 必须给一个看得见、点得到的清空入口，
  /// 否则那几百 MB 就成了"删不掉的隐形占用"。
  Widget _vaultCard(
    ThemeData theme,
    DesignPalette hud,
    int bytes,
    String path,
  ) {
    final size = bytes >= 1024 * 1024 * 1024
        ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
        : '${(bytes / (1024 * 1024)).round()} MB';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: hud.line, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.inventory_2_outlined, size: 18, color: hud.dim),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    context.t.aiVaultPurge,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Text(
                  bytes > 0 ? size : '0 MB',
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              context.t.aiVaultHint,
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
            if (path.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                context.t.aiVaultLocation(path),
                style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
              ),
            ],
            if (bytes > 0) ...[
              const SizedBox(height: Gap.xs),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    final freed = await ref
                        .read(aiModelInstallProvider.notifier)
                        .purgeVaultCache();
                    if (!mounted) return;
                    final human = freed >= 1024 * 1024 * 1024
                        ? '${(freed / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
                        : '${(freed / (1024 * 1024)).round()} MB';
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.t.aiVaultPurged(human))),
                    );
                  },
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: Text(context.t.aiVaultPurge),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _orphanFiles(
    ThemeData theme,
    DesignPalette hud,
    List<String> installed,
  ) {
    final known = {for (final m in kOnDeviceModels) m.fileName};
    final orphans = installed.where((f) => !known.contains(f)).toList();
    if (orphans.isEmpty) return const [];
    final install = ref.watch(aiModelInstallProvider);
    return [
      _sectionTitle(theme, hud, context.t.aiOrphanFiles),
      for (final f in orphans)
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
          child: Material(
            color: hud.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: hud.line, width: 1),
            ),
            child: DesignRowTile(
              title: Text(f, style: theme.textTheme.bodySmall),
              subtitle: Text(
                context.t.aiOrphanBody,
                style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
              ),
              trailing: TextButton(
                onPressed: install.busy
                    ? null
                    : () => ref
                          .read(aiModelInstallProvider.notifier)
                          .removeOrphan(f),
                child: Text(context.t.dtoActionDelete),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _modelCard(
    ThemeData theme,
    DesignPalette hud,
    AiModelInfo m,
    List<String> installed,
    AiModelInstallState install,
    AiModelInfo choice,
    List<VaultEntry> vault,
  ) {
    // 插件回的是文件名，但历史上也回过 id（`llm_engine._installed()` 两个都认）
    // ⇒ 这里用同一判据：只认文件名的话，"已装"会被判成"没装"，
    //   `In use` 徽标就会在**该出现的时候**消失（D6 的正向口径）。
    final has = installed.contains(m.fileName) || installed.contains(m.id);
    // 这份模型在离线保管库里有一份 ⇒ 卸载重装后不用再下载
    final cached = vault.any((e) => e.fileName == m.fileName);
    final busyThis = install.modelId == m.id && install.busy;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: has ? theme.colorScheme.primary : hud.line,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(m.displayName, style: theme.textTheme.bodyMedium),
                ),
                if (m.recommended)
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.xs),
                    child: Text(
                      context.t.aiRecommended,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                Text(
                  m.sizeLabel,
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              m.noteIn(context.t),
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
            if (cached) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.offline_pin_outlined, size: 14, color: hud.dim),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      context.t.aiVaultBadge,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: hud.dim,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (busyThis) ...[
              const SizedBox(height: Gap.sm),
              LinearProgressIndicator(
                value: install.percent <= 0 ? null : install.percent / 100,
              ),
              const SizedBox(height: 4),
              Text(
                install.viaVault
                    // ★ 走的是本机离线缓存：明确写出来，让用户知道没费流量
                    ? context.t.aiVaultReused
                    : install.viaMirror
                    ? context.t.aiDownloadingMirror(install.percent)
                    : context.t.aiDownloading(install.percent),
                style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
              ),
            ],
            if (install.modelId == m.id && install.error.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(
                install.error,
                style: theme.textTheme.bodySmall?.copyWith(color: hud.danger),
              ),
            ],
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                // 同上：全宽按钮要自己收窄（下载/删除占满剩余空间）
                Expanded(
                  child: has
                      ? OutlinedButton.icon(
                          onPressed: busyThis
                              ? null
                              : () => ref
                                    .read(aiModelInstallProvider.notifier)
                                    .remove(m),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: Text(context.t.dtoActionDelete),
                        )
                      : FilledButton.icon(
                          onPressed: busyThis
                              ? null
                              : () {
                                  trackSelect(
                                    UsageModule.ai,
                                    m.id,
                                    kind: 'model',
                                  );
                                  trackOnce(
                                    UsageModule.ai,
                                    UsageAction.download,
                                    objectType: m.id,
                                  );
                                  ref
                                      .read(aiModelInstallProvider.notifier)
                                      .install(m);
                                },
                          icon: const Icon(Icons.download_outlined, size: 18),
                          label: Text(context.t.aiDownload(m.sizeLabel)),
                        ),
                ),
                const SizedBox(width: Gap.sm),
                TextButton(
                  // 可观测点（D6 回归用）：这一行到底是"在使用中"还是"设为当前"
                  key: Key('ai-model-choice-${m.id}'),
                  onPressed: () {
                    trackSelect(UsageModule.ai, m.id, kind: 'model');
                    ref.read(aiModelChoiceProvider.notifier).select(m);
                  },
                  child: Text(
                    // ★ D6（r121 审计 `ai_11_ond.png`）：`In use` 必须**同时**满足
                    //   "这份模型在本机"（`has`）与"它是当前档位"（`choice`）。
                    //   只判 `choice.id == m.id` 时，删掉模型后行内照样写 `In use`，
                    //   和页首"还没有下载模型"直接打架 —— 页首说的是"文件在不在这台
                    //   机器上"，行内说的却只是"档位指针指向谁"，两种语义被混成了一个词。
                    has && choice.id == m.id
                        ? context.t.aiInUse
                        : context.t.aiSetCurrent,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
