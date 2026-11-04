// Phase 9：机器人消息的「附件 + 按钮」。
//
// 规格来源（两处权威）：
//   * NAS 自带帮助 `ui/help/enu/chat_integration.html`（2.4.7 包内）给了机器人
//     入站消息的 JSON 形状与 style 取值；
//   * APK 的 `AttachmentVo` / `ActionVo` / `AccountManager#triggerChatBotAttachment`
//     / `ActionAdapter`（颜色 switch）给了客户端解析与上报的确切字段。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/chatbot_attachment_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/chatbot_attachment.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 帮助文档里的原样例子（`chat_integration.html`）
const _docAttachment = {
  'callback_id': 'abc',
  'text': 'attachment',
  'actions': [
    {
      'type': 'button',
      'name': 'resp',
      'value': 'ok',
      'text': 'OK',
      'style': 'green',
    },
  ],
};

PostDto _postWith(Object? attachments, {int postId = 4294967300}) => PostDto(
  postId: postId,
  channelId: 5,
  message: 'Hello World',
  createAt: 1,
  props: {'attachments': attachments},
);

void main() {
  group('DTO 解析（AttachmentVo / ActionVo）', () {
    test('文档里的例子：callback_id / text / actions 全解析', () {
      final list = ChatbotAttachmentDto.parseList([_docAttachment]);
      expect(list, hasLength(1));
      final a = list.single;
      expect(a.callbackId, 'abc');
      expect(a.text, 'attachment');
      expect(a.actions, hasLength(1));
      final act = a.actions.single;
      expect(act.type, 'button');
      expect(act.name, 'resp');
      expect(act.value, 'ok');
      expect(act.text, 'OK');
      expect(act.resolvedStyle, ChatbotActionStyle.green);
    });

    test('单个对象（不是数组）也能解析', () {
      expect(ChatbotAttachmentDto.parseList(_docAttachment), hasLength(1));
    });

    test('被 JSON 字符串包一层也能解析（服务端两种形态都给过）', () {
      final list = ChatbotAttachmentDto.parseList(jsonEncode([_docAttachment]));
      expect(list, hasLength(1));
      expect(list.single.callbackId, 'abc');
    });

    test('乱七八糟的输入不炸：null / 空串 / 数字', () {
      expect(ChatbotAttachmentDto.parseList(null), isEmpty);
      expect(ChatbotAttachmentDto.parseList(''), isEmpty);
      expect(ChatbotAttachmentDto.parseList('not json'), isEmpty);
      expect(ChatbotAttachmentDto.parseList(7), isEmpty);
    });

    test('六种 style 都认（大小写不敏感），未知名落到 gray', () {
      expect(ChatbotActionStyle.parse('green'), ChatbotActionStyle.green);
      expect(ChatbotActionStyle.parse('BLUE'), ChatbotActionStyle.blue);
      expect(ChatbotActionStyle.parse('orange'), ChatbotActionStyle.orange);
      expect(ChatbotActionStyle.parse('teal'), ChatbotActionStyle.teal);
      expect(ChatbotActionStyle.parse('red'), ChatbotActionStyle.red);
      expect(ChatbotActionStyle.parse('gray'), ChatbotActionStyle.gray);
      // 文档写的是 grey，APK 的常量是 gray —— 都算 gray
      expect(ChatbotActionStyle.parse('grey'), ChatbotActionStyle.gray);
      expect(ChatbotActionStyle.parse('purple'), ChatbotActionStyle.gray);
      expect(ChatbotActionStyle.parse(null), ChatbotActionStyle.gray);
    });

    test('颜色值取自 APK 资源（colorButton*）', () {
      expect(ChatbotActionStyle.green.color, const Color(0xFF5FB86D));
      expect(ChatbotActionStyle.blue.color, const Color(0xFF189AF4));
      expect(ChatbotActionStyle.orange.color, const Color(0xFFFA8E4B));
      expect(ChatbotActionStyle.teal.color, const Color(0xFF1EB9C7));
      expect(ChatbotActionStyle.red.color, const Color(0xFFF0645A));
      expect(ChatbotActionStyle.gray.color, const Color(0xFF7A7C80));
    });

    test('按钮文案优先 text，没有就用 name', () {
      final a = ChatbotActionDto.fromJson({'name': 'resp', 'value': 'ok'});
      expect(a.label, 'resp');
      expect(a.type, 'button', reason: '服务端没给 type 时默认 button');
    });

    test('PostDto.chatbotAttachments 从 props.attachments 读', () {
      expect(_postWith([_docAttachment]).chatbotAttachments, hasLength(1));
      expect(_postWith(null).chatbotAttachments, isEmpty);
      expect(
        const PostDto(postId: 1, channelId: 5, message: 'x').chatbotAttachments,
        isEmpty,
      );
    });
  });

  group('trigger API 参数形态（对齐 AccountManager#triggerChatBotAttachment）', () {
    Future<ChatApi> apiOf(FakeTransport t) async {
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      return ChatApi(api);
    }

    test('Post.Attachment / trigger v1：post_id + payload（一层 JSON）', () async {
      final t = FakeTransport();
      final api = await apiOf(t);

      await api.triggerChatbotAction(
        postId: 4294967300,
        attachmentIndex: 2,
        actionIndex: 1,
        callbackId: 'abc',
        name: 'resp',
        type: 'button',
        value: 'ok',
      );

      final call = t.calls.last;
      expect(
        '${call['api']}.${call['method']}',
        'SYNO.Chat.Post.Attachment.trigger',
      );
      expect('${call['version']}', '1');
      expect('${call['post_id']}', '4294967300');

      // payload 是 Gson.toJson(AttachmentTmp) 的原文：一层 JSON，不是二次编码
      final raw = '${call['payload']}';
      expect(raw.startsWith('{'), isTrue, reason: '不该再包一层引号');
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      expect(payload.keys.toSet(), {'callback_id', 'idx', 'actions'});
      expect(payload['callback_id'], 'abc');
      expect(payload['idx'], 2);
      final actions = payload['actions'] as List;
      expect(actions, hasLength(1), reason: '只发被点的那一个 action');
      expect(actions.single, {
        'idx': 1,
        'name': 'resp',
        'type': 'button',
        'value': 'ok',
      });
    });
  });

  group('控制器：点按钮', () {
    test('下标正确 → 上报被点的那一个 action', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        _postWith([_docAttachment]),
      ]);

      final ok = await h.ctrl.triggerChatbotAction(
        channelId: 5,
        postId: 4294967300,
        attachmentIndex: 0,
        actionIndex: 0,
      );
      expect(ok, isTrue);

      final call = h.transport.calls.lastWhere(
        (c) =>
            '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.Attachment.trigger',
      );
      final payload = jsonDecode('${call['payload']}') as Map<String, dynamic>;
      expect(payload['callback_id'], 'abc');
      expect((payload['actions'] as List).single['value'], 'ok');
    });

    test('越界 / 不存在的消息 → false，且不发请求', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        _postWith([_docAttachment]),
      ]);
      final before = h.transport.calls.length;

      expect(
        await h.ctrl.triggerChatbotAction(
          channelId: 5,
          postId: 4294967300,
          attachmentIndex: 3,
          actionIndex: 0,
        ),
        isFalse,
      );
      expect(
        await h.ctrl.triggerChatbotAction(
          channelId: 5,
          postId: 4294967300,
          attachmentIndex: 0,
          actionIndex: 9,
        ),
        isFalse,
      );
      expect(
        await h.ctrl.triggerChatbotAction(
          channelId: 5,
          postId: 999,
          attachmentIndex: 0,
          actionIndex: 0,
        ),
        isFalse,
      );
      expect(h.transport.calls.length, before);
    });

    test('服务端报错 → false（UI 会提示）', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        _postWith([_docAttachment]),
      ]);
      h.transport.failures['SYNO.Chat.Post.Attachment.trigger'] = 101;

      expect(
        await h.ctrl.triggerChatbotAction(
          channelId: 5,
          postId: 4294967300,
          attachmentIndex: 0,
          actionIndex: 0,
        ),
        isFalse,
      );
    });
  });

  group('UI 渲染', () {
    Future<ProviderContainer> pumpList(
      WidgetTester tester,
      Object? attachments, {
      ChatHarness? harness,
    }) async {
      final h = harness ?? await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([_postWith(attachments)]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: SingleChildScrollView(
                child: ChatbotAttachmentList(
                  channelId: 5,
                  post: _postWith(attachments),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return h.container;
    }

    testWidgets('附件文本 + 按钮都画出来，颜色按 style', (tester) async {
      await pumpList(tester, [
        {
          'callback_id': 'abc',
          'text': 'attachment',
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
            {'type': 'button', 'name': 'x', 'value': 'x', 'text': '别的'},
          ],
        },
      ]);

      expect(find.text('attachment'), findsOneWidget);
      expect(find.text('OK'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('别的'), findsOneWidget);
      // 未知 style 落 gray
      final buttons = tester
          .widgetList<OutlinedButton>(find.byType(OutlinedButton))
          .toList();
      expect(buttons, hasLength(3));
      // ★ 第 238 轮（`DA182`）：断言从"必须等于品牌原色"改成
      //   "**色相仍按 style 区分**，且**文字可读**（≥ AA）"。
      //   原色在亮底上只有 2.3–4.2:1，直接当文字色是缺陷 ——
      //   所以这里钉住的是语义与可读性，而不是那个 hex。
      final colors = buttons
          .map((b) => b.style?.side?.resolve({})?.color)
          .toList();
      expect(colors, hasLength(3));
      // 绿：G 最大；红：R 最大；未知 style 落灰：三通道接近
      expect(colors[0]!.g, greaterThan(colors[0]!.r));
      expect(colors[1]!.r, greaterThan(colors[1]!.g));
      expect((colors[2]!.r - colors[2]!.g).abs(), lessThan(12));
      expect((colors[2]!.g - colors[2]!.b).abs(), lessThan(12));
    });

    testWidgets('点按钮：上报 + 请求期间显示"处理中..."', (tester) async {
      final h = await bootChat();
      await pumpList(tester, [_docAttachment], harness: h);
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        _postWith([_docAttachment]),
      ]);
      // 让请求停一会儿，好观察"处理中"这个中间态
      h.transport.responseDelay = const Duration(milliseconds: 200);

      await tester.tap(find.text('OK'));
      await tester.pump(); // 触发回调，进入 pending
      expect(find.text('处理中...'), findsOneWidget);
      expect(find.text('OK'), findsNothing, reason: '转圈期间按钮收起来（原版同款）');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      final call = h.transport.calls.lastWhere(
        (c) =>
            '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.Attachment.trigger',
      );
      final payload = jsonDecode('${call['payload']}') as Map<String, dynamic>;
      expect(payload['idx'], 0);
      expect(payload['callback_id'], 'abc');
      expect(find.text('处理中...'), findsNothing, reason: '请求回来要收起来');
    });

    testWidgets('没有附件时什么都不画', (tester) async {
      await pumpList(tester, null);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });
}
