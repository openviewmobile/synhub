// `.osheet` 的 **OOXML（XLSX）主通道** —— 直接按 ECMA-376 解析服务端转码出来的字节。
//
// 取证（`docs/ooxml-ground-truth.md`，2026-09-22；探针 `/tmp/o2_dl.py`，只读）：
//   * `SYNO.SynologyDrive.Files:download`（`files=["id:<file_id>"]`，
//     `force_download=true`、`is_preview=false`）对 `.osheet` 回的就是**标准 XLSX**
//     （头 `50 4B 03 04` = `PK\x03\x04`），**不是**原生 OFile；
//   * 真实 NAS 三份文件下载后都是 ZIP：
//     `Sales tracker.osheet` 10,719 B、`Annual income and expenditure.osheet` 12,955 B、
//     `Travel expenses.osheet` 12,595 B。
//
// 因此版式可以**直接按规范读**，不用猜：
//   * 列宽 / 行高 → `<cols><col width="15.4286"/></cols>` / `<row ht="…"/>`
//     （列宽是**字符单位**，按 Excel 的近似换算 `px ≈ width * 7 + 5`）；
//   * 冻结窗格 → `<sheetView><pane ySplit="10" state="frozen"/>`；
//   * 单元格样式 → `<c s="14">` → `styles.xml` 的 `cellXfs[14]` →
//     `fonts` / `fills` / `borders` / `numFmts` / `<alignment>`；
//   * 合并单元格 → `<mergeCells><mergeCell ref="A1:O1"/>`；
//   * 共享字符串 → `sharedStrings.xml` + `<c t="s"><v>idx</v></c>`；
//   * 公式 → `<f>SUM(K8:K17)</f>`（**只读展示，不求值**）。
//
// 解析结果**复用既有 `OSheetWorkbook` 模型**（OFile 路径同一套），因此渲染器只有一份。
// 拿不到 OOXML / 解析失败时由调用方回落到 `OSheetWorkbook.fromSections`（OFile），
// 并向用户明确说明（见 `office_sheet_view.dart`）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../data/office_native/osheet_model.dart';
import 'office_sheet_ooxml_color.dart';

/// OOXML 解析失败（调用方据此回落到 OFile 通道）。
class OfficeSheetXlsxException implements Exception {
  const OfficeSheetXlsxException(this.message);

  final String message;

  @override
  String toString() => 'OfficeSheetXlsxException($message)';
}

/// 是否是 OOXML（ZIP）容器：头 `PK\x03\x04`（也接受空档记录的 `PK\x05\x06`）。
///
/// 调用方**必须在下载后校验它**：File Station 的 `home/Drive/...` 路径回的是原生
/// OFile（BSON），那种字节不能喂给 XLSX 解析器。
bool isOfficeSheetOoxmlBytes(List<int> bytes) {
  if (bytes.length < 4) return false;
  if (bytes[0] != 0x50 || bytes[1] != 0x4B) return false;
  return (bytes[2] == 0x03 && bytes[3] == 0x04) ||
      (bytes[2] == 0x05 && bytes[3] == 0x06) ||
      (bytes[2] == 0x07 && bytes[3] == 0x08);
}

/// OOXML 长度上限（防御性；真实样本 ≤ 320 KB）。
const int kOfficeSheetOoxmlMaxBytes = 128 * 1024 * 1024;

/// 列宽（字符单位）→ 像素。Excel/WPS 同款近似（11pt Calibri，MDW≈7）。
double ooxmlColWidthToPixels(double width) => width * 7 + 5;

/// 行高（pt）→ 像素（96 dpi）。
double ooxmlRowHeightToPixels(double points) => points * 96 / 72;

/// EMU（English Metric Unit，`<a:ext cx>` / `<xdr:pos x>`）→ 像素。
double ooxmlEmuToPixels(double emu) => emu / 9525;

/// 内置 `numFmtId` → 格式串（ECMA-376 §18.8.30 的常用子集）。
///
/// 真实样本用到 `numFmtId=3`（`#,##0`）、`10`（`0.00%`）、`164`/`165`/`166`/`167`/`168`
/// （自定义，走 `<numFmts>`）；日期族（`14`…`22`）也在表里，供其它文件使用。
const Map<int, String> kOoxmlBuiltinNumberFormats = <int, String>{
  1: '0',
  2: '0.00',
  3: '#,##0',
  4: '#,##0.00',
  9: '0%',
  10: '0.00%',
  11: '0.00E+00',
  12: '# ?/?',
  13: '# ??/??',
  14: 'M/d/yyyy',
  15: 'd-mmm-yy',
  16: 'd-mmm',
  17: 'mmm-yy',
  18: 'h:mm AM/PM',
  19: 'h:mm:ss AM/PM',
  20: 'h:mm',
  21: 'h:mm:ss',
  22: 'M/d/yyyy h:mm',
  37: '#,##0 ;(#,##0)',
  38: '#,##0 ;[Red](#,##0)',
  39: '#,##0.00;(#,##0.00)',
  40: '#,##0.00;[Red](#,##0.00)',
  45: 'mm:ss',
  46: '[h]:mm:ss',
  47: 'mmss.0',
  48: '##0.0E+0',
  49: '@',
};

