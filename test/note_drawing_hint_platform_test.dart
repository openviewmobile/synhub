// D23 守卫（r716）：桌面宿主的措辞不许是「单指绘制」。
//
// 真机像素（macOS `n14_note_drawing.png`）曾经写 `Draw with one finger; …` —— 手机手势措辞。
// 这里钉住三件事：桌面出指针措辞、移动端仍出触摸措辞、两套措辞都不为空。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/notes/note_drawing_page.dart';

Widget _host(TargetPlatform platform) => MaterialApp(
      theme: ThemeData(platform: platform),
      home: const NoteDrawingPage(),
    );

void main() {
  testWidgets('① 桌面（macOS）出指针措辞，不出「单指/finger」', (tester) async {
    await tester.pumpWidget(_host(TargetPlatform.macOS));
    await tester.pump(const Duration(milliseconds: 200));
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(texts.contains('拖拽绘制'), isTrue, reason: '桌面没有指针措辞：$texts');
    expect(texts.contains('单指'), isFalse, reason: '桌面还在写手机手势：$texts');
  });

  testWidgets('② 移动端（android）仍是触摸措辞', (tester) async {
    await tester.pumpWidget(_host(TargetPlatform.android));
    await tester.pump(const Duration(milliseconds: 200));
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(texts.contains('单指绘制'), isTrue, reason: '移动端没有触摸措辞：$texts');
  });
}
