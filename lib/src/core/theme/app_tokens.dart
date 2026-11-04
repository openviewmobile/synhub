/// 设计语言的"数值底座"。
///
/// 这一版 UI 的设计代号是 **HUD（座舱玻璃）**，六条原则：
///   1. 玻璃而不是纸：面用半透明玻璃 + 1px 边缘高光表达层级，不靠投影；
///   2. 遥测而不是装饰：时间/状态/meta 用等宽小字（`AppType.telemetry`）排版，
///      让"信息本身"成为视觉风格；
///   3. 一个强调色、多种状态：主色跟随 Material You（用户可控），所以**识别度
///      必须来自结构 + 动效 + 光**，状态一律"形状/图标 + 颜色"双编码，绝不只靠色相；
///   4. 切角 + 胶囊：铬部件（标签/徽标/坞/球）用切角八边形，内容用胶囊与圆角矩形；
///   5. 动效即反馈：所有状态变化都有 90~420ms 的过渡；
///   6. 静息克制、交互时才炫：静止界面低对比，能量（辉光/扫描/扫描线）只给交互
///      与状态变化，所以"高科技"但不吵。
///
/// 第二版（科幻加权）在此基础上加一层**"深空座舱"**：透视网格地平线 + 星尘粒子 +
/// 切角科技边框（角括号 / 边缘刻度 / 数据带）+ 能量核（多层光环 / 轨道弧 / 光扫）。
/// 这一层全部走 `AppEffects.ambientAllowed` 闸门，并且用**低频重绘**（~20fps）
/// 而不是 60fps，保证"炫"不等于"费电"。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

/// 8dp 栅格。所有间距都从这里取，禁止散落魔数。
abstract final class Gap {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// 圆角/切角取值。
abstract final class Radii {
  /// 消息气泡（组外侧）
  static const double bubble = 18;

  /// 消息气泡（同发送者连续消息的内侧角）
  static const double bubbleInner = 6;

  /// 玻璃面板（卡片/弹层内的块）
  static const double pane = 20;

  /// 底部面板
  static const double sheet = 28;

  /// 气泡内嵌内容（图片/链接预览/文件）
  static const double embed = 14;

  /// 胶囊
  static const double capsule = 999;

  /// 铬部件的切角尺寸
  static const double cut = 9;
}

/// 动效时长与曲线。
abstract final class Motion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration base = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 420);

  /// 标准出场：先快后缓，观感"稳"
  static const Curve out = Cubic(0.2, 0, 0, 1);

  /// 强调曲线：用于选中/展开这类需要一点"弹"的地方
  static const Curve emphasized = Cubic(0.05, 0.7, 0.1, 1);

  /// 微回弹（图标/徽标出现）
  static const Curve pop = Curves.easeOutBack;

  /// 系统是否要求减少动效（无障碍）或用户在设置里关了效果
  static bool get enabled =>
      !AppEffects.reducedMotion.value &&
      !PlatformDispatcher.instance.accessibilityFeatures.disableAnimations;

  /// 实际使用的时长：减少动效时统一压到 0（widget 里用 `Duration.zero` 走
  /// 立即生效分支）。
  static Duration resolve(Duration d) => enabled ? d : Duration.zero;

  static Curve resolveCurve(Curve c) => enabled ? c : Curves.linear;
}

/// 全局效果开关。
///
/// * `reducedMotion`：无障碍/省电 —— 关掉所有非必要动画；
/// * `reducedBlur`：性能模式 —— 关掉 `BackdropFilter`（中低端机上毛玻璃
///   很贵，一条消息列表里尤其明显）。
abstract final class AppEffects {
  static final ValueNotifier<bool> reducedMotion = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> reducedBlur = ValueNotifier<bool>(false);

