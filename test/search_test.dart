// Phase 6 高级搜索：参数编码 / 结果形状 / 页面交互（离线）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/features/search/search_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 真机形状：结果在 `search_results`，另有 total/offset/limit
Map<String, dynamic> searchResponse(
  List<Map<String, dynamic>> posts, {
  int? total,
  int offset = 0,
  int limit = 30,
}) => {
  'search_results': posts,
  'total': total ?? posts.length,
  'offset': offset,
  'limit': limit,
};

Map<String, dynamic> postJson(
  int id, {
  String message = '',
  int channelId = 5,
  Map<String, dynamic>? extra,
}) => {
  'post_id': id,
  'channel_id': channelId,
  'creator_id': 14,
  'create_at': 1700000000000,
  'type': 'normal',
  'message': message,
  ...?extra,
};

void main() {
  group('searchPosts 参数', () {
    test('关键词 / 列表都 JSON 编码一次，offset+limit 是数字', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(100, message: 'hi'),
      ]);
      final r = await h.apiForTest.searchPosts(
        const PostSearchQuery(
          keyword: '你好',
          fromUsers: [14, 15],
          inChannels: [1, 2],
          hashtags: ['tag'],
          mentions: [7],
          has: ['star'],
          fileTypes: ['png'],
          after: 111,
          before: 222,
          offset: 10,
          limit: 20,
        ),
      );
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      expect(call['version'], '5');
      expect(call['keyword'], '"你好"');
      expect(call['from'], '[14,15]');
      expect(call['in'], '[1,2]');
      expect(call['hashtag'], '["tag"]');
      expect(call['mention'], '[7]');
      expect(call['has'], '["star"]');
      expect(call['file_type'], '["png"]');
      expect(call['after'], '111');
      expect(call['before'], '222');
      expect(call['offset'], '10');
      expect(call['limit'], '20');
      expect(r.posts, hasLength(1));
      expect(r.total, 1);
    });

    test('v>=3 时 has 里的 file/vote 挪进 post_type', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([]);
      await h.apiForTest.searchPosts(
        const PostSearchQuery(has: ['file', 'vote', 'star']),
      );
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      // has 里只剩 star，file/vote 去了 post_type
      expect(call['has'], '["star"]');
      expect(call['post_type'], '["file","vote"]');
    });

    test('v2 的服务器不搬（保持旧行为）', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([]);
      await h.apiForTest.searchPosts(
        const PostSearchQuery(has: ['file']),
        versionCandidates: const [2],
      );
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      expect(call['has'], '["file"]');
      expect(call.containsKey('post_type'), isFalse);
    });

    test('空条件不塞多余字段', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([]);
      await h.apiForTest.searchPosts(const PostSearchQuery(limit: 30));
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      for (final k in [
        'keyword',
        'from',
        'in',
        'hashtag',
        'mention',
        'has',
        'post_type',
        'file_type',
        'after',
        'before',
      ]) {
        expect(call.containsKey(k), isFalse, reason: '不该带 $k');
      }
      expect(call['offset'], '0');
      expect(call['limit'], '30');
    });

    test('结果里被删掉的消息要滤掉（控制器层过滤）', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(1, message: '还在'),
        postJson(2, message: '已删', extra: {'delete_at': 1700000000000}),
      ]);
      final ctrl = h.container.read(searchControllerProvider.notifier);
      await ctrl.search();
      final state = h.container.read(searchControllerProvider);
      expect(state.posts.map((p) => p.postId), [1]);
      expect(state.total, 2, reason: 'total 用服务端给的数');
    });
  });

  group('搜索页', () {
    Future<void> pump(WidgetTester tester, ChatHarness h) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: SearchPage()),
        ),
      );
      await tester.pump();
    }

    testWidgets('输入关键词回车 → 出结果 + 共 N 条', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(101, message: 'flt-p6-命中'),
      ], total: 1);
      await pump(tester, h);

      await tester.enterText(find.byType(TextField).first, 'flt-p6');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('共 1 条'), findsOneWidget);
      expect(find.textContaining('flt-p6-命中'), findsOneWidget);
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      expect(call['keyword'], '"flt-p6"');
    });

    testWidgets('筛选 chip 会带上 has 参数', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([]);
      await pump(tester, h);

      await tester.tap(find.text('星标'));
      await tester.pump();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      expect(call['has'], '["star"]');
      expect(find.text('没有匹配的消息'), findsOneWidget);
    });

    testWidgets('加载更多用 offset 续页', (tester) async {
      final h = await bootChat();
      // 第一页 30 条 / 共 60 → 滚到底继续拉
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        for (var i = 0; i < 30; i++) postJson(1000 + i, message: '第 $i 条'),
      ], total: 60);
      await pump(tester, h);
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      final ctrl = h.container.read(searchControllerProvider.notifier);
      expect(h.container.read(searchControllerProvider).hasMore, isTrue);
      // 第二页换成另一批
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse(
        [for (var i = 0; i < 30; i++) postJson(2000 + i, message: '第二批 $i')],
        total: 60,
        offset: 30,
      );
      await ctrl.loadMore();
      await tester.pumpAndSettle();

      final calls = h.transport.calls
          .where((c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search')
          .toList();
      expect(calls.last['offset'], '30');
      final state = h.container.read(searchControllerProvider);
      expect(state.posts, hasLength(60));
      expect(state.posts.first.postId, 1000);
      expect(state.posts.last.postId, 2029);
      expect(state.hasMore, isFalse);
    });

    testWidgets('服务端报错时给出错误文案', (tester) async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.search'] = 403;
      await pump(tester, h);
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.textContaining('搜索失败'), findsOneWidget);
    });

    testWidgets('结果里显示频道名和附件', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(
          102,
          message: '带附件的消息',
          extra: {
            'type': 'file',
            'file_props': {'name': 'note.pdf', 'type': 'pdf', 'size': 1024},
          },
        ),
      ]);
      await pump(tester, h);
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.text('note.pdf'), findsOneWidget);
      expect(find.textContaining('带附件的消息'), findsOneWidget);
    });
  });
}
