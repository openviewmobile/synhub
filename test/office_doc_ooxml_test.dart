// O1（`.odoc` 重做）—— **DOCX（OOXML）解析**的离线用例。
//
// 夹具是**从真机 NAS 只读下载回来的真实字节**（`Files:download` 把 `.odoc`
// 转码成标准 DOCX）：
//   * `test/fixtures/office_doc_redesign/product_spec.docx`
//     —— 源 `Product spec.odoc`，NAS 上 `size=3390`（原生 OFile），
//     下载回来 **12,973 B**、头 `PK\x03\x04`；sha256 见 MANIFEST。
//
// 断言里的数字**全部来自原文**（不是"我以为"）：
//   * `word/document.xml` 的 `<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>`
//     + `<w:pgMar w:top/right/bottom/left="1440"/>`；
//   * `word/styles.xml` 的 `<w:docDefaults><w:sz w:val="22"/>`（11pt）、
//     `Heading1` 的 `<w:outlineLvl w:val="0"/>` + `<w:sz w:val="48"/>`（24pt）；
//   * `word/numbering.xml` 的 `<w:lvlText w:val="●"/>`（bullet）；
//   * `word/document.xml` 的 `<w:tblGrid><w:gridCol w:w="2040"/>…`。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_doc_ooxml.dart';
import 'package:synhub/src/features/office/office_doc_ooxml_view.dart';

Uint8List _fixture(String name) => Uint8List.fromList(
  File('test/fixtures/office_doc_redesign/$name').readAsBytesSync(),
);

/// 造一个只含单段的块列表（给判定函数用）。
List<OOXMLBlock> _p(String text) => <OOXMLBlock>[
  OOXMLBlock.paragraph(OOXMLParagraph(runs: <OOXMLRun>[OOXMLRun(text: text)])),
];

