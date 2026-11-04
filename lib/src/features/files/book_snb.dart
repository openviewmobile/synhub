// SNB 解析层 —— **纯 Dart**，不 import flutter / l10n。
//
// 口径修正（原先"公开信息不足"的判断已作废）：真正有公开实现的 `.snb` 是
// **盛大 Bambook / 云中书城** 的 `SNBP000B`，不是"书生之家"（后者没有任何
// 公开解析器）。参考实现是 calibre 的 `ebooks/snb/snbfile.py`（GPLv3，
// © 2010 Li Fanxi），字段语义已用真实样本（openpreserve/format-corpus 的
// CC0 `lorem-ipsum .snb`）逐字段核对。
//
// 容器（**多字节整数一律大端**）：
//   * 44 字节头：magic `SNBP000B` + rev80(0x8000) + revA3 + revZ1(0) + 文件数
//     + VFAT 解压后大小 + VFAT 压缩后大小 + 二进制流大小 + 文本流原始大小 + revZ2(0)；
//   * 紧跟一段 **zlib 压缩的 VFAT**：文件数 × 12 字节 `{attr, nameOffset, size}`
//     + NUL 分隔的 UTF-8 文件名；
//   * 文件体分两种：`attr == 0x41000000` 的文本/XML 放在 **bzip2** 压缩的
//     32KiB 块流里；`attr == 0x01000000` 的二进制（图片等）在 VFAT 之后**原样**串接；
//   * 文件尾最后 16 字节：`tailSize + tailOffset + magic`，指向一段 zlib 压缩的
//     **块偏移表 + 每个文件的 (blockIndex, contentOffset)**。
//
// 正文：`snbc/*.snbc` 是 `<snbc><head><title/><body><text><![CDATA[…]]></text>
// <img>…</img></body></snbc>`；`snbf/book.snbf` 给书名/作者/封面，
// `snbf/toc.snbf` 给目录（`<chapter src="…">标题</chapter>`）。
//
// **明确边界**：`SNBP0000` / `SNBP100B` 等其它 revision、以及**非** `SNBP000B`
// 的私有 SNB 方言一律走 [BookUnsupportedException]，绝不当成 `SNBP000B` 硬切。
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'book_encoding.dart';
import 'book_office.dart';
import 'book_package.dart';
import 'book_text.dart';
import 'book_xml.dart';
import 'file_book.dart';

/// Bambook SNB 的 magic
const List<int> _kSnbMagic = [
  0x53,
  0x4E,
  0x42,
  0x50,
  0x30,
  0x30,
  0x30,
  0x42,
]; // SNBP000B

/// 复合文档（OLE2/CFB）签名：另一种 SNB 包装
const List<int> _kCfbMagic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

/// `.snb` → [BookContent]。
///
/// 不是 SNB/文件坏了 → [FormatException]；
/// 是不认识的 SNB 方言 → [BookUnsupportedException]。
BookContent parseSnbBook(List<int> bytes, {required BookFormat format}) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (data.length < 8) throw const FormatException('SNB 头不完整');

  if (_startsWith(data, _kSnbMagic)) {
    return _parseBambookSnb(data, format);
  }
  // 认得出来、但不是我们实现了的 revision → 明确结论
  if (_startsWith(data, _ascii('SNBP')) && data.length >= 8) {
    throw BookUnsupportedException(
      '这是 SNB 家族但不认识的 revision（${_asciiStr(data, 0, 8)}），本阅读器只支持 SNBP000B',
    );
  }

  // 有导出器把 HTML/OPC 直接打进去：能读就读（不猜私有格式）
  if (bookBytesAreZip(data)) {
    final book = _snbFromZip(data, format);
    if (book != null) return book;
    throw BookUnsupportedException('这个 SNB 是 zip 容器，但里面没有可识别的 HTML/OPC 正文');
  }
  if (_startsWith(data, _kCfbMagic)) {
    throw BookUnsupportedException(
      'SNB 用 OLE2 复合文档包装，内部流布局缺少公开规范，本应用暂不支持打开',
    );
  }

  // 裸 HTML 的 SNB（少见但存在）
  final head = decodeBookText(
    data.length > 4096 ? data.sublist(0, 4096) : data,
  );
  if (RegExp(
    r'<\s*(?:!doctype|html|body)\b',
    caseSensitive: false,
  ).hasMatch(head)) {
    return parseHtmlBook(data, format: format, title: '');
  }

  throw BookUnsupportedException(
    '这个 SNB 不是 SNBP000B（盛大 Bambook）容器，也没有可识别的 HTML/OPC 正文；'
    '其它 SNB 方言缺少公开规范，本应用暂不支持打开',
  );
}

