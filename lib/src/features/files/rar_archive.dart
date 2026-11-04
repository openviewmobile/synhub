// RAR（CBR 漫画包 / 归档）读取器 —— **纯 Dart、零三方依赖**，不 import flutter/l10n。
//
// 为什么要自己写（结论来自 `docs/ebook-formats-research.md`）：
//   * `unseal` 依赖 `archive ^3.1.6`，与本项目 `archive ^4.x` 硬冲突；
//   * `koni_rar` 的已发布 pubspec 带 `resolution: workspace`，外部工程消费不了；
//   * 两者 likes 都是 0、发布仅数天，供应链成熟度按"未验证"对待。
// 用户的要求是"电子书所有格式都要支持；遇到协议/许可证问题就自研"，所以这里
// 从零实现 RAR 的**容器解析 + 解压**，不引任何 RAR 库。
//
// **参考与许可**：比特流格式（RAR 3.0 / RAR 5.0）的事实来自公开的 RAR 技术说明
// 与 BSD-2-Clause 的 Go 实现 `github.com/nwaples/rardecode`
// （Copyright (c) 2015 Nicholas Waples，BSD-2-Clause，允许阅读后独立重写）。
// 本文件是独立重写的 Dart 实现：没有引入该工程的任何代码、模块或依赖，
// 只在算法常量（Huffman 表尺寸、长度/距离基表等纯事实）上一致。
// 测试素材由 rarlab 官方 `rar` 命令行**本地生成**（自造文本 + 自造 PNG），
// 不下载任何真实漫画/电子书。
//
// **能力边界**（宁可给明确错误，也不吐乱码或半截文件）：
//
//   | 维度 | 支持 | 明确报错 |
//   |---|---|---|
//   | 容器 | RAR 4.x（RAR3 主体）、RAR 5.x | —— |
//   | 压缩 | method 0x30（store）、RAR 3.x LZSS+Huffman、RAR 5.0 LZSS+Huffman | RAR 1.5/2.0 解码器（unpackver 15/20/26）、RAR 7（algorithm 1 非 v5 兼容）|
//   | 固实 | solid 包：跨文件共享 Huffman 表与滑动窗口（含基本的多文件链）| —— |
//   | 文件名 | UTF-8；RAR4 的 Unicode 文件名编码；ANSI 回落 GB18030/Big5 | —— |
//   | 校验 | 每个文件的数据 CRC32（RAR4/RAR5 都是 little-endian）| CRC 不符 → 报错 |
//   | 加密 | —— | 档头加密、文件加密（带密码）→ 报错 |
//   | 多卷 | —— | 分卷包、续卷文件块 → 报错 |
//   | 过滤器 | RAR3 标准过滤器（E8/E8E9/Itanium/Delta/RGB）、RAR5（Delta/E8/E9/ARM）| RAR3 未知 VM 过滤器、Audio 过滤器 → 报错 |
//   | PPM | —— | RAR3 的 PPM 块 → 报错 |
//   | 字典 | ≤ 256MB | 超过 → 报错（App 内存兜底）|
//
// 所有"报错"都抛 [RarUnsupportedException]（能力边界）或 [RarFormatException]
//（文件损坏/截断），由调用方翻译成界面的"这本书打不开"。
import 'dart:convert';
import 'dart:typed_data';

import 'file_book.dart' show BookUnsupportedReason;

import 'book_encoding.dart';

/// 能力边界：格式认识、但这个变体我们做不到（加密/多卷/PPM/未实现的解码器…）。
///
/// 与 [RarFormatException] 分开：前者"换别的工具还有救"，后者"文件本身坏了"。
class RarUnsupportedException implements Exception {
  RarUnsupportedException(
    this.message, {
    this.reason = BookUnsupportedReason.other,
  });

  /// ★ r316c：能力边界类型（界面按它取本地化文案，见 `bookParseErrorLabel`）
  final BookUnsupportedReason reason;
  final String message;
  @override
  String toString() => 'RAR 不支持：$message';
}

/// 文件损坏 / 截断 / 头部 CRC 不符 / 数据 CRC 不符。
class RarFormatException implements Exception {
  RarFormatException(this.message);
  final String message;
  @override
  String toString() => 'RAR 解析失败：$message';
}

/// 归档里的一个条目（文件或目录）。
class RarEntry {
  RarEntry._({
    required this.name,
    required this.isDir,
    required this.solid,
    required this.encrypted,
    required this.packedSize,
    required this.unpackedSize,
    required this.hostOs,
    required this.crc32,
    required this.modified,
    required this.method,
    required this.unpackVersion,
  });

  /// 归档内路径，分隔符统一成 `/`（RAR4 原生用 `\`）。
  final String name;
  final bool isDir;

  /// 这个文件用了固实（solid）编码：解码要接着上一个文件的表/窗口。
  final bool solid;
  final bool encrypted;
  final int packedSize;
  final int unpackedSize;

  /// RAR4：0=MSDOS 1=OS2 2=Windows 3=Unix 4=MacOS 5=BeOS；RAR5：0=Windows 1=Unix。
  final int hostOs;

  /// 期望的 CRC32（little-endian 存的 4 字节）；没有校验字段时是 null。
  final int? crc32;
  final DateTime? modified;

  /// 压缩方法：0 = store（原样），其余为压缩算法编号。
  final int method;

  /// 解码器版本（内部用）：29 = RAR3 LZSS+Huffman，50 = RAR5 LZSS+Huffman。
  final int unpackVersion;

  @override
  String toString() => 'RarEntry($name, ${isDir ? 'dir' : '$unpackedSize B'})';
}

/// 打开一个 RAR 归档。**不抛业务无关的异常**：坏文件/能力边界分别抛
/// [RarFormatException] / [RarUnsupportedException]。
class RarArchive {
  RarArchive._(this._bytes, this.entries, this._files, {required this.version});

  final Uint8List _bytes;
  final List<RarEntry> entries;
  final List<_RarFile> _files;

  /// 4 = RAR 4.x，5 = RAR 5.x
  final int version;

  /// 归档是否固实（solid）：固实包里第 2..n 个文件要从上一个文件的解码状态续上。
  bool get isSolid => _files.any((f) => f.solid);

  /// RAR 签名（含自解压 exe 里的偏移扫描，最多找 1MB）
  static bool isRar(List<int> bytes) => _findSignature(bytes) != null;

  static RarArchive open(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final sig = _findSignature(data);
    if (sig == null) {
      throw RarFormatException('不是 RAR 文件（找不到签名）');
    }
    final (offset, version) = sig;
    final files = <_RarFile>[];
    final entries = <RarEntry>[];
    if (version == 4) {
      _parseRar4(data, offset + 7, files, entries);
    } else {
      _parseRar5(data, offset + 8, files, entries);
    }
    if (entries.isEmpty) {
      throw RarFormatException('归档里没有文件');
    }
    final archive = RarArchive._(data, entries, files, version: version);
    return archive;
  }

  /// 顺序解压归档里的文件（solid 必须按归档顺序解码）。
  ///
  /// [only] 给"只要图片"这种场景：不在集合里的条目直接跳过（非固实包可以不解压）。
  /// 返回 `归档内路径 → 字节`（顺序与归档一致）。
  Map<String, Uint8List> extract({Set<String>? only}) {
    final out = <String, Uint8List>{};
    _DecodeReader? dr;
    for (var i = 0; i < _files.length; i++) {
      final f = _files[i];
      if (f.isDir) continue;
      final want = only == null || only.contains(f.name);
      // 固实包必须按顺序全部解压（后面的文件依赖前面的字典/码表）；
      // 非固实包才能"只要图片就跳过其它条目"。
      if (!want && !isSolid && !f.solid) continue;
      if (f.encrypted) {
        throw RarUnsupportedException(
          '「${f.name}」是带密码（加密）的 RAR 条目，本阅读器不解密',
          reason: BookUnsupportedReason.encrypted,
        );
      }
      final Uint8List data;
      if (f.decVer == 0) {
        data = _storeBytes(f);
      } else {
        if (f.unpackedSize < 0) {
          throw RarUnsupportedException('「${f.name}」是压缩条目但没有声明解压后大小');
        }
        dr ??= _DecodeReader();
        final reset = !f.solid;
        var winSize = f.winSize;
        if (!f.solid && winSize > f.unpackedSize) {
          winSize = f.unpackedSize;
        }
        if (winSize > _maxDictSize) {
          throw RarUnsupportedException('字典超过 ${_maxDictSize ~/ (1 << 20)}MB');
        }
        dr.init(
          _PackedSource(_bytes, f.dataOffset, f.dataOffset + f.packedSize),
          f.decVer,
          winSize,
          reset,
        );
        try {
          data = dr.readFile(f.unpackedSize);
          // 固实包：把当前文件剩下的块尾丢掉，让解码状态停在文件边界
          if (isSolid) dr.drain();
        } on RarUnsupportedException catch (e) {
          throw RarUnsupportedException('「${f.name}」：${e.message}');
        } on RarFormatException catch (e) {
          throw RarFormatException('「${f.name}」：${e.message}');
        }
      }
      _verify(f, data);
      if (want) out[f.name] = data;
    }
    return out;
  }

  Uint8List _storeBytes(_RarFile f) {
    final start = f.dataOffset;
    final end = start + f.packedSize;
    if (end > _bytes.length) {
      throw RarFormatException('「${f.name}」的数据区被截断');
    }
    return Uint8List.sublistView(_bytes, start, end);
  }

