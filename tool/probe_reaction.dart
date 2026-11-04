// 探 `Post.Reaction/set` 的 `sticker_name` 到底要不要再 JSON 编码一次
// （APK 的 AccountManager 用 gson.toJson 包了一层引号）。
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
  final created = await chat.createPost(
    channelId: 1,
    message: 'flt-probe-reaction',
    connId: 'probe',
  );
  final pid = (created['post_id'] as num).toInt();
  print('post=$pid');
  for (final value in ['thumbsup', '"thumbsup"']) {
    try {
      await api.call(
        'SYNO.Chat.Post.Reaction',
        'set',
        preferredVersion: 1,
        params: {'post_id': '$pid', 'sticker_name': value},
      );
      print('set sticker_name=$value → OK');
    } catch (e) {
      print('set sticker_name=$value → ERR $e');
    }
  }
  try {
    final d = await chat.listPosts(
      channelId: 1,
      prevCount: 3,
      has: const ['reactions'],
    );
    final p = d.firstWhere((x) => (x['post_id'] as num).toInt() == pid);
    print('reactions=${p['reactions']}');
  } catch (e) {
    print('list ERR $e');
  }
  await chat.deletePost(pid);
  print('已清理');
}
