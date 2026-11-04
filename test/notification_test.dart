// Phase 8：本地通知的决策、内容与动作（离线）。
//
// 原生那一半（Kotlin）没法在单测里跑，所以这里用一个假 `BackgroundService`
// 截获「要弹什么」，验证：
//   * 谁不该提醒（自己发的 / 系统消息 / 静音频道 / App 在前台）
//   * 提醒什么内容（E2EE 频道解密；锁着时是占位且不给回复按钮）
//   * 去重、贪睡
//   * 通知动作：已读打服务端、回复走 sendMessage（加密频道发密文）
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';
import 'package:synhub/src/features/settings/e2ee_controller.dart';
import 'package:synhub/src/features/settings/notification_settings_page.dart';
import 'package:synhub/src/features/settings/snooze_controller.dart';
import 'package:synhub/src/native/background_service.dart';

import 'support/chat_harness.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/fake_background.dart';

PostDto _post({
  int id = 1001,
  int channelId = 5,
  int creatorId = 4,
  String message = '在吗',
  String type = 'normal',
}) => PostDto.fromJson({
  'post_id': id,
  'channel_id': channelId,
  'creator_id': creatorId,
  'create_at': 9000,
  'type': type,
  'message': message,
});

ChannelDto _channel({
  int id = 5,
  String name = '测试频道',
  bool encrypted = false,
  bool mute = false,
}) => ChannelDto.fromJson({
  'channel_id': id,
  'name': name,
  'type': 'public',
  'encrypted': encrypted,
  if (mute) 'preferences': {'notification_mute': true},
});

/// 造一个带假原生层的辅助环境
({ChatHarness harness, FakeBackground bg, NotificationService service}) _env(
  ChatHarness h,
) {
  final bg = FakeBackground();
  final service = NotificationService(
    h.container.read(notificationServiceProvider).ref,
    background: bg,
  );
  return (harness: h, bg: bg, service: service);
}

