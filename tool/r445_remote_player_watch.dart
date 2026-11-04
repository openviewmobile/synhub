// r445 一次性观察探针：renderer 上线后，NAS 侧的 `RemotePlayer.list` 多久才认它。
// 只读（`Info.getinfo` / `RemotePlayer.list` / `getstatus`），不碰任何写动词。
//   set -a; . ~/.synhub-nas.env; set +a
//   dart run tool/r445_remote_player_watch.dart [轮数] [间隔秒]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

String env(String a) {
  final v = Platform.environment[a];
  if (v == null || v.isEmpty) {
    stderr.writeln('缺少环境变量 $a —— 请先 `. ~/.synhub-nas.env`');
    exit(2);
  }
  return v;
}

Future<void> main(List<String> args) async {
  final rounds = args.isNotEmpty ? int.parse(args[0]) : 8;
  final gap = args.length > 1 ? int.parse(args[1]) : 15;
  final api = DsmWebApi(
    DirectTransport.url(
      env('SYNO_NAS_URL'),
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: env('SYNO_NAS_ACCOUNT'),
    password: env('SYNO_NAS_PASSWORD'),
    session: 'AudioStation',
  );
  print('== 登录成功，开始轮询 $rounds 轮 × ${gap}s');
  for (var i = 1; i <= rounds; i++) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    try {
      final d = await api.call(
        'SYNO.AudioStation.RemotePlayer',
        'list',
        preferredVersion: 3,
      );
      final players = d['players'];
      final n = players is List ? players.length : -1;
      print('[$t] #$i list v3 ⇒ players=$n  ${n > 0 ? jsonEncode(players) : '(根键 ${d.keys.toList()})'}');
    } catch (e) {
      print('[$t] #$i list v3 ⇒ ERR $e');
    }
    if (i < rounds) await Future<void>.delayed(Duration(seconds: gap));
  }
  print('== 轮询结束');
}
