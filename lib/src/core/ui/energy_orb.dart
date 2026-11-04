// 科幻层组件 ③：能量核（EnergyOrb）—— 主行动 / 状态核心。
//
// 和 `OrbButton`（第一版的主行动球）的区别：
//   * 多层光环 + 两条反向旋转的轨道弧 + 内层脉冲（"反应堆"观感）；
//   * 中间可以放图标/文字/进度（连接中显示百分比）；
//   * 状态色可切换（待机 = 主色，失败 = warning，成功 = online）；
//   * 触摸时整核放大 + 增亮（动效即反馈）。
//
// 常驻旋转走 `AppEffects.ambientAllowed`（低频 20fps）；一次性脉冲用有限次。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../theme/app_typography.dart';
import 'ambient_clock.dart';
import 'hud_widgets.dart';

class EnergyOrb extends StatefulWidget {
  const EnergyOrb({
    super.key,
    this.size = 132,
    this.icon,
    this.label,
    this.caption,
    this.progress,
    this.color,
    this.busy = false,
    this.onTap,
    this.semanticLabel,
    this.rings = 2,
  });

  final double size;
  final IconData? icon;

  /// 核内主文字（例如"连接""登录"）
  final String? label;

  /// 核下小字（例如主机名/状态）
  final String? caption;

  /// 0~1：显示环形进度（连接中）
  final double? progress;

  final Color? color;
  final bool busy;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// 轨道弧条数
  final int rings;

  @override
  State<EnergyOrb> createState() => _EnergyOrbState();
}

