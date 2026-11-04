// `.osheet`（Synology Office 电子表格）的**只读**模型（纯 Dart；不 import flutter/l10n）。
//
// 证据（`docs/office-native-format-research.md` §4.2/§9.1，全部来自官方模板样本
// `template/sheet/*/text.json` —— 它们就是 `.osheet` 解密后的 section 字典）：
//   - 顶层 section：`index` / `style` / `define` / `comment` / `sh_<n>`（可选
//     `protection` / `externals` / `pivotCaches` / `pivotTables` / `file` / `locale`）；
//   - 单元格**稀疏**：`sheet.cells["<row>"]["<col>"] = {"s": <style id>, "v": <值>}`；
//     `v` 是 string 或 number；
//   - `index.order` 给出工作表顺序；`index.sheets[id].title` 是表名；
//   - `index.schemaVersion` / `index.ver` / `index.gcVer` / `index.maxIndex`。
//
// ⚠️ 推测/推断（研究文档 §8.2）：
//   - 单元格公式字段名 `f`：**样本里没有任何实例**，是**推测**；本模型提供
//     [OSheetCell.formula] 但注释与文档都明确标注"推测"，且测试**不**把它当事实。
//   - `s` 到 `style.styles[]` 的**基址**：官方只说"s 是 style 索引"。
//     13 份样本实测 `max(s) == styles.length`（如 invoice 1..57 / 57 条，
//     project_timeline 101..158 / 158 条），0 基会越界，所以本模型按
//     **1 基、`s=0` = 无样式** 解释（[OSheetStylePool.styleAt]）；这是**推断**。
//   - `styles[]` 条目实测是 6 个整数（槽位），**槽位语义未取证**；
//     [OSheetStylePool.slotsAt] 只如实返回这 6 个数，不臆造"第 0 个是字体"。
//   - `mergeCells` 的 `[a,b,c,d]` 四元组含义（推测 startRow/startCol/endRow/endCol）
//     同样标为推测，模型只原样保留。

import 'office_json.dart';

/// 冻结窗格 / 行列尺寸的**显示缺省**（文件没写 `global.h`/`global.w` 时用）。
///
/// 真实 NAS 文件（3 份 `.osheet`，2026-09 只读取证）的 `sh_N.global` **全部为
/// `null`**，而 `sh_N.rows` / `sh_N.cols` 逐条给出真实尺寸（列宽 20…504，行高
/// 21…364）。所以缺省只在文件**确实没声明**的那一行/列上生效。
const double kOSheetDefaultRowHeight = 22;
const double kOSheetDefaultColWidth = 96;

/// `sh_N.fixedRowTop` 的显示语义：前 N 行冻结（`0` = 不冻结）。
///
/// 取证（`Annual income and expenditure.osheet`）：`fixedRowTop = 10`、
/// `fixedColumnLeft = 0`。字段名与语义见 `office_sheet_schema.dart` 的
/// `kOfficeSheetWorksheetKeys`（该表早已登记，但**此前没有任何地方读它**）。
const int kOSheetMinFrozenRows = 0;

/// 合并单元格区间：真实 `sh_N.mergeCells` 的 `[r1,c1,r2,c2]` 四元组。
///
/// **取证原文**（`Annual income and expenditure.osheet`）：
/// `"mergeCells": [[0,0,0,14],[2,1,2,2]]` —— 第 0 行的 A1:O1（跨 15 列）与
/// B3:C3。`Travel expenses.osheet` 有 30 个区间（`[2,1,2,10]`、`[13,1,13,8]` …），
/// 全部满足 `r1<=r2`、`c1<=c2` 且行列都是**闭区间**（0 基）。
class OSheetMergeRange {
  const OSheetMergeRange(this.row1, this.col1, this.row2, this.col2);

  final int row1;
  final int col1;
  final int row2;
  final int col2;

  int get rowSpan => row2 - row1 + 1;
  int get colSpan => col2 - col1 + 1;

  bool contains(int row, int col) =>
      row >= row1 && row <= row2 && col >= col1 && col <= col2;

  bool isAnchor(int row, int col) => row == row1 && col == col1;

  /// A1 记法（`A1:O1`）；仅用于诊断/报告。
  String get a1 =>
      '${oSheetColumnLabel(col1)}${row1 + 1}:'
      '${oSheetColumnLabel(col2)}${row2 + 1}';

  @override
  String toString() => 'OSheetMergeRange($a1)';

  @override
  bool operator ==(Object other) =>
      other is OSheetMergeRange &&
      other.row1 == row1 &&
      other.col1 == col1 &&
      other.row2 == row2 &&
      other.col2 == col2;

  @override
  int get hashCode => Object.hash(row1, col1, row2, col2);
}

/// 列标（`A`…`Z`、`AA`…）——纯 Dart，模型层自用（与
/// `office_sheet_style.dart` 的 `officeSheetColumnLabel` 同一算法）。
String oSheetColumnLabel(int colIndex) {
  var n = colIndex + 1;
  var out = '';
  while (n > 0) {
    n -= 1;
    out = String.fromCharCode(65 + (n % 26)) + out;
    n ~/= 26;
  }
  return out;
}

/// 单个单元格。
class OSheetCell {
  const OSheetCell({
    required this.row,
    required this.col,
    this.styleIndex,
    this.value,
    this.formula,
  });

