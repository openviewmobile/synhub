// P0 #4：跨频道内容面板（话题 / 书签 / 提醒 / 定时）。
//
// ⚠️ 证据更正（详见 docs/chat-p0b-implementation.md §3）：官方
// `TabBookmarkFragment` 的 `newInstance(channelId, index)` **必须带 channelId**，
// 是**单频道**四 tab 面板，不是跨频道聚合；审计 §2.6 的"首页全局入口"与原文不符。
// 本页是自加编排，但每个 tab 的取数都有原文：
//   * 话题：`Post/search` + `has:["subscribe"]` 且**不带 `in`**（官方后备路径
//     `CommentsPresenter.fetchAllSubscribedPosts` 的 onErrorReturn 用的就是
//     `has:["subscribe"]`；服务端 `SearchControl::HandleSubscribe`）。
//   * 书签：`Post/search` + `has:["star"]` 不带 `in`（`BookmarkPresenter.getHas`，
//     服务端 `SearchControl::HasStar`）。
//   * 提醒 / 定时：`Reminder/list` / `Schedule/list` 的 `channel_id` **必填**
//     （`WebApiService.listReminder/listSchedule` 签名 + `user_reminders` /
//     `schedule_posts` 的 `channel_id` NOT NULL），服务端没有跨频道方法 →
//     本机对已加入频道逐个拉再合并。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/global_content_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Map<String, dynamic> postJson(
  int id, {
  int channelId = 5,
  int threadId = 0,
  String message = '',
  bool star = false,
}) => {
  'post_id': id,
  'channel_id': channelId,
  'creator_id': 14,
  'thread_id': threadId,
  'create_at': 1700000000000,
  'type': 'normal',
  'message': message,
  'props': {'is_star': star},
};

Map<String, dynamic> searchResponse(List<Map<String, dynamic>> posts) => {
  'search_results': posts,
  'total': posts.length,
  'offset': 0,
  'limit': 50,
};

/// 两个频道（#5 测试频道 / #6 第二个频道），都 joined。
Future<ChatHarness> bootTwoChannels() => bootChat(
  extra: {
    'SYNO.Chat.Channel.list': {
      'channels': [
        testChannelJson,
        {
          'channel_id': 6,
          'name': '第二个频道',
          'type': 'public',
          'is_joined': true,
          'unread': 0,
          'last_post_at': 900,
        },
      ],
    },
  },
);

