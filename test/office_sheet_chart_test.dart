// O3 批：`.osheet` **图表真实绘制**离线验收（接口层）。
//
// 断言的是**画出来的图形**（数据映射 + 几何 + 真的往 Canvas 上落了像素），
// 不是"占位卡换了个样式"：
//   * 真夹具 `Sales tracker.osheet` / `Travel expenses.osheet` 的
//     `chartObj.displayRange` / `plotArea.series` → 分类标签 + 系列数值；
//   * 柱状图矩形数量/高度、饼图扇形数量/角度（`2π` 闭合、首扇从 12 点开始）；
//   * XLSX 主通道也解析 `chartN.xml`（`cat`/`val`/`title`/`chartType`）；
//   * 无数据 / 类型不支持 → 明确退回（让渲染层用占位卡），不抛。
//
// ⚠️ 夹具里**没有 line 真样本**，line 属于 schema 防御性实现，这里用构造数据测。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/osheet_formula.dart';
import 'package:synhub/src/data/office_native/osheet_model.dart';
import 'package:synhub/src/features/office/office_sheet_chart.dart';
import 'package:synhub/src/features/office/office_sheet_xlsx.dart';

const double _epsilon = 1e-9;

Map<String, Object?> _sections(String name) =>
    (jsonDecode(File('test/fixtures/office_sheet_o2/$name').readAsStringSync())
            as Map)
        .cast<String, Object?>();

OSheetSheet _sheet(String name) =>
    OSheetWorkbook.fromSections(_sections(name)).sheets.first;

OfficeSheetChartData _dataFor(OSheetSheet sheet, OfficeSheetChart chart) {
  final engine = OSheetFormulaEngine(sheet);
  return officeSheetChartData(chart, OfficeSheetEngineDataSource(engine))!;
}