  void _verify(_RarFile f, Uint8List data) {
    final expected = f.crc32;
    if (expected == null) return;
    if (data.length != f.unpackedSize) {
      throw RarFormatException(
        '「${f.name}」解压后大小不符（声明 ${f.unpackedSize}，实得 ${data.length}）',
      );
    }
    final actual = rarCrc32(data);
    if (actual != expected) {
      throw RarFormatException(
        '「${f.name}」CRC 校验失败（期望 ${expected.toRadixString(16)}，'
        '实得 ${actual.toRadixString(16)}）',
      );
    }
  }
}

/// 字典上限：再大就不是手机该解的东西了（256MB）。
const int _maxDictSize = 256 * 1024 * 1024;

// ------------------------------------------------------------------ 签名

/// 公共前缀 `Rar!\x1A\x07`；RAR4 的第 7 字节是 0x00，RAR5 是 `0x01 0x00`。
const List<int> _rarSigPrefix = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07];

/// 返回 `(签名起点, 版本)`；找不到返回 null。自解压 exe 前面还有 PE，这里最多扫 1MB。
(int, int)? _findSignature(List<int> b) {
  if (b.length < 7) return null;
  final max = b.length - 7 < (1 << 20) ? b.length - 7 : (1 << 20);
  for (var i = 0; i <= max; i++) {
    var ok = b[i + 6] == 0x00 || b[i + 6] == 0x01;
    if (!ok) continue;
    for (var k = 0; k < 6; k++) {
      if (b[i + k] != _rarSigPrefix[k]) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    if (b[i + 6] == 0x01) {
      // RAR5 签名有第 8 字节
      if (i + 7 < b.length && b[i + 7] == 0x00) return (i, 5);
      continue;
    }
    return (i, 4);
  }
  return null;
}

// ------------------------------------------------------------------ CRC32

final Uint32List _crcTable = _buildCrcTable();

Uint32List _buildCrcTable() {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[i] = c;
  }
  return t;
}

/// 标准 CRC32（IEEE，反射多项式 0xEDB88320）——与 ZIP/Gzip/RAR 同一套。
int rarCrc32(List<int> bytes, [int crc = 0]) {
  var c = crc ^ 0xFFFFFFFF;
  for (var i = 0; i < bytes.length; i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// ------------------------------------------------------------------ 内部条目

class _RarFile {
  _RarFile(this.name);

  String name;
  bool isDir = false;
  bool solid = false;
  bool encrypted = false;
  bool first = true;
  bool last = true;
  bool unknownSize = false;
  bool exhausted = false;
  int packedSize = 0;
  int unpackedSize = 0;
  int hostOs = 0;
  int? crc32;
  DateTime? modified;
  int dataOffset = 0;
  int winSize = 0;
  int method = 0;

  /// 0 = store；29 = RAR3；50 = RAR5
  int decVer = 0;
}

// ------------------------------------------------------------------ 头部游标

class _Cursor {
  _Cursor(this.b, this.pos, this.end);

  final Uint8List b;
  int pos;
  final int end;

  bool get eof => pos >= end;
  int get left => end - pos;

  int u8() {
    if (pos >= end) {
      throw RarFormatException('头部被截断（偏移 $pos/$end）');
    }
    return b[pos++];
  }

  int u16() => u8() | (u8() << 8);
  int u32() {
    final v = u8() | (u8() << 8) | (u8() << 16) | (u8() << 24);
    return v & 0xFFFFFFFF;
  }

  int u64() {
    final lo = u32();
    final hi = u32();
    return lo | (hi << 32);
  }

  Uint8List bytes(int n) {
    if (n < 0 || pos + n > end) {
      throw RarFormatException('头部被截断（要 $n 字节，偏移 $pos/$end）');
    }
    final v = Uint8List.sublistView(b, pos, pos + n);
    pos += n;
    return v;
  }

  /// LEB128（RAR5 的 vint）
  int uvarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final c = u8();
      result |= (c & 0x7F) << shift;
      if ((c & 0x80) == 0) break;
      shift += 7;
      if (shift > 63) throw RarFormatException('vint 过长');
    }
    return result;
  }
}

// ================================================================== RAR 4.x

const int _r4BlockArc = 0x73;
const int _r4BlockFile = 0x74;
const int _r4BlockEnd = 0x7B;

const int _r4ArcVolume = 0x0001;
const int _r4ArcSolid = 0x0008;
const int _r4ArcEncrypted = 0x0080;

const int _r4FileSplitBefore = 0x0001;
const int _r4FileSplitAfter = 0x0002;
const int _r4FileEncrypted = 0x0004;
const int _r4FileSolid = 0x0010;
const int _r4FileWindowMask = 0x00E0;
const int _r4FileLarge = 0x0100;
const int _r4FileUnicode = 0x0200;
const int _r4FileSalt = 0x0400;
const int _r4FileExtTime = 0x1000;
const int _r4BlockHasData = 0x8000;

void _parseRar4(
  Uint8List data,
  int start,
  List<_RarFile> files,
  List<RarEntry> entries,
) {
  var pos = start;
  var sawArc = false;
  var firstFile = true;
  while (pos + 7 <= data.length) {
    final hdrStart = pos;
    final c = _Cursor(data, pos, data.length);
    final crc16 = c.u16();
    final htype = c.u8();
    final flags = c.u16();
    final size = c.u16();
    if (size < 7) throw RarFormatException('块头长度非法（$size）');
    final end = hdrStart + size;
    if (end > data.length) throw RarFormatException('块头被截断');
    // RAR3 的块头 CRC 是 CRC32 的低 16 位
    final actual =
        rarCrc32(Uint8List.sublistView(data, hdrStart + 2, end)) & 0xFFFF;
    if (actual != crc16) {
      throw RarFormatException(
        '块头 CRC 不符（期望 ${crc16.toRadixString(16)}，实得 ${actual.toRadixString(16)}）',
      );
    }
    pos = end;
    final base = hdrStart + 7;
    var dataSize = 0;
    if ((flags & _r4BlockHasData) != 0) {
      if (base + 4 > end) throw RarFormatException('文件头被截断');
      dataSize = _le32(data, base);
    }

    switch (htype) {
      case _r4BlockArc:
        if (!sawArc) {
          sawArc = true;
          if ((flags & _r4ArcVolume) != 0) {
            throw RarUnsupportedException(
              '这是分卷压缩包的其中一卷（多卷包）',
              reason: BookUnsupportedReason.multiVolume,
            );
          }
          if ((flags & _r4ArcEncrypted) != 0) {
            throw RarUnsupportedException(
        '归档头被加密（带密码的 RAR）',
        reason: BookUnsupportedReason.encrypted,
      );
          }
        }
        pos += dataSize;
      case _r4BlockFile:
        // blockHasData 的 4 字节 PACK_SIZE 已经在上面读过：文件字段从 base+4 开始
        final f = _readRar4File(data, base + 4, end, flags, dataSize);
        if (!f.first || !f.last) {
          throw RarUnsupportedException('文件「${f.name}」跨卷（多卷包）');
        }
        if (!firstFile && (flags & _r4ArcSolid) != 0 && !f.solid) {
          // 老 rar 有时只在归档头里标 solid；这里保守地把后续文件当固实链
          f.solid = true;
        }
        firstFile = false;
        files.add(f);
        entries.add(_entryOf(f));
        pos += dataSize;
      case _r4BlockEnd:
        if ((flags & 0x0001) != 0) {
          throw RarUnsupportedException('归档在下一卷里继续（多卷包）');
        }
        return;
      default:
        pos += dataSize; // 服务块 / 注释块：整块跳过
    }
  }
  if (!sawArc) throw RarFormatException('缺少归档头');
}

