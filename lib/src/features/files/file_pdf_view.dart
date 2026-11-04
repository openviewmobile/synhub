// PDF 内嵌预览（P0.1 尾巴）。
//
// 为什么内嵌：官方 FileStation/Drive 的 PDF 是**在 App 里翻页看**的，交系统应用
// 会把用户踢出我们的浏览路径（返回后还得重新找目录）。所以 PDF 单独做一页。
//
// 实现选择：`pdfx` —— Android 用**系统自带**的 `android.graphics.pdf.PdfRenderer`，
// iOS/macOS 用 PDFKit，**不额外带原生库**（APK 不变大，构建也不需要下载二进制；
// 我们试过 pdfrx，它会在构建期去 GitHub 拉 PDFium，离线/受限网络直接失败）。
//
//   * 不走 pdfx 的 URL 下载：DSM 的下载 URL 要带 `_sid`，自签名证书也由我们的
//     Dio（指纹固定）统一处理 —— 所以**先用 `fileBytesProvider` 取字节**
//     （与图片/文本预览同一条链路），再喂给 `PdfDocument.openData`；
//   * 大文件不内嵌（`kInlinePreviewMaxBytes`），仍走"交系统应用"。
//
// 平台通道在单测里不可用，所以渲染器是**可注入的**（`filePdfViewerProvider`）：
// 单测注入假 builder，只验证"选对了渲染路径 + 字节来自鉴权下载"。
//
// **目录（书签）**：`pdfx`/系统 `PdfRenderer` 没有目录 API，所以自己解析字节
// （`pdf_doc.dart`，纯 Dart，含 xref 流/对象流）。目录按钮放在**底部正中**
// —— 单手拿手机时顶部的够不到（用户反馈），点条目直接 `jumpToPage`。
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/app_shapes.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import 'file_providers.dart';
import '../ai/ai_assistant_sheet.dart';
import '../ai/ai_floating_orb.dart';
import '../ai/on_device_ai.dart';
import '../ai/ai_service.dart' show withRetrieval;
import '../ai/text_ai.dart' show passagesOfBook;
import '../analytics/analytics_track.dart' show trackOnce;
import '../analytics/usage_event.dart' show UsageAction, UsageModule;
import 'book_toc_sheet.dart';
import 'pdf_doc.dart';
import 'pdf_poppler_view.dart';
import '../../core/media/pdf_local_copy.dart';
import '../drive/drive_pdf_markup_page.dart';
import '../../core/user_facing_error.dart';

/// PDF 渲染器：拿到字节后画出来。返回值要能自己滚（PDF 通常多页）。
typedef FilePdfViewerBuilder =
    Widget Function(BuildContext context, FileEntryDto entry, Uint8List bytes);

/// PDF 本地副本的落盘方式（可注入 ⇒ 离线用例不碰平台通道、不写真实缓存）。
///
/// ★ r434：**不许**再走 `PdfDocument.openData` —— 那会让 pdfx 把整份 PDF 写到
/// 缓存**根层**（`<32 位十六进制>.pdf`），我们的用量/清理/淘汰**都看不到它**。
/// 见 `lib/src/core/media/pdf_local_copy.dart` 的文件头。
final pdfLocalCopyProvider = Provider<PdfLocalCopy>(
  (ref) => defaultPdfLocalCopy,
);

/// 真实实现：pdfx（Android 系统 PdfRenderer / iOS-macOS PDFKit）
Widget buildPdfxViewer(
  BuildContext context,
  FileEntryDto entry,
  Uint8List bytes,
) => _PdfxView(bytes: bytes, fileName: entry.name);

/// PDF 目录解析：**CPU 活**（要解 xref 流/对象流），所以丢到 isolate。
///
/// 为什么单独抽成函数：`filePdfTocProvider` 用它，测试不需要真的跑 isolate。
List<PdfTocEntry> parsePdfTocSync(Uint8List bytes) => parsePdfToc(bytes);

/// 一份 PDF 的目录（解析失败/没有目录 → 空表；UI 就不显示目录按钮）
final filePdfTocProvider = FutureProvider.autoDispose
    .family<List<PdfTocEntry>, Uint8List>((ref, bytes) async {
      // 大文件别卡 UI 线程：几十 MB 的 PDF 解 xref 流是实打实的 CPU 时间
      if (bytes.length > 1 << 20) {
        return Isolate.run(() => parsePdfTocSync(bytes));
      }
      return parsePdfTocSync(bytes);
    });