void main() {
  group('C1. 解析（真夹具 chartObj）', () {
    test('Sales tracker：2 个图表（bar + pie），位置/标题/系列齐', () {
      final sheet = _sheet('sales_tracker.json');
      final charts = officeSheetCharts(sheet.raw['drawing']);
      expect(charts.length, 2);

      final bar = charts[0];
      expect(bar.kind, OfficeSheetChartKind.bar);
      expect(bar.title, 'Product Profit Per Item');
      expect(bar.chartTypeRaw, 'bar');
      expect(bar.barDir, 'col');
      expect(bar.horizontal, isFalse);
      expect(bar.isRenderable, isTrue);
      expect(bar.series.length, 1);
      expect(bar.series.first.cat, 'B8:B12');
      expect(bar.series.first.val, 'J8:J12');
      expect(bar.displayRange, 'B8:B12,J8:J12');
      // `pos` 原样（真机就是 88,145,566,363）。
      expect(
        (bar.left, bar.top, bar.width, bar.height),
        (88.0, 145.0, 566.0, 363.0),
      );

      final pie = charts[1];
      expect(pie.kind, OfficeSheetChartKind.pie);
      expect(pie.title, '% Income Per Product');
      expect(pie.series.first.val, 'K8:K12');
    });

    test('Travel expenses：1 个饼图，displayRange F6:G11', () {
      final sheet = _sheet('travel_expenses.json');
      final charts = officeSheetCharts(sheet.raw['drawing']);
      expect(charts.length, 1);
      expect(charts.single.kind, OfficeSheetChartKind.pie);
      expect(charts.single.title, 'Expense Distribution');
      expect(charts.single.displayRange, 'F6:G11');
      expect(charts.single.series.single.cat, 'F6:F11');
      expect(charts.single.series.single.val, 'G6:G11');
    });

    test('没有 `plotArea.series` → 退回 displayRange 拆分（第一段分类）', () {
      final charts = officeSheetCharts(<Object?>[
        <String, Object?>{
          'id': 'x',
          'pos': <String, Object?>{
            'left': 0,
            'top': 0,
            'width': 100,
            'height': 80,
          },
          'chartObj': <String, Object?>{
            'chartType': 'bar',
            'barDir': 'col',
            'displayRange': 'B8:B12,J8:J12',
          },
        },
      ]);
      final chart = charts.single;
      expect(chart.series.length, 1);
      expect(chart.series.single.cat, 'B8:B12');
      expect(chart.series.single.val, 'J8:J12');
      expect(chart.isRenderable, isTrue);
    });

    test('类型不支持 / 缺 pos → 不可绘制（退回占位卡），不崩', () {
      expect(officeSheetChartKindOf('radar'), isNull);
      expect(officeSheetChartKindOf('area'), isNull);
      expect(officeSheetChartKindOf('PIE'), OfficeSheetChartKind.pie);
      final charts = officeSheetCharts(<Object?>[
        <String, Object?>{
          'id': 'radar',
          'pos': <String, Object?>{
            'left': 0,
            'top': 0,
            'width': 100,
            'height': 80,
          },
          'chartObj': <String, Object?>{
            'chartType': 'radar',
            'displayRange': 'B8:B12,J8:J12',
          },
        },
        <String, Object?>{'id': 'no-pos', 'chartObj': <String, Object?>{}},
        'not-a-map',
      ]);
      expect(charts.length, 1, reason: '缺 pos / 非 map 的条目直接丢');
      expect(charts.single.isRenderable, isFalse);
      expect(officeSheetCharts(null), isEmpty);
      expect(officeSheetCharts(<Object?>[]), isEmpty);
    });
  });

  group('C2. 数据映射（真夹具 → 分类 + 数值）', () {
    test('Sales tracker 柱状图：J8:J12 的**公式求值结果**成系列', () {
      final sheet = _sheet('sales_tracker.json');
      final chart = officeSheetCharts(sheet.raw['drawing'])[0];
      final data = _dataFor(sheet, chart);
      expect(data.categories, <String>[
        'Item #1',
        'Item #2',
        'Item #3',
        'Item #4',
        'Item #5',
      ]);
      expect(data.values.length, 1);
      expect(data.values.first, <num?>[
        14.25,
        7.75,
        10.75,
        8.75,
        7.75,
      ], reason: 'J 列 = C*D+H-I，逐格公式求值');
      expect(data.isEmpty, isFalse);
    });

    test('Sales tracker 饼图（第 2 张）：K8:K12 的公式求值结果成系列', () {
      final sheet = _sheet('sales_tracker.json');
      final chart = officeSheetCharts(sheet.raw['drawing'])[1];
      final data = _dataFor(sheet, chart);
      expect(chart.kind, OfficeSheetChartKind.pie);
      expect(data.values.first, <num?>[
        213.75,
        139.5,
        430.0,
        262.5,
        465.0,
      ], reason: 'K 列 = J*E，逐格公式求值');
    });

    test('Travel expenses 饼图：SUMIF/除法链求值成占比', () {
      final sheet = _sheet('travel_expenses.json');
      final chart = officeSheetCharts(sheet.raw['drawing']).single;
      final data = _dataFor(sheet, chart);
      expect(data.categories, <String>[
        'Transportation',
        'Lodging',
        'Food',
        'Entertainment',
        'Shopping',
        'Others',
      ]);
      // H6..H11 = SUMIF(...)，G6..G11 = H/$C$9（C9=2455）。
      final expected = <double>[
        950,
        480,
        525,
        280,
        200,
        20,
      ].map((e) => e / 2455).toList();
      for (var i = 0; i < expected.length; i++) {
        expect(data.values.first[i]!.toDouble(), closeTo(expected[i], 1e-12));
      }
    });

    test('区域解析不出来 → `officeSheetChartData` 返回 null（不抛）', () {
      const chart = OfficeSheetChart(
        id: 'bad',
        title: 'bad',
        kind: OfficeSheetChartKind.bar,
        chartTypeRaw: 'bar',
        barDir: 'col',
        horizontal: false,
        displayRange: 'NOPE',
        series: <OfficeSheetChartSeries>[
          OfficeSheetChartSeries(cat: 'NOPE', val: 'ALSO_NOPE'),
        ],
        left: 0,
        top: 0,
        width: 100,
        height: 80,
      );
      expect(chart.isRenderable, isFalse);
      expect(
        officeSheetChartData(chart, _StubSource(const <String, Object?>{})),
        isNull,
      );
    });
  });

  group('C3. 几何（纯函数，可精确断言）', () {
    test('数值轴：含 0、向上取好看刻度', () {
      final axis = officeSheetComputeAxis(<num?>[40000, 480000]);
      expect(axis.min, 0);
      expect(axis.max, 600000, reason: '步长 200000 向上取整');
      expect(axis.ticks.first, 0);
      expect(axis.ticks.last, 600000);
      expect(axis.max, greaterThanOrEqualTo(480000));
      final small = officeSheetComputeAxis(<num?>[10, 20, 30]);
      expect(small.ticks, <double>[0, 10, 20, 30]);
      final negative = officeSheetComputeAxis(<num?>[-5, 20]);
      expect(negative.min, -10);
      expect(negative.max, 20);
      expect(officeSheetComputeAxis(<num?>[null, null]).max, 1);
    });

    test('柱状图矩形：数量 = 系列数 × 分类数，高度按数值比例', () {
      const data = OfficeSheetChartData(
        categories: <String>['a', 'b', 'c'],
        seriesNames: <String>['s1'],
        values: <List<num?>>[
          <num?>[10, 20, null],
        ],
      );
      final axis = officeSheetComputeAxis(data.allValues);
      final rects = officeSheetBarRects(
        data: data,
        plot: const Rect.fromLTWH(40, 10, 300, 100),
        axis: axis,
      );
      expect(rects.length, 1);
      expect(rects.first.length, 3);
      expect(
        rects.first[0].height,
        closeTo(50, _epsilon),
        reason: '10/20 × 100',
      );
      expect(
        rects.first[1].height,
        closeTo(100, _epsilon),
        reason: '20/20 × 100',
      );
      expect(rects.first[2].height, closeTo(0, _epsilon), reason: '缺值画 0');
      // 三条都贴着 0 基线（y = plot.bottom）。
      for (final rect in rects.first) {
        expect(rect.bottom, closeTo(110, _epsilon));
      }
    });

    test('多系列柱状图：同分类的柱子横向排开且不重叠', () {
      const data = OfficeSheetChartData(
        categories: <String>['a', 'b'],
        seriesNames: <String>['s1', 's2'],
        values: <List<num?>>[
          <num?>[10, 20],
          <num?>[5, 15],
        ],
      );
      final rects = officeSheetBarRects(
        data: data,
        plot: const Rect.fromLTWH(0, 0, 200, 100),
        axis: officeSheetComputeAxis(data.allValues),
      );
      expect(rects.length, 2);
      expect(rects[0][0].left, lessThan(rects[1][0].left));
      expect(
        rects[0][0].right,
        lessThanOrEqualTo(rects[1][0].left),
        reason: '同分类内两条不重叠',
      );
    });

    test('折线图：点位数量 = 分类数，缺值断开', () {
      const data = OfficeSheetChartData(
        categories: <String>['a', 'b', 'c'],
        seriesNames: <String>['s1'],
        values: <List<num?>>[
          <num?>[0, null, 20],
        ],
      );
      final points = officeSheetLinePoints(
        data: data,
        plot: const Rect.fromLTWH(0, 0, 200, 100),
        axis: officeSheetComputeAxis(data.allValues),
      );
      expect(points.single.length, 3);
      expect(points.single[1], isNull);
      expect(points.single[0]!.dy, closeTo(100, _epsilon), reason: '0 → 底');
      expect(points.single[2]!.dy, closeTo(0, _epsilon), reason: '最大值 → 顶');
      expect(points.single[2]!.dx, closeTo(200, _epsilon));
    });

    test('饼图扇形：数量 = 正值个数，角度成比例、闭合 2π、从 12 点开始', () {
      const values = <num?>[950, 480, 525, 280, 200, 20];
      final sectors = officeSheetPieSectors(values);
      expect(sectors.length, 6);
      final total = values.fold<num>(0, (a, b) => a + (b ?? 0));
      expect(sectors.first.start, closeTo(-math.pi / 2, _epsilon));
      expect(sectors.first.sweep, closeTo(950 / total * 2 * math.pi, _epsilon));
      final sum = sectors.fold<double>(0, (a, s) => a + s.sweep);
      expect(sum, closeTo(2 * math.pi, 1e-9), reason: '闭合整圆');
      // 每个扇形接着上一个。
      for (var i = 1; i < sectors.length; i++) {
        expect(
          sectors[i].start,
          closeTo(sectors[i - 1].start + sectors[i - 1].sweep, 1e-12),
        );
      }
      // 负值/空 → 空列表（渲染层退回占位卡）。
      expect(officeSheetPieSectors(<num?>[0, null]), isEmpty);
      expect(officeSheetPieSectors(<num?>[-1, 0]), isEmpty);
      expect(officeSheetPieSectors(const <num?>[]), isEmpty);
    });
  });

  group('C4. XLSX 主通道也解出图表', () {
    test('sales_tracker.xlsx → 2 个图表（bar + pie，cat/val 从 chartN.xml）', () {
      final bytes = File(
        'test/fixtures/office_sheet_o2/sales_tracker.xlsx',
      ).readAsBytesSync();
      final workbook = parseOfficeSheetXlsx(Uint8List.fromList(bytes));
      final sheet = workbook.sheets.first;
      final charts = officeSheetCharts(sheet.raw['drawing']);
      expect(charts.length, 2);
      expect(charts[0].kind, OfficeSheetChartKind.bar);
      expect(charts[0].title, 'Product Profit Per Item');
      expect(charts[0].series.single.cat, 'B8:B12');
      expect(charts[0].series.single.val, 'J8:J12');
      expect(charts[1].kind, OfficeSheetChartKind.pie);
      expect(charts[1].title, '% Income Per Product');
      expect(charts[1].series.single.val, 'K8:K12');
      // 位置来自 drawing 的 EMU（非 0）。
      expect(charts[0].width, greaterThan(0));
      expect(charts[0].height, greaterThan(0));
    });

    test('travel_expenses.xlsx → 饼图 F6:G11', () {
      final bytes = File(
        'test/fixtures/office_sheet_o2/travel_expenses.xlsx',
      ).readAsBytesSync();
      final sheet = parseOfficeSheetXlsx(
        Uint8List.fromList(bytes),
      ).sheets.first;
      final charts = officeSheetCharts(sheet.raw['drawing']);
      expect(charts.length, 1);
      expect(charts.single.kind, OfficeSheetChartKind.pie);
      expect(charts.single.series.single.cat, 'F6:F11');
      expect(charts.single.series.single.val, 'G6:G11');
    });
  });

  group('C5. 画笔真的落像素（不是空白/占位）', () {
    testWidgets('柱状图/折线图/饼图都能画出非背景像素', (tester) async {
      for (final kind in OfficeSheetChartKind.values) {
        final data = OfficeSheetChartData(
          categories: const <String>['a', 'b', 'c'],
          seriesNames: const <String>['s1'],
          values: const <List<num?>>[
            <num?>[10, 20, 30],
          ],
        );
        final painter = OfficeSheetChartPainter(
          kind: kind,
          data: data,
          title: 'T',
          colors: const <Color>[Color(0xFF1BB3A6)],
          axisColor: const Color(0xFF000000),
          gridColor: const Color(0xFFCCCCCC),
          labelStyle: const TextStyle(fontSize: 9),
          titleStyle: const TextStyle(fontSize: 11),
        );
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        const size = Size(320, 200);
        painter.paint(canvas, size);
        // `toImage` 走光栅线程：必须在 `runAsync` 里 await，否则测试异步区会挂死。
        final picture = recorder.endRecording();
        final nonWhite = await tester.runAsync(() async {
          final image = await picture.toImage(
            size.width.toInt(),
            size.height.toInt(),
          );
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(bytes, isNotNull);
          var count = 0;
          final raw = bytes!.buffer.asUint8List();
          for (var i = 0; i + 3 < raw.length; i += 4) {
            if (raw[i] != 255 || raw[i + 1] != 255 || raw[i + 2] != 255) {
              count++;
            }
          }
          image.dispose();
          return count;
        });
        expect(
          nonWhite,
          greaterThan(100),
          reason: '$kind 必须真的画出内容（当前非白像素 $nonWhite）',
        );
      }
    });
  });
}

/// 只读来源（区域解析用例用；不需要真数据）。
class _StubSource implements OfficeSheetChartDataSource {
  const _StubSource(this.values);
  final Map<String, Object?> values;

  @override
  num? numberAt(int row, int col) => null;

  @override
  String textAt(int row, int col) => '';
}
