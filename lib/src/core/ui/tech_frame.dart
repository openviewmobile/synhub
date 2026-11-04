// 科幻层组件 ①：科技边框 / 角括号 / 边缘刻度 / 数据带。
//
// 设计意图：HUD 第一版靠"玻璃 + 遥测小字"表达层级，观感还是偏"干净的现代"。
// 这一层给铬部件加上**仪表盘骨架**：四角括号（对焦框）、边缘刻度（量程）、
// 顶部数据带（滚动遥测）—— 让每一块面板一眼就像"某台机器的操作台"。
//
// 性能与测试：
//   * 括号/刻度是**静态 CustomPaint**，不吃帧；
//   * `TechFrame.sweep` 的进场光扫是一次性动画（有限次），不会常驻；
//   * `DataStrip` 是常驻滚动（约 20fps），走 `AppEffects.ambientAllowed` 闸门。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_shapes.dart';
import '../theme/app_tokens.dart';
import 'ambient_clock.dart';
import '../theme/app_typography.dart';
import 'glass_pane.dart';
import 'hud_widgets.dart';

/// 四角"对焦括号"：只画四个 L 形角，中间留空给内容。
class CornerBrackets extends StatelessWidget {
  const CornerBrackets({
    super.key,
    this.color,
    this.length = 14,
    this.thickness = 1.6,
    this.inset = 0,
    this.cut = 0,
  });

  final Color? color;
  final double length;
  final double thickness;
  final double inset;

  /// >0 时角也切成斜边（和 `ChamferBorder` 对齐）
  final double cut;

  @override
  Widget build(BuildContext context) {
    final hud = HudTokens.of(context);
    return IgnorePointer(
      child: CustomPaint(
        painter: _BracketPainter(
          color: color ?? hud.bracket,
          length: length,
          thickness: thickness,
          inset: inset,
          cut: cut,
        ),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  _BracketPainter({
    required this.color,
    required this.length,
    required this.thickness,
    required this.inset,
    required this.cut,
  });

  final Color color;
  final double length;
  final double thickness;
  final double inset;
  final double cut;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final l = inset, t = inset, r = size.width - inset, b = size.height - inset;
    final len = math.min(length, math.min(size.width, size.height) / 2.4);
    final c = cut > 0 ? math.min(cut, len) : 0.0;

    // 左上
    canvas.drawPath(
      Path()
        ..moveTo(l, t + len)
        ..lineTo(l, t + c)
        ..lineTo(l + c, t)
        ..lineTo(l + len, t),
      p,
    );
    // 右上
    canvas.drawPath(
      Path()
        ..moveTo(r - len, t)
        ..lineTo(r - c, t)
        ..lineTo(r, t + c)
        ..lineTo(r, t + len),
      p,
    );
    // 右下
    canvas.drawPath(
      Path()
        ..moveTo(r, b - len)
        ..lineTo(r, b - c)
        ..lineTo(r - c, b)
        ..lineTo(r - len, b),
      p,
    );
    // 左下
    canvas.drawPath(
      Path()
        ..moveTo(l + len, b)
        ..lineTo(l + c, b)
        ..lineTo(l, b - c)
        ..lineTo(l, b - len),
      p,
    );
  }

  @override
  bool shouldRepaint(_BracketPainter old) =>
      old.color != color ||
      old.length != length ||
      old.thickness != thickness ||
      old.inset != inset ||
      old.cut != cut;
}

/// 边缘刻度：沿上/下（或左/右）边的短刻度线，像仪器量程。
class EdgeTicks extends StatelessWidget {
  const EdgeTicks({
    super.key,
    this.color,
    this.count = 24,
    this.length = 4,
    this.majorEvery = 6,
    this.majorLength = 8,
    this.thickness = 1,
    this.axis = Axis.horizontal,
  });

  final Color? color;
  final int count;
  final double length;
  final int majorEvery;
  final double majorLength;
  final double thickness;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final hud = HudTokens.of(context);
    return IgnorePointer(
      child: CustomPaint(
        painter: _TicksPainter(
          color: color ?? hud.tick,
          count: count,
          length: length,
          majorEvery: majorEvery,
          majorLength: majorLength,
          thickness: thickness,
          axis: axis,
        ),
      ),
    );
  }
}

class _TicksPainter extends CustomPainter {
  _TicksPainter({
    required this.color,
    required this.count,
    required this.length,
    required this.majorEvery,
    required this.majorLength,
    required this.thickness,
    required this.axis,
  });

