// 电子书格式的**解析层**（纯逻辑、可离线测试）。
//
// 客户端上真正流行的电子书格式就那么几种，按"能不能在 Flutter 里干净地做"排序：
//
//   * **EPUB**（2/3）：开放标准，事实上的通用格式。本质是 zip + OPF 清单 + 一串
//     XHTML → 纯 Dart 就能解析，正文能用我们已有的 HTML→Delta 管线渲染 → **做**；
//   * **CBZ / CBR**：漫画/杂志，"一堆图片打包成 zip/rar" → 复用同一个 `_ComicView`。
//     CBR 走**自研纯 Dart RAR 解压**（`rar_archive.dart`，零三方依赖）；
//   * **FB2**（FictionBook）：单个 XML 文件，俄语圈常用 → 转成 HTML 即可 → **做**；
//   * **MOBI / AZW3**：Amazon 系（PalmDB + PalmDOC LZ77 / **HUFF-CDIC**），
//     自研纯 Dart 解析（`book_mobi.dart`）→ **MOBI6 与 HUFF/CDIC 都做**
//     （HUFF/CDIC 已用真实 17480 样本端到端验证）；DRM、纯 KF8 给清晰错误
//     （不输出乱码）；
//   * **CHM**（Microsoft HTML Help）：ITSF 容器 + ITSP/PMGL 目录 + **LZX 解压**
//     全部自研（`chm_archive.dart` + `book_chm.dart`），正文是 HTML →
//     直接复用现有 HTML 阅读管线 → **做**；
//   * **DJVU**：DjVuLibre 是 GPL-2.0 → **不用**；改为自研纯 Dart 容器 + BZZ 文本层
//     + JB2 位图 + IW44 小波（`djvu_archive.dart` / `djvu_bzz.dart` /
//     `djvu_jb2.dart` / `djvu_iw44.dart` / `djvu_render.dart` / `book_djvu.dart`），
//     有文本层的书走文本路线、有位图的走和 CBZ 同一套翻页管线 → **做**；
//   * **XPS / OXPS**：OPC zip + FixedDocument 版式（`book_xps.dart`），
//     Glyphs → 文本、ImageBrush → 图片 → **做**；
//   * **FB3**：zip + FictionBook3 XML（`book_fb3.dart`）→ **做**；
//   * **RB**（Rocket eBook）：自研容器 + zlib 分块解压（`book_rb.dart`）→
//     **做**（加密页明确不支持）；
//   * **SNB**：盛大 Bambook `SNBP000B` 自研容器 + bzip2 文本流（`book_snb.dart`）
//     → **做**；其它 SNB 方言给明确结论；
//   * **LIT**（Microsoft Reader）：容器 + DRM 等级已能精确识别，但正文要
//     自研 MS-LZX + LIT-DES + evaporated-HTML 且无真实样本 → **明确不支持**；
//   * PDF / TXT / Markdown：已有各自的预览路径。
//
// 这里只负责"字节 → 结构化内容"，渲染在 `file_book_view.dart`。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as htmlp;

import 'book_comic.dart';
import 'book_chm.dart';
import 'book_djvu.dart';
import 'book_fb3.dart';
import 'book_lit.dart';
import 'book_mobi.dart';
import 'book_office.dart';
import 'book_rb.dart';
import 'book_snb.dart';
import 'book_xps.dart';
import 'rar_archive.dart';
import 'book_text.dart';
import 'files_i18n.dart';

/// 这本书用哪个解析器
enum BookFormat {
  epub('EPUB'),
  fb2('FB2'),
  cbz('CBZ'),

  /// `.cbr`（RAR 漫画包）：自研纯 Dart RAR 解压，和 CBZ 共用漫画阅读管线
  cbr('CBR'),

  /// `.chm`（Microsoft HTML Help）：自研纯 Dart ITSF 容器 + LZX 解压，
  /// 正文走现有 HTML 阅读管线（`chm_archive.dart` / `book_chm.dart`）
  chm('CHM'),

  /// `.djvu`（DjVu）：自研纯 Dart 容器 + BZZ 文本层 + JB2 掩码 + IW44 小波。
  /// 有位图页时走 CBZ 同一套翻页管线；只有隐藏文本层时走富文本阅读器。
  djvu('DJVU'),

  /// `.mobi` / `.azw`（Mobipocket 老后缀，同一容器）
  mobi('MOBI'),

  /// `.azw3`（KF8 容器；joint MOBI/KF8 优先 KF8 半边，失败回落 MOBI6）
  azw3('AZW3'),

  /// 纯文本（编码探测：UTF-8/UTF-16/GBK/GB18030/Big5）
  txt('TXT'),

  /// Markdown（走已有的 `package:markdown` → HTML 管线）
  md('MD'),

  /// HTML / XHTML 单文件
  html('HTML'),

  /// RTF（控制字解析）
  rtf('RTF'),

  /// 老式紧凑文本（TCR 解压后再当纯文本）
  tcr('TCR'),

  /// Word DOCX（zip 容器）
  docx('DOCX'),

  /// OpenDocument Text（zip 容器）
  odt('ODT'),

  /// Excel 工作簿（zip 容器；共享字符串 + 工作表 → 表格）
  xlsx('XLSX'),

  /// PowerPoint 演示文稿（zip 容器；每页一章）
  pptx('PPTX'),

  /// OpenDocument Spreadsheet
  ods('ODS'),

  /// OpenDocument Presentation
  odp('ODP'),

  /// PalmDB / PalmDOC（**没有** MOBI 头的老 Palm 电子书）
  pdb('PDB'),

  /// Palm Resource（`.prc`）：有 MOBI 头当 MOBI 读，否则当 PalmDOC 读
  prc('PRC'),

  /// FictionBook.zip（zip 里包一个 FB2）
  fbz('FBZ'),

  /// tar 漫画包
  cbt('CBT'),

  /// `.xps`（Open XML Paper Specification）：自研纯 Dart OPC 包 + FixedPage
  /// 版式解析（`book_xps.dart`）——Glyphs → 富文本、ImageBrush → 图片。
  xps('XPS'),

  /// `.oxps`（OpenXPS）：与 XPS 同样的固定版式结构，只是打包约定不同
  oxps('OXPS'),

  /// `.fb3`（FictionBook 3）：zip + XML，和 FB2 同一套阅读体验
  fb3('FB3'),

  /// `.lit`（Microsoft Reader / ITOLITLS）：容器识别 + **精确到 DRM 等级与
  /// 所需变换**的结论；正文要自研 MS-LZX + LIT-DES + evaporated-HTML，
  /// 且无真实样本可验证 → 明确不支持（`book_lit.dart`）
  lit('LIT'),

  /// `.rb`（Rocket eBook）：自研容器 + zlib 分块解压 + 裸 PNG 图片
  /// （`book_rb.dart`）→ **正文已实现**（加密页明确不支持）
  rb('RB'),

  /// `.snb`：盛大 Bambook `SNBP000B` 自研容器（zlib VFAT + bzip2 文本块流
  /// + `snbc/*.snbc` XML）；其它 SNB 方言给明确结论（`book_snb.dart`）
  snb('SNB'),

  /// 7z 漫画包（**无纯 Dart 解压实现** → 明确报不支持）
  cb7('CB7'),

  /// 散装 EPUB 的包文件（需要兄弟文件才能读正文）
  opf('OPF'),
  none('');

  const BookFormat(this.label);
  final String label;
}

/// 扩展名 → 格式（大小写不敏感；`.fb2.zip` 这类也认）
BookFormat bookFormatOf(String extension) {
  final e = extension.toLowerCase();
  return switch (e) {
    'epub' => BookFormat.epub,
    'fb2' => BookFormat.fb2,
    'cbz' => BookFormat.cbz,
    'cbr' => BookFormat.cbr,
    'chm' => BookFormat.chm,
    'djvu' || 'djv' => BookFormat.djvu,
    'mobi' || 'azw' => BookFormat.mobi,
    'azw3' => BookFormat.azw3,
    'txt' => BookFormat.txt,
    'md' || 'markdown' => BookFormat.md,
    'html' || 'htm' || 'xhtml' => BookFormat.html,
    'rtf' => BookFormat.rtf,
    'tcr' => BookFormat.tcr,
    'docx' => BookFormat.docx,
    'odt' => BookFormat.odt,
    'xlsx' => BookFormat.xlsx,
    'pptx' => BookFormat.pptx,
    'ods' => BookFormat.ods,
    'odp' => BookFormat.odp,
    'pdb' => BookFormat.pdb,
    'prc' => BookFormat.prc,
    'fbz' => BookFormat.fbz,
    'cbt' => BookFormat.cbt,
    'cb7' => BookFormat.cb7,
    'xps' => BookFormat.xps,
    'oxps' => BookFormat.oxps,
    'fb3' => BookFormat.fb3,
    'lit' => BookFormat.lit,
    'rb' => BookFormat.rb,
    'snb' => BookFormat.snb,
    'opf' => BookFormat.opf,
    _ => BookFormat.none,
  };
}

