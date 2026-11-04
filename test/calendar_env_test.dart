// 日历"环境信息"卡片与设置面板的离线 UI 测试。
//
// 天气/节假日都是网络源，所以这里**覆盖 provider**（region/weather/holiday）后只测
// 页面的渲染与交互；网络那一层由 `test/env_info_test.dart` 用本机桩覆盖。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drift/native.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/holidays/holiday_service.dart';
import 'package:synhub/src/data/region/geocode_client.dart';
import 'package:synhub/src/data/region/region_context.dart';
import 'package:synhub/src/data/weather/weather_client.dart';
import 'package:synhub/src/data/region/device_location.dart';
import 'package:synhub/src/features/calendar/calendar_env.dart';
import 'package:synhub/src/features/calendar/calendar_providers.dart';
import 'package:synhub/src/features/calendar/calendar_env_card.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatStoreProvider;

const _beijing = RegionContext(
  countryCode: 'CN',
  city: '北京',
  timezone: 'Asia/Shanghai',
  latitude: 39.9042,
  longitude: 116.4074,
  source: RegionSource.manual,
);

WeatherBundle _bundle() => WeatherBundle(
  providerId: 'open-meteo',
  now: const WeatherNow(
    providerId: 'open-meteo',
    temperatureC: 24.3,
    apparentC: 26.5,
    humidity: 71,
    code: 3,
    windKmh: 20,
    windDir: '南风',
    pressureHpa: 1013.5,
  ),
  days: [
    for (var i = 0; i < 5; i++)
      WeatherDay(
        date: DateTime(2026, 9, 19 + i),
        code: i == 0 ? 3 : 0,
        minC: 20 + i.toDouble(),
        maxC: 28 + i.toDouble(),
        precipitationMm: i == 0 ? 0.2 : 0,
      ),
  ],
);

HolidayBundle _holidays() => HolidayBundle(
  countryCode: 'CN',
  year: 2026,
  entries: [
    HolidayEntry(
      date: DateTime(2026, 9, 25),
      name: '中秋节',
      kind: HolidayKind.public,
      source: 'lunar',
    ),
    HolidayEntry(
      date: DateTime(2026, 9, 19),
      name: '世界住房日',
      kind: HolidayKind.observance,
      source: 'nager',
    ),
    HolidayEntry(
      date: DateTime(2026, 9, 19),
      name: '调休补班',
      kind: HolidayKind.workday,
      source: 'lunar',
    ),
  ],
  sources: const ['nager', 'lunar'],
);