_RarFile _readRar4File(
  Uint8List data,
  int base,
  int end,
  int flags,
  int dataSize,
) {
  if (base + 21 > end) throw RarFormatException('文件头被截断');
  final c = _Cursor(data, base, end);
  final f = _RarFile('');
  f.first = (flags & _r4FileSplitBefore) == 0;
  f.last = (flags & _r4FileSplitAfter) == 0;
  f.solid = (flags & _r4FileSolid) != 0;
  f.encrypted = (flags & _r4FileEncrypted) != 0;
  f.isDir = (flags & _r4FileWindowMask) == _r4FileWindowMask;
  if (!f.isDir) {
    f.winSize = 0x10000 << ((flags & _r4FileWindowMask) >> 5);
  }
  f.packedSize = dataSize;
  final unpLow = c.u32();
  f.hostOs = c.u8();
  final crc = c.u32();
  f.crc32 = crc;
  f.modified = _dosTime(c.u32());
  final unpackVer = c.u8();
  final method = c.u8() - 0x30;
  final nameSize = c.u16();
  c.u32(); // attributes
  var unpSize = unpLow;
  if ((flags & _r4FileLarge) != 0) {
    c.u32(); // HIGH_PACK_SIZE（已在 dataSize 里读过）
    unpSize |= c.u32() << 32;
  }
  f.unpackedSize = unpSize;
  if (unpLow == 0xFFFFFFFF) {
    f.unknownSize = true;
    f.unpackedSize = -1;
  }
  final rawName = c.bytes(nameSize);
  f.name = (flags & _r4FileUnicode) != 0
      ? _decodeRar4UnicodeName(rawName)
      : _decodeAnsiName(rawName);
  f.name = f.name.replaceAll('\\', '/');
  if ((flags & _r4FileSalt) != 0) {
    c.bytes(8); // salt：只用于解密，我们不解密
  }
  if ((flags & _r4FileExtTime) != 0) {
    _readRar4ExtTime(c, f);
  }
  f.dataOffset = end;
  f.method = method;
  if (f.isDir || method == 0) {
    // **存储型（METHOD=0x30）与压缩解码器版本号无关**：RAR 1.5 / 2.0 / 3.x 的包
    // 只要没压缩（PACK_SIZE == UNP_SIZE）就是原样字节，直接按存储读出。版本白名单
    // 只能管到压缩条目，否则 RAR 2.0 打的"只存储"包会被整包误判成不支持。
    f.decVer = 0;
    // 老包（尤其 RAR 2.0）常把 UNP_SIZE 写成 0xFFFFFFFF（未知）；存储型的解压后
    // 大小就是 PACK_SIZE，不必因此报错。
    if (f.unpackedSize < 0) f.unpackedSize = f.packedSize;
  } else {
    switch (unpackVer) {
      case 29:
        f.decVer = _ver29;
      case 20:
      case 26:
        throw RarUnsupportedException(
          'RAR 1.5/2.0 压缩流（unpackver $unpackVer）本阅读器没实现'
          '（同一包里的存储型条目不受影响）；请用较新的工具重新打包',
        );
      case 15:
        throw RarUnsupportedException('RAR 1.5 压缩流未实现（同一包里的存储型条目不受影响）');
      default:
        throw RarUnsupportedException('未知的 RAR 解码器版本 $unpackVer');
    }
  }
  return f;
}

/// RAR4 的「Unicode 文件名」编码：`ansiName \0 highByte flags 压缩串`。
///
/// 这是 RAR3 的自有编码（不是标准 UTF-8）—— 中文文件名在 RAR4 里几乎都走它，
/// 所以不能省。逐 2 bit 选 4 种字符打包方式（见公开说明）。
String _decodeRar4UnicodeName(Uint8List buf) {
  final nul = buf.indexOf(0);
  if (nul < 0) return _decodeAnsiName(buf); // 没有编码段 → 当纯字节处理
  final name = Uint8List.sublistView(buf, 0, nul);
  final enc = Uint8List.sublistView(buf, nul + 1);
  if (enc.length < 2) return '';
  var pos = 0;
  int nextByte() => pos < enc.length ? enc[pos++] : 0;
  final highByte = nextByte() << 8;
  var flags = nextByte();
  var flagBits = 8;
  final wchars = <int>[];
  while (wchars.length < name.length && pos < enc.length) {
    if (flagBits == 0) {
      flags = nextByte();
      flagBits = 8;
      if (pos >= enc.length) break;
    }
    switch (flags >> 6) {
      case 0:
        wchars.add(nextByte());
      case 1:
        wchars.add(nextByte() | highByte);
      case 2:
        if (enc.length - pos < 2) break;
        wchars.add(nextByte() | (nextByte() << 8));
      case 3:
        final n = nextByte();
        final rest = Uint8List.sublistView(name, wchars.length);
        var len = (n & 0x7F) + 2;
        if (len > rest.length) len = rest.length;
        if ((n & 0x80) != 0) {
          final ec = nextByte();
          for (var i = 0; i < len; i++) {
            wchars.add((rest[i] + ec) | highByte);
          }
        } else {
          for (var i = 0; i < len; i++) {
            wchars.add(rest[i]);
          }
        }
    }
    // flags 是**字节**：左移要按 8 位回绕（Go 里 byte << 2 会截断）
    flags = (flags << 2) & 0xFF;
    flagBits -= 2;
  }
  return String.fromCharCodes(wchars);
}

/// 非 Unicode 文件名：先严格 UTF-8，再回落 GB18030/Big5（老 RAR 用本地 ANSI 码页）。
String _decodeAnsiName(Uint8List raw) {
  try {
    return const Utf8Decoder(allowMalformed: false).convert(raw);
  } on FormatException {
    return decodeBookText(raw);
  }
}

void _readRar4ExtTime(_Cursor c, _RarFile f) {
  if (c.left < 2) return;
  final flags = c.u16();
  // 各位：mtime/ctime/atime，各 4 bit（bit3=存在、bit2=+1s、bit0-1=额外精度字节数）
  final order = <int>[flags >> 12, (flags >> 8) & 0xF, (flags >> 4) & 0xF];
  final times = <DateTime?>[f.modified, null, null];
  for (var i = 0; i < 3; i++) {
    final n = order[i];
    if ((n & 0x8) == 0) continue;
    if (i != 0) {
      if (c.left < 4) return;
      times[i] = _dosTime(c.u32());
    }
    var t = times[i] ?? f.modified ?? DateTime.fromMillisecondsSinceEpoch(0);
    if ((n & 0x4) != 0) t = t.add(const Duration(seconds: 1));
    final extra = n & 0x3;
    if (extra == 0) continue;
    if (c.left < extra) return;
    var d = 0;
    for (var j = 3 - extra; j < extra; j++) {
      d |= c.u8() << (j * 8);
    }
    t = t.add(Duration(microseconds: d ~/ 10));
    times[i] = t;
  }
  f.modified = times[0] ?? f.modified;
}

DateTime _dosTime(int t) {
  final sec = (t & 0x1F) << 1;
  final min = (t >> 5) & 0x3F;
  final hr = (t >> 11) & 0x1F;
  final day = (t >> 16) & 0x1F;
  final mon = (t >> 21) & 0x0F;
  final yr = ((t >> 25) & 0x7F) + 1980;
  if (mon < 1 || mon > 12 || day < 1 || day > 31) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime(yr, mon, day, hr, min, sec);
}

// ================================================================== RAR 5.x

const int _r5BlockArc = 1;
const int _r5BlockFile = 2;
const int _r5BlockEncrypt = 4;
const int _r5BlockEnd = 5;

const int _r5BlockHasExtra = 0x0001;
const int _r5BlockHasData = 0x0002;
const int _r5BlockDataNotFirst = 0x0008;
const int _r5BlockDataNotLast = 0x0010;

const int _r5ArcMultiVol = 0x0001;
const int _r5ArcSolid = 0x0004;

const int _r5FileIsDir = 0x0001;
const int _r5FileHasMtime = 0x0002;
const int _r5FileHasCrc32 = 0x0004;
const int _r5FileSizeUnknown = 0x0008;

const int _r5CompAlgorithm = 0x3F;
const int _r5CompSolid = 0x40;
const int _r5CompMethod = 0x380;
const int _r5CompDictSize = 0x7C00;
const int _r5CompDictFract = 0xF8000;
const int _r5CompV5Compat = 0x100000;

void _parseRar5(
  Uint8List data,
  int start,
  List<_RarFile> files,
  List<RarEntry> entries,
) {
  var pos = start;
  var sawArc = false;
  var archiveSolid = false;
  var firstFile = true;
  while (pos + 4 <= data.length) {
    final hdrStart = pos;
    final c = _Cursor(data, pos, data.length);
    final crc = c.u32();
    final hdrSize = c.uvarint();
    // HEAD_SIZE 不含 size 字段本身；块头总长 = 4(CRC) + size字段 + HEAD_SIZE
    final sizeFieldLen = c.pos - (hdrStart + 4);
    if (hdrSize + sizeFieldLen < 4 || hdrSize > 0x200000) {
      throw RarFormatException('RAR5 块头长度非法（$hdrSize）');
    }
    final end = hdrStart + 4 + sizeFieldLen + hdrSize;
    if (end > data.length) throw RarFormatException('RAR5 块头被截断');
    final actual = rarCrc32(Uint8List.sublistView(data, hdrStart + 4, end));
    if (actual != crc) {
      throw RarFormatException(
        'RAR5 块头 CRC 不符（期望 ${crc.toRadixString(16)}，实得 ${actual.toRadixString(16)}）',
      );
    }
    pos = end;
    // 块头正文（到 extra 区之前）
    final hc = _Cursor(data, c.pos, end);
    final htype = hc.uvarint();
    final flags = hc.uvarint();
    var extraSize = 0;
    if ((flags & _r5BlockHasExtra) != 0) extraSize = hc.uvarint();
    var dataSize = 0;
    if ((flags & _r5BlockHasData) != 0) dataSize = hc.uvarint();
    if (hc.left < extraSize) throw RarFormatException('RAR5 块头 extra 区越界');
    final dataEnd = end - extraSize;
    final dataCursor = _Cursor(data, hc.pos, dataEnd);
    final extraCursor = _Cursor(data, dataEnd, end);

    switch (htype) {
      case _r5BlockArc:
        final arcFlags = dataCursor.uvarint();
        if ((arcFlags & _r5ArcMultiVol) != 0) {
          throw RarUnsupportedException(
              '这是分卷压缩包的其中一卷（多卷包）',
              reason: BookUnsupportedReason.multiVolume,
            );
        }
        archiveSolid = (arcFlags & _r5ArcSolid) != 0;
        sawArc = true;
        pos += dataSize;
      case _r5BlockEncrypt:
        throw RarUnsupportedException(
        '归档头被加密（带密码的 RAR）',
        reason: BookUnsupportedReason.encrypted,
      );
      case _r5BlockFile:
        final f = _readRar5File(
          data,
          hc.pos,
          dataEnd,
          end,
          flags,
          dataSize,
          extraCursor,
        );
        if (!f.first || !f.last) {
          throw RarUnsupportedException('文件「${f.name}」跨卷（多卷包）');
        }
        if (!firstFile && archiveSolid && !f.solid) f.solid = true;
        firstFile = false;
        files.add(f);
        entries.add(_entryOf(f));
        pos += dataSize;
      case _r5BlockEnd:
        final endFlags = dataCursor.uvarint();
        if ((endFlags & 0x0001) != 0) {
          throw RarUnsupportedException('归档在下一卷里继续（多卷包）');
        }
        return;
      default:
        pos += dataSize;
    }
  }
  if (!sawArc) throw RarFormatException('缺少 RAR5 归档头');
}

