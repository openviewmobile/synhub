// 日历页（Synology Calendar，P3）。
//
// 官方**没有日历安卓 App**（见 docs/client-station-plan.md §4.7），所以形态以
// **包内 Web UI** 为准（`/tmp/spk/export_Calendar/ui/synocalendar-app.js`），
// 参数逐条真机验证过（docs/api-server-authoritative.md §18）。
//
// 本轮范围（普通用户 L1）：月视图（6 行网格）+ 选中日事件列表 + 新建/删除事件 +
// 日历分组勾选 + 待办只读。周/日视图、重复事件、邀请、附件后置。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/text_fit.dart';
import '../../data/calendar_api.dart';
import '../../data/dto/calendar_dto.dart';
import '../../data/weather/weather_client.dart';
import 'calendar_env.dart';
import 'weather_backdrop.dart';
import 'calendar_env_card.dart';
import 'calendar_providers.dart';
import 'calendar_settings_sheet.dart';
import 'calendar_todo_search_sheet.dart';
import 'calendar_todo_sheet.dart';
import '../../core/user_facing_error.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  @override
  void initState() {
    super.initState();
    // 环境信息设置（地区/单位/天气源/和风 key）要在第一帧之后才能读
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(calendarEnvProvider.notifier).preload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final setting = ref.watch(calSettingProvider);
    final calendars = ref.watch(calendarsProvider);
    final anchor = ref.watch(calendarAnchorProvider);
    final day = ref.watch(selectedDayProvider);
    final events = ref.watch(monthEventsProvider);
    final weekStart = weekStartWeekday(setting.value?.weekStartDay ?? 0);
    final viewMode = ref.watch(calendarViewModeProvider);
    // 整页天气背景：拿"选中那天"的天气码（今天优先用实况，更贴近窗外）
    final env = ref.watch(calendarEnvProvider);
    final weather = ref.watch(weatherBundleProvider).value;
    final scene = _sceneFor(day, weather);
    // 能力位降级：`SYNO.Cal.Todo` 缺失时只藏「待办」新建入口（待办嵌在当日列表里，
    // 无法整块隐藏；列表本身在 API 缺失时为空），日程功能照常可用。
    final canTodo = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.calendar, kCalTodoApi);

    return Scaffold(
      backgroundColor: DesignPalette.of(context).bg,
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('cal-new-event'),
        icon: const Icon(Icons.add),
        label: Text(context.t.calEventFab),
        onPressed: calendars.value == null
            ? null
            : () => _openEditor(context, calendars.value!),
      ),
      body: WeatherBackdrop(
          scene: scene,
          enabled: env.weatherBackground,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  _Header(
                    anchor: anchor,
                    busy: setting.isLoading || calendars.isLoading,
                    // 日历列表**加载失败**要如实说，不能渲染成"没有日历"：
                    // 真机上 `Cal/list` 不带 `cal_type` 回 **9009
                    // error:invalid_parameter**（包内 `ui/syno-cal-err-code.json`），
                    // 那是参数错误、可重试，**不是**"这个账号没有日历"。
                    // 放在副标题里（**不新增一行**）：页面在 360×640 + 2.0 文字缩放下
                    // 已经贴边，多一行会让整页 Column 溢出（`ui_overflow_audit` 会红）。
                    errorText: calendars.hasError
                        ? describeCalendarError(calendars.error!)
                        : null,
                    onPrev: () =>
                        ref.read(calendarAnchorProvider.notifier).shift(-1),
                    onNext: () =>
                        ref.read(calendarAnchorProvider.notifier).shift(1),
                    onToday: () =>
                        ref.read(calendarAnchorProvider.notifier).today(),
                    onPickCalendars: () => _openCalendarPicker(
                      context,
                      calendars.value ?? const [],
                      failed: calendars.hasError,
                    ),
                    onRefresh: () {
                      ref.invalidate(calendarsProvider);
                      ref.invalidate(calSettingProvider);
                      ref.invalidate(monthEventsProvider);
                      ref.invalidate(calTodosProvider);
                      // wave1：配色 / 时区 / 共享 / 待办计数一起刷（都是本轮加的）
                      ref.invalidate(calEventColorsProvider);
                      ref.invalidate(calTimezoneListProvider);
                      ref.invalidate(calTodoUncompletedCountProvider);
                      ref.invalidate(calSharePrincipalsProvider);
                    },
                  ),
                  _ViewSwitcher(
                    mode: viewMode,
                    onPick: (m) {
                      ref.read(calendarViewModeProvider.notifier).set(m);
                      // 使用日志：视图模式偏好（月/周/日）
                      trackViewMode(UsageModule.calendar, m.name);
                    },
                  ),
                  // 换页导航：月=按月，周=按周，日=按天（都是同一套锚点/选中日）
                  _MonthNav(
                    anchor: anchor,
                    mode: viewMode,
                    day: day,
                    onPrev: () => _shiftPeriod(-1),
                    onNext: () => _shiftPeriod(1),
                  ),
                  if (viewMode == CalendarViewMode.month) ...[
                    _WeekdayHeader(labels: _weekdayLabels(context.t)),
                    // 月视图：**左右滑动换月**（拖到上/下月就 jumpTo，手势细节见
                    // `_MonthPager` 的注释；按钮与手势共用同一个锚点）
                    _MonthPager(
                      anchor: anchor,
                      weekStart: weekStart,
                      selected: day,
                      height: monthGridHeightFor(constraints.maxHeight),
                      onPick: (d) {
                        ref.read(selectedDayProvider.notifier).select(d);
                        if (d.month != anchor.month) {
                          ref
                              .read(calendarAnchorProvider.notifier)
                              .jumpTo(DateTime(d.year, d.month));
                        }
                      },
                    ),
                    const Divider(height: 1),
                  ] else if (viewMode == CalendarViewMode.week) ...[
                    const Divider(height: 1),
                    _WeekBoard(
                      weekStart: weekStart,
                      day: day,
                      events: events,
                      calendars: calendars.value ?? const [],
                      onPickDay: (d) =>
                          ref.read(selectedDayProvider.notifier).select(d),
                      onOpen: (e) => _openDetail(context, e),
                      onNew: calendars.value == null
                          ? null
                          : (d) =>
                                _openEditor(context, calendars.value!, day: d),
                    ),
                    const Divider(height: 1),
                  ],
                  Expanded(
                    child: _DayList(
                      day: day,
                      events: events,
                      onRetry: () => ref.invalidate(monthEventsProvider),
                      onOpen: (e) => _openDetail(context, e),
                      calendars: calendars.value ?? const [],
                      todos: ref.watch(calTodosProvider).value ?? const [],
                      onNew: calendars.value == null
                          ? null
                          : () => _openEditor(
                              context,
                              calendars.value!,
                              day: day,
                            ),
                      compact: constraints.maxHeight < 900,
                      // 日视图：整页就是这一天，事件行带**时间刻度**（官方日视图的样子）
                      showTimeGutter: viewMode == CalendarViewMode.day,
                      onOpenTodo: (t) => _openTodoEditor(context, todo: t),
                      onToggleTodo: (t) => _toggleTodo(context, t),
                      onNewTodo: canTodo
                          ? () => _openTodoEditor(context, day: day)
                          : null,
                      // wave2：待办搜索（`Todo/search` v1）。**同一个 `canTodo`
                      // 门控**（`SYNO.Cal.Todo` 不在能力表 → 连搜索入口都不显示，
                      // 不给"点了必然失败"的按钮）。
                      onSearchTodo: canTodo
                          ? () => _openTodoSearch(context)
                          : null,
                      // wave1：**服务端**的未完成待办数量（`Todo/count_todo`）。
                      // null = 拿不到 → 角标不显示；**绝不写死 0**
                      // （写死会把"接口挂了"显示成"待办清空了"，见 falsification ②）。
                      todoCount: ref
                          .watch(calTodoUncompletedCountProvider)
                          .value,
                      onCleanDone: () => _cleanDoneTodos(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    );
  }

  /// 选中那天的天气 → 背景种类。
  ///
  /// * 今天是看**实况**（`now.code`，更贴近窗外），其它日子看那天的预报码；
  /// * 拿不到天气就回 [WeatherScene.cloudy]（中性、不抢眼）；
  /// * 晴天的夜里换星空（只在今天用日出日落判断，其它日期不知道用户几点看）。
  WeatherScene _sceneFor(DateTime day, WeatherBundle? bundle) {
    if (bundle == null) return WeatherScene.cloudy;
    final now = DateTime.now();
    final isToday =
        day.year == now.year && day.month == now.month && day.day == now.day;
    final code = isToday && bundle.now != null
        ? bundle.now!.code
        : bundle.dayOf(day)?.code;
    if (code == null) return WeatherScene.cloudy;
    var scene = weatherSceneForCode(code);
    final d = bundle.dayOf(day);
    if (scene == WeatherScene.clearDay &&
        d != null &&
        isNightNow(sunrise: d.sunrise, sunset: d.sunset, now: now)) {
      scene = WeatherScene.clearNight;
    }
    return scene;
  }

  Future<void> _openCalendarPicker(
    BuildContext context,
    List<CalendarDto> calendars, {
    bool failed = false,
  }) async {
    final t = context.t;
    final picked = ref.read(selectedCalIdsProvider);
    // 能力位（C4）：`SYNO.Cal.AuthForeign` 存在时才显示"外部日历"那条说明。
    final canExternalCal = ref
        .read(serviceAvailabilityProvider)
        .hasApi(StationService.calendar, kCalAuthForeignApi);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DesignRowTile(
                title: Text(t.wsCalendar),
                trailing: TextButton(
                  onPressed: () {
                    ref.read(selectedCalIdsProvider.notifier).clear();
                    // 使用日志：筛选偏好（日历来源=全部）
                    trackFilter(UsageModule.calendar, key: 'calendar', value: 'all');
                    setSheetState(() {});
                  },
                  child: Text(t.calSelectAll),
                ),
              ),
              // 勾选 = 只看这些日历；空集 = 全部（和官方默认一致）
              for (final c in calendars)
                DesignCheckRow(
                  value: picked.isEmpty || picked.contains(c.calId),
                  title: Text(c.displayName),
                  subtitle: Text(
                    c.canWrite ? t.calCanWrite : t.dtoNotePermReadOnly,
                  ),
                  secondary: _CalDot(color: c.color),
                  onChanged: (_) {
                    ref.read(selectedCalIdsProvider.notifier).toggle(c.calId);
                    // 使用日志：日历来源选择（稳定 id + kind=calendar）
                    trackSelect(
                      UsageModule.calendar,
                      c.calId,
                      kind: 'calendar',
                    );
                    setSheetState(() {});
                  },
                ),
              // 空列表 = **真的没有日历**（服务端回 0 条），给一句空态；
              // "加载失败"**不混进来** —— 失败由页面上的 `_CalErrorBar` 单独提示。
              if (calendars.isEmpty && !failed)
                DesignRowTile(
                  dense: true,
                  leading: const Icon(Icons.event_busy_outlined, size: 18),
                  title: Text(dataText('calNoCalendars', '这个账号还没有日历。')),
                ),
              // 加载失败时在弹层里也照实说（不能借"没有日历"糊过去）
              if (calendars.isEmpty && failed)
                DesignRowTile(
                  dense: true,
                  leading: const Icon(Icons.error_outline, size: 18),
                  title: Text(
                    dataText('calPickerLoadFailed', '日历列表加载失败，请先返回重试。'),
                  ),
                ),
              // 外部日历（Google 等）——**说明入口，不发请求**：
              // 官方链路是 `AuthForeign/create`（Google OAuth，写）+
              // `Proxy/cal_list {auth_id}`；真机上 `AuthForeign/list` 回 117
              // （连已连接账号都列不出来），参数链未取证 ⇒ 给"暂不支持 + 原因"，
              // **不给会失败的按钮**（见 docs/calendar-contacts-c4.md）。
              if (canExternalCal)
                DesignRowTile(
                  key: const Key('cal-external-info'),
                  dense: true,
                  leading: const Icon(Icons.cloud_off_outlined, size: 18),
                  title: Text(dataText('calExternalCalendars', '外部日历（Google 等）')),
                  // ★★★ D71（r349 真机像素）：这条原本是**开发者语言**——
                  // `暂不支持：服务端接口的参数链未取证（真机对 AuthForeign/list
                  // 回 117），请先用官方网页端连接。` —— 裸 API 路径 + 裸错误码
                  // 摊在用户面前，用户**无法据此做任何事**。
                  // ⇒ 用户文案只说"能做什么"；技术依据留在**这里**（不丢知识）：
                  //   对 `SYNO.Cal.AuthForeign:list` 真机回 `117`（参数链未取证），
                  //   连已连接账号都列不出来 ⇒ 不给会失败的按钮（见
                  //   `docs/calendar-contacts-c4.md`）。
                  // ★ 注意 **ARB 与 Dart 兜底字面量是两份生产者**：只改 ARB
                  //   = 留下整条旁路（§2.0.65 守卫通式 D60）。
                  subtitle: Text(
                    dataText(
                      'calExternalCalendarsUnsupported',
                      '暂不支持：请先在官方网页端连接这个日历。',
                    ),
                  ),
                ),
              // wave1：日历设置（配色 / 时区 / 共享 / 只读设置 / 导入说明）。
              //
              // ⚠️ 放在这个**已有的**弹层里，不往 `_Header` 加图标按钮：
              // 头部的 Row 在 360×640 / en / x2.0 下已经贴边，多一个 IconButton
              // 会横向溢出 36px（`calendar_d3_env_card_test.dart` 实测）。
              const Divider(height: 1),
              DesignRowTile(
                key: const Key('cal-settings'),
                dense: true,
                leading: const Icon(Icons.tune, size: 18),
                title: Text(dataText('calSettingsTitle', '日历设置')),
                subtitle: Text(
                  dataText(
                    'calSettingsSubtitle',
                    '配色 / 时区 / 共享日历 / 用户设置（只读）',
                  ),
                ),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  if (context.mounted) {
                    await showCalendarSettingsSheet(context, ref);
                  }
                },
              ),
              const SizedBox(height: Gap.sm),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDetail(BuildContext context, CalEventDto event) async {
    final t = context.t;
    final calendars = ref.read(calendarsProvider).value ?? const [];
    final calendar = _findCalendar(calendars, event.calId);
    final canWrite = calendar?.canWrite ?? true;
    final action = await showModalBottomSheet<_EventDetailAction>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (ctx) => _EventDetailSheet(event: event, canWrite: canWrite),
    );
    if (action == null || !context.mounted) return;
    if (action == _EventDetailAction.editOnce ||
        action == _EventDetailAction.editSeries) {
      await _openEditEvent(
        event,
        wholeSeries: action == _EventDetailAction.editSeries,
      );
      return;
    }
    try {
      final api = ref.read(calendarApiProvider)!;
      if (action == _EventDetailAction.thisOnly) {
        // 重复事件：只把这一次从系列里排除（母事件不动，其它几次照常）
        // 参数照包内 Web UI 的 `_deleteSingleEvt`：`{evt_id, dav_etag, exdate}`，
        // `exdate` 优先用服务端给的 `recurrence_id`，没有就退化成这次的开始串。
        await api.setEventExdate(
          evtId: event.evtId,
          davEtag: event.davEtag,
          exdate: event.recurrenceId.isNotEmpty
              ? event.recurrenceId
              : event.dtstartString,
        );
        _invalidateEvents();
        if (context.mounted) {
          AppSnack.show(context, t.calDeletedOnce(event.summary));
        }
      } else {
        await api.deleteEvent(event.evtId);
        _invalidateEvents();
        if (context.mounted) {
          AppSnack.show(
            context,
            action == _EventDetailAction.wholeSeries
                ? t.calDeletedSeries(event.summary)
                : t.calDeleted(event.summary),
          );
        }
      }
      track(
        ref,
        UsageModule.calendar,
        UsageAction.delete,
        objectType: 'event',
        detail: {
          if (event.isRepeatEvt)
            'repeat': action == _EventDetailAction.thisOnly ? 'this' : 'series',
        },
      );
    } catch (e) {
      if (context.mounted) {
        AppSnack.show(context, t.calDeleteFailed(userFacingError(e)), error: true);
      }
    }
  }

  /// 编辑日程：`Event/set`（整条 / 整个系列）或 `Event/subevent_set`（只改这一次）。
  ///
  /// 母事件的开始时间**必须问服务端**（`Event/get(evt_id)`）：真机探针确认
  /// `Event/get` 拿到的就是母事件（`dtstart_string` = 系列起点、`is_repeat_evt=true`、
  /// 带 `repeat_setting`）。不能拿列表里"最早的那一行"凑 —— 列表是按当前月份取的，
  /// 系列起点常常不在这个范围内，会把整个系列整体挪到一个月里。
  ///
  /// "单独改过的那一次"在列表里 `is_repeat_evt` 会消失（见 `isSeriesMember` 注释），
  /// 所以这里一律用 [CalEventDto.isSeriesMember] 判定，避免把系列当一次性事件改。
  /// 周/日视图的翻页：动的是"选中日"，同时把聚焦月份跟上
  /// （事件是按 `monthEventsOfProvider(锚点月)` 取的，跨月时要让锚点跟着走）。
  void _shiftPeriod(int direction) {
    final mode = ref.read(calendarViewModeProvider);
    if (mode == CalendarViewMode.month) {
      ref.read(calendarAnchorProvider.notifier).shift(direction);
      return;
    }
    final step = mode == CalendarViewMode.week ? 7 : 1;
    final day = ref
        .read(selectedDayProvider)
        .add(Duration(days: step * direction));
    ref.read(selectedDayProvider.notifier).select(day);
    final anchor = ref.read(calendarAnchorProvider);
    if (day.year != anchor.year || day.month != anchor.month) {
      ref.read(calendarAnchorProvider.notifier).jumpTo(day);
    }
  }

  Future<void> _openEditEvent(
    CalEventDto event, {
    required bool wholeSeries,
  }) async {
    final t = context.t;
    final calendars = ref.read(calendarsProvider).value ?? const [];
    final writable = [
      for (final c in calendars)
        if (c.canWrite) c,
    ];
    if (writable.isEmpty) {
      if (mounted) {
        AppSnack.show(context, t.calNoWritableCalendar, error: true);
      }
      return;
    }
    final api = ref.read(calendarApiProvider);
    if (api == null) return;

    // 只改这一次：就用这一行（`recurrence_id` 标出是哪一次）
    final thisOnly = !wholeSeries && event.isSeriesMember;
    var source = event;
    if (!thisOnly) {
      // 母事件：优先问服务端（权威），失败再退回"列表里 recurrence_id 为空的最早一行"
      masterFallback() {
        int at(CalEventDto e) =>
            (e.start ?? DateTime.fromMillisecondsSinceEpoch(e.dtstart * 1000))
                .millisecondsSinceEpoch;
        final same =
            (ref.read(monthEventsProvider).value ?? const <CalEventDto>[])
                .where((e) => e.evtId == event.evtId && !e.isOverriddenInstance)
                .toList()
              ..sort((a, b) => at(a).compareTo(at(b)));
        return same.isEmpty ? null : same.first;
      }

      if (event.isSeriesMember) {
        try {
          source = await api.event(event.evtId) ?? masterFallback() ?? event;
        } catch (_) {
          source = masterFallback() ?? event;
        }
        if (!mounted) return;
      }
    }

    final setting = ref.read(calSettingProvider).value;
    final draft = await showModalBottomSheet<_EventDraft>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (ctx) => _EventEditorSheet(
        calendars: writable,
        day: source.start ?? ref.read(selectedDayProvider),
        defaultTimeZone: source.tzId.isNotEmpty
            ? source.tzId
            : (setting?.timeZone ?? ''),
        editing: source,
        // "编辑本次"时重复规则属于整个系列，不许改
        lockRepeat: thisOnly,
      ),
    );
    if (draft == null || !mounted) return;
    final cal = draft.calendar;
    final orgId = cal.originalCalId.isEmpty ? cal.calId : cal.originalCalId;
    // 兜底：编辑系列时绝不能把重复规则丢掉（丢了这个系列就塌成一次性事件）
    final repeat =
        draft.repeat ?? (source.isSeriesMember ? source.repeat : null);
    try {
      if (thisOnly) {
        await api.updateSubEvent(
          instance: source,
          calendarId: cal.calId,
          originalCalendarId: orgId,
          summary: draft.summary,
          start: draft.start,
          end: draft.end,
          isAllDay: draft.isAllDay,
          timeZone: draft.timeZone,
          description: draft.description,
          // wave1：配色（`Event/set`/`subevent_set` 同样把 color 带上，
          // 不带服务端会按"要清空"处理 → 退回日历默认色）
          color: draft.color,
        );
        if (mounted) AppSnack.show(context, t.calUpdatedOnce(draft.summary));
      } else {
        await api.updateEvent(
          source: source,
          calendarId: cal.calId,
          originalCalendarId: orgId,
          summary: draft.summary,
          start: draft.start,
          end: draft.end,
          isAllDay: draft.isAllDay,
          timeZone: draft.timeZone,
          description: draft.description,
          color: draft.color,
          repeat: repeat,
          // 受邀人整体提交（`Event/set` 的 participant 是"整体替换"）
          participants: draft.participants,
        );
        if (mounted) {
          AppSnack.show(
            context,
            source.isSeriesMember
                ? t.calUpdatedSeries(draft.summary)
                : t.calUpdated(draft.summary),
          );
        }
      }
      track(
        ref,
        UsageModule.calendar,
        UsageAction.edit,
        objectType: 'event',
        detail: {
          'all_day': draft.isAllDay,
          if (source.isSeriesMember) 'repeat': wholeSeries ? 'series' : 'this',
        },
      );
      _invalidateEvents();
    } catch (e) {
      if (mounted) AppSnack.show(context, t.calUpdateFailed(userFacingError(e)), error: true);
    }
  }

  Future<void> _openEditor(
    BuildContext context,
    List<CalendarDto> calendars, {
    DateTime? day,
  }) async {
    final t = context.t;
    final writable = [
      for (final c in calendars)
        if (c.canWrite) c,
    ];
    if (writable.isEmpty) {
      AppSnack.show(context, t.calNoWritableCalendar, error: true);
      return;
    }
    final setting = ref.read(calSettingProvider).value;
    final draft = await showModalBottomSheet<_EventDraft>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (ctx) => _EventEditorSheet(
        calendars: writable,
        day: day ?? ref.read(selectedDayProvider),
        // wave1：设置页选过的"新建默认时区"优先；没选过就用 `Setting/get` 的值
        defaultTimeZone:
            ref.read(calDefaultTimeZoneProvider).isNotEmpty
            ? ref.read(calDefaultTimeZoneProvider)
            : (setting?.timeZone ?? ''),
      ),
    );
    if (draft == null || !context.mounted) return;
    try {
      final api = ref.read(calendarApiProvider)!;
      final created = await api.createEvent(
        calendarId: draft.calendar.calId,
        originalCalendarId: draft.calendar.originalCalId.isEmpty
            ? draft.calendar.calId
            : draft.calendar.originalCalId,
        summary: draft.summary,
        start: draft.start,
        end: draft.end,
        isAllDay: draft.isAllDay,
        timeZone: draft.timeZone,
        description: draft.description,
        // wave1：配色（空串 = 用日历默认色；候选只来自 `Event/list_color`）
        color: draft.color,
        repeat: draft.repeat,
        participants: draft.participants,
      );
      // 使用日志：建日程（只记动作和类型，不记标题）
      track(
        ref,
        UsageModule.calendar,
        UsageAction.create,
        objectType: 'event',
        detail: {'all_day': draft.isAllDay},
      );
      // 建完就把视图挪到它那天，用户立刻能看到
      final at = created.start ?? draft.start;
      ref.read(selectedDayProvider.notifier).select(at);
      ref
          .read(calendarAnchorProvider.notifier)
          .jumpTo(DateTime(at.year, at.month));
      _invalidateEvents();
      if (context.mounted) AppSnack.show(context, t.calCreated(draft.summary));
    } catch (e) {
      if (context.mounted) {
        AppSnack.show(context, t.calCreateFailed(userFacingError(e)), error: true);
      }
    }
  }

  /// wave2：搜索待办（`Todo/search` v1）。选中一条 → 走**既有的**待办编辑器
  /// （完成/删除/改标题都在那一条路径里，不重复实现）。
  Future<void> _openTodoSearch(BuildContext context) async {
    final picked = await showTodoSearchSheet(context);
    if (picked == null || !context.mounted) return;
    await _openTodoEditor(context, todo: picked);
  }

  /// 新建/编辑待办（`Todo/create` / `Todo/set`）。
  ///
  /// 完成勾选也走 `set`（弹层返回的 `done` 变化），一次请求改完。
  Future<void> _openTodoEditor(
    BuildContext context, {
    CalTodoDto? todo,
    DateTime? day,
  }) async {
    final t = context.t;
    final calendars = ref.read(calTodoCalendarsProvider).value ?? const [];
    final writable = [
      for (final c in calendars)
        if (c.canWrite) c,
    ];
    if (todo == null && writable.isEmpty) {
      AppSnack.show(context, t.calNoWritableTodoCalendar, error: true);
      return;
    }
    final result = await showTodoEditorSheet(
      context,
      todo: todo,
      calendars: writable,
      day: day ?? ref.read(selectedDayProvider),
    );
    if (result == null || !context.mounted) return;
    final api = ref.read(calendarApiProvider);
    if (api == null) {
      AppSnack.show(context, t.setNotConnected, error: true);
      return;
    }
    try {
      switch (result.action) {
        case TodoEditAction.save:
          if (todo == null) {
            final cal = result.calendar ?? writable.first;
            await api.createTodo(
              originalCalendarId: cal.originalCalId.isEmpty
                  ? cal.calId
                  : cal.originalCalId,
              summary: result.summary,
              description: result.description,
              due: result.due,
              isAllDay: false,
              timeZone: ref.read(calSettingProvider).value?.timeZone ?? '',
            );
            track(
              ref,
              UsageModule.calendar,
              UsageAction.create,
              objectType: 'todo',
              detail: {'has_due': result.due != null},
            );
            if (context.mounted) {
              AppSnack.show(context, t.calCreatedTodo(result.summary));
            }
          } else {
            await api.setTodo(
              todo,
              summary: result.summary,
              description: result.description,
              due: result.due,
              clearDue: result.clearDue,
              percentComplete: result.done ? 100 : todo.percentComplete,
            );
            if (context.mounted) AppSnack.show(context, t.calTodoSaved);
          }
        case TodoEditAction.toggleDone:
          await api.setTodo(todo!, percentComplete: result.done ? 100 : 0);
        case TodoEditAction.delete:
          await api.deleteTodo(todo!.evtId);
          if (context.mounted) {
            AppSnack.show(context, t.calDeleted(todo.summary));
          }
      }
      ref.invalidate(calTodosProvider);
    } catch (e) {
      if (context.mounted) {
        AppSnack.show(context, t.calTodoActionFailed(userFacingError(e)), error: true);
      }
    }
  }

  /// 勾选框：直接在弹层之外切完成状态（`Todo/set` + `percent_complete`）
  Future<void> _toggleTodo(BuildContext context, CalTodoDto todo) async {
    final t = context.t;
    final api = ref.read(calendarApiProvider);
    if (api == null) return;
    try {
      await api.setTodo(todo, percentComplete: todo.done ? 0 : 100);
      ref.invalidate(calTodosProvider);
    } catch (e) {
      if (context.mounted) {
        AppSnack.show(context, t.calToggleFailed(userFacingError(e)), error: true);
      }
    }
  }

  /// 清空已完成（`Todo/clean_complete`，**只有 v1 版本有这个方法**）
  Future<void> _cleanDoneTodos(BuildContext context) async {
    final t = context.t;
    final api = ref.read(calendarApiProvider);
    if (api == null) return;
    final calendars = ref.read(calTodoCalendarsProvider).value ?? const [];
    final ids = [for (final c in calendars) c.calId];
    try {
      await api.cleanCompletedTodos(ids);
      ref.invalidate(calTodosProvider);
      if (context.mounted) AppSnack.show(context, t.calCleanedDone);
    } catch (e) {
      if (context.mounted) {
        AppSnack.show(context, t.calClearFailed(userFacingError(e)), error: true);
      }
    }
  }

  void _invalidateEvents() {
    // ⚠️ 必须连 **family 实例**一起失效：`monthEventsProvider` 只是包了一层
    // `monthEventsOfProvider(anchor)`，光失效外层的话里层缓存还在 ——
    // 表现就是「删掉某一次/新建完，列表不刷新，要手动点刷新」。
    // `ref.invalidate(family)` 会把该 family 的**所有**实例都失效（Riverpod 3）。
    ref.invalidate(monthEventsOfProvider);
    ref.invalidate(monthEventsProvider);
    ref.invalidate(calTodosProvider);
  }
}

