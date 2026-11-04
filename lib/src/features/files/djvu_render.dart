// DJVU **合成渲染**：BG44 背景 + Sjbz 掩码 + FG44 前景 → RGBA 位图 → PNG 字节。
// 纯 Dart，零 flutter / l10n 依赖（PNG 用 `dart:io` 的 zlib，和其它预览代码同款）。
//
// 渲染口径对齐 DjVu 的位图管线（公开规范 + DjVuLibre 的 `DjVuImage::get_pixmap`）：
//
//   1. **背景**：`BG44` 解出的彩色/灰度图；没有 BG44 时用白底。
//   2. **掩码**：`Sjbz`（JB2）解出的黑白位图；没有掩码时：
//        * 有 FG44 → 整页都是前景；
//        * 没有 FG44 → 整页都是背景（纯色/白）。
//   3. **前景**：`FG44` 解出的彩色图；没有 FG44 时前景是黑色。
//   4. 逐像素：`mask ? fg : bg`。
//
// 明确边界：
//   * `Smmr`（G4 掩码）、`BGjp`/`FGjp`/`BG2k`/`FG2k`（JPEG/JPEG2000）→ 由
//     `djvu_archive.dart` 记成"不支持"，本文件**不猜**，直接抛
//     [DjvuUnsupportedException]（`book_djvu.dart` 会翻成界面文案）。
//   * `FGbz` 调色板块被忽略（`DjVuImage::get_pixmap` 也不消费它）。
//   * 旋转（INFO 的 orientation）在这里做，输出宽高按需交换。
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'djvu_archive.dart';
import 'djvu_iw44.dart';
import 'djvu_jb2.dart';

/// 解出来的 RGBA 位图（`width * height * 4`）。
class DjvuRgba {
  DjvuRgba(this.width, this.height) : pixels = Uint8List(width * height * 4);
  final int width;
  final int height;
  final Uint8List pixels;

  void set(int x, int y, int r, int g, int b, [int a = 255]) {
    final i = (y * width + x) * 4;
    pixels[i] = r;
    pixels[i + 1] = g;
    pixels[i + 2] = b;
    pixels[i + 3] = a;
  }

  /// 取通道值（越界给 0，不抛）。
  int _channel(int x, int y, int c) {
    if (x < 0 || y < 0 || x >= width || y >= height) return 0;
    return pixels[(y * width + x) * 4 + c];
  }

  int r(int x, int y) => _channel(x, y, 0);
  int g(int x, int y) => _channel(x, y, 1);
  int b(int x, int y) => _channel(x, y, 2);
  int a(int x, int y) => _channel(x, y, 3);
}

