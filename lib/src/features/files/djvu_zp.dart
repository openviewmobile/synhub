// DJVU 的 **ZP 二进制算术编码器**（JB2 / IW44 / BZZ 共用的底层比特编解码器）
// —— 纯 Dart，零 flutter / l10n 依赖。
//
// 为什么要自研：DJVU 的三种压缩（BZZ 文本、JB2 位图、IW44 小波）都建立在这个
// 算术编码器之上；DjVuLibre 是 **GPL-2.0**，对闭源 App 是法务阻塞，pub.dev 上
// 也没有任何 Dart 实现。所以这里按**公开的 DjVu 格式规范**（AT&T/LizardTech
// 发布的 DjVu3 规范，附录里给出 ZP 编码器的算法与默认自适应表）独立重写。
//
// **参考与许可**：算法事实来自公开的 DjVu3 规范与 DjVuLibre 的 `ZPCodec`
// （GPL-2.0，**仅作算法事实参考**，本文件没有任何其代码/头文件/注释的拷贝）。
// 默认自适应表 `_zpTable` 由 `tool/` 侧脚本从规范表逐项核对生成，是**纯常量事实**。
//
// **能力**：完整的 encoder/decoder 对（含 pass-thru 与 no-learn 变体）——
// 解码用于读真实文件，编码用于 `tool/make_djvu_fixture.dart` 自造样本、
// 以及"编解码逐位往返"的自证。
//
// 位流约定（与规范一致）：
//   * 状态机是 16 位区间 `a` + 16 位比较值 `code`；
//   * 每个 bit 用 1 字节的 [ZpBitContext] 状态描述"当前概率 + 置信度"，
//     `ctx.value & 1` 是 MPS（最可能符号）；
//   * 解码器容忍末尾填充：编码器少写的尾部字节按 0xff 读，连续 25 字节都没有
//     真实数据才报 `DjvuFormatException`（**不吐半截乱码**）。
import 'dart:typed_data';

import 'djvu_errors.dart';

/// 一个比特上下文（对应规范里的 `BitContext`：1 字节状态）。
///
/// Dart 没有"按引用传 int"，所以用一个小可变对象；[value] 是上下文状态，
/// 最低位是当前 MPS。初值 0 = "等概率 + 最快自适应"。
class ZpBitContext {
  ZpBitContext([this.value = 0]);
  int value;
}

/// 按数组使用的一批上下文（对应规范里 `BitContext ctx[255]` 这类用法）。
/// 内部是 `Uint8List`，下标访问；初值全 0。
class ZpContextArray {
  ZpContextArray(int count) : values = Uint8List(count);
  final Uint8List values;
  int get length => values.length;
  void reset() => values.fillRange(0, values.length, 0);
}

// ---------------------------------------------------------------- 解码器

/// ZP 解码器。构造时把整段字节读进来（DJVU 的 chunk 都已经在内存里）。
class ZpDecoder {
  ZpDecoder(List<int> data)
    : _data = data is Uint8List ? data : Uint8List.fromList(data) {
    _a = 0;
    // 前两个字节给 code；不足则按 0xff 填（规范允许）
    var b0 = 0xff, b1 = 0xff;
    if (_data.isNotEmpty) b0 = _data[0];
    if (_data.length > 1) b1 = _data[1];
    _code = (b0 << 8) | b1;
    _ip = 2;
    _delay = 25;
    _scount = 0;
    preload();
    _fence = _code >= 0x8000 ? 0x7fff : _code;
  }

  final Uint8List _data;
  late int _a;
  late int _code;
  late int _fence;
  int _buffer = 0;
  int _scount = 0;
  int _delay = 25;
  int _ip = 0;

  /// 常规解码（带自适应）。返回 0/1。
  int decode(ZpBitContext ctx) {
    final z = (_a + _zpP[ctx.value]) & 0xFFFFFFFF;
    if (z <= _fence) {
      _a = z;
      return ctx.value & 1;
    }
    return _decodeSub(ctx, z);
  }

  /// 数组版（对应 `ctx[i]`）——避免为每个上下文建对象。
  int decodeAt(ZpContextArray ctxs, int index) {
    final c = ctxs.values[index];
    final z = (_a + _zpP[c]) & 0xFFFFFFFF;
    if (z <= _fence) {
      _a = z;
      return c & 1;
    }
    final bit = _decodeSubValue(c, z);
    ctxs.values[index] = _nextCtx;
    return bit;
  }

