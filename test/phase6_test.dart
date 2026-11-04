// Phase 6：投票 / 提醒 / 定时消息（离线）。
//
// 真机实测的形状（见 docs/phase6-protocol.md）：
//   * 投票在 `post.props.vote`，`options` 的字段是 `add_option` / `expire_at`；
//   * `Vote/vote` 的 `choice_ids` 是 JSON 数组，返回 `{}`，之后
//     `get_choices` 的 `count`/`voters` 立刻变；
//   * 提醒在 `props.remind_at`，`Reminder/list` 回 `{posts:[...]}`；
//   * 定时消息 `Schedule/create` 回 `{cronjob_id}`，`list` 回 `{schedule_posts:[...]}`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/data/dto/vote_dto.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/notifications/reminder_scheduler.dart';
import 'package:synhub/src/features/chat/vote_card.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Map<String, dynamic> voteProps({
  int c0 = 0,
  int c1 = 0,
  List<int> v0 = const [],
  List<int> v1 = const [],
  bool multiple = false,
  String state = 'open',
  bool addOption = false,
}) => {
  'vote': {
    'choices': [
      {
        'id': 'id-a',
        'text': '面条',
        'count': c0,
        if (v0.isNotEmpty) 'voters': v0,
      },
      {
        'id': 'id-b',
        'text': '米饭',
        'count': c1,
        if (v1.isNotEmpty) 'voters': v1,
      },
    ],
    'options': {
      'multiple': multiple,
      'anonymous': false,
      'add_option': addOption,
      'expire_at': 0,
    },
    'state': state,
  },
};

PostDto votePost(Map<String, dynamic> props) => PostDto.fromJson({
  'post_id': 9001,
  'channel_id': 5,
  'creator_id': 14,
  'create_at': 1700000000000,
  'type': 'normal',
  'message': '午饭吃什么',
  'props': props,
});

