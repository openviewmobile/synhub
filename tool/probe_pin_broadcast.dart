// 探 `Post/pin` / `Post/unpin` 会不会走 socket 广播、广播成什么样。
//
// 背景：真机 phase4 里 A 会话置顶成功、也能从服务端回读 `last_pin_at`，但
// B 取消置顶后 A **没等到** `post.unpin` 广播（star 那套是能收到的）。
// 所以要直接看 socket：
//
//   dart run -DSYNO_NAS_URL=… -DSYNO_NAS_ACCOUNT=… "-DSYNO_NAS_PASSWORD=…" \
//            tool/probe_pin_broadcast.dart [channel_id]
//
// 会建一条 `flt-probe-` 测试消息，跑完自动删掉。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/dsm/webapi.dart';

const _prefix = 'flt-probe-';

Future<void> main(List<String> args) async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_NAS_PASSWORD']!;

  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  final session = await api.login(
    account: account,
    password: password,
    session: 'Chat',
  );
  final chat = ChatApi(api);

  final channels = await chat.listChannels();
  final channelId = args.isNotEmpty && int.tryParse(args.first) != null
      ? int.parse(args.first)
      : channels.firstWhere((c) => c.type == 'public' && c.isJoined).channelId;
  print('频道 = #$channelId');

  // 两个 socket：A 收发广播，B 做动作（模拟"别人置顶/取消置顶"）
  final sockets = <String, ChatSocket>{};
  for (final name in ['A', 'B']) {
    final s = ChatSocket(
      baseUrl: url,
      sid: session.sid,
      synotoken: session.synotoken,
    );
    s.events.listen((e) {
      if (e.event == 'client.broadcast') {
        final map = e.asMap;
        print(
          '  [$name] ← broadcast type=${map?['type']} '
          'data=${jsonEncode(map?['data'])}',
        );
      } else {
        print('  [$name] ← ${e.event}');
      }
    });
    await s.connect();
    await s.waitReady(timeout: const Duration(seconds: 10));
    sockets[name] = s;
    print('[$name] conn=${s.connId}');
  }

  final marker = '$_prefix${DateTime.now().millisecondsSinceEpoch}';
  final resp = await chat.createPost(
    channelId: channelId,
    message: marker,
    connId: sockets['A']!.connId!,
  );
  final postId = ((resp['post'] ?? resp)['post_id'] as num).toInt();
  print('建了测试消息 post_id=$postId marker=$marker');
  await Future<void>.delayed(const Duration(seconds: 2));

  print('\n① B 调 `Post/pin` v1：');
  await api.call(
    'SYNO.Chat.Post',
    'pin',
    preferredVersion: 1,
    params: {'post_id': '$postId'},
  );
  await Future<void>.delayed(const Duration(seconds: 4));

  print('\n② B 调 `Post/unpin` v1：');
  try {
    await api.call(
      'SYNO.Chat.Post',
      'unpin',
      preferredVersion: 1,
      params: {'post_id': '$postId'},
    );
  } catch (e) {
    print('  unpin 抛异常：$e');
  }
  await Future<void>.delayed(const Duration(seconds: 4));

  print('\n③ B 调 `Post/stick` v2（对照：is_sticky 那套）：');
  try {
    await api.call(
      'SYNO.Chat.Post',
      'stick',
      preferredVersion: 2,
      params: {'post_id': '$postId'},
    );
  } catch (e) {
    print('  stick 抛异常：$e');
  }
  await Future<void>.delayed(const Duration(seconds: 4));

  print('\n收尾：删除测试消息');
  try {
    await chat.deletePost(postId);
    print('  删除 ✓');
  } catch (e) {
    print('  删除失败：$e');
  }
  for (final s in sockets.values) {
    s.dispose();
  }
  await api.logout();
  await api.transport.close();
}
