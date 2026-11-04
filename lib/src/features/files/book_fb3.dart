// FB3（FictionBook 3）解析层 —— **纯 Dart**，不 import flutter / l10n。
//
// 真实的 `.fb3` 是 **OPC 包（就是 zip）**，不是"一个 XML 文件套一层壳"。以
// `gribuser/FB3`（规范与参考工具仓库）产出的真实样本为准，包内结构是：
//
//   * `[Content_Types].xml`：`Override PartName="…/body.xml"
//     ContentType="application/fb3-body+xml"`、`…/description.xml` →
//     `application/fb3-description+xml`（**这是最可靠的 part 发现信号**）；
//   * 正文 part 根元素是 **`<fb3-body xmlns="…/FictionBook3/body">`**；
//   * 描述 part 根元素是 **`<fb3-description xmlns="…/FictionBook3/description">`**，
//     书名在 `<title><main>`，作者在 `<fb3-relations><subject link="author">`，
//     语言在 `<lang>`；
//   * 图片**不是**直接用路径，而是正文里 `src="img4"`（一个 rel Id），经
//     `<partdir>/_rels/<partname>.rels` 的 `Relationship Id="img4" Target="img/…"/>`
//     映射到真实部件；根 `_rels/.rels` 的
//     `relationships/metadata/thumbnail` 指向封面；
//   * part 路径**可以是任意大小写/任意目录**（`Hardcore file structure.fb3` 里
//     正文是根目录下一个百分号转义的、没有扩展名的部件，目录叫 `%D1%84%D0%B13/`），
//     所以发现流程走 Content_Types → rels → 约定路径 → 扫描，而不是写死 `fb3/`。
//
// 仍然兼容**旧实现假设的形态**（单个 `<FictionBook xmlns="…/FictionBook3">`
// 根、`description/title-info/book-title`、`<image href="…">`、base64 `<binary>`），
// 因为存世确实有导出器这么写；但这只是兼容分支，主路径是上面的 OPC。
//
// ---------------------------------------------------------------------------
// 明确**不做**的清单（宁可少读，也不输出乱码）：
//   * **CSS 不解析**：`<style>` 元素、`fb3/style/*.css`、class 属性一律忽略；
//     只映射 FB3 的语义行内标签（strong/em/sup/sub/code/strikethrough 等）；
//   * **notes / notebody / footnotes 的高级形态不做**：`<notes>` 区里的注释条
//     不单独成章、不生成可跳转的脚注面板（正文里的 `#id` 链接仍按普通锚点定位）；
//   * **SVG 不缩放/不渲染**：`.svg` 部件只作为资源登记，交给渲染层尽力而为；
//     SVG 封面不会被 `bookCoverBytes` 采纳（它只认 PNG/JPEG/GIF/BMP/WEBP）；
//   * **加密不解密**：发现 OPC 加密迹象直接抛 `BookUnsupportedException`
//     （与 ODT 的处理一致）；
//   * 结构化排版（多栏、float、min-width/max-width、on-one-page）、
//     `<poem>` 的精确缩进/换行、`<subscription>`（作者署名）单独排版、
//     `<code>` 语法高亮 —— 都不做，退化成普通块/行内文本。
import 'dart:convert';
import 'dart:typed_data';

import 'book_package.dart';
import 'book_xml.dart';
import 'file_book.dart';
import 'files_i18n.dart';

