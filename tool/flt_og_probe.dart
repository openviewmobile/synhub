// 探针：验证 `SYNO.Chat.Post.File / og` 用 **GET + 查询串**（带 _sid）能不能拿到图。
// 原版是 POST（`streamService.og`），我们要复用 `getBytes` 这条现成下载路。
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

  var created = 0;
  if (args.contains('--post')) {
    final sent = await chat.createPost(
      channelId: 1,
      message: 'flt-og-probe https://www.synology.com/zh-cn/products/DS920+',
      connId: '',
    );
    created = (((sent['post'] ?? sent) as Map)['post_id'] as num).toInt();
    print('发了 #$created，等服务端抓 OG…');
  }

  Map<String, dynamic>? withUrl;
  for (var i = 0; i < 20; i++) {
    final posts = await chat.listPosts(channelId: 1, prevCount: 20);
    for (final p in posts) {
      final urls = p['url_props'];
      if (urls is List && urls.isNotEmpty) withUrl = p;
    }
    if (withUrl != null) break;
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  if (withUrl == null) {
    print('等了 60 秒仍没有 url_props');
    exit(0);
  }
  final pid = (withUrl['post_id'] as num).toInt();
  final url = ((withUrl['url_props'] as List).first as Map)['url'] as String;
  print('用 post=$pid url=$url');

  final link = api.authenticatedUrl(api.apiPath('SYNO.Chat.Post.File'), {
    'api': 'SYNO.Chat.Post.File',
    'method': 'og',
    'version': '1',
    'post_id': '$pid',
    'url': jsonEncode(url),
  });
  print('URL=$link');
  try {
    final bytes = await api.getBytes(link);
    print('GET og ✓ ${bytes.length} 字节，头 8 字节=${bytes.take(8).toList()}');
  } catch (e) {
    print('GET og ✗ $e');
  }
  // 顺带试 favicon（同样是外链，走同一个代理）
  final fav = ((withUrl['url_props'] as List).first as Map)['favicon'];
  if (fav is String && fav.isNotEmpty) {
    try {
      final bytes = await api.getBytes(
        api.authenticatedUrl(api.apiPath('SYNO.Chat.Post.File'), {
          'api': 'SYNO.Chat.Post.File',
          'method': 'og',
          'version': '1',
          'post_id': '$pid',
          'url': jsonEncode(fav),
        }),
      );
      print('GET og(favicon) ✓ ${bytes.length} 字节');
    } catch (e) {
      print('GET og(favicon) ✗ $e');
    }
  }
  if (created != 0 && args.contains('--cleanup')) {
    await chat.deletePost(created);
    print('已删除探针消息 #$created');
  }
  exit(0);
}
