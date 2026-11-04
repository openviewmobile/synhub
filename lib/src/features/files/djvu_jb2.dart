// DJVU 的 **JB2 双层图像编解码器**（`Sjbz` / `Djbz` chunk）—— 纯 Dart，
// 零 flutter / l10n 依赖（`dart run tool/*.dart` 必须能编译）。
//
// 为什么要自研（结论见 `docs/ebook-formats-research.md`）：DJVU 正文页的前景层
// 就是 JB2（"soft pattern matching"，按形状+参照形状差分的二值压缩）。
// DjVuLibre 是 **GPL-2.0**，对闭源 App 是法务阻塞；pub.dev 上没有任何纯 Dart
// 的 JB2 实现。所以这里按**公开的 DjVu3 规范 / ICFDD 提案**（记录类型表、
// 数字编码器、上下文模板）独立重写，只把它当作算法事实。
//
// **参考与许可**：算法事实来自公开的 DjVu3 规范与 DjVuLibre 的
// `JB2Image.cpp/.h`（GPL-2.0，**仅作算法事实参考**）。本文件没有任何其代码、
// 头文件或注释的拷贝：上下文模板、记录语义、数字编码器相位都按规范重述为
// Dart，命名、结构与错误处理完全自写。位流底座复用本仓库自研的
// `djvu_zp.dart`（ZP 算术编码器）。
//
// **能力边界**（宁可给明确错误，也绝不吐半截乱码）：
//
//   | 维度 | 支持 | 明确报错 |
//   |---|---|---|
//   | 记录类型 | 0 StartOfData / 1 NewMark / 2 NewMarkLibOnly / 3 NewMarkImgOnly / 4 MatchedRefine / 5 MatchedRefineLibOnly / 6 MatchedRefineImgOnly / 7 MatchedCopy / 8 NonMarkData / 9 RequiredDictOrReset / 10 PreservedComment / 11 EndOfData | 字典（Djbz）里出现仅图像记录 → [DjvuUnsupportedException] |
//   | 符号字典 | `Djbz` 解析；`require_dictionary` 继承（含数量校验） | 流要求字典却未提供 → 不支持；声明数量与字典不符 → 坏文件 |
//   | 数字编码器 | 完整 NumContext 16 位概率树 + `reset_numcoder` | —— |
//   | 精修/复用 | MatchedRefine 交叉编码、MatchedCopy 复用、相对/绝对定位 | —— |
//   | 逐页老 bug (DjVu<18) | 未实现（chunk 内无法自检） | 见下方"未验证/边界" |
//   | 注释 | 读取并丢弃（有长度上限） | 超限 → [DjvuFormatException] |
//
// `data` 是原始 `Sjbz`（图像）或 `Djbz`（字典）chunk 字节；`width`/`height` 来自
// 页面的 `INFO` chunk，仅在 JB2 流自身没有携带尺寸时兜底。
//
// **验证状态（诚实标注）**：本仓库内没有真实 `.djvu` 样本，且任务禁止联网
// 下载，因此**没有在真实整册 DJVU 文件上端到端跑过**。但为了补上"自证不算
// 证明"的缺口，`tool/djvu_jb2_selftest.dart` 会读取 /tmp 下本地编译的
// DjVuLibre 参考实现产出的 JB2 流做双向交叉验证（见 `tool/` 侧脚本）：
//   * 参考编码器 → 本解码器：覆盖全部 12 种记录类型，含 `Djbz` 共享字典继承、
//     `MatchedRefine` 交叉编码精修、`NonMarkData` 绝对定位、ImageOnly 变体，
//     逐像素一致；
//   * 本编码器 `djvuJb2EncodeSimple` → 参考解码器：逐像素一致。
// 仍然**未验证**的部分：真实扫描件的多页/跨页共享字典整册流程；记录 9 出现在
// `START_OF_DATA` 之后的 numcoder reset 分支（按规范实现，但参考样本未触发）；
// 以及 DjVu 版本 < 18 的 `reproduce_old_bug` 定位老 bug（chunk 内无法自检）。
import 'dart:typed_data';

import 'djvu_errors.dart';
import 'djvu_zp.dart';

// ---------------------------------------------------------------- 公开 API

/// 二值位图：每像素 1 字节，1 = 前景（墨迹），0 = 背景。
///
/// `pixels` 按**自上而下**的行序存储（`y = 0` 是最上面一行），
/// `pixels[y * width + x]`。
class DjvuBitmap {
  DjvuBitmap(this.width, this.height) : pixels = Uint8List(width * height);

  final int width;
  final int height;
  final Uint8List pixels;

  /// 读取像素；越界返回 false（不抛异常，方便渲染调用方直接裁剪）。
  bool at(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return false;
    return pixels[y * width + x] != 0;
  }
}

/// 一个已解析的 `Djbz` 共享符号字典（不透明）。
///
/// 只由 [djvuJb2DictionaryDecode] 构造，供 [djvuJb2Decode] 的 `dictionary`
/// 参数使用：图像流通过 `REQUIRED_DICT_OR_RESET` 声明依赖它时，符号索引
/// 从字典的符号总数开始编号。
class DjvuJb2Dictionary {
  DjvuJb2Dictionary._(this._shapes, this._boxes);

  /// 每个符号的位图（可能为 null——字典里一般都有）。
  final List<_Jb2Shape> _shapes;

  /// 每个符号的墨迹包围盒（与 C++ 参考实现同口径，空的符号给出
  /// right=-1 / top=-1 / left=0 / bottom=0）。
  final List<_LibRect> _boxes;

  int get _shapeCount => _shapes.length;
}

/// 解析一个 `Djbz` chunk，得到共享符号字典。
///
/// 字典是 JB2 图像格式的**纯子集**：`START_OF_DATA` 的宽高必须都是 0，
/// 只允许"仅库符号"记录（2 / 5）与结束记录（11）。
DjvuJb2Dictionary djvuJb2DictionaryDecode(Uint8List data) {
  final dec = _Jb2Decoder(
    ZpDecoder(data),
    dict: null,
    fallbackWidth: 0,
    fallbackHeight: 0,
  );
  return dec.runDictionary();
}

