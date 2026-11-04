// DOCX / ODT / OPF → BookContent —— **纯 Dart**，不 import flutter / l10n。
//
// 三种格式都是"容器 + 一份结构化正文"：
//
//   * **DOCX**：zip 容器。正文在 `word/document.xml`（`w:p` 段落、`w:pStyle`
//     标题样式、`w:r` 里的 `w:b`/`w:i`、`w:tbl` 表格），图片在 `word/media/*`，
//     关系映射在 `word/_rels/document.xml.rels`（`r:embed="rIdN"` → 图片路径）。
//   * **ODT**：zip 容器。正文在 `content.xml`（`text:p`/`text:h`/`text:span`/
//     `text:a`），图片在 `Pictures/*`（`draw:image xlink:href`）；
//     `META-INF/manifest.xml` 里出现 `encryption-data` 就是**加密文档**，
//     明确报错、不解密。
//   * **OPF**：散装 EPUB 的包文件。manifest/spine 解析出来之后，正文是**旁边**
//     的 XHTML 文件 —— 解析层只收到一个文件的字节，所以需要调用方把兄弟文件
//     一起给（`siblings`）；给不出来时**明确报错**，不假装能读。
//
// **明确不做**：DOCX 的域代码/修订记录、ODT 的嵌入对象等。宁可少读一点，
// 也不输出乱码。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'book_text.dart';
import '../../core/i18n/data_text.dart';
import 'book_xml.dart';
import 'file_book.dart';
import 'files_i18n.dart';

// ------------------------------------------------------------------ DOCX

/// `.docx`：zip → `word/document.xml` → 段落/标题/粗斜体/表格 + 图片
BookContent parseDocxBook(List<int> bytes, {required BookFormat format}) {
  final files = _unzip(bytes, 'DOCX');
  final doc = files['word/document.xml'];
  if (doc == null) {
    throw const FormatException('DOCX 里没有 word/document.xml（不是有效的 DOCX）');
  }
  final rels = _docxRels(files['word/_rels/document.xml.rels']);
  final root = parseBookXmlBytes(doc);
  if (root == null) throw const FormatException('DOCX 的 document.xml 解析失败');

  // 图片资源：word/media/*
  final resources = <String, Uint8List>{};
  files.forEach((path, data) {
    if (path.startsWith('word/media/') && _looksLikeImage(path)) {
      resources[path] = data;
    }
  });

  final blocks = <BookBlock>[];
  final body = root.first('body') ?? root;
  for (final child in body.children) {
    switch (child.local) {
      case 'p':
        final block = _docxParagraph(child, rels, resources);
        if (block != null) blocks.add(block);
      case 'tbl':
        final block = _docxTable(child, rels, resources);
        if (block != null) blocks.add(block);
      case 'sdt':
        // 结构化文档标签（封面/目录容器）：把里面的段落抽出来
        for (final p
            in child
                .childrenNamed('sdtcontent')
                .expand((c) => c.childrenNamed('p'))) {
          final block = _docxParagraph(p, rels, resources);
          if (block != null) blocks.add(block);
        }
      default:
        break;
    }
  }
  // `sdt` 的 descendants 会把嵌套的子段落也算进来，去重最稳妥的办法是重建；
  // 这里的重复只会让同一段出现两次，代价大于收益，所以只在没有正文时用它。
  if (blocks.isEmpty) {
    for (final p in root.descendants('p')) {
      final block = _docxParagraph(p, rels, resources);
      if (block != null) blocks.add(block);
    }
  }

  final split = bookChapterize(blocks, format: format);
  final rawTitle = _docxTitle(blocks, files);
  return BookContent(
    format: format,
    title: rawTitle,
    chapters: split.chapters,
    toc: split.toc,
    resources: resources,
  );
}

String _docxTitle(List<BookBlock> blocks, Map<String, Uint8List> files) {
  for (final b in blocks) {
    if (b.title != null && b.title!.isNotEmpty) return b.title!;
  }
  // docProps/core.xml 里的 <dc:title>
  final core = files['docprops/core.xml'];
  if (core != null) {
    final t = parseBookXmlBytes(core)?.first('title')?.text.trim() ?? '';
    if (t.isNotEmpty) return t;
  }
  return '';
}

