// 环境信息（地区 / 单位 / 天气 / 节假日 / 农历）的离线测试。
//
// 天气与节假日都要联网，所以这里**起一个本机回环桩服务器**，把 base URL 注入到
// 各客户端（`baseUrls=` / `nagerBase=` …），再逐字段比对：
// 桩里故意用**线上真实形状**（NWS 的华氏标量、wttr 的数组包对象、OpenHolidays 的
// `name` 数组），因为这几个形状在真网络探针里把我们坑过一遍（见
// `tool/env_probe.dart` 与 `docs/device-verification.md`）。
//
// ignore_for_file: avoid_manual_injections
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/holidays/holiday_service.dart';
import 'package:synhub/src/data/region/geocode_client.dart';
import 'package:synhub/src/data/region/region_context.dart';
import 'package:synhub/src/data/weather/weather_client.dart';
import 'package:synhub/src/features/calendar/calendar_env.dart';

/// 一个请求记录
class _Hit {
  _Hit(this.uri, this.headers);

  final Uri uri;
  final Map<String, String> headers;
}

/// 回环桩：按路径前缀分派 JSON
class _Stub {
  _Stub(this.routes, {this.statuses = const {}});

  final Map<String, Object? Function(Uri uri, Map<String, String> headers)>
  routes;

  /// 路径前缀 → 显式 HTTP 状态码（默认 200 / 返回 null 时 204）
  final Map<String, int> statuses;
  final List<_Hit> hits = [];
  late final HttpServer _server;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final uri = req.uri;
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      hits.add(_Hit(uri, headers));
      // ⚠️ 必须**最长前缀匹配**：`/stations` 与 `/stations/KNYC/observations/latest`
      // 同时前缀命中时，按声明顺序取会拿错（NWS 测试就是这么拿到 0°C 的）
      String? best;
      Object? Function(Uri, Map<String, String>)? handler;
      for (final e in routes.entries) {
        if (uri.path.startsWith(e.key) &&
            (best == null || e.key.length > best.length)) {
          best = e.key;
          handler = e.value;
        }
      }
      String? statusKey;
      for (final e in statuses.entries) {
        if (uri.path.startsWith(e.key) &&
            (statusKey == null || e.key.length > statusKey.length)) {
          statusKey = e.key;
        }
      }
      if (handler == null) {
        req.response.statusCode = HttpStatus.notFound;
        req.response.write('{"error":"no route ${uri.path}"}');
      } else {
        final forced = statusKey == null ? null : statuses[statusKey];
        final body = handler(uri, headers);
        if (forced != null) {
          req.response.statusCode = forced;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            body == null ? '{"error":"forced"}' : jsonEncode(body),
          );
        } else if (body == null) {
          req.response.statusCode = HttpStatus.noContent;
        } else {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(body));
        }
      }
      await req.response.close();
    });
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> stop() => _server.close(force: true);

  _Hit? hit(String pathPart) {
    for (final h in hits) {
      if (h.uri.path.contains(pathPart)) return h;
    }
    return null;
  }
}

Dio _dio() => Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    validateStatus: (_) => true,
  ),
);

