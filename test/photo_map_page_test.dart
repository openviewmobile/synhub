// P21：照片地图页的离线用例（自研瓦片底图 + 坐标聚合）。
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/region/device_location.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_map_page.dart';
import 'package:synhub/src/features/photos/photo_map_tiles.dart';
import 'package:synhub/src/features/calendar/calendar_env.dart'
    show deviceLocationProbeProvider;
import 'package:synhub/src/features/photos/photo_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 只认瓦片请求的假抓取器（一个字节都不出网）。
class _NoTileFetcher implements PhotoMapTileFetcher {
  final List<Uri> requested = [];

  @override
  Future<Uint8List?> fetch(Uri uri) async {
    requested.add(uri);
    return null;
  }
}

Map<String, dynamic> _photoJson(
  String id, {
  double? lat,
  double? lng,
  String? name,
}) => {
  'id': id,
  'filename': name ?? 'IMG_$id.jpg',
  'type': 'photo',
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'cache_key': 'ck_$id'},
    if (lat != null && lng != null) 'gps': {'latitude': lat, 'longitude': lng},
  },
};

FotoItemDto _photo(String id, {double? lat, double? lng, String? name}) =>
    FotoItemDto.fromJson(_photoJson(id, lat: lat, lng: lng, name: name));

Future<({FakeTransport t, ProviderContainer c})> _boot({
  required List<Map<String, dynamic>> items,
  Map<String, int> failures = const {},
  DeviceLocationProbe? probe,
}) async {
  final t = FakeTransport(const {}, {
    ...FakeTransport.table,
    ..._photoTable,
  });
  t.failures.addAll(failures);
  t.onCall = (params) => params['method'] == 'list' ? {'list': items} : null;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final fetcher = _NoTileFetcher();
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      photoMapTileFetcherProvider.overrideWithValue(fetcher),
      if (probe != null) deviceLocationProbeProvider.overrideWithValue(probe),
    ],
  );
  return (t: t, c: c);
}

Future<void> _pump(WidgetTester tester, ProviderContainer c) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: PhotoMapPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 相册接口的能力表（缺了它就协商不了 `Browse.Item`）。
const _photoTable = <String, Map<String, dynamic>>{
  'SYNO.Foto.Browse.Item': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 9},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
};

/// 假定位探针：不碰设备、不弹权限框。
class _FakeLocationProbe implements DeviceLocationProbe {
  _FakeLocationProbe({
    this.permission = LocationPermission.granted,
    this.location,
  });

  final LocationPermission permission;
  final DeviceLocation? location;
  int currentCalls = 0;

  @override
  Future<LocationPermission> ensurePermission({bool interactive = true}) async =>
      permission;

  @override
  Future<bool> serviceEnabled() async => true;

  @override
  Future<DeviceLocation?> current() async {
    currentCalls++;
    return location;
  }

  @override
  Future<void> clearCache() async {}
}

