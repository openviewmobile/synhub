// 日历事件全链路取证：`Cal/list` → `Event/create` → `Event/list`/`Event/get`
// → `Event/delete`，每个回包的**原始 JSON** 都打出来（DTO 字段照它写）。
//
// 参数形态来自包内 Web UI（见 docs/api-server-authoritative.md §18）：
//   create 形如 {cal_id, original_cal_id, summary, is_all_day, tz_id, dtstart,
//                dtend, is_repeat_evt, color, description, participant, notify_setting}
// 结束时删干净。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
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

  final cals = await api.call(
    'SYNO.Cal.Cal',
    'list',
    preferredVersion: 5,
    params: {'cal_type': 'event'},
  );
  final first = (cals['list'] as List).first as Map;
  final calId = '${first['cal_id']}';
  final orgCalId = '${first['original_cal_id']}';
  print('cal_id=$calId original_cal_id=$orgCalId');

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<int> purgeProbe() async {
    var n = 0;
    try {
      final all = await api.call(
        'SYNO.Cal.Event',
        'list',
        preferredVersion: 6,
        params: {
          'cal_id_list': jsonEncode([calId]),
          'start': '${now - 86400 * 30}',
          'end': '${now + 86400 * 30}',
        },
      );
      for (final e in (all['list'] as List? ?? const [])) {
        if ('${(e as Map)['summary']}' == 'probe-cal') {
          await api.call(
            'SYNO.Cal.Event',
            'delete',
            preferredVersion: 6,
            params: {'evt_id': '${e['evt_id']}'},
          );
          n++;
        }
      }
    } catch (e) {
      print('purge 失败：$e');
    }
    return n;
  }

  print('清残留 ${await purgeProbe()} 条');
  final start = now + 3600;
  final end = start + 3600;
  final created = await api.call(
    'SYNO.Cal.Event',
    'create',
    preferredVersion: 6,
    params: {
      'cal_id': jsonEncode(calId),
      'original_cal_id': jsonEncode(orgCalId),
      'summary': jsonEncode('probe-cal'),
      'is_all_day': 'false',
      'tz_id': jsonEncode('Asia/Shanghai'),
      'dtstart': '$start',
      'dtend': '$end',
      'is_repeat_evt': 'false',
      'color': jsonEncode(''),
      'description': jsonEncode('probe desc'),
      'participant': jsonEncode(const []),
      'notify_setting': jsonEncode(const []),
    },
  );
  print('① create → $created');
  final evtId = created['evt_id'] ?? created['evtId'] ?? created['id'];
  print('   evt_id=$evtId');

  final listed = await api.call(
    'SYNO.Cal.Event',
    'list',
    preferredVersion: 6,
    params: {
      'cal_id_list': jsonEncode([calId]),
      'start': '$now',
      'end': '${now + 86400 * 7}',
    },
  );
  print('② list → ${jsonEncode(listed)}');

  if (evtId != null) {
    print('③ Event/get 各种形态：');
    for (final probe in [
      ('v6 evt_id 裸串', 6, {'evt_id': '$evtId'}),
      ('v6 evt_id JSON 串', 6, {'evt_id': jsonEncode('$evtId')}),
      ('v5 evt_id 裸串', 5, {'evt_id': '$evtId'}),
      (
        'v6 evt_id + cal_id',
        6,
        {'evt_id': '$evtId', 'cal_id': jsonEncode(calId)},
      ),
      (
        'v6 evt_id + dav_etag',
        6,
        {'evt_id': '$evtId', 'dav_etag': '${created['dav_etag']}'},
      ),
      (
        'v6 ical_uid + cal_id',
        6,
        {
          'ical_uid': jsonEncode('${created['ical_uid']}'),
          'cal_id': jsonEncode(calId),
        },
      ),
    ]) {
      final (label, v, p) = probe;
      try {
        final r = await api.call(
          'SYNO.Cal.Event',
          'get',
          preferredVersion: v,
          params: p,
        );
        print('   ✔ $label → ${jsonEncode(r)}');
      } catch (e) {
        print('   ✘ $label → $e');
      }
    }
  }

  print('④ 清场：${await purgeProbe()} 条');
  final left = await api.call(
    'SYNO.Cal.Event',
    'list',
    preferredVersion: 6,
    params: {
      'cal_id_list': jsonEncode([calId]),
      'start': '${now - 86400 * 30}',
      'end': '${now + 86400 * 30}',
    },
  );
  print('⑤ 清空后 list → ${jsonEncode(left)}');

  await api.logout();
  exit(0);
}
