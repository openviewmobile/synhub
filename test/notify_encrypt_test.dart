// Phase 9：`User / notify_encrypt`（通知"没设口令"的成员）+ 邀请侧的
// `dialog_no_passphrase` 流程。
//
// 对齐原版：
//   * `AccountManager.notifyEncrypt(List<Integer>)` → `SYNO.Chat.User / notify_encrypt`
//     v1，`user_ids` 是 **Gson 序列化的 JSON 数组**（`[8]`），失败只记日志；
//   * `NamedCreateFragment.removeNoPassphraseUsers` / `AnonymousInviteFragment`：
//     加密频道把"没配口令"的人**移出邀请列表**，勾了「通知他们」才发这个请求；
//   * 邀请列表**不隐藏**这些人（原版也是让你选完再弹窗）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/channel_members_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/settings/e2ee_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

const _pk4 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
// 加密频道 #50：我是 14，已在里面；可邀请 4(有钥匙) / 9(没钥匙)
const _encChannel = {
  'channel_id': 50,
  'name': '加密频道',
  'type': 'private',
  'is_joined': true,
  'encrypted': true,
  'channel_key_enc': 'SEALED',
  'members': [14],
  'creator_id': 14,
  'last_post_at': 1000,
};

Map<String, dynamic> _usersJson() => {
  'users': [
    {'user_id': 14, 'username': 'me', 'nickname': '我', 'type': 'human'},
    {
      'user_id': 4,
      'username': 'demo',
      'nickname': 'demo',
      'type': 'human',
      'user_props': {
        'key_pair': {'public_key': _pk4},
      },
    },
    {'user_id': 9, 'username': 'nopk', 'nickname': '没钥匙', 'type': 'human'},
  ],
};

Future<ChatHarness> _boot() async {
  final h = await bootChat(
    extra: {
      'SYNO.Chat.Channel.list': {
        'channels': [_encChannel],
      },
      'SYNO.Chat.User.list': _usersJson(),
      'SYNO.Chat.Channel.Member.get': {
        'user_ids': [14],
        'broken_user_ids': <int>[],
        'members': [
          {'user_id': 14, 'username': 'me', 'nickname': '我', 'type': 'human'},
        ],
      },
    },
  );
  // 本地要有频道密钥才能封给别人
  await h.container.read(e2eeControllerProvider.notifier).setup('flt-pass');
  h.container.read(e2eeServiceProvider).putChannelKey(50, List.filled(32, 7));
  return h;
}

List<Map<String, dynamic>> _callsTo(
  FakeTransport t,
  String api,
  String method,
) => t.calls.where((c) => c['api'] == api && c['method'] == method).toList();