  final Color color;
  final int count;
  final double length;
  final int majorEvery;
  final double majorLength;
  final double thickness;
  final Axis axis;

  @override
  void paint(Canvas canvas, Size size) {
    if (count <= 1) return;
    final p = Paint()..color = color;
    final span = axis == Axis.horizontal ? size.width : size.height;
    final step = span / (count - 1);
    for (var i = 0; i < count; i++) {
      final major = majorEvery > 0 && i % majorEvery == 0;
      final len = major ? majorLength : length;
      final pos = i * step;
      if (axis == Axis.horizontal) {
        canvas.drawRect(Rect.fromLTWH(pos, 0, thickness, len), p);
        canvas.drawRect(
          Rect.fromLTWH(pos, size.height - len, thickness, len),
          p,
        );
      } else {
        canvas.drawRect(Rect.fromLTWH(0, pos, len, thickness), p);
        canvas.drawRect(
          Rect.fromLTWH(size.width - len, pos, len, thickness),
          p,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TicksPainter old) =>
      old.color != color ||
      old.count != count ||
      old.length != length ||
      old.majorEvery != majorEvery ||
      old.majorLength != majorLength ||
      old.axis != axis;
}

/// 科技面板：切角玻璃 + 角括号 + 边缘刻度 + 顶部遥测标签（可选编号/状态点）。
class TechFrame extends StatelessWidget {
  const TechFrame({
    super.key,
    required this.child,
    this.label,
    this.code,
    this.leading,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.lg),
    this.margin,
    this.accent,
    this.blur,
    this.glow = false,
    this.brackets = true,
    this.ticks = true,
    this.sweep = false,
    this.statusDot = false,
    this.cut = Radii.cut,
    this.fill,
  });

  /// 内容
  final Widget child;

  /// 顶部左侧标题（大写遥测字）
  final String? label;

  /// 顶部右侧编号 / 状态串（等宽小字）
  final String? code;

  final Widget? leading;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  /// 覆盖强调色（括号/标签/光扫）
  final Color? accent;

  /// 传给 `GlassPane` 的模糊强度（受性能模式约束）
  final double? blur;

  /// 外辉光
  final bool glow;

  /// 四角括号
  final bool brackets;

  /// 上下边缘刻度
  final bool ticks;

  /// 进场一次性光扫
  final bool sweep;

  /// 标题前的小状态点
  final bool statusDot;

  final double cut;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final hud = HudTokens.of(context);
    final tint = accent ?? Theme.of(context).colorScheme.primary;
    final shape = ChamferBorder(cut: cut);
    final header = (label != null || code != null || trailing != null)
        ? Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: Gap.sm),
                ] else if (statusDot) ...[
                  PulseDot(color: tint, size: 3.5, pulsing: false),
                  const SizedBox(width: Gap.sm),
                ],
                if (label != null)
                  Flexible(
                    child: TelemetryLabel(
                      label!,
                      size: 10.5,
                      letterSpacing: 1.1,
                      uppercase: true,
                      // 面板代号属于"仪器标签"，不承载语义信息
                      decorative: true,
                      color: tint.withValues(alpha: 0.9),
                    ),
                  ),
                if (code != null) ...[
                  const Spacer(),
                  ExcludeSemantics(
                    child: Text(
                      code!,
                      style: AppType.telemetry(size: 10, color: hud.meta),
                    ),
                  ),
                ],
                if (trailing != null) ...[
                  const SizedBox(width: Gap.sm),
                  trailing!,
                ],
              ],
            ),
          )
        : const SizedBox.shrink();

    Widget panel = GlassPane(
      shape: shape,
      blur: blur ?? hud.blurSheet,
      fill: fill,
      padding: padding,
      margin: margin,
      elevated: glow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [header, child],
      ),
    );

    if (glow) {
      panel = DecoratedBox(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: tint.withValues(alpha: 0.18),
              blurRadius: 34,
              spreadRadius: -6,
            ),
          ],
        ),
        child: panel,
      );
    }

    Widget stacked = Stack(
      children: [
        panel,
        if (brackets)
          Positioned.fill(
            child: CornerBrackets(
              color: tint.withValues(alpha: 0.55),
              inset: 3,
              cut: cut,
            ),
          ),
        if (ticks)
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: EdgeTicks(
                color: hud.tick.withValues(alpha: 0.5),
                count: 18,
                majorEvery: 6,
              ),
            ),
          ),
      ],
    );

    if (sweep) {
      stacked = ScanSweep(color: tint, child: stacked);
    }
    return margin != null ? Padding(padding: margin!, child: stacked) : stacked;
  }
}

