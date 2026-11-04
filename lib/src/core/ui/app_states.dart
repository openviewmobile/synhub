import 'package:flutter/material.dart';

import '../i18n/l10n.dart';
import '../theme/app_tokens.dart';
import 'ambient_clock.dart';

/// 统一空态：图标 + 标题 + 说明 + 可选主行动。
///
/// 之前每个页面各写各的（9 套不同的错误 UI），这里收敛成一套。
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.actionIcon = Icons.refresh,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 主行动按钮的**图标**。
  ///
  /// ★ r320：这里原来**写死** `Icons.refresh` —— 于是"新建任务""永久删除"
  ///   "卸载"这些**不是重试**的行动也顶着刷新箭头（像素取证：
  ///   `docs/evidence-r320/img/06_download_before.png` 的「New task」带着刷新圈）。
  ///   默认值保持 `Icons.refresh`（绝大多数调用点确实是"重试"），
  ///   非重试的站点必须**显式**传自己的图标 —— 漏掉的会在评审里一眼看出来。
  final IconData actionIcon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // 用可滚动容器包住：空态/错误态常被塞进固定高度的小格子里（预览页、
    // 列表底部等），高度不够时要能滚，而不是 RenderFlex 溢出。
    // ★ r675（`DA302`）：**矮视口**（iPhone 横屏宽屏档的右栏实测 300×102pt）里，
    //   72 图标 + `Gap.xl` 双倍留白 + 标题 + 两行说明会顶出折线 ——
    //   用户只看到一个圆圈图标，`Nothing selected yet` 在**屏幕外**（可滚，
    //   但没人会去滚一个"什么都没有"的面板）。判据：**空态的标题必须在静止
    //   状态下可见**。
    //
    // ★★ 二次修正（r675 当天被全量用例抓到）：第一版用 `LayoutBuilder` 按可用
    //   高度自动降档 —— 但 `LayoutBuilder` **不支持固有尺寸查询**，放进
    //   `AlertDialog`（`IntrinsicWidth`）里子树一个 `Text` 都建不出来（下载任务
    //   空态当场空白）。⇒ 改成**由调用方声明**：`compact: true` = 紧凑档
    //   （矮栏 / 弹层），不传 = 既有大档（一字不变）。
    final tight = compact;
    return SingleChildScrollView(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(tight ? Gap.md : Gap.xl),
              child: tight
                  // 极矮档（横屏右栏 ≈102pt / 弹层 168pt）：**横排**才可能同时
                  // 放下标题与说明（竖排 48 图标 + 标题 + 两行说明 ≈120pt）。
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.primary.withValues(alpha: 0.08),
                            border: Border.all(
                              color: scheme.primary.withValues(alpha: 0.18),
                            ),
                          ),
                          child: Icon(icon, size: 18, color: scheme.primary),
                        ),
                        const SizedBox(width: Gap.sm),
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: text.titleSmall,
                                textAlign: TextAlign.start,
                              ),
                              if (message != null) ...[
                                const SizedBox(height: Gap.xs),
                                Text(
                                  message!,
                                  style: text.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  textAlign: TextAlign.start,
                                ),
                              ],
                              if (actionLabel != null && onAction != null) ...[
                                const SizedBox(height: Gap.sm),
                                FilledButton.tonalIcon(
                                  onPressed: onAction,
                                  icon: Icon(actionIcon, size: 18),
                                  label: Text(actionLabel!),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    )
                  : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: tight ? 48 : 72,
                    height: tight ? 48 : 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary.withValues(alpha: 0.08),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Icon(
                      icon,
                      size: tight ? 24 : 32,
                      color: scheme.primary,
                    ),
                  ),
                  SizedBox(height: tight ? Gap.sm : Gap.lg),
                  Text(
                    title,
                    style: text.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  if (message != null) ...[
                    SizedBox(height: tight ? Gap.xs : Gap.sm),
                    Text(
                      message!,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: Gap.lg),
                    FilledButton.tonalIcon(
                      onPressed: onAction,
                      icon: Icon(actionIcon, size: 18),
                      label: Text(actionLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
    );
  }
}

/// 统一错误态：友好文案 + 重试（不把异常字符串直接糊在屏幕上）。
class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    this.title,
    this.detail,
    this.onRetry,
    this.icon = Icons.cloud_off,
  });

  /// 传 null 用当前语言的「加载失败」（`t.photoLoadFailed`）。
  final String? title;
  final String? detail;
  final VoidCallback? onRetry;
  final IconData icon;

  @override
  Widget build(BuildContext context) => AppEmptyState(
    icon: icon,
    title: title ?? context.t.photoLoadFailed,
    message: detail,
    actionLabel: onRetry == null ? null : context.t.photoRetry,
    onAction: onRetry,
  );
}

