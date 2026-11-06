// 相册**应用内地图**（自研，不依赖 Google Maps SDK）。
//
// ## 为什么自研（取证）
//
// 官方安卓版用的是 **Google Maps SDK for Android**：
// `smali_classes2/com/google/android/gms/maps/{SupportMapFragment,MapView,
// GoogleMap,StreetViewPanorama}.smali` + `databinding/FragmentMapViewBinding`，
// 全景另有 `libpanorenderer.so` / `libpano_video_renderer.so`（Google VR）。
// GMS Maps 需要 **Google API key + Play 服务**：本客户端不引入 GMS（无 key、
// 离线/无 GMS 设备也要能用）⇒ 按"协议不通就自研"的原则，自己画瓦片地图。
//
// ## 自研范围（只做地图该做的事，不发明协议）
//
// * **Web Mercator 投影**（与官方/所有瓦片地图一致的公开标准，EPSG:3857）；
// * **瓦片拼接 + 平移 + 缩放**（raster tile，默认见 [kPhotoDefaultTileSource]）；
// * **标记点**（照片 GPS / 地点中心）；
// * 瓦片来源可用 [photoMapTileSourceProvider] 换（用例注入假 source/fetcher）：
//   **测试期一个字节都不出网**。
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';


/// 瓦片边长（OSM/谷歌通用 256）。
const int kPhotoTileSize = 256;

/// 纬度可投影范围（Web Mercator 的公开上限）。
const double kPhotoMapMaxLatitude = 85.05112878;

/// 一个地图标记。
class PhotoMapMarker {
  const PhotoMapMarker({
    required this.id,
    required this.latitude,
    required this.longitude,
    this.label = '',
  });

  final String id;
  final double latitude;
  final double longitude;
  final String label;
}

/// Web Mercator 投影（纯函数，可单测）。
///
/// 世界坐标 = `256 * 2^zoom` 像素，左上角为 (0,0)；公式是公开标准
/// （OSM/Google/几乎所有瓦片地图都用这一套），不是我们自己发明的。
class PhotoMapProjection {
  const PhotoMapProjection._();

  static double _clampLat(double lat) =>
      lat.clamp(-kPhotoMapMaxLatitude, kPhotoMapMaxLatitude);

  /// 经纬度 → 世界像素坐标。
  static Offset worldPoint(double latitude, double longitude, double zoom) {
    final scale = kPhotoTileSize * (1 << zoom.floor());
    final lat = _clampLat(latitude);
    final x = (longitude + 180.0) / 360.0 * scale;
    final sinLat = math.sin(lat * math.pi / 180.0);
    final y = (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) *
        scale;
    return Offset(x, y);
  }

  /// 世界像素坐标 → 经纬度（[worldPoint] 的逆）。
  static ({double latitude, double longitude}) latLng(
    Offset point,
    double zoom,
  ) {
    final scale = kPhotoTileSize * (1 << zoom.floor());
    final lng = point.dx / scale * 360.0 - 180.0;
    final n = math.pi - 2 * math.pi * point.dy / scale;
    final lat = math.atan(_sinh(n)) * 180.0 / math.pi;
    return (latitude: lat, longitude: lng);
  }

  /// 某经纬度落在缩放级 [zoom] 的哪张瓦片上（(0,0) 在左上）。
  static ({int x, int y}) tile(double latitude, double longitude, int zoom) {
    final p = worldPoint(latitude, longitude, zoom.toDouble());
    final max = (1 << zoom) - 1;
    return (
      x: (p.dx / kPhotoTileSize).floor().clamp(0, max),
      y: (p.dy / kPhotoTileSize).floor().clamp(0, max),
    );
  }

  static double _sinh(double v) => (math.exp(v) - math.exp(-v)) / 2;
}

/// 瓦片来源（URL 模板 + 版权署名）。
class PhotoMapTileSource {
  const PhotoMapTileSource({
    required this.name,
    required this.urlTemplate,
    required this.attribution,
    this.maxZoom = 19,
  });

  final String name;