/// 这本书能不能内嵌阅读（其余交给系统阅读器）
bool isReadableBook(String extension) =>
    bookFormatOf(extension) != BookFormat.none;

/// 解析层**兜底生成**的标题属于哪一类（纯 Dart，不能 import i18n）
enum BookGeneratedUnit { chapter, section, body, page }

/// 书内链接（`<a href>`）的三种形态 —— 纯 Dart，界面据此决定"跳段"还是"开浏览器"。
///
/// E2 的脚注/超链接跳转就靠它：`anchor`（`#fn1`）与 `internal`
/// （`ch1.xhtml#fn1`）走阅读器内部跳转，`external`（`https://…` / `mailto:`）
/// 交系统浏览器。
enum BookLinkKind {
  /// 外链：`http(s):` / `mailto:` / 其它带 scheme 的地址
  external,

  /// 本文件内的锚点：`#fn1`
  anchor,

  /// 书内其它文件的链接（可能带锚点）：`ch2.xhtml` / `ch2.xhtml#fn1`
  internal,
}

/// 一个解析过的书内/外链接
class BookLink {
  const BookLink({
    required this.kind,
    required this.href,
    this.path = '',
    this.fragment = '',
  });

  final BookLinkKind kind;

  /// 原始 href（界面要把它交给系统浏览器）
  final String href;

  /// 归一化后的目标路径（`anchor` 时 = 链接所在文件自己的路径）
  final String path;

  /// 目标锚点（没有 `#` 时为空）
  final String fragment;
}

/// 把 `<a href>` 归类：外链 / 本文件锚点 / 书内跨文件链接。
///
/// [fromHref] 是链接**所在章节**的原始路径（FB2 没有路径时传空串）。
/// 纯函数、无 i18n 依赖，便于 `dart run` 探针与单测直接调用。
BookLink classifyBookLink(String fromHref, String href) {
  final raw = href.trim();
  if (raw.isEmpty) {
    return BookLink(kind: BookLinkKind.internal, href: raw, path: fromHref);
  }
  // `http://`、`https://`、`mailto:`、`data:` … 一律当外链（含 `tel:`）
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:').hasMatch(raw)) {
    return BookLink(kind: BookLinkKind.external, href: raw);
  }
  if (raw.startsWith('#')) {
    return BookLink(
      kind: BookLinkKind.anchor,
      href: raw,
      path: fromHref,
      fragment: raw.substring(1).trim(),
    );
  }
  final resolved = _resolveTarget(_dirOf(fromHref), raw);
  return BookLink(
    kind: BookLinkKind.internal,
    href: raw,
    path: resolved.path,
    fragment: resolved.fragment,
  );
}

/// 章节 HTML 里引用的**书内锚点**（只取带 `#` 的；外链与纯文件链接丢掉）。
///
/// 解析期用它决定"要不要在锚点处把这一章切开"，界面不用调它。
List<({String path, String fragment})> bookInternalLinkTargets(
  String fromHref,
  String html,
) {
  if (html.isEmpty) return const [];
  final root = htmlp.parseFragment(html);
  final out = <({String path, String fragment})>[];
  for (final a in root.querySelectorAll('a[href]')) {
    final href = a.attributes['href'] ?? '';
    if (href.isEmpty) continue;
    final link = classifyBookLink(fromHref, href);
    if (link.kind == BookLinkKind.external || link.fragment.isEmpty) continue;
    out.add((path: link.path, fragment: link.fragment));
  }
  return out;
}

/// 章节 HTML 里所有元素的 `id` / `<a name>`（锚点的"落点"）。
List<String> bookAnchorIds(String html) {
  if (html.isEmpty) return const [];
  final root = htmlp.parseFragment(html);
  final out = <String>[];
  for (final e in root.querySelectorAll('[id]')) {
    final id = (e.attributes['id'] ?? '').trim();
    if (id.isNotEmpty) out.add(id);
  }
  for (final e in root.querySelectorAll('a[name]')) {
    final name = (e.attributes['name'] ?? '').trim();
    if (name.isNotEmpty) out.add(name);
  }
  return out;
}

/// 一章（EPUB 的 spine item / FB2 的 section）
class BookChapter {
  const BookChapter({
    required this.title,
    required this.html,
    this.href = '',
    this.generatedUnit,
  });

  final String title;

  /// [title] 是解析层**兜底生成**的序号标题（`第 N 章` / `第 N 节` / `正文`），
  /// 不是书里写着的标题 —— 界面侧可以据此改用当前语言的文案。
  ///
  /// 解析层是**纯 Dart**（`tool/toc_real.dart` 会直接加载它），不能 import
  /// `core/i18n`，所以本地化只能由界面完成；[title] 保留中文兜底。
  final BookGeneratedUnit? generatedUnit;

  /// [title] 是兜底生成的吗（见 [generatedUnit]）
  bool get generatedTitle => generatedUnit != null;

  /// 已经规整成"我们能渲染的 HTML 子集"的正文
  final String html;

  /// EPUB 里的原始路径（图片相对路径要靠它做基准）
  final String href;
}

/// 目录条目。
///
/// 来源是书**自己带的目录**（EPUB 的 `toc.ncx` / EPUB3 `nav.xhtml`，
/// FB2 的 `<section>` 树），不是"spine 顺序猜出来的章节列表"。
/// [depth] 是层级（0 = 顶层），[chapterIndex] 是需要跳到 [BookContent.chapters]
/// 的哪一段 —— 有锚点（`ch1.xhtml#sec2`）时，解析层会把那一章**在锚点处切开**，
/// 所以"跳到第 2 小节"是精确落到段落，而不是只跳到文件头。
class BookTocEntry {
  const BookTocEntry({
    required this.title,
    required this.chapterIndex,
    this.depth = 0,
  });

  final String title;
  final int chapterIndex;
  final int depth;
}

/// 解析结果（EPUB/FB2 用 [chapters]，CBZ 用 [pages]）
class BookContent {
  const BookContent({
    required this.format,
    this.title = '',
    this.author = '',
    this.chapters = const [],
    this.pages = const [],
    this.resources = const {},
    this.toc = const [],
    this.anchors = const {},
  });

  final BookFormat format;
  final String title;
  final String author;
  final List<BookChapter> chapters;

  /// 书自带的目录（按原书顺序，带层级）；空表示这本书没有目录，
  /// 阅读器就退回"按章节列"。
  final List<BookTocEntry> toc;

  /// 锚点 → 段落下标（E2 的脚注/超链接跳转用）。
  ///
  /// 键是 `归一化路径#锚点id`（FB2 这类没有文件路径的书是 `#锚点id`）。
  /// 有锚点落在章节中间时，解析期已经把那一章**切开**，所以下标就是精确落点；
  /// 找不到的锚点不在表里，界面据此给"这个链接指向的内容不在书里"。
  final Map<String, int> anchors;

  /// CBZ 的漫画页（已按文件名排序）
  final List<Uint8List> pages;

  /// 书内资源：**归一化后的路径** → 字节（EPUB 的插图、封面等）
  final Map<String, Uint8List> resources;

  bool get isEmpty => chapters.isEmpty && pages.isEmpty;

  /// 这个链接跳到第几段（找不到返回 null）
  int? anchorFor(String fromHref, String href) {
    final link = classifyBookLink(fromHref, href);
    if (link.kind == BookLinkKind.external || link.fragment.isEmpty) {
      return null;
    }
    return anchors['${link.path}#${link.fragment}'];
  }
}

