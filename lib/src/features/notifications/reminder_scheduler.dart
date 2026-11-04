// 提醒到点 → 本地通知（Phase 6 的「提醒我」在 Phase 8 的通知体系上落地）。
//
// ## 为什么需要它
//
// 原版把「提醒」做在**服务端 + FCM**：`Post.Reminder/set` 只是把 `remind_at`
// 写进这条消息的 `props`；到点后服务端发一条推送（FCM）让客户端弹通知，顺手把
// `remind_at` 抹掉（真机实测：到期后 `Reminder/list` 就空了，而且**不会**在频道里
// 生成任何新消息 —— 反编译里 `Post.viewType()==110` 那条 `forward.type=="reminder"`
// 分支在 2.4.7 上根本走不到）。
//
// 我们明确不用 FCM（用户拍板：本地通知 + 前台常驻 Socket），所以「到点」这件事
// 只能自己盯着 —— 服务端不会通知我们，而且它到期就把 `remind_at` 抹了，
// 连"该提醒了"都无从查起。因此必须在**本地**留一份账：
//
//   1. 我自己 `Reminder/set` 成功、或收到 `post.reminder.set` 广播、
//      或 `Reminder/list` 回读（权威）→ `arm()` 记下 `{post_id → 频道 + 到点时间}`；
//   2. 到点 → 弹本地通知，条目从"待弹"挪到"已弹"（`notified_reminders`，持久化）；
//   3. 进程被杀/重启 → 启动时扫一遍，把"已过期但没弹过"的补弹（宁可晚到不能丢，
//      这正是原版推送会丢的场景）。
//
// ## 为什么不用"直接扫本地 `props.remind_at`"
//
// 提醒是**每个用户私有**的：`Reminder/list` 只回自己的，`Post/list` 里别人的消息
// 连 `remind_at` 字段都不带。如果无脑扫 props，一旦服务端把 `post.reminder.set`
// 广播给了整频道，我们就会替别人弹提醒。所以只认"我自己那一份账"。
//
// ## 取舍
//
// * **不做秒级精确**：定时器最长 [kMaxReminderSleep]（60s）就醒一次重新扫，
//   最坏晚 60 秒；换来"改时间/删除/时钟漂移/进程挂起恢复"都不用额外补偿逻辑。
// * **贪睡（snooze）期间不弹**：原版静音靠"服务端不推"，我们自己判（跟
//   `NotificationService.maybeNotify` 同一套 `SnoozeController`）。压着的**不记账**，
//   等免打扰过去再补弹。
// * 通知复用消息通知的原生通道（`MessageNotification`，tag 按频道+话题聚合），
//   点通知直接跳到那条消息；代价是它跟该频道的消息通知共用一个坑位。
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/settings/app_settings.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/post_dto.dart';
import '../../native/background_service.dart';
import '../chat/chat_session_controller.dart';
import '../settings/e2ee_controller.dart';
import '../settings/snooze_controller.dart';
import 'notification_service.dart';

/// 一次扫描最多补弹几条（防止积压几百条时一次炸一堆通知）
const int kMaxReminderBatch = 5;

/// 定时器最长睡多久就醒一次重新扫（见文件头"取舍"）
const Duration kMaxReminderSleep = Duration(seconds: 60);

/// 扫描间隔下限（免得密集重排把自己转晕）
const Duration kMinReminderSleep = Duration(seconds: 1);

/// 提醒通知的标题（原版只有正文文案，标题来自推送 payload）。
///
/// 通知栏拿不到 widget context，走 `platformText()` 跟随平台语言。
String get kReminderTitle => platformText().notifyReminderTitle;

/// 原版文案：`system_remind_msg` = 「嗨！以下是您关于 { 此信息 } 的提醒。」
///
/// 原版这里是个带跳转链接的格式化串（「此信息」可点，跳到原消息）；通知里放不了
/// 富文本链接，所以我们把原消息正文直接拼进引号里（点整条通知就跳过去）。
///
/// 走 `platformText()`（系统级文案跟平台语言；离线用例里把平台语言钉成 zh）。
String reminderNotificationText(String originPreview) {
  final t = platformText();
  return originPreview.isEmpty
      ? t.notifyReminderBody
      : t.notifyReminderBodyWith(originPreview);
}

