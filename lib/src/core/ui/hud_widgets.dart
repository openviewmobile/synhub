import '../../design/design_palette.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../theme/app_typography.dart';

/// 遥测小字：时间 / 人数 / 状态 / 分隔标签。
///
/// 等宽 + 字距 + 半透明，是 HUD 风格里"信息即装饰"的落点。
class TelemetryLabel extends StatelessWidget {
  const TelemetryLabel(
    this.text, {
    super.key,
    this.size = 11.5,
    this.weight = FontWeight.w500,
    this.color,
    this.letterSpacing = 0.6,
    this.uppercase = false,
    this.decorative = false,
    this.maxLines = 1,
  });

  final String text;
  final double size;
  final FontWeight weight;
  final Color? color;
  final double letterSpacing;
  final bool uppercase;

  /// 纯装饰（不承载信息）：从无障碍树里摘掉，屏幕阅读器不必念
  /// "CH · 01""STEP 02"这类代号。
  final bool decorative;

  /// 行数上限。默认 1（遥测标签本来是短代号）；**长句提示**必须给 2，
  /// 否则 `ellipsis` 只会把句子截成半截（r532 `DA169`）。
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final hud = HudTokens.of(context);
    final label = Text(
      uppercase ? text.toUpperCase() : text,
      style: AppType.telemetry(
        size: size,
        weight: weight,
        color: color ?? hud.meta,
        letterSpacing: letterSpacing,
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
    return decorative ? ExcludeSemantics(child: label) : label;
  }
}

/// HUD 标签（切角）：日期分隔、系统消息、状态条。
///
/// 切角 + 细边缘高光 + 等宽小字 —— 一个控件就把"科幻感"立住了，而且信息密度高。
class HudChip extends StatelessWidget {
  const HudChip({
    super.key,
    required this.text,
    this.icon,
    this.color,
    this.onTap,
    this.dense = false,
    this.glow = false,
  });

  final String text;
  final IconData? icon;
  final Color? color;
  final VoidCallback? onTap;
  final bool dense;

  /// 是否加一层柔光（用于"新消息"这类需要被注意到的标签）
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurfaceVariant;
    final content = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? Gap.sm : Gap.md,
        vertical: dense ? 3 : 5,
      ),
      decoration: ShapeDecoration(
        // ★ r501：**切角 → 胶囊**。切角是上一版 HUD 的"仪表标签"造型，
        //   真机上系统消息（"Channel xxx was closed."）看着像一块八角铭牌，
        //   与设计语言的圆角行/胶囊芯片不是同一套。系统消息本质是**提示**，
        //   用胶囊 + 1px 描边最稳（浅底上也有边界）。
        shape: StadiumBorder(
          side: BorderSide(color: DesignPalette.of(context).line),
        ),
        // ★ r503：**`surface2` 在亮色下和聊天底色几乎同一个值**
        //   （实测：页面 `#F2F5F9`、`surface2` `#E8EEF6`；像素取样都是 (241,245,250)）
        //   ⇒ 系统消息胶囊"看不见"。改 `surface`（亮=白 / 暗=#1A1F27），
        //   两套主题都与底色分开，边界再由 `line` 描边兜住。
        color: DesignPalette.of(context).surface,
        shadows: glow
            ? [
                BoxShadow(
                  color: c.withValues(alpha: 0.28),
                  blurRadius: 14,
                  spreadRadius: -2,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 11 : 13, color: c),
            const SizedBox(width: Gap.xs + 1),
          ],
          // ★ r132（iOS 逐屏像素）：这里原来是裸 `TelemetryLabel`。
          //   `Text` 虽有 `maxLines: 1 + ellipsis`，但 `Row(mainAxisSize: min)`
          //   给**非 flex 子项**的横向约束是**无界**的 ⇒ 文本按自然宽度撑开，
          //   芯片整体超出父约束，Flutter 当场报
          //   `A RenderFlex overflowed by 185 pixels on the right.`
          //   （iPhone 16 / 393pt，约束 329pt；creator 链
          //   `Row ← … ← HudChip ← Center ← Padding ← _PostTile`，
          //   即聊天里的**系统消息**：`demo_user Cannot enter this channel; …`）
          //   修法：套 `Flexible` ⇒ 拿到"剩余宽度"这个**有界**约束，省略号才生效。
          Flexible(
            child: TelemetryLabel(
              text,
              size: dense ? 10.5 : 11.5,
              weight: FontWeight.w600,
              letterSpacing: 0.8,
              color: c,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: content,
    );
  }
}

/// 连接/在线指示：一个点 + 呼吸光环。
///
/// 用 `AnimatedContainer` 做无状态呼吸（不引 AnimationController，可随
/// 减少动效开关自动静止）。
class PulseDot extends StatefulWidget {
  const PulseDot({
    super.key,
    required this.color,
    this.size = 8,
    this.pulsing = true,
    this.semanticLabel,
  });

