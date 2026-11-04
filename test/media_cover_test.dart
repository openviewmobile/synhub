// 内嵌封面解析（`lib/src/features/media/media_cover.dart`）的离线测试。
//
// 全部用**自造字节 fixture**：本机没有音视频真实样本，而这些容器格式的
// 封面结构是规范写死的，手工构造反而能把边界（截断/越界/64 位偏移/moov 在尾）
// 钉得比真样本更准。要钉死的事：
//   1. ID3v2.2 `PIC` / v2.3 `APIC` / v2.4 `APIC`（含 unsynchronisation、
//      extended header、多 APIC 取第一个）；
//   2. FLAC `METADATA_BLOCK_PICTURE`（type 6）+ Vorbis comment 里的 base64；
//   3. OGG/Vorbis 的 base64；
//   4. MP4 `moov > udta > meta > ilst > covr`（含 **moov 在文件尾**、64 位
//      largesize）；
//   5. MKV `Attachments > AttachedFile`（EBML 变长整数；头里 / 只尾部两种）；
//   6. 坏数据（截断/长度越界）→ **返回 null，不吐垃圾字节**；
//   7. 无封面文件 → null；
//   8. "只读片段"的建议 + FIFO 缓存命中 / 失效。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/media_cover.dart';
import 'package:synhub/src/features/media/media_source.dart'
    show MediaKind;

// ---------------------------------------------------------------- 基础工具

List<int> ascii(String s) => s.codeUnits;

List<int> be24(int v) => [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];
List<int> be64(int v) {
  final out = <int>[];
  for (var i = 7; i >= 0; i--) {
    out.add((v >> (8 * i)) & 0xFF);
  }
  return out;
}

List<int> le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

List<int> le32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

List<int> le64(int v) {
  final out = <int>[];
  for (var i = 0; i < 8; i++) {
    out.add((v >> (8 * i)) & 0xFF);
  }
  return out;
}

/// UTF-16LE（ASF 的字符串都是这个）
List<int> utf16le(String s) => [
  for (final c in s.codeUnits) ...[c & 0xFF, (c >> 8) & 0xFF],
];

/// ID3v2 syncsafe 整数（每字节 7 位）
List<int> syncsafe(int v) => [
  (v >> 21) & 0x7F,
  (v >> 14) & 0x7F,
  (v >> 7) & 0x7F,
  v & 0x7F,
];

/// 1x1 真 PNG（能被 Flutter 解码，UI 测试也能用）
final Uint8List kPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// 只有 magic 的 JPEG（解析只看 magic，不需要完整像素）
final List<int> kJpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46];

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

// ---------------------------------------------------------------- ID3v2

List<int> id3Frame(String id, List<int> body, int major) {
  if (major == 2) return [...ascii(id), ...be24(body.length), ...body];
  if (major == 4) {
    return [...ascii(id), ...syncsafe(body.length), 0, 0, ...body];
  }
  return [...ascii(id), ...be32(body.length), 0, 0, ...body];
}

List<int> id3Tag({
  required int major,
  required List<int> frames,
  int flags = 0,
}) => [...ascii('ID3'), major, 0, flags, ...syncsafe(frames.length), ...frames];

/// APIC 帧体（2.3/2.4）：enc=0(latin1) + mime + NUL + pictureType=3 + desc + 图
List<int> apicBody(List<int> img, {String mime = 'image/png', int enc = 0}) {
  if (enc == 1 || enc == 2) {
    // UTF-16 描述：BOM + 空描述（双字节结束符）
    return [enc, ...ascii(mime), 0, 0x03, 0xFF, 0xFE, 0x00, 0x00, ...img];
  }
  return [enc, ...ascii(mime), 0, 0x03, 0x00, ...img];
}

/// PIC 帧体（2.2）：enc + 3 字符图片格式 + pictureType + her desc + 图
List<int> picBody(List<int> img, {String fmt = 'PNG'}) => [
  0x00,
  ...ascii(fmt),
  0x03,
  0x00,
  ...img,
];

/// ID3v2.3 的 unssynchronisation：每个 0xFF 后面塞一个 0x00
List<int> unsync(List<int> b) {
  final out = <int>[];
  for (final x in b) {
    out.add(x);
    if (x == 0xFF) out.add(0x00);
  }
  return out;
}

// ---------------------------------------------------------------- FLAC / Vorbis

List<int> flacPictureBlock(List<int> img, {String mime = 'image/png'}) => [
  ...be32(3), // picture type: front cover
  ...be32(mime.length),
  ...ascii(mime),
  ...be32(0), // description 长度 0
  ...be32(1),
  ...be32(1),
  ...be32(24),
  ...be32(0),
  ...be32(img.length),
  ...img,
];

