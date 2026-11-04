// 待办提醒 / 逾期汇总的纯逻辑 + 调度器用例（批次 B / P0-1）。
//
// 全部离线：时间、定时器都注入，不联网、不碰设备。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/features/notes/note_reminder.dart';
import 'package:synhub/src/features/notes/note_reminder_service.dart';

TodoDto _todo({
  String id = 't1',
  String title = '写周报',
  bool done = false,
  int dueDate = -1,
  int reminderOffset = -1,
  int priority = -1,
}) => TodoDto(
  objectId: id,
  title: title,
  done: done,
  dueDate: dueDate,
  reminderOffset: reminderOffset,
  priority: priority,
);

DateTime _at(int y, int m, int d, [int hh = 0, int mm = 0]) =>
    DateTime(y, m, d, hh, mm);

void main() {
  group('TodoReminderPlanner · 提醒', () {
    test('due_date 是 -1 / 0 → 不排提醒', () {
      expect(TodoReminderPlanner.schedulesReminder(_todo()), isFalse);
      expect(
        TodoReminderPlanner.schedulesReminder(
          _todo(dueDate: 0, reminderOffset: 0),
        ),
        isFalse,
      );
    });

    test('reminder_offset = -1（关）→ 不排；即便有截止日期', () {
      expect(
        TodoReminderPlanner.schedulesReminder(
          _todo(dueDate: 1700000000000, reminderOffset: -1),
        ),
        isFalse,
      );
      expect(
        TodoReminderPlanner.fireAtMillis(
          _todo(dueDate: 1700000000000, reminderOffset: -1),
        ),
        isNull,
      );
    });

    test('已完成的任务不再排提醒', () {
      expect(
        TodoReminderPlanner.schedulesReminder(
          _todo(done: true, dueDate: 1700000000000, reminderOffset: 0),
        ),
        isFalse,
      );
    });

    test('触发时刻 = 截止(毫秒) - 提前量(秒)*1000（正点 = 0）', () {
      final todo = _todo(dueDate: 1700000000000, reminderOffset: 3600);
      expect(TodoReminderPlanner.fireAtMillis(todo), 1700000000000 - 3600000);
      expect(
        TodoReminderPlanner.fireAtMillis(
          _todo(dueDate: 1700000000000, reminderOffset: 0),
        ),
        1700000000000,
      );
    });

    test('已经过了触发点 → delay 为 null（不补发，官方也是取消）', () {
      final now = _at(2023, 11, 15);
      final past = _todo(
        dueDate: now.millisecondsSinceEpoch - 1000,
        reminderOffset: 0,
      );
      expect(TodoReminderPlanner.delayMillisFrom(past, now), isNull);
      final future = _todo(
        dueDate: now.millisecondsSinceEpoch + 60 * 1000,
        reminderOffset: 0,
      );
      expect(TodoReminderPlanner.delayMillisFrom(future, now), 60 * 1000);
    });

    test('预设就是官方 6 个 + 自定义单位', () {
      expect(todoReminderPresets.map((e) => e.offsetSeconds).toList(), [
        -1,
        0,
        1800,
        3600,
        43200,
        86400,
      ]);
      expect(TodoReminderUnit.all, [60, 3600, 86400, 604800]);
      expect(TodoReminderUnit.maxValue(TodoReminderUnit.hour), 24);
    });

    test('提前量文案：正点 / 分 / 时 / 天 / 周', () {
      expect(TodoReminderPlanner.describeOffset(-1), '不提醒');
      expect(TodoReminderPlanner.describeOffset(0), '正点提醒');
      expect(TodoReminderPlanner.describeOffset(1800), '提前 30 分钟');
      expect(TodoReminderPlanner.describeOffset(3600), '提前 1 小时');
      expect(TodoReminderPlanner.describeOffset(43200), '提前 12 小时');
      expect(TodoReminderPlanner.describeOffset(86400), '提前 1 天');
      expect(TodoReminderPlanner.describeOffset(604800), '提前 1 周');
    });
  });

  group('TodoReminderPlanner · 逾期汇总', () {
    final now = _at(2026, 9, 21, 10, 0);
    final todayStart = _at(2026, 9, 21).millisecondsSinceEpoch;

    test('只收「未完成 + 有截止日期 + 截止日期 < 今天 00:00」', () {
      final todos = [
        _todo(id: 'a', dueDate: todayStart - 86400000), // 昨天
        _todo(id: 'b', dueDate: todayStart - 1000), // 今天前一刻
        _todo(id: 'c', dueDate: todayStart + 1000), // 今天
        _todo(id: 'd', dueDate: -1), // 无截止
        _todo(id: 'e', dueDate: todayStart - 86400000, done: true), // 已完成
      ];
      final overdue = TodoReminderPlanner.overdueTodos(todos, now);
      expect(overdue.map((e) => e.objectId).toList(), ['a', 'b']);
    });

    test('按 due_date 升序（官方 order by due_date asc）', () {
      final todos = [
        _todo(id: 'late', dueDate: todayStart - 1000),
        _todo(id: 'early', dueDate: todayStart - 90000000),
        _todo(id: 'mid', dueDate: todayStart - 4000000),
      ];
      expect(
        TodoReminderPlanner.overdueTodos(
          todos,
          now,
        ).map((e) => e.objectId).toList(),
        ['early', 'mid', 'late'],
      );
    });

    test('明细行是官方形态 `<日期> - <标题>`', () {
      final overdue = [
        _todo(
          id: 'a',
          title: '交房租',
          dueDate: _at(2026, 9, 1).millisecondsSinceEpoch,
        ),
      ];
      expect(TodoReminderPlanner.overdueLines(overdue), ['2026-09-01 - 交房租']);
    });

    test('下一次每日触发：今天没过就是今天，过了就明天', () {
      final now = _at(2026, 9, 21, 8, 0);
      expect(
        TodoReminderPlanner.nextDailyFire(now, 9, 0),
        _at(2026, 9, 21, 9, 0),
      );
      final later = _at(2026, 9, 21, 10, 30);
      expect(
        TodoReminderPlanner.nextDailyFire(later, 9, 0),
        _at(2026, 9, 22, 9, 0),
      );
    });

    test('默认设置 = 关闭 + 09:00（官方 NINE_OCLOCK_TIME_IN_MILLIS）', () {
      const s = TodoOverdueSettings();
      expect(s.enabled, isFalse);
      expect(s.hour, 9);
      expect(s.minute, 0);
    });

    test('设置编解码；烂数据回落默认', () {
      const s = TodoOverdueSettings(enabled: true, hour: 7, minute: 5);
      expect(TodoOverdueSettings.decode(s.encode()), s);
      expect(TodoOverdueSettings.decode(null), const TodoOverdueSettings());
      expect(TodoOverdueSettings.decode('x'), const TodoOverdueSettings());
      expect(
        TodoOverdueSettings.decode('true|99|0'),
        const TodoOverdueSettings(),
      );
    });
  });

  group('TodoReminderScheduler', () {
    test('给每条可提醒的待办排一个定时器；关掉的/已完成的没有', () {
      final now = _at(2026, 9, 21, 9, 0);
      final timers = <_FakeTimer>[];
      final events = <TodoReminderEvent>[];
      final scheduler = TodoReminderScheduler(
        onEvent: events.add,
        clock: () => now,
        timerFactory: (delay, cb) {
          final t = _FakeTimer(delay, cb);
          timers.add(t);
          return t;
        },
      );
      scheduler.update([
        _todo(
          id: 'on',
          dueDate: now.millisecondsSinceEpoch + 3600 * 1000,
          reminderOffset: 1800,
        ),
        _todo(
          id: 'off',
          dueDate: now.millisecondsSinceEpoch + 3600 * 1000,
          reminderOffset: -1,
        ),
        _todo(
          id: 'done',
          done: true,
          dueDate: now.millisecondsSinceEpoch + 3600 * 1000,
          reminderOffset: 0,
        ),
      ]);
      expect(timers.length, 1);
      expect(timers.single.delay, const Duration(minutes: 30));
      timers.single.fire();
      expect(events.single.isOverdue, isFalse);
      expect(events.single.todo!.objectId, 'on');
    });

    test('逾期汇总开启 → 额外排一个每日定时器，到点只报未完成逾期项', () {
      final now = _at(2026, 9, 21, 8, 0);
      final timers = <_FakeTimer>[];
      final events = <TodoReminderEvent>[];
      final scheduler = TodoReminderScheduler(
        onEvent: events.add,
        clock: () => now,
        timerFactory: (delay, cb) {
          final t = _FakeTimer(delay, cb);
          timers.add(t);
          return t;
        },
      );
      scheduler.update(
        [_todo(id: 'over', dueDate: _at(2026, 9, 20).millisecondsSinceEpoch)],
        settings: const TodoOverdueSettings(enabled: true, hour: 9, minute: 0),
      );
      expect(timers.length, 1);
      expect(timers.single.delay, const Duration(hours: 1));
      timers.single.fire();
      expect(events.single.isOverdue, isTrue);
      expect(events.single.overdue.map((e) => e.objectId), ['over']);
    });

    test('逾期汇总没有逾期项 → 不发事件（官方只打日志）', () {
      final now = _at(2026, 9, 21, 8, 0);
      final timers = <_FakeTimer>[];
      final events = <TodoReminderEvent>[];
      final scheduler = TodoReminderScheduler(
        onEvent: events.add,
        clock: () => now,
        timerFactory: (delay, cb) {
          final t = _FakeTimer(delay, cb);
          timers.add(t);
          return t;
        },
      );
      scheduler.update([
        _todo(id: 'future', dueDate: now.millisecondsSinceEpoch + 99999),
      ], settings: const TodoOverdueSettings(enabled: true));
      timers.single.fire();
      expect(events, isEmpty);
    });

    test('dispose 后定时器全部取消，且事件不再发出', () {
      final now = _at(2026, 9, 21, 9, 0);
      final timers = <_FakeTimer>[];
      final events = <TodoReminderEvent>[];
      final scheduler = TodoReminderScheduler(
        onEvent: events.add,
        clock: () => now,
        timerFactory: (delay, cb) {
          final t = _FakeTimer(delay, cb);
          timers.add(t);
          return t;
        },
      );
      scheduler.update([
        _todo(dueDate: now.millisecondsSinceEpoch + 1000, reminderOffset: 0),
      ]);
      scheduler.dispose();
      expect(timers.single.cancelled, isTrue);
      timers.single.fire();
      expect(events, isEmpty);
    });
  });
}

class _FakeTimer implements TodoTimerHandle {
  _FakeTimer(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool cancelled = false;

  void fire() {
    if (cancelled) return;
    callback();
  }

  @override
  void cancel() => cancelled = true;
}
