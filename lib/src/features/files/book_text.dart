// TXT / Markdown / HTML / RTF / TCR → BookContent —— **纯 Dart**，
// 不 import flutter / l10n（`dart run tool/*.dart` 必须能编译）。
//
// 这一层的目标只有一个：**任何"能看懂的文字"都变成和 EPUB/FB2 一样的
// `BookContent`（chapters + toc + resources）**，于是阅读页、目录、书内搜索、
// 进度、书签、划线、TTS 全部免费复用，渲染层一行都不用改。
//
// 各格式的要点与边界：
//
//   * **TXT**：先做编码探测（`book_encoding.dart`），再按"章节标记行"分章，
//     没有标记就单章；超大文件按段落边界切块（Quill 一次渲染几 MB 会卡）。
//   * **Markdown**：走项目已有的 `package:markdown`（GitHub 风味：标题/列表/
//     引用/代码块/表格），转成 HTML 后和 HTML 走同一条管线。**没有新增依赖**。
//   * **HTML**：剥掉 head/style/script，抽出可见正文；`h1`/`h2`/`h3` 当章节
//     边界，并把容器（div/section/article…）摊平，否则整篇被一个外层 `<div>`
//     包住时只能得到"一章"。图片：`data:` 内联图直接解码成资源；相对路径若
//     调用方给了**兄弟文件**（`siblings`）就一并取进来，取不到就保留原 `src`。
//     外链保留 `<a href>`，交给阅读页现成的"外链交系统浏览器"。
//   * **RTF**：手写控制字解析（`\par`/`\pard`/`\b`/`\i`/`\uN`/`\'hh`/`\ansicpg`），
//     字体表/颜色表/样式表等"目的地"整组跳过；产出段落 + 粗斜体。
//   * **TCR**：老式紧凑文本，先解压（`0x00-0x7F` 字面量、高位置 1 的
//     "长度 + 字符"扩展），再走 TXT 那条路。
//
// **明确不做**：单文件 HTML/Markdown 的同目录图片，若调用方不提供兄弟文件，
// 解析层拿不到（它只收到一个文件的字节）—— 此时保留原样、不猜、不造半成品。
import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as htmlp;
import 'package:markdown/markdown.dart' as md;

import 'book_encoding.dart';
import 'file_book.dart';
import 'files_i18n.dart';

/// 单章超过这个体积且没有章节标记时才按大小切块
const int kTextSplitThreshold = 256 * 1024;

/// 按大小切块时每块的目标体积
const int kTextSplitTarget = 64 * 1024;

/// 章节标记行的最大长度（超过就不可能是一行标题，而是普通正文）
const int _kHeadingMaxChars = 60;

// ------------------------------------------------------------------ TXT / TCR

/// `.txt`：编码探测 → 分章/分块
BookContent parseTxtBook(
  List<int> bytes, {
  required BookFormat format,
  String title = '',
}) {
  final decoded = detectAndDecodeBookText(bytes);
  return bookFromPlainText(
    decoded.text,
    format: format,
    title: title,
    author: '（${decoded.encoding.label}）',
  );
}

/// TCR：先解压，再当 TXT 处理
BookContent parseTcrBook(
  List<int> bytes, {
  required BookFormat format,
  String title = '',
}) {
  final raw = decodeTcr(bytes);
  final decoded = detectAndDecodeBookText(raw);
  return bookFromPlainText(decoded.text, format: format, title: title);
}

/// TCR 解压。
///
/// 老式 Psion/EPOC 阅读器的紧凑文本：`0x00-0x7F` 是字面量字节；高位置 1 的
/// 字节是"长度 + 字符"扩展 —— 低 7 位是**重复次数**，紧跟的下一个字节是
/// **被重复的字符**。文件头可能有 2 字节 `!!` 标记，看到就跳过。
///
/// 不认识的收尾（高字节后没有字符）直接停，**不补 0、不猜**。
Uint8List decodeTcr(List<int> bytes) {
  var data = bytes;
  if (data.length >= 2 && data[0] == 0x21 && data[1] == 0x21) {
    data = data.sublist(2);
  }
  final out = <int>[];
  var i = 0;
  while (i < data.length) {
    final b = data[i++];
    if (b & 0x80 == 0) {
      out.add(b);
      continue;
    }
    if (i >= data.length) break; // 截断的尾巴：停，不补字节
    final count = b & 0x7F;
    final ch = data[i++];
    final n = count == 0 ? 1 : count; // 防御：count=0 当一次
    for (var k = 0; k < n; k++) {
      out.add(ch);
    }
  }
  return Uint8List.fromList(out);
}

