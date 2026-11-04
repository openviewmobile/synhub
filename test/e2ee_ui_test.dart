// Phase 7：E2EE 的 UI/控制器层测试（离线）。
//
// 覆盖：身份状态机（设置/锁定/解锁/换口令/重置）、加密频道消息的
// 显示与发送（服务端只收密文、本地留明文）、加密状态条与设置页。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/settings/e2ee_controller.dart';
import 'package:synhub/src/features/settings/e2ee_page.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:drift/native.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

const _encryptedChannelJson = {
  'channel_id': 5,
  'name': '加密频道',
  'type': 'private',
  'is_joined': true,
  'encrypted': true,
  'channel_key_enc': 'SEALED',
  'last_post_at': 1000,
};

ChannelDto _channel({bool encrypted = true}) => ChannelDto.fromJson({
  'channel_id': 9,
  'type': 'private',
  'encrypted': encrypted,
  'name': '加密频道',
});

void main() {
  group('E2eeController 状态机', () {
    test('未设置 → setup → 锁定 → 解锁', () async {
      final h = await bootChat();
      final ctrl = h.container.read(e2eeControllerProvider.notifier);
      await ctrl.load();
      expect(h.container.read(e2eeControllerProvider).configured, isFalse);

      final svc = h.container.read(e2eeServiceProvider);
      expect(await ctrl.setup('pass-1'), isTrue);
      var state = h.container.read(e2eeControllerProvider);
      expect(state.configured, isTrue);
      expect(state.unlocked, isTrue);
      expect(state.publicKey, svc.publicKey);
      // setup 会把公钥/私钥上传服务端（update_key）
      final call = h.transport.calls.lastWhere(
        (c) => c['method'] == 'update_key',
      );
      expect(jsonDecode(call['public_key'] as String), svc.publicKey);
      expect(
        jsonDecode(call['private_key_enc'] as String),
        svc.identity!.privateKeyEnc,
      );

      ctrl.lock();
      expect(h.container.read(e2eeControllerProvider).unlocked, isFalse);
      expect(svc.channelKey(9), isNull);

      expect(await ctrl.unlock('wrong'), isFalse);
      expect(h.container.read(e2eeControllerProvider).error, isNotNull);
      expect(await ctrl.unlock('pass-1'), isTrue);
      expect(h.container.read(e2eeControllerProvider).unlocked, isTrue);
    });

    test('换口令会重新上传 private_key_enc；重置清空身份', () async {
      final h = await bootChat();
      final ctrl = h.container.read(e2eeControllerProvider.notifier);
      final svc = h.container.read(e2eeServiceProvider);
      await ctrl.setup('old');
      final firstEnc = svc.identity!.privateKeyEnc;

      expect(
        await ctrl.changePasscode(oldPasscode: 'old', newPasscode: 'new'),
        isTrue,
      );
      expect(svc.identity!.privateKeyEnc, isNot(firstEnc));
      final call = h.transport.calls.lastWhere(
        (c) => c['method'] == 'update_key',
      );
      expect(
        jsonDecode(call['private_key_enc'] as String),
        svc.identity!.privateKeyEnc,
      );
      expect(
        await ctrl.changePasscode(oldPasscode: 'nope', newPasscode: 'x'),
        isFalse,
      );

      await ctrl.reset();
      expect(h.container.read(e2eeControllerProvider).configured, isFalse);
      expect(svc.isConfigured, isFalse);
    });

    test('displayMessage：非加密原样 / 能解就解 / 解不开给占位', () async {
      final h = await bootChat();
      final ctrl = h.container.read(e2eeControllerProvider.notifier);
      final svc = h.container.read(e2eeServiceProvider);
      await ctrl.setup('p');
      svc.putChannelKey(9, List.filled(32, 4));

      expect(ctrl.displayMessage(_channel(encrypted: false), '明文'), '明文');
      final enc = svc.encryptMessage(9, '机密内容');
      expect(ctrl.displayMessage(_channel(), enc), '机密内容');

      // 锁上之后 → 占位
      ctrl.lock();
      expect(ctrl.displayMessage(_channel(), enc), kUndecryptableText);
    });

    test('displayFileName：加密频道里是 hex', () async {
      final h = await bootChat();
      final svc = h.container.read(e2eeServiceProvider);
      final ctrl = h.container.read(e2eeControllerProvider.notifier);
      await ctrl.setup('p');
      svc.putChannelKey(9, List.filled(32, 5));
      final hex = svc.encryptFileName(9, '报表.xlsx');
      expect(ctrl.displayFileName(_channel(), hex), '报表.xlsx');
      expect(
        ctrl.displayFileName(_channel(encrypted: false), 'a.txt'),
        'a.txt',
      );
    });
  });

  group('生命周期', () {
    test('没有监听者（provider 会被 dispose）时，异步方法不会炸', () async {
      final h = await bootChat();
      final ctrl = h.container.read(e2eeControllerProvider.notifier);
      final svc = h.container.read(e2eeServiceProvider);
      // 故意不 watch，模拟"只有 read、没有监听者"的场景
      final pending = ctrl.load();
      h.container.dispose();
      await pending; // 不该抛 "Cannot use the Ref ... after it has been disposed"
      expect(svc.isConfigured, isFalse);
    });
  });

  group('加密频道的收发', () {
    test('发送：服务端收到密文，本地存的是明文', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_encryptedChannelJson],
          },
          'SYNO.Chat.Post.list': {
            'posts': [testPostJson],
          },
        },
      );
      final svc = h.container.read(e2eeServiceProvider);
      final ctrl = h.container.read(e2eeControllerProvider.notifier);
      await ctrl.setup('p');
      svc.putChannelKey(5, List.filled(32, 6));

      h.transport.responses['SYNO.Chat.Post.create'] = {
        'post': {
          'post_id': 4294967400,
          'channel_id': 5,
          'creator_id': 14,
          'create_at': 3000,
          'type': 'normal',
          'message': 'CIPHERTEXT-FROM-SERVER',
          'props': {'encrypted': true},
        },
      };
      expect(await h.ctrl.sendMessage(5, '要加密的话'), isTrue);

      final createCall = h.transport.calls.lastWhere(
        (c) => c['method'] == 'create',
      );
      final wire = jsonDecode(createCall['message'] as String) as String;
      expect(wire, isNot('要加密的话'));
      expect(svc.tryDecryptMessage(5, wire), '要加密的话');

      // 本地那条是明文（列表/通知/搜索都能直接用）
      final store = h.container.read(chatStoreProvider);
      final posts = await store.postsForChannel(5, limit: 10);
      final mine = posts.firstWhere((p) => p.postId == 4294967400);
      expect(mine.message, '要加密的话');
      expect(mine.encrypted, isTrue);
    });

    test('非加密频道不加密，原样发出去', () async {
      final h = await bootChat();
      await h.ctrl.sendMessage(5, '普通消息');
      final createCall = h.transport.calls.lastWhere(
        (c) => c['method'] == 'create',
      );
      expect(jsonDecode(createCall['message'] as String), '普通消息');
    });
  });

  group('界面', () {
    testWidgets('E2EE 设置页：未开启 → 走设置弹窗 → 显示公钥', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: E2eePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('未开启端到端加密'), findsOneWidget);

      await tester.tap(find.text('设置加密口令'));
      await tester.pumpAndSettle();
      expect(find.text('再输一遍'), findsOneWidget);

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'pass-123');
      await tester.enterText(fields.at(1), 'pass-123');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.text('已开启并解锁'), findsOneWidget);
      final svc = h.container.read(e2eeServiceProvider);
      expect(svc.isUnlocked, isTrue);
    });

    testWidgets('E2EE 设置页：两次口令不一致不提交', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: E2eePage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置加密口令'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'aaa');
      await tester.enterText(fields.at(1), 'bbb');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('两次输入不一致'), findsOneWidget);
      expect(h.container.read(e2eeServiceProvider).isConfigured, isFalse);
    });

    testWidgets('E2EE 设置页：broken 成员显示 ⚠ 与「某某 解不开」', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [
              {
                ..._encryptedChannelJson,
                'broken_users': [4],
              },
            ],
          },
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 4,
                'username': 'demo',
                'nickname': 'demo',
                'type': 'human',
              },
            ],
          },
        },
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: E2eePage()),
        ),
      );
      await tester.pumpAndSettle();
      // 频道名 + "demo 解不开（可修复）"（频道名在别处也会出现，用 findsWidgets）
      expect(find.text('加密频道'), findsWidgets);
      expect(find.textContaining('解不开（可修复）'), findsOneWidget);
      expect(find.textContaining('demo'), findsOneWidget);
      expect(find.byIcon(Icons.report_gmailerrorred_outlined), findsWidgets);
      expect(find.text('修复'), findsOneWidget);
    });

    testWidgets('加密频道顶部状态条：锁定时提示并给解锁入口', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.list': {
            'channels': [_encryptedChannelJson],
          },
          'SYNO.Chat.Post.list': {'posts': <Map<String, dynamic>>[]},
        },
      );
      // 模拟"另一台设备设好了身份，这台机器刚装好"：只拿到身份、没解锁
      final elsewhere = E2eeService(
        ChatStore(ChatDatabase(NativeDatabase.memory())),
      );
      final remote = await elsewhere.setup('p');
      await h.container.read(e2eeServiceProvider).adoptServerIdentity(remote);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChatPageForTest(channelId: 5)),
        ),
      );
      await tester.pumpAndSettle();
      final bar = h.container.read(e2eeControllerProvider.notifier);
      final channel = ChannelDto.fromJson(_encryptedChannelJson);
      expect(bar.keyStateOf(channel), ChannelKeyState.locked);
      expect(find.textContaining('加密频道已锁定'), findsOneWidget);
      expect(find.text('解锁'), findsOneWidget);
    });
  });
}

/// 测试里给 ChatPage 一个固定频道：直接复用真实的 ChatPage。
class ChatPageForTest extends StatelessWidget {
  const ChatPageForTest({super.key, required this.channelId});

  final int channelId;

  @override
  Widget build(BuildContext context) => ChatPage(channelId: channelId);
}
