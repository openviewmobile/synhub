// 整页天气动画背景（虚化）——日历页的"今天/那天在下雨"一眼可见。
//
// 用户要求原话："整块日历的背景是否可以展示当天天气的动画作为背景，不过这个背景
// 需要虚化，避免遮挡前面的日历文字"。
//
// 因此这里的分层是：
//   1. 一层很淡的**天气色晕**（`_WeatherPainter.wash`，alpha ≤ 0.22）；
//   2. 粒子动画（雨/雪/云/日光/星/雾），**先 `ImageFiltered` 高斯模糊再降透明度**，
//      所以永远只是"远处的天气"，不会和文字抢对比度；
//   3. 内容（日历本体）画在最上面 —— 顺序在 `Stack` 里就是"后画的在上面"。
//
// 两条硬约束：
//   * 常驻动效受 `AppEffects.ambientAllowed` 管（用户开了"减少动效"、系统关了动画、
//     或者跑在 `flutter test` 里 → 只画一帧静态图，`pumpAndSettle` 才停得下来）；
//   * 毛玻璃受 `AppEffects.blurAllowed` 管（低端机/省电模式可以关掉模糊，粒子直接降
//     透明度画，效果差一点但省 GPU）。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/ambient_clock.dart';

/// 背景要画的天气种类（由 WMO code 归并而来，够用就行）
enum WeatherScene {
  clearDay('calWeatherClearDay', '晴天'),
  clearNight('calWeatherClearNight', '晴夜'),
  cloudy('calWeatherCloudy', '多云'),
  rain('calWeatherRain', '雨'),
  snow('calWeatherSnow', '雪'),
  thunder('calWeatherThunder', '雷雨'),
  fog('calWeatherFog', '雾');

  const WeatherScene(this._labelKey, this._labelZh);

  final String _labelKey;
  final String _labelZh;

  /// 天气名称（跟随运行时语言；`dataText` 不是 const，所以只能做成 getter）
  String get label => dataText(_labelKey, _labelZh);

  /// 这层背景的主色（低透明度铺在页面上）
  Color tint(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (this) {
      // 白天暖金，夜里深蓝紫
      WeatherScene.clearDay =>
        dark ? const Color(0xFFFFC46B) : const Color(0xFFFFB74D),
      WeatherScene.clearNight => const Color(0xFF7C8CFF),
      WeatherScene.cloudy =>
        dark ? const Color(0xFF9FB3C8) : const Color(0xFF90A4AE),
      WeatherScene.rain => const Color(0xFF5C9DFF),
      WeatherScene.snow => const Color(0xFFBFE3FF),
      WeatherScene.thunder => const Color(0xFF8E7CFF),
      WeatherScene.fog => const Color(0xFF9E9E9E),
    };
  }

  /// 粒子数量（背景件，别太多）
  int get density => switch (this) {
    WeatherScene.rain => 64,
    WeatherScene.thunder => 70,
    WeatherScene.snow => 46,
    WeatherScene.clearNight => 60,
    WeatherScene.cloudy => 7,
    WeatherScene.fog => 5,
    WeatherScene.clearDay => 1,
  };
}

/// WMO 天气码 → 背景种类。
///
/// 和 `wmoText`/`wmoIcon` 的归类保持一致（`weather_client.dart`）：
/// 0~1 晴、2~3 多云、45/48 雾、51~67+80~82 雨、71~77+85/86 雪、95~99 雷。
WeatherScene weatherSceneForCode(int? code) {
  // 没拿到天气码 → 中性多云（不抢眼，也别假装是晴天）
  if (code == null) return WeatherScene.cloudy;
  final c = code;
  if (c == 0 || c == 1) return WeatherScene.clearDay;
  if (c == 45 || c == 48) return WeatherScene.fog;
  if (c >= 51 && c <= 67) return WeatherScene.rain;
  if ((c >= 71 && c <= 77) || c == 85 || c == 86) return WeatherScene.snow;
  if (c >= 80 && c <= 82) return WeatherScene.rain;
  if (c >= 95 && c <= 99) return WeatherScene.thunder;
  if (c == 2 || c == 3) return WeatherScene.cloudy;
  return WeatherScene.cloudy;
}

