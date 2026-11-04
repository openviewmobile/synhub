// R17 批：`.osheet` **公式显示修复**的离线验收。
//
// 真机缺陷（O4 批次在真机上发现、如实报告但按纪律未修；本批修好）：
//   * 协作会话一建立（`OfficeSheetEditController` 非 null），整表退回原始值 ——
//     公式格显示 `=SUM(B13:B21)` 原文而不是求值结果 `200,000`；
//   * 数字格式一并丢失：`40000` 而非 `40,000`。
//   机制：`office_sheet_view.dart :: _cell()` 旧实现用 **`edit == null`**（编辑
//   控制器是否存在）而不是 **"本格是否有未落盘的本地乐观值"** 来判定显示来源。
//
// 夹具：**真实 NAS 文件**（`test/fixtures/office_sheet_o2/annual_income_and_
// expenditure.{xlsx,json}`，O2 批次只读抓取）。它同时含：
//   * 公式格 B22 `=SUM(B13:B21)`（s=31 → builtin numFmt 3 `#,##0`）→ `200,000`；
//   * 普通数字格 B13 `40000`（s=20 → 同一个 `#,##0`）→ `40,000`。
//   断言里的 `40,000` / `200,000` 是**文件声明的数字格式**算出来的，不是实现里
//   写死的常量（本文件不碰实现，只喂夹具）。
//
// 无网络、无设备、无构建、**无任何写入**：假 sink 只收命令不真发。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/office_collab/office_collab_client.dart';
import 'package:synhub/src/features/office/office_sheet_edit.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_sheet_view.dart';

Uint8List _xlsxBytes(String name) =>
    File('test/fixtures/office_sheet_o2/$name').readAsBytesSync();

Map<String, Object?> _sections(String name) =>
    (jsonDecode(File('test/fixtures/office_sheet_o2/$name').readAsStringSync())
            as Map)
        .cast<String, Object?>();

/// 假发送通道：只**记录**命令、**绝不**对真实 NAS 发请求。
class _FakeSink implements OfficeSheetCommandSink {
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  final StreamController<OfficeCollabEvent> events =
      StreamController<OfficeCollabEvent>.broadcast();

  /// 非 null 时 `sendSet` 挂起（用来定格"在飞未确认"态）。
  Completer<void>? gate;

  @override
  Future<Object?> sendSet(Map<String, Object?> payload) async {
    sent.add(<String, Object?>{...payload});
    final g = gate;
    if (g != null) await g.future;
    return <Object?>[payload['rev'], payload['rev'], 1, null];
  }

  @override
  Stream<OfficeCollabEvent> get incoming => events.stream;

  void push(String name, Object? arg) =>
      events.add(OfficeCollabEvent(name, <Object?>[arg]));

  Future<void> close() => events.close();
}

/// 真机上"协作会话已建立"的等价物：`edit` 非 null，base 来自同一份文件的 sections。
OfficeSheetEditController _editFor(
  _FakeSink sink,
  Map<String, Object?> sections,
) => OfficeSheetEditController(
  sink: sink,
  base: officeSheetBaseCells(sections, 'sh_1'),
  initialRev: 3,
  sheetId: 'sh_1',
  source: 'r17-test',
);

Widget _host(Widget child) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(body: SizedBox(width: 800, height: 1200, child: child)),
);

/// 单元格当时显示的文本（键可能是 Text，也可能是包住 Text 的宿主）。
String? _textAt(WidgetTester tester, String key) {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) return null;
  final widget = finder.evaluate().first.widget;
  if (widget is Text) return widget.data;
  final text = find.descendant(of: finder, matching: find.byType(Text));
  if (text.evaluate().isEmpty) return null;
  return tester.widget<Text>(text.first).data;
}

const String _annual = 'annual_income_and_expenditure';

