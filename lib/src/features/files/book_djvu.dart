// DJVU（.djvu）**内容抽取层** —— 纯 Dart，不 import flutter / l10n。
//
// 容器/文本层在 `djvu_archive.dart`，位图在 `djvu_jb2.dart` / `djvu_iw44.dart`，
// 合成渲染与 PNG 在 `djvu_render.dart`。这里负责把"页"变成和 CBZ/CHM **同一套**
// `BookContent`，于是翻页 / 缩放 / 进度 / 封面 / 目录面板全部免费复用。
//
// **两种呈现路线**（DJVU 本质是"扫描位图 + 可选隐藏文本层"）：
//
//   * **位图路线**（页里有 Sjbz/BG44/FG44/TH44）：按页合成成 PNG 放进
//     `BookContent.pages`，走和 CBZ/CBR 完全相同的 `_ComicView` 翻页管线；
//   * **文本路线**（页里没有位图、但有 TXTz/TXTa 文本层）：把隐藏文本层抽成
//     `chapters`（每页一章，走现有富文本阅读器，能搜索/朗读）。
//
// 选择规则：**只要有一页能出位图**就走位图路线（忠实还原扫描件）；出不了位图
// 的页给白页占位。整本都没有位图时才走文本路线。渲染过程中遇到"认识但做不到"
// 的变体（Smmr/BGjp/…）→ 整本报 [BookParseErrorKind.unsupportedCompression]，
// 绝不吐半截或乱码。
//
// **边界与验证状态（诚实声明）**：
//   * 容器 / INFO / 文本层 / 多页 DIRM / NAVM / 坏样本：**已用自造 fixture 端到端证明**；
//   * JB2（Sjbz 掩码）：**自造编码器 ↔ 解码器逐像素往返**已证明；另有
//     `tool/djvu_jb2_selftest.dart` 对 DjVuLibre 参考码流的交叉验证；
//   * IW44（BG44/FG44/TH44）：**已用 6 份真实 .djvu 对 DjVuLibre 3.5.28 的 `ddjvu`
//     做像素级对照**（`tool/djvu_real_compare.dart`）：页数、INFO 尺寸逐份一致，
//     抽样页 meanAbs 0.0–1.6、墨迹 IoU 0.982–1.000。对照用的 oracle 是本地源码构建
//     （brew 装不上），只在 /tmp，**不进仓库**；
//   * 真实样本不入库（体积 + 版权）：`/tmp/djvu-samples/` 不在时相关用例整组跳过，
//     干净检出不会因此变红；
//   * 扫描（位图）路线的 `BookContent.toc` 已接 NAVM 书签：书签 url → 页索引
//     （`chapterIndex` 对位图书就是页索引，见 `_scannedBookToc`）；含
//     `#<page-id>`（DIRM 的 id/name/title）与 `#<page-number>` 两种形态。
//   * 仍然没做的：BM44/PM44（单色位平面 IW44）真实样本未遇到。
//   * 解不开的变体给明确错误，绝不吐乱码或半截。
import 'dart:typed_data';

import 'djvu_archive.dart';
import '../../core/i18n/data_text.dart';
import 'djvu_iw44.dart';
import 'djvu_render.dart';
import 'file_book.dart';
import 'files_i18n.dart';

/// 一次性合成到内存里的总 PNG 上限（扫描书页数多、体积大，必须有个闸）
const int _kMaxTotalRendered = 192 * 1024 * 1024;

/// 单页像素数上限（约 8000×8000）——超过就别硬渲染了
const int _kMaxPixelsPerPage = 64 * 1024 * 1024;

// ------------------------------------------------------------------ 入口

