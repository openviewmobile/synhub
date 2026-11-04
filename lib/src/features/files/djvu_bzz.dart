// DJVU 的 **BZZ 通用压缩编解码器**（Burrows-Wheeler 变换 + 准 MTF + ZP 算术编码）
// —— 纯 Dart，零 flutter / l10n 依赖。
//
// 为什么要自研：DJVU 里凡是"文本类"的大块（DIRM 目录、TXTz 隐藏文本、ANTz
// 注释、NAVM 书签、METz 元数据）都用 BZZ 压缩。唯一成熟的实现 DjVuLibre 是
// **GPL-2.0**，对闭源 App 是法务阻塞；pub.dev 上也没有任何 Dart 实现。所以这里
// 按**公开的 DjVu3 格式规范与算法事实**独立重写。
//
// **参考与许可**：算法事实来自公开的 DjVu3 规范，以及 DjVuLibre 的
// `BSByteStream` / `BSEncodeByteStream`（GPL-2.0，**仅作算法事实参考**）。
// 本文件没有任何其代码、头文件或注释的拷贝，是独立重写的 Dart 实现。
// 底层的 ZP 算术编码器复用同仓的 `djvu_zp.dart`（同样自研）。
//
// **位流结构**（一个 BZZ 流由 0..N 个数据块 + 1 个终止块串成）：
//
//   * 每个块以 **24 个 pass-thru 位**给出块长度 `size`（含末尾哨兵字节，
//     所以真实解出 `size-1` 字节）；`size == 0` 表示流结束；
//   * 接着 1..2 个 pass-thru 位给出"频率估计速度" `fshift`；
//   * 然后是 BWT 串的准 MTF 编码（固定 9 层二叉树，上下文共 260 个，
//     在块之间**持续自适应**）；
//   * 每块最后做**逆 BWT**：把 MTF 解出的串按首字符计数排序，再沿 LF 映射
//     回溯，得到 `size-1` 字节；末尾那个哨兵槽被丢弃。
//
// **关于"魔数"**：BZZ 位流本身**没有**固定魔数（首两字节是 ZP 的初始 16 位
// `code`，随数据而变，实测有 `fffe`/`ffff`/`fff9`/`ffad` 等）。真正的魔数在
// **IFF 容器层**：参考实现 `IFFByteStream` 里有**两个变体** —— `AT&T`
// （原始 DjVu）与 `SDJV`（Celartem Secure DjVu）。为了容错，本解码器**先按裸
// 流解**，失败时若开头命中这两个魔数之一（或 2 字节的 `BZ`/`ZB` 标记）则跳过
// 再试一次；两个都失败才抛错。见 [_magicPrefixCandidates]。
//
// **能力边界**（宁可给明确错误，也不吐乱码或半截）：
//
//   | 维度 | 支持 | 明确报错 |
//   |---|---|---|
//   | 解码 | 任意 0..N 块、块间共享上下文、单块 ≤ 4096KiB | 超过 → `DjvuFormatException` |
//   | 编码 | 自造 `djvuBzzEncode` 输出（本解码器可逐字节还原） | —— |
//   | 解压上限 | `maxSize`（默认 256MiB）以内 | 声明/累计超出 → `DjvuUnsupportedException` |
//   | 截断/垃圾 | —— | 一律 `DjvuFormatException`（不返回半截/乱码） |
//   | 无限循环 | —— | 每块必产 ≥1 字节且读取位置单调前进，受输入长度与 maxSize 双重约束 |
//   | 内存 | 单块 `Uint8List(size)` + 输出，均 ≤ maxSize | —— |
//
// **未端到端验证（无真实样本）**：仓库内没有真实 `.djvu` 样本，`book_djvu.dart`
// 的渲染链路也尚未接入，所以 BZZ 只做了"编解码逐字节往返 + 畸形输入"的单元
// 自证；真实文件解码能力**未经仓库内端到端验证**。开发期用一份外部样例
// （Internet Archive 的 `commons_example.djvu`）对 DIRM/TXTz 做过交叉核对，
// 但那只是本地临时资产，不属于仓库。此外**编码器**选的是"最简单的正确路径"
// （标准后缀数组 BWT + 参考实现的 MTF/ZP 编码），**不保证**与 DjVuLibre 编码
// 器逐字节一致（规范只要求解码器兼容，不要求编码器一致）。
import 'dart:typed_data';

import 'djvu_errors.dart';
import 'djvu_zp.dart';

// ---------------------------------------------------------------- 常量

/// 参考实现的排序阈值：频率表只有前 4 项（`FREQMAX`）。
const int _kFreqMax = 4;

