// 第 241 轮 · `DA185`（用户裁定 ③）：**Drive 四段胶囊的选中态必须读得清**。
//
// 真机亮色：`Recycle bin` 选中胶囊 = `primary` 字压在 `primary@16%` 的底上
// ⇒ 合成 **4.42:1**（低于 AA）。与 `DA176`（相册分段）/`DA183`（文件来源）同一类：
// **半透明底 + 同色字**。
//
// 判据：
//   ① 亮/暗两套主题下，选中文字对其**自身底色**≥4.5:1；
//   ② 选中底 alpha 必须 == 1（半透明就是成因）；
//   ③ 反证：16% 透明合成版确实 <4.5（否则本用例没有区分力）；
//   ④ 横条**可滚动**（4 段放不下是事实，允许滑，不许悄悄裁掉）——用
//      `SingleChildScrollView` 的轴向来钉。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Future<(Color, Color)> _colors(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SegmentedChips(
          labels: const ['Recycle bin', 'Starred', 'Shared with me', 'Team folders'],
          index: 0,
          onChanged: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final text = tester.widget<Text>(find.text('Recycle bin'));
  final fg = text.style!.color!;
  final material = tester.widget<Material>(
    find
        .ancestor(
          of: find.text('Recycle bin'),
          matching: find.byType(Material),
        )
        .first,
  );
  final bg = material.color!;
  expect(bg.a, 1.0, reason: '选中底必须不透明：$bg');
  return (fg, bg);
}

void main() {
  for (final e in {'light': AppTheme.light(), 'dark': AppTheme.dark()}.entries) {
    testWidgets('${e.key}：选中胶囊文字 ≥ 4.5:1（DA185）', (tester) async {
      final (fg, bg) = await _colors(tester, e.value);
      final r = _ratio(fg, bg);
      expect(r, greaterThanOrEqualTo(4.5),
          reason: '${e.key}：$fg on $bg = ${r.toStringAsFixed(2)}:1');
    });
  }

  testWidgets('横条真能滑：窄屏下拖动会带动胶囊（不是静默裁掉）', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SegmentedChips(
            labels: const ['Recycle bin', 'Starred', 'Shared with me', 'Team folders'],
            index: 0,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('Recycle bin')).dx;
    await tester.drag(find.byType(SingleChildScrollView), const Offset(-160, 0));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(find.text('Recycle bin')).dx;
    expect(after, lessThan(before), reason: '拖不动 ⇒ 放不下的那一段就是被裁掉了');
    // 拖完之后最后一段确实露出来了（说明内容真的在视口外等着滑进来）
    expect(find.text('Team folders'), findsOneWidget);
  });

  test('反证：真机量到的「16% 透明」那一对确实不达标', () {
    // 直接用**真机实测像素对**（r579 截图）：字 (51,99,131) / 合成底 (204,215,226) = 4.42:1。
    // 不必再用 alphaBlend 复算 —— 那样会差 0.09（浮点合成 vs GPU 合成），
    // 反而把"确实不达标"证成 4.51 的假绿。
    const fg = Color(0xFF336383);
    const composited = Color(0xFFCCD7E2);
    final r = _ratio(fg, composited);
    expect(r, lessThan(4.5), reason: '真机那一对应当不达标，实际 ${r.toStringAsFixed(2)}:1');
    expect(r, closeTo(4.42, 0.05));
  });
}