/// 解码一个 `Sjbz` chunk，渲染成整页前景位图。
///
/// [width] / [height] 来自页面 `INFO` chunk，仅当 JB2 流本身没写尺寸时兜底。
/// [dictionary] 提供 `require_dictionary` 需要的共享符号。
DjvuBitmap djvuJb2Decode(
  Uint8List data, {
  int width = 0,
  int height = 0,
  DjvuJb2Dictionary? dictionary,
}) {
  final dec = _Jb2Decoder(
    ZpDecoder(data),
    dict: dictionary,
    fallbackWidth: width,
    fallbackHeight: height,
  );
  return dec.runImage();
}

/// **自造的最小编码器**（仅供 `tool/` 侧造测试样本）。
///
/// 只输出一条 `NEW_MARK` 记录：把整张位图当作一个"新符号"直接逐像素编码，
/// 再补一条相对定位把它贴到 (0,0)。不做形状库复用、不做交叉编码——因此
/// 压缩率很差，但语义**完整且可被本解码器无损还原**，也能被按规范实现的
/// 解码器（例如参考实现）还原。
///
/// 这不是生产路径：真实 DJVU 的 `Sjbz` 由 DjVuLibre 的启发式切形器生成。
Uint8List djvuJb2EncodeSimple(DjvuBitmap bmp) {
  if (bmp.width <= 0 || bmp.height <= 0) {
    throw ArgumentError('JB2 编码要求正数宽高，收到 ${bmp.width}×${bmp.height}');
  }
  if (bmp.width > 0xffff || bmp.height > 0xffff) {
    throw ArgumentError('JB2 符号尺寸必须能放进 16 位：${bmp.width}×${bmp.height}');
  }
  // 公开位图是自上而下，JB2 内部位图是自下而上（row 0 = 最下面一行）。
  final shape = _Shape(bmp.width, bmp.height);
  for (var y = 0; y < bmp.height; y++) {
    final row = bmp.height - 1 - y;
    final base = y * bmp.width;
    for (var x = 0; x < bmp.width; x++) {
      if (bmp.pixels[base + x] != 0) shape.setPx(row, x, 1);
    }
  }
  return _Jb2Encoder(ZpEncoder()).encodeLiteral(shape);
}

// ---------------------------------------------------------------- 记录类型

const int _startOfData = 0;
const int _newMark = 1;
const int _newMarkLibraryOnly = 2;
const int _newMarkImageOnly = 3;
const int _matchedRefine = 4;
const int _matchedRefineLibraryOnly = 5;
const int _matchedRefineImageOnly = 6;
const int _matchedCopy = 7;
const int _nonMarkData = 8;
const int _requiredDictOrReset = 9;
const int _preservedComment = 10;
const int _endOfData = 11;

// “大正/大负”数字编码上下界（规范里 CodeNum 的取值域）。
const int _bigPositive = 262142;
const int _bigNegative = -262143;

// 资源上限（防坏数据把内存/CPU 打满）。
const int _maxShapes = 1 << 20;
const int _maxBlits = 1 << 21;
const int _maxShapePixels = 1 << 25; // 单个符号位图像素上限
const int _maxShapeBytes = 1 << 28; // 单符号位图（含填充）字节上限
const int _maxTotalShapePixels = 1 << 27; // 所有符号位图累计像素上限
const int _maxImagePixels = 1 << 26; // 输出整页位图像素上限
const int _maxRecords = 1 << 22; // 记录条数上限（成环保护）
const int _maxCommentBytes = 1 << 20; // 注释长度上限

// ---------------------------------------------------------------- 内部位图

/// 一个符号的位图。
///
/// 行序与 JB2 位流一致：**row 0 是最下面一行**。左右各有 [colPad] 列零填充
/// （对应参考实现里 GBitmap 的 border），行方向的越界访问一律返回 0
/// （对应参考实现的 zerobuffer）。
class _Shape {
  _Shape(this.width, this.height) : _stride = width + 2 * _pad0 {
    _data = Uint8List(_stride * height);
  }

  static const int _pad0 = 4;

  final int width;
  final int height;
  int _colPad = _pad0;
  int _stride;
  late Uint8List _data;

  int get colPad => _colPad;
  int get stride => _stride;
  Uint8List get data => _data;

  /// 行列都可越界：行越界或列越界都读作 0。
  int px(int row, int col) {
    if (row < 0 || row >= height) return 0;
    final c = col + _colPad;
    if (c < 0 || c >= _stride) return 0;
    return _data[row * _stride + c];
  }

  void setPx(int row, int col, int v) {
    if (row < 0 || row >= height) return;
    final c = col + _colPad;
    if (c < 0 || c >= _stride) return;
    _data[row * _stride + c] = v;
  }

  /// 保证左右各有至少 [p] 列零填充（只增不减），必要时整体搬一次。
  void ensureColPad(int p) {
    if (p <= _colPad) return;
    final ns = width + 2 * p;
    if (ns * height > _maxShapeBytes) {
      throw DjvuFormatException('JB2 符号位图填充后过大：$ns×$height');
    }
    final nd = Uint8List(ns * height);
    final shift = p - _colPad;
    for (var r = 0; r < height; r++) {
      final src = r * _stride;
      final dst = r * ns + shift;
      nd.setRange(dst, dst + _stride, _data, src);
    }
    _data = nd;
    _colPad = p;
    _stride = ns;
  }
}

/// 墨迹包围盒（列/行都按 JB2 内部的自下而上行序）。
class _LibRect {
  _LibRect(this.left, this.right, this.top, this.bottom);
  int left;
  int right;
  int top;
  int bottom;
}

/// 一个符号：位图 + 父符号下标（-1 = 无父；-2 = NonMarkData）。
class _Jb2Shape {
  _Jb2Shape(this.bits, this.parent);
  _Shape? bits;
  int parent;
}