  final int row;
  final int col;

  /// `s`：`style.styles[]` 下标（样式索引）。
  final int? styleIndex;

  /// `v`：值（string / number）。
  final Object? value;

  /// `f`：公式字段。**字段名是推测**（研究文档 §8.2；官方样本中无实例）。
  ///
  /// ⚠️ **真实文件否证（2026-09，2 份 `.osheet` 实测）**：真实单元格只有
  /// `s`/`v` 两个键，**没有 `f`**；公式是 **`v` 字符串以 `=` 开头**
  /// （`Travel expenses` 30 个、`Annual income` 257 个，如 `=C7-C9`、
  /// `=SUMIF($F$17:$F$31,"="&F11,$I$17:$I$31)`）。见 [isFormula]/[formulaText]。
  final String? formula;

  /// 真实公式：`v` 是字符串且以 `=` 开头（**真实文件实测**）。
  bool get isFormula => value is String && (value! as String).startsWith('=');

  /// 真实公式文本（`v` 本身）；不是公式时为 `null`。
  String? get formulaText => isFormula ? value! as String : null;

  bool get hasValue => value != null;

  bool get hasStyle => styleIndex != null;

  /// 展示文本；无值时为 `null`（**不是**空串，便于区分"空单元格"）。
  String? get text => asJsonScalarText(value);

  @override
  String toString() =>
      'OSheetCell(r$row,c$col, s=$styleIndex, v=$value, f=$formula)';
}

/// 一张工作表（`sh_<n>` section）。
class OSheetSheet {
  OSheetSheet({
    required this.id,
    required this.title,
    required this.rowCount,
    required this.colCount,
    required this.cells,
    required this.raw,
    this.isVisible = true,
    this.fixedRowTop = 0,
    this.fixedColumnLeft = 0,
    this.defaultRowHeight,
    this.defaultColWidth,
    Map<int, double>? rowHeights,
    Map<int, double>? colWidths,
    Set<int>? hiddenRows,
    Set<int>? hiddenCols,
    List<OSheetMergeRange>? mergedRegions,
  }) : rowHeights = rowHeights ?? const <int, double>{},
       colWidths = colWidths ?? const <int, double>{},
       hiddenRows = hiddenRows ?? const <int>{},
       hiddenCols = hiddenCols ?? const <int>{},
       mergedRegions = mergedRegions ?? const <OSheetMergeRange>[];

  final String id;
  final String title;
  final int rowCount;
  final int colCount;

  /// 稀疏表：row -> col -> cell（只存真实存在的单元格）。
  final Map<int, Map<int, OSheetCell>> cells;

  /// 原始 section JSON（未建模字段原样保留，供后续批次使用）。
  final Map<String, Object?> raw;

  /// 是否可见：由 `index.sheets[id].deleted` 反推（`deleted==true` → 隐藏）。
  ///
  /// 真实文件的 `index.sheets` 只有 `title` / `deleted` 两个键（取证原文：
  /// `{"deleted": false, "title": "Annual Income and Expenditure"}`），
  /// **没有**单独的 `hidden` 标志，所以可见性只能由 `deleted` 推出。
  final bool isVisible;

  /// `sh_N.fixedRowTop`：前 N 行冻结（真实文件 `Annual income` = 10）。
  final int fixedRowTop;

  /// `sh_N.fixedColumnLeft`：前 N 列冻结（真实文件均为 0）。
  final int fixedColumnLeft;

  /// `sh_N.global.h`（OFile 路径；真实 OFile 文件全部为 `null`）。
  /// OOXML 路径来自 `<sheetFormatPr defaultRowHeight="15.75">`（pt→px 后为 double）。
  final double? defaultRowHeight;

  /// `sh_N.global.w`（OFile 路径；真实 OFile 文件全部为 `null`）。
  /// OOXML 路径来自 `<sheetFormatPr defaultColWidth="14.4286">`。
  final double? defaultColWidth;

  /// `sh_N.rows["<r>"].h`（只存显式声明的行高）。
  final Map<int, double> rowHeights;

  /// `sh_N.cols["<c>"].w`（只存显式声明的列宽）。
  final Map<int, double> colWidths;

  /// `sh_N.rows["<r>"].hidden == true`。
  final Set<int> hiddenRows;

  /// `sh_N.cols["<c>"].hidden == true`。
  final Set<int> hiddenCols;

  /// `sh_N.mergeCells` 归一化后的区间（`[r1,c1,r2,c2]`，闭区间，0 基）。
  final List<OSheetMergeRange> mergedRegions;

  OSheetCell? cellAt(int row, int col) => cells[row]?[col];

  Iterable<OSheetCell> get allCells => cells.values.expand((row) => row.values);

  int get cellCount => allCells.length;

  int get valueCellCount => allCells.where((c) => c.hasValue).length;

  /// 该列**实际用于布局**的宽度：文件声明优先，否则 `global.w`，再否则缺省。
  double colWidthAt(int col) =>
      colWidths[col] ?? defaultColWidth ?? kOSheetDefaultColWidth;

  /// 该行**实际用于布局**的高度（优先级同 [colWidthAt]）。
  double rowHeightAt(int row) =>
      rowHeights[row] ?? defaultRowHeight ?? kOSheetDefaultRowHeight;

  bool isColHidden(int col) => hiddenCols.contains(col);

