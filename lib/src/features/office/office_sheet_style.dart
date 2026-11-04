// Office 批 D —— `.osheet` 的**样式 / 合并 / 条件格式**解析（纯函数，不碰 UI）。
//
// 本文件只做"把共享样式表解引用成可渲染的样式"，不做任何"猜测计算"：
//   * 公式（`v` 以 `=` 开头、`cfs.f1`）**原样当文本**，绝不求值；
//   * 数字格式（`numberFormats[].fc`）**只解引用 + 登记**，**不重排数值**
//     （见 [OfficeSheetResolvedStyle.numberFormat] 的注释：`s` 到 `fc` 的归属
//     在真实样本上不成立，重排会把 "NO." 列误显示成日期）。
//
// 样式表槽位（服务端束原文 `@ss/core.js` 的 `CellStyle.toJSON()`）：
//
//   `[refCount, fontId, fillId, alignmentId, borderId, nfId, +!!quotePrefix]`
//
// 服务端每个池 `toJSON()` **丢掉下标 0（默认样式）**，所以 `id` 是 **1 基**：
// `fonts[fontId-1]` / `fills[fillId-1]` / `alignments[alignmentId-1]` /
// `borders[borderId-1]` / `numberFormats[nfId-1]`。这与既有
// `office_sheet_view.dart` 文件头、`osheet_model.dart`（推断）以及 13 份官方模板
// 样本的零越界交叉验证一致。
//
// 颜色形态（真实样本逐字）：
//   * `fonts[].c` / `fills[].bg` 是 **裸 hex**（`ffffff`，**无 `#`**）；
//   * `borders[].b`（`[top,right,bottom,left]`）里的颜色**带 `#`**（`#1bb3a6`）；
//   * 允许空串 / `null` → 表示"无该样式"，**不编默认值**。
import 'package:flutter/material.dart';

import '../../data/office_native/office_json.dart';
import '../../data/office_native/osheet_model.dart';

/// `styles[i]` 的子表槽位（服务端 `CellStyle.toJSON()` 顺序）。
const int kOfficeSheetSlotFont = 1;
const int kOfficeSheetSlotFill = 2;
const int kOfficeSheetSlotAlignment = 3;
const int kOfficeSheetSlotBorder = 4;
const int kOfficeSheetSlotNumberFormat = 5;

/// 解析裸 hex / `#rrggbb` 颜色；空串 / `null` / 非 6/8 位 → `null`（不猜）。
///
/// 支持：`ffffff`（裸 hex，真实样本主流）、`#1bb3a6`（边框带 `#`）、
/// `RRGGBBAA`/`#AARRGGBB`（8 位，**未在本批样本出现**，按 AARRGGBB 解释并登记）。
Color? officeSheetParseColor(Object? raw) {
  if (raw is! String) return null;
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('#')) s = s.substring(1);
  if (s.startsWith('0x') || s.startsWith('0X')) s = s.substring(2);
  if (s.length == 6) {
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }
  if (s.length == 8) {
    // 8 位在真实样本里没有出现；按 AARRGGBB 解释（登记为未取证）。
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : Color(v);
  }
  return null;
}

/// `styles[i]` 的整数槽位；长度 < 6 或非整数项 → `null`。
List<int>? officeSheetStyleSlots(Object? entry) {
  final list = asJsonList(entry);
  if (list == null || list.length < 6) return null;
  final out = <int>[];
  for (final v in list) {
    final n = asJsonInt(v);
    if (n == null) return null;
    out.add(n);
  }
  return out;
}

/// 解引用后的单元格样式（渲染层直接可用）。
class OfficeSheetResolvedStyle {
  const OfficeSheetResolvedStyle({
    this.fontColor,
    this.fontSize,
    this.fontFamily,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.fillColor,
    this.borderTop,
    this.borderRight,
    this.borderBottom,
    this.borderLeft,
    this.alignH,
    this.alignV,
    this.wrap = false,
    this.numberFormat,
    this.fromConditionalFormat = false,
  });

  final Color? fontColor;
  final double? fontSize;
  final String? fontFamily;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final Color? fillColor;

  /// 四边边框色（`borders[].b = [top,right,bottom,left]`）；`null` = 该边无线。
  final Color? borderTop;
  final Color? borderRight;
  final Color? borderBottom;
  final Color? borderLeft;

  /// `alignments[].h`（`left`/`center`/`right`）；`null` = 无显式水平对齐。
  final String? alignH;

  /// `alignments[].v`（`middle`/`top`/`bottom`）；`null` = 无显式垂直对齐。
  final String? alignV;

  /// `alignments[].w == "wrap"`（真实样本唯一出现过的值）。
  final bool wrap;