void main() {
  group('VoteDto', () {
    test('解析 props.vote（含 voters / options 下划线字段 / state）', () {
      final post = votePost(
        voteProps(c0: 2, v0: [14, 15], multiple: true, addOption: true),
      );
      final vote = post.vote!;
      expect(vote.choices, hasLength(2));
      expect(vote.choices.first.text, '面条');
      expect(vote.choices.first.count, 2);
      expect(vote.choices.first.votedBy(14), isTrue);
      expect(vote.multiple, isTrue);
      expect(vote.addOption, isTrue);
      expect(vote.state, VoteState.open);
      expect(vote.totalVotes, 2);
      expect(vote.chosenBy(14), {'id-a'});
      expect(vote.ratioOf(vote.choices.first), 1.0);
    });

    test('state: close/delete', () {
      expect(votePost(voteProps(state: 'close')).vote!.state, VoteState.closed);
      expect(
        votePost(voteProps(state: 'delete')).vote!.state,
        VoteState.deleted,
      );
      expect(votePost(voteProps(state: 'close')).vote!.isOpen, isFalse);
    });

    test('没有 props.vote 时是 null（普通消息）', () {
      final plain = PostDto.fromJson(const {
        'post_id': 1,
        'channel_id': 5,
        'type': 'normal',
        'props': {'encrypted': false},
      });
      expect(plain.vote, isNull);
      expect(plain.remindAt, 0);
    });

    test('remind_at 从 props 里读', () {
      final p = PostDto.fromJson(const {
        'post_id': 1,
        'channel_id': 5,
        'type': 'normal',
        'props': {'remind_at': 1789602663164},
      });
      expect(p.remindAt, 1789602663164);
    });

    test('ScheduledPostDto 解析 cronjob', () {
      final s = ScheduledPostDto.fromJson(const {
        'cronjob_id': 4,
        'message': '明天的消息',
        // 2100-01-01：用远未来常量，别用会在某天变成过去的固定时间戳（时间炸弹）
        'send_at': 4102444800000,
      });
      expect(s.cronjobId, 4);
      expect(s.message, '明天的消息');
      expect(s.isPending, isTrue, reason: '时间是未来');
    });
  });

  group('建投票 / 投票（协议）', () {
    test('createVote 的参数形状（options 必须下划线）', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Vote.create'] = {
        'post_id': 9100,
        'channel_id': 5,
        'creator_id': 14,
        'create_at': 1,
        'type': 'normal',
        'message': '午饭',
        'props': voteProps(),
      };
      final ok = await h.ctrl.createVote(
        channelId: 5,
        message: '午饭',
        choices: ['面条', '米饭'],
        multiple: true,
        anonymous: true,
        addOption: true,
        expireAt: 1234,
      );
      expect(ok, isTrue);
      final call = h.transport.calls.lastWhere((c) => c['choices'] != null);
      expect(call['channel_id'], '5');
      expect(call['message'], '"午饭"');
      expect(call['choices'], '[{"text":"面条"},{"text":"米饭"}]');
      expect(
        call['options'],
        '{"add_option":true,"anonymous":true,"expire_at":1234,"multiple":true}',
      );
      // 建完要落库
      final post = await h.container.read(chatStoreProvider).postById(5, 9100);
      expect(post!.vote, isNotNull);
    });

    test('castVote 发 JSON 数组，成功后本地 voters 加我', () async {
      final h = await bootChat();
      final post = votePost(voteProps());
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      h.transport.responses['SYNO.Chat.Post.Vote.vote'] = const {};

      final ok = await h.ctrl.castVote(
        channelId: 5,
        post: post,
        choiceIds: const ['id-a'],
      );
      expect(ok, isTrue);
      final call = h.transport.calls.lastWhere((c) => c['choice_ids'] != null);
      expect(call['post_id'], '9001');
      expect(call['choice_ids'], '["id-a"]');

      final updated = await h.container
          .read(chatStoreProvider)
          .postById(5, 9001);
      final vote = updated!.vote!;
      expect(
        vote.choices.first.votedBy(
          h.container.read(chatSessionControllerProvider).myUserId,
        ),
        isTrue,
      );
      expect(vote.choices.first.count, 1);
      expect(vote.totalVotes, 1);
    });

    test('单选换票：旧选项的票要减掉', () async {
      final h = await bootChat();
      final me = h.container.read(chatSessionControllerProvider).myUserId;
      final post = votePost(voteProps(c0: 1, v0: [me]));
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      h.transport.responses['SYNO.Chat.Post.Vote.vote'] = const {};

      await h.ctrl.castVote(
        channelId: 5,
        post: post,
        choiceIds: const ['id-b'],
      );
      final vote =
          (await h.container.read(chatStoreProvider).postById(5, 9001))!.vote!;
      expect(vote.choices[0].count, 0);
      expect(vote.choices[0].voters, isEmpty);
      expect(vote.choices[1].count, 1);
      expect(vote.choices[1].votedBy(me), isTrue);
      expect(vote.totalVotes, 1);
    });

    test('多选：可以同时投两个', () async {
      final h = await bootChat();
      final post = votePost(voteProps(multiple: true));
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      h.transport.responses['SYNO.Chat.Post.Vote.vote'] = const {};
      await h.ctrl.castVote(
        channelId: 5,
        post: post,
        choiceIds: const ['id-a', 'id-b'],
      );
      final vote =
          (await h.container.read(chatStoreProvider).postById(5, 9001))!.vote!;
      expect(vote.totalVotes, 2);
    });

    test('refreshVoteChoices 用 get_choices 覆盖票数', () async {
      final h = await bootChat();
      final post = votePost(voteProps());
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      h.transport.responses['SYNO.Chat.Post.Vote.get_choices'] = {
        'choices': [
          {
            'id': 'id-a',
            'text': '面条',
            'count': 3,
            'voters': [14, 1, 2],
          },
          {
            'id': 'id-b',
            'text': '米饭',
            'count': 1,
            'voters': [3],
          },
        ],
      };
      await h.ctrl.refreshVoteChoices(channelId: 5, post: post);
      final vote =
          (await h.container.read(chatStoreProvider).postById(5, 9001))!.vote!;
      expect(vote.totalVotes, 4);
      expect(vote.choices.first.count, 3);
    });

    test('closeVote 后 state=close（本地也变）', () async {
      final h = await bootChat();
      final post = votePost(voteProps());
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      h.transport.responses['SYNO.Chat.Post.Vote.close'] = const {};
      expect(await h.ctrl.closeVote(channelId: 5, post: post), isTrue);
      final vote =
          (await h.container.read(chatStoreProvider).postById(5, 9001))!.vote!;
      expect(vote.state, VoteState.closed);
      expect(vote.isOpen, isFalse);
    });
  });

  group('投票卡片', () {
    Future<void> pump(WidgetTester tester, ChatHarness h, PostDto post) async {
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: VoteCard(post: post)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('显示选项和票数，点选项会投票', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Vote.vote'] = const {};
      await pump(tester, h, votePost(voteProps(c0: 2, c1: 1)));
      expect(find.text('面条'), findsOneWidget);
      expect(find.text('米饭'), findsOneWidget);
      expect(find.text('3 票'), findsOneWidget);

      await tester.tap(find.text('面条'));
      await tester.pumpAndSettle();
      final call = h.transport.calls.where((c) => c['choice_ids'] != null);
      expect(call, hasLength(1));
      expect(call.first['choice_ids'], '["id-a"]');
    });

    testWidgets('已结束的投票点不动，显示"已结束"', (tester) async {
      final h = await bootChat();
      await pump(tester, h, votePost(voteProps(c0: 2, state: 'close')));
      expect(find.text('已结束'), findsOneWidget);
      await tester.tap(find.text('面条'));
      await tester.pumpAndSettle();
      expect(h.transport.calls.where((c) => c['choice_ids'] != null), isEmpty);
    });

    testWidgets('发起人能看到「更多」菜单（编辑/结束/删除），允许加选项时有「添加选项」', (tester) async {
      final h = await bootChat();
      await pump(tester, h, votePost(voteProps(addOption: true)));
      // 原版把 编辑/结束/删除 收在 action sheet 里，我们收在同一个「更多」菜单
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      expect(find.text('添加选项'), findsOneWidget);
      expect(find.text('看结果'), findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('编辑投票'), findsOneWidget);
      expect(find.text('结束投票'), findsOneWidget);
      expect(find.text('删除投票'), findsOneWidget);
    });

    testWidgets('别人的投票不给「更多」菜单', (tester) async {
      final h = await bootChat();
      final other = PostDto.fromJson({
        'post_id': 9002,
        'channel_id': 5,
        'creator_id': 99,
        'type': 'normal',
        'props': voteProps(),
      });
      await pump(tester, h, other);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
    });

    testWidgets('state=delete 只显示「投票已删除」，没有任何操作', (tester) async {
      final h = await bootChat();
      await pump(tester, h, votePost(voteProps(state: 'delete', c0: 1)));
      expect(find.text('投票已删除'), findsOneWidget);
      expect(find.text('面条'), findsNothing);
      expect(find.text('看结果'), findsNothing);
      expect(find.text('添加选项'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
    });

    testWidgets('卡片头显示「匿名 | 截止 …」', (tester) async {
      final h = await bootChat();
      final props = voteProps();
      (props['vote'] as Map)['options'] = {
        'multiple': false,
        'anonymous': true,
        'add_option': false,
        'expire_at': 1800000000000,
      };
      await pump(tester, h, votePost(props));
      expect(find.textContaining('匿名'), findsOneWidget);
      expect(find.textContaining('截止 '), findsOneWidget);
    });
  });

  group('提醒', () {
    test('setReminder 落库 props.remind_at；clearReminder 去掉', () async {
      final h = await bootChat();
      final post = PostDto.fromJson(const {
        'post_id': 1,
        'channel_id': 5,
        'creator_id': 14,
        'type': 'normal',
        'message': '提醒我',
        'props': {'encrypted': false},
      });
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      h.transport.responses['SYNO.Chat.Post.Reminder.set'] = const {};
      expect(
        await h.ctrl.setReminder(
          channelId: 5,
          post: post,
          remindAt: 1789602663164,
        ),
        isTrue,
      );
      final call = h.transport.calls.lastWhere((c) => c['remind_at'] != null);
      expect(call['post_id'], '1');
      expect(call['remind_at'], '1789602663164');
      var updated = await h.container.read(chatStoreProvider).postById(5, 1);
      expect(updated!.remindAt, 1789602663164);

      // 同时排上本地通知的账（原版靠 FCM 推送，我们走本地通知，
      // 详见 `ReminderScheduler`）
      final sched = h.container.read(reminderSchedulerProvider);
      expect(sched.armed[1]?.remindAt, 1789602663164);

      h.transport.responses['SYNO.Chat.Post.Reminder.delete'] = const {};
      expect(await h.ctrl.clearReminder(channelId: 5, post: updated), isTrue);
      updated = await h.container.read(chatStoreProvider).postById(5, 1);
      expect(updated!.remindAt, 0);
      expect(sched.armed, isNot(contains(1)), reason: '取消后不该再弹');
    });

    test('listReminders 解析 props.remind_at 并按时间排序', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Reminder.list'] = {
        'posts': [
          {
            'post_id': 11,
            'channel_id': 5,
            'creator_id': 14,
            'type': 'normal',
            'message': '晚点',
            'props': {'remind_at': 2000},
          },
          {
            'post_id': 12,
            'channel_id': 5,
            'creator_id': 14,
            'type': 'normal',
            'message': '早点',
            'props': {'remind_at': 1000},
          },
        ],
      };
      final list = await h.ctrl.listReminders(5);
      expect(list.map((p) => p.postId), [12, 11]);
      // `Reminder/list` 是"我的提醒"的权威来源 → 校准本地账本
      final armed = h.container.read(reminderSchedulerProvider).armed;
      expect(armed.keys.toSet(), {11, 12});
    });

    test('长按菜单：没设提醒显示"提醒我"，设了显示"取消提醒"', () {
      // 直接查 action 列表（未挂载 widget，用 post 数据驱动）
      final plain = PostDto.fromJson(const {
        'post_id': 1,
        'channel_id': 5,
        'type': 'normal',
        'props': {'encrypted': false},
      });
      final withReminder = PostDto.fromJson(const {
        'post_id': 2,
        'channel_id': 5,
        'type': 'normal',
        'props': {'remind_at': 100},
      });
      expect(plain.remindAt, 0);
      expect(withReminder.remindAt, 100);
    });
  });

  group('定时消息', () {
    test('createScheduledPost 发 JSON 编码的 message，返回 cronjob_id', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Schedule.create'] = {
        'cronjob_id': 7,
      };
      final id = await h.ctrl.createScheduledPost(
        channelId: 5,
        message: '明天的消息',
        sendAt: 1789685466505,
      );
      expect(id, 7);
      final call = h.transport.calls.lastWhere((c) => c['send_at'] != null);
      expect(call['channel_id'], '5');
      expect(call['message'], '"明天的消息"');
      expect(call['send_at'], '1789685466505');
    });

    test('listScheduledPosts 解析 schedule_posts', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Schedule.list'] = {
        'schedule_posts': [
          {'cronjob_id': 4, 'message': '后天的消息', 'send_at': 2000},
          {'cronjob_id': 3, 'message': '明天的消息', 'send_at': 1000},
        ],
      };
      final list = await h.ctrl.listScheduledPosts(5);
      expect(list, hasLength(2));
      expect(list.first.cronjobId, 4);
      expect(list.last.message, '明天的消息');
    });

    test('deleteScheduledPost 用 cronjob_id', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Schedule.delete'] = const {};
      await h.ctrl.deleteScheduledPost(7);
      final call = h.transport.calls.lastWhere((c) => c['cronjob_id'] != null);
      expect(call['cronjob_id'], '7');
    });
  });

  group('广播（Phase 6 新增事件）', () {
    test('post.vote.update 把新票数写回 props.vote', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([votePost(voteProps())]);

      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'post.vote.update',
          'data': {
            'channel_id': 5,
            'post_id': 9001,
            'vote': {
              'choices': [
                {'id': 'id-a', 'text': '面条', 'count': 5},
                {'id': 'id-b', 'text': '米饭', 'count': 1},
              ],
              'options': {
                'multiple': false,
                'anonymous': false,
                'add_option': false,
                'expire_at': 0,
              },
              'state': 'open',
            },
          },
        }),
      );
      final vote = (await store.postById(5, 9001))!.vote!;
      expect(vote.totalVotes, 6);
    });

    test('post.vote.close 后是已结束', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([votePost(voteProps())]);
      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'post.vote.close',
          'data': {
            'channel_id': 5,
            'post_id': 9001,
            'vote': {
              'choices': [
                {'id': 'id-a', 'text': '面条', 'count': 1},
              ],
              'options': {
                'multiple': false,
                'anonymous': false,
                'add_option': false,
                'expire_at': 0,
              },
              'state': 'close',
            },
          },
        }),
      );
      expect((await store.postById(5, 9001))!.vote!.state, VoteState.closed);
    });

    test('post.reminder.set / delete 改 props.remind_at', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        const PostDto(postId: 91, channelId: 5, message: '提醒我', createAt: 1),
      ]);
      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'post.reminder.set',
          'data': {'channel_id': 5, 'post_id': 91, 'remind_at': 1789602663164},
        }),
      );
      expect((await store.postById(5, 91))!.remindAt, 1789602663164);

      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'post.reminder.delete',
          'data': {'channel_id': 5, 'post_id': 91},
        }),
      );
      expect((await store.postById(5, 91))!.remindAt, 0);
    });
  });

  group('标签 / 机器人 / 斜杠命令', () {
    test('channelHashtags 解析 hashtags 数组', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Channel.Hashtag.list'] = {
        'hashtags': ['日报', 'flt-tag-1'],
      };
      expect(await h.ctrl.channelHashtags(5), ['日报', 'flt-tag-1']);
    });

    test('setPostHashtag 发 JSON 字符串并落库（去 #）', () async {
      final h = await bootChat();
      final post = const PostDto(
        postId: 7,
        channelId: 5,
        message: 'x',
        createAt: 1,
      );
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      h.transport.responses['SYNO.Chat.Post.Hashtag.set'] = const {};
      expect(
        await h.ctrl.setPostHashtag(channelId: 5, post: post, hashtag: '#日报'),
        isTrue,
      );
      final call = h.transport.calls.lastWhere((c) => c['hashtag'] != null);
      expect(call['post_id'], '7');
      expect(call['hashtag'], '"日报"');
      expect(
        (await h.container.read(chatStoreProvider).postById(5, 7))!.hashtags,
        ['日报'],
      );
    });

    test('deletePostHashtag 本地移除', () async {
      final h = await bootChat();
      final post = PostDto.fromJson(const {
        'post_id': 8,
        'channel_id': 5,
        'message': 'x',
        'create_at': 1,
        'hashtags': ['a', 'b'],
      });
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      h.transport.responses['SYNO.Chat.Post.Hashtag.delete'] = const {};
      expect(
        await h.ctrl.deletePostHashtag(channelId: 5, post: post, hashtag: 'a'),
        isTrue,
      );
      expect(
        (await h.container.read(chatStoreProvider).postById(5, 8))!.hashtags,
        ['b'],
      );
    });

    test('UserDto 解析 slash_props / chatbot_props / bot_props', () async {
      final slash = UserDto.fromJson(const {
        'user_id': 3,
        'nickname': 'jitsi',
        'type': 'bot',
        'bot_type': 'slash',
        'bot_props': {'is_system': true, 'sticker_name': ''},
        'slash_props': {
          'cmd': 'jitsi',
          'description': 'webhook_builtin:desc_conference_jitsi',
          'url': '',
          'usage': '',
        },
      });
      expect(slash.isSlashBot, isTrue);
      expect(slash.slashCmd, 'jitsi');
      expect(slash.botIsSystem, isTrue);
      expect(slash.isListedBot, isFalse, reason: '斜杠命令不进机器人列表');

      final chatbot = UserDto.fromJson(const {
        'user_id': 11,
        'nickname': 'test',
        'type': 'bot',
        'bot_type': 'chatbot',
        'bot_props': {'is_system': false, 'sticker_name': 'bear'},
        'chatbot_props': {
          'hide_from_user': false,
          'purpose': '测试机器人',
          'welcome_note': 'hi',
        },
      });
      expect(chatbot.isChatbot, isTrue);
      expect(chatbot.isListedBot, isTrue);
      expect(chatbot.botStickerName, 'bear');
      expect(chatbot.chatbotPurpose, '测试机器人');

      final hidden = UserDto.fromJson(const {
        'user_id': 7,
        'nickname': 'Synology_Drive',
        'type': 'bot',
        'bot_type': 'broadcast',
        'chatbot_props': {'hide_from_user': true},
      });
      expect(hidden.isListedBot, isFalse, reason: 'hide_from_user 不列');
    });

    test('blockedBots 解析 blocked_user_ids', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Channel.Chatbot.list_blocked'] = {
        'blocked_user_ids': [7, 11],
      };
      expect(await h.ctrl.blockedBots(), [7, 11]);
    });

    test('initiateChatbot 落库频道并返回 id', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Channel.Chatbot.initiate'] = {
        'channel_id': 77,
        'name': '',
        'type': 'direct',
        'encrypted': false,
      };
      final id = await h.ctrl.initiateChatbot(11);
      expect(id, 77);
      final call = h.transport.calls.lastWhere((c) => c['user_id'] != null);
      // `user_id` 是 String 字段 → Gson 编码一次（`"11"`）
      expect(call['user_id'], '"11"');
      expect(
        (await h.container.read(chatStoreProvider).allChannels()).any(
          (c) => c.channelId == 77,
        ),
        isTrue,
      );
    });

    test('listArchives 只认 type=encrypted（JSON 编码）', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Archive.list'] = {
        'archives': [
          {
            'archive_id': 1,
            'props': {
              'channel': {
                'channel_id': 45,
                'type': 'private',
                'encrypted': true,
                'channel_key_enc': 'SEALED',
              },
            },
          },
        ],
      };
      final list = await h.ctrl.listArchives();
      expect(list, hasLength(1));
      final call = h.transport.calls.lastWhere((c) => c['type'] != null);
      expect(call['type'], '"encrypted"');
    });
  });

  group('斜杠命令补全', () {
    testWidgets('输入 / 时提示命令，点了插进输入框', (tester) async {
      final h = await bootChat();
      await h.container.read(chatStoreProvider).upsertUsers([
        UserDto.fromJson(const {
          'user_id': 3,
          'nickname': 'jitsi',
          'type': 'bot',
          'bot_type': 'slash',
          'slash_props': {
            'cmd': 'jitsi',
            'description': 'webhook_builtin:desc_conference_jitsi',
          },
        }),
      ]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: 5)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final field = find.byType(TextField).last;
      await tester.enterText(field, '/');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('/jitsi'), findsOneWidget);
      expect(find.text('发起 Jitsi 视频会议'), findsOneWidget);

      await tester.tap(find.text('/jitsi'));
      await tester.pump();
      final controller = tester.widget<TextField>(field).controller!;
      expect(controller.text, '/jitsi ');
    });

    testWidgets('输入普通文本不提示', (tester) async {
      final h = await bootChat();
      await h.container.read(chatStoreProvider).upsertUsers([
        UserDto.fromJson(const {
          'user_id': 3,
          'type': 'bot',
          'bot_type': 'slash',
          'slash_props': {'cmd': 'jitsi'},
        }),
      ]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: 5)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField).last, '你好');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('/jitsi'), findsNothing);
    });
  });

    testWidgets('「看结果」打开结果面板：票数 + 投票人（不再静默刷新）', (tester) async {
      final h = await bootChat(
        extra: {
          // 投票人列表（`VoteUsersFragment` 的语义：结果里要能看到人）
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 14,
                'username': 'me',
                'type': 'human',
                'status': 'online',
              },
              {
                'user_id': 1,
                'username': 'alice',
                'nickname': '小爱',
                'type': 'human',
                'status': 'online',
              },
              {
                'user_id': 2,
                'username': 'bob',
                'type': 'human',
                'status': 'online',
              },
            ],
          },
        },
      );
      h.transport.responses['SYNO.Chat.Post.Vote.get_choices'] = {
        'choices': [
          {
            'id': 'id-a',
            'text': '面条',
            'count': 3,
            'voters': [1, 2],
          },
          {
            'id': 'id-b',
            'text': '米饭',
            'count': 1,
            'voters': [14],
          },
        ],
      };
      final post = votePost(voteProps());
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: VoteCard(post: post))),
        ),
      );
      await tester.pump();
      expect(find.text('看结果'), findsOneWidget);

      await tester.tap(find.text('看结果'));
      await tester.pumpAndSettle();

      // 官方 `VoteResultFragment`：点「View results」必须**打开结果页**，
      // 而不是只刷新卡片（没人投票时卡片上根本没有票数 ⇒ "点了没反应"）。
      expect(find.text('投票结果'), findsOneWidget);
      expect(find.text('alice (小爱)、bob'), findsOneWidget);
      expect(find.text('me'), findsOneWidget);
    });

  group('频道页入口', () {
    testWidgets('长按消息能把投票卡片渲染出来', (tester) async {
      final h = await bootChat();
      final post = votePost(voteProps(c0: 1));
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      // 首页 provider 直接读本地库，避免走网络
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: 5)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(VoteCard), findsOneWidget);
      expect(find.text('午饭吃什么'), findsOneWidget);
    });
  });
}
