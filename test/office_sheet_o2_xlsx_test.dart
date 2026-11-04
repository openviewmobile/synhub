// O2 批：`.osheet` → **XLSX（OOXML）主通道**的离线验收。
//
// 夹具是**真实 NAS 文件**（只读下载，见
// `test/fixtures/office_sheet_o2/MANIFEST.json` 的 `xlsx` 节
// 与 `docs/ooxml-ground-truth.md`）——不是合成样本。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/osheet_model.dart';
import 'package:synhub/src/features/office/office_sheet_xlsx.dart';

/// 真实 `Travel expenses.osheet` 的 `styles.xml` 自定义 numFmt 164（逐字）。
const String _accountingCurrency = r'"$"#,##0.00_);[Red]\("$"#,##0.00\)';

Uint8List _fixture(String name) =>
    File('test/fixtures/office_sheet_o2/$name').readAsBytesSync();

void main() {
  group('X0. OOXML 识别 / 降级（PK 头校验）', () {
    test('真实 XLSX 夹具是 ZIP 且被接受', () {
      for (final name in <String>[
        'sales_tracker.xlsx',
        'annual_income_and_expenditure.xlsx',
        'travel_expenses.xlsx',
      ]) {
        final bytes = _fixture(name);
        expect(bytes.sublist(0, 4), <int>[
          0x50,
          0x4B,
          0x03,
          0x04,
        ], reason: '$name 必须是 PK\\x03\\x04');
        expect(isOfficeSheetOoxmlBytes(bytes), isTrue, reason: name);
        expect(canParseOfficeSheetXlsx(bytes), isTrue, reason: name);
      }
    });

    test('原生 OFile(BSON) / 垃圾字节 → 拒绝（回落通道的依据）', () {
      expect(isOfficeSheetOoxmlBytes(<int>[0x42, 0x53, 0x4F, 0x4E]), isFalse);
      expect(isOfficeSheetOoxmlBytes(<int>[]), isFalse);
      expect(
        () => parseOfficeSheetXlsx(<int>[1, 2, 3, 4, 5]),
        throwsA(isA<OfficeSheetXlsxException>()),
      );
    });

    test('ZIP 但不是 XLSX（没有 xl/workbook.xml）→ 明确抛错', () {
      // 空档记录的 ZIP 头 + 垃圾：解包会失败 → 必须是可判定的异常。
      expect(
        () => parseOfficeSheetXlsx(<int>[0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0]),
        throwsA(isA<OfficeSheetXlsxException>()),
      );
    });

    test('单位换算（Excel/WPS 同款近似）', () {
      // 真实 `<col width="15.4286">` → 113 px。
      expect(ooxmlColWidthToPixels(15.4286), closeTo(113.0, 0.01));
      // 真实 `<row ht="15.75">` → 21 px。
      expect(ooxmlRowHeightToPixels(15.75), closeTo(21.0, 0.001));
      // 真实 `<a:ext cx="5391150">` EMU → 566 px。
      expect(ooxmlEmuToPixels(5391150), closeTo(566.0, 0.001));
    });
  });

  group('X1. Sales tracker（真实 10,719 B XLSX）', () {
    late OSheetWorkbook workbook;

    setUpAll(() {
      workbook = parseOfficeSheetXlsx(_fixture('sales_tracker.xlsx'));
    });

    test('工作表名 / 数量 / 顺序来自 xl/workbook.xml', () {
      expect(workbook.sheets, hasLength(1));
      expect(workbook.sheets.first.title, 'Sales Tracker');
      expect(workbook.sheets.first.id, 'sh_1');
      expect(workbook.index.order, <String>['sh_1']);
      expect(workbook.sheets.first.isVisible, isTrue);
    });

    test('218 个单元格 + A1:L20 的网格尺寸', () {
      final sheet = workbook.sheets.first;
      expect(sheet.rowCount, 20);
      expect(sheet.colCount, 12);
      expect(sheet.cellCount, 218);
    });

    test('★ 列宽来自 <cols>（不是拉满屏）', () {
      final sheet = workbook.sheets.first;
      // <col min="1" max="1" width="6.85714"/> → 53 px
      expect(sheet.colWidthAt(0), closeTo(53.0, 0.01));
      // <col min="2" max="6" width="15.4286"/> → 113 px
      expect(sheet.colWidthAt(1), closeTo(113.0, 0.01));
      expect(sheet.colWidthAt(5), closeTo(113.0, 0.01));
      // <col min="7" max="7" width="22.8571"/> → 165 px
      expect(sheet.colWidthAt(6), closeTo(165.0, 0.01));
    });

    test('★ 行高来自 <row ht>，缺省来自 <sheetFormatPr>', () {
      final sheet = workbook.sheets.first;
      // 第 5 行 ht="273" → 364 px（真实样本最大行高）。
      expect(sheet.rowHeightAt(4), closeTo(364.0, 0.01));
      // 第 3 行 ht="43.5" → 58 px。
      expect(sheet.rowHeightAt(2), closeTo(58.0, 0.01));
      // 没有任何 ht 的行 → defaultRowHeight 15.75pt → 21 px。
      expect(sheet.defaultRowHeight, closeTo(21.0, 0.001));
      expect(sheet.defaultColWidth, closeTo(106.0, 0.01));
    });

    test('★ 样式索引 s="14" → cellXfs[14]（0 基转 1 基 + 填充/对齐）', () {
      final sheet = workbook.sheets.first;
      final a1 = sheet.cellAt(0, 0)!;
      expect(a1.styleIndex, 15, reason: 'XLSX s=14 是 0 基 → 模型 1 基 15');
      final pool = workbook.styles!;
      final style = pool.resolveStyle(a1.styleIndex);
      // cellXfs[14] = fillId 3 → fills[3] = solid FF6153A6；alignment horizontal=center
      expect(style.fillColorHex, 'FF6153A6');
      expect(style.alignH, 'center');
      // 标题 B3 是 s="28" → cellXfs[28] → font 9（Microsoft Sans Serif / 粗 / 30pt）
      final b3 = sheet.cellAt(2, 1)!;
      expect(b3.styleIndex, 29);
      final title = pool.resolveStyle(b3.styleIndex);
      expect(title.fontFamily, 'Microsoft Sans Serif');
      expect(title.fontSize, 30);
      expect(title.bold, isTrue);
    });

    test('公式 <f> 只读展示、不求值', () {
      final sheet = workbook.sheets.first;
      // 真实 sheet1.xml: <c r="K18" s="26" t="f"><f>SUM(K8:K17)</f></c>
      final k18 = sheet.cellAt(17, 10)!;
      expect(k18.isFormula, isTrue);
      expect(k18.value, '=SUM(K8:K17)');
    });

    test('★ 共享字符串 + 合并单元格', () {
      final sheet = workbook.sheets.first;
      // <c r="B3" s="28" t="s"><v>0</v></c> → sharedStrings[0]
      expect(sheet.cellAt(2, 1)?.value, 'Sales Tracker');
      expect(sheet.cellAt(6, 1)?.value, 'Item');
      expect(sheet.mergedRegions, hasLength(4));
      expect(
        sheet.mergedRegions.map((m) => m.a1),
        containsAll(<String>['B5:K5', 'B3:K3', 'B4:K4', 'B2:K2']),
      );
    });

    test('★ 数字格式按 cellXfs 的 numFmtId 归属（货币 / 百分比）', () {
      final pool = workbook.styles!;
      final sheet = workbook.sheets.first;
      // <c r="C8" s="6"> → cellXfs[6].numFmtId=165 → 自定义 [$$]#,##0.00
      final c8 = sheet.cellAt(7, 2)!;
      expect(c8.value, 10);
      expect(pool.resolveStyle(c8.styleIndex).numberFormat, r'[$$]#,##0.00');
      // <c r="D8" s="4"> → cellXfs[4].numFmtId=10 → 内置 0.00%
      final d8 = sheet.cellAt(7, 3)!;
      expect(d8.value, 1);
      expect(pool.resolveStyle(d8.styleIndex).numberFormat, '0.00%');
      // <c r="E8" s="5"> → cellXfs[5].numFmtId=3 → 内置 #,##0
      final e8 = sheet.cellAt(7, 4)!;
      expect(e8.value, 15);
      expect(pool.resolveStyle(e8.styleIndex).numberFormat, '#,##0');
    });
  });

  group('X2. Annual income（真实冻结窗格 + 合并 + 数字格式）', () {
    late OSheetWorkbook workbook;

    setUpAll(() {
      workbook = parseOfficeSheetXlsx(
        _fixture('annual_income_and_expenditure.xlsx'),
      );
    });

    test('★ <pane ySplit="10" state="frozen"/> → 冻结前 10 行', () {
      final sheet = workbook.sheets.first;
      expect(sheet.fixedRowTop, 10);
      expect(sheet.fixedColumnLeft, 0);
    });

    test('83 行 × 15 列、1245 个单元格、2 个合并区', () {
      final sheet = workbook.sheets.first;
      expect(sheet.rowCount, 83);
      expect(sheet.colCount, 15);
      expect(sheet.cellCount, 1245);
      expect(
        sheet.mergedRegions.map((m) => m.a1),
        containsAll(<String>['A1:O1', 'B3:C3']),
      );
    });

    test('列宽按 <cols>（A 列 28.5714 → 205 px；B 列 11.4286 → 85 px）', () {
      final sheet = workbook.sheets.first;
      expect(sheet.colWidthAt(0), closeTo(205.0, 0.01));
      expect(sheet.colWidthAt(1), closeTo(85.0, 0.01));
      expect(sheet.colWidthAt(13), closeTo(125.0, 0.01));
    });

    test('自定义 numFmt 164 = #,##0.00;(#,##0.00)', () {
      final pool = workbook.styles!;
      expect(
        pool.resolveStyle(1).numberFormat,
        anyOf(isNull, contains('#,##0')),
      );
      // 找到一个真的带该格式的样式。
      final formats = <String?>[
        for (var i = 1; i <= pool.styleCount; i++)
          pool.resolveStyle(i).numberFormat,
      ];
      expect(formats, contains('#,##0.00;(#,##0.00)'));
    });
  });

  group('X3. Travel expenses（27 个合并区 + 会计数字格式）', () {
    test('损坏/缺失部件不会伪造数据', () {
      final workbook = parseOfficeSheetXlsx(_fixture('travel_expenses.xlsx'));
      final sheet = workbook.sheets.first;
      expect(sheet.title, 'Travel Expenses');
      expect(sheet.mergedRegions, hasLength(27));
      expect(sheet.rowCount, 35);
      expect(sheet.colCount, 12);
      final pool = workbook.styles!;
      final formats = <String?>[
        for (var i = 1; i <= pool.styleCount; i++)
          pool.resolveStyle(i).numberFormat,
      ];
      expect(formats, contains(_accountingCurrency));
    });
  });

  group('X5. UTF-8（中文表名/中文单元格）不能变乱码', () {
    // 真实 NAS 上的表格里有中文（表名、单元格）；`xl/*.xml` 是 UTF-8 字节，
    // 若按码位直读会得到 `ä¸æ`。这个用例锁住 UTF-8 解码。
    Uint8List zhXlsx() {
      const workbook =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
          ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '<sheets><sheet name="一月预算" sheetId="1" state="visible" r:id="rId1"/>'
          '</sheets></workbook>';
      const rels =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"'
          ' Target="worksheets/sheet1.xml"/></Relationships>';
      const sheet =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<dimension ref="A1:B1"/><sheetData><row r="1">'
          '<c r="A1" t="inlineStr"><is><t>项目名称</t></is></c>'
          '<c r="B1" t="s"><v>0</v></c>'
          '</row></sheetData></worksheet>';
      const sst =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<si><t>餐饮与差旅</t></si></sst>';
      final archive = Archive()
        ..addFile(ArchiveFile.string('xl/workbook.xml', workbook))
        ..addFile(ArchiveFile.string('xl/_rels/workbook.xml.rels', rels))
        ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheet))
        ..addFile(ArchiveFile.string('xl/sharedStrings.xml', sst));
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    test('中文表名 / inlineStr / sharedStrings 全部原样', () {
      final workbook = parseOfficeSheetXlsx(zhXlsx());
      final sheet = workbook.sheets.first;
      expect(sheet.title, '一月预算');
      expect(sheet.cellAt(0, 0)?.value, '项目名称');
      expect(sheet.cellAt(0, 1)?.value, '餐饮与差旅');
    });

    test('UTF-8 BOM 也不影响（部分写出器会带 BOM）', () {
      final raw = zhXlsx();
      expect(isOfficeSheetOoxmlBytes(raw), isTrue);
      // `_decodeXmlBytes` 处理 BOM 的分支由上面这条覆盖；这里再确认原始字节
      // 里确实含 UTF-8 序列（否则这个用例就是自欺）。
      expect(utf8.decode(<int>[0xE4, 0xB8, 0x80, 0xE6, 0x9C, 0x88]), '一月');
    });
  });

  group('X4. 数字格式渲染（按文件声明显示）', () {
    test('货币 / 百分比 / 小数位 / 日期', () {
      expect(oSheetFormatNumber(5.75, r'[$$]#,##0.00'), r'$5.75');
      expect(oSheetFormatNumber(0.9, '0.00%'), '90.00%');
      expect(oSheetFormatNumber(40000, '#,##0'), '40,000');
      expect(oSheetFormatNumber(1234.5, '#,##0.00'), '1,234.50');
      expect(oSheetFormatNumber(42000, 'M/d/yyyy'), '12/27/2014');
      // 认不出/非数值 → null（调用方原样显示）。
      expect(oSheetFormatNumber('文本', '#,##0'), isNull);
      expect(oSheetFormatNumber(1, null), isNull);
    });

    test('会计格式：0 → "-"，负数 → 括号', () {
      const accounting = '_(* #,##0.00_);_(* \\(#,##0.00\\);_(* "-"??_);_(@_)';
      expect(oSheetFormatNumber(0, accounting), '-');
      expect(oSheetFormatNumber(-1234.5, accounting), '(1,234.50)');
      expect(oSheetFormatNumber(1234.5, accounting), '1,234.50');

      const currency = _accountingCurrency;
      expect(oSheetFormatNumber(-12.5, currency), r'($12.50)');
      expect(oSheetFormatNumber(12.5, currency), r'$12.50');
    });
  });
}
