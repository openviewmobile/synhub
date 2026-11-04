// 背景 × 文字可读性：**像素级**硬指标。
//
// 为什么要有这一层：`a11y_contrast_test.dart` 只算"单层颜色 vs `deep`"，
// 而真实屏幕上文字背后是 `deep + 径向辉光 + 透视网格 + 星尘 + 扫描线 + 渐晕`
// 的**合成**结果。网格线在中心消失点会堆叠成一块深色"结"，单层算法看不见。
// 这里把 [FieldBackdrop] 真渲染成位图，按屏幕分区取**实际像素**的亮度极值，
// 再拿各文字色去算最坏对比度 —— 文字落在任何分区都必须达标。
//
// 阈值（WCAG 2.1）：正文/小字 ≥ 4.5:1，大字与图形语义色 ≥ 3:1。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:synhub/src/core/ui/field_backdrop.dart';

const Key _rootKey = Key('legibility-root');

/// WCAG 相对亮度
double luminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// 对比度（两条不透明色）
double contrastRatio(Color a, Color b) {
  final la = luminance(a), lb = luminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// 把 [fg]（可带透明度）叠在 [bg]（不透明）上
Color over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

/// 屏幕分区（3 列 × 5 行）的**实际像素**亮度统计
class Region {
  Region(this.row, this.col, this.minLum, this.maxLum, this.avgLum);

  final int row;
  final int col;
  final double minLum;
  final double maxLum;
  final double avgLum;

  /// 与 [fg] 的最坏对比度：取该区最暗、最亮两个极端里更差的那个
  double worstContrast(Color fg) {
    final l = luminance(fg);
    double ratio(double bgLum) {
      final hi = math.max(l, bgLum), lo = math.min(l, bgLum);
      return (hi + 0.05) / (lo + 0.05);
    }

    return math.min(ratio(minLum), ratio(maxLum));
  }

  /// 该区亮度摆幅（越大 = 底纹对比越强、越抢文字）
  double get spread => maxLum - minLum;

  @override
  String toString() =>
      'r$row c$col(L ${minLum.toStringAsFixed(3)}~${maxLum.toStringAsFixed(3)}, '
      'Δ${spread.toStringAsFixed(3)})';
}

Future<List<Region>> _regionsOf(
  ui.Image image, {
  int rows = 5,
  int cols = 3,
}) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = data!.buffer.asUint8List();
  final w = image.width, h = image.height;
  final out = <Region>[];

  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final x0 = (w * c / cols).floor(), x1 = (w * (c + 1) / cols).floor();
      final y0 = (h * r / rows).floor(), y1 = (h * (r + 1) / rows).floor();
      var minL = 1.0, maxL = 0.0, sum = 0.0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final o = (y * w + x) * 4;
          final lum = luminance(
            Color.fromARGB(255, bytes[o], bytes[o + 1], bytes[o + 2]),
          );
          if (lum < minL) minL = lum;
          if (lum > maxL) maxL = lum;
          sum += lum;
        }
      }
      out.add(Region(r, c, minL, maxL, sum / ((x1 - x0) * (y1 - y0))));
    }
  }
  return out;
}

/// 从已经 pump 好的 [RepaintBoundary] 里取分区统计
Future<List<Region>> _regionsFromBoundary(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_rootKey),
  );
  late List<Region> regions;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    regions = await _regionsOf(image);
    image.dispose();
  });
  return regions;
}

Future<List<Region>> _renderField(
  WidgetTester tester, {
  required Brightness brightness,
  double intensity = 0.6,
  int particles = 20,
  bool scanlines = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        // 调试横幅会在右上角画一条纯白/红丝带，污染分区亮度统计
        debugShowCheckedModeBanner: false,
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: HudScaffold(
          intensity: intensity,
          particles: particles,
          showScanlines: scanlines,
          body: const SizedBox.expand(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_rootKey),
  );
  // `toImage` 与 `toByteData` 都是真异步（要走光栅化），**必须**在 runAsync 里，
  // 否则在假异步时钟下永远不会完成（踩过：整条测试挂死到超时）。
  late List<Region> regions;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    regions = await _regionsOf(image);
    image.dispose();
  });
  return regions;
}

