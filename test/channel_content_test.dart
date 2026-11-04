// 频道内容列表（置顶 / 文件 / 链接 / @我）—— 对齐原版
// `TabPostFragment`（PostFragment/FileFragment/UrlFragment）+ `MentionFragment`。
//
// 全部走 `SYNO.Chat.Post / search`，只是过滤条件不同：
//   pinned → has:["pin"]（老服务端 has:["thread"]）
//   files  → has:["file"]（Post v3 起挪到 post_type）
//   links  → has:["url"]
//   mentions → mention:[myUserId]
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:synhub/src/core/settings/server_settings.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/server_settings_dto.dart';
import 'package:synhub/src/features/chat/channel_content_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

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
  int creatorId = 14,
  bool sticky = false,
  bool star = false,
  Map<String, dynamic>? extra,
}) => {
  'post_id': id,
  'channel_id': 5,
  'creator_id': creatorId,
  'create_at': 1700000000000,
  'type': 'normal',
  'message': message,
  'props': {'is_sticky': sticky, 'is_star': star},
  ...?extra,
};

List<Map<String, dynamic>> manyPosts(int n, {int from = 1}) => [
  for (var i = 0; i < n; i++) postJson(from + i, message: '第 ${from + i} 条'),
];

void main() {
  group('搜索条件（原版各 presenter 的 getHas）', () {
    PostSearchQuery q(
      ChannelContentKind kind, {
      bool subscribe = true,
      int myUserId = 14,
    }) => channelContentQuery(
      kind: kind,
      channelId: 5,
      myUserId: myUserId,
      supportsSubscribeApi: subscribe,
    );

    test('置顶：支持订阅用 has pin，否则退回 thread', () {
      expect(q(ChannelContentKind.pinned).has, ['pin']);
      expect(q(ChannelContentKind.pinned, subscribe: false).has, ['thread']);
      expect(q(ChannelContentKind.pinned).inChannels, [5]);
    });

    test('文件 / 链接：has file / url', () {
      expect(q(ChannelContentKind.files).has, ['file']);
      expect(q(ChannelContentKind.links).has, ['url']);
    });

    test('@我：mention=[myUserId]，不带 has', () {
      final query = q(ChannelContentKind.mentions, myUserId: 7);
      expect(query.mentions, [7]);
      expect(query.has, isEmpty);
    });

    test('都限定在频道内，分页参数跟着 offset/limit 走', () {
      final query = channelContentQuery(
        kind: ChannelContentKind.links,
        channelId: 9,
        myUserId: 1,
        supportsSubscribeApi: true,
        offset: 30,
        limit: 15,
      );
      expect(query.inChannels, [9]);
      expect(query.offset, 30);
      expect(query.limit, 15);
    });
  });

  group('请求真的发对了（含 Post v3 的 post_type 迁移）', () {
    test('链接列表：in + has，没有 post_type', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(1, message: '看 https://a.b'),
      ]);
      final r = await h.apiForTest.searchPosts(
        channelContentQuery(
          kind: ChannelContentKind.links,
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
      expect(call['has'], '["url"]');
      expect(call['post_type'], isNull);
      expect(call['limit'], '30');
    });

    test('文件列表：v3 上 has 变 post_type=["file"]', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([]);
      await h.apiForTest.searchPosts(
        channelContentQuery(
          kind: ChannelContentKind.files,
          channelId: 5,
          myUserId: 14,
          supportsSubscribeApi: true,
        ),
      );
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      expect('${call['version']}', '5');
      expect(call['post_type'], '["file"]');
      expect(call['has'], isNull, reason: 'v3 起 file 归 post_type');
    });

    test('@我：mention=[14]', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([]);
      await h.apiForTest.searchPosts(
        channelContentQuery(
          kind: ChannelContentKind.mentions,
          channelId: 5,
          myUserId: 14,
          supportsSubscribeApi: true,
        ),
      );
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      expect(call['mention'], '[14]');
      expect(call['has'], isNull);
    });

    test('老服务端（Post.maxVersion<3）：file 留在 has 里', () async {
      final h = await bootChat(
        apiTable: {
          ...FakeTransport.table,
          'SYNO.Chat.Post': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 2,
          },
        },
      );
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([]);
      await h.apiForTest.searchPosts(
        channelContentQuery(
          kind: ChannelContentKind.files,
          channelId: 5,
          myUserId: 14,
          supportsSubscribeApi: true,
        ),
      );
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      expect('${call['version']}', '2');
      expect(call['has'], '["file"]');
      expect(call['post_type'], isNull);
    });
  });

  group('页面', () {
    Future<void> pump(
      WidgetTester tester,
      ProviderContainer c,
      ChannelContentKind kind, {
      GoRouter? router,
    }) async {
      final page = ChannelContentPage(channelId: 5, kind: kind);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: router == null
              ? MaterialApp(theme: AppTheme.dark(), home: page)
              : MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('标题是列表名，内容来自 search', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(11, message: '第一条链接 https://a.b'),
        postJson(12, message: '第二条链接', creatorId: 4),
      ]);
      await pump(tester, h.container, ChannelContentKind.links);
      expect(find.text('链接'), findsWidgets);
      expect(find.textContaining('第一条链接'), findsOneWidget);
      expect(find.textContaining('第二条链接'), findsOneWidget);
      // 别人的消息显示名字（本地库里没有 user 4 → 退化成「用户 4」）
      expect(find.text('用户 4'), findsOneWidget);
      expect(find.text('我'), findsOneWidget);
    });

    testWidgets('空列表给出对应文案', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([]);
      await pump(tester, h.container, ChannelContentKind.files);
      expect(find.text('这个频道还没有文件内容'), findsOneWidget);
    });

    testWidgets('失败 → 错误态 + 重试能再发一次', (tester) async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.search'] = 117;
      await pump(tester, h.container, ChannelContentKind.links);
      expect(find.textContaining('加载失败'), findsOneWidget);

      h.transport.failures.remove('SYNO.Chat.Post.search');
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(21, message: '重试后有了'),
      ]);
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('重试后有了'), findsOneWidget);
    });

    testWidgets('链接列表里画 OG 卡片；服务端要求隐藏时不画', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(
          31,
          message: '看 https://www.synology.com/',
          extra: {
            'url_props': [
              {
                'url': 'https://www.synology.com/',
                'title': 'Synology 官网',
                'image_prop': {'width': 1200, 'height': 628},
              },
            ],
          },
        ),
      ]);
      await pump(tester, h.container, ChannelContentKind.links);
      expect(find.text('Synology 官网'), findsOneWidget);

      h.container
          .read(serverSettingsProvider.notifier)
          .apply(ServerSettings.fromJson(const {}));
      h.container
          .read(serverSettingsProvider.notifier)
          .apply(ServerSettings(hidePostUrlPreview: true));
      await tester.pump();
      expect(find.text('Synology 官网'), findsNothing);
    });

    testWidgets('文件列表里出现附件行', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(
          41,
          message: '这是文件',
          extra: {
            'file_props': [
              {
                'file_id': 1,
                'post_id': 41,
                'name': 'report.pdf',
                'type': 'file',
                'size': 2048,
                'mime_type': 'application/pdf',
              },
            ],
          },
        ),
      ]);
      await pump(tester, h.container, ChannelContentKind.files);
      expect(find.textContaining('report.pdf'), findsOneWidget);
    });

    testWidgets('点一条 → 跳回频道正文的那条消息', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(51, message: '点我'),
      ]);
      final pushed = <String>[];
      final router = GoRouter(
        initialLocation: '/x',
        routes: [
          GoRoute(
            path: '/x',
            builder: (_, __) => ChannelContentPage(
              channelId: 5,
              kind: ChannelContentKind.links,
            ),
          ),
          // ChatPage 在这条用例里只记录"被跳到哪"，不真渲染（它要更多数据）
          GoRoute(
            path: '/chat/:channelId',
            builder: (_, state) {
              pushed.add(state.uri.toString());
              return const Scaffold(body: Text('频道正文'));
            },
          ),
        ],
      );
      await pump(tester, h.container, ChannelContentKind.links, router: router);
      await tester.tap(find.textContaining('点我'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(pushed, ['/chat/5?post=51']);
    });

    testWidgets('翻页：满一页就再拉下一页（offset 跟着走）', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse(
        manyPosts(30),
        total: 40,
      );
      await pump(tester, h.container, ChannelContentKind.links);
      final first = h.transport.calls
          .where((c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search')
          .toList();
      expect(first, hasLength(1));
      expect(first.single['offset'], '0');

      // 第二页（滚到底会触发；这里直接拖动到底部）
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse(
        manyPosts(10, from: 31),
        total: 40,
        offset: 30,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -4000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final calls = h.transport.calls
          .where((c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search')
          .toList();
      expect(calls.length, greaterThan(1), reason: '应该自动拉下一页');
      expect(calls.last['offset'], '30');
      expect(find.textContaining('第 31 条'), findsOneWidget);
    });
  });
}
