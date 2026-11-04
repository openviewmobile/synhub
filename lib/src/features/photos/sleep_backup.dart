// ★★ ③Drive 第 214 轮 **D84「休眠备份（专注备份和同步 / sleep mode）」** 的 Dart 核心。
//
// ## 官方事实（`SynologyDrive 3.9.0-1113` smali + 资源，逐字）
//
// | 官方 | 事实 |
// |---|---|
// | `util/SleepBackupUtil.hasOutDatedPBTask()` | `now - photoBackupStartTime > 0x5265c00`（**24h**）**或**（`PBTaskManager.getQueueSize() > 0` 且服务**没在跑**）⇒ "照片备份过时" |
// | `hasOutDatedSyncTask()` / `hasOutDatedWeChatTask()` | 同步 / 微信备份同样判过时；`hasOutDatedTask()` = 三者**或** |
// | `util/SleepBackupNotificationUtil.shouldPushNotification()` | `next_show_sleep_backup_notification_time <= now` |
// | `pushNotificationIfNecessary()` | `hasOutDatedTask() && !isSleepTimeBackupProcessing() && shouldPushNotification()` → 发提醒 + `updatePreferenceNotificationTimeAndBackOff()` |
// | `updatePreferenceNotificationTimeAndBackOff()` | `nextShowAt = now + backoff`；`backoff = min(backoff + 0x5265c00, 0xf731400)` ⇒ **+24h 递增，封顶 3 天**（`0xf731400 = 259200000ms`）；`getSleepBackupNotificationBackOff()` 默认 **24h** |
// | `removeNotificationIfNecessary()` | `!hasOutDatedTask()` → 撤掉提醒 |
// | `worker/SleepBackupNotificationWorker` | `PeriodicWorkRequest("SleepTimeBackupWorker", 60min, flex 10min)` |
// | `activity/SleepBackupActivity` | `remainCountLiveData` / `statusLiveData` / `countDownTimer` / `handleScreenDimming`；`tvStatusDetail` / `tvPbError` / `tvSyncBackupError` / `tvWechatBackupError` |
// | 资源（zh-rCN，逐字） | `sleepmode_processing_title`=**正在备份和同步...**；`sleepmode_finish_title`=**备份和同步已完成**；`sleepmode_stop_title`=**备份和同步已停止**；`sleepmode_stop_desc`=**发生错误。请前往主页 > 后台任务以检查以下任务：**；`sleepmode_guide_desc`=**…将在屏幕变暗的状态下运行任务…**；`sleepmode_keep_forground_desc`=**请让 … 保留在前台以继续此流程。**；`sleepmode_not_exit_app_desc`=**请勿锁定屏幕或退出应用程序。**；`sleepmode_turn_dark_countdown_desc`=**屏幕将在 %1$d 秒内后变暗。**；`sleepmode_notification_titile`=**Synology Drive 提醒**；`sleepmode_notification_message`=**还有未完成的任务。前往更多 > 备份和同步任务，启用专注备份和同步以利用闲置时间运行任务。**；`enable_sleepmode`/`disable_sleepmode`=**启用/停用** |
//
// ## 本文件的范围
//
// * **纯逻辑 + 持久化 + 提醒决策**：官方那套"过时判据 / 退避 / 该不该发提醒"
//   逐字实现（常量都用官方十六进制值），可离线断言。
// * **UI**：`sleep_backup_page.dart`（状态 + 引导 + 倒计时 + 剩余量 + 错误列表 + 启用/停用）。
// * **明确待办**（见台账）：官方那个 **60 分钟 PeriodicWorkRequest** 在**应用没起来时**
//   也查一次（我们目前只在应用内/前台服务里查）；以及 `handleScreenDimming` 的
//   **真·调暗屏幕**（官方走 `WindowManager` 改窗口亮度）—— 本轮只做**倒计时**。
import 'dart:convert';

import '../../core/i18n/data_text.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sleep_backup_worker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/platform/app_secure_storage.dart';
import '../../core/security/keystore_secret_keeper.dart';

/// 官方 `0x5265c00`：24 小时的毫秒数（既是"过时"阈值，也是退避增量）。
const int kSleepBackupDayMs = 0x5265c00;

/// 官方 `0xf731400`：退避封顶（3 天）。
const int kSleepBackupBackoffMaxMs = 0xf731400;

