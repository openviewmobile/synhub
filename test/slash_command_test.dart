// Phase 9：斜杠命令（`SYNO.Chat.Webhook.Slash / execute`）。
//
// 逐条对上原版 `SlashUtil` + `ChannelFragment.onCreatePost` +
// `ChannelPresenter.createConferenceSlashCommand`：
//   * 只有 `/jumpchat` / `/jitsi` 开头（且**未加密**频道）才走接口，不发普通消息；
//   * `message` 是**裸文本**、`user_id` 是匹配到的斜杠机器人；
//   * 没有匹配机器人时原版会静默什么都不做 —— 我们**也不发消息**，但给一句提示；
//   * 普通 `/xxx` 或加密频道 → 还是普通 `Post/create`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/slash_command.dart';
import 'package:synhub/src/features/settings/e2ee_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

UserDto _slashBot({int id = 7, String cmd = 'jitsi'}) => UserDto.fromJson({
  'user_id': id,
  'username': cmd,
  'type': 'bot',
  // 真机 wire：`bot_type` 在顶层，`slash_props.cmd` 是命令名
  'bot_type': 'slash',
  'slash_props': {
    'cmd': cmd,
    'description': 'webhook_builtin:desc_conference_jitsi',
  },
});

Widget _app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('SlashUtil（纯函数，照抄原版）', () {
    test('只有 /jumpchat 与 /jitsi 算"起会议"命令', () {
      expect(isConferenceSlashFormat('/jitsi'), isTrue);
      expect(isConferenceSlashFormat('/jitsi 周会'), isTrue);
      expect(isConferenceSlashFormat('/jumpchat https://meet'), isTrue);
      expect(
        isConferenceSlashFormat('/jitsiXXX'),
        isTrue,
        reason: '原版就是 startsWith',
      );
      expect(isConferenceSlashFormat('/other'), isFalse);
      expect(isConferenceSlashFormat('jitsi'), isFalse);
      expect(isConferenceSlashFormat(''), isFalse);
    });

    test('parseSlashCommandFromMessage：取第一个词的命令名', () {
      expect(parseSlashCommandFromMessage('/jitsi 周会'), 'jitsi');
      expect(parseSlashCommandFromMessage('/jumpchat'), 'jumpchat');
      expect(parseSlashCommandFromMessage('/'), '');
      expect(parseSlashCommandFromMessage('普通消息'), '');
    });

    test('findSlashBot：按 slash_cmd 全等匹配，非斜杠机器人不算', () {
      final bots = [_slashBot(), _slashBot(id: 8, cmd: 'jumpchat')];
      expect(findSlashBot(bots, '/jitsi 周会')!.userId, 7);
      expect(findSlashBot(bots, '/jumpchat https://x')!.userId, 8);
      expect(findSlashBot(bots, '/unknown'), isNull);
      final human = UserDto.fromJson({
        'user_id': 3,
        'username': 'k',
        'type': 'human',
      });
      expect(findSlashBot([human], '/jitsi'), isNull);
    });
  });

  group('API 形状', () {
    test('Webhook.Slash/execute v1：channel_id + 裸 message + user_id', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Webhook.Slash.execute'] = const {};
      final api = h.container
          .read(chatSessionControllerProvider.notifier)
          .chatApi!;
      await api.executeSlashCommand(
        channelId: 5,
        message: '/jitsi 周会',
        userId: 7,
      );

      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.Webhook.Slash',
      );
      expect(call['method'], 'execute');
      expect(call['version'], '1');
      expect(call['channel_id'], '5');
      expect(call['message'], '/jitsi 周会', reason: '原版传裸文本，不是 Gson 串');
      expect(call['user_id'], '7');
    });

    test('控制器：失败返回 false', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Webhook.Slash.execute'] = 407;
      final ok = await h.ctrl.executeSlashCommand(
        channelId: 5,
        message: '/jitsi',
        botUserId: 7,
      );
      expect(ok, isFalse);
    });
  });

  group('发送分流（ChannelFragment.onCreatePost）', () {
    testWidgets('/jitsi 且频道未加密 + 有机器人 → 不发普通消息，走 execute', (tester) async {
      final h = await bootChat(
        extra: {'SYNO.Chat.Webhook.Slash.execute': const {}},
      );
      // 本地放一个斜杠机器人（页面从本地用户表读）
      await h.container.read(chatStoreProvider).upsertUsers([_slashBot()]);

      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '/jitsi 周会');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send));
      await _settle(tester);

      expect(
        h.transport.calls.where(
          (c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'create',
        ),
        isEmpty,
        reason: '起会议不该再发一条普通消息',
      );
      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.Webhook.Slash',
      );
      expect(call['message'], '/jitsi 周会');
      expect(call['user_id'], '7');
    });

    testWidgets('加密频道里的 /jitsi 仍然发普通消息（原版 !encrypted 判断）', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                'channel_id': 5,
                'name': '加密频道',
                'type': 'private',
                'encrypted': true,
              },
            ],
          },
          'SYNO.Chat.Post.create': {
            'post_id': 4242,
            'channel_id': 5,
            'creator_id': 14,
            'create_at': 4000,
            'type': 'normal',
            'message': '/jitsi 周会',
          },
        },
      );
      // 给 E2EE 服务配上频道密钥，这样普通发送能真的走通
      await h.container.read(e2eeControllerProvider.notifier).setup('p');
      h.container
          .read(e2eeServiceProvider)
          .putChannelKey(5, List.filled(32, 7));
      await h.container.read(chatStoreProvider).upsertUsers([_slashBot()]);

      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '/jitsi 周会');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send));
      await _settle(tester);

      expect(
        h.transport.calls.where((c) => c['api'] == 'SYNO.Chat.Webhook.Slash'),
        isEmpty,
        reason: '加密频道不走斜杠命令',
      );
      // 走的是普通发送：请求体是密文（不是原文）
      final create = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'create',
      );
      expect(create['message'], isNot('/jitsi 周会'));
      expect(create['message'], isA<String>());
    });

    testWidgets('普通 /other 还是普通消息', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.create': {
            'post_id': 4243,
            'channel_id': 5,
            'creator_id': 14,
            'create_at': 4000,
            'type': 'normal',
            'message': '/other 你好',
          },
        },
      );
      await h.container.read(chatStoreProvider).upsertUsers([_slashBot()]);

      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '/other 你好');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send));
      await _settle(tester);

      expect(
        h.transport.calls.where((c) => c['api'] == 'SYNO.Chat.Webhook.Slash'),
        isEmpty,
      );
      expect(
        h.transport.calls.where(
          (c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'create',
        ),
        isNotEmpty,
      );
    });

    testWidgets('有 /jitsi 前缀但没有对应机器人 → 不发任何请求，给提示', (tester) async {
      final h = await bootChat();
      // 只有 jumpchat 机器人，没有 jitsi
      await h.container.read(chatStoreProvider).upsertUsers([
        _slashBot(id: 8, cmd: 'jumpchat'),
      ]);

      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '/jitsi 周会');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send));
      await _settle(tester);

      expect(
        h.transport.calls.where((c) => c['api'] == 'SYNO.Chat.Webhook.Slash'),
        isEmpty,
      );
      expect(
        h.transport.calls.where(
          (c) => c['api'] == 'SYNO.Chat.Post' && c['method'] == 'create',
        ),
        isEmpty,
        reason: '原版这种情况下什么都不发（我们也不发，只多给一句提示）',
      );
      expect(find.textContaining('没有找到'), findsOneWidget);
    });
  });
}
