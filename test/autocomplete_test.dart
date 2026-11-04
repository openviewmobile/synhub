// Phase 9：输入框联想（`@` 用户 / `#` 标签 / `/` 斜杠命令）+ 提及编码（`@u:<id>`）。
//
// 对齐原版：
//   * `AutoCompleteFilter.filter`：词以空格/换行分隔，`lower = word.substring(1)`，
//     `#`/`@`/`/` 各自按 `contains` 过滤；`/` 在"正文里还有别的 `/`"时不提示；
//   * `ChatUtil.moveChannelMemberForward` + `atMention`：成员排前面，非加密频道
//     最前面插 `@channel`(-2) / `@here`(-1)；
//   * `ChatUtil.getImageMentionSpanStringBuilder`：`Post v4 && !encrypted` 时
//     提及写成 `@u:<id>`，否则保持 `@username`；`@here`/`@channel` 永远原样；
//   * `ChatChannel.hashtags` 这一列由 `Channel.Hashtag/list` 落库（进频道时刷新）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/features/chat/autocomplete.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/mentions.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

UserDto _human(int id, String username, {String nickname = ''}) =>
    UserDto.fromJson({
      'user_id': id,
      'username': username,
      'nickname': nickname,
      'type': 'human',
      'status': 'online',
    });

UserDto _slashBot(int id, String cmd, {String desc = ''}) => UserDto.fromJson({
  'user_id': id,
  'username': cmd,
  'type': 'bot',
  'bot_type': 'slash',
  'slash_props': {'cmd': cmd, 'description': desc},
});

ChannelDto _channel({
  int id = 5,
  bool encrypted = false,
  String type = 'private',
  List<int> members = const [14, 4],
}) => ChannelDto.fromJson({
  'channel_id': id,
  'name': '频道',
  'type': type,
  'encrypted': encrypted,
  'members': members,
});

