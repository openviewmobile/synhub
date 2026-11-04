import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_shapes.dart';
import '../theme/app_tokens.dart';

/// 玻璃面板 —— HUD 设计语言的基础面。
///
/// 层级不靠投影，靠三件事：
///   1. 半透明填充（叠在深色/网格背景上时能透出层次）；
///   2. **1px 边缘高光**：从左上到右下渐隐的描边，模拟玻璃棱边的反光；
///   3. 需要浮起时（坞/球/面板）才加投影。
///
/// 性能：`blur` 只在"铬部件"上用（顶栏/输入区/坞/面板）。消息气泡**不要**
/// 开 blur —— 一屏十几条 `BackdropFilter` 在中低端机上会掉帧；气泡用高不透明
/// 填充即可达到同样观感。性能模式（`AppEffects.reducedBlur`）下自动关掉模糊。
class GlassPane extends StatelessWidget {
  const GlassPane({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = Radii.pane,
    this.shape,
    this.blur,
    this.fill,
    this.showEdge = true,
    this.elevated = false,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// 圆角（`shape` 非空时忽略）
  final double radius;
  final ShapeBorder? shape;

  /// 背景模糊强度（null/0 = 不模糊）
  final double? blur;

  /// 覆盖填充色（默认 `HudTokens.glassStrong`）
  final Color? fill;

  /// 是否画边缘高光
  final bool showEdge;

  /// 是否加投影（只有真正浮起的元素才该开）
  final bool elevated;

  final Clip clipBehavior;

  /// 圆角矩形形状
  static ShapeBorder rounded(double radius) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));

  /// 切角形状（铬部件）
  static ShapeBorder chamfer({double cut = Radii.cut}) =>
      ChamferBorder(cut: cut);

  @override
  Widget build(BuildContext context) {
    final hud = HudTokens.of(context);
    final s = shape ?? rounded(radius);
    return ValueListenableBuilder<bool>(
      valueListenable: AppEffects.reducedBlur,
      builder: (context, reduced, _) {
        final sigma = (blur ?? 0) > 0 && !reduced ? blur! : 0.0;
        Widget panel = CustomPaint(
          painter: _GlassPainter(
            shape: s,
            fill: fill ?? hud.glassStrong,
            edge: showEdge ? hud.edge : null,
            edgeWidth: hud.edgeWidth,
            shadow: elevated ? hud.floatShadow : null,
          ),
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        );
        if (sigma > 0) {
          panel = BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: panel,
          );
        }
        panel = ClipPath(
          clipper: ShapeBorderClipper(shape: s),
          child: panel,
        );
        if (margin != null) {
          panel = Padding(padding: margin!, child: panel);
        }
        return panel;
      },
    );
  }
}

/// 画：投影 → 填充 → 边缘高光。
class _GlassPainter extends CustomPainter {
  _GlassPainter({
    required this.shape,
    required this.fill,
    required this.edge,
    required this.edgeWidth,
    required this.shadow,
  });

  final ShapeBorder shape;
  final Color fill;
  final Color? edge;
  final double edgeWidth;
  final List<BoxShadow>? shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = shape.getOuterPath(rect);
    if (shadow != null) {
      for (final s in shadow!) {
        canvas.drawShadow(path, s.color, s.blurRadius / 2, false);
      }
    }
    canvas.drawPath(path, Paint()..color = fill);
    final e = edge;
    if (e != null) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = edgeWidth
          ..shader = ui.Gradient.linear(
            rect.topLeft,
            rect.bottomRight,
            [e, e.withValues(alpha: e.a * 0.25), e.withValues(alpha: 0)],
            const [0, 0.45, 1],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_GlassPainter old) =>
      old.fill != fill ||
      old.edge != edge ||
      old.edgeWidth != edgeWidth ||
      old.shape != shape ||
      old.shadow != shadow;
}

/// 可点的玻璃面（带水波，且水波被裁进形状内）。
class GlassTap extends StatelessWidget {
  const GlassTap({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.padding,
    this.margin,
    this.radius = Radii.pane,
    this.shape,
    this.blur,
    this.fill,
    this.elevated = false,
    this.showEdge = true,
    this.haptic = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final ShapeBorder? shape;
  final double? blur;
  final Color? fill;
  final bool elevated;
  final bool showEdge;

  /// 长按是否给一次中等触觉反馈
  final bool haptic;

  @override
  Widget build(BuildContext context) {
    final s = shape ?? GlassPane.rounded(radius);
    return GlassPane(
      shape: s,
      blur: blur,
      fill: fill,
      elevated: elevated,
      showEdge: showEdge,
      margin: margin,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          onLongPress: onLongPress == null
              ? null
              : () {
                  if (haptic) HapticFeedbackCompat.medium();
                  onLongPress!();
                },
          borderRadius: s is RoundedRectangleBorder
              ? (s.borderRadius as BorderRadius?)?.resolve(null)
              : null,
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),
      ),
    );
  }
}

/// 触觉反馈的小封装：集中开关 + 语义化命名，避免各处直接调 `HapticFeedback`。
abstract final class HapticFeedbackCompat {
  /// 长按 / 进入选择态
  static void medium() {
    if (AppEffects.reducedMotion.value) return;
    HapticFeedback.mediumImpact();
  }

  /// 回应 / 切换 / 小确认
  static void light() {
    if (AppEffects.reducedMotion.value) return;
    HapticFeedback.lightImpact();
  }

  /// 失败 / 危险确认
  static void heavy() {
    if (AppEffects.reducedMotion.value) return;
    HapticFeedback.heavyImpact();
  }

  /// 滚动到底 / 列表吸附
  static void tick() => HapticFeedback.selectionClick();
}