  bool isRowHidden(int row) => hiddenRows.contains(row);

  /// 命中 [row]/[col] 的合并区间（含被覆盖格）；不在任何区间 → `null`。
  OSheetMergeRange? mergeRangeAt(int row, int col) {
    for (final region in mergedRegions) {
      if (region.contains(row, col)) return region;
    }
    return null;
  }

  /// 是否是合并区的左上锚点。
  OSheetMergeRange? mergeAnchorAt(int row, int col) {
    for (final region in mergedRegions) {
      if (region.isAnchor(row, col)) return region;
    }
    return null;
  }

  /// `mergeCells` 原样四元组；含义是**推测**（见文件头）。
  List<List<int>> get mergeCellRanges =>
      (asJsonList(raw['mergeCells']) ?? const [])
          .map(
            (e) => (asJsonList(e) ?? const [])
                .map((n) => asJsonInt(n) ?? 0)
                .toList(growable: false),
          )
          .toList(growable: false);

  /// 稠密网格（rowCount x colCount）的**文本**；空单元格为 `null`。
  List<List<String?>> toTextGrid() {
    return List.generate(
      rowCount,
      (r) => List.generate(colCount, (c) => cellAt(r, c)?.text),
      growable: false,
    );
  }

  /// 稠密网格的**原值**（可能是 String/num）；空单元格为 `null`。
  List<List<Object?>> toValueGrid() {
    return List.generate(
      rowCount,
      (r) => List.generate(colCount, (c) => cellAt(r, c)?.value),
      growable: false,
    );
  }

  /// 非空文本按行拼成的纯文本（供检索/预览用）。
  String get plainText {
    final rows = <String>[];
    final sortedRows = cells.keys.toList()..sort();
    for (final r in sortedRows) {
      final cols = cells[r]!.keys.toList()..sort();
      final cellsText = <String>[];
      for (final c in cols) {
        final t = cells[r]![c]!.text;
        if (t != null && t.isNotEmpty) cellsText.add(t);
      }
      if (cellsText.isNotEmpty) rows.add(cellsText.join('\t'));
    }
    return rows.join('\n');
  }
}

/// `style` section 的样式池。
class OSheetStylePool {
  OSheetStylePool({
    required this.styles,
    required this.fonts,
    required this.fills,
    required this.alignments,
    required this.borders,
    required this.numberFormats,
    required this.raw,
  });

  final List<Object?> styles;
  final List<Object?> fonts;
  final List<Object?> fills;
  final List<Object?> alignments;
  final List<Object?> borders;
  final List<Object?> numberFormats;
  final Map<String, Object?> raw;

  int get styleCount => styles.length;

  /// 单元格里的 `s` 是**样式 id**，在这 13 份官方样本上实测满足：
  /// `min(s) >= 0`、`max(s) <= styles.length`，且当 `s>0` 时 `max(s) == styles.length`
  /// （`annual_income_and_expenditure`: 1..62 / 62 条；`invoice`: 1..57 / 57 条；
  /// `project_timeline`: 101..158 / 158 条）。
  ///
  /// 因此 [styleAt] 采用"**1 基、`s=0` 表示无样式**"的读法，但这属于**推断**
  /// （研究文档 §8.2 只把 `s` 记为"style 索引"，未定义基址；这里给出的是
  /// 13 份样本一致支持的解释，不是官方文档）：
  ///   - `s<=0` 或 `s>styles.length` → `null`；
  ///   - 否则 → `styles[s-1]`（长度 6 的整数槽位数组）。
  Object? styleAt(int styleId) {
    if (styleId < 1 || styleId > styles.length) return null;
    return styles[styleId - 1];
  }

  /// [styleAt] 的槽位形式（长度 6 的整数数组）；**槽位语义未取证**（推测见文件头）。
  List<int>? slotsAt(int styleId) {
    final raw = asJsonList(styleAt(styleId));
    if (raw == null) return null;
    return raw.map((e) => asJsonInt(e) ?? 0).toList(growable: false);
  }

  /// 直接按下标访问原始 `styles[]`（0 基；给需要自行解释 `s` 的调用方）。
  Object? rawStyleAt(int listIndex) =>
      (listIndex >= 0 && listIndex < styles.length) ? styles[listIndex] : null;

  // -------------------------------------------------------------------------
  // 1 基子表访问（槽位顺序取证原文见 [resolveStyle]）
  // -------------------------------------------------------------------------

  /// `fonts[fontId-1]`（`{n,b,i,u,c,sz}`）；越界/无 → `null`。
  Map<String, Object?>? fontAt(int fontId) => _poolAt(fonts, fontId);

  /// `fills[fillId-1]`（`{bg}`）；越界/无 → `null`。
  Map<String, Object?>? fillAt(int fillId) => _poolAt(fills, fillId);

  /// `alignments[alignmentId-1]`（`{h,v,w}`）；越界/无 → `null`。
  Map<String, Object?>? alignmentAt(int alignmentId) =>
      _poolAt(alignments, alignmentId);

  /// `borders[borderId-1]`（`{b:[top,right,bottom,left]}`）；越界/无 → `null`。
  Map<String, Object?>? borderAt(int borderId) => _poolAt(borders, borderId);

  /// `numberFormats[nfId-1]`（`{fc}`）；越界/无 → `null`。
  Map<String, Object?>? numberFormatAt(int nfId) =>
      _poolAt(numberFormats, nfId);

