// W1-6 Calendar / Contacts 打磨：邀请/参与者 + 列表头像（离线用例）。
//
// 证据来源（**只读**，见 docs/calendar-contacts-w1-6.md）：
//   * Calendar 3.0.3-21434（/tmp/spk/export_Calendar）：
//     - webapi/openapi.json 的 `participant_obj_0` / `user_contact_obj_0`；
//     - ui/synocalendar-common_utils.js 的 `SYNO.Cal.AttendeeUtils` 枚举；
//     - ui/synocalendar-app.js 的 `getAttendeeBySelection` / `getAttendeeByRawEmail`
//       / `_convertAttendeeForAPI`；
//     - ui/synocalendar.bundle.min.js 的 `Contact_list:{api:"SYNO.Cal.Contact",
//       method:"list",version:1}` 与 `runAPI("Contact_list",{})`。
//   * Contacts 1.0.11-20661（/tmp/spk/export_Contacts）：
//     - ui/static/js/main.js 的 `getContactPhoto:{api:"SYNO.Contacts.Contact",
//       method:"get_photo",version:1}` 与调用点
//       `Ht(Hn.send,"getContactPhoto",{contact_ids:t})`、`photo.forEach(e=>s[e.id]=e.photo)`。
//
// 纪律：不联网、不真机、不构建；全部走 FakeTransport。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/calendar_api.dart';
import 'package:synhub/src/data/contacts_api.dart';
import 'package:synhub/src/data/dto/calendar_dto.dart';
import 'package:synhub/src/data/region/device_location.dart';
import 'package:synhub/src/data/region/region_context.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/calendar/calendar_env.dart';
import 'package:synhub/src/features/calendar/calendar_page.dart';
import 'package:synhub/src/features/calendar/calendar_providers.dart';
import 'package:synhub/src/features/contacts/contact_detail_sheet.dart';
import 'package:synhub/src/features/contacts/contacts_page.dart';
import 'package:synhub/src/features/contacts/contacts_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

// ----------------------------------------------------------------- 能力表

const _calTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Cal.Cal': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Event': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Setting': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Todo': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Contact': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
};

/// 同上去掉 `SYNO.Cal.Contact`（验"缺能力"降级）
const _calTableNoContact = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Cal.Cal': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Event': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Setting': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Todo': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
};

const _contactsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Contacts.Addressbook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Contacts.Contact': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Contacts.Label': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Contacts.Info': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
};

// ------------------------------------------------------------------ 小工具

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

// =================================================================== API 层