/// `rIdN` → 归一化目标路径（相对 `word/`）
Map<String, String> _docxRels(Uint8List? relsBytes) {
  final out = <String, String>{};
  if (relsBytes == null) return out;
  final root = parseBookXmlBytes(relsBytes);
  if (root == null) return out;
  for (final rel in root.descendants('relationship')) {
    final id = rel.attr('id') ?? '';
    final target = rel.attr('target') ?? '';
    if (id.isEmpty || target.isEmpty) continue;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:').hasMatch(target)) {
      out[id] = target; // 外链原样保留
      continue;
    }
    out[id] = normalizeBookPath(
      target.startsWith('/') ? target : 'word/$target',
    ).toLowerCase();
  }
  return out;
}

/// 标题样式名 → 级别（1..6），不是标题返回 null
int? _headingLevel(String? style) {
  if (style == null || style.isEmpty) return null;
  final s = style.trim().toLowerCase().replaceAll('_', ' ');
  if (s == 'title' || s == '标题') return 1;
  if (s == 'subtitle') return 2;
  final m = RegExp(r'heading\s*([1-9])').firstMatch(s);
  if (m != null) return int.parse(m.group(1)!).clamp(1, 6);
  final m2 = RegExp(r'^(?:h|标题)\s*([1-9])$').firstMatch(s);
  if (m2 != null) return int.parse(m2.group(1)!).clamp(1, 6);
  return null;
}

BookBlock? _docxParagraph(
  BookXmlNode p,
  Map<String, String> rels,
  Map<String, Uint8List> resources,
) {
  final style = p.first('ppr')?.first('pstyle')?.attr('val');
  final level = _headingLevel(style);
  final buf = StringBuffer();
  for (final node in p.children) {
    _docxInline(node, rels, resources, buf);
  }
  final html = buf.toString().trim();
  final hasImage = html.contains('<img');
  if (html.isEmpty && !hasImage) return null;
  final text = html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  final isHeading =
      level != null && level <= 2 && text.isNotEmpty && text.length <= 4096;
  if (isHeading) {
    return BookBlock(
      '<h2>${_escapeText(text)}</h2>',
      title: text,
      heading: true,
    );
  }
  return BookBlock('<p>$html</p>');
}

void _docxInline(
  BookXmlNode node,
  Map<String, String> rels,
  Map<String, Uint8List> resources,
  StringBuffer out,
) {
  switch (node.local) {
    case 'r':
      final rPr = node.child('rpr');
      final bold =
          rPr?.child('b') != null &&
          (rPr!.child('b')!.attr('val') ?? '1') != '0';
      final italic =
          rPr?.child('i') != null &&
          (rPr!.child('i')!.attr('val') ?? '1') != '0';
      final buf = StringBuffer();
      for (final item in node.content) {
        if (item is String) {
          buf.write(_escapeText(item));
        } else {
          _docxInline(item as BookXmlNode, rels, resources, buf);
        }
      }
      var inner = buf.toString();
      if (inner.isEmpty) return;
      if (bold) inner = '<strong>$inner</strong>';
      if (italic) inner = '<em>$inner</em>';
      out.write(inner);
      return;
    case 't':
      out.write(_escapeText(node.text));
      return;
    case 'tab':
      out.write('    ');
      return;
    case 'br':
    case 'cr':
      out.write('<br>');
      return;
    case 'noBreakHyphen':
      out.write('-');
      return;
    case 'blip':
      // `<a:blip r:embed="rIdN">`：图片
      final embed = node.attr('embed');
      final name = embed == null ? null : _resourceFor(embed, rels, resources);
      if (name != null) out.write('<img src="$name" alt=""/>');
      return;
    case 'imagedata':
      // VML 老式图片：`<v:imagedata r:id="rIdN">`
      final id = node.attr('id');
      final name = id == null ? null : _resourceFor(id, rels, resources);
      if (name != null) out.write('<img src="$name" alt=""/>');
      return;
    case 'hyperlink':
      final id = node.attr('id');
      final anchor = node.attr('anchor');
      final href = id != null
          ? (rels[id] ?? '')
          : (anchor == null ? '' : '#$anchor');
      final buf = StringBuffer();
      _docxInlineChildren(node, rels, resources, buf);
      final inner = buf.toString();
      if (inner.isEmpty) return;
      out.write(
        href.isEmpty ? inner : '<a href="${_escapeAttr(href)}">$inner</a>',
      );
      return;
    default:
      _docxInlineChildren(node, rels, resources, out);
  }
}

/// 按**文档顺序**走一遍子内容（文本 + 元素）
void _docxInlineChildren(
  BookXmlNode node,
  Map<String, String> rels,
  Map<String, Uint8List> resources,
  StringBuffer out,
) {
  for (final item in node.content) {
    if (item is String) {
      out.write(_escapeText(item));
    } else {
      _docxInline(item as BookXmlNode, rels, resources, out);
    }
  }
}

