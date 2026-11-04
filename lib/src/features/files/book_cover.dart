// 电子书封面提取（纯函数，客户端自己解析）。
//
// **为什么要在客户端做**：NAS 的 `SYNO.FileStation.Thumb.get` 只认图片/视频，
// 对 `.epub` 直接回 404 + 一页 HTML（真机验证过：`book.epub` → 404，
// `cover.jpg` → 200 + 真 JPEG）。想让文件列表里的电子书显示封面，就只能自己
// 把整本书读进来、从包里把封面抠出来，不能指望服务端给缩略图。
//
// **为什么所有异常都吞成 null**：这个函数是在列表滚动时被成批调用的，
// 任何一本损坏的包、被截断的 XML、半截的 base64 都会让整条列表崩掉；而调用方
// 的降级路径本来就存在——拿不到封面就退回分类图标。所以 zip 解不开、OPF 乱、
// 封面字节不像图片、找不到 cover，统统返回 null，代价只是多解析一次。
//
// 两条硬边界，都是"列表内存"逼出来的：
//
//   * **8MB 上限**：缩略图会在滚动里被批量解码并缓存，一张几十 MB 的原图能把
//     列表内存打爆。现实中的电子书封面普遍在 50KB~2MB，8MB 已经宽到几乎不会
//     误伤正常书，又能挡住"封面其实是张大扫图"的极端情况。
//   * **返回前做图片 magic number 校验**：NAS 的错误页、书里被塞错的资源都可能
//     是 HTML/纯文本；直接丢给 `Image.memory` 会红屏，所以必须是 PNG/JPEG/GIF/
//     WEBP/BMP 之一才放行。
//
// 这里只做"字节 → 封面字节"：不碰 UI、不碰 provider、不做缓存。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as htmlp;

import 'book_chm.dart' show chmCoverBytes;
import 'book_djvu.dart' show djvuCoverBytes;
import 'book_fb3.dart' show fb3CoverBytes;
import 'book_mobi.dart' show mobiCoverBytes;
import 'book_rb.dart' show rbCoverBytes;
import 'book_xps.dart' show xpsCoverBytes;
import 'rar_archive.dart';

/// 封面体积上限。来源见文件头：列表缩略图会被批量解码缓存，单张巨图能打爆内存；
/// 8MB 远高于真实封面（一般 <2MB），只用来兜住"封面其实是整页扫描图"的极端书。
const int _maxCoverBytes = 8 * 1024 * 1024;

/// 从电子书字节里抠封面图。拿不到 → null（**不抛异常**）。
///
/// [extension] 是文件名后缀（大小写不敏感），支持 epub / cbz / cbr / fb2 / mobi / azw3 / chm，
/// 其余（含 pdf）返回 null（PDF 走渲染第一页那条路，不在这里）。
/// 这些格式 `bookCoverBytes` 里有对应分支（能抠出封面）。
///
/// 列表用它决定"要不要为了封面把整本书下下来"：TXT/RTF/DOCX/ODT/CB7 这些
/// 本批新增的格式**没有封面可抠**，让它们进这条路只会白白下载整份文件。
bool bookCoverSupported(String extension) {
  switch (extension.toLowerCase()) {
    case 'epub':
    case 'cbz':
    case 'cbr':
    case 'fb2':
    case 'mobi':
    case 'azw':
    case 'azw3':
    case 'chm':
    case 'djvu':
    case 'djv':
    case 'xps':
    case 'oxps':
    case 'fb3':
    case 'rb':
      return true;
    default:
      return false;
  }
}

