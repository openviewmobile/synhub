// Phase 7 真机验收：broken 成员 + 密钥更新广播 + 修复闭环。
//
//   flutter test integration_test/phase7_broken_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_E2EE_PASSCODE=…
//
// 这条用例做的是**真的让服务端把我标成 broken、再从 App 里修回来**：
//   ① 用第三条连接（B）调 `User/update_key`，As 服务端的行为是：给同账号的其它
//      会话广播 `client.user.updatekey` + `client.channel.brokenuser`，
//      并在这个频道里发一条 `user.broken` 系统消息；
//   ② App 自己那条连接（A）收到广播后，**本地** `broken_users` 要出现我；
//   ③ 从 App 调「重新上传我的频道密钥」修复 → 服务端 `broken_users` 回到空；
//   ④ 收尾：尽量删掉测试产生的系统消息。
//
// 真机实测的载荷（`tool/flt_key_probe.dart` 抓的，见 docs/phase7-protocol.md）：
//   client.user.updatekey {channels:[{channel_id, channel_key_enc}], conn_id,
//                          private_key_enc, public_key, user_id}
//   client.channel.brokenuser {channel_id, user_id}
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/data/remote/socket/socket_events.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/settings/e2ee_controller.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';

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
    'flt-p7b-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

Future<void> _sleep(WidgetTester tester, int ms) =>
    tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 7 真机：broken 广播 → 本地标记 → 修复 → 服务端清空',
      (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    // ---------- 登录（App 用这条连接） ----------
    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    await container.read(chatSessionControllerProvider.notifier).start(conn);
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    final store = container.read(chatStoreProvider);
    final sync = container.read(chatSessionControllerProvider);
    final myId = sync.myUserId;
    debugPrint('[p7b] 我=#$myId 实时=${sync.realtime}');
    expect(sync.realtime, isTrue);

    // ---------- 另外两条会话：B 触发 update_key，C 抓广播 ----------
    // （触发者自己收不到广播，所以要专门开一条来断言载荷形状）
    //
    // ⚠️ 别再走一遍 QuickConnect：QC 解析偶尔要 30s+（真踩过超时），直接在**同一个
    // 传输**上再登录两次拿两条 sid 就够了 —— 服务端支持同账号多会话。
    debugPrint('[p7b] 端点=${conn.endpoint.baseUrl}');
    final sessionB = await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final chatB = ChatApi(conn.api);
    final socketB = ChatSocket(
      baseUrl: conn.endpoint.baseUrl,
      sid: sessionB.sid,
      synotoken: sessionB.synotoken,
    );
    final bEvents = <ChatSocketEvent>[];
    final sub = socketB.events.listen(bEvents.add);
    addTearDown(() async {
      await sub.cancel();
      socketB.dispose();
    });
    await socketB.connect();
    await socketB.waitReady(timeout: const Duration(seconds: 25));

    final sessionC = await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final socketC = ChatSocket(
      baseUrl: conn.endpoint.baseUrl,
      sid: sessionC.sid,
      synotoken: sessionC.synotoken,
    );
    final cEvents = <ChatSocketEvent>[];
    final subC = socketC.events.listen(cEvents.add);
    addTearDown(() async {
      await subC.cancel();
      socketC.dispose();
    });
    await socketC.connect();
    await socketC.waitReady(timeout: const Duration(seconds: 25));
    debugPrint('[p7b] B(触发)=${socketB.connId} C(监听)=${socketC.connId}');

    // ---------- 自建一个加密频道当靶子 ----------
    //
    // ⚠️ 别拿 #49 那种"历史遗留"频道：它的 channel_key_enc 可能是上一代密钥对封的，
    // 本机根本解不开（真机踩过：keyState=missing）。自己建一个，密钥一定对得上。
    final create = container.read(channelCreateControllerProvider);
    final e2eeSvc = container.read(e2eeServiceProvider);
    await ctrl.refresh();
    if (e2eeSvc.identity == null) {
      final mine0 = await ctrl.chatApi!.myUser();
      if (mine0 != null && mine0.publicKey.isNotEmpty) {
        await e2eeSvc.adoptServerIdentity(E2eeIdentity(
            publicKey: mine0.publicKey, privateKeyEnc: mine0.privateKeyEnc));
      }
    }
    final encName = _marker('enc');
    final enc = await create.create(
      name: encName,
      purpose: 'Phase 7 broken/rescue 真机验收',
      type: 'private',
      encrypted: true,
      memberIds: const [_invitee],
    );
    final cid = enc.channelId;
    expect(cid, greaterThan(0));
    // 发两条带标记的密文，收尾时删掉（验证 rescue 之后还能正常加解密）
    final sentPostIds = <int>[];
    // 自己建完要重新拉一次列表，本地才有这条（控制器代码路径和用户操作一致）
    await ctrl.refresh();
    await ctrl.syncChannelMembers(cid);
    var target = (await store.allChannels())
        .where((c) => c.channelId == cid)
        .firstOrNull ??
        ChannelDto(channelId: cid, encrypted: true, isJoined: true);
    debugPrint('[p7b] 靶子加密频道 #$cid broken=${target.brokenUsers}');
    // 建完先确认本机能解开这个频道（否则后面 rescue 是假修复）
    await container.read(e2eeControllerProvider.notifier).refreshChannelKeys();
    target = (await store.allChannels()).firstWhere((c) => c.channelId == cid);
    final st0 = container.read(e2eeControllerProvider.notifier).keyStateOf(target);
    debugPrint('[p7b] 靶子频道本机密钥状态=$st0');
    expect(st0.name, 'ready', reason: '自己刚建的加密频道必须能解开');
    final members0 = await ctrl.chatApi!.listChannelMembers(cid);
    expect(members0.brokenUserIds, isEmpty,
        reason: '刚分发完密钥，服务端不该有 broken 成员');

    // 先把服务端上的密钥对读出来（原样重传 → 不改身份，但会触发 broken 判定）
    final me = await ctrl.chatApi!.myUser();
    expect(me?.publicKey.isNotEmpty, isTrue, reason: '服务端上要有我的公钥');
    debugPrint('[p7b] 服务端公钥长度=${me!.publicKey.length}');

    // 记录现有 broken 集合（修复后要回到这个状态）
    final beforeBroken = Set<int>.from(target.brokenUsers);

    // ---------- ① 触发 update_key ----------
    //
    // ⚠️ 先**锁定**本机 E2EE：解锁状态下我们手里有能用的频道密钥，控制器会认为
    // "自己没坏"而忽略给自己挂 ⚠（真机实测服务端确实会把我标成 broken，但那时
    // 我们明明能解开）。锁定后再触发，才能验证"收到广播 → 落库标 ⚠"这条路。
    e2eeSvc.lock();
    debugPrint('[p7b] ① 已锁定本机 E2EE，开始触发 update_key');
    await chatB.updateKey(
      connId: socketB.connId ?? '',
      publicKey: me.publicKey,
      privateKeyEnc: me.privateKeyEnc,
    );
    for (var i = 0; i < 20; i++) {
      await _sleep(tester, 250);
      if (cEvents.any((e) => e.event == SocketEvent.clientUserUpdateKey)) break;
    }
    final uk = cEvents
        .where((e) => e.event == SocketEvent.clientUserUpdateKey)
        .firstOrNull;
    debugPrint('[p7b] ① 真广播 client.user.updatekey=${uk?.payload}');
    expect(uk, isNotNull, reason: '服务端应把 updatekey 广播给同账号其它会话');
    final ukMap = Map<String, dynamic>.from(uk!.payload as Map);
    expect((ukMap['user_id'] as num).toInt(), myId);
    expect('${ukMap['public_key']}', isNotEmpty);
    expect(ukMap['channels'], isA<List>());

    // ---------- ② App 那条连接收到 brokenuser → 本地标记 ----------
    var markedLocally = false;
    for (var i = 0; i < 24; i++) {
      await _sleep(tester, 250);
      final ch = (await store.allChannels())
          .where((c) => c.channelId == cid)
          .firstOrNull;
      if (ch != null && ch.brokenUsers.contains(myId)) {
        markedLocally = true;
        break;
      }
    }
    var ch = (await store.allChannels()).firstWhere((c) => c.channelId == cid);
    debugPrint('[p7b] ② 本地 broken_users=${ch.brokenUsers} '
        '(收到 brokenuser 广播=$markedLocally)');
    // 列表刷新不能把它冲掉（真机 `Channel/list` 里这个字段一直是空的）
    await ctrl.refresh();
    ch = (await store.allChannels()).firstWhere((c) => c.channelId == cid);
    debugPrint('[p7b] ② 刷新后本地 broken_users=${ch.brokenUsers}');
    if (markedLocally) {
      expect(ch.brokenUsers.contains(myId), isTrue,
          reason: 'Channel/list 不带 broken_users，刷新后不能被清掉');
    }
    // 有些服务端版本只在"密钥真的变了"时才标 broken；没标到也不算错
    if (!markedLocally) {
      debugPrint('[p7b] ② 服务端这次没有把我标 broken（重传同密钥可能不改状态）');
    }

    // 服务端侧的 broken 状态（权威来源是 `Channel.Member/get`：
    // `Channel/list` 里那个字段真机实测一直是空的）
    var remoteBroken = <int>[];
    for (var i = 0; i < 12; i++) {
      final m = await ctrl.chatApi!.listChannelMembers(cid);
      remoteBroken = m.brokenUserIds;
      if (remoteBroken.isNotEmpty) break;
      await _sleep(tester, 500);
    }
    debugPrint('[p7b] ② 服务端 Channel.Member/get broken_user_ids=$remoteBroken');
    expect(remoteBroken, contains(myId),
        reason: '重传密钥后服务端应把我标成这台频道里的 broken 成员');
    // ⚠️ 服务端**不一定**广播 `client.channel.brokenuser`：真机实测过两次
    // 同样的触发，一次有广播、一次只有 `client.user.updatekey`（服务端那边
    // `Channel.Member/get` 已经把我标成 broken 了，只是没推）。这是服务端的
    // 自由裁量，不是 App 的问题，所以这里不能硬要求广播到达 —— 要求的是
    // "要么广播让本地立刻标上，要么走权威同步这条路也认得出来"。
    if (markedLocally) {
      debugPrint('[p7b] ② 广播路径已覆盖：本地 broken 由 brokenuser 事件落库');
    } else {
      debugPrint('[p7b] ② 服务端这次没广播 brokenuser，改验权威同步路径');
    }
    expect(markedLocally || remoteBroken.contains(myId), isTrue,
        reason: '要么收到 brokenuser 广播落库，要么服务端权威状态确实标了 broken');
    // 顺带验证"从服务端同步"这条路也认得出来
    await ctrl.syncChannelMembers(cid);
    target = (await store.allChannels()).firstWhere((c) => c.channelId == cid);
    expect(target.brokenUsers, contains(myId),
        reason: 'syncChannelMembers 要把服务端的 broken 结果写进本地');

    // ---------- ③ 修复 ----------
    final e2ee = container.read(e2eeControllerProvider.notifier);
    final svc = container.read(e2eeServiceProvider);
    if (!svc.isConfigured) {
      debugPrint('[p7b] ③ 本机没有 E2EE 身份，采纳服务端那份');
      await svc.adoptServerIdentity(
        E2eeIdentity(publicKey: me.publicKey, privateKeyEnc: me.privateKeyEnc),
      );
    }
    final unlocked = await e2ee.unlock(_passcode);
    expect(unlocked, isTrue, reason: '口令应能解开本机私钥');
    await e2ee.refreshChannelKeys();
    final ready = e2ee.keyStateOf(
        (await store.allChannels()).firstWhere((c) => c.channelId == cid));
    debugPrint('[p7b] ③ 本机频道密钥状态=$ready');
    expect(ready.name, 'ready', reason: '本机应能解开这个加密频道');

    // ③a 走一遍**真·rescue**（原版成员列表点 ⚠ 就是这条链路）：
    //     把频道密钥重新封给我的公钥 → `Channel/rescue` → 服务端广播
    //     `channel.rescue`，App 自己那条连接收到后要把 broken 标记摘掉。
    final cBefore = cEvents.length;
    final rescued = await e2ee.rescueChannel(channelId: cid, userId: myId);
    debugPrint('[p7b] ③a Channel/rescue=$rescued');
    expect(rescued, isTrue);
    // ⚠️ `channel.rescue` 的广播对象是**被救的那个人**，而这里救的是我自己 ——
    // 服务端不会把广播发回发起方自己（同 `client.user.updatekey` 的 origin 排除）。
    // 用单账号没法真机抓到这条广播，所以只做"等一会儿、抓不到也不算错"，
    // 载荷形状由离线用例（test/channel_broadcast_test.dart）和反编译保证。
    ChatSocketEvent? rescueEvent;
    for (var i = 0; i < 8; i++) {
      await _sleep(tester, 250);
      rescueEvent = cEvents
          .skip(cBefore)
          .where((e) => e.event == BroadcastType.channelRescue)
          .firstOrNull;
      if (rescueEvent != null) break;
    }
    if (rescueEvent == null) {
      debugPrint('[p7b] ③a 没抓到 channel.rescue 广播（救自己时服务端不回发给发起方，'
          '符合预期）');
    } else {
      debugPrint('[p7b] ③a 真广播 channel.rescue=${rescueEvent.payload}');
      final rMap = Map<String, dynamic>.from(rescueEvent.payload as Map);
      expect((rMap['channel_id'] as num).toInt(), cid);
      expect((rMap['user_id'] as num).toInt(), myId);
      expect('${rMap['channel_key_enc'] ?? ''}', isNotEmpty);
    }

    // ③b App 自己那条连接收到 rescue → 本地摘掉我的标记
    var localCleared = false;
    for (var i = 0; i < 12; i++) {
      await ctrl.refresh();
      ch = (await store.allChannels()).firstWhere((c) => c.channelId == cid);
      if (!ch.brokenUsers.contains(myId)) {
        localCleared = true;
        break;
      }
      await _sleep(tester, 500);
    }
    // 服务端权威结果也要清空
    var remoteAfter = <int>[myId];
    for (var i = 0; i < 16; i++) {
      remoteAfter = (await ctrl.chatApi!.listChannelMembers(cid)).brokenUserIds;
      if (!remoteAfter.contains(myId)) break;
      await _sleep(tester, 500);
    }
    debugPrint('[p7b] ③b 服务端 broken_user_ids=$remoteAfter');
    expect(remoteAfter, isNot(contains(myId)), reason: 'rescue 后服务端应清掉我');
    debugPrint('[p7b] ③b 本地 broken_users=${ch.brokenUsers} 已清=$localCleared');
    expect(localCleared, isTrue, reason: 'rescue 后本机不该再给自己挂 ⚠');
    expect(ch.brokenUsers.toSet().difference(beforeBroken), isEmpty,
        reason: '本地 broken 集合不该比之前多');

    // ③c 再走一遍"重新上传我的频道密钥"（换设备/服务端副本丢了时的正路），
    //     确认它返回成功、本地也不留标记
    final ok = await e2ee.reuploadMyChannelKeys();
    debugPrint('[p7b] ③c 重新上传频道密钥=$ok');
    expect(ok, isTrue);
    ch = (await store.allChannels()).firstWhere((c) => c.channelId == cid);
    expect(ch.brokenUsers.contains(myId), isFalse);

    // ③d 修复后还能真的加解密（不是"标记清了但其实解不开"）
    final body = _marker('msg');
    final sent = await ctrl.chatApi!.createPost(
      channelId: cid,
      message: e2eeSvc.encryptMessage(cid, body),
      connId: container.read(chatSessionControllerProvider).connId ?? '',
    );
    final sentPost = PostDto.fromJson(
        Map<String, dynamic>.from(sent['post'] as Map? ?? sent));
    sentPostIds.add(sentPost.postId);
    var decrypted = '';
    for (var i = 0; i < 12; i++) {
      final back = await ctrl.chatApi!.listPosts(channelId: cid, prevCount: 10);
      final minePost = back
          .map((j) => PostDto.fromJson(Map<String, dynamic>.from(j)))
          .where((p) => p.postId == sentPost.postId)
          .firstOrNull;
      if (minePost != null) {
        decrypted = e2eeSvc.tryDecryptMessage(cid, minePost.message) ?? '';
        if (decrypted == body) break;
      }
      await _sleep(tester, 500);
    }
    debugPrint('[p7b] ③d 修复后密文往返=${decrypted == body}');
    expect(decrypted, body, reason: 'rescue/重传之后本机仍要能收发密文');

    // ---------- ④ 收尾：删掉测试消息 + 退出频道 ----------
    for (final pid in sentPostIds) {
      try {
        await ctrl.chatApi!.deletePost(pid);
        debugPrint('[p7b] ④ 删掉测试消息 #$pid');
      } catch (e) {
        debugPrint('[p7b] ④ 测试消息 #$pid 删不掉：$e');
      }
    }
    try {
      await ctrl.chatApi!.disjoinNamedChannel(cid);
      debugPrint('[p7b] ④ 已退出频道 #$cid');
    } catch (e) {
      debugPrint('[p7b] ④ 退出频道失败：$e');
    }

    try {
      final posts = await ctrl.chatApi!
          .listPosts(channelId: cid, prevCount: 10);
      for (final p in posts) {
        final sp = p['system_props'];
        final isBroken = sp is Map && '${sp['event']}' == 'user.broken';
        final pid = (p['post_id'] as num?)?.toInt() ?? 0;
        if (!isBroken || pid == 0) continue;
        try {
          await ctrl.chatApi!.deletePost(pid);
          debugPrint('[p7b] ④ 删掉系统消息 #$pid');
        } catch (e) {
          debugPrint('[p7b] ④ 系统消息 #$pid 删不掉（正常，非管理员）：$e');
        }
      }
    } catch (e) {
      debugPrint('[p7b] ④ 收尾查询失败（忽略）：$e');
    }
    debugPrint('[p7b] 完成 ✓');
  });
}
