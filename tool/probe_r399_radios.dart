// r399 只读探针：`SYNO.AudioStation.Radio.list` 的**逐字原始回包**。
//
// 用途：真机验收「网络电台」页的自定义电台写动词（`Radio/add` / `Radio.updateradios`）时，
// 做**独立于界面的服务端通道** —— 动作前后各读一次，用服务端列表说话。
//
// 只读：登录 + `Radio.list`（root / `UserDefined` / `Favorite` 三档），
// **不**调用 `add`/`updateradios`/`search` 任何写方法。
//
// 运行：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/probe_r399_radios.dart [tag]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
  final base = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  final tag = args.isEmpty ? 'r399' : args.first;
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
  final e = table['SYNO.AudioStation.Radio'];
  print(
    '[$tag] SYNO.AudioStation.Radio → '
    '${e == null ? "（该 NAS 没这个 api）" : "v${e.minVersion}-${e.maxVersion}"}'
    ' path=${e?.path ?? "-"}',
  );

  // 三档：root（容器）/ UserDefined / Favorite。
  // 官方"一次全取"形态：offset 0 / limit -1（与数据层 listRadios 一致）。
  for (final container in const [null, 'UserDefined', 'Favorite']) {
    final params = <String, dynamic>{'offset': '0', 'limit': '-1'};
    if (container != null) params['container'] = container;
    final label = container ?? 'root';
    try {
      final raw = await api.call(
        'SYNO.AudioStation.Radio',
        'list',
        preferredVersion: 2,
        params: params,
      );
      print('[$tag][$label] raw=${jsonEncode(raw)}');
      final radios = raw['radios'];
      print(
        '[$tag][$label] radios=${radios is List ? radios.length : "非 List（${radios.runtimeType}）"} '
        'total=${raw['total']} rootKeys=${(raw.keys.toList()..sort()).join(",")}',
      );
      if (radios is List) {
        for (var i = 0; i < radios.length; i++) {
          print('[$tag][$label] radio[$i]=${jsonEncode(radios[i])}');
        }
      }
    } catch (err) {
      print('[$tag][$label] ✘ ${err.runtimeType}: $err');
    }
  }
  await api.logout(session: 'AudioStation');
  exit(0);
}
