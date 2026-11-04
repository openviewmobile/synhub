// 批 B：**真表格**离线测试（`table` / `table_row` / `table_cell`）。
//
// 夹具全部是真实 NAS 文档的原文节点（只读 `Snapshot:get` v4 取得）：
//   * test/fixtures/office_doc_tables/table_trip_planner.json
//   * test/fixtures/office_doc_tables/table_product_spec.json
//   * test/fixtures/office_doc_tables/table_vacation_packing.json
// 见同目录 MANIFEST.json（来源文档名 / 节点数 / sha256 / 未取证说明）。
//
// 无网络、无设备、无构建。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_doc_table.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_doc_view.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/office_doc_tables/$name').readAsStringSync())
        as Map<String, Object?>;

/// 官方模板夹具（`test/fixtures/office_templates/`）：**真实合并单元格**来源。
Map<String, Object?> _templateFixture(String name) =>
    jsonDecode(File('test/fixtures/office_templates/$name').readAsStringSync())
        as Map<String, Object?>;

/// `{content:{data:{content:[…]}}}`（Snapshot / 模板夹具的 section 形状）→ 根节点树。
Object? _sectionsRoot(Map<String, Object?> sections) =>
    ((sections['content'] as Map?)?['data'] as Map?)?['content'];

/// 递归收集某一类型的所有节点（保留文档顺序）。
List<Map<String, Object?>> _collectType(Object? node, String type) {
  final out = <Map<String, Object?>>[];
  void walk(Object? x) {
    if (x is List) {
      for (final y in x) {
        walk(y);
      }
      return;
    }
    if (x is! Map) return;
    if (x['type'] == type) out.add(x.cast<String, Object?>());
    walk(x['content']);
  }

  walk(node);
  return out;
}

Map<String, Object?> _docWithBlocks(List<Object?> blocks) => <String, Object?>{
  'type': 'doc',
  'content': <Object?>[
    <String, Object?>{
      'type': 'edit_area',
      'content': <Object?>[
        <String, Object?>{
          'type': 'paragraph',
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'BODY'},
          ],
        },
        ...blocks,
      ],
    },
  ],
};

Widget _host(Object? doc, [OfficeDocRenderReport? report]) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(
    body: OfficeDocView(doc: doc, report: report, showHeaderNote: false),
  ),
);

Map<String, Object?> _cellWithText(String text) => <String, Object?>{
  'type': 'table_cell',
  'attrs': <String, Object?>{'colspan': 1, 'rowspan': 1},
  'content': <Object?>[
    <String, Object?>{
      'type': 'paragraph',
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': text},
      ],
    },
  ],
};

