// 第 232 轮 · `DA176`：**胶囊选中态必须可读**（用户裁定 ③「亮色与暗色同等精细」）。
//
// 真机量到的原始缺陷：选中胶囊是 `scheme.primary` 文字压在
// `scheme.primary` **16% 透明**底上（底下是页面底色）⇒ 合成后
// 亮色 **4.42:1**、暗色 **4.36:1**，都低于 AA。
//
// 本用例钉三件事：
//   ① 选中底是**不透明**的 `primarySoft`（不再用 alpha 合成）；
//   ② 选中文字用 `primary`（令牌，且动态取色时有保底钳制）；
//   ③ 两者的对比度 ≥ 4.5 —— 亮/暗两套各算一遍。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Future<void> _check(WidgetTester tester, ThemeData theme, String label) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: PhotoSegment(
          labels: const ['Timeline', 'Photos', 'Folders'],
          index: 0,
          onChanged: (_) {},
        ),
      ),
    ),
  );
  final material = tester.widget<Material>(
    find.ancestor(
      of: find.text('Timeline'),
      matching: find.byType(Material),
    ).first,
  );
  final bg = material.color;
  expect(bg, isNotNull, reason: '$label：选中胶囊必须有底色');
  expect(
    bg!.a,
    1.0,
    reason: '$label：选中底必须是**不透明**的（透明度会让它压到页面底色上，实测 4.42:1）',
  );

  final text = tester.widget<Text>(find.text('Timeline'));
  final fg = text.style!.color!;
  final r = _ratio(fg, bg);
  expect(
    r,
    greaterThanOrEqualTo(4.5),
    reason: '$label：选中胶囊文字 ${r.toStringAsFixed(2)}:1 低于 AA',
  );

  // 未选中态也要能读（压在 surfaceContainerHighest 半透明底上）
  final idle = tester.widget<Text>(find.text('Photos'));
  expect(idle.style!.color, isNotNull, reason: '$label：未选中文字也要显式给色');
}

void main() {
  testWidgets('亮色：选中胶囊文字 ≥ AA 且底不透明（DA176）', (tester) async {
    await _check(tester, AppTheme.light(), 'light');
  });

  testWidgets('暗色：选中胶囊文字 ≥ AA 且底不透明（DA176）', (tester) async {
    await _check(tester, AppTheme.dark(), 'dark');
  });

  testWidgets('动态取色（任意壁纸色相）：选中胶囊仍 ≥ AA', (tester) async {
    for (var deg = 0; deg < 360; deg += 90) {
      final seed = HSVColor.fromAHSV(1, deg.toDouble(), 0.85, 0.55).toColor();
      await _check(
        tester,
        AppTheme.light(dynamic: ColorScheme.fromSeed(seedColor: seed)),
        'light/hue=$deg',
      );
    }
    // 顺带自证仪器：黑白 21:1
    expect(
      _ratio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
      closeTo(21.0, 0.1),
    );
    // 以及"旧写法"确实不达标（否则这条用例没有区分力）
    final oldBg = Color.alphaBlend(
      const Color(0xFF336383).withValues(alpha: 0.16),
      DesignPalette.light.bg,
    );
    expect(
      _ratio(const Color(0xFF336383), oldBg),
      lessThan(4.5),
      reason: '旧写法应当不达标 —— 否则本用例证明不了什么',
    );
  });
}
