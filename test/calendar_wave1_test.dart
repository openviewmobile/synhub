// 日历 **wave1**（2026-09-22）的离线测试。
//
// 覆盖两块，缺一不可：
//   1. **请求形状**（api / method / version / params / 编码）—— 参数名与编码
//      全部有出处（真机回包 或 官方客户端明文 JS），写错就会打服务端个 9009；
//   2. **页面层**（入口可见性 / 空态 / 失败提示 / 门控）。
//
// 事实出处逐条写在 `lib/src/data/calendar_api.dart` 与
// `docs/calendar-gaps-wave1.md`；这里的期望值**故意与真机回包逐字一致**，
// 这样任何"把回包形状记错"的改动都会在这里变红。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/calendar_api.dart';
import 'package:synhub/src/data/dto/calendar_dto.dart';
import 'package:synhub/src/data/region/device_location.dart';
import 'package:synhub/src/data/region/region_context.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/calendar/calendar_env.dart';
import 'package:synhub/src/features/calendar/calendar_page.dart';
import 'package:synhub/src/features/calendar/calendar_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// Calendar 3.0.3-21434 真机 `SYNO.API.Info` 快照（**含 wave1 的 4 个新 API**）
const _calTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Cal.Cal': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Event': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Setting': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Todo': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  // wave1 新增（真机 2026-09-22 均在能力表里）
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
      'cal_public_sharing_id': '',
      'cal_type': 'event',
      'default_calendar': true,
      'is_hidden_in_cal': false,
      'is_hidden_in_list': false,
      'original_cal_id': '/demo_user/home/',
      'original_ug_name': 'demo_user',
      'original_user_no': 1029,
    },
  ],
};

/// 真机 `Setting/get` v5 原样回包（子集）
const _settingPayload = {
  'time_zone': 'Asia/Shanghai',
  'date_format': 'Y-m-d',
  'time_format': '24',
  'week_start_day': 0,
  'default_view': 'week',
  'default_cal': '/demo_user/home/',
  'show_week_numbers': false,
  'enable_keyboard_shortcut': true,
};

/// 真机 `Sharing/get` v1 原样回包（**按 cal_id 分组**）
const _sharingPayload = {
  '/demo_user/home/': {
    'DSM_GROUP': <Object>[],
    'DSM_USER': [
      {'ug_name': 'demo_admin', 'cal_privilege': 'RW'},
    ],
  },
};

/// 真机 `Share.Priv/list` v1 原样回包
const _principalsPayload = {
  'list': [
    {'name': 'admin', 'type': 'user', 'uid': 1024, 'value': 'user:admin'},
    {'name': 'users', 'type': 'group', 'uid': 100, 'value': 'group:users'},
  ],
};

/// 真机 `Timezone/list` 的**裸数组**（不是 `{data:{list}}`）
final _timezoneBareArray = utf8.encode(
  jsonEncode([
    {
      'temp': 'Africa/Abidjan',
      'tzid': 'Africa/Abidjan',
      'vtimezone': 'BEGIN:VTIMEZONE',
    },
    {
      'temp': 'Asia/Shanghai',
      'tzid': 'Asia/Shanghai',
      'vtimezone': 'BEGIN:VTIMEZONE',
    },
  ]),
);

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

Future<({FakeTransport t, ProviderContainer container})> _bootPage(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, int> failures = const {},
  Map<String, Map<String, dynamic>>? table,
  Map<String, List<int>> bytes = const {},
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
  // 多跳几次：待办日历 → 待办列表 → count_todo 角标是**串行**的
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 打开日历设置弹层（入口在既有的"日历筛选"弹层里 —— 不往 header 加按钮，
/// 见 `calendar_page.dart` 的注释：header 在 360×640/en/x2.0 下已经贴边）
Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('cal-calendars')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('cal-settings')));
  await tester.pumpAndSettle();
}