  /// `numberFormats[].fc` 的**原始模式串**（Excel 语法）。
  ///
  /// O2 起**真的用于渲染显示值**（[officeSheetDisplayText] / `oSheetFormatNumber`）。
  /// 批 D 曾因"`s` 到 `fc` 的归属在真实样本上不成立"而只登记不重排；O2 取证
  /// **否证**了那条理由（`to_do_list_simple` 的 `styles[8] == [60,8,0,3,0,0,0]`，
  /// `nfId == 0`；真正带 `M/d/yyyy` 的 (3,3) 是日期序列号 42668）。见
  /// `osheet_model.dart` 的“数字格式”节。
  final String? numberFormat;

  /// 本样式是否来自条件格式（`cfs`）；条件公式 `f1` **未求值**。
  final bool fromConditionalFormat;

  bool get hasFont =>
      fontColor != null ||
      fontSize != null ||
      fontFamily != null ||
      bold ||
      italic ||
      underline ||
      strike;

  bool get hasBorder =>
      borderTop != null ||
      borderRight != null ||
      borderBottom != null ||
      borderLeft != null;

  /// 是否"什么可见样式都没有"（渲染层据此短路）。
  bool get isEmpty =>
      !hasFont &&
      fillColor == null &&
      !hasBorder &&
      alignH == null &&
      alignV == null &&
      !wrap &&
      numberFormat == null;

  TextStyle toTextStyle(TextStyle? base) {
    var style = base ?? const TextStyle();
    if (fontColor != null) style = style.copyWith(color: fontColor);
    if (fontSize != null) style = style.copyWith(fontSize: fontSize);
    if (fontFamily != null) style = style.copyWith(fontFamily: fontFamily);
    if (bold) style = style.copyWith(fontWeight: FontWeight.bold);
    if (italic) style = style.copyWith(fontStyle: FontStyle.italic);
    if (underline || strike) {
      style = style.copyWith(
        decoration: TextDecoration.combine(<TextDecoration>[
          if (underline) TextDecoration.underline,
          if (strike) TextDecoration.lineThrough,
        ]),
      );
    }
    return style;
  }

  BoxBorder? toBoxBorder() {
    if (!hasBorder) return null;
    BorderSide side(Color? c) =>
        c == null ? BorderSide.none : BorderSide(color: c, width: 1);
    return Border(
      top: side(borderTop),
      right: side(borderRight),
      bottom: side(borderBottom),
      left: side(borderLeft),
    );
  }

  OfficeSheetResolvedStyle mergeConditional(Map<String, Object?> cfStyle) {
    final color = officeSheetParseColor(cfStyle['color']);
    final bg = officeSheetParseColor(cfStyle['bgColor']);
    return OfficeSheetResolvedStyle(
      fontColor: color ?? fontColor,
      fontSize: fontSize,
      fontFamily: fontFamily,
      bold: bold,
      italic: italic,
      underline: underline,
      strike: strike || cfStyle['strike'] == true,
      fillColor: bg ?? fillColor,
      borderTop: borderTop,
      borderRight: borderRight,
      borderBottom: borderBottom,
      borderLeft: borderLeft,
      alignH: alignH,
      alignV: alignV,
      wrap: wrap,
      numberFormat: numberFormat,
      fromConditionalFormat: true,
    );
  }
}

/// 解引用共享样式表里的 [styleId]；`null`/越界/池缺失 → 空样式（不崩）。
///
/// O2 起**单一解引用路径**：槽位解析在模型层
/// （`OSheetStylePool.resolveStyle`，纯 Dart、离线可测），这里只把原始 hex
/// 串转成 Flutter `Color` 并保留原有的值域校验，避免两份实现漂移。
OfficeSheetResolvedStyle officeSheetResolveStyle({
  required OSheetStylePool? pool,
  required int? styleId,
}) {
  if (pool == null || styleId == null || styleId <= 0) {
    return const OfficeSheetResolvedStyle();
  }
  final raw = pool.resolveStyle(styleId);
  if (raw.isEmpty) return const OfficeSheetResolvedStyle();

  final family = raw.fontFamily?.trim();

  // 对齐：只接受已取证的取值域（其余原样丢弃，不猜）。
  final alignH =
      (raw.alignH == 'left' || raw.alignH == 'center' || raw.alignH == 'right')
      ? raw.alignH
      : null;
  final alignV =
      (raw.alignV == 'middle' ||
          raw.alignV == 'top' ||
          raw.alignV == 'bottom')
      ? raw.alignV
      : null;

  return OfficeSheetResolvedStyle(
    fontColor: officeSheetParseColor(raw.fontColorHex),
    fontSize: raw.fontSize,
    fontFamily: (family == null || family.isEmpty) ? null : family,
    bold: raw.bold,
    italic: raw.italic,
    underline: raw.underline,
    fillColor: officeSheetParseColor(raw.fillColorHex),
    borderTop: officeSheetParseColor(raw.borderTopHex),
    borderRight: officeSheetParseColor(raw.borderRightHex),
    borderBottom: officeSheetParseColor(raw.borderBottomHex),
    borderLeft: officeSheetParseColor(raw.borderLeftHex),
    alignH: alignH,
    alignV: alignV,
    wrap: raw.wrap,
    numberFormat: raw.numberFormat,
  );
}

