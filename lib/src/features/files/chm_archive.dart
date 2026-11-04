// CHM（Microsoft Compiled HTML Help，ITSF 容器 + LZX 压缩）读取器 —— **纯 Dart**，
// 不 import flutter / l10n（`dart run tool/*.dart` 必须能编译）。
//
// 为什么要自己写（结论见 `docs/ebook-formats-research.md` §2.5 / §3.3）：
// pub 上没有任何纯 Dart 的 CHM/LZX 实现；现实里的办法只有 chmlib（LGPL）或
// libmspack（LGPL）+ NDK 交叉编译 —— 属于"引原生库"。用户的硬要求是
// "所有电子书格式都要支持，遇到协议/许可证问题就自研"，所以这里从零实现
// **ITSF 容器 + ITSP/PMGL 目录树 + LZX 解压**，零三方依赖、零许可风险。
//
// **参考与许可**：比特流格式的事实来自公开规范与独立实现：
//   * 容器/目录：`chmspec`（Unofficial HTML Help Specification，pabs/jedwin，
//     FDL/GPL 文档）与 Matthew Russotto 的 `chmformat` 说明所描述的
//     ITSF/ITSP/PMGL/PMGI 结构；
//   * LZX：Microsoft 的 LZX 算法（CAB/CHM 同源）与公开的独立实现
//     `chmlib`/`cabextract` 的 lzx.c（GPL-2.0 + 作者豁免，**仅作算法事实参考**）。
//   本文件是**独立重写的 Dart 实现**：没有引入上述工程的任何代码、头文件或依赖，
//   只在算法常量（位置槽位基表、长度表尺寸、块头位宽等纯事实）上一致。
//
// **能力边界**（宁可给明确错误，也不吐乱码或半截文件）：
//
//   | 维度 | 支持 | 明确报错 |
//   |---|---|---|
//   | 容器 | ITSF v2（0x58）/ v3（0x60）+ ITSP v1 | 其它版本、签名不符、越界 → 坏文件 |
//   | 目录 | PMGL/PMGI 分页 + big-endian ENCINT 路径表 | 成环/越界 → 坏文件 |
//   | 内容空间 | Uncompressed（space 0）与 MSCompressed（space 1） | —— |
//   | LZX | 块类型 verbatim(1) / aligned(2) / uncompressed(3) + E8 地址变换 | 其它块类型 → [ChmUnsupportedException] |
//   | LZXC | version 2（reset interval / window size 按 0x8000 缩放） | 其它版本 → 不支持 |
//   | LZX 窗口 | 2^15 .. 2^21 | 其它 → 不支持 |
//   | 加密/DRM | —— | CHM 本身没有标准加密，带密码的自解压壳不是 ITSF → 坏文件 |
//
// 所有"能力边界"抛 [ChmUnsupportedException]，文件损坏/截断抛 [ChmFormatException]，
// 由 `book_chm.dart` / `file_book.dart` 翻译成界面的"这本书打不开"。
import 'dart:convert';
import 'dart:typed_data';

/// 能力边界：格式认识、但这个变体我们做不到（LZX 块类型/窗口/LZXC 版本…）。
///
/// 与 [ChmFormatException] 分开：前者"换别的工具还有救"，后者"文件本身坏了"。
class ChmUnsupportedException implements Exception {
  ChmUnsupportedException(this.message);
  final String message;
  @override
  String toString() => 'CHM 不支持：$message';
}

/// 文件损坏 / 截断 / 结构自相矛盾 / 目录越界。
class ChmFormatException implements Exception {
  ChmFormatException(this.message);
  final String message;
  @override
  String toString() => 'CHM 解析失败：$message';
}

/// 目录里的一个条目（文件或目录）。
///
/// [space] = 0（Uncompressed，直接落在文件的 data_offset 之后）或
/// 1（MSCompressed，落在 LZX 解压出来的内容流里，[start] 是**解压后**的偏移）。
class ChmEntry {
  const ChmEntry({
    required this.path,
    required this.space,
    required this.start,
    required this.length,
  });

  /// 归档内路径（保持 PMGL 里的原始写法：普通文件带前导 `/`，内部文件 `/#SYSTEM`，
  /// 数据空间 `::DataSpace/...`）。
  final String path;
  final int space;
  final int start;
  final int length;

  bool get isDir => path.endsWith('/');

  /// 归一化后的相对路径（去掉前导 `/`、统一 `/`）——给界面/资源表用
  String get normalized {
    var p = path.replaceAll('\\', '/');
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    return p;
  }

  @override
  String toString() => 'ChmEntry($path, space=$space, $start+$length)';
}

// ---------------------------------------------------------------- 公开入口

/// 打开一个 CHM。坏文件/能力边界分别抛 [ChmFormatException] /
/// [ChmUnsupportedException]（**不抛**业务无关的异常）。
class ChmArchive {
  ChmArchive._({
    required this.bytes,
    required this.version,
    required this.langId,
    required this.dirOffset,
    required this.dirLen,
    required this.dataOffset,
    required this.blockLen,
    required this.indexRoot,
    required this.indexHead,
    required this.entries,
  }) : _byLower = {
         for (final e in entries) e.path.replaceAll('\\', '/').toLowerCase(): e,
       };

  final Uint8List bytes;

  /// ITSF 版本（2 或 3）
  final int version;

  final int langId;
  final int dirOffset;
  final int dirLen;
  final int dataOffset;

  /// 目录页（PMGL/PMGI）大小
  final int blockLen;
  final int indexRoot;
  final int indexHead;

  /// 目录里的全部条目（PMGL 链顺序）
  final List<ChmEntry> entries;