CalendarDto? _findCalendar(List<CalendarDto> list, String calId) {
  for (final c in list) {
    if (c.calId == calId) return c;
  }
  return null;
}

/// 单行文本在 [maxWidth] 里是否**放得下**（用真实的 `TextScaler` 与 locale 量）。
///
/// 用途：装饰性副标题"放不下就整行不画"，而不是画一个被省略号吃掉半截的
/// （用户第 262 轮报的"副标题截断"）。**只能**用测量决定"画不画"：
/// 改字号是跟无障碍缩放对着干，`FittedBox` 会改自身高度 ⇒
/// 破坏下方环境卡的高度预算不变量（第 260 轮试过并回退过）。
class _Header extends ConsumerWidget {
  const _Header({
    required this.anchor,
    required this.busy,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onPickCalendars,
    required this.onRefresh,
    this.errorText,
  });

  final DateTime anchor;
  final bool busy;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback onPickCalendars;
  final VoidCallback onRefresh;

  /// 日历列表加载失败时的副标题（非空就顶掉 `calSubtitle`）。
  /// **单行 + 省略号**：高度与原副标题一致，不给窄屏/大字缩放添新行。
  final String? errorText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: context.t.calBack,
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 头部标题/副标题必须限行：英文 + 大字号下会换行成多行，
                // 把 `_Header` 从 71 顶到 212，直接吃掉月网格和"选中日"列表
                // 的空间（实测连锁导致整页 Column 溢出）。
                Text(
                  context.t.wsCalendar,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                // ⚠️ **这里不要改成 `FittedBox`**（第 260 轮试过并回退了）：
                // `FittedBox(scaleDown)` 会把自身高度报成"缩放后"的高度，
                // 副标题在 textScale 2.0 下变矮 ⇒ `_Header` 整体变矮 ⇒
                // 环境卡的可用预算变大 ⇒ `calendar_d3_env_card_test` 中
                // "360×640 / x2.0 预算不足必须切 dense" 的**布局不变量失效**。
                // 截断问题改用**文案长度**解决（ARB 改短，单行高度不变，不动预算）：
                // 第 262 轮把 `calSubtitle` 里冗余的 "· 月 / 周 / 日" 去掉 ——
                // 它下面一行就是**月/周/日切换器**，副标题再写一遍纯属重复，
                // 却正好是英文 + 2.0 缩放下被省略号吃掉的那几个词。
                // 副标题：装饰性文案（`calSubtitle`）**放不下就整行不画** ——
                // 宁可少一行装饰，也不要一行被省略号截掉半截的（那是用户看得到的
                // 缺陷）。错误文案是**真信息**，放不下也照旧省略号显示。
                // 这里用 `Text(' ')` 顶高度：空串的段落高度可能为 0，会让
                // `_Header` 忽高忽低 ⇒ 又去动下方预算（D3 不变量）。
                LayoutBuilder(
                  builder: (context, box) {
                    final style = Theme.of(context).textTheme.labelSmall
                        ?.copyWith(
                          // ★ r506：**去掉字距（原值 1.2）** ——
                          //   全大写 + 加字距正是上一版 HUD 的"遥测代号"写法，
                          //   真机上这行副标题看着像仪表标签。设计稿（`design/spec/
                          //   calendar.json`）的页头只有标题 + 动作，副标题是
                          //   **安静的次级文字**：字号与高度都不动（D3 预算不变量
                          //   依赖行高），只去掉字距。
                          color: errorText == null
                              ? DesignPalette.of(context).dim
                              : Theme.of(context).colorScheme.error,
                        );
                    final text = errorText ?? context.t.calSubtitle;
                    final keep =
                        errorText != null ||
                        textFitsOnOneLine(context, text, style, box.maxWidth);
                    return Text(
                      keep ? text : ' ',
                      // 用例按这个 key 取 `RenderParagraph.didExceedMaxLines`
                      // 直接判"到底有没有被截断"（布局断言证明不了这件事）。
                      key: errorText == null
                          ? const Key('cal-subtitle')
                          : const Key('cal-error-bar'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    );
                  },
                ),
              ],
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Gap.sm),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          TextButton(
            key: const Key('cal-today'),
            onPressed: onToday,
            child: Text(context.t.calToday),
          ),
          IconButton(
            key: const Key('cal-calendars'),
            tooltip: context.t.calCalendarGroups,
            icon: const Icon(Icons.filter_list),
            onPressed: onPickCalendars,
          ),
          IconButton(
            tooltip: context.t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

/// 视图切换（月 / 周 / 日）——官方 Web UI 顶部也是这三档
class _ViewSwitcher extends StatelessWidget {
  const _ViewSwitcher({required this.mode, required this.onPick});

  final CalendarViewMode mode;
  final ValueChanged<CalendarViewMode> onPick;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
    child: SegmentedButton<CalendarViewMode>(
      key: const Key('cal-view-switcher'),
      showSelectedIcon: false,
      style: const ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: [
        // 每个段的 label 带稳定 key：标签文案已经短到「月/周/日」，`find.text('日')`
        // 会与月网格的周列表头「日」撞车（第 270 轮），测试一律按 key 定位。
        ButtonSegment(
          value: CalendarViewMode.month,
          label: Text(context.t.calMonthView, key: const Key('cal-view-month')),
          icon: const Icon(Icons.calendar_view_month, size: 16),
        ),
        ButtonSegment(
          value: CalendarViewMode.week,
          label: Text(context.t.calWeekView, key: const Key('cal-view-week')),
          icon: const Icon(Icons.view_week_outlined, size: 16),
        ),
        ButtonSegment(
          value: CalendarViewMode.day,
          label: Text(context.t.calDayView, key: const Key('cal-view-day')),
          icon: const Icon(Icons.today_outlined, size: 16),
        ),
      ],
      selected: {mode},
      onSelectionChanged: (picked) {
        if (picked.isNotEmpty) onPick(picked.first);
      },
    ),
  );
}

/// 换页导航行：月 = `‹ 2026年9月 ›`，周 = `‹ 9月20日 – 9月26日 ›`，日 = `‹ 9月20日 周日 ›`
///
/// 三种模式的按钮 key 不变（`cal-prev-month`/`cal-next-month`），只是 tooltip 与
/// 中间文案随模式变 —— 翻页语义交给 `_shiftPeriod`。
class _MonthNav extends StatelessWidget {
  const _MonthNav({
    required this.anchor,
    required this.mode,
    required this.day,
    required this.onPrev,
    required this.onNext,
  });