/// 一次贴图（blit）。
class _Blit {
  _Blit(this.shape, this.left, this.bottom);
  int shape;
  int left;
  int bottom;
}

// ---------------------------------------------------------------- 数字编码器

/// 一个数字编码上下文的"根"（可变槽位，初始 0 = 未分配）。
class _NumCtx {
  _NumCtx() : cell = 0;
  int cell;
}

/// JB2 的 `NumContext` 数字编码器：一棵按需生长的 16 位概率树。
///
/// 编/解码共用同一套相位状态机；编码时传入要写的值，解码时不传。
class _NumCoder {
  _NumCoder.decoder(ZpDecoder dec) : _dec = dec, _enc = null;

  _NumCoder.encoder(ZpEncoder enc) : _dec = null, _enc = enc;

  final ZpDecoder? _dec;
  final ZpEncoder? _enc;

  /// 单元 0 是哑元（对齐参考实现的 cur_ncell=1 起点）。
  final List<int> _bits = <int>[0];
  final List<int> _left = <int>[0];
  final List<int> _right = <int>[0];
  int _ncell = 1;
  final ZpBitContext _scratch = ZpBitContext();

  /// 清空全部数字上下文（对应 `reset_numcoder`）。
  void reset(Iterable<_NumCtx> roots) {
    for (final r in roots) {
      r.cell = 0;
    }
    _bits
      ..clear()
      ..add(0);
    _left
      ..clear()
      ..add(0);
    _right
      ..clear()
      ..add(0);
    _ncell = 1;
  }

  /// 一个概率比特：编码时写 [bit]，解码时读。
  int _codeBit(int cell, int? bit) {
    _scratch.value = _bits[cell];
    final int r;
    if (bit != null) {
      _enc!.encode(_scratch, bit);
      r = bit;
    } else {
      r = _dec!.decode(_scratch);
    }
    _bits[cell] = _scratch.value;
    return r;
  }

  /// 编解码一个数。解码时返回读到的值；编码时返回 [value]（忽略）。
  ///
  /// 相位语义（与规范一致）：
  ///   * 相位 1 定符号；
  ///   * 相位 2 定高位量级，`range` 记录要写多少位；
  ///   * 相位 3 逐位细化。
  int codeNum(int low, int high, _NumCtx ctx, [int? value]) {
    final encoding = value != null;
    var negative = false;
    var cutoff = 0;
    var phase = 1;
    var range = 0xffffffff;
    var cur = ctx.cell;
    var parent = -1;
    var isRight = false;
    while (range != 1) {
      if (cur == 0) {
        cur = _ncell++;
        _bits.add(0);
        _left.add(0);
        _right.add(0);
        if (parent < 0) {
          ctx.cell = cur;
        } else if (isRight) {
          _right[parent] = cur;
        } else {
          _left[parent] = cur;
        }
      }
      bool decision;
      if (low >= cutoff) {
        decision = true;
      } else if (high >= cutoff) {
        final int want = encoding ? (value >= cutoff ? 1 : 0) : 0;
        decision = _codeBit(cur, encoding ? want : null) != 0;
      } else {
        decision = false;
      }
      parent = cur;
      isRight = decision;
      cur = decision ? _right[cur] : _left[cur];
      switch (phase) {
        case 1:
          negative = !decision;
          if (negative) {
            final temp = -low - 1;
            low = -high - 1;
            high = temp;
          }
          phase = 2;
          cutoff = 1;
          break;
        case 2:
          if (!decision) {
            phase = 3;
            range = (cutoff + 1) ~/ 2;
            if (range == 1) {
              cutoff = 0;
            } else {
              cutoff -= range ~/ 2;
            }
          } else {
            cutoff += cutoff + 1;
          }
          break;
        default: // phase 3
          range = range ~/ 2;
          if (range != 1) {
            if (!decision) {
              cutoff -= range ~/ 2;
            } else {
              cutoff += range ~/ 2;
            }
          } else if (!decision) {
            cutoff--;
          }
          break;
      }
    }
    return negative ? -cutoff - 1 : cutoff;
  }
}

// ---------------------------------------------------------------- 解码器

class _Jb2Decoder {
  _Jb2Decoder(
    ZpDecoder zp, {
    required this.dict,
    required this.fallbackWidth,
    required this.fallbackHeight,
  }) : _zp = zp,
       _num = _NumCoder.decoder(zp);

  final ZpDecoder _zp;
  final _NumCoder _num;
  final DjvuJb2Dictionary? dict;
  final int fallbackWidth;
  final int fallbackHeight;

  final ZpContextArray _bitdist = ZpContextArray(1024);
  final ZpContextArray _cbitdist = ZpContextArray(2048);

  final List<_Jb2Shape> _shapes = <_Jb2Shape>[];
  final List<int> _lib2shape = <int>[];
  final List<_LibRect> _libinfo = <_LibRect>[];
  final List<_Blit> _blits = <_Blit>[];

  int _inheritedShapes = 0;
  int _imageColumns = 0;
  int _imageRows = 0;
  bool _gotStartRecord = false;
  int _records = 0;
  int _totalShapePixels = 0;

  // 相对定位状态（`_lastLeft` 目前只写不读：解码路径尚未消费它，
  // 保持与参考实现的状态机一致；见文件头的"未端到端验证"说明）
  // ignore: unused_field
  int _lastLeft = 0;
  int _lastRowLeft = 0;
  int _lastRowBottom = 0;
  int _lastRight = 0;
  int _lastBottom = 0;
  final List<int> _shortList = <int>[0, 0, 0];
  int _shortListPos = 0;

