// P21：应用内瓦片地图（自研，不依赖 GMS）的离线用例。
//
// 全部走**假瓦片 source + 假 fetcher** ⇒ 一个字节都不出网。
//
// r440（`DA94`）：**默认底图源**从 OSM 换成可直连的 Esri World Street Map。
// 真机 A/B 判据 = 打开地图**不碰「图层」按钮**时瓦片渲不渲染（像素）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/photos/photo_map_tiles.dart';

/// 1×1 透明 PNG。
final Uint8List _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

class FakeTileFetcher implements PhotoMapTileFetcher {
  FakeTileFetcher({this.serve = true});

  /// 可变：重试用例中途把"抓不到"改成"抓得到"（DA85）。
  bool serve;
  final List<Uri> requested = [];

  @override
  Future<Uint8List?> fetch(Uri uri) async {
    requested.add(uri);
    return serve ? _png : null;
  }
}

const _fakeSource = PhotoMapTileSource(
  name: 'test-tiles',
  urlTemplate: 'https://tiles.invalid/{z}/{x}/{y}.png',
  attribution: '© test',
  maxZoom: 19,
);

Future<FakeTileFetcher> _pump(
  WidgetTester tester, {
  bool serve = true,
  List<PhotoMapMarker> markers = const [],
  FakeTileFetcher? fetcher,
}) async {
  fetcher ??= FakeTileFetcher(serve: serve);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        photoMapTileSourceProvider.overrideWithValue(_fakeSource),
        photoMapTileFetcherProvider.overrideWithValue(fetcher),
      ],
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: PhotoTileMap(
            latitude: 31.2304,
            longitude: 121.4737,
            markers: markers,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return fetcher;
}

