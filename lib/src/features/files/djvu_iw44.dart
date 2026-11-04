// DJVU 的 **IW44 小波（wavelet）解码器** —— 纯 Dart，零 flutter / l10n 依赖。
//
// ============================ 诚实声明 ============================
// **IW44 解码器已实现，但缺真实/自造样本，未端到端验证。**
//
// 本仓库既没有真实 DJVU 样本，也没有 IW44 编码器（本项目只自研解码方向）。
// `tool/make_djvu_fixture.dart` 只造**头合法、零系数**的 BG44/TH44 —— 那能证明
// "分块 → 头解析 → 像素缓冲 → PNG"的管线通了，**证明不了系数解码/反向小波**。
// 因此本文件只做了：
//   * 静态分析通过（`flutter analyze` 无 issue）；
//   * 对"垃圾 / 空 / 截断"输入的异常行为自检（`tool/djvu_iw44_selftest.dart`）；
// 而**没有**做「用 DjVuLibre `c44` 编码 → 本解码器还原像素」的端到端比对。
// 尤其反向小波与 YCbCr 逆变换虽然按公开算法事实逐句重写，但未经真实码流校核。
// ================================================================
//
// 为什么要自研：DjVuLibre 是 **GPL-2.0**，对闭源 App 是法务阻塞。这里按公开的
// DjVu3 格式规范 + IW44 算法事实独立重写；参考实现（DjVuLibre `IW44Image.cpp` /
// `IW44Image.h`，GPL-2.0）**仅作算法事实核对**，没有其代码/注释的拷贝。
//
// 实现结构（对应参考实现的 `IW44Image` / `Codec::Decode` / `Map` / `Transform`）：
//   1. chunk 头：primary(serial, slices) + 首块 secondary(major, minor) +
//      tertiary(xhi,xlo,yhi,ylo[,crcbdelay])；
//   2. 每个 chunk 独立一个 ZP 算术解码器（`djvu_zp.dart` 的 `ZpDecoder`），
//      逐 slice 解 10 个频带的系数（Huffman-ish 的 bucket 层次编码）；
//   3. 系数填回 32x32 liftblock，按 zigzagloc 展开成 bw x bh 的系数矩阵；
//   4. 反向小波（`backward` → `filter_bv` / `filter_bh`）重建；
//   5. 取样 + 直流偏移（灰度 +128 / 彩色 YCbCr→RGB Pigeon 逆变换）。
//
// 已知不确定点都用 `// 存疑：...` 标出。
//
// 公开 API：
//   * [DjvuIw44Pixels]：解码结果（行主序、0..255）。
//   * [djvuIw44Decode]：progressive 解码一串 BG44/FG44/TH44 payload。
import 'dart:typed_data';

import 'djvu_errors.dart';
import 'djvu_zp.dart';

/// IW44 解码后的整幅像素。
class DjvuIw44Pixels {
  DjvuIw44Pixels(this.width, this.height, this.channels, this.data);

  final int width;
  final int height;

  /// 1 = 灰度，3 = RGB。
  final int channels;

  /// `width*height*channels`，行主序，取值 0..255。
  final Uint8List data;
}

/// 本实现的内存上限（像素数）。超过就报"不支持"，避免畸形头导致超大分配。
const int _maxIw44Pixels = 40000000; // 4000 万像素，够 300dpi 的 A3 扫描页

/// 解码一串 IW44 数据（同一页的 BG44 / FG44 / TH44 payload，按出现顺序）。
///
/// * [chunks]：每个元素是**去掉 IFF chunk id / 长度**之后的 IW44 字节流
///   （即 DjVuLibre `decode_chunk` 收到的 ByteStream），可以与文件的
///   progressive chunk 一一对应；解一个前缀会得到更粗但依然合法的图像。
/// * [width] / [height]：当 IW44 头里尺寸为 0（或不可信）时由 INFO 提供。
///   只要 > 0 就覆盖头里的尺寸。
///
/// 失败语义：
///   * [DjvuUnsupportedException]：版本/尺寸等本实现做不到的变体；
///   * [DjvuFormatException]：空输入、序号断裂、头被截断、位流截断等。
///
/// **绝不返回半截乱码**：任何 mid-chunk 错误都会抛出，而不是退回部分像素。
DjvuIw44Pixels djvuIw44Decode(
  List<Uint8List> chunks, {
  int width = 0,
  int height = 0,
}) {
  if (chunks.isEmpty) {
    throw DjvuFormatException('IW44：chunks 为空，没有任何可解码的数据');
  }
  final session = _Iw44Session(width, height);
  for (final chunk in chunks) {
    // 存疑：真实文件里 IW44 payload 就是 chunk 内容；若上层误传了带 IFF
    // "FORM:PM44"/"PM44" 外壳的整段，这里不会识别，会当作坏数据。
    if (chunk.isEmpty) {
      throw DjvuFormatException('IW44：遇到空 chunk');
    }
    session.decodeChunk(chunk);
  }
  return session.finish();
}