/// 格式认识、但用了**我们做不到**的编码/容器（HUFF/CDIC、7z、加密 ODT…）。
///
/// 和"文件坏了"分开：这是能力边界。抛出它的解析路径会被 [parseBook] 翻译成
/// [BookParseErrorKind.unsupportedCompression]，界面文案复用既有的
/// `bookUnsupportedFormat`，**没有新增 ARB key**。
class BookUnsupportedException implements Exception {
  BookUnsupportedException(this.message, {this.reason = BookUnsupportedReason.other});
  final String message;

  /// ★★★ r316c：能力边界要**说人话且按语言说**。
  ///
  /// 真机形态：英文设备上错误面板是
  /// `This format can't be read inline yet · 带密码（加密）的 CBR，本阅读器不解密`
  /// —— 中英混串。原因是界面把 [message]（解析层的中文技术原因）**直接拼**到
  /// 本地化前缀后面（旧口径是"复用既有 ARB key、不新增"）。现在把"原因"变成
  /// **类型**：界面按类型取本地化文案，[message] 只留给日志与离线断言。
  final BookUnsupportedReason reason;

  @override
  String toString() => message;
}

/// 能力边界的**类型**（界面据此取本地化文案；**不比拼中文串**）
enum BookUnsupportedReason {
  /// 认不出来 / 没归类：界面只显示本地化的"不支持"，细节进日志
  other,

  /// 带密码（加密）：CBR 的加密条目 / 加密档头
  encrypted,

  /// 多卷（分卷）包：要全部卷才能解
  multiVolume,

  /// 带 DRM
  drm,

  /// 认识格式但压缩/编码变体做不到（HUFF/CDIC、LZX、FDIST/KF8…）
  compression,

  /// 缺配套文件（散装 EPUB/OPF：正文在兄弟文件里；TRZ 等比）
  missingParts,
}

/// 解析失败的原因类别（界面侧据此取本地化文案；[BookParseResult.error] 是中文兜底）。
enum BookParseErrorKind {
  unsupportedFormat,

  /// 格式认识，但这本书用的编码/容器变体我们做不到（MOBI 的 HUFF/CDIC、
  /// 纯 KF8、DRM）。**和"文件坏了"分开**：前者是能力边界，后者是数据问题。
  unsupportedCompression,
  parseFailed,
}

/// 主入口：按格式解析。
///
/// 解析失败**不抛**业务异常给页面 —— 返回一个 `chapters` 为空、带 [error] 的结果，
/// 让页面能说人话（"这本书打不开，用其他应用试试"）而不是红屏。
class BookParseResult {
  const BookParseResult(
    this.content, {
    this.error,
    this.errorKind,
    this.reason = BookUnsupportedReason.other,
  });

  final BookContent content;
  final String? error;

  /// 失败类别（本地化用；解析层是纯 Dart，见 [BookChapter.generatedTitle]）
  final BookParseErrorKind? errorKind;

  /// ★ r316c：能力边界的**类型**（界面按它取本地化文案；见 `bookUnsupportedReasonText`）。
  /// [error] 仍是解析层的中文技术细节 —— **只进日志与离线断言**，不再当用户文案。
  final BookUnsupportedReason reason;

  bool get ok => error == null && !content.isEmpty;
}

/// [siblings] 是"散装书"的可选兄弟文件表（归一化路径 → 字节）：
/// 只有 HTML/Markdown 的同目录图片、以及 OPF 引用的 XHTML 用得上；
/// 单文件来源（FileStation 只给一个文件的字节）传 null 即可。
///
/// [title] 是调用方给的兜底书名（一般是文件名去掉后缀）：解析层拿不到的书名、
/// 又不该拿"第一章 …"当书名的格式（TXT/HTML/RTF…）用它。
BookParseResult parseBook(
  BookFormat format,
  List<int> bytes, {
  Map<String, Uint8List>? siblings,
  String title = '',
}) {
  BookParseResult result;
  try {
    result = switch (format) {
      BookFormat.epub => BookParseResult(_parseEpub(bytes)),
      BookFormat.fb2 => BookParseResult(_parseFb2(bytes)),
      BookFormat.cbz => BookParseResult(_parseCbz(bytes)),
      BookFormat.cbr => BookParseResult(_parseCbr(bytes)),
      // CHM：自研纯 Dart ITSF/LZX（`chm_archive.dart` + `book_chm.dart`），
      // "能力边界"由 `parseChmBook` 自己翻译成 `unsupportedCompression`。
      BookFormat.chm => parseChmBook(bytes, format: format),
      // DJVU：自研纯 Dart 容器 + 文本层 + JB2/IW44（`book_djvu.dart`），
      // "能力边界"由 `parseDjvuBook` 自己翻译成 `unsupportedCompression`。
      BookFormat.djvu => parseDjvuBook(bytes, format: format),
      // MOBI / AZW3 共用一套 PalmDB 解析；它自己会把"能力边界"翻译成
      // `unsupportedCompression` 而不是抛异常（见 `book_mobi.dart`）。
      BookFormat.mobi ||
      BookFormat.azw3 => parseMobiBook(bytes, format: format),
      BookFormat.txt => BookParseResult(
        parseTxtBook(bytes, format: format, title: title),
      ),
      BookFormat.md => BookParseResult(
        parseMarkdownBook(
          bytes,
          format: format,
          title: title,
          siblings: siblings,
        ),
      ),
      BookFormat.html => BookParseResult(
        parseHtmlBook(bytes, format: format, title: title, siblings: siblings),
      ),
      BookFormat.rtf => BookParseResult(
        parseRtfBook(bytes, format: format, title: title),
      ),
      BookFormat.tcr => BookParseResult(
        parseTcrBook(bytes, format: format, title: title),
      ),
      BookFormat.docx => BookParseResult(parseDocxBook(bytes, format: format)),
      BookFormat.odt => BookParseResult(parseOdtBook(bytes, format: format)),
      // D62 通用查看器：Office 三件套的**只读**结构化预览
      // （XLSX 表格 / PPTX 分页 / ODS·ODP 与 ODT 同族的 ODF 容器）
      BookFormat.xlsx => BookParseResult(parseXlsxBook(bytes, format: format)),
      BookFormat.pptx => BookParseResult(parsePptxBook(bytes, format: format)),
      BookFormat.ods ||
      BookFormat.odp => BookParseResult(parseOdfBook(bytes, format: format)),
      // PalmDB/PalmDOC：`.prc` 带 MOBI 头时内部会转交给 MOBI 解析器
      BookFormat.pdb ||
      BookFormat.prc => parsePalmDocBook(bytes, format: format),
      BookFormat.fbz => BookParseResult(_parseFbz(bytes)),
      // XPS / OXPS：自研纯 Dart OPC 包 + FixedPage 版式解析（`book_xps.dart`），
      // Glyphs → 富文本、ImageBrush → 图片；矢量 Path 明确"未渲染"。
      BookFormat.xps ||
      BookFormat.oxps => BookParseResult(parseXpsBook(bytes, format: format)),
      // FB3：真实形态是 OPC（zip）包 —— Content_Types/rels 发现 part，
      // `fb3-body` 正文 + `fb3-description` 描述 + rels 图片映射（`book_fb3.dart`）。
      // `parseFb3Result` 负责把"缺正文部件 / 包损坏"翻成带具体文案的失败结果。
      BookFormat.fb3 => parseFb3Result(bytes, format: format),
      // LIT：自研 ITOLITLS/ITSF 容器（`book_lit.dart`）；加密/不支持的变体
      // 自己抛 `BookUnsupportedException` → 上面统一翻成"能力边界"。
      BookFormat.lit => BookParseResult(parseLitBook(bytes, format: format)),
      // RB：Rocket eBook，自研容器 + 文本解码（`book_rb.dart`）
      BookFormat.rb => BookParseResult(parseRbBook(bytes, format: format)),
      // SNB：公开信息不足 —— 只做容器识别，明确给结论（`book_snb.dart`）
      BookFormat.snb => BookParseResult(parseSnbBook(bytes, format: format)),
      BookFormat.cbt => BookParseResult(parseCbtBook(bytes, format: format)),
      BookFormat.cb7 => BookParseResult(parseCb7Book(bytes, format: format)),
      BookFormat.opf => BookParseResult(
        parseOpfBook(bytes, format: format, siblings: siblings),
      ),
      BookFormat.none => const BookParseResult(
        BookContent(format: BookFormat.none),
        error: '这个格式还不支持内嵌阅读',
        errorKind: BookParseErrorKind.unsupportedFormat,
      ),
    };
  } on BookUnsupportedException catch (e) {
    // 已知的**能力边界**（HUFF/CDIC、7z、加密 ODT…）：界面文案本地化
    return BookParseResult(
      BookContent(format: format),
      error: e.message,
      errorKind: BookParseErrorKind.unsupportedCompression,
      // ★ r316c：类型化的原因给界面取本地化文案；`e.message` 只进日志/离线断言
      reason: e.reason,
    );
  } catch (e) {
    return BookParseResult(
      BookContent(format: format),
      error: fsT('bookParseFailedDrm', '这本书解析失败（文件可能损坏或带 DRM）'),
      errorKind: BookParseErrorKind.parseFailed,
    );
  }

  // 兜底书名：解析层没拿到书名时用调用方给的（文件名），不要让 TXT 用"第一章"
  if (title.isNotEmpty && result.content.title.isEmpty) {
    final c = result.content;
    return BookParseResult(
      BookContent(
        format: c.format,
        title: title,
        author: c.author,
        chapters: c.chapters,
        pages: c.pages,
        resources: c.resources,
        toc: c.toc,
        anchors: c.anchors,
      ),
      error: result.error,
      errorKind: result.errorKind,
      reason: result.reason,
    );
  }
  return result;
}

