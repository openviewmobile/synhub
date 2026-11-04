// Phase 6 剩余项探针：频道 hashtag / 归档列表 / 归档-关闭频道 / 帖子加删标签。
import 'dart:convert';
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
  final sess = await api.login(
    account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
    password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
    session: 'Chat',
  );
  final chat = ChatApi(api);
  final ts = DateTime.now().millisecondsSinceEpoch;
  final created = <int>[];
  String j(Object v) => jsonEncode(v);

  Future<void> tryCall(
    String label,
    String name,
    String method,
    Map<String, dynamic> params, {
    int version = 1,
  }) async {
    try {
      final r = await api.call(
        name,
        method,
        preferredVersion: version,
        params: params,
      );
      final s = jsonEncode(r);
      print('$label → ${s.length > 600 ? '${s.substring(0, 600)}…' : s}');
    } catch (e) {
      print('$label → ERR $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  try {
    print('== 服务端对这些 API 的版本支持 ==');
    for (final n in [
      'SYNO.Chat.Post.Hashtag',
      'SYNO.Chat.Channel.Hashtag',
      'SYNO.Chat.Archive',
      'SYNO.Chat.Channel',
      'SYNO.Chat.Slash.Command',
      'SYNO.Chat.Bot',
    ]) {
      print('  $n → ${api.apiTable?[n]}');
    }

    print('\n== 频道 hashtag 列表 ==');
    await tryCall(
      'Channel.Hashtag/list #1',
      'SYNO.Chat.Channel.Hashtag',
      'list',
      {'channel_id': '1'},
    );

    print('\n== 归档列表 ==');
    for (final t in ['encrypted', 'archived', 'all', 'normal']) {
      await tryCall('Archive/list type=$t', 'SYNO.Chat.Archive', 'list', {
        'type': j(t),
      });
    }

    print('\n== 给帖子加标签 / 删标签 ==');
    final p = await chat.createPost(
      channelId: 1,
      connId: sess.sid,
      message: 'flt-p6b-$ts 标签测试',
    );
    final pid = (p['post_id'] as num).toInt();
    created.add(pid);
    print('消息 #$pid');
    await Future<void>.delayed(const Duration(seconds: 4));
    await tryCall('Post.Hashtag/set', 'SYNO.Chat.Post.Hashtag', 'set', {
      'post_id': '$pid',
      'hashtag': j('flt-tag-$ts'),
    });
    await tryCall(
      'Channel.Hashtag/list(加完)',
      'SYNO.Chat.Channel.Hashtag',
      'list',
      {'channel_id': '1'},
    );
    await tryCall('Post/list 看 hashtags', 'SYNO.Chat.Post', 'list', {
      'channel_id': '1',
      'prev_count': '3',
      'next_count': '0',
    });
    await tryCall('Post.Hashtag/delete', 'SYNO.Chat.Post.Hashtag', 'delete', {
      'post_id': '$pid',
      'hashtag': j('flt-tag-$ts'),
    });
  } finally {
    for (final id in created) {
      try {
        await chat.deletePost(id);
      } catch (_) {}
    }
    print('\n清理 ${created.length}');
  }
}
