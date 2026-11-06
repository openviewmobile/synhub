// P21：**照片地图页**（官方 `MapViewFragment` + `MapViewContentHelper` 的等价物）。
//
// ## 取证（官方到底怎么画的）
//
// * `ui/smartalbum/mapview/MapViewFragment` + `MapViewContentHelper`
//   （`smali_classes4`）—— 官方地图页；
// * 数据来源：`MapViewContentHelper` 直接读 `TimelineImage.getLatitude()/
//   getLongitude()` 打点 —— 也就是说**点来自照片条目自身的坐标**，
//   没有单独的"地图接口"；
// * 底图 = Google Maps SDK（见 `photo_map_tiles.dart` 顶部取证）。
//
// 本仓等价实现：`Browse.Item/list`（`additional` 含 `gps`）取时间轴条目 →
// 只留有坐标的 → 在**自研瓦片地图**上打点。坐标原点（wgs84）不做任何猜测换算。
//
// ## 与官方的差别（诚实登记）
//
// 官方是"一张照片一个 pin"；本页默认**按格子聚合**（点多时更好用），
// 这是**我们自己的界面选择**，不是官方行为 —— 差距表里按"自研增强"记，
// 不算官方对齐项。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import '../../core/i18n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/foto_dto.dart';
import '../../data/region/device_location.dart';
import '../calendar/calendar_env.dart' show deviceLocationProbeProvider;
import 'photo_map_tiles.dart';
import 'photo_viewer_page.dart';
import 'photo_providers.dart';

/// 一次取多少条用来打点（官方地图页也是按当前时间轴窗口取）。
const int kPhotoMapPageSize = 500;

/// 聚合格子的参考缩放级（越小格子越大、聚合越狠）。
///
/// 只用于**把标记分组**，不代表地图当前缩放（地图自己可以缩放/平移）。
const int kPhotoMapClusterZoom = 12;

/// 有坐标的照片（`Browse.Item/list` + `additional=["thumbnail","favorite","gps"]`）。
///
/// **没有坐标的条目直接丢掉**（不放到 `(0,0)` 这种假位置 —— 那是几内亚湾）。
final photoGeotaggedItemsProvider = FutureProvider.autoDispose
    .family<List<FotoItemDto>, int>((ref, limit) async {
      final api = ref.watch(fotoApiProvider);
      if (api == null) return const [];
      final items = await api.timeline(limit: limit);
      return [
        for (final it in items)
          if (it.hasGps) it,
      ];
      // Riverpod 3 默认会**自动重试**失败的 provider ⇒ 界面会一直停在 loading。
      // 这里不重试：错误就是错误，交给页面显示错误态 + 手动重试。
    }, retry: (_, _) => null);

/// 一组落进同一个格子的照片。
class PhotoMapCluster {
  const PhotoMapCluster({required this.key, required this.items});

  final String key;
  final List<FotoItemDto> items;

  bool get isSingle => items.length == 1;
  double get latitude => items.first.gps!.latitude;
  double get longitude => items.first.gps!.longitude;
}

/// 把有坐标的照片按 [zoom] 级瓦片格子聚合（纯函数，可单测）。
///
/// * 同格子的照片合成一个簇，簇的位置取**簇内第一张**（顺序稳定）；
/// * 单张的簇就是普通标记。
List<PhotoMapCluster> clusterGeotaggedItems(
  List<FotoItemDto> items, {
  int zoom = kPhotoMapClusterZoom,
}) {
  final buckets = <String, List<FotoItemDto>>{};
  final order = <String>[];
  for (final it in items) {
    final gps = it.gps;
    if (gps == null) continue;
    final t = PhotoMapProjection.tile(gps.latitude, gps.longitude, zoom);
    final key = '$zoom/${t.x}/${t.y}';
    if (!buckets.containsKey(key)) {
      order.add(key);
      buckets[key] = <FotoItemDto>[];
    }
    buckets[key]!.add(it);
  }
  return [
    for (final k in order) PhotoMapCluster(key: k, items: buckets[k]!),
  ];
}

/// 打开照片地图页。
Future<void> openPhotoMapPage(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(builder: (_) => const PhotoMapPage()),
    );

/// 照片地图页（自研瓦片底图 + 坐标聚合打点 + 「我的位置」）。
class PhotoMapPage extends ConsumerStatefulWidget {
  const PhotoMapPage({super.key, this.limit = kPhotoMapPageSize});

  final int limit;

  @override
  ConsumerState<PhotoMapPage> createState() => _PhotoMapPageState();
}

class _PhotoMapPageState extends ConsumerState<PhotoMapPage> {
  /// 「我的位置」拿到的坐标（null = 没定位过 / 用户没给权限）
  DeviceLocation? _me;

  /// 当前瓦片图层。**初值取全仓唯一的默认常量**（r440）：本网络里 OSM 直连
  /// 不可达（`photo_map_tiles.dart` 有实测），默认写它 ⇒ 打开就是一屏灰。
  /// "图层"按钮在 [kPhotoMapTileSources] 之间轮换。
  PhotoMapTileSource _layer = kPhotoDefaultTileSource;

  /// 切到下一个图层（唯一入口，保证顺序稳定、可重复）。
  void _cycleLayer() {
    final i = kPhotoMapTileSources.indexOf(_layer);
    setState(() {
      _layer = kPhotoMapTileSources[(i + 1) % kPhotoMapTileSources.length];
    });
  }

