// 内嵌封面（大 APIC）测试夹具。
//
// **真实夹具**：`test/support/media_cover_apic_real.bin`
//   * 来源：真机文件 `/home/Music/CD1 - 01 - Track01.mp3`（8.7 MB）的前
//     **2,200,001 字节**（`/tmp/mp3_cover_head.bin`，真实 NAS 只读 Range HTTP 206）；
//   * 本仓只留前 **2,110,000 字节**（剪裁范围 `[0, 2110000)`）——
//     刚好盖住 APIC 数据尾（绝对 2,104,127）+ 约 5.8KB 标签 padding；
//   * 剪裁后 sha256 前 16 位 = `fe652c7213a49c83`；
//   * 该文件是 ID3v2.3，APIC 帧头在绝对偏移 **526**、声明长度 **2,103,591**，
//     MIME 字段写作 `image/jpg`（归一成 `image/jpeg`），图片数据起于 **549**、
//     止于 **2,104,127**（**2,103,578 字节**）。
//
// 第一段预读只有 512KB（`kMediaCoverId3HeadBytes`）⇒ 图片被截断，正是本轮
// "两段式取字节"要修的现象。
import 'dart:io';
import 'dart:typed_data';

/// 真机文件的总大小（列表里的 `size`；8.7 MB）
const int kRealApicFileSize = 9130000;

/// 真机 ID3v2.3 APIC 图片在文件里的绝对区间 [start, end)
const int kRealApicImageStart = 549;
const int kRealApicImageEnd = 2104127;

/// 图片字节数（= end - start）
const int kRealApicImageLength = kRealApicImageEnd - kRealApicImageStart;

/// 剪裁后夹具的 sha256 前 16 位（见文件头说明）
const String kRealApicFixtureSha256Prefix = 'fe652c7213a49c83';

/// 剪裁后夹具的字节数
const int kRealApicFixtureBytes = 2110000;

Uint8List? _cached;
Uint8List? _cachedImage;

/// 读真实夹具（进程内缓存；文件缺失时抛，让用例失败而不是静默 skip）。
Uint8List realApicFixture() {
  final cached = _cached;
  if (cached != null) return cached;
  final file = File('test/support/media_cover_apic_real.bin');
  if (!file.existsSync()) {
    throw StateError('缺少夹具 ${file.path}（见 test/support/media_cover_samples.dart）');
  }
  final bytes = Uint8List.fromList(file.readAsBytesSync());
  _cached = bytes;
  return bytes;
}

/// 真实的 2.1MB APIC 图片字节（夹具里 [549, 2104127) 那一段）
Uint8List realApicImage() =>
    _cachedImage ??= Uint8List.sublistView(
      realApicFixture(),
      kRealApicImageStart,
      kRealApicImageEnd,
    );

// ============================================================ 合成夹具

List<int> _ascii(String s) => s.codeUnits;
List<int> _be32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> _syncsafe(int v) =>
    [(v >> 21) & 0x7F, (v >> 14) & 0x7F, (v >> 7) & 0x7F, v & 0x7F];

/// 1x1 PNG（magic 够用）
final Uint8List kTinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

/// 合成 ID3v2.3 MP3：一个 APIC 帧（图片 [image]）。
///
/// [declaredFrameSize] 显式给出帧头里写的长度（默认 = 实际帧体长度）——
/// 用来造"声明长度 > 预读/上限/文件尾"的脏数据。
/// [declaredTagSize] 同理控制标签长度字段（默认 = 实际帧区长度）。
Uint8List syntheticMp3WithApic({
  required List<int> image,
  String mime = 'image/png',
  int? declaredFrameSize,
  int? declaredTagSize,
}) {
  final apicBody = <int>[
    0x00, // encoding = ISO-8859-1
    ..._ascii(mime),
    0x00, // MIME 结束
    0x03, // picture type = cover (front)
    0x00, // description = 空
    ...image,
  ];
  final frame = <int>[
    ..._ascii('APIC'),
    ..._be32(declaredFrameSize ?? apicBody.length),
    0x00,
    0x00, // frame flags
    ...apicBody,
  ];
  return Uint8List.fromList([
    ..._ascii('ID3'),
    3,
    0,
    0,
    ..._syncsafe(declaredTagSize ?? frame.length),
    ...frame,
  ]);
}

/// 合成 ID3v2.4 MP3：APIC 帧长度字段是 **syncsafe**，故意把最高位置 1
/// （非法）⇒ 解析器应把它当"负数/非法"丢掉。
Uint8List syntheticMp3WithBadSyncsafeFrame() {
  final apicBody = <int>[0x00, ..._ascii('image/png'), 0x00, 0x03, 0x00, ...kTinyPng];
  final frame = <int>[
    ..._ascii('APIC'),
    0x80,
    0x00,
    0x00,
    0x00, // 高位非法
    0x00,
    0x00,
    ...apicBody,
  ];
  return Uint8List.fromList([
    ..._ascii('ID3'),
    4,
    0,
    0,
    ..._syncsafe(frame.length),
    ...frame,
  ]);
}

/// 合成 FLAC：`fLaC` + 一个 `METADATA_BLOCK_PICTURE`（type 6，最后一块）。
Uint8List syntheticFlacWithPicture({
  required List<int> image,
  String mime = 'image/jpeg',
  int? declaredBlockLen,
}) {
  final pic = <int>[
    ..._be32(3), // picture type
    ..._be32(mime.length),
    ..._ascii(mime),
    ..._be32(0), // description
    ..._be32(500),
    ..._be32(500),
    ..._be32(24),
    ..._be32(0),
    ..._be32(image.length),
    ...image,
  ];
  final len = declaredBlockLen ?? pic.length;
  return Uint8List.fromList([
    ..._ascii('fLaC'),
    0x80 | 6,
    (len >> 16) & 0xFF,
    (len >> 8) & 0xFF,
    len & 0xFF,
    ...pic,
  ]);
}

List<int> _box(String type, List<int> body) =>
    [..._be32(body.length + 8), ..._ascii(type), ...body];

/// 合成 MP4：`ftyp + moov>udta>meta>ilst>covr>data(JPEG) + mdat`。
///
/// `covr` 图片放在 `moov` 里、`moov` 在文件头；`mdat` 很大，好让图片段落在
/// 头 1MB 与尾 1MB 之间的"未知区"，逼出第二段请求。
Uint8List syntheticMp4WithCover({
  required List<int> image,
  int mdatBytes = 4 * 1024 * 1024,
}) {
  final data = _box('data', [..._be32(13), ..._be32(0), ...image]);
  final covr = _box('covr', data);
  final ilst = _box('ilst', covr);
  final meta = _box('meta', [..._be32(0), ...ilst]);
  final udta = _box('udta', meta);
  final moov = _box('moov', udta);
  final ftyp = _box('ftyp', [..._ascii('isom'), ..._be32(512)]);
  final mdat = _box('mdat', List<int>.filled(mdatBytes, 0));
  return Uint8List.fromList([...ftyp, ...moov, ...mdat]);
}
