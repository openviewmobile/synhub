// 极简 XML 解析器（**纯 Dart**）—— DOCX / ODT / OPF 这类"真 XML"用它。
//
// 为什么不直接用 `package:html`：它是 **HTML 解析器**，对 XML 有两个要命的习惯：
//   1. 自闭合标签（`<w:br/>`、`<text:span/>`）会被当成"没闭合的开始标签"，
//      后面的兄弟节点全部**嵌进它里面**（`file_book.dart` 里 OPF 的 manifest
//      就踩过：几十个 `<item/>` 只有一个能被直接子选择器拿到）；
//   2. 标签名连命名空间前缀一起保留，`querySelector('title')` 匹配不到
//      `<dc:title>`。
//
// DOCX/ODT 的正文里自闭合标签遍地都是（换行、制表、图片、空段落属性），
// 所以这批 office 格式自己带一个"够用就好"的 XML DOM：元素 / 属性 / 文本 /
// CDATA / 注释 / 实体引用，前缀统一剥成本地名（`w:val` → `val`）。
//
// 它**不是**通用的 XML 校验器：不校验配对、不展开 DTD、不保留命名空间语义。
// 对"把正文抠出来"这个目的足够了。
import 'dart:convert';
import 'dart:typed_data';

import 'book_encoding.dart';

/// 一个 XML 元素
class BookXmlNode {
  BookXmlNode(this.name);

  /// 原始标签名（可能含前缀，如 `w:p`）
  final String name;

  /// 属性：**本地名**（去前缀、小写） → 值
  final Map<String, String> attributes = {};

  final List<BookXmlNode> children = [];

  /// **有序**内容：元素是 [BookXmlNode]，文本是 [String]。
  ///
  /// ⚠️ ODT/DOCX 是混合内容（`<text:p>普通<span>粗</span>正文</text:p>`），
  /// 只靠 `children` + `text` 会把"普通/正文"这样的裸文本整段丢掉（真踩过：
  /// ODT 段落只剩加粗那两个字）。所以文本与子元素的**相对顺序**必须留着。
  final List<Object> content = [];

  /// 直接文本片段（按出现顺序拼接）
  final List<String> textChunks = [];

  String get text => textChunks.join();

  void addText(String chunk) {
    if (chunk.isEmpty) return;
    textChunks.add(chunk);
    if (content.isNotEmpty && content.last is String) {
      content[content.length - 1] = (content.last as String) + chunk;
    } else {
      content.add(chunk);
    }
  }

  void addChild(BookXmlNode node) {
    children.add(node);
    content.add(node);
  }

  /// 去前缀、小写的标签名
  String get local => localNameOf(name);

  String? attr(String local) => attributes[local];

  /// 深度优先找**所有**后代（含自己）
  Iterable<BookXmlNode> descendants(String local) sync* {
    if (this.local == local) yield this;
    for (final c in children) {
      yield* c.descendants(local);
    }
  }

  /// 找第一个后代
  BookXmlNode? first(String local) {
    for (final n in descendants(local)) {
      return n;
    }
    return null;
  }

  /// 直接子元素里找
  BookXmlNode? child(String local) {
    for (final c in children) {
      if (c.local == local) return c;
    }
    return null;
  }

  /// 直接子元素里找全部
  Iterable<BookXmlNode> childrenNamed(String local) =>
      children.where((c) => c.local == local);
}

/// `w:p` → `p`（去前缀、小写）
String localNameOf(String name) {
  final i = name.indexOf(':');
  final n = i < 0 ? name : name.substring(i + 1);
  return n.toLowerCase();
}

/// `dc:title` 的属性 → 本地名同理
String _localAttr(String name) {
  final i = name.indexOf(':');
  final n = i < 0 ? name : name.substring(i + 1);
  return n.toLowerCase();
}

/// 解析一段 XML 文本；[bytes] 版本会先做编码探测。
BookXmlNode? parseBookXml(String raw) {
  final p = _XmlReader(raw);
  return p.parseDocument();
}

/// 从字节解析（先做编码探测，兼容带 BOM / UTF-16 的 XML）
BookXmlNode? parseBookXmlBytes(List<int> bytes) =>
    parseBookXml(detectAndDecodeBookText(bytes).text);

class _XmlReader {
  _XmlReader(this.s);
  final String s;
  int i = 0;

  BookXmlNode? parseDocument() {
    final root = BookXmlNode('#document');
    while (i < s.length) {
      final lt = s.indexOf('<', i);
      if (lt < 0) {
        root.addText(_decodeEntities(s.substring(i)));
        break;
      }
      if (lt > i) root.addText(_decodeEntities(s.substring(i, lt)));
      i = lt;
      if (_startsWith('<?')) {
        final end = s.indexOf('?>', i);
        i = end < 0 ? s.length : end + 2;
        continue;
      }
      if (_startsWith('<!--')) {
        final end = s.indexOf('-->', i);
        i = end < 0 ? s.length : end + 3;
        continue;
      }
      if (_startsWith('<![CDATA[')) {
        final end = s.indexOf(']]>', i);
        if (end < 0) {
          root.addText(s.substring(i + 9));
          i = s.length;
        } else {
          root.addText(s.substring(i + 9, end));
          i = end + 3;
        }
        continue;
      }
      if (_startsWith('<!')) {
        final end = s.indexOf('>', i);
        i = end < 0 ? s.length : end + 1;
        continue;
      }
      if (_startsWith('</')) {
        // 文档级多余闭合标签：忽略
        final end = s.indexOf('>', i);
        i = end < 0 ? s.length : end + 1;
        continue;
      }
      final node = _parseElement();
      if (node != null) root.addChild(node);
    }
    return root;
  }

