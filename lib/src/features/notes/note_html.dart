// NoteStation 的 HTML ⇄ Quill Delta 转换 + XSS 净化。
//
// 为什么自己写：NoteStation 的正文是**净化后的 HTML**（官方编辑器是 WebView +
// execCommand），而我们的编辑器是 Flutter 原生（`flutter_quill`，Delta 模型）。
// pub 上的 `quill_html_converter` 只支持到 flutter_quill 9（我们用的是 11.6），
// 所以这层转换自己维护 —— 好处是能按 NoteStation 的 HTML 子集精确定制，
// 也顺手把净化做在同一处。
//
// Delta 的两条规矩（写错过一次，记在这里）：
//   * **行属性**（header / list / indent / blockquote / code-block）挂在行尾的
//     `\n` 上，不能挂到正文 insert 上；
//   * **行内属性**（bold / italic / link / color…）挂在文字 insert 上。
//
// 支持的子集（覆盖 NoteStation 编辑器的常用格式）：
//   块：p / div / h1..h6 / blockquote / pre / ul / ol / li / hr / table(拍平)
//   行内：b,strong / i,em / u / s,strike,del / sub / sup / code / a[href] /
//         span[style] / font[color] / br
//   图片：img[src] → Quill image embed
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as htmlp;

import '../../data/dto/note_dto.dart';

/// 允许保留的标签（净化白名单）
const Set<String> _allowedTags = {
  'p',
  'div',
  'br',
  'span',
  'b',
  'strong',
  'i',
  'em',
  'u',
  's',
  'strike',
  'del',
  'sub',
  'sup',
  'code',
  'pre',
  'blockquote',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'ul',
  'ol',
  'li',
  'a',
  'img',
  'input',
  'hr',
  'table',
  'thead',
  'tbody',
  'tr',
  'td',
  'th',
  'font',
};

/// 允许保留的属性（其余（含所有 `on*`）一律删）
const Map<String, Set<String>> _allowedAttrs = {
  'a': {'href', 'title'},
  // `ref`/`content_id` 是 NoteStation 自己认的图片标识（真机正文就靠它找附件），
  // 净化时必须留着，否则图片会变成一张指向 transparent.gif 的破图。
  // `class` 留着：清单勾选框的状态就编码在
  // `syno-notestation-editor-checkbox[-checked]` 上（官方 TinyMCE
  // `syno_checkbox` 插件 + `serializeContent` 原文）。
  'img': {
    'src',
    'alt',
    'width',
    'height',
    'ref',
    'content_id',
    'adjust',
    'class',
    'style',
  },
  // 清单勾选框（官方编辑器里就是 `<input type="image" class=…>`）
  'input': {'type', 'src', 'class', 'data-mce-src', 'content_id'},
  // `style` 留着：对齐（`text-align`）与字号（`font-size`）都在这里
  'p': {'style', 'align'},
  'div': {'style', 'align'},
  'h1': {'style', 'align'},
  'h2': {'style', 'align'},
  'h3': {'style', 'align'},
  'h4': {'style', 'align'},
  'h5': {'style', 'align'},
  'h6': {'style', 'align'},
  'li': {'style', 'align'},
  'blockquote': {'style', 'align'},
  'td': {'colspan', 'rowspan', 'style', 'align'},
  'th': {'colspan', 'rowspan', 'style', 'align'},
  'span': {'style', 'class'},
  'font': {'color', 'size', 'face', 'class'},
};

/// 块级标签（渲染成"一行"）
const Set<String> _blockTags = {
  'p',
  'div',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'blockquote',
  'pre',
  'ul',
  'ol',
  'li',
  'hr',
  'table',
  'thead',
  'tbody',
  'tr',
};

bool _isBlock(dom.Node n) =>
    n is dom.Element && _blockTags.contains(n.localName?.toLowerCase());

/// 安全 URL 协议（`javascript:`、`data:text/html` 一律清掉）
bool _safeUrl(String url) {
  final u = url.trim().toLowerCase();
  if (u.startsWith('javascript:') || u.startsWith('vbscript:')) return false;
  if (u.startsWith('data:') && !u.startsWith('data:image/')) return false;
  return true;
}

// --------------------------------------------------- 批次 A：格式补齐（对照）

/// 官方 7 档字号 class（[E2] `EditorToolBar.showFontSizeChooser` 的
/// `strArr` 与 `syno_notefontsizeselect/style.css`）。
///
/// 官方工具栏值：`syno-fontsize-xx-small`(10pt) / `x-small`(12pt) /
/// `small`(14pt) / `normal`(16pt) / `large`(18pt) / `x-large`(24pt) /
/// `xx-large`(36pt)；另有 `xxx-small`(8pt) 只在 Web 端存在。
const List<String> kSynoFontSizes = [
  'syno-fontsize-xx-small',
  'syno-fontsize-x-small',
  'syno-fontsize-small',
  'syno-fontsize-normal',
  'syno-fontsize-large',
  'syno-fontsize-x-large',
  'syno-fontsize-xx-large',
];