// ------------------------------------------------------------------ Markdown

/// `.md`：`package:markdown` → HTML → 和 HTML 同一条管线
BookContent parseMarkdownBook(
  List<int> bytes, {
  required BookFormat format,
  String title = '',
  Map<String, Uint8List>? siblings,
}) {
  final text = decodeBookText(bytes);
  final html = md.markdownToHtml(
    text,
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );
  return _parseHtmlContent(
    html,
    format: format,
    fallbackTitle: title.isEmpty ? _firstMarkdownHeading(text) : title,
    siblings: siblings,
  );
}

String _firstMarkdownHeading(String text) {
  for (final line in const LineSplitter().convert(text)) {
    final t = line.trim();
    if (t.startsWith('#')) {
      final h = t.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      if (h.isNotEmpty) return h;
    }
  }
  return '';
}

// ------------------------------------------------------------------ HTML

/// `.html` / `.htm` / `.xhtml`
BookContent parseHtmlBook(
  List<int> bytes, {
  required BookFormat format,
  String title = '',
  Map<String, Uint8List>? siblings,
}) {
  final raw = decodeBookText(bytes);
  return _parseHtmlContent(
    raw,
    format: format,
    fallbackTitle: title,
    siblings: siblings,
  );
}

/// HTML / Markdown 共用：可见正文 + 标题层级 + 图片资源
BookContent _parseHtmlContent(
  String raw, {
  required BookFormat format,
  required String fallbackTitle,
  required Map<String, Uint8List>? siblings,
}) {
  final doc = htmlp.parse(raw);
  final docTitle = (doc.querySelector('title')?.text ?? '').trim();
  final resources = <String, Uint8List>{};
  for (final junk in doc.querySelectorAll('style, script, head, title, link')) {
    junk.remove();
  }
  final collector = _HtmlCollector(resources, siblings);
  final body = doc.body ?? doc.documentElement;
  if (body != null) collector.walk(body);
  collector.finish();

  var resolvedTitle = docTitle.isNotEmpty ? docTitle : fallbackTitle;
  if (resolvedTitle.isEmpty) {
    for (final p in collector.paras) {
      if (p.title != null && p.title!.isNotEmpty) {
        resolvedTitle = p.title!;
        break;
      }
    }
  }

  final split = bookChapterize(collector.paras, format: format);
  return BookContent(
    format: format,
    title: resolvedTitle,
    chapters: split.chapters,
    toc: split.toc,
    resources: resources,
  );
}

/// 容器标签：会往下递归（摊平），否则整篇 HTML 被一个外层 `<div>`/`<table>`
/// 包住时只能得到"一章"。
const Set<String> _kHtmlContainers = {
  'html', 'body', 'div', 'section', 'article', 'main', 'header', 'footer', //
  'aside', 'nav', 'center', 'font', 'span', 'figure', 'figcaption',
  'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th',
};

class _HtmlCollector {
  _HtmlCollector(this.resources, this.siblings);

  final Map<String, Uint8List> resources;
  final Map<String, Uint8List>? siblings;
  final List<BookBlock> paras = [];
  final StringBuffer _inline = StringBuffer();

  void addInline(String html) => _inline.write(html);

  void flushInline() {
    final s = _inline.toString().trim();
    _inline.clear();
    if (s.isEmpty) return;
    paras.add(BookBlock('<p>$s</p>'));
  }

  void addBlock(String html, {String? title, bool heading = false}) {
    flushInline();
    paras.add(BookBlock(html, title: title, heading: heading));
  }

  void finish() => flushInline();

