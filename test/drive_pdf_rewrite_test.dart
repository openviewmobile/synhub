// ★★ ③Drive 第 244 轮：**D61 写回原文件（自研 PDF 增量更新）** 的用例。
//
// 铁律口径：
//   * 这些用例证明的是**原文件被就地追加了真正的注释对象**（`/Annots`），
//     且旧内容一字未动、xref 链正确；
//   * **不**证明"所有 PDF 都能改"：加密 PDF 明确拒绝，页对象在对象流里
//     目前不支持（如实报错，不假装成功）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:synhub/src/features/drive/drive_pdf_annot_export.dart';
import 'package:synhub/src/features/drive/drive_pdf_markup.dart';
import 'package:synhub/src/features/drive/drive_pdf_rewrite.dart';

/// 造一个 2 页、带可提取文字的 PDF（用 pdf 包；不是"我们自己的格式"）。
Future<Uint8List> makePdf({int pages = 2}) async {
  final doc = pw.Document();
  for (var i = 0; i < pages; i++) {
    doc.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(200, 100, marginAll: 8),
        build: (_) => pw.Center(child: pw.Text('page ${i + 1}')),
      ),
    );
  }
  return Uint8List.fromList(await doc.save());
}

void main() {
  group('D61 · 坐标换算（归一化左上 → PDF 左下点）', () {
    test('★ 高亮框 y 翻转正确 + 生成 /Highlight 与 /QuadPoints', () {
      final doc = PdfMarkupDoc(
        marks: [
          const PdfMarkup(
            id: 'm1',
            page: 0,
            kind: PdfMarkupKind.highlight,
            left: 0.1,
            top: 0.25,
            right: 0.6,
            bottom: 0.5,
            note: '重点',
            createdAtMs: 1700000000000,
          ),
        ],
      );
      final specs = pdfAnnotationSpecsFromDoc(
        doc: doc,
        page: 0,
        width: 200,
        height: 100,
      );
      expect(specs, hasLength(1));
      final s = specs.single;
      expect(s.subtype, '/Highlight');
      // x: 0.1*200=20 .. 0.6*200=120；y: 100-0.5*100=50 .. 100-0.25*100=75
      expect(s.rect, [20, 50, 120, 75]);
      // QuadPoints：左上、右上、左下、右下
      expect(s.quadPoints, [20, 75, 120, 75, 20, 50, 120, 50]);
      expect(s.contents, '重点');
    });

    test('★ 手写：点坐标也翻转，且进 /InkList', () {
      final doc = PdfMarkupDoc(
        marks: [
          const PdfMarkup(
            id: 'i1',
            page: 0,
            kind: PdfMarkupKind.ink,
            points: [0.2, 0.1, 0.4, 0.5],
            color: 0xFF112233,
          ),
        ],
      );
      final s = pdfAnnotationSpecsFromDoc(
        doc: doc,
        page: 0,
        width: 200,
        height: 100,
      ).single;
      expect(s.subtype, '/Ink');
      expect(s.inkLists.single, [40, 90, 80, 50]);
    });

    test('★ 便签 → /Text，内容进 /Contents', () {
      final doc = PdfMarkupDoc(
        marks: [
          const PdfMarkup(
            id: 'n1',
            page: 0,
            kind: PdfMarkupKind.note,
            left: 0.5,
            top: 0.1,
            right: 0.55,
            bottom: 0.2,
            note: '这里有问题',
          ),
        ],
      );
      final s = pdfAnnotationSpecsFromDoc(
        doc: doc,
        page: 0,
        width: 200,
        height: 100,
      ).single;
      expect(s.subtype, '/Text');
      expect(s.contents, '这里有问题');
    });
  });

  group('D61 · 写回原文件（增量更新）', () {
    test('★ 原文件被就地追加 /Annots，旧前缀一字未动', () async {
      final original = await makePdf();
      final prefix = latin1.decode(original.sublist(0, 200), allowInvalid: true);
      final r = appendPdfAnnotations(
        bytes: original,
        specs: [
          PdfAnnotationSpec(
            page: 1,
            subtype: '/Highlight',
            rect: const [20, 50, 120, 75],
            quadPoints: const [20, 75, 120, 75, 20, 50, 120, 50],
            contents: 'highlight',
            createdAtMs: 1700000000000,
          ),
          PdfAnnotationSpec(
            page: 1,
            subtype: '/Ink',
            rect: const [10, 10, 60, 60],
            inkLists: [
              const [10, 10, 60, 60],
            ],
          ),
          PdfAnnotationSpec(
            page: 1,
            subtype: '/Text',
            rect: const [5, 5, 20, 20],
            contents: 'note',
          ),
        ],
      );
      // ① 更长（是追加，不是重写）
      expect(r.bytes.length, greaterThan(original.length));
      // ② 原文件前缀逐字节保留
      expect(
        latin1.decode(r.bytes.sublist(0, 200), allowInvalid: true),
        prefix,
      );
      // ③ 一个页对象 + 三个注释对象被写
      expect(r.appendedObjectNumbers, hasLength(4));
      // ④ 回读：第 2 页有 3 条注释，子类型与结构对得上
      final annots = readPdfAnnotations(bytes: r.bytes, page: 1);
      expect(annots, hasLength(3));
      expect(annots.map((a) => a.subtype), ['/Highlight', '/Ink', '/Text']);
      final hl = annots.firstWhere((a) => a.subtype == '/Highlight');
      expect(hl.hasQuadPoints, isTrue);
      expect(hl.rect, [20, 50, 120, 75]);
      expect(hl.contents, 'highlight');
      expect(annots.firstWhere((a) => a.subtype == '/Ink').hasInkList, isTrue);
      // ⑤ 第 1 页没被动过
      expect(readPdfAnnotations(bytes: r.bytes, page: 0), isEmpty);
      // ⑥ 只看注释对象层**不在页字典里画** —— 视觉层是另一个函数的事
      final asText = latin1.decode(r.bytes, allowInvalid: true);
      expect(asText.contains('/Subtype /Highlight'), isTrue);
      expect(asText.trimRight().endsWith('%%EOF'), isTrue);
    });

    test('★ xref：重建整表（CoreGraphics 零告警的形态）+ 偏移可核对', () async {
      final original = await makePdf();
      final r = appendPdfAnnotations(
        bytes: original,
        specs: [
          PdfAnnotationSpec(
            page: 0,
            subtype: '/Text',
            rect: const [5, 5, 20, 20],
            contents: 'x',
          ),
        ],
      );
      final text = latin1.decode(r.bytes, allowInvalid: true);
      // ① 用的是重建整表（原文件是 xref 流；带 /Prev 会让 CoreGraphics 报警）
      expect(r.usedFullRebuild, isTrue);
      expect(text.contains('/Prev'), isFalse);
      expect(text.contains('trailer'), isTrue);
      expect(text.contains('startxref\n${r.newStartXref}'), isTrue);
      expect(
        latin1.decode(
          r.bytes.sublist(r.newStartXref, r.newStartXref + 4),
          allowInvalid: true,
        ),
        'xref',
      );
      // ② 整表：对象 0 是空闲头，所有对象（含原有页对象）都有条目
      final offsets = _parseXrefEntries(text, r.newStartXref);
      expect(offsets.containsKey(0), isTrue, reason: '经典表必须有对象 0 空闲头');
      for (final n in r.pageObjectNumbers) {
        expect(offsets.containsKey(n), isTrue, reason: '原页对象 $n 也要在整表里');
      }
      // ③ 每个追加对象登记的偏移处确实是 `N 0 obj`
      for (final n in r.appendedObjectNumbers) {
        final off = offsets[n];
        expect(off, isNotNull, reason: '对象 $n 应在 xref 表里');
        expect(
          latin1.decode(
            r.bytes.sublist(off!, off + '$n 0 obj'.length),
            allowInvalid: true,
          ),
          '$n 0 obj',
        );
      }
    });

    test('★ 二次追加 ⇒ 合并（不覆盖已有 /Annots）', () async {
      final original = await makePdf();
      final once = appendPdfAnnotations(
        bytes: original,
        specs: [
          PdfAnnotationSpec(
            page: 0,
            subtype: '/Text',
            rect: const [5, 5, 20, 20],
            contents: 'first',
          ),
        ],
      );
      final twice = appendPdfAnnotations(
        bytes: once.bytes,
        specs: [
          PdfAnnotationSpec(
            page: 0,
            subtype: '/Text',
            rect: const [30, 30, 60, 60],
            contents: 'second',
          ),
        ],
      );
      final annots = readPdfAnnotations(bytes: twice.bytes, page: 0);
      expect(annots, hasLength(2));
      expect(annots.map((a) => a.contents), containsAll(['first', 'second']));
      // 两次都是"重建整表"形态：第二次的表覆盖第一次的新对象
      expect(twice.usedFullRebuild, isTrue);
      expect(
        latin1.decode(twice.bytes, allowInvalid: true).contains('/Prev'),
        isFalse,
      );
      expect(readPdfAnnotations(bytes: twice.bytes, page: 0), hasLength(2));
    });

    test('★ 无 spec ⇒ 原样返回（不做无意义的改写）', () async {
      final original = await makePdf();
      final r = appendPdfAnnotations(bytes: original, specs: const []);
      expect(r.bytes, original);
      expect(r.appendedObjectNumbers, isEmpty);
    });

    test('★ 非 PDF ⇒ 明确报错，不做破坏性写入', () {
      expect(
        () => appendPdfAnnotations(
          bytes: Uint8List.fromList(utf8.encode('hello world')),
          specs: [
            PdfAnnotationSpec(
              page: 0,
              subtype: '/Text',
              rect: const [0, 0, 1, 1],
            ),
          ],
        ),
        throwsA(isA<PdfRewriteException>()),
      );
    });

    test('★ 加密 PDF ⇒ 拒绝（不硬改）', () async {
      final original = await makePdf();
      final bytes = Uint8List.fromList([
        ...original,
        ...latin1.encode('\ntrailer << /Encrypt 9 0 R >>\n'),
      ]);
      expect(
        () => appendPdfAnnotations(
          bytes: bytes,
          specs: [
            PdfAnnotationSpec(
              page: 0,
              subtype: '/Text',
              rect: const [0, 0, 1, 1],
            ),
          ],
        ),
        throwsA(
          isA<PdfRewriteException>().having(
            (e) => e.message,
            'message',
            contains('/Encrypt'),
          ),
        ),
      );
    });

    test('★ 页号越界 ⇒ 报错（不写到错的页上）', () async {
      final original = await makePdf(pages: 1);
      expect(
        () => appendPdfAnnotations(
          bytes: original,
          specs: [
            PdfAnnotationSpec(
              page: 5,
              subtype: '/Text',
              rect: const [0, 0, 1, 1],
            ),
          ],
        ),
        throwsA(
          isA<PdfRewriteException>().having(
            (e) => e.message,
            'message',
            contains('页号越界'),
          ),
        ),
      );
    });

    test('★ 非 ASCII 便签内容用 UTF-16BE 十六进制串写（PDF 规范）', () async {
      final original = await makePdf(pages: 1);
      final r = appendPdfAnnotations(
        bytes: original,
        specs: [
          PdfAnnotationSpec(
            page: 0,
            subtype: '/Text',
            rect: const [5, 5, 20, 20],
            contents: '中文批注',
          ),
        ],
      );
      final text = latin1.decode(r.bytes, allowInvalid: true);
      expect(text.contains('<FEFF'), isTrue);
      // 回读拿到的是原始字节串（十六进制形式），能被再解析
      final info = readPdfAnnotations(bytes: r.bytes, page: 0).single;
      expect(info.subtype, '/Text');
    });
  });

  group('D61 · 写回原文件（整文档入口 writeBackPdfAnnotations）', () {
    test('★ 多页：有批注的页写 /Annots，没有批注的页不动', () async {
      final original = await makePdf(pages: 3);
      final doc = PdfMarkupDoc(
        marks: [
          const PdfMarkup(
            id: 'a',
            page: 0,
            kind: PdfMarkupKind.highlight,
            left: 0.1,
            top: 0.1,
            right: 0.5,
            bottom: 0.3,
          ),
          const PdfMarkup(
            id: 'b',
            page: 2,
            kind: PdfMarkupKind.note,
            left: 0.2,
            top: 0.2,
            right: 0.3,
            bottom: 0.3,
            note: 'p3',
          ),
        ],
      );
      final pages = [
        for (var i = 0; i < 3; i++)
          PdfPageBitmap(
            page: i,
            width: 200,
            height: 100,
            pngBytes: Uint8List.fromList([1, 2, 3]),
          ),
      ];
      final out = await writeBackPdfAnnotations(
        original: original,
        doc: doc,
        pages: pages,
      );
      expect(readPdfAnnotations(bytes: out, page: 0).single.subtype, '/Highlight');
      expect(readPdfAnnotations(bytes: out, page: 1), isEmpty);
      expect(readPdfAnnotations(bytes: out, page: 2).single.subtype, '/Text');
      // 原字节仍在最前面（是追加不是重写）
      expect(
        latin1.decode(out.sublist(0, 8), allowInvalid: true),
        '%PDF-1.5',
      );
    });

    test('★ 零批注 ⇒ 字节原样返回（写回不做无谓改动）', () async {
      final original = await makePdf(pages: 1);
      final out = await writeBackPdfAnnotations(
        original: original,
        doc: PdfMarkupDoc(),
        pages: [
          PdfPageBitmap(
            page: 0,
            width: 200,
            height: 100,
            pngBytes: Uint8List.fromList([1]),
          ),
        ],
      );
      expect(out, original);
    });
  });
}