/// FBZ：zip 容器里包一个 FB2（`*.fb2`）
BookContent _parseFbz(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  Uint8List? fb2;
  for (final f in archive) {
    if (!f.isFile) continue;
    if (!f.name.toLowerCase().endsWith('.fb2')) continue;
    fb2 = Uint8List.fromList(f.content as List<int>);
    break;
  }
  if (fb2 == null) throw const FormatException('FBZ 里没有 .fb2 文件');
  final inner = _parseFb2(fb2);
  // format 回填 FBZ（书本身还是 FB2 的结构，但标签要显示 FBZ）
  return BookContent(
    format: BookFormat.fbz,
    title: inner.title,
    author: inner.author,
    chapters: inner.chapters,
    resources: inner.resources,
    toc: inner.toc,
    anchors: inner.anchors,
  );
}

// ------------------------------------------------------------------ EPUB

BookContent _parseEpub(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  final files = <String, Uint8List>{};
  for (final f in archive) {
    if (!f.isFile) continue;
    files[_normalize(f.name)] = Uint8List.fromList(f.content as List<int>);
  }

  // 1) container.xml → OPF 路径
  final container = files[_normalize('META-INF/container.xml')];
  var opfPath = '';
  if (container != null) {
    final doc = htmlp.parse(utf8.decode(container, allowMalformed: true));
    final rootfile = _firstByLocal(doc, 'rootfile');
    opfPath = _normalize(rootfile?.attributes['full-path'] ?? '');
  }
  if (opfPath.isEmpty || !files.containsKey(opfPath)) {
    // 兜底：直接找第一个 .opf
    opfPath = files.keys.firstWhere(
      (k) => k.endsWith('.opf'),
      orElse: () => '',
    );
  }
  if (opfPath.isEmpty) throw StateError('EPUB 里找不到 OPF');

  final opfDir = _dirOf(opfPath);
  final opf = htmlp.parse(utf8.decode(files[opfPath]!, allowMalformed: true));

  // 2) 元数据
  final title = _textOf(_firstByLocal(opf, 'title'));
  final author = _textOf(_firstByLocal(opf, 'creator'));

  // 3) manifest：id → href（相对 OPF 目录）
  final manifest = <String, ({String href, String media, String props})>{};
  // ⚠️ 不能用 `manifest > item`：OPF 是 XML，`<item .../>` 这类自闭合标签被
  // HTML 解析器当成"没闭合的开始标签"，后面所有 item 都会**嵌进第一个 item 里**，
  // 直接子选择器只能拿到一个（真机解析时章节只剩第一章就是这个原因）。
  for (final item in _allByLocal(opf, 'item')) {
    final id = item.attributes['id'] ?? '';
    final href = item.attributes['href'] ?? '';
    if (id.isEmpty || href.isEmpty) continue;
    manifest[id] = (
      href: _resolve(opfDir, href),
      media: item.attributes['media-type'] ?? '',
      props: item.attributes['properties'] ?? '',
    );
  }

  // 4) spine：读顺序就是阅读顺序
  final chapters = <BookChapter>[];
  // 归一化路径 → 章节下标（目录里的 href 靠它换算成"跳到哪一段"）
  final chapterByHref = <String, int>{};
  final spineIds = [
    for (final ref in _allByLocal(opf, 'itemref'))
      ref.attributes['idref'] ?? '',
  ];
  // 没有正确声明 spine 的 EPUB（现实中不少）：退回 manifest 顺序
  final order = spineIds.isNotEmpty ? spineIds : manifest.keys.toList();
  for (final id in order) {
    final item = manifest[id];
    if (item == null) continue;
    final raw = files[item.href];
    if (raw == null) continue;
    if (!item.media.contains('html') &&
        !item.href.endsWith('.xhtml') &&
        !item.href.endsWith('.html') &&
        !item.href.endsWith('.htm')) {
      continue;
    }
    final html = _bookHtmlToFragment(
      utf8.decode(raw, allowMalformed: true),
      baseDir: _dirOf(item.href),
    );
    chapterByHref[item.href] = chapters.length;
    final heading = _chapterTitle(html);
    chapters.add(
      BookChapter(
        title: heading ?? fsTFill('bookChapterN', '第 ${chapters.length + 1} 章', {
          'n': '${chapters.length + 1}',
        }),
        generatedUnit: heading == null ? BookGeneratedUnit.chapter : null,
        html: html,
        href: item.href,
      ),
    );
  }

  // 5) 书自带的目录（EPUB3 nav 优先，其次 NCX），带锚点的会把章节切开
  final rawToc = _epubToc(
    files: files,
    manifest: manifest,
    opf: opf,
    opfDir: opfDir,
  );
  final split = _applyToc(chapters, chapterByHref, rawToc);

  // 6) 资源（插图）：给渲染层按"相对章节的路径"取字节
  final resources = <String, Uint8List>{};
  files.forEach((path, data) {
    if (_looksLikeImage(path)) resources[path] = data;
  });

  return BookContent(
    format: BookFormat.epub,
    title: title,
    author: author,
    chapters: split.chapters,
    resources: resources,
    toc: split.toc,
    anchors: split.anchors,
  );
}

/// 目录里的一个原始条目（还没换算成章节下标）
typedef _RawToc = ({String title, int depth, String path, String fragment});