  final DateTime anchor;
  final CalendarViewMode mode;
  final DateTime day;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  String _label(AppText t) => switch (mode) {
    CalendarViewMode.month => t.calMonthTitle(anchor.year, anchor.month),
    CalendarViewMode.week => t.calWeekRangeTitle(day.month, day.day),
    CalendarViewMode.day => t.calDayTitle(
      day.month,
      day.day,
      _weekdayLabels(t)[day.weekday % 7],
    ),
  };

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
    child: Row(
      children: [
        IconButton(
          key: const Key('cal-prev-month'),
          tooltip: mode == CalendarViewMode.month
              ? context.t.calPrevMonth
              : (mode == CalendarViewMode.week
                    ? context.t.calPrevWeek
                    : context.t.calPrevDay),
          icon: const Icon(Icons.chevron_left),
          onPressed: onPrev,
        ),
        Expanded(
          child: Center(
            child: Text(
              _label(context.t),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        IconButton(
          key: const Key('cal-next-month'),
          tooltip: mode == CalendarViewMode.month
              ? context.t.calNextMonth
              : (mode == CalendarViewMode.week
                    ? context.t.calNextWeek
                    : context.t.calNextDay),
          icon: const Icon(Icons.chevron_right),
          onPressed: onNext,
        ),
      ],
    ),
  );
}

/// **周视图**：7 列（周起始日 → +6 天），每列自己的事件小块。
///
/// 不做"时间轴网格"（那要新写一套布局，收益有限）：这里把官方周视图最有用的部分
/// ——"这一周七天各有什么"——铺开，点小块进详情（复用同一套弹层/编辑入口），
/// 点列头选中那一天（右下角 FAB 的「日程」就会建在那天）。
class _WeekBoard extends StatelessWidget {
  const _WeekBoard({
    required this.weekStart,
    required this.day,
    required this.events,
    required this.calendars,
    required this.onPickDay,
    required this.onOpen,
    required this.onNew,
  });

  /// Dart 口径（1=周一 … 7=周日）
  final int weekStart;
  final DateTime day;
  final AsyncValue<List<CalEventDto>> events;
  final List<CalendarDto> calendars;
  final ValueChanged<DateTime> onPickDay;
  final ValueChanged<CalEventDto> onOpen;
  final ValueChanged<DateTime>? onNew;

  @override
  Widget build(BuildContext context) {
    final days = weekDays(day, weekStart);
    final today = DateTime.now();
    final all = events.value ?? const <CalEventDto>[];
    return SizedBox(
      height: 250,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final d in days)
            Expanded(
              child: _WeekColumn(
                day: d,
                selected:
                    d.year == day.year &&
                    d.month == day.month &&
                    d.day == day.day,
                isToday:
                    d.year == today.year &&
                    d.month == today.month &&
                    d.day == today.day,
                events:
                    [
                      for (final e in all)
                        if (e.start != null &&
                            e.start!.year == d.year &&
                            e.start!.month == d.month &&
                            e.start!.day == d.day)
                          e,
                    ]..sort(
                      (a, b) => (a.start ?? DateTime(0)).compareTo(
                        b.start ?? DateTime(0),
                      ),
                    ),
                calendars: calendars,
                onPick: () => onPickDay(d),
                onOpen: onOpen,
                onNew: onNew == null ? null : () => onNew!(d),
              ),
            ),
        ],
      ),
    );
  }
}

