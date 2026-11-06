// 电子书阅读页（EPUB / FB2 / CBZ，只读）。
//
// 渲染口径（跟着项目里已有的两条路走，不引新引擎）：
//   * EPUB / FB2：正文是 HTML/XML → 复用笔记那套 `noteHtmlToDelta` + Quill **只读**
//     渲染（标题、粗斜体、列表、引用、图片都能出来），不塞 WebView；
//   * CBZ：本质上是一包图片 → 直接 `PageView` 翻页。
//
// 图片：EPUB 的插图在 zip 里，`noteHtmlToDelta` 会把 `<img src>` 的**归一化路径**
// 放进 Delta 的 image embed，这里用一个自定义 [EmbedBuilder] 从书内资源取字节。

import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/system_open.dart' show isTestEnvironment;
import '../../core/theme/app_tokens.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/local/book_store.dart'
    show BookMark, BookProgress, fsBookKey;
import '../../data/local/file_store.dart' show describeFileError;
import '../ai/ai_assistant_sheet.dart';
import '../ai/ai_floating_orb.dart';
import '../ai/ai_providers.dart' show aiTierProvider;
import '../ai/ai_service.dart';
import '../ai/cloud_settings.dart';
import '../ai/on_device_ai.dart';
import '../ai/text_ai.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../notes/note_html.dart' show noteHtmlToDelta;
import '../notes/note_providers.dart' show noteApiProvider;
import 'book_dict_sheet.dart';
import 'book_note_export.dart';
import 'book_providers.dart';
import 'book_search.dart';
import 'book_tts.dart';
import 'book_tts_sheet.dart';
import 'file_book.dart';
import 'book_toc_sheet.dart';
import 'file_providers.dart';
import '../../core/user_facing_error.dart';

/// 选中菜单里的**非 AI** 动作（AI 的两个走 `AiTaskKind`）
enum BookSelectionAction {
  /// 查词（内置词表）
  lookup,

  /// 朗读选中内容
  speak,

  /// 导出到笔记
  exportNote,
}

/// 选中菜单的按钮表（**抽成纯函数**，便于离线断言"菜单里到底有哪几项"）。
///
/// `ContextMenuButtonItem` 要真的 `EditableTextState` 才能弹出来，而 Quill 的
/// 编辑器树里没有 `EditableText`（它是自己的 RawEditor）—— 所以把"按钮表"抽出来
/// 单测，弹层本身交真机截图核对。
List<ContextMenuButtonItem> bookSelectionMenuItems({
  required AppText t,
  required String text,
  required void Function(AiTaskKind kind, String text) onAiSelection,
  required void Function(BookSelectionAction action, String text)
  onSelectAction,
  required VoidCallback onCopy,
}) {
  void run(VoidCallback action) {
    ContextMenuController.removeAny();
    action();
  }

  return [
    if (text.isNotEmpty) ...[
      ContextMenuButtonItem(
        label: t.aiTranslate,
        onPressed: () => run(() => onAiSelection(AiTaskKind.translate, text)),
      ),
      ContextMenuButtonItem(
        label: t.aiExplain,
        onPressed: () => run(() => onAiSelection(AiTaskKind.explain, text)),
      ),
      ContextMenuButtonItem(
        label: t.bookDictLookup,
        onPressed: () =>
            run(() => onSelectAction(BookSelectionAction.lookup, text)),
      ),
      ContextMenuButtonItem(
        label: t.bookTtsReadAloud,
        onPressed: () =>
            run(() => onSelectAction(BookSelectionAction.speak, text)),
      ),
      ContextMenuButtonItem(
        label: t.bookExportNote,
        onPressed: () =>
            run(() => onSelectAction(BookSelectionAction.exportNote, text)),
      ),
    ],
    ContextMenuButtonItem(label: t.dtoActionCopy, onPressed: () => run(onCopy)),
  ];
}

/// 打开外链：测试环境不启动浏览器（与 `chat/url_actions.dart` 同一口径）
Future<void> openBookExternalLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  var ok = false;
  if (uri != null && uri.host.isNotEmpty && !isTestEnvironment) {
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
  }
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t.bookLinkExternalFailed(url))),
    );
  }
}

/// **字节已在手**时的只读阅读器 —— [FileBookStage] 的同一条解析/渲染管线
/// （`parseBook` → `_BookReader` / `_ComicView`），但不发网络、不写阅读进度库。
///
/// 为什么需要它（AGENTS §2.0.8 ④「同一份文档必须走同一个阅读器」）：
/// Office **模板预览**把模板导出成 OOXML（`Office.Export/download {object_id,
/// format:"ms"}`，见 `OfficeApi.templateExportBytes`），字节是从 Office API
/// 直接拿到的 —— 没有 FileStation/Drive 条目可以喂给 [FileBookStage]
/// （它要 `FileEntryDto` + 一条可下载直链，并且会把进度写进本地库）。
/// 模板正文十有八九是 docx/pptx，必须和"从文件里打开同名 .docx/.pptx"
/// **用同一个阅读器**渲染，所以这里把同一条管线的入口暴露成本 widget，
/// **不是**另写一个渲染器。
///
/// 只读语义：进度/书签/搜索/TTS 的键传空串，滚动与翻章回调都是 no-op
/// （预览不该在用户的书架/进度里留下记录）。
class FileBookBytesStage extends StatefulWidget {
  const FileBookBytesStage({
    super.key,
    required this.bytes,
    required this.format,
    this.title = '',
  });

  final List<int> bytes;
  final BookFormat format;

  /// 书内没有可靠书名时的兜底标题（模板预览给本地化模板名）。
  final String title;

  @override
  State<FileBookBytesStage> createState() => _FileBookBytesStageState();
}

class _FileBookBytesStageState extends State<FileBookBytesStage> {
  BookParseResult? _parsed;
  int _chapter = 0;

  @override
  void didUpdateWidget(FileBookBytesStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换模板（字节/格式变了）→ 重新解析，别复用上一份的模型。
    if (!identical(oldWidget.bytes, widget.bytes) ||
        oldWidget.format != widget.format) {
      _parsed = null;
      _chapter = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final bytes = widget.bytes;
    if (bytes.isEmpty) {
      return _BookHint(
        icon: Icons.menu_book_outlined,
        title: t.fileEmptyFile,
        detail: t.bookServerNoContent,
      );
    }
    final parsed = _parsed ??= parseBook(
      widget.format,
      bytes,
      title: widget.title,
    );
    if (!parsed.ok) {
      // 解不开就**如实说**（不静默画空页）
      return _BookHint(
        icon: Icons.menu_book_outlined,
        title: t.bookCannotRead,
        detail: bookParseErrorLabel(parsed, t),
        color: hud.dim,
      );
    }
    final book = parsed.content;
    if (usesPageView(book)) {
      return _ComicView(book: book, initialScroll: 0, onScroll: (_) {});
    }
    final index = _chapter.clamp(0, book.chapters.length - 1);
    return _BookReader(
      book: book,
      chapter: index,
      bookKey: '',
      initialScroll: 0,
      onAi: () {},
      onAiSelection: (_, _) {},
      onScrollForPage: (_, _) {},
      onSeekChapter: (i) => setState(() => _chapter = i),
      onChapter: (i) => setState(() => _chapter = i),
    );
  }
}

/// 阅读器外壳：取字节 → 解析 → 交给具体格式的视图
class FileBookStage extends ConsumerStatefulWidget {
  const FileBookStage({
    super.key,
    required this.entry,
    this.bytesUrl,
    this.bookKey,
  });

  final FileEntryDto entry;
  final String? bytesUrl;

  /// 阅读进度/书签的键（`fs:<path>` / `drive:<permanent_link>`）。
  /// 为空时按 FileStation 路径算一个 —— 测试与旧调用方不用改。
  final String? bookKey;

  @override
  ConsumerState<FileBookStage> createState() => _FileBookStageState();
}

class _FileBookStageState extends ConsumerState<FileBookStage> {
  BookParseResult? _parsed;
  var _chapter = 0;

  /// 进书时从本地库恢复的进度（只用来"开局定位"，之后以 Reader 里的实时位置为准）
  int? _resumeChapter;
  double _resumeScroll = 0;

  /// 服务端（本地库）读出来的进度 + 是否已经用它定位过
  BookProgress? _saved;
  var _applied = false;

  /// 用户在进度回来**之前**就自己动了（翻章/滑动）→ 不许再跳回去
  var _userMoved = false;

  /// 阅读进度/书签的键
  String get _bookKey => widget.bookKey ?? fsBookKey(widget.entry.path);

  @override
  void initState() {
    super.initState();
    // ⚠️ 进度必须**异步**读：`bookProgressProvider` 第一次被 read 时是
    // `AsyncLoading`，`.value` 是 null —— 之前就是在这里踩的坑：真机上冷启动
    // 打开书永远从头开始（界面上看不出报错），而 widget 测试里 provider 已经
    // 预热过，反而测不出来。这里直接问 store，读到再决定跳不跳。
    ref.read(bookStoreProvider).progressOf(_bookKey).then((saved) {
      if (!mounted || saved == null) return;
      setState(() {
        _saved = saved;
        _applySaved();
      });
    });
  }

