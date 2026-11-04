// Phase 9：`SYNO.Chat.Channel / enter`（进频道时告诉服务端"这条 conn 正在看它"）。
//
// 对齐原版：
//   * `AccountManager.enterChannel` → 版本 `getMaxAvailableVersion(2, 1)`（写死 2），
//     参数 `channel_id` + **Gson 编码的** `conn_id`；
//   * 没有 conn_id → 原版 `ApiException.emptyConnId`（code 101），**不发请求**；
//   * `ChannelFragment.enterChannel()` 里每次进频道页都调，成功后再拉 hashtags；
//     我们由标签页自己拉，控制器这边只负责 enter；
//   * 失败只记日志，不影响读消息。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

List<Map<String, dynamic>> _callsTo(
  FakeTransport t,
  String api,
  String method,
) => t.calls.where((c) => c['api'] == api && c['method'] == method).toList();

Widget _app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
);

void main() {
  group('ChatApi.enterChannel', () {
    test('v2：channel_id + Gson 编码的 conn_id', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Channel.enter'] = const {};
      await h.ctrl.chatApi!.enterChannel(5, 'conn-1');

      final call = _callsTo(h.transport, 'SYNO.Chat.Channel', 'enter').single;
      expect(call['version'], '2', reason: '原版写死 getMaxAvailableVersion(2,1)');
      expect(call['channel_id'], '5');
      expect(call['conn_id'], '"conn-1"', reason: 'conn_id 是 Gson 串（带引号）');
    });

    test('conn_id 为空 → 抛 101，且一个请求都不发', () async {
      final h = await bootChat();
      await expectLater(
        h.ctrl.chatApi!.enterChannel(5, ''),
        throwsA(
          predicate(
            (e) => e is DsmApiException && e.code == DsmErrorCode.badRequest,
          ),
        ),
      );
      expect(_callsTo(h.transport, 'SYNO.Chat.Channel', 'enter'), isEmpty);
    });
  });

  group('控制器 enterChannel', () {
    test('有 conn_id → 成功', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Channel.enter'] = const {};
      expect(await h.ctrl.enterChannel(5), isTrue);
      expect(_callsTo(h.transport, 'SYNO.Chat.Channel', 'enter'), hasLength(1));
    });

    test('实时通道没建起来（connId=null）→ 不发请求，返回 false', () async {
      final h = await bootChat(healthy: false);
      expect(await h.ctrl.enterChannel(5), isFalse);
      expect(_callsTo(h.transport, 'SYNO.Chat.Channel', 'enter'), isEmpty);
    });

    test('服务端报错 → 返回 false（不抛，不影响读消息）', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Channel.enter'] = 101;
      expect(await h.ctrl.enterChannel(5), isFalse);
    });
  });

  group('进频道页的顺序', () {
    testWidgets('先 enter，再拉消息，最后标已读', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.list': {'posts': <Map<String, dynamic>>[]},
          'SYNO.Chat.Channel.enter': const {},
          'SYNO.Chat.Channel.view': {'last_view_at': 12345},
        },
      );
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      final order = h.transport.calls
          .where(
            (c) =>
                c['api'] == 'SYNO.Chat.Channel' && c['method'] == 'enter' ||
                c['api'] == 'SYNO.Chat.Post' && c['method'] == 'list' ||
                c['api'] == 'SYNO.Chat.Channel' && c['method'] == 'view',
          )
          .map((c) => '${c['api']}.${c['method']}')
          .toList();
      expect(order.first, 'SYNO.Chat.Channel.enter');
      expect(order, contains('SYNO.Chat.Post.list'));
      expect(
        order.indexOf('SYNO.Chat.Post.list'),
        lessThan(order.indexOf('SYNO.Chat.Channel.view')),
      );
    });
  });
}
