// 服务不可用时的呈现件（受限模式首页 + 可操作提示 + 状态原因文案）。
//
// 设计 §2.2 / §2.3：
//   * `absent`（未安装）与 `unauthorized`（无权限）→ **隐藏**主 tab / 工作台入口，
//     可在「设置 → 服务检测」找回；
//   * `sessionExpired`（119/106 会话失效）与 `unreachable`（网络）→ **不隐藏**，
//     进入后显示可操作提示（重新登录 / 重试）。
//
// 文案策略：能复用的既有 ARB key 一律复用；本批新增文案一律走 ARB
// （`t.serviceXxx`），不再有中文字面量。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/app_theme.dart';
import 'app_tab.dart';
import 'service_text.dart';

/// 该服务"没装"时的一句话原因。优先复用既有 ARB key。
String notInstalledReason(AppText t, StationService service) =>
    switch (service) {
      StationService.photo => t.photoErrNotInstalled,
      StationService.note => t.noteErrNotInstalled,
      StationService.contacts => t.contactErrNotInstalled,
      StationService.download => t.dsErrNotInstalled,
      StationService.audio => t.asErrNotInstalled,
      StationService.surveillance => t.survErrNotInstalled,
      StationService.mailplus => t.mailErrNotInstalled,
      StationService.chat => t.chatErrNotInstalled,
      StationService.file => t.fileErrNotInstalled,
      StationService.calendar => t.calErrNotInstalled,
      StationService.drive => t.driveErrNotInstalled,
      StationService.office => t.officeErrNotInstalled,
      StationService.ai => t.aiNotNasService,
    };

/// `unauthorized`（已安装但该账号无权）原因。
///
/// 标题那行已经单独显示 `errNoAppPrivilege`（见 [ServiceStatusHint.forState]），
/// 这里只给"已安装但无权"的正文，避免同一句话重复两遍。
String unauthorizedReason(AppText t) => t.serviceUnauthorizedDetail;

/// `sessionExpired`（119/106）原因。复用 `errSidNotFound`。
String sessionExpiredReason(AppText t) => t.errSidNotFound;

/// `unreachable`（网络）原因。
String unreachableReason(AppText t) => t.dsErrNetwork;

/// 服务检测页 / 提示用：一个状态对应的一句话原因。
String serviceStateReason(
  AppText t,
  StationService service,
  AvailabilityState state,
) => switch (state) {
  AvailabilityState.available => t.serviceStateAvailableReason,
  AvailabilityState.partial => t.serviceStatePartialReason,
  AvailabilityState.absent => notInstalledReason(t, service),
  // 两信号矛盾（MailPlus）：如实说明"保守显示"的取舍，而不是谎称未安装。
  AvailabilityState.uncertain => serviceText(
    'serviceStateUncertainReason',
    '应用权限显示该模块已安装，但没有检测到它注册的接口 —— 按保守策略显示，不隐藏。',
  ),
  AvailabilityState.unauthorized => unauthorizedReason(t),
  AvailabilityState.sessionExpired => sessionExpiredReason(t),
  AvailabilityState.unreachable => unreachableReason(t),
  AvailabilityState.unknown => t.serviceStateUnknownReason,
};

/// 三个主 tab 被隐藏时的标题。
///
/// 全部是"未安装"时沿用设计的"未提供…服务"；含"无权限"时如实说"无法使用"。
String restrictedTitle(
  AppText t,
  List<StationService> hidden,
  Map<StationService, AvailabilityState> states,
) {
  final names = hidden.map((s) => serviceLabelIn(t, s)).join(' / ');
  final allAbsent = hidden.every((s) => states[s] == AvailabilityState.absent);
  return allAbsent
      ? t.serviceRestrictedAbsent(names)
      : t.serviceRestrictedNoAccess(names);
}