/// 解析 DJVU。**不抛异常**：失败返回带 `error` 的 [BookParseResult]。
BookParseResult parseDjvuBook(List<int> bytes, {required BookFormat format}) {
  try {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final archive = DjvuArchive.open(data);
    final doc = _buildDocument(archive);
    if (doc.pages.isEmpty && doc.chapters.isEmpty) {
      return BookParseResult(
        BookContent(format: format),
        error: fsT(
          'bookDjvuNoPages',
          '这本 DJVU 里没有可读的页（既没有位图也没有文本层）',
        ),
        errorKind: BookParseErrorKind.parseFailed,
      );
    }
    return BookParseResult(
      BookContent(
        format: format,
        pages: doc.pages,
        chapters: doc.chapters,
        toc: doc.toc,
      ),
    );
  } on DjvuUnsupportedException catch (e) {
    // 能力边界 → 界面文案复用 `bookUnsupportedFormat`（**没有新增 ARB key**）
    return BookParseResult(
      BookContent(format: format),
      error: e.message,
      errorKind: BookParseErrorKind.unsupportedCompression,
      reason: BookUnsupportedReason.compression,
    );
  } catch (_) {
    return BookParseResult(
      BookContent(format: format),
      error: fsT('bookDjvuParseFailed', '这本 DJVU 解析失败（文件可能损坏）'),
      errorKind: BookParseErrorKind.parseFailed,
    );
  }
}

/// 从 DJVU 里抠封面字节（拿不到 → null，**不抛**）。
///
/// 优先 `FORM:THUM` 里的 `TH44` 缩略图（IW44），其次渲染第一页。
/// 体积/魔数校验由调用方（`book_cover.dart`）统一收口。
Uint8List? djvuCoverBytes(Uint8List bytes) {
  try {
    final archive = DjvuArchive.open(bytes);
    // 1) THUM/TH44 缩略图
    if (archive.thumbnail.isNotEmpty) {
      // 两种语义：
      //   * 单页文件：`thumbnail` 是同一张 TH44 的多个 slice（serial 0,1,2…），整体解；
      //   * 多页 bundled：每个 THUM 是**独立**的一张缩略图（各自 serial 0），
      //     整体解会撞 serial 校验，此时只取第一张。
      DjvuIw44Pixels t;
      try {
        t = djvuIw44Decode(archive.thumbnail);
      } on DjvuFormatException {
        t = djvuIw44Decode([archive.thumbnail.first]);
      }
      return djvuEncodePng(djvuIw44ToRgba(t));
    }
    // 2) 第一页
    if (archive.pages.isNotEmpty) {
      final p = archive.pages.first;
      if (p.hasBitmap) return djvuRenderPagePng(p);
    }
    return null;
  } catch (_) {
    // 列表滚动时会成批调用：任何一本坏书都不该把整条列表崩掉
    return null;
  }
}

// ------------------------------------------------------------------ 文档

class _DjvuDoc {
  _DjvuDoc({required this.pages, required this.chapters, required this.toc});
  final List<Uint8List> pages;
  final List<BookChapter> chapters;
  final List<BookTocEntry> toc;
}

_DjvuDoc _buildDocument(DjvuArchive archive) {
  // 先判断这本书能不能出位图（只要有一页有位图块就走位图路线）
  final hasAnyBitmap = archive.pages.any((p) => p.hasBitmap);
  if (hasAnyBitmap) {
    return _buildBitmapDocument(archive);
  }
  return _buildTextDocument(archive);
}

_DjvuDoc _buildBitmapDocument(DjvuArchive archive) {
  final rendered = <Uint8List>[];
  var total = 0;
  for (var i = 0; i < archive.pages.length; i++) {
    final page = archive.pages[i];
    // 没有位图块的页：按 INFO 尺寸给一张白页（不是"半截内容"，是这本页本来就没图）
    final png = page.hasBitmap
        ? _renderPageChecked(page, index: i)
        : _blankPagePng(page, index: i);
    total += png.length;
    if (total > _kMaxTotalRendered) {
      throw DjvuUnsupportedException(
        '这本 DJVU 渲染后超过 ${_kMaxTotalRendered ~/ (1024 * 1024)}MB，无法一次性内嵌',
      );
    }
    rendered.add(png);
  }
  // 位图路线：章节留空（翻页视图不消费章节），但**目录照接**：NAVM 书签 →
  // 页索引。`BookTocEntry.chapterIndex` 对位图书就是"第几页"。
  return _DjvuDoc(
    pages: rendered,
    chapters: const [],
    toc: _scannedBookToc(archive),
  );
}

