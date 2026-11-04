// 地区上下文：**天气与节假日共用的那一份"这是哪儿"**。
//
// 为什么要有这层：用户要求"根据国家和地区自动选供应商与单位"，而单位习惯是
// **按国家/地区**不同的（美国 °F/mph/inch、英国 °C + mph 的混合制、中国习惯说
// "几级风"…）。如果散在各处各判一次，早晚会出现"温度华氏、风速公里"这种混搭。
// 所以：**先解析出一个 [RegionContext]，再由它派生出单位制与供应商优先级。**
import 'package:flutter/foundation.dart';

import '../../core/i18n/data_text.dart';

/// 单位制（英制国家里英国是**混合制**：温度摄氏、风速英里、降水毫米）
enum UnitSystem {
  metric('metric', '公制'),
  imperial('imperial', '英制'),
  uk('uk', '英制（英国）'),
  auto('auto', '跟随地区');

  const UnitSystem(this.id, this.label);

  final String id;

  /// 中文回落（界面侧读 [labelText]；`lib/src/features/**` 本轮不在迁移范围内）
  final String label;

  /// ARB key（多语言用；数据层不能碰 `AppText`）
  String get labelKey => switch (this) {
    UnitSystem.metric => 'regionUnitMetric',
    UnitSystem.imperial => 'regionUnitImperial',
    UnitSystem.uk => 'regionUnitUk',
    UnitSystem.auto => 'regionUnitAuto',
  };

  /// 当前语言文案（走 `data_text.dart` 的 [dataText]；没装翻译器时回落 [label]）
  String labelText() => dataText(labelKey, label);

  static UnitSystem fromId(String? id) => switch (id) {
    'metric' => UnitSystem.metric,
    'imperial' => UnitSystem.imperial,
    'uk' => UnitSystem.uk,
    _ => UnitSystem.auto,
  };
}

/// 风速单位：中国/港台说"几级"、日韩俄说 m/s、英美说 mph、其余 km/h
enum WindUnit {
  beaufort('beaufort', '级'),
  ms('ms', 'm/s'),
  kmh('kmh', 'km/h'),
  mph('mph', 'mph');

  const WindUnit(this.id, this.label);

  final String id;

  /// 中文回落（`m/s`/`km/h`/`mph` 是单位符号，两语言一样，只有"级"要翻）
  final String label;

  /// ARB key；单位符号没有语言差异，认不出就返回 null（原样显示 [label]）
  String? get labelKey => switch (this) {
    WindUnit.beaufort => 'regionWindForce',
    WindUnit.ms || WindUnit.kmh || WindUnit.mph => null,
  };

  /// 当前语言文案（走 `data_text.dart` 的 [dataText]；没装翻译器时回落 [label]）
  String labelText() {
    final k = labelKey;
    return k == null ? label : dataText(k, label);
  }
}

/// 一套"显示用"单位（内部一律存公制，只在出口换算）
@immutable
class WeatherUnits {
  const WeatherUnits({
    required this.temperature,
    required this.wind,
    required this.precipitation,
    required this.pressure,
    required this.visibility,
  });

  /// 'C' 或 'F'
  final String temperature;
  final WindUnit wind;

  /// 'mm' 或 'in'
  final String precipitation;

  /// 'hpa' 或 'inhg'
  final String pressure;

  /// 'km' 或 'mi'
  final String visibility;

  String get temperatureLabel => temperature == 'F' ? '°F' : '°C';

  String get precipitationLabel => precipitation == 'in' ? 'in' : 'mm';

  String get pressureLabel => pressure == 'inhg' ? 'inHg' : 'hPa';

  String get visibilityLabel => visibility == 'mi' ? 'mi' : 'km';

  /// 摄氏度 → 显示值（保留一位小数的地方交给调用方）
  double convertTemp(double celsius) =>
      temperature == 'F' ? celsius * 9 / 5 + 32 : celsius;

  double convertPrecip(double mm) => precipitation == 'in' ? mm / 25.4 : mm;

  double convertPressure(double hpa) =>
      pressure == 'inhg' ? hpa * 0.0295299830714 : hpa;

  double convertVisibility(double km) =>
      visibility == 'mi' ? km / 1.609344 : km;