/// 读 EPUB 的目录，**优先级从"最权威"到"最兜底"**：
///
///   1. EPUB3 `nav.xhtml` 的 `<nav epub:type="toc">`（manifest `properties` 含 `nav`）；
///   2. EPUB2 `toc.ncx`（`<spine toc="…">` 指到的那个，没写就扫包里第一个 `.ncx`）；
///   3. OPF `<guide><reference type="toc" href="…">` 指向的目录**页面**。
///
/// 三档都是"能读出条目才采用"：某一档存在但读出空表（空壳 nav、损坏 NCX）会
/// 继续往下走，不会被一个空壳挡死。三档都没有 / 都读不出时返回空表 —— 阅读器
/// 退回"按章节顺序列"（`file_book_view.dart:1499` 的 `hasOwnToc == false` 分支），
/// **不是**空白面板。
List<_RawToc> _epubToc({
  required Map<String, Uint8List> files,
  required Map<String, ({String href, String media, String props})> manifest,
  required dom.Document opf,
  required String opfDir,
}) {
  // EPUB3：manifest 里 properties 含 `nav` 的那一项
  for (final item in manifest.values) {
    if (!item.props.split(RegExp(r'\s+')).contains('nav')) continue;
    final raw = files[item.href];
    if (raw == null) continue;
    final entries = _parseNavXhtml(
      utf8.decode(raw, allowMalformed: true),
      baseDir: _dirOf(item.href),
    );
    if (entries.isNotEmpty) return entries;
  }

  // EPUB2：`<spine toc="ncx-id">` 指到 NCX；没写就找包里的 .ncx
  final tocId = _firstByLocal(opf, 'spine')?.attributes['toc'] ?? '';
  final candidates = <String>[
    if (tocId.isNotEmpty && manifest[tocId] != null) manifest[tocId]!.href,
    for (final k in files.keys)
      if (k.toLowerCase().endsWith('.ncx')) k,
  ];
  for (final path in candidates) {
    final raw = files[path];
    if (raw == null) continue;
    final entries = _parseNcx(
      utf8.decode(raw, allowMalformed: true),
      baseDir: _dirOf(path),
    );
    if (entries.isNotEmpty) return entries;
  }

  // EPUB2 最后一档：OPF `<guide><reference type="toc" href="…">`。
  // 现实里有一批书既没有 EPUB3 nav、`toc.ncx` 也缺失或为空，只剩 guide 这条线索
  // 指向一个手写的目录页（Humble Bundle / 老 InDesign 导出常见）。
  // `type` 是 OPS 的保留词，理论上小写，这里大小写不敏感地认。
  final guide = _firstByLocal(opf, 'guide');
  if (guide != null) {
    for (final ref in _allByLocalIn(guide, 'reference')) {
      final type = (ref.attributes['type'] ?? '').trim().toLowerCase();
      if (type != 'toc') continue;
      final href = (ref.attributes['href'] ?? '').trim();
      if (href.isEmpty) continue;
      final path = _resolve(opfDir, href);
      final raw = files[path];
      if (raw == null) continue;
      final entries = _parseGuideXhtml(
        utf8.decode(raw, allowMalformed: true),
        baseDir: _dirOf(path),
      );
      if (entries.isNotEmpty) return entries;
    }
  }
  return const [];
}

/// OPF `guide` 的 `<reference type="toc">` 指向的**目录页面**（普通 XHTML）。
///
/// 与 [parseNavXhtml] 的差别：guide 的目录页是 EPUB2 手写页，**没有 `<nav>`**，
/// 也没有 `epub:type`，链接就是裸的 `<a href>`。所以这里不要求任何容器：
///   * 页面里有嵌套 `<ol>/<ul>` → 按列表层级取（和 nav 同构的书，层级不丢）；
///   * 没有列表结构（纯 `<p><a>` 平铺或表格）→ 按**文档顺序**收集所有书内 `<a>`，
///     层级一律 0。
///
/// 外链（`http(s):` / `mailto:` / `data:`）直接丢：它们不是书内目标，留着只会让
/// 目录面板里多出点不动的条目。指向不在 spine 里的页面的条目由 `_applyToc` 丢掉。
List<_RawToc> _parseGuideXhtml(String raw, {required String baseDir}) {
  final doc = htmlp.parse(raw);
  final out = <_RawToc>[];

  void add(dom.Element a, int depth) {
    final href = (a.attributes['href'] ?? '').trim();
    final title = a.text.trim();
    if (title.isEmpty || href.isEmpty) return;
    final scheme = href.toLowerCase();
    if (scheme.startsWith('http:') ||
        scheme.startsWith('https:') ||
        scheme.startsWith('mailto:') ||
        scheme.startsWith('data:') ||
        scheme.startsWith('javascript:')) {
      return;
    }
    final resolved = _resolveTarget(baseDir, href);
    out.add((
      title: title,
      depth: depth,
      path: resolved.path,
      fragment: resolved.fragment,
    ));
  }

  void walkList(dom.Element list, int depth) {
    for (final li in _childrenByLocal(list, 'li')) {
      final a =
          _childrenByLocal(li, 'a').firstOrNull ??
          _allByLocalIn(li, 'a').firstOrNull;
      if (a != null) add(a, depth);
      for (final tag in const ['ul', 'ol']) {
        for (final sub in _childrenByLocal(li, tag)) {
          walkList(sub, depth + 1);
        }
      }
    }
  }

  // 只从"最外层列表"开始走；嵌套列表由 walkList 递归，避免重复收。
  final lists = <dom.Element>[
    ...doc.querySelectorAll('ul'),
    ...doc.querySelectorAll('ol'),
  ];
  for (final list in lists) {
    var nested = false;
    for (var p = list.parent; p != null; p = p.parent) {
      final n = _local(p);
      if (n == 'ul' || n == 'ol') {
        nested = true;
        break;
      }
    }
    if (!nested) walkList(list, 0);
  }

  // 没有列表结构的手写目录页：平铺所有书内链接。
  if (out.isEmpty) {
    for (final a in doc.querySelectorAll('a')) {
      add(a, 0);
    }
  }
  return out;
}

/// EPUB3 `nav.xhtml`：`<nav epub:type="toc">` → 嵌套 `<ol><li><a href>`
List<_RawToc> _parseNavXhtml(String raw, {required String baseDir}) {
  final doc = htmlp.parse(raw);
  // `<nav epub:type="toc">`；有的书写成 `type="toc"`，两种都认
  dom.Element? nav;
  for (final e in _allByLocal(doc, 'nav')) {
    final t = e.attributes['epub:type'] ?? e.attributes['type'] ?? '';
    if (t.split(RegExp(r'\s+')).contains('toc')) {
      nav = e;
      break;
    }
  }
  nav ??= _firstByLocal(doc, 'nav');
  if (nav == null) return const [];

  final out = <_RawToc>[];
  void walkList(dom.Element? ol, int depth) {
    if (ol == null) return;
    for (final li in _childrenByLocal(ol, 'li')) {
      final a =
          _childrenByLocal(li, 'a').firstOrNull ??
          _allByLocalIn(li, 'a').firstOrNull;
      final href = a?.attributes['href'] ?? '';
      final title = (a?.text ?? '').trim();
      if (title.isNotEmpty && href.isNotEmpty) {
        final resolved = _resolveTarget(baseDir, href);
        out.add((
          title: title,
          depth: depth,
          path: resolved.path,
          fragment: resolved.fragment,
        ));
      }
      walkList(_childrenByLocal(li, 'ol').firstOrNull, depth + 1);
    }
  }

  walkList(_allByLocalIn(nav, 'ol').firstOrNull, 0);
  return out;
}

/// EPUB2 `toc.ncx`：`navMap/navPoint`（可嵌套），`navLabel/text` + `content@src`
List<_RawToc> _parseNcx(String raw, {required String baseDir}) {
  final doc = htmlp.parse(raw);
  final points = _allByLocal(doc, 'navpoint');
  if (points.isEmpty) return const [];
  final out = <_RawToc>[];
  for (final p in points) {
    // 层级 = 祖先里还有几个 navPoint
    var depth = 0;
    for (var a = p.parent; a != null; a = a.parent) {
      if (_local(a) == 'navpoint') depth++;
    }
    final title = _plainText(_allByLocalIn(p, 'text').firstOrNull);
    final src =
        _allByLocalIn(p, 'content').firstOrNull?.attributes['src'] ?? '';
    if (title.isEmpty || src.isEmpty) continue;
    final resolved = _resolveTarget(baseDir, src);
    out.add((
      title: title,
      depth: depth,
      path: resolved.path,
      fragment: resolved.fragment,
    ));
  }
  return out;
}

/// `href` → （归一化路径，片段）——`ch1.xhtml#sec2` 的 `#sec2` 也算进来
({String path, String fragment}) _resolveTarget(String baseDir, String href) {
  final hash = href.indexOf('#');
  final fragment = hash < 0 ? '' : href.substring(hash + 1).trim();
  return (path: _resolve(baseDir, href), fragment: fragment);
}