_RarFile _readRar5File(
  Uint8List data,
  int dataStart,
  int dataEnd,
  int blockEnd,
  int blockFlags,
  int dataSize,
  _Cursor extra,
) {
  final f = _RarFile('');
  f.first = (blockFlags & _r5BlockDataNotFirst) == 0;
  f.last = (blockFlags & _r5BlockDataNotLast) == 0;
  final c = _Cursor(data, dataStart, dataEnd);
  final fileFlags = c.uvarint();
  f.isDir = (fileFlags & _r5FileIsDir) != 0;
  f.unknownSize = (fileFlags & _r5FileSizeUnknown) != 0;
  f.unpackedSize = c.uvarint();
  f.packedSize = dataSize;
  c.uvarint(); // attributes
  if ((fileFlags & _r5FileHasMtime) != 0) {
    f.modified = DateTime.fromMillisecondsSinceEpoch(c.u32() * 1000);
  }
  if ((fileFlags & _r5FileHasCrc32) != 0) {
    f.crc32 = c.u32();
  }
  final compFlags = c.uvarint();
  f.solid = (compFlags & _r5CompSolid) != 0;
  final method = (compFlags & _r5CompMethod) >> 7;
  f.method = method;
  if (method != 0) {
    final alg = compFlags & _r5CompAlgorithm;
    var win = 0x20000 << ((compFlags & _r5CompDictSize) >> 10);
    switch (alg) {
      case 0:
        f.decVer = _ver50;
      case 1:
        if ((compFlags & _r5CompV5Compat) != 0) {
          f.decVer = _ver50;
        } else {
          throw RarUnsupportedException('RAR 7 压缩（algorithm 1，非 v5 兼容）本阅读器没实现');
        }
        win += win ~/ 32 * ((compFlags & _r5CompDictFract) >> 15);
      default:
        throw RarUnsupportedException('未知的 RAR5 压缩算法（$alg）');
    }
    f.winSize = win;
  }
  final hostOs = c.uvarint();
  f.hostOs = hostOs == 0
      ? 3 // Windows
      : hostOs == 1
      ? 4 // Unix
      : 0;
  final nameLen = c.uvarint();
  if (nameLen > 0x10000 || c.left < nameLen) {
    throw RarFormatException('RAR5 文件名长度非法');
  }
  f.name = utf8.decode(c.bytes(nameLen), allowMalformed: true);
  // 归档内路径分隔符两种都要接受：Windows 打的包是 `\`，Unix 是 `/`，统一成 `/`。
  f.name = f.name.replaceAll('\\', '/');
  // 存储型（method == 0）即使声明"大小未知"，解压后大小就是 PACK_SIZE。
  if (f.unknownSize) f.unpackedSize = method == 0 ? f.packedSize : -1;
  // 数据区紧跟在**整个块头**（含 extra 区）之后
  f.dataOffset = blockEnd;

  // extra 记录
  while (!extra.eof) {
    final sz = extra.uvarint();
    if (extra.left < sz) throw RarFormatException('RAR5 extra 记录越界');
    final rec = _Cursor(data, extra.pos, extra.pos + sz);
    extra.pos += sz;
    final ftype = rec.uvarint();
    switch (ftype) {
      case 1: // 加密记录
        f.encrypted = true;
      case 3: // 高精度时间
        _readRar5PrecisionTime(rec, f);
      case 4: // 版本
        rec.uvarint();
        rec.uvarint();
      default:
        break;
    }
  }
  return f;
}

/// 返回"整个块头结束、数据区开始"的偏移。
void _readRar5PrecisionTime(_Cursor c, _RarFile f) {
  final flags = c.uvarint();
  final unix = (flags & 0x01) != 0;
  int? mtime;
  if ((flags & 0x02) != 0) {
    if (unix) {
      mtime = c.u32() * 1000;
    } else {
      final t = c.u64() - 116444736000000000;
      mtime = t ~/ 10000;
    }
  }
  if (mtime != null) {
    f.modified = DateTime.fromMillisecondsSinceEpoch(mtime);
  }
}

RarEntry _entryOf(_RarFile f) => RarEntry._(
  name: f.name,
  isDir: f.isDir,
  solid: f.solid,
  encrypted: f.encrypted,
  packedSize: f.packedSize,
  unpackedSize: f.unpackedSize,
  hostOs: f.hostOs,
  crc32: f.crc32,
  modified: f.modified,
  method: f.method,
  unpackVersion: f.decVer,
);

int _le32(Uint8List b, int i) =>
    (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) & 0xFFFFFFFF;

// ================================================================== 解码器

const int _ver29 = 29;
const int _ver50 = 50;

/// 解压数据源：一块连续的 packed 字节。
class _PackedSource {
  _PackedSource(this.b, this.pos, this.end);

  final Uint8List b;
  int pos;
  final int end;

  /// 读一个字节；没有了返回 null（Go 里的 io.EOF）
  int? tryByte() => pos < end ? b[pos++] : null;

  /// 读一个字节；没有了抛硬错误（Go 里的 ErrDecoderOutOfData）
  int byte() {
    final v = tryByte();
    if (v == null) throw RarFormatException('解压数据提前结束（packed 数据不够）');
    return v;
  }

  void readInto(Uint8List dst, int at, int n) {
    for (var i = 0; i < n; i++) {
      dst[at + i] = byte();
    }
  }
}

/// 位读取器的共同接口（Huffman 解码只关心这两件事）。
abstract class _Bits {
  /// 读 [n] 位；**数据/块边界到了返回 null**（对应 Go 里的 io.EOF）。
  int? readBits(int n);
  void unreadBits(int n);
}

/// 位缓冲掩码：**53 位**（JS 的 `int` 是 2^53 精确的 number，写 55/56 位会让
/// `flutter build web` 直接编不过）。语义等价：`readBits(n)` 只在 `n > _n` 时补字节，
/// 而 `n` 最大 32（`readUint32`）⇒ 移位前的 `_n <= 24`、`_v < 2^32`，
/// 缓冲里实际有效位永远不超过 53 位（第 335 轮）。
const int _kRarBitMask = 0x1FFFFFFFFFFFFF;

/// RAR3 的位读取器：高位在前，字节补进低位。
class _RarBitReader implements _Bits {
  _RarBitReader(this.src);
  _PackedSource src;
  int _v = 0;
  int _n = 0;

  void reset(_PackedSource s) {
    src = s;
    _v = 0;
    _n = 0;
  }

  /// 读 [n] 位；数据不够返回 null。
  @override
  int? readBits(int n) {
    while (n > _n) {
      final b = src.tryByte();
      if (b == null) return null;
      _v = ((_v << 8) | b) & _kRarBitMask;
      _n += 8;
    }
    _n -= n;
    return (_v >> _n) & ((1 << n) - 1);
  }

  @override
  void unreadBits(int n) => _n += n;

  void alignByte() => _n -= _n % 8;

  /// RAR3 的变长整数
  int? readUint32() {
    final n = readBits(2);
    if (n == null) return null;
    if (n != 1) {
      return readBits(4 << n);
    }
    final hi = readBits(4);
    if (hi == null) return null;
    if (hi == 0) {
      final b = readBits(8);
      if (b == null) return null;
      return (b | (-1 << 8)) & 0xFFFFFFFF;
    }
    final lo = readBits(4);
    if (lo == null) return null;
    return (hi << 4) | lo;
  }

  int? readByte() => _n == 0 ? src.tryByte() : readBits(8);

  void readFull(Uint8List dst, int at, int n) {
    for (var i = 0; i < n; i++) {
      final b = readByte();
      if (b == null) throw RarFormatException('解压数据提前结束');
      dst[at + i] = b;
    }
  }
}

/// RAR5 的位读取器：有"本块最多能读多少位"的上限，越界返回 null（io.EOF）。
class _Rar5BitReader implements _Bits {
  _Rar5BitReader(this.src);
  _PackedSource src;
  int _v = 0;
  int _n = 0;
  int _limit = 0;

  void reset(_PackedSource s) {
    src = s;
    _v = 0;
    _n = 0;
  }

  void setLimit(int bits) {
    _limit = bits;
    _n = 0;
  }

  @override
  int? readBits(int n) {
    while (n > _n) {
      if (_limit == 0) return null;
      final c = src.tryByte();
      if (c == null) throw RarFormatException('解压数据提前结束（packed 数据不够）');
      _v = ((_v << 8) | c) & _kRarBitMask;
      _n += 8;
      _limit -= 8;
      if (_limit < 0) {
        final extra = -_limit;
        _limit = 0;
        _v >>= extra;
        _n -= extra;
      }
    }
    _n -= n;
    return (_v >> _n) & ((1 << n) - 1);
  }

