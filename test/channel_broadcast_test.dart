// 频道列表一致性广播：`channel.view` / `channel.hide` / `channel.show` /
// `channel.hide_global` / `channel.unhide_global` / `user.delete` /
// `post.subscribe` / `post.unsubscribe`。
//
// 全部照原版 `SocketHelper` 的处理：
//   * `viewChannel` → `updateLastViewAt`（我们未读是持久列，顺带清零）；
//   * `hideChannel` → `updateLastHideAt(id, last_hide_at)`；`showChannel` → 置 0；
//   * `hide_global`/`unhide_global` → `hide_global_at`；
//   * `deleteUser` → `UserEvent.disable`（本地标已删除，历史消息的作者名还要用）；
//   * `subscribePost`/`unsubscribePost` → 维护 `subscribes`（**只认自己的**）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/data/remote/socket/socket_events.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/channel_scheduled_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/thread_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Map<String, dynamic> _event(String type, Map<String, dynamic> data) => {
  'type': type,
  'data': data,
};

/// 把一条 `client.broadcast` 喂给控制器（所有 `type` 分发都走这里）
extension on ChatHarness {
  Future<void> broadcast(String type, Map<String, dynamic> data) =>
      ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientBroadcast, _event(type, data)),
      );
}

Future<ChatHarness> _boot({Map<String, Map<String, dynamic>>? extra}) =>
    bootChat(
      extra: {
        'SYNO.Chat.Channel.list': {
          'channels': [
            {...testChannelJson},
          ],
        },
        ...?extra,
      },
    );

