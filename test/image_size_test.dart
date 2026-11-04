// 图片头尺寸解析（`imageSizeFromBytes`）—— 布局要靠它按真实比例摆书封。
//
// 素材全部在 Dart 里手拼（仓库不放二进制），并且**逐个格式都要有**：
// 少认一个格式，那种封面就会被当成正方形塞进方框里裁掉。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/image_size.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

/// 最小 PNG 头（只有 IHDR，够解析尺寸）
Uint8List png(int w, int h) {
  final b = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
    (w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF,
    (h >> 24) & 0xFF, (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF,
    0x08, 0x02, 0x00, 0x00, 0x00,
  ];
  return bytes(b);
}

/// 最小 JPEG：SOI + APP0(JFIF) + SOFn + EOI
Uint8List jpeg(int w, int h, {int sof = 0xC0}) {
  final b = <int>[0xFF, 0xD8];
  // APP0 段（16 字节）
  // APP0 段长 16（含 2 字节长度字段）→ 内容 14 字节：'JFIF\0'+版本2+单位1+密度4+缩略图2
  b.addAll([0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00]);
  b.addAll(List.filled(9, 0));
  // SOFn
  b.addAll([0xFF, sof, 0x00, 0x11, 0x08]);
  b.addAll([(h >> 8) & 0xFF, h & 0xFF, (w >> 8) & 0xFF, w & 0xFF]);
  b.addAll(List.filled(6, 0));
  b.addAll([0xFF, 0xD9]);
  return bytes(b);
}

Uint8List gif(int w, int h) => bytes([
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, //
  w & 0xFF, (w >> 8) & 0xFF, h & 0xFF, (h >> 8) & 0xFF,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
]);

Uint8List webpVp8x(int w, int h) {
  final b = <int>[];
  b.addAll('RIFF'.codeUnits);
  b.addAll([0x00, 0x00, 0x00, 0x00]);
  b.addAll('WEBP'.codeUnits);
  b.addAll('VP8X'.codeUnits);
  b.addAll([0x0A, 0x00, 0x00, 0x00]); // 段长度
  b.addAll([0x00, 0x00, 0x00, 0x00]); // flags + 保留
  b.addAll([(w - 1) & 0xFF, ((w - 1) >> 8) & 0xFF, ((w - 1) >> 16) & 0xFF]);
  b.addAll([(h - 1) & 0xFF, ((h - 1) >> 8) & 0xFF, ((h - 1) >> 16) & 0xFF]);
  return bytes(b);
}

Uint8List webpVp8l(int w, int h) {
  final b = <int>[];
  b.addAll('RIFF'.codeUnits);
  b.addAll([0x00, 0x00, 0x00, 0x00]);
  b.addAll('WEBP'.codeUnits);
  b.addAll('VP8L'.codeUnits);
  b.addAll([0x2F, 0x00, 0x00, 0x00]);
  b.add(0x2F); // 签名
  final bits = ((w - 1) & 0x3FFF) | (((h - 1) & 0x3FFF) << 14);
  b.addAll([
    bits & 0xFF,
    (bits >> 8) & 0xFF,
    (bits >> 16) & 0xFF,
    (bits >> 24) & 0xFF,
  ]);
  return bytes(b);
}

Uint8List webpVp8(int w, int h) {
  final b = <int>[];
  b.addAll('RIFF'.codeUnits);
  b.addAll([0x00, 0x00, 0x00, 0x00]);
  b.addAll('WEBP'.codeUnits);
  b.addAll('VP8 '.codeUnits);
  b.addAll([0x00, 0x00, 0x00, 0x00]);
  b.addAll([0x00, 0x00, 0x00]); // 帧 tag
  b.addAll([0x9D, 0x01, 0x2A]); // 起始码
  b.addAll([w & 0xFF, (w >> 8) & 0x3F, h & 0xFF, (h >> 8) & 0x3F]);
  return bytes(b);
}

Uint8List bmp(int w, int h) {
  final b = <int>[
    0x42, 0x4D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
    0x36, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00,
    w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, (w >> 24) & 0xFF,
    h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF, (h >> 24) & 0xFF,
    0x01, 0x00, 0x18, 0x00,
  ];
  return bytes(b);
}

void main() {
  test('PNG：IHDR 里的宽高', () {
    expect(imageSizeFromBytes(png(1600, 2400)), (width: 1600, height: 2400));
  });

  test('JPEG：基线 SOF0 与渐进 SOF2 都要认', () {
    expect(imageSizeFromBytes(jpeg(600, 900)), (width: 600, height: 900));
    expect(imageSizeFromBytes(jpeg(600, 900, sof: 0xC2)), (
      width: 600,
      height: 900,
    ), reason: '渐进式 JPEG 用的是 SOF2');
  });

  test('JPEG：前面有 DHT/DQT 等段也要能走过去', () {
    final head = <int>[0xFF, 0xD8];
    // DQT
    head.addAll([0xFF, 0xDB, 0x00, 0x43, 0x00]);
    head.addAll(List.filled(0x41, 7));
    // DHT
    head.addAll([0xFF, 0xC4, 0x00, 0x1F, 0x00]);
    head.addAll(List.filled(0x1D, 3));
    // SOF0
    head.addAll([0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x2C, 0x00, 0xC8]);
    head.addAll(List.filled(6, 0));
    head.addAll([0xFF, 0xD9]);
    expect(imageSizeFromBytes(bytes(head)), (width: 200, height: 300));
  });

  test('GIF：逻辑屏幕描述符', () {
    expect(imageSizeFromBytes(gif(320, 240)), (width: 320, height: 240));
  });

  test('WebP：三种子格式', () {
    expect(imageSizeFromBytes(webpVp8x(800, 600)), (width: 800, height: 600));
    expect(imageSizeFromBytes(webpVp8l(512, 384)), (width: 512, height: 384));
    expect(imageSizeFromBytes(webpVp8(640, 480)), (width: 640, height: 480));
  });

  test('BMP：小端宽高，负高度（自上而下）取绝对值', () {
    expect(imageSizeFromBytes(bmp(100, 50)), (width: 100, height: 50));
    expect(imageSizeFromBytes(bmp(100, -50)), (width: 100, height: 50));
  });

  test('认不出来 / 残缺 / 空：一律返回 null，不抛异常', () {
    expect(imageSizeFromBytes(Uint8List(0)), isNull);
    expect(imageSizeFromBytes(bytes(List.filled(64, 0))), isNull);
    expect(imageSizeFromBytes(bytes([0xFF, 0xD8, 0xFF])), isNull);
    expect(imageSizeFromBytes(png(0, 0)), isNull, reason: '0 尺寸不算有效');
    // 截断的 JPEG（声称有 SOF 但没字节了）
    expect(imageSizeFromBytes(bytes([0xFF, 0xD8, 0xFF, 0xC0, 0x00])), isNull);
  });
}