const List<String> kSynoFontSizeLabels = [
  '10pt',
  '12pt',
  '14pt',
  '16pt',
  '18pt',
  '24pt',
  '36pt',
];

/// 官方字号 class → Quill 原生 `size` 值（只为**编辑器里能看出差别**；
/// 权威值仍是 [kSynoFontSizes] 里的 class，保存时优先用它）。
String? quillSizeForSynoFont(String? synoClass) {
  switch (synoClass) {
    case 'syno-fontsize-xxx-small':
    case 'syno-fontsize-xx-small':
    case 'syno-fontsize-x-small':
      return 'small';
    case 'syno-fontsize-large':
    case 'syno-fontsize-x-large':
      return 'large';
    case 'syno-fontsize-xx-large':
      return 'huge';
    default:
      return null;
  }
}

String? _synoFontOfClass(String? cls) {
  if (cls == null || cls.isEmpty) return null;
  final parts = cls.split(RegExp(r'\s+'));
  for (final size in [...kSynoFontSizes, 'syno-fontsize-xxx-small']) {
    if (parts.contains(size)) return size;
  }
  return null;
}

/// 从块的 `style`/`align` 取对齐方式（官方 4 向 `justify*`）
String? _alignOf(dom.Element el) {
  final align = (el.attributes['align'] ?? '').trim().toLowerCase();
  if (align.isNotEmpty) {
    if (align == 'middle') return 'center';
    if (const {'left', 'center', 'right', 'justify'}.contains(align)) {
      return align;
    }
  }
  final style = el.attributes['style'] ?? '';
  final m = RegExp(
    r'text-align\s*:\s*(left|center|right|justify)',
    caseSensitive: false,
  ).firstMatch(style);
  return m?.group(1)?.toLowerCase();
}

/// 把块级对齐并进行属性（`align` 是 Quill 的块级属性，挂在行尾 `\n` 上）
Map<String, dynamic> _alignAttr(dom.Element el) {
  final align = _alignOf(el);
  return align == null ? const {} : {'align': align};
}

/// 清单勾选框的官方标识（[E2]/服务端 UI 原文）：
///
/// * 编辑器态：`<input type="image" class="syno-notestation-editor-checkbox
///   [syno-notestation-editor-checkbox-checked]">`
///   （`syno_checkbox/plugin.min.js` 的 `syno_checkbox_insert`）；
/// * 落库态：`serializeContent` 把它换成
///   `<img class="…" content_id="#checkbox_checked|#checkbox_unchecked">`。
///
/// 两种形态都要认，否则保存过的勾选状态在重开时丢。
String? _checkboxStateOf(dom.Element el) {
  final cls = el.attributes['class'] ?? '';
  final cid = el.attributes['content_id'] ?? '';
  final src = el.attributes['src'] ?? '';
  final isCheckbox =
      cls.contains('syno-notestation-editor-checkbox') ||
      cid.startsWith('#checkbox_');
  if (!isCheckbox) return null;
  final checked =
      cls.contains('syno-notestation-editor-checkbox-checked') ||
      cid == '#checkbox_checked' ||
      src.contains('editor_checkbox_03');
  return checked ? 'checked' : 'unchecked';
}

/// 清单勾选框的官方 HTML（编辑器态 `<input>`；官方 Web 保存时会自己转成
/// `<img content_id="#checkbox_checked">`，所以这里发编辑器态最稳）。
String noteCheckboxHtml(String state) {
  final checked = state == 'checked';
  final src = checked
      ? 'webman/modules/TinyMCE/js/tinymce/plugins/syno_checkbox/editor_checkbox_03.png'
      : 'webman/modules/TinyMCE/js/tinymce/plugins/syno_checkbox/editor_checkbox_01.png';
  final cls = checked
      ? 'syno-notestation-editor-checkbox syno-notestation-editor-checkbox-checked'
      : 'syno-notestation-editor-checkbox';
  return '<input type="image" src="$src" '
      'data-mce-src="webman/3rdparty/NoteStation/images/transparent.gif" '
      'class="$cls"></input>';
}

/// 净化笔记正文：只留白名单标签/属性，去掉脚本、事件属性与危险 URL。
///
/// 服务端存的本来就是"净化过的 HTML"，但共享笔记是**别人**写的，
/// 也就是不可信输入 —— 渲染前必须再净化一遍。
String sanitizeNoteHtml(String html) {
  if (html.trim().isEmpty) return '';
  final root = htmlp.parseFragment(html);
  _cleanNode(root);
  return root.nodes
      .map((n) => n is dom.Element ? n.outerHtml : (n.text ?? ''))
      .join();
}