  /// flutter_test 环境（`flutter test` 会设这个变量）。测试里必须关掉**常驻**
  /// 动效，否则 `pumpAndSettle` 永远等不到停帧。
  // ★ 第 336 轮：`Platform.environment` 在 web 上**抛**（dart2js 的 dart:io 是抛错桩）
  //   ⇒ `!kIsWeb` 必须在最左（它是启动期主题初始化会碰到的 `static final`）。
  static final bool isFlutterTest = !kIsWeb && Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  /// 是否允许毛玻璃
  static bool get blurAllowed => !reducedBlur.value;

  /// 是否允许**常驻**动效（星尘粒子 / 网格漂移 / 轨道旋转 / 数据带滚动）：
  /// 用户开"减少动效"、系统"移除动画"、或跑在测试里都不动。
  /// 一次性动效（进场/光扫/按压缩放）不受这个开关约束，它们自己会结束。
  static bool get ambientAllowed =>
      debugAmbientAllowedOverride ?? (Motion.enabled && !isFlutterTest);

  /// 用例**专用**的常驻动效开关（r287）。
  ///
  /// 生产路径恒为 `null` ⇒ 行为逐字节不变；只在 `test/ambient_clock_test.dart`
  /// 里被置为 `true`，用来量"排帧次数"，因为 `flutter_test` 下
  /// `isFlutterTest == true` 会把常驻动效恒关，量不到时钟机制。
  @visibleForTesting
  static bool? debugAmbientAllowedOverride;

  /// 常驻动效的重绘间隔（约 20fps）：这些效果本身很慢，没必要 60fps 白烧电。
  static const Duration ambientTick = Duration(milliseconds: 50);

  /// 主题里读一次，把两个开关同步进来（`app.dart` 在 build 时调用）。
  static void sync({required bool reducedMotion, required bool reducedBlur}) {
    AppEffects.reducedMotion.value = reducedMotion;
    AppEffects.reducedBlur.value = reducedBlur;
  }
}

/// HUD 设计令牌（跟随亮/暗与动态主色自动生成）。
///
/// 只放"ColorScheme 表达不了"的语义色与玻璃参数；能用 `colorScheme.*` 的地方
/// 一律不要新增字段。
@immutable
class HudTokens extends ThemeExtension<HudTokens> {
  const HudTokens({
    required this.glass,
    required this.glassStrong,
    required this.edge,
    required this.edgeWidth,
    required this.bubbleMine,
    required this.bubbleMineText,
    required this.bubbleOther,
    required this.bubbleOtherText,
    required this.meta,
    required this.online,
    required this.warning,
    required this.star,
    required this.grid,
    required this.vignette,
    required this.scan,
    required this.floatShadow,
    required this.blurChrome,
    required this.blurSheet,
    this.deep = const Color(0xFF060911),
    this.horizon = const Color(0x33FFFFFF),
    this.gridStrong = const Color(0x22FFFFFF),
    this.beam = const Color(0x66FFFFFF),
    this.tick = const Color(0x55FFFFFF),
    this.bracket = const Color(0x66FFFFFF),
    this.particle = const Color(0x99FFFFFF),
    this.glow = const Color(0xFFFFFFFF),
    this.scanlineAlpha = 0.05,
    this.fieldVeil = const Color(0x00FFFFFF),
    this.fieldVeilRadius = 0.62,
    this.fieldLineBudget = 1,
  });

  /// 玻璃填充（面板/坞/输入区；叠在背景之上）
  final Color glass;

  /// 需要保证文字对比度时的玻璃填充（更不透明）
  final Color glassStrong;

  /// 边缘高光起始色（渐变到透明 → 类似反光棱边）
  final Color edge;
  final double edgeWidth;

  final Color bubbleMine;
  final Color bubbleMineText;
  final Color bubbleOther;
  final Color bubbleOtherText;

  /// 遥测小字（时间/人数/状态说明）
  final Color meta;

  /// 语义色：在线（固定绿，不跟随主色，避免"在线=主色"在动态取色下失真）
  final Color online;
  final Color warning;
  final Color star;

  /// 聊天背景的网格线 / 渐晕
  final Color grid;
  final Color vignette;

  /// 扫描/进行中（取自主色）
  final Color scan;

  /// 浮起元素的投影（只用给坞/球/面板这类真正浮起的东西）
  final List<BoxShadow> floatShadow;

