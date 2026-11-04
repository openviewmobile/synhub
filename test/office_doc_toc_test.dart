// `.odoc` **目录**（大纲导航）的离线用例（**不发起任何 NAS 请求**）。
//
// ## 权威事实（父 agent 用官方 APK + 5 份真样本查清，本文件直接引用）
// 1. 官方 Android App **有**这个 UI：Synology Drive 3.9.0 的资源表里
//    `string/table_of_contents` = "Table of contents" / "目录" / "目錄"，
//    并有 `heading_1`..`heading_6` = "1 级标题".."6 级标题"（**只有 1..6**）。
// 2. `.odoc` 里**没有内嵌目录**：5 份真样本逐份统计 `TOC` / `instrText` /
//    `fldSimple` **全为 0**；而 `Heading1..3` **每份都有**。
//    ⇒ 官方的"目录"= 由标题层级生成的**大纲导航面板**，素材齐全、缺的只是 UI。
//
// 真样本标题数（本文件断言的就是这些，逐条**实测**）：
//   * `restaurant_menu.docx`：35 条（H1×5 / H2×15 / H3×15）—— 层级最丰富；
//   * `product_spec.docx`：7 条（H1×5 / H2×2）；
//   * `student_report.docx`：9 条。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_doc_ooxml.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_doc_ooxml_view.dart';

Uint8List _realDocx(String name) => Uint8List.fromList(
  File('test/fixtures/office_doc_redesign/$name').readAsBytesSync(),
);

ODocxDocument _doc(String name) => ODocxDocument.parse(_realDocx(name))!;

