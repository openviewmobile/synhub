// 「导出到笔记」：把选中内容变成一则 NoteStation 笔记（E2）。
//
// 分两层，**离线可测**：
//   * [buildBookNoteDraft] 是纯函数 —— 生成标题 / 标签 / Markdown / HTML，
//     单测直接断言这四个字段（不联网、不碰 Riverpod）；
//   * [BookNoteExporter] 只负责编排已有的 NoteStation 接口：
//     `Notebook/list` → （没有笔记本就 `Notebook/create`）→ `Note/create`
//     → `Note/set(tag: …)`（标签没有独立创建接口，靠 set 隐式建，见 note_api 注释）。
//
// 正文用 Markdown 管线（`<!--dsh-md:1:…-->` 里夹源码）：官方 App / 网页端
// 打开是排好版的笔记，回到我们这边还能无损拿回 Markdown 源码。
import '../../core/i18n/l10n.dart';
import '../../data/note_api.dart';
import '../notes/note_markdown.dart';

/// 一则"读书摘录"笔记的完整草稿
class BookNoteDraft {
  const BookNoteDraft({
    required this.title,
    required this.tags,
    required this.markdown,
    required this.notebookTitle,
  });

  /// 笔记标题（书名 + 章节）
  final String title;

  /// 标签：书名 / 读书笔记 / 章节
  final List<String> tags;

  /// Markdown 源码（写进笔记的"源"）
  final String markdown;

  /// 没有笔记本时新建的笔记本名
  final String notebookTitle;

  /// 落库用的 NoteStation HTML（可见正文 + 源码注释）
  String get html => markdownToNoteHtml(markdown);

  bool get isEmpty => markdown.trim().isEmpty;
}

/// 由选中内容生成草稿（纯函数）。
///
/// [percent] 是章内位置百分比（0..1，可空）——"位置标签"就靠它，
/// 以后按标签定位能直接跳回来。
BookNoteDraft buildBookNoteDraft({
  required AppText t,
  required String bookTitle,
  required String chapterTitle,
  required int chapter,
  required int chapterCount,
  required String selection,
  String note = '',
  int? percent,
}) {
  final book = bookTitle.trim().isEmpty ? t.bookUntitled : bookTitle.trim();
  final chapterLabel = chapterTitle.trim();
  final where = percent == null
      ? t.bookExportWhere(book, chapter + 1)
      : t.bookExportWherePercent(book, chapter + 1, percent);
  final source = chapterLabel.isEmpty
      ? t.bookExportSource(where, chapterCount)
      : t.bookExportSourceNamed(where, chapterLabel, chapterCount);

  final buf = StringBuffer();
  if (selection.trim().isNotEmpty) {
    // 原文用引用块：笔记里一眼能分清"书里的话"和"我写的话"
    for (final line in selection.trim().split('\n')) {
      buf.writeln('> ${line.trim()}');
    }
  }
  if (note.trim().isNotEmpty) {
    if (buf.isNotEmpty) buf.writeln();
    buf.writeln(note.trim());
  }
  if (buf.isNotEmpty) buf.writeln();
  buf.writeln('—— $source');

  return BookNoteDraft(
    title: t.bookExportTitle(book, chapter + 1),
    tags: [book, t.bookExportTagReader, t.bookExportTagChapter(chapter + 1)],
    markdown: buf.toString().trim(),
    notebookTitle: t.bookExportNotebook,
  );
}

/// 导出结果
typedef BookNoteExportResult = ({
  String objectId,
  String notebookTitle,

  /// 标签是否真的写上了（`Note/set` 成功才算）
  bool tagged,
});

/// 把草稿写进 NAS 的笔记应用
class BookNoteExporter {
  BookNoteExporter(this.api);

  final NoteStationApi api;

  /// 目标笔记本：优先复用已有笔记本；一个都没有才新建（不给用户塞一整排空本子）
  Future<({String id, String title, bool created})> ensureNotebook(
    String preferredTitle,
  ) async {
    final notebooks = await api.listNotebooks();
    if (notebooks.isNotEmpty) {
      return (
        id: notebooks.first.objectId,
        title: notebooks.first.title,
        created: false,
      );
    }
    final title = preferredTitle.trim().isEmpty ? 'Notes' : preferredTitle;
    final id = await api.createNotebook(title);
    return (id: id, title: title, created: true);
  }

  /// 导出：建笔记 → 打标签。返回笔记 id 与所在笔记本。
  ///
  /// 标签走 `Note/set`：`Note/create` 不接受 `tag`，且标签**没有独立创建接口**
  /// （`Tag/set` 只能改名）—— 这是 NoteStation 的既有语义，不是我们少做一步。
  Future<BookNoteExportResult> export(BookNoteDraft draft) async {
    final notebook = await ensureNotebook(draft.notebookTitle);
    final created = await api.createNote(
      title: draft.title,
      parentId: notebook.id,
      html: draft.html,
    );

    var tagged = false;
    if (draft.tags.isNotEmpty) {
      // `create` 不一定回 ver（不同服务端版本不一样）：拿不到就 `get` 一次，
      // 否则 `set` 会被乐观锁拒掉，标签静默丢失（真机上很难查出原因）。
      var ver = created.ver;
      if (ver.isEmpty) {
        try {
          ver = (await api.getNote(created.objectId)).ver;
        } catch (_) {
          ver = '';
        }
      }
      if (ver.isNotEmpty) {
        await api.setNote(
          objectId: created.objectId,
          ver: ver,
          tags: draft.tags,
        );
        tagged = true;
      }
    }

    return (
      objectId: created.objectId,
      notebookTitle: notebook.title,
      tagged: tagged,
    );
  }
}