/// FB3 的结构性问题（人话文案）。[parseFb3Result] 会把它翻成带
/// [BookParseErrorKind.parseFailed] 的 [BookParseResult]，页面因此能给
/// "缺正文部件" 这种具体原因，而不是笼统的"解析失败"。
class Fb3FormatException implements Exception {
  const Fb3FormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 主入口：字节 → [BookContent]。
///
/// 解析不了时抛 [Fb3FormatException]（数据问题）或 [BookUnsupportedException]
/// （加密等能力边界）。走 [parseBook] 时请用 [parseFb3Result]，它负责把异常
/// 翻成带人话文案的失败结果。
BookContent parseFb3Book(List<int> bytes, {required BookFormat format}) {
  final pkg = _openFb3(bytes);
  final meta = _fb3Metadata(pkg);

  // ---------- 资源：包内所有图片 + 少量仍带 base64 <binary> 的 FB3 ----------
  final resources = <String, Uint8List>{
    for (final e in bookImageParts(pkg.files).entries) e.key: e.value,
  };
  final binaries = <String, Uint8List>{};
  for (final b in pkg.bodyDocument.descendants('binary')) {
    final id = (b.attr('id') ?? '').trim().toLowerCase();
    final data = b.text.replaceAll(RegExp(r'\s'), '');
    if (id.isEmpty || data.isEmpty) continue;
    try {
      final decoded = base64.decode(data);
      binaries[id] = decoded;
      resources[id] = decoded;
    } catch (_) {
      // 坏图跳过，不影响正文
    }
  }

  final resolver = _ImageResolver(
    files: pkg.files,
    resources: resources,
    binaries: binaries,
    bodyDir: pkg.bodyDir,
    bodyRels: pkg.bodyRels,
  );

  // ---------- 章节：section 树摊平，目录保留层级 ----------
  final chapters = <BookChapter>[];
  final toc = <BookTocEntry>[];
  final body = pkg.bodyNode;
  final sections = body.descendants('section').toList();

  if (sections.isEmpty) {
    final html = _fb3Inline(body, resolveImage: resolver.resolve);
    final title = meta.title;
    chapters.add(
      BookChapter(
        title: title.isEmpty ? fsT('bookBodyText', '正文') : title,
        generatedUnit: title.isEmpty ? BookGeneratedUnit.body : null,
        html: html,
      ),
    );
  } else {
    // 父指针表：section 的层级（目录 depth）靠数**结构性**祖先 section
    final parents = <BookXmlNode, BookXmlNode>{};
    void link(BookXmlNode n) {
      for (final c in n.children) {
        parents[c] = n;
        link(c);
      }
    }

    link(body);
    for (final s in sections) {
      // 只带子 section 的"包装 section"（没标题、没自己的内容）不成章：
      // 否则目录里会冒出一串空的"第 N 节"。
      if (!_sectionHasOwnContent(s)) continue;
      var depth = 0;
      for (var p = parents[s]; p != null; p = parents[p]) {
        if (p.local == 'section' && _sectionHasOwnContent(p)) depth++;
      }
      final own = _fb3SectionTitle(s);
      final generated = own.isEmpty;
      final title = generated
          ? fsTFill('bookSectionN', '第 ${chapters.length + 1} 节', {
              'n': '${chapters.length + 1}',
            })
          : own;
      final index = chapters.length;
      var html = _fb3Inline(
        s,
        skipSections: true,
        resolveImage: resolver.resolve,
      );
      // section 自己的 id 也要落地，否则 `<a href="#<sectionId>">` 找不到落点
      final sid = (s.attr('id') ?? '').trim();
      if (sid.isNotEmpty) {
        html = '<div id="${bookEscapeAttr(sid)}">$html</div>';
      }
      chapters.add(
        BookChapter(
          title: title,
          generatedUnit: generated ? BookGeneratedUnit.section : null,
          html: html,
        ),
      );
      toc.add(BookTocEntry(title: title, depth: depth, chapterIndex: index));
    }
  }

  // ---------- 锚点：章节 HTML 里的 id（FB3 没有独立文件路径，键是 `#id`） ----------
  final anchors = <String, int>{};
  for (var i = 0; i < chapters.length; i++) {
    for (final id in _idsInHtml(chapters[i].html)) {
      anchors.putIfAbsent('#$id', () => i);
    }
  }

  return BookContent(
    format: format,
    title: meta.title,
    author: meta.author,
    chapters: chapters,
    toc: toc,
    anchors: anchors,
    resources: resources,
  );
}

/// [parseBook] 的 FB3 分派入口：把结构性问题翻成**带具体文案**的失败结果。
///
/// [BookUnsupportedException]（加密）**原样放行**，让 `parseBook` 统一翻成
/// `unsupportedCompression`（与 ODT/CBR 一致）。
BookParseResult parseFb3Result(List<int> bytes, {required BookFormat format}) {
  try {
    return BookParseResult(parseFb3Book(bytes, format: format));
  } on BookUnsupportedException {
    rethrow;
  } on Fb3FormatException catch (e) {
    return BookParseResult(
      BookContent(format: format),
      error: e.message,
      errorKind: BookParseErrorKind.parseFailed,
    );
  } on FormatException catch (e) {
    return BookParseResult(
      BookContent(format: format),
      error: e.message,
      errorKind: BookParseErrorKind.parseFailed,
    );
  }
}

// ------------------------------------------------------------------ 包结构

/// 一个 OPC 关系：`Id` / `Type` / `Target`（Target 已按 rels 所在目录解析成
/// 小写归一化包内路径）。
class _Rel {
  const _Rel(this.id, this.type, this.target);
  final String id;
  final String type;
  final String target;
}

class _Rels {
  const _Rels(this.list);
  final List<_Rel> list;
  static const _Rels empty = _Rels(<_Rel>[]);

