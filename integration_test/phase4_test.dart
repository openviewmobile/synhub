// Phase 4 真机验收：消息操作（星标/置顶/回应/编辑/话题/转发/删除）
// 以及**这些操作的广播能不能被本机控制器正确落库**。
//
//   flutter test integration_test/phase4_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=demo_admin-qq …
//
// 手法：A 是"App 本体"（ChatSessionController + 真 socket），B 是第二个会话。
// B 对同一条消息做各种操作 → 服务端广播 → A 必须把状态改对。
// 这验证的是广播载荷形状（我们是从反编译代码里推的）+ 控制器的落库分支。
import 'package:flutter/foundation.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _postRaw = String.fromEnvironment('SYNO_LIVE_POST');
final _doPost = _postRaw == '1' || _postRaw == 'true';

String _marker(String kind) =>
    'flt-p4-$kind-${DateTime.now().millisecondsSinceEpoch}';

Future<void> _waitFor(
  Future<bool> Function() cond, {
  Duration timeout = const Duration(seconds: 25),
  String what = '条件',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  fail('等待超时：$what');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 4 真机：星标/置顶/回应/编辑/话题/转发/删除', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final connA = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await connA.api.login(
        account: _account, password: _password, session: 'Chat');
    final chatA = ChatApi(connA.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(connA);
    final sync = container.read(chatSessionControllerProvider);
    expect(sync.phase, ChatSyncPhase.ready);
    final store = container.read(chatStoreProvider);

    final channels = await store.allChannels();
    final target = channels.firstWhere((c) => !c.encrypted && c.isJoined,
        orElse: () => channels.first);
    final other = channels.firstWhere(
        (c) => c.channelId != target.channelId && !c.encrypted && c.isJoined,
        orElse: () => target);
    debugPrint('[p4] 主频道=#${target.channelId} 转发目标=#${other.channelId}');

    // 会话 B
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
    await socketB.connect();
    await socketB.waitReady(timeout: const Duration(seconds: 25));

    // 本机创建的消息 id，收尾要删干净
    final mineIds = <int>[];
    final tmpIds = <int>[];
    addTearDown(() async {
      for (final id in [...mineIds, ...tmpIds]) {
        try {
          await chatA.deletePost(id);
        } catch (_) {}
      }
      try {
        socketB.dispose();
        await connB.api.logout();
        await connB.api.transport.close();
      } catch (_) {}
    });

    if (!_doPost) {
      debugPrint('[p4] 未开 SYNO_LIVE_POST，只验证离线部分');
      return;
    }

    // ---------- 准备一条消息 ----------
    final marker = _marker('base');
    final sent = await ctrl.sendMessage(target.channelId, marker);
    expect(sent, isTrue);
    final post = (await store.postsForChannel(target.channelId))
        .firstWhere((p) => p.message == marker);
    final postId = post.postId;
    mineIds.add(postId);
    debugPrint('[p4] 测试消息 post_id=$postId');

    // ---------- ① 星标 / 取消星标（B 操作，A 靠广播更新）----------
    await chatB.starPost(postId);
    await _waitFor(() async {
      final p = await store.postById(target.channelId, postId);
      return p?.isStar == true;
    }, what: 'post.star 广播让 A 的本地星标置位');
    debugPrint('[p4] 星标广播 → 本地 isStar ✓');

    await chatB.starPost(postId, star: false);
    await _waitFor(() async {
      final p = await store.postById(target.channelId, postId);
      return p?.isStar == false;
    }, what: 'post.unstar 广播');
    debugPrint('[p4] 取消星标广播 ✓');

    // ---------- ② 消息置顶 / 取消置顶 ----------
    //
    // ⚠️ 两套东西别混：
    //   * `Post/pin` v1（**消息置顶**，就是这一段）→ 服务端写 `last_pin_at`，
    //     `is_sticky` **保持 false**；置顶列表（`Post/list has=['pin']`）按
    //     `last_pin_at` 过滤。真机实测见 `tool/probe_pin2.dart`。
    //   * `Post/stick` v2（**话题置顶卡片**）→ 写 `is_sticky`。这台 NAS 的
    //     `Post/stick` 回 407 `CHAT_ERR_INVALID_RECORD`（置顶没开，
    //     `docs/phase4-protocol.md` §7），`unstick` 同样 407。
    final pinOk = await ctrl.setPin(target.channelId, postId, pin: true);
    expect(pinOk, isTrue, reason: 'Post/pin 这台 NAS 是开的（不该 407）');
    final pinned = await store.postById(target.channelId, postId);
    expect(pinned!.lastPinAt, greaterThan(0), reason: 'pin 后本地 last_pin_at 要写上');
    expect(pinned.isSticky, isFalse, reason: '消息置顶不该动 is_sticky（那是 stick v2）');
    // 服务端回读（别的会话看到的状态才算数）
    final serverPosts = await chatA.listPosts(
        channelId: target.channelId, prevCount: 20, nextCount: 20);
    await store.replaceChannelPosts(target.channelId,
        serverPosts.map(PostDto.fromJson).toList());
    final pinnedRemote = await store.postById(target.channelId, postId);
    expect(pinnedRemote!.lastPinAt, greaterThan(0), reason: '服务端确实记住了置顶');

    // ⚠️ 服务端**不会**广播 `post.pin` / `post.unpin`（两个 socket 实测：
    // 只有 `client.post.create` 回显，pin/unpin 返回 `{}` 且一个事件都不推，
    // 见 `tool/probe_pin_broadcast.dart`）。所以别的会话只能靠重新拉列表看到，
    // 原版也是这个行为：谁操作谁改自己的库。
    await chatB.pinPost(postId, pin: false);
    final afterUnpin = await chatA.listPosts(
        channelId: target.channelId, prevCount: 20, nextCount: 20);
    await store.replaceChannelPosts(target.channelId,
        afterUnpin.map(PostDto.fromJson).toList());
    expect((await store.postById(target.channelId, postId))!.lastPinAt, 0,
        reason: '服务端 unpin 后 last_pin_at 要归零');
    debugPrint('[p4] 消息置顶/取消置顶（last_pin_at，需重新拉列表）✓');

    // 广播分支单独验：直接造一条与反编译代码一致的 post.pin 载荷喂给控制器
    // （原版 `PostHelper.pinPost(postId, lastPinAt)` 只写 last_pin_at）
    final pinAt = DateTime.now().millisecondsSinceEpoch;
    await ctrl.handleEvent(ChatSocketEvent('client.broadcast', {
      'type': 'post.pin',
      'data': {
        'channel_id': target.channelId,
        'post_id': postId,
        'last_pin_at': pinAt,
        'user_id': sync.myUserId,
      },
    }));
    final afterBc = await store.postById(target.channelId, postId);
    expect(afterBc!.lastPinAt, pinAt, reason: 'post.pin 广播要落 last_pin_at');
    expect(afterBc.isSticky, isFalse, reason: '广播也不该动 is_sticky');
    await ctrl.handleEvent(ChatSocketEvent('client.broadcast', {
      'type': 'post.unpin',
      'data': {
        'channel_id': target.channelId,
        'post_id': postId,
        'user_id': sync.myUserId,
      },
    }));
    expect((await store.postById(target.channelId, postId))!.lastPinAt, 0);
    debugPrint('[p4] post.pin/unpin 广播落库（只动 last_pin_at）✓');

    // ---------- ③ 表情回应 ----------
    // 名字必须是 emojione **短代码**（`EmojiPresenter` 传的是 sticker.name()），
    // 直接发 unicode 会被服务端拒（407）。
    const emojiName = 'thumbsup';
    await chatB.setReaction(postId: postId, stickerName: emojiName);
    await _waitFor(() async {
      final p = await store.postById(target.channelId, postId);
      return p!.reactions.any((r) => '${r['sticker_name']}' == emojiName);
    }, what: '回应广播让本地 reactions 出现 thumbsup');
    final withReaction = await store.postById(target.channelId, postId);
    debugPrint('[p4] 回应广播 ✓ 本地=${withReaction!.reactions}');
    // UI 会把短代码转成 emoji
    final agg = aggregateReactions(withReaction.reactions, myUserId: sync.myUserId);
    expect(agg.single.label, '👍');
    debugPrint('[p4] 短代码 → 展示 = ${agg.single.label} ✓');

    await chatB.deleteReaction(postId: postId, stickerName: emojiName);
    await _waitFor(() async {
      final p = await store.postById(target.channelId, postId);
      return !p!.reactions.any((r) => '${r['sticker_name']}' == emojiName);
    }, what: '取消回应广播');
    debugPrint('[p4] 取消回应 ✓');

    // ---------- ④ 编辑（B 改，A 看广播）----------
    final edited = _marker('edited');
    await chatB.editPost(
        postId: postId, message: edited, channelId: target.channelId);
    await _waitFor(() async {
      final p = await store.postById(target.channelId, postId);
      return p?.message == edited;
    }, what: 'post.update 广播把正文改成新文本');
    debugPrint('[p4] 编辑广播 ✓');

    // ---------- ⑤ 话题回复 ----------
    final replyText = _marker('reply');
    final beforeCount =
        (await store.postById(target.channelId, postId))!.commentCount;
    final sentReply =
        await ctrl.sendThreadReply(target.channelId, postId, replyText);
    expect(sentReply, isTrue);
    final reply = (await store.postsForChannel(target.channelId, threadId: postId))
        .firstWhere((p) => p.message == replyText);
    mineIds.add(reply.postId);
    debugPrint('[p4] 回复 post_id=${reply.postId} thread_id=${reply.threadId}');
    expect(reply.threadId, postId, reason: '回复必须挂在父消息上');
    final afterCount =
        (await store.postById(target.channelId, postId))!.commentCount;
    expect(afterCount, beforeCount + 1, reason: '父消息回复数 +1');

    // 话题已读上报
    final lvc = await ctrl.markThreadRead(target.channelId, threadId: postId);
    debugPrint('[p4] 话题已读 last_view_comment_at=$lvc');
    final ch = (await store.allChannels())
        .firstWhere((c) => c.channelId == target.channelId);
    expect(ch.unreadThread.containsKey(postId), isFalse);

    // ---------- ⑥ 转发 ----------
    if (other.channelId != target.channelId) {
      final ok = await ctrl.forwardPost(postId, [other.channelId]);
      debugPrint('[p4] 转发到 #${other.channelId} → $ok');
      expect(ok, isTrue);
      // 目标频道里应当出现一条新消息（转发件），收尾一起删掉
      await _waitFor(() async {
        final list = await chatA.listPosts(
            channelId: other.channelId, prevCount: 10, has: const ['thread']);
        for (final p in list) {
          if ('${p['message']}'.contains(edited)) {
            tmpIds.add((p['post_id'] as num).toInt());
            return true;
          }
        }
        return false;
      }, what: '转发件出现在目标频道');
      debugPrint('[p4] 转发件已生成（会在收尾删除）');
    }

    // ---------- ⑦ 删除（B 删，A 靠广播清本地）----------
    await chatB.deletePost(reply.postId);
    await _waitFor(() async {
      return await store.postById(target.channelId, reply.postId) == null;
    }, what: 'post.delete 广播清掉本机那条回复');
    debugPrint('[p4] 删除广播 ✓');

    // 父消息由本机删（也走一遍 deleteMessage）
    final deleted = await ctrl.deleteMessage(target.channelId, postId);
    expect(deleted, isTrue);
    expect(await store.postById(target.channelId, postId), isNull);
    debugPrint('[p4] deleteMessage 本地已清 ✓');
  }, timeout: const Timeout(Duration(minutes: 8)));

  // 「没发出去的消息」：进频道标过期（state 3）→ 重新发送 → 删除。
  // 真机验的是三件事：local `updateAllOutdatedPosts` 的语义、`Post/create`
  // 重发真的能落服务端、以及删除 temp 不发任何请求。
  testWidgets('Phase 4 真机：失败/过期消息的重新发送与删除', (tester) async {
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
    await ctrl.start(conn);
    final sync = container.read(chatSessionControllerProvider);
    expect(sync.phase, ChatSyncPhase.ready);
    final store = container.read(chatStoreProvider);

    final channels = await store.allChannels();
    final target = channels.firstWhere((c) => !c.encrypted && c.isJoined,
        orElse: () => channels.first);
    final marker = _marker('temp');
    final createdIds = <int>[];
    addTearDown(() async {
      for (final id in createdIds) {
        try {
          await chat.deletePost(id);
        } catch (_) {}
      }
      try {
        await conn.api.logout();
        await conn.api.transport.close();
      } catch (_) {}
    });

    // ① 造一条"发送失败"的本地消息（state 2）
    final tmpA = await store.insertPendingPost(
      channelId: target.channelId,
      creatorId: sync.myUserId,
      message: marker,
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
    await store.failPendingPost(target.channelId, tmpA);
    // 注意：temp 行 post_id = 0，不能用 postById（按 post_id 查），得列表里找
    PostDto failed = (await store.postsForChannel(target.channelId))
        .firstWhere((p) => p.tmpPostId == tmpA);
    expect(failed.state, 2);

    // ② 进频道 → 原版 `updateDBAllOutDatedPosts` 把它标成"已过期"（3）
    await ctrl.enterChannel(target.channelId);
    failed = (await store.postsForChannel(target.channelId))
        .firstWhere((p) => p.tmpPostId == tmpA);
    expect(failed.state, 3, reason: '进频道要把没发成功的消息标成过期');
    final failedChannels = await store.watchChannelsWithFailedPosts().first;
    expect(failedChannels, contains(target.channelId),
        reason: '侧栏"有失败消息不藏频道"的例外要吃 state 3');

    // ③ 重新发送 → 服务端真有这条消息，本地 temp 行消失
    expect(await ctrl.resendPost(failed), isTrue, reason: '重发要成功');
    final server = await chat.listPosts(
      channelId: target.channelId,
      prevCount: 30,
      nextCount: 0,
      has: const ['thread'],
    );
    var serverId = 0;
    for (final p in server) {
      if ('${p['message']}' == marker) {
        serverId = (p['post_id'] as num).toInt();
      }
    }
    expect(serverId, greaterThan(0), reason: '重发的消息要落服务端');
    createdIds.add(serverId);
    final after = await store.postsForChannel(target.channelId);
    expect(after.where((p) => p.tmpPostId == tmpA), isEmpty,
        reason: 'temp 行要删掉，否则一条消息显示两遍');
    debugPrint('[p4] 失败消息重发 ✓（server post_id=$serverId）');

    // ④ 删除 temp：只删本地，不打服务端
    final tmpB = await store.insertPendingPost(
      channelId: target.channelId,
      creatorId: sync.myUserId,
      message: '$marker-delete',
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
    await store.failPendingPost(target.channelId, tmpB);
    final toDelete = (await store.postsForChannel(target.channelId))
        .firstWhere((p) => p.tmpPostId == tmpB);
    await ctrl.deleteTempPost(toDelete);
    expect(
        (await store.postsForChannel(target.channelId))
            .where((p) => p.tmpPostId == tmpB),
        isEmpty);
    final serverAfter = await chat.listPosts(
      channelId: target.channelId,
      prevCount: 30,
      nextCount: 0,
      has: const ['thread'],
    );
    expect(
        serverAfter.where((p) => '${p['message']}' == '$marker-delete'), isEmpty,
        reason: 'deleteTemp 不该把消息发到服务端');
    debugPrint('[p4] 删除 temp 只动本地 ✓');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