  static Map<String, Object?>? _poolAt(List<Object?> pool, int id) {
    if (id < 1 || id > pool.length) return null;
    return asJsonMap(pool[id - 1]);
  }

  /// 把 `styles[s-1]` 解引用成**纯 Dart** 的 [OSheetCellStyle]（无 Flutter 依赖）。
  ///
  /// 槽位顺序的**取证原文**（NAS `Annual income and expenditure.osheet`，
  /// `style.styles[0] == [35,0,0,6,0,0]`，`style.alignments[5]` 存在而
  /// `style.alignments[6]` 不存在）：
  ///
  ///   `[refCount, fontId, fillId, alignmentId, borderId, nfId, +!!quotePrefix]`
  ///
  /// 与服务端束 `@ss/core.js` 的 `CellStyle.toJSON()` 一致；每个池 `toJSON()`
  /// 丢掉下标 0（默认样式） ⇒ **1 基**：`s=0` = 无样式。
  OSheetCellStyle resolveStyle(int? styleId) {
    if (styleId == null || styleId < 1) return const OSheetCellStyle();
    final slots = slotsAt(styleId);
    if (slots == null) return const OSheetCellStyle();

    String? fontColorHex;
    String? fontFamily;
    double? fontSize;
    var bold = false;
    var italic = false;
    var underline = false;
    final font = slots.length > kOSheetSlotFont
        ? fontAt(slots[kOSheetSlotFont])
        : null;
    if (font != null) {
      fontColorHex = asJsonString(font['c']);
      fontFamily = asJsonString(font['n']);
      fontSize = asJsonDouble(font['sz']);
      bold = font['b'] == true;
      italic = font['i'] == true;
      underline = font['u'] == true;
    }

    final fill = slots.length > kOSheetSlotFill
        ? fillAt(slots[kOSheetSlotFill])
        : null;
    final fillColorHex = asJsonString(fill?['bg']);

    String? alignH;
    String? alignV;
    var wrap = false;
    final alignment = slots.length > kOSheetSlotAlignment
        ? alignmentAt(slots[kOSheetSlotAlignment])
        : null;
    if (alignment != null) {
      alignH = asJsonString(alignment['h']);
      alignV = asJsonString(alignment['v']);
      wrap = asJsonString(alignment['w']) == 'wrap';
    }

    String? borderTopHex;
    String? borderRightHex;
    String? borderBottomHex;
    String? borderLeftHex;
    final border = slots.length > kOSheetSlotBorder
        ? borderAt(slots[kOSheetSlotBorder])
        : null;
    final sides = asJsonList(border?['b']);
    if (sides != null) {
      String? sideAt(int i) => i < sides.length ? asJsonString(sides[i]) : null;
      borderTopHex = sideAt(0);
      borderRightHex = sideAt(1);
      borderBottomHex = sideAt(2);
      borderLeftHex = sideAt(3);
    }

    final numberFormat = slots.length > kOSheetSlotNumberFormat
        ? asJsonString(numberFormatAt(slots[kOSheetSlotNumberFormat])?['fc'])
        : null;

    return OSheetCellStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontColorHex: fontColorHex,
      bold: bold,
      italic: italic,
      underline: underline,
      fillColorHex: fillColorHex,
      alignH: alignH,
      alignV: alignV,
      wrap: wrap,
      borderTopHex: borderTopHex,
      borderRightHex: borderRightHex,
      borderBottomHex: borderBottomHex,
      borderLeftHex: borderLeftHex,
      numberFormat: numberFormat,
    );
  }
}

/// `styles[i]` 的槽位下标（服务端 `CellStyle.toJSON()` 顺序）。
const int kOSheetSlotRefCount = 0;
const int kOSheetSlotFont = 1;
const int kOSheetSlotFill = 2;
const int kOSheetSlotAlignment = 3;
const int kOSheetSlotBorder = 4;
const int kOSheetSlotNumberFormat = 5;

/// 解引用后的单元格样式（**纯 Dart**：颜色是原始 hex 串，不依赖 Flutter）。
class OSheetCellStyle {
  const OSheetCellStyle({
    this.fontFamily,
    this.fontSize,
    this.fontColorHex,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.fillColorHex,
    this.alignH,
    this.alignV,
    this.wrap = false,
    this.borderTopHex,
    this.borderRightHex,
    this.borderBottomHex,
    this.borderLeftHex,
    this.numberFormat,
  });

  final String? fontFamily;
  final double? fontSize;
  final String? fontColorHex;
  final bool bold;
  final bool italic;
  final bool underline;

  /// `fills[].bg`（真实样本是**裸 hex**，如 `4dbf7c`、`e6faee`）。
  final String? fillColorHex;

  /// `alignments[].h`（`left`/`center`/`right`）。
  final String? alignH;

  /// `alignments[].v`（`middle`/`top`/`bottom`）。
  final String? alignV;

  /// `alignments[].w == "wrap"`。
  final bool wrap;

  /// `borders[].b = [top,right,bottom,left]`（真实样本带 `#`，如 `#000000`）。
  final String? borderTopHex;
  final String? borderRightHex;
  final String? borderBottomHex;
  final String? borderLeftHex;

  /// `numberFormats[].fc` 的原始模式串（Excel 语法）。
  final String? numberFormat;

