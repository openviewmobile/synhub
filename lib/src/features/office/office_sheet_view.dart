// Office C′ 表格（Sheet）批 1 —— **只读、证据驱动**的 `.osheet` 渲染器。
//
// 数据来源（本批只读，不做历史回放）：
//   * 基础模型：`Sheet.Snapshot:init` 的 **`index`** section（`order` / `sheets` /
//     `schemaVersion` / `ver`）+ 每张表的 `sh_N` section。服务端 `instance.js`
//     原文就是 `this.workbookController = new WorkbookController(s.index)`，
//     即"从 index 重建"，**不重放历史命令**（`office-collab-schema-export.md`
//     §C.1）。本批用 `SYNO.Office.Snapshot:get v4` 拿到的 section 字典喂模型。
//   * 模型：**复用既有** `lib/src/data/office_native/osheet_model.dart` 的
//     `OSheetWorkbook.fromSections`（本批未改该文件）；渲染器只在其上加"证据驱动
//     的读取 + 未知项降级"，不另造一套 sheet 模型。
//
// 每个渲染字段的来源都在报告 `docs/office-sheet-ui-1.md` 的"字段 → 证据"表里，
// 关键几条：
//   * 表名 → `index.sheets["sh_N"].title`；表顺序 → `index.order`；
//   * 单元格值 → `sh_N.cells["<r>"]["<c>"].v`（string / number；`=` 开头 = 公式，
//     **本批不求值**，原样显示）；
//   * 单元格样式 id → `.s`；水平对齐 → `style.styles[s-1][3]`（alignmentId）→
//     `style.alignments[alignmentId-1].h`。
//     槽位顺序由服务端束原文确证：`CellStyle.toJSON()` 返回
//     `[this._refCount, this.fontId, this.fillId, this.alignmentId, this.borderId,
//     this.nfId, +!!this.quotePrefix]`（`@ss/core.js@676438`），且 `getStyleManager
//     .toJSON()` 对每个池 **丢掉下标 0**（默认样式）后序列化（`@ss/core.js@682964`）。
//     13 份官方模板样本交叉验证：`styles[s-1]` 的 slot1..slot5 作 `fonts/
//     fills/alignments/borders/numberFormats` 下标时**零越界**（846+56 条），
//     且 `s-1` 基址下 slot0 与真实引用计数**逐条相等**（`to_do_list_simple` 14/14）。
//   * 行高 / 列宽 → `sh_N.rows["<r>"].h` / `sh_N.cols["<c>"].w`（缺省用
//     `global.h` / `global.w`）。
//
// 降级纪律（与 `.odoc` 渲染器同构）：**不认识的 section / 字段 / 命令不许崩、
// 不许静默丢**——一律进 [OfficeSheetRenderReport]（计数 + messages），页顶给一条
// 聚合提示。未取证的（mergeCells 四元组、hidden、字体/填充/边框/数字格式）
// 都**如实登记**、不假装渲染。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/office_native/office_json.dart';
import '../../data/office_native/osheet_formula.dart';
import '../../data/office_native/osheet_model.dart';
import 'office_sheet_chart.dart';
import 'office_sheet_edit.dart';
import 'office_sheet_ooxml_color.dart';
import 'office_sheet_schema.dart';
import 'office_sheet_style.dart';
import 'office_sheet_xlsx.dart';

/// 批 D：`officeSheetColumnLabel` / `officeSheetStyleSlots` 已移入
/// `office_sheet_style.dart`；这里**再导出**，保持既有 import 点不变
/// （`office_sheet_edit.dart` 就 `show officeSheetColumnLabel`）。
export 'office_sheet_style.dart'
    show officeSheetColumnLabel, officeSheetStyleSlots;

/// 取本批新文案（key + 中文原文；清单见 `docs/office-sheet-ui-1.md` §⑩）。
String officeSheetText(String key, String zh) => dataText(key, zh);

