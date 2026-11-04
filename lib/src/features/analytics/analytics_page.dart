// 「设置 → 使用分析」页：把本地日志算出来的结论摆出来，并给用户完全的
// 控制权（开关、导出、清空）。这一页同时是"反哺策略"的**可解释性界面**：
// 每条结论都能展开看统计口径（`evidence`），也能看到它对应哪条策略。
//
// 为什么必须有这一页（不只是内部埋点）：
//   * 隐私要可见：用户得能一眼看到"记了什么、没记什么"，才谈得上信任；
//   * 结论要可复核：`evidence` 里是聚合数字，不是黑盒判断；
//   * 决策要可控：一键关掉 / 一键清空，不依赖服务端。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../shell/workspace_providers.dart';
import 'analytics_labels.dart';
import 'analytics_providers.dart';
import 'traffic_page.dart';
import 'usage_analysis.dart';
import 'usage_event.dart';
import '../../core/user_facing_error.dart';

class UsageAnalyticsPage extends ConsumerStatefulWidget {
  const UsageAnalyticsPage({super.key});

  @override
  ConsumerState<UsageAnalyticsPage> createState() => _UsageAnalyticsPageState();
}

class _UsageAnalyticsPageState extends ConsumerState<UsageAnalyticsPage> {
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    // 统计/结论这两个 provider 不是 autoDispose：上次打开算出来的值会一直留着，
    // 于是"用过一阵再进来"看到的还是旧数字（真机踩到过：明明记了 4 条还显示 0）。
    // 打开页面就重算一次；右上角「刷新分析」也还能再手动刷。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(usageInsightsProvider);
      ref.invalidate(usageStatsProvider);
      ref.invalidate(usageEventCountProvider);
    });
  }

  Future<void> _export() async {
    final t = context.t;
    final log = ref.read(usageLogProvider);
    final json = await log.exportJson(window: kAnalyticsWindow);
    await Clipboard.setData(ClipboardData(text: json));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.usageExported(json.length))));
    }
  }

  Future<void> _clear() async {
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.usageClearTitle),
        content: Text(t.usageClearBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.actionClear),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final log = ref.read(usageLogProvider);
    await log.clearEvents();
    await log.clearInsights();
    await ref.read(trafficLogProvider).clear();
    ref.invalidate(usageInsightsProvider);
    ref.invalidate(usageStatsProvider);
    ref.invalidate(usageEventCountProvider);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.usageCleared)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final enabled = ref.watch(analyticsEnabledProvider);
    final insights = ref.watch(usageInsightsProvider);
    final stats = ref.watch(usageStatsProvider);
    final count = ref.watch(usageEventCountProvider).value ?? 0;

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
                      tooltip: context.t.calBack,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.t.setUsageAnalytics,
                            style: theme.textTheme.titleLarge,
                          ),
                          Text(
                            context.t.usageLocalLog(count),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: hud.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: context.t.usageRefresh,
                      icon: const Icon(Icons.refresh),
                      onPressed: () {
                        ref.invalidate(usageInsightsProvider);
                        ref.invalidate(usageStatsProvider);
                        ref.invalidate(usageEventCountProvider);
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: Gap.xl),
                  children: [
                    // ListTile 家族要自己的 Material 祖先（页面底色是
                    // FieldBackdrop 的 ColoredBox，不套会在 debug 断言）
                    Material(
                      type: MaterialType.transparency,
                      child: DesignSwitchRow(
                        value: enabled,
                        onChanged: (v) =>
                            ref.read(analyticsEnabledProvider.notifier).set(v),
                        title: Text(context.t.usageEnableTitle),
                        subtitle: Text(
                          context.t.usageEnableSubtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                      ),
                    ),
                    // 网络流量：独立子页（模块排行 + 时段分布 + 系统对比）。
                    // 放在开关下面、且**不受开关影响** —— 已经有数据时仍然可看。
                    const Divider(height: 1),
                    Material(
                      type: MaterialType.transparency,
                      child: DesignRowTile(
                        key: const Key('usage-open-traffic'),
                        leading: const Icon(Icons.network_check_outlined),
                        title: Text(context.t.trafficTitle),
                        subtitle: Text(
                          context.t.trafficSubtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(
                          context,
                          rootNavigator: true,
                        ).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const TrafficPage(),
                          ),
                        ),
                      ),
                    ),
                    if (enabled) ...[
                      const Divider(height: 1),
                      _Header(text: context.t.usageSectionInsights, hud: hud),
                      insights.when(
                        loading: () => const SizedBox(
                          height: 160,
                          child: AppListSkeleton(rows: 4),
                        ),
                        error: (e, __) => AppErrorView(
                          title: context.t.usageInsightsFailed,
                          detail: userFacingError(e),
                          onRetry: () => ref.invalidate(usageInsightsProvider),
                        ),
                        data: (list) => list.isEmpty
                            ? AppEmptyState(
                                icon: Icons.insights_outlined,
                                title: context.t.usageInsightsEmptyTitle,
                                message: context.t.usageInsightsEmptyMessage,
                                compact: true,
                              )
                            : Column(
                                children: [
                                  for (final i in list)
                                    _InsightCard(insight: i),
                                ],
                              ),
                      ),
                      _Header(text: context.t.usageSectionData, hud: hud),
                      stats.when(
                        data: (s) => _StatsSections(stats: s),
                        loading: () => const SizedBox(
                          height: 60,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        // ★ 本地统计读取失败原来渲染成 `SizedBox.shrink()`：
                        //   "统计"小标题在、内容凭空消失，用户看不到失败也
                        //   没有重试入口（失败被静默吞掉）。
                        error: (e, __) => AppErrorView(
                          key: const Key('usage-stats-error'),
                          title: context.t.usageSectionData,
                          detail: userFacingError(e),
                          onRetry: () => ref.invalidate(usageStatsProvider),
                        ),
                      ),
                    ],
                    // 导出/清空/看原始事件**关了也要在**：页面自己写着
                    // "已有的数据仍然保留（可以导出或清空）"，那按钮就不能藏
                    //（真机上关掉开关后按钮全没了，是自相矛盾的）。
                    if (!enabled)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Gap.md,
                          Gap.sm,
                          Gap.md,
                          0,
                        ),
                        child: Text(
                          context.t.usageDisabledNote(count),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Gap.sm,
                        Gap.md,
                        Gap.sm,
                        0,
                      ),
                      // 三个 `TextButton.icon` 横排：中文 1.0 缩放在 360 宽屏上
                      // 就溢出了 7px，英文 / 大字号下最多溢出 310px。
                      // `Wrap` 一条信息不丢，放不下自动换行。
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: Gap.sm,
                        runSpacing: Gap.xs,
                        children: [
                          TextButton.icon(
                            onPressed: () =>
                                setState(() => _showRaw = !_showRaw),
                            icon: Icon(
                              _showRaw ? Icons.expand_less : Icons.expand_more,
                            ),
                            label: Text(
                              _showRaw
                                  ? context.t.usageHideRaw
                                  : context.t.usageShowRaw,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _export,
                            icon: const Icon(Icons.copy_all_outlined, size: 18),
                            label: Text(context.t.usageExportJson),
                          ),
                          TextButton.icon(
                            onPressed: _clear,
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: Text(context.t.actionClear),
                          ),
                        ],
                      ),
                    ),
                    if (_showRaw) const _RawEvents(),
                  ],
                ),
              ),
            ],
          ),
        ),
    );
  }
}

