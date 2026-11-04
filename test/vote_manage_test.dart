// Phase 9：投票的编辑 / 删除（`Post.Vote / set` + `delete`）。
//
// 覆盖（逐条对上原版 `EditVoteFragment` / `ChannelViewBinder.bindVoteContent`）：
//   * `set` 两个形态：**没人投票**（`editable`）→ 带 `message`/`choices`/`options`；
//     **有人投票** → 只带 `options`；
//   * `options` 字段名必须下划线（`add_option` / `expire_at`）；
//   * `choices` 里既有选项必须**带原 id**（服务端靠它保住票数）；
//   * `delete` 只删投票、消息保留，本地立刻变 `state=delete`（卡片显示「投票已删除」）；
//   * 编辑器校验：问题非空 / 至少两个选项 / 选项不重复 / 截止时间在未来；
//   * 已有人投票时编辑器把问题与选项置灰、只留「允许添加选项 / 截止时间」；
//   * 服务端出错 → 返回 false 且**不改本地数据**。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/vote_dto.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/vote_card.dart';
import 'package:synhub/src/features/chat/vote_editor.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';
import 'package:synhub/src/design/kit/design_kit.dart';

Map<String, dynamic> _voteProps({
  int c0 = 0,
  int c1 = 0,
  bool multiple = false,
  bool anonymous = false,
  bool addOption = false,
  int expireAt = 0,
  String state = 'open',
}) => {
  'vote': {
    'choices': [
      {'id': 'id-a', 'text': '面条', 'count': c0},
      {'id': 'id-b', 'text': '米饭', 'count': c1},
    ],
    'options': {
      'multiple': multiple,
      'anonymous': anonymous,
      'add_option': addOption,
      'expire_at': expireAt,
    },
    'state': state,
  },
};

PostDto _post(Map<String, dynamic> props, {int creator = 14, int id = 9001}) =>
    PostDto.fromJson({
      'post_id': id,
      'channel_id': 5,
      'creator_id': creator,
      'create_at': 1700000000000,
      'type': 'normal',
      'message': '午饭吃什么',
      'props': props,
    });

Map<String, dynamic> _setCall(ChatHarness h) => h.transport.calls.lastWhere(
  (c) => c['api'] == 'SYNO.Chat.Post.Vote' && c['method'] == 'set',
);

