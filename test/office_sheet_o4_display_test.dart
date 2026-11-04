// O4 批：**屏幕上真的显示了什么** —— `.osheet` 显示重做的页面层验收。
//
// 数据全部来自**真实 NAS 文件**（`test/fixtures/office_sheet_o2/*.xlsx`）。
// 这里断言的核心是"**文档画布不读 App 主题**"，所以刻意用 **App 自己的深色主题**
// （`AppTheme.dark()`）当宿主：旧实现正是在深色主题下把整张白纸表格画成黑底，
// 并把未声明字色的格子画成白字（叠在文件的浅灰/浅蓝填充上 = 看不见）。
//
// 本文件只断言**颜色来源与形态**，不比对屏幕像素（真机截图是 Display P3，
// 见报告里的色彩空间说明）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_sheet_ooxml_color.dart';
import 'package:synhub/src/features/office/office_sheet_view.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/office_sheet_o2/$name').readAsBytesSync();

Widget _host(
  Widget child, {
  bool dark = true,
  double width = 360,
  double height = 640,
}) => MaterialApp(
  theme: dark ? AppTheme.dark() : AppTheme.light(),
  home: Scaffold(
    body: SizedBox(width: width, height: height, child: child),
  ),
);

Widget _annual() => OfficeSheetView(
  initialScale: 1.0,
  sections: const <String, Object?>{},
  ooxmlBytes: _fixture('annual_income_and_expenditure.xlsx'),
);

/// 单元格里那个 `Text` 的样式。
TextStyle _cellTextStyle(WidgetTester tester, int r, int c) {
  final finder = find
      .descendant(
        of: find.byKey(Key('office-sheet-cell-$r-$c')),
        matching: find.byType(Text),
      )
      .first;
  return tester.widget<Text>(finder).style!;
}

BoxDecoration _cellDecoration(WidgetTester tester, int r, int c) =>
    tester
            .widget<Container>(find.byKey(Key('office-sheet-cell-$r-$c')))
            .decoration!
        as BoxDecoration;

BoxDecoration _boxDecoration(WidgetTester tester, Key key) =>
    tester.widget<Container>(find.byKey(key)).decoration! as BoxDecoration;