/// XLSX 字节 → [OSheetWorkbook]（含列宽/行高/冻结/样式/数字格式/合并/公式）。
///
/// 任何结构性缺失（不是 ZIP、没有 `xl/workbook.xml`、没有工作表）
/// 都抛 [OfficeSheetXlsxException]，由调用方回落。
OSheetWorkbook parseOfficeSheetXlsx(List<int> bytes) {
  if (!isOfficeSheetOoxmlBytes(bytes)) {
    throw const OfficeSheetXlsxException('不是 OOXML（缺少 PK\\x03\\x04 头）');
  }
  if (bytes.length > kOfficeSheetOoxmlMaxBytes) {
    throw const OfficeSheetXlsxException('OOXML 体积超出上限');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object catch (e) {
    throw OfficeSheetXlsxException('ZIP 解包失败：$e');
  }

  String? readText(String name) {
    final file = archive.findFile(name);
    final data = file?.readBytes();
    if (data == null) return null;
    return _decodeXmlBytes(data);
  }

  final workbookXml = readText('xl/workbook.xml');
  if (workbookXml == null) {
    throw const OfficeSheetXlsxException('缺少 xl/workbook.xml（不是 XLSX）');
  }
  final XmlDocument workbook;
  try {
    workbook = XmlDocument.parse(workbookXml);
  } on Object catch (e) {
    throw OfficeSheetXlsxException('xl/workbook.xml 解析失败：$e');
  }

  // 关系表：`r:id` → worksheet 部件名。
  final relTargets = <String, String>{};
  final relsXml = readText('xl/_rels/workbook.xml.rels');
  if (relsXml != null) {
    for (final rel in _elements(XmlDocument.parse(relsXml).rootElement, 'Relationship')) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id != null && target != null) relTargets[id] = target;
    }
  }

  // 共享字符串。
  final shared = <String>[];
  final sharedXml = readText('xl/sharedStrings.xml');
  if (sharedXml != null) {
    final doc = XmlDocument.parse(sharedXml);
    for (final si in _elements(doc.rootElement, 'si')) {
      shared.add(_textOf(si));
    }
  }

  // 主题色板：`xl/theme/theme1.xml`。`<color theme="N" tint="±x"/>` 这类
  // **引用色**必须靠它才能解出真实 RGB（否则整段颜色丢失）。
  // 解析不出来（缺部件/坏 XML）→ `null`，由 `office_sheet_ooxml_color.dart`
  // 退回 Office 默认主题，**不让整张表打不开**。
  final theme = OfficeSheetThemeScheme.parse(readText('xl/theme/theme1.xml'));

  // 样式池。
  final stylesXml = readText('xl/styles.xml');
  final pool = stylesXml == null
      ? null
      : _buildStylePool(XmlDocument.parse(stylesXml), theme);

  final sheetsheets = _elements(
    _elements(workbook.rootElement, 'sheets').isEmpty
        ? workbook.rootElement
        : _elements(workbook.rootElement, 'sheets').first,
    'sheet',
  );
  if (sheetsheets.isEmpty) {
    throw const OfficeSheetXlsxException('xl/workbook.xml 里没有 <sheet>');
  }

  final order = <String>[];
  final titles = <String, String>{};
  final deleted = <String, bool>{};
  final sheets = <OSheetSheet>[];

  var index = 0;
  for (final sheetEl in sheetsheets) {
    index++;
    final id = 'sh_$index';
    final title = sheetEl.getAttribute('name') ?? id;
    final state = sheetEl.getAttribute('state') ?? 'visible';
    final relId = _relIdOf(sheetEl);
    final target =
        (relId == null ? null : relTargets[relId]) ??
        'worksheets/sheet$index.xml';
    final path = _normalizePart(target);
    final sheetXml = readText(path) ?? readText('xl/$path');
    if (sheetXml == null) {
      throw OfficeSheetXlsxException('缺少工作表部件：$path');
    }
    final sheetDoc = XmlDocument.parse(sheetXml);
    sheets.add(
      _parseWorksheet(
        id: id,
        title: title,
        isVisible: state != 'hidden' && state != 'veryHidden',
        root: sheetDoc.rootElement,
        shared: shared,
        pool: pool,
        theme: theme,
        readPart: readText,
        archiveName: path,
        archive: archive,
      ),
    );
    order.add(id);
    titles[id] = title;
    deleted[id] = state == 'hidden' || state == 'veryHidden';
  }

  final indexSection = OSheetIndex(
    schemaVersion: 5,
    ver: 1,
    gcVer: null,
    maxIndex: sheets.length,
    order: order,
    sheetTitles: titles,
    deleted: deleted,
    raw: const <String, Object?>{'source': 'ooxml'},
  );

  return OSheetWorkbook(
    index: indexSection,
    sheets: sheets,
    styles: pool,
    sectionNames: <String>['index', 'style', ...order],
  );
}

// ---------------------------------------------------------------------------
// 工作表
// ---------------------------------------------------------------------------