/// ★ r691（`DA330`）：Linux 上 `pdfx` **没有实现**（插件只声明 Android/iOS/
/// macOS/Windows）⇒ 这一页以前只能"交系统应用"。现在按平台分流：
/// Linux 走 **poppler**（`pdftoppm`，纯 CPU 出 PNG），其它平台仍是 pdfx。
/// 判据是 `defaultTargetPlatform`（不是 `Platform.isLinux`）—— 与仓库里
/// 其余平台分流的写法一致，也让 `flutter test` 能在任意宿主上注入。
final filePdfViewerProvider = Provider<FilePdfViewerBuilder>(
  (ref) => defaultTargetPlatform == TargetPlatform.linux
      ? buildPopplerPdfViewer
      : buildPdfxViewer,
);

/// Linux / 桌面上的 PDF 出图（poppler）。
///
/// 与 `buildPdfxViewer` 的差别：poppler 每次只给**一页位图**，所以翻页由它自己的
/// 底部条负责；外层的目录条通过 `onPage` 拿到"第 x / y 页"并调 `jumpTo`。
Widget buildPopplerPdfViewer(
  BuildContext context,
  FileEntryDto entry,
  Uint8List bytes,
) => _PopplerPage(bytes: bytes);

/// 按页抽出来的文字（AI 用）。**一次解析**拿到每一页，空串 = 那页没文字。
///
/// 为什么做成 provider：AI 面板要"总结本页"和"问整份 PDF"两颗按钮共用同一份结果，
/// 抽一次就够；大文件丢 isolate，别卡 UI 线程。
final filePdfPagesProvider = FutureProvider.autoDispose
    .family<List<String>, Uint8List>((ref, bytes) async {
      if (bytes.length > 1 << 20) {
        return Isolate.run(() => extractPdfPages(bytes));
      }
      return extractPdfPages(bytes);
    });

/// 打开 PDF 的 AI 面板（pdfx 与 poppler **两条渲染路共用**）。
///
/// 为什么抽出来：r691 之前这段逻辑长在 `_PdfxViewState` 里，Linux 换成 poppler
/// 之后如果不共用，就等于"Linux 上 PDF 没有 AI 入口" —— 那是功能倒退。
Future<void> openPdfAiSheet(
  BuildContext context,
  WidgetRef ref, {
  required Uint8List bytes,
  required String fileName,
  required int page,
}) async {
  List<String> pages;
  try {
    pages = await ref.read(filePdfPagesProvider(bytes).future);
  } finally {}
  if (!context.mounted) return;

  final nonEmpty = [
    for (final p in pages)
      if (p.trim().isNotEmpty) p,
  ];
  if (nonEmpty.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(lastPdfTextError ?? context.t.pdfNoExtractableText),
      ),
    );
    return;
  }

  final name = fileName.isEmpty ? 'PDF' : fileName;
  final here = page >= 1 && page <= pages.length ? pages[page - 1] : '';
  final usePage = here.trim().isNotEmpty;
  final subject = usePage ? here : nonEmpty.first;
  final where = usePage
      ? context.t.pdfPageN(page)
      : context.t.pdfPageN(pages.indexOf(nonEmpty.first) + 1);
  trackOnce(UsageModule.reader, UsageAction.open, objectType: 'ai');

  showAiAssistant(
    context,
    title: '$name · $where',
    tasks: const [AiTaskKind.summary, AiTaskKind.askBook],
    labelOverrides: {AiTaskKind.askBook: context.t.pdfAskTitle},
    askHint: context.t.pdfAskHint,
    build: (kind, question) {
      if (kind == AiTaskKind.askBook) {
        final tt = context.t;
        final passages = passagesOfBook(name, [
          for (var i = 0; i < pages.length; i++) tt.pdfPageN(i + 1),
        ], pages);
        return withRetrieval(
          AiRequest(
            kind: kind,
            text: subject,
            title: name,
            question: question,
          ),
          passages,
        );
      }
      return AiRequest(
        kind: kind,
        text: subject,
        title: '$name · $where',
      );
    },
  );
}

/// pdfx 的查看器：`PdfDocument.openData` 要 `Future<Uint8List>`，
/// 而我们的字节已经在手上（`fileBytesProvider` 取好了），所以直接包一层。
class _PdfxView extends ConsumerStatefulWidget {
  const _PdfxView({required this.bytes, this.fileName = ''});

  final Uint8List bytes;

  /// 文件名（AI 面板的出处）
  final String fileName;

  @override
  ConsumerState<_PdfxView> createState() => _PdfxViewState();
}

class _PdfxViewState extends ConsumerState<_PdfxView> {
  pdfx.PdfController? _controller;

