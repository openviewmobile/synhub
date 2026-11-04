// 聊天 wave1（DSchat 对齐）数据层离线验证：
//   * 表情回应 `SYNO.Chat.Post.Reaction` set/delete（`sticker_id` 与
//     `sticker_name` **两种形态都要能用**，见 `docs/chat-api-wire.md` #17/#18/#75/#76）；
//   * 投票 `SYNO.Chat.Post.Vote` create/set/delete + close/create_option/vote/get_choices
//     （#8/#13/#21/#23/#24/#41/#98）；
//   * 提醒 `SYNO.Chat.Post.Reminder` set/get/list/delete
//     （#19/#37/#55/#77，`remind_at` 下划线）；
//   * 定时消息 `SYNO.Chat.Post.Schedule` create/list/set/delete
//     （#11/#20/#56/#78，`cronjob_id` 下划线，**不是 `id`**）；
//   * 帖子订阅 `SYNO.Chat.Post.Subscribe` create/delete（#87/#91）；
//   * hashtag `SYNO.Chat.Post.Hashtag` set/delete（#16/#74）。
//
// 参数形态逐字对齐 `docs/chat-api-wire.md` §2（源头是 APK 反编译
// `WebApiService.java` 的 `@Field`）与 `AccountManager` 的 Gson 编码。
// 错误码 401/402/407 在聊天侧**语义未取证** → 一律「未知错误 + 原始码」，
// 不套用 `DsmErrorCode` 的登录码文案（任务书硬要求）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/chat_error_text.dart';
import 'package:synhub/src/data/dto/vote_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/channel_scheduled_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

int _v(Map<String, dynamic> call) => int.parse('${call['version']}');

Map<String, dynamic> _lastOf(FakeTransport t, String apiDotMethod) =>
    t.calls.lastWhere(
      (c) => '${c['api']}.${c['method']}' == apiDotMethod,
      orElse: () => const {},
    );

Future<ChatApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return ChatApi(api);
}