  /// 公制风速（km/h）→ 显示单位的值
  double convertWind(double kmh) => switch (wind) {
    WindUnit.kmh => kmh,
    WindUnit.mph => kmh / 1.609344,
    WindUnit.ms => kmh / 3.6,
    // 蒲福风级：用标准区间（0 级 <1km/h 起算），取落点的级数
    WindUnit.beaufort => beaufortOf(kmh).toDouble(),
  };

  /// 风级 → 当前语言文案（"3 级（微风）"）
  ///
  /// 数据层拿不到 `BuildContext`，按 docs §4.6 走 `data_text.dart` 的 [dataText]；
  /// 没装翻译器就回落中文原文。
  String windText(double kmh) {
    if (wind != WindUnit.beaufort) {
      return '${convertWind(kmh).toStringAsFixed(1)} ${wind.labelText()}';
    }
    final b = beaufortOf(kmh);
    return dataText('regionWindText', '{level} 级（{name}）')
        .replaceAll('{level}', '$b')
        .replaceAll('{name}', b < kBeaufortNames.length ? beaufortName(b) : '');
  }

  Map<String, Object?> toJson() => {
    'temperature': temperature,
    'wind': wind.id,
    'precipitation': precipitation,
    'pressure': pressure,
    'visibility': visibility,
  };

  static WeatherUnits fromJson(Map<String, Object?> json) => WeatherUnits(
    temperature: '${json['temperature'] ?? 'C'}',
    wind: WindUnit.values.firstWhere(
      (w) => w.id == json['wind'],
      orElse: () => WindUnit.kmh,
    ),
    precipitation: '${json['precipitation'] ?? 'mm'}',
    pressure: '${json['pressure'] ?? 'hpa'}',
    visibility: '${json['visibility'] ?? 'km'}',
  );
}

/// 蒲福风级表（按 km/h 上界）
const List<double> kBeaufortUpperKmh = [
  1,
  5,
  11,
  19,
  28,
  38,
  49,
  61,
  74,
  88,
  102,
  117,
  134,
  149,
  166,
  183,
  201,
  220,
];

/// 蒲福风级名（**中文回落**：无 context 的地方与老测试还用得上）。
///
/// 界面/出口一律走 [beaufortName]（按当前语言取）；没装翻译器时它返回这里的原文。
const List<String> kBeaufortNames = [
  '无风',
  '软风',
  '轻风',
  '微风',
  '和风',
  '清风',
  '强风',
  '疾风',
  '大风',
  '烈风',
  '狂风',
  '暴风',
  '飓风',
  '飓风',
  '飓风',
  '飓风',
  '飓风',
  '飓风',
];

/// 蒲福风级 → ARB key（12 级及以上官方都叫"飓风"，共用一个 key）
String beaufortKey(int b) => 'regionBeaufort${b <= 12 ? b : 12}';

/// 蒲福风级名（当前语言；越界返回空串，与老口径一致）
String beaufortName(int b) {
  if (b < 0 || b >= kBeaufortNames.length) return '';
  return dataText(beaufortKey(b), kBeaufortNames[b]);
}

int beaufortOf(double kmh) {
  for (var i = 0; i < kBeaufortUpperKmh.length; i++) {
    if (kmh < kBeaufortUpperKmh[i]) return i;
  }
  return kBeaufortUpperKmh.length;
}

/// 英制（温度 °F + mph + inch + inHg + mile）国家/地区。
/// 依据是"日常公共气象表述用英制"，不是"是否用英制长度"（英国道路用英里但
/// 气温用摄氏度，所以单列 [kUkMixedCountries]）。
const Set<String> kImperialCountries = {
  'US', // 美国
  'BS', // 巴哈马
  'BZ', // 伯利兹
  'KY', // 开曼
  'PW', // 帕劳
  'FM', // 密克罗尼西亚
  'MH', // 马绍尔群岛
  'LR', // 利比里亚
  'MM', // 缅甸
};

/// 英国式混合：温度 °C、风速 mph、降水 mm、能见度 mile
const Set<String> kUkMixedCountries = {'GB'};

/// 风速按蒲福风级说的国家/地区（中文语境常见）
const Set<String> kBeaufortCountries = {'CN', 'TW', 'HK', 'MO', 'SG'};

/// 风速按 m/s（日韩俄等）
const Set<String> kMsCountries = {'JP', 'KR', 'KP', 'RU', 'BY', 'KZ', 'MN'};

