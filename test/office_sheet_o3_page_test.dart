// O3 批：`.osheet` **公式求值 + 图表绘制 + 隐藏行列** 页面层验收。
//
// 直接挂载 `OfficeSheetView`（真夹具 sections），断言**用户在屏幕上看到的东西**：
//   * 公式格显示**算出来的数值**（`=SUM(B13:B21)` → `200000`，`=C7-C9` → `$295.00`）；
//   * 图表是一个真的 `OfficeSheetChartPainter`（类型/分类数/标题都对），
//     **不是**占位卡；
//   * 隐藏行/列真的不出现（无格子、无表头，尺寸不占位）；
//   * 类型不支持/无数据 → 退回占位卡（不空白、不崩）。
//
// 无网络、无设备、无构建。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_sheet_chart.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_sheet_view.dart';

Map<String, Object?> _sections(String name) =>
    (jsonDecode(File('test/fixtures/office_sheet_o2/$name').readAsStringSync())
            as Map)
        .cast<String, Object?>();

Widget _host(
  Map<String, Object?> sections, [
  OfficeSheetRenderReport? report,
]) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(
    body: OfficeSheetView(
      initialScale: 1.0,
      sections: sections,
      report: report,
    ),
  ),
);

/// 单元格里的 `Text` 内容（公式值键 → 显示文本）。
String? _textAt(WidgetTester tester, String key) {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) return null;
  final widget = finder.evaluate().first.widget;
  if (widget is Text) return widget.data;
  final text = find.descendant(of: finder, matching: find.byType(Text));
  if (text.evaluate().isEmpty) return null;
  return tester.widget<Text>(text.first).data;
}

OfficeSheetChartPainter _chartPainter(WidgetTester tester, String id) {
  final paint = tester.widget<CustomPaint>(
    find.byKey(Key('office-sheet-chart-paint-$id')),
  );
  return paint.painter! as OfficeSheetChartPainter;
}

/// 隐藏行列用例的 sections：3×3，第 2 行（0 基 1）与第 2 列（0 基 1）隐藏。
///
/// ⚠️ 夹具里**没有**任何 hidden 真样本（三份 `.osheet` 的 `rows`/`cols` 都没有
/// `hidden:true`），所以这是**按 schema 构造**的最小 sections（③构造）。
Map<String, Object?> _hiddenSections() => <String, Object?>{
  'index': <String, Object?>{
    'order': <Object?>['sh_1'],
    'sheets': <String, Object?>{
      'sh_1': <String, Object?>{'title': 'Hidden'},
    },
  },
  'sh_1': <String, Object?>{
    'rowCount': 3,
    'colCount': 3,
    'cells': <String, Object?>{
      '0': <String, Object?>{
        '0': <String, Object?>{'v': 'A1'},
        '1': <String, Object?>{'v': 'B1'},
      },
      '1': <String, Object?>{
        '0': <String, Object?>{'v': 'A2'},
        '1': <String, Object?>{'v': 'B2'},
      },
      '2': <String, Object?>{
        '0': <String, Object?>{'v': 'A3'},
        '1': <String, Object?>{'v': 'B3'},
      },
    },
    'rows': <String, Object?>{
      '1': <String, Object?>{'hidden': true},
    },
    'cols': <String, Object?>{
      '1': <String, Object?>{'hidden': true},
    },
    'mergeCells': <Object?>[],
    'drawing': <Object?>[],
    'cfs': <Object?>[],
  },
};

