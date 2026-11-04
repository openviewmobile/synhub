// XPS / OXPS（Open XML Paper Specification / OpenXPS）解析层 —— **纯 Dart**，
// 不 import flutter / l10n。
//
// 格式本质（ECMA-388 / OpenXPS）：**OPC 包**（就是 zip）+ 一串 XML part，
// 版式是"固定页面"而不是流式文本：
//
//   `[Content_Types].xml`
//     └─ Override → `/FixedDocSeq.fdseq`（FixedDocumentSequence）
//          └─ `<DocumentReference Source="/Documents/1/FixedDoc.fdoc"/>`（ECMA-388
//             真实写法；早期自造 fixture 写的 `<FixedDocumentReference>` 也兼容）
//               └─ `<PageContent Source="Pages/1.fpage"/>`（FixedPage，**每页一个 part**）
//
// 页面内容用**固定坐标**画：`<Glyphs>`（一段已经排好版、带 OriginX/OriginY 的
// 字形串）、`<Path>`（矢量）、`<ImageBrush ImageSource="…">`（位图）。
//
// **自研的简化策略**（明确取舍，宁可少画也不吐乱码）：
//   * `<Glyphs>` → 按 `OriginY` 聚成行、行内按 `OriginX` 排序，取 `UnicodeString`
//     拼成段落 —— 于是正文**可搜索、可选中、可朗读**，跟 EPUB 同一套阅读器；
//   * `<ImageBrush>` → 解析出包里的图片 part，落到 `resources`，渲染成 `<img>`；
//   * `<Path>`（复杂矢量）→ **不渲染**，页尾给一条明确提示（"本页含 N 个矢量
//     图形，未渲染"），而不是假装画对了；
//   * 导航按 FixedPage 顺序，一页一段。
//
// 本项目的"能力边界"用 [BookUnsupportedException] 表达（带权限管理/加密的 XPS），
// 由 `file_book.dart` 统一翻成 `BookParseErrorKind.unsupportedCompression`。
import 'dart:typed_data';

import 'book_package.dart';
import 'book_xml.dart';
import 'file_book.dart';
import 'files_i18n.dart';

/// `.xps` / `.oxps` → [BookContent]。
///
/// 解析失败抛 [FormatException]（文件坏了）；加密/权限管理抛
/// [BookUnsupportedException]（能力边界）。
BookContent parseXpsBook(List<int> bytes, {required BookFormat format}) {
  final files = unzipBookPackage(bytes, format.label);

  // 加密/权限管理（RMS/IRM）的 XPS 会是一个只装了加密载荷的 OPC 包 ——
  // 明确报"不支持"，绝不解压出一堆二进制当正文。
  if (files.containsKey('encryptedpackage') ||
      files.containsKey('encryptioninfo') ||
      files.containsKey('drmcontent')) {
    throw BookUnsupportedException(
      '这本 XPS 带加密/权限管理（IRM），本阅读器不解密',
      reason: BookUnsupportedReason.encrypted,
    );
  }
  if (!files.containsKey('[content_types].xml')) {
    throw const FormatException('XPS 里没有 [Content_Types].xml（不是有效的 OPC 包）');
  }

  final sequencePath = _findSequencePart(files);
  if (sequencePath == null) {
    throw const FormatException('XPS 里没有 FixedDocumentSequence（不是固定版式文档）');
  }

  final pageParts = _fixedPageParts(files, sequencePath);
  if (pageParts.isEmpty) {
    throw const FormatException('XPS 里没有 FixedPage（没有可渲染的页面）');
  }

  final images = bookImageParts(files);
  final resources = <String, Uint8List>{};
  final chapters = <BookChapter>[];
  for (var i = 0; i < pageParts.length; i++) {
    final part = pageParts[i];
    final raw = files[part];
    if (raw == null) continue;
    final page = _renderFixedPage(
      raw,
      part: part,
      files: files,
      images: images,
      resources: resources,
    );
    // 第一行文字当页标题（固定版式页通常有页眉/标题）；没有就给"第 N 页"，
    // 由界面的 `bookPageN` 按当前语言重写（解析层是纯 Dart，不能 i18n）。
    final heading = page.heading;
    chapters.add(
      BookChapter(
        title: heading ?? '${i + 1}',
        generatedUnit: heading == null ? BookGeneratedUnit.page : null,
        html: page.html,
        href: part,
      ),
    );
  }
  if (chapters.isEmpty) {
    throw const FormatException('XPS 的页面都读不出来');
  }

  final meta = _xpsMetadata(files);
  return BookContent(
    format: format,
    title: meta.title,
    author: meta.author,
    chapters: chapters,
    toc: [
      for (var i = 0; i < chapters.length; i++)
        BookTocEntry(title: chapters[i].title, chapterIndex: i),
    ],
    resources: resources,
  );
}

