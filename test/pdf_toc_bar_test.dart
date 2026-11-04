// PDF 底部目录条（`PdfTocBar`）的行为与**真实解析结果**的接线。
//
// 两件事分开测：
//   1. `parsePdfToc` 能从我手搓的 PDF 字节里取出书签（解析器细节由
//      `test/pdf_doc_toc_test.dart` 覆盖，这里只需要"真字节 → 真目录"这一跳）；
//   2. UI：目录按钮在**底部正中**、没有目录时不可点、面板按层级缩进并带页码、
//      点条目回调给出 1 基页码。
//
// 不实例化 `_PdfxView`：那会拖进 `pdfx` 的平台通道（单测里没有实现）。
// 目录条与渲染解耦正是为了这个。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/files/file_pdf_view.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/pdf_doc.dart';

/// 手搓一份带目录的**经典 xref** PDF：3 页，书签 = 第一章(p1) / 第二章(p2) /
/// 2.1 小节(p2，嵌套)。
Uint8List classicOutlinePdf() {
  final out = BytesBuilder();
  final offsets = <int, int>{};
  void obj(int n, String body) {
    offsets[n] = out.length;
    out.add('$n 0 obj\n$body\nendobj\n'.codeUnits);
  }

  out.add('%PDF-1.7\n%\xe2\xe3\xcf\xd3\n'.codeUnits);
  obj(1, '<< /Type /Catalog /Pages 2 0 R /Outlines 8 0 R >>');
  obj(2, '<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>');
  for (final n in [3, 4, 5]) {
    obj(n, '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>');
  }
  obj(6, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  obj(7, '<< /Title (unused) >>');
  obj(8, '<< /Type /Outlines /First 9 0 R /Last 11 0 R /Count 3 >>');
  obj(
    9,
    '<< /Title (Chapter One) /Parent 8 0 R /Next 10 0 R '
    '/Dest [3 0 R /XYZ 0 200 0] >>',
  );
  obj(
    10,
    '<< /Title (Chapter Two) /Parent 8 0 R /Prev 9 0 R /Next 11 0 R '
    '/First 12 0 R /Last 12 0 R /Count 1 /Dest [4 0 R /Fit] >>',
  );
  obj(
    11,
    '<< /Title (Chapter Three) /Parent 8 0 R /Prev 10 0 R /Dest [5 0 R /Fit] >>',
  );
  obj(12, '<< /Title (Section 2.1) /Parent 10 0 R /Dest [4 0 R /Fit] >>');

  final xref = out.length;
  out.add('xref\n0 13\n0000000000 65535 f \n'.codeUnits);
  for (var n = 1; n <= 12; n++) {
    out.add('${offsets[n]!.toString().padLeft(10, '0')} 00000 n \n'.codeUnits);
  }
  out.add(
    'trailer\n<< /Size 13 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n'.codeUnits,
  );
  return out.toBytes();
}

Future<void> pumpBar(
  WidgetTester tester, {
  required List<PdfTocEntry> toc,
  int page = 2,
  int pageCount = 3,
  ValueChanged<int>? onJump,
}) async {
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.dark(), 
      home: Scaffold(
        body: Column(
          children: [
            const Spacer(),
            PdfTocBar(
              page: page,
              pageCount: pageCount,
              toc: toc,
              onJump: onJump ?? (_) {},
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('真字节 → 真目录：层级与 0 基页码都对', () {
    final toc = parsePdfToc(classicOutlinePdf());
    expect(toc.map((e) => e.title).toList(), [
      'Chapter One',
      'Chapter Two',
      'Section 2.1',
      'Chapter Three',
    ]);
    expect(toc.map((e) => e.depth).toList(), [0, 0, 1, 0]);
    expect(toc.map((e) => e.pageIndex).toList(), [0, 1, 1, 2]);
  });

  group('PdfTocBar', () {
    testWidgets('页码、上一页/下一页按边界启用；目录在三个按钮的正中', (tester) async {
      final jumped = <int>[];
      await pumpBar(
        tester,
        toc: parsePdfToc(classicOutlinePdf()),
        page: 2,
        pageCount: 3,
        onJump: jumped.add,
      );

      // 中键显示"当前看到哪一节"（第 2 页落在 Section 2.1 上）——
      // 页码只在没有目录/没被目录覆盖时才顶上
      expect(find.text('Section 2.1'), findsOneWidget);
      expect(find.text('第 2 / 3 页'), findsNothing);
      // 目录按钮在正中（x 方向夹在上一页/下一页之间），且是唯一的主按钮
      final tocBtn = find.byTooltip('目录');
      final prev = find.text('上一页');
      final next = find.text('下一页');
      expect(tocBtn, findsOneWidget);
      final tocX = tester.getCenter(tocBtn).dx;
      expect(tocX, greaterThan(tester.getCenter(prev).dx));
      expect(tocX, lessThan(tester.getCenter(next).dx));
      expect(find.byType(FilledButton), findsOneWidget);
      // 两侧按钮贴各自的边（Expanded 里内容默认居中，会看起来"挤到中间"）
      final bar = tester.getRect(find.byType(PdfTocBar));
      expect(tester.getCenter(prev).dx - bar.left, lessThan(100));
      expect(bar.right - tester.getCenter(next).dx, lessThan(100));

      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(jumped, [3]);

      await tester.tap(find.text('上一页'));
      await tester.pumpAndSettle();
      expect(jumped, [3, 1]);
    });

    testWidgets('没有目录：不是按钮，只给只读页码（不假装能开）', (tester) async {
      // ★ 第 234 轮 `DA178`：原来是"disabled 按钮"（`onPressed == null`），
      //   真机亮色量到页码文字只有 2.28:1、还带一块残缺禁用底。
      //   现在**根本不是按钮**：显示只读页码标签，既读得清，也不假装能点。
      await pumpBar(tester, toc: const [], page: 1, pageCount: 3);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byKey(const Key('pdf-page-indicator')), findsOneWidget);
      expect(find.text('第 1 / 3 页'), findsOneWidget);
      // 首页时"上一页"也是灰的
      final prev = tester.widget<TextButton>(
        find.ancestor(of: find.text('上一页'), matching: find.byType(TextButton)),
      );
      expect(prev.onPressed, isNull);
    });

    testWidgets('打开目录面板：层级缩进、页码、点条目回调 1 基页码', (tester) async {
      final jumped = <int>[];
      await pumpBar(
        tester,
        toc: parsePdfToc(classicOutlinePdf()),
        page: 2,
        pageCount: 3,
        onJump: jumped.add,
      );
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();

      expect(find.text('4 条 · 书签'), findsOneWidget);
      // 与 EPUB 目录面板同一套骨架：筛选框 + 列表
      expect(find.byKey(const Key('book-toc-filter')), findsOneWidget);
      expect(find.byKey(const Key('book-toc-list')), findsOneWidget);
      final list = find.byKey(const Key('book-toc-list'));
      expect(
        find.descendant(of: list, matching: find.text('Chapter One')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: list, matching: find.text('Section 2.1')),
        findsOneWidget,
      );
      expect(find.text('第 1 页'), findsOneWidget);
      // 第 2 页被两条书签覆盖（Chapter Two 和它的子节）→ 两条都算"当前位置"
      expect(find.byIcon(Icons.my_location), findsNWidgets(2));
      // 嵌套条目比顶层缩进更多
      final top = tester
          .getTopLeft(
            find.descendant(of: list, matching: find.text('Chapter Two')),
          )
          .dx;
      final nested = tester
          .getTopLeft(
            find.descendant(of: list, matching: find.text('Section 2.1')),
          )
          .dx;
      expect(nested, greaterThan(top));

      await tester.tap(
        find.descendant(of: list, matching: find.text('Chapter Three')),
      );
      await tester.pumpAndSettle();
      expect(jumped, [3]); // 0 基 2 → 第 3 页
      expect(find.text('4 条 · 书签'), findsNothing); // 面板已关
    });

    testWidgets('定位不到页的条目：灰显、点击无效果', (tester) async {
      final jumped = <int>[];
      await pumpBar(
        tester,
        toc: const [
          PdfTocEntry(title: '有页', depth: 0, pageIndex: 0),
          PdfTocEntry(title: '没页', depth: 0),
        ],
        page: 1,
        pageCount: 3,
        onJump: jumped.add,
      );
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.text('—'), findsOneWidget);

      await tester.tap(find.text('没页'));
      await tester.pumpAndSettle();
      expect(jumped, isEmpty);
    });
  });
}
