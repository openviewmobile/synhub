// 书内搜索（纯本地）：跨章命中 + 片段 + 章内位置。
//
// 放这里的理由：它是**书的结构**上的检索（章 → 命中 → 位置），不是通用文本
// 工具；AI 那层的 `bookPlainText` 只是被复用的"HTML → 纯文本"转换。
//
// 位置用 `ratio`（命中点在本章纯文本里的字符占比）而不是字符偏移：
// 阅读器要的是"滚到附近"，Quill 那边按比例估算滚动量最稳（见
// `_ChapterBodyState._seekTo`）。
library;

import '../ai/text_ai.dart' show bookPlainText;
import 'file_book.dart';
import 'files_i18n.dart';

/// 一条命中
class BookSearchHit {
  const BookSearchHit({
    required this.chapter,
    required this.ratio,
    required this.snippet,
    required this.start,
  });

  /// 第几章（0 基）
  final int chapter;

  /// 章内位置（0..1）
  final double ratio;

  /// 上下文片段（命中词前后各留一点）
  final String snippet;

  /// 命中在**本章纯文本**里的起始下标
  final int start;
}

/// 在一本书里搜 [query]，返回最多 [limit] 条命中（按章节顺序）。
///
/// 大小写不敏感（英文书名常见）；中文没有大小写，走同一套 `toLowerCase`。
List<BookSearchHit> searchBook(
  BookContent book,
  String query, {
  int limit = 200,
}) {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final needle = q.toLowerCase();
  final hits = <BookSearchHit>[];
  for (var i = 0; i < book.chapters.length; i++) {
    final text = bookPlainText(book.chapters[i].html);
    if (text.isEmpty) continue;
    final lower = text.toLowerCase();
    var from = 0;
    while (hits.length < limit) {
      final at = lower.indexOf(needle, from);
      if (at < 0) break;
      hits.add(
        BookSearchHit(
          chapter: i,
          ratio: text.isEmpty ? 0 : (at / text.length).clamp(0.0, 1.0),
          snippet: snippetAt(text, at, q.length),
          start: at,
        ),
      );
      // 同一个词连续出现时不重复列（步长至少一个词长）
      from = at + q.length;
    }
    if (hits.length >= limit) break;
  }
  return hits;
}

/// 取命中点前后各 30 字，命中的词用「」括起来，方便一眼认出。
String snippetAt(String text, int at, int len, {int pad = 30}) {
  final start = (at - pad).clamp(0, text.length);
  final end = (at + len + pad).clamp(0, text.length);
  final head = start > 0 ? '…' : '';
  final tail = end < text.length ? '…' : '';
  final before = text.substring(start, at);
  final hit = text.substring(at, (at + len).clamp(0, text.length));
  final after = text.substring((at + len).clamp(0, text.length), end);
  final open = fsT('bookSearchHitOpen', '「');
  final close = fsT('bookSearchHitClose', '」');
  return '$head$before$open$hit$close$after$tail'.replaceAll(RegExp(r'\s+'), ' ');
}
