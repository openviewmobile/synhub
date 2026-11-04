// RB（Rocket eBook / REB 1100/1200）解析层 —— **纯 Dart**，不 import flutter / l10n。
//
// 格式来源：rbmake v1.2（Wayne Davison，Artistic License）的事实实现 +
// `rb_format.html` 的字段说明；字段语义已用真实样本（openpreserve/format-corpus
// 的 CC0 lorem-ipsum `.rb`）逐字段核对。
//
// 布局（**多字节整数一律小端**）：
//
//   * 头：偏移 0 的 magic `B0 0C B0 0C`（另一支是 `B0 0C F0 0D`），偏移 4 的
//     int16 版本、偏移 6 的 `NUVO`、偏移 0x0E 的年/月/日；
//   * 偏移 **0x18** 是 ToC 偏移、**0x1C** 是文件长度（都 int32 LE）；
//   * ToC：`int32 条数` + N×44 字节条目 `{name[32], int32 length, int32 pos,
//     int32 flags}`；`pos` 是**绝对文件偏移**；
//   * 页类型看后缀：`.html`/`.htm` 正文、`.png` 图片、`.txt` 文本、
//     `.info` 元信息（明文 `NAME=VALUE`）、`.hidx`/`.hkey` 索引（跳过）；
//   * flags：`0x0001` 加密、`0x0002` 信息页、`0x0008` zlib 压缩；
//   * 压缩页：`int32 pieces` + `int32 解压后长度` + `pieces×int32 各块压缩长度`
//     + 各块**独立 zlib 流**（RFC1950，rbmake 用 windowBits=13）顺序拼接；
//     小于 128 字节的页不压缩；
//   * 图片就是**裸 PNG**，没有单独的偏移表（位置由 ToC 条目给）。
//
// **明确边界**：加密页（flag 0x0001）不做 —— 公开信息里没有密钥/算法，硬切只会
// 吐乱码；整本书只要正文页加密就走 `BookUnsupportedException`。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as htmlp;

import 'book_encoding.dart';
import 'file_book.dart';
import 'book_text.dart';

/// 两种已知 magic（第二种见于个别 ReB 文件）
const List<List<int>> _kRbMagics = [
  [0xB0, 0x0C, 0xB0, 0x0C],
  [0xB0, 0x0C, 0xF0, 0x0D],
];

const int _kFlagEncrypted = 0x0001;
const int _kFlagInfoPage = 0x0002;
const int _kFlagDeflated = 0x0008;

