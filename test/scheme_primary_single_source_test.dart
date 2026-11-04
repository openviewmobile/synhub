// 第 243 轮 · `DA187`：**没拿到壁纸方案时，`scheme.primary` 必须等于令牌 primary**。
//
// 真机事实（Downloads 筛选条）：`All` 是亮蓝 `(42,77,208)`（种子 `#1B69C1` 派生），
// 而页面其余主色是令牌青蓝 `(51,99,131)` —— 同一屏**两种主色**。
// 原因是 `scheme.primary` 一直留给"色相"，可没开动态取色时那是**另一个品牌蓝**，
// 不是个性化。规矩：**个性化只在真拿到壁纸色相时发生**，否则唯一真源是设计令牌。
//
// 判据：
//   ① 无动态方案：`scheme.primary == DesignPalette.light.primary`（亮/暗各自）；
//   ② 无动态方案：`scheme.primaryContainer == palette.primarySoft`，
//      且选中文字（primary on primaryContainer）≥4.5:1；
//   ③ 有动态方案（传入壁纸 scheme）：主色**跟着壁纸走**，不许被钉成令牌色
//      （否则 DA160 的"个性化"就被这轮改没了 —— 这条是防过度收口）；
//   ④ 反证：种子派生色确实不同于令牌色（否则本用例没有区分力）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('无动态方案：亮色 scheme.primary/primaryContainer 都来自令牌', () {
    final theme = AppTheme.light();
    final scheme = theme.colorScheme;
    final dp = DesignPalette.light;
    expect(scheme.primary, dp.primary);
    expect(scheme.primaryContainer, dp.primarySoft);
    expect(_ratio(scheme.primary, scheme.primaryContainer),
        greaterThanOrEqualTo(4.5));
  });

  test('无动态方案：暗色同样归令牌', () {
    final theme = AppTheme.dark();
    final scheme = theme.colorScheme;
    final dp = DesignPalette.dark;
    expect(scheme.primary, dp.primary);
    expect(scheme.primaryContainer, dp.primarySoft);
    expect(_ratio(scheme.primary, scheme.primaryContainer),
        greaterThanOrEqualTo(4.5));
  });

  test('★ 有动态方案时主色必须跟壁纸（这条防"过度收口"）', () {
    // 造一个明显的壁纸色相：品红
    final wallpaper = ColorScheme.fromSeed(seedColor: const Color(0xFFC2185B));
    final theme = AppTheme.light(dynamic: wallpaper);
    final scheme = theme.colorScheme;
    final dp = DesignPalette.light;
    expect(scheme.primary, isNot(dp.primary),
        reason: '传了壁纸方案却被钉成令牌色 ⇒ 个性化被改没了');
    // 但可读性仍要保证：主色对页面底 ≥4.5
    expect(_ratio(scheme.primary, dp.surface), greaterThanOrEqualTo(4.5));
  });

  test('反证：种子派生色确实不是令牌色', () {
    final seeded = ColorScheme.fromSeed(seedColor: AppTheme.seed);
    expect(seeded.primary, isNot(DesignPalette.light.primary),
        reason: '如果两者本来就相等，本用例证明不了任何事');
  });
}
