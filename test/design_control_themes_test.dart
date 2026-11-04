// DA148（r509 补强）：控件家族的**主题取值**必须等于设计令牌。
//
// 为什么要有这一条：r506 只断言了「`app_theme.dart` 里有这六个 `*Theme`」，
// 那是**文本判据**——把 `dp.primary` 换成别的颜色照样绿。这里直接解析
// `ThemeData` 里的状态色，与 `DesignPalette` 逐字段比对。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';

void main() {
  for (final brightness in const [Brightness.light, Brightness.dark]) {
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();
    final dp = brightness == Brightness.light
        ? DesignPalette.light
        : DesignPalette.dark;
    final name = brightness == Brightness.light ? '亮色' : '暗色';

    test('DA148 · $name：开关/复选/单选/滑杆/分段按钮/提示条 = 设计令牌', () {
      expect(
        theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
        dp.primary,
        reason: '开关"开"的轨道必须是 primary',
      );
      expect(
        theme.switchTheme.trackColor!.resolve(<WidgetState>{}),
        dp.line,
        reason: '开关"关"的轨道必须是 line',
      );
      expect(
        theme.checkboxTheme.fillColor!.resolve({WidgetState.selected}),
        dp.primary,
        reason: '复选选中必须 primary（DA148 真机读数 (92,139,247) 与此同族）',
      );
      expect(
        theme.checkboxTheme.side!.color,
        dp.dim,
        reason: '未选复选的描边必须是 dim（真机读数 (127,136,149)）',
      );
      expect(
        theme.radioTheme.fillColor!.resolve({WidgetState.selected}),
        dp.primary,
      );
      expect(theme.sliderTheme.activeTrackColor, dp.primary);
      expect(theme.sliderTheme.inactiveTrackColor, dp.line);
      expect(theme.sliderTheme.thumbColor, dp.primary);
      expect(
        theme.segmentedButtonTheme.style!.backgroundColor!.resolve({
          WidgetState.selected,
        }),
        dp.primarySoft,
        reason: '分段按钮选中底必须是 primarySoft（真机读数 (32,44,70)）',
      );
      expect(
        theme.segmentedButtonTheme.style!.backgroundColor!.resolve(
          <WidgetState>{},
        ),
        dp.surface,
        reason: '分段按钮未选底必须是 surface（真机读数 (27,31,38)）',
      );
      expect(
        (theme.tooltipTheme.decoration! as BoxDecoration).color,
        dp.surface,
      );
      expect(
        ((theme.tooltipTheme.decoration! as BoxDecoration).border! as Border)
            .top
            .color,
        dp.line,
      );
    });
  }

  // DA157：设计组件不许盖掉主题里已定的颜色（`side` 就是踩过的那个）。
  test('DA157：DesignCheckRow/DesignSwitchRow 不覆盖 checkboxTheme 的描边', () {
    final kit = File('lib/src/design/kit/design_kit.dart').readAsStringSync();
    final code = kit
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    // 只看 `Checkbox(` 这一段的参数：卡片 `CardTheme` 的 `side` 是另一回事。
    final start = code.indexOf('trailing: Checkbox(');
    expect(start, greaterThan(0), reason: 'DA157：没找到 DesignCheckRow 的 Checkbox');
    final end = code.indexOf('),', start);
    expect(end, greaterThan(start));
    final segment = code.substring(start, end);
    expect(
      segment.contains('side:'),
      isFalse,
      reason: 'DA157：Checkbox 又显式传了 `side:`，会把 checkboxTheme 的 dim 盖掉',
    );
  });

  // DA158：主行动球（`OrbButton`）不许用 `scheme.primary` ——
  // 开着 Material You 动态取色时，`scheme.primary` 是壁纸算出来的灰蓝，
  // 与同屏的令牌蓝差一档（真机亮色实测 (80,103,146) vs #2563EB）。
  test('DA158：OrbButton 用设计令牌而非 scheme.primary', () {
    final src = File('lib/src/core/ui/orb_button.dart').readAsStringSync();
    final code = src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(code.contains('scheme.primary'), isFalse,
        reason: 'DA158：主行动球又用回 scheme.primary 了（动态取色下会与令牌蓝不一致）');
    expect(code.contains('dp.primary'), isTrue,
        reason: 'DA158：主行动球必须用 DesignPalette.primary');
  });

  // DA159：FAB 必须走设计令牌（`primary` 实心 + `onPrimary` 图标）。
  // 没有 `floatingActionButtonTheme` 时 M3 用 `primaryContainer`，
  // 开着「动态取色」就变成壁纸色（亮色实测底 (216,226,252)、字 (45,70,115)）。
  test('DA159：floatingActionButtonTheme 用设计令牌', () {
    for (final brightness in const [Brightness.light, Brightness.dark]) {
      final p = brightness == Brightness.light
          ? DesignPalette.light
          : DesignPalette.dark;
      // 两条腿都要钉：`DesignTheme`（设计页）与 `AppTheme`（直接用 Scaffold 的页面）。
      for (final t in <ThemeData>[
        DesignTheme.of(p, brightness),
        brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      ]) {
        expect(t.floatingActionButtonTheme.backgroundColor, p.primary,
            reason: 'DA159：$brightness 下 FAB 底色不是令牌 primary');
        expect(t.floatingActionButtonTheme.foregroundColor, p.onPrimary,
            reason: 'DA159：$brightness 下 FAB 前景色不是令牌 onPrimary');
      }
    }
  });

  // DA160：中性色/语义色必须归设计令牌（只有"色相"可以跟壁纸走）。
  // 反例：开着动态取色时 `error` / `outline` / `surfaceContainerHighest`
  // 全是壁纸算的，而 features 里有 332 处直接读 `colorScheme.*`。
  test('DA160：AppTheme 把中性/语义槽位钉在令牌上（亮暗都查）', () {
    for (final brightness in const [Brightness.light, Brightness.dark]) {
      final p = brightness == Brightness.light
          ? DesignPalette.light
          : DesignPalette.dark;
      // 故意给一个"壁纸色"scheme，模拟 Material You 开着
      final wallpaper = ColorScheme.fromSeed(
        seedColor: const Color(0xFF7B5E57),
        brightness: brightness,
      );
      final t = brightness == Brightness.light
          ? AppTheme.light(dynamic: wallpaper)
          : AppTheme.dark(dynamic: wallpaper);
      final cs = t.colorScheme;
      expect(cs.surface, p.surface, reason: 'DA160：surface 未归令牌');
      expect(cs.onSurface, p.text, reason: 'DA160：onSurface 未归令牌');
      expect(cs.error, p.danger, reason: 'DA160：error 未归令牌');
      expect(cs.outline, p.line, reason: 'DA160：outline 未归令牌');
      expect(cs.surfaceContainerHighest, p.surface2,
          reason: 'DA160：surfaceContainerHighest 未归令牌');
      expect(cs.onSurfaceVariant, p.muted, reason: 'DA160：onSurfaceVariant 未归令牌');
    }
  });

  // DA160（补充）：不止断言 `ThemeData` 的槽位，还要断言**组件解析出来的值** ——
  // 文本守卫拦不住"把槽位换回去"，只有渲染出来的颜色算数。
  testWidgets('DA160：Divider / Chip / ProgressIndicator 在壁纸 scheme 下仍取令牌色',
      (tester) async {
    final wallpaper = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7B5E57),
      brightness: Brightness.light,
    );
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(dynamic: wallpaper),
      home: const Scaffold(
        body: Column(children: [
          Divider(height: 4),
          Chip(label: Text('x')),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    final divider = tester.widget<Divider>(find.byType(Divider));
    final theme = Theme.of(tester.element(find.byType(Divider)));
    expect(divider.color ?? theme.dividerColor, DesignPalette.light.line,
        reason: 'DA160：分隔线颜色没走令牌');
    // Chip 的底色由材质层的 `Colors.transparent` + `ChipTheme` 决定，
    // 这里断言**主题里解析出来的** chip 底色，而不是 Material 的 color。
    final chipTheme = theme.chipTheme;
    // chip 底色带 0.7 透明度（`surface2` + alpha），只比 RGB
    final chipBg = chipTheme.backgroundColor!;
    expect((chipBg.r, chipBg.g, chipBg.b),
        (DesignPalette.light.surface2.r, DesignPalette.light.surface2.g,
            DesignPalette.light.surface2.b),
        reason: 'DA160：Chip 底色没走 surface2 令牌');
  });
}
