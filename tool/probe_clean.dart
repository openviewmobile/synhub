// 把所有 `flt-` 前缀的测试消息（含话题回复）删干净。
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

// ignore_for_file: avoid_print

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      const String.fromEnvironment('SYNO_NAS_URL'),
      dio: DioFactory.create(),
    ),
  );
  await api.discover();
  await api.login(
    account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
    password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
    session: 'Chat',
  );
  final chat = ChatApi(api);
  final channels = await chat.listChannels();
  var removed = 0;
  for (final c in channels) {
    final id = c.channelId;
    for (final has in [
      const ['thread'],
      const ['thread', 'file_props'],
    ]) {
      final posts = await chat.listPosts(
        channelId: id,
        prevCount: 100,
        nextCount: 0,
        has: has,
      );
      for (final p in posts) {
        final msg = '${p['message'] ?? ''}';
        if (msg.startsWith('flt-')) {
          await chat.deletePost((p['post_id'] as num).toInt());
          removed++;
          print('删除 #$id post=${p['post_id']} $msg');
        }
      }
    }
  }
  print('清理完成，共删除 $removed 条');
}