void main() {
  group('分词（SpaceTokenizer）', () {
    test('按空格/换行切词，取光标所在的那个', () {
      expect(currentWord('你好 @dem', 9), '@dem');
      expect(currentWord('你好 @demo 再见', 5), '@demo');
      expect(currentWord('@demo', 0), '@demo');
      expect(currentWord('a\n#tag', 6), '#tag');
      expect(currentWord('', 0), '');
    });
  });

  group('斜杠命令禁用（setSlashCommandDisable）', () {
    test('/ 只在整条消息开头才提示', () {
      expect(slashAutocompleteDisabled(''), isFalse);
      expect(slashAutocompleteDisabled('/ji'), isFalse);
      expect(slashAutocompleteDisabled('你好 /ji'), isTrue);
      expect(slashAutocompleteDisabled('/jitsi https://x/'), isTrue);
    });
  });

  group('@ 候选列表（moveChannelMemberForward + atMention）', () {
    test('成员排前面，非加密频道插 @channel/@here', () {
      final users = [_human(7, 'other'), _human(4, 'demo')];
      final list = mentionCandidates(users: users, channel: _channel());

      expect(list.take(2).map((m) => m.username), ['channel', 'here']);
      expect(list.map((m) => m.username).toList(), [
        'channel',
        'here',
        'demo',
        'other',
      ], reason: '成员 4 要排在非成员 7 前面');
      expect(list[0].userId, -2);
      expect(list[1].userId, -1);
      expect(list[0].insertText, '@channel ');
    });

    test('加密频道不给 @channel/@here', () {
      final list = mentionCandidates(
        users: [_human(4, 'demo')],
        channel: _channel(encrypted: true),
      );
      expect(list.map((m) => m.username), ['demo']);
    });

    test('两人会话 / chatbot 不给 @channel/@here', () {
      final list = mentionCandidates(
        users: [_human(4, 'demo')],
        channel: _channel(type: 'anonymous', members: [14, 4]),
      );
      expect(list.map((m) => m.username), ['demo']);
    });
  });

  group('过滤（AutoCompleteFilter.filter）', () {
    final users = [_human(4, 'demo', nickname: '演示'), _human(7, 'other')];
    final mentions = mentionCandidates(users: users, channel: _channel());
    final bots = [
      _slashBot(3, 'jitsi', desc: 'webhook_builtin:desc_conference_jitsi'),
    ];

    List<AutocompleteItem> run(String word, {String? full}) =>
        filterAutocomplete(
          word: word,
          fullText: full ?? word,
          slashCommands: bots,
          hashtags: const ['报表', 'report', '周报'],
          mentions: mentions,
        );

    test('# 按标签 contains 过滤（不区分大小写）', () {
      expect(run('#报').map((i) => (i as HashtagTarget).tag), ['报表', '周报']);
      expect(run('#REP').map((i) => (i as HashtagTarget).tag), ['report']);
      expect(run('#不存在的'), isEmpty);
      expect(run('#')[0].insertText, '#报表 ');
    });

    test('@ 同时匹配 username 与 nickname', () {
      expect(run('@dem').map((i) => (i as MentionTarget).username), ['demo']);
      expect(run('@演').map((i) => (i as MentionTarget).username), ['demo']);
      expect(run('@the').map((i) => (i as MentionTarget).username), ['other']);
      expect(run('@demo')[0].label, '@demo (演示)');
    });

    test('/ 只在允许时提示；正文里有别的 / 就不提示', () {
      expect(run('/ji').map((i) => (i as SlashTarget).bot.slashCmd), ['jitsi']);
      expect(run('/ji', full: '你好 /ji'), isEmpty);
    });

    test('空词 / 普通词不提示', () {
      expect(run(''), isEmpty);
      expect(run('你好'), isEmpty);
    });
  });

  group('提及编码（getImageMentionSpanStringBuilder）', () {
    final byName = {'demo': 4, 'other': 7};

    test('v4 明文频道 → @u:<id>', () {
      expect(encodeMentions('@demo 看一下', byUsername: byName), '@u:4 看一下');
      expect(encodeMentions('麻烦 @other，谢谢', byUsername: byName), '麻烦 @u:7，谢谢');
    });

    test('@here / @channel / 认不出的名字保持原样', () {
      expect(encodeMentions('@here 有人吗', byUsername: byName), '@here 有人吗');
      expect(encodeMentions('@channel 通知', byUsername: byName), '@channel 通知');
      expect(encodeMentions('@nobody 你好', byUsername: byName), '@nobody 你好');
    });

    test('邮箱不被误伤（@ 必须在词首）', () {
      expect(encodeMentions('a@demo.com', byUsername: byName), 'a@demo.com');
      expect(encodeMentions('没有提及', byUsername: byName), '没有提及');
    });

    test('mentionIdByUsername 建表', () {
      expect(mentionIdByUsername([_human(4, 'demo'), _human(0, '')]), {
        'demo': 4,
      });
    });
  });

  group('发消息时的线路格式', () {
    testWidgets('v4 明文频道：服务端收到 @u:<id>，本地仍是原文', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {'user_id': 14, 'username': 'me', 'type': 'human'},
              _userJsonOf(_human(4, 'demo', nickname: '演示')),
            ],
          },
          'SYNO.Chat.Post.create': {
            'post_id': 777,
            'channel_id': 5,
            'creator_id': 14,
            'create_at': 4000,
            'type': 'normal',
            'message': '@u:4 看一下',
          },
        },
      );
      await h.container.read(chatStoreProvider).upsertUsers([
        _human(4, 'demo', nickname: '演示'),
      ]);
      final ok = await h.ctrl.sendMessage(5, '@demo 看一下');
      expect(ok, isTrue);

      final call = h.transport.calls.lastWhere((c) => c['method'] == 'create');
      // `Post/create` 的 message 走 Gson（带引号的 JSON 串，见 chat_api.createPost）
      expect(call['message'], '"@u:4 看一下"');
      final posts = await h.container
          .read(chatStoreProvider)
          .postsForChannel(5);
      expect(posts.single.message, '@u:4 看一下', reason: '本地最终以服务端返回为准（原版也这样）');
    });

    test('老服务端（Post 只有 v3）→ 保持 @username', () async {
      final h = await bootChat(
        apiTable: {
          ...FakeTransport.table,
          'SYNO.Chat.Post': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 3,
          },
        },
        extra: {
          'SYNO.Chat.Post.create': {
            'post_id': 778,
            'channel_id': 5,
            'creator_id': 14,
            'create_at': 4000,
            'type': 'normal',
            'message': '@demo 看一下',
          },
        },
      );
      await h.container.read(chatStoreProvider).upsertUsers([
        _human(4, 'demo'),
      ]);
      await h.ctrl.sendMessage(5, '@demo 看一下');
      final call = h.transport.calls.lastWhere((c) => c['method'] == 'create');
      expect(call['message'], '"@demo 看一下"');
    });
  });

  group('频道标签落库', () {
    test('enter 之后自动拉标签并写进频道行', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.enter': const {},
          'SYNO.Chat.Channel.Hashtag.list': {
            'hashtags': ['周报', 'report'],
          },
        },
      );
      h.transport.responses['SYNO.Chat.Channel.enter'] = const {};
      final ok = await h.ctrl.enterChannel(5);
      expect(ok, isTrue);
      // enter 之后是 unawaited 的刷新，等一个事件循环
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await h.container.read(chatStoreProvider).channelHashtags(5), [
        '周报',
        'report',
      ]);
      // 频道行是 StreamProvider（`channelsProvider`），它把这次写入推给 UI 的
      // 过程由下面的 widget 用例覆盖；这里只认权威的本地库。
    });

    test('updateChannelHashtags 覆盖旧值；频道不存在时忽略', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.updateChannelHashtags(5, ['a', 'b']);
      expect(await store.channelHashtags(5), ['a', 'b']);
      await store.updateChannelHashtags(5, ['c']);
      expect(await store.channelHashtags(5), ['c']);
      await store.updateChannelHashtags(999, ['x']);
      expect(await store.channelHashtags(999), isEmpty);
    });
  });

  group('输入框联想 UI', () {
    Widget app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
    );

    testWidgets('敲 # → 提示本地标签，点一下插进输入框', (tester) async {
      // 走真实链路：进频道 → `Channel.Hashtag/list` → 落库 → 联想读库
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Hashtag.list': {
            'hashtags': ['周报'],
          },
        },
      );
      await tester.pumpWidget(app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField), '#周');
      await tester.pump();
      expect(find.text('#周报'), findsOneWidget);

      await tester.tap(find.text('#周报'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '#周报 ',
      );
    });

    testWidgets('敲 @ → 成员与 @channel/@here 都在，点了插 @username', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {'user_id': 14, 'username': 'me', 'type': 'human'},
              _userJsonOf(_human(4, 'demo', nickname: '演示')),
            ],
          },
        },
      );
      await h.container.read(chatStoreProvider).upsertUsers([
        _human(4, 'demo', nickname: '演示'),
      ]);
      await tester.pumpWidget(app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField), '@d');
      await tester.pump();
      expect(find.text('@demo (演示)'), findsOneWidget);
      expect(find.text('@channel'), findsNothing, reason: '过滤后只剩 demo');

      await tester.tap(find.text('@demo (演示)'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '@demo ',
      );
    });

    testWidgets('敲 / 仍然提示斜杠命令', (tester) async {
      final h = await bootChat();
      await h.container.read(chatStoreProvider).upsertUsers([
        _slashBot(3, 'jitsi', desc: 'webhook_builtin:desc_conference_jitsi'),
      ]);
      h.container.invalidate(slashCommandsProvider);
      await tester.pumpWidget(app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField), '/ji');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('/jitsi'), findsOneWidget);
      expect(find.text('发起 Jitsi 视频会议'), findsOneWidget);

      await tester.tap(find.text('/jitsi'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '/jitsi ',
      );
    });
  });
}

/// `UserDto` → 服务端 JSON（`User/list` 覆盖用）
Map<String, dynamic> _userJsonOf(UserDto u) => {
  'user_id': u.userId,
  'username': u.username,
  'nickname': u.nickname,
  'type': u.type,
  'status': u.status,
};
