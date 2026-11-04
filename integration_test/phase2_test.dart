// Phase 2 真机验收（跑在 Android 设备上，不是 host）。
//
// 与 test/chat_live_test.dart 的区别：那边跑在 host（flutter test），这边跑在
// **真机上**，因此额外验证了 host 测不到的东西：
//   * Drift 真正落到设备磁盘（`ChatDatabase.open()` + path_provider）
//   * Android 网络栈下的 TLS websocket（自签/主机名不匹配）
//   * ChannelListPage 用真实数据渲染出可点的频道列表
//   * 另一会话发的消息能实时把未读推到 UI
//
// 用法：
//   flutter test integration_test/phase2_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=demo_admin-qq \
//     --dart-define=SYNO_NAS_ACCOUNT=demo_user \
//     --dart-define=SYNO_NAS_PASSWORD='…' \
//     --dart-define=SYNO_LIVE_POST=1
//
// 不带 SYNO_LIVE_POST=1 时第 ④ 步跳过（那一步会真发一条消息，末尾会删掉）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/channel_row.dart' as row;
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
// ⚠️ `bool.fromEnvironment('X')` 只认 "true"/"false"：
// `--dart-define=SYNO_LIVE_POST=1` 会被解析成默认值 false（真机踩过）。
// 所以两种写法都接受。
const _doPostRaw = String.fromEnvironment('SYNO_LIVE_POST');
final _doPost = _doPostRaw == '1' || _doPostRaw == 'true';

