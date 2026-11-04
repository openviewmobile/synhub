// 电子书阅读器的本地状态（Drift）：**阅读进度 + 书签/划线**。
//
// 为什么不塞 `app_settings` 的键值里：
//   * 书签是"一本书 N 条"，需要按书查、按时间排、单条删 —— 键值里只能
//     塞 JSON 数组，越读越慢（每次进书都要解析整本）；
//   * 进度要按 `updatedAt` 排（"最近在读"），键值表给不了。
//
// 键（`bookKey`）的选择：能唯一定位"这本书从哪来"就行 ——
//   * FileStation 里的书：`fs:<path>`（路径 + 大小/时间会变，所以只用路径）
//   * Drive 里的书：`drive:<link_id>`（`permanent_link`，Drive 的稳定 id）
// 两种来源同名文件不会串。
library;

import 'package:drift/drift.dart';

import 'database.dart';

/// 一本书的阅读进度
class BookProgress {
  const BookProgress({
    required this.bookKey,
    required this.title,
    required this.format,
    required this.chapter,
    required this.scroll,
    required this.chapterCount,
    required this.updatedAt,
    this.sourceUrl = '',
  });

  final String bookKey;
  final String title;
  final String format;
  final int chapter;

  /// 章内滚动百分比（0..1）
  final double scroll;
  final int chapterCount;
  final int updatedAt;

  /// 重新打开这本书用的鉴权直链（Drive 来源才有；FileStation 靠 [bookKey] 的路径）
  final String sourceUrl;

  /// 整本读完的百分比（估算）
  ///
  /// ★★★ r316c 真机缺陷（已修）：**漫画/图片包没有"章"**（CBR/CBZ/CBT/DJVU 位图
  /// 的 `chapterCount` 记 0 是既有约定），而这里原来 `chapterCount <= 0` 直接
  /// `return 0` ⇒ 工作台「继续阅读」对漫画**永远显示 0%**。真机逐字：读到 `CBR · 3/4`
  /// 之后冷启动，卡片仍是 `r316comic | 0% read`。翻页书的 `scroll` 本身就是
  /// "读到第几页 / 共几页"，直接当整本百分比即可。
  double get percent {
    final s = scroll.clamp(0.0, 1.0);
    if (chapterCount <= 0) return s;
    final done = chapter + s;
    return (done / chapterCount).clamp(0.0, 1.0);
  }
}

/// 一条书签 / 划线
class BookMark {
  const BookMark({
    required this.id,
    required this.bookKey,
    required this.chapter,
    required this.scroll,
    required this.excerpt,
    required this.note,
    required this.createdAt,
  });

  final int id;
  final String bookKey;
  final int chapter;
  final double scroll;
  final String excerpt;

  /// 用户批注（空 = 纯书签）
  final String note;
  final int createdAt;

  bool get hasNote => note.trim().isNotEmpty;
}

/// 阅读进度的键：FileStation 来源
String fsBookKey(String path) => 'fs:$path';

/// 阅读进度的键：Drive 来源（用 `permanent_link`，比路径稳）
String driveBookKey(String linkId) => 'drive:$linkId';

class BookStore {
  BookStore(this.db);

  final ChatDatabase db;

  // ---------------------------------------------------------------- 进度

  Future<BookProgress?> progressOf(String bookKey) async {
    final row = await (db.select(
      db.bookProgressRows,
    )..where((t) => t.bookKey.equals(bookKey))).getSingleOrNull();
    if (row == null) return null;
    return BookProgress(
      bookKey: row.bookKey,
      title: row.title,
      format: row.format,
      chapter: row.chapter,
      scroll: row.scroll,
      chapterCount: row.chapterCount,
      updatedAt: row.updatedAt,
      sourceUrl: row.sourceUrl,
    );
  }