  void walk(dom.Node node) {
    if (node is dom.Text) {
      final text = node.text.trim();
      if (text.isEmpty) return;
      addInline(_escape(text));
      return;
    }
    if (node is! dom.Element) return;
    final tag = (node.localName ?? '').toLowerCase();

    if (tag == 'br') {
      addInline('<br>');
      return;
    }
    if (tag == 'h1' || tag == 'h2' || tag == 'h3') {
      final text = node.text.trim();
      if (text.isEmpty) return;
      addBlock('<h2>${_escape(text)}</h2>', title: text, heading: true);
      return;
    }
    if (tag == 'img') {
      final src = node.attributes['src'] ?? '';
      final name = _materializeImage(src, resources, siblings);
      if (name != null) {
        addBlock('<p><img src="$name" alt=""/></p>');
      } else if (src.isNotEmpty && !src.startsWith('data:')) {
        // 取不到字节：保留原 src，渲染层会忽略它（**不猜、不造**）
        addBlock('<p><img src="${_escape(src)}" alt=""/></p>');
      }
      return;
    }
    if (_kHtmlContainers.contains(tag)) {
      if (tag == 'span' || tag == 'font') {
        final text = node.text.trim();
        if (text.isEmpty) return;
        addInline(_escape(text));
        return;
      }
      for (final child in node.nodes) {
        walk(child);
      }
      return;
    }
    // p / ul / ol / blockquote / pre / hr / h4-h6 …：整段保留（含内联标签）
    addBlock(_rewriteImages(node, resources, siblings));
  }
}

/// 元素内的 `<img>` 按资源规则改写，返回 outerHtml
String _rewriteImages(
  dom.Element el,
  Map<String, Uint8List> resources,
  Map<String, Uint8List>? siblings,
) {
  for (final img in el.querySelectorAll('img')) {
    final src = img.attributes['src'] ?? '';
    final name = _materializeImage(src, resources, siblings);
    if (name != null) img.attributes['src'] = name;
  }
  return el.outerHtml;
}

/// 图片 src → 资源名。
///
/// 只有两种能"取到字节"：`data:` 内联图、以及调用方提供的兄弟文件里的相对路径。
/// 其余（`http(s):`、本地文件但兄弟表里没有）返回 null —— **保留原 src**。
String? _materializeImage(
  String src,
  Map<String, Uint8List> resources,
  Map<String, Uint8List>? siblings,
) {
  if (src.isEmpty) return null;
  if (src.startsWith('data:')) {
    final comma = src.indexOf(',');
    if (comma < 0) return null;
    final meta = src.substring(5, comma);
    if (!meta.contains('base64')) return null;
    try {
      final data = base64.decode(src.substring(comma + 1));
      if (data.isEmpty) return null;
      final kind = _imageExt(meta);
      final name = 'html-img-${resources.length}.$kind';
      resources[name] = Uint8List.fromList(data);
      return name;
    } catch (_) {
      return null;
    }
  }
  if (siblings == null || siblings.isEmpty) return null;
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:').hasMatch(src)) return null;
  final key = normalizeBookPath(src);
  final data = siblings[key] ?? siblings[src];
  if (data == null) return null;
  resources[key] = data;
  return key;
}

String _imageExt(String mime) {
  if (mime.contains('png')) return 'png';
  if (mime.contains('gif')) return 'gif';
  if (mime.contains('webp')) return 'webp';
  if (mime.contains('bmp')) return 'bmp';
  if (mime.contains('svg')) return 'svg';
  return 'jpg';
}

/// `a/b/../c.png` → `a/c.png`（书内资源路径归一化，EPUB/OPF/FBZ 共用同一规则）
String normalizeBookPath(String path) {
  final clean = path.split('#').first.split('?').first.replaceAll('\\', '/');
  final parts = <String>[];
  for (final seg in clean.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(seg);
  }
  return parts.join('/');
}

// ------------------------------------------------------------------ RTF

/// `.rtf`：控制字解析 → 段落 + 粗斜体
BookContent parseRtfBook(
  List<int> bytes, {
  required BookFormat format,
  String title = '',
}) {
  final text = decodeBookText(bytes);
  final paras = _RtfParser(text).parse();
  final split = bookChapterize(paras, format: format);
  var resolvedTitle = title;
  if (resolvedTitle.isEmpty) {
    for (final p in paras) {
      if (p.title != null && p.title!.isNotEmpty) {
        resolvedTitle = p.title!;
        break;
      }
    }
  }
  return BookContent(
    format: format,
    title: resolvedTitle,
    chapters: split.chapters,
    toc: split.toc,
  );
}