/// 单元格的**显示文本**：数值按文件声明的数字格式渲染；其余原样。
///
/// [rawText] 是 `OSheetCell.text`；[value] 是原始值（公式串不套格式）。
/// 认不出的格式 → 原样返回 [rawText]，**绝不静默丢失内容**。
String officeSheetDisplayText({
  required Object? value,
  required String rawText,
  required String? numberFormat,
}) {
  if (numberFormat == null) return rawText;
  if (value is! num) return rawText;
  return oSheetFormatNumber(value, numberFormat) ?? rawText;
}

// ---------------------------------------------------------------------------
// 合并单元格：`[r1,c1,r2,c2]`（**行列区间**，与 `.odoc` 的 colspan 语义不同）
// ---------------------------------------------------------------------------

/// 一个合并区间（已归一化：`r1<=r2`、`c1<=c2`）。
class OfficeSheetMergeRegion {
  const OfficeSheetMergeRegion(this.r1, this.c1, this.r2, this.c2);

  final int r1;
  final int c1;
  final int r2;
  final int c2;

  int get rowSpan => r2 - r1 + 1;
  int get colSpan => c2 - c1 + 1;

  bool contains(int r, int c) => r >= r1 && r <= r2 && c >= c1 && c <= c2;

  bool isAnchor(int r, int c) => r == r1 && c == c1;

  /// A1 记法（如 `B2:D2`），用于报告/调试；**不是**用户可见的内部 id。
  String get a1 => '${officeSheetColumnLabel(c1)}${r1 + 1}'
      ':${officeSheetColumnLabel(c2)}${r2 + 1}';

  @override
  String toString() => 'OfficeSheetMergeRegion($a1)';

  @override
  bool operator ==(Object other) =>
      other is OfficeSheetMergeRegion &&
      other.r1 == r1 &&
      other.c1 == c1 &&
      other.r2 == r2 &&
      other.c2 == c2;

  @override
  int get hashCode => Object.hash(r1, c1, r2, c2);
}

/// 解析 `sh_N.mergeCells` → 归一化区间列表；坏数据丢弃（不崩、不猜）。
List<OfficeSheetMergeRegion> officeSheetMergeRegions(
  Object? rawMergeCells, {
  int? rowCount,
  int? colCount,
}) {
  final list = asJsonList(rawMergeCells);
  if (list == null) return const [];
  final out = <OfficeSheetMergeRegion>[];
  final seen = <String>{};
  for (final entry in list) {
    final quad = asJsonList(entry);
    if (quad == null || quad.length != 4) continue;
    final a = asJsonInt(quad[0]);
    final b = asJsonInt(quad[1]);
    final c = asJsonInt(quad[2]);
    final d = asJsonInt(quad[3]);
    if (a == null || b == null || c == null || d == null) continue;
    var r1 = a < c ? a : c;
    var r2 = a < c ? c : a;
    var c1 = b < d ? b : d;
    var c2 = b < d ? d : b;
    if (r1 < 0 || c1 < 0) continue;
    if (rowCount != null && r1 >= rowCount) continue;
    if (colCount != null && c1 >= colCount) continue;
    if (rowCount != null && r2 >= rowCount) r2 = rowCount - 1;
    if (colCount != null && c2 >= colCount) c2 = colCount - 1;
    if (r2 < r1 || c2 < c1) continue;
    final key = '$r1:$c1:$r2:$c2';
    if (!seen.add(key)) continue;
    out.add(OfficeSheetMergeRegion(r1, c1, r2, c2));
  }
  return out;
}

/// 合并索引：给定坐标查"它属于哪个合并区间 / 是不是被覆盖"。
class OfficeSheetMergeIndex {
  OfficeSheetMergeIndex(this.regions);

  final List<OfficeSheetMergeRegion> regions;

  /// 命中所在区间（含被覆盖格）；不在任何区间 → `null`。
  OfficeSheetMergeRegion? regionAt(int r, int c) {
    for (final region in regions) {
      if (region.contains(r, c)) return region;
    }
    return null;
  }

