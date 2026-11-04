// 待办提醒 + 逾期汇总的**纯逻辑**（P0-1，审计 E5/E6）。
//
// 官方证据（[E2] 反编译 DS note 1.12.0）：
//   * `Common.java`：`REMINDER_OFFSET_BEFORE_30_MINS=1800`、
//     `_1_HOUR=3600`、`_12_HOURS=43200`、`_1_DAY=86400`、`ON_TIME=0`、
//     `TODO_NO_REMINDER_OFFSET=-1`；`NINE_OCLOCK_TIME_IN_MILLIS=32400000`
//     （每日逾期汇总默认 09:00）；`TODO_OVERDUE_NOTIFICATION_ENABLE` /
//     `TODO_OVERDUE_NOTIFICATION_TIME` 两个偏好键。
//   * `utils/Utils.updateTodoReminderNotification(ctx, id, dueDate, offset)`：
//     `dueDate == -1 || offset == -1` → 取消；否则触发时刻
//     `(dueDate - offset) * 1000`（**dueDate/offset 都是秒**），
//     只在"还没到点"时 `setExact`。
//   * `utils/Utils.updateTodoOverdueNotification(ctx, hh, mm)`：每天
//     `setInexactRepeating(..., 24h)`。
//   * `receivers/TodoNotificationReceiver.notifyOverdue`：查
//     `done = 0 and due_date != -1 and due_date < 今天 00:00`，按 `due_date asc`，
//     标题 `overdue_notification`、正文 `num_overdue_tasks`（`%d overdue tasks`）、
//     摘要 `click_to_check_overdue`，明细 `InboxStyle` 行是
//     `<可读时间> - <标题>`。
//   * `fragments/TodoReminderDialogFragment` 的预设就是：off / on time /
//     30 分钟 / 1 小时 / 12 小时 / 1 天 / 自定义（单位 minute/hour/day/week）。
//
// ⚠️ 单位边界：官方 `due_date` 是**秒**，我们 DTO 里存的是**毫秒**
// （`note_todo_editor_page._pickDueDate` 用 `millisecondsSinceEpoch`，
// 既有用例也按毫秒钉死）。本文件因此统一按**毫秒**算触发时刻，
// `reminder_offset` 仍按官方**秒**理解。这条差异登记在
// `docs/note-b-implementation.md` 的「未验证边界」。
//
// 本文件不引入任何新依赖：只做"算什么时候该响 + 该报几条"，
// 真正的系统闹钟/通知见 `note_reminder_service.dart` 的方案说明。
import 'package:meta/meta.dart';

import '../../core/i18n/data_text.dart';
import '../../data/dto/note_dto.dart';

/// 本批次新增文案（`noteC3` 同款约定：key + 中文兜底，`.arb` 禁碰）。
abstract final class NoteBTextKeys {
  // ---- 提醒 ----
  static const reminder = 'noteBReminder';
  static const reminderOff = 'noteBReminderOff';
  static const reminderOnTime = 'noteBReminderOnTime';
  static const reminderBeforePrefix = 'noteBReminderBefore';
  static const reminderCustom = 'noteBReminderCustom';
  static const reminderUnitMinute = 'noteBReminderUnitMinute';
  static const reminderUnitHour = 'noteBReminderUnitHour';
  static const reminderUnitDay = 'noteBReminderUnitDay';
  static const reminderUnitWeek = 'noteBReminderUnitWeek';
  static const reminderNeedsDueDate = 'noteBReminderNeedsDueDate';

  // ---- 逾期汇总 ----
  static const overdueSettings = 'noteBOverdueSettings';
  static const overdueEnable = 'noteBOverdueEnable';
  static const overdueTime = 'noteBOverdueTime';
  static const overdueTitle = 'noteBOverdueTitle';
  static const overdueCount = 'noteBOverdueCount';
  static const overdueShow = 'noteBOverdueShow';
  static const overdueHint = 'noteBOverdueHint';

  // ---- 通知（本地能力）----
  static const notifyUnsupported = 'noteBNotifyUnsupported';
  // Android 平台批 A：系统级提醒（AlarmManager + 通知渠道 dsnote）的状态文案。
  // `.arb` 由维护者统一并库；未并库前 dataText 回落中文兜底。
  static const notifySystemReady = 'noteBNotifySystemReady';
  static const notifyPermissionNeeded = 'noteBNotifyPermissionNeeded';
  static const notifyExactAlarmDenied = 'noteBNotifyExactAlarmDenied';
  static const notifyGrant = 'noteBNotifyGrant';