  bool get isEmpty => list.isEmpty;

  /// 按 `Id` 找 Target（大小写不敏感）
  String? targetById(String id) {
    final l = id.toLowerCase();
    for (final r in list) {
      if (r.id.toLowerCase() == l) return r.target;
    }
    return null;
  }

  /// 按 `Type` 后缀找第一个 Target（`…/thumbnail`、`…/body` 这种）
  String? targetByType(String suffix) {
    final s = suffix.toLowerCase();
    for (final r in list) {
      if (r.type.toLowerCase().endsWith(s)) return r.target;
    }
    return null;
  }
}

/// 打开后的 FB3 包（zip 或裸 XML 两种形态）。
class _Fb3Package {
  const _Fb3Package({
    required this.zip,
    required this.files,
    required this.bodyNode,
    required this.bodyDocument,
    required this.bodyDir,
    required this.bodyRels,
    required this.descNode,
    required this.descDir,
    required this.descRels,
    required this.rootRels,
  });

  final bool zip;
  final Map<String, Uint8List> files;

  /// 走正文的元素（`fb3-body` / `<body>` / FictionBook 文档根）
  final BookXmlNode bodyNode;

  /// 正文文档根（找 `<binary>` 用；裸 XML 时与 [bodyNode] 同一个文档）
  final BookXmlNode bodyDocument;

  final String bodyDir;
  final _Rels bodyRels;

  /// 走元数据的元素（`fb3-description` / `<description>`）
  final BookXmlNode? descNode;
  final String descDir;
  final _Rels descRels;

  /// 根 `_rels/.rels`
  final _Rels rootRels;
}

_Fb3Package _openFb3(List<int> bytes) {
  if (!bookBytesAreZip(bytes)) return _openRawXml(bytes);

  final Map<String, Uint8List> files;
  try {
    files = unzipBookPackage(bytes, 'FB3');
  } on FormatException {
    // zip 头在、但中央目录/条目坏了（截断）——明确说"损坏"，别泛化成"解析失败"
    throw const Fb3FormatException('FB3 压缩包损坏（zip 不完整），无法解压');
  }

  _rejectEncrypted(files);

  final rootRels = _readRels(files, '_rels/.rels', '');

  // Content_Types 的 Override 是最可靠的 part 发现信号；rels 与约定路径兜底。
  final ct = _contentTypes(files);
  var bodyPath = ct.bodyPart;
  var descPath = ct.descPart;

  if (descPath == null || !files.containsKey(descPath)) {
    descPath ??= rootRels.targetByType('/book');
    descPath ??= files.containsKey('fb3/description.xml')
        ? 'fb3/description.xml'
        : null;
  }
  if (bodyPath == null || !files.containsKey(bodyPath)) {
    final fromDesc = descPath == null
        ? null
        : _relsFor(files, descPath).targetByType('/body');
    bodyPath =
        fromDesc ??
        (files.containsKey('fb3/body.xml') ? 'fb3/body.xml' : null) ??
        rootRels.targetByType('/body');
  }

  // 还没找到就扫描：根元素是 fb3-body / fictionbook 的部件就是正文。
  bodyPath ??= _scanForRoot(files, const {'fb3-body', 'fictionbook', 'body'});
  descPath ??= _scanForRoot(files, const {'fb3-description'});

  if (bodyPath == null || !files.containsKey(bodyPath)) {
    throw const Fb3FormatException(
      'FB3 包里找不到正文部件（Content_Types 的 fb3-body、rels 与 fb3/body.xml 都没有）',
    );
  }

  final bodyDoc = _parsePart(files[bodyPath]!, 'FB3 正文 XML');
  final bodyNode = _bodyScope(bodyDoc);

  BookXmlNode? descNode;
  var descDir = '';
  var descRels = _Rels.empty;
  if (descPath != null && files.containsKey(descPath)) {
    final descDoc = _parsePart(files[descPath]!, 'FB3 描述 XML');
    descNode = _scopeElement(descDoc, const {'fb3-description'});
    descDir = bookDirOf(descPath);
    descRels = _readRels(files, _relsPathOf(descPath), descDir);
  } else if (_rootLocal(bodyDoc) == 'fictionbook') {
    // 兼容形态：描述与正文写在同一个 `<FictionBook>` 文档里
    descNode = bodyDoc.first('description');
  }

  return _Fb3Package(
    zip: true,
    files: files,
    bodyNode: bodyNode,
    bodyDocument: bodyDoc,
    bodyDir: bookDirOf(bodyPath),
    bodyRels: _readRels(files, _relsPathOf(bodyPath), bookDirOf(bodyPath)),
    descNode: descNode,
    descDir: descDir,
    descRels: descRels,
    rootRels: rootRels,
  );
}

/// 裸 XML 的 `.fb3`（没有 zip 外壳）：兼容旧实现的 `<FictionBook>` 与
/// 单独的 `fb3-body` / `fb3-description` 文档。
_Fb3Package _openRawXml(List<int> bytes) {
  final doc = parseBookXmlBytes(bytes);
  if (doc == null) {
    throw const Fb3FormatException('FB3 的 XML 无法解析（不是 zip，也不是合法 XML）');
  }
  final local = _rootLocal(doc);
  const accepted = {'fb3-body', 'fictionbook', 'body', 'fb3-description'};
  if (!accepted.contains(local)) {
    throw const Fb3FormatException(
      '不是 FB3：既不是 zip 包，根元素也不是 <fb3-body> / <FictionBook>',
    );
  }
  final bodyNode = _bodyScope(doc);
  final BookXmlNode? descNode;
  if (local == 'fictionbook') {
    descNode = doc.first('description') ?? bodyNode.first('description');
  } else if (local == 'fb3-description') {
    descNode = _scopeElement(doc, const {'fb3-description'});
  } else {
    descNode = bodyNode.first('description');
  }
  return _Fb3Package(
    zip: false,
    files: const {},
    bodyNode: bodyNode,
    bodyDocument: doc,
    bodyDir: '',
    bodyRels: _Rels.empty,
    descNode: descNode,
    descDir: '',
    descRels: _Rels.empty,
    rootRels: _Rels.empty,
  );
}

class _ContentTypes {
  const _ContentTypes(this.bodyPart, this.descPart, this.mimeByPath);
  final String? bodyPart;
  final String? descPart;