List<int> flacBlock(int type, List<int> data, {bool last = false}) => [
  type | (last ? 0x80 : 0x00),
  ...be24(data.length),
  ...data,
];

List<int> flacWithPicture(List<int> img) => [
  ...ascii('fLaC'),
  ...flacBlock(0, List<int>.filled(34, 0)), // STREAMINFO
  ...flacBlock(6, flacPictureBlock(img), last: true),
];

List<int> vorbisCommentStruct(
  List<int> pictureBlock, {
  String key = 'METADATA_BLOCK_PICTURE',
}) {
  final vendor = ascii('libtest');
  final entry = ascii('$key=${base64.encode(pictureBlock)}');
  return [
    ...le32(vendor.length),
    ...vendor,
    ...le32(1),
    ...le32(entry.length),
    ...entry,
  ];
}

/// 一个最小 Ogg 页：'OggS' + version + type + granule + serial + seq + crc
/// + segment table + 负载
List<int> oggPage(List<int> packet, int seq) {
  final segments = <int>[];
  var remaining = packet.length;
  while (remaining >= 255) {
    segments.add(255);
    remaining -= 255;
  }
  segments.add(remaining);
  return [
    ...ascii('OggS'),
    0, // version
    0, // header type
    ...List<int>.filled(8, 0), // granule
    ...le32(1), // serial
    ...le32(seq),
    ...le32(0), // crc（解析不校验）
    segments.length,
    ...segments,
    ...packet,
  ];
}

List<int> oggWithPicture(List<int> img) {
  final idPacket = [0x01, ...ascii('vorbis'), ...List<int>.filled(23, 0)];
  final commentPacket = [
    0x03,
    ...ascii('vorbis'),
    ...vorbisCommentStruct(flacPictureBlock(img)),
  ];
  return [...oggPage(idPacket, 0), ...oggPage(commentPacket, 1)];
}

// ---------------------------------------------------------------- MP4

List<int> box(String type, List<int> body) => [
  ...be32(body.length + 8),
  ...ascii(type),
  ...body,
];

/// 64 位 largesize 箱子（size 字段 = 1）
List<int> box64(String type, List<int> body) => [
  ...be32(1),
  ...ascii(type),
  ...be64(16 + body.length),
  ...body,
];

List<int> _covrBody(List<int> img, {int typeIndicator = 13}) => box('covr', [
  ...box('data', [...be32(typeIndicator), ...be32(0), ...img]),
]);

List<int> mp4MoovBytes(
  List<int> img, {
  bool large = false,
  int typeIndicator = 13,
}) {
  final ilst = box('ilst', _covrBody(img, typeIndicator: typeIndicator));
  final meta = box('meta', [...be32(0), ...ilst]);
  final udta = box('udta', meta);
  return large ? box64('moov', udta) : box('moov', udta);
}

List<int> mp4Ftyp() =>
    box('ftyp', [...ascii('isom'), ...be32(512), ...ascii('isomiso2')]);

List<int> mp4WithCovrInHead(
  List<int> img, {
  bool large = false,
  int typeIndicator = 13,
}) => [
  ...mp4Ftyp(),
  ...mp4MoovBytes(img, large: large, typeIndicator: typeIndicator),
];

// ---------------------------------------------------------------- MKV

/// EBML 长度 vint（去掉 marker 位后是 [n]）
List<int> ebmlSize(int n) {
  for (var len = 1; len <= 8; len++) {
    final max = (1 << (7 * len)) - 1;
    if (n < max) {
      var v = n | (1 << (7 * len));
      final out = List<int>.filled(len, 0);
      for (var i = len - 1; i >= 0; i--) {
        out[i] = v & 0xFF;
        v >>= 8;
      }
      return out;
    }
  }
  throw ArgumentError('too big');
}

List<int> ebmlUnknownSize() => [0x01, ...List<int>.filled(7, 0xFF)];

List<int> ebmlElem(List<int> id, List<int> data) => [
  ...id,
  ...ebmlSize(data.length),
  ...data,
];

List<int> mkvAttachments(List<int> img, {String name = 'cover.jpg'}) {
  final file = ebmlElem(
    const [0x61, 0xA7],
    [
      ...ebmlElem(const [0x46, 0x6E], ascii(name)), // FileName
      ...ebmlElem(const [0x46, 0x60], ascii('image/png')), // FileMimeType
      ...ebmlElem(const [0x46, 0x5C], img), // FileData
    ],
  );
  return ebmlElem(const [0x19, 0x41, 0xA4, 0x69], file); // Attachments
}

List<int> mkvEbmlHeader() =>
    ebmlElem(const [0x1A, 0x45, 0xDF, 0xA3], [0x42, 0x86, 0x81, 0x01]);