void main() {
  group('P-O3.1 公式真的算出数值（真夹具）', () {
    testWidgets(r'annual：=SUM(B13:B21) 显示 200,000（数字格式 #,##0，不是公式原文）', (
      tester,
    ) async {
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(
        _host(_sections('annual_income_and_expenditure.json'), report),
      );
      await tester.pumpAndSettle();
      expect(_textAt(tester, 'office-sheet-formula-value-21-1'), '200,000');
      // 公式原文键还在（向后兼容），但内容已是数值。
      expect(_textAt(tester, 'office-sheet-formula-21-1'), '200,000');
      expect(find.text('=SUM(B13:B21)'), findsNothing);
      expect(report.formulaCellsEvaluated, greaterThan(0));
    });

    testWidgets(r'sales：=SUM(G8:G17) 显示 $2,877.00 / =F8*E8 显示 $300.00', (
      tester,
    ) async {
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(_sections('sales_tracker.json'), report));
      await tester.pumpAndSettle();
      expect(_textAt(tester, 'office-sheet-formula-value-17-6'), r'$2,877.00');
      expect(_textAt(tester, 'office-sheet-formula-value-7-6'), r'$300.00');
      expect(find.text('=SUM(G8:G17)'), findsNothing);
    });

    testWidgets(r'travel：=C7-C9 显示 $295.00 / =I33 显示 $2,455.00（数字格式仍生效）', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_sections('travel_expenses.json')));
      await tester.pumpAndSettle();
      // 真机 C7 已能出 `$2,750.00`；C9 = I33 = 2455、C11 = C7-C9 = 295。
      final c11 = _textAt(tester, 'office-sheet-formula-value-10-2');
      expect(c11, isNotNull);
      expect(c11, contains('295'));
      final c9 = _textAt(tester, 'office-sheet-formula-value-8-2');
      expect(c9, isNotNull);
      expect(c9, contains('2,455'));
      // 真机原来显示的公式原文**不该**再出现。
      expect(find.text('=C7-C9'), findsNothing);
      expect(find.text('=I33'), findsNothing);
    });

    testWidgets('不支持的函数（CONCATENATE）→ 原文可见（退化，不空白不崩）', (tester) async {
      // ③构造：真实模板 `to_do_list_simple` 里就有这条 CONCATENATE 公式
      // （office_sheet_view_test.dart 的 todoSections 逐字内联），这里用最小
      // sections 复现同一条公式的**退化**行为。
      final sections = <String, Object?>{
        'index': <String, Object?>{
          'order': <Object?>['sh_1'],
          'sheets': <String, Object?>{
            'sh_1': <String, Object?>{'title': 'F'},
          },
        },
        'sh_1': <String, Object?>{
          'rowCount': 1,
          'colCount': 1,
          'cells': <String, Object?>{
            '0': <String, Object?>{
              '0': <String, Object?>{'v': '=CONCATENATE(COUNTA(C4:C34), "/")'},
            },
          },
          'rows': <String, Object?>{},
          'cols': <String, Object?>{},
          'mergeCells': <Object?>[],
          'drawing': <Object?>[],
          'cfs': <Object?>[],
        },
      };
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(sections, report));
      await tester.pumpAndSettle();
      expect(find.text('=CONCATENATE(COUNTA(C4:C34), "/")'), findsOneWidget);
      expect(report.formulaCellsFallback, 1);
      expect(report.formulaCellsEvaluated, 0);
    });
  });

  group('P-O3.2 图表真的画出来（真夹具）', () {
    testWidgets(
      'sales：barChart「Product Profit Per Item」+ pieChart「% Income…」',
      (tester) async {
        final report = OfficeSheetRenderReport();
        await tester.pumpWidget(_host(_sections('sales_tracker.json'), report));
        await tester.pumpAndSettle();

        expect(report.chartsRendered, 2);
        expect(report.unsupportedDrawingItems, 0);

        final bar = _chartPainter(tester, 'c8e98ec07208261d');
        expect(bar.kind, OfficeSheetChartKind.bar);
        expect(bar.title, 'Product Profit Per Item');
        expect(bar.data.categories.length, 5, reason: 'B8:B12 的 5 个分类');
        expect(bar.data.values.first, <num?>[
          14.25,
          7.75,
          10.75,
          8.75,
          7.75,
        ], reason: 'J8:J12 = C*D+H-I 的求值结果');

        final pie = _chartPainter(tester, '88650364051df188');
        expect(pie.kind, OfficeSheetChartKind.pie);
        expect(pie.title, '% Income Per Product');
        expect(pie.data.categories.length, 5, reason: '饼图 5 个扇形');
        expect(pie.data.values.first, <num?>[
          213.75,
          139.5,
          430.0,
          262.5,
          465.0,
        ], reason: 'K8:K12 = J*E 的求值结果');

        // 真的图形在画，**不是**占位卡。
        expect(
          find.byKey(const Key('office-sheet-chart-c8e98ec07208261d')),
          findsNothing,
        );
      },
    );

    testWidgets('travel：饼图「Expense Distribution」6 个扇形、数值成比例', (tester) async {
      await tester.pumpWidget(_host(_sections('travel_expenses.json')));
      await tester.pumpAndSettle();
      final pie = _chartPainter(tester, 'ef5e3ffd97cfae91');
      expect(pie.kind, OfficeSheetChartKind.pie);
      expect(pie.title, 'Expense Distribution');
      expect(pie.data.categories, <String>[
        'Transportation',
        'Lodging',
        'Food',
        'Entertainment',
        'Shopping',
        'Others',
      ]);
      final sectors = officeSheetPieSectors(pie.data.values.first);
      expect(sectors.length, 6);
      // 首扇（Transportation = 950 / 2455）。
      expect(
        sectors.first.sweep,
        closeTo(950 / 2455 * 2 * 3.141592653589793, 1e-9),
      );
    });

    testWidgets('图表的尺寸 = `pos.width/height`（真的按声明排版）', (tester) async {
      await tester.pumpWidget(_host(_sections('sales_tracker.json')));
      await tester.pumpAndSettle();
      final size = tester.getSize(
        find.byKey(const Key('office-sheet-chart-paint-c8e98ec07208261d')),
      );
      expect(size.width, closeTo(566, 1));
      expect(size.height, closeTo(363, 1));
    });
  });

  group('P-O3.3 隐藏行/列真的隐藏', () {
    testWidgets('第 2 行/第 2 列不渲染（无格子、无表头），且报告如实计数', (tester) async {
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(_hiddenSections(), report));
      await tester.pumpAndSettle();

      // 可见格仍在。
      expect(find.byKey(const Key('office-sheet-cell-0-0')), findsOneWidget);
      expect(find.byKey(const Key('office-sheet-cell-2-0')), findsOneWidget);
      expect(find.byKey(const Key('office-sheet-cell-0-2')), findsOneWidget);
      // 隐藏行 r1 / 隐藏列 c1 的格子**不存在**。
      expect(find.byKey(const Key('office-sheet-cell-1-0')), findsNothing);
      expect(find.byKey(const Key('office-sheet-cell-0-1')), findsNothing);
      expect(find.byKey(const Key('office-sheet-cell-2-1')), findsNothing);
      // 表头也不画。
      expect(find.byKey(const Key('office-sheet-row-header-1')), findsNothing);
      expect(find.byKey(const Key('office-sheet-col-header-1')), findsNothing);
      expect(report.hiddenRowsHidden, 1);
      expect(report.hiddenColsHidden, 1);
    });

    testWidgets('隐藏行的行高为 0（不占位）', (tester) async {
      await tester.pumpWidget(_host(_hiddenSections()));
      await tester.pumpAndSettle();
      final a1 = tester.getTopLeft(
        find.byKey(const Key('office-sheet-cell-0-0')),
      );
      final a3 = tester.getTopLeft(
        find.byKey(const Key('office-sheet-cell-2-0')),
      );
      // 三行等高（默认 22）：隐藏行高为 0 ⇒ A3 顶 = A1 顶 + 22（少掉一整行）。
      expect(a3.dy - a1.dy, closeTo(22, 1));
    });
  });

  group('P-O3.4 图表退回占位卡（类型不支持）', () {
    testWidgets('chartType=radar → 占位卡可见，页面不崩不空白', (tester) async {
      final sections = <String, Object?>{
        ..._hiddenSections(),
        'sh_1': <String, Object?>{
          ...(_hiddenSections()['sh_1']! as Map).cast<String, Object?>(),
          'drawing': <Object?>[
            <String, Object?>{
              'id': 'radar-1',
              'type': 'chart',
              'pos': <String, Object?>{
                'left': 0,
                'top': 0,
                'width': 200,
                'height': 150,
              },
              'chartObj': <String, Object?>{
                'chartType': 'radar',
                'title': <String, Object?>{'text': '雷达图'},
                'displayRange': 'A1:B3',
              },
            },
          ],
        },
      };
      final report = OfficeSheetRenderReport();
      await tester.pumpWidget(_host(sections, report));
      await tester.pumpAndSettle();
      expect(report.chartsRendered, 0);
      expect(report.unsupportedDrawingItems, 1);
      expect(
        find.byKey(const Key('office-sheet-chart-radar-1')),
        findsOneWidget,
      );
      expect(find.textContaining('图表内容暂不能显示'), findsOneWidget);
    });
  });
}