  /// 形如 `https://tile.openstreetmap.org/{z}/{x}/{y}.png`
  final String urlTemplate;
  final String attribution;
  final int maxZoom;

  Uri tileUri(int z, int x, int y) => Uri.parse(
    urlTemplate
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y'),
  );
}

/// OSM 标准瓦片（公开、无 key）—— **可切，但不再是默认**。
///
/// r440 实测（本机直连，15 s 超时 ×2）：`tile.openstreetmap.org` **TCP 连不上**
/// （`curl` 报 `000 Connection timed out`）；**只有走本机代理才 200**
/// （6,987 B / 1.0 s）。App 里没有代理 ⇒ 默认用它 ⇒ 打开地图**一片灰**，
/// 用户得自己点「图层」才看得见图。
/// 保留它在图层清单里：换一个能直连 OSM 的网络仍有意义。
const PhotoMapTileSource kPhotoOsmTileSource = PhotoMapTileSource(
  name: 'OpenStreetMap',
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  attribution: '© OpenStreetMap contributors',
);

/// 街道图瓦片源 = **OSM 的德国社区镜像** `tile.openstreetmap.de`（公开、**无需 key**）。
///
/// 为什么不是别的（r440 实测，本机直连，上海 `121.4737 / 31.2304`，**看的是瓦片内容**）：
///   * `tile.openstreetmap.org`   ⇒ 直连**连不上**（15 s 超时 ×2；走代理才 200）；
///   * **Esri World Street Map**  ⇒ z12 有真图（52,358 B），但 **z14 返回
///     服务端自带的「Map data not yet available」占位图**（2,521 B）——
///     而地图页**初始就是 z14** ⇒ 换成它等于"没有报错、但还是一片灰"；
///   * **Carto**（`basemaps.cartocdn.com` light/voyager）⇒ z14 两个样式返回**逐字节相同**
///     的 2,049 B 占位图 ⇒ 同样不可用；
///   * **本镜像** ⇒ z14–z19 **真图**（36,573 B / 28,315 B / 21,819 B / 13,349 B / 10,519 B，
///     256×256 PNG），是标准 OSM Carto 样式、**带中文地名**（延安东路 · E Yan'an Rd. /
///     大世界 Dashijie / 八仙桥 Baxianqiao）。
/// 代价如实记：本镜像 **6/6 命中、平均 1.7–5.5 s/张**（同批读数 Esri 影像 0.55 s/张）
/// —— 慢，但**有图**；想快或要卫星图，点「图层」切到 Esri World Imagery。
const PhotoMapTileSource kPhotoStreetTileSource = PhotoMapTileSource(
  name: 'OpenStreetMap (de mirror)',
  urlTemplate: 'https://tile.openstreetmap.de/{z}/{x}/{y}.png',
  attribution: '© OpenStreetMap contributors',
  maxZoom: 19,
);

/// ★ **默认瓦片源**（唯一真源）。
///
/// 为什么不是 OSM：见 [kPhotoOsmTileSource] 的实测（本网络直连不可达）。
/// 全仓只有这一处定义"默认是哪一层"—— 页面与 provider **都**读它，
/// 不允许各自再写一份（历史上 `photo_map_page.dart` 就自带了一份 OSM 默认，
/// 于是"改默认源"这种改动只改一处会半生效）。
const PhotoMapTileSource kPhotoDefaultTileSource = kPhotoStreetTileSource;

/// 影像（卫星）瓦片源 = **Esri World Imagery**（公开服务、**无需 key**）。
///
/// 为什么是它而不是 Google 卫星图：官方安卓相册用 GMS Maps SDK 的
/// `MapType.SATELLITE`（需 Google API key + Play 服务）；本客户端不引 GMS
/// ⇒ 换一个**公开、无 key、稳定**的影像瓦片源。模板顺序是 `{z}/{y}/{x}`
/// （Esri 的 MapServer 约定），与 OSM 的 `{z}/{x}/{y}` 不同 ——
/// [PhotoMapTileSource.tileUri] 按占位符替换，顺序由模板自己决定。
const PhotoMapTileSource kPhotoImageryTileSource = PhotoMapTileSource(
  name: 'Esri World Imagery',
  urlTemplate:
      'https://server.arcgisonline.com/ArcGIS/rest/services/'
      'World_Imagery/MapServer/tile/{z}/{y}/{x}',
  attribution: 'Imagery © Esri, Maxar, Earthstar Geographics',
  maxZoom: 19,
);

