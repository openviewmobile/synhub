// Phase 9 真机验收：系统消息文案（`system_props` → 中文文案）。
//
//   flutter test integration_test/phase9_system_message_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 思路：在自建测试频道里**真造事件**（邀请 / 踢人 / 改名 / 置顶 / 建话题），
// 再从 `Post/list` 读回服务端生成的 `type=system` 消息，用我们的映射渲染，
// 断言：
//   ① 系统消息的 `message` 是空的（所以文案必须客户端拼，不能靠服务端）；
//   ② 每条都渲染出**真实姓名/频道名**，且**不是**兜底文案「系统消息（…）」。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/system_message.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _invitee = 4;

/// `SYNO.Chat.Post:create` 有**服务端频率限制**：几秒内连发会回
/// `411 CHAT_ERR_SEND_TOO_FREQUENTLY`（本仓早已记录：
/// `lib/src/features/chat/chat_session_controller.dart:2304`）。
/// 这个用例要在几秒内造"普通消息 + 话题回复"两条，第二条极容易撞上限 ——
/// 真机实测就是死在 `thread.create` 那条上（`DsmApiException(… code=411)`）。
/// 这里按服务端要求**退避重试**；不放宽断言：最终仍必须真的把消息发出去。
Future<Map<String, dynamic>> _createPostPaced(
  ChatApi chat, {
  required int channelId,
  required String message,
  required String connId,
  int? threadId,
  bool isThread = false,
  int attempts = 4,
}) async {
  for (var i = 1;; i++) {
    try {
      return await chat.createPost(
        channelId: channelId,
        message: message,
        connId: connId,
        threadId: threadId,
        isThread: isThread,
      );
    } on DsmApiException catch (e) {
      if (e.code != 411 || i >= attempts) rethrow;
      final wait = Duration(seconds: 5 * i);
      debugPrint('[p9sm] Post/create 撞上频率限制(411)，等 ${wait.inSeconds}s 重试'
          '（第 $i 次）');
      await Future<void>.delayed(wait);
    }
  }
}

String _marker(String kind) =>
    'flt-p9sm-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：系统消息文案映射', (tester) async {
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
    ChatSyncState sync() => container.read(chatSessionControllerProvider);
    final myId = sync().myUserId;

    // 用户表（真名 → 文案里的名字）
    final users = await container.read(chatStoreProvider).allUsers();
    final usersById = {for (final u in users) u.userId: u};
    debugPrint('[p9sm] 用户 ${usersById.length} 个，我=#$myId');

    // ---------- 造事件 ----------
    final create = container.read(channelCreateControllerProvider);
    await ctrl.refresh();
    final newName = _marker('ch');
    final plain = await create.create(
      name: newName,
      purpose: 'Phase 9 系统消息文案真机验收',
      type: 'private',
    );
    final cid = plain.channelId;
    debugPrint('[p9sm] 测试频道 #$cid $newName');

    // 邀请 → channel.join
    expect(await ctrl.inviteMembers(cid, const [_invitee]), isTrue);
    // 踢人 → channel.disjoin
    expect(await ctrl.kickMembers(cid, const [_invitee]), isTrue);
    // 改名 → channel.update
    final renamed = _marker('renamed');
    await chat.setNamedChannel(cid, name: renamed);
    // 发一条 + 置顶 → post.pin
    final body = _marker('msg');
    final sent = await _createPostPaced(chat,
        channelId: cid, message: body, connId: sync().connId ?? '');
    final postId = ((sent['post'] as Map? ?? sent)['post_id'] as num).toInt();
    expect(await ctrl.setPin(cid, postId, pin: true), isTrue);
    // 话题 → thread.create
    final thread = await _createPostPaced(
      chat,
      channelId: cid,
      message: _marker('thread'),
      connId: sync().connId ?? '',
      threadId: postId,
      isThread: true,
    );
    final threadPostId =
        ((thread['post'] as Map? ?? thread)['post_id'] as num).toInt();
    debugPrint('[p9sm] 事件造好：post=#$postId thread=#$threadPostId');

    // ---------- 读回系统消息并渲染 ----------
    await ctrl.refresh();
    final channel = (await container.read(chatStoreProvider).allChannels())
        .firstWhere((c) => c.channelId == cid);
    final posts = await chat.listPosts(channelId: cid, prevCount: 60);
    final systemPosts = [
      for (final raw in posts)
        if ('${raw['type']}' == 'system') PostDto.fromJson(raw),
    ];
    debugPrint('[p9sm] 系统消息 ${systemPosts.length} 条');

    final rendered = <String, List<String>>{};
    final rawMessages = <String>{};
    for (final p in systemPosts) {
      rawMessages.add(p.message);
      final text = systemMessageText(p,
          usersById: usersById, channel: channel, myUserId: myId);
      rendered.putIfAbsent(p.systemEvent, () => []).add(text);
      debugPrint('[p9sm]   ${p.systemEvent} → $text');
    }

    // ① 服务端给的 message 都是空的 → 文案确实得客户端拼
    expect(rawMessages, everyElement(isEmpty),
        reason: '系统消息的正文应由客户端按 event 拼（原版 ChannelViewBinder 就是这么做的）');
    // ② 造出来的事件都出现了
    for (final e in ['channel.join', 'channel.disjoin', 'channel.update', 'post.pin']) {
      expect(rendered.keys, contains(e), reason: '事件 $e 应该产生一条系统消息');
    }
    // ③ 渲染结果含真名/真频道名，且没有落进兜底文案
    final inviteeName = usersById[_invitee]?.displayName ?? '用户 $_invitee';
    final myName = usersById[myId]?.displayName ?? '用户 $myId';
    debugPrint('[p9sm] 期望名字：邀请人=$myName 被邀请/被踢=$inviteeName');
    expect(rendered['channel.join'], isNotNull);
    expect(rendered['channel.join']!.join(' | '), contains(inviteeName),
        reason: '邀请那条要出现被邀请人的真名');
    expect(rendered['channel.join']!.join(' | '), contains('已邀请'));
    expect(rendered['channel.disjoin']!.single, contains(inviteeName));
    expect(rendered['channel.update']!.single, contains(renamed));
    expect(rendered['post.pin']!.single, '已锁定 this message');
    for (final entry in rendered.entries) {
      for (final text in entry.value) {
        expect(text, isNot(contains('系统消息（')),
            reason: '${entry.key} 没被识别成已知事件');
        expect(text, isNotEmpty);
      }
    }
    debugPrint('[p9sm] ✓ 文案全部命中（无兜底）');

    // ---------- 收尾 ----------
    for (final id in [threadPostId, postId]) {
      try {
        await chat.deletePost(id);
      } catch (e) {
        debugPrint('[p9sm] 删 #$id 失败：$e');
      }
    }
    try {
      await chat.disjoinNamedChannel(cid);
      debugPrint('[p9sm] 已退出 #$cid');
    } catch (e) {
      debugPrint('[p9sm] 退出失败：$e');
    }
    debugPrint('[p9sm] 完成 ✓');
  });
}