/// 把目录与**书内锚点**挂到章节上：有锚点的章节会在锚点处切开。
///
/// 返回新的章节表 + 目录（目录顺序保持原书顺序，`chapterIndex` 指向切开后的段）
/// + 锚点表（`路径#锚点` → 段落下标，E2 的脚注/超链接跳转用它）。
///
/// 切开的锚点来源有两类，**用同一套机制**：
///   * 原书目录条目（`ch1.xhtml#sec2`）—— E1 就有的"跳到小节"；
///   * 正文里的 `<a href="#fn1">` / `<a href="ch2.xhtml#fn1">` —— E2 的脚注/超链接。
/// 后者即使这本书**没有目录**也会切；指向别章锚点的链接会让**被指向的那一章**
/// 在锚点处切开（所以 `#fn1` 落在章末时，点一下真的滚到注释那一段）。
({List<BookChapter> chapters, List<BookTocEntry> toc, Map<String, int> anchors})
_applyToc(
  List<BookChapter> chapters,
  Map<String, int> chapterByHref,
  List<_RawToc> rawToc,
) {
  // 目录条目 → 原章节下标（目标不在 spine 里的条目直接丢：封面页、外部链接等）
  final chapterOf = <int, int>{}; // 条目下标 → 原章节下标
  for (var i = 0; i < rawToc.length; i++) {
    final ci = chapterByHref[rawToc[i].path];
    if (ci != null) chapterOf[i] = ci;
  }

  // 每个原章节拿到挂在它身上的目录条目（保持原书顺序）
  final entriesOf = <int, List<int>>{};
  for (final e in chapterOf.entries) {
    entriesOf.putIfAbsent(e.value, () => []).add(e.key);
  }

  // 每个路径要切的锚点：目录条目 + 正文里的书内链接。跨文件链接的锚点也要
  // 记到**目标文件**头上，否则被指向的那一章不会切开。
  final fragsByPath = <String, List<String>>{};
  void addFrag(String path, String fragment) {
    final list = fragsByPath.putIfAbsent(path, () => <String>[]);
    if (!list.contains(fragment)) list.add(fragment);
  }

  for (final e in chapterOf.entries) {
    addFrag(rawToc[e.key].path, rawToc[e.key].fragment);
  }
  for (final ch in chapters) {
    for (final target in bookInternalLinkTargets(ch.href, ch.html)) {
      addFrag(target.path, target.fragment);
    }
  }

  final anchors = <String, int>{};
  final newIndexOf = <int, int>{};
  final newChapters = <BookChapter>[];
  for (var ci = 0; ci < chapters.length; ci++) {
    final ch = chapters[ci];
    final frags = fragsByPath[ch.href] ?? const <String>[];
    final entries = entriesOf[ci] ?? const <int>[];
    if (frags.isEmpty) {
      newChapters.add(ch);
      continue;
    }
    final base = newChapters.length;
    final sliced = _sliceChapterHtml(ch.html, frags);
    for (final piece in sliced.pieces) {
      newChapters.add(
        BookChapter(
          title: ch.title,
          generatedUnit: ch.generatedUnit,
          html: piece,
          href: ch.href,
        ),
      );
    }
    // 锚点表只收"正文里真的有落点"的锚点：找不到的链接宁可报"不在书里"，
    // 也不要静默跳到章首（用户会以为跳错了）。
    final ids = bookAnchorIds(ch.html).toSet();
    for (final f in frags) {
      if (!ids.contains(f)) continue;
      final index = base + (sliced.indexOf[f] ?? 0);
      anchors['${ch.href}#$f'] = index.clamp(0, newChapters.length - 1);
    }
    for (final e in entries) {
      final f = rawToc[e].fragment;
      newIndexOf[e] = base + (sliced.indexOf[f] ?? 0);
    }
  }

  // 标题：一个章节只挂一个目录条目时，目录标题比正文里猜的 h1 更可信
  for (final e in entriesOf.entries) {
    if (e.value.length != 1) continue;
    final raw = rawToc[e.value.single];
    final target = newIndexOf[e.value.single];
    if (target != null && raw.title.trim().isNotEmpty) {
      final ch = newChapters[target];
      newChapters[target] = BookChapter(
        title: raw.title.trim(),
        html: ch.html,
        href: ch.href,
      );
    }
  }

  final toc = <BookTocEntry>[
    for (var i = 0; i < rawToc.length; i++)
      if (newIndexOf[i] != null)
        BookTocEntry(
          title: rawToc[i].title,
          depth: rawToc[i].depth,
          chapterIndex: newIndexOf[i]!,
        ),
  ];
  return (chapters: newChapters, toc: toc, anchors: anchors);
}

/// 按锚点把一章的 HTML 切成若干段。
///
/// 返回**去重后的段**（`pieces`）与"每个锚点落在第几段"（`indexOf`）——
/// 目录条目、脚注链接都靠 `indexOf` 换算成段落下标，不再假设"一个锚点一段"。
/// 锚点在文件里找不到、或落在段首时，都并到第一段，**不会丢内容**。
({List<String> pieces, Map<String, int> indexOf}) _sliceChapterHtml(
  String html,
  List<String> fragments,
) {
  final root = htmlp.parseFragment(html);
  final tops = root.nodes.toList();
  final indexOf = <String, int>{};
  if (tops.isEmpty) {
    for (final f in fragments) {
      indexOf[f] = 0;
    }
    return (pieces: [html], indexOf: indexOf);
  }

  // 锚点 → 顶层节点下标
  final at = <int>[];
  var splitting = false;
  for (final f in fragments) {
    var index = 0;
    if (f.isNotEmpty) {
      final el =
          root.querySelector('[id="$f"]') ?? root.querySelector('[name="$f"]');
      if (el != null) {
        final i = _topIndex(tops, el);
        if (i > 0) index = i;
      }
    }
    at.add(index);
    if (index > 0) splitting = true;
  }
  // 没有"切在中间"的锚点 → 整章原样返回
  if (!splitting) {
    for (final f in fragments) {
      indexOf[f] = 0;
    }
    return (pieces: [html], indexOf: indexOf);
  }

  // 切点（升序去重，0 永远是第一段）
  final bounds = <int>[0];
  for (final i in at) {
    if (i > 0 && !bounds.contains(i)) bounds.add(i);
  }
  bounds.sort();

  final pieces = <String>[];
  for (var b = 0; b < bounds.length; b++) {
    final start = bounds[b];
    final end = b + 1 < bounds.length ? bounds[b + 1] : tops.length;
    final buf = StringBuffer();
    for (var i = start; i < end; i++) {
      buf.write(_outerOf(tops[i]));
    }
    pieces.add(buf.toString());
  }
  for (var k = 0; k < fragments.length; k++) {
    indexOf[fragments[k]] = bounds.indexOf(at[k]);
  }
  return (pieces: pieces, indexOf: indexOf);
}

// ------------------------------------------------------------------ FB2

BookContent _parseFb2(List<int> bytes) {
  final raw = utf8.decode(bytes, allowMalformed: true);
  final doc = htmlp.parse(raw);
  final title = _textOf(_firstByLocal(doc, 'book-title'));
  final author = [
    for (final a in _allByLocal(doc, 'author'))
      [
        _textOf(_firstByLocal(_asDoc(a), 'first-name')),
        _textOf(_firstByLocal(_asDoc(a), 'middle-name')),
        _textOf(_firstByLocal(_asDoc(a), 'last-name')),
      ].where((s) => s.isNotEmpty).join(' '),
  ].where((s) => s.isNotEmpty).join(fsT('bookListSeparator', '、'));

  final chapters = <BookChapter>[];
  final body = _firstByLocal(doc, 'body');
  // FB2 的正文是一串 <section>；没有 section 就整段当一章
  // 取"最外层"的 section：FB2 允许 section 嵌套，而 `<empty-line/>` 这类
  // 自闭合标签在 HTML 解析器里会把后面的兄弟**吞成子节点** —— 所以不能只看
  // body 的直接子节点（真机踩过：第二节整个丢了）。
  final all = _allByLocal(doc, 'section');
  final toc = <BookTocEntry>[];
  if (all.isEmpty) {
    final bookTitle = _plainText(_firstByLocal(doc, 'book-title'));
    chapters.add(
      BookChapter(
        title: bookTitle.isEmpty ? fsT('bookBodyText', '正文') : bookTitle,
        generatedUnit: bookTitle.isEmpty ? BookGeneratedUnit.body : null,
        html: _fb2Inline(body ?? doc.documentElement),
      ),
    );
  } else {
    // FB2 的 `section` 可以**任意嵌套**（章 / 节 / 小节）。以前只取最外层，
    // 结果嵌套 section 的 `<title>` 被整段丢掉（标题凭空消失）。
    // 现在按文档顺序摊平：每个 section 一段，层级进目录，子 section 是独立一段。
    for (final s in all) {
      var depth = 0;
      for (var a = s.parent; a != null; a = a.parent) {
        if (_local(a) == 'section') depth++;
      }
      final own = _plainText(_fb2OwnTitle(s));
      final fallback = own.isEmpty;
      final title = fallback
          ? fsTFill('bookSectionN', '第 ${chapters.length + 1} 节', {
              'n': '${chapters.length + 1}',
            })
          : own;
      final html = _fb2Inline(s, skipSections: true);
      final index = chapters.length;
      chapters.add(
        BookChapter(
          title: title,
          generatedUnit: fallback ? BookGeneratedUnit.section : null,
          html: html,
        ),
      );
      toc.add(BookTocEntry(title: title, depth: depth, chapterIndex: index));
    }
  }
  // 插图：FB2 的 <binary id="..." content-type="image/jpeg">BASE64</binary>
  final resources = <String, Uint8List>{};
  for (final b in _allByLocal(doc, 'binary')) {
    final id = b.attributes['id'] ?? '';
    final data = b.text.replaceAll(RegExp(r'\s'), '');
    if (id.isEmpty || data.isEmpty) continue;
    try {
      resources[id] = base64.decode(data);
    } catch (_) {
      // 坏图跳过，不影响正文
    }
  }
  // FB2 没有独立文件路径：所有章节 href 为空，锚点键就是 `#id`。
  // FB2 的脚注通常写在独立的 `<body name="notes">`／末尾 section 里，点击靠
  // `#id` 定位到**包含它的那一段**（EPUB 才能精确切到段中，见 `_applyToc`）。
  final anchors = <String, int>{};
  for (var i = 0; i < chapters.length; i++) {
    for (final id in bookAnchorIds(chapters[i].html)) {
      anchors.putIfAbsent('#$id', () => i);
    }
  }
  return BookContent(
    format: BookFormat.fb2,
    title: title,
    author: author,
    chapters: chapters,
    resources: resources,
    toc: toc,
    anchors: anchors,
  );
}