  @override
  void unreadBits(int n) => _n += n;

  int? readByte() => _n == 0 ? src.tryByte() : readBits(8);

  void readFull(Uint8List dst, int at, int n) {
    for (var i = 0; i < n; i++) {
      final b = readByte();
      if (b == null) throw RarFormatException('解压数据提前结束');
      dst[at + i] = b;
    }
  }
}

const int _maxCodeLength = 15;
const int _maxQuickBits = 10;
const int _maxQuickSize = 1 << _maxQuickBits;

/// 规范 Huffman 解码器（RAR3 / RAR5 共用，表结构由调用方裁剪）。
class _HuffmanDecoder {
  final List<int> limit = List<int>.filled(_maxCodeLength + 1, 0);
  final List<int> pos = List<int>.filled(_maxCodeLength + 1, 0);
  List<int> symbol = [];
  int minBits = 0;
  int quickBits = 0;
  final Uint8List quickLen = Uint8List(_maxQuickSize);
  final Uint16List quickSym = Uint16List(_maxQuickSize);

  void init(List<int> codeLengths) {
    final count = List<int>.filled(_maxCodeLength + 1, 0);
    for (final n in codeLengths) {
      if (n == 0) continue;
      count[n]++;
    }
    pos[0] = 0;
    limit[0] = 0;
    minBits = 0;
    for (var i = 1; i <= _maxCodeLength; i++) {
      limit[i] = limit[i - 1] + (count[i] << (_maxCodeLength - i));
      pos[i] = pos[i - 1] + count[i - 1];
      if (minBits == 0 && limit[i] > 0) minBits = i;
    }
    symbol = List<int>.filled(codeLengths.length, 0);
    final counters = List<int>.from(pos);
    for (var i = 0; i < codeLengths.length; i++) {
      final n = codeLengths[i];
      if (n != 0) {
        symbol[counters[n]] = i;
        counters[n]++;
      }
    }
    quickBits = codeLengths.length >= 298 ? _maxQuickBits : _maxQuickBits - 3;
    var bits = 1;
    for (var i = 0; i < (1 << quickBits); i++) {
      var v = i << (_maxCodeLength - quickBits);
      while (v >= limit[bits] && bits < _maxCodeLength) {
        bits++;
      }
      quickLen[i] = bits;
      var dist = v - limit[bits - 1];
      dist >>= _maxCodeLength - bits;
      final p = pos[bits] + dist;
      quickSym[i] = p < symbol.length ? symbol[p] : 0;
    }
  }

  /// 解一个符号；数据结束（io.EOF）返回 null，码表损坏返回 -1。
  int? readSym(_Bits r) {
    var bits = 0;
    int v;
    final n = r.readBits(_maxCodeLength);
    if (n == null) {
      // 位流到头（块边界）：退化成一位一位地读，能取到就取
      v = 0;
      for (bits = 1; bits <= _maxCodeLength; bits++) {
        final b = r.readBits(1);
        if (b == null) return null;
        v |= b << (_maxCodeLength - bits);
        if (v < limit[bits]) break;
      }
    } else {
      v = n;
      if (v < limit[quickBits]) {
        final i = v >> (_maxCodeLength - quickBits);
        r.unreadBits(_maxCodeLength - quickLen[i]);
        return quickSym[i];
      }
      for (bits = minBits; bits < _maxCodeLength; bits++) {
        if (v < limit[bits]) {
          r.unreadBits(_maxCodeLength - bits);
          break;
        }
      }
    }
    if (bits < 1) return -1;
    final dist = (v - limit[bits - 1]) >> (_maxCodeLength - bits);
    final p = pos[bits] + dist;
    if (p < 0 || p >= symbol.length) return -1;
    return symbol[p];
  }
}

/// 读"码长表"（RAR3 / RAR5 同一套编码）。
void _readCodeLengthTable(_Bits br, List<int> codeLength, bool addOld) {
  int need(int? v) {
    if (v == null) throw RarFormatException('码长表被截断');
    return v;
  }

  int bits4() => need(br.readBits(4));

  final bitLength = List<int>.filled(20, 0);
  for (var i = 0; i < 20; i++) {
    final n = bits4();
    if (n == 0xF) {
      final cnt = bits4();
      if (cnt > 0) {
        i += cnt + 1;
        continue;
      }
    }
    bitLength[i] = n;
  }
  final bl = _HuffmanDecoder()..init(bitLength);
  for (var i = 0; i < codeLength.length; i++) {
    final l = bl.readSym(br);
    if (l == null) throw RarFormatException('码长表被截断');
    if (l < 0) throw RarFormatException('码长表损坏');
    if (l < 16) {
      codeLength[i] = addOld ? (codeLength[i] + l) & 0xF : l;
      continue;
    }
    int count;
    if (l == 16 || l == 18) {
      count = 3 + need(br.readBits(3));
    } else {
      count = 11 + need(br.readBits(7));
    }
    var value = 0;
    if (l < 18) {
      if (i == 0) throw RarFormatException('码长表重复符号出现在开头');
      value = codeLength[i - 1];
    }
    for (; count > 0 && i < codeLength.length; i++) {
      codeLength[i] = value;
      count--;
    }
    i--;
  }
}

// ------------------------------------------------------------------ 输出窗口

/// 解码块和共享窗口：与 RAR 的解压模型一致 —— 解码器把字节写进滑动窗口，
/// 读取端从窗口里取；固实包跨文件保留窗口与 Huffman 表。
class _DecodeReader {
  Uint8List win = Uint8List(0);
  int size = 0;
  int r = 0;
  int w = 0;
  List<_FilterBlock> fl = [];
  _Decoder? dec;
  bool _ended = false;
  Uint8List outbuf = Uint8List(0);
  int outPos = 0;
  int tot = 0;
  Uint8List _buf = Uint8List(0);

  bool notFull() => w < size;

  void writeByte(int c) {
    win[w] = c;
    w++;
  }

  /// LZSS 的复制：从窗口里 `offset` 距离前复制 `length` 个字节（可自重叠）。
  void copyBytes(int length, int offset) {
    var len = (size + length) % size;
    final wend = w + len < size ? w + len : size;
    var i = (w - offset) % size;
    if (i < 0) i += size;
    if (i == w) {
      w = wend;
      return;
    }
    while (w < wend) {
      win[w] = win[i];
      w++;
      i++;
      if (i == size) i = 0;
    }
  }

  void queueFilter(_FilterBlock f) {
    if (fl.length >= 8192) throw RarFormatException('过滤器过多');
    f.offset += w - r;
    for (final fb in fl) {
      if (f.offset < fb.offset) throw RarFormatException('过滤器位置非法');
      f.offset -= fb.offset;
    }
    f.offset %= size;
    if (f.offset < 0) f.offset += size;
    f.length %= size;
    if (f.length < 0) f.length += size;
    fl.add(f);
  }

  void init(_PackedSource src, int ver, int winSize, bool reset) {
    outbuf = Uint8List(0);
    outPos = 0;
    tot = 0;
    _ended = false;
    if (reset) fl = [];
    final sz = winSize < 0x40000 ? 0x40000 : winSize;
    if (sz > win.length) {
      // 窗口要长大：固实包要保留已解码的历史（老窗口按 w 起点卷回线性）
      final b = Uint8List(sz);
      if (reset) {
        w = 0;
      } else if (win.isNotEmpty) {
        var n = 0;
        if (w < win.length) {
          final len = win.length - w;
          b.setRange(n, n + len, win, w);
          n += len;
        }
        if (w > 0) {
          b.setRange(n, n + w, win, 0);
          n += w;
        }
        w = n;
      }
      win = b;
      size = sz;
    } else if (reset) {
      win.fillRange(0, size, 0);
      w = 0;
    }
    r = w;
    final d = dec;
    if (d == null) {
      dec = ver == _ver29 ? _Lz29Decoder() : _Lz50Decoder();
    } else if (d.ver != ver) {
      throw RarUnsupportedException('同一个归档里混用了两种解码器');
    }
    dec!.reset(src, reset);
  }

  bool fill() {
    if (_ended) return false; // 上一轮已经把"文件结束"记下来了
    if (w == size) {
      r = 0;
      w = 0;
    }
    final ok = dec!.fill(this);
    if (!ok) _ended = true;
    return w != r;
  }

  /// 取 [n] 个字节（必要时继续解码）。返回 false = 解码正常结束但不够 n。
  bool _take(int n, Uint8List dst, int at) {
    var got = 0;
    while (got < n) {
      if (outPos >= outbuf.length) {
        if (!_decode()) break;
      }
      var m = outbuf.length - outPos;
      if (m > n - got) m = n - got;
      dst.setRange(at + got, at + got + m, outbuf, outPos);
      outPos += m;
      got += m;
    }
    return got == n;
  }

  bool _decode() {
    if (w == r) {
      if (!fill()) return false;
    }
    var n = w - r;
    if (fl.isEmpty) {
      outbuf = Uint8List.sublistView(win, r, w);
      outPos = 0;
      r = w;
      tot += n;
      return true;
    }
    final f = fl.first;
    if (f.offset > 0) {
      if (n > f.offset) n = f.offset;
      outbuf = Uint8List.sublistView(win, r, r + n);
      outPos = 0;
      r += n;
      f.offset -= n;
      tot += n;
      return true;
    }
    // 过滤器到了当前读取位置：取数据 → 依次过滤
    outbuf = _processFilters();
    outPos = 0;
    tot += outbuf.length;
    return true;
  }