Uint8List? bookCoverBytes(String extension, Uint8List bytes) {
  try {
    final cover = switch (extension.toLowerCase()) {
      'epub' => _epubCover(bytes),
      'cbz' => _cbzCover(bytes),
      'cbr' => _cbrCover(bytes),
      'fb2' => _fb2Cover(bytes),
      // MOBI/AZW3：走 PalmDB 的 EXTH 201（封面偏移）轻路径，不解正文。
      // HUFF/CDIC、DRM、纯 KF8 拿不到就返回 null —— 列表退回分类图标。
      'mobi' || 'azw' || 'azw3' => mobiCoverBytes(bytes),
      // CHM：解 hhc/默认首页 → 第一张 <img>，退到归档第一张图；LZX 做不到
      // （窗口/块类型/LZXC 版本不支持）就返回 null —— 列表退回分类图标。
      'chm' => chmCoverBytes(bytes),
      // DJVU：优先 THUM 的 TH44 缩略图，其次渲染第一页（自研纯 Dart，零 GPL）
      'djvu' || 'djv' => djvuCoverBytes(bytes),
      // XPS/OXPS：第一页引用的第一张图（ImageBrush），退到包内第一张图
      'xps' || 'oxps' => xpsCoverBytes(bytes),
      // FB3：`<cover><image href="…"/>` 指向的包内图片
      'fb3' => fb3CoverBytes(bytes),
      // RB：ToC 里第一张 PNG（裸 PNG，没有单独偏移表）
      'rb' => rbCoverBytes(bytes),
      // pdf：已有"渲染第一页"的独立路径，不走这里。
      _ => null,
    };
    // 统一收口校验：分支里可能抠到 HTML 错误页、超大图、半截数据，
    // 在这里一次性挡掉，比每个分支各查一遍更不容易漏。
    if (cover == null || cover.length > _maxCoverBytes) return null;
    if (!looksLikeCoverImage(cover)) return null;
    return cover;
  } catch (_) {
    // 敢吞的理由见文件头：列表调用方已有"退分类图标"的降级路径，
    // 为一次解析失败把整条列表崩掉不划算。
    return null;
  }
}

/// 字节看起来是不是一张图（PNG/JPEG/GIF/WEBP/BMP）。
///
/// 与 `file_thumb.dart` 里的 `looksLikeImage` 同款，这里放一份私有实现是为了
/// 不在并行开发时去动 `file_thumb.dart`。只看 magic number，不解码像素。
bool looksLikeCoverImage(Uint8List b) {
  if (b.length < 12) return false;
  bool at(int i, int v) => b[i] == v;
  // PNG
  if (at(0, 0x89) && at(1, 0x50) && at(2, 0x4E) && at(3, 0x47)) return true;
  // JPEG
  if (at(0, 0xFF) && at(1, 0xD8)) return true;
  // GIF87a / GIF89a
  if (at(0, 0x47) && at(1, 0x49) && at(2, 0x46)) return true;
  // BMP
  if (at(0, 0x42) && at(1, 0x4D)) return true;
  // WEBP: RIFF….WEBP
  if (at(0, 0x52) &&
      at(1, 0x49) &&
      at(2, 0x46) &&
      at(3, 0x46) &&
      at(8, 0x57) &&
      at(9, 0x45) &&
      at(10, 0x42) &&
      at(11, 0x50)) {
    return true;
  }
  return false;
}

// ------------------------------------------------------------------ EPUB