void _cleanNode(dom.Node node) {
  for (final child in node.nodes.toList()) {
    if (child is dom.Element) {
      final tag = child.localName?.toLowerCase() ?? '';
      if (!_allowedTags.contains(tag)) {
        // 不允许的标签整段丢弃（script/style 的内容也不能留）
        child.remove();
        continue;
      }
      final allowed = _allowedAttrs[tag] ?? const <String>{};
      for (final attr in child.attributes.keys.toList()) {
        final name = '$attr'.toLowerCase();
        final keep = allowed.contains(name) && !name.startsWith('on');
        if (!keep) {
          child.attributes.remove(attr);
          continue;
        }
        if ((name == 'href' || name == 'src') &&
            !_safeUrl(child.attributes[attr] ?? '')) {
          child.attributes.remove(attr);
        }
      }
      _cleanNode(child);
    } else if (child is dom.Comment) {
      child.remove();
    }
  }
}

/// 纯文本预览（列表摘要、搜索匹配都用它）
///
/// 块级边界与 `<br>` 都要留一个**空格**：`package:html` 的 `text` 只是把文本节点
/// 拼起来，`<p>a</p><p>b</p>` 会变成 `ab`（摘要里就黏成一个词了）。
String notePlainText(String html) {
  if (html.trim().isEmpty) return '';
  final root = htmlp.parseFragment(html);
  final b = StringBuffer();
  void walk(dom.Node n) {
    if (n is dom.Text) {
      b.write(n.text);
      return;
    }
    if (n is! dom.Element) return;
    final tag = n.localName?.toLowerCase() ?? '';
    if (tag == 'br') {
      b.write(' ');
      return;
    }
    for (final child in n.nodes) {
      walk(child);
    }
    if (_blockTags.contains(tag)) b.write(' ');
  }

  for (final n in root.nodes) {
    walk(n);
  }
  return b.toString().replaceAll(RegExp(r'[\s\u00a0]+'), ' ').trim();
}

/// 笔记里带的图片 URL（`<img src>`）
List<String> noteImageSources(String html) {
  if (html.trim().isEmpty) return const [];
  return htmlp
      .parseFragment(html)
      .querySelectorAll('img')
      .map((e) => e.attributes['src'] ?? '')
      .where((s) => s.isNotEmpty && _safeUrl(s))
      .toList(growable: false);
}

// ---------------------------------------------------------------- HTML → Delta

/// `<img>` 到附件 `file_id` 的解析规则。
///
/// 真机实测（见 `docs/p1-notestation-implementation.md`）：服务端**不**把
/// `<img ref="…">` 改写成别的形态 —— `Note/get` 回来的正文仍然是
/// `ref="<编辑器生成的唯一串>"`，而 `data.attachment` 里每条附件都带同一个 `ref`。
/// 所以渲染时要靠 `ref` 反查 `file_id`，再用 `Note/download` 取图。
///
/// 同时兼容 Web 端保存后的 `content_id`（值就是 `file_id`）。
class NoteImageResolver {
  const NoteImageResolver({this.byRef = const {}, this.bySrc = const {}});

  /// `ref`（或 `content_id`）→ `file_id`
  final Map<String, String> byRef;

  /// `src`（Web 端的 `/ns/dv/…` 直链里含 `file_id`）→ `file_id`
  final Map<String, String> bySrc;

  static const NoteImageResolver none = NoteImageResolver();

  /// 从附件表建解析器（`ref` 与 `content_id` 都指向 file_id）
  factory NoteImageResolver.ofAttachments(
    Map<String, NoteAttachmentDto> attachments,
  ) {
    final byRef = <String, String>{};
    final bySrc = <String, String>{};
    attachments.forEach((fileId, a) {
      if (a.ref.isNotEmpty) byRef[a.ref] = fileId;
      byRef[fileId] = fileId;
    });
    return NoteImageResolver(byRef: byRef, bySrc: bySrc);
  }

  /// `<img>` → `file_id`；解析不出来时回退到 `ref`/`content_id`/`src` 原值
  String? valueOf(dom.Element img) {
    final ref = img.attributes['ref'] ?? img.attributes['content_id'];
    if (ref != null && ref.isNotEmpty) {
      return byRef[ref] ?? (byRef.containsKey(ref) ? byRef[ref] : ref);
    }
    final src = img.attributes['src'] ?? '';
    if (src.isEmpty) return null;
    return bySrc[src] ?? src;
  }
}

/// 收集行内片段：文字 + 行内属性（图片用 `image` 属性表示）
class _Inline {
  _Inline(this.text, this.attrs);
  final String text;
  final Map<String, dynamic> attrs;
}