/// 把一个页面合成成 RGBA 位图。
///
/// [dictionary] 是多页/跨块共享的 JB2 字典（一般传 null，页内自带 `Djbz`）。
DjvuRgba djvuRenderPage(DjvuPage page, {DjvuJb2Dictionary? dictionary}) {
  if (page.unsupported.isNotEmpty) {
    throw DjvuUnsupportedException(
      '这一页用了未实现的编码 ${page.unsupported.join(' / ')}',
    );
  }

  // ---- 尺寸：优先 INFO，其次从 IW44/JB2 自己的头里取
  var width = page.info?.width ?? 0;
  var height = page.info?.height ?? 0;

  // ---- 背景（BG44；退到 TH44 缩略图）
  //
  // **关键（真实样本验证）**：BG44/FG44 在 DjVu 里通常是**降采样存储**的
  // （DJVU 规范允许 red=1..12）。例如 1998_lossy_masked 的页是 2556x3300，
  // 而 BG44 头里是 852x1100（red=3）、FG44 头里是 213x275（red=12）。
  // 因此这里**不能**用 INFO 尺寸去覆盖 IW44 的头尺寸（那会让解码器以为有
  // 80x104 个 32x32 块、把 ZP 流读穿），而要按头尺寸解出，再按比例放大到
  // INFO 页尺寸。参考实现对应 `DjVuImage::get_bg_pixmap` 的 `compute_red` +
  // `GPixmapScaler`。
  final bgChunks = page.bg44.isNotEmpty ? page.bg44 : page.th44;
  DjvuIw44Pixels? bg;
  if (bgChunks.isNotEmpty) {
    bg = djvuIw44Decode(bgChunks);
    if (width == 0 || height == 0) {
      width = bg.width;
      height = bg.height;
    }
  }

  // ---- 掩码（Sjbz）——掩码必须是整页分辨率（规范要求与 INFO 一致）
  DjvuBitmap? mask;
  if (page.sjbz != null) {
    mask = djvuJb2Decode(
      page.sjbz!,
      width: width,
      height: height,
      // 页面自带的 Djbz 优先；调用方传入的共享字典兜底
      dictionary: _pageDictionary(page) ?? dictionary,
    );
    if (width == 0 || height == 0) {
      width = mask.width;
      height = mask.height;
    }
  }

  if (width <= 0 || height <= 0) {
    throw DjvuFormatException('这一页没有可用的宽高（INFO/位图都缺）');
  }

  // ---- 前景（FG44，同样可能是降采样）
  DjvuIw44Pixels? fg;
  if (page.fg44.isNotEmpty) {
    fg = djvuIw44Decode(page.fg44);
  }

  // IW44 层按比例放大到页尺寸（整数倍时是"块平均/中心采样"，非整数倍走双线性）
  final bgS = bg == null ? null : _Scaled(bg, width, height);
  final fgS = fg == null ? null : _Scaled(fg, width, height);

  final out = DjvuRgba(width, height);
  final hasMask = mask != null;
  final fgIsWholePage = !hasMask && fgS != null;

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final useFg = hasMask ? mask.at(x, y) : fgIsWholePage;
      if (useFg) {
        if (fgS != null) {
          out.set(
            x,
            y,
            fgS.sample(x, y, 0),
            fgS.sample(x, y, 1),
            fgS.sample(x, y, 2),
          );
        } else {
          out.set(x, y, 0, 0, 0);
        }
      } else if (bgS != null) {
        out.set(
          x,
          y,
          bgS.sample(x, y, 0),
          bgS.sample(x, y, 1),
          bgS.sample(x, y, 2),
        );
      } else {
        out.set(x, y, 255, 255, 255);
      }
    }
  }

  // ---- 旋转
  final o = page.info?.orientation ?? 0;
  if (o == 1) return _rotate90(out);
  if (o == 2) return _rotate180(out);
  if (o == 3) return _rotate270(out);
  return out;
}

/// 把一张（可能降采样的）IW44 图放大到目标尺寸并取通道值。
///
/// 整数倍时等价于按比例抽样；非整数倍时走双线性。DjVu 的原始实现用
/// `GPixmapScaler`（同一族插值），这里不追逐步进一致的浮点细节，只保证
/// 几何正确、无越界、无半截。
class _Scaled {
  _Scaled(this.src, this.outW, this.outH);
  final DjvuIw44Pixels src;
  final int outW;
  final int outH;

  bool get _identity => src.width == outW && src.height == outH;

  int _raw(int x, int y, int c) {
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= src.width) x = src.width - 1;
    if (y >= src.height) y = src.height - 1;
    if (src.channels >= 3) {
      final i = (y * src.width + x) * 3 + c;
      return i < src.data.length ? src.data[i] : 255;
    }
    final i = y * src.width + x;
    return i < src.data.length ? src.data[i] : 255;
  }

  int sample(int x, int y, int c) {
    if (_identity) return _raw(x, y, c);
    if (outW <= 0 || outH <= 0 || src.width <= 0 || src.height <= 0) return 255;
    // 把输出像素中心映射回源坐标
    final fx = (x + 0.5) * src.width / outW - 0.5;
    final fy = (y + 0.5) * src.height / outH - 0.5;
    final x0 = fx.floor();
    final y0 = fy.floor();
    final dx = fx - x0;
    final dy = fy - y0;
    final v00 = _raw(x0, y0, c);
    final v10 = _raw(x0 + 1, y0, c);
    final v01 = _raw(x0, y0 + 1, c);
    final v11 = _raw(x0 + 1, y0 + 1, c);
    final v =
        (1 - dx) * (1 - dy) * v00 +
        dx * (1 - dy) * v10 +
        (1 - dx) * dy * v01 +
        dx * dy * v11;
    return v.round().clamp(0, 255);
  }
}

/// 收集页内 `Djbz` 字典（页级；跨页共享字典由调用方通过 `dictionary` 传入）。
DjvuJb2Dictionary? _pageDictionary(DjvuPage page) {
  if (page.djbz == null) return null;
  return djvuJb2DictionaryDecode(page.djbz!);
}

DjvuRgba _rotate90(DjvuRgba src) {
  // 逆时针 90°：新宽 = 原高
  final out = DjvuRgba(src.height, src.width);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      out.set(y, src.width - 1 - x, src.r(x, y), src.g(x, y), src.b(x, y));
    }
  }
  return out;
}