String? _resourceFor(
  String rId,
  Map<String, String> rels,
  Map<String, Uint8List> resources,
) {
  final path = rels[rId];
  if (path == null) return null;
  return resources.containsKey(path) ? path : null;
}

BookBlock? _docxTable(
  BookXmlNode tbl,
  Map<String, String> rels,
  Map<String, Uint8List> resources,
) {
  final rows = StringBuffer();
  for (final tr in tbl.childrenNamed('tr')) {
    final cells = StringBuffer();
    for (final tc in tr.childrenNamed('tc')) {
      final cell = StringBuffer();
      for (final p in tc.childrenNamed('p')) {
        for (final node in p.children) {
          _docxInline(node, rels, resources, cell);
        }
        cell.write(' ');
      }
      cells.write('<td>${cell.toString().trim()}</td>');
    }
    rows.write('<tr>$cells</tr>');
  }
  if (rows.isEmpty) return null;
  return BookBlock('<table>$rows</table>');
}

// ------------------------------------------------------------------ ODT

/// `.odt`：zip → `content.xml` + `styles.xml`，加密（manifest 标记）明确报错
BookContent parseOdtBook(List<int> bytes, {required BookFormat format}) {
  final files = _unzip(bytes, 'ODT');

  // 1) 加密检测：manifest 里有 encryption-data 就是加密文档
  final manifest = files['meta-inf/manifest.xml'];
  if (manifest != null) {
    final root = parseBookXmlBytes(manifest);
    if (root != null && root.first('encryption-data') != null) {
      throw BookUnsupportedException(
        '这个是加密的 ODT（manifest.xml 里标了 encryption-data），本阅读器不解密',
      );
    }
  }

  final content = files['content.xml'];
  if (content == null) {
    throw const FormatException('ODT 里没有 content.xml（不是有效的 ODT）');
  }
  final styles = _odtStyles(files['styles.xml']);
  final root = parseBookXmlBytes(content);
  if (root == null) throw const FormatException('ODT 的 content.xml 解析失败');

  // 图片资源：Pictures/*（相对 content.xml 同目录）
  final resources = <String, Uint8List>{};
  files.forEach((path, data) {
    if (_looksLikeImage(path)) resources[path] = data;
  });

  final blocks = <BookBlock>[];
  final body = root.first('body') ?? root;
  final officeText = body.first('text') ?? body;
  _odtBlocks(officeText, styles, resources, blocks);

  final split = bookChapterize(blocks, format: format);
  final title = _odtTitle(blocks, root);
  return BookContent(
    format: format,
    title: title,
    chapters: split.chapters,
    toc: split.toc,
    resources: resources,
  );
}

String _odtTitle(List<BookBlock> blocks, BookXmlNode root) {
  for (final b in blocks) {
    if (b.title != null && b.title!.isNotEmpty) return b.title!;
  }
  final t = root.first('title')?.text.trim() ?? '';
  return t;
}

/// `styles.xml`：样式名 → （outline level，bold，italic）
Map<String, ({int? level, bool bold, bool italic})> _odtStyles(
  Uint8List? bytes,
) {
  final out = <String, ({int? level, bool bold, bool italic})>{};
  if (bytes == null) return out;
  final root = parseBookXmlBytes(bytes);
  if (root == null) return out;
  for (final style in root.descendants('style')) {
    final name = style.attr('name') ?? '';
    if (name.isEmpty) continue;
    // 段落样式（标题层级）与文本样式（粗斜体）都要留；其它家族（表格/列表）跳过
    final family = style.attr('family') ?? '';
    if (family.isNotEmpty && family != 'paragraph' && family != 'text') {
      continue;
    }
    final levelText = style.first('outline-level')?.text.trim() ?? '';
    final level = int.tryParse(levelText);
    final props = style.first('text-properties');
    final weight = props?.attr('font-weight') ?? '';
    final fontStyle = props?.attr('font-style') ?? '';
    out[name] = (
      level: level,
      bold: weight == 'bold',
      italic: fontStyle == 'italic',
    );
  }
  return out;
}