// ------------------------------------------------------------------ 会话

/// 一次解码的全部可变状态（跨多个 progressive chunk 保留）。
///
/// 对应参考实现里"打开一个 codec，连续 decode_chunk"的生命周期。
class _Iw44Session {
  _Iw44Session(this._overrideWidth, this._overrideHeight);

  final int _overrideWidth;
  final int _overrideHeight;

  int _width = 0;
  int _height = 0;
  bool _color = false;
  int _crcbDelay = -1;
  int _crcbHalf = 0;
  bool _started = false;

  _IwMap? _y;
  _IwMap? _cb;
  _IwMap? _cr;
  _IwCodec? _yc;
  _IwCodec? _cbc;
  _IwCodec? _crc;

  int _cserial = 0; // 期望的下一个 primary.serial
  int _cslice = 0; // 已经解过的 slice 总数

  /// 解一个 chunk。抛出的异常见 [djvuIw44Decode] 的说明。
  void decodeChunk(Uint8List chunk) {
    if (chunk.length < 2) {
      throw DjvuFormatException('IW44 chunk 头不足 2 字节（primary header）');
    }
    final serial = chunk[0];
    final slices = chunk[1];
    if (serial != _cserial) {
      // 参考实现：serial 不连续直接 G_THROW(wrong_serial)。
      throw DjvuFormatException('IW44 chunk 序号不连续：期望 $_cserial，实际 $serial');
    }
    final int offset = _started ? 2 : _readFirstHeader(chunk);
    final nslices = _cslice + slices;
    // 每个 chunk 独立算术编码：ZP 位流从 header 之后开始。
    final zp = ZpDecoder(Uint8List.sublistView(chunk, offset));
    final yc = _yc!;
    var flag = 1;
    // nslices <= 255*chunks，循环次数有界；flag==0 表示所有量化阈值已归零。
    while (flag != 0 && _cslice < nslices) {
      flag = yc.codeSlice(zp);
      final cbc = _cbc;
      final crc = _crc;
      if (cbc != null && crc != null && _crcbDelay <= _cslice) {
        flag |= cbc.codeSlice(zp);
        flag |= crc.codeSlice(zp);
      }
      _cslice++;
    }
    _cserial++;
  }