  Uint8List _processFilters() {
    var f = fl[0];
    final flen = f.length;
    var b = _bufBytes(flen);
    while (true) {
      fl.removeAt(0);
      b = f.filter(b, tot);
      if (fl.isEmpty) return b;
      f = fl[0];
      if (f.offset != 0) {
        f.offset -= flen;
        return b;
      }
      if (f.length != b.length) throw RarFormatException('过滤器长度不一致');
    }
  }

  Uint8List _bufBytes(int n) {
    if (_buf.length < n) _buf = Uint8List(n);
    var ns = 0;
    while (true) {
      var m = w - r;
      if (m > n - ns) m = n - ns;
      if (m > 0) {
        _buf.setRange(ns, ns + m, win, r);
        r += m;
        ns += m;
      }
      if (ns == n) break;
      if (!fill()) throw RarFormatException('过滤器数据被截断');
    }
    return Uint8List.sublistView(_buf, 0, n);
  }

  /// 读一个文件：正好 [n] 个字节。
  Uint8List readFile(int n) {
    final out = Uint8List(n);
    if (!_take(n, out, 0)) {
      throw RarFormatException('解压结果比声明的短');
    }
    return out;
  }

  /// 固实包：把当前文件剩余的输出丢掉，让解码状态走到文件边界。
  void drain() {
    while (true) {
      if (outPos >= outbuf.length) {
        if (!_decode()) return;
        continue;
      }
      if (outbuf.length - outPos == 0) return;
      outPos = outbuf.length;
    }
  }
}

/// 过滤器：对窗口里的一段数据做变换（RAR3 的 VM 过滤器 / RAR5 的 4 种）。
class _FilterBlock {
  _FilterBlock(this.offset, this.length, this.filter);
  int offset;
  int length;
  final Uint8List Function(Uint8List buf, int offset) filter;
}

abstract class _Decoder {
  int get ver;
  void reset(_PackedSource src, bool full);

  /// 把窗口填满/推进；返回 false = 当前文件正常结束。
  bool fill(_DecodeReader dr);
}

// ------------------------------------------------------------------ RAR3 LZ

const int _mainSize = 299;
const int _offsetSize = 60;
const int _lowOffsetSize = 17;
const int _lengthSize = 28;
const int _tableSize = _mainSize + _offsetSize + _lowOffsetSize + _lengthSize;

const List<int> _lengthBase = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, //
  24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224,
];
const List<int> _lengthExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, //
  2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5,
];
const List<int> _offsetBase = [
  0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, //
  512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576,
  32768, 49152, 65536, 98304, 131072, 196608, 262144, 327680, 393216, 458752,
  524288, 589824, 655360, 720896, 786432, 851968, 917504, 983040, 1048576,
  1310720, 1572864, 1835008, 2097152, 2359296, 2621440, 2883584, 3145728,
  3407872, 3670016, 3932160,
];
const List<int> _offsetExtra = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, //
  10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 16, 16, 16, 16, 16,
  16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18, 18,
];
const List<int> _shortOffsetBase = [0, 4, 8, 16, 32, 64, 128, 192];
const List<int> _shortOffsetExtra = [2, 2, 3, 4, 5, 6, 6, 6];

/// RAR 2.9/3.x 的 LZSS + Huffman（unpackver 29）。
class _Lz29Decoder extends _Decoder {
  final List<int> codeLength = List<int>.filled(_tableSize, 0);
  final _HuffmanDecoder main = _HuffmanDecoder();
  final _HuffmanDecoder offsetDec = _HuffmanDecoder();
  final _HuffmanDecoder lowOffsetDec = _HuffmanDecoder();
  final _HuffmanDecoder lengthDec = _HuffmanDecoder();

  final List<int> offsetHist = [0, 0, 0, 0];
  int length = 0;
  int lowOffset = 0;
  int lowOffsetRepeats = 0;
  late _RarBitReader _br;

  /// 当前块是不是 PPM（我们没实现 → 报错）
  bool isPpm = false;
  bool _hdrRead = false;
  bool _eof = false;
  int _fnum = 0;
  List<int> _flen = [];
  final List<_V3Filter> _filters = [];

  @override
  int get ver => _ver29;

  @override
  void reset(_PackedSource src, bool full) {
    _br = _RarBitReader(src);
    _eof = false;
    if (full) {
      _fnum = 0;
      _flen = [];
      _filters.clear();
      offsetHist.setAll(0, [0, 0, 0, 0]);
      length = 0;
      codeLength.fillRange(0, codeLength.length, 0);
      _hdrRead = false;
    }
  }

  void _initTables(_RarBitReader br) {
    lowOffset = 0;
    lowOffsetRepeats = 0;
    final addOld = _need(br.readBits(1)) > 0;
    _readCodeLengthTable(br, codeLength, addOld);
    main.init(codeLength.sublist(0, _mainSize));
    offsetDec.init(codeLength.sublist(_mainSize, _mainSize + _offsetSize));
    lowOffsetDec.init(
      codeLength.sublist(
        _mainSize + _offsetSize,
        _mainSize + _offsetSize + _lowOffsetSize,
      ),
    );
    lengthDec.init(
      codeLength.sublist(_mainSize + _offsetSize + _lowOffsetSize),
    );
  }

  static int _need(int? v) {
    if (v == null) throw RarFormatException('LZ 码表被截断');
    return v;
  }

  void _readEndOfBlock() {
    final n = _need(_br.readBits(1));
    if (n > 0) throw const _EndOfBlock();
    final m = _need(_br.readBits(1));
    if (m > 0) throw const _EndOfBlockAndFile();
    throw const _EndOfFile();
  }

  List<int> _readFilterData() {
    final flags = _need(_br.readBits(8));
    var n = (flags & 7) + 1;
    if (n == 7) {
      n = _need(_br.readBits(8)) + 7;
    } else if (n == 8) {
      n = _need(_br.readBits(16));
    }
    final buf = Uint8List(n + 1);
    buf[0] = flags;
    _br.readFull(buf, 1, n);
    return buf;
  }

  void _decodeLength(int i) {
    final off = offsetHist[i];
    for (var k = i; k > 0; k--) {
      offsetHist[k] = offsetHist[k - 1];
    }
    offsetHist[0] = off;
    final sym = lengthDec.readSym(_br);
    if (sym == null || sym < 0) throw RarFormatException('长度码损坏');
    length = _lengthBase[sym] + 2;
    final bits = _lengthExtra[sym];
    if (bits > 0) length += _need(_br.readBits(bits));
  }

  void _decodeShortOffset(int i) {
    for (var k = 3; k > 0; k--) {
      offsetHist[k] = offsetHist[k - 1];
    }
    var offset = _shortOffsetBase[i] + 1;
    final bits = _shortOffsetExtra[i];
    if (bits > 0) offset += _need(_br.readBits(bits));
    offsetHist[0] = offset;
    length = 2;
  }

  void _decodeOffset(int i) {
    length = _lengthBase[i] + 3;
    final lbits = _lengthExtra[i];
    if (lbits > 0) length += _need(_br.readBits(lbits));

    final sym = offsetDec.readSym(_br);
    if (sym == null || sym < 0) throw RarFormatException('距离码损坏');
    var offset = _offsetBase[sym] + 1;
    final bits = _offsetExtra[sym];
    if (bits >= 4) {
      if (bits > 4) offset += _need(_br.readBits(bits - 4)) << 4;
      if (lowOffsetRepeats > 0) {
        lowOffsetRepeats--;
        offset += lowOffset;
      } else {
        final n = lowOffsetDec.readSym(_br);
        if (n == null || n < 0) throw RarFormatException('低距离码损坏');
        if (n == 16) {
          lowOffsetRepeats = 15;
          offset += lowOffset;
        } else {
          offset += n;
          lowOffset = n;
        }
      }
    } else if (bits > 0) {
      offset += _need(_br.readBits(bits));
    }
    if (offset >= 0x2000) {
      length++;
      if (offset >= 0x40000) length++;
    }
    for (var k = 3; k > 0; k--) {
      offsetHist[k] = offsetHist[k - 1];
    }
    offsetHist[0] = offset;
  }

  @override
  bool fill(_DecodeReader dr) {
    if (_eof) return false;
    while (dr.notFull()) {
      if (!_hdrRead) {
        _readBlockHeader();
      }
      try {
        if (isPpm) {
          throw RarUnsupportedException('RAR3 的 PPM 压缩块本阅读器没实现');
        }
        _fillLz(dr);
      } on _EndOfBlock {
        _hdrRead = false;
        continue;
      } on _EndOfBlockAndFile {
        _eof = true;
        _hdrRead = false;
        return false;
      } on _EndOfFile {
        _eof = true;
        return false;
      }
    }
    return true;
  }

  void _readBlockHeader() {
    _br.alignByte();
    final n = _br.readBits(1);
    if (n == null) throw RarFormatException('压缩块头被截断');
    isPpm = n > 0;
    if (isPpm) {
      throw RarUnsupportedException('RAR3 的 PPM 压缩块本阅读器没实现');
    }
    _initTables(_br);
    _hdrRead = true;
  }

