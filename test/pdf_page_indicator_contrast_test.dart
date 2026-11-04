// 第 234 轮 · `DA178`（用户裁定 ③「亮色与暗色同等精细」）：
// **页码是信息，不能因为"没目录"就进入禁用态**。
//
// 真机（亮色 PDF 预览，`ai_report_en.pdf` 无目录）：
//   中键文字 `(140,144,154)` 压在禁用底 `(215,218,224)` 上 = **2.28:1**
//   —— 页码基本读不出来，而且禁用底色还多出一块残缺方块。
//
// 本用例钉三件事：
//   ① 无目录时中键是 `pdf-page-indicator` 只读标签（不是按钮，不许有 onPressed）；
//   ② 该标签文字对底色的对比 ≥ 4.5（亮/暗两套各算一遍）；
//   ③ 有目录时仍然是可点按钮，且点了会弹目录面板（修完不许把入口弄丢）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/core/theme/app_shapes.dart';
import 'package:synhub/src/features/files/file_pdf_view.dart';
import 'package:synhub/src/features/files/pdf_doc.dart';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Widget _app(ThemeData theme, Widget child) => MaterialApp(
      theme: theme,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('无目录：中键是只读页码标签，且对比 ≥ AA（DA178）', (tester) async {
    for (final entry in <String, ThemeData>{
      'light': AppTheme.light(),
      'dark': AppTheme.dark(),
    }.entries) {
      final p = entry.key == 'light' ? DesignPalette.light : DesignPalette.dark;
      await tester.pumpWidget(
        _app(
          entry.value,
          PdfTocBar(page: 1, pageCount: 1, toc: const [], onJump: (_) {}),
        ),
      );
      // ★ MaterialApp 的主题切换是**动画**的：只 pump 一帧时树里还是上一套主题
      //   （本轮实测：暗色那一轮读到的是亮色调色板，差点写成"色不一致"的假缺陷）。
      await tester.pumpAndSettle();
      final finder = find.byKey(const Key('pdf-page-indicator'));
      expect(finder, findsOneWidget, reason: '${entry.key}：缺只读页码标签');

      // 不是按钮（无目录时不该假装能点）
      expect(
        find.descendant(of: finder, matching: find.byType(FilledButton)),
        findsNothing,
        reason: '${entry.key}：无目录时不该还是按钮',
      );

      final container = tester.widget<Container>(finder);
      // ★ r554：底色现在用 `ShapeDecoration`（形状是设计语言的 `ChamferBorder` 切角，
      //   不是胶囊）。这里两种装饰都要认，否则"改了形状"会把用例误判成"改了颜色"。
      final deco = container.decoration!;
      final Color? bg = switch (deco) {
        BoxDecoration() => deco.color,
        ShapeDecoration() => deco.color,
        _ => null,
      };
      expect(bg, isNotNull, reason: '${entry.key}：页码标签没有底色');
      // 形状必须是切角（设计语言），不是胶囊
      expect(
        deco is ShapeDecoration && deco.shape is ChamferBorder,
        isTrue,
        reason: '${entry.key}：页码标签必须沿用 ChamferBorder 切角',
      );
      final text = tester.widget<Text>(
        find.descendant(of: finder, matching: find.byType(Text)),
      );
      final r = _ratio(text.style!.color!, bg!);
      expect(
        r,
        greaterThanOrEqualTo(4.5),
        reason: '${entry.key}：页码 ${r.toStringAsFixed(2)}:1 低于 AA',
      );
      // 底色必须不透明（半透明会让它压到页面底上，对比随背景漂移）
      expect(bg.a, 1.0, reason: '${entry.key}：页码底必须是实色');
      // 文字必须是"花在 muted 或 text 上的令牌色"，不许是禁用色
      expect(
        text.style!.color == p.muted || text.style!.color == p.text,
        isTrue,
        reason: '${entry.key}：页码文字应是 muted/text，而不是禁用灰',
      );
    }
  });

  testWidgets('有目录：中键仍是可点按钮，点了弹目录面板', (tester) async {
    await tester.pumpWidget(
      _app(
        AppTheme.light(),
        PdfTocBar(
          page: 2,
          pageCount: 9,
          toc: const [PdfTocEntry(title: 'Chapter 1', depth: 0, pageIndex: 0)],
          onJump: (_) {},
        ),
      ),
    );
    expect(find.byKey(const Key('pdf-page-indicator')), findsNothing);
    final btn = find.byType(FilledButton);
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('book-toc-list')), findsOneWidget);
  });

  test('反证：旧的禁用态配色确实不达标（否则本条没有区分力）', () {
    // 真机量到的禁用态：文字 (140,144,154) / 底 (215,218,224)
    const oldFg = Color.fromARGB(255, 140, 144, 154);
    const oldBg = Color.fromARGB(255, 215, 218, 224);
    expect(_ratio(oldFg, oldBg), lessThan(3.0));
  });
}
