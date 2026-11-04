// `.osheet` **图表真实绘制**（自研 `CustomPainter`；零新依赖）。
//
// 背景（O3 批次）：`sh_N.drawing[]` 里的 `chartObj` / `pos` / `displayRange`
// **早已解析到模型里**，但渲染层此前只有 `OfficeSheetChartPlaceholder` 占位卡
// （"图表内容暂不能显示"）。本文件把柱状图 / 折线图 / 饼图**真的画出来**。
//
// **取证原文**（真实 NAS `Sales tracker.osheet`，`sh_1.drawing[0]`）：
// ```json
// {"chartObj":{"barDir":"col","chartType":"bar","displayRange":"B8:B12,J8:J12",
//   "plotArea":{"series":[{"cat":"B8:B12","val":"J8:J12","type":"bar"}]},
//   "title":{"text":"Product Profit Per Item"}},
//  "pos":{"height":363,"left":88,"top":145,"width":566},"type":"chart"}
// ```
// `Travel expenses.osheet` 另有 `chartType:"pie"`（`displayRange":"F6:G11"`）。
//
// 数据映射规则：
//   * `plotArea.series[]` 优先：每条的 `cat` 是分类轴、`val` 是数值轴（按位置配对）；
//   * 没有 `series[]` 时退回 `displayRange`：按 `,` 拆分，**第一段为分类、其余各段
//     各成一条系列**（`B8:B12,J8:J12` → cat `B8:B12`、一条系列 `J8:J12`）；
//   * 分类标签取单元格**显示文本**；数值取**公式求值后**的数字
//     （`Travel expenses` 的饼图 G6:G11 全是 `=H6/$C$9`，必须求值才能画）。
//   * 数据为空 / 类型不支持 / 区域解析失败 → **退回既有占位卡**（绝不空白、绝不崩）。
//
// 支持类型：`bar`/`column`（`barDir=col` 竖柱；`barDir=bar` 横条）、`line`、`pie`。
// ⚠️ 夹具里**没有 line 的真样本**（只有 bar / pie），line 是依据 schema 的
//    **防御性实现**（见报告）。

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/i18n/data_text.dart';
import '../../data/office_native/office_json.dart';
import '../../data/office_native/osheet_formula.dart';

// ---------------------------------------------------------------------------
// 模型
// ---------------------------------------------------------------------------

/// 图表类型。
enum OfficeSheetChartKind { bar, line, pie }

/// 一条系列：分类轴区域 + 数值轴区域。
class OfficeSheetChartSeries {
  const OfficeSheetChartSeries({
    required this.cat,
    required this.val,
    this.kind,
    this.name,
  });

  /// 分类轴区域文本（如 `B8:B12`）。
  final String cat;

  /// 数值轴区域文本（如 `J8:J12`）。
  final String val;

  /// 该系列自身的类型（`plotArea.series[].type`）。
  final OfficeSheetChartKind? kind;

  final String? name;

  @override
  String toString() => 'OfficeSheetChartSeries($cat,$val,$kind,$name)';
}

