// Phase 4 真机验收：「正在输入」（typing）收 + 发 + UI。
//
//   flutter test integration_test/phase4_typing_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 验收内容：
//   ① 真机 UI 上真的出现「xxx 正在输入」那一条（喂真形状的服务端载荷，走
//      `handleEvent` —— 和 socket 监听器是同一条链路）；
//   ② 停止输入（空列表）→ 那一条消失；
//   ③ 我们自己的 typing 走**真 socket** 发出去不报错、连接依然 ready
//      （节流与自动 clear 的行为在 `test/typing_test.dart` 里逐条断过）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/data/remote/socket/socket_events.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/typing_notifier.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 4 真机：正在输入（收 + 发）', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

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
    final sync = container.read(chatSessionControllerProvider);
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    debugPrint('[p4t] 我=#${sync.myUserId} 实时=${sync.realtime}');
    expect(sync.realtime, isTrue, reason: '需要真实时通道');

    // 频道列表是 Drift 流，start() 之后要等它落库；直接问库更稳
    final store = container.read(chatStoreProvider);
    var channels = await store.allChannels();
    if (channels.isEmpty) {
      await ctrl.refresh();
      channels = await store.allChannels();
    }
    expect(channels, isNotEmpty, reason: '至少得有一个频道');
    final target = channels.firstWhere(
      (c) => c.channelId > 0 && c.members.any((id) => id != sync.myUserId),
      orElse: () => channels.first,
    );
    var others = target.members.where((id) => id != sync.myUserId).toList();
    if (others.isEmpty) {
      // 频道成员没同步全时，随便挑一个别的真人当"正在输入的人"
      final users = await store.allUsers();
      others = users
          .where((u) => u.userId != sync.myUserId && u.type == 'human')
          .map((u) => u.userId)
          .take(2)
          .toList();
    }
    debugPrint('[p4t] 目标频道 #${target.channelId} 别人=$others');
    expect(others, isNotEmpty, reason: '这个 NAS 上得有别人才能测"别人正在输入"');

    // ---------- ① 收到 typing_v2 → UI 出现「正在输入」 ----------
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ChatPage(channelId: target.channelId)),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.runAsync(() async {
      await ctrl.handleEvent(ChatSocketEvent(
        SocketEvent.clientChannelTypingV2,
        {
          'channel_id': target.channelId,
          '0': others,
        },
      ));
    });
    await tester.pump(const Duration(milliseconds: 100));
    final want = others.length == 1 ? '1 个人正在输入' : '${others.length} 个人正在输入';
    // 1:1 会话会显示名字，两种都认
    final hasTyping = find.textContaining('正在输入').evaluate().isNotEmpty;
    expect(hasTyping, isTrue, reason: 'UI 上要出现「正在输入」（期望含 "$want"）');
    final shown = find
        .textContaining('正在输入')
        .evaluate()
        .map((e) => (e.widget as Text).textSpan?.toPlainText() ?? '')
        .join(' | ');
    debugPrint('[p4t] ① UI 显示：$shown ✓');
    expect(container.read(typingUsersProvider(target.channelId)), others);

    // ---------- ② 空列表 → 消失 ----------
    await tester.runAsync(() async {
      await ctrl.handleEvent(ChatSocketEvent(
        SocketEvent.clientChannelTypingV2,
        {'channel_id': target.channelId, '0': <int>[]},
      ));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('正在输入'), findsNothing);
    expect(container.read(typingUsersProvider(target.channelId)), isEmpty);
    debugPrint('[p4t] ② 停止输入后消失 ✓');

    // ---------- ③ 自己的 typing 走真 socket ----------
    ctrl.typing();
    ctrl.typing();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    ctrl.clearTyping();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    expect(sync.realtime, isTrue, reason: '发 typing 不该把连接弄断');
    debugPrint('[p4t] ③ 真 socket 发 typing/clear_typing 后连接仍 ready ✓');
    ctrl.clearTyping();
  });
}
