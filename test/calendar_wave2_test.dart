// 日历 **wave2**（2026-09-22）的离线测试：导出（`Cal.Cal/export` v1）+
// 待办搜索（`Todo/search` v1）。
//
// 与 wave1 同一套纪律：期望值**故意与真机回包逐字一致**，任何"把回包形状/
// 版本/参数记错"的改动都在这里变红。四个 falsification 靶子就长在这几个
// 断言上（见 `docs/calendar-gaps-wave2.md` §4）：
//   ① `export` 必须是 **v1**（v2–v5 全 103）；
//   ② 导出回包是**裸 ICS 文本**，不能当 JSON 解；
//   ③ 搜索结果从 **`evt_list_result`** 取，不是 `todolist`；
//   ④ 能力门控（导出 / 待办搜索）失效 → 必红。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/calendar_api.dart';
import 'package:synhub/src/data/dto/calendar_dto.dart';
import 'package:synhub/src/data/region/device_location.dart';
import 'package:synhub/src/data/region/region_context.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/calendar/calendar_env.dart';
import 'package:synhub/src/features/calendar/calendar_export.dart';
import 'package:synhub/src/features/calendar/calendar_page.dart';
import 'package:synhub/src/features/calendar/calendar_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真机 `SYNO.API.Info` 快照（Calendar 3.0.3-21434）。
const _calTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Cal.Cal': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Event': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Setting': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Todo': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Sharing': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Cal.Share.Priv': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Cal.Timezone': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
};

/// 真机 `Cal/list` v5 原样回包（`My Calendar`）
const _calListPayload = {
  'list': [
    {
      'cal_color': '#B240AF',
      'cal_displayname': 'My Calendar',
      'cal_id': '/demo_user/home/',
      'cal_privilege': 'RW',
      'cal_type': 'event',
      'default_calendar': true,
    },
  ],
};

const _settingPayload = {
  'time_zone': 'Asia/Shanghai',
  'date_format': 'Y-m-d',
  'time_format': '24',
  'week_start_day': 0,
  'default_view': 'week',
  'show_week_numbers': false,
};

/// **真机 `Cal.Cal/export` v1 原样回包**（裸 ICS 文本，逐字）。
const _realIcs =
    'BEGIN:VCALENDAR\r\n'
    'PRODID:-//davical.org//NONSGML AWL Calendar//EN\r\n'
    'VERSION:2.0\r\n'
    'CALSCALE:GREGORIAN\r\n'
    'X-WR-CALNAME:My Calendar\r\n'
    'END:VCALENDAR';

/// 真机 `Todo/search` v1 空结果（逐字）。
const _searchEmpty = {'evt_list_result': <Object>[], 'total': 0};

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

/// 固定的可用性快照（门控用；语义同 `drive_gaps_wave1_test.dart`）
class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);
  final ServiceAvailabilitySnapshot snapshot;
  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values) s: AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 22),
    );

/// Calendar 全能力集（门控"开"的一侧）
const _allCalApis = {
  'SYNO.Cal.Cal',
  'SYNO.Cal.Event',
  'SYNO.Cal.Setting',
  'SYNO.Cal.Todo',
  'SYNO.Cal.Sharing',
  'SYNO.Cal.Share.Priv',
  'SYNO.Cal.Timezone',
};

Future<({CalendarApi cal, FakeTransport t})> _bootApi([
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, Map<String, dynamic>>? table,
]) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ...(table ?? _calTable),
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (cal: CalendarApi(api), t: t);
}

Future<({FakeTransport t, ProviderContainer container})> _bootPage(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, int> failures = const {},
  Map<String, Map<String, dynamic>>? table,
  Map<String, List<int>> bytes = const {},
  Set<String>? apis,
  Directory? exportDir,
  List<String>? opened,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ...(table ?? _calTable),
  });
  t.failures.addAll(failures);
  t.bytesByUrl.addAll(bytes);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final dir = exportDir ?? Directory.systemTemp.createTempSync('calwave2');
  final container = ProviderContainer(
    overrides: [
      calendarApiProvider.overrideWithValue(CalendarApi(api)),
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
      weatherBundleProvider.overrideWith((ref) async => null),
      holidayBundleProvider.overrideWith((ref) async => null),
      deviceLocationProbeProvider.overrideWithValue(_NoLocation()),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis ?? _allCalApis)),
      ),
      calExportDirProvider.overrideWithValue(() async => dir),
      // widget 测试里 `writeAsBytes` 不会在 pump 之间落地 → 换同步写
      calExportWriterProvider.overrideWithValue((file, bytes) async {
        file.writeAsBytesSync(bytes);
      }),
      // 「打开 / 分享」记录调用；**默认实现**在 `FLUTTER_TEST` 下本来就是 no-op
      calExportSystemOpenProvider.overrideWithValue((path) async {
        opened?.add(path);
        return OpenResult(type: ResultType.done, message: 'test-noop');
      }),
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
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('cal-calendars')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('cal-settings')));
  await tester.pumpAndSettle();
}

