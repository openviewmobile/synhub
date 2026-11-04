// 相册「地点 → 在地图中打开」**纯函数层**的离线用例（第一期 · 方案 A）。
//
// 全程离线：不连 NAS、不发网络请求、不启动任何外部应用。
// 覆盖（也是 falsification 的承重点，见每条注释）：
//   * 区域判定（国内 / 国外 / locale 缺失看时区 / locale 覆盖时区）；
//   * WGS-84 **直传**（Google、高德网页）vs GCJ-02 **本地换算**（高德 scheme、腾讯、百度）；
//   * **坐标缺失时只按地名搜索**，URL 里**不得**出现经纬度（伪造点 ②）；
//   * 「首选 scheme 失败 → 回落网页」（伪造点 ③）；
//   * 「`<queries>` 声明后 scheme 可用 → 不回落」的可用性门控（伪造点 ④）。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/photos/photo_map_links.dart';

/// 天安门 WGS-84（公开参考点）
const double _lat = 39.908722;
const double _lng = 116.397499;

/// 本仓库 `wgs84ToGcj02`（`lib/src/data/region/china_gps.dart`）对该点的输出。
///
/// 硬编码是**故意的**：把换算结果钉住，将来有人动了 `china_gps.dart` 或
/// 在本文件里"顺手"把 WGS-84 当 GCJ-02 用，这条会立刻红。
/// 另有一条**非循环**断言：偏移量必须落在几百米量级（见下面 `_meters`）。
const String _gcjLat = '39.910126';
const String _gcjLng = '116.403743';

/// 两点间粗略距离（米）——只用来做"偏移量级"断言，不需要高精度。
double _meters(double lat1, double lng1, double lat2, double lng2) {
  const deg = 111320.0;
  final dx = (lng2 - lng1) * deg * 0.766; // cos(40°) ≈ 0.766
  final dy = (lat2 - lat1) * deg;
  return math.sqrt(dx * dx + dy * dy);
}

