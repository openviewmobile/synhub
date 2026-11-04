// Phase 9 真机验收：斜杠命令（`Webhook.Slash / execute`，起会议）。
//
//   flutter test integration_test/phase9_slash_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_LIVE_POST=true
//
// 真 NAS 2.4.7-22203：
//   ① `User/list` 里找服务端下发的斜杠机器人（`bot_type=slash` + `slash_props.cmd`）；
//   ② 建临时私有频道 → 执行 `/jitsi …`（未加密频道才允许）；
//   ③ 轮询 `Post/list` 等机器人把会议消息发出来（原版也是"命令下去、机器人回来发卡片"）；
//   ④ 关掉临时频道收尾。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/slash_command.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

String _marker(String kind) =>
    'flt-p9s-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：斜杠命令起会议', (tester) async {
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
    final create = container.read(channelCreateControllerProvider);
    await ctrl.start(conn);

    // ---------- ① 服务端下发的斜杠机器人 ----------
    final users = await chat.listUsers();
    final slashBots = users.where((u) => u.isSlashBot).toList();
    debugPrint('[p9s] 斜杠机器人：'
        '${slashBots.map((u) => "#${u.userId} /${u.slashCmd}").toList()}');
    expect(slashBots, isNotEmpty, reason: '服务端应当下发至少一个斜杠机器人');

    final jitsi = slashBots.where((u) => u.slashCmd == 'jitsi').toList();
    if (jitsi.isEmpty) {
      debugPrint('[p9s] 这台 NAS 没有 /jitsi（只有 '
          '${slashBots.map((u) => u.slashCmd).toList()}）→ 只验证解析函数，跳过执行');
      expect(isConferenceSlashFormat('/${slashBots.first.slashCmd}'),
          isFalse, reason: '非 jumpchat/jitsi 前缀不算起会议命令');
      return;
    }
    final bot = jitsi.first;

    // 本地解析：正文 → 匹配到的机器人
    expect(findSlashBot(users, '/jitsi ${_marker('m')}')!.userId, bot.userId);

    // ---------- ② 建临时频道 + 执行命令 ----------
    final channel = await create.create(
      name: _marker('slash'),
      purpose: 'Phase 9 斜杠命令验收',
      type: 'private',
    );
    final channelId = channel.channelId;
    expect(channelId, greaterThan(0));
    debugPrint('[p9s] 临时频道 #$channelId 建好');

    final before =
        (await chat.listPosts(channelId: channelId, prevCount: 30)).length;
    final text = '/jitsi ${_marker('meet')}';
    final ok = await ctrl.executeSlashCommand(
      channelId: channelId,
      message: text,
      botUserId: bot.userId,
    );
    expect(ok, isTrue, reason: 'Webhook.Slash/execute 应当成功');
    debugPrint('[p9s] execute 成功：$text');

    // ---------- ③ 等机器人把会议消息发出来 ----------
    List<Map<String, dynamic>> posts = const [];
    var fromBot = 0;
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      posts = await chat.listPosts(channelId: channelId, prevCount: 30);
      fromBot = posts.where((p) => p['creator_id'] == bot.userId).length;
      if (fromBot > 0) break;
    }
    final cmdName = bot.slashCmd;
    debugPrint('[p9s] 命令后消息数 $before→${posts.length}，'
        '其中来自 /$cmdName 机器人的 $fromBot 条');
    for (final p in posts.where((p) => p['creator_id'] == bot.userId)) {
      final body = (p['message'] ?? '').toString();
      debugPrint('[p9s] 机器人消息：'
          '${body.length > 80 ? body.substring(0, 80) : body}');
    }
    expect(fromBot, greaterThan(0),
        reason: '斜杠命令应当让机器人发一条会议消息（含 join 链接）');

    // ---------- ④ 收尾 ----------
    await ctrl.closeChannel(channelId);
    final gone = await chat.listChannels();
    expect(gone.any((c) => c.channelId == channelId), isFalse);
    debugPrint('[p9s] ✅ 斜杠命令验收通过，临时频道已收尾');
  });
}
