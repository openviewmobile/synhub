// O4 批：OOXML 颜色解引用（`theme1.xml` / `tint` / `indexed` / 自动色）的**离线**
// 单元验收。
//
// 事实来源分两层，测试里也分开断言，**不混为一谈**：
//   * 【实测】真实 NAS 样本 `test/fixtures/office_sheet_o2/*.xlsx` 的
//     `xl/theme/theme1.xml` 逐字内容 → 本文件从**真实字节**里解包后断言；
//   * 【推导】`<color theme="N">` 的 N→槽位映射与 `tint` 演算：
//     来自 Apache POI `ThemesTable.ThemeElement` / `XSSFColor.getTint()` javadoc
//     复述的 ECMA-376 口径（见 `office_sheet_ooxml_color.dart` 文件头）。
//     本批三份样本里 `theme=` / `tint=` 出现次数为 **0**，所以这两条**没有**
//     真实样本可交叉验证 —— 测试断言的是"实现符合该推导"，不是"样本实测"。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:synhub/src/data/office_native/osheet_model.dart';
import 'package:synhub/src/features/office/office_sheet_ooxml_color.dart';
import 'package:synhub/src/features/office/office_sheet_style.dart';
import 'package:synhub/src/features/office/office_sheet_xlsx.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/office_sheet_o2/$name').readAsBytesSync();

/// 从真实 XLSX 字节里取出某个部件的文本（用于读取**真实** `theme1.xml`）。
String? _part(Uint8List bytes, String name) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final file = archive.findFile(name);
  return file == null ? null : String.fromCharCodes(file.readBytes()!);
}

/// `<color …/>` 元素本身（`<c …/>` 就是根元素，没有子元素）。
XmlElement _colorEl(String xml) => XmlDocument.parse(xml).rootElement;

