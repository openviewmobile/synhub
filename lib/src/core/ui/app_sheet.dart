import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 统一的底部面板（玻璃 + 拖拽手柄 + 分组 + 危险区）。
///
/// 之前 5 个面板各写各的（有的没拖拽手柄、有的是复制粘贴），这里做成一套。
/// 用法：
/// ```dart
/// showAppSheet(context, title: '频道操作', children: [
///   AppSheetSection(children: [AppSheetAction(...), ...]),
/// ]);
/// ```
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required List<Widget> children,
  String? title,
  bool isScrollControlled = true,
  bool showDragHandle = true,
}) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
    useSafeArea: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.xl,
                  Gap.xs,
                  Gap.xl,
                  Gap.md,
                ),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            // 这里**刻意**不用 ListView：ListView 是懒构建，屏幕外的动作
            // （例如危险区的「删除」）根本不会挂载 → 测试 find 不到，用户也得
            // 先滚动才知道有这一项。面板项数不多，全部建出来更稳。
            Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Gap.md,
                    Gap.xs,
                    Gap.md,
                    Gap.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
            ),
            // 面板底部留一点主色渐隐，收口更好看
            Container(
              height: 2,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    scheme.primary.withValues(alpha: 0),
                    scheme.primary.withValues(alpha: 0.35),
                    scheme.primary.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 面板里的一个分组（玻璃卡片包住若干动作行）。
class AppSheetSection extends StatelessWidget {
  const AppSheetSection({
    super.key,
    required this.children,
    this.label,
    this.danger = false,
  });

  final List<Widget> children;
  final String? label;

  /// 危险区（删除/退出）：错误色描边 + 错误色图标
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Gap.sm,
                Gap.xs,
                Gap.sm,
                Gap.sm,
              ),
              child: Text(
                label!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: danger ? scheme.error : scheme.onSurfaceVariant,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          Container(
            decoration: BoxDecoration(
              color: danger
                  ? scheme.error.withValues(alpha: 0.06)
                  : scheme.surfaceContainerHigh.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(Radii.pane),
              border: Border.all(
                color: danger
                    ? scheme.error.withValues(alpha: 0.28)
                    : scheme.outlineVariant.withValues(alpha: 0.4),
                width: 0.7,
              ),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

/// 面板里的动作行（图标 + 标题 + 可选说明 + 危险色）。
class AppSheetAction extends StatelessWidget {
  const AppSheetAction({
    super.key,
    required this.icon,
    required this.label,
    this.description,
    this.onTap,
    this.danger = false,
    this.trailing,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String? description;
  final VoidCallback? onTap;
  final bool danger;
  final Widget? trailing;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final color = danger
        ? scheme.error
        : selected
        ? scheme.primary
        : scheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.md,
          vertical: Gap.md + 2,
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: (danger ? scheme.error : scheme.primary).withValues(
                  alpha: selected ? 0.18 : 0.10,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (description != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        description!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// 快速回应行：一排表情球，点一下即回应。
class QuickReactionRow extends StatelessWidget {
  const QuickReactionRow({
    super.key,
    required this.emojis,
    required this.onPick,
    this.mine,
  });

  final List<String> emojis;
  final void Function(String emoji) onPick;

  /// 我已回应过的表情（高亮）
  final Set<String>? mine;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.sm, 0, Gap.sm, Gap.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final e in emojis)
            _ReactionOrb(
              emoji: e,
              active: mine?.contains(e) ?? false,
              onTap: () => onPick(e),
            ),
        ],
      ),
    );
  }
}

class _ReactionOrb extends StatefulWidget {
  const _ReactionOrb({
    required this.emoji,
    required this.active,
    required this.onTap,
  });

  final String emoji;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_ReactionOrb> createState() => _ReactionOrbState();
}

class _ReactionOrbState extends State<_ReactionOrb> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 1.25 : 1,
        duration: Motion.resolve(Motion.fast),
        curve: Motion.pop,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.active
                ? scheme.primary.withValues(alpha: 0.18)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            border: Border.all(
              color: widget.active
                  ? scheme.primary.withValues(alpha: 0.6)
                  : Colors.transparent,
            ),
          ),
          child: Text(widget.emoji, style: const TextStyle(fontSize: 22)),
        ),
      ),
    );
  }
}