void _odtBlocks(
  BookXmlNode node,
  Map<String, ({int? level, bool bold, bool italic})> styles,
  Map<String, Uint8List> resources,
  List<BookBlock> blocks,
) {
  for (final child in node.children) {
    switch (child.local) {
      case 'h':
        final level = int.tryParse(child.attr('outline-level') ?? '') ?? 1;
        final text = _odtInline(child, styles, resources).trim();
        if (text.isEmpty) continue;
        if (level <= 2 && _plain(text).length <= 4096) {
          blocks.add(
            BookBlock(
              '<h2>${_plain(text)}</h2>',
              title: _plain(text),
              heading: true,
            ),
          );
        } else {
          blocks.add(BookBlock('<p>$text</p>'));
        }
      case 'p':
        final styleName = child.attr('style-name');
        final style = styles[styleName];
        final html = _odtInline(child, styles, resources).trim();
        if (html.isEmpty) continue;
        final plain = _plain(html);
        if (style?.level != null &&
            style!.level! <= 2 &&
            plain.isNotEmpty &&
            plain.length <= 4096) {
          blocks.add(
            BookBlock(
              '<h2>${_escapeText(plain)}</h2>',
              title: plain,
              heading: true,
            ),
          );
        } else {
          blocks.add(BookBlock('<p>$html</p>'));
        }
      case 'list':
        for (final item in child.descendants('list-item')) {
          _odtBlocks(item, styles, resources, blocks);
        }
      case 'table':
        final rows = StringBuffer();
        for (final tr in child.descendants('table-row')) {
          final cells = StringBuffer();
          for (final tc in tr.childrenNamed('table-cell')) {
            final buf = StringBuffer();
            for (final p in tc.descendants('p')) {
              buf.write(_odtInline(p, styles, resources));
              buf.write(' ');
            }
            cells.write('<td>${buf.toString().trim()}</td>');
          }
          rows.write('<tr>$cells</tr>');
        }
        if (rows.isNotEmpty) blocks.add(BookBlock('<table>$rows</table>'));
      case 'frame':
        // 图片基本都包在 `draw:frame` 里：把它的图单独成段，别丢
        final href = normalizeBookPath(
          child.first('image')?.attr('href') ?? '',
        ).toLowerCase();
        if (href.isNotEmpty && resources.containsKey(href)) {
          blocks.add(BookBlock('<p><img src="$href" alt=""/></p>'));
        }
        for (final p in child.descendants('p')) {
          final html = _odtInline(p, styles, resources).trim();
          if (html.isNotEmpty) blocks.add(BookBlock('<p>$html</p>'));
        }
      default:
        // 其它容器（section/…）继续往里找段落
        if (child.children.isNotEmpty) {
          _odtBlocks(child, styles, resources, blocks);
        }
    }
  }
}

/// ODT 内联：span/a/s/image/text:s/text:tab/text:line-break
String _odtInline(
  BookXmlNode node,
  Map<String, ({int? level, bool bold, bool italic})> styles,
  Map<String, Uint8List> resources,
) {
  final buf = StringBuffer();
  for (final item in node.content) {
    if (item is String) {
      buf.write(_escapeText(item));
      continue;
    }
    final child = item as BookXmlNode;
    switch (child.local) {
      case 'span':
        final style = styles[child.attr('style-name')];
        var inner = _odtInline(child, styles, resources);
        if (inner.isEmpty) continue;
        if (style?.bold ?? false) inner = '<strong>$inner</strong>';
        if (style?.italic ?? false) inner = '<em>$inner</em>';
        buf.write(inner);
      case 'a':
        final href = child.attr('href') ?? '';
        final inner = _odtInline(child, styles, resources);
        if (inner.isEmpty) continue;
        buf.write(
          href.isEmpty ? inner : '<a href="${_escapeAttr(href)}">$inner</a>',
        );
      case 's':
        final n = int.tryParse(child.attr('c') ?? '') ?? 1;
        buf.write(' ' * n.clamp(1, 64));
      case 'tab':
        buf.write('    ');
      case 'line-break':
        buf.write('<br>');
      case 'image':
        final href = normalizeBookPath(child.attr('href') ?? '').toLowerCase();
        if (href.isNotEmpty && resources.containsKey(href)) {
          buf.write('<img src="$href" alt=""/>');
        }
      case 'note':
        // 脚注/尾注：把正文抽出来接在后面（不做"点击跳转"——散装格式没有锚点约定）
        final inner = _odtInline(child, styles, resources);
        if (inner.isNotEmpty) {
          buf.write(fsTFill('bookFootnoteWrap', '（$inner）', {'inner': inner}));
        }
      default:
        // 其它内联容器（text:span 之外的）继续往下走
        buf.write(_odtInline(child, styles, resources));
    }
  }
  return buf.toString();
}

// ------------------------------------------------------------------ OPF