  // 数字上下文（对应参考实现里的 NumContext 成员）
  final _NumCtx _ctCommentByte = _NumCtx();
  final _NumCtx _ctCommentLength = _NumCtx();
  final _NumCtx _ctRecordType = _NumCtx();
  final _NumCtx _ctMatchIndex = _NumCtx();
  final _NumCtx _ctAbsLocX = _NumCtx();
  final _NumCtx _ctAbsLocY = _NumCtx();
  final _NumCtx _ctAbsSizeX = _NumCtx();
  final _NumCtx _ctAbsSizeY = _NumCtx();
  final _NumCtx _ctImageSize = _NumCtx();
  final _NumCtx _ctInheritedCount = _NumCtx();
  final _NumCtx _ctRelLocXCurrent = _NumCtx();
  final _NumCtx _ctRelLocXLast = _NumCtx();
  final _NumCtx _ctRelLocYCurrent = _NumCtx();
  final _NumCtx _ctRelLocYLast = _NumCtx();
  final _NumCtx _ctRelSizeX = _NumCtx();
  final _NumCtx _ctRelSizeY = _NumCtx();

  // 比特上下文
  final ZpBitContext _bcRefinementFlag = ZpBitContext();
  final ZpBitContext _bcOffsetType = ZpBitContext();

  List<_NumCtx> get _allNumRoots => <_NumCtx>[
    _ctCommentByte,
    _ctCommentLength,
    _ctRecordType,
    _ctMatchIndex,
    _ctAbsLocX,
    _ctAbsLocY,
    _ctAbsSizeX,
    _ctAbsSizeY,
    _ctImageSize,
    _ctInheritedCount,
    _ctRelLocXCurrent,
    _ctRelLocXLast,
    _ctRelLocYCurrent,
    _ctRelLocYLast,
    _ctRelSizeX,
    _ctRelSizeY,
  ];

  int get _shapeCount => _inheritedShapes + _shapes.length;

  // ------------------------------------------------------------ 运行入口

  /// 解一个 `Sjbz`：解析全部记录并渲染整页。
  DjvuBitmap runImage() {
    _decodeImageRecords();
    if (!_gotStartRecord) {
      throw DjvuFormatException('JB2 图像流缺少 START_OF_DATA 记录');
    }
    var w = _imageColumns;
    var h = _imageRows;
    if (w <= 0) w = fallbackWidth;
    if (h <= 0) h = fallbackHeight;
    if (w <= 0 || h <= 0) {
      throw DjvuFormatException(
        'JB2 图像尺寸无效（流内为 $_imageColumns×$_imageRows，'
        'INFO 兜底为 $fallbackWidth×$fallbackHeight）',
      );
    }
    if (w * h > _maxImagePixels) {
      throw DjvuFormatException('JB2 输出位图过大：$w×$h');
    }
    final out = DjvuBitmap(w, h);
    for (final b in _blits) {
      final shape = _shapeOrNull(b.shape);
      if (shape == null) continue;
      _renderShape(out, shape, b.left, b.bottom);
    }
    return out;
  }

  /// 解一个 `Djbz`：只允许库符号记录，返回字典。
  DjvuJb2Dictionary runDictionary() {
    _decodeDictionaryRecords();
    if (!_gotStartRecord) {
      throw DjvuFormatException('JB2 字典流缺少 START_OF_DATA 记录');
    }
    // 字典路径里每个符号都进了库（lib 下标 == 符号下标），libinfo 即包围盒。
    final boxes = <_LibRect>[
      for (var i = _inheritedShapes; i < _shapeCount; i++) _libinfo[i],
    ];
    return DjvuJb2Dictionary._(List<_Jb2Shape>.of(_shapes), boxes);
  }

  void _renderShape(DjvuBitmap out, _Shape shape, int left, int bottom) {
    final w = out.width;
    final h = out.height;
    final sw = shape.width;
    final sh = shape.height;
    final pixels = out.pixels;
    for (var r = 0; r < sh; r++) {
      // 内部 row 0 是最下面一行；输出 y=0 是最上面一行。
      final y = h - 1 - (bottom + r);
      if (y < 0 || y >= h) continue;
      final dst = y * w;
      final src = r * shape.stride + shape.colPad;
      for (var c = 0; c < sw; c++) {
        if (shape.data[src + c] == 0) continue;
        final x = left + c;
        if (x >= 0 && x < w) pixels[dst + x] = 1;
      }
    }
  }

  // ------------------------------------------------------------ 记录循环