/// 官方 `getSleepBackupNotificationBackOff()` 的默认值（1 天）。
const int kSleepBackupBackoffDefaultMs = kSleepBackupDayMs;

/// 官方 `PeriodicWorkRequest("SleepTimeBackupWorker", …)` 的周期（分钟）/弹性。
const int kSleepBackupCheckIntervalMinutes = 60;
const int kSleepBackupCheckFlexMinutes = 10;

/// 官方"照片备份过时"判据（`hasOutDatedPBTask`）。
///
/// `now - lastBackupAt > 24h` **或**（队列有积压 **且** 没在跑）。
bool sleepBackupOutdated({
  required int nowMs,
  required int lastBackupAtMs,
  int queueSize = 0,
  bool processing = false,
}) {
  // 从没跑过（lastBackupAtMs = 0）时，官方 `photoBackupStartTime` 为 0 ⇒
  // `now - 0 > 24h` 恒真 ⇒ 也算过时（冷启动场景）。
  if (lastBackupAtMs <= 0) return true;
  if (nowMs - lastBackupAtMs > kSleepBackupDayMs) return true;
  return queueSize > 0 && !processing;
}

/// 官方 `shouldPushNotification()`：到点了才发（`nextShowAt <= now`）。
bool sleepBackupReminderDue({
  required int nowMs,
  required int nextShowAtMs,
}) => nextShowAtMs <= nowMs;

/// 官方 `updatePreferenceNotificationTimeAndBackOff()`：退避 **+24h**、**封顶 3 天**。
int sleepBackupNextBackoff(int backoffMs) {
  final grown = (backoffMs <= 0 ? 0 : backoffMs) + kSleepBackupDayMs;
  return grown > kSleepBackupBackoffMaxMs ? kSleepBackupBackoffMaxMs : grown;
}

/// 一次提醒决策的结果（纯数据，便于断言）。
class SleepBackupReminderDecision {
  const SleepBackupReminderDecision({
    required this.push,
    required this.nextShowAtMs,
    required this.backoffMs,
  });

  final bool push;

  /// 决策**之后**的 `next_show_sleep_backup_notification_time`
  final int nextShowAtMs;

  /// 决策**之后**的 `sleep_backup_notification_backoff`
  final int backoffMs;

  @override
  String toString() =>
      'SleepBackupReminderDecision(push: $push, nextShowAt: $nextShowAtMs, '
      'backoff: $backoffMs)';
}

/// 官方 `pushNotificationIfNecessary()` 的完整决策：
/// `过时 && !正在跑 && 到点` → 发提醒，并把 `nextShowAt` 推进 `now + backoff`、
/// 退避 +24h 封顶 3 天；不发时**原样返回**现有值（不偷偷改状态）。
SleepBackupReminderDecision decideSleepBackupReminder({
  required int nowMs,
  required int nextShowAtMs,
  required int backoffMs,
  required bool outdated,
  required bool processing,
}) {
  final due = sleepBackupReminderDue(nowMs: nowMs, nextShowAtMs: nextShowAtMs);
  if (!outdated || processing || !due) {
    return SleepBackupReminderDecision(
      push: false,
      nextShowAtMs: nextShowAtMs,
      backoffMs: backoffMs <= 0 ? kSleepBackupBackoffDefaultMs : backoffMs,
    );
  }
  final used = backoffMs <= 0 ? kSleepBackupBackoffDefaultMs : backoffMs;
  return SleepBackupReminderDecision(
    push: true,
    nextShowAtMs: nowMs + used,
    backoffMs: sleepBackupNextBackoff(used),
  );
}

/// 备份/同步的**运行状态**（官方 `SleepBackupActivity.statusLiveData`）。
enum SleepBackupStatus {
  /// 没在跑（也没错误）—— 官方页面上就是"可以启用"的常态
  idle,

  /// `sleepmode_processing_title`
  processing,

  /// `sleepmode_finish_title`
  finished,

  /// `sleepmode_stop_title`（伴随错误任务列表）
  stopped,
}

/// 状态标题按官方 zh-CN 文案（`dataText` 落库，来自资源逐字）。
String sleepBackupStatusText(SleepBackupStatus status) {
  switch (status) {
    case SleepBackupStatus.processing:
      return dataText('sleepBackupStatusProcessing', '正在备份和同步...');
    case SleepBackupStatus.finished:
      return dataText('sleepBackupStatusFinished', '备份和同步已完成');
    case SleepBackupStatus.stopped:
      return dataText('sleepBackupStatusStopped', '备份和同步已停止');
    case SleepBackupStatus.idle:
      return dataText('sleepBackupTitle', '专注备份和同步');
  }
}

