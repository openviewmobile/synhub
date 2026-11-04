// `DA294`（续）：**侧栏行高必须恒定** —— 未读角标出现/清空不许改变行高。
//
// 用户报：「chat 的页面 channel 下面的连接状态变化太频繁，会导致页面跳动」。
// 第一轮只修了标题下的相位行（定高 + 稳定窗口），用户复测「还是会抖动」。
// 真实原因在**行内**：右侧那列是 `if (hasUnread) ... CountBadge(...)` ——
// 角标参与布局，未读一出现这行就长高 4dp、清空又缩回；同步期间未读数每秒都在变
// ⇒ 侧栏整列上下跳（列表里每一行都在抖，比标题那一行明显得多）。
//
// 判据（本文件）：同一频道 `unread: 0` vs `unread: 5`（以及 mention）**行高完全相同**，
// 且整列首行的 y 坐标不变。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/core/ui/hud_widgets.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/features/chat/channel_row.dart';

ChannelDto _channel({int unread = 0, int mention = 0}) => ChannelDto.fromJson({
  'channel_id': 7,
  'name': '运维值班',
  'type': 'public',
  'is_joined': true,
  'unread': unread,
  'mention': mention,
  'last_post_at': 1700000000000,
  'total_member_count': 12,
});

Widget _host(ChannelDto c) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(body: ChannelRow(channel: c, users: const <int, UserDto>{}, myUserId: 1, onTap: _noop)),
);

void _noop() {}

void main() {
  Future<double> heightOf(WidgetTester tester, ChannelDto c) async {
    await tester.pumpWidget(_host(c));
    await tester.pump();
    return tester.getSize(find.byType(ChannelRow)).height;
  }

  testWidgets('未读从 0 → 5 → 0：行高必须一像素不变', (tester) async {
    final a = await heightOf(tester, _channel(unread: 0));
    final b = await heightOf(tester, _channel(unread: 5));
    final c = await heightOf(tester, _channel(unread: 0));
    expect(b, a, reason: '未读角标出现让行变高了 ⇒ 侧栏会上下跳');
    expect(c, a, reason: '未读清空让行缩回 ⇒ 同样会跳');
  });

  testWidgets('@ 提及角标（不同尺寸）也不改行高', (tester) async {
    final a = await heightOf(tester, _channel(unread: 0));
    final m = await heightOf(tester, _channel(unread: 3, mention: 2));
    expect(m, a, reason: 'mention 角标换尺寸不许改变行高');
  });

  testWidgets('整列：首行 y 坐标在未读变化时不动', (tester) async {
    List<ChannelDto> rows({required bool unread}) => [
      for (var i = 0; i < 6; i++)
        ChannelDto.fromJson({
          'channel_id': 100 + i,
          'name': '频道 $i',
          'type': 'public',
          'is_joined': true,
          'unread': unread && i.isEven ? 3 : 0,
          'last_post_at': 1700000000000 - i * 1000,
        }),
    ];

    Widget list(List<ChannelDto> cs) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: ListView(
          children: [
            for (final c in cs)
              ChannelRow(channel: c, users: const <int, UserDto>{}, myUserId: 1, onTap: _noop),
          ],
        ),
      ),
    );

    await tester.pumpWidget(list(rows(unread: false)));
    await tester.pump();
    final y0 = tester.getTopLeft(find.byType(ChannelRow).at(3)).dy;

    await tester.pumpWidget(list(rows(unread: true)));
    await tester.pump();
    final y1 = tester.getTopLeft(find.byType(ChannelRow).at(3)).dy;

    expect(y1, y0, reason: '未读角标出现把后面的行推下去了 ⇒ 用户看到的"页面跳动"');
  });

  testWidgets('反向验证：真的没角标时不占可见空间（不画出来）', (tester) async {
    await tester.pumpWidget(_host(_channel(unread: 0)));
    await tester.pump();
    // 占位是为了定高；但不可见 —— 用 hitTest 之外的方式：Opacity 为 0
    expect(find.byType(CountBadge), findsOneWidget);
    final vis = tester.widget<Visibility>(find.byType(Visibility).first);
    expect(vis.visible, isFalse);
    expect(vis.maintainSize, isTrue, reason: '不 maintainSize 就等于没占位');
  });
}
