// 天气：**多源 + 按国家/地区自动选源**，内部一律公制，出口按地区单位换算。
//
// 为什么内部统一公制：各家的"英制参数"覆盖不一（Open-Meteo 支持 `temperature_unit`
// 等，NWS 只回 `wmoUnit:degC`，met.no 只有公制），如果各家各返回一套单位，
// 上层就要到处判断。**统一在入口转成公制，出口按 [WeatherUnits] 换算**，
// 换算逻辑只有一处、可测。
//
// 供应商（都免 key，除了和风需要用户自己的 key）：
//   * `open-meteo` 全球，免 key，一次请求拿当前+逐日+逐小时，`timezone=auto`
//   * `nws`（api.weather.gov）美国本土/属地官方源，免 key，**必须带 User-Agent**
//   * `met-no`（api.met.no）北欧/全球，免 key，**必须带可识别 UA**
//   * `qweather`（devapi.qweather.com）中国体验最好，**需要 key**，支持 `unit=m/i`
//   * `wttr`（wttr.in）全球兜底，免 key，`format=j1`
//
// 选源规则（[WeatherProviders.pickFor]）：按国家优先级挑**可用**的第一个
// （需要 key 的必须已配置）；都不行就用全球兜底，再不行就如实报错。
import 'dart:convert';

import 'package:dio/dio.dart';
import '../../core/net/traffic_meter.dart';
import 'package:flutter/foundation.dart';

import '../../core/i18n/data_text.dart';

/// 一家天气源
@immutable
class WeatherProviderInfo {
  const WeatherProviderInfo({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.countries = const {},
    this.global = false,
    this.needsKey = false,
    this.priority = 50,
    this.note = '',
    this.docsUrl = '',
    this.requiresUserAgent = false,
  });

  final String id;

  /// 源名（**中文回落**：界面侧读 [nameText]；`lib/src/features/**` 本轮不在迁移范围）
  final String name;
  final String baseUrl;

  /// 只在这些国家/地区可用（空 = 看 [global]）
  final Set<String> countries;

  /// 全球可用
  final bool global;
  final bool needsKey;
  final int priority;

  /// 数字越小越优先
  /// （`note` 同 [name]，是**中文回落**，界面侧读 [noteText]）
  final String note;
  final String docsUrl;

  /// 官方要求带可识别 User-Agent（NWS、met.no 都会拒绝默认 UA）
  final bool requiresUserAgent;

  /// `id` → ARB key 里的驼峰段（认不出的源返回 null，名字原样显示）
  static String? _suffix(String id) => switch (id) {
    'nws' => 'Nws',
    'qweather' => 'Qweather',
    'met-no' => 'MetNo',
    'open-meteo' => 'OpenMeteo',
    'wttr' => 'Wttr',
    _ => null,
  };

  /// ARB key（多语言用；数据层不能碰 `AppText`）
  String? get nameKey {
    final s = _suffix(id);
    return s == null ? null : 'wxProvider${s}Name';
  }

  String? get noteKey {
    final s = _suffix(id);
    return s == null ? null : 'wxProvider${s}Note';
  }

  /// 当前语言文案（走 `data_text.dart` 的 [dataText]；没装翻译器时回落 [name]/[note]）
  String nameText() {
    final k = nameKey;
    return k == null ? name : dataText(k, name);
  }

  String noteText() {
    final k = noteKey;
    return k == null ? note : dataText(k, note);
  }

  bool covers(String countryCode) {
    if (global) return true;
    final cc = countryCode.toUpperCase();
    return cc.isNotEmpty && countries.contains(cc);
  }

  /// 实际排序分：**在区**的源加分（met.no 在全球都能用，但在欧洲才是首选；
  /// 中国没有和风 key 时应该落到 Open-Meteo，而不是被 met.no 的全局兜底抢走）
  int effectivePriority(String countryCode) {
    final cc = countryCode.toUpperCase();
    return countries.contains(cc) ? priority - 10 : priority;
  }
}

const List<WeatherProviderInfo> kWeatherProviders = [
  WeatherProviderInfo(
    id: 'nws',
    name: 'NWS（美国官方）',
    baseUrl: 'https://api.weather.gov',
    countries: {'US', 'PR', 'VI', 'GU', 'AS', 'MP'},
    priority: 10,
    requiresUserAgent: true,
    note: '美国国家气象局，官方源、免 key',
    docsUrl: 'https://www.weather.gov/documentation/services-web-api',
  ),
  WeatherProviderInfo(
    id: 'qweather',
    name: '和风天气 QWeather',
    baseUrl: 'https://devapi.qweather.com',
    global: true,
    needsKey: true,
    priority: 15,
    note: '中国境内体验最好（要自己的 key）',
    docsUrl: 'https://dev.qweather.com/docs/api/',
  ),
  WeatherProviderInfo(
    id: 'met-no',
    name: 'MET Norway',
    baseUrl: 'https://api.met.no',
    global: true,
    countries: {
      'NO',
      'SE',
      'DK',
      'FI',
      'IS',
      'EE',
      'LV',
      'LT',
      'IE',
      'GB',
      'NL',
      'BE',
      'DE',
      'FR',
      'ES',
      'PT',
      'IT',
      'AT',
      'CH',
      'PL',
      'CZ',
      'SK',
      'HU',
      'HR',
      'SI',
    },
    priority: 25,
    requiresUserAgent: true,
    note: '挪威气象局，欧洲数据好、免 key',
    docsUrl: 'https://api.met.no/weatherapi/locationforecast/2.0/documentation',
  ),
  WeatherProviderInfo(
    id: 'open-meteo',
    name: 'Open-Meteo',
    baseUrl: 'https://api.open-meteo.com',
    global: true,
    priority: 20,
    note: '全球、免 key、一次拿当前+逐日+逐小时',
    docsUrl: 'https://open-meteo.com/en/docs',
  ),
  WeatherProviderInfo(
    id: 'wttr',
    name: 'wttr.in',
    baseUrl: 'https://wttr.in',
    global: true,
    priority: 90,
    note: '兜底源（列表里最后一个）',
    docsUrl: 'https://github.com/chubin/wttr.in',
  ),
];

