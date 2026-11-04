// ★★ ③Drive D84（214 轮）：「专注备份和同步 / 休眠备份」页。
//
// 官方对照（`activity/SleepBackupActivity` + `res/values/strings.xml`，逐字）：
//   * 标题状态：`sleepmode_processing_title`（正在备份和同步...）/
//     `sleepmode_finish_title`（备份和同步已完成）/
//     `sleepmode_stop_title`（备份和同步已停止）；
//   * 引导：`sleepmode_guide_desc` + `sleepmode_keep_forground_desc` +
//     `sleepmode_not_exit_app_desc`（三条，逐字见 `sleep_backup.dart`）；
//   * 倒计时：`sleepmode_turn_dark_countdown_desc`（屏幕将在 %1$d 秒内后变暗。）；
//   * 出错时列任务：`tvPbError` / `tvSyncBackupError` / `tvWechatBackupError`；
//   * 开关：`enable_sleepmode` / `disable_sleepmode`（启用/停用）；
//   * 提醒：`sleepmode_notification_titile` / `sleepmode_notification_message`。
//
// 页面的运行时数据（队列剩余 / 是否在跑 / 错误任务）来自
// [sleepBackupRuntimeProvider] —— 可注入，所以整页**离线可测**。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../downloads/download_notification_sink.dart'
    show DownloadNotificationSink, MethodChannelDownloadNotifications;
import 'sleep_backup.dart';
import 'sleep_backup_platform.dart';

/// 本地通知出口：**复用** ⑥下载 那轮建的通用本地通知桥
/// （`synhub/download_notifications`，`available` / `show`）。
/// 语义上它就是"发一条本地通知"，与下载完成通知共用一条通道没有副作用
/// （通知 id 不同、渠道一致）。单测里覆盖成记录器。
final sleepBackupNotificationSinkProvider = Provider<DownloadNotificationSink>(
  (ref) => const MethodChannelDownloadNotifications(),
);

/// 提醒通知的固定 id（与下载完成通知的 id 段错开）。
const int kSleepBackupNotificationId = 840214;

/// 进入专注模式的窗口亮度（与 Kotlin `SleepBackupBridge.DIM_BRIGHTNESS` 一致；
/// 官方也是"调暗"而不是全黑）。
const double _kSleepBackupDimBrightness = 0.02;

class SleepBackupPage extends ConsumerStatefulWidget {
  const SleepBackupPage({super.key});

  @override
  ConsumerState<SleepBackupPage> createState() => _SleepBackupPageState();
}

class _SleepBackupPageState extends ConsumerState<SleepBackupPage> {
  Timer? _timer;
  int _countdown = 0;
  bool _checked = false;

  /// 当前是否已经进入"调暗 + 常亮"（退出/停用时必须恢复）。
  bool _dimmed = false;

  /// 官方 `handleScreenDimming`：**只在"已启用 且 正在跑"时**调暗并保持常亮，
  /// 其余情况（含停用、跑完、出错停止、页面销毁）**恢复**跟随系统亮度。
  Future<void> _applyScreenMode() async {
    // 重入保护：initState 的 post-frame 与 ref.listen 可能**几乎同时**触发，
    // 没有这个闸门会把 `keepScreenOn(true)` 发两遍（用例断言得到 [true, true]）。
    if (_screenApplying) return;
    _screenApplying = true;
    try {
      await _applyScreenModeLocked();
    } finally {
      _screenApplying = false;
    }
  }

  bool _screenApplying = false;

  Future<void> _applyScreenModeLocked() async {
    final screen = ref.read(sleepBackupScreenProvider);
    final prefs = ref.read(sleepBackupPrefsProvider);
    final runtime = ref.read(sleepBackupRuntimeProvider);
    final active = prefs.enabled && runtime.processing;
    if (active && !_dimmed) {
      final ok = await screen.dim(_kSleepBackupDimBrightness);
      final keep = await screen.keepScreenOn(true);
      _dimmed = ok || keep;
    } else if (!active && _dimmed) {
      await screen.clearDim();
      await screen.keepScreenOn(false);
      _dimmed = false;
    }
  }

  @override
  void initState() {
    super.initState();
    final runtime = ref.read(sleepBackupRuntimeProvider);
    _countdown = runtime.countdownSeconds;
    Future<void>.microtask(() async {
      await ref.read(sleepBackupPrefsProvider.notifier).preload();
      if (!mounted) return;
      setState(() {});
      await _applyScreenMode();
    });
    _startTimerIfNeeded();
  }