  bool get hasFont =>
      fontFamily != null ||
      fontSize != null ||
      fontColorHex != null ||
      bold ||
      italic ||
      underline;

  bool get hasBorder =>
      borderTopHex != null ||
      borderRightHex != null ||
      borderBottomHex != null ||
      borderLeftHex != null;

  bool get isEmpty =>
      !hasFont &&
      fillColorHex == null &&
      !hasBorder &&
      alignH == null &&
      alignV == null &&
      !wrap &&
      numberFormat == null;

  @override
  String toString() =>
      'OSheetCellStyle(font: $fontFamily/$fontSize/$fontColorHex, '
      'bold=$bold, fill=$fillColorHex, align=$alignH/$alignV, wrap=$wrap, '
      'nf=$numberFormat)';
}

/// `index` section。
class OSheetIndex {
  OSheetIndex({
    required this.schemaVersion,
    required this.ver,
    required this.gcVer,
    required this.maxIndex,
    required this.order,
    required this.sheetTitles,
    required this.deleted,
    required this.raw,
  });

  final int? schemaVersion;
  final int? ver;
  final int? gcVer;
  final int? maxIndex;

  /// `index.order`（工作表顺序）。
  final List<String> order;

  /// `index.sheets[id].title`。
  final Map<String, String> sheetTitles;

  /// `index.sheets[id].deleted`。
  final Map<String, bool> deleted;

  final Map<String, Object?> raw;

  static OSheetIndex fromJson(Map<String, Object?> index) {
    final sheets = asJsonMap(index['sheets']) ?? const {};
    final titles = <String, String>{};
    final deleted = <String, bool>{};
    for (final entry in sheets.entries) {
      final def = asJsonMap(entry.value);
      titles[entry.key] = asJsonString(def?['title']) ?? entry.key;
      deleted[entry.key] = def?['deleted'] == true;
    }
    final order = (asJsonList(index['order']) ?? const [])
        .map((e) => asJsonString(e))
        .whereType<String>()
        .toList(growable: false);
    return OSheetIndex(
      schemaVersion: asJsonInt(index['schemaVersion']),
      ver: asJsonInt(index['ver']),
      gcVer: asJsonInt(index['gcVer']),
      maxIndex: asJsonInt(index['maxIndex']),
      order: order.isEmpty ? sheets.keys.toList(growable: false) : order,
      sheetTitles: titles,
      deleted: deleted,
      raw: index,
    );
  }
}

/// 整个工作簿。
class OSheetWorkbook {
  OSheetWorkbook({
    required this.index,
    required this.sheets,
    required this.styles,
    required this.sectionNames,
  });

  final OSheetIndex index;

  /// 按 [OSheetIndex.order] 排序的工作表。
  final List<OSheetSheet> sheets;

  final OSheetStylePool? styles;

  /// 该 payload 里出现过的全部 section 名（保留证据，便于报告缺口）。
  final List<String> sectionNames;

  OSheetSheet? sheetById(String id) {
    for (final s in sheets) {
      if (s.id == id) return s;
    }
    return null;
  }

  int get totalCellCount => sheets.fold(0, (sum, s) => sum + s.cellCount);

  int get totalValueCellCount =>
      sheets.fold(0, (sum, s) => sum + s.valueCellCount);

  /// 从 `.osheet` 解密后的 section 字典构造。
  static OSheetWorkbook fromSections(Map<String, Object?> sections) {
    final index = OSheetIndex.fromJson(
      asJsonMap(sections['index']) ?? const {},
    );
    final styleRaw = asJsonMap(sections['style']);
    final stylePool = styleRaw == null
        ? null
        : OSheetStylePool(
            styles: asJsonList(styleRaw['styles']) ?? const [],
            fonts: asJsonList(styleRaw['fonts']) ?? const [],
            fills: asJsonList(styleRaw['fills']) ?? const [],
            alignments: asJsonList(styleRaw['alignments']) ?? const [],
            borders: asJsonList(styleRaw['borders']) ?? const [],
            numberFormats: asJsonList(styleRaw['numberFormats']) ?? const [],
            raw: styleRaw,
          );

    final sheetSections = sections.keys
        .where((k) => k.startsWith('sh_'))
        .toList(growable: false);

    // 按 index.order 排；order 里有但缺 section 的跳过（如实反映缺样）。
    final ordered = <String>[];
    for (final id in index.order) {
      if (sheetSections.contains(id)) ordered.add(id);
    }
    for (final id in sheetSections) {
      if (!ordered.contains(id)) ordered.add(id);
    }

    final sheets = <OSheetSheet>[];
    for (final id in ordered) {
      final raw = asJsonMap(sections[id]) ?? const <String, Object?>{};
      sheets.add(
        _parseSheet(
          id,
          index.sheetTitles[id] ?? id,
          raw,
          isVisible: !(index.deleted[id] ?? false),
        ),
      );
    }

    return OSheetWorkbook(
      index: index,
      sheets: sheets,
      styles: stylePool,
      sectionNames: sections.keys.toList(growable: false),
    );
  }