void main() {
  // ==========================================================================
  group('wave1 API：请求形状（api / method / version / params）', () {
    test('Event/list_color 用 v6 且不带参数（方法只在 v6，v1–v5 全 103）', () async {
      final b = await _bootApi();
      b.t.bytesByUrl['SYNO.Cal.Event'] = utf8.encode(
        jsonEncode({
          'success': true,
          'data': {
            'evt_color_list': ['#112233', '445566'],
          },
        }),
      );
      final colors = await b.cal.listEventColors();

      expect(
        b.t.postDownloads.last,
        contains('api=SYNO.Cal.Event'),
        reason: '走的是 raw POST（裸回包接口必须自己解 JSON）',
      );
      expect(b.t.postDownloads.last, contains('method=list_color'));
      expect(b.t.postDownloads.last, contains('version=6'));
      // `#RRGGBB` 与裸 `RRGGBB` 两种都归一成 `#RRGGBB`
      expect([for (final c in colors) c.color], ['#112233', '#445566']);
    });

    test('Event/list_color 回包解析不出来时回空列表（绝不回退写死调色板）', () async {
      final b = await _bootApi();
      b.t.bytesByUrl['SYNO.Cal.Event'] = utf8.encode(
        '{"success":true,"data":{"whatever":{"nested":true}}}',
      );
      expect(await b.cal.listEventColors(), isEmpty);
    });

    test(
      'Todo/count_todo 的参数照官方客户端：filter_due/filter_complete + cal_id_list',
      () async {
        final b = await _bootApi({
          'SYNO.Cal.Todo.count_todo': {'result': 3},
        });
        final n = await b.cal.countTodos(
          calendarIds: const ['/demo_user/home_todo/'],
        );
        expect(n, 3);
        final call = b.t.calls.last;
        expect(call['api'], 'SYNO.Cal.Todo');
        expect(call['method'], 'count_todo');
        expect(call['version'], '6');
        // 枚举串是**裸串**（与 Todo/list 的 filter_complete 同口径）
        expect(call['filter_due'], 'all');
        expect(call['filter_complete'], 'no');
        // 数组是 **JSON 数组串**
        expect(call['cal_id_list'], '["/demo_user/home_todo/"]');
      },
    );

    test('Todo/count_todo 真机空库回 {"result":{}} → 0（空对象不是数字）', () async {
      final b = await _bootApi({
        'SYNO.Cal.Todo.count_todo': {'result': <String, dynamic>{}},
      });
      expect(await b.cal.countTodos(), 0);
    });

    test('Sharing/get 用 v1 + cal_id 裸串，回包按 cal_id 分组', () async {
      final b = await _bootApi({'SYNO.Cal.Sharing.get': _sharingPayload});
      final members = await b.cal.calendarSharing('/demo_user/home/');
      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Cal.Sharing');
      expect(call['method'], 'get');
      expect(call['version'], '1');
      // ⚠️ 裸串（真机 `{cal_id:"/demo_user/home/"}`）；传 id 会回 117
      expect(call['cal_id'], '/demo_user/home/');
      expect(members.length, 1);
      expect(members.first.name, 'demo_admin');
      expect(members.first.isUser, isTrue);
      expect(members.first.canWrite, isTrue);
    });

    test(
      'Sharing/set 的 cal_share_setting 形状照官方客户端（DSM_USER/DSM_GROUP + ug_name/cal_privilege）',
      () async {
        final b = await _bootApi({'SYNO.Cal.Sharing.set': _sharingPayload});
        await b.cal.setCalendarSharing(
          calId: '/demo_user/home/',
          members: const [
            CalShareMemberDto(name: 'demo_admin', privilege: 'RW'),
            CalShareMemberDto(name: 'users', privilege: 'RO', isUser: false),
          ],
        );
        final call = b.t.calls.last;
        expect(call['api'], 'SYNO.Cal.Sharing');
        expect(call['method'], 'set');
        expect(call['version'], '1');
        expect(call['cal_id'], '/demo_user/home/');
        final setting =
            jsonDecode('${call['cal_share_setting']}') as Map<String, dynamic>;
        expect(setting['DSM_USER'], [
          {'ug_name': 'demo_admin', 'cal_privilege': 'RW'},
        ]);
        expect(setting['DSM_GROUP'], [
          {'ug_name': 'users', 'cal_privilege': 'RO'},
        ]);
      },
    );

    test('Share.Priv/list 用 v1 无参，回包吃 name/type/uid/value', () async {
      final b = await _bootApi({
        'SYNO.Cal.Share.Priv.list': _principalsPayload,
      });
      final list = await b.cal.sharePrincipals();
      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Cal.Share.Priv');
      expect(call['method'], 'list');
      expect(call['version'], '1');
      expect(list.length, 2);
      expect(list[0].name, 'admin');
      expect(list[0].isUser, isTrue);
      expect(list[1].isUser, isFalse);
    });

    test('Timezone/list 吃**裸数组**（真机不回 data 包装）', () async {
      final b = await _bootApi();
      b.t.bytesByUrl['SYNO.Cal.Timezone'] = _timezoneBareArray;
      final zones = await b.cal.timezones();
      expect(b.t.postDownloads.last, contains('method=list'));
      expect(b.t.postDownloads.last, contains('api=SYNO.Cal.Timezone'));
      expect(
        [for (final z in zones) z.tzId],
        ['Africa/Abidjan', 'Asia/Shanghai'],
      );
    });

    test('Timezone/list 也吃 openapi 的 {data:{list:[…]}} 形状', () async {
      final b = await _bootApi();
      b.t.bytesByUrl['SYNO.Cal.Timezone'] = utf8.encode(
        jsonEncode({
          'success': true,
          'data': {
            'list': [
              {'tzid': 'Asia/Taipei', 'temp': 'Asia/Taipei'},
            ],
          },
        }),
      );
      final zones = await b.cal.timezones();
      expect([for (final z in zones) z.tzId], ['Asia/Taipei']);
    });

    test('Event/create|set 都把 color 发出去（空串 = 用日历默认色）', () async {
      final b = await _bootApi({
        'SYNO.Cal.Event.create': {'evt_id': 1, 'cal_id': '/demo_user/home/'},
        'SYNO.Cal.Event.set': {'evt_id': 1, 'cal_id': '/demo_user/home/'},
      });
      await b.cal.createEvent(
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: 's',
        start: DateTime(2026, 9, 22, 9),
        end: DateTime(2026, 9, 22, 10),
        color: '#112233',
      );
      expect(b.t.calls.last['color'], '"#112233"');

      final src = CalEventDto.fromJson(const {
        'evt_id': '7',
        'cal_id': '/demo_user/home/',
        'original_cal_id': '/demo_user/home/',
        'summary': 's',
        'color': '#AABBCC',
        'dav_etag': 'e',
        'is_all_day': false,
        'tz_id': 'Asia/Shanghai',
        'dtstart': 1789000000,
        'dtend': 1789003600,
      });
      await b.cal.updateEvent(
        source: src,
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: 's',
        start: DateTime(2026, 9, 22, 9),
        end: DateTime(2026, 9, 22, 10),
      );
      // 不传 color → 原样回传源事件的 color（`set` 是整体替换，丢了会被清掉）
      expect(b.t.calls.last['color'], '"#AABBCC"');

      await b.cal.updateEvent(
        source: src,
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: 's',
        start: DateTime(2026, 9, 22, 9),
        end: DateTime(2026, 9, 22, 10),
        color: '',
      );
      expect(b.t.calls.last['color'], '""');
    });

    test('create_from_ics 只留骨架：不臆造参数名，也不打网络', () async {
      final b = await _bootApi();
      await expectLater(
        b.cal.createEventFromIcs(),
        throwsA(isA<UnsupportedError>()),
      );
      // 一次请求都不该发出去（否则就是"点了必然 9009"的入口）
      expect(b.t.calls.where((c) => c['method'] == 'create_from_ics'), isEmpty);
    });

    test('能力位与门控：新 API 的存在性 + Event 是否到 v6', () async {
      final b = await _bootApi();
      expect(b.cal.hasSharingApi, isTrue);
      expect(b.cal.hasSharePrivApi, isTrue);
      expect(b.cal.hasTimezoneApi, isTrue);
      expect(b.cal.hasEventV6Api, isTrue);
      expect(b.cal.hasInviteMailApi, isFalse); // 测试表里没有邮件三件套

      // 老包（`Event` 只到 v5）→ `list_color` 不可用
      final old = await _bootApi(const {}, {
        ..._calTable,
        'SYNO.Cal.Event': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 5,
        },
      });
      expect(old.cal.hasEventV6Api, isFalse);
    });

    test('hasInviteMailApi：三条只要有任意一条在能力表里就算有（门控用）', () async {
      final b = await _bootApi(const {}, {
        ..._calTable,
        'SYNO.Cal.InviteMailInit': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 5,
        },
      });
      expect(b.cal.hasInviteMailApi, isTrue);
    });
  });

  // ==========================================================================
  group('wave1 页面：入口 / 空态 / 失败提示 / 门控', () {
    testWidgets('设置入口在日历弹层里，打开后有配色/时区/共享/ICS 四块', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());

      await tester.tap(find.byKey(const Key('cal-calendars')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cal-settings')), findsOneWidget);
      await tester.tap(find.byKey(const Key('cal-settings')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cal-settings-sheet')), findsOneWidget);
      expect(find.byKey(const Key('cal-settings-timezone')), findsOneWidget);
      expect(find.byKey(const Key('cal-settings-colors')), findsOneWidget);
      expect(find.byKey(const Key('cal-settings-sharing-0')), findsOneWidget);
      expect(find.byKey(const Key('cal-settings-ics')), findsOneWidget);
    });

    testWidgets('① 配色用 list_color 的**回值**（不是写死的调色板）', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        bytes: {
          'SYNO.Cal.Event': utf8.encode(
            jsonEncode({
              'success': true,
              'data': {
                'evt_color_list': ['#112233'],
              },
            }),
          ),
        },
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);

      final swatch = find.byKey(const Key('cal-color-swatch-0'));
      expect(swatch, findsOneWidget, reason: '服务端给了 1 个颜色 → 必须画 1 个色块');
      expect(find.byKey(const Key('cal-color-swatch-1')), findsNothing);
      final box = tester.widget<Container>(swatch);
      expect(
        (box.decoration! as BoxDecoration).color,
        const Color(0xFF112233),
        reason: '色块必须是服务端回的那个颜色；写死默认色会在这里红',
      );
    });

    testWidgets('① 服务端没回配色 → 明说"没有返回可用配色"，不画任何色块', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);

      expect(find.byKey(const Key('cal-color-swatch-0')), findsNothing);
      expect(find.byKey(const Key('cal-colors-empty')), findsOneWidget);
    });

    testWidgets('② 待办角标用 count_todo 的**回值**（不是写死 0）', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
          'SYNO.Cal.Todo.count_todo': {'result': 7},
          'SYNO.Cal.Todo.list': {'list': <Object>[]},
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());

      final badge = find.byKey(const Key('cal-todo-badge'));
      expect(badge, findsOneWidget, reason: 'count_todo 回了 7 → 必须出现角标');
      expect(
        find.descendant(of: badge, matching: find.text('7')),
        findsOneWidget,
      );
    });

    testWidgets('② count_todo 拿不到 → 角标不显示（**不显示 0**）', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
          'SYNO.Cal.Todo.list': {'list': <Object>[]},
        },
        failures: {
          'SYNO.Cal.Todo.count_todo': CalApiErrorCode.invalidParameter,
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());

      expect(
        find.byKey(const Key('cal-todo-badge')),
        findsNothing,
        reason: '失败要显示成"没有角标"，不能显示成"待办清空了"',
      );
    });

    testWidgets('③ SYNO.Cal.Sharing 缺失 → 共享入口整块不显示（门控）', (tester) async {
      // 老包：能力表里**没有** `SYNO.Cal.Sharing`
      final noSharing = {..._calTable}..remove('SYNO.Cal.Sharing');
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        table: noSharing,
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);

      expect(
        find.byKey(const Key('cal-settings-sharing-0')),
        findsNothing,
        reason: '没有 Sharing 能力时不能显示"点了必然失败"的入口',
      );
      // 但其它区块照常（不能因为共享不可用就把整个设置弹层藏了）
      expect(find.byKey(const Key('cal-settings-colors')), findsOneWidget);
    });

    testWidgets('共享编辑器：读 Sharing/get，成员按名字展示（不显示内部 cal_id）', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
          'SYNO.Cal.Sharing.get': _sharingPayload,
          'SYNO.Cal.Share.Priv.list': _principalsPayload,
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);

      await tester.tap(find.byKey(const Key('cal-settings-sharing-0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cal-sharing-sheet')), findsOneWidget);
      expect(find.text('demo_admin'), findsOneWidget);
      expect(
        find.text('/demo_user/home/'),
        findsNothing,
        reason: '内部 id 不显示给用户',
      );
    });

    testWidgets('⑤ 共享写入失败 → **明确**提示（不静默）', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
          'SYNO.Cal.Sharing.get': _sharingPayload,
          'SYNO.Cal.Share.Priv.list': _principalsPayload,
        },
        failures: {'SYNO.Cal.Sharing.set': CalApiErrorCode.invalidParameter},
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);
      await tester.tap(find.byKey(const Key('cal-settings-sharing-0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('cal-sharing-save')));
      await tester.pumpAndSettle();

      // 提示里必须带"保存失败"和错误码语义（9009 = invalid_parameter）
      expect(
        find.textContaining('共享设置保存失败'),
        findsOneWidget,
        reason: '写入失败必须明说；吞掉异常就是一个"静默失败"的写入口',
      );
      expect(find.textContaining('9009'), findsOneWidget);
    });

    testWidgets('④ ICS 导入：入口明说"未取证"，点开有原因（不是可点的假按钮）', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);

      final ics = find.byKey(const Key('cal-settings-ics'));
      expect(ics, findsOneWidget);
      expect(
        find.textContaining('参数名还没有取证到'),
        findsOneWidget,
        reason: '入口必须如实说明"未取证"，不能静默或假装可用',
      );

      await tester.tap(ics);
      await tester.pumpAndSettle();
      expect(find.textContaining('参数名还没有取证到'), findsWidgets);
      // 没有发过 create_from_ics 请求
      expect(b.t.calls.where((c) => c['method'] == 'create_from_ics'), isEmpty);
    });

    testWidgets('邀请邮件：能力缺失 → 不显示；存在 → 显示来源说明（依赖套件）', (tester) async {
      final without = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, without.container, const CalendarPage());
      await _openSettings(tester);
      expect(find.byKey(const Key('cal-settings-invite-mail')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      final withMail = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        table: {
          ..._calTable,
          'SYNO.Cal.InviteMail': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, withMail.container, const CalendarPage());
      await _openSettings(tester);
      expect(find.byKey(const Key('cal-settings-invite-mail')), findsOneWidget);
      expect(find.textContaining('邮件套件'), findsWidgets);
    });

    testWidgets('时区：列表来自 Timezone/list，空表时明说', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        bytes: {
          'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}'),
          'SYNO.Cal.Timezone': _timezoneBareArray,
        },
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);

      await tester.tap(find.byKey(const Key('cal-settings-timezone')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cal-timezone-sheet')), findsOneWidget);
      expect(find.byKey(const Key('cal-timezone-0')), findsOneWidget);
      // `ListView` 是懒建的：第二项可能在弹层视口外，先滚到可见再点
      await tester.scrollUntilVisible(
        find.byKey(const Key('cal-timezone-1')),
        60,
        scrollable: find.descendant(
          of: find.byKey(const Key('cal-timezone-sheet')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const Key('cal-timezone-1')));
      await tester.pumpAndSettle();
      // 选完写进会话内默认值（`Event/create` 的 `tz_id` 初值）；排序后第二项是
      // Asia/Shanghai —— 值来自服务端，证明列表真的走了 `Timezone/list`
      expect(b.container.read(calDefaultTimeZoneProvider), 'Asia/Shanghai');
    });

    testWidgets('用户设置只读：Setting/get 的字段照实展示', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
        },
        bytes: {'SYNO.Cal.Event': utf8.encode('{"success":true,"data":{}}')},
      );
      await _pump(tester, b.container, const CalendarPage());
      await _openSettings(tester);

      expect(find.byKey(const Key('cal-settings-date-format')), findsOneWidget);
      expect(find.text('Y-m-d'), findsWidgets);
      expect(find.byKey(const Key('cal-settings-week-start')), findsOneWidget);
      expect(
        find.byKey(const Key('cal-settings-default-view')),
        findsOneWidget,
      );
    });

    testWidgets('事件编辑器：配色选项来自 list_color，选中后随 create 发出', (tester) async {
      final b = await _bootPage(
        {
          'SYNO.Cal.Cal.list': _calListPayload,
          'SYNO.Cal.Setting.get': _settingPayload,
          'SYNO.Cal.Event.create': {
            'evt_id': 9,
            'cal_id': '/demo_user/home/',
            'summary': 'x',
            'color': '#112233',
            'dtstart': 1789000000,
            'dtend': 1789003600,
            'dtstart_string': '20260922T090000',
            'dtend_string': '20260922T100000',
            'is_all_day': false,
            'tz_id': 'Asia/Shanghai',
            'original_cal_id': '/demo_user/home/',
            'dav_etag': 'e',
          },
        },
        bytes: {
          'SYNO.Cal.Event': utf8.encode(
            jsonEncode({
              'success': true,
              'data': {
                'evt_color_list': ['#112233'],
              },
            }),
          ),
        },
      );
      await _pump(tester, b.container, const CalendarPage());

      await tester.tap(find.byKey(const Key('cal-new-event')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cal-editor-colors')), findsOneWidget);
      expect(
        find.byKey(const Key('cal-editor-color-0')),
        findsOneWidget,
        reason: '候选色必须来自 list_color；内置调色板会多出别的色号',
      );

      await tester.enterText(
        find.byKey(const Key('cal-editor-title')),
        'probe',
      );
      await tester.tap(find.byKey(const Key('cal-editor-color-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cal-editor-save')));
      await tester.pumpAndSettle();

      final create = b.t.calls.firstWhere(
        (c) => c['method'] == 'create',
        orElse: () => const <String, dynamic>{},
      );
      expect(create['color'], '"#112233"');
    });

    testWidgets('事件编辑器：list_color 不可用（v5）时整块配色不显示', (tester) async {
      final v5 = {
        ..._calTable,
        'SYNO.Cal.Event': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 5,
        },
      };
      final b = await _bootPage({
        'SYNO.Cal.Cal.list': _calListPayload,
        'SYNO.Cal.Setting.get': _settingPayload,
        'SYNO.Cal.Event.create': {
          'evt_id': 9,
          'cal_id': '/demo_user/home/',
          'summary': 'x',
          'dtstart': 1789000000,
          'dtend': 1789003600,
          'is_all_day': false,
          'original_cal_id': '/demo_user/home/',
          'dav_etag': 'e',
        },
      }, table: v5);
      await _pump(tester, b.container, const CalendarPage());

      await tester.tap(find.byKey(const Key('cal-new-event')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('cal-editor-colors')),
        findsNothing,
        reason: 'v5 没有 list_color → 不给会 103 的配色入口',
      );
    });
  });

  // ==========================================================================
  group('wave1 DTO：宽松解析（回包形状未取证时的兜底）', () {
    test('CalEventColorDto 吃数组 / 对象元素 / 裸 RRGGBB / 嵌套列表值', () {
      expect(
        [
          for (final c in CalEventColorDto.listFromJson([
            '#112233',
            '445566',
            {'color': '#AABBCC', 'name': '蓝'},
          ]))
            c.color,
        ],
        ['#112233', '#445566', '#AABBCC'],
      );
      // data 是 Map：取**第一个列表值**（不猜键名）
      expect(
        CalEventColorDto.listFromJson({
          'some_key': ['#010203'],
        }).single.color,
        '#010203',
      );
      // 非颜色串被丢掉（不能显示成色块）
      expect(CalEventColorDto.listFromJson(['not-a-color']), isEmpty);
    });

    test('CalTimezoneDto 去重 + 按 tzid 排序', () {
      final list = CalTimezoneDto.listFromJson([
        {'tzid': 'Asia/Tokyo'},
        {'tzid': 'Asia/Shanghai'},
        {'tzid': 'Asia/Tokyo'},
        {'temp': 'no-tzid'},
      ]);
      expect([for (final z in list) z.tzId], ['Asia/Shanghai', 'Asia/Tokyo']);
    });

    test('CalShareMemberDto 同时收 DSM_USER 与 DSM_GROUP', () {
      final members = CalShareMemberDto.listFromJson(const {
        '/x/home/': {
          'DSM_USER': [
            {'ug_name': 'u1', 'cal_privilege': 'RW'},
          ],
          'DSM_GROUP': [
            {'ug_name': 'g1', 'cal_privilege': 'RO'},
          ],
        },
      }, '/x/home/');
      expect([for (final m in members) m.name], ['u1', 'g1']);
      expect(members[0].isUser, isTrue);
      expect(members[1].isUser, isFalse);
    });

    test('CalSettingDto 收到 wave1 的只读字段', () {
      final s = CalSettingDto.fromJson(const {
        'time_zone': 'Asia/Shanghai',
        'show_week_numbers': true,
        'enable_keyboard_shortcut': true,
        'last_used_map_type': 'baidu',
        'default_plugin_mode': 'todo_plugin',
      });
      expect(s.showWeekNumbers, isTrue);
      expect(s.enableKeyboardShortcut, isTrue);
      expect(s.lastUsedMapType, 'baidu');
      expect(s.defaultPluginMode, 'todo_plugin');
    });
  });
}
