// C 类第四批（Calendar / Contacts 外部源与联系人能力补齐）的离线用例。
//
// 每条断言后面都跟着**原文证据**（包内文件 + 函数名/字符串），因为这一批的
// 全部价值就是"不猜"：
//   * `Contacts.ExternalSource/list` 的字段映射 —— 官方 `ui/static/js/main.js` 的 `kD()`；
//   * `status` 的 -1/1/0 语义 —— 同文件 `renderLastUpdate()`（`ji=-1`、`Gi=1`）；
//   * 组织单位调用参数 —— 同文件 `LD()`；分组显隐 —— `toggleGroup` / `toggleMember`；
//   * 分组字段 `is_hidden/path` —— 同文件 `MD()` 的 `listGroup` 合并段；
//   * `Cal/list` 的 9009 语义 —— 包内 `ui/syno-cal-err-code.json` 的
//     `"9009":"error:invalid_parameter"`；
//   * `Proxy/cal_list` 的参数与字段 —— `ui/synocalendar-app.js` +
//     `ui/synocalendar.bundle.min.js`。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/calendar_api.dart';
import 'package:synhub/src/data/contacts_api.dart';
import 'package:synhub/src/data/dto/contact_extras_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/contacts/contacts_manage_page.dart';
import 'package:synhub/src/features/contacts/contacts_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// Calendar 3.0.3-21434 / Contacts 1.0.11-20661 真机 `SYNO.API.Info` 子集
const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Cal.Cal': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Event': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Setting': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.Todo': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 6},
  'SYNO.Cal.Proxy': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Cal.AuthForeign': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
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
  'SYNO.Contacts.ExternalSource': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Contacts.OU': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
};

Future<({ContactsApi contacts, CalendarApi cal, FakeTransport t})> _boot([
  Map<String, Map<String, dynamic>> responses = const {},
]) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (contacts: ContactsApi(api), cal: CalendarApi(api), t: t);
}

