// 设置 → 服务检测（设计 §2.2 安全阀）。
//
// 用户决策："未安装和无权限都需要隐藏" —— 但**隐藏 ≠ 删除**：
// 这一页列出**全部**服务的状态（含被隐藏的）与原因，并提供
// **「重新检测」** 与 **「临时显示隐藏的模块」** 两个安全阀，
// 保证被隐藏的模块永远找得回来、且重测后能从隐藏恢复为可见。
//
// 文案一律走 ARB key（`t.serviceXxx`），状态枚举 → 文案的映射留在本呈现层。
import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../files/file_row.dart' show formatFileTime;
import '../shell/app_tab.dart';
import '../shell/service_gate_pages.dart';
import '../shell/service_text.dart';

/// 服务检测页展示顺序（主槽在前，其余按顶替顺序，最后 ai）。
const List<StationService> kServiceCheckOrder = [
  StationService.chat,
  StationService.file,
  StationService.photo,
  ...kReplacementOrder,
  StationService.office,
  StationService.ai,
];

String _stateLabel(AppText t, AvailabilityState state) => switch (state) {
  AvailabilityState.available => t.serviceStateAvailable,
  AvailabilityState.partial => t.serviceStatePartial,
  AvailabilityState.absent => t.serviceStateAbsent,
  // 多信号检测：信号 1（AppPrivilege）说有 / 信号 2（API 注册）说没有
  // → 如实标注"信号矛盾"，不算未安装（新文案走 dataText，见 service_text.dart）。
  AvailabilityState.uncertain => serviceText(
    'serviceStateUncertain',
    '信号矛盾（保守显示）',
  ),
  AvailabilityState.unauthorized => t.serviceStateUnauthorized,
  AvailabilityState.sessionExpired => t.serviceStateSessionExpired,
  AvailabilityState.unreachable => t.serviceStateUnreachable,
  AvailabilityState.unknown => t.serviceStateUnknown,
};

Color _stateColor(AvailabilityState state, ColorScheme scheme, Color meta) =>
    switch (state) {
      AvailabilityState.available => scheme.primary,
      AvailabilityState.partial => scheme.primary,
      AvailabilityState.absent => meta,
      AvailabilityState.uncertain => scheme.primary,
      AvailabilityState.unauthorized => scheme.error,
      AvailabilityState.sessionExpired => scheme.error,
      AvailabilityState.unreachable => meta,
      AvailabilityState.unknown => meta,
    };

class ServiceCheckPage extends ConsumerWidget {
  const ServiceCheckPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final snapshot = ref.watch(serviceAvailabilityProvider);
    final showHidden = ref.watch(showHiddenServicesProvider);
    final scheme = Theme.of(context).colorScheme;
    final hud = DesignPalette.of(context);
    final checkedAt = snapshot.checkedAt;

    return DesignScaffold(
      appBar: AppBar(
        title: Text(t.serviceCheckTitle),
        actions: [
          IconButton(
            tooltip: t.serviceRecheck,
            onPressed: snapshot.probing
                ? null
                : () =>
                      ref.read(serviceAvailabilityProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          DesignSwitchRow(
            key: const Key('service-show-hidden'),
            value: showHidden,
            onChanged: (v) =>
                ref.read(showHiddenServicesProvider.notifier).set(v),
            title: Text(t.serviceShowHidden),
            subtitle: Text(t.serviceShowHiddenHint),
          ),
          DesignRowTile(
            title: Text(t.serviceRecheck),
            subtitle: Text(
              // 点「重新检测」后、结果回来前要有反馈，否则用户以为没反应。
              snapshot.probing
                  ? t.serviceRechecking
                  : checkedAt == null
                  ? t.serviceNeverChecked
                  // ★ D41（r341 真机）：原来是 `'${checkedAt.toLocal()}'` ⇒ 裸 `DateTime.toString()`
                  // 会把**微秒**画给用户（`2026-10-10 06:37:32.449179`）。时间字段一律走
                  // 全仓唯一的口径 `formatFileTime`（`今天 06:37` / `昨天` / `09-18`；§2.0.44）。
                  : t.serviceLastCheckedAt(
                      formatFileTime(
                        checkedAt.millisecondsSinceEpoch ~/ 1000,
                      ),
                    ),
            ),
            trailing: snapshot.probing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right, size: 18),
            onTap: snapshot.probing
                ? null
                : () =>
                      ref.read(serviceAvailabilityProvider.notifier).refresh(),
          ),
          const SizedBox.shrink(),
          for (final service in kServiceCheckOrder)
            _ServiceRow(
              key: Key('service-row-${service.name}'),
              label: serviceLabelIn(t, service),
              state: snapshot.stateOf(service),
              reason: serviceStateReason(t, service, snapshot.stateOf(service)),
              stateLabel: _stateLabel(t, snapshot.stateOf(service)),
              color: _stateColor(snapshot.stateOf(service), scheme, hud.dim),
              hiddenByPolicy:
                  hidesModule(snapshot.stateOf(service)) && !showHidden,
            ),
        ],
      ),
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    super.key,
    required this.label,
    required this.state,
    required this.reason,
    required this.stateLabel,
    required this.color,
    required this.hiddenByPolicy,
  });

  final String label;
  final AvailabilityState state;
  final String reason;
  final String stateLabel;
  final Color color;
  final bool hiddenByPolicy;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return DesignRowTile(
      leading: Icon(
        hiddenByPolicy ? Icons.visibility_off_outlined : Icons.dns_outlined,
        color: color,
      ),
      title: Row(
        children: [
          Flexible(child: Text(label)),
          const SizedBox(width: Gap.sm),
          Text(
            stateLabel,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (hiddenByPolicy) ...[
            const SizedBox(width: 4),
            Icon(Icons.visibility_off_outlined, size: 13, color: hud.dim),
          ],
        ],
      ),
      subtitle: Text(
        reason,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: hud.dim),
      ),
    );
  }
}