  void _decodeImageRecords() {
    while (true) {
      _tickRecord();
      final rectype = _num.codeNum(_startOfData, _endOfData, _ctRecordType);
      switch (rectype) {
        case _startOfData:
          _imageColumns = _num.codeNum(0, _bigPositive, _ctImageSize);
          _imageRows = _num.codeNum(0, _bigPositive, _ctImageSize);
          if (_imageColumns == 0) _imageColumns = fallbackWidth;
          if (_imageRows == 0) _imageRows = fallbackHeight;
          // “事件性无损精修”标志：JB2 解码路径不使用，读掉即可。
          _zp.decode(_bcRefinementFlag);
          _imageStartImage();
          _initLibrary();
          break;
        case _newMark:
          final bm = _absoluteMarkSize();
          _bitmapDirectly(bm);
          final shp = _Jb2Shape(bm, -1);
          final blit = _relativeLocation(bm.height, bm.width);
          _addShape(shp);
          _addLibrary(shp);
          _addBlit(_Blit(_shapeCount - 1, blit.left, blit.bottom));
          break;
        case _newMarkLibraryOnly:
          final bm = _absoluteMarkSize();
          _bitmapDirectly(bm);
          final shp = _Jb2Shape(bm, -1);
          _addShape(shp);
          _addLibrary(shp);
          break;
        case _newMarkImageOnly:
          final bm = _absoluteMarkSize();
          _bitmapDirectly(bm);
          final shp = _Jb2Shape(bm, -1);
          final blit = _relativeLocation(bm.height, bm.width);
          _addShape(shp);
          _addBlit(_Blit(_shapeCount - 1, blit.left, blit.bottom));
          break;
        case _matchedRefine:
          final shp = _Jb2Shape(null, -1);
          final match = _matchIndex();
          shp.parent = _lib2shape[match];
          final cbm = _shapeBits(shp.parent);
          final l = _libinfo[match];
          final bm = _relativeMarkSize(
            l.right - l.left + 1,
            l.top - l.bottom + 1,
          );
          _bitmapByCrossCoding(bm, cbm, match);
          shp.bits = bm;
          final blit = _relativeLocation(bm.height, bm.width);
          _addShape(shp);
          _addLibrary(shp);
          _addBlit(_Blit(_shapeCount - 1, blit.left, blit.bottom));
          break;
        case _matchedRefineLibraryOnly:
          final shp = _Jb2Shape(null, -1);
          final match = _matchIndex();
          shp.parent = _lib2shape[match];
          final l = _libinfo[match];
          // 与参考实现的图像记录路径一致：仅图像记录里的"仅库"精修
          // **只编码相对尺寸**（不编码像素），得到一张全零位图。
          final bm = _relativeMarkSize(
            l.right - l.left + 1,
            l.top - l.bottom + 1,
          );
          shp.bits = bm;
          _addShape(shp);
          _addLibrary(shp);
          break;
        case _matchedRefineImageOnly:
          final shp = _Jb2Shape(null, -1);
          final match = _matchIndex();
          shp.parent = _lib2shape[match];
          final cbm = _shapeBits(shp.parent);
          final l = _libinfo[match];
          final bm = _relativeMarkSize(
            l.right - l.left + 1,
            l.top - l.bottom + 1,
          );
          _bitmapByCrossCoding(bm, cbm, match);
          shp.bits = bm;
          final blit = _relativeLocation(bm.height, bm.width);
          _addShape(shp);
          _addBlit(_Blit(_shapeCount - 1, blit.left, blit.bottom));
          break;
        case _matchedCopy:
          final match = _matchIndex();
          final shapeno = _lib2shape[match];
          final l = _libinfo[match];
          // 参考实现用包围盒尺寸做相对定位（reproduce_old_bug 分支除外）。
          final blit = _relativeLocation(
            l.top - l.bottom + 1,
            l.right - l.left + 1,
          );
          blit.left -= l.left;
          blit.bottom -= l.bottom;
          _addBlit(_Blit(shapeno, blit.left, blit.bottom));
          break;
        case _nonMarkData:
          final bm = _absoluteMarkSize();
          _bitmapDirectly(bm);
          final shp = _Jb2Shape(bm, -2);
          final blit = _absoluteLocation(bm.height, bm.width);
          _addShape(shp);
          _addBlit(_Blit(_shapeCount - 1, blit.left, blit.bottom));
          break;
        case _requiredDictOrReset:
          if (!_gotStartRecord) {
            _codeInheritedShapeCount();
          } else {
            _num.reset(_allNumRoots);
          }
          break;
        case _preservedComment:
          _codeComment();
          break;
        case _endOfData:
          return;
        default:
          throw DjvuUnsupportedException('JB2 图像出现未知记录类型 $rectype');
      }
    }
  }

  void _decodeDictionaryRecords() {
    while (true) {
      _tickRecord();
      final rectype = _num.codeNum(_startOfData, _endOfData, _ctRecordType);
      switch (rectype) {
        case _startOfData:
          final w = _num.codeNum(0, _bigPositive, _ctImageSize);
          final h = _num.codeNum(0, _bigPositive, _ctImageSize);
          if (w != 0 || h != 0) {
            throw DjvuFormatException(
              'JB2 字典的 START_OF_DATA 宽高必须为 0（读到 $w×$h）',
            );
          }
          // “事件性无损精修”标志：JB2 解码路径不使用，读掉即可。
          _zp.decode(_bcRefinementFlag);
          _imageStartDict();
          _initLibrary();
          break;
        case _newMarkLibraryOnly:
          final bm = _absoluteMarkSize();
          _bitmapDirectly(bm);
          final shp = _Jb2Shape(bm, -1);
          _addShape(shp);
          _addLibrary(shp);
          break;
        case _matchedRefineLibraryOnly:
          final shp = _Jb2Shape(null, -1);
          final match = _matchIndex();
          shp.parent = _lib2shape[match];
          final cbm = _shapeBits(shp.parent);
          final l = _libinfo[match];
          final bm = _relativeMarkSize(
            l.right - l.left + 1,
            l.top - l.bottom + 1,
          );
          _bitmapByCrossCoding(bm, cbm, match);
          shp.bits = bm;
          _addShape(shp);
          _addLibrary(shp);
          break;
        case _requiredDictOrReset:
          if (!_gotStartRecord) {
            _codeInheritedShapeCount();
          } else {
            _num.reset(_allNumRoots);
          }
          break;
        case _preservedComment:
          _codeComment();
          break;
        case _endOfData:
          return;
        default:
          throw DjvuUnsupportedException('JB2 字典（Djbz）中出现仅图像记录类型 $rectype');
      }
    }
  }

  void _tickRecord() {
    _records++;
    if (_records > _maxRecords) {
      throw DjvuFormatException('JB2 记录数超过上限 $_maxRecords（疑似损坏或成环）');
    }
  }

  // ------------------------------------------------------------ 数字/注释

  void _codeComment() {
    final size = _num.codeNum(0, _bigPositive, _ctCommentLength);
    if (size > _maxCommentBytes) {
      throw DjvuFormatException('JB2 注释长度 $size 超过上限 $_maxCommentBytes');
    }
    for (var i = 0; i < size; i++) {
      _num.codeNum(0, 255, _ctCommentByte);
    }
  }

  void _codeInheritedShapeCount() {
    final size = _num.codeNum(0, _bigPositive, _ctInheritedCount);
    if (size == 0) {
      if (dict != null && dict!._shapeCount != 0) {
        throw DjvuFormatException(
          'JB2 流声明不需要字典（0），但调用方提供了 ${dict!._shapeCount} 个符号',
        );
      }
      return;
    }
    if (dict == null) {
      throw DjvuUnsupportedException(
        'JB2 流要求 $size 个共享符号（require_dictionary），但未提供可解析的 Djbz 字典',
      );
    }
    if (size != dict!._shapeCount) {
      throw DjvuFormatException(
        'JB2 流声明的字典大小为 $size，实际字典有 ${dict!._shapeCount} 个符号',
      );
    }
    _inheritedShapes = size;
  }