  static OSheetSheet _parseSheet(
    String id,
    String title,
    Map<String, Object?> raw, {
    bool isVisible = true,
  }) {
    final cellsRaw = asJsonMap(raw['cells']) ?? const {};
    final cells = <int, Map<int, OSheetCell>>{};
    for (final rowEntry in cellsRaw.entries) {
      final row = int.tryParse(rowEntry.key);
      if (row == null) continue;
      final rowMap = asJsonMap(rowEntry.value);
      if (rowMap == null) continue;
      final cols = <int, OSheetCell>{};
      for (final colEntry in rowMap.entries) {
        final col = int.tryParse(colEntry.key);
        if (col == null) continue;
        final cellRaw = asJsonMap(colEntry.value) ?? const {};
        cols[col] = OSheetCell(
          row: row,
          col: col,
          styleIndex: asJsonInt(cellRaw['s']),
          value: cellRaw['v'],
          // 「f」是研究文档 §8.2 标为**推测**的公式字段名。
          formula: asJsonString(cellRaw['f']),
        );
      }
      if (cols.isNotEmpty) cells[row] = cols;
    }

    // 行高 / 列宽 / 隐藏（真实文件逐条声明；`global` 为 null 时只作缺省）。
    final rowHeights = <int, double>{};
    final hiddenRows = <int>{};
    final rowsRaw = asJsonMap(raw['rows']);
    if (rowsRaw != null) {
      for (final entry in rowsRaw.entries) {
        final r = int.tryParse(entry.key);
        if (r == null) continue;
        final def = asJsonMap(entry.value);
        if (def == null) continue;
        final h = asJsonDouble(def['h']);
        if (h != null && h > 0) rowHeights[r] = h;
        if (def['hidden'] == true) hiddenRows.add(r);
      }
    }
    final colWidths = <int, double>{};
    final hiddenCols = <int>{};
    final colsRaw = asJsonMap(raw['cols']);
    if (colsRaw != null) {
      for (final entry in colsRaw.entries) {
        final c = int.tryParse(entry.key);
        if (c == null) continue;
        final def = asJsonMap(entry.value);
        if (def == null) continue;
        final w = asJsonDouble(def['w']);
        if (w != null && w > 0) colWidths[c] = w;
        if (def['hidden'] == true) hiddenCols.add(c);
      }
    }

    return OSheetSheet(
      id: id,
      title: title,
      rowCount: asJsonInt(raw['rowCount']) ?? 0,
      colCount: asJsonInt(raw['colCount']) ?? 0,
      cells: cells,
      raw: raw,
      isVisible: isVisible,
      fixedRowTop: asJsonInt(raw['fixedRowTop']) ?? 0,
      fixedColumnLeft: asJsonInt(raw['fixedColumnLeft']) ?? 0,
      defaultRowHeight: asJsonDouble(asJsonMap(raw['global'])?['h']),
      defaultColWidth: asJsonDouble(asJsonMap(raw['global'])?['w']),
      rowHeights: rowHeights,
      colWidths: colWidths,
      hiddenRows: hiddenRows,
      hiddenCols: hiddenCols,
      mergedRegions: oSheetMergeRanges(raw['mergeCells']),
    );
  }
}

/// 解析 `sh_N.mergeCells` → 归一化区间；坏项丢弃（不崩、不猜）。
List<OSheetMergeRange> oSheetMergeRanges(Object? rawMergeCells) {
  final list = asJsonList(rawMergeCells);
  if (list == null) return const <OSheetMergeRange>[];
  final out = <OSheetMergeRange>[];
  final seen = <String>{};
  for (final entry in list) {
    final quad = asJsonList(entry);
    if (quad == null || quad.length != 4) continue;
    final a = asJsonInt(quad[0]);
    final b = asJsonInt(quad[1]);
    final c = asJsonInt(quad[2]);
    final d = asJsonInt(quad[3]);
    if (a == null || b == null || c == null || d == null) continue;
    final r1 = a < c ? a : c;
    final r2 = a < c ? c : a;
    final c1 = b < d ? b : d;
    final c2 = b < d ? d : b;
    if (r1 < 0 || c1 < 0) continue;
    if (!seen.add('$r1:$c1:$r2:$c2')) continue;
    out.add(OSheetMergeRange(r1, c1, r2, c2));
  }
  return out;
}

// ---------------------------------------------------------------------------
// 数字格式（`numberFormats[].fc`）：把数值渲染成**声明过的显示形态**
// ---------------------------------------------------------------------------
//
// **取证原文**（NAS 真实 `.osheet`，`style.numberFormats`）：
//
//   Annual income and expenditure:
//     [{"fc":"#,##0"}, {"fc":"#,##0.00;(#,##0.00)"}]
//     → 命中 `1,234` / `1,234.00` 两类（`nfId` 直方图 884 / 98 / 263）
//   Sales tracker:
//     [{"fc":"\"$\"#,##0.00"}, {"fc":"0.00%"}, {"fc":"#,##0"}, {"fc":"[$$]#,##0.00"}]
//     → (10,3)=0.9 用 `0.00%` → `90.00%`；(10,8)=5.75 用 `[$$]#,##0.00` → `$5.75`
//   Travel expenses:
//     `"$"#,##0.00_);[Red]\("$"#,##0.00\)`、`0%`、`"$"#,##0`、`#,##0.00`、
//     `_(* #,##0.00_);...`、`_("$"* #,##0.00_);...`、`[$$]#,##0.00`
//
// 上一批（批 D）曾把 `numberFormats` **只解引用、不重排**，理由是"`s` 到 `fc`
// 的归属在真实样本上不成立"。**O2 取证否证了这条理由**：`to_do_list_simple` 的
// `styles[8] == [60,8,0,3,0,0,0]`（`nfId == 0`，**不是**批 D 注释里写的
// `[60,8,0,3,0,1,0]`），而真正带 `M/d/yyyy` 的 (3,3) 是日期序列号 `42668`。
// ⇒ 槽位归属是成立的，数字格式**按声明渲染**。
//
// 纪律：**只做显示**，不改 `v`；**认不出的模式返回 `null`**，调用方原样显示。
// 公式（以 `=` 开头）**不求值、不套格式**。

