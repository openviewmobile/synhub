// MOBI / AZW3（PalmDB 容器）解析层 —— **纯 Dart**，不 import flutter / l10n。
//
// **为什么自己写而不是引包**（结论来自 `docs/ebook-formats-research.md` §3.2/§3.4）：
// pub 上唯一对口的纯 Dart 实现 `unseal` 要 `archive ^3.1.6`，与本项目的
// `archive ^4.0.7` **直接冲突**（`^3.x` 与 `^4.x` 无交集）；备选 `kindle_unpack`
// 是 GPL-3.0（传染）、`dart_mobi` 是 LGPL-3.0（Dart AOT 的"可重链接"合规不明）。
// 而 MOBI6 真正需要的算法只有三件 —— PalmDB 分记录 / PalmDOC LZ77 / EXTH 元数据 ——
// 都是几十行能写完的东西，所以自己实现：**零新依赖、零许可风险**。
//
// **明确的能力边界**（宁可给清晰错误，也不输出乱码）：
//
//   * 压缩类型 1（无压缩）✅ / 2（PalmDOC LZ77）✅ / **17480（HUFF/CDIC）✅**；
//   * DRM（PalmDOC `encryptionType != 0`）❌ → 报"带 DRM"，不解密；
//   * **纯 KF8**（AZW3 的 skeleton + FDST 重组）✅ → 见本文件 "KF8" 段：
//     按 KindleUnpack v0.83 的 `K8Processor.buildParts` 语义重组；**FDST 缺失 /
//     损坏、skeleton/fragment 索引读不出来时明确报错**（不吐半截）；
//   * **joint MOBI/KF8**（kindlegen 默认产物，EXTH 121 指向 KF8 边界）✅ →
//     **优先 KF8 半边**（排版/目录更全），KF8 半边重组失败时回落到同一文件里的
//     MOBI6 半边；纯 MOBI6 文件照常走 MOBI6 —— 见 `_readMobi`；
//   * **KF8 的 NCX(`0xF4`) / guide(`0x104`) 目录 → `BookContent.toc`** ✅
//     （层级保留，`pos` → 段号映射；见 `_kf8Toc`）；
//   * **KF8 `kindle:pos:fid` 内部链接重写 → `BookContent.anchors`** ✅
//     （fragment 表 `fid` + `off` → 段号，再找最近 `id`/`name`/`aid` 锚点；
//     见 `_Kf8LinkMap`）；定位不了的形态明确降级成 `#kf8-unsupported`。
//   * CSS/SVG flow 内联 ❌ → 尚未做（见 `docs/ebook-reader-plan.md` 的
//     "仍未支持/未证明"）。
//
// HUFF/CDIC 见 [_HuffCdic]：Kindle 的**静态 Huffman + 字典短语**编码。
// 与 PalmDOC 一样是"记录级"解压（每条正文记录独立解），所以我们把它挂在
// `_extractText` 的同一条流水线上 —— HUFF 字典损坏/记录缺失时明确报能力边界，
// **绝不**把 Huffman 码流当正文输出。
//
// 产物直接落进 **和 EPUB/FB2 同一套** `BookContent`（`chapters` + `toc` + `anchors`
// + `resources`），于是目录 / 书内搜索 / 书签 / 进度 / 阅读设置 **全部免费复用**，
// 渲染层一行不用改。章节切分见 `_mobiSlices`：优先用书**自带的目录**
// （`<guide>` 里 `type="toc"` 指向的 `<a filepos>` 列表），拿不到就按
// `<mbp:pagebreak>` 切，再拿不到就单章 + 按大小切。
import 'dart:convert';
import 'dart:typed_data';

import 'package:html/parser.dart' as htmlp;

import 'book_encoding.dart';
import 'book_text.dart';
import 'file_book.dart';

/// PalmDOC 压缩类型
const int _kCompressionNone = 1;
const int _kCompressionPalmDoc = 2;
const int _kCompressionHuffCdic = 17480;

/// 单章大到这个体积且没有任何目录线索时才按大小切
const int _kSizeSplitBytes = 256 * 1024;

/// 按大小切时每段的目标体积
const int _kSizeSplitTarget = 64 * 1024;

/// MOBI/KF8 头里"这个索引不存在"的哨兵值（`0xFFFFFFFF`）
const int _kKf8None = 0xFFFFFFFF;

/// "这本书是能读的，但用了我们做不到的编码" —— 界面据此给**清晰**的错误，
/// 而不是把乱码塞进阅读页。
class _MobiUnsupported implements Exception {
  _MobiUnsupported(this.message);
  final String message;
  @override
  String toString() => message;
}

// ------------------------------------------------------------------ 入口

/// 解析 MOBI / AZW3。**不抛异常**：失败返回带 `error` 的 [BookParseResult]。
///
/// [format] 只是回填到 [BookContent.format]（`.mobi`/`.azw` 与 `.azw3` 共用本解析器，
/// 前者落在 [BookFormat.mobi]、后者落在 [BookFormat.azw3]）。
BookParseResult parseMobiBook(List<int> bytes, {required BookFormat format}) {
  try {
    final doc = _readMobi(Uint8List.fromList(bytes));
    return BookParseResult(
      BookContent(
        format: format,
        title: doc.title,
        author: doc.author,
        chapters: doc.chapters,
        toc: doc.toc,
        anchors: doc.anchors,
        resources: doc.resources,
      ),
    );
  } on _MobiUnsupported catch (e) {
    // 已知类别 → [BookParseErrorKind.unsupportedCompression]，界面文案本地化；
    // [error] 保留技术细节（探针与日志用）。
    return BookParseResult(
      BookContent(format: format),
      error: e.message,
      errorKind: BookParseErrorKind.unsupportedCompression,
      reason: BookUnsupportedReason.compression,
    );
  } catch (_) {
    return BookParseResult(
      BookContent(format: format),
      error: '这本书解析失败（文件可能损坏或带 DRM）',
      errorKind: BookParseErrorKind.parseFailed,
    );
  }
}

