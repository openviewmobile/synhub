// r445 只读探针：`SYNO.AudioStation.Info::getinfo` v1..v6 全文（官方 Web 把这坨当
// `SessionData`，里面有 `settings.disable_upnp` 与 `privilege.upnp_browse`）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(DirectTransport.url(Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true)));
  await api.discover();
  await api.login(account: Platform.environment['SYNO_NAS_ACCOUNT']!,
      password: Platform.environment['SYNO_NAS_PASSWORD']!, session: 'AudioStation');
  for (var v = 2; v <= 6; v += 4) {
    try {
      final d = await api.call('SYNO.AudioStation.Info', 'getinfo', preferredVersion: v);
      final j = jsonEncode(d);
      print('--- v$v keys=${d.keys.toList()} len=${j.length}');
      if (v >= 6) {
        print('    settings=${jsonEncode(d['settings'])}');
        print('    privilege=${jsonEncode(d['privilege'])}');
        print('    remote_controller=${jsonEncode(d['remote_controller'])}');
        print('    same_subnet=${d['same_subnet']}');
      }
    } catch (e) {
      print('--- v$v ERR $e');
    }
  }
}
