// `.odoc` 排版三项修复批次的**离线**用例（**不发起任何 NAS 请求**）。
//
// 覆盖三项：
//   1. **嵌套表格**（`w:tc` 里的 `w:tbl`）—— 递归渲染，宽度受父单元格约束；
//   2. **首行缩进 / 悬挂缩进**（`w:ind/@w:firstLine` 与 `@w:hanging`）；
//   3. **`w:spacing/@w:lineRule`** 的 `auto` / `exact` / `atLeast` 换算。
//
// ## 夹具来源（每处都标注，报告 §"夹具台账"逐条对应）
//
// * **官方真样本**：`test/fixtures/office_doc_redesign/product_spec.docx`
//   —— 真机 `Files:download` 拿回来的真字节（12,973 B，`PK\x03\x04`），
//   源 `Product spec.odoc`。本文件只从它断言**它确实有的**东西：
//     - `document.xml` 有 **2 处** `<w:ind w:left="450" w:firstLine="0"/>`
//       （注意 `firstLine` 的值是 **0** —— 官方 5 份样本里 `firstLine` 全为 0，
//        所以"有可见首行缩进"这件事**无法用真样本取证**）；
//     - `document.xml` 有 **4 处** `<w:spacing w:line="288" w:lineRule="auto"/>`
//       （288/240 = **1.2 倍**）—— `lineRule="auto"` 的真样本取证；
//     - `styles.xml` 的 `<w:spacing w:line="240" w:lineRule="auto"/>`（= 1.0）；
//     - 表格**嵌套深度 = 1**（`<w:tbl>` 只有 1 个）→ 真样本里**没有**嵌套表格。
//
// * **构造样本（不是官方样本）**：`_constructedDocx()` —— 用 `package:archive`
//   在内存里手工拼 XML 打成最小 DOCX（OOXML schema 允许的写法），
//   **不来自 NAS、不联网**。它提供真样本里不存在的形态：
//   `w:firstLine=420`（非 0）、`w:hanging`、`lineRule="exact"|"atLeast"`、
//   以及 `w:tc` 里的嵌套 `w:tbl`（含表头 `w:tblHeader` / 底色 `w:shd` /
//   边框 `w:tcBorders`）。**这些断言的是"按 schema 的防御性实现"，不是真机取证。**
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_doc_ooxml.dart';
import 'package:synhub/src/features/office/office_doc_ooxml_view.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_doc_style.dart'
    show officeDocParseColor;

// ---------------------------------------------------------------------------
// 官方真样本
// ---------------------------------------------------------------------------

Uint8List _realDocx([String name = 'product_spec.docx']) => Uint8List.fromList(
  File('test/fixtures/office_doc_redesign/$name').readAsBytesSync(),
);

// ---------------------------------------------------------------------------
// 构造样本（内存里拼的最小 DOCX；**不是官方样本**）
// ---------------------------------------------------------------------------

const String _wNs =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

/// 表格单元格边框：`w:sz` 是**八分之一磅**，`4` → 0.667px。
const String _cellBorders =
    '<w:tcBorders>'
    '<w:top w:val="single" w:sz="4" w:color="000000"/>'
    '<w:left w:val="single" w:sz="4" w:color="000000"/>'
    '<w:bottom w:val="single" w:sz="4" w:color="000000"/>'
    '<w:right w:val="single" w:sz="4" w:color="000000"/>'
    '</w:tcBorders>';

String _run(String text, {int halfPoints = 22}) =>
    '<w:r><w:rPr><w:sz w:val="$halfPoints"/></w:rPr><w:t>$text</w:t></w:r>';

/// 单元格里的段落：`w:tc` 里**必须**有 `w:p` 包着 `w:r`
/// （裸 `w:r` 不是合法的 `w:tc` 内容，解析层也只会认 `w:p`/`w:tbl`）。
String _cellP(String text, {int halfPoints = 22}) =>
    '<w:p>${_run(text, halfPoints: halfPoints)}</w:p>';