/// 一个可绘制的图表（或"类型不支持"的图表 —— [kind] 为 `null`）。
class OfficeSheetChart {
  const OfficeSheetChart({
    required this.id,
    required this.title,
    required this.kind,
    required this.chartTypeRaw,
    required this.barDir,
    required this.horizontal,
    required this.displayRange,
    required this.series,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String? id;
  final String title;

  /// `null` = 类型不支持（退回占位卡）。
  final OfficeSheetChartKind? kind;

  /// 原始 `chartType`（诊断用）。
  final String? chartTypeRaw;

  /// 原始 `barDir`（`col` / `bar`）。
  final String? barDir;

  /// `barDir == "bar"` → 横向条形图。
  final bool horizontal;

  final String? displayRange;
  final List<OfficeSheetChartSeries> series;

  final double left;
  final double top;
  final double width;
  final double height;

  /// 类型支持 + 至少一条系列 + 所有区域都能解析 → 可真实绘制。
  bool get isRenderable {
    if (kind == null || series.isEmpty) return false;
    for (final s in series) {
      if (oSheetParseRange(s.val) == null) return false;
      if (oSheetParseRange(s.cat) == null) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'OfficeSheetChart($id, kind=$kind, title=$title, '
      'series=${series.length}, pos=$left,$top,$width,$height)';
}

/// 把 `sh_N.drawing` 解析成图表列表（坏项丢弃，不崩）。
List<OfficeSheetChart> officeSheetCharts(Object? rawDrawing) {
  final list = asJsonList(rawDrawing);
  if (list == null) return const <OfficeSheetChart>[];
  final out = <OfficeSheetChart>[];
  for (final entry in list) {
    final map = asJsonMap(entry);
    if (map == null) continue;
    final pos = asJsonMap(map['pos']);
    final chart = asJsonMap(map['chartObj']);
    final width = asJsonDouble(pos?['width']) ?? 0;
    final height = asJsonDouble(pos?['height']) ?? 0;
    if (width <= 0 || height <= 0) continue;
    final chartType = asJsonString(chart?['chartType']);
    final kind = officeSheetChartKindOf(chartType);
    final barDir = asJsonString(chart?['barDir']);
    final displayRange = asJsonString(chart?['displayRange']);
    final series = _parseSeries(chart, displayRange, kind);
    out.add(
      OfficeSheetChart(
        id: asJsonString(map['id']),
        title: asJsonString(asJsonMap(chart?['title'])?['text']) ?? '',
        kind: kind,
        chartTypeRaw: chartType,
        barDir: barDir,
        horizontal: kind == OfficeSheetChartKind.bar && barDir == 'bar',
        displayRange: displayRange,
        series: series,
        left: asJsonDouble(pos?['left']) ?? 0,
        top: asJsonDouble(pos?['top']) ?? 0,
        width: width,
        height: height,
      ),
    );
  }
  return out;
}

/// `chartType` → 枚举；未知 → `null`（退回占位卡）。
OfficeSheetChartKind? officeSheetChartKindOf(String? chartType) {
  switch ((chartType ?? '').trim().toLowerCase()) {
    case 'bar':
    case 'column':
    case 'col':
      return OfficeSheetChartKind.bar;
    case 'line':
      return OfficeSheetChartKind.line;
    case 'pie':
    case 'doughnut':
    case 'donut':
      return OfficeSheetChartKind.pie;
    default:
      return null;
  }
}

List<OfficeSheetChartSeries> _parseSeries(
  Map<String, Object?>? chart,
  String? displayRange,
  OfficeSheetChartKind? fallbackKind,
) {
  final out = <OfficeSheetChartSeries>[];
  final plotArea = asJsonMap(chart?['plotArea']);
  final rawSeries = asJsonList(plotArea?['series']);
  if (rawSeries != null) {
    for (final raw in rawSeries) {
      final map = asJsonMap(raw);
      if (map == null) continue;
      final cat = asJsonString(map['cat']);
      final val = asJsonString(map['val']);
      if (cat == null || val == null) continue;
      out.add(
        OfficeSheetChartSeries(
          cat: cat,
          val: val,
          kind: officeSheetChartKindOf(asJsonString(map['type'])) ?? fallbackKind,
          name: asJsonString(map['name']) ??
              asJsonString(asJsonMap(map['title'])?['text']),
        ),
      );
    }
    if (out.isNotEmpty) return out;
  }
  // 退回 `displayRange`：`B8:B12,J8:J12` → 第一段分类、其余各段一条系列。
  if (displayRange == null) return out;
  final parts = displayRange
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
  if (parts.length < 2) return out;
  for (final val in parts.skip(1)) {
    out.add(
      OfficeSheetChartSeries(cat: parts.first, val: val, kind: fallbackKind),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// 数据解析
// ---------------------------------------------------------------------------

/// 图表取值来源（分类标签文本 + 数值）。
abstract class OfficeSheetChartDataSource {
  String textAt(int row, int col);
  num? numberAt(int row, int col);
}

/// 基于 [OSheetFormulaEngine] 的来源（公式**求值后**的数字）。
class OfficeSheetEngineDataSource implements OfficeSheetChartDataSource {
  OfficeSheetEngineDataSource(this.engine);

  final OSheetFormulaEngine engine;

  @override
  String textAt(int row, int col) => engine.textAt(row, col) ?? '';

  @override
  num? numberAt(int row, int col) => engine.numberAt(row, col);
}

/// 解析好的图表数据：分类标签 + 每条系列的值（`null`=该分类缺值）。
class OfficeSheetChartData {
  const OfficeSheetChartData({
    required this.categories,
    required this.seriesNames,
    required this.values,
  });

  final List<String> categories;
  final List<String> seriesNames;

  /// `values[seriesIndex][categoryIndex]`。
  final List<List<num?>> values;

  /// 至少一个数值 → 可绘制。
  bool get isEmpty {
    if (categories.isEmpty) return true;
    for (final row in values) {
      for (final v in row) {
        if (v != null) return false;
      }
    }
    return true;
  }

  /// 全部数值（含 `null`），供刻度计算。
  List<num?> get allValues => <num?>[for (final row in values) ...row];

  @override
  String toString() =>
      'OfficeSheetChartData(cats=${categories.length}, '
      'series=${values.length}, $categories)';
}

/// 按 `series[].cat/val` 逐格配对，产出可绘制数据。
///
/// 区域解析失败 → 返回 `null`（调用方退回占位卡）。
OfficeSheetChartData? officeSheetChartData(
  OfficeSheetChart chart,
  OfficeSheetChartDataSource source,
) {
  final categories = <String>[];
  final names = <String>[];
  final values = <List<num?>>[];
  for (var i = 0; i < chart.series.length; i++) {
    final series = chart.series[i];
    final catRange = oSheetParseRange(series.cat);
    final valRange = oSheetParseRange(series.val);
    if (catRange == null || valRange == null) return null;
    final catCells = oSheetExpandRange(catRange, maxCells: 4096);
    final valCells = oSheetExpandRange(valRange, maxCells: 4096);
    final count = math.min(catCells.length, valCells.length);
    final row = <num?>[];
    for (var k = 0; k < count; k++) {
      if (i == 0) {
        categories.add(source.textAt(catCells[k].row, catCells[k].col));
      }
      row.add(source.numberAt(valCells[k].row, valCells[k].col));
    }
    names.add(series.name ?? '');
    values.add(row);
  }
  if (values.isEmpty || categories.isEmpty) return null;
  // 系列长度对齐到分类数（缺的补 null）。
  final aligned = <List<num?>>[
    for (final row in values)
      List<num?>.generate(
        categories.length,
        (i) => i < row.length ? row[i] : null,
        growable: false,
      ),
  ];
  return OfficeSheetChartData(
    categories: categories,
    seriesNames: names,
    values: aligned,
  );
}

// ---------------------------------------------------------------------------
// 几何（纯函数，可单测）
// ---------------------------------------------------------------------------

/// 数值轴刻度。
class OfficeSheetAxis {
  const OfficeSheetAxis({required this.min, required this.max, required this.ticks});

  final double min;
  final double max;
  final List<double> ticks;

  double get span => max - min;

  @override
  String toString() => 'OfficeSheetAxis($min..$max, $ticks)';
}

/// 由数值集合算数值轴：包含 0，向上取"好看"的刻度。
OfficeSheetAxis officeSheetComputeAxis(List<num?> values, {int tickCount = 4}) {
  var min = 0.0;
  var max = 0.0;
  var sawValue = false;
  for (final v in values) {
    if (v == null) continue;
    final d = v.toDouble();
    if (d.isNaN || d.isInfinite) continue;
    if (!sawValue) {
      min = d;
      max = d;
      sawValue = true;
    } else {
      if (d < min) min = d;
      if (d > max) max = d;
    }
  }
  if (!sawValue) return const OfficeSheetAxis(min: 0, max: 1, ticks: <double>[0, 1]);
  // 轴必须含 0（柱状图基线）。
  if (min > 0) min = 0;
  if (max < 0) max = 0;
  if (max == min) max = min + 1;
  final step = _niceStep((max - min) / math.max(1, tickCount));
  final niceMin = (min / step).floorToDouble() * step;
  final niceMax = (max / step).ceilToDouble() * step;
  final ticks = <double>[];
  for (var t = niceMin; t <= niceMax + step / 2; t += step) {
    ticks.add(_cleanDouble(t));
  }
  return OfficeSheetAxis(
    min: _cleanDouble(niceMin),
    max: _cleanDouble(niceMax),
    ticks: ticks,
  );
}

double _niceStep(double raw) {
  if (raw <= 0 || raw.isNaN || raw.isInfinite) return 1;
  final exponent = (math.log(raw) / math.ln10).floor();
  final magnitude = math.pow(10, exponent).toDouble();
  final normalized = raw / magnitude;
  double nice;
  if (normalized <= 1) {
    nice = 1;
  } else if (normalized <= 2) {
    nice = 2;
  } else if (normalized <= 5) {
    nice = 5;
  } else {
    nice = 10;
  }
  return nice * magnitude;
}

double _cleanDouble(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e12) {
    return value.roundToDouble();
  }
  return value;
}

/// 数值 → 绘图区里的 Y 坐标（`top` 是绘图区上边）。
double officeSheetValueToY(double value, OfficeSheetAxis axis, Rect plot) {
  if (axis.span == 0) return plot.bottom;
  final ratio = (value - axis.min) / axis.span;
  return plot.bottom - ratio * plot.height;
}

/// 柱状图：每个（系列, 分类）一个矩形；组间距 / 条间距与 Excel 默认接近。
///
/// 返回 `rects[seriesIndex][categoryIndex]`（横向条形图时矩形同样有效，
/// 只是宽度代表数值 —— 由 [officeSheetBarRects] 统一产出）。
List<List<Rect>> officeSheetBarRects({
  required OfficeSheetChartData data,
  required Rect plot,
  required OfficeSheetAxis axis,
  bool horizontal = false,
  double groupGap = 0.2,
  double barGap = 0.1,
}) {
  final categories = data.categories.length;
  final seriesCount = data.values.length;
  if (categories == 0 || seriesCount == 0 || axis.span == 0) {
    return const <List<Rect>>[];
  }
  final out = <List<Rect>>[
    for (var s = 0; s < seriesCount; s++) List<Rect>.filled(categories, Rect.zero),
  ];
  if (horizontal) {
    final slot = plot.height / categories;
    final groupWidth = slot * (1 - groupGap);
    final barThickness = groupWidth / seriesCount;
    for (var c = 0; c < categories; c++) {
      final top = plot.top + slot * c + (slot - groupWidth) / 2;
      for (var s = 0; s < seriesCount; s++) {
        final value = data.values[s][c] ?? 0;
        final x = officeSheetValueToX(value.toDouble(), axis, plot);
        final baseX = officeSheetValueToX(
          value < 0 ? 0 : 0,
          axis,
          plot,
        );
        final left = math.min(x, baseX);
        final width = (x - baseX).abs();
        out[s][c] = Rect.fromLTWH(
          left,
          top + barThickness * s + barThickness * barGap / 2,
          width,
          barThickness * (1 - barGap),
        );
      }
    }
    return out;
  }
  final slot = plot.width / categories;
  final groupWidth = slot * (1 - groupGap);
  final barThickness = groupWidth / seriesCount;
  for (var c = 0; c < categories; c++) {
    final left = plot.left + slot * c + (slot - groupWidth) / 2;
    for (var s = 0; s < seriesCount; s++) {
      final value = data.values[s][c] ?? 0;
      final y = officeSheetValueToY(value.toDouble(), axis, plot);
      final baseY = officeSheetValueToY(0, axis, plot);
      out[s][c] = Rect.fromLTWH(
        left + barThickness * s + barThickness * barGap / 2,
        math.min(y, baseY),
        barThickness * (1 - barGap),
        (y - baseY).abs(),
      );
    }
  }
  return out;
}

/// 数值 → 绘图区里的 X 坐标。
double officeSheetValueToX(double value, OfficeSheetAxis axis, Rect plot) {
  if (axis.span == 0) return plot.left;
  final ratio = (value - axis.min) / axis.span;
  return plot.left + ratio * plot.width;
}

/// 折线图：`points[seriesIndex][categoryIndex]`（缺值 → `null`，断开）。
List<List<Offset?>> officeSheetLinePoints({
  required OfficeSheetChartData data,
  required Rect plot,
  required OfficeSheetAxis axis,
}) {
  final categories = data.categories.length;
  if (categories == 0 || axis.span == 0) return const <List<Offset?>>[];
  final step = categories == 1 ? 0.0 : plot.width / (categories - 1);
  return <List<Offset?>>[
    for (final row in data.values)
      <Offset?>[
        for (var c = 0; c < categories; c++)
          if (c < row.length && row[c] != null)
            Offset(
              plot.left + step * c,
              officeSheetValueToY(row[c]!.toDouble(), axis, plot),
            )
          else
            null,
      ],
  ];
}

/// 饼图扇形：从 `-π/2`（12 点方向）开始**顺时针**。
///
/// 返回 `(start, sweep)` 弧度对；只统计正值（Excel 饼图忽略负值/缺值）；
/// 全 0 / 全空 → 空列表（调用方退回占位卡）。
List<({double start, double sweep})> officeSheetPieSectors(
  List<num?> values,
) {
  var total = 0.0;
  for (final v in values) {
    if (v == null) continue;
    final d = v.toDouble();
    if (d.isNaN || d.isInfinite || d <= 0) continue;
    total += d;
  }
  if (total <= 0) return const <({double start, double sweep})>[];
  final out = <({double start, double sweep})>[];
  var angle = -math.pi / 2;
  for (final v in values) {
    if (v == null) continue;
    final d = v.toDouble();
    if (d.isNaN || d.isInfinite || d <= 0) continue;
    final sweep = d / total * 2 * math.pi;
    out.add((start: angle, sweep: sweep));
    angle += sweep;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 画笔
// ---------------------------------------------------------------------------

/// 自研 [CustomPainter]：画标题、坐标轴/刻度、分类标签、柱/线/饼、图例。
class OfficeSheetChartPainter extends CustomPainter {
  OfficeSheetChartPainter({
    required this.kind,
    required this.data,
    required this.title,
    required this.colors,
    required this.axisColor,
    required this.gridColor,
    required this.labelStyle,
    required this.titleStyle,
    this.horizontal = false,
  });

  final OfficeSheetChartKind kind;
  final OfficeSheetChartData data;
  final String title;
  final List<Color> colors;
  final Color axisColor;
  final Color gridColor;
  final TextStyle labelStyle;
  final TextStyle titleStyle;
  final bool horizontal;

  static const double _padding = 8;
  static const double _titleHeight = 20;
  static const double _labelBand = 18;
  static const double _axisBand = 34;
  static const double _legendBand = 16;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xFFFFFFFF);
    canvas.drawRect(Offset.zero & size, background);
    if (size.width <= 1 || size.height <= 1) return;

    var top = _padding;
    if (title.isNotEmpty) {
      _paintText(
        canvas,
        title,
        Rect.fromLTWH(_padding, top, size.width - 2 * _padding, _titleHeight),
        titleStyle,
        align: TextAlign.center,
      );
      top += _titleHeight;
    }
    final legendHeight = data.values.length > 1 ? _legendBand : 0.0;
    switch (kind) {
      case OfficeSheetChartKind.pie:
        _paintPie(canvas, size, top, legendHeight);
      case OfficeSheetChartKind.bar:
        _paintCartesian(canvas, size, top, legendHeight, isLine: false);
      case OfficeSheetChartKind.line:
        _paintCartesian(canvas, size, top, legendHeight, isLine: true);
    }
  }

  void _paintCartesian(
    Canvas canvas,
    Size size,
    double top,
    double legendHeight, {
    required bool isLine,
  }) {
    final plot = Rect.fromLTRB(
      _padding + _axisBand,
      top + _padding,
      size.width - _padding,
      size.height - _padding - _labelBand - legendHeight,
    );
    if (plot.width <= 4 || plot.height <= 4) return;
    final axis = officeSheetComputeAxis(data.allValues);
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (final tick in axis.ticks) {
      final y = officeSheetValueToY(tick, axis, plot);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _paintText(
        canvas,
        _tickLabel(tick),
        Rect.fromLTWH(_padding, y - 7, _axisBand - 2, 14),
        labelStyle,
        align: TextAlign.right,
      );
    }
    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    canvas.drawLine(plot.bottomLeft, plot.topLeft, axisPaint);
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, axisPaint);

    // 分类标签（隔一个画，避免拥挤）。
    if (horizontal) {
      final slot = plot.height / math.max(1, data.categories.length);
      final step = _labelStride(slot);
      for (var c = 0; c < data.categories.length; c++) {
        if (c % step != 0) continue;
        _paintText(
          canvas,
          data.categories[c],
          Rect.fromLTWH(_padding + _axisBand, plot.top + slot * c, plot.width, 14),
          labelStyle,
          align: TextAlign.left,
        );
      }
    } else {
      final slot = plot.width / math.max(1, data.categories.length);
      final step = _labelStride(slot);
      for (var c = 0; c < data.categories.length; c++) {
        if (c % step != 0) continue;
        _paintText(
          canvas,
          data.categories[c],
          Rect.fromLTWH(plot.left + slot * c, plot.bottom + 2, slot, 14),
          labelStyle,
          align: TextAlign.center,
        );
      }
    }

    if (isLine) {
      final points = officeSheetLinePoints(data: data, plot: plot, axis: axis);
      for (var s = 0; s < points.length; s++) {
        final paint = Paint()
          ..color = _colorAt(s)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        final dot = Paint()..color = _colorAt(s);
        Offset? previous;
        for (final point in points[s]) {
          if (point == null) {
            previous = null;
            continue;
          }
          if (previous != null) canvas.drawLine(previous, point, paint);
          canvas.drawCircle(point, 2, dot);
          previous = point;
        }
      }
    } else {
      final rects = officeSheetBarRects(
        data: data,
        plot: plot,
        axis: axis,
        horizontal: horizontal,
      );
      for (var s = 0; s < rects.length; s++) {
        for (var c = 0; c < rects[s].length; c++) {
          final rect = rects[s][c];
          if (rect.width <= 0 && rect.height <= 0) continue;
          canvas.drawRect(rect, Paint()..color = _colorAt(s));
        }
      }
    }
    if (legendHeight > 0) _paintLegend(canvas, size, size.height - legendHeight);
  }

  void _paintPie(Canvas canvas, Size size, double top, double legendHeight) {
    final legend = data.values.length > 1 ? legendHeight : 0.0;
    final area = Rect.fromLTWH(
      _padding,
      top + _padding,
      size.width - 2 * _padding,
      size.height - top - 2 * _padding - legend,
    );
    if (area.width <= 4 || area.height <= 4) return;
    final values = data.values.isEmpty ? const <num?>[] : data.values.first;
    final sectors = officeSheetPieSectors(values);
    if (sectors.isEmpty) return;
    final radius = math.min(area.width, area.height) / 2;
    final center = area.center;
    final rect = Rect.fromCircle(center: center, radius: radius);
    for (var i = 0; i < sectors.length; i++) {
      final sector = sectors[i];
      canvas.drawArc(
        rect,
        sector.start,
        sector.sweep,
        true,
        Paint()..color = _colorAt(i),
      );
    }
    // 圆心留白（环形观感）+ 外描边。
    canvas.drawCircle(center, radius * 0.001, Paint()..color = axisColor);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = axisColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    if (legend > 0) _paintLegend(canvas, size, size.height - legend);
  }

  void _paintLegend(Canvas canvas, Size size, double top) {
    var x = _padding;
    for (var s = 0; s < data.values.length; s++) {
      final name = s < data.seriesNames.length && data.seriesNames[s].isNotEmpty
          ? data.seriesNames[s]
          : dataText('officeSheetChartSeries', '系列 ${s + 1}')
              .replaceAll('{n}', '${s + 1}');
      final swatch = Rect.fromLTWH(x, top + 4, 8, 8);
      canvas.drawRect(swatch, Paint()..color = _colorAt(s));
      final painter = TextPainter(
        text: TextSpan(text: name, style: labelStyle),
        textDirection: ui.TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 90);
      painter.paint(canvas, Offset(x + 11, top + 1));
      x += 11 + painter.width + 10;
      if (x > size.width - 20) break;
    }
  }

  Color _colorAt(int index) =>
      colors.isEmpty ? axisColor : colors[index % colors.length];

  static int _labelStride(double slot) {
    if (slot >= 34) return 1;
    if (slot >= 18) return 2;
    return 4;
  }

  static String _tickLabel(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e12) {
      return value.round().toString();
    }
    return value.toStringAsFixed(2);
  }

  void _paintText(
    Canvas canvas,
    String text,
    Rect rect,
    TextStyle style, {
    TextAlign align = TextAlign.left,
  }) {
    if (text.isEmpty || rect.width <= 0) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style.copyWith(color: style.color)),
      textAlign: align,
      textDirection: ui.TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: rect.width);
    painter.paint(
      canvas,
      Offset(
        rect.left,
        rect.top + (rect.height - painter.height) / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant OfficeSheetChartPainter oldDelegate) =>
      oldDelegate.kind != kind ||
      !identical(oldDelegate.data, data) ||
      oldDelegate.horizontal != horizontal ||
      oldDelegate.title != title ||
      oldDelegate.colors != colors;
}

/// 图表控件：真实绘制 [data]；`data == null || data.isEmpty` → `null`
/// （调用方退回占位卡）。
class OfficeSheetChartView extends StatelessWidget {
  const OfficeSheetChartView({
    super.key,
    required this.chart,
    required this.data,
  });

  final OfficeSheetChart chart;
  final OfficeSheetChartData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = <Color>[
      scheme.primary,
      scheme.tertiary,
      scheme.secondary,
      const Color(0xFF4C8DFF),
      const Color(0xFFFF8A3D),
      const Color(0xFF8E6BFF),
    ];
    return SizedBox.expand(
      child: CustomPaint(
        key: Key('office-sheet-chart-paint-${chart.id ?? chart.title}'),
        painter: OfficeSheetChartPainter(
          kind: chart.kind ?? OfficeSheetChartKind.bar,
          data: data,
          title: chart.title,
          colors: colors,
          axisColor: scheme.outline,
          gridColor: scheme.outlineVariant,
          labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 9,
              ) ??
              const TextStyle(fontSize: 9),
          titleStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: 11,
              ) ??
              const TextStyle(fontSize: 11),
          horizontal: chart.horizontal,
        ),
      ),
    );
  }
}
