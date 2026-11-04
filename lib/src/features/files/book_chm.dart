// CHM（HTML Help）**内容抽取层** —— 纯 Dart，不 import flutter / l10n。
//
// 容器/LZX 在 `chm_archive.dart`；这里负责把"目录树 + LZX 解出来的字节"
// 变成和 EPUB/FB2 **同一套** `BookContent`（chapters + toc + anchors + resources），
// 于是目录面板 / 书内搜索 / 书签 / 进度 / 阅读设置 / 渲染层**全部免费复用**。
//
// 抽取口径（对齐现实里的 CHM 结构，事实来自公开的 chmspec）：
//
//   * `/#SYSTEM`：code 0 = 目录文件（`.hhc`）、1 = 索引（`.hhk`）、
//     2 = 默认首页、3 = 书名 —— 都是 **NT（NUL 结尾）字符串**；
//   * 正文页：目录树里所有 `.htm/.html/.xhtml`（排除 `/#`、`/$`、`::` 内部条目）；
//   * 目录层级：`.hhc` 是 **sitemap**（`<UL><LI><OBJECT type="text/sitemap">`
//     + `<param name="Name">` / `name="Local"`），`<UL>` 的嵌套就是层级，
//     这里映射成 [BookTocEntry]（复用同一条渲染路径）；
//   * 锚点：`Local` 里的 `page.htm#sec` 会把那一页**在锚点处切开**（复用
//     `file_book.dart` 的切章实现），所以目录能精确落到小节；页内的 `<a href>`
//     链接也进 `anchors` 表，阅读器可跳转；
//   * 正文渲染：**复用现有 HTML 管线**（`bookHtmlToFragment` → `noteHtmlToDelta`），
//     本文件一行渲染代码都没有；
//   * 编码：GBK/GB18030/Big5/UTF-8/UTF-16 走 `book_encoding.dart` 的探测；
//     探测不出（英文 CHM 的 ANSI/Windows-1252）时按 **CP1252** 回落 ——
//     真实样本 python2718.chm 的 hhc/正文正是 CP1252（见 `_decodeWindows1252` 注释）；
//   * 资源：`<img>` 指向的图片会内联进 `BookContent.resources`；
//     **CSS/JS 一律忽略**（渲染层是 Quill，不吃 CSS），这条是明确的边界；
//   * 封面：优先"默认首页里的第一张图"，拿不到再取归档里第一张图片，
//     都没有 → null（`book_cover.dart` 会再做体积/魔数校验）。
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as htmlp;

import 'book_encoding.dart';
import 'chm_archive.dart';
import 'file_book.dart';
import 'files_i18n.dart';

/// 单张资源上限（图片会被渲染层解码进内存，超大图直接忽略）
const int _kMaxResourceBytes = 16 * 1024 * 1024;

/// 全部资源的总体积上限（防止"整本扫描图"的 CHM 把内存打爆）
const int _kMaxTotalResourceBytes = 64 * 1024 * 1024;

/// 资源条目数上限
const int _kMaxResourceCount = 4096;

// ------------------------------------------------------------------ 入口

/// 解析 CHM。**不抛异常**：失败返回带 `error` 的 [BookParseResult]。
///
/// 能力边界（LZX 块类型/窗口/LZXC 版本）→ [BookParseErrorKind.unsupportedCompression]；
/// 坏文件/截断 → [BookParseErrorKind.parseFailed]。
BookParseResult parseChmBook(List<int> bytes, {required BookFormat format}) {
  try {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final doc = _readChm(data);
    if (doc.chapters.isEmpty) {
      return BookParseResult(
        BookContent(format: format),
        error: fsT('bookChmNoHtml', '这本书里没有可读的 HTML 正文'),
        errorKind: BookParseErrorKind.parseFailed,
      );
    }
    return BookParseResult(
      BookContent(
        format: format,
        title: doc.title,
        chapters: doc.chapters,
        toc: doc.toc,
        anchors: doc.anchors,
        resources: doc.resources,
      ),
    );
  } on ChmUnsupportedException catch (e) {
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
      error: fsT('bookChmParseFailed', '这本 CHM 解析失败（文件可能损坏）'),
      errorKind: BookParseErrorKind.parseFailed,
    );
  }
}