  final Map<String, ChmEntry> _byLower;

  static bool isChm(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x49 && // I
      bytes[1] == 0x54 && // T
      bytes[2] == 0x53 && // S
      bytes[3] == 0x46; // F

  static ChmArchive open(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (data.length < 0x60) {
      throw ChmFormatException('文件太小，不像 CHM（ITSF 头都不够）');
    }
    if (!isChm(data)) {
      throw ChmFormatException('不是 CHM 文件（找不到 ITSF 签名）');
    }

    // ---- ITSF 头（v2 = 0x58 字节，v3 = 0x60 字节）
    final version = _u32(data, 0x04);
    if (version != 2 && version != 3) {
      throw ChmFormatException('ITSF 版本 $version 不认识（只见过 2 / 3）');
    }
    final headerLen = _u32(data, 0x08);
    final minHeader = version == 2 ? 0x58 : 0x60;
    if (headerLen < minHeader) {
      throw ChmFormatException('ITSF 头长度 $headerLen 小于最低要求 $minHeader');
    }
    if (headerLen > data.length) {
      throw ChmFormatException('ITSF 头长度越界');
    }
    final langId = _u32(data, 0x14);
    final dirOffset = _u64(data, 0x48);
    final dirLen = _u64(data, 0x50);
    // v2 没有独立的 data_offset 字段，约定为"目录之后"
    final dataOffset = version >= 3 ? _u64(data, 0x58) : dirOffset + dirLen;
    if (dirOffset < 0 || dirLen <= 0 || dirOffset + dirLen > data.length) {
      throw ChmFormatException('ITSF 目录区间越界');
    }
    if (dataOffset < 0 || dataOffset > data.length) {
      throw ChmFormatException('ITSF 内容区偏移越界');
    }

    // ---- ITSP 头（0x54 字节），位于 dir_offset
    if (dirOffset + 0x54 > data.length) {
      throw ChmFormatException('ITSP 头越界');
    }
    if (_ascii(data, dirOffset, 4) != 'ITSP') {
      throw ChmFormatException('目录处没有 ITSP 签名');
    }
    final itspVersion = _u32(data, dirOffset + 0x04);
    if (itspVersion != 1) {
      throw ChmFormatException('ITSP 版本 $itspVersion 不认识（只见过 1）');
    }
    final itspHeaderLen = _u32(data, dirOffset + 0x08);
    if (itspHeaderLen < 0x54) {
      throw ChmFormatException('ITSP 头长度 $itspHeaderLen 小于 0x54');
    }
    final blockLen = _u32(data, dirOffset + 0x10);
    if (blockLen < 0x80 || blockLen > 0x100000) {
      throw ChmFormatException('ITSP 目录页大小 $blockLen 不合理');
    }
    final indexRoot = _i32(data, dirOffset + 0x1C);
    final indexHead = _i32(data, dirOffset + 0x20);

    final entries = _enumerate(
      data: data,
      blockBase: dirOffset + itspHeaderLen,
      blockLen: blockLen,
      indexHead: indexHead,
    );
    if (entries.isEmpty) {
      throw ChmFormatException('CHM 目录是空的');
    }

    return ChmArchive._(
      bytes: data,
      version: version,
      langId: langId,
      dirOffset: dirOffset,
      dirLen: dirLen,
      dataOffset: dataOffset,
      blockLen: blockLen,
      indexRoot: indexRoot,
      indexHead: indexHead,
      entries: entries,
    );
  }

  /// 按路径找条目（大小写不敏感、容忍前导 `/` 与 `\`）。
  ChmEntry? find(String path) {
    var key = path.replaceAll('\\', '/').toLowerCase();
    while (key.startsWith('/')) {
      key = key.substring(1);
    }
    final hit = _byLower[key];
    if (hit != null) return hit;
    // PMGL 里普通文件是 `/x`、数据空间是 `::x`：两种前缀都试一下
    return _byLower['/$key'] ?? _byLower['::$key'];
  }

  // ------------------------------------------------------------ 读取

  /// 读一个条目的**原始字节**。
  ///
  /// * space 0（Uncompressed）：直接切片（返回的是视图，不复制）；
  /// * space 1（MSCompressed）：走 LZX 解压（含按需分块 + 缓存）。
  ///
  /// 越界/截断 → [ChmFormatException]；LZX 做不到的变体 → [ChmUnsupportedException]。
  Uint8List read(ChmEntry entry) {
    if (entry.length <= 0) return Uint8List(0);
    if (entry.space == 0) {
      final from = dataOffset + entry.start;
      final to = from + entry.length;
      if (entry.start < 0 || from < dataOffset || to > bytes.length) {
        throw ChmFormatException('条目 ${entry.path} 的数据区间越界');
      }
      return Uint8List.sublistView(bytes, from, to);
    }
    if (entry.space != 1) {
      throw ChmUnsupportedException(
        '条目 ${entry.path} 用了未知的存储空间 ${entry.space}',
      );
    }
    return readCompressed(entry.start, entry.length);
  }

  /// 读 MSCompressed 内容流的 `[start, start+length)`（解压后坐标）。
  Uint8List readCompressed(int start, int length) {
    _ensureLzx();
    final blockLen = _resetBlockLen!;
    final firstBlock = start ~/ blockLen;
    final lastBlock = (start + length - 1) ~/ blockLen;
    final out = Uint8List(length);
    var written = 0;
    for (var b = firstBlock; b <= lastBlock; b++) {
      final block = _decodeBlock(b);
      final blockStart = b * blockLen;
      final from = start + written - blockStart;
      final n = (blockLen - from).clamp(0, length - written);
      if (from < 0 || from + n > block.length) {
        throw ChmFormatException('LZX 块 $b 解出的数据不足');
      }
      out.setRange(written, written + n, block, from);
      written += n;
    }
    return out;
  }

  // ------------------------------------------------------------ LZX

  int? _windowBits;
  int? _resetBlockLen;
  int _resetBlockCount = 0;
  int _resetBlkCount = 1;
  int _resetTableOffset = 0;
  int _compressedLen = 0;
  int _contentStart = 0;
  ChmEntry? _resetEntry;
  final Map<int, Uint8List> _blockCache = {};
  static const int _kBlockCacheMax = 32;

  void _ensureLzx() {
    if (_resetBlockLen != null) return;

    // ---- LZXC 控制数据
    final control = find(_kControlUnit);
    if (control == null) {
      throw ChmUnsupportedException('CHM 的压缩内容缺少 LZXC 控制数据，本阅读器无法解压');
    }
    final cd = _rawUncompressed(control);
    if (cd.length < 0x18) throw ChmFormatException('LZXC 控制数据不完整');
    if (_ascii(cd, 0x04, 4) != 'LZXC') {
      throw ChmFormatException('LZXC 签名不符');
    }
    final lzxcVersion = _u32(cd, 0x08);
    if (lzxcVersion != 2) {
      throw ChmUnsupportedException('LZXC 版本 $lzxcVersion 未实现（只实现了 2）');
    }
    // version 2：两个字段都要乘 0x8000
    final resetInterval = _u32(cd, 0x0C) * 0x8000;
    final windowSize = _u32(cd, 0x10) * 0x8000;
    if (windowSize <= 0 || resetInterval <= 0) {
      throw ChmFormatException('LZXC 的窗口/重置间隔为 0');
    }
    final bits = _log2Exact(windowSize);
    if (bits == null || bits < 15 || bits > 21) {
      throw ChmUnsupportedException(
        'LZX 窗口 $windowSize 字节（$bits 位）未实现（支持 2^15..2^21）',
      );
    }
    _windowBits = bits;

    // ---- ResetTable
    final rt = find(_kResetUnit);
    if (rt == null) {
      throw ChmUnsupportedException('CHM 的压缩内容缺少 ResetTable，无法定位压缩块');
    }
    final rb = _rawUncompressed(rt);
    if (rb.length < 0x28) throw ChmFormatException('ResetTable 头不完整');
    if (_u32(rb, 0x00) != 2) {
      throw ChmFormatException('ResetTable 版本 ${_u32(rb, 0x00)} 不认识（只见过 2）');
    }
    _resetBlockCount = _u32(rb, 0x04);
    _resetTableOffset = _u32(rb, 0x0C);
    _compressedLen = _u64(rb, 0x18);
    final blockLen = _u64(rb, 0x20);
    if (_resetBlockCount <= 0) throw ChmFormatException('ResetTable 块数为 0');
    if (blockLen < 0x1000 || blockLen > 0x100000) {
      throw ChmFormatException('ResetTable 块大小 $blockLen 不合理');
    }
    _resetBlockLen = blockLen;
    if (_compressedLen <= 0) throw ChmFormatException('ResetTable 压缩长度为 0');
    _resetEntry = rt;

    // ---- Content
    final content = find(_kContentUnit);
    if (content == null) {
      throw ChmUnsupportedException('CHM 的压缩内容缺少 Content 数据');
    }
    _contentStart = dataOffset + content.start;

    // 重置间隔 → 每多少个内容块重置一次 LZX 状态
    var blkCount = resetInterval ~/ blockLen;
    if (blkCount < 1) blkCount = 1;
    _resetBlkCount = blkCount;
  }

  /// 解出一个内容块（带缓存；缓存未命中时从本重置区间开头顺推到该块）。
  Uint8List _decodeBlock(int index) {
    final cached = _blockCache[index];
    if (cached != null) return cached;
    final blockLen = _resetBlockLen!;
    if (index < 0 || index >= _resetBlockCount) {
      throw ChmFormatException('LZX 块下标 $index 越界（共 $_resetBlockCount 块）');
    }
    final resetStart = (index ~/ _resetBlkCount) * _resetBlkCount;
    final decoder = ChmLzxDecoder(windowBits: _windowBits!);
    Uint8List? result;
    // ⚠️ 必须**从本重置区间开头逐块解压**：LZX 的窗口/R0R1R2 是跨块的状态，
    // 缓存里的一块数据无法重建这个状态（踩过：跳过中间块会让后续块全错）。
    for (var b = resetStart; b <= index; b++) {
      final bounds = _cmpBlockBounds(b);
      final input = Uint8List.sublistView(
        bytes,
        bounds.start,
        bounds.start + bounds.length,
      );
      result = decoder.decodeChunk(input, blockLen);
      _cacheBlock(b, result);
    }
    if (result == null) throw ChmFormatException('LZX 块 $index 解压失败');
    return result;
  }

  void _cacheBlock(int index, Uint8List data) {
    if (_blockCache.length >= _kBlockCacheMax) {
      // 简单的 FIFO 淘汰：内容流是顺序读的，旧块基本不会再用
      final first = _blockCache.keys.first;
      _blockCache.remove(first);
    }
    _blockCache[index] = data;
  }

  ({int start, int length}) _cmpBlockBounds(int block) {
    final base = dataOffset + _resetEntry!.start + _resetTableOffset;
    final at = base + block * 8;
    if (at + 8 > bytes.length) {
      throw ChmFormatException('ResetTable 条目越界');
    }
    final start = _u64(bytes, at);
    final int end;
    if (block < _resetBlockCount - 1) {
      if (at + 16 > bytes.length) throw ChmFormatException('ResetTable 条目越界');
      end = _u64(bytes, at + 8);
    } else {
      end = _compressedLen;
    }
    final length = end - start;
    if (start < 0 || length <= 0 || start + length > _compressedLen) {
      throw ChmFormatException('ResetTable 里的块 $block 区间非法');
    }
    // 内容流必须真的在文件里
    if (_contentStart + start + length > bytes.length) {
      throw ChmFormatException('LZX 压缩块 $block 超出文件末尾');
    }
    return (start: _contentStart + start, length: length);
  }

  /// 只读 space 0 的原始字节（LZX 控制数据/ResetTable 一定是未压缩的）
  Uint8List _rawUncompressed(ChmEntry entry) {
    if (entry.space != 0) {
      throw ChmFormatException('条目 ${entry.path} 不在未压缩空间，无法当控制数据读');
    }
    final from = dataOffset + entry.start;
    final to = from + entry.length;
    if (from < dataOffset || to > bytes.length) {
      throw ChmFormatException('条目 ${entry.path} 的数据区间越界');
    }
    return Uint8List.sublistView(bytes, from, to);
  }
}

// ---------------------------------------------------------------- 目录树

const String _kContentUnit = '::dataspace/storage/mscompressed/content';
const String _kControlUnit = '::dataspace/storage/mscompressed/controldata';
const String _kResetUnit =
    '::dataspace/storage/mscompressed/transform/'
    '{7fc28940-9d31-11d0-9b27-00a0c91e9c7c}/instancedata/resettable';

/// 顺着 PMGL 链枚举目录条目。
///
/// 真实文件里目录是一棵 B 树（PMGI 索引页 → PMGL 叶子页）；读取侧只需要
/// "从 index_head 顺着 block_next 走完所有叶子页"就能拿到全部条目，
/// 不必实现 PMGI 的二分查找（那是 O(log n) 的优化，不是正确性要求）。
List<ChmEntry> _enumerate({
  required Uint8List data,
  required int blockBase,
  required int blockLen,
  required int indexHead,
}) {
  final out = <ChmEntry>[];
  final visited = <int>{};
  var page = indexHead;
  while (page >= 0) {
    if (!visited.add(page)) throw ChmFormatException('目录块链成环（块 $page）');
    if (visited.length > 1 << 20) throw ChmFormatException('目录块太多，疑似损坏');
    // ⚠️ PMGL 块从 **ITSP 头之后** 开始（chmlib：dir_offset += ITSP header_len）
    final at = blockBase + page * blockLen;
    if (at < blockBase || at + blockLen > data.length) {
      throw ChmFormatException('目录块 $page 越界');
    }
    final block = Uint8List.sublistView(data, at, at + blockLen);
    final sig = _ascii(block, 0, 4);
    if (sig == 'PMGL') {
      _parsePmgl(block, blockLen, out);
      page = _i32(block, 0x10);
    } else if (sig == 'PMGI') {
      // 索引页只在 index_head 指向它时出现；真实文件从 index_head 起步是 PMGL。
      throw ChmFormatException('目录首页是 PMGI 索引页，本阅读器只按叶子页枚举');
    } else {
      throw ChmFormatException('目录块 $page 的签名不是 PMGL/PMGI（是 "$sig"）');
    }
  }
  return out;
}

void _parsePmgl(Uint8List block, int blockLen, List<ChmEntry> out) {
  final freeSpace = _u32(block, 0x04);
  if (freeSpace > blockLen) throw ChmFormatException('PMGL free_space 越界');
  var end = blockLen - freeSpace;
  if (end > block.length) end = block.length;
  var pos = 0x14;
  while (pos < end) {
    final pathLen = _parseCword(block, pos);
    pos = pathLen.next;
    if (pathLen.value <= 0 ||
        pathLen.value > 0x10000 ||
        pos + pathLen.value > end) {
      throw ChmFormatException('PMGL 条目的路径长度非法');
    }
    final path = _decodePath(block, pos, pathLen.value);
    pos += pathLen.value;
    final space = _parseCword(block, pos);
    pos = space.next;
    final start = _parseCword(block, pos);
    pos = start.next;
    final length = _parseCword(block, pos);
    pos = length.next;
    if (space.value > 1) {
      throw ChmFormatException('条目 $path 的存储空间 ${space.value} 不认识');
    }
    out.add(
      ChmEntry(
        path: path,
        space: space.value,
        start: start.value,
        length: length.value,
      ),
    );
  }
}

/// PMGL 里的"压缩 DWORD"：**大端** 7 位变长整数（最高位为续读标志）。
({int value, int next}) _parseCword(Uint8List b, int pos) {
  var accum = 0;
  var p = pos;
  if (p >= b.length) throw ChmFormatException('PMGL 条目越界');
  var temp = b[p++];
  while (temp >= 0x80) {
    accum = (accum << 7) + (temp & 0x7f);
    if (p >= b.length) throw ChmFormatException('PMGL 变长整数越界');
    temp = b[p++];
    if (accum > 0x7FFFFFFFFF) {
      throw ChmFormatException('PMGL 变长整数过大');
    }
  }
  return (value: (accum << 7) + temp, next: p);
}

// ---------------------------------------------------------------- LZX

/// CHM 用的 LZX 解压器（**纯 Dart**，供解析层与单测直接使用）。
///
/// 与 CAB 的 LZX 是同源算法，但 CHM 的流式封装有三处不同（都由 chmlib 的
/// lzx.c 所记录的事实决定）：
///   1. 流头（1 bit 标志 + 可选 32 位 E8 文件长度）**每个重置区间只读一次**，
///      不是每个 CFDATA 帧一次；
///   2. 块头的 24 位块长度在**所有**块类型（含 uncompressed）之前读取；
///   3. uncompressed 块在块头之后 4 字节处放 R0/R1/R2（各 32 位小端），
///      原始数据从块头 +16 字节开始。
class ChmLzxDecoder {
  ChmLzxDecoder({required int windowBits, this.onBlockType})
    : _windowBits = windowBits {
    if (windowBits < 15 || windowBits > 21) {
      throw ChmUnsupportedException('LZX 窗口 $windowBits 位未实现（支持 15..21）');
    }
    _window = Uint8List(1 << windowBits);
    final posnSlots = windowBits == 20
        ? 42
        : (windowBits == 21 ? 50 : windowBits << 1);
    _mainElements = _kNumChars + (posnSlots << 3);
    _mainLens = List<int>.filled(_mainElements + 64, 0);
    _lengthLens = List<int>.filled(_kNumSecondaryLengths + 64, 0);
    _alignedLens = List<int>.filled(8, 0);
    _reset();
  }

