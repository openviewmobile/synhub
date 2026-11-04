// O2 批：**页面接线**验收 —— 证明 OOXML 主通道真的接到了用户看到的页面上。
//
// 断言的是"用户屏幕上出现了什么"，不是内部状态：
//   * 后台返回真实 XLSX 字节 → 页面渲染的列宽 = 文件声明的 113 px（不是拉满屏）；
//   * 数字格式 `$10.00` 真的出现；
//   * 回落到 OFile 时页面**明确说明**（不静默空白）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_sheet_page.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_write_gate.dart';

Uint8List _salesTracker() =>
    File('test/fixtures/office_sheet_o2/sales_tracker.xlsx').readAsBytesSync();

/// 最小 OFile `@C_text/*` 形态（回落通道用；含中文，顺带锁 UTF-8）。
Map<String, Object?> _oFileSections() => <String, Object?>{
  'index': <String, Object?>{
    'schemaVersion': 5,
    'order': <Object?>['sh_1'],
    'sheets': <String, Object?>{
      'sh_1': <String, Object?>{'title': '回落的表'},
    },
  },
  'sh_1': <String, Object?>{
    'rowCount': 1,
    'colCount': 1,
    'cells': <String, Object?>{
      '0': <String, Object?>{
        '0': <String, Object?>{'v': '回落内容'},
      },
    },
  },
};

class _FakeBackend implements OfficeSheetBackend, OfficeSheetOoxmlSource {
  _FakeBackend({this.bytes});

  final Uint8List? bytes;

  @override
  Future<Uint8List?> loadOoxml() async => bytes;

  @override
  Future<OfficeSheetSnapshot> loadSnapshot() async => OfficeSheetSnapshot(
    sections: _oFileSections(),
    version: 1,
    raw: const <String, dynamic>{},
  );

  @override
  Future<OfficeWriteGateInputs> loadGate() async => const OfficeWriteGateInputs(
    canWrite: false,
    canComment: false,
    schemaMobile: 0,
  );

  @override
  Future<OfficeSheetSession> openSession() async => throw StateError('本用例不建会话');

  @override
  Future<void> closeSession(OfficeSheetSession session) async {}
}

Widget _page(OfficeSheetBackend backend) => ProviderScope(
  child: MaterialApp(theme: AppTheme.dark(), 
    home: OfficeSheetPage(
      // 本用例量的是**文件声明的绝对尺寸**，显式锁 100%（默认是"打开即自适应宽"）。
      initialScale: 1.0,
      request: const OfficeSheetRequest(
        fileId: '974347163437938099',
        name: 'Sales tracker.osheet',
      ),
      backend: backend,
    ),
  ),
);

void main() {
  group('P-O2.1 主通道真的接到页面', () {
    testWidgets(r'真实 XLSX → 列宽 113 px + $10.00 + 行号列/列标行', (tester) async {
      await tester.pumpWidget(_page(_FakeBackend(bytes: _salesTracker())));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('office-sheet-grid')), findsOneWidget);
      expect(
        find.byKey(const Key('office-sheet-row-header-column')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-sheet-col-header-1')),
        findsOneWidget,
      );

      // 列宽来自 `<col width="15.4286">`：113 px（**不是**屏宽）。
      final width = tester
          .getSize(find.byKey(const Key('office-sheet-cell-0-1')))
          .width;
      expect(width, closeTo(113.0, 1.0));
      expect(width, lessThan(tester.view.physicalSize.width));

      // 数字格式真的套用（C8 = 10 + [$$]#,##0.00）。
      expect(find.text(r'$10.00'), findsWidgets);
      // 主通道命中 → 没有"兼容方式打开"的说明。
      expect(find.byKey(const Key('office-sheet-fallback-note')), findsNothing);
    });

    testWidgets('拿不到字节 → 回落到 OFile 且页面**明确说明**（不静默空白）', (tester) async {
      await tester.pumpWidget(_page(_FakeBackend()));
      await tester.pumpAndSettle();
      // 回落内容仍然显示（不空白）。
      expect(find.text('回落内容'), findsOneWidget);
      // 并且页面明确告诉用户"按兼容方式打开"。
      expect(
        find.byKey(const Key('office-sheet-fallback-note')),
        findsOneWidget,
      );
      expect(find.textContaining('兼容方式打开'), findsOneWidget);
    });

    testWidgets('非 OOXML 字节（原生 OFile）→ 同样回落 + 说明', (tester) async {
      await tester.pumpWidget(
        _page(
          _FakeBackend(
            bytes: Uint8List.fromList(<int>[0x42, 0x53, 0x4F, 0x4E]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('回落内容'), findsOneWidget);
      expect(find.textContaining('兼容方式打开'), findsOneWidget);
    });
  });
}