/// 解析从 [start] 处开始的经典 xref 表：对象号 → 偏移。
Map<int, int> _parseXrefEntries(String text, int start) {
  expect(text.substring(start, start + 4), 'xref');
  final out = <int, int>{};
  var i = start + 4;
  while (i < text.length) {
    while (i < text.length && (text[i] == '\n' || text[i] == '\r')) {
      i++;
    }
    final header = RegExp(r'^(\d+) (\d+)').firstMatch(text.substring(i));
    if (header == null) break;
    final first = int.parse(header.group(1)!);
    final count = int.parse(header.group(2)!);
    i += header.end;
    if (i < text.length && text[i] == '\n') i++;
    for (var k = 0; k < count; k++) {
      final entry = RegExp(
        r'^(\d{10}) (\d{5}) ([nf])',
      ).firstMatch(text.substring(i));
      expect(entry, isNotNull, reason: 'xref 条目格式错：${text.substring(i, i + 20)}');
      out[first + k] = int.parse(entry!.group(1)!);
      i += entry.end;
      if (i < text.length && text[i] == ' ') i++;
      if (i < text.length && text[i] == '\n') i++;
    }
    // 后面还有子段就继续（追加的对象号通常不连续）
    while (i < text.length && (text[i] == '\n' || text[i] == '\r')) {
      i++;
    }
    if (text.startsWith('trailer', i)) break;
  }
  return out;
}
