// 文件夹封面（客户端拼图）。
//
// **服务端不给文件夹封面** —— 2026-09-21 在真 NAS 上实测：
// `SYNO.FileStation.Thumb.get` 对目录一律 `404` + 11939 B 的 HTML 错误页
// （同一目录下的图片 200 带真字节）；`size` 换 small/large 都一样，路径加 `..`
// 也一样。所以想让文件夹有自己的封面，只能在客户端拼。
//
// 做法与 DSM 网页版的文件夹磁贴一致：**拿里面的图拼个小九宫格**。
//   * 只对"屏幕上看得见"的文件夹取（provider 是 autoDispose，滚走就停）；
//   * 每个文件夹只打**一次**目录列举（`limit 60`），结果按 `路径 + 目录 mtime`
//     缓存在内存里（目录没变就不重列）；
//   * 某个文件夹一张图都没有（或列举失败/离线）→ 返回空表，UI 退回分类图标，
//     不显示空框、不重试刷屏；
//   * 兼容性：只挑服务端会给缩略图的图片类型（`showsFileThumbnail`），
//     电子书/PDF 不当封面 —— 那要把整本书下下来，为了一个文件夹磁贴不值得。
//
// 照片相册（Photos）**不用**这条路：它有自己的服务端封面
// （`SYNO.Foto.Thumbnail` + `type=folder` + `folder_cover_seq`，见 `foto_api.dart`）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/media/aspect_image.dart';
import '../../data/dto/file_entry_dto.dart';
import 'file_providers.dart';
import 'file_thumb.dart';

/// 最多拼几张（2×2）
const int kFolderCoverMaxImages = 4;

/// 目录列举时最多看多少条 —— 只要找到 4 张图就够，不必列完整个目录
const int kFolderCoverScanLimit = 60;

/// 一个文件夹的封面请求。`mtime` 参与缓存键：目录内容变了（mtime 变）就重列。
@immutable
class FolderCoverRequest {
  const FolderCoverRequest({required this.path, required this.mtime});

  final String path;
  final int mtime;

  factory FolderCoverRequest.of(FileEntryDto entry) =>
      FolderCoverRequest(path: entry.path, mtime: entry.mtime);

  @override
  bool operator ==(Object other) =>
      other is FolderCoverRequest && other.path == path && other.mtime == mtime;

  @override
  int get hashCode => Object.hash(path, mtime);
}

/// 列一个目录（测试里替换成假实现）
typedef FolderImageLister =
    Future<List<FileEntryDto>> Function(String folderPath);

final folderImageListerProvider = Provider<FolderImageLister>((ref) {
  return (folderPath) async {
    final api = ref.watch(fileApiProvider);
    if (api == null) return const [];
    final result = await api.listFolder(
      folderPath: folderPath,
      limit: kFolderCoverScanLimit,
    );
    return result.entries;
  };
});

/// 一个文件夹的封面图（0~4 张）。空表 = 没图 → UI 退回分类图标。
final folderCoverProvider = FutureProvider.autoDispose
    .family<List<Uint8List>, FolderCoverRequest>((ref, req) async {
      final entries =
          FolderCoverCache.get(req.path, req.mtime) ??
          await _listImages(ref, req, store: true);
      final out = <Uint8List>[];
      for (final e in entries.take(kFolderCoverMaxImages)) {
        try {
          final bytes = await ref.read(
            fileThumbProvider(FileThumbRequest.of(e, ThumbScale.small)).future,
          );
          if (bytes != null && bytes.isNotEmpty && looksLikeImage(bytes)) {
            out.add(bytes);
          }
        } catch (_) {
          // 单张失败就当没有这张，不影响整个磁贴
        }
      }
      return out;
    });

