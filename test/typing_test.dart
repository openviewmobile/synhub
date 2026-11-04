// 「正在输入」：收（typing_v2 / 老 typing）+ 发（10 秒节流 + 自动 clear）+ UI 文案。
//
// 对齐原版：
//   * `SocketHelper.lambda$socketIO$7` → `TypingVo{channel_id, "0": [ids]}`，
//     处理前先把自己 remove 掉；
//   * `ChannelPresenter.typing()`：`mTyping` 状态机，10 秒内只发一次，
//     10 秒后自动 `client.user.clear_typing`；
//   * `ChannelFragment.showTyping()` 的三档文案 + LoadingDots。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/data/remote/socket/socket_events.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/typing_notifier.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 一个"我在 14、别人 4/6"的环境
Future<ChatHarness> _boot() => bootChat(
  extra: {
    'SYNO.Chat.User.list': {
      'users': [
        {'user_id': 14, 'username': 'me', 'type': 'human'},
        {'user_id': 4, 'username': 'demo', 'nickname': 'demo', 'type': 'human'},
        {
          'user_id': 6,
          'username': 'demo_user',
          'nickname': 'demo_user',
          'type': 'human',
        },
      ],
    },
  },
);

void main() {
  group('收 typing', () {
    test('typing_v2：{channel_id, "0": [ids]}，剔除自己', () async {
      final h = await _boot();
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
          'channel_id': 5,
          '0': [4, 14, 6],
        }),
      );
      expect(h.container.read(typingUsersProvider(5)), [4, 6]);
      expect(h.container.read(typingUsersProvider(6)), isEmpty);
    });

    test('老协议 typing：{"<channelId>": [ids]}', () async {
      final h = await _boot();
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelTyping, {
          '5': [4],
          '7': <int>[6, 14],
        }),
      );
      expect(h.container.read(typingUsersProvider(5)), [4]);
      expect(h.container.read(typingUsersProvider(7)), [6]);
    });

    test('空列表 = 停止输入，把状态清掉', () async {
      final h = await _boot();
      final typing = h.container.read(typingProvider.notifier);
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
          'channel_id': 5,
          '0': [4],
        }),
      );
      expect(h.container.read(typingUsersProvider(5)), [4]);
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
          'channel_id': 5,
          '0': <int>[],
        }),
      );
      expect(h.container.read(typingUsersProvider(5)), isEmpty);
      typing.clear();
    });

    test('只有我自己在输入 → 不显示', () async {
      final h = await _boot();
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
          'channel_id': 5,
          '0': [14],
        }),
      );
      expect(h.container.read(typingUsersProvider(5)), isEmpty);
      h.container.read(typingProvider.notifier).clear();
    });

    test('缺 channel_id / 载荷不是 list 时不炸也不写状态', () async {
      final h = await _boot();
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
          '0': [4],
        }),
      );
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
          'channel_id': 5,
          '0': 'x',
        }),
      );
      expect(h.container.read(typingProvider), isEmpty);
    });
  });

  group('typing TTL（防丢事件后一直挂着）', () {
    testWidgets('12 秒没动静自动消失', (tester) async {
      final h = await _boot();
      await tester.runAsync(() async {
        await h.ctrl.handleEvent(
          ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
            'channel_id': 5,
            '0': [4],
          }),
        );
      });
      expect(h.container.read(typingUsersProvider(5)), [4]);

      // Provider 里的 Timer 是真实计时器，用 runAsync 等过去
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 13000)),
      );
      expect(h.container.read(typingUsersProvider(5)), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  group('发 typing：10 秒节流 + 自动 clear（原版 mTyping 状态机）', () {
    testWidgets('连敲多个字只发一条 typing，10 秒后自动 clear', (tester) async {
      final h = await _boot();
      await tester.runAsync(() async {
        final ctrl = h.ctrl;
        ctrl.typing();
        ctrl.typing();
        ctrl.typing();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          h.socket.emitCount(SocketEvent.clientUserTyping),
          1,
          reason: '窗口内重复调用不应该重复发',
        );
        expect(h.socket.emitCount(SocketEvent.clientUserClearTyping), 0);

        await Future<void>.delayed(
          const Duration(milliseconds: 10 * 1000 + 300),
        );
        expect(h.socket.emitCount(SocketEvent.clientUserClearTyping), 1);

        // 复位之后可以再发
        ctrl.typing();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(h.socket.emitCount(SocketEvent.clientUserTyping), 2);
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('clearTyping() 立刻发 clear，且没发过就不发', (tester) async {
      final h = await _boot();
      await tester.runAsync(() async {
        h.ctrl.clearTyping();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          h.socket.emitCount(SocketEvent.clientUserClearTyping),
          0,
          reason: '没说过"我在输入"就别发 clear',
        );

        h.ctrl.typing();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        h.ctrl.clearTyping();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(h.socket.emitCount(SocketEvent.clientUserTyping), 1);
        expect(h.socket.emitCount(SocketEvent.clientUserClearTyping), 1);
      });
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  group('UI 文案（原版三档 + 加粗名字）', () {
    Future<void> pumpChat(WidgetTester tester, ChatHarness h) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: 5)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('1:1 会话显示名字', (tester) async {
      final h = await bootChat(
        extra: {
          // 匿名会话（type=anonymous）+ 两个人（我 + demo）
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                ...testChannelJson,
                'channel_id': 5,
                'type': 'anonymous',
                'name': '',
                'members': [14, 4],
                'total_member_count': 2,
              },
            ],
          },
          'SYNO.Chat.Channel.Member': {
            'user_ids': [14, 4],
            'broken_user_ids': <int>[],
          },
          'SYNO.Chat.User.list': {
            'users': [
              {'user_id': 14, 'username': 'me', 'type': 'human'},
              {
                'user_id': 4,
                'username': 'demo',
                'nickname': 'demo',
                'type': 'human',
              },
            ],
          },
        },
      );
      await pumpChat(tester, h);
      await tester.runAsync(() async {
        await h.ctrl.handleEvent(
          ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
            'channel_id': 5,
            '0': [4],
          }),
        );
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('demo 正在输入'), findsOneWidget);
      h.container.read(typingProvider.notifier).clear();
    });

    testWidgets('群里 1 个人 → 「1 个人正在输入」；3 个人 → 「3 个人正在输入」', (tester) async {
      final h = await _boot();
      await pumpChat(tester, h);
      await tester.runAsync(() async {
        await h.ctrl.handleEvent(
          ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
            'channel_id': 5,
            '0': [4],
          }),
        );
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('1 个人正在输入'), findsOneWidget);
      expect(find.textContaining('demo 正在输入'), findsNothing);

      await tester.runAsync(() async {
        await h.ctrl.handleEvent(
          ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
            'channel_id': 5,
            '0': [4, 6, 13],
          }),
        );
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('3 个人正在输入'), findsOneWidget);

      await tester.runAsync(() async {
        await h.ctrl.handleEvent(
          ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
            'channel_id': 5,
            '0': <int>[],
          }),
        );
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('正在输入'), findsNothing);
    });

    testWidgets('不是匿名会话就算名字能取到也走通用文案（原版同此）', (tester) async {
      // testChannelJson 是 public 频道
      final h = await _boot();
      await pumpChat(tester, h);
      await tester.runAsync(() async {
        await h.ctrl.handleEvent(
          ChatSocketEvent(SocketEvent.clientChannelTypingV2, {
            'channel_id': 5,
            '0': [4],
          }),
        );
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('1 个人正在输入'), findsOneWidget);
      h.container.read(typingProvider.notifier).clear();
    });
  });
}