  /// 有书 + 有进度 + 用户还没动过 → 定位一次。解析晚于进度回来时由 build 再叫一次。
  void _applySaved() {
    if (_applied || _userMoved) return;
    final saved = _saved;
    final book = _parsed?.content;
    if (saved == null || book == null) return;
    // ★★★ r316c 真机缺陷（已修）：**漫画/图片包只有 `pages`、没有 `chapters`**。
    // 原来这里一句 `|| book.chapters.isEmpty` 直接 return ⇒ CBR/CBZ/CBT 的
    // "存进度"照写、"恢复进度"永不发生 —— 真机逐字复现：
    // 停在 `CBR · 2/4` 关掉、重开又是 `CBR · 1/4`（2/4 不是"读完"，不适用重来规则），
    // 而 `_resumeChapter` 停在 null 又让漫画分支的 `_resumeChapter == 0` 判假。
    // 判据改成"这本书有可看的内容"：章节或页面任一非空都要走恢复。
    final paged = book.chapters.isEmpty && book.pages.isNotEmpty;
    if (book.chapters.isEmpty && !paged) return;
    _applied = true;
    // 翻页书（漫画）没有"章"：整本当成第 0 章（与 `_saveProgress(book, 0, p)` 对称）
    final last = paged ? 0 : book.chapters.length - 1;
    final chapter = paged
        ? 0
        : saved.chapter.clamp(0, book.chapters.length - 1);
    // 不恢复到"最后一章的最后 1%"（书读完了就从头来，像官方 App 一样）
    if (chapter == last && saved.scroll > 0.98) return;
    // 解析可能当帧就完成：布局期间 setState 会炸，放到下一帧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _resumeChapter = chapter;
        _resumeScroll = saved.scroll.clamp(0.0, 1.0);
        _chapter = chapter;
      });
      ref.read(readerProgressProvider.notifier).reset();
    });
  }

  /// 记进度（章节 + 章内百分比）。写库由 notifier 自己去重/节流。
  void _saveProgress(BookContent book, int chapter, double scroll) {
    ref
        .read(readerProgressProvider.notifier)
        .report(
          bookKey: _bookKey,
          title: book.title,
          format: book.format.label,
          chapter: chapter,
          scroll: scroll,
          chapterCount: book.chapters.length,
          // Drive 来源的现成直链：工作台「继续阅读」靠它重开（FileStation 为空）
          sourceUrl: widget.bytesUrl ?? '',
        );
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final req = FileBytesRequest(widget.entry.path, url: widget.bytesUrl);
    final async = ref.watch(fileBytesProvider(req));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _BookHint(
        icon: Icons.error_outline,
        title: t.bookOpenFailed,
        detail: describeFileError(e),
        onRetry: () => ref.invalidate(fileBytesProvider(req)),
      ),
      data: (bytes) {
        if (bytes.isEmpty) {
          return _BookHint(
            icon: Icons.menu_book_outlined,
            title: t.fileEmptyFile,
            detail: t.bookServerNoContent,
          );
        }
        final opened = _parsed == null;
        final parsed = _parsed ??= parseBook(
          bookFormatOf(widget.entry.extension),
          bytes,
          // 兜底书名 = 文件名去后缀：TXT/HTML/RTF 这类书里没有可靠书名，
          // 界面显示"-第一章"当书名很难看
          title: bookTitleFromEntry(widget.entry),
        );
        if (opened) {
          // 使用日志：打开一本书（只记格式和章数，不记书名）
          trackOnce(
            UsageModule.reader,
            UsageAction.open,
            objectType: widget.entry.extension,
            detail: {'chapters': parsed.content.chapters.length},
          );
        }
        if (!parsed.ok) {
          return _BookHint(
            icon: Icons.menu_book_outlined,
            title: t.bookCannotRead,
            detail: bookParseErrorLabel(parsed, t),
            hint: t.bookDownloadHint,
            color: hud.dim,
          );
        }
        final book = parsed.content;
        if (usesPageView(book)) {
          // ★★★ r316c 第四处（真机与离线分道扬镳的真因）：进度是**先**回来的、
          // 解析是**后**完成的（真机要下载 CBR）。`initState` 里那次 `_applySaved()`
          // 因为 `_parsed == null` 直接返回，而文本分支在下面还会再叫一次、
          // **漫画分支直接 return 就没有第二机会** ⇒ 真机永远回到第 1 页
          // （库里明明是 `scroll 0.75`）。这里补上"解析完成后也叫一次"，幂等。
          _applySaved();
          // 漫画/图片包（CBZ / CBR / CBT）与"出得了位图的 DJVU"共用翻页器，
          // 也记进度（按"第几页 / 共几页"）
          return _ComicView(
            book: book,
            // ★ r316c：`_resumeChapter` 在漫画这条路上原来是 null，`null == 0`
            // 为假 ⇒ 恢复出来的 `_resumeScroll` 被丢掉。写成 `?? 0` 才对称。
            initialScroll: (_resumeChapter ?? 0) == 0 ? _resumeScroll : 0,
            onScroll: (p) {
              _userMoved = true;
              _saveProgress(book, 0, p);
            },
          );
        }
        // 有进度就恢复（只做一次），并在"进度还没到"时把书先画出来
        _applySaved();
        final index = _chapter.clamp(0, book.chapters.length - 1);
        return _BookReader(
          book: book,
          chapter: index,
          // 恢复位置只喂给"第一次打开的那一章"，翻章后不再用
          initialScroll: _resumeChapter == index ? _resumeScroll : 0,
          bookKey: _bookKey,
          onAi: () => _openAi(book, index),
          onAiSelection: (kind, text) =>
              _openAiSelection(book, index, kind, text),
          onScrollForPage: (i, p) {
            // 旧页在换章那一帧还会报一次 → 只认当前页
            if (i != _chapter) return;
            _userMoved = true;
            _saveProgress(book, i, p);
          },
          onSeekChapter: (i) {
            _userMoved = true;
            // 跳章本身也要落库：不然"只翻章不滚动"的用户永远没有进度
            _saveProgress(book, i, 0);
            setState(() => _chapter = i);
          },
          onChapter: (i) {
            _userMoved = true;
            // 使用日志：翻章（横滑/上下章按钮都走这里）
            trackOnce(
              UsageModule.reader,
              UsageAction.switchSection,
              objectType: 'chapter',
            );
            _saveProgress(book, i, 0);
            setState(() => _chapter = i);
          },
        );
      },
    );
  }
}

// ------------------------------------------------------------------ 端侧 AI

/// 兜底书名：文件名去掉最后一个后缀（`三体.epub` → `三体`）
String bookTitleFromEntry(FileEntryDto entry) {
  final name = entry.name;
  final ext = entry.extension;
  if (ext.isEmpty) return name;
  final cut = name.length - ext.length - 1;
  return cut > 0 ? name.substring(0, cut) : name;
}

/// 解析失败的原因：已知类别走 i18n，陌生的回落解析层给的中文文本
/// 能力边界 → 本地化文案（**不再拼中文细节**）。
///
/// 技术细节（[detail]）只进日志：`[book] unsupported reason=… detail=…`。
/// 给用户的是**能看懂且同语言**的一句，而不是解析层的内部说法。
String bookUnsupportedReasonText(
  AppText t,
  BookUnsupportedReason reason, {
  String? detail,
}) {
  if (detail != null && detail.isNotEmpty) {
    debugPrint('[book] unsupported reason=${reason.name} detail=$detail');
  }
  return switch (reason) {
    BookUnsupportedReason.encrypted =>
      '${t.bookUnsupportedFormat} · ${t.bookReasonEncrypted}',
    BookUnsupportedReason.multiVolume =>
      '${t.bookUnsupportedFormat} · ${t.bookReasonMultiVolume}',
    BookUnsupportedReason.drm =>
      '${t.bookUnsupportedFormat} · ${t.bookReasonDrm}',
    BookUnsupportedReason.compression =>
      '${t.bookUnsupportedFormat} · ${t.bookReasonCompression}',
    BookUnsupportedReason.missingParts =>
      '${t.bookUnsupportedFormat} · ${t.bookReasonMissingParts}',
    // 没归类：只说「不支持」，不再把内部中文串给用户看
    BookUnsupportedReason.other => t.bookUnsupportedFormat,
  };
}

String bookParseErrorLabel(BookParseResult parsed, AppText t) =>
    switch (parsed.errorKind) {
      BookParseErrorKind.unsupportedFormat => t.bookUnsupportedFormat,
      // 能力边界（MOBI 的 HUFF/CDIC、纯 KF8、DRM）：本地化的"不支持"打头，
      // 后面接解析层给的具体技术原因 —— 用户能看懂，也**如实**说了卡在哪。
      // 这里**没有新增 ARB key**：前缀复用既有的 `bookUnsupportedFormat`。
      // ★★★ r316c：这里原来把 `parsed.error`（解析层的**中文**技术原因）
      // 直接拼在本地化前缀后面 ⇒ 英文设备上出现中英混串，真机逐字：
      // `This format can't be read inline yet · 带密码（加密）的 CBR，本阅读器不解密`。
      // 改成按**类型**取本地化文案；技术细节只进日志（`debugPrint`）。
      BookParseErrorKind.unsupportedCompression => bookUnsupportedReasonText(
        t,
        parsed.reason,
        detail: parsed.error,
      ),
      BookParseErrorKind.parseFailed => t.bookParseFailed,
      null =>
        parsed.error?.isNotEmpty == true ? parsed.error! : t.fileUnknownReason,
    };