void main() {
  group('区域判定（默认服务）', () {
    test('① 中国大陆 → 高德', () {
      expect(defaultPhotoMapService(countryCode: 'CN'), PhotoMapService.amap);
      expect(defaultPhotoMapService(countryCode: 'cn'), PhotoMapService.amap);
    });

    test('② 境外 → Google', () {
      expect(defaultPhotoMapService(countryCode: 'US'), PhotoMapService.google);
      expect(defaultPhotoMapService(countryCode: 'JP'), PhotoMapService.google);
      // 港澳台 Google 可用 → 默认 Google（可被用户覆盖；见评估文档 §4）
      expect(defaultPhotoMapService(countryCode: 'HK'), PhotoMapService.google);
    });

    test('③ locale 缺失 → 时区兜底（Asia/Shanghai → CN → 高德）', () {
      expect(
        defaultPhotoMapService(countryCode: '', timezone: 'Asia/Shanghai'),
        PhotoMapService.amap,
      );
      expect(
        defaultPhotoMapService(countryCode: '', timezone: 'America/New_York'),
        PhotoMapService.google,
      );
    });

    test('④ 显式国家码**压过**时区', () {
      // 人在美国、时区还是上海（没改时区）→ 以显式国家码为准
      expect(
        mapRegionCountryCode(countryCode: 'US', timezone: 'Asia/Shanghai'),
        'US',
      );
      expect(
        defaultPhotoMapService(countryCode: 'US', timezone: 'Asia/Shanghai'),
        PhotoMapService.google,
      );
    });

    test('⑤ 什么都没有 → 无法判定 → Google（保守默认，不硬猜成国内）', () {
      expect(mapRegionCountryCode(), '');
      expect(defaultPhotoMapService(), PhotoMapService.google);
    });
  });

  group('URL 构造 · 有坐标', () {
    test('① Google：WGS-84 **直传**，不做任何换算', () {
      final link = buildPhotoMapLink(
        service: PhotoMapService.google,
        target: const PhotoMapTarget(
          name: '杭州',
          latitude: _lat,
          longitude: _lng,
        ),
      );
      expect(link.precise, isTrue);
      expect(link.kind, PhotoMapUriKind.web);
      expect(
        link.uri.toString(),
        'https://maps.google.com/?q=39.908722,116.397499',
      );
      expect(link.hasFallback, isFalse);
    });

    test('② 高德**网页**：官方 `coordinate=wgs84` → WGS-84 直传', () {
      final link = buildPhotoMapLink(
        service: PhotoMapService.amap,
        target: const PhotoMapTarget(
          name: '杭州',
          latitude: _lat,
          longitude: _lng,
        ),
        preferApp: false,
      );
      expect(
        link.uri.toString(),
        'https://uri.amap.com/marker?position=116.397499,39.908722'
        '&name=%E6%9D%AD%E5%B7%9E&coordinate=wgs84&src=synhub'
        '&callnative=0',
      );
      expect(link.kind, PhotoMapUriKind.web);
    });

    test('③ 高德调起 App 走官方 `callnative=1`，**不**拼 `androidamap://viewMap`', () {
      // 理由：Dart 的 `Uri` 会把 `viewMap` 归一成 `viewmap`，自己拼也绕不过
      // （url_launcher 收 Uri）→ 走高德官方的"网页尝试调起 App"开关。
      final link = buildPhotoMapLink(
        service: PhotoMapService.amap,
        target: const PhotoMapTarget(
          name: '杭州',
          latitude: _lat,
          longitude: _lng,
        ),
      );
      expect(link.kind, PhotoMapUriKind.web);
      expect(link.uri.toString(), contains('callnative=1'));
      expect(link.uri.toString(), isNot(contains('androidamap')));
      expect(link.uri.toString(), contains('coordinate=wgs84'));
      expect(link.hasFallback, isFalse);
    });

    test('④ 腾讯：scheme 吃 GCJ-02；网页版无 key → 回落高德网页（也用 GCJ-02）', () {
      final link = buildPhotoMapLink(
        service: PhotoMapService.tencent,
        target: const PhotoMapTarget(
          name: '杭州',
          latitude: _lat,
          longitude: _lng,
        ),
      );
      expect(
        link.uri.toString(),
        'qqmap://map/marker?marker=coord:$_gcjLat,$_gcjLng'
        ';title:%E6%9D%AD%E5%B7%9E;addr:%E6%9D%AD%E5%B7%9E'
        '&referer=synhub',
      );
      expect(link.fallbackService, PhotoMapService.amap);
      // 回落到高德网页时**必须**用换算后的 GCJ-02（`coordinate=gaode`），
      // 否则会把 WGS-84 当 GCJ-02 用 → 偏几百米。
      expect(
        link.fallbackUri!.toString(),
        contains('position=$_gcjLng,$_gcjLat'),
      );
      expect(link.fallbackUri!.toString(), contains('coordinate=gaode'));
    });

    test('⑤ 百度：scheme 吃 GCJ-02（coord_type=gcj02）', () {
      final link = buildPhotoMapLink(
        service: PhotoMapService.baidu,
        target: const PhotoMapTarget(
          name: '杭州',
          latitude: _lat,
          longitude: _lng,
        ),
      );
      expect(
        link.uri.toString(),
        'baidumap://map/marker?location=$_gcjLat,$_gcjLng'
        '&title=%E6%9D%AD%E5%B7%9E&content=%E6%9D%AD%E5%B7%9E'
        '&coord_type=gcj02&src=synhub',
      );
      expect(link.fallbackService, PhotoMapService.amap);
    });

    test('⑥ 境外坐标不换算（不在中国 bbox 内 → 原样）', () {
      // 旧金山：lng 远小于 72.004 → isOutOfChina = true
      final link = buildPhotoMapLink(
        service: PhotoMapService.amap,
        target: const PhotoMapTarget(
          name: 'SF',
          latitude: 37.7749,
          longitude: -122.4194,
        ),
      );
      expect(link.uri.toString(), contains('position=-122.4194,37.7749'));
      expect(link.uri.toString(), contains('coordinate=wgs84'));
    });

    test('⑦ 非循环断言：GCJ-02 偏移是「几百米」量级', () {
      // 把换算结果钉住（硬编码），并断言偏移量级合理——不是 0（没换算），
      // 也不是公里级（换算写错）。
      final link = buildPhotoMapLink(
        service: PhotoMapService.tencent,
        target: const PhotoMapTarget(
          name: '杭州',
          latitude: _lat,
          longitude: _lng,
        ),
      );
      expect(link.uri.toString(), contains('coord:$_gcjLat,$_gcjLng'));
      final meters = _meters(
        _lat,
        _lng,
        double.parse(_gcjLat),
        double.parse(_gcjLng),
      );
      expect(meters, greaterThan(100));
      expect(meters, lessThan(1000));
    });
  });

  group('URL 构造 · 无坐标（第一期的常态）', () {
    test('① 高德：只能是「按地名搜索」，precise=false', () {
      final link = buildPhotoMapLink(
        service: PhotoMapService.amap,
        target: const PhotoMapTarget(name: '杭州'),
      );
      expect(link.precise, isFalse);
      expect(
        link.uri.toString(),
        'https://uri.amap.com/search?keyword=%E6%9D%AD%E5%B7%9E'
        '&src=synhub&callnative=1',
      );
    });

    test('② **绝不**在缺坐标时假装精确定位（伪造点 ②）', () {
      for (final s in [
        PhotoMapService.google,
        PhotoMapService.amap,
        PhotoMapService.tencent,
        PhotoMapService.baidu,
      ]) {
        final link = buildPhotoMapLink(
          service: s,
          target: const PhotoMapTarget(name: '杭州'),
        );
        final url = link.uri.toString();
        expect(link.precise, isFalse, reason: '$s 缺坐标必须 precise=false');
        expect(url, isNot(contains('39.')));
        expect(url, isNot(contains('116.')));
        expect(url, isNot(contains('lat=')));
        expect(url, isNot(contains('lon=')));
        expect(url, isNot(contains('location=')));
        expect(url, isNot(contains('position=')));
        expect(url, isNot(contains('coord')));
        // 地名必须被带上（按地名搜索）
        expect(url, contains('%E6%9D%AD%E5%B7%9E'), reason: '$s 必须带地名');
      }
    });

    test('③ 腾讯 / 百度缺坐标 → 高德搜索页，且标注了回落服务', () {
      for (final s in [PhotoMapService.tencent, PhotoMapService.baidu]) {
        final link = buildPhotoMapLink(
          service: s,
          target: const PhotoMapTarget(name: '杭州'),
        );
        expect(link.kind, PhotoMapUriKind.web);
        expect(link.fallbackService, PhotoMapService.amap);
        expect(link.uri.toString(), contains('uri.amap.com/search'));
      }
    });

    test('④ 地名也没有 → 目标不可用（UI 会禁用"打开"）', () {
      const t = PhotoMapTarget();
      expect(t.isUsable, isFalse);
      expect(t.hasName, isFalse);
      expect(t.hasCoordinates, isFalse);
      final link = buildPhotoMapLink(
        service: PhotoMapService.google,
        target: t,
      );
      expect(link.uri.toString(), 'https://maps.google.com/?q=');
    });
  });

  group('打开 + 回落（伪造点 ③）', () {
    // 用腾讯：它的首选是 **App scheme**（`qqmap://`，authority 小写、能穿过 Dart
    // 的 host 归一化），网页回落是**高德网页** → 正好能测"先 App 后网页"。
    final link = buildPhotoMapLink(
      service: PhotoMapService.tencent,
      target: const PhotoMapTarget(name: '杭州', latitude: _lat, longitude: _lng),
    );

    test('① 首选 scheme 成功 → 不回落', () async {
      final tried = <Uri>[];
      final r = await openPhotoMapLink(
        link,
        launcher: (u) async {
          tried.add(u);
          return true;
        },
      );
      expect(r.ok, isTrue);
      expect(r.usedFallback, isFalse);
      expect(tried.length, 1);
      expect(tried.single, link.uri);
    });

    test('② 首选 scheme 返回 false → 回落网页', () async {
      final tried = <Uri>[];
      final r = await openPhotoMapLink(
        link,
        launcher: (u) async {
          tried.add(u);
          return !u.toString().startsWith('qqmap://');
        },
      );
      expect(r.ok, isTrue);
      expect(r.usedFallback, isTrue);
      expect(tried.length, 2);
      expect(tried.last, link.fallbackUri);
    });

    test('③ 首选**抛异常**（没装 App / 包可见性挡住）→ 也必须回落', () async {
      final tried = <Uri>[];
      final r = await openPhotoMapLink(
        link,
        launcher: (u) async {
          tried.add(u);
          if (u.toString().startsWith('qqmap://')) {
            throw StateError('no activity found');
          }
          return true;
        },
      );
      expect(r.ok, isTrue);
      expect(r.usedFallback, isTrue);
      expect(tried.last, link.fallbackUri);
    });

    test('④ 两条都不行 → ok=false（UI 提示失败，不崩）', () async {
      final r = await openPhotoMapLink(link, launcher: (_) async => false);
      expect(r.ok, isFalse);
      expect(r.tried.length, 2);
    });

    test('⑤ 没有 fallback 的链接（Google）→ 只试一次', () async {
      final g = buildPhotoMapLink(
        service: PhotoMapService.google,
        target: const PhotoMapTarget(
          name: '杭州',
          latitude: _lat,
          longitude: _lng,
        ),
      );
      final tried = <Uri>[];
      final r = await openPhotoMapLink(
        g,
        launcher: (u) async {
          tried.add(u);
          return false;
        },
      );
      expect(r.ok, isFalse);
      expect(tried.length, 1);
    });
  });

  // `AndroidManifest.xml` 的 `<queries>` 声明了地图 scheme/package 之后，
  // "系统里能用"的判定（生产侧 `canLaunchUrl`）就会给 `true`。这一组把
  // **门控语义**钉住（伪造点 ④，见 falsification 记录）：
  //   * `canLaunch` 回 `true` + 启动成功 → **绝不回落**（声明 `<queries>` 的目的）；
  //   * `canLaunch` 回 `false` → 连试都不试，直接网页回落；
  //   * `canLaunch` 抛异常 → 当作不可用，仍回落，不崩；
  //   * `canLaunch` 回 `true` 但启动失败 → **降级路径保留**，仍回落。
  // 全部用假实现，**不真调系统**。
  group('scheme 可用性门控（`<queries>` 落地后的断言 · 伪造点 ④）', () {
    final link = buildPhotoMapLink(
      service: PhotoMapService.tencent,
      target: const PhotoMapTarget(name: '杭州', latitude: _lat, longitude: _lng),
    );

    test('① scheme 可用（canLaunch=true）→ 启动成功且**不回落**', () async {
      expect(link.kind, PhotoMapUriKind.app); // 首选确实是 `qqmap://`
      final asked = <Uri>[];
      final tried = <Uri>[];
      final r = await openPhotoMapLink(
        link,
        canLaunch: (u) async {
          asked.add(u);
          return true;
        },
        launcher: (u) async {
          tried.add(u);
          return true;
        },
      );
      expect(r.ok, isTrue);
      expect(r.usedFallback, isFalse);
      expect(asked.single, link.uri); // 只问了首选
      expect(tried.single, link.uri); // 只启动了首选，**没有**碰 fallback
      expect(tried, isNot(contains(link.fallbackUri)));
    });

    test('② scheme 不可用（canLaunch=false）→ 不试首选，直接网页回落', () async {
      final tried = <Uri>[];
      final r = await openPhotoMapLink(
        link,
        canLaunch: (_) async => false,
        launcher: (u) async {
          tried.add(u);
          return true;
        },
      );
      expect(r.ok, isTrue);
      expect(r.usedFallback, isTrue); // "用了回落"必须如实标记
      expect(tried, [link.fallbackUri!]); // 首选 scheme 一次都没试
    });

    test('③ canLaunch 抛异常 → 当作不可用，仍回落且不崩', () async {
      final tried = <Uri>[];
      final r = await openPhotoMapLink(
        link,
        canLaunch: (_) async => throw StateError('plugin missing'),
        launcher: (u) async {
          tried.add(u);
          return true;
        },
      );
      expect(r.ok, isTrue);
      expect(tried, [link.fallbackUri!]);
    });

    test('④ scheme 可用但启动失败 → 降级路径**保留**，仍回落', () async {
      final tried = <Uri>[];
      final r = await openPhotoMapLink(
        link,
        canLaunch: (_) async => true,
        launcher: (u) async {
          tried.add(u);
          return !u.toString().startsWith('qqmap://');
        },
      );
      expect(r.ok, isTrue);
      expect(r.usedFallback, isTrue);
      expect(tried.length, 2);
      expect(tried.first, link.uri);
      expect(tried.last, link.fallbackUri);
    });

    test('⑤ canLaunch=null → 与第一期逐字一致（不看可用性）', () async {
      final tried = <Uri>[];
      final r = await openPhotoMapLink(
        link,
        launcher: (u) async {
          tried.add(u);
          return true;
        },
      );
      expect(r.ok, isTrue);
      expect(r.usedFallback, isFalse);
      expect(tried.single, link.uri);
    });

    test('⑥ 首选是 https（高德/Google）→ 不查 canLaunch', () async {
      final amap = buildPhotoMapLink(
        service: PhotoMapService.amap,
        target: const PhotoMapTarget(
          name: '杭州',
          latitude: _lat,
          longitude: _lng,
        ),
      );
      expect(amap.kind, PhotoMapUriKind.web);
      var asked = 0;
      final tried = <Uri>[];
      final r = await openPhotoMapLink(
        amap,
        canLaunch: (_) async {
          asked++;
          return false;
        },
        launcher: (u) async {
          tried.add(u);
          return true;
        },
      );
      expect(r.ok, isTrue);
      expect(asked, 0); // https 路径不经过 scheme 门控
      expect(tried.single, amap.uri);
    });
  });

  test('坐标格式化：去掉末尾多余的 0', () {
    expect(photoMapCoord(39.9), '39.9');
    expect(photoMapCoord(116.397499), '116.397499');
    expect(photoMapCoord(-122.4194), '-122.4194');
    expect(photoMapCoord(0), '0');
  });
}