WeatherProviderInfo? weatherProviderById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final p in kWeatherProviders) {
    if (p.id == id) return p;
  }
  return null;
}

/// 选源：国家优先 → 全球兜底；需要 key 的必须已配置
WeatherProviderInfo? pickWeatherProvider(
  String countryCode, {
  required bool Function(WeatherProviderInfo) hasKey,
  String? forcedId,
}) {
  final forced = weatherProviderById(forcedId);
  if (forced != null && (!forced.needsKey || hasKey(forced))) return forced;
  final candidates =
      kWeatherProviders
          .where((p) => p.covers(countryCode))
          .where((p) => !p.needsKey || hasKey(p))
          .toList()
        ..sort(
          (a, b) => a
              .effectivePriority(countryCode)
              .compareTo(b.effectivePriority(countryCode)),
        );
  return candidates.isEmpty ? null : candidates.first;
}

/// 当前天气（内部公制）
@immutable
class WeatherNow {
  const WeatherNow({
    required this.providerId,
    required this.temperatureC,
    required this.code,
    this.apparentC,
    this.humidity,
    this.windKmh,
    this.windDir = '',
    this.precipitationMm,
    this.pressureHpa,
    this.visibilityKm,
    this.updatedAt,
    this.cityName = '',
    this.timezone = '',
  });

  final String providerId;
  final double temperatureC;

  /// WMO 天气码（各家都归一到它）
  final int code;
  final double? apparentC;
  final int? humidity;
  final double? windKmh;
  final String windDir;
  final double? precipitationMm;
  final double? pressureHpa;
  final double? visibilityKm;
  final DateTime? updatedAt;
  final String cityName;

  /// 来源回的时区（Open-Meteo 的 `timezone=auto`）
  final String timezone;

  String icon() => wmoIcon(code);

  String text() => wmoText(code);
}

/// 逐日预报（内部公制）
@immutable
class WeatherDay {
  const WeatherDay({
    required this.date,
    required this.code,
    required this.minC,
    required this.maxC,
    this.precipitationMm,
    this.sunrise = '',
    this.sunset = '',
  });

  final DateTime date;
  final int code;
  final double minC;
  final double maxC;

  String icon() => wmoIcon(code);

  String text() => wmoText(code);
  final double? precipitationMm;
  final String sunrise;
  final String sunset;
}

/// 逐小时预报的一条。
///
/// 各源的取法（都写在各自的解析函数里）：
/// * open-meteo：`hourly.temperature_2m/weather_code/precipitation_probability/precipitation`
/// * met.no：`properties.timeseries[]`（本来就是 1 小时一格）
/// * NWS：`points.properties.forecastHourly`（**额外一次请求**，periods 每格 1 小时）
/// * 和风：`/v7/weather/24h`（**额外一次请求**，`hourly[]`）
/// * wttr.in：`weather[].hourly[]`（**3 小时一格**，`time` 是 `"0"`/`"300"`…）
class WeatherHour {
  const WeatherHour({
    required this.time,
    required this.code,
    required this.temperatureC,
    this.precipitationMm,
    this.precipitationProbability,
    this.windKmh,
  });

  final DateTime time;
  final int code;
  final double temperatureC;
  final double? precipitationMm;

  /// 降水概率（百分数，0–100）；源没给就是 null
  final int? precipitationProbability;
  final double? windKmh;

  String icon() => wmoIcon(code);

  String text() => wmoText(code);
}

/// 一次"按天取天气"的结果
@immutable
class WeatherBundle {
  const WeatherBundle({
    required this.providerId,
    required this.now,
    required this.days,
    this.hours = const [],
    this.fetchedAt,
  });

  final String providerId;
  final WeatherNow? now;
  final List<WeatherDay> days;

  /// 逐小时预报（能拿到的源才给；不是每个源都有，也不保证覆盖整天）
  final List<WeatherHour> hours;
  final DateTime? fetchedAt;

  /// 某一天的逐小时预报（按时间升序；没有就空表）
  List<WeatherHour> hoursFor(DateTime day) => hours
      .where(
        (h) =>
            h.time.year == day.year &&
            h.time.month == day.month &&
            h.time.day == day.day,
      )
      .toList(growable: false);

  /// 从 [from] 起（含）往后的 [count] 条，用于"接下来几小时"
  List<WeatherHour> hoursFrom(DateTime from, {int count = 24}) {
    final after = hours
        .where((h) => !h.time.isBefore(from))
        .toList(growable: false);
    return after.length > count ? after.sublist(0, count) : after;
  }

  WeatherDay? dayOf(DateTime date) {
    for (final d in days) {
      if (d.date.year == date.year &&
          d.date.month == date.month &&
          d.date.day == date.day) {
        return d;
      }
    }
    return null;
  }
}

