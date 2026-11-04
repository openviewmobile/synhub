// 实时事件 → 本地库 的离线验证。
//
// 直接喂**真实形状**的载荷给 ChatSessionController.handleEvent（不启 socket），
// 断言 Drift 里的结果。载荷取自真实帧：
//   test/fixtures/socket_frames.txt（client.broadcast user.update）
// 以及 SocketHelper.java 里的 PostCreateVo / ChannelVo / UserVo 结构。
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:flutter/foundation.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/data/remote/socket/socket_events.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

ProviderContainer _container() {
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWith((ref) {
        final db = ChatDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('client.post.create → 未读 +1、lastPostAt 更新', () async {
    final c = _container();
    final store = c.read(chatStoreProvider);
    await store.upsertChannels([
      const ChannelDto(channelId: 7, name: 'group', type: 'public', unread: 2),
    ]);

    final ctrl = c.read(chatSessionControllerProvider.notifier);
    // 载荷形状照抄实测（channel_id 在顶层，data 里是 creator_id）
    await ctrl.handleEvent(
      const ChatSocketEvent('client.post.create', {
        'user_id': 3,
        'channel_id': 7,
        'data': {
          'creator_id': 3,
          'post_id': 99,
          'thread_id': 0,
          'create_at': 1700000000000,
          'mentions': <dynamic>[],
        },
      }),
    );

    final after = (await store.allChannels()).single;
    expect(after.unread, 3, reason: '原有 2 条未读，再来一条应为 3');
    expect(after.lastPostAt, 1700000000000);
  });

  test('未知频道收到 post.create 不写库也不炸', () async {
    final c = _container();
    final store = c.read(chatStoreProvider);
    final ctrl = c.read(chatSessionControllerProvider.notifier);

    await ctrl.handleEvent(
      const ChatSocketEvent('client.post.create', {
        'user_id': 3,
        'channel_id': 4242,
        'data': {'creator_id': 3, 'post_id': 1, 'create_at': 1},
      }),
    );

    expect(await store.allChannels(), isEmpty);
  });

  test('client.channel.join → 新频道入库且 is_joined=true', () async {
    final c = _container();
    final store = c.read(chatStoreProvider);
    final ctrl = c.read(chatSessionControllerProvider.notifier);

    await ctrl.handleEvent(
      const ChatSocketEvent('client.channel.join', {
        'channel_id': 11,
        'name': '新群',
        'type': 'public',
        'is_joined': true,
        'total_member_count': 3,
      }),
    );

    final ch = (await store.allChannels()).single;
    expect(ch.channelId, 11);
    expect(ch.name, '新群');
    expect(ch.isJoined, isTrue);
  });

  test('client.channel.disjoin → is_joined=false（频道保留）', () async {
    final c = _container();
    final store = c.read(chatStoreProvider);
    await store.upsertChannels([
      const ChannelDto(channelId: 11, name: '新群', isJoined: true),
    ]);

    final ctrl = c.read(chatSessionControllerProvider.notifier);
    await ctrl.handleEvent(
      const ChatSocketEvent('client.channel.disjoin', {
        'channel_id': 11,
        'user_id': 1,
      }),
    );

    final ch = (await store.allChannels()).single;
    expect(ch.isJoined, isFalse);
  });

  test('client.user.update → 用户写入本地库', () async {
    final c = _container();
    final store = c.read(chatStoreProvider);
    final ctrl = c.read(chatSessionControllerProvider.notifier);

    await ctrl.handleEvent(
      const ChatSocketEvent('client.user.update', {
        'user_id': 14,
        'username': 'demo_user',
        'nickname': '',
        'type': 'human',
        'status': 'online',
        'user_props': {
          'avatar_color': '#94bf13',
          'key_pair': {'public_key': ''},
        },
      }),
    );

    final u = (await store.allUsers()).single;
    expect(u.userId, 14);
    expect(u.username, 'demo_user');
    expect(u.status, 'online');
    expect(u.avatarColor, '#94bf13');
  });

  test('client.broadcast user.update → 同样落库', () async {
    final c = _container();
    final store = c.read(chatStoreProvider);
    final ctrl = c.read(chatSessionControllerProvider.notifier);

    await ctrl.handleEvent(
      const ChatSocketEvent('client.broadcast', {
        'type': 'user.update',
        'data': {
          'user_id': 14,
          'username': 'demo_user',
          'type': 'human',
          'status': 'online',
          'user_props': {'avatar_color': '#94bf13'},
        },
      }),
    );

    final u = (await store.allUsers()).single;
    expect(u.userId, 14);
    expect(u.status, 'online');
  });

  test('client.broadcast channel.star → is_star 置位', () async {
    final c = _container();
    final store = c.read(chatStoreProvider);
    await store.upsertChannels([
      const ChannelDto(channelId: 5, name: 'x', isStar: false),
    ]);

    final ctrl = c.read(chatSessionControllerProvider.notifier);
    await ctrl.handleEvent(
      const ChatSocketEvent('client.broadcast', {
        'type': 'channel.star',
        'data': {'channel_id': 5},
      }),
    );

    expect((await store.allChannels()).single.isStar, isTrue);
  });

  test('未实现的事件（typing 等）被安静忽略', () async {
    final c = _container();
    final ctrl = c.read(chatSessionControllerProvider.notifier);
    await ctrl.handleEvent(
      const ChatSocketEvent('client.channel.typing', {
        'channel_id': 7,
        'user_id': 3,
      }),
    );
    await ctrl.handleEvent(const ChatSocketEvent('notification.create', null));
    expect(c.read(chatSessionControllerProvider).phase, ChatSyncPhase.idle);
  });

  test('未处理的顶层事件 / 广播类型只记一次，不影响其他事件', () async {
    final c = _container();
    final ctrl = c.read(chatSessionControllerProvider.notifier);
    final store = c.read(chatStoreProvider);
    await store.upsertChannels([
      const ChannelDto(channelId: 5, name: 'group', type: 'public'),
    ]);
    await store.upsertPosts([
      const PostDto(
        postId: 4294967300,
        channelId: 5,
        creatorId: 4,
        message: 'hi',
        createAt: 1700000000000,
      ),
    ]);
    final logs = <String>[];
    final old = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = old);

    // 未知事件一律安静忽略，但各记一条日志（协议漂移排查用）
    await ctrl.handleEvent(
      const ChatSocketEvent('client.something.new', {'x': 1}),
    );
    await ctrl.handleEvent(
      const ChatSocketEvent('client.something.new', {'x': 2}),
    );
    for (var i = 0; i < 2; i++) {
      await ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientBroadcast, const {
          'type': 'post.brand.new',
          'data': {'post_id': 1},
        }),
      );
    }

    expect(logs.where((l) => l.contains('client.something.new')).length, 1);
    expect(logs.where((l) => l.contains('post.brand.new')).length, 1);

    // 已知事件照常工作（未知事件不该把状态搞坏）
    await ctrl.handleEvent(
      ChatSocketEvent(SocketEvent.clientBroadcast, const {
        'type': BroadcastType.postStar,
        'data': {'post_id': 4294967300, 'channel_id': 5},
      }),
    );
    final posts = await store.postsForChannel(5);
    expect(posts.any((p) => p.isStar), isTrue);
  });

  test('channelsProvider 会随事件自动刷新（流式）', () async {
    final c = _container();
    final store = c.read(chatStoreProvider);
    await store.upsertChannels([
      const ChannelDto(channelId: 7, name: 'group', unread: 0),
    ]);

    final emissions = <List<ChannelDto>>[];
    final sub = c.listen(channelsProvider, (prev, next) {
      next.whenData(emissions.add);
    }, fireImmediately: true);

    final ctrl = c.read(chatSessionControllerProvider.notifier);
    await ctrl.handleEvent(
      const ChatSocketEvent('client.post.create', {
        'user_id': 3,
        'channel_id': 7,
        'data': {'creator_id': 3, 'post_id': 1, 'create_at': 42},
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    sub.close();
    expect(emissions.length, greaterThanOrEqualTo(2), reason: '应当再推一次更新后的列表');
    expect(emissions.last.single.unread, 1);
  });
}
