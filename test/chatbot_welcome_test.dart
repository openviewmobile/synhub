// 聊天机器人会话的「欢迎语」卡片 + 机器人消息头像（离线）。
//
// 对齐原版：
//   * `ChannelPresenter.addChatBotWelcomeMessageToList`：进 chatbot 会话时**客户端自己**
//     造一条 `welcome_message`（列表最前面），内容取对面机器人的 `welcome_note`；
//     机器人停用/删除 → `bot_hello_msg_default`（「这是您与 X 之间进行的一对一会话。」）；
//   * `Post.viewType()==112` → `item_post_welcome_message`：卡片 + 加粗标题
//     （布局里写死的 `Hello there!`）+ 16sp 正文 + `synobot_mini` 图标；
//   * `ChannelViewBinder.java:214`：消息带 `props.bot` 时头像换成机器人图标。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chatbot_welcome.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

const _me = 14;
const _bot = 11;

Map<String, dynamic> _botUserJson({
  int id = _bot,
  String nickname = '小助手',
  String note = '有什么可以帮您？',
  String botType = 'chatbot',
  bool deleted = false,
  Map<String, dynamic> props = const {},
}) => {
  'user_id': id,
  'username': 'bot_$id',
  'nickname': nickname,
  'type': 'bot',
  'status': 'online',
  'deleted': deleted,
  'delete_at': deleted ? 1 : 0,
  'bot_type': botType,
  'chatbot_props': {'welcome_note': note},
  'user_props': props,
};

Map<String, dynamic> _channelJson({
  String type = 'chatbot',
  List<int> members = const [_bot, _me],
}) => {
  'channel_id': 5,
  'name': '小助手',
  'type': type,
  'is_joined': true,
  'members': members,
};

Future<ChatHarness> _boot({
  Map<String, dynamic>? bot,
  String type = 'chatbot',
  List<int> members = const [_bot, _me],
}) => bootChat(
  extra: {
    'SYNO.Chat.Channel.list': {
      'channels': [_channelJson(type: type, members: members)],
    },
    'SYNO.Chat.User.list': {
      'users': [
        {'user_id': _me, 'username': 'me', 'type': 'human', 'status': 'online'},
        bot ?? _botUserJson(),
      ],
    },
    'SYNO.Chat.User.get': {
      'user': {'user_id': _me, 'username': 'me', 'type': 'human'},
    },
  },
);

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: 5)),
);

PostDto _post({
  int id = 4294967300,
  int creator = _bot,
  String type = 'normal',
  String message = '你好，我是机器人',
  Map<String, dynamic> props = const {},
}) => PostDto.fromJson({
  'post_id': id,
  'channel_id': 5,
  'creator_id': creator,
  'create_at': 2000,
  'type': type,
  'message': message,
  'props': props,
});

void main() {
  group('chatbotOf / 欢迎语文案（纯函数）', () {
    final users = <int, UserDto>{
      _me: const UserDto(userId: _me, username: 'me', type: 'human'),
      _bot: UserDto.fromJson(_botUserJson()),
    };

    test('只有 chatbot 频道才有；取成员里第一个非我', () {
      expect(chatbotOf('chatbot', const [_bot, _me], users, _me)?.userId, _bot);
      expect(chatbotOf('public', const [_bot, _me], users, _me), isNull);
      expect(chatbotOf('anonymous', const [_bot, _me], users, _me), isNull);
    });

    test('成员表拿不到（真机常为 null）时按用户表兜底', () {
      expect(chatbotOf('chatbot', const [], users, _me)?.userId, _bot);
    });

    test('正常机器人用 welcome_note；停用/删除用 bot_hello_msg_default', () {
      expect(chatbotWelcomeText(users[_bot]!), '有什么可以帮您？');
      final gone = UserDto.fromJson(_botUserJson(deleted: true));
      // 模板是「这是您与 [_SUBST_1_] 之间进行的一对一会话。」—— 名字两侧本来就有空格
      expect(chatbotWelcomeText(gone), '这是您与 小助手 之间进行的一对一会话。');
      final disabled = UserDto.fromJson({
        ..._botUserJson(),
        'is_disabled': true,
      });
      expect(chatbotWelcomeText(disabled), contains('一对一会话'));
      expect(botHelloDefaultText(''), contains('机器人'));
    });
  });

  testWidgets('chatbot 会话：列表最前面挂欢迎卡片，标题是布局里写死的 Hello there!', (tester) async {
    final h = await _boot();
    await h.container.read(chatStoreProvider).upsertPosts([_post()]);

    await tester.pumpWidget(_app(h.container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(kChatbotWelcomeTitle), findsOneWidget);
    expect(find.text('有什么可以帮您？'), findsOneWidget);
    expect(find.text('你好，我是机器人'), findsOneWidget);
    // 标题行的机器人图标（卡片）+ 消息头像（发送者本身就是机器人）
    expect(find.byIcon(Icons.smart_toy_outlined), findsNWidgets(2));
  });

  testWidgets('chatbot 会话一条消息都没有：也显示欢迎卡片（原版就是建出来的）', (tester) async {
    final h = await _boot();
    await tester.pumpWidget(_app(h.container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('还没有消息'), findsNothing);
    expect(find.text(kChatbotWelcomeTitle), findsOneWidget);
    expect(find.text('有什么可以帮您？'), findsOneWidget);
  });

  testWidgets('机器人停用：欢迎卡片换成 bot_hello_msg_default', (tester) async {
    final h = await _boot(bot: _botUserJson(deleted: true));
    await tester.pumpWidget(_app(h.container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('一对一会话'), findsOneWidget);
  });

  testWidgets('普通频道不挂欢迎卡片', (tester) async {
    final h = await _boot(type: 'public');
    await h.container.read(chatStoreProvider).upsertPosts([_post()]);
    await tester.pumpWidget(_app(h.container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(kChatbotWelcomeTitle), findsNothing);
    expect(find.text('你好，我是机器人'), findsOneWidget);
  });

  testWidgets('消息带 props.bot：头像换成机器人图标（原版 synobot_mini）', (tester) async {
    final h = await _boot(type: 'public');
    await h.container.read(chatStoreProvider).upsertPosts([
      _post(
        props: {
          'bot': {'bot_id': 3, 'nickname': '提醒机器人'},
        },
      ),
    ]);
    await tester.pumpWidget(_app(h.container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byIcon(Icons.smart_toy_outlined),
      findsOneWidget,
      reason: '带 props.bot 的消息头像用机器人图标',
    );
    expect(find.text('提'), findsNothing, reason: '不该再画首字母');
  });

  testWidgets('PostDto 解析 props.bot', (tester) async {
    final p = _post(
      props: {
        'bot': {'bot_id': 3, 'nickname': '提醒机器人'},
      },
    );
    expect(p.botId, 3);
    expect(p.botNickname, '提醒机器人');
    expect(p.hasBot, isTrue);
    expect(_post().hasBot, isFalse);
  });
}
