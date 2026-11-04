// 待办提醒 / 逾期汇总的**系统级平台桥**（Android 平台批 A）。
//
// 批次 B 只有前台 Dart `Timer`（`note_reminder_service.dart`）。本文件把"到点
// 该响"这件事交给原生 `AlarmManager` + 通知渠道 `dsnote`（官方同构，证据 [E2]
// 见 `docs/note-b-implementation.md` 与 `docs/android-platform-a.md`）。
//
// 与原生 Kotlin（`android/app/src/main/kotlin/.../NoteReminderPlugin.kt`）的接口
// （MethodChannel `synhub/note_reminder`）：
//   * `status`             → { supported, notificationsGranted, exactAlarmAllowed }
//   * `requestPermissions` → 申请 `POST_NOTIFICATIONS`（13+）/ 拉起精确闹钟授权页（12+）
//   * `scheduleTodos`      → 用一份 [NoteReminderPlan] 重排全部闹钟 + 每日逾期汇总；
//                            返回 false 表示"原生这条路走不通"（通道缺失 / 通知未授权）
//                            → 调用方**必须**回落到前台 Timer，不许静默失败
//   * `cancelAll`          → 撤销本 App 的全部待办闹钟
//
// ⚠️ 单位换算**只有一处**：`TodoReminderPlanner.fireAtMillis`
// （`note_reminder.dart`）。本文件与 Kotlin 侧都**不再**做
// "（截止 - 提前量）× 1000" 的第二次换算：原生收到的 `fireAtMillis` 已经是绝对
// 毫秒时间戳；`dueDateMillis` / `reminderOffsetSeconds` 只用于**官方语义的取消
// 判定**（`dueDate == -1 || offset == -1` → 取消），不做算术。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/provider_retry.dart';
import '../../data/dto/note_dto.dart';
import 'note_reminder.dart';

/// 原生通道名（Kotlin `NoteReminderPlugin.CHANNEL` 必须一致）
const String kNoteReminderChannel = 'synhub/note_reminder';

/// 系统级提醒的**能力 / 授权快照**。
///
/// 三个字段互不替代：通道可能在（[supported]）但通知没授权
/// （[notificationsGranted] = false，Android 13+），或通知能发但精确闹钟被
/// 系统收回（[exactAlarmAllowed] = false，Android 12+）。设置页据此**如实**显示，
/// 不允许"看起来排上了、其实不会响"。
@immutable
class NoteReminderStatus {
  const NoteReminderStatus({
    this.supported = false,
    this.notificationsGranted = false,
    this.exactAlarmAllowed = false,
  });

  /// 原生通道存在（Android 且插件已挂）。false ⇒ 只能前台 Timer。
  final bool supported;

  /// 通知权限（Android 13+ 运行时权限；12- 恒 true）
  final bool notificationsGranted;

  /// 能否用 `setExact*`（Android 12+ `canScheduleExactAlarms()`；11- 恒 true）
  final bool exactAlarmAllowed;

  /// 系统级提醒真的会响（通道在 + 通知能发）
  bool get ready => supported && notificationsGranted;

  @override
  bool operator ==(Object other) =>
      other is NoteReminderStatus &&
      other.supported == supported &&
      other.notificationsGranted == notificationsGranted &&
      other.exactAlarmAllowed == exactAlarmAllowed;

  @override
  int get hashCode =>
      Object.hash(supported, notificationsGranted, exactAlarmAllowed);

  @override
  String toString() =>
      'NoteReminderStatus(supported: $supported, '
      'notificationsGranted: $notificationsGranted, '
      'exactAlarmAllowed: $exactAlarmAllowed)';

  static NoteReminderStatus fromMap(Object? raw) {
    if (raw is! Map) return const NoteReminderStatus();
    return NoteReminderStatus(
      supported: raw['supported'] == true,
      notificationsGranted: raw['notificationsGranted'] == true,
      exactAlarmAllowed: raw['exactAlarmAllowed'] == true,
    );
  }
}

/// 一条待办的**快照**（喂给原生的每日逾期汇总）。
///
/// 为什么要把"全部待办"也送到原生：官方 `TodoNotificationReceiver.notifyOverdue`
/// 是在**响铃时刻**查库（`done = 0 and due_date != -1 and due_date < 今天 00:00`）
/// 才知道该汇总哪几条。我们的进程那时已经死了，所以把快照持久化到原生，
/// 让 `NoteReminderOverdueReceiver` 在响铃时按同一规则自己过滤。
@immutable
class NoteReminderTodo {
  const NoteReminderTodo({
    required this.id,
    required this.title,
    required this.dueDateMillis,
    required this.done,
  });

  final String id;
  final String title;