  /// 观察钩子：每读到一个 LZX 块头就把块类型（1/2/3）回报一次。
  ///
  /// **纯粹给探针/测试用**（`tool/chm_real_probe.dart` 用它统计真实文件到底走了
  /// verbatim/aligned/uncompressed 哪条路径）；为 null 时零开销，解码行为一字不变。
  final void Function(int blockType)? onBlockType;

  final int _windowBits;
  late final Uint8List _window;
  late final int _mainElements;
  late final List<int> _mainLens;
  late final List<int> _lengthLens;
  late final List<int> _alignedLens;

  int _r0 = 1;
  int _r1 = 1;
  int _r2 = 1;
  int _windowPos = 0;
  bool _headerRead = false;
  int _framesRead = 0;
  int _blockType = 0;
  int _blockLength = 0;
  int _blockRemaining = 0;
  int _intelFileSize = 0;
  int _intelCurPos = 0;
  bool _intelStarted = false;

  _Huffman? _mainTree;
  _Huffman? _lengthTree;
  _Huffman? _alignedTree;

  int get windowSize => 1 << _windowBits;

  /// 解开一个压缩块（[outLen] 通常等于 CHM 的块大小 32768）。
  ///
  /// 状态（窗口、R0/R1/R2、流头是否已读）跨调用保留 —— 调用方按内容流顺序
  /// 逐块喂入即可；每个**重置区间**要新建一个实例（等价于 LZXreset）。
  Uint8List decodeChunk(Uint8List input, int outLen) {
    if (outLen <= 0) return Uint8List(0);
    if (outLen > windowSize) {
      throw ChmFormatException('LZX 单次输出 $outLen 超过窗口 $windowSize');
    }
    final br = _BitReader(input);
    final out = Uint8List(outLen);
    var outPos = 0;

    // 流头：每个重置区间的第一块才有
    if (!_headerRead) {
      final flag = br.read(1);
      if (flag != 0) {
        final hi = br.read(16);
        final lo = br.read(16);
        _intelFileSize = (hi << 16) | lo;
      } else {
        _intelFileSize = 0;
      }
      _headerRead = true;
    }

    var togo = outLen;
    while (togo > 0) {
      if (_blockRemaining == 0) {
        // 上一个 uncompressed 块：先按需多跳一个字节对齐到字，再重置位流
        if (_blockType == _kBlockUncompressed) {
          if (_blockLength & 1 != 0) br.skipByte();
          br.resetBits();
        }
        _blockType = br.read(3);
        onBlockType?.call(_blockType);
        final hi = br.read(16);
        final lo = br.read(8);
        _blockLength = (hi << 8) | lo;
        _blockRemaining = _blockLength;
        if (_blockLength <= 0) {
          throw ChmFormatException('LZX 块长度为 0');
        }
        if (_blockType == _kBlockAligned) {
          // aligned 块：对齐偏移树在**主树/长度树之前**
          for (var i = 0; i < 8; i++) {
            _alignedLens[i] = br.read(3);
          }
          _alignedTree = _Huffman.build(_alignedLens, 8);
          _readTrees(br);
        } else if (_blockType == _kBlockVerbatim) {
          _readTrees(br);
        } else if (_blockType == _kBlockUncompressed) {
          _intelStarted = true;
          // 块头（3+24 位）之后对齐到 16 位字，再读 R0/R1/R2
          br.alignToWord();
          final rStart = br.ip;
          if (rStart + 12 > input.length) {
            throw ChmFormatException('LZX 未压缩块的 R0/R1/R2 被截断');
          }
          _r0 = _u32(input, rStart);
          _r1 = _u32(input, rStart + 4);
          _r2 = _u32(input, rStart + 8);
          br.seek(rStart + 12);
        } else {
          throw ChmUnsupportedException(
            'LZX 块类型 $_blockType 未实现（只实现了 verbatim/aligned/uncompressed）',
          );
        }
      }

      var thisRun = _blockRemaining < togo ? _blockRemaining : togo;
      togo -= thisRun;
      _blockRemaining -= thisRun;

      if (_blockType == _kBlockUncompressed) {
        final dataStart = br.ip;
        if (dataStart + thisRun > input.length) {
          throw ChmFormatException('LZX 未压缩块的数据被截断');
        }
        out.setRange(outPos, outPos + thisRun, input, dataStart);
        for (var i = 0; i < thisRun; i++) {
          _window[(_windowPos + i) & (windowSize - 1)] = input[dataStart + i];
        }
        _windowPos += thisRun;
        outPos += thisRun;
        br.seek(dataStart + thisRun);
        continue;
      }

      final main = _mainTree;
      if (main == null) throw ChmFormatException('LZX 主树缺失');
      final aligned = _alignedTree;
      while (thisRun > 0) {
        final sym = main.decode(br);
        if (sym < _kNumChars) {
          _window[_windowPos & (windowSize - 1)] = sym;
          out[outPos++] = sym;
          _windowPos++;
          thisRun--;
          continue;
        }
        var rest = sym - _kNumChars;
        var matchLength = rest & _kNumPrimaryLengths;
        if (matchLength == _kNumPrimaryLengths) {
          final lengthTree = _lengthTree;
          if (lengthTree == null) throw ChmFormatException('LZX 长度树缺失');
          matchLength += lengthTree.decode(br);
        }
        matchLength += _kMinMatch;
        var matchOffset = rest >> 3;

        if (_blockType == _kBlockAligned) {
          if (matchOffset > 2) {
            final extra = _kExtraBits[matchOffset];
            matchOffset = _kPositionBase[matchOffset] - 2;
            if (extra > 3) {
              final verbatim = br.read(extra - 3);
              matchOffset += verbatim << 3;
              if (aligned == null) throw ChmFormatException('LZX aligned 树缺失');
              matchOffset += aligned.decode(br);
            } else if (extra == 3) {
              if (aligned == null) throw ChmFormatException('LZX aligned 树缺失');
              matchOffset += aligned.decode(br);
            } else if (extra > 0) {
              matchOffset += br.read(extra);
            } else {
              matchOffset = 1;
            }
            _r2 = _r1;
            _r1 = _r0;
            _r0 = matchOffset;
          } else if (matchOffset == 0) {
            matchOffset = _r0;
          } else if (matchOffset == 1) {
            matchOffset = _r1;
            _r1 = _r0;
            _r0 = matchOffset;
          } else {
            matchOffset = _r2;
            _r2 = _r0;
            _r0 = matchOffset;
          }
        } else {
          if (matchOffset > 2) {
            if (matchOffset != 3) {
              final extra = _kExtraBits[matchOffset];
              final verbatim = br.read(extra);
              matchOffset = _kPositionBase[matchOffset] - 2 + verbatim;
            } else {
              matchOffset = 1;
            }
            _r2 = _r1;
            _r1 = _r0;
            _r0 = matchOffset;
          } else if (matchOffset == 0) {
            matchOffset = _r0;
          } else if (matchOffset == 1) {
            matchOffset = _r1;
            _r1 = _r0;
            _r0 = matchOffset;
          } else {
            matchOffset = _r2;
            _r2 = _r0;
            _r0 = matchOffset;
          }
        }

        if (matchOffset <= 0 ||
            matchOffset > windowSize ||
            matchOffset > _windowPos) {
          throw ChmFormatException('LZX 匹配距离 $matchOffset 越界（坏文件）');
        }
        final mask = windowSize - 1;
        var src = (_windowPos - matchOffset) & mask;
        for (var k = 0; k < matchLength; k++) {
          final byte = _window[src];
          src = (src + 1) & mask;
          _window[_windowPos & mask] = byte;
          out[outPos++] = byte;
          _windowPos++;
        }
        thisRun -= matchLength;
      }
    }

    _applyE8(out);
    return out;
  }