  final Color color;
  final double size;
  final bool pulsing;

  /// 无障碍标签（状态不能只靠颜色）
  final String? semanticLabel;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _breathe();
  }

  @override
  void didUpdateWidget(PulseDot old) {
    super.didUpdateWidget(old);
    // 只在 pulsing **状态发生变化**时重新呼吸。
    //
    // 早先的写法是"没在动就再动一次"，结果父级每重建一次（消息页有实时推送，
    // 经常重建）就把动画续上 → 永远不静止：既费电，也让 `uiautomator dump` /
    // `pumpAndSettle` 永远等不到 idle。
    if (widget.pulsing == old.pulsing) return;
    if (widget.pulsing) {
      _breathe();
    } else {
      _c.stop();
      _c.value = 0;
    }
  }

  /// **有限次**呼吸（3 个来回）后停住。
  ///
  /// 设计原则 "calm resting, vivid on interaction"：常驻脉冲既费电，也会让
  /// `pumpAndSettle` 永远不收敛（测试里就表现为超时）。静止的圆点一样能表达
  /// "在线"，动几下只是把注意力拉过来。
  void _breathe() {
    if (!Motion.enabled) {
      _c.stop();
      _c.value = 0;
      return;
    }
    _c.repeat(reverse: true, count: 3);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = SizedBox(
      width: widget.size * 2,
      height: widget.size * 2,
      child: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = Motion.enabled ? _c.value : 0.0;
            return Container(
              width: widget.size + t * 3,
              height: widget.size + t * 3,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.45 - t * 0.3),
                    blurRadius: 6 + t * 8,
                    spreadRadius: t * 2,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    final label = widget.semanticLabel;
    return label == null ? dot : Semantics(label: label, child: dot);
  }
}

/// 发送中：环形扫描进度（替代原来语义歧义的"闹钟"图标）。
class ScanRing extends StatefulWidget {
  const ScanRing({super.key, this.size = 14, this.color, this.semanticLabel});

  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  State<ScanRing> createState() => _ScanRingState();
}

class _ScanRingState extends State<ScanRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    // 扫描环是"进场特效"：有限 8 圈，且 `减少动效` 下直接停在终态。
    // （不要无条件 `..repeat()`：真机上会让 uiautomator 拿不到 idle。）
    if (Motion.enabled) _c.repeat(count: 8);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? HudTokens.of(context).scan;
    final ring = SizedBox(
      width: widget.size,
      height: widget.size,
      child: Motion.enabled
          ? RotationTransition(
              turns: _c,
              child: CustomPaint(painter: _ScanRingPainter(color: color)),
            )
          : CustomPaint(painter: _ScanRingPainter(color: color, static: true)),
    );
    final label = widget.semanticLabel;
    return label == null ? ring : Semantics(label: label, child: ring);
  }
}

class _ScanRingPainter extends CustomPainter {
  _ScanRingPainter({required this.color, this.static = false});

  final Color color;
  final bool static;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color.withValues(alpha: 0.22);
    canvas.drawArc(rect.deflate(1), 0, math.pi * 2, false, track);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.8
      ..color = color;
    canvas.drawArc(
      rect.deflate(1),
      static ? -math.pi / 2 : 0,
      math.pi * 0.55,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_ScanRingPainter old) =>
      old.color != color || old.static != static;
}

/// 头像：圆形 + 可选"环"（未读/在线/加密），并支持首字母或图标。
///
/// 现代 IM 的头像不只是一张图：环的颜色/形状编码状态，这里统一处理。
class RingAvatar extends StatelessWidget {
  const RingAvatar({
    super.key,
    this.label,
    this.icon,
    this.size = 44,
    this.background,
    this.image,
    this.ring,
    this.ringWidth = 2,
    this.badge,
    this.onTap,
    this.semanticLabel,
  });

