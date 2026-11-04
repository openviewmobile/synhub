// Phase 3 真机验收：看得到、发得出、收得到、已读能清。
//
//   flutter test integration_test/phase3_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=demo_admin-qq \
//     --dart-define=SYNO_NAS_ACCOUNT=… --dart-define=SYNO_NAS_PASSWORD=… \
//     --dart-define=SYNO_LIVE_POST=true
//
// 验证的是**整条 App 链路**（Controller → Drift → UI），不是单个 API：
//   ① 打开频道：Post/list 首屏 + Channel/view 已读（unread 清零，用服务端 last_view_at）
//   ② 别的会话发消息 → 本机未读 +1 且正文被捞回来落到 drift
//   ③ 本机发消息 → 服务端确认（拿到真 post_id）→ 另一会话实时收到
//   ④ 删除 → post.delete 广播 → 本地行被清掉
//   ⑤ ChatPage 真的把消息渲染出来
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
// ⚠️ bool.fromEnvironment 只认 "true"/"false"，这里两种都接受
const _postRaw = String.fromEnvironment('SYNO_LIVE_POST');
final _doPost = _postRaw == '1' || _postRaw == 'true';

String _marker(String kind) =>
    'flt-$kind-${DateTime.now().millisecondsSinceEpoch}';

Future<void> _deleteByMarker(ChatApi chat, int channelId, String marker) async {
  try {
    final posts = await chat.listPosts(channelId: channelId, prevCount: 50);
    for (final p in posts) {
      if ('${p['message']}'.contains(marker)) {
        await chat.deletePost((p['post_id'] as num).toInt());
      }
    }
  } catch (_) {}
}

/// 扫掉历史遗留的 flt- 测试消息（只删我们自己造的）
Future<void> _sweep(ChatApi chat, int channelId) async {
  try {
    final posts = await chat.listPosts(channelId: channelId, prevCount: 50);
    for (final p in posts) {
      final msg = '${p['message']}';
      if (msg.startsWith('flt-')) {
        await chat.deletePost((p['post_id'] as num).toInt());
      }
    }
  } catch (_) {}
}

