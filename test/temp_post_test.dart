// 「没发出去的消息」（失败 state=2 / 已过期 state=3）的本地语义 + 长按面板。
//
// 对齐原版：
//   * `ChannelFragment.enterChannel()` → `updateDBAllOutDatedPosts`：
//     进频道时把 `state != 0` 的行写成 `state = 3` 并把 `create_at` 改成"现在"
//     （`DatabaseHelper.updateAllOutdatedPosts`，`DatabaseHelper.java:1298`）；
//   * 侧栏"有失败消息就不藏"的例外判定用的是 `state = 3 OR state = 2`
//     （`DatabaseHelper.observeAllOutDatedPosts`，`:1514`）；
//   * 长按这类消息 → `R.array.temp_operation` = 重新发送 / 编辑 / 删除
//     （贴纸只有 `temp_sticker_operation` = 重新发送 / 删除）；
//   * 「重新发送」= `ChannelPresenter.resendPost` → 重发 → 成功后删本地 temp 行；
//   * 「删除」= `deleteTemp`：**只删本地**，不打服务端。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/post_actions_sheet.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

void main() {
  group('ChatStore：temp 消息', () {
    late ChatDatabase db;
    late ChatStore store;

    setUp(() {
      db = ChatDatabase(NativeDatabase.memory());
      store = ChatStore(db);
    });
    tearDown(() => db.close());

    Future<int> pending(int channelId, String text, {int at = 1000}) =>
        store.insertPendingPost(
          channelId: channelId,
          creatorId: 14,
          message: text,
          nowMillis: at,
        );

    test('markOutdatedPosts：只动 state != 0 的行，并把 create_at 推到"现在"', () async {
      final a = await pending(5, '发不出去的消息');
      await pending(5, '另一条也没发出去', at: 2000);
      // 服务端已确认的消息（state 0）不该被动
      await store.upsertPosts([
        const PostDto(
          postId: 900,
          channelId: 5,
          message: '正常消息',
          createAt: 500,
        ),
      ]);
      await store.failPendingPost(5, a);

      await store.markOutdatedPosts(5, nowMillis: 7777);

      final posts = await store.postsForChannel(5);
      final temp = posts.where((p) => p.postId == 0).toList();
      expect(temp, hasLength(2));
      for (final p in temp) {
        expect(p.state, 3, reason: '原版 updateAllOutdatedPosts 写的就是 3');
        expect(p.createAt, 7777, reason: 'create_at 会被改成"现在"');
      }
      final normal = posts.firstWhere((p) => p.postId == 900);
      expect(normal.state, 0);
      expect(normal.createAt, 500);
    });

    test('markOutdatedPosts 不跨频道', () async {
      await pending(5, 'A 频道');
      await pending(6, 'B 频道');
      await store.markOutdatedPosts(5, nowMillis: 1);
      expect((await store.postsForChannel(6)).single.state, 1);
    });

    test('同一毫秒发多条不会撞 dedupe_key（跨频道也不行）', () async {
      // 默认 temp id 就是毫秒时间戳，早先 dedupe_key 是 't:<id>'（全球唯一）
      // → 同毫秒两条直接 SqliteException(2067)。现在键带频道 + 自动后移 id。
      final a = await pending(5, '同毫秒 A');
      final b = await pending(5, '同毫秒 B');
      final c = await pending(6, '同毫秒 C');
      expect(a, isNot(b), reason: '同频道同毫秒要自增出不同的 temp id');
      expect(c, a, reason: '不同频道可以复用同一个 temp id —— 去重键里带了频道，不冲突');
      expect(await store.postsForChannel(5), hasLength(2));
      expect(await store.postsForChannel(6), hasLength(1));
    });

    test('deletePendingPost：只删本地那条（post_id == 0）', () async {
      final tmp = await pending(5, '删我');
      await store.upsertPosts([
        const PostDto(postId: 901, channelId: 5, message: '服务端消息', createAt: 1),
      ]);
      // 用服务端 post_id 当 tmp 调删除 → 不该删掉真消息
      await store.deletePendingPost(5, 901);
      expect(await store.postsForChannel(5), hasLength(2));

      await store.deletePendingPost(5, tmp);
      final left = await store.postsForChannel(5);
      expect(left, hasLength(1));
      expect(left.single.postId, 901);
    });

    test('watchChannelsWithFailedPosts 认 state 2 和 3（侧栏不藏频道的例外）', () async {
      final a = await pending(5, 'x', at: 1000);
      await pending(6, 'y', at: 2000);
      await store.failPendingPost(5, a);
      await store.markOutdatedPosts(6, nowMillis: 1);

      final set = await store.watchChannelsWithFailedPosts().first;
      expect(
        set,
        containsAll(<int>[5, 6]),
        reason: '原版 observeAllOutDatedPosts 是 state=3 OR state=2',
      );
    });

    test('updatePendingMessage 改正文但不动 state', () async {
      final tmp = await pending(5, '打错了');
      await store.failPendingPost(5, tmp);
      await store.updatePendingMessage(5, tmp, '改好了');
      final p = (await store.postsForChannel(5)).single;
      expect(p.message, '改好了');
      expect(p.state, 2);
    });
  });

  group('控制器：进频道标过期 / 重发 / 删除 / 编辑', () {
    test(
      'enterChannel 顺手把没发成功的消息标成 3（原版 order：enter → outdated → 拉消息）',
      () async {
        final h = await bootChat();
        h.transport.responses['SYNO.Chat.Channel.enter'] = const {};
        final store = h.container.read(chatStoreProvider);
        final tmp = await store.insertPendingPost(
          channelId: 5,
          creatorId: h.ctrl.state.myUserId,
          message: '发不出去',
          nowMillis: 1,
        );
        await store.failPendingPost(5, tmp);

        await h.ctrl.enterChannel(5);

        final p = (await store.postsForChannel(5)).single;
        expect(p.state, 3);
        expect(p.createAt, greaterThan(1), reason: 'create_at 被推到"现在"');
      },
    );

    test('resendPost：重发成功后本地 temp 行消失（服务端那条留着）', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      h.transport.responses['SYNO.Chat.Post.create'] = {
        'post': {
          'post_id': 424242,
          'channel_id': 5,
          'creator_id': 14,
          'create_at': 4242,
          'type': 'normal',
          'message': '会失败的消息',
        },
      };
      // 先让发送失败一次
      h.transport.failures['SYNO.Chat.Post.create'] = 407;
      expect(await h.ctrl.sendMessage(5, '会失败的消息'), isFalse);
      var posts = await store.postsForChannel(5);
      expect(posts.single.state, 2);
      final failed = posts.single;

      // 网络恢复 → 重新发送
      h.transport.failures.remove('SYNO.Chat.Post.create');
      expect(await h.ctrl.resendPost(failed), isTrue);

      posts = await store.postsForChannel(5);
      expect(
        posts.where((p) => p.postId == 0),
        isEmpty,
        reason: 'temp 行要删掉，否则会出现两条一样的消息',
      );
      expect(posts.any((p) => p.message == '会失败的消息' && p.postId > 0), isTrue);
    });

    test('resendPost：附件重发（本地文件还在）走上传那条路', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      h.transport.responses['SYNO.Chat.Post.create'] = {
        'post': {
          'post_id': 424244,
          'channel_id': 5,
          'creator_id': 14,
          'create_at': 4244,
          'type': 'file',
          'message': 'note.txt',
          'file_props': {
            'name': 'note.txt',
            'size': 5,
            'type': 'txt',
            'source': 'upload',
          },
        },
      };
      final dir = await Directory.systemTemp.createTemp('flt-temp-post');
      final file = File('${dir.path}/note.txt');
      await file.writeAsString('hello');

      final tmp = await store.insertPendingPost(
        channelId: 5,
        creatorId: h.ctrl.state.myUserId,
        message: 'note.txt',
        nowMillis: 1,
        type: 'file',
      );
      await store.failPendingPost(5, tmp);
      h.ctrl.state = h.ctrl.state.copyWith(pendingFiles: {tmp: file.path});
      final failed = (await store.postsForChannel(5)).single;

      expect(await h.ctrl.resendPost(failed), isTrue);
      expect(
        (await store.postsForChannel(5)).where((p) => p.postId == 0),
        isEmpty,
      );

      // 本地文件没了 → 老老实实返回 false，绝不把文件名当文字发出去
      final tmp2 = await store.insertPendingPost(
        channelId: 5,
        creatorId: h.ctrl.state.myUserId,
        message: 'gone.txt',
        nowMillis: 2,
        type: 'file',
      );
      await store.failPendingPost(5, tmp2);
      final failed2 = (await store.postsForChannel(
        5,
      )).firstWhere((p) => p.tmpPostId == 2);
      expect(await h.ctrl.resendPost(failed2), isFalse);
      await dir.delete(recursive: true);
    });

    test('deleteTempPost：只删本地，不发任何请求', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      final tmp = await store.insertPendingPost(
        channelId: 5,
        creatorId: h.ctrl.state.myUserId,
        message: '删我',
        nowMillis: 1,
      );
      await store.failPendingPost(5, tmp);
      final failed = (await store.postsForChannel(5)).single;
      final before = h.transport.calls.length;

      await h.ctrl.deleteTempPost(failed);

      expect(await store.postsForChannel(5), isEmpty);
      expect(h.transport.calls.length, before, reason: '原版 deleteTemp 不打服务端');
    });

    test('editTempPost：先改本地正文再重发', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      h.transport.responses['SYNO.Chat.Post.create'] = {
        'post': {
          'post_id': 424243,
          'channel_id': 5,
          'creator_id': 14,
          'create_at': 4243,
          'type': 'normal',
          'message': '改好了',
        },
      };
      h.transport.failures['SYNO.Chat.Post.create'] = 407;
      await h.ctrl.sendMessage(5, '打错了');
      final failed = (await store.postsForChannel(5)).single;
      h.transport.failures.remove('SYNO.Chat.Post.create');

      expect(await h.ctrl.editTempPost(failed, '改好了'), isTrue);
      final posts = await store.postsForChannel(5);
      expect(posts.single.message, '改好了');
      expect(posts.single.postId, greaterThan(0));
    });
  });

  group('长按面板', () {
    Future<void> pumpSheet(WidgetTester tester, PostDto post) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTempPostActionsSheet(context, post: post),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('普通消息：重新发送 / 编辑 / 删除', (tester) async {
      await pumpSheet(
        tester,
        const PostDto(
          postId: 0,
          channelId: 5,
          message: '发不出去',
          state: 2,
          tmpPostId: 9,
        ),
      );
      expect(find.text('重新发送'), findsOneWidget);
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('贴纸：没有「编辑」（原版 temp_sticker_operation 只有重发/删除）', (tester) async {
      await pumpSheet(
        tester,
        const PostDto(
          postId: 0,
          channelId: 5,
          message: ':happy:',
          type: 'sticker',
          state: 3,
          tmpPostId: 9,
        ),
      );
      expect(find.text('重新发送'), findsOneWidget);
      expect(find.text('编辑'), findsNothing);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('聊天页长按失败消息：弹 temp 面板而不是普通面板', (tester) async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      final tmp = await store.insertPendingPost(
        channelId: 5,
        creatorId: h.ctrl.state.myUserId,
        message: '发不出去的消息',
        nowMillis: 1,
      );
      await store.failPendingPost(5, tmp);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: 5)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.longPress(find.text('发不出去的消息'));
      await tester.pumpAndSettle();

      expect(find.text('重新发送'), findsOneWidget);
      expect(find.text('星标'), findsNothing, reason: 'temp 消息不给普通操作面板');

      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(await store.postsForChannel(5), isEmpty);
    });

    testWidgets('聊天页**单击**失败消息也弹 temp 面板（原版 onClick 那个入口）', (tester) async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      final tmp = await store.insertPendingPost(
        channelId: 5,
        creatorId: h.ctrl.state.myUserId,
        message: '点我一下',
        nowMillis: 1,
      );
      await store.failPendingPost(5, tmp);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: 5)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('点我一下'));
      await tester.pumpAndSettle();
      expect(find.text('重新发送'), findsOneWidget);

      // 正常消息单击不弹任何东西（原版 onClick 对 state 0 不做动作）
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('重新发送'), findsNothing);
    });
  });
}