  /// 首字母/短文本（与 [icon] 二选一）
  final String? label;
  final IconData? icon;
  final double size;
  final Color? background;

  /// 头像图片（用户真实头像）。非空时**优先于** [label]/[icon]，
  /// 但仍保留 [ring]/[badge] 与圆形裁切。见 `features/chat/user_avatar.dart`。
  final ImageProvider? image;

  /// 状态环颜色（未读/在线）。null = 不画环
  final Color? ring;
  final double ringWidth;

  /// 右下角小徽标（静音/加密/失败）
  final Widget? badge;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = background ?? scheme.primaryContainer;
    final fg = bg.computeLuminance() > 0.5
        ? scheme.onPrimaryContainer
        : Colors.white;
    final avatar = SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              image: image == null
                  ? null
                  : DecorationImage(image: image!, fit: BoxFit.cover),
              border: ring == null
                  ? null
                  : Border.all(color: ring!, width: ringWidth),
            ),
            alignment: Alignment.center,
            child: image != null
                ? null
                : icon != null
                ? Icon(icon, size: size * 0.46, color: fg)
                : Text(
                    label ?? '?',
                    style: TextStyle(
                      color: fg,
                      fontSize: size * 0.4,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
          ),
          if (badge != null) Positioned(right: -2, bottom: -2, child: badge!),
        ],
      ),
    );
    final body = onTap == null
        ? avatar
        : InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: avatar,
          );
    final l = semanticLabel;
    return l == null ? body : Semantics(label: l, child: body);
  }
}

/// 未读徽标（胶囊 + 切角可选），统一替代各处手写的 Container。
class CountBadge extends StatelessWidget {
  const CountBadge({
    super.key,
    required this.count,
    this.mention = false,
    this.color,
    this.dense = false,
  });

  final int count;

  /// @提及：用错误色（更醒目）
  final bool mention;
  final Color? color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = color ?? (mention ? scheme.error : scheme.primary);
    final fg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    final text = mention ? '@$count' : '$count';
    return Container(
      constraints: BoxConstraints(minWidth: dense ? 18 : 20),
      padding: EdgeInsets.symmetric(
        horizontal: count > 99 ? 5 : (dense ? 5 : 6),
        vertical: dense ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.capsule),
        boxShadow: [
          BoxShadow(
            color: bg.withValues(alpha: 0.35),
            blurRadius: 8,
            spreadRadius: -2,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        count > 999 ? '999+' : text,
        style: TextStyle(
          color: fg,
          fontSize: dense ? 10 : 11,
          height: 1.25,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 聊天背景：极淡网格 + 主色渐晕。
///
/// 静态绘制（无动画），成本可以忽略；给玻璃面板提供"有内容"的背景层次，
/// 否则半透明填充会显得发灰。可在设置里关掉。
class ChatBackdrop extends StatelessWidget {
  const ChatBackdrop({super.key, this.gridSize = 26, this.enabled = true});

  final double gridSize;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    final hud = HudTokens.of(context);
    return IgnorePointer(
      child: CustomPaint(
        painter: _BackdropPainter(
          grid: hud.grid,
          vignette: hud.vignette,
          gridSize: gridSize,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.grid,
    required this.vignette,
    required this.gridSize,
  });

  final Color grid;
  final Color vignette;
  final double gridSize;

  @override
  void paint(Canvas canvas, Size size) {
    // 渐晕：右上角一团主色柔光
    canvas.drawCircle(
      Offset(size.width * 0.85, -size.height * 0.1),
      size.width * 0.9,
      Paint()
        ..shader =
            RadialGradient(
              colors: [vignette, vignette.withValues(alpha: 0)],
            ).createShader(
              Rect.fromCircle(
                center: Offset(size.width * 0.85, -size.height * 0.1),
                radius: size.width * 0.9,
              ),
            ),
    );
    final p = Paint()
      ..color = grid
      ..strokeWidth = 0.7;
    for (double x = 0; x < size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y < size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.grid != grid || old.vignette != vignette || old.gridSize != gridSize;
}
