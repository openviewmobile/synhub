// 点 @提及 → 资料弹窗 → 「发消息」开一对一（用户报告第 2 条）。
//
// 证据（官方 `Android-SynologyChat 2.11.1-607`）：
//   * `MentionUtil` 把提及画成可点 chip；点击走 `ProfileFragment.newInstance(userId)`；
//   * `ProfileFragment` 的资料来自本地用户表（`AccountManager.queryUser`）；
//   * 底部「发消息」= `ProfilePresenter.initiateAnonymous` →
//     `SYNO.Chat.Channel.Anonymous / initiate` v1（`user_ids`/`channel_key_encs`/`encrypted`）。
//
// 修复前：`chat_page` 的 `onMention` 只 `showSnackBar('@名字（user_id=…）')`，
// 既不开资料、也没有聊天入口 ⇒ 下面第 1/2 条用例在修复前必失败。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
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

const _users = {
  'users': [
    {'user_id': 14, 'username': 'me', 'type': 'human', 'status': 'online'},
    {
      'user_id': 3,
      'username': 'bob',
      'nickname': '小波',
      'type': 'human',
      'status': 'online',
      'user_props': {
        'email': 'bob@example.com',
        'description': '测试简介',
        'timezoneUTC': 'Asia/Shanghai',
      },
    },
  ],
};

void main() {
  testWidgets('点 @提及 → 打开资料（真字段）+「发消息」走 Channel.Anonymous/initiate', (
    tester,
  ) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.User.list': _users,
        'SYNO.Chat.Channel.Anonymous.initiate': {
          'channel': {
            'channel_id': 60,
            'type': 'anonymous',
            'is_joined': true,
            'members': [3, 14],
          },
        },
      },
    );
    await h.container.read(chatStoreProvider).upsertPosts([
      PostDto(
        postId: 100,
        channelId: 5,
        creatorId: 14,
        message: '@u:3 你好',
        mentions: const [3],
      ),
    ]);

    final pushed = <String>[];
    final router = GoRouter(
      initialLocation: '/chat/5',
      routes: [
        GoRoute(
          path: '/chat/:channelId',
          builder: (_, state) {
            pushed.add(state.uri.toString());
            return ChatPage(
              channelId: int.parse(state.pathParameters['channelId']!),
            );
          },
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await _settle(tester);

    // `@u:3` 还原成 `@bob`，而且可点
    expect(find.textContaining('@bob'), findsOneWidget);
    await tester.tap(find.textContaining('@bob'));
    await _settle(tester);

    // 资料弹窗显示服务端事实字段（不是占位）
    expect(find.text('小波'), findsWidgets);
    expect(find.text('账号：bob　ID：#3'), findsOneWidget);
    expect(find.text('邮箱：bob@example.com'), findsOneWidget);
    expect(find.text('简介：测试简介'), findsOneWidget);
    expect(find.text('时区：Asia/Shanghai'), findsOneWidget);
    expect(find.text('发消息'), findsOneWidget);

    await tester.tap(find.text('发消息'));
    await _settle(tester);

    final call = h.transport.calls.firstWhere(
      (c) => c['api'] == 'SYNO.Chat.Channel.Anonymous',
    );
    expect(call['method'], 'initiate');
    expect(call['version'], '1');
    expect(call['user_ids'], '[3,14]', reason: '顺序必须是 [对方, 我]');
    expect(call['encrypted'], 'false');
    expect(pushed, contains('/chat/60'), reason: '开完会话要进聊天页');
  });

  testWidgets('提及解析不出 user_id 时 → 显示名字 + 「资料不可用」而不是死点击', (
    tester,
  ) async {
    final h = await bootChat(extra: {'SYNO.Chat.User.list': _users});
    await h.container.read(chatStoreProvider).upsertPosts([
      PostDto(postId: 101, channelId: 5, creatorId: 14, message: '@ghost 在吗'),
    ]);

    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);

    await tester.tap(find.textContaining('@ghost'));
    await _settle(tester);

    expect(find.text('ghost'), findsOneWidget);
    expect(find.textContaining('资料不可用'), findsOneWidget);
    // 解析不出人就不该出现「发消息」
    expect(find.text('发消息'), findsNothing);
  });
}
