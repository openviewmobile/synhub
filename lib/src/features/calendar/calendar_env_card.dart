// 日历的"环境信息"卡片 + 设置面板。
//
// 用户要的是"**天气和节假日放在一起**"，所以这里就是一张卡：
//   第一行：这一天（农历 + 节日/节气 + 休/班）
//   第二行：现在天气（按地区单位）
//   第三行：未来几天（一眼看趋势）
//   第四行：数据来源（哪个天气源、地区怎么判的）——**来源必须可见**，
//           否则"温度不对"时用户没法判断是地区判错了还是源的问题。
//
// 设置面板从这张卡点进去：**地点（搜城市，天气要坐标）**/ 地区（自动/手选）/
// 单位（自动/公制/英制/英国混合）/ 天气源（自动或强制）/ 和风 key（存系统安全存储）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/holidays/holiday_service.dart';
import '../../data/region/device_location.dart';
import '../../data/region/geocode_client.dart';
import '../../data/region/region_context.dart';
import '../../data/weather/weather_client.dart';
import 'calendar_env.dart';
import 'weather_backdrop.dart';
import '../../core/user_facing_error.dart';

class CalendarEnvCard extends ConsumerWidget {
  const CalendarEnvCard({
    super.key,
    required this.day,
    this.compact = false,
    this.dense = false,
  });

  final DateTime day;

  /// 紧凑模式：矮屏（真机逻辑高度 ~814）只留"农历 + 此刻天气"两行，
  /// 当日概况和未来几天的横滑条收进设置弹层 —— 否则下面的选中日列表只剩几十像素。
  final bool compact;

  /// 极窄模式（D3）：可用高度连 [compact] 的两行都放不下时只画**一行天气**。
  /// 由 `_DayList` 的高度预算决定（矮屏 + 2.0 缩放会走到这里），保证天气卡
  /// 在任何组合下都有内容可见，而不是被压成 0 高。
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = context.t;
    final info = ChineseCalendar.infoFor(day);
    final units = ref.watch(weatherUnitsProvider);
    final region = ref.watch(calendarRegionProvider);
    final weather = ref.watch(weatherBundleProvider);
    final holidays = ref.watch(holidayBundleProvider);

    final dayHolidays = holidays.value?.on(day) ?? const <HolidayEntry>[];
    final now = weather.value?.now;
    final days = weather.value?.days ?? const <WeatherDay>[];
    // 选中那天的**预报**（`WeatherBundle.dayOf` 只认日期，正好就是"那一天"）
    final today = weather.value?.dayOf(day);
    final nowDate = DateTime.now();
    final isToday =
        day.year == nowDate.year &&
        day.month == nowDate.month &&
        day.day == nowDate.day;
    // ⚠️ 真机反馈过"切换日期天气不变"：这一行原来**永远**显示 `now`（此刻实况），
    // 所以点哪一天长得都一样。现在：选中非今天 → 显示那天的预报；今天 → 实况 + 当日
    // 最低/最高；超出 7 天预报范围 → 退回避实况，但标注"此刻"让用户知道不是那天的。
    final showForecast = !isToday && today != null;
    // 逐小时：今天 → 从当前整点起往后 24 条（"现在"那格高亮）；其它日子 → 那天的整点
    final hourList = isToday
        ? (weather.value?.hoursFrom(
                DateTime(
                  nowDate.year,
                  nowDate.month,
                  nowDate.day,
                  nowDate.hour,
                ),
              ) ??
              const <WeatherHour>[])
        : (weather.value?.hoursFor(day) ?? const <WeatherHour>[]);

