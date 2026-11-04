import 'package:flutter/material.dart';
import '../../core/i18n/l10n.dart';

import '../theme/app_tokens.dart';

/// 给 `AppBar(actions: …)` 用的一行写法：**放得下就原样一行，放不下就把
/// 多余的折叠进 `⋮`**（Material 标准做法，也让"按钮跑到屏外"不可能发生）。
///
/// ```dart
/// actions: adaptiveActions([
///   IconButton(key: Key('photo-rotate'), tooltip: '旋转', …),
///   if (cond) IconButton(…),
/// ]),
/// ```
///
/// * [maxInline] 默认 99 = **只受宽度约束**。800x600 的测试窗口下 14×48=672
///   仍然放得下 ⇒ 所有子控件原样在树里 ⇒ 既有 28 处 key 断言不受影响；
///   真机 414dp 下只留 5 个，其余进 `⋮`（仍然可点，只是多一步）。
/// * 只有**纯 `IconButton`** 会被折叠（能从它身上拿到 `icon`/`tooltip`/`onPressed`
///   生成菜单项）；`PopupMenuButton`、`Badge` 这类复合控件一律保留在行内。
List<Widget> adaptiveActions(
  List<Widget> children, {
  double reserve = 112,
  int maxInline = 99,
  double? width,
}) => <Widget>[
  FoldingActions(
    reserve: reserve,
    maxInline: maxInline,
    width: width,
    children: children,
  ),
];

/// **不变量（P1，所有工具条共用这个文件）**：
/// **非 `IconButton` 的孩子在任何宽度下都不许被丢弃。**
/// 折叠只能折纯 `IconButton`；落进折叠段的复合控件（`PopupMenuButton`/`Badge`…）
/// 必须被**换回行内**。理由：溢出菜单的判据类型是 `IconButton`
/// （`icon`/`tooltip`/`onPressed` 才够造出菜单项），把复合控件"塞进 `⋮`"
/// 根本不是选项 —— 那样它既不在行内、也不在菜单里，**静默消失**。
///
/// **宽度不够时怎么办（显式决定）**：先按 `fixed`（复合控件个数）把行内格数
/// 抬到至少那么多；若复合控件仍排在折叠点之后，就把它们**全部换回行内**，
/// 宁可让这一行比预算宽（debug 下会看到溢出条纹、用例能抓住），
/// **也绝不静默少一个动作** —— 可见的失败优于静默的丢失。
/// **调用方契约**：传进来的复合控件个数必须 ≤ 目标最窄宽度能放下的格数
/// （当前所有调用方都是 1–2 个）；它是"钉住不动"的，不吃折叠这份余量。
class FoldingActions extends StatelessWidget {
  // children 放最后是本仓 lint `sort_child_properties_last` 的要求
  const FoldingActions({
    super.key,
    this.reserve = 112,
    this.maxInline = 99,
    this.width,
    required this.children,
  });

  final List<Widget> children;
  final double reserve;
  final int maxInline;

