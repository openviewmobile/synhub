// Phase 9 真机验收：投票的编辑 / 删除（`Post.Vote / set` + `delete`）。
//
//   flutter test integration_test/phase9_vote_manage_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_LIVE_POST=true
//
// 全流程走 App 自己的代码（`ChatSessionController` → `ChatApi`），真 NAS 2.4.7-22203：
//   ① 建临时私有频道 → 建一个投票（没人投）；
//   ② `set`（没人投票 = editable）：改问题 + 加一个选项 + 打开匿名/允许添加
//      → 回读 `Post/list` 确认**全都生效**；
//   ③ 投一票（票数 > 0）；
//   ④ 再 `set`（有人投票）：只发 options（把 allow_add_option 关掉）
//      → 回读确认**问题与选项没被改**、`add_option` 变 false；
//   ⑤ `delete` → 回读 `state == "delete"`（消息本身还在）；
//   ⑥ 关掉临时频道收尾。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/vote_dto.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/vote_editor.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

String _marker(String kind) =>
    'flt-p9v-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：投票编辑 / 删除', (tester) async {
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

    /// 从服务端回读某条消息（`Post/list`）
    Future<PostDto> fetchPost(int channelId, int postId) async {
      final raw = await chat.listPosts(channelId: channelId, prevCount: 30);
      final hit = raw.where((p) => p['post_id'] == postId).toList();
      expect(hit, isNotEmpty, reason: '服务端应当能查到 #$postId');
      return PostDto.fromJson(hit.first);
    }

    // ---------- ① 建临时频道 + 投票 ----------
    final chName = _marker('vote');
    final channel = await create.create(
      name: chName,
      purpose: 'Phase 9 投票编辑验收',
      type: 'private',
    );
    final channelId = channel.channelId;
    expect(channelId, greaterThan(0));
    debugPrint('[p9v] 临时频道 #$channelId 建好');

    final created = await chat.createVote(
      channelId: channelId,
      message: _marker('q'),
      choices: ['面条', '米饭'],
      multiple: false,
      anonymous: false,
      addOption: false,
      expireAt: 0,
    );
    final postId = (created['post_id'] as num).toInt();
    debugPrint('[p9v] 投票消息 #$postId 建好');

    var post = await fetchPost(channelId, postId);
    var vote = post.vote!;
    expect(vote.state, VoteState.open);
    expect(vote.choices.map((c) => c.text), ['面条', '米饭']);
    expect(vote.totalVotes, 0);
    final firstChoiceId = vote.choices.first.id;
    debugPrint('[p9v] 初始：${vote.choices.map((c) => "${c.id}:${c.text}").toList()} '
        'anonymous=${vote.anonymous} addOption=${vote.addOption}');

    // ---------- ② set（没人投票 = editable，全字段） ----------
    final newTitle = _marker('q2');
    final okEdit = await ctrl.editVote(
      channelId: channelId,
      post: post,
      message: newTitle,
      choices: [
        VoteChoiceDraft(id: firstChoiceId, text: '面条'),
        VoteChoiceDraft(text: '火锅'),
      ],
      multiple: false,
      anonymous: true,
      addOption: true,
      expireAt: 0,
    );
    expect(okEdit, isTrue, reason: '没人投票时 set 应当成功');

    post = await fetchPost(channelId, postId);
    vote = post.vote!;
    debugPrint('[p9v] set#1 之后：message=${post.message} '
        'choices=${vote.choices.map((c) => c.text).toList()} '
        'anonymous=${vote.anonymous} addOption=${vote.addOption}');
    expect(post.message, newTitle, reason: '没人投票时问题要能改');
    expect(vote.choices.map((c) => c.text), ['面条', '火锅'],
        reason: '既有选项保 id + 新选项要被服务端接受');
    expect(vote.choices.first.id, firstChoiceId, reason: '既有选项的 id 不能被换掉');
    expect(vote.anonymous, isTrue);
    expect(vote.addOption, isTrue);

    // ---------- ③ 投一票（让票数 > 0） ----------
    await chat.castVote(postId: postId, choiceIds: [firstChoiceId]);
    post = await fetchPost(channelId, postId);
    vote = post.vote!;
    expect(vote.totalVotes, greaterThan(0), reason: '投票后票数要 > 0');
    debugPrint('[p9v] 投票后 totalVotes=${vote.totalVotes}');

    // ---------- ④ set（有人投票 = 只发 options） ----------
    final frozenMessage = post.message;
    final frozenChoices = vote.choices.map((c) => c.text).toList();
    final okEdit2 = await ctrl.editVote(
      channelId: channelId,
      post: post,
      message: _marker('should-not-apply'),
      choices: [VoteChoiceDraft(id: firstChoiceId, text: '只留一个')],
      multiple: false,
      anonymous: true,
      addOption: false,
      expireAt: 0,
    );
    expect(okEdit2, isTrue);

    post = await fetchPost(channelId, postId);
    vote = post.vote!;
    debugPrint('[p9v] set#2 之后：message=${post.message} '
        'choices=${vote.choices.map((c) => c.text).toList()} '
        'addOption=${vote.addOption}');
    expect(post.message, frozenMessage, reason: '有人投票后问题不许改');
    expect(vote.choices.map((c) => c.text), frozenChoices,
        reason: '有人投票后选项不许改');
    expect(vote.addOption, isFalse, reason: 'options 仍然要能改（这条就是 options-only）');

    // ---------- ⑤ delete ----------
    final okDelete = await ctrl.deleteVote(channelId: channelId, post: post);
    expect(okDelete, isTrue);
    post = await fetchPost(channelId, postId);
    vote = post.vote!;
    debugPrint('[p9v] delete 之后：state=${vote.state.wire} '
        'message=${post.message}');
    expect(vote.state, VoteState.deleted);
    expect(post.message, frozenMessage, reason: '删投票不能把消息一起删掉');

    // ---------- ⑥ 收尾：关掉临时频道 ----------
    // 收尾：关掉临时私有频道（close 需要 conn_id，控制器内部会取）
    await ctrl.closeChannel(channelId);
    final gone = await chat.listChannels();
    expect(gone.any((c) => c.channelId == channelId), isFalse,
        reason: '临时频道要被关掉');
    debugPrint('[p9v] ✅ 投票 建-改-投-改-删 全流程通过，临时频道已收尾');
  });
}
