// PDF 阅读器里的 AI 助手：入口（悬浮球）、文字抽取接线、以及"抽不到就别装"。
//
// 为什么值得单测：PDF 的正文对 `pdfx`/系统 PdfRenderer 来说是**图片**，AI 想说话
// 必须先靠 `extractPdfPages` 把字抠出来。这条链路（球 → 抽文字 → 面板）任何一环
// 断了，用户看到的就是"PDF 里没有 AI"或者"总结了个寂寞"。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/ai/ai_floating_orb.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/file_pdf_view.dart';

/// 一页、有真实文字层的 PDF（WinAnsi 简单字体）
Uint8List textPdf(String text) {
  final out = BytesBuilder();
  final offs = <int, int>{};
  out.add(utf8.encode('%PDF-1.7\n%\xe2\xe3\xcf\xd3\n'));
  void obj(int n, String body) {
    offs[n] = out.length;
    out.add(utf8.encode('$n 0 obj\n$body\nendobj\n'));
  }

  void stream(int n, String body) {
    offs[n] = out.length;
    final raw = utf8.encode(body);
    out.add(utf8.encode('$n 0 obj\n<< /Length ${raw.length} >>\nstream\n'));
    out.add(raw);
    out.add(utf8.encode('\nendstream\nendobj\n'));
  }

  obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
  obj(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  obj(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
    '/Resources << /Font << /F1 5 0 R >> >> >>',
  );
  stream(4, 'BT /F1 12 Tf 40 700 Td ($text) Tj ET');
  obj(
    5,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
    '/Encoding /WinAnsiEncoding >>',
  );
  final xref = out.length;
  out.add(utf8.encode('xref\n0 6\n0000000000 65535 f \n'));
  for (var n = 1; n <= 5; n++) {
    out.add(utf8.encode('${offs[n]!.toString().padLeft(10, '0')} 00000 n \n'));
  }
  out.add(
    utf8.encode(
      'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
    ),
  );
  return out.toBytes();
}

/// 只有图片的"扫描件"：没有任何文字层
Uint8List imageOnlyPdf() {
  final out = BytesBuilder();
  final offs = <int, int>{};
  out.add(utf8.encode('%PDF-1.7\n%\xe2\xe3\xcf\xd3\n'));
  void obj(int n, String body) {
    offs[n] = out.length;
    out.add(utf8.encode('$n 0 obj\n$body\nendobj\n'));
  }

  void stream(int n, String body) {
    offs[n] = out.length;
    final raw = utf8.encode(body);
    out.add(utf8.encode('$n 0 obj\n<< /Length ${raw.length} >>\nstream\n'));
    out.add(raw);
    out.add(utf8.encode('\nendstream\nendobj\n'));
  }

  obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
  obj(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  obj(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
    '/Resources << /XObject << /Im1 5 0 R >> >> >>',
  );
  stream(4, 'q 612 0 0 792 0 0 cm /Im1 Do Q');
  stream(5, 'not-a-jpeg');
  final xref = out.length;
  out.add(utf8.encode('xref\n0 6\n0000000000 65535 f \n'));
  for (var n = 1; n <= 5; n++) {
    out.add(utf8.encode('${offs[n]!.toString().padLeft(10, '0')} 00000 n \n'));
  }
  out.add(
    utf8.encode(
      'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
    ),
  );
  return out.toBytes();
}

final _entry = FileEntryDto(
  name: '手册.pdf',
  path: '/home/手册.pdf',
  size: 2048,
  mtime: 1700000000,
);

/// 真渲染器：`pdfx` 的平台通道在单测里没有实现，`PdfView` 会走 errorBuilder，
/// 但悬浮球在它外层，照样能点 —— 这条链路正是我们要测的。
Future<void> pumpPdf(WidgetTester tester, Uint8List bytes) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: Builder(
            builder: (context) => Stack(
              children: [
                Positioned.fill(child: buildPdfxViewer(context, _entry, bytes)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('有文字层的 PDF：悬浮球在，点一下能开 AI 面板并给出处', (tester) async {
    await pumpPdf(tester, textPdf('Hello PDF body'));
    // ignore: avoid_print
    expect(find.byType(AiFloatingOrb), findsOneWidget);
    expect(find.byTooltip('AI 助手'), findsOneWidget);

    await tester.tap(find.byTooltip('AI 助手'));
    // 抽文字是异步的（大文件还会进 isolate）→ 多 pump 几轮
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    // 面板出来了，并且自动跑了"总结"（没装模型时如实标注内置摘要）
    expect(find.textContaining('AI 助手 · 总结'), findsOneWidget);
    expect(find.textContaining('手册.pdf'), findsWidgets);
    // PDF 不是"书"：文案要是"问这份 PDF"，出处要带上页码
    expect(find.text('问这份 PDF'), findsOneWidget);
    expect(find.text('问这本书'), findsNothing);
    expect(find.textContaining('手册.pdf · 第 1 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('扫描件（没有文字层）：如实提示，不打开面板、不编内容', (tester) async {
    await pumpPdf(tester, imageOnlyPdf());
    await tester.tap(find.byTooltip('AI 助手'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(find.textContaining('没有文字'), findsOneWidget);
    expect(find.textContaining('AI 助手 · 总结'), findsNothing);
  });
}
