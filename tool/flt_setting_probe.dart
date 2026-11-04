// 探针：SYNO.Chat.Admin.Setting/get 的真实响应（版本 + 字段）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_NAS_PASSWORD']!;
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'Chat');

  for (final e in (api.apiTable ?? {}).entries) {
    if (e.key.toLowerCase().contains('setting')) {
      print(
        '${e.key} path=${e.value.path} v${e.value.minVersion}-${e.value.maxVersion}',
      );
    }
  }
  // list_editable：频道维度（不带 thread_id）与话题维度都试一下
  try {
    final chans = await api.call(
      'SYNO.Chat.Channel',
      'list',
      preferredVersion: 5,
    );
    final list = (chans['channels'] as List?) ?? const [];
    for (final ch in list.take(3)) {
      final cid = (ch as Map)['channel_id'];
      if (cid is! num || cid <= 0) continue;
      try {
        final d = await api.call(
          'SYNO.Chat.Post',
          'list_editable',
          preferredVersion: 1,
          params: {'channel_id': '$cid'},
        );
        print('list_editable channel=$cid -> $d');
      } catch (e) {
        print('list_editable channel=$cid 失败：$e');
      }
    }
  } catch (e) {
    print('channel/list 失败：$e');
  }

  for (final v in [4, 3, 1]) {
    try {
      final data = await api.call(
        'SYNO.Chat.Admin.Setting',
        'get',
        preferredVersion: v,
      );
      print('--- v$v 成功');
      print(const JsonEncoder.withIndent('  ').convert(data));
      break;
    } catch (e) {
      print('--- v$v 失败：$e');
    }
  }
  exit(0);
}
