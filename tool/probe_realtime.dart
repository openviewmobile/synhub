// ignore_for_file: avoid_print
// 实时通道诊断 + 测试消息清理。
//
// 用途一：打印 socket 上收到的**每一条**事件（含 client.broadcast 的 type），
//         回答"自己发的消息会不会以 client.post.create 推回给自己"。
// 用途二：发一条带 marker 的测试消息，然后**按 marker 找回真实 post_id 并删除**，
//         避免在 NAS 上留下垃圾消息。
//
// 用法：
//   SYNO_NAS_URL=… SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… \
//     dart run tool/probe_realtime.dart [channel_id] [--cleanup-only marker]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// 我们自己造的测试消息前缀 —— 只删这些，绝不碰真实消息
const _testPrefixes = ['flt-check-', 'flt-probe-', 'flt-two-', 'flt-live-'];

void main(List<String> args) async {
  final url = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'];
  if (url == null || account == null || password == null) {
    stderr.writeln('需要 SYNO_NAS_URL / SYNO_NAS_ACCOUNT / SYNO_NAS_PASSWORD');
    exit(2);
  }

  final dio = DioFactory.create();
  final api = DsmWebApi(DirectTransport.url(url, dio: dio));
  await api.discover();
  final session = await api.login(
    account: account,
    password: password,
    session: 'Chat',
  );
  final chat = ChatApi(api);

  final cleanupOnly = args.contains('--cleanup-only');
  final marker = cleanupOnly
      ? args.last
      : 'flt-probe-${DateTime.now().millisecondsSinceEpoch}';

  // 选定频道
  int channelId;
  if (args.isNotEmpty && int.tryParse(args.first) != null) {
    channelId = int.parse(args.first);
  } else {
    final channels = await chat.listChannels();
    channelId = channels
        .firstWhere((c) => !c.encrypted, orElse: () => channels.first)
        .channelId;
  }
  print('频道 = #$channelId, marker = $marker');

  // ------------------------------------------------------------ cleanup
  //
  // 扫全频道，只删**我们自己造的**测试消息（flt-check- / flt-probe- 前缀），
  // 绝不碰用户的真实消息。
  Future<void> cleanup() async {
    final posts = await chat.listPosts(channelId: channelId, prevCount: 50);
    print('频道内共 ${posts.length} 条消息：');
    for (final p in posts) {
      print('   id=${p['post_id']} message=${p['message']}');
    }
    final hits = posts
        .where((p) => _testPrefixes.any((m) => '${p['message']}'.contains(m)))
        .toList();
    print('按 marker 命中 ${hits.length} 条');
    for (final p in hits) {
      final id = (p['post_id'] as num).toInt();
      print('  删除 post_id=$id message=${p['message']}');
      try {
        await chat.deletePost(id);
        print('  已删除 $id');
      } catch (e) {
        print('  删除失败 $id: $e');
      }
    }
  }

  if (cleanupOnly) {
    await cleanup();
    await api.logout();
    await api.transport.close();
    return;
  }

  // ------------------------------------------------------------ socket
  final socket = ChatSocket(
    baseUrl: url,
    sid: session.sid,
    synotoken: session.synotoken,
  );
  socket.events.listen((e) {
    final map = e.asMap;
    final detail = e.event == 'client.broadcast'
        ? 'type=${map?['type']} data=${jsonEncode(map?['data'])}'
        : jsonEncode(e.payload);
    print('  ← ${e.event} $detail');
  });
  socket.statuses.listen((st) => print('  [status] $st'));

  var ready = false;
  for (var attempt = 1; attempt <= 3 && !ready; attempt++) {
    print('--- 连接尝试 $attempt ---');
    await socket.connect();
    try {
      await socket.waitReady(timeout: const Duration(seconds: 8));
      ready = true;
    } catch (e) {
      print('  第 $attempt 次未就绪: $e (lastError=${socket.lastError})');
      socket.disposeSocketOnly();
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  if (!ready) {
    print('三次都没拿到 client.init，放弃');
    await api.logout();
    await api.transport.close();
    return;
  }
  print('conn_id = ${socket.connId}');

  // ------------------------------------------------------------ create
  final resp = await chat.createPost(
    channelId: channelId,
    message: marker,
    connId: socket.connId!,
  );
  print('createPost 响应:\n${const JsonEncoder.withIndent('  ').convert(resp)}');

  await Future<void>.delayed(const Duration(seconds: 8));

  // ------------------------------------------------------------ cleanup
  await cleanup();
  socket.dispose();
  await api.logout();
  await api.transport.close();
}
