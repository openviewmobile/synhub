// 探针：`Channel/list` 里各频道 preferences 的真实形状（hideAtSideBar 要用
// notification_mobile / by_admin_console 的判断）。
// 用法：SYNO_NAS_* dart run tool/probe_channel_prefs.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final transport = DirectTransport.url(
    Platform.environment['SYNO_NAS_URL']!,
    dio: DioFactory.create(allowSelfSigned: true),
  );
  final api = DsmWebApi(transport);
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_NAS_ACCOUNT']!,
    password: Platform.environment['SYNO_NAS_PASSWORD']!,
    session: 'Chat',
  );
  final chat = ChatApi(api);
  final v = chat.negotiate('SYNO.Chat.Channel', const [5, 4, 3, 2, 1]);
  final data = await api.call(
    'SYNO.Chat.Channel',
    'list',
    preferredVersion: v,
    params: {},
  );
  final list = (data['channels'] as List).cast<Map>();
  for (final c in list) {
    final p = c['preferences'];
    print(
      '#${c['channel_id']} type=${c['type']} name="${c['name']}" '
      'prefs=${jsonEncode(p)}',
    );
  }
  print('---- 服务端默认 notify_type ----');
  final s = await api.call(
    'SYNO.Chat.Admin.Setting',
    'get',
    preferredVersion: chat.negotiate('SYNO.Chat.Admin.Setting', const [
      3,
      2,
      1,
    ]),
    params: {},
  );
  print(
    'notify_type=${(s['settings'] as Map?)?['notify_type']} '
    'raw=${jsonEncode(s['settings'] ?? s)}',
  );
  exit(0);
}
