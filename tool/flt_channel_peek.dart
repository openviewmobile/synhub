// ignore_for_file: avoid_print
// 看一眼指定频道里的消息，判断是不是测试残留。
//   SYNO_NAS_* dart run tool/flt_channel_peek.dart 1 2 83
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
  for (final id in args.map(int.parse)) {
    print('== 频道 #$id');
    try {
      final ch = await api.call(
        'SYNO.Chat.Channel',
        'get',
        preferredVersion: 2,
        params: {'channel_id': id, 'additional': '[]'},
      );
      final keys = [
        'channel_id',
        'name',
        'type',
        'creator_id',
        'member_count',
        'is_public',
      ];
      print('  ${keys.map((k) => '$k=${jsonEncode(ch[k])}').join(' ')}');
    } catch (e) {
      print('  get 失败：$e');
    }
    try {
      final posts = await chat.listPosts(channelId: id, prevCount: 10);
      print('  消息 ${posts.length} 条：');
      for (final p in posts) {
        print(
          '    ${p['post_id']} ${jsonEncode('${p['message']}')} '
          'by=${p['creator_name'] ?? p['creator_id']} type=${p['type']} '
          'at=${p['create_at']}',
        );
      }
    } catch (e) {
      print('  消息读取失败：$e');
    }
  }
  await api.logout();
  exit(0);
}
