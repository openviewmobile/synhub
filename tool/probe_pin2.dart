// 摸清「消息置顶」到底怎么落库（`Post/pin` v1 vs `Post/stick` v2）。
//
// 疑点：真机 phase4 用例里 `ctrl.setPin()` 返回 true（没报 407），但等不到
// `post.pin` 广播把 `is_sticky` 改掉。要分清是"服务端没广播"还是
// "这台 NAS 压根没开置顶（接口不报错但也不生效）"，只能直接问服务端：
//
//   建一条测试消息 → `Post/pin` → `Post/list` 看 `is_sticky`/`last_pin_at`
//   → `Post/list` 带 `has=['pin']` 看它进没进置顶列表
//   → `Post/unpin` 再看一次 → 删掉测试消息
//
//   dart run -DSYNO_NAS_URL=… -DSYNO_NAS_ACCOUNT=… "-DSYNO_NAS_PASSWORD=…" \
//            tool/probe_pin.dart
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

late DsmWebApi api;
late ChatApi chat;

Future<Map<String, dynamic>?> fetchPost(int channelId, int postId) async {
  final data = await api.call(
    'SYNO.Chat.Post',
    'list',
    preferredVersion: 8,
    params: {
      'channel_id': '$channelId',
      'post_id': '$postId',
      'prev_count': '5',
      'next_count': '5',
    },
  );
  for (final p in (data['posts'] as List?) ?? const []) {
    final m = Map<String, dynamic>.from(p as Map);
    if ((m['post_id'] as num).toInt() == postId) return m;
  }
  return null;
}

void dump(String label, Map<String, dynamic>? p) {
  if (p == null) {
    print('  $label → (list 里没有这条)');
    return;
  }
  print(
    '  $label → is_sticky=${p['is_sticky']} last_pin_at=${p['last_pin_at']} '
    'type=${p['type']} message=${jsonEncode(p['message'])}',
  );
}

Future<void> main() async {
  api = DsmWebApi(
    DirectTransport.url(
      const String.fromEnvironment('SYNO_NAS_URL'),
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
    password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
    session: 'Chat',
  );
  chat = ChatApi(api);

  final channels = await chat.listChannels();
  final c = channels.firstWhere(
    (x) => x.type == 'public' && x.isJoined,
    orElse: () => channels.firstWhere((x) => x.isJoined),
  );
  print('用频道 #${c.channelId}「${c.name}」type=${c.type}');

  final mobile = jsonEncode(DateTime.now().millisecondsSinceEpoch);
  final raw = await api.call(
    'SYNO.Chat.Post',
    'create',
    preferredVersion: 2,
    params: {
      'channel_id': '${c.channelId}',
      'message': jsonEncode('flt-probe-pin'),
      'mobile_token': mobile,
    },
  );
  final postId = ((raw['post'] ?? raw)['post_id'] as num).toInt();
  print('建了测试消息 post_id=$postId');

  try {
    print('\n① `Post/pin` v1：');
    try {
      final r = await api.call(
        'SYNO.Chat.Post',
        'pin',
        preferredVersion: 1,
        params: {'post_id': '$postId'},
      );
      print('  返回 ${jsonEncode(r)}');
    } catch (e) {
      print('  抛异常：$e');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    dump('回读', await fetchPost(c.channelId, postId));

    print('\n② `has=[pin]` 的列表里有没有它：');
    try {
      final data = await api.call(
        'SYNO.Chat.Post',
        'list',
        preferredVersion: 8,
        params: {
          'channel_id': '${c.channelId}',
          'prev_count': '20',
          'next_count': '0',
          'has': jsonEncode(['pin']),
        },
      );
      final posts = ((data['posts'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      print(
        '  置顶列表 ${posts.length} 条：'
        '${posts.map((p) => '#${p['post_id']}(sticky=${p['is_sticky']})').take(8).join(', ')}',
      );
    } catch (e) {
      print('  抛异常：$e');
    }

    print('\n③ `Post/stick` v2（话题置顶，另一套）：');
    try {
      final r = await api.call(
        'SYNO.Chat.Post',
        'stick',
        preferredVersion: 2,
        params: {'post_id': '$postId'},
      );
      print('  返回 ${jsonEncode(r)}');
    } catch (e) {
      print('  抛异常：$e');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    dump('回读', await fetchPost(c.channelId, postId));

    print('\n④ 收尾：unpin + unstick + delete');
    try {
      await api.call(
        'SYNO.Chat.Post',
        'unpin',
        preferredVersion: 1,
        params: {'post_id': '$postId'},
      );
      print('  unpin ✓');
    } catch (e) {
      print('  unpin 失败：$e');
    }
    try {
      await api.call(
        'SYNO.Chat.Post',
        'unstick',
        preferredVersion: 2,
        params: {'post_id': '$postId'},
      );
      print('  unstick ✓');
    } catch (e) {
      print('  unstick 失败：$e');
    }
    dump('unpin 后', await fetchPost(c.channelId, postId));
  } finally {
    try {
      await chat.deletePost(postId);
      print('  删除测试消息 ✓');
    } catch (e) {
      print('  删除失败：$e');
    }
  }
}
