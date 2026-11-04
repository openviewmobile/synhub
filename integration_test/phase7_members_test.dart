// Phase 7 真机验收：成员列表 / 邀请 / 踢人 / 权限表（ACL）。
//
//   flutter test integration_test/phase7_members_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_E2EE_PASSCODE=…
//
// 真机上做四件事：
//   ① 拉真 `SYNO.Chat.Misc acl` → 权限表落地（guest_manage=false 这种真值也要认）
//   ② 自建私有频道 → 邀请 demo(#4) → 服务端 `Channel.Member/get` 要看到 [14,4]
//   ③ 踢掉 #4 → 服务端成员表回到 [14]
//   ④ 自建**加密**频道 → 邀请 #4（逐人封一份频道密钥）→ 服务端不该把 #4 标 broken
//      （这条是真·密钥分发正确性的服务端侧证据）
//   ⑤ 成员页 UI：拿真数据渲染出来，能看到成员名字
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/settings/acl.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/channel_members_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
/// 验收用的 E2EE 口令。
///
/// 默认值与 `phase7_test.dart` / `phase8_test.dart` / `phase6_channel_create_test.dart`
/// **保持一致**：服务端那份 `key_pair` 就是用这个口令加密的。
/// 套件脚本（`tool/device_feature_suite.sh`）只传 QC/ACCOUNT/PASSWORD，**不传**
/// 这个 define ⇒ 原来 `String.fromEnvironment` 没给默认值时 `_passcode` 恒为空串，
/// `E2eeService.unlock('')` 必然抛 `SodiumException`。真机红灯的真因是
/// **少了一个 dart-define**，不是本机身份/Keystore 坏了。仍可用 `--dart-define` 覆盖。
const _passcode = String.fromEnvironment(
  'SYNO_E2EE_PASSCODE',
  defaultValue: 'flt-e2ee-pass',
);
const _invitee = 4;

String _marker(String kind) =>
    'flt-p7m-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 7 真机：成员列表 / 邀请 / 踢人 / ACL', (tester) async {
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
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    final myId = container.read(chatSessionControllerProvider).myUserId;
    debugPrint('[p7m] 我=#$myId 实时='
        '${container.read(chatSessionControllerProvider).realtime}');

    // ---------- ① 真权限表 ----------
    for (var i = 0; i < 30; i++) {
      if (container.read(myAclProvider).isNotEmpty) break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
    }
    final acl = container.read(myAclProvider);
    debugPrint('[p7m] ① 服务端 ACL（${acl.length} 条）：$acl');
    expect(acl, isNotEmpty, reason: '真 NAS 上 SYNO.Chat.Misc acl 要能拿到');
    expect(acl['channel_invite'], isTrue);
    expect(acl['channel_kick'], isTrue);
    expect(acl.containsKey('guest_manage'), isTrue,
        reason: 'false 的规则也要落进来（不能只看 true 的）');

    // ---------- ② 私有频道：邀请 ----------
    final create = container.read(channelCreateControllerProvider);
    final e2ee = container.read(e2eeServiceProvider);
    await ctrl.refresh();
    if (e2ee.identity == null) {
      final mine = await chat.myUser();
      if (mine != null && mine.publicKey.isNotEmpty) {
        await e2ee.adoptServerIdentity(E2eeIdentity(
            publicKey: mine.publicKey, privateKeyEnc: mine.privateKeyEnc));
      }
    }
    try {
      await e2ee.unlock(_passcode);
    } catch (e) {
      debugPrint('[p7m] 口令解不开私钥（$e）—— 加密频道仍可建，但读不回密文');
    }

    final plain = await create.create(
      name: _marker('plain'),
      purpose: 'Phase 7 成员/邀请/踢人 真机验收',
      type: 'private',
    );
    final plainId = plain.channelId;
    expect(plainId, greaterThan(0));
    var members = await chat.listChannelMembers(plainId);
    debugPrint('[p7m] ② 新建 #$plainId 成员=${members.userIds}');
    expect(members.userIds, contains(myId));

    final invited = await ctrl.inviteMembers(plainId, const [_invitee]);
    debugPrint('[p7m] ② 邀请 #$_invitee = $invited');
    expect(invited, isTrue);
    members = await chat.listChannelMembers(plainId);
    debugPrint('[p7m] ② 邀请后服务端成员=${members.userIds}');
    expect(members.userIds, containsAll([myId, _invitee]));
    // 本地也要跟上（syncChannelMembers 写回）
    final localCh = (await container.read(chatStoreProvider).allChannels())
        .firstWhere((c) => c.channelId == plainId);
    debugPrint('[p7m] ② 本地成员=${localCh.members}');
    expect(localCh.members, contains(_invitee));

    // ---------- ③ 踢人 ----------
    final kicked = await ctrl.kickMembers(plainId, const [_invitee]);
    debugPrint('[p7m] ③ 踢 #$_invitee = $kicked');
    expect(kicked, isTrue);
    members = await chat.listChannelMembers(plainId);
    debugPrint('[p7m] ③ 踢后服务端成员=${members.userIds}');
    expect(members.userIds, isNot(contains(_invitee)));

    // ---------- ④ 加密频道：邀请要真的把密钥封过去 ----------
    final encName = _marker('enc');
    final enc = await create.create(
      name: encName,
      purpose: 'Phase 7 成员/密钥分发 真机验收',
      type: 'private',
      encrypted: true,
    );
    final encId = enc.channelId;
    expect(encId, greaterThan(0));
    // 建频道时没勾人，这里手动邀请 #4 —— 走的是成员页同一条链路
    final encInvited = await ctrl.inviteMembers(encId, const [_invitee]);
    debugPrint('[p7m] ④ 加密频道 #$encId 邀请 #$_invitee = $encInvited');
    expect(encInvited, isTrue);
    final encMembers = await chat.listChannelMembers(encId);
    debugPrint('[p7m] ④ 加密频道成员=${encMembers.userIds} '
        'broken=${encMembers.brokenUserIds}');
    expect(encMembers.userIds, containsAll([myId, _invitee]));
    expect(encMembers.brokenUserIds, isNot(contains(_invitee)),
        reason: '我们给他封了频道密钥，服务端不该把他标 broken');

    // 我自己仍然能解开这个频道（密钥没被搞坏）
    final encDto = (await chat.listChannelsByIds([encId])).single;
    final reopened = E2eeService(container.read(chatStoreProvider));
    await reopened.adoptServerIdentity(e2ee.identity!);
    await reopened.unlock(_passcode);
    expect(reopened.loadChannelKey(encId, encDto.channelKeyEnc), isTrue,
        reason: '服务端存的 channel_key_enc 仍要用我的私钥能解开');

    // ---------- ⑤ 成员页 UI 用真数据渲染 ----------
    await ctrl.syncChannelMembers(plainId);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ChannelMembersPage(channelId: plainId),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('成员 ('), findsOneWidget);
    debugPrint('[p7m] ⑤ 成员页渲染 ✓ 标题=${tester
        .widgetList<Text>(find.textContaining('成员 ('))
        .map((t) => t.data)
        .toList()}');

    // ---------- ⑥ 收尾 ----------
    for (final id in [plainId, encId]) {
      try {
        await chat.disjoinNamedChannel(id);
        debugPrint('[p7m] ⑥ 已退出 #$id');
      } catch (e) {
        debugPrint('[p7m] ⑥ 退出 #$id 失败：$e');
      }
    }
    debugPrint('[p7m] 完成 ✓');
  });
}
