// 「设置 → 使用分析 → 网络流量」子页（第 276 轮）。
//
// 这一页回答用户的问题：**哪个模块在什么时段吃掉了多少流量**。
// 四条展示纪律（对应 `docs/network-traffic-analytics.md`）：
//   * **精确 / 估算分栏**：`exact` = Dart HTTP 客户端按流实测；`estimated` =
//     原生播放器绕过 Dart、用系统 UID 计数在活动会话窗口差分。两者绝不合并；
//   * **未归属单独列**：没打模块标签的那一份必须看得见，不能靠"只加钩到的"
//     把总量做漂亮；
//   * **与系统计数对比**：本 App 归属量 vs 系统 UID 合计，差额如实展示
//     （"未计入"），不做假账；
//   * **诚实空态**：没数据就说没数据，并说清两个档位分别要什么才会出现。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/net/traffic_meter.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/user_facing_error.dart';
import 'analytics_labels.dart';
import 'analytics_providers.dart';
import 'traffic_analysis.dart';
import 'usage_event.dart';

class TrafficPage extends ConsumerStatefulWidget {
  const TrafficPage({super.key});

  @override
  ConsumerState<TrafficPage> createState() => _TrafficPageState();
}

class _TrafficPageState extends ConsumerState<TrafficPage> {
  Duration _window = const Duration(days: 7);
  TrafficDirection? _direction;

  @override
  void initState() {
    super.initState();
    // 「系统对比」需要一个基线（App 启动时已存；万一没有，打开这一页补一个）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final log = ref.read(trafficLogProvider);
      if (await log.osBaseline() == null) {
        final snap = await ref.read(deviceTrafficProbeProvider).snapshot();
        if (snap != null) await log.saveOsBaseline(snap.toJson());
      }
      if (mounted) ref.invalidate(trafficWindowProvider(_window));
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final async = ref.watch(trafficWindowProvider(_window));

    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.md,
                  Gap.sm,
                  Gap.sm,
                  Gap.sm,
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: t.calBack,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.trafficTitle, style: theme.textTheme.titleLarge),
                          Text(
                            t.trafficSubtitle,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: hud.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: t.usageRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () {
                        ref.invalidate(trafficWindowProvider(_window));
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(Gap.md),
                    child: AppListSkeleton(rows: 5),
                  ),
                  error: (e, __) => AppErrorView(
                    key: const Key('traffic-error'),
                    title: t.trafficLoadFailed,
                    detail: userFacingError(e),
                    onRetry: () => ref.invalidate(trafficWindowProvider(_window)),
                  ),
                  data: (stats) => ListView(
                    padding: const EdgeInsets.only(bottom: Gap.xl),
                    children: [
                      _RangeBar(
                        window: _window,
                        onChanged: (w) => setState(() => _window = w),
                      ),
                      if (stats.isEmpty && stats.osBaselineAt == null)
                        AppEmptyState(
                          key: const Key('traffic-empty'),
                          icon: Icons.network_check_outlined,
                          title: t.trafficEmptyTitle,
                          message: t.trafficEmptyMessage,
                        )
                      else ...[
                        _SummaryCard(stats: stats),
                        _OsCard(stats: stats),
                        if (!stats.isEmpty) ...[
                          _Header(text: t.trafficSectionRanking, hud: hud),
                          _DirectionBar(
                            value: _direction,
                            onChanged: (d) => setState(() => _direction = d),
                          ),
                          _RankingList(stats: stats, direction: _direction),
                          _Header(text: t.trafficSectionHours, hud: hud),
                          _HoursChart(stats: stats),
                        ],
                      ],
                      _Header(text: t.trafficExact, hud: hud),
                      _Note(text: t.trafficExactPaths, hud: hud),
                      _Note(text: t.trafficEstimatedPaths, hud: hud),
                      _Note(text: t.trafficPrivacyNote, hud: hud),
                      _Note(text: t.trafficStorageNote, hud: hud),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

/// 日 / 周切换 + 合计
class _RangeBar extends StatelessWidget {
  const _RangeBar({required this.window, required this.onChanged});

  final Duration window;
  final ValueChanged<Duration> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
      child: Wrap(
        spacing: Gap.sm,
        children: [
          _Pill(
            key: const Key('traffic-range-day'),
            label: t.trafficRangeDay,
            selected: window == const Duration(days: 1),
            onTap: () => onChanged(const Duration(days: 1)),
            hud: hud,
          ),
          _Pill(
            key: const Key('traffic-range-week'),
            label: t.trafficRangeWeek,
            selected: window == const Duration(days: 7),
            onTap: () => onChanged(const Duration(days: 7)),
            hud: hud,
          ),
        ],
      ),
    );
  }
}

class _DirectionBar extends StatelessWidget {
  const _DirectionBar({required this.value, required this.onChanged});

  final TrafficDirection? value;
  final ValueChanged<TrafficDirection?> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
      child: Wrap(
        spacing: Gap.sm,
        children: [
          _Pill(
            key: const Key('traffic-dir-all'),
            label: t.trafficDirectionAll,
            selected: value == null,
            onTap: () => onChanged(null),
            hud: hud,
          ),
          _Pill(
            key: const Key('traffic-dir-down'),
            label: t.trafficDirectionDown,
            selected: value == TrafficDirection.down,
            onTap: () => onChanged(TrafficDirection.down),
            hud: hud,
          ),
          _Pill(
            key: const Key('traffic-dir-up'),
            label: t.trafficDirectionUp,
            selected: value == TrafficDirection.up,
            onTap: () => onChanged(TrafficDirection.up),
            hud: hud,
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.hud,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final DesignPalette hud;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.md,
            vertical: Gap.xs,
          ),
          decoration: BoxDecoration(
            // ★ `DA186`：不透明 `primarySoft`（半透明叠底只有 4.4:1）
            color: selected ? hud.primarySoft : hud.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: selected ? hud.primary : hud.line,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: selected ? hud.primary : hud.dim,
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.stats});

  final TrafficStats stats;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final total = stats.attributedTotalBytes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: hud.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: hud.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.trafficTotal, style: theme.textTheme.labelMedium?.copyWith(color: hud.dim)),
            const SizedBox(height: Gap.xs),
            Text(
              formatTrafficBytes(total),
              key: const Key('traffic-total-bytes'),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.xs,
              children: [
                _Tag(
                  key: const Key('traffic-tag-exact'),
                  text: '${t.trafficExact} ${formatTrafficBytes(stats.exactBytes)}',
                  color: hud.primary,
                ),
                _Tag(
                  key: const Key('traffic-tag-estimated'),
                  text:
                      '${t.trafficEstimated} ${formatTrafficBytes(stats.estimatedBytes)}',
                  color: hud.danger,
                ),
                _Tag(
                  key: const Key('traffic-tag-unattributed'),
                  text:
                      '${t.trafficUnattributed} ${formatTrafficBytes(stats.unattributedBytes)}',
                  color: hud.dim,
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              t.trafficUnattributedShare(
                stats.unattributedPercent.toStringAsFixed(1),
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          ],
        ),
      ),
    );
  }
}

class _OsCard extends StatelessWidget {
  const _OsCard({required this.stats});