void main() {
  // flutter_test 默认装了一个"所有请求都回 400"的 HttpOverrides
  setUpAll(() => HttpOverrides.global = null);

  group('单位制按国家/地区自动选', () {
    test('美制：°F / mph / in / inHg / mi', () {
      final u = weatherUnitsFor('US');
      expect(u.temperatureLabel, '°F');
      expect(u.wind, WindUnit.mph);
      expect(u.precipitationLabel, 'in');
      expect(u.pressureLabel, 'inHg');
      expect(u.visibilityLabel, 'mi');
      expect(u.convertTemp(20), closeTo(68, 0.01));
      expect(u.convertWind(20), closeTo(12.43, 0.01));
      expect(u.convertPrecip(25.4), closeTo(1, 0.001));
    });

    test('英国是混合制：温度 °C、风速 mph、降水 mm、能见度 mi', () {
      final u = weatherUnitsFor('GB');
      expect(u.temperatureLabel, '°C');
      expect(u.wind, WindUnit.mph);
      expect(u.precipitationLabel, 'mm');
      expect(u.visibilityLabel, 'mi');
    });

    test('中国按"几级风"说，日韩俄按 m/s，德国按 km/h', () {
      expect(weatherUnitsFor('CN').wind, WindUnit.beaufort);
      expect(weatherUnitsFor('TW').wind, WindUnit.beaufort);
      expect(weatherUnitsFor('JP').wind, WindUnit.ms);
      expect(weatherUnitsFor('RU').wind, WindUnit.ms);
      expect(weatherUnitsFor('DE').wind, WindUnit.kmh);
    });

    test('蒲福风级换算与文案', () {
      expect(beaufortOf(0.5), 0);
      expect(beaufortOf(20), 4); // 20km/h → 4 级
      expect(weatherUnitsFor('CN').windText(20), '4 级（和风）');
      expect(weatherUnitsFor('JP').windText(20), '5.6 m/s');
      expect(weatherUnitsFor('US').windText(20), '12.4 mph');
    });

    test('手动覆盖优先于国家判定；auto 回到国家判定', () {
      expect(
        weatherUnitsFor('CN', override: UnitSystem.imperial).temperatureLabel,
        '°F',
      );
      expect(
        weatherUnitsFor('US', override: UnitSystem.auto).temperatureLabel,
        '°F',
      );
      expect(
        weatherUnitsFor('US', override: UnitSystem.metric).wind,
        WindUnit.kmh,
      );
    });

    test('未知地区回落公制（不瞎猜英制）', () {
      expect(weatherUnitsFor('').temperatureLabel, '°C');
      expect(weatherUnitsFor('ZZ').wind, WindUnit.kmh);
    });

    test('序列化往返', () {
      final u = weatherUnitsFor('GB');
      expect(WeatherUnits.fromJson(u.toJson()).wind, u.wind);
      expect(WeatherUnits.fromJson(u.toJson()).visibilityLabel, 'mi');
    });
  });

  group('手选地点（天气要坐标）的设置持久化', () {
    test('坐标/名字/国家往返不丢', () {
      const s = CalendarEnvSettings(
        countryOverride: 'CN',
        manualPlaceName: '杭州',
        manualLatitude: 30.2741,
        manualLongitude: 120.1551,
      );
      final back = CalendarEnvSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>,
      );
      expect(back.manualPlaceName, '杭州');
      expect(back.manualLatitude, closeTo(30.2741, 1e-9));
      expect(back.manualLongitude, closeTo(120.1551, 1e-9));
      expect(back.countryOverride, 'CN');
      expect(back.hasManualPlace, isTrue);
    });

    test('没设地点时 JSON 里不写坐标；copyWith(clear) 清得掉', () {
      const s = CalendarEnvSettings();
      expect(s.toJson().containsKey('manualLatitude'), isFalse);
      final set = s.copyWith(
        manualPlaceName: '北京',
        manualLatitude: 39.9,
        manualLongitude: 116.4,
      );
      expect(set.hasManualPlace, isTrue);
      final cleared = set.copyWith(clearManualPlace: true);
      expect(cleared.hasManualPlace, isFalse);
      expect(cleared.manualPlaceName, '');
    });

    test('坐标存成字符串也读得回来（老数据/别的平台写过的）', () {
      final back = CalendarEnvSettings.fromJson({
        'manualPlaceName': '杭州',
        'manualLatitude': '30.2741',
        'manualLongitude': '120.1551',
      });
      expect(back.manualLatitude, closeTo(30.2741, 1e-9));
    });
  });

  group('时区兜底 → 国家', () {
    test('常见时区命中；未知时区返回空（不猜）', () {
      expect(countryFromTimezone('Asia/Shanghai'), 'CN');
      expect(countryFromTimezone('America/New_York'), 'US');
      expect(countryFromTimezone('Europe/Berlin'), 'DE');
      expect(countryFromTimezone('Pacific/Auckland'), 'NZ');
      expect(countryFromTimezone('Etc/Unknown'), '');
      expect(countryFromTimezone(''), '');
    });

    test('RegionContext 的说明文案带来源', () {
      const r = RegionContext(
        countryCode: 'JP',
        city: '東京',
        source: RegionSource.eventGps,
      );
      expect(r.label, '東京 · JP（日程地点（GPS））');
      expect(RegionContext.fromJson(r.toJson()).countryCode, 'JP');
      expect(RegionContext.fromJson(r.toJson()).source, RegionSource.eventGps);
    });
  });

  group('天气选源', () {
    bool noKey(WeatherProviderInfo p) => false;
    bool hasKey(WeatherProviderInfo p) => p.id == 'qweather';

    test('美国 → NWS（在区加分）', () {
      expect(pickWeatherProvider('US', hasKey: noKey)!.id, 'nws');
    });

    test('德国 → met.no（全球源里它在欧洲加分）', () {
      expect(pickWeatherProvider('DE', hasKey: noKey)!.id, 'met-no');
    });

    test('中国没配和风 key → Open-Meteo（不是 met.no）', () {
      expect(pickWeatherProvider('CN', hasKey: noKey)!.id, 'open-meteo');
    });

    test('中国配了和风 key → 和风优先', () {
      expect(pickWeatherProvider('CN', hasKey: hasKey)!.id, 'qweather');
    });

    test('强制指定源优先；强制一个没 key 的源则回落自动', () {
      expect(
        pickWeatherProvider('CN', hasKey: noKey, forcedId: 'wttr')!.id,
        'wttr',
      );
      expect(
        pickWeatherProvider('CN', hasKey: noKey, forcedId: 'qweather')!.id,
        'open-meteo',
      );
    });

    test('NWS / met.no 标了"必须带 UA"', () {
      expect(weatherProviderById('nws')!.requiresUserAgent, isTrue);
      expect(weatherProviderById('met-no')!.requiresUserAgent, isTrue);
    });
  });

  group('天气解析（本机桩，形状照抄线上）', () {
    test('Open-Meteo：请求带公制参数 + timezone=auto；解析当前与逐日', () async {
      final stub = _Stub({
        '/v1/forecast': (uri, _) {
          expect(uri.queryParameters['temperature_unit'], 'celsius');
          expect(uri.queryParameters['wind_speed_unit'], 'kmh');
          expect(uri.queryParameters['precipitation_unit'], 'mm');
          expect(uri.queryParameters['timezone'], 'auto');
          return {
            'timezone': 'Asia/Shanghai',
            'current': {
              'time': '2026-09-19T10:00',
              'temperature_2m': 24.3,
              'apparent_temperature': 26.5,
              'relative_humidity_2m': 71,
              'weather_code': 3,
              'wind_speed_10m': 6.1,
              'wind_direction_10m': 180,
              'precipitation': 0.2,
              'surface_pressure': 1013.5,
            },
            'daily': {
              'time': ['2026-09-19', '2026-09-20'],
              'weather_code': [51, 3],
              'temperature_2m_max': [28.2, 30.1],
              'temperature_2m_min': [20.5, 19.9],
              'precipitation_sum': [0.2, 0.0],
              'sunrise': ['2026-09-19T05:58', '2026-09-20T05:59'],
              'sunset': ['2026-09-19T18:10', '2026-09-20T18:09'],
            },
          };
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'open-meteo': stub.baseUrl},
      );
      final b = await client.fetch(
        provider: weatherProviderById('open-meteo')!,
        latitude: 39.9,
        longitude: 116.4,
        days: 2,
      );
      final now = b.now!;
      expect(now.temperatureC, 24.3);
      expect(now.code, 3);
      expect(wmoText(now.code), '阴');
      expect(now.humidity, 71);
      expect(now.windDir, '南风');
      expect(now.timezone, 'Asia/Shanghai');
      expect(b.days, hasLength(2));
      expect(b.days.first.minC, 20.5);
      expect(b.days.first.maxC, 28.2);
      expect(b.dayOf(DateTime(2026, 9, 20))!.code, 3);
      expect(b.dayOf(DateTime(2026, 9, 21)), isNull);
    });

    test('NWS：温度是华氏（period 标量 + temperatureUnit）→ 必须换算；用观测站取当前', () async {
      final stub = _Stub({
        '/points/': (uri, headers) {
          // 桩里顺便验证 UA 有没有带上（线上不带会被 403）
          expect(headers['user-agent'], contains('SynHub'));
          return {
            'properties': {
              'forecast': '$_stubUrl/forecast/x',
              'observationStations': '$_stubUrl/stations',
            },
          };
        },
        '/stations': (_, _) => {
          'features': [
            {'id': '$_stubUrl/stations/KNYC'},
          ],
        },
        '/stations/KNYC/observations/latest': (_, _) => {
          'properties': {
            'timestamp': '2026-09-19T14:00:00+00:00',
            'temperature': {'unitCode': 'wmoUnit:degC', 'value': 17.8},
            'relativeHumidity': {'value': 52},
            'windSpeed': {'unitCode': 'wmoUnit:km_h-1', 'value': 16.56},
            'windDirection': {'value': 60},
            'barometricPressure': {'value': 102410},
            'visibility': {'value': 16090},
            'textDescription': 'Mostly Cloudy',
          },
        },
        '/forecast/x': (_, _) => {
          'properties': {
            'periods': [
              {
                'startTime': '2026-09-19T06:00:00-04:00',
                'isDaytime': true,
                'temperature': 71,
                'temperatureUnit': 'F',
                'shortForecast': 'Sunny',
              },
              {
                'startTime': '2026-09-19T18:00:00-04:00',
                'isDaytime': false,
                'temperature': 62,
                'temperatureUnit': 'F',
                'shortForecast': 'Clear',
              },
            ],
          },
        },
      });
      await stub.start();
      _stubUrl = stub.baseUrl;
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'nws': stub.baseUrl},
      );
      final b = await client.fetch(
        provider: weatherProviderById('nws')!,
        latitude: 40.71,
        longitude: -74.0,
        days: 3,
      );
      final now = b.now!;
      // 观测站是摄氏，直接用
      expect(now.temperatureC, closeTo(17.8, 0.01));
      expect(now.humidity, 52);
      expect(now.windKmh, closeTo(16.56, 0.01));
      expect(now.pressureHpa, closeTo(1024.1, 0.05));
      expect(now.visibilityKm, closeTo(16.09, 0.01));
      expect(now.code, 3); // Mostly Cloudy
      // 逐日是华氏 71/62 → 21.67 / 16.67
      expect(b.days.first.maxC, closeTo(21.67, 0.01));
      expect(b.days.first.minC, closeTo(16.67, 0.01));
      expect(b.days.first.code, 0); // Sunny
    });

    test('wttr：current_condition / nearest_area 是数组 → 取第一个', () async {
      final stub = _Stub({
        '/31.230,121.474': (uri, _) {
          expect(uri.queryParameters['format'], 'j1');
          return {
            'current_condition': [
              {
                'temp_C': '24',
                'FeelsLikeC': '27',
                'humidity': '78',
                'weatherCode': '113',
                'windspeedKmph': '10',
                'winddir16Point': 'ENE',
                'precipMM': '0.0',
                'pressure': '1019',
                'visibility': '10',
              },
            ],
            'nearest_area': [
              {
                'areaName': [
                  {'value': 'Shanghai'},
                ],
              },
            ],
            'weather': [
              {
                'date': '2026-09-19',
                'hourly': [
                  {'weatherCode': '176', 'tempC': '24'},
                  {'weatherCode': '176', 'tempC': '29'},
                ],
                'astronomy': [
                  {'sunrise': '05:41 AM', 'sunset': '06:05 PM'},
                ],
              },
            ],
          };
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'wttr': stub.baseUrl},
      );
      final b = await client.fetch(
        provider: weatherProviderById('wttr')!,
        latitude: 31.230,
        longitude: 121.474,
        days: 1,
      );
      expect(b.now!.temperatureC, 24);
      expect(b.now!.apparentC, 27);
      expect(b.now!.humidity, 78);
      expect(b.now!.cityName, 'Shanghai');
      expect(b.now!.code, 0); // 113 晴
      expect(b.days.first.minC, 24);
      expect(b.days.first.maxC, 29);
      expect(b.days.first.sunrise, '05:41 AM');
    });

    test('met.no：compact 结构 + symbol_code 归一', () async {
      final stub = _Stub({
        '/weatherapi/locationforecast/2.0/compact': (uri, headers) {
          expect(headers['user-agent'], contains('SynHub'));
          return {
            'properties': {
              'timeseries': [
                {
                  'time': '2026-09-19T10:00:00Z',
                  'data': {
                    'instant': {
                      'details': {
                        'air_temperature': 19.5,
                        'relative_humidity': 70,
                        'wind_speed': 7.7,
                        'wind_from_direction': 180,
                        'air_pressure_at_sea_level': 994.6,
                      },
                    },
                    'next_1_hours': {
                      'summary': {'symbol_code': 'partlycloudy_day'},
                    },
                  },
                },
              ],
            },
          };
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'met-no': stub.baseUrl},
      );
      final b = await client.fetch(
        provider: weatherProviderById('met-no')!,
        latitude: 59.9,
        longitude: 10.7,
        days: 1,
      );
      expect(b.now!.temperatureC, 19.5);
      expect(b.now!.windKmh, closeTo(27.72, 0.05));
      expect(b.now!.code, 2); // partlycloudy
    });

    test('和风：没 key 直接报人话错误（不发请求）', () async {
      final stub = _Stub({
        '/v7/weather': (_, _) => {'code': '200'},
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'qweather': stub.baseUrl},
      );
      await expectLater(
        client.fetch(
          provider: weatherProviderById('qweather')!,
          latitude: 39.9,
          longitude: 116.4,
          days: 1,
        ),
        throwsA(
          isA<WeatherException>().having(
            (e) => e.message,
            'message',
            contains('API Key'),
          ),
        ),
      );
      expect(stub.hits, isEmpty);
    });

    test('和风：key 以查询参数发出、unit=m；icon 码归一', () async {
      final stub = _Stub({
        '/v7/weather/now': (uri, _) {
          expect(uri.queryParameters['key'], 'k123');
          expect(uri.queryParameters['unit'], 'm');
          expect(uri.queryParameters['location'], '116.40,39.90');
          return {
            'code': '200',
            'now': {
              'temp': '25',
              'feelsLike': '27',
              'humidity': '60',
              'icon': '101',
              'windSpeed': '12',
              'windDir': '东南风',
              'pressure': '1008',
              'vis': '20',
            },
          };
        },
        '/v7/weather/7d': (_, _) => {
          'code': '200',
          'daily': [
            {
              'fxDate': '2026-09-19',
              'iconDay': '305',
              'tempMin': '20',
              'tempMax': '27',
              'sunrise': '05:58',
              'sunset': '18:10',
            },
          ],
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'qweather': stub.baseUrl},
      );
      final b = await client.fetch(
        provider: weatherProviderById('qweather')!,
        latitude: 39.9,
        longitude: 116.4,
        days: 1,
        apiKey: 'k123',
      );
      expect(b.now!.temperatureC, 25);
      expect(b.now!.code, 2); // 101 多云
      expect(b.days.first.code, 63); // 305 中雨
    });

    test('HTTP 错误 → 人话（含状态码）', () async {
      final stub = _Stub(
        {
          '/v1/forecast': (_, _) => {'error': 'rate limited'},
        },
        statuses: {'/v1/forecast': 429},
      );
      await stub.start();
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'open-meteo': stub.baseUrl},
      );
      await expectLater(
        client.fetch(
          provider: weatherProviderById('open-meteo')!,
          latitude: 1,
          longitude: 1,
          days: 1,
        ),
        throwsA(
          isA<WeatherException>().having(
            (e) => e.message,
            'message',
            contains('429'),
          ),
        ),
      );
    });

    test('连不上 → 说"连不上"而不是抛裸异常', () async {
      final client = WeatherClient(
        dio: _dio(),
        // 保留端口但关掉的地址
        baseUrls: {'open-meteo': 'http://127.0.0.1:9'},
      );
      await expectLater(
        client.fetch(
          provider: weatherProviderById('open-meteo')!,
          latitude: 1,
          longitude: 1,
          days: 1,
        ),
        throwsA(isA<WeatherException>()),
      );
    });

    test('逐小时：open-meteo 的**平行数组**（time[] + 每字段一个数组）', () async {
      final stub = _Stub({
        '/v1/forecast': (uri, _) {
          // 必须真的把 `hourly=…` 带上，否则线上不会回逐小时
          expect(uri.queryParameters['hourly'], contains('temperature_2m'));
          expect(
            uri.queryParameters['hourly'],
            contains('precipitation_probability'),
          );
          return {
            'current': {'temperature_2m': 24.0, 'weather_code': 3},
            'daily': {
              'time': ['2026-09-20'],
              'weather_code': [3],
              'temperature_2m_max': [30.0],
              'temperature_2m_min': [20.0],
            },
            'hourly': {
              'time': [
                '2026-09-20T00:00',
                '2026-09-20T01:00',
                '2026-09-21T00:00', // 次日：`hoursFor` 不能把它算进来
              ],
              'weather_code': [0, 61, 3],
              'temperature_2m': [19.4, 18.8, 17.0],
              'precipitation_probability': [0, 65, 10],
              'precipitation': [0.0, 1.2, 0.0],
            },
          };
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'open-meteo': stub.baseUrl},
      );
      final b = await client.fetch(
        provider: weatherProviderById('open-meteo')!,
        latitude: 39.9,
        longitude: 116.4,
        days: 1,
      );
      expect(b.hours, hasLength(3));
      expect(b.hours[1].temperatureC, 18.8);
      expect(b.hours[1].precipitationProbability, 65);
      expect(b.hours[1].precipitationMm, 1.2);
      expect(wmoText(b.hours[1].code), '小雨');
      expect(b.hoursFor(DateTime(2026, 9, 20)), hasLength(2));
      expect(
        b.hoursFrom(DateTime(2026, 9, 20, 1)),
        hasLength(2),
        reason: '从 1 点起算：1 点 + 次日 0 点',
      );
    });

    test('逐小时：wttr 的 `time` 是 3 小时一格的 `"0"`/`"300"`（HHMM）', () async {
      final stub = _Stub({
        '/39.900,116.400': (_, _) => {
          'current_condition': [
            {'temp_C': '24', 'weatherCode': '116', 'humidity': '40'},
          ],
          'nearest_area': [
            {
              'areaName': [
                {'value': 'Beijing'},
              ],
            },
          ],
          'weather': [
            {
              'date': '2026-09-20',
              'hourly': [
                {
                  'time': '0',
                  'tempC': '19',
                  'weatherCode': '113',
                  'chanceofrain': '0',
                  'precipMM': '0.0',
                },
                {
                  'time': '300', // 03:00
                  'tempC': '18',
                  'weatherCode': '296',
                  'chanceofrain': '55',
                  'precipMM': '0.4',
                },
              ],
            },
          ],
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'wttr': stub.baseUrl},
      );
      final b = await client.fetch(
        provider: weatherProviderById('wttr')!,
        latitude: 39.9,
        longitude: 116.4,
        days: 1,
      );
      expect(b.hours, hasLength(2));
      expect(b.hours.first.time, DateTime(2026, 9, 20, 0, 0));
      expect(
        b.hours.last.time,
        DateTime(2026, 9, 20, 3, 0),
        reason: '"300" = 03:00，不是 300 分钟也不是 3 点整以外的时刻',
      );
      expect(b.hours.last.precipitationProbability, 55);
      expect(b.hours.last.precipitationMm, 0.4);
    });

    test('逐小时：met.no 的 timeseries 直接就是 1 小时一格', () async {
      final stub = _Stub({
        '/weatherapi/locationforecast/2.0/compact': (_, _) => {
          'properties': {
            'timeseries': [
              {
                'time': '2026-09-20T10:00:00Z',
                'data': {
                  'instant': {
                    'details': {'air_temperature': 19.5, 'wind_speed': 7.7},
                  },
                  'next_1_hours': {
                    'summary': {'symbol_code': 'partlycloudy_day'},
                    'details': {
                      'precipitation_amount': 0.3,
                      'probability_of_precipitation': 40.0,
                    },
                  },
                },
              },
              {
                'time': '2026-09-20T11:00:00Z',
                'data': {
                  'instant': {
                    'details': {'air_temperature': 20.5, 'wind_speed': 5.0},
                  },
                  'next_1_hours': {
                    'summary': {'symbol_code': 'clearsky_day'},
                  },
                },
              },
            ],
          },
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'met-no': stub.baseUrl},
      );
      final b = await client.fetch(
        provider: weatherProviderById('met-no')!,
        latitude: 59.9,
        longitude: 10.7,
        days: 1,
      );
      expect(b.hours, hasLength(2));
      expect(b.hours.first.temperatureC, 19.5);
      expect(b.hours.first.precipitationMm, 0.3);
      expect(b.hours.first.precipitationProbability, 40);
      expect(b.hours.first.windKmh, closeTo(27.72, 0.05));
      expect(b.hours[1].temperatureC, 20.5);
    });

    test('逐小时：NWS 要另取 `forecastHourly`（第二次请求，失败不致命）', () async {
      final stub = _Stub({
        '/points/': (_, _) => {
          'properties': {
            'forecast': '$_stubUrl/hf',
            'forecastHourly': '$_stubUrl/hourly',
          },
        },
        '/hf': (_, _) => {
          'properties': {
            'periods': [
              {
                'startTime': '2026-09-20T06:00:00-04:00',
                'temperature': 68,
                'temperatureUnit': 'F',
                'isDaytime': true,
                'shortForecast': 'Sunny',
              },
            ],
          },
        },
        '/hourly': (_, _) => {
          'properties': {
            'periods': [
              {
                'startTime': '2026-09-20T06:00:00-04:00',
                'temperature': 68,
                'temperatureUnit': 'F',
                'shortForecast': 'Sunny',
                'probabilityOfPrecipitation': {'value': 10},
                'windSpeed': '5 mph',
              },
              {
                'startTime': '2026-09-20T07:00:00-04:00',
                'temperature': 72,
                'temperatureUnit': 'F',
                'shortForecast': 'Chance Rain Showers',
                'probabilityOfPrecipitation': {'value': 35},
              },
            ],
          },
        },
      });
      await stub.start();
      _stubUrl = stub.baseUrl;
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'nws': stub.baseUrl},
      );
      final b = await client.fetch(
        provider: weatherProviderById('nws')!,
        latitude: 40.7,
        longitude: -74.0,
        days: 1,
      );
      expect(b.hours, hasLength(2));
      expect(
        b.hours.first.temperatureC,
        closeTo(20, 0.1),
        reason: '68°F ≈ 20°C',
      );
      expect(b.hours.first.precipitationProbability, 10);
      expect(wmoText(b.hours[1].code), contains('阵雨'));
    });

    test('逐小时：和风的 `/v7/weather/24h`（`hourly[]` 带 pop）', () async {
      final stub = _Stub({
        '/v7/weather/now': (_, _) => {
          'code': '200',
          'now': {'temp': '24', 'icon': '100'},
        },
        '/v7/weather/7d': (_, _) => {
          'code': '200',
          'daily': [
            {
              'fxDate': '2026-09-20',
              'tempMax': '30',
              'tempMin': '20',
              'iconDay': '100',
            },
          ],
        },
        '/v7/weather/24h': (_, _) => {
          'code': '200',
          'hourly': [
            {
              'fxTime': '2026-09-20T14:00+08:00',
              'temp': '28',
              'icon': '101',
              'pop': '20',
              'precip': '0.0',
              'windSpeed': '9',
            },
            {
              'fxTime': '2026-09-20T15:00+08:00',
              'temp': '29',
              'icon': '305',
              'pop': '70',
              'precip': '1.5',
            },
          ],
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = WeatherClient(
        dio: _dio(),
        baseUrls: {'qweather': stub.baseUrl},
      );
      final b = await client.fetch(
        provider: weatherProviderById('qweather')!,
        latitude: 39.9,
        longitude: 116.4,
        days: 1,
        apiKey: 'K',
      );
      expect(b.hours, hasLength(2));
      expect(b.hours.first.temperatureC, 28);
      expect(b.hours.first.precipitationProbability, 20);
      expect(b.hours.last.precipitationMm, 1.5);
      expect(b.hours.last.windKmh, isNull, reason: '第二格源里没给风速');
    });
  });

  group('节假日', () {
    test('Nager：解析 localName / types / counties；204 → 空', () async {
      final stub = _Stub({
        '/PublicHolidays/2026/DE': (_, _) => [
          {
            'date': '2026-01-01',
            'localName': 'Neujahr',
            'name': "New Year's Day",
            'countryCode': 'DE',
            'global': true,
            'types': ['Public'],
          },
          {
            'date': '2026-01-06',
            'localName': 'Heilige Drei Könige',
            'types': ['Public'],
            'counties': ['DE-BY'],
          },
          {
            'date': '2026-02-12',
            'localName': 'Lincoln',
            'types': ['Observance'],
          },
        ],
        '/PublicHolidays/2026/TW': (_, _) => null, // 204：不支持
      });
      await stub.start();
      addTearDown(stub.stop);
      // DE 在 OpenHolidays 覆盖范围内 → 必须把它也指向死地址，
      // 否则会去**真实的 openholidaysapi.org** 拿数据（实测混进 18 条，断言全乱）
      final svc = HolidayService(
        dio: _dio(),
        nagerBase: stub.baseUrl,
        openHolidaysBase: 'http://127.0.0.1:9',
      );
      final de = await svc.load(countryCode: 'DE', year: 2026);
      expect(de.entries, hasLength(3));
      expect(de.entries.first.name, 'Neujahr');
      expect(de.entries.first.kind, HolidayKind.public);
      expect(de.entries[1].subdivisionCode, 'DE-BY');
      expect(de.entries.last.kind, HolidayKind.observance);
      expect(de.sources, contains('nager'));

      final tw = await svc.load(countryCode: 'TW', year: 2026);
      expect(tw.entries.where((e) => e.source == 'nager'), isEmpty);
      expect(tw.note, contains('没有公开的法定节假日数据源'));
    });

    test('OpenHolidays：name 是数组、type 映射、州参数传下去', () async {
      final stub = _Stub({
        '/PublicHolidays': (uri, _) {
          expect(uri.queryParameters['countryIsoCode'], 'DE');
          expect(uri.queryParameters['subdivisionCode'], 'DE-BY');
          expect(uri.queryParameters['validFrom'], '2026-01-01');
          return [
            {
              'startDate': '2026-01-01',
              'type': 'Public',
              'name': [
                {'language': 'DE', 'text': 'Neujahr'},
                {'language': 'EN', 'text': "New Year's Day"},
              ],
              'subdivisionCode': 'DE-BY',
            },
            {
              'startDate': '2026-01-06',
              'type': 'Bank',
              'name': [
                {'language': 'DE', 'text': 'Bankfeiertag'},
              ],
            },
          ];
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final svc = HolidayService(
        dio: _dio(),
        nagerBase: '${stub.baseUrl}/nonexistent',
        openHolidaysBase: stub.baseUrl,
      );
      final b = await svc.load(
        countryCode: 'DE',
        year: 2026,
        subdivisionCode: 'DE-BY',
      );
      final open = b.entries.where((e) => e.source == 'openholidays').toList();
      expect(open, hasLength(2));
      expect(open.first.name, 'Neujahr');
      expect(open.first.kind, HolidayKind.public);
      expect(open.first.subdivisionCode, 'DE-BY');
      expect(open.last.kind, HolidayKind.observance); // Bank → 纪念
    });

    test('同义节日跨源合并（Neujahr vs New Year\'s Day 只留一条，留本地语言）', () {
      final merged = HolidayService.mergeHolidays([
        HolidayEntry(
          date: DateTime(2026, 1, 1),
          name: "New Year's Day",
          kind: HolidayKind.public,
          source: 'nager',
        ),
        HolidayEntry(
          date: DateTime(2026, 1, 1),
          name: 'Neujahr',
          kind: HolidayKind.public,
          source: 'openholidays',
        ),
        // 名字认不出来 → 两条都留（宁可多一条，别丢真节日）
        HolidayEntry(
          date: DateTime(2026, 5, 1),
          name: 'Tag der Arbeit',
          kind: HolidayKind.public,
          source: 'openholidays',
        ),
        HolidayEntry(
          date: DateTime(2026, 5, 1),
          name: 'Staatsfeiertag',
          kind: HolidayKind.public,
          source: 'nager',
        ),
      ]);
      final jan1 = merged.where((e) => e.date.month == 1).toList();
      expect(jan1, hasLength(1));
      expect(jan1.first.name, 'Neujahr');
      final may1 = merged.where((e) => e.date.month == 5).toList();
      expect(may1, hasLength(1));
      expect(may1.first.name, 'Tag der Arbeit'); // labour 别名命中
    });

    test('中国大陆：本地官方表优先，网络源同一天的法定条目让位', () async {
      final stub = _Stub({
        '/PublicHolidays/2026/CN': (_, _) => [
          {
            'date': '2026-10-01',
            'localName': 'National Day',
            'types': ['Public'],
          },
          {
            'date': '2026-02-17',
            'localName': 'Chinese New Year',
            'types': ['Public'],
          },
          {
            'date': '2026-12-25',
            'localName': 'Christmas Day',
            'types': ['Public'],
          },
        ],
      });
      await stub.start();
      addTearDown(stub.stop);
      final svc = HolidayService(dio: _dio(), nagerBase: stub.baseUrl);
      final b = await svc.load(countryCode: 'CN', year: 2026);
      // 10-01 / 02-17 的英文条目被本地官方表挤掉
      expect(
        b.entries.where((e) => e.name == 'National Day'),
        isEmpty,
        reason: '10-01 应该只有"国庆节"',
      );
      expect(b.entries.where((e) => e.name == 'Chinese New Year'), isEmpty);
      // 本地表没有的日子，网络源照留
      expect(b.entries.where((e) => e.name == 'Christmas Day'), hasLength(1));
      final oct1 = b.on(DateTime(2026, 10, 1));
      expect(oct1.where((e) => e.kind == HolidayKind.public), hasLength(1));
      expect(oct1.first.name, contains('国庆'));
    });

    test('本地农历：2026 年含春节/清明/中秋、且含调休上班', () {
      final entries = ChineseCalendar.yearEntries(2026, includeOfficial: true);
      final byName = <String, List<HolidayEntry>>{};
      for (final e in entries) {
        byName.putIfAbsent(e.name, () => []).add(e);
      }
      expect(byName['春节'], isNotNull);
      expect(byName['中秋节'], isNotNull);
      // 清明在 2026 是 4/5（节气 + 法定假期 4/4~4/6 都在）
      expect(byName['清明节'], isNotNull);
      expect(
        byName['清明节']!.map((e) => e.date.day).toSet(),
        containsAll(<int>[4, 5, 6]),
      );
      // 调休上班必须标出来（2/14 与 2/28 是 2026 年春节前后的补班）
      final workdays = entries
          .where((e) => e.kind == HolidayKind.workday)
          .map((e) => '${e.date.month}-${e.date.day}')
          .toSet();
      expect(workdays, containsAll(<String>['2-14', '2-28']));
      // 节气也在（一年 24 个）
      expect(
        entries.where((e) => e.kind == HolidayKind.solarTerm).length,
        greaterThanOrEqualTo(24),
      );
    });

    test('非华人地区不塞农历节日', () async {
      final stub = _Stub({
        '/PublicHolidays/2026/FR': (_, _) => [
          {
            'date': '2026-01-01',
            'localName': 'Jour de l\'an',
            'types': ['Public'],
          },
        ],
      });
      await stub.start();
      addTearDown(stub.stop);
      final svc = HolidayService(dio: _dio(), nagerBase: stub.baseUrl);
      final b = await svc.load(countryCode: 'FR', year: 2026);
      expect(b.sources, isNot(contains('lunar')));
      expect(b.entries.where((e) => e.name == '春节'), isEmpty);
    });

    test('缓存：第二次不再发请求；forceRefresh 会重发', () async {
      var calls = 0;
      final stub = _Stub({
        '/PublicHolidays/2026/US': (_, _) {
          calls++;
          return [
            {
              'date': '2026-07-04',
              'localName': 'Independence Day',
              'types': ['Public'],
            },
          ];
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final svc = HolidayService(dio: _dio(), nagerBase: stub.baseUrl);
      await svc.load(countryCode: 'US', year: 2026);
      await svc.load(countryCode: 'US', year: 2026);
      expect(calls, 1);
      await svc.load(countryCode: 'US', year: 2026, forceRefresh: true);
      expect(calls, 2);
    });

    test('一个源挂了不影响另一个（说明里如实写）', () async {
      final stub = _Stub({
        '/PublicHolidays': (_, _) => [
          {
            'startDate': '2026-05-01',
            'type': 'Public',
            'name': [
              {'language': 'DE', 'text': 'Tag der Arbeit'},
            ],
          },
        ],
      });
      await stub.start();
      addTearDown(stub.stop);
      final svc = HolidayService(
        dio: _dio(),
        nagerBase: 'https://127.0.0.1:9/nope',
        openHolidaysBase: stub.baseUrl,
      );
      final b = await svc.load(countryCode: 'DE', year: 2026);
      expect(b.entries.where((e) => e.name == 'Tag der Arbeit'), hasLength(1));
      expect(b.note, contains('取数失败'));
    });

    test('序列化往返（供设置表缓存）', () {
      final b = HolidayBundle(
        countryCode: 'CN',
        year: 2026,
        entries: [
          HolidayEntry(
            date: DateTime(2026, 10, 1),
            name: '国庆节',
            kind: HolidayKind.public,
            source: 'lunar',
          ),
          HolidayEntry(
            date: DateTime(2026, 2, 14),
            name: '春节',
            kind: HolidayKind.workday,
            source: 'lunar',
          ),
        ],
        sources: const ['lunar'],
      );
      final back = HolidayBundle.fromJson(b.toJson());
      expect(back.entries, hasLength(2));
      expect(back.entries.first.date, DateTime(2026, 10, 1));
      expect(back.entries.last.kind, HolidayKind.workday);
      expect(back.countryCode, 'CN');
    });
  });

  group('农历格子标签', () {
    test('法定 > 农历节日 > 节气 > 公历节日 > 农历日', () {
      final spring = ChineseCalendar.infoFor(DateTime(2026, 2, 17));
      expect(spring.label, '春节');
      expect(spring.isOfficialHoliday, isTrue);
      expect(spring.lunarMonthDay, '正月初一');

      final qingming = ChineseCalendar.infoFor(DateTime(2026, 4, 5));
      // 这一天既是节气"清明"又是法定"清明节"：官方表优先（labelKind = 法定）
      expect(qingming.label, '清明节');
      expect(qingming.labelKind, HolidayKind.public);
      expect(qingming.isOfficialHoliday, isTrue);
      // 2026-04-04/06 也是清明假期，但不是节气当天
      final qm4 = ChineseCalendar.infoFor(DateTime(2026, 4, 4));
      expect(qm4.label, '清明节');

      final midAutumn = ChineseCalendar.infoFor(DateTime(2026, 9, 25));
      expect(midAutumn.label, '中秋节');
      expect(midAutumn.lunarMonthDay, '八月十五');

      final national = ChineseCalendar.infoFor(DateTime(2026, 10, 1));
      expect(national.label, '国庆节');
      expect(national.isOfficialHoliday, isTrue);

      // 调休上班那天要能标出来（2026-02-28 春节补班）
      final workday = ChineseCalendar.infoFor(DateTime(2026, 2, 28));
      expect(workday.isWorkday, isTrue);
      expect(workday.labelKind, HolidayKind.workday);

      // 普通日子显示农历日
      final plain = ChineseCalendar.infoFor(DateTime(2026, 3, 3));
      expect(plain.label, '元宵节'); // 正月十五是节日
      final plain2 = ChineseCalendar.infoFor(DateTime(2026, 3, 4));
      expect(plain2.label, '十六');
      expect(plain2.isFestival, isFalse);
    });

    test('闰月年份不崩（2025 有闰六月）', () {
      final entries = ChineseCalendar.yearEntries(2025);
      expect(entries, isNotEmpty);
      expect(entries.any((e) => e.kind == HolidayKind.traditional), isTrue);
    });
  });

  group('地理编码', () {
    test('Open-Meteo 命不中就退 Nominatim（中文地名实测 Open-Meteo 回空）', () async {
      final stub = _Stub({
        '/v1/search': (_, _) => {'results': <Object?>[]},
        '/search': (uri, headers) {
          expect(headers['user-agent'], contains('SynHub'));
          return [
            {
              'name': '北京',
              'lat': '39.9057136',
              'lon': '116.3912972',
              'address': {'country_code': 'cn', 'state': '北京市'},
            },
          ];
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = GeocodeClient(
        dio: _dio(),
        geocodingBase: stub.baseUrl,
        nominatimBase: stub.baseUrl,
      );
      final hits = await client.search('北京');
      expect(hits, hasLength(1));
      expect(hits.first.countryCode, 'CN');
      expect(hits.first.admin1, '北京市');
      expect(hits.first.latitude, closeTo(39.9057, 0.001));
      expect(hits.first.toRegion().source, RegionSource.eventAddress);
    });

    test('坐标反查 → 国家/城市；语言按 zh-CN 传', () async {
      final stub = _Stub({
        '/data/reverse-geocode-client': (uri, _) {
          expect(uri.queryParameters['localityLanguage'], 'zh-CN');
          return {
            'countryCode': 'US',
            'city': '舊金山',
            'principalSubdivisionCode': 'US-CA',
          };
        },
      });
      await stub.start();
      addTearDown(stub.stop);
      final client = GeocodeClient(dio: _dio(), reverseBase: stub.baseUrl);
      final region = await client.reverse(latitude: 37.77, longitude: -122.42);
      expect(region.countryCode, 'US');
      expect(region.city, '舊金山');
      expect(region.subdivisionCode, 'US-CA');
      expect(region.source, RegionSource.eventGps);
    });

    test('两边都挂 → 返回空（不编地址）', () async {
      final client = GeocodeClient(
        dio: _dio(),
        geocodingBase: 'http://127.0.0.1:9',
        nominatimBase: 'http://127.0.0.1:9',
      );
      expect(await client.search('北京'), isEmpty);
      final region = await client.reverse(latitude: 1, longitude: 1);
      expect(region.isKnown, isFalse);
    });
  });
}

/// NWS 桩要回**指向自己**的 URL（预报与观测站），端口要等 start() 之后才知道，
/// 所以用一个可变全局在 start 之后再注入（桩的处理函数是请求时才读它，来得及）
String _stubUrl = '';
