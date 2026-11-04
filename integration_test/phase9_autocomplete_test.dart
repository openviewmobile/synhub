// Phase 9 真机验收：`#` 标签来源 + `@` 提及的线路格式。
//
//   flutter test integration_test/phase9_autocomplete_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 要回答两个只有真机能回答的问题：
//   ① `Channel.Hashtag/list` 的标签从哪来 —— 发一条带 `#tag` 的消息，服务端会不会
//      自己把它收进标签列表（决定输入框 `#` 联想的候选是本地攒还是能直接依赖服务端）；
//   ② 原版把提及写成 `@u:<id>`（`ChatUtil.getImageMentionSpanStringBuilder`，仅当
//      `Post v4 && 非加密频道`）——真机确认服务端认这个写法、并且把它记进
//      `Post/list` 的 `mentions`，而不是当成普通文本。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/features/chat/autocomplete.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/mentions.dart';
import 'package:synhub/src/features/chat/rich_text.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

/// 拿来当提及目标的另一个真人（有 E2EE 公钥那个账号）
const _targetUserId = 4;

String _marker(String kind) =>
    'flt-p9a-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：标签来源与 @u:<id> 提及', (tester) async {
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

    // ---------- 服务端能力：Post 到什么版本 ----------
    final postV4 = chat.supports('SYNO.Chat.Post', 4);
    debugPrint('[p9a] Post v4 = $postV4（决定提及写 @u:<id> 还是 @username）');

    // ---------- 建临时频道，把目标用户拉进来 ----------
    final tag = _marker('tag');
    final channel = await create.create(
      name: _marker('auto'),
      purpose: 'Phase 9 联想/提及验收',
      type: 'private',
      memberIds: const [_targetUserId],
    );
    final channelId = channel.channelId;
    expect(channelId, greaterThan(0));
    debugPrint('[p9a] 临时频道 #$channelId（成员含 $_targetUserId）');

    // ---------- ① 带 #tag 的消息 → 服务端标签列表 ----------
    final ok = await ctrl.sendMessage(channelId, '#$tag 标签验收');
    expect(ok, isTrue, reason: '发消息应当成功');
    List<String> tags = const [];
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      tags = await chat.channelHashtags(channelId);
      if (tags.contains(tag)) break;
    }
    debugPrint('[p9a] Channel.Hashtag/list = $tags');
    debugPrint('[p9a] 服务端${tags.contains(tag) ? "会" : "不会"}'
        '自动从正文里收标签');

    // 如果服务端不自动收，就用 Post.Hashtag/set 补一下，确认接口本身可用
    if (!tags.contains(tag)) {
      final posts = await chat.listPosts(channelId: channelId, prevCount: 10);
      final mine = posts.where((p) => '$p'.contains(tag)).toList();
      debugPrint('[p9a] 带标签的那条消息：${mine.isEmpty ? "没找到" : mine.first}');
      if (mine.isNotEmpty) {
        final postId = mine.first['post_id'] as int;
        await chat.setPostHashtag(postId: postId, hashtag: tag);
        tags = await chat.channelHashtags(channelId);
        debugPrint('[p9a] Post.Hashtag/set 之后 = $tags');
        expect(tags, contains(tag), reason: 'set 之后标签列表里应当有它');
      }
    } else {
      expect(tags, contains(tag));
    }

    // 落库 + 联想：进频道 → enter 里顺手刷新 → 输入 `#` 能提示出来
    final opened = await ctrl.enterChannel(channelId);
    expect(opened, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final cached = await ctrl.cachedChannelHashtags(channelId);
    debugPrint('[p9a] 本地缓存的标签 = $cached');
    expect(cached, contains(tag), reason: '进频道后标签要落到本地库（联想读它）');

    final users = await chat.listUsers();
    final channelNow = (await chat.listChannels())
        .where((c) => c.channelId == channelId)
        .firstOrNull;
    final candidates = mentionCandidates(users: users, channel: channelNow);
    debugPrint('[p9a] @ 候选（前 6 个）= '
        '${candidates.take(6).map((m) => "id=${m.userId} @${m.username}").toList()}');
    expect(candidates.any((m) => m.userId == _targetUserId), isTrue,
        reason: '真人用户应当在 @ 候选里');
    expect(candidates.first.userId, -2, reason: '非加密频道第一个是 @channel');
    expect(candidates[1].userId, -1, reason: '第二个是 @here');

    final filtered = filterAutocomplete(
      word: '@${users.firstWhere((u) => u.userId == _targetUserId).username}',
      fullText: '@x',
      slashCommands: users.where((u) => u.isSlashBot).toList(),
      hashtags: cached,
      mentions: candidates,
    );
    debugPrint('[p9a] 输入 @username 过滤结果 = '
        '${filtered.map((i) => i.label).toList()}');

    // ---------- ② `@u:<id>` 提及 ----------
    final target = users.firstWhere((u) => u.userId == _targetUserId);
    debugPrint('[p9a] 目标用户 #${target.userId} username=${target.username} '
        'nickname=${target.nickname}');
    debugPrint('[p9a] 频道 members=${channelNow?.members} '
        '（真机上 `Channel/list` 的 members 是否有值，决定 @ 候选的排序）');

    // 服务端会限流（`CHAT_ERR_SEND_TOO_FREQUENTLY` 411），两次发送之间要留间隔
    Future<void> throttle() =>
        Future<void>.delayed(const Duration(milliseconds: 2500));

    // ① 按原版的写法：`@u:<id>` 直接发
    final encoded = encodeMentions(
      '@${target.username} 按 id 提及',
      byUsername: {target.username: target.userId},
    );
    final viaUid = await chat.createPost(
      channelId: channelId,
      message: encoded,
      connId: container.read(chatSessionControllerProvider).connId!,
      type: 'normal',
    );
    debugPrint('[p9a] 发出 "$encoded" → 服务端返回 $viaUid');
    expect('${viaUid['message']}', contains('@u:${target.userId}'),
        reason: '服务端应当原样保留 @u:<id>');
    expect((viaUid['mentions'] as List?)?.contains(target.userId), isTrue,
        reason: '@u:<id> 必须被记成 mentions');

    await throttle();

    // ② 走 App 自己的发送链路（控制器会把 `@username` 编成 `@u:<id>`）
    final sent = await ctrl.sendMessage(
        channelId, '@${target.username} 走 App 链路');
    debugPrint('[p9a] 控制器 sendMessage = $sent');
    expect(sent, isTrue, reason: 'App 里发消息应当成功');

    await Future<void>.delayed(const Duration(milliseconds: 800));
    final posts = await chat.listPosts(channelId: channelId, prevCount: 30);
    for (final p in posts.where(
        (p) => '${p['message']}'.contains('提及') || '${p['message']}'.contains('链路'))) {
      debugPrint('[p9a] Post/list：post_id=${p['post_id']} '
          'message=${p['message']} mentions=${p['mentions']}');
    }
    final mine = posts.where((p) => '${p['message']}'.contains('链路')).toList();
    expect(mine, isNotEmpty, reason: '刚发的那条应当在列表里');
    final serverMessage = '${mine.first['message']}';
    debugPrint('[p9a] 服务端存的正文 = "$serverMessage"');

    // ③ 这个 `@u:<id>` 在我们自己的渲染里要变回可读名字
    final names = mentionNamesById(users);
    final segs = parseMessage(
      serverMessage,
      mentions: ((mine.first['mentions'] as List?) ?? const [])
          .map((e) => e is int ? e : int.tryParse('$e') ?? 0)
          .where((id) => id > 0)
          .toList(),
      mentionNames: names,
    );
    final rendered = segs
        .map((s) => switch (s) {
              MentionSegment(:final text) => text,
              PlainSegment(:final text) => text,
              HashtagSegment(:final text) => text,
              UrlSegment(:final url) => url,
            })
        .join();
    debugPrint('[p9a] 我们渲染成 = "$rendered"');
    expect(rendered, contains('@${target.username}'),
        reason: '`@u:<id>` 要换回 username 显示（原版 SpannableParser.parseMention）');
    expect(rendered, isNot(contains('@u:')), reason: '不该把 @u:<id> 直接显示出来');

    debugPrint('[p9a] ✅ 联想候选 / 标签落库 / 提及编码验收完成'
        '（人工看上面 mentions 是否记到了 ${target.userId}）');
  });
}