/// 持久化的偏好（对应官方 `PreferenceUtilities` 的三个键）。
class SleepBackupPrefs {
  const SleepBackupPrefs({
    this.enabled = false,
    this.nextShowAtMs = 0,
    this.backoffMs = kSleepBackupBackoffDefaultMs,
    this.lastBackupAtMs = 0,
  });

  /// `getAnyTaskEnabled()` 的对应物（至少一个备份任务开着）
  final bool enabled;

  /// `next_show_sleep_backup_notification_time`
  final int nextShowAtMs;

  /// `sleep_backup_notification_backoff`（默认 24h）
  final int backoffMs;

  /// 上次备份完成时间（过时判据用）
  final int lastBackupAtMs;

  SleepBackupPrefs copyWith({
    bool? enabled,
    int? nextShowAtMs,
    int? backoffMs,
    int? lastBackupAtMs,
  }) => SleepBackupPrefs(
    enabled: enabled ?? this.enabled,
    nextShowAtMs: nextShowAtMs ?? this.nextShowAtMs,
    backoffMs: backoffMs ?? this.backoffMs,
    lastBackupAtMs: lastBackupAtMs ?? this.lastBackupAtMs,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'next_show_sleep_backup_notification_time': nextShowAtMs,
    'sleep_backup_notification_backoff': backoffMs,
    'last_backup_at': lastBackupAtMs,
  };

  static SleepBackupPrefs fromJson(Map<String, dynamic> j) => SleepBackupPrefs(
    enabled: j['enabled'] == true,
    nextShowAtMs:
        (j['next_show_sleep_backup_notification_time'] as num?)?.toInt() ?? 0,
    backoffMs:
        (j['sleep_backup_notification_backoff'] as num?)?.toInt() ??
        kSleepBackupBackoffDefaultMs,
    lastBackupAtMs: (j['last_backup_at'] as num?)?.toInt() ?? 0,
  );
}

/// 偏好的落盘口（与仓库既有纪律一致：读不出来当默认、写不进去只影响下次）。
abstract class SleepBackupStore {
  Future<SleepBackupPrefs> read();
  Future<void> write(SleepBackupPrefs prefs);
}

/// 安全存储实现（槽位 `sleep_backup_prefs_v1`）。
///
/// ★ r701 · `DA340` 第二层：**起飞前检查只装在 keeper 上是不够的**。
/// 这条路径直连 `appSecureStorage()`，绕过了 `KeystoreSecretKeeper` 的闸门 ——
/// 实测（`docs/evidence-r701-linux/shots/211_locked_second_source.png`）：
/// keeper 已经判"不可用"、日志也打了 `usable=false`，**解锁框照样弹**，
/// 因为这里 `read()` 一上来就调 libsecret。
/// ⇒ 直连插件的调用点必须**自己过同一道闸**：`KeystoreSecretKeeper.isSupported`
/// 读的是 `main()` 里预热好的缓存（Linux：文件在 **且** 默认 collection 未锁）。
class SecureSleepBackupStore implements SleepBackupStore {
  SecureSleepBackupStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          (KeystoreSecretKeeper.isSupported ? appSecureStorage() : null);

  static const String slot = 'sleep_backup_prefs_v1';

  /// `null` = 这台机器上不许碰 libsecret（无 keyring / 集合锁定 / 探测不出来）。
  final FlutterSecureStorage? _storage;

  @override
  Future<SleepBackupPrefs> read() async {
    final storage = _storage;
    if (storage == null) return const SleepBackupPrefs();
    try {
      final raw = await storage.read(key: slot);
      if (raw == null || raw.isEmpty) return const SleepBackupPrefs();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const SleepBackupPrefs();
      return SleepBackupPrefs.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return const SleepBackupPrefs();
    }
  }

  @override
  Future<void> write(SleepBackupPrefs prefs) async {
    final storage = _storage;
    if (storage == null) return;
    try {
      await storage.write(key: slot, value: jsonEncode(prefs.toJson()));
    } catch (_) {
      // 写不进去只影响"下次还在不在"
    }
  }
}