  /// 是不是合并区的**左上锚点**（要画成一个大格）。
  OfficeSheetMergeRegion? anchorAt(int r, int c) {
    for (final region in regions) {
      if (region.isAnchor(r, c)) return region;
    }
    return null;
  }

  /// 是否被合并区覆盖但**不是**锚点（渲染层跳过，避免画出重复的小格）。
  bool isCovered(int r, int c) {
    for (final region in regions) {
      if (region.contains(r, c) && !region.isAnchor(r, c)) return true;
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// A1 区间（条件格式 `ranges`）
// ---------------------------------------------------------------------------

/// A1 记法的单元格区间（`B4:E33` / `C30`），0 基行列。
class OfficeSheetRange {
  const OfficeSheetRange(this.r1, this.c1, this.r2, this.c2);

  final int r1;
  final int c1;
  final int r2;
  final int c2;

  bool contains(int r, int c) => r >= r1 && r <= r2 && c >= c1 && c <= c2;

  @override
  String toString() => 'OfficeSheetRange($r1,$c1-$r2,$c2)';
}

/// 列标题字母（`A`…`Z`、`AA`…），与 [officeSheetColumnIndex] 互逆。
///
/// 来源：`@ss/core` 导出的 `coordToLabel`（`office-collab-schema-export.md` §C.1）。
String officeSheetColumnLabel(int colIndex) {
  var n = colIndex + 1;
  var out = '';
  while (n > 0) {
    n -= 1;
    out = String.fromCharCode(65 + (n % 26)) + out;
    n ~/= 26;
  }
  return out;
}

/// `A`→0、`AA`→26（与 [officeSheetColumnLabel] 互逆）。
int? officeSheetColumnIndex(String letters) {
  if (letters.isEmpty) return null;
  var n = 0;
  for (final ch in letters.toUpperCase().codeUnits) {
    if (ch < 65 || ch > 90) return null;
    n = n * 26 + (ch - 64);
  }
  return n - 1;
}

/// 解析 `"B4:E33"` / `"C30"`；非法/绝对引用 `$` 去掉后仍非法 → `null`。
OfficeSheetRange? parseOfficeSheetRange(String raw) {
  final s = raw.replaceAll(r'$', '').trim().toUpperCase();
  if (s.isEmpty) return null;
  final match = RegExp(r'^([A-Z]+)(\d+)(?::([A-Z]+)(\d+))?$').firstMatch(s);
  if (match == null) return null;
  final c1 = officeSheetColumnIndex(match.group(1)!);
  final r1 = int.tryParse(match.group(2)!);
  final c2 = match.group(3) == null
      ? c1
      : officeSheetColumnIndex(match.group(3)!);
  final r2 = match.group(4) == null ? r1 : int.tryParse(match.group(4)!);
  if (c1 == null || r1 == null || c2 == null || r2 == null) return null;
  return OfficeSheetRange(
    r1 - 1 < r2 - 1 ? r1 - 1 : r2 - 1,
    c1 < c2 ? c1 : c2,
    r1 - 1 < r2 - 1 ? r2 - 1 : r1 - 1,
    c1 < c2 ? c2 : c1,
  );
}

List<OfficeSheetRange> parseOfficeSheetRanges(Object? raw) {
  final list = asJsonList(raw);
  if (list == null) return const [];
  final out = <OfficeSheetRange>[];
  for (final e in list) {
    final s = asJsonString(e);
    if (s == null) continue;
    final range = parseOfficeSheetRange(s);
    if (range != null) out.add(range);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 条件格式（`cfs`）
// ---------------------------------------------------------------------------

/// 一条条件格式（`cfs[]`）。`f1` 是**公式原文**，本批**不求值**。
class OfficeSheetConditionalFormat {
  const OfficeSheetConditionalFormat({
    required this.id,
    required this.formula,
    required this.type,
    required this.op,
    required this.text,
    required this.ranges,
    required this.style,
  });

  final String? id;

  /// 条件公式原文（`not(isblank($C4))` / `isodd(row())` / `"High"` …）。
  final String? formula;

  /// `type`：`expression` / `cellIs` / `containsText` …（真实样本出现的）。
  final String? type;

  /// `op`：`equal` / `lessThan` …（`cellIs` 才有）。
  final String? op;

  /// `text`：`containsText` 的匹配串。
  final String? text;

  final List<OfficeSheetRange> ranges;

  /// 生效样式（`color` / `strike` / `bgColor`）。
  final Map<String, Object?> style;

  bool get hasStrike => style['strike'] == true;
}

/// 解析 `sh_N.cfs`；坏项丢弃（不崩）。
List<OfficeSheetConditionalFormat> officeSheetConditionalFormats(
  Object? rawCfs,
) {
  final list = asJsonList(rawCfs);
  if (list == null) return const [];
  final out = <OfficeSheetConditionalFormat>[];
  for (final entry in list) {
    final map = asJsonMap(entry);
    if (map == null) continue;
    out.add(
      OfficeSheetConditionalFormat(
        id: asJsonString(map['cfId']),
        formula: asJsonString(map['f1']),
        type: asJsonString(map['type']),
        op: asJsonString(map['op']),
        text: asJsonString(map['text']),
        ranges: parseOfficeSheetRanges(map['ranges']),
        style: asJsonMap(map['style']) ?? const <String, Object?>{},
      ),
    );
  }
  return out;
}

/// 命中 [r]/[c] 的所有条件格式（真实样本里一条范围可重叠；全部叠加）。
List<OfficeSheetConditionalFormat> officeSheetConditionalAt(
  List<OfficeSheetConditionalFormat> cfs,
  int r,
  int c,
) => <OfficeSheetConditionalFormat>[
  for (final cf in cfs)
    if (cf.ranges.any((range) => range.contains(r, c))) cf,
];

/// 给基础样式叠加命中区间的条件格式样式（`color`→字色、`bgColor`→填充、`strike`）。
OfficeSheetResolvedStyle officeSheetApplyConditionalFormats(
  OfficeSheetResolvedStyle base,
  List<OfficeSheetConditionalFormat> hits,
) {
  var out = base;
  for (final cf in hits) {
    out = out.mergeConditional(cf.style);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 图表 / 图形（`sh_N.drawing`）—— O3 起**真实绘制**在 `office_sheet_chart.dart`
// ---------------------------------------------------------------------------
//
// **取证原文**（NAS `Sales tracker.osheet`，`sh_1.drawing[0]`）：
// ```json
// {"chartObj":{"barDir":"col","chartType":"bar","displayRange":"B8:B12,J8:J12",
//   "plotArea":{"series":[{"cat":"B8:B12","val":"J8:J12","type":"bar"}],...},
//   "title":{"text":"Product Profit Per Item"}},
//  "id":"c8e98ec07208261d","pos":{"height":363,"left":88,"top":145,"width":566},
//  "type":"chart"}
// ```
// `Travel expenses.osheet` 另有一个 `chartType: "pie"`。
//
// ⚠️ O3 起渲染层走 `office_sheet_chart.dart` 的 `officeSheetCharts()` +
// `OfficeSheetChartView`（真的画柱/折线/饼）；本文件的
// [OfficeSheetChartPlaceholder] 只保留给"类型不支持 / 数据解析不出来"的
// **退回占位卡**场景，不再是主通道（保留以兼容既有 import 点）。

/// 一个 `drawing` 条目的占位信息。
class OfficeSheetChartPlaceholder {
  const OfficeSheetChartPlaceholder({
    required this.id,
    required this.title,
    required this.type,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String? id;
  final String title;

  /// `chartObj.chartType`（真实样本 `bar` / `pie`）。
  final String? type;

  final double left;
  final double top;
  final double width;
  final double height;

  @override
  String toString() =>
      'OfficeSheetChartPlaceholder($id, type=$type, title=$title, '
      'pos=$left,$top,$width,$height)';
}

/// 解析 `sh_N.drawing` → 占位卡片列表（坏项丢弃，不崩）。
List<OfficeSheetChartPlaceholder> officeSheetChartPlaceholders(
  Object? rawDrawing,
) {
  final list = asJsonList(rawDrawing);
  if (list == null) return const <OfficeSheetChartPlaceholder>[];
  final out = <OfficeSheetChartPlaceholder>[];
  for (final entry in list) {
    final map = asJsonMap(entry);
    if (map == null) continue;
    final pos = asJsonMap(map['pos']);
    final chart = asJsonMap(map['chartObj']);
    final width = asJsonDouble(pos?['width']) ?? 0;
    final height = asJsonDouble(pos?['height']) ?? 0;
    if (width <= 0 || height <= 0) continue;
    out.add(
      OfficeSheetChartPlaceholder(
        id: asJsonString(map['id']),
        title: asJsonString(asJsonMap(chart?['title'])?['text']) ?? '',
        type: asJsonString(chart?['chartType']),
        left: asJsonDouble(pos?['left']) ?? 0,
        top: asJsonDouble(pos?['top']) ?? 0,
        width: width,
        height: height,
      ),
    );
  }
  return out;
}
