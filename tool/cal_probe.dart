// 日历（Synology Calendar 3.0.3-21434）参数取证探针。
//
// 参数名不再靠猜：从**包内 Web UI**（`ui/synocalendar-app.js` / bundle）里抠出来的
// 官方调用形态是 ——
//   `Cal/list`   v5  params {cal_type: "event"}
//   `Event/list` v5/6 params {cal_id_list:[…], start: epoch秒, end: epoch秒,
//                             (?limit, ?keyword, ?evt_color_list)}
//   `Setting/get` v1（注意是 **v1**，不是 v5）
// 见 docs/api-server-authoritative.md §18。
//
// 用法：SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/cal_probe.dart
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

  // 0) 这个 NAS 上 Calendar 到底装没装 / 有哪些版本
  final table = api.apiTable ?? const {};
  final calApis = table.keys.where((k) => k.startsWith('SYNO.Cal.')).toList()
    ..sort();
  print('① SYNO.Cal.* 共 ${calApis.length} 个');
  for (final k in calApis) {
    print('   $k  v${table[k]!.minVersion}..${table[k]!.maxVersion}');
  }
  if (calApis.isEmpty) {
    print('   ⚠️ API.Info 里没有 SYNO.Cal.* → Calendar 包未安装/未启用');
    await api.logout();
    exit(0);
  }

  Future<void> show(
    String api_,
    String method,
    int v,
    Map<String, dynamic> p,
  ) async {
    try {
      final raw = await api.call(api_, method, preferredVersion: v, params: p);
      print('   ✔ $api_.$method v$v → $raw');
    } catch (e) {
      print('   ✘ $api_.$method v$v → $e');
    }
  }

  print('② Cal/list（v5 {cal_type:event} / v1 / 空参）');
  await show('SYNO.Cal.Cal', 'list', 5, {'cal_type': 'event'});
  await show('SYNO.Cal.Cal', 'list', 1, {'cal_type': 'event'});
  await show('SYNO.Cal.Cal', 'list', 5, const {});

  print('③ Setting/get（v1 / v5）');
  await show('SYNO.Cal.Setting', 'get', 1, const {});
  await show('SYNO.Cal.Setting', 'get', 5, const {});

  // 真正的 cal_id 要从 Cal/list 里取：/demo_user/home/
  final cals = await api.call(
    'SYNO.Cal.Cal',
    'list',
    preferredVersion: 5,
    params: {'cal_type': 'event'},
  );
  final list = (cals['list'] as List?) ?? const [];
  final ids = [for (final c in list) '${(c as Map)['cal_id']}'];
  print('   cal_ids=$ids');

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final window = {'start': '$now', 'end': '${now + 86400 * 60}'};

  print('④ Event/list：cal_id_list 的三种编码 × 带/不带 start+end');
  for (final enc in ['json-array', 'joined', 'single']) {
    final v = switch (enc) {
      'json-array' => jsonEncode(ids),
      'joined' => ids.join(','),
      _ => ids.isEmpty ? '' : ids.first,
    };
    await show('SYNO.Cal.Event', 'list', 6, {'cal_id_list': v, ...window});
  }
  print('   —— 省略 cal_id_list，只给 start/end：');
  await show('SYNO.Cal.Event', 'list', 6, window);
  await show('SYNO.Cal.Event', 'list', 5, window);
  await show('SYNO.Cal.Event', 'list', 4, window);

  print('⑤ Todo/list v6/v5/v1（cal_id_list + filter_complete）');
  for (final v in [6, 5, 1]) {
    await show('SYNO.Cal.Todo', 'list', v, {
      'cal_id_list': jsonEncode(ids),
      'filter_complete': 'no',
    });
  }
  print('⑥ Timezone/list');
  await show('SYNO.Cal.Timezone', 'list', 5, const {});

  await api.logout();
  exit(0);
}
