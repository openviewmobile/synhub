// 日历的"环境信息"：**地区 → 单位 → 天气源 → 节假日源** 的 provider 层。
//
// 设计要点（用户要求"按国家和地区自动选供应商与单位"）：
//   1. **一份地区上下文**（[RegionContext]）供天气与节假日共用，避免各自判一次；
//   2. 地区来源有优先级：**用户手选 > 日程地点（GPS/文字）> 日历时区 > 设备地区**；
//      手选优先是为了"我人在中国但关心德国假期"这种真实需求；
//   3. 单位**永远派生于地区**（[weatherUnitsFor]），用户可整体覆盖成公制/英制；
//   4. 天气与节假日**各自独立降级**：天气挂了不影响节假日，反之亦然；
//   5. 和风的 key 走**系统安全存储**（复用 [CloudKeyStore]），不进普通偏好表。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../core/settings/app_settings.dart' show settingsServiceProvider;
import '../../core/settings/cloud_key_store.dart';
import '../../data/holidays/holiday_service.dart';
import '../../data/region/geocode_client.dart';
import '../../data/region/device_location.dart';
import '../../data/region/region_context.dart';
import '../../data/weather/weather_client.dart';
import 'calendar_providers.dart';

/// 和风 key 在安全存储里的槽位名（和云端大模型的 key 分开存，便于单独清除）
const String kQweatherKeySlot = 'weather_qweather';

/// 用户可调的环境设置
@immutable
class CalendarEnvSettings {
  const CalendarEnvSettings({
    this.countryOverride = '',
    this.unitsOverrideId = 'auto',
    this.forcedWeatherProviderId = '',
    this.qweatherKey = '',
    this.manualPlaceName = '',
    this.manualLatitude,
    this.manualLongitude,
    this.autoLocate = true,
    this.weatherBackground = true,
  });

  /// 手动指定的国家/地区（空 = 自动判定）
  final String countryOverride;

  /// 手动指定的**地点**（空 = 从日程地点/时区推）。
  ///
  /// ⚠️ 为什么必须有这个：天气要的是**坐标**，而坐标原先只能从"带地点的日程"
  /// 里拿 —— 没有地点日程的日子，卡片只能写"还没有地点信息"，用户也就永远看不到
  /// 天气。用户明确要求"天气要做"，所以开一个手选地点（搜索城市 → 存坐标）。
  final String manualPlaceName;
  final double? manualLatitude;
  final double? manualLongitude;

  bool get hasManualPlace => manualLatitude != null && manualLongitude != null;

  /// **跟随手机定位**（默认开）。
  ///
  /// 用户反馈"切换日期天气不变、地点还是老的手动指定"：手动地点是一次性设置，
  /// 出差/换城市后不会自己更新。所以默认走系统定位（城市级就够），
  /// 用户一旦手选城市/国家就自动关掉它（显式选择优先）。
  final bool autoLocate;

  /// 日历页的**天气动画背景**（虚化那层）。默认开；嫌晃眼/费电可以关。
  final bool weatherBackground;

  /// 单位制覆盖（auto = 跟随地区）
  final String unitsOverrideId;

  /// 强制指定天气源（空 = 按地区自动选）
  final String forcedWeatherProviderId;

  /// 和风 key（**只在内存里**，持久化走安全存储）
  final String qweatherKey;

  UnitSystem get unitsOverride => UnitSystem.fromId(unitsOverrideId);

  bool get hasQweatherKey => qweatherKey.trim().isNotEmpty;