/// EPUB 的封面找到顺序：
///   1. container.xml → OPF 路径（坏了就包里找第一个 `*.opf`）；
///   2. OPF 里 `<meta name="cover" content="ID">`（EPUB2）→ manifest 对应 href；
///   3. manifest 里 `properties="cover-image"` 的 item（EPUB3）；
///   4. id 或 href 含 `cover` 的图片 item；
///   5. 上面都指向了"封面页 XHTML"（不是图片本身）时，抠那一页里的 `<img>`；
///   6. 最后（可选）spine 第一个文档里的 `<img>`。
///
/// 故意**不**做"manifest 里第一个图片 item"：那多半是正文里的无关插图，
/// 拿它当封面比没有封面更糟。
Uint8List? _epubCover(Uint8List bytes) {
  // verify: false —— CRC 校验对"能解出结构就行"的封面提取是纯负担，
  // 而且现实里不少 EPUB 的 CRC 就是坏的（正文阅读器那边同样跳过）。
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);

  // 只遍历条目**名字**建索引，不碰 `.content`：archive 4.x 的条目内容是懒的，
  // 一旦取 content 就会把该条整条解压进内存；这里等真正选中封面再读。
  final files = <String, ArchiveFile>{};
  final byLower = <String, ArchiveFile>{};
  for (final f in archive) {
    if (!f.isFile) continue;
    final name = _normalize(f.name);
    if (name.isEmpty) continue;
    files[name] = f;
    byLower.putIfAbsent(name.toLowerCase(), () => f);
  }
  if (files.isEmpty) return null;

  // 1) container.xml → OPF 路径
  final container = _readEntry(files, byLower, 'META-INF/container.xml');
  var opfPath = '';
  if (container != null) {
    final doc = htmlp.parse(_decode(container));
    final rootfile = _firstByLocal(doc, 'rootfile');
    opfPath = _normalize(rootfile?.attributes['full-path'] ?? '');
  }
  if (opfPath.isEmpty || !files.containsKey(opfPath)) {
    // 兜底：container.xml 缺失或乱写时，直接找包里第一个 .opf
    opfPath = files.keys.firstWhere(
      (k) => k.toLowerCase().endsWith('.opf'),
      orElse: () => '',
    );
  }
  if (opfPath.isEmpty) return null;
  final opfBytes = _readEntry(files, byLower, opfPath);
  if (opfBytes == null) return null;
  final opfDir = _dirOf(opfPath);
  final opf = htmlp.parse(_decode(opfBytes));

  // 2) manifest：id → href（相对 OPF 目录解析）
  final manifest = <String, _ManifestItem>{};
  // ⚠️ 不能用 `manifest > item`：OPF 是 XML，`<item .../>` 这种自闭合标签会被
  // HTML 解析器当成"没闭合的开始标签"，后面的 item 全嵌进第一个里，直接子选择器
  // 只能拿到一个（file_book.dart 里真机踩过同一个坑）。
  for (final item in _allByLocal(opf, 'item')) {
    final id = item.attributes['id'] ?? '';
    final href = item.attributes['href'] ?? '';
    if (id.isEmpty || href.isEmpty) continue;
    manifest[id] = _ManifestItem(
      href: _resolvePath(opfDir, href),
      media: item.attributes['media-type'] ?? '',
      props: item.attributes['properties'] ?? '',
    );
  }

  // 3) 按 metadata/manifest 里的线索找
  final href = _coverHrefFromOpf(opf, manifest);
  if (href != null) {
    final raw = _readEntry(files, byLower, href);
    if (raw != null) {
      if (looksLikeCoverImage(raw)) return raw;
      // 指向的其实是"封面页 XHTML"（不少 EPUB2 这么写），再从页面里抠 <img>
      final fromPage = _firstImageInHtmlDoc(raw, _dirOf(href), files, byLower);
      if (fromPage != null) return fromPage;
    }
  }

  // 4) 最后兜底（可选）：spine 第一个文档里的 <img>
  final spineDoc = _firstSpineDocHref(opf, manifest);
  if (spineDoc != null) {
    final raw = _readEntry(files, byLower, spineDoc);
    if (raw != null) {
      final img = _firstImageInHtmlDoc(raw, _dirOf(spineDoc), files, byLower);
      if (img != null) return img;
    }
  }
  return null;
}

/// OPF 清单里的一项
class _ManifestItem {
  const _ManifestItem({
    required this.href,
    required this.media,
    required this.props,
  });

  final String href;
  final String media;
  final String props;
}

String? _coverHrefFromOpf(
  dom.Document opf,
  Map<String, _ManifestItem> manifest,
) {
  // EPUB2 风格：<meta name="cover" content="ID"/>
  for (final m in _allByLocal(opf, 'meta')) {
    if ((m.attributes['name'] ?? '').toLowerCase() != 'cover') continue;
    final item = manifest[m.attributes['content'] ?? ''];
    if (item != null) return item.href;
  }
  // EPUB3 风格：properties="cover-image"
  for (final item in manifest.values) {
    if (item.props.split(RegExp(r'\s+')).contains('cover-image')) {
      return item.href;
    }
  }
  // 兜底：id 或 href 里含 "cover" 的**图片** item
  for (final e in manifest.entries) {
    final looksImage =
        e.value.media.toLowerCase().startsWith('image/') ||
        _looksLikeImagePath(e.value.href);
    if (!looksImage) continue;
    if (e.key.toLowerCase().contains('cover') ||
        e.value.href.toLowerCase().contains('cover')) {
      return e.value.href;
    }
  }
  return null;
}

