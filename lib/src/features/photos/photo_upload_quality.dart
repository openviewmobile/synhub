// ⑦相册 **P43 上传质量档（原图 / 压缩）**。
//
// 事实与边界（先说清楚，避免又变成"编协议"）：
// * 官方**安卓端**有「上传质量」选项；**压缩是纯客户端行为** ——
//   服务端 `SYNO.Foto.Upload.so` 的请求参数里**没有**任何"质量/尺寸"字段
//   （rodata 只有 `folder`/`filename`/`duplicate` 那一套），所以这里**不发明 API**；
// * 实现用仓库**已有依赖** `image: ^4.5.4` 在 Dart 侧解码→缩放→重编码 JPEG；
// * **不是所有格式都能压**：`image` 认不出的（如 HEIC/RAW）**原样直传**，
//   不静默丢内容、也不报错（`compress` 返回原路径）；
// * 视频不压（官方也是原样上传）。
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 上传质量档。
enum PhotoUploadQuality {
  /// 原图（零改动，`compress` 直接返回原路径）
  original('original'),

  /// 高：长边 ≤ 2048、JPEG q88（日常分享够用）
  high('high'),

  /// 中：长边 ≤ 1600、JPEG q80
  medium('medium'),

  /// 低：长边 ≤ 1280、JPEG q70（省流量）
  low('low');

  const PhotoUploadQuality(this.id);

  final String id;

  static PhotoUploadQuality fromId(String? raw) {
    for (final q in values) {
      if (q.id == raw) return q;
    }
    return PhotoUploadQuality.original;
  }
}

/// 档位对应的压缩参数（长边上限 / JPEG 质量）。
class PhotoUploadProfile {
  const PhotoUploadProfile({required this.maxLongSide, required this.jpegQuality});

  final int maxLongSide;
  final int jpegQuality;
}

const Map<PhotoUploadQuality, PhotoUploadProfile> kPhotoUploadProfiles = {
  PhotoUploadQuality.original: PhotoUploadProfile(
    maxLongSide: 0,
    jpegQuality: 100,
  ),
  PhotoUploadQuality.high: PhotoUploadProfile(
    maxLongSide: 2048,
    jpegQuality: 88,
  ),
  PhotoUploadQuality.medium: PhotoUploadProfile(
    maxLongSide: 1600,
    jpegQuality: 80,
  ),
  PhotoUploadQuality.low: PhotoUploadProfile(maxLongSide: 1280, jpegQuality: 70),
};

/// 视频后缀：一律原样上传（压缩只针对静态图）。
const Set<String> kPhotoUploadPassthroughExtensions = {
  'mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp', 'heic', 'heif', 'dng', 'raw',
};

/// 压缩出口（可替换，便于用例注入假实现）。
abstract class PhotoUploadCompressor {
  /// 返回**待上传文件的路径**：压缩成功 = 新临时文件；原图/不支持 = 原路径。
  Future<String> compress({
    required String localPath,
    required PhotoUploadQuality quality,
  });
}

/// 真实实现：`package:image` 解码 → 等比缩放 → JPEG 重编码到临时文件。
class ImageUploadCompressor implements PhotoUploadCompressor {
  ImageUploadCompressor({Directory? tempDir}) : _tempDir = tempDir;

  final Directory? _tempDir;

  @override
  Future<String> compress({
    required String localPath,
    required PhotoUploadQuality quality,
  }) async {
    if (quality == PhotoUploadQuality.original) return localPath;
    final ext = _ext(localPath);
    if (kPhotoUploadPassthroughExtensions.contains(ext)) return localPath;

    Uint8List bytes;
    try {
      bytes = await File(localPath).readAsBytes();
    } catch (_) {
      return localPath; // 读不到就交给上层报错，这里不吞
    }
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return localPath; // 认不出的格式：原样传，不丢内容

    final profile = kPhotoUploadProfiles[quality]!;
    var out = decoded;
    final longSide = decoded.width > decoded.height
        ? decoded.width
        : decoded.height;
    if (profile.maxLongSide > 0 && longSide > profile.maxLongSide) {
      out = decoded.width >= decoded.height
          ? img.copyResize(
              decoded,
              width: profile.maxLongSide,
              interpolation: img.Interpolation.average,
            )
          : img.copyResize(
              decoded,
              height: profile.maxLongSide,
              interpolation: img.Interpolation.average,
            );
    }
    final encoded = img.encodeJpg(out, quality: profile.jpegQuality);
    final dir = _tempDir ?? Directory.systemTemp;
    final name =
        'photo_up_${localPath.hashCode}_${quality.id}_${encoded.length}.jpg';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(encoded, flush: true);
    return file.path;
  }

  static String _ext(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    return path.substring(dot + 1).toLowerCase();
  }
}
