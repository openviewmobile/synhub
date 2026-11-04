// ★★★ ③Drive **D61「批注写进 PDF 注释对象层」** —— 第 231 轮。
//
// ## 官方做法 vs 我方
// 官方 PDF 阅读器把批注写进**原 PDF 的对象图**（`/Annots`），所以别的阅读器
// 打开原文件能看到批注、能编辑、能列出批注面板。
// 219 轮我方只是"**画上去**"（把批注画进导出的副本像素/矢量里）——
// 在别的阅读器里那不是批注，只是一块颜色。
//
// `pdf` 包**不能改已有 PDF**，只能构建新文档 ⇒ 本轮在**导出的副本**上写
// **真正的注释对象**（`/Annots` + `/Subtype`），其他阅读器能列出来：
//   * 高亮 → `/Square`（★ `pdf` 包**没有** `/Highlight`，如实登记，不假装一致）
//   * 手写 → `/Ink`（带 `/InkList`）
//   * 便签 → `/Text`（`/Contents` 就是便签文字）
// 视觉层仍然保留（不看注释面板的阅读器照样看得到），二者叠加不冲突。
//
// ## 坐标
// 批注模型是**归一化、左上原点**；PDF 注释对象用**左下原点**、页面点为单位 ⇒
// 这里做一次翻转：`bottom_pdf = h - bottom_td`。手写点的 y 直接给"相对页顶"的值，
// `PdfAnnotInk.build` 内部会按 `rect.height - y` 翻回来（`annotation.dart:576`）。
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'drive_pdf_markup.dart';
import 'drive_pdf_rewrite.dart';

/// 注释对象的作者名（其他阅读器的批注面板会显示）
const String kPdfAnnotAuthor = 'Synology Chat Station';

/// 导出：**视觉层 + 注释对象层**（二者叠加）。
Future<Uint8List> flattenPdfMarkupsAnnotated({
  required List<PdfPageBitmap> pages,
  required PdfMarkupDoc doc,
  DateTime? date,
}) async {
  final out = pw.Document();
  final stamp = date ?? DateTime.now();
  for (final p in pages) {
    final w = p.width.toDouble().clamp(1, 100000).toDouble();
    final h = p.height.toDouble().clamp(1, 100000).toDouble();
    final ops = pdfPageDrawOps(doc, p.page, w, h);
    final image = pw.MemoryImage(Uint8List.fromList(p.pngBytes));
    out.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(w, h, marginAll: 0),
        build: (ctx) => pw.Stack(
          children: [
            pw.Positioned.fill(child: pw.Image(image, fit: pw.BoxFit.fill)),
            for (final op in ops)
              if (op.kind == PdfMarkupKind.highlight)
                pw.Positioned(
                  left: op.rect.left,
                  top: op.rect.top,
                  child: pw.Container(
                    width: (op.rect.right - op.rect.left).clamp(1, w).toDouble(),
                    height: (op.rect.bottom - op.rect.top).clamp(1, h).toDouble(),
                    color: PdfColor.fromInt(op.color),
                  ),
                )
              else if (op.kind == PdfMarkupKind.note)
                pw.Positioned(
                  left: op.rect.left,
                  top: op.rect.top,
                  child: pw.Container(
                    padding: const pw.EdgeInsets.all(4),
                    color: PdfColors.yellow,
                    child: pw.Text(
                      op.note,
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                  ),
                )
              else
                pw.Positioned.fill(
                  child: pw.CustomPaint(
                    size: PdfPoint(w, h),
                    painter: (canvas, size) {
                      canvas
                        ..setStrokeColor(PdfColor.fromInt(op.color))
                        ..setLineWidth(2.4);
                      if (op.points.isEmpty) return;
                      canvas.moveTo(op.points.first.dx, h - op.points.first.dy);
                      for (final pt in op.points.skip(1)) {
                        canvas.lineTo(pt.dx, h - pt.dy);
                      }
                      canvas.strokePath();
                    },
                  ),
                ),
          ],
        ),
      ),
    );
    final pdfPage = out.document.pdfPageList.pages.last;
    for (final op in ops) {
      // ⚠️ `PdfAnnot` 的构造器**自己**会 `pdfPage.annotations.add(this)`
      // （`annotation.dart:110`）—— 再调一次 `addAnnotation` 会让
      // `/Annots[4 0 R 4 0 R]` 出现**重复引用**（231 轮用例当场抓到）。
      PdfAnnot(pdfPage, _annotFor(op, w, h, stamp, out.document));
    }
  }
  return out.save();
}