  final double blurChrome;
  final double blurSheet;

  // ---------------------------------------------------------------- 科幻层
  /// 全屏科幻底色（登录/连接这类"英雄页"铺满，聊天页只在暗色下垫一层）
  final Color deep;

  /// 透视网格的远/近线色
  final Color horizon;

  /// 前景网格线（比 [grid] 亮一档）
  final Color gridStrong;

  /// 扫描光带
  final Color beam;

  /// 边缘刻度线
  final Color tick;

  /// 角括号 / 切角描边
  final Color bracket;

  /// 星尘粒子
  final Color particle;

  /// 辉光主色（一般就是 primary，单独放是给"暗色下要更亮"留口子）
  final Color glow;

  /// 扫描线罩层透明度
  final double scanlineAlpha;

  /// **内容核心的"静区"面纱**：盖在网格/星尘之上、内容之下。
  ///
  /// 网格线在消失点会堆叠成深色"结"，星尘是随机亮点 —— 文字一旦落在上面，
  /// 对比度会崩（实测亮色主题最坏只有 1.0:1）。这层面纱按径向渐变把**画面中心**
  /// （列表/正文真正待的地方）压回接近纯 [deep]，让底纹只在四周当氛围。
  final Color fieldVeil;

  /// 静区半径（相对短边；1.0 = 到屏幕边缘）
  final double fieldVeilRadius;

  /// 底纹预算：网格线/星尘的整体透明度倍率（1 = 按 token 原值）
  final double fieldLineBudget;

  /// 辉光投影（能量核/主行动球）
  List<BoxShadow> get glowShadow => [
    BoxShadow(
      color: glow.withValues(alpha: 0.35),
      blurRadius: 24,
      spreadRadius: -2,
    ),
    BoxShadow(
      color: glow.withValues(alpha: 0.18),
      blurRadius: 48,
      spreadRadius: 2,
    ),
  ];

  /// 亮色：我发的气泡用主色（动态取色下用户自己的颜色），对方用容器灰。
  factory HudTokens.light(ColorScheme s) => HudTokens(
    glass: s.surface.withValues(alpha: 0.74),
    glassStrong: s.surface.withValues(alpha: 0.93),
    edge: s.onSurface.withValues(alpha: 0.16),
    edgeWidth: 1.1,
    bubbleMine: s.primary.withValues(alpha: 0.94),
    bubbleMineText: s.onPrimary,
    bubbleOther: s.surfaceContainerHighest.withValues(alpha: 0.88),
    bubbleOtherText: s.onSurface,
    // ★ r518（DA160 的连带）：`onSurfaceVariant` 现在是令牌 `muted`（#5B6B7F），
    // 再乘 0.78 透明度 → 亮色对比度只有 3.1:1，读不清（守卫 `backdrop_legibility_test`
    // 当场打红）。亮色的遥测小字直接用满不透明度的 `muted`：4.67:1。
    meta: s.onSurfaceVariant,
    // 语义色在**浅底**上必须够深：亮色主题用深色变体（≥3:1），
    // 暗色主题才用亮色变体（见 HudTokens.dark）
    online: const Color(0xFF067647),
    warning: const Color(0xFFB54708),
    star: const Color(0xFF9A6700),
    grid: s.onSurface.withValues(alpha: 0.10),
    vignette: s.primary.withValues(alpha: 0.05),
    scan: s.primary,
    floatShadow: [
      BoxShadow(
        color: s.shadow.withValues(alpha: 0.16),
        blurRadius: 24,
        offset: const Offset(0, 8),
      ),
    ],
    blurChrome: 16,
    blurSheet: 24,
    deep: const Color(0xFFF1F5FB),
    horizon: s.primary.withValues(alpha: 0.30),
    gridStrong: s.onSurface.withValues(alpha: 0.08),
    beam: s.primary.withValues(alpha: 0.32),
    tick: s.onSurface.withValues(alpha: 0.26),
    bracket: s.primary.withValues(alpha: 0.55),
    particle: s.primary.withValues(alpha: 0.40),
    glow: s.primary,
    scanlineAlpha: 0.03,
    // 亮色下网格线是**深色**线，最抢文字 → 静区要更实
    fieldVeil: const Color(0xFFF1F5FB).withValues(alpha: 0.94),
    fieldVeilRadius: 0.86,
    fieldLineBudget: 0.75,
  );