/// 一条"已排期、还没弹"的提醒
@immutable
class ArmedReminder {
  const ArmedReminder({
    required this.postId,
    required this.channelId,
    required this.remindAt,
  });

  final int postId;
  final int channelId;
  final int remindAt;

  DateTime get at => DateTime.fromMillisecondsSinceEpoch(remindAt);

  Map<String, Object?> toJson() => {'c': channelId, 't': remindAt};

  static ArmedReminder? tryParse(int postId, Object? raw) {
    if (raw is! Map) return null;
    final c = raw['c'];
    final t = raw['t'];
    if (t is! num) return null;
    return ArmedReminder(
      postId: postId,
      channelId: c is num ? c.toInt() : 0,
      remindAt: t.toInt(),
    );
  }
}

/// 提醒到点检测 + 本地通知。
class ReminderScheduler {
  ReminderScheduler(
    this.ref, {
    BackgroundService? background,
    bool autoScan = true,
    DateTime Function()? clock,
  }) : background = background ?? ref.read(backgroundServiceProvider),
       _autoScan = autoScan,
       _clock = clock ?? DateTime.now;

  final Ref ref;
  final BackgroundService background;

  /// 测试里关掉"记账后自动扫"：让用例完全掌控扫描时机
  final bool _autoScan;

  /// 取"现在"（测试可注入假时钟）
  final DateTime Function() _clock;

  Timer? _timer;
  bool _stopped = false;
  bool _scanning = false;

  /// 扫描期间有人喊了 [wake]：扫完立刻再来一轮（否则那次唤醒会被丢掉）
  bool _wakePending = false;

  /// 上一轮扫到"到点了但没弹"的条数（被贪睡压着 / 超出单批上限）
  int pendingDue = 0;

  /// 扫描被触发了几次（测试/日志用）
  int scanCount = 0;

  Duration? _nextDelay;

  bool get running => _timer != null;

  /// 下一次扫描的延时（测试用）
  Duration? get nextDelay => _nextDelay;

  /// 还能用吗：provider 被销毁（App 退出/测试 teardown）后，
  /// 途中在飞的异步链不能再碰 `ref`，不然会炸
  /// "Cannot use the Ref … after it has been disposed"（真机日志里很吵）。
  bool get _alive => !_stopped && ref.mounted;

  /// 当前"待弹"的提醒（内存镜像；`arm/disarm` 后即时生效）
  Map<int, ArmedReminder>? _cache;
  Map<int, ArmedReminder> get armed => Map.unmodifiable(_cache ?? const {});

  void start() {
    _stopped = false;
    unawaited(scan());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _nextDelay = null;
  }

  /// 提醒时间变了（新建/删除/广播/回读），重新排一次
  void wake() {
    if (_stopped || !_autoScan) return;
    if (_scanning) {
      _wakePending = true; // 扫完自己会再来一轮
      return;
    }
    _timer?.cancel();
    _timer = null;
    unawaited(scan());
  }

  // ------------------------------------------------------------ 记账

