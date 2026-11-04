// 第 272 轮只读探针：Office 模板正文「当前路径（书籍阅读器）vs 高阶路径
// （Office OOXML 阅读器）」的**保真度实测**。纯 Dart，不依赖 Flutter。
//
// 运行（仓库根目录）：
//   dart run tool/office_template_preview_probe.dart
//
// 样本：真机只读导出的模板 OOXML（`Office.Export:download {object_id, format:"ms"}`）：
//   /tmp/r265_post_doc_ms.bin          Meeting minutes.docx   13,039 B
//   /tmp/r265_post_sheet_ms.bin        Project timeline.xlsx  14,536 B
//   /tmp/r265_post_presentation_ms.bin Countryside.pptx       29,008 B
//
// 结论口径（详见 docs/office-template-gallery.md §10）：
//   * 书籍阅读器只保留 粗体/斜体/标题级别/图片/表格 ⇒ 字号/颜色/字体/对齐/行距/
//     页边距/页眉页脚/列宽全部丢失；
//   * Office OOXML 阅读器（`ODocxDocument` / `OSlidesDeck` / `OSheetWorkbook`）
//     保留上述全部 ⇒ 模板预览应当改走它们（本探针给出逐项数字）。
import 'dart:io';

import 'package:synhub/src/data/office_native/oslides_ooxml.dart';
import 'package:synhub/src/features/files/book_office.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/office/office_doc_ooxml.dart';

void main() {
  final docx = File('/tmp/r265_post_doc_ms.bin').readAsBytesSync();
  final xlsx = File('/tmp/r265_post_sheet_ms.bin').readAsBytesSync();
  final pptx = File('/tmp/r265_post_presentation_ms.bin').readAsBytesSync();

  print('=== DOCX (Meeting minutes.docx, ${docx.length} B) ===');
  final d = ODocxDocument.parse(docx);
  if (d == null) {
    print('  ODocxDocument.parse -> null');
  } else {
    final ps = d.allParagraphs.toList();
    final runs = ps.expand((p) => p.runs).toList();
    print('  段落 ${ps.length} / run ${runs.length} / 块 ${d.blocks.length}');
    print('  带字号 run = ${runs.where((r) => r.sizePt != null).length}');
    print('  带颜色 run = ${runs.where((r) => r.color != null).length}');
    print('  带字体 run = ${runs.where((r) => r.fontFamily != null).length}');
    print('  粗体 run = ${runs.where((r) => r.bold).length}'
        ' / 斜体 ${runs.where((r) => r.italic).length}');
    print('  对齐 != left 的段落 = '
        '${ps.where((p) => p.alignment != 'left').length}');
    print('  有行距声明的段落 = '
        '${ps.where((p) => p.lineHeight != null || p.linePx != null).length}');
    print('  有编号/项目符号的段落 = '
        '${ps.where((p) => p.numId != null).length}');
    print('  表格数 = ${d.blocks.where((b) => b.table != null).length}');
    print('  图片数(media) = ${d.media.length}');
    print('  页眉 ${d.headers.length} / 页脚 ${d.footers.length}');
    print('  页面 ${d.pageSetup.widthPx.toStringAsFixed(1)}x'
        '${d.pageSetup.heightPx.toStringAsFixed(1)}px '
        'margin ${d.pageSetup.marginLeftPx.toStringAsFixed(1)}/'
        '${d.pageSetup.marginTopPx.toStringAsFixed(1)}');
    print('  heading>=1 段落 = ${ps.where((p) => p.headingLevel > 0).length}');
  }
  final bd = parseDocxBook(docx, format: BookFormat.docx);
  var htmlLen = 0, hasSize = 0, hasColor = 0, hasFamily = 0, hasAlign = 0;
  for (final c in bd.chapters) {
    htmlLen += c.html.length;
    hasSize += 'font-size'.allMatches(c.html).length;
    hasColor += 'color:'.allMatches(c.html).length;
    hasFamily += 'font-family'.allMatches(c.html).length;
    hasAlign += 'text-align'.allMatches(c.html).length;
  }
  print('  --- 书籍阅读器（当前路径）---');
  print('  章节 ${bd.chapters.length} / html $htmlLen B / 资源 ${bd.resources.length}');
  print('  html 里 font-size=$hasSize color=$hasColor '
      'font-family=$hasFamily text-align=$hasAlign');
  print('  页眉页脚 = 不读（0）');

  print('');
  print('=== PPTX (Countryside.pptx, ${pptx.length} B) ===');
  final deck = OSlidesDeck.parse(pptx);
  if (deck == null) {
    print('  OSlidesDeck.parse -> null');
  } else {
    print('  画布 ${deck.widthPx.toStringAsFixed(0)}x'
        '${deck.heightPx.toStringAsFixed(0)}px 16:9=${deck.isWidescreen}');
    print('  幻灯片 ${deck.slides.length} / 版式 ${deck.layoutCount} / '
        '母版 ${deck.masterCount}');
    print('  形状 ${deck.shapeCount} / 几何继承自版式母版 '
        '${deck.inheritedGeometryCount}');
    print('  媒体 ${deck.media.length} / svg ${deck.svgMediaCount} / '
        '不可渲染矢量 ${deck.unrenderableVectorCount}');
    for (final s in deck.slides) {
      print('  页${s.pageNumber}: 形状 ${s.shapes.length} 可绘 '
          '${s.drawableShapeCount} 占位符 ${s.placeholderCount} 继承几何 '
          '${s.inheritedGeometryCount} 背景 '
          '#${s.backgroundArgb.toRadixString(16).padLeft(8, '0')} '
          '继承背景=${s.backgroundInherited} 文本 ${s.plainText.length}B');
    }
  }
  final bp = parsePptxBook(pptx, format: BookFormat.pptx);
  print('  --- 书籍阅读器（当前路径）---');
  print('  章节 ${bp.chapters.length} / 资源 ${bp.resources.length}');
  for (final c in bp.chapters) {
    final flat = c.html.replaceAll(RegExp(r'\s+'), ' ');
    print('  章「${c.title}」html ${c.html.length} B: '
        '${flat.substring(0, flat.length > 140 ? 140 : flat.length)}');
  }
  print('  几何/背景/母版 = 不读（0）');

  // XLSX：解析器 `office_sheet_xlsx.dart` → `office_sheet_ooxml_color.dart`
  // 依赖 Flutter（dart:ui），故不放本纯 Dart 探针；其保真度由
  // test/office_template_preview_fidelity_test.dart 的 widget 用例覆盖。
}