  void _readTrees(_BitReader br) {
    _readLens(br, _mainLens, 0, _kNumChars);
    _readLens(br, _mainLens, _kNumChars, _mainElements);
    _mainTree = _Huffman.build(_mainLens, _mainElements);
    if (_mainLens[0xE8] != 0) _intelStarted = true;
    _readLens(br, _lengthLens, 0, _kNumSecondaryLengths);
    _lengthTree = _Huffman.build(_lengthLens, _kNumSecondaryLengths);
  }

  /// LZX 的"码长表"编码：20 个 4 位预表码长 + 预表，然后 17/18/19 是重复编码。
  void _readLens(_BitReader br, List<int> lens, int first, int last) {
    final preLens = List<int>.filled(20, 0);
    for (var x = 0; x < 20; x++) {
      preLens[x] = br.read(4);
    }
    final pre = _Huffman.build(preLens, 20);
    var x = first;
    while (x < last) {
      final z = pre.decode(br);
      if (z == 17) {
        var y = br.read(4) + 4;
        while (y-- > 0 && x < last) {
          lens[x++] = 0;
        }
      } else if (z == 18) {
        var y = br.read(5) + 20;
        while (y-- > 0 && x < last) {
          lens[x++] = 0;
        }
      } else if (z == 19) {
        var y = br.read(1) + 4;
        final z2 = pre.decode(br);
        final v = (lens[x] - z2 + 17) % 17;
        while (y-- > 0 && x < last) {
          lens[x++] = v;
        }
      } else {
        lens[x] = (lens[x] - z + 17) % 17;
        x++;
      }
    }
  }