/// NoteStation HTML → Quill Delta（`List<Map>`，可直接喂 `Document.fromJson`）。
///
/// [resolver] 用来把 `<img ref="…">` 变成附件 `file_id`（见 [NoteImageResolver]）。
List<Map<String, dynamic>> noteHtmlToDelta(
  String html, {
  NoteImageResolver resolver = NoteImageResolver.none,
}) {
  final ops = <Map<String, dynamic>>[];
  final root = htmlp.parseFragment(sanitizeNoteHtml(html));
  for (final node in root.nodes) {
    // 顶层不是块级标签的（例如笔记正文里裸放的 `<img>`、`<span>`）
    // 也要单独成行 —— 否则会被当成"没有子节点的容器"整段丢掉（真机踩过：
    // NoteStation 存回来的正文就是 `<p>l1.png</p><img …>`）。
    if (node is dom.Element && !_isBlock(node)) {
      _emitInlineLine([node], ops, const {}, const {}, 0, resolver);
      continue;
    }
    _emitBlock(node, ops, const {}, 0, resolver);
  }
  if (ops.isEmpty || ops.last['insert'] != '\n') ops.add({'insert': '\n'});
  return ops;
}

void _emitBlock(
  dom.Node node,
  List<Map<String, dynamic>> ops,
  Map<String, dynamic> lineAttrs,
  int indent, [
  NoteImageResolver resolver = NoteImageResolver.none,
]) {
  if (node is dom.Text) {
    if (node.text.trim().isEmpty) return;
    _emitInlineLine(
      node.nodes.toList(),
      ops,
      const {},
      lineAttrs,
      indent,
      resolver,
    );
    return;
  }
  if (node is! dom.Element) return;

  final tag = node.localName?.toLowerCase() ?? '';
  switch (tag) {
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      _emitInlineLine(
        node.nodes.toList(),
        ops,
        const {},
        {
          ...lineAttrs,
          'header': int.parse(tag.substring(1)),
          ..._alignAttr(node),
        },
        indent,
        resolver,
      );
    case 'blockquote':
      _emitInlineLine(
        node.nodes.toList(),
        ops,
        const {},
        {...lineAttrs, 'blockquote': true, ..._alignAttr(node)},
        indent,
        resolver,
      );
    case 'pre':
      final code = _collectText(node).replaceAll(RegExp(r'\n+$'), '');
      if (code.trim().isEmpty) return;
      ops.add({
        'insert': '$code\n',
        'attributes': {...lineAttrs, 'code-block': true},
      });
    case 'hr':
      // 官方 `CMD_HORIZONTAL_RULE="inserthorizontalrule"` → `<hr>`。
      // Quill 没有内置 hr，用自定义块 embed（`{'hr': ''}`）保住它。
      ops.add({
        'insert': const {'hr': ''},
      });
      ops.add({
        'insert': '\n',
        if (lineAttrs.isNotEmpty) 'attributes': lineAttrs,
      });
    case 'ul':
    case 'ol':
      for (final li in node.children.where(
        (c) => c.localName?.toLowerCase() == 'li',
      )) {
        final nested = li.children.where((c) {
          final t = c.localName?.toLowerCase();
          return t == 'ul' || t == 'ol';
        }).toList();
        // `<li>` 的文字部分（去掉嵌套列表）
        final inlineNodes = <dom.Node>[];
        for (final child in li.nodes) {
          if (child is dom.Element &&
              const {'ul', 'ol'}.contains(child.localName?.toLowerCase())) {
            continue;
          }
          inlineNodes.add(child);
        }
        _emitInlineLine(
          inlineNodes,
          ops,
          const {},
          {
            ...lineAttrs,
            'list': tag == 'ol' ? 'ordered' : 'bullet',
            if (indent > 0) 'indent': indent,
          },
          indent,
          resolver,
        );
        for (final sub in nested) {
          _emitBlock(sub, ops, lineAttrs, indent + 1, resolver);
        }
      }
    case 'table':
      // 表格先拍平成"一行一格"，内容不丢（真机对齐后再升级成真表格）
      for (final row in node.querySelectorAll('tr')) {
        final cells = row.children
            .where(
              (c) => const {'td', 'th'}.contains(c.localName?.toLowerCase()),
            )
            .map((c) => c.text.trim())
            .where((t) => t.isNotEmpty)
            .join(' | ');
        if (cells.isEmpty) continue;
        ops.add({'insert': '$cells\n'});
      }
    case 'div':
    case 'p':
    case 'li':
      // 里面还有块级子节点（比如 div 套 p）→ 继续往下钻，别丢行属性
      if (node.nodes.any(_isBlock)) {
        for (final child in node.nodes) {
          _emitBlock(child, ops, lineAttrs, indent, resolver);
        }
        return;
      }
      if (node.nodes.isEmpty) {
        // `<p></p>`（空行）也要占一行
        ops.add({
          'insert': '\n',
          if (lineAttrs.isNotEmpty) 'attributes': lineAttrs,
        });
        return;
      }
      _emitInlineLine(
        node.nodes.toList(),
        ops,
        const {},
        {...lineAttrs, ..._alignAttr(node)},
        indent,
        resolver,
      );
    default:
      for (final child in node.nodes) {
        _emitBlock(child, ops, lineAttrs, indent, resolver);
      }
  }
}