  bool _startsWith(String t) => s.startsWith(t, i);

  BookXmlNode? _parseElement() {
    if (i >= s.length || s[i] != '<') return null;
    i++;
    final nameStart = i;
    while (i < s.length && !_isSpace(s[i]) && s[i] != '/' && s[i] != '>') {
      i++;
    }
    if (i == nameStart) return null;
    final name = s.substring(nameStart, i);
    final node = BookXmlNode(name);

    // 属性
    while (i < s.length) {
      while (i < s.length && _isSpace(s[i])) {
        i++;
      }
      if (i >= s.length) break;
      if (s[i] == '/') {
        i++;
        if (i < s.length && s[i] == '>') i++;
        return node; // 自闭合
      }
      if (s[i] == '>') {
        i++;
        break;
      }
      final aStart = i;
      while (i < s.length &&
          !_isSpace(s[i]) &&
          s[i] != '=' &&
          s[i] != '/' &&
          s[i] != '>') {
        i++;
      }
      if (i == aStart) {
        i++;
        continue;
      }
      final aName = s.substring(aStart, i);
      while (i < s.length && _isSpace(s[i])) {
        i++;
      }
      var value = '';
      if (i < s.length && s[i] == '=') {
        i++;
        while (i < s.length && _isSpace(s[i])) {
          i++;
        }
        if (i < s.length && (s[i] == '"' || s[i] == "'")) {
          final q = s[i];
          i++;
          final vStart = i;
          while (i < s.length && s[i] != q) {
            i++;
          }
          value = s.substring(vStart, i);
          if (i < s.length) i++;
        }
      }
      node.attributes[_localAttr(aName)] = _decodeEntities(value);
    }

    // 内容直到配对闭合标签
    while (i < s.length) {
      final lt = s.indexOf('<', i);
      if (lt < 0) {
        node.addText(_decodeEntities(s.substring(i)));
        i = s.length;
        break;
      }
      if (lt > i) node.addText(_decodeEntities(s.substring(i, lt)));
      i = lt;
      if (_startsWith('<!--')) {
        final end = s.indexOf('-->', i);
        i = end < 0 ? s.length : end + 3;
        continue;
      }
      if (_startsWith('<![CDATA[')) {
        final end = s.indexOf(']]>', i);
        if (end < 0) {
          node.addText(s.substring(i + 9));
          i = s.length;
        } else {
          node.addText(s.substring(i + 9, end));
          i = end + 3;
        }
        continue;
      }
      if (_startsWith('<?')) {
        final end = s.indexOf('?>', i);
        i = end < 0 ? s.length : end + 2;
        continue;
      }
      if (_startsWith('</')) {
        final end = s.indexOf('>', i);
        i = end < 0 ? s.length : end + 1;
        return node;
      }
      if (_startsWith('<!')) {
        final end = s.indexOf('>', i);
        i = end < 0 ? s.length : end + 1;
        continue;
      }
      final child = _parseElement();
      if (child != null) {
        node.addChild(child);
      } else {
        i++; // 防死循环
      }
    }
    return node;
  }

  bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

String _decodeEntities(String s) {
  if (!s.contains('&')) return s;
  final buf = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final amp = s.indexOf('&', i);
    if (amp < 0) {
      buf.write(s.substring(i));
      break;
    }
    buf.write(s.substring(i, amp));
    final semi = s.indexOf(';', amp);
    if (semi < 0 || semi - amp > 12) {
      buf.write('&');
      i = amp + 1;
      continue;
    }
    final entity = s.substring(amp + 1, semi);
    final replaced = _entityValue(entity);
    if (replaced == null) {
      buf.write('&');
      i = amp + 1;
    } else {
      buf.write(replaced);
      i = semi + 1;
    }
  }
  return buf.toString();
}

String? _entityValue(String entity) {
  switch (entity) {
    case 'amp':
      return '&';
    case 'lt':
      return '<';
    case 'gt':
      return '>';
    case 'quot':
      return '"';
    case 'apos':
      return "'";
    case 'nbsp':
      return '\u00A0';
  }
  if (entity.startsWith('#x') || entity.startsWith('#X')) {
    final v = int.tryParse(entity.substring(2), radix: 16);
    return v == null ? null : String.fromCharCode(v);
  }
  if (entity.startsWith('#')) {
    final v = int.tryParse(entity.substring(1));
    return v == null ? null : String.fromCharCode(v);
  }
  return null;
}

/// 给探针用：报告 XML 的元素数（不落 BookContent）
Map<String, Object?> bookXmlProbe(List<int> bytes) {
  try {
    final root = parseBookXmlBytes(bytes);
    if (root == null) return const {'ok': false};
    var n = 0;
    for (final _ in root.descendants('#document')) {
      n++;
    }
    return {
      'ok': true,
      'roots': root.children.length,
      'elements': root.children.fold<int>(0, (a, c) => a + _count(c)),
      'document': n,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}

int _count(BookXmlNode n) =>
    1 + n.children.fold<int>(0, (a, c) => a + _count(c));

/// 探测辅助：把字节当 UTF-8 读（探针用，容错）
String utf8OrLatin1(List<int> bytes) =>
    utf8.decode(Uint8List.fromList(bytes), allowMalformed: true);