/// 图层清单（界面上"图层"按钮按这个顺序切）。
///
/// **第一项就是默认源**（`kPhotoMapTileSources.first == kPhotoDefaultTileSource`
/// 有用例守着）—— 省得"默认"和"清单首项"两处各说各话。
const List<PhotoMapTileSource> kPhotoMapTileSources = [
  kPhotoStreetTileSource,
  kPhotoImageryTileSource,
  kPhotoOsmTileSource,
];

/// 瓦片字节抓取器（用例注入假实现 ⇒ 零出网）。
abstract class PhotoMapTileFetcher {
  Future<Uint8List?> fetch(Uri uri);
}

/// 真机默认实现：直接 HTTP GET，**不缓存到磁盘**（内存缓存由 widget 持有）。
class HttpPhotoMapTileFetcher implements PhotoMapTileFetcher {
  HttpPhotoMapTileFetcher({HttpClient? client})
    : _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 8));

  final HttpClient _client;

  static const Map<String, String> _headers = {
    // 官方瓦片服务要求带 UA，否则会 403
    'User-Agent': 'synhub/1.0 (photo map)',
  };

  @override
  Future<Uint8List?> fetch(Uri uri) async {
    try {
      final req = await _client.getUrl(uri);
      _headers.forEach(req.headers.set);
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final bytes = await res.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      return bytes.takeBytes();
    } on Object {
      return null;
    }
  }
}

/// 默认瓦片源（sheet 里的应用内地图走这条；页面可显式传 [PhotoTileMap.source]）。
final photoMapTileSourceProvider = Provider<PhotoMapTileSource>(
  (ref) => kPhotoDefaultTileSource,
);

final photoMapTileFetcherProvider = Provider<PhotoMapTileFetcher>(
  (ref) => HttpPhotoMapTileFetcher(),
);

/// 应用内瓦片地图：可平移、可缩放、带标记。
///
/// * 只抓**视口内**的瓦片；抓不到就留空位（**不画假图**，也不崩）；
/// * 内存在 State 里缓存，至少不会因为一次 rebuild 重复下载；
/// * 地图版权署名常驻左下角（OSM 的使用条款要求）。
class PhotoTileMap extends ConsumerStatefulWidget {
  const PhotoTileMap({
    super.key,
    required this.latitude,
    required this.longitude,
    this.markers = const [],
    this.initialZoom = 14,
    this.height = 220,
    this.zoom,
    this.source,
  });

  final double latitude;
  final double longitude;
  final List<PhotoMapMarker> markers;
  final int initialZoom;
  final double height;

  /// 受控缩放（"我的位置"等外部操作要改缩放时给值）；null = 内部自己管。
  final double? zoom;

  /// 指定瓦片源（图层切换）；null = 用 [photoMapTileSourceProvider] 的默认源。
  final PhotoMapTileSource? source;

  @override
  ConsumerState<PhotoTileMap> createState() => _PhotoTileMapState();
}

class _PhotoTileMapState extends ConsumerState<PhotoTileMap> {
  late double _zoom = widget.initialZoom.toDouble();
  late double _centerLat = widget.latitude;
  late double _centerLng = widget.longitude;
  final Map<Uri, Uint8List?> _cache = {};
  final Set<Uri> _inflight = {};

  /// 抓取**已经结束**的瓦片（成功与否都算）——用来判"这一屏到底加载出来没有"。
  ///
  /// DA85：`fetch` 失败时返回 `null`（`HttpPhotoMapTileFetcher` 吞掉异常），
  /// 旧实现只是把空位留灰，**既不说原因、也不给重试**（刷新按钮只刷条目、
  /// 不清瓦片缓存 ⇒ 抓不到的瓦片会一直灰着）。现在按"是否已有非空字节"判。
  bool _viewportAllFailed(List<Uri> viewport) {
    var anyDone = false;
    for (final u in viewport) {
      if (!_cache.containsKey(u)) continue; // 还在抓
      anyDone = true;
      final b = _cache[u];
      if (b != null && b.isNotEmpty) return false; // 有真图 ⇒ 不算失败
    }
    return anyDone;
  }