/// `.rb` → [BookContent]。
///
/// 文件坏了/不是 RB → [FormatException]；加密正文 → [BookUnsupportedException]。
BookContent parseRbBook(List<int> bytes, {required BookFormat format}) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (data.length < 0x20) throw const FormatException('RB 头不完整');
  if (!_kRbMagics.any((m) => _matches(data, 0, m))) {
    throw const FormatException('不是 Rocket eBook（RB）文件：magic 不匹配');
  }
  final tocOffset = _u32le(data, 0x18);
  if (tocOffset <= 0 || tocOffset + 4 > data.length) {
    throw const FormatException('RB 的 ToC 偏移越界');
  }
  final count = _u32le(data, tocOffset);
  if (count <= 0 || count > 100000) {
    throw FormatException('RB 的 ToC 条数不合理（$count）');
  }
  if (tocOffset + 4 + count * 44 > data.length) {
    throw const FormatException('RB 的 ToC 越界');
  }

  final entries = <_RbEntry>[];
  for (var i = 0; i < count; i++) {
    final at = tocOffset + 4 + i * 44;
    final name = _entryName(data, at);
    entries.add(
      _RbEntry(
        name: name,
        length: _u32le(data, at + 32),
        pos: _u32le(data, at + 36),
        flags: _u32le(data, at + 40),
      ),
    );
  }

  // 信息页（flags & 2 或 .info 后缀）：明文 NAME=VALUE
  final info = <String, String>{};
  for (final e in entries) {
    if (e.flags & _kFlagInfoPage == 0 &&
        !e.name.toLowerCase().endsWith('.info')) {
      continue;
    }
    final raw = _pageData(data, e);
    if (raw == null) continue;
    info.addAll(_parseInfoPage(raw));
  }

  // 加密判定：正文/文本页加密就没法读
  for (final e in entries) {
    if (e.flags & _kFlagEncrypted == 0) continue;
    if (_kindOf(e.name) == _RbKind.html || _kindOf(e.name) == _RbKind.text) {
      throw BookUnsupportedException(
        '这本 RB 的正文页带版权保护（加密），本阅读器不解密',
        reason: BookUnsupportedReason.encrypted,
      );
    }
  }

  // 图片资源：裸 PNG，按小写归一化名（渲染层按 src 查）
  final resources = <String, Uint8List>{};
  for (final e in entries) {
    if (_kindOf(e.name) != _RbKind.image) continue;
    if (e.flags & _kFlagEncrypted != 0) continue;
    final raw = _pageData(data, e);
    if (raw == null) continue;
    final key = e.name.toLowerCase();
    resources[key] = raw;
    final bare = key.split('/').last;
    resources.putIfAbsent(bare, () => raw);
  }

  // 正文：ToC 顺序里的 html 页，每页走已有 HTML 解析管线
  final chapters = <BookChapter>[];
  final toc = <BookTocEntry>[];
  for (final e in entries) {
    final kind = _kindOf(e.name);
    if (kind != _RbKind.html && kind != _RbKind.text) continue;
    if (e.flags & _kFlagEncrypted != 0) continue;
    final raw = _pageData(data, e);
    if (raw == null || raw.isEmpty) continue;
    final decoded = detectAndDecodeBookText(raw).text;
    final List<BookChapter> pageChapters;
    if (kind == _RbKind.text) {
      pageChapters = bookFromPlainText(
        decoded,
        format: format,
        title: '',
      ).chapters;
    } else {
      pageChapters = parseHtmlBook(
        raw,
        format: format,
        title: '',
        siblings: resources,
      ).chapters;
    }
    final pageTitle = _pageTitle(detectAndDecodeBookText(raw).text, e.name);
    for (final ch in pageChapters) {
      // 单页没有标题时，用 `<title>` / 文件名兜底，别让目录里出现一堆"正文"
      final generated = ch.generatedUnit == BookGeneratedUnit.body;
      final title = generated ? pageTitle : ch.title;
      final index = chapters.length;
      chapters.add(
        BookChapter(
          title: title,
          generatedUnit: generated ? null : ch.generatedUnit,
          html: ch.html,
        ),
      );
      toc.add(BookTocEntry(title: title, chapterIndex: index));
    }
  }
  if (chapters.isEmpty) {
    throw const FormatException('RB 里没有可读的正文页（html/txt）');
  }

  return BookContent(
    format: format,
    title: info['TITLE'] ?? '',
    author: info['AUTHOR'] ?? '',
    chapters: chapters,
    toc: toc,
    resources: resources,
  );
}

/// 探测用：RB 头部/ToC 摘要（不落 [BookContent]）
Map<String, Object?> rbProbe(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (data.length < 0x20) return {'ok': false, 'size': data.length};
  final magic = data
      .take(4)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final known = _kRbMagics.any((m) => _matches(data, 0, m));
  if (!known) return {'ok': false, 'rb': false, 'magic': magic};
  final tocOffset = _u32le(data, 0x18);
  final count = tocOffset + 4 <= data.length ? _u32le(data, tocOffset) : 0;
  return {
    'ok': true,
    'rb': true,
    'magic': magic,
    'version': _u16le(data, 4),
    'tocOffset': tocOffset,
    'fileLength': _u32le(data, 0x1C),
    'entries': count,
  };
}