  // ---- 智能笔记本（F6）----
  static const smart = 'noteBSmart';
  static const smartNew = 'noteBSmartNew';
  static const smartEdit = 'noteBSmartEdit';
  static const smartEmpty = 'noteBSmartEmpty';
  static const smartName = 'noteBSmartName';
  static const smartKeyword = 'noteBSmartKeyword';
  static const smartNoteTitle = 'noteBSmartNoteTitle';
  static const smartNotebooks = 'noteBSmartNotebooks';
  static const smartTags = 'noteBSmartTags';
  static const smartTagAnd = 'noteBSmartTagAnd';
  static const smartTagOr = 'noteBSmartTagOr';
  static const smartDateFrom = 'noteBSmartDateFrom';
  static const smartDateTo = 'noteBSmartDateTo';
  static const smartDelete = 'noteBSmartDelete';
  static const smartDeleteConfirm = 'noteBSmartDeleteConfirm';
  static const smartSaved = 'noteBSmartSaved';
  static const smartFailed = 'noteBSmartFailed';
  static const smartNameRequired = 'noteBSmartNameRequired';
  static const smartNoConditions = 'noteBSmartNoConditions';

  // ---- Shelf（F2）----
  static const shelf = 'noteBShelf';
  static const shelfAdd = 'noteBShelfAdd';
  static const shelfRemove = 'noteBShelfRemove';
  static const shelfName = 'noteBShelfName';
  static const shelfEmpty = 'noteBShelfEmpty';
  static const shelfDone = 'noteBShelfDone';

  // ---- 共享给我（J5）----
  static const joined = 'noteBJoined';
  static const joinedNotebooks = 'noteBJoinedNotebooks';
  static const joinedNotes = 'noteBJoinedNotes';
  static const joinedEmpty = 'noteBJoinedEmpty';
  static const joinedOwner = 'noteBJoinedOwner';

  // ---- wave3：待办超时（`Todo/list_timeout`）----
  static const todoTimeoutChip = 'noteBTodoTimeoutChip';
  static const todoTimeoutEmpty = 'noteBTodoTimeoutEmpty';
  static const todoTimeoutHint = 'noteBTodoTimeoutHint';

  // ---- wave3：快捷方式（`Shortcut/list`）----
  static const shortcut = 'noteBShortcut';
  static const shortcutEmpty = 'noteBShortcutEmpty';
  static const shortcutEmptyHint = 'noteBShortcutEmptyHint';
  static const shortcutLoadFailed = 'noteBShortcutLoadFailed';
  static const shortcutCategoryNotebook = 'noteBShortcutCategoryNotebook';
  static const shortcutCategoryNote = 'noteBShortcutCategoryNote';
  static const shortcutCategoryTag = 'noteBShortcutCategoryTag';
  static const shortcutCategoryStack = 'noteBShortcutCategoryStack';
  static const shortcutCategorySmart = 'noteBShortcutCategorySmart';
  static const shortcutCategoryOther = 'noteBShortcutCategoryOther';

  // ---- 复制 / 加密转换（A9/A10）----
  static const copy = 'noteBCopy';
  static const copySuffix = 'noteBCopySuffix';
  static const copyToEncrypt = 'noteBCopyToEncrypt';
  static const copyToPlaintext = 'noteBCopyToPlaintext';
  static const copyPassword = 'noteBCopyPassword';
  static const copyDone = 'noteBCopyDone';
  static const copyFailed = 'noteBCopyFailed';
  static const copyTitle = 'noteBCopyTitle';
}

/// 取本批次文案
String noteB(String key, String zh) => dataText(key, zh);

