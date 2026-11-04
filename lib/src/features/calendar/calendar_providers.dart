// 日历模块的 provider 层。
//
// 事实来源：`lib/src/data/calendar_api.dart`（形态全部真机取证，见
// docs/api-server-authoritative.md §18）。Riverpod 3 统一 `retry: _noRetry`，
// 否则错误页会被指数退避盖住。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';

import '../../data/calendar_api.dart';
import '../../data/dto/calendar_dto.dart';
import 'calendar_env.dart';
import '../servers/session_controller.dart';

/// Riverpod 3：返回 null = 不重试（与笔记/相册/联系人同口径）
Duration? _noRetry(int retryCount, Object error) => null;

/// 日历 API（未连接为 null → 页面说"未连接"而不是崩）
final calendarApiProvider = Provider<CalendarApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : CalendarApi(conn.api);
});

/// 事件日历列表（`Cal/list`）
final calendarsProvider = FutureProvider.autoDispose<List<CalendarDto>>((
  ref,
) async {
  final api = ref.watch(calendarApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.listCalendars();
}, retry: _noRetry);

/// 个人设置（`Setting/get`）—— 时区 / 周起始日 / 日期格式
final calSettingProvider = FutureProvider.autoDispose<CalSettingDto>((
  ref,
) async {
  final api = ref.watch(calendarApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api.setting();
}, retry: _noRetry);

/// 受邀人候选（`SYNO.Cal.Contact/list`，NAS 用户列表）。
///
/// 降级语义：`SYNO.Cal.Contact` **不存在**（老包）→ 返回空列表，事件编辑器的
/// "从 NAS 用户选择"入口整个隐藏（只留手输邮箱），**不隐藏日历模块**；
/// 能力存在但调用失败（如 105 无权限）→ 也退化成空列表 + 邮箱手输。
/// 这是"可选入口"，不新增 `service_registry` 能力位（那是禁改区）。
final calContactsProvider = FutureProvider.autoDispose<List<CalContactDto>>((
  ref,
) async {
  final api = ref.watch(calendarApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  if (!api.hasContactApi) return const [];
  try {
    return await api.calContacts();
  } catch (_) {
    return const [];
  }
}, retry: _noRetry);

/// 勾选的日历 id（**空集 = 全部**，和官方"默认全选"一致）
final selectedCalIdsProvider =
    NotifierProvider<SelectedCalIdsNotifier, Set<String>>(
      SelectedCalIdsNotifier.new,
    );

class SelectedCalIdsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String calId) {
    final next = {...state};
    if (!next.remove(calId)) next.add(calId);
    state = next;
  }

  void clear() => state = const {};
}

/// 日历的视图模式：月 / 周 / 日。
///
/// 只存在内存里（和"选中哪天/聚焦哪个月"一样）：官方 Web UI 会记住，
/// 我们等"偏好持久化"那一条（计划 §11.1 第 17 项）一起做。
enum CalendarViewMode { month, week, day }

final calendarViewModeProvider =
    NotifierProvider<CalendarViewModeNotifier, CalendarViewMode>(
      CalendarViewModeNotifier.new,
    );

class CalendarViewModeNotifier extends Notifier<CalendarViewMode> {
  @override
  CalendarViewMode build() => CalendarViewMode.month;

  void set(CalendarViewMode mode) => state = mode;
}

/// 当前聚焦的月份（只用到年/月，归一化到 1 号 00:00）
final calendarAnchorProvider =
    NotifierProvider<CalendarAnchorNotifier, DateTime>(
      CalendarAnchorNotifier.new,
    );

class CalendarAnchorNotifier extends Notifier<DateTime> {
  @override
  DateTime build() {
    final now = DateTime.now();
    return DateTime(now.year, now.month);
  }

  void shift(int months) {
    state = DateTime(state.year, state.month + months);
  }

  /// 跳到某个月（点网格里上/下月的日子时用）
  void jumpTo(DateTime month) => state = DateTime(month.year, month.month);

  void today() {
    final now = DateTime.now();
    state = DateTime(now.year, now.month);
    ref.read(selectedDayProvider.notifier).select(now);
  }
}

/// 选中的那一天（月视图下面的事件列表按它过滤）
final selectedDayProvider = NotifierProvider<SelectedDayNotifier, DateTime>(
  SelectedDayNotifier.new,
);

class SelectedDayNotifier extends Notifier<DateTime> {
  @override
  DateTime build() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  void select(DateTime day) => state = DateTime(day.year, day.month, day.day);
}

/// 周起始日：官方设置里 `week_start_day` 用的是 **JS `Date.getDay()`** 口径
/// （0 = 周日），Dart 里 7 = 周日，所以要换一下。
int weekStartWeekday(int weekStartDay) {
  if (weekStartDay < 0 || weekStartDay > 6) return DateTime.sunday;
  return weekStartDay == 0 ? DateTime.sunday : weekStartDay;
}

/// 月视图的网格窗口：从"当月第一天所在周的周起始日"到"最后一天所在周的周六"。
///
/// [weekStartWeekday] 是 **Dart 口径**（1=周一 … 7=周日），调用方先过一遍
/// [weekStartWeekday] 把服务端的 JS 口径（0=周日）换过来。
({DateTime from, DateTime to}) monthGridWindow(
  DateTime anchor,
  int dartWeekStart,
) {
  final first = DateTime(anchor.year, anchor.month);
  final last = DateTime(anchor.year, anchor.month + 1, 0);
  final startWeekday = dartWeekStart;
  final lead = (first.weekday - startWeekday + 7) % 7;
  final from = first.subtract(Duration(days: lead));
  final tail = (startWeekday - 1 - last.weekday + 7) % 7;
  // 官方月视图固定 6 行，窗口给足（多取一周不影响，列表只渲染网格内的天）
  final to = last.add(Duration(days: tail + 7));
  return (from: from, to: to);
}

/// 某一周的 7 天（从周起始日开始）。
///
/// 周/日视图不额外打服务端：`monthEventsOfProvider` 的窗口是"当月首日所在周 ~
/// 末日所在周 +1 周"，**包含整周**，所以周视图在本月网格窗口里一定能取到数据。
List<DateTime> weekDays(DateTime day, int dartWeekStart) {
  final lead = (day.weekday - dartWeekStart + 7) % 7;
  final first = DateTime(
    day.year,
    day.month,
    day.day,
  ).subtract(Duration(days: lead));
  return [for (var i = 0; i < 7; i++) first.add(Duration(days: i))];
}

/// 月视图窗口内的事件（`Event/list`）。
///
/// 依赖：聚焦月份 + 周起始日设置 + 勾选的日历。筛选是**本地**的（不重新请求），
/// 所以勾选/取消勾选日历不会打服务端 —— 官方 Web UI 也是本地过滤 `cal_id_list`。
final monthEventsProvider = FutureProvider.autoDispose<List<CalEventDto>>((
  ref,
) {
  final anchor = ref.watch(calendarAnchorProvider);
  return ref.watch(monthEventsOfProvider(anchor).future);
}, retry: _noRetry);

/// **任意月份**的月视图事件。
///
/// 为什么要有它：月视图支持左右滑动换月（`_MonthPager`），拖动时**相邻两页
/// 也要有事件点**，所以不能只给"锚点那个月"取数据。锚点月通过
/// [monthEventsProvider] 复用同一份请求（同一个 family 实例，不会打两次）。
final monthEventsOfProvider = FutureProvider.autoDispose
    .family<List<CalEventDto>, DateTime>((ref, month) async {
      final api = ref.watch(calendarApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      final anchor = DateTime(month.year, month.month);
      final setting = await ref.watch(calSettingProvider.future);
      final picked = ref.watch(selectedCalIdsProvider);
      final calendars = await ref.watch(calendarsProvider.future);
      final ids = picked.isEmpty
          ? [for (final c in calendars) c.calId]
          : picked.toList();
      final window = monthGridWindow(
        anchor,
        weekStartWeekday(setting.weekStartDay),
      );
      final events = await api.listEvents(
        calendarIds: ids,
        from: window.from,
        to: window.to,
      );
      return events;
    }, retry: _noRetry);

/// 某天的事件（本地从 [monthEventsProvider] 里筛，不再打服务端）
final dayEventsProvider = Provider.autoDispose
    .family<List<CalEventDto>, DateTime>((ref, day) {
      final all = ref.watch(monthEventsProvider).value ?? const [];
      return [
        for (final e in all)
          if (_sameDay(e, day)) e,
      ]..sort(
        (a, b) => (a.start ?? DateTime(0)).compareTo(b.start ?? DateTime(0)),
      );
    });

/// 事件是否落在 [day]（跨天事件：只看开始日，和官方月视图的常规做法一致）
bool _sameDay(CalEventDto e, DateTime day) {
  final s = e.start;
  if (s == null) return false;
  return s.year == day.year && s.month == day.month && s.day == day.day;
}

/// 日历时区（服务端 `Setting/get` 的 `time_zone`）。
///
/// 环境信息（天气/节假日）要靠它兜底判断"这是哪儿"：服务端设置里通常就是
/// 用户所在时区。取不到就回空串（地区解析会继续往设备地区退）。
final calTimezoneProvider = Provider<String>((ref) {
  final setting = ref.watch(calSettingProvider).value;
  return setting?.timeZone ?? '';
}, dependencies: [calendarAnchorProvider]);

/// 当前月视图里出现过的**日程地点**线索（给地区解析用）。
///
/// 顺序有意义：按时间先后排，越近的日程越可能是"我现在在的地方"。
final eventLocationHintsProvider = Provider<List<EventLocationHint>>((ref) {
  final events = ref.watch(monthEventsProvider).value ?? const [];
  final sorted = [
    ...events,
  ]..sort((a, b) => (a.start ?? DateTime(0)).compareTo(b.start ?? DateTime(0)));
  final out = <EventLocationHint>[];
  final seen = <String>{};
  for (final e in sorted) {
    // ⚠️ 用**纠偏后**的 WGS84 坐标：百度/高德存的是偏移坐标，
    // 直接拿去反查国家会落到隔壁（见 `data/region/china_gps.dart`）
    final wgs = e.locationGpsWgs84;
    final hint = EventLocationHint(
      text: e.locationName.isNotEmpty ? e.locationName : e.locationAddress,
      latitude: wgs?.lat,
      longitude: wgs?.lng,
    );
    if (hint.isEmpty) continue;
    final key = '${hint.text}|${hint.latitude}|${hint.longitude}';
    if (seen.add(key)) out.add(hint);
  }
  return out;
});

/// **待办日历**（`Cal/list {cal_type:"todo"}`）。
///
/// ⚠️ 事件日历 ≠ 待办日历：官方 Web UI 的待办挂在待办日历（`…/home_todo/`）下，
/// 拿事件日历的 id 去 `Todo/list` 会一条都查不到（这就是"官方 App 里有待办、
/// 我们这儿空着"的原因）。没有独立待办日历时才退回事件日历。
final calTodoCalendarsProvider = FutureProvider.autoDispose<List<CalendarDto>>((
  ref,
) async {
  final api = ref.watch(calendarApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  try {
    final todoCals = await api.listTodoCalendars();
    if (todoCals.isNotEmpty) return todoCals;
  } catch (_) {
    // 老版本没有 todo 类型的日历：静默退回事件日历，不要让整页报错
  }
  return ref.watch(calendarsProvider.future);
}, retry: _noRetry);

/// 日历待办（`Todo/list`，未完成）
final calTodosProvider = FutureProvider.autoDispose<List<CalTodoDto>>((
  ref,
) async {
  final api = ref.watch(calendarApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  final calendars = await ref.watch(calTodoCalendarsProvider.future);
  // `filter_complete: all`（服务端只认 yes/no/all）：已完成的那几条也要拿到，
  // 才能在列表里划线显示并给出「清空已完成」——官方 Web UI 就是这个行为。
  return api.listTodos(
    calendarIds: [for (final c in calendars) c.calId],
    filterComplete: 'all',
  );
}, retry: _noRetry);

// ===========================================================================
// wave1（2026-09-22）
//
// 三个纪律，每个 provider 都照做：
//   1. **可选入口**失败 → 退化成"空/隐藏"，**不把整页带崩**；
//   2. 但**绝不把"接口失败"伪装成"数据是 0"**（待办角标用 `int?`，null = 不显示）；
//   3. 能力位（`service_registry.dart` 是禁改区）直接看 `SYNO.API.Info` 能力表。
// ===========================================================================

/// 事件配色候选（`Event/list_color` v6）。
///
/// 降级语义：
/// * `SYNO.Cal.Event` 的 maxVersion < 6（方法只在 v6）→ **空列表**，颜色选择器
///   整块隐藏（**不是**回退到写死的调色板）；
/// * 能力在但调用失败 → 同样空列表。
///
/// ⚠️ 回包形状未取证（见 `CalEventColorDto` 注释），所以这里只做"拿到什么用什么"。
final calEventColorsProvider = FutureProvider.autoDispose<List<CalEventColorDto>>(
  (ref) async {
    final api = ref.watch(calendarApiProvider);
    if (api == null) throw StateError(currentText().setNotConnected);
    if (!api.hasEventV6Api) return const [];
    try {
      return await api.listEventColors();
    } catch (_) {
      return const [];
    }
  },
  retry: _noRetry,
);

/// **待办数量角标**（`Todo/count_todo`，未完成）。
///
/// 返回 `int?`：**null = 不显示角标**（拿不到就宁可没有），`0` = 服务端明确说
/// 没有未完成待办。**两者不能混** —— 把失败当成 0 会让"接口挂了"看起来像
/// "待办清空了"（falsification ②）。
final calTodoUncompletedCountProvider = FutureProvider.autoDispose<int?>((
  ref,
) async {
  final api = ref.watch(calendarApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  final calendars = await ref.watch(calTodoCalendarsProvider.future);
  try {
    return await api.countTodos(
      calendarIds: [for (final c in calendars) c.calId],
    );
  } catch (_) {
    // 失败 → null（不显示角标）。不 rethrow：它只是角标，不该让整页进错误态。
    return null;
  }
}, retry: _noRetry);

/// 时区表（`Timezone/list`）—— 新建/编辑事件的时区选择。
///
/// 失败 → 空列表（选择器隐藏，事件仍用服务端设置里的时区，功能不残）。
final calTimezoneListProvider = FutureProvider.autoDispose<List<CalTimezoneDto>>(
  (ref) async {
    final api = ref.watch(calendarApiProvider);
    if (api == null) throw StateError(currentText().setNotConnected);
    if (!api.hasTimezoneApi) return const [];
    try {
      return await api.timezones();
    } catch (_) {
      return const [];
    }
  },
  retry: _noRetry,
);

/// 共享候选账号（`Share.Priv/list`）—— 共享日历编辑器的"加人"来源。
///
/// `SYNO.Cal.Share.Priv` 不存在 → 空列表，编辑器里"加人"整块隐藏，**只留
/// 只读成员展示 + 移除**（移除不需要候选列表）。
final calSharePrincipalsProvider =
    FutureProvider.autoDispose<List<CalSharePrincipalDto>>((ref) async {
      final api = ref.watch(calendarApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      if (!api.hasSharePrivApi) return const [];
      try {
        return await api.sharePrincipals();
      } catch (_) {
        return const [];
      }
    }, retry: _noRetry);

/// 某个日历的共享成员（`Sharing/get`，**只读**）。
///
/// `SYNO.Cal.Sharing` 不存在 → 空列表；调用失败 → 空列表（入口的"能否写"
/// 由页面层用 `api.hasSharingApi` 单独判，别靠这里是否为空推断）。
final calSharingOfProvider = FutureProvider.autoDispose
    .family<List<CalShareMemberDto>, String>((ref, calId) async {
      final api = ref.watch(calendarApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      if (!api.hasSharingApi || calId.isEmpty) return const [];
      try {
        return await api.calendarSharing(calId);
      } catch (_) {
        return const [];
      }
    }, retry: _noRetry);

/// **新建事件时的默认时区**（会话内覆盖；空串 = 用 `Setting/get` 里的时区）。
///
/// 为什么是会话内：改"默认时区"要落服务端 `Setting/set`，而它的参数虽然有
/// 包内 `openapi.json` 的 requestBody 属性表，**没有 entry.cgi 的真机写取证**
/// —— 按纪律"写不确定就只读并登记"（见 `docs/calendar-gaps-wave1.md`）。
/// 单条事件的时区是**写**在 `Event/create` 的 `tz_id` 里的（真机验过），
/// 所以这里只是个"新建时的初值"，不影响任何已验证的写路径。
final calDefaultTimeZoneProvider =
    NotifierProvider<CalDefaultTimeZoneNotifier, String>(
      CalDefaultTimeZoneNotifier.new,
    );

class CalDefaultTimeZoneNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String tzId) => state = tzId;
}

// ===========================================================================
// wave2（2026-09-22）—— 导出（`Cal.Cal/export` v1）与待办搜索（`Todo/search` v1）
//
// 两个都是**只读**接口；纪律同 wave1：可选入口失败 → 退化成"空/明确空态"，
// 绝不把"接口失败"伪装成"搜到了 0 条"。
// ===========================================================================

/// 可导出的日历（`Cal/list {cal_type:"event"}` **+** `{cal_type:"todo"}`）。
///
/// 为什么两类都要：真机上**事件日历与待办日历是两个 `cal_id`**
/// （`/demo_user/home/` 与 `/demo_user/home_todo/`），`Cal.Cal/export` 两者都能导
/// （真机都调通）。只列事件日历会让待办日历永远导不出来。
///
/// 去重按 `calId`：`calTodoCalendarsProvider` 在没有待办日历时会**退回事件
/// 日历**，不去重会出现两遍同名条目。
final calExportCalendarsProvider =
    FutureProvider.autoDispose<List<CalendarDto>>((ref) async {
      List<CalendarDto> event = const [];
      try {
        event = await ref.watch(calendarsProvider.future);
      } catch (_) {
        // 事件日历拿不到不该挡住待办日历的导出
      }
      var todo = const <CalendarDto>[];
      try {
        todo = await ref.watch(calTodoCalendarsProvider.future);
      } catch (_) {
        // 老包没有 todo 类型的日历：只用事件日历
      }
      final seen = <String>{};
      return [
        for (final c in [...event, ...todo])
          if (c.calId.isNotEmpty && seen.add(c.calId)) c,
      ];
    }, retry: _noRetry);

/// 待办搜索（`Todo/search` v1，`keyword`）。
///
/// 空关键字**不请求**：直接回空结果（面板给明确空态），避免发一次无意义的
/// 空参调用。失败**如实抛出**（页面按 [describeCalendarError] 明说），
/// **不吞成"0 条"** —— "搜不到"和"搜索接口挂了"必须能分辨。
final calTodoSearchProvider = FutureProvider.autoDispose
    .family<CalTodoSearchResultDto, String>((ref, keyword) async {
      final api = ref.watch(calendarApiProvider);
      if (api == null) throw StateError(currentText().setNotConnected);
      final kw = keyword.trim();
      if (kw.isEmpty) return const CalTodoSearchResultDto();
      return api.searchTodos(keyword: kw);
    }, retry: _noRetry);
