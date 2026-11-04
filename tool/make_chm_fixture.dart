// 生成**自造的最小 CHM（ITSF + ITSP/PMGL + LZX）**，供离线测试与真机验证用
// （不下载任何真实 CHM）。
//
//   dart run tool/make_chm_fixture.dart [输出目录]
//
// 产物：
//   * `chm-verify.chm` —— 合法 CHM v3：中文正文（UTF-8 / GBK / UTF-16LE 三种编码）、
//     hhc 三层嵌套目录、一张棋盘 PNG、正文由 **LZX 未压缩块** 承载；
//   * `chm-broken-truncated.chm` —— 尾部截断（读控制数据/正文时报"坏文件"）；
//   * `chm-unsupported-lzxblock.chm` —— LZX 块类型 4（报"不支持的压缩"）；
//   * `chm-unsupported-lzxc.chm` —— LZXC 版本 3（报"不支持的压缩"）；
//   * `chm-broken-signature.chm` —— ITSF 签名被改坏（报"坏文件"）。
//
// 生成完会**立刻用解析层自检**（`chmProbe` / `parseChmBook` / `chmCoverBytes`），
// 所以这个脚本同时也是"解析器能读自己造的文件"的冒烟测试。纯 Dart，不依赖 flutter。
//
// ⚠️ LZX 编码：本工具只实现**未压缩块（block type 3）**的写入器 —— 那是自研解析
// 里最基础、也最容易自证正确的一条路。verbatim/aligned 压缩块的**解码**已实现，
// 但需要真实 CHM 才能端到端证明（见 `chm_archive.dart` 头部的边界说明）。
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:synhub/src/features/files/book_charset_table.dart';
import 'package:synhub/src/features/files/book_chm.dart';
import 'package:synhub/src/features/files/chm_archive.dart';
import 'package:synhub/src/features/files/file_book.dart';

// ---------------------------------------------------------------- 字节工具

/// PNG 里的整数是**大端**
List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

/// CHM 的整数（ITSF/ITSP/PMGL/LZXC/ResetTable/#SYSTEM）都是**小端**
List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

List<int> _le32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

List<int> _le64(int v) => [
  ..._le32(v & 0xFFFFFFFF),
  ..._le32((v >> 32) & 0xFFFFFFFF),
];

List<int> asciiBytes(String s) => [for (final c in s.codeUnits) c];

// ---------------------------------------------------------------- PNG