Future<void> _sweep(ChatApi chat, int channelId) async {
  try {
    final posts = await chat.listPosts(channelId: channelId, prevCount: 50);
    for (final p in posts) {
      final msg = '${p['message']}';
      if (msg.contains('flt-device-') || msg.contains('flt-live-')) {
        await chat.deletePost((p['post_id'] as num).toInt());
      }
    }
  } catch (_) {
    // 清理失败不影响结论
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 2 真机：登录 → 同步 → 实时未读 → UI 渲染', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');
    expect(_account, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_ACCOUNT=…');

    // ---- ① 连接 + 登录（走 QuickConnect，与 App 真实路径一致）----
    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    final session = await conn.api.login(
      account: _account,
      password: _password,
      session: 'Chat',
    );
    expect(session.sid, isNotEmpty);
    debugPrint('[device] 已登录 baseUrl=${conn.endpoint.baseUrl}');

    // ---- ② 控制器：拉列表 + 建实时通道（Drift 落设备磁盘）----
    final container = ProviderContainer();
    // Riverpod 3 在 StreamProvider 还有未完成的 future 时 dispose 会抛 StateError
    // （ElementWithFuture.dispose）。集成测试进程随后就退出，这里吞掉即可，
    // 但真正的断言失败不受影响。
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);

    var state = container.read(chatSessionControllerProvider);
    debugPrint('[device] phase=${state.phase} 频道=${state.channelCount} '
        '用户=${state.userCount} connId=${state.connId}');
    expect(state.phase, ChatSyncPhase.ready, reason: '同步+实时通道都应就绪');
    expect(state.channelCount, greaterThan(0));
    expect(state.connId, isNotNull);
    expect(state.myUserId, greaterThan(0));

    // 频道确实写进了设备上的 drift 库
    final db = container.read(chatDatabaseProvider);
    expect(db, isA<ChatDatabase>());
    // ★ 第 52 轮加固：这里原来断言 `stored.length == state.channelCount`，
    //   前提是"本地库 == 服务端列表" —— **这个前提不成立，也不该成立**：
    //   * 套件用 `flutter drive --keep-app-running` ⇒ 本地 drift 库**跨轮次累积**
    //     （实测 `Expected <28> / Actual <32>`）；
    //   * `ChatStore._pruneChannelsMissingFrom`（`lib/src/data/local/chat_store.dart:163-188`）
    //     是**有意**放过三类行的：
    //       - 本地新建、服务端还没确认的频道（进程内内存标记）；
    //       - 有失败/过期消息的频道（`failedPostChannelIds()`，`state IN (2,3)`）；
    //       - **带 `channel_key_enc` 的 E2EE 频道** —— 剪掉 = 永久丢频道密钥、
    //         该频道历史密文再也解不开（同文件 :180-188 的注释），不可逆。
    //   ⇒ "行数相等"既不成立也不该成立。改成**集合语义**（比数行数更强，
    //     而且不依赖"库是干净的"）：
    //       ① 服务端列出的每个频道都必须真的落进了本地 drift 库；
    //       ② 本地多出来的行必须**逐个**能归因到上面那条清理政策，否则就是剪枝漏了。
    final store = container.read(chatStoreProvider);
    final stored = await store.allChannels();
    final server = await ChatApi(conn.api).listChannels();
    final serverIds = {for (final c in server) c.channelId};
    final storedIds = {for (final c in stored) c.channelId};
    expect(storedIds, containsAll(serverIds),
        reason: '服务端列出的 ${serverIds.length} 个频道都要落进本地 drift 库'
            '（本地有 ${storedIds.length} 条）');
    final protectedIds = await store.failedPostChannelIds();
    final unexplained = stored
        .where((c) => !serverIds.contains(c.channelId))
        .where((c) => c.channelKeyEnc.isEmpty && !protectedIds.contains(c.channelId))
        .map((c) => c.channelId)
        .toList();
    expect(unexplained, isEmpty,
        reason: '本地多出来的频道只能是"清理政策有意保留"的两类'
            '（E2EE 密钥行 / 有失败消息的频道）；这几个都不是 ⇒ 剪枝漏了：$unexplained');

    debugPrint('[device] drift 里读到 ${stored.length} 条频道，接下来等 stream 首帧');
    // ⚠️ 不要用 `channelsProvider.future`：Riverpod 3 里它等的是"下一个值"，
    // 而 provider 是刚刚才创建的，首帧可能已经错过 → 会一直挂着（真机踩过）。
    // 直接监听 stream 并给超时，这样卡住会变成"失败"而不是"永远不动"。
    final channels = await container
        .read(chatStoreProvider)
        .watchChannels()
        .first
        .timeout(const Duration(seconds: 10));
    debugPrint('[device] stream 首帧=${channels.length} 条');
    expect(channels, isNotEmpty);

    // ---- ③ UI：ChannelListPage 用真实数据渲染 ----
    debugPrint('[device] 开始渲染 ChannelListPage');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ChannelListPage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    // 【同步更新】列表页在"深空座舱"重构后不再是 ListTile，而是指挥台风格的行面板
    // （`ChannelRow`：切角面板 + 未读能量条 + 形状/图标双编码）。断言的**意图不变**：
    // 真实频道条目必须画出来，所以这里换成按新组件类型断言。
    expect(find.byType(row.ChannelRow), findsWidgets,
        reason: '应当渲染出频道条目');
    debugPrint('[device] UI 渲染 OK');

    // ---- ④ 另一会话发消息 → 本机未读实时 +1 ----
    if (!_doPost) {
      debugPrint('[device] 未设置 SYNO_LIVE_POST=1，跳过实时投递验证');
      return;
    }

    final target =
        channels.firstWhere((c) => !c.encrypted && c.isJoined, orElse: () => channels.first);
    addTearDown(() => _sweep(ChatApi(conn.api), target.channelId));

    // 第二个"设备"（同账号第二次登录）
    final conn2 = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    final session2 = await conn2.api.login(
      account: _account,
      password: _password,
      session: 'Chat',
    );
    final socket2 = ChatSocket(
      baseUrl: conn2.endpoint.baseUrl,
      sid: session2.sid,
      synotoken: session2.synotoken,
    );
    addTearDown(() async {
      socket2.dispose();
      await conn2.api.logout();
      await conn2.api.transport.close();
    });
    await socket2.connect();
    await socket2.waitReady(timeout: const Duration(seconds: 25));

    final before = (await container.read(chatStoreProvider).allChannels())
        .firstWhere((c) => c.channelId == target.channelId)
        .unread;
    if (before != 0) {
      // 先把未读清零，后面才能观察到 +1
      await ctrl.markRead(target.channelId);
    }

    final marker = 'flt-device-${DateTime.now().millisecondsSinceEpoch}';
    final post = await ChatApi(conn2.api).createPost(
      channelId: target.channelId,
      message: marker,
      connId: socket2.connId!,
    );
    debugPrint('[device] 第二会话发出 post_id=${post['post_id']}');

    // 等本机控制器把未读写进库。
    // ⚠️ 第二会话是**同一账号**，所以 creator_id == myUserId，未读不该涨
    // （原 App 语义：自己的消息不算未读，哪怕来自另一台设备）。
    // 给实时事件一点时间（同账号不该涨未读，等 5 秒足够确认"没涨"）
    var after = 0;
    for (var i = 0; i < 16; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      after = (await container.read(chatStoreProvider).allChannels())
          .firstWhere((c) => c.channelId == target.channelId)
          .unread;
    }
    debugPrint('[device] 同账号另一设备发来的消息 → 未读=$after（应为 0）');
    expect(after, 0, reason: '同账号发的消息不该算未读');

    // "别人发的"这条分支：注入形状一致、只把 creator_id 换成另一个用户的事件
    await ctrl.handleEvent(ChatSocketEvent('client.post.create', {
      'user_id': 4,
      'channel_id': target.channelId,
      'data': {
        'creator_id': 4,
        'post_id': (post['post_id'] as num).toInt(),
        'thread_id': 0,
        'create_at': DateTime.now().millisecondsSinceEpoch,
      },
    }));
    final bumped = (await container.read(chatStoreProvider).allChannels())
        .firstWhere((c) => c.channelId == target.channelId)
        .unread;
    debugPrint('[device] 注入"别人发的"事件 → 未读=$bumped');
    expect(bumped, 1, reason: '别人发的消息应当 +1 未读');

    // 收尾：删掉测试消息。
    //
    // ⚠️ 这里**不要**再调 tester.pump()：真机测试跑久了屏幕会息屏，
    // 息屏后 vsync 停发，`pump()` 会永远等不到帧（踩过一次，卡死 5 分钟超时）。
    // UI 更新本身已由 phase3_test（ChatPage 渲染真消息）+ 离线 widget 测试覆盖。
    await ChatApi(conn2.api).deletePost((post['post_id'] as num).toInt());
    debugPrint('[device] 已删除测试消息');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