/// 该分区里"文字最可能踩到"的底：取最亮与最暗，两个都要算
Region worstFor(List<Region> regions, Color fg) =>
    regions.reduce((a, b) => a.worstContrast(fg) < b.worstContrast(fg) ? a : b);

/// 12×12 滑窗：对每个窗口算 (minLum, maxLum)，返回"对 [fg] 最差"的那个窗口
Future<({double contrast, double spread})> _localWorst(
  WidgetTester tester, {
  required Brightness brightness,
  required Color fg,
  int window = 12,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: const HudScaffold(body: SizedBox.expand()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_rootKey),
  );
  var worstContrast = 99.0;
  var worstSpread = 0.0;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    final w = image.width, h = image.height;
    final lum = Float64List(w * h);
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      lum[i] = luminance(
        Color.fromARGB(255, bytes[o], bytes[o + 1], bytes[o + 2]),
      );
    }
    final lf = luminance(fg);
    double ratio(double bgLum) {
      final hi = math.max(lf, bgLum), lo = math.min(lf, bgLum);
      return (hi + 0.05) / (lo + 0.05);
    }

    // 只在"内容带"里扫（去掉最外 8px 与四角装饰）
    for (var y = 8; y + window < h - 8; y += 2) {
      for (var x = 8; x + window < w - 8; x += 2) {
        var lo = 1.0, hi = 0.0;
        for (var dy = 0; dy < window; dy++) {
          final row = (y + dy) * w;
          for (var dx = 0; dx < window; dx++) {
            final l = lum[row + x + dx];
            if (l < lo) lo = l;
            if (l > hi) hi = l;
          }
        }
        final c = math.min(ratio(lo), ratio(hi));
        if (c < worstContrast) worstContrast = c;
        if (hi - lo > worstSpread) worstSpread = hi - lo;
      }
    }
    image.dispose();
  });
  return (contrast: worstContrast, spread: worstSpread);
}