OSheetSheet _parseWorksheet({
  required String id,
  required String title,
  required bool isVisible,
  required XmlElement root,
  required List<String> shared,
  required OSheetStylePool? pool,
  required OfficeSheetThemeScheme? theme,
  required String? Function(String) readPart,
  required String archiveName,
  required Archive archive,
}) {
  // 缺省尺寸：`<sheetFormatPr defaultRowHeight="15.75" defaultColWidth="14.4286"/>`
  final formatPr = _elements(root, 'sheetFormatPr');
  final defRowH = formatPr.isEmpty
      ? null
      : double.tryParse(formatPr.first.getAttribute('defaultRowHeight') ?? '');
  final defColW = formatPr.isEmpty
      ? null
      : double.tryParse(formatPr.first.getAttribute('defaultColWidth') ?? '');

  // `<cols><col min max width hidden customWidth/></cols>`（**列宽按声明**）
  final colWidths = <int, double>{};
  final hiddenCols = <int>{};
  final colsEl = _elements(root, 'cols');
  if (colsEl.isNotEmpty) {
    for (final col in _elements(colsEl.first, 'col')) {
      final min = int.tryParse(col.getAttribute('min') ?? '');
      final max = int.tryParse(col.getAttribute('max') ?? '');
      if (min == null || max == null || max < min) continue;
      final hidden = _isTrue(col.getAttribute('hidden'));
      final width = double.tryParse(col.getAttribute('width') ?? '');
      for (var c = min; c <= max; c++) {
        final idx = c - 1;
        if (width != null) colWidths[idx] = ooxmlColWidthToPixels(width);
        if (hidden) hiddenCols.add(idx);
      }
    }
  }

  // 冻结窗格：`<sheetView><pane xSplit ySplit state="frozen"/>`
  var fixedRowTop = 0;
  var fixedColumnLeft = 0;
  final sheetViews = _descendants(root, 'sheetView');
  if (sheetViews.isNotEmpty) {
    final panes = _elements(sheetViews.first, 'pane');
    for (final pane in panes) {
      final state = pane.getAttribute('state') ?? '';
      if (state != 'frozen' && state != 'frozenSplit') continue;
      final y = int.tryParse(pane.getAttribute('ySplit') ?? '') ?? 0;
      final x = int.tryParse(pane.getAttribute('xSplit') ?? '') ?? 0;
      if (y > fixedRowTop) fixedRowTop = y;
      if (x > fixedColumnLeft) fixedColumnLeft = x;
    }
  }

  // 网格线：`<sheetView showGridLines="0">` 可关；颜色可由 `colorId`（indexed）
  // 或 `<sheetView>` 下的 `<color>` 元素声明。文件没说 → 交给渲染层用文档兜底灰，
  // **不要用 App 主题的 dividerColor**（深色主题下那条线是亮的，画在白纸上像反色）。
  var showGridLines = true;
  String? gridLineHex;
  if (sheetViews.isNotEmpty) {
    final view = sheetViews.first;
    final showAttr = view.getAttribute('showGridLines');
    if (showAttr != null && !_isTrue(showAttr)) showGridLines = false;
    final colorId = int.tryParse(view.getAttribute('colorId') ?? '');
    if (colorId != null) {
      final c = officeSheetIndexedColor(colorId);
      if (c != null) gridLineHex = officeSheetColorToHex(c);
    }
    final colorEl = _elements(view, 'color');
    if (colorEl.isNotEmpty) {
      gridLineHex =
          officeSheetColorHexFromElement(colorEl.first, theme) ?? gridLineHex;
    }
  }

  // 单元格。
  final cells = <int, Map<int, OSheetCell>>{};
  final rowHeights = <int, double>{};
  final hiddenRows = <int>{};
  var maxRow = 0;
  var maxCol = 0;
  final sheetData = _elements(root, 'sheetData');
  final rows = sheetData.isEmpty
      ? const <XmlElement>[]
      : _elements(sheetData.first, 'row');
  for (final row in rows) {
    final r = int.tryParse(row.getAttribute('r') ?? '');
    if (r == null || r < 1) continue;
    final rowIndex = r - 1;
    if (rowIndex + 1 > maxRow) maxRow = rowIndex + 1;
    final ht = double.tryParse(row.getAttribute('ht') ?? '');
    if (ht != null && ht > 0) rowHeights[rowIndex] = ooxmlRowHeightToPixels(ht);
    if (_isTrue(row.getAttribute('hidden'))) hiddenRows.add(rowIndex);

    final rowCells = <int, OSheetCell>{};
    for (final c in _elements(row, 'c')) {
      final ref = c.getAttribute('r');
      final colIndex = ref == null ? null : ooxmlColumnIndexFromRef(ref);
      if (colIndex == null) continue;
      if (colIndex + 1 > maxCol) maxCol = colIndex + 1;
      final s = int.tryParse(c.getAttribute('s') ?? '') ?? 0;
      final cell = _parseCell(
        row: rowIndex,
        col: colIndex,
        styleIndex: s + 1,
        element: c,
        shared: shared,
      );
      rowCells[colIndex] = cell;
    }
    if (rowCells.isNotEmpty) cells[rowIndex] = rowCells;
  }

  // `dimension ref="A1:O83"`：给出完整网格尺寸（含空行/空列）。
  var rowCount = maxRow;
  var colCount = maxCol;
  final dimension = _elements(root, 'dimension');
  if (dimension.isNotEmpty) {
    final ref = dimension.first.getAttribute('ref');
    final range = ref == null ? null : _parseA1Range(ref);
    if (range != null) {
      if (range[2] + 1 > rowCount) rowCount = range[2] + 1;
      if (range[3] + 1 > colCount) colCount = range[3] + 1;
    }
  }

  // 合并单元格。
  final mergedRegions = <OSheetMergeRange>[];
  final mergeCells = _elements(root, 'mergeCells');
  if (mergeCells.isNotEmpty) {
    for (final mc in _elements(mergeCells.first, 'mergeCell')) {
      final ref = mc.getAttribute('ref');
      final range = ref == null ? null : _parseA1Range(ref);
      if (range != null) {
        mergedRegions.add(
          OSheetMergeRange(range[0], range[1], range[2], range[3]),
        );
      }
    }
  }

  // 图表 / 图形的**占位信息**（位置 + 标题）；失败只丢图表，不影响整表。
  final drawings = _parseDrawings(
    archiveName: archiveName,
    readPart: readPart,
    archive: archive,
  );

  final raw = <String, Object?>{
    'source': 'ooxml',
    // 渲染器沿用 OFile 的 `mergeCells` / `drawing` 形状 → 一份渲染逻辑。
    'mergeCells': <Object?>[
      for (final m in mergedRegions) <Object?>[m.row1, m.col1, m.row2, m.col2],
    ],
    if (drawings.isNotEmpty) 'drawing': drawings,
    // 网格线（文档自己的声明；缺省时不写，渲染层用文档兜底色）。
    if (!showGridLines) 'showGridLines': false,
    if (gridLineHex != null) 'gridLineColor': gridLineHex,
  };

  return OSheetSheet(
    id: id,
    title: title,
    rowCount: rowCount,
    colCount: colCount,
    cells: cells,
    raw: raw,
    isVisible: isVisible,
    fixedRowTop: fixedRowTop,
    fixedColumnLeft: fixedColumnLeft,
    defaultRowHeight: defRowH == null ? null : ooxmlRowHeightToPixels(defRowH),
    defaultColWidth: defColW == null ? null : ooxmlColWidthToPixels(defColW),
    rowHeights: rowHeights,
    colWidths: colWidths,
    hiddenRows: hiddenRows,
    hiddenCols: hiddenCols,
    mergedRegions: mergedRegions,
  );
}

