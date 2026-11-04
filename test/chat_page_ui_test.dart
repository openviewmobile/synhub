// 第 2 批（聊天页 HUD 改造）新增界面的离线验证：
//   日期分隔 / 未读水位线 / 滚动到底球 / 附件宫格面板 / 形态切换球
//
// 这些都是"新加的东西"，不是原版行为，所以独立一个文件，别和
// `chat_page_test.dart`（对位原版的用例）混在一起。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Widget _app(ProviderContainer c, int channelId) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChatPage(channelId: channelId)),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 相对"现在"造时间戳：`days=0` 就是今天（分隔线要显示"今天"这类相对文案，
/// 所以不能用写死的日期）
int _at(int daysAgo, int hour) {
  final now = DateTime.now();
  final d = now.subtract(Duration(days: daysAgo));
  return DateTime(d.year, d.month, d.day, hour, 30).millisecondsSinceEpoch;
}

void main() {
  testWidgets('跨天消息之间有日期分隔（今天/昨天/更早）', (tester) async {
    final h = await bootChat();
    final store = h.container.read(chatStoreProvider);
    await store.upsertPosts([
      // 用"今天/昨天"不好造，直接用固定日期走"月日"分支 + 相对日期分支
      PostDto(
        postId: 20,
        channelId: 5,
        creatorId: 3,
        message: '前天的消息',
        createAt: _at(2, 9),
      ),
      PostDto(
        postId: 21,
        channelId: 5,
        creatorId: 3,
        message: '昨天的消息',
        createAt: _at(1, 9),
      ),
      PostDto(
        postId: 22,
        channelId: 5,
        creatorId: 3,
        message: '今天的消息',
        createAt: _at(0, 9),
      ),
    ]);

    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);

    // 每"天"一条分隔线：三条消息跨三天 → 三条分隔
    expect(find.text('前天'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('今天的消息'), findsOneWidget);
  });

  testWidgets('同一天内不重复画分隔线，且同一人的连续消息只有一次名字', (tester) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.User.list': {
          'users': [
            {
              'user_id': 14,
              'username': 'me',
              'type': 'human',
              'status': 'online',
            },
            {
              'user_id': 3,
              'username': 'bob',
              'nickname': '小波',
              'type': 'human',
              'status': 'online',
            },
          ],
        },
      },
    );
    final store = h.container.read(chatStoreProvider);
    await store.upsertPosts([
      PostDto(
        postId: 30,
        channelId: 5,
        creatorId: 3,
        message: '第一条',
        createAt: _at(0, 9),
      ),
      PostDto(
        postId: 31,
        channelId: 5,
        creatorId: 3,
        message: '第二条',
        createAt: _at(0, 10),
      ),
      PostDto(
        postId: 32,
        channelId: 5,
        creatorId: 3,
        message: '第三条',
        createAt: _at(0, 11),
      ),
    ]);

    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);

    expect(find.text('今天'), findsOneWidget, reason: '同一天只画一条分隔线');
    // 连续三条同一个人：名字只出现在这一段的第一条上（分组）
    expect(find.text('小波'), findsOneWidget);
    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第三条'), findsOneWidget);
  });

  testWidgets('进频道后新到的消息上方画「以下为新消息」', (tester) async {
    final h = await bootChat();
    final store = h.container.read(chatStoreProvider);
    await store.upsertPosts([
      PostDto(
        postId: 40,
        channelId: 5,
        creatorId: 3,
        message: '进来时就有的',
        createAt: _at(0, 9),
      ),
    ]);

    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);
    // 进来那一刻还没有"未读"，不该有水位线
    expect(find.text('以下为新消息'), findsNothing);

    // 模拟进来之后别人才发了一条（postId 比水位线大 = 未读）
    await store.upsertPosts([
      PostDto(
        postId: 41,
        channelId: 5,
        creatorId: 3,
        message: '进来之后才发的',
        createAt: _at(4, 10),
      ),
    ]);
    await _settle(tester);

    expect(find.text('以下为新消息'), findsOneWidget);
    expect(find.text('进来之后才发的'), findsOneWidget);
  });

  testWidgets('滚上去出现「回到最新」球，点了回到列表底部', (tester) async {
    final h = await bootChat();
    final store = h.container.read(chatStoreProvider);
    await store.upsertPosts([
      for (var i = 0; i < 40; i++)
        PostDto(
          postId: 100 + i,
          channelId: 5,
          creatorId: 3,
          message: '消息 $i ${'很长很长' * 6}',
          createAt: _at(4, 9) + i * 60000,
        ),
    ]);

    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);

    // 一开始在最底部（reverse 列表 offset 0）→ 没有球
    expect(find.byTooltip('回到最新'), findsNothing);

    // 往回滚（手指往下拖 = 看更旧的消息）
    await tester.drag(find.byType(ListView), const Offset(0, 900));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byTooltip('回到最新'), findsOneWidget);

    await tester.tap(find.byTooltip('回到最新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final sc = tester.widget<ListView>(find.byType(ListView));
    expect(sc.controller!.offset, lessThan(8), reason: '回到最新一条');
  });

  testWidgets('输入框空是麦克风、有文字变发送（形态切换球）', (tester) async {
    final h = await bootChat();
    final store = h.container.read(chatStoreProvider);
    await store.upsertPosts([
      PostDto(
        postId: 50,
        channelId: 5,
        creatorId: 14,
        message: '嗯',
        createAt: _at(0, 9),
      ),
    ]);
    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);

    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);

    await tester.enterText(find.byType(TextField), '要发的字');
    // 形态切换是 AnimatedSwitcher（快），等它放完旧的麦克风才会消失
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.mic_none), findsNothing);
  });

  testWidgets('「+」打开切角宫格面板（7 个入口一个不少）', (tester) async {
    final h = await bootChat();
    await tester.pumpWidget(_app(h.container, 5));
    await _settle(tester);

    await tester.tap(find.byTooltip('发送图片 / 文件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('添加到会话'), findsOneWidget);
    // 后两项是 P0-1：官方 composer 的 `video`（input_section.xml:104）与
    // `record`（:112）——相册选视频 / 现场录视频
    for (final label in const [
      '相册图片',
      '拍照',
      '相册视频',
      '录制视频',
      '文件',
      '投票',
      // ★ DA190：这块以前用页面标题「定时消息」（en "Scheduled messages"）当标签，
      //   72dp 瓦片里被截成 "Scheduled ..."，现改为专用短标签「定时」。
      '定时',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });
}