/// 参考实现的前两个 MTF 层用的上下文步长（`CTXIDS`）。
const int _kCtxIds = 3;

/// 参考实现 `BSByteStream::MAXBLOCK * 1024`：单块最大字节数（4MiB）。
const int _kMaxBlockSize = 4096 * 1024;

/// 编码器分块大小。参考实现默认 2048KiB / DjVu 文本用 50KiB；这里取 128KiB，
/// 在压缩率与后缀数组 O(n log n) 的耗时之间折中。
const int _kEncodeBlockBytes = 128 * 1024;

/// 9 层固定二叉树的根上下文下标（与参考实现的 `ctx` 指针步进一一对应）。
const List<int> _kTreeRoots = <int>[0, _kCtxIds, 6, 8, 12, 20, 36, 68, 132];

/// 上下文总数：最后一个二叉树用到下标 132+126=258。
const int _kContextCount = 300;

/// BZZ 流外面可能带、需要容忍的容器魔数前缀（长的优先）。
///
/// 参考实现 `IFFByteStream` 里两个变体：`AT&T` 与 `SDJV`；`BZ`/`ZB` 是
/// 部分工具在"纯 bzz 文件"上使用的 2 字节标记。
final List<Uint8List> _magicPrefixCandidates = <Uint8List>[
  Uint8List.fromList(<int>[0x41, 0x54, 0x26, 0x54]), // 'AT&T'
  Uint8List.fromList(<int>[0x53, 0x44, 0x4A, 0x56]), // 'SDJV'
  Uint8List.fromList(<int>[0x42, 0x5A]), // 'BZ'
  Uint8List.fromList(<int>[0x5A, 0x42]), // 'ZB'
];

// ---------------------------------------------------------------- 公共 API

/// 解压一段 BZZ 流（DIRM / TXTz / ANTz / NAVM / METz 的载荷）。
///
/// [data] 是裸 BZZ 字节流；若开头带 IFF/工具魔数（见 [_magicPrefixCandidates]）
/// 也会先剥离再试。解压失败抛 [DjvuFormatException]；声明或累计解压长度超过
/// [maxSize] 抛 [DjvuUnsupportedException]。
Uint8List djvuBzzDecode(List<int> data, {int maxSize = 1 << 28}) {
  if (maxSize < 0) {
    throw DjvuUnsupportedException('BZZ 解压上限非法：$maxSize');
  }
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  try {
    return _decodeRawStream(bytes, maxSize);
  } on DjvuFormatException {
    // 裸流失败：若开头命中已知魔数，剥离后再试一次。真实文件走不到这里，
    // 所以不会影响正常解码；两条路都失败才把原始错误抛出去。
    for (final magic in _magicPrefixCandidates) {
      if (bytes.length > magic.length &&
          _startsWith(bytes, magic) &&
          _startsWithCandidate(bytes, magic)) {
        try {
          return _decodeRawStream(
            Uint8List.sublistView(bytes, magic.length),
            maxSize,
          );
        } on DjvuFormatException {
          continue;
        }
      }
    }
    rethrow;
  }
}

/// 把 [data] 压成一段 BZZ 流，保证能被 [djvuBzzDecode] 逐字节还原。
///
/// 空数组会编码成"只有终止块"的合法流；超长输入按 [_kEncodeBlockBytes] 分块。
Uint8List djvuBzzEncode(List<int> data) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  final zp = ZpEncoder();
  final contexts = ZpContextArray(_kContextCount);
  var offset = 0;
  while (offset < bytes.length) {
    final end = offset + _kEncodeBlockBytes < bytes.length
        ? offset + _kEncodeBlockBytes
        : bytes.length;
    _encodeBlock(zp, contexts, Uint8List.sublistView(bytes, offset, end));
    offset = end;
  }
  // 终止块：24 位长度 0，然后 flush 出所有挂起的比特。
  _encodeRaw(zp, 24, 0);
  return zp.finish();
}

// ---------------------------------------------------------------- 解码

Uint8List _decodeRawStream(Uint8List data, int maxSize) {
  final zp = ZpDecoder(data);
  final contexts = ZpContextArray(_kContextCount);
  final out = BytesBuilder(copy: false);
  var total = 0;
  while (true) {
    final declared = _decodeRaw(zp, 24);
    if (declared == 0) break; // 终止块
    if (declared > _kMaxBlockSize) {
      throw DjvuFormatException('BZZ 块长度 $declared 超过 4096KiB（数据损坏）');
    }
    // size 含末尾哨兵，真实产出 size-1 字节；提前用 maxSize 卡死分配。
    if (declared - 1 > maxSize - total) {
      throw DjvuUnsupportedException(
        'BZZ 解压长度将超过上限 $maxSize 字节（已解 $total，本块声明 $declared）',
      );
    }
    final block = _decodeBlock(zp, contexts, declared);
    out.add(block);
    total += block.length;
  }
  return out.toBytes();
}

