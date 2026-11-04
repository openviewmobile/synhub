// 「继续阅读」——把一条**已落库的阅读进度**还原成一个能直接打开的阅读页。
//
// 复用阅读器 E1 的那一套：进度存在 `BookStore`（Drift `book_progress_rows`），
// `FileBookStage` 进去后会自己 `progressOf(bookKey)` 定位到上次那一章。
// 这里只负责把"进度 → 文件条目"翻译出来，**不另立一套进度**。
//
// 两种来源的重开方式：
//   * FileStation（`bookKey = fs:<path>`）：路径本身就能取字节，直链为空；
//   * Drive（`bookKey = drive:<permanent_link>`）：路径不是 FileStation 路径，
//     靠进度里顺手存下的 `sourceUrl`（进书时的鉴权直链）重开。
library;

import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/local/book_store.dart';
import 'file_book_view.dart';

/// 进度 → 阅读器条目（纯函数，便于离线断言重开参数）。
///
/// 扩展名必须还原对：`FileBookStage` 靠 `entry.extension` 挑解析器。
FileEntryDto bookEntryForResume(BookProgress p) {
  final format = p.format.trim().toLowerCase();
  final suffix = format.isEmpty ? '' : '.$format';
  if (p.bookKey.startsWith('fs:')) {
    final path = p.bookKey.substring('fs:'.length);
    final name = path.split('/').last;
    if (name.isNotEmpty) return FileEntryDto(name: name, path: path);
    // 路径缺失的坏记录：退回书名，至少能解析出格式
    return FileEntryDto(name: '${p.title}$suffix', path: p.bookKey);
  }
  final title = p.title.trim().isEmpty ? p.bookKey : p.title.trim();
  return FileEntryDto(name: '$title$suffix', path: p.bookKey);
}

/// 卡片上的"第几章 / 百分比"。章数未知时只给百分比。
String bookProgressLabel(AppText t, BookProgress p) {
  final pct = (p.percent * 100).round().clamp(0, 100);
  final total = p.chapterCount;
  if (total <= 0) return t.bookContinuePercent(pct);
  final n = (p.chapter + 1).clamp(1, total);
  return t.bookContinueProgress(n, total, pct);
}

/// 从工作台/文件页打开"继续阅读"（走根导航，盖住外壳底栏）
Future<void> openBookProgress(BuildContext context, BookProgress progress) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(builder: (_) => BookResumePage(progress: progress)),
  );
}

/// 只有阅读器本体的轻量页面：标题 = 书名，正文交给 [FileBookStage]
/// （进去后它会按 [BookProgress.bookKey] 自动恢复到上次那一章）。
class BookResumePage extends StatelessWidget {
  const BookResumePage({super.key, required this.progress});

  final BookProgress progress;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final title = progress.title.trim().isEmpty
        ? t.bookUntitled
        : progress.title;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              bookProgressLabel(t, progress),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      body: FileBookStage(
        entry: bookEntryForResume(progress),
        bytesUrl: progress.sourceUrl.isEmpty ? null : progress.sourceUrl,
        bookKey: progress.bookKey,
      ),
    );
  }
}