  /// 重试当前视口：清掉失败记录后重新抓（失败不算"已抓过"，所以要清缓存）。
  void _retryTiles() {
    setState(() {
      _cache.removeWhere((_, v) => v == null || v.isEmpty);
      _inflight.clear();
    });
  }
  late final PhotoMapTileFetcher _fetcher = ref.read(
    photoMapTileFetcherProvider,
  );
  PhotoMapTileSource get _source =>
      widget.source ?? ref.read(photoMapTileSourceProvider);

  int get _zoomInt => _zoom.floor().clamp(0, _source.maxZoom);

  void _zoomBy(double delta) {
    setState(() {
      _zoom = (_zoom + delta).clamp(1.0, _source.maxZoom.toDouble());
    });
  }

  void _panBy(Offset delta) {
    // 屏幕位移 → 世界位移（向左拖 = 地图右移 = 中心东移）
    setState(() {
      final center = PhotoMapProjection.worldPoint(
        _centerLat,
        _centerLng,
        _zoom,
      );
      final moved = Offset(center.dx + delta.dx, center.dy + delta.dy);
      final ll = PhotoMapProjection.latLng(moved, _zoom);
      _centerLat = ll.latitude.clamp(-kPhotoMapMaxLatitude, kPhotoMapMaxLatitude);
      _centerLng = ((ll.longitude + 180) % 360) - 180;
    });
  }

  Future<void> _ensureTile(int z, int x, int y) async {
    final max = (1 << z) - 1;
    if (y < 0 || y > max) return;
    final wrappedX = x < 0 ? x + max + 1 : (x > max ? x - max - 1 : x);
    final uri = _source.tileUri(z, wrappedX, y);
    if (_cache.containsKey(uri) || _inflight.contains(uri)) return;
    _inflight.add(uri);
    final bytes = await _fetcher.fetch(uri);
    _inflight.remove(uri);
    if (!mounted) return;
    setState(() => _cache[uri] = bytes);
  }