class WeatherException implements Exception {
  WeatherException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WeatherClient {
  WeatherClient({Dio? dio, String? userAgent, this.baseUrls = const {}})
    : _dio = tagDioWithModule(
        dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
                validateStatus: (_) => true,
              ),
            ),
        TrafficModules.calendar,
      ),
      _userAgent = userAgent ?? kWeatherUserAgent;

  final Dio _dio;

  /// base URL 覆盖（测试用本机桩服务器；键是 provider id）
  final Map<String, String> baseUrls;

  String _base(String id, String fallback) => baseUrls[id] ?? fallback;

  /// ⚠️ NWS 与 met.no **会拒**默认/空 UA（实测 NWS 直接 403），
  /// 官方要求写明应用与联系方式，这里如实写。
  static const String kWeatherUserAgent =
      'SynHub/0.1 (Synology client station; +https://github.com/openviewai)';

  final String _userAgent;

  Map<String, String> get _headers => {
    'User-Agent': _userAgent,
    'Accept': 'application/json',
  };

  Future<WeatherBundle> fetch({
    required WeatherProviderInfo provider,
    required double latitude,
    required double longitude,
    required int days,
    String apiKey = '',
    String language = 'zh',
  }) async {
    switch (provider.id) {
      case 'nws':
        return _nws(latitude, longitude);
      case 'met-no':
        return _metNo(latitude, longitude);
      case 'qweather':
        return _qweather(latitude, longitude, apiKey, language);
      case 'wttr':
        return _wttr(latitude, longitude, language);
      default:
        return _openMeteo(latitude, longitude, days);
    }
  }

  // ------------------------------------------------------------- Open-Meteo

  Future<WeatherBundle> _openMeteo(double lat, double lon, int days) async {
    final map = await _getJson(
      '${_base('open-meteo', 'https://api.open-meteo.com')}/v1/forecast',
      {
        'latitude': lat,
        'longitude': lon,
        'current': [
          'temperature_2m',
          'apparent_temperature',
          'relative_humidity_2m',
          'weather_code',
          'wind_speed_10m',
          'wind_direction_10m',
          'precipitation',
          'surface_pressure',
        ].join(','),
        'daily': [
          'weather_code',
          'temperature_2m_max',
          'temperature_2m_min',
          'precipitation_sum',
          'sunrise',
          'sunset',
        ].join(','),
        // 逐小时（`forecast_hours` 不传时默认给满 7×24 小时）
        'hourly': [
          'temperature_2m',
          'weather_code',
          'precipitation_probability',
          'precipitation',
        ].join(','),
        'timezone': 'auto',
        'forecast_days': days.clamp(1, 16),
        // 内部统一公制：显式声明，别依赖默认值
        'temperature_unit': 'celsius',
        'wind_speed_unit': 'kmh',
        'precipitation_unit': 'mm',
      },
    );
    final cur = _asMap(map['current']);
    final daily = _asMap(map['daily']);
    final now = WeatherNow(
      providerId: 'open-meteo',
      temperatureC: _d(cur['temperature_2m']),
      apparentC: _dOrNull(cur['apparent_temperature']),
      humidity: (cur['relative_humidity_2m'] as num?)?.round(),
      code: (cur['weather_code'] as num?)?.round() ?? 0,
      windKmh: _dOrNull(cur['wind_speed_10m']),
      windDir: windDirText(_dOrNull(cur['wind_direction_10m'])),
      precipitationMm: _dOrNull(cur['precipitation']),
      pressureHpa: _dOrNull(cur['surface_pressure']),
      timezone: '${map['timezone'] ?? ''}',
      updatedAt: DateTime.tryParse('${cur['time'] ?? ''}'),
    );
    final dates = daily['time'];
    final codes = daily['weather_code'];
    final maxs = daily['temperature_2m_max'];
    final mins = daily['temperature_2m_min'];
    final precs = daily['precipitation_sum'];
    final sunrises = daily['sunrise'];
    final sunsets = daily['sunset'];
    final out = <WeatherDay>[];
    if (dates is List) {
      for (var i = 0; i < dates.length; i++) {
        final d = DateTime.tryParse('${dates[i]}');
        if (d == null) continue;
        out.add(
          WeatherDay(
            date: d,
            code: _at(codes, i).round(),
            maxC: _at(maxs, i),
            minC: _at(mins, i),
            precipitationMm: _atOrNull(precs, i),
            sunrise: '${_atStr(sunrises, i)}',
            sunset: '${_atStr(sunsets, i)}',
          ),
        );
      }
    }
    // 逐小时：open-meteo 给的是**平行数组**（`time[]` + 每个字段一个数组）
    final hours = <WeatherHour>[];
    final hourly = _asMap(map['hourly']);
    final times = hourly['time'];
    if (times is List) {
      for (var i = 0; i < times.length; i++) {
        final at = DateTime.tryParse('${times[i]}');
        if (at == null) continue;
        hours.add(
          WeatherHour(
            time: at,
            code: _at(hourly['weather_code'], i).round(),
            temperatureC: _at(hourly['temperature_2m'], i),
            precipitationMm: _atOrNull(hourly['precipitation'], i),
            precipitationProbability: _atOrNull(
              hourly['precipitation_probability'],
              i,
            )?.round(),
          ),
        );
      }
    }
    return WeatherBundle(
      providerId: 'open-meteo',
      now: now,
      days: out,
      hours: hours,
      fetchedAt: DateTime.now(),
    );
  }

  // -------------------------------------------------------------------- NWS

  /// NWS 两步：`/points/{lat},{lon}` 拿到该点的网格 → 再取 `forecast`/`observations`。
  /// 温度单位是 `wmoUnit:degC`（已是公制），风速 `wmoUnit:km_h-1` ✔
  Future<WeatherBundle> _nws(double lat, double lon) async {
    final point = await _getJson(
      '${_base('nws', 'https://api.weather.gov')}/points/'
      '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}',
      const {},
    );
    final props = _asMap(point['properties']);
    final forecastUrl = '${props['forecast'] ?? ''}';
    if (forecastUrl.isEmpty) {
      throw WeatherException(
        dataText('wxErrNwsNoForecast', 'NWS 没返回预报地址（这个点可能不在覆盖范围内）'),
      );
    }
    final forecast = await _getJson(forecastUrl, const {});
    final periods = _asMap(forecast['properties'])['periods'];
    final days = <WeatherDay>[];
    final hours = <WeatherHour>[];
    final nowList = <WeatherNow>[];
    // 逐小时：NWS 是**另一个 URL**（`properties.forecastHourly`），多一次请求；
    // 拿不到不算致命（days 照样有）
    final hourlyUrl = '${props['forecastHourly'] ?? ''}';
    if (hourlyUrl.isNotEmpty) {
      try {
        final hourly = await _getJson(hourlyUrl, const {});
        final hPeriods = _asMap(hourly['properties'])['periods'];
        if (hPeriods is List) {
          for (final h in hPeriods) {
            final one = _asMap(h);
            final at = DateTime.tryParse('${one['startTime'] ?? ''}');
            if (at == null) continue;
            hours.add(
              WeatherHour(
                time: at,
                code: nwsTextToWmo('${one['shortForecast'] ?? ''}'),
                temperatureC:
                    _nwsTempOrNull(
                      one['temperature'],
                      unitHint: one['temperatureUnit'],
                    ) ??
                    0,
                precipitationProbability: _dOrNull(
                  _asMap(one['probabilityOfPrecipitation'])['value'],
                )?.round(),
                windKmh: _nwsWind(_asMap(one['windSpeed'])),
              ),
            );
          }
          hours.sort((a, b) => a.time.compareTo(b.time));
        }
      } catch (_) {
        // 逐小时拿不到就只给逐日（与观测站失败同一条策略）
      }
    }
    // 真正的"当前"要用最近观测站：forecast 的 periods 是白天/夜间预报，
    // 拿它当实时温度会差好几度（而且实测温度字段是**华氏**，见下）
    final stations = props['observationStations'];
    if (stations is String && stations.isNotEmpty) {
      try {
        final st = await _getJson(stations, const {});
        final features = st['features'];
        if (features is List && features.isNotEmpty) {
          final stationId = '${_asMap(features.first)['id'] ?? ''}';
          if (stationId.isNotEmpty) {
            final obs = await _getJson(
              '$stationId/observations/latest',
              const {},
            );
            final p2 = _asMap(obs['properties']);
            nowList.add(
              WeatherNow(
                providerId: 'nws',
                temperatureC: _nwsTemp(p2['temperature']),
                apparentC: _nwsTempOrNull(p2['apparentTemperature']),
                humidity: _dOrNull(
                  _asMap(p2['relativeHumidity'])['value'],
                )?.round(),
                // NWS 没有天气码：观测里有 `textDescription`，按关键词归一
                code: nwsTextToWmo('${p2['textDescription'] ?? ''}'),
                windKmh: _nwsWind(_asMap(p2['windSpeed'])),
                windDir:
                    '${p2['windDirection'] != null ? _dOrNull(_asMap(p2['windDirection'])['value']) ?? '' : ''}',
                pressureHpa:
                    _dOrNull(_asMap(p2['barometricPressure'])['value']) == null
                    ? null
                    : _dOrNull(_asMap(p2['barometricPressure'])['value'])! /
                          100,
                visibilityKm:
                    _dOrNull(_asMap(p2['visibility'])['value']) == null
                    ? null
                    : _dOrNull(_asMap(p2['visibility'])['value'])! / 1000,
                updatedAt: DateTime.tryParse('${p2['timestamp'] ?? ''}'),
              ),
            );
          }
        }
      } catch (_) {
        // 观测站拿不到不算致命：下面还有 periods 兜底
      }
    }
    if (periods is List) {
      // NWS 的 periods 是"白天/夜间"交替；按日期取当天的最高/最低
      final byDate = <String, ({double? min, double? max, int code})>{};
      for (final p in periods) {
        final one = _asMap(p);
        final start = DateTime.tryParse('${one['startTime'] ?? ''}');
        if (start == null) continue;
        final key = '${start.year}-${start.month}-${start.day}';
        final temp = _nwsTempOrNull(
          one['temperature'],
          unitHint: one['temperatureUnit'],
        );
        final isDay = '${one['isDaytime']}' == 'true';
        final prev = byDate[key];
        byDate[key] = (
          min: isDay ? prev?.min : _min(prev?.min, temp),
          max: isDay ? _max(prev?.max, temp) : prev?.max,
          code: prev?.code ?? 0,
        );
        if (nowList.isEmpty && isDay) {
          nowList.add(
            WeatherNow(
              providerId: 'nws',
              temperatureC: temp ?? 0,
              code: nwsTextToWmo('${one['shortForecast'] ?? ''}'),
              windKmh: _nwsWind(_asMap(one['windSpeed'])),
              windDir: '${one['windDirection'] ?? ''}',
            ),
          );
        }
      }
      for (final e in byDate.entries) {
        final parts = e.key.split('-');
        days.add(
          WeatherDay(
            date: DateTime(
              int.parse(parts[0]),
              int.parse(parts[1]),
              int.parse(parts[2]),
            ),
            code: e.value.code,
            minC: e.value.min ?? e.value.max ?? 0,
            maxC: e.value.max ?? e.value.min ?? 0,
          ),
        );
      }
      days.sort((a, b) => a.date.compareTo(b.date));
    }
    return WeatherBundle(
      providerId: 'nws',
      now: nowList.isEmpty ? null : nowList.first,
      days: days,
      hours: hours,
      fetchedAt: DateTime.now(),
    );
  }

  /// ⚠️ NWS 的温度**不是**公制：`temperature` 配 `temperatureUnit: "F"`（实测纽约
  /// 回 71，当成摄氏就是 71°C 的"热带纽约"）。这里按 unit 归一。
  double _nwsTemp(Object? field) => _nwsTempOrNull(field) ?? 0;

  /// NWS 有两种形状：观测里是 `{unitCode, value}`，forecast 的 period 里是
  /// **标量 + 旁边的 `temperatureUnit`**（实测 `71` + `"F"`）。两种都要认。
  static double? _nwsTempOrNull(Object? field, {Object? unitHint}) {
    if (field is num) {
      final unit = '$unitHint';
      return unit.contains('F') ? (field - 32) * 5 / 9 : field.toDouble();
    }
    final map = _asMap(field);
    final v = _dOrNull(map['value']);
    if (v == null) return null;
    final unit = '${map['unitCode'] ?? unitHint ?? ''}';
    if (unit.contains('degF')) return (v - 32) * 5 / 9;
    return v;
  }

  double? _nwsWind(Map<String, dynamic> wind) {
    // 形如 `{"unitCode":"wmoUnit:km_h-1","value":12.9}`
    final unit = '${wind['unitCode'] ?? ''}';
    final v = _dOrNull(wind['value']);
    if (v == null) return null;
    if (unit.contains('km_h')) return v;
    if (unit.contains('m_s')) return v * 3.6;
    if (unit.contains('mi_h')) return v * 1.609344;
    return v;
  }

  // ----------------------------------------------------------------- MET Norway

  Future<WeatherBundle> _metNo(double lat, double lon) async {
    final map = await _getJson(
      '${_base('met-no', 'https://api.met.no')}/weatherapi/'
      'locationforecast/2.0/compact',
      {'lat': lat, 'lon': lon},
    );
    final series = _asMap(map['properties'])['timeseries'];
    final days = <WeatherDay>[];
    final hours = <WeatherHour>[];
    WeatherNow? now;
    if (series is List && series.isNotEmpty) {
      final byDate = <String, ({double min, double max, int code})>{};
      // "当前"取**离现在最近**的那一条：原先只接受"不早于 2 小时前"的时间点，
      // 一旦桩/缓存的时刻偏旧就整个 now 为空（实测踩到，`now!` 直接崩）
      DateTime? nowRef;
      Map<String, dynamic>? nowDetails;
      Map<String, dynamic>? nowData;
      for (final entry in series) {
        final one = _asMap(entry);
        final at = DateTime.tryParse('${one['time'] ?? ''}');
        if (at == null) continue;
        final diff = at.difference(DateTime.now()).abs();
        if (nowRef == null || diff < nowRef.difference(DateTime.now()).abs()) {
          nowRef = at;
          nowDetails = _asMap(_asMap(one['data'])['instant']['details']);
          nowData = _asMap(one['data']);
          final symbol =
              '${_asMap(nowData['next_1_hours'])['summary']?['symbol_code'] ?? ''}';
          now = WeatherNow(
            providerId: 'met-no',
            temperatureC: _dOrNull(nowDetails['air_temperature']) ?? 0,
            code: metSymbolToWmo(symbol),
            humidity: _dOrNull(nowDetails['relative_humidity'])?.round(),
            windKmh: _dOrNull(nowDetails['wind_speed']) == null
                ? null
                : _dOrNull(nowDetails['wind_speed'])! * 3.6,
            windDir: windDirText(_dOrNull(nowDetails['wind_from_direction'])),
            pressureHpa: _dOrNull(nowDetails['air_pressure_at_sea_level']),
            updatedAt: at,
          );
        }
      }
      for (final entry in series) {
        final one = _asMap(entry);
        final at = DateTime.tryParse('${one['time'] ?? ''}');
        if (at == null) continue;
        final details = _asMap(_asMap(one['data'])['instant']['details']);
        final temp = _dOrNull(details['air_temperature']) ?? 0;
        final symbol =
            '${_asMap(_asMap(one['data'])['next_1_hours'])['summary']?['symbol_code'] ?? ''}';
        final code = metSymbolToWmo(symbol);
        final key = '${at.year}-${at.month}-${at.day}';
        final prev = byDate[key];
        byDate[key] = (
          min: prev == null ? temp : (temp < prev.min ? temp : prev.min),
          max: prev == null ? temp : (temp > prev.max ? temp : prev.max),
          code: prev?.code ?? code,
        );
      }
      for (final e in byDate.entries) {
        final parts = e.key.split('-');
        days.add(
          WeatherDay(
            date: DateTime(
              int.parse(parts[0]),
              int.parse(parts[1]),
              int.parse(parts[2]),
            ),
            code: e.value.code,
            minC: e.value.min,
            maxC: e.value.max,
          ),
        );
      }
      days.sort((a, b) => a.date.compareTo(b.date));
      // 逐小时：`timeseries[]` 本来就是 1 小时一格
      for (final entry in series) {
        final one = _asMap(entry);
        final at = DateTime.tryParse('${one['time'] ?? ''}');
        if (at == null) continue;
        final data = _asMap(one['data']);
        final details = _asMap(_asMap(data['instant'])['details']);
        final next1 = _asMap(data['next_1_hours']);
        hours.add(
          WeatherHour(
            time: at,
            code: metSymbolToWmo(
              '${_asMap(next1['summary'])['symbol_code'] ?? ''}',
            ),
            temperatureC: _dOrNull(details['air_temperature']) ?? 0,
            precipitationMm: _dOrNull(
              next1['details']?['precipitation_amount'],
            ),
            precipitationProbability: _dOrNull(
              next1['details']?['probability_of_precipitation'],
            )?.round(),
            windKmh: _dOrNull(details['wind_speed']) == null
                ? null
                : _dOrNull(details['wind_speed'])! * 3.6,
          ),
        );
      }
      hours.sort((a, b) => a.time.compareTo(b.time));
    }
    return WeatherBundle(
      providerId: 'met-no',
      now: now,
      days: days,
      hours: hours,
      fetchedAt: DateTime.now(),
    );
  }

  // ------------------------------------------------------------- QWeather

  Future<WeatherBundle> _qweather(
    double lat,
    double lon,
    String key,
    String language,
  ) async {
    if (key.isEmpty) {
      throw WeatherException(
        dataText('wxErrQweatherNoKey', '和风天气需要 API Key（在设置里填）'),
      );
    }
    final loc = '${lon.toStringAsFixed(2)},${lat.toStringAsFixed(2)}';
    // `unit=m` 明确公制；`lang=zh` 让天气现象回中文
    final common = {
      'location': loc,
      'key': key,
      'unit': 'm',
      'lang': language == 'zh' ? 'zh' : 'en',
    };
    final nowMap = await _getJson(
      '${_base('qweather', 'https://devapi.qweather.com')}/v7/weather/now',
      common,
    );
    final now = _asMap(nowMap['now']);
    final nowWeather = WeatherNow(
      providerId: 'qweather',
      temperatureC: _d(now['temp']),
      apparentC: _dOrNull(now['feelsLike']),
      humidity: _dOrNull(now['humidity'])?.round(),
      code: qweatherIconToWmo('${now['icon'] ?? ''}'),
      windKmh: _dOrNull(now['windSpeed']),
      windDir: '${now['windDir'] ?? ''}',
      precipitationMm: _dOrNull(now['precip']),
      pressureHpa: _dOrNull(now['pressure']),
      visibilityKm: _dOrNull(now['vis']),
      updatedAt: DateTime.tryParse('${nowMap['updateTime'] ?? ''}'),
    );
    final dailyMap = await _getJson(
      '${_base('qweather', 'https://devapi.qweather.com')}/v7/weather/7d',
      common,
    );
    final list = dailyMap['daily'];
    // 逐小时：和风的 `/v7/weather/24h`（**额外一次请求**，失败不影响逐日）
    final hours = <WeatherHour>[];
    try {
      final hourlyMap = await _getJson(
        '${_base('qweather', 'https://devapi.qweather.com')}/v7/weather/24h',
        common,
      );
      final hourly = hourlyMap['hourly'];
      if (hourly is List) {
        for (final one in hourly) {
          final h = _asMap(one);
          final at = DateTime.tryParse('${h['fxTime'] ?? ''}');
          if (at == null) continue;
          hours.add(
            WeatherHour(
              time: at,
              code: qweatherIconToWmo('${h['icon'] ?? ''}'),
              temperatureC: _d(h['temp']),
              precipitationMm: _dOrNull(h['precip']),
              precipitationProbability: _dOrNull(h['pop'])?.round(),
              windKmh: _dOrNull(h['windSpeed']),
            ),
          );
        }
      }
    } catch (_) {
      // 24h 拿不到就只给逐日
    }
    final days = <WeatherDay>[];
    if (list is List) {
      for (final one in list) {
        final d = _asMap(one);
        final date = DateTime.tryParse('${d['fxDate'] ?? ''}');
        if (date == null) continue;
        days.add(
          WeatherDay(
            date: date,
            code: qweatherIconToWmo('${d['iconDay'] ?? ''}'),
            minC: _d(d['tempMin']),
            maxC: _d(d['tempMax']),
            precipitationMm: _dOrNull(d['precip']),
            sunrise: '${d['sunrise'] ?? ''}',
            sunset: '${d['sunset'] ?? ''}',
          ),
        );
      }
    }
    return WeatherBundle(
      providerId: 'qweather',
      now: nowWeather,
      days: days,
      hours: hours,
      fetchedAt: DateTime.now(),
    );
  }

  // ------------------------------------------------------------------ wttr.in

  Future<WeatherBundle> _wttr(double lat, double lon, String language) async {
    final map = await _getJson(
      '${_base('wttr', 'https://wttr.in')}/'
      '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}',
      {'format': 'j1', 'lang': language == 'zh' ? 'zh' : 'en'},
    );
    // ⚠️ wttr 的 `current_condition` 与 `nearest_area` 都是**数组**（数组里一个对象），
    // 直接 `_asMap` 会拿到空表 → 实测"上海 晴 0.0°C、湿度 null"，全是 0
    final current = _firstMap(map['current_condition']);
    final nearest = _firstMap(map['nearest_area']);
    final now = WeatherNow(
      providerId: 'wttr',
      temperatureC: _d(current['temp_C']),
      apparentC: _dOrNull(current['FeelsLikeC']),
      humidity: _dOrNull(current['humidity'])?.round(),
      // wttr 给的是 `weatherCode`（WW 码），要归一
      code: wwToWmo('${current['weatherCode'] ?? ''}'),
      windKmh: _dOrNull(current['windspeedKmph']),
      windDir: '${current['winddir16Point'] ?? ''}',
      precipitationMm: _dOrNull(current['precipMM']),
      pressureHpa: _dOrNull(current['pressure']),
      visibilityKm: _dOrNull(current['visibility']),
      cityName: _wttrArea(nearest),
    );
    final days = <WeatherDay>[];
    final hours = <WeatherHour>[];
    final weather = map['weather'];
    if (weather is List) {
      for (final one in weather) {
        final d = _asMap(one);
        final date = DateTime.tryParse('${d['date'] ?? ''}');
        if (date == null) continue;
        final hourly = d['hourly'];
        var code = 0;
        var minC = double.infinity;
        var maxC = -double.infinity;
        if (hourly is List) {
          for (final h in hourly) {
            final hm = _asMap(h);
            code = code == 0 ? wwToWmo('${hm['weatherCode'] ?? ''}') : code;
            final t = _dOrNull(hm['tempC']);
            if (t != null) {
              if (t < minC) minC = t;
              if (t > maxC) maxC = t;
            }
            // ★ wttr 的逐小时是**3 小时一格**，`time` 是 `"0"`/`"300"`/`"600"`…（HHMM）
            final rawTime = '${hm['time'] ?? ''}'.padLeft(4, '0');
            final hh = int.tryParse(rawTime.substring(0, 2));
            final mm = int.tryParse(rawTime.substring(2, 4));
            if (hh != null && t != null) {
              hours.add(
                WeatherHour(
                  time: DateTime(date.year, date.month, date.day, hh, mm ?? 0),
                  code: wwToWmo('${hm['weatherCode'] ?? ''}'),
                  temperatureC: t,
                  precipitationMm: _dOrNull(hm['precipMM']),
                  precipitationProbability: _dOrNull(
                    hm['chanceofrain'],
                  )?.round(),
                  windKmh: _dOrNull(hm['windspeedKmph']),
                ),
              );
            }
          }
        }
        days.add(
          WeatherDay(
            date: date,
            code: code,
            minC: minC.isFinite ? minC : 0,
            maxC: maxC.isFinite ? maxC : 0,
            // wttr 的 `totalSnow_cm` 是降雪不是降水；没有逐日降水量就留空，
            // 别拿雪量冒充雨量
            sunrise: _wttrAstronomy(d, 'sunrise'),
            sunset: _wttrAstronomy(d, 'sunset'),
          ),
        );
      }
    }
    hours.sort((a, b) => a.time.compareTo(b.time));
    return WeatherBundle(
      providerId: 'wttr',
      now: now,
      days: days,
      hours: hours,
      fetchedAt: DateTime.now(),
    );
  }

  static Map<String, dynamic> _firstMap(Object? o) {
    if (o is List && o.isNotEmpty) return _asMap(o.first);
    return _asMap(o);
  }

  String _wttrArea(Map<String, dynamic> nearest) {
    final area = nearest['areaName'];
    if (area is List && area.isNotEmpty) {
      return '${_asMap(area.first)['value'] ?? ''}';
    }
    return '';
  }

  /// wttr 的 `astronomy` 是**长度为 1 的数组**，每项 `{sunrise:"06:01 AM", sunset:...}`
  String _wttrAstronomy(Map<String, dynamic> day, String key) {
    final astro = day['astronomy'];
    if (astro is List && astro.isNotEmpty) {
      return '${_asMap(astro.first)[key] ?? ''}';
    }
    return '';
  }

  // ------------------------------------------------------------------ 工具

  Future<Map<String, dynamic>> _getJson(
    String url,
    Map<String, Object?> query,
  ) async {
    Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        url,
        queryParameters: query.isEmpty ? null : query,
        options: Options(headers: _headers, responseType: ResponseType.plain),
      );
    } on DioException catch (e) {
      throw WeatherException(describeWeatherError(e, url));
    }
    final code = res.statusCode ?? 0;
    final raw = res.data;
    if (code < 200 || code >= 300) {
      throw WeatherException(
        raw is String && raw.length < 120
            ? dataText(
                'wxErrHttpStatusBody',
                '天气接口返回 {code}：{body}',
              ).replaceAll('{code}', '$code').replaceAll('{body}', raw)
            : dataText(
                'wxErrHttpStatus',
                '天气接口返回 {code}',
              ).replaceAll('{code}', '$code'),
      );
    }
    if (raw is Map) return raw.map((k, v) => MapEntry('$k', v));
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return decoded.map((k, v) => MapEntry('$k', v));
      } catch (_) {
        throw WeatherException(
          dataText('wxErrNotJson', '天气接口返回的不是 JSON（可能被网关拦了）'),
        );
      }
    }
    throw WeatherException(dataText('wxErrNoData', '天气接口没有返回数据'));
  }

  static Map<String, dynamic> _asMap(Object? o) {
    if (o is Map) return o.map((k, v) => MapEntry('$k', v));
    return const {};
  }

  static double _d(Object? o) => _dOrNull(o) ?? 0;

  static double? _dOrNull(Object? o) {
    if (o is num) return o.toDouble();
    if (o is String) return double.tryParse(o);
    return null;
  }

  static double _at(Object? list, int i) {
    if (list is List && i < list.length) return _d(list[i]);
    return 0;
  }

  static double? _atOrNull(Object? list, int i) {
    if (list is List && i < list.length) return _dOrNull(list[i]);
    return null;
  }

  static Object? _atStr(Object? list, int i) {
    if (list is List && i < list.length) return list[i];
    return '';
  }

  static double? _min(double? a, double? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a < b ? a : b;
  }

  static double? _max(double? a, double? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }
}