Future<List<FileEntryDto>> _listImages(
  Ref ref,
  FolderCoverRequest req, {
  required bool store,
}) async {
  try {
    final lister = ref.read(folderImageListerProvider);
    final entries = await lister(req.path);
    final images = [
      for (final e in entries)
        if (!e.isDir && showsFileThumbnail(e)) e,
    ];
    if (store) FolderCoverCache.put(req.path, req.mtime, images);
    return images;
  } catch (_) {
    // 权限不足 / 离线 / 目录已删：当作"没有封面"，不打扰用户
    if (store) FolderCoverCache.put(req.path, req.mtime, const []);
    return const [];
  }
}

/// 进程内的"目录 → 里面能当封面的图"小缓存。
///
/// 为什么要它：provider 是 autoDispose 的，来回滚动会把同一批文件夹反复重建；
/// 没有这层缓存就会反复打目录列举。上限 400 个文件夹，超了丢最旧的。
@visibleForTesting
class FolderCoverCache {
  FolderCoverCache._();

  static const int maxEntries = 400;
  static final Map<String, ({int mtime, List<FileEntryDto> images})> _cache =
      {};

  static List<FileEntryDto>? get(String path, int mtime) {
    final hit = _cache[path];
    if (hit == null || hit.mtime != mtime) return null;
    return hit.images;
  }

  static void put(String path, int mtime, List<FileEntryDto> images) {
    if (_cache.length >= maxEntries && !_cache.containsKey(path)) {
      _cache.remove(_cache.keys.first);
    }
    _cache[path] = (mtime: mtime, images: images);
  }

  @visibleForTesting
  static void clear() => _cache.clear();

  @visibleForTesting
  static int get size => _cache.length;
}

/// 文件夹封面磁贴：1 张铺满 / 2 张左右 / 3 张一大两小 / 4 张 2×2。
///
/// 小格子里用 `BoxFit.cover`（这是**拼贴**，不是看图），单张时按真实比例摆。
class FolderCoverMosaic extends StatelessWidget {
  const FolderCoverMosaic({
    super.key,
    required this.images,
    this.size = 40,
    this.radius = 8,
  });

  final List<Uint8List> images;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gap = size >= 36 ? 1.5 : 1.0;
    final r = BorderRadius.circular(radius <= 10 ? 3 : 6);
    final shots = images.take(kFolderCoverMaxImages).toList();
    if (shots.isEmpty) return const SizedBox.shrink();

    Widget cell(int i) => Expanded(
      child: Image.memory(
        shots[i],
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: 160,
        errorBuilder: (_, __, ___) =>
            ColoredBox(color: scheme.surfaceContainerHighest),
      ),
    );

    Widget mosaic;
    if (shots.length == 1) {
      // 单张：按真实比例（不裁），背景色兜底
      final aspect = aspectOfImageBytes(shots.first);
      mosaic = AspectImage(
        aspect: aspect,
        child: Image.memory(
          shots.first,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          cacheWidth: 160,
          errorBuilder: (_, __, ___) =>
              ColoredBox(color: scheme.surfaceContainerHighest),
        ),
      );
    } else if (shots.length == 2) {
      mosaic = Row(
        children: [
          cell(0),
          SizedBox(width: gap),
          cell(1),
        ],
      );
    } else if (shots.length == 3) {
      mosaic = Row(
        children: [
          cell(0),
          SizedBox(width: gap),
          Expanded(
            child: Column(
              children: [
                cell(1),
                SizedBox(height: gap),
                cell(2),
              ],
            ),
          ),
        ],
      );
    } else {
      mosaic = Column(
        children: [
          Expanded(
            child: Row(
              children: [
                cell(0),
                SizedBox(width: gap),
                cell(1),
              ],
            ),
          ),
          SizedBox(height: gap),
          Expanded(
            child: Row(
              children: [
                cell(2),
                SizedBox(width: gap),
                cell(3),
              ],
            ),
          ),
        ],
      );
    }

    return ClipRRect(
      borderRadius: r,
      child: SizedBox(
        width: size,
        height: size,
        child: ColoredBox(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          child: mosaic,
        ),
      ),
    );
  }
}
