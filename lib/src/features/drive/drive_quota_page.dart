// Drive 存储空间 / 配额页（wave2）：`SYNO.SynologyDrive.Info:quota` **v2**。
//
// 契约与语义（证据见 [DriveQuotaDto] 顶部注释）：
//   * 无参调用，**必须 v2**（v1 回 103）；
//   * 回包 `share_list[]`，`is_home:true` 那条是**主目录（我的文件）**；
//   * 数值单位 **MiB**；
//   * **`quota <= 0` = 不限额** —— 界面只显示"已使用 X" + "不限额"，
//     **绝不放成 "X / 0 B"**（官方 `[quota] description` 逐字："仅当已为用户
//     设置了配额上限时，才会显示总容量"）。
//
// 能力门控：入口在 [DriveExtrasPage] 里按 `SYNO.SynologyDrive.Info` 能力位隐藏；
// 本页只负责错误态（105/160 → 无权限说明；119/106 → 会话提示；其它 fail-open）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart' show driveHumanSize;
import '../../data/dto/drive_quota_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import 'drive_p0_text.dart';
import 'drive_wave2_providers.dart';
import 'drive_wave2_text.dart';

class DriveQuotaPage extends ConsumerWidget {
  const DriveQuotaPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveQuotaProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-quota-page'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: t.calBack,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        driveWave2(
                          DriveWave2TextKeys.quotaTitle,
                          '存储空间',
                        ),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const Key('drive-quota-refresh'),
                      tooltip: driveWave2(
                        DriveWave2TextKeys.quotaRefresh,
                        '刷新',
                      ),
                      icon: const Icon(Icons.refresh),
                      onPressed: () => ref.invalidate(driveQuotaProvider),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, __) {
                    final gate = driveEntryGate(e);
                    final gated = gate != DriveEntryGate.available;
                    return AppEmptyState(
                      icon: gated ? Icons.block_outlined : Icons.error_outline,
                      title: driveWave2(
                        DriveWave2TextKeys.quotaLoadFailed,
                        '读取存储空间失败',
                      ),
                      message: gated
                          ? driveGateMessage(gate)
                          : describeFileError(e),
                      actionLabel: t.photoRetry,
                      onAction: () => ref.invalidate(driveQuotaProvider),
                    );
                  },
                  data: (quota) {
                    final primary = quota.primary;
                    if (primary == null) {
                      return AppEmptyState(
                        icon: Icons.pie_chart_outline,
                        title: driveWave2(
                          DriveWave2TextKeys.quotaEmpty,
                          '没有可显示的空间配额信息',
                        ),
                        message: driveWave2(
                          DriveWave2TextKeys.quotaEmpty,
                          '没有可显示的空间配额信息',
                        ),
                      );
                    }
                    final others = quota.shares
                        .where((s) => !identical(s, primary) && s.hasQuota)
                        .toList(growable: false);
                    return ListView(
                      padding: const EdgeInsets.only(bottom: Gap.xl),
                      children: [
                        _QuotaCard(share: primary, primary: true),
                        if (others.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              Gap.md,
                              Gap.md,
                              Gap.md,
                              Gap.xs,
                            ),
                            child: Text(
                              driveWave2(
                                DriveWave2TextKeys.quotaOtherShares,
                                '其它文件夹',
                              ),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          for (final s in others) _QuotaCard(share: s),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _QuotaCard extends StatelessWidget {
  const _QuotaCard({required this.share, this.primary = false});

  final DriveQuotaShareDto share;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final label = share.isHome
        ? driveWave2(DriveWave2TextKeys.quotaMyDrive, '我的文件')
        : share.name;
    final usageLine = driveQuotaUsageLine(share, driveHumanSize);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
      child: Card(
        color: hud.surface,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.titleMedium),
              const SizedBox(height: Gap.xs),
              Text(
                usageLine,
                key: primary
                    ? const Key('drive-quota-primary-used')
                    : Key('drive-quota-used-${share.name}'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: Gap.sm),
              if (share.hasQuota)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      key: primary
                          ? const Key('drive-quota-primary-progress')
                          : null,
                      value: share.ratio,
                      minHeight: 4,
                    ),
                    const SizedBox(height: Gap.xs),
                    Text(
                      driveWave2Fill(
                        DriveWave2TextKeys.quotaPercent,
                        '已用 {percent}%',
                        {'percent': '${(100 * share.ratio).round()}'},
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: hud.dim,
                      ),
                    ),
                  ],
                )
              else
                // 不限额：官方不画进度条，只说明"不限额"。
                Text(
                  driveWave2(DriveWave2TextKeys.quotaUnlimited, '不限额'),
                  key: primary
                      ? const Key('drive-quota-primary-unlimited')
                      : Key('drive-quota-unlimited-${share.name}'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: hud.dim,
                  ),
                ),
              if (share.hasShareQuota) ...[
                const SizedBox(height: Gap.sm),
                Text(
                  driveQuotaUsageLine(
                    DriveQuotaShareDto(
                      name: share.name,
                      isHome: share.isHome,
                      quotaMib: share.shareQuotaMib,
                      usedMib: share.shareUsedMib,
                      shareQuotaMib: share.shareQuotaMib,
                      shareUsedMib: share.shareUsedMib,
                      supportPerShareQuota: share.supportPerShareQuota,
                    ),
                    driveHumanSize,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