  /// 我们 DTO 的截止日期（**毫秒**；`<= 0` 等价官方的 `-1`）
  final int dueDateMillis;
  final bool done;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'dueDate': dueDateMillis,
    'done': done,
  };

  @override
  bool operator ==(Object other) =>
      other is NoteReminderTodo &&
      other.id == id &&
      other.title == title &&
      other.dueDateMillis == dueDateMillis &&
      other.done == done;

  @override
  int get hashCode => Object.hash(id, title, dueDateMillis, done);
}

/// 一条要交给系统闹钟的提醒（**触发时刻已换算成绝对毫秒**）。
@immutable
class NoteReminderAlarm {
  const NoteReminderAlarm({
    required this.id,
    required this.title,
    required this.dueDateMillis,
    required this.reminderOffsetSeconds,
    required this.fireAtMillis,
  });

  /// 待办 `object_id`（原生用它算稳定的 PendingIntent requestCode / 通知 id）
  final String id;
  final String title;

  /// 我们 DTO 的截止日期（**毫秒**，官方是秒；仅用于原生的取消判定与展示）
  final int dueDateMillis;

  /// 官方 `reminder_offset`（**秒**；`-1` = 关闭）
  final int reminderOffsetSeconds;

  /// 绝对触发时刻（**毫秒**，epoch）。唯一换算处见文件头注释。
  final int fireAtMillis;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'dueDate': dueDateMillis,
    'reminderOffset': reminderOffsetSeconds,
    'fireAtMillis': fireAtMillis,
  };

  @override
  bool operator ==(Object other) =>
      other is NoteReminderAlarm &&
      other.id == id &&
      other.title == title &&
      other.dueDateMillis == dueDateMillis &&
      other.reminderOffsetSeconds == reminderOffsetSeconds &&
      other.fireAtMillis == fireAtMillis;

  @override
  int get hashCode =>
      Object.hash(id, title, dueDateMillis, reminderOffsetSeconds, fireAtMillis);
}

/// 一次"重排全部提醒"的完整计划。
///
/// 为什么把取消也显式带出来：官方 `Utils.updateTodoReminderNotification` 对
/// `dueDate == -1 || offset == -1` 是**取消**，不是"什么都不做"。原生侧按这个
/// 列表逐条撤销 `PendingIntent`，这样"关掉提醒 / 标记完成 / 删除待办"都会让旧
/// 闹钟消失，而不是留在系统里继续响。
@immutable
class NoteReminderPlan {
  const NoteReminderPlan({
    required this.alarms,
    required this.cancelledIds,
    required this.todos,
    this.overdueEnabled = false,
    this.overdueHour = TodoReminderPlanner.defaultOverdueHour,
    this.overdueMinute = TodoReminderPlanner.defaultOverdueMinute,
  });

  final List<NoteReminderAlarm> alarms;

  /// 需要撤销闹钟的待办 id（`done` / 无截止日期 / `offset == -1` / 已过触发点）
  final List<String> cancelledIds;

  /// **全部**待办快照（原生持久化后供每日逾期汇总在响铃时刻自行过滤）
  final List<NoteReminderTodo> todos;

  final bool overdueEnabled;
  final int overdueHour;
  final int overdueMinute;

  /// 纯计算：把待办列表 + 逾期设置换算成一份计划。
  ///
  /// [clock] 可注入，单测不依赖真实时间。
  static NoteReminderPlan from(
    List<TodoDto> todos, {
    TodoOverdueSettings settings = const TodoOverdueSettings(),
    DateTime Function()? clock,
  }) {
    final now = (clock ?? DateTime.now)().millisecondsSinceEpoch;
    final alarms = <NoteReminderAlarm>[];
    final cancelled = <String>[];
    for (final todo in todos) {
      // 唯一换算处（`note_reminder.dart` 的 fireAtMillis）
      final fire = TodoReminderPlanner.fireAtMillis(todo);
      if (fire == null || fire <= now) {
        // 官方：无效 / 关闭 / 已完成 → 取消；已经过点也不再补排（旧闹钟要撤销）
        cancelled.add(todo.objectId);
        continue;
      }
      alarms.add(
        NoteReminderAlarm(
          id: todo.objectId,
          title: todo.title,
          dueDateMillis: todo.dueDate,
          reminderOffsetSeconds: todo.reminderOffset,
          fireAtMillis: fire,
        ),
      );
    }
    return NoteReminderPlan(
      alarms: alarms,
      cancelledIds: cancelled,
      todos: [
        for (final t in todos)
          NoteReminderTodo(
            id: t.objectId,
            title: t.title,
            dueDateMillis: t.dueDate,
            done: t.done,
          ),
      ],
      overdueEnabled: settings.enabled,
      overdueHour: settings.hour,
      overdueMinute: settings.minute,
    );
  }