/// `.opf`：散装 EPUB 的包文件。
///
/// 只有调用方把 manifest 里引用的 XHTML **兄弟文件**一起给进来（[siblings]），
/// 才能产出正文；否则明确报错 —— 解析层拿到的是一个文件的字节，不会去猜。
BookContent parseOpfBook(
  List<int> bytes, {
  required BookFormat format,
  Map<String, Uint8List>? siblings,
  String opfPath = 'content.opf',
}) {
  final root = parseBookXmlBytes(bytes);
  if (root == null) throw const FormatException('OPF 解析失败');

  final package = root.first('package') ?? root;
  final metadata = package.first('metadata');
  final title = metadata?.first('title')?.text.trim() ?? '';
  final author = metadata?.first('creator')?.text.trim() ?? '';

  final manifest = <String, ({String href, String media})>{};
  for (final item in package.descendants('item')) {
    final id = item.attr('id') ?? '';
    final href = item.attr('href') ?? '';
    if (id.isEmpty || href.isEmpty) continue;
    manifest[id] = (
      href: normalizeBookPath(opfDir(opfPath) + href),
      media: item.attr('media-type') ?? '',
    );
  }

  final spineIds = [
    for (final ref in package.descendants('itemref')) ref.attr('idref') ?? '',
  ];
  final order = spineIds.isNotEmpty ? spineIds : manifest.keys.toList();

  final chapters = <BookChapter>[];
  final toc = <BookTocEntry>[];
  var missing = 0;
  for (final id in order) {
    final item = manifest[id];
    if (item == null) continue;
    final isHtml =
        item.media.contains('html') ||
        item.href.endsWith('.xhtml') ||
        item.href.endsWith('.html') ||
        item.href.endsWith('.htm');
    if (!isHtml) continue;
    final data = siblings?[item.href];
    if (data == null) {
      missing++;
      continue;
    }
    final sub = parseHtmlBook(data, format: format, siblings: siblings);
    for (final ch in sub.chapters) {
      final index = chapters.length;
      chapters.add(
        BookChapter(title: ch.title, html: ch.html, href: item.href),
      );
      toc.add(BookTocEntry(title: ch.title, chapterIndex: index));
    }
  }

  if (chapters.isEmpty && missing > 0) {
    // 这是**能力边界**而不是"文件坏了"：单独的 OPF 本来就只有清单，正文在
    // 旁边的文件里，而解析层只收到一个文件的字节 → 明确报"不支持内嵌"。
    throw BookUnsupportedException(
      '散装 EPUB 的 OPF：正文文件不在包内（只收到 OPF 一个文件，缺 $missing 个 XHTML）',
      reason: BookUnsupportedReason.missingParts,
    );
  }
  if (chapters.isEmpty) {
    throw const FormatException('OPF 里没有可读的正文（manifest/spine 为空）');
  }

  final resources = <String, Uint8List>{};
  if (siblings != null) {
    siblings.forEach((path, data) {
      if (_looksLikeImage(path)) resources[path] = data;
    });
  }

  return BookContent(
    format: format,
    title: title,
    author: author,
    chapters: chapters,
    toc: toc,
    resources: resources,
  );
}

/// `OEBPS/content.opf` → `OEBPS/`
String opfDir(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i + 1);
}


// -------------------------------------------------- XLSX / PPTX / ODS / ODP
//
// D62「通用查看器」：官方 Drive 用**本地 `uv.html`**（UniversalViewer 的 WebView）
// 渲染 pptx/xlsx/odt/ods/odp；我们是纯 Dart 阅读器，所以直接解容器、抽结构，
// 再交给既有的分章/渲染管线（表格 → `<table>`，幻灯片/页 → 分章）。
//
// 四种都是 zip 容器 + 结构化 XML：
//   * **XLSX**：`xl/sharedStrings.xml`（共享字符串）+ `xl/worksheets/sheetN.xml`
//     （行/列；`t="s"` 是共享字符串下标、`t="inlineStr"` 是内联、其余是数值）+
//     `xl/workbook.xml` 的 sheet 名。一张表 = 一章。
//   * **PPTX**：`ppt/slides/slideN.xml`（`a:t` 文本运行）+ 每页图片
//     `ppt/media/*`；一张幻灯片 = 一章（标题取该页第一个文本行）。
//   * **ODS / ODP**：`content.xml` 里 `table:table`（单元格 `table:table-cell`，
//     值在 `office:value`/`office:value-type` 或内嵌 `text:p`）与
//     `draw:page`（页内 `text:p`）；与 ODT 共用 manifest 加密检测。

