// ★★★ r379（DA28）：`.txt` 长文**单章整本排版 ⇒ 真机 ANR** 的守卫。
//
// 真机事实（HONOR LGE-AN10 / Android 12，2/2 复现，`docs/evidence-r379/`）：
//   点 1.5 MB 的 `r379big.txt`（全文只有**单换行**、没有空行）⇒ 页面转圈，
//   随后系统弹 `SynHub isn't responding`（`uiautomator dump` 读到
//   `CLOSE APP` / `WAIT` 两个按钮，dump 5118 B 两次逐字节相同），
//   连 `keyevent 4` 都消费不掉 ⇒ **UI 线程被排版卡住**，不是"网络慢"。
//
// 根因：`_parasFromPlainText` 只在**空行**分段 ⇒ 整份文本成一段；
//   而 `bookChapterize` 的按大小切块是"每写完一段才检查长度" ⇒
//   单段超长就直接进同一章。
//
// 守卫口径：**任何一章的 HTML 都不许超过 2 × `kTextSplitTarget`**
//   （每个段块 ≤ target，切块判断在同一段之后 ⇒ 最多 target + 一块）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/files/book_text.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/ai/text_ai.dart' show bookPlainText;

/// 生成**单换行**的长文本（模拟日志/导出文本：没有任何空行 ⇒ 只有一个"段"）
String longText(int approxBytes) {
  const line = 'r379 big text line 1234567890 abcdefghijklmnopqrstuvwxyz\n';
  final b = StringBuffer();
  while (b.length < approxBytes) {
    b.write(line);
  }
  return b.toString();
}

String plainOf(BookChapter c) => bookPlainText(c.html);

void main() {
  test('1.5 MB 单换行 .txt：不再整本一章，每章都被切到上限内', () {
    final text = longText(1500 * 1024);
    final book = parseTxtBook(
      utf8.encode(text),
      format: BookFormat.txt,
      title: 'r379big.txt',
    );
    // 修前：chapters == 1（整本 1.5 MB 一章）⇒ 真机 ANR
    expect(book.chapters.length, greaterThan(1));
    final worst = book.chapters
        .map((c) => c.html.length)
        .reduce((a, b) => a > b ? a : b);
    expect(
      worst,
      lessThanOrEqualTo(2 * kTextSplitTarget),
      reason: '★ 任何一章都不许把几百 KB 的文本交给渲染器排版',
    );
    // 数量守恒：切块不许丢字（'<p>'/'<br>' 之外的可打印字符一个不能少）
    int printable(String s) =>
        s.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\s'), '').length;
    final inChars = printable(text);
    final outChars = book.chapters.map((c) => printable(c.html)).reduce((a, b) => a + b);
    expect(outChars, inChars, reason: '★ 切块只许换行，不许吞内容');
  });

  test('100 KB 单换行 .txt：仍是"正文"一章（小文件体验不变）', () {
    final text = longText(100 * 1024);
    final book = parseTxtBook(utf8.encode(text), format: BookFormat.txt);
    expect(book.chapters.length, 1);
    expect(book.chapters.single.generatedUnit, BookGeneratedUnit.body);
  });

  test('一条 300 KB 的长**行**（没有换行可切）：退化为按字符硬切且不丢内容', () {
    final text = 'A' * (300 * 1024);
    final book = parseTxtBook(utf8.encode(text), format: BookFormat.txt);
    expect(book.chapters.length, greaterThan(1));
    for (final c in book.chapters) {
      expect(c.html.length, lessThanOrEqualTo(2 * kTextSplitTarget));
    }
    final joined = book.chapters.map((c) => plainOf(c)).join();
    expect(joined.replaceAll(RegExp(r'\s'), '').length, text.length);
  });

  test('有 ≥2 个标题的文本：仍按标题分章（不被大小切块取代）', () {
    final text = StringBuffer();
    for (var i = 1; i <= 3; i++) {
      // 标题要**独占一个空行分隔的段**（`_headingTitle` 收到多行会判 null：
      // 这是既有口径 —— 宁可少分一章，也不把一句正文当标题）
      text.write('第 $i 章 标题$i\n\n');
      text.write('${'正文 content ' * 50}\n\n');
    }
    final book = parseTxtBook(utf8.encode(text.toString()), format: BookFormat.txt);
    expect(book.chapters.length, 3);
    expect(book.chapters.first.title, contains('标题1'));
  });
}