/// 内存实现（单测用）。
class MemorySleepBackupStore implements SleepBackupStore {
  MemorySleepBackupStore([this._prefs = const SleepBackupPrefs()]);

  SleepBackupPrefs _prefs;

  SleepBackupPrefs get prefs => _prefs;

  @override
  Future<SleepBackupPrefs> read() async => _prefs;

  @override
  Future<void> write(SleepBackupPrefs prefs) async => _prefs = prefs;
}

final sleepBackupStoreProvider = Provider<SleepBackupStore>(
  (ref) => SecureSleepBackupStore(),
);

/// 偏好状态（页面读它；改动即落盘）。
class SleepBackupPrefsNotifier extends Notifier<SleepBackupPrefs> {
  @override
  SleepBackupPrefs build() => const SleepBackupPrefs();

  /// 页面 `initState` 调一次，把落盘的偏好读回内存。
  Future<void> preload() async {
    final loaded = await ref.read(sleepBackupStoreProvider).read();
    if (ref.mounted) state = loaded;
  }

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await ref.read(sleepBackupStoreProvider).write(state);
    // ★ 222 轮 D84：启用/停用**同时登记/撤销原生 60min 周期任务**
    // （判定在这里算好交给 worker；失败不影响偏好本身）
    try {
      final scheduler = ref.read(sleepBackupWorkerSchedulerProvider);
      if (!enabled) {
        await scheduler.cancel();
      } else {
        await scheduler.schedule(
          planSleepBackupWorkerWake(
            prefs: state,
            runtime: const SleepBackupRuntime(),
            nowMs: DateTime.now().millisecondsSinceEpoch,
            title: dataText('sleepBackupWorkerTitle', 'SynHub 休眠备份'),
            text: dataText(
              'sleepBackupWorkerText',
              '为了让备份继续，请保持 App 在前台并让屏幕常亮。',
            ),
          ),
        );
      }
    } catch (_) {
      // 原生不支持（桌面/测试）时静默跳过：偏好仍然生效
    }
  }

  /// 备份跑完一次（官方 `photoBackupStartTime` 的更新点）。
  Future<void> markBackupFinished(int atMs) async {
    state = state.copyWith(lastBackupAtMs: atMs);
    await ref.read(sleepBackupStoreProvider).write(state);
  }

  /// 应用一次提醒决策（写入 `nextShowAt` / `backoff`）。
  Future<void> applyReminderDecision(SleepBackupReminderDecision d) async {
    state = state.copyWith(
      nextShowAtMs: d.nextShowAtMs,
      backoffMs: d.backoffMs,
    );
    await ref.read(sleepBackupStoreProvider).write(state);
  }

  /// "立刻试用提醒"（官方调试项 `prefs_title_push_sleep_time_backup_notification`
  /// 的语义）：把 `nextShowAt` 清零，让下一次检查必然到点。
  Future<void> armReminderNow() async {
    state = state.copyWith(nextShowAtMs: 0);
    await ref.read(sleepBackupStoreProvider).write(state);
  }
}

final sleepBackupPrefsProvider =
    NotifierProvider<SleepBackupPrefsNotifier, SleepBackupPrefs>(
      SleepBackupPrefsNotifier.new,
    );

/// 页面要展示的运行时输入（队列/是否在跑/错误任务）。
///
/// 做成可注入的 provider：**真机上**由相册备份的队列与运行器填，
/// 离线用例里直接给一组数就行（官方 `remainCountLiveData` 的对应物）。
class SleepBackupRuntime {
  const SleepBackupRuntime({
    this.queueSize = 0,
    this.processing = false,
    this.status = SleepBackupStatus.idle,
    this.errors = const [],
    this.countdownSeconds = 0,
  });

  final int queueSize;
  final bool processing;
  final SleepBackupStatus status;

  /// 官方 `tvPbError` / `tvSyncBackupError` / `tvWechatBackupError` 列出的任务名
  final List<String> errors;

  /// 官方 `sleepmode_turn_dark_countdown_desc` 的 `%1$d`（0 = 不显示倒计时）
  final int countdownSeconds;
}

final sleepBackupRuntimeProvider = Provider<SleepBackupRuntime>(
  (ref) => const SleepBackupRuntime(),
);

/// 提醒文案（官方两条资源，逐字）。
///
/// 用 getter 而不是 `const`：文案要按当前语言取（`dataText` 走注入的翻译表）。
String get kSleepBackupNotificationTitle =>
    dataText('sleepBackupNotificationTitle', 'SynHub 提醒');