  void _fillLz(_DecodeReader dr) {
    while (dr.notFull()) {
      final sym = main.readSym(_br);
      if (sym == null) throw RarFormatException('LZ 数据提前结束');
      if (sym < 0) throw RarFormatException('LZ 主码表损坏');
      if (sym < 256) {
        dr.writeByte(sym);
        continue;
      }
      if (sym == 258) {
        dr.copyBytes(length, offsetHist[0]);
        continue;
      }
      if (sym == 256) {
        _readEndOfBlock();
        continue;
      }
      if (sym == 257) {
        final b = _readFilterData();
        final f = _parseVmFilter(Uint8List.fromList(b));
        if (f != null) dr.queueFilter(f);
        continue;
      }
      if (sym >= 271) {
        _decodeOffset(sym - 271);
      } else if (sym >= 263) {
        _decodeShortOffset(sym - 263);
      } else {
        _decodeLength(sym - 259);
      }
      dr.copyBytes(length, offsetHist[0]);
    }
  }

  _FilterBlock? _parseVmFilter(Uint8List buf) {
    var flags = buf[0];
    final r = _RarBitReader(_PackedSource(buf, 1, buf.length));
    var offset = 0;
    var length = 0;
    var fnum = _fnum;
    if ((flags & 0x80) != 0) {
      final n = _need(r.readUint32());
      if (n == 0) {
        _fnum = 0;
        _flen = [];
        _filters.clear();
      } else if (n - 1 > 1024 || n - 1 > _filters.length) {
        throw RarFormatException('滤波器编号非法');
      }
      fnum = n == 0 ? 0 : n - 1;
      _fnum = fnum;
    }
    offset = _need(r.readUint32());
    if ((flags & 0x40) != 0) offset += 258;
    if (fnum == _flen.length) _flen.add(0);
    if ((flags & 0x20) != 0) {
      _flen[fnum] = _need(r.readUint32());
    }
    length = _flen[fnum];
    final regs = <int, int>{};
    if ((flags & 0x10) != 0) {
      var bits = _need(r.readBits(6));
      for (var i = 0; i < 6; i++) {
        if ((bits & 1) > 0) regs[i] = _need(r.readUint32());
        bits >>= 1;
      }
    }
    if (fnum == _filters.length) {
      final code = _readVmCode(r);
      _filters.add(_lookupV3Filter(code));
    }
    if ((flags & 0x08) != 0) {
      r.readUint32(); // global data（标准过滤器不需要）
    }
    final impl = _filters[fnum];
    return _FilterBlock(offset, length, impl.build(regs));
  }

  Uint8List _readVmCode(_RarBitReader r) {
    final n = _need(r.readUint32());
    if (n == 0 || n > 0x10000) throw RarFormatException('滤波器代码长度非法');
    final buf = Uint8List(n);
    r.readFull(buf, 0, n);
    var x = 0;
    for (var i = 1; i < n; i++) {
      x ^= buf[i];
    }
    if (x != buf[0]) throw RarFormatException('滤波器代码校验失败');
    return buf;
  }
}

/// RAR3 的标准过滤器：按代码 CRC32 认出来，不需要跑 VM。
class _V3Filter {
  const _V3Filter(this.crc, this.len, this.kind);
  final int crc;
  final int len;
  final String kind;

  Uint8List Function(Uint8List buf, int offset) build(Map<int, int> regs) {
    switch (kind) {
      case 'e8':
        return (b, o) => _filterE8(0xE8, false, b, o);
      case 'e8e9':
        return (b, o) => _filterE8(0xE9, false, b, o);
      case 'itanium':
        return (b, o) => _filterItanium(b, o);
      case 'delta':
        return (b, o) => _filterDelta(regs[0] ?? 0, b);
      case 'rgb':
        return (b, o) => _filterRgb(regs[0] ?? 0, regs[1] ?? 0, b);
      case 'audio':
        return (b, o) => _filterAudio(regs[0] ?? 0, b);
      default:
        throw RarUnsupportedException('未知的 RAR3 过滤器');
    }
  }
}

const List<_V3Filter> _v3Filters = <_V3Filter>[
  _V3Filter(0xAD576887, 53, 'e8'),
  _V3Filter(0x3CD7E57E, 57, 'e8e9'),
  _V3Filter(0x3769893F, 120, 'itanium'),
  _V3Filter(0x0E06077D, 29, 'delta'),
  _V3Filter(0x1C2C5DC8, 149, 'rgb'),
  _V3Filter(0xBC85E701, 216, 'audio'),
];

_V3Filter _lookupV3Filter(Uint8List code) {
  final crc = rarCrc32(code);
  for (final f in _v3Filters) {
    if (f.crc == crc && f.len == code.length) return f;
  }
  throw RarUnsupportedException('RAR3 的 VM 过滤器（非标准）本阅读器没实现');
}

// ------------------------------------------------------------------ RAR5 LZ

const int _mainSize5 = 306;
const int _offsetSize5 = 64;
const int _lowOffsetSize5 = 16;
const int _lengthSize5 = 44;
const int _tableSize5 =
    _mainSize5 + _offsetSize5 + _lowOffsetSize5 + _lengthSize5;

/// RAR 5.0 的 LZSS + Huffman（分块，每块自带码长表）。
class _Lz50Decoder extends _Decoder {
  final List<int> codeLength = List<int>.filled(_tableSize5, 0);
  final _HuffmanDecoder main = _HuffmanDecoder();
  final _HuffmanDecoder offsetDec = _HuffmanDecoder();
  final _HuffmanDecoder lowOffsetDec = _HuffmanDecoder();
  final _HuffmanDecoder lengthDec = _HuffmanDecoder();
  final List<int> offsetHist = [0, 0, 0, 0];
  int length = 0;
  late _Rar5BitReader _br;
  bool _lastBlock = false;

  @override
  int get ver => _ver50;

  @override
  void reset(_PackedSource src, bool full) {
    _br = _Rar5BitReader(src);
    _lastBlock = false;
    if (full) {
      offsetHist.setAll(0, [0, 0, 0, 0]);
      length = 0;
      codeLength.fillRange(0, codeLength.length, 0);
    }
  }

  /// 读一个块头（含可选的码长表）。返回 false = 流结束。
  bool _readBlockHeader() {
    final flags = _br.readByte();
    if (flags == null) return false;
    var byteCount = ((flags >> 3) & 3) + 1;
    if (byteCount == 4) throw RarFormatException('RAR5 块头非法');
    final hsum = _br.readByte();
    if (hsum == null) throw RarFormatException('RAR5 块头被截断');
    var blockBits = (flags & 0x07) + 1;
    var blockBytes = 0;
    var sum = 0x5A ^ flags;
    for (var i = 0; i < byteCount; i++) {
      final n = _br.readByte();
      if (n == null) throw RarFormatException('RAR5 块头被截断');
      sum ^= n;
      blockBytes |= n << (i * 8);
    }
    if (sum != hsum) throw RarFormatException('RAR5 块头校验失败');
    blockBits += (blockBytes - 1) * 8;
    _br.setLimit(blockBits);
    _lastBlock = (flags & 0x40) > 0;
    if ((flags & 0x80) > 0) {
      _readCodeLengthTable(_br, codeLength, false);
      main.init(codeLength.sublist(0, _mainSize5));
      offsetDec.init(codeLength.sublist(_mainSize5, _mainSize5 + _offsetSize5));
      lowOffsetDec.init(
        codeLength.sublist(
          _mainSize5 + _offsetSize5,
          _mainSize5 + _offsetSize5 + _lowOffsetSize5,
        ),
      );
      lengthDec.init(
        codeLength.sublist(_mainSize5 + _offsetSize5 + _lowOffsetSize5),
      );
    }
    return true;
  }

  int _slotToLength(int n) {
    if (n >= 8) {
      final bits = n ~/ 4 - 1;
      n = (4 | (n & 3)) << bits;
      if (bits > 0) n |= _need(_br.readBits(bits));
    }
    return n + 2;
  }

  static int _need(int? v) {
    if (v == null) throw RarFormatException('RAR5 解压位流被截断');
    return v;
  }

  int _readFilter5Data() {
    var bytes = _need(_br.readBits(2)) + 1;
    var data = 0;
    for (var i = 0; i < bytes; i++) {
      data |= _need(_br.readBits(8)) << (i * 8);
    }
    return data;
  }

  void _readFilter(_DecodeReader dr) {
    final offset = _readFilter5Data();
    final len = _readFilter5Data();
    final ftype = _need(_br.readBits(3));
    final Uint8List Function(Uint8List, int) fn;
    switch (ftype) {
      case 0:
        final n = _need(_br.readBits(5)) + 1;
        fn = (b, o) => _filterDelta(n, b);
      case 1:
        fn = (b, o) => _filterE8(0xE8, true, b, o);
      case 2:
        fn = (b, o) => _filterE8(0xE9, true, b, o);
      case 3:
        fn = (b, o) => _filterArm(b, o);
      default:
        throw RarUnsupportedException('未知的 RAR5 过滤器（$ftype）');
    }
    dr.queueFilter(_FilterBlock(offset, len, fn));
  }

  void _decodeLength(_DecodeReader dr, int i) {
    final off = offsetHist[i];
    for (var k = i; k > 0; k--) {
      offsetHist[k] = offsetHist[k - 1];
    }
    offsetHist[0] = off;
    final sl = lengthDec.readSym(_br);
    if (sl == null || sl < 0) throw RarFormatException('RAR5 长度码损坏');
    length = _slotToLength(sl);
    dr.copyBytes(length, offsetHist[0]);
  }

