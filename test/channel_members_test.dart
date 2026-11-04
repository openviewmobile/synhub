// 频道成员页 + 权限表（ACL）+ 邀请/踢人（Phase 7 补齐）。
//
// 对齐原版：
//   * `AccountManager.fetchAcl` → `SYNO.Chat.Misc acl v1` → `{acl_name: allow}`，
//     查不到就允许（`User.hasPrivilege` fail-open）；
//   * `MemberFragment` 的成员列表（名称过滤、⚠ broken、编辑模式批量踢）；
//   * `AccountManager.inviteNamed`（加密频道逐人封密钥）与
//     `kickUsers`（`Entry.Request` parallel compound，每人一段 `Named/kick`）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:synhub/src/core/settings/acl.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/features/chat/channel_members_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

const _memberChannel = {
  'channel_id': 50,
  'name': '项目讨论',
  'type': 'private',
  'is_joined': true,
  'encrypted': true,
  'channel_key_enc': 'SEALED',
  'members': [14, 4, 8],
  'broken_users': [8],
  'creator_id': 14,
  'last_post_at': 1000,
};

// 必须是合法 base64 的 32 字节公钥（真机上就是这种 44 字符）
const _pk4 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _pk8 = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=';

Map<String, dynamic> _users() => {
  'users': [
    {'user_id': 14, 'username': 'me', 'nickname': '我', 'type': 'human'},
    // 公钥在 `user_props.key_pair` 里（对齐 UserVo）
    {
      'user_id': 4,
      'username': 'demo',
      'nickname': 'demo',
      'type': 'human',
      'user_props': {
        'key_pair': {'public_key': _pk4},
      },
    },
    {
      'user_id': 8,
      'username': 'nokey',
      'nickname': '没钥匙',
      'type': 'human',
      'user_props': {
        'key_pair': {'public_key': _pk8},
      },
    },
  ],
};