/// 从 CHM 里抠封面字节（拿不到 → null，**不抛**）。
///
/// 只解"默认首页/第一页 + 它引用的第一张图"，必要时再退到归档里第一张图片；
/// 不会把整本书的正文都切一遍。体积/魔数校验由调用方
/// （`book_cover.dart` 的 `bookCoverBytes`）统一收口，这里只做轻量魔数兜底。
Uint8List? chmCoverBytes(Uint8List bytes) {
  try {
    final archive = ChmArchive.open(bytes);
    final system = _readSystem(archive);

    // 1) 默认首页优先，其次归档里前几页
    final pages = _pageEntries(archive);
    final ordered = _orderPages(pages, system.defaultTopic, const []);
    for (final page in ordered.take(8)) {
      final html = _decode(archive.read(page));
      final root = htmlp.parseFragment(html);
      for (final img in root.querySelectorAll('img')) {
        final src = (img.attributes['src'] ?? '').trim();
        if (src.isEmpty || src.startsWith('data:')) continue;
        final hit = _resourceBytes(archive, page.normalized, src);
        if (hit != null) return hit;
      }
    }

    // 2) 归档里第一张图片
    final images =
        archive.entries
            .where(
              (e) =>
                  !e.isDir &&
                  !e.path.startsWith('::') &&
                  _isImage(e.normalized),
            )
            .toList()
          ..sort(
            (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
          );
    for (final e in images.take(8)) {
      if (e.length <= 0 || e.length > _kMaxResourceBytes) continue;
      final b = archive.read(e);
      if (_looksLikeImageBytes(b)) return b;
    }
    return null;
  } catch (_) {
    // 列表滚动时会成批调用：任何一本坏书都不该把整条列表崩掉（调用方有降级路径）
    return null;
  }
}

// ------------------------------------------------------------------ 文档

class _ChmDoc {
  _ChmDoc({
    required this.title,
    required this.chapters,
    required this.toc,
    required this.anchors,
    required this.resources,
  });
  final String title;
  final List<BookChapter> chapters;
  final List<BookTocEntry> toc;
  final Map<String, int> anchors;
  final Map<String, Uint8List> resources;
}

class _HhcItem {
  _HhcItem({
    required this.title,
    required this.path,
    required this.fragment,
    required this.depth,
  });
  final String title;
  final String path;
  final String fragment;
  final int depth;
}

_ChmDoc _readChm(Uint8List bytes) {
  final archive = ChmArchive.open(bytes);
  final system = _readSystem(archive);

  // ---- 目录（hhc）
  final hhcEntry = _findHhc(archive, system.contents);
  final items = hhcEntry == null
      ? const <_HhcItem>[]
      : _parseHhc(_decode(archive.read(hhcEntry)));

  // ---- 正文页顺序：默认首页 → hhc 引用顺序 → 其余按路径自然序
  final pages = _pageEntries(archive);
  final ordered = _orderPages(pages, system.defaultTopic, items);

  // ---- 逐页切片、建锚点
  final chapters = <BookChapter>[];
  final anchors = <String, int>{};
  final firstOf = <String, int>{};
  final fragIndexOf = <String, Map<String, int>>{};

  for (final page in ordered) {
    final norm = page.normalized;
    final key = norm.toLowerCase();
    final html = bookHtmlToFragment(
      _decode(archive.read(page)),
      baseDir: _dirOf(norm),
    );
    final ids = bookAnchorIds(html).toSet();

    // 这一页被 hhc 引用的锚点（顺序按 hhc）
    final frags = <String>[];
    for (final it in items) {
      if (it.path.toLowerCase() != key) continue;
      if (it.fragment.isEmpty || !ids.contains(it.fragment)) continue;
      if (!frags.contains(it.fragment)) frags.add(it.fragment);
    }
    // 页内 `<a href="page#sec">` 也补上（让脚注/跳转可用）
    for (final t in bookInternalLinkTargets(norm, html)) {
      if (t.path.toLowerCase() != key) continue;
      if (t.fragment.isEmpty || !ids.contains(t.fragment)) continue;
      if (!frags.contains(t.fragment)) frags.add(t.fragment);
    }

    final title = _titleFor(items, key) ?? _headingOf(html) ?? '';
    final base = chapters.length;
    firstOf[key] = base;

    if (frags.isEmpty) {
      chapters.add(
        BookChapter(
          title: title.isNotEmpty ? title : fsT('bookBodyText', '正文'),
          html: html,
          href: norm,
          generatedUnit: title.isEmpty ? BookGeneratedUnit.body : null,
        ),
      );
      fragIndexOf[key] = const {};
      continue;
    }

    final sliced = bookSliceChapterHtml(html, frags);
    for (final piece in sliced.pieces) {
      chapters.add(
        BookChapter(
          title: title.isNotEmpty ? title : fsT('bookBodyText', '正文'),
          html: piece,
          href: norm,
          generatedUnit: title.isEmpty ? BookGeneratedUnit.body : null,
        ),
      );
    }
    final map = <String, int>{};
    for (final f in frags) {
      final index = (base + (sliced.indexOf[f] ?? 0)).clamp(
        0,
        chapters.length - 1,
      );
      map[f] = index;
      anchors['$norm#$f'] = index;
    }
    fragIndexOf[key] = map;
  }
  if (chapters.isEmpty) {
    throw ChmFormatException('目录里没有任何 .htm/.html 正文');
  }

  // ---- 目录条目（hhc → BookTocEntry，层级就是 <UL> 嵌套）
  final toc = <BookTocEntry>[];
  for (final it in items) {
    final key = it.path.toLowerCase();
    final first = firstOf[key];
    if (first == null) continue; // hhc 引用了不在归档里的页 → 跳过（不猜）
    var index = first;
    if (it.fragment.isNotEmpty) {
      index = fragIndexOf[key]?[it.fragment] ?? first;
    }
    final fallback = index < chapters.length ? chapters[index].title : '';
    toc.add(
      BookTocEntry(
        title: it.title.isNotEmpty ? it.title : fallback,
        chapterIndex: index,
        depth: it.depth,
      ),
    );
  }

  // ---- 图片资源（CSS/JS 明确忽略：Quill 不吃 CSS）
  final resources = <String, Uint8List>{};
  var totalBytes = 0;
  for (final e in archive.entries) {
    if (resources.length >= _kMaxResourceCount) break;
    if (totalBytes >= _kMaxTotalResourceBytes) break;
    if (e.isDir || e.path.startsWith('::') || !_isImage(e.normalized)) continue;
    if (e.length <= 0 || e.length > _kMaxResourceBytes) continue;
    try {
      final b = archive.read(e);
      resources[e.normalized] = b;
      totalBytes += b.length;
    } catch (_) {
      // 单张图坏/解不开不该毁掉整本书：忽略它（正文照读）
    }
  }

  return _ChmDoc(
    title: system.title,
    chapters: chapters,
    toc: toc,
    anchors: anchors,
    resources: resources,
  );
}

/// 正文页排序：默认首页 → hhc 引用到的页（按 hhc 顺序）→ 其余按自然序
List<ChmEntry> _orderPages(
  List<ChmEntry> pages,
  String defaultTopic,
  List<_HhcItem> items,
) {
  final byLower = <String, ChmEntry>{
    for (final p in pages) p.normalized.toLowerCase(): p,
  };
  final out = <ChmEntry>[];
  final seen = <String>{};
  void take(String path) {
    var key = path.replaceAll('\\', '/').split('#').first.split('?').first;
    while (key.startsWith('/')) {
      key = key.substring(1);
    }
    final page = byLower[key.toLowerCase()];
    if (page == null) return;
    if (seen.add(page.normalized.toLowerCase())) out.add(page);
  }

  take(defaultTopic);
  for (final it in items) {
    take(it.path);
  }
  final rest =
      pages.where((p) => !seen.contains(p.normalized.toLowerCase())).toList()
        ..sort((a, b) => _naturalCompare(a.normalized, b.normalized));
  out.addAll(rest);
  return out;
}

List<ChmEntry> _pageEntries(ChmArchive archive) => archive.entries.where((e) {
  if (e.isDir || e.path.startsWith('::')) return false;
  if (e.path.startsWith('/#') || e.path.startsWith(r'/$')) return false;
  final p = e.normalized.toLowerCase();
  return p.endsWith('.htm') || p.endsWith('.html') || p.endsWith('.xhtml');
}).toList();

ChmEntry? _findHhc(ChmArchive archive, String contents) {
  if (contents.trim().isNotEmpty) {
    final e = archive.find(contents.trim());
    if (e != null && !e.isDir) return e;
  }
  final all =
      archive.entries
          .where((e) => !e.isDir && !e.path.startsWith('::'))
          .where((e) => e.normalized.toLowerCase().endsWith('.hhc'))
          .toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
  return all.isEmpty ? null : all.first;
}

String? _titleFor(List<_HhcItem> items, String key) {
  for (final it in items) {
    if (it.path.toLowerCase() == key && it.title.trim().isNotEmpty) {
      return it.title.trim();
    }
  }
  return null;
}

/// 第一个 h1-h4 的文本（没有就 null）
String? _headingOf(String html) {
  final root = htmlp.parseFragment(html);
  for (final tag in const ['h1', 'h2', 'h3', 'h4']) {
    final t = root.querySelector(tag)?.text.trim() ?? '';
    if (t.isNotEmpty) return t;
  }
  return null;
}

// ------------------------------------------------------------------ #SYSTEM

class _SystemInfo {
  String title = '';
  String contents = '';
  String defaultTopic = '';
}

/// `/#SYSTEM`：DWORD 版本 + 若干 `WORD code / WORD len / 数据(NUL 结尾)`
_SystemInfo _readSystem(ChmArchive archive) {
  final info = _SystemInfo();
  final e = archive.find('/#SYSTEM');
  if (e == null) return info;
  final data = archive.read(e);
  if (data.length < 4) return info;
  var p = 4;
  while (p + 4 <= data.length) {
    final code = data[p] | (data[p + 1] << 8);
    final len = data[p + 2] | (data[p + 3] << 8);
    p += 4;
    if (p + len > data.length) break;
    final raw = Uint8List.sublistView(data, p, p + len);
    p += len;
    final value = _decode(raw).replaceAll('\u0000', '').trim();
    switch (code) {
      case 0:
        info.contents = value;
      case 2:
        info.defaultTopic = value;
      case 3:
        info.title = value;
    }
  }
  return info;
}

// ------------------------------------------------------------------ HHC

/// 解析 `.hhc` 的 sitemap：`<UL>` 的嵌套 = 层级，`<LI>` 里的 OBJECT/param 给
/// Name（显示名）与 Local（目标页 `page.htm#anchor`）。
List<_HhcItem> _parseHhc(String raw) {
  final doc = htmlp.parse(raw);
  final out = <_HhcItem>[];
  if (doc.documentElement == null) return out;

  bool isNamed(dom.Element e, String name) =>
      (e.localName ?? '').toLowerCase() == name;

  void walk(dom.Element ul, int depth) {
    for (final li in ul.children.where((c) => isNamed(c, 'li'))) {
      dom.Element? obj;
      for (final c in li.children) {
        if (isNamed(c, 'object')) {
          obj = c;
          break;
        }
      }
      if (obj != null) {
        String name = '';
        String local = '';
        for (final p in obj.children) {
          if (!isNamed(p, 'param')) continue;
          final key = (p.attributes['name'] ?? '').trim().toLowerCase();
          final value = p.attributes['value'] ?? '';
          if (key == 'name') name = value;
          if (key == 'local') local = value;
        }
        final type = (obj.attributes['type'] ?? '').toLowerCase();
        // 只认 sitemap 项（全局 `text/site properties` 没有 Local/Name，跳过）
        final split = _splitLocal(local);
        final isSitemap = type.isEmpty || type.contains('sitemap');
        if (isSitemap && (name.isNotEmpty || split.path.isNotEmpty)) {
          out.add(
            _HhcItem(
              title: name.trim(),
              path: split.path,
              fragment: split.fragment,
              depth: depth,
            ),
          );
        }
      }
      for (final nested in li.children.where((c) => isNamed(c, 'ul'))) {
        walk(nested, depth + 1);
      }
    }
  }

  for (final ul in doc.querySelectorAll('ul')) {
    // 只从最外层 <ul> 起步（否则同一棵子树会被走两遍）
    if (_hasUlAncestor(ul)) continue;
    walk(ul, 0);
  }
  return out;
}

bool _hasUlAncestor(dom.Element e) {
  for (var p = e.parent; p != null; p = p.parent) {
    if ((p.localName ?? '').toLowerCase() == 'ul') return true;
  }
  return false;
}

({String path, String fragment}) _splitLocal(String local) {
  var s = local.trim();
  if (s.isEmpty) return (path: '', fragment: '');
  final hash = s.indexOf('#');
  var pathPart = hash >= 0 ? s.substring(0, hash) : s;
  var frag = hash >= 0 ? s.substring(hash + 1) : '';
  final lower = pathPart.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('mailto:') ||
      lower.startsWith('javascript:')) {
    return (path: '', fragment: '');
  }
  pathPart = pathPart.split('?').first.replaceAll('\\', '/');
  pathPart = _tryDecode(pathPart);
  frag = _tryDecode(frag);
  while (pathPart.startsWith('/')) {
    pathPart = pathPart.substring(1);
  }
  while (pathPart.startsWith('./')) {
    pathPart = pathPart.substring(2);
  }
  return (path: pathPart.trim(), fragment: frag.trim());
}

