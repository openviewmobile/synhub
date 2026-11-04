// Phase 9 端到端（真机 NAS）：机器人发「附件 + 按钮」→ 我们解析 → 点按钮上报。
//
// 踩坑记录（都是实测出来的，别照抄文档想当然）：
//   * `SYNO.Chat.Chatbot / create` 建的机器人 `nickname` 是空的 → 直接调
//     `Channel.Chatbot / initiate` 或 `External/*` 都会说 "bot is not legal"。
//     必须补两条：`SYNO.Chat.Bot / set`（`user_id` + `nickname`，**昵称只能走这个接口**，
//     `Chatbot/set` 的 `nickname` 是无效字段）+ `SYNO.Chat.Chatbot / set`
//     （`purpose` / `welcome_note`）。
//   * 机器人给自己频道发消息走 `SYNO.Chat.External / chatbot`（v1/v2/v3 都行），
//     `payload` 里要 **`user_ids`**（不给会 800 "no target"），这才支持 `attachments`；
//     `SYNO.Chat.External / incoming` 是**入站 webhook** 专用，只收 `text`，
//     附件会被静默丢掉（且 webhook 还要先绑定 `channel_id` 才"legal"）。
//   * 入站侧用 `token` 认证，**不要带 sid**（走 transport 直接 POST）。
//
// 用法：SYNO_NAS_* dart run tool/probe_bot_attachment.dart [--keep]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const _attachments = [
  {
    'callback_id': 'flt-p9-cb',
    'text': 'flt 附件文本，带 #flt-p9-tag 和链接 https://www.synology.com',
    'actions': [
      {
        'type': 'button',
        'name': 'resp',
        'value': 'ok',
        'text': 'OK',
        'style': 'green',
      },
      {
        'type': 'button',
        'name': 'no',
        'value': 'no',
        'text': '取消',
        'style': 'red',
      },
      {
        'type': 'button',
        'name': 'mystery',
        'value': 'x',
        'text': '未知样式',
        'style': 'purple',
      },
    ],
  },
];

Future<void> main(List<String> args) async {
  final keep = args.contains('--keep');
  final transport = DirectTransport.url(
    Platform.environment['SYNO_NAS_URL']!,
    dio: DioFactory.create(allowSelfSigned: true),
  );
  final api = DsmWebApi(transport);
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

  var botUserId = 0;
  var channelId = 0;
  var postId = 0;
  try {
    // ① 建机器人 + 弄"合法"
    final created = await api.call(
      'SYNO.Chat.Chatbot',
      'create',
      preferredVersion: 1,
      params: {'name': 'flt-p9-bot'},
    );
    botUserId = int.parse('${created['user_id']}');
    final token = '${created['token']}';
    await api.call(
      'SYNO.Chat.Bot',
      'set',
      preferredVersion: 1,
      params: {'user_id': '$botUserId', 'nickname': 'flt-p9-bot'},
    );
    await api.call(
      'SYNO.Chat.Chatbot',
      'set',
      preferredVersion: 1,
      params: {'user_id': '$botUserId', 'purpose': 'p9', 'welcome_note': 'hi'},
    );
    final init = await api.call(
      'SYNO.Chat.Channel.Chatbot',
      'initiate',
      preferredVersion: 1,
      params: {'user_id': '$botUserId'},
    );
    channelId = int.parse('${init['channel_id']}');
    print(
      '① 机器人 #$botUserId → 频道 #$channelId'
      '（token=${token.substring(0, 8)}…）',
    );

    // ② 机器人发一条带按钮的消息
    final sent = await transport.postForm('entry.cgi', {
      'api': 'SYNO.Chat.External',
      'method': 'chatbot',
      'version': '2',
      'token': token,
      'payload': jsonEncode({
        'text': 'Hello World',
        'user_ids': [me],
        'attachments': _attachments,
      }),
    });
    print('② External/chatbot → $sent');

    // ③ 读回来（服务端存下来的 props.attachments）
    final posts = await chat.listPosts(channelId: channelId, prevCount: 5);
    final hit = posts.where(
      (p) => (p['props'] as Map?)?['attachments'] != null,
    );
    if (hit.isEmpty) {
      print('✗ 没找到带 attachments 的消息：${jsonEncode(posts)}');
      exit(1);
    }
    postId = int.parse('${hit.first['post_id']}');
    print('③ 落库的 props.attachments：');
    print(
      const JsonEncoder.withIndent(
        '  ',
      ).convert((hit.first['props'] as Map)['attachments']),
    );

    // ④ 点按钮（= App 里点第一个附件第一个按钮）
    final t = await api.call(
      'SYNO.Chat.Post.Attachment',
      'trigger',
      preferredVersion: 1,
      params: {
        'post_id': '$postId',
        'payload': jsonEncode({
          'callback_id': 'flt-p9-cb',
          'idx': 0,
          'actions': [
            {'idx': 0, 'name': 'resp', 'type': 'button', 'value': 'ok'},
          ],
        }),
      },
    );
    print('④ Post.Attachment/trigger → ${jsonEncode(t)}');
  } finally {
    if (!keep) {
      if (postId > 0) {
        try {
          await api.call(
            'SYNO.Chat.Post',
            'delete',
            preferredVersion: 1,
            params: {'post_id': '$postId'},
          );
          print('⑤ 已删消息 #$postId');
        } catch (e) {
          print('⑤ 删消息失败：$e');
        }
      }
      if (botUserId > 0) {
        try {
          await api.call(
            'SYNO.Chat.Bot',
            'delete',
            preferredVersion: 1,
            params: {'user_id': '$botUserId'},
          );
          print('   已删机器人 #$botUserId（空频道会留在 NAS —— Synology 没有删 bot 频道的接口）');
        } catch (e) {
          print('   删机器人失败：$e');
        }
      }
    }
  }
  exit(0);
}
