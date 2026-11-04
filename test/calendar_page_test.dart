// 日历页的离线 UI 测试：月视图网格 / 选中日列表 / 新建 / 删除 / 日历分组 / 错误态。
//
// 真机流程（装 APK → 点 → 看 NAS 回读）另做；这里用假传输把**页面行为**钉死，
// 与笔记/相册/联系人的离线测试同思路。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/analytics_database.dart';
import 'package:synhub/src/features/analytics/analytics_track.dart';
import 'package:synhub/src/features/analytics/usage_event.dart';
import 'package:synhub/src/features/analytics/usage_log.dart';
import 'package:synhub/src/data/calendar_api.dart';
import 'package:synhub/src/data/region/device_location.dart';
import 'package:synhub/src/data/region/region_context.dart';
import 'package:synhub/src/data/weather/weather_client.dart';
import 'package:synhub/src/data/dto/calendar_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/calendar/calendar_env.dart';
import 'package:synhub/src/features/calendar/calendar_page.dart';
import 'package:synhub/src/features/calendar/weather_backdrop.dart';
import 'package:synhub/src/features/calendar/calendar_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _calTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Cal.Cal': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Event': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Setting': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Todo': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
};

Map<String, dynamic> _event({
  required String id,
  required String summary,
  required String dtstart,
  String calId = '/demo_user/home/',
  String color = '',
  bool allDay = false,
  String description = '',
}) => {
  'evt_id': id,
  'cal_id': calId,
  'original_cal_id': calId,
  'summary': summary,
  'description': description,
  'dtstart_string': dtstart,
  'dtend_string': dtstart,
  'is_all_day': allDay,
  'tz_id': 'Asia/Shanghai',
  'color': color,
  'is_repeat_evt': false,
  'dav_etag': 'etag-$id',
  'ical_uid': 'uid-$id',
  'owner_name': 'demo_user',
  'location_info': {
    'name': '',
    'address': '',
    'gps': {'lat': -1, 'lng': -1},
    'map_type': '',
    'place_id': '',
  },
  'participant': <Object>[],
  'notify_setting': <Object>[],
  'attachments': <Object>[],
};

/// 假定位探针：测试里绝不碰 MethodChannel
class _NoLocation implements DeviceLocationProbe {
  @override
  Future<LocationPermission> ensurePermission({
    bool interactive = true,
  }) async => LocationPermission.unsupported;

  @override
  Future<bool> serviceEnabled() async => false;

  @override
  Future<DeviceLocation?> current() async => null;

  @override
  Future<void> clearCache() async {}
}

/// 用假传输装好 CalendarApi，并挂上 [CalendarPage]
/// 页面测试默认没有天气（背景回中性"多云"）；要验背景就传 [weather]
Future<({FakeTransport t, ProviderContainer container})> _boot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, int> failures = const {},
  WeatherBundle? weather,
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._calTable});
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final cal = CalendarApi(api);
  final container = ProviderContainer(
    overrides: [
      calendarApiProvider.overrideWithValue(cal),
      // 页面现在会挂**整页天气背景**（`WeatherBackdrop`），环境卡片也要地区/天气：
      // 全部钉死，测试才不碰网络、不碰定位插件（否则 Open-Meteo 真会被请求）。
      calendarRegionProvider.overrideWith(
        (ref) async => const RegionContext(
          countryCode: 'CN',
          city: '北京',
          timezone: 'Asia/Shanghai',
          latitude: 39.9042,
          longitude: 116.4074,
          source: RegionSource.manual,
        ),
      ),
      weatherBundleProvider.overrideWith((ref) async => weather),
      holidayBundleProvider.overrideWith((ref) async => null),
      deviceLocationProbeProvider.overrideWithValue(_NoLocation()),
    ],
  );
  addTearDown(container.dispose);
  return (t: t, container: container);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  tester.view.physicalSize = const Size(1148, 2492);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  // ⚠️ 待办要多一跳：`calTodosProvider` 先问 `Cal/list {cal_type:"todo"}` 拿待办
  // 日历，再问 `Todo/list`（事件日历 ≠ 待办日历）。少 pump 一次就会断言到空列表。
  await tester.pump(const Duration(milliseconds: 50));
}

/// 把选中日列表往下滚一段：待办小节在事件下面，屏幕外时 ListView 不会建出它的
/// element（`cacheExtent` 只有 250px），`find.text` 会误报"没有待办"。
Future<void> _scrollDayList(WidgetTester tester, [double dy = -400]) async {
  await tester.drag(find.byType(Scrollable).last, Offset(0, dy));
  await tester.pump();
}

/// 滚到目标可见再点：待办小节在事件/空态下面，固定距离的拖动会让按钮滑出视口，
/// `tap()` 会"点空"（warnIfMissed）——真机上用户也是先滚再点。
Future<void> _tapTodo(WidgetTester tester, Finder f) async {
  await _scrollDayList(tester);
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
}

/// 顶部那行的按钮（新建待办/清空已完成）：不用先滚，滚了反而把它顶出视口。
Future<void> _tapHeaderButton(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
}

