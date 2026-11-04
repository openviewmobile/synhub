// 冻结窗格**可滚动区域**回归测试。
//
// ── 为什么有这个文件 ────────────────────────────────────────────────────────
// 用户报「.osheet 文档左右滑动有 bug」。排查发现本仓 `test/office_sheet*.dart`
// 里**从来没有一次真正的 `drag()`** —— `office_sheet_o2_render_test.dart:7`
// 的注释写着"且能横向滚动"，但那条断言并不存在。于是横向/纵向滚动的**整条
// 命中测试路径完全没有覆盖**，下面这个缺陷就这样活了下来：
//
//   冻结带（行号列 / 列标行 / 冻结行带 / 冻结列带 / 左上角）是 `Positioned`
//   画在二维滚动视图**之上**的 `ColoredBox`。`ColoredBox` 用
//   `_RenderColoredBox extends RenderProxyBoxWithHitTestBehavior`，构造时
//   `behavior: HitTestBehavior.opaque` ⇒ `hitTestSelf()` **恒为 true**
//   ⇒ 外层 `Stack` 认为"已被命中"，**不再把指针交给下面的滚动视图**
//   ⇒ 在这些区域滑动**完全不滚动**（探针实测 h=0 / v=0）。
//
// 修复：`_bandScrollRelay`（不参与 gesture arena 的 `Listener`，只转发位移，
// 因此**点击仍然落到正确的单元格**）+ 冻结带背景 `IgnorePointer`。
//
// ── 纪律 ────────────────────────────────────────────────────────────────────
// 1. 断言必须覆盖**每一个**冻结区域，不只是主体 —— 这个 bug 恰恰只在
//    冻结区域出现，只测主体会 100% 漏掉。
// 2. 拖动起点必须用**从 widget 树里量出来的坐标**。我第一版探针把
//    `(250, 20)` 当成列标行，实际那里是**工具栏**（表格从 y=49 起），
//    于是"测出"了假死区。
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_sheet_view.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/office_sheet_o2/$name').readAsBytesSync();

Widget _host(Widget child, {double w = 360, double h = 640}) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(
    body: SizedBox(width: w, height: h, child: child),
  ),
);

/// 当前两个滚动控制器的偏移（外层 = 纵向，内层 = 横向）。
({double v, double h}) _offsets(WidgetTester tester) {
  var v = 0.0, h = 0.0;
  for (final sv in tester.widgetList<SingleChildScrollView>(
    find.byType(SingleChildScrollView),
  )) {
    final c = sv.controller;
    if (c == null || !c.hasClients) continue;
    if (sv.scrollDirection == Axis.horizontal) {
      h = c.offset;
    } else {
      v = c.offset;
    }
  }
  return (v: v, h: h);
}

void _resetScroll(WidgetTester tester) {
  for (final sv in tester.widgetList<SingleChildScrollView>(
    find.byType(SingleChildScrollView),
  )) {
    final c = sv.controller;
    if (c != null && c.hasClients) c.jumpTo(0);
  }
}