OSheetCell _parseCell({
  required int row,
  required int col,
  required int styleIndex,
  required XmlElement element,
  required List<String> shared,
}) {
  final type = element.getAttribute('t') ?? 'n';
  final formula = _elements(element, 'f').isEmpty
      ? null
      : _elements(element, 'f').first.innerText.trim();

  // 公式：**只读展示、不求值** → 值就用公式原文（与 OFile 路径同形）。
  if (formula != null && formula.isNotEmpty) {
    return OSheetCell(
      row: row,
      col: col,
      styleIndex: styleIndex,
      value: '=$formula',
    );
  }

  final v = _elements(element, 'v').isEmpty
      ? null
      : _elements(element, 'v').first.innerText;
  Object? value;
  switch (type) {
    case 's':
      final idx = v == null ? null : int.tryParse(v.trim());
      value = idx == null
          ? null
          : (idx >= 0 && idx < shared.length ? shared[idx] : null);
    case 'str':
    case 'e':
      value = v;
    case 'inlineStr':
      final inline = _elements(element, 'is');
      value = inline.isEmpty ? null : _textOf(inline.first);
    case 'b':
      value = v?.trim() == '1';
    default:
      final text = v?.trim();
      if (text == null || text.isEmpty) {
        value = null;
      } else {
        value = num.tryParse(text) ?? text;
      }
  }
  return OSheetCell(row: row, col: col, styleIndex: styleIndex, value: value);
}

// ---------------------------------------------------------------------------
// styles.xml → OSheetStylePool（OFile 路径同一套槽位形状）
// ---------------------------------------------------------------------------