/// 行内节点 → Delta（`<br>` 会拆成多行）
void _emitInlineLine(
  List<dom.Node> nodes,
  List<Map<String, dynamic>> ops,
  Map<String, dynamic> inlineAttrs,
  Map<String, dynamic> lineAttrs,
  int indent, [
  NoteImageResolver resolver = NoteImageResolver.none,
]) {
  final runs = <_Inline>[];
  for (final n in nodes) {
    _collectInline(n, inlineAttrs, runs, resolver);
  }
  if (runs.isEmpty) return;

  // 按 `<br>` 产生的 `\n` 拆行
  var chunks = <List<_Inline>>[<_Inline>[]];
  for (final run in runs) {
    if (!run.text.contains('\n')) {
      chunks.last.add(run);
      continue;
    }
    final parts = run.text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) {
        chunks.last.add(_Inline(parts[i], run.attrs));
      }
      if (i < parts.length - 1) chunks.add(<_Inline>[]);
    }
  }
  // 行尾的 `<br>` 在浏览器里是"无意义"的（`<p>a<br></p>` 就是一行 a）
  while (chunks.length > 1 && chunks.last.isEmpty) {
    chunks.removeLast();
  }
  for (final chunk in chunks) {
    // 行内勾选框 → Quill 的清单行属性（`list: checked|unchecked`）
    String? checkbox;
    for (final r in chunk) {
      final v = r.attrs['__checkbox'];
      if (v is String) checkbox = v;
    }
    final effectiveLine = checkbox == null
        ? lineAttrs
        : {...lineAttrs, 'list': checkbox};
    if (chunk.every((r) => r.text.isEmpty && r.attrs['image'] == null)) {
      ops.add({
        'insert': '\n',
        if (effectiveLine.isNotEmpty) 'attributes': effectiveLine,
      });
      continue;
    }
    for (final run in chunk) {
      if (run.attrs['image'] != null) {
        ops.add({
          'insert': {'image': run.attrs['image']},
        });
        continue;
      }
      if (run.text.isEmpty) continue;
      final attrs = Map<String, dynamic>.from(run.attrs)
        ..remove('image')
        ..remove('__checkbox');
      ops.add({'insert': run.text, if (attrs.isNotEmpty) 'attributes': attrs});
    }
    // 行属性只挂在行尾换行上
    ops.add({
      'insert': '\n',
      if (effectiveLine.isNotEmpty) 'attributes': effectiveLine,
    });
  }
}

void _collectInline(
  dom.Node node,
  Map<String, dynamic> attrs,
  List<_Inline> out, [
  NoteImageResolver resolver = NoteImageResolver.none,
]) {
  if (node is dom.Text) {
    if (node.text.isEmpty) return;
    out.add(_Inline(node.text, attrs));
    return;
  }
  if (node is! dom.Element) return;
  final tag = node.localName?.toLowerCase() ?? '';
  if (tag == 'br') {
    out.add(_Inline('\n', const {}));
    return;
  }
  if (tag == 'input') {
    // 清单勾选框（官方编辑器态）：不产生文字，只标一个行级状态
    final state = _checkboxStateOf(node);
    if (state != null) out.add(_Inline('', {...attrs, '__checkbox': state}));
    return;
  }
  if (tag == 'img') {
    // 落库态的勾选框（`content_id="#checkbox_checked"`）优先按勾选框处理
    final state = _checkboxStateOf(node);
    if (state != null) {
      out.add(_Inline('', {...attrs, '__checkbox': state}));
      return;
    }
    // 附件图片（真机：`<img … ref="…">`）→ Delta 的 image embed，
    // 值用**附件 file_id**，渲染时才能带上鉴权去下载。
    final value = resolver.valueOf(node) ?? node.attributes['src'] ?? '';
    if (value.isEmpty) return;
    final src = node.attributes['src'] ?? '';
    if (src.isNotEmpty && src.startsWith('data:') && !_safeUrl(src)) return;
    out.add(_Inline('', {...attrs, 'image': value}));
    return;
  }
  final next = <String, dynamic>{...attrs};
  switch (tag) {
    case 'b':
    case 'strong':
      next['bold'] = true;
    case 'i':
    case 'em':
      next['italic'] = true;
    case 'u':
      next['underline'] = true;
    case 's':
    case 'strike':
    case 'del':
      next['strike'] = true;
    case 'sub':
      next['script'] = 'sub';
    case 'sup':
      next['script'] = 'super';
    case 'code':
      next['code'] = true;
    case 'a':
      final href = node.attributes['href'];
      if (href != null && href.isNotEmpty && _safeUrl(href)) {
        next['link'] = href;
      }
    case 'span':
    case 'font':
      _mergeStyle(next, node);
  }
  for (final child in node.nodes) {
    _collectInline(child, next, out, resolver);
  }
}