  /// 暗色：我发的气泡用 `primaryContainer`（暗色下更沉、对比更强），
  /// 对方用 `surfaceContainerHigh`；边缘高光更亮一档，撑起"玻璃在暗处"的观感。
  factory HudTokens.dark(ColorScheme s) => HudTokens(
    glass: s.surface.withValues(alpha: 0.62),
    glassStrong: s.surface.withValues(alpha: 0.88),
    edge: s.onSurface.withValues(alpha: 0.24),
    edgeWidth: 1.2,
    bubbleMine: s.primaryContainer.withValues(alpha: 0.92),
    bubbleMineText: s.onPrimaryContainer,
    bubbleOther: s.surfaceContainerHigh.withValues(alpha: 0.9),
    bubbleOtherText: s.onSurface,
    meta: s.onSurfaceVariant.withValues(alpha: 0.85),
    online: const Color(0xFF32D583),
    warning: const Color(0xFFFDB022),
    star: const Color(0xFFFEC84B),
    grid: s.onSurface.withValues(alpha: 0.12),
    vignette: s.primary.withValues(alpha: 0.1),
    scan: s.primary,
    floatShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.5),
        blurRadius: 28,
        offset: const Offset(0, 10),
      ),
    ],
    blurChrome: 18,
    blurSheet: 26,
    // 别压成纯黑：留一点亮度，玻璃层才有"浮在深空上"的层次
    deep: const Color(0xFF0C111C),
    horizon: s.primary.withValues(alpha: 0.38),
    gridStrong: s.primary.withValues(alpha: 0.14),
    beam: s.primary.withValues(alpha: 0.55),
    tick: s.onSurface.withValues(alpha: 0.34),
    bracket: s.primary.withValues(alpha: 0.70),
    particle: s.primary.withValues(alpha: 0.62),
    glow: s.primary,
    scanlineAlpha: 0.06,
    // 暗色下网格线是**亮色**线，同样会盖住正文 → 静区稍淡但面积一致
    fieldVeil: const Color(0xFF0C111C).withValues(alpha: 0.90),
    fieldVeilRadius: 0.86,
    fieldLineBudget: 0.75,
  );

  /// 当前上下文里的 HUD 令牌（`AppTheme` 已注册，永远拿得到）
  /// 取当前主题的 HUD 令牌。
  ///
  /// 测试里经常直接 pump 一个**裸 `MaterialApp`**（不经过 `AppTheme`），
  /// 这时主题上没有这个 extension —— 不能直接 `!` 崩掉，就地按亮暗兜底一份。
  static HudTokens of(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<HudTokens>();
    if (ext != null) return ext;
    return theme.brightness == Brightness.dark
        ? HudTokens.dark(theme.colorScheme)
        : HudTokens.light(theme.colorScheme);
  }

  @override
  HudTokens copyWith({
    Color? glass,
    Color? glassStrong,
    Color? edge,
    double? edgeWidth,
    Color? bubbleMine,
    Color? bubbleMineText,
    Color? bubbleOther,
    Color? bubbleOtherText,
    Color? meta,
    Color? online,
    Color? warning,
    Color? star,
    Color? grid,
    Color? vignette,
    Color? scan,
    List<BoxShadow>? floatShadow,
    double? blurChrome,
    double? blurSheet,
    Color? deep,
    Color? horizon,
    Color? gridStrong,
    Color? beam,
    Color? tick,
    Color? bracket,
    Color? particle,
    Color? glow,
    double? scanlineAlpha,
    Color? fieldVeil,
    double? fieldVeilRadius,
    double? fieldLineBudget,
  }) => HudTokens(
    glass: glass ?? this.glass,
    glassStrong: glassStrong ?? this.glassStrong,
    edge: edge ?? this.edge,
    edgeWidth: edgeWidth ?? this.edgeWidth,
    bubbleMine: bubbleMine ?? this.bubbleMine,
    bubbleMineText: bubbleMineText ?? this.bubbleMineText,
    bubbleOther: bubbleOther ?? this.bubbleOther,
    bubbleOtherText: bubbleOtherText ?? this.bubbleOtherText,
    meta: meta ?? this.meta,
    online: online ?? this.online,
    warning: warning ?? this.warning,
    star: star ?? this.star,
    grid: grid ?? this.grid,
    vignette: vignette ?? this.vignette,
    scan: scan ?? this.scan,
    floatShadow: floatShadow ?? this.floatShadow,
    blurChrome: blurChrome ?? this.blurChrome,
    blurSheet: blurSheet ?? this.blurSheet,
    deep: deep ?? this.deep,
    horizon: horizon ?? this.horizon,
    gridStrong: gridStrong ?? this.gridStrong,
    beam: beam ?? this.beam,
    tick: tick ?? this.tick,
    bracket: bracket ?? this.bracket,
    particle: particle ?? this.particle,
    glow: glow ?? this.glow,
    scanlineAlpha: scanlineAlpha ?? this.scanlineAlpha,
    fieldVeil: fieldVeil ?? this.fieldVeil,
    fieldVeilRadius: fieldVeilRadius ?? this.fieldVeilRadius,
    fieldLineBudget: fieldLineBudget ?? this.fieldLineBudget,
  );

  @override
  HudTokens lerp(HudTokens? other, double t) {
    if (other == null) return this;
    return HudTokens(
      glass: Color.lerp(glass, other.glass, t)!,
      glassStrong: Color.lerp(glassStrong, other.glassStrong, t)!,
      edge: Color.lerp(edge, other.edge, t)!,
      edgeWidth: lerpDouble(edgeWidth, other.edgeWidth, t),
      bubbleMine: Color.lerp(bubbleMine, other.bubbleMine, t)!,
      bubbleMineText: Color.lerp(bubbleMineText, other.bubbleMineText, t)!,
      bubbleOther: Color.lerp(bubbleOther, other.bubbleOther, t)!,
      bubbleOtherText: Color.lerp(bubbleOtherText, other.bubbleOtherText, t)!,
      meta: Color.lerp(meta, other.meta, t)!,
      online: Color.lerp(online, other.online, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      star: Color.lerp(star, other.star, t)!,
      grid: Color.lerp(grid, other.grid, t)!,
      vignette: Color.lerp(vignette, other.vignette, t)!,
      scan: Color.lerp(scan, other.scan, t)!,
      floatShadow: BoxShadow.lerpList(floatShadow, other.floatShadow, t)!,
      blurChrome: lerpDouble(blurChrome, other.blurChrome, t),
      blurSheet: lerpDouble(blurSheet, other.blurSheet, t),
      deep: Color.lerp(deep, other.deep, t)!,
      horizon: Color.lerp(horizon, other.horizon, t)!,
      gridStrong: Color.lerp(gridStrong, other.gridStrong, t)!,
      beam: Color.lerp(beam, other.beam, t)!,
      tick: Color.lerp(tick, other.tick, t)!,
      bracket: Color.lerp(bracket, other.bracket, t)!,
      particle: Color.lerp(particle, other.particle, t)!,
      glow: Color.lerp(glow, other.glow, t)!,
      scanlineAlpha: lerpDouble(scanlineAlpha, other.scanlineAlpha, t),
      fieldVeil: Color.lerp(fieldVeil, other.fieldVeil, t)!,
      fieldVeilRadius: lerpDouble(fieldVeilRadius, other.fieldVeilRadius, t),
      fieldLineBudget: lerpDouble(fieldLineBudget, other.fieldLineBudget, t),
    );
  }
}

double lerpDouble(double a, double b, double t) => a + (b - a) * t;