OSheetStylePool _buildStylePool(
  XmlDocument doc,
  OfficeSheetThemeScheme? theme,
) {
  final root = doc.rootElement;

  // 数字格式：内置表 + 自定义 `<numFmt>`。
  final numFmtCodes = <int, String>{...kOoxmlBuiltinNumberFormats};
  for (final nf in _descendants(root, 'numFmt')) {
    final id = int.tryParse(nf.getAttribute('numFmtId') ?? '');
    final code = nf.getAttribute('formatCode');
    if (id != null && code != null) numFmtCodes[id] = code;
  }

  // fonts：`{n, sz, c, b, i, u}`（**真实取值**来自 `<font>` 子元素）。
  // 颜色走统一解引用：`rgb` / `theme`+`tint` / `indexed` / 自动。
  // **"自动"（无 `<color>`）刻意不写 `c`**：渲染层要按底色对比度决定黑/白字，
  // 不能在这里编一个默认色（那正是"浅灰底 + 浅色字"的成因）。
  final fonts = <Object?>[];
  for (final font in _descendants(root, 'font')) {
    final map = <String, Object?>{};
    final name = _firstAttr(font, 'name', 'val');
    final size = double.tryParse(_firstAttr(font, 'sz', 'val') ?? '');
    final colorEl = _elements(font, 'color');
    final color = officeSheetColorHexFromElement(
      colorEl.isEmpty ? null : colorEl.first,
      theme,
    );
    if (name != null) map['n'] = name;
    if (size != null) map['sz'] = size;
    if (color != null) map['c'] = color;
    if (_isTrue(_firstAttr(font, 'b', 'val')) || _hasElement(font, 'b')) {
      map['b'] = true;
    }
    if (_isTrue(_firstAttr(font, 'i', 'val')) || _hasElement(font, 'i')) {
      map['i'] = true;
    }
    if (_hasElement(font, 'u')) map['u'] = true;
    fonts.add(map);
  }

  // fills：只认 `solid`（`patternType="none"/"gray125"` = 无填充）。
  final fills = <Object?>[];
  final fillSolid = <bool>[];
  for (final fill in _descendants(root, 'fill')) {
    final pattern = _elements(fill, 'patternFill');
    String? bg;
    var solid = false;
    if (pattern.isNotEmpty) {
      final type = pattern.first.getAttribute('patternType') ?? 'none';
      final fgEl = _elements(pattern.first, 'fgColor');
      final fg = officeSheetColorHexFromElement(
        fgEl.isEmpty ? null : fgEl.first,
        theme,
      );
      if (type == 'solid' && fg != null) {
        bg = fg;
        solid = true;
      }
    }
    fills.add(bg == null ? <String, Object?>{} : <String, Object?>{'bg': bg});
    fillSolid.add(solid);
  }

  // borders：`b = [top,right,bottom,left]`（颜色 hex）。
  final borders = <Object?>[];
  final borderHas = <bool>[];
  for (final border in _descendants(root, 'border')) {
    final sides = <String?>[];
    var any = false;
    for (final side in <String>['top', 'right', 'bottom', 'left']) {
      final el = _elements(border, side);
      if (el.isEmpty) {
        sides.add(null);
        continue;
      }
      final style = el.first.getAttribute('style') ?? '';
      final sideColorEl = _elements(el.first, 'color');
      final color = officeSheetColorHexFromElement(
        sideColorEl.isEmpty ? null : sideColorEl.first,
        theme,
      );
      if (style.isNotEmpty) {
        // 有边框线型但**没声明颜色** = OOXML 的"自动"边框色（Excel 用文字色/黑）。
        // 旧实现把这种边直接丢掉，等于文件里画的框线凭空消失。
        sides.add(color ?? officeSheetColorToHex(kOfficeSheetDefaultTextColor));
        any = true;
      } else {
        sides.add(null);
      }
    }
    borders.add(<String, Object?>{'b': sides});
    borderHas.add(any);
  }

  // alignments：只登记真实出现的对齐（用于 1 基 id）。
  final alignments = <Object?>[];
  final alignmentByKey = <String, int>{};

  int alignmentIdFor(XmlElement? alignment) {
    if (alignment == null) return 0;
    final h = alignment.getAttribute('horizontal');
    final v = alignment.getAttribute('vertical');
    final wrap = _isTrue(alignment.getAttribute('wrapText'));
    if (h == null && v == null && !wrap) return 0;
    final key = '${h ?? ''}|${v ?? ''}|$wrap';
    final existing = alignmentByKey[key];
    if (existing != null) return existing;
    final map = <String, Object?>{
      if (h != null) 'h': h,
      if (v != null) 'v': v,
      if (wrap) 'w': 'wrap',
    };
    alignments.add(map);
    final id = alignments.length;
    alignmentByKey[key] = id;
    return id;
  }

  // numberFormats：按出现顺序建 1 基 id。
  final numberFormats = <Object?>[];
  final numFmtIdByFormat = <int, int>{};

  int numFmtIdFor(int xlsxNumFmtId) {
    if (xlsxNumFmtId == 0) return 0;
    final existing = numFmtIdByFormat[xlsxNumFmtId];
    if (existing != null) return existing;
    final code = numFmtCodes[xlsxNumFmtId];
    if (code == null) return 0;
    numberFormats.add(<String, Object?>{'fc': code});
    final id = numberFormats.length;
    numFmtIdByFormat[xlsxNumFmtId] = id;
    return id;
  }

  // styles：cellXfs 的每个 `<xf>` → `[refCount, fontId, fillId, alignmentId,
  // borderId, nfId]`（**1 基**，与 OFile 路径完全同形）。
  final styles = <Object?>[];
  final cellXfs = _descendants(root, 'cellXfs');
  final xfs = cellXfs.isEmpty
      ? const <XmlElement>[]
      : _elements(cellXfs.first, 'xf');
  for (final xf in xfs) {
    final fontId = int.tryParse(xf.getAttribute('fontId') ?? '') ?? 0;
    final fillId = int.tryParse(xf.getAttribute('fillId') ?? '') ?? 0;
    final borderId = int.tryParse(xf.getAttribute('borderId') ?? '') ?? 0;
    final nfId = int.tryParse(xf.getAttribute('numFmtId') ?? '') ?? 0;
    final alignment = _elements(xf, 'alignment');
    final alignmentId = alignmentIdFor(
      alignment.isEmpty ? null : alignment.first,
    );
    final fillIsSolid = fillId >= 0 && fillId < fillSolid.length
        ? fillSolid[fillId]
        : false;
    final borderIsVisible = borderId >= 0 && borderId < borderHas.length
        ? borderHas[borderId]
        : false;
    styles.add(<int>[
      0,
      fontId >= 0 && fontId < fonts.length ? fontId + 1 : 0,
      fillIsSolid ? fillId + 1 : 0,
      alignmentId,
      borderIsVisible ? borderId + 1 : 0,
      numFmtIdFor(nfId),
    ]);
  }

  return OSheetStylePool(
    styles: styles,
    fonts: fonts,
    fills: fills,
    alignments: alignments,
    borders: borders,
    numberFormats: numberFormats,
    raw: const <String, Object?>{'source': 'ooxml'},
  );
}