PdfAnnotBase _annotFor(
  PdfPageDrawOp op,
  double width,
  double height,
  DateTime date,
  PdfDocument document,
) {
  final box = PdfRect.fromLBRT(
    op.rect.left,
    height - op.rect.bottom,
    op.rect.right,
    height - op.rect.top,
  );
  switch (op.kind) {
    case PdfMarkupKind.highlight:
      final c = PdfColor.fromInt(op.color);
      return PdfAnnotSquare(
        rect: box,
        color: c,
        // 半透明填充 ⇒ 更像"高亮"（`pdf` 包没有 /Highlight，如实登记）
        interiorColor: PdfColor(c.red, c.green, c.blue, 0.35),
        date: date,
        author: kPdfAnnotAuthor,
        subject: 'Highlight',
      );
    case PdfMarkupKind.note:
      return PdfAnnotText(
        rect: box,
        content: op.note,
        date: date,
        author: kPdfAnnotAuthor,
        subject: 'Note',
      );
    case PdfMarkupKind.ink:
      return PdfAnnotInk(
        // 传"相对页顶"的点：build 内部按 rect.height - y 翻成左下原点，
        // 所以整页矩形 + 左上原点坐标正好对得上。
        document,
        [
          if (op.points.isNotEmpty)
            [
              for (final pt in op.points) PdfPoint(pt.dx, pt.dy),
            ],
        ],
        rect: PdfRect.fromLBRT(0, 0, width, height),
        color: PdfColor.fromInt(op.color),
        date: date,
        author: kPdfAnnotAuthor,
        subject: 'Ink',
      );
  }
}

/// ★ 244 轮 D61：**把批注写回原文件**（自研 PDF 增量更新，另一份实现见
/// `drive_pdf_rewrite.dart`）。
///
/// 与 [flattenPdfMarkupsAnnotated] 的区别：
///   * 那个是"导出**副本**"（重建页面图像 + 注释对象）；
///   * 这个是**在原文件的字节后面追加**注释对象与改过的页对象，
///     原文件内容一字不动 —— 别的阅读器打开原文件就能看到批注。
///
/// 返回：新的 PDF 字节；`result.usedFullRebuild` 等诊断在
/// [PdfRewriteResult] 里（需要时直接调 `appendPdfAnnotations`）。
Future<Uint8List> writeBackPdfAnnotations({
  required Uint8List original,
  required PdfMarkupDoc doc,
  required List<PdfPageBitmap> pages,
}) async {
  final specs = <PdfAnnotationSpec>[];
  for (var i = 0; i < pages.length; i++) {
    if (doc.marksForPage(i).isEmpty) continue;
    specs.addAll(
      pdfAnnotationSpecsFromDoc(
        doc: doc,
        page: i,
        width: pages[i].width.toDouble(),
        height: pages[i].height.toDouble(),
      ),
    );
  }
  return appendPdfAnnotations(bytes: original, specs: specs).bytes;
}

/// 给用例/调用方一个显式的"批注对象种类"清单（便于台账与文档对齐）。
const List<String> kPdfAnnotSubtypes = ['/Square', '/Ink', '/Text'];

/// 说明：`pdf` 包没有 `/Highlight` —— 高亮用 `/Square` 近似。
/// 这条常量是给文档与用例**钉死**这个事实的，不允许悄悄改写。
const bool kPdfHasHighlightSubtype = false;