/// 使用日志里的**模块 id** → 工作台**入口 id**（只有这些能"收进第二屏"）。
///
/// 注意 `drive` 映射不到独立入口（它和 `files` 共用"文件"这一个入口），
/// `office`/`reader`/`settings`/`workspace` 也没有独立磁贴 —— 这类不参与收起，
/// 否则会把"从没用过 Drive"变成"把文件入口藏了"。
const Map<String, String> kHideableWorkspaceEntry = {
  'files': 'files',
  'notes': 'notes',
  'photos': 'photos',
  'contacts': 'contacts',
  'calendar': 'calendar',
  'chat': 'chat',
  'search': 'search',
};

class _InsightCard extends ConsumerWidget {
  const _InsightCard({required this.insight});

  final UsageInsight insight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final hideable = _hideableIdsOf(insight);
    final hidden = ref.watch(workspaceHiddenProvider);
    final applied = hideable.where(hidden.contains).toList();
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => showModalBottomSheet<void>(
            context: context,
            backgroundColor: Colors.transparent,
            builder: (_) => _InsightSheet(insight: insight),
          ),
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
                    Expanded(
                      child: Text(
                        insight.title,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      '${(insight.score * 100).round()}%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: hud.dim,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.xs),
                Text(
                  insight.body,
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
                if (insight.suggestion.isNotEmpty) ...[
                  const SizedBox(height: Gap.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.tips_and_updates_outlined,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: Gap.xs),
                      Expanded(
                        child: Text(
                          insight.suggestion,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                // 「结论 → 策略」的**真实动作**：把没用过的入口收进第二屏（可逆）。
                // 只在有可收起的入口时出现；应用/还原都在这里，工作台那边还有
                // 一条"已收起 N 个 · 显示全部"的提示可以还原。
                if (hideable.isNotEmpty) ...[
                  const SizedBox(height: Gap.sm),
                  Row(
                    children: [
                      if (applied.isEmpty)
                        TextButton.icon(
                          onPressed: () async {
                            final t = context.t;
                            await ref
                                .read(workspaceHiddenProvider.notifier)
                                .hide(hideable);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    t.usageHidEntries(hideable.length),
                                  ),
                                ),
                              );
                            }
                          },
                          icon: const Icon(
                            Icons.visibility_off_outlined,
                            size: 18,
                          ),
                          label: Text(
                            context.t.usageHideAction(hideable.length),
                          ),
                        )
                      else
                        TextButton.icon(
                          onPressed: () => ref
                              .read(workspaceHiddenProvider.notifier)
                              .showAll(),
                          icon: const Icon(Icons.visibility_outlined, size: 18),
                          label: Text(
                            context.t.usageHiddenCount(applied.length),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 这条结论能收起哪些工作台入口（`unused_module` 才有）
List<String> _hideableIdsOf(UsageInsight insight) {
  if (insight.kind != InsightKind.unusedModule) return const [];
  final raw = insight.evidence['unused'];
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (kHideableWorkspaceEntry.containsKey('$e'))
        kHideableWorkspaceEntry['$e']!,
  ];
}

/// 结论详情：口径（evidence）+ 对应策略 + 来源
class _InsightSheet extends StatelessWidget {
  const _InsightSheet({required this.insight});

  final UsageInsight insight;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Material(
        color: hud.surface2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: hud.line, width: 1),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(insight.title, style: theme.textTheme.titleMedium),
              const SizedBox(height: Gap.sm),
              Text(insight.body, style: theme.textTheme.bodyMedium),
              if (insight.suggestion.isNotEmpty) ...[
                const SizedBox(height: Gap.md),
                Text(
                  context.t.usageHowToChange,
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(height: Gap.xs),
                Text(
                  insight.suggestion,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
              const SizedBox(height: Gap.md),
              Text(context.t.usageEvidence, style: theme.textTheme.labelSmall),
              const SizedBox(height: Gap.xs),
              for (final e in insight.evidence.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${e.key}: ${e.value}',
                    style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                  ),
                ),
              const SizedBox(height: Gap.md),
              Text(
                [
                  context.t.usageMetaKind(insight.kind.labelIn(context.t)),
                  context.t.usageMetaConfidence((insight.score * 100).round()),
                  context.t.usageMetaSource(
                    insight.source == 'heuristic'
                        ? context.t.usageSourceHeuristic
                        : insight.source,
                  ),
                  if (insight.model.isNotEmpty)
                    context.t.usageMetaModel(insight.model),
                  if (insight.strategyKey.isNotEmpty)
                    context.t.usageMetaStrategy(insight.strategyKey),
                ].join(' · '),
                style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
              ),
              const SizedBox(height: Gap.md),
            ],
          ),
        ),
      ),
    );
  }
}

/// 原始事件列表（脱敏后的样子，让用户"看得见记了什么"）
class _RawEvents extends ConsumerWidget {
  const _RawEvents();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    return FutureBuilder<List<UsageEvent>>(
      future: ref.watch(usageLogProvider).recent(limit: 60),
      builder: (context, snap) {
        final rows = snap.data ?? const <UsageEvent>[];
        if (rows.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Text(
              context.t.usageNoEvents,
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          );
        }
        return Column(
          children: [
            for (final e in rows)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.md,
                  vertical: Gap.xs,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(
                        '${e.at.hour.toString().padLeft(2, '0')}:'
                        '${e.at.minute.toString().padLeft(2, '0')}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: hud.dim,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${e.module.labelIn(context.t)} · '
                        '${e.action.labelIn(context.t)}'
                        '${e.objectType.isEmpty ? '' : ' · ${e.objectType}'}'
                        '${e.value == 0 ? '' : ' · ${e.value}'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.text, required this.hud});

  final String text;
  final DesignPalette hud;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.lg, Gap.md, Gap.sm),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: hud.dim),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: hud.line, width: 1),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

/// 统计区：总览 chips + **按模块 / 功能采用 / 视图偏好 / 失败原因 / 使用时长**。
///
/// 这一块就是"使用分析页现在能回答什么"的正面清单：
///   * 哪些模块真的被用（`byModule`）；
///   * 哪些功能被采用、哪些从未用过（`adoptedModules`/`unusedModules`）；
///   * 视图/模式偏好（`byViewMode`，来自 `switchView`）；
///   * 失败**原因**（`byFailureReason`，可查询的原因码，不只是计数）；
///   * 有时长的使用（`durationTotalMs`/`durationCount`，来自 `complete`）；
///   * 统计范围（from→to），避免"看不到时间窗"。
class _StatsSections extends StatelessWidget {
  const _StatsSections({required this.stats});

  final UsageStats stats;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final s = stats;
    final modules = s.byModule.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final durations = s.durationCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    String moduleName(String id) => UsageModule.byId(id)?.labelIn(t) ?? id;
    String actionName(String id) => UsageAction.byId(id)?.labelIn(t) ?? id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          child: Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              _Chip(t.usageChipEvents(s.total)),
              _Chip(t.usageChipDays(s.dayCount)),
              _Chip(t.usageChipSessions(s.sessions.length)),
              _Chip(t.usageChipAvg(s.avgSession)),
              _Chip(t.usageChipSearch(s.searchCount)),
              _Chip(t.usageChipUpload(s.uploadCount)),
              _Chip(t.usageChipDownload(s.downloadCount)),
              _Chip(t.usageChipEdit(s.editCount)),
              _Chip(t.usageRange(_ymd(s.from), _ymd(s.to))),
            ],
          ),
        ),

        // ── 按模块使用 ──────────────────────────────────────────────
        _Header(text: t.usageSectionModules, hud: hud),
        if (modules.isEmpty)
          _StatRow(text: t.usageNoEvents)
        else
          for (final e in modules.take(10))
            _StatRow(
              rowKey: Key('usage-mod-${e.key}'),
              text: t.usageModuleRow(
                moduleName(e.key),
                e.value,
                s.total == 0 ? 0 : (e.value * 100 / s.total).round(),
              ),
            ),

        // ── 功能采用 ────────────────────────────────────────────────
        _Header(text: t.usageSectionAdoption, hud: hud),
        _StatRow(
          rowKey: const Key('usage-adoption'),
          text: t.usageAdoptTitle(s.adoptedModules.length, s.adoptionTotal),
        ),
        _StatRow(
          text: s.unusedModules.isEmpty
              ? t.usageAdoptAll
              : t.usageAdoptBody(
                  s.unusedModules.map(moduleName).join(', '),
                ),
        ),

        // ── 视图 / 选项偏好 ─────────────────────────────────────────
        _Header(text: t.usageSectionViewPrefs, hud: hud),
        if (s.topViewModes.isEmpty)
          _StatRow(text: t.usageNoViewPrefs)
        else
          for (final e in s.topViewModes.take(8))
            _StatRow(
              rowKey: Key('usage-view-${e.key}'),
              text: t.usageViewPrefRow(usageModuleKeyLabel(e.key, t), e.value),
            ),

        // ── 失败原因（可查询的原因码）────────────────────────────────
        _Header(text: t.usageSectionFailures, hud: hud),
        if (s.topFailureReasons.isEmpty)
          _StatRow(text: t.usageNoFailures)
        else
          for (final e in s.topFailureReasons.take(8))
            _StatRow(
              rowKey: Key('usage-fail-${e.key}'),
              text: t.usageFailReasonRow(_reasonLabel(e.key, t), e.value),
            ),

        // ── 使用时长 ────────────────────────────────────────────────
        _Header(text: t.usageSectionDurations, hud: hud),
        if (durations.isEmpty)
          _StatRow(text: t.usageNoDurations)
        else
          for (final e in durations.take(8))
            _StatRow(
              rowKey: Key('usage-dur-${e.key}'),
              text: t.usageDurationRow(
                actionName(_actionOf(e.key)),
                s.avgMinutesOf(e.key),
                e.value,
              ),
            ),
      ],
    );
  }
}

/// `module.action` → action id
String _actionOf(String key) {
  final i = key.indexOf('.');
  return i < 0 ? key : key.substring(i + 1);
}

/// `module.reason` → 本地化失败原因
String _reasonLabel(String key, AppText t) {
  final i = key.indexOf('.');
  if (i <= 0) return key;
  final mod = UsageModule.byId(key.substring(0, i))?.labelIn(t) ?? key.substring(0, i);
  return '$mod·${usageFailureReasonLabel(key.substring(i + 1), t)}';
}

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class _StatRow extends StatelessWidget {
  const _StatRow({required this.text, this.rowKey});

  final String text;
  final Key? rowKey;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Padding(
      key: rowKey,
      padding: const EdgeInsets.fromLTRB(Gap.md, 2, Gap.md, 2),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: hud.dim),
      ),
    );
  }
}