DjvuRgba _rotate180(DjvuRgba src) {
  final out = DjvuRgba(src.width, src.height);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      out.set(
        src.width - 1 - x,
        src.height - 1 - y,
        src.r(x, y),
        src.g(x, y),
        src.b(x, y),
      );
    }
  }
  return out;
}

DjvuRgba _rotate270(DjvuRgba src) {
  final out = DjvuRgba(src.height, src.width);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      out.set(src.height - 1 - y, x, src.r(x, y), src.g(x, y), src.b(x, y));
    }
  }
  return out;
}

/// 合成并把一页编码成 **PNG 字节**（交给漫画翻页管线 `Image.memory`）。
Uint8List djvuRenderPagePng(DjvuPage page, {DjvuJb2Dictionary? dictionary}) {
  final rgba = djvuRenderPage(page, dictionary: dictionary);
  return djvuEncodePng(rgba);
}

/// IW44 像素（1/3 通道）→ RGBA。
DjvuRgba djvuIw44ToRgba(DjvuIw44Pixels p) {
  final out = DjvuRgba(p.width, p.height);
  for (var y = 0; y < p.height; y++) {
    for (var x = 0; x < p.width; x++) {
      out.set(x, y, p.r(x, y), p.g(x, y), p.b(x, y));
    }
  }
  return out;
}

/// 给 [DjvuIw44Pixels] 加按像素取通道的便捷方法（1 通道时三通道相同）。
extension DjvuIw44Access on DjvuIw44Pixels {
  int _sample(int x, int y, int channel) {
    if (x < 0 || y < 0 || x >= width || y >= height) return 255;
    if (channels >= 3) {
      final i = (y * width + x) * 3 + channel;
      return i < data.length ? data[i] : 255;
    }
    final i = y * width + x;
    return i < data.length ? data[i] : 255;
  }

  int r(int x, int y) => _sample(x, y, 0);
  int g(int x, int y) => channels >= 3 ? _sample(x, y, 1) : _sample(x, y, 0);
  int b(int x, int y) => channels >= 3 ? _sample(x, y, 2) : _sample(x, y, 0);
}

/// 白页（页里没有位图块时的占位；尺寸来自 INFO）
Uint8List djvuBlankPagePng(int width, int height) {
  final img = DjvuRgba(width, height);
  for (var i = 0; i < img.pixels.length; i += 4) {
    img.pixels[i] = 255;
    img.pixels[i + 1] = 255;
    img.pixels[i + 2] = 255;
    img.pixels[i + 3] = 255;
  }
  return djvuEncodePng(img);
}

// ---------------------------------------------------------------- PNG

/// 把 RGBA 位图编码成 PNG（8 位 RGBA，无隔行）。纯手写，只用 zlib。
Uint8List djvuEncodePng(DjvuRgba img) {
  final w = img.width;
  final h = img.height;
  if (w <= 0 || h <= 0) throw DjvuFormatException('PNG 尺寸非法：$w×$h');

  // 原始扫描线：每行前加一个 filter 字节 0
  final raw = Uint8List(h * (1 + w * 4));
  var p = 0;
  for (var y = 0; y < h; y++) {
    raw[p++] = 0;
    raw.setRange(p, p + w * 4, img.pixels, y * w * 4);
    p += w * 4;
  }
  final compressed = Uint8List.fromList(ZLibEncoder().convert(raw));

  final out = BytesBuilder(copy: false);
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = BytesBuilder(copy: false)
    ..add(_be32(w))
    ..add(_be32(h))
    ..add(const [8, 6, 0, 0, 0]);
  _writeChunk(out, 'IHDR', ihdr.toBytes());
  _writeChunk(out, 'IDAT', compressed);
  _writeChunk(out, 'IEND', Uint8List(0));
  return out.toBytes();
}

void _writeChunk(BytesBuilder out, String type, Uint8List data) {
  out.add(_be32(data.length));
  final typeBytes = Uint8List.fromList([for (final c in type.codeUnits) c]);
  final crcInput = Uint8List(typeBytes.length + data.length)
    ..setRange(0, typeBytes.length, typeBytes)
    ..setRange(typeBytes.length, typeBytes.length + data.length, data);
  out.add(typeBytes);
  out.add(data);
  out.add(_be32(_crc32(crcInput)));
}

List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int _crc32(Uint8List data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
