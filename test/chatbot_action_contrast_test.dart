// 第 238 轮 · `DA182`（用户裁定 ③）：**机器人按钮的文字必须读得清**。
//
// 官方六个品牌色是给"浅底上的图标/填充"用的，拿来写字在亮色底上只有
// 2.32–4.18:1（真机像素：绿 `OK` = 2.41:1，红 `取消` = 3.15:1）——连 AA 都不到。
//
// 判据：
//   ① 亮色/暗色两套主题下，六个 style 的文字色对 `surface` 都必须 ≥ 4.5:1；
//   ② **色相不许丢**：拟合后的颜色仍要"绿还是绿、红还是红"（通道序关系保持）；
//   ③ 反证：原始品牌色确实 < 4.5（否则本用例没有区分力）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/chatbot_attachment_dto.dart';
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/features/chat/chatbot_attachment.dart';

double _lum(Color c) => c.computeLuminance();

double _ratio(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Future<(Color, Color)> _resolve(
  WidgetTester tester,
  ChatbotActionStyle style,
  ThemeData theme,
) async {
  late Color color;
  late Color surface;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) {
          color = chatbotActionColor(context, style);
          surface = DesignPalette.of(context).surface;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (color, surface);
}

void main() {
  for (final entry in {
    'light': AppTheme.light(),
    'dark': AppTheme.dark(),
  }.entries) {
    testWidgets('${entry.key}：六个 style 的文字都 ≥ 4.5:1（DA182）', (tester) async {
      for (final style in ChatbotActionStyle.values) {
        final (c, surface) = await _resolve(tester, style, entry.value);
        final r = _ratio(c, surface);
        expect(
          r,
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} / ${style.name}：$c 对 $surface 只有 ${r.toStringAsFixed(2)}:1',
        );
      }
    });
  }

  testWidgets('色相不许丢：绿仍偏绿、红仍偏红', (tester) async {
    final light = AppTheme.light();
    final (green, _) = await _resolve(tester, ChatbotActionStyle.green, light);
    final (red, _) = await _resolve(tester, ChatbotActionStyle.red, light);
    expect(green.g, greaterThan(green.r), reason: '绿被拟合成了 $green');
    expect(green.g, greaterThan(green.b), reason: '绿被拟合成了 $green');
    expect(red.r, greaterThan(red.g), reason: '红被拟合成了 $red');
    expect(red.r, greaterThan(red.b), reason: '红被拟合成了 $red');
  });

  testWidgets('量化后仍达标（真机像素判据，不是浮点判据）', (tester) async {
    // 真机上 `Color.lerp` 的浮点通道会被四舍五入成 8 位：4.50:1 可能掉到 4.47:1。
    // 这里按"8 位量化后的颜色"复算一遍，确保屏幕上真的看得清。
    const white = Color(0xFFFFFFFF);
    for (final style in ChatbotActionStyle.values) {
      final (c, _) = await _resolve(tester, style, AppTheme.light());
      final q = Color.fromARGB(
        255,
        (c.r * 255).round(),
        (c.g * 255).round(),
        (c.b * 255).round(),
      );
      expect(_ratio(q, white), greaterThanOrEqualTo(4.5),
          reason: '${style.name} 量化后 ${_ratio(q, white).toStringAsFixed(2)}:1');
    }
  });

  test('反证：原始品牌色在亮色底上确实不达标', () {
    const white = Color(0xFFFFFFFF);
    final worst = [
      for (final s in ChatbotActionStyle.values) s.color,
    ].map((c) => _ratio(c, white)).toList();
    expect(worst.every((r) => r < 4.5), isTrue,
        reason: '有品牌色本来就 ≥4.5，说明本用例的前提不成立：$worst');
    expect(worst.reduce((a, b) => a < b ? a : b), lessThan(2.6),
        reason: '最差的品牌色应当很差（真机绿 OK 量到 2.41:1）');
  });
}