  /// 当前页 / 总页数（`PdfView` 的回调给，用来显示"第 x/y 页"和跳页边界）
  int _page = 1;
  int _pageCount = 0;

  /// 正在抽文字（AI 入口转圈用）
  bool _readingText = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  void _open() {
    _page = 1;
    _pageCount = 0;
    // ★ r434：先落到**已登记**的 `pdf_renderer_cache/`（内容摘要命名 ⇒ 复用），
    //   再 `openFile` —— 别再 `openData`（插件会写缓存根层，清不掉）。
    final copy = ref.read(pdfLocalCopyProvider);
    _controller = pdfx.PdfController(
      document: copy(widget.bytes).then(pdfx.PdfDocument.openFile),
      initialPage: 1,
    );
  }

  /// 跳页（目录条目、上一页/下一页都用它）。
  ///
  /// `PdfController.jumpToPage` 内部直接 `_pageController!` —— 视图还没挂上
  /// 时是 null，会崩；所以这里兜住（真出现也只是"这一次没跳成"）。
  void _jump(int page) {
    final c = _controller;
    if (c == null) return;
    final target = page.clamp(1, _pageCount == 0 ? page : _pageCount);
    if (target == _page) return;
    try {
      c.jumpToPage(target);
    } catch (_) {}
  }

  /// 打开 AI 助手：先抽文字，再按"本页 / 整份"组请求。
  ///
  /// PDF 的正文对渲染器来说是**图片**（系统 PdfRenderer 只出位图），所以必须先
  /// 自己抽文字（`pdf_doc.dart` 里的 `extractPdfPages`）。抽不到（扫描件、纯图
  /// PDF）就如实说明，不装模作样地总结一堆空话。
  Future<void> _openAi() async {
    if (_readingText) return;
    setState(() => _readingText = true);
    try {
      await openPdfAiSheet(
        context,
        ref,
        bytes: widget.bytes,
        fileName: widget.fileName,
        page: _page,
      );
    } finally {
      if (mounted) setState(() => _readingText = false);
    }
  }

  @override
  void didUpdateWidget(covariant _PdfxView old) {
    super.didUpdateWidget(old);
    // 换了一份字节（重试/切文件）→ 重新开文档
    if (old.bytes != widget.bytes) {
      setState(_open);
    }
  }

  @override
  void dispose() {
    // pdfx 的 PdfController 自己管文档生命周期（没有公开的 close）
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // 目录：解析字节（大文件走 isolate）。空表 = 这本 PDF 没有书签。
    final toc =
        ref.watch(filePdfTocProvider(widget.bytes)).value ??
        const <PdfTocEntry>[];
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              pdfx.PdfView(
                controller: controller,
                // 竖向翻页更像阅读器
                scrollDirection: Axis.vertical,
                onPageChanged: (p) {
                  if (mounted) setState(() => _page = p);
                },
                onDocumentLoaded: (doc) {
                  if (mounted) setState(() => _pageCount = doc.pagesCount);
                },
                onDocumentError: (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.t.pdfParseFailed(userFacingError(e)))),
                  );
                },
                builders: pdfx.PdfViewBuilders<pdfx.DefaultBuilderOptions>(
                  options: const pdfx.DefaultBuilderOptions(),
                  documentLoaderBuilder: (context) => Center(
                    child: Text(
                      context.t.pdfParsing,
                      style: TextStyle(color: hud.dim),
                    ),
                  ),
                  pageLoaderBuilder: (context) => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  errorBuilder: (context, error) => Center(
                    child: Text(
                      context.t.pdfOpenFailedDetail(userFacingError(error)),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: hud.dim),
                    ),
                  ),
                ),
              ),
              // AI 助手：与电子书阅读器同一个悬浮球（可拖/贴边/收起）。
              // PDF 的正文对渲染器来说是图片，所以点它先**抽文字**再开面板。
              AiFloatingOrb(busy: _readingText, onTap: _openAi),
            ],
          ),
        ),
        PdfTocBar(page: _page, pageCount: _pageCount, toc: toc, onJump: _jump),
      ],
    );
  }
}

/// Linux 的 PDF 页：poppler 出图 + 目录条 + AI 浮动球。
///
/// 与 `_PdfxView` 的布局契约保持一致（同一位置摆同一个目录条、同一个 AI 球），
/// 差别只在"图从哪来"：这里来自 `pdftoppm`，一次一页。
class _PopplerPage extends ConsumerStatefulWidget {
  const _PopplerPage({required this.bytes});