  Future<Map<int, ArmedReminder>> _load() async {
    if (_cache != null) return _cache!;
    if (!_alive) return <int, ArmedReminder>{};
    final raw = await ref.read(settingsServiceProvider).armedRemindersRaw();
    final out = <int, ArmedReminder>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw);
        if (map is Map) {
          for (final e in map.entries) {
            final pid = int.tryParse('${e.key}');
            if (pid == null || pid <= 0) continue;
            final r = ArmedReminder.tryParse(pid, e.value);
            if (r != null) out[pid] = r;
          }
        }
      } catch (_) {
        // 脏数据当没有：提醒功能不该被一段坏 JSON 卡死
      }
    }
    _cache = out;
    return out;
  }

  Future<void> _save(Map<int, ArmedReminder> m) async {
    if (!_alive) return;
    _cache = m;
    final json = jsonEncode({
      for (final e in m.entries) '${e.key}': e.value.toJson(),
    });
    await ref.read(settingsServiceProvider).setArmedRemindersRaw(json);
  }

  /// 记下"我设了一条提醒"（幂等；同一 post 以最新时间为准）
  Future<void> arm({
    required int postId,
    required int channelId,
    required int remindAt,
  }) async {
    if (postId <= 0 || remindAt <= 0 || !_alive) return;
    final m = await _load();
    final old = m[postId];
    if (old != null &&
        old.remindAt == remindAt &&
        (old.channelId == channelId || channelId <= 0)) {
      return; // 没变化：别写库、也别重排定时器
    }
    m[postId] = ArmedReminder(
      postId: postId,
      channelId: channelId > 0 ? channelId : (old?.channelId ?? 0),
      remindAt: remindAt,
    );
    await _save(m);
    await _unmarkFired(postId);
    wake();
  }

  /// 同一条消息**再次**设提醒时，要把"已弹过"的记账抹掉，
  /// 否则新一轮到点会被 `fired.contains(postId)` 挡掉（永远不弹了）。
  Future<void> _unmarkFired(int postId) async {
    if (!_alive) return;
    final settings = ref.read(settingsServiceProvider);
    final fired = await settings.firedReminders();
    if (!fired.remove(postId)) return;
    await settings.setFiredReminders(fired);
  }

  /// 取消/删掉一条提醒（服务端抹了、或我自己删了）
  Future<void> disarm(int postId) async {
    if (postId <= 0 || !_alive) return;
    final m = await _load();
    if (m.remove(postId) == null) return;
    await _save(m);
    wake();
  }

  /// 用 `Reminder/list` 的回读结果**校准**某个频道的账（权威来源）：
  /// 这个频道里"我"的提醒就该是这些，多的删掉、少的补上。
  Future<void> reconcileChannel(int channelId, List<PostDto> posts) async {
    if (channelId <= 0 || !_alive) return;
    final m = await _load();
    var changed = false;
    final keep = <int>{};
    for (final p in posts) {
      if (p.postId <= 0 || p.remindAt <= 0) continue;
      keep.add(p.postId);
      final old = m[p.postId];
      if (old == null ||
          old.remindAt != p.remindAt ||
          old.channelId != channelId) {
        m[p.postId] = ArmedReminder(
          postId: p.postId,
          channelId: channelId,
          remindAt: p.remindAt,
        );
        changed = true;
      }
    }
    // 这个频道里已经不在服务端列表里的，本地也别留着
    final stale = m.entries
        .where((e) => e.value.channelId == channelId && !keep.contains(e.key))
        .map((e) => e.key)
        .toList();
    for (final id in stale) {
      m.remove(id);
      changed = true;
    }
    if (!changed) return;
    await _save(m);
    // 服务端说"这条还欠着提醒" → 本地"已弹过"的记账要撤（可能是我又设了一次）
    for (final id in keep) {
      await _unmarkFired(id);
    }
    wake();
  }

  // ------------------------------------------------------------ 扫描

  /// 扫一遍：到点的弹通知、记账，然后排下一次。
  ///
  /// [now] 可注入（测试）。返回这次真弹了几条。
  Future<int> scan({DateTime? now}) async {
    if (!_alive) return 0;
    if (_scanning) {
      _wakePending = true;
      return 0; // 上一次还没跑完，别叠加
    }
    _scanning = true;
    try {
      scanCount++;
      final at = now ?? _clock();
      if (!_alive) return 0;
      final settings = ref.read(settingsServiceProvider);
      final fired = await settings.firedReminders();
      if (!_alive) return 0;
      final m = await _load();

      final due = <ArmedReminder>[];
      DateTime? nextAt;
      for (final r in m.values) {
        if (fired.contains(r.postId)) continue;
        if (!r.at.isAfter(at)) {
          due.add(r);
        } else if (nextAt == null || r.at.isBefore(nextAt)) {
          nextAt = r.at;
        }
      }
      due.sort((a, b) => a.remindAt.compareTo(b.remindAt));

      if (!_alive) return 0;
      var shown = 0;
      final snoozed = ref.read(snoozeControllerProvider).suppressesAt(at);
      if (!snoozed) {
        for (final r in due.take(kMaxReminderBatch)) {
          if (await _notifyReminder(r)) {
            fired.add(r.postId);
            m.remove(r.postId);
            shown++;
          }
        }
        if (shown > 0) {
          await settings.setFiredReminders(fired);
          await _save(m);
        }
        pendingDue = due.length - shown;
      } else {
        pendingDue = due.length;
        if (due.isNotEmpty) {
          debugPrint('[reminder] 免打扰中，$pendingDue 条提醒先压着');
        }
      }

      _scheduleNext(nextAt, at);
      return shown;
    } finally {
      _scanning = false;
      if (_wakePending && _alive) {
        _wakePending = false;
        _timer?.cancel();
        _timer = Timer(Duration.zero, () {
          if (_alive) unawaited(scan());
        });
      }
    }
  }

  /// 还有到点的没弹（被贪睡压着/超出批次）→ 很快再来看一眼；
  /// 否则按最近的未来提醒排，最长 [kMaxReminderSleep]。
  void _scheduleNext(DateTime? nextAt, DateTime at) {
    _timer?.cancel();
    _timer = null;
    _nextDelay = null;
    if (!_alive) return;
    var d = kMaxReminderSleep;
    if (pendingDue > 0) {
      d = kMinReminderSleep;
    } else if (nextAt != null) {
      final delta = nextAt.difference(at);
      d = Duration(
        milliseconds: math.max(
          kMinReminderSleep.inMilliseconds,
          delta.inMilliseconds + 200,
        ),
      );
      if (d > kMaxReminderSleep) d = kMaxReminderSleep;
    }
    _nextDelay = d;
    _timer = Timer(d, () {
      if (!_alive) return;
      unawaited(scan());
    });
  }

  /// 真弹一条提醒通知。返回是否弹成功。
  Future<bool> _notifyReminder(ArmedReminder r) async {
    if (!_alive) return false;
    final post = await _postOf(r.postId);
    if (!_alive) return false;
    final channelId = r.channelId > 0 ? r.channelId : (post?.channelId ?? 0);
    final channel = await _channelOf(channelId);
    if (channel == null) {
      debugPrint('[reminder] 频道 #$channelId 不在本地，跳过 #${r.postId}');
      return false;
    }
    final title = channel.name.isEmpty
        ? kReminderTitle
        : '$kReminderTitle · ${channel.name}';
    final ok = await background.show(
      MessageNotification(
        channelId: channel.channelId,
        postId: r.postId,
        threadId: post?.threadId ?? 0,
        title: title,
        text: reminderNotificationText(_originPreview(channel, post)),
        canReply: false, // 提醒通知不提供「回复」——它指向的是旧消息
      ),
    );
    if (ok) {
      debugPrint('[reminder] 提醒到点 → #${r.postId}（${channel.name}）');
    }
    return ok;
  }

  /// 被提醒的那条消息的正文（本地没有/加密解不开就给空串）
  String _originPreview(ChannelDto channel, PostDto? post) {
    final raw = (post?.message ?? '').trim();
    if (raw.isEmpty) return '';
    if (channel.encrypted) {
      final e2ee = ref.read(e2eeControllerProvider.notifier);
      final text = e2ee.displayMessage(channel, raw).trim();
      return text == kUndecryptableText ? '' : text;
    }
    return raw;
  }

  Future<ChannelDto?> _channelOf(int channelId) async {
    if (channelId <= 0 || !_alive) return null;
    final store = ref.read(chatStoreProvider);
    for (final c in await store.allChannels()) {
      if (c.channelId == channelId) return c;
    }
    return null;
  }

  Future<PostDto?> _postOf(int postId) async {
    if (postId <= 0 || !_alive) return null;
    final store = ref.read(chatStoreProvider);
    final cid = await store.findPostChannel(postId);
    if (cid == null) return null;
    return store.postById(cid, postId);
  }
}

/// 全局单例（`App` 启动时 `start()`）。
final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  final s = ReminderScheduler(ref);
  ref.onDispose(s.stop);
  return s;
});