/// 章节标题：解析层兜底生成的序号标题要按当前语言重写（纯 Dart 层不能 i18n）
String bookChapterTitle(BookChapter ch, int index, AppText t) =>
    switch (ch.generatedUnit) {
      BookGeneratedUnit.chapter => t.bookChapterN(index + 1),
      BookGeneratedUnit.section => t.bookSectionN(index + 1),
      BookGeneratedUnit.body => t.bookBodyText,
      // 固定版式（XPS/OXPS）一页一段：标题用"第 N 页"
      BookGeneratedUnit.page => t.bookPageN(index + 1),
      null => ch.title,
    };

extension _BookAi on _FileBookStageState {
  /// 这一章的可读文本（去掉 HTML 标签；正文里没有图片信息，模型也不需要）
  String _chapterText(BookContent book, int index) {
    if (book.chapters.isEmpty) return '';
    final i = index.clamp(0, book.chapters.length - 1);
    return bookPlainText(book.chapters[i].html);
  }

  String _label(BookContent book, int index) {
    final t = context.t;
    final title = book.title.isEmpty ? t.bookUntitled : book.title;
    final i = index.clamp(
      0,
      book.chapters.isEmpty ? 0 : book.chapters.length - 1,
    );
    final ch = book.chapters.isEmpty
        ? ''
        : bookChapterTitle(book.chapters[i], i, t);
    return ch.isEmpty
        ? t.bookAiLabel(title, i + 1)
        : t.bookAiLabelNamed(title, i + 1, ch);
  }

  /// 整章摘要的**二次确认**：先把"要发什么、发到哪"讲清楚再发。
  ///
  /// 顺带处理"云端档还没配 key"：这时引擎会降级到端侧/内置（功能不消失），
  /// 但用户以为配好了云端，所以要如实提示一句（可读错误态的入口）。
  Future<bool> _confirmSendChapter(int chars) async {
    final t = context.t;
    if (ref.read(aiTierProvider) == AiTier.cloud &&
        !ref.read(cloudSettingsProvider).configured) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.bookAiNoKey)));
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(t.bookSendChapterTitle),
        content: Text(t.bookSendChapterBody(chars)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(t.bookSendChapterConfirm),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 打开 AI 助手：总结本章 / 就这本书提问（带检索引用）
  Future<void> _openAi(BookContent book, int index) async {
    final chapterText = _chapterText(book, index);
    // 整章摘要要**二次确认**（E2 验收项）：只发这一章，但也要用户点一下
    if (!await _confirmSendChapter(chapterText.length)) return;
    if (!mounted) return;
    // 使用日志：只记"用了阅读器的 AI"，不记内容
    trackOnce(UsageModule.reader, UsageAction.open, objectType: 'ai');
    showAiAssistant(
      context,
      title: _label(book, index),
      tasks: const [AiTaskKind.summary, AiTaskKind.askBook],
      build: (kind, question) {
        if (kind == AiTaskKind.askBook) {
          final passages = passagesOfBook(
            book.title.isEmpty ? context.t.bookThisBook : book.title,
            [
              for (var i = 0; i < book.chapters.length; i++)
                bookChapterTitle(book.chapters[i], i, context.t),
            ],
            [for (final c in book.chapters) bookPlainText(c.html)],
          );
          return withRetrieval(
            AiRequest(
              kind: kind,
              text: chapterText,
              title: book.title,
              question: question,
            ),
            passages,
          );
        }
        return AiRequest(
          kind: kind,
          text: chapterText,
          title: _label(book, index),
        );
      },
    );
  }

  /// 选句解释 / 翻译
  void _openAiSelection(
    BookContent book,
    int index,
    AiTaskKind kind,
    String text,
  ) {
    trackOnce(UsageModule.reader, UsageAction.open, objectType: 'ai_select');
    showAiAssistant(
      context,
      title: _label(book, index),
      initial: kind,
      selection: text,
      tasks: const [AiTaskKind.summary, AiTaskKind.askBook],
      build: (k, question) => AiRequest(
        kind: k,
        text: k == kind ? text : _chapterText(book, index),
        title: _label(book, index),
        maxOutputTokens: k == AiTaskKind.translate ? 320 : 400,
      ),
    );
  }
}

// ------------------------------------------------------------------ EPUB / FB2

/// EPUB / FB2 的正文阅读器：**左右滑动翻章** + 目录 + 上一章/下一章。
///
/// 手势冲突的处理：
///   * 每章正文是**竖向**滚动的 Quill 只读编辑框 → 与横向翻章不同轴，
///     纵向滚动不会误触发翻章；
///   * 正文里的文字选择是"长按 + 拖手柄"，横向拖动落在编辑框空白处时
///     会冒泡给外层 `PageView`（这正是想要的翻章手势）；
///   * 目录/按钮改章节走同一条 `onChapter`，`didUpdateWidget` 里补一次
///     `animateToPage`，保证"手势"和"按钮"两条路状态一致。
class _BookReader extends ConsumerStatefulWidget {
  const _BookReader({
    required this.book,
    required this.chapter,
    required this.bookKey,
    required this.onChapter,
    required this.onSeekChapter,
    required this.onScrollForPage,
    required this.onAi,
    required this.onAiSelection,
    this.initialScroll = 0,
  });

  final BookContent book;
  final int chapter;

  /// 进度/书签的键（`fs:` / `drive:`）
  final String bookKey;

  /// 从搜索/书签跳章（**不走**使用日志的翻章口径：那是"用户翻章"）
  final ValueChanged<int> onSeekChapter;

  /// `(pageIndex, scrollRatio)` —— 带页码的滚动上报
  final void Function(int chapter, double ratio) onScrollForPage;

  final ValueChanged<int> onChapter;

  /// 打开时恢复到的章内位置（0..1）
  final double initialScroll;

  /// 顶部「AI 助手」按钮（总结本章）
  final VoidCallback onAi;

  /// 选句工具条里的「解释 / 翻译」
  final void Function(AiTaskKind kind, String text) onAiSelection;

  @override
  ConsumerState<_BookReader> createState() => _BookReaderState();
}

class _BookReaderState extends ConsumerState<_BookReader> {
  late final PageController _pager;
  late int _current;

  /// 跳转目标：`第几章 → 要高亮的原文片段`（搜索命中 / 书签摘录）
  ///
  /// 用"片段"而不是字符偏移：书在服务端可能被换过版本，偏移量会错位，
  /// 而片段在正文里搜一次就能定位（`_ChapterBody` 里做）。
  String _seekText = '';
  double _seekScroll = 0;

  /// 当前章内位置（用于加书签）
  double _scroll = 0;

  /// 脚注/超链接的**来源栈**：点链接跳走前把"原处"压进来，供「返回原处」退回。
  ///
  /// 为什么不只依赖书里自带的 `↩` 回跳链接：大量 EPUB/FB2 只有去的链接、
  /// 没有回的链接（或者回跳锚点本身也丢了）。自己记来源栈，任何链接都能跳回。
  final List<({int chapter, double scroll})> _linkStack = [];

  /// 搜索/书签跳转：不算"翻章"埋点，但照样要换章
  void _seek(int chapter, {String text = '', double scroll = 0}) {
    // ⚠️ **不要**在这里同步 `_current`：`didUpdateWidget` 靠
    // `widget.chapter != _current` 判断"外部要求换章"，提前同步会把这个判断
    // 抹掉 → `jumpToPage` 永远不执行。真机表现很隐蔽：页眉页脚已经是目标章，
    // **正文还停在原来那一章**（离线用例只断言了页脚，所以一直是绿的）。
    setState(() {
      _seekText = text;
      _seekScroll = scroll;
    });
    widget.onSeekChapter(chapter);
  }