/// 网络错误 → 人话
///
/// 数据层拿不到 `BuildContext`，按 docs §4.6 走 `data_text.dart` 的 [dataText]；
/// 没装翻译器就回落中文原文。
String describeWeatherError(DioException e, String url) {
  final host = e.requestOptions.uri.host;
  return switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout => dataText(
      'wxErrConnectTimeout',
      '连接 {host} 超时（检查网络）',
    ).replaceAll('{host}', host),
    DioExceptionType.receiveTimeout => dataText(
      'wxErrSlowResponse',
      '{host} 响应太慢',
    ).replaceAll('{host}', host),
    DioExceptionType.connectionError => dataText(
      'wxErrNoConnection',
      '连不上 {host}（国内可能需要代理）',
    ).replaceAll('{host}', host),
    _ =>
      dataText('wxErrRequestFailed', '请求 {url} 失败：{error}')
          .replaceAll('{url}', url)
          .replaceAll('{error}', '${e.error ?? e.message ?? e.type.name}'),
  };
}

/// NWS 的 `textDescription` / `shortForecast` → WMO 码（它是文字，没有码）
int nwsTextToWmo(String text) {
  final t = text.toLowerCase();
  if (t.contains('thunder')) return 95;
  if (t.contains('snow') || t.contains('flurr')) {
    return t.contains('heavy') ? 75 : 71;
  }
  if (t.contains('freezing') || t.contains('sleet')) return 66;
  if (t.contains('shower')) return 80;
  if (t.contains('drizzle')) return 51;
  if (t.contains('heavy rain')) return 65;
  if (t.contains('rain')) return 61;
  if (t.contains('fog') || t.contains('mist')) return 45;
  if (t.contains('mostly cloudy') || t.contains('overcast')) return 3;
  if (t.contains('partly')) return 2;
  if (t.contains('mostly clear') || t.contains('mostly sunny')) return 1;
  if (t.contains('cloudy')) return 3;
  if (t.contains('clear') || t.contains('sunny')) return 0;
  return 0;
}