/// 按国家/地区给出单位制（auto 时用）
UnitSystem unitSystemFor(String countryCode) {
  final cc = countryCode.toUpperCase();
  if (cc.isEmpty) return UnitSystem.metric;
  if (kImperialCountries.contains(cc)) return UnitSystem.imperial;
  if (kUkMixedCountries.contains(cc)) return UnitSystem.uk;
  return UnitSystem.metric;
}

/// 由国家/地区 + 用户覆盖，得到最终单位
WeatherUnits weatherUnitsFor(String countryCode, {UnitSystem? override}) {
  final cc = countryCode.toUpperCase();
  final system = (override == null || override == UnitSystem.auto)
      ? unitSystemFor(cc)
      : override;
  final wind = switch (system) {
    UnitSystem.imperial => WindUnit.mph,
    UnitSystem.uk => WindUnit.mph,
    _ =>
      kBeaufortCountries.contains(cc)
          ? WindUnit.beaufort
          : (kMsCountries.contains(cc) ? WindUnit.ms : WindUnit.kmh),
  };
  return switch (system) {
    UnitSystem.imperial => WeatherUnits(
      temperature: 'F',
      wind: wind,
      precipitation: 'in',
      pressure: 'inhg',
      visibility: 'mi',
    ),
    UnitSystem.uk => WeatherUnits(
      temperature: 'C',
      wind: wind,
      precipitation: 'mm',
      pressure: 'hpa',
      visibility: 'mi',
    ),
    _ => WeatherUnits(
      temperature: 'C',
      wind: wind,
      precipitation: 'mm',
      pressure: 'hpa',
      visibility: 'km',
    ),
  };
}

/// 地区从哪儿来的（决定"能不能信"以及 UI 上要不要提示）
enum RegionSource {
  none('none', '未确定'),
  manual('manual', '手动指定'),
  deviceLocation('deviceLocation', '手机定位'),
  eventGps('eventGps', '日程地点（GPS）'),
  eventAddress('eventAddress', '日程地点（文字）'),
  calendarTimezone('calendarTimezone', '日历时区'),
  deviceLocale('deviceLocale', '设备地区');

  const RegionSource(this.id, this.label);

  final String id;

  /// 中文回落（界面侧读 [labelText]；`lib/src/features/**` 本轮不在迁移范围内）
  final String label;

  /// ARB key（多语言用；数据层不能碰 `AppText`）
  String get labelKey => switch (this) {
    RegionSource.none => 'regionUnknown',
    RegionSource.manual => 'regionSourceManual',
    RegionSource.deviceLocation => 'regionSourceDeviceLocation',
    RegionSource.eventGps => 'regionSourceEventGps',
    RegionSource.eventAddress => 'regionSourceEventAddress',
    RegionSource.calendarTimezone => 'regionSourceCalendarTimezone',
    RegionSource.deviceLocale => 'regionSourceDeviceLocale',
  };

  /// 当前语言文案（走 `data_text.dart` 的 [dataText]；没装翻译器时回落 [label]）
  String labelText() => dataText(labelKey, label);
}

/// 解析出来的"这是哪儿"
@immutable
class RegionContext {
  const RegionContext({
    this.countryCode = '',
    this.subdivisionCode = '',
    this.city = '',
    this.timezone = '',
    this.latitude,
    this.longitude,
    this.source = RegionSource.none,
  });

  /// ISO 3166-1 alpha-2（大写）
  final String countryCode;

  /// ISO 3166-2（例如 `US-CA`、`DE-BY`），有就用（节假日按州不同）
  final String subdivisionCode;
  final String city;
  final String timezone;
  final double? latitude;
  final double? longitude;
  final RegionSource source;

  bool get isKnown => countryCode.isNotEmpty;

  /// UI 上一句话说明"这是哪儿、怎么来的"
  ///
  /// 数据层走 `data_text.dart`（docs §4.6）；没装翻译器回落中文原文。
  String get label {
    final parts = <String>[
      if (city.isNotEmpty) city,
      if (countryCode.isNotEmpty) countryCode,
    ];
    final where = parts.isEmpty
        ? dataText('regionUnknown', '未确定')
        : parts.join(' · ');
    return dataText(
      'regionLabel',
      '{where}（{source}）',
    ).replaceAll('{where}', where).replaceAll('{source}', source.labelText());
  }