/// 一行遥测：`键 ·············· 值`（点线引导 + 等宽）。
class TelemetryRow extends StatelessWidget {
  const TelemetryRow({
    super.key,
    required this.label,
    required this.value,
    this.color,
    this.dense = false,
    this.valueFlex = 3,
    this.maxLines = 1,
  });

  final String label;
  final String value;
  final Color? color;
  final bool dense;

  /// 值列最多占多少份（点线至少留 1 份）—— 长值（完整 QuickConnect ID、
  /// 主机名、conn_id）在窄屏上必须让位，否则 RenderFlex 必然溢出。
  final int valueFlex;

  /// 默认单行省略号；需要完全展开时传更大的值并配 `maxLines`
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final hud = HudTokens.of(context);
    final size = dense ? 9.5 : 10.5;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 1 : 2.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          // label 与 value 都必须是"可让位"的：只有点线是 Expanded 的话，
          // 长 label/长 value 会在窄屏直接把行撑爆（320dp 实测溢出）。
          Flexible(
            flex: 3,
            child: Text(
              label,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: AppType.telemetry(size: size, color: hud.meta),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
              child: CustomPaint(
                size: const Size(double.infinity, 1),
                painter: _DotLeaderPainter(
                  color: hud.tick.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
          Flexible(
            flex: valueFlex,
            child: Text(
              value,
              maxLines: maxLines,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: AppType.telemetry(
                size: size,
                weight: FontWeight.w600,
                color: color ?? Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DotLeaderPainter extends CustomPainter {
  _DotLeaderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    const dot = 1.4;
    const gap = 4.0;
    final y = size.height / 2;
    for (var x = 0.0; x + dot <= size.width; x += gap) {
      canvas.drawCircle(Offset(x + dot / 2, y), dot / 2, p);
    }
  }

  @override
  bool shouldRepaint(_DotLeaderPainter old) => old.color != color;
}

/// 一次性"光扫"：一条斜向光带从左上扫到右下，然后消失（进场/发送这类时刻用）。
class ScanSweep extends StatefulWidget {
  const ScanSweep({
    super.key,
    required this.child,
    this.color,
    this.duration = const Duration(milliseconds: 900),
    this.delay = const Duration(milliseconds: 120),
    this.strength = 0.5,
  });

  final Widget child;
  final Color? color;
  final Duration duration;
  final Duration delay;
  final double strength;

  @override
  State<ScanSweep> createState() => _ScanSweepState();
}

class _ScanSweepState extends State<ScanSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.resolve(widget.duration),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (Motion.enabled) {
      // 用可取消的 Timer（`Future.delayed` 在 widget 销毁后仍会挂着一个
      // pending timer，测试框架会直接判失败）
      _timer = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tint = widget.color ?? Theme.of(context).colorScheme.primary;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  if (_c.value == 0 || _c.value == 1) {
                    return const SizedBox.shrink();
                  }
                  return CustomPaint(
                    painter: _SweepPainter(
                      progress: _c.value,
                      color: tint.withValues(alpha: widget.strength),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SweepPainter extends CustomPainter {
  _SweepPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 一条斜向光带：中心在 progress 处，两侧渐隐
    final travel = size.width + size.height;
    final center = progress * travel;
    const band = 120.0;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.save();
    canvas.clipRect(rect);
    final shader = _sweepShader(center, band, color);
    final p = Paint()
      ..shader = shader
      ..blendMode = BlendMode.plus;
    final path = Path()
      ..moveTo(center - band, 0)
      ..lineTo(center + band, 0)
      ..lineTo(center + band - size.height, size.height)
      ..lineTo(center - band - size.height, size.height)
      ..close();
    canvas.drawPath(path, p);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SweepPainter old) =>
      old.progress != progress || old.color != color;
}

/// 光扫用的斜向线性渐变
Shader _sweepShader(double center, double band, Color color) {
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [color.withValues(alpha: 0), color, color.withValues(alpha: 0)],
    stops: const [0.0, 0.5, 1.0],
  ).createShader(Rect.fromLTWH(center - band, 0, band * 2, band * 2));
}

/// 滚动数据带：把若干遥测串拼起来横向匀速滚动（常驻效果，20fps）。
///
/// 只在 `AppEffects.ambientAllowed` 时滚动；否则就静态显示第一段。
class DataStrip extends StatefulWidget {
  const DataStrip({
    super.key,
    required this.items,
    this.separator = '  ·  ',
    this.height = 22,
    this.speed = 18,
    this.color,
    this.prefix,
  });

  final List<String> items;
  final String separator;
  final double height;

  /// 每秒滚动多少逻辑像素
  final double speed;
  final Color? color;
  final String? prefix;

  @override
  State<DataStrip> createState() => _DataStripState();
}

class _DataStripState extends State<DataStrip>
    with AmbientAnimation<DataStrip> {
  // ★ r287：滚动相位改由共享常驻动效时钟推进（原来是 vsync ticker + 手动限频，
  //   限频只限住了"画什么"，引擎仍按 60fps 排帧）。
  @override
  Duration get ambientPeriod => const Duration(seconds: 10);

  double _offset = 0;
  double _textWidth = 0;

  @override
  void initState() {
    super.initState();
    AppEffects.reducedMotion.addListener(_sync);
    ambientPhase.addListener(_onTick);
  }

  /// 常驻滚动：跟随"减少动效"实时启停（关掉就停在原地，不重绘）。
  void _sync() {
    if (!mounted) return;
    syncAmbient();
  }

  void _onTick() {
    if (!mounted) return;
    final dt = AppEffects.ambientTick.inMilliseconds / 1000.0;
    setState(() {
      _offset += widget.speed * dt;
      if (_textWidth > 0 && _offset >= _textWidth) _offset -= _textWidth;
    });
  }

  @override
  void dispose() {
    AppEffects.reducedMotion.removeListener(_sync);
    ambientPhase.removeListener(_onTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTokens.of(context);
    final text = widget.items.join(widget.separator);
    final style = AppType.telemetry(
      size: 10,
      color: widget.color ?? hud.meta,
      letterSpacing: 0.8,
    );
    return ExcludeSemantics(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        // ★★ `DA283`（r664）：**宽度必须吃满父级**。
        //   以前这里只有 `height`，而里面是
        //   `ClipRect → LayoutBuilder → Stack`，**Stack 的子节点全是 `Positioned`**
        //   ⇒ Stack 尺寸算出来是 0×0 ⇒ 整条带子塌成
        //   `2 × Gap.lg = 32` 宽、`height + 2 × Gap.xs = 30.8` 高：
        //   屏幕上看到的就是**正下方居中的一个 32×30.8 灰方块**
        //   （iOS/Web 真机像素取证 `docs/evidence-r664/`），
        //   滚动的 `NODE … · TARGET … · APP v…` 被 `ClipRect` 全裁掉 ——
        //   这条底部信息带**从来没显示过**。
        //   放进 Column（唯一的 4 个调用点都在竖向容器里）时 `double.infinity`
        //   会取父级 `maxWidth`，若将来放进无界宽度处会**响亮抛错**，不再静默塌陷。
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, c) {
              return Stack(
                children: [
                  Positioned(
                    left: -_offset,
                    top: 0,
                    bottom: 0,
                    child: Row(
                      children: [
                        if (widget.prefix != null) ...[
                          Text(
                            widget.prefix!,
                            style: style.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: Gap.sm),
                        ],
                        Text(text, style: style),
                      ],
                    ),
                  ),
                  // 量一次文本宽度（TextPainter），用来做无缝回绕
                  Builder(
                    builder: (context) {
                      final tp = TextPainter(
                        text: TextSpan(text: text, style: style),
                        textDirection: Directionality.of(context),
                        maxLines: 1,
                      )..layout();
                      if (tp.width > 0 && _textWidth != tp.width) {
                        _textWidth = tp.width;
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