  /// 读首个 chunk 的 secondary/tertiary 头并建图；返回 header 总字节数。
  int _readFirstHeader(Uint8List chunk) {
    if (chunk.length < 4) {
      throw DjvuFormatException('IW44 首个 chunk 头不足 4 字节（secondary header）');
    }
    final major = chunk[2];
    final minor = chunk[3];
    final majorVer = major & 0x7f;
    if (majorVer != 1) {
      throw DjvuUnsupportedException('IW44 主版本 $majorVer（本实现只支持 1）');
    }
    if (minor > 2) {
      throw DjvuUnsupportedException('IW44 次版本 $minor（本实现只支持 1 / 2）');
    }
    final need = minor >= 2 ? 5 : 4;
    if (chunk.length < 4 + need) {
      throw DjvuFormatException('IW44 tertiary header 被截断');
    }
    final headerW = (chunk[4] << 8) | chunk[5];
    final headerH = (chunk[6] << 8) | chunk[7];
    final w = _overrideWidth > 0 ? _overrideWidth : headerW;
    final h = _overrideHeight > 0 ? _overrideHeight : headerH;
    if (w <= 0 || h <= 0) {
      throw DjvuFormatException(
        'IW44 尺寸无效：头里 ${headerW}x$headerH，覆盖值 '
        '${_overrideWidth}x$_overrideHeight',
      );
    }
    if (w > 65535 || h > 65535 || w * h > _maxIw44Pixels) {
      throw DjvuUnsupportedException('IW44 图像尺寸 $w x $h 超出本实现上限');
    }
    var crcbdelay = 0;
    if (minor >= 2) crcbdelay = chunk[8];

    _width = w;
    _height = h;
    // major 的最高位 = 1 表示灰度（BM44 编码器写 IWCODEC_MAJOR+0x80；
    // PM44 编码器写 IWCODEC_MAJOR）。参考实现的 IWBitmap 正是要求该位为 1。
    final gray = (major & 0x80) != 0;
    _color = !gray;
    if (gray) {
      _crcbDelay = -1;
      _crcbHalf = 0;
    } else {
      _crcbDelay = minor >= 2 ? (crcbdelay & 0x7f) : 0;
      _crcbHalf = minor >= 2 ? ((crcbdelay & 0x80) != 0 ? 0 : 1) : 0;
    }
    _y = _IwMap(w, h);
    _yc = _IwCodec(_y!);
    if (_color) {
      _cb = _IwMap(w, h);
      _cr = _IwMap(w, h);
      _cbc = _IwCodec(_cb!);
      _crc = _IwCodec(_cr!);
    }
    _started = true;
    return 4 + need;
  }

  /// 全部 chunk 解完后做反向小波并输出像素。
  DjvuIw44Pixels finish() {
    if (!_started) {
      throw DjvuFormatException('IW44：没有可解码的头信息');
    }
    final w = _width;
    final h = _height;
    if (_color) {
      final out = Uint8List(w * h * 3);
      final y = Int8List(w * h);
      final cb = Int8List(w * h);
      final cr = Int8List(w * h);
      _y!.reconstructTo(y, 1, false);
      // 存疑：chroma 的 fast(=crcb_half) 与 get_pixmap 一致；
      // minor<2 的旧流 crcb_half 恒为 0。
      _cb!.reconstructTo(cb, 1, _crcbHalf != 0);
      _cr!.reconstructTo(cr, 1, _crcbHalf != 0);
      _flipRows(y, w, h);
      _flipRows(cb, w, h);
      _flipRows(cr, w, h);
      final n = w * h;
      for (var i = 0; i < n; i++) {
        final yy = y[i];
        final bb = cb[i];
        final rr = cr[i];
        // Pigeon 逆变换（参考实现 Transform::Decode::YCbCr_to_RGB）。
        final t1 = bb >> 2;
        final t2 = rr + (rr >> 1);
        final t3 = yy + 128 - t1;
        out[i * 3] = _clamp8(yy + 128 + t2);
        out[i * 3 + 1] = _clamp8(t3 - (t2 >> 1));
        out[i * 3 + 2] = _clamp8(t3 + (bb << 1));
      }
      return DjvuIw44Pixels(w, h, 3, out);
    }
    final out = Uint8List(w * h * 3);
    final y = Int8List(w * h);
    _y!.reconstructTo(y, 1, false);
    // **灰度（major 置 0x80）**：DjVuFile 对 BG44/FG44/TH44/BM44/PM44 一律用
    // `IW44Image::create_decode(COLOR)`（即 IWPixmap），灰度流只是令
    // `crcb_delay = -1`、不建 chroma 两个 map。输出走的是
    // `IWPixmap::get_pixmap` 的 else 分支：
    //     r = g = b = 127 - (signed char)s
    // **不是** GBitmap 路径的 `s + 128`（那条只在 `create_decode(GRAY)`/IWBitmap
    // 里用，DjVuFile 不会走）。这里 s = clamp((v+32)>>6) 已由 reconstructTo 给出。
    final n = w * h;
    _flipRows(y, w, h);
    for (var i = 0; i < n; i++) {
      final v = _clamp8(127 - y[i]);
      out[i * 3] = v;
      out[i * 3 + 1] = v;
      out[i * 3 + 2] = v;
    }
    return DjvuIw44Pixels(w, h, 3, out);
  }
}

