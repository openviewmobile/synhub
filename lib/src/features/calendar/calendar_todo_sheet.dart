// 日历待办（`SYNO.Cal.Todo`）的新建/编辑/完成/删除弹层。
//
// 参数形态与编码口径见 `data/calendar_api.dart` 顶部表 + `createTodo`/`setTodo`
// 的注释：与 `Event/*` 同一套 Gson 参数层（真机验过），必填 7 个字段一个不能少。
//
// 为什么单独一个文件：日历页已经有事件详情/事件编辑两个弹层，再加待办会把
// `calendar_page.dart` 撑爆；这里的 key 命名与事件弹层保持一致，方便页面测试。
import 'package:flutter/material.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/calendar_dto.dart';

/// 弹层里用户做的动作
enum TodoEditAction { save, toggleDone, delete }

/// 弹层返回值（`null` = 用户取消）
class TodoEditResult {
  const TodoEditResult.save({
    required this.summary,
    required this.description,
    this.due,
    this.clearDue = false,
    this.calendar,
    this.done = false,
  }) : action = TodoEditAction.save;

  const TodoEditResult.toggleDone({required this.done})
    : action = TodoEditAction.toggleDone,
      summary = '',
      description = '',
      due = null,
      clearDue = false,
      calendar = null;

  const TodoEditResult.delete()
    : action = TodoEditAction.delete,
      summary = '',
      description = '',
      due = null,
      clearDue = false,
      done = false,
      calendar = null;

  final TodoEditAction action;
  final String summary;
  final String description;
  final DateTime? due;

  /// 用户点了"清除截止"（`set` 里唯一能表达"删掉 due"的方式）
  final bool clearDue;
  final bool done;

  /// 新建时选的待办日历（编辑时为 null）
  final CalendarDto? calendar;
}

/// 打开待办弹层。[todo] 为 null 表示新建。
Future<TodoEditResult?> showTodoEditorSheet(
  BuildContext context, {
  CalTodoDto? todo,
  List<CalendarDto> calendars = const [],
  DateTime? day,
}) {
  return showModalBottomSheet<TodoEditResult>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    builder: (ctx) => _TodoEditorSheet(
      todo: todo,
      calendars: calendars,
      day: day ?? DateTime.now(),
    ),
  );
}

class _TodoEditorSheet extends StatefulWidget {
  const _TodoEditorSheet({
    required this.todo,
    required this.calendars,
    required this.day,
  });

  final CalTodoDto? todo;
  final List<CalendarDto> calendars;
  final DateTime day;

  @override
  State<_TodoEditorSheet> createState() => _TodoEditorSheetState();
}

class _TodoEditorSheetState extends State<_TodoEditorSheet> {
  late final TextEditingController _title = TextEditingController(
    text: widget.todo?.summary ?? '',
  );
  late final TextEditingController _desc = TextEditingController(
    text: widget.todo?.description ?? '',
  );
  late CalendarDto? _calendar = widget.calendars.isEmpty
      ? null
      : widget.calendars.first;
  late DateTime? _due = widget.todo?.dueAt;
  late bool _done = widget.todo?.done ?? false;
  var _clearedDue = false;

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  bool get _editing => widget.todo != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg + inset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _editing ? context.t.calEditTodo : context.t.calNewTodo,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: context.t.photoClose,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            TextField(
              key: const Key('cal-todo-title'),
              controller: _title,
              autofocus: !_editing,
              decoration: InputDecoration(labelText: context.t.calTodoContent),
            ),
            const SizedBox(height: Gap.md),
            if (!_editing && widget.calendars.length > 1)
              DropdownButtonFormField<CalendarDto>(
                isExpanded: true,
                key: const Key('cal-todo-calendar'),
                initialValue: _calendar,
                decoration: InputDecoration(
                  labelText: context.t.calTodoCalendar,
                ),
                items: [
                  for (final c in widget.calendars)
                    DropdownMenuItem(value: c, child: Text(c.displayName)),
                ],
                onChanged: (v) => setState(() => _calendar = v ?? _calendar),
              ),
            if (_editing)
              DesignSwitchRow(
                key: const Key('cal-todo-done'),
                value: _done,
                contentPadding: EdgeInsets.zero,
                title: Text(context.t.calDone),
                onChanged: (v) => setState(() => _done = v),
              ),
            DesignRowTile(
              key: const Key('cal-todo-due'),
              contentPadding: EdgeInsets.zero,
              title: Text(context.t.calDueTime),
              subtitle: Text(
                _due == null ? context.t.calNotSet : _fmtDateTime(_due!),
              ),
              trailing: _due == null
                  ? const Icon(Icons.event_outlined)
                  : IconButton(
                      key: const Key('cal-todo-clear-due'),
                      tooltip: context.t.calClearDue,
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _due = null;
                        _clearedDue = true;
                      }),
                    ),
              onTap: _pickDue,
            ),
            TextField(
              key: const Key('cal-todo-desc'),
              controller: _desc,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: context.t.calTodoNoteOptional,
              ),
            ),
            const SizedBox(height: Gap.lg),
            FilledButton(
              key: const Key('cal-todo-save'),
              onPressed: _submitSave,
              child: Text(
                _editing ? context.t.actionSave : context.t.photoCreate,
              ),
            ),
            if (_editing) ...[
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                key: const Key('cal-todo-delete'),
                onPressed: () =>
                    Navigator.of(context).pop(const TodoEditResult.delete()),
                icon: const Icon(Icons.delete_outline),
                label: Text(context.t.calDeleteTodo),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _submitSave() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      AppSnack.show(context, context.t.calTodoContentRequired, error: true);
      return;
    }
    // 编辑时"勾选已完成"也走 save（`set` 一次请求改完，别发两次）
    final nextDone = _editing && _done;
    Navigator.of(context).pop(
      TodoEditResult.save(
        summary: title,
        description: _desc.text.trim(),
        due: _due,
        clearDue: _clearedDue,
        calendar: _calendar,
        done: nextDone,
      ),
    );
  }

  Future<void> _pickDue() async {
    final base = _due ?? widget.day;
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: base.hour, minute: base.minute),
    );
    if (!mounted) return;
    final picked = time ?? TimeOfDay(hour: base.hour, minute: base.minute);
    setState(() {
      _due = DateTime(
        date.year,
        date.month,
        date.day,
        picked.hour,
        picked.minute,
      );
      _clearedDue = false;
    });
  }
}

/// 截止时间（非空）→ `yyyy-MM-dd HH:mm`。空值的"未设置"由界面侧走
/// `context.t.calNotSet`，这里不再自带中文兜底。
String _fmtDateTime(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}