  /// 不解码、不学习的变体（少数编码路径用）。
  int decodeNoLearn(ZpBitContext ctx) {
    final c = ctx.value;
    final z = (_a + _zpP[c]) & 0xFFFFFFFF;
    if (z <= _fence) {
      _a = z;
      return c & 1;
    }
    return _decodeSubNoLearn(c & 1, z);
  }

  /// pass-thru 解码：直接取一个比特，不走算术编码（规范里的 `decoder(void)`）。
  int decodeSimple() => _decodeSubSimple(0, 0x8000 + (_a >> 1));

  /// IW44 专用的"简单"解码（规范里的 `IWdecoder()`）。
  int decodeIw() => _decodeSubSimple(0, 0x8000 + ((_a + _a + _a) >> 3));

  int _decodeSub(ZpBitContext ctx, int z) {
    final r = _decodeSubValue(ctx.value, z);
    ctx.value = _nextCtx;
    return r;
  }

  // `_nextCtx` 是 `_decodeSubValue` 输出"新上下文状态"的传出通道
  int _nextCtx = 0;

  int _decodeSubValue(int c, int z) {
    final bit = c & 1;
    var zz = z;
    // 避免区间反转（ZPCODER 分支）
    final d = 0x6000 + ((zz + _a) >> 2);
    if (zz > d) zz = d;
    if (zz > _code) {
      // LPS 分支
      zz = 0x10000 - zz;
      _a = (_a + zz) & 0xFFFFFFFF;
      _code = (_code + zz) & 0xFFFFFFFF;
      _nextCtx = _zpDn[c];
      final shift = _ffz(_a);
      _scount -= shift;
      final mask = (1 << shift) - 1;
      _a = (_a << shift) & 0xFFFF;
      _code = ((_code << shift) & 0xFFFF) | ((_buffer >> _scount) & mask);
      if (_scount < 16) preload();
      _fence = _code >= 0x8000 ? 0x7fff : _code;
      return bit ^ 1;
    } else {
      _nextCtx = _a >= _zpM[c] ? _zpUp[c] : c;
      _scount -= 1;
      _a = (zz << 1) & 0xFFFF;
      _code = ((_code << 1) & 0xFFFF) | ((_buffer >> _scount) & 1);
      if (_scount < 16) preload();
      _fence = _code >= 0x8000 ? 0x7fff : _code;
      return bit;
    }
  }

  int _decodeSubNoLearn(int mps, int z) {
    var zz = z;
    final d = 0x6000 + ((zz + _a) >> 2);
    if (zz > d) zz = d;
    if (zz > _code) {
      zz = 0x10000 - zz;
      _a = (_a + zz) & 0xFFFFFFFF;
      _code = (_code + zz) & 0xFFFFFFFF;
      final shift = _ffz(_a);
      _scount -= shift;
      final mask = (1 << shift) - 1;
      _a = (_a << shift) & 0xFFFF;
      _code = ((_code << shift) & 0xFFFF) | ((_buffer >> _scount) & mask);
      if (_scount < 16) preload();
      _fence = _code >= 0x8000 ? 0x7fff : _code;
      return mps ^ 1;
    } else {
      _scount -= 1;
      _a = (zz << 1) & 0xFFFF;
      _code = ((_code << 1) & 0xFFFF) | ((_buffer >> _scount) & 1);
      if (_scount < 16) preload();
      _fence = _code >= 0x8000 ? 0x7fff : _code;
      return mps;
    }
  }

  int _decodeSubSimple(int mps, int z) {
    var zz = z;
    if (zz > _code) {
      zz = 0x10000 - zz;
      _a = (_a + zz) & 0xFFFFFFFF;
      _code = (_code + zz) & 0xFFFFFFFF;
      final shift = _ffz(_a);
      _scount -= shift;
      final mask = (1 << shift) - 1;
      _a = (_a << shift) & 0xFFFF;
      _code = ((_code << shift) & 0xFFFF) | ((_buffer >> _scount) & mask);
      if (_scount < 16) preload();
      _fence = _code >= 0x8000 ? 0x7fff : _code;
      return mps ^ 1;
    } else {
      _scount -= 1;
      _a = (zz << 1) & 0xFFFF;
      _code = ((_code << 1) & 0xFFFF) | ((_buffer >> _scount) & 1);
      if (_scount < 16) preload();
      _fence = _code >= 0x8000 ? 0x7fff : _code;
      return mps;
    }
  }