void main() {
  group('R17.1 edit 控制器存在 ≠ 显示原始值（真机缺陷的根因）', () {
    testWidgets(
      'edit 非 null 且本格**无本地改动** ⇒ =SUM(B13:B21) 显示 200,000（求值），不是公式原文',
      (tester) async {
        final sections = _sections('$_annual.json');
        final sink = _FakeSink();
        final edit = _editFor(sink, sections);
        addTearDown(edit.dispose);
        addTearDown(sink.close);

        await tester.pumpWidget(
          _host(
            OfficeSheetView(
              sections: sections,
              ooxmlBytes: _xlsxBytes('$_annual.xlsx'),
              edit: edit,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 求值结果键（O3 起就有）——现在**在 edit 非 null 时也必须命中**。
        expect(
          _textAt(tester, 'office-sheet-formula-value-21-1'),
          '200,000',
          reason: '协作会话建立后公式格仍要显示求值结果 + 数字格式',
        );
        // 旧键兼容，内容也必须是数值。
        expect(_textAt(tester, 'office-sheet-formula-21-1'), '200,000');
        // 公式原文不该出现在屏幕上（真机缺陷的可见症状）。
        expect(find.text('=SUM(B13:B21)'), findsNothing);
      },
    );

    testWidgets('回归保护：无 edit 控制器 ⇒ 仍显示 200,000（批 1/O3 只读路径逐字不变）', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            sections: const <String, Object?>{},
            ooxmlBytes: _xlsxBytes('$_annual.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_textAt(tester, 'office-sheet-formula-value-21-1'), '200,000');
      expect(find.text('=SUM(B13:B21)'), findsNothing);
    });

    testWidgets('OFILE 兼容通道（只有 sections）在 edit 非 null 时也显示求值结果', (
      tester,
    ) async {
      final sections = _sections('$_annual.json');
      final sink = _FakeSink();
      final edit = _editFor(sink, sections);
      addTearDown(edit.dispose);
      addTearDown(sink.close);

      await tester.pumpWidget(
        _host(OfficeSheetView(sections: sections, edit: edit)),
      );
      await tester.pumpAndSettle();

      expect(_textAt(tester, 'office-sheet-formula-value-21-1'), '200,000');
      expect(find.text('=SUM(B13:B21)'), findsNothing);
    });
  });

  group('R17.2 本地乐观显示不被破坏', () {
    testWidgets('本格**有**未落盘的本地改动 ⇒ 显示改动值（原样，不套格式）', (tester) async {
      final sections = _sections('$_annual.json');
      final sink = _FakeSink()..gate = Completer<void>();
      final edit = _editFor(sink, sections)..editable = true;
      addTearDown(edit.dispose);
      addTearDown(sink.close);

      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            sections: sections,
            ooxmlBytes: _xlsxBytes('$_annual.xlsx'),
            edit: edit,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // B13：文件值 40000，用户敲进去 99999。
      edit.editCell(12, 1, 99999);
      await tester.pump();

      expect(
        _textAt(tester, 'office-sheet-cell-12-1'),
        '99999',
        reason:
            '有本地乐观值时必须显示改动值（编辑手感），不能套文件的千分位 '
            '（否则输入过程中文本会自己跳变）',
      );
      // 未确认标记仍在（乐观显示 + 编辑层契约不变）。
      expect(
        find.byKey(const Key('office-sheet-cell-pending-12-1')),
        findsOneWidget,
      );
      // 也没有把这一格退回公式/文件路径。
      expect(_textAt(tester, 'office-sheet-cell-12-1'), isNot('40,000'));

      sink.gate!.complete();
      sink.gate = null;
      await tester.pump(const Duration(milliseconds: 20));
    });

    testWidgets('有本地改动的公式格 ⇒ 显示用户输入的原文（不假装求值）', (tester) async {
      final sections = _sections('$_annual.json');
      final sink = _FakeSink()..gate = Completer<void>();
      final edit = _editFor(sink, sections)..editable = true;
      addTearDown(edit.dispose);
      addTearDown(sink.close);

      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            sections: sections,
            ooxmlBytes: _xlsxBytes('$_annual.xlsx'),
            edit: edit,
          ),
        ),
      );
      await tester.pumpAndSettle();

      edit.editCell(21, 1, '=B13+B14');
      await tester.pump();
      expect(_textAt(tester, 'office-sheet-cell-21-1'), '=B13+B14');

      sink.gate!.complete();
      sink.gate = null;
      await tester.pump(const Duration(milliseconds: 20));
    });
  });

  group('R17.3 数字格式恢复（40000 → 40,000）', () {
    testWidgets('edit 非 null + 普通数字格：文件 #,##0 格式仍生效', (tester) async {
      final sections = _sections('$_annual.json');
      final sink = _FakeSink();
      final edit = _editFor(sink, sections);
      addTearDown(edit.dispose);
      addTearDown(sink.close);

      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            sections: sections,
            ooxmlBytes: _xlsxBytes('$_annual.xlsx'),
            edit: edit,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _textAt(tester, 'office-sheet-cell-12-1'),
        '40,000',
        reason: 'B13 = 40000，文件声明 numFmt `#,##0` ⇒ 必须千分位',
      );
      // 真机上"格式丢了"的样子：裸 `40000` 不该再出现。
      expect(find.text('40000'), findsNothing);
    });

    testWidgets('无 edit 控制器时同一格也是 40,000（两条通道口径一致）', (tester) async {
      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            sections: const <String, Object?>{},
            ooxmlBytes: _xlsxBytes('$_annual.xlsx'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_textAt(tester, 'office-sheet-cell-12-1'), '40,000');
    });
  });

  group('R17.4 协作契约：公式的引用看得到远端改动（不显示文件快照的旧值）', () {
    testWidgets('远端把 B13 改成 0 ⇒ =SUM(B13:B21) 从 200,000 变 160,000', (
      tester,
    ) async {
      final sections = _sections('$_annual.json');
      final sink = _FakeSink();
      final edit = _editFor(sink, sections);
      addTearDown(edit.dispose);
      addTearDown(sink.close);

      await tester.pumpWidget(
        _host(
          OfficeSheetView(
            sections: sections,
            ooxmlBytes: _xlsxBytes('$_annual.xlsx'),
            edit: edit,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_textAt(tester, 'office-sheet-formula-value-21-1'), '200,000');

      // 远端广播（同 `set` 帧形状；**不经过写路径**）。
      sink.push('set', <String, Object?>{
        'cmd': 'value',
        'id': 'sh_1',
        'changes': <Object?>[
          <Object?>[12, 1, 0],
        ],
        'rev': 4,
      });
      // 广播经 Socket.IO 事件流异步到达：多泵一帧让 setState 落到屏幕上。
      await tester.pumpAndSettle();

      expect(
        _textAt(tester, 'office-sheet-formula-value-21-1'),
        '160,000',
        reason: '求值必须看得到协作改动（B13 40000→0），而不是停在文件快照上',
      );
      expect(_textAt(tester, 'office-sheet-cell-12-1'), '0');
    });
  });
}
