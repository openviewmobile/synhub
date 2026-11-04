// 反查/正查地点：把"日程上的地点"变成 [RegionContext]。
//
// 两个都选**免 key**的服务（用户不该为了看天气去申请凭据）：
//   * **正查**（地名 → 国家/坐标）：Open-Meteo 的 geocoding
//     `https://geocoding-api.open-meteo.com/v1/search?name=北京&count=5&language=zh`
//     —— 同一家还提供天气，少一个域名要维护。
//   * **反查**（坐标 → 国家/城市）：BigDataCloud 的 client 版
//     `https://api.bigdatacloud.net/data/reverse-geocode-client?...`
//     —— 免 key、支持 `localityLanguage=zh`。
//
// 都失败就返回空，**不让上层瞎猜**（UI 会显示"地区未确定"并允许手动指定）。
import 'dart:convert';

import 'package:dio/dio.dart';
import '../../core/net/traffic_meter.dart';

import 'region_context.dart';

/// 一个候选地点（正查结果）
class GeoSuggestion {
  const GeoSuggestion({
    required this.name,
    required this.countryCode,
    this.admin1 = '',
    this.timezone = '',
    this.latitude,
    this.longitude,
  });

  final String name;
  final String countryCode;
  final String admin1;
  final String timezone;
  final double? latitude;
  final double? longitude;

  String get label {
    final parts = [
      name,
      if (admin1.isNotEmpty) admin1,
      if (countryCode.isNotEmpty) countryName(countryCode),
    ];
    return parts.join(' · ');
  }

  RegionContext toRegion() => RegionContext(
    countryCode: countryCode,
    subdivisionCode: admin1,
    city: name,
    timezone: timezone,
    latitude: latitude,
    longitude: longitude,
    source: RegionSource.eventAddress,
  );
}

class GeocodeClient {
  GeocodeClient({
    Dio? dio,
    this.geocodingBase = kGeocodingBase,
    this.reverseBase = kReverseBase,
    this.nominatimBase = kNominatimBase,
  }) : _dio = tagDioWithModule(
         dio ??
             Dio(
               BaseOptions(
                 connectTimeout: const Duration(seconds: 8),
                 receiveTimeout: const Duration(seconds: 12),
                 validateStatus: (_) => true,
               ),
             ),
         TrafficModules.calendar,
       );

  final Dio _dio;

  /// base URL 覆盖（测试用本机桩）
  final String geocodingBase;
  final String reverseBase;
  final String nominatimBase;

  static const String kGeocodingBase = 'https://geocoding-api.open-meteo.com';
  static const String kReverseBase = 'https://api.bigdatacloud.net';
  static const String kNominatimBase = 'https://nominatim.openstreetmap.org';

  /// 地名 → 候选列表（中文优先，失败退英文；再失败返回空）
  Future<List<GeoSuggestion>> search(String query, {int count = 5}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    // Open-Meteo 的地理编码**只按拉丁字母匹配**（实测 `name=北京` 回空，
    // `name=Beijing` 有结果；`language` 只影响返回字段的语言）→ 所以中文/日文
    // 这类非拉丁地名要靠 Nominatim（OSM，免 key、要求 UA）兜底。
    for (final lang in const ['zh', 'en']) {
      final list = await _searchOnce(q, lang, count);
      if (list.isNotEmpty) return list;
    }
    return _searchNominatim(q, count);
  }

  /// OpenStreetMap Nominatim：`q=北京&format=jsonv2&accept-language=zh`
  ///
  /// 它要求可识别 UA 且**每秒最多 1 次**（我们只在"填地点"时手动触发，够用），
  /// 所以放在最后兜底，不参与批量查询。
  Future<List<GeoSuggestion>> _searchNominatim(String q, int count) async {
    try {
      final res = await _dio.get<dynamic>(
        '$nominatimBase/search',
        queryParameters: {
          'q': q,
          'format': 'jsonv2',
          'limit': count,
          'accept-language': 'zh-CN,zh',
          'addressdetails': 1,
        },
        options: Options(
          responseType: ResponseType.plain,
          headers: const {'User-Agent': 'SynHub/0.1 (Synology client station)'},
        ),
      );
      if (res.statusCode != 200) return const [];
      final raw = res.data;
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! List) return const [];
      final out = <GeoSuggestion>[];
      for (final one in decoded) {
        if (one is! Map) continue;
        final address = one['address'];
        final addr = address is Map ? address : const {};
        final country = '${addr['country_code'] ?? ''}'.toUpperCase();
        if (country.isEmpty) continue;
        final name = '${one['name'] ?? ''}'.isNotEmpty
            ? '${one['name']}'
            : '${one['display_name'] ?? ''}'.split(',').first;
        out.add(
          GeoSuggestion(
            name: name,
            countryCode: country,
            admin1: '${addr['state'] ?? addr['province'] ?? ''}',
            latitude: double.tryParse('${one['lat'] ?? ''}'),
            longitude: double.tryParse('${one['lon'] ?? ''}'),
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<GeoSuggestion>> _searchOnce(
    String q,
    String language,
    int count,
  ) async {
    try {
      final res = await _dio.get<dynamic>(
        '$geocodingBase/v1/search',
        queryParameters: {
          'name': q,
          'count': count,
          'language': language,
          'format': 'json',
        },
        options: Options(responseType: ResponseType.plain),
      );
      if (res.statusCode != 200) return const [];
      final raw = res.data;
      final map = raw is String ? jsonDecode(raw) : raw;
      if (map is! Map) return const [];
      final results = map['results'];
      if (results is! List) return const [];
      return [
        for (final one in results)
          if (one is Map)
            GeoSuggestion(
              name: '${one['name'] ?? ''}',
              countryCode: '${one['country_code'] ?? ''}'.toUpperCase(),
              admin1: '${one['admin1'] ?? ''}',
              timezone: '${one['timezone'] ?? ''}',
              latitude: (one['latitude'] as num?)?.toDouble(),
              longitude: (one['longitude'] as num?)?.toDouble(),
            ),
      ];
    } catch (_) {
      // 网络问题不该让"填地点"这个动作崩掉：当作没有结果，UI 让用户手选国家
      return const [];
    }
  }

  /// 坐标 → 国家/城市（失败返回空 RegionContext）
  Future<RegionContext> reverse({
    required double latitude,
    required double longitude,
    String language = 'zh-CN',
  }) async {
    try {
      final res = await _dio.get<dynamic>(
        '$reverseBase/data/reverse-geocode-client',
        queryParameters: {
          'latitude': latitude,
          'longitude': longitude,
          'localityLanguage': language,
        },
        options: Options(responseType: ResponseType.plain),
      );
      if (res.statusCode != 200) return const RegionContext();
      final raw = res.data;
      final map = raw is String ? jsonDecode(raw) : raw;
      if (map is! Map) return const RegionContext();
      final city = '${map['city'] ?? map['locality'] ?? ''}';
      return RegionContext(
        countryCode: '${map['countryCode'] ?? ''}'.toUpperCase(),
        subdivisionCode: '${map['principalSubdivisionCode'] ?? ''}',
        city: city,
        // 反查接口不给时区；时区由天气接口回（Open-Meteo 的 `timezone=auto`），
        // 这里留空，别硬编一个看起来像的
        latitude: latitude,
        longitude: longitude,
        source: RegionSource.eventGps,
      );
    } catch (_) {
      return const RegionContext();
    }
  }
}
