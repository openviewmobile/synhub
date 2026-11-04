// Office `.odoc` 的**真表格**（批 B）。
//
// 取证（只读 `SYNO.Office.Snapshot:get` v4，原文见
// `docs/office-doc-render-design.md` §7.1 与本批 `test/fixtures/office_doc_tables/`）：
//
//   * 列宽：`table.attrs.colgroup = [{"width":413},{"width":188}]`（**px**）。
//     三份真实文档的 colgroup 之和分别为 601 / 600 / 600 px；A4 纵向 2.54cm 页边距
//     的内容宽 = (21 - 5.08)cm ≈ 601.7px(@96dpi) → colgroup 就是**页面内容宽坐标系**
//     下的像素宽度，因此"按比例缩放到可用宽度"与原文排版同构（不是拍脑袋）。
//   * 行高：`table_row.attrs.height`（px，实测 124 / 28 / 26..91）。
//   * 单元格：`table_cell.attrs` 的真实键集合（3 份文档共 42 格逐个解剖）：
//     `borderTop/Right/Bottom/Left × {Color,Style,Width}`（12 键）+ `colspan` +
//     `rowspan` + `verticalAlign`。
//     `backgroundColor` 是 schema 声明的**可选**键，但**真实 42 格里一个都没有**
//     → 代码只在它存在时才用，**绝不假定存在、也绝不为了"像"而编底色**。
//   * **合并**：`synotable` **不是**合并载体、也不是表格 id ——
//     `5-day trip planner.odoc` 的 **5 个彼此独立的 table 取值完全相同**
//     （`"2pgIFIeerl"`）⇒ 它是**表格样式/定义 id**（可复用），本批只原样读出，
//     不拿它做任何判据。
//     真正的合并字段 = 每个 cell 自己的 `colspan` / `rowspan`。
//
//   * **批 C 升级（真实合并样例已到手）**：官方模板 `doc/invoice` 的第二个表
//     （夹具 `test/fixtures/office_templates/invoice_merged_cells.json`）里有
//     **4 个真实的 `colspan=3, rowspan=1` 合并格**。逐格解剖得到的**真实语义**是：
//       - 每一行的 `content` **恰好一列一个 `table_cell`**（该表 colgroup 4 列 →
//         每行 4 个 cell，含表头在内的 16 行全部成立）；
//       - 合并格所在行的第 1、2 个 cell 的边框色是 `#7b8187`、第 3 个是
//         `#aaaaaa`，与合并格自身的 `#aaaaaa` 一致 ⇒ **被跨过的 cell 是留在树里的
//         "占位格"，必须跳过、不能重复渲染**；
//       - 因此**合并格的列 = 该 cell 在行内的下标**（不是"按 colspan 顺序推进"）。
//     > 这条纠了批 B 的"未取证"写法：批 B 的阶段化落位（按 colspan 推进光标）
//     > 会把 invoice 的第 4 列画成 **cell#1 的占位格**（边框色错、真实内容丢失），
//     > 是**真实样例暴露出来的 bug**。见 [computeOfficeDocTablePlacements]。
//
//   * **仍未取证**：`rowspan>1`（真实合并样例全是 `rowspan=1`）、嵌套/交叠合并、
//     以及"行内 cell 数 < 列数"的 Excel 式存储形态（真实样例每行都补齐到列数）。
//     代码对后两者按"rowspan 占位时向右滑动"处理并**如实登记**。
//
// 超宽处理（**明确二选一**）：**按 colgroup 宽度比例分配可用宽度**（Row + Expanded
// flex = width×100），**不做横向滚动**。这样列宽总和永远等于可用宽度，**不可能溢出**，
// 同时在可用宽 = 601.7px 时与原文 px 一致。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import 'office_doc_image.dart' show officeDocImagePx;
import 'office_doc_style.dart' show officeDocParseColor;

/// 单元格垂直对齐（真机取值 `middle`，schema 也声明了 `top/bottom`）。
enum OfficeDocCellVerticalAlign { top, middle, bottom }

/// 一条边框（`borderXxxWidth/Style/Color` 四元组里的三件）。
class OfficeDocTableCellBorder {
  const OfficeDocTableCellBorder({
    required this.width,
    required this.color,
    required this.style,
  });

  static const OfficeDocTableCellBorder none = OfficeDocTableCellBorder(
    width: 0,
    color: null,
    style: 'none',
  );

  final double width;
  final Color? color;