  void _reset() {
    _r0 = _r1 = _r2 = 1;
    _headerRead = false;
    _framesRead = 0;
    _blockRemaining = 0;
    _blockType = 0;
    _windowPos = 0;
    _intelCurPos = 0;
    _intelStarted = false;
    _intelFileSize = 0;
    for (var i = 0; i < _mainLens.length; i++) {
      _mainLens[i] = 0;
    }
    for (var i = 0; i < _lengthLens.length; i++) {
      _lengthLens[i] = 0;
    }
    _mainTree = null;
    _lengthTree = null;
    _alignedTree = null;
  }

  /// E8 调用地址变换（可执行文件里的 `E8 xx xx xx xx` 相对化）。
  ///
  /// 与 chmlib 同款：只在"有 E8 字面量"且流头给了文件长度时启用，
  /// 每个输出块做一次，最后 10 字节内不动（规范要求最后 6 字节不翻译）。
  void _applyE8(Uint8List out) {
    final frames = _framesRead++;
    if (frames >= 32768 || _intelFileSize == 0) return;
    final outLen = out.length;
    if (outLen <= 6 || !_intelStarted) {
      _intelCurPos += outLen;
      return;
    }
    var curpos = _intelCurPos;
    final filesize = _intelFileSize;
    _intelCurPos = curpos + outLen;
    final end = outLen - 10;
    var i = 0;
    while (i < end) {
      if (out[i++] != 0xE8) {
        curpos++;
        continue;
      }
      if (i + 4 > outLen) break;
      var absOff =
          out[i] | (out[i + 1] << 8) | (out[i + 2] << 16) | (out[i + 3] << 24);
      if (absOff >= 0x80000000) absOff -= 0x100000000; // 有符号 32 位
      if (absOff >= -curpos && absOff < filesize) {
        final rel = absOff >= 0 ? absOff - curpos : absOff + filesize;
        out[i] = rel & 0xFF;
        out[i + 1] = (rel >> 8) & 0xFF;
        out[i + 2] = (rel >> 16) & 0xFF;
        out[i + 3] = (rel >> 24) & 0xFF;
      }
      i += 4;
      curpos += 5;
    }
  }
}

/// 给测试/探针用：把一个独立的 LZX 压缩块解成 [outLen] 字节（新开一个解码器）。
Uint8List chmLzxDecodeBlock(
  List<int> input, {
  required int windowBits,
  required int outLen,
}) {
  final data = input is Uint8List ? input : Uint8List.fromList(input);
  return ChmLzxDecoder(windowBits: windowBits).decodeChunk(data, outLen);
}

// ---------------------------------------------------------------- Huffman

/// 规范 Huffman 解码器（按码长构造，MSB-first 逐位走）。
///
/// 不建查表：LZX 的树最多几千个符号，逐位解码在书这种体量下完全够用，
/// 而且代码量小、没有"查表越界"这类隐藏 bug。空树（全 0 码长）是合法的
/// （LZX 规范允许 length 树为空），此时 [decode] 会报错而不是返回垃圾。
class _Huffman {
  _Huffman._(this._count, this._firstCode, this._offset, this._symbols);