/// 源里的时间串 → 当天第几分钟。
///
/// ⚠️ 真机踩到过：Open-Meteo 的日出/日落是 **ISO 串**（`2026-09-23T05:48`），
/// 不是 `05:48`。直接 `split(':')` 会把 `2026-09-23T05` 当小时 → 解析失败，
/// 于是"夜里"永远判成白天（晴天背景该换星空也换不了）。
int? clockMinutes(String raw) {
  var t = raw.trim();
  if (t.isEmpty) return null;
  final i = t.indexOf('T');
  if (i >= 0) t = t.substring(i + 1);
  final parts = t.split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0].trim());
  final m = int.tryParse(parts[1].trim());
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// 时间串 → `HH:mm`（解析不出来回空串，UI 好判断要不要显示）
String clockText(String raw) {
  final minutes = clockMinutes(raw);
  if (minutes == null) return '';
  final h = (minutes ~/ 60) % 24;
  final m = minutes % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// 现在是不是夜里（日出前 / 日落后）。日出日落缺一个就当白天（保守）。
bool isNightNow({
  required String sunrise,
  required String sunset,
  required DateTime now,
}) {
  final rise = clockMinutes(sunrise);
  final set = clockMinutes(sunset);
  if (rise == null || set == null) return false;
  final minutes = now.hour * 60 + now.minute;
  return minutes < rise || minutes >= set;
}

/// 天气动画背景。[child] 画在最上面（不被虚化）。
class WeatherBackdrop extends StatefulWidget {
  const WeatherBackdrop({
    super.key,
    required this.scene,
    required this.child,
    this.enabled = true,
    this.opacity = 0.55,
    this.blurSigma = 14,
  });

  final WeatherScene scene;
  final Widget child;

  /// 总开关（设置里可以关掉：省电/看着晕）
  final bool enabled;

  /// 粒子层最不透明度（0~1）；色晕另算，乘在它上面
  final double opacity;

  /// 虚化半径（"避免遮挡前面的日历文字"靠它）
  final double blurSigma;

  @override
  State<WeatherBackdrop> createState() => _WeatherBackdropState();
}

class _WeatherBackdropState extends State<WeatherBackdrop>
    with AmbientAnimation<WeatherBackdrop> {
  // ★ r287：和 `FieldBackdrop` 一样改走共享常驻动效时钟（不再挂 vsync ticker）。
  @override
  Duration get ambientPeriod => const Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    AppEffects.reducedMotion.addListener(_sync);
  }

  void _sync() {
    if (!mounted) return;
    syncAmbient();
    if (!AppEffects.ambientAllowed) {
      // 减少动效/测试：停在一个固定相位，画一帧静态的天气（还是能看出在下雨/下雪）
      ambientPhase.value = 0.37;
    }
    setState(() {});
  }

  @override
  void dispose() {
    AppEffects.reducedMotion.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final brightness = Theme.of(context).brightness;
    final tint = widget.scene.tint(brightness);

    Widget particles = RepaintBoundary(
      child: CustomPaint(
        painter: _WeatherPainter(
          scene: widget.scene,
          phase: ambientPhase,
          tint: tint,
          // 亮色主题下背景本来就浅，粒子要更实一点才看得见；暗色反之
          strength: brightness == Brightness.dark ? 1.0 : 0.85,
        ),
      ),
    );
    if (AppEffects.blurAllowed) {
      // 虚化：让粒子变成"远处的天气"，文字对比度不受影响
      particles = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: widget.blurSigma,
          sigmaY: widget.blurSigma,
        ),
        child: particles,
      );
    }

    return Stack(
      children: [
        // 天气色晕（很淡；`FieldBackdrop` 的底色仍然透出来）
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              key: const Key('weather-backdrop-wash'),
              painter: _WashPainter(
                color: tint,
                alpha: widget.scene == WeatherScene.clearNight ? 0.18 : 0.12,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              key: const Key('weather-backdrop-particles'),
              opacity: widget.opacity,
              child: particles,
            ),
          ),
        ),
        Positioned.fill(child: widget.child),
      ],
    );
  }
}