/// 从 MOBI/AZW3 里抠封面字节（拿不到 → null，**不抛**）。
///
/// 只走"PalmDB 头 + EXTH 201"这条轻路径，不解正文 —— 列表滚动时它会被成批调用，
/// 没必要为了封面把整本书的章节都切一遍。体积/图片校验由调用方
/// （`book_cover.dart` 的 `bookCoverBytes`）统一收口。
Uint8List? mobiCoverBytes(Uint8List bytes) {
  try {
    final db = _parsePalmDb(bytes);
    final header = _parseHeader(db);
    if (header.encryptionType != 0) return null;
    final first = header.firstImageIndex;
    if (first <= 0 || first >= db.records.length) return null;
    final offset = _exthInt(header.exth, 201);
    if (offset == null) return null;
    // EXTH 201 是"相对 firstImageIndex 的图片序号"。0-based 与 1-based 两种
    // 写法在现实文件里都出现过，靠 magic number 判哪个能对上。
    for (final candidate in [first + offset, first + offset - 1]) {
      if (candidate < first || candidate >= db.records.length) continue;
      final rec = db.records[candidate];
      if (_imageKind(rec) != null) return rec;
    }
    return null;
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------------ PalmDB

class _PalmDb {
  _PalmDb(this.records);

  /// 每条记录一段字节（最后一条到文件尾）
  final List<Uint8List> records;
}

/// PalmDB（PalmDOC）容器：78 字节数据库头 + N 条 8 字节记录索引。
_PalmDb _parsePalmDb(Uint8List bytes) {
  if (bytes.length < 78) throw const FormatException('PalmDB 头不完整');
  final recordCount = _u16(bytes, 76);
  if (recordCount <= 0) throw const FormatException('PalmDB 没有记录');
  final tableEnd = 78 + recordCount * 8;
  if (tableEnd > bytes.length) throw const FormatException('PalmDB 记录表越界');

  final offsets = <int>[
    for (var i = 0; i < recordCount; i++) _u32(bytes, 78 + i * 8),
  ];
  final records = <Uint8List>[];
  for (var i = 0; i < offsets.length; i++) {
    final start = offsets[i];
    // 最后一条记录一直延伸到文件尾（PalmDB 不记它的长度）
    final end = i + 1 < offsets.length ? offsets[i + 1] : bytes.length;
    if (start < 0 ||
        start > bytes.length ||
        end < start ||
        end > bytes.length) {
      throw const FormatException('PalmDB 记录区间非法');
    }
    records.add(Uint8List.sublistView(bytes, start, end));
  }
  return _PalmDb(records);
}

// ------------------------------------------------------------------ 头部

class _MobiHeader {
  int compression = 0;
  int textLength = 0;
  int textRecordCount = 0;
  int encryptionType = 0;

  /// 1 = no compression, 2 = PalmDOC, 17480 = HUFF/CDIC
  int mobiVersion = 0;
  int mobiType = 0;
  int textEncoding = 0;
  int firstNonBookIndex = 0;
  int firstImageIndex = 0;
  int huffRecordOffset = 0;
  int huffRecordCount = 0;
  int extraDataFlags = 0;

  /// EXTH 121：joint MOBI/KF8 里 KF8 段的起始记录号（0 = 没有）
  int kf8Boundary = 0;

  /// MOBI8（KF8）专有字段 —— 偏移都是 **record 0 里的绝对偏移**
  /// （与 KindleUnpack `mobi8_header` 的表一致；那份表的偏移就是 record 0 绝对偏移）。
  ///
  ///   * `0xC0` FDST 定位表记录号、`0xC4` flow 数；
  ///   * `0xC8/0xCC` FCIS、`0xD0/0xD4` FLIS（都只用于探针，解析正文不需要）；
  ///   * `0xF4` NCX 索引、`0xF8` fragment 索引、`0xFC` skeleton 索引、`0x104` guide 索引。
  ///
  /// 取不到（老头 / 非 KF8）时保持 [_kKf8None]（0xFFFFFFFF，即"没有"）。
  int fdstOffset = _kKf8None;
  int fdstCount = 0;
  int fcisOffset = _kKf8None;
  int fcisCount = 0;
  int flisOffset = _kKf8None;
  int flisCount = 0;
  int ncxIndex = _kKf8None;
  int fragIndex = _kKf8None;
  int skelIndex = _kKf8None;
  int guideIndex = _kKf8None;

  /// 文字编码对应的语言代码（MOBI 头 `0x5C` 的低字节；0 = 没写）
  int languageCode = 0;

  /// EXTH 类型 → 值（同一类型可重复）
  Map<int, List<Uint8List>> exth = const {};
}

_MobiHeader _parseHeader(_PalmDb db) {
  if (db.records.isEmpty) throw const FormatException('PalmDB 没有记录 0');
  final rec0 = db.records.first;
  if (rec0.length < 24) throw const FormatException('MOBI record 0 太短');
  if (_ascii(rec0, 16, 4) != 'MOBI') throw const FormatException('不是 MOBI 文件');

  final h = _MobiHeader()
    ..compression = _u16(rec0, 0)
    ..textLength = _u32(rec0, 4)
    ..textRecordCount = _u16(rec0, 8)
    ..encryptionType = _u16(rec0, 12)
    ..mobiType = _u32(rec0, 24)
    ..textEncoding = _u32(rec0, 28)
    ..mobiVersion = _u32(rec0, 36)
    ..firstNonBookIndex = _u32(rec0, 80)
    ..firstImageIndex = _u32(rec0, 108)
    ..huffRecordOffset = _u32(rec0, 112)
    ..huffRecordCount = _u32(rec0, 116);

  final headerLength = _u32(rec0, 20);
  // 尾部 "extra data" 标志（traildata_flags）：**MOBI 头相对偏移 0xE0**，
  // 而 MOBI 头从 record 0 的 0x10 开始 → record 0 里的绝对偏移是 **0xF2**（2 字节大端）。
  //
  // ⚠️ 真实样本（Gutenberg pg11.mobi，见 `tool/mobi_real_probe.dart`）暴露的坑：
  // 这里曾经读的是 record 0 的 0xE4（那是 INDX record offset，值恒为 0），于是
  // flags 恒为 0、**尾部数据一律没剥** —— 每条正文记录尾部多出的 5~11 字节被
  // 当成正文解出来，正文每 ~4KB 就混进一小段垃圾。自造 fixture 把 flags 也写在
  // 0xE4，所以单测全绿、真实文件才露馅。
  //
  // 旧头（MOBI 头长度 < 0xE4）或 MOBI5 之前的版本没有这个字段 —— 与
  // KindleUnpack `getRawML` 的判据一致。
  if (headerLength >= 0xE4 && h.mobiVersion >= 5 && rec0.length >= 0xF4) {
    h.extraDataFlags = _u16(rec0, 0xF2);
  }
  final exthFlags = _u32(rec0, 128);
  if (exthFlags & 0x40 != 0) {
    h.exth = _parseExth(rec0, 16 + headerLength);
    h.kf8Boundary = _exthInt(h.exth, 121) ?? 0;
  }
  h.languageCode = _u32(rec0, 0x5C) & 0xFF;
  // MOBI8（KF8）专有索引/表字段。判据与 KindleUnpack `MobiHeader.__init__` 一致：
  // MOBI 头（自 record 0 偏移 16 起）总长至少到 0xF8 才有 NCX 之后的字段，
  // 而 K8 的 skeleton/fragment/FDST 是 version 8 才写的。字段偏移是 record 0 绝对偏移。
  if (h.mobiVersion >= 8 && rec0.length >= 0x108) {
    h.fdstOffset = _u32(rec0, 0xC0);
    h.fdstCount = _u32(rec0, 0xC4);
    h.fcisOffset = _u32(rec0, 0xC8);
    h.fcisCount = _u32(rec0, 0xCC);
    h.flisOffset = _u32(rec0, 0xD0);
    h.flisCount = _u32(rec0, 0xD4);
    h.ncxIndex = _u32(rec0, 0xF4);
    h.fragIndex = _u32(rec0, 0xF8);
    h.skelIndex = _u32(rec0, 0xFC);
    h.guideIndex = _u32(rec0, 0x104);
  }
  return h;
}

/// record 0 里 "16 + MOBI header 长度" 处是 EXTH（magic `EXTH`）。
Map<int, List<Uint8List>> _parseExth(Uint8List rec0, int offset) {
  if (offset < 0 || offset + 12 > rec0.length) return const {};
  if (_ascii(rec0, offset, 4) != 'EXTH') return const {};
  final count = _u32(rec0, offset + 8);
  final out = <int, List<Uint8List>>{};
  var p = offset + 12;
  for (var i = 0; i < count && p + 8 <= rec0.length; i++) {
    final type = _u32(rec0, p);
    final len = _u32(rec0, p + 4);
    // 长度字段含 8 字节自描述头；记录按 4 字节对齐（对齐含在 len 里）
    if (len < 8 || p + len > rec0.length) break;
    out
        .putIfAbsent(type, () => <Uint8List>[])
        .add(Uint8List.sublistView(rec0, p + 8, p + len));
    p += len;
  }
  return out;
}

int? _exthInt(Map<int, List<Uint8List>> exth, int type) {
  final list = exth[type];
  if (list == null || list.isEmpty) return null;
  final data = list.first;
  if (data.length >= 4) return _u32(data, 0);
  if (data.length == 1) return data[0];
  return null;
}

String _exthString(Map<int, List<Uint8List>> exth, int type, int encoding) {
  final list = exth[type];
  if (list == null || list.isEmpty) return '';
  final data = list.first;
  // EXTH 记录按 4 字节对齐 → 值的尾部是 NUL 填充，**先剥掉再解码**，
  // 否则书名/作者会带一串看不见的 `\0`。
  var end = data.length;
  while (end > 0 && data[end - 1] == 0) {
    end--;
  }
  if (end == 0) return '';
  return _decode(Uint8List.sublistView(data, 0, end), encoding).trim();
}

// ------------------------------------------------------------------ 正文

/// 解出整本 MOBI6 正文（未解码的原始字节）。
Uint8List _extractText(_PalmDb db, _MobiHeader h) {
  // HUFF/CDIC 的字典在 record 0 指定的 HUFF/CDIC 记录里，先加载好
  _HuffCdic? huff;
  if (h.compression == _kCompressionHuffCdic) {
    huff = _loadHuffCdic(db, h);
  }
  if (h.compression != _kCompressionNone &&
      h.compression != _kCompressionPalmDoc &&
      h.compression != _kCompressionHuffCdic) {
    throw _MobiUnsupported('MOBI 压缩类型 ${h.compression} 本阅读器不支持');
  }

  final out = BytesBuilder(copy: false);
  final end = h.textRecordCount.clamp(0, db.records.length - 1);
  for (var i = 1; i <= end; i++) {
    final raw = db.records[i];
    // 记录尾部的 "extra data"（TBS/索引用的附加块）不属于正文，先剥掉，
    // 否则中间几条记录会混进一段垃圾字节 —— 那正是"乱码"的来源。
    final payload = _stripTrailingData(raw, h.extraDataFlags);
    switch (h.compression) {
      case _kCompressionNone:
        out.add(payload);
      case _kCompressionPalmDoc:
        out.add(_palmDocDecompress(payload));
      case _kCompressionHuffCdic:
        out.add(huff!.unpack(payload));
    }
  }
  var text = out.takeBytes();
  // PalmDOC 头里的 textLength 是权威长度：多出来的尾巴一律截掉（双保险）
  if (h.textLength > 0 && text.length > h.textLength) {
    text = Uint8List.sublistView(text, 0, h.textLength);
  }
  return text;
}

/// 剥掉记录尾部的 extra data。
///
/// 规则（与 KindleUnpack / calibre 同款）：`extraDataFlags` 的 bit1..bit15 各对应
/// 一段尾部数据，其**总长度**（含自身 varint）以"从末尾往前读的变长整数"记在尾部；
/// bit0 表示多字节字符重叠，长度 = `(末字节 & 0x3) + 1`。读不出来就原样返回 ——
/// 宁可多留几个字节，也不能把正文切掉。
Uint8List _stripTrailingData(Uint8List record, int flags) {
  if (flags == 0 || record.isEmpty) return record;
  var num = 0;
  var testFlags = flags >> 1;
  while (testFlags != 0) {
    if (testFlags & 1 != 0) {
      final v = _readBackwardVarint(record, record.length - num);
      if (v == null) return record;
      num += v;
    }
    testFlags >>= 1;
  }
  if (flags & 1 != 0) {
    final at = record.length - num - 1;
    if (at < 0 || at >= record.length) return record;
    num += (record[at] & 0x03) + 1;
  }
  if (num <= 0 || num >= record.length) return record;
  return Uint8List.sublistView(record, 0, record.length - num);
}

/// 从 [size] 处**往前**读一个变长整数（MOBI 的尾部数据就是这么编码的）。
///
/// ⚠️ 终止位是**最高位为 1**（不是 0）：从末字节往前读，遇到 `0x80` 置位的字节
/// 即结束。真实样本里尾部块的编码形如 `00 xx 80 yy 84` —— 末字节 `0x84` 本身就
/// 是"值 4 且到此为止"。此前这里把终止条件写反（遇最高位为 0 才停），于是会
/// 把前一个字节也算进去（例如 `03 84` 被读成 0x184=388），一剥就剥掉大半个记录。
///
/// 4 个字节内没有终止位 → 返回 null，调用方原样保留（宁多留也不切正文）。
int? _readBackwardVarint(Uint8List data, int size) {
  if (size <= 0 || size > data.length) return null;
  var num = 0;
  for (var i = 0; i < 4; i++) {
    final idx = size - 1 - i;
    if (idx < 0) return null;
    final v = data[idx];
    num |= (v & 0x7f) << (7 * i);
    if (v & 0x80 != 0) return num;
  }
  return null;
}

/// PalmDOC（LZ77 变体）解压 —— 压缩类型 2。
///
/// 操作码：
///   * `0x00`         → 原样输出一个 0 字节；
///   * `0x01..0x08`   → 后面 N 个字节**原样拷贝**（N = 操作码本身）；
///   * `0x09..0x7F`   → 单字节字面量；
///   * `0x80..0xBF`   → 两字节的"距离/长度对"（回到已输出内容里复制）；
///   * `0xC0..0xFF`   → 输出一个空格 + `opcode ^ 0x80`（省掉一个空格字节）。
///
/// 遇到坏的距离（> 已输出长度）**立即停止**，不制造乱码。
Uint8List _palmDocDecompress(Uint8List src) {
  final out = <int>[];
  var i = 0;
  while (i < src.length) {
    final op = src[i++];
    if (op == 0) {
      out.add(0);
      continue;
    }
    if (op <= 8) {
      // 1..8：原样拷贝这么多个字节
      var n = op;
      while (n > 0 && i < src.length) {
        out.add(src[i++]);
        n--;
      }
      continue;
    }
    if (op <= 0x7f) {
      out.add(op);
      continue;
    }
    if (op >= 0xc0) {
      out.add(0x20);
      out.add(op ^ 0x80);
      continue;
    }
    // 0x80..0xBF：距离/长度对
    if (i >= src.length) break;
    final pair = (op << 8) | src[i++];
    final distance = (pair >> 3) & 0x07ff;
    final length = (pair & 0x07) + 3;
    if (distance == 0 || distance > out.length) break;
    final from = out.length - distance;
    // 逐字节复制，允许 distance < length 的重叠展开
    for (var k = 0; k < length; k++) {
      out.add(out[from + k]);
    }
  }
  return Uint8List.fromList(out);
}

// ------------------------------------------------------------------ HUFF/CDIC

/// 加载 record 0 指向的 HUFF/CDIC 记录。
///
/// 布局（与 KindleUnpack / calibre 同一套）：
///   * HUFF 记录从 `huffRecordOffset` 开始，**第一条**就是 HUFF（magic `HUFF`）；
///   * 紧随其后的若干条是 CDIC（magic `CDIC`），条数由 `huffRecordCount` 给出。
///
/// `huffRecordCount` 到底"含不含 HUFF"在各家实现里写法不一 —— 这里不赌：
/// 从 `offset+1` 起**按 magic 一直读 CDIC**，读到非 CDIC 或条数上限为止。
/// 一条 CDIC 都没读到就明确报能力边界，不拿空字典去解出乱码。
_HuffCdic _loadHuffCdic(_PalmDb db, _MobiHeader h) {
  final off = h.huffRecordOffset;
  final count = h.huffRecordCount;
  if (off <= 0 || off >= db.records.length) {
    throw _MobiUnsupported('MOBI 声明 HUFF/CDIC 压缩，但找不到 Huffman 字典记录');
  }
  final huff = _HuffCdic();
  try {
    huff.loadHuff(db.records[off]);
  } on FormatException catch (e) {
    throw _MobiUnsupported('MOBI 的 HUFF 字典损坏（${e.message}）');
  }
  final limit = count > 0 ? count : db.records.length;
  var cdicCount = 0;
  for (var i = 1; i <= limit && off + i < db.records.length; i++) {
    final rec = db.records[off + i];
    if (rec.length < 16 || _ascii(rec, 0, 4) != 'CDIC') break;
    try {
      huff.loadCdic(rec);
    } on FormatException catch (e) {
      throw _MobiUnsupported('MOBI 的 CDIC 字典损坏（${e.message}）');
    }
    cdicCount++;
  }
  if (cdicCount == 0 || huff.phraseCount == 0) {
    throw _MobiUnsupported('MOBI 声明 HUFF/CDIC 压缩，但没有可用的 CDIC 短语字典');
  }
  return huff;
}

/// Kindle 的 HUFF/CDIC（压缩类型 17480）= 静态 Huffman 码 + 短语字典。
///
/// 算法（**自研纯 Dart 实现**，字段语义来自公开的 MOBI 格式描述）：
///
///   * **HUFF 记录**：magic `HUFF` + 头长 `0x18`；偏移 8/12 是两个大端 u32，
///     分别指向 `dict1`（256 项）与 `dict2`（64 项）表：
///       - `dict1[v]`：`codelen = v & 0x1f`、`term = v & 0x80`、
///         `maxcode = ((v >> 8) + 1) << (32 - codelen) - 1`（peculiar，但就是这样）；
///       - `dict2[0::2]`/`dict2[1::2]` 是 codelen=1..32 的 min/max code 归一化表；
///   * **CDIC 记录**：magic `CDIC` + 头长 `0x10`；`phrases`、`bits` 两个大端 u32；
///     随后 `min(1<<bits, phrases - 已加载数)` 个大端 u16 偏移，每个偏移处是
///     `u16 长度`（最高位是"已解码"标志）+ 短语字节；
///   * **解码**：64 位大端滑动窗口，取高 32 位当 code；`dict1[code >> 24]` 给
///     codelen（`term` 为假时用 dict2 的 min/max 表继续加长），再从字典里取短语。
///     短语本身可能是"压缩过的短语"，递归解一次并缓存。
///
/// 坏数据（越界、长度非法、递归过深）一律抛 [FormatException] 或提前结束，
/// **不制造乱码**。
class _HuffCdic {
  /// 256 项：`code >> 24` → (码长, 是否终端, 归一化 maxcode)
  final List<({int codelen, bool term, int maxcode})> dict1 = [];

  /// codelen=0..32 的 min/max 归一化码表（0 号是占位）
  final List<int> mincode = [];
  final List<int> maxcode = [];

  final List<Uint8List> _phrases = [];
  final List<Uint8List?> _decoded = [];

  int get phraseCount => _phrases.length;

  void loadHuff(Uint8List huff) {
    if (huff.length < 24) throw const FormatException('HUFF 记录太短');
    if (_ascii(huff, 0, 4) != 'HUFF') {
      throw const FormatException('HUFF magic 不对');
    }
    final off1 = _u32(huff, 8);
    final off2 = _u32(huff, 12);
    if (off1 + 256 * 4 > huff.length || off2 + 64 * 4 > huff.length) {
      throw const FormatException('HUFF 字典表越界');
    }
    dict1.clear();
    for (var i = 0; i < 256; i++) {
      final v = _u32(huff, off1 + i * 4);
      final codelen = v & 0x1f;
      final term = (v & 0x80) != 0;
      if (codelen == 0 || codelen > 32) {
        throw const FormatException('HUFF 码长非法');
      }
      final raw = v >> 8;
      dict1.add((
        codelen: codelen,
        term: term,
        maxcode: ((raw + 1) << (32 - codelen)) - 1,
      ));
    }
    mincode
      ..clear()
      ..add(0);
    maxcode
      ..clear()
      ..add(0);
    for (var codelen = 1; codelen <= 32; codelen++) {
      final min = _u32(huff, off2 + (codelen - 1) * 8);
      final max = _u32(huff, off2 + (codelen - 1) * 8 + 4);
      mincode.add(min << (32 - codelen));
      maxcode.add(((max + 1) << (32 - codelen)) - 1);
    }
  }

  void loadCdic(Uint8List cdic) {
    if (cdic.length < 16) throw const FormatException('CDIC 记录太短');
    if (_ascii(cdic, 0, 4) != 'CDIC') {
      throw const FormatException('CDIC magic 不对');
    }
    final phrases = _u32(cdic, 8);
    final bits = _u32(cdic, 12);
    if (bits > 16) throw const FormatException('CDIC 短语位宽非法');
    var n = 1 << bits;
    final remain = phrases - _phrases.length;
    if (remain < n) n = remain < 0 ? 0 : remain;
    if (n == 0) return;
    if (16 + n * 2 > cdic.length) throw const FormatException('CDIC 偏移表越界');
    for (var i = 0; i < n; i++) {
      final off = _u16(cdic, 16 + i * 2);
      final at = 16 + off;
      if (at + 2 > cdic.length) throw const FormatException('CDIC 短语偏移越界');
      final blen = _u16(cdic, at);
      final len = blen & 0x7fff;
      if (18 + off + len > cdic.length) {
        throw const FormatException('CDIC 短语长度越界');
      }
      // 最高位是"已解码"标志：置位说明这一条本来就是明文
      _phrases.add(Uint8List.sublistView(cdic, 18 + off, 18 + off + len));
      _decoded.add((blen & 0x8000) != 0 ? _phrases.last : null);
    }
  }

  /// 解压一条正文记录。
  Uint8List unpack(Uint8List data) => _unpackWithDepth(data, 0);

  /// 实际解码循环；[depth] 是"压缩短语"的递归深度（坏数据防打爆栈）。
  Uint8List _unpackWithDepth(Uint8List data, int depth) {
    if (depth > 32) throw const FormatException('HUFF 短语递归过深');
    final buf = Uint8List(data.length + 8);
    buf.setRange(0, data.length, data);
    var bitsleft = data.length * 8;
    var pos = 0;
    var x = _readU64(buf, 0);
    var n = 32;
    final out = BytesBuilder(copy: false);
    while (true) {
      if (n <= 0) {
        pos += 4;
        x = _readU64(buf, pos);
        n += 32;
      }
      final code = (x >>> n) & 0xFFFFFFFF;
      final head = dict1[code >> 24];
      var codelen = head.codelen;
      var maxc = head.maxcode;
      if (!head.term) {
        // 非终端码：按 dict2 的 min/max 表把码长加长到包含 code 的那一档
        while (codelen <= 32 && code < mincode[codelen]) {
          codelen++;
        }
        if (codelen > 32) break; // 坏码流：停，不猜
        maxc = maxcode[codelen];
      }
      n -= codelen;
      bitsleft -= codelen;
      if (bitsleft < 0) break;
      final r = (maxc - code) >> (32 - codelen);
      if (r < 0 || r >= _phrases.length) break; // 越界：坏字典，停
      var phrase = _decoded[r];
      if (phrase == null) {
        phrase = _unpackWithDepth(_phrases[r], depth + 1);
        _decoded[r] = phrase;
      }
      out.add(phrase);
    }
    return out.takeBytes();
  }
}

/// 大端 u64（Dart 的 int 是 64 位，高位置 1 时变成负数 —— `>>>` 负责当无符号用）
int _readU64(Uint8List d, int pos) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | (pos + i < d.length ? d[pos + i] : 0);
  }
  return v;
}