  final Uint8List bytes;

  @override
  ConsumerState<_PopplerPage> createState() => _PopplerPageState();
}

class _PopplerPageState extends ConsumerState<_PopplerPage> {
  final GlobalKey<PopplerPdfViewState> _viewKey =
      GlobalKey<PopplerPdfViewState>();
  int _page = 1;
  int? _pageCount;
  bool _readingText = false;

  Future<void> _openAi() async {
    if (_readingText) return;
    setState(() => _readingText = true);
    try {
      await openPdfAiSheet(
        context,
        ref,
        bytes: widget.bytes,
        fileName: '',
        page: _page,
      );
    } finally {
      if (mounted) setState(() => _readingText = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final toc = ref.watch(filePdfTocProvider(widget.bytes)).value ??
        const <PdfTocEntry>[];
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: PopplerPdfView(
                  key: _viewKey,
                  bytes: widget.bytes,
                  onPage: (page, count) {
                    if (!mounted) return;
                    setState(() {
                      _page = page;
                      _pageCount = count;
                    });
                  },
                ),
              ),
              AiFloatingOrb(busy: _readingText, onTap: _openAi),
            ],
          ),
        ),
        PdfTocBar(
          page: _page,
          pageCount: _pageCount ?? 0,
          toc: toc,
          onJump: (page) => _viewKey.currentState?.jumpTo(page),
        ),
      ],
    );
  }
}

/// PDF 底部操作条：**目录在正中**（与电子书阅读器同一处，拇指够得到）。
///
/// 单独抽成公开 widget 是为了**能单测**：把它与 `pdfx` 的平台通道解耦，
/// 单测直接 pump 这个条，验证"目录按钮可用性 / 面板内容 / 跳页回调"。
class PdfTocBar extends StatelessWidget {
  const PdfTocBar({
    super.key,
    required this.page,
    required this.pageCount,
    required this.toc,
    required this.onJump,
  });

  /// 当前页（1 基）
  final int page;

  /// 总页数；0 = 文档还没打开
  final int pageCount;

  /// 解析出来的书签（空表 → 目录按钮不可点）
  final List<PdfTocEntry> toc;

