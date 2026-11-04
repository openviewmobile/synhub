// 服务端设置同步：登录后拉 `SYNO.Chat.Admin.Setting/get` + 实时 `setting.update`
// 广播覆盖，以及它如何影响"编辑窗口 / 文件大小 / 通知默认档位"。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/settings/server_settings.dart';
import 'package:synhub/src/data/remote/socket/socket_events.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'support/chat_harness.dart';

/// 等到假传输上真的发出过某个请求（`_loadServerSettings` 是 unawaited 的）
Future<void> _waitCall(FakeTransport t, String api) async {
  for (var i = 0; i < 100; i++) {
    if (t.calls.any((c) => c['api'] == api)) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('没等到 $api 调用');
}

/// 真机 `Setting/get` 响应（NAS 2.3.1）
const _live = <String, dynamic>{
  'allow_edit_message': true,
  'allow_edit_message_time_within_min': -1,
  'allow_encryption': true,
  'allow_guest': false,
  'allow_read_status': false,
  'file_size_limit': 0,
  'notify_type': 'mention_subscribe',
  'readonly_profile': <String>[],
};

void main() {
  test('登录后拉服务端设置：落库 + 内存状态 + 版本能力', () async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Admin.Setting.get': {..._live, 'file_size_limit': 64},
      },
    );
    await _waitCall(h.transport, 'SYNO.Chat.Admin.Setting');

    final s = h.container.read(serverSettingsProvider);
    expect(s.fileSizeLimitMb, 64);
    expect(s.defaultNotificationType, 'mention_subscribe');
    expect(s.fileSizeLimitBytes, 64 * 1048576);

    // 版本能力（假表里 maxVersion=5 → v4 支持）
    final sync = h.container.read(chatSessionControllerProvider);
    expect(sync.supportsEditAllPost, isTrue);
    expect(sync.supportsReadStatus, isTrue);

    // 调用参数/版本
    final call = h.transport.calls.lastWhere(
      (c) => c['api'] == 'SYNO.Chat.Admin.Setting',
    );
    expect(call['method'], 'get');
    expect('${call['version']}', '4', reason: 'getMaxAvailableVersion(4,1)');

    // 落库（重启后 preload 能读回来）
    final raw = await h.container
        .read(settingsServiceProvider)
        .serverSettingsJson();
    expect(raw, isNotNull);
    expect(jsonDecode(raw!)['file_size_limit'], 64);
  });

  test('setting.update 广播增量覆盖（没带的字段保持）', () async {
    final h = await bootChat(
      extra: {
        'SYNO.Chat.Admin.Setting.get': {..._live, 'file_size_limit': 64},
      },
    );
    // 等"登录时那次拉取"真的落进状态，否则它可能后到并把广播覆盖回去
    for (
      var i = 0;
      i < 100 && h.container.read(serverSettingsProvider).fileSizeLimitMb != 64;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(h.container.read(serverSettingsProvider).fileSizeLimitMb, 64);

    // ⚠️ `setting.update` 走的是 `client.broadcast`（原版 SocketHelper 的
    // broadcast what 分支里就有它），不是顶层事件
    await h.ctrl.handleEvent(
      ChatSocketEvent(SocketEvent.clientBroadcast, const {
        'type': BroadcastType.settingUpdate,
        'data': {
          'allow_edit_message': false,
          'allow_edit_message_time_within_min': 5,
        },
      }),
    );

    final s = h.container.read(serverSettingsProvider);
    expect(s.allowEditMessage, isFalse);
    expect(s.editMessageTimeWithinMin, 5);
    expect(s.defaultNotificationType, 'mention_subscribe', reason: '推送没带');
    expect(s.allowEncryption, isTrue);
  });

  test('preload：冷启动先读缓存（离线也有正确的限制）', () async {
    final h = await bootChat();
    // 模拟上次运行留下的缓存
    await h.container
        .read(chatStoreProvider)
        .setSetting(
          kServerSettingsKey,
          jsonEncode(const {'file_size_limit': 8}),
        );
    // 冷启动时 state 还是默认值
    expect(h.container.read(serverSettingsProvider).fileSizeLimitMb, 0);

    await h.container.read(serverSettingsProvider.notifier).preload();
    expect(h.container.read(serverSettingsProvider).fileSizeLimitMb, 8);
    expect(
      h.container.read(serverSettingsProvider).allowEncryption,
      isTrue,
      reason: '缓存里没有的字段回落默认值',
    );
  });
}
