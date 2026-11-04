// ignore_for_file: avoid_print
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
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
  final target = int.parse(args.first);
  for (final c in await chat.listChannels()) {
    final posts = await chat.listPosts(channelId: c.channelId, prevCount: 30);
    for (final p in posts) {
      final id = (p['post_id'] as num).toInt();
      final msg = '${p['message']}';
      if (id == target ||
          msg.startsWith('flt-p5og-') ||
          msg.startsWith('flt-url-probe') ||
          msg.startsWith('flt-og-probe')) {
        await chat.deletePost(id);
        print('删除 #${c.channelId} post=$id "$msg"');
      }
    }
  }
  exit(0);
}