/// RTF 目的地（这些分组里的内容是排版元数据，不是正文 → 整组跳过）
const Set<String> _kRtfSkipDestinations = {
  'fonttbl', 'colortbl', 'stylesheet', 'info', 'pict', 'header', 'footer', //
  'footerl', 'footerr', 'headerl', 'headerr', 'footnote', 'annotation',
  'xe', 'tc', 'bkmkstart', 'bkmkend', 'listtable', 'listoverridetable',
  'revtbl', 'generator', 'themedata', 'datastore', 'latentstyles',
  'rsidtbl', 'filetbl', 'objdata', 'object', 'nonshppict', 'shppict',
  'upn', 'xmlnstbl',
};

class _RtfParser {
  _RtfParser(this.src);
  final String src;
  int i = 0;
  int depth = 0;
  bool skipping = false;
  int skipDepth = -1;
  bool expectDestination = false;

  bool bold = false;
  bool italic = false;
  bool underline = false;
  int ucSkip = 1;
  int ansiCodePage = 1252;

  final List<BookBlock> paras = [];
  final StringBuffer para = StringBuffer();
  final List<int> ansiBytes = [];

  List<BookBlock> parse() {
    while (i < src.length) {
      final c = src[i];
      if (c == '{') {
        i++;
        depth++;
        if (!skipping) expectDestination = true;
        continue;
      }
      if (c == '}') {
        // 跳过组里的 `{` / `}` 只是深度记账，不产出正文
        if (skipping && depth == skipDepth) skipping = false;
        depth--;
        i++;
        continue;
      }
      if (c == r'\') {
        _backslash();
        continue;
      }
      if (c == '\r' || c == '\n') {
        // RTF 源里的换行只是排版用的空白，不是段落分隔
        i++;
        continue;
      }
      i++;
      if (skipping) continue;
      _flushAnsi();
      _text(c);
    }
    _endParagraph();
    return paras;
  }

  /// 消费一个 `\…`
  void _backslash() {
    i++; // 跳过反斜杠
    if (i >= src.length) return;
    final c = src[i];

    // `\'hh`：当前代码页的一个字节
    if (c == "'") {
      i++;
      if (i + 1 >= src.length) return;
      final v = int.tryParse(src.substring(i, i + 2), radix: 16);
      i += 2;
      if (v == null || skipping) return;
      ansiBytes.add(v);
      return;
    }
    // `\\` `\{` `\}`：字面量
    if (c == r'\' || c == '{' || c == '}') {
      i++;
      if (skipping) return;
      _flushAnsi();
      _text(c);
      return;
    }
    // `\*`：这一组是"可忽略的目的地"，整组跳过
    if (c == '*') {
      i++;
      expectDestination = false;
      if (!skipping) {
        skipping = true;
        skipDepth = depth;
      }
      return;
    }
    if (c == '~') {
      i++;
      if (skipping) return;
      _flushAnsi();
      _text('\u00A0');
      return;
    }
    if (c == '-' || c == '_') {
      i++;
      return;
    }
    if (!_isAsciiLetter(c)) {
      i++; // 未知控制符号：忽略
      return;
    }

    final start = i;
    while (i < src.length && _isAsciiLetter(src[i])) {
      i++;
    }
    final word = src.substring(start, i).toLowerCase();

    var neg = false;
    if (i < src.length && src[i] == '-') {
      neg = true;
      i++;
    }
    final numStart = i;
    while (i < src.length && _isDigit(src[i])) {
      i++;
    }
    final hasNum = i > numStart;
    var param = hasNum ? int.parse(src.substring(numStart, i)) : 0;
    if (neg) param = -param;
    if (i < src.length && src[i] == ' ') i++; // 控制字后的空格是分隔符

    final atGroupStart = expectDestination;
    expectDestination = false;

    if (atGroupStart && _kRtfSkipDestinations.contains(word)) {
      if (!skipping) {
        skipping = true;
        skipDepth = depth;
      }
      return;
    }
    if (skipping) return;

    switch (word) {
      case 'par':
        _endParagraph();
        return;
      case 'pard':
        return;
      case 'line':
        _flushAnsi();
        _text('<br>');
        return;
      case 'tab':
        _flushAnsi();
        _text('    ');
        return;
      case 'b':
        _setStyle(bold: !(hasNum && param == 0));
        return;
      case 'i':
        _setStyle(italic: !(hasNum && param == 0));
        return;
      case 'ul':
        _setStyle(underline: !(hasNum && param == 0));
        return;
      case 'ulnone':
        _setStyle(underline: false);
        return;
      case 'plain':
        _setStyle(bold: false, italic: false, underline: false);
        return;
      case 'ansicpg':
        if (hasNum) ansiCodePage = param;
        return;
      case 'uc':
        if (hasNum) ucSkip = param.clamp(0, 32);
        return;
      case 'u':
        _flushAnsi();
        var cp = param;
        if (cp < 0) cp += 65536;
        if (cp >= 0 && cp <= 0x10FFFF) _text(String.fromCharCode(cp));
        _skipFallback();
        return;
      default:
        return;
    }
  }