/// FixedDocumentSequence 的 part 路径（小写归一化）。
///
/// 优先按 `[Content_Types].xml` 里的 ContentType 找（权威），找不到再按
/// `.fdseq` / `.fdoc` 后缀兜底 —— 现实里有 XPS 省掉了 Override 声明。
String? _findSequencePart(Map<String, Uint8List> files) {
  final types = files['[content_types].xml'];
  if (types != null) {
    final root = parseBookXmlBytes(types);
    if (root != null) {
      for (final o in root.descendants('override')) {
        final part = o.attr('partname') ?? '';
        final type = (o.attr('contenttype') ?? '').toLowerCase();
        if (part.isEmpty) continue;
        if (type.contains('fixeddocumentsequence')) {
          final resolved = bookResolvePart('', part);
          if (files.containsKey(resolved)) return resolved;
        }
      }
    }
  }
  for (final k in files.keys) {
    if (k.endsWith('.fdseq')) return k;
  }
  // 没有 sequence 的包极少，但有些导出器直接给 .fdoc：那就当 sequence 用。
  for (final k in files.keys) {
    if (k.endsWith('.fdoc')) return k;
  }
  return null;
}

/// 按 FixedDocumentSequence → FixedDocument → FixedPage 顺序展开页面 part。
List<String> _fixedPageParts(
  Map<String, Uint8List> files,
  String sequencePath,
) {
  final out = <String>[];
  final root = files[sequencePath] == null
      ? null
      : parseBookXmlBytes(files[sequencePath]!);
  if (root == null) return out;

  final rootLocal = _firstElementLocal(root);
  final docs = <String>[];
  if (rootLocal == 'fixeddocument') {
    // 兜底：拿到的其实是 FixedDocument
    docs.add(sequencePath);
  } else {
    // 真实的 FixedDocumentSequence（ECMA-388）用 `<DocumentReference Source=…>`；
    // `<FixedDocumentReference>` 只是早期自造 fixture 里的写法，两个都认。
    final refs = <BookXmlNode>[];
    void collectRefs(BookXmlNode n) {
      for (final c in n.children) {
        if (c.local == 'documentreference' ||
            c.local == 'fixeddocumentreference') {
          refs.add(c);
        }
        collectRefs(c);
      }
    }

    collectRefs(root);
    for (final ref in refs) {
      final src = ref.attr('source') ?? '';
      if (src.isEmpty) continue;
      final resolved = bookResolvePart(bookDirOf(sequencePath), src);
      if (files.containsKey(resolved)) docs.add(resolved);
    }
  }
  for (final doc in docs) {
    final docRoot = parseBookXmlBytes(files[doc]!);
    if (docRoot == null) continue;
    for (final pc in docRoot.descendants('pagecontent')) {
      final src = pc.attr('source') ?? '';
      if (src.isEmpty) continue;
      final resolved = bookResolvePart(bookDirOf(doc), src);
      if (files.containsKey(resolved)) out.add(resolved);
    }
  }
  return out;
}

/// 一个 FixedPage 渲染出来的正文 + 标题
typedef _RenderedPage = ({String html, String? heading});

/// FixedPage XML → 阅读器能渲染的 HTML 片段。
_RenderedPage _renderFixedPage(
  Uint8List raw, {
  required String part,
  required Map<String, Uint8List> files,
  required Map<String, Uint8List> images,
  required Map<String, Uint8List> resources,
}) {
  final root = parseBookXmlBytes(raw);
  if (root == null) return (html: '', heading: null);
  final page = root.descendants('fixedpage').firstOrNull ?? root;
  final baseDir = bookDirOf(part);

  final glyphs = <_Glyph>[];
  final brushes = <String>[];
  var vectorCount = 0;
  void walk(BookXmlNode n) {
    for (final c in n.children) {
      switch (c.local) {
        case 'glyphs':
          final g = _Glyph.fromNode(c);
          if (g != null) glyphs.add(g);
        case 'path':
          vectorCount++;
        case 'imagebrush':
          final src = c.attr('imagesource') ?? '';
          if (src.isNotEmpty) brushes.add(src);
        default:
          break;
      }
      walk(c);
    }
  }

  walk(page);

  // 行聚合：同一行（OriginY 接近）的字形串按 OriginX 拼接。
  glyphs.sort((a, b) {
    final dy = a.y.compareTo(b.y);
    return dy != 0 ? dy : a.x.compareTo(b.x);
  });
  final lines = <_Line>[];
  for (final g in glyphs) {
    final tol = g.size > 1 ? g.size * 0.6 : 1.5;
    if (lines.isNotEmpty && (g.y - lines.last.y).abs() <= tol) {
      lines.last.add(g);
    } else {
      lines.add(_Line(g.y)..add(g));
    }
  }

  final parts = <String>[];
  String? heading;
  for (final line in lines) {
    final text = line.text;
    if (text.trim().isEmpty) continue;
    if (heading == null) {
      final t = text.trim();
      heading = t.length > 60 ? t.substring(0, 60) : t;
    }
    parts.add('<p>${bookEscapeHtml(text)}</p>');
  }

  // 位图：ImageSource 相对**页面 part** 解析；解析不到就按后缀/字节 magic 兜底。
  for (final src in brushes) {
    final name = _resolveImage(src, baseDir, files, images, resources);
    if (name == null) continue;
    parts.add('<p><img src="${bookEscapeAttr(name)}" alt=""/></p>');
  }

  if (vectorCount > 0) {
    // 复杂矢量明确"没渲染"，不假装画对了（XPS 的 Path 可以是任意几何图元）
    parts.add(
      '<p><em>${fsTFill('bookXpsVectorUnrendered', '（本页含 $vectorCount 个矢量图形，未渲染）', {
        'count': '$vectorCount',
      })}</em></p>',
    );
  }
  if (parts.isEmpty) {
    parts.add(
      '<p><em>${fsT('bookXpsNoContent', '（本页没有可提取的文字或位图）')}</em></p>',
    );
  }
  return (html: parts.join(), heading: heading);
}

