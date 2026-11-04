// 探针：发一条带链接的消息，把服务端回的 `url_props` 原样打出来
// （用来对齐 OG 卡片字段：title/description/image/favicon/hidden/mime_type…）。
// ignore_for_file: avoid_print
import 'dart:convert';
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

  final channels = await chat.listChannels();
  final target = channels.firstWhere((c) => !c.encrypted);
  print('频道 #${target.channelId} ${target.name}');

  // 先看看已有消息里有没有带 url_props 的（不用发新消息）
  for (final c in channels) {
    final posts = await chat.listPosts(channelId: c.channelId, prevCount: 40);
    for (final p in posts) {
      final urls = p['url_props'];
      if (urls is List && urls.isNotEmpty) {
        print(
          '已有 #${c.channelId} post=${p['post_id']} url_props='
          '${jsonEncode(urls)}',
        );
      }
    }
  }

  if (!args.contains('--post')) {
    print('（加 --post 才发新消息）');
    exit(0);
  }
  // conn_id 只能从 socket 的 client.init 拿；这里借 TestChatSocket 太绕，
  // 直接用一个空 conn_id 试（服务端对 url 预览不校验 conn_id 的场景）
  final sent = await chat.createPost(
    channelId: target.channelId,
    message: 'flt-url-probe https://www.synology.com/zh-cn/products/DS920+',
    connId: '',
  );
  final post = (sent['post'] as Map? ?? sent);
  final pid = (post['post_id'] as num).toInt();
  print('新消息 #$pid url_props=${jsonEncode(post['url_props'])}');
  print('props=${jsonEncode(post['props'])}');
  exit(0);
}
