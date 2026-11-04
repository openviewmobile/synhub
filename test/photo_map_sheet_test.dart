// 相册「地点 → 在地图中打开」**弹层 / 接线**的离线用例（第一期 · 方案 A）。
//
// 全程离线：不连 NAS、不启动任何外部应用（`photoMapLauncherProvider` 换成假的）。
// 承重判据：
//   * 第一期手里**没有经纬度** → 弹层必须**如实**说"按地名搜索"（伪造点 ② 的界面侧）；
//   * 区域判定 → 国内高德 / 国外 Google；用户手选**压过**区域（且落盘）；
//   * 点"打开" → 交给注入的 launcher；scheme 打不开回落网页（伪造点 ③ 的界面侧）。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_c2_dto.dart';
import 'package:synhub/src/features/photos/photo_c2_providers.dart';
import 'package:synhub/src/features/photos/photo_c2_sections.dart';
import 'package:synhub/src/features/photos/photo_map_links.dart';
import 'package:synhub/src/features/photos/photo_map_prefs.dart';
import 'package:synhub/src/features/photos/photo_map_sheet.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/photos/photo_map_tiles.dart';

class _FakeLauncher {
  _FakeLauncher({this.fail = const {}});

  /// 这些 scheme 前缀会被判为"打不开"
  final Set<String> fail;
  final List<Uri> calls = [];

  Future<bool> call(Uri uri) async {
    calls.add(uri);
    for (final p in fail) {
      if (uri.toString().startsWith(p)) return false;
    }
    return true;
  }
}

/// 用例里的瓦片抓取器：**一个字节都不出网**（P21 应用内地图会请求瓦片）。
class _NoTileFetcher implements PhotoMapTileFetcher {
  @override
  Future<Uint8List?> fetch(Uri uri) async => null;
}