void main() {
  // 第 55 轮：`synhub/background` 等 Android-only 桥改成"先问能力层"。
  // 能力层看的是**真宿主**（`flutter test` 里 = macos），而旧的
  // `defaultTargetPlatform` 被测试绑定固定成 android ⇒ 本文件历史上是在
  // "原生桥可用"的前提下写的（提醒会走系统级路径）。这里显式把门控强制打开，
  // 恢复该前提；断言一条没改。生产语义不受影响（Android 真机能力层同样放行）。
  setUp(() => debugForceCapabilityGate = true);
  tearDown(() => debugForceCapabilityGate = false);

  group('跨频道话题 tab', () {
    test('Post/search has:["subscribe"] 且不带 in，只留父贴', () async {
      final h = await bootTwoChannels();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(100, channelId: 5, message: '频道 5 的话题'),
        postJson(200, channelId: 6, message: '频道 6 的话题'),
        postJson(101, channelId: 5, threadId: 100, message: '一条回复'),
      ]);
      final list = await h.container.read(globalThreadsProvider.future);
      expect(list.map((p) => p.postId), [100, 200]);
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      expect(call['has'], '["subscribe"]');
      expect(call['in'], isNull, reason: '跨频道不能带 in');
    });
  });

  group('跨频道书签 tab', () {
    test('Post/search has:["star"] 且不带 in，含所有频道', () async {
      final h = await bootTwoChannels();
      h.transport.responses['SYNO.Chat.Post.search'] = searchResponse([
        postJson(11, channelId: 5, message: '星标甲', star: true),
        postJson(12, channelId: 6, message: '星标乙', star: true),
      ]);
      final list = await h.container.read(globalBookmarksProvider.future);
      expect(list.map((p) => p.channelId), [5, 6]);
      final call = h.transport.calls.singleWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.search',
      );
      expect(call['has'], '["star"]');
      expect(call['in'], isNull, reason: '跨频道不能带 in');
    });
  });

  group('跨频道提醒 / 定时 tab（逐频道汇总）', () {
    test('Reminder/list 按每个已加入频道各发一次，合并结果', () async {
      final h = await bootTwoChannels();
      h.transport.onCall = (params) {
        if ('${params['api']}.${params['method']}' ==
            'SYNO.Chat.Post.Reminder.list') {
          final cid = int.tryParse('${params['channel_id']}') ?? 0;
          return {
            'posts': [
              {
                'post_id': cid * 10,
                'channel_id': cid,
                'creator_id': 14,
                'create_at': 1700000000000,
                'type': 'normal',
                'message': '提醒@$cid',
                'props': {'remind_at': 1700000000000 + cid},
              },
            ],
          };
        }
        return null;
      };
      final list = await h.container.read(globalRemindersProvider.future);
      expect(list.map((p) => p.channelId).toSet(), {5, 6});
      final calls = h.transport.calls
          .where(
            (c) =>
                '${c['api']}.${c['method']}' == 'SYNO.Chat.Post.Reminder.list',
          )
          .toList();
      expect(calls.map((c) => c['channel_id']).toSet(), {'5', '6'});
    });

    test('Schedule/list 同样逐频道，合并结果', () async {
      final h = await bootTwoChannels();
      h.transport.onCall = (params) {
        if ('${params['api']}.${params['method']}' ==
            'SYNO.Chat.Post.Schedule.list') {
          final cid = int.tryParse('${params['channel_id']}') ?? 0;
          return {
            'schedule_posts': [
              {
                'cronjob_id': cid * 100,
                'channel_id': cid,
                'message': '定时@$cid',
                'send_at': 1800000000000 + cid,
              },
            ],
          };
        }
        return null;
      };
      final list = await h.container.read(globalScheduledProvider.future);
      expect(list.map((s) => s.channelId).toSet(), {5, 6});
    });

    test('接口整体报错 → 逐频道 try/catch 吞掉，不整页抛错', () async {
      final h = await bootTwoChannels();
      h.transport.failures['SYNO.Chat.Post.Reminder.list'] = 117;
      final list = await h.container.read(globalRemindersProvider.future);
      expect(list, isEmpty);
    });
  });

  group('页面与入口', () {
    Future<void> pump(
      WidgetTester tester,
      ProviderContainer c,
      Widget home,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: home),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('四个 tab 都在；提醒 tab 显示各频道名', (tester) async {
      final h = await bootTwoChannels();
      h.transport.onCall = (params) {
        if ('${params['api']}.${params['method']}' ==
            'SYNO.Chat.Post.Reminder.list') {
          final cid = int.tryParse('${params['channel_id']}') ?? 0;
          return {
            'posts': [
              {
                'post_id': cid * 10,
                'channel_id': cid,
                'creator_id': 14,
                'create_at': 1700000000000,
                'type': 'normal',
                'message': '提醒@$cid',
                'props': {'remind_at': 1700000000000 + cid},
              },
            ],
          };
        }
        return null;
      };
      await pump(tester, h.container, const GlobalContentPage());
      expect(find.text('话题'), findsOneWidget);
      expect(find.text('书签'), findsOneWidget);
      expect(find.text('提醒'), findsOneWidget);
      expect(find.text('定时'), findsOneWidget);

      await tester.tap(find.text('提醒'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.textContaining('提醒@5'), findsOneWidget);
      expect(find.textContaining('提醒@6'), findsOneWidget);
      expect(find.textContaining('测试频道'), findsWidgets);
      expect(find.textContaining('第二个频道'), findsWidgets);
      // 第 55 轮：`synhub/background` 走能力层后，**测试宿主**（真 macos）上
      // `background.isSupported == false`（旧写法 `defaultTargetPlatform` 被
      // 测试绑定固定成 android ⇒ 曾恒为 true）⇒ 提醒 tab 会启动
      // `reminderSchedulerProvider`，它按设计排一个**前台 Timer 回落**
      // （真桌面就是这个行为）。本用例的 `ProviderContainer` 是手工建的、
      // 不随 widget 树析构 ⇒ 必须显式 dispose 才会跑到 `ref.onDispose(stop)`
      // 取消 Timer，否则报 "A Timer is still pending"。
    });

    testWidgets('频道列表溢出菜单有「跨频道内容」入口', (tester) async {
      final h = await bootTwoChannels();
      await pump(tester, h.container, const ChannelListPage());
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('跨频道内容'), findsOneWidget);
    });
  });
}