String _tryDecode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

// ------------------------------------------------------------------ 工具

/// CHM 文本解码：先走通用探测（UTF-8/UTF-16/GB18030/Big5），**探测不出时按
/// Windows-1252（ANSI）解**。
///
/// ⚠️ 真实样本暴露的坑（`tool/chm_real_probe.dart` 对 python2718.chm 的实况）：
/// 英文 CHM 的 `.hhc` 与正文页是 **Windows-1252**，弯引号/破折号落在 `0x80..0x9F`
/// （右单引号是 `0x92`）。`detectAndDecodeBookText` 只认 UTF-8/UTF-16/CJK，
/// 这些字节既不是合法 UTF-8 也不是合法 GB18030/Big5 → 一路回落到
/// `utf-8(lossy)`，于是一页正文里冒出 `�`（实测：hhc 431 个、403/513 个页面命中）。
///
/// CHM 是 Windows 格式，ANSI 回落是安全的：CJK 编码的 CHM 会在探测阶段就命中
/// GB18030/Big5，不会走到这里。
///
/// 但还有第二类误判：**短的英文页**里 `0x92 's'`、`0x94 'n'` 这类组合本身就
/// 是**合法的 GB18030 双字节序列**，于是探测会信心十足地选 GB18030，把
/// `What’s` 解成 `What抯`（ascii+一个伪汉字）。判据：解出来几乎全是 ASCII、
/// 只有零星 CJK，而 `0x80..0x9F` 字节数与之相当 → 判为"英文 + CP1252 标点"。
///
/// 明确边界：CP1251（俄文）等其它 ANSI 代码页仍未处理，仍会回落到 lossy UTF-8
/// —— 那需要语言 ID 驱动的代码页选择，未实现。
String _decode(Uint8List bytes) {
  final r = detectAndDecodeBookText(bytes);
  if (r.encoding == BookTextEncoding.utf8Lossy) {
    return _decodeWindows1252(bytes);
  }
  if ((r.encoding == BookTextEncoding.gb18030 ||
          r.encoding == BookTextEncoding.big5) &&
      _cjkEvidenceWeak(bytes, r.text)) {
    return _decodeWindows1252(bytes);
  }
  return r.text;
}