  void preload() {
    while (_scount <= 24) {
      int b;
      if (_ip < _data.length) {
        b = _data[_ip++];
      } else {
        b = 0xff;
        _delay -= 1;
        if (_delay < 1) {
          throw DjvuFormatException('ZP 位流在填充窗口内仍然结束（数据被截断）');
        }
      }
      _buffer = ((_buffer << 8) | b) & 0xFFFFFFFF;
      _scount += 8;
    }
  }

  /// 机器无关的 ffz（前导零计数，作用在 16 位值上）
  int _ffz(int x) => x >= 0xff00 ? _ffzt[x & 0xff] + 8 : _ffzt[(x >> 8) & 0xff];
}

// ---------------------------------------------------------------- 编码器

/// ZP 编码器。用法：`encode(ctx, bit)` … 最后必须调 [finish] 拿字节。
class ZpEncoder {
  int _a = 0;
  int _byte = 0;
  int _scount = 0;
  int _delay = 25;
  int _subend = 0;
  int _buffer = 0xffffff;
  int _nrun = 0;
  final BytesBuilder _out = BytesBuilder(copy: false);
  bool _finished = false;

  /// 常规编码（带自适应）。
  void encode(ZpBitContext ctx, int bit) {
    final z = (_a + _zpP[ctx.value]) & 0xFFFFFFFF;
    if (bit != (ctx.value & 1)) {
      _encodeLps(ctx, z);
    } else if (z >= 0x8000) {
      _encodeMps(ctx, z);
    } else {
      _a = z;
    }
  }

  void encodeAt(ZpContextArray ctxs, int index, int bit) {
    final ctx = ZpBitContext(ctxs.values[index]);
    encode(ctx, bit);
    ctxs.values[index] = ctx.value;
  }

  /// 不学习的编码变体。
  void encodeNoLearn(ZpBitContext ctx, int bit) {
    final c = ctx.value;
    final z = (_a + _zpP[c]) & 0xFFFFFFFF;
    if (bit != (c & 1)) {
      _encodeLpsNoLearn(z);
    } else if (z >= 0x8000) {
      _encodeMpsNoLearn(z);
    } else {
      _a = z;
    }
  }

  /// pass-thru 编码（规范里的 `encoder(int bit)`）。
  void encodeSimple(int bit) {
    if (bit != 0) {
      _encodeLpsSimple(0x8000 + (_a >> 1));
    } else {
      _encodeMpsSimple(0x8000 + (_a >> 1));
    }
  }

  /// IW44 专用简单编码。
  void encodeIw(int bit) {
    if (bit != 0) {
      _encodeLpsSimple(0x8000 + ((_a + _a + _a) >> 3));
    } else {
      _encodeMpsSimple(0x8000 + ((_a + _a + _a) >> 3));
    }
  }

  void _encodeMps(ZpBitContext ctx, int z) {
    var zz = z;
    final d = 0x6000 + ((zz + _a) >> 2);
    if (zz > d) zz = d;
    if (_a >= _zpM[ctx.value]) ctx.value = _zpUp[ctx.value];
    _a = zz;
    if (_a >= 0x8000) {
      _zemit(1 - (_subend >> 15));
      _subend = (_subend << 1) & 0xFFFF;
      _a = (_a << 1) & 0xFFFF;
    }
  }

  void _encodeLps(ZpBitContext ctx, int z) {
    var zz = z;
    final d = 0x6000 + ((zz + _a) >> 2);
    if (zz > d) zz = d;
    ctx.value = _zpDn[ctx.value];
    zz = 0x10000 - zz;
    _subend = (_subend + zz) & 0xFFFFFFFF;
    _a = (_a + zz) & 0xFFFFFFFF;
    while (_a >= 0x8000) {
      _zemit(1 - (_subend >> 15));
      _subend = (_subend << 1) & 0xFFFF;
      _a = (_a << 1) & 0xFFFF;
    }
  }

  void _encodeMpsSimple(int z) {
    _a = z;
    if (_a >= 0x8000) {
      _zemit(1 - (_subend >> 15));
      _subend = (_subend << 1) & 0xFFFF;
      _a = (_a << 1) & 0xFFFF;
    }
  }