/// 把数值渲染成 Excel 风格数字格式；不可解释/非数值 → `null`。
String? oSheetFormatNumber(Object? value, String? pattern) {
  if (pattern == null) return null;
  final fmt = pattern.trim();
  if (fmt.isEmpty) return null;
  if (value is! num) return null;

  // 日期/时间形态优先（真实样本的 `M/d/yyyy`）。
  final date = oSheetFormatSerialDate(value, fmt);
  if (date != null) return date;

  final sections = _oSheetFormatSections(fmt);
  if (sections.isEmpty) return null;

  final n = value.toDouble();
  final List<_OSheetFormatToken> tokens;
  final bool negativeSection;
  if (n < 0 && sections.length > 1) {
    tokens = sections[1];
    negativeSection = true;
  } else if (n == 0 && sections.length > 2) {
    tokens = sections[2];
    negativeSection = false;
  } else {
    tokens = sections[0];
    negativeSection = false;
  }

  var maskIndex = -1;
  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i].isMask) {
      maskIndex = i;
      break;
    }
  }
  if (maskIndex < 0) return null;

  final mask = tokens[maskIndex].text;
  var prefix = tokens.take(maskIndex).map((t) => t.text).join();
  var suffix = tokens.skip(maskIndex + 1).map((t) => t.text).join();

  final percent = mask.contains('%');
  final digits = mask.replaceAll('%', '');
  final dot = digits.indexOf('.');
  final intPart = dot < 0 ? digits : digits.substring(0, dot);
  final fracPart = dot < 0 ? '' : digits.substring(dot + 1);
  final decimals = fracPart.replaceAll(RegExp(r'[^0#?]'), '').length;
  final grouping = intPart.contains(',');
  final hasMinIntDigit = intPart.contains('0');

  // 零值 + 全部是 `?` 占位（会计格式 `_(* "-"??_)`）→ 只留字面量（"-"）。
  if (n == 0 &&
      !hasMinIntDigit &&
      intPart.replaceAll(RegExp(r'[^?]'), '').isNotEmpty) {
    return '$prefix$suffix';
  }

  var v = n.abs();
  if (percent) v = v * 100;
  var text = v.toStringAsFixed(decimals);
  if (grouping) text = _oSheetGroupDigits(text);

  // 负号：负号区间（第 2 段）**自带** `-` 或括号字面量时不再补；
  // 只有"用正号区间渲染负数"时才补一个 `-`。
  if (n < 0 && !negativeSection) {
    if (!prefix.contains('-') && !prefix.contains('(')) prefix = '-$prefix';
  }
  if (percent && !suffix.contains('%')) suffix = '$suffix%';
  return '$prefix$text$suffix';
}

/// 千分位分组（只处理整数部分）。
String _oSheetGroupDigits(String text) {
  final dot = text.indexOf('.');
  final intPart = dot < 0 ? text : text.substring(0, dot);
  final rest = dot < 0 ? '' : text.substring(dot);
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  return '$buf$rest';
}

/// 一个已解析的格式片段：字面量或数字占位段。
class _OSheetFormatToken {
  const _OSheetFormatToken(this.text, {required this.isMask});
  final String text;
  final bool isMask;
}