void main() {
  // ==========================================================================
  group('wave2 API：请求形状（api / method / version / params）', () {
    test(
      '① Cal.Cal/export 必须 v1 + cal_id 裸串 + 不发 cal_type，回裸 ICS 文本',
      () async {
        final b = await _bootApi();
        b.t.bytesByUrl['SYNO.Cal.Cal'] = utf8.encode(_realIcs);

        final ics = await b.cal.exportCalendarIcs('/demo_user/home/');

        final sent = b.t.postDownloads.last;
        expect(sent, contains('api=SYNO.Cal.Cal'));
        expect(sent, contains('method=export'));
        // v2–v5 真机全 103 ⇒ 只有 v1 是对的
        expect(sent, contains('version=1'), reason: 'export 必须 v1；v2–v5 恒 103');
        expect(
          sent,
          contains('cal_id=/demo_user/home/'),
          reason: 'cal_id 是必需参数（无参 117）',
        );
        // `cal_type` 不需要（带上也成功、回包相同）⇒ 不发
        expect(sent, isNot(contains('cal_type')));
        // **裸文本**逐字回传（不是 JSON 包装）
        expect(ics, _realIcs);
      },
    );

    test('② 裸 ICS 文本按文本返回（当 JSON 解会直接炸）', () {
      final text = decodeCalendarIcsExport(
        utf8.encode(_realIcs),
        what: 'SYNO.Cal.Cal.export',
      );
      expect(text, _realIcs);
      expect(text.startsWith('BEGIN:VCALENDAR'), isTrue);
    });

    test('export 的错误回包是 JSON（117）→ 抛 DsmApiException，不吞', () async {
      final b = await _bootApi();
      b.t.bytesByUrl['SYNO.Cal.Cal'] = utf8.encode(
        jsonEncode({
          'success': false,
          'error': {'code': 117},
        }),
      );
      await expectLater(
        b.cal.exportCalendarIcs('/demo_user/home/'),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 117)),
      );
    });

    test('export 的 cal_id 为空：本地就拦下来（不打网络，真机无参 = 117）', () async {
      final b = await _bootApi();
      await expectLater(
        b.cal.exportCalendarIcs(''),
        throwsA(isA<DsmApiException>()),
      );
      expect(b.t.postDownloads, isEmpty);
    });

    test('Todo/search 用 v1 + keyword 裸串，回包 root 是 evt_list_result', () async {
      final b = await _bootApi({
        'SYNO.Cal.Todo.search': {
          'evt_list_result': [
            {
              'evt_id': '77',
              'summary': '买牛奶',
              'evt_cal': '/demo_user/home_todo/',
              'percent_complete': 0,
            },
          ],
          'total': 1,
        },
      });
      final res = await b.cal.searchTodos(keyword: '牛奶');
      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Cal.Todo');
      expect(call['method'], 'search');
      expect(call['version'], '1', reason: 'search 只在 v1');
      expect(call['keyword'], '牛奶');
      expect(call.containsKey('cal_id'), isFalse);
      expect(res.items.length, 1);
      expect(res.items.first.summary, '买牛奶');
      expect(res.items.first.calId, '/demo_user/home_todo/');
      expect(res.total, 1);
    });

    test('Todo/search 也吃 cal_id（两者都实测可调），仍是 v1 + 裸串', () async {
      final b = await _bootApi({'SYNO.Cal.Todo.search': _searchEmpty});
      await b.cal.searchTodos(calId: '/demo_user/home_todo/');
      final call = b.t.calls.last;
      expect(call['version'], '1');
      expect(call['cal_id'], '/demo_user/home_todo/');
      expect(call.containsKey('keyword'), isFalse);
    });

    test('③ 搜索结果只认 evt_list_result（todolist 里放干扰项也不许读到）', () {
      final dto = CalTodoSearchResultDto.fromJson(const {
        'evt_list_result': [
          {'evt_id': '1', 'summary': 'EVT'},
        ],
        // 干扰：真机 root 不是 todolist；取错键就会读成 2 条
        'todolist': [
          {'evt_id': '2', 'summary': 'TODO-A'},
          {'evt_id': '3', 'summary': 'TODO-B'},
        ],
        'total': 1,
      });
      expect(dto.items.length, 1);
      expect(dto.items.first.summary, 'EVT');
      expect(dto.total, 1);
    });

    test('Todo/search 真机空结果 → 0 条（不是错误）', () async {
      final b = await _bootApi({'SYNO.Cal.Todo.search': _searchEmpty});
      final res = await b.cal.searchTodos(keyword: 'zzz');
      expect(res.items, isEmpty);
      expect(res.total, 0);
      expect(res.isEmpty, isTrue);
    });
  });

  // ==========================================================================
  group('wave2 落盘：文件名与字节', () {
    test('文件名用日历显示名（不是 cal_id），补 .ics', () {
      expect(calendarIcsFileName('My Calendar'), 'My Calendar.ics');
      expect(calendarIcsFileName('  My Calendar  '), 'My Calendar.ics');
      // 已经带 .ics 不重复补
      expect(calendarIcsFileName('a.ics'), 'a.ics');
      // 空显示名给中性兜底（**也不是 cal_id**）
      expect(calendarIcsFileName('   '), 'calendar.ics');
    });

    test('saveCalendarIcs 落盘：文件名 = 显示名，内容逐字 = 服务端裸 ICS', () async {
      final b = await _bootApi();
      b.t.bytesByUrl['SYNO.Cal.Cal'] = utf8.encode(_realIcs);
      final dir = Directory.systemTemp.createTempSync('calwave2_pure');
      addTearDown(() => dir.deleteSync(recursive: true));

      final path = await saveCalendarIcs(
        api: b.cal,
        calId: '/demo_user/home/',
        displayName: 'My Calendar',
        dir: () async => dir,
        writer: (f, bytes) async => f.writeAsBytesSync(bytes),
      );

      expect(path, '${dir.path}/My Calendar.ics');
      expect(File(path).readAsStringSync(), _realIcs);
      // 内部 id 绝不入文件名
      expect(path.contains('/demo_user/home/'), isFalse);
    });
  });

  // ==========================================================================
  group('wave2 页面：导出入口 / 落盘 / 失败提示 / 门控', () {
    testWidgets('设置弹层里有导出块：按**显示名**列出日历，不显示内部 cal_id', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);

      expect(find.byKey(const Key('cal-settings-export-0')), findsOneWidget);
      expect(find.text('My Calendar'), findsWidgets);
      expect(
        find.text('/demo_user/home/'),
        findsNothing,
        reason: '内部 cal_id 不上屏',
      );
      expect(find.textContaining('导出为 .ics 文件'), findsOneWidget);
    });

    testWidgets(
      '点导出 → 调 export v1 并落成 <显示名>.ics；**不**自动打开（不弹 Preview/QuickTime）',
      (tester) async {
        final opened = <String>[];
        final b = await _bootPage(
          {
            'SYNO.Cal.Cal.list': _calListPayload,
            'SYNO.Cal.Setting.get': _settingPayload,
          },
          bytes: {
            'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}'),
            'SYNO.Cal.Cal': utf8.encode(_realIcs),
          },
          opened: opened,
        );
        await _pump(tester, b.container, const CalendarPage());
        await _openSettings(tester);

        await tester.tap(find.byKey(const Key('cal-settings-export-0')));
        await tester.pumpAndSettle();

        final sent = b.t.postDownloads.last;
        expect(sent, contains('method=export'));
        expect(sent, contains('version=1'));
        expect(sent, contains('cal_id=/demo_user/home/'));

        // "已导出"弹层出现
        expect(find.byKey(const Key('cal-export-done')), findsOneWidget);
        expect(find.textContaining('My Calendar.ics'), findsOneWidget);
        // ⚠️ 导出本身**不**调起任何外部应用（用户明确要求：本机测试不弹预览）
        expect(opened, isEmpty, reason: '导出只落盘；打开要用户显式点');

        // 用户显式点「打开 / 分享」才走既有 system_open（测试环境 no-op）
        await tester.tap(find.byKey(const Key('cal-export-open')));
        await tester.pumpAndSettle();
        expect(opened.length, 1);
        expect(opened.first.endsWith('My Calendar.ics'), isTrue);
      },
    );

    testWidgets('导出失败（117）→ **明确**提示，不静默', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      // export 的回包是一个 JSON 错误体（HTTP 层仍 200 —— 与真机 117 同形）
      b.t.bytesByUrl['SYNO.Cal.Cal'] = utf8.encode(
        jsonEncode({
          'success': false,
          'error': {'code': 117},
        }),
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);

      await tester.tap(find.byKey(const Key('cal-settings-export-0')));
      await tester.pumpAndSettle();

      expect(find.textContaining('导出失败'), findsOneWidget);
      expect(find.byKey(const Key('cal-export-done')), findsNothing);
    });

    testWidgets('④ SYNO.Cal.Cal 不在能力表 → 导出块整块不显示（门控）', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        apis: {..._allCalApis}..remove('SYNO.Cal.Cal'),
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);

      expect(
        find.byKey(const Key('cal-settings-export-0')),
        findsNothing,
        reason: '没有 Cal 能力时不能显示"点了必然失败"的导出入口',
      );
      // 其它区块照常
      expect(find.byKey(const Key('cal-settings-ics')), findsOneWidget);
    });
  });

  // ==========================================================================
  group('wave2 页面：待办搜索', () {
    testWidgets('待办面板有放大镜入口；点开输入关键字 → 出结果（evt_list_result）', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
          'SYNO.Cal.Todo.list': {'list': <Object>[]},
          'SYNO.Cal.Todo.search': {
            'evt_list_result': [
              {'evt_id': '77', 'summary': '买牛奶'},
            ],
            'total': 1,
          },
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());

      await tester.tap(find.byKey(const Key('cal-todo-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cal-todo-search-sheet')), findsOneWidget);
      // 还没搜 → 说明态（不是"没有结果"）
      expect(find.byKey(const Key('cal-todo-search-idle')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('cal-todo-search-field')),
        '牛奶',
      );
      await tester.tap(find.byKey(const Key('cal-todo-search-go')));
      await tester.pumpAndSettle();

      final call = b.t.calls.lastWhere((c) => c['method'] == 'search');
      expect(call['version'], '1');
      expect(call['keyword'], '牛奶');
      expect(find.byKey(const Key('cal-todo-search-0')), findsOneWidget);
      expect(find.text('买牛奶'), findsOneWidget);
      expect(find.byKey(const Key('cal-todo-search-empty')), findsNothing);
    });

    testWidgets('空关键字**不发请求**，给的是"输入关键字"提示', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
          'SYNO.Cal.Todo.list': {'list': <Object>[]},
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await tester.tap(find.byKey(const Key('cal-todo-search')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('cal-todo-search-go')));
      await tester.pumpAndSettle();

      expect(b.t.calls.where((c) => c['method'] == 'search'), isEmpty);
      expect(find.byKey(const Key('cal-todo-search-idle')), findsOneWidget);
    });

    testWidgets('服务端回 0 条 → **明确空态**', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
          'SYNO.Cal.Todo.list': {'list': <Object>[]},
          'SYNO.Cal.Todo.search': _searchEmpty,
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await tester.tap(find.byKey(const Key('cal-todo-search')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('cal-todo-search-field')),
        'zzz',
      );
      await tester.tap(find.byKey(const Key('cal-todo-search-go')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cal-todo-search-empty')), findsOneWidget);
      expect(find.textContaining('没有找到匹配的待办'), findsOneWidget);
      expect(find.byKey(const Key('cal-todo-search-0')), findsNothing);
    });

    testWidgets('搜索失败 → 显示错误，**不**伪装成"0 条"', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
          'SYNO.Cal.Todo.list': {'list': <Object>[]},
        },
        failures: {'SYNO.Cal.Todo.search': CalApiErrorCode.invalidParameter},
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await tester.tap(find.byKey(const Key('cal-todo-search')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('cal-todo-search-field')),
        'x',
      );
      await tester.tap(find.byKey(const Key('cal-todo-search-go')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cal-todo-search-error')), findsOneWidget);
      expect(find.textContaining('9009'), findsOneWidget);
      expect(
        find.byKey(const Key('cal-todo-search-empty')),
        findsNothing,
        reason: '"搜不到"和"搜索接口挂了"必须能分辨',
      );
    });

    testWidgets('④ SYNO.Cal.Todo 不在能力表 → 待办搜索入口不显示（门控）', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
          'SYNO.Cal.Todo.list': {'list': <Object>[]},
        },
        apis: {..._allCalApis}..remove('SYNO.Cal.Todo'),
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());

      expect(
        find.byKey(const Key('cal-todo-search')),
        findsNothing,
        reason: '没有 Todo 能力时不能显示"点了必然失败"的搜索入口',
      );
      // 待办"新建"入口同样被既有门控藏掉（不许删既有门控）
      expect(find.byKey(const Key('cal-todo-new')), findsNothing);
    });
  });
}