void main() {
  group('D1. ★ 文档画布底色 = 白纸（不再吃 App 主题）', () {
    testWidgets('深色主题下仍然铺一张白纸（office-sheet-paper）', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();

      final paper = find.byKey(const Key('office-sheet-paper'));
      expect(paper, findsOneWidget, reason: '必须有文档白纸底层');
      final box = tester.widget<ColoredBox>(paper);
      expect(box.color, kOfficeSheetPaperColor);
      expect(box.color, const Color(0xFFFFFFFF));
    });

    testWidgets('★ 深色主题不会让白纸变黑：纸面与 App surface 不同', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();
      final ctx = tester.element(find.byKey(const Key('office-sheet-paper')));
      final surface = Theme.of(ctx).colorScheme.surface;
      // App 深色主题的 surface 是暗的；文档纸面必须**不是**它。
      expect(surface.computeLuminance(), lessThan(0.5));
      expect(kOfficeSheetPaperColor.computeLuminance(), greaterThan(0.9));
    });

    testWidgets('无填充的格子保持透明（透出白纸），不额外涂 App 色', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();
      // A13「Wages」：真实文件 fillId=0 → 无填充。
      final deco = _cellDecoration(tester, 12, 0);
      expect(deco.color, isNull, reason: '没填充就该是透明，而不是 App 的 surface');
    });
  });

  group('D2. ★ 文字对比度：浅底配黑字（旧实现给白字 → 看不见）', () {
    testWidgets('A5「Total Income」浅灰底 + 文件未给字色 → **黑字**（深色主题下）', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();

      final deco = _cellDecoration(tester, 4, 0);
      expect(deco.color, const Color(0xFFF0F2F4));
      final style = _cellTextStyle(tester, 4, 0);

      expect(
        style.color,
        const Color(0xFF000000),
        reason:
            '文件没声明字色 → 必须按填充明暗判对比度，'
            '浅灰底 F0F2F4 上应为黑字（旧实现拿 App 深色主题的 bodySmall = 白字）',
      );
      // 而且这个黑字在浅底上真的看得清
      expect(
        officeSheetContrastRatio(deco.color!, style.color!),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('A22「Total」浅绿底 → 黑字', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();
      expect(_cellDecoration(tester, 21, 0).color, const Color(0xFFE6FAEE));
      expect(_cellTextStyle(tester, 21, 0).color, const Color(0xFF000000));
    });

    testWidgets('A3「Starting Balance」浅蓝底 → 黑字', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();
      expect(_cellDecoration(tester, 2, 0).color, const Color(0xFFAAD4F2));
      expect(_cellTextStyle(tester, 2, 0).color, const Color(0xFF000000));
    });

    testWidgets('无填充的 A13「Wages」→ 白纸上黑字', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();
      expect(_cellTextStyle(tester, 12, 0).color, const Color(0xFF000000));
    });
  });

  group('D3. ★ 文件显式字色以文件为准（对比度不得覆盖它）', () {
    testWidgets('A12「INCOME」：文件显式白字 + 绿底 → 仍是白字', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();
      final deco = _cellDecoration(tester, 11, 0);
      expect(deco.color, const Color(0xFF4DBF7C));
      expect(_cellTextStyle(tester, 11, 0).color, const Color(0xFFFFFFFF));
    });

    testWidgets('A1 标题：显式白字 + 蓝底 → 仍是白字', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();
      expect(_cellDecoration(tester, 0, 0).color, const Color(0xFF419AD9));
      expect(_cellTextStyle(tester, 0, 0).color, const Color(0xFFFFFFFF));
    });

    testWidgets('A24「HOME EXPENSES」：显式白字 + 橙底 → 仍是白字', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();
      expect(_cellDecoration(tester, 23, 0).color, const Color(0xFFFAA732));
      expect(_cellTextStyle(tester, 23, 0).color, const Color(0xFFFFFFFF));
    });
  });

  group('D4. ★ 浅色/深色主题下**渲染结果一致**（文档画布与 App 主题解耦）', () {
    testWidgets('同一批格子的填充色与文字色在两种主题下逐位相等', (tester) async {
      final samples = <List<int>>[
        [0, 0], // A1 标题
        [2, 0], // A3 浅蓝底
        [4, 0], // A5 浅灰底
        [11, 0], // A12 绿底白字
        [12, 0], // A13 无填充
        [21, 0], // A22 浅绿底
        [23, 0], // A24 橙底
      ];

      Future<Map<String, List<int?>>> snapshot({required bool dark}) async {
        await tester.pumpWidget(_host(_annual(), dark: dark));
        await tester.pumpAndSettle();
        final out = <String, List<int?>>{};
        for (final s in samples) {
          final deco = _cellDecoration(tester, s[0], s[1]);
          final text = _cellTextStyle(tester, s[0], s[1]);
          out['${s[0]}-${s[1]}'] = <int?>[
            deco.color?.toARGB32(),
            text.color?.toARGB32(),
          ];
        }
        return out;
      }

      final darkRun = await snapshot(dark: true);
      final lightRun = await snapshot(dark: false);
      expect(darkRun, lightRun, reason: '文档画布不应随 App 主题变化');
    });

    testWidgets('行号列 / 列标行用文档表头色（不是 App 的 surfaceContainerHighest）', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();

      final ctx = tester.element(find.byType(OfficeSheetView));
      final themeHeader = Theme.of(ctx).colorScheme.surfaceContainerHighest;

      for (final key in <Key>[
        const Key('office-sheet-row-header-4'),
        const Key('office-sheet-col-header-0'),
        const Key('office-sheet-corner'),
      ]) {
        final deco = _boxDecoration(tester, key);
        expect(deco.color, kOfficeSheetHeaderFillColor, reason: '$key');
        expect(deco.color, isNot(themeHeader), reason: '$key 不该用 App 主题色');
      }
      // 表头文字色也来自文档
      final headerText = tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(const Key('office-sheet-row-header-4')),
              matching: find.byType(Text),
            )
            .first,
      );
      expect(headerText.style?.color, kOfficeSheetHeaderTextColor);
    });
  });

  group('D5. 网格线来自文档，不是 App 的 dividerColor', () {
    testWidgets('A5（文件 borderId=0）→ 落到文档网格线灰', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();
      final ctx = tester.element(find.byType(OfficeSheetView));
      final divider = Theme.of(ctx).dividerColor;

      final deco = _cellDecoration(tester, 4, 0);
      final border = deco.border! as Border;
      expect(border.bottom.color, kOfficeSheetGridLineColor);
      expect(border.bottom.color, isNot(divider));
    });

    testWidgets('★ 逐边合成：文件给了的边用文件色，没给的边仍显示网格线', (tester) async {
      await tester.pumpWidget(_host(_annual()));
      await tester.pumpAndSettle();
      // B13 s=20 → 真实 borders[13] 只有 left/top = 7B8187，**没有 bottom**。
      final deco = _cellDecoration(tester, 12, 1);
      final border = deco.border! as Border;
      expect(border.top.color, const Color(0xFF7B8187), reason: '文件声明了 top');
      expect(border.left.color, const Color(0xFF7B8187), reason: '文件声明了 left');
      // 文件**没声明** bottom → 该边必须仍显示网格线（Excel/WPS 同形态），
      // 而不是被 `BorderSide.none` 抹掉。
      expect(border.bottom.color, kOfficeSheetGridLineColor);
      expect(border.bottom.width, greaterThan(0));
    });
  });

  group('D6. 真实 Sales tracker：既有形态没被改坏', () {
    testWidgets('列宽 / 标题字号 / 表头填充色保持（回归）', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
          dark: false,
        ),
      );
      await tester.pumpAndSettle();

      final title = tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(const Key('office-sheet-cell-2-1')),
              matching: find.text('Sales Tracker'),
            )
            .first,
      );
      expect(title.style?.fontSize, 30);
      expect(title.style?.fontFamily, 'Microsoft Sans Serif');
      // 真实 cellXfs[14] → fillId 3 → FF6153A6
      expect(_cellDecoration(tester, 0, 0).color, const Color(0xFF6153A6));
    });
  });
}
