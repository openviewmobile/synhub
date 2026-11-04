// 冒烟回归：**本地频道缓存不清理**（`docs/stale-channels-finding.md`）。
//
// 真机现象：侧栏出现 `hidden:Synology Office:1028…` 这种**服务端早已不再返回**
// 的频道，未读数也是本地陈旧值。根因是 `ChatStore.upsertChannels` 只
// `insertOnConflictUpdate`、从不删行，而 `watchChannels()` 又无任何过滤。
//
// 修法（已取证，见 `chat_store.dart` / `chat_session_controller.dart` 的注释）：
// 逐行对位官方 `DatabaseHelper.setChannels(channels, true)`
// （APK `data/local/DatabaseHelper.java:703-739`：本地行不在本次全量列表里就
// `delete("ChatChannel", "channel_id = ? ")`）。
//
// 本文件测的是**页面层**（store 层见 `test/chat_store_test.dart` 的
// `upsertChannels(removeMissing:)` 分组）：
//   ① 服务端不再返回的频道，同步后侧栏**不再显示**；
//   ② 有「发送失败」消息的频道**仍然可见**，且清理时不被删（重发入口不能丢）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: ChannelListPage()),
);

const _kept = {
  'channel_id': 5,
  'name': '还在的频道',
  'type': 'public',
  'is_joined': true,
  'unread': 1,
  'last_post_at': 1000,
};

/// 会被服务端"丢掉"的那个频道（被删 / 归档 / 不再可见）。
/// [hidden] = true 时还带 `last_hide_at`，用来验证"失败消息例外"这条渲染规则。
Map<String, dynamic> _stale({bool hidden = false}) => {
  'channel_id': 6,
  'name': '陈旧频道',
  'type': 'public',
  'is_joined': true,
  'unread': 3,
  'last_post_at': 500,
  if (hidden) 'last_hide_at': 1700000000000,
};

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('服务端不再返回的频道：同步后从侧栏消失（冒烟回归）', (tester) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Channel.list': {
          'channels': [_kept, _stale()],
        },
      },
    );
    await tester.pumpWidget(_app(h.container));
    await _settle(tester);
    expect(find.text('陈旧频道'), findsOneWidget, reason: '首次同步时它还在服务端列表里');

    // 服务端这次不再返回频道 6
    h.transport.responses['SYNO.Chat.Channel.list'] = {
      'channels': [_kept],
    };
    await h.ctrl.refresh();
    await _settle(tester);

    expect(find.text('陈旧频道'), findsNothing, reason: '本地那行必须跟着服务端清掉，否则就还是陈旧缓存');
    expect(find.text('还在的频道'), findsOneWidget, reason: '仍在列表里的不能误删');

    final ids = (await h.container.read(chatStoreProvider).allChannels())
        .map((c) => c.channelId)
        .toList();
    expect(ids, isNot(contains(6)), reason: '库里也真的没有了，不只是渲染藏起来');
  });

  testWidgets('有失败消息的频道：清理不删它，且仍然可见（重发入口不能丢）', (tester) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Channel.list': {
          'channels': [_kept, _stale(hidden: true)],
        },
      },
    );
    await tester.pumpWidget(_app(h.container));
    await _settle(tester);
    // 隐藏过 + 没有失败消息 → 侧栏不显示（这句同时证明"下面变成可见"是
    // 失败消息这条例外带来的，不是本来就在）
    expect(find.text('陈旧频道'), findsNothing);

    // 频道 6 里落一条"发送失败"的消息（state = 2）
    final store = h.container.read(chatStoreProvider);
    final tmp = await store.insertPendingPost(
      channelId: 6,
      creatorId: 14,
      message: '这条没发出去',
      nowMillis: 1000,
    );
    await store.failPendingPost(6, tmp);
    await _settle(tester);
    expect(find.text('陈旧频道'), findsOneWidget, reason: '有失败消息的频道必须能看见');

    // 服务端这次不再返回频道 6 → 清理必须放过它
    h.transport.responses['SYNO.Chat.Channel.list'] = {
      'channels': [_kept],
    };
    await h.ctrl.refresh();
    await _settle(tester);

    expect(find.text('陈旧频道'), findsOneWidget, reason: '有失败消息 → 清理时也留着');
    expect(
      (await store.allChannels()).map((c) => c.channelId),
      contains(6),
      reason: '行和它的失败消息都不能被清掉',
    );
    expect(await store.postsForChannel(6), hasLength(1));
  });

  // 本批**引入过**的真实回归：`initiateChatbot` 是"先写本地、再 `refresh()`"
  // （`chat_session_controller.dart:1795-1796`），而 `refresh()` 会按服务端全量
  // 列表剪枝。服务端列表里没有这个刚建好的频道（滞后/最终一致）⇒
  // 走普通 upsert 会被自己的剪枝删掉，用户看到"建完就消失"。
  testWidgets('本地新建的频道（initiateChatbot）紧接 refresh：不能被自己的剪枝删掉', (tester) async {
    final h = await bootChat(
      extra: {
        // 服务端 `Channel/list` 只有频道 5，**没有** 77
        'SYNO.Chat.Channel.Chatbot.initiate': {
          'channel_id': 77,
          'name': '',
          'type': 'direct',
          'encrypted': false,
        },
      },
    );
    final store = h.container.read(chatStoreProvider);

    final id = await h.ctrl.initiateChatbot(11);
    expect(id, 77, reason: '`Channel.Chatbot / initiate` 回了 channel_id');
    expect(
      (await store.allChannels()).map((c) => c.channelId),
      contains(77),
      reason: '落库后不能被紧接着的那次 refresh 剪掉',
    );

    // 服务端列表始终没收录它 → 再同步几轮也必须还在
    await h.ctrl.refresh();
    await h.ctrl.refresh();
    expect(
      (await store.allChannels()).map((c) => c.channelId),
      contains(77),
      reason: '"本地新建、服务端没确认"的行，清理一律放过',
    );
  });
}