Future<void> _pump(WidgetTester tester, ChatHarness h) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(theme: AppTheme.dark(), home: ChannelMembersPage(channelId: 50)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('User / notify_encrypt 协议', () {
    test('v1：user_ids 是 Gson 的 JSON 数组', () async {
      final h = await _boot();
      h.transport.responses['SYNO.Chat.User.notify_encrypt'] = const {};
      await h.ctrl.notifyEncrypt([9, 12]);

      final call = _callsTo(
        h.transport,
        'SYNO.Chat.User',
        'notify_encrypt',
      ).single;
      expect(call['version'], '1');
      expect(call['user_ids'], '[9,12]');
    });

    test('空列表：一个请求都不发', () async {
      final h = await _boot();
      expect(await h.ctrl.notifyEncrypt(const []), isFalse);
      expect(
        _callsTo(h.transport, 'SYNO.Chat.User', 'notify_encrypt'),
        isEmpty,
      );
    });

    test('失败不抛异常（原版只记日志）', () async {
      final h = await _boot();
      h.transport.failures['SYNO.Chat.User.notify_encrypt'] = 101;
      expect(await h.ctrl.notifyEncrypt([9]), isFalse);
    });
  });

  group('挑出没设口令的人', () {
    test('usersWithoutPublicKey 只回没有公钥的（顺序跟着入参）', () async {
      final h = await _boot();
      final noKey = await h.container
          .read(channelCreateControllerProvider)
          .usersWithoutPublicKey([4, 9, 14]);
      expect(noKey.map((u) => u.userId), [9, 14]);
    });
  });

  group('邀请加密频道（dialog_no_passphrase）', () {
    testWidgets('选中有钥匙 + 没钥匙 → 弹窗；勾「通知他们」→ 邀请剩下的人并通知', (tester) async {
      final h = await _boot();
      await _pump(tester, h);

      await tester.tap(find.byTooltip('邀请成员'));
      await tester.pumpAndSettle();
      expect(find.text('没钥匙'), findsOneWidget, reason: '原版不隐藏没口令的人');

      await tester.tap(find.text('demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('没钥匙'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('邀请 (2)'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 位'), findsOneWidget);
      await tester.tap(find.text('通知他们去设置口令'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      final invite = _callsTo(
        h.transport,
        'SYNO.Chat.Channel.Named',
        'invite',
      ).single;
      expect('${invite['user_ids']}', contains('4'));
      expect(
        '${invite['user_ids']}',
        isNot(contains('9')),
        reason: '没口令的人被移出邀请名单',
      );
      final notify = _callsTo(
        h.transport,
        'SYNO.Chat.User',
        'notify_encrypt',
      ).single;
      expect(notify['user_ids'], '[9]');
      expect(find.text('已邀请'), findsOneWidget);
    });

    testWidgets('不勾通知 → 只移出，不发 notify_encrypt', (tester) async {
      final h = await _boot();
      await _pump(tester, h);

      await tester.tap(find.byTooltip('邀请成员'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('没钥匙'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('邀请 (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(
        _callsTo(h.transport, 'SYNO.Chat.Channel.Named', 'invite'),
        hasLength(1),
      );
      expect(
        _callsTo(h.transport, 'SYNO.Chat.User', 'notify_encrypt'),
        isEmpty,
      );
    });

    testWidgets('弹窗取消 → 邀请整个不动', (tester) async {
      final h = await _boot();
      await _pump(tester, h);

      await tester.tap(find.byTooltip('邀请成员'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('没钥匙'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('邀请 (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(
        _callsTo(h.transport, 'SYNO.Chat.Channel.Named', 'invite'),
        isEmpty,
      );
      expect(
        _callsTo(h.transport, 'SYNO.Chat.User', 'notify_encrypt'),
        isEmpty,
      );
    });

    testWidgets('只选了没口令的人 → 确认后不邀请，只提示', (tester) async {
      final h = await _boot();
      await _pump(tester, h);

      await tester.tap(find.byTooltip('邀请成员'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('没钥匙'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('邀请 (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(
        _callsTo(h.transport, 'SYNO.Chat.Channel.Named', 'invite'),
        isEmpty,
      );
      expect(find.textContaining('都没有设置口令'), findsOneWidget);
    });

    testWidgets('普通频道不弹窗、直接邀请', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                'channel_id': 50,
                'name': '普通频道',
                'type': 'private',
                'is_joined': true,
                'members': [14],
                'creator_id': 14,
              },
            ],
          },
          'SYNO.Chat.User.list': _usersJson(),
          'SYNO.Chat.Channel.Member.get': {
            'user_ids': [14],
            'broken_user_ids': <int>[],
          },
        },
      );
      await _pump(tester, h);

      await tester.tap(find.byTooltip('邀请成员'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('没钥匙'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('邀请 (1)'));
      await tester.pumpAndSettle();

      expect(find.textContaining('还没有设置端到端加密口令'), findsNothing);
      expect(
        _callsTo(h.transport, 'SYNO.Chat.Channel.Named', 'invite'),
        hasLength(1),
      );
    });
  });
}