String _collectText(dom.Node node) {
  final b = StringBuffer();
  if (node is dom.Text) return node.text;
  for (final child in node.nodes) {
    if (child is dom.Element &&
        const {'br'}.contains(child.localName?.toLowerCase())) {
      b.write('\n');
    } else {
      b.write(_collectText(child));
    }
  }
  return b.toString();
}

void _mergeStyle(Map<String, dynamic> attrs, dom.Element el) {
  final style = el.attributes['style'] ?? '';
  for (final decl in style.split(';')) {
    final idx = decl.indexOf(':');
    if (idx <= 0) continue;
    final key = decl.substring(0, idx).trim().toLowerCase();
    final value = decl.substring(idx + 1).trim();
    if (value.isEmpty) continue;
    switch (key) {
      case 'color':
        attrs['color'] = value;
      case 'background-color':
        attrs['background'] = value;
      case 'font-size':
        final syno = _synoFontOfPt(value);
        if (syno != null) attrs['size'] = syno;
      case 'font-weight':
        if (value == 'bold' || (int.tryParse(value) ?? 0) >= 600) {
          attrs['bold'] = true;
        }
      case 'font-style':
        if (value == 'italic') attrs['italic'] = true;
      case 'text-decoration':
        if (value.contains('underline')) attrs['underline'] = true;
        if (value.contains('line-through')) attrs['strike'] = true;
      // `text-align` 是**块级**属性，交给 `_alignOf`；行内 span 上忽略
    }
  }
  final color = el.attributes['color'];
  if (color != null && color.isNotEmpty) attrs['color'] = color;
  // 官方字号是 class，不是 inline style（`syno_notefontsizeselect`）
  final syno = _synoFontOfClass(el.attributes['class']);
  if (syno != null) attrs['size'] = syno;
}

