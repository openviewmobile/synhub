// O1（`.odoc` 重做）—— **页面层**用例：断言"用户真的看到了什么"。
//
// 用户原话：「Office 里面三种格式的文档显示还是离预期很远…参考下 wps，或者
// microsoft office 的安卓版是如何展示文档的」。所以这里断言的是**版式事实**，
// 不是"函数被调用了"：
//   * 一张 **A4 白纸**（793.7×1122.5 px，宽高比 ≈ 0.707）；
//   * 纸面左右有 **非零页边距 96 px**（= 2.54cm，来自 `w:pgMar`）；
//   * 表格按 `w:tblGrid` 的**声明列宽**排（四列互不相同、且不拉满整页）；
//   * 列表是**真实标记 `●`**，正文里没有把 `-` 当项目符号；
//   * 标题字号 **严格大于** 正文字号；
//   * **没有**任何开发者横幅（"只读渲染 / 从简 / 本批…"）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_doc_ooxml.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_doc_ooxml_view.dart';

Uint8List _docxBytes() => Uint8List.fromList(
  File('test/fixtures/office_doc_redesign/product_spec.docx').readAsBytesSync(),
);

Future<ODocxDocument> _pump(WidgetTester tester) async {
  final doc = ODocxDocument.parse(_docxBytes())!;
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.dark(), 
      home: Scaffold(body: OfficeDocxView(doc: doc)),
    ),
  );
  await tester.pumpAndSettle();
  return doc;
}