/// 解码一个数据块，返回其 `size-1` 个真实字节（末尾哨兵已剥离）。
Uint8List _decodeBlock(ZpDecoder zp, ZpContextArray contexts, int size) {
  // 频率估计速度：0/1/2 个 pass-thru 位。
  var fshift = 0;
  if (zp.decodeSimple() != 0) {
    fshift = 1;
    if (zp.decodeSimple() != 0) fshift = 2;
  }

  final data = Uint8List(size);
  final mtf = Uint8List(256);
  for (var m = 0; m < 256; m++) {
    mtf[m] = m;
  }
  final freq = <int>[0, 0, 0, 0];
  var fadd = 4;
  var mtfno = 3;
  var markerpos = -1;

  for (var i = 0; i < size; i++) {
    final number = _decodeMtfNumber(zp, contexts, mtfno);
    if (number == 256) {
      // MTF 逃逸 = 逆 BWT 的哨兵位置（编码时 `i == markerpos`）。
      data[i] = 0;
      markerpos = i;
      mtfno = number;
      continue;
    }
    mtfno = number;
    final c = mtf[mtfno];
    data[i] = c;

    // 按经验频率重排 MTF（与参考实现逐行对应）。
    fadd = fadd + (fadd >> fshift);
    if (fadd > 0x10000000) {
      fadd >>= 24;
      freq[0] >>= 24;
      freq[1] >>= 24;
      freq[2] >>= 24;
      freq[3] >>= 24;
    }
    var fc = fadd;
    if (mtfno < _kFreqMax) fc += freq[mtfno];
    var k = mtfno;
    for (; k >= _kFreqMax; k--) {
      mtf[k] = mtf[k - 1];
    }
    for (; k > 0 && fc >= freq[k - 1]; k--) {
      mtf[k] = mtf[k - 1];
      freq[k] = freq[k - 1];
    }
    mtf[k] = c;
    freq[k] = fc;
  }

  return _inverseBwt(data, size, markerpos);
}

/// 固定 9 层二叉树解码：返回 0..255 的 MTF 序号，或 256 表示哨兵逃逸。
///
/// [previous] 是上一个符号的 `mtfno`，用于挑选前两层的上下文（与参考实现
/// 的 `ctxid = min(CTXIDS-1, mtfno)` 一致）。
int _decodeMtfNumber(ZpDecoder zp, ZpContextArray contexts, int previous) {
  var ctxid = _kCtxIds - 1;
  if (ctxid > previous) ctxid = previous;
  if (zp.decodeAt(contexts, _kTreeRoots[0] + ctxid) != 0) return 0;
  if (zp.decodeAt(contexts, _kTreeRoots[1] + ctxid) != 0) return 1;
  for (var level = 2; level <= 8; level++) {
    if (zp.decodeAt(contexts, _kTreeRoots[level]) != 0) {
      final value = _decodeBinary(
        zp,
        contexts,
        _kTreeRoots[level] + 1,
        level - 1,
      );
      return (1 << (level - 1)) + value;
    }
  }
  return 256;
}

/// 逆 BWT：`data` 是 BWT 串（含哨兵），返回 `data[0..size-2]`。
Uint8List _inverseBwt(Uint8List data, int size, int markerpos) {
  if (markerpos < 1 || markerpos >= size) {
    throw DjvuFormatException('BZZ 块缺少有效的 BWT 哨兵位置（数据损坏）');
  }
  final posn = Uint32List(size);
  final count = List<int>.filled(256, 0);
  for (var i = 0; i < markerpos; i++) {
    final c = data[i];
    posn[i] = (c << 24) | (count[c] & 0xffffff);
    count[c]++;
  }
  for (var i = markerpos + 1; i < size; i++) {
    final c = data[i];
    posn[i] = (c << 24) | (count[c] & 0xffffff);
    count[c]++;
  }
  var last = 1;
  for (var i = 0; i < 256; i++) {
    final tmp = count[i];
    count[i] = last;
    last += tmp;
  }
  var index = 0;
  last = size - 1;
  while (last > 0) {
    final n = posn[index];
    final c = (n >> 24) & 0xff;
    data[--last] = c;
    index = count[c] + (n & 0xffffff);
  }
  if (index != markerpos) {
    throw DjvuFormatException('BZZ 逆 BWT 自相矛盾（数据损坏）');
  }
  return Uint8List.sublistView(data, 0, size - 1);
}