/// 整页色晕：从底部往上淡出（天气的"天光"）
class _WashPainter extends CustomPainter {
  _WashPainter({required this.color, required this.alpha});

  final Color color;
  final double alpha;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(size.width / 2, size.height),
          Offset(size.width / 2, 0),
          [
            color.withValues(alpha: alpha),
            color.withValues(alpha: alpha * 0.25),
            color.withValues(alpha: 0),
          ],
          const [0, 0.55, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_WashPainter old) =>
      old.color != color || old.alpha != alpha;
}

/// 粒子层。所有位置都用 [phase]（0~1 循环）算出来，**不存状态**：
/// 这样 painter 是无副作用的，`shouldRepaint` 只看相位/尺寸/场景。
class _WeatherPainter extends CustomPainter {
  _WeatherPainter({
    required this.scene,
    required this.phase,
    required this.tint,
    required this.strength,
  }) : super(repaint: phase);

  final WeatherScene scene;
  final ValueNotifier<double> phase;
  final Color tint;
  final double strength;

  /// 确定性伪随机：同一个下标永远同一个值（不用 `Random()`，重绘才不会跳）
  static double _rnd(int i, [int salt = 0]) {
    final h = (i + 1) * 1103515245 + salt * 12345 + 1299709;
    return (h & 0x7fffffff) / 0x7fffffff;
  }

  /// -1~1 的对称摆动
  static double _sway(int i, double t) =>
      math.sin((t + _rnd(i, 7)) * math.pi * 2) * (0.5 + _rnd(i, 9) * 0.5);

  @override
  void paint(Canvas canvas, Size size) {
    final t = phase.value;
    switch (scene) {
      case WeatherScene.clearDay:
        _paintSun(canvas, size, t);
      case WeatherScene.clearNight:
        _paintNight(canvas, size, t);
      case WeatherScene.cloudy:
        _paintClouds(canvas, size, t);
      case WeatherScene.rain:
        _paintRain(canvas, size, t, lightning: false);
      case WeatherScene.thunder:
        _paintRain(canvas, size, t, lightning: true);
      case WeatherScene.snow:
        _paintSnow(canvas, size, t);
      case WeatherScene.fog:
        _paintFog(canvas, size, t);
    }
  }