  /// 原文 CSS 边框样式（实测 `solid`）。
  final String style;

  /// 是否画出来：宽度 > 0 且样式不是 none/hidden。
  bool get visible => width > 0 && style != 'none' && style != 'hidden';

  BorderSide toBorderSide() => visible
      ? BorderSide(width: width, color: color ?? const Color(0xFF000000))
      : BorderSide.none;
}

/// 一个 `table_cell` 的渲染规格。
class OfficeDocTableCellSpec {
  const OfficeDocTableCellSpec({
    required this.node,
    required this.nodeIndex,
    required this.columnIndex,
    required this.colspan,
    required this.rowspan,
    required this.verticalAlign,
    required this.backgroundColor,
    required this.top,
    required this.right,
    required this.bottom,
    required this.left,
  });

  /// 原始节点（渲染单元格内容时用）。
  final Object? node;

  /// 在本行 `content` 里的下标（编辑路径用）。
  final int nodeIndex;

  /// 落在第几列（由行内顺序推出）。
  final int columnIndex;

  /// schema `table_cell.attrs.colspan` / `.rowspan`。
  /// `colspan` 有真实样例（doc/invoice 的 `colspan=3`）；`rowspan>1` 无。
  final int colspan;
  final int rowspan;

  final OfficeDocCellVerticalAlign verticalAlign;
  final Color? backgroundColor;
  final OfficeDocTableCellBorder top;
  final OfficeDocTableCellBorder right;
  final OfficeDocTableCellBorder bottom;
  final OfficeDocTableCellBorder left;

  bool get hasSpan => colspan > 1 || rowspan > 1;
}

/// 一个 `table_row` 的渲染规格。
class OfficeDocTableRowSpec {
  const OfficeDocTableRowSpec({
    required this.node,
    required this.nodeIndex,
    required this.heightPx,
    required this.cells,
  });

  final Object? node;
  final int nodeIndex;

  /// `attrs.height`（px）；缺失/非法时为 null → 用内容高度。
  final double? heightPx;

  final List<OfficeDocTableCellSpec> cells;
}

/// 一列的宽度（px）+ 用于 `Expanded.flex` 的整数比例。
class OfficeDocTableColumn {
  const OfficeDocTableColumn({required this.widthPx, required this.flex});

  final double widthPx;

  /// `width×100` 取整：既保住比例精度，又是合法的整数 flex。
  final int flex;
}

/// 表格布局模型（**纯解析，可在无 widget 环境下单测**）。
class OfficeDocTableModel {
  const OfficeDocTableModel({
    required this.columns,
    required this.rows,
    required this.totalWidthPx,
    required this.synotable,
    required this.spanCellCount,
    required this.maxColspan,
    required this.maxRowspan,
    required this.hasColgroup,
    required this.notes,
  });

  final List<OfficeDocTableColumn> columns;
  final List<OfficeDocTableRowSpec> rows;

  /// colgroup 宽度之和（px）；无 colgroup 时是列数（等分占位）。
  final double totalWidthPx;

  /// `attrs.synotable` —— **表格样式/定义 id**（实探：同一文档 5 个独立表格同值）。
  /// **不是**表格 id，也**不是**合并判据；本批只原样读出。
  final String? synotable;

  /// `colspan>1 || rowspan>1` 的单元格数（doc/invoice 真实样例为 4）。
  final int spanCellCount;
  final int maxColspan;
  final int maxRowspan;

  /// 是否读到合法 `colgroup`；false = 退回等分（并已登记 note）。
  final bool hasColgroup;

  /// 解析过程中的如实登记（不允许静默）。
  final List<String> notes;

  int get totalFlex =>
      columns.fold<int>(0, (a, c) => a + c.flex) <= 0
      ? 1
      : columns.fold<int>(0, (a, c) => a + c.flex);

  /// 第 [columnIndex] 列在 [availableWidth] 下的实际宽度（= 比例分配）。
  double effectiveWidth(int columnIndex, double availableWidth) {
    if (columns.isEmpty) return 0;
    final i = columnIndex < 0
        ? 0
        : (columnIndex >= columns.length ? columns.length - 1 : columnIndex);
    return availableWidth * columns[i].flex / totalFlex;
  }

  /// 某一格占的 flex：**只占自己那一列**（不合并时的网格用）。
  int flexForCell(OfficeDocTableCellSpec cell) {
    if (columns.isEmpty) return 1;
    final i = _clampColumn(cell.columnIndex);
    return columns[i].flex;
  }