/// "解成 CJK 的证据太弱"：真 CJK 文本里一个汉字平均贡献的 `0x80..0x9F` 尾字节
/// 远不到半个，所以 `cjk >> high`；反过来"英文正文 + 几个弯引号"是 `cjk ≈ high`。
/// 阈值取 2 倍，给真 CJK（尤其中英混排）留足余量。
bool _cjkEvidenceWeak(Uint8List bytes, String decoded) {
  var high = 0;
  for (final b in bytes) {
    if (b >= 0x80 && b <= 0x9F) high++;
  }
  if (high == 0) return false;
  var cjk = 0;
  for (final r in decoded.runes) {
    if ((r >= 0x2E80 && r <= 0x9FFF) || (r >= 0xF900 && r <= 0xFAFF)) cjk++;
  }
  return cjk < high * 2;
}

/// Windows-1252 的 `0x80..0x9F` 映射（其余字节与 Latin-1 相同）。
/// 0x81/0x8D/0x8F/0x90/0x9D 在 CP1252 里未定义，按原控制字符保留。
const List<int> _kCp1252High = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
];

String _decodeWindows1252(Uint8List bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.writeCharCode(b >= 0x80 && b <= 0x9F ? _kCp1252High[b - 0x80] : b);
  }
  return out.toString();
}

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i + 1);
}