/// 带 `{name}` / `{count}` 等占位符的文案填充。
String officeSheetFill(String key, String zh, Map<String, String> values) {
  var out = officeSheetText(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批的只读渲染报告：**所有**降级/未渲染项都在这里留痕（可被单测与日志读到）。
class OfficeSheetRenderReport {
  /// section 名不在词表/schema 导出里（未知 → 计数，不崩）。
  final Map<String, int> unknownSections = <String, int>{};

  /// section 已确证但本批不解释其内容。
  final Map<String, int> unsupportedSections = <String, int>{};

  /// section 已登记但本批有意不进网格（`define` / `comment` / `locale` …）。
  final Map<String, int> registeredOnlySections = <String, int>{};

  /// 未登记的字段：key 形如 `index.maxFoo` / `sh_1.cell.bar`。
  final Map<String, int> unknownFields = <String, int>{};

  /// 未登记的命令名（`init` ack 的 `commands[]`）。
  final Map<String, int> unknownCommands = <String, int>{};

  /// 出现过的命令名（无论认识与否）——批 1 只登记，不回放。
  final Map<String, int> seenCommands = <String, int>{};

  /// 出现过的命令名（`sheet_commands.json` 的 148 词汇集）。
  final List<String> messages = <String>[];

  /// `init` ack 带进来但**未回放**的增量命令数（本批有意不回放）。
  int commandsNotReplayed = 0;

  /// `commands[]` 里连 `cmd` 都读不出来的条目数。
  int malformedCommands = 0;

  /// 本批登记但不应用的语义项（如实计数，不静默）。
  int hiddenRows = 0;
  int hiddenCols = 0;
  int mergedRanges = 0;
  int mergedCellsRendered = 0;
  int formulaCells = 0;
  int sheetsRendered = 0;
  int cellsRendered = 0;

  /// 条件格式（`cfs`）条数 / 被套用样式的格子数。
  int conditionalFormats = 0;
  int conditionalCellsStyled = 0;

  /// **未实现**的真实内容（非空 `drawing` / 非空 `filter.range`）——如实计数。
  int unsupportedDrawingItems = 0;
  int unsupportedFilterRanges = 0;

  /// O3：**真的画出来**的图表数（bar/line/pie，有可用数据）。
  int chartsRendered = 0;

  /// O3：`drawing` 里存在但**类型不支持 / 数据解析失败** → 退回占位卡的图表数。
  int chartsPlaceholder = 0;

  /// O3：**真的求值**了的公式格数 / 无法求值（退化显示原文）的公式格数 /
  /// 命中循环引用（`#CIRC!`）的公式格数。渲染时写入。
  int formulaCellsEvaluated = 0;
  int formulaCellsFallback = 0;
  int formulaCellsCircular = 0;

  /// O3：**真的隐藏**了的隐藏行数 / 隐藏列数（渲染时写入；`hiddenRows` /
  /// `hiddenCols` 是解析期的"文件声明数"，这里是被应用的数量）。
  int hiddenRowsHidden = 0;
  int hiddenColsHidden = 0;

  /// 存在但本批不渲染的样式池（批 D 起四个池都解引用了 → 恒空；保留字段兼容）。
  final Set<String> unrenderedStyleFacets = <String>{};

  /// 批 D 起**真的解引用**了的样式池（有 `styles[]` 指向该池时登记）。
  final Set<String> resolvedStyleFacets = <String>{};

  /// 数字格式虽解引用但**不重排数值**（见 `office_sheet_style.dart` 文件头）。
  int numberFormatsResolved = 0;

  /// **O2 主通道标记**：OOXML(XLSX) 解析成功的工作表数。
  /// `0` = 本次走的是 OFile 兼容通道（此时页面会给出用户语言说明）。
  int ooxmlSheetsParsed = 0;

  /// 主通道命中时 **不写任何节流/告示**——它只是"我们读的是真版式"的事实登记。
  bool get usedOoxmlMainChannel => ooxmlSheetsParsed > 0;

  void unknownSection(String name) {
    unknownSections[name] = (unknownSections[name] ?? 0) + 1;
    messages.add('未知 section（词表/schema 导出未登记）：${officeSheetSectionKey(name)}');
  }

  void unsupportedSection(String name) {
    unsupportedSections[name] = (unsupportedSections[name] ?? 0) + 1;
    messages.add('已确证但当前不渲染的 section：${officeSheetSectionKey(name)}');
  }

  void registeredOnlySection(String name) {
    registeredOnlySections[name] = (registeredOnlySections[name] ?? 0) + 1;
    messages.add('已登记、不进网格的 section：${officeSheetSectionKey(name)}');
  }

  void unknownField(String scope, String key) {
    final k = '$scope.$key';
    unknownFields[k] = (unknownFields[k] ?? 0) + 1;
    messages.add('未知字段（未登记）：$k');
  }

  void unknownCommand(String cmd) {
    unknownCommands[cmd] = (unknownCommands[cmd] ?? 0) + 1;
    messages.add('未知命令（148 词表未登记）：$cmd');
  }

  void seenCommand(String cmd) {
    seenCommands[cmd] = (seenCommands[cmd] ?? 0) + 1;
  }

  void note(String message) => messages.add(message);

  bool get hasDegradations =>
      unknownSections.isNotEmpty ||
      unsupportedSections.isNotEmpty ||
      unknownFields.isNotEmpty ||
      unknownCommands.isNotEmpty ||
      malformedCommands > 0 ||
      unsupportedDrawingItems > 0 ||
      unsupportedFilterRanges > 0;

  int get degradationCount =>
      unknownSections.values.fold<int>(0, (a, b) => a + b) +
      unsupportedSections.values.fold<int>(0, (a, b) => a + b) +
      unknownFields.values.fold<int>(0, (a, b) => a + b) +
      unknownCommands.values.fold<int>(0, (a, b) => a + b) +
      malformedCommands +
      unsupportedDrawingItems +
      unsupportedFilterRanges;

  @override
  String toString() =>
      'OfficeSheetRenderReport(unknownSections=$unknownSections, '
      'unsupportedSections=$unsupportedSections, unknownFields=$unknownFields, '
      'unknownCommands=$unknownCommands, commandsNotReplayed=$commandsNotReplayed)';
}

/// 扫 section 字典：登记未知 / 只登记 / 未知字段。
///
/// **纯函数**（只写 report），可离线单测；不抛。
void scanOfficeSheetSections(
  Map<String, Object?> sections,
  OfficeSheetRenderReport report,
) {
  for (final entry in sections.entries) {
    final evidence = officeSheetSectionEvidence(entry.key);
    switch (evidence.support) {
      case OfficeSheetSectionSupport.rendered:
        if (isOfficeSheetWorksheetSection(entry.key)) {
          report.sheetsRendered++;
          _scanWorksheet(entry.key, entry.value, report);
        }
      case OfficeSheetSectionSupport.structural:
        report.registeredOnlySection(entry.key);
      case OfficeSheetSectionSupport.degraded:
        report.unsupportedSection(entry.key);
      case OfficeSheetSectionSupport.unknown:
        report.unknownSection(entry.key);
    }
  }

  // `index` 的键 + `index.sheets[id]` 的键。
  final index = asJsonMap(sections['index']);
  if (index != null) {
    for (final key in index.keys) {
      if (!kOfficeSheetIndexKeys.contains(key)) {
        report.unknownField('index', key);
      }
    }
    final sheets = asJsonMap(index['sheets']);
    if (sheets != null) {
      for (final sheet in sheets.values) {
        final def = asJsonMap(sheet);
        if (def == null) continue;
        for (final key in def.keys) {
          if (!kOfficeSheetIndexSheetKeys.contains(key)) {
            report.unknownField('index.sheets', key);
          }
        }
      }
    }
    final order = asJsonList(index['order']);
    if (order != null) {
      for (final id in order) {
        final name = asJsonString(id);
        if (name != null && !sections.containsKey(name)) {
          report.note(
            'index.order 引用了缺失的 section：${officeSheetSectionKey(name)}',
          );
        }
      }
    }
  }

  // `style` 的顶层键。
  final style = asJsonMap(sections['style']);
  if (style != null) {
    for (final key in style.keys) {
      if (!kOfficeSheetStyleKeys.contains(key)) {
        report.unknownField('style', key);
      }
    }
    // 批 D：四个池都**解引用**了（fonts/fills/borders/numberFormats），
    // 不再登记为 "unrendered"；只登记"桶非空"作为解引用证据。
    for (final facet in const <String>[
      'fonts',
      'fills',
      'borders',
      'numberFormats',
      'alignments',
    ]) {
      final pool = asJsonList(style[facet]);
      if (pool != null && pool.isNotEmpty) {
        report.resolvedStyleFacets.add(facet);
      }
    }
    final nf = asJsonList(style['numberFormats']);
    if (nf != null) report.numberFormatsResolved = nf.length;
  }
}

/// 工作簿级图表统计：**两条通道**（OOXML 主通道 / OFile 兼容通道）都在这里数。
///
/// 可绘制的（`bar`/`line`/`pie` 且有 `series[].cat/val`）计入 `chartsRendered`；
/// 类型不支持 / 区域解析失败 / 缺 `chartObj` → `unsupportedDrawingItems` 并留痕。
void scanOfficeSheetCharts(
  OSheetWorkbook workbook,
  OfficeSheetRenderReport report,
) {
  for (final sheet in workbook.sheets) {
    final raw = asJsonList(sheet.raw['drawing']);
    if (raw == null || raw.isEmpty) continue;
    final charts = officeSheetCharts(sheet.raw['drawing']);
    for (final chart in charts) {
      if (chart.isRenderable) {
        report.chartsRendered++;
      } else {
        report.unsupportedDrawingItems++;
        report.note(
          '${sheet.id} 的 `drawing` 有 1 项无法绘制'
          '（chartType=${chart.chartTypeRaw ?? "?"}，'
          'series=${chart.series.length}）→ 退回占位卡。',
        );
      }
    }
    final dropped = raw.length - charts.length;
    if (dropped > 0) {
      report.unsupportedDrawingItems += dropped;
      report.note('${sheet.id} 的 `drawing` 有 $dropped 项缺少 pos/chartObj，已丢弃。');
    }
  }
}

void _scanWorksheet(
  String sectionName,
  Object? raw,
  OfficeSheetRenderReport report,
) {
  final sheet = asJsonMap(raw);
  if (sheet == null) return;
  for (final key in sheet.keys) {
    if (!kOfficeSheetWorksheetKeys.contains(key)) {
      report.unknownField(sectionName, key);
    }
  }
  final rows = asJsonMap(sheet['rows']);
  if (rows != null) {
    for (final row in rows.values) {
      final def = asJsonMap(row);
      if (def == null) continue;
      for (final key in def.keys) {
        if (!kOfficeSheetRowKeys.contains(key)) {
          report.unknownField('$sectionName.rows', key);
        }
      }
      if (def['hidden'] == true) report.hiddenRows++;
    }
  }
  final cols = asJsonMap(sheet['cols']);
  if (cols != null) {
    for (final col in cols.values) {
      final def = asJsonMap(col);
      if (def == null) continue;
      for (final key in def.keys) {
        if (!kOfficeSheetColKeys.contains(key)) {
          report.unknownField('$sectionName.cols', key);
        }
      }
      if (def['hidden'] == true) report.hiddenCols++;
    }
  }
  final global = asJsonMap(sheet['global']);
  if (global != null) {
    for (final key in global.keys) {
      if (!kOfficeSheetGlobalKeys.contains(key)) {
        report.unknownField('$sectionName.global', key);
      }
    }
  }
  if (asJsonList(sheet['mergeCells'])?.isNotEmpty ?? false) {
    report.mergedRanges += asJsonList(sheet['mergeCells'])!.length;
  }
  // 批 D：合并区按 `[r1,c1,r2,c2]` 归一化后，**一个区间只画一个大格**。
  final rowCount = asJsonInt(sheet['rowCount']) ?? 0;
  final colCount = asJsonInt(sheet['colCount']) ?? 0;
  final mergeIndex = OfficeSheetMergeIndex(
    officeSheetMergeRegions(
      sheet['mergeCells'],
      rowCount: rowCount > kOfficeSheetMaxRenderRows
          ? kOfficeSheetMaxRenderRows
          : rowCount,
      colCount: colCount > kOfficeSheetMaxRenderCols
          ? kOfficeSheetMaxRenderCols
          : colCount,
    ),
  );
  report.mergedCellsRendered += mergeIndex.regions.length;
  // 批 D：条件格式登记（公式 `f1` 不求值，只如实计数）。
  final cfs = officeSheetConditionalFormats(sheet['cfs']);
  if (cfs.isNotEmpty) {
    report.conditionalFormats += cfs.length;
    final rLimit = rowCount > kOfficeSheetMaxRenderRows
        ? kOfficeSheetMaxRenderRows
        : rowCount;
    final cLimit = colCount > kOfficeSheetMaxRenderCols
        ? kOfficeSheetMaxRenderCols
        : colCount;
    for (final range in cfs.expand((cf) => cf.ranges)) {
      for (var r = range.r1; r <= range.r2 && r < rLimit; r++) {
        if (r < 0) continue;
        for (var c = range.c1; c <= range.c2 && c < cLimit; c++) {
          if (c < 0 || mergeIndex.isCovered(r, c)) continue;
          report.conditionalCellsStyled++;
        }
      }
    }
    report.note(
      '$sectionName 带 ${cfs.length} 条条件格式：按 `ranges` 套用其 '
      '`style`（color/bgColor/strike），但 `f1` 公式**不求值**（原样登记）。',
    );
    for (final cf in cfs) {
      final formula = cf.formula;
      if (formula != null && formula.trim().isNotEmpty) {
        report.messages.add('$sectionName 条件格式公式（未求值）：$formula');
      }
    }
  }
  // O3：`drawing` 的图表统计在**工作簿级**做（[scanOfficeSheetCharts]）——OOXML
  // 主通道的 `drawing` 来自 `parseOfficeSheetXlsx`，不在 section 字典里，这里数
  // 会漏；放到工作簿模型上数，两条通道一致。
  final filterRange = asJsonMap(sheet['filter'])?['range'];
  if (filterRange != null) {
    report.unsupportedFilterRanges++;
    report.note(
      '$sectionName 的 `filter.range` 非空：自动筛选**不渲染**（未取证）。',
    );
  }
  final cells = asJsonMap(sheet['cells']);
  if (cells == null) return;
  for (final row in cells.values) {
    final rowMap = asJsonMap(row);
    if (rowMap == null) continue;
    for (final cell in rowMap.values) {
      final cellMap = asJsonMap(cell);
      if (cellMap == null) continue;
      for (final key in cellMap.keys) {
        if (!kOfficeSheetCellKeys.contains(key)) {
          report.unknownField('$sectionName.cell', key);
        }
      }
      final value = cellMap['v'];
      if (value is String && value.startsWith('=')) report.formulaCells++;
      if (value != null) report.cellsRendered++;
    }
  }
}

/// 扫 `init` ack 的 `commands[]`：**只登记，不回放**（批 1 只读）。
///
/// 不认识的命令名计入 [OfficeSheetRenderReport.unknownCommands]（可见），
/// 认识的计入 `seenCommands`；两者都**不崩**。
void scanOfficeSheetCommands(
  Object? commands,
  OfficeSheetRenderReport report, {
  required String source,
}) {
  final list = asJsonList(commands);
  if (list == null || list.isEmpty) return;
  report.commandsNotReplayed += list.length;
  for (final command in list) {
    final name = officeSheetCommandNameOf(command);
    if (name == null) {
      report.malformedCommands++;
      report.messages.add('命令条目没有 cmd 字段（来源：$source）');
      continue;
    }
    report.seenCommand(name);
    if (!isOfficeSheetCommandKnown(name)) report.unknownCommand(name);
  }
  report.note(
    '$source 带 ${list.length} 条增量命令：**不回放历史命令**'
    '（基础模型从 index + sh_N 重建），命令名已全部登记。',
  );
}

// ---------------------------------------------------------------------------
// 样式槽位 / 对齐（证据见文件头；批 D 起实现在 `office_sheet_style.dart`）
// ---------------------------------------------------------------------------

/// 批 D：`officeSheetColumnLabel` / `officeSheetStyleSlots` 已移入
/// `office_sheet_style.dart`；上面 import 后已**再导出**，保持既有 import 点不变
/// （`office_sheet_edit.dart` 就 `show officeSheetColumnLabel`）。

/// 单元格的水平对齐（`left` / `center` / `right`）。
enum OfficeSheetCellAlign { left, center, right }

/// 从样式池 + 样式 id 解析水平对齐（批 D 起走完整解引用）。
///
/// 返回 `null` = 文件里**没有**显式水平对齐（调用方用显示默认值）。
String? officeSheetAlignmentH(OSheetStylePool? pool, int? styleId) =>
    officeSheetResolveStyle(pool: pool, styleId: styleId).alignH;

/// 本批显示用的对齐：文件里有显式 `h` 用它；否则**数值右对齐、文本左对齐**
/// （这是显示约定，不是文件证据，报告里如实标注）。
OfficeSheetCellAlign officeSheetCellAlign({
  required OSheetStylePool? pool,
  required int? styleId,
  required Object? value,
}) {
  switch (officeSheetAlignmentH(pool, styleId)) {
    case 'center':
      return OfficeSheetCellAlign.center;
    case 'right':
      return OfficeSheetCellAlign.right;
    case 'left':
      return OfficeSheetCellAlign.left;
  }
  return value is num ? OfficeSheetCellAlign.right : OfficeSheetCellAlign.left;
}

/// 渲染上限（真实样本最大 100 行 × 30 列；超出只画到上限并登记）。
const int kOfficeSheetMaxRenderRows = 500;
const int kOfficeSheetMaxRenderCols = 100;

/// 缩放区间（O2）。下限允许"缩到能看全宽表"，上限够看清小字号。
const double kOfficeSheetMinScale = 0.25;
const double kOfficeSheetMaxScale = 4.0;

/// 行号列 / 列标行（冻结表头）的横向/纵向尺寸（未缩放）。
const double kOfficeSheetRowHeaderWidth = 48;
const double kOfficeSheetColHeaderHeight = 26;

/// 单元格基础字号（无样式声明时的显示缺省）。
const double kOfficeSheetDefaultFontSize = 12;

/// 冻结表头的**平移条带**该取多长（行号列/列标行的"画布"长度）。
///
/// ## 为什么需要这个函数（真机 bug 的完整推导）
/// 每个平移条带被 `Positioned(top: headerH + frozenH, bottom: 0)` + `ClipRect`
/// 裁到一个窗口里，窗口长度是
/// ```
/// band = 视口 − (header + frozen)          // band 就是条带的裁剪窗口
/// ```
/// 条带自身长度记 `strip`，它被 `Transform.translate(-o)` 平移，`o` 是滚动量，
/// 且 `o` 的实际取值范围上界是
/// ```
/// oMax = (header + frozen + body) − 视口 = body − band
/// ```
/// （为负时**被钳到 0**，因为滚动视图没有可滚区间）。
///
/// 要保证任意 `o ∈ [0, oMax]` 下条带都盖住窗口，需
/// ```
/// strip ≥ band + oMax
/// ```
///
/// * **内容比视口高**（`body > band`）：`band + oMax = band + body − band = body`
///   ⇒ `strip = body` **恰好够**。这就是原来那版代码，它是对的。
/// * **内容比视口矮**（`body ≤ band`，例如"适宽"、或表本身就短）：`oMax = 0`
///   ⇒ 要求变成 `strip ≥ band`，而 `body ≤ band` ⇒ **原来的 `strip = body` 必然差一截**，
///   于是窗口下半部分**整片空白**（真机：适宽 25% 下整表都画出来了、行号却只到十几行）。
///
/// 所以正确取值是 **`max(body, band)`** —— 两个分支同时满足。
///
/// ⚠️ 之前试过 `strip = header + frozen + body`（"可滚动内容全长"），
/// 它在"内容比视口矮"时**仍然可能小于 `band`**（实测 338 < 493），
/// 所以**不是**正确的修法；A/B 又恰好没覆盖这个分支，才让我误判。
double officeSheetBandStripExtent(double body, double band) =>
    body > band ? body : (band > 0 ? band : body);

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

/// `.osheet` 网格（批 1 只读渲染；批 2 起可选**可编辑**）。
///
/// [sections] 是 `@C_text/*` 的 section 字典（`index` / `style` / `sh_N` …），
/// 直接传给既有的 [OSheetWorkbook.fromSections]。
///
/// [edit] 非空时网格进入"编辑接线"形态（照 `.odoc` 批 2 的 `OfficeDocEditHost`）：
///   * 单元格显示值：**本格有未落盘的本地乐观值**时用
///     [OfficeSheetEditController.valueAt] 的覆盖值（保持编辑手感）；
///     否则显示**文件值 / 公式求值结果 + 数字格式**（远端广播/已确认改动
///     与文件原值不同时以编辑层为准）。判据是"本格是否有本地改动"，
///     **不是**"编辑控制器是否存在"（R17 修复，见报告 §机制复核）；
///   * `edit.canEdit` 为真时，点/双击单元格把 `_cell` 换成输入组件，提交生成
///     `value` 命令（乐观显示 + 未确认队列由编辑层负责）；
///   * 未确认的格子在边框/字重上**可见标记**（不静默）。
class OfficeSheetView extends StatefulWidget {
  const OfficeSheetView({
    super.key,
    required this.sections,
    this.report,
    this.initialSheetId,
    this.edit,
    this.ooxmlBytes,
    this.workbook,
    this.initialScale,
  });

  final Map<String, Object?> sections;

  /// 页面的报告（与 `.odoc` 批同构）。不传时本 widget 自建一份并 `debugPrint`。
  final OfficeSheetRenderReport? report;

  /// 初始选中的表（测试/深链用；缺省取 `index.order` 第一张）。
  final String? initialSheetId;

  /// 编辑层（批 2）；null = 批 1 的纯只读网格，行为逐字不变。
  final OfficeSheetEditController? edit;

  /// **主通道**：服务端转码出来的 OOXML(XLSX) 字节。
  ///
  /// 有它且带 `PK\x03\x04` 头就走 [parseOfficeSheetXlsx]（真实列宽/样式/数字格式/
  /// 冻结/合并）；否则**回落** [sections]（OFile），并在网格顶部用用户语言说明。
  final Uint8List? ooxmlBytes;

  /// 已经解析好的模型（`office_viewer_page.dart` 复用本渲染器时用）。
  final OSheetWorkbook? workbook;

  /// 初始缩放比例。`null`（默认）= **打开即自适应宽**（对齐 WPS/Office 安卓版）。
  ///
  /// 传具体值用于两个场景：① 恢复用户上次的缩放；② 测试里要**确定的几何**，
  /// 不想被自适应影响。传了值就**不再自适应**。
  final double? initialScale;

  @override
  State<OfficeSheetView> createState() => _OfficeSheetViewState();
}

class _OfficeSheetViewState extends State<OfficeSheetView> {
  late OfficeSheetRenderReport _report;
  late OSheetWorkbook? _workbook;
  Object? _modelError;
  String? _sheetId;

  /// 回落到 OFile 兼容通道时给用户的说明（**只在真的回落时出现**，不是常驻横幅）。
  String? _fallbackNotice;

  /// 正在编辑的格子（批 2；null = 没有输入组件在前台）。
  int? _editRow;
  int? _editCol;
  TextEditingController? _editText;
  FocusNode? _editFocus;

  /// 选中的格子（O2：点按高亮；`null` = 无选中）。
  int? _selRow;
  int? _selCol;

  /// 缩放系数（O2）：`1.0` = 文件声明尺寸原样。行高/列宽/字号都按它缩放，
  /// 所以"适宽"与"双指缩放"用的是**同一套尺寸**，不会和滚动坐标系打架。
  double _scale = 1.0;

  /// 双指缩放的手势状态（用 `Listener` 直接数手指，**不进 gesture arena**，
  /// 这样单指滚动/拖动完全不受影响）。
  final Map<int, Offset> _pointers = <int, Offset>{};
  double? _pinchStartDistance;
  double _pinchStartScale = 1.0;

  /// 网格可视区宽度（`LayoutBuilder` 给；"适宽"用它算缩放）。
  double _viewportWidth = 0;

  /// 网格可视区高度（`LayoutBuilder` 给）。
  ///
  /// **为什么需要它**：行号列/列标行的平移条带必须**盖满自己的裁剪窗口**，
  /// 而窗口高度是 `视口高 − (headerH + frozenH)`。当**内容比视口矮**时
  /// （"适宽"、或表本身就短），滚动量为 0，条带只需 `bodyH` 高就会出现
  /// **下半截整片空白**（真机 bug：适宽 25% 下整表都画出来了，行号却只到十几行）。
  /// 详见 [officeSheetBandStripExtent] 的推导。
  double _viewportHeight = 0;

  /// 是否已经做过"**打开即自适应宽**"（每个文档只做一次）。
  bool _autoFitDone = false;

  /// 用户是否**手动**调过缩放（适宽 / ± / 双指）。
  /// 一旦调过就**永不自适应**，否则会把用户的选择抢掉。
  bool _userZoomed = false;

  /// 滚动控制器：body 的纵向/横向，冻结表头与 body 共用（保证同步）。
  final ScrollController _vController = ScrollController();
  final ScrollController _hController = ScrollController();

  OfficeSheetEditController? _boundEdit;

  /// O3：公式求值引擎**按工作表缓存**（选区/缩放触发重建时不重复求值）。
  OSheetSheet? _formulaSheet;
  OSheetFormulaEngine? _formulaEngine;

  OSheetFormulaEngine _engineFor(OSheetSheet sheet) {
    if (!identical(_formulaSheet, sheet) || _formulaEngine == null) {
      _formulaSheet = sheet;
      _formulaEngine = OSheetFormulaEngine(sheet, overrideAt: _editOverride);
    }
    return _formulaEngine!;
  }

  /// 协作覆盖：编辑层（远端广播 / 未确认乐观值 / 已确认改动）与**文件原值不同**时
  /// 把它喂给公式引擎，让公式的**引用**看得到协作改动（否则求值结果停在文件快照上）。
  ///
  /// **只读**：只读编辑层的 `valueAt`，不产生任何写入（§5.1）。
  (bool, Object?)? _editOverride(int row, int col) {
    final edit = widget.edit;
    final sheet = _formulaSheet;
    if (edit == null || sheet == null) return null;
    final cell = edit.valueAt(row, col);
    if (!cell.present) return null;
    final value = cell.value;
    if (value == sheet.cellAt(row, col)?.value) return null;
    // 用户刚敲进去的公式串本地无法求值（`officeSheetValueFromText` 原样保留 `=`），
    // 不作数值覆盖：引用该格回落到文件值，避免把公式原文当成数值参与计算。
    if (value is String && value.startsWith('=')) return null;
    return (true, value);
  }

  @override
  void initState() {
    super.initState();
    _prepare();
    _bindEdit();
  }

  @override
  void didUpdateWidget(covariant OfficeSheetView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sections, widget.sections) ||
        !identical(oldWidget.ooxmlBytes, widget.ooxmlBytes) ||
        !identical(oldWidget.workbook, widget.workbook) ||
        oldWidget.report != widget.report) {
      _prepare();
    }
    if (!identical(oldWidget.edit, widget.edit)) {
      _bindEdit();
    }
  }

  @override
  void dispose() {
    _boundEdit?.removeListener(_onEditChanged);
    _editText?.dispose();
    _editFocus?.dispose();
    _vController.dispose();
    _hController.dispose();
    super.dispose();
  }

  void _bindEdit() {
    if (!identical(_boundEdit, widget.edit)) {
      _boundEdit?.removeListener(_onEditChanged);
      _boundEdit = widget.edit;
      _boundEdit?.addListener(_onEditChanged);
      // 换了一个编辑层：求值缓存（含旧覆盖）失效。
      _formulaEngine = null;
    }
  }

  void _onEditChanged() {
    if (!mounted) return;
    // 编辑层变了（乐观值 / 远端广播 / 确认回滚）：求值缓存必须失效，
    // 否则公式会停在改动前的值上。
    _formulaEngine = null;
    setState(() {});
  }

  void _prepare() {
    _report = widget.report ?? OfficeSheetRenderReport();
    _fallbackNotice = null;
    // 换文档后重新允许一次自适应（用户手动缩放过的记录由 [_userZoomed] 兜住）。
    _autoFitDone = false;
    // 显式给了初始缩放（恢复上次缩放 / 测试要确定几何）⇒ **不再自适应**。
    final presetScale = widget.initialScale;
    if (presetScale != null) {
      _scale = presetScale.clamp(kOfficeSheetMinScale, kOfficeSheetMaxScale);
      _autoFitDone = true;
    }

    // ① 预建的模型（`office_viewer_page.dart` 的旧路径复用同一渲染器）。
    final preset = widget.workbook;
    if (preset != null) {
      _workbook = preset;
      _modelError = null;
      _afterPrepare();
      return;
    }

    // ② **OOXML（XLSX）主通道**：服务端转码后的标准 XLSX 里有真实列宽/样式/数字格式。
    final ooxml = widget.ooxmlBytes;
    if (ooxml != null && ooxml.isNotEmpty) {
      if (!isOfficeSheetOoxmlBytes(ooxml)) {
        _fallbackNotice = officeSheetText(
          'officeSheetFallbackNotOoxml',
          '这个文件不是标准表格格式，已按兼容方式打开，部分版式可能未完全还原。',
        );
        _report.note('下载字节没有 ZIP(OXML) 头 → 回落 OFile 只读解析');
      } else {
        try {
          _workbook = parseOfficeSheetXlsx(ooxml);
          _modelError = null;
          _report.ooxmlSheetsParsed = _workbook!.sheets.length;
          _afterPrepare();
          return;
        } on Object catch (e) {
          _fallbackNotice = officeSheetText(
            'officeSheetFallbackParseFailed',
            '标准表格版式解析失败，已按兼容方式打开，部分版式可能未完全还原。',
          );
          _report.note('OOXML 解析失败 → 回落 OFile 只读解析：$e');
        }
      }
    } else if (ooxml != null) {
      _fallbackNotice = officeSheetText(
        'officeSheetFallbackEmpty',
        '没有取到文件字节，已按兼容方式打开，部分版式可能未完全还原。',
      );
      _report.note('没有 OOXML 字节 → 回落 OFile 只读解析');
    }

    // ③ 降级通道：既有 OFile（`Snapshot:get` → `@C_text/*`）section 字典。
    scanOfficeSheetSections(widget.sections, _report);
    try {
      _workbook = OSheetWorkbook.fromSections(widget.sections);
      _modelError = null;
    } on Object catch (e) {
      _workbook = null;
      _modelError = e;
      _report.note('表格模型重建失败：$e');
    }
    _afterPrepare();
  }

  void _afterPrepare() {
    final sheets = _workbook?.sheets ?? const <OSheetSheet>[];
    if (_workbook != null) scanOfficeSheetCharts(_workbook!, _report);
    final wanted = widget.initialSheetId;
    if (wanted != null && sheets.any((s) => s.id == wanted)) {
      _sheetId = wanted;
    } else if (sheets.isNotEmpty) {
      _sheetId = sheets.first.id;
    } else {
      _sheetId = null;
    }
    if (widget.report == null && _report.messages.isNotEmpty) {
      for (final m in _report.messages) {
        debugPrint('[OfficeSheetView] $m');
      }
    }
  }

  OSheetSheet? get _sheet {
    final id = _sheetId;
    if (id == null) return null;
    return _workbook?.sheetById(id);
  }

  // -------------------------------------------------------------------------
  // 缩放（O2）：`Listener` 直接数手指 → 不参与 gesture arena，单指滚动不受影响
  // -------------------------------------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      _pinchStartDistance = _pointerDistance();
      _pinchStartScale = _scale;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length != 2 || _pinchStartDistance == null) return;
    final d = _pointerDistance();
    if (d <= 0 || _pinchStartDistance! <= 0) return;
    final next = (_pinchStartScale * (d / _pinchStartDistance!))
        .clamp(kOfficeSheetMinScale, kOfficeSheetMaxScale);
    if ((next - _scale).abs() > 0.001) setState(() => _scale = next);
  }

  void _onPointerEnd(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.length < 2) {
      _pinchStartDistance = null;
    }
  }

  double _pointerDistance() {
    final values = _pointers.values.toList(growable: false);
    if (values.length != 2) return 0;
    return (values[0] - values[1]).distance;
  }

  /// [byUser] = false 只有"打开即自适应宽"会用到 —— 那是**应用替用户做的决定**，
  /// 不能因此认为用户"已经调过缩放"。
  void _setScale(double value, {bool byUser = true}) {
    final next = value.clamp(kOfficeSheetMinScale, kOfficeSheetMaxScale);
    if ((next - _scale).abs() < 0.0001) return;
    setState(() {
      _scale = next;
      if (byUser) _userZoomed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final workbook = _workbook;
    if (_modelError != null || workbook == null) {
      return _withFallback(_card(
        key: const Key('office-sheet-error'),
        icon: Icons.error_outline,
        text: officeSheetFill(
          'officeSheetModelFailed',
          '无法重建表格模型：{name}',
          <String, String>{'name': '$_modelError'},
        ),
      ));
    }
    if (workbook.sheets.isEmpty) {
      return _withFallback(_card(
        key: const Key('office-sheet-empty'),
        icon: Icons.grid_off_outlined,
        text: officeSheetText('officeSheetEmpty', '这张工作簿里没有可显示的工作表'),
        hint: officeSheetText(
          'officeSheetEmptyHint',
          '可以重试打开，或在官方 Synology Drive 应用里查看这个文件。',
        ),
      ));
    }
    final sheet = _sheet;
    if (sheet == null) {
      return _withFallback(_card(
        key: const Key('office-sheet-empty'),
        icon: Icons.grid_off_outlined,
        text: officeSheetText('officeSheetEmpty', '这张工作簿里没有可显示的工作表'),
        hint: officeSheetText(
          'officeSheetEmptyHint',
          '可以重试打开，或在官方 Synology Drive 应用里查看这个文件。',
        ),
      ));
    }
    final cfs = officeSheetConditionalFormats(sheet.raw['cfs']);
    return Column(
      key: const Key('office-sheet-view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_fallbackNotice != null) _fallbackNote(_fallbackNotice!),
        if (sheet.rowCount > kOfficeSheetMaxRenderRows ||
            sheet.colCount > kOfficeSheetMaxRenderCols)
          _truncationNote(sheet),
        if (_report.hasDegradations) _partialBanner(),
        if (workbook.sheets.length > 1) _sheetTabs(workbook),
        _toolbar(sheet),
        const Divider(height: 1),
        Expanded(child: _grid(sheet)),
        // 条件格式：把文件里声明的规则如实列出（公式求值在服务端，这里不假装求值）。
        if (cfs.isNotEmpty) _cfsNote(cfs),
      ],
    );
  }

  /// 缩放工具条（O2）：**适宽** + 缩放增减 + 百分比。
  ///
  /// 与双指缩放共用同一个 [_scale]（所有行高/列宽/字号都乘它），所以"适宽"后
  /// 滚动坐标系依然一致。
  Widget _toolbar(OSheetSheet sheet) {
    final percent = (_scale * 100).round();
    return Container(
      key: const Key('office-sheet-toolbar'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      child: Row(
        children: [
          TextButton.icon(
            key: const Key('office-sheet-zoom-fit'),
            onPressed: () => _fitToWidth(sheet),
            icon: const Icon(Icons.fit_screen_outlined, size: 16),
            label: Text(officeSheetText('officeSheetFitWidth', '适宽')),
          ),
          const Spacer(),
          IconButton(
            key: const Key('office-sheet-zoom-out'),
            tooltip: officeSheetText('officeSheetZoomOut', '缩小'),
            visualDensity: VisualDensity.compact,
            onPressed: () => _setScale(_scale / 1.25),
            icon: const Icon(Icons.remove, size: 18),
          ),
          Text(
            '$percent%',
            key: const Key('office-sheet-zoom-label'),
            style: Theme.of(context).textTheme.labelSmall,
          ),
          IconButton(
            key: const Key('office-sheet-zoom-in'),
            tooltip: officeSheetText('officeSheetZoomIn', '放大'),
            visualDensity: VisualDensity.compact,
            onPressed: () => _setScale(_scale * 1.25),
            icon: const Icon(Icons.add, size: 18),
          ),
        ],
      ),
    );
  }

  /// "适宽"：把整张表的列宽（含行号列）缩到可视区宽度。
  void _fitToWidth(OSheetSheet sheet) {
    final fit = _fitScaleFor(sheet);
    if (fit == null) return;
    _setScale(fit);
  }

  /// 整张表（**含行号列**）在当前可视区宽度下的"适宽"比例。
  ///
  /// 返回 `null` 表示还算不出来（列宽或可视区宽度还没拿到）。
  double? _fitScaleFor(OSheetSheet sheet) {
    final cLimit = sheet.colCount < kOfficeSheetMaxRenderCols
        ? sheet.colCount
        : kOfficeSheetMaxRenderCols;
    var width = kOfficeSheetRowHeaderWidth;
    for (var c = 0; c < cLimit; c++) {
      if (sheet.isColHidden(c)) continue;
      width += sheet.colWidthAt(c);
    }
    if (width <= 0 || _viewportWidth <= 0) return null;
    return (_viewportWidth - 8) / width;
  }

  Widget _partialBanner() {
    return Container(
      key: const Key('office-sheet-partial-banner'),
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(
              officeSheetFill(
                'officeSheetRenderPartial',
                '此表格有 {count} 处内容未能完整显示。',
                <String, String>{'count': '${_report.degradationCount}'},
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// 超大表：只渲染可视窗口内的行列（虚拟化），并**如实**说明显示了哪一块。
  ///
  /// 与 `_fallbackNote` 一样是"有事才显示"的一行，不是常驻横幅。
  Widget _truncationNote(OSheetSheet sheet) {
    final rows = sheet.rowCount > kOfficeSheetMaxRenderRows
        ? kOfficeSheetMaxRenderRows
        : sheet.rowCount;
    final cols = sheet.colCount > kOfficeSheetMaxRenderCols
        ? kOfficeSheetMaxRenderCols
        : sheet.colCount;
    return Container(
      key: const Key('office-sheet-truncated'),
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Text(
        officeSheetFill(
          'officeSheetRenderTruncated',
          '只显示前 {rows} 行 × {cols} 列（表格更大，已按可视范围显示）。',
          <String, String>{'rows': '$rows', 'cols': '$cols'},
        ),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  /// 把"回落说明"包在**任何**返回体外面：空态/错误态也不能把"为什么不是标准版式"
  /// 这条信息吞掉（用户要求：不得静默空白）。
  Widget _withFallback(Widget child) {
    final notice = _fallbackNotice;
    if (notice == null) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [ _fallbackNote(notice), Expanded(child: child) ],
    );
  }

  /// **只在真的回落到 OFile 兼容通道时**出现的一行用户语言说明。
  ///
  /// 不是常驻横幅：主通道（OOXML）命中时这里恒不渲染；文案里也没有任何
  /// "本批 / 从简 / 不支持"之类的工程话术。
  Widget _fallbackNote(String text) {
    return Container(
      key: const Key('office-sheet-fallback-note'),
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _sheetTabs(OSheetWorkbook workbook) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
        children: [
          for (final sheet in workbook.sheets)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xxs),
              child: Center(
                child: ChoiceChip(
                  key: Key('office-sheet-tab-${sheet.id}'),
                  label: Text(sheet.title),
                  selected: sheet.id == _sheetId,
                  onSelected: (_) => setState(() => _sheetId = sheet.id),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _grid(OSheetSheet sheet) {
    final pool = _workbook?.styles;
    final rowCount = sheet.rowCount;
    final colCount = sheet.colCount;
    if (rowCount <= 0 || colCount <= 0) {
      return _card(
        key: const Key('office-sheet-empty'),
        icon: Icons.grid_off_outlined,
        text: officeSheetText(
          'officeSheetNoRows',
          '这张工作表没有行列（rowCount/colCount 为 0）',
        ),
        hint: officeSheetText(
          'officeSheetEmptyHint',
          '可以重试打开，或在官方 Synology Drive 应用里查看这个文件。',
        ),
      );
    }
    final rLimit = rowCount < kOfficeSheetMaxRenderRows
        ? rowCount
        : kOfficeSheetMaxRenderRows;
    final cLimit = colCount < kOfficeSheetMaxRenderCols
        ? colCount
        : kOfficeSheetMaxRenderCols;

    // ★ 列宽 / 行高**按文件声明**（`sh_N.cols[c].w` / `sh_N.rows[r].h`；
    //   缺省回落 `global.w/h`，再回落显示缺省），再乘当前缩放系数。
    //   **绝不把列拉满屏**：真实文件列宽 20…504，屏宽通常 360+ ⇒ 必须横向滚动。
    //   O3：**隐藏行/列真的隐藏**（尺寸置 0 且不产格子/表头，位置自然塌缩）。
    final scale = _scale;
    final formulas = _engineFor(sheet);
    final rowH = <double>[];
    final rowTop = <double>[];
    var y = 0.0;
    for (var r = 0; r < rLimit; r++) {
      final hidden = sheet.isRowHidden(r);
      final h = hidden ? 0.0 : sheet.rowHeightAt(r) * scale;
      rowH.add(h);
      rowTop.add(y);
      y += h;
    }
    final totalH = y;
    final colW = <double>[];
    final colLeft = <double>[];
    var x = 0.0;
    for (var c = 0; c < cLimit; c++) {
      final hidden = sheet.isColHidden(c);
      final w = hidden ? 0.0 : sheet.colWidthAt(c) * scale;
      colW.add(w);
      colLeft.add(x);
      x += w;
    }
    final totalW = x;
    _report.hiddenRowsHidden = sheet.hiddenRows.where((r) => r < rLimit).length;
    _report.hiddenColsHidden = sheet.hiddenCols.where((c) => c < cLimit).length;
    final headerW = kOfficeSheetRowHeaderWidth * scale;
    final headerH = kOfficeSheetColHeaderHeight * scale;

    // 合并区间 `[r1,c1,r2,c2]`（**行列区间**，与 `.odoc` 的 colspan 语义不同）。
    final merges = OfficeSheetMergeIndex(
      officeSheetMergeRegions(
        sheet.raw['mergeCells'],
        rowCount: rLimit,
        colCount: cLimit,
      ),
    );
    // 条件格式（`f1` 不求值，只按 `ranges` 套 `style`）。
    final cfs = officeSheetConditionalFormats(sheet.raw['cfs']);

    // ★ 冻结窗格：`sh_N.fixedRowTop` / `fixedColumnLeft`（真实文件 Annual = 10 / 0）。
    final frozenRows = sheet.fixedRowTop <= 0
        ? 0
        : (sheet.fixedRowTop > rLimit ? rLimit : sheet.fixedRowTop);
    final frozenCols = sheet.fixedColumnLeft <= 0
        ? 0
        : (sheet.fixedColumnLeft > cLimit ? cLimit : sheet.fixedColumnLeft);
    final frozenH = frozenRows > 0
        ? rowTop[frozenRows - 1] + rowH[frozenRows - 1]
        : 0.0;
    final frozenW = frozenCols > 0
        ? colLeft[frozenCols - 1] + colW[frozenCols - 1]
        : 0.0;
    final bodyW = (totalW - frozenW) < 0 ? 0.0 : totalW - frozenW;
    final bodyH = (totalH - frozenH) < 0 ? 0.0 : totalH - frozenH;

    // ★ 文档画布的着色**一律来自文档自己**（批 O4）。App 深色模式只影响外层
    //   chrome（AppBar / 工具条），**不影响文档画布**：
    //   * 纸面 = **白**（OOXML "无填充" 的语义；也与 `.odoc` 的 `Colors.white` 对齐）；
    //   * 网格线 = 文件 `<sheetView colorId>` / `<color>`，否则文档兜底灰
    //     （**不再用 `Theme.of(context).dividerColor`**：深色主题下那条线是亮的，
    //      画在白纸上像反色表格）；
    //   * 行号列 / 列标行 = 文档表头灰，不跟 App 主题。
    final docGridLine =
        officeSheetParseColor(sheet.raw['gridLineColor']) ??
        kOfficeSheetGridLineColor;
    final showGridLines = sheet.raw['showGridLines'] != false;
    const headerBg = kOfficeSheetHeaderFillColor;

    // 一个格子（合并区的左上锚点画成大格；被覆盖的格调用方跳过）。
    // `left`/`top` 是**所在带（band）的局部坐标**。
    Positioned positioned(int r, int c, double left, double top) {
      final region = merges.anchorAt(r, c);
      final r2 = region == null
          ? r
          : (region.r2 < rLimit - 1 ? region.r2 : rLimit - 1);
      final c2 = region == null
          ? c
          : (region.c2 < cLimit - 1 ? region.c2 : cLimit - 1);
      var width = 0.0;
      for (var cc = c; cc <= c2; cc++) {
        width += colW[cc];
      }
      var height = 0.0;
      for (var rr = r; rr <= r2; rr++) {
        height += rowH[rr];
      }
      return Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: _cell(
          sheet,
          r,
          c,
          width,
          height,
          pool,
          merges,
          cfs,
          scale,
          formulas,
          docGridLine,
          showGridLines,
        ),
      );
    }

    final bodyCells = <Widget>[];
    for (var r = frozenRows; r < rLimit; r++) {
      if (sheet.isRowHidden(r)) continue;
      for (var c = frozenCols; c < cLimit; c++) {
        if (sheet.isColHidden(c)) continue;
        if (merges.isCovered(r, c)) continue;
        bodyCells.add(positioned(r, c, colLeft[c] - frozenW, rowTop[r] - frozenH));
      }
    }
    // O3：图表**真的绘制**（`displayRange`/`plotArea.series` → 系列）。
    //   位置尺寸用 `pos{left,top,width,height}`；数据为空/类型不支持 → 退回占位卡。
    final chartSource = OfficeSheetEngineDataSource(formulas);
    var chartPlaceholders = 0;
    for (final chart in officeSheetCharts(sheet.raw['drawing'])) {
      final left = chart.left * scale - frozenW;
      final top = chart.top * scale - frozenH;
      final data = chart.isRenderable
          ? officeSheetChartData(chart, chartSource)
          : null;
      final drawable = data != null && !data.isEmpty;
      if (!drawable) chartPlaceholders++;
      bodyCells.add(
        Positioned(
          left: left < 0 ? 0 : left,
          top: top < 0 ? 0 : top,
          width: chart.width * scale,
          height: chart.height * scale,
          child: drawable
              ? OfficeSheetChartView(chart: chart, data: data)
              : _chartCard(chart),
        ),
      );
    }
    // 公式引擎的统计（渲染真正用到了才写；图表取值也走同一个引擎）。
    _report.formulaCellsEvaluated = formulas.formulaCellsEvaluated;
    _report.formulaCellsFallback = formulas.formulaCellsFailed;
    _report.formulaCellsCircular = formulas.circularCells;
    _report.chartsPlaceholder = chartPlaceholders;
    final frozenRowCells = <Widget>[];
    for (var r = 0; r < frozenRows; r++) {
      if (sheet.isRowHidden(r)) continue;
      for (var c = frozenCols; c < cLimit; c++) {
        if (sheet.isColHidden(c)) continue;
        if (merges.isCovered(r, c)) continue;
        frozenRowCells.add(positioned(r, c, colLeft[c] - frozenW, rowTop[r]));
      }
    }
    final frozenColCells = <Widget>[];
    for (var r = frozenRows; r < rLimit; r++) {
      if (sheet.isRowHidden(r)) continue;
      for (var c = 0; c < frozenCols; c++) {
        if (sheet.isColHidden(c)) continue;
        if (merges.isCovered(r, c)) continue;
        frozenColCells.add(positioned(r, c, colLeft[c], rowTop[r] - frozenH));
      }
    }
    final cornerCells = <Widget>[];
    for (var r = 0; r < frozenRows; r++) {
      if (sheet.isRowHidden(r)) continue;
      for (var c = 0; c < frozenCols; c++) {
        if (sheet.isColHidden(c)) continue;
        if (merges.isCovered(r, c)) continue;
        cornerCells.add(
          positioned(r, c, headerW + colLeft[c], headerH + rowTop[r]),
        );
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        _viewportHeight = constraints.maxHeight;
        // ★ **打开即自适应宽**（对齐 WPS / Microsoft Office 安卓版形态）。
        //
        //   为什么必须有：手机竖屏宽约 375dp，而真实工作表的列宽总和大得多
        //   （Annual 那份 15 列 ≈ 1500px）⇒ 100% 打开时**只能看到 A/B/C 三列**，
        //   用户得先手动点"适宽"。官方是**打开就把整张表的宽度适配到屏幕**。
        //
        //   三条克制：① 每个文档**只做一次**；② 用户手动调过缩放就**永不**介入；
        //   ③ **永不放大超过 100%**（本来就窄的表保持原样，不做虚假放大）。
        if (!_autoFitDone && _viewportWidth > 0) {
          _autoFitDone = true;
          final fit = _fitScaleFor(sheet);
          if (fit != null && fit < 1.0 && !_userZoomed) {
            // build/layout 期间不能直接 setState ⇒ 排到本帧结束再应用。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _userZoomed) return;
              final again = _fitScaleFor(sheet);
              if (again != null && again < 1.0) {
                _setScale(again, byUser: false);
              }
            });
          }
        }
        // 平移条带的裁剪窗口长度（见 [officeSheetBandStripExtent] 的推导）。
        final bandH = _viewportHeight - (headerH + frozenH);
        final bandW = _viewportWidth - (headerW + frozenW);
        // ★ 条带长度取 max(内容, 窗口)：内容比视口矮时（"适宽"/表短）
        //   滚动量为 0，只给 bodyH 会让窗口下半截**整片空白**（真机 bug）。
        final rowStripH = officeSheetBandStripExtent(bodyH, bandH);
        final colStripW = officeSheetBandStripExtent(bodyW, bandW);
        return Listener(
          key: const Key('office-sheet-pinch'),
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: (event) => _onPointerEnd(event.pointer),
          onPointerCancel: (event) => _onPointerEnd(event.pointer),
          child: Stack(
            children: [
              // ★ 文档画布底色 = **文档自己的白纸**（批 O4 的核心修复）。
              //   旧实现让没有显式填充的格子直接透出 App 的 `colorScheme.surface`，
              //   深色主题下整张表变黑底白字 —— 而真实文件是白底黑字。
              //   铺在最底层，覆盖整个视口（含已用区域之外、以及右侧/下方的空白），
              //   与 Excel / WPS 的"白纸页面"形态一致。
              const Positioned.fill(
                child: ColoredBox(
                  key: Key('office-sheet-paper'),
                  color: kOfficeSheetPaperColor,
                ),
              ),
              // 主体：二维滚动（纵向在外、横向在内）。
              Positioned.fill(
                child: SingleChildScrollView(
                  controller: _vController,
                  child: SingleChildScrollView(
                    controller: _hController,
                    scrollDirection: Axis.horizontal,
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: headerW + frozenW,
                        top: headerH + frozenH,
                      ),
                      child: SizedBox(
                        width: bodyW,
                        height: bodyH,
                        child: Stack(
                          key: const Key('office-sheet-grid'),
                          children: bodyCells,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 冻结行带：纵向固定、横向随主体。
              if (frozenRows > 0 && frozenH > 0)
                Positioned(
                  key: const Key('office-sheet-frozen-rows-band'),
                  top: headerH,
                  left: headerW + frozenW,
                  right: 0,
                  height: frozenH,
                  child: ClipRect(
                      child: _bandScrollRelay(
                        key: Key('office-sheet-band-relay-43076'),
                        child: Stack(
                          children: [
                            // BEI: background must NOT hit-test (see _bandScrollRelay doc).
                            Positioned.fill(
                              child: IgnorePointer(child: ColoredBox(color: kOfficeSheetPaperColor)),
                            ),
 AnimatedBuilder(
                      animation: _hController,
                      builder: (context, _) => Transform.translate(
                        offset: Offset(-_hOffset(), 0),
                        child: SizedBox(
                          key: const Key('office-sheet-frozen-rows-strip'),
                          width: colStripW,
                          height: frozenH,
                          // ★ Clip.none：外层 Stack 的**松约束**会把本 SizedBox 的高度钳到窗口高，
                          //   内层 Stack 默认 `Clip.hardEdge` 就会把窗口以下的标签
                          //   整个裁掉（真机 bug：滚深后行号列空白）。
                          //   裁到窗口由外层的 ClipRect 负责，这里必须放行。
                          child: Stack(clipBehavior: Clip.none, children: frozenRowCells),
                        ),
                      ),
                    )
                          ],
                        ),
                      ),
                    ),
                ),
              // 冻结列带：横向固定、纵向随主体。
              if (frozenCols > 0 && frozenW > 0)
                Positioned(
                  key: const Key('office-sheet-frozen-cols-band'),
                  top: headerH + frozenH,
                  left: headerW,
                  width: frozenW,
                  bottom: 0,
                  child: ClipRect(
                      child: _bandScrollRelay(
                        key: Key('office-sheet-band-relay-44083'),
                        child: Stack(
                          children: [
                            // BEI: background must NOT hit-test (see _bandScrollRelay doc).
                            Positioned.fill(
                              child: IgnorePointer(child: ColoredBox(color: kOfficeSheetPaperColor)),
                            ),
 AnimatedBuilder(
                      animation: _vController,
                      builder: (context, _) => Transform.translate(
                        offset: Offset(0, -_vOffset()),
                        child: SizedBox(
                          key: const Key('office-sheet-frozen-cols-strip'),
                          width: frozenW,
                          height: rowStripH,
                          child: Stack(clipBehavior: Clip.none, children: frozenColCells),
                        ),
                      ),
                    )
                          ],
                        ),
                      ),
                    ),
                ),
              // 列标行（可滚动部分）：**冻结在顶部**。
              Positioned(
                key: const Key('office-sheet-header-row'),
                top: 0,
                left: headerW + frozenW,
                right: 0,
                height: headerH,
                child: ClipRect(
                    child: _bandScrollRelay(
                      key: Key('office-sheet-band-relay-45020'),
                      child: Stack(
                        children: [
                          // BEI: background must NOT hit-test (see _bandScrollRelay doc).
                          Positioned.fill(
                            child: IgnorePointer(child: ColoredBox(color: headerBg)),
                          ),
 AnimatedBuilder(
                    animation: _hController,
                    builder: (context, _) => Transform.translate(
                      offset: Offset(-_hOffset(), 0),
                      child: SizedBox(
                        key: const Key('office-sheet-col-header-strip'),
                        width: colStripW,
                        height: headerH,
                        // ★ Clip.none（同 frozenRowCells 处的说明）。
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            for (var c = frozenCols; c < cLimit; c++)
                              if (!sheet.isColHidden(c))
                                Positioned(
                                  left: colLeft[c] - frozenW,
                                  top: 0,
                                  width: colW[c],
                                  height: headerH,
                                  child: _headerBox(
                                    officeSheetColumnLabel(c),
                                    colW[c],
                                    key: Key('office-sheet-col-header-$c'),
                                    scale: scale,
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  )
                        ],
                      ),
                    ),
                  ),
              ),
              // 行号列（可滚动部分）：**冻结在左侧**。
              Positioned(
                key: const Key('office-sheet-row-header-column'),
                top: headerH + frozenH,
                left: 0,
                width: headerW,
                bottom: 0,
                child: ClipRect(
                    child: _bandScrollRelay(
                      key: Key('office-sheet-band-relay-46755'),
                      child: Stack(
                        children: [
                          // BEI: background must NOT hit-test (see _bandScrollRelay doc).
                          Positioned.fill(
                            child: IgnorePointer(child: ColoredBox(color: headerBg)),
                          ),
 AnimatedBuilder(
                    animation: _vController,
                    builder: (context, _) => Transform.translate(
                      offset: Offset(0, -_vOffset()),
                      child: SizedBox(
                        key: const Key('office-sheet-row-header-strip'),
                        width: headerW,
                        height: rowStripH,
                        // ★ Clip.none（同 frozenRowCells 处的说明）。
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            for (var r = frozenRows; r < rLimit; r++)
                              if (!sheet.isRowHidden(r))
                                Positioned(
                                  left: 0,
                                  top: rowTop[r] - frozenH,
                                  width: headerW,
                                  height: rowH[r],
                                  child: _headerBox(
                                    '${r + 1}',
                                    headerW,
                                    key: Key('office-sheet-row-header-$r'),
                                    scale: scale,
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  )
                        ],
                      ),
                    ),
                  ),
              ),
              // 左上角块：行号列 ∩ 列标行 ∩ 冻结区。
              Positioned(
                top: 0,
                left: 0,
                width: headerW + frozenW,
                height: headerH + frozenH,
                child: _bandScrollRelay(
                  key: const Key('office-sheet-band-relay-corner'),
                  child: Stack(
                    children: [
                      // BEI: background must NOT hit-test (see _bandScrollRelay doc).
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ColoredBox(color: headerBg),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        width: headerW,
                        height: headerH,
                        child: _headerBox(
                          '',
                          headerW,
                          key: const Key('office-sheet-corner'),
                          scale: scale,
                        ),
                      ),
                      for (var c = 0; c < frozenCols; c++)
                        if (!sheet.isColHidden(c))
                          Positioned(
                            left: headerW + colLeft[c],
                            top: 0,
                            width: colW[c],
                            height: headerH,
                            child: _headerBox(
                              officeSheetColumnLabel(c),
                              colW[c],
                              key: Key('office-sheet-col-header-$c'),
                              scale: scale,
                            ),
                          ),
                      for (var r = 0; r < frozenRows; r++)
                        if (!sheet.isRowHidden(r))
                          Positioned(
                            left: 0,
                            top: headerH + rowTop[r],
                            width: headerW,
                            height: rowH[r],
                            child: _headerBox(
                              '${r + 1}',
                              headerW,
                              key: Key('office-sheet-row-header-$r'),
                              scale: scale,
                            ),
                          ),
                      ...cornerCells,
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ⚠️ 冻结带（行号列 / 列标行 / 冻结行列带）必须与内容**同向**移动：
  //   内容随滚动向左/上移，所以冻结带要用**负**偏移跟随。
  //   这里曾长期写成正号 `Offset(_hOffset(), 0)` / `Offset(0, _vOffset())`，
  //   导致滚动时冻结的行号/列标**朝反方向跑**（真机表现为"滑动时表头乱跳、
  //   行号对不上内容"）。探针实测：拖动 380px，内容上移 380，而
  //   `row-header-20` 下移了 380 —— 两者相差 2*offset。
  //   两个取值函数本身仍返回**正**的滚动偏移，取负放在使用处，语义更清楚。
  double _hOffset() => _hController.hasClients ? _hController.offset : 0;

  double _vOffset() => _vController.hasClients ? _vController.offset : 0;

  // ── 冻结带上的拖动转发（修「左右/上下滑动没反应」）─────────────────────────
  //
  // 【根因】冻结带（行号列 / 列标行 / 冻结行带 / 冻结列带 / 左上角）是 `Positioned`
  //   画在二维滚动视图**之上**的 `ColoredBox`。Flutter 的 `ColoredBox` 用
  //   `_RenderColoredBox extends RenderProxyBoxWithHitTestBehavior`，构造时
  //   `behavior: HitTestBehavior.opaque` ⇒ `hitTestSelf()` **恒为 true** ⇒
  //   指针在冻结带上按下时，外层 `Stack` 视为"已命中"而**不再命中下面的滚动视图**，
  //   ⇒ 在这些区域滑动**完全不滚动**。
  //
  //   真机后果：手机屏窄（360–412dp），行号列（48px）+ 列标行（49px）+ 冻结列
  //   占掉左侧/顶部一大块，用户习惯从边缘起划 ⇒ 表格纹丝不动。
  //   探针实测（修前）：主体区拖动 h=180 ✅；行号列/列标行/左上角拖动 h=0 ❌。
  //
  // 【为什么不用 `IgnorePointer` 包整块】冻结带里的单元格是 `_cell()` 出来的，
  //   带 `onTap`/`onDoubleTap`（点格编辑）。整块 `IgnorePointer` 会让"点冻结格
  //   编辑"失效；而只对行号列 `IgnorePointer` 又会在横向滚动后把点击透给
  //   **被压在下面的错格子**（行号列位置下方正是已滚过来内容）。两条都不可取。
  //
  // 【做法】`Listener` **不参与 gesture arena**（它只观察原始指针事件，不做裁决）
  //   ⇒ 点击照旧落到正确的单元格；但它能看到指针位移，于是手动把位移喂给滚动
  //   控制器。这是"保点击 + 能拖动"两全的唯一办法。
  //
  //   轴锁定与 `Scrollable` 一致：先看谁先超过 `kTouchSlop`，锁定该轴后不再改判，
  //   避免斜划时两轴同时乱动。
  int? _bandPointer;
  Offset? _bandLastPos;
  Axis? _bandAxis;
  Offset _bandAccum = Offset.zero;

  /// 把冻结带上的手指位移转发给滚动控制器（不消费手势，不影响点击）。
  void _bandDragStart(PointerDownEvent event) {
    if (_bandPointer != null) return; // 只认第一根手指；多指交给捏合缩放
    _bandPointer = event.pointer;
    _bandLastPos = event.position;
    _bandAxis = null;
    _bandAccum = Offset.zero;
  }

  void _bandDragUpdate(PointerMoveEvent event) {
    if (event.pointer != _bandPointer) return;
    final last = _bandLastPos;
    if (last == null) return;
    final delta = event.position - last;
    _bandLastPos = event.position;

    if (_bandAxis == null) {
      _bandAccum += delta;
      if (_bandAccum.distance < _kBandTouchSlop) return;
      _bandAxis = _bandAccum.dx.abs() >= _bandAccum.dy.abs()
          ? Axis.horizontal
          : Axis.vertical;
      // 起手先吃掉一个 touch slop —— 与 `Scrollable` 的既有手感一致。
      // 不这么做实测会多走 20px（原生滚动 180、转发 200）。
      final slop = _bandAxis == Axis.horizontal
          ? Offset(_bandAccum.dx.sign * _kBandTouchSlop, 0)
          : Offset(0, _bandAccum.dy.sign * _kBandTouchSlop);
      _applyBandScroll(_bandAccum - slop);
      return;
    }
    _applyBandScroll(delta);
  }

  void _bandDragEnd(int pointer) {
    if (pointer != _bandPointer) return;
    _bandPointer = null;
    _bandLastPos = null;
    _bandAxis = null;
    _bandAccum = Offset.zero;
  }

  /// 与框架的 `kTouchSlop` 同值（18.0）。`kTouchSlop` 定义在
  /// `package:flutter/gestures.dart`，**没有被 `material.dart` 导出**，
  /// 这里用私有常量避免为一个数值引入新 import。
  static const double _kBandTouchSlop = 18.0;

  void _applyBandScroll(Offset delta) {
    final horizontal = _bandAxis == Axis.horizontal;
    final controller = horizontal ? _hController : _vController;
    if (!controller.hasClients) return;
    // 手指向左/上 ⇒ 内容向左/上 ⇒ offset 增大（与 Scrollable 同向）
    final next = (controller.offset - (horizontal ? delta.dx : delta.dy))
        .clamp(0.0, controller.position.maxScrollExtent);
    if ((next - controller.offset).abs() < 0.01) return;
    controller.jumpTo(next);
  }

  /// 包住一个冻结带：背景可穿透（空白处走真实滚动 + 惯性），
  /// 但整块都接上拖动转发（在单元格上也能拖动滚动）。
  Widget _bandScrollRelay({required Key key, required Widget child}) {
    return Listener(
      key: key,
      behavior: HitTestBehavior.translucent,
      onPointerDown: _bandDragStart,
      onPointerMove: _bandDragUpdate,
      onPointerUp: (e) => _bandDragEnd(e.pointer),
      onPointerCancel: (e) => _bandDragEnd(e.pointer),
      child: child,
    );
  }

  /// 图表占位卡片：只有在**类型不支持或数据解析不出来**时才用（O3 起真图优先）。
  Widget _chartCard(OfficeSheetChart chart) {
    return Container(
      key: Key('office-sheet-chart-${chart.id ?? chart.title}'),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(Gap.sm),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.insert_chart_outlined, size: 28),
          const SizedBox(height: Gap.xs),
          Text(
            chart.title.isEmpty
                ? officeSheetText('officeSheetChart', '图表')
                : chart.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: Gap.xxs),
          Text(
            officeSheetText('officeSheetChartUnavailable', '图表内容暂不能显示'),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// 条件格式说明：**原样列出 `f1` 规则**（求值在服务端，这里不假装求值）。
  Widget _cfsNote(List<OfficeSheetConditionalFormat> cfs) {
    return Container(
      key: const Key('office-sheet-cfs-note'),
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            officeSheetFill(
              'officeSheetConditionalFormats',
              '已套用的条件格式规则（{count} 条）',
              <String, String>{'count': '${cfs.length}'},
            ),
            style: Theme.of(context).textTheme.labelMedium,
          ),
          for (final cf in cfs)
            Text(
              officeSheetFill(
                'officeSheetConditionalFormatLine',
                '{ranges} · {formula}',
                <String, String>{
                  'ranges': cf.ranges
                      .map(
                        (r) =>
                            '${officeSheetColumnLabel(r.c1)}${r.r1 + 1}:'
                            '${officeSheetColumnLabel(r.c2)}${r.r2 + 1}',
                      )
                      .join(', '),
                  'formula': cf.formula ?? cf.text ?? cf.type ?? '',
                },
              ),
              key: Key('office-sheet-cfs-line-${cf.id ?? cf.formula}'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  Widget _headerBox(String label, double width, {Key? key, double scale = 1.0}) {
    return Container(
      key: key,
      width: width,
      padding: EdgeInsets.symmetric(horizontal: Gap.xxs * scale),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // 行号列 / 列标行属于**文档画布**，用文档表头色（Excel / WPS 同形态），
        // 不跟 App 主题：否则深色主题下会出现"黑表头 + 白纸"的割裂感。
        color: kOfficeSheetHeaderFillColor,
        border: Border.all(color: kOfficeSheetHeaderLineColor, width: 0.5),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: 10 * scale,
          color: kOfficeSheetHeaderTextColor,
        ),
      ),
    );
  }

  /// 进入格子编辑（批 2；只读态直接返回，**不允许绕过门控**）。
  void _beginEdit(int row, int col) {
    final edit = widget.edit;
    if (edit == null || !edit.canEdit) return;
    final current = edit.valueAt(row, col);
    _editText?.dispose();
    _editFocus?.dispose();
    _editText = TextEditingController(text: current.text);
    final focus = FocusNode()..addListener(_onEditFocusChanged);
    _editFocus = focus;
    setState(() {
      _editRow = row;
      _editCol = col;
    });
  }

  void _onEditFocusChanged() {
    final focus = _editFocus;
    if (focus == null || focus.hasFocus) return;
    _commitEdit();
  }

  /// 提交编辑 → `value` 命令（`officeSheetValueFromText` 决定 JSON 形态）。
  void _commitEdit() {
    final row = _editRow;
    final col = _editCol;
    final text = _editText;
    final edit = widget.edit;
    if (row == null || col == null || text == null || edit == null) return;
    final current = edit.valueAt(row, col);
    final value = officeSheetValueFromText(text.text, previous: current.value);
    final unchanged = current.present && value == current.value;
    final oldText = _editText;
    final oldFocus = _editFocus;
    _editText = null;
    _editFocus = null;
    setState(() {
      _editRow = null;
      _editCol = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldText?.dispose();
      oldFocus?.dispose();
    });
    if (!unchanged) {
      // 乐观显示 + 未确认队列在编辑层；这里只负责"生成一次提交"。
      unawaited(edit.editCell(row, col, value));
    }
  }

  Widget _editableOverlay(
    int row,
    int col,
    Widget child,
    Alignment alignment,
  ) {
    return GestureDetector(
      key: Key('office-sheet-cell-hit-$row-$col'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _beginEdit(row, col),
      onDoubleTap: () => _beginEdit(row, col),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Align(alignment: alignment, child: child),
          if (widget.edit?.isPending(row, col) ?? false)
            Positioned(
              key: Key('office-sheet-cell-pending-$row-$col'),
              right: 1,
              top: 1,
              child: Icon(
                Icons.edit,
                size: 9,
                color: Theme.of(context).colorScheme.tertiary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(
    OSheetSheet sheet,
    int r,
    int c,
    double width,
    double height,
    OSheetStylePool? pool,
    OfficeSheetMergeIndex merges,
    List<OfficeSheetConditionalFormat> cfs,
    double scale,
    OSheetFormulaEngine formulas,
    Color gridLineColor,
    bool showGridLines,
  ) {
    final edit = widget.edit;
    final workbookCell = sheet.cellAt(r, c);
    final cellValue = edit?.valueAt(r, c);
    final isFormula = workbookCell?.isFormula ?? false;
    // ★ 修复（R17）：显示来源的判据是**本格有没有未落盘的本地乐观值**
    //   （[OfficeSheetCellValue.pending]），**不是**"编辑控制器存不存在"。
    //   旧实现用 `edit == null` 判定 ⇒ 只要协作会话建起来（`edit` 非 null），
    //   整表就退回原始值：公式格显示 `=SUM(B13:B21)`、数字格式一并丢失
    //   （真机缺陷，`docs/osheet-formula-fix-report.md` §机制复核）。
    final hasLocalOverlay = cellValue?.pending ?? false;
    // O3：公式**求值**（只读路径）。没有本地乐观值时求值；求不出 → 退化公式原文。
    final formulaResult = !hasLocalOverlay && isFormula
        ? formulas.resolveCell(r, c)
        : null;
    // 编辑层的 base（含**远端广播**与**已确认的本地改动**）。它与文件原值**相同**
    // 时以文件/求值为准（既有契约不变）；**不同**时以编辑层为准 —— 否则远端或
    // 已确认的改动会被文件原值盖回去（既有用例 "远端改动会刷新网格" 断言这一点）。
    final editedDiffers = !hasLocalOverlay &&
        (cellValue?.present ?? false) &&
        cellValue!.value != workbookCell?.value;
    final Object? value;
    final String rawText;
    if (hasLocalOverlay) {
      // 本地乐观值：**原样**显示（保持编辑手感，不套数字格式）。
      value = cellValue?.value;
      rawText = cellValue?.value == null ? '' : '${cellValue!.value}';
    } else if (editedDiffers) {
      value = cellValue.value;
      rawText = cellValue.value == null ? '' : '${cellValue.value}';
    } else if (formulaResult == null) {
      value = workbookCell?.value;
      rawText = workbookCell?.text ?? '';
    } else if (formulaResult.isError) {
      value = formulaResult.errorCode;
      rawText = formulaResult.errorCode ?? '';
    } else if (formulaResult.isUnsupported) {
      value = workbookCell?.value;
      rawText = workbookCell?.text ?? '';
    } else {
      value = formulaResult.value;
      rawText = asJsonScalarText(formulaResult.value) ?? '';
    }
    final pending = edit?.isPending(r, c) ?? false;

    // 批 D：**先解引用共享样式表**（字体/填充/边框/对齐/数字格式），再叠加命中的
    // 条件格式样式。绝不把 `styles[i]` 当颜色用。
    final baseStyle = officeSheetResolveStyle(
      pool: pool,
      styleId: workbookCell?.styleIndex,
    );
    final hits = officeSheetConditionalAt(cfs, r, c);
    final style = officeSheetApplyConditionalFormats(baseStyle, hits);

    // ★ 数字格式（O2）：数值按 `numberFormats[].fc` 渲染显示值。
    //   R17 修复：**只有本地乐观值不套格式**（那是用户正在敲的原始文本）；
    //   文件值、公式求值结果、远端值、已确认的本地改动都按文件声明的数字格式
    //   渲染（旧实现只在 `edit == null` 时套格式 ⇒ 协作会话一建立格式就丢了）。
    final text = hasLocalOverlay
        ? rawText
        : officeSheetDisplayText(
            value: value,
            rawText: rawText,
            numberFormat: style.numberFormat,
          );

    final align = officeSheetCellAlign(
      pool: pool,
      styleId: workbookCell?.styleIndex,
      value: value,
    );
    final alignment = switch (align) {
      OfficeSheetCellAlign.left => Alignment.centerLeft,
      OfficeSheetCellAlign.center => Alignment.center,
      OfficeSheetCellAlign.right => Alignment.centerRight,
    };
    // 垂直对齐（`alignments[].v`）：真实样本该列已被解析；这里作用在内容层。
    final contentAlignment = switch (style.alignV) {
      'top' => Alignment(alignment.x, -1),
      'bottom' => Alignment(alignment.x, 1),
      _ => alignment,
    };
    final editing =
        edit != null && edit.canEdit && _editRow == r && _editCol == c;
    final interactive = edit != null && edit.canEdit;
    final selected = _selRow == r && _selCol == c;

    Widget content;
    if (editing && _editText != null) {
      content = TextField(
        key: Key('office-sheet-cell-input-$r-$c'),
        controller: _editText,
        focusNode: _editFocus,
        autofocus: true,
        style: Theme.of(context).textTheme.bodySmall,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onSubmitted: (_) => _commitEdit(),
        onTapOutside: (_) => _commitEdit(),
      );
    } else {
      // ★ 文字默认色 = **按填充明暗做对比度判定**（即 OOXML 的"自动"文字色，批 O4）。
      //   文件里显式给了字色 → 下面的 `style.toTextStyle` 会覆盖这个 base 色，
      //   **以文件为准**（`<color rgb>` / `theme` / `indexed` 三种都算显式）。
      //   旧实现直接把 `textTheme.bodySmall` 当 base：深色主题下未声明字色的格子
      //   拿到白字，叠在文件自带的浅灰/浅蓝填充上 = 几乎看不见（本批要修的核心症状）。
      final base = Theme.of(context).textTheme.bodySmall?.copyWith(
        color: officeSheetAutomaticTextColor(style.fillColor),
      );
      final declaredSize =
          style.fontSize ?? base?.fontSize ?? kOfficeSheetDefaultFontSize;
      final textStyle = style
          .toTextStyle(base)
          .copyWith(fontSize: declaredSize * scale);
      content = Text(
        text,
        key: isFormula ? Key('office-sheet-formula-$r-$c') : null,
        maxLines: style.wrap ? null : 1,
        overflow: style.wrap ? TextOverflow.clip : TextOverflow.ellipsis,
        style: pending
            ? textStyle.copyWith(
                fontStyle: FontStyle.italic,
                color: Theme.of(context).colorScheme.tertiary,
              )
            : textStyle,
      );
      // O3：**算出来了**（不是原文退化）→ 额外挂一个可断言的值键。
      if (formulaResult != null && formulaResult.hasValue) {
        content = KeyedSubtree(
          key: Key('office-sheet-formula-value-$r-$c'),
          child: content,
        );
      }
    }
    if (interactive) {
      content = _editableOverlay(r, c, content, contentAlignment);
    } else if (style.alignV == 'top' || style.alignV == 'bottom') {
      content = Align(alignment: contentAlignment, child: content);
    }

    // 边框：**逐边合成**（批 O4 修正）。OOXML 里网格线是"背景层"，单元格边框
    // 是"前景层"叠加在上面 —— 所以某条边文件没写边框时，**该边仍应显示网格线**，
    // 而不是像旧实现那样整格退回 `style.toBoxBorder()`（缺边 = `BorderSide.none`），
    // 把文件没声明的那几条边的网格线一起抹掉。
    //   * 文件给了该边颜色 → 用文件色（以文件为准）；
    //   * 文件没给 + 文件开着网格线 → 用文档网格线色；
    //   * 文件没给 + `<sheetView showGridLines="0">` → 该边不画。
    // 未确认格子仍用 tertiary 高亮覆盖（可编辑态的可见标记，不静默）。
    // 选中格子用描边高亮（UI 状态，非文档内容）。
    final BoxBorder? border;
    if (pending) {
      border = Border.all(
        color: Theme.of(context).colorScheme.tertiary,
        width: 1.5,
      );
    } else if (selected) {
      border = Border.all(color: kOfficeSheetSelectionColor, width: 2);
    } else {
      final gridSide = showGridLines
          ? BorderSide(color: gridLineColor, width: 0.5)
          : BorderSide.none;
      BorderSide edge(Color? declared) =>
          declared == null ? gridSide : BorderSide(color: declared, width: 1);
      border = Border(
        top: edge(style.borderTop),
        right: edge(style.borderRight),
        bottom: edge(style.borderBottom),
        left: edge(style.borderLeft),
      );
    }

    final cell = Container(
      key: Key('office-sheet-cell-$r-$c'),
      width: width,
      height: height,
      padding: EdgeInsets.symmetric(horizontal: Gap.xxs * scale),
      // 只按水平对齐（既有契约；`_cellAlignment` 用例读的就是这个属性），
      // 垂直对齐由上面的内容层 `Align` 承担。
      alignment: alignment,
      decoration: BoxDecoration(
        // ★ 单元格底色**只来自文档**：文件没写填充 = 透明（透出白纸）。
        //   选中态由描边表达，**不再覆盖 `primaryContainer`** —— 那样会在白纸上
        //   压一块深色（深色主题下），把刚修好的对比度又毁掉。
        color: style.fillColor,
        border: border,
      ),
      child: content,
    );
    // 兼容别名：只有**接管旧宿主**（`office_viewer_page.dart` 注入已解析的
    // `workbook`）时才挂旧键 `sheet-cell-r{r}c{c}`；主路径（新页面）只用
    // `office-sheet-cell-r-c`，保持键位方案单一。
    final aliased = widget.workbook == null
        ? cell
        : KeyedSubtree(key: Key('sheet-cell-r${r}c$c'), child: cell);

    if (interactive) return aliased;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        _selRow = r;
        _selCol = c;
      }),
      child: aliased,
    );
  }

  Widget _card({
    required Key key,
    required IconData icon,
    required String text,
    String? hint,
  }) {
    return Center(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36),
            const SizedBox(height: Gap.md),
            Text(text, textAlign: TextAlign.center),
            if (hint != null) ...[
              const SizedBox(height: Gap.sm),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
