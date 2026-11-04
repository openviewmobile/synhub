// 清掉 Phase 9 机器人/入站 webhook 探针造出来的东西。
//
//   * 机器人/入站 webhook：`creator_id` 是我自己、且昵称以 `flt` 开头或为空
//     （空的都是我 `Chatbot/create` 出来忘了起名的）→ `SYNO.Chat.Bot / delete`
//   * 频道：名字以 `flt-` 开头的 → `Channel.Named / disjoin`
//
// 用法：SYNO_NAS_* dart run tool/flt_chatbot_cleanup.dart [--apply]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main(List<String> args) async {
  final apply = args.contains('--apply');
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

  final me = int.parse(
    '${(await api.call('SYNO.Chat.User', 'get', preferredVersion: 1, params: {'user_id': '0'}))['user_id'] ?? 0}',
  );
  print('我 = #$me');

  print('\n== 待清理的机器人');
  final bots = await api.call(
    'SYNO.Chat.Chatbot',
    'list',
    preferredVersion: 1,
    params: {'channel_id': ''},
  );
  for (final bot in ((bots['chatbots'] as List?) ?? const [])) {
    final nickname = '${bot['nickname']}';
    final creator = bot['creator_id'];
    final mine =
        creator == me && (nickname.startsWith('flt') || nickname.isEmpty);
    print(
      'bot #${bot['user_id']} nickname=${jsonEncode(nickname)} '
      'type=${bot['bot_type']} url=${jsonEncode(bot['url'])} '
      'creator=$creator ${mine ? "← 要删" : ""}',
    );
    if (apply && mine) {
      try {
        await api.call(
          'SYNO.Chat.Bot',
          'delete',
          preferredVersion: 1,
          params: {'user_id': '${bot['user_id']}'},
        );
        print('  → 已删');
      } catch (e) {
        print('  → 删失败：$e');
      }
    }
  }

  print('\n== 入站 webhook（SYNO.Chat.Webhook.Incoming/list）');
  final hooks = await api.call(
    'SYNO.Chat.Webhook.Incoming',
    'list',
    preferredVersion: 1,
  );
  for (final h in ((hooks['webhook_incomings'] as List?) ?? const [])) {
    final mine =
        '${h['nickname']}'.startsWith('flt') || '${h['nickname']}'.isEmpty;
    print(
      'hook #${h['user_id']} nickname=${jsonEncode(h['nickname'])} '
      'channel=${h['channel_id']} ${mine ? "← 要删" : ""}',
    );
    if (apply && mine && h['creator_id'] == me) {
      try {
        await api.call(
          'SYNO.Chat.Bot',
          'delete',
          preferredVersion: 1,
          params: {'user_id': '${h['user_id']}'},
        );
        print('  → 已删');
      } catch (e) {
        print('  → 删失败：$e');
      }
    }
  }

  // 孤儿 chatbot 频道（机器人已删、只剩我一个）—— 用参数点名才动，别手滑
  for (final raw in args.where((a) => int.tryParse(a) != null)) {
    final id = int.parse(raw);
    if (!apply) {
      print('（dry-run）要不要退 #$id？');
      continue;
    }
    try {
      await chat.disjoinNamedChannel(id);
      print('已退出 #$id（Named/disjoin）');
    } catch (e) {
      print('Named/disjoin #$id 失败：$e');
    }
  }

  print('\n== 待退出的频道');
  for (final c in await chat.listChannels()) {
    final mine = c.name.startsWith('flt-');
    print(
      '#${c.channelId} ${jsonEncode(c.name)} type=${c.type} '
      'joined=${c.isJoined} ${mine ? "← 要退" : ""}',
    );
    if (apply && mine && c.isJoined) {
      try {
        await chat.disjoinNamedChannel(c.channelId);
        print('  → 已退出');
      } catch (e) {
        print('  → 退出失败：$e');
      }
    }
  }
  exit(0);
}