  /// 跳页回调（1 基）
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final p = DesignPalette.of(context);
    // 中键上放什么：有目录就显示"当前看到哪一节"（与 EPUB 阅读器一致），
    // 没有目录就退回页码 —— 两者都是此刻最想知道的那个信息。
    final currentTitle = currentEntryTitle(toc, page);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, 4, Gap.sm, 6),
          child: Row(
            children: [
              // 两侧按钮用**自身宽度**贴边（同电子书阅读器：套 Expanded 会被居中）
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                ),
                onPressed: page > 1 ? () => onJump(page - 1) : null,
                icon: const Icon(Icons.chevron_left, size: 18),
                label: Text(
                  context.t.readerPrevPage,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 目录在正中：单手够得到，且与电子书阅读器同一个位置、同一种外观。
              // 当前书签标题并进这个按钮，省掉单独一行页码。
              Expanded(
                child: Center(
                  // ★ 第 234 轮（`DA178`，用户裁定 ③）：**页码是信息，不是"能不能点"**。
                  //   原来这里一律是 `FilledButton.tonalIcon`，没有目录时
                  //   `onPressed: null` ⇒ 中键整体禁用：亮色真机量到文字
                  //   `(140,144,154)` 压在 `(215,218,224)` 上 = **2.28:1**，
                  //   页码几乎读不出来；禁用底色还多出一块残缺方块。
                  //   现在分两种形态：有目录 → 可点按钮；没有目录 → **只读标签**。
                  child: toc.isEmpty
                      ? Container(
                          key: const Key('pdf-page-indicator'),
                          constraints: const BoxConstraints(minHeight: 40),
                          padding: const EdgeInsets.symmetric(
                            horizontal: Gap.sm,
                            vertical: 8,
                          ),
                          // 形状沿用设计语言 `ChamferBorder`（切角 9）——
                          // r553 我一度改成胶囊，那是**偏离设计稿**：真机上那种
                          // "缺一角"的方块是主题里的切角，不是渲染故障。
                          decoration: ShapeDecoration(
                            color: p.surface2,
                            shape: const ChamferBorder(
                              cut: Radii.cut,
                              side: BorderSide.none,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.list_alt, size: 18, color: p.muted),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  pageCount == 0
                                      ? context.t.bookTocTitle
                                      : context.t.pdfPageOf(page, pageCount),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: p.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Tooltip(
                          message: context.t.bookTocTitle,
                          child: FilledButton.tonalIcon(
                            // 主题里 FilledButton 的 minimumSize 是整行宽，见 app_theme.dart；
                            // Row 里当小按钮必须在本地覆盖，否则 minWidth=∞ 崩布局
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 40),
                              padding: const EdgeInsets.symmetric(
                                horizontal: Gap.sm,
                              ),
                            ),
                            onPressed: () => _showToc(context),
                            icon: const Icon(Icons.list_alt, size: 18),
                            label: Text(
                              currentTitle ?? context.t.pdfPageOf(page, pageCount),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                ),
                onPressed: pageCount > 0 && page < pageCount
                    ? () => onJump(page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right, size: 18),
                label: Text(
                  context.t.readerNextPage,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
                iconAlignment: IconAlignment.end,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 目录面板：与电子书阅读器**共用同一个面板**（`book_toc_sheet.dart`）。
  ///
  /// 这里只做"翻译"：PDF 书签 → [TocEntry]（层级 + 页码 + 当前页高亮），
  /// 面板的样式、筛选、空态、缩进都在共用实现里 —— 用户要求两边"同一套风格"。
  void _showToc(BuildContext context) {
    showBookTocSheet(
      context,
      entries: [
        for (final e in toc)
          TocEntry(
            title: e.title,
            depth: e.depth,
            // PDF 的 pageIndex 是 **0 基**，交给面板原样回传
            index: e.pageIndex,
            trailing: e.pageIndex == null
                ? '—'
                : context.t.pdfPageN(e.pageIndex! + 1),
            current: e.pageIndex != null && e.pageIndex! + 1 == page,
            // 命名目标解析不到页 = 跳不过去 → 灰显，不假装能点
            enabled: e.pageIndex != null,
          ),
      ],
      sourceLabel: context.t.pdfBookmark,
      filterHint: context.t.bookTocFilterHint,
      onPick: (e) {
        final i = e.index;
        if (i != null) onJump(i + 1);
      },
    );
  }
}

/// 当前页落在哪条书签里（取**最靠后**的那条：一页可能被多条覆盖，
/// 后面那条才代表"读到哪儿了"）。没有目录/没有覆盖到 → null（中键退回页码）。
String? currentEntryTitle(List<PdfTocEntry> toc, int page) {
  String? found;
  for (final e in toc) {
    final p = e.pageIndex;
    if (p != null && p + 1 <= page && e.title.isNotEmpty) found = e.title;
  }
  return found;
}

/// PDF 舞台：取字节 → 渲染；出错给"打不开 + 原因"，不假装能看。
class FilePdfStage extends ConsumerWidget {
  const FilePdfStage({super.key, required this.entry, this.bytesUrl});

  final FileEntryDto entry;

  /// 取字节直链（Drive 等非 FileStation 来源）
  final String? bytesUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final req = FileBytesRequest(entry.path, url: bytesUrl);
    final bytes = ref.watch(fileBytesProvider(req));
    final viewer = ref.watch(filePdfViewerProvider);
    return bytes.when(
      loading: () => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: Gap.md),
            Text(context.t.pdfLoading, style: TextStyle(color: hud.dim)),
          ],
        ),
      ),
      error: (e, __) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.picture_as_pdf_outlined, size: 40, color: hud.dim),
              const SizedBox(height: Gap.md),
              Text(context.t.pdfOpenFailed),
              const SizedBox(height: Gap.xs),
              Text(
                describeFileError(e),
                textAlign: TextAlign.center,
                style: TextStyle(color: hud.dim, fontSize: 12),
              ),
              const SizedBox(height: Gap.md),
              OutlinedButton.icon(
                onPressed: () => ref.invalidate(fileBytesProvider(req)),
                icon: const Icon(Icons.refresh),
                label: Text(context.t.photoRetry),
              ),
            ],
          ),
        ),
      ),
      data: (data) => Column(
        children: [
          // ★★ 219 轮 D61：PDF **批注 / 签名**入口（官方包内带 pdfium/pdftool）。
          // 字节已经在手 ⇒ 直接进批注页（本地路径给 sidecar 用）。
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.md,
                vertical: Gap.xs,
              ),
              child: TextButton.icon(
                key: const Key('pdf-markup-entry'),
                icon: const Icon(Icons.edit_note_outlined, size: 18),
                label: Text(context.t.filePdfMarkupEntry),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DrivePdfMarkupPage(
                      filePath: entry.path,
                      fileName: entry.name,
                      bytes: data,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: viewer(context, entry, data)),
        ],
      ),
    );
  }
}
