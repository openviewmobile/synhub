// 用**真实世界的 EPUB**验目录解析（Project Gutenberg 的 Alice，EPUB2 与 EPUB3 各一份）
// ignore_for_file: avoid_print
import 'dart:io';
import 'package:synhub/src/features/files/file_book.dart';

void main(List<String> args) {
  for (final path in args) {
    final bytes = File(path).readAsBytesSync();
    final r = parseBook(BookFormat.epub, bytes);
    print('== $path ok=${r.ok} err=${r.error}');
    final b = r.content;
    print(
      '   书名=${b.title} 作者=${b.author} 段数=${b.chapters.length} '
      '目录=${b.toc.length} 资源=${b.resources.length}',
    );
    for (final e in b.toc.take(12)) {
      print('   ${'  ' * e.depth}· ${e.title}  → 第 ${e.chapterIndex + 1} 段');
    }
    if (b.toc.length > 12) print('   …… 还有 ${b.toc.length - 12} 条');
    if (b.chapters.isNotEmpty) {
      print('   第一段标题=${b.chapters.first.title}');
      final text = b.chapters.first.html
          .replaceAll(RegExp(r"<[^>]*>"), ' ')
          .trim();
      print(
        '   第一段前 120 字=${text.length > 120 ? text.substring(0, 120) : text}',
      );
    }
  }
}