  void _startTimerIfNeeded() {
    _timer?.cancel();
    if (_countdown <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _countdown -= 1;
        if (_countdown <= 0) t.cancel();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    // 页面销毁时必须把亮度还给系统（官方退出专注模式也会恢复）。
    if (_dimmed) {
      final screen = ref.read(sleepBackupScreenProvider);
      _dimmed = false;
      unawaited(screen.clearDim());
      unawaited(screen.keepScreenOn(false));
    }
    super.dispose();
  }

  Future<void> _testReminder() async {
    final sink = ref.read(sleepBackupNotificationSinkProvider);
    final available = await sink.available();
    final decision = await runSleepBackupReminderCheck(
      prefs: ref.read(sleepBackupPrefsProvider),
      runtime: ref.read(sleepBackupRuntimeProvider),
      nowMs: DateTime.now().millisecondsSinceEpoch,
      push: () async {
        if (!available) return;
        await sink.show(
          id: kSleepBackupNotificationId,
          title: kSleepBackupNotificationTitle,
          text: kSleepBackupNotificationMessage,
        );
      },
      persist: (d) =>
          ref.read(sleepBackupPrefsProvider.notifier).applyReminderDecision(d),
    );
    if (!mounted) return;
    setState(() => _checked = true);
    final text = !decision.push
        ? context.t.sleepBackupTestNotDue
        : (available
              ? context.t.sleepBackupTestSent
              : context.t.sleepBackupTestNoPerm);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final prefs = ref.watch(sleepBackupPrefsProvider);
    final runtime = ref.watch(sleepBackupRuntimeProvider);
    // 状态一变就同步"调暗/常亮"（官方 handleScreenDimming 的触发点）
    ref.listen(sleepBackupPrefsProvider, (_, _) => _applyScreenMode());
    ref.listen(sleepBackupRuntimeProvider, (_, _) => _applyScreenMode());
    final view = SleepBackupView.of(
      prefs: prefs,
      runtime: runtime,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final countdown = _countdown;
    return Scaffold(
      appBar: AppBar(title: Text(context.t.sleepBackupTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        runtime.processing
                            ? Icons.sync
                            : (runtime.errors.isNotEmpty
                                  ? Icons.error_outline
                                  : Icons.nightlight_round),
                        color: hud.dim,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          view.statusText,
                          key: const Key('sleep-backup-status'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.t.sleepBackupRemaining(view.remaining),
                    key: const Key('sleep-backup-remaining'),
                  ),
                  if (countdown > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      context.t.sleepBackupCountdown(countdown),
                      key: const Key('sleep-backup-countdown'),
                    ),
                  ],
                  if (view.outdated) ...[
                    const SizedBox(height: 6),
                    Text(
                      context.t.sleepBackupOutdated,
                      key: const Key('sleep-backup-outdated'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            context.t.sleepBackupEnablingTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          for (final line in kSleepBackupGuideLines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('• '),
                  Expanded(
                    child: Text(line, key: Key('sleep-backup-guide-${line.hashCode}')),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          if (runtime.errors.isNotEmpty)
            Card(
              key: const Key('sleep-backup-errors'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(kSleepBackupStopDesc),
                    const SizedBox(height: 6),
                    for (final e in runtime.errors)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text('· $e'),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const Key('sleep-backup-enable'),
                  onPressed: prefs.enabled
                      ? null
                      : () => ref
                            .read(sleepBackupPrefsProvider.notifier)
                            .setEnabled(true),
                  child: Text(context.t.sleepBackupEnable),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  key: const Key('sleep-backup-disable'),
                  onPressed: !prefs.enabled
                      ? null
                      : () => ref
                            .read(sleepBackupPrefsProvider.notifier)
                            .setEnabled(false),
                  child: Text(context.t.sleepBackupDisable),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            prefs.enabled
                ? context.t.sleepBackupEnabledState
                : context.t.sleepBackupDisabledState,
            key: const Key('sleep-backup-enabled-state'),
            style: TextStyle(color: hud.dim),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('sleep-backup-test-reminder'),
            onPressed: _testReminder,
            icon: const Icon(Icons.notifications_active_outlined),
            label: Text(context.t.sleepBackupTestReminder),
          ),
          if (_checked)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.t.sleepBackupReminderTitleLine(
                  kSleepBackupNotificationTitle,
                ),
                key: const Key('sleep-backup-last-check'),
              ),
            ),
          const SizedBox(height: 24),
          Text(
            context.t.sleepBackupScheduleLine(kSleepBackupCheckIntervalMinutes),
            style: TextStyle(fontSize: 12, color: hud.dim),
          ),
        ],
      ),
    );
  }
}