  CalendarEnvSettings copyWith({
    String? countryOverride,
    String? unitsOverrideId,
    String? forcedWeatherProviderId,
    String? qweatherKey,
    String? manualPlaceName,
    double? manualLatitude,
    double? manualLongitude,
    bool clearManualPlace = false,
    bool? autoLocate,
    bool? weatherBackground,
  }) => CalendarEnvSettings(
    countryOverride: countryOverride ?? this.countryOverride,
    unitsOverrideId: unitsOverrideId ?? this.unitsOverrideId,
    forcedWeatherProviderId:
        forcedWeatherProviderId ?? this.forcedWeatherProviderId,
    qweatherKey: qweatherKey ?? this.qweatherKey,
    manualPlaceName: clearManualPlace
        ? ''
        : (manualPlaceName ?? this.manualPlaceName),
    manualLatitude: clearManualPlace
        ? null
        : (manualLatitude ?? this.manualLatitude),
    manualLongitude: clearManualPlace
        ? null
        : (manualLongitude ?? this.manualLongitude),
    autoLocate: autoLocate ?? this.autoLocate,
    weatherBackground: weatherBackground ?? this.weatherBackground,
  );

  Map<String, Object?> toJson() => {
    if (countryOverride.isNotEmpty) 'countryOverride': countryOverride,
    'unitsOverrideId': unitsOverrideId,
    if (forcedWeatherProviderId.isNotEmpty)
      'forcedWeatherProviderId': forcedWeatherProviderId,
    if (manualPlaceName.isNotEmpty) 'manualPlaceName': manualPlaceName,
    if (manualLatitude != null) 'manualLatitude': manualLatitude,
    if (manualLongitude != null) 'manualLongitude': manualLongitude,
    // 只有"关掉"才落盘：默认开着，不写盘也让老配置升级后能用定位
    if (!autoLocate) 'autoLocate': false,
    if (!weatherBackground) 'weatherBackground': false,
  };

  static CalendarEnvSettings fromJson(Map<String, Object?> json) {
    double? num_(Object? v) => v is num
        ? v.toDouble()
        : (v is String && v.isNotEmpty ? double.tryParse(v) : null);
    return CalendarEnvSettings(
      countryOverride: '${json['countryOverride'] ?? ''}',
      unitsOverrideId: '${json['unitsOverrideId'] ?? 'auto'}',
      forcedWeatherProviderId: '${json['forcedWeatherProviderId'] ?? ''}',
      manualPlaceName: '${json['manualPlaceName'] ?? ''}',
      manualLatitude: num_(json['manualLatitude']),
      manualLongitude: num_(json['manualLongitude']),
      autoLocate: json['autoLocate'] != false,
      weatherBackground: json['weatherBackground'] != false,
    );
  }
}

/// 环境设置的状态（含加载/保存 key）
class CalendarEnvNotifier extends Notifier<CalendarEnvSettings> {
  @override
  CalendarEnvSettings build() => const CalendarEnvSettings();

