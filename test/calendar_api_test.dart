// Synology Calendar 的离线测试：**参数编码是重点**。
//
// 官方没有日历安卓 App，形态只能以包内 Web UI 为准（docs/api-server-authoritative.md §18），
// 真机把每一种编码都试过了。这里把结论钉死，回归时一眼能看出是谁改坏了：
//   * `Cal/list` **v5** + `cal_type=event`（空参 9009，v1 回 `{}`）；
//   * `Event/list` **v6** + `cal_id_list` 是 **JSON 数组串** + `start`/`end` 是 **epoch 秒裸串**；
//   * `Event/create` 的字符串字段要 **Gson 引号串**（裸串 9009），epoch/布尔裸串，数组 JSON 串；
//   * `Event/get` / `Event/delete` 的 `evt_id` 是 **裸串**（`"1017"` 回 9009）；
//   * `Event/list` **不能协商到 v4**（真机 121）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/calendar_api.dart';
import 'package:synhub/src/data/dto/calendar_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// Calendar 3.0.3-21434 真机 `SYNO.API.Info` 快照（相关子集）
const _calTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Cal.Cal': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Event': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Setting': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Todo': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Timezone': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
};

/// 真机 `Cal/list` v5 的原样回包（`My Calendar`）
const _calListPayload = {
  'list': [
    {
      'cal_color': '#B240AF',
      'cal_description': '',
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

/// 真机 `Event/create` 的原样回包（字段一个不改）
const _eventPayload = {
  'attachments': <Object>[],
  'cal_id': '/demo_user/home/',
  'color': '',
  'create_time': 1789769139,
  'dav_etag': 'fxapvuddrrwyvnvualepaygxohdgyitc',
  'description': 'probe desc',
  'dtend': 1789776339,
  'dtend_string': '20260919T080539',
  'dtstart': 1789772739,
  'dtstart_string': '20260919T070539',
  'evt_id': 1014,
  'extra_info': <String, dynamic>{},
  'ical_uid': '20260918T220539-kifssvkq@cal.synology.com',
  'is_all_day': false,
  'is_repeat_evt': false,
  'last_modify_user': 'demo_user',
  'location_info': {
    'address': '',
    'gps': {'lat': -1, 'lng': -1},
    'map_type': '',
    'name': '',
    'place_id': '',
  },
  'modify_time': 0,
  'notify_setting': <Object>[],
  'original_cal_id': '/demo_user/home/',
  'owner_id': 1029,
  'owner_name': 'demo_user',
  'participant': <Object>[],
  'personal_property': {'is_visible': true},
  'summary': 'probe-cal',
  'tz_id': 'Asia/Shanghai',
};

Future<({CalendarApi cal, FakeTransport t})> _boot([
  Map<String, Map<String, dynamic>> responses = const {},
]) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._calTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (cal: CalendarApi(api), t: t);
}

/// 重复事件的服务端回包（`repeat_setting` 是**对象**；`recurrence_id` 标出"这是哪一次"）
Map<String, dynamic> _repeatEventPayload({Object? repeatSetting}) => {
  ..._eventPayload,
  'evt_id': 1042,
  'is_repeat_evt': true,
  'recurrence_id': '20260919T070539',
  'dav_etag': 'etag-repeat',
  'repeat_setting':
      repeatSetting ??
      {
        'type': 'week',
        'interval': 1,
        'weekday': ['monday', 'wednesday'],
        'month_option': 'day_of_month',
        'week_start_day': 'monday',
        'end': {'type': 'count', 'count': 10},
      },
};

void main() {
  group('CalendarApi：参数与官方对齐', () {
    test('Cal/list 用 v5 + cal_type=event，回包键是 list', () async {
      final b = await _boot({'SYNO.Cal.Cal.list': _calListPayload});
      final cals = await b.cal.listCalendars();

      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Cal.Cal');
      expect(call['method'], 'list');
      expect(call['version'], '5', reason: '空参 9009、v1 回 {} —— 只能 v5');
      expect(call['cal_type'], 'event');

      expect(cals.single.displayName, 'My Calendar');
      expect(cals.single.calId, '/demo_user/home/');
      expect(cals.single.color, '#B240AF');
      expect(cals.single.canWrite, isTrue, reason: 'cal_privilege=RW');
      expect(cals.single.isDefault, isTrue);
      expect(cals.single.originalUserNo, 1029);
    });

    test('只读日历（RO）canWrite=false', () async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {..._calListPayload['list']![0], 'cal_privilege': 'RO'},
          ],
        },
      });
      expect((await b.cal.listCalendars()).single.canWrite, isFalse);
    });

    test('Setting/get 用 v5，解析时区/周起始日', () async {
      final b = await _boot({
        'SYNO.Cal.Setting.get': {
          'date_format': 'Y-m-d',
          'default_cal': '',
          'default_view': 'week',
          'time_format': '24',
          'time_zone': 'Asia/Shanghai',
          'tls_default_level': 2,
          'user_no': 1029,
          'week_start_day': 0,
        },
      });
      final s = await b.cal.setting();
      expect(b.t.calls.last['version'], '5');
      expect(s.timeZone, 'Asia/Shanghai');
      expect(s.weekStartDay, 0);
      expect(s.dateFormat, 'Y-m-d');
    });

    test('Event/list：cal_id_list 是 JSON 数组串，start/end 是 epoch 秒裸串', () async {
      final b = await _boot({
        'SYNO.Cal.Event.list': {
          'list': [_eventPayload],
        },
      });
      final from = DateTime(2026, 9, 18);
      final to = DateTime(2026, 9, 25);
      final events = await b.cal.listEvents(
        calendarIds: const ['/demo_user/home/'],
        from: from,
        to: to,
      );

      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Cal.Event');
      expect(call['version'], '6', reason: 'v4 真机回 121，只能 5/6');
      expect(
        call['cal_id_list'],
        '["/demo_user/home/"]',
        reason: '数组必须 JSON 数组串：逗号拼或标量都回 9009',
      );
      expect(call['start'], '${from.millisecondsSinceEpoch ~/ 1000}');
      expect(call['end'], '${to.millisecondsSinceEpoch ~/ 1000}');

      final e = events.single;
      expect(e.evtId, '1014');
      expect(e.summary, 'probe-cal');
      expect(e.tzId, 'Asia/Shanghai');
      // 显示时间优先用 *_string（事件时区下的墙上时间）
      expect(e.start, DateTime(2026, 9, 19, 7, 5, 39));
      expect(e.end, DateTime(2026, 9, 19, 8, 5, 39));
      expect(e.dtstart, 1789772739);
      expect(e.davEtag, 'fxapvuddrrwyvnvualepaygxohdgyitc');
    });

    test('Event/list 不传日历 id 时不发 cal_id_list 键', () async {
      final b = await _boot({
        'SYNO.Cal.Event.list': {'list': <Object>[]},
      });
      await b.cal.listEvents(
        calendarIds: const [],
        from: DateTime(2026, 9, 18),
        to: DateTime(2026, 9, 19),
      );
      expect(b.t.calls.last.containsKey('cal_id_list'), isFalse);
    });

    test('Event/create：字符串 Gson 引号串、epoch 裸串、数组 JSON 串', () async {
      final b = await _boot({'SYNO.Cal.Event.create': _eventPayload});
      final created = await b.cal.createEvent(
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: 'probe-cal',
        start: DateTime(2026, 9, 19, 7, 5, 39),
        end: DateTime(2026, 9, 19, 8, 5, 39),
        timeZone: 'Asia/Shanghai',
        description: 'probe desc',
      );

      final call = b.t.calls.last;
      expect(call['version'], '6');
      expect(call['cal_id'], '"/demo_user/home/"', reason: '裸串会 9009（真机实测）');
      expect(call['summary'], '"probe-cal"');
      expect(call['original_cal_id'], '"/demo_user/home/"');
      expect(call['tz_id'], '"Asia/Shanghai"');
      expect(call['color'], '""');
      expect(call['description'], '"probe desc"');
      expect(call['is_all_day'], 'false', reason: '布尔裸串');
      expect(call['is_repeat_evt'], 'false');
      // epoch 是数字 → 裸串（本地墙上时间换算）
      expect(
        call['dtstart'],
        '${DateTime(2026, 9, 19, 7, 5, 39).millisecondsSinceEpoch ~/ 1000}',
      );
      expect(
        call['dtend'],
        '${DateTime(2026, 9, 19, 8, 5, 39).millisecondsSinceEpoch ~/ 1000}',
      );
      expect(call['participant'], '[]');
      expect(call['notify_setting'], '[]');
      expect(created.evtId, '1014');
    });

    test('全天事件：tz_id 传空串 + is_all_day=true', () async {
      final b = await _boot({'SYNO.Cal.Event.create': _eventPayload});
      await b.cal.createEvent(
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: 'all day',
        start: DateTime(2026, 9, 19),
        end: DateTime(2026, 9, 20),
        isAllDay: true,
        timeZone: 'Asia/Shanghai',
      );
      final call = b.t.calls.last;
      expect(call['is_all_day'], 'true');
      expect(call['tz_id'], '""', reason: '全天事件官方不发时区');
      // 官方编码：dtstart = 开始日 UTC 零点，dtend = **结束日次日** UTC 零点（exclusive）
      expect(
        call['dtstart'],
        '${DateTime.utc(2026, 9, 19).millisecondsSinceEpoch ~/ 1000}',
      );
      expect(
        call['dtend'],
        '${DateTime.utc(2026, 9, 21).millisecondsSinceEpoch ~/ 1000}',
      );
    });

    test('Event/get 与 Event/delete 的 evt_id 必须是裸串', () async {
      final b = await _boot({
        'SYNO.Cal.Event.get': _eventPayload,
        'SYNO.Cal.Event.delete': <String, dynamic>{},
      });
      final got = await b.cal.event('1014');
      expect(b.t.calls.last['evt_id'], '1014', reason: '加引号（"1014"）真机回 9009');
      expect(got?.summary, 'probe-cal');

      await b.cal.deleteEvent('1014');
      final del = b.t.calls.last;
      expect(del['api'], 'SYNO.Cal.Event');
      expect(del['method'], 'delete');
      expect(del['evt_id'], '1014');
      expect(del['version'], '6');
    });

    test('Todo/list：cal_id_list JSON 数组串 + filter_complete', () async {
      final b = await _boot({
        'SYNO.Cal.Todo.list': {
          'list': [
            {
              'evt_id': 7,
              'summary': '买牛奶',
              'percent_complete': 0,
              'due': 1789776339,
              'due_string': '20260919T080539',
              'original_cal_id': '/demo_user/home/',
              'priority_order': 0,
            },
            {'evt_id': 8, 'summary': '已做', 'percent_complete': 100},
          ],
        },
      });
      final todos = await b.cal.listTodos(
        calendarIds: const ['/demo_user/home/'],
      );
      final call = b.t.calls.last;
      expect(call['version'], '6', reason: 'v1 真机回 117');
      expect(call['cal_id_list'], '["/demo_user/home/"]');
      expect(call['filter_complete'], 'no');
      expect(todos.length, 2);
      expect(todos[0].summary, '买牛奶');
      expect(todos[0].done, isFalse);
      expect(todos[0].dueAt, DateTime(2026, 9, 19, 8, 5, 39));
      expect(todos[1].done, isTrue);
    });

    test('Cal/list {cal_type:"todo"}：待办日历是**另一套**日历', () async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {
          'list': [
            {
              ..._calListPayload['list']![0],
              'cal_id': '/demo_user/home_todo/',
              'cal_type': 'todo',
              'cal_displayname': 'My Tasks',
            },
          ],
        },
      });
      final cals = await b.cal.listTodoCalendars();
      final call = b.t.calls.last;
      expect(call['version'], '5');
      expect(call['cal_type'], 'todo', reason: '事件日历 id 丢给 Todo/list 查不到待办');
      expect(cals.single.calId, '/demo_user/home_todo/');
    });

    test('Todo/create：必填 7 项 + 编码口径与 Event/create 一致', () async {
      final b = await _boot({
        'SYNO.Cal.Todo.create': {
          'evt_id': 9,
          'summary': '买牛奶',
          'dav_etag': 'abc',
          'percent_complete': 0,
        },
      });
      final todo = await b.cal.createTodo(
        originalCalendarId: '/demo_user/home_todo/',
        summary: '买牛奶',
        description: '两升',
        due: DateTime(2026, 9, 21, 9),
        timeZone: 'Asia/Shanghai',
      );
      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Cal.Todo');
      expect(call['method'], 'create');
      expect(call['version'], '6');
      // 字符串 → Gson 引号串（裸串回 9009）
      expect(call['original_cal_id'], '"/demo_user/home_todo/"');
      expect(call['summary'], '"买牛奶"');
      expect(call['description'], '"两升"');
      expect(call['tz_id'], '"Asia/Shanghai"');
      expect(call['notify_setting'], '[]');
      expect(call['from_syno_app_url'], '{}');
      // 布尔/数字 → 裸串
      expect(call['has_start_time'], 'false');
      expect(call['has_end_time'], 'true');
      expect(call['percent_complete'], '0');
      expect(call['is_all_day'], 'false');
      expect(
        call['due'],
        '${DateTime(2026, 9, 21, 9).millisecondsSinceEpoch ~/ 1000}',
      );
      expect(call.containsKey('dtstart'), isFalse, reason: '没给开始时间就别发');
      expect(todo.evtId, '9');
      expect(todo.davEtag, 'abc');
    });

    test('Todo/create 全天：tz_id 必须是空串（服务端会校验）', () async {
      final b = await _boot({
        'SYNO.Cal.Todo.create': {'evt_id': 10, 'summary': 'x'},
      });
      await b.cal.createTodo(
        originalCalendarId: '/c/',
        summary: 'x',
        isAllDay: true,
        timeZone: 'Asia/Shanghai',
      );
      expect(b.t.calls.last['tz_id'], '""');
      expect(b.t.calls.last['is_all_day'], 'true');
    });

    test('Todo/set：带 evt_id（裸串）+ dav_etag + priority_order，全量提交', () async {
      final b = await _boot({
        'SYNO.Cal.Todo.set': {
          'evt_id': 9,
          'summary': '买牛奶',
          'percent_complete': 100,
        },
      });
      final todo = CalTodoDto.fromJson(const {
        'evt_id': 9,
        'summary': '买牛奶',
        'description': '两升',
        'original_cal_id': '/demo_user/home_todo/',
        'dav_etag': 'etag-1',
        'priority_order': 3,
        'due': 1789776339,
        'has_end_time': true,
      });
      await b.cal.setTodo(todo, percentComplete: 100);
      final call = b.t.calls.last;
      expect(call['method'], 'set');
      expect(call['version'], '6');
      expect(call['evt_id'], '9', reason: '裸串：加引号回 9009');
      expect(call['dav_etag'], '"etag-1"', reason: '乐观锁：不带会 1019 冲突');
      expect(call['priority_order'], '3');
      expect(call['percent_complete'], '100');
      expect(call['summary'], '"买牛奶"', reason: '不打参数 = 服务端当清空，必须全量带上');
      expect(call['description'], '"两升"');
      expect(call['has_end_time'], 'true');
      expect(call['due'], '1789776339');
      expect(call['has_start_time'], 'false');
      expect(call.containsKey('dtstart'), isFalse);
    });

    test('Todo/set 清除截止时间：不发 due 且 has_end_time=false', () async {
      final b = await _boot({
        'SYNO.Cal.Todo.set': {'evt_id': 9, 'summary': 'x'},
      });
      final todo = CalTodoDto.fromJson(const {
        'evt_id': 9,
        'summary': 'x',
        'due': 1789776339,
        'has_end_time': true,
      });
      await b.cal.setTodo(todo, clearDue: true);
      final call = b.t.calls.last;
      expect(call['has_end_time'], 'false');
      expect(call.containsKey('due'), isFalse);
    });

    test('Todo/delete：evt_id 裸串', () async {
      final b = await _boot({'SYNO.Cal.Todo.delete': const {}});
      await b.cal.deleteTodo('9');
      final call = b.t.calls.last;
      expect(call['method'], 'delete');
      expect(call['evt_id'], '9');
      expect(call['version'], '6');
    });

    test('Todo/clean_complete：**只有 v1**，参数是 cal_id_list 数组串', () async {
      final b = await _boot({'SYNO.Cal.Todo.clean_complete': const {}});
      await b.cal.cleanCompletedTodos(const ['/demo_user/home_todo/']);
      final call = b.t.calls.last;
      expect(call['method'], 'clean_complete');
      expect(call['version'], '1', reason: '方法分散在不互相包含的版本里：v5/v6 回 103');
      expect(call['cal_id_list'], '["/demo_user/home_todo/"]');
    });

    test('版本协商：表里没有的 API 也不炸（返回候选第一档）', () async {
      final b = await _boot({'SYNO.Cal.Cal.list': _calListPayload});
      await b.cal.listCalendars();
      expect(b.t.calls.last['version'], '5');
    });
  });

  group('CalendarDto 容错', () {
    test('缺字段/类型不对都不崩', () {
      final cal = CalendarDto.fromJson(const {});
      expect(cal.calId, '');
      expect(cal.calType, 'event');
      expect(cal.canWrite, isFalse);

      final e = CalEventDto.fromJson(const {
        'evt_id': 12,
        'summary': null,
        'dtstart': '1789772739',
        'is_all_day': 1,
        'participant': ['a@b.com'],
      });
      expect(e.evtId, '12');
      expect(e.summary, '');
      expect(e.dtstart, 1789772739);
      expect(e.isAllDay, isTrue);
      expect(e.participants, ['a@b.com']);
      expect(
        e.start,
        DateTime.fromMillisecondsSinceEpoch(1789772739 * 1000),
        reason: '没有 *_string 时退化到 epoch 本地时间',
      );
    });

    test('CalTodoDto：回包用 evt_cal/dtstart/dtstart_string/tzid 也要认', () {
      // openapi `/task` GET 的真名（老代码只读 cal_id/start/start_string/tz_id → 全空）
      final t = CalTodoDto.fromJson(const {
        'evt_id': 7,
        'summary': '买牛奶',
        'evt_cal': '/demo_user/home_todo/',
        'dtstart': 1789772739,
        'dtstart_string': '20260919T070539',
        'due': 1789776339,
        'due_string': '20260919T080539',
        'tzid': 'Asia/Shanghai',
        'dav_etag': 'etag-1',
        'has_start_time': true,
        'has_end_time': true,
        'ical_uid': 'u1',
        'owner_name': 'demo_user',
        'last_modify_user': 'demo_user',
        'from_syno_app_url': '',
      });
      expect(t.calId, '/demo_user/home_todo/');
      expect(t.start, 1789772739);
      expect(t.startAt, DateTime(2026, 9, 19, 7, 5, 39));
      expect(t.dueAt, DateTime(2026, 9, 19, 8, 5, 39));
      expect(t.tzId, 'Asia/Shanghai');
      expect(t.davEtag, 'etag-1');
      expect(t.hasStart, isTrue);
      expect(t.hasDue, isTrue);
      expect(t.icalUid, 'u1');
      expect(t.ownerName, 'demo_user');
    });

    test('CalTodoDto：老回包（cal_id/start/tz_id）继续能读', () {
      final t = CalTodoDto.fromJson(const {
        'evt_id': 7,
        'summary': 'x',
        'cal_id': '/c/',
        'start': 1789772739,
        'tz_id': 'Asia/Shanghai',
      });
      expect(t.calId, '/c/');
      expect(t.start, 1789772739);
      expect(t.tzId, 'Asia/Shanghai');
      expect(t.hasDue, isFalse);
    });

    test('parseCalStamp：格式不对返回 null', () {
      expect(parseCalStamp('20260919T070539'), DateTime(2026, 9, 19, 7, 5, 39));
      expect(parseCalStamp(''), isNull);
      expect(parseCalStamp('2026-09-19 07:05:39'), isNull);
      expect(parseCalStamp('20260919T07053'), isNull);
    });

    test('Event/list 的 list 键缺失时返回空表', () {
      expect(CalEventDto.listFromJson(const {}), isEmpty);
      expect(CalendarDto.listFromJson(const {}), isEmpty);
      expect(
        CalTodoDto.listFromJson(
          jsonDecode('{"list":null}') as Map<String, dynamic>,
        ),
        isEmpty,
      );
    });
  });
  group('CalendarApi：重复事件（repeat_setting / set_exdate）', () {
    test(
      'create 带重复：is_repeat_evt=true + repeat_setting 是按服务端枚举的 JSON 串',
      () async {
        final b = await _boot({'SYNO.Cal.Event.create': _eventPayload});
        await b.cal.createEvent(
          calendarId: '/demo_user/home/',
          originalCalendarId: '/demo_user/home/',
          summary: 'weekly sync',
          start: DateTime(2026, 9, 19, 9),
          end: DateTime(2026, 9, 19, 10),
          timeZone: 'Asia/Shanghai',
          repeat: const CalRepeatRule(
            type: 'week',
            interval: 2,
            weekday: ['monday', 'wednesday'],
            weekStartDay: 'monday',
            endType: 'count',
            endCount: 10,
          ),
        );

        final call = b.t.calls.last;
        expect(call['method'], 'create');
        expect(call['is_repeat_evt'], 'true', reason: '布尔是裸串');
        final rule =
            jsonDecode(call['repeat_setting'] as String)
                as Map<String, dynamic>;
        expect(rule['type'], 'week');
        expect(rule['interval'], 2);
        expect(rule['weekday'], ['monday', 'wednesday']);
        expect(
          rule['week_start_day'],
          'monday',
          reason: '内层键是 snake_case（camelCase 真机回 9009）',
        );
        expect(rule['end'], {'type': 'count', 'count': 10, 'date': 0});
        expect(
          rule.containsKey('month_option'),
          isFalse,
          reason: '按周的规则不带 month_option（按类型只带对应的那个）',
        );
      },
    );

    test('不重复：is_repeat_evt=false 且**整个 repeat_setting 键都不发**', () async {
      final b = await _boot({'SYNO.Cal.Event.create': _eventPayload});
      await b.cal.createEvent(
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: 'one shot',
        start: DateTime(2026, 9, 19, 9),
        end: DateTime(2026, 9, 19, 10),
      );

      final call = b.t.calls.last;
      expect(call['is_repeat_evt'], 'false');
      expect(
        call.containsKey('repeat_setting'),
        isFalse,
        reason: '官方参数层会过滤 null —— 不带键，而不是带 "null"',
      );
    });

    test('按月按"第几个星期几"：带 month_option=day_of_week', () async {
      final b = await _boot({'SYNO.Cal.Event.create': _eventPayload});
      await b.cal.createEvent(
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: 'monthly',
        start: DateTime(2026, 9, 19, 9),
        end: DateTime(2026, 9, 19, 10),
        repeat: const CalRepeatRule(
          type: 'month',
          monthOption: 'day_of_week',
          endType: 'never',
        ),
      );
      final rule =
          jsonDecode(b.t.calls.last['repeat_setting'] as String)
              as Map<String, dynamic>;
      expect(rule['month_option'], 'day_of_week');
      expect(rule['end'], {'type': 'never', 'count': 1, 'date': 0});
    });

    test('set_exdate：evt_id/exdate 裸串 + dav_etag 引号串（真机 x1 唯一通的组合）', () async {
      final b = await _boot({'SYNO.Cal.Event.set_exdate': <String, dynamic>{}});
      await b.cal.setEventExdate(
        evtId: '1042',
        davEtag: 'etag-repeat',
        exdate: '20260919T070539',
      );

      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Cal.Event');
      expect(call['method'], 'set_exdate');
      expect(call['evt_id'], '1042', reason: '裸串');
      expect(call['dav_etag'], '"etag-repeat"');
      expect(
        call['exdate'],
        '20260919T070539',
        reason: 'exdate 是裸串（引号串真机 9009）',
      );
    });

    test('Event/set：evt_id 裸串、字符串引号串，四个"整体替换"字段原样回传', () async {
      final b = await _boot({'SYNO.Cal.Event.set': _eventPayload});
      final source = CalEventDto.fromJson({
        ..._eventPayload,
        // 源事件带着受邀人 / 提醒 / 地点 / 附件：编辑时必须原样回传，否则会被清空
        'participant': [
          {
            'type': 'dsm',
            'role': 'attendee',
            'user_name': 'bob',
            'status': 'accepted',
          },
        ],
        'notify_setting': [
          {'type': 'duration', 'action': 'DISPLAY'},
        ],
        'location_info': {
          'name': '公司',
          'address': '文一西路 1 号',
          'map_type': 'baidu',
          'place_id': 'pid-1',
          'gps': {'lat': 30.1, 'lng': 120.2},
        },
        'attachments': [
          {'filename': 'a.txt', 'file_size': 3},
        ],
      });
      await b.cal.updateEvent(
        source: source,
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: '改过的标题',
        start: DateTime(2026, 9, 19, 7, 5),
        end: DateTime(2026, 9, 19, 8, 5),
        timeZone: 'Asia/Shanghai',
        description: '改过的说明',
      );

      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Cal.Event');
      expect(call['method'], 'set');
      expect(call['version'], '6');
      expect(call['evt_id'], '1014', reason: '裸串（引号串 9009）');
      expect(
        call['dav_etag'],
        '"fxapvuddrrwyvnvualepaygxohdgyitc"',
        reason: '乐观锁',
      );
      expect(call['summary'], '"改过的标题"');
      expect(call['description'], '"改过的说明"');
      expect(call['cal_id'], '"/demo_user/home/"');
      expect(call['original_cal_id'], '"/demo_user/home/"');
      expect(call['is_all_day'], 'false');
      expect(call['tz_id'], '"Asia/Shanghai"');
      expect(call['is_repeat_evt'], 'false');
      expect(call.containsKey('repeat_setting'), isFalse, reason: '不重复就不发这个键');
      // 四个"整体替换"字段：原样 JSON 回传（真机验证过这样能保住）
      expect(jsonDecode(call['participant']! as String), [
        {
          'type': 'dsm',
          'role': 'attendee',
          'user_name': 'bob',
          'status': 'accepted',
        },
      ]);
      expect(jsonDecode(call['notify_setting']! as String), [
        {'type': 'duration', 'action': 'DISPLAY'},
      ]);
      final loc = jsonDecode(call['location_info']! as String) as Map;
      expect(loc['name'], '公司');
      expect(loc['place_id'], 'pid-1', reason: '强类型字段装不下的 place_id 也要原样带回');
      expect((loc['gps'] as Map)['lat'], 30.1);
      expect(jsonDecode(call['attachments']! as String), [
        {'filename': 'a.txt', 'file_size': 3},
      ]);
    });

    test('Event/set：重复系列带上**改过的** repeat_setting', () async {
      final b = await _boot({'SYNO.Cal.Event.set': _eventPayload});
      await b.cal.updateEvent(
        source: CalEventDto.fromJson(_repeatEventPayload()),
        calendarId: '/demo_user/home/',
        originalCalendarId: '/demo_user/home/',
        summary: '系列改名',
        start: DateTime(2026, 9, 19, 7, 5),
        end: DateTime(2026, 9, 19, 8, 5),
        timeZone: 'Asia/Shanghai',
        repeat: const CalRepeatRule(
          type: 'day',
          interval: 2,
          endType: 'count',
          endCount: 5,
        ),
      );

      final call = b.t.calls.last;
      expect(call['is_repeat_evt'], 'true');
      final rule =
          jsonDecode(call['repeat_setting']! as String) as Map<String, dynamic>;
      expect(rule['type'], 'day');
      expect(rule['interval'], 2);
      expect(rule['week_start_day'], 'sunday');
      expect(rule['end'], {'type': 'count', 'count': 5, 'date': 0});
    });

    test(
      'Event/subevent_set：recurrence_id 裸串 + 必须带 participant/location_info/is_repeat_evt',
      () async {
        final b = await _boot({'SYNO.Cal.Event.subevent_set': _eventPayload});
        await b.cal.updateSubEvent(
          instance: CalEventDto.fromJson(
            _repeatEventPayload(),
          ), // 服务端回的实例 recurrence_id
          calendarId: '/demo_user/home/',
          originalCalendarId: '/demo_user/home/',
          summary: '只改这一次',
          start: DateTime(2026, 9, 19, 7, 5),
          end: DateTime(2026, 9, 19, 8, 5),
          timeZone: 'Asia/Shanghai',
        );

        final call = b.t.calls.last;
        expect(call['method'], 'subevent_set');
        expect(call['version'], '6', reason: '只有 v6（v5 是官方老 Web UI 的版本，本机不吃）');
        expect(call['evt_id'], '1042', reason: '裸串');
        expect(call['recurrence_id'], '20260919T070539', reason: '裸串，按日期字段解析');
        expect(call['dav_etag'], '"etag-repeat"');
        // 真机实测：漏掉这三项回 9009（subevent_set 也是"整体替换"语义）
        expect(call['is_repeat_evt'], 'true');
        expect(call.containsKey('participant'), isTrue);
        expect(call.containsKey('location_info'), isTrue);
        expect(jsonDecode(call['participant']! as String), isEmpty);
      },
    );

    test(
      'Event/subevent_set：服务端不给 recurrence_id 时退化成这次的 dtstart_string',
      () async {
        final b = await _boot({'SYNO.Cal.Event.subevent_set': _eventPayload});
        final instance = CalEventDto.fromJson({
          ..._repeatEventPayload(),
          'recurrence_id': null,
          'dtstart_string': '20260930T070539',
        });
        await b.cal.updateSubEvent(
          instance: instance,
          calendarId: '/demo_user/home/',
          originalCalendarId: '/demo_user/home/',
          summary: '只改这一次',
          start: DateTime(2026, 9, 30, 7, 5),
          end: DateTime(2026, 9, 30, 8, 5),
          timeZone: 'Asia/Shanghai',
        );
        expect(b.t.calls.last['recurrence_id'], '20260930T070539');
      },
    );

    test('时间编码：全天取 UTC 零点、dtend 是次日零点（官方 getAllDayUTCSeconds）', () {
      // 2026-09-24 全天（单日）：dtstart = 当天 UTC 零点，dtend = 次日 UTC 零点
      final oneDay = CalendarApi.eventEpoch(
        start: DateTime(2026, 9, 24),
        end: DateTime(2026, 9, 24),
        isAllDay: true,
      );
      expect(
        oneDay.start,
        DateTime.utc(2026, 9, 24).millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        oneDay.end,
        DateTime.utc(2026, 9, 25).millisecondsSinceEpoch ~/ 1000,
      );
      expect(oneDay.end - oneDay.start, 86400);

      // 多天：结束日 +1 天（exclusive）
      final three = CalendarApi.eventEpoch(
        start: DateTime(2026, 9, 24),
        end: DateTime(2026, 9, 26),
        isAllDay: true,
      );
      expect(
        three.end,
        DateTime.utc(2026, 9, 27).millisecondsSinceEpoch ~/ 1000,
      );

      // 非全天：原样 epoch 秒（本地墙上时间）
      final timed = CalendarApi.eventEpoch(
        start: DateTime(2026, 9, 24, 10),
        end: DateTime(2026, 9, 24, 11),
        isAllDay: false,
      );
      expect(
        timed.start,
        DateTime(2026, 9, 24, 10).millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        timed.end,
        DateTime(2026, 9, 24, 11).millisecondsSinceEpoch ~/ 1000,
      );
    });

    test('重复"到某天"：全天按 UTC 的 23:59:59，非全天按本地 23:59:59', () {
      final rule = CalRepeatRule(endType: 'date', endDate: '2027-01-31');
      final utc = (rule.toJson(allDay: true)['end']! as Map)['date']! as int;
      expect(
        utc,
        DateTime.utc(2027, 1, 31, 23, 59, 59).millisecondsSinceEpoch ~/ 1000,
      );
      final local = (rule.toJson()['end']! as Map)['date']! as int;
      expect(
        local,
        DateTime(2027, 1, 31, 23, 59, 59).millisecondsSinceEpoch ~/ 1000,
      );
    });

    test('DTO：repeat_setting 是对象或 JSON 串都收，并带 recurrence_id', () {
      final asMap = CalEventDto.fromJson(_repeatEventPayload());
      expect(asMap.isRepeatEvt, isTrue);
      expect(asMap.recurrenceId, '20260919T070539');
      expect(asMap.repeat!.type, 'week');
      expect(asMap.repeat!.weekday, ['monday', 'wednesday']);
      expect(asMap.repeat!.endType, 'count');
      expect(asMap.repeat!.endCount, 10);
      expect(asMap.repeat!.describe(), '每周 · 周一、周三 · 共 10 次');

      // 回包是 snake_case，camelCase 老格式也收；`end.date` 是 epoch 秒
      final camel = CalEventDto.fromJson(
        _repeatEventPayload(
          repeatSetting: {
            'type': 'month',
            'interval': 1,
            'monthOption': 'day_of_week',
            'weekStartDay': 'monday',
            'end': {'type': 'date', 'count': 1, 'date': 1789718400},
          },
        ),
      );
      expect(camel.repeat!.monthOption, 'day_of_week');
      expect(camel.repeat!.weekStartDay, 'monday');
      expect(camel.repeat!.endType, 'date');
      expect(
        camel.repeat!.endDate,
        startsWith('2026-09-'),
        reason: 'epoch 秒要换算成界面用的日期串',
      );

      final asString = CalEventDto.fromJson(
        _repeatEventPayload(repeatSetting: jsonEncode({'type': 'day'})),
      );
      expect(asString.repeat!.type, 'day');
      expect(asString.repeat!.interval, 1);
      expect(asString.repeat!.describe(), '每天');

      // 一次性事件：没有 repeat_setting
      final once = CalEventDto.fromJson(_eventPayload);
      expect(once.repeat, isNull);
      expect(once.isRepeatEvt, isFalse);
    });

    test('DTO：每月"第几个星期几"与"到某天"的人话', () {
      final byDow = CalRepeatRule.fromJson({
        'type': 'month',
        'interval': 3,
        'month_option': 'day_of_week',
        'end': {'type': 'date', 'date': '2027-01-31'},
      });
      expect(byDow.describe(), '每 3 个月 · 按月内第几个星期几 · 到 2027-01-31');
      // 发出去是 epoch 秒（当天 23:59:59 本地时间），不是日期串
      final epoch = (byDow.toJson()['end']! as Map)['date']! as int;
      final back = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
      expect('${back.year}-${back.month}-${back.day}', '2027-1-31');
      expect(back.hour, 23);
      expect(
        (const CalRepeatRule(
              endType: 'never',
              endDate: '2027-01-31',
            ).toJson()['end']!
            as Map)['date'],
        0,
        reason: '非 date 结束方式给数字 0（空串会让服务端 Gson 崩）',
      );
    });
  });
}
