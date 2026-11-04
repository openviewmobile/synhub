// 发送图片前的预处理 —— 对齐原版的「Image quality」设置。
//
// 原版逻辑（`UploadProgressPresenter.resizeImageFiles` + `BitmapUtil`）：
//   * `upload_quality == standard`（默认）：**只要是图片**就重编码成 JPEG q90；
//     其中长边 > 1280 的会先等比缩到 1280（`resizeBitmapIfNecessary`），
//     文件名扩展名改成 `jpg`；
//   * `upload_quality == original`：原样上传，不动一个字节。
// 注意原版**不看**图片格式：PNG/GIF/HEIC 都会被转成 JPEG 90；我们这里对
// **动图（GIF/WebP 动图）** 破例放行原图，否则会丢动画（有意偏离，已记录）。
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../settings/app_settings.dart';

/// 标准质量的目标长边（原版写死 1280）
const int kStandardImageMaxEdge = 1280;

/// JPEG 质量（原版 `Bitmap.compress(JPEG, 90, ...)`）
const int kStandardImageJpegQuality = 90;

/// 处理结果
class PreparedUpload {
  const PreparedUpload({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.changed,
  });

  final Uint8List bytes;

  /// 可能要改扩展名（`a.png` → `a.jpg`）
  final String fileName;
  final String mimeType;

  /// 是否真的重新编码过（false = 原样）
  final bool changed;
}

/// 按设置处理待上传的图片。
///
/// [fileName] 用来判断扩展名与生成新名字；[bytes] 是文件内容。
/// 不是图片、或质量为原图、或动图 → 原样返回。
PreparedUpload prepareImageUpload({
  required Uint8List bytes,
  required String fileName,
  required ImageQuality quality,
}) {
  PreparedUpload unchanged() => PreparedUpload(
    bytes: bytes,
    fileName: fileName,
    mimeType: _mimeOf(fileName),
    changed: false,
  );

  if (quality == ImageQuality.original) return unchanged();
  if (!_looksLikeImage(fileName, bytes)) return unchanged();
  // 动图不动它（重编码会丢帧）
  if (_looksAnimated(fileName, bytes)) return unchanged();

  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return unchanged();
  }
  if (decoded == null) return unchanged();

  // 长边缩到 1280（只缩不放）
  var out = decoded;
  final longEdge = decoded.width > decoded.height
      ? decoded.width
      : decoded.height;
  if (longEdge > kStandardImageMaxEdge) {
    final scale = kStandardImageMaxEdge / longEdge;
    final w = (decoded.width * scale).round().clamp(1, kStandardImageMaxEdge);
    final h = (decoded.height * scale).round().clamp(1, kStandardImageMaxEdge);
    out = img.copyResize(
      decoded,
      width: w,
      height: h,
      interpolation: img.Interpolation.average,
    );
  }

  final encoded = img.encodeJpg(out, quality: kStandardImageJpegQuality);
  return PreparedUpload(
    bytes: Uint8List.fromList(encoded),
    fileName: _withJpgExtension(fileName),
    mimeType: 'image/jpeg',
    changed: true,
  );
}

/// 上传用的 MIME（按扩展名猜，用于 multipart 的 Content-Type）
String _mimeOf(String fileName) {
  final ext = fileName.contains('.')
      ? fileName.split('.').last.toLowerCase()
      : '';
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'bmp' => 'image/bmp',
    _ => 'application/octet-stream',
  };
}

bool _looksLikeImage(String fileName, Uint8List bytes) {
  final mime = _mimeOf(fileName);
  if (mime.startsWith('image/')) return true;
  return _signatureMime(bytes) != null;
}

/// 常见图片魔数（扩展名骗人时兜底）
String? _signatureMime(Uint8List b) {
  if (b.length < 12) return null;
  if (b[0] == 0xFF && b[1] == 0xD8) return 'image/jpeg';
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return 'image/png';
  }
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'image/gif';
  if (b[0] == 0x42 && b[1] == 0x4D) return 'image/bmp';
  if (b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// 动图：GIF 多帧 / 动图 WebP（原版会拍成静态 JPEG，我们放行）
bool _looksAnimated(String fileName, Uint8List bytes) {
  final ext = fileName.contains('.')
      ? fileName.split('.').last.toLowerCase()
      : '';
  if (ext != 'gif' && ext != 'webp') return false;
  try {
    final decoded = img.decodeImage(bytes);
    return decoded != null && decoded.frames.length > 1;
  } catch (_) {
    return false;
  }
}

String _withJpgExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final base = dot > 0 ? fileName.substring(0, dot) : fileName;
  return '$base.jpg';
}

/// 把一张图裁成**正方形**（取中间），并限制长边 —— 头像上传用。
///
/// 原版用 uCrop（`Crop.of(uri, out).asSquare()`），这里用纯 Dart 做等效处理：
/// 居中裁正方形 + 缩到 [maxEdge]（默认 512，头像没必要更大）。
/// 失败（解码不了）就原样返回源路径，让服务端自己处理。
Future<String> cropAvatarSquare(String sourcePath, {int maxEdge = 512}) async {
  final file = File(sourcePath);
  final decoded = img.decodeImage(await file.readAsBytes());
  if (decoded == null) return sourcePath;

  final side = decoded.width < decoded.height ? decoded.width : decoded.height;
  final square = img.copyCrop(
    decoded,
    x: (decoded.width - side) ~/ 2,
    y: (decoded.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final resized = side > maxEdge
      ? img.copyResize(square, width: maxEdge, height: maxEdge)
      : square;
  final out = File(
    '${file.parent.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  await out.writeAsBytes(img.encodeJpg(resized, quality: 92));
  return out.path;
}