String? _firstSpineDocHref(
  dom.Document opf,
  Map<String, _ManifestItem> manifest,
) {
  final spine = _firstByLocal(opf, 'spine');
  if (spine == null) return null;
  for (final ref in _allByLocalIn(spine, 'itemref')) {
    final item = manifest[ref.attributes['idref'] ?? ''];
    if (item == null) continue;
    final p = item.href.toLowerCase();
    if (item.media.contains('html') ||
        p.endsWith('.xhtml') ||
        p.endsWith('.html') ||
        p.endsWith('.htm')) {
      return item.href;
    }
  }
  return null;
}

/// 从一页 HTML（封面页/正文页）里抠第一张能读到的图。
Uint8List? _firstImageInHtmlDoc(
  Uint8List raw,
  String baseDir,
  Map<String, ArchiveFile> files,
  Map<String, ArchiveFile> byLower,
) {
  final doc = htmlp.parse(_decode(raw));
  for (final img in doc.querySelectorAll('img')) {
    final src = img.attributes['src'] ?? '';
    if (src.isEmpty || src.startsWith('data:')) continue;
    final data = _readEntry(files, byLower, _resolvePath(baseDir, src));
    if (data != null && looksLikeCoverImage(data)) return data;
  }
  return null;
}

// ------------------------------------------------------------------ CBZ

/// CBZ 就是"一堆图片打成 zip"。按**自然序**取第一个图片条目
/// （`page2` 要排在 `page10` 前面，纯字典序会取错第一页）。
Uint8List? _cbzCover(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  final entries = <ArchiveFile>[];
  for (final f in archive) {
    if (!f.isFile) continue;
    final name = _normalize(f.name);
    // macOS 打包会塞一堆 __MACOSX/._xxx 资源叉，不是真页
    if (name.startsWith('__MACOSX/')) continue;
    if (!_looksLikeImagePath(name)) continue;
    // 超限的条目在读之前就跳过（`.content` 一旦取就会全解压进内存）：
    // 宁可往后找一张正常尺寸的页，也不为空这个限制放弃整本书。
    if (f.size > _maxCoverBytes) continue;
    entries.add(f);
  }
  if (entries.isEmpty) return null;
  entries.sort(
    (a, b) => _naturalCompare(_normalize(a.name), _normalize(b.name)),
  );
  return _readFile(entries.first);
}

// ------------------------------------------------------------------ CBR

/// CBR 就是"一堆图片打成 RAR"。和 CBZ 同一套规则：按**自然序**取第一张图。
///
/// 解压走自研的 `rar_archive.dart`；加密 / 多卷 / 未实现变体会抛
/// [RarUnsupportedException]，由 [bookCoverBytes] 统一吞成 null（列表退回图标）。
Uint8List? _cbrCover(Uint8List bytes) {
  final archive = RarArchive.open(bytes);
  final picked = <({String archiveName, String name})>[];
  for (final e in archive.entries) {
    if (e.isDir || e.encrypted) continue;
    final name = _normalize(e.name);
    if (name.startsWith('__MACOSX/')) continue;
    if (!_looksLikeImagePath(name)) continue;
    // 超大条目直接跳过（封面会被 `Image.memory` 解码进内存）
    if (e.unpackedSize > _maxCoverBytes) continue;
    picked.add((archiveName: e.name, name: name));
  }
  if (picked.isEmpty) return null;
  picked.sort((a, b) => _naturalCompare(a.name, b.name));
  final first = picked.first;
  return archive.extract(only: {first.archiveName})[first.archiveName];
}

// ------------------------------------------------------------------ FB2

