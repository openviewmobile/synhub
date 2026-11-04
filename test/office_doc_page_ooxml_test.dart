// O1（`.odoc` 重做）—— **页面集成**：OOXML 主通道 / 回落 / 无横幅。
//
// 这里用假后端（离线、无网络）验证三件事：
//   1. 后端**能**提供 DOCX 字节 → 页面渲染 **A4 纸面**（`OfficeDocPaperView`），
//      且**没有**"兼容排版"提示；
//   2. 后端**拿不到** DOCX（离线 / 老服务端 / 无权限）→ 回落到既有 OFile 渲染，
//      并且**明确告知用户**（可关闭的小条，不是常驻横幅，也不是静默空白）；
//   3. 页面上**没有**任何开发者话术（"从简 / 本批 / 只读渲染"）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/doc_ot_session.dart';
import 'package:synhub/src/data/office_collab/doc_schema.dart';
import 'package:synhub/src/features/office/office_doc_page.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/office/office_write_gate.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/office_collab/$name').readAsStringSync())
        as Map<String, Object?>;

Uint8List _docxBytes() => Uint8List.fromList(
  File('test/fixtures/office_doc_redesign/product_spec.docx').readAsBytesSync(),
);

/// 假后端：`ooxml == null` 表示拿不到标准格式（等价于离线/无权限）。
class _FakeBackend implements OfficeDocBackend, OfficeDocOoxmlSource {
  _FakeBackend({required this.ooxml, required this.snapshot});

  final Uint8List? ooxml;
  final OfficeDocSnapshot snapshot;

  int ooxmlCalls = 0;

  @override
  Future<Uint8List?> loadOoxmlBytes() async {
    ooxmlCalls++;
    return ooxml;
  }

  @override
  Future<OfficeDocSnapshot> loadSnapshot() async => snapshot;

  @override
  Future<OfficeWriteGateInputs> loadGate() async => const OfficeWriteGateInputs(
    canWrite: true,
    canComment: true,
    schemaMobile: 2003,
  );

  @override
  Future<DocOtSession> openSession() async =>
      throw const OfficeDocLoadException('no_session', '离线用例不建会话');

  @override
  Future<OfficeDocSaveResult> save(DocOtSession session) async =>
      const OfficeDocSaveResult(success: false, message: '离线');

  @override
  Future<void> closeSession(DocOtSession session) async {}
}

OfficeDocSnapshot _snapshot(Map<String, Object?> doc) {
  final node = DocNode.fromRawJson(doc);
  return OfficeDocSnapshot(node: node, version: 1, raw: node.toRawJson());
}

