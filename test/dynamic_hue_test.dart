// 对应缺陷 **DA175**（动态取色曾是假开关）+ 设计约束 `DA160`（中性色归令牌）。
// 第 231 轮：**动态取色只借"色相"**的机器判据。
//
// 用户裁定「Material You 保留默认开，而且要想办法让它真正取到壁纸色」，
// 但 `DA160` 同时要求中性色/语义色归设计令牌。两条要求叠起来就是本用例：
//   * 拿到动态方案 ⇒ `primary/primarySoft/accent` 跟着壁纸走（**看得见的变化**）；
//   * `bg/surface/line/text/muted/danger` **逐字节等于设计令牌**（154 稿对得上）；
//   * 关掉动态取色 ⇒ 调色板与常量令牌**完全一致**（没有色相层）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';

void main() {
  final wallpaperSeed = const Color(0xFF007FAC); // 真机读到的系统主题色（青）

  testWidgets('关掉动态取色：调色板与设计令牌完全一致（无色相层）', (tester) async {
    late DesignPalette seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) {
            seen = DesignPalette.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen.primary, DesignPalette.light.primary);
    expect(seen.primarySoft, DesignPalette.light.primarySoft);
    expect(seen.accent, DesignPalette.light.accent);
    expect(
      Theme.of(tester.element(find.byType(SizedBox))).extension<HudDynamicHue>(),
      isNull,
      reason: '没有动态方案时不该挂色相层',
    );
  });

  mainHueContrast();

  testWidgets('开启动态取色：色相三兄弟跟壁纸走，中性色一个字节都不动', (tester) async {
    final scheme = ColorScheme.fromSeed(seedColor: wallpaperSeed);
    late DesignPalette seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(dynamic: scheme),
        home: Builder(
          builder: (context) {
            seen = DesignPalette.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    // ① 色相变了
    expect(seen.primary, scheme.primary);
    expect(seen.primarySoft, scheme.primaryContainer);
    expect(seen.accent, scheme.tertiary);
    expect(seen.primary, isNot(DesignPalette.light.primary));
    // ② 中性/语义色一名一字节都不许变
    final base = DesignPalette.light;
    expect(seen.bg, base.bg);
    expect(seen.surface, base.surface);
    expect(seen.surface2, base.surface2);
    expect(seen.line, base.line);
    expect(seen.text, base.text);
    expect(seen.muted, base.muted);
    expect(seen.dim, base.dim);
    expect(seen.danger, base.danger);
    expect(seen.ok, base.ok);
    expect(seen.navBar, base.navBar);
    expect(seen.playerBar, base.playerBar);
  });

  testWidgets('暗色同样只换色相', (tester) async {
    final scheme = ColorScheme.fromSeed(
      seedColor: wallpaperSeed,
      brightness: Brightness.dark,
    );
    late DesignPalette seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(dynamic: scheme),
        home: Builder(
          builder: (context) {
            seen = DesignPalette.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen.primary, scheme.primary);
    expect(seen.text, DesignPalette.dark.text);
    expect(seen.surface, DesignPalette.dark.surface);
    expect(seen.danger, DesignPalette.dark.danger);
  });
}

/// 壁纸色相是**任意的**（360 度都可能）⇒ 取色后的对比度必须全部达标。
/// 这条用例是 ③「亮色与暗色同等精细」的机器判据：同一组 seed 两套主题各跑一遍。
double _ratio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void mainHueContrast() {
  for (final entry in <String, Brightness>{
    'light': Brightness.light,
    'dark': Brightness.dark,
  }.entries) {
    testWidgets('任意壁纸色相下 ${entry.key} 主题的主色仍 ≥ AA（12 个色相）', (tester) async {
      for (var deg = 0; deg < 360; deg += 30) {
        final seed = HSVColor.fromAHSV(1, deg.toDouble(), 0.8, 0.6).toColor();
        final scheme = ColorScheme.fromSeed(
          seedColor: seed,
          brightness: entry.value,
        );
        late DesignPalette seen;
        await tester.pumpWidget(
          MaterialApp(
            theme: entry.value == Brightness.light
                ? AppTheme.light(dynamic: scheme)
                : AppTheme.dark(dynamic: scheme),
            home: Builder(
              builder: (context) {
                seen = DesignPalette.of(context);
                return const SizedBox();
              },
            ),
          ),
        );
        expect(
          _ratio(seen.primary, seen.primarySoft),
          greaterThanOrEqualTo(4.5),
          reason: 'hue=$deg 主题=${entry.key}：芯片文字对比度不足',
        );
        expect(
          _ratio(seen.primary, seen.surface),
          greaterThanOrEqualTo(4.5),
          reason: 'hue=$deg 主题=${entry.key}：主色当文字压在卡片上不足',
        );
        // 中性色仍必须是令牌值（不被取色污染）
        expect(seen.surface, entry.value == Brightness.light
            ? DesignPalette.light.surface
            : DesignPalette.dark.surface);
      }
    });
  }
}

