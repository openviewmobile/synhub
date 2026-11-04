// r398 只读探针：`SYNO.AudioStation.Pin.list` 的**逐字原始回包**。
//
// 用途：真机验收时给「收藏」页做**独立于界面的服务端通道**——
// 动作前后各读一次，用服务端的记数说话，而不是只信 UI。
//
// 只读：登录 + `Pin.list`，**不**调用 `pin`/`unpin`/`reorder` 任何写方法。
//
// 运行：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/probe_r398_pins.dart [tag]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  final tag = args.isEmpty ? 'r398' : args.first;
  if (base == null || account == null || password == null) {
    print('需要 SYNO_NAS_URL / SYNO_ACCOUNT / SYNO_PASSWORD');
    exit(2);
  }
  final api = DsmWebApi(
    DirectTransport.url(base, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');

  final table = api.apiTable ?? const {};
  final e = table['SYNO.AudioStation.Pin'];
  print(
    '[$tag] SYNO.AudioStation.Pin → '
    '${e == null ? "（该 NAS 没这个 api）" : "v${e.minVersion}-${e.maxVersion}"}'
    ' path=${e?.path ?? "-"}',
  );

  // list：官方"一次全取"形态（offset 0 / limit -1），与我们数据层逐字一致。
  final raw = await api.call(
    'SYNO.AudioStation.Pin',
    'list',
    params: {'offset': '0', 'limit': '-1'},
  );
  print('[$tag] raw=${jsonEncode(raw)}');
  {
    final items = raw['items'];
    print(
      '[$tag] items=${items is List ? items.length : "非 List（${items.runtimeType}）"} '
      'total=${raw['total']} rootKeys=${(raw.keys.toList()..sort()).join(",")}',
    );
    if (items is List) {
      for (var i = 0; i < items.length; i++) {
        print('[$tag] item[$i]=${jsonEncode(items[i])}');
      }
    }
  }
  await api.logout(session: 'AudioStation');
  exit(0);
}