/// 固定"今天"，让断言与运行日期无关
DateTime get _today {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

String _stamp(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}'
    'T090000';

/// 中文星期（与页面里的 `_cnWeekday` 同口径，测试断言文案用）
String _cnWeekdayFor(DateTime d) =>
    const ['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1];

/// 埋点断言用：装一个内存日志并挂成全局单例
Future<UsageLog> armUsageLog() async {
  final db = AnalyticsDatabase.memory();
  final log = UsageLog(db);
  await log.load();
  setGlobalUsageLog(log);
  addTearDown(() async {
    setGlobalUsageLog(null);
    log.dispose();
    await db.close();
  });
  return log;
}

Future<List<UsageEvent>> drainUsageLog(
  WidgetTester tester,
  UsageLog log,
) async {
  await tester.runAsync(() => log.flush());
  final rows = await tester.runAsync(() => log.recent());
  return rows!;
}

/// 重复事件里**普通的那一次**（真机探针：`is_repeat_evt` 为 true、`repeat_setting` 在、
/// `recurrence_id` 是 **null**，每一次都共用母事件的 `evt_id`）
Map<String, dynamic> _repeatEvent({
  required String id,
  required String summary,
  String dtstart = '20260919T090000',
  String? recurrenceId,
}) => {
  ..._event(id: id, summary: summary, dtstart: dtstart),
  'is_repeat_evt': true,
  'recurrence_id': recurrenceId,
  'dav_etag': 'etag-$id',
  'repeat_setting': {
    'type': 'week',
    'interval': 1,
    'weekday': ['saturday'],
    'week_start_day': 'sunday',
    'end': {'type': 'never', 'count': 1},
  },
};

/// **被单独改过的那一次**（真机探针：`subevent_set` 之后 `is_repeat_evt` 消失、
/// `repeat_setting` 消失、只有 `recurrence_id` 有值，但 `evt_id` 仍是母事件的）
Map<String, dynamic> _repeatOverride({
  required String id,
  required String summary,
  required String dartStartString,
}) => {
  ..._event(id: id, summary: summary, dtstart: dartStartString),
  'is_repeat_evt': null,
  'recurrence_id': dartStartString,
  'dav_etag': 'etag-$id',
};

void main() {
  testWidgets('月视图：网格渲染 + 选中日事件列表 + 事件条', (tester) async {
    final today = _today;
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_color': '#B240AF',
            'cal_privilege': 'RW',
            'cal_type': 'event',
            'default_calendar': true,
            'original_cal_id': '/demo_user/home/',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {
        'time_zone': 'Asia/Shanghai',
        'week_start_day': 0,
        'date_format': 'Y-m-d',
        'time_format': '24',
      },
      'SYNO.Cal.Event.list': {
        'list': [
          _event(
            id: '1',
            summary: '产品评审',
            dtstart: _stamp(today),
            color: '#B240AF',
          ),
          _event(
            id: '2',
            summary: '全天团建',
            dtstart: _stamp(today),
            allDay: true,
          ),
        ],
      },
      'SYNO.Cal.Todo.list': {
        'list': [
          {
            'evt_id': 9,
            'summary': '买牛奶',
            'percent_complete': 0,
            'due_string': '${today.year}0919T180000',
          },
        ],
      },
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    // 头部与网格
    expect(find.text('日历'), findsWidgets);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('产品评审'), findsWidgets);
    // 事件列表（选中日）
    expect(find.text('全天团建'), findsWidgets);
    // 待办小节（在事件下面，先滚下去）
    await _scrollDayList(tester);
    expect(find.text('待办（1）'), findsOneWidget);
    expect(find.text('买牛奶'), findsOneWidget);

    // Event/list 的窗口必须覆盖当月网格
    final call = b.t.calls.lastWhere(
      (c) => c['method'] == 'list' && c['api'] == 'SYNO.Cal.Event',
    );
    expect(call['cal_id_list'], '["/demo_user/home/"]');
    expect(call['version'], '6');
  });

  testWidgets('切月份：点「下月」重新请求，网格标题跟着变', (tester) async {
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_color': '#B240AF',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {
        'week_start_day': 0,
        'time_zone': 'Asia/Shanghai',
      },
      'SYNO.Cal.Event.list': {'list': <Object>[]},
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));
    final before = b.t.calls.where((c) => c['api'] == 'SYNO.Cal.Event').length;

    await tester.tap(find.byKey(const Key('cal-next-month')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final after = b.t.calls.where((c) => c['api'] == 'SYNO.Cal.Event').length;
    expect(after, greaterThan(before), reason: '换月要重新拉事件');
    // 网格里仍渲染（不崩）—— 按 `cal-month-pager` key 精确断言：
    // 第 270 轮把切换器标签缩成「月/周/日」后，`find.text('日')` 会同时命中
    // 月网格的周列表头「日」，不再唯一。
    expect(find.byKey(const Key('cal-month-pager')), findsOneWidget);
  });

  testWidgets('月视图支持左右滑动换月（左滑=下月、右滑=上月）', (tester) async {
    final log = await armUsageLog();
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);
    final next = DateTime(now.year, now.month + 1);
    final prev = DateTime(now.year, now.month - 1);
    String label(DateTime m) => '${m.year}年${m.month}月';

    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_color': '#B240AF',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {
        'week_start_day': 0,
        'time_zone': 'Asia/Shanghai',
      },
      'SYNO.Cal.Event.list': {'list': <Object>[]},
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(label(thisMonth)), findsOneWidget);

    // 左滑 → 下个月
    await tester.drag(
      find.byKey(const Key('cal-month-pager')),
      const Offset(-400, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(label(next)), findsOneWidget, reason: '左滑应该翻到下个月');

    // 右滑 → 回到上个月
    await tester.drag(
      find.byKey(const Key('cal-month-pager')),
      const Offset(400, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(label(thisMonth)), findsOneWidget, reason: '右滑应该翻回上个月');

    // 再右滑一次 → 上个月
    await tester.drag(
      find.byKey(const Key('cal-month-pager')),
      const Offset(400, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(label(prev)), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 使用日志：三次换月 = 三条 calendar/switch_section(month)
    final rows = await drainUsageLog(tester, log);
    expect(rows, hasLength(3));
    expect(
      rows.every(
        (e) =>
            e.module == UsageModule.calendar &&
            e.action == UsageAction.switchSection &&
            e.objectType == 'month',
      ),
      isTrue,
    );
  });

  testWidgets('DA173：相邻月份的日期必须看得清（对比度 ≥ 4.5:1，不许再乘 alpha）', (tester) async {
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_color': '#B240AF',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {'week_start_day': 0, 'time_zone': 'Asia/Shanghai'},
      'SYNO.Cal.Event.list': {'list': <Object>[]},
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
    });
    await _pump(tester, b.container, const CalendarPage());

    final scheme = Theme.of(tester.element(find.byType(CalendarPage))).colorScheme;

    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    // 网格里的日期数字：只挑**带显式颜色**的那些（本月是 null，走默认正文色）
    final dayTexts = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => RegExp(r'^[0-9]{1,2}$').hasMatch(t.data ?? ''))
        .where((t) => t.style?.color != null)
        .toList();
    expect(dayTexts, isNotEmpty, reason: 'DA173：应当能找到相邻月份的日期数字');
    for (final t in dayTexts) {
      final c = t.style!.color!;
      expect(c.a, 1.0,
          reason: 'DA173：日期色被乘了 alpha（${c.a}），合成后只剩约 2:1');
      final ratio = contrast(c, scheme.surface);
      expect(ratio, greaterThanOrEqualTo(4.5),
          reason: 'DA173：相邻月日期对比度只有 ${ratio.toStringAsFixed(2)}:1');
    }
  });

  testWidgets('滑到相邻月后，网格里那个月的日子也能点（选中日列表跟着走）', (tester) async {
    final now = DateTime.now();
    final next = DateTime(now.year, now.month + 1);
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_color': '#B240AF',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {
        'week_start_day': 0,
        'time_zone': 'Asia/Shanghai',
      },
      'SYNO.Cal.Event.list': {'list': <Object>[]},
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.drag(
      find.byKey(const Key('cal-month-pager')),
      const Offset(-400, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('${next.year}年${next.month}月'), findsOneWidget);

    // 第二天（下个月的 2 号）应该能点，并且底部列表标题跟着变
    await tester.tap(find.text('2').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('${next.month} 月 2 日'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建日程：走 Event/create，参数是官方形态', (tester) async {
    final today = _today;
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_color': '#B240AF',
            'cal_privilege': 'RW',
            'cal_type': 'event',
            'original_cal_id': '/demo_user/home/',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {
        'week_start_day': 0,
        'time_zone': 'Asia/Shanghai',
      },
      'SYNO.Cal.Event.list': {'list': <Object>[]},
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
      'SYNO.Cal.Event.create': _event(
        id: '77',
        summary: '新日程',
        dtstart: _stamp(today),
      ),
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('cal-new-event')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('新建日程'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('cal-editor-title')), '新日程');
    await tester.enterText(find.byKey(const Key('cal-editor-desc')), '说明');
    await tester.tap(find.byKey(const Key('cal-editor-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final create = b.t.calls.lastWhere((c) => c['method'] == 'create');
    expect(create['api'], 'SYNO.Cal.Event');
    expect(create['version'], '6');
    expect(create['summary'], '"新日程"', reason: '字符串要 Gson 引号串');
    expect(create['cal_id'], '"/demo_user/home/"');
    expect(create['original_cal_id'], '"/demo_user/home/"');
    expect(create['tz_id'], '"Asia/Shanghai"');
    expect(create['description'], '"说明"');
    expect(create['is_all_day'], 'false');
    expect(create['participant'], '[]');
    expect(create['notify_setting'], '[]');
  });

  testWidgets('标题为空时不发请求，给提示', (tester) async {
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {'week_start_day': 0},
      'SYNO.Cal.Event.list': {'list': <Object>[]},
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('cal-new-event')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('cal-editor-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(b.t.calls.where((c) => c['method'] == 'create'), isEmpty);
    expect(find.text('标题不能为空'), findsOneWidget);
  });

  testWidgets('事件详情：删除走 Event/delete，evt_id 是裸串', (tester) async {
    final today = _today;
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {'week_start_day': 0},
      'SYNO.Cal.Event.list': {
        'list': [_event(id: '42', summary: '要删的事', dtstart: _stamp(today))],
      },
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
      'SYNO.Cal.Event.delete': <String, dynamic>{},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.widgetWithText(DesignRowTile, '要删的事'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('创建者 demo_user'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cal-delete-event')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final del = b.t.calls.lastWhere((c) => c['method'] == 'delete');
    expect(del['api'], 'SYNO.Cal.Event');
    expect(del['evt_id'], '42', reason: '"42" 会回 9009');
    expect(del['version'], '6');
  });

  testWidgets('编辑日程：详情「编辑」→ 预填 → 保存走 Event/set（evt_id 裸串 + dav_etag）', (
    tester,
  ) async {
    final today = _today;
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {
        'time_zone': 'Asia/Shanghai',
        'week_start_day': 0,
      },
      'SYNO.Cal.Event.list': {
        'list': [
          _event(
            id: '42',
            summary: '原标题',
            dtstart: _stamp(today),
            description: '原说明',
          ),
        ],
      },
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
      'SYNO.Cal.Event.set': _event(
        id: '42',
        summary: '新标题',
        dtstart: _stamp(today),
      ),
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.widgetWithText(DesignRowTile, '原标题'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('cal-edit-event')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 预填：标题/说明都带出来了，且不再显示"新建日程"
    expect(find.text('编辑日程'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('cal-editor-title')))
          .controller!
          .text,
      '原标题',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('cal-editor-desc')))
          .controller!
          .text,
      '原说明',
    );

    await tester.enterText(find.byKey(const Key('cal-editor-title')), '新标题');
    await tester.tap(find.byKey(const Key('cal-editor-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final call = b.t.calls.lastWhere((c) => c['method'] == 'set');
    expect(call['api'], 'SYNO.Cal.Event');
    expect(call['version'], '6');
    expect(call['evt_id'], '42', reason: '裸串');
    expect(call['dav_etag'], '"etag-42"');
    expect(call['summary'], '"新标题"');
    expect(call['tz_id'], '"Asia/Shanghai"');
    expect(call['is_all_day'], 'false');
    expect(jsonDecode(call['participant']! as String), isEmpty);
    expect(jsonDecode(call['notify_setting']! as String), isEmpty);
    // 没有再建一条新的
    expect(b.t.calls.where((c) => c['method'] == 'create'), isEmpty);
    expect(find.text('已更新「新标题」'), findsOneWidget);
  });

  testWidgets('编辑重复日程：编辑本次走 subevent_set（带 recurrence_id），编辑整个走 set', (
    tester,
  ) async {
    final today = _today;
    Map<String, dynamic> calList() => {
      'list': [
        {
          'cal_id': '/demo_user/home/',
          'cal_displayname': 'My Calendar',
          'cal_privilege': 'RW',
          'cal_type': 'event',
        },
      ],
    };
    final b = await _boot({
      'SYNO.Cal.Cal.list': calList(),
      'SYNO.Cal.Setting.get': {
        'time_zone': 'Asia/Shanghai',
        'week_start_day': 0,
      },
      // 真机：系列里普通的那一次 `recurrence_id` 是 null，靠 dtstart_string 定位
      'SYNO.Cal.Event.list': {
        'list': [
          _repeatEvent(id: '77', summary: '每周站会', dtstart: _stamp(today)),
        ],
      },
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
      'SYNO.Cal.Event.subevent_set': _repeatEvent(
        id: '77',
        summary: '本周站会',
        dtstart: _stamp(today),
      ),
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.widgetWithText(DesignRowTile, '每周站会'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 重复事件给的是"编辑本次 / 编辑整个"两档
    expect(find.byKey(const Key('cal-edit-event')), findsNothing);
    await tester.tap(find.byKey(const Key('cal-edit-event-this')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // "本次"时重复规则只读（规则属于整个系列）
    expect(find.byKey(const Key('cal-editor-repeat-locked')), findsOneWidget);
    expect(find.byKey(const Key('cal-editor-repeat')), findsNothing);

    await tester.enterText(find.byKey(const Key('cal-editor-title')), '本周站会');
    await tester.tap(find.byKey(const Key('cal-editor-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final sub = b.t.calls.lastWhere((c) => c['method'] == 'subevent_set');
    expect(sub['version'], '6');
    expect(sub['evt_id'], '77', reason: '母事件的 id，裸串');
    expect(sub['recurrence_id'], _stamp(today), reason: '这一次的身份，裸串');
    expect(sub['is_repeat_evt'], 'true');
    expect(sub['summary'], '"本周站会"');
    expect(find.text('已更新这一次「本周站会」'), findsOneWidget);
  });

  testWidgets('编辑整个重复系列：母事件用 Event/get 拿（列表里那一行挪不动系列）', (tester) async {
    final today = _today;
    // 母事件的起点是**上周**（列表这个月根本看不到它）：
    // 只用列表里最早的那一行会把整个系列挪到本月
    final seriesStart = today.subtract(const Duration(days: 7));
    final d2 = today.add(const Duration(days: 7));
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {
        'time_zone': 'Asia/Shanghai',
        'week_start_day': 0,
      },
      'SYNO.Cal.Event.list': {
        'list': [
          // 这个月能看到的两行：一次被单独改过、一次照旧
          _repeatOverride(
            id: '78',
            summary: '站会（这次改过）',
            dartStartString: _stamp(d2),
          ),
          _repeatEvent(id: '78', summary: '每周站会', dtstart: _stamp(today)),
        ],
      },
      // `Event/get(母事件 id)` → 系列起点（上周），且带 `repeat_setting`
      'SYNO.Cal.Event.get': _repeatEvent(
        id: '78',
        summary: '每周站会',
        dtstart: _stamp(seriesStart),
      ),
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
      'SYNO.Cal.Event.set': _repeatEvent(
        id: '78',
        summary: '站会（改名）',
        dtstart: _stamp(today),
      ),
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.widgetWithText(DesignRowTile, '每周站会').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('cal-edit-event-all')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 整个系列：重复规则可以改（选择器在）
    expect(find.byKey(const Key('cal-editor-repeat')), findsOneWidget);
    expect(find.byKey(const Key('cal-editor-repeat-locked')), findsNothing);

    await tester.enterText(find.byKey(const Key('cal-editor-title')), '站会（改名）');
    await tester.tap(find.byKey(const Key('cal-editor-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final set = b.t.calls.lastWhere((c) => c['method'] == 'set');
    expect(set['evt_id'], '78');
    expect(set['summary'], '"站会（改名）"');
    expect(set['is_repeat_evt'], 'true');
    // 开始时间必须是 Event/get 给的**系列起点**（上周），
    // 不能是列表里那一行（今天/下周），也不能是那条被单独改过的行
    expect(
      set['dtstart'],
      '${DateTime(seriesStart.year, seriesStart.month, seriesStart.day, 9).millisecondsSinceEpoch ~/ 1000}',
      reason: '母事件的开始 = Event/get 给的系列起点',
    );
    // 重复规则原样保留（改系列不能把规则丢了）
    final rule = jsonDecode(set['repeat_setting']! as String) as Map;
    expect(rule['type'], 'week');
    expect(find.text('已更新整个重复日程「站会（改名）」'), findsOneWidget);
  });

  testWidgets('编辑整个：Event/get 失败时退化成"列表里 recurrence_id 为空的最早一行"', (
    tester,
  ) async {
    final today = _today;
    final d2 = today.add(const Duration(days: 7));
    final b = await _boot(
      {
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': '/demo_user/home/',
              'cal_displayname': 'My Calendar',
              'cal_privilege': 'RW',
              'cal_type': 'event',
            },
          ],
        },
        'SYNO.Cal.Setting.get': {
          'time_zone': 'Asia/Shanghai',
          'week_start_day': 0,
        },
        'SYNO.Cal.Event.list': {
          'list': [
            // 顺序打乱 + 一条被改过的行在前面：退化路径也不能选中它
            _repeatOverride(
              id: '79',
              summary: '改过的那次',
              dartStartString: _stamp(today),
            ),
            _repeatEvent(id: '79', summary: '每周站会', dtstart: _stamp(d2)),
            _repeatEvent(id: '79', summary: '每周站会', dtstart: _stamp(today)),
          ],
        },
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
        'SYNO.Cal.Event.set': _repeatEvent(
          id: '79',
          summary: '站会（改名）',
          dtstart: _stamp(today),
        ),
      },
      failures: {'SYNO.Cal.Event.get': 1},
    );
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.widgetWithText(DesignRowTile, '每周站会').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('cal-edit-event-all')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byKey(const Key('cal-editor-title')), '站会（改名）');
    await tester.tap(find.byKey(const Key('cal-editor-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final set = b.t.calls.lastWhere((c) => c['method'] == 'set');
    expect(
      set['dtstart'],
      '${DateTime(today.year, today.month, today.day, 9).millisecondsSinceEpoch ~/ 1000}',
      reason: '退化成列表里"没被改过"的最早一行（今天），不是被改过的那行也不是下周',
    );
    final rule = jsonDecode(set['repeat_setting']! as String) as Map;
    expect(rule['type'], 'week', reason: '退化路径也必须保住重复规则');
  });

  testWidgets('被单独改过的那一次：详情仍按重复系列给按钮（否则一删删整个系列）', (tester) async {
    final today = _today;
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {
        'time_zone': 'Asia/Shanghai',
        'week_start_day': 0,
      },
      'SYNO.Cal.Event.list': {
        'list': [
          _repeatOverride(
            id: '80',
            summary: '只改过这一次',
            dartStartString: _stamp(today),
          ),
        ],
      },
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
      'SYNO.Cal.Event.set_exdate': <String, dynamic>{},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.widgetWithText(DesignRowTile, '只改过这一次'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // `is_repeat_evt` 是 null、`repeat_setting` 也没有，但 `recurrence_id` 有值
    expect(find.byKey(const Key('cal-edit-event-this')), findsOneWidget);
    expect(find.byKey(const Key('cal-edit-event-all')), findsOneWidget);
    expect(find.byKey(const Key('cal-edit-event')), findsNothing);
    expect(find.byKey(const Key('cal-delete-event-this')), findsOneWidget);
    expect(find.byKey(const Key('cal-delete-event')), findsNothing);

    await tester.tap(find.byKey(const Key('cal-delete-event-this')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final call = b.t.calls.lastWhere((c) => c['method'] == 'set_exdate');
    expect(call['evt_id'], '80');
    expect(call['exdate'], _stamp(today), reason: '用 recurrence_id 定位这一次');
    expect(
      b.t.calls.any((c) => c['method'] == 'delete'),
      isFalse,
      reason: '绝不能把母事件删掉（整个系列会没）',
    );
  });

  // ---------- 月 / 周 / 日视图（计划 §11.1 第 3 项） ----------

  Map<String, dynamic> oneCal() => {
    'list': [
      {
        'cal_id': '/demo_user/home/',
        'cal_displayname': 'My Calendar',
        'cal_color': '#B240AF',
        'cal_privilege': 'RW',
        'cal_type': 'event',
        'default_calendar': true,
        'original_cal_id': '/demo_user/home/',
      },
    ],
  };

  testWidgets('整页天气背景：跟着"选中那天"的天气，且文字在最上层', (tester) async {
    final today = _today;
    final rainy = today.add(const Duration(days: 1));
    final b = await _boot(
      {
        'SYNO.Cal.Cal.list': oneCal(),
        'SYNO.Cal.Setting.get': {
          'time_zone': 'Asia/Shanghai',
          'week_start_day': 0,
        },
        'SYNO.Cal.Event.list': {'list': <Object>[]},
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
      },
      // 今天晴、明天雨：切一天，背景就该从"日光"变成"雨"
      weather: WeatherBundle(
        providerId: 'open-meteo',
        now: const WeatherNow(
          providerId: 'open-meteo',
          temperatureC: 20,
          code: 0,
        ),
        days: [
          WeatherDay(date: today, code: 0, minC: 10, maxC: 20),
          WeatherDay(date: rainy, code: 61, minC: 9, maxC: 15),
        ],
      ),
    );
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    WeatherScene sceneOf(WidgetTester t) =>
        t.widget<WeatherBackdrop>(find.byType(WeatherBackdrop)).scene;

    expect(find.byType(WeatherBackdrop), findsOneWidget);
    expect(sceneOf(tester), WeatherScene.clearDay, reason: '今天是晴（WMO 0）');
    // 背景层在，且内容是 Stack 的最后一层（后画 = 在上面，文字不被虚化）
    expect(find.byKey(const Key('weather-backdrop-particles')), findsOneWidget);
    final stack = tester.widget<Stack>(
      find
          .ancestor(
            of: find.byKey(const Key('weather-backdrop-particles')),
            matching: find.byType(Stack),
          )
          .first,
    );
    expect(
      (stack.children.last as Positioned).child,
      isNotNull,
      reason: '内容层是最后一个孩子',
    );

    // 换选中日 → 背景跟着变（同一份天气数据，只换"那天"）
    b.container.read(selectedDayProvider.notifier).select(rainy);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(sceneOf(tester), WeatherScene.rain, reason: '明天 61 → 雨');
    expect(find.byKey(const Key('weather-backdrop-particles')), findsOneWidget);
  });

  testWidgets('视图切换：周视图铺开一周 7 天，日视图给事件加时间刻度', (tester) async {
    final today = _today;
    final week = weekDays(today, DateTime.sunday);
    final b = await _boot({
      'SYNO.Cal.Cal.list': oneCal(),
      'SYNO.Cal.Setting.get': {
        'time_zone': 'Asia/Shanghai',
        'week_start_day': 0,
      },
      'SYNO.Cal.Event.list': {
        'list': [
          _event(id: '1', summary: '周一例会', dtstart: _stamp(week[1])),
          _event(id: '2', summary: '周三评审', dtstart: _stamp(week[3])),
        ],
      },
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    // 三种视图的切换器一直在
    expect(find.byKey(const Key('cal-view-switcher')), findsOneWidget);
    expect(find.byKey(const Key('cal-week-day-1')), findsNothing);

    await tester.tap(find.byKey(const Key('cal-view-week')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 一周 7 列（不管跨不跨月）
    for (final d in week) {
      expect(
        find.byKey(Key('cal-week-day-${d.day}')),
        findsOneWidget,
        reason: '周视图要有 ${d.month}/${d.day} 这一列',
      );
    }
    // 事件落在自己的列里（两天的标题都在同屏）。
    //
    // ⚠️ 必须按"周视图的那一列"作用域断言：`_DayList`（当日事件列表）是**无条件渲染**的，
    // 周视图只是在它上面再加一块 `_WeekBoard`。所以当"今天"正好是周一/周三时，同一标题
    // 会同时出现在周视图列与下方当日列表里，裸 `find.text` 会数到 2 个
    // ——2026-09-21（周一）就因此被误报成回归。按列作用域后与运行日期无关。
    final monTile = find.descendant(
      of: find.byKey(Key('cal-week-col-${week[1].day}')),
      matching: find.text('周一例会'),
    );
    final wedTile = find.descendant(
      of: find.byKey(Key('cal-week-col-${week[3].day}')),
      matching: find.text('周三评审'),
    );
    expect(monTile, findsOneWidget, reason: '周一那列里应有「周一例会」');
    expect(wedTile, findsOneWidget, reason: '周三那列里应有「周三评审」');
    expect(find.text('那一周'), findsNothing, reason: '标题是纯文本，不该拆开匹配');

    // 周视图里点事件 → 同一个详情弹层（同样要按列作用域点，避免"今天=周三"时点到
    // 下方当日列表里的同名那条）
    await tester.tap(wedTile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('创建者 demo_user'), findsOneWidget);
    // 关闭弹层：标题栏那个 close 图标（`tooltip: 关闭`，不是文字）。
    // ⚠️ 这条同时是回归：老代码 `pop(false)` 在这条路由上会抛类型错误、弹层关不掉，
    // 后面再点切换器就点到遮罩上了（"模式没切"）。
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('创建者 demo_user'), findsNothing, reason: '点关闭要真的关掉弹层');

    // 切到日视图：事件行左边出现时间刻度，副标题不再重复写时间
    await tester.tap(find.byKey(const Key('cal-view-day')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // 切到日视图 = 周看板整块消失（周列 key 不再存在）
    expect(
      find.byKey(Key('cal-week-day-${today.day}')),
      findsNothing,
      reason: '日视图不该再画周看板',
    );
    expect(
      find.text('${today.month}月${today.day}日 那一周'),
      findsNothing,
      reason: '导航文案不再是"那一周"',
    );
    // 今天（周日）这一天有上周日的事件吗？—— 这天没有，先切到有事件的那天
    await tester.tap(find.byKey(const Key('cal-next-month')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final next = today.add(const Duration(days: 1));
    expect(
      find.text('${next.month} 月 ${next.day} 日 · 周${_cnWeekdayFor(next)}'),
      findsWidgets,
      reason:
          '日视图按天翻页（找到的文本：'
          '${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).where((d) => d != null && d.contains('月')).toList()}）',
    );
  });

  testWidgets('日视图：事件行有时间刻度（09:00），待办小节照旧在下面', (tester) async {
    final today = _today;
    final b = await _boot({
      'SYNO.Cal.Cal.list': oneCal(),
      'SYNO.Cal.Setting.get': {
        'time_zone': 'Asia/Shanghai',
        'week_start_day': 0,
      },
      'SYNO.Cal.Event.list': {
        'list': [
          _event(id: '3', summary: '晨会', dtstart: _stamp(today)),
          _event(
            id: '4',
            summary: '全天事',
            // `dtstart_string` 仍带 T000000：DTO 靠它解析 start，全天只是 is_all_day
            dtstart:
                '${today.year}${today.month.toString().padLeft(2, '0')}'
                '${today.day.toString().padLeft(2, '0')}T000000',
            allDay: true,
          ),
        ],
      },
      'SYNO.Cal.Todo.list': {
        'list': [
          {
            'todo_id': 't1',
            'cal_id': '/demo_user/home/',
            'summary': '写周报',
            'is_done': false,
            'due_date': _stamp(today),
            'priority': 0,
          },
        ],
      },
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('cal-view-day')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('09:00'), findsOneWidget, reason: '日视图左侧时间刻度');
    expect(find.text('全天'), findsWidgets, reason: '全天事件刻度写"全天"');
    expect(find.text('晨会'), findsOneWidget);
    // 副标题只留日历名（时间已经在刻度里）
    expect(find.text('My Calendar'), findsWidgets);
    expect(find.textContaining('09:00 – 10:00'), findsNothing);
    expect(find.text('待办（1）'), findsWidgets, reason: '日视图也要有待办小节');
  });

  testWidgets('周视图：点列头选中那天（FAB 的「日程」就建在那天）', (tester) async {
    final today = _today;
    final week = weekDays(today, DateTime.sunday);
    final target = week[3]; // 周三
    final b = await _boot({
      'SYNO.Cal.Cal.list': oneCal(),
      'SYNO.Cal.Setting.get': {
        'time_zone': 'Asia/Shanghai',
        'week_start_day': 0,
      },
      'SYNO.Cal.Event.list': {
        'list': [_event(id: '1', summary: '周一例会', dtstart: _stamp(week[1]))],
      },
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('cal-view-week')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(Key('cal-week-day-${target.day}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text(
        '${target.month} 月 ${target.day} 日 · 周${_cnWeekdayFor(target)}',
      ),
      findsWidgets,
      reason: '点列头就把"选中日"改到那天（下面日列表跟着变）',
    );
  });

  testWidgets('只读日历不给删除按钮', (tester) async {
    final today = _today;
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'Shared',
            'cal_privilege': 'RO',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {'week_start_day': 0},
      'SYNO.Cal.Event.list': {
        'list': [_event(id: '5', summary: '别人建的', dtstart: _stamp(today))],
      },
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(DesignRowTile, '别人建的'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('只读日历'), findsOneWidget);
    expect(find.byKey(const Key('cal-delete-event')), findsNothing);
  });

  testWidgets('日历分组：取消勾选后重新过滤（本地，不额外请求）', (tester) async {
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'My Calendar',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
          {
            'cal_id': '/demo_user/work/',
            'cal_displayname': 'Work',
            'cal_privilege': 'RW',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {'week_start_day': 0},
      'SYNO.Cal.Event.list': {'list': <Object>[]},
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('cal-calendars')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Work'), findsOneWidget);
    await tester.tap(find.text('Work'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // 取消勾选 → 只看 My Calendar
    expect(b.container.read(selectedCalIdsProvider), {'/demo_user/work/'});
  });

  testWidgets('加载失败：给可重试的错误态', (tester) async {
    final b = await _boot(
      {
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': '/demo_user/home/',
              'cal_displayname': 'My Calendar',
              'cal_privilege': 'RW',
              'cal_type': 'event',
            },
          ],
        },
        'SYNO.Cal.Setting.get': {'week_start_day': 0},
        'SYNO.Cal.Event.list': <String, dynamic>{},
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
      },
      failures: {'SYNO.Cal.Event.list': 9009},
    );
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('日历加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('没有可写日历时，新建给出提示而不是崩', (tester) async {
    final b = await _boot({
      'SYNO.Cal.Cal.list': {
        'list': [
          {
            'cal_id': '/demo_user/home/',
            'cal_displayname': 'Shared',
            'cal_privilege': 'RO',
            'cal_type': 'event',
          },
        ],
      },
      'SYNO.Cal.Setting.get': {'week_start_day': 0},
      'SYNO.Cal.Event.list': {'list': <Object>[]},
      'SYNO.Cal.Todo.list': {'list': <Object>[]},
    });
    await _pump(tester, b.container, const CalendarPage());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('cal-new-event')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('没有可写入的日历'), findsOneWidget);
    expect(b.t.calls.where((c) => c['method'] == 'create'), isEmpty);
  });

  test('monthGridWindow：周起始日对齐 + 覆盖整月', () {
    // 2026-09 月：1 号是周二
    final w = monthGridWindow(DateTime(2026, 9), 0); // 周日起
    expect(w.from, DateTime(2026, 8, 30));
    expect(w.from.weekday, DateTime.sunday);
    final w2 = monthGridWindow(DateTime(2026, 9), 1); // 周一起
    expect(w2.from, DateTime(2026, 8, 31));
    expect(w2.from.weekday, DateTime.monday);
    // 窗口必须覆盖到月末
    expect(w.to.isBefore(DateTime(2026, 9, 30)), isFalse);
  });

  test('weekStartWeekday：JS 口径 0 = 周日', () {
    expect(weekStartWeekday(0), DateTime.sunday);
    expect(weekStartWeekday(1), DateTime.monday);
    expect(weekStartWeekday(6), DateTime.saturday);
    expect(weekStartWeekday(99), DateTime.sunday, reason: '越界回落周日');
  });

  group('日历待办：新建 / 编辑 / 完成 / 删除（全部走真接口形状）', () {
    const todoCal = '/demo_user/home_todo/';
    Map<String, dynamic> todoJson({
      String id = '7',
      String summary = '买牛奶',
      int percent = 0,
      String due = '20260919T080539',
    }) => {
      'evt_id': id,
      'summary': summary,
      'description': '两升',
      'evt_cal': todoCal,
      'original_cal_id': todoCal,
      'percent_complete': percent,
      'due_string': due,
      'has_end_time': true,
      'dav_etag': 'etag-$id',
      'priority_order': 0,
      'is_all_day': false,
      'tzid': 'Asia/Shanghai',
    };

    testWidgets('待办区块来自待办日历，勾选直接发 Todo/set(percent_complete=100)', (
      tester,
    ) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': '/demo_user/home/',
              'cal_displayname': 'My Calendar',
              'cal_color': '#B240AF',
              'cal_privilege': 'RW',
              'cal_type': 'event',
              'default_calendar': true,
              'original_cal_id': '/demo_user/home/',
            },
          ],
        },
        'SYNO.Cal.Todo.list': {
          'list': [todoJson()],
        },
        'SYNO.Cal.Todo.set': {'evt_id': 7, 'summary': '买牛奶'},
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 100));

      await _scrollDayList(tester);
      expect(find.text('待办（1）'), findsOneWidget);
      expect(find.text('买牛奶'), findsOneWidget);
      expect(find.byKey(const Key('cal-todo-new')), findsOneWidget);

      await _tapTodo(tester, find.byKey(const Key('cal-todo-check-7')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final set = b.t.calls.lastWhere((c) => c['method'] == 'set');
      expect(set['api'], 'SYNO.Cal.Todo');
      expect(set['evt_id'], '7');
      expect(set['percent_complete'], '100');
      expect(set['dav_etag'], '"etag-7"');
      expect(set['version'], '6');
    });

    testWidgets('新建待办 → Todo/create（标题/截止/待办日历）', (tester) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': todoCal,
              'cal_displayname': 'My Tasks',
              'cal_color': '#4C8DFF',
              'cal_privilege': 'RW',
              'cal_type': 'todo',
              'original_cal_id': todoCal,
            },
          ],
        },
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
        'SYNO.Cal.Todo.create': {'evt_id': 11, 'summary': '写周报'},
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 100));

      await _tapHeaderButton(tester, find.byKey(const Key('cal-todo-new')));
      await tester.pumpAndSettle();
      expect(find.text('新建待办'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('cal-todo-title')), '写周报');
      await tester.tap(find.byKey(const Key('cal-todo-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final create = b.t.calls.lastWhere((c) => c['method'] == 'create');
      expect(create['api'], 'SYNO.Cal.Todo');
      expect(create['original_cal_id'], '"$todoCal"');
      expect(create['summary'], '"写周报"');
      expect(create['has_end_time'], 'false', reason: '没设截止时间');
      expect(create['percent_complete'], '0');
    });

    testWidgets('点待办进编辑弹层：改名 + 勾完成 → Todo/set 全量提交', (tester) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': todoCal,
              'cal_displayname': 'My Tasks',
              'cal_color': '#4C8DFF',
              'cal_privilege': 'RW',
              'cal_type': 'todo',
              'original_cal_id': todoCal,
            },
          ],
        },
        'SYNO.Cal.Todo.list': {
          'list': [todoJson()],
        },
        'SYNO.Cal.Todo.set': {'evt_id': 7, 'summary': '买牛奶和面包'},
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 100));

      await _tapTodo(tester, find.text('买牛奶'));
      await tester.pumpAndSettle();
      expect(find.text('编辑待办'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('cal-todo-title')), '买牛奶和面包');
      await tester.tap(find.byKey(const Key('cal-todo-done')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('cal-todo-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final set = b.t.calls.lastWhere((c) => c['method'] == 'set');
      expect(set['summary'], '"买牛奶和面包"');
      expect(set['percent_complete'], '100');
      expect(set['description'], '"两升"', reason: '全量提交，未改的字段也要带上');
      expect(set['due'], isNotNull, reason: '原来的截止时间要保留');
    });

    testWidgets('编辑弹层里删除 → Todo/delete', (tester) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': todoCal,
              'cal_displayname': 'My Tasks',
              'cal_color': '#4C8DFF',
              'cal_privilege': 'RW',
              'cal_type': 'todo',
              'original_cal_id': todoCal,
            },
          ],
        },
        'SYNO.Cal.Todo.list': {
          'list': [todoJson()],
        },
        'SYNO.Cal.Todo.delete': const {},
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 100));

      await _tapTodo(tester, find.text('买牛奶'));
      await tester.pumpAndSettle();
      await _tapTodo(tester, find.byKey(const Key('cal-todo-delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final del = b.t.calls.lastWhere((c) => c['method'] == 'delete');
      expect(del['api'], 'SYNO.Cal.Todo');
      expect(del['evt_id'], '7');
    });

    testWidgets('已完成待办划线显示 + 顶部出现「清空已完成」', (tester) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': todoCal,
              'cal_displayname': 'My Tasks',
              'cal_color': '#4C8DFF',
              'cal_privilege': 'RW',
              'cal_type': 'todo',
              'original_cal_id': todoCal,
            },
          ],
        },
        'SYNO.Cal.Todo.list': {
          'list': [
            todoJson(id: '8', summary: '已做', percent: 100),
            todoJson(id: '9', summary: '没做'),
          ],
        },
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 100));

      final list = b.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Cal.Todo' && c['method'] == 'list',
      );
      expect(list['filter_complete'], 'all', reason: '已完成那几条也要拿到');
      await _scrollDayList(tester);
      // 顶部那行（清空已完成）本来就在视口里；已完成的条目滚到底可见。
      // 小节的标题文字会随滚动移出视口，所以用 skipOffstage:false 校验文案格式。
      expect(find.byKey(const Key('cal-todo-clean')), findsOneWidget);
      expect(find.text('已做'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').contains('已完成 1'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(find.text('已做'), findsOneWidget);
      expect(find.byKey(const Key('cal-todo-clean')), findsOneWidget);
    });

    testWidgets('清空已完成 → Todo/clean_complete（v1）', (tester) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': todoCal,
              'cal_displayname': 'My Tasks',
              'cal_color': '#4C8DFF',
              'cal_privilege': 'RW',
              'cal_type': 'todo',
              'original_cal_id': todoCal,
            },
          ],
        },
        'SYNO.Cal.Todo.list': {
          'list': [todoJson(id: '8', summary: '已做', percent: 100)],
        },
        'SYNO.Cal.Todo.clean_complete': const {},
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 100));

      await _tapHeaderButton(tester, find.byKey(const Key('cal-todo-clean')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final clean = b.t.calls.lastWhere((c) => c['method'] == 'clean_complete');
      expect(clean['api'], 'SYNO.Cal.Todo');
      expect(clean['version'], '1', reason: 'v5/v6 没有这个方法');
      expect(clean['cal_id_list'], '["$todoCal"]');
    });
  });

  test('calTimeRange：全天 / 同天区间 / 跨天', () {
    expect(
      calTimeRange(
        _dto({
          'evt_id': '1',
          'summary': 'x',
          'is_all_day': true,
          'dtstart_string': '20260919T000000',
          'dtend_string': '20260920T000000',
        }),
      ),
      '全天',
    );
    expect(
      calTimeRange(
        _dto({
          'evt_id': '2',
          'summary': 'x',
          'dtstart_string': '20260919T090000',
          'dtend_string': '20260919T103000',
        }),
      ),
      '09:00 – 10:30',
    );
    expect(
      calTimeRange(
        _dto({
          'evt_id': '3',
          'summary': 'x',
          'dtstart_string': '20260919T220000',
          'dtend_string': '20260920T010000',
        }),
      ),
      '22:00 – 2026-09-20 01:00',
    );
  });
  group('日历重复：新建带规则 / 删除"仅这一次"与"整个系列"', () {
    testWidgets('新建日程选「每周」→ Event/create 带上 repeat_setting', (tester) async {
      final today = _today;
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': '/demo_user/home/',
              'cal_displayname': 'My Calendar',
              'cal_color': '#B240AF',
              'cal_privilege': 'RW',
              'cal_type': 'event',
              'original_cal_id': '/demo_user/home/',
            },
          ],
        },
        'SYNO.Cal.Setting.get': {
          'week_start_day': 0,
          'time_zone': 'Asia/Shanghai',
        },
        'SYNO.Cal.Event.list': {'list': <Object>[]},
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
        'SYNO.Cal.Event.create': _event(
          id: '88',
          summary: '周会',
          dtstart: _stamp(today),
        ),
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('cal-new-event')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byKey(const Key('cal-editor-title')), '周会');

      // 重复 = 每周
      await tester.tap(find.byKey(const Key('cal-editor-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('每周').last);
      await tester.pumpAndSettle();

      // 间隔 +1（每 2 周）
      await tester.tap(find.byKey(const Key('cal-editor-repeat-plus')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('cal-editor-repeat-interval')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('cal-editor-repeat-interval')))
            .data,
        '2',
      );

      // 结束 = 重复次数 → 10 次（点 8 下从默认 1 到 9？这里只点一下确认按钮起作用）
      await tester.tap(find.byKey(const Key('cal-editor-repeat-end')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重复次数').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cal-editor-repeat-count-plus')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('cal-editor-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final create = b.t.calls.lastWhere((c) => c['method'] == 'create');
      expect(create['is_repeat_evt'], 'true');
      final rule =
          jsonDecode(create['repeat_setting'] as String)
              as Map<String, dynamic>;
      expect(rule['type'], 'week');
      expect(rule['interval'], 2);
      expect(rule['end'], {'type': 'count', 'count': 2, 'date': 0});
      expect(
        (rule['weekday'] as List).isNotEmpty,
        isTrue,
        reason: '每周默认勾上事件开始那天',
      );
    });

    testWidgets('重复事件详情：显示规则 + 「仅此日程」走 Event/set_exdate', (tester) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': '/demo_user/home/',
              'cal_displayname': 'My Calendar',
              'cal_color': '#B240AF',
              'cal_privilege': 'RW',
              'cal_type': 'event',
              'original_cal_id': '/demo_user/home/',
            },
          ],
        },
        'SYNO.Cal.Setting.get': {
          'week_start_day': 0,
          'time_zone': 'Asia/Shanghai',
        },
        'SYNO.Cal.Event.list': {
          'list': [
            _repeatEvent(id: '91', summary: '周会', dtstart: _stamp(_today)),
          ],
        },
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
        'SYNO.Cal.Event.set_exdate': <String, dynamic>{},
        'SYNO.Cal.Event.delete': <String, dynamic>{},
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 100));

      final listCallsBefore = b.t.calls
          .where((c) => c['method'] == 'list')
          .length;
      await tester.tap(find.widgetWithText(DesignRowTile, '周会'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('每周 · 周六'), findsOneWidget);
      expect(
        find.byKey(const Key('cal-delete-event-this')),
        findsOneWidget,
        reason: '重复事件要分"仅此日程/所有日程"',
      );
      expect(find.byKey(const Key('cal-delete-event')), findsNothing);

      await tester.tap(find.byKey(const Key('cal-delete-event-this')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final call = b.t.calls.lastWhere((c) => c['method'] == 'set_exdate');
      expect(call['api'], 'SYNO.Cal.Event');
      expect(call['evt_id'], '91', reason: '裸串');
      expect(call['dav_etag'], '"etag-91"');
      expect(
        call['exdate'],
        _stamp(_today),
        reason: 'exdate 裸串；系列里普通那一次 recurrence_id 是 null，用这次的 dtstart_string',
      );
      expect(
        b.t.calls.any((c) => c['method'] == 'delete'),
        isFalse,
        reason: '仅此日程不能删母事件',
      );
      // 删掉某一次之后列表必须**重新拉**：真机上出现过「删了但行还在，
      // 手动点刷新才消失」—— 单向的 provider 缓存在作怪
      expect(
        b.t.calls.where((c) => c['method'] == 'list').length,
        greaterThan(listCallsBefore),
        reason: 'set_exdate 后必须重拉 Event/list',
      );
    });

    testWidgets('重复事件详情：「所有日程」走 Event/delete（带 evt_id）', (tester) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': '/demo_user/home/',
              'cal_displayname': 'My Calendar',
              'cal_color': '#B240AF',
              'cal_privilege': 'RW',
              'cal_type': 'event',
              'original_cal_id': '/demo_user/home/',
            },
          ],
        },
        'SYNO.Cal.Setting.get': {
          'week_start_day': 0,
          'time_zone': 'Asia/Shanghai',
        },
        'SYNO.Cal.Event.list': {
          'list': [
            _repeatEvent(id: '92', summary: '周会', dtstart: _stamp(_today)),
          ],
        },
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
        'SYNO.Cal.Event.set_exdate': <String, dynamic>{},
        'SYNO.Cal.Event.delete': <String, dynamic>{},
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.widgetWithText(DesignRowTile, '周会'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('cal-delete-event-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final call = b.t.calls.lastWhere((c) => c['method'] == 'delete');
      expect(call['evt_id'], '92', reason: '母事件用裸串 evt_id');
      expect(b.t.calls.any((c) => c['method'] == 'set_exdate'), isFalse);
    });

    testWidgets('一次性事件详情：仍然只有一个「删除」按钮', (tester) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': '/demo_user/home/',
              'cal_displayname': 'My Calendar',
              'cal_color': '#B240AF',
              'cal_privilege': 'RW',
              'cal_type': 'event',
              'original_cal_id': '/demo_user/home/',
            },
          ],
        },
        'SYNO.Cal.Setting.get': {
          'week_start_day': 0,
          'time_zone': 'Asia/Shanghai',
        },
        'SYNO.Cal.Event.list': {
          'list': [_event(id: '93', summary: '一次性', dtstart: _stamp(_today))],
        },
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
        'SYNO.Cal.Event.delete': <String, dynamic>{},
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.widgetWithText(DesignRowTile, '一次性'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('cal-delete-event')), findsOneWidget);
      expect(find.byKey(const Key('cal-delete-event-this')), findsNothing);
      expect(find.byKey(const Key('cal-delete-event-all')), findsNothing);
    });
  });

  // ---- C4：`Cal/list` 失败要**如实说**，不能渲染成"没有日历" ----
  //
  // 9009 = `error:invalid_parameter`（包内 `ui/syno-cal-err-code.json` 原文），
  // 真机上"不带 cal_type"就是这个码；它是参数错误、可重试，
  // **不是**"这个账号没有日历"。
  group('C4 Cal/list 失败的展示口径', () {
    testWidgets('Cal/list 回 9009：出现错误横幅 + 重试，且不说"还没有日历"', (tester) async {
      final b = await _boot(
        {
          'SYNO.Cal.Cal.list': <String, dynamic>{},
          'SYNO.Cal.Setting.get': {'week_start_day': 0},
          'SYNO.Cal.Event.list': <String, dynamic>{},
          'SYNO.Cal.Todo.list': {'list': <Object>[]},
        },
        failures: {'SYNO.Cal.Cal.list': 9009},
      );
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const Key('cal-error-bar')), findsOneWidget);
      expect(find.textContaining('9009'), findsWidgets);
      // 这一条的错误文案里带"重试"（副标题会按宽度省略，但 Text 的 data 是全文）
      expect(find.textContaining('重试'), findsWidgets);
      // 错误**绝不能**被说成空数据
      expect(find.textContaining('还没有日历'), findsNothing);
    });

    testWidgets('真·空列表：不出现错误横幅（空态≠错误）', (tester) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {'list': <Object>[]},
        'SYNO.Cal.Setting.get': {'week_start_day': 0},
        'SYNO.Cal.Event.list': {'list': <Object>[]},
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const Key('cal-error-bar')), findsNothing);
    });

    testWidgets('加载失败时打开日历选择器：说"加载失败"而不是"还没有日历"', (tester) async {
      final b = await _boot(
        {
          'SYNO.Cal.Cal.list': <String, dynamic>{},
          'SYNO.Cal.Setting.get': {'week_start_day': 0},
          'SYNO.Cal.Event.list': <String, dynamic>{},
          'SYNO.Cal.Todo.list': {'list': <Object>[]},
        },
        failures: {'SYNO.Cal.Cal.list': 9009},
      );
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const Key('cal-calendars')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('加载失败'), findsWidgets);
      expect(find.textContaining('还没有日历'), findsNothing);
    });

    testWidgets('真·空列表时打开日历选择器：给"还没有日历"的空态', (tester) async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {'list': <Object>[]},
        'SYNO.Cal.Setting.get': {'week_start_day': 0},
        'SYNO.Cal.Event.list': {'list': <Object>[]},
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
      });
      await _pump(tester, b.container, const CalendarPage());
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byKey(const Key('cal-calendars')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('还没有日历'), findsOneWidget);
    });
  });
}

/// 时间文案的单元测试用真实 DTO（走 fromJson，避免另造一条路径）
CalEventDto _dto(Map<String, dynamic> json) => CalEventDto.fromJson(json);