  void _decodeOffset(_DecodeReader dr, int i) {
    var len = _slotToLength(i);
    var offset = 1;
    final slot = offsetDec.readSym(_br);
    if (slot == null || slot < 0) throw RarFormatException('RAR5 距离码损坏');
    if (slot < 4) {
      offset += slot;
    } else {
      var bitCount = slot ~/ 2 - 1;
      offset += (2 | (slot & 1)) << bitCount;
      if (bitCount >= 4) {
        bitCount -= 4;
        if (bitCount > 0) offset += _need(_br.readBits(bitCount)) << 4;
        final n = lowOffsetDec.readSym(_br);
        if (n == null || n < 0) throw RarFormatException('RAR5 低距离码损坏');
        offset += n;
      } else {
        offset += _need(_br.readBits(bitCount));
      }
    }
    if (offset > 0x100) {
      len++;
      if (offset > 0x2000) {
        len++;
        if (offset > 0x40000) len++;
      }
    }
    for (var k = 3; k > 0; k--) {
      offsetHist[k] = offsetHist[k - 1];
    }
    offsetHist[0] = offset;
    length = len;
    dr.copyBytes(length, offset);
  }

  @override
  bool fill(_DecodeReader dr) {
    while (dr.notFull()) {
      final sym = main.readSym(_br);
      if (sym == null) {
        if (_lastBlock) return false;
        if (!_readBlockHeader()) return false;
        continue;
      }
      if (sym < 0) throw RarFormatException('RAR5 主码表损坏');
      if (sym < 256) {
        dr.writeByte(sym);
        continue;
      }
      if (sym == 257) {
        dr.copyBytes(length, offsetHist[0]);
        continue;
      }
      if (sym == 256) {
        _readFilter(dr);
        continue;
      }
      if (sym >= 262) {
        _decodeOffset(dr, sym - 262);
      } else {
        _decodeLength(dr, sym - 258);
      }
    }
    return true;
  }
}

// ------------------------------------------------------------------ 过滤器实现

Uint8List _filterDelta(int n, Uint8List buf) {
  if (n <= 0) return buf;
  final l = buf.length;
  final res = Uint8List(l);
  var i = 0;
  for (var j = 0; j < n; j++) {
    var c = 0;
    for (var k = j; k < l; k += n) {
      c = (c - buf[i]) & 0xFF;
      i++;
      res[k] = c;
    }
  }
  return res;
}

Uint8List _filterE8(int c, bool v5, Uint8List buf, int offset) {
  var off = offset;
  var i = 0;
  while (buf.length - i >= 5) {
    final ch = buf[i];
    i++;
    off++;
    if (ch != 0xE8 && ch != c) continue;
    if (v5) off %= 0x1000000;
    final addr = _le32i(buf, i);
    if (addr >= 0x80000000) {
      // 有符号负数
      final signed = addr - 0x100000000;
      if (signed + off >= 0) {
        _putLe32(buf, i, (signed + 0x1000000) & 0xFFFFFFFF);
      }
    } else if (addr < 0x1000000) {
      _putLe32(buf, i, (addr - off) & 0xFFFFFFFF);
    }
    off += 4;
    i += 4;
  }
  return buf;
}

int _le32i(Uint8List b, int i) =>
    (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) & 0xFFFFFFFF;

void _putLe32(Uint8List b, int i, int v) {
  b[i] = v & 0xFF;
  b[i + 1] = (v >> 8) & 0xFF;
  b[i + 2] = (v >> 16) & 0xFF;
  b[i + 3] = (v >> 24) & 0xFF;
}

Uint8List _filterArm(Uint8List buf, int offset) {
  for (var i = 0; buf.length - i > 3; i += 4) {
    if (buf[i + 3] == 0xEB) {
      var n = buf[i] + (buf[i + 1] << 8) + (buf[i + 2] << 16);
      n -= (offset + i) ~/ 4;
      buf[i] = n & 0xFF;
      buf[i + 1] = (n >> 8) & 0xFF;
      buf[i + 2] = (n >> 16) & 0xFF;
    }
  }
  return buf;
}

const List<int> _itaniumMask = [4, 4, 6, 6, 0, 0, 7, 7, 4, 4, 0, 0, 4, 4, 0, 0];

int _getBits(Uint8List b, int pos, int count) {
  var n = _le32i(b, pos ~/ 8) >> (pos & 7);
  n &= (1 << count) - 1;
  return n;
}

void _setBits(Uint8List b, int pos, int count, int bits) {
  var mask = ((1 << count) - 1) << (pos & 7);
  final at = pos ~/ 8;
  var n = _le32i(b, at);
  n = (n & ~mask) | ((bits << (pos & 7)) & mask);
  _putLe32(b, at, n & 0xFFFFFFFF);
}

Uint8List _filterItanium(Uint8List buf, int offset) {
  var fileOffset = offset >> 4;
  var i = 0;
  while (buf.length - i > 21) {
    final c = (buf[i] & 0x1F) - 0x10;
    if (c >= 0 && c < _itaniumMask.length) {
      final mask = _itaniumMask[c];
      if (mask != 0) {
        for (var k = 0; k <= 2; k++) {
          if ((mask & (1 << k)) == 0) continue;
          final pos = k * 41 + 18;
          if (_getBits(buf, i * 8 + pos + 24, 4) == 5) {
            var n = _getBits(buf, i * 8 + pos, 20);
            n = (n - fileOffset) & 0xFFFFF;
            _setBits(buf, i * 8 + pos, 20, n);
          }
        }
      }
    }
    fileOffset++;
    i += 16;
  }
  return buf;
}

int _iabs(int n) => n < 0 ? -n : n;

Uint8List _filterRgb(int widthReg, int posR, Uint8List buf) {
  final width = widthReg - 3;
  if (posR < 0 || width < 0) return buf;
  final l = buf.length;
  final res = Uint8List(l);
  var src = 0;
  for (var c = 0; c < 3; c++) {
    var prevByte = 0;
    for (var i = c; i < l; i += 3) {
      var predicted = 0;
      final upperPos = i - width;
      if (upperPos >= 3) {
        final upperByte = res[upperPos];
        final upperLeftByte = res[upperPos - 3];
        predicted = prevByte + upperByte - upperLeftByte;
        final pa = _iabs(predicted - prevByte);
        final pb = _iabs(predicted - upperByte);
        final pc = _iabs(predicted - upperLeftByte);
        if (pa <= pb && pa <= pc) {
          predicted = prevByte;
        } else if (pb <= pc) {
          predicted = upperByte;
        } else {
          predicted = upperLeftByte;
        }
      } else {
        predicted = prevByte;
      }
      prevByte = (predicted - buf[src]) & 0xFF;
      src++;
      res[i] = prevByte;
    }
  }
  for (var i = posR; i < l - 2; i += 3) {
    final c = res[i + 1];
    res[i] = (res[i] + c) & 0xFF;
    res[i + 2] = (res[i + 2] + c) & 0xFF;
  }
  return res;
}

int _i8(int v) {
  v &= 0xFF;
  return v > 127 ? v - 256 : v;
}

/// RAR3 的音频过滤器（无损音频预测；漫画里用不到，但归档里可能有）。
Uint8List _filterAudio(int chans, Uint8List buf) {
  if (chans <= 0 || chans > 4) return buf;
  final l = buf.length;
  final res = Uint8List(l);
  var src = 0;
  for (var c = 0; c < chans; c++) {
    var prevByte = 0;
    var byteCount = 0;
    final diff = List<int>.filled(7, 0);
    final d = List<int>.filled(3, 0);
    final k = List<int>.filled(3, 0);
    for (var i = c; i < l; i += chans) {
      var predicted = (prevByte << 3) + k[0] * d[0] + k[1] * d[1] + k[2] * d[2];
      predicted = _i8(predicted >> 3);
      final curByte = src < l ? _i8(buf[src]) : 0;
      src++;
      predicted -= curByte;
      res[i] = predicted & 0xFF;
      final dd = curByte << 3;
      diff[0] += _iabs(dd);
      diff[1] += _iabs(dd - d[0]);
      diff[2] += _iabs(dd + d[0]);
      diff[3] += _iabs(dd - d[1]);
      diff[4] += _iabs(dd + d[1]);
      diff[5] += _iabs(dd - d[2]);
      diff[6] += _iabs(dd + d[2]);
      final prevDelta = _i8(predicted - prevByte);
      prevByte = predicted;
      d[2] = d[1];
      d[1] = prevDelta - d[0];
      d[0] = prevDelta;
      if (byteCount & 0x1F == 0) {
        var min = diff[0];
        diff[0] = 0;
        var n = 0;
        for (var j = 1; j < diff.length; j++) {
          if (diff[j] < min) {
            min = diff[j];
            n = j;
          }
          diff[j] = 0;
        }
        n--;
        if (n >= 0) {
          final m = n ~/ 2;
          if (n % 2 == 0) {
            if (k[m] >= -16) k[m]--;
          } else {
            if (k[m] < 16) k[m]++;
          }
        }
      }
      byteCount++;
    }
  }
  return res;
}

// ================================================================== 信号

class _EndOfBlock implements Exception {
  const _EndOfBlock();
}

class _EndOfBlockAndFile implements Exception {
  const _EndOfBlockAndFile();
}

class _EndOfFile implements Exception {
  const _EndOfFile();
}
