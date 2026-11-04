// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
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
  final id = int.parse(Platform.environment['POST_ID']!);
  final posts = await chat.listPosts(channelId: 1, prevCount: 10);
  for (final p in posts) {
    if ((p['post_id'] as num).toInt() == id) {
      print('url_props=${jsonEncode(p['url_props'])}');
      print('props=${jsonEncode(p['props'])}');
    }
  }
  // 试着直接问 OG
  try {
    final body = await api.call(
      'SYNO.Chat.Post.File',
      'og',
      preferredVersion: 1,
      params: {
        'post_id': '$id',
        'url': jsonEncode('https://www.synology.com/zh-cn/products/DS920+'),
      },
    );
    print(
      'og ok: ${body.toString().substring(0, body.toString().length.clamp(0, 120))}',
    );
  } catch (e) {
    print('og err: $e');
  }
  // 删掉探针消息
  try {
    await chat.deletePost(id);
    print('已删除探针消息 #$id');
  } catch (e) {
    print('删除失败：$e');
  }
  exit(0);
}
