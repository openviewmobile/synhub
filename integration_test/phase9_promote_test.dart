// Phase 9 真机验收：「发消息」开一对一 + 「将会话转换为专用频道」。
//
//   flutter test integration_test/phase9_promote_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 只有真机能回答的问题：
//   ① `Channel.Anonymous / initiate`（非加密、`user_ids=[对方,我]`、
//      `channel_key_encs="null"`）在这台服务端上认不认 —— 反编译里
//      `ProfileFragment` 的「发消息」就是这条路；
//   ② `Channel.Anonymous / promote` v2 到底把会话变成什么（type/name/成员），
//      以及它落的组（升级后该从「会话」挪进「频道」）。
//
// ⚠️ 会建一个跟用户 #6 的一对一会话，验完**关掉**（`Channel/close` v2）。
// 若这个会话本来就存在（不是我们建的），就只验证"复用"那条路，绝不 promote/close。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/features/chat/channel_sort.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

/// 验收用的对方账号（demo_admin/demo 都是本人的账号）
const int _peerUserId = 6;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：开一对一 + 升级为专用频道', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(account: _account, password: _password, session: 'Chat');

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);
    final store = container.read(chatStoreProvider);
    final myId = container.read(chatSessionControllerProvider).myUserId;
    debugPrint('[p9pm] 我是 #$myId');

    final before = (await store.allChannels()).map((c) => c.channelId).toSet();

    // ---------- ① 「发消息」开一对一 ----------
    final channelId = await ctrl.startAnonymousConversation(_peerUserId);
    expect(channelId, greaterThan(0), reason: '服务端该返回会话 id');
    debugPrint('[p9pm] startAnonymousConversation(#$_peerUserId) → #$channelId '
        '（${before.contains(channelId) ? "复用已有" : "新建"}）');

    final anon = (await store.allChannels())
        .firstWhere((c) => c.channelId == channelId);
    expect(anon.type, 'anonymous');
    expect(anon.members, containsAll([_peerUserId, myId]));
    debugPrint('[p9pm] 会话类型=${anon.type} 成员=${anon.members} '
        '加密=${anon.encrypted}');
    // 升级前应该落在「会话」组
    final groupsBefore = buildSidebarGroups(await store.allChannels(),
        myUserId: myId);
    final sectionBefore = groupsBefore
        .firstWhere((g) => g.channels.any((c) => c.channelId == channelId))
        .section;
    expect(sectionBefore, SidebarSection.conversation);
    debugPrint('[p9pm] 升级前分组 = ${sectionBefore.name} ✓');

    if (before.contains(channelId)) {
      debugPrint('[p9pm] ⚠️ 这个会话本来就存在 → 只验复用，不 promote/close');
      return;
    }

    // ---------- ② promote → 专用频道 ----------
    // ⚠️ 名字里**不能有空格**：真机实测服务端对带空格的频道名直接回
    // 407 CHAT_ERR_INVALID_RECORD（"cannot promote"）；原版客户端
    // `PromoteChannelFragment` 也是拿 `name.contains(" ")` 先拦一道
    // （见 `lib/src/features/chat/channel_name.dart`）。
    final name = '验收专用频道${DateTime.now().millisecondsSinceEpoch}';
    final promoted = await ctrl.promoteChannel(channelId,
        name: name, purpose: 'p9pm 自动验收建的，验完就关');
    expect(promoted, isNotNull, reason: 'promote 该回一个频道对象');
    debugPrint('[p9pm] promote 返回：type=${promoted!.type} name=${promoted.name} '
        'members=${promoted.members} encrypted=${promoted.encrypted}');

    final after = (await store.allChannels())
        .firstWhere((c) => c.channelId == channelId);
    debugPrint('[p9pm] 本地行：type=${after.type} name=${after.name} '
        'purpose=${after.purpose}');
    expect(after.type, 'private', reason: '真机实测：升级后服务端给的是 private');
    debugPrint('[p9pm] 升级后 members=${after.members}'
        '（`channels.members` 这个唯一键列被清空，成员关系仍在 channel_members 里）');
    expect(after.name, name, reason: '名字要落库');

    // 升级后该从「会话」挪到「频道」（或星标）组
    final groupsAfter =
        buildSidebarGroups(await store.allChannels(), myUserId: myId);
    final sectionAfter = groupsAfter
        .firstWhere((g) => g.channels.any((c) => c.channelId == channelId))
        .section;
    expect(sectionAfter, isNot(SidebarSection.conversation));
    debugPrint('[p9pm] 升级后分组 = ${sectionAfter.name} ✓');

    // ---------- ③ 收拾现场：关掉这个验收频道 ----------
    await ctrl.closeChannel(channelId);
    final gone = (await store.allChannels())
        .every((c) => c.channelId != channelId);
    expect(gone, isTrue, reason: '关闭后本地该整条删掉');
    debugPrint('[p9pm] 验收频道 #$channelId 已关闭并清理 ✓');

    debugPrint('[p9pm] ✅ 开会话 / 升级频道 验收完成');
  });
}