  /// 从设置表 + 安全存储读回（页面 initState 里调一次）
  Future<void> preload() async {
    final raw = await ref.read(settingsServiceProvider).calendarEnvRaw();
    var next = const CalendarEnvSettings();
    if (raw != null && raw.isNotEmpty) {
      try {
        next = CalendarEnvSettings.fromJson(
          (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', v)),
        );
      } catch (_) {
        // 存坏了就当没有，不要因此打不开日历
      }
    }
    try {
      final key = await ref.read(cloudKeyStoreProvider).read(kQweatherKeySlot);
      next = next.copyWith(qweatherKey: key ?? '');
    } catch (_) {
      // 安全存储不可用（老系统/模拟器）不该让设置页崩
    }
    if (ref.mounted) state = next;
  }

  Future<void> _persist(CalendarEnvSettings next) async {
    state = next;
    await ref
        .read(settingsServiceProvider)
        .setCalendarEnvRaw(jsonEncode(next.toJson()));
  }

  Future<void> setCountryOverride(String code) =>
      _persist(state.copyWith(countryOverride: code.toUpperCase()));

  Future<void> setUnitsOverride(String id) =>
      _persist(state.copyWith(unitsOverrideId: id));

  Future<void> setForcedWeatherProvider(String id) =>
      _persist(state.copyWith(forcedWeatherProviderId: id));

  /// 天气动画背景开关
  Future<void> setWeatherBackground(bool on) =>
      _persist(state.copyWith(weatherBackground: on));

  /// 跟随手机定位的开关（关掉 = 用回手动地点/时区推算）
  Future<void> setAutoLocate(bool on) async {
    if (on) {
      // 打开就重新定位一次：用户按它通常是"我现在不在原来那个地方了"
      await ref.read(deviceLocationProbeProvider).clearCache();
      ref.invalidate(deviceLocationProvider);
    }
    await _persist(state.copyWith(autoLocate: on));
  }

  /// 手选地点（城市搜索结果里的坐标）
  ///
  /// `countryCode` 一并写进 `countryOverride`：选了"东京"就该按日本算单位与节假日，
  /// 否则国家留空会退回设备地区（单位/节假日与看到的天气对不上）。
  Future<void> setManualPlace({
    required String name,
    required double latitude,
    required double longitude,
    String countryCode = '',
  }) => _persist(
    state.copyWith(
      manualPlaceName: name,
      manualLatitude: latitude,
      manualLongitude: longitude,
      countryOverride: countryCode.isNotEmpty ? countryCode : null,
      // 手选了城市 = 显式选择，关掉"跟随定位"，否则会被定位结果顶掉
      autoLocate: false,
    ),
  );

  Future<void> clearManualPlace() =>
      _persist(state.copyWith(clearManualPlace: true));

  /// 和风 key 只进安全存储；传空串 = 删除
  Future<void> setQweatherKey(String key) async {
    final trimmed = key.trim();
    final store = ref.read(cloudKeyStoreProvider);
    if (trimmed.isEmpty) {
      await store.delete(kQweatherKeySlot);
    } else {
      await store.write(kQweatherKeySlot, trimmed);
    }
    // ⚠️ 内存里也不留副本更安全，但"测试连接"要用一次，所以保留到本次会话结束
    state = state.copyWith(qweatherKey: trimmed);
  }
}

final calendarEnvProvider =
    NotifierProvider<CalendarEnvNotifier, CalendarEnvSettings>(
      CalendarEnvNotifier.new,
      // `setAutoLocate`/「用当前位置」要 invalidate 这两个 provider；
      // Riverpod 3 规定：invalidate（和 watch 一样）的对象必须在 dependencies 里登记，
      // 否则 debug/测试里抛 "may be scoped"（release 关断言 → 只真机 release 才"看起来正常"）。
      dependencies: [deviceLocationProvider, locationPermissionProvider],
    );

/// 地区解析器 / 客户端
final geocodeClientProvider = Provider<GeocodeClient>((ref) => GeocodeClient());

final weatherClientProvider = Provider<WeatherClient>((ref) => WeatherClient());

/// 设备定位探针（测试里覆盖成假实现）
final deviceLocationProbeProvider = Provider<DeviceLocationProbe>(
  (ref) => MethodChannelDeviceLocationProbe(),
);

/// 一次定位结果（进程内缓存 10 分钟，由 Android 侧把关；这里只管取一次）。
///
/// 拿不到（没权限/没开定位/超时）就是 null —— **不抛异常**，让地区解析继续走
/// 后面的兜底（手动地点 → 日程地点 → 时区 → 设备地区）。
/// 定位权限的现状（**不弹**授权框，只查）；给设置页显示"还没授权"用
final locationPermissionProvider = FutureProvider<LocationPermission>(
  (ref) async {
    final probe = ref.watch(deviceLocationProbeProvider);
    return probe.ensurePermission(interactive: false);
  },
  retry: noRetry,
  dependencies: [deviceLocationProbeProvider],
);

final deviceLocationProvider = FutureProvider<DeviceLocation?>(
  (ref) async {
    final probe = ref.watch(deviceLocationProbeProvider);
    // ⚠️ **不弹**系统授权框：一进日历就弹"要不要允许定位"太唐突（真机第一次点进来就会弹）。
    // 授权只从设置面板的「用当前位置」走，那一次才是 interactive 的。
    final permission = await probe.ensurePermission(interactive: false);
    if (permission != LocationPermission.granted) return null;
    if (!await probe.serviceEnabled()) return null;
    final fix = await probe.current();
    if (fix == null || !fix.isUsable) return null;
    return fix;
  },
  retry: noRetry,
  dependencies: [deviceLocationProbeProvider],
);

final holidayServiceProvider = Provider<HolidayService>((ref) {
  final service = HolidayService();
  // 把已缓存的节假日塞回服务的内存缓存（跨页面/跨启动都省一次请求）
  return service;
});

/// 设备地区（`zh_CN` → `CN`）；拿不到就空
String deviceCountryCode() {
  final locale = PlatformDispatcher.instance.locale;
  return (locale.countryCode ?? '').toUpperCase();
}

/// 有网版地区解析：**异步**，会去查日程地点（GPS → 文字）与日历时区
Future<RegionContext> resolveRegionAsync({
  required CalendarEnvSettings settings,
  required String calendarTimezone,
  required List<EventLocationHint> eventLocations,
  required GeocodeClient geocoder,
}) async {
  if (settings.countryOverride.isNotEmpty) {
    final cc = settings.countryOverride;
    return RegionContext(
      countryCode: cc,
      city: countryName(cc),
      timezone: calendarTimezone,
      source: RegionSource.manual,
    );
  }
  // 2) 日程地点：先 GPS（最准），再文字（正查）
  for (final hint in eventLocations) {
    if (hint.latitude != null && hint.longitude != null) {
      final region = await geocoder.reverse(
        latitude: hint.latitude!,
        longitude: hint.longitude!,
      );
      if (region.isKnown) return region;
    }
  }
  for (final hint in eventLocations) {
    final text = hint.text.trim();
    if (text.isEmpty) continue;
    final hits = await geocoder.search(text, count: 1);
    if (hits.isNotEmpty) return hits.first.toRegion();
  }
  // 3) 日历时区
  final byTimezone = countryFromTimezone(calendarTimezone);
  if (byTimezone.isNotEmpty) {
    return RegionContext(
      countryCode: byTimezone,
      timezone: calendarTimezone,
      source: RegionSource.calendarTimezone,
    );
  }
  // 4) 设备地区
  final device = deviceCountryCode();
  if (device.isNotEmpty) {
    return RegionContext(
      countryCode: device,
      timezone: calendarTimezone,
      source: RegionSource.deviceLocale,
    );
  }
  return const RegionContext(source: RegionSource.none);
}

/// 日程地点的线索（GPS 来自 `location_info.gps`，文字来自 `location_info.name`）
@immutable
class EventLocationHint {
  const EventLocationHint({this.text = '', this.latitude, this.longitude});