void main() {
  group('W1-6 Calendar 受邀人（participant）参数逐字', () {
    test('Cal-1 create 的 participant 只有官方 6 键（display_name 不发）', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._calTable});
      t.onCall = (p) => {'evt_id': '77', 'summary': '周会'};
      final api = await _loggedIn(t);
      await CalendarApi(api).createEvent(
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: '周会',
        start: DateTime(2026, 9, 20, 9),
        end: DateTime(2026, 9, 20, 10),
        participants: [
          CalParticipantDto.forDsm(
            const CalContactDto(
              userName: 'demo_user',
              displayName: 'K',
              email: 'k@n.local',
              isRealEmail: true,
              type: 'local',
            ),
          ),
          CalParticipantDto.forEmail('guest@example.com'),
        ],
      );
      final call = t.calls.lastWhere((c) => c['method'] == 'create');
      final list = jsonDecode('${call['participant']}') as List;
      expect(list, hasLength(2));
      // 官方 `_convertAttendeeForAPI` 的键集：多一个 display_name 都是改坏了
      expect((list[0] as Map).keys.toSet(), {
        'user_name',
        'email',
        'type',
        'status',
        'role',
        'is_real_email',
      });
      expect((list[0] as Map).containsKey('display_name'), isFalse);
      expect(list[0]['type'], 'dsm');
      expect(list[0]['user_name'], 'demo_user');
      expect(list[0]['status'], 'needs_action');
      expect(list[0]['role'], 'attendee');
      expect(list[0]['is_real_email'], isTrue);
      // 手输邮箱：官方 `getAttendeeByRawEmail` → type=email、user_name=email
      expect(list[1]['type'], 'email');
      expect(list[1]['user_name'], 'guest@example.com');
      expect(list[1]['is_real_email'], isTrue);
    });

    test('Cal-2 update 传 participants 时整体替换，不传时原样回传源事件', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._calTable});
      t.onCall = (p) => {'evt_id': '1017', 'summary': 'x'};
      final api = await _loggedIn(t);
      final cal = CalendarApi(api);
      const source = CalEventDto(
        evtId: '1017',
        calId: '/demo_user/home/',
        summary: '旧标题',
        participantsRaw: [
          {
            'user_name': 'boss',
            'email': 'boss@n.local',
            'type': 'dsm',
            'status': 'accepted',
            'role': 'organizer',
            'is_real_email': true,
          },
        ],
      );

      // 不传：必须原样回传（否则改个标题就把受邀人清光了）
      await cal.updateEvent(
        source: source,
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: '新标题',
        start: DateTime(2026, 9, 20, 9),
        end: DateTime(2026, 9, 20, 10),
      );
      var call = t.calls.lastWhere((c) => c['method'] == 'set');
      var list = jsonDecode('${call['participant']}') as List;
      expect(list, hasLength(1));
      expect(list[0]['role'], 'organizer', reason: '组织者原样带回');

      // 传了：整体替换成新的那批
      await cal.updateEvent(
        source: source,
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: '新标题',
        start: DateTime(2026, 9, 20, 9),
        end: DateTime(2026, 9, 20, 10),
        participants: [CalParticipantDto.forEmail('new@example.com')],
      );
      call = t.calls.lastWhere((c) => c['method'] == 'set');
      list = jsonDecode('${call['participant']}') as List;
      expect(list, hasLength(1));
      expect(list[0]['email'], 'new@example.com');
      expect(list[0]['role'], 'attendee');
    });

    test(
      'Cal-3 calContacts 用 SYNO.Cal.Contact/list v1 + 空参数，键是 list',
      () async {
        final t = FakeTransport(const {}, {
          ...FakeTransport.table,
          ..._calTable,
        });
        t.onCall = (p) => {
          'list': [
            {
              'user_name': 'demo_user',
              'display_name': 'K',
              'email': 'k@n.local',
              'is_real_email': true,
              'type': 'local',
              'has_set_email': true,
            },
            {
              'user_name': 'other',
              'display_name': 'Other',
              'email': 'o@n.local',
              'is_real_email': false,
              'type': 'local',
              'has_set_email': false,
            },
          ],
        };
        final api = await _loggedIn(t);
        final users = await CalendarApi(api).calContacts();
        final call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Cal.Contact');
        expect(call['method'], 'list');
        expect(call['version'], '1');
        // 官方调用点是 `runAPI("Contact_list",{})`：不能凭空夹带过滤参数
        expect(call.containsKey('offset'), isFalse);
        expect(call.containsKey('limit'), isFalse);
        expect(call.containsKey('keyword'), isFalse);
        expect(users, hasLength(2));
        expect(users.first.userName, 'demo_user');
        expect(users.first.displayName, 'K');
        expect(users.first.isRealEmail, isTrue);
      },
    );

    test(
      'Cal-5 缺 SYNO.Cal.Contact → hasContactApi=false，provider 空列表且不发请求',
      () async {
        final t = FakeTransport(const {}, {
          ...FakeTransport.table,
          ..._calTableNoContact,
        });
        final api = await _loggedIn(t);
        final cal = CalendarApi(api);
        expect(cal.hasContactApi, isFalse);
        final c = ProviderContainer(
          overrides: [calendarApiProvider.overrideWithValue(cal)],
        );
        addTearDown(c.dispose);
        expect(await c.read(calContactsProvider.future), isEmpty);
        expect(
          t.calls.any((x) => x['api'] == 'SYNO.Cal.Contact'),
          isFalse,
          reason: '没有这个能力就不该发请求',
        );
      },
    );
  });

  group('W1-6 Contacts 列表头像（Contact/get_photo）', () {
    test('Cont-1 get_photo 参数是 contact_ids 的 JSON 数组串，空 photo 不收录', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._contactsTable,
      });
      t.onCall = (p) => {
        'photo': [
          {'id': '12', 'photo': 'data:image/png;base64,AAA'},
          {'id': '13', 'photo': ''},
        ],
      };
      final api = await _loggedIn(t);
      final map = await ContactsApi(api).photos(['12', '13']);
      final call = t.calls.lastWhere((c) => c['method'] == 'get_photo');
      expect(call['api'], 'SYNO.Contacts.Contact');
      expect(call['version'], '1');
      expect(call['contact_ids'], '["12","13"]');
      expect(call.containsKey('ids'), isFalse, reason: 'get_photo 不认 ids');
      expect(map['12'], 'data:image/png;base64,AAA');
      expect(map.containsKey('13'), isFalse, reason: '空串 = 没头像');
    });

    test('Cont-2 contactPhotosProvider 按 CSV key 批量取一次', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._contactsTable,
      });
      t.onCall = (p) => {
        'photo': [
          {'id': '12', 'photo': 'data:image/png;base64,AAA'},
        ],
      };
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [contactsApiProvider.overrideWithValue(ContactsApi(api))],
      );
      addTearDown(c.dispose);
      expect(contactPhotosKey(['12', '13']), '12,13');
      final map = await c.read(contactPhotosProvider('12,13').future);
      expect(map['12'], 'data:image/png;base64,AAA');
      expect(t.calls.where((x) => x['method'] == 'get_photo'), hasLength(1));
    });

    test('Cont-3 取图失败不报错，退回空表（页面用姓名首字）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._contactsTable,
      });
      t.failures['SYNO.Contacts.Contact.get_photo'] = 105;
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [contactsApiProvider.overrideWithValue(ContactsApi(api))],
      );
      addTearDown(c.dispose);
      expect(await c.read(contactPhotosProvider('12').future), isEmpty);
    });
  });

  // =============================================================== 页面接线

  group('W1-6 页面接线（离线 UI）', () {
    testWidgets('Cal-4 编辑器选 NAS 用户后，create 带上 participant', (tester) async {
      final responses = <String, Map<String, dynamic>>{
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': '/demo_user/home/',
              'cal_displayname': 'My Calendar',
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
        'SYNO.Cal.Contact.list': {
          'list': [
            {
              'user_name': 'demo_user',
              'display_name': 'K',
              'email': 'k@n.local',
              'is_real_email': true,
              'type': 'local',
              'has_set_email': true,
            },
          ],
        },
        'SYNO.Cal.Event.create': {'evt_id': '77', 'summary': '周会'},
      };
      final t = FakeTransport(responses, {
        ...FakeTransport.table,
        ..._calTable,
      });
      final api = await _loggedIn(t);
      final c = _calendarContainer(CalendarApi(api));
      await _pumpCalendar(tester, c);

      await tester.tap(find.byKey(const Key('cal-new-event')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('cal-editor-participant-add')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('cal-participant-user-demo_user')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const Key('cal-editor-participant-k@n.local')),
        findsOneWidget,
        reason: '选中的 NAS 用户要变成编辑器里的一枚 chip',
      );

      await tester.enterText(find.byKey(const Key('cal-editor-title')), '周会');
      await tester.ensureVisible(find.byKey(const Key('cal-editor-save')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('cal-editor-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final create = t.calls.lastWhere((x) => x['method'] == 'create');
      final list = jsonDecode('${create['participant']}') as List;
      expect(list, hasLength(1));
      expect(list.single['user_name'], 'demo_user');
      expect(list.single['type'], 'dsm');
      expect(list.single['status'], 'needs_action');
    });

    testWidgets('Cal-6 缺 SYNO.Cal.Contact → 用户候选换成原因说明，邮箱仍可手输', (tester) async {
      final responses = <String, Map<String, dynamic>>{
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              'cal_id': '/demo_user/home/',
              'cal_displayname': 'My Calendar',
              'cal_privilege': 'RW',
              'cal_type': 'event',
              'original_cal_id': '/demo_user/home/',
            },
          ],
        },
        'SYNO.Cal.Setting.get': {'week_start_day': 0},
        'SYNO.Cal.Event.list': {'list': <Object>[]},
        'SYNO.Cal.Todo.list': {'list': <Object>[]},
        'SYNO.Cal.Event.create': {'evt_id': '78', 'summary': '外部会'},
      };
      final t = FakeTransport(responses, {
        ...FakeTransport.table,
        ..._calTableNoContact,
      });
      final api = await _loggedIn(t);
      final c = _calendarContainer(CalendarApi(api));
      await _pumpCalendar(tester, c);

      await tester.tap(find.byKey(const Key('cal-new-event')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('cal-editor-participant-add')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const Key('cal-participant-unsupported')),
        findsOneWidget,
        reason: '缺能力必须给出原因，而不是一个空列表',
      );
      expect(
        find.byKey(const Key('cal-participant-user-demo_user')),
        findsNothing,
      );

      await tester.enterText(
        find.byKey(const Key('cal-participant-email')),
        'guest@example.com',
      );
      await tester.tap(find.byKey(const Key('cal-participant-email-add')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const Key('cal-editor-participant-guest@example.com')),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(const Key('cal-editor-title')), '外部会');
      await tester.ensureVisible(find.byKey(const Key('cal-editor-save')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('cal-editor-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final create = t.calls.lastWhere((x) => x['method'] == 'create');
      final list = jsonDecode('${create['participant']}') as List;
      expect(list.single['type'], 'email');
      expect(list.single['email'], 'guest@example.com');
    });

    testWidgets('Cont-4 列表头像用 get_photo 的结果覆盖姓名首字', (tester) async {
      // 合法 1×1 PNG（`DecorationImage` 会真的去解，坏数据会让用例红）
      const url =
          'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
          'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._contactsTable,
      });
      t.onCall = (params) {
        switch ('${params['method']}') {
          case 'list':
            if ('${params['api']}' == 'SYNO.Contacts.Addressbook') {
              return {
                'addressbook': [
                  {'id': 5, 'name': 'My Contacts', 'member_count': 1},
                ],
              };
            }
            return {
              'contact': [
                {
                  'id': 12,
                  'addressbook_id': 5,
                  'full_name': 'probe_联系人',
                  'primary_mail': 'probe@example.com',
                  'is_editable': true,
                  'photo': '',
                  'additional': {'label': <Object>[]},
                },
              ],
            };
          case 'get_photo':
            return {
              'photo': [
                {'id': 12, 'photo': url},
              ],
            };
          case 'list_group':
            return {'group': <Object>[]};
          case 'list_principal':
            return {'principal': <Object>[]};
        }
        return const <String, dynamic>{};
      };
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [contactsApiProvider.overrideWithValue(ContactsApi(api))],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const ContactsPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        t.calls.any((x) => x['method'] == 'get_photo'),
        isTrue,
        reason: '列表必须批量取图（Contact/list 不回头像）',
      );
      final avatars = tester
          .widgetList<ContactsAvatar>(find.byType(ContactsAvatar))
          .toList();
      expect(
        avatars.any((a) => a.photo == url),
        isTrue,
        reason: '取回的 data URL 要真的交给头像控件',
      );
    });
  });
}

// --------------------------------------------------------- 页面脚手架

/// 假定位探针：测试里绝不碰 MethodChannel（与 calendar_page_test 同口径）
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

ProviderContainer _calendarContainer(CalendarApi cal) {
  final c = ProviderContainer(
    overrides: [
      calendarApiProvider.overrideWithValue(cal),
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
  addTearDown(c.dispose);
  return c;
}

Future<void> _pumpCalendar(
  WidgetTester tester,
  ProviderContainer container,
) async {
  tester.view.physicalSize = const Size(1148, 2492);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: const CalendarPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}
