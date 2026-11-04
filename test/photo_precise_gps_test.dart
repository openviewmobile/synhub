// 相册「精确位置 marker」离线用例（第二期）。
//
// 覆盖三件事，全部**离线**（`FakeTransport` + 夹具；不连 NAS、不启动外部应用）：
//   ① **请求侧**：产出照片条目的 `Browse.Item/list` 的 `additional` 带上 `gps`，
//      且**版本不变**（个人 v7 / Team 走 `SYNO.FotoTeam.Browse.Item`）；
//   ② **解析侧**：`additional.gps` → 可空坐标；**判"键存在性"而不是判数值**
//      （真实 (0,0) 必须解析成坐标，缺键才是 null）；
//   ③ **地图入口**：有坐标 → 精确徽标 + 坐标不落到界面上（默认不展示数字）；
//      无坐标 → 按地名搜索徽标；境外 Google + 精确坐标 → **一次性出境告知**，
//      拒了就不打开；境内服务不弹。
//
// 证据链见 `docs/photo-map-queries-and-coords.md` §5 与 `docs/photo-precise-gps.md`。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/photos/photo_map_prefs.dart';
import 'package:synhub/src/features/photos/photo_map_sheet.dart';
import 'package:synhub/src/features/photos/photo_map_tiles.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 能力表：够 `discover` + negotiate 到 v7。
///
/// 与 `FakeTransport.table` 合并（登录要 `SYNO.API.Encryption.getinfo` 等）。
const _gpsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.FotoTeam.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Browse.Geocoding': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.Browse.Person': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.Foto.Browse.Concept': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

final _table = {...FakeTransport.table, ..._gpsTable};

Future<FotoApi> _api(
  FakeTransport t, {
  FotoSpace space = FotoSpace.personal,
}) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FotoApi(api).inSpace(space);
}

Map<String, dynamic> _call(FakeTransport t, String apiName) =>
    t.calls.lastWhere((c) => c['api'] == apiName);

/// P21 应用内地图的瓦片抓取器：用例里**一个字节都不出网**。
class _NoTileFetcher implements PhotoMapTileFetcher {
  @override
  Future<Uint8List?> fetch(Uri uri) async => null;
}

