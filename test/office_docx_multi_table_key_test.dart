// r132 D6 —— **一份 `.odoc` 里有两张表**时的重键缺陷（真机像素抓到的 P1）。
//
// 现象（iOS 模拟器像素 `/private/tmp/r132_ios_ui_pass7/007_s090_office_odoc.png`）：
//   打开 `5-day trip planner.odoc`（`Fit width`、`1 / 2` 都在），正文却是 Flutter 的
//   红色错误屏：
//     Duplicate keys found.
//     Column(direction: vertical, ...) has multiple children with key
//     [<'office-docx-table'>].
//   根因：`_table()` 把**常量** key `Key('office-docx-table')`（行/单元格同理）挂在
//   每一张表上 ⇒ 同一 `Column` 里两张表 = 兄弟重键 ⇒ 整篇正文被错误屏替换。
//
// 本用例是**反向验证**：把 `_table` 的 key 改回常量（去掉 `-t<n>` 后缀）时，
// 这条会真的红（`takeException()` 拿到 `Duplicate keys found`）；
// 带后缀时张数再多也只有**唯一** key，正文正常渲染。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_doc_ooxml.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_doc_ooxml_view.dart';

Uint8List _bytes() => Uint8List.fromList(
  File('test/fixtures/office_doc_redesign/product_spec.docx')
      .readAsBytesSync(),
);

ODocxDocument _real() => ODocxDocument.parse(_bytes())!;

/// 手搓一份**两张小表**的文档：两行文字都不长 ⇒ 两张表都在**第一页**
/// （`.odoc` 是分页 + 懒加载，把表塞到第二页会让 `find` 找不到 Widget，
///  那样测的就不是"重键"而是"分页"）。
ODocxDocument _twoTables() {
  OOXMLBlock tableBlock(String marker) => OOXMLBlock.table(
        OOXMLTable(
          colWidthsPx: const <double>[300],
          rows: <OOXMLRow>[
            OOXMLRow(
              cells: <OOXMLCell>[
                OOXMLCell(blocks: <OOXMLBlock>[
                  OOXMLBlock.paragraph(OOXMLParagraph(runs: <OOXMLRun>[
                    OOXMLRun(text: marker),
                  ])),
                ]),
              ],
            ),
          ],
        ),
      );
  return ODocxDocument(
    blocks: <OOXMLBlock>[tableBlock('FIRST TABLE MARKER'), tableBlock('SECOND TABLE MARKER')],
    pageSetup: OOXMLPageSetup.a4Default,
    headers: const <String, String>{},
    footers: const <String, String>{},
    media: const <String, Uint8List>{},
    styles: const OOXMLStyleSheet(),
    numbering: const <int, Map<int, OOXMLNumberLevel>>{},
  );
}

Future<void> _pump(WidgetTester tester, ODocxDocument doc) async {
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: OfficeDocxView(doc: doc))),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('D6. 两张表不重键：没有 DuplicateKeys 断言，两张表都真渲染', (tester) async {
    await _pump(tester, _twoTables());

    // ① 关键断言：**不许有异常**。修复前这里是
    //    `Duplicate keys found. ... key [<'office-docx-table'>]`（红屏）。
    expect(
      tester.takeException(),
      isNull,
      reason: '两张表重键会抛 Duplicate keys found，整篇正文变错误屏',
    );

    // ② 第一张表沿用历史 key（既有用例/外部断言依赖，不许改），第二张带 `-t1`。
    expect(find.byKey(const Key('office-docx-table')), findsOneWidget);
    // 第 2 张表带 `-t1` 前缀（行/单元格用同一前缀，见 `_table` 的 `childPrefix`）。
    expect(find.byKey(const Key('office-docx-t1-table')), findsOneWidget);

    // ③ 两张表的后代 key 也要唯一（行/单元格原来同样是常量）。
    expect(find.byKey(const Key('office-docx-table-row-0')), findsOneWidget);
    expect(
      find.byKey(const Key('office-docx-t1-table-row-0')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('office-docx-cell-0-0')), findsOneWidget);
    expect(find.byKey(const Key('office-docx-t1-cell-0-0')), findsOneWidget);

    // ④ 内容真的在（不是"只有壳"）。
    expect(find.text('FIRST TABLE MARKER'), findsOneWidget);
    expect(find.text('SECOND TABLE MARKER'), findsOneWidget);
  });

  testWidgets('D6b. 反过来：单张表的 key 与修复前**逐字一致**（不破坏既有断言）',
      (tester) async {
    await _pump(tester, _real());
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('office-docx-table')), findsOneWidget);
    expect(find.byKey(const Key('office-docx-table-row-0')), findsOneWidget);
    expect(find.byKey(const Key('office-docx-cell-0-0')), findsOneWidget);
    // 没有 `-t1` 这种后缀混进来。
    expect(find.byKey(const Key('office-docx-t1-table')), findsNothing);
  });
}