  /// 晴天：右上角一轮日光 + 缓慢旋转的光芒
  void _paintSun(Canvas canvas, Size size, double t) {
    final center = Offset(size.width * 0.78, size.height * 0.12);
    final r = size.width * 0.16;
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          r * 2.1,
          [
            tint.withValues(alpha: 0.85 * strength),
            tint.withValues(alpha: 0.28 * strength),
            tint.withValues(alpha: 0),
          ],
          const [0, 0.45, 1],
        ),
    );
    final rays = Paint()
      ..color = tint.withValues(alpha: 0.30 * strength)
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 12; i++) {
      final a = t * math.pi * 2 + i * math.pi / 6;
      canvas.drawLine(
        center + Offset(math.cos(a), math.sin(a)) * (r * 1.15),
        center +
            Offset(math.cos(a), math.sin(a)) * (r * (1.5 + _rnd(i, 3) * 0.35)),
        rays,
      );
    }
  }

  /// 晴夜：星点闪烁 + 月亮光晕（星星从顶部往下慢慢掠过）
  void _paintNight(Canvas canvas, Size size, double t) {
    final moon = Offset(size.width * 0.2, size.height * 0.14);
    canvas.drawCircle(
      moon,
      size.width * 0.09,
      Paint()
        ..shader = ui.Gradient.radial(moon, size.width * 0.24, [
          const Color(0xFFF3F0FF).withValues(alpha: 0.5 * strength),
          const Color(0xFFF3F0FF).withValues(alpha: 0),
        ]),
    );
    for (var i = 0; i < scene.density; i++) {
      final x = _rnd(i, 1) * size.width;
      var y = (_rnd(i, 2) + t * (0.06 + _rnd(i, 5) * 0.06)) % 1.0;
      y *= size.height;
      // 闪烁：相位错开的方波近似
      final tw = 0.35 + 0.65 * (0.5 + 0.5 * _sway(i, t * 3));
      canvas.drawCircle(
        Offset(x, y),
        0.8 + _rnd(i, 4) * 1.6,
        Paint()..color = Colors.white.withValues(alpha: 0.75 * tw * strength),
      );
    }
  }

  /// 多云/阴：几坨大而软的云横着飘
  void _paintClouds(Canvas canvas, Size size, double t) {
    for (var i = 0; i < scene.density; i++) {
      final speed = 0.05 + _rnd(i, 1) * 0.10;
      var x = (_rnd(i, 2) + t * speed) % 1.0;
      // 左侧进右侧出：越界时从另一边回来（不用取模的话会闪一下）
      x = x * 1.3 - 0.15;
      final y = size.height * (0.05 + _rnd(i, 3) * 0.5);
      final w = size.width * (0.35 + _rnd(i, 4) * 0.5);
      final h = w * (0.18 + _rnd(i, 5) * 0.12);
      final rect = Rect.fromCenter(
        center: Offset(x * size.width, y),
        width: w,
        height: h,
      );
      canvas.drawOval(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            rect.center,
            w / 2,
            [
              tint.withValues(alpha: 0.34 * strength),
              tint.withValues(alpha: 0.10 * strength),
              tint.withValues(alpha: 0),
            ],
            const [0, 0.55, 1],
          ),
      );
    }
  }

  /// 雨/雷雨：斜着落下的雨丝（雷雨额外加一道闪）
  void _paintRain(
    Canvas canvas,
    Size size,
    double t, {
    required bool lightning,
  }) {
    final paint = Paint()
      ..color = tint.withValues(alpha: 0.55 * strength)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < scene.density; i++) {
      final speed = 1.6 + _rnd(i, 1) * 1.4;
      final x = _rnd(i, 2) * size.width;
      var y = (_rnd(i, 3) + t * speed) % 1.0;
      y *= size.height;
      final len = 14 + _rnd(i, 4) * 26;
      // 风：往左下斜（和体感一致，雨丝斜着更好看）
      final drift = -len * 0.32;
      canvas.drawLine(Offset(x, y), Offset(x + drift, y + len), paint);
    }
    if (lightning) {
      // 每 ~7 秒闪一次：用相位算，不做计时器
      final beat = (t * 7) % 1.0;
      if (beat < 0.08) {
        final a = (1 - beat / 0.08) * 0.42 * strength;
        canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..shader = ui.Gradient.linear(
              Offset(size.width * 0.7, 0),
              Offset(size.width * 0.2, size.height),
              [
                Colors.white.withValues(alpha: a),
                Colors.white.withValues(alpha: 0),
              ],
            ),
        );
      }
    }
  }

  /// 雪：慢速飘落 + 左右摇摆
  void _paintSnow(Canvas canvas, Size size, double t) {
    for (var i = 0; i < scene.density; i++) {
      final speed = 0.20 + _rnd(i, 1) * 0.35;
      var y = (_rnd(i, 2) + t * speed) % 1.0;
      y *= size.height;
      final x =
          (_rnd(i, 3) * size.width) +
          _sway(i, t * (0.6 + _rnd(i, 6) * 0.8)) * size.width * 0.05;
      final r = 1.4 + _rnd(i, 4) * 2.6;
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()..color = Colors.white.withValues(alpha: 0.72 * strength),
      );
    }
  }

  /// 雾：横向慢移的软带
  void _paintFog(Canvas canvas, Size size, double t) {
    for (var i = 0; i < scene.density; i++) {
      final speed = 0.03 + _rnd(i, 1) * 0.05;
      var x = (_rnd(i, 2) + t * speed) % 1.0;
      x = x * 1.4 - 0.2;
      final y = size.height * (0.12 + i * 0.18);
      final h = size.height * (0.05 + _rnd(i, 3) * 0.05);
      final rect = Rect.fromLTWH(x * size.width, y, size.width * 0.9, h);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(
            rect.centerLeft,
            rect.centerRight,
            [
              tint.withValues(alpha: 0),
              tint.withValues(alpha: 0.34 * strength),
              tint.withValues(alpha: 0),
            ],
            const [0, 0.5, 1],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_WeatherPainter old) =>
      old.scene != scene || old.tint != tint || old.strength != strength;
}
