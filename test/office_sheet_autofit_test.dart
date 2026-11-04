// `.osheet` **打开即自适应宽** 的验收（对齐 WPS / Microsoft Office 安卓版形态）。
//
// ── 为什么有这个文件 ────────────────────────────────────────────────────────
// 用户抱怨 Office 三格式"显示非常差劲…参考下 wps，或者 microsoft office 的安卓版"。
// 其中一条**一眼可见**的形态差距：官方打开表格是**把整张表的宽度适配到屏幕**，
// 而我方**永远 `_scale = 1.0`** —— 手机竖屏宽约 375dp，真实工作表 15 列 ≈ 1500px，
// 于是打开只看到 **A/B/C 三列**，用户必须先手动点"适宽"。
//
// 修法（`OfficeSheetView`）：第一次拿到可视区宽度时做**一次性**自适应，
// 三条克制：① 每个文档只做一次；② 用户手动调过缩放就永不介入；③ **永不放大超过 100%**。
//
// 本文件钉住这四条行为。**无网络、无设备、无构建。**
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_sheet_view.dart';

/// 构造一张固定列宽的 `.osheet` sections（列宽 = [colWidth]，共 [cols] 列）。
///
/// 用**按 schema 构造**而不是真夹具，是为了让"适宽比例"可以被精确预期。
Map<String, Object?> _sheet({required int cols, required double colWidth}) {
  final cells = <String, Object?>{};
  for (var r = 0; r < 3; r++) {
    final row = <String, Object?>{};
    for (var c = 0; c < cols; c++) {
      row['$c'] = <String, Object?>{'v': 'r${r}c$c'};
    }
    cells['$r'] = row;
  }
  return <String, Object?>{
    'index': <String, Object?>{
      'order': <Object?>['sh_1'],
      'sheets': <String, Object?>{
        'sh_1': <String, Object?>{'title': 'Fit'},
      },
    },
    'sh_1': <String, Object?>{
      'rowCount': 3,
      'colCount': cols,
      'cells': cells,
      'rows': <String, Object?>{},
      'cols': <String, Object?>{
        for (var c = 0; c < cols; c++) '$c': <String, Object?>{'w': colWidth},
      },
      'mergeCells': <Object?>[],
      'drawing': <Object?>[],
      'cfs': <Object?>[],
    },
  };
}

/// 手机竖屏尺寸（HONOR LGE-AN10），逻辑宽 ≈ 375。
const Size _phone = Size(1148, 2492);
const double _dpr = 3.0625;

Widget _host(
  Map<String, Object?> sections, {
  double? initialScale,
  Widget? child,
}) {
  return MaterialApp(theme: AppTheme.dark(), 
    home: Scaffold(
      body:
          child ??
          OfficeSheetView(sections: sections, initialScale: initialScale),
    ),
  );
}

int _zoomPercent(WidgetTester tester) {
  final text = tester
      .widget<Text>(find.byKey(const Key('office-sheet-zoom-label')))
      .data!;
  return int.parse(text.replaceAll('%', ''));
}

double _hMax(WidgetTester tester) {
  for (final sv in tester.widgetList<SingleChildScrollView>(
    find.byType(SingleChildScrollView),
  )) {
    final c = sv.controller;
    if (c != null && c.hasClients && sv.scrollDirection == Axis.horizontal) {
      return c.position.maxScrollExtent;
    }
  }
  return -1;
}

void main() {
  group('打开即自适应宽（对齐 WPS/Office 形态）', () {
    // 8 列 × 100 + 行号列 48 = 848；视口 375 ⇒ 期望比例 (375-8)/848 ≈ 0.4326 ⇒ 43%。
    testWidgets('A1. 宽表打开即适宽：整表宽度进屏，且不需要横向滚动', (tester) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = _dpr;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_host(_sheet(cols: 8, colWidth: 100)));
      await tester.pumpAndSettle();

      // ① 比例真的被适配过，而不是原样 100%。
      expect(_zoomPercent(tester), lessThan(100));
      expect(_zoomPercent(tester), 43, reason: '(375-8)/848 ≈ 0.4326 ⇒ 43%');
      // ② 整张表的宽度确实进了屏 ⇒ 横向没有可滚区间。
      expect(
        _hMax(tester),
        lessThan(1.0),
        reason: '适宽后不该还需要横向滚动（hMax=${_hMax(tester)}）',
      );
      // ③ 列宽仍**来自文件声明**（× 当前比例），不是"拉满屏"。
      final cellW = tester
          .getSize(find.byKey(const Key('office-sheet-cell-0-0')))
          .width;
      expect(cellW, closeTo(100.0 * 43 / 100, 2.5));
    });

    testWidgets('A2. 窄表本来就装得下 ⇒ 保持 100%，**不做虚假放大**', (tester) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = _dpr;
      addTearDown(tester.view.reset);
      // 2 列 × 100 + 48 = 248 < 375 ⇒ 适宽比例 > 1 ⇒ 不应用。
      await tester.pumpWidget(_host(_sheet(cols: 2, colWidth: 100)));
      await tester.pumpAndSettle();
      expect(_zoomPercent(tester), 100);
      expect(_hMax(tester), lessThan(1.0));
    });

    testWidgets('A3. 用户手动缩放后**永不被自适应抢走**（重建也不抢）', (tester) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = _dpr;
      addTearDown(tester.view.reset);
      final sections = _sheet(cols: 8, colWidth: 100);
      await tester.pumpWidget(_host(sections));
      await tester.pumpAndSettle();
      final fit = _zoomPercent(tester);
      expect(fit, 43);

      // 用户放大一档：43% × 1.25 = 53.75% ⇒ 54%。
      await tester.tap(find.byKey(const Key('office-sheet-zoom-in')));
      await tester.pumpAndSettle();
      final zoomed = _zoomPercent(tester);
      expect(zoomed, greaterThan(fit));

      // 触发一次 `_prepare()`（`report` 换了实例）⇒ 不许把用户的缩放改回去。
      await tester.pumpWidget(
        _host(
          sections,
          child: OfficeSheetView(
            sections: sections,
            report: OfficeSheetRenderReport(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_zoomPercent(tester), zoomed, reason: '用户调过缩放后，自适应必须彻底让位');
    });

    testWidgets('A4. 显式 initialScale 优先，且不触发自适应', (tester) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = _dpr;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(_sheet(cols: 8, colWidth: 100), initialScale: 2.0),
      );
      await tester.pumpAndSettle();
      expect(_zoomPercent(tester), 200);
    });

    testWidgets('A5. 换文档后重新允许一次自适应', (tester) async {
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = _dpr;
      addTearDown(tester.view.reset);
      // 先用窄表（保持 100%），再换成宽表 ⇒ 新文档应当自适应。
      final narrow = _sheet(cols: 2, colWidth: 100);
      await tester.pumpWidget(_host(narrow));
      await tester.pumpAndSettle();
      expect(_zoomPercent(tester), 100);

      final wide = _sheet(cols: 8, colWidth: 100);
      await tester.pumpWidget(_host(wide));
      await tester.pumpAndSettle();
      expect(_zoomPercent(tester), 43);
    });
  });
}