void main() {
  group('请求侧：additional 带 gps（版本不变）', () {
    test('① timeline：v7 + additional = thumbnail/favorite/gps', () async {
      final t = FakeTransport({
        'SYNO.Foto.Browse.Item.list': {'list': <dynamic>[]},
      }, _table);
      final api = await _api(t);
      await api.timeline();
      final call = _call(t, 'SYNO.Foto.Browse.Item');
      expect('${call['version']}', '7');
      // 本用例的能力表把 rating（P40 评分）与 motion_photo（P13 实况照片）
      // 两个能力位都打开了，因此 `itemAdditional()` 会在这三个基础键之后
      // 按能力位追加这两个键。旧值 `["thumbnail","favorite","gps"]` 是这两个
      // 能力落地**之前**的事实；这里钉住的是**能力位全开时的完整列表**
      // （仍是严格等值断言，不是放宽匹配）。
      expect(
        call['additional'],
        '["thumbnail","favorite","gps","rating","motion_photo"]',
      );
    });

    test('② 相册 / 文件夹 / 收藏三条通路都带 gps', () async {
      for (final run in <Future<void> Function(FotoApi)>[
        (a) => a.albumItems('9'),
        (a) => a.folderItems('10'),
        (a) => a.favorites(),
      ]) {
        final t = FakeTransport({
          'SYNO.Foto.Browse.Item.list': {'list': <dynamic>[]},
        }, _table);
        final api = await _api(t);
        await run(api);
        final call = _call(t, 'SYNO.Foto.Browse.Item');
        expect('${call['version']}', '7');
        expect(call['additional'], contains('gps'));
        expect(call['additional'], contains('thumbnail'));
        expect(call['additional'], contains('favorite'));
      }
    });

    test('③ Team 空间走 SYNO.FotoTeam.Browse.Item，同样带 gps', () async {
      final t = FakeTransport({
        'SYNO.FotoTeam.Browse.Item.list': {'list': <dynamic>[]},
      }, _table);
      final api = await _api(t, space: FotoSpace.team);
      await api.timeline();
      final call = _call(t, 'SYNO.FotoTeam.Browse.Item');
      expect('${call['version']}', '7');
      expect(call['additional'], contains('gps'));
    });

    test('④ 人物 / 场景 / 地点三条过滤通路也带 gps', () async {
      for (final entry in <(String, Future<void> Function(FotoApi))>[
        ('person', (a) => a.personItems('3')),
        ('concept', (a) => a.conceptItems('4')),
        ('geocoding', (a) => a.geocodingItems('5')),
      ]) {
        final t = FakeTransport({
          'SYNO.Foto.Browse.Item.list': {'list': <dynamic>[]},
        }, _table);
        final api = await _api(t);
        await entry.$2(api);
        expect(
          _call(t, 'SYNO.Foto.Browse.Item')['additional'],
          // 同 ①：能力位全开时 `itemAdditional()` 会追加 rating(P40) 与
          // motion_photo(P13)。这三个键必须仍在，且列表整体严格等值。
          '["thumbnail","favorite","gps","rating","motion_photo"]',
          reason: '${entry.$1} 通路必须带 gps',
        );
      }
    });
  });

  group('解析侧：键存在性 vs (0,0)', () {
    test('① gps 键存在（含真实 0,0）→ 解析出坐标，不许当"没有"', () {
      final zero = FotoItemDto.fromJson({
        'id': 1,
        'additional': {
          'gps': {'latitude': 0.0, 'longitude': 0.0},
        },
      });
      expect(zero.gps, isNotNull);
      expect(zero.hasGps, isTrue);
      expect(zero.gps!.latitude, 0.0);
      expect(zero.gps!.longitude, 0.0);

      final real = FotoItemDto.fromJson({
        'id': 2,
        'additional': {
          'gps': {'latitude': 39.908722, 'longitude': 116.397499},
        },
      });
      expect(real.hasGps, isTrue);
      expect(real.gps!.latitude, 39.908722);
      expect(real.gps!.longitude, 116.397499);
    });

    test('② **缺 gps 键** → null（这才是"没有坐标"）', () {
      final dto = FotoItemDto.fromJson({
        'id': 1,
        'additional': {
          'thumbnail': {'sm': 'ready'},
        },
      });
      expect(dto.gps, isNull);
      expect(dto.hasGps, isFalse);
    });

    test('③ 没有 additional / gps 是字符串 → null，不抛', () {
      expect(FotoItemDto.fromJson({'id': 1}).hasGps, isFalse);
      expect(
        FotoItemDto.fromJson({
          'id': 1,
          'additional': {'gps': 'nope'},
        }).hasGps,
        isFalse,
      );
    });
  });

  group('地图入口：精确 / 地名两条路径', () {
    Future<ProviderContainer> pumpSheet(
      WidgetTester tester, {
      required String name,
      double? latitude,
      double? longitude,
      String country = 'CN',
      String? service,
      bool consent = false,
      required _FakeLauncher launcher,
    }) async {
      final store = MemoryPhotoMapPrefsStore(service, consent);
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

    String badgeText(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const Key('photo-map-badge')),
            matching: find.byType(Text),
          ),
        )
        .data!;

    testWidgets('① 有坐标 → "精确坐标"徽标；提示里**不出现坐标数字**', (tester) async {
      final launcher = _FakeLauncher();
      await pumpSheet(
        tester,
        name: 'IMG_1.jpg',
        latitude: 39.908722,
        longitude: 116.397499,
        service: 'amap',
        launcher: launcher,
      );
      expect(badgeText(tester), contains('精确'));
      final hint = tester.widget<Text>(find.byKey(const Key('photo-map-hint')));
      expect(hint.data, contains('WGS-84'));
      // 默认**不展示原始坐标数字**（合规）：提示文本里不许出现纬度/经度片段
      expect(hint.data, isNot(contains('39.9')));
      expect(hint.data, isNot(contains('116.')));
      // 精确路径：高德网页用官方 `coordinate=wgs84` 直传
      await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-map-open')));
      await tester.pumpAndSettle();
      final url = launcher.calls.single.toString();
      expect(url, contains('uri.amap.com/marker'));
      expect(url, contains('position=116.397499,39.908722'));
      expect(url, contains('coordinate=wgs84'));
    });

    testWidgets('② 无坐标 → "按地名搜索"徽标 + 不保证精确提示', (tester) async {
      final launcher = _FakeLauncher();
      await pumpSheet(tester, name: '杭州', service: 'amap', launcher: launcher);
      expect(badgeText(tester), contains('地名'));
      final hint = tester.widget<Text>(find.byKey(const Key('photo-map-hint')));
      expect(hint.data, contains('不保证'));
      expect(find.byKey(const Key('photo-map-copy-coord')), findsNothing);
    });

    testWidgets('③ "复制坐标"是唯一拿到数字的入口', (tester) async {
      final log = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          log.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final launcher = _FakeLauncher();
      await pumpSheet(
        tester,
        name: 'IMG_1.jpg',
        latitude: 39.908722,
        longitude: 116.397499,
        service: 'amap',
        launcher: launcher,
      );
      await tester.ensureVisible(find.byKey(const Key('photo-map-copy-coord')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-map-copy-coord')));
      await tester.pumpAndSettle();
      final copied = log
          .where((c) => c.method == 'Clipboard.setData')
          .map((c) => (c.arguments as Map)['text'])
          .toList();
      expect(copied, ['39.908722,116.397499']);
    });

    testWidgets('④ 境外 Google + 精确坐标 → 首次弹一次性告知；拒了不打开', (tester) async {
      final launcher = _FakeLauncher();
      final store = MemoryPhotoMapPrefsStore('google', false);
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
            home: Scaffold(
              body: PhotoMapSheet(
                name: 'IMG_1.jpg',
                latitude: 39.908722,
                longitude: 116.397499,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-map-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-map-consent-dialog')), findsOneWidget);
      expect(launcher.calls, isEmpty); // 没同意之前不许出境

      await tester.tap(find.byKey(const Key('photo-map-consent-refuse')));
      await tester.pumpAndSettle();
      expect(launcher.calls, isEmpty);
      expect(await store.readOverseasConsent(), isFalse);

      // 再来一次 → 同意 → 才真的打开
      await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-map-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-map-consent-agree')));
      await tester.pumpAndSettle();
      expect(
        launcher.calls.single.toString(),
        startsWith('https://maps.google.com/'),
      );
      expect(await store.readOverseasConsent(), isTrue);
    });

    testWidgets('⑤ 已同意过 → 不再弹告知，直接打开', (tester) async {
      final launcher = _FakeLauncher();
      await pumpSheet(
        tester,
        name: 'IMG_1.jpg',
        latitude: 39.908722,
        longitude: 116.397499,
        country: 'US',
        service: 'google',
        consent: true,
        launcher: launcher,
      );
      await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-map-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-map-consent-dialog')), findsNothing);
      expect(
        launcher.calls.single.toString(),
        startsWith('https://maps.google.com/'),
      );
    });

    testWidgets('⑥ 境内服务（高德 / 腾讯 / 百度）+ 精确坐标 → **不弹**出境告知', (tester) async {
      for (final id in ['amap', 'tencent', 'baidu']) {
        final launcher = _FakeLauncher();
        await pumpSheet(
          tester,
          name: 'IMG_1.jpg',
          latitude: 39.908722,
          longitude: 116.397499,
          service: id,
          launcher: launcher,
        );
        await tester.ensureVisible(find.byKey(const Key('photo-map-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-map-open')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('photo-map-consent-dialog')),
          findsNothing,
          reason: '$id 是境内服务，不做出境告知',
        );
        expect(launcher.calls, isNotEmpty);
      }
    });
  });
}

class _FakeLauncher {
  final List<Uri> calls = [];

  Future<bool> call(Uri uri) async {
    calls.add(uri);
    return true;
  }
}