int _clamp8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// 行序翻转为**自上而下**。
///
/// DjVuLibre 的 `IW44Image::Map::image` 把重建结果按第 0 行起写进目标缓冲，
/// 而渲染管线（`ddjvu` / `DjVuImage::get_pixmap`）取像素时再翻一次，最终
/// 屏上是自上而下的。这里直接在解码出口翻正，使 [DjvuIw44Pixels] 恒为
/// 自上而下的行序（PNG / 位图约定）。
void _flipRows(Int8List buf, int w, int h) {
  for (var y = 0; y < h >> 1; y++) {
    final a = y * w;
    final b = (h - 1 - y) * w;
    for (var x = 0; x < w; x++) {
      final t = buf[a + x];
      buf[a + x] = buf[b + x];
      buf[b + x] = t;
    }
  }
}

// ------------------------------------------------------------------ 系数地图

/// 一帧小波系数（对应参考实现的 `IW44Image::Map`）。
///
/// 图像按 32x32 分块，每块最多 64 个 bucket，每个 bucket 16 个 short 系数。
/// bucket 惰性分配：全零的 bucket 为 null（对应参考实现的稀疏 Alloc）。
class _IwMap {
  _IwMap(this.iw, this.ih) : bw = (iw + 31) & ~31, bh = (ih + 31) & ~31 {
    nb = (bw * bh) >> 10; // /1024
    buckets = List<Int16List?>.filled(nb * 64, null);
  }

  final int iw;
  final int ih;
  final int bw; // 32 对齐后的宽
  final int bh; // 32 对齐后的高
  late final int nb; // 块数
  late final List<Int16List?> buckets; // nb*64 个 bucket

  Int16List? bucketOf(int blockno, int n) => buckets[blockno * 64 + n];

  Int16List obtain(int blockno, int n) {
    final i = blockno * 64 + n;
    var b = buckets[i];
    if (b == null) {
      b = Int16List(16);
      buckets[i] = b;
    }
    return b;
  }

  /// 把某个 block 的 64 个 bucket 按 zigzagloc 展开到 [coeff]，
  /// 从 [dstBase] 开始，按宽 [bw] 行主序写入（对应 `write_liftblock` +
  /// `Map::image` 里的 memcpy）。
  void _writeLiftBlock(int blockno, Int16List coeff, int dstBase) {
    var n = 0;
    final base = blockno * 64;
    for (var n1 = 0; n1 < 64; n1++) {
      final d = buckets[base + n1];
      if (d == null) {
        n += 16;
        continue;
      }
      for (var n2 = 0; n2 < 16; n2++, n++) {
        final m = _zigzagloc[n];
        coeff[dstBase + (m >> 5) * bw + (m & 31)] = d[n2];
      }
    }
  }

  /// 反向小波 + 取样，输出有符号字节（对应 `Map::image`）。
  ///
  /// [pixStride] 是相邻像素在 [dest] 中的步长（灰度 1，彩色 3）。
  /// [fast] 为 true 时只重建到 scale=2 再 2x2 复制（用于 Cb/Cr）。
  void reconstructTo(Int8List dest, int pixStride, bool fast) {
    final data16 = Int16List(bw * bh);
    var blockno = 0;
    for (var i = 0; i < bh; i += 32) {
      for (var j = 0; j < bw; j += 32) {
        _writeLiftBlock(blockno, data16, i * bw + j);
        blockno++;
      }
    }
    _backward(data16, iw, ih, bw, 32, fast ? 2 : 1);
    if (fast) {
      // Map::image 的 fast 分支：2x2 复制。注意它遍历的是 32 对齐的 bh。
      var pp = 0;
      for (var i = 0; i < bh; i += 2, pp += bw) {
        for (var jj = 0; jj < bw; jj += 2, pp += 2) {
          final v = data16[pp];
          data16[pp + bw] = v;
          data16[pp + bw + 1] = v;
          data16[pp + 1] = v;
        }
      }
    }
    var idx = 0;
    var src = 0;
    for (var i = 0; i < ih; i++) {
      for (var j = 0; j < iw; j++) {
        var x = (data16[src + j] + 32) >> 6; // iw_round=32, iw_shift=6
        if (x < -128) {
          x = -128;
        } else if (x > 127) {
          x = 127;
        }
        dest[idx] = x;
        idx += pixStride;
      }
      src += bw;
    }
  }
}