/// 文字编码：65001 = UTF-8，其余按 CP1252（MOBI 老书的默认值，事实上的 Latin-1）。
String _decode(Uint8List bytes, int encoding) {
  if (encoding == 65001) {
    return utf8.decode(bytes, allowMalformed: true);
  }
  return _decodeCp1252(bytes);
}

/// CP1252 → String。0x80..0x9F 是 Windows 的"私有"区（弯引号、破折号…），
/// 其余与 Latin-1 一一对应。Dart 标准库没有这个表，自己带一份。
String _decodeCp1252(Uint8List bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.writeCharCode(b >= 0x80 && b <= 0x9f ? _kCp1252[b - 0x80] : b);
  }
  return buf.toString();
}

const List<int> _kCp1252 = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
];

// ------------------------------------------------------------------ 图片

/// 图片 magic number → 扩展名（不是图片就返回 null）
String? _imageKind(Uint8List b) {
  if (b.length < 4) return null;
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'jpg';
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return 'png';
  }
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
  if (b[0] == 0x42 && b[1] == 0x4D) return 'bmp';
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'webp';
  }
  return null;
}

/// `firstImageIndex` 之后的图片记录 → `recindex` 解析表 + 资源表。
///
/// 返回 (序号 → 资源路径, 资源路径 → 字节, 文件里用没用 0-based 的 recindex)。
({Map<int, String> index, Map<String, Uint8List> resources}) _collectImages(
  _PalmDb db,
  _MobiHeader h,
) {
  final index = <int, String>{};
  final resources = <String, Uint8List>{};
  final first = h.firstImageIndex;
  if (first <= 0 || first >= db.records.length) {
    return (index: index, resources: resources);
  }
  for (var i = first; i < db.records.length; i++) {
    final rec = db.records[i];
    final kind = _imageKind(rec);
    if (kind == null) continue;
    final ordinal = i - first;
    final name = 'mobi-img-$ordinal.$kind';
    index[ordinal] = name;
    resources[name] = rec;
  }
  return (index: index, resources: resources);
}

/// `recindex` → 资源路径。1-based 是主流，但个别工具产的文件用 0-based；
/// 文档里出现过 `recindex="0"` 就整本按 0-based 解释（两种都测得到）。
String? _imageForIndex(Map<int, String> index, int recindex, bool zeroBased) {
  final ordinal = zeroBased ? recindex : recindex - 1;
  return index[ordinal];
}

// ------------------------------------------------------------------ 切章

class _MobiToc {
  _MobiToc(this.offset, this.title);
  final int offset;
  final String title;
}

/// 书**自带**的目录：`<a filepos="N">标题</a>` 的递增序列。
///
/// 起点优先用 `<guide><reference type="toc" filepos="N">`（MOBI6 的"目录页"约定），
/// 拿不到就从文档头扫。只接受**严格递增**的目标偏移，遇到回退就停 —— 这样正文里的
/// 脚注/回链（目标往回指）不会污染目录。
List<_MobiToc> _mobiToc(String latin, int encoding) {
  final refRe = RegExp(r'<reference\b[^>]*>', caseSensitive: false);
  int? start;
  for (final m in refRe.allMatches(latin)) {
    final tag = m.group(0)!;
    if (!RegExp(r'type\s*=\s*"?toc"?', caseSensitive: false).hasMatch(tag)) {
      continue;
    }
    final f = RegExp(
      r'filepos\s*=\s*"?(\d+)"?',
      caseSensitive: false,
    ).firstMatch(tag);
    if (f != null) {
      start = int.parse(f.group(1)!);
      break;
    }
  }

  final linkRe = RegExp(
    r'<a\s[^>]*filepos\s*=\s*"?(\d+)"?[^>]*>(.*?)</a\s*>',
    caseSensitive: false,
    dotAll: true,
  );
  final out = <_MobiToc>[];
  var last = -1;
  for (final m in linkRe.allMatches(latin)) {
    if (start != null && m.start < start) continue;
    final offset = int.parse(m.group(1)!);
    if (offset <= last) break;
    // 上面是在 **latin1 空间**里匹的（1 字符 == 1 字节，filepos 才是真实字节偏移），
    // 所以标题此刻是"把 UTF-8 字节当成 Latin-1 字符"的乱码串。必须把它编回字节、
    // 按 textEncoding 重新解码，否则中文目录标题会显示成 `c⃗-ä»¥c«` 这种。
    final title = _decode(
      Uint8List.fromList(latin1.encode(_stripTags(m.group(2) ?? ''))),
      encoding,
    ).trim();
    if (title.isEmpty) continue;
    out.add(_MobiToc(offset, title));
    last = offset;
  }
  return out.length >= 2 ? out : const [];
}

class _Slice {
  _Slice(this.start, this.end, {this.title, this.generated = false});
  final int start;
  final int end;
  String? title;
  bool generated;
}

/// 把偏移**对齐到一个 UTF-8 字符的起点**。
///
/// `filepos` / `<mbp:pagebreak>` 的语义都是**字节偏移**（不是字符下标）。但少数
/// 生成器（以及"用字符下标算偏移"的自造文件）会差几个字节，正好切在半个汉字上，
/// 解码出来就是 `�` 开头的乱码。真实文件里偏几个字节的情况最多；这里只往前走
/// 最多 3 字节（一个 UTF-8 序列的余数），正常文件完全不受影响。
int _alignUtf8(Uint8List raw, int offset, int encoding) {
  if (encoding != 65001) return offset.clamp(0, raw.length);
  var o = offset.clamp(0, raw.length);
  for (var step = 0; step < 3; step++) {
    if (o >= raw.length || (raw[o] & 0xC0) != 0x80) break;
    o++;
  }
  return o;
}

/// 把正文切成章：原书目录 → `<mbp:pagebreak>` → 单章（过大再按大小切）。
List<_Slice> _mobiSlices(
  Uint8List rawText,
  String latin,
  List<_MobiToc> toc, {
  int encoding = 65001,
}) {
  final total = rawText.length;
  if (total == 0) return const [];

  if (toc.isNotEmpty) {
    final slices = <_Slice>[];
    final sorted = [...toc]..sort((a, b) => a.offset.compareTo(b.offset));
    if (sorted.first.offset > 0) {
      // 目录第一条之前的封面页/书名页也是内容，别丢
      slices.add(
        _Slice(
          0,
          _alignUtf8(rawText, sorted.first.offset, encoding).clamp(0, total),
        ),
      );
    }
    for (var i = 0; i < sorted.length; i++) {
      final start = _alignUtf8(
        rawText,
        sorted[i].offset,
        encoding,
      ).clamp(0, total);
      final end = i + 1 < sorted.length
          ? _alignUtf8(
              rawText,
              sorted[i + 1].offset,
              encoding,
            ).clamp(start, total)
          : total;
      if (end <= start) continue;
      slices.add(_Slice(start, end, title: sorted[i].title));
    }
    if (slices.isNotEmpty) return slices;
  }

  final pageRe = RegExp(r'<mbp:pagebreak[^>]*>', caseSensitive: false);
  final bounds = <int>{0};
  for (final m in pageRe.allMatches(latin)) {
    if (m.end > 0 && m.end < total) bounds.add(m.end);
  }
  final ordered = bounds.toList()..sort();
  if (ordered.length >= 2) {
    return [
      for (var i = 0; i < ordered.length; i++)
        _Slice(ordered[i], i + 1 < ordered.length ? ordered[i + 1] : total),
    ];
  }
  return _sizeSplit(latin, total);
}

/// 既没目录也没分页符的书：单章，但太大就按大小切。
///
/// Quill 一次性渲染几 MB 的段落列表会非常卡，切段能用现有"上一章/下一章"救回来。
/// 切点尽量落在块级标签（`<p` / `<div` / `<mbp:pagebreak`）开头，不会把标签劈开。
List<_Slice> _sizeSplit(String latin, int total) {
  if (total <= _kSizeSplitBytes) return [_Slice(0, total)];
  const lookback = 8 * 1024;
  final out = <_Slice>[];
  var start = 0;
  while (start < total) {
    var end = (start + _kSizeSplitTarget).clamp(0, total);
    if (end < total) {
      final from = start + lookback > end ? start : end - lookback;
      final idx = _lastBlockStart(latin, from, end);
      if (idx != null && idx > start) end = idx;
    }
    if (end <= start) end = (start + _kSizeSplitTarget).clamp(0, total);
    out.add(_Slice(start, end, generated: true));
    start = end;
  }
  return out;
}

/// 在 `[from, to)` 里找**最后一个**块级标签起点
int? _lastBlockStart(String latin, int from, int to) {
  final re = RegExp(r'<(?:p|div|mbp:pagebreak)\b', caseSensitive: false);
  int? found;
  for (final m in re.allMatches(latin, from)) {
    if (m.start >= to) break;
    found = m.start;
  }
  return found;
}

// ------------------------------------------------------------------ 主流程

class _MobiDoc {
  _MobiDoc({
    required this.title,
    required this.author,
    required this.chapters,
    required this.toc,
    required this.anchors,
    required this.resources,
  });

  final String title;
  final String author;
  final List<BookChapter> chapters;
  final List<BookTocEntry> toc;
  final Map<String, int> anchors;
  final Map<String, Uint8List> resources;
}

_MobiDoc _readMobi(Uint8List bytes) {
  final db = _parsePalmDb(bytes);
  final header = _parseHeader(db);

  if (header.encryptionType != 0) {
    throw _MobiUnsupported('这本书带 DRM 加密，本阅读器不解密');
  }

  // joint MOBI/KF8（kindlegen 默认产物）在 record 0 里是 **MOBI6 头 + EXTH 121**
  // 指向 KF8 半边的 record 0；纯 KF8（AZW3）自己的 record 0 就是 MOBI8 头。
  //
  // **优先级：能用 KF8 半边就用 KF8 半边。** 理由：joint 是 kindlegen 的兼容
  // 双份，KF8 那半才是"现代"排版（skeleton/fragment、内链、NCX 目录），MOBI6
  // 那半是给老设备看的降级件；既然我们两种都能解，就选信息更全的那半。
  // **安全网**：joint 的 KF8 半边重组失败（FDST/索引损坏）时回落到同一文件里的
  // MOBI6 半边 —— joint 一定有 MOBI6 兜底，所以对 KF8 半边可以"先试后回落"；
  // 纯 KF8 没有退路，失败时把原因原样交给界面（能力边界，不吐半截正文）。
  final isJoint = header.mobiVersion < 8 && header.kf8Boundary > 0;
  if (header.mobiVersion >= 8 || isJoint) {
    try {
      return _readKf8(db);
    } catch (e) {
      if (header.mobiVersion >= 8) {
        if (e is _MobiUnsupported) rethrow;
        throw _MobiUnsupported('这本 AZW3 的 KF8 正文无法重组（$e）');
      }
      // joint：KF8 半边坏了 → 落到下面的 MOBI6 路径（同一文件里的兼容半边）
    }
  }

  return _readMobi6(db, header);
}

/// MOBI6 半边（也是纯 MOBI6 书的唯一路径）。
_MobiDoc _readMobi6(_PalmDb db, _MobiHeader header) {
  final rawText = _extractText(db, header);
  if (rawText.isEmpty) throw const FormatException('MOBI 正文为空');

  final images = _collectImages(db, header);

  // 结构扫描在 Latin-1 空间做：那里"字符下标 == 字节下标"，
  // 而 `filepos` 正是**字节偏移**（UTF-8 书里两者不等，直接用 String 下标会错位）。
  final latin = latin1.decode(rawText);

  final usedRecindex = _recindexValues(latin);
  final zeroBased = usedRecindex.contains(0);

  final tocEntries = _mobiToc(latin, header.textEncoding);
  final slices = _mobiSlices(
    rawText,
    latin,
    tocEntries,
    encoding: header.textEncoding,
  );

  final chapters = <BookChapter>[];
  final toc = <BookTocEntry>[];
  for (var i = 0; i < slices.length; i++) {
    final s = slices[i];
    // ⚠️ 内容必须**按字节切片再按 textEncoding 解码**：`latin` 只是用来算
    // 偏移的（1 字符 = 1 字节），直接 substring 会把 UTF-8 正文变成乱码。
    final fragment = _mobiFragment(
      _decode(
        Uint8List.sublistView(rawText, s.start, s.end),
        header.textEncoding,
      ),
      images: images.index,
      zeroBased: zeroBased,
    );
    var title = s.title;
    var generated = false;
    if (title == null || title.trim().isEmpty) {
      title = _firstHeading(fragment);
    }
    if (title == null || title.trim().isEmpty) {
      // 按大小切出来的"伪章节"叫「第 N 节」更诚实：它不是书里真有的章
      title = s.generated ? '第 ${i + 1} 节' : '第 ${i + 1} 章';
      generated = true;
    }
    // 兜底标题的类别：按大小切的 → 节；有目录/分页符切出的多段 → 章；单段 → 正文
    final BookGeneratedUnit? unit = s.generated
        ? BookGeneratedUnit.section
        : (!generated
              ? null
              : (slices.length > 1
                    ? BookGeneratedUnit.chapter
                    : BookGeneratedUnit.body));
    final index = chapters.length;
    chapters.add(
      BookChapter(
        title: title.trim(),
        generatedUnit: unit,
        html: fragment,
        // MOBI 没有"章文件路径"这个概念：图片走 resources 里的合成路径，
        // 锚点键就是裸 `#f<偏移>`（与 FB2 同款）
        href: '',
      ),
    );
    if (tocEntries.isNotEmpty && s.title != null) {
      toc.add(BookTocEntry(title: title.trim(), chapterIndex: index));
    }
  }

  // 锚点：正文里每个 `filepos` 目标 → 它落在第几段。
  // 这样 MOBI6 的目录链接、脚注、索引全都能走阅读器现成的 `anchorFor` 跳转。
  final anchors = <String, int>{};
  for (final target in _allFilepos(latin)) {
    final idx = _chapterAt(slices, target);
    if (idx != null) anchors['#f$target'] = idx;
  }

  return _MobiDoc(
    title: _mobiTitle(header, db),
    author: _exthString(header.exth, 100, header.textEncoding),
    chapters: chapters,
    toc: toc,
    anchors: anchors,
    resources: images.resources,
  );
}