/// `.xlsx`：读**每个工作表**为一块 HTML 表格（一张表一章）。
BookContent parseXlsxBook(List<int> bytes, {required BookFormat format}) {
  final files = _unzip(bytes, 'XLSX');
  final shared = _xlsxSharedStrings(files['xl/sharedstrings.xml']);
  final names = _xlsxSheetNames(files['xl/workbook.xml']);

  final sheets = files.keys
      .where((k) => k.startsWith('xl/worksheets/sheet') && k.endsWith('.xml'))
      .toList()
    ..sort(_sheetOrder);

  final blocks = <BookBlock>[];
  for (var i = 0; i < sheets.length; i++) {
    final path = sheets[i];
    final root = parseBookXmlBytes(files[path]!);
    if (root == null) continue;
    // `sheet1.xml` → 1（用来对齐 workbook.xml 里的名字）
    final idx = int.tryParse(
      RegExp(r'sheet(\d+)\.xml$').firstMatch(path)?.group(1) ?? '',
    );
    final name =
        (idx != null && idx - 1 < names.length && names[idx - 1].isNotEmpty)
        ? names[idx - 1]
        : fsTFill('bookSheetN', '工作表 ${i + 1}', {'n': '${i + 1}'});
    blocks.add(
      BookBlock(
        '<h2>${_escapeText(name)}</h2>',
        title: name,
        heading: true,
      ),
    );
    final table = _xlsxSheetTable(root, shared);
    if (table != null) blocks.add(table);
  }

  if (blocks.isEmpty) {
    throw const FormatException('XLSX 里没有可读的工作表（不是有效的 XLSX）');
  }

  final resources = _imageResources(files);
  final split = bookChapterize(blocks, format: format);
  final title = names.isNotEmpty ? names.first : fsT('bookWorkbookTitle', '工作簿');
  return BookContent(
    format: format,
    title: title,
    chapters: split.chapters,
    toc: split.toc,
    resources: resources,
  );
}

/// `.pptx`：一页一章；`a:t` 文本运行 + `ppt/media/*` 图片。
BookContent parsePptxBook(List<int> bytes, {required BookFormat format}) {
  final files = _unzip(bytes, 'PPTX');
  final slides = files.keys
      .where((k) => k.startsWith('ppt/slides/slide') && k.endsWith('.xml'))
      .toList()
    ..sort(_slideOrder);
  if (slides.isEmpty) {
    throw const FormatException('PPTX 里没有幻灯片（不是有效的 PPTX）');
  }

  final blocks = <BookBlock>[];
  for (var i = 0; i < slides.length; i++) {
    final path = slides[i];
    final root = parseBookXmlBytes(files[path]!);
    if (root == null) continue;
    // 每页的文本运行，按文档顺序
    final runs = <String>[];
    for (final t in root.descendants('t')) {
      final v = t.text.trim();
      if (v.isNotEmpty) runs.add(v);
    }
    final heading = runs.isEmpty ? _slideTitle(i + 1) : runs.first;
    blocks.add(
      BookBlock(
        '<h2>${_escapeText(_pageTitle(i + 1))}</h2>',
        title: _pageTitle(i + 1),
        heading: true,
      ),
    );
    if (heading.isNotEmpty && heading != _slideTitle(i + 1)) {
      blocks.add(BookBlock('<h3>${_escapeText(heading)}</h3>'));
    }
    for (final r in runs.skip(1)) {
      blocks.add(BookBlock('<p>${_escapeText(r)}</p>'));
    }
  }

  final resources = _imageResources(files);
  final split = bookChapterize(blocks, format: format);
  return BookContent(
    format: format,
    title: _officeTitle(files) ?? dataText('officeSlidesTitle', '演示文稿'),
    chapters: split.chapters,
    toc: split.toc,
    resources: resources,
  );
}

