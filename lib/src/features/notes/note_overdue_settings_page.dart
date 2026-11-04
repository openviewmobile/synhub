// 逾期汇总通知设置（P0-1 / 审计 E6）。
//
// 对照官方 `activities/TodoNotificationSettingActivity`：
//   * 一个开关（默认**关**，偏好键 `todo_overdue_enable`）
//   * 一个时刻（默认 **09:00**，偏好键 `todo_overdue_time`）
// 服务端只有 `Todo/list`；开关/时刻是本机偏好，官方存 SharedPreferences，
// 我们存在既有 Drift 键值表（`note_reminder_service.dart`）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/theme/app_tokens.dart';
import 'note_reminder.dart';
import 'note_reminder_platform.dart';
import 'note_reminder_service.dart';

class NoteOverdueSettingsPage extends ConsumerWidget {
  const NoteOverdueSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final settings = ref.watch(todoOverdueSettingsProvider);
    final notifier = ref.read(todoOverdueSettingsProvider.notifier);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(noteB(NoteBTextKeys.overdueSettings, '逾期提醒')),
      ),
      body: ListView(
        children: [
          DesignSwitchRow(
            key: const Key('note-overdue-enable'),
            secondary: Icon(Icons.notifications_active_outlined, color: hud.dim),
            title: Text(noteB(NoteBTextKeys.overdueEnable, '每日逾期汇总')),
            subtitle: Text(
              noteB(
                NoteBTextKeys.overdueHint,
                '到点把当天已逾期、未完成的任务汇总成一条提醒',
              ),
              style: TextStyle(color: hud.dim),
            ),
            value: settings.enabled,
            onChanged: (v) => notifier.setEnabled(v),
          ),
          const Divider(height: 1),
          DesignRowTile(
            key: const Key('note-overdue-time'),
            enabled: settings.enabled,
            leading: Icon(Icons.schedule_outlined, color: hud.dim),
            title: Text(noteB(NoteBTextKeys.overdueTime, '提醒时间')),
            subtitle: Text(settings.label, style: TextStyle(color: hud.dim)),
            trailing: const Icon(Icons.chevron_right),
            onTap: settings.enabled
                ? () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(
                        hour: settings.hour,
                        minute: settings.minute,
                      ),
                    );
                    if (picked == null) return;
                    await notifier.setTime(picked.hour, picked.minute);
                  }
                : null,
          ),
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  noteB(
                    NoteBTextKeys.overdueShow,
                    '逾期列表可在待办页「未完成」筛选里查看',
                  ),
                  style: TextStyle(color: hud.dim, fontSize: 12),
                ),
                const SizedBox(height: Gap.sm),
                // 据实显示系统级提醒能力（Android 平台批 A）：
                //   有 AlarmManager + 通知权限 → 说"系统级已开启"；
                //   未授权 / 精确闹钟被收回 → 如实提示并给"去授权"入口；
                //   原生通道缺失 → 才回落"仅应用打开时提醒"。
                _NotifyCapabilityText(hud: hud),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 系统级提醒能力 / 授权状态的**如实**文案（`note_reminder_platform.dart`）。
class _NotifyCapabilityText extends ConsumerWidget {
  const _NotifyCapabilityText({required this.hud});

  final DesignPalette hud;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(noteReminderStatusProvider);
    final s = status.value ?? const NoteReminderStatus();

    final String text;
    final Key key;
    var canGrant = false;
    if (!s.supported) {
      // 原生通道不在（桌面/单测/未挂插件）：只能是前台 Timer
      text = noteB(
        NoteBTextKeys.notifyUnsupported,
        '当前版本仅在应用打开时提醒（系统级提醒需要额外依赖）',
      );
      key = const Key('note-overdue-foreground-only');
    } else if (!s.notificationsGranted) {
      text = noteB(
        NoteBTextKeys.notifyPermissionNeeded,
        '系统级提醒需要通知权限：未授权时仅在应用打开时提醒',
      );
      key = const Key('note-overdue-permission-needed');
      canGrant = true;
    } else if (!s.exactAlarmAllowed) {
      text = noteB(
        NoteBTextKeys.notifyExactAlarmDenied,
        '精确闹钟未授权：提醒可能延迟（已降级为不精确闹钟）',
      );
      key = const Key('note-overdue-exact-alarm-denied');
      canGrant = true;
    } else {
      text = noteB(
        NoteBTextKeys.notifySystemReady,
        '系统级提醒已开启：应用未打开时也会按闹钟提醒',
      );
      key = const Key('note-overdue-system-ready');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, key: key, style: TextStyle(color: hud.dim, fontSize: 12)),
        if (canGrant)
          TextButton(
            key: const Key('note-overdue-grant'),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () async {
              await ref.read(noteReminderPlatformProvider).requestPermissions();
              ref.invalidate(noteReminderStatusProvider);
            },
            child: Text(noteB(NoteBTextKeys.notifyGrant, '去授权')),
          ),
      ],
    );
  }
}