bool _isImage(String path) {
  final p = path.toLowerCase();
  return p.endsWith('.jpg') ||
      p.endsWith('.jpeg') ||
      p.endsWith('.png') ||
      p.endsWith('.gif') ||
      p.endsWith('.webp') ||
      p.endsWith('.bmp');
}

/// 轻量魔数校验：一条 NAS 错误页/HTML 不该被当封面（`book_cover.dart` 还会再查一遍）
bool _looksLikeImageBytes(Uint8List b) {
  if (b.length < 12) return false;
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true;
  if (b[0] == 0xFF && b[1] == 0xD8) return true;
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true;
  if (b[0] == 0x42 && b[1] == 0x4D) return true;
  if (b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return true;
  }
  return false;
}

/// `page.htm` + `images/logo.png` → 资源字节；拿不到 → null（**不抛**）
Uint8List? _resourceBytes(ChmArchive archive, String pagePath, String src) {
  try {
    final link = classifyBookLink(pagePath, src);
    if (link.kind == BookLinkKind.external) return null;
    final target = link.path;
    if (target.isEmpty) return null;
    final e = archive.find(target);
    if (e == null ||
        e.isDir ||
        e.length <= 0 ||
        e.length > _kMaxResourceBytes) {
      return null;
    }
    final b = archive.read(e);
    return _looksLikeImageBytes(b) ? b : null;
  } catch (_) {
    return null;
  }
}