/// 扫描（位图）路线的目录：NAVM 书签 → 页索引。
///
/// 位图路线没有 `chapters`，所以按翻页视图的契约把 [BookTocEntry.chapterIndex]
/// 填成 **0-based 页索引**（与 `BookContent.pages` 对齐）；层级沿用 NAVM 的 depth。
///
/// 书签 url 的三种形态（DjVu3 规范 §8.3.4.2.1 与 DjVuLibre `DjVuDocument::
/// set_file_aliases` 对 `#N` 的别名一致）：
///   * `#<component-id>`（DIRM 的 id / name / title）→ 查 [_urlToPageMap]；
///   * `#<page-number>`（**0-based**，DjVuLibre 用 `page_num` 直接做别名）→ 页码；
///   * `#<带符号整数>`（`#-1`/`#+1` 表示"上一页/下一页"）→ **不解析**（相对位移
///     在扁平目录里没有"当前页"作基准），宁可少一条也不跳错页；
///   * 空 url（根书签）/ 越界页码 / 认不出的 url → 跳过。
List<BookTocEntry> _scannedBookToc(DjvuArchive archive) {
  if (archive.bookmarks.isEmpty) return const [];
  final urlToPage = _urlToPageMap(archive);
  final pageCount = archive.pages.length;
  final out = <BookTocEntry>[];
  for (final b in archive.bookmarks) {
    final page =
        _resolveBookmarkPageRef(b.url, urlToPage) ??
        _resolveBookmarkPageNumber(b.url);
    if (page == null || page < 0 || page >= pageCount) continue;
    final title = b.title.trim();
    out.add(
      BookTocEntry(
        title: title.isNotEmpty ? title : _bookPageTitle(page + 1),
        depth: b.depth,
        chapterIndex: page,
      ),
    );
  }
  return out;
}

/// 书签 url → 页索引（`#<component-id>` / `<component-id>` 形态）。
///
/// 与文本路线复用的 [_resolveBookmarkPage] 分开是有意的：后者把 `#` **之前**当
/// 路径、`#` **之后**当锚点丢掉，所以 NAVM 最常见的 `#p0002.djvu`（整个 url 以
/// `#` 开头）在那里会被当成空 url 丢掉。文本路线按"零回归"要求保持原样，这里
/// 给扫描路线一份正确实现：
///   * `#p0002.djvu` / `p0002.djvu` / `p0002` → DIRM 的 id/name/title；
///   * `pages/p0002.djvu#anchor` → 取 basename，锚点忽略（页内锚点我们不做）。
int? _resolveBookmarkPageRef(String url, Map<String, int> urlToPage) {
  var u = url.trim();
  if (u.isEmpty) return null;
  final hash = u.indexOf('#');
  if (hash >= 0) u = u.substring(hash + 1); // 只要 `#` 之后的部分
  u = u.trim().replaceAll('\\', '/');
  while (u.startsWith('./')) {
    u = u.substring(2);
  }
  final slash = u.lastIndexOf('/');
  if (slash >= 0) u = u.substring(slash + 1);
  if (u.isEmpty) return null;
  final hit = urlToPage[u.toLowerCase()];
  if (hit != null) return hit;
  final dot = u.lastIndexOf('.');
  if (dot > 0) {
    final hit2 = urlToPage[u.substring(0, dot).toLowerCase()];
    if (hit2 != null) return hit2;
  }
  return null;
}