// ------------------------------------------------------------------ 系数解码

/// 一个 Y / Cb / Cr 的 IW44 系数解码器（对应 `IW44Image::Codec::Decode`）。
class _IwCodec {
  _IwCodec(this.map) {
    // 量化表 = 参考实现 iw_quant 经 Codec 构造展开而来。
    quantLo[0] = 0x4000;
    quantLo[1] = 0x8000;
    quantLo[2] = 0x8000;
    quantLo[3] = 0x10000;
    for (var i = 4; i < 12; i++) {
      quantLo[i] = 0x10000;
    }
    for (var i = 12; i < 16; i++) {
      quantLo[i] = 0x20000;
    }
    quantHi[0] = 0;
    quantHi[1] = 0x20000;
    quantHi[2] = 0x20000;
    quantHi[3] = 0x40000;
    quantHi[4] = 0x40000;
    quantHi[5] = 0x40000;
    quantHi[6] = 0x80000;
    quantHi[7] = 0x40000;
    quantHi[8] = 0x40000;
    quantHi[9] = 0x80000;
  }

  static const int _zero = 1;
  static const int _active = 2;
  static const int _new = 4;
  static const int _unk = 8;

  // bandbuckets[]：每个频带的起始 bucket 与 bucket 数。
  static const List<int> _bandStart = [0, 1, 2, 3, 4, 8, 12, 16, 32, 48];
  static const List<int> _bandSize = [1, 1, 1, 1, 4, 4, 4, 16, 16, 16];

  final _IwMap map;

  int curband = 0;
  int curbit = 1;

  final Int32List quantHi = Int32List(10);
  final Int32List quantLo = Int32List(16);
  final Int32List coeffstate = Int32List(256);
  final Int32List bucketstate = Int32List(16);
  final ZpContextArray ctxStart = ZpContextArray(32);
  final List<ZpContextArray> ctxBucket = List<ZpContextArray>.generate(
    10,
    (_) => ZpContextArray(8),
  );
  final ZpBitContext ctxMant = ZpBitContext();
  final ZpBitContext ctxRoot = ZpBitContext();

  /// 解一个 slice；返回 0 表示所有量化阈值已归零（没有更多数据）。
  int codeSlice(ZpDecoder zp) {
    if (curbit < 0) return 0;
    if (!_isNullSlice(curband)) {
      final fbucket = _bandStart[curband];
      final nbucket = _bandSize[curband];
      final nb = map.nb;
      for (var blockno = 0; blockno < nb; blockno++) {
        _decodeBuckets(zp, curband, blockno, fbucket, nbucket);
      }
    }
    return _finishCodeSlice();
  }

  /// 对应 `is_null_slice`：顺手填 band 0 的 coeffstate。
  bool _isNullSlice(int band) {
    if (band == 0) {
      var isNull = true;
      for (var i = 0; i < 16; i++) {
        final threshold = quantLo[i];
        coeffstate[i] = _zero;
        if (threshold > 0 && threshold < 0x8000) {
          coeffstate[i] = _unk;
          isNull = false;
        }
      }
      return isNull;
    }
    final threshold = quantHi[band];
    return !(threshold > 0 && threshold < 0x8000);
  }

  /// 对应 `finish_code_slice`：阈值减半、推进 band/bitplane。
  int _finishCodeSlice() {
    quantHi[curband] = quantHi[curband] >> 1;
    if (curband == 0) {
      for (var i = 0; i < 16; i++) {
        quantLo[i] = quantLo[i] >> 1;
      }
    }
    curband++;
    if (curband >= 10) {
      curband = 0;
      curbit++;
      if (quantHi[9] == 0) {
        curbit = -1;
        return 0;
      }
    }
    return 1;
  }