void main() {
  final bytes = _fixture('product_spec.docx');

  group('X1. 容器与页面设置（A4 来自 w:sectPr，不是猜的）', () {
    test('真机下载回来的是 ZIP（PK\\x03\\x04），不是原生 OFile', () {
      expect(bytes.length, 12973);
      expect(ODocxDocument.looksLikeDocx(bytes), isTrue);
      expect(bytes.sublist(0, 4), <int>[0x50, 0x4B, 0x03, 0x04]);
    });

    test('非 ZIP 字节 → parse 返回 null（调用方据此走 OFile 回落）', () {
      final notZip = Uint8List.fromList(List<int>.filled(64, 7));
      expect(ODocxDocument.looksLikeDocx(notZip), isFalse);
      expect(ODocxDocument.parse(notZip), isNull);
      expect(ODocxDocument.parse(Uint8List(0)), isNull);
    });

    test('A4 纵向 210×297mm → 793.7×1122.5px；页边距 2.54cm → 96px', () {
      final doc = ODocxDocument.parse(bytes);
      expect(doc, isNotNull);
      final page = doc!.pageSetup;
      expect(page.rawWidthTwips, 11906);
      expect(page.rawHeightTwips, 16838);
      expect(page.isA4, isTrue);
      expect(page.orientation, 'portrait');
      // 11906 / 15 = 793.7（96 dpi）
      expect(page.widthPx, closeTo(793.73, 0.02));
      expect(page.heightPx, closeTo(1122.53, 0.02));
      // 1440 twips = 1 inch = 96 px = 2.54cm
      expect(page.marginLeftPx, closeTo(96.0, 0.01));
      expect(page.marginRightPx, closeTo(96.0, 0.01));
      expect(page.marginTopPx, closeTo(96.0, 0.01));
      expect(page.marginBottomPx, closeTo(96.0, 0.01));
      // 内容区宽 = 793.73 - 192 = 601.73；与专有路径 colgroup 之和 600/601 自洽。
      expect(page.contentWidthPx, closeTo(601.73, 0.05));
      // A4 宽高比 ≈ 0.707
      expect(page.widthPx / page.heightPx, closeTo(0.7071, 0.001));
    });
  });

  group('X2. 样式（w:pStyle + styles.xml → 标题层级与字号）', () {
    test('docDefaults 是 11pt / Arial / 1.5 倍行距', () {
      final doc = ODocxDocument.parse(bytes)!;
      final defaults = doc.styles.docDefaults;
      expect(defaults, isNotNull);
      expect(defaults!.sizePt, 11.0); // <w:sz w:val="22"/> 半磅
      expect(defaults.fontFamily, 'Arial');
      // `w:docDefaults` 自身是 line=240 → 1.0；`Normal` 样式是 360 → 1.5，
      // 段落经**样式链合并**后拿到 1.5（见下一条用例）。
      expect(defaults.lineHeight, 1.0);
    });

    test('Heading1/2 的 outlineLvl 与字号逐字来自 styles.xml', () {
      final doc = ODocxDocument.parse(bytes)!;
      final h1 = doc.styles['Heading1'];
      final h2 = doc.styles['Heading2'];
      expect(h1, isNotNull);
      expect(h2, isNotNull);
      expect(h1!.outlineLevel, 0); // → headingLevel 1
      expect(h2!.outlineLevel, 1); // → headingLevel 2
      expect(h1.sizePt, 24.0); // <w:sz w:val="48"/>
      expect(h2.sizePt, 20.0); // <w:sz w:val="40"/>
      // 段前/段后：300/90 twips → 20/6 px
      expect(h1.spacingBeforePx, closeTo(20.0, 0.01));
      expect(h1.spacingAfterPx, closeTo(6.0, 0.01));
    });

    test('段落：Heading1 → headingLevel 1，正文 → 0（正文继承 docDefaults 11pt）', () {
      final doc = ODocxDocument.parse(bytes)!;
      final headings = doc.allParagraphs
          .where((p) => p.headingLevel > 0)
          .toList();
      expect(headings, isNotEmpty);
      expect(headings.any((p) => p.styleId == 'Heading1'), isTrue);
      expect(headings.any((p) => p.styleId == 'Heading2'), isTrue);

      // ⚠️ 必须带上 `headingLevel == 1`：正文里有一份**文档自带**的目录
      //   （`w:sdt`，解析层已修复不再丢弃），它的条目文字就是标题原文
      //   ⇒ 不带条件会**先命中目录条目**（那是普通段落，headingLevel = 0）。
      final intro = doc.allParagraphs.firstWhere(
        (p) => p.text.startsWith('1. Introduction') && p.headingLevel == 1,
      );
      expect(intro.headingLevel, 1);
      expect(intro.styleId, 'Heading1');

      final body = doc.allParagraphs.firstWhere(
        (p) => p.text.startsWith('Describe the concept'),
      );
      expect(body.headingLevel, 0);
      // run 没写 <w:sz> → 继承 docDefaults 的 11pt（而不是 null/0）。
      expect(body.maxFontSizePt, 11.0);
    });

    test('标题字号 **严格大于** 正文字号（用户抱怨的"标题没按字号渲染"）', () {
      final doc = ODocxDocument.parse(bytes)!;
      final body = doc.allParagraphs.firstWhere(
        (p) => p.text.startsWith('Describe the concept'),
      );
      // 同上：取**标题**那份，不是目录条目。
      final heading = doc.allParagraphs.firstWhere(
        (p) => p.text.startsWith('1. Introduction') && p.headingLevel == 1,
      );
      final bodyPt = body.maxFontSizePt!;
      final headingPt = heading.maxFontSizePt!;
      expect(headingPt, greaterThan(bodyPt));
      // 段落经样式链合并后拿到 `Normal` 的 1.5 倍行距（docDefaults 是 1.0）。
      expect(body.lineHeight, 1.5);
      expect(heading.lineHeight, 1.5);
      // 样式层面：`Heading1`（24pt）> `w:docDefaults`（11pt）。
      expect(
        doc.styles['Heading1']!.sizePt!,
        greaterThan(doc.styles.docDefaults!.sizePt!),
      );
    });

    test('富文本：粗体 / 颜色 / 字体 / 对齐都读出来了', () {
      final doc = ODocxDocument.parse(bytes)!;
      final rich = doc.allParagraphs.firstWhere(
        (p) => p.text == 'Product Name',
      );
      expect(rich.runs.single.bold, isTrue);
      expect(rich.runs.single.sizePt, 50.0); // <w:sz w:val="100"/>

      final brand = doc.allParagraphs.firstWhere(
        (p) => p.text == 'YOUR COMPANY',
      );
      expect(brand.runs.single.color, '#4176cc');
      expect(brand.runs.single.fontFamily, 'Trebuchet MS');

      final centered = doc.allParagraphs.firstWhere(
        (p) => p.text == 'Version Number',
      );
      expect(centered.alignment, 'center');
      // 深色文字来自 docDefaults（#000000）而不是 null。
      expect(centered.runs.single.color, isNotNull);
    });

    test('颜色取值至少覆盖真机实测集合里的一个', () {
      final doc = ODocxDocument.parse(bytes)!;
      final colors = <String>{
        for (final p in doc.allParagraphs)
          for (final r in p.runs)
            if (r.color != null) r.color!,
      };
      // 父代理用 Python 独立算出这份文件的色值是
      // #0F7BE9 / #15658c / #4176cc / #64696e；这里逐个核对（大小写不敏感）。
      final lower = colors.map((c) => c.toLowerCase()).toSet();
      expect(
        lower.intersection(<String>{
          '#0f7be9',
          '#15658c',
          '#4176cc',
          '#64696e',
        }),
        isNotEmpty,
        reason: '实际颜色：$colors',
      );
      expect(lower.contains('#4176cc'), isTrue);
    });
  });

  group('X3. 列表（w:numPr + numbering.xml → 真实标记）', () {
    test('2 处 numPr → ilvl 0 的项目符号，标记是 ●（不是字面 "-"）', () {
      final doc = ODocxDocument.parse(bytes)!;
      final items = doc.allParagraphs.where((p) => p.isListItem).toList();
      expect(items.length, 2);
      for (final item in items) {
        expect(item.numId, 1);
        expect(item.numLevel, 0);
        expect(item.marker, '●');
        expect(item.ordered, isFalse);
        // **关键**：标记来自 numbering.xml，不是把 "-" 拼进正文。
        expect(item.text.startsWith('-'), isFalse);
        expect(item.text.startsWith('●'), isFalse);
      }
      expect(
        items.map((p) => p.text),
        containsAll(<String>[
          'Record the issues without conclusions.',
          'Propose the next step for this product.',
        ]),
      );
    });

    test('挂起缩进来自 w:ind（left=450 / hanging=450 → 30px）', () {
      final doc = ODocxDocument.parse(bytes)!;
      final item = doc.allParagraphs.firstWhere((p) => p.isListItem);
      expect(item.indentLeftPx, closeTo(30.0, 0.01));
      expect(item.hangingPx, closeTo(30.0, 0.01));
      expect(item.markerIndentPx, closeTo(30.0, 0.01));
    });

    test('numbering.xml 的层级定义可解析（● / ○ / ■ 与 decimal 格式渲染）', () {
      final doc = ODocxDocument.parse(bytes)!;
      final levels = doc.numbering[1];
      expect(levels, isNotNull);
      expect(levels![0]!.text, '●');
      expect(levels[1]!.text, '○');
      expect(levels[2]!.text, '■');
      expect(levels[0]!.isBullet, isTrue);
      // 有序格式的渲染（离线纯函数，不依赖夹具里有 ol）。
      const decimal = OOXMLNumberLevel(
        start: 1,
        format: 'decimal',
        text: '%1.',
      );
      expect(decimal.render(3), '3.');
      const lower = OOXMLNumberLevel(
        start: 1,
        format: 'lowerLetter',
        text: '%1)',
      );
      expect(lower.render(1), 'a)');
      expect(lower.render(27), 'aa)');
      const roman = OOXMLNumberLevel(
        start: 1,
        format: 'upperRoman',
        text: '%1.',
      );
      expect(roman.render(4), 'IV.');
    });
  });

  group('X4. 表格（w:tblGrid → 每列声明的宽度）', () {
    test('列宽是声明值、互不相同，且总和 = 正文区宽（600 ≈ 601.7）', () {
      final doc = ODocxDocument.parse(bytes)!;
      final tables = doc.blocks.where((b) => b.isTable).toList();
      expect(tables.length, 1);
      final table = tables.single.table!;
      // <w:gridCol w:w="2040/1770/3480/1710"/> ÷ 15
      expect(table.colWidthsPx, <double>[136.0, 118.0, 232.0, 114.0]);
      expect(table.colWidthsPx.toSet().length, 4, reason: '四列宽度互不相同');
      expect(table.totalWidthPx, closeTo(600.0, 0.01));
      expect(table.totalWidthPx, lessThan(doc.pageSetup.contentWidthPx));
      expect(table.hasGrid, isTrue);
    });

    test('行高 / 边框 / 垂直居中 / 单元格文字', () {
      final doc = ODocxDocument.parse(bytes)!;
      final table = doc.blocks.firstWhere((b) => b.isTable).table!;
      expect(table.rows.length, 5);
      expect(table.rows.first.heightPx, closeTo(28.0, 0.01)); // trHeight 420
      final cell = table.rows.first.cells.first;
      expect(cell.text, 'Version Number');
      expect(cell.gridSpan, 1);
      expect(cell.verticalAlign, 'center'); // <w:vAlign w:val="center"/>
      expect(cell.widthPx, closeTo(136.0, 0.01));
      // 四边都在（<w:tcBorders> 的 bottom/right/top/left 各 sz=6 → 0.75pt → 1px）
      expect(cell.borderTop!.visible, isTrue);
      expect(cell.borderBottom!.visible, isTrue);
      expect(cell.borderLeft!.visible, isTrue);
      expect(cell.borderRight!.visible, isTrue);
      expect(cell.borderTop!.widthPx, closeTo(1.0, 0.01));
      expect(cell.borderTop!.color, '#aaaaaa');
      expect(table.rows.last.cells.first.text, '');
    });
  });

  group('X5. 媒体 / 页眉页脚 / 降级登记', () {
    test('包内图片字节被读出且是真 PNG', () {
      final doc = ODocxDocument.parse(bytes)!;
      expect(doc.media.keys, contains('word/media/image1.png'));
      final png = doc.media['word/media/image1.png']!;
      expect(png.length, 948);
      // PNG 魔数 89 50 4E 47
      expect(png.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
    });

    test('段内 drawing 的尺寸来自 wp:extent（EMU ÷ 9525）', () {
      final doc = ODocxDocument.parse(bytes)!;
      final images = <OOXMLImage>[
        for (final p in doc.allParagraphs)
          for (final r in p.runs)
            if (r.image != null) r.image!,
      ];
      expect(images, isNotEmpty);
      for (final image in images) {
        expect(image.mediaPath, 'word/media/image1.png');
        expect(image.widthPx, greaterThan(0));
        expect(image.heightPx, greaterThan(0));
      }
    });

    test('页眉/页脚存在但为空 → 一条如实的 notes 登记（不是静默）', () {
      final doc = ODocxDocument.parse(bytes)!;
      expect(doc.headers.length, 3);
      expect(doc.footers.length, 3);
      expect(doc.headers.values.every((v) => v.trim().isEmpty), isTrue);
      expect(
        doc.notes.any((n) => n.contains('页眉/页脚存在但内容为空')),
        isTrue,
        reason: '${doc.notes}',
      );
    });

    test('纯文本与字数', () {
      final doc = ODocxDocument.parse(bytes)!;
      expect(doc.plainText, contains('Functional Spec'));
      expect(doc.plainText, contains('Record the issues without conclusions.'));
      expect(doc.textLength, greaterThan(400));
      expect(doc.isEmpty, isFalse);
    });
  });

  // =========================================================================
  // X-SDT：**块级 `w:sdt`（内容控件）必须下钻**，否则文档自带的目录被整块丢弃
  //
  // 真机取证（直接数 `word/document.xml` 的 body 直接子元素）：
  //   * `Product spec`  : 26×`w:p` + 1×`w:tbl` + **1×`w:sdt`**
  //       —— 该 SDT `docPartGallery="Table of Contents"`，内含 **7 个 `w:p`**
  //          （`1. Introduction` … `5. To Be Discussed`，带 `w:hyperlink w:anchor="_Toc…"`）
  //   * `Student report`: 35×`w:p` + **1×`w:sdt`**（内含 **9 条**目录条目）
  //   * `Restaurant menu`: 43×`w:p`，**没有任何 `w:sdt`**
  //
  // 旧实现只处理 `p`/`tbl`/`sectPr`，`w:sdt` 落进 `default: break` ⇒
  // **文档自带的目录整个丢掉**，正文里只剩 "Table of Contents" 标题、下面空着。
  // =========================================================================
  group('X-SDT. 块级 `w:sdt` 下钻（文档自带目录的还原）', () {
    test('S1. `Product spec`：27 → 34 块，7 条真目录进正文且顺序在标题之后', () {
      final doc = ODocxDocument.parse(_fixture('product_spec.docx'))!;
      expect(doc.hasTocContentControl, isTrue);
      expect(doc.blocks.length, 34, reason: '27（旧）+ 7 条 SDT 里的目录条目');

      final texts = doc.allParagraphs
          .map((p) => p.text.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      final titleAt = texts.indexOf('Table of Contents');
      expect(titleAt, greaterThanOrEqualTo(0), reason: '目录标题段在正文里');
      expect(texts.sublist(titleAt + 1, titleAt + 4), <String>[
        '1. Introduction',
        '2. Summary',
        '3. Specifications',
      ], reason: '目录条目必须在标题之后、且保持文档顺序');
      // 这 7 条**不是标题**（是目录条目）⇒ headingLevel = 0。
      final entries = doc.allParagraphs.where(
        (p) => p.text.trim() == '2. Summary',
      );
      expect(
        entries.any((p) => p.headingLevel == 0),
        isTrue,
        reason: '目录条目是普通段落；真实标题另外还有一份（headingLevel = 1）',
      );
    });

    test(
      'S2. `Student report`：35 → 44 块 / 9 条；`Restaurant menu` 一个 SDT 都没有',
      () {
        final rep = ODocxDocument.parse(_fixture('student_report.docx'))!;
        expect(rep.hasTocContentControl, isTrue);
        expect(rep.blocks.length, 44);

        final menu = ODocxDocument.parse(_fixture('restaurant_menu.docx'))!;
        expect(
          menu.hasTocContentControl,
          isFalse,
          reason: 'restaurant_menu 的 body 是 43 个 w:p + sectPr，没有 w:sdt',
        );
        expect(menu.blocks.length, 43);
        expect(
          menu.allParagraphs.any(
            (p) => p.text.trim().toLowerCase() == 'table of contents',
          ),
          isFalse,
        );
      },
    );

    test('S3. 判定函数 `officeDocxHasRealToc` 的两条判据（含中文目录标题）', () {
      // 判据①：SDT 内容控件（精确）。
      expect(
        officeDocxHasRealToc(const <OOXMLBlock>[], hasTocContentControl: true),
        isTrue,
      );
      // 判据②：目录标题段（原生 OFile 通道也能用）——英文与中文都要认。
      expect(officeDocxHasRealToc(_p('Table of Contents')), isTrue);
      expect(officeDocxHasRealToc(_p('目录')), isTrue);
      expect(officeDocxHasRealToc(_p('  目錄  ')), isTrue);
      // 非目录的普通文字**不许**误判。
      expect(officeDocxHasRealToc(_p('Appetizers')), isFalse);
      expect(officeDocxHasRealToc(_p('Table of Content')), isFalse);
      expect(officeDocxHasRealToc(const <OOXMLBlock>[]), isFalse);
    });
  });
}
