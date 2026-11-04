// Phase 9 侦察：机器人消息（附件 + 按钮）在真实 NAS 上的形态。
//
// 输出：
//   * 所有频道的 id/名字/type（找出 chatbot 频道）
//   * `SYNO.Chat.Chatbot / list`（机器人清单）+ `get`（拿 token / 入站 URL）
//   * 每个频道最近 60 条里带 `props.attachments` 的消息（原样打印）
//   * 可选：往指定机器人发一条带按钮的消息（--send <channelId>）
//
// 用法：
//   SYNO_NAS_URL=... SYNO_NAS_ACCOUNT=... SYNO_NAS_PASSWORD=... \
//     dart run tool/probe_chatbot.dart [--send <channelId>]
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

  print('== 频道');
  final channels = await chat.listChannels();
  for (final c in channels) {
    print('#${c.channelId} ${c.name} type=${c.type} joined=${c.isJoined}');
  }

  print('\n== 机器人清单（SYNO.Chat.Chatbot/list）');
  Map<String, dynamic>? botList;
  try {
    botList = await api.call(
      'SYNO.Chat.Chatbot',
      'list',
      preferredVersion: 1,
      params: {'channel_id': ''},
    );
    print(const JsonEncoder.withIndent('  ').convert(botList));
  } catch (e) {
    print('list 失败：$e');
  }

  // 每个频道找带附件的消息
  for (final c in channels.take(20)) {
    List<Map<String, dynamic>> posts;
    try {
      posts = await chat.listPosts(channelId: c.channelId, prevCount: 60);
    } catch (e) {
      continue;
    }
    for (final p in posts) {
      final props = p['props'];
      if (props is Map && props['attachments'] != null) {
        print('\n== 带附件的消息 #${c.channelId} ${c.name} post=${p['post_id']}');
        print(const JsonEncoder.withIndent('  ').convert(props['attachments']));
      }
    }
  }

  print('\n== 每个机器人的详情（Chatbot/get）');
  for (final bot in ((botList?['chatbots'] as List?) ?? const [])) {
    final id = bot['user_id'];
    try {
      final got = await api.call(
        'SYNO.Chat.Chatbot',
        'get',
        preferredVersion: 1,
        params: {'user_id': '$id'},
      );
      print('user_id=$id nickname=${bot['nickname']} → ${jsonEncode(got)}');
    } catch (e) {
      print('user_id=$id get 失败：$e');
    }
  }

  print('\n== chatbot 频道的成员');
  for (final c in channels.where(
    (c) => c.type == 'chatbot' || c.type == 'synobot',
  )) {
    try {
      final m = await chat.listChannelMembers(c.channelId);
      print('#${c.channelId} ${c.name} type=${c.type} members=${m.userIds}');
    } catch (e) {
      print('#${c.channelId} 成员失败：$e');
    }
  }

  exit(0);
}
