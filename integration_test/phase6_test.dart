// Phase 6 真机验收：搜索 / 投票 / 提醒 / 定时消息。
//
//   flutter test integration_test/phase6_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_LIVE_POST=true
//
// 只写 `flt-p6-` 前缀的消息，跑完自己删；定时消息按 cronjob_id 删。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/vote_dto.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/notifications/notification_service.dart';
import 'package:synhub/src/features/notifications/reminder_scheduler.dart';
import 'package:synhub/src/features/search/search_page.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _postRaw = String.fromEnvironment('SYNO_LIVE_POST');
final _doPost = _postRaw == '1' || _postRaw == 'true';

String _marker(String kind) =>
    'flt-p6-$kind-${DateTime.now().millisecondsSinceEpoch}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 6 真机：搜索 + 投票 + 提醒 + 定时消息', (tester) async {
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
    await ctrl.start(conn);
    final sync = container.read(chatSessionControllerProvider);
    expect(sync.phase, ChatSyncPhase.ready);
    final store = container.read(chatStoreProvider);

    final channels = await store.allChannels();
    final target = channels.firstWhere((c) => !c.encrypted && c.isJoined,
        orElse: () => channels.first);
    final channelId = target.channelId;
    debugPrint('[p6] 频道=#$channelId 我=#${sync.myUserId}');

    final created = <int>[];
    final cronjobs = <int>[];
    final tagStamp = DateTime.now().millisecondsSinceEpoch;
    addTearDown(() async {
      for (final id in created) {
        try {
          await chat.deletePost(id);
        } catch (_) {}
      }
      for (final id in cronjobs) {
        try {
          await chat.deleteScheduledPost(id);
        } catch (_) {}
      }
    });

    if (!_doPost) {
      debugPrint('[p6] SYNO_LIVE_POST 未开：只跑搜索/提醒列表读接口');
    }

    // ---------- ① 搜索（关键词 + star + post_type=file） ----------
    final kw = _marker('kw');
    if (_doPost) {
      final p = await chat.createPost(
          channelId: channelId, connId: sync.connId!, message: '$kw 搜索测试');
      created.add((p['post_id'] as num).toInt());
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    final byKeyword = await chat.searchPosts(PostSearchQuery(keyword: kw));
    final found =
        byKeyword.posts.where((p) => '${p['message']}'.contains(kw));
    // 只读模式（`SYNO_LIVE_POST` 未开）下这条消息**根本没发出去**，所以"搜不到"
    // 才是对的 —— 原来无条件断言 `isNotEmpty`，读完接口就被自己的前提打红。
    // 两种模式下都真在验"搜索接口如实作答"，没有放宽断言。
    expect(found, _doPost ? isNotEmpty : isEmpty,
        reason: _doPost
            ? '关键词搜索应该能搜到 $kw'
            : '只读模式没发过 $kw，搜不到才是对的');
    debugPrint('[p6] 关键词搜索 → ${byKeyword.total} 条，命中 ${found.length}');

    final starQuery = await chat
        .searchPosts(const PostSearchQuery(has: ['star'], limit: 5));
    debugPrint('[p6] has=[star] → ${starQuery.posts.length} 条');

    // 搜索控制器（界面用的那条路径）
    final sc = container.read(searchControllerProvider.notifier);
    sc.setQuery(PostSearchQuery(keyword: kw));
    await sc.search();
    final sstate = container.read(searchControllerProvider);
    expect(sstate.posts.any((p) => p.message.contains(kw)), _doPost ? isTrue : isFalse,
        reason: _doPost ? 'SearchController 也要能搜到' : '只读模式下不该搜到 $kw');
    debugPrint('[p6] SearchController 命中 ${sstate.posts.length} 条 ✓');

    // ---------- ② 投票 ----------
    if (_doPost) {
      final voteMsg = _marker('vote');
      // 建投票（料 5 秒，Post/create 之后立刻建投票会吃 411）
      await Future<void>.delayed(const Duration(seconds: 5));
      final ok = await ctrl.createVote(
        channelId: channelId,
        message: '$voteMsg 午饭吃什么',
        choices: const ['面条', '米饭', '随便'],
        multiple: false,
        addOption: true,
      );
      expect(ok, isTrue, reason: '建投票失败（可能 411 太频繁）');
      await Future<void>.delayed(const Duration(seconds: 2));

      final mine = await store.postsForChannel(channelId, limit: 50);
      final votePost = mine.firstWhere((p) => p.message == '$voteMsg 午饭吃什么');
      created.add(votePost.postId);
      var vote = votePost.vote;
      expect(vote, isNotNull, reason: '投票应该在 props.vote 里');
      expect(vote!.choices, hasLength(3));
      expect(vote.addOption, isTrue);
      expect(vote.state, VoteState.open);
      debugPrint('[p6] 投票 #${votePost.postId} 选项=${vote.choices.length} ✓');

      // 服务端单选：投第一项
      final first = vote.choices.first.id;
      expect(
        await ctrl.castVote(
            channelId: channelId, post: votePost, choiceIds: [first]),
        isTrue,
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      await ctrl.refreshVoteChoices(channelId: channelId, post: votePost);
      vote = (await store.postById(channelId, votePost.postId))!.vote!;
      final votedCount = vote.choices.fold(0, (s, c) => s + c.count);
      expect(votedCount, greaterThanOrEqualTo(1), reason: '票数应该涨上去');
      expect(vote.choices.first.count, greaterThanOrEqualTo(1));
      debugPrint('[p6] 投票后票数=$votedCount '
          'voters=${vote.choices.first.voters} ✓');

      // 结束投票
      final latest = (await store.postById(channelId, votePost.postId))!;
      expect(await ctrl.closeVote(channelId: channelId, post: latest), isTrue);
      await Future<void>.delayed(const Duration(seconds: 2));
      final closed = (await store.postById(channelId, votePost.postId))!.vote!;
      expect(closed.state, VoteState.closed);
      debugPrint('[p6] 结束投票 → ${closed.state.wire} ✓');
    }

    // ---------- ③ 提醒 ----------
    if (_doPost) {
      final remindMsg = _marker('remind');
      await Future<void>.delayed(const Duration(seconds: 5));
      final raw = await chat.createPost(
          channelId: channelId, connId: sync.connId!, message: remindMsg);
      final remindPostId = (raw['post_id'] as num).toInt();
      created.add(remindPostId);
      if (await store.postById(channelId, remindPostId) == null) {
        await ctrl.loadPosts(channelId, force: true, aroundPostId: remindPostId);
      }
      final post = (await store.postById(channelId, remindPostId))!;

      final at = DateTime.now().add(const Duration(hours: 2));
      expect(
        await ctrl.setReminder(
            channelId: channelId, post: post, remindAt: at.millisecondsSinceEpoch),
        isTrue,
      );
      expect((await store.postById(channelId, remindPostId))!.remindAt,
          at.millisecondsSinceEpoch);
      // 服务端读回来
      expect(await chat.reminderAt(remindPostId), at.millisecondsSinceEpoch);
      final list = await ctrl.listReminders(channelId);
      expect(list.any((p) => p.postId == remindPostId), isTrue,
          reason: 'Reminder/list 应该包含刚设的那条');
      debugPrint('[p6] 提醒 #$remindPostId = ${at.toIso8601String()} ✓');
      final latest1 = (await store.postById(channelId, remindPostId))!;

      // ---- 到点弹本地通知（原版靠 FCM 推送，我们不用 FCM，见 ReminderScheduler）----
      // 设一个 20 秒后到点的提醒，退到后台等着，看系统里是不是真挂出一条通知，
      // 文案是不是原版那句 `system_remind_msg`。
      final soon = DateTime.now().add(const Duration(seconds: 20));
      expect(
        await ctrl.setReminder(
            channelId: channelId,
            post: latest1,
            remindAt: soon.millisecondsSinceEpoch),
        isTrue,
      );
      final scheduler = container.read(reminderSchedulerProvider);
      expect(scheduler.armed[remindPostId]?.remindAt,
          soon.millisecondsSinceEpoch,
          reason: '设完提醒要排进本地账本');
      final notifService = container.read(notificationServiceProvider);
      notifService.appInForeground = false; // 假装退到后台
      debugPrint('[p6] 提醒改成 20 秒后到点，等通知…');
      await Future<void>.delayed(const Duration(seconds: 25));

      final active = await container.read(backgroundServiceProvider).activeTags();
      final mine = active.where((n) => n.title.contains('提醒')).toList();
      expect(mine, isNotEmpty,
          reason: '到点后系统通知栏里应该挂着一条「提醒」（原版靠 FCM 推送）');
      debugPrint('[p6] 通知标题=${mine.first.title}');
      debugPrint('[p6] 通知正文=${mine.first.text}');
      expect(mine.first.text, contains(remindMsg),
          reason: '正文是原版 system_remind_msg 句式 + 原消息内容');
      expect(scheduler.armed, isNot(contains(remindPostId)),
          reason: '弹过就从"待弹"挪走');
      expect(
        await container
            .read(settingsServiceProvider)
            .firedReminders(),
        contains(remindPostId),
        reason: '弹过要记账，重启不重弹',
      );
      debugPrint('[p6] 到点弹本地通知 ✓');
      // 通知栏清干净，别留给下一轮用例
      await container.read(backgroundServiceProvider).cancelAll();

      final latestReminder = (await store.postById(channelId, remindPostId))!;
      expect(
        await ctrl.clearReminder(channelId: channelId, post: latestReminder),
        isTrue,
      );
      expect((await store.postById(channelId, remindPostId))!.remindAt, 0);
      expect(scheduler.armed, isNot(contains(remindPostId)));
      debugPrint('[p6] 取消提醒 ✓');
    }

    // ---------- ④ 定时消息 ----------
    if (_doPost) {
      final sendAt =
          DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch;
      final id = await ctrl.createScheduledPost(
          channelId: channelId,
          message: '${_marker('sched')} 一年后发',
          sendAt: sendAt);
      expect(id, greaterThan(0), reason: 'Schedule/create 应该回 cronjob_id');
      cronjobs.add(id);
      final list = await ctrl.listScheduledPosts(channelId);
      expect(list.any((s) => s.cronjobId == id), isTrue);
      await ctrl.deleteScheduledPost(id);
      cronjobs.remove(id);
      final after = await ctrl.listScheduledPosts(channelId);
      expect(after.any((s) => s.cronjobId == id), isFalse);
      debugPrint('[p6] 定时消息 create/list/delete ✓');
    }

    // ---------- ⑤ 标签 ----------
    if (_doPost) {
      final tag = 'flt-tag-$tagStamp';
      final tagMsg = _marker('tag');
      await Future<void>.delayed(const Duration(seconds: 5));
      final raw = await chat.createPost(
          channelId: channelId, connId: sync.connId!, message: tagMsg);
      final tagPostId = (raw['post_id'] as num).toInt();
      created.add(tagPostId);
      await Future<void>.delayed(const Duration(seconds: 2));
      // 这条是用裸 API 建的，本地库还没有，先拉一次（hashtag 要 post_id 就够，
      // 但控制器还要拿 post 去更新本地 hashtags）
      if (await store.postById(channelId, tagPostId) == null) {
        await ctrl.loadPosts(channelId, force: true, aroundPostId: tagPostId);
      }
      final post = (await store.postById(channelId, tagPostId))!;
      expect(await ctrl.setPostHashtag(
          channelId: channelId, post: post, hashtag: tag), isTrue);
      final tags = await ctrl.channelHashtags(channelId);
      expect(tags, contains(tag), reason: 'Channel.Hashtag/list 应该能看到刚加的标签');
      // 按标签搜（服务端 hashtags 过滤）
      final byTag = await chat.searchPosts(PostSearchQuery(hashtags: [tag]));
      expect(byTag.posts, isNotEmpty, reason: '按 hashtags 过滤应该能搜到');
      debugPrint('[p6] 标签 #$tag → 频道标签 ${tags.length} 个，搜索 ${byTag.posts.length} 条 ✓');

      final tagged = (await store.postById(channelId, tagPostId))!;
      expect(await ctrl.deletePostHashtag(
          channelId: channelId, post: tagged, hashtag: tag), isTrue);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(await ctrl.channelHashtags(channelId), isNot(contains(tag)));
      debugPrint('[p6] 移除标签 ✓');
    }

    // ---------- ⑥ 机器人 / 斜杠命令 / 归档 ----------
    final users = await chat.listUsers();
    final slashBots = users.where((u) => u.isSlashBot).toList();
    final chatBots = users.where((u) => u.isListedBot).toList();
    debugPrint('[p6] 用户 ${users.length}：斜杠命令=${slashBots.map((u) => '/${u.slashCmd}').toList()} '
        '机器人=${chatBots.map((u) => '${u.displayName}(${u.botType})').toList()}');
    expect(users.any((u) => u.isBot), isTrue, reason: 'User/list type=bot 应该有机器人');
    debugPrint('[p6] 屏蔽列表=${await ctrl.blockedBots()}');
    final archives = await ctrl.listArchives();
    debugPrint('[p6] 归档频道 ${archives.length} 个（type=encrypted）');

    // 跟 synobot 开一对一（原 App 的"机器人会话"路径：先查本地 chatbot/synobot 频道）
    final synobot = users.where((u) => u.botType == 'synobot').toList();
    if (synobot.isNotEmpty) {
      final botChannel = await ctrl.initiateChatbot(synobot.first.userId);
      debugPrint('[p6] 打开 synobot 会话 → 频道 #$botChannel');
      // 这台 NAS 上 synobot 的频道（type=synobot）应该已经在本地库里，
      // 所以这里不该退化成"打接口"（接口对已有机器人会回 101/117）
      expect(botChannel, greaterThan(0), reason: '应该定位到 synobot 的频道');
    }

    // 真·chatbot：`Chatbot/initiate`（`user_id` 发 Gson 编码的字符串），
    // 返回的是**完整频道对象**（type=chatbot，members=[我, bot]）而不是包一层
    final chatBotsOnly =
        users.where((u) => u.botType == 'chatbot' && !u.isDisabled).toList();
    if (chatBotsOnly.isNotEmpty) {
      final bot = chatBotsOnly.first;
      final first = await ctrl.initiateChatbot(bot.userId);
      expect(first, greaterThan(0), reason: 'initiate 应该返回 channel_id');
      final channel = (await store.allChannels())
          .firstWhere((c) => c.channelId == first);
      expect(channel.type, 'chatbot');
      expect(channel.members, contains(bot.userId));
      debugPrint('[p6] initiate(${bot.displayName}) → #$first '
          'type=${channel.type} members=${channel.members} ✓');
      // 再来一次：这次应该走"本地已有频道"，返回同一个 id
      expect(await ctrl.initiateChatbot(bot.userId), first,
          reason: '第二次应该是本地命中同一个频道');
      debugPrint('[p6] 二次打开命中同一频道 ✓');
    }

    // ---------- ⑦ 清理 ----------
    for (final id in [...created]) {
      try {
        await chat.deletePost(id);
      } catch (_) {}
    }
    created.clear();
    debugPrint('[p6] 清理完成 ✓');
  }, timeout: const Timeout(Duration(minutes: 12)));
}