  void _encodeLpsSimple(int z) {
    final zz = 0x10000 - z;
    _subend = (_subend + zz) & 0xFFFFFFFF;
    _a = (_a + zz) & 0xFFFFFFFF;
    while (_a >= 0x8000) {
      _zemit(1 - (_subend >> 15));
      _subend = (_subend << 1) & 0xFFFF;
      _a = (_a << 1) & 0xFFFF;
    }
  }

  void _encodeMpsNoLearn(int z) {
    var zz = z;
    final d = 0x6000 + ((zz + _a) >> 2);
    if (zz > d) zz = d;
    _a = zz;
    if (_a >= 0x8000) {
      _zemit(1 - (_subend >> 15));
      _subend = (_subend << 1) & 0xFFFF;
      _a = (_a << 1) & 0xFFFF;
    }
  }

  void _encodeLpsNoLearn(int z) {
    var zz = z;
    final d = 0x6000 + ((zz + _a) >> 2);
    if (zz > d) zz = d;
    zz = 0x10000 - zz;
    _subend = (_subend + zz) & 0xFFFFFFFF;
    _a = (_a + zz) & 0xFFFFFFFF;
    while (_a >= 0x8000) {
      _zemit(1 - (_subend >> 15));
      _subend = (_subend << 1) & 0xFFFF;
      _a = (_a << 1) & 0xFFFF;
    }
  }

  void _outbit(int bit) {
    if (_delay > 0) {
      if (_delay < 0xff) _delay -= 1;
    } else {
      _byte = ((_byte << 1) | (bit & 1)) & 0xFF;
      _scount += 1;
      if (_scount == 8) {
        _out.addByte(_byte);
        _scount = 0;
        _byte = 0;
      }
    }
  }

  void _zemit(int b) {
    _buffer = ((_buffer << 1) + (b & 0xFFFFFFFF)) & 0xFFFFFFFF;
    final top = (_buffer >> 24) & 0xFF;
    _buffer = _buffer & 0xffffff;
    switch (top) {
      case 1:
        _outbit(1);
        while (_nrun > 0) {
          _outbit(0);
          _nrun -= 1;
        }
        _nrun = 0;
      case 0xff:
        _outbit(0);
        while (_nrun > 0) {
          _outbit(1);
          _nrun -= 1;
        }
        _nrun = 0;
      case 0:
        _nrun += 1;
      default:
        throw DjvuFormatException('ZP 编码器内部错误：非法的 zemit 状态 $top');
    }
  }

  /// 收尾（规范里的 `eflush`），返回完整字节流。只能调用一次。
  Uint8List finish() {
    if (_finished) throw StateError('ZpEncoder.finish 只能调用一次');
    _finished = true;
    // 调整 subend
    if (_subend > 0x8000) {
      _subend = 0x10000;
    } else if (_subend > 0) {
      _subend = 0x8000;
    }
    while (_buffer != 0xffffff || _subend != 0) {
      _zemit(1 - (_subend >> 15));
      _subend = (_subend << 1) & 0xFFFF;
    }
    _outbit(1);
    while (_nrun > 0) {
      _outbit(0);
      _nrun -= 1;
    }
    _nrun = 0;
    while (_scount > 0) {
      _outbit(1);
    }
    _delay = 0xff;
    return _out.toBytes();
  }
}

// ---------------------------------------------------------------- 常量表

/// 机器无关的 ffz 表（`ffzt[i]` = i 的高位连续 1 的个数）
final Uint8List _ffzt = () {
  final t = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    var c = 0;
    var j = i;
    while ((j & 0x80) != 0) {
      c += 1;
      j = (j << 1) & 0x1FF;
    }
    t[i] = c;
  }
  return t;
}();