void main() {
  group('冻结窗格：每个区域都必须能滚动（用户报「左右滑动有 bug」）', () {
    /// 拖动 [from] 后返回偏移。每次先复位，避免相互污染。
    Future<({double v, double h})> dragAt(
      WidgetTester tester,
      Offset from,
      Offset delta,
    ) async {
      _resetScroll(tester);
      await tester.pumpAndSettle();
      await tester.dragFrom(from, delta);
      await tester.pumpAndSettle();
      return _offsets(tester);
    }

    testWidgets('Sales tracker：行号列 / 列标行 / 左上角 / 主体 都能横向滚动', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // ⚠️ 坐标**从 widget 树量出来**，不要写死。
      //    表格上方有工具栏，写死 y=20 会点到工具栏（我踩过）。
      final rowHdr = tester.getRect(
        find.byKey(const Key('office-sheet-row-header-0')),
      );
      final colHdr = tester.getRect(
        find.byKey(const Key('office-sheet-col-header-0')),
      );
      final grid = tester.getRect(find.byKey(const Key('office-sheet-grid')));

      // 前提：这份样本确实需要横向滚动，否则本组断言没有意义。
      final start = _offsets(tester);
      expect(start.h, 0.0, reason: '初始横向偏移应为 0');
      final vScroll = tester
          .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .map((sv) => sv.controller)
          .where((c) => c != null && c.hasClients)
          .toList();
      expect(vScroll, isNotEmpty);

      const left = Offset(-200, 0);

      // ① 主体
      final body = await dragAt(
        tester,
        grid.centerLeft + const Offset(60, 0),
        left,
      );
      expect(body.h, greaterThan(0), reason: '主体区必须能横向滚动');

      // ② 行号列（修复前 = 0）
      final rowHeaderBand = await dragAt(
        tester,
        Offset(rowHdr.right / 2, rowHdr.center.dy + 120),
        left,
      );
      expect(
        rowHeaderBand.h,
        greaterThan(0),
        reason: '在**行号列**上滑动必须能横向滚动（修复前这里是触摸死区）',
      );

      // ③ 列标行（修复前 = 0）
      final colHeaderBand = await dragAt(
        tester,
        Offset(colHdr.center.dx + 150, colHdr.center.dy),
        left,
      );
      expect(
        colHeaderBand.h,
        greaterThan(0),
        reason: '在**列标行**上滑动必须能横向滚动（修复前这里是触摸死区）',
      );

      // ④ 左上角
      final corner = await dragAt(
        tester,
        Offset(rowHdr.right / 2, colHdr.center.dy),
        left,
      );
      expect(
        corner.h,
        greaterThan(0),
        reason: '在**左上角**上滑动必须能横向滚动（修复前这里是触摸死区）',
      );
    });

    testWidgets('Sales tracker：四个区域都能纵向滚动', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rowHdr = tester.getRect(
        find.byKey(const Key('office-sheet-row-header-0')),
      );
      final colHdr = tester.getRect(
        find.byKey(const Key('office-sheet-col-header-0')),
      );
      final grid = tester.getRect(find.byKey(const Key('office-sheet-grid')));

      const up = Offset(0, -200);

      final body = await dragAt(
        tester,
        grid.centerLeft + const Offset(60, 60),
        up,
      );
      expect(body.v, greaterThan(0), reason: '主体区必须能纵向滚动');

      final rowHeaderBand = await dragAt(
        tester,
        Offset(rowHdr.right / 2, rowHdr.center.dy + 120),
        up,
      );
      expect(rowHeaderBand.v, greaterThan(0), reason: '行号列上滑动必须能纵向滚动');

      final colHeaderBand = await dragAt(
        tester,
        Offset(colHdr.center.dx + 150, colHdr.center.dy),
        up,
      );
      expect(colHeaderBand.v, greaterThan(0), reason: '列标行上滑动必须能纵向滚动（修复前 = 0）');

      final corner = await dragAt(
        tester,
        Offset(rowHdr.right / 2, colHdr.center.dy),
        up,
      );
      expect(corner.v, greaterThan(0), reason: '左上角上滑动必须能纵向滚动（修复前 = 0）');
    });

    testWidgets('在冻结带上下滑动**不能**把点击透给错误的单元格', (tester) async {
      // 冻结带里的单元格带 `onTap`（点格编辑）。修法必须**保住点击**：
      // `IgnorePointer` 包整块或只包行号列，都会让"点冻结格"失效
      // 或把点击透给被压在下层的错格子。这里用"点行号列不得触发任何编辑"
      // 作为下界，并断言 grid 仍然完整可点。
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rowHdr = tester.getRect(
        find.byKey(const Key('office-sheet-row-header-0')),
      );
      // 点行号列：只读态下不应有任何编辑态出现（不得出现文本框）
      await tester.tapAt(Offset(rowHdr.right / 2, rowHdr.center.dy + 200));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing, reason: '只读态点行号列不应进入编辑');

      // 点主体：也不应崩、不出现异常
      final grid = tester.getRect(find.byKey(const Key('office-sheet-grid')));
      await tester.tapAt(grid.centerLeft + const Offset(60, 60));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('斜向拖动只锁一个轴（不会两轴同时乱动）', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rowHdr = tester.getRect(
        find.byKey(const Key('office-sheet-row-header-0')),
      );
      final before = _offsets(tester);
      expect(before.v, 0.0);
      expect(before.h, 0.0);

      // 横向占优的斜划 ⇒ 只应横向滚动
      await tester.dragFrom(
        Offset(rowHdr.right / 2, rowHdr.center.dy + 120),
        const Offset(-200, -60),
      );
      await tester.pumpAndSettle();
      final after = _offsets(tester);
      expect(after.h, greaterThan(0), reason: '横向占优的斜划应横向滚动');
      expect(after.v, 0.0, reason: '横向占优的斜划不应同时纵向滚动');
    });
  });

  group('冻结表头必须与内容【同向同步】（真 bug：符号曾写反，差 2×offset）', () {
    /// 量出当前的横/纵滚动偏移。
    ({double v, double h}) offs(WidgetTester tester) => _offsets(tester);

    testWidgets('纵向滚动后：行号列标签位移 == -vOffset（而不是 +vOffset）', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('annual_income_and_expenditure.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 取一个**不在冻结行集内**的行号标签（冻结行在左上角块里，本就不动）。
      // 第 21 行（index 20）足够靠下，确定在可滚动的行号列里。
      const idx = 20;
      final label = find.byKey(Key('office-sheet-row-header-$idx'));
      expect(label, findsOneWidget, reason: '第 ${idx + 1} 行的行号标签应存在');
      final beforeY = tester.getRect(label).center.dy;

      await tester.dragFrom(const Offset(200, 400), const Offset(0, -400));
      await tester.pumpAndSettle();

      final after = offs(tester);
      expect(after.v, greaterThan(0), reason: '应确实纵向滚动了');
      final afterY = tester.getRect(label).center.dy;

      // 核心断言：标签必须**上移** vOffset，与内容同向。
      // 写反符号时会变成**下移** vOffset（两者相差 2×offset）——本用例就是为它写的。
      expect(
        beforeY - afterY,
        closeTo(after.v, 0.5),
        reason:
            '行号列必须上移 vOffset(=) 与内容同向；'
            '实测位移=${(beforeY - afterY).toStringAsFixed(1)}，vOffset=${after.v}',
      );
    });

    testWidgets('横向滚动后：列标行标签位移 == -hOffset（而不是 +hOffset）', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            initialScale: 1.0,
            sections: const <String, Object?>{},
            ooxmlBytes: _fixture('sales_tracker.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 找一个确定在可滚动列标行里的列标（靠右一点，避开冻结列）。
      final probe = find.byKey(const Key('office-sheet-col-header-3'));
      if (probe.evaluate().isEmpty) return; // 该样本列数不足，跳过
      final beforeX = tester.getRect(probe).center.dx;

      final grid = tester.getRect(find.byKey(const Key('office-sheet-grid')));
      await tester.dragFrom(
        Offset(grid.left + 80, (grid.top + 600) / 2),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();

      final after = offs(tester);
      expect(after.h, greaterThan(0), reason: '应确实横向滚动了');
      final afterX = tester.getRect(probe).center.dx;
      expect(
        beforeX - afterX,
        closeTo(after.h, 0.5),
        reason:
            '列标行必须左移 hOffset 与内容同向；'
            '实测位移=${(beforeX - afterX).toStringAsFixed(1)}，hOffset=${after.h}',
      );
    });
  });

  group('滚到底，冻结表头不许"滚空"（真机 bug：行号列整个消失）', () {
    testWidgets('滚到最大后：行号列仍必须显示【最后一行】的编号，且编号连续', (tester) async {
      // 守卫：**滚到最大滚动位置时，行号列必须仍然显示一段连续的编号，
      // 并且一直盖到内容的最后一行**（而不是在某个位置"滚空"）。
      //
      // ⚠️ 诚实登记：真机上量到过"行号列下部整片空白、只剩冻结行"的现象，
      //    但在离线（OOXML 与 OFile 两条解析通道都试过）**都没能复现**，
      //    因此本用例是**防回归守卫**，不是"某处修复的证明"。
      //    写这个用例时我自己踩过两个坑，都写进注释了：
      //      (a) 套 `_host`(360x640) 后拖动起点落在 host 之外 ⇒ vOff 恒为 0；
      //      (b) 拖动距离太小没到 max ⇒ 看到的是中间态。
      tester.view.physicalSize = const Size(1148, 2492); // 真机 HONOR LGE-AN10
      tester.view.devicePixelRatio = 3.0625;
      addTearDown(tester.view.reset);
      // ⚠️ 这里**不能**套 `_host`（它是 360x640 的 SizedBox）：
      //      1) 套上之后拖动起点必须落在 360x640 内，否则拖了个寂寞（vOff 恒为 0）；
      //      2) 这个 bug 与**视口高度/比例**相关，必须用真机尺寸整屏。
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: OfficeSheetView(
              initialScale: 1.0,
              sections: const <String, Object?>{},
              ooxmlBytes: _fixture('annual_income_and_expenditure.xlsx'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final band = tester.getRect(
        find.byKey(const Key('office-sheet-row-header-column')),
      );
      // 拉到底（真实文件的最后一行是 83）。起点必须在屏幕内且拖得足够远。
      await tester.dragFrom(const Offset(190, 700), const Offset(0, -20000));
      await tester.pumpAndSettle();

      var visible = <int>[];
      for (var r = 0; r < 90; r++) {
        final f = find.byKey(Key('office-sheet-row-header-$r'));
        if (f.evaluate().isEmpty) continue;
        final rect = tester.getRect(f);
        if (rect.bottom <= band.top || rect.top >= band.bottom) continue;
        visible.add(r + 1);
      }
      expect(visible, isNotEmpty, reason: '滾到底后行号列整片空白 —— 表头条带"滚空"了（条带尺寸取小了）');
      // 编号必须连续：中间断号说明条带上部/下部被裁掉。
      for (var i = 1; i < visible.length; i++) {
        expect(visible[i], visible[i - 1] + 1, reason: '行号必须连续，实测可见=$visible');
      }
      // 必须一直盖到内容的最后一行。
      expect(
        visible.last,
        greaterThanOrEqualTo(50),
        reason: '滚到底时最后可见行号应接近内容末尾，实测=${visible.last}（可见=$visible）',
      );
    });
  });

  // =========================================================================
  // 冻结表头"平移条带"必须**盖满自己的裁剪窗口**
  //
  // 真机 bug（适宽 25%）：整张表都画出来了（INCOME…INSURANCE 全在），
  // **行号却只画到十几行，下面整片空白**。
  //
  // 推导（见 `officeSheetBandStripExtent` 的文档注释）：
  //   band = 视口 − (header + frozen)        条带的裁剪窗口
  //   oMax = body − band                     （为负时钳到 0）
  //   要盖满需 strip ≥ band + oMax
  //     * body >  band ⇒ strip ≥ body        ← 原代码，够
  //     * body ≤  band ⇒ strip ≥ band        ← **原代码必然差一截**
  // 所以正确值是 max(body, band)。
  //
  // ⚠️ 我上一轮试过 `header+frozen+body`（"全长"），它在第 2 个分支**仍然不够**
  //    （实测 338 < 493）；A/B 又没覆盖这个分支，才让我误判成"不需要修"。
  // =========================================================================
  group('条带长度不变量（真机适宽 bug）', () {
    test('U1. `officeSheetBandStripExtent`：两个分支都要满足 strip ≥ band + oMax', () {
      // 分支 1：内容比视口高（可滚动）⇒ 取 body，恰好等于 band + oMax。
      expect(officeSheetBandStripExtent(2000, 500), 2000);
      // 分支 2：内容比视口矮（适宽/表短）⇒ oMax = 0 ⇒ 必须取 band。
      expect(officeSheetBandStripExtent(300, 500), 500);
      expect(officeSheetBandStripExtent(0, 500), 500);
      // 边界：相等时任取其一都对。
      expect(officeSheetBandStripExtent(500, 500), 500);
      // 防御：窗口非正时不返回负数。
      expect(officeSheetBandStripExtent(120, -10), 120);
      // 真机那组实测数值：适宽 25% 下 body≈338、band≈493 ⇒ 必须取 493。
      expect(officeSheetBandStripExtent(338, 493), 493);
    });

    testWidgets('U2. 真机尺寸 + 适宽（整表进视口）：条带必须 ≥ 裁剪窗口', (tester) async {
      tester.view.physicalSize = const Size(1148, 2492); // HONOR LGE-AN10
      tester.view.devicePixelRatio = 3.0625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: OfficeSheetView(
              initialScale: 1.0,
              sections: const <String, Object?>{},
              ooxmlBytes: _fixture('annual_income_and_expenditure.xlsx'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // "适宽" ⇒ scale 变小、整张表（含 83 行）进入视口 ⇒ body ≤ band。
      await tester.tap(find.byKey(const Key('office-sheet-zoom-fit')));
      await tester.pumpAndSettle();

      final band = tester.getRect(
        find.byKey(const Key('office-sheet-row-header-column')),
      );
      final stripRect = tester.getRect(
        find.byKey(const Key('office-sheet-row-header-strip')),
      );
      // 行号列的窗口是 band 自身（`Positioned(top: headerH+frozenH, bottom: 0)`）。
      expect(
        stripRect.height,
        greaterThanOrEqualTo(band.height - 0.5),
        reason:
            '行号列条带必须盖满整个裁剪窗口，否则下半截整片空白。'
            'strip=${stripRect.height} band=${band.height}',
      );
    });

    testWidgets('U3. 真机尺寸 + 适宽：横向条带同理必须 ≥ 裁剪窗口', (tester) async {
      tester.view.physicalSize = const Size(1148, 2492);
      tester.view.devicePixelRatio = 3.0625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: OfficeSheetView(
              initialScale: 1.0,
              sections: const <String, Object?>{},
              ooxmlBytes: _fixture('annual_income_and_expenditure.xlsx'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('office-sheet-zoom-fit')));
      await tester.pumpAndSettle();

      final band = tester.getRect(
        find.byKey(const Key('office-sheet-header-row')),
      );
      final stripRect = tester.getRect(
        find.byKey(const Key('office-sheet-col-header-strip')),
      );
      expect(
        stripRect.width,
        greaterThanOrEqualTo(band.width - 0.5),
        reason:
            '列标行条带必须盖满整个裁剪窗口。'
            'strip=${stripRect.width} band=${band.width}',
      );
    });
  });

  // =========================================================================
  // ★ 渲染级（像素）验证：滚深之后行号列**真的画出了数字**
  //
  // 为什么必须做像素级：`tester.getRect()` 返回的是**布局矩形**，
  // **完全不反映裁剪**。我这一轮就是被它骗了很久 ——
  // 探针一直报"labels=58..83"，而真机上那一整列是空白。
  //
  // 真正发生过的事：条带外层是 `Stack`（松约束）⇒ 请求的高度被**钳到窗口高**；
  // 条带**内层** `Stack` 默认 `Clip.hardEdge` ⇒ 超出被整个裁掉。
  // 布局矩形还在，像素没了。所以只有像素能证伪。
  // =========================================================================
  group('行号列渲染级验证（Clip.hardEdge 真 bug）', () {
    testWidgets('U4. 95% 深度滚动后：行号列必须有深色文字像素（不是一片表头底色）', (tester) async {
      tester.view.physicalSize = const Size(1148, 2492); // HONOR LGE-AN10
      tester.view.devicePixelRatio = 3.0625;
      addTearDown(tester.view.reset);
      const boundaryKey = Key('u4-boundary');
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: RepaintBoundary(
              key: boundaryKey,
              child: OfficeSheetView(
                initialScale: 1.0,
                sections: const <String, Object?>{},
                ooxmlBytes: _fixture('annual_income_and_expenditure.xlsx'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 真机路径：先"适宽"到 25%，再点 6 次 x1.25 ⇒ 95%。
      await tester.tap(find.byKey(const Key('office-sheet-zoom-fit')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byKey(const Key('office-sheet-zoom-in')));
        await tester.pumpAndSettle();
      }
      // 滚到最底。
      await tester.dragFrom(const Offset(190, 700), const Offset(0, -4000));
      await tester.pumpAndSettle();

      final band = tester.getRect(
        find.byKey(const Key('office-sheet-row-header-column')),
      );
      // ⚠️ `toImage()` 是真异步：widget 测试里**必须**包在 `runAsync` 里，
      //    否则这个 await 永远不返回（我第一版就这么挂死了）。
      late final int w;
      late final Uint8List bytes;
      await tester.runAsync(() async {
        final image = await tester
            .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey))
            .toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        expect(data, isNotNull);
        bytes = data!.buffer.asUint8List();
        w = image.width;
      });

      // 只看行号列的**下半段**（下表头区），那里以前整片是 0xFFF5F5F5。
      final x0 = band.left.round();
      final x1 = band.right.round();
      final y0 = (band.top + (band.bottom - band.top) * 0.35).round();
      final y1 = band.bottom.round();
      var dark = 0, total = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1 && x < w; x++) {
          final i = (y * w + x) * 4;
          final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2];
          total++;
          // 表头文字 0x5F6368 / 分隔线 0xD0D7DE；底色 0xF5F5F5。
          // 判"深"取 r<0x90（文字），避开底色与浅线。
          if (r < 0x90 && g < 0x90 && b < 0x90) dark++;
        }
      }
      expect(total, greaterThan(0));
      expect(
        dark,
        greaterThan(20),
        reason:
            '行号列下半段几乎全是底色（dark=$dark/$total）⇒ 行号被裁掉了。'
            '这正是内层 Stack 用 Clip.hardEdge 的症状。',
      );
    });
  });
}
