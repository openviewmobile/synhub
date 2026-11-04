// 从图片字节的**文件头**读出像素尺寸 —— 不解码整张图。
//
// 为什么要它：书封/缩略图要按**真实宽高比**摆放（书的封面基本不是正方形，
// 硬塞进方框就得裁掉两边）。`Image.memory` 能自己缩放，但布局需要提前知道比例，
// 否则只能先铺一个方框再等解码回调，列表会跳一下。
//
// 只认头部：
//   * 扫描量在几百字节内（JPEG 要顺着 marker 找 SOFn，其余都是固定偏移）；
//   * 纯函数、不依赖 Flutter（方便单测与将来丢 isolate）。
//
// 认得出：PNG / JPEG(含 progressive) / GIF / WebP(VP8 / VP8L / VP8X) / BMP。
// 认不出（HEIC/AVIF、损坏字节）返回 null，调用方退到默认比例。
library;

import 'dart:typed_data';

/// 像素尺寸（宽、高）
typedef ImagePixels = ({int width, int height});

/// 读文件头拿尺寸；读不出来返回 null（**不抛异常**）。
ImagePixels? imageSizeFromBytes(Uint8List bytes) {
  if (bytes.length < 16) return null;
  try {
    if (_startsWith(bytes, const [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ])) {
      return _png(bytes);
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) return _jpeg(bytes);
    if (_startsWith(bytes, const [0x47, 0x49, 0x46, 0x38])) return _gif(bytes);
    if (_startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
        _startsWith(bytes, const [0x57, 0x45, 0x42, 0x50], at: 8)) {
      return _webp(bytes);
    }
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return _bmp(bytes);
  } catch (_) {
    // 头部残缺/越界：当作"读不出来"，别把列表搞崩
  }
  return null;
}

bool _startsWith(Uint8List bytes, List<int> magic, {int at = 0}) {
  if (bytes.length < at + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[at + i] != magic[i]) return false;
  }
  return true;
}

int _u16be(Uint8List b, int at) => (b[at] << 8) | b[at + 1];
int _u16le(Uint8List b, int at) => (b[at + 1] << 8) | b[at];
int _u32be(Uint8List b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
int _u32le(Uint8List b, int at) =>
    (b[at + 3] << 24) | (b[at + 2] << 16) | (b[at + 1] << 8) | b[at];

/// 有符号 32 位小端（BMP 的高度可以是负数 = 自上而下；Dart 的 int 是 64 位，
/// 直接 `.abs()` 会得到 4294967246 这种巨数，必须先做符号扩展）
int _i32le(Uint8List b, int at) {
  final v = _u32le(b, at);
  return v >= 0x80000000 ? v - 0x100000000 : v;
}

ImagePixels? _png(Uint8List b) {
  if (b.length < 24) return null;
  if (!_startsWith(b, const [0x49, 0x48, 0x44, 0x52], at: 12)) return null;
  final w = _u32be(b, 16);
  final h = _u32be(b, 20);
  return (w > 0 && h > 0) ? (width: w, height: h) : null;
}

/// JPEG：顺着 marker 走，碰到 SOF0..SOF15（除 DHT/JPG/DAC）就是尺寸所在段。
ImagePixels? _jpeg(Uint8List b) {
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++; // 段间填充
      continue;
    }
    var marker = b[i + 1];
    // 连续 0xFF 是填充
    while (marker == 0xFF && i + 2 < b.length) {
      i++;
      marker = b[i + 1];
    }
    i += 2;
    // 无长度字段的 marker：SOI/EOI/RSTn/TEM
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null; // EOI / 进到压缩数据
    if (i + 1 >= b.length) return null;
    final len = _u16be(b, i);
    if (len < 2) return null;
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 && // DHT
        marker != 0xC8 && // JPG
        marker != 0xCC; // DAC
    if (isSof) {
      if (i + 7 >= b.length) return null;
      final h = _u16be(b, i + 3);
      final w = _u16be(b, i + 5);
      return (w > 0 && h > 0) ? (width: w, height: h) : null;
    }
    i += len;
  }
  return null;
}

ImagePixels? _gif(Uint8List b) {
  final w = _u16le(b, 6);
  final h = _u16le(b, 8);
  return (w > 0 && h > 0) ? (width: w, height: h) : null;
}

ImagePixels? _webp(Uint8List b) {
  if (b.length < 25) return null;
  final fourcc = String.fromCharCodes(b.sublist(12, 16));
  switch (fourcc) {
    case 'VP8X':
      // 24 位小端画布尺寸（存的是 -1）
      final w = b[24] | (b[25] << 8) | (b[26] << 16);
      final h = b[27] | (b[28] << 8) | (b[29] << 16);
      return (width: w + 1, height: h + 1);
    case 'VP8 ':
      // 帧头：3 字节 tag + 0x9D 0x01 0x2A + 16 位宽高（低 14 位有效）
      if (!_startsWith(b, const [0x9D, 0x01, 0x2A], at: 23)) return null;
      final w = _u16le(b, 26) & 0x3FFF;
      final h = _u16le(b, 28) & 0x3FFF;
      return (w > 0 && h > 0) ? (width: w, height: h) : null;
    case 'VP8L':
      if (b[20] != 0x2F) return null;
      // 14 位宽-1、14 位高-1，按位紧排（小端）
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      final w = (bits & 0x3FFF) + 1;
      final h = ((bits >> 14) & 0x3FFF) + 1;
      return (w > 1 && h > 1) ? (width: w, height: h) : null;
  }
  return null;
}

ImagePixels? _bmp(Uint8List b) {
  if (b.length < 26) return null;
  final w = _u32le(b, 18);
  final h = _i32le(b, 22).abs(); // 负数 = 自上而下
  return (w > 0 && h > 0) ? (width: w, height: h) : null;
}