// ---------------------------------------------------------------------------
// 图表（`xl/drawings/drawingN.xml` + `xl/charts/chartN.xml`）
//
// O3：不再只登记 `cNvPr name` 当标题 —— 真的把 `chartN.xml` 解出
//   `chartType` / `barDir` / `plotArea.series[].cat/val` / 标题，
// 产出与 OFile 路径**同形**的 `chartObj`，交给 `office_sheet_chart.dart` 绘制。
// ---------------------------------------------------------------------------

List<Map<String, Object?>> _parseDrawings({
  required String archiveName,
  required String? Function(String) readPart,
  required Archive archive,
}) {
  final out = <Map<String, Object?>>[];
  try {
    final dir = archiveName.contains('/')
        ? archiveName.substring(0, archiveName.lastIndexOf('/'))
        : '';
    final base = archiveName.split('/').last;
    final relsName = dir.isEmpty
        ? '_rels/$base.rels'
        : '$dir/_rels/$base.rels';
    final relsXml = readPart(relsName);
    if (relsXml == null) return out;
    for (final rel in _elements(
      XmlDocument.parse(relsXml).rootElement,
      'Relationship',
    )) {
      final type = rel.getAttribute('Type') ?? '';
      if (!type.endsWith('/drawing')) continue;
      final target = rel.getAttribute('Target');
      if (target == null) continue;
      final drawingPart = _normalizePart(target);
      final drawingXml = readPart(drawingPart) ?? readPart('xl/$drawingPart');
      if (drawingXml == null) continue;
      // 图表的部件映射：`xl/drawings/_rels/drawing1.xml.rels` → rId → chart part。
      final chartParts = _readRelationships(readPart, drawingPart);
      out.addAll(
        _parseDrawingPart(
          XmlDocument.parse(drawingXml).rootElement,
          chartParts,
          readPart,
        ),
      );
    }
  } on Object {
    // 图表是"锦上添花"：解析失败只丢图表，绝不让整表失败。
    return out;
  }
  return out;
}

/// 读某个部件的 `.rels`：`rId → 归一化后的包内部件路径`。
Map<String, String> _readRelationships(
  String? Function(String) readPart,
  String part,
) {
  final dir = part.contains('/')
      ? part.substring(0, part.lastIndexOf('/'))
      : '';
  final base = part.split('/').last;
  final relsName = dir.isEmpty ? '_rels/$base.rels' : '$dir/_rels/$base.rels';
  final xml = readPart(relsName);
  if (xml == null) return const <String, String>{};
  final out = <String, String>{};
  for (final rel in _elements(
    XmlDocument.parse(xml).rootElement,
    'Relationship',
  )) {
    final id = rel.getAttribute('Id');
    final target = rel.getAttribute('Target');
    if (id == null || target == null) continue;
    out[id] = _resolvePart(dir, target);
  }
  return out;
}