  /// 对应 `decode_prepare`：算出该频带各 bucket / 整块的 ZERO/ACTIVE/UNK 状态。
  int _decodePrepare(int fbucket, int nbucket, int blockno) {
    var bbstate = 0;
    if (fbucket != 0) {
      var cbase = 0;
      for (var buckno = 0; buckno < nbucket; buckno++, cbase += 16) {
        var bstatetmp = 0;
        final pcoeff = map.bucketOf(blockno, fbucket + buckno);
        if (pcoeff == null) {
          // coeffstate 稍后在分配时再填。
          bstatetmp = _unk;
        } else {
          for (var i = 0; i < 16; i++) {
            final cstatetmp = pcoeff[i] != 0 ? _active : _unk;
            coeffstate[cbase + i] = cstatetmp;
            bstatetmp |= cstatetmp;
          }
        }
        bucketstate[buckno] = bstatetmp;
        bbstate |= bstatetmp;
      }
    } else {
      // band 0：fbucket==0 意味着 nbucket==1。
      final pcoeff = map.bucketOf(blockno, 0);
      if (pcoeff == null) {
        bbstate = _unk;
      } else {
        for (var i = 0; i < 16; i++) {
          var cstatetmp = coeffstate[i];
          if (cstatetmp != _zero) {
            cstatetmp = _unk;
            if (pcoeff[i] != 0) cstatetmp = _active;
          }
          coeffstate[i] = cstatetmp;
          bbstate |= cstatetmp;
        }
      }
      bucketstate[0] = bbstate;
    }
    return bbstate;
  }

  /// 对应 `decode_buckets`：解一个 block 在某频带的全部 bucket。
  void _decodeBuckets(
    ZpDecoder zp,
    int band,
    int blockno,
    int fbucket,
    int nbucket,
  ) {
    var bbstate = _decodePrepare(fbucket, nbucket, blockno);

    // root bit：只有 nbucket==16（细频带）且整块全 UNK 时才编码。
    if (nbucket < 16 || (bbstate & _active) != 0) {
      bbstate |= _new;
    } else if ((bbstate & _unk) != 0) {
      if (zp.decode(ctxRoot) != 0) bbstate |= _new;
    }

    // bucket bits
    if ((bbstate & _new) != 0) {
      for (var buckno = 0; buckno < nbucket; buckno++) {
        if ((bucketstate[buckno] & _unk) != 0) {
          var ctx = 0;
          if (band > 0) {
            // 参考实现用"父 bucket"（bucket 序号 >>2，偏移 (序号&3)*4）当上下文。
            final k = (fbucket + buckno) << 2;
            final b = map.bucketOf(blockno, k >> 4);
            if (b != null) {
              final off = k & 0xf;
              if (b[off] != 0) ctx += 1;
              if (b[off + 1] != 0) ctx += 1;
              if (b[off + 2] != 0) ctx += 1;
              if (ctx < 3 && b[off + 3] != 0) ctx += 1;
            }
          }
          if ((bbstate & _active) != 0) ctx |= 4;
          if (zp.decodeAt(ctxBucket[band], ctx) != 0) {
            bucketstate[buckno] |= _new;
          }
        }
      }
    }

    // 新激活系数（含符号）
    if ((bbstate & _new) != 0) {
      var thres = quantHi[band];
      var cbase = 0;
      for (var buckno = 0; buckno < nbucket; buckno++, cbase += 16) {
        if ((bucketstate[buckno] & _new) == 0) continue;
        final existing = map.bucketOf(blockno, fbucket + buckno);
        final Int16List pcoeff;
        if (existing != null) {
          pcoeff = existing;
        } else {
          pcoeff = map.obtain(blockno, fbucket + buckno);
          if (fbucket == 0) {
            for (var i = 0; i < 16; i++) {
              if (coeffstate[i] != _zero) coeffstate[i] = _unk;
            }
          } else {
            for (var i = 0; i < 16; i++) {
              coeffstate[cbase + i] = _unk;
            }
          }
        }
        var gotcha = 0;
        const maxgotcha = 7;
        for (var i = 0; i < 16; i++) {
          if ((coeffstate[cbase + i] & _unk) != 0) gotcha += 1;
        }
        for (var i = 0; i < 16; i++) {
          if ((coeffstate[cbase + i] & _unk) == 0) continue;
          if (band == 0) thres = quantLo[i];
          var ctx = gotcha >= maxgotcha ? maxgotcha : gotcha;
          if ((bucketstate[buckno] & _active) != 0) ctx |= 8;
          if (zp.decodeAt(ctxStart, ctx) != 0) {
            coeffstate[cbase + i] |= _new;
            final halfthres = thres >> 1;
            final coeff = thres + halfthres - (halfthres >> 2);
            pcoeff[i] = zp.decodeIw() != 0 ? -coeff : coeff;
          }
          if ((coeffstate[cbase + i] & _new) != 0) {
            gotcha = 0;
          } else if (gotcha > 0) {
            gotcha -= 1;
          }
        }
      }
    }

    // mantissa bits
    if ((bbstate & _active) != 0) {
      var thres = quantHi[band];
      var cbase = 0;
      for (var buckno = 0; buckno < nbucket; buckno++, cbase += 16) {
        if ((bucketstate[buckno] & _active) == 0) continue;
        final pcoeff = map.obtain(blockno, fbucket + buckno);
        for (var i = 0; i < 16; i++) {
          if ((coeffstate[cbase + i] & _active) == 0) continue;
          final orig = pcoeff[i];
          var coeff = orig < 0 ? -orig : orig;
          if (band == 0) thres = quantLo[i];
          if (coeff <= 3 * thres) {
            // 第二个 mantissa bit
            coeff = coeff + (thres >> 2);
            if (zp.decode(ctxMant) != 0) {
              coeff = coeff + (thres >> 1);
            } else {
              coeff = coeff - thres + (thres >> 1);
            }
          } else {
            if (zp.decodeIw() != 0) {
              coeff = coeff + (thres >> 1);
            } else {
              coeff = coeff - thres + (thres >> 1);
            }
          }
          pcoeff[i] = orig > 0 ? coeff : -coeff;
        }
      }
    }
  }
}