void main() {
  testWidgets('P1. 有 A4 纸面：793.7×1122.5px、宽高比 ≈ 0.707', (tester) async {
    await _pump(tester);
    final page = find.byKey(const Key('office-doc-paper-page-0'));
    expect(page, findsOneWidget, reason: '必须存在 A4 纸面 Widget');
    final size = tester.getSize(page);
    expect(size.width, closeTo(793.73, 0.1));
    expect(size.height, closeTo(1122.53, 0.1));
    expect(size.width / size.height, closeTo(0.7071, 0.002));
    // 纸面阅读容器（灰底 + 缩放 + 页码指示）也在。
    expect(find.byKey(const Key('office-doc-paper')), findsOneWidget);
    expect(find.byKey(const Key('office-doc-paper-viewer')), findsOneWidget);
    expect(find.byKey(const Key('office-doc-fit-width')), findsOneWidget);
  });

  testWidgets('P2. 左右页边距是真的 96px（不是 0，也不是"看起来差不多"）', (tester) async {
    await _pump(tester);
    final page = tester.getRect(
      find.byKey(const Key('office-doc-paper-page-0')),
    );
    // 正文第一段（`YOUR COMPANY`，无缩进）的左边界 = 纸面左 + 96。
    final text = tester.getRect(find.text('YOUR COMPANY'));
    expect(text.left - page.left, closeTo(96.0, 1.0));
    // 表格总宽 600px 的内容区也贴着同一条左边距，右边还剩 ~97.7px。
    final table = tester.getRect(find.byKey(const Key('office-docx-table')));
    expect(table.left - page.left, closeTo(96.0, 1.0));
    // 最后一列的右边界：96 + (136+118+232+114) = 696 → 右边距剩 97.73px。
    final lastCell = tester.getRect(
      find.byKey(const Key('office-docx-cell-0-3')),
    );
    expect(page.right - lastCell.right, closeTo(97.73, 1.0));
    expect(page.left < table.left, isTrue, reason: '左右都必须是**非零**页边距');
    expect(lastCell.right < page.right, isTrue);
  });

  testWidgets('P3. 表格按声明列宽排：四列互不相同、都不等于整页宽', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('office-docx-table')), findsOneWidget);
    expect(find.byKey(const Key('office-docx-table-row-0')), findsOneWidget);
    final widths = <double>[
      for (var i = 0; i < 4; i++)
        tester.getSize(find.byKey(Key('office-docx-cell-0-$i'))).width,
    ];
    // w:tblGrid → 2040/1770/3480/1710 twips ÷ 15 = 136/118/232/114 px
    expect(widths[0], closeTo(136.0, 0.5));
    expect(widths[1], closeTo(118.0, 0.5));
    expect(widths[2], closeTo(232.0, 0.5));
    expect(widths[3], closeTo(114.0, 0.5));
    expect(widths.toSet().length, 4, reason: '列宽必须来自原文，不能均分');
    final pageWidth = tester
        .getSize(find.byKey(const Key('office-doc-paper-page-0')))
        .width;
    for (final w in widths) {
      expect(w, lessThan(pageWidth), reason: '单元格不能拉满整页宽');
    }
    // 单元格里有真实文字（不是空白格子）。
    expect(find.text('Version Number'), findsOneWidget);
    expect(find.text('Document created'), findsOneWidget);
  });

  testWidgets('P4. 列表是真实标记 ●（不是把 "-" 当项目符号）', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('office-docx-list-marker')), findsNWidgets(2));
    expect(find.text('●'), findsNWidgets(2));
    expect(find.text('Record the issues without conclusions.'), findsOneWidget);
    // 正文里**没有**以 "- " 开头的列表文本（用户看到的应该是符号，不是字面短横）。
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>();
    for (final t in texts) {
      expect(t.trimLeft().startsWith('- '), isFalse, reason: '不该出现字面 "- "：$t');
    }
  });

  testWidgets('P5. 标题字号严格大于正文字号（且按 headingLevel 递增）', (tester) async {
    await _pump(tester);
    // ⚠️ 不能直接 `find.text(...)` 就 `tester.widget`：同一个文字会出现**多份**。
    //
    // 为什么（这是**真实文档结构**，不是测试怪癖）：
    // `Product spec` 的正文里有一份**文档自带**的目录（`w:sdt` 内容控件，
    // 解析层已修复不再丢弃），而目录条目写的**就是标题原文** ⇒
    // `find.text('1. Introduction')` 同时命中「目录条目」和「正文标题」。
    //
    // 这里要量的是**标题那份**，所以按**字号最大**取 —— 标题 `Heading1` 是 18pt，
    // 而目录条目/正文是 11pt。同时顺带断言"两份都在"，把这件事钉住。
    Text biggestText(String data) {
      final all = find
          .text(data)
          .evaluate()
          .map((e) => e.widget as Text)
          .toList();
      expect(all, isNotEmpty, reason: '正文里找不到文本：「$data」');
      all.sort(
        (a, b) => (b.style?.fontSize ?? 0).compareTo(a.style?.fontSize ?? 0),
      );
      return all.first;
    }

    // 目录条目 + 正文标题**都在**（文档自带目录，不再由我方合成）。
    expect(find.text('1. Introduction'), findsNWidgets(2));
    final heading1 = biggestText('1. Introduction');
    final heading2 = biggestText('3.1. Technique');
    final body = biggestText('Describe the concept of this product here.');
    final h1 = heading1.style!.fontSize!;
    final h2 = heading2.style!.fontSize!;
    final b = body.style!.fontSize!;
    expect(h1, greaterThan(b));
    expect(h2, greaterThan(b));
    // pt → px：18pt=24px、15pt=20px、11pt≈14.67px
    expect(h1, closeTo(18 * 96 / 72, 0.01));
    expect(h2, closeTo(15 * 96 / 72, 0.01));
    expect(h1, greaterThan(h2));
    expect(body.style!.color, isNotNull);
    // 标题的粗体/颜色按 `w:rPr` 生效。
    expect(heading1.style!.fontFamily, 'Arial');
  });

  testWidgets('P6. 富文本与图片：加粗/颜色生效，图片按 wp:extent 出图', (tester) async {
    await _pump(tester);
    final brand = tester.widget<Text>(find.text('YOUR COMPANY'));
    expect(brand.style!.color, const Color(0xFF4176CC));
    expect(brand.style!.fontFamily, 'Trebuchet MS');
    final bold = tester.widget<Text>(find.text('Product Name'));
    expect(bold.style!.fontWeight, FontWeight.w700);
    // 段内图片：真 PNG 字节来自 DOCX 包内 word/media/。
    expect(find.byKey(const Key('office-docx-image')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('P7. 页码指示 + 多页纸面（不是一整条长列表）', (tester) async {
    await _pump(tester);
    final indicator = find.descendant(
      of: find.byKey(const Key('office-doc-page-indicator')),
      matching: find.byType(Text),
    );
    expect(indicator, findsOneWidget);
    expect(tester.widget<Text>(indicator).data, '1 / 2');
    expect(find.byKey(const Key('office-doc-paper-page-1')), findsOneWidget);
  });

  testWidgets('P8. **没有任何开发者横幅**（用户不该读到内部话术）', (tester) async {
    await _pump(tester);
    for (final banned in <String>[
      '从简',
      '本批',
      '只读渲染',
      '只读预览',
      '不支持编辑',
      '未取证',
      '降级',
      'schema',
      '文档设置',
    ]) {
      expect(
        find.textContaining(banned),
        findsNothing,
        reason: '界面上不该出现「$banned」',
      );
    }
  });

  testWidgets('P9. 窄屏（手机宽）时纸面按可用宽度适配且不横向溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pump(tester);
    expect(tester.takeException(), isNull);
    // `getSize` 是**未缩放的布局尺寸**；被 FittedBox 缩放后的实际绘制宽度
    // 要用 `getRect`（它经过 `localToGlobal`）。
    final page = tester.getRect(
      find.byKey(const Key('office-doc-paper-page-0')),
    );
    expect(page.width, lessThanOrEqualTo(390.0 + 1.0));
    expect(page.width, greaterThan(300.0));
    expect(
      tester.getSize(find.byKey(const Key('office-doc-paper-page-0'))).width,
      closeTo(793.73, 0.1),
    );
    expect(find.byKey(const Key('office-doc-paper-page-0')), findsOneWidget);
  });
}