  Map<String, Object?> toMap() => {
    'alarms': [for (final a in alarms) a.toMap()],
    'cancelIds': cancelledIds,
    'todos': [for (final t in todos) t.toMap()],
    'overdueEnabled': overdueEnabled,
    'overdueHour': overdueHour,
    'overdueMinute': overdueMinute,
  };

  @override
  String toString() =>
      'NoteReminderPlan(alarms: ${alarms.length}, '
      'cancelled: ${cancelledIds.length}, overdue: $overdueEnabled '
      '$overdueHour:$overdueMinute)';
}

/// 平台实现（测试里注入假实现；真实现走 MethodChannel）。
abstract class NoteReminderPlatform {
  /// 当前能力 / 授权快照（不申请任何东西）。
  Future<NoteReminderStatus> status();

  /// 申请通知权限（13+ 运行时）/ 拉起精确闹钟授权页（12+），返回申请后的快照。
  Future<NoteReminderStatus> requestPermissions();

  /// 按 [plan] 重排系统闹钟。
  ///
  /// 返回 **false** 表示原生不可用（通道缺失）或通知未授权 → 调用方回落到前台
  /// Timer。**绝不允许**在失败时假装成功。
  Future<bool> schedule(NoteReminderPlan plan);

  /// 撤销本 App 的全部待办闹钟。
  Future<void> cancelAll();

  void dispose();
}

/// 真实现：MethodChannel `synhub/note_reminder`。
///
/// 任何 `MissingPluginException` / `PlatformException` 都当作"平台不可用"
/// （返回 false / 默认快照），由上层回落 —— 这样 iOS/桌面/单测都不会炸。
class MethodChannelNoteReminderPlatform implements NoteReminderPlatform {
  MethodChannelNoteReminderPlatform([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(kNoteReminderChannel);

  final MethodChannel _channel;

  /// 第 55 轮：`synhub/note_reminder` 只有 Android 侧实现 ⇒ 宿主上如实报
  /// "未实现"，回落前台 Timer（`TodoReminderScheduler` 已有这条回落路径）。
  static bool get _allowed => capabilityGateAllows(AppCapability.noteReminders);

  static void _logBlocked(String what) => debugPrint(
    capabilityGateLog(AppCapability.noteReminders, 'note_reminder.$what'),
  );

  @override
  Future<NoteReminderStatus> status() async {
    if (!_allowed) {
      _logBlocked('status');
      return const NoteReminderStatus();
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('status');
      return NoteReminderStatus.fromMap(raw);
    } on MissingPluginException {
      // 没有原生实现（桌面/单测）—— 不是错误，回落前台 Timer
      return const NoteReminderStatus();
    } on PlatformException catch (e) {
      debugPrint('[note_reminder] status 失败：$e');
      return const NoteReminderStatus();
    }
  }

  @override
  Future<NoteReminderStatus> requestPermissions() async {
    if (!_allowed) {
      _logBlocked('requestPermissions');
      return const NoteReminderStatus();
    }
    try {
      await _channel.invokeMethod<Object?>('requestPermissions');
    } on MissingPluginException {
      // 同上
    } on PlatformException catch (e) {
      debugPrint('[note_reminder] requestPermissions 失败：$e');
    }
    return status();
  }

  @override
  Future<bool> schedule(NoteReminderPlan plan) async {
    if (!_allowed) {
      _logBlocked('scheduleTodos');
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('scheduleTodos', plan.toMap());
      return ok ?? false;
    } on MissingPluginException {
      // 平台缺失：明确回落，不静默吞掉
      return false;
    } on PlatformException catch (e) {
      debugPrint('[note_reminder] scheduleTodos 失败：$e');
      return false;
    }
  }

  @override
  Future<void> cancelAll() async {
    if (!_allowed) {
      _logBlocked('cancelAll');
      return;
    }
    try {
      await _channel.invokeMethod<Object?>('cancelAll');
    } on MissingPluginException {
      // 平台缺失
    } on PlatformException catch (e) {
      debugPrint('[note_reminder] cancelAll 失败：$e');
    }
  }

  @override
  void dispose() {}
}

/// 平台实现（全局单例；`MethodChannel` 自己不需要释放）。
final noteReminderPlatformProvider = Provider<NoteReminderPlatform>((ref) {
  final platform = MethodChannelNoteReminderPlatform();
  ref.onDispose(platform.dispose);
  return platform;
});

/// 能力 / 授权快照（设置页 watch 它来**据实**显示文案）。
final noteReminderStatusProvider =
    FutureProvider.autoDispose<NoteReminderStatus>((ref) async {
      return ref.watch(noteReminderPlatformProvider).status();
    }, retry: noRetry);