  /// 部件路径（归一化小写）→ MIME（`Override`），用于无扩展名图片的类型推断
  final Map<String, String> mimeByPath;
}

_ContentTypes _contentTypes(Map<String, Uint8List> files) {
  final data = files['[content_types].xml'];
  if (data == null) {
    return const _ContentTypes(null, null, {});
  }
  final root = parseBookXmlBytes(data);
  if (root == null) return const _ContentTypes(null, null, {});
  String? body;
  String? desc;
  final mime = <String, String>{};
  for (final o in root.descendants('override')) {
    final part = (o.attr('partname') ?? '').trim();
    final type = (o.attr('contenttype') ?? '').trim();
    if (part.isEmpty) continue;
    final path = bookResolvePart('', part);
    if (type.toLowerCase().contains('fb3-body')) body ??= path;
    if (type.toLowerCase().contains('fb3-description')) desc ??= path;
    if (type.isNotEmpty) mime[path] = type;
  }
  for (final d in root.descendants('default')) {
    final ext = (d.attr('extension') ?? '').trim().toLowerCase();
    final type = (d.attr('contenttype') ?? '').trim();
    if (ext.isEmpty || type.isEmpty) continue;
    mime.putIfAbsent('*.$ext', () => type);
  }
  return _ContentTypes(body, desc, mime);
}

/// 明确的 OPC 加密迹象 → 能力边界（**不解密**，与 ODT 同款处理）。
void _rejectEncrypted(Map<String, Uint8List> files) {
  for (final key in files.keys) {
    final base = key.split('/').last;
    if (base == 'encryption.xml' ||
        base == 'encryptedpackage' ||
        base == 'encryptioninfo') {
      throw BookUnsupportedException(
        'FB3 是加密包（OPC 加密），本阅读器不解密；请用支持 DRM 的应用打开',
        reason: BookUnsupportedReason.encrypted,
      );
    }
  }
  final ct = files['[content_types].xml'];
  if (ct != null) {
    final s = decodeBookXmlText(ct).toLowerCase();
    if (s.contains('encryptedpackage') ||
        s.contains('application/xmlenc') ||
        s.contains('encryptedcontent')) {
      throw BookUnsupportedException(
        'FB3 是加密包（OPC 加密），本阅读器不解密；请用支持 DRM 的应用打开',
        reason: BookUnsupportedReason.encrypted,
      );
    }
  }
}

BookXmlNode _parsePart(Uint8List data, String what) {
  final root = parseBookXmlBytes(data);
  if (root == null) throw Fb3FormatException('$what 解析失败');
  return root;
}

String _rootLocal(BookXmlNode doc) =>
    doc.children.isEmpty ? '' : doc.children.first.local;

/// 文档根 → 顶层元素（`fb3-body` 这种）；匹配不上就返回整个文档根。
BookXmlNode _scopeElement(BookXmlNode doc, Set<String> wanted) {
  for (final c in doc.children) {
    if (wanted.contains(c.local)) return c;
  }
  return doc;
}

/// 正文元素：`fb3-body` 文档取根元素；兼容的 `<FictionBook>` 文档取 `<body>`
/// （别把 `<description>` 的文本也当成正文）。
BookXmlNode _bodyScope(BookXmlNode doc) {
  if (_rootLocal(doc) == 'fictionbook') {
    return doc.first('body') ?? _scopeElement(doc, const {'fb3-body', 'body'});
  }
  return _scopeElement(doc, const {'fb3-body', 'body'});
}

/// `<ownerDir>/_rels/<basename>.rels`（小写）——OPC 的 relationship part 命名。
String _relsPathOf(String partPath) {
  final dir = bookDirOf(partPath);
  final base = partPath.substring(dir.length);
  return '${dir}_rels/$base.rels'.toLowerCase();
}

/// 读取某个 part 的 rels（解析成"Id → 归一化包内路径"）。
_Rels _relsFor(Map<String, Uint8List> files, String partPath) {
  final dir = bookDirOf(partPath);
  return _readRels(files, _relsPathOf(partPath), dir);
}

_Rels _readRels(
  Map<String, Uint8List> files,
  String relsPath,
  String ownerDir,
) {
  final data = files[relsPath.toLowerCase()];
  if (data == null) return _Rels.empty;
  final root = parseBookXmlBytes(data);
  if (root == null) return _Rels.empty;
  final out = <_Rel>[];
  for (final r in root.descendants('relationship')) {
    final target = (r.attr('target') ?? '').trim();
    if (target.isEmpty) continue;
    out.add(
      _Rel(
        (r.attr('id') ?? '').trim(),
        (r.attr('type') ?? '').trim(),
        bookResolvePart(ownerDir, target),
      ),
    );
  }
  return _Rels(out);
}

/// 扫描包内"可能是 XML part"的部件，返回根元素匹配的第一个。
///
/// 只在前面的发现手段都失败时调用（例如正文是根目录下一个没有扩展名、
/// 目录名还百分号转义的部件）。
String? _scanForRoot(Map<String, Uint8List> files, Set<String> wanted) {
  final keys = files.keys.toList()..sort();
  for (final k in keys) {
    if (k.contains('/_rels/')) continue;
    final base = k.split('/').last;
    final dot = base.lastIndexOf('.');
    final ext = dot < 0 ? '' : base.substring(dot + 1);
    if (ext != '' && ext != 'xml' && ext != 'fb3') continue;
    final root = parseBookXmlBytes(files[k]!);
    if (root == null) continue;
    if (wanted.contains(_rootLocal(root))) return k;
  }
  return null;
}

// ------------------------------------------------------------------ 元数据

({String title, String author, String lang}) _fb3Metadata(_Fb3Package pkg) {
  final desc = pkg.descNode ?? pkg.bodyNode;
  return (
    title: _descTitle(desc),
    author: _descAuthors(desc),
    lang: (desc.first('lang')?.text ?? '').trim(),
  );
}

String _descTitle(BookXmlNode root) {
  // FB2 兼容写法优先
  final bt = (root.first('book-title')?.text ?? '').trim();
  if (bt.isNotEmpty) return bt;
  // FB3：<title><main>书名</main></title>；sub/alt 只是副题，不进书名
  final title = root.first('title');
  if (title == null) return '';
  final main = title.first('main');
  final text = (main?.text ?? title.text).trim();
  return text;
}

/// 作者：FB3 的 `fb3-relations/subject[@link=author]`；FB2 兼容写法退回
/// `title-info/author`。`managing_editor` / `editor` 等**不算作者**。
String _descAuthors(BookXmlNode root) {
  final out = <String>[];
  for (final rel in root.descendants('fb3-relations')) {
    for (final s in rel.childrenNamed('subject')) {
      if ((s.attr('link') ?? '').toLowerCase() != 'author') continue;
      final name = _personName(s);
      if (name.isNotEmpty && !out.contains(name)) out.add(name);
    }
  }
  if (out.isEmpty) {
    final ti = root.first('title-info') ?? root;
    for (final a in ti.childrenNamed('author')) {
      final name = _personName(a);
      if (name.isNotEmpty && !out.contains(name)) out.add(name);
    }
  }
  return out.join(fsT('bookListSeparator', '、'));
}

String _personName(BookXmlNode a) {
  final parts = [
    (a.first('first-name')?.text ?? '').trim(),
    (a.first('middle-name')?.text ?? '').trim(),
    (a.first('last-name')?.text ?? '').trim(),
  ].where((s) => s.isNotEmpty);
  final joined = parts.join(' ');
  if (joined.isNotEmpty) return joined;
  final nick = (a.first('nickname')?.text ?? '').trim();
  if (nick.isNotEmpty) return nick;
  // 结构化姓名字段缺失时才退回 <title><main>
  return (a.first('main')?.text ?? '').trim();
}

// ------------------------------------------------------------------ 章节标题

/// section **自己**的标题：直接子节点里的 `<title>`，取其 `<p>` 文本拼接。
String _fb3SectionTitle(BookXmlNode section) {
  BookXmlNode? title;
  for (final c in section.children) {
    if (c.local == 'title') {
      title = c;
      break;
    }
  }
  title ??= section.first('title');
  if (title == null) return '';
  return _titleText(title);
}

/// section 是否有"自己的"内容（**直接子** `<title>`，或除子 section / 标题之外
/// 的子节点/裸文本）。
///
/// ⚠️ 只认直接子 `<title>`：`section.first('title')` 会命中**子 section** 的标题，
/// 那样只有子 section 的"包装 section"会被误判成有内容，目录里就会多出一章空的
/// "第 N 节"（marker 样本真踩过）。
bool _sectionHasOwnContent(BookXmlNode s) {
  for (final c in s.children) {
    if (c.local == 'title') {
      if (_titleText(c).isNotEmpty) return true;
      continue;
    }
    if (c.local == 'section') continue;
    return true;
  }
  for (final item in s.content) {
    if (item is String && item.trim().isNotEmpty) return true;
  }
  return false;
}

/// `<title>` → 显示文本：直接子 `<p>` 拼接，没有就整个 title 的文本。
String _titleText(BookXmlNode title) {
  final ps = title.childrenNamed('p').toList();
  if (ps.isEmpty) return title.text.trim();
  return ps.map((p) => p.text.trim()).where((s) => s.isNotEmpty).join(' ');
}

// ------------------------------------------------------------------ 图片解析

/// 正文里的图片引用 → 包内真实路径（小写归一化），解析不了返回 null。
///
/// 顺序：rels 的 `Id` → 相对正文目录的直接路径 → 相对包根的路径 →
/// base64 `<binary>` id → 全包同名/同主名图片兜底。全部落空时上层保留原始
/// 引用（渲染层会显式画"图片缺失"一行），**不会静默错位**。
class _ImageResolver {
  _ImageResolver({
    required this.files,
    required this.resources,
    required this.binaries,
    required this.bodyDir,
    required this.bodyRels,
  });

