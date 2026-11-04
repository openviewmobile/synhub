// Phase 4 的 UI 验证：长按操作面板、表情回应聚合、话题页收发。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/thread_page.dart';

import 'package:synhub/src/core/settings/server_settings.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Widget _app(ProviderContainer c, Widget child) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: child),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 等底部面板/对话框的动画跑完（假 socket 是 broadcast 流，不会让这里挂住）
Future<void> _settleSheet(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
}

void main() {
  group('aggregateReactions', () {
    test('同一种回应聚合成一个计数', () {
      // 服务端存的是 emojione 短代码，展示时转成字符
      final out = aggregateReactions(const [
        {'post_id': 1, 'sticker_name': 'thumbsup', 'user_id': 3},
        {'post_id': 1, 'sticker_name': 'thumbsup', 'user_id': 4},
        {'post_id': 1, 'sticker_name': 'heart', 'user_id': 5},
      ], myUserId: 14);
      expect(out.length, 2);
      expect(out[0].label, '👍');
      expect(out[0].count, 2);
      expect(out[0].mine, isFalse);
      expect(out[1].label, '❤');
    });

    test('真机载荷：一条记录 + user_ids 数组（人数就是次数）', () {
      final out = aggregateReactions(const [
        {
          'post_id': 4294967322,
          'sticker_name': 'thumbsup',
          'user_ids': [14, 3, 4],
        },
        {
          'sticker_name': 'joy',
          'user_ids': [3],
        },
      ], myUserId: 14);
      expect(out.length, 2);
      expect(out[0].label, '👍');
      expect(out[0].count, 3, reason: 'user_ids 有几个人就是几次');
      expect(out[0].mine, isTrue);
      expect(out[1].label, '😂');
      expect(out[1].mine, isFalse);
    });

    test('表里没有的名字（自定义贴纸）原样显示', () {
      final out = aggregateReactions(const [
        {'sticker_name': 'my_custom_sticker', 'user_id': 3},
      ], myUserId: 14);
      expect(out.single.label, 'my_custom_sticker');
    });

    test('标出自己点过的那个', () {
      final out = aggregateReactions(const [
        {'sticker_name': 'thumbsup', 'user_id': 14},
      ], myUserId: 14);
      expect(out.single.mine, isTrue);
    });

    test('没有 sticker_name 时用 sticker_id 兜底（贴纸 Phase 6 再接）', () {
      final out = aggregateReactions(const [
        {'sticker_id': 81, 'user_id': 3},
      ], myUserId: 14);
      expect(out.single.label, contains('81'));
    });
  });

  testWidgets('长按消息 → 操作面板 → 星标调用服务端', (tester) async {
    final h = await bootChat();
    await h.container.read(chatStoreProvider).upsertPosts(const [
      PostDto(
        postId: 4294967300,
        channelId: 5,
        creatorId: 3,
        message: '给我点星标',
        createAt: 1700000000000,
      ),
    ]);

    await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
    await _settle(tester);

    await tester.longPress(find.text('给我点星标'));
    await _settleSheet(tester);
    expect(find.text('星标'), findsOneWidget);
    expect(find.text('回复话题'), findsOneWidget);
    expect(find.text('编辑'), findsNothing, reason: '别人的消息不能编辑');

    await tester.ensureVisible(find.text('星标'));
    await tester.tap(find.text('星标'));
    await _settle(tester);

    expect(
      h.transport.calls.any(
        (c) =>
            '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.star' &&
            c['post_id'] == '4294967300',
      ),
      isTrue,
    );
    final post = await h.container
        .read(chatStoreProvider)
        .postById(5, 4294967300);
    expect(post!.isStar, isTrue);
  });

  testWidgets('自己的消息才有编辑/删除', (tester) async {
    final h = await bootChat();
    await h.container.read(chatStoreProvider).upsertPosts(const [
      PostDto(
        postId: 7,
        channelId: 5,
        creatorId: 14,
        message: '我自己的话',
        createAt: 1700000000000,
      ),
    ]);

    await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
    await _settle(tester);
    await tester.longPress(find.text('我自己的话'));
    await _settleSheet(tester);

    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('服务端关掉编辑（allow_edit_message=false）→ 面板里没有「编辑」', (tester) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Admin.Setting.get': const {
          'allow_edit_message': false,
          'allow_edit_message_time_within_min': -1,
          'allow_encryption': true,
        },
      },
    );
    await h.container.read(chatStoreProvider).upsertPosts(const [
      PostDto(
        postId: 11,
        channelId: 5,
        creatorId: 14,
        message: '这条不让改',
        createAt: 1700000000000,
      ),
    ]);
    // 等登录时那次 Setting/get 落进状态
    for (
      var i = 0;
      i < 100 && h.container.read(serverSettingsProvider).allowEditMessage;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(h.container.read(serverSettingsProvider).allowEditMessage, isFalse);

    await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
    await _settle(tester);
    await tester.longPress(find.text('这条不让改'));
    await _settleSheet(tester);

    expect(find.text('编辑'), findsNothing);
    expect(find.text('删除'), findsOneWidget, reason: '删除不受编辑窗口影响');
  });

  testWidgets('窗口过期（15 分钟前发的）→ 没有「编辑」；刚发的有', (tester) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Admin.Setting.get': const {
          'allow_edit_message': true,
          'allow_edit_message_time_within_min': 15,
        },
      },
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    await h.container.read(chatStoreProvider).upsertPosts([
      PostDto(
        postId: 21,
        channelId: 5,
        creatorId: 14,
        message: '很久以前发的',
        createAt: now - 16 * 60000,
      ),
      PostDto(
        postId: 22,
        channelId: 5,
        creatorId: 14,
        message: '刚发的',
        createAt: now - 60000,
      ),
    ]);
    for (
      var i = 0;
      i < 100 &&
          h.container.read(serverSettingsProvider).editMessageTimeWithinMin !=
              15;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
    await _settle(tester);

    await tester.longPress(find.text('很久以前发的'));
    await _settleSheet(tester);
    expect(find.text('编辑'), findsNothing, reason: '超出 15 分钟窗口');
    await tester.tapAt(const Offset(20, 20)); // 关掉面板
    await _settleSheet(tester);

    await tester.longPress(find.text('刚发的'));
    await _settleSheet(tester);
    expect(find.text('编辑'), findsOneWidget);
  });

  testWidgets('回应行显示聚合结果', (tester) async {
    final h = await bootChat();
    await h.container.read(chatStoreProvider).upsertPosts(const [
      PostDto(
        postId: 8,
        channelId: 5,
        creatorId: 3,
        message: '有回应的消息',
        createAt: 1700000000000,
        reactions: [
          {'sticker_name': 'thumbsup', 'user_id': 3},
          {'sticker_name': 'thumbsup', 'user_id': 4},
        ],
      ),
    ]);

    await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
    await _settle(tester);
    expect(find.text('👍 2'), findsOneWidget);
  });

  testWidgets('有回复的消息显示「N 条回复」并可进入话题页', (tester) async {
    final h = await bootChat();
    await h.container.read(chatStoreProvider).upsertPosts(const [
      PostDto(
        postId: 100,
        channelId: 5,
        creatorId: 3,
        message: '带回复的主消息',
        createAt: 1700000000000,
        commentCount: 2,
      ),
      PostDto(
        postId: 101,
        channelId: 5,
        creatorId: 4,
        message: '第一条回复',
        createAt: 1700000001000,
        threadId: 100,
      ),
      PostDto(
        postId: 102,
        channelId: 5,
        creatorId: 5,
        message: '第二条回复',
        createAt: 1700000002000,
        threadId: 100,
      ),
    ]);

    await tester.pumpWidget(_app(h.container, const ChatPage(channelId: 5)));
    await _settle(tester);
    expect(find.text('2 条回复'), findsOneWidget);
    expect(find.text('第一条回复'), findsNothing, reason: '回复不混进主列表');
  });

  testWidgets('话题页：渲染原消息与回复，并能发新回复', (tester) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Post.create': {
          'post_id': 4294967501,
          'channel_id': 5,
          'creator_id': 14,
          'create_at': 3000,
          'thread_id': 100,
          'type': 'normal',
          'message': '我也来说一句',
        },
        'SYNO.Chat.Post.list': {
          'posts': [
            {
              'post_id': 101,
              'channel_id': 5,
              'creator_id': 4,
              'create_at': 1700000001000,
              'thread_id': 100,
              'type': 'normal',
              'message': '已有回复',
            },
          ],
        },
        'SYNO.Chat.Post.Subscribe.view': {'last_view_comment_at': 5555},
      },
    );
    await h.container.read(chatStoreProvider).upsertPosts(const [
      PostDto(
        postId: 100,
        channelId: 5,
        creatorId: 3,
        message: '原消息',
        createAt: 1700000000000,
        commentCount: 1,
      ),
    ]);

    await tester.pumpWidget(
      _app(h.container, const ThreadPage(channelId: 5, parentPostId: 100)),
    );
    await _settle(tester);

    // 页头标签 + 正文各一次
    expect(find.text('原消息'), findsNWidgets(2));
    // 话题页拉过 Post/list（thread_id=100）
    expect(
      h.transport.calls.any(
        (c) =>
            '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.list' &&
            c['thread_id'] == '100',
      ),
      isTrue,
    );
    // 已读上报
    expect(
      h.transport.calls.any(
        (c) =>
            '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.Subscribe.view' &&
            c['thread_id'] == '100',
      ),
      isTrue,
    );

    await tester.enterText(find.byType(TextField), '我也来说一句');
    await tester.tap(find.byIcon(Icons.send));
    await _settle(tester);

    final reply =
        (await h.container
                .read(chatStoreProvider)
                .postsForChannel(5, threadId: 100))
            .firstWhere((p) => p.message == '我也来说一句');
    expect(reply.postId, 4294967501);
    expect(reply.threadId, 100);

    final parent = await h.container.read(chatStoreProvider).postById(5, 100);
    expect(parent!.commentCount, 2, reason: '父消息回复数 +1');
  });

  testWidgets('话题页长按回复可删除', (tester) async {
    final h = await bootChat();
    await h.container.read(chatStoreProvider).upsertPosts(const [
      PostDto(
        postId: 100,
        channelId: 5,
        creatorId: 3,
        message: '原消息',
        createAt: 1,
      ),
      PostDto(
        postId: 102,
        channelId: 5,
        creatorId: 14,
        message: '我的回复',
        createAt: 2,
        threadId: 100,
      ),
    ]);

    await tester.pumpWidget(
      _app(h.container, const ThreadPage(channelId: 5, parentPostId: 100)),
    );
    await _settle(tester);

    await tester.longPress(find.text('我的回复'));
    await _settleSheet(tester);
    await tester.ensureVisible(find.text('删除'));
    await tester.tap(find.text('删除'));
    await _settle(tester);

    expect(
      h.transport.calls.any(
        (c) =>
            '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.delete' &&
            c['post_id'] == '102',
      ),
      isTrue,
    );
    expect(await h.container.read(chatStoreProvider).postById(5, 102), isNull);
  });
}