    // 极窄模式（D3）：只画一行"此刻天气"，高度约 44，任何组合下都放得下。
    if (dense) {
      final denseIcon = showForecast
          ? today.icon()
          : (now == null ? '—' : now.icon());
      final denseLine = showForecast
          ? '${today.icon()} ${wmoText(today.code)} '
                '${_fmtTemp(units.convertTemp(today.minC))}~'
                '${_fmtTemp(units.convertTemp(today.maxC))}'
                '${units.temperatureLabel}'
          : (weather.isLoading && now == null)
          ? t.calEnvWeatherLoading
          : (weather.hasError && now == null)
          ? t.calEnvWeatherFailed('${weather.error}')
          : now == null
          ? t.calEnvNoPlace
          : '${now.icon()} ${now.text()} '
                '${_fmtTemp(units.convertTemp(now.temperatureC))}'
                '${units.temperatureLabel}';
      return Padding(
        // dense 是"极度缺高"的分支：上下留白和内部 padding 一起收紧，
        // 让"天气行 + 出处行"两行真的塞得进 `kEnvCardMinVisible`（第 262 轮
        // 用例实测原来出处行底部超出视口 4.1px ⇒ 又被切）。
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.xxs),
        child: Material(
          color: DesignPalette.of(context).surface,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            key: const Key('cal-env-card'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => showCalendarEnvSheet(context, ref),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.md,
                vertical: Gap.xxs,
              ),
              child: Row(
                children: [
                  Text(denseIcon, style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          denseLine,
                          key: const Key('cal-env-weather'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        // 极窄模式**也要能看到出处**：这张卡存在的理由之一就是
                        // "温度不对时用户能判断是地区判错还是源的问题"
                        // （见文件头第 4 行）。字号降到 9，一行省略号封顶。
                        Text(
                          _sourceLine(
                            t,
                            region.value,
                            weather.value?.providerId,
                            holidays.value,
                          ),
                          key: const Key('cal-env-source'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: DesignPalette.of(context).dim,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
      child: Material(
        color: DesignPalette.of(context).surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: const Key('cal-env-card'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => showCalendarEnvSheet(context, ref),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 农历一行：节日/节气优先，普通日子给"初三"
                    Flexible(
                      child: Text(
                        info.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color:
                              info.isFestival ||
                                  info.labelKind == HolidayKind.public
                              ? theme.colorScheme.primary
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    // ⚠️ 必须 Flexible + 省略号：节日名可能很长（"世界住房日"、
                    // "国际劳动妇女节"），不约束会把整行撑爆（离线测试报 1129px 溢出）
                    Flexible(
                      child: Text(
                        info.lunarMonthDay,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: DesignPalette.of(context).dim,
                        ),
                      ),
                    ),
                    if (info.isOfficialHoliday) ...[
                      const SizedBox(width: Gap.xs),
                      _Badge(
                        text: t.calEnvBadgeRest,
                        color: theme.colorScheme.primary,
                      ),
                    ] else if (info.isWorkday) ...[
                      const SizedBox(width: Gap.xs),
                      _Badge(
                        text: t.calEnvBadgeWork,
                        color: theme.colorScheme.error,
                      ),
                    ],
                    const Spacer(),
                    Icon(Icons.tune, size: 16, color: DesignPalette.of(context).dim),
                  ],
                ),
                const SizedBox(height: Gap.sm),
                // 天气：此刻
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      showForecast
                          ? today.icon()
                          : (now == null ? '—' : now.icon()),
                      style: const TextStyle(fontSize: 26),
                    ),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      key: const Key('cal-env-weather'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showForecast)
                            Text(
                              '${today.icon()} ${wmoText(today.code)} '
                              '${_fmtTemp(units.convertTemp(today.minC))}~'
                              '${_fmtTemp(units.convertTemp(today.maxC))}'
                              '${units.temperatureLabel}',
                              style: theme.textTheme.bodyMedium,
                            )
                          else if (weather.isLoading && now == null)
                            Text(
                              t.calEnvWeatherLoading,
                              style: theme.textTheme.bodySmall,
                            )
                          else if (weather.hasError && now == null)
                            Text(
                              t.calEnvWeatherFailed('${weather.error}'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            )
                          else if (now == null)
                            Text(
                              t.calEnvNoPlace,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: DesignPalette.of(context).dim,
                              ),
                            )
                          else
                            Text(
                              '${now.icon()} ${now.text()} '
                              '${_fmtTemp(units.convertTemp(now.temperatureC))}'
                              '${units.temperatureLabel}'
                              '${now.apparentC == null ? '' : t.calEnvFeelsLike(_fmtTemp(units.convertTemp(now.apparentC!)))}',
                              style: theme.textTheme.bodyMedium,
                            ),
                          if (showForecast)
                            Text(
                              [
                                t.calEnvTodayForecast,
                                if (today.precipitationMm != null &&
                                    today.precipitationMm! > 0)
                                  t.calEnvPrecip(
                                    units
                                        .convertPrecip(today.precipitationMm!)
                                        .toStringAsFixed(1),
                                    units.precipitationLabel,
                                  ),
                                if (_clockOf(today.sunrise).isNotEmpty)
                                  t.calEnvSunrise(_clockOf(today.sunrise)),
                                if (_clockOf(today.sunset).isNotEmpty)
                                  t.calEnvSunset(_clockOf(today.sunset)),
                              ].join(' · '),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: DesignPalette.of(context).dim,
                              ),
                            )
                          else if (now != null)
                            Text(
                              [
                                if (!isToday) t.calEnvNowLabel,
                                if (now.humidity != null)
                                  t.calEnvHumidity('${now.humidity}'),
                                if (now.windKmh != null)
                                  t.calEnvWind(units.windText(now.windKmh!)),
                                if (now.windDir.isNotEmpty) now.windDir,
                                if (now.pressureHpa != null)
                                  t.calEnvPressure(
                                    units
                                        .convertPressure(now.pressureHpa!)
                                        .toStringAsFixed(0),
                                    units.pressureLabel,
                                  ),
                              ].join(' · '),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: DesignPalette.of(context).dim,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                // 来源行：地区怎么定的 + 哪个天气源 + 节假日源。
                // ⚠️ **必须紧跟天气行**（第 262 轮改）：卡片视口是固定预算
                // （外层 `ConstrainedBox(maxHeight: cardMax)` + 内部滚动），原来这段
                // 放在卡片**最底部**，矮屏 / 大字号下会被视口上沿切掉半行 ——
                // 用户看到的就是"被裁的来源行"（`docs/launch-readiness.md §5-3`）。
                // 数据出处本来就是"数据的一部分"，紧贴数据；体积大的趋势条
                // （当日概况 / 未来几天 / 逐小时）才是该给趋势让位的那部分。
                const SizedBox(height: Gap.xs),
                Text(
                  _sourceLine(
                    t,
                    region.value,
                    weather.value?.providerId,
                    holidays.value,
                  ),
                  key: const Key('cal-env-source'),
                  // 单行放不下时最多两行 + 省略号：**不给无限行**（会把趋势条挤没），
                  // 也**不是 1 行**（长出处直接丢信息）。
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: DesignPalette.of(context).dim,
                    fontSize: 10,
                  ),
                ),
                if (today != null && isToday && !compact) ...[
                  const SizedBox(height: Gap.xs),
                  Text(
                    t.calEnvDaily(
                      '${today.icon()} ${wmoText(today.code)} '
                      '${_fmtTemp(units.convertTemp(today.minC))}~'
                      '${_fmtTemp(units.convertTemp(today.maxC))}'
                      '${units.temperatureLabel}'
                      '${today.precipitationMm == null || today.precipitationMm == 0 ? '' : ' ${t.calEnvPrecip(units.convertPrecip(today.precipitationMm!).toStringAsFixed(1), units.precipitationLabel)}'}',
                    ),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: DesignPalette.of(context).dim,
                    ),
                  ),
                ],
                if (days.length > 1 && !compact) ...[
                  const SizedBox(height: Gap.sm),
                  SizedBox(
                    // ⚠️ 高度必须跟随 `textScaler`：固定的 62 在 1.3/2.0 缩放下
                    // 装不下 3 行文字（离线实测 RenderFlex overflowed 5px）。这是
                    // D3 同一类问题（固定容器 + 跟随字号的文字），矩阵里因为不注入
                    // 天气而没露出来。
                    height: 62 * MediaQuery.textScalerOf(context).scale(1),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: days.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: Gap.md),
                      itemBuilder: (_, i) {
                        final d = days[i];
                        final dIsToday =
                            d.date.year == nowDate.year &&
                            d.date.month == nowDate.month &&
                            d.date.day == nowDate.day;
                        final dSelected =
                            d.date.year == day.year &&
                            d.date.month == day.month &&
                            d.date.day == day.day;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              dIsToday
                                  ? t.calToday
                                  : _weekdayChars(t)[d.date.weekday % 7],
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: DesignPalette.of(context).dim,
                              ),
                            ),
                            Text(
                              d.icon(),
                              style: const TextStyle(fontSize: 18),
                            ),
                            Text(
                              '${_fmtTemp(units.convertTemp(d.maxC))}/${_fmtTemp(units.convertTemp(d.minC))}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: dSelected
                                    ? theme.colorScheme.primary
                                    : null,
                                fontWeight: dSelected ? FontWeight.w600 : null,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
                // 逐小时（选中日：今天从"现在这一小时"起往后 24 条；其它日子给那天整天）
                // 各天气源不一定都有（见 `WeatherHour` 的注释），没有就整段不显示。
                if (hourList.isNotEmpty) ...[
                  const SizedBox(height: Gap.sm),
                  SizedBox(
                    key: const Key('cal-hourly-strip'),
                    // 3 行（时刻 / 图标 / 温度+降水）刚好 56px；4 行会溢出。
                    // 同未来几天条：高度跟随 `textScaler`，否则 2.0 缩放下 3 行
                    // 文字撑破固定 56（D3 同族问题）。
                    height: 56 * MediaQuery.textScalerOf(context).scale(1),
                    child: ListView.separated(
                      // ⚠️ key 里带日期：换一天要**回到最前面**。真机上这个
                      // ListView 的滚动位置会被复用（同类型同位置），今天滑到
                      // 后半天再点明天，明天就从 6 点开始画（实测踩到）。
                      key: ValueKey(
                        'cal-hours-${day.year}-${day.month}-${day.day}',
                      ),
                      scrollDirection: Axis.horizontal,
                      itemCount: hourList.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: Gap.md),
                      itemBuilder: (_, i) {
                        final h = hourList[i];
                        final isNow = isToday && h.time.hour == nowDate.hour;
                        final pop = h.precipitationProbability;
                        final precip = (pop != null && pop > 0)
                            ? '$pop%'
                            : (h.precipitationMm != null &&
                                  h.precipitationMm! > 0)
                            ? units
                                  .convertPrecip(h.precipitationMm!)
                                  .toStringAsFixed(1)
                            : '';
                        return Column(
                          key: Key('cal-hour-${h.time.hour}'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isNow
                                  ? t.calEnvHourNow
                                  : t.calEnvHour(h.time.hour),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: isNow
                                    ? theme.colorScheme.primary
                                    : DesignPalette.of(context).dim,
                                fontWeight: isNow ? FontWeight.w600 : null,
                              ),
                            ),
                            Text(
                              h.icon(),
                              style: const TextStyle(fontSize: 16),
                            ),
                            // 温度和降水概率**同一行**：分成两行会溢出
                            // （62px 的条里 4 行实测溢出 4px，widget 测试抓到的）
                            Text.rich(
                              TextSpan(
                                text:
                                    '${_fmtTemp(units.convertTemp(h.temperatureC))}°',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: isNow ? FontWeight.w600 : null,
                                ),
                                children: [
                                  if (precip.isNotEmpty)
                                    TextSpan(
                                      text: ' $precip',
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        fontSize: 9,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
                if (dayHolidays.isNotEmpty) ...[
                  const SizedBox(height: Gap.sm),
                  Wrap(
                    spacing: Gap.sm,
                    runSpacing: Gap.xxs,
                    children: [
                      for (final h in dayHolidays)
                        Text(
                          _holidayLabel(t, h),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: h.kind == HolidayKind.workday
                                ? theme.colorScheme.error
                                : DesignPalette.of(context).dim,
                          ),
                        ),
                    ],
                  ),
                ],
                if (holidays.value?.note.isNotEmpty ?? false) ...[
                  const SizedBox(height: Gap.xxs),
                  Text(
                    holidays.value!.note,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: DesignPalette.of(context).dim,
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _sourceLine(
    AppText t,
    RegionContext? region,
    String? weatherProviderId,
    HolidayBundle? holidays,
  ) {
    final provider = weatherProviderById(weatherProviderId);
    final parts = <String>[
      region == null ? t.calEnvRegionPending : region.label,
      if (provider != null) t.calEnvSourceWeather(provider.nameText()),
      // ★★★ D70（r349 真机像素）：这里原本是 `holidays.sources.join('+')`
      // ——`sources` 是**聚合器给的原始 id**，于是界面上直接出现
      // `节假日 nager+lunar`（内部供应方代号当用户文案）。
      // 上一行的**天气源**走的是 `provider.nameText()`（本地化名字），
      // 只有节假日这一条漏了；`HolidaySource.labelText()` 本来就存在却没有 caller。
      // 认不出的 id 原样显示（不编造名字）。
      if (holidays != null && holidays.sources.isNotEmpty)
        t.calEnvSourceHoliday(HolidaySource.sourceLabels(holidays.sources)),
    ];
    return parts.join(' · ');
  }

  static String _fmtTemp(double v) => v.toStringAsFixed(v.abs() >= 100 ? 0 : 0);

  /// 日出/日落：源里有 `05:48` 也有 ISO（`2026-09-23T05:48`），统一显示成 `HH:mm`
  static String _clockOf(String raw) => clockText(raw);
}

/// 星期几的单字简写（0=周日 … 6=周六），与日历页同口径。
List<String> _weekdayChars(AppText t) => [
  t.calWeekdayMinSun,
  t.calWeekdayMinMon,
  t.calWeekdayMinTue,
  t.calWeekdayMinWed,
  t.calWeekdayMinThu,
  t.calWeekdayMinFri,
  t.calWeekdayMinSat,
];

/// 节日行文案：`预计 ` 前缀 + 名称 + 调休上班后缀。
String _holidayLabel(AppText t, HolidayEntry h) {
  final name =
      '${h.displayName}'
      '${h.kind == HolidayKind.workday ? t.calEnvWorkdaySuffix : ''}';
  return h.approximate ? t.calEnvApprox(name) : name;
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withValues(alpha: 0.5), width: 0.8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 10, color: color, height: 1.1),
    ),
  );
}

/// 环境信息设置面板
Future<void> showCalendarEnvSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _CalendarEnvSheet(),
  );
}

class _CalendarEnvSheet extends ConsumerStatefulWidget {
  const _CalendarEnvSheet();

  @override
  ConsumerState<_CalendarEnvSheet> createState() => _CalendarEnvSheetState();
}

class _CalendarEnvSheetState extends ConsumerState<_CalendarEnvSheet> {
  /// "用当前位置"按钮的转圈状态
  bool locating = false;

  late final TextEditingController _key;
  late final TextEditingController _place;
  List<GeoSuggestion> _hits = const [];
  bool _searching = false;
  String? _placeError;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(
      text: ref.read(calendarEnvProvider).qweatherKey,
    );
    _place = TextEditingController();
  }

  @override
  void dispose() {
    _key.dispose();
    _place.dispose();
    super.dispose();
  }

  /// 搜地名 → 给候选（用户点一个才写库）。
  ///
  /// **不猜也不编**：搜不到就如实说"没找到"，不悄悄塞一个默认城市。
  Future<void> _searchPlace() async {
    final t = context.t;
    final q = _place.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _placeError = null;
    });
    try {
      final hits = await ref.read(geocodeClientProvider).search(q, count: 5);
      if (!mounted) return;
      setState(() {
        _hits = [
          for (final h in hits)
            if (h.latitude != null) h,
        ];
        _searching = false;
        if (_hits.isEmpty) _placeError = t.calEnvPlaceNotFound;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _placeError = t.calEnvSearchFailed(userFacingError(e));
      });
    }
  }

  Future<void> _usePlace(GeoSuggestion hit) async {
    await ref
        .read(calendarEnvProvider.notifier)
        .setManualPlace(
          name: hit.name,
          latitude: hit.latitude!,
          longitude: hit.longitude!,
          countryCode: hit.countryCode,
        );
    if (!mounted) return;
    setState(() {
      _hits = const [];
      _place.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t;
    final settings = ref.watch(calendarEnvProvider);
    final region = ref.watch(calendarRegionProvider).value;
    final units = ref.watch(weatherUnitsProvider);
    // 定位：`fix` 可能还在路上（GPS 慢），所以 UI 要能显示"正在定位"
    final fixAsync = ref.watch(deviceLocationProvider);
    final fix = fixAsync.value;
    final locatingNow = locating || fixAsync.isLoading;
    final locPermission = ref.watch(locationPermissionProvider).value;
    final provider = pickProviderFor(
      region: region ?? const RegionContext(),
      settings: settings,
    );

    // ⚠️ 用 ListView 而不是 `SingleChildScrollView > Column`：后者在
    // showModalBottomSheet 里会让 Row 里的按钮拿到**无界宽度**约束
    // （实测报 "BoxConstraints forces an infinite width"）。项目里其它
    // bottom sheet（AI 厂商选择）也是这个写法。
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            Gap.lg,
            Gap.lg,
            Gap.lg,
            MediaQuery.of(context).viewInsets.bottom + Gap.lg,
          ),
          children: [
            Text(t.calEnvTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(
              region == null ? t.calEnvRegionPendingDots : region.label,
              style: theme.textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
            ),
            const SizedBox(height: Gap.md),

            // ---- 跟随手机定位（默认开）----
            DesignSwitchRow(
              key: const Key('cal-env-autolocate'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: settings.autoLocate,
              title: Text(t.calEnvAutoLocate),
              subtitle: Text(
                settings.autoLocate
                    ? (locatingNow
                          ? t.calEnvLocating
                          : (fix == null
                                ? (locPermission == LocationPermission.granted
                                      ? t.calEnvNoFix
                                      : t.calEnvNoPermission)
                                : t.calEnvLocated(
                                        '${fix.latitude.toStringAsFixed(3)}, '
                                        '${fix.longitude.toStringAsFixed(3)}',
                                      ) +
                                      (fix.accuracyM == null
                                          ? ''
                                          : ' · ${t.calEnvAccuracy(fix.accuracyM!.toStringAsFixed(0))}')))
                    : t.calEnvLocateOff,
                style: theme.textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
              ),
              onChanged: (on) =>
                  ref.read(calendarEnvProvider.notifier).setAutoLocate(on),
            ),
            if (settings.autoLocate)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('cal-env-locate-now'),
                  onPressed: locatingNow
                      ? null
                      : () async {
                          setState(() => locating = true);
                          try {
                            // 交互式申请权限 → 丢掉缓存 → 重新取一次
                            await ref
                                .read(deviceLocationProbeProvider)
                                .ensurePermission();
                            await ref
                                .read(calendarEnvProvider.notifier)
                                .setAutoLocate(true);
                            ref.invalidate(locationPermissionProvider);
                            ref.invalidate(calendarRegionProvider);
                            ref.invalidate(weatherBundleProvider);
                          } finally {
                            if (mounted) setState(() => locating = false);
                          }
                        },
                  icon: const Icon(Icons.my_location, size: 18),
                  label: Text(
                    locatingNow ? t.calEnvLocateButton : t.calEnvUseCurrent,
                  ),
                ),
              ),
            const SizedBox(height: Gap.xs),

            _label(t.calEnvPlaceLabel, DesignPalette.of(context).dim),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('cal-env-place-query'),
                    controller: _place,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: t.calEnvPlaceHint,
                    ),
                    onSubmitted: (_) => _searchPlace(),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                TextButton(
                  key: const Key('cal-env-place-search'),
                  onPressed: _searching ? null : _searchPlace,
                  child: Text(_searching ? t.calEnvSearching : t.calEnvSearch),
                ),
              ],
            ),
            if (settings.hasManualPlace)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.calEnvPlaceCurrent(
                          settings.manualPlaceName,
                          settings.manualLatitude!.toStringAsFixed(2),
                          settings.manualLongitude!.toStringAsFixed(2),
                        ),
                        key: const Key('cal-env-place-current'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: DesignPalette.of(context).dim,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('cal-env-place-clear'),
                      onPressed: () => ref
                          .read(calendarEnvProvider.notifier)
                          .clearManualPlace(),
                      child: Text(t.calEnvClear),
                    ),
                  ],
                ),
              ),
            for (final hit in _hits)
              DesignRowTile(
                key: Key('cal-env-place-hit-${hit.name}'),
                dense: true,
                title: Text(hit.name),
                subtitle: Text(
                  [
                    hit.admin1,
                    hit.countryCode,
                  ].where((x) => x.isNotEmpty).join(' · '),
                ),
                onTap: () => _usePlace(hit),
              ),
            if (_placeError != null)
              Text(
                _placeError!,
                key: const Key('cal-env-place-error'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            const SizedBox(height: Gap.md),

            _label(t.calEnvRegion, DesignPalette.of(context).dim),
            Wrap(
              spacing: Gap.sm,
              children: [
                ChoiceChip(
                  key: const Key('cal-env-region-auto'),
                  label: Text(t.calEnvAuto),
                  selected: settings.countryOverride.isEmpty,
                  onSelected: (_) => ref
                      .read(calendarEnvProvider.notifier)
                      .setCountryOverride(''),
                ),
                for (final cc in kRegionPickerCountries)
                  ChoiceChip(
                    label: Text(countryName(cc)),
                    selected: settings.countryOverride == cc,
                    onSelected: (_) => ref
                        .read(calendarEnvProvider.notifier)
                        .setCountryOverride(cc),
                  ),
              ],
            ),
            const SizedBox(height: Gap.md),

            DesignSwitchRow(
              key: const Key('cal-env-weather-bg'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: settings.weatherBackground,
              title: Text(t.calEnvWeatherBg),
              subtitle: Text(
                t.calEnvWeatherBgHint,
                style: theme.textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
              ),
              onChanged: (on) => ref
                  .read(calendarEnvProvider.notifier)
                  .setWeatherBackground(on),
            ),
            const SizedBox(height: Gap.sm),

            _label(t.calEnvUnitsLabel, DesignPalette.of(context).dim),
            Wrap(
              spacing: Gap.sm,
              children: [
                for (final u in UnitSystem.values)
                  ChoiceChip(
                    key: Key('cal-env-units-${u.id}'),
                    label: Text(
                      u == UnitSystem.auto
                          ? t.calEnvUnitsByRegion
                          : u.labelText(),
                    ),
                    selected: settings.unitsOverride == u,
                    onSelected: (_) => ref
                        .read(calendarEnvProvider.notifier)
                        .setUnitsOverride(u.id),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(
                t.calEnvUnitsSummary(
                  units.temperatureLabel,
                  units.wind.labelText(),
                  units.precipitationLabel,
                  units.pressureLabel,
                  units.visibilityLabel,
                ),
                style: theme.textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
              ),
            ),
            const SizedBox(height: Gap.md),

            _label(t.calEnvWeatherSource, DesignPalette.of(context).dim),
            Wrap(
              spacing: Gap.sm,
              children: [
                ChoiceChip(
                  key: const Key('cal-env-weather-auto'),
                  label: Text(t.calEnvAuto),
                  selected: settings.forcedWeatherProviderId.isEmpty,
                  onSelected: (_) => ref
                      .read(calendarEnvProvider.notifier)
                      .setForcedWeatherProvider(''),
                ),
                for (final p in kWeatherProviders)
                  ChoiceChip(
                    label: Text(p.nameText()),
                    selected: settings.forcedWeatherProviderId == p.id,
                    onSelected: (_) => ref
                        .read(calendarEnvProvider.notifier)
                        .setForcedWeatherProvider(p.id),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(
                provider == null
                    ? t.calEnvNoProvider
                    : '${t.calEnvUsingProvider(provider.nameText())}'
                          '${provider.noteText().isEmpty ? '' : ' —— ${provider.noteText()}'}',
                style: theme.textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
              ),
            ),
            const SizedBox(height: Gap.md),

            _label(t.calEnvQweatherKeyLabel, DesignPalette.of(context).dim),
            TextField(
              key: const Key('cal-env-qweather-key'),
              controller: _key,
              obscureText: true,
              decoration: InputDecoration(
                isDense: true,
                hintText: t.calEnvQweatherKeyHint,
              ),
              onSubmitted: (v) =>
                  ref.read(calendarEnvProvider.notifier).setQweatherKey(v),
            ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                // ⚠️ 主题里 FilledButton 的 minimumSize 是 `Size.fromHeight(48)`（全宽），
                // 放进 Row 必须**显式给宽度**，否则渲染层直接报
                // "BoxConstraints forces an infinite width"（我是先在这里踩的）
                Flexible(
                  child: FilledButton.tonal(
                    key: const Key('cal-env-save-key'),
                    onPressed: () async {
                      await ref
                          .read(calendarEnvProvider.notifier)
                          .setQweatherKey(_key.text);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t.calEnvQweatherKeySaved)),
                      );
                    },
                    child: Text(t.calEnvSaveKey),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Text(
                  settings.hasQweatherKey
                      ? t.calEnvKeyConfigured
                      : t.calEnvKeyMissing,
                  style: theme.textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
                ),
              ],
            ),
            const SizedBox(height: Gap.md),

            _label(t.calEnvHolidaySources, DesignPalette.of(context).dim),
            Text(
              t.calEnvHolidaySourcesNote,
              style: theme.textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
            ),
            const SizedBox(height: Gap.md),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () {
                    ref.invalidate(weatherBundleProvider);
                    ref.invalidate(holidayBundleProvider);
                    ref.invalidate(calendarRegionProvider);
                    Navigator.of(context).maybePop();
                  },
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(t.calEnvRefetch),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(t.calEnvDone),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.xs),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: color, letterSpacing: 0.6),
    ),
  );
}
