// Phase 6/8：提醒到点 → 本地通知（离线）。
//
// 我们不用 FCM，原版的「到点推送」只能自己顶上，所以这里钉住的是**账本逻辑**：
//   * 到点弹、弹过就记账、不重复弹；
//   * 未来的不弹，但要按最近一条排下一次扫描（最长 60s 醒一次）；
//   * 进程重启（新实例）后：已弹过的不重弹，没弹过的补弹（catch-up）；
//   * 取消提醒、服务端回读校准（`Reminder/list` 是权威）；
//   * 免打扰期间压着不弹**也不记账**（免得免打扰结束后就永远收不到了）。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/notifications/reminder_scheduler.dart';
import 'package:synhub/src/features/settings/snooze_controller.dart';

import 'support/chat_harness.dart';
import 'support/fake_background.dart';

const int kChannel = 5;
const int kPost = 4294967300;

PostDto _post({
  int id = kPost,
  int channelId = kChannel,
  String message = '要不要一起吃饭',
  Map<String, dynamic> props = const {},
}) => PostDto.fromJson({
  'post_id': id,
  'channel_id': channelId,
  'creator_id': 4,
  'create_at': 2000,
  'type': 'normal',
  'message': message,
  'props': props,
});

/// 造环境：假原生通知层 + 把测试消息塞进本地库 + 一个调度器
Future<({ReminderScheduler sched, FakeBackground bg})> _env(
  ChatHarness h, {
  FakeBackground? bg,
  PostDto? post,
}) async {
  final b = bg ?? FakeBackground();
  await h.container.read(chatStoreProvider).upsertPosts([post ?? _post()]);
  final sched = ReminderScheduler(
    h.container.read(reminderSchedulerProvider).ref,
    background: b,
    autoScan: false, // 用例自己决定什么时候扫
  );
  addTearDown(sched.stop);
  return (sched: sched, bg: b);
}

