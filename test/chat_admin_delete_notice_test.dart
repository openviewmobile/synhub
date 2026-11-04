// ★ **②聊天 第 40 轮：管理员批量删除的「告知用户」**（审计行 **149**）
//
// ## 补的是什么
// 行 149 原判 **❌未实现「删除他人消息（管理员）」**。
// 取证后这个**定性是错的**：
//
//   `chat_apktool/res/values-en/strings.xml`：
//     `<string name="str_post_delete_by_admin">Some posts have been deleted by
//      admin. This page will be refreshed in a minute.</string>`
//   `values-zh-rCN`：部分帖子已被管理员删除。此页面将在一分钟后刷新。
//   `values-zh-rTW`：部分訊息已被系統管理者刪除，即將重新整理頁面。
//
// ⇒ 官方**根本没有**"删除他人消息"这个用户动作；它做的是：**服务端**（管理员/DSM）
//   删完，socket 推 `post.delete_batch` / `post.delete_search_list`，
//   客户端**清本地缓存并弹这句提示**（原版在 `SocketHelper.deletePostByAdmin` 里）。
//   这正是本仓反复强调的「**看到了 ≠ 是这样**」。
//
// 我方原本已按权威形状 `{channel_id_list:[..]}` 清空本地（`chat_session_controller.dart
// :985-996`，注释里还记着"之前猜成 `{channel_id, post_ids}` 是错的"），
// **但清完什么都没说** —— 消息**无声消失**，对用户是 bug。
//
// ⇒ 本轮补：`ChatSyncState.adminDeletedSeq` 计数 + `ChatPage` 里 `ref.listen`
//   弹官方原文。用**计数**不用 bool：连着来两次要能弹两次。
//
// ## 不做什么
// 不碰真机、不碰真 NAS（§5.1）。全程 widget 测试 + 内存 Mock。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 送一条 `client.broadcast` 给控制器（与 `test/chat_post_actions_test.dart:343` 同法）。
Future<void> _broadcast(
  ChatHarness h,
  String type,
  Map<String, Object?> data,
) => h.ctrl.handleEvent(
  ChatSocketEvent('client.broadcast', {'type': type, 'data': data}),
);

Widget _app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
);

void main() {
  group('AD-1. 控制器：收到管理员批量删除 → 计数 +1（否则 UI 收不到通知）', () {
    test('post.delete_batch 且真的清了频道 → adminDeletedSeq +1', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);
      await store.upsertPosts(const [
        PostDto(postId: 1, channelId: 5, message: 'a', createAt: 1),
      ]);
      expect(h.ctrl.state.adminDeletedSeq, 0);

      await _broadcast(h, 'post.delete_batch', {
        'channel_id_list': [5],
      });

      expect(await store.postsForChannel(5), isEmpty, reason: '本地还是要清');
      expect(
        h.ctrl.state.adminDeletedSeq,
        1,
        reason: '★ 清了就必须计数，否则用户永远不知道消息去哪了',
      );
    });

    test('post.delete_search_list 走同一条路（官方两个事件都弹这句）', () async {
      final h = await bootChat();
      await _broadcast(h, 'post.delete_search_list', {
        'channel_id_list': [5],
      });
      expect(h.ctrl.state.adminDeletedSeq, 1);
    });

    test('★ 反面对照：点名的是**别的**频道也要弹（用户可能在任一频道）', () async {
      final h = await bootChat();
      await _broadcast(h, 'post.delete_batch', {
        'channel_id_list': [999],
      });
      expect(
        h.ctrl.state.adminDeletedSeq,
        1,
        reason: '命中"有合法 cid"就算，不要求等于当前频道',
      );
    });

    test('★ 反面对照：空数组 / 全是非法 id → **不**计数（没清东西就别打扰用户）', () async {
      final h = await bootChat();
      await _broadcast(h, 'post.delete_batch', {'channel_id_list': <int>[]});
      expect(h.ctrl.state.adminDeletedSeq, 0);

      await _broadcast(h, 'post.delete_batch', {
        'channel_id_list': [0, -1, 'x'],
      });
      expect(h.ctrl.state.adminDeletedSeq, 0);
    });

    test('★ 反面对照：无关广播绝不计数（防"随便什么都弹"）', () async {
      final h = await bootChat();
      await _broadcast(h, 'channel.view_comment', {
        'channel_id': 5,
        'user_id': 1,
        'last_view_comment_at': 123,
      });
      await _broadcast(h, 'post.update', {'post_id': 1, 'channel_id': 5});
      expect(h.ctrl.state.adminDeletedSeq, 0);
    });

    test('★ 连续两次 → 计数到 2（这就是用计数不用 bool 的原因）', () async {
      final h = await bootChat();
      await _broadcast(h, 'post.delete_batch', {
        'channel_id_list': [5],
      });
      await _broadcast(h, 'post.delete_batch', {
        'channel_id_list': [5],
      });
      expect(h.ctrl.state.adminDeletedSeq, 2);
    });
  });

  group('AD-2. 页面：真的弹出官方那句提示', () {
    testWidgets('★ 收到 post.delete_batch → SnackBar 显示官方原文', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 一开始没有提示
      expect(find.text('部分帖子已被管理员删除。此页面将在一分钟后刷新。'), findsNothing);

      await _broadcast(h, 'post.delete_batch', {
        'channel_id_list': [5],
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text('部分帖子已被管理员删除。此页面将在一分钟后刷新。'),
        findsOneWidget,
        reason: '★ 官方 `str_post_delete_by_admin` 的 zh-rCN 原文，逐字一致',
      );
    });

    testWidgets('★ 反面对照：什么都不发 → 不弹（排除"永远显示"的假通过）', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('部分帖子已被管理员删除。此页面将在一分钟后刷新。'), findsNothing);
    });

    testWidgets('★文案与官方 strings.xml 逐字一致（防以后被顺手改掉）', (tester) async {
      // 原文取自 `chat_apktool/res/values-zh-rCN/strings.xml`：
      //   <string name="str_post_delete_by_admin">部分帖子已被管理员删除。此页面将在一分钟后刷新。</string>
      const officialZh = '部分帖子已被管理员删除。此页面将在一分钟后刷新。';
      expect(officialZh, isNotEmpty);
      final h = await bootChat();
      await tester.pumpWidget(_app(h.container, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _broadcast(h, 'post.delete_batch', {
        'channel_id_list': [5],
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(officialZh), findsOneWidget);
    });
  });
}
