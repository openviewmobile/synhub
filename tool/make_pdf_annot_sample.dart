// 生成一份"原文件 + 就地把批注写回去"的样本，供**独立校验器**（系统 PDFKit）检查。
//
//   dart run tool/make_pdf_annot_sample.dart /tmp/out.pdf
//
// 这样做的意义：D61 的自研增量更新是"我们自己的解析器说它对了"还不够，
// 要让**另一个独立的 PDF 实现**（macOS PDFKit，见 tool/verify_pdf_annots.swift）
// 能打开、能列出注释、能拿到子类型 —— 这才算"写进原文件"。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:synhub/src/features/drive/drive_pdf_markup.dart';
import 'package:synhub/src/features/drive/drive_pdf_rewrite.dart';
import 'package:synhub/src/features/drive/drive_pdf_text_layer.dart';

Future<void> main(List<String> args) async {
  final outPath = args.isNotEmpty ? args.first : '/tmp/drive_pdf_annot_sample.pdf';

  // ① 造"原文件"：2 页、带真文字
  final doc = pw.Document();
  for (var i = 0; i < 2; i++) {
    doc.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(300, 200, marginAll: 12),
        build: (_) => pw.Center(child: pw.Text('Original page ${i + 1}')),
      ),
    );
  }
  final original = Uint8List.fromList(await doc.save());

  // ② 批注模型（归一化、左上原点）
  final marks = PdfMarkupDoc(
    marks: [
      const PdfMarkup(
        id: 'hl',
        page: 1,
        kind: PdfMarkupKind.highlight,
        left: 0.10,
        top: 0.20,
        right: 0.70,
        bottom: 0.35,
        note: 'highlight note',
        color: 0xFFFFD54F,
        createdAtMs: 1700000000000,
      ),
      const PdfMarkup(
        id: 'ink',
        page: 1,
        kind: PdfMarkupKind.ink,
        left: 0.10,
        top: 0.50,
        right: 0.60,
        bottom: 0.80,
        points: [0.10, 0.50, 0.30, 0.70, 0.60, 0.80],
        color: 0xFFE53935,
        createdAtMs: 1700000001000,
      ),
      const PdfMarkup(
        id: 'note',
        page: 1,
        kind: PdfMarkupKind.note,
        left: 0.80,
        top: 0.10,
        right: 0.86,
        bottom: 0.18,
        note: '中文便签：这里要改',
        color: 0xFF1E88E5,
        createdAtMs: 1700000002000,
      ),
    ],
  );

  // ②′ ★ 245 轮：文字层联动 —— 框选第 1 页的文字行，按行给四边形
  final layer = extractPdfTextLayer(original);
  final page0 = layer.pages.isEmpty ? null : layer.pages[0];
  if (page0 != null && page0.parsed && page0.spans.isNotEmpty) {
    final span = page0.spans.first;
    final sel = pdfTextSelectionToQuote(
      spans: page0.spans,
      left: span.left - 0.05,
      top: span.top - 0.02,
      right: span.right + 0.05,
      bottom: span.bottom + 0.02,
      pageWidth: 300,
      pageHeight: 200,
    );
    marks.add(
      PdfMarkup(
        id: 'text-hl',
        page: 0,
        kind: PdfMarkupKind.highlight,
        left: span.left,
        top: span.top,
        right: span.right,
        bottom: span.bottom,
        quads: sel.quads,
        selectedText: sel.text,
        color: 0xFFA5D6A7,
        createdAtMs: 1700000003000,
      ),
    );
  }

  // ③ 写回**原文件**
  final specs = <PdfAnnotationSpec>[
    ...pdfAnnotationSpecsFromDoc(doc: marks, page: 0, width: 300, height: 200),
    ...pdfAnnotationSpecsFromDoc(doc: marks, page: 1, width: 300, height: 200),
  ];
  final r = appendPdfAnnotations(bytes: original, specs: specs);

  File(outPath).writeAsBytesSync(r.bytes);

  // ④ 自述（校验器输出与它比对）
  stdout.writeln(
    jsonEncode({
      'out': outPath,
      'originalBytes': original.length,
      'patchedBytes': r.bytes.length,
      'pageObjects': r.pageObjectNumbers,
      'appendedObjects': r.appendedObjectNumbers,
      'previousStartXref': r.previousStartXref,
      'newStartXref': r.newStartXref,
      'textLayerParsed': layer.pages.map((p) => p.parsed).toList(),
      'page1Spans': page0 == null
          ? const <String>[]
          : page0.spans.map((s) => s.text).toList(),
      'annotsOnPage1': readPdfAnnotations(
        bytes: r.bytes,
        page: 0,
      ).map((a) => a.toJson()).toList(),
      'annotsOnPage2': readPdfAnnotations(
        bytes: r.bytes,
        page: 1,
      ).map((a) => a.toJson()).toList(),
    }),
  );
}
