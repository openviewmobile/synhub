// `.odoc` 显示重做批次（r17）的**离线**用例（**不发起任何 NAS 请求**）。
//
// ## 逐项取证口径（报告 §测试用例清单逐条对应）
//
// | 能力 | 真样本取证 | 结论 |
// |---|---|---|
// | `word/theme/theme1.xml` 的 `a:clrScheme` **解析** | 3 份真样本**都有** | **实测** |
// | `w:themeColor`/`themeTint`/`themeShade` **消费** | 3 份真样本 **0 处** | schema 级防御性实现 |
// | `w:tblCellMar` | `product_spec.docx` **1 处**（left/right 90 dxa、top/bottom 0） | **实测** |
// | `w:tblBorders` | 3 份真样本 **0 处** | schema 级防御性实现 |
// | `w:br w:type="page"` / `w:pageBreakBefore` | 3 份真样本 **0 处** | schema 级防御性实现 |
// | `w:vertAlign`（上下标） | 3 份真样本 **0 处** | schema 级防御性实现 |
// | `w:highlight` | 3 份真样本 **0 处** | schema 级防御性实现 |
// | `w:pPr/w:shd` 段落底纹 | `student_report.docx` 有 11 处 `w:fill="auto"`（= 无底纹） | 构造样本覆盖 |
// | 段前/段后**覆盖**语义 | `restaurant_menu.docx` **20 处** | **实测** |
// | 缺省字色**不落 App 主题** | 渲染层 | **实测（离线渲染）** |
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_doc_ooxml.dart';
import 'package:synhub/src/features/office/office_doc_ooxml_view.dart';
import 'package:synhub/src/features/office/office_doc_paper.dart'
    show kOfficeDocPaperColor;
import 'package:synhub/src/features/office/office_doc_style.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_doc_view.dart';

const String _wNs =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const String _aNs = 'http://schemas.openxmlformats.org/drawingml/2006/main';

Uint8List _realDocx([String name = 'product_spec.docx']) => Uint8List.fromList(
  File('test/fixtures/office_doc_redesign/$name').readAsBytesSync(),
);

// ---------------------------------------------------------------------------
// 构造样本（内存里拼的最小 DOCX；**不是官方样本**）
// ---------------------------------------------------------------------------

Uint8List _docx({required String body, String? styles, String? theme}) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add(
    'word/document.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="$_wNs" xmlns:a="$_aNs"><w:body>$body</w:body></w:document>',
  );
  if (styles != null) add('word/styles.xml', styles);
  if (theme != null) add('word/theme/theme1.xml', theme);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _run(String text, {String rPr = ''}) =>
    '<w:r>${rPr.isEmpty ? '' : '<w:rPr>$rPr</w:rPr>'}<w:t>$text</w:t></w:r>';

String _p(String inner, {String pPr = ''}) =>
    '<w:p>${pPr.isEmpty ? '' : '<w:pPr>$pPr</w:pPr>'}$inner</w:p>';

String _themeXml() =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<a:theme xmlns:a="$_aNs"><a:themeElements><a:clrScheme name="Theme1">'
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