  final Map<String, Uint8List> files;
  final Map<String, Uint8List> resources;
  final Map<String, Uint8List> binaries;
  final String bodyDir;
  final _Rels bodyRels;

  String? resolve(String raw) {
    var ref = raw.trim();
    if (ref.isEmpty) return null;
    if (ref.startsWith('#')) ref = ref.substring(1);

    // 1) rels 映射：`src="img4"` → `fb3/img/_600400.jpg`
    final mapped = bodyRels.targetById(ref);
    if (mapped != null && files.containsKey(mapped)) return mapped;

    // 2) 相对正文目录 / 包根的直接路径
    final direct = bookResolvePart(bodyDir, ref);
    if (files.containsKey(direct)) return direct;
    final fromRoot = bookResolvePart('', ref);
    if (files.containsKey(fromRoot)) return fromRoot;

    // 3) base64 <binary> 的 id（旧写法）
    final lower = ref.toLowerCase();
    if (binaries.containsKey(lower)) return lower;

    // 4) 全包同名图片兜底（大小写/目录不同）
    for (final e in files.entries) {
      if (!_looksImage(e.key, e.value)) continue;
      if (e.key == lower || e.key.split('/').last == lower.split('/').last) {
        return e.key;
      }
    }

    // 5) 同主名 + 任意图片后缀（`imge91e` → `Pictures/MyPictures/imge91e.jpg`）
    final base = lower.split('/').last;
    final stem = base.contains('.')
        ? base.substring(0, base.lastIndexOf('.'))
        : base;
    for (final e in files.entries) {
      if (!_looksImage(e.key, e.value)) continue;
      final kb = e.key.split('/').last;
      final kstem = kb.contains('.')
          ? kb.substring(0, kb.lastIndexOf('.'))
          : kb;
      if (kstem == stem) return e.key;
    }
    return null;
  }