  /// 跳过 `\uN` 之后的回落字符（默认 1 个，多为 `\'hh` 或 `?`）
  void _skipFallback() {
    var left = ucSkip;
    while (left > 0 && i < src.length) {
      final c = src[i];
      if (c == r'\') {
        if (i + 1 < src.length && src[i + 1] == "'") {
          i += 4; // \'hh
        } else {
          return; // 其它控制字不当回落字符
        }
      } else if (c == '{' || c == '}') {
        return;
      } else {
        i++;
      }
      left--;
    }
  }

  void _setStyle({bool? bold, bool? italic, bool? underline}) {
    _flushAnsi();
    if (bold != null) this.bold = bold;
    if (italic != null) this.italic = italic;
    if (underline != null) this.underline = underline;
  }

  void _text(String s) {
    if (s.isEmpty) return;
    var open = '';
    var close = '';
    if (bold) {
      open += '<strong>';
      close = '</strong>$close';
    }
    if (italic) {
      open += '<em>';
      close = '</em>$close';
    }
    if (underline) {
      open += '<u>';
      close = '</u>$close';
    }
    para.write('$open${_escape(s)}$close');
  }

  void _flushAnsi() {
    if (ansiBytes.isEmpty) return;
    final bytes = Uint8List.fromList(ansiBytes);
    ansiBytes.clear();
    final decoded = switch (ansiCodePage) {
      936 => decodeGb18030(bytes, strict: false)!,
      950 => decodeBig5(bytes, strict: false)!,
      65001 => utf8.decode(bytes, allowMalformed: true),
      _ => _decodeCp1252(bytes),
    };
    _text(decoded);
  }

  void _endParagraph() {
    _flushAnsi();
    final html = para.toString().trim();
    para.clear();
    if (html.isEmpty) return;
    final text = html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    // RTF 里的章标题没有统一标记；"整段加粗且很短"是最接近的启发式
    final isBoldOnly =
        html.startsWith('<strong>') && html.endsWith('</strong>');
    final heading =
        isBoldOnly && text.isNotEmpty && text.length <= _kHeadingMaxChars;
    paras.add(
      BookBlock('<p>$html</p>', title: heading ? text : null, heading: heading),
    );
  }
}

bool _isAsciiLetter(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
}

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x30 && u <= 0x39;
}

String _decodeCp1252(Uint8List bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.writeCharCode(b >= 0x80 && b <= 0x9F ? _kCp1252[b - 0x80] : b);
  }
  return buf.toString();
}

const List<int> _kCp1252 = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
];

// ------------------------------------------------------------------ 通用分章

/// 一个"段落块"：HTML + 可选标题 + 是不是标题段。
///
/// TXT/HTML/RTF/DOCX/ODT/PalmDOC **共用**同一套分章逻辑（见 [bookChapterize]），
/// 所以它是公开类型。
class BookBlock {
  BookBlock(this.html, {this.title, this.heading = false});
  final String html;
  final String? title;
  final bool heading;
}