// ------------------------------------------------------------------ 反向小波

/// 对应 `Transform::Decode::backward`：[begin] 起、[end] 止的双正交小波逆变换。
void _backward(Int16List p, int w, int h, int rowsize, int begin, int end) {
  for (var scale = begin >> 1; scale >= end; scale >>= 1) {
    _filterBv(p, w, h, rowsize, scale);
    _filterBh(p, w, h, rowsize, scale);
  }
}

/// 对应 `filter_bv`：竖直方向的 lifting + interpolation。
void _filterBv(Int16List p, int w, int h, int rowsize, int scale) {
  var y = 0;
  final s = scale * rowsize;
  final s3 = s + s + s;
  h = ((h - 1) ~/ scale) + 1;
  var base = 0;
  while (y - 3 < h) {
    // 1-Lifting
    {
      var q = base;
      final e = q + w;
      if (y >= 3 && y + 3 < h) {
        while (q < e) {
          final a = p[q - s] + p[q + s];
          final b = p[q - s3] + p[q + s3];
          p[q] = p[q] - (((a << 3) + a - b + 16) >> 5);
          q += scale;
        }
      } else if (y < h) {
        var q1 = y + 1 < h ? q + s : -1;
        var q3 = y + 3 < h ? q + s3 : -1;
        if (y >= 3) {
          while (q < e) {
            final a = p[q - s] + (q1 >= 0 ? p[q1] : 0);
            final b = p[q - s3] + (q3 >= 0 ? p[q3] : 0);
            p[q] = p[q] - (((a << 3) + a - b + 16) >> 5);
            q += scale;
            if (q1 >= 0) q1 += scale;
            if (q3 >= 0) q3 += scale;
          }
        } else if (y >= 1) {
          while (q < e) {
            final a = p[q - s] + (q1 >= 0 ? p[q1] : 0);
            final b = q3 >= 0 ? p[q3] : 0;
            p[q] = p[q] - (((a << 3) + a - b + 16) >> 5);
            q += scale;
            if (q1 >= 0) q1 += scale;
            if (q3 >= 0) q3 += scale;
          }
        } else {
          while (q < e) {
            final a = q1 >= 0 ? p[q1] : 0;
            final b = q3 >= 0 ? p[q3] : 0;
            p[q] = p[q] - (((a << 3) + a - b + 16) >> 5);
            q += scale;
            if (q1 >= 0) q1 += scale;
            if (q3 >= 0) q3 += scale;
          }
        }
      }
    }
    // 2-Interpolation
    {
      var q = base - s3;
      final e = q + w;
      if (y >= 6 && y < h) {
        while (q < e) {
          final a = p[q - s] + p[q + s];
          final b = p[q - s3] + p[q + s3];
          p[q] = p[q] + (((a << 3) + a - b + 8) >> 4);
          q += scale;
        }
      } else if (y >= 3) {
        var q1 = y - 2 < h ? q + s : q - s;
        while (q < e) {
          final a = p[q - s] + p[q1];
          p[q] = p[q] + ((a + 1) >> 1);
          q += scale;
          q1 += scale;
        }
      }
    }
    y += 2;
    base += s + s;
  }
}