Future<void> _waitFor(
  Future<bool> Function() cond, {
  Duration timeout = const Duration(seconds: 20),
  String what = '条件',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  fail('等待超时：$what');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 3 真机：读消息 / 收消息 / 发消息 / 已读 / 渲染', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    // ---- 会话 A：被验证的 App 本体 ----
    final connA = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    final sessionA = await connA.api.login(
        account: _account, password: _password, session: 'Chat');
    expect(sessionA.sid, isNotEmpty);
    final chatA = ChatApi(connA.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(connA);
    var sync = container.read(chatSessionControllerProvider);
    debugPrint('[p3] 同步完成 phase=${sync.phase} connId=${sync.connId} '
        'myUserId=${sync.myUserId}');
    expect(sync.phase, ChatSyncPhase.ready);

    final channels = await container.read(chatStoreProvider).allChannels();
    final target = channels.firstWhere((c) => !c.encrypted && c.isJoined,
        orElse: () => channels.first);
    addTearDown(() => _sweep(chatA, target.channelId));
    debugPrint('[p3] 目标频道 #${target.channelId} 未读=${target.unread}');

    if (!_doPost) {
      // ---------- 不带 SYNO_LIVE_POST：只验证"读" ----------
      await ctrl.loadPosts(target.channelId);
      final posts = await container
          .read(chatStoreProvider)
          .postsForChannel(target.channelId);
      debugPrint('[p3] 首屏拉到 ${posts.length} 条消息');
      final n = await ctrl.markRead(target.channelId);
      debugPrint('[p3] markRead → $n');
      final after = (await container.read(chatStoreProvider).allChannels())
          .firstWhere((c) => c.channelId == target.channelId);
      expect(after.unread, 0);
      // 页面能渲染
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: ChatPage(channelId: target.channelId)),
      ));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TextField), findsOneWidget);
      return;
    }

    // ---- 会话 B：另一个客户端 ----
    final connB = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    final sessionB = await connB.api.login(
        account: _account, password: _password, session: 'Chat');
    final chatB = ChatApi(connB.api);
    final socketB = ChatSocket(
      baseUrl: connB.endpoint.baseUrl,
      sid: sessionB.sid,
      synotoken: sessionB.synotoken,
    );
    addTearDown(() async {
      socketB.dispose();
      await connB.api.logout();
      await connB.api.transport.close();
    });
    await socketB.connect();
    await socketB.waitReady(timeout: const Duration(seconds: 25));
    final bEvents = <ChatSocketEvent>[];
    socketB.events.listen(bEvents.add);

    // ---- ① 首屏 + 已读 ----
    await ctrl.loadPosts(target.channelId);
    final firstPage = await container
        .read(chatStoreProvider)
        .postsForChannel(target.channelId);
    debugPrint('[p3] 首屏 ${firstPage.length} 条（含历史）');
    await ctrl.markRead(target.channelId);
    var ch = (await container.read(chatStoreProvider).allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    expect(ch.unread, 0);
    expect(ch.lastViewAt, greaterThan(0));
    debugPrint('[p3] 已读完成 lastViewAt=${ch.lastViewAt}');

    // ---- ② 别人发消息 → 未读 +1 且正文捞回来 ----
    final incoming = _marker('in');
    final inPost = await chatB.createPost(
      channelId: target.channelId,
      message: incoming,
      connId: socketB.connId!,
    );
    final inId = (inPost['post_id'] as num).toInt();
    debugPrint('[p3] B 发出 $incoming (post_id=$inId)');

    await _waitFor(() async {
      final list = await container
          .read(chatStoreProvider)
          .postsForChannel(target.channelId);
      return list.any((p) => p.message == incoming);
    }, what: '把 B 的消息正文捞回本地');

    // ⚠️ 会话 B 用的是**同一个账号**（user 14），所以这条事件带的是 creator_id=14。
    // 原 App 的语义是"自己的消息不算未读"（哪怕是另一台设备发的），我们照做：
    // 这里应当**保持 0**。
    ch = (await container.read(chatStoreProvider).allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    debugPrint('[p3] 同账号另一设备发来的消息 → 未读=${ch.unread}（应为 0）');
    expect(ch.unread, 0, reason: '同账号发的消息不该算未读');

    // 真正"别人发的"要换个 creator_id。手上只有一个测试账号，
    // 所以这里**注入**一条与实测形状完全一致的事件（只有 creator_id 换成 user 4），
    // 用真实 post_id 验证"未读 +1"这条分支。
    final before = ch.unread;
    await ctrl.handleEvent(ChatSocketEvent('client.post.create', {
      'user_id': 4,
      'channel_id': target.channelId,
      'data': {
        'creator_id': 4,
        'post_id': inId,
        'thread_id': 0,
        'create_at': DateTime.now().millisecondsSinceEpoch,
      },
    }));
    ch = (await container.read(chatStoreProvider).allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    debugPrint('[p3] 注入"别人发的"事件 → 未读=$before → ${ch.unread}');
    expect(ch.unread, before + 1, reason: '别人发的消息应当让未读 +1');
    await ctrl.markRead(target.channelId);

    // ---- ③ 自己发消息 ----
    final outgoing = _marker('out');
    final ok = await ctrl.sendMessage(target.channelId, outgoing);
    expect(ok, isTrue, reason: '发送应当成功');

    final mine = (await container
            .read(chatStoreProvider)
            .postsForChannel(target.channelId))
        .firstWhere((p) => p.message == outgoing);
    debugPrint('[p3] 自己发的消息落库 post_id=${mine.postId} state=${mine.state}');
    expect(mine.postId, greaterThan(0), reason: '要拿到服务端真实 post_id');
    expect(mine.state, 0, reason: '已被服务端确认');
    expect(mine.tmpPostId, greaterThan(0), reason: '乐观发送用过的临时 id');

    // 顺手探一下服务端到底怎么回带 mobile_token（数字还是带引号的字符串）
    // 服务端对连续发送有频率限制（`CHAT_ERR_SEND_TOO_FREQUENTLY 411`），
    // 上一条刚发完要歇一下，否则这里必挂 —— 不是 App 的问题。
    await Future<void>.delayed(const Duration(seconds: 3));
    final tokenProbe = await chatA.createPost(
      channelId: target.channelId,
      message: _marker('tok'),
      connId: sync.connId!,
      mobileToken: '12345',
    );
    debugPrint('[p3] mobile_token 回带 = '
        '${tokenProbe['mobile_token']} (${tokenProbe['mobile_token'].runtimeType})');
    await chatA.deletePost((tokenProbe['post_id'] as num).toInt());

    // B 应当实时收到
    await _waitFor(
      () async => bEvents.any((e) =>
          e.event == 'client.post.create' &&
          (e.asMap?['data'] as Map?)?['post_id'] == mine.postId),
      what: 'B 实时收到 A 发的消息',
    );
    debugPrint('[p3] B 实时收到了 A 的消息 ✓');

    // 服务端确实有这条（不是只在本地）
    final serverPosts = await chatA.listPosts(
      channelId: target.channelId,
      prevCount: 10,
      has: const ['thread'],
    );
    expect(serverPosts.any((p) => p['post_id'] == mine.postId), isTrue,
        reason: 'Post/list 里应当能查到刚发的消息');

    // ---- ④ 删除 → 广播 → 本地清掉 ----
    await chatA.deletePost(mine.postId);
    await _waitFor(() async {
      final list = await container
          .read(chatStoreProvider)
          .postsForChannel(target.channelId);
      return !list.any((p) => p.postId == mine.postId);
    }, what: '本地删除自己的消息');

    // 顺手清掉对方那条，别在 NAS 上留垃圾
    await _deleteByMarker(chatA, target.channelId, incoming);

    // ---- ⑤ ChatPage 渲染真实消息 ----
    final keep = _marker('render');
    await ctrl.sendMessage(target.channelId, keep);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ChatPage(channelId: target.channelId)),
    ));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text(keep), findsOneWidget, reason: 'UI 应当渲染出刚发的消息');
    debugPrint('[p3] ChatPage 渲染出消息 ✓');
    await _deleteByMarker(chatA, target.channelId, keep);

    // 未读在页面停留期间应保持 0（在看的频道不该涨未读）
    ch = (await container.read(chatStoreProvider).allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    debugPrint('[p3] 结束时未读=${ch.unread}');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
