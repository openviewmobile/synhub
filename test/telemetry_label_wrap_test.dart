// ★ r533（DA170）：`TelemetryLabel` 默认 1 行 + 省略号。短代号没问题，
// 但**整句提示**用默认值就会被省略号截成半句（DA169 的同族）。
// 这里量两件事：① 默认仍是 1 行（不改变既有 75 处短标签的观感）；
// ② 给 `maxLines: 2` 时，一句 40+ 字符的英文在 390 宽下真的排成两行、且不带省略号。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/ui/hud_widgets.dart';

Future<void> _pump(WidgetTester tester, Widget child, {double width = 358}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

const String _sentence =
    'Double-tap to zoom / double-tap again to reset · pinch to zoom';

void main() {
  testWidgets('DA170：默认仍是 1 行（不改变短标签的观感）', (tester) async {
    await _pump(tester, const TelemetryLabel('AUTH · BOUND'));
    final label = tester.widget<TelemetryLabel>(find.byType(TelemetryLabel));
    expect(label.maxLines, 1);
  });

  testWidgets('DA170：整句提示给 maxLines:2 ⇒ 排两行且无省略号', (tester) async {
    await _pump(
      tester,
      const TelemetryLabel(_sentence, size: 10, maxLines: 2),
    );
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.maxLines, 2, reason: 'DA170：提示要允许两行');
    expect(text.overflow, TextOverflow.ellipsis);
    // 单行放不下这句（宽度 300、字号 10）⇒ 必须真的用掉两行
    final box = tester.renderObject<RenderBox>(find.byType(Text));
    final painter = TextPainter(
      text: TextSpan(text: _sentence, style: text.style),
      maxLines: 2,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 358);
    expect(painter.didExceedMaxLines, isFalse,
        reason: 'DA170：两行之内必须放得下整句');
    expect(painter.height, greaterThan(14),
        reason: 'DA170：这句在 358 宽下应当真的换行（一行装不下）');
    expect(box.size.width, lessThanOrEqualTo(358));
  });
}