Future<void> _pumpCard(
  WidgetTester tester, {
  DateTime? day,
  RegionContext? region,
  WeatherBundle? weather,
  HolidayBundle? holidays,
  bool noWeather = false,
}) async {
  tester.view.physicalSize = const Size(1148, 2492);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      calendarRegionProvider.overrideWith((ref) async => region ?? _beijing),
      weatherBundleProvider.overrideWith(
        (ref) async => noWeather ? null : (weather ?? _bundle()),
      ),
      holidayBundleProvider.overrideWith(
        (ref) async => holidays ?? _holidays(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CalendarEnvCard(day: day ?? DateTime(2026, 9, 19)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// 假的地理编码客户端：只回固定候选，**记录查询串**（用来钉"搜的就是用户输入的"）
class _FakeGeo extends GeocodeClient {
  _FakeGeo({
    this.hits = const [],
    this.throwOnSearch = false,
    this.region,
    this.throwOnReverse = false,
  });

  final List<GeoSuggestion> hits;
  final bool throwOnSearch;

  /// 逆地理（定位坐标 → 城市/国家）的结果
  final RegionContext? region;
  final bool throwOnReverse;
  final List<String> queries = [];
  final List<(double, double)> reverses = [];

  @override
  Future<List<GeoSuggestion>> search(String query, {int count = 5}) async {
    queries.add(query);
    if (throwOnSearch) throw Exception('连不上地理编码服务');
    return hits;
  }

  @override
  Future<RegionContext> reverse({
    required double latitude,
    required double longitude,
    String language = 'zh-CN',
  }) async {
    reverses.add((latitude, longitude));
    if (throwOnReverse) throw Exception('逆地理挂了');
    return region ?? const RegionContext();
  }
}

/// 假的定位探针：把"系统定位"这一层换成可控的固定值
class _FakeLocation implements DeviceLocationProbe {
  _FakeLocation({
    this.permission = LocationPermission.granted,
    this.service = true,
    this.fix,
  });

  LocationPermission permission;
  bool service;
  DeviceLocation? fix;
  int cleared = 0;
  int permissionAsks = 0;

  /// 每次要权限时 `interactive` 的值（进页面**不该**弹框，只有用户点按钮才弹）
  final List<bool> asks = [];

  @override
  Future<LocationPermission> ensurePermission({bool interactive = true}) async {
    permissionAsks++;
    asks.add(interactive);
    return permission;
  }

  @override
  Future<bool> serviceEnabled() async => service;

  @override
  Future<DeviceLocation?> current() async => fix;

  @override
  Future<void> clearCache() async => cleared++;
}

const _hangzhou = GeoSuggestion(
  name: '杭州',
  countryCode: 'CN',
  admin1: '浙江省',
  timezone: 'Asia/Shanghai',
  latitude: 30.2741,
  longitude: 120.1551,
);

const _noCoord = GeoSuggestion(name: '没有坐标的地方', countryCode: 'CN');

void main() {
  testWidgets('卡片：选中非今天 → 显示那天的预报（不是此刻实况）', (tester) async {
    // ⚠️ 用户真机反馈过"切换日期天气不变"：卡片原来永远显示 `now`（此刻实况）。
    // 现在选中非今天时主行是**那天的预报**（最低~最高），实况退到"当日"只在今天显示。
    await _pumpCard(tester);
    // `_fmtTemp` 只给数字（`20`），温度单位由 `units.temperatureLabel` 兜底 → `20~28°C`
    expect(find.textContaining('20~28°C'), findsOneWidget, reason: '9/19 的预报');
    expect(find.textContaining('当天预报'), findsOneWidget);
    expect(find.textContaining('24°C'), findsNothing, reason: '不是今天就不该显示此刻实况');
    expect(find.textContaining('体感'), findsNothing);
    expect(find.textContaining('风 4 级（和风）'), findsNothing);
    expect(find.textContaining('气压'), findsNothing);
    // 单位仍然是按地区派生的（中国 → 摄氏）
    expect(find.textContaining('°C'), findsWidgets);
    // 农历行（2026-09-19 是农历八月初九）
    expect(find.textContaining('初九'), findsOneWidget);
    // 节假日：纪念日 + 调休上班（同一张卡）
    expect(find.textContaining('世界住房日'), findsOneWidget);
    expect(find.textContaining('调休补班（上班）'), findsOneWidget);
    // 来源行必须可见：地区怎么判的 + 哪个天气源 + 节假日源
    expect(find.byKey(const Key('cal-env-source')), findsOneWidget);
    expect(find.textContaining('北京 · CN（手动指定）'), findsOneWidget);
    expect(find.textContaining('天气 Open-Meteo'), findsOneWidget);
    // ★★★ D70（r349 真机像素）：这一行**原本把缺陷当契约** ——
    // 上面一行天气源断言的是**本地化名字**（`天气 Open-Meteo`），
    // 下面却断言 `节假日 nager+lunar`（**聚合器原始 id**）。
    // 同一行、同一类东西、两种口径，而且被用例钉死了 —— 见 §2.0.29
    // 「用例把缺陷当契约 ⇒ 修复必须连用例一起改」。
    expect(find.textContaining('节假日 Nager.Date'), findsOneWidget);
    expect(find.textContaining('农历'), findsOneWidget);
    // ★ 反向：原始 id 不许再出现在用户可见文案里（否则上面的断言形同虚设）
    expect(
      find.textContaining('nager+lunar'),
      findsNothing,
      reason: '内部供应方 id 不许当用户文案',
    );
  });

  testWidgets('卡片：今天 → 此刻实况 + 当日最低/最高 + 单位按地区', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // 预报从"今天"开始，这样 `dayOf(today)` 命中第一天
    final bundle = WeatherBundle(
      providerId: 'open-meteo',
      now: _bundle().now,
      days: [
        for (var i = 0; i < 5; i++)
          WeatherDay(
            date: today.add(Duration(days: i)),
            code: i == 0 ? 3 : 0,
            minC: 20 + i.toDouble(),
            maxC: 28 + i.toDouble(),
            precipitationMm: i == 0 ? 0.2 : 0,
          ),
      ],
    );
    await _pumpCard(tester, day: today, weather: bundle);
    // 中国 → 摄氏 + 蒲福风级
    expect(find.textContaining('24°C'), findsWidgets);
    expect(find.textContaining('体感 27°'), findsWidgets);
    expect(find.textContaining('风 4 级（和风）'), findsOneWidget);
    expect(find.textContaining('气压 1014hPa'), findsOneWidget);
    // 今天才显示"当日"那一行
    expect(find.textContaining('当日'), findsOneWidget);
    expect(find.textContaining('当天预报'), findsNothing);
  });

  /// 悬挂卡片 → 设置面板 → 搜地名 → 点候选。这条链是"天气能不能有坐标"的关键：
  /// 坐标原先只能从带地点的日程里拿，没有地点日程的日子就永远看不到天气。
  Future<ProviderContainer> pumpSheet(
    WidgetTester tester,
    _FakeGeo geo, {
    RegionContext? region,
  }) async {
    tester.view.physicalSize = const Size(1148, 2492);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        geocodeClientProvider.overrideWithValue(geo),
        calTimezoneProvider.overrideWithValue('Asia/Shanghai'),
        eventLocationHintsProvider.overrideWithValue(const []),
        if (region != null)
          calendarRegionProvider.overrideWith((ref) async => region),
        weatherBundleProvider.overrideWith((ref) async => null),
        holidayBundleProvider.overrideWith((ref) async => _holidays()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CalendarEnvCard(day: DateTime(2026, 9, 19)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(CalendarEnvCard));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('设置面板：搜地名 → 点候选 → 写入坐标 + 国家（天气才有地点）', (tester) async {
    final geo = _FakeGeo(hits: const [_hangzhou, _noCoord]);
    final container = await pumpSheet(tester, geo);

    await tester.enterText(find.byKey(const Key('cal-env-place-query')), '杭州');
    await tester.tap(find.byKey(const Key('cal-env-place-search')));
    await tester.pumpAndSettle();

    expect(geo.queries, ['杭州'], reason: '搜的就是用户输入的地名');
    expect(find.byKey(const Key('cal-env-place-hit-杭州')), findsOneWidget);
    // 没坐标的候选**不显示**（点了也没用，天气要的是坐标）
    expect(find.byKey(const Key('cal-env-place-hit-没有坐标的地方')), findsNothing);

    await tester.tap(find.byKey(const Key('cal-env-place-hit-杭州')));
    await tester.pumpAndSettle();

    final saved = container.read(calendarEnvProvider);
    expect(saved.manualPlaceName, '杭州');
    expect(saved.manualLatitude, closeTo(30.2741, 0.0001));
    expect(saved.manualLongitude, closeTo(120.1551, 0.0001));
    expect(saved.countryOverride, 'CN', reason: '选了东京就该按日本算单位与节假日');
    // 真正的落点：地区解析现在带的坐标就是天气要用的坐标
    final region = await container.read(calendarRegionProvider.future);
    expect(region.latitude, closeTo(30.2741, 0.0001));
    expect(region.longitude, closeTo(120.1551, 0.0001));
    expect(region.city, '杭州');

    // 「清除」后回到"没有地点信息"
    await tester.tap(find.byKey(const Key('cal-env-place-clear')));
    await tester.pumpAndSettle();
    expect(container.read(calendarEnvProvider).hasManualPlace, isFalse);
  });

  testWidgets('设置面板：搜不到就说没找到（不悄悄塞一个默认城市）', (tester) async {
    final geo = _FakeGeo(hits: const []);
    await pumpSheet(tester, geo);

    await tester.enterText(
      find.byKey(const Key('cal-env-place-query')),
      '不存在的村',
    );
    await tester.tap(find.byKey(const Key('cal-env-place-search')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cal-env-place-error')), findsOneWidget);
    expect(find.textContaining('没找到这个地名'), findsOneWidget);
  });

  testWidgets('设置面板：搜索报错如实显示，不崩', (tester) async {
    final geo = _FakeGeo(throwOnSearch: true);
    await pumpSheet(tester, geo);

    await tester.enterText(find.byKey(const Key('cal-env-place-query')), '杭州');
    await tester.tap(find.byKey(const Key('cal-env-place-search')));
    await tester.pumpAndSettle();

    expect(find.textContaining('搜索失败'), findsOneWidget);
  });

  testWidgets('卡片：手选地点后天气就有地点可用了', (tester) async {
    // 地区解析是**真**跑（只把网络层换掉），证明手选地点真的喂给了天气
    final geo = _FakeGeo(hits: const [_hangzhou]);
    final container = await pumpSheet(tester, geo);
    await tester.enterText(find.byKey(const Key('cal-env-place-query')), '杭州');
    await tester.tap(find.byKey(const Key('cal-env-place-search')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cal-env-place-hit-杭州')));
    await tester.pumpAndSettle();

    final region = await container.read(calendarRegionProvider.future);
    expect(region.isKnown, isTrue);
    expect(region.latitude, isNotNull);
    expect(region.longitude, isNotNull);
  });

  test('地区：开着「跟随手机定位」→ 用定位坐标 + 反查到的城市（source=手机定位）', () async {
    // 地区解析**真跑**：只把定位探针与地理编码换掉
    final geo = _FakeGeo(
      region: const RegionContext(
        countryCode: 'JP',
        city: '东京',
        timezone: 'Asia/Tokyo',
      ),
    );
    final loc = _FakeLocation(
      fix: const DeviceLocation(
        latitude: 35.6762,
        longitude: 139.6503,
        accuracyM: 25,
        provider: 'gps',
        timeMs: 1789000000000,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        deviceLocationProbeProvider.overrideWithValue(loc),
        geocodeClientProvider.overrideWithValue(geo),
        calTimezoneProvider.overrideWithValue('Asia/Shanghai'),
        eventLocationHintsProvider.overrideWithValue(const []),
        weatherBundleProvider.overrideWith((ref) async => null),
        holidayBundleProvider.overrideWith((ref) async => null),
        // 设置持久化走内存库：不然 `path_provider` 插件在纯 Dart 测试里不存在
        chatStoreProvider.overrideWithValue(
          ChatStore(ChatDatabase(NativeDatabase.memory())),
        ),
      ],
    );
    addTearDown(container.dispose);

    final region = await container.read(calendarRegionProvider.future);
    expect(region.source, RegionSource.deviceLocation, reason: '定位最优先');
    expect(region.latitude, closeTo(35.6762, 0.0001));
    expect(region.longitude, closeTo(139.6503, 0.0001));
    expect(region.city, '东京');
    expect(region.countryCode, 'JP');
    expect(geo.reverses, [(35.6762, 139.6503)], reason: '拿坐标反查城市/国家');
  });

  test('地区：逆地理挂了也照用定位坐标（天气只要坐标，国家用时区兜底）', () async {
    final geo = _FakeGeo(throwOnReverse: true);
    final loc = _FakeLocation(
      fix: const DeviceLocation(
        latitude: 31.2304,
        longitude: 121.4737,
        timeMs: 1789000000000,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        deviceLocationProbeProvider.overrideWithValue(loc),
        geocodeClientProvider.overrideWithValue(geo),
        calTimezoneProvider.overrideWithValue('Asia/Shanghai'),
        eventLocationHintsProvider.overrideWithValue(const []),
        weatherBundleProvider.overrideWith((ref) async => null),
        holidayBundleProvider.overrideWith((ref) async => null),
        // 设置持久化走内存库：不然 `path_provider` 插件在纯 Dart 测试里不存在
        chatStoreProvider.overrideWithValue(
          ChatStore(ChatDatabase(NativeDatabase.memory())),
        ),
      ],
    );
    addTearDown(container.dispose);
    final region = await container.read(calendarRegionProvider.future);
    expect(region.latitude, closeTo(31.2304, 0.0001), reason: '坐标必须留住（天气要用）');
    expect(region.countryCode, 'CN', reason: '国家退到时区推出来的 CN');
    expect(region.source, RegionSource.deviceLocation);
  });

  test('地区：定位没权限 → 退回手动地点（定位不该把用户的显式选择顶掉）', () async {
    final geo = _FakeGeo(hits: const [_hangzhou]);
    final loc = _FakeLocation(permission: LocationPermission.denied);
    final container = ProviderContainer(
      overrides: [
        deviceLocationProbeProvider.overrideWithValue(loc),
        geocodeClientProvider.overrideWithValue(geo),
        calTimezoneProvider.overrideWithValue('Asia/Shanghai'),
        eventLocationHintsProvider.overrideWithValue(const []),
        weatherBundleProvider.overrideWith((ref) async => null),
        holidayBundleProvider.overrideWith((ref) async => null),
        // 设置持久化走内存库：不然 `path_provider` 插件在纯 Dart 测试里不存在
        chatStoreProvider.overrideWithValue(
          ChatStore(ChatDatabase(NativeDatabase.memory())),
        ),
      ],
    );
    addTearDown(container.dispose);
    // 手选杭州（这会自动关掉"跟随定位"——见下一条）
    await container
        .read(calendarEnvProvider.notifier)
        .setManualPlace(
          name: '杭州',
          latitude: 30.2741,
          longitude: 120.1551,
          countryCode: 'CN',
        );
    expect(container.read(calendarEnvProvider).autoLocate, isFalse);

    final region = await container.read(calendarRegionProvider.future);
    expect(region.source, RegionSource.manual);
    expect(region.latitude, closeTo(30.2741, 0.0001));
    expect(geo.reverses, isEmpty, reason: '没定位就不该去反查');
  });

  test('地区：定位开着但没开系统开关 → 也不硬用（回退到后续兜底）', () async {
    final loc = _FakeLocation(service: false);
    final container = ProviderContainer(
      overrides: [
        deviceLocationProbeProvider.overrideWithValue(loc),
        geocodeClientProvider.overrideWithValue(_FakeGeo()),
        calTimezoneProvider.overrideWithValue('Asia/Shanghai'),
        eventLocationHintsProvider.overrideWithValue(const []),
        weatherBundleProvider.overrideWith((ref) async => null),
        holidayBundleProvider.overrideWith((ref) async => null),
        // 设置持久化走内存库：不然 `path_provider` 插件在纯 Dart 测试里不存在
        chatStoreProvider.overrideWithValue(
          ChatStore(ChatDatabase(NativeDatabase.memory())),
        ),
      ],
    );
    addTearDown(container.dispose);
    final region = await container.read(calendarRegionProvider.future);
    expect(region.source, RegionSource.calendarTimezone, reason: '时区兜底 → CN');
    expect(region.countryCode, 'CN');
    expect(region.latitude, isNull);
  });

  test('设置：「用当前位置」会清定位缓存并重新解析；手选城市则关掉跟随定位', () async {
    final geo = _FakeGeo(hits: const [_hangzhou]);
    final loc = _FakeLocation(
      permission: LocationPermission.denied,
      fix: const DeviceLocation(latitude: 1, longitude: 2, timeMs: 0),
    );
    final container = ProviderContainer(
      overrides: [
        deviceLocationProbeProvider.overrideWithValue(loc),
        geocodeClientProvider.overrideWithValue(geo),
        calTimezoneProvider.overrideWithValue('Asia/Shanghai'),
        eventLocationHintsProvider.overrideWithValue(const []),
        weatherBundleProvider.overrideWith((ref) async => null),
        holidayBundleProvider.overrideWith((ref) async => null),
        // 设置持久化走内存库：不然 `path_provider` 插件在纯 Dart 测试里不存在
        chatStoreProvider.overrideWithValue(
          ChatStore(ChatDatabase(NativeDatabase.memory())),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(calendarEnvProvider.notifier);

    // 先手选城市 → 跟随定位被关掉
    await notifier.setManualPlace(
      name: '杭州',
      latitude: 30.2741,
      longitude: 120.1551,
      countryCode: 'CN',
    );
    expect(container.read(calendarEnvProvider).autoLocate, isFalse);

    // 再打开「跟随手机定位」→ 清缓存（否则 10 分钟内还是老坐标）
    await notifier.setAutoLocate(true);
    expect(container.read(calendarEnvProvider).autoLocate, isTrue);
    expect(loc.cleared, 1);
    expect(geo.queries, isEmpty, reason: '清缓存不该顺手打地理编码');
  });

  test('地区：解析地区时**不弹**系统授权框（只有「用当前位置」才弹）', () async {
    final loc = _FakeLocation(permission: LocationPermission.denied);
    final container = ProviderContainer(
      overrides: [
        deviceLocationProbeProvider.overrideWithValue(loc),
        geocodeClientProvider.overrideWithValue(_FakeGeo()),
        calTimezoneProvider.overrideWithValue('Asia/Shanghai'),
        eventLocationHintsProvider.overrideWithValue(const []),
        weatherBundleProvider.overrideWith((ref) async => null),
        holidayBundleProvider.overrideWith((ref) async => null),
        chatStoreProvider.overrideWithValue(
          ChatStore(ChatDatabase(NativeDatabase.memory())),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(calendarRegionProvider.future);
    expect(loc.asks, isNotEmpty, reason: '要看一眼权限现状');
    expect(
      loc.asks.every((i) => i == false),
      isTrue,
      reason: '一进日历就弹授权框太唐突，这里必须是非交互查询',
    );
  });

  testWidgets('卡片：日出/日落显示成 HH:mm（源给的是 ISO 串）', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final bundle = WeatherBundle(
      providerId: 'open-meteo',
      now: _bundle().now,
      days: [
        WeatherDay(date: today, code: 1, minC: 20, maxC: 28),
        WeatherDay(
          date: today.add(const Duration(days: 1)),
          code: 1,
          minC: 20,
          maxC: 28,
          // 真机看到的形态：ISO 串，不是 `05:48`
          sunrise: '2026-09-23T05:48',
          sunset: '2026-09-23T17:55',
        ),
      ],
    );
    // 选中"明天"→ 走预报分支（副标题里才有日出日落）
    await _pumpCard(
      tester,
      day: today.add(const Duration(days: 1)),
      weather: bundle,
    );
    expect(find.textContaining('日出 05:48'), findsOneWidget);
    expect(find.textContaining('日落 17:55'), findsOneWidget);
    expect(find.textContaining('T05:48'), findsNothing, reason: '别把 ISO 串原样显示');
  });

  test('设置：autoLocate 默认开、只有"关掉"才落盘（老配置升级后也能用定位）', () {
    expect(const CalendarEnvSettings().autoLocate, isTrue);
    // 开着：JSON 里不写这个键
    final on = const CalendarEnvSettings(manualPlaceName: '杭州');
    expect(on.toJson().containsKey('autoLocate'), isFalse);
    expect(CalendarEnvSettings.fromJson(on.toJson()).autoLocate, isTrue);
    // 关掉：写 false 并能读回来
    final off = on.copyWith(autoLocate: false);
    expect(off.toJson()['autoLocate'], false);
    expect(CalendarEnvSettings.fromJson(off.toJson()).autoLocate, isFalse);
  });

  testWidgets('卡片：美制地区自动换单位（°F / mph / inHg）', (tester) async {
    // 用"今天"跑：实况行有风/气压（mph / inHg），能一次把三种换算都验到
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final bundle = WeatherBundle(
      providerId: 'open-meteo',
      now: _bundle().now,
      days: [
        for (var i = 0; i < 5; i++)
          WeatherDay(
            date: today.add(Duration(days: i)),
            code: 3,
            minC: 20,
            maxC: 28,
          ),
      ],
    );
    await _pumpCard(
      tester,
      day: today,
      weather: bundle,
      region: _beijing.copyWith(
        countryCode: 'US',
        city: '纽约',
        source: RegionSource.eventGps,
      ),
    );
    expect(find.textContaining('76°F'), findsWidgets); // 24.3°C → 75.7°F
    expect(find.textContaining('mph'), findsWidgets);
    expect(find.textContaining('inHg'), findsWidgets);
    expect(find.textContaining('纽约 · US（日程地点（GPS））'), findsOneWidget);
  });

  testWidgets('卡片：节日当天给「休」徽标，调休当天给「班」', (tester) async {
    // 2026-09-25 中秋节（法定）→ 休
    await _pumpCard(tester, day: DateTime(2026, 9, 25));
    expect(find.text('休'), findsOneWidget);
    expect(find.textContaining('中秋节'), findsWidgets);

    // 2026-02-28 春节补班 → 班
    await _pumpCard(tester, day: DateTime(2026, 2, 28));
    expect(find.text('班'), findsOneWidget);
  });

  testWidgets('卡片：天气失败时如实说明，且不影响农历与节假日', (tester) async {
    await _pumpCard(tester, noWeather: true);
    // weatherBundleProvider 返回 null → 卡片要说清"缺的是位置"并且指向可点的动作
    // （DA275：原来是"还没有地点信息"——既不说原因也不说该点哪儿）
    expect(find.textContaining('天气要位置'), findsOneWidget);
    expect(find.textContaining('还没有地点信息'), findsNothing);
    expect(find.textContaining('世界住房日'), findsOneWidget);
  });

  testWidgets('设置面板：切单位立刻生效，并显示当前单位组合', (tester) async {
    await _pumpCard(tester);
    await tester.tap(find.byKey(const Key('cal-env-card')));
    await tester.pumpAndSettle();
    expect(find.text('天气与节假日'), findsOneWidget);
    expect(find.textContaining('温度 °C · 风 级'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cal-env-units-imperial')));
    await tester.pumpAndSettle();
    expect(find.textContaining('温度 °F · 风 mph · 降水 in'), findsOneWidget);
  });

  testWidgets('设置面板：能列出全部天气源并说明当前会用哪个', (tester) async {
    await _pumpCard(tester);
    await tester.tap(find.byKey(const Key('cal-env-card')));
    await tester.pumpAndSettle();
    expect(find.text('和风天气 QWeather'), findsOneWidget);
    expect(find.text('Open-Meteo'), findsOneWidget);
    expect(find.textContaining('当前会用：'), findsOneWidget);
    // 和风 key 输入框在（存安全存储）
    expect(find.byKey(const Key('cal-env-qweather-key')), findsOneWidget);
  });

  /// 带逐小时的天气包（`_bundle()` 故意不带，免得动到上面几十条断言）
  WeatherBundle withHours(List<WeatherHour> hours) => WeatherBundle(
    providerId: 'open-meteo',
    now: _bundle().now,
    days: _bundle().days,
    hours: hours,
  );

  testWidgets('逐小时条：今天从「现在」这一小时起往后，降水概率也显示', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // 今天 0 点起 24 条整点，温度 10+i；其中"现在"那一小时有降水概率
    final hours = [
      for (var i = 0; i < 24; i++)
        WeatherHour(
          time: today.add(Duration(hours: i)),
          code: i == now.hour ? 61 : 0,
          temperatureC: 10 + i.toDouble(),
          precipitationProbability: i == now.hour ? 65 : 0,
        ),
    ];
    await _pumpCard(tester, day: today, weather: withHours(hours));
    expect(find.byKey(const Key('cal-hourly-strip')), findsOneWidget);
    // "现在"只出现在当前那一格（其它格是"14时"这种）
    expect(find.text('现在'), findsOneWidget);
    expect(find.byKey(Key('cal-hour-${now.hour}')), findsOneWidget);
    // 温度与降水概率在同一个 `Text.rich` 里 → 用 textContaining
    expect(find.textContaining('65%'), findsOneWidget);
    // 0 点那条**已经被跳过去了**（`hoursFrom` 从当前整点起，0 点时除外）
    if (now.hour > 0) {
      expect(find.byKey(const Key('cal-hour-0')), findsNothing);
    }
  });

  testWidgets('逐小时条：选中非今天 → 那一天的整点，没有「现在」', (tester) async {
    final hours = [
      for (var i = 0; i < 24; i++)
        WeatherHour(
          time: DateTime(2026, 9, 19, i),
          code: 0,
          temperatureC: 15 + i.toDouble(),
          precipitationMm: i == 3 ? 0.8 : 0,
        ),
    ];
    await _pumpCard(
      tester,
      day: DateTime(2026, 9, 19),
      weather: withHours(hours),
    );
    expect(find.byKey(const Key('cal-hourly-strip')), findsOneWidget);
    expect(find.text('现在'), findsNothing, reason: '不是今天就不该有"现在"');
    expect(find.text('3时'), findsOneWidget);
    // 有降水量但没有概率 → 显示 mm（换算后 0.8mm = 0.08cm? 公制下就是 0.8）
    expect(find.textContaining('0.8'), findsOneWidget);
  });

  testWidgets('逐小时条：源没给逐小时（比如只有逐日）→ 整段不出现', (tester) async {
    await _pumpCard(tester, day: DateTime(2026, 9, 19));
    expect(find.byKey(const Key('cal-hourly-strip')), findsNothing);
  });
}