Future<ProviderContainer> _pumpSheet(
  WidgetTester tester, {
  required String name,
  double? latitude,
  double? longitude,
  String country = 'CN',
  Map<String, String> prefs = const {},
  required _FakeLauncher launcher,
}) async {
  final store = MemoryPhotoMapPrefsStore(prefs['service']);
  final c = ProviderContainer(
    overrides: [
      photoMapPrefsStoreProvider.overrideWithValue(store),
      photoMapLauncherProvider.overrideWithValue(launcher.call),
      photoMapRegionCountryCodeProvider.overrideWithValue(country),
      photoMapTileFetcherProvider.overrideWithValue(_NoTileFetcher()),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: PhotoMapSheet(
            name: name,
            latitude: latitude,
            longitude: longitude,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('① 第一期没有经纬度 → 弹层**如实**说是按地名搜索，不是精确位置', (tester) async {
    final launcher = _FakeLauncher();
    await _pumpSheet(tester, name: '杭州', launcher: launcher);

    final hint = tester.widget<Text>(find.byKey(const Key('photo-map-hint')));
    expect(hint.data, contains('地名'));
    expect(hint.data, contains('不保证'));

    // 打开 → 高德"按地名搜索"（CN 默认）
    // P21 起弹层顶部多了应用内地图 ⇒ 先滚到按钮可见再点
    await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    expect(launcher.calls.length, 1);
    final url = launcher.calls.single.toString();
    expect(url, startsWith('https://uri.amap.com/search?keyword='));
    expect(url, contains('%E6%9D%AD%E5%B7%9E'));
    // **不许**出现任何坐标（伪造点 ② 的界面侧）
    expect(url, isNot(contains('position=')));
    expect(url, isNot(contains('lat=')));
  });

  testWidgets('② 区域判定：CN → 高德；US → Google', (tester) async {
    final cn = _FakeLauncher();
    await _pumpSheet(tester, name: '杭州', country: 'CN', launcher: cn);
    // P21 起弹层顶部多了应用内地图 ⇒ 先滚到按钮可见再点
    await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    expect(cn.calls.single.toString(), contains('uri.amap.com'));

    final us = _FakeLauncher();
    await _pumpSheet(tester, name: '杭州', country: 'US', launcher: us);
    // P21 起弹层顶部多了应用内地图 ⇒ 先滚到按钮可见再点
    await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    expect(us.calls.single.toString(), startsWith('https://maps.google.com/'));
  });

  testWidgets('③ 用户手选**压过**区域判定，并且落盘', (tester) async {
    final launcher = _FakeLauncher();
    final store = MemoryPhotoMapPrefsStore();
    final c = ProviderContainer(
      overrides: [
        photoMapPrefsStoreProvider.overrideWithValue(store),
        photoMapLauncherProvider.overrideWithValue(launcher.call),
        photoMapRegionCountryCodeProvider.overrideWithValue('US'),
        photoMapTileFetcherProvider.overrideWithValue(_NoTileFetcher()),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(body: PhotoMapSheet(name: '杭州')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 区域判成 US（默认 Google），手动改成高德
    expect(c.read(resolvedPhotoMapServiceProvider), PhotoMapService.google);
    await tester.tap(find.byKey(const Key('photo-map-service-amap')));
    await tester.pumpAndSettle();
    expect(c.read(resolvedPhotoMapServiceProvider), PhotoMapService.amap);
    expect(await store.read(), 'amap');

    // P21 起弹层顶部多了应用内地图 ⇒ 先滚到按钮可见再点
    await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    expect(launcher.calls.single.toString(), contains('uri.amap.com'));
  });

  testWidgets('④ 落盘的用户选择在下次打开时被读回', (tester) async {
    final launcher = _FakeLauncher();
    final c = await _pumpSheet(
      tester,
      name: '杭州',
      country: 'CN',
      prefs: {'service': 'google'},
      launcher: launcher,
    );
    expect(c.read(resolvedPhotoMapServiceProvider), PhotoMapService.google);
    // P21 起弹层顶部多了应用内地图 ⇒ 先滚到按钮可见再点
    await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    expect(
      launcher.calls.single.toString(),
      startsWith('https://maps.google.com/'),
    );
  });

  testWidgets('⑤ 有坐标时如实显示坐标；腾讯 scheme 打不开 → 回落高德网页', (tester) async {
    final launcher = _FakeLauncher(fail: {'qqmap://'});
    final c = await _pumpSheet(
      tester,
      name: '杭州',
      latitude: 39.908722,
      longitude: 116.397499,
      prefs: {'service': 'tencent'},
      launcher: launcher,
    );
    final hint = tester.widget<Text>(find.byKey(const Key('photo-map-hint')));
    expect(hint.data, contains('坐标'));
    expect(hint.data, contains('WGS-84'));

    // P21 起弹层顶部多了应用内地图 ⇒ 先滚到按钮可见再点
    await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();

    // 先 App scheme（qqmap），失败后回落高德网页（GCJ-02）
    expect(launcher.calls.length, 2);
    expect(launcher.calls.first.toString(), startsWith('qqmap://map/marker'));
    expect(
      launcher.calls.last.toString(),
      startsWith('https://uri.amap.com/marker?'),
    );
    expect(launcher.calls.last.toString(), contains('coordinate=gaode'));
    expect(c.read(resolvedPhotoMapServiceProvider), PhotoMapService.tencent);
  });

  testWidgets('⑥ 地名也没有 → "打开"按钮禁用', (tester) async {
    final launcher = _FakeLauncher();
    await _pumpSheet(tester, name: '   ', launcher: launcher);
    final btn = tester.widget<FilledButton>(
      find.byKey(const Key('photo-map-open')),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('⑦ 接线：地点列表上的「在地图中打开」按钮能拉起弹层', (tester) async {
    final launcher = _FakeLauncher();
    final c = ProviderContainer(
      overrides: [
        photoMapPrefsStoreProvider.overrideWithValue(
          MemoryPhotoMapPrefsStore(),
        ),
        photoMapLauncherProvider.overrideWithValue(launcher.call),
        photoMapRegionCountryCodeProvider.overrideWithValue('CN'),
        photoMapTileFetcherProvider.overrideWithValue(_NoTileFetcher()),
        geocodingPlacesProvider.overrideWith(
          (ref) async => [
            const FotoGeocodingPlaceDto(id: '3', name: '杭州', itemCount: 5),
          ],
        ),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: AppTheme.dark(), home: PhotoGeocodingPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('photo-map-place-3')), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo-map-place-3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-map-sheet')), findsOneWidget);

    // P21 起弹层顶部多了应用内地图 ⇒ 先滚到按钮可见再点
    await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-map-open')));
    await tester.pumpAndSettle();
    expect(launcher.calls.single.toString(), contains('%E6%9D%AD%E5%B7%9E'));
  });
}