  /// 某一格按 `colspan` 合并后占的 flex（= 被跨各列 flex 之和）。
  int flexForCellSpan(OfficeDocTableCellSpec cell) {
    if (columns.isEmpty) return 1;
    final start = _clampColumn(cell.columnIndex);
    final end = _clampColumn(cell.columnIndex + cell.colspan - 1);
    var flex = 0;
    for (var i = start; i <= end; i++) {
      flex += columns[i].flex;
    }
    return flex < 1 ? 1 : flex;
  }

  int _clampColumn(int i) =>
      i < 0 ? 0 : (i >= columns.length ? columns.length - 1 : i);

  /// 合并路径是否可用：有 >1 的 span，且**每行都有显式 height**（否则算不出
  /// 跨行矩形；此时退回网格并登记"未合并"）。真实样例（doc/invoice）每行都有
  /// height，因此合并路径**真的被真实数据走到了**。
  bool get canRenderSpans =>
      spanCellCount > 0 &&
      rows.isNotEmpty &&
      columns.isNotEmpty &&
      rows.every((r) => r.heightPx != null && r.heightPx! > 0);

  /// 解析一个 `table` 节点。
  ///
  /// [notes] 非 null 时把解析中的如实登记写进去（渲染器传 renderReport）。
  static OfficeDocTableModel parse(Object? node, {List<String>? notes}) {
    final out = <String>[];
    final map = node is Map ? node.cast<String, Object?>() : null;
    final attrs = map != null && map['attrs'] is Map
        ? (map['attrs']! as Map).cast<String, Object?>()
        : const <String, Object?>{};
    final rawCols = attrs['colgroup'];
    final colWidths = <double>[];
    if (rawCols is List) {
      for (final raw in rawCols) {
        final w = raw is Map ? officeDocImagePx(raw['width']) : null;
        if (w != null && w > 0) colWidths.add(w);
      }
    }
    final rows = <OfficeDocTableRowSpec>[];
    final children = map != null && map['content'] is List
        ? (map['content']! as List)
        : const <Object?>[];
    final maxCells = children.whereType<Map>().fold<int>(0, (a, r) {
      final cells = (r['content'] as List?)?.whereType<Map>().length ?? 0;
      return cells > a ? cells : a;
    });
    final hasColgroup = colWidths.isNotEmpty;
    if (!hasColgroup) {
      out.add('table 缺少合法 colgroup → 列宽退回等分（未取证形态，如实登记）');
    }
    for (var ri = 0; ri < children.length; ri++) {
      final raw = children[ri];
      if (raw is! Map) continue;
      final row = raw.cast<String, Object?>();
      if (row['type'] != 'table_row') continue;
      final rowAttrs = row['attrs'] is Map
          ? (row['attrs']! as Map).cast<String, Object?>()
          : const <String, Object?>{};
      final height = officeDocImagePx(rowAttrs['height']);
      final cellNodes = (row['content'] as List?) ?? const <Object?>[];
      final cells = <OfficeDocTableCellSpec>[];
      var column = 0;
      for (var ci = 0; ci < cellNodes.length; ci++) {
        final rawCell = cellNodes[ci];
        if (rawCell is! Map) continue;
        final cell = rawCell.cast<String, Object?>();
        if (cell['type'] != 'table_cell') continue;
        final a = cell['attrs'] is Map
            ? (cell['attrs']! as Map).cast<String, Object?>()
            : const <String, Object?>{};
        final cs = _span(a['colspan']);
        final rs = _span(a['rowspan']);
        cells.add(
          OfficeDocTableCellSpec(
            node: cell,
            nodeIndex: ci,
            columnIndex: column,
            colspan: cs,
            rowspan: rs,
            verticalAlign: switch ('${a['verticalAlign']}'.toLowerCase()) {
              'top' => OfficeDocCellVerticalAlign.top,
              'bottom' => OfficeDocCellVerticalAlign.bottom,
              _ => OfficeDocCellVerticalAlign.middle,
            },
            backgroundColor: officeDocParseColor(a['backgroundColor']),
            top: _border(a, 'Top', out),
            right: _border(a, 'Right', out),
            bottom: _border(a, 'Bottom', out),
            left: _border(a, 'Left', out),
          ),
        );
        column += 1;
      }
      rows.add(
        OfficeDocTableRowSpec(
          node: row,
          nodeIndex: ri,
          heightPx: height != null && height > 0 ? height : null,
          cells: cells,
        ),
      );
    }
    // 列数：优先 colgroup；没有就按最宽的行等分。
    final columnCount = hasColgroup
        ? colWidths.length
        : (maxCells > 0 ? maxCells : 1);
    final widths = hasColgroup
        ? List<double>.generate(
            columnCount,
            (i) => i < colWidths.length ? colWidths[i] : colWidths.last,
          )
        : List<double>.filled(columnCount, 1);
    final columns = <OfficeDocTableColumn>[
      for (final w in widths)
        OfficeDocTableColumn(widthPx: w, flex: _flexOf(w, hasColgroup)),
    ];
    var spanCells = 0;
    var maxCs = 1;
    var maxRs = 1;
    for (final r in rows) {
      for (final c in r.cells) {
        if (c.hasSpan) spanCells += 1;
        if (c.colspan > maxCs) maxCs = c.colspan;
        if (c.rowspan > maxRs) maxRs = c.rowspan;
      }
    }
    if (spanCells > 0) {
      // 批 C：`colspan>1` 已有**真实样例**（官方模板 `doc/invoice` 的 4 个
      // `colspan=3, rowspan=1`，夹具 invoice_merged_cells.json）—— 不再标"未取证"。
      if (maxCs > 1) {
        out.add(
          '合并渲染已取证：colspan>1 有真实样例（doc/invoice 的 4 个 '
          'colspan=3,rowspan=1；被跨过的占位 cell 按行内下标落位并跳过）',
        );
      }
      if (maxRs > 1) {
        // rowspan>1 在真实语料里**一次都没出现**（invoice 的合并格全是 rowspan=1）
        // → 按"占位格仍留在树里、后续 cell 向右滑动"的语义实现，但**明确登记未取证**。
        out.add(
          'rowspan>1 合并未取证：真实样例（doc/invoice）只有 colspan=3、rowspan=1；'
          '本路径按 rowspan 占位语义实现。要真验证需要一个带纵向合并的真实文档'
          '（可在 DSM Office 里造）',
        );
      }
    }
    final synotable = attrs['synotable'];
    final model = OfficeDocTableModel(
      columns: columns,
      rows: rows,
      totalWidthPx: hasColgroup
          ? colWidths.fold<double>(0, (a, b) => a + b)
          : columnCount.toDouble(),
      synotable: synotable is String && synotable.isNotEmpty ? synotable : null,
      spanCellCount: spanCells,
      maxColspan: maxCs,
      maxRowspan: maxRs,
      hasColgroup: hasColgroup,
      notes: out,
    );
    if (notes != null) notes.addAll(out);
    return model;
  }

