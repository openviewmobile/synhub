import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../theme/app_shapes.dart';
import '../theme/app_tokens.dart';
import 'glass_pane.dart';

/// 主行动球 —— 悬浮的圆形按钮（发送/新建/滚动到底/快速操作）。
///
/// 签名细节：主色渐变 + 顶部高光弧（模拟球面反光）+ 按压缩放。
/// 比 Material 默认 FAB 更有"硬件按钮"的质感，也是 HUD 风格里能量的出口。
class OrbButton extends StatefulWidget {
  const OrbButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 52,
    this.tooltip,
    this.semanticLabel,
    this.badge,
    this.filled = true,
    this.iconSize,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final String? tooltip;
  final String? semanticLabel;

  /// 右上角徽标（未读数等）
  final Widget? badge;

  /// true = 主色实心球；false = 玻璃球
  final bool filled;
  final double? iconSize;

  @override
  State<OrbButton> createState() => _OrbButtonState();
}

class _OrbButtonState extends State<OrbButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hud = HudTokens.of(context);
    // ★ r516（DA158）：**主行动球必须用设计令牌，不用 `scheme.primary`**。
    //   本机开着「动态取色（Material You）」⇒ `colorScheme.primary` 是从壁纸
    //   算出来的灰蓝 `(80,103,146)`，而同一屏的 chip / 文字 / 开关是令牌蓝
    //   `#2563EB (37,99,235)` —— 一个球比周围暗一档，看起来像"没点亮"。
    //   设计稿只有一个主色：令牌说了算。
    final dp = DesignPalette.of(context);
    final enabled = widget.onPressed != null;
    final diameter = widget.size;
    final baseColor = widget.filled ? dp.primary : hud.glassStrong;
    final fg = widget.filled ? dp.onPrimary : scheme.onSurface;

    Widget orb = AnimatedScale(
      scale: _down ? 0.92 : 1,
      duration: Motion.resolve(Motion.fast),
      curve: Motion.pop,
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled ? baseColor : baseColor.withValues(alpha: 0.5),
          gradient: widget.filled && enabled
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(dp.primary, Colors.white, 0.16)!,
                    dp.primary,
                  ],
                )
              : null,
          boxShadow: [
            ...hud.floatShadow.take(1),
            if (widget.filled && enabled)
              BoxShadow(
                color: dp.primary.withValues(alpha: 0.38),
                blurRadius: 18,
                spreadRadius: -4,
              ),
          ],
          border: widget.filled
              ? null
              : Border.all(color: hud.edge, width: hud.edgeWidth),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // ★ r492：顶部那块"高光弧"删掉了。设计稿的圆按钮是**平色 + 阴影**，
            //   而这块白色胶囊在深色主题下渲染成一坨白斑（真机 Files 页的 `+`
            //   看起来像渲染 bug，而不是高光）。按钮的"浮起感"由 `boxShadow` 负责。
            Icon(
              widget.icon,
              color: enabled ? fg : fg.withValues(alpha: 0.5),
              size: widget.iconSize ?? diameter * 0.44,
            ),
            if (widget.badge != null)
              Positioned(right: -2, top: -2, child: widget.badge!),
          ],
        ),
      ),
    );

    if (widget.onPressed != null) {
      orb = GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: () {
          HapticFeedbackCompat.light();
          widget.onPressed!();
        },
        behavior: HitTestBehavior.opaque,
        child: orb,
      );
    }

    final label = widget.semanticLabel ?? widget.tooltip;
    if (label != null) {
      orb = Semantics(button: true, label: label, child: orb);
    }
    if (widget.tooltip != null) {
      orb = Tooltip(message: widget.tooltip!, child: orb);
    }
    return orb;
  }
}

/// 会"变身"的圆按钮：麦克风 ⇄ 发送（WhatsApp/Signal 的手感）。
///
/// 用 `AnimatedSwitcher` + 旋转缩放过渡；图标切换时背景色也渐变。
class MorphOrbButton extends StatelessWidget {
  const MorphOrbButton({
    super.key,
    required this.morph,
    required this.icon,
    required this.onPressed,
    this.size = 46,
    this.tooltip,
    this.busy = false,
  });

  /// true = 发送态（有文本），false = 录音态（无文本）
  final bool morph;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final String? tooltip;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hud = HudTokens.of(context);
    final dp = DesignPalette.of(context);
    return AnimatedContainer(
      duration: Motion.resolve(Motion.fast),
      curve: Motion.out,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // 录音态是玻璃球（次要），发送态是主色球（主要）
        // DA158：同一个理由 —— 主色球用令牌蓝，不用动态取色的 scheme.primary。
        color: morph ? dp.primary : hud.glassStrong,
        border: morph
            ? null
            : Border.all(color: hud.edge, width: hud.edgeWidth),
        boxShadow: morph
            ? [
                BoxShadow(
                  color: dp.primary.withValues(alpha: 0.35),
                  blurRadius: 16,
                  spreadRadius: -4,
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: AnimatedSwitcher(
              duration: Motion.resolve(Motion.fast),
              switchInCurve: Motion.pop,
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: anim,
                child: RotationTransition(
                  turns: Tween<double>(begin: -0.12, end: 0).animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
              ),
              child: busy
                  ? SizedBox(
                      key: const ValueKey('busy'),
                      width: size * 0.42,
                      height: size * 0.42,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: morph ? dp.onPrimary : dp.primary,
                      ),
                    )
                  : Icon(
                      icon,
                      key: ValueKey('$morph-$icon'),
                      size: size * 0.46,
                      color: morph ? dp.onPrimary : scheme.onSurfaceVariant,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 切角小图标按钮（铬部件）：用于 AppBar action / 面板里的次要动作。
class HudIconButton extends StatelessWidget {
  const HudIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.color,
    this.size = 40,
    this.badge,
    this.glass = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;
  final double size;
  final Widget? badge;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hud = HudTokens.of(context);
    final fg = color ?? scheme.onSurfaceVariant;
    Widget child = Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Icon(
          icon,
          size: size * 0.5,
          color: onPressed == null ? fg.withValues(alpha: 0.4) : fg,
        ),
        if (badge != null) Positioned(right: -3, top: -3, child: badge!),
      ],
    );
    // 无障碍：视觉尺寸可以是 40，但**触摸目标**不能小于 48dp
    // （Material 的最小可点区域）。外面套一层 48 的盒子，绘制尺寸不变。
    final hit = size < kMinInteractiveDimension
        ? kMinInteractiveDimension
        : size;
    Widget body = SizedBox(
      width: hit,
      height: hit,
      child: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              customBorder: const ChamferBorder(cut: 8),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
    if (glass) {
      body = SizedBox(
        width: size,
        height: size,
        child: GlassTap(
          shape: const ChamferBorder(cut: 8),
          fill: hud.glass,
          blur: hud.blurChrome + 6,
          onTap: onPressed,
          haptic: false,
          child: Center(child: child),
        ),
      );
    }
    final label = tooltip;
    if (label != null) {
      body = Tooltip(
        message: label,
        child: Semantics(button: true, label: label, child: body),
      );
    }
    return body;
  }
}
