// 探针：`SYNO.Chat.Post / get_read_status` v6 在这台 NAS 上的行为。
// 顺便确认服务端设置 `allow_read_status` 关掉之后 API 还答不答应。
// ignore_for_file: avoid_print
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

  final settings = await chat.fetchServerSettings();
  print(
    'allow_read_status=${settings.allowReadStatus} '
    '(Post v6 支持=${chat.supports('SYNO.Chat.Post', 6)})',
  );

  final channels = await chat.listChannels();
  for (final c in channels) {
    final posts = await chat.listPosts(channelId: c.channelId, prevCount: 5);
    for (final p in posts) {
      final creator = p['creator_id'];
      final pid = p['post_id'];
      final type = p['type'];
      if (type != 'normal') continue;
      try {
        final r = await chat.fetchReadStatus((pid as num).toInt());
        print(
          '频道 #${c.channelId} post=$pid creator=$creator '
          'read=${r.readUsers} unread=${r.unreadUsers}',
        );
      } catch (e) {
        print('频道 #${c.channelId} post=$pid creator=$creator → 失败：$e');
      }
    }
  }
  exit(0);
}