class _WeekColumn extends StatelessWidget {
  const _WeekColumn({
    required this.day,
    required this.selected,
    required this.isToday,
    required this.events,
    required this.calendars,
    required this.onPick,
    required this.onOpen,
    required this.onNew,
  });

  final DateTime day;
  final bool selected;
  final bool isToday;
  final List<CalEventDto> events;
  final List<CalendarDto> calendars;
  final VoidCallback onPick;
  final ValueChanged<CalEventDto> onOpen;
  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 整列（列头 + 底下的事件块）的 key，供测试按"这一列"作用域断言。
      // 注意 `cal-week-day-<d>` 只挂在列头的 InkWell 上，不包含事件块。
      key: Key('cal-week-col-${day.day}'),
      decoration: BoxDecoration(
        color: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        border: const Border(left: BorderSide(color: Color(0x22FFFFFF))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: Key('cal-week-day-${day.day}'),
            onTap: onPick,
            onLongPress: onNew,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xs),
              child: Column(
                children: [
                  Text(
                    _weekdayLabels(context.t)[day.weekday % 7],
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isToday
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                    ),
                    child: Text(
                      '${day.day}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: isToday
                            ? Theme.of(context).colorScheme.onPrimary
                            : null,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              children: [
                for (final e in events)
                  _WeekEventChip(
                    event: e,
                    calendar: _findCalendar(calendars, e.calId),
                    onTap: () => onOpen(e),
                  ),
                if (events.isEmpty && selected)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.sm),
                    child: Text(
                      context.t.calEmptyCell,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: DesignPalette.of(context).dim, fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekEventChip extends StatelessWidget {
  const _WeekEventChip({
    required this.event,
    required this.calendar,
    required this.onTap,
  });

  final CalEventDto event;
  final CalendarDto? calendar;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(
      event.color.isNotEmpty ? event.color : (calendar?.color ?? ''),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(4),
            border: Border(left: BorderSide(color: color, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                event.isAllDay ? context.t.calAllDay : _fmtTime(event.start!),
                style: TextStyle(color: color, fontSize: 9),
              ),
              Text(
                event.summary.isEmpty ? context.t.calNoTitle : event.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, height: 1.15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader({required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.xs),
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Center(
                child: Text(
                  labels[i],
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: DesignPalette.of(context).dim),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 月视图网格的高度：6 行 × (62 格高 + 1.5×2 外边距)。
const double kMonthGridHeight = 6 * 65;

/// 月网格在**当前可用高度**下能占多少。
///
/// ⚠️ 真机踩过：HONOR 的逻辑高度只有约 814（density 490 → dpr 3.06），固定的
/// 390 逻辑像素网格 + 环境卡片会把下面的"选中日"列表挤到只剩 **20~56 像素**，
/// 事件和待办完全点不到。这里按可用高度取 34%，下限 216（每格 36），上限保持
/// 原来的 390 —— 大屏（测试里的 1246）行为完全不变。
double monthGridHeightFor(double available) =>
    (available * 0.34).clamp(216.0, kMonthGridHeight);

/// **环境卡在极端组合下的最小可见高度**（D3 修复）。
///
/// 56 = 紧凑（`dense`）天气行的自然高度上限：图标 20 + 上下内边距 2×12 +
/// 2.0 缩放下一行文字（约 20~24）。矮屏 + 2.0 缩放时宁可让卡片内部滚动，
/// 也不允许它被压成 0（旧算法 `可用高度 − 40 × textScale` 会算出 0）。
const double kEnvCardMinVisible = 56;

/// 常规布局下"选中日列表"至少保留的可见高度（一行空态 + 一点余量）。
/// 与 [kEnvCardMinVisible] 一起决定什么时候切换到紧凑布局。
const double kDayListMinVisible = 56;

/// 紧凑布局下**滚动列表**至少保留的高度：日期操作行 + 事件行都收进这个
/// 可滚动区，所以它可以很小，但必须 > 0（否则用户连"新建"都够不到）。
const double kDayListFloor = 24;

/// 卡片可用高度低于这个值就换成 `CalendarEnvCard.dense`：只留"此刻天气"
/// 一行。64 的取法 = 常规卡片首行（农历，2.0 缩放下约 28）+ 天气行（约 24），
/// 小于它时常规卡片会把天气行挤到视口外 —— 那正是要避免的。
const double kEnvCardDenseThreshold = 64;

/// **可左右滑动的月视图**（左滑 = 下个月，右滑 = 上个月）。
///
/// 为什么用"3 页相对窗口"而不是"几千页的绝对月份"：
///   * 月份不是线性列表 —— 用户可能点"今天"、点相邻月的日子、点 `‹ ›` 按钮，
///     这些都会**直接改锚点**；如果页面索引是绝对月份，就得双向同步
///     "锚点 → 页码"，很容易打架；
///   * 相对窗口下，三页永远是 `[上月, 锚点月, 下月]`，按钮/跳转只要改锚点、
///     pager 自动重渲染，翻页后 `jumpToPage(1)` 复位即可。
///
/// 手势冲突：
///   * 网格本身不横向滚动（只有 `InkWell` 点击），所以横向拖动必然属于翻月；
///   * 下面的 `_DayList` 是竖向滚动，和这里不同轴，互不影响；
///   * 页面不参与外层任何横向手势（日历是推入的整页）。
class _MonthPager extends ConsumerStatefulWidget {
  const _MonthPager({
    required this.anchor,
    required this.weekStart,
    required this.selected,
    required this.height,
    required this.onPick,
  });

  final DateTime anchor;
  final int weekStart;
  final DateTime selected;

  /// 网格总高度（按可用高度自适应，见 [monthGridHeightFor]）
  final double height;
  final ValueChanged<DateTime> onPick;

  @override
  ConsumerState<_MonthPager> createState() => _MonthPagerState();
}

class _MonthPagerState extends ConsumerState<_MonthPager> {
  final _pager = PageController(initialPage: 1);

  /// 上一次已经报给锚点的月份，避免 `onPageChanged` 与外部跳转互相触发
  late String _reported = _key(widget.anchor);

  static String _key(DateTime m) => '${m.year}-${m.month}';

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    if (page == 1) return;
    // 使用日志：翻月（横滑和箭头都走这里）
    track(
      ref,
      UsageModule.calendar,
      UsageAction.switchSection,
      objectType: 'month',
    );
    final anchor = widget.anchor;
    final month = DateTime(anchor.year, anchor.month + (page - 1));
    _reported = _key(month);
    ref.read(calendarAnchorProvider.notifier).jumpTo(month);
    // 复位到中间页：新的锚点月马上会在第 1 页重新渲染出来
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pager.hasClients && _pager.page?.round() != 1) _pager.jumpToPage(1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final anchor = widget.anchor;
    // 外部改了锚点（点「今天」/点相邻月日子/点 ‹ ›）→ 让中间页保持是锚点月
    if (_key(anchor) != _reported) {
      _reported = _key(anchor);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_pager.hasClients && _pager.page?.round() != 1) {
          _pager.jumpToPage(1);
        }
      });
    }

    return SizedBox(
      height: widget.height,
      child: PageView.builder(
        key: const Key('cal-month-pager'),
        controller: _pager,
        itemCount: 3,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, page) {
          final month = DateTime(anchor.year, anchor.month + (page - 1));
          final events = ref.watch(monthEventsOfProvider(month));
          return _MonthGrid(
            anchor: month,
            weekStart: widget.weekStart,
            selected: widget.selected,
            // 每格上下各 1.5 的外边距（6 行共 18），不减掉就会 RenderFlex 溢出
            cellHeight: (widget.height - 18) / 6,
            events: events.value ?? const [],
            onPick: widget.onPick,
          );
        },
      ),
    );
  }
}

/// 月视图网格：固定 6 行 × 7 列，每格显示日号 + 最多 3 个事件条。
class _MonthGrid extends ConsumerWidget {
  const _MonthGrid({
    required this.anchor,
    required this.weekStart,
    required this.selected,
    required this.events,
    required this.onPick,
    this.cellHeight = 65,
  });

  final DateTime anchor;
  final int weekStart;
  final DateTime selected;
  final List<CalEventDto> events;

  /// 每格高度（小屏会被压到 36 左右，此时只显示日号）
  final double cellHeight;
  final ValueChanged<DateTime> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window = monthGridWindow(anchor, weekStart);
    final today = DateTime.now();
    final byDay = <String, List<CalEventDto>>{};
    for (final e in events) {
      final s = e.start;
      if (s == null) continue;
      byDay.putIfAbsent(_dayKey(s), () => []).add(e);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      child: Column(
        children: [
          for (var row = 0; row < 6; row++)
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: _DayCell(
                      height: cellHeight,
                      day: window.from.add(Duration(days: row * 7 + col)),
                      anchorMonth: anchor.month,
                      today: today,
                      selected: selected,
                      events:
                          byDay[_dayKey(
                            window.from.add(Duration(days: row * 7 + col)),
                          )] ??
                          const [],
                      onTap: onPick,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

String _dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.anchorMonth,
    required this.today,
    required this.selected,
    required this.events,
    required this.onTap,
    this.height = 62,
  });

  final DateTime day;
  final int anchorMonth;
  final DateTime today;
  final DateTime selected;
  final List<CalEventDto> events;
  final ValueChanged<DateTime> onTap;

  /// 格子高度：低于 46 时只画日号（事件条会把格子撑破）
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = _dayKey(day) == _dayKey(selected);
    final isToday = _dayKey(day) == _dayKey(today);
    final inMonth = day.month == anchorMonth;

    return InkWell(
      onTap: () => onTap(day),
      borderRadius: BorderRadius.circular(Radii.bubbleInner),
      child: Container(
        height: height,
        margin: const EdgeInsets.all(1.5),
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 3),
        decoration: BoxDecoration(
          color: isSelected ? scheme.primary.withValues(alpha: 0.18) : null,
          border: Border.all(
            color: isSelected
                ? scheme.primary
                : isToday
                ? DesignPalette.of(context).danger
                : Colors.transparent,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(Radii.bubbleInner),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 日期数字会跟随系统"字体大小"放大，而格子高度是网格算出来的固定值：
            // 2.0 缩放下数字本身就能把格子顶溢（实测最多 34px）。
            // `Flexible` 给出剩余高度上限、`FittedBox.scaleDown` 只在放不下时
            // 等比缩小（1.0 缩放完全不生效 → 外观不变）。
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${day.day}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    // ★ r539（DA173，真机量到 2.09:1）：相邻月份的日期**是可点的**，
                    // 原来 `dim` 再乘 0.5 alpha ⇒ 亮色 2.09:1 / 暗色 2.15:1，等于看不清。
                    // 去掉 alpha：dim 本身 5.5:1（亮）/ 4.63:1（暗），与本月 `text`
                    // 的 17.85:1 仍拉开层次，不用再压低。
                    color: inMonth ? null : DesignPalette.of(context).dim,
                    fontWeight: isToday ? FontWeight.w700 : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 1),
            // 小屏（真机 dpr 3.06）格子只有 ~36 逻辑像素：再画事件条必然 overflow
            if (height >= 46)
              for (final e in events.take(2))
                Container(
                  margin: const EdgeInsets.only(bottom: 1),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 0.5,
                  ),
                  decoration: BoxDecoration(
                    color: _parseColor(e.color).withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    e.summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 9, color: Colors.white),
                  ),
                ),
            if (height >= 46 && events.length > 2)
              Text(
                '+${events.length - 2}',
                style: TextStyle(fontSize: 9, color: DesignPalette.of(context).dim),
              ),
          ],
        ),
      ),
    );
  }
}

/// `#RRGGBB` → Color（官方给的永远是 7 位十六进制，容错到任意串）
Color _parseColor(String raw) {
  final s = raw.trim();
  if (s.length >= 7 && s.startsWith('#')) {
    final v = int.tryParse(s.substring(1, 7), radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  return const Color(0xFF7C4DFF);
}

class _CalDot extends StatelessWidget {
  const _CalDot({required this.color});

  final String color;

  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(
      color: _parseColor(color),
      shape: BoxShape.circle,
    ),
  );
}

/// 选中日的事件 + 待办列表
class _DayList extends StatelessWidget {
  const _DayList({
    required this.day,
    required this.events,
    required this.onRetry,
    required this.onOpen,
    required this.calendars,
    required this.todos,
    required this.onNew,
    this.compact = false,
    this.showTimeGutter = false,
    this.onOpenTodo,
    this.onToggleTodo,
    this.onNewTodo,
    this.onSearchTodo,
    this.onCleanDone,
    this.todoCount,
  });

  final DateTime day;

  /// ⚠️ 这里必须收整个 AsyncValue：早先只在**出错时**才传，于是 `error?.value` 恒为
  /// null，成功加载后"选中日列表"永远是空的（月视图有事件条、下面却没有）——
  /// 离线测试 `只读日历不给删除按钮` 就是被这个坑抓出来的。
  final AsyncValue<List<CalEventDto>> events;
  final VoidCallback onRetry;
  final ValueChanged<CalEventDto> onOpen;
  final List<CalendarDto> calendars;
  final List<CalTodoDto> todos;
  final VoidCallback? onNew;

  /// 矮屏：环境卡片收成两行（见 [CalendarEnvCard.compact]）
  final bool compact;

  /// 事件行左侧画**时间刻度**（日视图用；月视图下面的当日列表不用）
  final bool showTimeGutter;

  /// 点一条待办 → 编辑弹层（改标题/截止/完成/删除）
  final ValueChanged<CalTodoDto>? onOpenTodo;

  /// 点勾选框 → 直接切完成状态（不发弹层，少一次点击）
  final ValueChanged<CalTodoDto>? onToggleTodo;

  /// 头部"+" → 新建待办
  final VoidCallback? onNewTodo;

  /// wave2：头部放大镜 → 搜索待办（`Todo/search` v1，`keyword`）
  final VoidCallback? onSearchTodo;

  /// 头部"清空已完成"
  final VoidCallback? onCleanDone;

  /// wave1：**未完成待办数量**（`Todo/count_todo` 的 `data.result`）。
  ///
  /// `null` = 服务端没给/没调通 → **不显示角标**；`0` = 明确没有未完成待办
  /// → 同样不显示（0 没有信息量），但**两者语义不同**，不要合成一个值。
  final int? todoCount;

  @override
  Widget build(BuildContext context) {
    final loading = events.isLoading;
    final openTodos = [
      for (final t in todos)
        if (!t.done) t,
    ];
    final doneTodos = [
      for (final t in todos)
        if (t.done) t,
    ];
    final dayEvents =
        [
          for (final e in (events.value ?? const <CalEventDto>[]))
            if (e.start != null &&
                e.start!.year == day.year &&
                e.start!.month == day.month &&
                e.start!.day == day.day)
              e,
        ]..sort(
          (a, b) => (a.start ?? DateTime(0)).compareTo(b.start ?? DateTime(0)),
        );

    // ---- 「选中日」区域的高度预算（D3 修复） ---------------------------------
    //
    // 这个区域 = 日期操作行 + 环境卡 + 选中日列表，全部挤在 `_DayList` 的高度里。
    // 旧实现把卡片上限写成 `可用高度 − 40 × textScale`：
    //   * `40 × textScale` 是个经验值，1.0 缩放下就已经小于日期操作行的实际高度
    //     （48 点击区 + 16 上下 padding = 64），于是卡片+日期行会把下面的列表
    //     挤出屏幕（实测 360×640/en/x1.0 溢出 9.6px）；
    //   * 矮屏 + 2.0 缩放时上限更会被算成 0 —— 天气卡直接不可见（审计 §5.2 D3）。
    //
    // 现在改成显式预算：日期行 (dateRowBlock) + 卡片 (≥ kEnvCardMinVisible) +
    // 列表 (≥ kDayListMinVisible)。预算不够时切换到「紧凑布局」：日期操作行收进
    // 可滚动列表，卡片独占剩余高度（至少 kDayListFloor 留给列表），
    // 并让卡片换 `dense` 只画一行天气 —— 保证任何组合下卡片都可见且不溢出。
    final double scale = MediaQuery.textScalerOf(context).scale(1);
    final Widget dateHeader = Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
      child: Row(
        children: [
          // 日期文案 + 「新建」按钮 + 两个图标按钮横排：英文/大字号下
          // `Text` 与 `TextButton` 都是不可压缩的 → 横向溢出（实测最多 34px）。
          // 日期用 `Expanded`（有界、省略），按钮用 `Flexible`（标签省略）。
          Expanded(
            child: Text(
              context.t.calDayHeader(
                day.month,
                day.day,
                _weekdayLabels(context.t)[day.weekday % 7],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (onNew != null)
            Flexible(
              child: TextButton.icon(
                key: const Key('cal-new-on-day'),
                onPressed: onNew,
                icon: const Icon(Icons.add, size: 18),
                label: Text(
                  context.t.calNew,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          // ⚠️ 待办的新建/清空按钮必须放在**顶部这行**：放在列表末尾会被悬浮的
          // 「日程」FAB 压住，点它其实点到了 FAB（真机复现：弹出的是"新建日程"）。
          // FAB 只在右下角，顶部这行永远不会被挡。
          if (onNewTodo != null)
            IconButton(
              key: const Key('cal-todo-new'),
              tooltip: context.t.calNewTodo,
              // 角标值来自 `Todo/count_todo`；`todoCount == null`（拿不到）
              // 或 `<= 0`（确实没有未完成）都**不画**角标。
              icon: Badge(
                key: todoCount != null && todoCount! > 0
                    ? const Key('cal-todo-badge')
                    : null,
                isLabelVisible: todoCount != null && todoCount! > 0,
                label: Text('${todoCount ?? 0}'),
                child: const Icon(Icons.add_task_outlined, size: 18),
              ),
              onPressed: onNewTodo,
            ),
          // wave2：待办搜索。**和"新建待办"放同一行** —— 同样的理由：这一行
          // 在 FAB（右下角）上方，不会被悬浮按钮吃掉点击；列表末尾的按钮会。
          if (onSearchTodo != null)
            IconButton(
              key: const Key('cal-todo-search'),
              tooltip: dataText('calTodoSearchTitle', '搜索待办'),
              icon: const Icon(Icons.search, size: 18),
              onPressed: onSearchTodo,
            ),
          if (onCleanDone != null && todos.any((t) => t.done))
            IconButton(
              key: const Key('cal-todo-clean'),
              tooltip: context.t.calCleanDone,
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              onPressed: onCleanDone,
            ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, box) {
        final double avail = box.maxHeight;
        // 日期操作行的高度：点击区最小 48 + 上下 padding(md+xs)；字号很大时
        // 文字可能比 48 高，用 max 兜住（宁可高估，预算是安全的）。
        final double dateRowBlock =
            math.max(48.0, 24.0 * scale) + Gap.md + Gap.xs;
        final double budget = avail.isFinite
            ? avail - dateRowBlock
            : double.infinity;
        // 预算连"卡片 + 列表"的最小可见高度都放不下 → 紧凑布局
        final bool tight = budget < kEnvCardMinVisible + kDayListMinVisible;
        // 这块区域够不够画整块空态（图标 56 + 标题 + 副文案 ≈ 190 + 上下留白）。
        final bool roomy = avail.isFinite && avail >= 640;
        final double cardMax = !avail.isFinite
            ? double.infinity
            : tight
            // 紧凑：日期行让位给滚动列表，卡片独占剩余高度
            ? (avail <= kDayListFloor ? 0.0 : avail - kDayListFloor)
            : budget - kDayListMinVisible;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!tight) dateHeader,
            // 环境信息（天气 + 节假日/农历）——用户要求两者放一起
            // 矮屏（真机 814 逻辑高度）用紧凑卡片，把空间留给事件/待办列表。
            // 卡片内部滚动 + 高度封顶；极端组合下换 `dense` 只留一行天气。
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: cardMax),
              child: SingleChildScrollView(
                child: CalendarEnvCard(
                  day: day,
                  compact: compact,
                  dense: cardMax < kEnvCardDenseThreshold,
                ),
              ),
            ),
            Expanded(
              child: events is AsyncError
                  ? AppErrorView(
                      title: context.t.calLoadFailed,
                      detail: '${events.error}',
                      onRetry: onRetry,
                    )
                  : loading && events.value == null
                  ? const Center(child: CircularProgressIndicator())
                  // ListTile 的涟漪要画在最近的 Material 上；外层 FieldBackdrop 有
                  // ColoredBox，不套一层透明 Material 会触发 framework 断言。
                  : Material(
                      type: MaterialType.transparency,
                      child: ListView(
                        // ⚠️ 底部要留出 FAB 的高度：「新建待办」那一行正好落在悬浮的
                        // 「日程」按钮下面时，点它会**点到 FAB**（真机/测试都复现过）。
                        padding: const EdgeInsets.only(bottom: Gap.xxl + 72),
                        children: [
                          // 紧凑布局：日期操作行收进列表（让卡片独占剩余高度）
                          if (tight) dateHeader,
                          // ★ r520（DA161，真机像素）：这块列表在真机上只有
                          // ~374 逻辑高（日历网格 + 环境卡把上面吃满了），
                          // 整块 `AppEmptyState`（56 图标 + 标题 + 副文案 ≈ 190）
                          // 放进来就会被下边缘截断，右边还被悬浮的「日程」FAB
                          // 压住（像素见 `docs/evidence-r520/`）。
                          // 高度不够时改画**一行**提示，并给 FAB 让出右边距；
                          // 只有真·大屏（≥640）才画整块空态。
                          if (dayEvents.isEmpty)
                            roomy
                                ? Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: Gap.xl,
                                    ),
                                    child: AppEmptyState(
                                      icon: Icons.event_available_outlined,
                                      title: context.t.calDayNoEventsTitle,
                                      message: context.t.calDayNoEventsMessage,
                                      compact: true,
                                    ),
                                  )
                                : Padding(
                                    key: const Key('cal-day-empty-hint'),
                                    padding: EdgeInsets.fromLTRB(
                                      Gap.lg,
                                      Gap.sm,
                                      Gap.lg + 96,
                                      Gap.sm,
                                    ),
                                    child: Text(
                                      context.t.calDayNoEventsTitle,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                          for (final e in dayEvents)
                            _EventRow(
                              event: e,
                              calendar: _findCalendar(calendars, e.calId),
                              showTime: showTimeGutter,
                              onTap: () => onOpen(e),
                            ),
                          if (todos.isNotEmpty || onNewTodo != null) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                Gap.lg,
                                Gap.lg,
                                Gap.xs,
                                Gap.xs,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      doneTodos.isEmpty
                                          ? context.t.calTodoSection(
                                              openTodos.length,
                                            )
                                          : context.t.calTodoSectionDone(
                                              openTodos.length,
                                              doneTodos.length,
                                            ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium
                                          ?.copyWith(color: DesignPalette.of(context).dim),
                                    ),
                                  ),
                                  // 新建/清空按钮在**顶部那行**（见上面的注释：那里才躲得开 FAB）
                                ],
                              ),
                            ),
                            for (final t in openTodos.take(8))
                              DesignRowTile(
                                key: Key('cal-todo-${t.evtId}'),
                                dense: true,
                                leading: IconButton(
                                  key: Key('cal-todo-check-${t.evtId}'),
                                  tooltip: t.done
                                      ? context.t.calMarkUndone
                                      : context.t.calMarkDone,
                                  icon: Icon(
                                    t.done
                                        ? Icons.check_circle
                                        : Icons.radio_button_unchecked,
                                    size: 18,
                                    color: t.done ? DesignPalette.of(context).dim : null,
                                  ),
                                  onPressed: onToggleTodo == null
                                      ? null
                                      : () => onToggleTodo!(t),
                                ),
                                title: Text(
                                  t.summary,
                                  style: t.done
                                      ? TextStyle(
                                          decoration:
                                              TextDecoration.lineThrough,
                                          color: DesignPalette.of(context).dim,
                                        )
                                      : null,
                                ),
                                subtitle: t.dueAt == null
                                    ? null
                                    : Text(
                                        context.t.calDueDate(
                                          _fmtDate(t.dueAt!),
                                        ),
                                      ),
                                onTap: onOpenTodo == null
                                    ? null
                                    : () => onOpenTodo!(t),
                              ),
                            // 已完成的最多露 3 条（划线）：给用户"确实做完了"的回执，
                            // 又不会把列表撑长；要清掉点顶部的「清空已完成」
                            for (final t in doneTodos.take(3))
                              DesignRowTile(
                                key: Key('cal-todo-${t.evtId}'),
                                dense: true,
                                leading: IconButton(
                                  key: Key('cal-todo-check-${t.evtId}'),
                                  tooltip: context.t.calMarkUndone,
                                  icon: Icon(
                                    Icons.check_circle,
                                    size: 18,
                                    color: DesignPalette.of(context).dim,
                                  ),
                                  onPressed: onToggleTodo == null
                                      ? null
                                      : () => onToggleTodo!(t),
                                ),
                                title: Text(
                                  t.summary,
                                  style: TextStyle(
                                    decoration: TextDecoration.lineThrough,
                                    color: DesignPalette.of(context).dim,
                                  ),
                                ),
                                subtitle: t.dueAt == null
                                    ? null
                                    : Text(
                                        context.t.calDueDate(
                                          _fmtDate(t.dueAt!),
                                        ),
                                      ),
                                onTap: onOpenTodo == null
                                    ? null
                                    : () => onOpenTodo!(t),
                              ),
                          ],
                        ],
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.calendar,
    required this.onTap,
    this.showTime = false,
  });

  final CalEventDto event;
  final CalendarDto? calendar;
  final VoidCallback onTap;

  /// 左侧画时间刻度（日视图）：`09:00` + 一条竖线，官方日视图的样子
  final bool showTime;

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(
      event.color.isNotEmpty ? event.color : (calendar?.color ?? ''),
    );
    final subtitle = [
      // 日视图左边已经有时间刻度了，副标题就不重复写时间
      if (!showTime) calTimeRange(event, context.t),
      if (calendar != null) calendar!.displayName,
      if (event.hasLocation) event.locationName,
    ].join(' · ');
    leading() => Container(
      width: 4,
      height: 34,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
    return DesignRowTile(
      onTap: onTap,
      leading: showTime
          ? SizedBox(
              width: 52,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      event.isAllDay
                          ? context.t.calAllDay
                          : _fmtTime(event.start!),
                      style: TextStyle(color: DesignPalette.of(context).dim, fontSize: 11),
                    ),
                  ),
                  leading(),
                ],
              ),
            )
          : leading(),
      title: Text(event.summary.isEmpty ? context.t.calNoTitle : event.summary),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: DesignPalette.of(context).dim),
      ),
      trailing: event.isSeriesMember
          ? Icon(Icons.repeat, size: 16, color: DesignPalette.of(context).dim)
          : null,
    );
  }
}

/// 事件时间的一行文案（全天 / 时间区间）
///
/// [l10n] 缺省走 `currentText()`：纯函数的老调用方/单测仍拿到中文回落。
String calTimeRange(CalEventDto e, [AppText? l10n]) {
  final t = l10n ?? currentText();
  final s = e.start;
  final en = e.end;
  if (e.isAllDay || (s != null && s.hour == 0 && s.minute == 0 && en == null)) {
    return t.calAllDay;
  }
  if (s == null) return t.calTimeUnknown;
  final sameDay =
      en == null ||
      (en.year == s.year && en.month == s.month && en.day == s.day);
  final left = _fmtTime(s);
  if (en == null) return left;
  return sameDay
      ? '$left – ${_fmtTime(en)}'
      : '$left – ${_fmtDate(en)} ${_fmtTime(en)}';
}

String _repeatUnit(AppText t, String type) => switch (type) {
  'day' => t.dtoCalUnitDay,
  'week' => t.dtoCalUnitWeek,
  'month' => t.dtoCalUnitMonth,
  'year' => t.dtoCalUnitYear,
  _ => t.dtoCalUnitTimes,
};

/// 0=周日 … 6=周六（与 `CalRepeatRule.kWeekdays` 对齐）的单字简写
List<String> _weekdayLabels(AppText t) => [
  t.calWeekdayMinSun,
  t.calWeekdayMinMon,
  t.calWeekdayMinTue,
  t.calWeekdayMinWed,
  t.calWeekdayMinThu,
  t.calWeekdayMinFri,
  t.calWeekdayMinSat,
];

String _fmtTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

/// 受邀人状态文案（状态枚举逐字来自包内 `SYNO.Cal.AttendeeUtils.attendeeStatus`）。
String _participantStatusText(String status) => switch (status) {
  CalParticipantDto.statusAccepted => dataText('calParticipantAccepted', '已接受'),
  CalParticipantDto.statusDeclined => dataText('calParticipantDeclined', '已拒绝'),
  CalParticipantDto.statusTentative => dataText('calParticipantTentative', '暂定'),
  CalParticipantDto.statusNeedsAction => dataText(
    'calParticipantNeedsAction',
    '待回复',
  ),
  _ => '',
};

/// 详情弹层返回的动作（重复事件要分"仅这一次/整个系列"）
enum _EventDetailAction {
  deleteOnce,
  thisOnly,
  wholeSeries,
  editOnce,
  editSeries,
}

/// 事件详情（可删）
class _EventDetailSheet extends StatelessWidget {
  const _EventDetailSheet({required this.event, required this.canWrite});

  final CalEventDto event;
  final bool canWrite;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    event.summary.isEmpty
                        ? context.t.calNoTitle
                        : event.summary,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: context.t.photoClose,
                  icon: const Icon(Icons.close),
                  // ⚠️ 必须 `pop()`（不传值）：这条路由是 `showModalBottomSheet<
                  // _EventDetailAction>`，pop 一个 `bool` 会抛
                  // "A request was made to pop a route with a result of type bool"
                  // —— 调试构建里**弹层关不掉**（点关闭像没反应），
                  // 老代码是 `pop(false)`，遗留自"删除确认弹层返回 bool"的年代。
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: Gap.sm),
            _kv(context, Icons.schedule, calTimeRange(event, context.t)),
            if (event.tzId.isNotEmpty)
              _kv(context, Icons.public, context.t.calTimezone(event.tzId)),
            if (event.hasLocation)
              _kv(
                context,
                Icons.place_outlined,
                [
                  event.locationName,
                  event.locationAddress,
                ].where((s) => s.isNotEmpty).join(' · '),
              ),
            // 重复规则（服务端 `repeat_setting`）：列表/详情都要能一眼看出"这不是一次性的"
            if (event.repeat != null)
              _kv(
                context,
                Icons.repeat,
                '${event.repeat!.describe()}'
                '${event.recurrenceId.isEmpty ? '' : context.t.calOccurrenceSuffix}',
              ),
            if (event.description.isNotEmpty)
              _kv(context, Icons.notes_outlined, event.description),
            if (event.ownerName.isNotEmpty)
              _kv(
                context,
                Icons.person_outline,
                context.t.calCreator(event.ownerName),
              ),
            // 受邀人（`participant`）：官方 attendee 表格给的是"名字 + 状态"。
            if (event.participantList.isNotEmpty)
              _kv(
                context,
                Icons.groups_outlined,
                event.participantList
                    .map((p) {
                      final s = _participantStatusText(p.status);
                      return s.isEmpty
                          ? p.label
                          : dataText(
                              'calParticipantNameStatus',
                              '{name}（{status}）',
                            ).replaceAll('{name}', p.label).replaceAll('{status}', s);
                    })
                    .join(context.t.listSeparator),
              ),
            const SizedBox(height: Gap.md),
            if (canWrite && !event.isSeriesMember)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('cal-edit-event'),
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(_EventDetailAction.editOnce),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: Text(context.t.calEditLabel),
                    ),
                  ),
                ],
              ),
            // 重复事件：官方 Web UI 编辑时也是"仅此/所有"两档（`set` 与 `subevent_set`）
            if (canWrite && event.isSeriesMember)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('cal-edit-event-this'),
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(_EventDetailAction.editOnce),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: Text(context.t.calEditThis),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('cal-edit-event-all'),
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(_EventDetailAction.editSeries),
                      icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                      label: Text(context.t.calEditAll),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                if (!canWrite)
                  Expanded(
                    child: Text(
                      context.t.calReadOnlyCalendar,
                      style: TextStyle(color: DesignPalette.of(context).dim, fontSize: 12),
                    ),
                  ),
                if (canWrite && !event.isSeriesMember)
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const Key('cal-delete-event'),
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(_EventDetailAction.deleteOnce),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(context.t.dtoActionDelete),
                    ),
                  ),
                // 重复事件：官方 Web UI 也是这两个选择（"仅此日程"/"所有日程"）
                if (canWrite && event.isSeriesMember) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('cal-delete-event-this'),
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(_EventDetailAction.thisOnly),
                      icon: const Icon(Icons.event_busy_outlined, size: 18),
                      label: Text(context.t.calOnlyThis),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const Key('cal-delete-event-all'),
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(_EventDetailAction.wholeSeries),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(context.t.calAllEvents),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: DesignPalette.of(context).dim),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