const List<int> kSegmentId = [0x18, 0x53, 0x80, 0x67];
const List<int> kClusterId = [0x1F, 0x43, 0xB6, 0x75];

// ---------------------------------------------------------------- ASF / WMA

const List<int> kAsfHeader = [
  0x30,
  0x26,
  0xB2,
  0x75,
  0x8E,
  0x66,
  0xCF,
  0x11,
  0xA6,
  0xD9,
  0x00,
  0xAA,
  0x00,
  0x62,
  0xCE,
  0x6C,
];
const List<int> kAsfExtContentDesc = [
  0x40,
  0xA4,
  0xD0,
  0xD2,
  0x07,
  0xE3,
  0xD2,
  0x11,
  0x97,
  0xF0,
  0x00,
  0xA0,
  0xC9,
  0x5E,
  0xA8,
  0x50,
];

/// ASF **Metadata Object** 的 GUID（`WM/Picture` 的另一个常见落点；
/// 与 `media_cover.dart` 的 `_asfMetadata` 逐字节一致）
const List<int> kAsfMetadata = [
  0xEA,
  0xCB,
  0xF8,
  0xC5,
  0xAF,
  0x5B,
  0x77,
  0x48,
  0x84,
  0x67,
  0xAA,
  0x8C,
  0x44,
  0xFA,
  0x4C,
  0xCA,
];

/// `WM/Picture` 值：**真实 ASF 规范**的形态
/// （type(1) + dataLen(4LE) + **NUL 结尾**的 mime + **NUL 结尾**的 desc + 图）。
///
/// 这里以前写的是 ID3 APIC 那种"mimeLen/descLen 4 字节前缀"的形状 —— 夹具与
/// 解析器**互相自洽**，真实 ASF 文件却一律解析失败。字节形态现按真机样本
/// `/tmp/wma-samples/real_example_wmpicture.wma`（在真实 Windows 产
/// `real_example.wma` 上按规范注入）对齐，见 docs/audio-codec-fallback.md §4.3。
List<int> wmPicture(List<int> img, {String mime = 'image/png'}) => [
  0x03,
  ...le32(img.length),
  ...utf16le(mime),
  0x00,
  0x00,
  0x00,
  0x00, // 空 description（NUL 结尾）
  ...img,
];

List<int> asfWithPicture(List<int> img, {String desc = ''}) {
  // 真实 ASF 的属性名是 **NUL 结尾**的 UTF-16LE 串，nameLen 含结尾的 0x0000
  final name = [...utf16le('WM/Picture'), 0x00, 0x00];
  final value = [
    0x03,
    ...le32(img.length),
    ...utf16le('image/png'),
    0x00,
    0x00,
    ...utf16le(desc),
    0x00,
    0x00,
    ...img,
  ];
  final descriptor = [
    ...le16(name.length),
    ...name,
    ...le16(1), // valueType = 1 (bytes)
    ...le16(value.length),
    ...value,
  ];
  final extObjBody = [...le16(1), ...descriptor]; // count = 1
  final extObj = [
    ...kAsfExtContentDesc,
    ...le64(24 + extObjBody.length),
    ...extObjBody,
  ];
  final headerSize = 30 + extObj.length;
  return [
    ...kAsfHeader,
    ...le64(headerSize),
    ...le32(1), // number of header objects
    0x01,
    0x02,
    ...extObj,
  ];
}

/// 同一个 `WM/Picture` 值放进 ASF **Metadata Object**（不是 Extended Content
/// Description）—— 规范里它常出现在 Header Extension 内，我们的解析器也会
/// 直接扫 Header Object 的子对象，所以这里作为 Header 子对象即可。
///
/// Metadata Object 的记录布局（与 `_asfMetadataObject` 一致）：
/// reserved(2) + stream(2) + nameLen(2) + valueType(2) + dataLen(4) + name + data
List<int> asfMetadataWithPicture(List<int> img) {
  final name = [...utf16le('WM/Picture'), 0x00, 0x00];
  final value = [
    0x03,
    ...le32(img.length),
    ...utf16le('image/png'),
    0x00,
    0x00,
    0x00,
    0x00,
    ...img,
  ];
  final record = [
    ...le16(0), // reserved
    ...le16(0), // stream number
    ...le16(name.length),
    ...le16(1), // valueType = 1 (bytes)
    ...le32(value.length),
    ...name,
    ...value,
  ];
  final objBody = [...le16(1), ...record]; // count = 1
  final obj = [...kAsfMetadata, ...le64(24 + objBody.length), ...objBody];
  final headerSize = 30 + obj.length;
  return [
    ...kAsfHeader,
    ...le64(headerSize),
    ...le32(1), // number of header objects
    0x01,
    0x02,
    ...obj,
  ];
}

