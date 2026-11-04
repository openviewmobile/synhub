// 探针：把真实频道里的 `type=system` 消息连同 `props.system` 原样打出来，
// 用来核对系统消息文案映射（事件名 / extra / target_user_ids / creator）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
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
    account: Platform.environment['SYNO_NAS_ACCOUNT']!,
    password: Platform.environment['SYNO_NAS_PASSWORD']!,
    session: 'Chat',
  );
  final chat = ChatApi(api);

  final channels = await chat.listChannels();
  final types = <String, int>{};
  final events = <String, String>{};
  for (final c in channels) {
    var posts = await chat.listPosts(channelId: c.channelId, prevCount: 50);
    if (posts.length >= 50) {
      posts = await chat.listPosts(channelId: c.channelId, prevCount: 200);
    }
    for (final p in posts.take(4)) {
      final t = '${p['type']}';
      types[t] = (types[t] ?? 0) + 1;
      if (t != 'system') continue;
      print('RAW ${jsonEncode(p)}');
      final props = p['props'] ?? p['prop'];
      final sys = (props is Map ? props['system'] : null);
      final event = sys is Map ? '${sys['event']}' : '(no system props)';
      if (!events.containsKey(event)) {
        events[event] = 'props.system=${jsonEncode(sys)}';
      }
    }
  }
  print('类型分布=$types');
  print('系统事件 ${events.length} 类：');
  events.forEach((k, v) {
    print('  • $k');
    print('    $v');
  });
  exit(0);
}