  // ------------------------------------------------------------ 尺寸/定位

  void _imageStartImage() {
    _lastLeft = 1 + _imageColumns;
    _lastRowLeft = 0;
    _lastRowBottom = _imageRows;
    _lastRight = 0;
    _fillShortList(_imageRows);
    _gotStartRecord = true;
  }

  void _imageStartDict() {
    _lastLeft = 1;
    _lastRowLeft = 0;
    _lastRowBottom = 0;
    _lastRight = 0;
    _fillShortList(0);
    _gotStartRecord = true;
  }

  void _fillShortList(int v) {
    _shortList[0] = v;
    _shortList[1] = v;
    _shortList[2] = v;
    _shortListPos = 0;
  }

  int _updateShortList(int v) {
    _shortListPos++;
    if (_shortListPos == 3) _shortListPos = 0;
    final s = _shortList;
    s[_shortListPos] = v;
    if (s[0] >= s[1]) {
      if (s[0] > s[2]) return s[1] >= s[2] ? s[1] : s[2];
      return s[0];
    }
    if (s[0] < s[2]) return s[1] >= s[2] ? s[2] : s[1];
    return s[0];
  }

  int _getDiff(_NumCtx ctx) => _num.codeNum(_bigNegative, _bigPositive, ctx);

  _Blit _relativeLocation(int rows, int columns) {
    if (!_gotStartRecord) {
      throw DjvuFormatException('JB2 相对定位出现在 START_OF_DATA 之前');
    }
    final newRow = _zp.decode(_bcOffsetType) != 0;
    int left;
    int bottom;
    int right;
    int top;
    if (newRow) {
      final xDiff = _getDiff(_ctRelLocXLast);
      final yDiff = _getDiff(_ctRelLocYLast);
      left = _lastRowLeft + xDiff;
      top = _lastRowBottom + yDiff;
      right = left + columns - 1;
      bottom = top - rows + 1;
      _lastLeft = _lastRowLeft = left;
      _lastRight = right;
      _lastBottom = _lastRowBottom = bottom;
      _fillShortList(bottom);
    } else {
      final xDiff = _getDiff(_ctRelLocXCurrent);
      final yDiff = _getDiff(_ctRelLocYCurrent);
      left = _lastRight + xDiff;
      bottom = _lastBottom + yDiff;
      right = left + columns - 1;
      top = bottom + rows - 1;
      _lastLeft = left;
      _lastRight = right;
      _lastBottom = _updateShortList(bottom);
    }
    return _Blit(0, left - 1, bottom - 1);
  }

  _Blit _absoluteLocation(int rows, int columns) {
    if (!_gotStartRecord) {
      throw DjvuFormatException('JB2 绝对定位出现在 START_OF_DATA 之前');
    }
    final left = _num.codeNum(1, _imageColumns, _ctAbsLocX);
    final top = _num.codeNum(1, _imageRows, _ctAbsLocY);
    return _Blit(0, left - 1, top - rows + 1 - 1);
  }

  // ------------------------------------------------------------ 符号

  _Shape _absoluteMarkSize() {
    final xsize = _num.codeNum(0, _bigPositive, _ctAbsSizeX);
    final ysize = _num.codeNum(0, _bigPositive, _ctAbsSizeY);
    if (xsize > 0xffff || ysize > 0xffff) {
      throw DjvuFormatException('JB2 符号绝对尺寸放不进 16 位：$xsize×$ysize');
    }
    return _newShape(xsize, ysize);
  }

  _Shape _relativeMarkSize(int cw, int ch) {
    final xsize = cw + _num.codeNum(_bigNegative, _bigPositive, _ctRelSizeX);
    final ysize = ch + _num.codeNum(_bigNegative, _bigPositive, _ctRelSizeY);
    if (xsize < 0 || xsize > 0xffff || ysize < 0 || ysize > 0xffff) {
      throw DjvuFormatException('JB2 符号相对尺寸非法：$xsize×$ysize');
    }
    return _newShape(xsize, ysize);
  }

  _Shape _newShape(int w, int h) {
    final area = w * h;
    if (area > _maxShapePixels) {
      throw DjvuFormatException('JB2 单个符号位图过大：$w×$h');
    }
    _totalShapePixels += area;
    if (_totalShapePixels > _maxTotalShapePixels) {
      throw DjvuFormatException('JB2 全部符号位图累计像素超过上限 $_maxTotalShapePixels');
    }
    return _Shape(w, h);
  }

  int _matchIndex() {
    if (_lib2shape.isEmpty) {
      throw DjvuFormatException('JB2 匹配记录出现时符号库为空');
    }
    return _num.codeNum(0, _lib2shape.length - 1, _ctMatchIndex);
  }

  void _addShape(_Jb2Shape shp) {
    if (shp.parent >= _shapeCount) {
      throw DjvuFormatException('JB2 符号父下标 ${shp.parent} 超出符号总数 $_shapeCount');
    }
    if (_shapes.length >= _maxShapes) {
      throw DjvuFormatException('JB2 符号数超过上限 $_maxShapes');
    }
    _shapes.add(shp);
  }

  void _addLibrary(_Jb2Shape shp) {
    final shapeIndex = _shapeCount - 1;
    _lib2shape.add(shapeIndex);
    _libinfo.add(_boundingBox(shp.bits!));
  }

  void _addBlit(_Blit b) {
    if (_blits.length >= _maxBlits) {
      throw DjvuFormatException('JB2 贴图数超过上限 $_maxBlits');
    }
    _blits.add(b);
  }

  void _initLibrary() {
    _lib2shape.clear();
    _libinfo.clear();
    final d = dict;
    for (var i = 0; i < _inheritedShapes; i++) {
      if (d == null || i >= d._shapeCount) {
        throw DjvuFormatException('JB2 继承字典缺少符号 $i');
      }
      _lib2shape.add(i);
      _libinfo.add(d._boxes[i]);
    }
  }

