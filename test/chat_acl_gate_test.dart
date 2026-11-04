// P0-4：5 个频道 ACL 键的接入验证。
//
// 官方门控证据：
//   * `channel_create`            → `NamedChannelFragment.java:155-157`（无权限清空
//                                   `menu_available_channel`，创建入口整个不出现）
//   * `channel_join`+`channel_public` → `NamedChannelFragment.java:165`
//                                   `showPublic(join && public)`
//   * `channel_encryption`        → `NamedCreateFragment.java:300`
//                                   `mPrivateSwitch.setVisibility(GONE)`
//   * `channel_anonymous`         → `DrawerPresenter.java:67`（不挂 `DrawerField(108)`）
// 键名/取值来自真机 `Misc/acl` 回包（`docs/device-verification.md:455-458`）与
// `docs/phase7-protocol.md:354-363` 的 14 条 ACL。
//
// 语义：`acl.dart` 与 `User.hasPrivilege` 一样 **fail-open**（表里没有的 key 允许），
// 所以老服务器不带 ACL 时功能不会被锁死 —— 每个用例都同时验"默认可见"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/acl.dart';
import 'package:synhub/src/features/chat/channel_create_page.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/channel_row.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';
import 'support/switch_rows.dart';

Widget _app(ProviderContainer c, Widget home) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(theme: AppTheme.dark(), home: home),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 两个频道：一个 public（#5）+ 一个 anonymous（#6），用来验匿名门控。
Future<ChatHarness> _bootChannels() => bootChat(
  extra: {
    'SYNO.Chat.Channel.list': {
      'channels': [
        testChannelJson,
        {
          'channel_id': 6,
          'name': '匿名会话',
          'type': 'anonymous',
          'is_joined': true,
          'unread': 0,
          'last_post_at': 900,
        },
      ],
    },
  },
);

Future<void> _setAcl(ChatHarness h, Map<String, bool> acl) =>
    h.container.read(myAclProvider.notifier).apply(acl);

void main() {
  group('channel_create：建频道入口', () {
    testWidgets('无 ACL 数据（fail-open）→ 主行动球与菜单项都在', (tester) async {
      final h = await _bootChannels();
      await tester.pumpWidget(_app(h.container, const ChannelListPage()));
      await _settle(tester);

      expect(find.byTooltip('新建频道'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await _settle(tester);
      expect(find.text('新建频道'), findsOneWidget);
    });

    testWidgets('channel_create=false → 主行动球与菜单项都消失', (tester) async {
      final h = await _bootChannels();
      await _setAcl(h, {kAclChannelCreate: false});
      await tester.pumpWidget(_app(h.container, const ChannelListPage()));
      await _settle(tester);

      expect(find.byTooltip('新建频道'), findsNothing);
      await tester.tap(find.byIcon(Icons.more_vert));
      await _settle(tester);
      expect(find.text('新建频道'), findsNothing);
    });
  });

  group('channel_join + channel_public：加入公开频道', () {
    testWidgets('两个权限都有 → 菜单出现「加入公开频道」', (tester) async {
      final h = await _bootChannels();
      await _setAcl(h, {kAclChannelJoin: true, kAclChannelPublic: true});
      await tester.pumpWidget(_app(h.container, const ChannelListPage()));
      await _settle(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await _settle(tester);
      expect(find.text('加入公开频道'), findsOneWidget);
    });

    testWidgets('只缺 channel_public → 入口隐藏（与官方 && 语义一致）', (tester) async {
      final h = await _bootChannels();
      await _setAcl(h, {kAclChannelJoin: true, kAclChannelPublic: false});
      await tester.pumpWidget(_app(h.container, const ChannelListPage()));
      await _settle(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await _settle(tester);
      expect(find.text('加入公开频道'), findsNothing);
    });

    test('allowsPublicChannels 是 AND 语义，且 fail-open', () {
      bool none(String _) => true;
      expect(allowsPublicChannels(none), isTrue);
      expect(
        allowsPublicChannels((n) => n != kAclChannelPublic),
        isFalse,
        reason: '缺 channel_public 就不该列公开频道',
      );
      expect(allowsPublicChannels((n) => n != kAclChannelJoin), isFalse);
    });
  });

  group('channel_encryption：建频道的加密开关', () {
    Future<void> pumpCreate(WidgetTester tester, ChatHarness h) async {
      await tester.pumpWidget(_app(h.container, const ChannelCreatePage()));
      await tester.pumpAndSettle();
    }

    testWidgets('默认（fail-open）→ 加密开关在', (tester) async {
      final h = await _bootChannels();
      await pumpCreate(tester, h);
      expect(switchRowFinder, findsOneWidget);
    });

    testWidgets('channel_encryption=false → 开关整块隐藏', (tester) async {
      final h = await _bootChannels();
      await _setAcl(h, {kAclChannelEncryption: false});
      await pumpCreate(tester, h);
      expect(switchRowFinder, findsNothing);
    });
  });

  group('channel_anonymous：一对一会话', () {
    testWidgets('默认（fail-open）→ 匿名会话行显示', (tester) async {
      final h = await _bootChannels();
      await tester.pumpWidget(_app(h.container, const ChannelListPage()));
      await _settle(tester);
      expect(find.byType(ChannelRow), findsNWidgets(2));
    });

    testWidgets('channel_anonymous=false → 匿名会话整块隐藏', (tester) async {
      final h = await _bootChannels();
      await _setAcl(h, {kAclChannelAnonymous: false});
      await tester.pumpWidget(_app(h.container, const ChannelListPage()));
      await _settle(tester);
      expect(find.byType(ChannelRow), findsOneWidget);
    });
  });
}