void main() {
  final trip = _fixture('table_trip_planner.json');
  final spec = _fixture('table_product_spec.json');
  final packing = _fixture('table_vacation_packing.json');

  group('T1. 表格模型按真机字段解析（colgroup 列宽 / 行高 / 边框 / 对齐）', () {
    test('5-day trip planner：colgroup=[413,188]、行高 124、白边框、middle', () {
      final m = OfficeDocTableModel.parse(trip);
      expect(m.hasColgroup, isTrue);
      expect(m.columns.map((c) => c.widthPx).toList(), <double>[413, 188]);
      expect(m.totalWidthPx, 601);
      // flex = width×100 → 比例就是原文像素比例（不是均分）。
      expect(m.columns[0].flex, 41300);
      expect(m.columns[1].flex, 18800);
      expect(m.synotable, '2pgIFIeerl');
      expect(m.rows, hasLength(1));
      expect(m.rows[0].heightPx, 124);
      expect(m.rows[0].cells, hasLength(2));
      final cell = m.rows[0].cells[0];
      expect(cell.colspan, 1);
      expect(cell.rowspan, 1);
      expect(cell.verticalAlign, OfficeDocCellVerticalAlign.middle);
      expect(cell.top.width, 1);
      expect(cell.top.style, 'solid');
      expect(cell.top.color, const Color(0xffffffff));
      // 真机这 42 格里没有任何 backgroundColor 实例 → 底色为 null（不编）。
      expect(cell.backgroundColor, isNull);
      expect(m.spanCellCount, 0, reason: '真实样例没有任何合并单元格');
      expect(m.notes.where((n) => n.contains('合并')).toList(), isEmpty);
    });

    test('Product spec：4 列 / 5 行、每行 28px、#aaaaaa 边框', () {
      final m = OfficeDocTableModel.parse(spec);
      expect(m.columns.map((c) => c.widthPx).toList(), <double>[
        136,
        118,
        232,
        114,
      ]);
      expect(m.totalWidthPx, 600);
      expect(m.rows, hasLength(5));
      expect(m.rows.every((r) => r.heightPx == 28), isTrue);
      expect(
        m.rows[0].cells.every((c) => c.right.color == const Color(0xffaaaaaa)),
        isTrue,
      );
      expect(m.columns[2].flex / m.columns[3].flex, closeTo(232 / 114, 0.001));
    });

    test('Vacation packing list：行高逐行不同（26/44/54/91/53/91）', () {
      final m = OfficeDocTableModel.parse(packing);
      expect(m.columns.map((c) => c.widthPx).toList(), <double>[301, 299]);
      expect(m.rows.map((r) => r.heightPx).toList(), <double?>[
        26,
        44,
        54,
        91,
        53,
        91,
      ]);
    });

    test('超宽策略：按 colgroup 比例分配可用宽度（不横向滚动）', () {
      final m = OfficeDocTableModel.parse(trip);
      // A4 内容宽 ≈ 601.7px（21-5.08cm @96dpi）→ 与原文字节宽度同构。
      expect(m.effectiveWidth(0, 601.7), closeTo(413.5, 0.5));
      expect(m.effectiveWidth(1, 601.7), closeTo(188.2, 0.5));
      // 缩到一半时比例不变、总和恰好等于可用宽（永不溢出）。
      expect(m.effectiveWidth(0, 300), closeTo(206.0, 0.5));
      expect(
        m.effectiveWidth(0, 300) + m.effectiveWidth(1, 300),
        closeTo(300, 0.01),
      );
    });

    test('缺少合法 colgroup → 等分 + 如实登记（未取证形态）', () {
      final m = OfficeDocTableModel.parse(<String, Object?>{
        'type': 'table',
        'attrs': <String, Object?>{'synotable': 'X'},
        'content': <Object?>[
          <String, Object?>{
            'type': 'table_row',
            'content': <Object?>[
              <String, Object?>{
                'type': 'table_cell',
                'attrs': <String, Object?>{},
              },
              <String, Object?>{
                'type': 'table_cell',
                'attrs': <String, Object?>{},
              },
            ],
          },
        ],
      });
      expect(m.hasColgroup, isFalse);
      expect(m.columns.map((c) => c.flex).toList(), <int>[1, 1]);
      expect(m.notes.any((n) => n.contains('colgroup')), isTrue);
    });

    test('合并按每个 cell 自己的 colspan/rowspan 计算，并标注"跨格未取证"', () {
      final m = OfficeDocTableModel.parse(<String, Object?>{
        'type': 'table',
        'attrs': <String, Object?>{
          'colgroup': <Object?>[
            <String, Object?>{'width': 300},
            <String, Object?>{'width': 100},
          ],
        },
        'content': <Object?>[
          <String, Object?>{
            'type': 'table_row',
            'attrs': <String, Object?>{'height': 40},
            'content': <Object?>[
              <String, Object?>{
                'type': 'table_cell',
                'attrs': <String, Object?>{'colspan': 2, 'rowspan': 1},
              },
            ],
          },
        ],
      });
      expect(m.spanCellCount, 1);
      expect(m.maxColspan, 2);
      // 合并后占的 flex = 被跨两列之和（不是单列）。
      expect(
        m.flexForCellSpan(m.rows[0].cells[0]),
        m.columns[0].flex + m.columns[1].flex,
      );
      expect(m.flexForCell(m.rows[0].cells[0]), m.columns[0].flex);
      expect(m.canRenderSpans, isTrue);
      // 批 C：`colspan>1` 已有真实样例（doc/invoice）→ 不再是"未取证"，
      // 断言升级为"必须写出真实证据来源"（更强的断言，不是放宽）。
      expect(
        m.notes.any((n) => n.contains('合并渲染已取证')),
        isTrue,
        reason: 'colspan>1 已由真实样例取证：${m.notes}',
      );
      expect(
        m.notes.any((n) => n.contains('doc/invoice')),
        isTrue,
        reason: '证据来源必须写明：${m.notes}',
      );
      // rowspan=1 → 不应冒称 rowspan>1 已取证。
      expect(
        m.notes.any((n) => n.contains('rowspan>1 合并未取证')),
        isFalse,
        reason: '本例 rowspan=1，不应出现 rowspan>1 未取证登记：${m.notes}',
      );
    });

    test('落位算法：rowspan 占据的格子会被后面的 cell 向右滑动（未取证形态）', () {
      final m = OfficeDocTableModel.parse(<String, Object?>{
        'type': 'table',
        'attrs': <String, Object?>{
          'colgroup': <Object?>[
            <String, Object?>{'width': 300},
            <String, Object?>{'width': 100},
          ],
        },
        'content': <Object?>[
          <String, Object?>{
            'type': 'table_row',
            'attrs': <String, Object?>{'height': 40},
            'content': <Object?>[
              <String, Object?>{
                'type': 'table_cell',
                'attrs': <String, Object?>{'rowspan': 2, 'colspan': 1},
              },
              <String, Object?>{
                'type': 'table_cell',
                'attrs': <String, Object?>{},
              },
            ],
          },
          <String, Object?>{
            'type': 'table_row',
            'attrs': <String, Object?>{'height': 30},
            'content': <Object?>[
              <String, Object?>{
                'type': 'table_cell',
                'attrs': <String, Object?>{},
              },
            ],
          },
        ],
      });
      final ps = computeOfficeDocTablePlacements(m);
      // row0: (col0, rowspan2) + (col1)；row1 的 cell 因为 col0 被占 → 落到 col1。
      expect(ps, hasLength(3));
      expect(ps[0].rowIndex, 0);
      expect(ps[0].columnIndex, 0);
      expect(ps[0].rowSpan, 2);
      expect(ps[1].columnIndex, 1);
      expect(ps[2].rowIndex, 1);
      expect(ps[2].columnIndex, 1);
    });

    test('行高缺失 → 合并路径不可用（退回网格，登记未生效）', () {
      final m = OfficeDocTableModel.parse(<String, Object?>{
        'type': 'table',
        'attrs': <String, Object?>{
          'colgroup': <Object?>[
            <String, Object?>{'width': 300},
            <String, Object?>{'width': 100},
          ],
        },
        'content': <Object?>[
          <String, Object?>{
            'type': 'table_row',
            'content': <Object?>[
              <String, Object?>{
                'type': 'table_cell',
                'attrs': <String, Object?>{'colspan': 2},
              },
            ],
          },
        ],
      });
      expect(m.spanCellCount, 1);
      expect(m.canRenderSpans, isFalse);
    });
  });

  group('T2. 真表格渲染（列宽生效 / 行高生效 / 不溢出）', () {
    testWidgets('列宽按 colgroup 比例：413:188（均分就红）', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(_host(_docWithBlocks(<Object?>[trip]), report));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('office-doc-table')), findsOneWidget);
      final w0 = tester
          .getSize(find.byKey(const Key('office-doc-table-cell-0-0')))
          .width;
      final w1 = tester
          .getSize(find.byKey(const Key('office-doc-table-cell-0-1')))
          .width;
      expect(w0 / w1, closeTo(413 / 188, 0.02));
      expect(w0, greaterThan(w1));
    });

    testWidgets('行高按 table_row.height：放得下时就是 height，内容更高时不裁字', (tester) async {
      // 派生单行（短文本 'A'，内容高 ≈ 24px）+ height=60 → 行高恰好 60：
      // 这证明 `table_row.height` 真的生效（忽略 height 就会退回内容高度）。
      // 说明：测试环境的默认字体比真机 Arial 宽，真实夹具长文本会换行，
      // 所以对真实夹具只断言 >= height（见下）。
      final derived = <String, Object?>{
        'type': 'table',
        'attrs': <String, Object?>{
          'colgroup': <Object?>[
            <String, Object?>{'width': 300},
            <String, Object?>{'width': 300},
          ],
        },
        'content': <Object?>[
          <String, Object?>{
            'type': 'table_row',
            'attrs': <String, Object?>{'height': 60},
            'content': <Object?>[_cellWithText('A'), _cellWithText('B')],
          },
        ],
      };
      await tester.pumpWidget(_host(_docWithBlocks(<Object?>[derived])));
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('office-doc-table-row-0'))).height,
        60,
      );
      // Product spec：每行 height=28；5-day trip planner：height=124。
      await tester.pumpWidget(_host(_docWithBlocks(<Object?>[spec])));
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('office-doc-table-row-0'))).height,
        greaterThanOrEqualTo(28),
      );
      await tester.pumpWidget(_host(_docWithBlocks(<Object?>[trip])));
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('office-doc-table-row-0'))).height,
        greaterThanOrEqualTo(124),
      );
    });

    testWidgets('表格不溢出页面宽度（比例分配，无横向滚动）', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(_host(_docWithBlocks(<Object?>[spec]), report));
      expect(tester.takeException(), isNull, reason: '${report.messages}');
      final tableWidth = tester
          .getSize(find.byKey(const Key('office-doc-table')))
          .width;
      final viewWidth = tester
          .getSize(find.byKey(const Key('office-doc-view')))
          .width;
      expect(tableWidth, lessThanOrEqualTo(viewWidth));
      for (final row in <int>[0, 4]) {
        // height 是最小行高：内容需要更高时行会长高（绝不裁字/溢出）。
        expect(
          tester.getSize(find.byKey(Key('office-doc-table-row-$row'))).height,
          greaterThanOrEqualTo(28),
        );
      }
    });

    testWidgets('单元格底色 / 边框 / 垂直对齐真的画出来', (tester) async {
      // 先把真实 fixture 的一格改成有底色 + 顶对齐：**schema 声明了
      // backgroundColor/verticalAlign，但 42 个真实格子里没有非 null 底色实例**
      // → 该代码路径没有真实素材，这里用真实节点形状注入取值（派生用例，见
      // MANIFEST.json :: derived）。
      final derived = jsonDecode(jsonEncode(spec)) as Map<String, Object?>;
      final firstRow = (derived['content']! as List)[0] as Map<String, Object?>;
      final firstCell =
          (firstRow['content']! as List)[0] as Map<String, Object?>;
      final attrs = (firstCell['attrs']! as Map).cast<String, Object?>();
      attrs['backgroundColor'] = '#ff0000';
      attrs['verticalAlign'] = 'top';
      await tester.pumpWidget(_host(_docWithBlocks(<Object?>[derived])));
      expect(tester.takeException(), isNull);
      final container = tester.widget<Container>(
        find.byKey(const Key('office-doc-table-cell-0-0')),
      );
      final deco = container.decoration! as BoxDecoration;
      expect(deco.color, const Color(0xffff0000));
      final border = deco.border! as Border;
      expect(border.top.color, const Color(0xffaaaaaa));
      expect(border.top.width, 1);
      final align = tester.widget<Align>(
        find
            .descendant(
              of: find.byKey(const Key('office-doc-table-cell-0-0')),
              matching: find.byType(Align),
            )
            .first,
      );
      expect(align.alignment, Alignment.topLeft);
    });

    testWidgets('真表格里的文字仍是"给人看的"，不出现内部标识', (tester) async {
      await tester.pumpWidget(_host(_docWithBlocks(<Object?>[spec])));
      expect(find.text('Version Number', findRichText: true), findsOneWidget);
      expect(find.textContaining('synotable'), findsNothing);
      expect(find.textContaining('colgroup'), findsNothing);
    });

    testWidgets('合并路径（未取证）：rowspan 跨两行高度、colspan 跨满整行', (tester) async {
      // 派生表：colgroup=[200,200]，三行 height=60/50/40（测试字体比真机宽，
      // 行高留足避免内容溢出）：
      //   row0: cell 跨 2 行（第 0 列）+ cell（第 1 列）
      //   row1: cell 只能落到第 1 列（第 0 列被 rowspan 占着）
      //   row2: cell 跨 2 列（整行）
      final derived = <String, Object?>{
        'type': 'table',
        'attrs': <String, Object?>{
          'colgroup': <Object?>[
            <String, Object?>{'width': 200},
            <String, Object?>{'width': 200},
          ],
        },
        'content': <Object?>[
          <String, Object?>{
            'type': 'table_row',
            'attrs': <String, Object?>{'height': 60},
            'content': <Object?>[
              <String, Object?>{
                'type': 'table_cell',
                'attrs': <String, Object?>{'colspan': 1, 'rowspan': 2},
                'content': <Object?>[
                  <String, Object?>{
                    'type': 'paragraph',
                    'content': <Object?>[
                      <String, Object?>{'type': 'text', 'text': 'A'},
                    ],
                  },
                ],
              },
              _cellWithText('B'),
            ],
          },
          <String, Object?>{
            'type': 'table_row',
            'attrs': <String, Object?>{'height': 50},
            'content': <Object?>[_cellWithText('C')],
          },
          <String, Object?>{
            'type': 'table_row',
            'attrs': <String, Object?>{'height': 40},
            'content': <Object?>[
              <String, Object?>{
                'type': 'table_cell',
                'attrs': <String, Object?>{'colspan': 2, 'rowspan': 1},
                'content': <Object?>[
                  <String, Object?>{
                    'type': 'paragraph',
                    'content': <Object?>[
                      <String, Object?>{'type': 'text', 'text': 'D'},
                    ],
                  },
                ],
              },
            ],
          },
        ],
      };
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(
        _host(_docWithBlocks(<Object?>[derived]), report),
      );
      expect(tester.takeException(), isNull, reason: '${report.messages}');
      final tableSize = tester.getSize(
        find.byKey(const Key('office-doc-table')),
      );
      // rowspan=2 的格：高度 = 60 + 50（跨两行），宽度 = 一列。
      final rowSpan = tester.getSize(
        find.byKey(const Key('office-doc-table-cell-0-0')),
      );
      expect(rowSpan.height, 110);
      expect(rowSpan.width, closeTo(tableSize.width / 2, 0.01));
      // row1 的格被推到第 1 列。
      expect(
        tester
            .getSize(find.byKey(const Key('office-doc-table-cell-1-0')))
            .width,
        closeTo(tableSize.width / 2, 0.01),
      );
      // colspan=2 的格：宽度 = 整行。
      final colSpan = tester.getSize(
        find.byKey(const Key('office-doc-table-cell-2-0')),
      );
      expect(colSpan.width, closeTo(tableSize.width, 0.01));
      expect(colSpan.height, 40);
      expect(
        report.messages.any((m) => m.contains('rowspan>1 合并未取证')),
        isTrue,
        reason: '${report.messages}',
      );
    });
  });

  // -----------------------------------------------------------------------
  // T3（批 C）：用**真实合并单元格样例**验证 —— 官方模板 `doc/invoice`
  // 夹具 `test/fixtures/office_templates/invoice_merged_cells.json`，
  // 第二个表有 4 个真实的 `colspan=3, rowspan=1`。
  // -----------------------------------------------------------------------
  group('T3. 真实合并单元格（doc/invoice，colspan=3）', () {
    final invoice = _templateFixture('invoice_merged_cells.json');
    final invoiceTables = _collectType(_sectionsRoot(invoice), 'table');
    final merged = invoiceTables.length > 1
        ? invoiceTables[1]
        : invoiceTables.first;
    const colW = <double>[248, 123, 119, 109];
    const totalW = 599.0; // 248+123+119+109

    test('真实合并样例的形状：4 列 / 15 行 / 4 个 colspan=3,rowspan=1', () {
      final m = OfficeDocTableModel.parse(merged);
      expect(m.hasColgroup, isTrue);
      expect(m.columns.map((c) => c.widthPx).toList(), colW);
      expect(m.totalWidthPx, totalW);
      expect(m.rows, hasLength(15));
      expect(m.spanCellCount, 4);
      expect(m.maxColspan, 3);
      expect(m.maxRowspan, 1);
      expect(m.canRenderSpans, isTrue, reason: '每行都有 height → 合并路径可用');
      expect(
        m.notes.any((n) => n.contains('合并渲染已取证')),
        isTrue,
        reason: '${m.notes}',
      );
      expect(
        m.notes.any((n) => n.contains('rowspan>1 合并未取证')),
        isFalse,
        reason: '真实样例全是 rowspan=1：${m.notes}',
      );
    });

    test('落位：合并格 1 个宽格（跨 3 列），被跨过的 2 个占位格被跳过', () {
      final m = OfficeDocTableModel.parse(merged);
      final ps = computeOfficeDocTablePlacements(m);
      // 每个合并行只落 2 个格（合并格 + 第 4 列），不是 4 个。
      for (final row in <int>[11, 12, 13, 14]) {
        final inRow = ps.where((p) => p.rowIndex == row).toList();
        expect(inRow, hasLength(2), reason: 'row $row 应只渲染 2 个格：$inRow');
        expect(inRow[0].cellIndex, 0);
        expect(inRow[0].columnIndex, 0);
        expect(inRow[0].columnSpan, 3);
        expect(inRow[1].cellIndex, 3, reason: '可见的第 4 列格是 cell#3 而不是 cell#1');
        expect(inRow[1].columnIndex, 3);
        expect(inRow[1].columnSpan, 1);
      }
      // 被跨过的占位格（cell#1/#2）在整张表里**一次都不落位**。
      expect(ps.any((p) => p.rowIndex == 11 && p.cellIndex == 1), isFalse);
      expect(ps.any((p) => p.rowIndex == 11 && p.cellIndex == 2), isFalse);
      // 普通行照旧一列一格。
      final row0 = ps.where((p) => p.rowIndex == 0).toList();
      expect(row0.map((p) => p.columnIndex).toList(), <int>[0, 1, 2, 3]);
    });

    testWidgets('合并格渲染成 1 个宽格（宽 = 被跨 3 列之和），占位格不重复渲染', (tester) async {
      final report = OfficeDocRenderReport();
      await tester.pumpWidget(_host(_docWithBlocks(<Object?>[merged]), report));
      expect(tester.takeException(), isNull, reason: '${report.messages}');
      final tableWidth = tester
          .getSize(find.byKey(const Key('office-doc-table')))
          .width;
      final w3 = tableWidth * colW[3] / totalW;
      final mergedCell = tester.getSize(
        find.byKey(const Key('office-doc-table-cell-11-0')),
      );
      // 直接用"被跨列宽之和"断言（这就是"列宽按 colgroup 比例分配后跨列宽
      // = 被跨列宽之和"）。
      expect(
        mergedCell.width,
        closeTo(tableWidth * (colW[0] + colW[1] + colW[2]) / totalW, 0.5),
      );
      expect(mergedCell.height, 32);
      // 第 4 列可见格：宽度 = 单列。
      final last = tester.getSize(
        find.byKey(const Key('office-doc-table-cell-11-3')),
      );
      expect(last.width, closeTo(w3, 0.5));
      // 被跨过的占位格（cell#1/#2）**不渲染**。
      expect(find.byKey(const Key('office-doc-table-cell-11-1')), findsNothing);
      expect(find.byKey(const Key('office-doc-table-cell-11-2')), findsNothing);
      // 合并格是 1 个格（不是 3 个）：该行只有 2 个格 widget。
      expect(
        find.byKey(const Key('office-doc-table-cell-11-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-doc-table-cell-11-3')),
        findsOneWidget,
      );
    });

    testWidgets('合并格内容不裁字：真实文字完整可见，且没有 ClipRect', (tester) async {
      await tester.pumpWidget(_host(_docWithBlocks(<Object?>[merged])));
      expect(tester.takeException(), isNull);
      expect(find.text('Subtotal', findRichText: true), findsOneWidget);
      expect(
        find.text('Shipping & Handling', findRichText: true),
        findsOneWidget,
      );
      final cell = find.byKey(const Key('office-doc-table-cell-11-0'));
      // 合并格靠 Stack 定位，但**不许**再套 ClipRect（批 B 会裁字）。
      expect(
        find.descendant(of: cell, matching: find.byType(ClipRect)),
        findsNothing,
      );
      // 文字确实落在合并格内部（宽度足够，没有被挤到格子外）。
      expect(
        tester.getSize(cell).width,
        greaterThan(
          tester.getSize(find.text('Subtotal', findRichText: true)).width,
        ),
      );
    });
  });
}