String get kSleepBackupNotificationMessage => dataText(
  'sleepBackupNotificationMessage',
  '还有未完成的任务。前往更多 > 备份和同步任务，启用专注备份和同步以利用闲置时间运行任务。',
);

/// 屏幕变暗倒计时文案（官方 `sleepmode_turn_dark_countdown_desc`，`%1$d` = 剩余秒数）。
///
/// key 走 `dataText`（`{n}` 模板由本函数替换）；用函数而不是 `const`：
/// 译文按当前语言取（`dataText` 走注入的翻译表）。
const String kSleepBackupCountdownKey = 'sleepBackupCountdown';
String sleepBackupCountdownText(int seconds) =>
    dataText(kSleepBackupCountdownKey, '屏幕将在 {n} 秒内后变暗。')
        .replaceAll('{n}', '$seconds');

/// 页面上的引导三条（官方 `sleepmode_guide_desc` 的三条子句）。
List<String> get kSleepBackupGuideLines => [
  dataText(
    'sleepBackupGuideRunning',
    '本应用会在屏幕变暗的状态下运行任务，该流程可能需要一段时间才能完成。',
  ),
  dataText('sleepBackupGuideForeground', '请让本应用保留在前台，以便继续这个流程。'),
  dataText('sleepBackupGuideNoLock', '请勿锁定屏幕或退出应用程序。'),
];

/// 官方"停止"时的说明行。
String get kSleepBackupStopDesc =>
    dataText('sleepBackupStopDesc', '发生错误。请前往主页 > 后台任务以检查以下任务：');

/// 一个纯函数：把运行时输入汇总成"该显示什么"（页面与用例共用）。
class SleepBackupView {
  const SleepBackupView({
    required this.statusText,
    required this.remaining,
    required this.countdownText,
    required this.errors,
    required this.outdated,
  });

  final String statusText;
  final int remaining;
  final String countdownText;
  final List<String> errors;
  final bool outdated;

  static SleepBackupView of({
    required SleepBackupPrefs prefs,
    required SleepBackupRuntime runtime,
    required int nowMs,
  }) {
    final status = runtime.processing
        ? SleepBackupStatus.processing
        : (runtime.errors.isNotEmpty
              ? SleepBackupStatus.stopped
              : (runtime.status == SleepBackupStatus.processing
                    ? SleepBackupStatus.finished
                    : runtime.status));
    return SleepBackupView(
      statusText: sleepBackupStatusText(status),
      remaining: runtime.queueSize,
      countdownText: runtime.countdownSeconds > 0
          ? sleepBackupCountdownText(runtime.countdownSeconds)
          : '',
      errors: runtime.errors,
      outdated: sleepBackupOutdated(
        nowMs: nowMs,
        lastBackupAtMs: prefs.lastBackupAtMs,
        queueSize: runtime.queueSize,
        processing: runtime.processing,
      ),
    );
  }
}

/// 提醒的"检查一次"编排（官方 `pushNotificationIfNecessary` + worker 的那一步）。
///
/// 发不发由 [decideSleepBackupReminder] 定；发出去由调用方给的 `push` 回调做
/// （页面/前台服务传本地通知出口，用例传记录器）。
Future<SleepBackupReminderDecision> runSleepBackupReminderCheck({
  required SleepBackupPrefs prefs,
  required SleepBackupRuntime runtime,
  required int nowMs,
  required Future<void> Function() push,
  required Future<void> Function(SleepBackupReminderDecision) persist,
}) async {
  final d = decideSleepBackupReminder(
    nowMs: nowMs,
    nextShowAtMs: prefs.nextShowAtMs,
    backoffMs: prefs.backoffMs,
    outdated: sleepBackupOutdated(
      nowMs: nowMs,
      lastBackupAtMs: prefs.lastBackupAtMs,
      queueSize: runtime.queueSize,
      processing: runtime.processing,
    ),
    processing: runtime.processing,
  );
  if (d.push) {
    await push();
    await persist(d);
  }
  return d;
}

/// 提醒检查的定时器周期（官方 worker 的 Dart 侧对应物；`noRetry` 防抖）。
final sleepBackupCheckIntervalProvider = Provider<Duration>(
  (ref) => const Duration(minutes: kSleepBackupCheckIntervalMinutes),
  name: 'sleepBackupCheckInterval',
);