void main() {
  group('P21 Web Mercator 投影（纯函数）', () {
    test('零点 / 极点 / 瓦片编号', () {
      final p0 = PhotoMapProjection.worldPoint(0, 0, 0);
      expect(p0.dx, closeTo(128, 0.001));
      expect(p0.dy, closeTo(128, 0.001));
      expect(PhotoMapProjection.tile(0, 0, 0), (x: 0, y: 0));

      // 赤道本初子午线在 z=1 时落在 (1,1) 瓦片
      expect(PhotoMapProjection.tile(0, 0, 1), (x: 1, y: 1));

      // 纬度被夹到 Web Mercator 上限（不会出现无穷大）
      final top = PhotoMapProjection.worldPoint(89.9, 0, 2);
      expect(top.dy, greaterThan(-1), reason: '夹到上限后不会溢出/出负无穷');
      expect(top.dy.isFinite, isTrue);
      final bottom = PhotoMapProjection.worldPoint(-89.9, 0, 2);
      expect(bottom.dy, lessThan(1025), reason: '浮点误差内落在世界范围内');
    });

    test('投影 → 反投影往返（经纬度误差 < 0.1°）', () {
      for (final (lat, lng) in const [
        (31.2304, 121.4737),
        (-33.8688, 151.2093),
        (51.5074, -0.1278),
      ]) {
        final p = PhotoMapProjection.worldPoint(lat, lng, 12);
        final back = PhotoMapProjection.latLng(p, 12);
        expect(back.latitude, closeTo(lat, 0.1));
        expect(back.longitude, closeTo(lng, 0.1));
      }
    });

    test('瓦片 URL 模板替换（z/x/y 都是纯数字）', () {
      final uri = _fakeSource.tileUri(14, 13405, 6686);
      expect(uri.toString(), 'https://tiles.invalid/14/13405/6686.png');
    });

    test('摘要跟着**默认源**走（不再写死 OSM），且没有 key', () {
      expect(kPhotoOsmTileSource.urlTemplate, contains('{z}/{x}/{y}'));
      // r440：默认源已不是 OSM ⇒ 摘要里应是新默认；OSM 仍在图层清单里。
      expect(photoMapTileSourceSummary(), contains(kPhotoDefaultTileSource.name));
      expect(photoMapTileSourceSummary(), contains(kPhotoOsmTileSource.name));
      expect(photoMapTileSourceSummary().toLowerCase(), isNot(contains('key')));
    });
  });

  group('P21 图层（街道 / 影像）', () {
    test('影像源模板是 {z}/{y}/{x}（Esri 约定），且公开无 key', () {
      final uri = kPhotoImageryTileSource.tileUri(10, 843, 389);
      expect(uri.host, 'server.arcgisonline.com');
      // {z}/{y}/{x} ⇒ 路径顺序是 10/389/843（若按 OSM 顺序就会错）
      expect(uri.path, contains('/10/389/843'), reason: uri.path);
      expect(kPhotoImageryTileSource.urlTemplate.toLowerCase(), isNot(contains('key')));
      expect(kPhotoImageryTileSource.attribution, contains('Esri'));
    });

    test('OSM 的 URL 形状没变（它仍是可切的一层）', () {
      final osm = kPhotoOsmTileSource.tileUri(10, 843, 389);
      expect(osm.path, contains('/10/843/389'), reason: osm.path);
      expect(kPhotoMapTileSources, contains(kPhotoOsmTileSource));
    });

    // ★ r440：这三条就是"默认源不许再是不可达的那一层"的守卫。
    test('r440 默认源 = **有数据的**可直连街道图；清单首项与默认是同一个常量', () {
      expect(kPhotoMapTileSources.first, same(kPhotoDefaultTileSource));
      // 默认必须是 OSM 家族（保留"默认是街道图"的产品语义），且是能直连的镜像。
      expect(kPhotoDefaultTileSource.name, contains('OpenStreetMap'));
      expect(
        kPhotoDefaultTileSource.urlTemplate,
        contains('tile.openstreetmap.de'),
      );
      // ★ 判据是 **host 不同**，不是样式：`tile.openstreetmap.de`（默认）与
      // `tile.openstreetmap.org`（清单里的备用层）**URL 形状一样**，
      // 所以只比模板字符串会分不清两者。
      final u = kPhotoDefaultTileSource.tileUri(14, 13718, 6694);
      expect(u.host, 'tile.openstreetmap.de');
      expect(u.path, '/14/13718/6694.png');
      expect(u.toString(), isNot(contains('tile.openstreetmap.org')));
    });

    test('r440 provider 给的默认 == 唯一默认常量（sheet 里的地图走这条）', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(photoMapTileSourceProvider), same(kPhotoDefaultTileSource));
    });

    test('r440 结构性守卫：页面**不再自带一份** OSM 默认（仪器122 认"声明"）', () {
      final src = File(
        'lib/src/features/photos/photo_map_page.dart',
      ).readAsStringSync();
      expect(
        src,
        contains('PhotoMapTileSource _layer = kPhotoDefaultTileSource'),
        reason: '页面初值必须指向全仓唯一的默认常量',
      );
      expect(
        src,
        isNot(contains('PhotoMapTileSource _layer = kPhotoOsmTileSource')),
        reason: '历史上就是这条自带默认让"改默认源"半生效',
      );
      // 反向：这条声明得真的在 `_layer` 上，而不是别处碰巧有同名文本
      expect(RegExp(r'_layer\s*=\s*kPhotoOsmTileSource').hasMatch(src), isFalse);
    });
  });

  group('P21 应用内地图（UI）', () {
    testWidgets('渲染瓦片 + 版权署名 + 标记；请求的瓦片都在假 source 的域下', (tester) async {
      final fetcher = await _pump(
        tester,
        markers: const [
          PhotoMapMarker(id: 'target', latitude: 31.2304, longitude: 121.4737),
        ],
      );
      expect(find.byKey(const Key('photo-map-tiles')), findsOneWidget);
      expect(find.byKey(const Key('photo-map-attribution')), findsOneWidget);
      expect(find.byKey(const Key('photo-map-marker-target')), findsOneWidget);
      expect(fetcher.requested, isNotEmpty, reason: '视口内瓦片应该被抓取');
      expect(
        fetcher.requested.every((u) => u.host == 'tiles.invalid'),
        isTrue,
      );
    });

    testWidgets('抓不到瓦片 ⇒ 留空位、不崩、也不画假图；并**明说**失败（DA85）', (
      tester,
    ) async {
      // DA85：旧实现只留一片灰 —— 用户既不知道是网络问题，也没有重试的路。
      final fetcher = await _pump(tester, serve: false);
      expect(fetcher.requested, isNotEmpty);
      expect(find.byKey(const Key('photo-map-tiles')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('photo-map-tiles-unavailable')),
        findsOneWidget,
        reason: '整屏瓦片都抓不到时必须给出可见提示（DA85）',
      );
      expect(find.byKey(const Key('photo-map-attribution')), findsOneWidget);

      // ★ r426 真机撞到过：提示条压在右上角的缩放 ± 上（像素里那个 `−` 被盖住）。
      // 逐矩形不重叠断言 —— 提示条不许盖住任何控件。
      final notice = tester.getRect(
        find.byKey(const Key('photo-map-tiles-unavailable')),
      );
      for (final k in const ['photo-map-zoom-in', 'photo-map-zoom-out']) {
        final r = tester.getRect(find.byKey(Key(k)));
        expect(
          notice.overlaps(r),
          isFalse,
          reason: '$k $r 被提示条 $notice 盖住（DA85 的布局回归）',
        );
      }
      expect(
        notice.overlaps(
          tester.getRect(find.byKey(const Key('photo-map-attribution'))),
        ),
        isFalse,
        reason: '提示条也不许盖住版权署名',
      );
    });

    testWidgets('抓得到就不该出现失败提示（DA85 反向）', (tester) async {
      await _pump(tester);
      expect(
        find.byKey(const Key('photo-map-tiles-unavailable')),
        findsNothing,
      );
    });

    testWidgets('点失败提示 ⇒ 重新抓，网络恢复后提示消失（DA85）', (tester) async {
      final fetcher = FakeTileFetcher(serve: false);
      await _pump(tester, fetcher: fetcher);
      expect(
        find.byKey(const Key('photo-map-tiles-unavailable')),
        findsOneWidget,
      );
      final before = fetcher.requested.length;

      // 网络恢复 + 用户点提示重试（不清瓦片缓存的话永远救不回来）
      fetcher.serve = true;
      await tester.tap(find.byKey(const Key('photo-map-tiles-unavailable')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(fetcher.requested.length, greaterThan(before), reason: '必须真重抓');
      expect(
        find.byKey(const Key('photo-map-tiles-unavailable')),
        findsNothing,
        reason: '抓到了就该收起提示（DA85）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('点 + / − 改缩放级别并重新抓新级别的瓦片', (tester) async {
      final fetcher = await _pump(tester);
      final before = fetcher.requested.length;
      await tester.tap(find.byKey(const Key('photo-map-zoom-in')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(fetcher.requested.length, greaterThan(before));
      expect(
        fetcher.requested.any((u) => u.path.startsWith('/15/')),
        isTrue,
        reason: '默认 z=14，放大一级 = z=15',
      );
      await tester.tap(find.byKey(const Key('photo-map-zoom-out')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(fetcher.requested.any((u) => u.path.startsWith('/14/')), isTrue);
    });

    testWidgets('拖动 ⇒ 视口移动（请求到新的瓦片 x/y）', (tester) async {
      final fetcher = await _pump(tester);
      final before = fetcher.requested.toSet();
      await tester.drag(
        find.byKey(const Key('photo-map-tiles')),
        const Offset(-300, 0),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final after = fetcher.requested.toSet();
      expect(after.difference(before), isNotEmpty, reason: '平移应带来新的瓦片');
    });
  });
}