  static int _span(Object? v) {
    final n = v is num ? v.toInt() : int.tryParse('$v');
    return n == null || n < 1 ? 1 : n;
  }

  static int _flexOf(double width, bool hasColgroup) {
    if (!hasColgroup || width <= 0) return 1;
    final flex = (width * 100).round();
    return flex < 1 ? 1 : flex;
  }

  static OfficeDocTableCellBorder _border(
    Map<String, Object?> attrs,
    String side,
    List<String> notes,
  ) {
    final style = '${attrs['border${side}Style'] ?? ''}'.toLowerCase();
    final w = officeDocImagePx(attrs['border${side}Width']) ?? 0;
    if (style.isNotEmpty &&
        style != 'solid' &&
        style != 'none' &&
        style != 'hidden' &&
        w > 0) {
      const msg = '边框样式非 solid（虚线/点线）无逐像素画笔 → 按 solid 渲染（如实登记）';
      if (!notes.contains(msg)) notes.add(msg);
    }
    return OfficeDocTableCellBorder(
      width: w,
      color: officeDocParseColor(attrs['border${side}Color']),
      style: style.isEmpty ? 'none' : style,
    );
  }
}

/// 真表格 widget：**按 colgroup 比例分配宽度**（不横向滚动）、按 `table_row.height`
/// 固定行高、逐格画底色/边框/垂直对齐。
///
/// [cellBuilder] 由渲染器提供（单元格内容是文档块，需要递归渲染）。
class OfficeDocTable extends StatelessWidget {
  const OfficeDocTable({
    super.key,
    required this.model,
    required this.cellBuilder,
  });

  final OfficeDocTableModel model;

  /// 渲染一格的内容；(cell, rowIndex, cellIndex) → widget。
  final Widget Function(OfficeDocTableCellSpec cell, int rowIndex, int cellIndex)
  cellBuilder;

