// P0-5：每个频道的消息草稿（原版 `ChatChannelPosting` 表）。
//
// 官方证据：
//   * 建表 `CREATE TABLE IF NOT EXISTS ChatChannelPosting (channel_id INTEGER PRIMARY KEY,
//     posting_text TEXT )`（`Db.java:16-21`）
//   * 读 `DatabaseHelper.queryChannelPostingText`（`:3016-3036`）
//   * 写/删 `DatabaseHelper.saveChannelPostingText`（`:3040-3055`，**空串 = DELETE 行**）
//   * 进频道回填 `ChannelFragment.java:436` `fetchPostingText`
//   * 离开频道落盘 `ChannelFragment.java:582` `savePostingText`
//
// 我们的实现：`SettingsService` 的 KV 层，一个频道一条行
// （key = `chat_posting_text_<channelId>`），语义与官方按 channel_id 读写/删等价。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Widget _app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('SettingsService 草稿行', () {
    test('写入 / 读回 / 空串删行', () async {
      final h = await bootChat();
      final s = h.container.read(settingsServiceProvider);

      expect(await s.channelPostingText(5), '');
      await s.setChannelPostingText(5, '半截草稿');
      expect(await s.channelPostingText(5), '半截草稿');
      // 不同频道互不影响
      await s.setChannelPostingText(6, '另一个频道');
      expect(await s.channelPostingText(5), '半截草稿');
      expect(await s.channelPostingText(6), '另一个频道');

      // 清空 = 删行（原版 saveChannelPostingText 的 empty → DELETE）
      await s.setChannelPostingText(5, '');
      expect(await s.channelPostingText(5), '');
      expect(await s.channelPostingText(6), '另一个频道');
      expect(
        await h.container
            .read(chatStoreProvider)
            .setting('chat_posting_text_5'),
        isNull,
        reason: '空草稿必须删行，而不是留一条空串',
      );
    });
  });

  group('聊天页草稿', () {
    testWidgets('进频道回填草稿', (tester) async {
      final h = await bootChat();
      await h.container
          .read(settingsServiceProvider)
          .setChannelPostingText(5, '上次没发完的');

      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '上次没发完的',
      );
    });

    testWidgets('打字停顿后落盘（onChanged 防抖）', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);

      await tester.enterText(find.byType(TextField), '打了半截');
      // 防抖 300ms 还没到 → 不落盘（证明是"停顿才写"，不是每次 setState 都写）
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        await h.container.read(settingsServiceProvider).channelPostingText(5),
        '',
      );
      await tester.pump(const Duration(milliseconds: 300));
      // 让 unawaited 的 KV 写跑完
      await tester.pumpAndSettle();
      expect(
        await h.container.read(settingsServiceProvider).channelPostingText(5),
        '打了半截',
      );
    });

    testWidgets('发送成功 → 草稿清除；发送失败 → 草稿保留', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.create': {
            'post_id': 4294967600,
            'channel_id': 5,
            'creator_id': 14,
            'create_at': 4000,
            'type': 'normal',
            'message': '发出去的',
          },
        },
      );
      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);

      await tester.enterText(find.byType(TextField), '发出去的');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        await h.container.read(settingsServiceProvider).channelPostingText(5),
        '发出去的',
      );

      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        await h.container.read(settingsServiceProvider).channelPostingText(5),
        '',
        reason: '发送成功必须清掉草稿，否则下次进来又冒出来',
      );

      // 失败路径：服务端 411（太频繁）→ 正文保留在输入框、草稿也保留
      h.transport.failures['SYNO.Chat.Post.create'] = 411;
      await tester.enterText(find.byType(TextField), '失败也不该丢');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        await h.container.read(settingsServiceProvider).channelPostingText(5),
        '失败也不该丢',
      );
    });

    testWidgets('切频道不丢：旧频道落盘、新频道空白', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '属于 5 的草稿');
      await tester.pump(const Duration(milliseconds: 100)); // 防抖没到

      // 同一个 State 被复用但 channelId 变了（`go` 到另一条 /chat/<id>）
      await tester.pumpWidget(_app(h.container, 6));
      await _settle(tester);

      expect(
        await h.container.read(settingsServiceProvider).channelPostingText(5),
        '属于 5 的草稿',
        reason: '换频道必须把旧频道的草稿按旧 id 落盘',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '',
        reason: '新频道没有草稿 → 输入框为空，不能把旧正文带过去',
      );
    });
  });
}