// ---------------------------------------------------------------- 编码

void _encodeBlock(ZpEncoder zp, ZpContextArray contexts, Uint8List block) {
  final size = block.length + 1; // 末尾追加 BWT 哨兵字节
  _encodeRaw(zp, 24, size);

  final int fshift;
  if (size < 100000) {
    fshift = 0;
    zp.encodeSimple(0);
  } else if (size < 1000000) {
    fshift = 1;
    zp.encodeSimple(1);
    zp.encodeSimple(0);
  } else {
    fshift = 2;
    zp.encodeSimple(1);
    zp.encodeSimple(1);
  }

  final transformed = _forwardBwt(block);
  final size1 = transformed.bytes.length; // == size
  final mtf = Uint8List(256);
  final rmtf = Uint8List(256);
  for (var m = 0; m < 256; m++) {
    mtf[m] = m;
    rmtf[m] = m;
  }
  final freq = <int>[0, 0, 0, 0];
  var fadd = 4;
  var mtfno = 3;

  for (var i = 0; i < size1; i++) {
    final c = transformed.bytes[i];
    var ctxid = _kCtxIds - 1;
    if (ctxid > mtfno) ctxid = mtfno;
    mtfno = rmtf[c];
    final isMarker = (i == transformed.markerpos);
    if (isMarker) mtfno = 256;

    // 固定 9 层二叉树编码。
    if (mtfno == 0) {
      zp.encodeAt(contexts, _kTreeRoots[0] + ctxid, 1);
    } else {
      zp.encodeAt(contexts, _kTreeRoots[0] + ctxid, 0);
      if (mtfno == 1) {
        zp.encodeAt(contexts, _kTreeRoots[1] + ctxid, 1);
      } else {
        zp.encodeAt(contexts, _kTreeRoots[1] + ctxid, 0);
        for (var level = 2; level <= 8; level++) {
          final bit = mtfno < (1 << level) ? 1 : 0;
          zp.encodeAt(contexts, _kTreeRoots[level], bit);
          if (bit == 1) {
            _encodeBinary(
              zp,
              contexts,
              _kTreeRoots[level] + 1,
              level - 1,
              mtfno - (1 << (level - 1)),
            );
            break;
          }
        }
      }
    }
    if (isMarker) continue;

    fadd = _rotateMtfEncode(mtf, rmtf, freq, fadd, fshift, mtfno, c);
  }
}

int _rotateMtfEncode(
  Uint8List mtf,
  Uint8List rmtf,
  List<int> freq,
  int fadd,
  int fshift,
  int mtfno,
  int c,
) {
  fadd = fadd + (fadd >> fshift);
  if (fadd > 0x10000000) {
    fadd >>= 24;
    freq[0] >>= 24;
    freq[1] >>= 24;
    freq[2] >>= 24;
    freq[3] >>= 24;
  }
  var fc = fadd;
  if (mtfno < _kFreqMax) fc += freq[mtfno];
  var k = mtfno;
  for (; k >= _kFreqMax; k--) {
    mtf[k] = mtf[k - 1];
    rmtf[mtf[k]] = k;
  }
  for (; k > 0 && fc >= freq[k - 1]; k--) {
    mtf[k] = mtf[k - 1];
    freq[k] = freq[k - 1];
    rmtf[mtf[k]] = k;
  }
  mtf[k] = c;
  freq[k] = fc;
  rmtf[mtf[k]] = k;
  return fadd;
}

/// 前向 BWT 的结果：变换后的字节串 + 哨兵所在下标。
class _BwtResult {
  _BwtResult(this.bytes, this.markerpos);
  final Uint8List bytes;
  final int markerpos;
}

/// 前向 BWT：把 `block + 哨兵 0` 的所有后缀排序，取每个后缀的前一个字节。
///
/// 哨兵视为**唯一最小**字节（即便原始数据里也有 0x00）。用前缀倍增 + 计数
/// 排序求后缀数组，O(n log n)，对"高度重复"数据也不会退化。
_BwtResult _forwardBwt(Uint8List block) {
  final n = block.length + 1;
  final text = Uint8List(n);
  text.setRange(0, block.length, block);
  text[n - 1] = 0;
  final sa = _suffixArray(text);
  final out = Uint8List(n);
  var markerpos = -1;
  for (var i = 0; i < n; i++) {
    final p = sa[i];
    if (p == 0) {
      markerpos = i;
      out[i] = 0;
    } else {
      out[i] = text[p - 1];
    }
  }
  if (markerpos < 0) {
    throw DjvuFormatException('BZZ 编码器内部错误：后缀数组里没有起点 0');
  }
  return _BwtResult(out, markerpos);
}

