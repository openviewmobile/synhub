// ignore_for_file: avoid_print
// 删掉自己发过的测试消息（正文以 `flt-` 开头的那些）。
//   SYNO_NAS_* dart run tool/flt_post_purge.dart [--apply]
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
  final apply = args.contains('--apply');
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

  final ids = <int>{
    for (final c in await chat.listChannels(isJoined: '')) c.channelId,
    1, // #1 不在 list 里（public 默认频道），单独带上
  };
  var found = 0;
  for (final id in ids) {
    List<Map<String, dynamic>> posts;
    try {
      posts = await chat.listPosts(channelId: id, prevCount: 300);
    } catch (_) {
      continue;
    }
    for (final p in posts) {
      final msg = '${p['message']}';
      final postId = int.tryParse('${p['post_id']}') ?? 0;
      if (postId <= 0) continue;
      if (!msg.startsWith('flt-')) continue;
      found++;
      if (!apply) {
        print(
          '  [dry] #$id post=$postId ${msg.substring(0, msg.length.clamp(0, 60))}',
        );
        continue;
      }
      try {
        await chat.deletePost(postId);
        print('  删除 #$id post=$postId ✓');
      } catch (e) {
        // 提醒类消息（`Post.delete` 会 415）改用 Reminder/delete 收尾
        try {
          await chat.deleteReminder(postId);
          print('  取消提醒 #$id post=$postId ✓');
        } catch (e2) {
          print('  删除 #$id post=$postId 失败：$e → 提醒接口也失败：$e2');
        }
      }
    }
  }
  print('命中 $found 条${apply ? "（已处理）" : "（dry-run，加 --apply 才删）"}');
  await api.logout();
  exit(0);
}