/// `xl/drawings` + `../charts/chart1.xml` → `xl/charts/chart1.xml`。
String _resolvePart(String baseDir, String target) {
  if (target.startsWith('/')) return _normalizePart(target);
  final segments = <String>[
    ...baseDir.split('/').where((e) => e.isNotEmpty),
  ];
  for (final segment in target.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.join('/');
}

List<Map<String, Object?>> _parseDrawingPart(
  XmlElement root,
  Map<String, String> chartParts,
  String? Function(String) readPart,
) {
  final out = <Map<String, Object?>>[];
  var index = 0;
  for (final anchor in _elements(root, 'absoluteAnchor')) {
    final pos = _elements(anchor, 'pos');
    final ext = _elements(anchor, 'ext');
    if (pos.isEmpty || ext.isEmpty) continue;
    final x = double.tryParse(pos.first.getAttribute('x') ?? '');
    final y = double.tryParse(pos.first.getAttribute('y') ?? '');
    final cx = double.tryParse(ext.first.getAttribute('cx') ?? '');
    final cy = double.tryParse(ext.first.getAttribute('cy') ?? '');
    if (x == null || y == null || cx == null || cy == null) continue;
    index++;
    final name = _elements(anchor, 'cNvPr');
    final frameName = name.isEmpty ? '' : (name.first.getAttribute('name') ?? '');
    // `c:chart r:id="rIdN"` → chart part → chartObj（拿不到就只留 frame 名）。
    Map<String, Object?>? chartObj;
    final chartRefs = _descendants(anchor, 'chart');
    if (chartRefs.isNotEmpty) {
      final relId = _relIdOf(chartRefs.first);
      final part = relId == null ? null : chartParts[relId];
      final xml = part == null ? null : readPart(part);
      if (xml != null) {
        try {
          chartObj = _parseChartXml(XmlDocument.parse(xml).rootElement);
        } on Object {
          chartObj = null;
        }
      }
    }
    out.add(<String, Object?>{
      'id': 'drawing-$index',
      'type': 'chart',
      'pos': <String, Object?>{
        'left': ooxmlEmuToPixels(x),
        'top': ooxmlEmuToPixels(y),
        'width': ooxmlEmuToPixels(cx),
        'height': ooxmlEmuToPixels(cy),
      },
      'chartObj':
          chartObj ?? <String, Object?>{'title': <String, Object?>{'text': frameName}},
    });
  }
  return out;
}

/// `chartN.xml` → OFile 同形的 `chartObj`。
Map<String, Object?> _parseChartXml(XmlElement root) {
  final plotArea = _descendants(root, 'plotArea');
  final plot = plotArea.isEmpty ? root : plotArea.first;
  String? chartType;
  final barCharts = _elements(plot, 'barChart');
  final lineCharts = _elements(plot, 'lineChart');
  final pieCharts = _elements(plot, 'pieChart');
  final doughnutCharts = _elements(plot, 'doughnutChart');
  String? barDir;
  XmlElement? seriesHost;
  if (barCharts.isNotEmpty) {
    chartType = 'bar';
    seriesHost = barCharts.first;
    final dirs = _elements(seriesHost, 'barDir');
    if (dirs.isNotEmpty) barDir = dirs.first.getAttribute('val');
  } else if (lineCharts.isNotEmpty) {
    chartType = 'line';
    seriesHost = lineCharts.first;
  } else if (pieCharts.isNotEmpty) {
    chartType = 'pie';
    seriesHost = pieCharts.first;
  } else if (doughnutCharts.isNotEmpty) {
    chartType = 'doughnut';
    seriesHost = doughnutCharts.first;
  } else {
    for (final child in plot.childElements) {
      if (child.name.local.endsWith('Chart')) {
        chartType = child.name.local.substring(
          0,
          child.name.local.length - 'Chart'.length,
        );
        seriesHost = child;
        break;
      }
    }
  }

  final series = <Map<String, Object?>>[];
  if (seriesHost != null) {
    var position = 0;
    for (final ser in _elements(seriesHost, 'ser')) {
      final cat = _chartRef(ser, 'cat');
      final val = _chartRef(ser, 'val');
      if (cat == null || val == null) continue;
      final name = _chartSeriesName(ser);
      series.add(<String, Object?>{
        'cat': cat,
        'val': val,
        'type': chartType,
        'index': position,
        'order': position,
        if (name != null) 'name': name,
      });
      position++;
    }
  }
  final displayRange = series.isEmpty
      ? null
      : '${series.map((e) => e['cat']).join(',')},'
            '${series.map((e) => e['val']).join(',')}';

  return <String, Object?>{
    if (chartType != null) 'chartType': chartType,
    if (barDir != null) 'barDir': barDir,
    if (displayRange != null) 'displayRange': displayRange,
    'plotArea': <String, Object?>{'series': series},
    'title': <String, Object?>{'text': _chartTitle(root) ?? ''},
  };
}

/// `<c:title>`（图表标题，文档序第一个）里的 `a:t` 文本。
String? _chartTitle(XmlElement root) {
  final titles = _descendants(root, 'title');
  if (titles.isEmpty) return null;
  final buf = StringBuffer();
  for (final t in _descendants(titles.first, 't')) {
    buf.write(t.innerText);
  }
  final text = buf.toString().trim();
  return text.isEmpty ? null : text;
}

String? _chartSeriesName(XmlElement ser) {
  final tx = _descendants(ser, 'tx');
  if (tx.isEmpty) return null;
  final buf = StringBuffer();
  for (final t in _descendants(tx.first, 't')) {
    buf.write(t.innerText);
  }
  final text = buf.toString().trim();
  return text.isEmpty ? null : text;
}

/// `ser/cat` 或 `ser/val` 的公式区域；去掉 `'Sheet'!` 表名限定。
String? _chartRef(XmlElement ser, String kind) {
  final nodes = _elements(ser, kind);
  if (nodes.isEmpty) return null;
  final refs = _descendants(nodes.first, 'f');
  if (refs.isEmpty) return null;
  var text = refs.first.innerText.trim();
  if (text.isEmpty) return null;
  final bang = text.lastIndexOf('!');
  if (bang >= 0) text = text.substring(bang + 1);
  text = text.replaceAll("'", '').trim();
  return text.isEmpty ? null : text;
}


// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

/// 按 XML 声明解字节 → 字符串。
///
/// **必须是 UTF-8**：真实样本的中文表名/中文单元格（`一月`、`餐饮`…）如果按
/// 码位直读会变成乱码。`readBytes()` 给的是**原始字节**，这里显式解码；
/// 只有带 `FF FE` / `FE FF` BOM 的部件才按 UTF-16 处理（OOXML 允许但不常见）。
String _decodeXmlBytes(List<int> data) {
  if (data.length >= 2) {
    if (data[0] == 0xFF && data[1] == 0xFE) {
      return _decodeUtf16(data.sublist(2), littleEndian: true);
    }
    if (data[0] == 0xFE && data[1] == 0xFF) {
      return _decodeUtf16(data.sublist(2), littleEndian: false);
    }
  }
  var start = 0;
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    start = 3; // UTF-8 BOM
  }
  return utf8.decode(data.sublist(start), allowMalformed: true);
}

