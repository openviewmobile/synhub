// 待办提醒 / 逾期汇总的**调度**（P0-1）。
//
// 纯计算在 `note_reminder.dart`；这里只负责"到点把事件交出去"。
//
// ⚠️ 调度优先级（Android 平台批 A 之后）：
//   1. **系统级**：注入 [NoteReminderPlatform]（Android 走 `AlarmManager` +
//      通知渠道 `dsnote`，官方同构，见 `note_reminder_platform.dart`）。原生排上
//      了就**不再**排 Dart 定时器 —— 否则同一时刻会响两遍。
//   2. **前台回落**：平台缺失（桌面/单测）或原生明确返回 false（通道不在/
//      通知未授权）时，回落到批次 B 的前台 Dart `Timer`：App 进程活着时到点把
//      提醒/逾期汇总交给 UI（`NoteReminderHost`）。这条回落路径**必须保留**，
//      它让"能力不足"时至少不是完全没提醒（在设置页如实标注为前台）。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/note_dto.dart';
import '../../data/local/database.dart';
import '../chat/chat_session_controller.dart';
import 'note_providers.dart';
import 'note_reminder.dart';
import 'note_reminder_platform.dart';

/// 定时器句柄（可注入替身，测试里不用真等）。
abstract class TodoTimerHandle {
  void cancel();
}

/// 定时器工厂（默认走 `dart:async` 的 `Timer`）
typedef TodoTimerFactory =
    TodoTimerHandle Function(Duration delay, void Function() callback);