  /// 取符号位图（继承或自有）；null 位图 → 坏文件。
  _Shape _shapeBits(int i) {
    final s = _shapeOrNull(i);
    if (s == null) {
      throw DjvuFormatException('JB2 符号 $i 没有位图，无法作为交叉编码参照');
    }
    return s;
  }

  _Shape? _shapeOrNull(int i) {
    if (i < 0) return null;
    if (i < _inheritedShapes) {
      final d = dict;
      if (d == null || i >= d._shapeCount) return null;
      return d._shapes[i].bits;
    }
    final k = i - _inheritedShapes;
    if (k >= _shapes.length) return null;
    return _shapes[k].bits;
  }

  // ------------------------------------------------------------ 位图解码

  void _bitmapDirectly(_Shape bm) {
    bm.ensureColPad(4);
    final dw = bm.width;
    for (var dy = bm.height - 1; dy >= 0; dy--) {
      var context = _directContext(bm, dy + 2, dy + 1, dy, 0);
      for (var dx = 0; dx < dw;) {
        final n = _zp.decodeAt(_bitdist, context);
        bm.setPx(dy, dx, n);
        dx++;
        context = _shiftDirectContext(context, n, bm, dy + 2, dy + 1, dy, dx);
      }
    }
  }

  void _bitmapByCrossCoding(_Shape bm, _Shape cbm, int libno) {
    final cw = cbm.width;
    final dw = bm.width;
    final dh = bm.height;
    final l = _libinfo[libno];
    final xd2c = (dw ~/ 2 - dw + 1) - ((l.right - l.left + 1) ~/ 2 - l.right);
    final yd2c = (dh ~/ 2 - dh + 1) - ((l.top - l.bottom + 1) ~/ 2 - l.top);
    bm.ensureColPad(2);
    final need = 2 - xd2c > 2 + dw + xd2c - cw ? 2 - xd2c : 2 + dw + xd2c - cw;
    cbm.ensureColPad(need);
    final dy0 = dh - 1;
    final cy0 = dy0 + yd2c;
    for (var i = 0; i < dh; i++) {
      final dy = dy0 - i;
      final cy = cy0 - i;
      var context = _crossContext(
        bm,
        dy + 1,
        dy,
        cbm,
        cy + 1,
        cy,
        cy - 1,
        xd2c,
        0,
      );
      for (var dx = 0; dx < dw;) {
        final n = _zp.decodeAt(_cbitdist, context);
        bm.setPx(dy, dx, n);
        dx++;
        context = _shiftCrossContext(
          context,
          n,
          bm,
          dy + 1,
          dy,
          cbm,
          cy + 1,
          cy,
          cy - 1,
          xd2c,
          dx,
        );
      }
    }
  }

  // 上下文模板（按公开规范/算法事实重述）
  int _directContext(_Shape bm, int r2, int r1, int r0, int column) =>
      (bm.px(r2, column - 1) << 9) |
      (bm.px(r2, column) << 8) |
      (bm.px(r2, column + 1) << 7) |
      (bm.px(r1, column - 2) << 6) |
      (bm.px(r1, column - 1) << 5) |
      (bm.px(r1, column) << 4) |
      (bm.px(r1, column + 1) << 3) |
      (bm.px(r1, column + 2) << 2) |
      (bm.px(r0, column - 2) << 1) |
      bm.px(r0, column - 1);

  int _shiftDirectContext(
    int context,
    int next,
    _Shape bm,
    int r2,
    int r1,
    int r0,
    int column,
  ) =>
      ((context << 1) & 0x37a) |
      (bm.px(r1, column + 2) << 2) |
      (bm.px(r2, column + 1) << 7) |
      next;

  int _crossContext(
    _Shape bm,
    int d1,
    int d0,
    _Shape cbm,
    int c1,
    int c0,
    int cm1,
    int xd2c,
    int column,
  ) =>
      (bm.px(d1, column - 1) << 10) |
      (bm.px(d1, column) << 9) |
      (bm.px(d1, column + 1) << 8) |
      (bm.px(d0, column - 1) << 7) |
      (cbm.px(c1, column + xd2c) << 6) |
      (cbm.px(c0, column + xd2c - 1) << 5) |
      (cbm.px(c0, column + xd2c) << 4) |
      (cbm.px(c0, column + xd2c + 1) << 3) |
      (cbm.px(cm1, column + xd2c - 1) << 2) |
      (cbm.px(cm1, column + xd2c) << 1) |
      cbm.px(cm1, column + xd2c + 1);

  int _shiftCrossContext(
    int context,
    int n,
    _Shape bm,
    int d1,
    int d0,
    _Shape cbm,
    int c1,
    int c0,
    int cm1,
    int xd2c,
    int column,
  ) =>
      ((context << 1) & 0x636) |
      (bm.px(d1, column + 1) << 8) |
      (cbm.px(c1, column + xd2c) << 6) |
      (cbm.px(c0, column + xd2c + 1) << 3) |
      cbm.px(cm1, column + xd2c + 1) |
      (n << 7);
}

// ---------------------------------------------------------------- 编码器

/// 极简 JB2 编码器：只产出"一条 NEW_MARK + 一条相对定位"的合法流。
class _Jb2Encoder {
  _Jb2Encoder(this._zp) : _num = _NumCoder.encoder(_zp);

  final ZpEncoder _zp;
  final _NumCoder _num;

  final ZpContextArray _bitdist = ZpContextArray(1024);

  int _imageColumns = 0;
  int _imageRows = 0;
  int _lastLeft = 0;
  int _lastRowLeft = 0;
  int _lastRowBottom = 0;
  int _lastRight = 0;
  int _lastBottom = 0;
  final List<int> _shortList = <int>[0, 0, 0];
  int _shortListPos = 0;