/// 纯文本 → 段落（空行分段；章节标记行成为标题段）
List<BookBlock> _parasFromPlainText(String text) {
  final lines = const LineSplitter().convert(text.replaceAll('\r\n', '\n'));
  final paras = <BookBlock>[];
  final buf = <String>[];
  void flush() {
    if (buf.isEmpty) return;
    final joined = buf.join('\n').trim();
    buf.clear();
    if (joined.isEmpty) return;
    final title = _headingTitle(joined);
    if (title != null) {
      paras.add(
        BookBlock('<h2>${_escape(title)}</h2>', title: title, heading: true),
      );
      return;
    }
    final html = joined
        .split('\n')
        .map((l) => _escape(l.trim()))
        .where((l) => l.isNotEmpty)
        .join('<br>');
    // ★★★ r379（DA28）真机 ANR 的根因就在这里 —— **一个段可以长达整本书**。
    //
    // 触发场景（真机 HONOR LGE-AN10，2/2 复现）：`.txt` 全文只用**单换行**、
    // 一个空行都没有（日志/导出的文本极常见）⇒ `flush()` 只在**空行**触发
    // ⇒ 整份 1.5 MB 文本成为**一个** `<p>`（78,103 行）⇒ 后面
    // `bookChapterize` 的"按大小切块"是**逐段 append 后**才检查长度
    // （`if (buf.length >= kTextSplitTarget) flushChunk();`），单段本身就超长
    // ⇒ 整本进**同一章**，最后把一个 1.5 MB 的字符串交给渲染器排版，
    // UI 线程被排版卡死 ≥5 s ⇒ 系统弹 `SynHub isn't responding`（ANR）。
    //
    // 宿主侧测量（`test/tmp_*`，已删）：解析 1.5 MB = **28 ms**、
    // `TextPainter.layout` 1.5 MB = **162 ms**（测试字体、无 shaping）
    // ⇒ 解析不是元凶；真机字体下同一次排版的量级差着两位数，正是 ANR 的来源。
    //
    // 修法：**在段内按行切块**（切点只落在行边界，绝不切进 `<p>`/`<br>`/转义文本），
    // 保证任何一次交给渲染器的文本块都不超过 `kTextSplitTarget`。
    paras.addAll(_longParagraphBlocks(html));
  }

  for (final line in lines) {
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    buf.add(line);
  }
  flush();
  return paras;
}

/// 把一个（可能超长的）段落 HTML 切成若干不超过 [kTextSplitTarget] 的 `<p>` 块。
///
/// ★ r379（DA28）：切点**只落在 `'<br>'` 之间** —— 段落 HTML 由
/// `_escape()` 过的行 + `<br>` 组成，所以除 `<p>`/`<br>`/`<h2>` 之外文本里
/// 不可能再出现裸 `<`；按 `'<br>'` 拆开再拼回去，永远不会切进标签中间。
/// 单行本身超过目标（没有 `<br>` 可切）时退化为按字符硬切，每片仍各自包 `<p>`。
///
/// 不截断内容：所有片拼起来与原文逐字相同（数量守恒，见
/// `test/book_text_chunk_test.dart`）。
List<BookBlock> _longParagraphBlocks(String html) {
  if (html.length <= kTextSplitTarget) return [BookBlock('<p>$html</p>')];
  final blocks = <BookBlock>[];
  final lines = html.split('<br>');
  final buf = <String>[];
  var len = 0;
  void flushPart() {
    if (buf.isEmpty) return;
    blocks.add(BookBlock('<p>${buf.join('<br>')}</p>'));
    buf.clear();
    len = 0;
  }

  for (final line in lines) {
    // 单行就超目标：先收掉手上的，再把它自身切片
    if (line.length >= kTextSplitTarget) {
      flushPart();
      for (var i = 0; i < line.length; i += kTextSplitTarget) {
        final end = (i + kTextSplitTarget).clamp(0, line.length);
        blocks.add(BookBlock('<p>${line.substring(i, end)}</p>'));
      }
      continue;
    }
    if (len + line.length > kTextSplitTarget) flushPart();
    buf.add(line);
    len += line.length;
  }
  flushPart();
  return blocks;
}