Uint8List _renderPageChecked(DjvuPage page, {required int index}) {
  final info = page.info;
  if (info != null && info.width * info.height > _kMaxPixelsPerPage) {
    throw DjvuUnsupportedException(
      '第 ${index + 1} 页尺寸 ${info.width}×${info.height} 太大，本阅读器不内嵌渲染',
    );
  }
  try {
    return djvuRenderPagePng(page);
  } on DjvuUnsupportedException {
    rethrow; // 能力边界：整本明确报"不支持"
  } on DjvuFormatException {
    rethrow; // 坏页：整本明确报"坏文件"
  }
}

Uint8List _blankPagePng(DjvuPage page, {required int index}) {
  final w = page.info?.width ?? 1000;
  final h = page.info?.height ?? 1400;
  return djvuBlankPagePng(w, h);
}

_DjvuDoc _buildTextDocument(DjvuArchive archive) {
  final chapters = <BookChapter>[];
  final pageToChapter = <int, int>{};
  for (var i = 0; i < archive.pages.length; i++) {
    final page = archive.pages[i];
    final text = page.text.trim();
    if (text.isEmpty) continue;
    final title = page.title.trim().isNotEmpty
        ? page.title.trim()
        : _bookPageTitle(i + 1);
    pageToChapter[i] = chapters.length;
    chapters.add(
      BookChapter(
        title: title,
        html: _textToHtml(text),
        href: 'page${i + 1}',
        // 标题是兜底生成的（页没有标题）→ 让界面本地化
        generatedUnit: page.title.trim().isEmpty
            ? BookGeneratedUnit.body
            : null,
      ),
    );
  }

  // 目录：优先 NAVM；拿不到就退化成"每页一条"的页码列表
  final toc = <BookTocEntry>[];
  if (archive.bookmarks.isNotEmpty) {
    final urlToPage = _urlToPageMap(archive);
    for (final b in archive.bookmarks) {
      final page = _resolveBookmarkPage(b.url, urlToPage);
      if (page == null) continue;
      final chapter = pageToChapter[page];
      if (chapter == null) continue;
      toc.add(
        BookTocEntry(
          title: b.title.trim().isNotEmpty
              ? b.title.trim()
              : _bookPageTitle(page + 1),
          depth: b.depth,
          chapterIndex: chapter,
        ),
      );
    }
  }
  if (toc.isEmpty) {
    for (var i = 0; i < archive.pages.length; i++) {
      final chapter = pageToChapter[i];
      if (chapter == null) continue;
      toc.add(
        BookTocEntry(
          title: chapters[chapter].title,
          depth: 0,
          chapterIndex: chapter,
        ),
      );
    }
  }

  return _DjvuDoc(pages: const [], chapters: chapters, toc: toc);
}

/// 导航 url → 页码。url 可能是 `page001.djvu`、`page001.djvu#anchor`、
/// 也可能是 DIRM 里的 id/name。
Map<String, int> _urlToPageMap(DjvuArchive archive) {
  final map = <String, int>{};
  void put(String key, int page) {
    final k = key.trim().toLowerCase();
    if (k.isEmpty) return;
    map.putIfAbsent(k, () => page);
  }

  final pageFiles = archive.directory.where((f) => f.isPage).toList();
  for (var i = 0; i < archive.pages.length; i++) {
    final p = archive.pages[i];
    put(p.title, i);
    if (i < pageFiles.length) {
      put(pageFiles[i].id, i);
      put(pageFiles[i].name, i);
      put(pageFiles[i].title, i);
    }
  }
  return map;
}

int? _resolveBookmarkPage(String url, Map<String, int> urlToPage) {
  var u = url.trim();
  if (u.isEmpty) return null;
  final hash = u.indexOf('#');
  if (hash >= 0) u = u.substring(0, hash);
  u = u.replaceAll('\\', '/');
  while (u.startsWith('./')) {
    u = u.substring(2);
  }
  final slash = u.lastIndexOf('/');
  if (slash >= 0) u = u.substring(slash + 1);
  if (u.isEmpty) return null;
  final hit = urlToPage[u.toLowerCase()];
  if (hit != null) return hit;
  // 去扩展名再试一次
  final dot = u.lastIndexOf('.');
  if (dot > 0) {
    final noExt = u.substring(0, dot);
    final hit2 = urlToPage[noExt.toLowerCase()];
    if (hit2 != null) return hit2;
  }
  return null;
}