/// 带占位符填充
String noteBFill(String key, String zh, Map<String, String> values) {
  var out = noteB(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 提醒预设（与官方 `TodoReminderDialogFragment` 的复选框一一对应）。
@immutable
class TodoReminderPreset {
  const TodoReminderPreset(
    this.offsetSeconds,
    this.labelKey,
    this.labelZh, {
    this.value,
    this.unitSeconds,
  });

  /// 提前量（秒）；`-1` = 关闭，`0` = 正点
  final int offsetSeconds;
  final String labelKey;
  final String labelZh;

  /// `{value}` 占位符的取值；null = 该模板没有占位符（`reminderOff` / `reminderOnTime`）。
  final int? value;

  /// `{unit}` 占位符对应的单位秒数（见 [TodoReminderUnit]）；null = 没有占位符。
  final int? unitSeconds;

  /// 当前语言文案。
  ///
  /// `reminderBeforePrefix` 在 ARB 里是 `提前 {value} {unit}` —— **两个**占位符都
  /// 必须在这里替换掉；只取 `noteB(key, zh)` 会在装了翻译表后把 `{value}`/`{unit}`
  /// 原样显示到界面上（真机可见缺陷）。
  String get label {
    final v = value;
    final u = unitSeconds;
    if (v == null || u == null) return noteB(labelKey, labelZh);
    return noteBFill(labelKey, labelZh, {
      'value': '$v',
      'unit': TodoReminderUnit.label(u),
    });
  }
}

/// 官方 6 个预设（自定义单列，不在这张表里）。
const List<TodoReminderPreset> todoReminderPresets = [
  TodoReminderPreset(
    TodoReminderPlanner.offsetOff,
    NoteBTextKeys.reminderOff,
    '不提醒',
  ),
  TodoReminderPreset(
    TodoReminderPlanner.offsetOnTime,
    NoteBTextKeys.reminderOnTime,
    '正点提醒',
  ),
  TodoReminderPreset(
    TodoReminderPlanner.offsetBefore30Min,
    NoteBTextKeys.reminderBeforePrefix,
    '提前 {value} {unit}',
    value: 30,
    unitSeconds: TodoReminderUnit.minute,
  ),
  TodoReminderPreset(
    TodoReminderPlanner.offsetBefore1Hour,
    NoteBTextKeys.reminderBeforePrefix,
    '提前 {value} {unit}',
    value: 1,
    unitSeconds: TodoReminderUnit.hour,
  ),
  TodoReminderPreset(
    TodoReminderPlanner.offsetBefore12Hours,
    NoteBTextKeys.reminderBeforePrefix,
    '提前 {value} {unit}',
    value: 12,
    unitSeconds: TodoReminderUnit.hour,
  ),
  TodoReminderPreset(
    TodoReminderPlanner.offsetBefore1Day,
    NoteBTextKeys.reminderBeforePrefix,
    '提前 {value} {unit}',
    value: 1,
    unitSeconds: TodoReminderUnit.day,
  ),
];

/// 自定义提醒的单位（官方 `R.array.reminder_custom_unit`：
/// minute/hour/day/week，对应秒数 60/3600/86400/604800）。
abstract final class TodoReminderUnit {
  static const int minute = 60;
  static const int hour = 3600;
  static const int day = 86400;
  static const int week = 604800;

  /// 单位 → 文案
  static String label(int unitSeconds) => switch (unitSeconds) {
    minute => noteB(NoteBTextKeys.reminderUnitMinute, '分钟'),
    hour => noteB(NoteBTextKeys.reminderUnitHour, '小时'),
    day => noteB(NoteBTextKeys.reminderUnitDay, '天'),
    week => noteB(NoteBTextKeys.reminderUnitWeek, '周'),
    _ => noteB(NoteBTextKeys.reminderUnitMinute, '分钟'),
  };

  /// 官方自定义值域：分钟 1..60、小时 1..24、天 1..31、周 1..8
  static int maxValue(int unitSeconds) => switch (unitSeconds) {
    minute => 60,
    hour => 24,
    day => 31,
    week => 8,
    _ => 60,
  };

  static const List<int> all = [minute, hour, day, week];
}

/// 待办提醒 / 逾期汇总的纯计算。
abstract final class TodoReminderPlanner {
  /// 官方 `Common.TODO_NO_REMINDER_OFFSET`
  static const int offsetOff = -1;

  /// 官方 `Common.REMINDER_OFFSET_ON_TIME`
  static const int offsetOnTime = 0;
  static const int offsetBefore30Min = 1800;
  static const int offsetBefore1Hour = 3600;
  static const int offsetBefore12Hours = 43200;
  static const int offsetBefore1Day = 86400;

  /// 官方 `Common.NINE_OCLOCK_TIME_IN_MILLIS`
  static const int defaultOverdueHour = 9;
  static const int defaultOverdueMinute = 0;

  /// `due_date` 无效（我们 DTO 里 -1 / 0 都是"没有截止日期"）
  static bool hasDueDate(TodoDto todo) => todo.dueDate > 0;

  /// 该不该为这条待办排提醒。
  ///
  /// 官方规则：`due_date == -1 || reminder_offset == -1` → 不排；
  /// `done` 的任务也不再排。
  static bool schedulesReminder(TodoDto todo) =>
      !todo.done &&
      hasDueDate(todo) &&
      todo.reminderOffset != offsetOff;

  /// 触发时刻（毫秒）；不排则 null。
  ///
  /// `reminder_offset` 是**秒**（官方），`dueDate` 是**毫秒**（我们的 DTO）。
  static int? fireAtMillis(TodoDto todo) {
    if (!schedulesReminder(todo)) return null;
    return todo.dueDate - todo.reminderOffset * 1000;
  }

  /// 从现在起还要等多久（毫秒）；已经过了 / 不排 → null。
  static int? delayMillisFrom(TodoDto todo, DateTime now) {
    final fire = fireAtMillis(todo);
    if (fire == null) return null;
    final delta = fire - now.millisecondsSinceEpoch;
    return delta >= 0 ? delta : null;
  }

  /// 提醒文案：`提前量` → 人读
  static String describeOffset(int offsetSeconds) {
    if (offsetSeconds == offsetOff) {
      return noteB(NoteBTextKeys.reminderOff, '不提醒');
    }
    if (offsetSeconds == offsetOnTime) {
      return noteB(NoteBTextKeys.reminderOnTime, '正点提醒');
    }
    if (offsetSeconds % TodoReminderUnit.week == 0) {
      return _before(
        offsetSeconds ~/ TodoReminderUnit.week,
        TodoReminderUnit.week,
      );
    }
    if (offsetSeconds % TodoReminderUnit.day == 0) {
      return _before(
        offsetSeconds ~/ TodoReminderUnit.day,
        TodoReminderUnit.day,
      );
    }
    if (offsetSeconds % TodoReminderUnit.hour == 0) {
      return _before(
        offsetSeconds ~/ TodoReminderUnit.hour,
        TodoReminderUnit.hour,
      );
    }
    return _before(
      offsetSeconds ~/ TodoReminderUnit.minute,
      TodoReminderUnit.minute,
    );
  }

  static String _before(int value, int unit) => noteBFill(
    NoteBTextKeys.reminderBeforePrefix,
    '提前 {value} {unit}',
    {'value': '$value', 'unit': TodoReminderUnit.label(unit)},
  );

  // ------------------------------------------------------------ 逾期汇总

  /// 今天 00:00（本地时区）的毫秒
  static int startOfDayMillis(DateTime now) =>
      DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;

  /// 官方查询：`done is 0 and due_date != -1 and due_date < 今天 00:00`
  /// （按 `due_date asc`）。
  static List<TodoDto> overdueTodos(List<TodoDto> todos, DateTime now) {
    final start = startOfDayMillis(now);
    final out = todos
        .where((t) => !t.done && hasDueDate(t) && t.dueDate < start)
        .toList();
    out.sort((a, b) => a.dueDate.compareTo(b.dueDate));
    return out;
  }

  /// 逾期汇总的 InboxStyle 明细行：`<可读时间> - <标题>`（官方原文）
  static List<String> overdueLines(List<TodoDto> overdue) => [
    for (final t in overdue) '${formatDueDate(t.dueDate)} - ${t.title}',
  ];

  /// 下一次"每日 HH:mm"触发的时刻（毫秒）。今天已过则明天。
  static DateTime nextDailyFire(DateTime now, int hour, int minute) {
    final today = DateTime(now.year, now.month, now.day, hour, minute);
    return today.isAfter(now) ? today : today.add(const Duration(days: 1));
  }

  /// `yyyy-MM-dd`（官方 `Utils.getReadableTime` 的日期部分）
  static String formatDueDate(int epochMillis) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMillis);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// 逾期汇总设置（官方两个偏好键：开关 + 时刻）。
@immutable
class TodoOverdueSettings {
  const TodoOverdueSettings({
    this.enabled = false,
    this.hour = TodoReminderPlanner.defaultOverdueHour,
    this.minute = TodoReminderPlanner.defaultOverdueMinute,
  });

  final bool enabled;
  final int hour;
  final int minute;

  String get label =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  TodoOverdueSettings copyWith({bool? enabled, int? hour, int? minute}) =>
      TodoOverdueSettings(
        enabled: enabled ?? this.enabled,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
      );

  /// 官方偏好键的字符串形态（持久化用）
  String encode() => '$enabled|$hour|$minute';

  @override
  bool operator ==(Object other) =>
      other is TodoOverdueSettings &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(enabled, hour, minute);

  static TodoOverdueSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) return const TodoOverdueSettings();
    final parts = raw.split('|');
    if (parts.length != 3) return const TodoOverdueSettings();
    final enabled = parts[0] == 'true';
    final hour = int.tryParse(parts[1]);
    final minute = int.tryParse(parts[2]);
    if (hour == null || minute == null) return const TodoOverdueSettings();
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return const TodoOverdueSettings();
    }
    return TodoOverdueSettings(
      enabled: enabled,
      hour: hour,
      minute: minute,
    );
  }
}
