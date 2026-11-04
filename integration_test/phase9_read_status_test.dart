// Phase 9 真机验收：已读/未读名单（`SYNO.Chat.Post / get_read_status` v6）。
//
//   flutter test integration_test/phase9_read_status_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// ⚠️ 这台 NAS 的服务端设置里 `allow_read_status=false`（非管理员改不了），
// 所以真机只能验"**关掉时的行为**"：
//   ① 设置读回来就是 false；
//   ② 长按面板**不出现**「已读成员 / 未读成员」；
//   ③ 硬调 `get_read_status` → 服务端回 **404 CHAT_ERR_NO_PERMISSION**（服务端侧也拦）；
//   ④ 名单页在真 404 下走错误态 + 有「重试」。
// happy path（真有人读过）由离线用例覆盖（`test/read_status_test.dart`）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/post_actions_sheet.dart';
import 'package:synhub/src/features/chat/read_status_page.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

String _marker(String kind) =>
    'flt-p9rs-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：已读回执（服务端关闭时的行为）', (tester) async {
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

    // ---------- ① 服务端设置 ----------
    final settings = await chat.fetchServerSettings();
    debugPrint('[p9rs] ① 服务端 allow_read_status=${settings.allowReadStatus} '
        '(Post v6=${chat.supports('SYNO.Chat.Post', 6)})');
    expect(chat.supports('SYNO.Chat.Post', 6), isTrue,
        reason: '这台服务器的 Post 表要支持 v6');

    // ---------- 建个测试频道发一条自己的消息 ----------
    final create = container.read(channelCreateControllerProvider);
    await ctrl.refresh();
    final plain = await create.create(
      name: _marker('ch'),
      purpose: 'Phase 9 已读回执真机验收',
      type: 'private',
    );
    final cid = plain.channelId;
    final body = _marker('msg');
    final sent = await chat.createPost(
      channelId: cid,
      message: body,
      connId: container.read(chatSessionControllerProvider).connId ?? '',
    );
    final postId =
        ((sent['post'] as Map? ?? sent)['post_id'] as num).toInt();
    debugPrint('[p9rs] 测试频道 #$cid post=#$postId');

    // ---------- ② 面板入口：服务端关掉已读回执 → 不出现这两个入口 ----------
    // 直接按聊天页的判定式算一遍（`settings.allowReadStatus && 是我发的`）
    final allowReadStatus = settings.allowReadStatus && true;
    debugPrint('[p9rs] ② 面板入口判定 allowReadStatus=$allowReadStatus');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showPostActionsSheet(
                  context,
                  post: PostDto.fromJson(const {
                    'post_id': 1,
                    'channel_id': 1,
                    'creator_id': 14,
                    'type': 'normal',
                    'message': 'x',
                  }),
                  mine: true,
                  canWrite: true,
                  allowReadStatus: allowReadStatus,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    if (!settings.allowReadStatus) {
      expect(find.text('已读成员'), findsNothing);
      expect(find.text('未读成员'), findsNothing);
      debugPrint('[p9rs] ② 服务端关闭 → 面板没有「已读/未读成员」 ✓');
    } else {
      expect(find.text('已读成员'), findsOneWidget);
      debugPrint('[p9rs] ② 服务端开启 → 面板有入口 ✓');
    }
    // 关掉面板
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // ---------- ③ 硬调接口：服务端也要拦 ----------
    var denied = false;
    String? errText;
    try {
      final r = await chat.fetchReadStatus(postId);
      debugPrint('[p9rs] ③ 意外成功：read=${r.readUsers} unread=${r.unreadUsers}');
    } catch (e) {
      denied = true;
      errText = '$e';
      debugPrint('[p9rs] ③ get_read_status 被服务端拒绝：$errText');
    }
    if (!settings.allowReadStatus) {
      expect(denied, isTrue, reason: '关掉已读回执后服务端应拒绝 get_read_status');
      expect(errText, contains('404'),
          reason: '真机实测就是 404 CHAT_ERR_NO_PERMISSION');
    }

    // ---------- ④ 名单页：真错误态 + 重试可用 ----------
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ReadStatusPage(postId: postId, readUsers: true),
      ),
    ));
    await tester.pumpAndSettle();
    if (!settings.allowReadStatus) {
      expect(find.textContaining('查不到已读状态'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget, reason: '重试后仍是同样的错误');
      debugPrint('[p9rs] ④ 名单页错误态 + 重试 ✓');
    } else {
      // 服务端开着的话，自己的消息通常就是"所有人都没读"或"部分已读"
      expect(find.textContaining('已读成员'), findsWidgets);
      debugPrint('[p9rs] ④ 名单页正常渲染 ✓');
    }

    // ---------- ⑤ 收尾 ----------
    try {
      await chat.deletePost(postId);
      debugPrint('[p9rs] ⑤ 删掉测试消息 #$postId');
    } catch (e) {
      debugPrint('[p9rs] ⑤ 删消息失败：$e');
    }
    try {
      await chat.disjoinNamedChannel(cid);
      debugPrint('[p9rs] ⑤ 已退出 #$cid');
    } catch (e) {
      debugPrint('[p9rs] ⑤ 退出频道失败：$e');
    }
    debugPrint('[p9rs] 完成 ✓（我=#$myId）');
  });
}
