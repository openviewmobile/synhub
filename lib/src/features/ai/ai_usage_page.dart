// 「AI 用量与费用」页：把本机记录的云端调用汇总出来（按模型 / 按日期）。
//
// ⚠️ **这是本地估算，不是服务商账单。** 页面第一屏就把这句话写出来：
//   * token 数优先用服务端回的 `usage`；服务端没回时按字符数折算（标「估算」）；
//   * 费用按 `cloud_pricing.dart` 里的**公开列表价**折算，认不出单价的模型
//     显示「单价未知」且不计入总额（宁可不给数字，也不给一个假的）；
//   * 自建/局域网服务按 0 计（本地不算钱）。
// 展示风格对齐「使用分析」页：顶部时间窗 + 汇总卡 + 分组列表。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/ai/cloud_pricing.dart';
import 'cloud_settings.dart';

/// 时间窗
enum _UsageRange { all, days7, days30 }

class AiUsagePage extends ConsumerStatefulWidget {
  const AiUsagePage({super.key});

  @override
  ConsumerState<AiUsagePage> createState() => _AiUsagePageState();
}

class _AiUsagePageState extends ConsumerState<AiUsagePage> {
  _UsageRange _range = _UsageRange.all;

  int? get _sinceMs => switch (_range) {
    _UsageRange.all => null,
    _UsageRange.days7 =>
      DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch,
    _UsageRange.days30 =>
      DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch,
  };

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final usage = ref.watch(cloudSettingsProvider.select((s) => s.usage));
    final summary = summarizeCloudUsage(usage, sinceMs: _sinceMs);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        backgroundColor: hud.bg,
        title: Text(context.t.aiUsageTitle),
        actions: [
          IconButton(
            tooltip: context.t.aiUsageClear,
            onPressed: usage.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        children: [
          _rangeBar(theme, hud),
          _note(theme, hud, context.t.aiUsageEstimateNote),
          _note(theme, hud, context.t.aiUsagePriceNote(kCloudPricingUpdatedAt)),
          if (usage.isEmpty)
            _empty(theme, hud)
          else ...[
            _totalsCard(theme, hud, summary.overall),
            _sectionTitle(theme, hud, context.t.aiUsageByModel),
            for (final b in summary.byModel) _bucket(theme, hud, b),
            _sectionTitle(theme, hud, context.t.aiUsageByDay),
            for (final b in summary.byDay) _bucket(theme, hud, b),
          ],
          const SizedBox(height: Gap.xl),
        ],
      ),
    );
  }

  Widget _rangeBar(ThemeData theme, DesignPalette hud) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
      child: SegmentedButton<_UsageRange>(
        segments: [
          ButtonSegment(
            value: _UsageRange.all,
            label: Text(
              context.t.aiUsageRangeAll,
              style: theme.textTheme.labelSmall,
            ),
          ),
          ButtonSegment(
            value: _UsageRange.days7,
            label: Text(
              context.t.aiUsageRange7,
              style: theme.textTheme.labelSmall,
            ),
          ),
          ButtonSegment(
            value: _UsageRange.days30,
            label: Text(
              context.t.aiUsageRange30,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
        selected: {_range},
        onSelectionChanged: (v) => setState(() => _range = v.first),
      ),
    );
  }

  Widget _note(ThemeData theme, DesignPalette hud, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: hud.dim),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(ThemeData theme, DesignPalette hud) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t.aiUsageEmpty, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            context.t.aiUsageEmptyHint,
            style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
          ),
        ],
      ),
    );
  }

  /// 费用展示：小额给 4 位小数（不然全是 $0.00）。
  ///
  /// ⚠️ 一笔单价未知时**不能**显示"约 US$0"——那会被读成"免费"。
  /// 真机上看过一次「约 US$0 + 1 次未计价」，两行自相矛盾，这里改成
  /// 直接显示「单价未知」。
  String _cost(CloudUsageTotals t) {
    if (t.unpricedCalls > 0 && t.costUsd == 0) {
      return context.t.aiUsageCostUnknown;
    }
    if (t.costUsd == 0) return context.t.aiUsageCost('US\$0');
    return context.t.aiUsageCost(
      'US\$${t.costUsd < 0.01 ? t.costUsd.toStringAsFixed(4) : t.costUsd.toStringAsFixed(2)}',
    );
  }

  Widget _totalsCard(ThemeData theme, DesignPalette hud, CloudUsageTotals t) {
    final rows = <(String, String)>[
      (context.t.aiUsageCalls(t.calls), _cost(t)),
      (context.t.aiUsagePromptTokens(t.promptTokens), ''),
      (context.t.aiUsageCompletionTokens(t.completionTokens), ''),
      (context.t.aiUsageTotalTokens(t.totalTokens), ''),
      if (t.reasoningTokens > 0)
        (context.t.aiUsageReasoningTokens(t.reasoningTokens), ''),
      if (t.estimatedCalls > 0)
        (context.t.aiUsageEstimatedCalls(t.estimatedCalls), ''),
      if (t.unpricedCalls > 0) (context.t.aiUsageUnpriced(t.unpricedCalls), ''),
    ];
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
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(label, style: theme.textTheme.bodySmall),
                    ),
                    if (value.isNotEmpty)
                      Text(
                        value,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bucket(ThemeData theme, DesignPalette hud, CloudUsageBucket b) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              b.key,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Text(
            '${context.t.aiUsageCalls(b.totals.calls)} · '
            '${b.totals.totalTokens} · ${_cost(b.totals)}',
            style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, DesignPalette hud, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.lg, Gap.md, Gap.xs),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(color: hud.dim),
      ),
    );
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t.aiUsageClear),
        content: Text(ctx.t.aiUsageClearConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ctx.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ctx.t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final done = context.t.aiUsageCleared;
    await ref.read(cloudSettingsProvider.notifier).clearUsage();
    messenger.showSnackBar(SnackBar(content: Text(done)));
  }
}
