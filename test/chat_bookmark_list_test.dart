// P0 #3：频道书签（星标）列表 + 取消星标 —— 对齐官方 `BookmarkFragment`。
//
// 官方证据（反编译 2.11.1）：
//   * 入口：`res/menu/menu_channel.xml @+id/bookmark`；`ChannelFragment.java:623`
//     `mCallbacks.showBookmarks(mChannelId)` → `MainActivity.showBookmarks` →
//     `showTabBookmarkFragment(channelId, 1)`。
//   * 数据：`BookmarkPresenter.getHas()` = `["star"]`（继承
//     `LoadMoreBasePresenter.fetchPosts` → `AccountManager.search(..., has, ...)`，
//     `in` 只有当前频道）；服务端 `SearchControl::HasStar(int)`。
//   * 取消：`BookmarkFragment.onRemoveBookmark(postId)` → `BookmarkPresenter.unstar`
//     → `AccountManager.unstarPost`（`SYNO.Chat.Post / unstar` v1，
//     `WebApiService.java:419` 只有 `post_id`）。
//   * 空态原文：`no_bookmark_available` "No bookmark available."。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/chat/channel_content_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Map<String, dynamic> searchResponse(List<Map<String, dynamic>> posts) => {
  'search_results': posts,
  'total': posts.length,
  'offset': 0,
  'limit': 30,
};

Map<String, dynamic> starred(
  int id, {
  String message = '',
  int channelId = 5,
}) => {
  'post_id': id,
  'channel_id': channelId,
  'creator_id': 14,
  'create_at': 1700000000000,
  'type': 'normal',
  'message': message,
  'props': {'is_star': true},
};

void main() {
  group('搜索条件（原版 BookmarkPresenter.getHas）', () {
    test('书签 = in:[channelId] + has:["star"]', () {
      final q = channelContentQuery(
        kind: ChannelContentKind.bookmarks,
        channelId: 5,
        myUserId: 14,
        supportsSubscribeApi: true,
      );
      expect(q.inChannels, [5]);
      expect(q.has, ['star']);
      expect(q.mentions, isEmpty);
    });

    test('标签是「书签」', () {
      expect(ChannelContentKind.bookmarks.label, '书签');
    });
  });

  test('请求真的发对了：in + has，且没有 post_type', () async {
    final h = await bootChat();
    h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
      starred(1, message: '被星标的'),
    ]);
    final r = await h.apiForTest.searchPosts(
      channelContentQuery(
        kind: ChannelContentKind.bookmarks,
        channelId: 5,
        myUserId: 14,
        supportsSubscribeApi: true,
      ),
    );
    expect(r.posts, hasLength(1));
    final call = h.transport.calls.singleWhere(
      (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
    );
    expect(call['in'], '[5]');
    expect(call['has'], '["star"]');
    expect(call['post_type'], isNull);
  });

  group('页面', () {
    Future<void> pump(WidgetTester tester, ProviderContainer c) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: ChannelContentPage(
              channelId: 5,
              kind: ChannelContentKind.bookmarks,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('列出星标消息', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        starred(11, message: '第一条星标'),
        starred(12, message: '第二条星标'),
      ]);
      await pump(tester, h.container);
      expect(find.text('书签'), findsWidgets);
      expect(find.textContaining('第一条星标'), findsOneWidget);
      expect(find.textContaining('第二条星标'), findsOneWidget);
      // 每行都有「取消星标」按钮
      expect(find.byIcon(Icons.bookmark_remove_outlined), findsNWidgets(2));
    });

    testWidgets('空列表给「这个频道还没有书签内容」', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([]);
      await pump(tester, h.container);
      expect(find.text('这个频道还没有书签内容'), findsOneWidget);
    });

    testWidgets('取消星标 → Post/unstar(post_id)，行从列表消失', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        starred(11, message: '第一条星标'),
        starred(12, message: '第二条星标'),
      ]);
      await pump(tester, h.container);

      // 点第一行的取消星标
      await tester.tap(find.byIcon(Icons.bookmark_remove_outlined).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.unstar',
      );
      expect(call['post_id'], '11');
      expect(call['version'], '1');
      expect(find.textContaining('第一条星标'), findsNothing);
      expect(find.textContaining('第二条星标'), findsOneWidget);
    });

    testWidgets('取消星标失败 → 行保留 + 失败提示', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        starred(11, message: '第一条星标'),
      ]);
      h.transport.failures['SYNO.Chat.Post.unstar'] = 117;
      await pump(tester, h.container);

      await tester.tap(find.byIcon(Icons.bookmark_remove_outlined).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('第一条星标'), findsOneWidget);
      expect(find.textContaining('取消星标失败'), findsOneWidget);
    });
  });
}
