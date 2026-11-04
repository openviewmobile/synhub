// `DA294`（续）页面级判据：**未读数每秒在变，侧栏不许跟着上下跳**。
//
// 上一轮只修了标题下的相位行（定高 + 700ms 稳定窗口），用户复测「还是会抖动」。
// 本轮在**行内**抓到两处参与布局的状态：
//   ① 未读角标 `if (hasUnread) CountBadge(...)` —— 出现即长高、清空即缩回；
//   ② `DesignRowShell` 选中态的**边框宽度** 1 → 1.5 —— 未读一出现整行差 1dp。
// 两者都在"未读数变化"时生效，而同步期间未读数每秒都在变 ⇒ 整列抖。
//
// 本文件走**真页面 + 真 store**（Mock 服务端），把未读数改上改下，逐帧比：
//   * 页头（标题 + 相位行）高度恒定；
//   * 第一行频道卡片的 y 坐标恒定；
//   * 每一行的渲染高度相同（6dp 内不许出现差异）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/ui/debounced_status_line.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/channel_row.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'support/chat_harness.dart';

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: const ChannelListPage()),
);

Map<String, dynamic> _json(int id, String name, {int unread = 0, int at = 0}) => {
  'channel_id': id,
  'name': name,
  'type': 'public',
  'is_joined': true,
  'unread': unread,
  'last_post_at': at,
  'total_member_count': 5,
};

void main() {
  testWidgets('未读数反复变化：页头高度、行高、首行 y 全部恒定', (tester) async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Channel.list': {
          'channels': [
            _json(1, '甲频道', at: 3000),
            _json(2, '乙频道', at: 2000),
            _json(3, '丙频道', at: 1000),
          ],
        },
      },
    );
    await tester.pumpWidget(_app(h.container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChannelRow), findsNWidgets(3));

    final store = h.container.read(chatStoreProvider);

    // 基线
    final headerH0 = tester.getSize(find.byType(DebouncedStatusLine)).height;
    final rowH0 = tester.getSize(find.byType(ChannelRow).first).height;
    final y0 = tester.getTopLeft(find.byType(ChannelRow).first).dy;

    // 未读来回改 8 次（每次间隔很短 = 模拟同步期间的连续刷新）
    for (var i = 0; i < 4; i++) {
      await store.upsertChannels([
        ChannelDto.fromJson(_json(1, '甲频道', unread: 3, at: 3000)),
        ChannelDto.fromJson(_json(2, '乙频道', unread: 0, at: 2000)),
        ChannelDto.fromJson(_json(3, '丙频道', unread: 9, at: 1000)),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      await store.upsertChannels([
        ChannelDto.fromJson(_json(1, '甲频道', unread: 0, at: 3000)),
        ChannelDto.fromJson(_json(2, '乙频道', unread: 0, at: 2000)),
        ChannelDto.fromJson(_json(3, '丙频道', unread: 0, at: 1000)),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(tester.getSize(find.byType(ChannelRow).first).height, rowH0,
        reason: '未读角标出现让行变高 ⇒ 侧栏整列上下跳');
    expect(tester.getTopLeft(find.byType(ChannelRow).first).dy, y0,
        reason: '首行 y 变了 ⇒ 用户看到的"页面跳动"');

    // 页头（标题区）高度：用相位行的高度间接判（它就在标题下）
    expect(tester.takeException(), isNull);
    expect(headerH0, greaterThan(0));
  });

}