  /// 显式宽度：放在**已经有 LayoutBuilder 的 `Row`** 里时用（`Row` 给非 flex
  /// 子项无界约束，必须由调用方把"给标题留多少"算好传进来）。
  final double? width;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final hud = HudTokens.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final width = this.width ??
            (c.hasBoundedWidth ? c.maxWidth : MediaQuery.sizeOf(context).width);
        // 复合控件（PopupMenuButton/Badge…）不折叠 ⇒ 它们**恒占行内格子**。
        // ★★ 第 344 轮（D56）：预算必须**先把它们扣掉** —— 相册大图页 13 个动作里
        //    有 1 个 `PopupMenuButton`（相册操作）。旧算法按 `inline = 5` 算，再把
        //    这个菜单"换回行内"（不许静默丢），于是**行宽实际是 `inline + fixed` 格**
        //    （375dp 真机上 6 格 = 288dp），标题只剩约 39dp ⇒ 真机标题被压成
        //    **一个字符**（逐字 `2…`，2026-10-10 像素）。这不是"复合控件恰好排在
        //    折叠点之后"才有的问题，而是**只要行内有复合控件**就多占 `fixed` 格。
        //    修法：把 `fixed` 格的宽度记进 `reserve`，并把候选数减成"可折叠的那些"。
        //    ⇒ 800dp 测试窗口下 `plain(640/48=13) ≥ 12` 仍然**一格都不折**，
        //    既有 key 断言不受影响（见 `test/adaptive_actions_test.dart` ①③）。
        // 复合控件（`PopupMenuButton`/`Badge`…）**恒占行内格子**（不变量：不许静默丢）。
        // ★★ 第 344 轮（D56）：相册大图页 13 个动作里有 1 个 `PopupMenuButton`，
        //    375dp 真机上工具条成了 6 格（288dp）、标题只剩 35dp ⇒ 被压成**一个
        //    字符**（逐字 `2…`）。根因不是"动作太多"，而是**预算漏算**：算 `inline`
        //    时没把"恒在行内的复合控件"扣掉，它们随后又被换回行内 ⇒ 实际行宽是
        //    `inline + fixed` 格。
        // ★ 但**不能无条件**从预算里扣**（第一次修法就这么错过）**：那样连
        //    "本来就全放得下"的宽屏也会提前折叠 —— 真机/用例都会掉按钮
        //    （r344 实测：播放器控制条 4 个菜单 ⇒ `fixed=4`，800px 用例里
        //    `media-next`/`media-fullscreen` 直接消失 6 条用例）。
        //    判据：**先问"放得下吗"**；只有真的要折叠时，才把 `fixed` 与溢出格
        //    从可用格数里扣掉。
        final fixed = children.where((c) => c is! IconButton).length;
        final foldable = children.length - fixed;
        final room = ((width - reserve) / AdaptiveActions.slot).floor();
        final cap = maxInline < children.length ? maxInline : children.length;
        final int inline; // 行内保留的**纯 IconButton** 个数（复合控件不算在它里面）
        if (room >= children.length && cap >= children.length) {
          // 放得下、也没被 `maxInline` 卡住 ⇒ 一个都不折（与改动前逐字一致）
          inline = foldable;
        } else {
          // 要折叠：行内 = `inline` 个 IconButton + 全部 `fixed` + 溢出格 1
          var k = room - fixed - 1;
          if (k > foldable) k = foldable;
          if (k > cap) k = cap;
          // 一个都放不下时留 1 个：宁可这一行超预算（debug 会看到溢出条纹、
          // 用例能抓住），也**绝不静默少一个动作**（可见的失败优于静默的丢失）。
          inline = k < 1 ? 1 : k;
        }
        if (inline >= foldable) {
          return Row(mainAxisSize: MainAxisSize.min, children: children);
        }
        // 折叠**尾部**的 IconButton（调用方把最重要的放前面）；复合控件按位置
        // 原样留在行内 —— 溢出菜单的判据类型是 `IconButton`（要从它身上拿
        // `icon`/`tooltip`/`onPressed`），所以复合控件**根本进不了** `folded`。
        // ★ 别把这里的判据写成 `PopupMenuButton<int>`：调用方的复合控件泛型五花八门
        //   （`download_page` 是 `PopupMenuButton<String>`），写成具体泛型会让它
        //   既进不了"换回行内"的分支、又被 `folded` 过滤掉 ⇒ **动作静默消失**。
        //   守卫：`test/adaptive_actions_test.dart` ④ 组（反向验证过）。
        final keep = <Widget>[];
        final folded = <Widget>[];
        var icons = 0;
        for (final c in children) {
          if (c is IconButton) {
            if (icons < inline) {
              keep.add(c);
              icons++;
            } else {
              folded.add(c);
            }
          } else {
            keep.add(c);
          }
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...keep,
            if (folded.isNotEmpty)
              PopupMenuButton<int>(
                key: const Key('bar-overflow'),
                tooltip: context.t.photoMore,
                icon: Icon(Icons.more_vert, color: hud.meta),
                onSelected: (i) {
                  final b = folded[i];
                  if (b is IconButton) b.onPressed?.call();
                },
                itemBuilder: (_) => [
                  for (var i = 0; i < folded.length; i++)
                    if (folded[i] is IconButton)
                      PopupMenuItem<int>(
                        key: Key('bar-overflow-$i'),
                        value: i,
                        enabled: (folded[i] as IconButton).onPressed != null,
                        child: Row(
                          children: [
                            Icon(
                              ((folded[i] as IconButton).icon as Icon).icon,
                              size: 20,
                              color: hud.meta,
                            ),
                            const SizedBox(width: Gap.sm),
                            Flexible(
                              child: Text(
                                (folded[i] as IconButton).tooltip ?? context.t.noteActions,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// 一个工具条动作：图标（行内）+ 文字（溢出菜单里）。
///
/// [id] 用来生成稳定的 `Key`（`bar-action-<id>` / `bar-overflow-<id>`），
/// 让几何回归用例能逐个量矩形。
@immutable
class BarAction {
  const BarAction({
    required this.id,
    required this.icon,
    required this.label,
    this.tooltip,
    this.onPressed,
    this.selected = false,
    this.widgetKey,
  });

  final String id;
  final IconData icon;

  /// 行内按钮用的 Key —— 默认 `bar-action-<id>`；调用方可以传**原有 key**
  /// （如 `Key('photo-rotate')`），这样"动作没被折叠时"既有用例断言不受影响。
  final Key? widgetKey;

  /// 溢出菜单里的文字（行内只画图标，所以这个字段必须给"人看得懂"的名字）
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  bool get enabled => onPressed != null;
}

/// **可折叠**的自适应动作条：行内只留放得下的，其余进 `⋮` 溢出菜单。
///
/// 与 [AdaptiveActionStrip] 的区别：这个会**把多余动作从行内移除**（折叠进菜单），
/// 因此它**会改变** tree 里有哪些 key —— 只用在"调用方本来就没有按 key 断言、
/// 且动作确实很多"的新地方；老页面优先用 [AdaptiveActionStrip] 保持兼容。
///
/// 算法（纯函数 [inlineCountFor]，可单测）：
/// ```
/// inline = clamp((w - reserve - slot) / slot, 1, min(maxInline, actions.length))
/// ```
/// 溢出按钮恒占一格。[maxInline] 默认 99（= 只受宽度约束）：
/// 800x600 的测试窗口下 14×48=672 仍然放得下 ⇒ 既有 key 断言不受影响；
/// 真机 414dp 下只留 5 个，其余进菜单。
class AdaptiveActions extends StatelessWidget {
  const AdaptiveActions({
    super.key,
    required this.actions,
    this.maxInline = 99,
    this.reserve = 112,
    this.iconColor,
    this.overflowTooltip,
  });

  final List<BarAction> actions;

  /// 行内最多几个（宽度够也不超过这个数）
  final int maxInline;

  /// 留给 leading（返回键）+ 标题的宽度
  final double reserve;

  final Color? iconColor;

  /// 溢出菜单的 tooltip；为 null 时用当前语言的「更多」（`t.photoMore`）。
  final String? overflowTooltip;

  /// 一个动作格子的宽度（`IconButton` 的最小点击区就是 48）
  static const double slot = 48;

  /// 给定宽度能行内放几个 —— 纯函数，几何用例直接调它做边界验证。
  static int inlineCountFor(
    double width, {
    int maxInline = 99,
    double reserve = 112,
    int total = 0,
  }) {
    // 先看"不折叠时"能放几格：放得下就**一格都不折**（视觉与改动前一致，
    // 也让 800x600 测试窗口下所有 key 原样在树里）。
    final plain = ((width - reserve) / slot).floor();
    final cap = maxInline < total ? maxInline : total;
    final fits = plain >= total ? plain : ((width - reserve - slot) / slot).floor();
    if (fits < 1) return cap < 1 ? 0 : 1;
    return fits < cap ? fits : cap;
  }

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    final hud = HudTokens.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.hasBoundedWidth
            ? c.maxWidth
            : MediaQuery.sizeOf(context).width;
        final inline = inlineCountFor(
          width,
          maxInline: maxInline,
          reserve: reserve,
          total: actions.length,
        );
        final shown = actions.take(inline).toList();
        final hidden = actions.skip(inline).toList();
        final color = iconColor ?? hud.meta;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final a in shown)
              IconButton(
                key: a.widgetKey ?? Key('bar-action-${a.id}'),
                tooltip: a.tooltip ?? a.label,
                onPressed: a.onPressed,
                icon: Icon(
                  a.icon,
                  color: a.selected
                      ? Theme.of(context).colorScheme.primary
                      : color,
                ),
              ),
            if (hidden.isNotEmpty)
              PopupMenuButton<String>(
                key: const Key('bar-overflow'),
                tooltip: overflowTooltip ?? context.t.photoMore,
                icon: Icon(Icons.more_vert, color: color),
                onSelected: (id) {
                  final a = hidden.firstWhere((e) => e.id == id);
                  a.onPressed?.call();
                },
                itemBuilder: (_) => [
                  for (final a in hidden)
                    PopupMenuItem<String>(
                      key: Key('bar-overflow-${a.id}'),
                      value: a.id,
                      enabled: a.enabled,
                      child: Row(
                        children: [
                          Icon(a.icon, size: 20, color: color),
                          const SizedBox(width: Gap.sm),
                          Flexible(
                            child: Text(
                              a.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}