// ---------------------------------------------------------------- RIFF / WAV

/// RIFF 里的 `ID3 ` 块（一些 WAV 用这种方式嵌封面）
List<int> wavWithId3(List<int> id3TagBytes) {
  final pad = id3TagBytes.length.isOdd ? [0x00] : <int>[];
  final chunk = [
    ...ascii('ID3 '),
    ...le32(id3TagBytes.length),
    ...id3TagBytes,
    ...pad,
  ];
  return [
    ...ascii('RIFF'),
    ...le32(4 + chunk.length),
    ...ascii('WAVE'),
    ...chunk,
  ];
}

// ================================================================ 测试

void main() {
  setUp(clearMediaCoverCache);
  tearDown(clearMediaCoverCache);

  group('ID3v2（MP3）', () {
    test('v2.3 APIC：mime + 图片字节', () {
      final tag = id3Tag(major: 3, frames: id3Frame('APIC', apicBody(kPng), 3));
      final cover = extractMediaCoverFromHead(
        bytes(tag),
        MediaKind.audio,
        'mp3',
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/png');
      expect(cover.bytes, kPng);
      expect(cover.source, 'id3v2.3/APIC');
    });

    test('v2.2 PIC：3 字符格式码 → mime', () {
      final tag = id3Tag(major: 2, frames: id3Frame('PIC', picBody(kPng), 2));
      final cover = extractMediaCoverFromHead(
        bytes(tag),
        MediaKind.audio,
        'mp3',
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/png');
      expect(cover.source, 'id3v2.2/PIC');
    });

    test('v2.4 APIC：syncsafe 帧长 + extended header', () {
      final ext = [...syncsafe(6), 0x01, 0x00];
      final tag = id3Tag(
        major: 4,
        flags: 0x40,
        frames: [...ext, ...id3Frame('APIC', apicBody(kPng), 4)],
      );
      final cover = extractMediaCoverFromHead(
        bytes(tag),
        MediaKind.audio,
        'mp3',
      );
      expect(cover, isNotNull);
      expect(cover!.source, 'id3v2.4/APIC');
      expect(cover.bytes, kPng);
    });

    test('v2.3 extended header（长度字段不含自身 4 字节）', () {
      final ext = [...be32(6), 0, 0, 0, 0, 0, 0];
      final tag = id3Tag(
        major: 3,
        flags: 0x40,
        frames: [...ext, ...id3Frame('APIC', apicBody(kPng), 3)],
      );
      final cover = extractMediaCoverFromHead(
        bytes(tag),
        MediaKind.audio,
        'mp3',
      );
      expect(cover, isNotNull);
      expect(cover!.bytes, kPng);
    });

    test('v2.3 整标签级 unsynchronisation 能还原', () {
      // 描述里放一个 0xFF，unsync 后会插 0x00；解析时必须去掉
      final frame = id3Frame('APIC', [
        0x00,
        ...ascii('image/png'),
        0,
        0x03,
        0xFF,
        0x00,
        ...kPng,
      ], 3);
      final tag = id3Tag(major: 3, flags: 0x80, frames: unsync(frame));
      final cover = extractMediaCoverFromHead(
        bytes(tag),
        MediaKind.audio,
        'mp3',
      );
      expect(cover, isNotNull);
      expect(cover!.bytes, kPng);
    });

    test('v2.4 帧级 unsynchronisation + data length indicator 能还原', () {
      // 描述里放一个 0xFF（保证 unsync 真的会插入 0x00）
      final raw = [0x00, ...ascii('image/png'), 0, 0x03, 0xFF, 0x00, ...kPng];
      // data length indicator（syncsafe 实际长度）也一起被 unsync 包住
      final stored = unsync([...syncsafe(raw.length), ...raw]);
      final frame = [
        ...ascii('APIC'),
        ...syncsafe(stored.length),
        0x00,
        0x03, // 帧级 unsync(0x02) + data length indicator(0x01)
        ...stored,
      ];
      final tag = id3Tag(major: 4, frames: frame);
      final cover = extractMediaCoverFromHead(
        bytes(tag),
        MediaKind.audio,
        'mp3',
      );
      expect(cover, isNotNull);
      expect(cover!.bytes, kPng);
    });

    test('多个 APIC 取第一个', () {
      final tag = id3Tag(
        major: 3,
        frames: [
          ...id3Frame('APIC', apicBody(kPng), 3),
          ...id3Frame('APIC', apicBody(kJpeg, mime: 'image/jpeg'), 3),
        ],
      );
      final cover = extractMediaCoverFromHead(
        bytes(tag),
        MediaKind.audio,
        'mp3',
      );
      expect(cover!.mime, 'image/png');
    });

    test('TIT2 在前、APIC 在后：能跳过非图片帧找到封面', () {
      final frames = [
        ...id3Frame('TIT2', [0x00, ...ascii('song')], 3),
        ...id3Frame('APIC', apicBody(kPng), 3),
      ];
      final tag = id3Tag(major: 3, frames: frames);
      final cover = extractMediaCoverFromHead(
        bytes(tag),
        MediaKind.audio,
        'mp3',
      );
      expect(cover, isNotNull);
      expect(cover!.bytes, kPng);
    });

    test('只有 TIT2（没有 APIC）→ null', () {
      final tag = id3Tag(
        major: 3,
        frames: id3Frame('TIT2', [0x00, ...ascii('song')], 3),
      );
      expect(
        extractMediaCoverFromHead(bytes(tag), MediaKind.audio, 'mp3'),
        isNull,
      );
    });

    test('截断的 APIC（帧长越界）→ null，不吐半张图', () {
      final full = id3Frame('APIC', apicBody(kPng), 3);
      final truncated = full.sublist(0, full.length - 5);
      final tag = [
        ...ascii('ID3'),
        3,
        0,
        0,
        ...syncsafe(truncated.length),
        ...truncated,
      ];
      expect(
        extractMediaCoverFromHead(bytes(tag), MediaKind.audio, 'mp3'),
        isNull,
      );
    });

    test('APIC 里不是图片（HTML 错误页）→ null', () {
      final tag = id3Tag(
        major: 3,
        frames: id3Frame('APIC', apicBody(ascii('<html>oops')), 3),
      );
      expect(
        extractMediaCoverFromHead(bytes(tag), MediaKind.audio, 'mp3'),
        isNull,
      );
    });

    test('ID3v2.2 的 UTF-16 描述也能跳过', () {
      final tag = id3Tag(
        major: 3,
        frames: id3Frame('APIC', apicBody(kPng, enc: 1), 3),
      );
      final cover = extractMediaCoverFromHead(
        bytes(tag),
        MediaKind.audio,
        'mp3',
      );
      expect(cover, isNotNull);
      expect(cover!.bytes, kPng);
    });
  });

  group('FLAC', () {
    test('METADATA_BLOCK_PICTURE（type 6）', () {
      final cover = extractMediaCoverFromHead(
        bytes(flacWithPicture(kPng)),
        MediaKind.audio,
        'flac',
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/png');
      expect(cover.source, 'flac/picture');
      expect(cover.bytes, kPng);
    });

    test('Vorbis comment 里的 METADATA_BLOCK_PICTURE= base64', () {
      final data = [
        ...ascii('fLaC'),
        ...flacBlock(0, List<int>.filled(34, 0)),
        ...flacBlock(
          4,
          vorbisCommentStruct(flacPictureBlock(kPng)),
          last: true,
        ),
      ];
      final cover = extractMediaCoverFromHead(
        bytes(data),
        MediaKind.audio,
        'flac',
      );
      expect(cover, isNotNull);
      expect(cover!.source, 'flac/vorbis/METADATA_BLOCK_PICTURE');
      expect(cover.bytes, kPng);
    });

    test('只有 STREAMINFO（没有封面）→ null', () {
      final data = [
        ...ascii('fLaC'),
        ...flacBlock(0, List<int>.filled(34, 0), last: true),
      ];
      expect(
        extractMediaCoverFromHead(bytes(data), MediaKind.audio, 'flac'),
        isNull,
      );
    });

    test('picture 的 dataLen 越界 → null', () {
      final picture = flacPictureBlock(kPng);
      // 把最后的 dataLen 字段改大
      final tampered = [...picture];
      final lenOff = tampered.length - kPng.length - 4;
      tampered[lenOff] = 0x7F;
      tampered[lenOff + 1] = 0xFF;
      tampered[lenOff + 2] = 0xFF;
      tampered[lenOff + 3] = 0xFF;
      final data = [
        ...ascii('fLaC'),
        ...flacBlock(0, List<int>.filled(34, 0)),
        ...flacBlock(6, tampered, last: true),
      ];
      expect(
        extractMediaCoverFromHead(bytes(data), MediaKind.audio, 'flac'),
        isNull,
      );
    });
  });

  group('OGG / Vorbis', () {
    test('comment header 的 base64 封面能取到', () {
      final cover = extractMediaCoverFromHead(
        bytes(oggWithPicture(kPng)),
        MediaKind.audio,
        'ogg',
      );
      expect(cover, isNotNull);
      expect(cover!.source, 'ogg/vorbis/METADATA_BLOCK_PICTURE');
      expect(cover.bytes, kPng);
    });

    test('坏 base64 / 没有 comment → null', () {
      final idPacket = [0x01, ...ascii('vorbis'), ...List<int>.filled(23, 0)];
      expect(
        extractMediaCoverFromHead(
          bytes(oggPage(idPacket, 0)),
          MediaKind.audio,
          'ogg',
        ),
        isNull,
      );
    });
  });

  group('MP4 / M4A / M4V', () {
    test('moov 在文件头：covr > data(type 13=JPEG)', () {
      final cover = extractMediaCoverFromHead(
        bytes(mp4WithCovrInHead(kJpeg)),
        MediaKind.audio,
        'm4a',
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/jpeg');
      expect(cover.source, 'mp4/covr');
      expect(cover.bytes, kJpeg);
    });

    test('covr > data(type 14=PNG)', () {
      final cover = extractMediaCoverFromHead(
        bytes(mp4WithCovrInHead(kPng, typeIndicator: 14)),
        MediaKind.video,
        'mp4',
      );
      expect(cover!.mime, 'image/png');
      expect(cover.bytes, kPng);
    });

    test('64 位 largesize 的 moov 也能解析', () {
      final cover = extractMediaCoverFromHead(
        bytes(mp4WithCovrInHead(kPng, large: true)),
        MediaKind.video,
        'mp4',
      );
      expect(cover, isNotNull);
      expect(cover!.bytes, kPng);
    });

    test('moov 在**文件尾**：头段 + 尾段拼起来才拿得到', () {
      final ftyp = mp4Ftyp();
      const mdatBody = 5000000;
      final mdatHeader = [...be32(mdatBody + 8), ...ascii('mdat')];
      final prefix = Uint8List.fromList([...ftyp, ...mdatHeader]);
      final moov = Uint8List.fromList(mp4MoovBytes(kPng));
      final fileSize = prefix.length + mdatBody + moov.length;

      // 只给头段 → 拿不到（moov 不在已知范围）
      expect(
        extractMediaCover(
          MediaCoverBytes(prefix: prefix, fileSize: fileSize),
          MediaKind.video,
          'mp4',
        ),
        isNull,
      );
      // 头 + 尾 → 拿到
      final cover = extractMediaCover(
        MediaCoverBytes(prefix: prefix, tail: moov, fileSize: fileSize),
        MediaKind.video,
        'mp4',
      );
      expect(cover, isNotNull);
      expect(cover!.bytes, kPng);
      expect(cover.source, startsWith('mp4/covr'));
    });

    test('moov 里没有 covr → null', () {
      final moov = box('moov', box('udta', box('meta', be32(0))));
      final file = [...mp4Ftyp(), ...moov];
      expect(
        extractMediaCoverFromHead(bytes(file), MediaKind.video, 'mp4'),
        isNull,
      );
    });

    test('covr 里不是图片 → null', () {
      final moov = box(
        'moov',
        box(
          'udta',
          box('meta', [
            ...be32(0),
            ...box(
              'ilst',
              box(
                'covr',
                box('data', [...be32(13), ...be32(0), ...ascii('junk!!')]),
              ),
            ),
          ]),
        ),
      );
      final file = [...mp4Ftyp(), ...moov];
      expect(
        extractMediaCoverFromHead(bytes(file), MediaKind.video, 'mp4'),
        isNull,
      );
    });
  });

  group('MKV / WebM', () {
    test('Attachments > AttachedFile（在文件头里）', () {
      final file = [
        ...mkvEbmlHeader(),
        ...kSegmentId,
        ...ebmlUnknownSize(),
        ...mkvAttachments(kPng),
      ];
      final cover = extractMediaCoverFromHead(
        bytes(file),
        MediaKind.video,
        'mkv',
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/png');
      expect(cover.source, 'matroska/cover.jpg');
      expect(cover.bytes, kPng);
    });

    test('Attachments 只在**文件尾**：尾段扫描能命中', () {
      // 头段：EBML 头 + Segment（未知长度）+ 一个未知长度的 Cluster（跳不过）
      final prefix = Uint8List.fromList([
        ...mkvEbmlHeader(),
        ...kSegmentId,
        ...ebmlUnknownSize(),
        ...kClusterId,
        ...ebmlUnknownSize(),
        0x00,
        0x00,
      ]);
      final tail = Uint8List.fromList(mkvAttachments(kPng));
      final fileSize = prefix.length + tail.length;
      final cover = extractMediaCover(
        MediaCoverBytes(prefix: prefix, tail: tail, fileSize: fileSize),
        MediaKind.video,
        'mkv',
      );
      expect(cover, isNotNull);
      expect(cover!.bytes, kPng);
    });

    test('EBML FileData 不是图片 → null', () {
      final file = [
        ...mkvEbmlHeader(),
        ...kSegmentId,
        ...ebmlUnknownSize(),
        ...mkvAttachments(ascii('not-an-image')),
      ];
      expect(
        extractMediaCoverFromHead(bytes(file), MediaKind.video, 'mkv'),
        isNull,
      );
    });
  });

  group('ASF / WMA 与 RIFF / WAV（尽力而为）', () {
    test('ASF：Extended Content Description 里的 WM/Picture', () {
      final cover = extractMediaCoverFromHead(
        bytes(asfWithPicture(kPng)),
        MediaKind.audio,
        'wma',
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/png');
      expect(cover.source, 'asf/WM-Picture');
      expect(cover.bytes, kPng);
    });

    test('ASF：GUID 对但对象被截断 → null', () {
      final full = asfWithPicture(kPng);
      final truncated = full.sublist(0, full.length - 10);
      expect(
        extractMediaCoverFromHead(bytes(truncated), MediaKind.audio, 'wma'),
        isNull,
      );
    });

    test('ASF：**规范形态**（NUL 结尾的 mime/desc）解析正确 —— 真文件回归', () {
      // 依据：真实 Windows ASF（`real_example.wma`，WMFSDK 12.0.15063.332）
      // 注入规范 `WM/Picture` 后，修复前返回 null、修复后返回 'asf/WM-Picture'。
      // 这里用非空 description，钉住"desc 是 NUL 结尾而不是 4 字节长度前缀"
      // —— 若退回 ID3 APIC 形状，图片起点会早 2 字节，`bytes` 断言立刻红。
      final cover = extractMediaCoverFromHead(
        bytes(asfWithPicture(kPng, desc: 'cover')),
        MediaKind.audio,
        'wma',
      );
      expect(cover, isNotNull);
      expect(cover!.mime, 'image/png');
      expect(cover.source, 'asf/WM-Picture');
      expect(cover.bytes, kPng);
    });

    test('ASF：属性名带结尾 NUL（真实形态）必须能匹配上 —— 老解析器在这里失手', () {
      // `asfWithPicture` 现在写的是**带 NUL** 的名字 + `nameLen` 含 NUL（规范）。
      // 把名字换成不带 NUL 的"夹具形态"，同样要能匹配（向后兼容）。
      final withNul = asfWithPicture(kPng);
      expect(
        extractMediaCoverFromHead(bytes(withNul), MediaKind.audio, 'wma'),
        isNotNull,
      );
      // Metadata Object（另一个 WM/Picture 落点，常出现在 Header Extension 里）
      final meta = asfMetadataWithPicture(kPng);
      final cover = extractMediaCoverFromHead(
        bytes(meta),
        MediaKind.audio,
        'wma',
      );
      expect(cover, isNotNull);
      expect(cover!.bytes, kPng);
      expect(cover.source, 'asf/WM-Picture');
    });

    test('WAV：RIFF 的 ID3 块里再走 ID3v2 APIC', () {
      final tag = id3Tag(major: 3, frames: id3Frame('APIC', apicBody(kPng), 3));
      final cover = extractMediaCoverFromHead(
        bytes(wavWithId3(tag)),
        MediaKind.audio,
        'wav',
      );
      expect(cover, isNotNull);
      expect(cover!.bytes, kPng);
      expect(cover.source, 'id3v2.3/APIC');
    });

    test('WMA 的片段建议：只读头部、不要尾部', () {
      final plan = mediaCoverRequestFor(
        kind: MediaKind.audio,
        extension: 'wma',
      );
      expect(plan.supported, isTrue);
      expect(plan.container, 'asf');
      expect(plan.needsTail, isFalse);
      expect(plan.prefixBytes, kMediaCoverAsfHeadBytes);
    });
  });

  group('坏数据 / 无封面 → 一律 null', () {
    test('空 / 太短', () {
      expect(
        extractMediaCover(const MediaCoverBytes(), MediaKind.audio, 'mp3'),
        isNull,
      );
      expect(
        extractMediaCoverFromHead(bytes([0x49, 0x44]), MediaKind.audio, 'mp3'),
        isNull,
      );
    });

    test('后缀说是音视频，内容却是纯文本', () {
      for (final ext in ['mp3', 'flac', 'ogg', 'mp4', 'mkv', 'wma', 'wav']) {
        expect(
          extractMediaCoverFromHead(
            bytes(ascii('hello world, definitely not media')),
            MediaKind.audio,
            ext,
          ),
          isNull,
          reason: ext,
        );
      }
    });

    test('ID3 头声明超大标签但字节被截断 → null', () {
      final header = [...ascii('ID3'), 3, 0, 0, ...syncsafe(1000000)];
      expect(
        extractMediaCoverFromHead(bytes(header), MediaKind.audio, 'mp3'),
        isNull,
      );
    });
  });

  group('读取片段建议', () {
    test('ID3（mp3）：只读头部，不要尾部', () {
      final plan = mediaCoverRequestFor(
        kind: MediaKind.audio,
        extension: 'mp3',
      );
      expect(plan.supported, isTrue);
      expect(plan.container, 'id3v2');
      expect(plan.prefixBytes, kMediaCoverId3HeadBytes);
      expect(plan.needsTail, isFalse);
    });

    test('MP4：头 + 尾都要（moov 可能在尾）', () {
      final plan = mediaCoverRequestFor(
        kind: MediaKind.video,
        extension: 'mp4',
      );
      expect(plan.supported, isTrue);
      expect(plan.prefixBytes, kMediaCoverMp4HeadBytes);
      expect(plan.tailBytes, kMediaCoverMp4TailBytes);
      expect(plan.needsTail, isTrue);
    });

    test('MKV：尾段给得比头段大（Attachments 常追加在末尾）', () {
      final plan = mediaCoverRequestFor(
        kind: MediaKind.video,
        extension: 'mkv',
      );
      expect(plan.needsTail, isTrue);
      expect(plan.tailBytes, greaterThan(plan.prefixBytes));
    });

    test('AVI：明确 supported=false，prefix=0（连请求都别发）', () {
      final plan = mediaCoverRequestFor(
        kind: MediaKind.video,
        extension: 'avi',
      );
      expect(plan.supported, isFalse);
      expect(plan.prefixBytes, 0);
    });

    test('非音视频后缀：supported=false', () {
      for (final ext in ['txt', 'pdf', 'epub', 'zip', '']) {
        expect(
          mediaCoverRequestFor(kind: MediaKind.video, extension: ext).supported,
          isFalse,
          reason: ext,
        );
      }
    });

    test('小文件：建议值被夹到文件大小，不重复读', () {
      final plan = mediaCoverRequestFor(
        kind: MediaKind.video,
        extension: 'mp4',
        fileSize: 1000,
      );
      expect(plan.prefixBytes, 1000);
      expect(plan.needsTail, isFalse);
    });

    test('总读取量远小于文件大小（不会为了封面下载整文件）', () {
      final plan = mediaCoverRequestFor(
        kind: MediaKind.video,
        extension: 'mkv',
        fileSize: 1024 * 1024 * 1024, // 1GB
      );
      expect(plan.totalBytes, lessThan(4 * 1024 * 1024));
    });
  });

  group('后缀归一化', () {
    test('大小写 / 前导点 / 路径 / 多点都归一', () {
      expect(normalizeMediaExtension('MP3'), 'mp3');
      expect(normalizeMediaExtension('.M4A'), 'm4a');
      expect(normalizeMediaExtension('song.FLAC'), 'flac');
      expect(normalizeMediaExtension('/home/a/clip.MKV'), 'mkv');
      expect(normalizeMediaExtension('archive.tar.gz'), 'gz');
    });
  });

  group('封面缓存（FIFO + 失效）', () {
    MediaCover make(int i) => MediaCover(
      bytes: Uint8List.fromList([i, i, i, i]),
      mime: 'image/png',
      source: 'test',
    );

    test('写入后能命中；evict 前缀能清掉', () {
      mediaCoverCachePut('/home/a.mp3|1|100', make(1));
      mediaCoverCachePut('/home/b.mp3|1|100', make(2));
      expect(mediaCoverCacheGet('/home/a.mp3|1|100')!.bytes[0], 1);
      final evicted = evictMediaCovers('/home/a.mp3|');
      expect(evicted, ['/home/a.mp3|1|100']);
      expect(mediaCoverCacheGet('/home/a.mp3|1|100'), isNull);
      expect(mediaCoverCacheGet('/home/b.mp3|1|100'), isNotNull);
    });

    test('超过上限按插入顺序 FIFO 淘汰', () {
      for (var i = 0; i < kMediaCoverCacheLimit + 10; i++) {
        mediaCoverCachePut('k$i', make(i % 256));
      }
      expect(debugMediaCoverCacheCount(), kMediaCoverCacheLimit);
      expect(mediaCoverCacheGet('k0'), isNull); // 最早的被淘汰
      expect(mediaCoverCacheGet('k${kMediaCoverCacheLimit + 9}'), isNotNull);
    });

    test('clearMediaCoverCache 清空', () {
      mediaCoverCachePut('x', make(1));
      clearMediaCoverCache();
      expect(debugMediaCoverCacheCount(), 0);
      expect(debugMediaCoverCacheKeys(), isEmpty);
    });
  });
}