// ------------------------------------------------------------------ Bambook

/// 一个 VFAT 条目
class _SnbFile {
  _SnbFile(this.attr, this.name, this.size);
  final int attr;
  final String name;
  final int size;
  int blockIndex = 0;
  int contentOffset = 0;
  Uint8List body = Uint8List(0);

  bool get isPlain => attr & 0x41000000 == 0x41000000;
  bool get isBinary => attr & 0x01000000 == 0x01000000;
}

BookContent _parseBambookSnb(Uint8List data, BookFormat format) {
  if (data.length < 60) throw const FormatException('SNB 头不完整');
  if (!_matchesAt(data, data.length - 8, _kSnbMagic)) {
    throw const FormatException('SNB 尾部 magic 不匹配（文件被截断或被改动过）');
  }
  final fileCount = _i32be(data, 20);
  final vfatSize = _i32be(data, 24);
  final vfatCompressed = _i32be(data, 28);
  final binStreamSize = _i32be(data, 32);
  final plainUncompressed = _i32be(data, 36);
  if (_i32be(data, 8) != 0x00008000 ||
      _i32be(data, 12) != 0x00A3A3A3 ||
      _i32be(data, 16) != 0 ||
      _i32be(data, 40) != 0) {
    throw const FormatException('SNB 头部保留字段不符（不是 SNBP000B 布局）');
  }
  if (fileCount <= 0 || fileCount > 100000) {
    throw FormatException('SNB 的文件数不合理（$fileCount）');
  }
  if (vfatCompressed <= 0 || 44 + vfatCompressed > data.length) {
    throw const FormatException('SNB 的 VFAT 越界');
  }

  final Uint8List vfat;
  try {
    vfat = ZLibDecoder().decodeBytes(
      Uint8List.sublistView(data, 44, 44 + vfatCompressed),
    );
  } catch (_) {
    throw const FormatException('SNB 的 VFAT 解压失败（不是 zlib 数据）');
  }
  if (vfat.length != vfatSize) {
    throw FormatException('SNB 的 VFAT 长度不符（期望 $vfatSize，实际 ${vfat.length}）');
  }
  if (fileCount * 12 > vfat.length) {
    throw const FormatException('SNB 的 VFAT 条数越界');
  }

  // 文件名按 NUL 分隔，**按顺序**对应（calibre 也忽略 nameOffset）
  final nameBlob = vfat.sublist(fileCount * 12);
  final names = <String>[];
  for (final chunk in _splitNul(nameBlob)) {
    names.add(_utf8Loose(chunk));
  }
  final files = <_SnbFile>[];
  for (var i = 0; i < fileCount; i++) {
    final at = i * 12;
    files.add(
      _SnbFile(
        _i32be(vfat, at),
        i < names.length ? names[i] : '',
        _i32be(vfat, at + 8),
      ),
    );
  }

  // 尾部：块偏移表 + 每个文件的 (blockIndex, contentOffset)
  if (data.length < 16) throw const FormatException('SNB 尾部不完整');
  final tailSize = _i32be(data, data.length - 16);
  final tailOffset = _i32be(data, data.length - 12);
  if (tailOffset <= 0 || tailOffset + tailSize > data.length) {
    throw const FormatException('SNB 的尾部表越界');
  }
  final Uint8List tail;
  try {
    tail = ZLibDecoder().decodeBytes(
      Uint8List.sublistView(data, tailOffset, tailOffset + tailSize),
    );
  } catch (_) {
    throw const FormatException('SNB 的尾部表解压失败');
  }
  final binBlock = (binStreamSize + 0x8000 - 1) ~/ 0x8000;
  final plainBlock = (plainUncompressed + 0x8000 - 1) ~/ 0x8000;
  final blockCount = binBlock + plainBlock;
  if (tail.length < blockCount * 4 + fileCount * 8) {
    throw const FormatException('SNB 的尾部表长度不符');
  }
  final blockOffsets = <int>[
    for (var i = 0; i < blockCount; i++) _i32be(tail, i * 4),
  ];
  for (var i = 0; i < fileCount; i++) {
    final at = blockCount * 4 + i * 8;
    files[i].blockIndex = _i32be(tail, at);
    files[i].contentOffset = _i32be(tail, at + 4);
  }

  // 文本流：bzip2 压缩的 32KiB 块（块本身若没压缩就是原样）
  final plain = _decodePlainStream(
    data,
    files: files,
    blockOffsets: blockOffsets,
    binBlock: binBlock,
    plainBlock: plainBlock,
    tailOffset: tailOffset,
  );
  if (plainUncompressed >= 0 && plain.length != plainUncompressed) {
    throw FormatException(
      'SNB 文本流长度不符（期望 $plainUncompressed，实际 ${plain.length}）',
    );
  }

  var plainPos = 0;
  var binPos = 0;
  for (final f in files) {
    if (f.size < 0) throw const FormatException('SNB 条目长度非法');
    if (f.isPlain) {
      if (plainPos + f.size > plain.length) {
        throw const FormatException('SNB 文本条目越界');
      }
      f.body = Uint8List.sublistView(plain, plainPos, plainPos + f.size);
      plainPos += f.size;
    } else if (f.isBinary) {
      final at = 44 + vfatCompressed + binPos;
      if (at + f.size > data.length) {
        throw const FormatException('SNB 二进制条目越界');
      }
      f.body = Uint8List.sublistView(data, at, at + f.size);
      binPos += f.size;
    } else {
      throw FormatException('SNB 条目类型不认识（attr=0x${f.attr.toRadixString(16)}）');
    }
  }

  // 元数据
  final bookSnbf = _findFile(files, 'snbf/book.snbf');
  final tocSnbf = _findFile(files, 'snbf/toc.snbf');
  var title = '';
  var author = '';
  var coverName = '';
  if (bookSnbf != null) {
    final root = parseBookXmlBytes(bookSnbf.body);
    if (root != null) {
      title = root.first('name')?.text.trim() ?? '';
      author = root.first('author')?.text.trim() ?? '';
      coverName = root.first('cover')?.text.trim() ?? '';
    }
  }

  // 目录：src → 标题（按出现顺序）
  final tocTitles = <String, String>{};
  final tocOrder = <String>[];
  if (tocSnbf != null) {
    final root = parseBookXmlBytes(tocSnbf.body);
    if (root != null) {
      for (final c in root.descendants('chapter')) {
        final src = c.attr('src') ?? '';
        if (src.isEmpty) continue;
        tocTitles[src.toLowerCase()] = c.text.trim();
        tocOrder.add(src.toLowerCase());
      }
    }
  }

  // 正文：按目录顺序取 snbc 页；没有目录就按 VFAT 顺序
  final snbcFiles = files.where((f) => f.name.toLowerCase().endsWith('.snbc'));
  final byName = <String, _SnbFile>{
    for (final f in snbcFiles) f.name.toLowerCase(): f,
  };
  final ordered = <_SnbFile>[];
  for (final src in tocOrder) {
    final f = byName[src];
    if (f != null && !ordered.contains(f)) ordered.add(f);
  }
  for (final f in snbcFiles) {
    if (!ordered.contains(f)) ordered.add(f);
  }
  if (ordered.isEmpty) {
    throw const FormatException('SNB 里没有 snbc 正文页');
  }

  // 图片资源：二进制里的图片文件，键用小写全名 + 裸文件名
  final resources = <String, Uint8List>{};
  for (final f in files) {
    if (!f.isBinary) continue;
    if (bookImageKindOfBytes(f.body) == null &&
        !bookLooksLikeImagePath(f.name)) {
      continue;
    }
    final key = f.name.toLowerCase();
    resources[key] = f.body;
    resources.putIfAbsent(key.split('/').last, () => f.body);
  }

  final chapters = <BookChapter>[];
  final toc = <BookTocEntry>[];
  for (final f in ordered) {
    final html = _snbcToHtml(f.body);
    if (html.isEmpty) continue;
    final snbcRoot = parseBookXmlBytes(f.body);
    final ownTitle = snbcRoot?.first('title')?.text.trim() ?? '';
    final title = ownTitle.isNotEmpty
        ? ownTitle
        : (tocTitles[f.name.toLowerCase()] ?? '').isNotEmpty
        ? tocTitles[f.name.toLowerCase()]!
        : f.name.split('/').last;
    final index = chapters.length;
    chapters.add(BookChapter(title: title, html: html));
    toc.add(BookTocEntry(title: title, chapterIndex: index));
  }
  if (chapters.isEmpty) {
    throw const FormatException('SNB 的 snbc 页里没有正文');
  }

  // 封面：book.snbf 的 <cover> 指向的文件；找不到就用第一张图
  if (coverName.isNotEmpty) {
    final key = coverName.toLowerCase();
    final f = _findFile(files, key) ?? _findFile(files, key.split('/').last);
    if (f != null && f.isBinary) {
      resources[key] = f.body;
    }
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

/// 文本流：`plainBlock` 个块，每块是 bzip2 流（未压缩的块原样拼接）
Uint8List _decodePlainStream(
  Uint8List data, {
  required List<_SnbFile> files,
  required List<int> blockOffsets,
  required int binBlock,
  required int plainBlock,
  required int tailOffset,
}) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < plainBlock; i++) {
    final start = blockOffsets[binBlock + i];
    final end = i < plainBlock - 1
        ? blockOffsets[binBlock + i + 1]
        : tailOffset;
    if (start < 0 || end < start || end > data.length) {
      throw const FormatException('SNB 文本块偏移越界');
    }
    final block = Uint8List.sublistView(data, start, end);
    if (_startsWith(block, const [0x42, 0x5A, 0x68])) {
      // `BZh` → bzip2 流
      try {
        out.add(BZip2Decoder().decodeBytes(block));
      } catch (_) {
        throw const FormatException('SNB 文本块 bzip2 解压失败');
      }
    } else {
      out.add(block);
    }
  }
  return out.takeBytes();
}