// ------------------------------------------------------------------ KF8 主流程

/// KF8 重组结果：完整 XHTML 段（每个 skeleton 一段）+ 索引表 + flow 表 +
/// 每段在 **flow0（原始 rawML）里的字节区间**。
///
/// [partRanges] 与 KindleUnpack `K8Processor.partinfo` 的 `[skelpos, baseptr]`
/// 同口径，是 NCX/guide 的 `pos`（也是 rawML 坐标）→ 段号的**可靠**映射依据。
class _Kf8Book {
  _Kf8Book({
    required this.parts,
    required this.skeletons,
    required this.fragments,
    required this.flows,
    required this.partRanges,
  });
  final List<Uint8List> parts;
  final List<_Kf8Skeleton> skeletons;
  final List<_Kf8Fragment> fragments;
  final List<Uint8List> flows;
  final List<({int start, int end})> partRanges;
}

/// KF8 的完整重组：FDST → flow 表 → skeleton/fragment 索引 → 拼回 XHTML。
///
/// 读不出关键一环（skeleton/fragment 索引）都抛 [_MobiUnsupported]（界面给清晰
/// 错误），**不产出半截正文**。
///
/// [allowMissingFdst]：FDST 缺失时是否退化成"整段 rawML 就是 flow0"。
///   * **joint** 传 true：真实 joint 样本（libmobi 的三份 kindlegen 风格组合包）
///     全都**没有 FDST**（`0xC0 = 0xFFFFFFFF`），KindleUnpack 此时把整个 rawML
///     当成一个 flow，照样能重组出正文；不这么做的话真实 joint 书根本读不出 KF8。
///   * **纯 KF8** 传 false：保持既有已发布契约（FDST 缺失 → 明确报错），
///     这是上一批已经钉住的边界，不在本次改动里放宽。
///   * FDST **在但坏**（magic/段表/偏移非法）永远报错，与是否 joint 无关。
_Kf8Book _kf8Book(
  _PalmDb db,
  _MobiHeader h,
  Uint8List rawText, {
  bool allowMissingFdst = false,
}) {
  final fdst = _kf8Fdst(db, h, allowMissing: allowMissingFdst);
  final skeletons = _kf8Skeletons(_kf8Index(db, h.skelIndex, 'skeleton'));
  final fragments = _kf8Fragments(_kf8Index(db, h.fragIndex, 'fragment'));
  if (skeletons.isEmpty) {
    throw _MobiUnsupported('这本 AZW3 的 KF8 skeleton 索引为空，无法重组正文');
  }
  final parts = _kf8Rebuild(rawText, fdst, skeletons, fragments);
  if (parts.every((p) => p.isEmpty)) {
    throw _MobiUnsupported('这本 AZW3 的 KF8 重组结果为空，无法读出正文');
  }
  final flows = <Uint8List>[];
  if (fdst.isEmpty) {
    // 没有 FDST：整份 rawML 就是 flow0（与 KindleUnpack `fdsttbl=[0,0xffffffff]`
    // 的退化行为一致）
    flows.add(rawText);
  } else {
    final bounds = [...fdst, rawText.length];
    for (var i = 0; i + 1 < bounds.length; i++) {
      if (bounds[i] < 0 ||
          bounds[i] > bounds[i + 1] ||
          bounds[i + 1] > rawText.length) {
        throw _MobiUnsupported('这本 AZW3 的 FDST 偏移越界，无法重组正文');
      }
      flows.add(Uint8List.sublistView(rawText, bounds[i], bounds[i + 1]));
    }
  }
  return _Kf8Book(
    parts: parts,
    skeletons: skeletons,
    fragments: fragments,
    flows: flows,
    partRanges: _kf8PartRanges(skeletons, fragments),
  );
}

/// 取 KF8 半边：纯 KF8 → record 0 自己；joint MOBI/KF8 → EXTH 121（或 `BOUNDARY`
/// 记录）之后的 KF8 record 0。
///
/// **用子 PalmDB（`records.sublist(start)`）而不是逐个字段加基址**：KF8 头里的
/// HUFF/FDST/FCIS/FLIS/NCX/fragment/skeleton/guide/firstImage 索引都是**相对 KF8
/// record 0** 的（KindleUnpack `MobiHeader` 对 `start != 0` 一律 `+= start`，本文件
/// 的纯 KF8 就是 start=0 的特例）。子表把"相对索引"直接变成"子表里的绝对索引"，
/// 于是 `_extractText` / `_collectImages` / `_kf8Book` 这些既有代码一行都不用改。
_PalmDb _kf8SubDb(_PalmDb fullDb) {
  final base = _parseHeader(fullDb);
  if (base.mobiVersion >= 8) return fullDb;
  var start = base.kf8Boundary;
  if (!_looksLikeMobiRecord(fullDb, start)) start = _findBoundary(fullDb);
  if (!_looksLikeMobiRecord(fullDb, start)) {
    throw _MobiUnsupported('这是 joint MOBI/KF8，但找不到 KF8 半边（边界记录损坏）');
  }
  final sub = _PalmDb(fullDb.records.sublist(start));
  if (_parseHeader(sub).mobiVersion < 8) {
    throw _MobiUnsupported('这是 joint MOBI/KF8，但 KF8 半边不是 MOBI8 头');
  }
  return sub;
}

/// KF8 半边 + 它是不是 joint 里的那一半（决定 FDST 缺失是否可容忍）。
({_PalmDb db, _MobiHeader header, bool joint}) _kf8Half(_PalmDb fullDb) {
  final joint = _parseHeader(fullDb).mobiVersion < 8;
  final db = _kf8SubDb(fullDb);
  return (db: db, header: _parseHeader(db), joint: joint);
}

bool _looksLikeMobiRecord(_PalmDb db, int i) =>
    i > 0 && i < db.records.length && _ascii(db.records[i], 16, 4) == 'MOBI';

/// 扫描 8 字节的 `BOUNDARY` 记录（KindleUnpack `unpackBook` 的判据）：
/// joint 文件在 MOBI6 与 KF8 之间插一条恰好 `BOUNDARY` 的 8 字节记录，
/// 紧随其后的就是 KF8 record 0。EXTH 121 缺失/损坏时用它兜底。
int _findBoundary(_PalmDb db) {
  for (var i = 0; i + 1 < db.records.length; i++) {
    final r = db.records[i];
    if (r.length == 8 && _ascii(r, 0, 8) == 'BOUNDARY') return i + 1;
  }
  return -1;
}

/// KF8 的正文入口：重组 → 每段 XHTML 一段"章节"，再接 NCX / guide 目录。
///
/// 元数据（书名 / 作者）复用 MOBI6 那套 EXTH 读取；语言代码读在
/// [_MobiHeader.languageCode]（`BookContent` 目前没有语言字段，界面侧不用）。
///
/// **明确没做**（见 `docs/ebook-reader-plan.md`）：CSS/SVG flow 的原样内联。
/// NCX/guide → `BookContent.toc` 已接；`kindle:pos:fid` 内部链接 → 改写 +
/// `BookContent.anchors` 也已接（见 [_Kf8LinkMap]）。
_MobiDoc _readKf8(_PalmDb fullDb) {
  final half = _kf8Half(fullDb);
  final db = half.db;
  final h = half.header;
  final rawText = _extractText(db, h);
  if (rawText.isEmpty) throw const FormatException('KF8 正文为空');
  final images = _collectImages(db, h);
  final book = _kf8Book(db, h, rawText, allowMissingFdst: half.joint);
  final flowImages = _kf8FlowImages(book.flows, images.index);
  // 内部链接（`kindle:pos:fid`）→ 我们文档里的定位；锚点表随链接改写一起建。
  final links = _Kf8LinkMap(book);

  final chapters = <BookChapter>[];
  for (var i = 0; i < book.parts.length; i++) {
    final html = _decode(book.parts[i], h.textEncoding);
    final fragment = _mobiFragment(
      html,
      images: images.index,
      // KF8 不用 MOBI6 的 `recindex`；真要用，1-based 是主流（KF8 的
      // `kindle:embed:XXXX` 由 [_kf8ImageForSrc] 单独按 1-based 图片号解）
      zeroBased: false,
      flowImages: flowImages,
      kf8Links: links,
    );
    final titleTag = _firstTitleText(html);
    final title = (titleTag != null && titleTag.trim().isNotEmpty)
        ? titleTag.trim()
        : _firstHeading(fragment);
    chapters.add(
      BookChapter(
        title: (title == null || title.isEmpty) ? '第 ${i + 1} 章' : title,
        generatedUnit: (title == null || title.isEmpty)
            ? (book.parts.length > 1
                  ? BookGeneratedUnit.chapter
                  : BookGeneratedUnit.body)
            : null,
        html: fragment,
        // 合成路径：内部链接的锚点键（`part00NN.xhtml#id`）要用它做基准
        href: _Kf8LinkMap.partHref(i),
      ),
    );
  }

  return _MobiDoc(
    title: _mobiTitle(h, db),
    author: _exthString(h.exth, 100, h.textEncoding),
    chapters: chapters,
    toc: _kf8Toc(db, h, book),
    anchors: links.anchors,
    resources: images.resources,
  );
}

// ------------------------------------------------------- KF8 目录（NCX / guide）

/// KF8 的目录：**优先 NCX（`0xF4`）**，只有 NCX 读不出/为空时才用 guide（`0x104`）。
///
/// 取舍（与 KindleUnpack 一致的口径）：
///   * NCX 是"书名层级目录树"（`navPoint` 的 `hlvl`/`child1`/`childn`），语义就是
///     `BookContent.toc`，所以它非空时**只用 NCX**；
///   * guide 是 OPF 的"地标"（`cover`/`toc`/`text`/`start`），不是章节树；把
///     "Table of Contents"/"Cover" 混进章节目录只会重复/噪声，所以**仅当 NCX 缺失
///     或没有可映射条目时**用它兜底（拍平成一层，`depth = 0`）。
///
/// 任何一步解析失败都**只让目录为空，不影响正文**（正文已经重组成功）。
List<BookTocEntry> _kf8Toc(_PalmDb db, _MobiHeader h, _Kf8Book book) {
  final ncx = _kf8Ncx(db, h, book);
  if (ncx.isNotEmpty) return ncx;
  return _kf8Guide(db, h, book);
}

/// NCX INDX（`0xF4`）→ 带层级的 [BookTocEntry]。
///
/// 字段（KindleUnpack `ncxExtract.parseNCX` 的 `tag_fieldname_map` 同款）：
///   * tag 1 `pos`   → 目标在 **rawML（flow0）里的字节位置**；
///   * tag 3 `noffs` → CTOC 表偏移，取出来才是 `navLabel` 的**标题文本**；
///   * tag 4 `hlvl`  → 层级（0 = 顶层）；
///   * tag 21/22/23  → parent / child1 / childn（`hlvl` 缺失时用来推层级）。
///
/// `pos` → 段号用 [partRanges]（skeleton 的 `[start, end)`，与 KindleUnpack
/// `partinfo` 同口径）映射，与 `_Kf8LinkMap` 的 `kindle:pos:fid` 解析是**两条
/// 独立路径**（后者解 `fid`/`off`，前者直接用 NCX 的 `pos`）。落在所有骨架区间
/// 之外、或标题为空、或段号越界的条目**跳过**（宁可少一条目录，也不给一个会跳到
/// 错地方的条目）。
List<BookTocEntry> _kf8Ncx(_PalmDb db, _MobiHeader h, _Kf8Book book) {
  // 目录是**可选**信息：NCX 记录缺失/损坏（含越界）一律退化成"没有目录"，
  // 绝不让它把已经重组好的正文一起拖失败。
  final _Kf8IndexBlock block;
  try {
    block = _kf8Index(db, h.ncxIndex, 'NCX');
  } catch (_) {
    return const [];
  }
  final out = <BookTocEntry>[];
  for (var i = 0; i < block.entries.length; i++) {
    final e = block.entries[i];
    final title = _ncxTitle(e, block, h);
    if (title.isEmpty) continue;
    final chapter = _kf8PartForPos(
      book.partRanges,
      book.fragments,
      e.value(1) ?? -1,
    );
    if (chapter == null) continue;
    out.add(
      BookTocEntry(
        title: title,
        chapterIndex: chapter,
        depth: _ncxDepth(block, i),
      ),
    );
  }
  return out;
}

/// NCX 条目的标题：tag 3（CTOC 偏移）是 `navLabel` 的正文；取不到再退回条目文本。
String _ncxTitle(_Kf8IndexEntry e, _Kf8IndexBlock block, _MobiHeader h) {
  final noffs = e.value(3);
  if (noffs != null) {
    final raw = block.ctoc[noffs];
    if (raw != null) {
      final text = _decode(raw, h.textEncoding).trim();
      if (text.isNotEmpty) return text;
    }
  }
  return _decode(e.text, h.textEncoding).trim();
}

/// NCX 条目的层级：tag 4（`hlvl`）优先；没有就顺着 tag 21（parent）往上数。
int _ncxDepth(_Kf8IndexBlock block, int index) {
  var i = index;
  var depth = 0;
  final seen = <int>{};
  while (i >= 0 && i < block.entries.length && seen.add(i)) {
    final e = block.entries[i];
    final hlvl = e.value(4);
    if (hlvl != null && hlvl >= 0) return depth + hlvl;
    final parent = e.value(21);
    if (parent == null || parent < 0 || parent >= i) return depth;
    i = parent;
    depth++;
  }
  return depth;
}