void main() {
  group('权限表（ACL）', () {
    test('fetchAcl 解析 {acls:[{acl_name,allow}]}', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Misc.acl': {
            'acls': [
              {'acl_name': 'channel_invite', 'allow': true},
              {'acl_name': 'channel_kick', 'allow': false},
            ],
          },
        },
      );
      final acls = await h.apiForTest.fetchAcl();
      expect(acls, {'channel_invite': true, 'channel_kick': false});
    });

    test('登录后自动拉权限表；表里没有的 key 默认允许', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Misc.acl': {
            'acls': [
              {'acl_name': 'channel_kick', 'allow': false},
            ],
          },
        },
      );
      // `_loadAcl` 是 fire-and-forget，等它落地
      for (var i = 0; i < 20; i++) {
        if (h.container.read(myAclProvider).isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final acl = h.container.read(myAclProvider);
      expect(acl['channel_kick'], isFalse);
      expect(
        h.container.read(myAclProvider.notifier).hasPrivilege('channel_kick'),
        isFalse,
      );
      expect(
        h.container.read(myAclProvider.notifier).hasPrivilege('channel_invite'),
        isTrue,
        reason: '表里没有的 key 要 fail-open（原版语义）',
      );
      // 也要落盘，下次离线启动还能按同样权限渲染
      final saved = await h.container.read(settingsServiceProvider).myAclJson();
      expect(saved, contains('channel_kick'));
    });
  });

  group('邀请 / 踢人', () {
    test('普通频道邀请：只发 user_ids，不带 channel_key_encs', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [
              {..._memberChannel, 'encrypted': false, 'channel_key_enc': ''},
            ],
          },
          'SYNO.Chat.User.list': _users(),
          'SYNO.Chat.Channel.Named.invite': const {},
          'SYNO.Chat.Channel.Member.get': {
            'user_ids': [14, 4],
            'broken_user_ids': <int>[],
          },
        },
      );
      final ok = await h.ctrl.inviteMembers(50, [4]);
      expect(ok, isTrue);
      final call = h.transport.calls.lastWhere((c) => c['method'] == 'invite');
      expect(call['channel_id'], 50);
      expect('${call['user_ids']}', contains('4'));
      expect(call['channel_key_encs'], isNull, reason: '非加密频道不带密钥');
      // 邀请后本地成员表跟着服务端走
      final ch = (await h.container.read(chatStoreProvider).allChannels())
          .firstWhere((c) => c.channelId == 50);
      expect(ch.members, [14, 4]);
    });

    test('加密频道邀请：逐人封一份 channel_key_enc（顺序对应）', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_memberChannel],
          },
          'SYNO.Chat.User.list': _users(),
          'SYNO.Chat.Channel.Named.invite': const {},
          'SYNO.Chat.Channel.Member.get': {
            'user_ids': [14, 4],
            'broken_user_ids': <int>[],
          },
        },
      );
      // 造一把频道密钥：跟"本机就是建频道的人"一样
      final svc = h.container.read(e2eeServiceProvider);
      final identity = await svc.setup('pass-123');
      final fresh = svc.newChannelKey([identity.publicKey]);
      svc.putChannelKey(50, fresh.key);
      await h.container.read(chatStoreProvider).upsertChannels([
        ChannelDto.fromJson({
          ..._memberChannel,
          'channel_key_enc': fresh.sealedKeys.single,
        }),
      ]);
      svc.loadChannelKey(50, fresh.sealedKeys.single);

      final ok = await h.ctrl.inviteMembers(50, [4, 8]);
      expect(ok, isTrue);
      final call = h.transport.calls.lastWhere((c) => c['method'] == 'invite');
      final encs = '${call['channel_key_encs']}';
      expect(encs, contains(','), reason: '两个人两份密钥');
      expect('${call['user_ids']}', contains('4'));
      expect('${call['user_ids']}', contains('8'));
    });

    test('加密频道邀请没有公钥的人 → 直接拒绝，不发请求', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_memberChannel],
          },
          'SYNO.Chat.User.list': {
            'users': [
              {'user_id': 9, 'username': 'nopk', 'type': 'human'},
            ],
          },
        },
      );
      // 登录后的异步刷新（服务端设置/免打扰）也会发请求，所以按方法过滤，
      // 不能拿"总请求数没变"当断言
      final ok = await h.ctrl.inviteMembers(50, [9]);
      expect(ok, isFalse);
      expect(
        h.transport.calls.where((c) => c['method'] == 'invite'),
        isEmpty,
        reason: '不该把一个邀请请求发出去',
      );
    });

    test('踢多人：Entry.Request parallel compound，每人一段 Named/kick', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_memberChannel],
          },
          'SYNO.Chat.User.list': _users(),
          'SYNO.Chat.Channel.Member.get': {
            'user_ids': [14],
            'broken_user_ids': <int>[],
          },
        },
      );
      final ok = await h.ctrl.kickMembers(50, [4, 8]);
      expect(ok, isTrue);
      final compound = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Entry.Request',
      );
      final raw = '${compound['compound']}';
      expect(raw, contains('"method":"kick"'));
      expect(raw, contains('"user_id":4'));
      expect(raw, contains('"user_id":8'));
      expect(compound['mode'], 'parallel');
    });

    test('踢人时服务端报错 → 返回 false（不吞错误）', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_memberChannel],
          },
          'SYNO.Chat.User.list': _users(),
        },
      );
      h.transport.failures['SYNO.Entry.Request.request'] = 401;
      final ok = await h.ctrl.kickMembers(50, [4]);
      expect(ok, isFalse);
    });
  });

  group('成员页', () {
    Widget wrap(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: ChannelMembersPage(channelId: 50)),
    );

    testWidgets('渲染成员、我排第一、broken 提示与 ⚠', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_memberChannel],
          },
          'SYNO.Chat.User.list': _users(),
          'SYNO.Chat.Channel.Member.get': {
            'user_ids': [14, 4, 8],
            'broken_user_ids': [8],
          },
        },
      );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();

      expect(find.text('成员 (3)'), findsOneWidget);
      expect(find.text('我（我）'), findsOneWidget);
      expect(find.text('demo'), findsWidgets);
      expect(find.textContaining('1 位成员解不开'), findsOneWidget);
      expect(find.byIcon(Icons.report_gmailerrorred_outlined), findsWidgets);
    });

    testWidgets('过滤框按昵称/账号名筛选', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_memberChannel],
          },
          'SYNO.Chat.User.list': _users(),
          'SYNO.Chat.Channel.Member.get': {
            'user_ids': [14, 4, 8],
            'broken_user_ids': <int>[],
          },
        },
      );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'demo');
      await tester.pumpAndSettle();
      expect(find.text('成员 (1)'), findsOneWidget);
      expect(find.text('我（我）'), findsNothing);
    });

    testWidgets('点 broken 成员 → 确认后走 rescue 链路', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_memberChannel],
          },
          'SYNO.Chat.User.list': _users(),
          'SYNO.Chat.Channel.Member.get': {
            'user_ids': [14, 4, 8],
            'broken_user_ids': [8],
          },
          'SYNO.Chat.Channel.rescue': const {},
        },
      );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('没钥匙'));
      await tester.pumpAndSettle();
      expect(find.text('修复加密密钥'), findsOneWidget);
      await tester.tap(find.text('修复'));
      await tester.pumpAndSettle();

      // 本机没有频道密钥 → 修不了，但不该崩
      expect(find.byType(ChannelMembersPage), findsOneWidget);
      final ch = (await h.container.read(chatStoreProvider).allChannels())
          .firstWhere((c) => c.channelId == 50);
      expect(ch.brokenUsers, contains(8));
    });

    testWidgets('点别人 → 「发消息」开一对一（Channel.Anonymous/initiate v1）', (
      tester,
    ) async {
      final pushed = <String>[];
      final router = GoRouter(
        initialLocation: '/members',
        routes: [
          GoRoute(
            path: '/members',
            builder: (_, __) => const ChannelMembersPage(channelId: 50),
          ),
          GoRoute(
            path: '/chat/:channelId',
            builder: (_, state) {
              pushed.add(state.uri.toString());
              return const Scaffold(body: Text('聊天页'));
            },
          ),
        ],
      );
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_memberChannel],
          },
          'SYNO.Chat.User.list': _users(),
          'SYNO.Chat.Channel.Member.get': {
            'user_ids': [14, 4, 8],
            'broken_user_ids': [8],
          },
          'SYNO.Chat.Channel.Anonymous.initiate': {
            'channel': {
              'channel_id': 60,
              'type': 'anonymous',
              'is_joined': true,
              'members': [4, 14],
            },
          },
        },
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('demo').first);
      await tester.pumpAndSettle();
      expect(find.text('发消息'), findsOneWidget);
      await tester.tap(find.text('发消息'));
      await tester.pumpAndSettle();

      final call = h.transport.calls.firstWhere(
        (c) => c['api'] == 'SYNO.Chat.Channel.Anonymous',
      );
      expect(call['method'], 'initiate');
      expect(call['version'], '1');
      expect(
        call['user_ids'],
        '[4,14]',
        reason: '顺序必须是 [对方, 我]（反了服务端回 117，真机实测）',
      );
      expect(call['encrypted'], 'false', reason: '资料页「发消息」这条路原版就是非加密的');
      expect(
        call['channel_key_encs'],
        'null',
        reason: '原版 gson.toJson(null) = "null"',
      );
      expect(pushed, ['/chat/60'], reason: '开完会话要进聊天页');
    });

    testWidgets('已有同两个人的匿名会话 → 直接复用，不再打 initiate', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                'channel_id': 61,
                'type': 'anonymous',
                'is_joined': true,
                'members': [4, 14],
              },
            ],
          },
          'SYNO.Chat.User.list': _users(),
          'SYNO.Chat.Channel.Member.get': {
            'user_ids': [4, 14],
            'broken_user_ids': <int>[],
          },
        },
      );
      final id = await h.ctrl.startAnonymousConversation(4);
      expect(id, 61);
      expect(
        h.transport.calls.where(
          (c) =>
              c['api'] == 'SYNO.Chat.Channel.Anonymous' &&
              c['method'] == 'initiate',
        ),
        isEmpty,
        reason: '本地已有就别白跑（服务端会回 117）',
      );
    });

    test('服务端已有会话（initiate 回 117）→ 重拉列表复用，不冒错', () async {
      // boot 时服务端还没有这条会话 → 本地库为空
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {'channels': <Map<String, dynamic>>[]},
        },
      );
      // 现在"服务端有了"（模拟别的设备建的），并且 initiate 会撞 117
      h.transport.responses['SYNO.Chat.Channel.list'] = {
        'channels': [
          {
            'channel_id': 62,
            'type': 'anonymous',
            'is_joined': true,
            'members': [4, 14],
          },
        ],
      };
      h.transport.failTimes['SYNO.Chat.Channel.Anonymous.initiate'] = 117;

      final id = await h.ctrl.startAnonymousConversation(4);
      expect(id, 62, reason: '117 之后要回查并复用，而不是把错误抛给界面');
      expect(
        h.transport.calls.any((c) => c['method'] == 'initiate'),
        isTrue,
        reason: '本地看不到 → 确实打过一次 initiate',
      );
    });

    testWidgets('编辑模式勾人 → 移出（走 compound kick）', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_memberChannel],
          },
          'SYNO.Chat.User.list': _users(),
          'SYNO.Chat.Channel.Member.get': {
            'user_ids': [14, 4, 8],
            'broken_user_ids': <int>[],
          },
        },
      );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      // 我不可勾选（只有别人有 checkbox）
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('移出'));
      await tester.pumpAndSettle();
      expect(find.text('移出频道'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '移出'));
      await tester.pumpAndSettle();

      final kick = h.transport.calls
          .where((c) => c['api'] == 'SYNO.Entry.Request')
          .toList();
      expect(kick, isNotEmpty, reason: '要真的调复合踢人接口');
    });
  });
}