  RegionContext copyWith({
    String? countryCode,
    String? subdivisionCode,
    String? city,
    String? timezone,
    double? latitude,
    double? longitude,
    RegionSource? source,
  }) => RegionContext(
    countryCode: countryCode ?? this.countryCode,
    subdivisionCode: subdivisionCode ?? this.subdivisionCode,
    city: city ?? this.city,
    timezone: timezone ?? this.timezone,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    source: source ?? this.source,
  );

  Map<String, Object?> toJson() => {
    'countryCode': countryCode,
    'subdivisionCode': subdivisionCode,
    'city': city,
    'timezone': timezone,
    'latitude': latitude,
    'longitude': longitude,
    'source': source.id,
  };

  static RegionContext fromJson(Map<String, Object?> json) => RegionContext(
    countryCode: '${json['countryCode'] ?? ''}',
    subdivisionCode: '${json['subdivisionCode'] ?? ''}',
    city: '${json['city'] ?? ''}',
    timezone: '${json['timezone'] ?? ''}',
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
    source: RegionSource.values.firstWhere(
      (s) => s.id == json['source'],
      orElse: () => RegionSource.none,
    ),
  );
}

/// IANA 时区 → 国家/地区 的兜底表。
///
/// 为什么不查库：时区到国家的完整映射有上千条且会变，我们只需要"常见的那批"
/// 作为**最后的兜底**（前面还有手动指定 / GPS 反查 / 地点文字正查）。命中不了的
/// 就老实返回空串，让 UI 显示"未确定"，绝不瞎猜。
const Map<String, String> kTimezoneCountries = {
  'Asia/Shanghai': 'CN',
  'Asia/Chongqing': 'CN',
  'Asia/Harbin': 'CN',
  'Asia/Urumqi': 'CN',
  'Asia/Hong_Kong': 'HK',
  'Asia/Macau': 'MO',
  'Asia/Taipei': 'TW',
  'Asia/Tokyo': 'JP',
  'Asia/Seoul': 'KR',
  'Asia/Pyongyang': 'KP',
  'Asia/Singapore': 'SG',
  'Asia/Kuala_Lumpur': 'MY',
  'Asia/Bangkok': 'TH',
  'Asia/Ho_Chi_Minh': 'VN',
  'Asia/Saigon': 'VN',
  'Asia/Jakarta': 'ID',
  'Asia/Manila': 'PH',
  'Asia/Kolkata': 'IN',
  'Asia/Calcutta': 'IN',
  'Asia/Dubai': 'AE',
  'Asia/Riyadh': 'SA',
  'Asia/Jerusalem': 'IL',
  'Asia/Istanbul': 'TR',
  'Europe/Istanbul': 'TR',
  'Europe/London': 'GB',
  'Europe/Dublin': 'IE',
  'Europe/Paris': 'FR',
  'Europe/Berlin': 'DE',
  'Europe/Madrid': 'ES',
  'Europe/Rome': 'IT',
  'Europe/Amsterdam': 'NL',
  'Europe/Brussels': 'BE',
  'Europe/Vienna': 'AT',
  'Europe/Zurich': 'CH',
  'Europe/Stockholm': 'SE',
  'Europe/Oslo': 'NO',
  'Europe/Copenhagen': 'DK',
  'Europe/Helsinki': 'FI',
  'Europe/Warsaw': 'PL',
  'Europe/Prague': 'CZ',
  'Europe/Budapest': 'HU',
  'Europe/Lisbon': 'PT',
  'Europe/Athens': 'GR',
  'Europe/Moscow': 'RU',
  'Europe/Kiev': 'UA',
  'Europe/Kyiv': 'UA',
  'America/New_York': 'US',
  'America/Chicago': 'US',
  'America/Denver': 'US',
  'America/Los_Angeles': 'US',
  'America/Phoenix': 'US',
  'America/Anchorage': 'US',
  'Pacific/Honolulu': 'US',
  'America/Toronto': 'CA',
  'America/Vancouver': 'CA',
  'America/Edmonton': 'CA',
  'America/Winnipeg': 'CA',
  'America/Halifax': 'CA',
  'America/Mexico_City': 'MX',
  'America/Sao_Paulo': 'BR',
  'America/Argentina/Buenos_Aires': 'AR',
  'America/Santiago': 'CL',
  'America/Bogota': 'CO',
  'America/Lima': 'PE',
  'Africa/Cairo': 'EG',
  'Africa/Johannesburg': 'ZA',
  'Africa/Lagos': 'NG',
  'Africa/Nairobi': 'KE',
  'Australia/Sydney': 'AU',
  'Australia/Melbourne': 'AU',
  'Australia/Brisbane': 'AU',
  'Australia/Perth': 'AU',
  'Australia/Adelaide': 'AU',
  'Pacific/Auckland': 'NZ',
};