/// 风向角度 → 当前语言方位（16 向太多，用 8 向够看）
///
/// 数据层走 `data_text.dart`（docs §4.6）；没装翻译器回落中文原文。
String windDirText(double? degrees) {
  if (degrees == null) return '';
  const keys = [
    'wxWindN',
    'wxWindNe',
    'wxWindE',
    'wxWindSe',
    'wxWindS',
    'wxWindSw',
    'wxWindW',
    'wxWindNw',
  ];
  const names = ['北', '东北', '东', '东南', '南', '西南', '西', '西北'];
  final idx = (((degrees % 360) + 360) % 360 / 45).round() % 8;
  return dataText(
    'wxWindDir',
    '{dir}风',
  ).replaceAll('{dir}', dataText(keys[idx], names[idx]));
}

// --------------------------------------------------------------- 天气码归一

/// WMO 天气码 → emoji 图标（够直观，也不依赖图标字体）
String wmoIcon(int code) => switch (code) {
  0 => '☀️',
  1 => '🌤️',
  2 => '⛅',
  3 => '☁️',
  45 || 48 => '🌫️',
  51 || 53 || 55 => '🌦️',
  56 || 57 => '🌧️',
  61 => '🌦️',
  63 => '🌧️',
  65 => '🌧️',
  66 || 67 => '🌧️',
  71 || 73 || 75 || 77 => '🌨️',
  80 || 81 || 82 => '🌦️',
  85 || 86 => '🌨️',
  95 => '⛈️',
  96 || 99 => '⛈️',
  _ => '🌡️',
};

