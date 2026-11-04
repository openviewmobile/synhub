// 只读探针：列出日历里当前的事件（真机双向验证用，**不写任何东西**）。
// 用法：SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/cal_list_probe.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/calendar_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

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
  final cal = CalendarApi(api);
  final cals = await cal.listCalendars();
  for (final c in cals) {
    print('日历 ${c.displayName} (${c.calId}) ${c.privilege} ${c.color}');
  }
  final now = DateTime.now();
  final events = await cal.listEvents(
    calendarIds: [for (final c in cals) c.calId],
    from: now.subtract(const Duration(days: 30)),
    to: now.add(const Duration(days: 60)),
  );
  print('事件 ${events.length} 条');
  for (final e in events) {
    print(
      '  - #${e.evtId} ${e.summary} '
      '${e.dtstartString}~${e.dtendString} allDay=${e.isAllDay} '
      'tz=${e.tzId} desc="${e.description}"',
    );
  }
  final todos = await cal.listTodos(
    calendarIds: [for (final c in cals) c.calId],
  );
  print('待办 ${todos.length} 条');
  for (final t in todos) {
    print('  - #${t.evtId} ${t.summary} done=${t.done}');
  }
  await api.logout();
  exit(0);
}
