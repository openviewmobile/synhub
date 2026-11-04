// 相册「最近添加」页面（`Browse.RecentlyAdded/list`）。
//
// 只读浏览：网格 → 点开复用既有 `PhotoViewerPage`（不另造轮子）。
//
// 层级分工（本文件只做页面）：
//   * 数据 provider = `photoRecentlyAddedProvider`（`photo_providers.dart`）；
//   * 入口可见性 = `photoC2AvailabilityProvider` 的 `recentlyAdded` 能力位
//     （`photo_c2_providers.dart`；能力表缺 `SYNO.Foto.Browse.RecentlyAdded`
//     → 入口隐藏，连探测都不发）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/foto_dto.dart';
import 'photo_c2_sections.dart';
import 'photo_providers.dart';
import 'photo_recent_text.dart';
import 'photo_viewer_page.dart';
import 'photo_widgets.dart';

class PhotoRecentlyAddedPage extends ConsumerWidget {
  const PhotoRecentlyAddedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(fotoSpaceProvider);
    final async = ref.watch(photoRecentlyAddedProvider);
    return PhotoC2Scaffold(
      pageKey: const Key('photo-c2-recent-page'),
      title: photoRecent(PhotoRecentTextKeys.title, '最近添加'),
      body: PhotoAsync<List<FotoItemDto>>(
        value: RiverpodAsync(async),
        emptyTitle: photoRecent(PhotoRecentTextKeys.emptyTitle, '还没有最近添加的内容'),
        emptyMessage: photoRecent(
          PhotoRecentTextKeys.emptyMessage,
          'NAS 端索引完成后，最近加入的照片会出现在这里。',
        ),
        emptyIcon: Icons.new_releases_outlined,
        isEmpty: (items) => items.isEmpty,
        onRetry: () => ref.invalidate(photoRecentlyAddedProvider),
        builder: (items) => PhotoGrid(
          key: const Key('photo-c2-recent-grid'),
          items: items,
          space: space,
          size: 'm',
          onTap: (i) => _openViewer(context, items, i),
        ),
      ),
    );
  }
}

/// 点开大图（与 `photo_wave2_page.dart` 同一个形态；那边是文件私有函数，这里复制）
void _openViewer(BuildContext context, List<FotoItemDto> items, int index) {
  Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PhotoViewerPage(items: items, index: index),
    ),
  );
}
