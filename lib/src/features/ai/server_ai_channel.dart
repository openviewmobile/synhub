// NAS 端 AI（AI Console）通道 —— **可选增强**能力位。
//
// 背景（2026-09-21 更正，见 `service_registry.dart` 文件头）：
//   * 本 App 的 AI 是**本机能力**：端侧模型（`on_device_ai.dart`）+
//     自带 key 的云端 LLM（`cloud_engine.dart`）→ **不需要** NAS 服务端 API；
//   * NAS 侧 AI Console（`SYNO.AI.Completion` / `.Thread` / `.Config` /
//     `.Metrics`）登记为 `StationService.ai` 的**可选能力位**；
//   * 因此：缺 `SYNO.AI.Completion` **只隐藏「使用 NAS 的 AI」这一类服务端
//     选项**（本文件门控），AI 模块的端侧 / 云端引擎**照常可用**。
//
// ⚠️ 探针边界：活体探针只证明「方法存在 + 需会话」，**证明不了 `allowUser`**；
// 因此这里只按**能力表存在性**判定，不做任何权限判定（权限走调用错误码回填）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';

/// 服务端 AI 能力快照（纯数据，可离线单测）。
@immutable
class ServerAiChannel {
  const ServerAiChannel({
    required this.completion,
    required this.thread,
    required this.config,
    required this.metrics,
  });

  /// `SYNO.AI.Completion/create` —— 服务端生成通道的**必需位**。
  final bool completion;

  /// `SYNO.AI.Thread/create|delete` —— 服务端会话。
  final bool thread;

  /// `SYNO.AI.Config/get` —— 服务端模型 / provider 配置。
  final bool config;

  /// `SYNO.AI.Metrics/get` —— 服务端用量指标。
  final bool metrics;

  /// 「使用 NAS 的 AI」这一类 UI 是否出现。
  ///
  /// 只有 `SYNO.AI.Completion` 在位才认为服务端生成通道存在；其余三项是
  /// 更细的服务端 UI（会话 / 配置 / 指标）的独立门控位。
  bool get generation => completion;

  /// 这台 NAS 上有没有任何服务端 AI 能力（用于"检测到了"这类提示）。
  bool get any => completion || thread || config || metrics;

  /// 由统一可用性快照构造。`unknown` / `unreachable` / `sessionExpired` 时
  /// [ServiceAvailabilitySnapshot.hasApi] 是 fail-open（返回 true）——
  /// **不因一次网络抖动隐藏服务端选项**。
  static ServerAiChannel of(ServiceAvailabilitySnapshot snapshot) =>
      ServerAiChannel(
        completion: snapshot.hasApi(StationService.ai, kAiCompletionApi),
        thread: snapshot.hasApi(StationService.ai, kAiThreadApi),
        config: snapshot.hasApi(StationService.ai, kAiConfigApi),
        metrics: snapshot.hasApi(StationService.ai, kAiMetricsApi),
      );

  /// 检测到的服务端能力位（API 名，按固定顺序）。用于状态卡展示。
  List<String> get detectedApis => [
    if (completion) kAiCompletionApi,
    if (thread) kAiThreadApi,
    if (config) kAiConfigApi,
    if (metrics) kAiMetricsApi,
  ];
}

/// 服务端 AI 通道的唯一入口；任何"使用 NAS 的 AI"UI 都应 watch 本 provider。
final serverAiChannelProvider = Provider<ServerAiChannel>(
  (ref) => ServerAiChannel.of(ref.watch(serviceAvailabilityProvider)),
);

/// 「NAS AI Console」状态卡。
///
/// 只在服务端生成通道（`SYNO.AI.Completion`）在位时由调用方渲染；缺失即
/// **整体不出现**（模块其余部分照常）。key = `ai-server-channel` 供用例定位。
class ServerAiChannelCard extends ConsumerWidget {
  const ServerAiChannelCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ★ r342 D46：卡片内容现在是**用户文案**，不再依赖具体检测到哪些 API
    //   （是否出现这一整块仍由父级按 `serverAiChannelProvider.generation` 门控；
    //   原始 API 名单在诊断页）。
    final hud = Theme.of(context);
    return Padding(
      key: const Key('ai-server-channel'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.dns_outlined, size: 20, color: hud.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ★ r342 **D46**：这里原来把**检测到的服务端 API 名**直接印给用户
                //   （`channel.detectedApis.join(' · ')` ⇒ 真机上逐字
                //   `SYNO.AI.Completion · SYNO.AI.Thread · SYNO.AI.Config · SYNO.AI.Metrics`）——
                //   与 D39/D40/D43 **同族**：实现细节当用户文案（§2.0.47）。用户既不认识
                //   这些名字，也无法据此做任何操作。改成说清"这一档能干什么"。
                //   ★ 原始 API 名单没有丢：挪到**诊断页**（`features/diagnostics/diag_page.dart`
                //   的「服务端 AI 通道」一行），那才是技术事实该出现的地方。
                // ★ 标题由上一行的段标题承担（同一个 key），卡片只留说明 —— 避免
                //   同一屏出现两遍同一个名字（D44 同族：同一个语义别渲染两次）。
                Text(
                  context.t.aiServerChannelDesc,
                  style: hud.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