void main() {
  group('表情回应 SYNO.Chat.Post.Reaction', () {
    test('set 按 sticker_id：v1，只带 post_id + sticker_id', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.setReaction(postId: 7, stickerId: 3);
      final call = _lastOf(t, 'SYNO.Chat.Post.Reaction.set');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
      expect(call['sticker_id'], '3');
      expect(call.containsKey('sticker_name'), isFalse);
    });

    test('set 按 sticker_name：发 emojione 短代码（裸值，不加引号）', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.setReaction(postId: 7, stickerName: 'thumbsup');
      final call = _lastOf(t, 'SYNO.Chat.Post.Reaction.set');
      expect(_v(call), 1);
      expect(call['sticker_name'], 'thumbsup');
      expect(call.containsKey('sticker_id'), isFalse);
    });

    test('delete 按 sticker_id：v1，只带 post_id + sticker_id', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.deleteReaction(postId: 7, stickerId: 3);
      final call = _lastOf(t, 'SYNO.Chat.Post.Reaction.delete');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
      expect(call['sticker_id'], '3');
      expect(call.containsKey('sticker_name'), isFalse);
    });

    test('delete 按 sticker_name：第二种形态必须也支持', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.deleteReaction(postId: 7, stickerName: 'joy');
      final call = _lastOf(t, 'SYNO.Chat.Post.Reaction.delete');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
      expect(call['sticker_name'], 'joy');
      expect(call.containsKey('sticker_id'), isFalse);
    });

    test('两种形态都不给 → 客户端报错，不发废请求', () async {
      final t = FakeTransport();
      final api = await _api(t);
      expect(() => api.setReaction(postId: 7), throwsA(isA<ArgumentError>()));
      expect(
        () => api.deleteReaction(postId: 7),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        t.calls.any((c) => '${c['api']}'.startsWith('SYNO.Chat.Post.Reaction')),
        isFalse,
      );
    });
  });

  group('投票 SYNO.Chat.Post.Vote', () {
    test('create：v1 + channel_id/message/choices/options（下划线字段）', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.createVote(
        channelId: 5,
        message: '晚饭吃什么',
        choices: const ['面条', '米饭'],
        multiple: true,
        anonymous: true,
        addOption: true,
        expireAt: 1800000000000,
      );
      final call = _lastOf(t, 'SYNO.Chat.Post.Vote.create');
      expect(_v(call), 1);
      expect(call['channel_id'], '5');
      expect(call['message'], '"晚饭吃什么"');
      expect(jsonDecode(call['choices'] as String), [
        {'text': '面条'},
        {'text': '米饭'},
      ]);
      final options = jsonDecode(call['options'] as String) as Map;
      expect(options, {
        'add_option': true,
        'anonymous': true,
        'expire_at': 1800000000000,
        'multiple': true,
      });
      // `add_option` / `expire_at` 必须是下划线：写成驼峰会得到 101
      expect(options.containsKey('addOption'), isFalse);
      expect(options.containsKey('expireAt'), isFalse);
    });

    test('set（还没人投票）：v1 + message/choices/options 三件套', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.setVote(
        channelId: 5,
        postId: 7,
        message: '换个问法',
        choices: const [(id: 'a', text: '面条'), (id: 'b', text: '米饭')],
        multiple: false,
        anonymous: false,
        addOption: true,
        expireAt: 0,
      );
      final call = _lastOf(t, 'SYNO.Chat.Post.Vote.set');
      expect(_v(call), 1);
      expect(call['channel_id'], '5');
      expect(call['post_id'], '7');
      expect(call['message'], '"换个问法"');
      final choices = jsonDecode(call['choices'] as String) as List;
      expect(choices.first, {'count': 0, 'id': 'a', 'text': '面条'});
      expect(jsonDecode(call['options'] as String), {
        'add_option': true,
        'anonymous': false,
        'expire_at': 0,
        'multiple': false,
      });
    });

    test('set（已有人投票）：只发 options，不带 message/choices', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.setVote(
        channelId: 5,
        postId: 7,
        multiple: false,
        anonymous: false,
        addOption: false,
        expireAt: 0,
      );
      final call = _lastOf(t, 'SYNO.Chat.Post.Vote.set');
      expect(_v(call), 1);
      expect(call['options'], isNotNull);
      expect(call.containsKey('message'), isFalse);
      expect(call.containsKey('choices'), isFalse);
    });

    test('vote：choice_ids 是 JSON 数组', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.castVote(postId: 7, choiceIds: const ['a', 'b']);
      final call = _lastOf(t, 'SYNO.Chat.Post.Vote.vote');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
      expect(jsonDecode(call['choice_ids'] as String), ['a', 'b']);
    });

    test('get_choices / close / create_option / delete：v1 + post_id', () async {
      final t = FakeTransport();
      final api = await _api(t);
      t.responses['SYNO.Chat.Post.Vote.get_choices'] = {
        'choices': [
          {'id': 'a', 'text': '面条', 'count': 2},
        ],
      };
      final choices = await api.voteChoices(7);
      expect(choices.single['id'], 'a');
      expect(_v(_lastOf(t, 'SYNO.Chat.Post.Vote.get_choices')), 1);

      await api.closeVote(7);
      var call = _lastOf(t, 'SYNO.Chat.Post.Vote.close');
      expect(_v(call), 1);
      expect(call['post_id'], '7');

      await api.createVoteOption(postId: 7, text: '饺子');
      call = _lastOf(t, 'SYNO.Chat.Post.Vote.create_option');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
      expect(call['text'], '"饺子"');

      await api.deleteVote(7);
      call = _lastOf(t, 'SYNO.Chat.Post.Vote.delete');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
    });
  });

  group('提醒 SYNO.Chat.Post.Reminder', () {
    test('set：线参是 remind_at（下划线），不是 remindAt', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.setReminder(postId: 7, remindAt: 1800000000000);
      final call = _lastOf(t, 'SYNO.Chat.Post.Reminder.set');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
      expect(call['remind_at'], '1800000000000');
      expect(call.containsKey('remindAt'), isFalse);
    });

    test('get：v1 + post_id，解析 data.remind_at', () async {
      final t = FakeTransport();
      final api = await _api(t);
      t.responses['SYNO.Chat.Post.Reminder.get'] = {'remind_at': 1234};
      expect(await api.reminderAt(7), 1234);
      final call = _lastOf(t, 'SYNO.Chat.Post.Reminder.get');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
    });

    test('delete：v1 + post_id', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.deleteReminder(7);
      final call = _lastOf(t, 'SYNO.Chat.Post.Reminder.delete');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
    });

    test('list：v1 + channel_id，解析 posts', () async {
      final t = FakeTransport();
      final api = await _api(t);
      t.responses['SYNO.Chat.Post.Reminder.list'] = {
        'posts': [
          {
            'post_id': 7,
            'props': {'remind_at': 1234},
          },
        ],
      };
      final posts = await api.listReminders(5);
      expect(posts.single['post_id'], 7);
      final call = _lastOf(t, 'SYNO.Chat.Post.Reminder.list');
      expect(_v(call), 1);
      expect(call['channel_id'], '5');
    });
  });

  group('定时消息 SYNO.Chat.Post.Schedule', () {
    test('create：v1 + channel_id/message/send_at → cronjob_id', () async {
      final t = FakeTransport();
      final api = await _api(t);
      t.responses['SYNO.Chat.Post.Schedule.create'] = {'cronjob_id': 42};
      final id = await api.createScheduledPost(
        channelId: 5,
        message: '记得开会',
        sendAt: 1800000000000,
      );
      expect(id, 42);
      final call = _lastOf(t, 'SYNO.Chat.Post.Schedule.create');
      expect(_v(call), 1);
      expect(call['channel_id'], '5');
      expect(call['message'], '"记得开会"');
      expect(call['send_at'], '1800000000000');
    });

    test('set：用 cronjob_id（不是 id/post_id）+ message/send_at', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.updateScheduledPost(
        cronjobId: 42,
        message: '改个时间',
        sendAt: 1800000001000,
      );
      final call = _lastOf(t, 'SYNO.Chat.Post.Schedule.set');
      expect(_v(call), 1);
      expect(call['cronjob_id'], '42');
      expect(call.containsKey('id'), isFalse);
      expect(call.containsKey('post_id'), isFalse);
      expect(call['message'], '"改个时间"');
      expect(call['send_at'], '1800000001000');
    });

    test('delete：用 cronjob_id（这就是 Common.ARG_CRONJOB_ID 的真值）', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.deleteScheduledPost(42);
      final call = _lastOf(t, 'SYNO.Chat.Post.Schedule.delete');
      expect(_v(call), 1);
      expect(call['cronjob_id'], '42');
      expect(call.containsKey('id'), isFalse);
      expect(call.containsKey('post_id'), isFalse);
    });

    test('list：v1 + channel_id，解析 schedule_posts', () async {
      final t = FakeTransport();
      final api = await _api(t);
      t.responses['SYNO.Chat.Post.Schedule.list'] = {
        'schedule_posts': [
          {'cronjob_id': 42, 'message': '记得开会', 'send_at': 1800000000000},
        ],
      };
      final list = await api.listScheduledPosts(5);
      expect(list.single['cronjob_id'], 42);
      final call = _lastOf(t, 'SYNO.Chat.Post.Schedule.list');
      expect(_v(call), 1);
      expect(call['channel_id'], '5');
    });
  });

  group('帖子订阅 / hashtag', () {
    test('Subscribe create/delete：v1，只带 post_id', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.subscribePost(7);
      var call = _lastOf(t, 'SYNO.Chat.Post.Subscribe.create');
      expect(_v(call), 1);
      expect('${call['post_id']}', '7');
      expect(call.containsKey('channel_id'), isFalse);

      await api.unsubscribePost(7);
      call = _lastOf(t, 'SYNO.Chat.Post.Subscribe.delete');
      expect(_v(call), 1);
      expect('${call['post_id']}', '7');
      expect(call.containsKey('channel_id'), isFalse);
    });

    test('Hashtag set/delete：v1 + post_id + hashtag（JSON 编码）', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.setPostHashtag(postId: 7, hashtag: 'alpha');
      var call = _lastOf(t, 'SYNO.Chat.Post.Hashtag.set');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
      expect(call['hashtag'], '"alpha"');

      await api.deletePostHashtag(postId: 7, hashtag: 'alpha');
      call = _lastOf(t, 'SYNO.Chat.Post.Hashtag.delete');
      expect(_v(call), 1);
      expect(call['post_id'], '7');
      expect(call['hashtag'], '"alpha"');
    });
  });

  group('未取证 / 同名不同义错误码（102/401/402/403/407）', () {
    test('一律「未知错误 + 原始码」，不猜语义、不套 DSM 文案', () {
      for (final code in const [102, 401, 402, 403, 407]) {
        final text = describeChatWave1Error(
          DsmApiException(code, method: 'SYNO.Chat.Post.Schedule'),
        );
        expect(text, contains('$code'), reason: '必须带原始码');
        expect(text, contains('未知'), reason: '未取证码只能走未知错误通用提示');
        // DSM 的通用/登录码文案（102 API 不存在 / 401 账号已停用 / 402 权限被拒 /
        // 403 需要两步验证码 / 407 尝试次数过多）都不能出现
        expect(text, isNot(contains('API 不存在')));
        expect(text, isNot(contains('账号已停用')));
        expect(text, isNot(contains('权限被拒')));
        expect(text, isNot(contains('两步验证码')));
        expect(text, isNot(contains('尝试次数过多')));
        // `SYNO.Chat.*` 猜测表里的固定说法也不能出现
        expect(text, isNot(contains('不在该频道')));
        expect(text, isNot(contains('消息不存在')));
        expect(text, isNot(contains('记录无效')));
        // 不许把内部 id 带上屏
        expect(text, isNot(contains('post_id')));
        expect(text, isNot(contains('cronjob_id')));
        expect(text, isNot(contains('channel_id')));
      }
    });

    test('403 的 errors 原文只作诊断，不上屏', () {
      final text = describeChatWave1Error(
        DsmApiException(
          403,
          method: 'SYNO.Chat.Post.list',
          raw: {'errors': 'no such channel'},
        ),
      );
      expect(text, contains('403'));
      expect(text, isNot(contains('no such channel')));
    });

    test('其余错误码仍走 DsmErrorCode（如 101 请求无效）', () {
      expect(
        describeChatWave1Error(
          DsmApiException(101, method: 'SYNO.Chat.Post.Schedule'),
        ),
        DsmErrorCode.describe(101, method: 'SYNO.Chat.Post.Schedule'),
      );
    });

    test('非 DsmApiException 原样回落（不吞异常信息）', () {
      expect(describeChatWave1Error(StateError('boom')), contains('boom'));
    });

    testWidgets('定时消息页 401 → 界面显示原始码而不是猜测文案', (tester) async {
      // 直接注入 AsyncError，绕开 Riverpod 3 的失败自动重试（真实页面会重试，
      // 这里要验的是**错误分支渲染**本身）。
      final h = await bootChat(
        moreOverrides: [
          scheduledPostsProvider(5).overrideWithValue(
            AsyncValue<List<ScheduledPostDto>>.error(
              DsmApiException(401, method: 'SYNO.Chat.Post.Schedule.list'),
              StackTrace.empty,
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ScheduledMessagesPage(channelId: 5)),
        ),
      );
      await tester.pump();
      expect(find.textContaining('401'), findsOneWidget);
      expect(find.textContaining('不在该频道'), findsNothing);
      expect(find.textContaining('账号已停用'), findsNothing);
    });
  });
}