  @override
  void didUpdateWidget(covariant PhotoTileMap old) {
    super.didUpdateWidget(old);
    // 父级换了中心/缩放（例如点了"我的位置"）⇒ 跟着走
    if (old.source != widget.source) {
      _cache.clear();
      _inflight.clear();
    }
    if (old.latitude != widget.latitude ||
        old.longitude != widget.longitude ||
        (widget.zoom != null && widget.zoom != old.zoom)) {
      _centerLat = widget.latitude;
      _centerLng = widget.longitude;
      if (widget.zoom != null) _zoom = widget.zoom!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          final center = PhotoMapProjection.worldPoint(
            _centerLat,
            _centerLng,
            _zoom,
          );
          final origin = Offset(
            center.dx - size.width / 2,
            center.dy - size.height / 2,
          );
          final z = _zoomInt;
          final firstX = (origin.dx / kPhotoTileSize).floor();
          final firstY = (origin.dy / kPhotoTileSize).floor();
          final cols = (size.width / kPhotoTileSize).ceil() + 1;
          final rows = (size.height / kPhotoTileSize).ceil() + 1;
          final max = (1 << z) - 1;

          // 触发视口内瓦片的抓取（抓不到就留空位）
          final viewport = <Uri>[];
          for (var dx = 0; dx < cols; dx++) {
            for (var dy = 0; dy < rows; dy++) {
              final ty = firstY + dy;
              if (ty < 0 || ty > max) continue;
              final tx = firstX + dx;
              final wx = tx < 0
                  ? tx + max + 1
                  : (tx > max ? tx - max - 1 : tx);
              viewport.add(_source.tileUri(z, wx, ty));
              unawaited(_ensureTile(z, tx, ty));
            }
          }
          // DA85：整屏瓦片一张都没抓到时，**明说**这是底图加载失败，
          // 并且**给出路**（重试 / 换图源）——不再静默留一片灰。
          final showTileFailure = viewport.isNotEmpty && _viewportAllFailed(viewport);

          return ClipRect(
            child: Stack(
              key: const Key('photo-map-tiles'),
              children: [
                GestureDetector(
                  onPanUpdate: (d) => _panBy(d.delta),
                  child: Stack(
                    children: [
                      for (var dx = 0; dx < cols; dx++)
                        for (var dy = 0; dy < rows; dy++)
                          _tileAt(
                            z: z,
                            x: firstX + dx,
                            y: firstY + dy,
                            left: (firstX + dx) * kPhotoTileSize - origin.dx,
                            top: (firstY + dy) * kPhotoTileSize - origin.dy,
                          ),
                      for (final m in widget.markers)
                        _markerAt(m, origin, size),
                    ],
                  ),
                ),
                if (showTileFailure)
                  // ★ 放在**底部**（版权署名之上）：顶部右侧是缩放 ± 按钮，
                  // 放上面会盖住它们（r426 真机像素当场撞到）。
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 26,
                    child: Material(
                      color: Colors.white.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        key: const Key('photo-map-tiles-unavailable'),
                        onTap: _retryTiles,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.cloud_off_outlined,
                                size: 16,
                                color: Colors.black87,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  context.t.photoMapTilesUnavailable,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.black87,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.refresh,
                                size: 16,
                                color: Colors.black87,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Text(
                    _source.attribution,
                    key: const Key('photo-map-attribution'),
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.black54,
                      backgroundColor: Colors.white70,
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: Column(
                    children: [
                      _ZoomButton(
                        keyName: 'photo-map-zoom-in',
                        icon: Icons.add,
                        onTap: () => _zoomBy(1),
                      ),
                      const SizedBox(height: 6),
                      _ZoomButton(
                        keyName: 'photo-map-zoom-out',
                        icon: Icons.remove,
                        onTap: () => _zoomBy(-1),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _tileAt({
    required int z,
    required int x,
    required int y,
    required double left,
    required double top,
  }) {
    final max = (1 << z) - 1;
    if (y < 0 || y > max) return const SizedBox.shrink();
    final wx = x < 0 ? x + max + 1 : (x > max ? x - max - 1 : x);
    final bytes = _cache[_source.tileUri(z, wx, y)];
    return Positioned(
      left: left,
      top: top,
      width: kPhotoTileSize.toDouble(),
      height: kPhotoTileSize.toDouble(),
      child: bytes == null
          // 还没抓到 / 抓不到：留空位（不画假图）
          ? const ColoredBox(color: Color(0xFFEFEFEF))
          : Image.memory(
              bytes,
              gaplessPlayback: true,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: Color(0xFFEFEFEF)),
            ),
    );
  }

  Widget _markerAt(PhotoMapMarker m, Offset origin, Size size) {
    final p = PhotoMapProjection.worldPoint(m.latitude, m.longitude, _zoom);
    final left = p.dx - origin.dx - 12;
    final top = p.dy - origin.dy - 24;
    if (left < -32 || top < -32 || left > size.width + 32 || top > size.height + 32) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: left,
      top: top,
      child: Tooltip(
        message: m.label,
        child: Icon(
          Icons.place,
          key: Key('photo-map-marker-${m.id}'),
          size: 24,
          color: Colors.red.shade700,
        ),
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.keyName,
    required this.icon,
    required this.onTap,
  });

  final String keyName;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    elevation: 2,
    shape: const CircleBorder(),
    child: InkWell(
      key: Key(keyName),
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, size: 18)),
    ),
  );
}

/// 给用例/调试用：回一眼默认瓦片源（公开信息，不含任何 key）。
String photoMapTileSourceSummary() => jsonEncode({
  'name': kPhotoDefaultTileSource.name,
  'maxZoom': kPhotoDefaultTileSource.maxZoom,
  'layers': [for (final s in kPhotoMapTileSources) s.name],
});