// 两个 controller（自转 + 按压）→ 必须用 TickerProviderStateMixin
class _EnergyOrbState extends State<EnergyOrb>
    with TickerProviderStateMixin, AmbientAnimation<EnergyOrb> {
  // ★ r287：常驻自转改用共享常驻动效时钟（不再挂 vsync ticker）；
  //   `_press` 是**一次性**按压反馈，保持 AnimationController。
  @override
  Duration get ambientPeriod => const Duration(seconds: 9);

  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: Motion.fast,
    reverseDuration: Motion.instant,
  );

  @override
  void initState() {
    super.initState();
    AppEffects.reducedMotion.addListener(_sync);
  }

  void _sync() {
    if (!mounted) return;
    syncAmbient();
  }

  @override
  void dispose() {
    AppEffects.reducedMotion.removeListener(_sync);
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = widget.color ?? scheme.primary;
    final enabled = widget.onTap != null;
    final orb = AnimatedBuilder(
      animation: _press,
      builder: (context, _) {
        final k = 1 - _press.value * 0.05;
        return Transform.scale(
          scale: k,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: CustomPaint(
              painter: _OrbPainter(
                phase: ambientPhase,
                tint: tint,
                surface: scheme.surface,
                onSurface: scheme.onSurface,
                busy: widget.busy,
                progress: widget.progress,
                rings: widget.rings,
              ),
              child: Center(child: _core(context, tint)),
            ),
          ),
        );
      },
    );

    Widget result = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTapDown: enabled ? (_) => _press.forward() : null,
          onTapUp: enabled ? (_) => _press.reverse() : null,
          onTapCancel: enabled ? () => _press.reverse() : null,
          onTap: widget.onTap,
          child: orb,
        ),
        if (widget.caption != null) ...[
          const SizedBox(height: Gap.sm),
          TelemetryLabel(widget.caption!, size: 10, letterSpacing: 0.8),
        ],
      ],
    );
    if (widget.semanticLabel != null) {
      // 无障碍：整个核作为**一个**节点，label 就是调用方给的语义标签，
      // 内部那些装饰性小字（百分比/主机名）不再单独播报（ExcludeSemantics）。
      result = Semantics(
        container: true,
        button: enabled,
        label: widget.semanticLabel,
        child: ExcludeSemantics(child: result),
      );
    }
    return result;
  }

  Widget _core(BuildContext context, Color tint) {
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[
      if (widget.icon != null)
        Icon(widget.icon, size: widget.size * 0.26, color: scheme.onPrimary),
      if (widget.label != null && widget.icon == null)
        Text(
          widget.label!,
          textAlign: TextAlign.center,
          style: AppType.telemetry(
            size: widget.size * 0.11,
            weight: FontWeight.w700,
            color: scheme.onPrimary,
            letterSpacing: 1.2,
          ).copyWith(height: 1.15),
        ),
      if (widget.progress != null) ...[
        const SizedBox(height: Gap.xs),
        Text(
          '${(widget.progress! * 100).round()}%',
          style: AppType.telemetry(
            size: widget.size * 0.1,
            weight: FontWeight.w600,
            color: scheme.onPrimary.withValues(alpha: 0.9),
          ),
        ),
      ],
    ];
    return Padding(
      padding: EdgeInsets.all(widget.size * 0.2),
      // 能量核的直径是**固定值**，而核内的文字会跟随系统"字体大小"放大：
      // 2.0 缩放下图标/标签 + 百分比比核的可用高度还高，直接 RenderFlex
      // 溢出（登录页 / 连接页 / 诊断页实测）。`FittedBox.scaleDown` 只在
      // 放不下时等比缩小 —— 1.0 缩放完全不生效，外观与语义都不变。
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.phase,
    required this.tint,
    required this.surface,
    required this.onSurface,
    required this.busy,
    required this.progress,
    required this.rings,
  }) : super(repaint: phase);

  final ValueNotifier<double> phase;
  final Color tint;
  final Color surface;
  final Color onSurface;
  final bool busy;
  final double? progress;
  final int rings;

  @override
  void paint(Canvas canvas, Size size) {
    final t = phase.value;
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final coreR = r * 0.62;

    // 外辉光
    canvas.drawCircle(
      c,
      coreR * 1.16,
      Paint()
        ..shader = RadialGradient(
          colors: [
            tint.withValues(alpha: 0.36),
            tint.withValues(alpha: 0.06),
            // 同色透明：`Colors.transparent` 是 (0,0,0,0)，渐变会经过"半透明黑"，
            // 亮色主题下给能量核镶一圈脏灰边
            tint.withValues(alpha: 0),
          ],
          stops: const [0.55, 0.8, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: coreR * 1.2)),
    );

    // 核心球体：从 tint 亮部到暗部的径向渐变（有体积感）
    canvas.drawCircle(
      c,
      coreR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.05,
          colors: [
            Color.lerp(tint, Colors.white, 0.35)!,
            tint,
            Color.lerp(tint, Colors.black, 0.35)!,
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: coreR)),
    );

    // 内圈细边（玻璃壳）
    canvas.drawCircle(
      c,
      coreR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.35),
    );

    // 轨道弧：反向旋转的两条
    for (var i = 0; i < rings; i++) {
      final rr = coreR * (1.18 + i * 0.16);
      final dir = i.isEven ? 1.0 : -1.0;
      final start = (t * 6.28 * dir) + i * 1.9;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = i == 0 ? 2.4 : 1.4
        ..color = tint.withValues(alpha: i == 0 ? 0.7 : 0.4);
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: rr),
        start,
        1.15,
        false,
        paint,
      );
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: rr),
        start + math.pi,
        0.55,
        false,
        paint..color = tint.withValues(alpha: 0.22),
      );
    }

    // 进度环（连接中）
    if (progress != null && progress! > 0) {
      final rr = coreR * 1.46;
      canvas.drawCircle(
        c,
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = onSurface.withValues(alpha: 0.12),
      );
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: rr),
        -math.pi / 2,
        6.283 * progress!.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 3
          ..color = tint,
      );
    }

    // 忙碌：核内一圈细扫描（有限次，由 ScanRing 承担更合适，这里只做静态环）
    if (busy) {
      canvas.drawCircle(
        c,
        coreR * 0.86,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: 0.25),
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => false;
}