void main() {
  group('C1. 真实 theme1.xml（实测：来自真实 NAS 样本字节）', () {
    late OfficeSheetThemeScheme scheme;

    setUpAll(() {
      final bytes = _fixture('annual_income_and_expenditure.xlsx');
      final themeXml = _part(bytes, 'xl/theme/theme1.xml');
      expect(themeXml, isNotNull, reason: '真实样本必须带 xl/theme/theme1.xml');
      scheme = OfficeSheetThemeScheme.parse(themeXml)!;
    });

    test('clrScheme 十二色逐字解出（srgbClr@val + sysClr@lastClr）', () {
      // 逐字来自该文件 `<a:clrScheme name="Theme1">`：
      //   dk1=<sysClr val="windowText" lastClr="000000"/>
      //   lt1=<sysClr val="window" lastClr="FFFFFF"/>
      //   dk2=1F497D  lt2=EEECE1  accent1=4F81BD accent2=C0504D accent3=9BBB59
      //   accent4=8064A2 accent5=4BACC6 accent6=F79646 hlink=0000FF folHlink=800080
      expect(scheme.bySlot(OfficeSheetThemeSlot.dk1), const Color(0xFF000000));
      expect(scheme.bySlot(OfficeSheetThemeSlot.lt1), const Color(0xFFFFFFFF));
      expect(scheme.bySlot(OfficeSheetThemeSlot.dk2), const Color(0xFF1F497D));
      expect(scheme.bySlot(OfficeSheetThemeSlot.lt2), const Color(0xFFEEECE1));
      expect(
        scheme.bySlot(OfficeSheetThemeSlot.accent1),
        const Color(0xFF4F81BD),
      );
      expect(
        scheme.bySlot(OfficeSheetThemeSlot.accent2),
        const Color(0xFFC0504D),
      );
      expect(
        scheme.bySlot(OfficeSheetThemeSlot.accent3),
        const Color(0xFF9BBB59),
      );
      expect(
        scheme.bySlot(OfficeSheetThemeSlot.accent4),
        const Color(0xFF8064A2),
      );
      expect(
        scheme.bySlot(OfficeSheetThemeSlot.accent5),
        const Color(0xFF4BACC6),
      );
      expect(
        scheme.bySlot(OfficeSheetThemeSlot.accent6),
        const Color(0xFFF79646),
      );
      expect(
        scheme.bySlot(OfficeSheetThemeSlot.hlink),
        const Color(0xFF0000FF),
      );
      expect(
        scheme.bySlot(OfficeSheetThemeSlot.folHlink),
        const Color(0xFF800080),
      );
    });

    test('sysClr 取 lastClr（不是系统别名 val）', () {
      // 若错取 `val="window"` 当颜色 → 解析失败；正确实现必须拿 lastClr。
      final parsed = OfficeSheetThemeScheme.parse(
        '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<a:themeElements><a:clrScheme name="T">'
        '<a:dk1><a:sysClr val="windowText" lastClr="102030"/></a:dk1>'
        '<a:lt1><a:sysClr val="window" lastClr="FEDCBA"/></a:lt1>'
        '</a:clrScheme></a:themeElements></a:theme>',
      )!;
      expect(parsed.bySlot(OfficeSheetThemeSlot.dk1), const Color(0xFF102030));
      expect(parsed.bySlot(OfficeSheetThemeSlot.lt1), const Color(0xFFFEDCBA));
    });

    test('缺 theme1.xml / 坏 XML → null（不抛，调用方退默认主题）', () {
      expect(OfficeSheetThemeScheme.parse(null), isNull);
      expect(OfficeSheetThemeScheme.parse('   '), isNull);
      expect(OfficeSheetThemeScheme.parse('<a:theme 这不是 XML'), isNull);
      expect(
        OfficeSheetThemeScheme.parse(
          '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"/>',
        ),
        isNull,
      );
    });
  });

  group('C2. ★ theme="N" 的下标映射（推导：POI ThemesTable.ThemeElement）', () {
    test('0..11 → lt1,dk1,lt2,dk2,accent1..6,hlink,folHlink（0↔1 / 2↔3 互换）', () {
      const expected = <int, OfficeSheetThemeSlot>{
        0: OfficeSheetThemeSlot.lt1,
        1: OfficeSheetThemeSlot.dk1,
        2: OfficeSheetThemeSlot.lt2,
        3: OfficeSheetThemeSlot.dk2,
        4: OfficeSheetThemeSlot.accent1,
        5: OfficeSheetThemeSlot.accent2,
        6: OfficeSheetThemeSlot.accent3,
        7: OfficeSheetThemeSlot.accent4,
        8: OfficeSheetThemeSlot.accent5,
        9: OfficeSheetThemeSlot.accent6,
        10: OfficeSheetThemeSlot.hlink,
        11: OfficeSheetThemeSlot.folHlink,
      };
      expected.forEach((index, slot) {
        expect(
          kOfficeSheetThemeSlotByIndex[index],
          slot,
          reason: 'theme="$index" 必须映射到 $slot',
        );
      });
      expect(kOfficeSheetThemeSlotByIndex, hasLength(12));
    });

    test('★ 映射**不是** theme1.xml 的物理顺序（0 是 lt1 不是 dk1）', () {
      // 若哪天有人"顺手"改成物理顺序，这条会红：物理顺序第 0 个是 dk1。
      expect(officeSheetThemeSlotByName['dk1'], OfficeSheetThemeSlot.dk1);
      // 物理顺序（元素名表）里 dk1 在 lt1 前；下标表里 lt1 在 dk1 前。
      expect(kOfficeSheetThemeSlotByIndex[0], isNot(OfficeSheetThemeSlot.dk1));
    });

    test('theme="4" 在真实主题上 = accent1 = 4F81BD', () {
      final scheme = OfficeSheetThemeScheme.parse(
        _part(
          _fixture('annual_income_and_expenditure.xlsx'),
          'xl/theme/theme1.xml',
        ),
      )!;
      expect(officeSheetThemeColor(4, theme: scheme), const Color(0xFF4F81BD));
      expect(officeSheetThemeColor(0, theme: scheme), const Color(0xFFFFFFFF));
      expect(officeSheetThemeColor(1, theme: scheme), const Color(0xFF000000));
      // 越界 → null（不崩、不乱编色）。
      expect(officeSheetThemeColor(12, theme: scheme), isNull);
      expect(officeSheetThemeColor(-1, theme: scheme), isNull);
    });
  });

  group('C3. tint 演算（推导：POI XSSFColor.getTint javadoc / ECMA-376）', () {
    test('tint 边界：0 不变、+1 变白、-1 变黑', () {
      const base = Color(0xFF4F81BD);
      expect(officeSheetApplyTint(base, 0), base);
      expect(officeSheetApplyTint(base, 1.0), const Color(0xFFFFFFFF));
      expect(officeSheetApplyTint(base, -1.0), const Color(0xFF000000));
    });

    test('★ POI javadoc 算例：Lum=100/255, tint=0.75 → ≈217（允许 ±1）', () {
      // javadoc: Lum' = 100*(1-.75) + (255 - 255*(1-.75)) = 25 + 192 = 217
      // （POI 的算例用整数截断 255*.25=63 ⇒ 192；本实现走浮点 ⇒ 216.25）
      // 两者是**同一个公式**的不同舍入，所以这里允许 ±1，并把这个差异写清楚。
      const gray100 = Color(0xFF646464); // HLS L = 100/255
      final out = officeSheetApplyTint(gray100, 0.75);
      expect((out.r * 255).round(), closeTo(217, 1));
    });

    test('★ POI javadoc 算例：Lum=200/255, tint=-0.5 → 100（±1）', () {
      const gray200 = Color(0xFFC8C8C8); // HLS L = 200/255
      final out = officeSheetApplyTint(gray200, -0.5);
      expect((out.r * 255).round(), closeTo(100, 1));
    });

    test('单调性：正 tint 变亮、负 tint 变暗（任何底色）', () {
      for (final base in <Color>[
        const Color(0xFF4F81BD),
        const Color(0xFF9BBB59),
        const Color(0xFF7F7F7F),
      ]) {
        final l0 = base.computeLuminance();
        expect(
          officeSheetApplyTint(base, 0.4).computeLuminance(),
          greaterThan(l0),
        );
        expect(
          officeSheetApplyTint(base, -0.4).computeLuminance(),
          lessThan(l0),
        );
      }
    });

    test('tint 越界被夹到 [-1,1]（不产生非法色）', () {
      const base = Color(0xFF4F81BD);
      expect(officeSheetApplyTint(base, 9.0), const Color(0xFFFFFFFF));
      expect(officeSheetApplyTint(base, -9.0), const Color(0xFF000000));
    });
  });

  group('C4. `<color>` 四写法解引用（rgb / theme+tint / indexed / 自动）', () {
    test('rgb 字面色优先，且以文件为准', () {
      expect(
        officeSheetColorFromElement(_colorEl('<c rgb="FF4DBF7C"/>'), null),
        const Color(0xFF4DBF7C),
      );
    });

    test('theme + tint：引用色真的被解出来（不是丢掉）', () {
      final scheme = OfficeSheetThemeScheme.fallback;
      // theme=4 → accent1 4F81BD
      expect(
        officeSheetColorFromElement(_colorEl('<c theme="4"/>'), scheme),
        const Color(0xFF4F81BD),
      );
      // theme=4 + tint 0.4 → 比原色亮
      final tinted = officeSheetColorFromElement(
        _colorEl('<c theme="4" tint="0.4"/>'),
        scheme,
      )!;
      expect(
        tinted.computeLuminance(),
        greaterThan(const Color(0xFF4F81BD).computeLuminance()),
      );
      // theme 缺失（无 theme1.xml）也退默认主题，不返回 null
      expect(
        officeSheetColorFromElement(_colorEl('<c theme="4"/>'), null),
        const Color(0xFF4F81BD),
      );
    });

    test('indexed：传统 64 色表 + 系统色 64/65 = 自动', () {
      expect(officeSheetIndexedColor(2), const Color(0xFFFF0000));
      expect(officeSheetIndexedColor(8), const Color(0xFF000000));
      expect(officeSheetIndexedColor(22), const Color(0xFFC0C0C0));
      expect(officeSheetIndexedColor(53), const Color(0xFFFF6600));
      expect(officeSheetIndexedColor(64), isNull, reason: '64 = 系统前景 = 自动');
      expect(officeSheetIndexedColor(65), isNull, reason: '65 = 系统背景 = 自动');
      expect(officeSheetIndexedColor(999), isNull);
      expect(
        officeSheetColorFromElement(_colorEl('<c indexed="2"/>'), null),
        const Color(0xFFFF0000),
      );
    });

    test('★ 自动（auto / 空元素 / 无 color）→ null，**不编默认色**', () {
      // 这条是本批的核心：null 才会让渲染层按底色对比度选黑/白。
      expect(officeSheetColorFromElement(null, null), isNull);
      expect(
        officeSheetColorFromElement(_colorEl('<c auto="1"/>'), null),
        isNull,
      );
      expect(officeSheetColorFromElement(_colorEl('<c/>'), null), isNull);
    });

    test('颜色 → 存储串：8 位大写无 #（与既有池形态一致）', () {
      expect(officeSheetColorToHex(const Color(0xFF6153A6)), 'FF6153A6');
      expect(officeSheetColorToHex(const Color(0xFFFFFFFF)), 'FFFFFFFF');
      expect(
        officeSheetColorHexFromElement(_colorEl('<c theme="4"/>'), null),
        'FF4F81BD',
      );
    });
  });

  group('C5. 对比度：OOXML "自动"文字色（本仓规则：WCAG 取反差大者）', () {
    test('无填充（白纸）→ 黑字', () {
      expect(officeSheetAutomaticTextColor(null), const Color(0xFF000000));
    });

    test('★ 真实文件里"浅底 + 未声明字色"的行 → 黑字（旧实现给白字 → 看不见）', () {
      // 这三行就是真机截图上"几乎看不见"的行，填充色逐字来自真实 styles.xml：
      //   A5/A6/A7/A8 fill F0F2F4、A22 fill E6FAEE、A3 fill AAD4F2
      for (final fill in <Color>[
        const Color(0xFFF0F2F4),
        const Color(0xFFE6FAEE),
        const Color(0xFFAAD4F2),
        const Color(0xFFD9EFFF),
      ]) {
        expect(
          officeSheetAutomaticTextColor(fill),
          const Color(0xFF000000),
          reason: '浅底必须配黑字',
        );
        // 并且黑字的反差确实更大
        expect(
          officeSheetContrastRatio(fill, const Color(0xFF000000)),
          greaterThan(officeSheetContrastRatio(fill, const Color(0xFFFFFFFF))),
        );
      }
    });

    test('深底 → 白字', () {
      for (final fill in <Color>[
        const Color(0xFF000000),
        const Color(0xFF1F497D),
        const Color(0xFF333333),
      ]) {
        expect(officeSheetAutomaticTextColor(fill), const Color(0xFFFFFFFF));
      }
    });

    test('选出的自动色**必定**满足 WCAG AA 正文 4.5:1（浅底行）', () {
      for (final fill in <Color>[
        const Color(0xFFF0F2F4),
        const Color(0xFFE6FAEE),
        const Color(0xFFAAD4F2),
        const Color(0xFFD9EFFF),
        const Color(0xFFFFFFFF),
      ]) {
        final fg = officeSheetAutomaticTextColor(fill);
        expect(
          officeSheetContrastRatio(fill, fg),
          greaterThanOrEqualTo(4.5),
          reason: '$fill 上的自动字色反差不足',
        );
      }
    });

    test('半透明填充按叠在白纸上算（防御性）', () {
      expect(
        officeSheetAutomaticTextColor(const Color(0x22000000)),
        const Color(0xFF000000),
        reason: '22% 黑叠白纸 ≈ 很浅的灰 → 黑字',
      );
    });
  });

  group('C6. ★ 真实年度收支表：逐格（填充, 字色）解析结果', () {
    late OSheetWorkbook workbook;

    setUpAll(() {
      workbook = parseOfficeSheetXlsx(
        _fixture('annual_income_and_expenditure.xlsx'),
      );
    });

    ({Color? fill, Color? font}) resolved(int r, int c) {
      final sheet = workbook.sheets.first;
      final style = officeSheetResolveStyle(
        pool: workbook.styles,
        styleId: sheet.cellAt(r, c)!.styleIndex,
      );
      return (fill: style.fillColor, font: style.fontColor);
    }

    test('A5「Total Income」：浅灰底 + **无显式字色** → 自动黑字', () {
      final s = resolved(4, 0);
      expect(s.fill, const Color(0xFFF0F2F4));
      expect(s.font, isNull, reason: '文件没给字色 → 必须留给对比度判定');
      expect(officeSheetAutomaticTextColor(s.fill), const Color(0xFF000000));
    });

    test('A22「Total」：浅绿底 + 无显式字色 → 自动黑字', () {
      final s = resolved(21, 0);
      expect(s.fill, const Color(0xFFE6FAEE));
      expect(s.font, isNull);
      expect(officeSheetAutomaticTextColor(s.fill), const Color(0xFF000000));
    });

    test('A3「Starting Balance」：浅蓝底 + 无显式字色 → 自动黑字', () {
      final s = resolved(2, 0);
      expect(s.fill, const Color(0xFFAAD4F2));
      expect(s.font, isNull);
      expect(officeSheetAutomaticTextColor(s.fill), const Color(0xFF000000));
    });

    test('★ A12「INCOME」：文件**显式**给了白字 → 以文件为准（不被对比度改写）', () {
      final s = resolved(11, 0);
      expect(s.fill, const Color(0xFF4DBF7C));
      expect(s.font, const Color(0xFFFFFFFF));
    });

    test('★ A1 标题：文件显式白字 + 蓝底 → 以文件为准', () {
      final s = resolved(0, 0);
      expect(s.fill, const Color(0xFF419AD9));
      expect(s.font, const Color(0xFFFFFFFF));
    });

    test('A24「HOME EXPENSES」：显式白字 + 橙底 → 以文件为准', () {
      final s = resolved(23, 0);
      expect(s.fill, const Color(0xFFFAA732));
      expect(s.font, const Color(0xFFFFFFFF));
    });

    test('A13「Wages」：无填充无字色 → 白纸上黑字', () {
      final s = resolved(12, 0);
      expect(s.fill, isNull);
      expect(s.font, isNull);
      expect(officeSheetAutomaticTextColor(s.fill), const Color(0xFF000000));
    });

    test('无边框的格子**不会**被编出一条边框（保持 null）', () {
      // A13 真实 styles.xml 里 borderId=0（无边框）→ 不应被"自动边框色"污染。
      final sheet = workbook.sheets.first;
      final style = officeSheetResolveStyle(
        pool: workbook.styles,
        styleId: sheet.cellAt(12, 0)!.styleIndex,
      );
      expect(style.hasBorder, isFalse);
    });
  });

  group('C7. 网格线 / 主题缺失的稳健性', () {
    test('真实年度表没有 colorId/color → raw 不带 gridLineColor（走文档兜底色）', () {
      final sheet = parseOfficeSheetXlsx(
        _fixture('annual_income_and_expenditure.xlsx'),
      ).sheets.first;
      expect(sheet.raw['gridLineColor'], isNull);
      expect(sheet.raw['showGridLines'], isNull, reason: '默认显示 → 不写键');
    });

    test('没有 theme1.xml 的 XLSX 也能解析（退默认主题，不抛）', () {
      final bytes = _buildMinimalXlsx(
        withTheme: false,
      ).map((e) => e.toInt()).toList();
      final wb = parseOfficeSheetXlsx(Uint8List.fromList(bytes));
      expect(wb.sheets, hasLength(1));
    });

    test('有 theme1.xml 时 theme 引用色解得出（不丢色）', () {
      final bytes = Uint8List.fromList(
        _buildMinimalXlsx(
          withTheme: true,
          themeRefFill: true,
        ).map((e) => e.toInt()).toList(),
      );
      final wb = parseOfficeSheetXlsx(bytes);
      final style = officeSheetResolveStyle(
        pool: wb.styles,
        styleId: wb.sheets.first.cellAt(0, 0)!.styleIndex,
      );
      // fills[1] = solid fgColor theme="4" → 默认主题 accent1 = 4F81BD
      expect(style.fillColor, const Color(0xFF4F81BD));
    });

    test('showGridLines="0" 被记录（渲染层据此不画线）', () {
      final bytes = Uint8List.fromList(
        _buildMinimalXlsx(showGridLines: false).map((e) => e.toInt()).toList(),
      );
      final sheet = parseOfficeSheetXlsx(bytes).sheets.first;
      expect(sheet.raw['showGridLines'], isFalse);
    });

    test('colorId 被解成 indexed 色并记录', () {
      final bytes = Uint8List.fromList(
        _buildMinimalXlsx(gridColorId: 2).map((e) => e.toInt()).toList(),
      );
      final sheet = parseOfficeSheetXlsx(bytes).sheets.first;
      expect(sheet.raw['gridLineColor'], 'FFFF0000');
    });
  });
}