Future<void> _pumpPage(WidgetTester tester, _FakeBackend backend) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(theme: AppTheme.dark(), 
        home: OfficeDocPage(
          request: const OfficeDocRequest(
            fileId: '1',
            name: 'Product spec.odoc',
          ),
          backend: backend,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final fetchDoc = _fixture('dart_fetched_doc_v1.json');

  testWidgets('Q1. 后端给得出 DOCX → 走 **A4 纸面主通道**，且没有"兼容排版"提示', (tester) async {
    final backend = _FakeBackend(
      ooxml: _docxBytes(),
      snapshot: _snapshot(fetchDoc),
    );
    await _pumpPage(tester, backend);

    expect(backend.ooxmlCalls, 1, reason: '必须**调用** OOXML 通道');
    // 主通道：A4 纸面 + 纸面阅读容器。
    expect(find.byKey(const Key('office-doc-paper')), findsOneWidget);
    expect(find.byKey(const Key('office-doc-paper-page-0')), findsOneWidget);
    expect(find.byKey(const Key('office-doc-page-indicator')), findsOneWidget);
    // 真实 DOCX 内容上屏。
    //
    // ⚠️ 作用域限定到第 0 页：正文里有**文档自带**的目录（`w:sdt`，解析层已修复），
    //   而目录条目就是标题原文 ⇒ 不限定时会同时命中"目录条目"和"正文标题"。
    final page0 = find.byKey(const Key('office-doc-paper-page-0'));
    Finder inPage(String t) =>
        find.descendant(of: page0, matching: find.text(t));
    expect(inPage('YOUR COMPANY'), findsOneWidget);
    expect(inPage('1. Introduction'), findsWidgets);
    // 项目符号**不**需要限定：目录条目只有标题文字，没有 `●`，
    // 所以未限定时它仍然是恰好 2 个。
    expect(find.text('●'), findsNWidgets(2));
    // ★ 正文里那份目录是**文档自己带的**（SDT 内容控件），不是我方合成的：
    //   标题段 + 7 条条目都在。我方已**不再**合成第二份
    //   （用户要求："没有目录的 odoc 不要强行加上目录，要根据文档是否真的有目录来"）。
    expect(find.text('Table of Contents'), findsWidgets);
    expect(find.byKey(const Key('office-doc-inline-toc')), findsNothing);
    // 表格按声明列宽。
    expect(find.byKey(const Key('office-docx-table')), findsOneWidget);
    // **主通道不出现回落提示**。
    expect(find.byKey(const Key('office-doc-layout-note')), findsNothing);
    // 开发者话术一律不在。
    for (final banned in <String>['从简', '本批', '只读渲染', '只读预览']) {
      expect(find.textContaining(banned), findsNothing, reason: banned);
    }
  });

  testWidgets('Q2. 拿不到 DOCX → 回落 OFile，并**明确告知**（可关闭，非常驻）', (tester) async {
    final backend = _FakeBackend(ooxml: null, snapshot: _snapshot(fetchDoc));
    await _pumpPage(tester, backend);

    expect(backend.ooxmlCalls, 1);
    expect(find.byKey(const Key('office-doc-paper')), findsNothing);
    // 回落到既有 OFile 渲染路径：正文仍在（**不静默空白**）。
    expect(find.text('C3SPIKE-DOC-BASE', findRichText: true), findsOneWidget);
    // 如实说明，且**可关闭**。
    final note = find.byKey(const Key('office-doc-layout-note'));
    expect(note, findsOneWidget);
    expect(find.textContaining('兼容排版'), findsOneWidget);
    await tester.tap(find.byKey(const Key('office-doc-layout-note-close')));
    await tester.pumpAndSettle();
    expect(note, findsNothing);
    // 关闭后正文依然在（不是靠提示撑着的）。
    expect(find.text('C3SPIKE-DOC-BASE', findRichText: true), findsOneWidget);
  });

  testWidgets('Q3. 非 DOCX 字节（原生 OFile / 垃圾数据）→ 同样走回落', (tester) async {
    final backend = _FakeBackend(
      // 不是 `PK\x03\x04`：`loadOoxmlBytes` 的契约要求调用方已校验，
      // 这里直接给"坏字节"，页面必须**不崩**并且回落到 OFile。
      ooxml: Uint8List.fromList(List<int>.filled(32, 0x41)),
      snapshot: _snapshot(fetchDoc),
    );
    await _pumpPage(tester, backend);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('office-doc-paper')), findsNothing);
    expect(find.byKey(const Key('office-doc-layout-note')), findsOneWidget);
    expect(find.text('C3SPIKE-DOC-BASE', findRichText: true), findsOneWidget);
  });

  testWidgets('Q4. 编辑入口仍在（阅读模式是默认，编辑是主动动作）', (tester) async {
    final backend = _FakeBackend(
      ooxml: _docxBytes(),
      snapshot: _snapshot(fetchDoc),
    );
    await _pumpPage(tester, backend);
    // 会话没建立 → 门控入口是**禁用占位**（既有语义不变）。
    expect(find.byKey(const Key('office-doc-edit-entry')), findsOneWidget);
    expect(find.byKey(const Key('office-doc-save')), findsOneWidget);
    // 阅读模式下**没有**编辑工具栏（工具栏只在编辑模式出现）。
    expect(find.byKey(const Key('office-doc-toolbar')), findsNothing);
  });
}