void main() {
  test('自己发的 / 系统消息 / 静音频道都不提醒', () async {
    final h = await bootChat();
    final e = _env(h);
    e.service.appInForeground = false; // 假装退到后台

    expect(
      await e.service.maybeNotify(_post(creatorId: 14), channel: _channel()),
      isFalse,
    );
    expect(
      await e.service.maybeNotify(_post(type: 'system'), channel: _channel()),
      isFalse,
    );
    expect(
      await e.service.maybeNotify(_post(), channel: _channel(mute: true)),
      isFalse,
    );
    expect(e.bg.shown, isEmpty);
  });

  test('前台不弹通知；退到后台才弹，正文与标题正确', () async {
    final h = await bootChat();
    final e = _env(h);
    e.service.appInForeground = true;
    expect(await e.service.maybeNotify(_post(), channel: _channel()), isFalse);

    e.service.appInForeground = false;
    expect(await e.service.maybeNotify(_post(), channel: _channel()), isTrue);
    final n = e.bg.shown.single;
    expect(n.channelId, 5);
    expect(n.postId, 1001);
    expect(n.text, '在吗');
    expect(n.canReply, isTrue);
    expect(n.title, contains('测试频道')); // 发送者(取不到名字) + 频道名
  });

  test('同一条消息只提醒一次（socket 重连重放要挡住）', () async {
    final h = await bootChat();
    final e = _env(h);
    e.service.appInForeground = false;
    await e.service.maybeNotify(_post(), channel: _channel());
    await e.service.maybeNotify(_post(), channel: _channel());
    expect(e.bg.shown, hasLength(1));
  });

  test('加密频道：解锁后提醒明文；锁着时占位且不能回复', () async {
    final h = await bootChat();
    final e = _env(h);
    final svc = h.container.read(e2eeServiceProvider);
    await h.container.read(e2eeControllerProvider.notifier).setup('p');
    svc.putChannelKey(5, List.filled(32, 3));
    e.service.appInForeground = false;

    final enc = _channel(encrypted: true);
    final wire = svc.encryptMessage(5, '秘密内容');
    expect(
      await e.service.maybeNotify(_post(id: 2001, message: wire), channel: enc),
      isTrue,
    );
    expect(e.bg.shown.last.text, '秘密内容');
    expect(e.bg.shown.last.canReply, isTrue);

    // 锁上以后：占位文案 + 不给回复按钮
    h.container.read(e2eeControllerProvider.notifier).lock();
    expect(
      await e.service.maybeNotify(_post(id: 2002, message: wire), channel: enc),
      isTrue,
    );
    expect(e.bg.shown.last.text, kUndecryptableText);
    expect(e.bg.shown.last.canReply, isFalse);
  });

  test('通知动作：已读打服务端；回复走 sendMessage（加密频道发密文）', () async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Channel.list': {
          'channels': [
            {
              'channel_id': 5,
              'name': '加密频道',
              'type': 'private',
              'is_joined': true,
              'encrypted': true,
              'channel_key_enc': 'SEALED',
            },
          ],
        },
      },
    );
    final e = _env(h);
    final svc = h.container.read(e2eeServiceProvider);
    await h.container.read(e2eeControllerProvider.notifier).setup('p');
    svc.putChannelKey(5, List.filled(32, 4));

    // 已读
    await e.service.handleAction(
      const NotificationAction(
        action: NotificationAction.markRead,
        channelId: 5,
        postId: 1001,
      ),
    );
    expect(h.transport.calls.any((c) => c['method'] == 'view'), isTrue);

    // 回复（加密频道 → 服务端收到的是密文）
    h.transport.responses['SYNO.Chat.Post.create'] = {
      'post': {
        'post_id': 9001,
        'channel_id': 5,
        'creator_id': 14,
        'create_at': 9100,
        'type': 'normal',
        'message': 'CIPHER',
      },
    };
    await e.service.handleAction(
      const NotificationAction(
        action: NotificationAction.reply,
        channelId: 5,
        postId: 1001,
        text: '通知里回复的内容',
      ),
    );
    final create = h.transport.calls.lastWhere((c) => c['method'] == 'create');
    // 表单这条路服务端要 JSON 编码过的字符串，所以这里先解一层
    final wire = jsonDecode(create['message'] as String) as String;
    expect(svc.tryDecryptMessage(5, wire), '通知里回复的内容');
    // 「已读」现在按**频道**撤通知（原来是一条一条按 postId 撤）
    expect(e.bg.cancelledChannels, contains(5));
  });

  test('贪睡：设全局免打扰 1 小时 + 撤掉该频道通知（原版 NotificationActionWorker）', () async {
    final h = await bootChat();
    final e = _env(h);
    final ok = await e.service.snooze(5);
    expect(ok, isTrue);
    // 服务端收到的是「服务端时钟」的截止时间
    final call = h.transport.calls.lastWhere(
      (c) => c['api'] == 'SYNO.Chat.User.Preference' && c['method'] == 'set',
    );
    expect(call['version'], '1');
    expect(call['snooze'], greaterThan(DateTime.now().millisecondsSinceEpoch));
    // 通知被撤掉（按频道撤）
    expect(e.bg.cancelledChannels, contains(5));
    // 状态是"免打扰中"，所以后续消息不会再弹
    expect(h.container.read(snoozeControllerProvider).manualActiveNow, isTrue);
  });

  testWidgets('设置页：开关自启 + 发测试通知', (tester) async {
    // ★ r693（DA334）：「前台服务 / 开机自启」两段现在按能力位 fail-closed，
    //   宿主上（macOS）没有 `synhub/background` 桥 ⇒ 不摆。本用例验的是**开关真的
    //   调到桥**，所以要先显式把门放开；门本身的开关行为由
    //   `desktop_mobile_only_gates_test.dart` 双向钉住。
    debugForceCapabilityGate = true;
    addTearDown(() => debugForceCapabilityGate = false);
    final h = await bootChat();
    final bg = FakeBackground();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: ProviderScope(
          overrides: [backgroundServiceProvider.overrideWithValue(bg)],
          child: MaterialApp(theme: AppTheme.dark(), home: NotificationSettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('通知与后台'), findsOneWidget);

    await tester.tap(find.text('开机自启'));
    await tester.pumpAndSettle();
    expect(bg.autoBoot, isTrue);

    await tester.tap(find.text('发一条测试通知'));
    await tester.pumpAndSettle();
    expect(bg.shown.single.text, contains('测试通知'));
  });
}
