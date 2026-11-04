// Phase 9：频道管理（收藏 / 退出 / 归档 / 关闭）—— 规则 + 请求 + 本地落库。
//
// 权威依据：NAS 实装 `Chat-x86_64-2.4.7-22203.spk` 的 `webapi/SYNO.Chat.lib`
// （`SYNO.Chat.Channel` maxVersion=5，方法分散在互不包含的版本里）＋
// 原版 2.11.1 的 `AccountManager.archiveChannel/closeChannel/starChannel/disjoin`
// 与 `ChannelSettingFragment` / `ChannelManageFragment` 的可见性规则。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/settings/acl.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/features/chat/channel_manage_rules.dart';
import 'package:synhub/src/features/chat/channel_manage_sheet.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

ChannelDto _channel({
  int id = 7,
  String type = 'private',
  String name = 'flt-manage',
}) => ChannelDto.fromJson({
  'channel_id': id,
  'name': name,
  'type': type,
  'is_joined': true,
});

ChannelManageRules _rules(
  ChannelDto channel, {
  bool isGuest = false,
  bool archiveAcl = true,
  bool disjoinAcl = true,
  bool canArchiveApi = true,
  bool canPromoteApi = true,
  int postCount = 3,
}) => channelManageRules(
  channel: channel,
  isGuest: isGuest,
  hasPrivilege: (acl) => switch (acl) {
    kAclChannelArchive => archiveAcl,
    kAclChannelDisjoin => disjoinAcl,
    _ => true,
  },
  canArchiveApi: canArchiveApi,
  canPromoteApi: canPromoteApi,
  postCount: postCount,
);

