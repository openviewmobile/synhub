// 待办的新建 / 编辑（P1 · NoteStation）。
//
// 字段与官方 `CreateTodoOperation` / `SetTodoOperation` 一一对应：
// 标题、完成、截止日期、优先级（**枚举**，见 `TodoPriority`）、星标、备注。
// `due_date = -1` = 没有截止日期（官方 Web 端 `isNoDueDate`）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/note_dto.dart';
import 'note_providers.dart';
import 'note_reminder.dart';
import 'note_widgets.dart';

class NoteTodoEditorPage extends ConsumerStatefulWidget {
  const NoteTodoEditorPage({super.key, this.todo, this.parent});

  /// null = 新建
  final TodoDto? todo;

  /// 非空 = 给这个任务建**子任务**（新建时发 `parent_id`）
  final TodoDto? parent;

  @override
  ConsumerState<NoteTodoEditorPage> createState() => _NoteTodoEditorPageState();
}

class _NoteTodoEditorPageState extends ConsumerState<NoteTodoEditorPage> {
  late final TextEditingController _title = TextEditingController(
    text: widget.todo?.title ?? '',
  );
  late final TextEditingController _comment = TextEditingController(
    text: widget.todo?.comment ?? '',
  );
  late int _priority = widget.todo?.priority ?? TodoPriority.none;
  late int _dueDate = widget.todo?.dueDate ?? -1;
  late int _reminderOffset =
      widget.todo?.reminderOffset ?? TodoReminderPlanner.offsetOff;
  late bool _star = widget.todo?.star ?? false;
  late bool _done = widget.todo?.done ?? false;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final isNew = widget.todo == null;
    final parent = widget.parent;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(
          isNew
              ? (parent == null
                    ? context.t.calNewTodo
                    : context.t.noteNewSubtask)
              : context.t.calEditTodo,
        ),
        actions: [
          if (!isNew)
            IconButton(
              tooltip: context.t.dtoActionDelete,
              icon: const Icon(Icons.delete_outline),
              onPressed: _saving ? null : _delete,
            ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(context.t.actionSave),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          TextField(
            controller: _title,
            autofocus: isNew,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: context.t.dtoTaskGeneric,
              hintText: context.t.noteTaskHint,
            ),
          ),
          const SizedBox(height: Gap.lg),
          DesignRowTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.event_outlined, color: hud.dim),
            title: Text(context.t.noteDueDate),
            subtitle: Text(
              _dueDate > 0 ? _format(_dueDate) : context.t.dtoPriorityNone,
              style: TextStyle(color: hud.dim),
            ),
            trailing: _dueDate > 0
                ? IconButton(
                    tooltip: context.t.noteClearDueDate,
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _dueDate = -1;
                      // 没有截止日期就谈不上提前量（官方同样会取消闹钟）
                      _reminderOffset = TodoReminderPlanner.offsetOff;
                    }),
                  )
                : null,
            onTap: _pickDueDate,
          ),
          const Divider(height: 1),
          DesignRowTile(
            key: const Key('note-todo-reminder'),
            contentPadding: EdgeInsets.zero,
            enabled: _dueDate > 0,
            leading: Icon(Icons.alarm_outlined, color: hud.dim),
            title: Text(noteB(NoteBTextKeys.reminder, '提醒')),
            subtitle: Text(
              _dueDate > 0
                  ? TodoReminderPlanner.describeOffset(_reminderOffset)
                  : noteB(
                      NoteBTextKeys.reminderNeedsDueDate,
                      '先设置截止日期',
                    ),
              style: TextStyle(color: hud.dim),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _dueDate > 0 ? _pickReminder : null,
          ),
          const Divider(height: 1),
          DesignRowTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.flag_outlined, color: hud.dim),
            title: Text(context.t.notePriority),
            subtitle: Text(
              TodoPriority.label(_priority),
              style: TextStyle(color: hud.dim),
            ),
            trailing: DropdownButton<int>(
              value: _priority,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(
                  value: TodoPriority.none,
                  child: Text(context.t.dtoPriorityNone),
                ),
                DropdownMenuItem(
                  value: TodoPriority.low,
                  child: Text(context.t.dtoPriorityLow),
                ),
                DropdownMenuItem(
                  value: TodoPriority.medium,
                  child: Text(context.t.dtoPriorityMedium),
                ),
                DropdownMenuItem(
                  value: TodoPriority.high,
                  child: Text(context.t.dtoPriorityHigh),
                ),
              ],
              onChanged: (v) =>
                  setState(() => _priority = v ?? TodoPriority.none),
            ),
          ),
          const Divider(height: 1),
          DesignSwitchRow(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.star_outline, color: hud.dim),
            title: Text(context.t.noteStar),
            value: _star,
            onChanged: (v) => setState(() => _star = v),
          ),
          const Divider(height: 1),
          DesignSwitchRow(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.check_circle_outline, color: hud.dim),
            title: Text(context.t.calDone),
            value: _done,
            onChanged: (v) => setState(() => _done = v),
          ),
          const Divider(height: 1),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _comment,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: context.t.noteComment,
              hintText: context.t.noteOptional,
            ),
          ),
          const SizedBox(height: Gap.sm),
          Text(
            _priority == TodoPriority.none
                ? context.t.notePriorityHint
                : context.t.notePriorityValue(TodoPriority.label(_priority)),
            style: TextStyle(color: hud.dim, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final initial = _dueDate > 0
        ? DateTime.fromMillisecondsSinceEpoch(_dueDate)
        : now;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10),
    );
    if (date == null) return;
    // 官方按"当天 06:00"这类本地时刻存 epoch 毫秒（`defaultHour: 6`），
    // 这里就存选中日的 06:00，保持和 Web 端建任务时的观感一致
    setState(
      () => _dueDate = DateTime(
        date.year,
        date.month,
        date.day,
        6,
      ).millisecondsSinceEpoch,
    );
  }

  Future<void> _pickReminder() async {
    final picked = await showModalBottomSheet<_PickedReminder>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            DesignRowTile(
              title: Text(
                noteB(NoteBTextKeys.reminder, '提醒'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            for (final preset in todoReminderPresets)
              DesignRowTile(
                key: Key('note-todo-reminder-preset-${preset.offsetSeconds}'),
                title: Text(preset.label),
                trailing: _reminderOffset == preset.offsetSeconds
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(
                  context,
                ).pop(_PickedReminder(preset.offsetSeconds)),
              ),
            DesignRowTile(
              key: const Key('note-todo-reminder-custom'),
              title: Text(noteB(NoteBTextKeys.reminderCustom, '自定义')),
              onTap: () async {
                final custom = await _pickCustomReminder();
                if (custom == null || !context.mounted) return;
                Navigator.of(context).pop(_PickedReminder(custom));
              },
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _reminderOffset = picked.offsetSeconds);
  }

  Future<int?> _pickCustomReminder() async {
    var unit = TodoReminderUnit.minute;
    var value = 1;
    return showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(noteB(NoteBTextKeys.reminderCustom, '自定义')),
          content: Row(
            children: [
              Expanded(
                child: DropdownButton<int>(
                  key: const Key('note-todo-reminder-unit'),
                  value: unit,
                  isExpanded: true,
                  items: [
                    for (final u in TodoReminderUnit.all)
                      DropdownMenuItem(value: u, child: Text(TodoReminderUnit.label(u))),
                  ],
                  onChanged: (v) => setDialogState(() {
                    unit = v ?? TodoReminderUnit.minute;
                    value = 1;
                  }),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: DropdownButton<int>(
                  key: const Key('note-todo-reminder-value'),
                  value: value,
                  isExpanded: true,
                  items: [
                    for (var i = 1; i <= TodoReminderUnit.maxValue(unit); i++)
                      DropdownMenuItem(value: i, child: Text('$i')),
                  ],
                  onChanged: (v) => setDialogState(() => value = v ?? 1),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.t.actionCancel),
            ),
            FilledButton(
              key: const Key('note-todo-reminder-custom-ok'),
              onPressed: () => Navigator.of(context).pop(value * unit),
              child: Text(context.t.actionSave),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      _toast(context.t.noteTaskNameRequired);
      return;
    }
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    try {
      final TodoDto saved;
      if (widget.todo == null) {
        saved = await api.createTodo(
          title: title,
          done: _done,
          dueDate: _dueDate,
          reminderOffset: _reminderOffset,
          priority: _priority,
          comment: _comment.text.trim(),
          star: _star,
          parentId: widget.parent?.objectId,
        );
      } else {
        await api.updateTodo(
          objectId: widget.todo!.objectId,
          title: title,
          done: _done,
          dueDate: _dueDate,
          reminderOffset: _reminderOffset,
          priority: _priority,
          comment: _comment.text.trim(),
          star: _star,
          noteId: widget.todo!.noteId,
          parentId: widget.todo!.parentId,
        );
        saved = widget.todo!.copyWith(
          title: title,
          done: _done,
          dueDate: _dueDate,
          reminderOffset: _reminderOffset,
          priority: _priority,
          comment: _comment.text.trim(),
          star: _star,
        );
      }
      if (!mounted) return;
      navigator.pop(saved);
    } catch (e) {
      _toast(context.t.noteTodoSaveFailed(describeNoteError(e, context.t)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final api = ref.read(noteApiProvider);
    final todo = widget.todo;
    if (api == null || todo == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t.noteDeleteTodo),
        content: Text(context.t.noteDeleteTodoConfirm(todo.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    try {
      await api.deleteTodos([todo.objectId]);
      if (!mounted) return;
      navigator.pop();
    } catch (e) {
      _toast(context.t.noteTodoDeleteFailed(describeNoteError(e, context.t)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  static String _format(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}

/// 提醒选择器返回值（只用 offset，别把 UI 类型漏到外面）
class _PickedReminder {
  const _PickedReminder(this.offsetSeconds);

  final int offsetSeconds;
}
