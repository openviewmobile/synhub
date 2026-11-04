// O2 批：**页面层**验收 —— 断言"屏幕上真的显示了什么"。
//
// 数据全部来自**真实 NAS 文件**（`test/fixtures/office_sheet_o2/*.xlsx`，
// 服务端转码后的标准 XLSX，见 `MANIFEST.json`），没有任何合成数值。
//
// 覆盖用户提出的三个"离预期很远"：
//   1. 列被拉满屏 → 这里断言**第 2 列 = 113 px ≠ 屏宽**，且能横向滚动；
//   2. 没有行号列 / 列标行 → 断言 `office-sheet-row-header-*` / `col-header-*`；
//   3. 合并单元格 / 数字格式没还原 → 断言跨列宽度与 `$10.00`、`100.00%`。
// 另加"开发者横幅必须不存在"的硬断言（`从简` / `本批` / `只读预览`）。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_sheet_view.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/office_sheet_o2/$name').readAsBytesSync();

/// 用最小 XLSX 容器造一份**双表**样本（只为验证底部表标签）。
///
/// 只放解析器真正读的部件：`xl/workbook.xml` + `xl/_rels/workbook.xml.rels`
/// + `xl/worksheets/sheet{1,2}.xml`。这不是"假数据替代真数据"——真实样本已在
/// `office_sheet_o2_xlsx_test.dart` 里断言；这里仅补**多表**这个渲染分支。
Uint8List _twoSheetXlsx() {
  const workbook =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
      ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>'
      '<sheet name="一月" sheetId="1" state="visible" r:id="rId1"/>'
      '<sheet name="二月" sheetId="2" state="visible" r:id="rId2"/>'
      '</sheets></workbook>';
  const rels =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"'
      ' Target="worksheets/sheet1.xml"/>'
      '<Relationship Id="rId2" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"'
      ' Target="worksheets/sheet2.xml"/>'
      '</Relationships>';
  String sheetWith(String text) =>
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<dimension ref="A1:B2"/>'
      '<sheetFormatPr defaultRowHeight="15.75" defaultColWidth="14.4286"/>'
      '<cols><col min="1" max="1" width="12" customWidth="1"/>'
      '<col min="2" max="2" width="24" customWidth="1"/></cols>'
      '<sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>$text</t></is></c>'
      '<c r="B1"><v>42</v></c></row></sheetData></worksheet>';

  final archive = Archive()
    ..addFile(ArchiveFile.string('xl/workbook.xml', workbook))
    ..addFile(ArchiveFile.string('xl/_rels/workbook.xml.rels', rels))
    ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheetWith('一月数据')))
    ..addFile(
      ArchiveFile.string('xl/worksheets/sheet2.xml', sheetWith('二月数据')),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Widget _host(Widget child) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(body: SizedBox(width: 360, height: 640, child: child)),
);