Future<void> _pump(WidgetTester tester, ODocxDocument doc) async {
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.dark(), 
      home: Scaffold(body: OfficeDocxView(doc: doc)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // =========================================================================
  // 接口层：目录条目由**标题层级**生成
  // =========================================================================
  group('TOC-1. 目录条目生成（真样本）', () {
    test('T1. `restaurant_menu.docx` → 35 条、三级层次都对', () {
      final toc = officeDocxBuildToc(_doc('restaurant_menu.docx').blocks);
      expect(toc.length, 35);
      expect(toc.where((e) => e.level == 1).length, 5);
      expect(toc.where((e) => e.level == 2).length, 15);
      expect(toc.where((e) => e.level == 3).length, 15);
      // 一级标题逐字（真样本原文）。
      expect(
        toc.where((e) => e.level == 1).map((e) => e.text).toList(),
        <String>[
          'Appetizers',
          'Salads',
          'Soup of the Day',
          'Main Courses',
          'Desserts',
        ],
      );
      // 层级是**嵌套**的：每个 H2 前面最近的那个 H1 是它的父节点。
      var lastH1 = '';
      for (final e in toc) {
        if (e.level == 1) lastH1 = e.text;
        if (e.level == 2) {
          expect(lastH1, isNotEmpty, reason: 'H2 必须挂在某个 H1 下');
        }
      }
    });

    test('T2. `product_spec.docx` → 7 条（H1×5 + H2×2），文字逐字', () {
      final toc = officeDocxBuildToc(_doc('product_spec.docx').blocks);
      expect(toc.length, 7);
      expect(toc.first.level, 1);
      expect(toc.first.text, '1. Introduction');
      expect(toc.last.text, '5. To Be Discussed');
      expect(toc.where((e) => e.level == 2).length, 2);
    });

    test('T3. 条目顺序 = 文档顺序（blockIndex 单调递增）', () {
      for (final name in <String>[
        'restaurant_menu.docx',
        'product_spec.docx',
        'student_report.docx',
      ]) {
        final toc = officeDocxBuildToc(_doc(name).blocks);
        for (var i = 1; i < toc.length; i++) {
          expect(
            toc[i].blockIndex,
            greaterThan(toc[i - 1].blockIndex),
            reason: '$name 的目录必须按文档顺序',
          );
        }
      }
    });

    test('T4. 层级只收 **1..6**（官方只有 1..6 级，没有 7/8）', () {
      for (final name in <String>[
        'restaurant_menu.docx',
        'product_spec.docx',
        'student_report.docx',
      ]) {
        for (final e in officeDocxBuildToc(_doc(name).blocks)) {
          expect(e.level, inInclusiveRange(1, 6));
        }
      }
    });

    test('T5. 无标题的块集合 → 空目录（入口不会出现）', () {
      // 只有 3 份 `.docx` 夹具（另外 2 份官方样本只有原生 JSON 快照，
      // 没有 DOCX 字节）⇒ 这里用"从真样本里筛掉标题块"的方式构造无标题文档。
      final doc = _doc('restaurant_menu.docx');
      expect(officeDocxBuildToc(const <OOXMLBlock>[]), isEmpty);
      final noHeading = doc.blocks
          .where((b) => b.paragraph != null && b.paragraph!.headingLevel == 0)
          .toList();
      expect(noHeading, isNotEmpty, reason: '真样本里确实有非标题段落');
      expect(officeDocxBuildToc(noHeading), isEmpty);
    });
  });

  // =========================================================================
  // 界面层：入口 / 面板 / 分级缩进 / 点击定位
  // =========================================================================
  group('TOC-2. 目录入口与面板', () {
    testWidgets('T6. 文档**真有**目录 → 出现「目录」入口；文案是官方原文（回落中文）', (tester) async {
      // ⚠️ 这里必须用**真有目录**的样本（`product_spec`）：
      //    `restaurant_menu` 有 35 个标题但**文档里没有任何目录**，
      //    按用户要求"没有目录的 odoc 不要强行加上目录"，它**不该**出现入口。
      await _pump(tester, _doc('product_spec.docx'));
      final button = find.byKey(const Key('office-doc-toc-button'));
      expect(button, findsOneWidget);
      // 没装翻译器时回落中文原文（`dataText` 的既有约定）。
      expect(
        find.descendant(of: button, matching: find.text('目录')),
        findsOneWidget,
      );
    });

    testWidgets('T7. 没有标题的文档 → **不显示**入口（不给空面板）', (tester) async {
      final doc = _doc('restaurant_menu.docx');
      // 只保留没有标题的块，重建成一份"无标题文档"。
      final noHeading = ODocxDocument(
        blocks: doc.blocks
            .where((b) => b.paragraph == null || b.paragraph!.headingLevel == 0)
            .toList(),
        pageSetup: doc.pageSetup,
        headers: doc.headers,
        footers: doc.footers,
        media: doc.media,
        styles: doc.styles,
        numbering: doc.numbering,
        theme: doc.theme,
      );
      expect(officeDocxBuildToc(noHeading.blocks), isEmpty);
      await _pump(tester, noHeading);
      expect(find.byKey(const Key('office-doc-toc-button')), findsNothing);
      // 正文仍然正常渲染（入口消失不该影响文档本身）。
      expect(find.byKey(const Key('office-doc-paper-page-0')), findsOneWidget);
    });

    testWidgets('T8. 点开目录 → 列出 7 条，且**按层级缩进**、层级数字可见', (tester) async {
      await _pump(tester, _doc('product_spec.docx'));
      await tester.tap(find.byKey(const Key('office-doc-toc-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('office-doc-toc-panel')), findsOneWidget);
      // 面板标题同样是官方原文。
      expect(find.byKey(const Key('office-doc-toc-title')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('office-doc-toc-title'))).data,
        '目录',
      );
      // 列表是懒加载的（ListView.builder），首屏能看到的条目必须字号/缩进都对。
      final item0 = find.byKey(const Key('office-doc-toc-item-0'));
      expect(item0, findsOneWidget);
      expect(
        find.descendant(of: item0, matching: find.text('1. Introduction')),
        findsOneWidget,
      );
      // 1 级条目的层级数字是 `1`。
      expect(
        tester
            .widget<Text>(find.byKey(const Key('office-doc-toc-level-0')))
            .data,
        '1',
      );

      // **缩进真的分级**：1 级与 2 级条目左边界不同，且 3 级比 2 级更右。
      double leftOf(int i) => tester
          .getTopLeft(
            find.descendant(
              of: find.byKey(Key('office-doc-toc-item-$i')),
              matching: find.byType(Row),
            ),
          )
          .dx;
      // `product_spec` 的层级是 [1,1,1,2,2,1,1] ⇒ 索引 0 是 1 级、索引 3 是 2 级。
      expect(
        leftOf(3) - leftOf(0),
        closeTo(16.0, 0.5),
        reason: '2 级比 1 级多缩进 16px',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('office-doc-toc-level-3')))
            .data,
        '2',
      );
    });

    testWidgets('T9. 点击某条 → 面板关闭 + 页面**真的滚到**该标题', (tester) async {
      final doc = _doc('product_spec.docx');
      await _pump(tester, doc);
      final scroll = find.byKey(const Key('office-doc-paper-scroll'));
      double offset() =>
          tester.widget<SingleChildScrollView>(scroll).controller!.offset;
      expect(offset(), closeTo(0.0, 0.01), reason: '起始在顶部');

      await tester.tap(find.byKey(const Key('office-doc-toc-button')));
      await tester.pumpAndSettle();

      // 找一个**在后面**的一级标题（`5. To Be Discussed`，文档最后一段 H1）。
      final entries = officeDocxBuildToc(doc.blocks);
      final targetIndex = entries.indexWhere(
        (e) => e.text == '5. To Be Discussed',
      );
      expect(targetIndex, greaterThan(0));

      // 面板是懒加载列表：先把目标滚到可见处再点。
      await tester.scrollUntilVisible(
        find.byKey(Key('office-doc-toc-item-$targetIndex')),
        120,
        scrollable: find.descendant(
          of: find.byKey(const Key('office-doc-toc-panel')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(Key('office-doc-toc-item-$targetIndex')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('office-doc-toc-panel')), findsNothing);
      expect(offset(), greaterThan(50.0), reason: '点击目录条目必须把正文滚下去（不是只关面板）');
    });

    testWidgets('T10. 面板是**只读**的：没有任何输入控件 / 编辑动作', (tester) async {
      await _pump(tester, _doc('product_spec.docx'));
      await tester.tap(find.byKey(const Key('office-doc-toc-button')));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      // 条目本身是 `InkWell`（点击 = 定位），不是开关/复选。
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('T11. `product_spec.docx`（7 条）面板能开、条数对', (tester) async {
      await _pump(tester, _doc('product_spec.docx'));
      await tester.tap(find.byKey(const Key('office-doc-toc-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-toc-panel')), findsOneWidget);
      // 条目文字与正文里的同名标题都会命中 ⇒ 限定在面板里找。
      final panel = find.byKey(const Key('office-doc-toc-panel'));
      expect(
        find.descendant(of: panel, matching: find.text('1. Introduction')),
        findsOneWidget,
      );
      // 懒加载：先滚到底，最后一条也要能看到。
      await tester.scrollUntilVisible(
        find.byKey(const Key('office-doc-toc-item-6')),
        120,
        scrollable: find.descendant(
          of: panel,
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.descendant(of: panel, matching: find.text('5. To Be Discussed')),
        findsOneWidget,
      );
    });
    testWidgets('T12. **深色主题**下条目文字仍然看得见（外壳配色，不是文档色）', (tester) async {
      final doc = _doc('product_spec.docx');
      final dark = ThemeData.dark();
      await tester.pumpWidget(
        MaterialApp(
          theme: dark,
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('office-doc-toc-button')));
      await tester.pumpAndSettle();

      final panel = find.byKey(const Key('office-doc-toc-panel'));
      final label = find.descendant(
        of: panel,
        matching: find.text('2. Summary'),
      );
      expect(label, findsOneWidget, reason: '条目文字必须真的在面板里');

      final style = tester.widget<Text>(label).style!;
      // 面板是 **App 外壳**：跟面板主题的 `onSurface` 走。
      expect(style.color, dark.colorScheme.onSurface);
      // 反例守卫：绝不是文档缺省色（第一版就是这样在深色下隐形了）。
      expect(
        style.color,
        isNot(const Color(0xFF202124)),
        reason: '面板文字不许用文档缺省色（真机踩过：深底 + 深字 = 看不见）',
      );
      // 亮度差要够（不是"几乎同色"）。
      final sheetBg = dark.colorScheme.surfaceContainerLow;
      final diff =
          (style.color!.computeLuminance() - sheetBg.computeLuminance()).abs();
      expect(diff, greaterThan(0.3), reason: '与面板底色必须有可读的亮度差');
    });

    testWidgets('T13. 浅色主题下同样是 onSurface（两侧都不许写死颜色）', (tester) async {
      final doc = _doc('student_report.docx');
      final light = ThemeData.light();
      await tester.pumpWidget(
        MaterialApp(
          theme: light,
          home: Scaffold(body: OfficeDocxView(doc: doc)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('office-doc-toc-button')));
      await tester.pumpAndSettle();
      final panel = find.byKey(const Key('office-doc-toc-panel'));
      final label = find.descendant(
        of: panel,
        matching: find.text('Introduction'),
      );
      expect(label, findsOneWidget);
      expect(
        tester.widget<Text>(label).style!.color,
        light.colorScheme.onSurface,
      );
    });
  });

  // ===========================================================================
  // TOC-5. **正文里的那份目录**（与浮动面板**并存**，不是二选一）
  //
  // 用户明确要求：「odoc 的目录你可以用浮层实现，但是主区内容也需要显示一份，
  // 不应该去掉」。此前只有浮层，正文里什么都没有。
  //
  // 事实依据：官方 Android 版正文里就有目录（原生 `.odoc` 容器带 TOC），而 Drive
  // 转码出来的 DOCX 把 TOC 域**整个丢了**（5 份真实样本 `TOC`/`instrText`/
  // `fldSimple`/`fldChar` 计数全为 0）⇒ 正文这份必须由**标题层级重建**，
  // 与浮层共用同一份 `officeDocxBuildToc()` 条目（同一个 `blockIndex`）。
  // ===========================================================================
  // =========================================================================
  // ★★ 核心：目录 UI **只在文档真的有目录时**才出现
  //
  // 用户原话："没有目录的 odoc 不要强行加上目录，要根据文档是否真的有目录来"。
  //
  // 旧实现**无条件按标题层级合成**目录 ⇒ 只要文档有标题就加目录：
  //   * `Restaurant menu`：35 个标题（H1×5 + H2×15 + H3×15），
  //     **文档里没有任何目录** —— 却被强行加了目录；
  //   * `5-day trip planner`：round 18 真机打开的那份，
  //     原生模型里 `Table of Contents` = **0** —— 同样被强行加了目录。
  //
  // 现在判定走 [officeDocxHasRealToc]（见 `office_doc_ooxml_view.dart`），
  // 并且**正文里那份目录由文档自己提供** —— 解析层已修复块级 `w:sdt` 被丢弃的
  // bug（`Product spec` 27→34 块、`Student report` 35→44 块），
  // 所以不再合成第二份（同屏两份目录反而更差）。
  // =========================================================================
  group('TOC-5. 目录 UI 只在文档**真的有**目录时出现', () {
    testWidgets(
      'T20. ★ 用户报的 bug：`restaurant_menu`（35 个标题但**文档里没有目录**）⇒ 完全不给目录 UI',
      (tester) async {
        final doc = _doc('restaurant_menu.docx');
        // 前提：它有 35 个标题（合成的导航条目很多）……
        expect(officeDocxBuildToc(doc.blocks).length, 35);
        // ……但**文档里没有目录** ⇒ 不许给任何目录 UI。
        expect(
          officeDocxHasRealToc(
            doc.blocks,
            hasTocContentControl: doc.hasTocContentControl,
          ),
          isFalse,
          reason: 'restaurant_menu 的 body 是 43 个 w:p，一个 w:sdt 都没有',
        );
        expect(doc.hasTocContentControl, isFalse);

        await _pump(tester, doc);
        expect(
          find.byKey(const Key('office-doc-toc-button')),
          findsNothing,
          reason: '没有目录就不许有目录入口',
        );
        expect(find.byKey(const Key('office-doc-toc-panel')), findsNothing);
        // 正文照常渲染（入口消失不影响文档本身）。
        expect(
          find.byKey(const Key('office-doc-paper-page-0')),
          findsOneWidget,
        );
        expect(find.text('Appetizers'), findsWidgets);
      },
    );

    testWidgets('T21. ★ `5-day trip planner`（round 18 真机那份）的原生模型里也**没有**目录', (
      tester,
    ) async {
      // 直接读原生 `.odoc` 模型导出（`*_snapshot.json`）——
      // 这是"文档是否真的有目录"在**原生通道**上的证据。
      Map<String, Object?> snap(String n) =>
          (jsonDecode(
                    File(
                      'test/fixtures/office_doc_redesign/${n}_snapshot.json',
                    ).readAsStringSync(),
                  )
                  as Map)
              .cast<String, Object?>();

      bool hasTocTitle(String n) =>
          jsonEncode(snap(n)).contains('Table of Contents');

      // 真有目录的两份：
      expect(hasTocTitle('product_spec'), isTrue);
      expect(hasTocTitle('student_report'), isTrue);
      // 没有目录的三份（**含用户 round 18 打开的那份**）：
      expect(
        hasTocTitle('five_day_trip_planner'),
        isFalse,
        reason: '这就是用户看到"被强行加目录"的那份文档',
      );
      expect(hasTocTitle('restaurant_menu'), isFalse);
      expect(hasTocTitle('vacation_packing_list'), isFalse);
    });

    testWidgets('T22. `product_spec`（真有目录）⇒ 入口出现，且**正文里有文档自带的目录条目**', (
      tester,
    ) async {
      final doc = _doc('product_spec.docx');
      expect(doc.hasTocContentControl, isTrue, reason: 'SDT docPartGallery 判据');
      // 解析层修复前是 27 块（`w:sdt` 被丢），修复后 +7 条真目录。
      expect(doc.blocks.length, 34);

      await _pump(tester, doc);
      expect(
        find.byKey(const Key('office-doc-toc-button')),
        findsOneWidget,
        reason: '真有目录 ⇒ 浮层导航入口要有',
      );
      // ★ 正文里那份来自**文档自己**：标题 + 7 条条目都渲染出来了。
      expect(find.text('Table of Contents'), findsWidgets);
      for (final t in <String>[
        '1. Introduction',
        '2. Summary',
        '3. Specifications',
        '3.1. Technique',
        '3.2. Design',
        '4. Limitations',
        '5. To Be Discussed',
      ]) {
        expect(find.text(t), findsWidgets, reason: '文档自带目录条目「$t」必须渲染在正文里');
      }
      // 不再合成第二份（否则同屏两份目录）。
      expect(find.byKey(const Key('office-doc-inline-toc')), findsNothing);
    });

    testWidgets('T23. `student_report`（真有目录、9 条）⇒ 入口出现且条数对', (tester) async {
      final doc = _doc('student_report.docx');
      expect(doc.hasTocContentControl, isTrue);
      expect(doc.blocks.length, 44); // 35 → 44（+9 条真目录）
      await _pump(tester, doc);
      await tester.tap(find.byKey(const Key('office-doc-toc-button')));
      await tester.pumpAndSettle();
      final panel = find.byKey(const Key('office-doc-toc-panel'));
      expect(panel, findsOneWidget);
      expect(
        find.descendant(of: panel, matching: find.text('Introduction')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('office-doc-toc-item-8')),
        120,
        scrollable: find.descendant(
          of: panel,
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.descendant(of: panel, matching: find.text('Acknowledgements')),
        findsOneWidget,
      );
    });

    testWidgets('T24. 点浮层条目 → 面板关闭 + 页面**真的滚到**该标题', (tester) async {
      final doc = _doc('student_report.docx');
      await _pump(tester, doc);
      final scroll = find.byKey(const Key('office-doc-paper-scroll'));
      double offset() =>
          tester.widget<SingleChildScrollView>(scroll).controller!.offset;
      expect(offset(), closeTo(0.0, 0.01));

      await tester.tap(find.byKey(const Key('office-doc-toc-button')));
      await tester.pumpAndSettle();
      final entries = officeDocxBuildToc(doc.blocks);
      final target = entries.indexWhere((e) => e.text == 'Acknowledgements');
      expect(target, greaterThan(0));
      await tester.scrollUntilVisible(
        find.byKey(Key('office-doc-toc-item-$target')),
        120,
        scrollable: find.descendant(
          of: find.byKey(const Key('office-doc-toc-panel')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(Key('office-doc-toc-item-$target')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-toc-panel')), findsNothing);
      expect(offset(), greaterThan(50.0), reason: '点目录必须真的滚动（不是只关面板）');
    });
  });
}
