// 日历待办（`SYNO.Cal.Todo`）写操作取证：create / get / set / delete 的
// **真实参数名与回包字段**逐字打出来（DTO 照它写）。
//
// 为什么必须真机试：包内 `webapi/openapi.json` 把 `/task` 的 POST/PUT 属性写成了
// **回包形状**（`tzid`/`dtstart`/`notify_setting`），而官方 Web UI 的
// `_todoCreateRequiredParams` 发的是 `time_zone`/`start`/`notify` —— 两套名字，
// 只能拿 NAS 当权威，试完读回来看存进去的是什么。
//
// 结束时会删掉所有探针待办并复核列表复原。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Object? js(Object? v) => jsonEncode(v);

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'Calendar',
  );

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, Object?> params, {
    int version = 5,
  }) async {
    try {
      return await api.call(
        'SYNO.Cal.Todo',
        method,
        preferredVersion: version,
        params: params,
      );
    } catch (e) {
      print('  !! $method 抛异常: $e');
      return {'__error__': '$e'};
    }
  }

  void dump(String title, Object? v) {
    print('--- $title');
    print(const JsonEncoder.withIndent('  ').convert(v));
  }

  // 1) 待办日历（`cal_type:"todo"`）
  final todoCals = await api.call(
    'SYNO.Cal.Cal',
    'list',
    preferredVersion: 5,
    params: {'cal_type': 'todo'},
  );
  dump('Cal/list {cal_type:"todo"}', todoCals);
  final todoList = (todoCals['list'] as List? ?? const []);
  final calId = todoList.isEmpty
      ? '/${Platform.environment['SYNO_ACCOUNT']}/home_todo/'
      : '${(todoList.first as Map)['cal_id']}';
  final orgCalId = todoList.isEmpty
      ? calId
      : '${(todoList.first as Map)['original_cal_id'] ?? calId}';
  print('todo cal_id=$calId original_cal_id=$orgCalId');

  // 2) 列表（回包字段就是 DTO 的依据）
  dump(
    'Todo/list (baseline)',
    await call('list', {
      'cal_id_list': js([calId]),
      'filter_complete': 'no',
    }),
  );

  final tag = 'probe-todo-${DateTime.now().millisecondsSinceEpoch}';
  final created = <String>[];

  // 3) create：**规范里的名字**（tzid/dtstart/notify_setting/from_syno_app_url）
  final specResp = await call('create', {
    'original_cal_id': js(orgCalId),
    'summary': js('$tag-spec'),
    'description': js('规范命名探针'),
    'has_start_time': 'false',
    'has_end_time': 'true',
    'percent_complete': '0',
    'is_all_day': 'true',
    'tzid': js(''),
    'due': '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400}',
    'notify_setting': js(const []),
    'from_syno_app_url': js(const {}),
  });
  dump('Todo/create（规范名 tzid/dtstart/notify_setting）', specResp);
  if (specResp['evt_id'] != null) created.add('${specResp['evt_id']}');

  // 4) create：**Web UI 里的名字**（time_zone/start/notify/synoAppURL）
  final uiResp = await call('create', {
    'original_cal_id': js(orgCalId),
    'summary': js('$tag-ui'),
    'description': js('WebUI 命名探针'),
    'has_start_time': 'false',
    'has_end_time': 'true',
    'percent_complete': '0',
    'is_all_day': 'true',
    'time_zone': js(''),
    'due': '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2 * 86400}',
    'notify': js(const []),
    'syno_app_url': js(const {}),
  });
  dump('Todo/create（WebUI 名 time_zone/notify/syno_app_url）', uiResp);
  if (uiResp['evt_id'] != null) created.add('${uiResp['evt_id']}');

  // 5) 读回：字段名与值时 DTO 的权威依据
  dump(
    'Todo/get（规范名创建的那条）',
    await call('get', {'evt_id': '${specResp['evt_id'] ?? ''}'}),
  );
  dump(
    'Todo/list（创建后）',
    await call('list', {
      'cal_id_list': js([calId]),
      'filter_complete': 'all',
    }),
  );

  // 6) set：标记完成（percent_complete=100 + dav_etag 乐观锁）
  final etag = '${specResp['dav_etag'] ?? ''}';
  dump(
    'Todo/set（勾完成，规范名）',
    await call('set', {
      'evt_id': '${specResp['evt_id'] ?? ''}',
      'original_cal_id': js(orgCalId),
      'dav_etag': js(etag),
      'summary': js('$tag-spec-done'),
      'description': js('规范命名探针'),
      'has_start_time': 'false',
      'has_end_time': 'true',
      'percent_complete': '100',
      'priority_order': '0',
      'is_all_day': 'true',
      'tzid': js(''),
      'due': '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400}',
      'notify_setting': js(const []),
    }),
  );

  // 7) set：Web UI 命名
  dump(
    'Todo/set（WebUI 名）',
    await call('set', {
      'evt_id': '${uiResp['evt_id'] ?? ''}',
      'original_cal_id': js(orgCalId),
      'dav_etag': js('${uiResp['dav_etag'] ?? ''}'),
      'summary': js('$tag-ui-done'),
      'description': js('WebUI 命名探针'),
      'has_start_time': 'false',
      'has_end_time': 'true',
      'percent_complete': '100',
      'priority_order': '0',
      'time_zone': js(''),
      'notify': js(const []),
    }),
  );

  dump(
    'Todo/list（改完）',
    await call('list', {
      'cal_id_list': js([calId]),
      'filter_complete': 'all',
    }),
  );

  // 8) delete：`evt_id` 裸串（官方 Web UI 就是裸串）
  for (final id in created) {
    dump('Todo/delete id=$id', await call('delete', {'evt_id': id}));
  }

  dump(
    'Todo/list（清理后，应恢复基线）',
    await call('list', {
      'cal_id_list': js([calId]),
      'filter_complete': 'all',
    }),
  );
}