/// `.ods` / `.odp`：ODF 表格 / 演示文稿（与 ODT 共用 `content.xml` + 加密检测）。
BookContent parseOdfBook(List<int> bytes, {required BookFormat format}) {
  final files = _unzip(bytes, 'ODF');

  final manifest = files['meta-inf/manifest.xml'];
  if (manifest != null) {
    final mroot = parseBookXmlBytes(manifest);
    if (mroot != null && mroot.first('encryption-data') != null) {
      throw BookUnsupportedException(
        '这个是加密的 ${format.label}（manifest.xml 里标了 encryption-data），本阅读器不解密',
      );
    }
  }

  final content = files['content.xml'];
  if (content == null) {
    throw const FormatException('ODF 里没有 content.xml（不是有效的 ODF）');
  }
  final root = parseBookXmlBytes(content);
  if (root == null) throw const FormatException('ODF 的 content.xml 解析失败');
  final body = root.first('body') ?? root;

  final blocks = <BookBlock>[];
  final tables = body.descendants('table').where((t) => t.local == 'table');
  final pages = body.descendants('page').toList();
  if (tables.isNotEmpty) {
    var i = 0;
    for (final tbl in tables) {
      i += 1;
      final name =
          tbl.attr('name') ?? fsTFill('bookSheetN', '工作表 $i', {'n': '$i'});
      blocks.add(
        BookBlock('<h2>${_escapeText(name)}</h2>', title: name, heading: true),
      );
      final html = _odfTable(tbl);
      if (html != null) blocks.add(html);
    }
  }
  if (pages.isNotEmpty) {
    for (var i = 0; i < pages.length; i++) {
      final name = pages[i].attr('name') ?? '';
      final label = name.isEmpty ? _pageTitle(i + 1) : name;
      blocks.add(
        BookBlock('<h2>${_escapeText(label)}</h2>', title: label, heading: true),
      );
      for (final p in pages[i].descendants('p')) {
        final v = p.text.trim();
        if (v.isNotEmpty) blocks.add(BookBlock('<p>${_escapeText(v)}</p>'));
      }
    }
  }
  if (blocks.isEmpty) {
    throw FormatException('${format.label} 里没有可读内容（不是有效的 ${format.label}）');
  }

  final resources = _imageResources(files);
  final split = bookChapterize(blocks, format: format);
  return BookContent(
    format: format,
    title: _officeTitle(files) ?? format.label,
    chapters: split.chapters,
    toc: split.toc,
    resources: resources,
  );
}

/// XLSX 共享字符串（`xl/sharedStrings.xml` 的每个 `<si>` 拼起来）。
List<String> _xlsxSharedStrings(Uint8List? bytes) {
  if (bytes == null) return const [];
  final root = parseBookXmlBytes(bytes);
  if (root == null) return const [];
  return [
    for (final si in root.descendants('si'))
      si.descendants('t').map((t) => t.text).join(),
  ];
}

/// `xl/workbook.xml` 的 sheet 名（按出现顺序）。
List<String> _xlsxSheetNames(Uint8List? bytes) {
  if (bytes == null) return const [];
  final root = parseBookXmlBytes(bytes);
  if (root == null) return const [];
  return [
    for (final sh in root.descendants('sheet')) sh.attr('name') ?? '',
  ];
}

int _sheetOrder(String a, String b) =>
    (_numSuffix(a) ?? 0).compareTo(_numSuffix(b) ?? 0);

int _slideOrder(String a, String b) =>
    (_numSuffix(a) ?? 0).compareTo(_numSuffix(b) ?? 0);

int? _numSuffix(String path) =>
    int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(path)?.group(1) ?? '');

/// 一张工作表 → `<table>`（空行/空列**照样保留占位**，否则行列会错位）。
BookBlock? _xlsxSheetTable(BookXmlNode sheetRoot, List<String> shared) {
  final rows = <List<String>>[];
  var width = 0;
  for (final row in sheetRoot.descendants('row')) {
    final cells = <String>[];
    for (final c in row.childrenNamed('c')) {
      final ref = c.attr('r') ?? '';
      final col = _xlsxColumnIndex(ref);
      while (col >= 0 && cells.length < col) {
        cells.add('');
      }
      cells.add(_xlsxCellValue(c, shared));
    }
    if (cells.isEmpty) continue;
    if (cells.length > width) width = cells.length;
    rows.add(cells);
  }
  if (rows.isEmpty) return null;
  final buf = StringBuffer('<table>');
  for (final r in rows) {
    buf.write('<tr>');
    for (var i = 0; i < width; i++) {
      buf.write('<td>${_escapeText(i < r.length ? r[i] : '')}</td>');
    }
    buf.write('</tr>');
  }
  buf.write('</table>');
  return BookBlock(buf.toString());
}

/// `B12` → 1（0 起）；解析不了回 -1。
int _xlsxColumnIndex(String ref) {
  var col = -1;
  for (final ch in ref.toUpperCase().codeUnits) {
    if (ch < 0x41 || ch > 0x5A) break;
    col = (col + 1) * 26 + (ch - 0x41);
  }
  return col;
}

String _xlsxCellValue(BookXmlNode c, List<String> shared) {
  final type = c.attr('t');
  if (type == 'inlineStr') {
    return c.descendants('t').map((t) => t.text).join();
  }
  final v = c.child('v')?.text ?? c.first('v')?.text ?? '';
  if (type == 's') {
    final i = int.tryParse(v.trim());
    if (i != null && i >= 0 && i < shared.length) return shared[i];
    return '';
  }
  return v;
}