/// 文件名自然序（`p2` < `p10`）
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

// ------------------------------------------------------------------ 探针

/// 给探针用：只回报"能不能读 + 为什么不能"（不落 `BookContent`）。
///
/// 注意别和 `chm_archive.dart` 里**容器级**的 `chmSupportProbe` 混：那个只看
/// ITSF/目录能不能开；这个走完整内容抽取（hhc/正文/图片）。
Map<String, Object?> chmBookProbe(List<int> bytes) {
  final r = parseChmBook(bytes, format: BookFormat.chm);
  return {
    'ok': r.ok,
    'error': r.error,
    'kind': r.errorKind?.name,
    'chapters': r.content.chapters.length,
    'toc': r.content.toc.length,
    'images': r.content.resources.length,
    'title': r.content.title,
  };
}

/// 给探针用：目录层级 + 前三章标题（真机验证时肉眼核对）
Map<String, Object?> chmDebugProbe(List<int> bytes) {
  final r = parseChmBook(bytes, format: BookFormat.chm);
  return {
    'ok': r.ok,
    'title': r.content.title,
    'chapters': [for (final c in r.content.chapters.take(8)) c.title],
    'toc': [
      for (final e in r.content.toc.take(16)) '${"  " * e.depth}${e.title}',
    ],
    'anchors': r.content.anchors.length,
    'resources': r.content.resources.keys.take(8).toList(),
  };
}