/// WMO 天气码 → 当前语言文案（Open-Meteo / met.no 直接给 WMO）
///
/// 数据层走 `data_text.dart`（docs §4.6）；没装翻译器回落中文原文。
String wmoText(int code) => switch (code) {
  0 => dataText('wxCodeClear', '晴'),
  1 => dataText('wxCodeMainlyClear', '少云'),
  2 => dataText('wxCodePartlyCloudy', '多云'),
  3 => dataText('wxCodeOvercast', '阴'),
  45 || 48 => dataText('wxCodeFog', '雾'),
  51 => dataText('wxCodeDrizzle', '毛毛雨'),
  53 => dataText('wxCodeLightRain', '小雨'),
  55 => dataText('wxCodeModerateRain', '中雨'),
  56 || 57 => dataText('wxCodeFreezingRain', '冻雨'),
  61 => dataText('wxCodeLightRain', '小雨'),
  63 => dataText('wxCodeModerateRain', '中雨'),
  65 => dataText('wxCodeHeavyRain', '大雨'),
  66 || 67 => dataText('wxCodeFreezingRain', '冻雨'),
  71 => dataText('wxCodeLightSnow', '小雪'),
  73 => dataText('wxCodeModerateSnow', '中雪'),
  75 => dataText('wxCodeHeavySnow', '大雪'),
  77 => dataText('wxCodeSnowGrains', '雪粒'),
  80 => dataText('wxCodeRainShowers', '阵雨'),
  81 => dataText('wxCodeModerateRainShowers', '中阵雨'),
  82 => dataText('wxCodeViolentRainShowers', '强阵雨'),
  85 || 86 => dataText('wxCodeSnowShowers', '阵雪'),
  95 => dataText('wxCodeThunderstorm', '雷阵雨'),
  96 || 99 => dataText('wxCodeThunderstormHail', '雷阵雨伴冰雹'),
  _ => dataText('wxCodeUnknown', '未知'),
};