/// 一行文本像不像章节标题（`第一章 …` / `Chapter 3 …`）
String? _headingTitle(String line) {
  final t = line.trim();
  if (t.isEmpty || t.length > _kHeadingMaxChars) return null;
  if (t.contains('\n')) return null;
  // 标题里几乎不会出现句末/句中标点 —— 用它们挡掉"第三章讲了什么。"这类正文
  // （保守优先：宁可少分一章，也不要把一句正文当标题）
  if (RegExp(r'[。！？；，]').hasMatch(t)) return null;
  if (RegExp(r'^第\s*[0-9〇零一二三四五六七八九十百千两]+\s*[章节回卷部篇集]').hasMatch(t)) {
    return t;
  }
  if (RegExp(
    r'^(?:chapter|prologue|epilogue|part|book)\s+[0-9ivxlc]+',
    caseSensitive: false,
  ).hasMatch(t)) {
    return t;
  }
  return null;
}

/// 段落表 → 章节表。
///
/// 有标题段（>=2 个）→ 按标题分章；否则单章；单章超过 [kTextSplitThreshold]
/// 时按段落边界切成 `第 N 节`（Quill 一次渲染几 MB 会明显卡顿）。
({List<BookChapter> chapters, List<BookTocEntry> toc}) bookChapterize(
  List<BookBlock> paras, {
  required BookFormat format,
}) {
  final chapters = <BookChapter>[];
  final toc = <BookTocEntry>[];

  final headingCount = paras.where((p) => p.heading).length;
  if (headingCount >= 2) {
    final buf = StringBuffer();
    String? title;
    void flush() {
      final html = buf.toString().trim();
      buf.clear();
      if (html.isEmpty && title == null) return;
      final index = chapters.length;
      chapters.add(
        BookChapter(
          title: title ?? fsTFill('bookChapterN', '第 ${index + 1} 章', {
            'n': '${index + 1}',
          }),
          generatedUnit: title == null ? BookGeneratedUnit.chapter : null,
          html: html,
        ),
      );
      toc.add(BookTocEntry(title: chapters.last.title, chapterIndex: index));
      title = null;
    }

    for (final p in paras) {
      if (p.heading && buf.toString().trim().isNotEmpty) flush();
      if (p.heading) title = p.title;
      buf.write(p.html);
    }
    flush();
    if (chapters.isNotEmpty) return (chapters: chapters, toc: toc);
  }

  final total = paras.fold<int>(0, (a, p) => a + p.html.length);
  if (total <= kTextSplitThreshold) {
    chapters.add(
      BookChapter(
        title: fsT('bookBodyText', '正文'),
        generatedUnit: BookGeneratedUnit.body,
        html: paras.map((p) => p.html).join(),
      ),
    );
    return (chapters: chapters, toc: toc);
  }

  final buf = StringBuffer();
  void flushChunk() {
    final html = buf.toString();
    buf.clear();
    if (html.trim().isEmpty) return;
    chapters.add(
      BookChapter(
        title: fsTFill('bookSectionN', '第 ${chapters.length + 1} 节', {
          'n': '${chapters.length + 1}',
        }),
        generatedUnit: BookGeneratedUnit.section,
        html: html,
      ),
    );
  }

  for (final p in paras) {
    buf.write(p.html);
    if (buf.length >= kTextSplitTarget) flushChunk();
  }
  flushChunk();
  return (chapters: chapters, toc: toc);
}

// ------------------------------------------------------------------ 工具

/// 纯文本（TXT/TCR/PalmDOC）→ BookContent（给 `book_mobi.dart` 的 PalmDOC 复用）
BookContent bookFromPlainText(
  String text, {
  required BookFormat format,
  required String title,
  String author = '',
}) {
  final paras = _parasFromPlainText(text);
  final split = bookChapterize(paras, format: format);
  var resolvedTitle = title;
  if (resolvedTitle.isEmpty) {
    for (final p in paras) {
      if (p.title != null && p.title!.isNotEmpty) {
        resolvedTitle = p.title!;
        break;
      }
    }
  }
  return BookContent(
    format: format,
    title: resolvedTitle,
    author: author,
    chapters: split.chapters,
    toc: split.toc,
  );
}

/// 章节标题检测（PalmDOC/PRC 复用）
String? bookHeadingTitle(String line) => _headingTitle(line);

String _escape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
