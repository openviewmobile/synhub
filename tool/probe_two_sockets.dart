// 两个实时连接的自检：回答"自己发的消息会不会以 client.post.create 推回来"。
//
// 结论（实测）：
//   * 同一条连接：不会。发送方靠 HTTP 响应里的 PostVo 得知自己发了什么，
//     服务端只把 `client.broadcast / user.update`、`post.delete` 之类的推回来。
//   * 另一条连接（同账号第二次登录）：会收到 `client.post.create`。
//
// 用法：
//   SYNO_NAS_URL=… SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… \
//     dart run tool/probe_two_sockets.dart [channel_id]
import 'dart:async';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/dsm/webapi.dart';

// ignore_for_file: avoid_print

void main(List<String> args) async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_NAS_PASSWORD']!;

  // 两个「客户端」：各自的 Dio / DsmWebApi / 登录会话 / socket
  Future<(DsmWebApi, ChatApi, ChatSocket, List<String>)> newClient(
    String tag,
  ) async {
    final api = DsmWebApi(DirectTransport.url(url, dio: DioFactory.create()));
    await api.discover();
    final session = await api.login(
      account: account,
      password: password,
      session: 'Chat',
    );
    final socket = ChatSocket(baseUrl: url, sid: session.sid);
    final events = <String>[];
    // 记录事件名，方便最后统一打印
    socket.events.listen((e) {
      final extra = e.event == 'client.broadcast'
          ? '(${e.asMap?['type']})'
          : '';
      events.add('${e.event}$extra');
      print('[$tag] ← ${e.event}$extra');
    });
    await socket.connect();
    await socket.waitReady(timeout: const Duration(seconds: 20));
    print('[$tag] conn_id = ${socket.connId}');
    return (api, ChatApi(api), socket, events);
  }

  final a = await newClient('A');
  print('--- A 已就绪，现在登录第二个会话 B ---');
  final b = await newClient('B');
  final aEvents = a.$4;
  final bEvents = b.$4;

  print('A 是否还活着: ${a.$3.status}, B: ${b.$3.status}');

  var channelId = args.isNotEmpty ? int.parse(args.first) : 0;
  if (channelId == 0) {
    final channels = await a.$2.listChannels();
    channelId = channels.firstWhere((c) => !c.encrypted).channelId;
  }

  final marker = 'flt-two-${DateTime.now().millisecondsSinceEpoch}';
  print('--- 用 A 往 #$channelId 发消息: $marker ---');
  final post = await a.$2.createPost(
    channelId: channelId,
    message: marker,
    connId: a.$3.connId!,
  );
  print(
    'post_id=${post['post_id']} type=${post['type']} '
    'message=${post['message']}',
  );

  await Future<void>.delayed(const Duration(seconds: 6));

  print('--- 清理 ---');
  final posts = await a.$2.listPosts(channelId: channelId, prevCount: 50);
  for (final p in posts) {
    final msg = '${p['message']}';
    if (msg.contains('flt-two-') ||
        msg.contains('flt-probe-') ||
        msg.contains('flt-check-')) {
      print('删除 ${p['post_id']} ($msg)');
      await a.$2.deletePost((p['post_id'] as num).toInt());
    }
  }

  print('=== A 收到的事件 ===');
  print(aEvents.isEmpty ? '(无)' : aEvents.join(', '));
  print('=== B 收到的事件 ===');
  print(bEvents.isEmpty ? '(无)' : bEvents.join(', '));
  print('=== 结论 ===');
  print('A 收到 client.post.create: ${aEvents.contains('client.post.create')}');
  print('B 收到 client.post.create: ${bEvents.contains('client.post.create')}');
  print('A 是否被 B 的登录踢掉: ${a.$3.status}');

  a.$3.dispose();
  b.$3.dispose();
  await a.$1.logout();
  await b.$1.logout();
  await a.$1.transport.close();
  await b.$1.transport.close();
}