/// met.no 的 `symbol_code`（clearsky_day / partlycloudy_night / rain…）→ WMO
int metSymbolToWmo(String symbol) {
  final s = symbol.toLowerCase();
  final night = s.endsWith('_night');
  if (s.startsWith('clearsky')) return night ? 0 : 0;
  if (s.startsWith('fair')) return 1;
  if (s.startsWith('partlycloudy')) return 2;
  if (s.startsWith('cloudy')) return 3;
  if (s.startsWith('fog')) return 45;
  if (s.contains('thunder')) return 95;
  if (s.contains('sleet')) return 66;
  if (s.contains('snow')) return s.contains('heavy') ? 75 : 71;
  if (s.contains('heavyrain')) return 65;
  if (s.contains('rainshowers')) return 80;
  if (s.contains('rain')) return s.contains('light') ? 61 : 63;
  if (s.contains('drizzle')) return 51;
  return 0;
}

/// wttr.in 的 WW 码（113/116/…/395）→ WMO 近似
int wwToWmo(String ww) {
  final n = int.tryParse(ww);
  return switch (n) {
    113 => 0,
    116 => 2,
    119 || 122 => 3,
    143 || 248 || 260 => 45,
    176 || 263 || 266 || 293 || 296 => 61,
    299 || 302 || 305 || 308 => 63,
    353 || 356 || 359 => 65,
    200 || 386 || 389 || 392 || 395 => 95,
    179 ||
    182 ||
    185 ||
    281 ||
    284 ||
    311 ||
    314 ||
    317 ||
    320 ||
    362 ||
    365 ||
    374 ||
    377 => 66,
    227 || 230 || 323 || 326 || 329 || 332 || 335 || 338 || 368 || 371 => 71,
    // 注意：227/179/392 等已经被上面的分支覆盖，重复列出来 Dart 会报
    // "covered by the previous cases"（分析器不骗人，删掉才是对的）
    _ => 0,
  };
}

