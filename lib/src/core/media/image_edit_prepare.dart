// 图生图的**本地预检**：缩边 + JPEG 重编码 + **EXIF（含 GPS）剥离** + 体积/合法性校验。
//
// 为什么必须单独有这一步（重要，别被 `image_prepare.dart` 的注释误导）：
//   `prepareImageUpload()` 只保证"重编码成 JPEG"，**并不保证剥掉 EXIF** ——
//   `img.decodeImage()` 解出来的 `Image` 会**保留**源 EXIF，而
//   `img.encodeJpg(image, quality:)` 默认会把 `image.exif` 原样写回去
//   （image 包 `jpeg_encoder.dart` 的 `_writeExif`）。
//   所以"长边没超 1280、走的是原图分支"时，EXIF（含 GPS IFD）会**原封不动地**
//   留在输出里 —— 本文件用探针实测确认过（见 docs/photo-ai-image-edit-batch1.md）。
//   因此这里在复用 [prepareImageUpload] 之后，**显式清空 `image.exif` 再编码**，
//   并对输出做**字节级**断言：不含 `Exif\0\0` 段。
//
// 隐私边界：相册照片是敏感个人信息（人脸/证件/位置）。EXIF 默认剥离不是可选项
// （方案 §6.4）。
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../data/ai/image_edit_client.dart';
import '../settings/app_settings.dart' show ImageQuality;
import 'image_prepare.dart';

/// 本地预检的体积上限（**保守兜底**，不是"各家真实上限"）。
///
/// 已知的官方数字只有 A1 的 GPT image 模型：每张 `< 50MB`（方案 §4.1 字段表，
/// 来源 openai-python `image_edit_params.py`）。A2/B1 的上限**【待取证】**，
/// 所以这里取 50MB 当统一兜底；真实体积在缩边+JPEG q90 之后通常只有几百 KB。
/// **不许**把这里的数字当成"某后端已核实的限制"对外宣称。
const int kImageEditMaxUploadBytes = 50 * 1024 * 1024;

/// 预检结果（`bytes` 是**已剥离 EXIF** 的 JPEG 字节）
class PreparedImageForEdit {
  const PreparedImageForEdit({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.originalBytes,
    required this.resized,
    required this.flattenedAnimation,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
  final int width;
  final int height;

  /// 处理前的原始字节数（用于"已先压缩到 y MB"的如实说明）
  final int originalBytes;

  /// 长边是否被缩过（`prepareImageUpload` 的 changed 分支）
  final bool resized;

  /// 动图被展平成单张静态图（会丢动画，必须如实告知）
  final bool flattenedAnimation;

  int get byteLength => bytes.length;

  String get sizeText => '${(bytes.length / 1024).toStringAsFixed(0)} KB';
}

/// 预检：给图生图发出去**之前**处理一张照片。
///
/// 失败抛 [ImageEditException]，类型确定：
///   * 不是图片/损坏 → [ImageEditErrorKind.inputNotImage]
///   * 超体积 → [ImageEditErrorKind.imageTooLarge]
///   * 剥不掉 EXIF（不该发生）→ [ImageEditErrorKind.exifNotStripped]（**阻止外发**）
PreparedImageForEdit prepareImageForEdit({
  required Uint8List bytes,
  required String fileName,

  /// 体积上限（默认 [kImageEditMaxUploadBytes]；**只为单测注入更小值**）
  int maxBytes = kImageEditMaxUploadBytes,
}) {
  if (bytes.isEmpty) {
    throw ImageEditException(ImageEditErrorKind.inputNotImage);
  }
  // 1) 复用既有重编码/缩边（只缩不放，长边 1280、JPEG q90）
  final base = prepareImageUpload(
    bytes: bytes,
    fileName: fileName,
    quality: ImageQuality.standard,
  );
  // 2) 解码；解不出就是"不是图片"（不静默放行）
  img.Image? decoded;
  try {
    decoded = img.decodeImage(base.bytes);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
    throw ImageEditException(ImageEditErrorKind.inputNotImage);
  }

  final flattened = decoded.frames.length > 1;
  final frame = flattened ? decoded.frames.first : decoded;
  // 3) **关键**：清空 EXIF（含 GPS IFD）再编码 —— `encodeJpg` 会写 `image.exif`，
  //    不清就是"把 GPS 随照片发到云端"。
  frame.exif = img.ExifData();
  final out = Uint8List.fromList(
    img.encodeJpg(frame, quality: kStandardImageJpegQuality),
  );

  // 4) 字节级自检：输出里**不得**再有 EXIF 段
  assert(!hasExifSegment(out), 'EXIF 未剥离：图生图预检必须清空 image.exif 再 encodeJpg');
  if (hasExifSegment(out)) {
    throw ImageEditException(ImageEditErrorKind.exifNotStripped);
  }

  // 5) 体积兜底（在本地先拦，不等服务端 413）
  if (out.length > maxBytes) {
    throw ImageEditException(
      ImageEditErrorKind.imageTooLarge,
      imageEditErrorText(ImageEditErrorKind.imageTooLarge, {
        'mb': (out.length / (1024 * 1024)).toStringAsFixed(1),
        'limit': '${maxBytes ~/ (1024 * 1024)}',
      }),
    );
  }

  return PreparedImageForEdit(
    bytes: out,
    fileName: base.fileName,
    mimeType: 'image/jpeg',
    width: frame.width,
    height: frame.height,
    originalBytes: bytes.length,
    resized: base.changed,
    flattenedAnimation: flattened,
  );
}

/// **字节级**判据：JPEG/EXIF 里的 `Exif\0\0` 签名（APP1 的载荷开头）。
///
/// 找到即认为"这张图带 EXIF 段"（GPS IFD 一定在 EXIF 段里，所以也一并覆盖）。
/// 返回签名所在偏移（找不到返回 -1），方便测试打印证据。
int findExifSegment(Uint8List bytes) {
  const sig = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // "Exif\0\0"
  for (var i = 0; i + sig.length <= bytes.length; i++) {
    var hit = true;
    for (var j = 0; j < sig.length; j++) {
      if (bytes[i + j] != sig[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}

/// 输出里到底还有没有 EXIF 段（[findExifSegment] 的布尔版）
bool hasExifSegment(Uint8List bytes) => findExifSegment(bytes) >= 0;

/// 探针（测试用）：解出这张图里的 **GPS IFD** 标签数量。
///
/// 0 = 没有 GPS 信息；>0 = 真的带 GPS（用来证明"夹具确实含 GPS、输出确实没有"）。
int gpsIfdTagCount(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    return decoded?.exif.gpsIfd.keys.length ?? 0;
  } catch (_) {
    return 0;
  }
}