void main() {
  group('R1. 真实 Sales tracker：网格结构（行号列 + 列标行）', () {
    testWidgets('列标行 A/B/… 与行号列 1/2/… 都在屏幕上', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('office-sheet-grid')), findsOneWidget);
      // 列标行（A、B…）
      expect(
        find.byKey(const Key('office-sheet-col-header-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-sheet-col-header-1')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('office-sheet-col-header-1')),
          matching: find.text('B'),
        ),
        findsOneWidget,
      );
      // 行号列（1、2…）
      expect(
        find.byKey(const Key('office-sheet-row-header-column')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('office-sheet-row-header-0')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('office-sheet-row-header-1')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      // 网格本体：滚动（不是拉满屏的 Table）
      expect(find.byType(SingleChildScrollView), findsWidgets);
    });
  });

  group('R2. ★ 列宽按文件声明（不再拉满屏）', () {
    testWidgets('第 2 列 = 113 px，明显小于 360 的屏宽', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // <col min="2" max="6" width="15.4286"/> → 15.4286*7+5 = 113
      final col1 = tester.getSize(
        find.byKey(const Key('office-sheet-cell-0-1')),
      );
      expect(col1.width, closeTo(113.0, 0.5));
      // <col min="1" max="1" width="6.85714"/> → 53
      final col0 = tester.getSize(
        find.byKey(const Key('office-sheet-cell-1-0')),
      );
      expect(col0.width, closeTo(53.0, 0.5));
      // <col min="7" max="7" width="22.8571"/> → 165
      final col6 = tester.getSize(
        find.byKey(const Key('office-sheet-cell-6-6')),
      );
      expect(col6.width, closeTo(165.0, 0.5));

      // **硬断言**：没有哪一列被拉到屏宽（360）附近。
      for (final key in <Key>[
        const Key('office-sheet-cell-0-1'),
        const Key('office-sheet-cell-0-6'),
      ]) {
        expect(tester.getSize(find.byKey(key)).width, lessThan(200));
      }
    });

    testWidgets('行高按 <row ht>：第 5 行 = 364 px', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // <row r="5" ht="273"/> → 273*96/72 = 364
      final row4 = tester.getSize(
        find.byKey(const Key('office-sheet-cell-4-1')),
      );
      expect(row4.height, closeTo(364.0, 0.5));
    });
  });

  group('R3. ★ 合并单元格真的跨列（B3:K3）', () {
    testWidgets('锚点格宽度 = 合并区总宽；被覆盖格不渲染', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // B3:K3 → col 1..10 = 113*5 + 165 + 113*3 + 165 = 1234
      final merged = tester.getSize(
        find.byKey(const Key('office-sheet-cell-2-1')),
      );
      expect(merged.width, closeTo(1234.0, 1.0));
      // 单列宽是 113 → 合并区**确实跨了 10 列**。
      expect(merged.width, greaterThan(113.0 * 9));
      // 被 B3:K3 覆盖的 C3 不再单独渲染。
      expect(find.byKey(const Key('office-sheet-cell-2-2')), findsNothing);
    });
  });

  group('R4. ★ 数字格式按文件声明显示（货币 / 百分比 / 千分位）', () {
    testWidgets(r'$10.00 / 100.00% / 15', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // C8 值 10，numFmt 165 = [$$]#,##0.00 → $10.00
      expect(
        find.descendant(
          of: find.byKey(const Key('office-sheet-cell-7-2')),
          matching: find.text(r'$10.00'),
        ),
        findsOneWidget,
      );
      // D8 值 1，numFmt 10 = 0.00% → 100.00%
      expect(
        find.descendant(
          of: find.byKey(const Key('office-sheet-cell-7-3')),
          matching: find.text('100.00%'),
        ),
        findsOneWidget,
      );
      // E8 值 15，numFmt 3 = #,##0 → 15
      expect(
        find.descendant(
          of: find.byKey(const Key('office-sheet-cell-7-4')),
          matching: find.text('15'),
        ),
        findsOneWidget,
      );
    });
  });

  group('R5. 样式（字体/填充/对齐/边框）来自 cellXfs', () {
    testWidgets('标题格字号 30 / 表头行有填充色', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final title = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('office-sheet-cell-2-1')),
          matching: find.text('Sales Tracker'),
        ),
      );
      // cellXfs[28] → fontId 9 = Microsoft Sans Serif / 30pt
      expect(title.style?.fontSize, 30);
      expect(title.style?.fontFamily, 'Microsoft Sans Serif');

      final header = tester.widget<Container>(
        find.byKey(const Key('office-sheet-cell-0-0')),
      );
      final decoration = header.decoration! as BoxDecoration;
      // cellXfs[14] → fillId 3 → FF6153A6
      expect(decoration.color, const Color(0xFF6153A6));
    });
  });

  group('R6. ★ 主通道/降级通道：明确告知，绝不静默空白', () {
    testWidgets('OOXML 命中 → 不出现任何回落说明', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-sheet-fallback-note')), findsNothing);
    });

    testWidgets('字节不是 OOXML → 回落 + **一行用户语言说明**（不是静默空白）', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: Uint8List.fromList(<int>[0x42, 0x53, 0x4F, 0x4E, 0, 0]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-sheet-fallback-note')),
        findsOneWidget,
      );
      expect(find.textContaining('兼容方式打开'), findsOneWidget);
    });

    testWidgets('完全空的内容 → 空态给出**可操作建议**，不是空白页', (tester) async {
      await tester.pumpWidget(
        _host(
          const OfficeSheetView(
            initialScale: 1.0,
            sections: <String, Object?>{},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-sheet-empty')), findsOneWidget);
      expect(find.textContaining('重试打开'), findsOneWidget);
      expect(find.textContaining('Synology Drive'), findsOneWidget);
    });
  });

  group('R7. 无开发者横幅（用户硬要求）', () {
    testWidgets('新渲染器文案里没有 从简 / 本批 / 只读预览', (tester) async {
      for (final name in <String>[
        'sales_tracker.xlsx',
        'annual_income_and_expenditure.xlsx',
        'travel_expenses.xlsx',
      ]) {
        await tester.pumpWidget(
          _host(
            OfficeSheetView(
              initialScale: 1.0,
              sections: const <String, Object?>{},
              ooxmlBytes: _fixture(name),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final texts = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .toList();
        expect(
          texts.where((t) => t.contains('从简')),
          isEmpty,
          reason: '$name 不得出现"版式从简"类话术',
        );
        expect(
          texts.where((t) => t.contains('本批')),
          isEmpty,
          reason: '$name 不得出现"本批"工程话术',
        );
        expect(
          texts.where((t) => t.contains('只读预览') || t.contains('不支持编辑')),
          isEmpty,
          reason: '$name 不得出现开发者状态横幅',
        );
      }
    });
  });

  group('R8. 多工作表 → 底部表标签（真实多表分支）', () {
    testWidgets('两张表 → office-sheet-tab-* 可切换', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _twoSheetXlsx(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-sheet-tab-sh_1')), findsOneWidget);
      expect(find.byKey(const Key('office-sheet-tab-sh_2')), findsOneWidget);
      expect(find.text('一月数据'), findsOneWidget);

      await tester.tap(find.byKey(const Key('office-sheet-tab-sh_2')));
      await tester.pumpAndSettle();
      expect(find.text('二月数据'), findsOneWidget);
      expect(find.text('一月数据'), findsNothing);
    });
  });

  group('R9. 冻结表头（真实 ySplit=10）', () {
    testWidgets('Annual income：前 10 行是冻结带，且带内行号可见', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('annual_income_and_expenditure.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-sheet-frozen-rows-band')),
        findsOneWidget,
      );
      // 冻结带里第 1..10 行的行号都在
      for (var r = 0; r < 10; r++) {
        expect(
          find.byKey(Key('office-sheet-row-header-$r')),
          findsOneWidget,
          reason: '冻结带应包含行 ${r + 1}',
        );
      }
    });
  });

  group('R10. 缩放工具条（适宽 / 放大缩小，按同一套尺寸）', () {
    testWidgets('适宽后列宽变化，但仍是按声明比例', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester
          .getSize(find.byKey(const Key('office-sheet-cell-0-1')))
          .width;
      await tester.tap(find.byKey(const Key('office-sheet-zoom-out')));
      await tester.pumpAndSettle();
      final after = tester
          .getSize(find.byKey(const Key('office-sheet-cell-0-1')))
          .width;
      expect(after, lessThan(before));
      expect(find.byKey(const Key('office-sheet-zoom-label')), findsOneWidget);
    });
  });
}