void main() {
  // 平台语言钉成中文：这两条通知文案走 `platformText()`（系统级跟平台语言），
  // 测试环境默认是 en-US，不钉住的话断言中文会红（见 docs/app-identity-and-i18n.md §4.6）。
  setUp(() {
    // `locale` 与 `locales` 都要钉：语言协商读的是 `locales`
    final pd = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
    pd.localeTestValue = const Locale('zh');
    pd.localesTestValue = const [Locale('zh')];
  });
  tearDown(() {
    final pd = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
    pd.clearLocaleTestValue();
    pd.clearLocalesTestValue();
  });
  test('到点弹一条、记账、不重复弹', () async {
    final h = await bootChat();
    final e = await _env(h);
    final now = DateTime.now();
    await e.sched.arm(
      postId: kPost,
      channelId: kChannel,
      remindAt: now
          .subtract(const Duration(seconds: 30))
          .millisecondsSinceEpoch,
    );
    // 还没扫之前不该弹
    expect(e.bg.shown, isEmpty);

    expect(await e.sched.scan(now: now), 1);
    final n = e.bg.shown.single;
    expect(n.postId, kPost);
    expect(n.channelId, kChannel);
    expect(n.title, contains('测试频道'));
    expect(n.text, '嗨！以下是您关于「要不要一起吃饭」的提醒。');
    expect(n.canReply, isFalse, reason: '提醒通知不给「回复」按钮');

    // 账本：从"待弹"挪到"已弹"
    expect(e.sched.armed, isEmpty);
    final settings = h.container.read(settingsServiceProvider);
    expect(await settings.firedReminders(), contains(kPost));

    // 再扫不会重复
    expect(await e.sched.scan(now: now), 0);
    expect(e.bg.shown, hasLength(1));
  });

  test('未来的提醒不弹，并按最近一条排下一次扫描', () async {
    final h = await bootChat();
    final e = await _env(h);
    final now = DateTime.now();
    await e.sched.arm(
      postId: kPost,
      channelId: kChannel,
      remindAt: now.add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    );
    expect(await e.sched.scan(now: now), 0);
    expect(e.bg.shown, isEmpty);
    expect(e.sched.armed, contains(kPost), reason: '还留着，到点再说');
    // 10 分钟后到点 → 但定时器最长 60s 醒一次
    expect(e.sched.nextDelay, kMaxReminderSleep);

    // 很近的提醒就按实际差值排（+200ms 余量）
    await e.sched.arm(
      postId: kPost,
      channelId: kChannel,
      remindAt: now.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
    );
    await e.sched.scan(now: now);
    expect(e.sched.nextDelay!.inMilliseconds, inInclusiveRange(5000, 5400));
  });

  test('进程重启：已弹的不重弹，没弹过的补弹（catch-up）', () async {
    final h = await bootChat();
    final e = await _env(h);
    final now = DateTime.now();

    // ① 第一次运行，到点弹掉
    await e.sched.arm(
      postId: kPost,
      channelId: kChannel,
      remindAt: now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
    );
    expect(await e.sched.scan(now: now), 1);

    // ② "重启"：换一个调度器实例（内存全没了，只剩库里的账）
    final bg2 = FakeBackground();
    final sched2 = ReminderScheduler(
      h.container.read(reminderSchedulerProvider).ref,
      background: bg2,
      autoScan: false,
    );
    addTearDown(sched2.stop);
    expect(await sched2.scan(now: now), 0, reason: '已经弹过的不重弹');
    expect(bg2.shown, isEmpty);

    // ③ 进程被杀期间到点的那条：启动补弹
    await h.container.read(chatStoreProvider).upsertPosts([
      _post(id: 4294967999, message: '买菜'),
    ]);
    await sched2.arm(
      postId: 4294967999,
      channelId: kChannel,
      remindAt: now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
    );
    final bg3 = FakeBackground();
    final sched3 = ReminderScheduler(
      h.container.read(reminderSchedulerProvider).ref,
      background: bg3,
      autoScan: false,
    );
    addTearDown(sched3.stop);
    expect(await sched3.scan(now: now), 1);
    expect(bg3.shown.single.text, contains('买菜'));
  });

  test('取消提醒 / 服务端回读校准', () async {
    final h = await bootChat();
    final e = await _env(h);
    final now = DateTime.now();
    final past = now
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch;

    // arm → disarm → 不弹
    await e.sched.arm(postId: kPost, channelId: kChannel, remindAt: past);
    await e.sched.disarm(kPost);
    expect(await e.sched.scan(now: now), 0);
    expect(e.bg.shown, isEmpty);

    // 回读校准：服务端只剩一条 → 本地多出来的要被清掉
    await e.sched.arm(postId: kPost, channelId: kChannel, remindAt: past);
    await e.sched.arm(
      postId: 4294967555,
      channelId: kChannel,
      remindAt: now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
    await e.sched.reconcileChannel(kChannel, [
      _post(
        id: 4294967555,
        props: {
          'remind_at': now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        },
      ),
    ]);
    expect(e.sched.armed.keys, [4294967555]);

    // 服务端把提醒抹了（列表变空）→ 本地也清空
    await e.sched.reconcileChannel(kChannel, const []);
    expect(e.sched.armed, isEmpty);
  });

  test('免打扰期间压着不弹、也不记账（免打扰过后补弹）', () async {
    final h = await bootChat();
    final e = await _env(h);
    final now = DateTime.now();
    await h.container
        .read(snoozeControllerProvider.notifier)
        .setSnooze(const Duration(hours: 1));

    await e.sched.arm(
      postId: kPost,
      channelId: kChannel,
      remindAt: now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
    );
    expect(await e.sched.scan(now: now), 0);
    expect(e.bg.shown, isEmpty);
    expect(e.sched.pendingDue, 1);
    expect(e.sched.armed, contains(kPost), reason: '还在账上，别记账');
    expect(
      await h.container.read(settingsServiceProvider).firedReminders(),
      isNot(contains(kPost)),
    );
    expect(e.sched.nextDelay, kMinReminderSleep, reason: '压着 → 快点再看一眼');

    // 免打扰结束（`Duration.zero` = 立刻结束）→ 补弹
    await h.container
        .read(snoozeControllerProvider.notifier)
        .setSnooze(Duration.zero);
    expect(await e.sched.scan(now: now), 1);
    expect(e.bg.shown.single.postId, kPost);
  });

  test('同一条消息再设一次提醒：能再弹（清掉"已弹"记账）', () async {
    final h = await bootChat();
    final e = await _env(h);
    final now = DateTime.now();
    await e.sched.arm(
      postId: kPost,
      channelId: kChannel,
      remindAt: now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
    );
    expect(await e.sched.scan(now: now), 1);

    // 用户又对同一条消息设了提醒（比如"过 10 分钟再提醒我一次"）
    final again = now.add(const Duration(minutes: 10)).millisecondsSinceEpoch;
    await e.sched.arm(postId: kPost, channelId: kChannel, remindAt: again);
    expect(e.sched.armed, contains(kPost));
    expect(
      await h.container.read(settingsServiceProvider).firedReminders(),
      isNot(contains(kPost)),
      reason: '新一轮要把旧的"已弹"记账撤掉',
    );
    expect(
      await e.sched.scan(
        now: DateTime.fromMillisecondsSinceEpoch(again + 1000),
      ),
      1,
      reason: '到点要能再弹一次',
    );
    expect(e.bg.shown, hasLength(2));
  });

  test('通知文案：没有正文时给通用说法（原版 system_remind_msg）', () {
    expect(reminderNotificationText(''), '嗨！以下是您关于这条消息的提醒。');
    expect(reminderNotificationText('买菜'), '嗨！以下是您关于「买菜」的提醒。');
  });
}