/// DjVu3 规范的 ZP 默认自适应表（256 项：p, m, up, dn）—— 纯常量事实。
///
/// 参考实现里 251..255 未显式初始化 → C++ 零初始化；这里补齐为 0 以对齐语义。
const List<List<int>> _zpTable = [
  [0x8000, 0, 84, 145], // 000
  [0x8000, 0, 3, 4], // 001
  [0x8000, 0, 4, 3], // 002
  [0x6bbd, 4261, 5, 1], // 003
  [0x6bbd, 4261, 6, 2], // 004
  [0x5d45, 7976, 7, 3], // 005
  [0x5d45, 7976, 8, 4], // 006
  [0x51b9, 11219, 9, 5], // 007
  [0x51b9, 11219, 10, 6], // 008
  [0x4813, 14051, 11, 7], // 009
  [0x4813, 14051, 12, 8], // 010
  [0x3fd5, 16524, 13, 9], // 011
  [0x3fd5, 16524, 14, 10], // 012
  [0x38b1, 18685, 15, 11], // 013
  [0x38b1, 18685, 16, 12], // 014
  [0x3275, 20573, 17, 13], // 015
  [0x3275, 20573, 18, 14], // 016
  [0x2cfd, 22224, 19, 15], // 017
  [0x2cfd, 22224, 20, 16], // 018
  [0x2825, 23665, 21, 17], // 019
  [0x2825, 23665, 22, 18], // 020
  [0x23ab, 24923, 23, 19], // 021
  [0x23ab, 24923, 24, 20], // 022
  [0x1f87, 26021, 25, 21], // 023
  [0x1f87, 26021, 26, 22], // 024
  [0x1bbb, 26978, 27, 23], // 025
  [0x1bbb, 26978, 28, 24], // 026
  [0x1845, 27810, 29, 25], // 027
  [0x1845, 27810, 30, 26], // 028
  [0x1523, 28532, 31, 27], // 029
  [0x1523, 28532, 32, 28], // 030
  [0x1253, 29158, 33, 29], // 031
  [0x1253, 29158, 34, 30], // 032
  [0x0fcf, 29700, 35, 31], // 033
  [0x0fcf, 29700, 36, 32], // 034
  [0x0d95, 30166, 37, 33], // 035
  [0x0d95, 30166, 38, 34], // 036
  [0x0b9d, 30568, 39, 35], // 037
  [0x0b9d, 30568, 40, 36], // 038
  [0x09e3, 30914, 41, 37], // 039
  [0x09e3, 30914, 42, 38], // 040
  [0x0861, 31210, 43, 39], // 041
  [0x0861, 31210, 44, 40], // 042
  [0x0711, 31463, 45, 41], // 043
  [0x0711, 31463, 46, 42], // 044
  [0x05f1, 31678, 47, 43], // 045
  [0x05f1, 31678, 48, 44], // 046
  [0x04f9, 31861, 49, 45], // 047
  [0x04f9, 31861, 50, 46], // 048
  [0x0425, 32015, 51, 47], // 049
  [0x0425, 32015, 52, 48], // 050
  [0x0371, 32145, 53, 49], // 051
  [0x0371, 32145, 54, 50], // 052
  [0x02d9, 32254, 55, 51], // 053
  [0x02d9, 32254, 56, 52], // 054
  [0x0259, 32346, 57, 53], // 055
  [0x0259, 32346, 58, 54], // 056
  [0x01ed, 32422, 59, 55], // 057
  [0x01ed, 32422, 60, 56], // 058
  [0x0193, 32486, 61, 57], // 059
  [0x0193, 32486, 62, 58], // 060
  [0x0149, 32538, 63, 59], // 061
  [0x0149, 32538, 64, 60], // 062
  [0x010b, 32581, 65, 61], // 063
  [0x010b, 32581, 66, 62], // 064
  [0x00d5, 32619, 67, 63], // 065
  [0x00d5, 32619, 68, 64], // 066
  [0x00a5, 32653, 69, 65], // 067
  [0x00a5, 32653, 70, 66], // 068
  [0x007b, 32682, 71, 67], // 069
  [0x007b, 32682, 72, 68], // 070
  [0x0057, 32707, 73, 69], // 071
  [0x0057, 32707, 74, 70], // 072
  [0x003b, 32727, 75, 71], // 073
  [0x003b, 32727, 76, 72], // 074
  [0x0023, 32743, 77, 73], // 075
  [0x0023, 32743, 78, 74], // 076
  [0x0013, 32754, 79, 75], // 077
  [0x0013, 32754, 80, 76], // 078
  [0x0007, 32762, 81, 77], // 079
  [0x0007, 32762, 82, 78], // 080
  [0x0001, 32767, 81, 79], // 081
  [0x0001, 32767, 82, 80], // 082
  [0x5695, 0, 9, 85], // 083
  [0x24ee, 0, 86, 226], // 084
  [0x8000, 0, 5, 6], // 085
  [0x0d30, 0, 88, 176], // 086
  [0x481a, 0, 89, 143], // 087
  [0x0481, 0, 90, 138], // 088
  [0x3579, 0, 91, 141], // 089
  [0x017a, 0, 92, 112], // 090
  [0x24ef, 0, 93, 135], // 091
  [0x007b, 0, 94, 104], // 092
  [0x1978, 0, 95, 133], // 093
  [0x0028, 0, 96, 100], // 094
  [0x10ca, 0, 97, 129], // 095
  [0x000d, 0, 82, 98], // 096
  [0x0b5d, 0, 99, 127], // 097
  [0x0034, 0, 76, 72], // 098
  [0x078a, 0, 101, 125], // 099
  [0x00a0, 0, 70, 102], // 100
  [0x050f, 0, 103, 123], // 101
  [0x0117, 0, 66, 60], // 102
  [0x0358, 0, 105, 121], // 103
  [0x01ea, 0, 106, 110], // 104
  [0x0234, 0, 107, 119], // 105
  [0x0144, 0, 66, 108], // 106
  [0x0173, 0, 109, 117], // 107
  [0x0234, 0, 60, 54], // 108
  [0x00f5, 0, 111, 115], // 109
  [0x0353, 0, 56, 48], // 110
  [0x00a1, 0, 69, 113], // 111
  [0x05c5, 0, 114, 134], // 112
  [0x011a, 0, 65, 59], // 113
  [0x03cf, 0, 116, 132], // 114
  [0x01aa, 0, 61, 55], // 115
  [0x0285, 0, 118, 130], // 116
  [0x0286, 0, 57, 51], // 117
  [0x01ab, 0, 120, 128], // 118
  [0x03d3, 0, 53, 47], // 119
  [0x011a, 0, 122, 126], // 120
  [0x05c5, 0, 49, 41], // 121
  [0x00ba, 0, 124, 62], // 122
  [0x08ad, 0, 43, 37], // 123
  [0x007a, 0, 72, 66], // 124
  [0x0ccc, 0, 39, 31], // 125
  [0x01eb, 0, 60, 54], // 126
  [0x1302, 0, 33, 25], // 127
  [0x02e6, 0, 56, 50], // 128
  [0x1b81, 0, 29, 131], // 129
  [0x045e, 0, 52, 46], // 130
  [0x24ef, 0, 23, 17], // 131
  [0x0690, 0, 48, 40], // 132
  [0x2865, 0, 23, 15], // 133
  [0x09de, 0, 42, 136], // 134
  [0x3987, 0, 137, 7], // 135
  [0x0dc8, 0, 38, 32], // 136
  [0x2c99, 0, 21, 139], // 137
  [0x10ca, 0, 140, 172], // 138
  [0x3b5f, 0, 15, 9], // 139
  [0x0b5d, 0, 142, 170], // 140
  [0x5695, 0, 9, 85], // 141
  [0x078a, 0, 144, 168], // 142
  [0x8000, 0, 141, 248], // 143
  [0x050f, 0, 146, 166], // 144
  [0x24ee, 0, 147, 247], // 145
  [0x0358, 0, 148, 164], // 146
  [0x0d30, 0, 149, 197], // 147
  [0x0234, 0, 150, 162], // 148
  [0x0481, 0, 151, 95], // 149
  [0x0173, 0, 152, 160], // 150
  [0x017a, 0, 153, 173], // 151
  [0x00f5, 0, 154, 158], // 152
  [0x007b, 0, 155, 165], // 153
  [0x00a1, 0, 70, 156], // 154
  [0x0028, 0, 157, 161], // 155
  [0x011a, 0, 66, 60], // 156
  [0x000d, 0, 81, 159], // 157
  [0x01aa, 0, 62, 56], // 158
  [0x0034, 0, 75, 71], // 159
  [0x0286, 0, 58, 52], // 160
  [0x00a0, 0, 69, 163], // 161
  [0x03d3, 0, 54, 48], // 162
  [0x0117, 0, 65, 59], // 163
  [0x05c5, 0, 50, 42], // 164
  [0x01ea, 0, 167, 171], // 165
  [0x08ad, 0, 44, 38], // 166
  [0x0144, 0, 65, 169], // 167
  [0x0ccc, 0, 40, 32], // 168
  [0x0234, 0, 59, 53], // 169
  [0x1302, 0, 34, 26], // 170
  [0x0353, 0, 55, 47], // 171
  [0x1b81, 0, 30, 174], // 172
  [0x05c5, 0, 175, 193], // 173
  [0x24ef, 0, 24, 18], // 174
  [0x03cf, 0, 177, 191], // 175
  [0x2b74, 0, 178, 222], // 176
  [0x0285, 0, 179, 189], // 177
  [0x201d, 0, 180, 218], // 178
  [0x01ab, 0, 181, 187], // 179
  [0x1715, 0, 182, 216], // 180
  [0x011a, 0, 183, 185], // 181
  [0x0fb7, 0, 184, 214], // 182
  [0x00ba, 0, 69, 61], // 183
  [0x0a67, 0, 186, 212], // 184
  [0x01eb, 0, 59, 53], // 185
  [0x06e7, 0, 188, 210], // 186
  [0x02e6, 0, 55, 49], // 187
  [0x0496, 0, 190, 208], // 188
  [0x045e, 0, 51, 45], // 189
  [0x030d, 0, 192, 206], // 190
  [0x0690, 0, 47, 39], // 191
  [0x0206, 0, 194, 204], // 192
  [0x09de, 0, 41, 195], // 193
  [0x0155, 0, 196, 202], // 194
  [0x0dc8, 0, 37, 31], // 195
  [0x00e1, 0, 198, 200], // 196
  [0x2b74, 0, 199, 243], // 197
  [0x0094, 0, 72, 64], // 198
  [0x201d, 0, 201, 239], // 199
  [0x0188, 0, 62, 56], // 200
  [0x1715, 0, 203, 237], // 201
  [0x0252, 0, 58, 52], // 202
  [0x0fb7, 0, 205, 235], // 203
  [0x0383, 0, 54, 48], // 204
  [0x0a67, 0, 207, 233], // 205
  [0x0547, 0, 50, 44], // 206
  [0x06e7, 0, 209, 231], // 207
  [0x07e2, 0, 46, 38], // 208
  [0x0496, 0, 211, 229], // 209
  [0x0bc0, 0, 40, 34], // 210
  [0x030d, 0, 213, 227], // 211
  [0x1178, 0, 36, 28], // 212
  [0x0206, 0, 215, 225], // 213
  [0x19da, 0, 30, 22], // 214
  [0x0155, 0, 217, 223], // 215
  [0x24ef, 0, 26, 16], // 216
  [0x00e1, 0, 219, 221], // 217
  [0x320e, 0, 20, 220], // 218
  [0x0094, 0, 71, 63], // 219
  [0x432a, 0, 14, 8], // 220
  [0x0188, 0, 61, 55], // 221
  [0x447d, 0, 14, 224], // 222
  [0x0252, 0, 57, 51], // 223
  [0x5ece, 0, 8, 2], // 224
  [0x0383, 0, 53, 47], // 225
  [0x8000, 0, 228, 87], // 226
  [0x0547, 0, 49, 43], // 227
  [0x481a, 0, 230, 246], // 228
  [0x07e2, 0, 45, 37], // 229
  [0x3579, 0, 232, 244], // 230
  [0x0bc0, 0, 39, 33], // 231
  [0x24ef, 0, 234, 238], // 232
  [0x1178, 0, 35, 27], // 233
  [0x1978, 0, 138, 236], // 234
  [0x19da, 0, 29, 21], // 235
  [0x2865, 0, 24, 16], // 236
  [0x24ef, 0, 25, 15], // 237
  [0x3987, 0, 240, 8], // 238
  [0x320e, 0, 19, 241], // 239
  [0x2c99, 0, 22, 242], // 240
  [0x432a, 0, 13, 7], // 241
  [0x3b5f, 0, 16, 10], // 242
  [0x447d, 0, 13, 245], // 243
  [0x5695, 0, 10, 2], // 244
  [0x5ece, 0, 7, 1], // 245
  [0x8000, 0, 244, 83], // 246
  [0x8000, 0, 249, 250], // 247
  [0x5695, 0, 10, 2], // 248
  [0x481a, 0, 89, 143], // 249
  [0x481a, 0, 230, 246], // 250
  [0x0000, 0, 0, 0], // 251
  [0x0000, 0, 0, 0], // 252
  [0x0000, 0, 0, 0], // 253
  [0x0000, 0, 0, 0], // 254
  [0x0000, 0, 0, 0], // 255
];

final Uint16List _zpP = Uint16List.fromList([for (final e in _zpTable) e[0]]);
final Uint16List _zpM = Uint16List.fromList([for (final e in _zpTable) e[1]]);
final Uint8List _zpUp = Uint8List.fromList([for (final e in _zpTable) e[2]]);
final Uint8List _zpDn = Uint8List.fromList([for (final e in _zpTable) e[3]]);
