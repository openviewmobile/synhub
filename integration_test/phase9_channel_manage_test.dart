// Phase 9 真机验收：频道管理（收藏 / 归档 / 关闭）。
//
//   flutter test integration_test/phase9_channel_manage_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_LIVE_POST=true
//
// 走 App 自己的代码（`ChatSessionController` → `ChatApi`），在真 NAS（2.4.7-22203）上：
//   ① 建临时私有频道 → `Channel/star` v1 收藏（服务端 `is_star=true`）→ `unstar` 复原；
//   ② 里面发一条消息（归档要求频道非空）→ `Channel/archive` v2：
//      **真机实测这个账号 + 自己建的私有频道上服务端"收下请求但不归档"**
//      （返回 success，但 `is_joined` 不变、`Archive/list` 无记录），所以这里
//      断言的是"我们如实回查、没瞎删本地数据"，随后用 close 收尾；
//      v4 会直接 103（印证 2.4.7 方法表里 v4 没有 archive）；
//   ③ 再建一个临时频道 → `Channel/close` v2（带 conn_id）关掉
//      → 服务端 `Channel/get` 报错、本地频道行与消息一并删除；
//   ④ 归档/关闭本身就是清理（不额外建垃圾），失败路径下兜底 disjoin。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

String _marker(String kind) =>
    'flt-p9m-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：收藏 / 归档 / 关闭频道', (tester) async {
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
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    final create = container.read(channelCreateControllerProvider);
    await ctrl.start(conn);
    expect(ctrl.supportsChannelV2, isTrue, reason: 'NAS 是 2.4.7，Channel 有 v5');
    debugPrint('[p9m] 我=#${container.read(chatSessionControllerProvider).myUserId} '
        'conn_id=${container.read(chatSessionControllerProvider).connId}');

    // ---------- ① 建频道 + 收藏/取消收藏 ----------
    final starName = _marker('star');
    final starCh = await create.create(
      name: starName,
      purpose: 'Phase 9 频道管理验收',
      type: 'private',
    );
    final starId = starCh.channelId;
    expect(starId, greaterThan(0));
    debugPrint('[p9m] 临时频道 #$starId 建好');

    await ctrl.setChannelStar(starId, star: true);
    var dto = (await chat.listChannelsByIds([starId])).single;
    expect(dto.isStar, isTrue, reason: '服务端要记住 is_star');
    await ctrl.setChannelStar(starId, star: false);
    dto = (await chat.listChannelsByIds([starId])).single;
    expect(dto.isStar, isFalse, reason: 'unstar 要生效');
    debugPrint('[p9m] 收藏/取消收藏 ✓');

    // ---------- ② 归档（要求频道里有消息） ----------
    final sent = await ctrl.sendMessage(starId, 'flt-p9m archive seed');
    expect(sent, isTrue, reason: '归档前要有一条消息');
    final localCount = await ctrl.postCountOf(starId);
    expect(localCount, greaterThan(0));
    final joinedBefore =
        (await chat.listChannels()).map((c) => c.channelId).toList();
    expect(joinedBefore, contains(starId));

    // v4 没有 archive（2.4.7 方法表），应报 103
    var v4Rejected = false;
    try {
      await conn.api.call('SYNO.Chat.Channel', 'archive',
          preferredVersion: 4, params: {'channel_id': starId});
    } catch (e) {
      v4Rejected = true;
      debugPrint('[p9m] archive v4（方法表里没有）→ $e');
    }
    expect(v4Rejected, isTrue, reason: 'v4 不含 archive，必须报错');

    final applied = await ctrl.archiveChannel(starId);
    final joinedAfter =
        (await chat.listChannels()).map((c) => c.channelId).toList();
    if (applied) {
      expect(joinedAfter, isNot(contains(starId)), reason: '归档后要从已加入列表消失');
      final archives = await ctrl.listArchives();
      expect(archives.where((a) => a.channel.channelId == starId), isNotEmpty);
      debugPrint('[p9m] 归档 ✓（服务端真的归档了）');
    } else {
      // 实测路径：服务端没归档 → 频道必须**还在**，本地也不能被删掉
      expect(joinedAfter, contains(starId), reason: '服务端没归档时不该本地删掉');
      final store = container.read(chatStoreProvider);
      expect((await store.allChannels()).any((c) => c.channelId == starId), isTrue);
      debugPrint('[p9m] 归档被服务端忽略（非管理员 + 自己建的私有频道）—— '
          '本地保持原样，没瞎删 ✓');
    }

    // ---------- ③ 关闭频道（不可逆） ----------
    // #starId 用 close 收尾（archive 若没生效，它是唯一的清理方式）
    final closeName = _marker('close');
    final closeCh = await create.create(
      name: closeName,
      purpose: 'Phase 9 关闭验收',
      type: 'private',
    );
    final closeId = closeCh.channelId;
    await ctrl.sendMessage(closeId, 'flt-p9m close seed');
    await ctrl.closeChannel(closeId);
    debugPrint('[p9m] 关闭 #$closeId ✓');

    // 服务端：从已加入列表消失；本地：频道行 + 消息都没了
    final joinedFinal =
        (await chat.listChannels()).map((c) => c.channelId).toList();
    expect(joinedFinal, isNot(contains(closeId)));
    final store = container.read(chatStoreProvider);
    expect((await store.allChannels()).any((c) => c.channelId == closeId), isFalse,
        reason: 'close 要删本地频道行');
    expect(await store.countPosts(closeId), 0, reason: 'close 要清本地消息');

    // 关掉的频道再查应该报错（服务端已删）
    var gone = false;
    try {
      final again = await chat.listChannelsByIds([closeId]);
      gone = again.isEmpty;
    } catch (_) {
      gone = true;
    }
    expect(gone, isTrue, reason: '关闭后 Channel/get 不该再拿到它');
    debugPrint('[p9m] 关闭后服务端/本地都干净 ✓');

    // 收尾：把 ① 的频道关掉（archive 没生效时的兜底）
    if ((await chat.listChannels()).any((c) => c.channelId == starId)) {
      await ctrl.closeChannel(starId);
      debugPrint('[p9m] 收尾关闭 #$starId ✓');
    }
  });
}