/// FB2 标签 → 我们能渲染的 HTML 子集
///
/// [skipSections] = true 时丢掉嵌套的 `<section>`：它们已经是**独立的段**了
/// （以前在这里被内联进来，标题会丢）。
String _fb2Inline(dom.Element? root, {bool skipSections = false}) {
  if (root == null) return '';
  final out = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      out.write(_escape(node.text));
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName;
    switch (tag) {
      case 'section':
        // 子 section 是独立的一段，正文里不再重复
        if (skipSections) return;
        out.write('<div${_domIdAttr(node)}>');
        node.nodes.forEach(walk);
        out.write('</div>');
        return;
      case 'title':
        // title 单独由章节标题呈现，这里只走正文
        return;
      case 'p':
        out.write('<p${_domIdAttr(node)}>');
        node.nodes.forEach(walk);
        out.write('</p>');
        return;
      case 'subtitle':
        out.write('<h3>');
        node.nodes.forEach(walk);
        out.write('</h3>');
        return;
      case 'emphasis':
        out.write('<em>');
        node.nodes.forEach(walk);
        out.write('</em>');
        return;
      case 'strong':
        out.write('<strong>');
        node.nodes.forEach(walk);
        out.write('</strong>');
        return;
      case 'strikethrough':
        out.write('<s>');
        node.nodes.forEach(walk);
        out.write('</s>');
        return;
      case 'code':
        out.write('<code>');
        node.nodes.forEach(walk);
        out.write('</code>');
        return;
      case 'sup':
        out.write('<sup>');
        node.nodes.forEach(walk);
        out.write('</sup>');
        return;
      case 'sub':
        out.write('<sub>');
        node.nodes.forEach(walk);
        out.write('</sub>');
        return;
      case 'empty-line':
        out.write('<p><br></p>');
        // 自闭合的 `<empty-line/>` 在 HTML 解析器里会把后面的兄弟吞成子节点，
        // 所以这里**继续往下走**，否则紧跟其后的插图会整张丢掉（真机踩过）
        node.nodes.forEach(walk);
        return;
      // FB2 的 `<image l:href="#id"/>`；HTML 解析器可能把 `image` 认成 `img`
      case 'image':
      case 'img':
        final href =
            node.attributes['l:href'] ??
            node.attributes['xlink:href'] ??
            node.attributes['href'] ??
            node.attributes['src'] ??
            '';
        out.write('<p><img src="${_escape(href)}" alt=""/></p>');
        return;
      // FB2 的脚注/超链接：`<a l:href="#fn1">1</a>`
      //
      // 以前这里把 `<a>` 包成 `<p>` 并**丢掉 href**（链接只当文字），
      // E2 起保留 href 让阅读器能真的跳过去（外链交系统浏览器）。
      case 'a':
        final href =
            node.attributes['l:href'] ??
            node.attributes['xlink:href'] ??
            node.attributes['href'] ??
            '';
        if (href.isEmpty) {
          node.nodes.forEach(walk);
          return;
        }
        out.write('<a href="${_escape(href)}">');
        node.nodes.forEach(walk);
        out.write('</a>');
        return;
      case 'cite':
      case 'epigraph':
      case 'annotation':
        out.write('<blockquote>');
        node.nodes.forEach(walk);
        out.write('</blockquote>');
        return;
      case 'poem':
      case 'stanza':
      case 'v':
      case 'date':
      case 'style':
        node.nodes.forEach(walk);
        return;
      default:
        node.nodes.forEach(walk);
    }
  }

  root.nodes.forEach(walk);
  return out.toString();
}

/// 取 section **自己**的 `<title>`（直接子节点里的那个，不是孙子节的）
dom.Element? _fb2OwnTitle(dom.Element section) {
  for (final child in section.children) {
    if (_local(child) == 'title') return child;
  }
  // 现实里的 FB2 常把 `<title>` 写在 `<epigraph>` 之后等位置，再退一步按后代找
  return _allByLocalIn(section, 'title').firstOrNull;
}

// ------------------------------------------------------------------ CBZ

BookContent _parseCbz(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  final entries = <({String name, Uint8List data})>[];
  for (final f in archive) {
    if (!f.isFile) continue;
    final name = _normalize(f.name);
    if (name.startsWith('__MACOSX/')) continue;
    if (!_looksLikeImage(name)) continue;
    entries.add((name: name, data: Uint8List.fromList(f.content as List<int>)));
  }
  // 漫画页靠文件名排序（`001.jpg`、`p10.png` 这种），自然序排才对
  entries.sort((a, b) => _naturalCompare(a.name, b.name));
  return BookContent(
    format: BookFormat.cbz,
    title: '',
    pages: [for (final e in entries) e.data],
  );
}

// ------------------------------------------------------------------ CBR

/// `.cbr`：RAR 包里的图片 → 漫画页。
///
/// 和 CBZ **完全相同**的产物（`BookContent.pages`，按自然序），所以阅读页、
/// 进度记忆、封面提取全部复用。解压在 `rar_archive.dart`（自研纯 Dart）。
///
/// 能力边界（加密 / 多卷 / 未实现的压缩变体）在这里翻译成
/// [BookUnsupportedException]，界面文案复用既有的 `bookUnsupportedFormat`。
BookContent _parseCbr(List<int> bytes) {
  final RarArchive archive;
  try {
    archive = RarArchive.open(bytes);
  } on RarUnsupportedException catch (e) {
    throw BookUnsupportedException(e.message, reason: e.reason);
  }
  if (archive.entries.any((e) => e.encrypted)) {
    throw BookUnsupportedException(
      '带密码（加密）的 CBR，本阅读器不解密',
      reason: BookUnsupportedReason.encrypted,
    );
  }
  final picked = <({String archiveName, String name})>[];
  for (final e in archive.entries) {
    if (e.isDir) continue;
    final name = _normalize(e.name);
    if (name.startsWith('__MACOSX/')) continue;
    if (!_looksLikeImage(name)) continue;
    picked.add((archiveName: e.name, name: name));
  }
  // 漫画页靠文件名排序（`001.jpg`、`p10.png` 这种），自然序排才对
  picked.sort((a, b) => _naturalCompare(a.name, b.name));
  if (picked.isEmpty) {
    throw const FormatException('CBR（RAR）里没有图片');
  }
  final Map<String, Uint8List> data;
  try {
    data = archive.extract(only: {for (final p in picked) p.archiveName});
  } on RarUnsupportedException catch (e) {
    throw BookUnsupportedException(e.message, reason: e.reason);
  }
  final pages = <Uint8List>[
    for (final p in picked)
      if (data[p.archiveName] != null) data[p.archiveName]!,
  ];
  if (pages.isEmpty) {
    throw const FormatException('CBR（RAR）里没有可解码的图片');
  }
  return BookContent(format: BookFormat.cbr, pages: pages);
}