  /// 最近的 N 本（给"继续阅读"用）
  Future<List<BookProgress>> recent({int limit = 12}) async {
    final rows =
        await (db.select(db.bookProgressRows)
              ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
              ..limit(limit))
            .get();
    return [
      for (final r in rows)
        BookProgress(
          bookKey: r.bookKey,
          title: r.title,
          format: r.format,
          chapter: r.chapter,
          scroll: r.scroll,
          chapterCount: r.chapterCount,
          updatedAt: r.updatedAt,
          sourceUrl: r.sourceUrl,
        ),
    ];
  }

  /// 写进度（upsert）。
  ///
  /// 只在"真的动了"的时候写：同一个章节 + 位置差 < 1% 的重复调用直接跳过，
  /// 免得滚动时每帧都落库。定位串变了不算"没动"（老进度补 Drive 直链时要写进去）。
  Future<void> saveProgress({
    required String bookKey,
    required String title,
    required String format,
    required int chapter,
    required double scroll,
    required int chapterCount,
    String sourceUrl = '',
    DateTime? now,
  }) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final current = await progressOf(bookKey);
    // 定位串只增不减：新值空着时保留旧的（FileStation 重开不该抹掉之前的 Drive 直链）
    final src = sourceUrl.isEmpty ? (current?.sourceUrl ?? '') : sourceUrl;
    if (current != null &&
        current.chapter == chapter &&
        (current.scroll - scroll).abs() < 0.01 &&
        current.chapterCount == chapterCount &&
        current.sourceUrl == src) {
      return;
    }
    await db
        .into(db.bookProgressRows)
        .insertOnConflictUpdate(
          BookProgressRowsCompanion.insert(
            bookKey: bookKey,
            title: Value(title),
            format: Value(format),
            chapter: Value(chapter),
            scroll: Value(scroll),
            chapterCount: Value(chapterCount),
            updatedAt: Value(at),
            sourceUrl: Value(src),
          ),
        );
  }

  Future<void> clearProgress(String bookKey) async {
    await (db.delete(
      db.bookProgressRows,
    )..where((t) => t.bookKey.equals(bookKey))).go();
  }

  // ---------------------------------------------------------------- 书签

  Future<List<BookMark>> marksOf(String bookKey) async {
    final rows =
        await (db.select(db.bookMarkRows)
              ..where((t) => t.bookKey.equals(bookKey))
              ..orderBy([
                (t) => OrderingTerm.asc(t.chapter),
                (t) => OrderingTerm.asc(t.scroll),
              ]))
            .get();
    return [for (final r in rows) _mark(r)];
  }

  /// 加书签/划线，返回新行 id
  Future<int> addMark({
    required String bookKey,
    required int chapter,
    required double scroll,
    String excerpt = '',
    String note = '',
    DateTime? now,
  }) async {
    return db
        .into(db.bookMarkRows)
        .insert(
          BookMarkRowsCompanion.insert(
            bookKey: bookKey,
            chapter: Value(chapter),
            scroll: Value(scroll),
            excerpt: Value(excerpt),
            note: Value(note),
            createdAt: Value((now ?? DateTime.now()).millisecondsSinceEpoch),
          ),
        );
  }

  Future<void> deleteMark(int id) async {
    await (db.delete(db.bookMarkRows)..where((t) => t.id.equals(id))).go();
  }

  Future<void> setMarkNote(int id, String note) async {
    await (db.update(db.bookMarkRows)..where((t) => t.id.equals(id))).write(
      BookMarkRowsCompanion(note: Value(note)),
    );
  }

  /// 删除整本书的书签（书被删掉时收尾用）
  Future<void> clearMarks(String bookKey) async {
    await (db.delete(
      db.bookMarkRows,
    )..where((t) => t.bookKey.equals(bookKey))).go();
  }

  BookMark _mark(BookMarkRow r) => BookMark(
    id: r.id,
    bookKey: r.bookKey,
    chapter: r.chapter,
    scroll: r.scroll,
    excerpt: r.excerpt,
    note: r.note,
    createdAt: r.createdAt,
  );
}