  final TrafficStats stats;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final baseAt = stats.osBaselineAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: hud.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: hud.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.trafficOsSection,
              style: theme.textTheme.labelMedium?.copyWith(color: hud.dim),
            ),
            const SizedBox(height: Gap.xs),
            if (baseAt == null)
              Text(
                t.trafficOsUnavailable,
                key: const Key('traffic-os-unavailable'),
                style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
              )
            else ...[
              Text(
                t.trafficOsTotal(formatTrafficBytes(stats.osTotalBytes)),
                key: const Key('traffic-os-total'),
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                t.trafficOsAttributed(
                  formatTrafficBytes(stats.attributedTotalBytes),
                ),
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                t.trafficOsUnaccounted(formatTrafficBytes(stats.unaccountedBytes)),
                key: const Key('traffic-os-unaccounted'),
                style: theme.textTheme.bodyMedium?.copyWith(color: hud.danger),
              ),
              const SizedBox(height: Gap.xs),
              Text(
                t.trafficOsSince(_hm(baseAt)),
                style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RankingList extends StatelessWidget {
  const _RankingList({required this.stats, required this.direction});

  final TrafficStats stats;
  final TrafficDirection? direction;

  @override
  Widget build(BuildContext context) {
    final rows = stats.ranking(direction: direction);
    final maxBytes = rows.isEmpty
        ? 1
        : rows.first.bytesOf(direction ?? TrafficDirection.down) == 0
        ? rows.first.totalBytes
        : rows.first.bytesOf(direction ?? TrafficDirection.down);
    return Column(
      key: const Key('traffic-ranking'),
      children: [
        for (final r in rows)
          _RankRow(
            entry: r,
            wholeApp: stats.attributedTotalBytes,
            maxBytes: maxBytes,
            direction: direction,
          ),
      ],
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.entry,
    required this.wholeApp,
    required this.maxBytes,
    required this.direction,
  });

  final TrafficRankEntry entry;
  final int wholeApp;
  final int maxBytes;
  final TrafficDirection? direction;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final bytes = direction == null ? entry.totalBytes : entry.bytesOf(direction!);
    final frac = maxBytes <= 0 ? 0.0 : (bytes / maxBytes).clamp(0.0, 1.0);
    final module = UsageModule.byId(entry.module)?.labelIn(t) ?? entry.module;
    return Padding(
      key: Key('traffic-rank-${entry.module}'),
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.trafficRankRow(
              module,
              formatTrafficBytes(bytes),
              entry.sharePercent(wholeApp).toStringAsFixed(1),
            ),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              children: [
                Container(height: 6, color: hud.surface),
                FractionallySizedBox(
                  widthFactor: frac,
                  child: Container(height: 6, color: hud.primary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HoursChart extends StatelessWidget {
  const _HoursChart({required this.stats});

  final TrafficStats stats;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    var max = 1;
    for (final h in stats.hours) {
      if (h.totalBytes > max) max = h.totalBytes;
    }
    return Padding(
      key: const Key('traffic-hours'),
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
      child: Column(
        children: [
          SizedBox(
            height: 96,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final h in stats.hours)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          heightFactor: (h.totalBytes / max).clamp(0.02, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: hud.primary.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final label in const ['0', '6', '12', '18', '23'])
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.text, required this.hud});

  final String text;
  final DesignPalette hud;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: hud.dim,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.hud});

  final String text;
  final DesignPalette hud;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, 2, Gap.md, 2),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: hud.dim),
      ),
    );
  }
}

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