/// 从 RB 抠封面：ToC 里第一张 PNG。
Uint8List? rbCoverBytes(Uint8List bytes) {
  try {
    final data = bytes;
    if (data.length < 0x20) return null;
    if (!_kRbMagics.any((m) => _matches(data, 0, m))) return null;
    final tocOffset = _u32le(data, 0x18);
    if (tocOffset <= 0 || tocOffset + 4 > data.length) return null;
    final count = _u32le(data, tocOffset);
    if (count <= 0 || tocOffset + 4 + count * 44 > data.length) return null;
    for (var i = 0; i < count; i++) {
      final at = tocOffset + 4 + i * 44;
      final e = _RbEntry(
        name: _entryName(data, at),
        length: _u32le(data, at + 32),
        pos: _u32le(data, at + 36),
        flags: _u32le(data, at + 40),
      );
      if (_kindOf(e.name) != _RbKind.image) continue;
      if (e.flags & _kFlagEncrypted != 0) continue;
      return _pageData(data, e);
    }
    return null;
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------------ 内部

// 注意：不能叫 `index` —— enum 自带实例成员 `index`，同名会编译不过。
enum _RbKind { html, text, image, info, hidx, other }

_RbKind _kindOf(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.html') || n.endsWith('.htm')) return _RbKind.html;
  if (n.endsWith('.txt')) return _RbKind.text;
  if (n.endsWith('.png')) return _RbKind.image;
  if (n.endsWith('.info')) return _RbKind.info;
  if (n.endsWith('.hidx') || n.endsWith('.hkey')) return _RbKind.hidx;
  return _RbKind.other;
}

class _RbEntry {
  _RbEntry({
    required this.name,
    required this.length,
    required this.pos,
    required this.flags,
  });
  final String name;
  final int length;
  final int pos;
  final int flags;
}

/// ToC 条目里的 `name[32]`（NUL 截断）
String _entryName(Uint8List data, int at) {
  final raw = data.sublist(at, at + 32);
  var end = raw.indexOf(0);
  if (end < 0) end = raw.length;
  return String.fromCharCodes(raw.sublist(0, end));
}

/// 取一个页面的**原始/解压后**字节；越界返回 null。
Uint8List? _pageData(Uint8List data, _RbEntry e) {
  if (e.length < 0 || e.pos < 0 || e.pos + e.length > data.length) return null;
  final raw = Uint8List.sublistView(data, e.pos, e.pos + e.length);
  if (e.flags & _kFlagDeflated == 0) return raw;
  return _rbInflate(raw);
}

/// RB 的压缩页：多块独立 zlib 流。
///
/// 布局（小端）：`int32 pieces` + `int32 解压后长度` + `pieces×int32 各块压缩长度`
/// + 各块 zlib 数据。任一块坏掉就抛 [FormatException]（不吐半截）。
Uint8List _rbInflate(Uint8List raw) {
  if (raw.length < 8) throw const FormatException('RB 压缩页头不完整');
  final pieces = _u32le(raw, 0);
  final inflated = _u32le(raw, 4);
  if (pieces <= 0 || pieces > 4096) {
    throw FormatException('RB 压缩页块数不合理（$pieces）');
  }
  if (8 + pieces * 4 > raw.length) {
    throw const FormatException('RB 压缩页块长度表越界');
  }
  final lens = <int>[];
  for (var i = 0; i < pieces; i++) {
    lens.add(_u32le(raw, 8 + i * 4));
  }
  final out = BytesBuilder(copy: false);
  var at = 8 + pieces * 4;
  for (final len in lens) {
    if (at + len > raw.length) throw const FormatException('RB 压缩块越界');
    final chunk = Uint8List.sublistView(raw, at, at + len);
    at += len;
    final decoded = ZLibDecoder().decodeBytes(chunk);
    out.add(decoded);
  }
  final result = out.takeBytes();
  if (result.length != inflated) {
    throw FormatException('RB 压缩页解压长度不符（期望 $inflated，实际 ${result.length}）');
  }
  return result;
}

/// `.info` 页：明文 `NAME=VALUE` 行
Map<String, String> _parseInfoPage(Uint8List raw) {
  final text = detectAndDecodeBookText(raw).text;
  final out = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    final i = line.indexOf('=');
    if (i <= 0) continue;
    final k = line.substring(0, i).trim().toUpperCase();
    final v = line.substring(i + 1).trim();
    if (k.isEmpty || v.isEmpty) continue;
    out[k] = v;
  }
  return out;
}

/// 页面标题：先 `<title>`，再第一个 `<h1>`，最后退到 ToC 文件名（去后缀）
String _pageTitle(String html, String name) {
  final doc = _tryParse(html);
  if (doc != null) {
    final t = doc.querySelector('title')?.text.trim() ?? '';
    if (t.isNotEmpty) return t;
    final h = doc.querySelector('h1')?.text.trim() ?? '';
    if (h.isNotEmpty) return h;
  }
  final base = name.split('/').last;
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

/// 只在 HTML 解析失败时返回 null（`package:html` 对垃圾输入也会给个空文档）
dom.Document? _tryParse(String html) {
  try {
    return htmlp.parse(html);
  } catch (_) {
    return null;
  }
}

bool _matches(Uint8List data, int offset, List<int> bytes) {
  if (offset + bytes.length > data.length) return false;
  for (var i = 0; i < bytes.length; i++) {
    if (data[offset + i] != bytes[i]) return false;
  }
  return true;
}

int _u16le(Uint8List b, int o) => o + 2 > b.length ? 0 : b[o] | (b[o + 1] << 8);

int _u32le(Uint8List b, int o) => o + 4 > b.length
    ? 0
    : b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