/// `font-size` 值（px/pt/named）→ 最接近的官方字号 class
String? _synoFontOfPt(String value) {
  final m = RegExp(r'([\d.]+)\s*(px|pt)').firstMatch(value);
  double? pt;
  if (m != null) {
    final v = double.tryParse(m.group(1)!) ?? 16;
    pt = m.group(2) == 'px' ? v * 0.75 : v;
  } else {
    const named = {
      'x-small': 10.0,
      'small': 12.0,
      'medium': 16.0,
      'large': 18.0,
      'x-large': 24.0,
      'xx-large': 36.0,
    };
    pt = named[value.trim().toLowerCase()];
  }
  if (pt == null) return null;
  const thresholds = [10.0, 12.0, 14.0, 16.0, 18.0, 24.0, 36.0];
  var best = 0;
  var bestDist = double.infinity;
  for (var i = 0; i < thresholds.length; i++) {
    final d = (thresholds[i] - pt).abs();
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  return kSynoFontSizes[best];
}

// ---------------------------------------------------------------- Delta → HTML

/// Quill Delta → NoteStation 用的 HTML。
///
/// 生成**朴素语义 HTML**（`<h2>` / `<ul><li>` / `<b>` …），官方编辑器
/// （WebView）能直接打开。
///
/// [refOf] 把图片 embed 的 `file_id` 换回附件 `ref`（服务端存的正文就是这个
/// 形态：`<img … ref="…">`）。没有对应 ref 时（新插入的图）用
/// [noteAttachmentRef] 生成一个，和官方 Web 端 `genUniqueImageRef` 同规则。
String noteDeltaToNoteHtml(
  List<Map<String, dynamic>> ops, {
  String? Function(String fileId)? refOf,
  bool Function(String fileId)? isPainting,
}) {
  final out = StringBuffer();
  for (final line in _groupLines(ops, refOf, isPainting)) {
    final attrs = line.lineAttrs;
    if (line.runs.isEmpty) {
      if (attrs.isEmpty) out.write('<p><br></p>');
      continue;
    }
    if (line.hasHr) {
      // 官方 `inserthorizontalrule` → `<hr>`
      out.write('<hr${_alignStyle(attrs)}>');
      continue;
    }
    final inner = line.html();
    final header = attrs['header'];
    if (attrs['code-block'] == true) {
      out.write('<pre>${_esc(line.text)}</pre>');
      continue;
    }
    if (header is int) {
      out.write(
        '<h$header${_alignStyle(attrs)}>${inner.isEmpty ? '<br>' : inner}</h$header>',
      );
      continue;
    }
    final listKind = attrs['list'];
    if (listKind == 'checked' || listKind == 'unchecked') {
      // 官方清单：一行一个 `<div>` + 勾选框（TinyMCE `syno_checkbox`），
      // **不是** `<ul>`；状态编码在 class 上。
      final box = noteCheckboxHtml('$listKind');
      out.write(
        '<div${_alignStyle(attrs)}>$box${inner.isEmpty ? '<br>' : inner}</div>',
      );
      continue;
    }
    if (listKind != null) {
      final ordered = listKind == 'ordered';
      final indent = (attrs['indent'] as int?) ?? 0;
      // 缩进用 `<ul>` 嵌套表达（NoteStation 编辑器也是这么存的）
      var open = '<ul>';
      var close = '</ul>';
      if (ordered) {
        open = '<ol>';
        close = '</ol>';
      }
      final buffer = StringBuffer();
      for (var i = 0; i <= indent; i++) {
        buffer.write(open);
      }
      buffer.write('<li>$inner</li>');
      for (var i = 0; i <= indent; i++) {
        buffer.write(close);
      }
      out.write(buffer.toString());
      continue;
    }
    if (attrs['blockquote'] == true) {
      out.write(
        '<blockquote${_alignStyle(attrs)}>${inner.isEmpty ? '<br>' : inner}</blockquote>',
      );
      continue;
    }
    out.write(
      '<p${_alignStyle(attrs)}>${inner.isEmpty ? '<br>' : inner}</p>',
    );
  }
  return out.toString();
}

/// 块级对齐的 inline style（官方 `justify*` 在 TinyMCE 里就是 `text-align`）
String _alignStyle(Map<String, dynamic> attrs) {
  final a = attrs['align'];
  if (a is! String || a.isEmpty) return '';
  return ' style="text-align:$a"';
}

class _Line {
  _Line(this.lineAttrs, [this.refOf, this.isPainting]);
  final Map<String, dynamic> lineAttrs;
  final String? Function(String fileId)? refOf;
  final bool Function(String fileId)? isPainting;
  final List<_Run> runs = [];

  /// 这一行是不是一条分割线（自定义块 embed `{'hr': ''}`）
  bool get hasHr => runs.any((r) => r.embed != null && r.embed!['hr'] != null);

  String get text => runs.map((r) => r.embed != null ? '' : r.text).join();

  String html() {
    final b = StringBuffer();
    for (final run in runs) {
      b.write(run.html());
    }
    return b.toString();
  }
}

class _Run {
  _Run(this.text, this.attrs, this.embed, [this.refOf, this.isPainting]);

  final String text;
  final Map<String, dynamic> attrs;
  final Map<String, dynamic>? embed;
  final String? Function(String fileId)? refOf;
  final bool Function(String fileId)? isPainting;

  String html() {
    final image = embed?['image'];
    if (image != null) {
      final id = '$image';
      // 解析不出原 ref 时原样留着（它本身就是个 ref），别凭空造一个新的
      final ref = refOf?.call(id) ?? id;
      // 手绘对象（`syno-dsnote-painting-object`）与普通图片只差一个 class
      return isPainting?.call(id) == true
          ? notePaintingHtml(ref)
          : noteImageHtml(ref);
    }
    if (text.isEmpty) return '';
    var out = _esc(text);
    if (attrs['code'] == true) out = '<code>$out</code>';
    if (attrs['bold'] == true) out = '<b>$out</b>';
    if (attrs['italic'] == true) out = '<i>$out</i>';
    if (attrs['underline'] == true) out = '<u>$out</u>';
    if (attrs['strike'] == true) out = '<s>$out</s>';
    if (attrs['script'] == 'sub') out = '<sub>$out</sub>';
    if (attrs['script'] == 'super') out = '<sup>$out</sup>';
    if (attrs['link'] != null) {
      out = '<a href="${_esc('${attrs['link']}')}">$out</a>';
    }
    final style = <String>[];
    if (attrs['color'] != null) style.add('color:${attrs['color']}');
    if (attrs['background'] != null) {
      style.add('background-color:${attrs['background']}');
    }
    // 字号：优先官方 `synofontsize` class；退回 Quill 原生 `size`
    final synoClass = _outputSynoFont(attrs);
    if (synoClass == null) {
      final size = attrs['size'];
      if (size is int) {
        // 历史形态（早期版本存的是 px 档位整数）
        const px = {10: 12, 12: 14, 14: 16, 18: 22, 22: 28, 26: 34};
        style.add('font-size:${px[size] ?? 16}px');
      }
    }
    if (style.isNotEmpty || synoClass != null) {
      final cls = synoClass == null ? '' : ' class="$synoClass"';
      final st = style.isEmpty ? '' : ' style="${style.join(';')}"';
      out = '<span$cls$st>$out</span>';
    }
    return out;
  }
}

/// 输出的官方字号 class（无法判定时 null）
String? _outputSynoFont(Map<String, dynamic> attrs) {
  final size = attrs['size'];
  if (size is String) {
    if (kSynoFontSizes.contains(size) || size == 'syno-fontsize-xxx-small') {
      return size;
    }
    return switch (size) {
      'small' => 'syno-fontsize-xx-small',
      'large' => 'syno-fontsize-large',
      'huge' => 'syno-fontsize-xx-large',
      _ => null,
    };
  }
  return null;
}

/// 把 Delta 按"行"分组：行内属性留在 run 上，行属性取自行尾的 `\n`
List<_Line> _groupLines(
  List<Map<String, dynamic>> ops, [
  String? Function(String fileId)? refOf,
  bool Function(String fileId)? isPainting,
]) {
  final lines = <_Line>[];
  var current = _Line(const {}, refOf, isPainting);
  for (final op in ops) {
    final rawAttrs = op['attributes'];
    final attrs = <String, dynamic>{
      ...?rawAttrs is Map ? rawAttrs.map((k, v) => MapEntry('$k', v)) : null,
    };
    final insert = op['insert'];
    if (insert is String) {
      final parts = insert.split('\n');
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        final endsLine = i < parts.length - 1;
        if (part.isNotEmpty) {
          current.runs.add(_Run(part, attrs, null, refOf, isPainting));
        }
        if (endsLine) {
          final line = _Line(attrs, refOf, isPainting);
          line.runs.addAll(current.runs);
          lines.add(line);
          current = _Line(const {}, refOf, isPainting);
        }
      }
    } else if (insert is Map) {
      current.runs.add(
        _Run('', attrs, Map<String, dynamic>.from(insert), refOf, isPainting),
      );
    }
  }
  if (current.runs.isNotEmpty) lines.add(current);
  if (lines.isEmpty) lines.add(_Line(const {}, refOf, isPainting));
  return lines;
}