  final List<int> _count;
  final List<int> _firstCode;
  final List<int> _offset;
  final List<int> _symbols;
  bool get isEmpty => _symbols.isEmpty;

  static _Huffman build(List<int> lengths, int nsyms) {
    final count = List<int>.filled(17, 0);
    for (var i = 0; i < nsyms; i++) {
      final l = lengths[i];
      if (l < 0 || l > 16) {
        throw ChmFormatException('LZX 码长 $l 非法');
      }
      if (l != 0) count[l]++;
    }
    final firstCode = List<int>.filled(17, 0);
    final offset = List<int>.filled(17, 0);
    var code = 0;
    var total = 0;
    for (var len = 1; len <= 16; len++) {
      code = (code + count[len - 1]) << 1;
      firstCode[len] = code;
      offset[len] = total;
      total += count[len];
      // 规范 Huffman：同级码字必须放得下
      if (code + count[len] > (1 << len)) {
        throw ChmFormatException('LZX Huffman 码长表非法（过订阅）');
      }
    }
    final symbols = List<int>.filled(total, 0);
    final cursor = List<int>.from(offset);
    for (var sym = 0; sym < nsyms; sym++) {
      final l = lengths[sym];
      if (l == 0) continue;
      symbols[cursor[l]++] = sym;
    }
    return _Huffman._(count, firstCode, offset, symbols);
  }