/// 构造样本的正文。
///
/// 覆盖真样本里**没有**的形态：
///   * `AUTO360`   —— `w:line="360" w:lineRule="auto"` → 1.5 倍（对照项）；
///   * `EXACT400`  —— `w:line="400" w:lineRule="exact"`（11pt 与 24pt 各一段，
///     证明**绝对行高不随字号变**：400 twips = 26.667px）；
///   * `ATLEAST200`—— 低于自然行高 → 取自然（1.0）；
///   * `ATLEAST600`—— 高于自然行高 → 取该值（600 twips = 40px → 2.727 倍）；
///   * `FIRSTLINE` —— `w:firstLine="420"`（= 28px，首行**多**缩进）；
///   * `HANGING`   —— `w:left="720" w:hanging="360"`（首行 24px，续行 48px）；
///   * 外层 `w:tbl` 的单元格里再放一个 `w:tbl`（内层带 `w:tblHeader` / `w:shd`）。
String _constructedDocumentXml() {
  final firstLineText = 'FIRSTLINE ${'wrap ' * 40}end';
  final hangingText = 'HANGING ${'wrap ' * 40}end';
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="$_wNs"><w:body>'
      // --- 行距 ---
      '<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/></w:pPr>'
      '${_run('AUTO360 body line spacing')}</w:p>'
      '<w:p><w:pPr><w:spacing w:line="400" w:lineRule="exact"/></w:pPr>'
      '${_run('EXACT400 eleven point')}</w:p>'
      '<w:p><w:pPr><w:spacing w:line="400" w:lineRule="exact"/></w:pPr>'
      '${_run('EXACT400 twentyfour point', halfPoints: 48)}</w:p>'
      '<w:p><w:pPr><w:spacing w:line="200" w:lineRule="atLeast"/></w:pPr>'
      '${_run('ATLEAST200 below natural')}</w:p>'
      '<w:p><w:pPr><w:spacing w:line="600" w:lineRule="atLeast"/></w:pPr>'
      '${_run('ATLEAST600 above natural')}</w:p>'
      // --- 首行缩进 ---
      '<w:p><w:pPr><w:ind w:firstLine="420"/></w:pPr>'
      '${_run(firstLineText)}</w:p>'
      // --- 悬挂缩进（非列表段落）+ 右缩进（验证右缩进不会被扣两次）---
      '<w:p><w:pPr><w:ind w:left="720" w:hanging="360" w:right="360"/></w:pPr>'
      '${_run(hangingText)}</w:p>'
      // --- 嵌套表格 ---
      '<w:tbl>'
      '<w:tblPr><w:tblW w:w="9000" w:type="dxa"/></w:tblPr>'
      '<w:tblGrid><w:gridCol w:w="4500"/><w:gridCol w:w="4500"/></w:tblGrid>'
      '<w:tr><w:trPr><w:tblHeader/></w:trPr>'
      '<w:tc><w:tcPr>$_cellBorders<w:vAlign w:val="center"/></w:tcPr>'
      '${_cellP('Outer Header A')}</w:tc>'
      '<w:tc><w:tcPr>$_cellBorders</w:tcPr>'
      '${_cellP('Outer Header B')}</w:tc></w:tr>'
      '<w:tr>'
      '<w:tc><w:tcPr><w:shd w:fill="DDEEFF"/>$_cellBorders</w:tcPr>'
      '${_cellP('Cell with nested table')}'
      // 内层表格：声明总宽 6000 twips = 400px > 父单元格内容宽 → 必须被等比压缩。
      '<w:tbl>'
      '<w:tblPr><w:tblW w:w="6000" w:type="dxa"/></w:tblPr>'
      '<w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>'
      '<w:tr><w:trPr><w:tblHeader/></w:trPr>'
      '<w:tc><w:tcPr>$_cellBorders</w:tcPr>'
      '${_cellP('Inner Header 1')}</w:tc>'
      '<w:tc><w:tcPr>$_cellBorders</w:tcPr>'
      '${_cellP('Inner Header 2')}</w:tc></w:tr>'
      '<w:tr>'
      '<w:tc><w:tcPr><w:shd w:fill="FFEEDD"/>$_cellBorders</w:tcPr>'
      '${_cellP('Inner Cell 1')}</w:tc>'
      '<w:tc><w:tcPr><w:shd w:fill="FFEEDD"/>$_cellBorders</w:tcPr>'
      '${_cellP('Inner Cell 2')}</w:tc></w:tr>'
      '</w:tbl>'
      '</w:tc>'
      '<w:tc><w:tcPr>$_cellBorders</w:tcPr>${_cellP('Sibling cell')}</w:tc>'
      '</w:tr>'
      '</w:tbl>'
      '</w:body></w:document>';
}

const String _constructedStylesXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:styles xmlns:w="$_wNs"><w:docDefaults>'
    '<w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial"/>'
    '<w:sz w:val="22"/></w:rPr></w:rPrDefault>'
    // ⚠️ 故意**不写** `w:spacing/@w:line` → 样式的 auto 倍数为 null，
    // 这样 `atLeast` 才能验证"取自然行高"的分支。
    '<w:pPrDefault><w:pPr/></w:pPrDefault>'
    '</w:docDefaults></w:styles>';