/// 走"图片页"路线的漫画包格式（CBZ / CBR / CBT）。
///
/// 阅读页用同一套 `_ComicView`：翻页、缩放、按"第几页/共几页"记进度。
bool isComicBook(BookFormat format) =>
    format == BookFormat.cbz ||
    format == BookFormat.cbr ||
    format == BookFormat.cbt;

/// 阅读页是否走"图片翻页"视图。
///
/// 漫画包天然是图片；**DJVU 要看解析结果**——出得了位图页（扫描件）就走翻页，
/// 只有隐藏文本层就走富文本阅读器。用内容判断而不是单纯看格式，正是为此。
bool usesPageView(BookContent book) =>
    isComicBook(book.format) ||
    (book.format == BookFormat.djvu && book.pages.isNotEmpty);

// ------------------------------------------------------------------ 工具

/// 把任意元素当成"文档根"来查（查子元素用）
dom.Document _asDoc(dom.Element e) => htmlp.parse(e.outerHtml);

String _normalize(String path) {
  var p = path.replaceAll('\\', '/');
  while (p.startsWith('./')) {
    p = p.substring(2);
  }
  while (p.startsWith('/')) {
    p = p.substring(1);
  }
  // zip 里目录以 / 结尾
  return p;
}

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i + 1);
}

/// 把 `href` 按 base 目录解析成"归一化路径"（处理 `../`）
String _resolve(String baseDir, String href) {
  final cleaned = href.split('#').first.split('?').first;
  final joined = cleaned.startsWith('/')
      ? cleaned.substring(1)
      : '$baseDir$cleaned';
  final parts = <String>[];
  for (final seg in joined.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(seg);
  }
  return parts.join('/');
}

String _textOf(dom.Element? e) => e == null ? '' : e.text.trim();

/// 取纯文本（再去一次标签）
///
/// ⚠️ `package:html` 把 `<title>` 当成"可转义原始文本"（HTML 的 title 语义），
/// 里面的 `<p>` 会被**当字面量**输出 —— FB2 的 `<title><p>第一节</p></title>`
/// 读出来就是字符串 `<p>第一节</p>`（真机解析时章节名带着标签就是这个原因）。
String _plainText(dom.Element? e) =>
    _textOf(e).replaceAll(RegExp(r'<[^>]*>'), '').trim();

/// 标签的"本地名"（去掉 `dc:` / `l:` 这类命名空间前缀）
///
/// ⚠️ OPF / FB2 都是 XML：`package:html` 会把 `<dc:title>` 的标签名**连前缀**
/// 一起保留，`querySelector('title')` 是**匹配不到**的（真机解析时书名一直是空的，
/// 就是这里）。所以按本地名自己找。
String _local(dom.Element e) {
  final n = e.localName ?? e.toString();
  final i = n.indexOf(':');
  return i < 0 ? n : n.substring(i + 1);
}

dom.Element? _firstByLocal(dom.Document doc, String name) {
  for (final e in doc.querySelectorAll('*')) {
    if (_local(e) == name) return e;
  }
  return null;
}

List<dom.Element> _allByLocal(dom.Document doc, String name) => [
  for (final e in doc.querySelectorAll('*'))
    if (_local(e) == name) e,
];

/// 在某个元素内部按本地名找**所有**后代（`_allByLocal` 的元素版）
List<dom.Element> _allByLocalIn(dom.Element root, String name) => [
  for (final e in root.querySelectorAll('*'))
    if (_local(e) == name) e,
];

/// 元素落在第几个顶层节点里（`parseFragment` 会包一层隐形的 html/body，
/// 所以不能用 `node.parent == root` 判断"是不是顶层"，只能按包含关系找）
int _topIndex(List<dom.Node> tops, dom.Element el) {
  for (var i = 0; i < tops.length; i++) {
    final t = tops[i];
    if (identical(t, el)) return i;
    if (t is! dom.Element) continue;
    for (var a = el.parent; a != null; a = a.parent) {
      if (identical(a, t)) return i;
    }
  }
  return -1;
}

/// 节点 → HTML 串：元素给 `outerHtml`，纯文本节点原样输出
String _outerOf(dom.Node n) => n is dom.Element ? n.outerHtml : (n.text ?? '');

/// 只要**直接子元素**（按本地名）——目录树的"下一层"这种语义必须只认直接子节点，
/// 用 `querySelectorAll` 会把孙子也一并捞进来。
List<dom.Element> _childrenByLocal(dom.Element parent, String name) => [
  for (final n in parent.children)
    if (_local(n) == name) n,
];

bool _looksLikeImage(String path) {
  final p = path.toLowerCase();
  return p.endsWith('.jpg') ||
      p.endsWith('.jpeg') ||
      p.endsWith('.png') ||
      p.endsWith('.gif') ||
      p.endsWith('.webp') ||
      p.endsWith('.bmp');
}

/// 从一章 HTML 里取标题（第一个 h1-h6；没有就用 `<title>`）
String? _chapterTitle(String html) {
  final doc = htmlp.parseFragment(html);
  for (final tag in const ['h1', 'h2', 'h3', 'h4']) {
    final e = doc.querySelector(tag);
    final t = e?.text.trim() ?? '';
    if (t.isNotEmpty) return t;
  }
  return null;
}

/// 给 CHM 解析层复用：整篇 HTML → 阅读器片段（见 [_bookHtmlToFragment]）。
///
/// 之所以开这个口子：CHM 解出来的正文就是 HTML，和 EPUB 用的是**同一条**渲染
/// 管线；与其在 CHM 里再写一份"剥 head / 改 img src"的逻辑，不如直接复用。
String bookHtmlToFragment(String raw, {required String baseDir}) =>
    _bookHtmlToFragment(raw, baseDir: baseDir);

/// 给 CHM 解析层复用：按锚点把一章切开（见 [_sliceChapterHtml]）。
({List<String> pieces, Map<String, int> indexOf}) bookSliceChapterHtml(
  String html,
  List<String> fragments,
) => _sliceChapterHtml(html, fragments);

/// EPUB/FB2 的整篇文档 → 我们渲染用的 HTML 片段
///
/// 只留 body，剥掉 `<style>/<script>`（渲染层不支持 CSS，留着也没用），
/// 并且把图片的相对路径改写成"以书根为基准"的归一化路径 —— 渲染层拿它去
/// [BookContent.resources] 里找字节。
String _bookHtmlToFragment(String raw, {required String baseDir}) {
  final doc = htmlp.parse(raw);
  for (final junk in doc.querySelectorAll('style, script, head, title')) {
    junk.remove();
  }
  final body = doc.body;
  if (body == null) return '';
  for (final img in body.querySelectorAll('img')) {
    final src = img.attributes['src'] ?? '';
    if (src.isEmpty || src.startsWith('data:')) continue;
    img.attributes['src'] = _resolve(baseDir, src);
  }
  return body.innerHtml;
}

String _escape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// 元素自带 `id` 时输出 ` id="…"`（FB2 的锚点要靠它落地；EPUB 原样保留）。
String _domIdAttr(dom.Element e) {
  final id = (e.attributes['id'] ?? '').trim();
  return id.isEmpty ? '' : ' id="${_escape(id)}"';
}

/// 文件名自然序（`p2` < `p10`）—— 漫画页顺序错了整个阅读体验就废了
int _naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+|\D+)');
  final as = re.allMatches(a).map((m) => m.group(0)!).toList();
  final bs = re.allMatches(b).map((m) => m.group(0)!).toList();
  for (var i = 0; i < as.length && i < bs.length; i++) {
    final x = as[i], y = bs[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    if (nx != null && ny != null) {
      final c = nx.compareTo(ny);
      if (c != 0) return c;
    } else {
      final c = x.toLowerCase().compareTo(y.toLowerCase());
      if (c != 0) return c;
    }
  }
  return as.length.compareTo(bs.length);
}