  @override
  Widget build(BuildContext context) {
    final limit = widget.limit;
    final value = ref.watch(photoGeotaggedItemsProvider(limit));
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.photoMapTitle),
        actions: [
          IconButton(
            key: const Key('photo-map-layer-toggle'),
            tooltip: context.t.photoMapLayerTooltip(_layer.name),
            icon: const Icon(Icons.layers_outlined),
            onPressed: _cycleLayer,
          ),
          IconButton(
            key: const Key('photo-map-refresh'),
            tooltip: context.t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(photoGeotaggedItemsProvider(limit)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('photo-map-my-location'),
        tooltip: context.t.photoMapMyLocation,
        onPressed: _locateMe,
        child: const Icon(Icons.my_location),
      ),
      body: value.when(
        loading: () => const Center(
          child: CircularProgressIndicator(key: Key('photo-map-loading')),
        ),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.map_outlined, size: 48),
                const SizedBox(height: 12),
                Text(
                  context.t.photoMapLoadFailed('$err'),
                  key: const Key('photo-map-error'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('photo-map-retry'),
                  onPressed: () =>
                      ref.invalidate(photoGeotaggedItemsProvider(limit)),
                  child: Text(context.t.photoRetry),
                ),
              ],
            ),
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.t.photoMapNoGeotagged,
                  key: const Key('photo-map-empty'),
                ),
              ),
            );
          }
          final clusters = clusterGeotaggedItems(items);
          // 地图中心 = 所有簇的**坐标平均**（点少时不用管，点多时也还行）；
          // 定位过就把自己放进去（"我的位置"点完地图要跟过去）
          var lat = 0.0;
          var lng = 0.0;
          for (final c in clusters) {
            lat += c.latitude;
            lng += c.longitude;
          }
          lat /= clusters.length;
          lng /= clusters.length;
          final me = _me;
          if (me != null) {
            lat = me.latitude;
            lng = me.longitude;
          }
          return Column(
            children: [
              PhotoTileMap(
                key: const Key('photo-map-photos'),
                latitude: lat,
                longitude: lng,
                height: 360,
                source: _layer,
                zoom: me == null ? null : 14,
                markers: [
                  if (me != null)
                    PhotoMapMarker(
                      id: 'me',
                      latitude: me.latitude,
                      longitude: me.longitude,
                      label: context.t.photoMapMyLocation,
                    ),
                  for (final c in clusters)
                    PhotoMapMarker(
                      id: c.key,
                      latitude: c.latitude,
                      longitude: c.longitude,
                      label: c.isSingle
                          ? c.items.first.filename
                          : context.t.photoMapNPhotos(c.items.length),
                    ),
                ],
              ),
              Expanded(
                child: ListView.separated(
                  key: const Key('photo-map-cluster-list'),
                  itemCount: clusters.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _ClusterTile(
                    cluster: clusters[i],
                    onOpen: () => _openCluster(context, ref, clusters[i]),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 「我的位置」：先要权限，再取一次坐标。
  ///
  /// 拿不到就**明确说**（权限被拒 / 本机没有定位能力 / 定位失败三种），
  /// 且**不动地图** —— 不编一个假坐标出来。
  Future<void> _locateMe() async {
    final messenger = ScaffoldMessenger.of(context);
    final probe = ref.read(deviceLocationProbeProvider);
    final permission = await probe.ensurePermission();
    if (!mounted) return;
    switch (permission) {
      case LocationPermission.unsupported:
        messenger.showSnackBar(
          SnackBar(content: Text(context.t.photoMapNoLocationSupport)),
        );
        return;
      case LocationPermission.denied:
        messenger.showSnackBar(
          SnackBar(content: Text(context.t.photoMapLocationDenied)),
        );
        return;
      case LocationPermission.granted:
        break;
    }
    final loc = await probe.current();
    if (!mounted) return;
    if (loc == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(context.t.photoMapLocationFailed)),
      );
      return;
    }
    setState(() => _me = loc);
  }

  Future<void> _openCluster(
    BuildContext context,
    WidgetRef ref,
    PhotoMapCluster cluster,
  ) async {
    if (cluster.isSingle) {
      _openViewer(context, ref, cluster.items, 0);
      return;
    }
    final index = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          key: const Key('photo-map-cluster-sheet'),
          shrinkWrap: true,
          children: [
            for (var i = 0; i < cluster.items.length; i++)
              DesignRowTile(
                key: Key('photo-map-cluster-item-${cluster.items[i].id}'),
                leading: const Icon(Icons.photo_outlined),
                title: Text(cluster.items[i].filename),
                onTap: () => Navigator.of(context).pop(i),
              ),
          ],
        ),
      ),
    );
    if (index == null || !context.mounted) return;
    _openViewer(context, ref, cluster.items, index);
  }

  void _openViewer(
    BuildContext context,
    WidgetRef ref,
    List<FotoItemDto> items,
    int index,
  ) {
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(items: items, index: index),
      ),
    );
  }
}

class _ClusterTile extends StatelessWidget {
  const _ClusterTile({required this.cluster, required this.onOpen});

  final PhotoMapCluster cluster;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => DesignRowTile(
    key: Key('photo-map-cluster-${cluster.key}'),
    leading: Icon(
      cluster.isSingle ? Icons.place_outlined : Icons.layers_outlined,
    ),
    title: Text(
      cluster.isSingle
          ? cluster.items.first.filename
          : context.t.photoMapClusterN(cluster.items.length),
    ),
    subtitle: Text(
      '${cluster.latitude.toStringAsFixed(4)}, '
      '${cluster.longitude.toStringAsFixed(4)}',
    ),
    onTap: onOpen,
  );
}
