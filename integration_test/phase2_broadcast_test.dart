// Phase 2/4 真机验收：频道列表一致性广播 + 话题订阅。
//
//   flutter test integration_test/phase2_broadcast_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_LIVE_POST=true
//
// ① `post.subscribe` **真服务端往返**：调 `Post.Subscribe/create` 后，
//    服务端的 `client.broadcast: post.subscribe` 会到达实时通道 → 落到
//    `channel.subscribes`。这是这批事件里唯一能被真服务端触发的；
// ② 其余广播（`channel.view` / `channel.hide` / `channel.show` /
//    `user.delete`）喂真形状载荷，验证落库；`hide_global`/`unhide_global`
//    是**顶层事件**（服务端 service.js 直接 emit 事件名），单独喂顶层形状 —— 一个账号
//    没法在 NAS 上制造"另一台设备/另一个用户"的动作，只能这样验；
// ③ 收尾：退订 + 删除测试消息。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/data/remote/socket/socket_events.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/thread_page.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _postRaw = String.fromEnvironment('SYNO_LIVE_POST');
final _doPost = _postRaw == '1' || _postRaw == 'true';

String _marker(String kind) =>
    'flt-p2b-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

Map<String, dynamic> _event(String type, Map<String, dynamic> data) =>
    {'type': type, 'data': data};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 2 真机：频道广播一致性 + 话题订阅', (tester) async {
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
    final store = container.read(chatStoreProvider);
    final sync = container.read(chatSessionControllerProvider);
    debugPrint('[p2b] 我=#${sync.myUserId} 实时=${sync.realtime}');
    expect(sync.realtime, isTrue);

    var channels = await store.allChannels();
    if (channels.isEmpty) {
      await ctrl.refresh();
      channels = await store.allChannels();
    }
    final target = channels.firstWhere(
      (c) => !c.encrypted && c.channelId > 0,
      orElse: () => channels.first,
    );
    debugPrint('[p2b] 目标频道 #${target.channelId} (${target.type})');

    // ---------- ① 真服务端：post.subscribe 广播 ----------
    int? probePostId;
    if (_doPost) {
      final post = await chat.createPost(
        channelId: target.channelId,
        message: _marker('sub'),
        connId: sync.connId!,
      );
      probePostId = (post['post_id'] as num?)?.toInt();
      debugPrint('[p2b] 造了一条消息 post=#$probePostId');
    }
    if (probePostId == null) {
      final posts = await chat.listPosts(channelId: target.channelId, prevCount: 1);
      probePostId = posts.isEmpty
          ? null
          : (posts.first['post_id'] as num?)?.toInt();
      debugPrint('[p2b] 用已有消息 post=#$probePostId');
    }
    expect(probePostId, isNotNull, reason: '要有条消息才能测订阅');

    // 订阅前状态：先清干净（这台设备上的本地库是**跨次运行**保留的，
    // 上一次跑剩的订阅、或服务端本来就有，都会让这条前置断言失败）
    var ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    if (ch.subscribes.contains(probePostId)) {
      await ctrl.setPostSubscribed(target.channelId, probePostId!, subscribed: false);
      ch = (await store.allChannels())
          .firstWhere((c) => c.channelId == target.channelId);
    }
    expect(ch.subscribes.contains(probePostId), isFalse);

    // 真 API
    final ok = await ctrl.setPostSubscribed(
      target.channelId,
      probePostId!,
      subscribed: true,
    );
    expect(ok, isTrue, reason: 'Post.Subscribe/create 应当成功');
    ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    expect(ch.subscribes, contains(probePostId),
        reason: '订阅后本地 subscribes 要包含它');
    debugPrint('[p2b] ① 订阅落库 subscribes=${ch.subscribes} ✓');

    // 服务端的广播是发给**同一个账号的其它会话**的，所以再开一条连接来听：
    // 这样能拿到真正的 `client.broadcast: post.subscribe` 载荷形状。
    final connB = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    final sessionB = await connB.api.login(
        account: _account, password: _password, session: 'Chat');
    final socketB = ChatSocket(
      baseUrl: connB.endpoint.baseUrl,
      sid: sessionB.sid,
      synotoken: sessionB.synotoken,
    );
    final events = <ChatSocketEvent>[];
    final sub = socketB.events.listen(events.add);
    addTearDown(() async {
      await sub.cancel();
      socketB.dispose();
    });
    await socketB.connect();
    await socketB.waitReady(timeout: const Duration(seconds: 25));
    debugPrint('[p2b] 第二条连接就绪（听广播用）');

    // 抓广播：**订阅状态必须有变化**服务端才广播（刚订阅过、再订阅一次没有
    // 事件 —— 探针实测），所以这里按"退订 → 订阅"两步走，两条都验。
    Future<Map<String, dynamic>?> waitFor(String type) async {
      for (var i = 0; i < 24; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)));
        final hit = events.where((e) =>
            e.event == SocketEvent.clientBroadcast &&
            e.payload is Map &&
            (e.payload as Map)['type'] == type);
        if (hit.isNotEmpty) {
          final payload = hit.last.payload as Map;
          return Map<String, dynamic>.from(payload['data'] as Map);
        }
      }
      return null;
    }

    await chat.unsubscribePost(probePostId);
    final unsubPayload = await waitFor(BroadcastType.postUnsubscribe);
    debugPrint('[p2b] ① 真广播 post.unsubscribe 载荷=$unsubPayload');
    expect(unsubPayload, isNotNull, reason: '服务端应当广播退订');
    expect((unsubPayload!['post_id'] as num).toInt(), probePostId);
    expect((unsubPayload['user_id'] as num).toInt(), sync.myUserId);
    expect((unsubPayload['channel_id'] as num).toInt(), target.channelId);
    expect(unsubPayload.containsKey('channel_order_time'), isTrue,
        reason: '原版就是拿它刷频道排序时间的');

    await chat.subscribePost(probePostId);
    final subPayload = await waitFor(BroadcastType.postSubscribe);
    debugPrint('[p2b] ① 真广播 post.subscribe 载荷=$subPayload');
    expect(subPayload, isNotNull, reason: '服务端应当广播订阅');
    expect((subPayload!['post_id'] as num).toInt(), probePostId);
    expect((subPayload['user_id'] as num).toInt(), sync.myUserId,
        reason: '订阅人是我');
    expect(subPayload['comment_count'], isNotNull,
        reason: '原版 subscribePost 会读 comment_count');

    // 退订：真 API + 本地清掉
    final ok2 = await ctrl.setPostSubscribed(
      target.channelId,
      probePostId,
      subscribed: false,
    );
    expect(ok2, isTrue);
    ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    expect(ch.subscribes.contains(probePostId), isFalse);
    debugPrint('[p2b] ① 退订清掉 ✓');

    // ---------- ② 其余广播（真形状载荷） ----------
    // channel.view：清未读 + last_view_at
    await ctrl.handleEvent(ChatSocketEvent(
      SocketEvent.clientBroadcast,
      _event(BroadcastType.channelView, {
        'channel_id': target.channelId,
        'last_view_at': 1700000000000,
        'user_id': sync.myUserId,
      }),
    ));
    ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    expect(ch.unread, 0);
    expect(ch.lastViewAt, 1700000000000);
    debugPrint('[p2b] ② channel.view 落库 ✓');

    // channel.hide → 列表里藏起来；show → 回来
    //
    // ⚠️ 先把未读清干净：原版 `Channel.hideAtSideBar()` 是"隐藏后**只要还有未读**
    // 就重新冒出来"，而真机上的 #23 可能有 comment 未读，会让断言随环境漂移。
    final hideAt = DateTime.now().millisecondsSinceEpoch;
    await ctrl.handleEvent(ChatSocketEvent(
      SocketEvent.clientBroadcast,
      _event(BroadcastType.channelHide, {
        'channel_id': target.channelId,
        'last_hide_at': hideAt,
        'user_id': sync.myUserId,
      }),
    ));
    ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    // 只断言"字段写进去了"：`hideAtSideBar()` 还取决于这个频道的 type /
    // 未读 / 通知档位（真机上 #23 有自己的状态），断言它会随环境漂移。
    // `hideAtSideBar()` 的规则由单测覆盖（test/channel_broadcast_test.dart）。
    expect(ch.lastHideAt, hideAt);
    await ctrl.handleEvent(ChatSocketEvent(
      SocketEvent.clientBroadcast,
      _event(BroadcastType.channelShow, {
        'channel_id': target.channelId,
        'user_id': sync.myUserId,
      }),
    ));
    ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    expect(ch.lastHideAt, 0);
    debugPrint('[p2b] ② channel.hide/show → last_hide_at 写/清 ✓');

    // hide_global / unhide_global —— ⚠️ **顶层事件**，不是广播。
    //
    // 2.4.7 服务端 `chat_service/service.js#onCloseChannel`：
    //   n = "client.channel.hide_global"; this.io.to(room).emit(n, e)
    // 载荷是 `{channel_id, channel_close_type}`（没有时间戳，`channel` 已 delete），
    // 原版 `ChannelGlobalHideVo` 也只解析 channel_id、处理时用当前时间。
    // （这里以前按"广播里的一种 type"喂，真机上永远收不到，本轮修正。）
    final before = DateTime.now().millisecondsSinceEpoch;
    await ctrl.handleEvent(ChatSocketEvent(
      SocketEvent.clientChannelHideGlobal,
      {
        'channel_id': target.channelId,
        'channel_close_type': 'CHANNEL_CLOSE_TYPE_HIDE_GLOBAL',
      },
    ));
    ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    expect(ch.hideGlobalAt, greaterThanOrEqualTo(before));
    expect(ch.hideAtSideBar(), isTrue);
    await ctrl.handleEvent(ChatSocketEvent(
      SocketEvent.clientChannelUnhideGlobal,
      {
        'channel_id': target.channelId,
        'channel_close_type': 'CHANNEL_CLOSE_TYPE_UNHIDE_GLOBAL',
      },
    ));
    ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    expect(ch.hideGlobalAt, 0);
    expect(ch.hideAtSideBar(), isFalse);

    // 兜底：包进 client.broadcast 也要认（老信封）
    await ctrl.handleEvent(ChatSocketEvent(
      SocketEvent.clientBroadcast,
      _event(SocketEvent.clientChannelHideGlobal, {
        'channel_id': target.channelId,
        'channel_close_type': 'CHANNEL_CLOSE_TYPE_HIDE_GLOBAL',
      }),
    ));
    ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    expect(ch.hideGlobalAt, greaterThanOrEqualTo(before));
    await ctrl.handleEvent(ChatSocketEvent(
      SocketEvent.clientChannelUnhideGlobal,
      {'channel_id': target.channelId},
    ));
    ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    expect(ch.hideGlobalAt, 0);
    debugPrint('[p2b] ② hide_global/unhide_global（顶层 + 广播兜底）✓');

    // user.delete（挑一个真人用户，改完再恢复）
    final users = await store.allUsers();
    final victim = users.where((u) => u.userId != sync.myUserId).toList();
    if (victim.isNotEmpty) {
      final id = victim.first.userId;
      await ctrl.handleEvent(ChatSocketEvent(
        SocketEvent.clientBroadcast,
        _event(BroadcastType.userDelete, {'user_id': id}),
      ));
      final after = (await store.allUsers()).firstWhere((u) => u.userId == id);
      expect(after.isDeleted, isTrue);
      expect(after.displayName.isNotEmpty, isTrue, reason: '名字要留着');
      debugPrint('[p2b] ② user.delete → #$id 标已删除（名字保留）✓');
      // 恢复：重新拉一次用户列表
      await ctrl.refresh();
    }

    // ---------- ②.5 话题页上的订阅开关（UI 真的能点） ----------
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ThreadPage(channelId: target.channelId, parentPostId: probePostId),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump(const Duration(milliseconds: 200));

    // 刚才清干净了 → 空心铃铛
    expect(find.byIcon(Icons.notifications_none), findsOneWidget,
        reason: '未订阅状态');
    await tester.tap(find.byIcon(Icons.notifications_none));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 100));
      ch = (await store.allChannels())
          .firstWhere((c) => c.channelId == target.channelId);
      if (ch.subscribes.contains(probePostId)) break;
    }
    expect(ch.subscribes, contains(probePostId), reason: 'UI 点订阅要真生效');
    expect(find.byIcon(Icons.notifications_active), findsOneWidget);
    await tester.tap(find.byIcon(Icons.notifications_active));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 100));
      ch = (await store.allChannels())
          .firstWhere((c) => c.channelId == target.channelId);
      if (!ch.subscribes.contains(probePostId)) break;
    }
    expect(ch.subscribes.contains(probePostId), isFalse, reason: '取消订阅要真生效');
    debugPrint('[p2b] ②.5 话题页订阅开关（真机点击）✓');

    // ---------- ③ 收尾 ----------
    if (_doPost) {
      try {
        await chat.deletePost(probePostId);
        debugPrint('[p2b] 删掉测试消息 #$probePostId');
      } catch (e) {
        debugPrint('[p2b] 删消息失败（忽略）：$e');
      }
    }
    debugPrint('[p2b] 清理完成 ✓');
  });
}
