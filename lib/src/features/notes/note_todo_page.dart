// 「待办」页（P1 · NoteStation）：`Todo/list` + 勾选完成（`Todo/set`）。
//
// 官方 Web 客户端的待办是**独立模块**（左侧 todo 入口），任务还能挂到笔记上
// （`note_id`）或挂子任务（`parent_id`）。这一版做"看 + 勾 + 层级"：
// 勾选走 `Todo/set`，并按官方形态（`object_id` 数组 + 顶层任务回发
// due_date/priority/reminder_offset/comment/star）发请求，避免服务端把字段清掉；
// `parent_id` 由 `note_todo_tree.dart` 拼成树（可折叠、可加子任务）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/note_dto.dart';
import '../../data/local/note_store.dart';
import 'note_overdue_settings_page.dart';
import 'note_providers.dart';
import 'note_reminder.dart';
import 'note_sync.dart';
import 'note_todo_editor_page.dart';
import 'note_todo_tree.dart';
import 'note_widgets.dart';

class NoteTodoPage extends ConsumerStatefulWidget {
  const NoteTodoPage({super.key});

  @override
  ConsumerState<NoteTodoPage> createState() => _NoteTodoPageState();
}

class _NoteTodoPageState extends ConsumerState<NoteTodoPage> {
  /// 收起来的父任务（默认全展开）
  final Set<String> _collapsed = {};

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final filter = ref.watch(todoFilterProvider);
    final timeoutOnly = ref.watch(todoTimeoutOnlyProvider);
    final timeout = ref.watch(noteTimeoutTodosProvider);
    final timeoutCount = timeout.value?.count ?? 0;
    // wave3：打开「已超时」时列表来源整体切到服务端 `list_timeout`
    // （不在前端按 due_date 自己算，口径与服务端 overdue 汇总一致）。
    final AsyncValue<List<TodoDto>> todos = timeoutOnly
        ? timeout.whenData((r) => r.todos)
        : ref.watch(noteTodosProvider);

    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(context.t.noteTodoTitle),
        actions: [
          IconButton(
            key: const Key('note-overdue-settings'),
            tooltip: noteB(NoteBTextKeys.overdueSettings, '逾期提醒'),
            icon: const Icon(Icons.notifications_active_outlined),
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => const NoteOverdueSettingsPage(),
              ),
            ),
          ),
          IconButton(
            tooltip: context.t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(noteTodosProvider);
              ref.invalidate(noteTimeoutTodosProvider);
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          // 4 个筛选 chip 在大字号 + 窄屏下会换行，而 AppBar 的这个槽只有 44px
          // （x2.0 实测溢出 44px）→ 改成**横向滚动单行**，永远不换行。
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Row(
                children: [
                  for (final option in [
                    (null, context.t.noteAll),
                    (false, context.t.noteTodoOpen),
                    (true, context.t.calDone),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.sm),
                      child: ChoiceChip(
                        label: Text(option.$2),
                        selected: !timeoutOnly && filter == option.$1,
                        onSelected: (_) {
                          // 选状态筛选就退出「已超时」模式（两者互斥）
                          ref
                              .read(todoTimeoutOnlyProvider.notifier)
                              .set(false);
                          ref
                              .read(todoFilterProvider.notifier)
                              .set(option.$1);
                        },
                      ),
                    ),
                  // wave3：`Todo/list_timeout` 的**已超时计数**入口；点开看列表。
                  ChoiceChip(
                    key: const Key('note-todo-timeout-chip'),
                    label: Text(
                      noteBFill(
                        NoteBTextKeys.todoTimeoutChip,
                        '已超时 {count}',
                        {'count': '$timeoutCount'},
                      ),
                    ),
                    selected: timeoutOnly,
                    onSelected: (v) =>
                        ref.read(todoTimeoutOnlyProvider.notifier).set(v),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(null),
        icon: const Icon(Icons.add),
        label: Text(context.t.calNewTodo),
      ),
      body: Column(
        children: [
          const NoteOfflineBanner(compact: true),
          Expanded(
            child: todos.when(
              loading: () => const AppListSkeleton(),
              error: (e, _) => AppErrorView(
                title: context.t.noteOpenTodosFailed,
                detail: describeNoteError(e, context.t),
                onRetry: () {
                  ref.invalidate(noteTodosProvider);
                  ref.invalidate(noteTimeoutTodosProvider);
                },
              ),
              data: (rows) => Builder(
                builder: (context) {
                  // 服务端给的是**扁平列表**，层级自己拼
                  // （孤儿子任务 / 成环都在纯函数里兜住了，见 note_todo_tree.dart）
                  final flat = flattenTodoTree(
                    buildTodoTree(rows, done: timeoutOnly ? null : filter),
                    _collapsed,
                  );
                  return RefreshIndicator(
                    onRefresh: () async {
                      ref.invalidate(noteTodosProvider);
                      ref.invalidate(noteTimeoutTodosProvider);
                      await ref
                          .read(noteTodosProvider.future)
                          .catchError((Object _) => const <TodoDto>[]);
                    },
                    child: flat.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height: 320,
                                child: AppEmptyState(
                                  icon: Icons.checklist_outlined,
                                  title: timeoutOnly
                                      ? noteB(
                                          NoteBTextKeys.todoTimeoutEmpty,
                                          '没有已超时的待办',
                                        )
                                      : context.t.noteNoTodos,
                                  message: timeoutOnly
                                      ? noteB(
                                          NoteBTextKeys.todoTimeoutHint,
                                          '所有待办都还在截止时间内',
                                        )
                                      : context.t.noteNoTodosMessage,
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            itemCount: flat.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 1,
                              indent: Gap.lg,
                              color: hud.line,
                            ),
                            padding: const EdgeInsets.only(bottom: 96),
                            itemBuilder: (context, i) {
                              final entry = flat[i];
                              final todo = entry.node.todo;
                              final collapsed = _collapsed.contains(
                                todo.objectId,
                              );
                              return _TodoRow(
                                todo: todo,
                                depth: entry.depth,
                                contextOnly: entry.node.contextOnly,
                                // 只有"真有子孙"的节点才画折叠三角和进度
                                childProgress: entry.node.hasChildren
                                    ? (
                                        done: entry.node.doneDescendants,
                                        total: entry.node.descendantCount,
                                      )
                                    : null,
                                collapsed: collapsed,
                                onToggleCollapse: entry.node.hasChildren
                                    ? () => setState(() {
                                        if (!_collapsed.remove(todo.objectId)) {
                                          _collapsed.add(todo.objectId);
                                        }
                                      })
                                    : null,
                                onToggle: (done) =>
                                    _toggle(context, ref, todo, done),
                                onEdit: () => _openEditor(todo),
                                onAddSubtask: () =>
                                    _openEditor(null, parent: todo),
                              );
                            },
                          ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openEditor(TodoDto? todo, {TodoDto? parent}) async {
    final t = context.t;
    final saved = await Navigator.of(context, rootNavigator: true)
        .push<TodoDto>(
          MaterialPageRoute<TodoDto>(
            builder: (_) => NoteTodoEditorPage(todo: todo, parent: parent),
          ),
        );
    if (!mounted) return;
    ref.invalidate(noteTodosProvider);
    ref.invalidate(noteTimeoutTodosProvider);
    if (saved != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.noteTodoSaved(saved.title))));
    }
  }

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    TodoDto todo,
    bool done,
  ) async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    final store = ref.read(noteStoreProvider);
    final sync = ref.read(noteSyncProvider.notifier);
    try {
      await api.setTodoDone(todo, done);
      await store.putTodo(todo, dirty: false);
      ref.invalidate(noteTodosProvider);
      ref.invalidate(noteTimeoutTodosProvider);
    } catch (e) {
      if (isOfflineError(e)) {
        // 离线勾选：本地先改，入队等联网再推
        await store.putTodo(todo.copyWith(done: done), dirty: true);
        await store.enqueue(NotePendingKind.todoSet, todo.objectId, {
          'title': todo.title,
          'comment': todo.comment,
          'done': done,
          'star': todo.star,
          'priority': todo.priority,
          'due_date': todo.dueDate,
        });
        await sync.refreshPending();
        ref.invalidate(noteTodosProvider);
        ref.invalidate(noteTimeoutTodosProvider);
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t.noteTodoOfflineChecked)));
        return;
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t.noteTodoUpdateFailed(describeNoteError(e, t))),
        ),
      );
    }
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({
    required this.todo,
    required this.onToggle,
    required this.onEdit,
    required this.onAddSubtask,
    this.depth = 0,
    this.contextOnly = false,
    this.childProgress,
    this.collapsed = false,
    this.onToggleCollapse,
  });

  final TodoDto todo;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;

  /// 给这个任务加一条子任务（`Todo/create` + `parent_id`）
  final VoidCallback onAddSubtask;

  /// 树深度（0 = 顶层）
  final int depth;

  /// 只是"给命中的子任务当上下文"才出现的父节点
  final bool contextOnly;

  /// 子孙完成进度（`done/total`），null = 没有子孙
  final ({int done, int total})? childProgress;
  final bool collapsed;
  final VoidCallback? onToggleCollapse;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    // `CheckboxListTile` 没有 `trailing`（M3 里 `secondary` 会跑到控件对面），
    // 所以外面套一层 Row 放「加子任务」按钮
    return Row(
      children: [
        Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: DesignCheckRow(
              value: todo.done,
              onChanged: (v) => onToggle(v),
              // 层级用左内边距表达（不画连线，列表里更干净）
              contentPadding: EdgeInsets.only(
                left: Gap.xs + depth * 16.0,
                right: Gap.xs,
              ),
              secondary: onToggleCollapse == null
                  ? null
                  : IconButton(
                      tooltip: collapsed
                          ? context.t.noteExpandSubtasks
                          : context.t.noteCollapseSubtasks,
                      icon: Icon(
                        collapsed ? Icons.chevron_right : Icons.expand_more,
                        size: 20,
                        color: hud.dim,
                      ),
                      onPressed: onToggleCollapse,
                    ),
              title: GestureDetector(
                onTap: onEdit,
                child: Row(
                  children: [
                    if (childProgress != null) ...[
                      _Pill(
                        text: '${childProgress!.done}/${childProgress!.total}',
                      ),
                      const SizedBox(width: Gap.xs),
                    ],
                    Expanded(
                      child: Text(
                        todo.title,
                        style: TextStyle(
                          decoration: todo.done
                              ? TextDecoration.lineThrough
                              : null,
                          color: todo.done
                              ? hud.dim
                              : contextOnly
                              ? hud.dim
                              : null,
                          fontWeight: depth == 0 ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 元信息（星标 / 优先级 / 截止 / 子任务 / 备注）数量不定、长度不定，
              // 用 `Row` 横排在大字号下必然溢出（2.0 缩放实测 61px）。
              // 收进一个 `Expanded` + `Wrap`：有界、放不下自动换行、信息不丢。
              subtitle: Row(
                children: [
                  if (todo.star) ...[
                    Icon(Icons.star, size: 13, color: scheme.primary),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (todo.priority != TodoPriority.none) ...[
                          _Pill(
                            text: context.t.notePriorityLabel(
                              TodoPriority.label(todo.priority),
                            ),
                          ),
                          const SizedBox(width: Gap.xs),
                        ],
                        if (todo.dueDate > 0)
                          _Pill(
                            text: context.t.noteDue(_date(todo.dueDate)),
                            warn: _overdue(todo),
                          ),
                        if (todo.parentId.isNotEmpty)
                          _Pill(text: context.t.noteSubtask),
                        if (todo.comment.isNotEmpty)
                          SizedBox(
                            width: double.infinity,
                            child: Text(
                              todo.comment,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: hud.dim, fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 顶层任务才给「加子任务」：子任务不再往下套（官方 Web 端也只做一层）
        if (depth == 0)
          IconButton(
            key: Key('todo-add-sub-${todo.objectId}'),
            tooltip: context.t.noteAddSubtask,
            icon: const Icon(Icons.subdirectory_arrow_right, size: 18),
            onPressed: onAddSubtask,
          ),
      ],
    );
  }

  bool _overdue(TodoDto t) =>
      !t.done &&
      t.dueDate > 0 &&
      t.dueDate < DateTime.now().millisecondsSinceEpoch;

  static String _date(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.warn = false});

  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(right: Gap.xs),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: warn ? scheme.errorContainer : hud.surface,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: warn ? scheme.onErrorContainer : hud.dim,
        ),
      ),
    );
  }
}