String _decodeUtf16(List<int> data, {required bool littleEndian}) {
  final buf = StringBuffer();
  for (var i = 0; i + 1 < data.length; i += 2) {
    buf.writeCharCode(
      littleEndian ? data[i] | (data[i + 1] << 8) : (data[i] << 8) | data[i + 1],
    );
  }
  return buf.toString();
}

/// 按**局部名**取直接子级（OOXML 里有默认命名空间，前缀不可靠）。
List<XmlElement> _elements(XmlElement node, String local) => node.childElements
    .where((e) => e.name.local == local)
    .toList(growable: false);

bool _hasElement(XmlElement node, String local) =>
    _elements(node, local).isNotEmpty;

/// 按**局部名**取后代（样式池/`sheetView` 都在容器元素里，不是 root 的直接子级）。
List<XmlElement> _descendants(XmlElement node, String local) => node.descendants
    .whereType<XmlElement>()
    .where((e) => e.name.local == local)
    .toList(growable: false);

String? _firstAttr(XmlElement node, String local, String attr) {
  final els = _elements(node, local);
  if (els.isEmpty) return null;
  return els.first.getAttribute(attr);
}

bool _isTrue(String? value) =>
    value == '1' || value == 'true' || value == 'True';

/// `si` / `is` 的可见文本（含 `<r><t>` 分段）。
String _textOf(XmlElement node) {
  final buf = StringBuffer();
  void walk(XmlElement e) {
    for (final child in e.childElements) {
      if (child.name.local == 't') {
        buf.write(child.innerText);
      } else if (child.name.local != 'rPh') {
        walk(child);
      }
    }
  }

  walk(node);
  return buf.toString();
}

String? _relIdOf(XmlElement sheetEl) {
  for (final attr in sheetEl.attributes) {
    if (attr.name.local == 'id' && attr.name.prefix == 'r') return attr.value;
  }
  return null;
}

/// 包内相对路径归一（`/xl/worksheets/sheet1.xml` → `xl/worksheets/sheet1.xml`）。
String _normalizePart(String target) {
  var t = target;
  if (t.startsWith('/')) t = t.substring(1);
  if (t.startsWith('xl/')) return t;
  return t.startsWith('worksheets/') || t.startsWith('_rels/')
      ? 'xl/$t'
      : t;
}

/// `A1` / `$B$7` → 0 基列号；非法 → `null`。
int? ooxmlColumnIndexFromRef(String ref) {
  var n = 0;
  var seen = false;
  for (final code in ref.toUpperCase().codeUnits) {
    if (code == 0x24) continue; // `$`
    if (code < 65 || code > 90) break;
    n = n * 26 + (code - 64);
    seen = true;
  }
  if (!seen) return null;
  return n - 1;
}

/// `B3:K3` / `A1` → `[r1,c1,r2,c2]`（0 基闭区间）；非法 → `null`。
List<int>? _parseA1Range(String ref) {
  final match = RegExp(
    r'^\$?([A-Za-z]+)\$?(\d+)(?::\$?([A-Za-z]+)\$?(\d+))?$',
  ).firstMatch(ref.trim());
  if (match == null) return null;
  final c1 = ooxmlColumnIndexFromRef(match.group(1)!);
  final r1 = int.tryParse(match.group(2)!);
  final c2 = match.group(3) == null
      ? c1
      : ooxmlColumnIndexFromRef(match.group(3)!);
  final r2 = match.group(4) == null ? r1 : int.tryParse(match.group(4)!);
  if (c1 == null || r1 == null || c2 == null || r2 == null) return null;
  if (r1 < 1 || r2 < 1) return null;
  return <int>[
    (r1 - 1) < (r2 - 1) ? r1 - 1 : r2 - 1,
    c1 < c2 ? c1 : c2,
    (r1 - 1) < (r2 - 1) ? r2 - 1 : r1 - 1,
    c1 < c2 ? c2 : c1,
  ];
}

/// 便于测试/调用方：XLSX 字节 → 是否被本解析器接受（但不抛异常）。
bool canParseOfficeSheetXlsx(List<int> bytes) {
  try {
    parseOfficeSheetXlsx(Uint8List.fromList(bytes));
    return true;
  } on Object {
    return false;
  }
}