/// `<snbc>` → 我们能渲染的 HTML：`<text>`（CDATA）成段、`<img>` 成图
String _snbcToHtml(Uint8List body) {
  final root = parseBookXmlBytes(body);
  if (root == null) return '';
  final out = StringBuffer();
  void walk(BookXmlNode n) {
    for (final c in n.children) {
      switch (c.local) {
        case 'text':
          final t = c.text;
          if (t.trim().isNotEmpty) {
            out.write('<p>${bookEscapeHtml(t.trim())}</p>');
          }
        case 'img':
          final src = c.text.trim().toLowerCase();
          if (src.isNotEmpty) {
            out.write('<p><img src="${bookEscapeAttr(src)}" alt=""/></p>');
          }
        case 'title':
        case 'head':
          break; // 标题由章节标题呈现
        default:
          walk(c);
      }
    }
  }

  walk(root);
  return out.toString();
}

_SnbFile? _findFile(List<_SnbFile> files, String name) {
  final n = name.toLowerCase();
  for (final f in files) {
    if (f.name.toLowerCase() == n) return f;
  }
  return null;
}

/// zip 容器里的 SNB：找 HTML/OPF/纯文本，走已有解析器。
BookContent? _snbFromZip(Uint8List data, BookFormat format) {
  final Map<String, Uint8List> files;
  try {
    files = unzipBookPackage(data, 'SNB');
  } catch (_) {
    return null;
  }
  final keys = files.keys.toList()..sort();
  final opfKey = keys.where((k) => k.endsWith('.opf')).firstOrNull;
  if (opfKey != null) {
    try {
      final book = parseOpfBook(
        files[opfKey]!,
        format: format,
        siblings: files,
        opfPath: opfKey,
      );
      if (book.chapters.isNotEmpty) return book;
    } catch (_) {
      // 落到下面的 HTML 分支
    }
  }
  for (final k in keys) {
    if (!k.endsWith('.html') && !k.endsWith('.htm') && !k.endsWith('.xhtml')) {
      continue;
    }
    final raw = files[k];
    if (raw == null) continue;
    final book = parseHtmlBook(raw, format: format, title: '', siblings: files);
    if (book.chapters.isNotEmpty) return book;
  }
  for (final k in keys) {
    if (!k.endsWith('.txt')) continue;
    final raw = files[k];
    if (raw == null) continue;
    final book = parseTxtBook(raw, format: format, title: '');
    if (book.chapters.isNotEmpty) return book;
  }
  return null;
}