  final String text;
  final double? latitude;
  final double? longitude;

  bool get isEmpty =>
      text.trim().isEmpty && latitude == null && longitude == null;
}

/// 当前生效的单位（地区 + 用户覆盖）
final weatherUnitsProvider = Provider<WeatherUnits>((ref) {
  final settings = ref.watch(calendarEnvProvider);
  final region = ref.watch(calendarRegionProvider).value;
  return weatherUnitsFor(
    region?.countryCode ?? deviceCountryCode(),
    override: settings.unitsOverride,
  );
}, dependencies: [calendarRegionProvider, calendarEnvProvider]);

/// 选定的天气源（按地区自动 + 用户强制；key 只用于"能不能选和风"）
WeatherProviderInfo? pickProviderFor({
  required RegionContext region,
  required CalendarEnvSettings settings,
}) => pickWeatherProvider(
  region.countryCode,
  hasKey: (p) => p.id == 'qweather' && settings.hasQweatherKey,
  forcedId: settings.forcedWeatherProviderId,
);

/// 当前地区（异步，含地点解析）
final calendarRegionProvider = FutureProvider<RegionContext>(
  (ref) async {
    final settings = ref.watch(calendarEnvProvider);
    final timezone = ref.watch(calTimezoneProvider);
    final hints = ref.watch(eventLocationHintsProvider);
    // 0) 跟随定位最优先（用户要求"定位修好"）：城市级坐标 + 反查到的国家/城市。
    //    反查失败也照样用坐标 —— 天气只要坐标，国家退到后面的兜底。
    if (settings.autoLocate) {
      final fix = await ref.watch(deviceLocationProvider.future);
      if (fix != null) {
        RegionContext located = RegionContext(
          countryCode: settings.countryOverride,
          timezone: timezone,
          latitude: fix.latitude,
          longitude: fix.longitude,
          source: RegionSource.deviceLocation,
        );
        try {
          final region = await ref
              .watch(geocodeClientProvider)
              .reverse(latitude: fix.latitude, longitude: fix.longitude);
          if (region.isKnown) {
            located = region.copyWith(
              latitude: fix.latitude,
              longitude: fix.longitude,
              source: RegionSource.deviceLocation,
            );
          }
        } catch (_) {
          // 反查挂了不影响"知道坐标"这件事（天气照常，国家用时区/设备地区兜底）
        }
        if (located.countryCode.isEmpty) {
          located = located.copyWith(
            countryCode: countryFromTimezone(timezone).isNotEmpty
                ? countryFromTimezone(timezone)
                : deviceCountryCode(),
          );
        }
        return located;
      }
    }
    // 手选地点：它同时给出**国家**（单位/节假日）与**坐标**（天气）。
    // （关了定位或定位拿不到时才轮到它）
    if (settings.hasManualPlace) {
      return RegionContext(
        countryCode: settings.countryOverride,
        city: settings.manualPlaceName,
        timezone: timezone,
        latitude: settings.manualLatitude,
        longitude: settings.manualLongitude,
        source: RegionSource.manual,
      );
    }
    if (settings.countryOverride.isNotEmpty) {
      return RegionContext(
        countryCode: settings.countryOverride,
        city: countryName(settings.countryOverride),
        timezone: timezone,
        source: RegionSource.manual,
      );
    }
    return resolveRegionAsync(
      settings: settings,
      calendarTimezone: timezone,
      eventLocations: hints,
      geocoder: ref.watch(geocodeClientProvider),
    );
  },
  retry: noRetry,
  dependencies: [
    // Riverpod 3 要求：watch 了"可能被 scope 覆盖"的 provider 就要登记依赖，
    // 否则 debug 构建/测试里会抛 "depends on Provider<T>, which may be scoped"
    // （release 关断言所以只在真机 release 上"看起来正常"——正是这种问题最难查）。
    calendarEnvProvider,
    calTimezoneProvider,
    eventLocationHintsProvider,
    geocodeClientProvider,
    deviceLocationProvider,
  ],
);

/// 天气（当前 + 未来几天），按地区缓存
final weatherBundleProvider = FutureProvider<WeatherBundle?>(
  (ref) async {
    final region = await ref.watch(calendarRegionProvider.future);
    if (region.latitude == null || region.longitude == null) return null;
    final settings = ref.watch(calendarEnvProvider);
    final provider = pickProviderFor(region: region, settings: settings);
    if (provider == null) return null;
    return ref
        .watch(weatherClientProvider)
        .fetch(
          provider: provider,
          latitude: region.latitude!,
          longitude: region.longitude!,
          days: 7,
          apiKey: provider.needsKey ? settings.qweatherKey : '',
        );
  },
  retry: noRetry,
  dependencies: [calendarRegionProvider, calendarEnvProvider],
);

/// 节假日（按月视图当前年份取；缓存到设置表）
final holidayBundleProvider = FutureProvider<HolidayBundle?>(
  (ref) async {
    final region = await ref.watch(calendarRegionProvider.future);
    if (region.countryCode.isEmpty) return null;
    final year = ref.watch(calendarAnchorProvider).year;
    final service = ref.watch(holidayServiceProvider);
    final bundle = await service.load(
      countryCode: region.countryCode,
      year: year,
      subdivisionCode: region.subdivisionCode,
      allowNetwork: true,
    );
    // 落盘缓存：下次打开先出旧数据（服务内部还有 12 小时 TTL）
    try {
      await ref
          .read(settingsServiceProvider)
          .setCalendarHolidayCacheRaw(jsonEncode(bundle.toJson()));
    } catch (_) {
      // 缓存写不进去不影响展示
    }
    return bundle;
  },
  retry: noRetry,
  dependencies: [
    calendarRegionProvider,
    calendarAnchorProvider,
    holidayServiceProvider,
  ],
);