String countryFromTimezone(String timezone) {
  if (timezone.isEmpty) return '';
  final direct = kTimezoneCountries[timezone];
  if (direct != null) return direct;
  // `Asia/Shanghai` 之外还可能是 `Etc/GMT-8` 之类：按前缀做一次粗匹配
  final slash = timezone.indexOf('/');
  if (slash > 0) {
    final region = timezone.substring(0, slash);
    final city = timezone.substring(slash + 1);
    for (final e in kTimezoneCountries.entries) {
      if (e.key.startsWith('$region/') && e.key.endsWith('/$city')) {
        return e.value;
      }
    }
  }
  return '';
}

/// 国家/地区的中文名（**中文回落**：只列我们可能遇到的；查不到就显示代码）
///
/// 界面/出口一律走 [countryName]（按当前语言取，ARB key `regionCountry<代码>`）。
const Map<String, String> kCountryNames = {
  'CN': '中国',
  'HK': '中国香港',
  'MO': '中国澳门',
  'TW': '中国台湾',
  'JP': '日本',
  'KR': '韩国',
  'KP': '朝鲜',
  'SG': '新加坡',
  'MY': '马来西亚',
  'TH': '泰国',
  'VN': '越南',
  'ID': '印度尼西亚',
  'PH': '菲律宾',
  'IN': '印度',
  'AE': '阿联酋',
  'SA': '沙特阿拉伯',
  'IL': '以色列',
  'TR': '土耳其',
  'GB': '英国',
  'IE': '爱尔兰',
  'FR': '法国',
  'DE': '德国',
  'ES': '西班牙',
  'IT': '意大利',
  'NL': '荷兰',
  'BE': '比利时',
  'AT': '奥地利',
  'CH': '瑞士',
  'SE': '瑞典',
  'NO': '挪威',
  'DK': '丹麦',
  'FI': '芬兰',
  'PL': '波兰',
  'CZ': '捷克',
  'HU': '匈牙利',
  'PT': '葡萄牙',
  'GR': '希腊',
  'RU': '俄罗斯',
  'UA': '乌克兰',
  'US': '美国',
  'CA': '加拿大',
  'MX': '墨西哥',
  'BR': '巴西',
  'AR': '阿根廷',
  'CL': '智利',
  'CO': '哥伦比亚',
  'PE': '秘鲁',
  'EG': '埃及',
  'ZA': '南非',
  'NG': '尼日利亚',
  'KE': '肯尼亚',
  'AU': '澳大利亚',
  'NZ': '新西兰',
};

/// 国家/地区代码 → 当前语言的名字；认不出的代码原样返回（转大写）。
///
/// 数据层走 `data_text.dart`（docs §4.6）；没装翻译器回落 [kCountryNames] 的中文原文。
String countryName(String code) {
  if (code.isEmpty) return dataText('regionUnknown', '未确定');
  final cc = code.toUpperCase();
  final zh = kCountryNames[cc];
  if (zh == null) return cc;
  return dataText('regionCountry$cc', zh);
}

/// 常见国家/地区选项（设置里让用户手动选，覆盖自动判定）
const List<String> kRegionPickerCountries = [
  'CN',
  'HK',
  'MO',
  'TW',
  'SG',
  'MY',
  'JP',
  'KR',
  'TH',
  'VN',
  'PH',
  'ID',
  'IN',
  'AE',
  'SA',
  'IL',
  'TR',
  'GB',
  'IE',
  'FR',
  'DE',
  'ES',
  'IT',
  'NL',
  'CH',
  'SE',
  'NO',
  'DK',
  'FI',
  'PL',
  'RU',
  'UA',
  'US',
  'CA',
  'MX',
  'BR',
  'AR',
  'AU',
  'NZ',
  'ZA',
  'EG',
];