/// 对应 `filter_bh`：水平方向的 lifting + interpolation（原地、带边界特判）。
void _filterBh(Int16List p, int w, int h, int rowsize, int scale) {
  var y = 0;
  final s = scale;
  final s3 = s + s + s;
  rowsize *= scale;
  var base = 0;
  while (y < h) {
    var q = base;
    final e = base + w;
    var a0 = 0, a1 = 0, a2 = 0, a3 = 0;
    var b0 = 0, b1 = 0, b2 = 0, b3 = 0;
    if (q < e) {
      // 特例 x=0
      if (q + s < e) a2 = p[q + s];
      if (q + s3 < e) a3 = p[q + s3];
      b2 = b3 = p[q] - ((((a1 + a2) << 3) + (a1 + a2) - a0 - a3 + 16) >> 5);
      p[q] = b3;
      q += s + s;
    }
    if (q < e) {
      // 特例 x=2
      a0 = a1;
      a1 = a2;
      a2 = a3;
      if (q + s3 < e) a3 = p[q + s3];
      b3 = p[q] - ((((a1 + a2) << 3) + (a1 + a2) - a0 - a3 + 16) >> 5);
      p[q] = b3;
      q += s + s;
    }
    if (q < e) {
      // 特例 x=4
      b1 = b2;
      b2 = b3;
      a0 = a1;
      a1 = a2;
      a2 = a3;
      if (q + s3 < e) a3 = p[q + s3];
      b3 = p[q] - ((((a1 + a2) << 3) + (a1 + a2) - a0 - a3 + 16) >> 5);
      p[q] = b3;
      p[q - s3] = p[q - s3] + ((b1 + b2 + 1) >> 1);
      q += s + s;
    }
    while (q + s3 < e) {
      // 通用情形
      a0 = a1;
      a1 = a2;
      a2 = a3;
      a3 = p[q + s3];
      b0 = b1;
      b1 = b2;
      b2 = b3;
      b3 = p[q] - ((((a1 + a2) << 3) + (a1 + a2) - a0 - a3 + 16) >> 5);
      p[q] = b3;
      p[q - s3] =
          p[q - s3] + ((((b1 + b2) << 3) + (b1 + b2) - b0 - b3 + 8) >> 4);
      q += s + s;
    }
    while (q < e) {
      // 特例 w-3 <= x < w
      a0 = a1;
      a1 = a2;
      a2 = a3;
      a3 = 0;
      b0 = b1;
      b1 = b2;
      b2 = b3;
      b3 = p[q] - ((((a1 + a2) << 3) + (a1 + a2) - a0 - a3 + 16) >> 5);
      p[q] = b3;
      p[q - s3] =
          p[q - s3] + ((((b1 + b2) << 3) + (b1 + b2) - b0 - b3 + 8) >> 4);
      q += s + s;
    }
    while (q - s3 < e) {
      // 特例 w <= x < w+3
      b0 = b1;
      b1 = b2;
      b2 = b3;
      if (q - s3 >= base) {
        p[q - s3] = p[q - s3] + ((b1 + b2 + 1) >> 1);
      }
      q += s + s;
    }
    y += scale;
    base += rowsize;
  }
}

// ------------------------------------------------------------------ 常量

/// liftblock 内 1024 个系数的 zigzag 位置。
///
/// 参考实现是一张写死的 1024 项表（注释里给出生成程序）；这里直接按同一程序
/// 生成，并已用脚本逐项与参考表核对一致（1024/1024 相等）。
final Int32List _zigzagloc = () {
  final t = Int32List(1024);
  for (var n = 0; n < 1024; n++) {
    var x = 0;
    var y = 0;
    var v = n;
    for (var k = 0; k < 5; k++) {
      x = (x << 1) | (v & 1);
      v >>= 1;
      y = (y << 1) | (v & 1);
      v >>= 1;
    }
    t[n] = x + 32 * y;
  }
  return t;
}();
