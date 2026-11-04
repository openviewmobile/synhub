// DA289 —— **纸边吃宽度**导致 `.odoc` 表格行溢出（r667 · Linux 站真渲染抓到）。
//
// 真机读数（`/work` 容器 + Xvfb，`integration_test/linux_walkthrough_test.dart`）：
//   A RenderFlex overflowed by 0.267 pixels on the right.
//   The relevant error-causing widget was:
//     Row-[<'office-docx-t4-table-row-0'>]  (office_doc_ooxml_view.dart)
//   constraints: BoxConstraints(0.0<=w<=600.7, h=134.0)   ← 实际拿到 600.7333
//   打开的是 `5-day trip planner.odoc`（真 NAS /home/Drive），同屏 5 次异常。
//
// 根因（算式对得上到小数点后一位）：
//   A4 纸 `793.7333`（11906 twips / 15），左右边距各 `96` ⇒
//   `metrics.contentWidth = 601.7333`；
//   而 `OfficeDocPaperPage` 的 `Container.decoration.border`（左右各 `0.5`）
//   **会把子级可用宽度吃掉 1.0** ⇒ 正文实际只有 `600.7333`。
//   `_table` 按 `contentWidth`（601.7333）缩放列宽 ⇒ 每行溢 1.0 px；
//   `FittedBox` 缩放 0.5333 后报出来的就是 **0.267**。
//
// 两处修：
//   ① `office_doc_paper.dart`：纸边改画在 `foregroundDecoration`（像素一致、不参与布局）；
//   ② `office_doc_ooxml_view.dart`：列宽缩放基准改成 `LayoutBuilder` 拿到的**真实约束**。
//
// 本用例是**反向验证**：把 ① 改回 `decoration.border`、并把 ② 改回按 `contentWidth`
// 缩放，下面第一条会真的红（`takeException()` 拿到 RenderFlex overflow）。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_doc_ooxml.dart';
import 'package:synhub/src/features/office/office_doc_ooxml_view.dart';
import 'package:synhub/src/features/office/office_doc_paper.dart';

/// 一张表：两列，声明总宽**正好等于** `metrics.contentWidth`（601.7333）。
///
/// 故意取"正好等于"而不是"比正文宽"：比正文宽时 `_table` 会缩放，掩盖问题；
/// 正好相等时它按声明宽度原样铺开 —— 只要正文实际可用宽度少了一点点（纸边），
/// 就必然溢出。真实文档（`5-day trip planner.odoc`）就是这种"按正文宽排满"的表。
ODocxDocument _docFilledTable() {
  final setup = OOXMLPageSetup.a4Default;
  final metrics = OfficeDocPaperMetrics(
    pageWidth: setup.widthPx,
    pageHeight: setup.heightPx,
    marginLeft: setup.marginLeftPx,
    marginRight: setup.marginRightPx,
    marginTop: setup.marginTopPx,
    marginBottom: setup.marginBottomPx,
    pageType: 'a4',
    orientation: setup.orientation,
  );
  final half = metrics.contentWidth / 2;
  return ODocxDocument(
    blocks: <OOXMLBlock>[
      OOXMLBlock.table(
        OOXMLTable(
          colWidthsPx: <double>[half, half],
          rows: <OOXMLRow>[
            OOXMLRow(
              cells: <OOXMLCell>[
                OOXMLCell(
                  blocks: <OOXMLBlock>[
                    OOXMLBlock.paragraph(OOXMLParagraph(runs: <OOXMLRun>[
                      OOXMLRun(text: 'LEFT CELL'),
                    ])),
                  ],
                ),
                OOXMLCell(
                  blocks: <OOXMLBlock>[
                    OOXMLBlock.paragraph(OOXMLParagraph(runs: <OOXMLRun>[
                      OOXMLRun(text: 'RIGHT CELL'),
                    ])),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    ],
    pageSetup: setup,
    headers: const <String, String>{},
    footers: const <String, String>{},
    media: const <String, Uint8List>{},
    styles: const OOXMLStyleSheet(),
    numbering: const <int, Map<int, OOXMLNumberLevel>>{},
  );
}

Future<void> _pump(WidgetTester tester, ODocxDocument doc) async {
  // 视口给窄一点，让纸面走 `FittedBox` 缩放（真机 Linux 2560x1440 也是这样）。
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: OfficeDocxView(doc: doc)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('DA289. 按正文宽排满的表格行不许溢出（纸边不吃宽度）', (tester) async {
    await _pump(tester, _docFilledTable());

    // ① 关键断言：渲染期**不许有异常**（修复前是
    //    `A RenderFlex overflowed by ... pixels on the right`）。
    expect(
      tester.takeException(),
      isNull,
      reason: '纸边吃掉 1px ⇒ 表格行溢出（DA289）',
    );

    // ② 表格真的画出来了（不是"没渲染所以没异常"）。
    expect(find.byKey(const Key('office-docx-table')), findsOneWidget);
    expect(find.byKey(const Key('office-docx-table-row-0')), findsOneWidget);
    expect(find.text('LEFT CELL'), findsOneWidget);
    expect(find.text('RIGHT CELL'), findsOneWidget);

    // ③ 行宽必须**不超过**父级给的约束（数值判据，不依赖异常）。
    final row =
        tester.renderObject<RenderBox>(find.byKey(const Key('office-docx-table-row-0')));
    final paper = tester.renderObject<RenderBox>(
      find.byKey(const Key('office-doc-paper-page-0')),
    );
    expect(
      row.size.width,
      lessThanOrEqualTo(paper.size.width + 0.001),
      reason: '行宽 ${row.size.width} 不许超过纸面宽 ${paper.size.width}',
    );
  });

  testWidgets('DA289 之二. 纸面：正文可用宽 == metrics.contentWidth（纸边不参与布局）',
      (tester) async {
    await _pump(tester, _docFilledTable());
    expect(tester.takeException(), isNull);

    final metrics = OfficeDocPaperMetrics(
      pageWidth: OOXMLPageSetup.a4Default.widthPx,
      pageHeight: OOXMLPageSetup.a4Default.heightPx,
      marginLeft: OOXMLPageSetup.a4Default.marginLeftPx,
      marginRight: OOXMLPageSetup.a4Default.marginRightPx,
      marginTop: OOXMLPageSetup.a4Default.marginTopPx,
      marginBottom: OOXMLPageSetup.a4Default.marginBottomPx,
      pageType: 'a4',
      orientation: 'portrait',
    );
    final row =
        tester.renderObject<RenderBox>(find.byKey(const Key('office-docx-table-row-0')));
    // 两列各半、原样铺开 ⇒ 行宽就是正文宽（不再被纸边啃掉 1px）。
    expect(row.size.width, closeTo(metrics.contentWidth, 0.01));
  });
}