void main() {
  group('频道管理可见性（照抄 ChannelSettingFragment / ChannelManageFragment）', () {
    test('私有频道非访客：退出 + 归档 + 关闭 都给', () {
      final r = _rules(_channel());
      expect(r.showLeave, isTrue);
      expect(r.showArchive, isTrue);
      expect(r.showClose, isTrue);
      expect(r.closeLabel, '关闭频道');
    });

    test('归档要求：API v2 + 有消息 + ACL_CHANNEL_ARCHIVE', () {
      expect(_rules(_channel(), canArchiveApi: false).showArchive, isFalse);
      expect(_rules(_channel(), postCount: 0).showArchive, isFalse);
      expect(_rules(_channel(), archiveAcl: false).showArchive, isFalse);
      expect(_rules(_channel(), isGuest: true).showArchive, isFalse);
    });

    test('退出要求 ACL_CHANNEL_DISJOIN；访客连close都没有', () {
      expect(_rules(_channel(), disjoinAcl: false).showLeave, isFalse);
      expect(_rules(_channel(), isGuest: true).showLeave, isFalse);
      expect(_rules(_channel(), isGuest: true).showClose, isFalse);
    });

    test('匿名会话：关闭 + 「将会话转换为专用频道」（门控 API v2）', () {
      final anon = _channel(type: 'anonymous', name: '');
      final r = _rules(anon);
      expect(r.showClose, isTrue);
      expect(r.closeLabel, '关闭会话');
      expect(r.showPromote, isTrue);
      expect(r.hasAny, isTrue);
      // promote 只存在于 v2 → 服务器不支持就不出这一项
      expect(_rules(anon, canPromoteApi: false).showPromote, isFalse);
      // 访客不给
      expect(_rules(anon, isGuest: true).showPromote, isFalse);
      // 非匿名频道不给
      expect(_rules(_channel()).showPromote, isFalse);
      expect(_rules(_channel(type: 'public', id: 16)).showPromote, isFalse);
    });

    test('匿名会话：只能关闭，标题是「关闭会话」', () {
      final r = _rules(_channel(type: 'anonymous'));
      expect(r.showClose, isTrue);
      expect(r.closeLabel, '关闭会话');
      expect(r.showArchive, isFalse);
      expect(r.showLeave, isFalse);
    });

    test('公开频道：不给归档/关闭；#1 不给退出，#23 给退出', () {
      final c23 = _rules(_channel(id: 23, type: 'public'));
      expect(c23.showArchive, isFalse);
      expect(c23.showClose, isFalse);
      expect(c23.showLeave, isTrue);

      final c1 = _rules(_channel(id: 1, type: 'public'));
      expect(c1.showLeave, isFalse);
    });

    test('机器人会话（chatbot/synobot）什么都不给', () {
      for (final type in ['chatbot', 'synobot']) {
        final r = _rules(_channel(type: type));
        expect(r.showLeave, isFalse, reason: type);
        expect(r.showArchive, isFalse, reason: type);
        expect(r.showClose, isFalse, reason: type);
      }
    });
  });

  group('API 请求形状（对齐原版写死的版本）', () {
    test('star/unstar 用 v1，只带 channel_id', () async {
      final h = await bootChat();
      await h.ctrl.setChannelStar(5, star: true);
      // 登录后的同步/免打扰刷新是异步的，可能还有别的调用排在后面 → 按方法找
      final call = h.transport.calls.lastWhere((c) => c['method'] == 'star');
      expect(call['api'], 'SYNO.Chat.Channel');
      expect(call['method'], 'star');
      expect(call['version'], '1');
      expect(call['channel_id'], 5);
    });

    test('unstar 同理，且本地 is_star 立刻变', () async {
      final h = await bootChat();
      await h.ctrl.setChannelStar(5, star: false);
      expect(
        h.transport.calls.lastWhere((c) => c['method'] == 'unstar')['api'],
        'SYNO.Chat.Channel',
      );
      final store = h.container.read(chatStoreProvider);
      final row = (await store.allChannels()).firstWhere(
        (c) => c.channelId == 5,
      );
      expect(row.isStar, isFalse);
    });

    test('archive 用 v2（原版写死 2），不是协商出来的 5', () async {
      final h = await bootChat();
      await h.ctrl.archiveChannel(5);
      // 归档之后还会回查一次 `Channel/get`，所以按 method 找那次 archive
      final call = h.transport.calls.firstWhere(
        (c) => c['method'] == 'archive',
      );
      expect(call['method'], 'archive');
      expect(call['version'], '2');
      expect(call['channel_id'], 5);
      // 归档后本地 is_joined=false
      final store = h.container.read(chatStoreProvider);
      final row = (await store.allChannels()).firstWhere(
        (c) => c.channelId == 5,
      );
      expect(row.isJoined, isFalse);
    });

    test('close 用 v2 且必须带 conn_id', () async {
      final h = await bootChat();
      await h.ctrl.closeChannel(5);
      final call = h.transport.calls.lastWhere((c) => c['method'] == 'close');
      expect(call['method'], 'close');
      expect(call['version'], '2');
      expect(call['channel_id'], 5);
      expect(call['conn_id'], isNotNull);
      // 关闭后本地频道行 + 消息都没了
      final store = h.container.read(chatStoreProvider);
      expect((await store.allChannels()).any((c) => c.channelId == 5), isFalse);
    });

    test('服务器 maxVersion=1 时 archive/close 直接抛版本不支持', () async {
      final h = await bootChat(
        apiTable: {
          ...FakeTransport.table,
          'SYNO.Chat.Channel': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      expect(h.ctrl.supportsChannelV2, isFalse);
      await expectLater(h.ctrl.archiveChannel(5), throwsA(isA<Exception>()));
    });

    test('leave 走 Channel.Named/disjoin v1', () async {
      final h = await bootChat();
      await h.ctrl.leaveChannel(5);
      final call = h.transport.calls.lastWhere((c) => c['method'] == 'disjoin');
      expect(call['api'], 'SYNO.Chat.Channel.Named');
      expect(call['method'], 'disjoin');
      expect(call['version'], '1');
    });
  });

  group('底部弹窗渲染', () {
    testWidgets('私有频道：显示 收藏 / 退出 / 归档 / 关闭', (tester) async {
      final h = await bootChat();
      // 归档要求"频道里有消息"（原版用列表 itemCount），先塞一条本地消息
      await h.container.read(chatStoreProvider).upsertPosts(const [
        PostDto(postId: 1, channelId: 7, creatorId: 14, message: 'seed'),
      ]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Builder(
              builder: (context) => Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => Center(
                    child: ElevatedButton(
                      onPressed: () => showChannelManageSheet(
                        context,
                        ref,
                        _channel(type: 'private'),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('频道管理 · flt-manage'), findsOneWidget);
      expect(find.text('收藏频道'), findsOneWidget);
      expect(find.text('退出频道'), findsOneWidget);
      expect(find.text('归档频道'), findsOneWidget);
      expect(find.text('关闭频道'), findsOneWidget);
    });

    testWidgets('公开频道 #1：没有 退出/归档/关闭', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Builder(
              builder: (context) => Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => Center(
                    child: ElevatedButton(
                      onPressed: () => showChannelManageSheet(
                        context,
                        ref,
                        _channel(id: 1, type: 'public'),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('收藏频道'), findsOneWidget);
      expect(find.text('退出频道'), findsNothing);
      expect(find.text('归档频道'), findsNothing);
      expect(find.text('关闭频道'), findsNothing);
    });
  });

  group('将会话转换为专用频道（Channel.Anonymous / promote v2）', () {
    test('请求形状：v2 + channel_id + name/purpose 各 Gson 二次编码', () async {
      final h = await bootChat(
        extra: {
          // 真机实测：promote 成功只回 `{}`（BasicVo，没有 channel 对象）
          'SYNO.Chat.Channel.Anonymous.promote': {},
          // 所以升级后的类型/名字靠 `refresh()` 回拉
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                'channel_id': 7,
                'name': '项目讨论',
                'purpose': '从会话转过来',
                'type': 'private',
                'is_joined': true,
              },
            ],
          },
        },
      );
      await h.ctrl.promoteChannel(7, name: '项目讨论', purpose: '从会话转过来');
      final call = h.transport.calls.firstWhere(
        (c) => c['method'] == 'promote',
      );
      expect(call['api'], 'SYNO.Chat.Channel.Anonymous');
      expect(call['method'], 'promote');
      expect(call['version'], '2', reason: 'promote 只在 v2，别拿协商出来的别的版本');
      expect(call['channel_id'], '7');
      expect(call['name'], '"项目讨论"', reason: 'Gson 二次编码');
      expect(call['purpose'], '"从会话转过来"');

      // 本地类型/名字要跟着变（原来是 anonymous）
      final store = h.container.read(chatStoreProvider);
      final row = (await store.allChannels()).firstWhere(
        (c) => c.channelId == 7,
      );
      expect(row.type, 'private');
      expect(row.name, '项目讨论');
    });

    test('服务器没有 v2 → supportsPromoteAnonymous=false，调用直接抛错', () async {
      final h = await bootChat(
        apiTable: {
          ...FakeTransport.table,
          'SYNO.Chat.Channel.Anonymous': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      expect(h.ctrl.supportsPromoteAnonymous, isFalse);
      await expectLater(
        h.ctrl.promoteChannel(7, name: 'x', purpose: ''),
        throwsA(isA<StateError>()),
      );
    });

    testWidgets('匿名会话：弹窗里有入口，填名称确认后发出 promote', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Anonymous.promote': {},
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                'channel_id': 7,
                'name': '新频道',
                'type': 'private',
                'is_joined': true,
              },
            ],
          },
        },
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Builder(
              builder: (context) => Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => Center(
                    child: ElevatedButton(
                      onPressed: () => showChannelManageSheet(
                        context,
                        ref,
                        _channel(type: 'anonymous', name: ''),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('将会话转换为专用频道'), findsOneWidget);
      expect(find.text('关闭会话'), findsOneWidget);

      await tester.tap(find.text('将会话转换为专用频道'));
      await tester.pumpAndSettle();
      expect(find.text('频道名称'), findsOneWidget);
      expect(find.text('描述（可选）'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '新频道');
      // 校验是 onChanged → setState 驱动的，得先让界面重建才能点亮「转换」
      await tester.pumpAndSettle();
      await tester.tap(find.text('转换'));
      await tester.pumpAndSettle();
      final call = h.transport.calls.firstWhere(
        (c) => c['method'] == 'promote',
      );
      expect(call['channel_id'], '7');
      expect(call['name'], '"新频道"');
    });

    testWidgets('名字带空格或特殊字符 → 「转换」置灰（原版 afterInputChanged）', (tester) async {
      final h = await bootChat(
        extra: {'SYNO.Chat.Channel.Anonymous.promote': {}},
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Builder(
              builder: (context) => Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => Center(
                    child: ElevatedButton(
                      onPressed: () => showChannelManageSheet(
                        context,
                        ref,
                        _channel(type: 'anonymous', name: ''),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('将会话转换为专用频道'));
      await tester.pumpAndSettle();

      // 真机实测服务端对带空格的名字回 407，所以客户端先拦
      await tester.enterText(find.byType(TextField).first, '验收 频道');
      await tester.pumpAndSettle();
      expect(find.text('不可用空格和特殊字符。'), findsOneWidget);
      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '转换'),
      );
      expect(btn.onPressed, isNull, reason: '非法名字不该能点');

      await tester.enterText(find.byType(TextField).first, 'a@b');
      await tester.pumpAndSettle();
      expect(find.text('不可用空格和特殊字符。'), findsOneWidget);
    });
  });

  group(
    'client.channel.disjoin 的 is_close 分支（原版 DatabaseHelper.closeChannel）',
    () {
      test('is_close=true → 本地整条删掉', () async {
        final h = await bootChat();
        await h.ctrl.handleEvent(
          const ChatSocketEvent('client.channel.disjoin', {
            'channel_id': 5,
            'is_close': true,
          }),
        );
        final store = h.container.read(chatStoreProvider);
        expect(
          (await store.allChannels()).any((c) => c.channelId == 5),
          isFalse,
        );
      });

      test('is_close=false → 只置 is_joined=false（行还在）', () async {
        final h = await bootChat();
        await h.ctrl.handleEvent(
          const ChatSocketEvent('client.channel.disjoin', {
            'channel_id': 5,
            'is_close': false,
          }),
        );
        final store = h.container.read(chatStoreProvider);
        final row = (await store.allChannels()).firstWhere(
          (c) => c.channelId == 5,
        );
        expect(row.isJoined, isFalse);
      });
    },
  );
}