/// 给探针用：SNB 容器摘要
Map<String, Object?> snbProbe(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final head = decodeBookText(data.length > 512 ? data.sublist(0, 512) : data);
  return {
    'ok': true,
    'size': data.length,
    'bambook': _startsWith(data, _kSnbMagic),
    'magic': data.length >= 8 ? _asciiStr(data, 0, 8) : '',
    'zip': bookBytesAreZip(data),
    'cfb': _startsWith(data, _kCfbMagic),
    'html': RegExp(
      r'<\s*(?:!doctype|html|body)\b',
      caseSensitive: false,
    ).hasMatch(head),
    'first16': data
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(),
  };
}

/// 给探针/测试用：Bambook SNB 的文件表摘录
Map<String, Object?> snbFileProbe(List<int> bytes) {
  try {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (!_startsWith(data, _kSnbMagic)) {
      return {'ok': false, 'reason': 'not SNBP000B'};
    }
    final book = _parseBambookSnb(data, BookFormat.snb);
    return {
      'ok': true,
      'title': book.title,
      'author': book.author,
      'chapters': book.chapters.length,
      'images': book.resources.length,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}

// ------------------------------------------------------------------ 工具

List<Uint8List> _splitNul(Uint8List blob) {
  final out = <Uint8List>[];
  var start = 0;
  for (var i = 0; i < blob.length; i++) {
    if (blob[i] == 0) {
      out.add(Uint8List.sublistView(blob, start, i));
      start = i + 1;
    }
  }
  if (start < blob.length) out.add(Uint8List.sublistView(blob, start));
  return out;
}

String _utf8Loose(Uint8List b) => decodeBookText(b);

bool _startsWith(Uint8List data, List<int> prefix) =>
    _matchesAt(data, 0, prefix);

bool _matchesAt(Uint8List data, int offset, List<int> bytes) {
  if (offset < 0 || offset + bytes.length > data.length) return false;
  for (var i = 0; i < bytes.length; i++) {
    if (data[offset + i] != bytes[i]) return false;
  }
  return true;
}

List<int> _ascii(String s) => s.codeUnits;

String _asciiStr(Uint8List b, int offset, int length) {
  if (offset + length > b.length) return '';
  return String.fromCharCodes(b.sublist(offset, offset + length));
}

int _i32be(Uint8List b, int o) {
  if (o < 0 || o + 4 > b.length) return 0;
  return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
}