/// 书签 url 的 `#<page-number>` 形态 → 0-based 页索引。
///
/// DjVu3 规范 §8.3.4.2.1：`#` 后可以跟"component file id 或 page number"，
/// page number 可带符号（`#-1` = 上一页、`#+1` = 下一页）。DjVuLibre
/// `DjVuDocument::set_file_aliases` 给第 `page_num` 页挂的别名是
/// `init_url + "#" + page_num`（`page_num` 是 0-based），所以无符号整数按
/// **0-based** 解释。
///
/// 带符号（相对位移）在"整本扁平目录"里没有基准页可算，返回 null（跳过该条），
/// 不猜成绝对页 —— 宁可少一条目录，也不把读者跳到错页。
int? _resolveBookmarkPageNumber(String url) {
  var u = url.trim();
  if (u.isEmpty) return null;
  final hash = u.indexOf('#');
  if (hash >= 0) u = u.substring(hash + 1);
  u = u.trim();
  if (u.isEmpty) return null;
  if (u.startsWith('+') || u.startsWith('-')) return null; // 相对位移：不解析
  if (!RegExp(r'^\d+$').hasMatch(u)) return null;
  final n = int.tryParse(u);
  if (n == null) return null;
  return n;
}

/// 纯文本 → 阅读器能渲染的 HTML（逐段 `<p>`，转义 `&<>`）
String _textToHtml(String text) {
  final out = StringBuffer();
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    out
      ..write('<p>')
      ..write(_escapeHtml(t))
      ..write('</p>');
  }
  if (out.isEmpty) {
    return '<p>${_escapeHtml(text.trim())}</p>';
  }
  return out.toString();
}

String _escapeHtml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

// ------------------------------------------------------------------ 探针

/// 给探针用：只回报"能不能读 + 为什么不能"（不落 `BookContent`）。
Map<String, Object?> djvuBookProbe(List<int> bytes) {
  final r = parseDjvuBook(bytes, format: BookFormat.djvu);
  return {
    'ok': r.ok,
    'error': r.error,
    'kind': r.errorKind?.name,
    'pages': r.content.pages.length,
    'chapters': r.content.chapters.length,
    'toc': r.content.toc.length,
  };
}

/// 给探针用：容器/文本层/目录的细节（真机验证时肉眼核对）。
Map<String, Object?> djvuDebugProbe(List<int> bytes) {
  final container = djvuProbe(bytes);
  final r = parseDjvuBook(bytes, format: BookFormat.djvu);
  return {
    'container': container,
    'ok': r.ok,
    'error': r.error,
    'kind': r.errorKind?.name,
    'bitmapPages': r.content.pages.length,
    'chapters': [for (final c in r.content.chapters.take(8)) c.title],
    'toc': [
      for (final e in r.content.toc.take(16)) '${"  " * e.depth}${e.title}',
    ],
    'textHead': r.content.chapters.isEmpty
        ? ''
        : r.content.chapters.first.html
              .replaceAll(RegExp(r'<[^>]*>'), '')
              .substring(
                0,
                r.content.chapters.first.html
                    .replaceAll(RegExp(r'<[^>]*>'), '')
                    .length
                    .clamp(0, 80),
              ),
  };
}


/// 由解析层兜底的页码标题（界面/导出用；纯 Dart 层不能 i18n ⇒ 走 `dataText`）。
String _bookPageTitle(int n) =>
    dataText('bookPageN', '第 {n} 页').replaceAll('{n}', '$n');