/// 和风 icon 码（100 晴 / 101 多云 / 104 阴 / 3xx 雨 / 4xx 雪 / 5xx 雾霾…）→ WMO
int qweatherIconToWmo(String icon) {
  final n = int.tryParse(icon);
  if (n == null) return 0;
  if (n == 100 || n == 150) return 0;
  if (n == 101 || n == 102 || n == 103) return 2;
  if (n == 104) return 3;
  if (n >= 300 && n < 400) {
    if (n == 300 || n == 350) return 80;
    if (n >= 302 && n <= 304) return 95;
    if (n == 305 ||
        n == 306 ||
        n == 307 ||
        n == 308 ||
        n == 309 ||
        n == 310 ||
        n == 311 ||
        n == 312 ||
        n == 313 ||
        n == 314 ||
        n == 315 ||
        n == 316 ||
        n == 317 ||
        n == 318 ||
        n == 399) {
      return n == 305 || n == 306 || n == 307 || n == 308 ? 63 : 65;
    }
    return 61;
  }
  if (n >= 400 && n < 500) {
    if (n == 400 ||
        n == 401 ||
        n == 402 ||
        n == 403 ||
        n == 404 ||
        n == 405 ||
        n == 406 ||
        n == 407 ||
        n == 408 ||
        n == 409 ||
        n == 410 ||
        n == 456 ||
        n == 457) {
      return n == 400 || n == 401 ? 71 : 73;
    }
    return 75;
  }
  if (n == 500 || n == 501 || n == 509 || n == 510 || n == 514 || n == 515) {
    return 45;
  }
  if (n == 502 || n == 511 || n == 512 || n == 513) return 3;
  if (n >= 503 && n <= 508) return 61;
  return 0;
}
