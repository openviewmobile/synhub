// Phase 9 真机验收：`SYNO.Chat.Channel / enter`。
//
//   flutter test integration_test/phase9_enter_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 要验证的是：真机上 `enter` 到底接受哪个版本、`conn_id` 该是什么形状（Gson 串），
// 以及"先 enter 再标已读"这个顺序能不能跑通（原版 `ChannelFragment.enterChannel`）。
// 顺带确认：没 conn_id 时服务端会怎么答（对照组）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：Channel/enter', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);

    final connId = container.read(chatSessionControllerProvider).connId;
    debugPrint('[p9e] conn_id=$connId');
    expect(connId, isNotNull);
    expect(connId, isNotEmpty);

    // 挑一个我真正在里面的频道（enter 对非成员频道没意义）
    final joined = (await chat.listChannels())
        .where((c) => c.isJoined && !c.isChatBotType)
        .toList();
    expect(joined, isNotEmpty, reason: '账号至少要在一个频道里');
    final channelId = joined.first.channelId;
    debugPrint('[p9e] 用频道 #$channelId ${joined.first.name}');

    // ---------- 控制器路径（enter + 标已读） ----------
    final entered = await ctrl.enterChannel(channelId);
    expect(entered, isTrue, reason: '真机上 enter 应当成功');
    final lastViewAt = await ctrl.markRead(channelId);
    debugPrint('[p9e] enter 成功；view 返回 last_view_at=$lastViewAt');

    // 直接按协议再发一次，确认版本/字段（v2 + Gson 串 conn_id）
    await chat.enterChannel(channelId, connId!);
    final versioned = await conn.api.call(
      'SYNO.Chat.Channel',
      'enter',
      preferredVersion: 2,
      params: {'channel_id': '$channelId', 'conn_id': '"$connId"'},
    );
    debugPrint('[p9e] 直接 v2 调用返回：$versioned');

    // ---------- 对照组：conn_id 不是 Gson 串 ----------
    Object? rawConnResult;
    try {
      rawConnResult = await conn.api.call(
        'SYNO.Chat.Channel',
        'enter',
        preferredVersion: 2,
        params: {'channel_id': '$channelId', 'conn_id': connId}, // 无引号
      );
    } catch (e) {
      rawConnResult = e;
    }
    debugPrint('[p9e] conn_id 不带引号的返回：$rawConnResult');

    // ---------- 对照组：v5 上这个方法不存在（原版写死 2 的原因） ----------
    Object? v5Result;
    try {
      v5Result = await conn.api.call(
        'SYNO.Chat.Channel',
        'enter',
        preferredVersion: 5,
        params: {'channel_id': '$channelId', 'conn_id': '"$connId"'},
      );
    } catch (e) {
      v5Result = e;
    }
    debugPrint('[p9e] v5 调用的返回：$v5Result');

    debugPrint('[p9e] ✅ Channel/enter 验收通过');
  });
}