List<int> _suffixArray(Uint8List text) {
  final n = text.length;
  if (n == 1) return <int>[0];
  final sa = List<int>.filled(n, 0);
  var rank = List<int>.filled(n, 0);
  var tmp = List<int>.filled(n, 0);

  // 初始序：哨兵 rank=0（唯一最小），字节 b 的 rank=b+1。
  var classes = 0;
  {
    final cnt = List<int>.filled(258, 0);
    for (var i = 0; i < n; i++) {
      rank[i] = (i == n - 1) ? 0 : text[i] + 1;
      cnt[rank[i]]++;
    }
    for (var i = 1; i < 258; i++) {
      cnt[i] += cnt[i - 1];
    }
    for (var i = n - 1; i >= 0; i--) {
      sa[--cnt[rank[i]]] = i;
    }
    classes = 1;
    tmp[sa[0]] = 0;
    for (var i = 1; i < n; i++) {
      if (rank[sa[i]] != rank[sa[i - 1]]) classes++;
      tmp[sa[i]] = classes - 1;
    }
    final swap = rank;
    rank = tmp;
    tmp = swap;
  }
  if (classes == n) return sa;

  final pn = List<int>.filled(n, 0);
  final cnt = List<int>.filled(n + 1, 0);
  for (var k = 1; k < n && classes < n; k <<= 1) {
    for (var i = 0; i < n; i++) {
      final v = sa[i] - k;
      pn[i] = v < 0 ? v + n : v;
    }
    for (var i = 0; i < classes; i++) {
      cnt[i] = 0;
    }
    for (var i = 0; i < n; i++) {
      cnt[rank[pn[i]]]++;
    }
    for (var i = 1; i < classes; i++) {
      cnt[i] += cnt[i - 1];
    }
    for (var i = n - 1; i >= 0; i--) {
      sa[--cnt[rank[pn[i]]]] = pn[i];
    }
    tmp[sa[0]] = 0;
    var next = 1;
    for (var i = 1; i < n; i++) {
      final a = sa[i];
      final b = sa[i - 1];
      if (rank[a] != rank[b] || rank[(a + k) % n] != rank[(b + k) % n]) {
        next++;
      }
      tmp[a] = next - 1;
    }
    final swap = rank;
    rank = tmp;
    tmp = swap;
    classes = next;
  }
  return sa;
}

// ---------------------------------------------------------------- 位辅助

/// `bits` 位 pass-thru 解码（参考实现的 `decode_raw`）。
int _decodeRaw(ZpDecoder zp, int bits) {
  var n = 1;
  final m = 1 << bits;
  while (n < m) {
    n = (n << 1) | zp.decodeSimple();
  }
  return n - m;
}

/// `bits` 位 pass-thru 编码（参考实现的 `encode_raw`）。
void _encodeRaw(ZpEncoder zp, int bits, int value) {
  var n = 1;
  final m = 1 << bits;
  var x = value;
  while (n < m) {
    x = (x & (m - 1)) << 1;
    final b = x >> bits;
    zp.encodeSimple(b);
    n = (n << 1) | b;
  }
}

/// 用 `2^bits - 1` 个上下文做二叉解码（参考实现的 `decode_binary`）。
int _decodeBinary(ZpDecoder zp, ZpContextArray contexts, int ptr, int bits) {
  var n = 1;
  final m = 1 << bits;
  while (n < m) {
    final b = zp.decodeAt(contexts, ptr + n - 1);
    n = (n << 1) | b;
  }
  return n - m;
}

/// 用 `2^bits - 1` 个上下文做二叉编码（参考实现的 `encode_binary`）。
void _encodeBinary(
  ZpEncoder zp,
  ZpContextArray contexts,
  int ptr,
  int bits,
  int value,
) {
  var n = 1;
  final m = 1 << bits;
  var x = value;
  while (n < m) {
    x = (x & (m - 1)) << 1;
    final b = x >> bits;
    zp.encodeAt(contexts, ptr + n - 1, b);
    n = (n << 1) | b;
  }
}

bool _startsWith(Uint8List data, Uint8List prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

/// 只在"剥离前缀后仍有意义"时才尝试（避免把短输入当魔数）。
bool _startsWithCandidate(Uint8List data, Uint8List prefix) {
  return data.length > prefix.length + 1;
}