/// 官方编辑器的图片片段（`syno_ddupload` 插入正文用的就是这一串）。
///
/// 真机实测：服务端**原样保存**这一串（不会把 `ref` 换成 `file_id`），
/// 附件表里的 `ref` 与它对应，客户端靠 `ref` 找 `file_id`。
String noteImageHtml(String ref) =>
    '<img class="syno-notestation-image-object" '
    'src="webman/3rdparty/NoteStation/images/transparent.gif" '
    'data-mce-src="webman/3rdparty/NoteStation/images/transparent.gif" '
    'ref="${_esc(ref)}" adjust="true">';

/// 手绘/涂鸦的 `ref` 标记类。官方 DS note 1.12.0-346 的编辑器
/// `assets/editor/syno-editor.js` `insertpainting.exec` 插入的 `<img>` 比普通图片
/// **只多这一个 class**（没有宽高/背景色等额外属性）：
/// `<img class="syno-notestation-image-object syno-dsnote-painting-object" …>`；
/// 点击时按它区分 `tapPainting` / `tapImage`（`JavascriptHandler.onPaintingTapped`）。
const String kNotePaintingClass = 'syno-dsnote-painting-object';

/// 手绘片段：在官方图片片段基础上加 [kNotePaintingClass]。
String notePaintingHtml(String ref) =>
    '<img class="syno-notestation-image-object $kNotePaintingClass" '
    'src="webman/3rdparty/NoteStation/images/transparent.gif" '
    'data-mce-src="webman/3rdparty/NoteStation/images/transparent.gif" '
    'ref="${_esc(ref)}" adjust="true">';

/// 元素的 class 里是否带手绘标记
bool _isPaintingElement(dom.Element el) {
  final cls = el.attributes['class'] ?? '';
  return cls.split(RegExp(r'\s+')).contains(kNotePaintingClass);
}

/// 从正文 HTML 里收集**手绘对象的 `ref`**。
///
/// 手绘在正文里与普通图片的唯一区别就是 [kNotePaintingClass]（官方
/// `syno-editor.js` `insertpainting` / `tapPainting`），所以"这条笔记里哪些图是
/// 手绘"只能从 HTML 读回来。编辑器拿它当 `isPainting` 判据，保存时把 class 原样写回
/// （Quill 的 image embed 不支持自定义键 —— `Embeddable.fromJson` 断言只有一个键）。
Set<String> notePaintingRefsFromHtml(String html) {
  if (html.trim().isEmpty) return const {};
  final refs = <String>{};
  for (final img in htmlp.parseFragment(html).querySelectorAll('img')) {
    if (!_isPaintingElement(img)) continue;
    final ref = img.attributes['ref'] ?? img.attributes['content_id'] ?? '';
    if (ref.isNotEmpty) refs.add(ref);
  }
  return refs;
}

/// 生成一个附件 ref —— 与官方 Web 端 `genUniqueImageRef` 同规则：
/// `base64(时间戳 + 文件名)`。
String noteAttachmentRef(String fileName) => base64Encode(
  utf8.encode('${DateTime.now().millisecondsSinceEpoch}$fileName'),
);

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