/// 一张**肉眼可见**的棋盘 PNG（1×1 透明图在截图里看不出来）
Uint8List makePng(int w, int h, int rgb) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0); // 每行的 filter type
    for (var x = 0; x < w; x++) {
      final on = ((x ~/ 8) + (y ~/ 8)) % 2 == 0;
      raw.add(
        on
            ? [(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF]
            : [0x18, 0x18, 0x22],
      );
    }
  }
  final out = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  void chunk(String type, List<int> data) {
    out.add(_be32(data.length));
    out.add(asciiBytes(type));
    out.add(data);
    out.add(_be32(getCrc32([...asciiBytes(type), ...data])));
  }

  chunk('IHDR', [..._be32(w), ..._be32(h), 8, 2, 0, 0, 0]); // 8bit truecolor
  chunk('IDAT', ZLibEncoder().encode(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

// ---------------------------------------------------------------- 文本编码

/// GBK / GB18030 双字节编码（**反向查**解析层自带的解码表，保证往返一致）。
///
/// 只覆盖表里有的字符；找不到的字符抛错（fixture 里不该出现）。
Uint8List gbkEncode(String text) {
  final out = BytesBuilder();
  for (final rune in text.runes) {
    if (rune < 0x80) {
      out.addByte(rune);
      continue;
    }
    final pair = _gbkBytesFor(rune);
    if (pair == null) {
      throw ArgumentError('GBK 表里找不到 U+${rune.toRadixString(16)}');
    }
    out.add(pair);
  }
  return out.takeBytes();
}

List<int>? _gbkBytesFor(int cp) {
  for (var i = 0; i < kGbkTwoByteTable.length; i++) {
    if (kGbkTwoByteTable.codeUnitAt(i) == cp) {
      final lead = 0x81 + i ~/ 190;
      final trailIdx = i % 190;
      final trail = trailIdx < 63 ? 0x40 + trailIdx : 0x80 + (trailIdx - 63);
      return [lead, trail];
    }
  }
  return null;
}

/// UTF-16LE + BOM（Windows 记事本存中文的常见形态）
Uint8List utf16LeWithBom(String text) {
  final out = BytesBuilder()..add([0xFF, 0xFE]);
  for (final unit in text.codeUnits) {
    out.add(_le16(unit));
  }
  return out.takeBytes();
}

// ---------------------------------------------------------------- LZX 写入器

/// LZX **未压缩块**写入器（与 `ChmLzxDecoder` 对称，用来生成可自证的最小流）。
///
/// 块布局（事实来自公开的 LZX/CHM 实现说明，见 `chm_archive.dart` 头部）：
///   位流头：1 bit 标志（0 = 无 E8 文件长度），只在每个"重置区间"开头出现；
///   块头：3 bit 块类型 + 16 bit 高 + 8 bit 低（块长度）；uncompressed 块之后
///         位流对齐到 16 位字，紧接 12 字节 R0/R1/R2（小端），再是原始数据。
///
/// 输出的是"小端 16 位字 + 从最高位取"的位流（与 LZX 一致）。
class LzxUncompressedWriter {
  LzxUncompressedWriter({this.resetEvery = 4});

  /// 每多少个块插入一个位流头（= 重置区间长度）
  final int resetEvery;

  final BytesBuilder _out = BytesBuilder();
  int _bitBuf = 0;
  int _bitCount = 0;
  int _blocks = 0;

  void _emitWord(int w) {
    _out.addByte(w & 0xFF);
    _out.addByte((w >> 8) & 0xFF);
  }

  void _writeBits(int value, int n) {
    _bitBuf =
        ((_bitBuf << n) | (value & ((1 << n) - 1))) &
        ((1 << (_bitCount + n)) - 1);
    _bitCount += n;
    while (_bitCount >= 16) {
      final w = (_bitBuf >> (_bitCount - 16)) & 0xFFFF;
      _bitCount -= 16;
      _bitBuf &= (1 << _bitCount) - 1;
      _emitWord(w);
    }
  }

  void _flushWord() {
    if (_bitCount > 0) _writeBits(0, 16 - _bitCount);
  }

  /// 追加一个块，块类型由 [type] 指定（正常路径用 3 = uncompressed）
  void addBlockWithType(List<int> data, int type) {
    if (_blocks % resetEvery == 0) {
      _flushWord();
      _writeBits(0, 1); // 位流头：1 bit，0 = 没有 E8 文件长度
    }
    _writeBits(type, 3);
    _writeBits(data.length >> 8, 16);
    _writeBits(data.length & 0xFF, 8);
    _flushWord(); // 对齐到 16 位字（R0/R1/R2 从下一个字开始）
    _out.add(const [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]); // R0=R1=R2=1
    _out.add(data);
    if (data.length.isOdd) {
      _out.addByte(0); // 对齐到字，下一个块头才能从偶数字节开始
    }
    _blocks++;
  }

  void addBlock(List<int> data) => addBlockWithType(data, 3);

  Uint8List finish() {
    _flushWord();
    return _out.takeBytes();
  }
}

/// 把一个（已补齐到块大小整数倍的）内容流写成 LZX 块流
///
/// [blockType] 正常用 3（uncompressed）；测试"能力边界"时可以传 4/0 造坏块。
Uint8List lzxUncompressedStream(
  Uint8List content, {
  required int blockLen,
  int resetEvery = 4,
  int blockType = 3,
}) {
  final writer = LzxUncompressedWriter(resetEvery: resetEvery);
  for (var off = 0; off < content.length; off += blockLen) {
    writer.addBlockWithType(
      Uint8List.sublistView(
        content,
        off,
        (off + blockLen).clamp(0, content.length),
      ),
      blockType,
    );
  }
  return writer.finish();
}

// ---------------------------------------------------------------- CHM 组装

/// 一个待写进 fixture 的文件
class ChmFixtureFile {
  const ChmFixtureFile(this.path, this.data, {this.uncompressed = false});

  /// 归档内路径（`/guide/ch1.htm` 或 `guide/ch1.htm` 都行）
  final String path;
  final Uint8List data;

  /// true → 落在 Uncompressed 空间（space 0，直接存文件里）；
  /// false（默认）→ 落在 MSCompressed 空间（space 1，走 LZX 内容流）
  final bool uncompressed;
}

/// 造一个合法 CHM v3。
///
/// * [files] 里 `uncompressed: false` 的文件会被拼进 MSCompressed 内容流，
///   用 **LZX 未压缩块** 承载；
/// * `/#SYSTEM` 由 [title] / [defaultTopic] / [hhcPath] 自动生成（未压缩空间）；
/// * [blockType] / [lzxcVersion] / [windowField] / [resetField] 供测试
///   "能力边界"路径时**故意造坏**；
/// * [truncateAt] 可以在 [truncateAt] 字节处截断（造"坏文件"样本）。
Uint8List buildChmFixture(
  List<ChmFixtureFile> files, {
  String title = 'CHM 验证之书',
  String defaultTopic = 'index.htm',
  String? hhcPath = 'toc.hhc',
  int blockLen = 0x8000,
  int blockType = 3,
  int lzxcVersion = 2,
  int windowField = 1, // *0x8000 = 32KB 窗口
  int resetField = 4, // *0x8000 = 4 个块
  int dirBlockLen = 0x1000,
  int? truncateAt,
}) {
  // ---- 1. 分类 + 内容流
  final uncompressedFiles = <ChmFixtureFile>[];
  final compressedFiles = <ChmFixtureFile>[];
  for (final f in files) {
    final p = _norm(f.path);
    if (f.uncompressed || _isInternal(p)) {
      uncompressedFiles.add(ChmFixtureFile(p, f.data, uncompressed: true));
    } else {
      compressedFiles.add(ChmFixtureFile(p, f.data));
    }
  }

  final contentRaw = BytesBuilder();
  final compressedOffsets = <String, int>{};
  for (final f in compressedFiles) {
    compressedOffsets[_norm(f.path)] = contentRaw.length;
    contentRaw.add(f.data);
  }
  final contentBytes = contentRaw.takeBytes();
  final contentLen = contentBytes.length;
  final padded = Uint8List(
    contentLen == 0 ? 0 : ((contentLen + blockLen - 1) ~/ blockLen) * blockLen,
  );
  padded.setRange(0, contentLen, contentBytes);

  // ---- 2. LZX 流 + ResetTable + LZXC
  //
  // ⚠️ 写入侧的"每个重置区间插一个位流头"必须等于**解码侧**由 LZXC 算出来的
  // 重置间隔（resetInterval / blockLen），否则解出来就是错的 —— 这里推导出来，
  // 不交给调用方手填。
  final blkReset = (resetField * 0x8000) ~/ blockLen;
  final resetEvery = blkReset < 1 ? 1 : blkReset;
  final lzxStream = contentLen == 0
      ? Uint8List(0)
      : lzxUncompressedStream(
          padded,
          blockLen: blockLen,
          resetEvery: resetEvery,
          blockType: blockType,
        );
  final blockCount = contentLen == 0 ? 0 : padded.length ~/ blockLen;

  Uint8List resetTable() {
    final b = BytesBuilder();
    b.add(_le32(2)); // version
    b.add(_le32(blockCount));
    b.add(_le32(0)); // unknown
    b.add(_le32(0x28)); // table_offset：表紧跟在这个 0x28 字节头之后
    b.add(_le64(contentLen)); // uncompressed_len
    b.add(_le64(lzxStream.length)); // compressed_len
    b.add(_le64(blockLen));
    // 每块的**起始偏移**（相对 Content 流）：解压侧靠它 + 下一项定块边界
    final blockCompressedLen = _blockStreamLen(blockLen);
    for (var i = 0; i < blockCount; i++) {
      b.add(_le64(i * blockCompressedLen));
    }
    return b.takeBytes();
  }

  Uint8List controlData() {
    final b = BytesBuilder();
    b.add(_le32(0x1C)); // size
    b.add(asciiBytes('LZXC'));
    b.add(_le32(lzxcVersion));
    b.add(_le32(resetField));
    b.add(_le32(windowField));
    b.add(_le32(0)); // windowsPerReset
    b.add(_le32(0)); // unknown_18
    return b.takeBytes();
  }

  // ---- 3. #SYSTEM（未压缩空间）
  final system = _buildSystem(
    title: title,
    defaultTopic: defaultTopic,
    hhcPath: hhcPath,
  );

  // ---- 4. 数据区布局：未压缩文件 → Content → ResetTable → ControlData
  final dataRegion = BytesBuilder();
  final entries = <_RawEntry>[];

  void addUncompressed(String path, Uint8List data) {
    entries.add(_RawEntry(_norm(path), 0, dataRegion.length, data.length));
    dataRegion.add(data);
  }

  addUncompressed('/#SYSTEM', system);
  for (final f in uncompressedFiles) {
    addUncompressed(f.path, f.data);
  }
  if (blockCount > 0) {
    addUncompressed(_kContentUnit, lzxStream);
    addUncompressed(_kResetUnit, resetTable());
    addUncompressed(_kControlUnit, controlData());
  }
  final dataBytes = dataRegion.takeBytes();

  // ---- 5. 压缩条目（start = 内容流里的偏移）
  for (final f in compressedFiles) {
    final p = _norm(f.path);
    entries.add(_RawEntry(p, 1, compressedOffsets[p]!, f.data.length));
  }
  // 目录项（`/guide/` 这种），真实文件里都有
  final dirs = <String>{};
  for (final e in entries) {
    if (e.path.startsWith('::')) continue;
    var p = e.path;
    while (p.contains('/')) {
      p = p.substring(0, p.lastIndexOf('/'));
      if (p.isEmpty || p == '/') break;
      dirs.add('$p/');
    }
  }
  for (final d in dirs) {
    if (entries.any((e) => e.path == d)) continue;
    entries.add(_RawEntry(d, 0, 0, 0));
  }
  entries.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

  // ---- 6. 目录块（PMGL）：dir_len 覆盖 ITSP 头 + 所有目录页（chmlib 的算法）
  final dirBlocks = _encodeDirectory(entries, dirBlockLen);
  final dirLen = 0x54 + dirBlocks.length * dirBlockLen;
  final dataOffset = 0x60 + dirLen;

  // ---- 7. 组装
  final out = BytesBuilder();
  out.add(_itsfHeader(dirOffset: 0x60, dirLen: dirLen, dataOffset: dataOffset));
  out.add(
    _itspHeader(
      blockLen: dirBlockLen,
      numBlocks: dirBlocks.length,
      langId: 0x0804, // zh-CN
    ),
  );
  for (final b in dirBlocks) {
    out.add(b);
  }
  out.add(dataBytes);
  final bytes = out.takeBytes();
  if (truncateAt != null && truncateAt < bytes.length) {
    return Uint8List.sublistView(bytes, 0, truncateAt);
  }
  return bytes;
}

// ---------------------------------------------------------------- 内部组装

const String _kContentUnit = '::DataSpace/Storage/MSCompressed/Content';
const String _kControlUnit = '::DataSpace/Storage/MSCompressed/ControlData';
const String _kResetUnit =
    '::DataSpace/Storage/MSCompressed/Transform/'
    '{7FC28940-9D31-11D0-9B27-00A0C91E9C7C}/InstanceData/ResetTable';

class _RawEntry {
  _RawEntry(this.path, this.space, this.start, this.length);
  final String path;
  final int space;
  final int start;
  final int length;
}

String _norm(String path) {
  var p = path.replaceAll('\\', '/');
  while (p.startsWith('./')) {
    p = p.substring(2);
  }
  if (!p.startsWith('/') && !p.startsWith('::')) p = '/$p';
  return p;
}

bool _isInternal(String p) => p.startsWith('/#') || p.startsWith(r'/$');

/// 一个 LZX 块在流里占多少字节（块头 4 + R0R1R2 12 + blockLen 原始数据，
/// 奇数长度再补 1 字节对齐）
int _blockStreamLen(int blockLen) {
  var n = 4 + 12 + blockLen;
  if (blockLen.isOdd) n += 1;
  return n;
}

Uint8List _itsfHeader({
  required int dirOffset,
  required int dirLen,
  required int dataOffset,
}) {
  final b = Uint8List(0x60);
  void put(int off, List<int> v) => b.setRange(off, off + v.length, v);
  put(0x00, asciiBytes('ITSF'));
  put(0x04, _le32(3)); // version
  put(0x08, _le32(0x60)); // header length
  put(0x0C, _le32(1));
  put(0x10, _le32(0)); // last modified
  put(0x14, _le32(0x0804)); // zh-CN
  put(0x18, asciiBytes('CHMFIXTUREDIRGID')); // 16
  put(0x28, asciiBytes('CHMFIXTURESTREAM')); // 16
  put(0x38, _le64(0)); // unknown offset
  put(0x40, _le64(0)); // unknown len
  put(0x48, _le64(dirOffset));
  put(0x50, _le64(dirLen));
  put(0x58, _le64(dataOffset));
  return b;
}

Uint8List _itspHeader({
  required int blockLen,
  required int numBlocks,
  required int langId,
}) {
  final b = Uint8List(0x54);
  void put(int off, List<int> v) => b.setRange(off, off + v.length, v);
  put(0x00, asciiBytes('ITSP'));
  put(0x04, _le32(1)); // version
  put(0x08, _le32(0x54)); // header length
  put(0x0C, _le32(0));
  put(0x10, _le32(blockLen));
  put(0x14, _le32(1)); // blockidx_intvl
  put(0x18, _le32(1)); // index_depth
  put(0x1C, _le32(0)); // index_root
  put(0x20, _le32(0)); // index_head
  put(0x24, _le32(0));
  put(0x28, _le32(numBlocks));
  put(0x2C, _le32(0));
  put(0x30, _le32(langId));
  put(0x34, asciiBytes('CHMFIXTURESYSTEM')); // 16
  put(0x44, List<int>.filled(16, 0));
  return b;
}

/// PMGL 条目：**大端** 7 位变长整数（最高位为续读标志）
List<int> _encint(int v) {
  if (v < 0x80) return [v];
  final digits = <int>[];
  var x = v;
  while (x > 0) {
    digits.insert(0, x & 0x7F);
    x >>= 7;
  }
  for (var i = 0; i < digits.length - 1; i++) {
    digits[i] |= 0x80;
  }
  return digits;
}

/// 把条目编码成若干 PMGL 块（block_next 串联）
List<Uint8List> _encodeDirectory(List<_RawEntry> entries, int dirBlockLen) {
  final chunks = <List<int>>[];
  var current = <int>[];
  final payloadMax = dirBlockLen - 0x14;
  for (final e in entries) {
    final name = utf8.encode(e.path);
    final item = <int>[
      ..._encint(name.length),
      ...name,
      ..._encint(e.space),
      ..._encint(e.start),
      ..._encint(e.length),
    ];
    if (current.length + item.length > payloadMax && current.isNotEmpty) {
      chunks.add(current);
      current = <int>[];
    }
    current.addAll(item);
  }
  if (current.isNotEmpty || chunks.isEmpty) chunks.add(current);

  final out = <Uint8List>[];
  for (var i = 0; i < chunks.length; i++) {
    final block = Uint8List(dirBlockLen);
    void put(int off, List<int> v) => block.setRange(off, off + v.length, v);
    put(0x00, asciiBytes('PMGL'));
    // ⚠️ PMGL 头里的整数是**小端**（条目里的变长整数才是大端）
    put(0x04, _le32(dirBlockLen - 0x14 - chunks[i].length)); // free_space
    put(0x08, _le32(0));
    put(0x0C, _le32(i == 0 ? 0xFFFFFFFF : i - 1)); // block_prev = -1
    put(0x10, _le32(i + 1 < chunks.length ? i + 1 : 0xFFFFFFFF)); // block_next
    block.setRange(0x14, 0x14 + chunks[i].length, chunks[i]);
    out.add(block);
  }
  return out;
}

Uint8List _buildSystem({
  required String title,
  required String defaultTopic,
  required String? hhcPath,
}) {
  final b = BytesBuilder();
  b.add(_le32(3)); // #SYSTEM 版本
  void entry(int code, List<int> data) {
    // ⚠️ chmspec：NT 字符串的 length **包含** 结尾的 NUL
    final nt = [...data, 0];
    b.add(_le16(code));
    b.add(_le16(nt.length));
    b.add(nt);
  }

  if (hhcPath != null) entry(0, utf8.encode(hhcPath));
  entry(2, utf8.encode(defaultTopic));
  entry(3, utf8.encode(title));
  return b.takeBytes();
}

// ---------------------------------------------------------------- fixture 内容

/// 三段中文正文（UTF-8 / GBK / UTF-16LE）+ hhc 三层嵌套目录 + 一张 PNG
List<ChmFixtureFile> chmFixtureFiles() {
  final png = makePng(96, 48, 0x4F8CFF);
  final hhc = utf8.encode('''
<HTML><BODY>
<OBJECT type="text/site properties">
  <param name="FrameName" value="left">
</OBJECT>
<UL>
  <LI><OBJECT type="text/sitemap">
    <param name="Name" value="第一章 起风了">
    <param name="Local" value="guide/ch1.htm">
  </OBJECT>
  <UL>
    <LI><OBJECT type="text/sitemap">
      <param name="Name" value="1.1 小节：锚点">
      <param name="Local" value="guide/ch1.htm#sec1">
    </OBJECT>
    <UL>
      <LI><OBJECT type="text/sitemap">
        <param name="Name" value="1.1.1 更深的锚点">
        <param name="Local" value="guide/ch1.htm#sec2">
      </OBJECT>
    </UL>
  </UL>
  <LI><OBJECT type="text/sitemap">
    <param name="Name" value="第二章 落雨了">
    <param name="Local" value="guide/ch2.htm">
  </OBJECT>
  <UL>
    <LI><OBJECT type="text/sitemap">
      <param name="Name" value="2.1 编码：GBK">
      <param name="Local" value="guide/ch2.htm#sec1">
    </OBJECT>
    <LI><OBJECT type="text/sitemap">
      <param name="Name" value="第三章 UTF-16">
      <param name="Local" value="guide/deep/ch3.htm">
    </OBJECT>
  </UL>
</UL>
</BODY></HTML>
''');
  final index = utf8.encode('''
<html><head><meta charset="utf-8"><title>示例 CHM 手册</title></head>
<body>
<h1>示例 CHM 手册</h1>
<p>这是一本<strong>自造的最小 CHM</strong>，用来验证 ITSF 容器、ITSP 目录树、
LZX 未压缩块解压，以及 hhc 目录层级。</p>
<p><img src="images/logo.png" alt="logo"></p>
<p>上面那张棋盘图来自 MSCompressed 内容流里的 PNG。</p>
<p><a href="guide/ch1.htm">开始阅读第一章</a></p>
</body></html>
''');
  final ch1 = utf8.encode('''
<html><head><meta charset="utf-8"></head>
<body>
<h1>第一章 起风了</h1>
<p>中文 UTF-8 正文：风从海上来，带着一点咸味。</p>
<h2 id="sec1">1.1 小节：锚点</h2>
<p>这一段用来验证 hhc 里的锚点能落到小节，而不是只跳到章首。</p>
<h3 id="sec2">1.1.1 更深的锚点</h3>
<p>第三层目录项落到这里。</p>
<img src="../images/logo.png">
</body></html>
''');
  final ch2Text = '''
<html><head><meta charset="gb2312"></head>
<body>
<h1>第二章 落雨了</h1>
<p>中文 GBK 正文：雨点打在窗台上，噼里啪啦响个不停。</p>
<h2 id="sec1">2.1 编码：GBK</h2>
<p>这一页用 GBK 存，验证编码探测走的是 GB18030 而不是 UTF-8 容错。</p>
</body></html>
''';
  final ch3Text = '''
<html><head></head>
<body>
<h1>第三章 UTF-16</h1>
<p>中文 UTF-16LE 正文：深夜的灯还亮着，书页翻过去的声音很轻。</p>
</body></html>
''';
  return [
    ChmFixtureFile('index.htm', Uint8List.fromList(index)),
    ChmFixtureFile('toc.hhc', Uint8List.fromList(hhc)),
    ChmFixtureFile('guide/ch1.htm', Uint8List.fromList(ch1)),
    ChmFixtureFile('guide/ch2.htm', gbkEncode(ch2Text)),
    ChmFixtureFile('guide/deep/ch3.htm', utf16LeWithBom(ch3Text)),
    ChmFixtureFile('images/logo.png', png),
  ];
}

/// 供测试/探针用：hhc 里的中文标题（断言目录层级与编码都读对）
const List<String> chmFixtureTocTitles = [
  '第一章 起风了',
  '1.1 小节：锚点',
  '1.1.1 更深的锚点',
  '第二章 落雨了',
  '2.1 编码：GBK',
  '第三章 UTF-16',
];

/// 供测试/探针用：hhc 目录的层级（0/1/2），与 [chmFixtureTocTitles] 一一对应
const List<int> chmFixtureTocDepths = [0, 1, 2, 0, 1, 1];

// ---------------------------------------------------------------- CLI

Future<void> main(List<String> args) async {
  final dir = Directory(args.isEmpty ? '/tmp/chm-verify' : args.first);
  await dir.create(recursive: true);

  final files = chmFixtureFiles();
  final good = buildChmFixture(files);

  final outputs = <String, Uint8List>{
    'chm-verify.chm': good,
    'chm-broken-truncated.chm': Uint8List.sublistView(
      good,
      0,
      good.length - 64,
    ),
    'chm-unsupported-lzxblock.chm': buildChmFixture(files, blockType: 4),
    'chm-unsupported-lzxc.chm': buildChmFixture(files, lzxcVersion: 3),
    'chm-broken-signature.chm': Uint8List.fromList([...good]..[0] = 0x58),
  };

  var bad = 0;
  for (final e in outputs.entries) {
    final path = '${dir.path}/${e.key}';
    await File(path).writeAsBytes(e.value);
    print('$path  ${e.value.length} B');
  }

  // ---- 自检：合法样本必须能读，坏样本必须报对应的错
  print('\n容器探针：${chmProbe(good)}');
  final parsed = parseChmBook(good, format: BookFormat.chm);
  print(
    '解析：ok=${parsed.ok} error=${parsed.error} kind=${parsed.errorKind?.name} '
    'chapters=${parsed.content.chapters.length} toc=${parsed.content.toc.length} '
    'resources=${parsed.content.resources.length} title=${parsed.content.title}',
  );
  print('封面：${chmCoverBytes(good)?.length} B');
  if (!parsed.ok || parsed.content.chapters.isEmpty) {
    stderr.writeln('!! 解析层读不了自己造的合法 CHM，fixture 有问题');
    bad++;
  }
  final tocTitles = parsed.content.toc.map((e) => e.title).toList();
  if (!chmFixtureTocTitles.every(tocTitles.contains)) {
    stderr.writeln('!! hhc 目录标题没读全：$tocTitles');
    bad++;
  }
  if (parsed.content.resources.isEmpty) {
    stderr.writeln('!! 图片资源没读出来');
    bad++;
  }

  for (final e in outputs.entries) {
    if (e.key == 'chm-verify.chm') continue;
    final r = parseChmBook(e.value, format: BookFormat.chm);
    print('坏样本 ${e.key}：ok=${r.ok} kind=${r.errorKind?.name} error=${r.error}');
    if (r.ok || r.errorKind == null) {
      stderr.writeln('!! 坏样本 ${e.key} 居然被当成好书');
      bad++;
    }
  }
  if (bad != 0) exit(1);
  print('\n全部自检通过。');
  exit(0);
}