/// guide INDX（`0x104`）→ 拍平的目录（NCX 缺失时的兜底）。
///
/// 条目文本是 `ref_type`（`cover`/`toc`/`text`/…），tag 1 是 CTOC 偏移
/// （`ref_title`），tag 3/6 是 **fragment 表行号**。行号 → 该碎片的 `insertPos`
/// → 段号（同 [partRanges]）。`thumbimagestandard` 是缩略图，跳过。
List<BookTocEntry> _kf8Guide(_PalmDb db, _MobiHeader h, _Kf8Book book) {
  // 同 [_kf8Ncx]：guide 也是可选信息，坏了只丢目录，不拖垮正文。
  final _Kf8IndexBlock block;
  try {
    block = _kf8Index(db, h.guideIndex, 'guide');
  } catch (_) {
    return const [];
  }
  final out = <BookTocEntry>[];
  for (final e in block.entries) {
    final type = _decode(e.text, h.textEncoding).trim();
    if (type.isEmpty || type == 'thumbimagestandard') continue;
    final titleOff = e.value(1);
    final raw = titleOff == null ? null : block.ctoc[titleOff];
    final title = raw == null ? type : _decode(raw, h.textEncoding).trim();
    final fileno = e.value(3) ?? e.value(6);
    if (fileno == null || fileno < 0 || fileno >= book.fragments.length) {
      continue;
    }
    final chapter = _kf8PartForPos(
      book.partRanges,
      book.fragments,
      book.fragments[fileno].insertPos,
    );
    if (chapter == null) continue;
    out.add(
      BookTocEntry(title: title.isEmpty ? type : title, chapterIndex: chapter),
    );
  }
  return out;
}

/// 每段在 flow0（rawML）里的字节区间 `[start, end)` —— KindleUnpack
/// `K8Processor.partinfo` 的 `[skelpos, baseptr]` 同款：从 skeleton.start 起，
/// 加上骨架长度与它名下所有碎片的长度。
List<({int start, int end})> _kf8PartRanges(
  List<_Kf8Skeleton> skeletons,
  List<_Kf8Fragment> fragments,
) {
  final ranges = <({int start, int end})>[];
  var fragPtr = 0;
  for (final sk in skeletons) {
    var end = sk.start + sk.length;
    for (var i = 0; i < sk.fragCount; i++) {
      if (fragPtr >= fragments.length) break;
      end += fragments[fragPtr].length;
      fragPtr++;
    }
    ranges.add((start: sk.start, end: end));
  }
  return ranges;
}

/// rawML 位置 → 段号。
///
/// 先看落在哪个骨架区间；落在区间之外（例如指向某个 fragment 内部又跨了骨架
/// 边界）时退化为"第一条覆盖它的 fragment 的 `fileNum`"（KindleUnpack
/// `getIDTagByPosFid` 的 retarget 思路）。都映射不到 → null，调用方跳过该条目。
int? _kf8PartForPos(
  List<({int start, int end})> ranges,
  List<_Kf8Fragment> fragments,
  int pos,
) {
  if (pos < 0) return null;
  for (var i = 0; i < ranges.length; i++) {
    if (pos >= ranges[i].start && pos < ranges[i].end) return i;
  }
  for (final f in fragments) {
    if (pos < f.insertPos + f.length) {
      return (f.fileNum >= 0 && f.fileNum < ranges.length) ? f.fileNum : null;
    }
  }
  return null;
}

// ------------------------------------------------ KF8 内部链接（kindle:pos:fid）

/// 定位不了的 KF8 内部链接统一改写成的 href：书内锚点形态，但**不注册**到
/// `anchors`，阅读器会走"链接目标不在书里"提示 —— 明确降级，不静默失效
/// （不改的话 `kindle:` 会被 [classifyBookLink] 当外链去开系统浏览器）。
const String _kKf8UnsupportedHref = '#kf8-unsupported';

/// "目标段开头"的合成锚点：KF8 的 `pos:fid` 有时只给到段首（KindleUnpack 的
/// `getIDTag` 返回空），这种就跳到该段（章）开头。
const String _kKf8TopAnchor = 'kf8-top';

/// KF8 内部链接（`kindle:pos:fid:<fid>:off:<off>`）→ 本文档定位。
///
/// KF8 的链接目标不是文件名，而是"位置"：`fid` 是 **fragment 表行号**（base32），
/// `off` 是相对该 fragment `insertPos` 的字节位移（base32）。位置 =
/// fragment 的 `insertPos + off`；再按骨架区间定位到段（part），并找该位置前
/// **最近一个带 `id` / `name` / `aid` 的标签**（KindleUnpack v0.83
/// `K8Processor.getIDTag` / `getIDTagByPosFid` 同款 —— 这就是"aid → 位置"映射）。
///
/// 结果写回成书内链接 `part00NN.xhtml[#anchor]`，并把 [anchors] 指到对应段号
/// （[BookTocEntry.chapterIndex] 那套段号），阅读器现成的 `anchorFor` 就能跳。
///
/// **支持范围 / 不支持形态**（都明确降级，不静默失效）：
///   * `kindle:pos:fid:<fid>:off:<off>` 且 fid/位移能定位 → 正常跳转；
///   * fid 越界 / 目标段找不到（连 fragment 声明的骨架也越界）→ `#kf8-unsupported`；
///   * 其它 `kindle:` 链接（`kindle:flow:` 等）→ `#kf8-unsupported`。
class _Kf8LinkMap {
  _Kf8LinkMap(this._book);

  final _Kf8Book _book;

  /// 原始 href → 改写后的 href（同一条链接重复出现只解析一次）
  final Map<String, String> _cache = {};

  /// `part00NN.xhtml[#anchor]` → 段号（直接进 `BookContent.anchors`）
  final Map<String, int> anchors = {};

  /// 解析成功 / 降级的**不同链接**条数（探针与测试用）
  int resolved = 0;
  int unsupported = 0;

  static final _posFid = RegExp(
    r'^kindle:pos:fid:([0-9A-V]+):off:([0-9A-V]+)',
    caseSensitive: false,
  );

  /// 段号 → 我们给 KF8 章节用的合成 href（与 KindleUnpack 的 `part%04d.xhtml`
  /// 同形；`anchors` 的键也用它）。
  static String partHref(int part) =>
      'part${part.toString().padLeft(4, '0')}.xhtml';

  /// 改写一段正文里的 `<a href>`；不是 KF8 内部链接（外链 / 锚点）返回 null。
  String? rewrite(String href) {
    final raw = href.trim();
    if (!raw.toLowerCase().startsWith('kindle:')) return null;
    return _cache.putIfAbsent(raw, () {
      final m = _posFid.firstMatch(raw);
      if (m == null) {
        unsupported++;
        return _kKf8UnsupportedHref;
      }
      final target = resolve(m.group(1)!, m.group(2)!);
      if (target == null) {
        unsupported++;
        return _kKf8UnsupportedHref;
      }
      resolved++;
      final frag = target.anchor.isEmpty ? _kKf8TopAnchor : target.anchor;
      final full = '${partHref(target.part)}#$frag';
      anchors[full] = target.part;
      return full;
    });
  }

  /// 解析一条 `fid`/`off` → 目标段 + 锚点 id；定位不了返回 null。
  ({int part, String anchor})? resolve(String fid, String off) {
    final row = _kf8Base32(fid);
    if (row < 0 || row >= _book.fragments.length) return null;
    final f = _book.fragments[row];
    var pos = f.insertPos + _kf8Base32(off);
    var part = _kf8PartIndexAt(_book.partRanges, pos);
    if (part == null) {
      // 位置落在所有骨架区间之外：退回到该 fragment 声明的骨架开头
      // （KindleUnpack `getIDTagByPosFid` 的 retarget 同款）。
      if (f.fileNum < 0 || f.fileNum >= _book.partRanges.length) return null;
      part = f.fileNum;
      pos = _book.partRanges[part].start;
    }
    final anchor = _kf8NearestAnchorId(
      _book.parts[part],
      pos - _book.partRanges[part].start,
    );
    return (part: part, anchor: anchor);
  }
}

/// `pos` 严格落在哪个骨架区间 `[start, end)`；不在任何区间时返回 null。
///
/// 与 [kf8PartForPos] 的"fragment 兜底"区别开：链接解析要先拿到严格区间，
/// 区间外再按 KindleUnpack 的 retarget 规则退回到 fragment 声明的骨架。
int? _kf8PartIndexAt(List<({int start, int end})> ranges, int pos) {
  if (pos < 0) return null;
  for (var i = 0; i < ranges.length; i++) {
    if (pos >= ranges[i].start && pos < ranges[i].end) return i;
  }
  return null;
}

/// `getIDTag` 用的三个属性正则：`id` / `name`（值可为空）与 `aid`（值非空）。
/// 与 KindleUnpack v0.83 `K8Processor.getIDTag` 的 `id_pattern` / `name_pattern`
/// / `aid_pattern` 同款，`^` 锚定到标签开头。
final _kf8IdAttr = RegExp(r'''^<[^>]*\sid\s*=\s*["']([^"']*)["']''');
final _kf8NameAttr = RegExp(r'''^<[^>]*\sname\s*=\s*["']([^"']*)["']''');
final _kf8AidAttr = RegExp(r'''^<[^>]+\s(?:aid|AID)\s*=\s*["']([^"']+)["']''');

/// 找 [part] 里字节位置 [posInPart] 之前**最近一个**带 `id` / `name` / `aid`
/// 的标签，返回它的锚点名（aid 加 `aid-` 前缀）；没有则空串。
///
/// 逐字对齐 KindleUnpack v0.83 `K8Processor.getIDTag`：从后往前扫标签，
/// 先看 `id`，再看 `name`，最后看 `aid`；碰到 `<body …>` 就停（返回空）。
/// 用 Latin-1 解码是为了"字节下标 == 字符下标"，属性值都是 ASCII。
String _kf8NearestAnchorId(Uint8List part, int posInPart) {
  var npos = posInPart;
  if (npos < 0) npos = 0;
  if (npos > part.length) npos = part.length;
  // 位置落在标签内部时，跳到该标签的 `>` 之后（参考实现同款校正）。
  final pgt = _indexOf(part, 0x3E, npos);
  final plt = _indexOf(part, 0x3C, npos);
  if (plt == npos || pgt < plt) npos = pgt + 1;
  if (npos < 0) npos = 0;
  if (npos > part.length) npos = part.length;
  final head = latin1.decode(Uint8List.sublistView(part, 0, npos));
  var end = head.length;
  while (true) {
    final gt = end <= 0 ? -1 : head.lastIndexOf('>', end - 1);
    if (gt < 0) break;
    final lt = gt <= 0 ? -1 : head.lastIndexOf('<', gt - 1);
    if (lt < 0) break;
    final tag = head.substring(lt, gt + 1);
    end = lt;
    if (tag.startsWith('<body ')) return '';
    if (tag.startsWith('<meta ')) continue;
    final id = _kf8IdAttr.firstMatch(tag)?.group(1);
    if (id != null) return id;
    final name = _kf8NameAttr.firstMatch(tag)?.group(1);
    if (name != null) return name;
    final aid = _kf8AidAttr.firstMatch(tag)?.group(1);
    if (aid != null) return 'aid-$aid';
  }
  return '';
}

/// flow 号 → 一个可直接渲染的图片资源名。
///
/// KF8 的封面这类"整页图"是一个 **SVG flow**：`<img src="kindle:flow:NNNN
/// ?mime=image/svg+xml">`，而那个 flow 内部才是 `<image xlink:href=
/// "kindle:embed:XXXX?mime=image/jpeg">`。这里把 flow 里第一张 `kindle:embed`
/// 解出来当作这个 flow 的位图（KindleUnpack 是整段内联 SVG，我们只需要能看见图）。
///
/// 解不出来（不是 SVG / 没有 embed）→ 这个 flow 不进表，调用方会把这个 `<img>` 删掉。
Map<int, String> _kf8FlowImages(
  List<Uint8List> flows,
  Map<int, String> images,
) {
  final out = <int, String>{};
  for (var i = 0; i < flows.length; i++) {
    final latin = latin1.decode(flows[i]);
    if (!RegExp('kindle:embed:', caseSensitive: false).hasMatch(latin)) {
      continue;
    }
    final m = RegExp(
      r'kindle:embed:([0-9A-V]+)',
      caseSensitive: false,
    ).firstMatch(latin);
    if (m == null) continue;
    // `kindle:embed:XXXX` 的 XXXX 是 1-based 图片号（KindleUnpack `rscnames[n-1]`）
    final name = _imageForIndex(images, _kf8Base32(m.group(1)!), false);
    if (name != null) out[i] = name;
  }
  return out;
}

/// Kindle 的 base32 图片/flow 号 —— KindleUnpack `mobi_utils.fromBase32` 的移植：
/// 数字 `0-9` 值 0-9，字母 `A-V` 值 10-31，最低位是**最后**一个字符。
int _kf8Base32(String text) {
  const scale = [
    1,
    32,
    1024,
    32768,
    1048576,
    33554432,
    1073741824,
    34359738368,
  ];
  var value = 0;
  var j = 0;
  var s = 1;
  for (var i = text.length - 1; i >= 0; i--) {
    final c = text.codeUnitAt(i);
    final v = (c >= 0x30 && c <= 0x39) ? c - 0x30 : c - 0x41 + 10;
    if (j < scale.length) {
      s = scale[j];
    } else {
      s = s * 32;
    }
    j++;
    if (v > 0 && v < 32) value += v * s;
  }
  return value;
}