/// 骨架占位块（加载态）。
///
/// 一屏灰块比转圈更"现代"：它预示了内容的形状，等待感更短。
class AppSkeleton extends StatefulWidget {
  const AppSkeleton({super.key, this.width, this.height = 12, this.radius = 6});

  final double? width;
  final double height;
  final double radius;

  @override
  State<AppSkeleton> createState() => _AppSkeletonState();
}

class _AppSkeletonState extends State<AppSkeleton>
    with AmbientAnimation<AppSkeleton> {
  // ★ r287：呼吸相位改由共享常驻动效时钟推进（原来是 vsync ticker）。
  @override
  Duration get ambientPeriod => const Duration(milliseconds: 1300);

  @override
  bool get ambientPingPong => true;

  @override
  void initState() {
    super.initState();
    AppEffects.reducedMotion.addListener(_sync);
  }

  /// 呼吸/流光属于**常驻动效**：必须走 `AppEffects.ambientAllowed`
  /// （减少动效 / 测试环境恒关），并随设置实时启停。
  /// 反例：无条件 `repeat()` —— 测试里 `pumpAndSettle` 永不返回，
  /// 真机上 `uiautomator` 永远等不到 idle（本项目真踩过）。
  void _sync() {
    if (!mounted) return;
    syncAmbient();
    if (!AppEffects.ambientAllowed) ambientPhase.value = 0;
    setState(() {});
  }

  @override
  void dispose() {
    AppEffects.reducedMotion.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.onSurfaceVariant.withValues(alpha: 0.10);
    final highlight = scheme.onSurfaceVariant.withValues(alpha: 0.18);
    final box = AnimatedBuilder(
      animation: ambientPhase,
      builder: (context, _) {
        final t = Motion.enabled ? ambientPhase.value : 0.5;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Color.lerp(base, highlight, t),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
    return widget.width == null
        ? SizedBox(width: double.infinity, child: box)
        : box;
  }
}

/// 消息列表骨架：左右交替的气泡占位。
class AppChatSkeleton extends StatelessWidget {
  const AppChatSkeleton({super.key, this.rows = 7});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return ListView.builder(
      reverse: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      itemCount: rows,
      itemBuilder: (context, i) {
        final mine = i.isEven;
        final width = w * (mine ? 0.52 : 0.62) - (i % 3) * 18;
        return Padding(
          padding: EdgeInsets.only(
            top: Gap.sm,
            bottom: Gap.xs,
            left: mine ? w * 0.3 : Gap.xxl + Gap.sm,
            right: mine ? Gap.md : w * 0.24,
          ),
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (!mine) ...[
                const AppSkeleton(width: 64, height: 9),
                const SizedBox(height: Gap.xs + 2),
              ],
              AppSkeleton(
                width: width.clamp(80, w),
                height: 40,
                radius: Radii.bubble,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 列表行骨架（会话列表/成员列表用）。
class AppListSkeleton extends StatelessWidget {
  const AppListSkeleton({super.key, this.rows = 6, this.avatar = 46});

  final int rows;
  final double avatar;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      itemCount: rows,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.md),
        child: Row(
          children: [
            AppSkeleton(width: avatar, height: avatar, radius: avatar / 2),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 三条一循环的宽度，让骨架看起来像真列表
                  AppSkeleton(width: 64 + (i % 3) * 34, height: 11),
                  const SizedBox(height: Gap.sm),
                  const AppSkeleton(height: 9),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 统一 SnackBar：先清掉旧的，避免排队堆积。
abstract final class AppSnack {
  static void show(
    BuildContext context,
    String message, {
    bool error = false,
    SnackBarAction? action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                error ? Icons.error_outline : Icons.check_circle_outline,
                size: 18,
                color: error ? scheme.error : scheme.primary,
              ),
              const SizedBox(width: Gap.sm + 2),
              Expanded(child: Text(message)),
            ],
          ),
          action: action,
        ),
      );
  }
}
