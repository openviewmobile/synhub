// Phase 9：免打扰设置（手动 snooze + 定时免打扰）。
//
// 对位原版两个页面：
//   * `SnoozeSettingFragment` / `SnoozeActivity`（弹窗）：关闭 / 20 分钟 /
//     1·2·4·8·24 小时，副标题显示「剩余 HH:MM:SS」；
//   * `ScheduleSnoozeFragment`：定时免打扰开关 + 起始/结束时间（`HH:mm`）+
//     一行只读的时区（原版显示服务端下发的 `timezoneUTC`），保存前校验
//     起止不能相等（`validate_snooze_schedule_duplicate`）。
//
// 数据都走服务端（`SYNO.Chat.User.Preference`），本地只做镜像 —— 所以换设备/重装
// 之后免打扰状态还在（这是原版把 snooze 放服务端的唯一理由）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/kit/design_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'snooze_controller.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../../core/i18n/l10n.dart';
import '../../design/design_palette.dart';
import '../../core/user_facing_error.dart';

class SnoozeSettingsPage extends ConsumerStatefulWidget {
  const SnoozeSettingsPage({super.key});

  @override
  ConsumerState<SnoozeSettingsPage> createState() => _SnoozeSettingsPageState();
}

class _SnoozeSettingsPageState extends ConsumerState<SnoozeSettingsPage> {
  /// 每秒刷新一次剩余时间（原版 `SnoozeFragment` 也是 `postDelayed` 续命）
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _pickSnooze() async {
    final state = ref.read(snoozeControllerProvider);
    final now = DateTime.now();
    final picked = await showModalBottomSheet<SnoozeOption?>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            DesignRowTile(
              dense: true,
              title: Text(
                context.t.notifSnooze,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (state.remainingAt(now) > Duration.zero)
              DesignRowTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: Text(SnoozeOption.off.labelIn(context.t)),
                subtitle: Text(
                  context.t.snoozeSubtitleRemaining(
                    formatSnoozeRemaining(state.remainingAt(now)),
                  ),
                ),
                onTap: () => Navigator.of(ctx).pop(SnoozeOption.off),
              ),
            for (final o in SnoozeOption.all)
              DesignRowTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: Text(o.labelIn(context.t)),
                onTap: () => Navigator.of(ctx).pop(o),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await ref
          .read(snoozeControllerProvider.notifier)
          .setSnooze(picked.duration);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            picked.duration <= Duration.zero
                ? context.t.snoozeDisabledToast
                : context.t.snoozeEnabledToast(picked.labelIn(context.t)),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // 使用日志：免打扰设置写入失败（用户可见的错误）
      trackOnceFailure(
        UsageModule.settings,
        UsageAction.edit,
        objectType: 'snooze',
        reason: 'snooze_set_failed',
        error: e,
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.t.actionSetFailed(userFacingError(e)))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(snoozeControllerProvider);
    final now = DateTime.now();
    return DesignScaffold(
      appBar: AppBar(title: Text(context.t.notifSnooze)),
      body: ListView(
        children: [
          DesignRowTile(
            leading: Icon(
              state.suppressesNow
                  ? Icons.notifications_off
                  : Icons.notifications_none,
            ),
            title: Text(context.t.notifSnooze),
            subtitle: Text(state.subtitleIn(context.t, now)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickSnooze,
          ),
          if (state.supportsSchedule) ...[
            const Divider(height: 1),
            DesignRowTile(
              leading: const Icon(Icons.schedule),
              title: Text(context.t.snoozeScheduleTitle),
              subtitle: Text(
                state.scheduleEnabled
                    ? context.t.snoozeScheduleOn(
                        formatSecondsOfDay(state.scheduleStartSecond),
                        formatSecondsOfDay(state.scheduleEndSecond),
                      )
                    : context.t.snoozeStatusOff,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ScheduleSnoozePage(),
                ),
              ),
            ),
            DesignRowTile(
              leading: const Icon(Icons.public),
              title: Text(context.t.snoozeTimezone),
              subtitle: Text(
                state.timezoneUtc.isEmpty
                    ? context.t.snoozeTimezoneUnset
                    : state.timezoneUtc,
              ),
            ),
          ],
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.t.snoozeFootnote,
              // ★ r511：`Colors.grey` 不是设计令牌 —— 亮色下浅灰压白底几乎看不见，
              // 暗色下又偏亮。脚注是"次要信息"，用 `dim` + `bodySmall`。
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: DesignPalette.of(context).dim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 定时免打扰（原版 `ScheduleSnoozeFragment`）
class ScheduleSnoozePage extends ConsumerStatefulWidget {
  const ScheduleSnoozePage({super.key});

  @override
  ConsumerState<ScheduleSnoozePage> createState() => _ScheduleSnoozePageState();
}

class _ScheduleSnoozePageState extends ConsumerState<ScheduleSnoozePage> {
  bool _enabled = false;
  int _start = UserPreferenceDefault.start;
  int _end = UserPreferenceDefault.end;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(snoozeControllerProvider);
    _enabled = s.scheduleEnabled;
    _start = s.scheduleStartSecond;
    _end = s.scheduleEndSecond;
  }

  Future<void> _pick(bool isStart) async {
    final current = isStart ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: current ~/ 3600,
        minute: (current % 3600) ~/ 60,
      ),
    );
    if (picked == null) return;
    setState(() {
      final sec = picked.hour * 3600 + picked.minute * 60;
      if (isStart) {
        _start = sec;
      } else {
        _end = sec;
      }
    });
  }

  Future<void> _save() async {
    if (_start == _end) {
      // 原版 `validate_snooze_schedule_duplicate`
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.t.snoozeScheduleSameTime)));
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(snoozeControllerProvider.notifier)
          .setSchedule(enable: _enabled, startSecond: _start, endSecond: _end);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.t.actionSaved)));
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // 使用日志：免打扰定时计划保存失败（用户可见的错误）
      trackOnceFailure(
        UsageModule.settings,
        UsageAction.edit,
        objectType: 'snooze_schedule',
        reason: 'snooze_schedule_save_failed',
        error: e,
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.t.actionSaveFailed(userFacingError(e)))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tz = ref.watch(snoozeControllerProvider).timezoneUtc;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.snoozeScheduleTitle),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(context.t.actionSave),
          ),
        ],
      ),
      body: ListView(
        children: [
          DesignSwitchRow(
            secondary: const Icon(Icons.schedule),
            title: Text(context.t.snoozeScheduleTitle),
            subtitle: Text(context.t.snoozeScheduleHint),
            value: _enabled,
            onChanged: (on) => setState(() => _enabled = on),
          ),
          const Divider(height: 1),
          DesignRowTile(
            leading: const Icon(Icons.play_arrow_outlined),
            title: Text(context.t.snoozeStartTime),
            subtitle: Text(formatSecondsOfDay(_start)),
            enabled: _enabled,
            onTap: _enabled ? () => _pick(true) : null,
          ),
          DesignRowTile(
            leading: const Icon(Icons.stop_outlined),
            title: Text(context.t.snoozeEndTime),
            subtitle: Text(formatSecondsOfDay(_end)),
            enabled: _enabled,
            onTap: _enabled ? () => _pick(false) : null,
          ),
          DesignRowTile(
            leading: const Icon(Icons.public),
            title: Text(context.t.snoozeTimezone),
            subtitle: Text(tz.isEmpty ? context.t.snoozeTimezoneDevice : tz),
          ),
        ],
      ),
    );
  }
}

/// DTO 默认值的快捷引用（避免这个页面再 import data 层）
class UserPreferenceDefault {
  const UserPreferenceDefault._();

  static const int start = 32400; // 09:00
  static const int end = 64800; // 18:00
}