/// 新建事件的草稿
class _EventDraft {
  const _EventDraft({
    required this.calendar,
    required this.summary,
    required this.start,
    required this.end,
    required this.isAllDay,
    required this.timeZone,
    required this.description,
    this.color = '',
    this.repeat,
    this.participants = const [],
  });

  final CalendarDto calendar;
  final String summary;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
  final String timeZone;
  final String description;

  /// wave1：事件配色（`color`）。**空串 = 用日历默认色**（服务端语义，
  /// 见包内 `openapi.json` 对 `color` 的说明："Leave empty to use the
  /// calendar's default color"）。取值来自 `Event/list_color`（仅 v6）。
  final String color;

  /// 重复规则（null = 不重复）
  final CalRepeatRule? repeat;

  /// 受邀人（`participant`）：新建/编辑整条事件时整体提交。
  final List<CalParticipantDto> participants;
}

class _EventEditorSheet extends StatefulWidget {
  const _EventEditorSheet({
    required this.calendars,
    required this.day,
    required this.defaultTimeZone,
    this.editing,
    this.lockRepeat = false,
  });

  final List<CalendarDto> calendars;
  final DateTime day;
  final String defaultTimeZone;

  /// 编辑模式：预填这条日程的现有值（null = 新建）
  final CalEventDto? editing;