  @override
  Widget build(BuildContext context) {
    // 有 `colspan/rowspan>1` 且每行都有显式 height → 走**合并**路径（按被跨
    // 行列之和定位/定尺寸）。`colspan` 已由真实样例取证（doc/invoice），
    // `rowspan>1` 仍未取证（见文件头）。
    if (model.canRenderSpans) return _spanLayout(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < model.rows.length; r++) _rowWidget(r),
      ],
    );
  }

  /// 合并路径：按“列宽比例 × 行高”算出每格的矩形，用 [Stack] 绝对定位。
  ///
  /// ✅ `colspan>1` 已由真实样例取证（`doc/invoice`，4 个 `colspan=3,rowspan=1`）：
  /// 合并格 = **1 个宽格**（宽度 = 被跨列宽之和），被跨过的占位格**不渲染**。
  /// ⚠️ `rowspan>1` 无真实样例（见文件头）。
  Widget _spanLayout(BuildContext context) {
    final placements = computeOfficeDocTablePlacements(model);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : model.totalWidthPx;
        final colWidth = <double>[
          for (var i = 0; i < model.columns.length; i++)
            model.effectiveWidth(i, width),
        ];
        final rowHeight = <double>[
          for (final r in model.rows) r.heightPx ?? 0,
        ];
        double before(List<double> xs, int index) {
          var sum = 0.0;
          for (var i = 0; i < index && i < xs.length; i++) {
            sum += xs[i];
          }
          return sum;
        }

        double spanSum(List<double> xs, int start, int count) {
          var sum = 0.0;
          for (var i = start; i < start + count && i < xs.length; i++) {
            sum += xs[i];
          }
          return sum;
        }

        final totalHeight = rowHeight.fold<double>(0, (a, b) => a + b);
        return SizedBox(
          height: totalHeight,
          child: Stack(
            children: [
              for (final p in placements)
                Positioned(
                  left: before(colWidth, p.columnIndex),
                  top: before(rowHeight, p.rowIndex),
                  width: spanSum(colWidth, p.columnIndex, p.columnSpan),
                  height: spanSum(rowHeight, p.rowIndex, p.rowSpan),
                  // 合并格内容**不裁剪**（批 C：真实样例里合并格是"宽格"，
                  // 裁字会让用户看不到内容；几何仍由 Stack 定死，内容更高时
                  // 直接溢出绘制而不被切掉）。
                  child: _cellWidget(p.cell, p.rowIndex, p.cellIndex),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _rowWidget(int rowIndex) {
    final row = model.rows[rowIndex];
    final cells = <Widget>[
      for (var c = 0; c < row.cells.length; c++)
        Expanded(
          // 网格路径下 `colspan` 照算（宽度 = 被跨各列之和）；`rowspan` 只有在
          // 合并路径（canRenderSpans）才生效，这里按单行渲染并登记。
          flex: model.flexForCellSpan(row.cells[c]),
          child: _cellWidget(row.cells[c], rowIndex, c),
        ),
    ];
    final rowWidget = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: cells,
    );
    return KeyedSubtree(
      key: Key('office-doc-table-row-$rowIndex'),
      child: row.heightPx == null
          ? IntrinsicHeight(child: rowWidget)
          // `table_row.height` 作为**最小行高**：真机行高就是"内容所需高度"
          // （Product spec 单行 28px、Vacation packing list 多行 44/91px）。
          // 若用固定高度，内容比 height 高时会被裁掉（用户看不到字），所以
          // 取 max(内容高, height) —— 与"内容正确优先于逐像素复刻"的总原则一致。
          : ConstrainedBox(
              constraints: BoxConstraints(minHeight: row.heightPx!),
              child: IntrinsicHeight(child: rowWidget),
            ),
    );
  }

  Widget _cellWidget(OfficeDocTableCellSpec cell, int rowIndex, int cellIndex) {
    return Container(
      key: Key('office-doc-table-cell-$rowIndex-$cellIndex'),
      decoration: BoxDecoration(
        color: cell.backgroundColor,
        border: Border(
          top: cell.top.toBorderSide(),
          right: cell.right.toBorderSide(),
          bottom: cell.bottom.toBorderSide(),
          left: cell.left.toBorderSide(),
        ),
      ),
      child: Align(
        alignment: switch (cell.verticalAlign) {
          OfficeDocCellVerticalAlign.top => Alignment.topLeft,
          OfficeDocCellVerticalAlign.bottom => Alignment.bottomLeft,
          OfficeDocCellVerticalAlign.middle => Alignment.centerLeft,
        },
        child: Padding(
          // 单元格内边距取最小的 Gap.xxs：真机文本行约 17px + 段落自带
          // paddingTop/Bottom，用更大的内边距会把 28px 行挤爆（会溢出、裁字）。
          padding: const EdgeInsets.all(Gap.xxs),
          child: cellBuilder(cell, rowIndex, cellIndex),
        ),
      ),
    );
  }
}

/// 一个格在网格里的落位（合并路径用）。
class OfficeDocTablePlacement {
  const OfficeDocTablePlacement({
    required this.cell,
    required this.rowIndex,
    required this.cellIndex,
    required this.columnIndex,
    required this.columnSpan,
    required this.rowSpan,
  });

  final OfficeDocTableCellSpec cell;

  /// 起始行（`content` 下标）与在该行 `content` 里的下标（key/编辑路径用）。
  final int rowIndex;
  final int cellIndex;

  /// 起始列 + 实际跨度（已按表边界收敛）。
  final int columnIndex;
  final int columnSpan;
  final int rowSpan;
}

/// 合并落位（**批 C 按真实样例修正**）。
///
/// **真实语义（证据）**：官方模板 `doc/invoice`（夹具
/// `invoice_merged_cells.json`）的合并行 `content` 是
/// `[cell(colspan=3), cell, cell, cell]` —— **一列一个 cell，被跨过的 cell
/// 仍留在树里**（它们的边框色 `#7b8187` 与可见格 `#aaaaaa` 明显不同，是占位格）。
/// 因此：
///   * **合并格的列 = 它在行内的下标**（不是"按 colspan 累加光标"）；
///   * 落在**同一行前面某个 `colspan` 覆盖范围**内的 cell = 占位格 → **跳过、不渲染**；
///   * 被**上方 `rowspan` 占住**的列（真实样例无此形态）→ 该 cell 向右滑到下一空列
///     （这是"行内 cell 数 < 列数"的 Excel 式形态，**未取证**，见文件头）。
///
/// **纯函数**（可离线单测）。
List<OfficeDocTablePlacement> computeOfficeDocTablePlacements(
  OfficeDocTableModel model,
) {
  final cols = model.columns.length;
  final rowCount = model.rows.length;
  if (cols == 0 || rowCount == 0) return const <OfficeDocTablePlacement>[];
  // `occupiedAbove[r][c]`：该格已被**上方 rowspan** 占住（用于向右滑动）。
  final occupiedAbove = List<List<bool>>.generate(
    rowCount,
    (_) => List<bool>.filled(cols, false),
  );
  final out = <OfficeDocTablePlacement>[];
  for (var r = 0; r < rowCount; r++) {
    final cells = model.rows[r].cells;
    // 本行 `colspan` 覆盖到的列（由已落位的 cell 推出）：这些列上的后续 cell
    // 是**占位格**，跳过不渲染（真实样例的 `#7b8187` 格）。
    final coveredBySpan = List<bool>.filled(cols, false);
    for (var ci = 0; ci < cells.length; ci++) {
      final cell = cells[ci];
      // 行内下标即列号（真实样例：每行恰好一列一个 cell）。
      var col = ci;
      if (col >= cols) break; // 真实样例不会出现；多出的 cell 无法定位，不猜列
      if (coveredBySpan[col]) continue; // 被同行 colspan 跨过的占位格
      // 被上方 rowspan 占住 → 向右滑到下一空列（未取证形态，见文件头）。
      while (col < cols && occupiedAbove[r][col]) {
        col += 1;
      }
      if (col >= cols || coveredBySpan[col]) continue;
      final cs = math.min(cell.colspan < 1 ? 1 : cell.colspan, cols - col);
      final rs = math.min(
        cell.rowspan < 1 ? 1 : cell.rowspan,
        rowCount - r,
      );
      for (var rr = r; rr < r + rs; rr++) {
        for (var cc = col; cc < col + cs; cc++) {
          if (rr > r) {
            occupiedAbove[rr][cc] = true;
          } else {
            coveredBySpan[cc] = true;
          }
        }
      }
      out.add(
        OfficeDocTablePlacement(
          cell: cell,
          rowIndex: r,
          cellIndex: ci,
          columnIndex: col,
          columnSpan: cs,
          rowSpan: rs,
        ),
      );
    }
  }
  return out;
}