class _AsyncTimerHandle implements TodoTimerHandle {
  _AsyncTimerHandle(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

TodoTimerHandle defaultTodoTimerFactory(
  Duration delay,
  void Function() callback,
) => _AsyncTimerHandle(Timer(delay, callback));

/// 一条"到点了"的事件。
class TodoReminderEvent {
  const TodoReminderEvent.reminder(this.todo, this.fireAtMillis)
    : overdue = const [],
      isOverdue = false;

  const TodoReminderEvent.overdue(this.overdue)
    : todo = null,
      fireAtMillis = 0,
      isOverdue = true;

  /// 单条提醒（[isOverdue] = false 时非空）
  final TodoDto? todo;
  final int fireAtMillis;

  /// 逾期汇总（[isOverdue] = true 时非空，按 due_date 升序）
  final List<TodoDto> overdue;
  final bool isOverdue;
}

/// 前台调度器：把待办列表换算成一组定时器。
///
/// * 每条"设了截止日期 + 提醒提前量"的待办排一个定时器；
/// * 逾期汇总开启时，按每日 `HH:mm` 排一个（响完自动排下一天）。
///
/// 可注入 [clock] / [timerFactory]，单测里不需要真实时间。
class TodoReminderScheduler {
  TodoReminderScheduler({
    required this.onEvent,
    DateTime Function()? clock,
    TodoTimerFactory? timerFactory,
    NoteReminderPlatform? platform,
  }) : _clock = clock ?? DateTime.now,
       _timerFactory = timerFactory ?? defaultTodoTimerFactory,
       _platform = platform;

  /// 事件出口（UI 可在拿到实例后覆盖；默认丢弃）
  void Function(TodoReminderEvent event) onEvent;
  final DateTime Function() _clock;
  final TodoTimerFactory _timerFactory;

  /// 系统级实现；null / 返回 false 时回落前台 [TodoTimerFactory]
  final NoteReminderPlatform? _platform;

  final List<TodoTimerHandle> _timers = [];
  bool _disposed = false;
  bool _platformScheduled = false;

  /// 当前挂着的定时器数（测试用）
  int get timerCount => _timers.length;

  /// 是否已经交给系统级闹钟（而非前台 Timer）。测试用。
  bool get platformScheduled => _platformScheduled;

  /// 用最新的待办 + 设置重建全部提醒。
  ///
  /// **平台优先**：先整体交给 [NoteReminderPlatform]；只有它明确说"不行"
  /// （返回 false，例如通道缺失或通知未授权）才回落到前台 Timer。回落是异步的
  /// （要看原生的返回值），因此平台路径下 [timerCount] 可能在一个微任务之后才
  /// 变成非 0。
  void update(
    List<TodoDto> todos, {
    TodoOverdueSettings settings = const TodoOverdueSettings(),
  }) {
    if (_disposed) return;
    _cancelAll();
    final platform = _platform;
    if (platform != null) {
      final plan = NoteReminderPlan.from(todos, settings: settings, clock: _clock);
      unawaited(
        platform.schedule(plan).then((ok) {
          if (_disposed) return;
          _platformScheduled = ok;
          if (!ok) {
            // 如实回落：平台不可用 / 未授权，不能让提醒整个消失
            _scheduleTimers(todos, settings);
          }
        }),
      );
      return;
    }
    _scheduleTimers(todos, settings);
  }

  /// 前台 Timer 路径（批次 B 的原始实现，作为回落保留）。
  void _scheduleTimers(
    List<TodoDto> todos,
    TodoOverdueSettings settings,
  ) {
    if (_disposed) return;
    final now = _clock();
    for (final todo in todos) {
      final delay = TodoReminderPlanner.delayMillisFrom(todo, now);
      if (delay == null) continue;
      final fireAt = TodoReminderPlanner.fireAtMillis(todo)!;
      _timers.add(
        _timerFactory(Duration(milliseconds: delay), () {
          if (_disposed) return;
          onEvent(TodoReminderEvent.reminder(todo, fireAt));
        }),
      );
    }
    if (settings.enabled) {
      _scheduleOverdue(todos, settings);
    }
  }

  void _scheduleOverdue(
    List<TodoDto> todos,
    TodoOverdueSettings settings,
  ) {
    final now = _clock();
    final next = TodoReminderPlanner.nextDailyFire(
      now,
      settings.hour,
      settings.minute,
    );
    final delay = next.difference(now);
    _timers.add(
      _timerFactory(delay, () {
        if (_disposed) return;
        final overdue = TodoReminderPlanner.overdueTodos(todos, _clock());
        if (overdue.isEmpty) {
          // 官方 `TodoNotificationReceiver`：没有逾期任务就只打日志、不发通知
          return;
        }
        onEvent(TodoReminderEvent.overdue(overdue));
      }),
    );
  }

  void _cancelAll() {
    _platformScheduled = false;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  void dispose() {
    _disposed = true;
    _cancelAll();
  }
}

// ------------------------------------------------------------------ 本地偏好

/// 笔记模块自己的键值持久化（复用既有 `KeyValueRows` 表，不新增表/不改 schema）。
class NoteLocalPrefs {
  NoteLocalPrefs(this.db);

  final ChatDatabase db;

  Future<String?> get(String key) async {
    final row = await (db.select(
      db.keyValueRows,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> set(String key, String value) async {
    await db
        .into(db.keyValueRows)
        .insertOnConflictUpdate(KeyValueRow(key: key, value: value));
  }
}

final noteLocalPrefsProvider = Provider<NoteLocalPrefs>(
  (ref) => NoteLocalPrefs(ref.watch(chatDatabaseProvider)),
);

/// 官方偏好键（`Common.TODO_OVERDUE_NOTIFICATION_ENABLE/TIME` 合并成一条）
const String kTodoOverduePrefsKey = 'note_todo_overdue_settings';

/// 逾期汇总设置（默认：关闭、09:00 —— 官方默认值）。
final todoOverdueSettingsProvider =
    NotifierProvider<TodoOverdueSettingsNotifier, TodoOverdueSettings>(
      TodoOverdueSettingsNotifier.new,
    );

class TodoOverdueSettingsNotifier extends Notifier<TodoOverdueSettings> {
  @override
  TodoOverdueSettings build() {
    _restore();
    return const TodoOverdueSettings();
  }

  Future<void> _restore() async {
    final raw = await ref.read(noteLocalPrefsProvider).get(kTodoOverduePrefsKey);
    if (!ref.mounted) return;
    final decoded = TodoOverdueSettings.decode(raw);
    state = decoded;
  }

  Future<void> save(TodoOverdueSettings settings) async {
    state = settings;
    await ref
        .read(noteLocalPrefsProvider)
        .set(kTodoOverduePrefsKey, settings.encode());
  }

  Future<void> setEnabled(bool enabled) =>
      save(state.copyWith(enabled: enabled));

  Future<void> setTime(int hour, int minute) =>
      save(state.copyWith(hour: hour, minute: minute));
}

/// 调度器（页面挂载期间有效）。
///
/// 平台优先（Android 系统闹钟），原生不可用时**回落**前台 Timer ——
/// 回落路径见 [TodoReminderScheduler.update]。
///
/// `autoDispose`：没有页面监听时自动销毁，避免定时器泄漏。
final todoReminderSchedulerProvider =
    Provider.autoDispose<TodoReminderScheduler>((ref) {
      final scheduler = TodoReminderScheduler(
        onEvent: (_) {},
        platform: ref.watch(noteReminderPlatformProvider),
      );
      ref.onDispose(scheduler.dispose);
      return scheduler;
    });

/// 把当前待办列表推给调度器（UI 层在 build 里调用）。
void refreshTodoReminders(WidgetRef ref, {List<TodoDto>? todos}) {
  final scheduler = ref.read(todoReminderSchedulerProvider);
  final settings = ref.read(todoOverdueSettingsProvider);
  final list = todos ?? ref.read(noteTodosProvider).value ?? const <TodoDto>[];
  scheduler.update(list, settings: settings);
}