  /// 点正文里的链接：书内锚点跳段、外链交系统浏览器、找不到给提示。
  void _openLink(int fromChapter, String href) {
    final book = widget.book;
    if (fromChapter < 0 || fromChapter >= book.chapters.length) return;
    final fromHref = book.chapters[fromChapter].href;
    final link = classifyBookLink(fromHref, href);
    if (link.kind == BookLinkKind.external) {
      trackOnce(
        UsageModule.reader,
        UsageAction.openExternal,
        objectType: 'url',
      );
      openBookExternalLink(context, link.href);
      return;
    }
    final target = book.anchorFor(fromHref, href);
    if (target == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.t.bookLinkNotFound)));
      return;
    }
    // 记下原处（章 + 段内百分比）；同一处反复点也不会丢
    _linkStack.add((chapter: _current, scroll: _scroll));
    _seek(target);
  }

  /// 返回上一处（脚注/超链接的"跳回原处"）
  void _backFromLink() {
    if (_linkStack.isEmpty) return;
    final from = _linkStack.removeLast();
    _seek(from.chapter, scroll: from.scroll);
  }

  /// 选中菜单里的非 AI 动作：查词 / 朗读 / 导出到笔记
  Future<void> _onSelectAction(BookSelectionAction action, String text) async {
    switch (action) {
      case BookSelectionAction.lookup:
        await showBookDictionarySheet(context, word: text);
      case BookSelectionAction.speak:
        await _speakText(text);
      case BookSelectionAction.exportNote:
        await _exportToNote(text);
    }
  }

  String _chapterLabel(int index) {
    final book = widget.book;
    final i = index.clamp(0, book.chapters.length - 1);
    return bookChapterTitle(book.chapters[i], i, context.t);
  }

  /// 朗读：选中内容优先，没选中（正文区入口）就读本章。
  Future<void> _speakText(String text) async {
    final chapter = widget.chapter.clamp(0, widget.book.chapters.length - 1);
    final source = text.trim().isEmpty
        ? bookPlainText(widget.book.chapters[chapter].html)
        : text.trim();
    trackOnce(UsageModule.reader, UsageAction.play, objectType: 'tts');
    await showBookTtsSheet(
      context,
      title: _chapterLabel(chapter),
      paragraphs: ttsParagraphsOf(source),
    );
  }

  /// 导出到笔记：生成 Markdown/HTML → `Note/create` → `Note/set` 打标签
  Future<void> _exportToNote(String text) async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    if (api == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.setNotConnected)));
      return;
    }
    final chapter = widget.chapter.clamp(0, widget.book.chapters.length - 1);
    final selection = text.trim().isEmpty
        ? bookPlainText(widget.book.chapters[chapter].html)
        : text.trim();
    final draft = buildBookNoteDraft(
      t: t,
      bookTitle: widget.book.title,
      chapterTitle: _chapterLabel(chapter),
      chapter: chapter,
      chapterCount: widget.book.chapters.length,
      selection: selection,
      percent: (_scroll.clamp(0.0, 1.0) * 100).round(),
    );
    try {
      final result = await BookNoteExporter(api).export(draft);
      if (!mounted) return;
      trackOnce(UsageModule.reader, UsageAction.exportFile, objectType: 'note');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t.bookExportNotebookReady(result.notebookTitle)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.bookExportFailed(userFacingError(e)))),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    // ⚠️ 必须在 initState 里取 `widget.chapter`：写成 `late int _current =
    // widget.chapter` 会**延迟到第一次读取**才求值，而第一次读取发生在
    // 章节已经变了之后的 `didUpdateWidget` 里 —— 于是 `_current == 新章节`，
    // 判断"外部改了章节"永远不成立，pager 卡在第一页（测试抓出来的）。
    _current = widget.chapter;
    _pager = PageController(initialPage: widget.chapter);
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _BookReader old) {
    super.didUpdateWidget(old);
    // 外部改的章节（目录、上一章/下一章按钮）→ pager 跟过去。
    // ⚠️ 必须等这一帧画完：在 `didUpdateWidget`（build 阶段）里直接
    // `animateToPage` 会被这一帧的布局吃掉，pager 停在原地（真机/测试都复现过）。
    if (widget.chapter != _current) {
      _current = widget.chapter;
      final target = widget.chapter;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pager.hasClients) return;
        // 这里用 `jumpToPage` 而不是 `animateToPage`：在 build 后的回调里
        // `animateToPage` 会被 PageView 的布局吃掉（测试里连 1 秒都不动，
        // `jumpToPage` 立刻到位）。手势滑动本身由 PageView 自己动画，
        // 所以只有"按钮/目录跳章"走这条即时路径。
        _pager.jumpToPage(target);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final t = context.t;
    final book = widget.book;
    final chapter = widget.chapter.clamp(0, book.chapters.length - 1);
    final ch = book.chapters[chapter];
    return Column(
      children: [
        // 书名/作者 + 当前章节
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title.isEmpty ? t.bookUntitled : book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      [
                        if (book.author.isNotEmpty) book.author,
                        t.bookChapterOf(
                          book.format.label,
                          chapter + 1,
                          book.chapters.length,
                        ),
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: hud.dim,
                      ),
                    ),
                  ],
                ),
              ),
              // 「返回原处」：从脚注/超链接跳走之后才出现，点一下回到来源位置
              if (_linkStack.isNotEmpty)
                IconButton(
                  key: const Key('book-link-back'),
                  tooltip: t.bookLinkBack,
                  icon: const Icon(Icons.undo),
                  onPressed: _backFromLink,
                ),
              // AI 助手改成**可拖动悬浮球**（见本文件的 Stack 与
              // `ai_floating_orb.dart`）：阅读器头部不再常驻一个右上角图标，
              // 顶部只留"阅读工具"。
              // 书签 / 搜索 / 阅读设置：三件事收在一个菜单里，
              // 免得头部挤下五个图标（手机宽度只有 ~375dp）
              IconButton(
                tooltip: t.bookTools,
                icon: const Icon(Icons.more_vert),
                onPressed: () => _showTools(context),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            children: [
              PageView.builder(
                key: const Key('book-chapter-pager'),
                controller: _pager,
                itemCount: book.chapters.length,
                onPageChanged: (i) {
                  // `i == _current` 有两种情况：手势滑到同一页（无事发生），
                  // 或"跳章"这一帧（`didUpdateWidget` 已经把 `_current` 改成目标章）
                  // —— 后者**必须保留** `_seekText/_seekScroll`，否则目标章的
                  // `_ChapterBody` 刚建出来就发现定位被清空了。
                  if (i == _current) return;
                  _current = i;
                  _seekText = '';
                  _seekScroll = 0;
                  _scroll = 0;
                  // 手势翻章 = 用户主动换地方，来源栈不再有意义
                  _linkStack.clear();
                  widget.onChapter(i);
                },
                itemBuilder: (context, i) => _ChapterBody(
                  book: book,
                  chapter: i,
                  bookKey: widget.bookKey,
                  initialScroll: i == widget.chapter ? widget.initialScroll : 0,
                  seekText: i == _current ? _seekText : '',
                  seekScroll: i == _current ? _seekScroll : 0,
                  // ⚠️ 上报要带**页码**：换章那一帧旧页还会再报一次 scroll(0)，
                  // 父层若只知道"当前章"，就会把刚跳过去的进度又写回原来那一章
                  // （真机：搜索跳到第 2 章 → 重启 App 又回到第 1 章）。
                  onScroll: (p) {
                    _scroll = p;
                    widget.onScrollForPage(i, p);
                  },
                  onAiSelection: widget.onAiSelection,
                  onLink: (href) => _openLink(i, href),
                  onSelectAction: _onSelectAction,
                ),
              ),
              // AI 悬浮球：可拖到任意位置、松手吸附左右边、朝边缘一滑收起。
              // 只覆盖正文区（头部与底部操作条不受影响），空白处不拦手势。
              AiFloatingOrb(onTap: widget.onAi),
            ],
          ),
        ),
        const Divider(height: 1),
        // 底部操作条：**目录放在正中，章标题就在这个按钮上**。
        //
        // 为什么不放右上角：单手拿手机时顶部的图标够不到，而"开目录换章"
        // 是阅读里最高频的动作（用户反馈：顶部不方便点击切换）。
        // 为什么章标题并进按钮：它原来是单独一行的纯文本（只占高度不能点），
        // 而它就是"目录里当前那一条"，合起来既省一行又让按钮自带语义
        // （点之前就知道自己在哪一章）。
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, 4, Gap.sm, 6),
          // ★ 第 235 轮（`DA179`，用户裁定 ③）：窄屏上"上一章/下一章"的文字
          //   把中键挤到 ~110dp，真机上章标题被截成「第二…」（亮色实测截图）。
          //   现在按可用宽度分两态：够宽给文字；窄了退成图标按钮（48dp 点击区不变），
          //   把中间让给**当前章标题**这个信息。
          child: LayoutBuilder(
            builder: (context, barBox) {
              final tight = barBox.maxWidth < 460;
              return Row(
                children: [
                  // 两侧按钮用**自身宽度**贴边。
                  //
                  // 别套 Expanded：套上以后按钮被拉满，内容默认在中间，
                  // "上一章/下一章"看起来就都挤到中间去了（用户反馈过）。
                  if (tight)
                    IconButton(
                      key: const Key('book-prev-icon'),
                      tooltip: t.bookPrevChapter,
                      onPressed: chapter > 0
                          ? () => widget.onChapter(chapter - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left, size: 20),
                    )
                  else
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      ),
                      onPressed: chapter > 0
                          ? () => widget.onChapter(chapter - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left, size: 18),
                      label: Text(
                        t.bookPrevChapter,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  // 中间用 Expanded 把两侧顶到屏幕边上；中键自己居中
                  Expanded(
                    child: Center(
                      child: Tooltip(
                        message: t.bookTocTitle,
                        child: FilledButton.tonalIcon(
                          // ⚠️ 主题里 FilledButton 的 `minimumSize` 是
                          // `Size.fromHeight(48)`（= 整行宽，见 app_theme.dart）。
                          // 放在 Row 里当小按钮用必须覆盖，否则拿到 minWidth=∞，
                          // 直接 `BoxConstraints forces an infinite width` 崩布局。
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(
                              horizontal: Gap.sm,
                            ),
                          ),
                          onPressed: () => _showToc(context),
                          icon: const Icon(Icons.list_alt, size: 18),
                          label: Text(
                            ch.title.isEmpty
                                ? t.bookTocTitle
                                : bookChapterTitle(ch, chapter, t),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (tight)
                    IconButton(
                      key: const Key('book-next-icon'),
                      tooltip: t.bookNextChapter,
                      onPressed: chapter < book.chapters.length - 1
                          ? () => widget.onChapter(chapter + 1)
                          : null,
                      icon: const Icon(Icons.chevron_right, size: 20),
                    )
                  else
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      ),
                      onPressed: chapter < book.chapters.length - 1
                          ? () => widget.onChapter(chapter + 1)
                          : null,
                      // 图标放到文字右边更像"下一页"
                      icon: const Icon(Icons.chevron_right, size: 18),
                      label: Text(
                        t.bookNextChapter,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                      iconAlignment: IconAlignment.end,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// 阅读工具菜单：书签 / 全文搜索 / 阅读设置
  Future<void> _showTools(BuildContext context) async {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        // ⚠️ 菜单项 E2 起变成 5 条，小屏（600 高的测试视口）会溢出 —— 必须可滚
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.md,
                  Gap.sm,
                  Gap.md,
                  Gap.xs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.t.bookTools,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              DesignRowTile(
                leading: const Icon(Icons.search),
                title: Text(context.t.bookSearchTool),
                subtitle: Text(
                  context.t.bookSearchToolSubtitle,
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
                onTap: () => Navigator.of(context).pop('search'),
              ),
              DesignRowTile(
                leading: const Icon(Icons.bookmark_add_outlined),
                title: Text(context.t.bookMarks),
                subtitle: Text(
                  context.t.bookMarksSubtitle,
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
                onTap: () => Navigator.of(context).pop('marks'),
              ),
              DesignRowTile(
                leading: const Icon(Icons.text_fields),
                title: Text(context.t.readerPrefsTitle),
                subtitle: Text(
                  context.t.readerPrefsSubtitle,
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
                onTap: () => Navigator.of(context).pop('prefs'),
              ),
              // 整章朗读 / 整章导出：长按选中在真机上要先选中再找工具条，
              // 这两个入口让"整章"这一类动作一步可达（E2）
              DesignRowTile(
                key: const Key('book-tools-tts'),
                leading: const Icon(Icons.volume_up_outlined),
                title: Text(context.t.bookTtsReadAloud),
                onTap: () => Navigator.of(context).pop('tts'),
              ),
              DesignRowTile(
                key: const Key('book-tools-export'),
                leading: const Icon(Icons.note_add_outlined),
                title: Text(context.t.bookExportNote),
                onTap: () => Navigator.of(context).pop('export'),
              ),
            ],
          ),
        ),
      ),
    );
    if (pick == null || !context.mounted) return;
    switch (pick) {
      case 'search':
        await _showSearch(context);
      case 'marks':
        await _showMarks(context);
      case 'prefs':
        await _showPrefs(context);
      case 'tts':
        await _speakText('');
      case 'export':
        await _exportToNote('');
    }
  }

  /// 书内搜索：纯本地（正文已经在内存里），跨章命中 → 点结果跳章 + 高亮
  ///
  /// 为什么不做"整章全文高亮全部命中"：Quill 只读渲染没有"文本高亮"这层，
  /// 硬塞要给 Delta 打补丁；这里改为**跳到命中的那一章 + 选中命中片段 +
  /// 按比例滚到附近**（阅读器里够用，且不改正文数据）。
  Future<void> _showSearch(BuildContext context) async {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final t = context.t;
    final book = widget.book;
    final controller = TextEditingController();
    var hits = const <BookSearchHit>[];
    var query = '';
    var searching = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          void run(String q) {
            query = q.trim();
            hits = query.isEmpty
                ? const <BookSearchHit>[]
                : searchBook(book, query, limit: 120);
            setSheet(() {});
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            builder: (context, scroll) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Gap.md,
                    Gap.sm,
                    Gap.xs,
                    Gap.xs,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.bookSearchTool,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      Text(
                        query.isEmpty ? '' : t.bookSearchHits(hits.length),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hud.dim,
                        ),
                      ),
                      IconButton(
                        tooltip: t.photoClose,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  child: TextField(
                    key: const Key('book-search-field'),
                    controller: controller,
                    autofocus: false,
                    textInputAction: TextInputAction.search,
                    onChanged: (v) {
                      searching = true;
                      run(v);
                      searching = false;
                    },
                    onSubmitted: run,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: t.bookSearchHint,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: controller.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                controller.clear();
                                run('');
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: Gap.sm),
                Expanded(
                  child: query.isEmpty
                      ? _PaddedCenter(
                          child: Text(
                            t.bookSearchPrompt,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: hud.dim,
                            ),
                          ),
                        )
                      : hits.isEmpty
                      ? _PaddedCenter(
                          child: Text(
                            t.bookSearchNoMatch(query),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: hud.dim,
                            ),
                          ),
                        )
                      : ListView.separated(
                          key: const Key('book-search-list'),
                          controller: scroll,
                          itemCount: hits.length + (searching ? 1 : 0),
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final h = hits[i];
                            return DesignRowTile(
                              dense: true,
                              title: Text(
                                t.bookChapterTitleLine(
                                  h.chapter + 1,
                                  bookChapterTitle(
                                    book.chapters[h.chapter],
                                    h.chapter,
                                    t,
                                  ),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: hud.dim,
                                ),
                              ),
                              subtitle: Text(
                                h.snippet,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () {
                                Navigator.of(context).pop();
                                _seek(h.chapter, text: query, scroll: h.ratio);
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
    // ⚠️ 不要在这里 `controller.dispose()`：弹层 pop 之后还有一段退出动画，
    // 期间 TextField 会重建 → "A TextEditingController was used after being
    // disposed"（测试里直接红屏）。它没有注册到任何全局对象，交给 GC 就行。
  }

  /// 书签 / 划线列表：加当前位置、跳回、改批注、删除
  Future<void> _showMarks(BuildContext context) async {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final t = context.t;
    final book = widget.book;
    final actions = ref.read(bookMarksActionsProvider(widget.bookKey));

    Future<String?> askNote(String initial) async {
      final c = TextEditingController(text: initial);
      final out = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.bookNoteTitle),
          content: TextField(
            controller: c,
            autofocus: true,
            maxLines: 3,
            decoration: InputDecoration(hintText: t.bookNoteHint),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(c.text.trim()),
              child: Text(t.actionSave),
            ),
          ],
        ),
      );
      // 同上：对话框退场动画期间还会重建，别提前 dispose
      return out;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, scroll) => Consumer(
          builder: (context, ref, _) {
            final async = ref.watch(bookMarksProvider(widget.bookKey));
            final marks = async.value ?? const <BookMark>[];
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Gap.md,
                    Gap.sm,
                    Gap.xs,
                    Gap.xs,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.bookMarks,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      Text(
                        t.bookMarksCount(marks.length),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hud.dim,
                        ),
                      ),
                      IconButton(
                        tooltip: t.photoClose,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const Key('book-mark-add'),
                      onPressed: () async {
                        // 摘录当前段：用"当前章开头 + 附近一句"太糙，
                        // 这里取本章前 40 字当识别用摘要（书签列表里够认）
                        final text = bookPlainText(
                          book.chapters[widget.chapter].html,
                        );
                        await actions.add(
                          chapter: widget.chapter,
                          scroll: _scroll,
                          excerpt: text.length > 40
                              ? text.substring(0, 40)
                              : text,
                        );
                      },
                      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                      label: Text(
                        t.bookAddMarkAt(
                          widget.chapter + 1,
                          ((_scroll.clamp(0.0, 1.0)) * 100).round(),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Gap.sm),
                const Divider(height: 1),
                Expanded(
                  child: marks.isEmpty
                      ? Center(
                          child: Text(
                            t.bookNoMarks,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: hud.dim,
                            ),
                          ),
                        )
                      : ListView.separated(
                          key: const Key('book-mark-list'),
                          controller: scroll,
                          itemCount: marks.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final m = marks[i];
                            return DesignRowTile(
                              dense: true,
                              title: Text(
                                t.bookChapterTitleLine(
                                  m.chapter + 1,
                                  bookChapterTitle(
                                    book.chapters[m.chapter.clamp(
                                      0,
                                      book.chapters.length - 1,
                                    )],
                                    m.chapter.clamp(
                                      0,
                                      book.chapters.length - 1,
                                    ),
                                    t,
                                  ),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: hud.dim,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.excerpt.isEmpty
                                        ? t.bookNoExcerpt
                                        : m.excerpt,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (m.hasNote)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        t.bookNotePrefix(m.note),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme.colorScheme.primary,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                              onTap: () {
                                Navigator.of(context).pop();
                                _seek(
                                  m.chapter,
                                  text: m.excerpt,
                                  scroll: m.scroll,
                                );
                              },
                              trailing: PopupMenuButton<String>(
                                tooltip: t.bookMarkActions,
                                onSelected: (v) async {
                                  switch (v) {
                                    case 'note':
                                      final note = await askNote(m.note.trim());
                                      if (note != null) {
                                        await actions.setNote(m.id, note);
                                      }
                                    case 'delete':
                                      await actions.remove(m.id);
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'note',
                                    child: Text(
                                      m.hasNote
                                          ? t.bookEditNote
                                          : t.bookWriteNote,
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(t.dtoActionDelete),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 阅读设置：字号 / 行距 / 背景主题 / 两端对齐
  Future<void> _showPrefs(BuildContext context) async {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final t = context.t;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final prefs = ref.watch(readerPrefsProvider);
          final notifier = ref.read(readerPrefsProvider.notifier);
          return SafeArea(
            // ⚠️ 必须可滚动：小屏/键盘弹出时这一屏放不下（测试默认 800×600
            // 就溢出 21px），设置项以后只会更多不会更少。
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Gap.md,
                      Gap.sm,
                      Gap.md,
                      Gap.xs,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            t.readerPrefsTitle,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        Text(
                          t.readerPrefsGlobal,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // 字号：左右两颗按钮 + 当前值（比滑块更容易点准）
                  DesignRowTile(
                    title: Text(t.readerFontSize),
                    subtitle: Text(
                      '${prefs.fontSize.round()} px',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: hud.dim,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const Key('book-font-smaller'),
                          tooltip: t.readerFontSmaller,
                          icon: const Icon(Icons.text_decrease),
                          onPressed: () => notifier.stepFontSize(-1),
                        ),
                        IconButton(
                          key: const Key('book-font-bigger'),
                          tooltip: t.readerFontBigger,
                          icon: const Icon(Icons.text_increase),
                          onPressed: () => notifier.stepFontSize(1),
                        ),
                      ],
                    ),
                  ),
                  // ★ 第 236 轮（`DA180`，用户裁定 ③）：**选项多的时候标签不能被压成竖排**。
                  //   原来这两行是 `DesignRowTile(trailing: Wrap(ChoiceChip...))`，
                  //   trailing 不限宽 ⇒ 标题列被挤到 ~40dp：真机上
                  //   `Line spacing` 变成「Line / spacin / g」、`Background` 变成
                  //   「B / ac / kg / ro / un / d」一列碎字（亮色实测截图）。
                  //   选项多 ⇒ 改成**上下两段**（标签在上、切块在下），这也是分段选择的常规排版。
                  _PrefsChoiceRow(
                    title: t.readerLineHeight,
                    value: t.readerLineHeightValue(
                      prefs.lineHeight.toStringAsFixed(1),
                    ),
                    chips: [
                      for (final h in ReaderPrefs.lineHeights)
                        ChoiceChip(
                          label: Text(h.toStringAsFixed(1)),
                          selected: (prefs.lineHeight - h).abs() < 0.01,
                          onSelected: (_) => notifier.setLineHeight(h),
                        ),
                    ],
                  ),
                  _PrefsChoiceRow(
                    title: t.readerBackground,
                    chips: [
                      for (final opt in [
                        ('normal', t.readerThemeFollow),
                        ('sepia', t.readerThemeSepia),
                        ('night', t.readerThemeNight),
                      ])
                        ChoiceChip(
                          label: Text(opt.$2),
                          selected: prefs.theme == opt.$1,
                          onSelected: (_) => notifier.setTheme(opt.$1),
                        ),
                    ],
                  ),
                  DesignSwitchRow(
                    title: Text(t.readerJustify),
                    subtitle: Text(
                      t.readerJustifySubtitle,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: hud.dim,
                      ),
                    ),
                    value: prefs.justify,
                    onChanged: notifier.setJustify,
                  ),
                  const SizedBox(height: Gap.xs),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 目录面板：与 PDF 阅读器**共用同一个面板**（`book_toc_sheet.dart`）。
  ///
  /// 这里只做"翻译"：书的目录 → [TocEntry]（层级 + 当前章高亮），面板本身的
  /// 样式、筛选、空态、缩进规则都在共用实现里。
  void _showToc(BuildContext context) {
    final book = widget.book;
    // 优先用**书自带的目录**（嵌套层级 + 精确跳转）；书里没有目录时退回按章节列。
    final hasOwnToc = book.toc.isNotEmpty;
    final entries = [
      if (hasOwnToc)
        for (final e in book.toc)
          TocEntry(
            title: e.title,
            depth: e.depth,
            index: e.chapterIndex,
            current: e.chapterIndex == widget.chapter,
          )
      else
        for (var i = 0; i < book.chapters.length; i++)
          TocEntry(
            title: bookChapterTitle(book.chapters[i], i, context.t),
            index: i,
            current: i == widget.chapter,
          ),
    ];
    showBookTocSheet(
      context,
      entries: entries,
      // 没有原书目录时按"章"计数（`12 章`），有目录时说明来源（`4 条 · 原书目录`）
      sourceLabel: hasOwnToc ? context.t.bookOwnToc : null,
      fallbackUnitLabel: context.t.bookTocUnit,
      onPick: (e) {
        final i = e.index;
        if (i != null) widget.onChapter(i);
      },
    );
  }
}

/// 一章的正文（单独一层，方便 `PageView` 按需构建/回收）
///
/// 这一层负责阅读器的**外观与位置**：
///   * 外观：字号（`MediaQuery.textScaler`，标题也按比例放大）、行距
///     （`DefaultStyles` 的 `height`）、背景/文字色（三种阅读主题）、两端对齐
///     （给整章打 `Attribute.justifyAlignment`）；
///   * 位置：恢复上次读到的百分比、滚动时上报、搜索/书签跳过来时定位到命中处。
class _ChapterBody extends ConsumerStatefulWidget {
  const _ChapterBody({
    required this.book,
    required this.chapter,
    required this.bookKey,
    required this.onAiSelection,
    required this.onLink,
    required this.onSelectAction,
    required this.onScroll,
    this.initialScroll = 0,
    this.seekText = '',
    this.seekScroll = 0,
  });

  final BookContent book;
  final int chapter;
  final String bookKey;
  final void Function(AiTaskKind kind, String text) onAiSelection;

  /// 点正文里的 `<a href>`：书内锚点跳段 / 外链开浏览器
  final ValueChanged<String> onLink;

  /// 选中菜单里的查词 / 朗读 / 导出到笔记
  final void Function(BookSelectionAction action, String text) onSelectAction;

  /// 章内位置变化（0..1）
  final ValueChanged<double> onScroll;

  /// 打开时恢复到的位置
  final double initialScroll;

  /// 跳转目标：要高亮的片段（搜索词 / 书签摘录），空 = 不定位
  final String seekText;

  /// 片段找不到时的兜底位置（0..1）
  final double seekScroll;

  @override
  ConsumerState<_ChapterBody> createState() => _ChapterBodyState();
}

class _ChapterBodyState extends ConsumerState<_ChapterBody> {
  /// ⚠️ 控制器必须**在 State 里建一次**：原来写在 `build` 里，每次重建都换
  /// 一个新 controller，选中的文字/滚动位置会在父级 setState 时丢；
  /// 而且选句工具条要读 controller 的 selection，必须有个稳定引用。
  late final quill.QuillController _controller;
  final ScrollController _scroll = ScrollController();

  /// 起始位置只恢复一次 / 同一个跳转目标只处理一次
  var _restored = false;
  String _appliedSeek = '';

  /// 两端对齐当前是否已经打进文档（按需打、退出时不用清）
  var _justified = false;

  @override
  void initState() {
    super.initState();
    _controller = quill.QuillController(
      document: quill.Document.fromJson(
        noteHtmlToDelta(widget.book.chapters[widget.chapter].html),
      ),
      selection: const TextSelection.collapsed(offset: 0),
      // ⚠️ 真机上发现的：`QuillController.readOnly` 默认是 **false**，
      // 只设 `showCursor: false` 拦不住输入 —— 点正文再打字，字会直接插进
      // 书里（不会保存，但用户看到书被人改了）。阅读器必须是只读的，
      // 选中/选句工具条不受影响（`enableInteractiveSelection` 单独生效）。
      readOnly: true,
    );
    _scroll.addListener(_reportScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restorePosition();
      // ⚠️ 新构建的页也要处理跳转目标：搜索/书签/**脚注跳回**落到一个
      // PageView 之前没建过的页时，只调 `_restorePosition` 会把目标位置
      // 丢掉（正文停在章首）。这里补一次 `_seekToTarget`。
      if (widget.seekText.isNotEmpty || widget.seekScroll > 0) _seekToTarget();
    });
  }

  @override
  void didUpdateWidget(covariant _ChapterBody old) {
    super.didUpdateWidget(old);
    if (old.chapter != widget.chapter) {
      // 换章 = 换正文（`PageView` 通常会新建 State，这里兜一手）
      _restored = false;
      _appliedSeek = '';
      _justified = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restorePosition());
      return;
    }
    if (widget.seekText != old.seekText ||
        widget.seekScroll != old.seekScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _seekToTarget());
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_reportScroll);
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _reportScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    widget.onScroll(max <= 0 ? 0 : (_scroll.offset / max).clamp(0.0, 1.0));
  }

  /// 打开时回到上次读到的位置（只做一次）
  void _restorePosition() {
    if (_restored) return;
    _restored = true;
    if (widget.initialScroll <= 0) return;
    _jumpRatio(widget.initialScroll);
  }

  /// 跳到命中的片段（搜索 / 书签）
  void _seekToTarget() {
    final key = '${widget.seekText}|${widget.seekScroll}';
    if (key == _appliedSeek) return;
    _appliedSeek = key;
    final text = widget.seekText.trim();
    var ratio = widget.seekScroll;
    if (text.isNotEmpty) {
      // 在**文档**文本里找（Quill 的 selection 偏移就是按文档算的，比拿
      // HTML 转出来的纯文本更准），找到就选中它 —— 选中范围本身也是一种高亮
      final doc = _controller.document.toPlainText();
      final at = doc.toLowerCase().indexOf(text.toLowerCase());
      if (at >= 0 && doc.isNotEmpty) {
        final end = (at + text.length).clamp(0, doc.length);
        _controller.updateSelection(
          TextSelection(baseOffset: at, extentOffset: end),
          quill.ChangeSource.local,
        );
        ratio = at / doc.length;
      }
    }
    _jumpRatio(ratio);
  }

  /// 按比例滚到章内位置。
  ///
  /// ⚠️ 这是**估算**：Quill 没给"滚到第 N 个字符"的公开接口，按字符占比乘以
  /// 可滚动高度在等宽场景下很准，正文里有大插图时会偏一点。选中范围已经落在
  /// 命中处，所以"看得到命中"这件事不依赖估算精度。
  void _jumpRatio(double ratio) {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return;
    _scroll.jumpTo((max * ratio.clamp(0.0, 1.0)).clamp(0, max));
  }

  /// 选中的纯文本（空 = 没选）
  ///
  /// 数据源是 `EditableTextState.textEditingValue`（= quill 的
  /// `plainTextEditingValue`），它和 `contextMenuAnchors` 来自同一份状态，
  /// 一定不会出现"有菜单、没文本"的错位。
  String _selectionText(TextEditingValue value) {
    final sel = value.selection;
    if (!sel.isValid || sel.isCollapsed) return '';
    final text = value.text;
    final start = sel.start.clamp(0, text.length);
    final end = sel.end.clamp(0, text.length);
    if (end <= start) return '';
    return text.substring(start, end).trim();
  }

  /// 阅读外观 → Quill 的 `DefaultStyles`（只改行距，颜色交给外层 Theme）
  quill.DefaultStyles _styles(
    BuildContext context,
    ReaderPrefs prefs, {
    Color? ink,
  }) {
    final base = quill.DefaultStyles.getInstance(context);
    // ★ DA205（真机 r614）：Sepia/Night 只换了 `ColoredBox` 的底色与一层 `Theme`
    //   `bodyColor`，但 `DefaultStyles.getInstance(context)` 拿的是**外层**（亮色）
    //   主题，块样式里已经写死了亮色墨色 ⇒ 换主题后正文仍然用 #0F172A。
    //   Night 的纸是 #0B0B0C，于是正文只有 **1.10:1**（几乎看不见）。
    //   ⇒ 把阅读主题的墨色显式喂进每一层样式。
    quill.DefaultTextBlockStyle? withHeight(quill.DefaultTextBlockStyle? s) =>
        s?.copyWith(
          style: s.style.copyWith(
            height: prefs.lineHeight,
            color: ink ?? s.style.color,
          ),
        );
    TextStyle? tint(TextStyle? s) =>
        s == null || ink == null ? s : s.copyWith(color: ink);
    return quill.DefaultStyles(
      h1: withHeight(base.h1),
      h2: withHeight(base.h2),
      h3: withHeight(base.h3),
      h4: withHeight(base.h4),
      h5: withHeight(base.h5),
      h6: withHeight(base.h6),
      paragraph: withHeight(base.paragraph),
      lineHeightNormal: withHeight(base.lineHeightNormal),
      lineHeightTight: withHeight(base.lineHeightTight),
      lineHeightOneAndHalf: withHeight(base.lineHeightOneAndHalf),
      lineHeightDouble: withHeight(base.lineHeightDouble),
      bold: tint(base.bold),
      italic: tint(base.italic),
      underline: tint(base.underline),
      strikeThrough: tint(base.strikeThrough),
      inlineCode: base.inlineCode,
      link: tint(base.link),
      lists: base.lists,
      quote: withHeight(base.quote),
      code: withHeight(base.code),
      indent: withHeight(base.indent),
      align: withHeight(base.align),
      leading: withHeight(base.leading),
      sizeSmall: base.sizeSmall,
      sizeLarge: base.sizeLarge,
      sizeHuge: base.sizeHuge,
      palette: base.palette,
      placeHolder: withHeight(base.placeHolder),
      color: ink ?? base.color,
    );
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final theme = Theme.of(context);
    final prefs = ref.watch(readerPrefsProvider);

    // 阅读主题的纸色/墨色：**先算**，墨色要同时喂给自定义样式（DA205）。
    final colors = readerColorsOf(prefs.theme);
    final fg = colors == null ? null : Color(colors.fg!);

    // 两端对齐：Quill 的对齐只认文档属性，所以要"真的打进 Delta"才生效
    if (prefs.justify && !_justified) {
      _justified = true;
      final len = _controller.document.length;
      if (len > 1) {
        _controller.document.format(
          0,
          len - 1,
          quill.Attribute.justifyAlignment,
        );
      }
    } else if (!prefs.justify && _justified) {
      _justified = false;
      final len = _controller.document.length;
      if (len > 1) {
        _controller.document.format(
          0,
          len - 1,
          quill.Attribute.clone(quill.Attribute.align, null),
        );
      }
    }

    final body = quill.QuillEditor.basic(
      controller: _controller,
      scrollController: _scroll,
      config: quill.QuillEditorConfig(
        scrollable: true,
        autoFocus: false,
        expands: true,
        padding: const EdgeInsets.all(Gap.lg),
        customStyles: _styles(context, prefs, ink: fg),
        embedBuilders: [_BookImageEmbedBuilder(resources: book.resources)],
        // 阅读态：不给光标、不给选择手柄
        showCursor: false,
        enableInteractiveSelection: true,
        // 点正文里的链接（`<a href>` 会变成 Delta 的 link 属性）：
        // `#fn1` / `ch2.xhtml#fn1` → 跳段并可跳回；`https://…` → 系统浏览器。
        onLaunchUrl: widget.onLink,
        // ⚠️ 必须原样透传：flutter_quill 默认的 `_transformLink` 会用
        // `LinkValidator` 校验，书内的 `#fn1` / `ch1.xhtml#fn1` 不是合法 URL，
        // 会被**改写成 `https://#fn1`** —— 结果所有脚注/内链都被当成外链。
        transformLink: (link) => link,
        // 选句工具条：AI（解释 / 翻译）+ 本地动作（查词 / 朗读 / 导出到笔记），
        // 复制保留系统原有能力
        contextMenuBuilder: (context, raw) {
          // ⚠️ 选中文本必须从 `textEditingValue` 取（quill 自己的 copy/cut 也这么干）。
          // 真机踩坑：读 `_controller.selection` 在工具条弹出那一帧是**折叠**的，
          // 于是 `_selected()` 返回空串，菜单里只剩下「复制」。
          final text = _selectionText(raw.textEditingValue);
          final t = context.t;
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: raw.contextMenuAnchors,
            buttonItems: bookSelectionMenuItems(
              t: t,
              text: text,
              onAiSelection: widget.onAiSelection,
              onSelectAction: widget.onSelectAction,
              onCopy: () {
                final messenger = ScaffoldMessenger.of(context);
                Clipboard.setData(ClipboardData(text: text)).then((_) {
                  messenger.showSnackBar(SnackBar(content: Text(t.fileCopied)));
                });
              },
            ),
          );
        },
      ),
    );

    // 字号：整体缩放（标题也跟着放大），而不是只改段落字号 ——
    // 书架里的"字号"用户预期是"整页都变大"。
    final scaled = MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(prefs.fontSize / 16)),
      child: body,
    );

    // 阅读主题：改的是**这个子树**的 textTheme 颜色（DefaultStyles 就是从
    // 它推出来的），不动全局主题。
    final themed = fg == null
        ? scaled
        : Theme(
            data: theme.copyWith(
              textTheme: theme.textTheme.apply(bodyColor: fg, displayColor: fg),
            ),
            child: scaled,
          );

    final bg = colors == null ? null : Color(colors.bg);
    return bg == null ? themed : ColoredBox(color: bg, child: themed);
  }
}

/// 书内插图：Delta 里存的是归一化路径，从 [resources] 取字节渲染
class _BookImageEmbedBuilder extends quill.EmbedBuilder {
  _BookImageEmbedBuilder({required this.resources});

  final Map<String, Uint8List> resources;

  @override
  String get key => 'image';

  @override
  bool get expanded => true;

  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    final raw = '${embedContext.node.value.data}';
    final path = raw.replaceFirst(RegExp(r'^#'), '').split('#').first;
    final bytes = resources[path];
    if (bytes == null) {
      // 找不到就画一行说明，别让整章变成 ErrorBox（真机踩过这种坑）
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Text(
          raw.isEmpty
              ? context.t.bookMissingImage
              : context.t.bookMissingImageNamed(raw),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
    );
  }
}

// ------------------------------------------------------------------ CBZ

class _ComicView extends StatefulWidget {
  const _ComicView({required this.book, this.initialScroll = 0, this.onScroll});

  final BookContent book;

  /// 上次读到第几页（0..1）
  final double initialScroll;

  /// 翻页时上报位置
  final ValueChanged<double>? onScroll;

  @override
  State<_ComicView> createState() => _ComicViewState();
}

class _ComicViewState extends State<_ComicView> {
  late final PageController _pager = PageController(initialPage: _initialPage);
  var _index = 0;

  /// 恢复到的页码（0.87 这种比例四舍五入到页）
  int get _initialPage {
    final pages = widget.book.pages.length;
    if (pages == 0 || widget.initialScroll <= 0) return 0;
    // ★★★ r316c 第二处（同一个功能的"存/取公式不一致"）：
    // 存的是 **1 基比例**（`_jumpToPage` / `onPageChanged` 都发 `(index+1)/total`），
    // 而这里原来按 `(scroll * pages).floor()` 当 **0 基索引**取 —— 读第 2/3 页
    // （scroll=0.667）会 floor 成 2 ⇒ 重开落在**第 3 页**。改成"1 基比例 → 0 基索引"：
    // `ceil(scroll*pages) - 1`（0.667*3=2 → 1=第 2 页；1.0*3=3 → 2=最后一页）。
    return ((widget.initialScroll * pages).ceil() - 1).clamp(0, pages - 1);
  }

  /// 当前页落在目录的哪一条（取**最靠后**且页号不超过当前页的那条：
  /// 一条目录可能覆盖多页，后面的那条才代表"读到哪儿了"）。
  ///
  /// 只用来给底部的目录按钮当标题（与 PDF 阅读器"中键显示当前书签"同一口径）；
  /// 没有目录 / 没覆盖到 → null，按钮退回 [AppText.bookTocTitle]。
  String? get _currentTocTitle {
    String? found;
    var at = -1;
    for (final e in widget.book.toc) {
      if (e.title.isEmpty) continue;
      if (e.chapterIndex <= _index && e.chapterIndex >= at) {
        at = e.chapterIndex;
        found = e.title;
      }
    }
    return found;
  }

  /// 目录条目 → 跳到该页。
  ///
  /// 位图路线（扫描书 DJVU）的 `BookTocEntry.chapterIndex` 就是 **0 基页索引**；
  /// 跳完必须让"当前页"与"翻页进度"**同步**：页脚读 [_index]，进度走 `onScroll`
  /// （写进 `BookStore`，重开才能落回同一页）。
  void _jumpToPage(int page) {
    final total = widget.book.pages.length;
    if (total == 0) return;
    final target = page.clamp(0, total - 1);
    // `jumpToPage` 会同步派发滚动通知 → `PageView.onPageChanged`
    // （那里更新 `_index` 并上报进度）。
    if (_pager.hasClients) _pager.jumpToPage(target);
    // 控制器还没 attach（首帧前 / 零页）或本来就在这一页时回调不会来，
    // 这里兜底同步一次，保证"点了目录 → 页码和进度一定跟着变"。
    if (_index != target) {
      setState(() => _index = target);
      widget.onScroll?.call(
        total <= 1 ? 1 : ((target + 1) / total).clamp(0.0, 1.0),
      );
    }
  }

  /// 目录面板：与文本 / PDF 阅读器**共用同一个面板**（`book_toc_sheet.dart`）。
  ///
  /// 这里只做"翻译"：书的目录 → [TocEntry]（层级 + 页码 + 当前页高亮），
  /// 面板的样式、筛选、空态、缩进都在共用实现里。漫画包一般没有目录，
  /// 所以入口在 [build] 里就按 `book.toc.isNotEmpty` 收掉了，不会弹空面板。
  void _showToc(BuildContext context) {
    final book = widget.book;
    if (book.toc.isEmpty) return; // 防御：没目录绝不弹空面板
    showBookTocSheet(
      context,
      entries: [
        for (final e in book.toc)
          TocEntry(
            title: e.title,
            depth: e.depth,
            // 位图路线的 chapterIndex = 0 基页索引，面板原样回传
            index: e.chapterIndex,
            trailing: context.t.bookPageN(e.chapterIndex + 1),
            current: e.chapterIndex == _index,
          ),
      ],
      sourceLabel: context.t.bookOwnToc,
      fallbackUnitLabel: context.t.bookTocUnit,
      onPick: (e) {
        final i = e.index;
        if (i != null) _jumpToPage(i);
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _index = _initialPage;
    if (widget.initialScroll > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final pages = widget.book.pages.length;
        widget.onScroll?.call(
          pages <= 1 ? 1 : ((_index + 1) / pages).clamp(0.0, 1.0),
        );
      });
    }
  }

  /// ★★★ r316c 第三处（真正的拦路虎）：进度是**异步**读回来的（见 `_applySaved`），
  /// 所以 `widget.initialScroll` 往往在**首帧之后**才从 0 变成 0.667 ——
  /// 而 `_pager` 是 `late final`，`initialPage` 只在创建时取一次 ⇒ 新值被丢弃，
  /// 真机与用例都停在 `1/3`。这里补上"初始位置变了就跳一次"。
  @override
  void didUpdateWidget(covariant _ComicView old) {
    super.didUpdateWidget(old);
    if (widget.initialScroll == old.initialScroll) return;
    final target = _initialPage;
    if (target == _index) return;
    // 布局期间不能跳：等这一帧画完
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToPage(target);
    });
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final pages = widget.book.pages;
    // 目录入口只在**真的有目录**时出现：没有 NAVM 的扫描书、漫画包都没有目录，
    // 这时按钮不显示（不是灰按钮），也就绝不会弹出空面板。
    final hasToc = widget.book.toc.isNotEmpty;
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pager,
            itemCount: pages.length,
            onPageChanged: (i) {
              setState(() => _index = i);
              final pages = widget.book.pages.length;
              widget.onScroll?.call(
                pages <= 1 ? 1 : ((i + 1) / pages).clamp(0.0, 1.0),
              );
            },
            itemBuilder: (context, i) => InteractiveViewer(
              // 漫画页常常要放大看小字
              maxScale: 4,
              child: Center(child: Image.memory(pages[i], fit: BoxFit.contain)),
            ),
          ),
        ),
        if (hasToc)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.sm, 4, Gap.sm, 0),
            child: Center(
              // 与文本 / PDF 阅读器**同一种入口**：底部操作条正中的
              // `FilledButton.tonalIcon`，同一个图标（`list_alt`）、同一个
              // tooltip 与兜底文案（`bookTocTitle`）—— 入口形式与文案都复用。
              child: Tooltip(
                message: t.bookTocTitle,
                child: FilledButton.tonalIcon(
                  key: const Key('book-comic-toc'),
                  // ⚠️ 主题里 FilledButton 的 `minimumSize` 是 `Size.fromHeight(48)`
                  // （= 整行宽，见 app_theme.dart）。放 Row/Center 里当小按钮用
                  // 必须覆盖，否则拿到 minWidth=∞，直接崩布局（见 `_BookReader`）。
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                  ),
                  onPressed: () => _showToc(context),
                  icon: const Icon(Icons.list_alt, size: 18),
                  label: Text(
                    _currentTocTitle ?? t.bookTocTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            // 页脚：格式名取枚举自己的 label，以后接 CBR 之类不用再来改这行
            '${widget.book.format.label} · ${_index + 1}/${pages.length}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: hud.dim),
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 提示

class _BookHint extends StatelessWidget {
  const _BookHint({
    required this.icon,
    required this.title,
    required this.detail,
    this.hint,
    this.color,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? hint;
  final Color? color;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: color ?? hud.dim),
            const SizedBox(height: Gap.md),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
            if (hint != null) ...[
              const SizedBox(height: Gap.xs),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: Gap.md),
              FilledButton(
                onPressed: onRetry,
                child: Text(context.t.photoRetry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 阅读设置里的"标签在上、切块在下"一行 —— 选项 ≥3 个时不能和标题抢横向空间。
class _PrefsChoiceRow extends StatelessWidget {
  const _PrefsChoiceRow({required this.title, required this.chips, this.value});

  final String title;
  final String? value;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final p = DesignPalette.of(context);
    // ★ 仍然走 `DesignRowTile`（设计语言组件，`DA130` 有用量下界），
    //   但把"标签 + 切块"整体放进 title：trailing 不参与横向抢位，
    //   窄屏就不会把标签挤成竖排（`DA180`）。
    return DesignRowTile(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: DesignType.titleSmallSize,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
              ),
              if (value != null)
                Text(
                  value!,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: p.dim),
                ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: chips),
          ),
        ],
      ),
    );
  }
}

/// 空态文案的居中容器：**带水平内边距**。
///
/// ★ 真机 r610（`DA202`）：搜索弹层的两句空态提示原来直接 `Center(child: Text)`，
/// 在 1148 px 宽的真机上文字**从 x=1 开始、右端被裁到 1125** —— 贴着屏幕边缘，
/// 圆角屏上还会被切掉。这里统一给水平内边距，任何长度都留出安全区。
class _PaddedCenter extends StatelessWidget {
  const _PaddedCenter({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      child: Center(child: child),
    );
  }
}
