// 标量参数编码取证：raw（官方 Web UI 的做法）vs JSON 引号串，哪个被服务端接受。
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
  final calId = '/demo_user/home/';
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final made = <String>[];
  for (final style in ['raw', 'json']) {
    String enc(String s) => style == 'raw' ? s : jsonEncode(s);
    try {
      final r = await api.call(
        'SYNO.Cal.Event',
        'create',
        preferredVersion: 6,
        params: {
          'cal_id': enc(calId),
          'original_cal_id': enc(calId),
          'summary': enc('enc-$style'),
          'is_all_day': 'false',
          'tz_id': enc('Asia/Shanghai'),
          'dtstart': '${now + 3600}',
          'dtend': '${now + 7200}',
          'is_repeat_evt': 'false',
          'color': enc(''),
          'description': enc('d'),
          'participant': jsonEncode(const []),
          'notify_setting': jsonEncode(const []),
        },
      );
      made.add('${r['evt_id']}');
      print(
        '$style ✔ summary=${r['summary']} cal_id=${r['cal_id']} evt=${r['evt_id']}',
      );
    } catch (e) {
      print('$style ✘ $e');
    }
  }
  for (final id in made) {
    await api.call(
      'SYNO.Cal.Event',
      'delete',
      preferredVersion: 6,
      params: {'evt_id': id},
    );
  }
  print('清掉 ${made.length} 条');
  await api.logout();
  exit(0);
}