void main() {
  group('P21 聚合（纯函数）', () {
    test('同格子的照片合成一簇；无坐标的丢掉', () {
      final items = [
        _photo('1', lat: 31.2304, lng: 121.4737),
        _photo('2', lat: 31.2305, lng: 121.4738),
        _photo('3', lat: 39.9042, lng: 116.4074),
        _photo('4'),
      ];
      final clusters = clusterGeotaggedItems(items);
      expect(clusters, hasLength(2));
      expect(clusters.first.items.map((e) => e.id), ['1', '2']);
      expect(clusters.first.isSingle, isFalse);
      expect(clusters[1].isSingle, isTrue);
      expect(clusters[1].items.single.id, '3');
    });

    test('缩放级越小格子越大 ⇒ 更狠地聚合', () {
      final items = [
        _photo('1', lat: 31.2304, lng: 121.4737),
        _photo('2', lat: 31.9, lng: 121.9),
      ];
      // 0.7° 左右：z4 同格、z12 起分家（格子随缩放变小）
      expect(clusterGeotaggedItems(items, zoom: 4), hasLength(1));
      expect(clusterGeotaggedItems(items, zoom: 12), hasLength(2));
      expect(clusterGeotaggedItems(items, zoom: 16), hasLength(2));
    });

    test('簇键就是格子编号（z/x/y，顺序稳定）', () {
      final c = clusterGeotaggedItems([
        _photo('1', lat: 0, lng: 0),
      ], zoom: 1).single;
      expect(c.key, '1/1/1');
    });
  });

  group('P21 照片地图页（UI）', () {
    testWidgets('请求里带 gps；只给有坐标的照片打点', (tester) async {
      final boot = await _boot(
        items: [
          _photoJson('1', lat: 31.2304, lng: 121.4737),
          _photoJson('2'),
          _photoJson('3', lat: 39.9042, lng: 116.4074),
        ],
      );
      addTearDown(boot.c.dispose);
      await _pump(tester, boot.c);
      final call = boot.t.calls.lastWhere((c) => c['method'] == 'list');
      expect(call['api'], 'SYNO.Foto.Browse.Item');
      expect(call['additional'], contains('gps'));
      expect(find.byKey(const Key('photo-map-photos')), findsOneWidget);
      // 两条有坐标 + 一条没坐标 ⇒ 列表恰好两行
      expect(find.byKey(const Key('photo-map-cluster-list')), findsOneWidget);
      expect(find.text('IMG_2.jpg'), findsNothing, reason: '没坐标的不进地图');
    });

    testWidgets('同一带的照片合成一行（"这一带 N 张"），点开是清单', (tester) async {
      final boot = await _boot(
        items: [
          _photoJson('1', lat: 31.2304, lng: 121.4737),
          _photoJson('2', lat: 31.2305, lng: 121.4738),
        ],
      );
      addTearDown(boot.c.dispose);
      await _pump(tester, boot.c);
      expect(find.text('这一带 2 张'), findsOneWidget);
      final cluster = clusterGeotaggedItems([
        _photo('1', lat: 31.2304, lng: 121.4737),
        _photo('2', lat: 31.2305, lng: 121.4738),
      ]).single;
      await tester.tap(find.byKey(Key('photo-map-cluster-${cluster.key}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('photo-map-cluster-sheet')), findsOneWidget);
      expect(find.byKey(const Key('photo-map-cluster-item-2')), findsOneWidget);
    });

    testWidgets('一张坐标都没有 ⇒ 明确空态，不画假地图', (tester) async {
      final boot = await _boot(items: [_photoJson('1'), _photoJson('2')]);
      addTearDown(boot.c.dispose);
      await _pump(tester, boot.c);
      expect(find.byKey(const Key('photo-map-empty')), findsOneWidget);
      expect(find.byKey(const Key('photo-map-photos')), findsNothing);
    });

    // ★ r440（`DA94`）：判据从"默认域名 = OSM"改成"**默认源有数据且可直连**"。
    // 三层 host 互不相同（`tile.openstreetmap.de` / `server.arcgisonline.com`
    // / `tile.openstreetmap.org`）⇒ 用 host 就能唯一认出当前图层。
    testWidgets('默认源 = Esri 街道图（不再打不可直连的 OSM）；图层按钮逐层切换', (tester) async {
      final boot = await _boot(
        items: [_photoJson('1', lat: 31.2304, lng: 121.4737)],
      );
      addTearDown(boot.c.dispose);
      await _pump(tester, boot.c);
      final fetcher = boot.c.read(photoMapTileFetcherProvider) as _NoTileFetcher;
      expect(
        fetcher.requested.any((u) => u.host == 'tile.openstreetmap.de'),
        isTrue,
        reason: '默认层应是可直连、且 z14 有真数据的 OSM 镜像',
      );
      expect(
        fetcher.requested.any((u) => u.host == 'tile.openstreetmap.org'),
        isFalse,
        reason: 'r440：直连不可达的源不许出现在默认路径上',
      );
      // 第一次点：街道镜像 → Esri 影像
      await tester.tap(find.byKey(const Key('photo-map-layer-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        fetcher.requested.any((u) => u.host == 'server.arcgisonline.com'),
        isTrue,
        reason: '切图层后要真的去抓影像瓦片',
      );
      expect(find.byKey(const Key('photo-map-photos')), findsOneWidget);
      // 第二次点：影像 → OSM 官方站（它仍是**可切**的一层，只是不再默认）
      await tester.tap(find.byKey(const Key('photo-map-layer-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        fetcher.requested.any((u) => u.host == 'tile.openstreetmap.org'),
        isTrue,
        reason: 'OSM 官方站保留在图层清单里',
      );
    });

    testWidgets('我的位置：授权 + 定位成功 ⇒ 出现"我的位置"标记并居中过去', (tester) async {
      final probe = _FakeLocationProbe(
        location: DeviceLocation(
          latitude: 22.5431,
          longitude: 114.0579,
          accuracyM: 20,
          timeMs: 1758600000000,
        ),
      );
      final boot = await _boot(
        items: [_photoJson('1', lat: 31.2304, lng: 121.4737)],
        probe: probe,
      );
      addTearDown(boot.c.dispose);
      await _pump(tester, boot.c);
      expect(find.byKey(const Key('photo-map-marker-me')), findsNothing);
      await tester.tap(find.byKey(const Key('photo-map-my-location')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(probe.currentCalls, 1);
      expect(find.byKey(const Key('photo-map-marker-me')), findsOneWidget);
    });

    testWidgets('我的位置：没有权限 ⇒ 明确提示、不定位、不加标记', (tester) async {
      final probe = _FakeLocationProbe(permission: LocationPermission.denied);
      final boot = await _boot(
        items: [_photoJson('1', lat: 31.2304, lng: 121.4737)],
        probe: probe,
      );
      addTearDown(boot.c.dispose);
      await _pump(tester, boot.c);
      await tester.tap(find.byKey(const Key('photo-map-my-location')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(probe.currentCalls, 0, reason: '没权限就别去定位');
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byKey(const Key('photo-map-marker-me')), findsNothing);
    });

    testWidgets('我的位置：本机不支持 ⇒ 明确提示、不去定位', (tester) async {
      final unsupported = _FakeLocationProbe(
        permission: LocationPermission.unsupported,
      );
      final boot = await _boot(
        items: [_photoJson('1', lat: 31.2304, lng: 121.4737)],
        probe: unsupported,
      );
      addTearDown(boot.c.dispose);
      await _pump(tester, boot.c);
      await tester.tap(find.byKey(const Key('photo-map-my-location')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(unsupported.currentCalls, 0);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('我的位置：有权限但定不到位 ⇒ 不编坐标、不加标记', (tester) async {
      final nothing = _FakeLocationProbe();
      final boot = await _boot(
        items: [_photoJson('1', lat: 31.2304, lng: 121.4737)],
        probe: nothing,
      );
      addTearDown(boot.c.dispose);
      await _pump(tester, boot.c);
      await tester.tap(find.byKey(const Key('photo-map-my-location')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(nothing.currentCalls, 1);
      expect(find.byKey(const Key('photo-map-marker-me')), findsNothing);
    });

    testWidgets('接口失败 ⇒ 错误态 + 可重试', (tester) async {
      final boot = await _boot(
        items: [_photoJson('1', lat: 31.2, lng: 121.4)],
        failures: {'SYNO.Foto.Browse.Item.list': 105},
      );
      addTearDown(boot.c.dispose);
      await _pump(tester, boot.c);
      expect(find.byKey(const Key('photo-map-error')), findsOneWidget);
      expect(find.byKey(const Key('photo-map-retry')), findsOneWidget);
    });
  });
}
