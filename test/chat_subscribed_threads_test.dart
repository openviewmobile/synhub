// P0 #2：订阅话题列表 —— 对齐官方 `CommentsFragment`（频道菜单 "Threads"）。
//
// 官方证据（反编译 2.11.1）：
//   * 入口：`res/menu/menu_channel.xml @+id/threads`（`ChannelFragment.java:645-646`
//     `showThreads(mChannelId)` → `MainActivity.java:974-975`
//     `showTabBookmarkFragment(channelId, 0)`）。
//   * 数据主路径：`CommentsPresenter.fetchAllSubscribedPosts` →
//     `AccountManager.fetchThreadList(channelId, offset, limit, 1)` →
//     `WebApiService.listThread(..., ChatPost.THREAD_LIST, 5, channelId, map)`
//     （`SYNO.Chat.Post / thread_list` v5；`offset`/`limit`/`related_comment_count`
//     都是 JSON 标量串）。服务端方法表：`thread_list` 在 `SYNO.Chat.Post` v5..8。
//   * 响应形状（`AccountManager.lambda$fetchThreadList$63`）：`search_results`
//     （话题父贴）+ `related_posts`（要来的相关评论）。
//   * 降级路径：`onErrorReturn` → `searchSubscribes(..., has:["subscribe"],
//     sort_by="last_comment_at")`；服务端 `SearchControl::HandleSubscribe`。
//   * 空态原文：`comments_empty` "No subscribed discussion threads."。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/chat/subscribed_threads_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Map<String, dynamic> threadPost(
  int id, {
  int channelId = 5,
  int threadId = 0,
  String message = '',
  int commentCount = 0,
}) => {
  'post_id': id,
  'channel_id': channelId,
  'creator_id': 14,
  'thread_id': threadId,
  'create_at': 1700000000000,
  'type': 'normal',
  'message': message,
  'comment_count': commentCount,
  'props': {'is_star': false},
};

void main() {
  group('chat_api.listThreads 的响应解析（官方 fetchThreadList 原文）', () {
    test('父贴在 search_results、相关评论在 related_posts，都收，按 post_id 去重', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.thread_list'] = {
        'search_results': [
          threadPost(100, message: '话题一'),
          threadPost(200, message: '话题二'),
        ],
        'related_posts': [
          threadPost(200, message: '话题二'),
          threadPost(300, message: '话题三'),
        ],
      };
      final list = await h.apiForTest.listThreads(channelId: 5, limit: 30);
      expect(list.map((e) => e['post_id']), [100, 200, 300]);
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.thread_list',
      );
      expect(call['version'], '5');
      expect(call['channel_id'], '5');
    });

    test('老假服务端只回 threads/posts 的兼容分支仍在', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.thread_list'] = {
        'threads': [threadPost(7, message: '旧形状')],
      };
      final list = await h.apiForTest.listThreads(channelId: 5);
      expect(list.single['message'], '旧形状');
    });
  });

  group('控制器取数（主路径 / 降级）', () {
    test('服务端支持 v5 → 走 thread_list，只留父贴', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.thread_list'] = {
        'search_results': [
          threadPost(100, message: '话题一', commentCount: 2),
          // 回复（thread_id != post_id）要被过滤掉
          threadPost(101, threadId: 100, message: '一条回复'),
        ],
      };
      final list = await h.ctrl.listSubscribedThreads(5);
      expect(list.map((p) => p.postId), [100]);
      expect(
        h.transport.calls.any(
          (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.thread_list',
        ),
        isTrue,
      );
    });

    test('服务端不支持 v5 → 降级 search has:["subscribe"] + in:[channelId]', () async {
      final h = await bootChat(
        apiTable: {
          ...FakeTransport.table,
          'SYNO.Chat.Post': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 4,
          },
        },
      );
      h.transport.responses['SYNO.Chat.Post.search'] = {
        'search_results': [threadPost(100, message: '话题一')],
        'total': 1,
        'offset': 0,
        'limit': 30,
      };
      final list = await h.ctrl.listSubscribedThreads(5);
      expect(list.map((p) => p.postId), [100]);
      expect(
        h.transport.calls.any(
          (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.thread_list',
        ),
        isFalse,
      );
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      expect(call['has'], '["subscribe"]');
      expect(call['in'], '[5]');
    });

    test('thread_list 报错 → 也降级到 search', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.thread_list'] = 407;
      h.transport.responses['SYNO.Chat.Post.search'] = {
        'search_results': [threadPost(100, message: '话题一')],
        'total': 1,
        'offset': 0,
        'limit': 30,
      };
      final list = await h.ctrl.listSubscribedThreads(5);
      expect(list.map((p) => p.postId), [100]);
      expect(
        h.transport.calls.any(
          (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
        ),
        isTrue,
      );
    });
  });

  group('页面', () {
    Future<void> pump(WidgetTester tester, ProviderContainer c) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: SubscribedThreadsPage(channelId: 5)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('列出订阅话题（标题 + 行 + 回复数）', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.thread_list'] = {
        'search_results': [
          threadPost(100, message: '订阅的话题甲', commentCount: 3),
          threadPost(200, message: '订阅的话题乙', commentCount: 1),
        ],
      };
      await pump(tester, h.container);
      expect(find.text('订阅话题'), findsWidgets);
      expect(find.textContaining('订阅的话题甲'), findsOneWidget);
      expect(find.textContaining('3 条回复'), findsOneWidget);
    });

    testWidgets('空列表 → 「还没有订阅的话题」', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.thread_list'] = {
        'search_results': [],
      };
      await pump(tester, h.container);
      expect(find.text('还没有订阅的话题'), findsOneWidget);
    });
  });
}
