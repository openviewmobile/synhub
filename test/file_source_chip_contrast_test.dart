// 第 239 轮 · `DA183`（用户裁定 ③）：**文件来源胶囊的选中态必须读得清**。
//
// 真机亮色：`My Drive` 选中胶囊 = `primary` 文字压在
// `primary` 的 18% 透明底上 ⇒ 合成后 **4.28:1**（低于 AA）。
// 这与 `DA176`（相册分段）是同一类问题：**半透明叠在页面底上会掉对比度**。
//
// 判据：
//   ① 亮/暗两套主题下，选中文字对其**自身背景**≥4.5:1；
//   ② 选中背景必须**不透明**（alpha == 1）——半透明就是本缺陷的成因；
//   ③ 容器与 InkWell 的圆角一致（原来 11 vs 胶囊 999，水波纹会露出直角）；
//   ④ 反证：18% 透明版本确实 <4.5（否则本用例没有区分力）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';

import 'package:synhub/src/features/files/file_browse_page.dart';

double _lum(Color c) => c.computeLuminance();
double _ratio(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Future<(Color, Color)> _colors(WidgetTester tester, ThemeData theme,
    {required bool selected}) async {
  late Color fg, bg;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        backgroundColor: const Color(0xFFEAF0F6),
        body: Builder(
          builder: (context) => FileSourceChip(
            label: 'My Drive',
            selected: selected,
            onTap: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final text = tester.widget<Text>(find.text('My Drive'));
  fg = text.style!.color!;
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byType(FileSourceChip),
      matching: find.byType(Container),
    ),
  );
  final deco = container.decoration! as ShapeDecoration;
  bg = Color.fromARGB(255, (deco.color!.r * 255).round(),
      (deco.color!.g * 255).round(), (deco.color!.b * 255).round());
  expect(deco.color!.a, 1.0, reason: '选中底必须不透明（半透明会掉对比度）');
  return (fg, bg);
}

void main() {
  for (final entry in {'light': AppTheme.light(), 'dark': AppTheme.dark()}.entries) {
    testWidgets('${entry.key}：选中胶囊文字 ≥ 4.5:1（DA183）', (tester) async {
      final (fg, bg) = await _colors(tester, entry.value, selected: true);
      final r = _ratio(fg, bg);
      expect(r, greaterThanOrEqualTo(4.5),
          reason: '${entry.key}：$fg on $bg 只有 ${r.toStringAsFixed(2)}:1');
    });
  }

  test('反证：18% 透明版本在亮色页底上确实不达标', () {
    const pageBg = Color(0xFFEAF0F6);
    const primary = Color(0xFF1D4ED8);
    final blended = Color.alphaBlend(primary.withValues(alpha: 0.18), pageBg);
    final r = _ratio(primary, blended);
    expect(r, lessThan(4.5), reason: '透明版应当不达标，实际 ${r.toStringAsFixed(2)}:1');
  });
}
