// Phase 4 数据层离线验证：消息操作类接口（编辑/星标/置顶/回应/转发/话题）
// + 广播事件落库。
//
// API 参数形态全部对齐反编译的 `AccountManager` / `WebApiService`
// （版本号、哪些参数要"再 JSON 序列化一次"都是照抄的）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/post_actions_sheet.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 版本号在请求里是字符串（form 字段），统一转回 int 断言
int _v(Map<String, dynamic> call) => int.parse('${call['version']}');

/// 取最后一次调用的参数
Map<String, dynamic> _lastOf(FakeTransport t, String apiDotMethod) {
  final hit = t.calls.lastWhere(
    (c) => '${c['api']}.${c['method']}' == apiDotMethod,
    orElse: () => const {},
  );
  return hit;
}

Future<ChatApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return ChatApi(api);
}

void main() {
  group('Post API（离线参数校验）', () {
    test('star / unstar：v1，只带 post_id', () async {
      final t = FakeTransport();
      final api = await _api(t);

      await api.starPost(4294967300);
      var call = _lastOf(t, 'SYNO.Chat.Post.star');
      expect(_v(call), 1);
      expect(call['post_id'], '4294967300');

      await api.starPost(4294967300, star: false);
      call = _lastOf(t, 'SYNO.Chat.Post.unstar');
      expect(_v(call), 1);
      expect(call['post_id'], '4294967300');
    });

    test('pin / unpin（消息置顶）走 v1；stick / unstick（话题）走 v2', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.pinPost(7);
      expect(_v(_lastOf(t, 'SYNO.Chat.Post.pin')), 1);
      await api.pinPost(7, pin: false);
      expect(_v(_lastOf(t, 'SYNO.Chat.Post.unpin')), 1);

      await api.stickPost(7);
      expect(_v(_lastOf(t, 'SYNO.Chat.Post.stick')), 2);
      await api.stickPost(7, stick: false);
      expect(_v(_lastOf(t, 'SYNO.Chat.Post.unstick')), 2);
    });

    test('set / delete reaction：sticker_id 与 sticker_name 二选一', () async {
      final t = FakeTransport();
      final api = await _api(t);

      await api.setReaction(postId: 7, stickerId: 3);
      var call = _lastOf(t, 'SYNO.Chat.Post.Reaction.set');
      expect(_v(call), 1);
      expect(call['sticker_id'], '3');
      expect(call.containsKey('sticker_name'), isFalse);

      await api.setReaction(postId: 7, stickerName: ':smile:');
      call = _lastOf(t, 'SYNO.Chat.Post.Reaction.set');
      expect(call['sticker_name'], ':smile:');
      expect(call.containsKey('sticker_id'), isFalse);

      await api.deleteReaction(postId: 7, stickerId: 3);
      expect(_lastOf(t, 'SYNO.Chat.Post.Reaction.delete')['post_id'], '7');

      expect(() => api.setReaction(postId: 7), throwsA(isA<ArgumentError>()));
    });

    test('editPost：版本 (8,4,1)，message 再 JSON 序列化一次', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.editPost(postId: 9, message: '改过了', channelId: 1);
      final call = _lastOf(t, 'SYNO.Chat.Post.set');
      expect(_v(call), 8, reason: '候选里最高的 8 没超过服务器上限');
      expect(call['message'], '"改过了"');
      expect(call['post_id'], '9');
      expect(call.containsKey('thread_id'), isFalse);
    });

    test('editPost 带 thread_id（编辑话题回复时）', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.editPost(
        postId: 9,
        message: 'x',
        channelId: 1,
        threadId: 4294967300,
      );
      expect(_lastOf(t, 'SYNO.Chat.Post.set')['thread_id'], '4294967300');
    });

    test('forwardPost：channel_ids 是 JSON 数组字符串，版本 3', () async {
      final t = FakeTransport();
      final api = await _api(t);
      await api.forwardPost(postId: 5, channelIds: [1, 23]);
      final call = _lastOf(t, 'SYNO.Chat.Post.forward');
      expect(_v(call), 3);
      expect(call['channel_ids'], '[1,23]');
    });

    test('listThreads：thread_list v5，offset/limit 都是 JSON 标量串', () async {
      final t = FakeTransport();
      t.responses['SYNO.Chat.Post.thread_list'] = {
        'threads': [
          {'post_id': 4294967300, 'channel_id': 1, 'message': '话题'},
        ],
      };
      final api = await _api(t);

      final list = await api.listThreads(
        channelId: 1,
        offset: 0,
        limit: 20,
        relatedCommentCount: 3,
      );
      final call = _lastOf(t, 'SYNO.Chat.Post.thread_list');
      expect(_v(call), 5);
      expect(call['offset'], '0');
      expect(call['limit'], '20');
      expect(call['related_comment_count'], '3');
      expect(list.single['message'], '话题');
    });

    test('viewChannelThreads：带 thread_id 用 v2，不带用 v1；返回已读时间', () async {
      final t = FakeTransport();
      t.responses['SYNO.Chat.Post.Subscribe.view'] = {
        'last_view_comment_at': 1789000000000,
      };
      final api = await _api(t);

      final all = await api.viewChannelThreads(channelId: 1, connId: 'C1');
      expect(_v(_lastOf(t, 'SYNO.Chat.Post.Subscribe.view')), 1);
      expect(all, 1789000000000);

      final one = await api.viewChannelThreads(
        channelId: 1,
        connId: 'C1',
        threadId: 4294967300,
      );
      final call = _lastOf(t, 'SYNO.Chat.Post.Subscribe.view');
      expect(_v(call), 2);
      expect(call['thread_id'], '4294967300');
      expect(one, 1789000000000);
    });
  });

  group('版本协商 vs 真实 NAS 的 API 表', () {
    // test/fixtures/api_table.json 是真机 query.cgi 抓下来的 977 个 API 的
    // 完整版本表（tool/probe_api_table.dart 落盘）。
    // 这里校验"我们写死的候选版本"在真机上真的可用 —— 候选写超了会静默降到
    // 别的方法版本，是很难发现的坑。
    final table =
        jsonDecode(File('test/fixtures/api_table.json').readAsStringSync())
            as Map<String, dynamic>;

    int maxVersionOf(String api) =>
        ((table[api] as Map?)?['maxVersion'] as num?)?.toInt() ?? -1;

    test('Post 家族：候选版本都不超过真机上限', () {
      expect(maxVersionOf('SYNO.Chat.Post'), 8);

      // 代码里用到的候选（与 chat_api.dart 保持一致）
      const used = <String, List<int>>{
        'SYNO.Chat.Post': [8, 7, 4, 3, 2, 1],
        'SYNO.Chat.Post.Reaction': [1],
        'SYNO.Chat.Post.Subscribe': [2, 1],
        'SYNO.Chat.Post.Hashtag': [1],
        'SYNO.Chat.Post.Vote': [1],
        'SYNO.Chat.Post.Schedule': [1],
        'SYNO.Chat.Channel': [5, 2, 1],
        'SYNO.Chat.User': [3, 2, 1],
      };
      used.forEach((api, candidates) {
        final max = maxVersionOf(api);
        expect(max, greaterThan(0), reason: '$api 应当存在');
        expect(
          candidates.reduce((a, b) => a > b ? a : b),
          lessThanOrEqualTo(max),
          reason: '$api 候选版本超过真机上限 $max',
        );
      });
    });

    test('Post/list 用的 v2、Post/create 用的 v7 都在范围内', () {
      final post = table['SYNO.Chat.Post'] as Map;
      expect(post['minVersion'], 1);
      expect(post['maxVersion'], greaterThanOrEqualTo(7));
    });
  });

  group('消息操作落库（控制器）', () {
    test('post.star / post.unstar 广播改本地 is_star', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        const PostDto(
          postId: 4294967300,
          channelId: 5,
          message: 'm',
          createAt: 1,
        ),
      ]);

      // star 的载荷是**完整 PostVo**
      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'post.star',
          'data': testPostJson,
        }),
      );
      var post = await store.postById(5, 4294967300);
      expect(post, isNotNull);
      expect(post!.isStar, isTrue);
    });

    test('post.star 落到本地已有那条（不改内容）', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        const PostDto(
          postId: 4294967300,
          channelId: 5,
          message: '原文',
          createAt: 1,
        ),
      ]);

      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'post.star',
          'data': {'post_id': 4294967300, 'channel_id': 5, 'is_star': true},
        }),
      );
      final post = await store.postById(5, 4294967300);
      expect(post!.isStar, isTrue);
      expect(post.message, '原文', reason: '星标广播不能把正文冲掉');
    });

    test(
      'post.pin / post.unpin：精简载荷只写 last_pin_at（对齐 PostHelper.pinPost）',
      () async {
        final h = await bootChat();
        final store = h.container.read(chatStoreProvider);
        await store.upsertPosts([
          const PostDto(postId: 55, channelId: 5, message: '置顶我', createAt: 1),
        ]);

        await h.ctrl.handleEvent(
          const ChatSocketEvent('client.broadcast', {
            'type': 'post.pin',
            'data': {
              'channel_id': 5,
              'post_id': 55,
              'last_pin_at': 8888,
              'user_id': 3,
            },
          }),
        );
        var post = await store.postById(5, 55);
        // 原版 `DatabaseHelper.pinPost(postId, lastPinAt)` 只更新 `last_pin_at`；
        // `is_sticky` 属于 `Post/stick` v2（话题置顶卡片），别混。
        expect(post!.lastPinAt, 8888);
        expect(post.isSticky, isFalse);
        expect(post.message, '置顶我');

        await h.ctrl.handleEvent(
          const ChatSocketEvent('client.broadcast', {
            'type': 'post.unpin',
            'data': {'channel_id': 5, 'post_id': 55, 'user_id': 3},
          }),
        );
        post = await store.postById(5, 55);
        expect(post!.lastPinAt, 0);
        expect(post.isSticky, isFalse);
      },
    );

    test('post.update：正文被改写', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        const PostDto(postId: 77, channelId: 5, message: '旧文本', createAt: 1),
      ]);

      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'post.update',
          'data': {
            'post_id': 77,
            'channel_id': 5,
            'creator_id': 14,
            'create_at': 1,
            'update_at': 2222,
            'type': 'normal',
            'message': '新文本',
          },
        }),
      );
      final post = await store.postById(5, 77);
      expect(post!.message, '新文本');
      expect(post.updateAt, 2222);
    });

    test('post.update 不带 channel_id 时按 post_id 反查', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        const PostDto(postId: 78, channelId: 5, message: '旧', createAt: 1),
      ]);

      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'post.update',
          'data': {'post_id': 78, 'message': '新', 'create_at': 1},
        }),
      );
      final post = await store.postById(5, 78);
      expect(post!.message, '新');
    });

    test('post.delete_batch：按 channel_id_list 整频道清空（管理员操作）', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts(const [
        PostDto(postId: 1, channelId: 5, message: 'a', createAt: 1),
        PostDto(postId: 2, channelId: 5, message: 'b', createAt: 2),
        PostDto(postId: 3, channelId: 6, message: 'c', createAt: 3),
      ]);

      // 权威形状：{channel_id_list: [..]}（原版 SocketHelper.deletePostByAdmin
      // 就读这个数组；之前我们猜成 {channel_id, post_ids} 是错的）
      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'post.delete_batch',
          'data': {
            'channel_id_list': [5],
          },
        }),
      );
      expect(await store.postsForChannel(5), isEmpty);
      // 没被点名的频道不受影响
      expect((await store.postsForChannel(6)).map((p) => p.postId), [3]);
    });

    test('channel.view_comment（整频道）清空话题未读', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.applyCommentCreate(channelId: 5, threadId: 100);
      await store.applyCommentCreate(channelId: 5, threadId: 200);
      var ch = (await store.allChannels()).single;
      expect(ch.unreadComment, 2);
      expect(ch.unreadThread[100], 1);

      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'channel.view_comment',
          'data': {
            'channel_id': 5,
            'last_view_comment_at': 4321,
            'user_id': 14,
          },
        }),
      );
      ch = (await store.allChannels()).single;
      expect(ch.unreadComment, 0);
      expect(ch.unreadThread, isEmpty);
      expect(ch.lastViewCommentAt, 4321);
    });

    test('channel.view_comment（带 thread_id）只清那一个话题', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.applyCommentCreate(channelId: 5, threadId: 100);
      await store.applyCommentCreate(channelId: 5, threadId: 200);

      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'channel.view_comment',
          'data': {
            'channel_id': 5,
            'thread_id': 100,
            'last_view_comment_at': 99,
            'user_id': 14,
          },
        }),
      );
      final ch = (await store.allChannels()).single;
      expect(ch.unreadThread.containsKey(100), isFalse);
      expect(ch.unreadThread[200], 1, reason: '别的话题未读要保留');
      expect(ch.unreadComment, 1);
    });

    test('别人的已读广播不落到我的频道上', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.applyCommentCreate(channelId: 5, threadId: 100);

      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.broadcast', {
          'type': 'channel.view_comment',
          'data': {'channel_id': 5, 'last_view_comment_at': 1, 'user_id': 3},
        }),
      );
      expect((await store.allChannels()).single.unreadComment, 1);
    });

    test('话题回复的 post.create：父消息回复数 +1、话题未读 +1', () async {
      // 假服务端要返回**那条回复**（真实服务端就是按 post_id 锚点捞回来的）
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Post.list': {
            'posts': [
              {
                'post_id': 4294967400,
                'channel_id': 5,
                'creator_id': 3,
                'create_at': 2000,
                'thread_id': 4294967300,
                'type': 'normal',
                'message': '回复正文',
              },
            ],
          },
        },
      );
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        const PostDto(
          postId: 4294967300,
          channelId: 5,
          message: '父消息',
          createAt: 1,
        ),
      ]);

      await h.ctrl.handleEvent(
        const ChatSocketEvent('client.post.create', {
          'user_id': 3,
          'channel_id': 5,
          'data': {
            'creator_id': 3,
            'post_id': 4294967400,
            'thread_id': 4294967300,
            'create_at': 2000,
          },
        }),
      );

      final parent = await store.postById(5, 4294967300);
      expect(parent!.commentCount, 1);
      expect(parent.lastCommentAt, 2000);

      final ch = (await store.allChannels()).single;
      expect(ch.unreadComment, 1);
      expect(ch.unreadThread[4294967300], 1);
    });

    test('回应：本地乐观更新照服务端形状（一条记录 + user_ids）', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        const PostDto(postId: 50, channelId: 5, message: 'm', createAt: 1),
      ]);

      // 别人先点了个 👍
      await store.applyPostPatch(
        5,
        50,
        reactions: [
          {
            'sticker_name': 'thumbsup',
            'user_ids': [3],
          },
        ],
      );

      expect(
        await h.ctrl.setReaction(5, 50, on: true, stickerName: 'thumbsup'),
        isTrue,
      );
      var post = (await store.postById(5, 50))!;
      expect(post.reactions.length, 1, reason: '同一个表情只有一条记录');
      expect(post.reactions.single['user_ids'], containsAll(<int>[3, 14]));

      // 再点一次（取消）→ 只剩别人
      await h.ctrl.setReaction(5, 50, on: false, stickerName: 'thumbsup');
      post = (await store.postById(5, 50))!;
      expect(post.reactions.single['user_ids'], [3]);

      // 新表情：自己点 → 新增一条记录
      await h.ctrl.setReaction(5, 50, on: true, stickerName: 'joy');
      post = (await store.postById(5, 50))!;
      expect(post.reactions.length, 2);
      final joy = post.reactions.firstWhere((r) => r['sticker_name'] == 'joy');
      expect(joy['user_ids'], [14]);
      // 短代码原样发（服务端两种都收，见 docs/phase4-protocol.md §4）
      expect(
        h.transport.calls.any(
          (c) =>
              '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.Reaction.set' &&
              c['sticker_name'] == 'joy',
        ),
        isTrue,
      );
    });

    test('服务端不支持置顶（407）→ 不反复失败，而是记住并让 UI 隐藏', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.pin'] = 407;
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts([
        const PostDto(postId: 42, channelId: 5, message: 'm', createAt: 1),
      ]);

      final ok = await h.ctrl.setPin(5, 42, pin: true);
      expect(ok, isFalse);
      expect(
        h.container.read(chatSessionControllerProvider).pinUnsupported,
        isTrue,
        reason: '407 = CHAT_ERR_INVALID_RECORD，说明服务端没开置顶',
      );
      expect((await store.postById(5, 42))!.lastPinAt, 0);

      // 别的错误码不该触发这个降级
      final h2 = await bootChat();
      h2.transport.failures['SYNO.Chat.Post.pin'] = 403;
      await h2.container.read(chatStoreProvider).upsertPosts([
        const PostDto(postId: 43, channelId: 5, message: 'm', createAt: 1),
      ]);
      await h2.ctrl.setPin(5, 43, pin: true);
      expect(
        h2.container.read(chatSessionControllerProvider).pinUnsupported,
        isFalse,
      );
    });

    test('话题回复不混进频道主列表（thread_id 过滤）', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts(const [
        PostDto(postId: 1, channelId: 5, message: '主列表', createAt: 10),
        PostDto(
          postId: 2,
          channelId: 5,
          message: '回复',
          createAt: 11,
          threadId: 1,
        ),
      ]);

      final main = await store.postsForChannel(5);
      expect(main.map((p) => p.message), ['主列表']);
      final replies = await store.postsForChannel(5, threadId: 1);
      expect(replies.map((p) => p.message), ['回复']);
    });
  });

  group('长按菜单：复制文案（copy_text / copy_desc）', () {
    /// 挂起长按面板，等它铺开
    Future<void> open(WidgetTester tester, String type) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showPostActionsSheet(
                    context,
                    post: PostDto(
                      postId: 1,
                      channelId: 5,
                      creatorId: 14,
                      type: type,
                      message: '说明或正文',
                      createAt: 1,
                    ),
                    mine: true,
                    canWrite: true,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('文本消息 → 「复制文字」（copy_text）', (tester) async {
      await open(tester, 'normal');
      expect(find.text('复制文字'), findsOneWidget);
      expect(find.text('复制描述'), findsNothing);
    });

    testWidgets('文件消息 → 「复制描述」（copy_desc）', (tester) async {
      await open(tester, 'file');
      expect(find.text('复制描述'), findsOneWidget);
      expect(find.text('复制文字'), findsNothing);
    });
  });
}
