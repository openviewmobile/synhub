// 待办提醒 / 逾期汇总的**前台宿主**（P0-1）。
//
// 挂在笔记页外层：页面活着时，把 `NoteTodoPage` 的待办列表交给
// `TodoReminderScheduler`，到点就弹一条应用内提示（SnackBar）。
//
// 为什么是"应用内"而不是系统通知：见 `note_reminder_service.dart` 顶部的
// 依赖边界说明 —— 系统级闹钟要么加新依赖、要么改 `android/**`，本批都禁止。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'note_providers.dart';
import 'note_reminder.dart';
import 'note_reminder_service.dart';

class NoteReminderHost extends ConsumerStatefulWidget {
  const NoteReminderHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NoteReminderHost> createState() => _NoteReminderHostState();
}

class _NoteReminderHostState extends ConsumerState<NoteReminderHost> {
  @override
  Widget build(BuildContext context) {
    // watch 一下把 autoDispose 的调度器钉住
    final scheduler = ref.watch(todoReminderSchedulerProvider);
    scheduler.onEvent = _handle;

    // 待办列表 / 逾期设置变化 → 重建定时器
    ref.listen(noteTodosProvider, (_, __) => refreshTodoReminders(ref));
    ref.listen(
      todoOverdueSettingsProvider,
      (_, __) => refreshTodoReminders(ref),
    );
    // 首帧也排一次（列表可能已经加载完）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      refreshTodoReminders(ref);
    });

    return widget.child;
  }

  void _handle(TodoReminderEvent event) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    if (event.isOverdue) {
      final count = event.overdue.length;
      final title = noteB(NoteBTextKeys.overdueTitle, '逾期提醒');
      final summary = noteBFill(
        NoteBTextKeys.overdueCount,
        '{count} 条任务已逾期',
        {'count': '$count'},
      );
      final lines = TodoReminderPlanner.overdueLines(event.overdue);
      messenger.showSnackBar(
        SnackBar(
          key: const Key('note-todo-overdue-notification'),
          duration: const Duration(seconds: 8),
          content: Text(
            [
              '$title · $summary',
              ...lines.take(5),
            ].join('\n'),
          ),
        ),
      );
      return;
    }
    final todo = event.todo;
    if (todo == null) return;
    final when = TodoReminderPlanner.formatDueDate(todo.dueDate);
    messenger.showSnackBar(
      SnackBar(
        key: Key('note-todo-reminder-${todo.objectId}'),
        content: Text('${todo.title} · $when'),
      ),
    );
  }
}