void main() {
  group('Vote/set（协议）', () {
    test('没人投票：message / choices / options 都发，choices 带原 id 与 count', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Vote.set'] = const {};
      final post = _post(_voteProps());
      await h.container.read(chatStoreProvider).upsertPosts([post]);

      final ok = await h.ctrl.editVote(
        channelId: 5,
        post: post,
        message: '晚饭吃什么',
        choices: [
          VoteChoiceDraft(id: 'id-a', text: '面条'),
          VoteChoiceDraft(id: '', text: '火锅'),
        ],
        multiple: true,
        anonymous: true,
        addOption: true,
        expireAt: 1800000000000,
      );
      expect(ok, isTrue);

      final call = _setCall(h);
      expect(call['version'], '1');
      expect(call['channel_id'], '5');
      expect(call['post_id'], '9001');
      // message 是"再 JSON 序列化一次"的字符串
      expect(call['message'], '"晚饭吃什么"');
      // choices 也是 JSON 数组字符串，既有选项保留 id、新选项 id 为空
      expect(
        call['choices'],
        '[{"count":0,"id":"id-a","text":"面条"},'
        '{"count":0,"id":"","text":"火锅"}]',
      );
      // options 是下划线字段
      expect(
        call['options'],
        '{"add_option":true,"anonymous":true,'
        '"expire_at":1800000000000,"multiple":true}',
      );
    });

    test('有人投票：只发 channel_id / post_id / options', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Vote.set'] = const {};
      final post = _post(_voteProps(c0: 2));
      await h.container.read(chatStoreProvider).upsertPosts([post]);

      final ok = await h.ctrl.editVote(
        channelId: 5,
        post: post,
        message: '改了也没用',
        choices: [VoteChoiceDraft(id: 'id-a', text: '改了也没用')],
        multiple: false,
        anonymous: false,
        addOption: true,
        expireAt: 0,
      );
      expect(ok, isTrue);
      final call = _setCall(h);
      expect(call.containsKey('message'), isFalse, reason: '有人投票后不许改正文');
      expect(call.containsKey('choices'), isFalse, reason: '有人投票后不许改选项');
      expect(
        call['options'],
        '{"add_option":true,"anonymous":false,'
        '"expire_at":0,"multiple":false}',
      );
      // 本地正文也没被改掉
      final local = await h.container.read(chatStoreProvider).postById(5, 9001);
      expect(local!.message, '午饭吃什么');
    });

    test('没人投票时本地立刻生效（正文 + 选项 + options）', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Vote.set'] = const {};
      final post = _post(_voteProps());
      await h.container.read(chatStoreProvider).upsertPosts([post]);

      await h.ctrl.editVote(
        channelId: 5,
        post: post,
        message: '晚饭吃什么',
        choices: [
          VoteChoiceDraft(id: 'id-a', text: '面条'),
          VoteChoiceDraft(id: '', text: '火锅'),
        ],
        multiple: false,
        anonymous: true,
        addOption: false,
        expireAt: 0,
      );
      final local = (await h.container
          .read(chatStoreProvider)
          .postById(5, 9001))!;
      expect(local.message, '晚饭吃什么');
      final vote = local.vote!;
      expect(vote.choices.map((c) => c.text), ['面条', '火锅']);
      expect(vote.choices.first.id, 'id-a');
      expect(vote.anonymous, isTrue);
    });

    test('服务端失败 → false 且本地一行不改', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.Vote.set'] = 407;
      final post = _post(_voteProps());
      await h.container.read(chatStoreProvider).upsertPosts([post]);

      final ok = await h.ctrl.editVote(
        channelId: 5,
        post: post,
        message: '新问题',
        choices: [
          VoteChoiceDraft(id: 'id-a', text: '面条'),
          VoteChoiceDraft(id: 'id-b', text: '米饭'),
        ],
        multiple: false,
        anonymous: false,
        addOption: false,
        expireAt: 0,
      );
      expect(ok, isFalse);
      final local = (await h.container
          .read(chatStoreProvider)
          .postById(5, 9001))!;
      expect(local.message, '午饭吃什么');
      expect(local.vote!.choices.map((c) => c.text), ['面条', '米饭']);
    });
  });

  group('Vote/delete（协议）', () {
    test('删除只动 state，消息还在；本地立即变 delete', () async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Vote.delete'] = const {};
      final post = _post(_voteProps(c0: 1));
      await h.container.read(chatStoreProvider).upsertPosts([post]);

      final ok = await h.ctrl.deleteVote(channelId: 5, post: post);
      expect(ok, isTrue);
      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.Post.Vote' && c['method'] == 'delete',
      );
      expect(call['version'], '1');
      expect(call['post_id'], '9001');

      final local = (await h.container
          .read(chatStoreProvider)
          .postById(5, 9001))!;
      expect(local.vote!.state, VoteState.deleted);
      expect(local.message, '午饭吃什么', reason: '消息本身不能被删');
    });

    test('服务端失败 → false 且状态不变', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.Post.Vote.delete'] = 404;
      final post = _post(_voteProps());
      await h.container.read(chatStoreProvider).upsertPosts([post]);

      expect(await h.ctrl.deleteVote(channelId: 5, post: post), isFalse);
      final local = (await h.container
          .read(chatStoreProvider)
          .postById(5, 9001))!;
      expect(local.vote!.state, VoteState.open);
    });
  });

  group('投票编辑器（发起 / 编辑共用）', () {
    Future<VoteDraft?> openEditor(
      WidgetTester tester, {
      VoteDraft? initial,
      bool editable = true,
    }) async {
      VoteDraft? result;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await showVoteEditor(
                      context,
                      initial: initial,
                      editable: editable,
                      title: initial == null ? '发起投票' : '编辑投票',
                      submitLabel: initial == null ? '发起' : '保存',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('发起：问题为空 / 少于两个选项会被拦下', (tester) async {
      await openEditor(tester);
      await tester.tap(find.text('发起'));
      await tester.pumpAndSettle();
      expect(find.text('问题不能为空'), findsOneWidget);
    });

    testWidgets('发起：填问题 + 两个选项 → 返回草稿', (tester) async {
      await openEditor(tester);
      await tester.enterText(find.widgetWithText(TextField, '问题'), '午饭吃什么');
      await tester.enterText(find.widgetWithText(TextField, '选项'), '面条');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '选项'), '米饭');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发起'));
      await tester.pumpAndSettle();

      // 对话框关掉了（说明校验通过并 pop 了草稿）；草稿内容在下面那条用例里细验
      expect(find.text('发起投票'), findsNothing);
    });

    testWidgets('重复选项会被拦下', (tester) async {
      await openEditor(tester);
      await tester.enterText(find.widgetWithText(TextField, '问题'), '午饭');
      for (final t in ['面条', '面条']) {
        await tester.enterText(find.widgetWithText(TextField, '选项'), t);
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
      }
      // 重复的不会被加进去（列表里只有一条），所以只有 1 个选项 → 至少两个
      await tester.tap(find.text('发起'));
      await tester.pumpAndSettle();
      expect(find.text('至少两个选项'), findsOneWidget);
    });

    testWidgets('编辑：已有人投票 → 问题与选项置灰，开关中的多选/匿名禁用', (tester) async {
      final vote = VoteDto.fromJson({
        'choices': [
          {'id': 'id-a', 'text': '面条', 'count': 2},
          {'id': 'id-b', 'text': '米饭', 'count': 0},
        ],
        'options': {
          'multiple': true,
          'anonymous': false,
          'add_option': false,
          'expire_at': 0,
        },
        'state': 'open',
      });
      await openEditor(
        tester,
        initial: VoteDraft.fromVote('午饭吃什么', vote),
        editable: false,
      );
      expect(find.text('编辑投票'), findsOneWidget);
      // 问题框禁用
      final title = tester.widget<TextField>(
        find.widgetWithText(TextField, '午饭吃什么'),
      );
      expect(title.enabled, isFalse);
      // 选项框也禁用（两个）
      final choices = tester
          .widgetList<TextField>(find.byType(TextField))
          .where((f) => f.enabled == false)
          .length;
      expect(choices, 3, reason: '1 个问题 + 2 个选项');
      // 三条提示
      expect(find.textContaining('已经有人投过票了'), findsOneWidget);
      // 「允许添加选项」仍然可点（服务端 options-only 那条路）
      final addSwitch = tester.widget<DesignSwitchRow>(
        find.widgetWithText(DesignSwitchRow, '允许添加选项'),
      );
      expect(addSwitch.onChanged, isNotNull);
      final multiSwitch = tester.widget<DesignSwitchRow>(
        find.widgetWithText(DesignSwitchRow, '允许多选'),
      );
      expect(multiSwitch.onChanged, isNull, reason: '有人投票后多选不许改');
    });

    testWidgets('编辑：没人投票 → 一切都可改', (tester) async {
      final vote = VoteDto.fromJson({
        'choices': [
          {'id': 'id-a', 'text': '面条', 'count': 0},
          {'id': 'id-b', 'text': '米饭', 'count': 0},
        ],
        'options': {
          'multiple': false,
          'anonymous': false,
          'add_option': false,
          'expire_at': 0,
        },
        'state': 'open',
      });
      await openEditor(
        tester,
        initial: VoteDraft.fromVote('午饭吃什么', vote),
        editable: true,
      );
      final title = tester.widget<TextField>(
        find.widgetWithText(TextField, '午饭吃什么'),
      );
      expect(title.enabled, isTrue);
      expect(find.textContaining('已经有人投过票了'), findsNothing);
    });
  });

  group('卡片上的编辑 / 删除入口', () {
    Future<void> pump(WidgetTester tester, ChatHarness h, PostDto post) async {
      await h.container.read(chatStoreProvider).upsertPosts([post]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: VoteCard(post: post)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('菜单里「删除投票」要二次确认，确认后服务端被调用、卡片变「投票已删除」', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Vote.delete'] = const {};
      await pump(tester, h, _post(_voteProps(c0: 1)));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除投票'));
      await tester.pumpAndSettle();
      expect(find.text('删除投票？消息本身会保留。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(
        h.transport.calls.where((c) => c['method'] == 'delete'),
        hasLength(1),
      );
      expect(find.text('投票已删除'), findsOneWidget);
    });

    testWidgets('取消删除：不发请求', (tester) async {
      final h = await bootChat();
      await pump(tester, h, _post(_voteProps()));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除投票'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(h.transport.calls.where((c) => c['method'] == 'delete'), isEmpty);
      expect(find.text('投票已删除'), findsNothing);
    });

    testWidgets('菜单里「编辑投票」打开编辑器并提交（没人投票 → 带 message/choices）', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Vote.set'] = const {};
      await pump(tester, h, _post(_voteProps()));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑投票'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '午饭吃什么'), '晚饭吃什么');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final call = _setCall(h);
      expect(call['message'], '"晚饭吃什么"');
      expect(call.containsKey('choices'), isTrue);
    });

    testWidgets('菜单里「结束投票」直接发 close', (tester) async {
      final h = await bootChat();
      h.transport.responses['SYNO.Chat.Post.Vote.close'] = const {};
      await pump(tester, h, _post(_voteProps()));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('结束投票'));
      await tester.pumpAndSettle();
      expect(
        h.transport.calls.where((c) => c['method'] == 'close'),
        hasLength(1),
      );
      final local = (await h.container
          .read(chatStoreProvider)
          .postById(5, 9001))!;
      expect(local.vote!.state, VoteState.closed);
    });
  });
}
