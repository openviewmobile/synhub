// ★★ ③Drive 第 245 轮：**D61 文字层联动** 的用例。
//
// 口径：
//   * 抽取是**真几何**：位置来自内容流算子 + 字体宽度表，不是"猜个大致框"；
//   * 抽不了就 `parsed=false` + 原因（对象流/CID 字体/别的滤镜），**不猜**；
//   * 选中 → 按**行**给 `/QuadPoints`（左上、右上、左下、右下）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:synhub/src/features/drive/drive_pdf_markup.dart';
import 'package:synhub/src/features/drive/drive_pdf_rewrite.dart';
import 'package:synhub/src/features/drive/drive_pdf_text_layer.dart';

Future<Uint8List> makeTextPdf(List<List<String>> pages) async {
  final doc = pw.Document();
  for (final lines in pages) {
    doc.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(300, 200, marginAll: 20),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [for (final l in lines) pw.Text(l)],
        ),
      ),
    );
  }
  return Uint8List.fromList(await doc.save());
}

void main() {
  group('D61 文字层 · 抽取', () {
    test('★ 两页文本：页序、内容、归一化框都对得上', () async {
      final bytes = await makeTextPdf([
        ['Hello World'],
        ['Second page text'],
      ]);
      final tl = extractPdfTextLayer(bytes);
      expect(tl.pages, hasLength(2));
      expect(tl.pages.map((p) => p.parsed), [true, true]);
      expect(tl.pages[0].spans.single.text, 'Hello World');
      expect(tl.pages[1].spans.single.text, 'Second page text');
      // 归一化、左上原点、框在页内、left<right、top<bottom
      for (final p in tl.pages) {
        for (final s in p.spans) {
          expect(s.left, inInclusiveRange(0, 1));
          expect(s.top, inInclusiveRange(0, 1));
          expect(s.right, greaterThan(s.left));
          expect(s.bottom, greaterThan(s.top));
          expect(s.right, lessThanOrEqualTo(1));
          expect(s.bottom, lessThanOrEqualTo(1));
        }
      }
      expect(tl.width, 300);
      expect(tl.height, 200);
    });

    test('★ 多行：自上而下排序，行间不粘连', () async {
      final bytes = await makeTextPdf([
        ['Line one', 'Line two', 'Line three'],
      ]);
      final tl = extractPdfTextLayer(bytes);
      final spans = tl.pages.single.spans;
      expect(spans.map((s) => s.text), ['Line one', 'Line two', 'Line three']);
      // 行序 = y 递增
      for (var i = 1; i < spans.length; i++) {
        expect(spans[i].top, greaterThan(spans[i - 1].top));
      }
    });

    test('★ 非 PDF ⇒ parsed=false 且写明原因（不编造）', () {
      final tl = extractPdfTextLayer(
        Uint8List.fromList(utf8.encode('not a pdf at all')),
      );
      expect(tl.anyParsed, isFalse);
      expect(tl.pages.single.parsed, isFalse);
      expect(tl.pages.single.reason, contains('不是 PDF'));
      expect(tl.spanCount, 0);
    });

    test('★ CID/Type0 字体（没有 /Widths）⇒ 明确不解码，不猜坐标', () {
      // 手搓一个最小 PDF：页对象 + 内容流引用 /F0，而 /F0 是 Type0 且无 /Widths
      const content = 'BT /F0 12 Tf 10 50 Td (abc) Tj ET';
      final objects = {
        1: '<</Type/Catalog/Pages 2 0 R>>',
        2: '<</Type/Pages/Kids[3 0 R]/Count 1>>',
        3: '<</Type/Page/Parent 2 0 R/MediaBox[0 0 100 100]'
            '/Resources<</Font<</F0 5 0 R>>>>/Contents 4 0 R>>',
        4: '<</Length ${content.length}>>\nstream\n$content\nendstream',
        5: '<</Type/Font/Subtype/Type0/BaseFont/Noto/Encoding/Identity-H'
            '/DescendantFonts[6 0 R]>>',
        6: '<</Type/Font/Subtype/CIDFontType2/BaseFont/Noto/CIDSystemInfo'
            '<</Registry(Adobe)/Ordering(Identity)/Supplement 0>>>>',
      };
      final sb = StringBuffer('%PDF-1.5\n');
      final offsets = <int, int>{};
      objects.forEach((n, body) {
        offsets[n] = sb.length;
        sb.write('$n 0 obj\n$body\nendobj\n');
      });
      final xref = sb.length;
      sb.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
      for (var i = 1; i <= objects.length; i++) {
        sb.write('${offsets[i]!.toString().padLeft(10, '0')} 00000 n \n');
      }
      sb.write(
        'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
        'startxref\n$xref\n%%EOF\n',
      );
      final tl = extractPdfTextLayer(
        Uint8List.fromList(latin1.encode(sb.toString())),
      );
      expect(tl.pages.single.parsed, isFalse);
      expect(tl.pages.single.spans, isEmpty);
      expect(tl.pages.single.reason, contains('/Widths'));
    });

    test('★ 空白页（没有文字）⇒ parsed=false + 原因，绝不返回假框', () async {
      final doc = pw.Document();
      doc.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(200, 200),
          build: (_) => pw.SizedBox(),
        ),
      );
      final tl = extractPdfTextLayer(Uint8List.fromList(await doc.save()));
      expect(tl.pages.single.parsed, isFalse);
      expect(tl.pages.single.reason, isNotEmpty);
      expect(tl.pages.single.spans, isEmpty);
    });
  });

  group('D61 文字层 · 框选 → 四边形', () {
    test('★ 框住一行 ⇒ 一个四边形 + 完整文本', () async {
      final bytes = await makeTextPdf([
        ['Select me'],
      ]);
      final tl = extractPdfTextLayer(bytes);
      final span = tl.pages.single.spans.single;
      final sel = pdfTextSelectionToQuote(
        spans: tl.pages.single.spans,
        left: span.left - 0.05,
        top: span.top - 0.02,
        right: span.right + 0.05,
        bottom: span.bottom + 0.02,
        pageWidth: 300,
        pageHeight: 200,
      );
      expect(sel.text, 'Select me');
      expect(sel.quads, hasLength(8));
      // 顺序：左上、右上、左下、右下 ⇒ y 先大后小
      expect(sel.quads[1], greaterThan(sel.quads[5]));
      expect(sel.quads[0], lessThan(sel.quads[2]));
      // 与文字层框一致（PDF 点）
      expect(sel.quads[0], closeTo(span.left * 300, 0.5));
      expect(sel.quads[2], closeTo(span.right * 300, 0.5));
      expect(sel.rect, hasLength(4));
    });

    test('★ 框住两行 ⇒ 两个四边形（每行一个），文本按行拼', () async {
      final bytes = await makeTextPdf([
        ['First row', 'Second row'],
      ]);
      final tl = extractPdfTextLayer(bytes);
      final a = tl.pages.single.spans[0];
      final b = tl.pages.single.spans[1];
      final sel = pdfTextSelectionToQuote(
        spans: tl.pages.single.spans,
        left: 0,
        top: a.top - 0.02,
        right: 1,
        bottom: b.bottom + 0.02,
        pageWidth: 300,
        pageHeight: 200,
      );
      expect(sel.quads, hasLength(16));
      expect(sel.text, contains('First row'));
      expect(sel.text, contains('Second row'));
      // 第一行的四边形在第二行**上面**（PDF 坐标 y 更大）
      expect(sel.quads[1], greaterThan(sel.quads[9]));
    });

    test('★ 框在空白处 ⇒ 空结果（不硬塞一个四边形）', () async {
      final bytes = await makeTextPdf([
        ['Top text'],
      ]);
      final tl = extractPdfTextLayer(bytes);
      final sel = pdfTextSelectionToQuote(
        spans: tl.pages.single.spans,
        left: 0.0,
        top: 0.9,
        right: 0.2,
        bottom: 0.99,
        pageWidth: 300,
        pageHeight: 200,
      );
      expect(sel.isEmpty, isTrue);
      expect(sel.text, isEmpty);
      expect(sel.quads, isEmpty);
    });
  });

  group('D61 文字层 · 与注释对象/写回联动', () {
    test('★ 带 quads 的高亮：/QuadPoints 用行四边形，/Rect 是包围盒，/Contents 用选中文字', () {
      final doc = PdfMarkupDoc(
        marks: [
          const PdfMarkup(
            id: 'h1',
            page: 0,
            kind: PdfMarkupKind.highlight,
            left: 0.1,
            top: 0.2,
            right: 0.9,
            bottom: 0.3,
            quads: [30, 160, 150, 160, 30, 140, 150, 140],
            selectedText: '框选到的文字',
          ),
        ],
      );
      final s = pdfAnnotationSpecsFromDoc(
        doc: doc,
        page: 0,
        width: 300,
        height: 200,
      ).single;
      expect(s.subtype, '/Highlight');
      expect(s.quadPoints, [30, 160, 150, 160, 30, 140, 150, 140]);
      expect(s.rect, [30, 140, 150, 160]); // 包围盒
      expect(s.contents, '框选到的文字');
    });

    test('★ 用户备注优先于选中文字', () {
      final doc = PdfMarkupDoc(
        marks: [
          const PdfMarkup(
            id: 'h2',
            page: 0,
            kind: PdfMarkupKind.highlight,
            quads: [10, 90, 60, 90, 10, 80, 60, 80],
            selectedText: '选中的',
            note: '我的备注',
          ),
        ],
      );
      final s = pdfAnnotationSpecsFromDoc(
        doc: doc,
        page: 0,
        width: 100,
        height: 100,
      ).single;
      expect(s.contents, '我的备注');
    });

    test('★ sidecar 往返：quads/selected_text 能存能读，旧数据仍兼容', () {
      final doc = PdfMarkupDoc(
        marks: [
          const PdfMarkup(
            id: 'h3',
            page: 1,
            kind: PdfMarkupKind.highlight,
            left: 0.1,
            top: 0.1,
            right: 0.5,
            bottom: 0.2,
            quads: [10, 90, 50, 90, 10, 80, 50, 80],
            selectedText: 'round trip',
          ),
        ],
      );
      final back = PdfMarkupDoc.decode(doc.encode());
      expect(back.marks.single.quads, [10, 90, 50, 90, 10, 80, 50, 80]);
      expect(back.marks.single.selectedText, 'round trip');
      // 旧 sidecar（没有这两个键）⇒ 默认空，不炸
      final legacy = PdfMarkupDoc.decode(
        '{"key":"pdf_markup","version":1,"marks":[{"id":"old","page":0,'
        '"kind":"highlight","left":0.1,"top":0.1,"right":0.2,"bottom":0.2}]}',
      );
      expect(legacy.marks.single.quads, isEmpty);
      expect(legacy.marks.single.selectedText, isEmpty);
    });

    test('★ 端到端：文字层选中的高亮写回原文件后 /QuadPoints 是行四边形', () async {
      final original = await makeTextPdf([
        ['Write me back'],
      ]);
      final tl = extractPdfTextLayer(original);
      final span = tl.pages.single.spans.single;
      final sel = pdfTextSelectionToQuote(
        spans: tl.pages.single.spans,
        left: span.left - 0.05,
        top: span.top - 0.02,
        right: span.right + 0.05,
        bottom: span.bottom + 0.02,
        pageWidth: 300,
        pageHeight: 200,
      );
      final doc = PdfMarkupDoc(
        marks: [
          PdfMarkup(
            id: 'h4',
            page: 0,
            kind: PdfMarkupKind.highlight,
            left: span.left,
            top: span.top,
            right: span.right,
            bottom: span.bottom,
            quads: sel.quads,
            selectedText: sel.text,
            createdAtMs: 1700000000000,
          ),
        ],
      );
      final specs = pdfAnnotationSpecsFromDoc(
        doc: doc,
        page: 0,
        width: 300,
        height: 200,
      );
      final r = appendPdfAnnotations(bytes: original, specs: specs);
      final annots = readPdfAnnotations(bytes: r.bytes, page: 0);
      expect(annots.single.subtype, '/Highlight');
      expect(annots.single.hasQuadPoints, isTrue);
      expect(annots.single.contents, 'Write me back');
    });
  });
}
