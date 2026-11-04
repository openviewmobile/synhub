// Phase 6/7 真机验收：**在 App 里新建频道**（含加密频道的密钥分发）。
//
//   flutter test integration_test/phase6_channel_create_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_LIVE_POST=true
//
// 走的是 App 自己的代码（`ChannelCreateController` → `ChatApi`），在真 NAS 上：
//   ① 建一个**普通**私有频道并邀请 demo(#4) → 服务端列表能看到、成员能看到；
//   ② 建一个**加密**频道：生成密钥 → create → join(自带 channel_key_enc) → invite
//      （用 #4 公钥封一份）→ 服务端 `channel_key_enc` 存在、我本地能解开、
//      **发的密文能读回并解出原文**（这才证明密钥分发是对的）；
//   ③ 用另一个 ProviderContainer 模拟"换台设备"：只从服务端拿 `channel_key_enc` +
//      口令解私钥 → 也能解开同一个频道（密钥真的在服务端可恢复）；
//   ④ 收尾把两个频道都退掉（服务端没有 delete）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _passcode = 'flt-e2ee-pass';
const _invitee = 4;

String _marker(String kind) =>
    'flt-p6-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 6 真机：新建普通/加密频道 + 密钥分发', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    await container.read(chatSessionControllerProvider.notifier).start(conn);
    debugPrint('[p6c] 我=#${container.read(chatSessionControllerProvider).myUserId}');
    final create = container.read(channelCreateControllerProvider);
    final e2ee = container.read(e2eeServiceProvider);

    // 本机身份：服务端那对密钥用固定口令解锁（真机上是「端到端加密」页做过的）
    await container.read(chatSessionControllerProvider.notifier).refresh();
    if (e2ee.identity == null) {
      debugPrint('[p6c] 本地没有身份，先从服务端认领');
      final mine = await chat.myUser();
      if (mine != null && mine.publicKey.isNotEmpty) {
        await e2ee.adoptServerIdentity(
            E2eeIdentity(publicKey: mine.publicKey, privateKeyEnc: mine.privateKeyEnc));
      }
    }
    expect(e2ee.identity, isNotNull, reason: '需要有 E2EE 身份才能测加密频道');
    try {
      await e2ee.unlock(_passcode);
    } catch (e) {
      debugPrint('[p6c] 口令解不开私钥（$e）—— 加密频道仍可创建，但读不回密文');
    }
    debugPrint('[p6c] 身份公钥=${e2ee.identity!.publicKey.substring(0, 16)}… '
        '已解锁=${e2ee.isUnlocked}');

    final plainName = _marker('plain');
    final encName = _marker('enc');
    var plainId = 0;
    var encId = 0;

    // ---------- ① 普通频道 ----------
    final plain = await create.create(
      name: plainName,
      purpose: 'Phase 6 真机验收（普通）',
      type: 'private',
      memberIds: const [_invitee],
    );
    plainId = plain.channelId;
    expect(plainId, greaterThan(0));
    final plainDto = (await chat.listChannelsByIds([plainId])).single;
    expect(plainDto.name, plainName);
    expect(plainDto.encrypted, isFalse);
    // 成员不在 `Channel/get` 里，要单独问 `Channel.Member/get`
    final plainMembers = await chat.listChannelMembers(plainId);
    expect(plainMembers.userIds, contains(_invitee), reason: '邀请的成员要在里面');
    expect(plainMembers.brokenUserIds, isEmpty, reason: '普通频道没有 broken 概念');
    debugPrint('[p6c] 普通频道 #$plainId 建好，members=${plainMembers.userIds} ✓');

    // ---------- ② 加密频道 ----------
    final enc = await create.create(
      name: encName,
      purpose: 'Phase 6 真机验收（加密）',
      type: 'private',
      encrypted: true,
      memberIds: const [_invitee],
    );
    encId = enc.channelId;
    expect(encId, greaterThan(0));
    final encDto = (await chat.listChannelsByIds([encId])).single;
    expect(encDto.encrypted, isTrue);
    expect(encDto.channelKeyEnc, isNotEmpty, reason: '服务端要存着我的 channel_key_enc');
    final encMembers = await chat.listChannelMembers(encId);
    expect(encMembers.userIds, containsAll([_invitee, 14]));
    expect(encMembers.brokenUserIds, isEmpty,
        reason: '我们给 #4 封了密钥，不该是 broken');
    // 本地那把密钥能解开服务端存的那份（= 换个进程也能恢复）
    final reopened = E2eeService(container.read(chatStoreProvider));
    await reopened.adoptServerIdentity(e2ee.identity!);
    await reopened.unlock(_passcode);
    expect(reopened.loadChannelKey(encId, encDto.channelKeyEnc), isTrue,
        reason: '服务端存的 channel_key_enc 要用我的私钥能解开');
    expect(reopened.channelKey(encId), e2ee.channelKey(encId),
        reason: '解出来的必须就是刚才那把频道密钥');
    debugPrint('[p6c] 加密频道 #$encId 建好，channel_key_enc=${encDto.channelKeyEnc.length} 字节，'
        '本地/服务端密钥一致 ✓');

    // ---------- ③ 真的发一条密文并读回 ----------
    final body = _marker('msg');
    final sent = await chat.createPost(
      channelId: encId,
      message: e2ee.encryptMessage(encId, body),
      connId: container.read(chatSessionControllerProvider).connId ?? '',
    );
    final sentPost = PostDto.fromJson(
        Map<String, dynamic>.from(sent['post'] as Map? ?? sent));
    final back = await chat.listPosts(channelId: encId, prevCount: 10);
    final mine = back
        .map((j) => PostDto.fromJson(Map<String, dynamic>.from(j)))
        .where((p) => p.postId == sentPost.postId)
        .toList();
    expect(mine, hasLength(1), reason: '刚发的那条要能读回来');
    expect(e2ee.tryDecryptMessage(encId, mine.single.message), body,
        reason: '读回来的密文要能解出原文 —— 密钥分发正确');
    debugPrint('[p6c] 密文往返 ✓（post #${sentPost.postId}）');

    // ---------- ④ 换"设备"：只靠服务端密钥恢复 ----------
    final other = ProviderContainer();
    addTearDown(() {
      try {
        other.dispose();
      } catch (_) {}
    });
    final fresh = E2eeService(other.read(chatStoreProvider));
    await fresh.adoptServerIdentity(e2ee.identity!);
    await fresh.unlock(_passcode);
    final freshDto = (await chat.listChannelsByIds([encId])).single;
    expect(fresh.loadChannelKey(encId, freshDto.channelKeyEnc), isTrue);
    expect(fresh.tryDecryptMessage(encId, mine.single.message), body,
        reason: '新设备光凭服务端数据也要能读');
    debugPrint('[p6c] 模拟新设备恢复密钥后解密 ✓');

    // ---------- ⑤ 收尾：退出频道 ----------
    await chat.disjoinNamedChannel(encId);
    await chat.disjoinNamedChannel(plainId);
    final after = await chat.listChannelsByIds([plainId, encId]);
    debugPrint('[p6c] 退出后还剩 ${after.length} 个（应为 0）');
    expect(after, isEmpty);
    debugPrint('[p6c] 清理完成 ✓');
  });
}