  /// 重复规则**不许改**（编辑重复系列的"本次"时：规则属于整个系列）
  final bool lockRepeat;

  @override
  State<_EventEditorSheet> createState() => _EventEditorSheetState();
}

class _EventEditorSheetState extends State<_EventEditorSheet> {
  late final TextEditingController _title = TextEditingController(text: '');
  late final TextEditingController _desc = TextEditingController();
  late CalendarDto _calendar = widget.calendars.first;
  late DateTime _start = DateTime(
    widget.day.year,
    widget.day.month,
    widget.day.day,
    9,
  );
  late DateTime _end = _start.add(const Duration(hours: 1));
  var _allDay = false;

  /// 重复：null = 不重复（默认）。规则本身照服务端 `repeat_setting` 的枚举。
  CalRepeatRule? _repeat;

  /// 受邀人（`participant`）。编辑时预填源事件的受邀人（含组织者）。
  List<CalParticipantDto> _participants = const [];

  /// wave1：事件配色（`color`）。空串 = 用日历默认色。
  ///
  /// ⚠️ 候选值**只来自 `Event/list_color`**（见 `calEventColorsProvider`）；
  /// provider 拿不到就回空列表，这里也就只剩"用日历默认色"一项 ——
  /// **绝不内置写死的调色板**（falsification ①）。
  String _color = '';

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e == null) return;
    _title.text = e.summary;
    _desc.text = e.description;
    final cal = widget.calendars.firstWhere(
      (c) => c.calId == e.calId,
      orElse: () => widget.calendars.first,
    );
    _calendar = cal;
    _allDay = e.isAllDay;
    _start = e.start ?? _start;
    final end = e.end;
    // 全天事件的 `dtend` 是**次日零点（exclusive）**，编辑时要减回"最后一天"，
    // 否则打开编辑再保存就会把事件越改越长。
    if (end != null) {
      _end = _allDay ? end.subtract(const Duration(days: 1)) : end;
      if (_end.isBefore(_start)) _end = _start;
    } else {
      _end = _start.add(const Duration(hours: 1));
    }
    _repeat = e.repeat;
    // 受邀人：原样预填（`Event/set` 是"整体替换"语义，丢了就会清空受邀人）。
    _participants = e.participantList;
    // 配色：原样预填（`Event/set` 同样要把 color 原样带回，否则会被清成默认色）
    _color = e.color;
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg + inset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _isEditing ? context.t.calEditEvent : context.t.calNewEvent,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: context.t.photoClose,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            TextField(
              key: const Key('cal-editor-title'),
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                labelText: context.t.calEventTitleLabel,
              ),
            ),
            const SizedBox(height: Gap.md),
            DropdownButtonFormField<CalendarDto>(
              isExpanded: true,
              key: const Key('cal-editor-calendar'),
              initialValue: _calendar,
              decoration: InputDecoration(labelText: context.t.wsCalendar),
              items: [
                for (final c in widget.calendars)
                  DropdownMenuItem(value: c, child: Text(c.displayName)),
              ],
              onChanged: (v) => setState(() => _calendar = v ?? _calendar),
            ),
            DesignSwitchRow(
              key: const Key('cal-editor-allday'),
              value: _allDay,
              contentPadding: EdgeInsets.zero,
              title: Text(context.t.calAllDay),
              onChanged: (v) => setState(() => _allDay = v),
            ),
            DesignRowTile(
              key: const Key('cal-editor-start'),
              contentPadding: EdgeInsets.zero,
              title: Text(context.t.calStartLabel),
              subtitle: Text(
                _allDay
                    ? _fmtDate(_start)
                    : '${_fmtDate(_start)} ${_fmtTime(_start)}',
              ),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: () => _pickDate(isStart: true),
            ),
            DesignRowTile(
              key: const Key('cal-editor-end'),
              contentPadding: EdgeInsets.zero,
              title: Text(context.t.calEndLabel),
              subtitle: Text(
                _allDay
                    ? _fmtDate(_end)
                    : '${_fmtDate(_end)} ${_fmtTime(_end)}',
              ),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: () => _pickDate(isStart: false),
            ),
            // 编辑重复系列的"本次"时，重复规则属于整个系列，这里只读
            if (widget.lockRepeat && _repeat != null)
              DesignRowTile(
                key: const Key('cal-editor-repeat-locked'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.repeat, size: 18),
                title: Text(context.t.calRepeatPrefixed(_repeat!.describe())),
                subtitle: Text(context.t.calRepeatLockedHint),
              ),
            // 重复（官方 Web UI 在同一个表单里：类型 → 间隔 → 星期几 → 结束方式）
            if (!widget.lockRepeat)
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: const Key('cal-editor-repeat'),
                initialValue: _repeat?.type ?? '',
                decoration: InputDecoration(labelText: context.t.dtoCalRepeat),
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(context.t.calRepeatNever),
                  ),
                  DropdownMenuItem(
                    value: 'day',
                    child: Text(context.t.dtoCalEveryDay),
                  ),
                  DropdownMenuItem(
                    value: 'week',
                    child: Text(context.t.dtoCalEveryWeek),
                  ),
                  DropdownMenuItem(
                    value: 'month',
                    child: Text(context.t.dtoCalEveryMonth),
                  ),
                  DropdownMenuItem(
                    value: 'year',
                    child: Text(context.t.dtoCalEveryYear),
                  ),
                ],
                onChanged: (v) => setState(() {
                  _repeat = (v == null || v.isEmpty)
                      ? null
                      : (_repeat != null && _repeat!.type == v)
                      ? _repeat
                      : CalRepeatRule.ofType(v, start: _start);
                }),
              ),
            if (!widget.lockRepeat && _repeat != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.t.calRepeatIntervalLabel(
                          _repeatUnit(context.t, _repeat!.type),
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    IconButton(
                      key: const Key('cal-editor-repeat-minus'),
                      onPressed: _repeat!.interval <= 1
                          ? null
                          : () => setState(
                              () => _repeat = _repeat!.copyWith(
                                interval: _repeat!.interval - 1,
                              ),
                            ),
                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                    ),
                    Text(
                      '${_repeat!.interval}',
                      key: const Key('cal-editor-repeat-interval'),
                    ),
                    IconButton(
                      key: const Key('cal-editor-repeat-plus'),
                      onPressed: _repeat!.interval >= 30
                          ? null
                          : () => setState(
                              () => _repeat = _repeat!.copyWith(
                                interval: _repeat!.interval + 1,
                              ),
                            ),
                      icon: const Icon(Icons.add_circle_outline, size: 18),
                    ),
                  ],
                ),
              ),
              if (_repeat!.type == 'week')
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: Gap.xs,
                    children: [
                      for (var i = 0; i < CalRepeatRule.kWeekdays.length; i++)
                        FilterChip(
                          key: Key(
                            'cal-editor-repeat-day-'
                            '${CalRepeatRule.kWeekdays[i]}',
                          ),
                          label: Text(_weekdayLabels(context.t)[i % 7]),
                          selected: _repeat!.weekday.contains(
                            CalRepeatRule.kWeekdays[i],
                          ),
                          onSelected: (on) => setState(() {
                            final next = [..._repeat!.weekday];
                            if (on) {
                              if (!next.contains(CalRepeatRule.kWeekdays[i])) {
                                next.add(CalRepeatRule.kWeekdays[i]);
                              }
                            } else {
                              next.remove(CalRepeatRule.kWeekdays[i]);
                            }
                            _repeat = _repeat!.copyWith(weekday: next);
                          }),
                        ),
                    ],
                  ),
                ),
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: const Key('cal-editor-repeat-end'),
                initialValue: _repeat!.endType,
                decoration: InputDecoration(labelText: context.t.calEndLabel),
                items: [
                  DropdownMenuItem(
                    value: 'never',
                    child: Text(context.t.calRepeatForever),
                  ),
                  DropdownMenuItem(
                    value: 'count',
                    child: Text(context.t.calRepeatCountLabel),
                  ),
                  DropdownMenuItem(
                    value: 'date',
                    child: Text(context.t.calRepeatUntilDate),
                  ),
                ],
                onChanged: (v) => setState(
                  () => _repeat = _repeat!.copyWith(endType: v ?? 'never'),
                ),
              ),
              if (_repeat!.endType == 'count')
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Row(
                    children: [
                      Text(
                        context.t.dtoCalEndCount(_repeat!.endCount),
                        key: const Key('cal-editor-repeat-count'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Spacer(),
                      TextButton(
                        key: const Key('cal-editor-repeat-count-minus'),
                        onPressed: _repeat!.endCount <= 1
                            ? null
                            : () => setState(
                                () => _repeat = _repeat!.copyWith(
                                  endCount: _repeat!.endCount - 1,
                                ),
                              ),
                        child: const Text('−1'),
                      ),
                      TextButton(
                        key: const Key('cal-editor-repeat-count-plus'),
                        onPressed: _repeat!.endCount >= 999
                            ? null
                            : () => setState(
                                () => _repeat = _repeat!.copyWith(
                                  endCount: _repeat!.endCount + 1,
                                ),
                              ),
                        child: const Text('+1'),
                      ),
                    ],
                  ),
                ),
              if (_repeat!.endType == 'date')
                DesignRowTile(
                  key: const Key('cal-editor-repeat-until'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.t.calRepeatUntil),
                  subtitle: Text(
                    _repeat!.endDate.isEmpty
                        ? context.t.calPickDate
                        : _repeat!.endDate,
                  ),
                  trailing: const Icon(Icons.event_outlined),
                  onTap: _pickRepeatEnd,
                ),
            ],
            TextField(
              key: const Key('cal-editor-desc'),
              controller: _desc,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: context.t.calDescriptionOptional,
              ),
            ),
            // wave1 配色（`Event/create|set` 的 `color`）。
            //
            // 候选色**只来自 `Event/list_color`**（v6）：provider 拿不到就回
            // 空列表 ⇒ 整块隐藏（**不回退到写死的调色板**，falsification ①）。
            // 空串 = 用日历默认色（服务端语义，逐字见 openapi 对 `color` 的说明）。
            Consumer(
              builder: (context, ref, _) {
                final colors =
                    ref.watch(calEventColorsProvider).value ?? const [];
                if (colors.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: Gap.sm),
                    Text(
                      dataText('calEventColor', '日程配色'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: Gap.xs),
                    Wrap(
                      key: const Key('cal-editor-colors'),
                      spacing: Gap.xs,
                      runSpacing: Gap.xs,
                      children: [
                        // 第一项 = 用日历默认色（色块用日历自己的颜色表示）
                        ChoiceChip(
                          key: const Key('cal-editor-color-default'),
                          selected: _color.isEmpty,
                          label: Text(dataText('calColorDefault', '默认色')),
                          avatar: _CalDot(
                            color: _calendar.color.isEmpty
                                ? ''
                                : _calendar.color,
                          ),
                          onSelected: (_) => setState(() => _color = ''),
                        ),
                        for (var i = 0; i < colors.length; i++)
                          ChoiceChip(
                            key: Key('cal-editor-color-$i'),
                            selected:
                                _color.toUpperCase() ==
                                colors[i].color.toUpperCase(),
                            label: colors[i].name.isEmpty
                                ? Text(colors[i].color)
                                : Text(colors[i].name),
                            avatar: _CalDot(color: colors[i].color),
                            onSelected: (_) =>
                                setState(() => _color = colors[i].color),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
            // 受邀人（`participant`，openapi 里是 required）。官方 Web UI 也是
            // 同一个表单里的一个区块：候选人 = NAS 用户（`Contact/list`）+ 手输邮箱。
            const Divider(height: Gap.lg),
            Row(
              children: [
                Expanded(
                  child: Text(
                    dataText('calParticipantsLabel', '参与者'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                TextButton.icon(
                  key: const Key('cal-editor-participant-add'),
                  onPressed: _addParticipant,
                  icon: const Icon(Icons.person_add_alt, size: 18),
                  label: Text(dataText('calParticipantAdd', '添加')),
                ),
              ],
            ),
            if (_participants.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  dataText('calParticipantEmpty', '还没有参与者'),
                  key: const Key('cal-editor-participant-empty'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
                ),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: Gap.xs,
                  runSpacing: Gap.xs,
                  children: [
                    for (final p in _participants)
                      InputChip(
                        key: Key('cal-editor-participant-${_participantKey(p)}'),
                        avatar: Icon(
                          p.role == CalParticipantDto.roleOrganizer
                              ? Icons.star_outline
                              : Icons.person_outline,
                          size: 16,
                        ),
                        label: Text(p.label),
                        // 组织者不给删（官方 attendee 表格里 organizer 那一行没有
                        // remove 按钮）：删了就无法表达"谁是组织者"。
                        onDeleted: p.role == CalParticipantDto.roleOrganizer
                            ? null
                            : () => setState(
                                () => _participants = [
                                  for (final x in _participants)
                                    if (!identical(x, p)) x,
                                ],
                              ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: Gap.lg),
            FilledButton(
              key: const Key('cal-editor-save'),
              onPressed: () {
                final title = _title.text.trim();
                if (title.isEmpty) {
                  AppSnack.show(
                    context,
                    context.t.calTitleRequired,
                    error: true,
                  );
                  return;
                }
                var end = _end;
                if (!end.isAfter(_start)) {
                  end = _start.add(const Duration(hours: 1));
                }
                Navigator.of(context).pop(
                  _EventDraft(
                    calendar: _calendar,
                    summary: title,
                    start: _start,
                    end: end,
                    isAllDay: _allDay,
                    timeZone: widget.defaultTimeZone,
                    description: _desc.text.trim(),
                    color: _color,
                    repeat: _repeat,
                    participants: _participants,
                  ),
                );
              },
              child: Text(context.t.actionSave),
            ),
          ],
        ),
      ),
    );
  }

  /// 参与者 chip 的 key/去重键：优先邮箱（官方以 email 判重），退化到用户名。
  static String _participantKey(CalParticipantDto p) =>
      p.email.isNotEmpty ? p.email : p.userName;

  /// 加一个受邀人：弹层里可以选 NAS 用户，也可以手输邮箱（不需要任何额外 API）。
  Future<void> _addParticipant() async {
    final picked = await showModalBottomSheet<CalParticipantDto>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (_) => _ParticipantPickerSheet(
        // 已在列表里的不再重复（官方也是按 email 去重）
        existing: {
          for (final p in _participants)
            if (_participantKey(p).isNotEmpty) _participantKey(p),
        },
      ),
    );
    if (picked == null || !mounted) return;
    final key = _participantKey(picked);
    if (_participants.any((p) => _participantKey(p) == key)) return;
    setState(() => _participants = [..._participants, picked]);
  }

  /// 重复到某天（默认给一年后，官方也是预填）
  Future<void> _pickRepeatEnd() async {
    final now = _repeat?.endDate.isNotEmpty == true
        ? DateTime.tryParse(_repeat!.endDate)
        : null;
    final picked = await showDatePicker(
      context: context,
      initialDate: now ?? _start.add(const Duration(days: 365)),
      firstDate: _start,
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(
      () => _repeat = _repeat!.copyWith(
        endType: 'date',
        endDate:
            '${picked.year}-${picked.month.toString().padLeft(2, '0')}'
            '-${picked.day.toString().padLeft(2, '0')}',
      ),
    );
  }

  Future<void> _pickDate({required bool isStart}) async {
    final base = isStart ? _start : _end;
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    var time = TimeOfDay(hour: base.hour, minute: base.minute);
    if (!_allDay) {
      final picked = await showTimePicker(context: context, initialTime: time);
      if (picked == null || !mounted) return;
      time = picked;
    }
    final next = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (isStart) {
        final delta = _end.difference(_start);
        _start = next;
        _end = next.add(delta.isNegative ? const Duration(hours: 1) : delta);
      } else {
        _end = next;
      }
    });
  }
}

/// 加受邀人的弹层：NAS 用户候选（`SYNO.Cal.Contact/list`）+ 手输邮箱。
///
/// 两级的降级语义（不隐藏日历模块）：
///   * `SYNO.Cal.Contact` 不存在（老包）→ 用户候选整块换成一条**说明**，
///     手输邮箱照常可用（官方 `getAttendeeByRawEmail`，不需要额外接口）；
///   * 能力存在但调用失败 → `calContactsProvider` 已兜成空列表，同样只留邮箱。
class _ParticipantPickerSheet extends ConsumerStatefulWidget {
  const _ParticipantPickerSheet({required this.existing});

  /// 已经在受邀人列表里的去重键（email 优先，退化到 user_name）。
  final Set<String> existing;

  @override
  ConsumerState<_ParticipantPickerSheet> createState() =>
      _ParticipantPickerSheetState();
}

class _ParticipantPickerSheetState
    extends ConsumerState<_ParticipantPickerSheet> {
  final _email = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _addEmail() {
    final v = _email.text.trim();
    if (v.isEmpty || !v.contains('@')) {
      AppSnack.show(
        context,
        dataText('calParticipantBadEmail', '请输入有效的邮箱地址'),
        error: true,
      );
      return;
    }
    Navigator.of(context).pop(CalParticipantDto.forEmail(v));
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(calendarApiProvider);
    final users = ref.watch(calContactsProvider);
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg + inset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    dataText('calAddParticipant', '添加参与者'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: context.t.photoClose,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            TextField(
              key: const Key('cal-participant-email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: dataText('calParticipantEmailHint', '输入邮箱'),
              ),
              onSubmitted: (_) => _addEmail(),
            ),
            const SizedBox(height: Gap.sm),
            FilledButton.icon(
              key: const Key('cal-participant-email-add'),
              onPressed: _addEmail,
              icon: const Icon(Icons.alternate_email, size: 18),
              label: Text(dataText('calParticipantAddEmail', '加为外部参与者')),
            ),
            const Divider(height: Gap.lg),
            if (api != null && !api.hasContactApi)
              Text(
                dataText(
                  'calParticipantUnsupported',
                  // ★★ r348 D60：ARB 与这里的**兜底串**都曾把内部接口名
                  //   `SYNO.Cal.Contact` 印给用户（静态守卫只扫 ARB、且只认带 `/method`
                  //   的形状 ⇒ 这条从四条规则下走过去）。
                  '这台 NAS 的日历没有用户列表接口，只能手动输入邮箱。',
                ),
                key: const Key('cal-participant-unsupported'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
              )
            else ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  dataText('calParticipantPickUser', '从 NAS 用户选择'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              users.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: Gap.md),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  child: Text(
                    dataText(
                      'calParticipantUsersFailed',
                      '用户列表加载失败，可以手动输入邮箱。',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                data: (list) {
                  if (list.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                      child: Text(
                        dataText(
                          'calParticipantNoUsers',
                          '没有可选的 NAS 用户，可以手动输入邮箱。',
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final u in list)
                        Builder(
                          builder: (ctx) {
                            final p = CalParticipantDto.forDsm(u);
                            final key = p.email.isNotEmpty ? p.email : p.userName;
                            final added = widget.existing.contains(key);
                            return DesignRowTile(
                              key: Key('cal-participant-user-${u.userName}'),
                              dense: true,
                              enabled: !added,
                              leading: const Icon(Icons.person_outline),
                              title: Text(u.label),
                              subtitle: u.email.isEmpty
                                  ? null
                                  : Text(u.email),
                              trailing: added
                                  ? Icon(
                                      Icons.check,
                                      size: 18,
                                      color: DesignPalette.of(ctx).dim,
                                    )
                                  : null,
                              onTap: added
                                  ? null
                                  : () => Navigator.of(ctx).pop(p),
                            );
                          },
                        ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
