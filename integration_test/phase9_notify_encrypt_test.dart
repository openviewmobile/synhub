// Phase 9 真机验收：`User / notify_encrypt`（通知"没设口令"的成员）。
//
//   flutter test integration_test/phase9_notify_encrypt_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 要验证的风险点只有一个：`user_ids` 必须是 **Gson 序列化的 JSON 数组**（`[9]`），
// 传别的形状服务端会 101。真机上挑一个真实存在的 user_id 发一次，确认服务端接受；
// 另外把"本地判定谁没口令"的规则也跑一遍（`Key_pair` 缺失 = 没口令）。
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

  testWidgets('Phase 9 真机：notify_encrypt 协议', (tester) async {
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

    // ---------- 谁没配口令 ----------
    final users = await chat.listUsers();
    final me = container.read(chatSessionControllerProvider).myUserId;
    for (final u in users.where((u) => u.type == 'human')) {
      debugPrint('[p9n] #${u.userId} ${u.displayName} '
          '口令=${u.publicKey.isEmpty ? '无' : '有'}');
    }
    final noKey = users
        .where((u) => u.type == 'human' && u.publicKey.isEmpty && !u.isDeleted)
        .map((u) => u.userId)
        .toList();
    debugPrint('[p9n] 本地判定"没口令"的人：$noKey（我 = $me）');

    // ---------- 真的发一次 ----------
    // 优先用"没口令的真人"；这台 NAS 如果只有我自己，就拿我自己的 id 验证协议形状
    final targets = noKey.isNotEmpty ? noKey : [me];
    expect(targets, isNotEmpty);
    final ok = await ctrl.notifyEncrypt(targets);
    expect(ok, isTrue, reason: 'user_ids=$targets 服务端应当接受');

    // ---------- 反例：形状错了要失败（证明这个字段真被服务端解析） ----------
    Object? wrongShapeError;
    try {
      await conn.api.call(
        'SYNO.Chat.User',
        'notify_encrypt',
        preferredVersion: 1,
        // ⚠️ 不能写 '$targets'：`[6]` 本身就是合法 JSON，会被服务端照收。
        // 要证明"这个字段真被解析"，得传一个**不是** JSON 数组的串。
        params: {'user_ids': 'not-a-json-array'},
      );
    } catch (e) {
      wrongShapeError = e;
    }
    debugPrint('[p9n] 非 JSON 形状的返回值：$wrongShapeError');
    expect(wrongShapeError, isNotNull,
        reason: '如果这个也成功，说明 user_ids 根本没被解析');

    debugPrint('[p9n] ✅ notify_encrypt 验收通过');
  });
}
