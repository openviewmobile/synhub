// EPUB / PDF 共用的目录面板（`showBookTocSheet`）。
//
// 用户要求"PDF 目录的界面风格和 EPUB 用同一套"，所以这里就按"同一套"来钉：
// 两个来源的目录丢进同一个面板，标题行、计数文案、筛选、层级缩进、当前项高亮、
// 空态、点选回调的行为必须一致（只有来源说明和页码列不同）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/book_toc_sheet.dart';

Future<void> pumpSheet(
  WidgetTester tester, {
  required List<TocEntry> entries,
  String? sourceLabel,
  String fallbackUnitLabel = '章',
  ValueChanged<TocEntry>? onPick,
}) async {
  final picked = <TocEntry>[];
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.dark(), 
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showBookTocSheet(
                context,
                entries: entries,
                sourceLabel: sourceLabel,
                fallbackUnitLabel: fallbackUnitLabel,
                onPick: onPick ?? picked.add,
              ),
              child: const Text('开目录'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('开目录'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('EPUB：有原书目录 → 「N 条 · 原书目录」+ 层级缩进 + 点选回传', (tester) async {
    TocEntry? picked;
    await pumpSheet(
      tester,
      entries: const [
        TocEntry(title: '第一章 起点', index: 0),
        TocEntry(title: '第二章 深入', index: 1, depth: 1),
        TocEntry(title: '2.1 小节', index: 1, depth: 2),
      ],
      sourceLabel: '原书目录',
      onPick: (e) => picked = e,
    );

    expect(find.text('3 条 · 原书目录'), findsOneWidget);
    expect(find.byKey(const Key('book-toc-filter')), findsOneWidget);
    expect(find.byKey(const Key('book-toc-list')), findsOneWidget);

    // 缩进：层级越深越靠右（这一组都不带"当前项"高亮，免得 leading 图标干扰测量）
    final l1 = tester.getTopLeft(find.text('第一章 起点')).dx;
    final l2 = tester.getTopLeft(find.text('第二章 深入')).dx;
    final l3 = tester.getTopLeft(find.text('2.1 小节')).dx;
    expect(l2, greaterThan(l1));
    expect(l3, greaterThan(l2));

    await tester.tap(find.text('2.1 小节'));
    await tester.pumpAndSettle();
    expect(picked?.title, '2.1 小节');
    expect(picked?.index, 1);
    // 点完自动关面板
    expect(find.byKey(const Key('book-toc-list')), findsNothing);
  });

  testWidgets('当前那一条：定位图标 + 选中态（EPUB 与 PDF 都走同一套）', (tester) async {
    await pumpSheet(
      tester,
      entries: const [
        TocEntry(title: '第一章 起点', index: 0),
        TocEntry(title: '第二章 深入', index: 1, current: true),
      ],
      sourceLabel: '原书目录',
    );
    expect(find.byIcon(Icons.my_location), findsOneWidget);
    final here = tester.widget<DesignRowTile>(
      find.ancestor(of: find.text('第二章 深入'), matching: find.byType(DesignRowTile)),
    );
    expect(here.selected, isTrue);
    final other = tester.widget<DesignRowTile>(
      find.ancestor(of: find.text('第一章 起点'), matching: find.byType(DesignRowTile)),
    );
    expect(other.selected, isFalse);
  });

  testWidgets('EPUB：没有原书目录 → 按章计数（「3 章」）', (tester) async {
    await pumpSheet(
      tester,
      entries: const [
        TocEntry(title: '一', index: 0),
        TocEntry(title: '二', index: 1),
        TocEntry(title: '三', index: 2),
      ],
      sourceLabel: null,
      fallbackUnitLabel: '章',
    );
    expect(find.text('3 章'), findsOneWidget);
  });

  testWidgets('PDF：同一套面板，来源写「书签」、右侧带页码、点一条回传 0 基页码', (tester) async {
    TocEntry? picked;
    await pumpSheet(
      tester,
      entries: const [
        TocEntry(
          title: 'Chapter One',
          index: 0,
          trailing: '第 1 页',
          current: true,
        ),
        TocEntry(title: 'Chapter Two', index: 1, trailing: '第 2 页'),
        TocEntry(title: 'Section 2.1', index: 1, depth: 1, trailing: '第 2 页'),
        TocEntry(title: '坏目标', trailing: '—', enabled: false),
      ],
      sourceLabel: '书签',
      onPick: (e) => picked = e,
    );

    expect(find.text('4 条 · 书签'), findsOneWidget);
    // 与 EPUB 完全一样的骨架
    expect(find.byKey(const Key('book-toc-filter')), findsOneWidget);
    expect(find.byKey(const Key('book-toc-list')), findsOneWidget);
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.byIcon(Icons.my_location), findsOneWidget);

    await tester.tap(find.text('Section 2.1'));
    await tester.pumpAndSettle();
    expect(picked?.index, 1); // 0 基页码，调用方 +1 得到第 2 页
  });

  testWidgets('筛选：计数变「命中/总数 条」，没有命中给空态文案', (tester) async {
    await pumpSheet(
      tester,
      entries: const [
        TocEntry(title: '第一章 起点', index: 0),
        TocEntry(title: '第二章 深入', index: 1),
      ],
      sourceLabel: '原书目录',
    );
    await tester.enterText(find.byKey(const Key('book-toc-filter')), '第二');
    await tester.pumpAndSettle();
    expect(find.text('1/2 条'), findsOneWidget);
    expect(find.text('第一章 起点'), findsNothing);

    await tester.enterText(find.byKey(const Key('book-toc-filter')), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('0/2 条'), findsOneWidget);
    expect(find.text('目录里没有「不存在」'), findsOneWidget);
  });

  testWidgets('跳不过去的条目：点它什么都不发生、面板不关', (tester) async {
    var picks = 0;
    await pumpSheet(
      tester,
      entries: const [TocEntry(title: '坏目标', trailing: '—', enabled: false)],
      sourceLabel: '书签',
      onPick: (_) => picks++,
    );
    await tester.tap(find.text('坏目标'));
    await tester.pumpAndSettle();
    expect(picks, 0);
    expect(find.byKey(const Key('book-toc-list')), findsOneWidget);
  });

  testWidgets('标题为空的书签显示占位，不出现空白行', (tester) async {
    await pumpSheet(
      tester,
      entries: const [TocEntry(title: '', index: 0)],
      sourceLabel: '书签',
    );
    expect(find.text('(无标题)'), findsOneWidget);
  });
}