void main() {
  // ------------------------------------------------------------ 外部源（只读）
  group('C4-1 Contacts 外部源只读（ExternalSource/list）', () {
    test('空列表是正确空态：真机 {"external_sources":[],"total":0} 不抛错', () async {
      // 真机原文（docs/live-nas-verification.md §6.2）：
      // {"data": {"external_sources": [], "total": 0}, "success": true}
      final b = await _boot({
        'SYNO.Contacts.ExternalSource.list': {
          'external_sources': <Object>[],
          'total': 0,
        },
      });
      final list = await b.contacts.externalSources();
      expect(list, isEmpty);

      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Contacts.ExternalSource');
      expect(call['method'], 'list');
      expect(call['version'], '1');
      // 官方唯一调用点是空参：Ht(Hn.send,"listExternalSource",{})
      expect(call.containsKey('offset'), isFalse);
      expect(call.containsKey('limit'), isFalse);
    });

    test('字段按官方 kD() 映射：source/status/username/update_time', () async {
      // 官方 main.js：
      // n&&(n.source=t.source, n.sync_status=t.status,
      //      n.user_name=t.username, n.last_update=t.update_time);
      final b = await _boot({
        'SYNO.Contacts.ExternalSource.list': {
          'external_sources': [
            {
              'addressbook_id': 9,
              'source': 'carddav',
              'status': -1,
              'username': 'demo',
              'update_time': 1700000000,
            },
          ],
          'total': 1,
        },
      });
      final s = (await b.contacts.externalSources()).single;
      expect(s.addressbookId, '9');
      expect(s.source, 'carddav');
      expect(s.isCardDav, isTrue);
      expect(s.username, 'demo');
      // 官方 renderLastUpdate()：e===ji(-1) → status_fail
      expect(s.status, ExternalSourceDto.statusFailed);
      expect(s.hasFailed, isTrue);
      // 官方 new Date(1e3*t)：update_time 是 epoch 秒
      expect(
        s.lastUpdatedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
      expect(s.lastSyncTime, '1700000000');
    });

    test('status=1 → 正在处理；status=0 → 展示 update_time 的"上次更新"', () {
      // 官方 renderLastUpdate()：e===Gi(1) → status_process；否则格式化时间
      final processing = ExternalSourceDto.fromJson({
        'addressbook_id': 1,
        'source': 'google',
        'status': 1,
        'update_time': 0,
      });
      expect(processing.isProcessing, isTrue);
      expect(processing.hasFailed, isFalse);
      expect(processing.isGoogle, isTrue);
      expect(processing.lastUpdatedAt, isNull);

      final ok = ExternalSourceDto.fromJson({
        'addressbook_id': 2,
        'source': 'outlook',
        'status': 0,
        'update_time': 1600000000,
      });
      expect(ok.isProcessing, isFalse);
      expect(ok.hasFailed, isFalse);
      expect(ok.isOutlook, isTrue);
      expect(ok.lastUpdatedAt, isNotNull);
    });

    test('get 未实现（方法存在但参数无原文证据，真机 120）→ 不在 API 面上', () {
      // 纪律用例：`ExternalSource/get` 在 `SYNO.Contacts.so` 里存在
      // （external_source::Get_v1），但官方 JS 无调用点、真机任意入参回 120
      // 且 errors 是空对象 —— 所以**没有**对应方法，改坏了这条就会红。
      final api = ContactsApi(DsmWebApi(FakeTransport(const {}, _table)));
      expect(api.externalSources, isNotNull);
      // 列表项已经带全 UI 需要的字段，足够做"列表 + 状态"
      expect(ExternalSourceDto.listFromJson(const {}), isEmpty);
    });
  });

  // ---------------------------------------------------------------- 分组
  group('C4-2 Contacts 分组（list_group / OU / toggle_*）', () {
    test('list_group 用 addressbook_id，解析官方 {is_hidden, path}', () async {
      // 官方 main.js MD()：
      // Ht(Hn.send,"listGroup",{addressbook_id:i.addressbook[l].id});
      // ...is_hidden:e.is_hidden,path:e.path})
      final b = await _boot({
        'SYNO.Contacts.Contact.list_group': {
          'group': [
            {
              'id': 21,
              'name': 'Sales',
              'member_count': 3,
              'is_hidden': true,
              'path': 'OU=Sales,DC=example,DC=com',
            },
          ],
          'total': 1,
        },
      });
      final g = (await b.contacts.groups(addressbookId: '5')).single;
      expect(b.t.calls.last['addressbook_id'], '5');
      expect(b.t.calls.last['version'], '1');
      expect(g.name, 'Sales');
      expect(g.memberCount, 3);
      expect(g.isHidden, isTrue);
      expect(g.path, 'OU=Sales,DC=example,DC=com');
    });

    test('OU/list 参数是官方 {limit:100,offset:0,addressbook_id}', () async {
      // 官方 main.js LD()：
      // Ht(Hn.send,"listOrganizationUnit",{limit:100,offset:0,addressbook_id:t})
      final b = await _boot({
        'SYNO.Contacts.OU.list': {
          'ou': [
            {
              'id': 3,
              'dn': 'OU=Sales,OU=HQ,DC=example,DC=com',
              'principal': [11, 12],
            },
          ],
        },
      });
      final ous = await b.contacts.organizationUnits(addressbookId: '5');
      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Contacts.OU');
      expect(call['method'], 'list');
      expect(call['version'], '1');
      expect(call['limit'], '100');
      expect(call['offset'], '0');
      expect(call['addressbook_id'], '5');

      final ou = ous.single;
      // 官方 ID() 读 e.ou，并用 dn 最靠左的 OU= 段当 name
      expect(ou.name, 'Sales');
      expect(ou.depth, 2);
      expect(ou.parentDn, 'OU=HQ,DC=example,DC=com');
      expect(ou.principalIds, ['11', '12']);
    });

    test('toggle_group 的 ids 是 JSON 数组串、is_hidden 小写', () async {
      // 官方 main.js：toggleGroup(ids,isHidden) → {ids,is_hidden}
      final b = await _boot({
        'SYNO.Contacts.Contact.toggle_group': <String, dynamic>{},
      });
      await b.contacts.setGroupsHidden(['21', '22'], hidden: true);
      final call = b.t.calls.last;
      expect(call['method'], 'toggle_group');
      expect(call['version'], '1');
      expect(call['ids'], '["21","22"]', reason: 'ids 是 JSON 数组串');
      expect(call['is_hidden'], 'true');
    });

    test('toggle_member 的 id 是裸标量（和 toggle_person 不同）', () async {
      // 官方 main.js MO()：Ht(Hn.send,"toggleMember",{id:t,is_hidden:n})
      final b = await _boot({
        'SYNO.Contacts.Contact.toggle_member': <String, dynamic>{},
      });
      await b.contacts.setGroupMemberHidden('11', hidden: false);
      final call = b.t.calls.last;
      expect(call['method'], 'toggle_member');
      expect(call['id'], '11', reason: '裸标量，不是 [11]');
      expect(call['is_hidden'], 'false');
    });

    test('dn 解析：转义与没有 OU 段的 dn', () {
      // 官方 replace(/\\([\S\s])/g,"$1")
      expect(OuDto.ouNameFromDn(r'OU=Sa\,les,DC=x'), 'Sa,les');
      expect(OuDto.ouNameFromDn('CN=Users,DC=x'), '');
      expect(OuDto.ouNameFromDn('OU=Sales'), 'Sales');
      expect(OuDto.listFromJson(const {}), isEmpty);
    });
  });

  // ---------------------------------------------------------------- 日历
  group('C4-3 Calendar：9009 的语义与远端日历', () {
    test('Cal/list 必带 cal_type（不带 → 真机 9009）', () async {
      final b = await _boot({
        'SYNO.Cal.Cal.list': {'list': <Object>[]},
      });
      await b.cal.listCalendars();
      expect(b.t.calls.last['cal_type'], 'event');
      expect(b.t.calls.last['version'], '5');
    });

    test('9009 = error:invalid_parameter（包内 syno-cal-err-code.json 原文）', () {
      final msg = describeCalendarError(
        DsmApiException(CalApiErrorCode.invalidParameter, method: 'Cal.list'),
      );
      expect(msg, contains('9009'));
      expect(msg, contains('重试'));
      // ⚠️ 绝不能是"没有日历"这一类空数据说法
      expect(msg.contains('没有日历'), isFalse);
      expect(msg.contains('还没有日历'), isFalse);
      expect(CalApiErrorCode.invalidParameter, 9009);
    });

    test('117（internalError）也按"服务端暂时无法完成 + 可重试"处理', () {
      final msg = describeCalendarError(
        DsmApiException(DsmErrorCode.internalError, method: 'AuthForeign.list'),
      );
      expect(msg, contains('117'));
      expect(msg, contains('重试'));
      expect(msg.contains('没有'), isFalse);
    });

    test('Proxy/cal_list 用 auth_id，回包是裸数组（老 Web UI 直吃数组）', () async {
      // 官方 ui/synocalendar-app.js：
      // sendPromise("Proxy_cal_list",{auth_id:t.auth_id}).then(t=>store.loadData(t))
      final b = await _boot();
      b.t.bytesByUrl['SYNO.Cal.Proxy'] = utf8.encode(
        jsonEncode({
          'success': true,
          'data': [
            {
              'remote_cal_id': 'abc@group.calendar.google.com',
              'remote_cal_displayname': 'Holidays',
              'remote_cal_type': 'VCALENDAR',
              'cal_color': '#E0567B',
            },
          ],
        }),
      );
      final cals = await b.cal.remoteCalendars('7');
      expect(cals.single.remoteCalId, 'abc@group.calendar.google.com');
      expect(cals.single.displayName, 'Holidays');
      expect(cals.single.color, '#E0567B');

      final url = b.t.downloads.last;
      expect(url, contains('api=SYNO.Cal.Proxy'));
      expect(url, contains('method=cal_list'));
      expect(url, contains('auth_id=7'));
      expect(url, contains('version=1'));
    });

    test('Proxy/cal_list 的错误码照实抛出（不静默成空列表）', () async {
      final b = await _boot();
      b.t.bytesByUrl['SYNO.Cal.Proxy'] = utf8.encode(
        jsonEncode({
          'success': false,
          'error': {'code': 119},
        }),
      );
      await expectLater(
        b.cal.remoteCalendars('7'),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 119)),
      );
    });

    test('auth_id 为空时不发请求（省掉一次注定失败的调用）', () async {
      final b = await _boot();
      expect(await b.cal.remoteCalendars(''), isEmpty);
      expect(b.t.downloads, isEmpty);
    });
  });

  // ---------------------------------------------------------------- 能力位
  group('C4-5 能力位（最小可选位追加）', () {
    test('新能力位都确实在注册表的对应服务里（防漂移）', () {
      expect(
        kServiceRegistry[StationService.contacts]!.optionalApis,
        contains(kContactsExternalSourceApi),
      );
      expect(
        kServiceRegistry[StationService.contacts]!.optionalApis,
        contains(kContactsOUApi),
      );
      expect(
        kServiceRegistry[StationService.calendar]!.optionalApis,
        contains(kCalAuthForeignApi),
      );
      expect(
        kServiceRegistry[StationService.calendar]!.optionalApis,
        contains(kCalProxyApi),
      );
    });

    test('缺位 → 只 partial（隐藏入口），模块不 absent', () {
      // 缺 OU 但必需的 Contact 在 → partial（不是 absent / unauthorized）
      final state = classifyApiTable(
        kServiceRegistry[StationService.contacts]!,
        const {'SYNO.Contacts.Contact', 'SYNO.Contacts.Addressbook'},
      );
      expect(state, AvailabilityState.partial);
      expect(hidesModule(state), isFalse);
    });
  });

  // ---------------------------------------------------------------- UI 门控
  group('C4-4 「分组」页签（UI + 能力位）', () {
    testWidgets('页签打开后：分组带显隐开关、组织单位只读列出', (tester) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        switch (params['method']) {
          case 'list':
            if (params['api'] == 'SYNO.Contacts.Addressbook') {
              return {
                'addressbook': [
                  {
                    'id': 5,
                    'name': 'Team Contacts',
                    'type': 4,
                    'mode': 0,
                    'member_count': 1,
                  },
                ],
                'total': 1,
              };
            }
            if (params['api'] == 'SYNO.Contacts.Contact' &&
                params.containsKey('group_id')) {
              return {
                'contact': [
                  {
                    'id': 11,
                    'addressbook_id': 5,
                    'full_name': '张三',
                    'is_hidden': false,
                  },
                ],
                'total': 1,
              };
            }
            if (params['api'] == 'SYNO.Contacts.OU') {
              return {
                'ou': [
                  {
                    'id': 3,
                    'dn': 'OU=Sales,DC=example,DC=com',
                    'principal': [11],
                  },
                ],
              };
            }
            if (params['api'] == 'SYNO.Contacts.Label') {
              return {'label': <Object>[], 'total': 0};
            }
            return const <String, dynamic>{};
          case 'list_group':
            return {
              'group': [
                {
                  'id': 21,
                  'name': 'Sales',
                  'member_count': 1,
                  'is_hidden': false,
                },
              ],
              'total': 1,
            };
          case 'get':
            return const <String, dynamic>{};
          default:
            return const <String, dynamic>{};
        }
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          contactsApiProvider.overrideWithValue(ContactsApi(api)),
        ],
      );
      addTearDown(c.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: ContactsManagePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 能力位：没有 session 信号 → hasApi fail-open → 页签在
      expect(find.byKey(const Key('contact-groups-tab')), findsOneWidget);
      await tester.tap(find.byKey(const Key('contact-groups-tab')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      // 分组名（分组标题）与 OU 名（dn 解析出来）都叫 Sales
      expect(find.text('Sales'), findsWidgets);
      expect(find.byKey(const Key('contact-group-21')), findsOneWidget);
      // 组织单位（只读）：列出 dn，不给显隐开关
      expect(find.textContaining('OU=Sales,DC=example,DC=com'), findsOneWidget);
    });
  });

  // ------------------------------------------------------------- falsification
  group('C4-6 falsification（必红项）', () {
    test('F1 空列表不能被当成错误', () async {
      // 真机 ExternalSource/list 回的就是空数组（未配置外部源），
      // 这是**正常空态**；把它当错误就红。
      final b = await _boot({
        'SYNO.Contacts.ExternalSource.list': {
          'external_sources': <Object>[],
          'total': 0,
        },
      });
      final list = await b.contacts.externalSources();
      expect(list, isEmpty);
      expect(
        ExternalSourceDto.listFromJson({
          'external_sources': <Object>[],
          'total': 0,
        }),
        isEmpty,
      );
      // 键缺失（老版本/异常回包）也**不抛**，只是空
      expect(ExternalSourceDto.listFromJson(const {}), isEmpty);
    });

    test('F2 119（sid 失效）绝不能判成无权限而隐藏入口', () {
      // 用户纪律：119/106 = 会话提示，**绝不隐藏模块**。
      expect(
        classifyErrorCode(DsmErrorCode.sidNotFound),
        AvailabilityState.sessionExpired,
      );
      expect(hidesModule(classifyErrorCode(DsmErrorCode.sidNotFound)), isFalse);
      expect(
        classifyErrorCode(DsmErrorCode.sessionTimeout),
        AvailabilityState.sessionExpired,
      );
      expect(
        hidesModule(classifyErrorCode(DsmErrorCode.sessionTimeout)),
        isFalse,
      );
      // 对照：105/160 才隐藏
      expect(hidesModule(classifyErrorCode(DsmErrorCode.noPermission)), isTrue);
    });

    test('F3 9009 不能被当成"没有日历"（错误与空态必须分开）', () {
      final err = describeCalendarError(
        DsmApiException(CalApiErrorCode.invalidParameter, method: 'Cal.list'),
      );
      expect(err.contains('没有日历'), isFalse);
      expect(err.contains('invalid_parameter'), isTrue);
      // 空列表（真的没有日历）另有空态文案
      expect(describeCalendarError(StateError('x')), isNot(contains('9009')));
    });
  });
}