void main() {
  group('channel.view（别的设备读掉了）', () {
    test('清未读并更新 last_view_at', () async {
      final h = await _boot();
      var ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.unread, 3, reason: 'fixture 初始未读 3');

      await h.ctrl.handleEvent(
        ChatSocketEvent(
          SocketEvent.clientBroadcast,
          _event(BroadcastType.channelView, {
            'channel_id': 5,
            'last_view_at': 1700000000000,
            'user_id': 14,
          }),
        ),
      );
      ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.unread, 0);
      expect(ch.unreadComment, 0);
      expect(ch.lastViewAt, 1700000000000);
    });

    test('别人的已读不清我的未读（原版不看 user_id，我们加闸更保险）', () async {
      final h = await _boot();
      await h.ctrl.handleEvent(
        ChatSocketEvent(
          SocketEvent.clientBroadcast,
          _event(BroadcastType.channelView, {
            'channel_id': 5,
            'last_view_at': 1700000000000,
            'user_id': 4,
          }),
        ),
      );
      final ch =
          (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.unread, 3, reason: '不该被别人读掉');
      expect(ch.lastViewAt, 0);
    });
  });

  group('channel.hide / show（多设备同步隐藏状态）', () {
    test('hide 写入 last_hide_at，show 清零', () async {
      final h = await _boot();
      await h.ctrl.handleEvent(
        ChatSocketEvent(
          SocketEvent.clientBroadcast,
          _event(BroadcastType.channelHide, {
            'channel_id': 5,
            'last_hide_at': 1700000000000,
            'user_id': 14,
          }),
        ),
      );
      var ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.lastHideAt, 1700000000000);

      await h.ctrl.handleEvent(
        ChatSocketEvent(
          SocketEvent.clientBroadcast,
          _event(BroadcastType.channelShow, {'channel_id': 5, 'user_id': 14}),
        ),
      );
      ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.lastHideAt, 0);
    });

    test('全局隐藏 / 取消（顶层事件，2.4.7 service.js 的实际形状）', () async {
      final h = await _boot();
      // 真实形状：服务端 `onCloseChannel` 直接 `emit("client.channel.hide_global", e)`，
      // **不是** `client.broadcast` 里的 type。载荷只有
      // `channel_id`/`channel_close_type`（没有时间戳），原版处理时用
      // `System.currentTimeMillis()`，我们同样。
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelHideGlobal, {
          'channel_id': 5,
          'channel_close_type': 'CHANNEL_CLOSE_TYPE_HIDE_GLOBAL',
        }),
      );
      var ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.hideGlobalAt, greaterThan(0));
      expect(ch.hideAtSideBar(), isTrue);

      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelUnhideGlobal, {
          'channel_id': 5,
          'channel_close_type': 'CHANNEL_CLOSE_TYPE_UNHIDE_GLOBAL',
        }),
      );
      ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.hideGlobalAt, 0);
      expect(ch.hideAtSideBar(), isFalse);

      // 兜底分支：万一被包进 client.broadcast 也要认
      await h.ctrl.handleEvent(
        ChatSocketEvent(
          SocketEvent.clientBroadcast,
          _event(SocketEvent.clientChannelHideGlobal, {
            'channel_id': 5,
            'channel_close_type': 'CHANNEL_CLOSE_TYPE_HIDE_GLOBAL',
          }),
        ),
      );
      ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.hideGlobalAt, greaterThan(0));

      // channel_id 缺失时不动手
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelHideGlobal, {
          'channel_close_type': 'CHANNEL_CLOSE_TYPE_HIDE_GLOBAL',
        }),
      );
      ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.hideGlobalAt, greaterThan(0), reason: '没有 channel_id 不能清/改');
    });
  });

  group('hideAtSideBar 语义（照抄 Channel.hideAtSideBar）', () {
    ChannelDto make({
      int lastHideAt = 0,
      int hideGlobalAt = 0,
      int unread = 0,
      int unreadMention = 0,
      int unreadComment = 0,
      String type = 'public',
      bool encrypted = false,
      List<int> members = const [14, 4],
      String notificationMobile = 'all',
    }) => ChannelDto(
      channelId: 5,
      type: type,
      encrypted: encrypted,
      members: members,
      lastHideAt: lastHideAt,
      hideGlobalAt: hideGlobalAt,
      unread: unread,
      unreadMention: unreadMention,
      unreadComment: unreadComment,
      notificationMobile: notificationMobile,
    );

    test('没隐藏过就不藏；hide 之后有新未读会冒出来', () {
      expect(make().hideAtSideBar(), isFalse);
      expect(make(lastHideAt: 100).hideAtSideBar(), isTrue);
      expect(
        make(lastHideAt: 100, unread: 2).hideAtSideBar(),
        isFalse,
        reason: '有新消息要回来',
      );
    });

    test('有发送失败的消息时不藏（要留重试入口）', () {
      expect(make(lastHideAt: 100).hideAtSideBar(hasFailedPost: true), isFalse);
    });

    test('全局隐藏无条件藏', () {
      expect(make(hideGlobalAt: 1, unread: 5).hideAtSideBar(), isTrue);
    });

    test('通知粒度不是 all 时只看 @我/回复未读', () {
      expect(
        make(
          lastHideAt: 100,
          unread: 3,
          notificationMobile: 'mention',
        ).hideAtSideBar(),
        isTrue,
        reason: '只提我/回复才算 "值得冒出来"',
      );
      expect(
        make(
          lastHideAt: 100,
          unreadMention: 1,
          notificationMobile: 'mention',
        ).hideAtSideBar(),
        isFalse,
      );
      expect(
        make(
          lastHideAt: 100,
          unreadComment: 1,
          notificationMobile: 'mention',
        ).hideAtSideBar(),
        isFalse,
      );
    });

    test('匿名会话（type=anonymous）/chatbot 看总未读', () {
      expect(make(type: 'anonymous', lastHideAt: 100).hideAtSideBar(), isTrue);
      expect(
        make(type: 'anonymous', lastHideAt: 100, unread: 1).hideAtSideBar(),
        isFalse,
      );
      expect(
        make(type: 'chatbot', lastHideAt: 100, unread: 3).hideAtSideBar(),
        isFalse,
      );
      expect(make(type: 'anonymous', lastHideAt: 100).isConversation, isTrue);
      expect(
        make(type: 'public', lastHideAt: 100).isConversation,
        isFalse,
        reason: '原版 isConversation 只看 type == anonymous',
      );
    });
  });

  group('user.delete', () {
    test('标成已删除 + 禁用，历史记录还能取到名字', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {'user_id': 14, 'username': 'me', 'type': 'human'},
              {
                'user_id': 4,
                'username': 'demo',
                'nickname': 'demo',
                'type': 'human',
              },
            ],
          },
        },
      );
      await h.ctrl.handleEvent(
        ChatSocketEvent(
          SocketEvent.clientBroadcast,
          _event(BroadcastType.userDelete, {'user_id': 4, 'delete_at': 123}),
        ),
      );
      final users = await h.container.read(chatStoreProvider).allUsers();
      final demo = users.firstWhere((u) => u.userId == 4);
      expect(demo.isDeleted, isTrue);
      expect(demo.isDisabled, isTrue);
      expect(demo.deleteAt, 123);
      expect(demo.displayName, 'demo', reason: '名字要留着给历史消息用');
    });

    test('不存在的 user_id 不炸', () async {
      final h = await _boot();
      await h.ctrl.handleEvent(
        ChatSocketEvent(
          SocketEvent.clientBroadcast,
          _event(BroadcastType.userDelete, {'user_id': 999}),
        ),
      );
      final users = await h.container.read(chatStoreProvider).allUsers();
      expect(users.any((u) => u.userId == 999), isFalse);
      expect(users.every((u) => !u.isDeleted), isTrue, reason: '没人被误标');
    });
  });

  group('post.subscribe / unsubscribe', () {
    test('只认自己的订阅，写入 subscribes 数组', () async {
      final h = await _boot();
      await h.ctrl.handleEvent(
        ChatSocketEvent(
          SocketEvent.clientBroadcast,
          _event(BroadcastType.postSubscribe, {
            'channel_id': 5,
            'post_id': 42,
            'user_id': 14,
            'executor_user_id': 4,
            'comment_count': 3,
            'channel_order_time': 1700000000000,
          }),
        ),
      );
      var ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.subscribes, [42]);
      expect(ch.channelOrderTime, 1700000000000);

      // 别人订阅 → 不动我的
      await h.ctrl.handleEvent(
        ChatSocketEvent(
          SocketEvent.clientBroadcast,
          _event(BroadcastType.postSubscribe, {
            'channel_id': 5,
            'post_id': 43,
            'user_id': 4,
          }),
        ),
      );
      ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.subscribes, [42]);

      // 退订
      await h.ctrl.handleEvent(
        ChatSocketEvent(
          SocketEvent.clientBroadcast,
          _event(BroadcastType.postUnsubscribe, {
            'channel_id': 5,
            'post_id': 42,
            'user_id': 14,
          }),
        ),
      );
      ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.subscribes, isEmpty);
    });

    test('不重复追加同一个 post_id', () async {
      final h = await _boot();
      for (var i = 0; i < 3; i++) {
        await h.ctrl.handleEvent(
          ChatSocketEvent(
            SocketEvent.clientBroadcast,
            _event(BroadcastType.postSubscribe, {
              'channel_id': 5,
              'post_id': 42,
              'user_id': 14,
            }),
          ),
        );
      }
      final ch =
          (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.subscribes, [42]);
    });
  });

  group('话题订阅 API（create/delete）', () {
    test('订阅 → 参数只有 post_id（版本 v1）；退订同理', () async {
      final h = await _boot();
      final ok = await h.ctrl.setPostSubscribed(5, 42, subscribed: true);
      expect(ok, isTrue);
      var call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.Post.Subscribe',
      );
      expect(call['method'], 'create');
      expect('${call['version']}', '1');
      expect('${call['post_id']}', '42');
      expect(
        call.containsKey('channel_id'),
        isFalse,
        reason: '原版 WebApiService 只发 post_id',
      );

      var ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.subscribes, [42], reason: '本地先落库（服务端只回 BasicVo）');

      final ok2 = await h.ctrl.setPostSubscribed(5, 42, subscribed: false);
      expect(ok2, isTrue);
      call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.Post.Subscribe',
      );
      expect(call['method'], 'delete');
      ch = (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.subscribes, isEmpty);
    });

    test('服务端失败时返回 false，本地不变', () async {
      final h = await _boot();
      h.transport.failures['SYNO.Chat.Post.Subscribe.create'] = 103;
      final ok = await h.ctrl.setPostSubscribed(5, 42, subscribed: true);
      expect(ok, isFalse);
      final ch =
          (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.subscribes, isEmpty);
    });
  });

  group('话题页订阅按钮', () {
    testWidgets('点一下订阅 → 调 create + 图标变实心；再点退订', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.list': {
            'posts': [
              {...testPostJson, 'post_id': 700, 'comment_count': 2},
            ],
          },
        },
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: ThreadPage(channelId: 5, parentPostId: 700),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byIcon(Icons.notifications_none),
        findsOneWidget,
        reason: '没订阅时是空心铃铛',
      );
      await tester.tap(find.byIcon(Icons.notifications_none));
      await tester.pump(const Duration(milliseconds: 100));

      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.Post.Subscribe',
      );
      expect(call['method'], 'create');
      expect('${call['post_id']}', '700');
      final ch =
          (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(ch.subscribes, contains(700));
      expect(find.byIcon(Icons.notifications_active), findsOneWidget);
      expect(
        find.text('订阅'),
        findsOneWidget,
        reason: 'toast 文案照原版 post_subscribed',
      );

      // 让第一条 SnackBar 自己消失，否则第二条会排队不显示
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.byIcon(Icons.notifications_active));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        h.transport.calls.lastWhere(
          (c) => c['api'] == 'SYNO.Chat.Post.Subscribe',
        )['method'],
        'delete',
      );
      final after =
          (await h.container.read(chatStoreProvider).allChannels()).single;
      expect(after.subscribes, isNot(contains(700)));
      expect(
        find.byIcon(Icons.notifications_none),
        findsOneWidget,
        reason: '退订后回到空心铃铛',
      );
    });
  });

  group('归档 / 通知档位 / 定时消息广播', () {
    test('channel.archive → 本地清空该频道消息', () async {
      final h = await _boot();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts(const [
        PostDto(postId: 1, channelId: 5, creatorId: 4, message: 'a'),
        PostDto(postId: 2, channelId: 5, creatorId: 4, message: 'b'),
      ]);
      expect(await store.postsForChannel(5), hasLength(2));

      await h.broadcast(BroadcastType.channelArchive, const {'channel_id': 5});
      expect(await store.postsForChannel(5), isEmpty);
    });

    test('channel.preference → 覆盖本地通知档位', () async {
      final h = await _boot();
      final store = h.container.read(chatStoreProvider);
      var ch = (await store.allChannels()).single;
      expect(ch.notificationMobile, isNot('mention'));

      await h.broadcast(BroadcastType.channelPreference, const {
        'channel_id': 5,
        'preferences': {
          'notification_desktop': 'all',
          'notification_mobile': 'mention',
          'notification_mute': true,
        },
      });
      ch = (await store.allChannels()).single;
      expect(ch.notificationMobile, 'mention');
      expect(ch.notificationDesktop, 'all');
      expect(ch.notificationMute, isTrue);
    });

    test('post.schedule.set/delete → 让定时列表重新拉取', () async {
      final h = await _boot();
      final container = h.container;
      // 先读一次（进缓存）
      await container.read(scheduledPostsProvider(5).future);
      final before = h.transport.calls
          .where(
            (c) =>
                '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.Schedule.list',
          )
          .length;

      await h.broadcast(BroadcastType.postScheduleSet, const {
        'channel_id': 5,
        'cronjob_id': 9,
        'message': '晚点发',
        'send_at': 1800000000000,
        'user_id': 14,
      });
      await container.read(scheduledPostsProvider(5).future);
      final afterSet = h.transport.calls
          .where(
            (c) =>
                '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.Schedule.list',
          )
          .length;
      expect(afterSet, greaterThan(before), reason: '失效后重拉了一次');

      await h.broadcast(BroadcastType.postScheduleDelete, const {
        'channel_id': 5,
        'cronjob_id': 9,
      });
      await container.read(scheduledPostsProvider(5).future);
      final afterDelete = h.transport.calls
          .where(
            (c) =>
                '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.Schedule.list',
          )
          .length;
      expect(afterDelete, greaterThan(afterSet));
    });
  });

  group('E2EE broken 成员 + 密钥更新广播', () {
    test('client.channel.brokenuser → 频道 brokenUsers 加人（去重）', () async {
      final h = await _boot();
      final store = h.container.read(chatStoreProvider);
      expect((await store.allChannels()).single.brokenUsers, isEmpty);

      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelBrokenUser, const {
          'channel_id': 5,
          'user_id': 8,
        }),
      );
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelBrokenUser, const {
          'channel_id': 5,
          'user_id': 8,
        }),
      );
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelBrokenUser, const {
          'channel_id': 5,
          'user_id': 6,
        }),
      );
      final ch = (await store.allChannels()).single;
      expect(ch.brokenUsers, [6, 8], reason: '去重且有序');
    });

    test('刷新频道列表（broken_users 为空）不该冲掉本地标记', () async {
      final h = await _boot();
      final store = h.container.read(chatStoreProvider);
      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientChannelBrokenUser, const {
          'channel_id': 5,
          'user_id': 8,
        }),
      );
      expect((await store.allChannels()).single.brokenUsers, [8]);

      // 真机上 `Channel/list` 的 broken_users 一直是空数组 —— 再同步一次
      await h.ctrl.refresh();
      expect((await store.allChannels()).single.brokenUsers, [
        8,
      ], reason: '事件攒出来的标记不能被列表刷新清掉');
    });

    test(
      'syncChannelMembers → 用 Channel.Member/get 覆盖成员 + broken（服务端权威）',
      () async {
        final h = await _boot(
          extra: {
            'SYNO.Chat.Channel.Member.get': {
              'user_ids': [4, 14],
              'broken_user_ids': [4],
            },
          },
        );
        final store = h.container.read(chatStoreProvider);
        await store.addChannelBrokenUsers(5, [8]);

        final ok = await h.ctrl.syncChannelMembers(5);
        expect(ok, isTrue);
        final ch = (await store.allChannels()).single;
        expect(ch.members, [4, 14]);
        expect(ch.brokenUsers, [4], reason: '服务端权威结果覆盖本地（8 被清掉，4 是服务端说的）');
      },
    );

    test('channel.rescue → 摘掉这个人 + 覆盖频道密钥（载荷是 ChannelVo）', () async {
      final h = await _boot();
      final store = h.container.read(chatStoreProvider);
      await store.addChannelBrokenUsers(5, [6, 8]);
      await store.upsertChannels([
        (await store.allChannels()).single.copyWith(channelKeyEnc: 'old-key'),
      ]);

      // `channel.rescue` 是 `client.broadcast` 里的类型（原版 what 分支里有它）
      await h.broadcast(BroadcastType.channelRescue, const {
        'channel_id': 5,
        'user_id': 8,
        'channel_key_enc': 'rescued-key',
      });
      final ch = (await store.allChannels()).single;
      expect(ch.brokenUsers, [6], reason: '只摘掉被救的那个人');
      expect(ch.channelKeyEnc, 'rescued-key', reason: '用载荷里的新密钥覆盖');
    });

    test('client.user.updatekey → 逐频道更新密钥 + 只在自己身上换身份', () async {
      final h = await _boot(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {'user_id': 14, 'username': 'me', 'type': 'human'},
              {
                'user_id': 8,
                'username': 'other',
                'type': 'human',
                'public_key': 'old-pub',
              },
            ],
          },
        },
      );
      final store = h.container.read(chatStoreProvider);
      await store.upsertUsers(const [
        UserDto(userId: 14, username: 'me', type: 'human', publicKey: 'my-pub'),
        UserDto(
          userId: 8,
          username: 'other',
          type: 'human',
          publicKey: 'old-pub',
        ),
      ]);

      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientUserUpdateKey, const {
          'user_id': 8,
          'public_key': 'new-pub',
          'channels': [
            {'channel_id': 5, 'channel_key_enc': 'key-for-8'},
          ],
        }),
      );

      final ch = (await store.allChannels()).single;
      expect(ch.channelKeyEnc, 'key-for-8');
      final users = await store.allUsers();
      expect(users.firstWhere((u) => u.userId == 8).publicKey, 'new-pub');
      // 不是我自己 → 本地 E2EE 身份不该被动
      final svc = h.container.read(e2eeServiceProvider);
      expect(svc.identity?.publicKey, isNot('new-pub'));
    });

    test('client.user.updatekey（自己）→ 采纳服务端下发的密钥对', () async {
      final h = await _boot();
      final svc = h.container.read(e2eeServiceProvider);
      expect(svc.isConfigured, isFalse, reason: '一开始没身份');

      await h.ctrl.handleEvent(
        ChatSocketEvent(SocketEvent.clientUserUpdateKey, const {
          'user_id': 14,
          'public_key': 'server-pub',
          'private_key_enc': 'server-priv-enc',
        }),
      );
      expect(svc.identity?.publicKey, 'server-pub');
      expect(svc.identity?.privateKeyEnc, 'server-priv-enc');
      final users = await h.container.read(chatStoreProvider).allUsers();
      expect(users.firstWhere((u) => u.userId == 14).publicKey, 'server-pub');
    });

    test('服务端列表响应里的 broken_users 也能解析（数组 / JSON 字符串）', () {
      final a = ChannelDto.fromJson(const {
        'channel_id': 5,
        'encrypted': true,
        'broken_users': [3, 8],
      });
      expect(a.brokenUsers, [3, 8]);
      final b = ChannelDto.fromJson(const {
        'channel_id': 5,
        'encrypted': true,
        'broken_users': '[8, 3]',
      });
      expect(b.brokenUsers, [8, 3], reason: '原版本地库存的是 JSON 字符串');
      final c = ChannelDto.fromJson(const {
        'channel_id': 5,
        'broken_users': '',
      });
      expect(c.brokenUsers, isEmpty);
      final d = ChannelDto.fromJson(const {'channel_id': 5});
      expect(d.brokenUsers, isEmpty);
    });
  });

  group('频道列表过滤', () {
    testWidgets('隐藏的频道不出现在列表里，有未读就回来（通知档 = 全部消息）', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                ...testChannelJson,
                'unread': 0,
                'last_hide_at': 1700000000000,
                // 真机 public 频道默认是 mention_subscribe，这里用 all 才"任何未读都回来"
                'preferences': {'notification_mobile': 'all'},
              },
            ],
          },
        },
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChannelListPage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('测试频道'), findsNothing, reason: '隐藏且无未读 → 不显示');

      // 来一条新消息（未读 > 0）→ 重新出现
      await tester.runAsync(() async {
        await h.container
            .read(chatStoreProvider)
            .applyPostCreate(channelId: 5, createAt: 1800000000000);
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('测试频道'), findsOneWidget);
    });

    testWidgets('通知档 mention_subscribe（真机默认）：只有 @我/回复才让它冒出来', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                ...testChannelJson,
                'channel_id': 5,
                'name': '普通未读',
                'unread': 3,
                'last_hide_at': 1700000000000,
                'preferences': {'notification_mobile': 'mention_subscribe'},
              },
              {
                ...testChannelJson,
                'channel_id': 6,
                'name': '被提到',
                'unread': 0,
                'unread_mention': 1,
                'last_hide_at': 1700000000000,
                'preferences': {'notification_mobile': 'mention_subscribe'},
              },
            ],
          },
        },
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChannelListPage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('普通未读'),
        findsNothing,
        reason: 'public + mention_subscribe：普通未读不算"值得回来"',
      );
      expect(find.text('被提到'), findsOneWidget);
    });
  });
}