/// ImageSource → 落在 [resources] 里的资源名；解析不到返回 null。
String? _resolveImage(
  String src,
  String baseDir,
  Map<String, Uint8List> files,
  Map<String, Uint8List> images,
  Map<String, Uint8List> resources,
) {
  final resolved = bookResolvePart(baseDir, src);
  final data = files[resolved] ?? images[resolved];
  if (data != null) {
    resources[resolved] = data;
    return resolved;
  }
  // 有些 XPS 的 ImageSource 大小写/路径写法与 zip 项不完全一致：按文件名再找一次。
  final tail = resolved.split('/').last;
  for (final e in images.entries) {
    if (e.key.split('/').last == tail) {
      resources[e.key] = e.value;
      return e.key;
    }
  }
  return null;
}

/// `<Glyphs>` 需要的最小信息
class _Glyph {
  _Glyph(this.x, this.y, this.size, this.text);

  final double x;
  final double y;
  final double size;
  final String text;

  static _Glyph? fromNode(BookXmlNode n) {
    final text = n.attr('unicodestring');
    if (text == null || text.isEmpty) return null;
    // `\u0000` 之类控制字符直接丢掉，别让正文里混进不可见字符
    final clean = text.replaceAll(
      RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f]'),
      '',
    );
    if (clean.isEmpty) return null;
    return _Glyph(
      double.tryParse(n.attr('originx') ?? '') ?? 0,
      double.tryParse(n.attr('originy') ?? '') ?? 0,
      double.tryParse(n.attr('fontrenderingemsize') ?? '') ?? 0,
      clean,
    );
  }
}

class _Line {
  _Line(this.y);
  final double y;
  final List<_Glyph> items = [];

  void add(_Glyph g) => items.add(g);

  String get text {
    items.sort((a, b) => a.x.compareTo(b.x));
    return items.map((g) => g.text).join();
  }
}

({String title, String author}) _xpsMetadata(Map<String, Uint8List> files) {
  final core = files['docprops/core.xml'];
  if (core == null) return (title: '', author: '');
  final root = parseBookXmlBytes(core);
  if (root == null) return (title: '', author: '');
  return (
    title: root.first('title')?.text.trim() ?? '',
    author: root.first('creator')?.text.trim() ?? '',
  );
}

/// 第一个元素的本地标签名（判断 sequence part 里到底是 sequence 还是 document）
String _firstElementLocal(BookXmlNode root) {
  for (final c in root.children) {
    return c.local;
  }
  return '';
}

/// 从 XPS 里抠封面：第一页引用的第一张图；没有就退到包里的第一张图（按路径序）。
Uint8List? xpsCoverBytes(Uint8List bytes) {
  try {
    final files = unzipBookPackage(bytes, 'XPS');
    final sequencePath = _findSequencePart(files);
    if (sequencePath == null) return null;
    final images = bookImageParts(files);
    if (images.isEmpty) return null;
    for (final part in _fixedPageParts(files, sequencePath)) {
      final raw = files[part];
      if (raw == null) continue;
      final root = parseBookXmlBytes(raw);
      if (root == null) continue;
      for (final n in root.descendants('imagebrush')) {
        final src = n.attr('imagesource') ?? '';
        if (src.isEmpty) continue;
        final resolved = bookResolvePart(bookDirOf(part), src);
        final data = files[resolved] ?? images[resolved];
        if (data != null) return data;
        final tail = resolved.split('/').last;
        for (final e in images.entries) {
          if (e.key.split('/').last == tail) return e.value;
        }
      }
    }
    final keys = images.keys.toList()..sort();
    return images[keys.first];
  } catch (_) {
    return null;
  }
}

/// 给探针用：XPS/OXPS 包的结构摘要（不落 [BookContent]）
Map<String, Object?> xpsProbe(List<int> bytes) {
  try {
    final files = unzipBookPackage(bytes, 'XPS');
    final seq = _findSequencePart(files);
    final pages = seq == null ? const <String>[] : _fixedPageParts(files, seq);
    final glyphCount = pages.fold<int>(0, (a, p) {
      final raw = files[p];
      if (raw == null) return a;
      final root = parseBookXmlBytes(raw);
      if (root == null) return a;
      return a + root.descendants('glyphs').length;
    });
    return {
      'ok': true,
      'parts': files.length,
      'hasContentTypes': files.containsKey('[content_types].xml'),
      'sequence': seq,
      'pages': pages.length,
      'images': bookImageParts(files).length,
      'glyphs': glyphCount,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}
