// r445 只读探针：`RemotePlayer/list` 的**参数**到底要不要（官方 Web 前端逐字给了
// `{type:"all", additional:"subplayer_list"}`，见 AudioStation 7.2.1-6006 包的
// `app/audio-core.js`）。只读，不碰任何写动词。
// ignore_for_file: avoid_print
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(DirectTransport.url(Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true)));
  await api.discover();
  await api.login(account: Platform.environment['SYNO_NAS_ACCOUNT']!,
      password: Platform.environment['SYNO_NAS_PASSWORD']!, session: 'AudioStation');
  final cases = <String, Map<String, dynamic>>{
    'A 无参（我们现在的实现）': {},
    'B type=all': {'type': 'all'},
    'C additional=subplayer_list': {'additional': 'subplayer_list'},
    'D type=all + additional=subplayer_list（官方 Web 逐字）': {
      'type': 'all', 'additional': 'subplayer_list'},
    'E type=upnp': {'type': 'upnp'},
  };
  for (final e in cases.entries) {
    try {
      final d = await api.call('SYNO.AudioStation.RemotePlayer', 'list',
          preferredVersion: 3, params: e.value);
      final p = d['players'];
      print('--- ${e.key} ⇒ keys=${d.keys.toList()} players=${p is List ? p.length : p}');
      if (p is List && p.isNotEmpty) {
        for (final x in p) print('      $x');
      }
    } catch (err) {
      print('--- ${e.key} ⇒ ERR $err');
    }
  }
}