/// ODF 表格 → `<table>`
BookBlock? _odfTable(BookXmlNode tbl) {
  final rows = <List<String>>[];
  var width = 0;
  for (final row in tbl.descendants('table-row')) {
    final cells = <String>[];
    for (final cell in row.childrenNamed('table-cell')) {
      var text = cell.descendants('p').map((p) => p.text).join(' ').trim();
      if (text.isEmpty) {
        // 数字单元格：`office:value`（没有 text:p 时）
        text = cell.attr('value') ?? cell.attr('date-value') ?? '';
      }
      final repeat = int.tryParse(
        cell.attr('number-columns-repeated') ?? '',
      );
      final n = (repeat == null || repeat < 1 || repeat > 64) ? 1 : repeat;
      for (var k = 0; k < n; k++) {
        cells.add(text);
      }
    }
    if (cells.isEmpty) continue;
    if (cells.length > width) width = cells.length;
    rows.add(cells);
  }
  if (rows.isEmpty) return null;
  final buf = StringBuffer('<table>');
  for (final r in rows) {
    buf.write('<tr>');
    for (var i = 0; i < width; i++) {
      buf.write('<td>${_escapeText(i < r.length ? r[i] : '')}</td>');
    }
    buf.write('</tr>');
  }
  buf.write('</table>');
  return BookBlock(buf.toString());
}

/// 包里的图片资源（按路径小写键，与 DOCX/ODT 一致）。
Map<String, Uint8List> _imageResources(Map<String, Uint8List> files) {
  final out = <String, Uint8List>{};
  files.forEach((path, data) {
    if (_looksLikeImage(path)) out[path] = data;
  });
  return out;
}

/// `docProps/core.xml` 的 `dc:title`（有就用，没有回 null）。
String? _officeTitle(Map<String, Uint8List> files) {
  final core = files['docprops/core.xml'];
  if (core == null) return null;
  final root = parseBookXmlBytes(core);
  final t = root?.first('title')?.text.trim() ?? '';
  return t.isEmpty ? null : t;
}

// ------------------------------------------------------------------ 工具

Map<String, Uint8List> _unzip(List<int> bytes, String what) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  final files = <String, Uint8List>{};
  for (final f in archive) {
    if (!f.isFile) continue;
    // zip 里的路径大小写不统一（`META-INF/` vs `meta-inf/`、`docProps/`），
    // 一律小写做键，查找也用小写字面量，避免"明明在包里却找不到"。
    final name = normalizeBookPath(f.name).toLowerCase();
    if (name.isEmpty) continue;
    files[name] = Uint8List.fromList(f.content as List<int>);
  }
  if (files.isEmpty) throw FormatException('$what 是空的（zip 里没有文件）');
  return files;
}

bool _looksLikeImage(String path) {
  final p = path.toLowerCase();
  return p.endsWith('.jpg') ||
      p.endsWith('.jpeg') ||
      p.endsWith('.png') ||
      p.endsWith('.gif') ||
      p.endsWith('.webp') ||
      p.endsWith('.bmp') ||
      p.endsWith('.svg');
}

String _plain(String html) => html.replaceAll(RegExp(r'<[^>]*>'), '').trim();

String _escapeText(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _escapeAttr(String s) => _escapeText(s).replaceAll('"', '&quot;');

/// 给探针用：DOCX/ODT/OPF 的结构摘要（不落 BookContent）
Map<String, Object?> officeProbe(List<int> bytes, String format) {
  try {
    final files = _unzip(bytes, format);
    return {
      'ok': true,
      'entries': files.length,
      'hasDocument': files.containsKey('word/document.xml'),
      'hasContent': files.containsKey('content.xml'),
      'hasOpf': files.keys.any((k) => k.endsWith('.opf')),
      'media': files.keys.where(_looksLikeImage).length,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}

/// 供测试/探针：UTF-8 编码
List<int> utf8Bytes(String s) => utf8.encode(s);


/// 幻灯片兜底标题（`幻灯片 N`）：纯 Dart 层不能 i18n ⇒ 走 `dataText`。
String _slideTitle(int n) =>
    dataText('bookSlidesHeading', '幻灯片 {n}').replaceAll('{n}', '$n');

/// 页码标题（`第 N 页`）。
String _pageTitle(int n) =>
    dataText('bookPageN', '第 {n} 页').replaceAll('{n}', '$n');