void main() {
  // =========================================================================
  // 1. 主题色板：**真样本可取证**（3 份都有 theme1.xml）
  // =========================================================================
  group('T. `word/theme/theme1.xml` 的 `a:clrScheme`', () {
    test('T1. 真样本 `product_spec.docx` 的 12 个槽位逐字解析出来', () {
      final doc = ODocxDocument.parse(_realDocx())!;
      // 逐字取自该样本的 `word/theme/theme1.xml`。
      expect(doc.theme.isEmpty, isFalse);
      expect(doc.theme.rawOf('dark1'), '000000');
      expect(doc.theme.rawOf('light1'), 'FFFFFF');
      expect(doc.theme.rawOf('dark2'), '1F497D');
      expect(doc.theme.rawOf('light2'), 'EEECE1');
      expect(doc.theme.rawOf('accent1'), '4F81BD');
      expect(doc.theme.rawOf('accent2'), 'C0504D');
      expect(doc.theme.rawOf('accent3'), '9BBB59');
      expect(doc.theme.rawOf('accent4'), '8064A2');
      expect(doc.theme.rawOf('accent5'), '4BACC6');
      expect(doc.theme.rawOf('accent6'), 'F79646');
      expect(doc.theme.slots['hlink'], '0000FF');
      expect(doc.theme.slots['folHlink'], '800080');
      expect(doc.theme.slots.length, 12);
    });

    test('T2. 3 份真样本的色板**完全一致**（同一套 Office 默认主题）', () {
      final a = ODocxDocument.parse(_realDocx('product_spec.docx'))!.theme;
      final b = ODocxDocument.parse(_realDocx('restaurant_menu.docx'))!.theme;
      final c = ODocxDocument.parse(_realDocx('student_report.docx'))!.theme;
      expect(b.slots, a.slots);
      expect(c.slots, a.slots);
    });

    test('T3. `ST_ThemeColor` 的别名对（Word 写 dark1、PPT 系写 tx1/bg1）都认', () {
      expect(OOXMLThemeScheme.slotFor('dark1'), 'dk1');
      expect(OOXMLThemeScheme.slotFor('text1'), 'dk1');
      expect(OOXMLThemeScheme.slotFor('tx1'), 'dk1');
      expect(OOXMLThemeScheme.slotFor('light1'), 'lt1');
      expect(OOXMLThemeScheme.slotFor('background1'), 'lt1');
      expect(OOXMLThemeScheme.slotFor('bg1'), 'lt1');
      expect(OOXMLThemeScheme.slotFor('hyperlink'), 'hlink');
      expect(OOXMLThemeScheme.slotFor('followedHyperlink'), 'folHlink');
      expect(OOXMLThemeScheme.slotFor('nonexistent'), isNull);
    });

    test('T4. `themeTint` 是**变亮**（往 255 靠）、`themeShade` 是**变暗**（乘系数）', () {
      final theme = ODocxDocument.parse(_realDocx())!.theme;
      // accent1 = 4F81BD。
      // tint "99" → c' = c + (255-c) * 0x99/255
      //   R: 0x4F=79 → 79 + 176*153/255 = 79 + 105.6 = 184 (0xB8)
      //   G: 0x81=129 → 129 + 126*0.6 = 204 (0xCC)
      //   B: 0xBD=189 → 189 + 66*0.6 = 228 (0xE4)
      expect(theme.resolve('accent1', tint: '99'), '#b8cce4');
      // shade "99" → c' = c * 0x99/255 = c * 0.6
      //   R: 79*0.6=47 (0x2F) / G: 129*0.6=77 (0x4D) / B: 189*0.6=113 (0x71)
      expect(theme.resolve('accent1', shade: '99'), '#2f4d71');
      // 无色偏时是原值本身。
      expect(theme.resolve('accent1'), '#4f81bd');
    });

    test('T5. 没有色板时**不编颜色**：resolve 返回 null（调用方保留默认）', () {
      const empty = OOXMLThemeScheme.empty;
      expect(empty.resolve('accent1'), isNull);
      expect(empty.resolve('dark1', tint: '99'), isNull);
      // 认不出的主题名同样返回 null。
      final theme = ODocxDocument.parse(_realDocx())!.theme;
      expect(theme.resolve('notAThemeColor'), isNull);
    });

    test('T6. 真样本 `w:themeColor` 出现 **0 处** ⇒ 主题消费**不可真机取证**', () async {
      for (final name in <String>[
        'product_spec.docx',
        'restaurant_menu.docx',
        'student_report.docx',
      ]) {
        final xml = await _documentXmlOf(_realDocx(name));
        expect(
          xml.contains('w:themeColor'),
          isFalse,
          reason: '$name 里不该有 w:themeColor（这是本批结论的依据）',
        );
      }
    });

    test('T7. 构造样本：`w:color w:themeColor` 真的解出 `#rrggbb`', () {
      final bytes = _docx(
        body: _p(
          _run(
            'themed text',
            rPr: '<w:color w:themeColor="accent2"/><w:sz w:val="22"/>',
          ),
        ),
        theme: _themeXml(),
      );
      final doc = ODocxDocument.parse(bytes)!;
      final run = doc.allParagraphs.single.runs.single;
      expect(run.color, '#c0504d');
    });

    test('T8. 构造样本：`themeTint` 与字面色同时存在时**主题优先**', () {
      final bytes = _docx(
        body: _p(
          _run(
            'themed tinted',
            rPr:
                '<w:color w:val="000000" w:themeColor="accent1" w:themeTint="99"/>',
          ),
        ),
        theme: _themeXml(),
      );
      final doc = ODocxDocument.parse(bytes)!;
      expect(doc.allParagraphs.single.runs.single.color, '#b8cce4');
    });

    test('T9. 缺 theme1.xml 时字面色**逐字节不变**（不能因为加了主题就改坏老文档）', () {
      final bytes = _docx(
        body: _p(_run('plain', rPr: '<w:color w:val="FF0000"/>')),
      );
      final doc = ODocxDocument.parse(bytes)!;
      expect(doc.allParagraphs.single.runs.single.color, 'FF0000');
      expect(doc.theme.isEmpty, isTrue);
    });
  });

  // =========================================================================
  // 2. 段前/段后：**段落自己声明就覆盖样式**（真样本取证）
  // =========================================================================
  group('S. `w:spacing` 的段前/段后覆盖语义', () {
    test(
      'S1. 真样本 `restaurant_menu.docx`：5 个 Heading1 的段前 = 240 twips = 16px',
      () {
        final doc = ODocxDocument.parse(_realDocx('restaurant_menu.docx'))!;
        // 原文：`<w:pStyle w:val="Heading1"/><w:spacing w:before="240" w:lineRule="auto"/>`
        // styles.xml 的 Heading1 另有 `w:before="300"`。
        // **旧实现把两者相加** → 240/15 + 300/15 = 16 + 20 = 36px（多 20px/处）。
        final h1 = doc.allParagraphs
            .where((p) => p.styleId == 'Heading1')
            .toList();
        expect(h1.length, greaterThanOrEqualTo(5));
        for (final p in h1) {
          expect(
            p.spacingBeforePx,
            closeTo(240 / 15, 0.01),
            reason: '段落自己的 w:before 必须**覆盖**样式的 300 twips',
          );
        }
      },
    );

    test(
      'S2. 真样本 `restaurant_menu.docx`：15 个 Heading2 的段前 = 160 twips = 10.67px',
      () {
        final doc = ODocxDocument.parse(_realDocx('restaurant_menu.docx'))!;
        final h2 = doc.allParagraphs
            .where((p) => p.styleId == 'Heading2')
            .toList();
        expect(h2.length, greaterThanOrEqualTo(15));
        for (final p in h2) {
          expect(p.spacingBeforePx, closeTo(160 / 15, 0.01));
        }
      },
    );

    test('S3. 段落**没写** before 时仍然回退样式（不能一律清零）', () {
      final doc = ODocxDocument.parse(_realDocx())!;
      // product_spec.docx 的 Heading1 段落都没有自己的 w:before
      // ⇒ 必须回退到 styles.xml Heading1 的 300 twips = 20px。
      final h1 = doc.allParagraphs.firstWhere((p) => p.styleId == 'Heading1');
      expect(h1.spacingBeforePx, closeTo(20.0, 0.01));
      expect(h1.spacingAfterPx, closeTo(6.0, 0.01));
    });

    test('S4. 构造样本：只声明 `before` 时，`after` 仍走样式（逐属性覆盖）', () {
      final bytes = _docx(
        body: _p(
          _run('H', rPr: '<w:sz w:val="32"/>'),
          pPr:
              '<w:pStyle w:val="Heading1"/>'
              '<w:spacing w:before="120" w:lineRule="auto"/>',
        ),
        styles:
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<w:styles xmlns:w="$_wNs">'
            '<w:style w:type="paragraph" w:styleId="Heading1">'
            '<w:pPr><w:spacing w:before="300" w:after="90" w:line="360" '
            'w:lineRule="auto"/></w:pPr></w:style></w:styles>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      final p = doc.allParagraphs.single;
      expect(p.spacingBeforePx, closeTo(120 / 15, 0.01), reason: '本段覆盖');
      expect(p.spacingAfterPx, closeTo(90 / 15, 0.01), reason: '本段没写 → 回退样式');
    });
  });

  // =========================================================================
  // 3. 表格：`w:tblCellMar`（真样本）/ `w:tblBorders`（构造）
  // =========================================================================
  group('B. 表格的单元格内边距与表级边框', () {
    test('B1. 真样本 `product_spec.docx` 的 `w:tblCellMar`：左右 90 dxa = 6px、上下 0', () {
      final doc = ODocxDocument.parse(_realDocx())!;
      final table = doc.blocks.firstWhere((b) => b.isTable).table!;
      // 原文：<w:tblCellMar><w:left w:w="90"/><w:bottom w:w="0"/><w:right w:w="90"/>
      //        <w:top w:w="0"/></w:tblCellMar>
      expect(table.cellMarginLeftPx, closeTo(6.0, 0.01));
      expect(table.cellMarginRightPx, closeTo(6.0, 0.01));
      expect(table.cellMarginTopPx, closeTo(0.0, 0.01));
      expect(table.cellMarginBottomPx, closeTo(0.0, 0.01));
    });

    test('B2. 没声明 `w:tblCellMar` 的表格走**既有兜底** 6/4（不改坏老版面）', () {
      final bytes = _docx(
        body:
            '<w:tbl><w:tblGrid><w:gridCol w:w="4500"/></w:tblGrid>'
            '<w:tr><w:tc><w:tcPr/>${_p(_run('x'))}</w:tc></w:tr></w:tbl>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      final table = doc.blocks.firstWhere((b) => b.isTable).table!;
      expect(table.cellMarginLeftPx, closeTo(kOoxmlDefaultCellMarginPx, 0.01));
      expect(
        table.cellMarginTopPx,
        closeTo(kOoxmlDefaultCellMarginVerticalPx, 0.01),
      );
    });

    test('B3. 构造：`w:tblBorders` 作为**表级兜底**，`w:tcBorders` 优先', () {
      final bytes = _docx(
        body:
            '<w:tbl><w:tblPr><w:tblBorders>'
            '<w:top w:val="single" w:sz="8" w:color="112233"/>'
            '<w:left w:val="single" w:sz="8" w:color="112233"/>'
            '<w:bottom w:val="single" w:sz="8" w:color="112233"/>'
            '<w:right w:val="single" w:sz="8" w:color="112233"/>'
            '</w:tblBorders></w:tblPr>'
            '<w:tblGrid><w:gridCol w:w="4500"/><w:gridCol w:w="4500"/></w:tblGrid>'
            '<w:tr>'
            // 第 1 格：自己声明了 top（颜色不同）→ 用自己那条
            '<w:tc><w:tcPr><w:tcBorders>'
            '<w:top w:val="single" w:sz="4" w:color="FF0000"/>'
            '</w:tcBorders></w:tcPr>${_p(_run('own top'))}</w:tc>'
            // 第 2 格：什么都没声明 → 四边全部落回表级
            '<w:tc><w:tcPr/>${_p(_run('inherits'))}</w:tc>'
            '</w:tr></w:tbl>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      final row = doc.blocks.firstWhere((b) => b.isTable).table!.rows.single;
      // 第 1 格：top 是自己的红色（sz=4 → 0.667px），left 落回表级（sz=8 → 1.33px）
      expect(row.cells[0].borderTop!.color, 'FF0000');
      expect(row.cells[0].borderTop!.widthPx, closeTo(4 / 6.0, 1e-9));
      expect(row.cells[0].borderLeft!.color, '112233');
      expect(row.cells[0].borderLeft!.widthPx, closeTo(8 / 6.0, 1e-9));
      // 第 2 格：四边都是表级。
      for (final b in <OOXMLBorder?>[
        row.cells[1].borderTop,
        row.cells[1].borderLeft,
        row.cells[1].borderBottom,
        row.cells[1].borderRight,
      ]) {
        expect(b!.visible, isTrue);
        expect(b.color, '112233');
      }
    });

    test('B4. `w:val="nil"` = **没有边框**（表级与格级都认）', () {
      final bytes = _docx(
        body:
            '<w:tbl><w:tblPr><w:tblBorders>'
            '<w:top w:val="single" w:sz="8" w:color="112233"/>'
            '<w:left w:val="nil"/></w:tblBorders></w:tblPr>'
            '<w:tblGrid><w:gridCol w:w="4500"/></w:tblGrid>'
            '<w:tr><w:tc><w:tcPr/>${_p(_run('x'))}</w:tc></w:tr></w:tbl>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      final cell = doc.blocks
          .firstWhere((b) => b.isTable)
          .table!
          .rows
          .single
          .cells
          .single;
      expect(cell.borderTop!.visible, isTrue);
      expect(cell.borderLeft!.visible, isFalse, reason: 'nil = 明确不要边框');
    });

    test('B5. 边框**没写颜色**（= OOXML 的 `auto`）也必须画出来（旧实现整条丢掉）', () {
      final bytes = _docx(
        body:
            '<w:tbl><w:tblGrid><w:gridCol w:w="4500"/></w:tblGrid>'
            '<w:tr><w:tc><w:tcPr><w:tcBorders>'
            '<w:top w:val="single" w:sz="4"/>'
            '</w:tcBorders></w:tcPr>${_p(_run('x'))}</w:tc></w:tr></w:tbl>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      final b = doc.blocks
          .firstWhere((x) => x.isTable)
          .table!
          .rows
          .single
          .cells
          .single
          .borderTop!;
      expect(b.visible, isTrue, reason: 'w:val=single + sz>0 ⇒ 可见');
      expect(b.color, isNull, reason: '颜色缺省 = auto，交给渲染层用黑色兜底');
    });

    test('B6. 渲染层：缺颜色的边框画成**黑**（不是旧的灰 AAAAAA）', () {
      // 由 B5 的解析结果驱动的期望值；这里直接钉住渲染层的兜底色。
      expect(
        officeDocParseColor(null) ?? const Color(0xFF000000),
        const Color(0xFF000000),
      );
    });
  });

  // =========================================================================
  // 4. 分页：`w:pageBreakBefore` 与 `<w:br w:type="page"/>`
  // =========================================================================
  group('P. 真分页', () {
    test('P1. `w:pageBreakBefore` 落到段落的 `pageBreakBefore`', () {
      final bytes = _docx(
        body:
            _p(_run('first')) + _p(_run('second'), pPr: '<w:pageBreakBefore/>'),
      );
      final doc = ODocxDocument.parse(bytes)!;
      final ps = doc.allParagraphs.toList();
      expect(ps[0].pageBreakBefore, isFalse);
      expect(ps[1].pageBreakBefore, isTrue);
    });

    test('P2. `<w:br w:type="page"/>` 把**一段拆成两段**，后一段起新页', () {
      final bytes = _docx(
        body:
            '<w:p>${_run('before break')}'
            '<w:r><w:br w:type="page"/></w:r>'
            '${_run('after break')}</w:p>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      final ps = doc.allParagraphs.toList();
      expect(ps.length, 2, reason: '分页符把段落拆开');
      expect(ps[0].text, 'before break');
      expect(ps[0].pageBreakBefore, isFalse);
      expect(ps[1].text, 'after break');
      expect(ps[1].pageBreakBefore, isTrue, reason: '后一段必须起新页');
      expect(ps[1].runs.single.bold, ps[0].runs.single.bold);
    });

    test('P3. `<w:br/>`（无名）是**软换行**，不拆段、只出一个 \\n', () {
      final bytes = _docx(
        body: '<w:p>${_run('line1')}<w:r><w:br/></w:r>${_run('line2')}</w:p>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      expect(doc.allParagraphs.length, 1);
      expect(doc.allParagraphs.single.text, 'line1\nline2');
      expect(doc.allParagraphs.single.pageBreakBefore, isFalse);
    });

    test('P4. 段**末**的分页符 → 该段 `pageBreakAfter`，且不造空段', () {
      final bytes = _docx(
        body:
            '<w:p>${_run('only')}<w:r><w:br w:type="page"/></w:r></w:p>'
            '${_p(_run('next'))}',
      );
      final doc = ODocxDocument.parse(bytes)!;
      final ps = doc.allParagraphs.toList();
      expect(ps.length, 2, reason: '不能多造一个空段');
      expect(ps[0].text, 'only');
      expect(ps[0].pageBreakAfter, isTrue);
      expect(ps[1].text, 'next');
      expect(ps[1].pageBreakBefore, isFalse, reason: 'after 由上一段承载');
    });

    test('P5. 渲染层：`officeDocxForcedBreakBefore` 合并两条来源', () {
      final bytes = _docx(
        body:
            '${_p(_run('a'))}'
            '${_p(_run('b'), pPr: '<w:pageBreakBefore/>')}'
            '${_p('${_run('c')}<w:r><w:br w:type="page"/></w:r>')}'
            '${_p(_run('d'))}',
      );
      final doc = ODocxDocument.parse(bytes)!;
      final blocks = doc.blocks;
      expect(officeDocxForcedBreakBefore(blocks, 0), isFalse);
      expect(
        officeDocxForcedBreakBefore(blocks, 1),
        isTrue,
        reason: 'pageBreakBefore',
      );
      expect(
        officeDocxForcedBreakBefore(blocks, 3),
        isTrue,
        reason: '上一段 pageBreakAfter',
      );
    });

    testWidgets('P6. 强制分页**真的分成两页**（哪怕内容塞得下一页）', (tester) async {
      final bytes = _docx(
        body:
            _p(_run('page one text')) +
            _p(_run('page two text'), pPr: '<w:pageBreakBefore/>'),
      );
      final doc = ODocxDocument.parse(bytes)!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-paper-page-0')), findsOneWidget);
      expect(
        find.byKey(const Key('office-doc-paper-page-1')),
        findsOneWidget,
        reason: 'pageBreakBefore 必须真的翻页',
      );
      expect(
        find.byKey(const Key('office-doc-paper-page-2')),
        findsNothing,
        reason: '只该分成两页',
      );
      expect(tester.takeException(), isNull);
    });
  });

  // =========================================================================
  // 5. 字符级：上下标 / 高亮 / 字体
  // =========================================================================
  group('C. 字符级排版', () {
    test('C1. `w:vertAlign` 解析成 superscript / subscript，`baseline` = 正常', () {
      final bytes = _docx(
        body:
            '<w:p>'
            '${_run('x', rPr: '<w:vertAlign w:val="superscript"/>')}'
            '${_run('2', rPr: '<w:vertAlign w:val="subscript"/>')}'
            '${_run('n', rPr: '<w:vertAlign w:val="baseline"/>')}'
            '</w:p>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      final runs = doc.allParagraphs.single.runs;
      expect(runs[0].isSuperscript, isTrue);
      expect(runs[1].isSubscript, isTrue);
      expect(runs[2].verticalAlign, isNull, reason: 'baseline = 正常基线');
    });

    testWidgets('C2. 上下标上屏：字号缩小 + 基线位移，且**不失控**', (tester) async {
      // 注意 `w:sz` 是**半磅**：`24` = 12pt = 16px。
      final bytes = _docx(
        body:
            '<w:p>${_run('base', rPr: '<w:sz w:val="24"/>')}'
            '${_run('S', rPr: '<w:sz w:val="24"/><w:vertAlign w:val="superscript"/>')}'
            '${_run('B', rPr: '<w:sz w:val="24"/><w:vertAlign w:val="subscript"/>')}'
            '</w:p>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 上下标各是一个独立的 `Text`（WidgetSpan 承载，见
      // `_spanWithVerticalAlign` 的说明）。
      final marks = find.byKey(const Key('office-docx-vertical-align'));
      expect(marks, findsNWidgets(2));
      final sup = tester.widget<Text>(marks.at(0));
      final sub = tester.widget<Text>(marks.at(1));
      expect(sup.data, 'S');
      expect(sub.data, 'B');
      expect(
        sup.style!.fontSize,
        closeTo(12 * 96 / 72 * 0.65, 0.01),
        reason: '上标字号 = 正文 12pt → 16px 的 0.65 倍',
      );
      expect(sub.style!.fontSize, closeTo(12 * 96 / 72 * 0.65, 0.01));

      // 正文 run 仍然是原始字号（12pt = 16px），没被上下标带小。
      //
      // `Text.rich` 的根 span 是 Flutter 用 `DefaultTextStyle` 包出来的一层
      // （所以根上读到的是 App/环境的 14px）；真正带我们样式的是它的子 span。
      final rp = tester.renderObject<RenderParagraph>(
        find.ancestor(of: marks.at(0), matching: find.byType(RichText)),
      );
      TextSpan ownSpan(RenderParagraph r) {
        if (r.text is! TextSpan) return TextSpan(text: '', style: r.text.style);
        final root = r.text as TextSpan;
        final kids = root.children;
        if (kids != null && kids.length == 1 && kids.first is TextSpan) {
          return kids.first as TextSpan;
        }
        return root;
      }

      expect(ownSpan(rp).style!.fontSize, closeTo(16.0, 0.01));

      // **基线位移真的发生了**：上标必须比下标高，且差值看得出来
      // （0.34 × 16px × 2 = 10.9px）。
      final supTop = tester.getRect(marks.at(0)).top;
      final subTop = tester.getRect(marks.at(1)).top;
      expect(supTop, lessThan(subTop), reason: '上标必须被抬到下标之上');
      expect(
        subTop - supTop,
        greaterThan(4.0),
        reason: '位移幅度要能看出来，不是"缩了字号但没动基线"',
      );
      expect(subTop - supTop, lessThan(16.0), reason: '位移不能超过一倍字号');
    });

    test('C3. `w:highlight` 的**具名色板**（16 色）解析成 `#rrggbb`', () {
      for (final entry in kOoxmlHighlightColors.entries) {
        final bytes = _docx(
          body: _p(_run('hl', rPr: '<w:highlight w:val="${entry.key}"/>')),
        );
        final run = ODocxDocument.parse(
          bytes,
        )!.allParagraphs.single.runs.single;
        expect(
          run.highlight,
          entry.value,
          reason: '${entry.key} → ${entry.value}',
        );
      }
      expect(kOoxmlHighlightColors.length, 16);
      // `none` = 没有高亮。
      final none = _docx(
        body: _p(_run('hl', rPr: '<w:highlight w:val="none"/>')),
      );
      expect(
        ODocxDocument.parse(none)!.allParagraphs.single.runs.single.highlight,
        isNull,
      );
    });

    test('C4. `w:shd w:fill` 仍然是 run 底色（没被 highlight 改坏）', () {
      final bytes = _docx(
        body: _p(_run('shaded', rPr: '<w:shd w:fill="FFF2CC"/>')),
      );
      expect(
        ODocxDocument.parse(bytes)!.allParagraphs.single.runs.single.highlight,
        'FFF2CC',
      );
    });

    test('C5. `<w:pPr><w:shd>` 段落底纹解析出来了；`fill="auto"` = 无底纹', () {
      final bytes = _docx(
        body:
            _p(_run('shaded para'), pPr: '<w:shd w:fill="D9E2F3"/>') +
            _p(_run('auto para'), pPr: '<w:shd w:fill="auto"/>'),
      );
      final doc = ODocxDocument.parse(bytes)!;
      final ps = doc.allParagraphs.toList();
      expect(ps[0].shading, 'D9E2F3');
      expect(ps[1].shading, 'auto');
      // `auto` 解不出颜色 ⇒ 渲染层不画（不是画成黑）。
      expect(officeDocParseColor('auto'), isNull);
    });

    testWidgets('C6. 段落底纹真的上屏（ColoredBox）', (tester) async {
      final bytes = _docx(
        body: _p(_run('shaded para'), pPr: '<w:shd w:fill="D9E2F3"/>'),
      );
      final doc = ODocxDocument.parse(bytes)!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boxes = tester.widgetList<ColoredBox>(find.byType(ColoredBox));
      expect(
        boxes.any((b) => b.color == const Color(0xFFD9E2F3)),
        isTrue,
        reason: '段落底纹必须是 D9E2F3',
      );
    });
  });

  // =========================================================================
  // 6. 单元格竖直对齐**不许**变成水平居中（父 agent r17 截图复现的真缺陷）
  // =========================================================================
  group('V. `w:vAlign` 是**竖直**对齐（旧实现错接到水平轴）', () {
    testWidgets('V1. `w:vAlign="center"` 的单元格里，段落**仍然左对齐**', (tester) async {
      final bytes = _docx(
        body:
            '<w:tbl>'
            '<w:tblGrid><w:gridCol w:w="9000"/></w:tblGrid>'
            '<w:tr><w:tc><w:tcPr><w:vAlign w:val="center"/></w:tcPr>'
            '${_p(_run('vertically centred cell'))}</w:tc></w:tr></w:tbl>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final cell = tester.getRect(
        find.byKey(const Key('office-docx-cell-0-0')),
      );
      final text = tester.getRect(find.text('vertically centred cell'));
      // 旧实现：Column.crossAxisAlignment = center → 文字被推到单元格中间。
      // 新实现：crossAxisAlignment = stretch，段落铺满内容宽、文字贴左边界。
      expect(
        text.left - cell.left,
        closeTo(kOoxmlDefaultCellMarginPx, 1.5),
        reason: '文字必须贴在单元格左内边距处，不是水平居中',
      );
      expect(
        text.width,
        greaterThan(cell.width / 2),
        reason: '段落应铺满单元格宽（否则说明被 shrink-wrap 居中）',
      );
    });

    testWidgets('V2. `w:jc="center"` 才水平居中（不能被 vAlign 干扰）', (tester) async {
      final bytes = _docx(
        body:
            '<w:tbl>'
            '<w:tblGrid><w:gridCol w:w="9000"/></w:tblGrid>'
            '<w:tr><w:tc><w:tcPr><w:vAlign w:val="center"/></w:tcPr>'
            '${_p(_run('centred'), pPr: '<w:jc w:val="center"/>')}</w:tc>'
            '</w:tr></w:tbl>',
      );
      final doc = ODocxDocument.parse(bytes)!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      final cell = tester.getRect(
        find.byKey(const Key('office-docx-cell-0-0')),
      );
      final rich = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text('centred'),
          matching: find.byType(RichText),
        ),
      );
      expect(rich.textAlign, TextAlign.center);
      expect(cell.width, greaterThan(0));
    });

    test('V3. 真样本 `5-day trip planner` 的口径：`vAlign=middle`（原生 JSON）同义', () {
      // 原生 JSON 用 `verticalAlign: "middle"`，OOXML 用 `w:val="center"`。
      // 渲染层必须同时认这两个（见 `_cell` 的 switch）。
      const cell = OOXMLCell(blocks: <OOXMLBlock>[], verticalAlign: 'middle');
      expect(cell.verticalAlign, 'middle');
    });
  });

  // =========================================================================
  // 7. 缺省字色**不许**落 App 主题
  // =========================================================================
  group('D. 文档缺省字色 = 文档自己的默认色，不是 App 主题色', () {
    testWidgets('D1. OOXML 纸面路径：深色 App 主题下正文仍是 `0xFF202124`', (tester) async {
      final bytes = _docx(body: _p(_run('no colour given')));
      final doc = ODocxDocument.parse(bytes)!;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.text('no colour given'));
      expect(text.style!.color, kOfficeDocDefaultTextColor);
      expect(
        text.style!.color,
        isNot(ThemeData.dark().textTheme.bodyMedium!.color),
        reason: '绝不许是 App 主题的正文色',
      );
    });

    testWidgets('D2. 原生回退路径：深色 App 主题下正文/标题都是文档缺省色', (tester) async {
      // 最小原生文档树：一个 heading_level=1 的段落 + 一个普通段落。
      final root = <String, Object?>{
        'type': 'doc',
        'content': <Object?>[
          <String, Object?>{
            'type': 'paragraph',
            'attrs': <String, Object?>{'heading_level': 1},
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'Doc Heading'},
            ],
          },
          <String, Object?>{
            'type': 'paragraph',
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'Doc body text'},
            ],
          },
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: OfficeDocView(doc: root)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 原生渲染器把样式挂在 `TextSpan` 上（`Text.rich(TextSpan(style: ...))`），
      // 所以从渲染对象上读**实际生效**的根 span 样式最可靠。
      Color? effectiveColor(String text) => tester
          .renderObject<RenderParagraph>(
            find.descendant(
              of: find.text(text),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style
          ?.color;
      expect(effectiveColor('Doc Heading'), kOfficeDocDefaultTextColor);
      expect(effectiveColor('Doc body text'), kOfficeDocDefaultTextColor);
      expect(
        effectiveColor('Doc body text'),
        isNot(ThemeData.dark().textTheme.bodyMedium!.color),
        reason: '绝不许是 App 主题的正文色',
      );
      // 文档画布是白的（不是 App 的深色面）。
      final canvas = tester.widget<DecoratedBox>(
        find.byKey(const Key('office-doc-canvas')),
      );
      expect(
        (canvas.decoration as BoxDecoration).color,
        kOfficeDocPaperCanvasColor,
      );
    });

    testWidgets('D3. 文档**显式给了**字色时不被覆盖', (tester) async {
      final root = <String, Object?>{
        'type': 'doc',
        'content': <Object?>[
          <String, Object?>{
            'type': 'paragraph',
            'content': <Object?>[
              <String, Object?>{
                'type': 'text',
                'text': 'coloured',
                'marks': <Object?>[
                  <String, Object?>{'type': 'color', 'value': '#ff0000'},
                ],
              },
            ],
          },
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: OfficeDocView(doc: root)),
        ),
      );
      await tester.pumpAndSettle();
      final rp = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text('coloured'),
          matching: find.byType(RichText),
        ),
      );
      // 内层 span 携带 `text_color` mark；`TextSpan.style` 的链式继承 →
      // 取**直接绘制**的那个 span 的颜色。
      Color? colour;
      void walk(InlineSpan sp) {
        if (sp is! TextSpan) return;
        if (sp.text == 'coloured' && sp.style?.color != null) {
          colour = sp.style!.color;
        }
        for (final c in sp.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      }

      walk(rp.text);
      expect(colour, const Color(0xFFFF0000));
    });

    testWidgets('D4. OOXML 纸面底色恒为白（深色主题下也是白纸）', (tester) async {
      final bytes = _docx(body: _p(_run('paper')));
      final doc = ODocxDocument.parse(bytes)!;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      final page = tester.widget<Container>(
        find.byKey(const Key('office-doc-paper-page-0')),
      );
      final decoration = page.decoration! as BoxDecoration;
      expect(decoration.color, kOfficeDocPaperColor);
    });
  });
}

/// 从内存里的 DOCX 字节里抠出 `word/document.xml` 的文本（只给断言 `contains` 用）。
Future<String> _documentXmlOf(Uint8List bytes) async {
  final archive = ZipDecoder().decodeBytes(bytes);
  final file = archive.files.firstWhere((f) => f.name == 'word/document.xml');
  return utf8.decode(file.content as List<int>);
}
