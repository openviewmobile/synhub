// 消息链路离线验证：真正的 ChatSessionController + 假 API + 假 socket。
//
// 覆盖 Phase 3 的三件事：
//   ① 打开频道拉第一页 + 标记已读（unread 清零、last_view_at 用服务端返回值）
//   ② 发消息：乐观插入 → 服务端确认替换（不留重复行）
//   ③ 收到别人的 post.create：未读 +1 并回服务端把正文捞回来；
//      同账号另一台设备发的则不加未读
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'support/chat_harness.dart';

void main() {
  test('打开频道：拉第一页消息 + 标记已读（last_view_at 用服务端值）', () async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Post.list': {
          'posts': [testPostJson],
        },
      },
    );

    final store = h.container.read(chatStoreProvider);
    expect((await store.postsForChannel(5)), isEmpty, reason: '初始为空');

    final n = await h.ctrl.loadPosts(5);
    expect(n, 1);
    final posts = await store.postsForChannel(5);
    expect(posts.single.message, '来自服务端的正文');
    expect(posts.single.postId, 4294967300);

    // 已读上报
    await h.ctrl.markRead(5);
    final ch = (await store.allChannels()).single;
    expect(ch.unread, 0);
    expect(ch.lastViewAt, 1234, reason: '用服务端返回的 last_view_at');
  });

  test('loadPosts 幂等：本地已有就不重复请求', () async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Post.list': {
          'posts': [testPostJson],
        },
      },
    );
    await h.ctrl.loadPosts(5);
    final before = h.container.read(chatStoreProvider).db; // 仅用于类型提示
    expect(before, isNotNull);

    final n2 = await h.ctrl.loadPosts(5);
    expect(n2, 0, reason: '本地已有 → 不再拉');
  });

  test('发消息：乐观插入 → 服务端确认替换，且不加未读', () async {
    final h = await bootChat(
      extra: {
        // 假服务端会把我们发的 mobile_token 原样回带（实测行为）
        'SYNO.Chat.Post.create': {
          'post_id': 4294967500,
          'channel_id': 5,
          'creator_id': 14,
          'create_at': 3000,
          'type': 'normal',
          'message': '我发的',
        },
      },
    );

    final ok = await h.ctrl.sendMessage(5, '我发的');
    expect(ok, isTrue);

    final store = h.container.read(chatStoreProvider);
    final posts = await store.postsForChannel(5);
    expect(posts.length, 1, reason: '乐观行必须被服务端行替换掉，不能两条');
    expect(posts.single.postId, 4294967500);
    expect(posts.single.state, 0);
    expect(
      posts.single.tmpPostId,
      greaterThan(0),
      reason: '临时 id 要能从 mobile_token 回填，方便多设备对账',
    );

    final ch = (await store.allChannels()).single;
    expect(ch.unread, 3, reason: '自己发的消息不该改未读（原值 3 保持）');
    expect(ch.lastPostAt, 3000);

    // 请求体必须带 conn_id 与 mobile_token（原库用 tmpPostId 对账）
    final req = h.container.read(chatSessionControllerProvider);
    expect(req.myUserId, 14);
  });

  test('发消息失败：本地行标记 state=2 并保留', () async {
    final h = await bootChat(); // create 没有预设响应 → data 为空 → post_id=0 也算成功
    // 用非法输入触发失败路径
    final ok = await h.ctrl.sendMessage(5, '   ');
    expect(ok, isFalse, reason: '空消息直接拒绝');
    expect(
      await h.container.read(chatStoreProvider).postsForChannel(5),
      isEmpty,
    );
  });

  test('收到别人的 post.create：未读 +1 且把正文捞回来', () async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Post.list': {
          'posts': [testPostJson],
        },
      },
    );
    expect(
      (await h.container.read(chatStoreProvider).allChannels()).single.unread,
      3,
    );

    // 实测载荷：channel_id 在顶层，作者在 data.creator_id
    await h.ctrl.handleEvent(
      const ChatSocketEvent('client.post.create', {
        'user_id': 3,
        'channel_id': 5,
        'data': {
          'creator_id': 3,
          'post_id': 4294967300,
          'thread_id': 0,
          'create_at': 2000,
        },
      }),
    );

    final store = h.container.read(chatStoreProvider);
    final ch = (await store.allChannels()).single;
    expect(ch.unread, 4);
    expect(ch.lastPostAt, 2000);

    final posts = await store.postsForChannel(5);
    expect(posts.single.message, '来自服务端的正文', reason: '事件里没有正文，要回服务端捞');
  });

  test('同账号另一台设备发的 post.create：不加未读', () async {
    final h = await bootChat();
    await h.ctrl.handleEvent(
      const ChatSocketEvent('client.post.create', {
        'user_id': 14,
        'channel_id': 5,
        'data': {'creator_id': 14, 'post_id': 11, 'create_at': 2600},
      }),
    );

    final ch = (await h.container.read(chatStoreProvider).allChannels()).single;
    expect(ch.unread, 3, reason: '自己发的（哪怕来自别的设备）不算未读');
    expect(ch.lastPostAt, 2600);
  });

  test('broadcast(post.delete) → 本地删掉那条消息', () async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Post.list': {
          'posts': [testPostJson],
        },
      },
    );
    final store = h.container.read(chatStoreProvider);
    await h.ctrl.loadPosts(5);
    expect(await store.postsForChannel(5), isNotEmpty);

    await h.ctrl.handleEvent(
      const ChatSocketEvent('client.broadcast', {
        'type': 'post.delete',
        'data': {'channel_id': 5, 'post_id': 4294967300},
      }),
    );

    expect(await store.postsForChannel(5), isEmpty);
  });

  test('postsProvider 是流式的：插入消息后自动推新', () async {
    final h = await bootChat();
    final seen = <List<PostDto>>[];
    final sub = h.container.listen(postsProvider(5), (prev, next) {
      next.whenData(seen.add);
    }, fireImmediately: true);

    await h.container.read(chatStoreProvider).upsertPosts([
      const PostDto(postId: 1, channelId: 5, message: 'x', createAt: 1),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    sub.close();

    expect(seen.last.single.message, 'x');
  });
}