  int decode(_BitReader br) {
    if (_symbols.isEmpty) throw ChmFormatException('LZX 需要一个空的 Huffman 树来解码');
    var code = 0;
    for (var len = 1; len <= 16; len++) {
      code = (code << 1) | br.read(1);
      final n = _count[len];
      if (n != 0 && code - _firstCode[len] < n && code >= _firstCode[len]) {
        return _symbols[_offset[len] + (code - _firstCode[len])];
      }
    }
    throw ChmFormatException('LZX Huffman 码非法');
  }
}

// ---------------------------------------------------------------- 位流

/// LZX 位流读取器：**小端 16 位字**喂入，从最高位开始取（与 LZX 一致）。
class _BitReader {
  _BitReader(this.data);

  final Uint8List data;
  int _ip = 0;
  int _buf = 0;
  int _bits = 0;

  /// 预取字节数（一般等于 `_ip`；`alignToWord` 会把它退回）
  int get ip => _ip;
  int get bitsLeft => _bits;

  void _ensure(int n) {
    while (_bits < n) {
      final word = _readWord();
      _buf = ((_buf << 16) | word) & ((1 << (_bits + 16)) - 1);
      _bits += 16;
    }
  }

  int _readWord() {
    if (_ip + 2 <= data.length) {
      final w = data[_ip] | (data[_ip + 1] << 8);
      _ip += 2;
      return w;
    }
    final b0 = _ip < data.length ? data[_ip] : 0;
    _ip += 2;
    // 允许末尾两个字节的填充读取（LZX 的边界情况），再远就是截断
    if (_ip > data.length + 2) {
      throw ChmFormatException('LZX 位流被截断');
    }
    return b0;
  }

