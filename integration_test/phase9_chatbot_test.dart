// Phase 9 真机验收：机器人消息的「附件 + 按钮」。
//
//   flutter test integration_test/phase9_chatbot_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 只有真机能回答的问题：服务端把机器人的 `attachments` 存成什么样、我们的 DTO
// 能不能原样读懂、以及点按钮时 `SYNO.Chat.Post.Attachment / trigger` 的
// **请求形态**能不能被 2.4.7 服务端接受。
//
// 服务端的规矩（本文件实测出来的，别照抄文档）：
//   * 给机器人频道发消息要走 `SYNO.Chat.External / chatbot`（带 `token` + `payload`
//     里的 `user_ids`）—— `External / incoming` 是入站 webhook 专用，**不收附件**；
//   * `Chatbot / create` 出来的机器人 `nickname` 是空的，得 `Bot / set` 补上，
//     否则 `Channel.Chatbot / initiate` 与 `External / chatbot` 都会说
//     "bot is not legal"。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/chatbot_attachment_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/chatbot_attachment.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

const _attachments = [
  {
    'callback_id': 'flt-p9bot-cb',
    'text': '附件正文 #flt-p9bot-tag https://www.synology.com',
    'actions': [
      {'type': 'button', 'name': 'resp', 'value': 'ok', 'text': 'OK', 'style': 'green'},
      {'type': 'button', 'name': 'no', 'value': 'no', 'text': '取消', 'style': 'red'},
      {'type': 'button', 'name': 'mystery', 'value': 'x', 'text': '未知样式', 'style': 'purple'},
    ],
  }
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：机器人附件渲染 + 按钮上报', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);
    final me = container.read(chatSessionControllerProvider).myUserId;
    debugPrint('[p9bot] 我=#$me');

    // 机器人的 token 走"无 sid"的裸 POST（入站侧就是这么认证的）
    final transport = DirectTransport.url(conn.endpoint.baseUrl,
        dio: DioFactory.create(allowSelfSigned: true));

    var botUserId = 0;
    var channelId = 0;
    var postId = 0;
    try {
      // ---------- 建机器人并把它弄"合法" ----------
      final created = await conn.api.call('SYNO.Chat.Chatbot', 'create',
          preferredVersion: 1, params: {'name': 'flt-p9bot'});
      botUserId = int.parse('${created['user_id']}');
      final token = '${created['token']}';
      await conn.api.call('SYNO.Chat.Bot', 'set',
          preferredVersion: 1,
          params: {'user_id': '$botUserId', 'nickname': 'flt-p9bot'});
      // 光有昵称还不够：得 `Chatbot/set` 补上 purpose/welcome_note，
      // `initiate` 才不再报"chatbot is not legal"
      await conn.api.call('SYNO.Chat.Chatbot', 'set',
          preferredVersion: 1,
          params: {
            'user_id': '$botUserId',
            'purpose': 'Phase 9 验收',
            'welcome_note': 'hi',
          });
      final init = await conn.api.call('SYNO.Chat.Channel.Chatbot', 'initiate',
          preferredVersion: 1, params: {'user_id': '$botUserId'});
      channelId = int.parse('${init['channel_id']}');
      debugPrint('[p9bot] 机器人 #$botUserId → 频道 #$channelId');

      // ---------- 机器人发一条带按钮的消息 ----------
      final sent = await transport.postForm('entry.cgi', {
        'api': 'SYNO.Chat.External',
        'method': 'chatbot',
        'version': '2',
        'token': token,
        'payload': jsonEncode({
          'text': 'Phase 9 机器人附件验收',
          'user_ids': [me],
          'attachments': _attachments,
        }),
      });
      debugPrint('[p9bot] External/chatbot → $sent');
      expect(sent, contains('"success":true'));

      // ---------- 我们自己的读取链路：enter → Post/list ----------
      await ctrl.enterChannel(channelId);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final posts = await chat.listPosts(channelId: channelId, prevCount: 10);
      final hit = posts.where((p) {
        final props = p['props'];
        return props is Map && props['attachments'] != null;
      }).toList();
      expect(hit, isNotEmpty, reason: '服务端应当把 attachments 存下来');
      postId = int.parse('${hit.first['post_id']}');
      debugPrint('[p9bot] 服务端 props.attachments = '
          '${jsonEncode((hit.first['props'] as Map)['attachments'])}');

      // ---------- DTO 解析（真响应）----------
      final store = container.read(chatStoreProvider);
      final local = await store.postById(channelId, postId);
      expect(local, isNotNull, reason: 'enter 之后本地应当有这条消息');
      final parsed = local!.chatbotAttachments;
      debugPrint('[p9bot] 我们解析出 ${parsed.length} 条附件：'
          '${parsed.map((a) => "${a.callbackId}/${a.text}/"
              "${a.actions.map((x) => x.label).join("|")}").join(" ; ")}');
      expect(parsed, hasLength(1));
      expect(parsed.single.callbackId, 'flt-p9bot-cb');
      expect(parsed.single.actions.map((a) => a.label), ['OK', '取消', '未知样式']);
      expect(parsed.single.actions[0].resolvedStyle, ChatbotActionStyle.green);
      expect(parsed.single.actions[1].resolvedStyle, ChatbotActionStyle.red);
      expect(parsed.single.actions[2].resolvedStyle, ChatbotActionStyle.gray,
          reason: 'purple 不是六种样式之一 → 按 gray 画');
      expect(parsed.single.actions[0].value, 'ok');

      // ---------- 真机上把这块 UI 画出来（布局/溢出只有真机能验）----------
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChatbotAttachmentList(
              channelId: channelId,
              post: local,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      for (final label in ['OK', '取消', '未知样式']) {
        expect(find.text(label), findsOneWidget, reason: '按钮「$label」应当画出来');
      }
      expect(find.byType(OutlinedButton), findsNWidgets(3));
      expect(tester.takeException(), isNull, reason: '真机布局不该溢出/报错');
      debugPrint('[p9bot] 真机渲染：3 个按钮 + 附件正文 ✓');

      // ---------- 点按钮：真调 trigger ----------
      final ok = await ctrl.triggerChatbotAction(
        channelId: channelId,
        postId: postId,
        attachmentIndex: 0,
        actionIndex: 0,
      );
      expect(ok, isTrue, reason: '2.4.7 服务端应当接受 trigger 请求（形态见单测）');
      debugPrint('[p9bot] ✅ 机器人附件 + 按钮上报验收完成');
    } finally {
      // ---------- 清理 ----------
      if (postId > 0) {
        await conn.api
            .call('SYNO.Chat.Post', 'delete',
                preferredVersion: 1, params: {'post_id': '$postId'})
            .catchError((_) => <String, dynamic>{});
      }
      if (botUserId > 0) {
        await conn.api
            .call('SYNO.Chat.Bot', 'delete',
                preferredVersion: 1, params: {'user_id': '$botUserId'})
            .catchError((_) => <String, dynamic>{});
      }
      debugPrint('[p9bot] 清理完成（消息 #$postId / 机器人 #$botUserId）');
    }
  });
}