/// 主 tab 保留、但服务 `sessionExpired` / `unreachable` 时的可操作提示。
///
/// 用在 `app_shell_page.dart` 的 `_pageFor`：命中这些状态时**直接返回本件**，
/// 不构造模块页（既省资源，也避免模块页在无权限/断网时闪错）。
class ServiceStatusHint extends StatelessWidget {
  const ServiceStatusHint({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  /// 由状态构造标准提示。
  ///
  /// * `sessionExpired` → "会话已过期，请重新登录"（**绝不隐藏**）；
  /// * `unauthorized` → "无权限"（只在安全阀把隐藏模块临时放出来时才会走到）；
  /// * 其它（`unreachable` 等）→ "无法连接 NAS" + 重试。
  factory ServiceStatusHint.forState(
    BuildContext context,
    StationService service,
    AvailabilityState state, {
    required VoidCallback onAction,
  }) {
    final t = context.t;
    switch (state) {
      case AvailabilityState.sessionExpired:
        return ServiceStatusHint(
          icon: Icons.schedule_outlined,
          title: t.serviceSessionExpiredTitle,
          detail: t.serviceSessionExpiredDetail(sessionExpiredReason(t)),
          actionLabel: t.serviceRelogin,
          onAction: onAction,
        );
      case AvailabilityState.unauthorized:
        return ServiceStatusHint(
          icon: Icons.lock_outline,
          title: t.errNoAppPrivilege,
          detail: t.serviceUnauthorizedDetail,
          actionLabel: t.serviceRecheck,
          onAction: onAction,
        );
      default:
        return ServiceStatusHint(
          icon: Icons.cloud_off_outlined,
          title: t.serviceUnreachableTitle,
          detail: t.serviceUnreachableDetail(unreachableReason(t)),
          actionLabel: t.serviceRetry,
          onAction: onAction,
        );
    }
  }

  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: DesignPalette.of(context).dim),
            const SizedBox(height: Gap.md),
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Gap.sm),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Gap.lg),
              FilledButton.tonal(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// **受限模式首页**：三个主服务全被隐藏（未安装 / 无权限）时的主界面。
///
/// 一句话说明 + 可用服务入口 + "重新检测"；仍保留 workspace / me（在底栏）。
class RestrictedHomePage extends ConsumerWidget {
  const RestrictedHomePage({super.key, required this.onOpen});

  /// 打开某个可用服务（由 shell 决定是切 tab 还是推页面）。
  final void Function(StationService service) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final snapshot = ref.watch(serviceAvailabilityProvider);
    final states = snapshot.resolvedStates;
    final hidden = hiddenPrimaryServices(states);
    final available = [
      for (final s in kReplacementOrder)
        if (snapshot.stateOf(s) == AvailabilityState.available) s,
    ];

    return Scaffold(
      backgroundColor: DesignPalette.of(context).bg,
      body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.xl),
            children: [
              Icon(
                Icons.dns_outlined,
                size: 40,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: Gap.md),
              Text(
                restrictedTitle(t, hidden, states),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: Gap.sm),
              for (final service in hidden)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    t.serviceRestrictedReason(
                      serviceLabelIn(t, service),
                      serviceStateReason(t, service, snapshot.stateOf(service)),
                    ),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: DesignPalette.of(context).dim,
                    ),
                  ),
                ),
              const SizedBox(height: Gap.md),
              Text(
                t.serviceRestrictedHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: DesignPalette.of(context).dim,
                ),
              ),
              const SizedBox(height: Gap.lg),
              Row(
                children: [
                  FilledButton.tonalIcon( style: InlineButtonStyle.filled,
                    onPressed: snapshot.probing
                        ? null
                        : () => ref
                              .read(serviceAvailabilityProvider.notifier)
                              .refresh(),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(t.serviceRecheck),
                  ),
                  const SizedBox(width: Gap.md),
                  if (snapshot.probing)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: Gap.lg),
              if (available.isEmpty)
                Text(
                  t.serviceRestrictedNone,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: DesignPalette.of(context).dim,
                  ),
                )
              else
                for (final service in available)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.sm),
                    child: Material(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(Radii.pane),
                      child: DesignRowTile(
                        key: Key('restricted-entry-${service.name}'),
                        leading: Icon(
                          kReplacementTabByService[service]!.icon,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(serviceLabelIn(t, service)),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                        onTap: () => onOpen(service),
                      ),
                    ),
                  ),
            ],
          ),
        ),
    );
  }
}

/// 工作台入口置灰时的原因（`sessionExpired` / `unreachable`）。
///
/// `absent` / `unauthorized` 的入口直接隐藏，不会走到这里。
String? entryDisabledReason(AppText t, AvailabilityState state) =>
    switch (state) {
      AvailabilityState.sessionExpired => t.serviceEntrySessionExpired,
      AvailabilityState.unreachable => t.serviceEntryUnreachable,
      _ => null,
    };