/// 按 `;` 切分格式段（**不切引号内 / `[]` 内 / 转义后的 `;`**）。
List<List<_OSheetFormatToken>> _oSheetFormatSections(String fmt) {
  final raw = <String>[];
  final buf = StringBuffer();
  var inQuote = false;
  var inBracket = false;
  for (var i = 0; i < fmt.length; i++) {
    final ch = fmt[i];
    if (inQuote) {
      buf.write(ch);
      if (ch == '"') inQuote = false;
      continue;
    }
    if (inBracket) {
      buf.write(ch);
      if (ch == ']') inBracket = false;
      continue;
    }
    if (ch == '\\') {
      buf.write(ch);
      if (i + 1 < fmt.length) buf.write(fmt[++i]);
      continue;
    }
    if (ch == '"') {
      inQuote = true;
      buf.write(ch);
      continue;
    }
    if (ch == '[') {
      inBracket = true;
      buf.write(ch);
      continue;
    }
    if (ch == ';') {
      raw.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  raw.add(buf.toString());
  return raw.map(_oSheetFormatTokens).toList(growable: false);
}

/// 把一段格式拆成 `{字面量 | 数字占位段}` 交替的 token 列表。
List<_OSheetFormatToken> _oSheetFormatTokens(String section) {
  final out = <_OSheetFormatToken>[];
  final lit = StringBuffer();
  final mask = StringBuffer();

  void flushLit() {
    if (lit.isNotEmpty) {
      out.add(_OSheetFormatToken(lit.toString(), isMask: false));
      lit.clear();
    }
  }

  void flushMask() {
    if (mask.isNotEmpty) {
      out.add(_OSheetFormatToken(mask.toString(), isMask: true));
      mask.clear();
    }
  }

  for (var i = 0; i < section.length; i++) {
    final ch = section[i];
    if (ch == '"') {
      // 引号字面量：整体进字面量缓冲。
      final end = section.indexOf('"', i + 1);
      final body = end < 0
          ? section.substring(i + 1)
          : section.substring(i + 1, end);
      lit.write(body);
      i = end < 0 ? section.length : end;
      continue;
    }
    if (ch == '\\') {
      if (i + 1 < section.length) lit.write(section[++i]);
      continue;
    }
    if (ch == '[') {
      // `[$$]` → 货币符号；`[Red]` 之类的颜色/条件 → 丢弃。
      final end = section.indexOf(']', i + 1);
      final body = end < 0 ? '' : section.substring(i + 1, end);
      if (body.startsWith(r'$') && body.length > 1) lit.write(body[1]);
      i = end < 0 ? section.length : end;
      continue;
    }
    if (ch == '_' || ch == '*') {
      // `_x` / `*x`：宽度占位，本身不显示 → 跳过下一个字符。
      i++;
      continue;
    }
    if ('#0?.,%'.contains(ch)) {
      flushLit();
      mask.write(ch);
      continue;
    }
    flushMask();
    lit.write(ch);
  }
  flushMask();
  flushLit();
  return out;
}

/// 日期/时间格式的**显示值**（Excel 序列号 → `DateTime`）；非日期模式 → `null`。
///
/// 支持真实样本里出现过的子集：`M/d/yyyy`（大小写不敏感）、`yy`、`d`/`dd`、
/// `m`/`mm`（月，跟在 `h`/`:` 后按分钟）、`h`/`hh`、`s`/`ss`、`AM/PM`。
/// 判定条件：去掉引号/`[]`/转义后**没有任何 `#0?%` 数字占位**且**含 `y` 或 `d`**。
String? oSheetFormatSerialDate(Object? value, String? pattern) {
  if (pattern == null || value is! num) return null;
  final plain = StringBuffer();
  for (var i = 0; i < pattern.length; i++) {
    final ch = pattern[i];
    if (ch == '"') {
      final end = pattern.indexOf('"', i + 1);
      i = end < 0 ? pattern.length : end;
      continue;
    }
    if (ch == '\\') {
      i++;
      continue;
    }
    if (ch == '[') {
      final end = pattern.indexOf(']', i + 1);
      i = end < 0 ? pattern.length : end;
      continue;
    }
    plain.write(ch);
  }
  final p = plain.toString();
  if (p.contains('#') ||
      p.contains('0') ||
      p.contains('?') ||
      p.contains('%')) {
    return null;
  }
  final lower = p.toLowerCase();
  if (!lower.contains('y') && !lower.contains('d')) return null;
  if (!RegExp(r'[ymdhs]').hasMatch(lower)) return null;

  final serial = value.toDouble();
  final wholeDays = serial.floor();
  final fraction = serial - wholeDays;
  // Excel 序列号 0 = 1899-12-30（含 1900 闰年 bug 的通行修正）。
  final base = DateTime(1899, 12, 30).add(Duration(days: wholeDays));
  final minutes = (fraction * 24 * 60).round();
  final dt = base.add(Duration(minutes: minutes));

  final hasAmPm = lower.contains('am/pm');
  final out = StringBuffer();
  var i = 0;
  while (i < p.length) {
    final ch = p[i];
    final lc = ch.toLowerCase();
    var run = 1;
    while (i + run < p.length && p[i + run].toLowerCase() == lc) {
      run++;
    }
    switch (lc) {
      case 'y':
        out.write(
          run >= 4
              ? dt.year.toString().padLeft(4, '0')
              : (dt.year % 100).toString().padLeft(2, '0'),
        );
        i += run;
      case 'm':
        // 紧邻 hour/minute 上下文（`h` 或 `:` 之前出现过 h）→ 分钟。
        final before = p.substring(0, i).toLowerCase();
        final isMinute = before.contains('h') || before.endsWith(':');
        if (isMinute) {
          out.write(
            run >= 2
                ? dt.minute.toString().padLeft(2, '0')
                : dt.minute.toString(),
          );
        } else {
          out.write(
            run >= 2
                ? dt.month.toString().padLeft(2, '0')
                : dt.month.toString(),
          );
        }
        i += run;
      case 'd':
        out.write(
          run >= 2 ? dt.day.toString().padLeft(2, '0') : dt.day.toString(),
        );
        i += run;
      case 'h':
        var hour = dt.hour;
        if (hasAmPm) {
          hour = hour % 12;
          if (hour == 0) hour = 12;
        }
        out.write(run >= 2 ? hour.toString().padLeft(2, '0') : hour.toString());
        i += run;
      case 's':
        out.write(
          run >= 2
              ? dt.second.toString().padLeft(2, '0')
              : dt.second.toString(),
        );
        i += run;
      case 'a':
        if (lower.substring(i).startsWith('am/pm')) {
          out.write(dt.hour < 12 ? 'AM' : 'PM');
          i += 5;
        } else {
          out.write(ch);
          i++;
        }
      default:
        out.write(ch);
        i++;
    }
  }
  return out.toString();
}