  final _NumCtx _ctRecordType = _NumCtx();
  final _NumCtx _ctAbsSizeX = _NumCtx();
  final _NumCtx _ctAbsSizeY = _NumCtx();
  final _NumCtx _ctImageSize = _NumCtx();
  final _NumCtx _ctRelLocXLast = _NumCtx();
  final _NumCtx _ctRelLocYLast = _NumCtx();
  final _NumCtx _ctRelLocXCurrent = _NumCtx();
  final _NumCtx _ctRelLocYCurrent = _NumCtx();

  final ZpBitContext _bcRefinementFlag = ZpBitContext();
  final ZpBitContext _bcOffsetType = ZpBitContext();

  Uint8List encodeLiteral(_Shape bm) {
    _imageColumns = bm.width;
    _imageRows = bm.height;
    _num.codeNum(_startOfData, _endOfData, _ctRecordType, _startOfData);
    _num.codeNum(0, _bigPositive, _ctImageSize, _imageColumns);
    _num.codeNum(0, _bigPositive, _ctImageSize, _imageRows);
    _zp.encode(_bcRefinementFlag, 0);
    _imageStartImage();
    _num.codeNum(_startOfData, _endOfData, _ctRecordType, _newMark);
    _num.codeNum(0, _bigPositive, _ctAbsSizeX, bm.width);
    _num.codeNum(0, _bigPositive, _ctAbsSizeY, bm.height);
    _bitmapDirectly(bm);
    _relativeLocationEncode(0, 0, bm.height, bm.width);
    _num.codeNum(_startOfData, _endOfData, _ctRecordType, _endOfData);
    return _zp.finish();
  }

  void _imageStartImage() {
    _lastLeft = 1 + _imageColumns;
    _lastRowLeft = 0;
    _lastRowBottom = _imageRows;
    _lastRight = 0;
    _fillShortList(_imageRows);
  }

  void _fillShortList(int v) {
    _shortList[0] = v;
    _shortList[1] = v;
    _shortList[2] = v;
    _shortListPos = 0;
  }

  int _updateShortList(int v) {
    _shortListPos++;
    if (_shortListPos == 3) _shortListPos = 0;
    final s = _shortList;
    s[_shortListPos] = v;
    if (s[0] >= s[1]) {
      if (s[0] > s[2]) return s[1] >= s[2] ? s[1] : s[2];
      return s[0];
    }
    if (s[0] < s[2]) return s[1] >= s[2] ? s[2] : s[1];
    return s[0];
  }

  void _bitmapDirectly(_Shape bm) {
    bm.ensureColPad(4);
    final dw = bm.width;
    for (var dy = bm.height - 1; dy >= 0; dy--) {
      var context = _directContext(bm, dy + 2, dy + 1, dy, 0);
      for (var dx = 0; dx < dw;) {
        final n = bm.px(dy, dx);
        _zp.encodeAt(_bitdist, context, n);
        dx++;
        context = _shiftDirectContext(context, n, bm, dy + 2, dy + 1, dy, dx);
      }
    }
  }

  void _relativeLocationEncode(int left0, int bottom0, int rows, int columns) {
    final left = left0 + 1;
    final bottom = bottom0 + 1;
    final right = left + columns - 1;
    final top = bottom + rows - 1;
    final newRow = left < _lastLeft;
    _zp.encode(_bcOffsetType, newRow ? 1 : 0);
    if (newRow) {
      _num.codeNum(
        _bigNegative,
        _bigPositive,
        _ctRelLocXLast,
        left - _lastRowLeft,
      );
      _num.codeNum(
        _bigNegative,
        _bigPositive,
        _ctRelLocYLast,
        top - _lastRowBottom,
      );
      _lastLeft = _lastRowLeft = left;
      _lastRight = right;
      _lastBottom = _lastRowBottom = bottom;
      _fillShortList(bottom);
    } else {
      _num.codeNum(
        _bigNegative,
        _bigPositive,
        _ctRelLocXCurrent,
        left - _lastRight,
      );
      _num.codeNum(
        _bigNegative,
        _bigPositive,
        _ctRelLocYCurrent,
        bottom - _lastBottom,
      );
      _lastLeft = left;
      _lastRight = right;
      _lastBottom = _updateShortList(bottom);
    }
  }

  int _directContext(_Shape bm, int r2, int r1, int r0, int column) =>
      (bm.px(r2, column - 1) << 9) |
      (bm.px(r2, column) << 8) |
      (bm.px(r2, column + 1) << 7) |
      (bm.px(r1, column - 2) << 6) |
      (bm.px(r1, column - 1) << 5) |
      (bm.px(r1, column) << 4) |
      (bm.px(r1, column + 1) << 3) |
      (bm.px(r1, column + 2) << 2) |
      (bm.px(r0, column - 2) << 1) |
      bm.px(r0, column - 1);

  int _shiftDirectContext(
    int context,
    int next,
    _Shape bm,
    int r2,
    int r1,
    int r0,
    int column,
  ) =>
      ((context << 1) & 0x37a) |
      (bm.px(r1, column + 2) << 2) |
      (bm.px(r2, column + 1) << 7) |
      next;
}

// ---------------------------------------------------------------- 包围盒

_LibRect _boundingBox(_Shape bm) {
  final w = bm.width;
  final h = bm.height;
  var right = w - 1;
  while (right >= 0 && !_columnHasInk(bm, right)) {
    right--;
  }
  var top = h - 1;
  while (top >= 0 && !_rowHasInk(bm, top)) {
    top--;
  }
  var left = 0;
  while (left <= right && !_columnHasInk(bm, left)) {
    left++;
  }
  var bottom = 0;
  while (bottom <= top && !_rowHasInk(bm, bottom)) {
    bottom++;
  }
  return _LibRect(left, right, top, bottom);
}

bool _columnHasInk(_Shape bm, int col) {
  for (var r = 0; r < bm.height; r++) {
    if (bm.px(r, col) != 0) return true;
  }
  return false;
}

bool _rowHasInk(_Shape bm, int row) {
  for (var c = 0; c < bm.width; c++) {
    if (bm.px(row, c) != 0) return true;
  }
  return false;
}