/// FB2：`<coverpage><image l:href="#id"/></coverpage>` → 找
/// `<binary id="id" content-type="image/*">BASE64</binary>`。
///
/// 属性名只匹配**以 href 结尾**：不同生成器写成 `l:href`（FictionBook 命名空间）
/// 或 `xlink:href`，写死 `l:href` 会漏。
Uint8List? _fb2Cover(Uint8List bytes) {
  final doc = htmlp.parse(_decode(bytes));
  final coverpage = _firstByLocal(doc, 'coverpage');
  if (coverpage == null) return null;

  String href = '';
  for (final el in [coverpage, ...coverpage.querySelectorAll('*')]) {
    final tag = _local(el);
    if (tag != 'image' && tag != 'img') continue;
    href = _hrefAttr(el);
    if (href.isNotEmpty) break;
  }
  // `#cover.jpg` 这种是包内 id 引用；裸值也当 id 处理
  final id = href.startsWith('#') ? href.substring(1) : href;
  if (id.isEmpty) return null;

  for (final b in _allByLocal(doc, 'binary')) {
    if ((b.attributes['id'] ?? '') != id) continue;
    final text = b.text.replaceAll(RegExp(r'\s'), '');
    if (text.isEmpty) continue;
    // base64 解码前先按长度拦一次：4 字符 → 3 字节，超限就没必要真的解出来。
    // （FB2 的 binary 在 XML 文本里，解码前也要先防一次内存放大。）
    if (text.length > (_maxCoverBytes ~/ 3) * 4 + 4) return null;
    return base64.decode(text);
  }
  return null;
}

/// 取元素上任意"以 href 结尾"的属性（`href` / `l:href` / `xlink:href`）
String _hrefAttr(dom.Element e) {
  for (final entry in e.attributes.entries) {
    // 普通属性 key 是 String；带命名空间的（`l:href`）是 AttributeName，
    // toString() 才还原成 `l:href` 这种带前缀的名字。
    if (entry.key.toString().toLowerCase().endsWith('href')) return entry.value;
  }
  return '';
}

// ------------------------------------------------------------------ 工具

/// 取目标条目字节。先精确匹配，再**大小写不敏感**兜底找一次：书里 href 写的
/// 大小写和 zip 里实际条目名不一致是家常便饭（真机遇到过 `Cover.JPG` vs
/// `cover.jpg`），直接判失败会白白丢封面。
Uint8List? _readEntry(
  Map<String, ArchiveFile> files,
  Map<String, ArchiveFile> byLower,
  String path,
) {
  final name = _normalize(path);
  if (name.isEmpty) return null;
  final file = files[name] ?? byLower[name.toLowerCase()];
  if (file == null) return null;
  return _readFile(file);
}

/// 读单个条目。**读之前**先用 header 里的未压缩大小拦掉超大条目：
/// archive 4.x 的 `ArchiveFile.content` 是懒的，但一旦取就会把整条解压进内存，
/// 列表场景里没理由为一张封面付这个代价。
Uint8List? _readFile(ArchiveFile file) {
  if (file.size > _maxCoverBytes) return null;
  final data = file.content;
  if (data.length > _maxCoverBytes) return null;
  return data;
}

String _decode(Uint8List b) => utf8.decode(b, allowMalformed: true);

String _normalize(String path) {
  var p = path.replaceAll('\\', '/');
  while (p.startsWith('./')) {
    p = p.substring(2);
  }
  while (p.startsWith('/')) {
    p = p.substring(1);
  }
  return p;
}

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i + 1);
}

/// 把 `href` 按 base 目录解析成"归一化路径"（处理 `../`、`.%20` 这类转义）
String _resolvePath(String baseDir, String href) {
  final cleaned = href.split('#').first.split('?').first;
  var decoded = cleaned;
  try {
    // URL 解码：`My%20Cover.jpg` 要还原成带空格的真实条目名
    decoded = Uri.decodeComponent(cleaned);
  } catch (_) {
    // 半截 `%XX` 会让 decodeComponent 抛 FormatException；按原样用就好，
    // 不能因为一次坏转义就让整本书的封面判失败。
  }
  final joined = decoded.startsWith('/')
      ? decoded.substring(1)
      : '$baseDir$decoded';
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

List<dom.Element> _allByLocalIn(dom.Element root, String name) => [
  for (final e in root.querySelectorAll('*'))
    if (_local(e) == name) e,
];

bool _looksLikeImagePath(String path) {
  final p = path.toLowerCase();
  return p.endsWith('.jpg') ||
      p.endsWith('.jpeg') ||
      p.endsWith('.png') ||
      p.endsWith('.gif') ||
      p.endsWith('.webp') ||
      p.endsWith('.bmp');
}

/// 文件名自然序（`p2` < `p10`）——漫画页顺序错了整个阅读体验就废了
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
