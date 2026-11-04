// 探针：Post.Subscribe 之后服务端到底广播了什么（打印所有到达的事件）。
// 用法：dart run tool/flt_sub_probe.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL']!;
  final account = Platform.environment['SYNO_NAS_ACCOUNT']!;
  final password = Platform.environment['SYNO_NAS_PASSWORD']!;

  final apiA = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await apiA.discover();
  await apiA.login(account: account, password: password, session: 'Chat');
  final chatA = ChatApi(apiA);

  final apiB = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await apiB.discover();
  final b = await apiB.login(
    account: account,
    password: password,
    session: 'Chat',
  );

  final socket = ChatSocket(baseUrl: url, sid: b.sid, synotoken: b.synotoken);
  final events = <String>[];
  socket.events.listen((e) => events.add('${e.event} ${e.payload}'));

  final channels = await chatA.listChannels();
  final ch = channels.firstWhere((c) => !c.encrypted && c.channelId > 0);
  final posts = await chatA.listPosts(channelId: ch.channelId, prevCount: 3);
  print('频道 #${ch.channelId} 消息 ${posts.map((p) => p['post_id']).toList()}');

  await socket.connect();
  await socket.waitReady(timeout: const Duration(seconds: 25));
  print('第二条连接就绪 sid_b=${b.sid}');

  for (final p in posts.take(2)) {
    final pid = (p['post_id'] as num).toInt();
    print('--- 用 A 订阅 #$pid');
    await chatA.subscribePost(pid);
    await Future<void>.delayed(const Duration(seconds: 3));
    print('--- A 退订 #$pid');
    await chatA.unsubscribePost(pid);
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  print('=== B 收到的事件 ===');
  for (final e in events) {
    print(e);
  }
  socket.dispose();
  exit(0);
}