/// `<title>` 的文本（KF8 每个 part 的 `<title>` 就是它自己的章名，比正文里的
/// 第一个标题更准 —— 例如 "CHAPTER I.\nDown the Rabbit-Hole"）。
String? _firstTitleText(String html) {
  if (html.isEmpty) return null;
  final doc = htmlp.parse(html);
  final title = doc.querySelector('title')?.text;
  if (title == null) return null;
  return title.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 正文里所有 `filepos` 目标（去重，升序）
List<int> _allFilepos(String latin) {
  final re = RegExp(r'filepos\s*=\s*"?(\d+)"?', caseSensitive: false);
  final out = <int>{};
  for (final m in re.allMatches(latin)) {
    out.add(int.parse(m.group(1)!));
  }
  return out.toList()..sort();
}

int? _chapterAt(List<_Slice> slices, int offset) {
  for (var i = 0; i < slices.length; i++) {
    if (offset >= slices[i].start && offset < slices[i].end) return i;
  }
  return null;
}

/// 正文里用到的所有 `recindex` 值（判断 0-based / 1-based）
Set<int> _recindexValues(String latin) {
  final re = RegExp(r'recindex\s*=\s*"?(\d+)"?', caseSensitive: false);
  return {for (final m in re.allMatches(latin)) int.parse(m.group(1)!)};
}

/// 书名：EXTH 503（更新后的书名）优先，其次 MOBI 头的 `fullName`。
String _mobiTitle(_MobiHeader h, _PalmDb db) {
  final updated = _exthString(h.exth, 503, h.textEncoding);
  if (updated.isNotEmpty) return updated;
  final rec0 = db.records.first;
  final offset = _u32(rec0, 84);
  final length = _u32(rec0, 88);
  if (offset > 0 && length > 0 && offset + length <= rec0.length) {
    final name = _decode(
      Uint8List.sublistView(rec0, offset, offset + length),
      h.textEncoding,
    ).trim();
    if (name.isNotEmpty) return name;
  }
  return '';
}

/// 一段 MOBI6 / KF8 HTML → 我们能渲染的 HTML 片段。
///
/// 干四件事：剥掉 `<mbp:*>` 私有标签与 head 里的样式脚本；把
/// `<img recindex="N">` 换成 `src="<resources 里的键>"`（渲染层按 src 取字节）；
/// 把 KF8 的 `kindle:embed:XXXX` / `kindle:flow:NNNN` 图片引用解成同一个
/// `resources` 键（见 [flowImages]）；把 `<a filepos="N">` 换成 `<a href="#fN">`
/// （走阅读器现成的书内跳转）；KF8 的 `kindle:pos:fid` 内部链接交给 [kf8Links]
/// 重写成 `part00NN.xhtml#anchor`（见 [_Kf8LinkMap]）。
String _mobiFragment(
  String html, {
  required Map<int, String> images,
  required bool zeroBased,
  Map<int, String> flowImages = const {},
  _Kf8LinkMap? kf8Links,
}) {
  // `<mbp:pagebreak>` 这类私有标签先按字符串剥掉：`package:html` 会把它们
  // 当成未知元素留在 DOM 里，选择器写 `mbp\:pagebreak` 又很别扭。
  final cleaned = html.replaceAll(
    RegExp(r'<\s*mbp:[^>]*>', caseSensitive: false),
    '',
  );
  final doc = htmlp.parse(cleaned);
  for (final junk in doc.querySelectorAll('style, script, head, title')) {
    junk.remove();
  }
  final root = doc.body ?? doc.documentElement;
  if (root == null) return '';

  for (final img in root.querySelectorAll('img')) {
    final raw = img.attributes['recindex'];
    final recindex = raw == null ? null : int.tryParse(raw.trim());
    var name = recindex == null
        ? null
        : _imageForIndex(images, recindex, zeroBased);
    // KF8：MOBI6 的 recindex 换成了 `kindle:embed:XXXX?mime=…`（图片）
    // 与 `kindle:flow:NNNN?mime=image/svg+xml`（SVG flow，里面才是 embed）。
    name ??= _kf8ImageForSrc(img.attributes['src'], images, flowImages);
    if (name == null) {
      // 找不到对应图片记录：删掉这个空 img，别让渲染层画一个空框
      img.remove();
      continue;
    }
    img.attributes['src'] = name;
    img.attributes.remove('recindex');
  }

  for (final a in root.querySelectorAll('a[filepos]')) {
    final offset = int.tryParse((a.attributes['filepos'] ?? '').trim());
    if (offset == null) continue;
    a.attributes['href'] = '#f$offset';
    a.attributes.remove('filepos');
  }

  // KF8：`kindle:pos:fid` 之类内部链接 → 我们文档里的定位（或明确降级）。
  // 必须在 `filepos` 之后：KF8 不用 filepos，两者不会互相覆盖。
  if (kf8Links != null) {
    for (final a in root.querySelectorAll('a[href]')) {
      final href = a.attributes['href'];
      if (href == null) continue;
      final rewritten = kf8Links.rewrite(href);
      if (rewritten != null) a.attributes['href'] = rewritten;
    }
  }

  return root.innerHtml;
}

/// KF8 的 `src` 引用 → 资源键；不是 KF8 引用就返回 null。
String? _kf8ImageForSrc(
  String? src,
  Map<int, String> images,
  Map<int, String> flowImages,
) {
  if (src == null || src.isEmpty) return null;
  final embed = RegExp(
    r'^kindle:embed:([0-9A-V]+)',
    caseSensitive: false,
  ).firstMatch(src.trim());
  if (embed != null) {
    return _imageForIndex(images, _kf8Base32(embed.group(1)!), false);
  }
  final flow = RegExp(
    r'^kindle:flow:([0-9A-V]+)',
    caseSensitive: false,
  ).firstMatch(src.trim());
  if (flow != null) return flowImages[_kf8Base32(flow.group(1)!)];
  return null;
}

/// 取第一段的标题（h1..h4）
String? _firstHeading(String html) {
  if (html.isEmpty) return null;
  final doc = htmlp.parseFragment(html);
  for (final tag in const ['h1', 'h2', 'h3', 'h4']) {
    final text = doc.querySelector(tag)?.text.trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return null;
}

String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]*>'), ' ');

// ------------------------------------------------------------------ KF8
//
// 纯 KF8（AZW3 的 `mobiVersion == 8` 且没有 EXTH 121 的 MOBI6 兼容部分）不是
// "一整篇 HTML"，而是被 Amazon 拆成了 **skeleton（骨架）+ fragment（碎片）**：
//
//   * 正文（`getRawML` 解出来的 `rawML`）被 **FDST** 记录切成一串 flow，
//     flow[0] 是正文流，后面几个是 CSS / SVG；
//   * flow[0] 里的排布是 `[skeleton0][frag…][skeleton1][frag…]…`；
//   * **skeleton INDX** 给出每个骨架的 `start/length/fragCount`，
//     **fragment INDX** 给出每个碎片的 `insertPos（相对 skeleton 的插入点）`
//     `fileNum/seqNum/startPos/length`；碎片按顺序插回骨架的插入点，就还原出
//     原始 XHTML。
//
// **逐字对齐的参考语义**：Kevin Hendricks 的 **KindleUnpack v0.83**
// （`lib/mobi_k8proc.py` 的 `K8Processor.buildParts` / `lib/mobi_index.py` 的
// `getIndexData` / `lib/mobi_header.py` 的 `mobi8_header` 表）。本机已用
// KindleUnpack 对真实样本做过**全量对照**（见 `tool/mobi_kf8_probe.dart` 与
// `docs/ebook-reader-plan.md` §7.10），不是"照文档猜"。
//
// 与 MOBI6 共用：PalmDB 分记录 / PalmDOC 解压 / extra-data 剥离 / EXTH。
// KF8 只是多了一步"skeleton + fragment 重组"，解出来的 XHTML 仍走同一套
// `BookContent`。

/// 一个 INDX 条目的"文本 + 标签表"（对应 KindleUnpack `[text, tagMap]`）
class _Kf8IndexEntry {
  _Kf8IndexEntry(this.text, this.tags);
  final Uint8List text;
  final Map<int, List<int>> tags;

  /// 取第 [tag] 号标签的第 [i] 个值（缺就返回 null）
  int? value(int tag, [int i = 0]) {
    final list = tags[tag];
    if (list == null || i >= list.length) return null;
    return list[i];
  }

  int? get intText => int.tryParse(latin1.decode(text).trim());
}

/// 一个 INDX 段：条目表 + CTOC 文本表（偏移 → 名字字节）
class _Kf8IndexBlock {
  _Kf8IndexBlock(this.entries, this.ctoc);
  final List<_Kf8IndexEntry> entries;
  final Map<int, Uint8List> ctoc;
}

/// 读 FDST 记录 → flow 的**起始偏移表**（不含结尾，调用方补 `rawText.length`）。
///
/// FDST 布局（与 KindleUnpack `K8Processor.__init__` 同款）：`FDST` + u32 头长 +
/// u32 段数，随后是 `段数` 对 `(start, end)` 大端 u32；参考实现只取每对的 start，
/// 末尾补 rawSize。这里读法等价（第 i 段的 start 在第 `12 + i*8` 字节）。
///
/// 段数 <= 1 / 指向非法记录 → 明确报错，**不猜**。
///
/// [allowMissing]：FDST **整个缺失**（`0xC0 == 0xFFFFFFFF` 或缺 FDST 记录）时是
/// 否返回空表（调用方退化成"整份 rawML 一个 flow"）。只有 joint 半边传 true ——
/// 见 [_kf8Book]。
List<int> _kf8Fdst(_PalmDb db, _MobiHeader h, {bool allowMissing = false}) {
  final missing =
      h.fdstOffset == _kKf8None ||
      h.fdstCount <= 1 ||
      h.fdstOffset >= db.records.length;
  if (missing) {
    if (allowMissing) return const [];
    throw _MobiUnsupported(
      '这本 AZW3 是纯 KF8，但缺少可用的 FDST 定位表（FDST 缺失或损坏），无法安全重组正文',
    );
  }
  final rec = db.records[h.fdstOffset];
  if (_ascii(rec, 0, 4) != 'FDST') {
    throw _MobiUnsupported('这本 AZW3 的 FDST 记录损坏（magic 不是 FDST），无法重组正文');
  }
  final sections = _u32(rec, 8);
  if (sections <= 0 || 12 + sections * 8 > rec.length) {
    throw _MobiUnsupported('这本 AZW3 的 FDST 段表越界（声明 $sections 段），无法重组正文');
  }
  return [for (var i = 0; i < sections; i++) _u32(rec, 12 + i * 8)];
}

/// 解析一个 KF8 INDX 段（含其后续 entry 段与 CTOC 段）—— KindleUnpack
/// `MobiIndex.getIndexData` 的逐字段移植。
///
/// 结构：
///   * **主段**（magic `INDX`）头部给出 `len`（TAGX 起点）、`count`（后续 entry 段数）、
///     `nctoc`（CTOC 段数）；`len` 处是 `TAGX` 标签表；
///   * **entry 段**（第 `idx+1..idx+count` 条记录）头部 `start` 指向 `IDXT`，
///     其后是每个条目的 u16 偏移（末尾补 `IDXT` 自身位置）；
///   * **CTOC 段**（第 `idx+count+1..` 条记录）：变长"长度 + 名字字节"，
///     键是该名字在 CTOC 段内的字节偏移（多段时每段 +0x10000，与参考一致）。
_Kf8IndexBlock _kf8Index(_PalmDb db, int idx, String label) {
  if (idx == _kKf8None || idx < 0 || idx >= db.records.length) {
    throw _MobiUnsupported('这本 AZW3 缺少 $label 索引记录，无法重组正文');
  }
  final data = db.records[idx];
  if (_ascii(data, 0, 4) != 'INDX') {
    throw _MobiUnsupported('这本 AZW3 的 $label 索引不是 INDX 记录（可能损坏）');
  }
  // INDX 头 13 个 u32：len/nul1/type/gen/start/count/code/lng/total/ordt/ligt/nligt/nctoc
  final headerLen = _u32(data, 4);
  final entrySections = _u32(data, 24);
  final code = _u32(data, 28);
  final nctoc = _u32(data, 52);

  // ESP 方言（`code == 0xfdea` 或 ORDT 指针非零）会把条目文本经 ORDT2 重映射。
  // 只有这种书才需要，读不出来时按原字节处理（参考实现同样只在有表时重映射）。
  List<int>? ordt2;
  final ocnt = _u32(data, 0xA4);
  final oentries = _u32(data, 0xA8);
  final op2 = _u32(data, 0xB0);
  if ((code == 0xFDEA || ocnt != 0 || oentries > 0) &&
      oentries > 0 &&
      op2 + 4 + oentries * 2 <= data.length) {
    ordt2 = [for (var i = 0; i < oentries; i++) _u16(data, op2 + 4 + i * 2)];
  }

  final ctocStart = idx + entrySections + 1;
  final ctoc = <int, Uint8List>{};
  var recOff = 0;
  for (var j = 0; j < nctoc; j++) {
    if (ctocStart + j >= db.records.length) {
      throw _MobiUnsupported('这本 AZW3 的 $label CTOC 段越界，无法重组正文');
    }
    final cdata = db.records[ctocStart + j];
    var offset = 0;
    while (offset < cdata.length && cdata[offset] != 0) {
      final key = recOff + offset;
      final len = _kf8VarWidth(cdata, offset);
      offset += len.consumed;
      if (offset + len.value > cdata.length) break; // 截断：停，不吐半截
      ctoc[key] = Uint8List.sublistView(cdata, offset, offset + len.value);
      offset += len.value;
    }
    recOff += 0x10000;
  }

  // TAGX 标签表
  final tagTable = <_Kf8Tag>[];
  var controlByteCount = 0;
  if (headerLen + 4 <= data.length && _ascii(data, headerLen, 4) == 'TAGX') {
    final firstEntry = _u32(data, headerLen + 4);
    controlByteCount = _u32(data, headerLen + 8);
    for (var i = 12; i < firstEntry; i += 4) {
      final p = headerLen + i;
      if (p + 4 > data.length) break;
      tagTable.add(
        _Kf8Tag(
          tag: data[p],
          valuesPerEntry: data[p + 1],
          mask: data[p + 2],
          endFlag: data[p + 3],
        ),
      );
    }
  }
  if (tagTable.isEmpty) {
    throw _MobiUnsupported('这本 AZW3 的 $label 索引缺少 TAGX 标签表，无法重组正文');
  }

  final entries = <_Kf8IndexEntry>[];
  for (var s = idx + 1; s <= idx + entrySections; s++) {
    if (s >= db.records.length) {
      throw _MobiUnsupported('这本 AZW3 的 $label entry 段越界，无法重组正文');
    }
    final ed = db.records[s];
    final idxtPos = _u32(ed, 20);
    final count = _u32(ed, 24);
    if (idxtPos + 4 + count * 2 > ed.length) {
      throw _MobiUnsupported('这本 AZW3 的 $label IDXT 表越界，无法重组正文');
    }
    final positions = <int>[
      for (var j = 0; j < count; j++) _u16(ed, idxtPos + 4 + j * 2),
      idxtPos,
    ];
    for (var j = 0; j < count; j++) {
      final startPos = positions[j];
      final endPos = positions[j + 1];
      if (startPos >= ed.length) {
        throw _MobiUnsupported('这本 AZW3 的 $label 条目越界，无法重组正文');
      }
      final textLength = ed[startPos];
      final textEnd = (startPos + 1 + textLength).clamp(0, ed.length);
      var text = Uint8List.sublistView(ed, startPos + 1, textEnd);
      if (ordt2 != null) {
        text = Uint8List.fromList([
          for (final b in text) b < ordt2.length ? ordt2[b] & 0xFF : b,
        ]);
      }
      entries.add(
        _Kf8IndexEntry(
          text,
          _kf8TagMap(
            controlByteCount,
            tagTable,
            ed,
            startPos + 1 + textLength,
            endPos,
          ),
        ),
      );
    }
  }
  return _Kf8IndexBlock(entries, ctoc);
}

/// TAGX 标签表项（`tag / valuesPerEntry / mask / endFlag`）
class _Kf8Tag {
  _Kf8Tag({
    required this.tag,
    required this.valuesPerEntry,
    required this.mask,
    required this.endFlag,
  });
  final int tag;
  final int valuesPerEntry;
  final int mask;
  final int endFlag;
}

/// 一个 skeleton（骨架）条目
class _Kf8Skeleton {
  _Kf8Skeleton({
    required this.start,
    required this.length,
    required this.fragCount,
    required this.name,
  });
  final int start;
  final int length;
  final int fragCount;
  final String name;
}

/// 一个 fragment（碎片）条目
class _Kf8Fragment {
  _Kf8Fragment({
    required this.insertPos,
    required this.idText,
    required this.fileNum,
    required this.seqNum,
    required this.startPos,
    required this.length,
  });
  final int insertPos;
  final Uint8List idText;
  final int fileNum;
  final int seqNum;
  final int startPos;
  final int length;

  /// `idtext[12:-2]`：CTOC 名字形如 `P-//*[@aid='XXXX']`，中间那段才是 aid
  String get aidText {
    if (idText.length <= 14) return '';
    return latin1.decode(Uint8List.sublistView(idText, 12, idText.length - 2));
  }
}

List<_Kf8Skeleton> _kf8Skeletons(_Kf8IndexBlock block) => [
  for (final e in block.entries)
    _Kf8Skeleton(
      start: e.value(6, 0) ?? 0,
      length: e.value(6, 1) ?? 0,
      fragCount: e.value(1, 0) ?? 0,
      name: latin1.decode(e.text).trim(),
    ),
];

List<_Kf8Fragment> _kf8Fragments(_Kf8IndexBlock block) => [
  for (final e in block.entries)
    _Kf8Fragment(
      insertPos: e.intText ?? 0,
      idText: e.value(2) == null
          ? Uint8List(0)
          : (block.ctoc[e.value(2)!] ?? Uint8List(0)),
      fileNum: e.value(3) ?? 0,
      seqNum: e.value(4) ?? 0,
      startPos: e.value(6, 0) ?? 0,
      length: e.value(6, 1) ?? 0,
    ),
];

/// 按 KindleUnpack `K8Processor.buildParts` 的顺序把 skeleton + fragment
/// 拼回原始 XHTML：每个 skeleton 得到一段**完整 XHTML 文档**。
///
/// 关键顺序：碎片在 rawML 里紧跟在骨架**之后**连续存放，`baseptr` 从
/// `skeleton.start + skeleton.length` 起**顺序**前进；每条碎片插到骨架的
/// `insertPos - skeleton.start` 处。**插入点必须从后往前逐个累加**——每插一条，
/// 骨架变长，但参考实现记的 `insertPos` 是"原始骨架坐标"，所以插完后面那条时
/// 用的仍是相对原始骨架的偏移（本函数同样用"原始坐标"语义，与参考一致）。
List<Uint8List> _kf8Rebuild(
  Uint8List rawText,
  List<int> fdst,
  List<_Kf8Skeleton> skeletons,
  List<_Kf8Fragment> fragments,
) {
  final bounds = [...fdst, rawText.length];
  for (var i = 0; i + 1 < bounds.length; i++) {
    if (bounds[i] < 0 ||
        bounds[i] > bounds[i + 1] ||
        bounds[i + 1] > rawText.length) {
      throw _MobiUnsupported('这本 AZW3 的 FDST 偏移越界，无法重组正文');
    }
  }
  // flow[0] 是正文流；后面的 CSS/SVG 流本阅读器不内联（明确记在文档边界里）。
  // 没有 FDST（joint 的常见情形）时整份 rawML 就是 flow0。
  final flow0 = fdst.isEmpty
      ? rawText
      : Uint8List.sublistView(rawText, bounds[0], bounds[1]);

  final parts = <Uint8List>[];
  var fragPtr = 0;
  for (final sk in skeletons) {
    final skelEnd = sk.start + sk.length;
    if (sk.start < 0 || skelEnd > flow0.length) {
      throw _MobiUnsupported('这本 AZW3 的 skeleton 索引越界，无法重组正文');
    }
    var basePtr = skelEnd;
    var skeleton = Uint8List.fromList(
      Uint8List.sublistView(flow0, sk.start, skelEnd),
    );
    for (var i = 0; i < sk.fragCount; i++) {
      if (fragPtr >= fragments.length) {
        throw _MobiUnsupported('这本 AZW3 的 fragment 索引条目不足，无法重组正文');
      }
      final f = fragments[fragPtr];
      if (basePtr + f.length > flow0.length) {
        throw _MobiUnsupported('这本 AZW3 的 fragment 索引越界，无法重组正文');
      }
      final slice = Uint8List.sublistView(flow0, basePtr, basePtr + f.length);
      var insertPos = f.insertPos - sk.start;
      if (insertPos < 0 || insertPos > skeleton.length) {
        throw _MobiUnsupported('这本 AZW3 的 fragment 插入点越界，无法重组正文');
      }
      // 参考实现在插之前做一次"插入点是不是落在半个标签里"的校正：
      // 头部最后一个 `>` 落在最后一个 `<` 之前（或尾部第一个 `>` 落在第一个 `<`
      // 之前）→ 说明插入点在标签内部，改用 aid 重新定位标签末尾。
      final head = skeleton.sublist(0, insertPos);
      final tail = skeleton.sublist(insertPos);
      if (_indexOf(tail, 0x3E) < _indexOf(tail, 0x3C) ||
          _lastIndexOf(head, 0x3E) < _lastIndexOf(head, 0x3C)) {
        final fixed = _kf8AidTagEnd(skeleton, f.aidText);
        if (fixed != null) insertPos = fixed + 1 + f.startPos;
        if (insertPos < 0 || insertPos > skeleton.length) {
          throw _MobiUnsupported('这本 AZW3 的 fragment 插入点无法校正，无法重组正文');
        }
      }
      final next = Uint8List(skeleton.length + slice.length);
      next.setRange(0, insertPos, skeleton);
      next.setRange(insertPos, insertPos + slice.length, slice);
      next.setRange(insertPos + slice.length, next.length, skeleton, insertPos);
      skeleton = next;
      basePtr += f.length;
      fragPtr++;
    }
    parts.add(skeleton);
  }
  return parts;
}

/// 定位"带指定 aid 的标签"的结束 `>` 位置（对应 KindleUnpack
/// `mobi_k8proc.locate_beg_end_of_tag`）；找不到返回 null。
int? _kf8AidTagEnd(Uint8List ml, String aid) {
  if (aid.isEmpty) return null;
  final re = RegExp(
    '<[^>]*\\said\\s*=\\s*[\'"]${RegExp.escape(aid)}[\'"][^>]*>',
    caseSensitive: false,
  );
  final latin = latin1.decode(ml);
  final m = re.firstMatch(latin);
  if (m == null) return null;
  return m.end - 1;
}

/// 读一个 INDX 变长整数（最高位 1 = 结束），与 KindleUnpack
/// `mobi_index.getVariableWidthValue` 同款。截断的（没有终止位）按已读字节返回。
({int consumed, int value}) _kf8VarWidth(Uint8List data, int offset) {
  var value = 0;
  var consumed = 0;
  while (offset + consumed < data.length) {
    final v = data[offset + consumed];
    consumed++;
    value = (value << 7) | (v & 0x7F);
    if (v & 0x80 != 0) break;
  }
  return (consumed: consumed, value: value);
}

/// 解析一个 INDX 条目的标签表 —— KindleUnpack `mobi_index.getTagMap` 的移植。
///
/// 控制字节里每个标签占一段位；`mask` 位全 0 → 没这个标签；全 1（且 mask 多位）
/// → 后面跟"变长字节长度"，再按长度读一串变长值；其余 → 位值本身就是值的个数。
Map<int, List<int>> _kf8TagMap(
  int controlByteCount,
  List<_Kf8Tag> tagTable,
  Uint8List data,
  int startPos,
  int endPos,
) {
  var dataStart = startPos + controlByteCount;
  final pending = <({_Kf8Tag tag, int valueCount, int valueBytes})>[];
  var cbyteIndex = 0;
  for (final t in tagTable) {
    if (t.endFlag == 0x01) {
      cbyteIndex++;
      continue;
    }
    if (startPos + cbyteIndex >= data.length) continue;
    final cbyte = data[startPos + cbyteIndex];
    final value = cbyte & t.mask;
    if (value == 0) continue;
    if (value == t.mask) {
      if (_kf8PopCount(t.mask) > 1) {
        final r = _kf8VarWidth(data, dataStart);
        dataStart += r.consumed;
        pending.add((tag: t, valueCount: 0, valueBytes: r.value));
      } else {
        pending.add((tag: t, valueCount: 1, valueBytes: 0));
      }
    } else {
      var mask = t.mask;
      var v = value;
      while (mask & 0x01 == 0) {
        mask >>= 1;
        v >>= 1;
      }
      pending.add((tag: t, valueCount: v, valueBytes: 0));
    }
  }
  final out = <int, List<int>>{};
  for (final p in pending) {
    final values = <int>[];
    if (p.valueBytes == 0) {
      for (var k = 0; k < p.valueCount; k++) {
        for (var m = 0; m < p.tag.valuesPerEntry; m++) {
          final r = _kf8VarWidth(data, dataStart);
          dataStart += r.consumed;
          values.add(r.value);
        }
      }
    } else {
      var total = 0;
      while (total < p.valueBytes) {
        final r = _kf8VarWidth(data, dataStart);
        if (r.consumed == 0) break; // 数据提前用完：停，不空转
        dataStart += r.consumed;
        total += r.consumed;
        values.add(r.value);
      }
    }
    out[p.tag.tag] = values;
  }
  return out;
}

int _kf8PopCount(int v) {
  var count = 0;
  var x = v;
  while (x != 0) {
    count += x & 1;
    x >>= 1;
  }
  return count;
}

int _indexOf(Uint8List b, int byte, [int from = 0]) {
  for (var i = from; i < b.length; i++) {
    if (b[i] == byte) return i;
  }
  return -1;
}

int _lastIndexOf(Uint8List b, int byte) {
  for (var i = b.length - 1; i >= 0; i--) {
    if (b[i] == byte) return i;
  }
  return -1;
}

// ------------------------------------------------------------------ PalmDOC / PRC

/// `.pdb` / 非 MOBI 的 `.prc`：**PalmDB + PalmDOC 头**的直读路径。
///
/// `.prc` 现实中大多是 Mobipocket 书（record 0 里带 `MOBI` 头）—— 那就直接交给
/// [parseMobiBook]；只有**没有 MOBI 头**的老 PalmDOC 才走这里。
///
/// 复用的正是 MOBI 那两个私有层：`_parsePalmDb`（容器的记录表）与
/// `_palmDocDecompress`（LZ77 变体）。压缩类型 1/2 支持，HUFF/CDIC 与 DRM
/// 明确报错，**绝不把码流当正文**。
BookParseResult parsePalmDocBook(
  List<int> bytes, {
  required BookFormat format,
}) {
  try {
    final db = _parsePalmDb(Uint8List.fromList(bytes));
    final rec0 = db.records.first;
    // 有 MOBI 头 → Mobipocket（.prc 的常态），交给 MOBI 解析器
    if (rec0.length >= 20 && _ascii(rec0, 16, 4) == 'MOBI') {
      return parseMobiBook(bytes, format: format);
    }
    if (rec0.length < 16) throw const FormatException('PalmDOC 头不完整');

    final compression = _u16(rec0, 0);
    final textLength = _u32(rec0, 4);
    final textRecordCount = _u16(rec0, 8);
    final encryption = _u16(rec0, 12);

    if (encryption != 0) {
      throw _MobiUnsupported('这本 PalmDOC 带 DRM 加密，本阅读器不解密');
    }
    if (compression == _kCompressionHuffCdic) {
      throw _MobiUnsupported(
        '这本 PalmDOC 声明 HUFF/CDIC 压缩，但没有 MOBI 头，无法定位 Huffman 字典记录',
      );
    }
    if (compression != _kCompressionNone &&
        compression != _kCompressionPalmDoc) {
      throw _MobiUnsupported('PalmDOC 压缩类型 $compression 本阅读器不支持');
    }

    final out = BytesBuilder(copy: false);
    final end = textRecordCount.clamp(0, db.records.length - 1);
    for (var i = 1; i <= end; i++) {
      final raw = db.records[i];
      switch (compression) {
        case _kCompressionNone:
          out.add(raw);
        case _kCompressionPalmDoc:
          out.add(_palmDocDecompress(raw));
      }
    }
    var text = out.takeBytes();
    // PalmDOC 头的 textLength 是权威长度，多出来的尾巴截掉
    if (textLength > 0 && text.length > textLength) {
      text = Uint8List.sublistView(text, 0, textLength);
    }
    if (text.isEmpty) throw const FormatException('PalmDOC 正文为空');

    final decoded = detectAndDecodeBookText(text);
    final title = _palmDbName(bytes);

    // 换页符（\x0c）是 PalmDOC 事实上的分页标记 → 有就分章
    final pages = decoded.text
        .split('\x0c')
        .where((p) => p.trim().isNotEmpty)
        .toList();
    if (pages.length >= 2) {
      final chapters = <BookChapter>[];
      final toc = <BookTocEntry>[];
      for (final page in pages) {
        final sub = bookFromPlainText(page, format: format, title: '');
        final ch = sub.chapters.isNotEmpty
            ? sub.chapters.first
            : BookChapter(
                title: '第 ${chapters.length + 1} 章',
                html: '',
                generatedUnit: BookGeneratedUnit.chapter,
              );
        final index = chapters.length;
        chapters.add(
          BookChapter(
            title: ch.title,
            generatedUnit: ch.generatedUnit,
            html: ch.html,
          ),
        );
        toc.add(BookTocEntry(title: ch.title, chapterIndex: index));
      }
      return BookParseResult(
        BookContent(format: format, title: title, chapters: chapters, toc: toc),
      );
    }

    final sub = bookFromPlainText(decoded.text, format: format, title: title);
    return BookParseResult(
      BookContent(
        format: format,
        title: title.isNotEmpty ? title : sub.title,
        author: '（${decoded.encoding.label}）',
        chapters: sub.chapters,
        toc: sub.toc,
      ),
    );
  } on _MobiUnsupported catch (e) {
    return BookParseResult(
      BookContent(format: format),
      error: e.message,
      errorKind: BookParseErrorKind.unsupportedCompression,
      reason: BookUnsupportedReason.compression,
    );
  } catch (_) {
    return BookParseResult(
      BookContent(format: format),
      error: '这本书解析失败（文件可能损坏或带 DRM）',
      errorKind: BookParseErrorKind.parseFailed,
    );
  }
}

/// PalmDB 数据库名（头 32 字节，NUL 结尾）—— PalmDOC 没有别的书名来源
String _palmDbName(List<int> bytes) {
  if (bytes.length < 32) return '';
  var end = 0;
  while (end < 32 && bytes[end] != 0) {
    end++;
  }
  if (end == 0) return '';
  final raw = Uint8List.fromList(bytes.sublist(0, end));
  try {
    return utf8.decode(raw).trim();
  } catch (_) {
    return latin1.decode(raw).trim();
  }
}

/// 给探针用：PalmDOC（非 MOBI）头部摘要
Map<String, Object?> palmDocProbe(List<int> bytes) {
  try {
    final data = Uint8List.fromList(bytes);
    final db = _parsePalmDb(data);
    final rec0 = db.records.first;
    final hasMobi = rec0.length >= 20 && _ascii(rec0, 16, 4) == 'MOBI';
    return {
      'records': db.records.length,
      'hasMobiHeader': hasMobi,
      'compression': _u16(rec0, 0),
      'textLength': _u32(rec0, 4),
      'textRecords': _u16(rec0, 8),
      'encryption': _u16(rec0, 12),
      'title': _palmDbName(data),
    };
  } catch (e) {
    return {'error': '$e'};
  }
}

// ------------------------------------------------------------------ 字节工具

int _u16(Uint8List b, int offset) {
  if (offset < 0 || offset + 2 > b.length) return 0;
  return (b[offset] << 8) | b[offset + 1];
}

int _u32(Uint8List b, int offset) {
  if (offset < 0 || offset + 4 > b.length) return 0;
  return (b[offset] << 24) |
      (b[offset + 1] << 16) |
      (b[offset + 2] << 8) |
      b[offset + 3];
}

String _ascii(Uint8List b, int offset, int length) {
  if (offset < 0 || offset + length > b.length) return '';
  return String.fromCharCodes(b.sublist(offset, offset + length));
}

/// 给探针/测试用：直接跑一遍 PalmDOC（压缩类型 2）解压。
///
/// 单测用**手写 opcode** 打它，能精确覆盖五种操作码（字面量串 / 单字节字面量 /
/// 距离-长度对 / 空格优化 / 0x00），而不是拿"自己压自己解"糊过去。
Uint8List mobiPalmDocDecode(List<int> bytes) =>
    _palmDocDecompress(Uint8List.fromList(bytes));

/// 给探针/测试用：直接跑一遍 HUFF/CDIC 解码。
///
/// [huff] 是一条 HUFF 记录（magic `HUFF`），[cdics] 是按顺序加载的 CDIC 记录。
/// 单测用**自造字典**打它：短语映射、压缩短语的递归展开、越界/坏字典的"停下不吐
/// 乱码"都能精确覆盖，而不必依赖真实 HUFF/CDIC 书。
Uint8List mobiHuffCdicDecode(
  List<int> huff,
  List<List<int>> cdics,
  List<int> data,
) {
  final hc = _HuffCdic()..loadHuff(Uint8List.fromList(huff));
  for (final c in cdics) {
    hc.loadCdic(Uint8List.fromList(c));
  }
  return hc.unpack(Uint8List.fromList(data));
}

/// 给探针/测试用：HUFF/CDIC 字典的可加载性摘要
Map<String, Object?> mobiHuffProbe(List<int> bytes) {
  try {
    final data = Uint8List.fromList(bytes);
    final db = _parsePalmDb(data);
    final h = _parseHeader(db);
    if (h.compression != _kCompressionHuffCdic) {
      return {'ok': false, 'compression': h.compression, 'huff': false};
    }
    final hc = _loadHuffCdic(db, h);
    return {
      'ok': true,
      'compression': h.compression,
      'huff': true,
      'phrases': hc.phraseCount,
      'huffOffset': h.huffRecordOffset,
      'huffCount': h.huffRecordCount,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}

/// 给探针/测试用：只回报**解压后的正文字节数**（在 `_extractText` 之后、
/// 任何抽取/规整之前）。
///
/// HUFF/CDIC 这类压缩路径的真实性就靠它：文档写"解出 111,701 字节 ==
/// `text_length`"，`mobiHuffProbe` 的 `phrases` 证明不了这一点，这个探针能。
/// 字典坏了 / 记录缺失 → 直接抛，返回 `ok:false`（不假装成功）。
Map<String, Object?> mobiTextProbe(List<int> bytes) {
  try {
    final db = _parsePalmDb(Uint8List.fromList(bytes));
    final h = _parseHeader(db);
    final raw = _extractText(db, h);
    return {
      'ok': true,
      'compression': h.compression,
      'declaredTextLength': h.textLength,
      'decodedBytes': raw.length,
      'matchesDeclared': h.textLength == 0 || raw.length == h.textLength,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}

/// 给探针/调试用：不解正文，只回报头部关键字段（`tool/*.dart` 可以直接调）。
Map<String, Object?> mobiHeaderProbe(List<int> bytes) {
  try {
    final data = Uint8List.fromList(bytes);
    final db = _parsePalmDb(data);
    final h = _parseHeader(db);
    return {
      'records': db.records.length,
      'compression': h.compression,
      'textLength': h.textLength,
      'textRecords': h.textRecordCount,
      'encryption': h.encryptionType,
      'version': h.mobiVersion,
      'encoding': h.textEncoding,
      'firstImage': h.firstImageIndex,
      'imageCount': _collectImages(db, h).resources.length,
      'kf8Boundary': h.kf8Boundary,
      'language': h.languageCode,
      'fdstOffset': h.fdstOffset,
      'fdstCount': h.fdstCount,
      'fcisOffset': h.fcisOffset,
      'fcisCount': h.fcisCount,
      'flisOffset': h.flisOffset,
      'flisCount': h.flisCount,
      'ncxIndex': h.ncxIndex,
      'fragIndex': h.fragIndex,
      'skelIndex': h.skelIndex,
      'guideIndex': h.guideIndex,
      'title': _mobiTitle(h, db),
    };
  } catch (e) {
    return {'error': '$e'};
  }
}

/// 给探针/测试用：跑一遍**KF8 重组**并回报每段 XHTML 的字节数 / 首尾摘要。
///
/// 这是"解析层内部真值"的探针：`tool/mobi_kf8_probe.dart` 用它把结果逐段
/// 写到磁盘，与 KindleUnpack `K8Processor.buildParts` 的 parts 做**逐字节**对照。
/// 失败（缺 FDST / 索引坏）→ `ok: false` + 原因，**不产出半截正文**。
///
/// **joint 也适用**：自动定位 KF8 半边（EXTH 121 / `BOUNDARY`），并像
/// KindleUnpack 那样容忍 joint 半边缺 FDST。[joint] 字段会说明走的是哪半边。
Map<String, Object?> mobiKf8Probe(List<int> bytes) {
  try {
    final data = Uint8List.fromList(bytes);
    final full = _parsePalmDb(data);
    final base = _parseHeader(full);
    if (base.encryptionType != 0) {
      return {'ok': false, 'error': '带 DRM'};
    }
    final half = _kf8Half(full);
    final db = half.db;
    final h = half.header;
    final rawText = _extractText(db, h);
    final book = _kf8Book(db, h, rawText, allowMissingFdst: half.joint);
    return {
      'ok': true,
      'joint': half.joint,
      'kf8Start': full.records.length - db.records.length,
      'rawText': rawText.length,
      'flows': book.flows.length,
      'skeletons': book.skeletons.length,
      'fragments': book.fragments.length,
      'parts': book.parts.length,
      'partLengths': [for (final p in book.parts) p.length],
      'assembledBytes': book.parts.fold<int>(0, (s, p) => s + p.length),
      'assembledChars': book.parts.fold<int>(
        0,
        (s, p) => s + _decode(p, h.textEncoding).length,
      ),
      'title': _mobiTitle(h, db),
      'author': _exthString(h.exth, 100, h.textEncoding),
      'language': h.languageCode,
      'fdst': _kf8Fdst(db, h, allowMissing: half.joint),
      'toc': _kf8Toc(db, h, book).length,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}

/// 给探针/测试用：KF8 重组出的**原始 XHTML 段**（没做 `_mobiFragment` 规整）。
///
/// 逐段与 KindleUnpack `K8Processor.buildParts` 的 parts 做**逐字节**对照用；
/// joint 文件会自动定位 KF8 半边（与 [mobiKf8Probe] 同一套判据）。
/// 坏 KF8（缺 FDST / 索引坏）会抛异常，调用方可据此断言"明确报错、不吐半截"。
List<Uint8List> mobiKf8Parts(List<int> bytes) {
  final full = _parsePalmDb(Uint8List.fromList(bytes));
  final half = _kf8Half(full);
  final rawText = _extractText(half.db, half.header);
  return _kf8Book(
    half.db,
    half.header,
    rawText,
    allowMissingFdst: half.joint,
  ).parts;
}

/// 给探针/测试用：KF8 的目录（NCX `0xF4` → guide `0x104` 兜底）逐条明细。
///
/// 回报 `(title, chapterIndex, depth, source)`，source 是 `ncx` / `guide` /
/// `none`。目录解析失败只回报空表（不影响正文）。
Map<String, Object?> mobiTocProbe(List<int> bytes) {
  try {
    final full = _parsePalmDb(Uint8List.fromList(bytes));
    final half = _kf8Half(full);
    final rawText = _extractText(half.db, half.header);
    final book = _kf8Book(
      half.db,
      half.header,
      rawText,
      allowMissingFdst: half.joint,
    );
    final ncx = _kf8Ncx(half.db, half.header, book);
    final guide = _kf8Guide(half.db, half.header, book);
    final used = ncx.isNotEmpty ? ncx : guide;
    return {
      'ok': true,
      'source': ncx.isNotEmpty ? 'ncx' : (guide.isNotEmpty ? 'guide' : 'none'),
      'count': used.length,
      'ncxCount': ncx.length,
      'guideCount': guide.length,
      'entries': [
        for (final e in used)
          {'title': e.title, 'chapterIndex': e.chapterIndex, 'depth': e.depth},
      ],
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}

/// 给探针/测试用：KF8 内部链接（`kindle:pos:fid`）逐条解析明细。
///
/// 每条回报 `from`（链接所在段的合成 href）/ `fid` / `off` / `part`
/// （目标段号，定位不了是 -1）/ `anchor`（目标锚点 id，段首为空）/ `supported`。
/// 与 KindleUnpack `XHTMLK8Processor.buildXHTML` + `getIDTagByPosFid` 的
/// `(filename, idtag)` 对照用。
Map<String, Object?> mobiKf8LinkProbe(List<int> bytes) {
  try {
    final full = _parsePalmDb(Uint8List.fromList(bytes));
    final half = _kf8Half(full);
    final rawText = _extractText(half.db, half.header);
    final book = _kf8Book(
      half.db,
      half.header,
      rawText,
      allowMissingFdst: half.joint,
    );
    final map = _Kf8LinkMap(book);
    final re = RegExp(
      r'''["']kindle:pos:fid:([0-9A-V]+):off:([0-9A-V]+)''',
      caseSensitive: false,
    );
    final links = <Map<String, Object?>>[];
    for (var i = 0; i < book.parts.length; i++) {
      final latin = latin1.decode(book.parts[i]);
      for (final m in re.allMatches(latin)) {
        final target = map.resolve(m.group(1)!, m.group(2)!);
        links.add({
          'from': _Kf8LinkMap.partHref(i),
          'fid': m.group(1)!.toUpperCase(),
          'off': m.group(2)!.toUpperCase(),
          'part': target?.part ?? -1,
          'anchor': target?.anchor ?? '',
          'supported': target != null,
        });
      }
    }
    return {
      'ok': true,
      'count': links.length,
      'supported': links.where((e) => e['supported'] == true).length,
      'unsupported': links.where((e) => e['supported'] != true).length,
      'links': links,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}

/// 给探针/测试用：对**指定** `fid`/`off` 解析一次（可以是书里没有的链接）。
///
/// 专门用来验证"越界 / 非法形态 → 不崩、降级"的分支：真实样本里每条
/// `kindle:pos:fid` 都能定位，没法用它们覆盖降级路径。返回
/// `supported`（能否定位）/ `part`（段号，失败 -1）/ `anchor`（锚点，段首为空）。
Map<String, Object?> mobiKf8ResolveLink(
  List<int> bytes,
  String fid,
  String off,
) {
  try {
    final full = _parsePalmDb(Uint8List.fromList(bytes));
    final half = _kf8Half(full);
    final rawText = _extractText(half.db, half.header);
    final book = _kf8Book(
      half.db,
      half.header,
      rawText,
      allowMissingFdst: half.joint,
    );
    final target = _Kf8LinkMap(book).resolve(fid, off);
    return {
      'ok': true,
      'supported': target != null,
      'part': target?.part ?? -1,
      'anchor': target?.anchor ?? '',
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}

/// 给探针用：只回报"能不能读 + 为什么不能"（不落 `BookContent`）
Map<String, Object?> mobiSupportProbe(List<int> bytes) {
  final r = parseMobiBook(bytes, format: BookFormat.mobi);
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
