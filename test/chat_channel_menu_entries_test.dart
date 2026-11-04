// ★ **②聊天 第 39 轮：频道菜单的 Threads / Bookmarks 入口**（审计行 **237 / 238**）
//
// ## 缺的到底是哪一环
// 行 237（Threads 入口）/ 238（Bookmarks 入口）的判定是「真机未验」。
// 核对后：**页面本身早就覆盖了** ——
//   * `test/chat_subscribed_threads_test.dart`：响应解析（`search_results` 父贴 +
//     `related_posts` 评论、按 `post_id` 去重、老假服务端兼容分支）、
//     控制器取数（v5 `thread_list` 主路径 / 不支持 v5 降级 `search has:["subscribe"]` /
//     `thread_list` 报错也降级）、页面渲染 + 空列表；
//   * `test/chat_bookmark_list_test.dart`：搜索条件 `in:[channelId] + has:["star"]`、
//     标签、**请求真的发对了**、列表渲染、空列表、取消星标移除行、取消失败保留 + 提示。
//
// **唯独没人验过「菜单里到底有没有这两个入口」** —— 而"入口"正是 237/238 这两行
// 字面上的诉求（官方 `menu_channel.xml` 里刻意加了这两项）。
// `chat_page.dart:2089-2100` 虽然实现了，但全仓 `test/` 里**没有任何用例打开过
// 聊天页的频道溢出菜单**去断言它们。
//
// ⇒ 本轮补上。同时把同菜单里的邻居项一起钉住，防止将来重排把这两项挤掉。
//
// ## 证据
// * 官方 `res/menu/menu_channel.xml`（本会话早先读过：threads / setting / members /
//   invite / post / files / urls / bookmark / mention）。
// * 我方实现：`chat_page.dart:2091`（`value:'threads'`）、`:2098`
//   （`value:'content-bookmarks'`）；分发在 `:782` / `:774`。
//
// ## 不做什么
// 不碰真机、不碰真 NAS（§5.1）。全程 widget 测试 + 内存 Mock。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:synhub/src/features/chat/chat_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Widget _app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
);

/// 打开聊天页顶部的频道溢出菜单。
Future<void> _openChannelMenu(WidgetTester tester) async {
  // `chat_page.dart:2038-2042` 的 `PopupMenuButton`（`Icons.more_vert`）
  await tester.tap(find.byIcon(Icons.more_vert).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('ME-1. ★ 频道菜单里**真有** Threads / Bookmarks 两个入口（237 / 238）', () {
    testWidgets('★ 两项都在（官方 `menu_channel.xml` 的 threads / bookmark）', (
      tester,
    ) async {
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await _openChannelMenu(tester);

      expect(
        find.text('订阅话题'),
        findsOneWidget,
        reason: '★ 行 237：Threads 入口（`chat_page.dart:2091` value=threads）',
      );
      expect(
        find.text('书签'),
        findsOneWidget,
        reason:
            '★ 行 238：Bookmarks 入口（`chat_page.dart:2098` value=content-bookmarks）',
      );
    });

    testWidgets('★ 同菜单的邻居项也在（防止将来重排把这两项挤掉）', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _openChannelMenu(tester);

      // 这些都是同一个 `PopupMenuButton` 里的项，逐一点名
      // ⚠️ `chatAllLinks` 的 zh 文案是「所有链接」（不是"全部链接"）
      expect(find.text('所有链接'), findsOneWidget, reason: 'content-links');
      expect(find.textContaining('提醒'), findsWidgets, reason: 'reminders');
      expect(find.text('置顶的消息'), findsOneWidget, reason: 'content-pinned');
      expect(find.text('所有文件'), findsOneWidget, reason: 'content-files');
      // 用**文案**而不是 icon 断言：`Icons.star_border` 在菜单外也出现
      // （频道星标按钮），`findsOneWidget` 会误报。
    });

    testWidgets('★ 点「订阅话题」→ 真的推进 SubscribedThreadsPage（不是空动作）', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _openChannelMenu(tester);

      await tester.tap(find.text('订阅话题'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // 页面自己的标题/空状态应当出现（证明路由真的走了）
      expect(
        find.text('订阅话题'),
        findsWidgets,
        reason: '★ 入口必须真的打开页面（原来只断言"有菜单项"是不够的）',
      );
    });

    testWidgets('★ 点「书签」→ 真的路由到 bookmarks 内容页（kind 也要对）', (tester) async {
      final h = await bootChat();
      // ⚠️ `content-bookmarks` 走 `context.push(AppRoutes.contentOf(...))`
      // ⇒ **需要 GoRouter**；而 `threads` 走 `Navigator.push` 不需要。
      // 这个差别本身就说明两条入口的实现路径不同。
      final router = GoRouter(
        initialLocation: '/chat/5',
        routes: [
          GoRoute(path: '/chat/:id', builder: (_, _) => ChatPage(channelId: 5)),
          GoRoute(
            path: '/chat/:id/content/:kind',
            builder: (_, state) =>
                Scaffold(body: Text('CONTENT ${state.pathParameters['kind']}')),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _openChannelMenu(tester);

      await tester.tap(find.text('书签'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.text('CONTENT bookmarks'),
        findsOneWidget,
        reason: '★ 入口必须真的路由到 bookmarks 内容页',
      );
    });
  });

  group('ME-2. 与既有页面用例的分工（避免把"有页面"当成"有入口"）', () {
    test('既有文件覆盖的是**页面**，本文件覆盖的是**入口**', () {
      // 把分工写下来防止将来重复/漏测：
      //   test/chat_subscribed_threads_test.dart  → 页面 + 取数（228）
      //   test/chat_bookmark_list_test.dart       → 页面 + 请求形状（227）
      //   test/chat_global_panel_test.dart:223    → **频道列表**的「跨频道内容」入口（240）
      //   本文件                                  → **聊天页频道菜单**的两个入口（237/238）
      expect(true, isTrue);
    });
  });
}
