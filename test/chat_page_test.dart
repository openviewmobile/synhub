// ChatPage 的离线 UI 验证：真的把页面挂起来，喂本地数据 + 假发送接口。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/core/ui/hud_widgets.dart';
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
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('渲染消息：别人的消息显示名字、自己的显示在右侧、系统消息居中', (tester) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Post.list': {
          'posts': [testPostJson],
        },
      },
    );
    final store = h.container.read(chatStoreProvider);
    await store.upsertPosts(const [
      PostDto(
        postId: 10,
        channelId: 5,
        creatorId: 14,
        message: '我自己发的话',
        createAt: 1700000000000,
      ),
      PostDto(
        postId: 11,
        channelId: 5,
        creatorId: 3,
        message: '别人说的话',
        createAt: 1700000060000,
      ),
      PostDto(
        postId: 12,
        channelId: 5,
        creatorId: 1,
        type: 'system',
        createAt: 1700000120000,
        systemProps: {'event': 'channel.join', 'effective_user_id': 4},
      ),
    ]);

    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);

    expect(find.text('我自己发的话'), findsOneWidget);
    expect(find.text('别人说的话'), findsOneWidget);
    expect(find.text('用户 4 加入了此频道。'), findsOneWidget);
    // 自己的消息不显示发送者名，别人的显示
    expect(find.text('用户 3'), findsOneWidget);
  });

  testWidgets('空频道显示占位文案', (tester) async {
    final h = await bootChat();
    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);
    expect(find.text('还没有消息'), findsOneWidget);
  });

  testWidgets('输入并发送：本地立刻出现该消息，输入框清空', (tester) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Post.create': {
          'post_id': 4294967600,
          'channel_id': 5,
          'creator_id': 14,
          'create_at': 4000,
          'type': 'normal',
          'message': '你好 NAS',
        },
      },
    );

    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);

    await tester.enterText(find.byType(TextField), '你好 NAS');
    // 输入框空时按钮是"麦克风"、有文字才变"发送"（形态切换球），
    // 所以要等一帧让 morph 完成再点
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await _settle(tester);

    expect(find.text('你好 NAS'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );

    final posts = await h.container.read(chatStoreProvider).postsForChannel(5);
    expect(posts.single.postId, 4294967600, reason: '乐观行已被服务端行替换');
  });

  testWidgets('发送中的消息带时钟图标，失败/过期带错误图标', (tester) async {
    final h = await bootChat();
    final store = h.container.read(chatStoreProvider);

    // 先进频道（`enterChannel` 会把"上一轮没发出去"的消息标成过期 state=3），
    // 再插这两条 —— 这样测的是纯渲染：1 = 发送中（时钟），2 = 失败（红叹号）。
    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);

    await store.upsertPosts(const [
      PostDto(
        postId: 0,
        channelId: 5,
        creatorId: 14,
        message: '发送中',
        createAt: 5000,
        tmpPostId: 5000,
        state: 1,
      ),
      PostDto(
        postId: 0,
        channelId: 5,
        creatorId: 14,
        message: '失败了',
        createAt: 6000,
        tmpPostId: 6000,
        state: 2,
      ),
      PostDto(
        postId: 0,
        channelId: 5,
        creatorId: 14,
        message: '过期了',
        createAt: 7000,
        tmpPostId: 7000,
        state: 3,
      ),
    ]);
    await _settle(tester);

    // 发送中不再是"闹钟"图标，而是扫描环（ScanRing）
    expect(find.byType(ScanRing), findsOneWidget, reason: 'state 1 = 发送中');
    // state 2 与 3 都画红叹号（原版 `state() == 2 || state() == 3`）
    expect(find.byIcon(Icons.error_outline), findsNWidgets(2));
  });

  testWidgets('未就绪时输入框禁用（connId 为空）', (tester) async {
    final h = await bootChat(healthy: false);
    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
    expect(find.text('实时通道未就绪'), findsOneWidget);
  });
}