/// 造一份最小 XLSX，只为验证**解析分支**（真实样本已在 C6 断言；这里不替代它）。
List<int> _buildMinimalXlsx({
  bool withTheme = false,
  bool themeRefFill = false,
  bool showGridLines = true,
  int? gridColorId,
}) {
  const workbook =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
      ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets><sheet name="S" sheetId="1" state="visible" r:id="rId1"/></sheets>'
      '</workbook>';
  const rels =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"'
      ' Target="worksheets/sheet1.xml"/></Relationships>';

  final fill = themeRefFill
      ? '<fill><patternFill patternType="solid"><fgColor theme="4"/>'
            '</patternFill></fill>'
      : '<fill><patternFill patternType="solid"><fgColor rgb="FF00FF00"/>'
            '</patternFill></fill>';
  final styles =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="1"><font><sz val="11"/></font></fonts>'
      '<fills count="2"><fill><patternFill/></fill>$fill</fills>'
      '<borders count="1"><border/></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>'
      '</cellStyleXfs>'
      '<cellXfs count="2">'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>'
      '<xf numFmtId="0" fontId="0" fillId="1" borderId="0"/>'
      '</cellXfs></styleSheet>';

  final viewAttrs = StringBuffer('workbookViewId="0"');
  if (!showGridLines) viewAttrs.write(' showGridLines="0"');
  if (gridColorId != null) viewAttrs.write(' colorId="$gridColorId"');
  final sheet =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<dimension ref="A1:A1"/>'
      '<sheetViews><sheetView $viewAttrs/></sheetViews>'
      '<sheetData><row r="1"><c r="A1" s="1"><v>7</v></c></row></sheetData>'
      '</worksheet>';

  const theme =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
      ' name="Office Theme"><a:themeElements>'
      '<a:clrScheme name="Office">'
      '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>'
      '<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>'
      '<a:dk2><a:srgbClr val="1F497D"/></a:dk2>'
      '<a:lt2><a:srgbClr val="EEECE1"/></a:lt2>'
      '<a:accent1><a:srgbClr val="4F81BD"/></a:accent1>'
      '<a:accent2><a:srgbClr val="C0504D"/></a:accent2>'
      '<a:accent3><a:srgbClr val="9BBB59"/></a:accent3>'
      '<a:accent4><a:srgbClr val="8064A2"/></a:accent4>'
      '<a:accent5><a:srgbClr val="4BACC6"/></a:accent5>'
      '<a:accent6><a:srgbClr val="F79646"/></a:accent6>'
      '<a:hlink><a:srgbClr val="0000FF"/></a:hlink>'
      '<a:folHlink><a:srgbClr val="800080"/></a:folHlink>'
      '</a:clrScheme></a:themeElements></a:theme>';

  final archive = Archive()
    ..addFile(ArchiveFile.string('xl/workbook.xml', workbook))
    ..addFile(ArchiveFile.string('xl/_rels/workbook.xml.rels', rels))
    ..addFile(ArchiveFile.string('xl/styles.xml', styles))
    ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheet));
  if (withTheme) {
    archive.addFile(ArchiveFile.string('xl/theme/theme1.xml', theme));
  }
  return ZipEncoder().encode(archive);
}