  int read(int n) {
    if (n == 0) return 0;
    _ensure(n);
    final v = (_buf >> (_bits - n)) & ((1 << n) - 1);
    _bits -= n;
    return v;
  }

  /// 清空位缓冲但**保留字节位置**（LZX 的 INIT_BITSTREAM）
  void resetBits() {
    _buf = 0;
    _bits = 0;
  }

  /// 直接跳到某个字节位置并清空位缓冲
  void seek(int position) {
    _ip = position;
    _buf = 0;
    _bits = 0;
  }

  void skipByte() {
    _ip += 1;
  }

  /// uncompressed 块头之后对齐到 16 位字（等价于 `ENSURE_BITS(16); if (bits>16) ip-=2`）
  void alignToWord() {
    _ensure(16);
    if (_bits > 16) _ip -= 2;
  }
}

// ---------------------------------------------------------------- 常量 / 工具

const int _kMinMatch = 2;
const int _kNumChars = 256;
const int _kBlockVerbatim = 1;
const int _kBlockAligned = 2;
const int _kBlockUncompressed = 3;
const int _kNumPrimaryLengths = 7;
const int _kNumSecondaryLengths = 249;

/// position slot → 额外位数（LZX 规范常量）
const List<int> _kExtraBits = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, //
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14,
  15, 15, 16, 16, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17,
  17, 17, 17,
];

/// position slot → 位置基值（LZX 规范常量）
const List<int> _kPositionBase = [
  0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, //
  256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288,
  16384, 24576, 32768, 49152, 65536, 98304, 131072, 196608, 262144,
  393216, 524288, 655360, 786432, 917504, 1048576, 1179648, 1310720,
  1441792, 1572864, 1703936, 1835008, 1966080, 2097152,
];

int? _log2Exact(int v) {
  if (v <= 0 || (v & (v - 1)) != 0) return null;
  var bits = 0;
  while ((1 << bits) < v) {
    bits++;
  }
  return bits;
}

int _u32(Uint8List b, int offset) {
  if (offset < 0 || offset + 4 > b.length) return 0;
  return b[offset] |
      (b[offset + 1] << 8) |
      (b[offset + 2] << 16) |
      (b[offset + 3] << 24);
}

int _i32(Uint8List b, int offset) {
  final v = _u32(b, offset);
  return v >= 0x80000000 ? v - 0x100000000 : v;
}

int _u64(Uint8List b, int offset) {
  if (offset < 0 || offset + 8 > b.length) return 0;
  var v = 0;
  for (var i = 7; i >= 0; i--) {
    v = (v << 8) | b[offset + i];
  }
  return v;
}

String _ascii(Uint8List b, int offset, int length) {
  if (offset < 0 || offset + length > b.length) return '';
  return String.fromCharCodes(b.sublist(offset, offset + length));
}

/// PMGL 里的路径是 **UTF-8**（chmspec 的说法；现实里中文文件名很常见）。
/// 坏字节不抛异常 —— 路径只是显示/查找用，`allowMalformed` 回落即可。
String _decodePath(Uint8List b, int offset, int length) {
  if (offset < 0 || length <= 0 || offset + length > b.length) {
    throw ChmFormatException('PMGL 路径越界');
  }
  return utf8.decode(
    Uint8List.sublistView(b, offset, offset + length),
    allowMalformed: true,
  );
}

// ---------------------------------------------------------------- 探针

/// 给探针/调试用：不解正文，只回报容器与目录的关键字段。
Map<String, Object?> chmProbe(List<int> bytes) {
  try {
    final a = ChmArchive.open(bytes);
    final compressed = a.entries.where((e) => e.space == 1).length;
    final dirs = a.entries.where((e) => e.isDir).length;
    final hasSystem = a.find('/#SYSTEM') != null;
    final hhc = a.entries
        .where((e) => e.path.toLowerCase().endsWith('.hhc'))
        .map((e) => e.path)
        .toList();
    final html = a.entries.where((e) {
      final p = e.path.toLowerCase();
      return p.endsWith('.htm') || p.endsWith('.html');
    }).length;
    return {
      'version': a.version,
      'langId': a.langId,
      'dirOffset': a.dirOffset,
      'dirLen': a.dirLen,
      'dataOffset': a.dataOffset,
      'blockLen': a.blockLen,
      'entries': a.entries.length,
      'dirs': dirs,
      'compressedEntries': compressed,
      'hasSystem': hasSystem,
      'hhc': hhc,
      'htmlFiles': html,
    };
  } catch (e) {
    return {'error': '$e'};
  }
}

/// 给探针用：只回报"能不能读 + 为什么不能"（不落 `BookContent`）。
Map<String, Object?> chmSupportProbe(List<int> bytes) {
  try {
    final a = ChmArchive.open(bytes);
    var compressedRead = -1;
    var error = '';
    try {
      // 触发一次压缩内容解压（若书里有压缩条目）
      final entry = a.entries.firstWhere(
        (e) => e.space == 1 && e.length > 0,
        orElse: () => const ChmEntry(path: '', space: 0, start: 0, length: 0),
      );
      if (entry.length > 0) compressedRead = a.read(entry).length;
    } on ChmUnsupportedException catch (e) {
      error = e.message;
    } catch (e) {
      error = '$e';
    }
    return {
      'ok': error.isEmpty,
      'entries': a.entries.length,
      'version': a.version,
      'firstCompressedBytes': compressedRead,
      'error': error,
    };
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  }
}