Uint8List _constructedDocx() {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('word/document.xml', _constructedDocumentXml());
  add('word/styles.xml', _constructedStylesXml);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 更小的构造样本：**缩进/行距写在表格单元格里**。
///
/// 目的是把"`IntrinsicHeight`（表格行）+ 首行缩进占位 + 悬挂缩进拆分"这条路
/// 真正走一遍 —— 表格行外面套着 `IntrinsicHeight`，任何依赖固有尺寸的
/// 布局（例如 `LayoutBuilder`）都会直接抛异常。
Uint8List _inCellDocx() {
  final p1 =
      '<w:p><w:pPr><w:ind w:firstLine="420"/>'
      '<w:spacing w:line="400" w:lineRule="exact"/></w:pPr>'
      '${_run('Cell firstline paragraph')}</w:p>';
  final p2 =
      '<w:p><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>'
      '${_run('Cell hanging paragraph')}</w:p>';
  final xml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="$_wNs"><w:body><w:tbl>'
      '<w:tblGrid><w:gridCol w:w="4500"/><w:gridCol w:w="4500"/></w:tblGrid>'
      '<w:tr><w:tc><w:tcPr><w:tcW w:w="4500"/></w:tcPr>'
      '${_cellP('plain')}'
      '<w:tbl><w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>'
      '<w:tr><w:tc><w:tcPr/>${_cellP('nested inner')}</w:tc>'
      '<w:tc><w:tcPr/>${_cellP('nested two')}</w:tc></w:tr>'
      '</w:tbl>'
      '</w:tc>'
      '<w:tc><w:tcPr><w:tcW w:w="4500"/></w:tcPr>'
      '$p1$p2'
      '</w:tc></w:tr></w:tbl>'
      '${_cellP('tail')}'
      '</w:body></w:document>';
  return _docxFromParts(xml);
}

/// 只传 `document.xml` 的最小 DOCX（styles 走内置默认）。
Uint8List _docxFromParts(String documentXml) {
  final archive = Archive();
  final doc = utf8.encode(documentXml);
  archive.addFile(ArchiveFile('word/document.xml', doc.length, doc));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

OOXMLParagraph _paragraphStartingWith(ODocxDocument doc, String prefix) =>
    doc.allParagraphs.firstWhere((p) => p.text.startsWith(prefix));

void main() {
  // =========================================================================
  // 接口层（解析结果）—— 官方真样本
  // =========================================================================
  group('R. 官方真样本 product_spec.docx（12,973 B 真字节）', () {
    final doc = ODocxDocument.parse(_realDocx())!;

    test('R1. 真样本的 `w:ind`：left=450 → 30px，`w:firstLine="0"` → 首行**不加**缩进', () {
      // 原文：`<w:ind w:left="450" w:firstLine="0"/>`（2 处）。
      final withInd = doc.allParagraphs
          .where((p) => p.indentLeftPx > 0 && p.indentFirstPx > 0)
          .toList();
      expect(withInd, isEmpty, reason: '真样本的 firstLine 全是 0，不该凭空多出缩进');
      final indented = doc.allParagraphs
          .where((p) => p.indentLeftPx > 0)
          .toList();
      expect(indented.length, greaterThanOrEqualTo(2));
      for (final p in indented) {
        expect(
          p.indentLeftPx,
          closeTo(30.0, 0.01),
          reason: '450 twips / 15 = 30px',
        );
        expect(p.indentFirstPx, closeTo(0.0, 0.01));
      }
    });

    test('R2. 真样本的 `w:spacing w:line="288" lineRule="auto"` → 1.2 倍（4 处）', () {
      final l12 = doc.allParagraphs
          .where(
            (p) => p.lineHeight != null && (p.lineHeight! - 1.2).abs() < 1e-9,
          )
          .toList();
      // 288 / 240 = 1.2
      expect(l12.length, 4, reason: 'document.xml 里正好 4 处 w:line="288"');
      for (final p in l12) {
        expect(p.lineRule, 'auto');
        expect(p.linePx, isNull, reason: 'auto 规则下没有绝对行高');
      }
    });

    test('R3. 真样本 `styles.xml` 的 `w:line="240" auto` → 1.0 倍（改动前后一致）', () {
      expect(doc.styles.docDefaults?.lineHeight, closeTo(1.0, 1e-9));
      expect(doc.styles.docDefaults?.lineRule, 'auto');
      expect(doc.styles.docDefaults?.linePx, isNull);
    });

    test('R4b. 另两份官方真样本的 `w:line auto`：480 → 2.0×、276 → 1.15×', () {
      // `restaurant_menu.docx`（27,441 B）/ `student_report.docx`（241,817 B）
      // 都是官方 `.odoc` 的真字节（父批次只读下载；本批**未发起任何 NAS 请求**）。
      final menu = ODocxDocument.parse(_realDocx('restaurant_menu.docx'))!;
      final line480 = menu.allParagraphs
          .where(
            (p) => p.lineHeight != null && (p.lineHeight! - 2.0).abs() < 1e-9,
          )
          .toList();
      expect(line480.length, 1);
      expect(line480.single.lineRule, 'auto');
      expect(line480.single.linePx, isNull);
      // ⚠️ 如实说明：这一段的 `<w:r>` 里只有 `w:drawing`（`divider_19.png`），
      // **没有文字** ⇒ 行距在 Word 与本渲染器里都**没有可见载体**，
      // 所以这里只能断言"真样本的 480 被正确换算成 2.0×"，不能断言 TextStyle.height。
      expect(line480.single.text, isEmpty);
      expect(
        ooxmlEffectiveLineHeight(
          rule: line480.single.lineRule,
          linePx: line480.single.linePx,
          autoMultiple: line480.single.lineHeight,
          fontSizePt: line480.single.maxFontSizePt,
        ),
        closeTo(2.0, 1e-9),
      );

      final report = ODocxDocument.parse(_realDocx('student_report.docx'))!;
      final line276 = report.allParagraphs
          .where(
            (p) => p.lineHeight != null && (p.lineHeight! - 1.15).abs() < 1e-9,
          )
          .toList();
      expect(line276.length, 1);
      expect(line276.single.lineRule, 'auto');
      expect(line276.single.text, 'REPORT TITLE');
      expect(
        ooxmlEffectiveLineHeight(
          rule: line276.single.lineRule,
          linePx: line276.single.linePx,
          autoMultiple: line276.single.lineHeight,
          fontSizePt: line276.single.maxFontSizePt,
        ),
        closeTo(1.15, 1e-9),
      );
    });

    test('R4. 真样本**没有**嵌套表格：1 个顶层表格，单元格不含内层 w:tbl', () {
      expect(doc.allTables.length, 1);
      final cells = doc.blocks
          .where((b) => b.isTable)
          .expand((b) => b.table!.rows)
          .expand((r) => r.cells);
      for (final c in cells) {
        expect(c.hasNestedTable, isFalse);
        expect(c.tables, isEmpty);
      }
      // 旧的"只渲染外层"登记必须**不再**出现。
      expect(
        doc.notes.where((n) => n.contains('只渲染外层')),
        isEmpty,
        reason: '嵌套表格已实现，不该再登记"只渲染外层"',
      );
      expect(doc.notes.where((n) => n.contains('嵌套表格')), isEmpty);
    });
  });

  // =========================================================================
  // 接口层（解析结果）—— 构造样本
  // =========================================================================
  group('C-I. 构造样本（**不是官方样本**）：接口层', () {
    final doc = ODocxDocument.parse(_constructedDocx())!;

    test('C-I1. 嵌套表格被解析成内层 OOXMLTable（不是只登记一个 note）', () {
      // 顶层 1 个 + 内层 1 个 = 2（allTables 递归）。
      expect(doc.allTables.length, 2);
      final outer = doc.blocks.firstWhere((b) => b.isTable).table!;
      expect(outer.colWidthsPx.length, 2);
      expect(outer.colWidthsPx[0], closeTo(300.0, 0.01)); // 4500 / 15
      // 内层挂在第 2 行第 1 个单元格上。
      final host = outer.rows[1].cells[0];
      expect(host.hasNestedTable, isTrue);
      expect(host.tables.length, 1);
      expect(
        host.paragraphs.map((p) => p.text),
        contains('Cell with nested table'),
      );
      final inner = host.tables.single;
      expect(inner.colWidthsPx.length, 2);
      expect(inner.colWidthsPx[0], closeTo(200.0, 0.01)); // 3000 / 15
      // 内层表头 / 底色来自内层自己的 w:trPr·w:tcPr。
      expect(inner.rows[0].isHeader, isTrue);
      expect(outer.rows[0].isHeader, isTrue);
      expect(inner.rows[1].cells[0].shading, 'FFEEDD');
      expect(host.shading, 'DDEEFF');
      // 边框（8 分之一磅 × 4 → 0.667px）。
      expect(inner.rows[1].cells[0].borderTop!.widthPx, closeTo(4 / 6, 1e-9));
    });

    test('C-I2. 嵌套表格里的文字进 allParagraphs / plainText（不再凭空消失）', () {
      final texts = doc.allParagraphs.map((p) => p.text).toList();
      expect(
        texts,
        containsAll(<String>['Inner Header 1', 'Inner Cell 1', 'Inner Cell 2']),
      );
      expect(doc.plainText, contains('Inner Cell 1'));
    });

    test('C-I3. 单元格内容按文档顺序：段落在前、嵌套表格在后', () {
      final outer = doc.blocks.firstWhere((b) => b.isTable).table!;
      final host = outer.rows[1].cells[0];
      expect(host.blocks.map((b) => b.isTable).toList(), <bool>[false, true]);
      expect(host.blocks.first.paragraph!.text, 'Cell with nested table');
      expect(host.blocks.last.table!.rows.length, 2);
      // 没有嵌套表格的单元格只有一个段落块。
      expect(outer.rows[1].cells[1].blocks.length, 1);
    });

    test('C-I4. 解析后 notes 如实登记"已递归渲染"，而不是"只渲染外层"', () {
      expect(doc.notes.where((n) => n.contains('只渲染外层')), isEmpty);
      final logged = doc.notes
          .where((n) => n.contains('已按外层同一规则递归渲染'))
          .toList();
      expect(logged.length, 1);
      expect(logged.single, contains('1 个嵌套表格'));
    });

    test('C-I5. `w:ind w:firstLine="420"` → 28px，且 `w:left` 缺省为 0', () {
      final p = _paragraphStartingWith(doc, 'FIRSTLINE');
      expect(p.indentLeftPx, closeTo(0.0, 0.01));
      expect(p.indentFirstPx, closeTo(28.0, 0.01)); // 420 / 15
      expect(p.hangingPx, closeTo(0.0, 0.01));
    });

    test('C-I6. `w:ind w:left="720" w:hanging="360"` → 左 48px、悬挂 24px', () {
      final p = _paragraphStartingWith(doc, 'HANGING');
      expect(p.indentLeftPx, closeTo(48.0, 0.01)); // 720 / 15
      expect(p.hangingPx, closeTo(24.0, 0.01)); // 360 / 15
      expect(p.indentRightPx, closeTo(24.0, 0.01)); // 360 / 15
      expect(
        p.indentFirstPx,
        closeTo(0.0, 0.01),
        reason: 'hanging 与 firstLine 互斥',
      );
    });

    test('C-I7. `lineRule="auto"`：`w:line / 240`（360 → 1.5）', () {
      final p = _paragraphStartingWith(doc, 'AUTO360');
      expect(p.lineRule, 'auto');
      expect(p.lineHeight, closeTo(1.5, 1e-9));
      expect(p.linePx, isNull);
    });

    test('C-I8. `lineRule="exact"`：换算成绝对 twips 高度（400 → 26.667px）', () {
      final p = _paragraphStartingWith(doc, 'EXACT400 eleven');
      expect(p.lineRule, 'exact');
      expect(p.linePx, closeTo(400 / 15, 1e-9)); // 26.6667px
      expect(p.lineHeight, isNull, reason: 'exact 没有倍数，必须在渲染层按字号换算');
    });

    test('C-I9. `lineRule="atLeast"`：保留绝对高度，渲染层取 max(自然, 该值)', () {
      final low = _paragraphStartingWith(doc, 'ATLEAST200');
      final high = _paragraphStartingWith(doc, 'ATLEAST600');
      expect(low.lineRule, 'atLeast');
      expect(low.linePx, closeTo(200 / 15, 1e-9));
      expect(high.linePx, closeTo(600 / 15, 1e-9));
    });
  });

  // =========================================================================
  // 接口层：纯函数换算（exact / atLeast 的核心语义）
  // =========================================================================
  group('L. 行距换算纯函数 ooxmlEffectiveLineHeight', () {
    const size11 = 11.0 * 96 / 72; // 14.6667px
    const size24 = 24.0 * 96 / 72; // 32px

    test('L1. exact：绝对行高**不随字号变**（400 twips = 26.667px）', () {
      const px = 400 / 15;
      final m11 = ooxmlEffectiveLineHeight(
        rule: 'exact',
        linePx: px,
        autoMultiple: null,
        fontSizePt: 11,
      )!;
      final m24 = ooxmlEffectiveLineHeight(
        rule: 'exact',
        linePx: px,
        autoMultiple: null,
        fontSizePt: 24,
      )!;
      // 倍数不同……
      expect(m11, closeTo(px / size11, 1e-9));
      expect(m24, closeTo(px / size24, 1e-9));
      expect(m11, greaterThan(m24));
      // ……但"倍数 × 字号高度"是同一个绝对高度。
      expect(m11 * size11, closeTo(px, 1e-9));
      expect(m24 * size24, closeTo(px, 1e-9));
    });

    test('L2. atLeast：取 max(自然行高, 该值)', () {
      // 200 twips = 13.333px < 自然（1.0 × 14.667px）→ 自然胜出。
      expect(
        ooxmlEffectiveLineHeight(
          rule: 'atLeast',
          linePx: 200 / 15,
          autoMultiple: null,
          fontSizePt: 11,
        ),
        closeTo(1.0, 1e-9),
      );
      // 600 twips = 40px > 自然 → 该值胜出（40 / 14.6667 = 2.7273）。
      expect(
        ooxmlEffectiveLineHeight(
          rule: 'atLeast',
          linePx: 600 / 15,
          autoMultiple: null,
          fontSizePt: 11,
        ),
        closeTo(600 / 15 / size11, 1e-9),
      );
      // 有显式 auto 倍数时，"自然"用该倍数。
      expect(
        ooxmlEffectiveLineHeight(
          rule: 'atLeast',
          linePx: 200 / 15,
          autoMultiple: 1.5,
          fontSizePt: 11,
        ),
        closeTo(1.5, 1e-9),
      );
    });

    test('L3. auto 与退化输入：不声明就回退 autoMultiple，不炸', () {
      expect(
        ooxmlEffectiveLineHeight(
          rule: 'auto',
          linePx: null,
          autoMultiple: 1.5,
          fontSizePt: 11,
        ),
        closeTo(1.5, 1e-9),
      );
      // exact/atLeast 但缺 w:line（只有 lineRule）→ 回退，不返回 0/NaN。
      expect(
        ooxmlEffectiveLineHeight(
          rule: 'exact',
          linePx: null,
          autoMultiple: 1.2,
          fontSizePt: 11,
        ),
        closeTo(1.2, 1e-9),
      );
      // 拿不到字号 → 按 11pt 兜底（真机正文实测 11pt）。
      expect(
        ooxmlEffectiveLineHeight(
          rule: 'exact',
          linePx: 400 / 15,
          autoMultiple: null,
          fontSizePt: null,
        ),
        closeTo(400 / 15 / size11, 1e-9),
      );
    });

    test('L3b. 官方 5 份样本里出现过的真实 w:line 取值 → 倍数换算', () {
      // 这三个值是**父批次对 5 份官方 `.odoc` 解剖**得到的真值
      // （见本文件头"夹具来源"；其中只有 288 那份 DOCX 在仓库夹具里，
      //  480 / 276 两份**不在**本仓库 → 这里只能对换算函数断言，
      //  渲染级断言见 R-P3）。
      expect(ooxmlAutoLineMultiple(288, 'auto'), closeTo(1.2, 1e-9));
      expect(ooxmlAutoLineMultiple(480, 'auto'), closeTo(2.0, 1e-9));
      expect(ooxmlAutoLineMultiple(276, 'auto'), closeTo(1.15, 1e-9));
      // 非 auto 规则不产倍数。
      expect(ooxmlAutoLineMultiple(288, 'exact'), isNull);
      expect(ooxmlAutoLineMultiple(288, 'atLeast'), isNull);
      expect(ooxmlLinePx(288, 'exact'), closeTo(288 / 15, 1e-9));
    });

    test('L4. 1pt = 20 twips / 1px = 0.75pt 的换算基准自洽', () {
      expect(kOoxmlPtToPx, closeTo(96 / 72, 1e-12));
      // 400 twips = 20pt = 26.667px
      expect(400 / 20, closeTo(20.0, 1e-9));
      expect(kOoxmlPtToPx * 20, closeTo(400 / 15, 1e-9));
    });
  });

  // =========================================================================
  // 页面层（用户在真机上看到什么）—— 官方真样本回归
  // =========================================================================
  group('R-P. 页面层：官方真样本不受破坏', () {
    testWidgets('R-P1. 列表标记的悬挂缩进仍在（真样本 2 个 ●，位置不回归）', (tester) async {
      final doc = ODocxDocument.parse(_realDocx())!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-docx-list-marker')),
        findsNWidgets(2),
      );
      final page = tester.getRect(
        find.byKey(const Key('office-doc-paper-page-0')),
      );
      final item = doc.allParagraphs.firstWhere((p) => p.isListItem);
      // 标记槽宽 = hanging（numbering.xml 的 450 twips = 30px）。
      final marker = tester.getRect(
        find.byKey(const Key('office-docx-list-marker')).first,
      );
      expect(item.hangingPx, closeTo(30.0, 0.01));
      expect(marker.left - page.left, closeTo(96.0, 1.0), reason: '标记在正文左边界');
      expect(marker.width, closeTo(30.0, 0.5));
    });

    testWidgets('R-P3. 真样本 `w:line="288" auto` **真的渲染成 1.2 倍行高**', (
      tester,
    ) async {
      final doc = ODocxDocument.parse(_realDocx())!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      // document.xml 里带 `w:line="288"` 的 4 段：YOUR COMPANY / Product Name /
      // Functional Spec / 空段。前两段是可见的 `Text`。
      for (final t in <String>[
        'YOUR COMPANY',
        'Product Name',
        'Functional Spec',
      ]) {
        final w = tester.widget<Text>(find.text(t));
        expect(
          w.style!.height,
          closeTo(1.2, 1e-9),
          reason: '288 / 240 = 1.2 —— 必须真的作用到行盒，不只是"读到了属性"',
        );
      }
      // 对照组：没有段落级 `w:line` 的正文回退到 styles.xml 的 1.5。
      final normal = tester.widget<Text>(
        find.text('Describe the concept of this product here.'),
      );
      expect(normal.style!.height, closeTo(1.5, 1e-9));
    });

    testWidgets('R-P4. 真样本 `w:line="276" auto` 渲染成 1.15 倍行高（Student report）', (
      tester,
    ) async {
      final doc = ODocxDocument.parse(_realDocx('student_report.docx'))!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      final title = tester.widget<Text>(find.text('REPORT TITLE'));
      // 276 / 240 = 1.15 —— 真样本、渲染级。
      expect(title.style!.height, closeTo(1.15, 1e-9));
    });

    testWidgets('R-P2. 真样本首行缩进为 0：**没有**首行缩进占位（不凭空多缩进）', (tester) async {
      final doc = ODocxDocument.parse(_realDocx())!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(kOfficeDocxFirstLineIndentKey), findsNothing);
      expect(find.byKey(const Key('office-docx-hanging-rest')), findsNothing);
    });
  });

  // =========================================================================
  // 页面层 —— 构造样本
  // =========================================================================
  group('C-P. 页面层：构造样本（**不是官方样本**）', () {
    Future<ODocxDocument> pump(WidgetTester tester) async {
      final doc = ODocxDocument.parse(_constructedDocx())!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      return doc;
    }

    testWidgets('C-P1. 首行缩进：只有**第一行**右移 28px，末行仍在段左边界', (tester) async {
      final doc = await pump(tester);
      final p = _paragraphStartingWith(doc, 'FIRSTLINE');
      final indent = find.byKey(kOfficeDocxFirstLineIndentKey);
      expect(indent, findsOneWidget);
      // 占位宽度 = 420 twips / 15 = 28px。
      expect(tester.getSize(indent).width, closeTo(28.0, 0.01));

      // 段落文字（Text.rich）与纸面左边界对齐 → **整段没有被推走**。
      final page = tester.getRect(
        find.byKey(const Key('office-doc-paper-page-0')),
      );
      final rich = find.ancestor(of: indent, matching: find.byType(RichText));
      expect(rich, findsOneWidget);
      expect(tester.getTopLeft(rich).dx - page.left, closeTo(96.0, 1.0));
      expect(
        tester.getTopLeft(indent).dx,
        closeTo(tester.getTopLeft(rich).dx, 0.5),
      );

      // 用 RenderParagraph 量行内盒：
      //   * 首行第 1 个字符在 +28（被占位 span 顶开）；
      //   * **最后一行**的左边界回到 0（= 不是"整段左缩进"）。
      final rp = tester.renderObject<RenderParagraph>(rich);
      // span 偏移 0 是占位 span（算 1 个偏移），正文从偏移 1 开始。
      final firstChar = rp
          .getBoxesForSelection(
            const TextSelection(baseOffset: 1, extentOffset: 2),
          )
          .first;
      expect(firstChar.left, closeTo(28.0, 1.0), reason: '首行文字从 28px 开始');
      final allLines = rp.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: 1 + p.text.length),
      );
      expect(allLines.length, greaterThan(1), reason: '这段文字必须换行，否则测不出"只有首行缩进"');
      expect(
        allLines.last.left,
        closeTo(0.0, 1.5),
        reason: '换行后的行回到段落左边界（= 不是整段左缩进）',
      );
    });

    testWidgets('C-P2. 悬挂缩进：首行在 24px，续行在 48px（且不丢字）', (tester) async {
      final doc = await pump(tester);
      final p = _paragraphStartingWith(doc, 'HANGING');
      final first = find.byKey(const Key('office-docx-hanging-first'));
      final rest = find.byKey(const Key('office-docx-hanging-rest'));
      expect(first, findsOneWidget);
      expect(rest, findsOneWidget);
      final page = tester.getRect(
        find.byKey(const Key('office-doc-paper-page-0')),
      );
      final contentLeft = page.left + 96.0;
      // 量**文字**的位置（Padding 的 box 左边界不含自身 padding，量 Padding 会失真）。
      final firstText = find
          .descendant(of: first, matching: find.byType(Text))
          .first;
      final restText = find
          .descendant(of: rest, matching: find.byType(Text))
          .first;
      // w:left=720 → 48px，w:hanging=360 → 24px；首行在 48-24=24，续行在 48。
      expect(tester.getTopLeft(firstText).dx - contentLeft, closeTo(24.0, 0.5));
      expect(tester.getTopLeft(restText).dx - contentLeft, closeTo(48.0, 0.5));
      // 右缩进 `w:right="360"`（24px）只能扣一次（续行文字右边界距正文右边界 24px）。
      final contentRight = page.right - 96.0;
      expect(
        contentRight - tester.getRect(restText).right,
        closeTo(24.0, 0.5),
        reason: '右缩进被扣两次会让续行窄 24px（本批踩过这个坑）',
      );
      // 拆行不能丢字。
      String dataOf(Finder f) => tester
          .widget<Text>(
            find.descendant(of: f, matching: find.byType(Text)).first,
          )
          .data!;
      expect(dataOf(first) + dataOf(rest), p.text);
      expect(dataOf(first).isNotEmpty, isTrue);
      expect(dataOf(rest).isNotEmpty, isTrue);
    });

    testWidgets('C-P3. 嵌套表格真的画出来了，且宽度受父单元格约束（不撑破外层）', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('office-docx-table')), findsOneWidget);
      final nested = find.byKey(const Key('office-docx-nested-table'));
      expect(nested, findsOneWidget, reason: '内层表格必须渲染，不能只登记');
      expect(nested, findsOneWidget);

      final host = tester.getRect(
        find.byKey(const Key('office-docx-cell-1-0')),
      );
      final nestedRect = tester.getRect(nested);
      // 外列 4500 twips = 300px；内层声明 400px > 父单元格内容宽 → 等比压缩。
      expect(host.width, closeTo(300.0, 0.5));
      expect(nestedRect.width, lessThanOrEqualTo(host.width - 12.0 + 0.5));
      expect(nestedRect.right, lessThanOrEqualTo(host.right + 0.5));
      expect(nestedRect.left, greaterThanOrEqualTo(host.left - 0.5));
      // 两列各占一半（3000 twips 声明 → 等比压缩后 ≈143.3px）。
      final c0 = tester.getSize(
        find.byKey(const Key('office-docx-nested-cell-1-0')),
      );
      final c1 = tester.getSize(
        find.byKey(const Key('office-docx-nested-cell-1-1')),
      );
      expect(c0.width, closeTo(c1.width, 0.5));
      expect(c0.width * 2, closeTo(nestedRect.width, 0.5));
      expect(c0.width, lessThan(host.width));
    });

    testWidgets('C-P4. 嵌套表格与外层同一套规则：表头加粗、底色、边框都在', (tester) async {
      await pump(tester);
      expect(find.text('Inner Header 1'), findsOneWidget);
      expect(find.text('Inner Cell 1'), findsOneWidget);
      // 内层表头行加粗（w:tblHeader）。
      expect(
        tester.widget<Text>(find.text('Inner Header 1')).style!.fontWeight,
        FontWeight.w700,
      );
      // 外层表头行同样加粗。
      expect(
        tester.widget<Text>(find.text('Outer Header A')).style!.fontWeight,
        FontWeight.w700,
      );
      // 非表头行不加粗。
      expect(
        tester.widget<Text>(find.text('Inner Cell 1')).style!.fontWeight,
        FontWeight.w400,
      );
      expect(
        tester.widget<Text>(find.text('Sibling cell')).style!.fontWeight,
        FontWeight.w400,
      );
      // 内层单元格底色来自内层 w:shd。
      final innerCell = tester.widget<Container>(
        find.byKey(const Key('office-docx-nested-cell-1-0')),
      );
      expect(
        (innerCell.decoration! as BoxDecoration).color,
        officeDocParseColor('FFEEDD'),
      );
      // 边框真实可见（不是 BorderSide.none）。
      final border = (innerCell.decoration! as BoxDecoration).border! as Border;
      expect(border.top.width, greaterThan(0));
      expect(border.top.color, isNot(Colors.transparent));
    });

    testWidgets('C-P5. `lineRule="exact"`：字号变大、倍数变小，绝对行盒不变', (tester) async {
      await pump(tester);
      const px = 400 / 15;
      final p11 = tester.widget<Text>(find.text('EXACT400 eleven point'));
      final p24 = tester.widget<Text>(find.text('EXACT400 twentyfour point'));
      final h11 = p11.style!.height!;
      final h24 = p24.style!.height!;
      final f11 = p11.style!.fontSize!;
      final f24 = p24.style!.fontSize!;
      // 11pt → 26.667 / 14.667 = 1.818；24pt → 26.667 / 32 = 0.833
      expect(h11, closeTo(px / f11, 1e-9));
      expect(h24, closeTo(px / f24, 1e-9));
      expect(h11, greaterThan(h24));
      // **绝对行高一致**（这才是 exact 的语义）。
      expect(h11 * f11, closeTo(px, 1e-6));
      expect(h24 * f24, closeTo(px, 1e-6));
    });

    testWidgets('C-P6. `lineRule="atLeast"`：低值取自然行高、高值取该值', (tester) async {
      await pump(tester);
      final low = tester.widget<Text>(find.text('ATLEAST200 below natural'));
      final high = tester.widget<Text>(find.text('ATLEAST600 above natural'));
      // 200 twips = 13.333px < 自然（1.0 倍）→ 1.0
      expect(low.style!.height, closeTo(1.0, 1e-9));
      // 600 twips = 40px → 40 / 14.667 = 2.7273
      expect(
        high.style!.height,
        closeTo(600 / 15 / high.style!.fontSize!, 1e-9),
      );
      expect(high.style!.height!, greaterThan(low.style!.height!));
    });

    testWidgets('C-P7. `auto` 行距照旧 360/240 = 1.5（未被本批改坏）', (tester) async {
      await pump(tester);
      final auto = tester.widget<Text>(find.text('AUTO360 body line spacing'));
      expect(auto.style!.height, closeTo(1.5, 1e-9));
    });

    testWidgets('C-P8. 整篇构造文档能画完、不溢出、无异常', (tester) async {
      await pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('office-doc-paper-page-0')), findsOneWidget);
    });
  });

  // =========================================================================
  // 页面层 —— 缩进/行距写在**表格单元格**里（构造样本）
  // =========================================================================
  group('C-PC. 页面层：单元格里的缩进与行距（构造样本）', () {
    testWidgets('C-PC1. 单元格里同时有嵌套表格 + firstLine + hanging：不崩、缩进生效', (
      tester,
    ) async {
      final doc = ODocxDocument.parse(_inCellDocx())!;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      // 表格行外面是 IntrinsicHeight：任何 LayoutBuilder 都会在这里炸。
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('office-docx-nested-table')), findsOneWidget);
      // 单元格里的首行缩进占位（唯一一个）。
      final indent = find.byKey(kOfficeDocxFirstLineIndentKey);
      expect(indent, findsOneWidget);
      expect(tester.getSize(indent).width, closeTo(28.0, 0.01));
      // 单元格里的悬挂缩进（首行 / 续行分别定位，且不丢字）。
      final first = find.byKey(const Key('office-docx-hanging-first'));
      final rest = find.byKey(const Key('office-docx-hanging-rest'));
      expect(first, findsOneWidget);
      expect(rest, findsOneWidget);
      final firstText = find
          .descendant(of: first, matching: find.byType(Text))
          .first;
      final restText = find
          .descendant(of: rest, matching: find.byType(Text))
          .first;
      // 单元格内容宽 = 300 − 12 = 288（无边框）→ 首行 24、续行 48。
      final cell = tester.getRect(
        find.byKey(const Key('office-docx-cell-0-1')),
      );
      expect(
        tester.getTopLeft(firstText).dx - cell.left - 6,
        closeTo(24.0, 1.0),
      );
      expect(
        tester.getTopLeft(restText).dx - cell.left - 6,
        closeTo(48.0, 1.0),
      );
      String dataOf(Finder f) => tester
          .widget<Text>(
            find.descendant(of: f, matching: find.byType(Text)).first,
          )
          .data!;
      expect(dataOf(first) + dataOf(rest), contains('Cell hanging paragraph'));
      // 单元格里的 exact 行距也换算到了（400 twips / 15 / 14.667px = 1.818）。
      // 注意：带首行缩进的段落走 `Text.rich`（行内多了一个占位 span），
      // `find.text` 匹配不到，所以从 `RichText` 的行内 span 上读样式。
      final rich = find.ancestor(of: indent, matching: find.byType(RichText));
      // `Text.rich` 会把传入的 span 再包一层（DefaultTextStyle），所以要递归找。
      TextSpan? found;
      void walk(InlineSpan sp) {
        if (sp is! TextSpan) return;
        if (sp.text == 'Cell firstline paragraph') found = sp;
        for (final c in sp.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      }

      walk(tester.widget<RichText>(rich).text);
      final innerStyle = found!.style!;
      expect(innerStyle.height, closeTo(400 / 15 / innerStyle.fontSize!, 1e-9));
    });
  });
}