  bool _looksImage(String path, Uint8List data) =>
      bookLooksLikeImagePath(path) || bookImageKindOfBytes(data) != null;
}

// ------------------------------------------------------------------ HTML 子集

/// FB3 标签 → 我们能渲染的 HTML 子集（与 `file_book.dart` 里的 FB2 转换同构）。
///
/// ⚠️ 走的是 [BookXmlNode.content]（元素与裸文本的**有序**混合内容），不是
/// `children` —— `<p>前<emphasis>中</emphasis>后</p>` 里的"前/后"就在 content 里，
/// 只看 children 会整段丢掉（`book_xml.dart` 的文件头专门讲了这件事）。
///
/// [inline] 表示"当前已在段落/单元格等行内上下文里"：`<br/>` 在那里输出 `<br>`，
/// 在块级上下文输出一个空行;`<img>` 同理决定要不要包 `<p>`。
String _fb3Inline(
  BookXmlNode? root, {
  bool skipSections = false,
  String? Function(String)? resolveImage,
}) {
  if (root == null) return '';
  final out = StringBuffer();

  // `walkAll` 与 `walk` 互相递归，Dart 的局部函数不能向前引用 —— 用 `late`
  // 先声明、后赋值（否则 analyze 直接报 "can't be referenced before declared"）。
  late final void Function(BookXmlNode, bool) walk;

  void walkAll(List<Object> content, bool inline) {
    for (final item in content) {
      if (item is String) {
        out.write(bookEscapeHtml(item));
      } else if (item is BookXmlNode) {
        walk(item, inline);
      }
    }
  }

  void image(BookXmlNode node, bool inline) {
    final raw = (node.attr('src') ?? node.attr('href') ?? '').trim();
    if (raw.isEmpty) return;
    final resolved = resolveImage?.call(raw);
    final src = bookEscapeAttr(resolved ?? raw);
    final alt = (node.attr('alt') ?? '').trim();
    final altAttr = alt.isEmpty ? '' : ' alt="${bookEscapeAttr(alt)}"';
    final tag = '<img src="$src"$altAttr/>';
    out.write(inline ? tag : '<p>$tag</p>');
  }

  walk = (BookXmlNode node, bool inline) {
    final tag = node.local;
    switch (tag) {
      case 'section':
        // 子 section 是独立的一段（已经单独成章），正文里不再重复
        if (skipSections) return;
        out.write('<div${_idAttr(node)}>');
        walkAll(node.content, false);
        out.write('</div>');
        return;
      case 'title':
        return; // 标题由章节标题呈现
      case 'p':
        out.write('<p${_idAttr(node)}>');
        walkAll(node.content, true);
        out.write('</p>');
        return;
      case 'subtitle':
        out.write('<h3>');
        walkAll(node.content, true);
        out.write('</h3>');
        return;
      case 'emphasis':
      case 'em':
        out.write('<em>');
        walkAll(node.content, true);
        out.write('</em>');
        return;
      case 'strong':
        out.write('<strong>');
        walkAll(node.content, true);
        out.write('</strong>');
        return;
      case 'strikethrough':
        out.write('<s>');
        walkAll(node.content, true);
        out.write('</s>');
        return;
      case 'code':
        out.write('<code>');
        walkAll(node.content, true);
        out.write('</code>');
        return;
      case 'sup':
        out.write('<sup>');
        walkAll(node.content, true);
        out.write('</sup>');
        return;
      case 'sub':
        out.write('<sub>');
        walkAll(node.content, true);
        out.write('</sub>');
        return;
      case 'br':
        out.write(inline ? '<br>' : '<p><br></p>');
        return;
      case 'empty-line':
        out.write('<p><br></p>');
        return;
      case 'image':
      case 'img':
        image(node, inline);
        return;
      case 'a':
        final href = (node.attr('href') ?? '').trim();
        if (href.isEmpty) {
          walkAll(node.content, true);
          return;
        }
        out.write('<a href="${bookEscapeAttr(href)}">');
        walkAll(node.content, true);
        out.write('</a>');
        return;
      case 'cite':
      case 'epigraph':
      case 'annotation':
      case 'subscription':
        out.write('<blockquote>');
        walkAll(node.content, false);
        out.write('</blockquote>');
        return;
      case 'table':
        out.write('<table>');
        // 表格自己的 <title> 不能丢：做成第一行表头单元格（渲染管线把表拍平成
        // "一行一格"，caption 不在白名单里会被净化掉）
        final t = node.child('title');
        if (t != null) {
          out.write('<tr><td>');
          walkAll(t.content, true);
          out.write('</td></tr>');
        }
        walkAll(node.content, false);
        out.write('</table>');
        return;
      case 'tr':
        out.write('<tr>');
        walkAll(node.content, false);
        out.write('</tr>');
        return;
      case 'td':
      case 'th':
        final span = _spanAttrs(node);
        out.write('<$tag$span>');
        walkAll(node.content, true);
        out.write('</$tag>');
        return;
      case 'poem':
      case 'stanza':
      case 'v':
      case 'date':
      case 'style':
      case 'link':
      case 'div':
      case 'marker':
      case 'notes':
      case 'notebody':
        walkAll(node.content, inline);
        return;
      default:
        // 未知标签：保留里面的文字内容，不保留标签（宁可少样式，不丢正文）
        walkAll(node.content, inline);
    }
  };

  walkAll(root.content, false);
  return out.toString();
}

String _idAttr(BookXmlNode n) {
  final id = (n.attr('id') ?? '').trim();
  return id.isEmpty ? '' : ' id="${bookEscapeAttr(id)}"';
}

String _spanAttrs(BookXmlNode n) {
  final out = StringBuffer();
  for (final a in const ['colspan', 'rowspan']) {
    final v = (n.attr(a) ?? '').trim();
    if (v.isNotEmpty) out.write(' $a="${bookEscapeAttr(v)}"');
  }
  return out.toString();
}

/// 从一段 HTML 里取所有 `id="…"`（锚点落点）
List<String> _idsInHtml(String html) {
  final out = <String>[];
  for (final m in RegExp(r'id="([^"]+)"').allMatches(html)) {
    out.add(m.group(1)!);
  }
  return out;
}

// ------------------------------------------------------------------ 封面

/// 从 FB3 里抠封面：优先根 `_rels/.rels` 的 `…/thumbnail` 关系（真实 FB3 的
/// 标准位置），其次描述 part 的 `<cover>`/`<thumbnail>`，最后兼容旧写法
/// `<cover><image href="…"/></cover>`。拿不到 → null（不抛）。
Uint8List? fb3CoverBytes(List<int> bytes) {
  try {
    final pkg = _openFb3(bytes);

    // 1) 根 rels thumbnail（nightmare 的 fb3/img/cover1.png、hardcore 的 svg）
    final rootThumb = pkg.rootRels.targetByType('/thumbnail');
    if (rootThumb != null) {
      final data = pkg.files[rootThumb];
      if (data != null) return data;
    }
    // 2) 描述 part 的 rels thumbnail
    final descThumb = pkg.descRels.targetByType('/thumbnail');
    if (descThumb != null) {
      final data = pkg.files[descThumb];
      if (data != null) return data;
    }
    // 3) 描述/正文里的 <cover>/<thumbnail> 元素 → 图片引用
    final resolver = _ImageResolver(
      files: pkg.files,
      resources: const {},
      binaries: const {},
      bodyDir: pkg.bodyDir,
      bodyRels: pkg.bodyRels,
    );
    for (final scope in [pkg.descNode, pkg.bodyNode]) {
      if (scope == null) continue;
      final cover = scope.first('cover') ?? scope.first('thumbnail');
      if (cover == null) continue;
      final img = cover.first('image') ?? cover.first('img');
      final href =
          (img?.attr('href') ?? img?.attr('src') ?? cover.attr('href') ?? '')
              .trim();
      if (href.isEmpty) continue;
      final path = resolver.resolve(href);
      final data = path == null ? null : pkg.files[path];
      if (data != null) return data;
    }
    return null;
  } catch (_) {
    // 与 book_cover.dart 的契约一致：抠不到封面不是错误，列表退回分类图标
    return null;
  }
}

// ------------------------------------------------------------------ 探针

/// 给探针用：FB3 结构摘要（不落 [BookContent]）。
///
/// `lang` 只在这里给出：`BookContent` 没有语言字段，界面暂不需要，但研究/证据
/// 表要能看到真实 description 里的 `<lang>`。
Map<String, Object?> fb3Probe(List<int> bytes) {
  try {
    final pkg = _openFb3(bytes);
    final meta = _fb3Metadata(pkg);
    final sections = pkg.bodyNode.descendants('section').toList();
    return {
      'ok': true,
      'zip': pkg.zip,
      'fictionbook': true,
      'sections': sections.where(_sectionHasOwnContent).length,
      'sections_all': sections.length,
      'tables': pkg.bodyNode.descendants('table').length,
      'images': pkg.zip ? bookImageParts(pkg.files).length : 0,
      'title': meta.title,
      'author': meta.author,
      'lang': meta.lang,
      'cover': fb3CoverBytes(bytes) != null,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}
