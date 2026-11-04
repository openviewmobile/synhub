// r415 只读探针：④「音频 · 投屏」（RemotePlayer 远程播放器/DLNA 渲染器）。
//
//    set -a; . ~/.synhub-nas.env; set +a
//    dart run tool/probe_r415_cast.dart
//
// 目的：把 r386/r403 那句"**本机无 DLNA 渲染器**"从**推断**改成**读到什么** ——
// 投屏目标列表是 **NAS 侧**发现的（`SYNO.AudioStation.RemotePlayer.list`，
// 见 `lib/src/data/audio_station.dart:803` / `audio_remote_page.dart`），
// 所以"有没有可投的设备"必须问 NAS，而不是看手机的局域网。
//
// 本探针**只打只读方法**（`Info.getinfo` / `RemotePlayer.list` / `*getstatus`），
// 不碰 `updateplaylist`/`control`/`play` 这类写动词，也不动 NAS 上任何数据。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// 环境变量取两套命名（老探针用 `SYNO_*`，新探针用 `SYNO_NAS_*`）
String env(String a, String b) {
  final v = Platform.environment[a] ?? Platform.environment[b];
  if (v == null || v.isEmpty) {
    stderr.writeln('缺少环境变量 $a（或 $b）—— 请先 `. ~/.synhub-nas.env`');
    exit(2);
  }
  return v;
}

Future<DsmWebApi> login() async {
  final api = DsmWebApi(
    DirectTransport.url(
      env('SYNO_NAS_URL', 'SYNO_URL'),
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: env('SYNO_NAS_ACCOUNT', 'SYNO_ACCOUNT'),
    password: env('SYNO_NAS_PASSWORD', 'SYNO_PASSWORD'),
    session: 'AudioStation',
  );
  return api;
}

/// 打一个只读方法并打印**原始回包**（成功与失败都打，不做任何"解释"）
Future<void> raw(
  DsmWebApi api,
  String name,
  String method, {
  required int version,
  Map<String, dynamic>? params,
}) async {
  stdout.write('--- $name::$method v$version\n');
  try {
    final data = await api.call(
      name,
      method,
      preferredVersion: version,
      params: params ?? const <String, dynamic>{},
    );
    final s = const JsonEncoder.withIndent('  ').convert(data);
    print('    OK  data = ${s.length > 4000 ? '${s.substring(0, 4000)}…(截断)' : s}');
  } catch (e) {
    print('    ERR $e');
  }
}

Future<void> main() async {
  final api = await login();
  print('== NAS 只读探针（地址已脱敏）');
  for (final v in const [3, 2, 1]) {
    await raw(api, 'SYNO.AudioStation.RemotePlayer', 'list', version: v);
  }
  for (final v in const [2, 1]) {
    await raw(
      api,
      'SYNO.AudioStation.RemotePlayerStatus',
      'getstatus',
      version: v,
    );
  }
  for (final v in const [3, 2, 1]) {
    await raw(api, 'SYNO.AudioStation.RemotePlayer', 'getstatus', version: v);
  }
  await raw(api, 'SYNO.AudioStation.Info', 'getinfo', version: 1);
  exit(0);
}
