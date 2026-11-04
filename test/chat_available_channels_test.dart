// 收尾遗留 3：「公开频道」完整浏览页（`AvailableChannelsPage`）。
//
// 审计原文：`docs/chat-p0-implementation.md:134-140,305-306`（P0-4 只补了最小底部
// 弹层；官方 `NamedChannelFragment` 是独立列表页 + 关键字过滤）。
//
// 覆盖：
//   ① 入口：频道列表溢出菜单「加入公开频道」→ 打开**完整页**（不再是弹层）；
//   ② 只列 `type == public && !isJoined`（对齐 `NamedAdapter.updateChannels`）；
//   ③ 名字 + 成员数（对齐官方 `"%s (%d)"` 行文案）；
//   ④ 空态 / 错误态（可重试）；
//   ⑤ 能力位 `channel_join` + `channel_public`（AND，fail-open）；
//   ⑥ 关键字过滤（对齐 `NamedAdapter.keywordChange`）；
//   ⑦ 加入走既有 `Channel.Named / join`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/acl.dart';
import 'package:synhub/src/features/chat/available_channels_page.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Widget _app(ProviderContainer c, Widget home) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: home),
);

/// 混合列表：public 未加入 ×2（一条带 purpose）/ private / 已加入的 public / 匿名。
List<Map<String, dynamic>> _channels() => [
  {
    'channel_id': 7,
    'name': '公开一',
    'type': 'public',
    'is_joined': false,
    'total_member_count': 12,
  },
  {
    'channel_id': 8,
    'name': '公开二',
    'type': 'public',
    'is_joined': false,
    'purpose': '聊技术',
    'total_member_count': 3,
  },
  {'channel_id': 9, 'name': '私有', 'type': 'private', 'is_joined': false},
  {'channel_id': 10, 'name': '已加入', 'type': 'public', 'is_joined': true},
  {'channel_id': 11, 'name': '匿名', 'type': 'anonymous', 'is_joined': false},
];

Future<ChatHarness> _boot({Map<String, dynamic>? list}) => bootChat(
  extra: {
    'SYNO.Chat.Channel.list': list ?? {'channels': _channels()},
    'SYNO.Chat.Channel.Named.join': {'success': true},
  },
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 走真实入口：频道列表溢出菜单 →「加入公开频道」→ 完整页。
Future<void> _openViaMenu(WidgetTester tester, ChatHarness h) async {
  await tester.pumpWidget(_app(h.container, const ChannelListPage()));
  await _settle(tester);
  await tester.tap(find.byIcon(Icons.more_vert));
  await _settle(tester);
  await tester.tap(find.text('加入公开频道'));
  await _settle(tester);
}

void main() {
  testWidgets('入口：溢出菜单「加入公开频道」→ 打开完整页（不再是弹层）', (tester) async {
    final h = await _boot();
    await _openViaMenu(tester, h);
    // 完整页的承重标志：AppBar 标题 + 列表（不是 `showModalBottomSheet`）
    expect(find.text('公开频道'), findsOneWidget);
    expect(find.byKey(const Key('chat-public-list')), findsOneWidget);
  });

  testWidgets('浏览：只列 public 且未加入的，并显示名字 + 成员数', (tester) async {
    final h = await _boot();
    await _openViaMenu(tester, h);
    expect(find.byKey(const Key('chat-public-7')), findsOneWidget);
    expect(find.byKey(const Key('chat-public-8')), findsOneWidget);
    // 非 public / 已加入 / 匿名都不列（对齐 `NamedAdapter` 的过滤）
    expect(find.byKey(const Key('chat-public-9')), findsNothing);
    expect(find.byKey(const Key('chat-public-10')), findsNothing);
    expect(find.byKey(const Key('chat-public-11')), findsNothing);
    // 行文案：没 purpose 只给成员数；有 purpose 则是「purpose · 成员数」
    expect(find.text('12 名成员'), findsOneWidget);
    expect(find.text('聊技术 · 3 名成员'), findsOneWidget);
  });

  testWidgets('空列表 → 空态（不是空白页）', (tester) async {
    final h = await _boot(list: {'channels': const []});
    await _openViaMenu(tester, h);
    expect(find.byKey(const Key('chat-public-empty')), findsOneWidget);
    expect(find.text('没有可以加入的公开频道。'), findsOneWidget);
  });

  testWidgets('加载失败 → 错误态 + 重试（重试后出列表，与空态区分）', (tester) async {
    final h = await _boot();
    h.transport.failures['SYNO.Chat.Channel.list'] = 500;
    // 直接挂页：避免频道列表页后台的 `ctrl.start` 也吃这次失败（那是另一条链路）
    await tester.pumpWidget(_app(h.container, const AvailableChannelsPage()));
    await _settle(tester);
    expect(find.byKey(const Key('chat-public-error')), findsOneWidget);
    expect(find.byKey(const Key('chat-public-empty')), findsNothing);
    expect(find.text('公开频道加载失败'), findsOneWidget);

    h.transport.failures.remove('SYNO.Chat.Channel.list');
    await tester.tap(find.text('重试'));
    await _settle(tester);
    expect(find.byKey(const Key('chat-public-list')), findsOneWidget);
    expect(find.byKey(const Key('chat-public-error')), findsNothing);
  });

  testWidgets('无 channel_public 权限 → 整页不给浏览（AND 门控，兜底）', (tester) async {
    final h = await _boot();
    await h.container.read(myAclProvider.notifier).apply({
      kAclChannelJoin: true,
      kAclChannelPublic: false,
    });
    await tester.pumpWidget(_app(h.container, const AvailableChannelsPage()));
    await _settle(tester);
    expect(find.byKey(const Key('chat-public-no-privilege')), findsOneWidget);
    expect(find.byKey(const Key('chat-public-list')), findsNothing);
  });

  testWidgets('关键字过滤：只留下名字匹配的频道', (tester) async {
    final h = await _boot();
    await _openViaMenu(tester, h);
    await tester.enterText(find.byKey(const Key('chat-public-filter')), '公开二');
    await _settle(tester);
    expect(find.byKey(const Key('chat-public-8')), findsOneWidget);
    expect(find.byKey(const Key('chat-public-7')), findsNothing);
  });

  testWidgets('加入：走既有 Channel.Named / join（点行或点「加入」都行）', (tester) async {
    final h = await _boot();
    await _openViaMenu(tester, h);
    await tester.tap(find.byKey(const Key('chat-public-join-7')));
    await tester.pumpAndSettle();
    final joins = h.transport.calls
        .where(
          (c) => c['api'] == 'SYNO.Chat.Channel.Named' && c['method'] == 'join',
        )
        .toList();
    expect(joins, hasLength(1));
    expect('${joins.single['channel_id']}', '7');
    // 加入成功 → 从完整页退回到列表页（不是停在原页）
    expect(find.byKey(const Key('chat-public-list')), findsNothing);
  });
}