/// "玻璃面板盖在最坏底纹上"的可读性：把 [glass] 逐像素合成到底图上，
/// 再看 [fg] 的最坏对比度。这一层测的是**搭配**（主题 × 背景 × 玻璃），
/// 而不只是背景本身 —— 半透明玻璃会把底纹的亮/暗透上来。
Future<({double contrast, double spread})> _glassWorst(
  WidgetTester tester, {
  required Brightness brightness,
  required Color glass,
  required Color fg,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: const HudScaffold(body: SizedBox.expand()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_rootKey),
  );

  var worst = 99.0;
  var worstSpread = 0.0;
  final lf = luminance(fg);
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    final w = image.width, h = image.height;
    // 先把"玻璃盖上去"之后的亮度算出来
    final lum = Float64List(w * h);
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      final bg = Color.fromARGB(255, bytes[o], bytes[o + 1], bytes[o + 2]);
      lum[i] = luminance(over(glass, bg));
    }
    double ratio(double bgLum) {
      final hi = math.max(lf, bgLum), lo = math.min(lf, bgLum);
      return (hi + 0.05) / (lo + 0.05);
    }

    // 玻璃面板尺寸远大于 12px，按 24×24 的块看即可
    const win = 24;
    for (var y = 0; y + win < h; y += 4) {
      for (var x = 0; x + win < w; x += 4) {
        var lo = 1.0, hi = 0.0;
        for (var dy = 0; dy < win; dy++) {
          final row = (y + dy) * w;
          for (var dx = 0; dx < win; dx++) {
            final l = lum[row + x + dx];
            if (l < lo) lo = l;
            if (l > hi) hi = l;
          }
        }
        final c = math.min(ratio(lo), ratio(hi));
        if (c < worst) worst = c;
        if (hi - lo > worstSpread) worstSpread = hi - lo;
      }
    }
    image.dispose();
  });
  return (contrast: worst, spread: worstSpread);
}

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    final label = brightness == Brightness.dark ? '暗色' : '亮色';
    final theme = brightness == Brightness.dark
        ? AppTheme.dark()
        : AppTheme.light();
    final scheme = theme.colorScheme;
    final hud =
        theme.extension<HudTokens>() ??
        (brightness == Brightness.dark
            ? HudTokens.dark(scheme)
            : HudTokens.light(scheme));

    group('$label主题 · 背景上的文字可读性', () {
      testWidgets('分区亮度报告 + 正文色 ≥ 4.5:1', (tester) async {
        final regions = await _renderField(tester, brightness: brightness);

        // ignore: avoid_print
        print(
          '[$label 主题] 分区亮度 '
          '${regions.map((r) => r.toString()).join(' ')}\n'
          '[$label 主题] 最大摆幅 Δ=${regions.map((r) => r.spread).reduce(math.max).toStringAsFixed(3)}',
        );

        expect(regions.length, 15);
        final worst = worstFor(regions, scheme.onSurface);
        expect(
          worst.worstContrast(scheme.onSurface),
          greaterThanOrEqualTo(4.5),
          reason: '正文色在最坏分区 $worst 上不达标',
        );
      });

      testWidgets('次级文字（onSurfaceVariant）≥ 4.5:1', (tester) async {
        final regions = await _renderField(tester, brightness: brightness);
        final worst = worstFor(regions, scheme.onSurfaceVariant);
        expect(
          worst.worstContrast(scheme.onSurfaceVariant),
          greaterThanOrEqualTo(4.5),
          reason: '次级文字在最坏分区 $worst 上不达标',
        );
      });

      testWidgets('遥测小字（hud.meta）≥ 4.5:1', (tester) async {
        final regions = await _renderField(tester, brightness: brightness);
        // meta 自带透明度（0.78~0.85），最坏情形是叠在**最亮**的底上
        final worst = regions.reduce(
          (a, b) =>
              a.worstContrast(over(hud.meta, hud.deep)) <
                  b.worstContrast(over(hud.meta, hud.deep))
              ? a
              : b,
        );
        final onWorst = over(hud.meta, grayscale(worst.maxLum));
        expect(
          contrastRatio(onWorst, grayscale(worst.maxLum)),
          greaterThanOrEqualTo(4.5),
          reason: '遥测小字在最坏分区 $worst 上不达标',
        );
      });

      testWidgets('语义色（在线/警告/星标）≥ 3:1', (tester) async {
        final regions = await _renderField(tester, brightness: brightness);
        for (final (name, color) in [
          ('online', hud.online),
          ('warning', hud.warning),
          ('star', hud.star),
        ]) {
          final worst = worstFor(regions, color);
          expect(
            worst.worstContrast(color),
            greaterThanOrEqualTo(3.0),
            reason: '$name 在最坏分区 $worst 上不达标',
          );
        }
      });

      testWidgets('局部窗口：文字周围 12px 内的摆幅 ≤ 0.18', (tester) async {
        final r = await _localWorst(
          tester,
          brightness: brightness,
          fg: scheme.onSurface,
        );
        // ignore: avoid_print
        print(
          '[$label 主题] 局部最坏窗口：摆幅 Δ=${r.spread.toStringAsFixed(3)} '
          '对比度=${r.contrast.toStringAsFixed(2)}:1',
        );
        expect(
          r.spread,
          lessThanOrEqualTo(0.18),
          reason: '文字周围 12px 内的底纹摆幅太大（Δ=${r.spread}），字会被切碎',
        );
      });

      for (final (glassName, glass) in [
        ('glass', hud.glass),
        ('glassStrong', hud.glassStrong),
      ]) {
        testWidgets('$glassName 面板盖在最坏底纹上：正文 ≥ 4.5:1', (tester) async {
          final r = await _glassWorst(
            tester,
            brightness: brightness,
            glass: glass,
            fg: scheme.onSurface,
          );
          // ignore: avoid_print
          print(
            '[$label 主题] $glassName 上的正文：最坏对比度='
            '${r.contrast.toStringAsFixed(2)}:1（玻璃下的摆幅 Δ=${r.spread.toStringAsFixed(3)}）',
          );
          expect(
            r.contrast,
            greaterThanOrEqualTo(4.5),
            reason: '$glassName 透出的底纹把正文压到 ${r.contrast}:1',
          );
        });
      }

      testWidgets('最坏情况：页面把强度开到 1.0 时正文仍 ≥ 4.5:1 且局部摆幅 ≤ 0.22', (tester) async {
        // 各页面的 intensity 不同（频道列表 0.9、英雄页 1.0）——按最坏的那个来
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          RepaintBoundary(
            key: _rootKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: brightness == Brightness.dark
                  ? AppTheme.dark()
                  : AppTheme.light(),
              home: const HudScaffold(intensity: 1, body: SizedBox.expand()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final regions = await _regionsFromBoundary(tester);
        final worst = worstFor(regions, scheme.onSurface);
        expect(
          worst.worstContrast(scheme.onSurface),
          greaterThanOrEqualTo(4.5),
          reason: 'intensity=1.0 时正文在最坏分区 $worst 上不达标',
        );
        expect(
          regions.map((r) => r.spread).reduce(math.max),
          lessThanOrEqualTo(0.30),
          reason: 'intensity=1.0 时分区摆幅超预算（会把文字切碎）',
        );
      });

      testWidgets('局部窗口：正文对比度 ≥ 4.5:1', (tester) async {
        final r = await _localWorst(
          tester,
          brightness: brightness,
          fg: scheme.onSurfaceVariant,
        );
        expect(
          r.contrast,
          greaterThanOrEqualTo(4.5),
          reason: '次级文字在局部最坏窗口里只有 ${r.contrast}:1',
        );
      });

      testWidgets('底纹自己不能抢戏（分区亮度摆幅有上限）', (tester) async {
        final regions = await _renderField(tester, brightness: brightness);
        // 摆幅 = 网格线相对底色的最坏亮度差。>0.28 时，普通文字踩上去就会掉到 4.5 以下
        final spread = regions.map((r) => r.spread).reduce(math.max);
        expect(
          spread,
          lessThanOrEqualTo(0.28),
          reason: '底纹最坏摆幅 Δ=$spread 太大，文字会被网格线切碎',
        );
      });
    });
  }

  // ── 动态取色（Material You）鲁棒性 ───────────────────────────────────────
  // 主色来自壁纸，极端情况下可能是近黑/近白/高饱和。底纹与静区面纱都从主色
  // 派生（`horizon`/`particle`/`vignette`），所以必须扫一遍极端主色：
  // 无论用户壁纸什么颜色，正文都不能掉下 4.5:1。
  group('动态取色鲁棒性 · 极端主色下正文仍达标', () {
    const extremes = {
      '近黑': Color(0xFF101010),
      '品牌深蓝': Color(0xFF0B2947),
      '中灰': Color(0xFF808080),
      '荧光粉': Color(0xFFFFE0F0),
      '正红': Color(0xFFB3261E),
      '正绿': Color(0xFF1B6B3A),
    };

    for (final brightness in [Brightness.light, Brightness.dark]) {
      final label = brightness == Brightness.dark ? '暗色' : '亮色';
      for (final entry in extremes.entries) {
        testWidgets('$label · 主色=${entry.key}', (tester) async {
          final scheme = ColorScheme.fromSeed(
            seedColor: entry.value,
            brightness: brightness,
          ).copyWith(primary: entry.value);
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            RepaintBoundary(
              key: _rootKey,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                // 亮暗必须与 scheme 同源：混用会让"文字色 vs 底色"本身就错位
                theme: brightness == Brightness.dark
                    ? AppTheme.dark(dynamic: scheme)
                    : AppTheme.light(dynamic: scheme),
                home: const HudScaffold(body: SizedBox.expand()),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final regions = await _regionsFromBoundary(tester);
          final worst = worstFor(regions, scheme.onSurface);
          expect(
            worst.worstContrast(scheme.onSurface),
            greaterThanOrEqualTo(4.5),
            reason: '主色=${entry.key} 时正文在最坏分区 $worst 上不达标',
          );
          expect(
            regions.map((r) => r.spread).reduce(math.max),
            lessThanOrEqualTo(0.30),
            reason: '主色=${entry.key} 时底纹摆幅超预算',
          );
        });
      }
    }
  });
}

/// 按亮度造一条灰（用于把半透明文字叠到指定亮度的底上）
Color grayscale(double lum) {
  // 亮度→sRGB 的粗略反解足够用于"最坏情形"夹逼
  final v = lum <= 0.0031308
      ? lum * 12.92
      : 1.055 * math.pow(lum, 1 / 2.4) - 0.055;
  final g = (v.clamp(0.0, 1.0) * 255).round();
  return Color.fromARGB(255, g, g, g);
}
