// 待办的层级（P1 · NoteStation）：官方 `Todo` 用 `parent_id` 表示子任务，
// 服务端给的是**扁平列表**，层级由客户端拼。
//
// 这一层是纯函数（不碰 provider / 网络），方便离线用例把边角情况钉死：
//   * 父任务被筛掉 / 还没同步下来时，孤儿子任务按顶层显示（不能藏起来）；
//   * 脏数据成环（`a.parent = b`、`b.parent = a`）时断开，别让界面递归炸；
//   * 筛选（未完成 / 已完成）时保留"命中的节点 + 它的祖先"，
//     祖先只作为上下文（`contextOnly`，自身其实不匹配筛选条件）。

import '../../data/dto/note_dto.dart';

/// 树里的一个节点
class TodoNode {
  TodoNode(this.todo, this.children, {required this.contextOnly});

  final TodoDto todo;
  final List<TodoNode> children;

  /// 只是为了把命中的子任务挂在下面才出现的父节点（自身不匹配当前筛选）
  final bool contextOnly;

  bool get hasChildren => children.isNotEmpty;

  /// 所有后代（含子、孙…）的数量
  int get descendantCount =>
      children.fold(children.length, (n, c) => n + c.descendantCount);

  /// 后代里已完成的数量（画「1/3」那种进度用）
  int get doneDescendants =>
      children.fold(0, (n, c) => n + (c.todo.done ? 1 : 0) + c.doneDescendants);
}

/// 扁平待办 → 树。
///
/// [done] 为 null = 不筛；否则只保留 `todo.done == done` 的节点及其祖先。
///
/// 两条兜底规则（都是真机上会遇到的脏数据）：
///   1. 父任务不在这一批里（被筛掉 / 没同步下来）→ 提到顶层；
///   2. 成环（`A.parent=B`、`B.parent=A`）→ 从根走不到的节点也提成顶层，
///      绝不因为"找不到根"就把任务从列表里弄丢。
List<TodoNode> buildTodoTree(List<TodoDto> rows, {bool? done}) {
  final ids = {for (final t in rows) t.objectId};
  final hasParent = <String, bool>{
    for (final t in rows)
      t.objectId: t.parentId.isNotEmpty && ids.contains(t.parentId),
  };
  final byParent = <String, List<TodoDto>>{};
  for (final t in rows) {
    byParent
        .putIfAbsent(hasParent[t.objectId]! ? t.parentId : '', () => [])
        .add(t);
  }

  bool hit(TodoDto t) => done == null || t.done == done;

  // 一个节点要不要出现：自己命中，或后代里有命中的（成环时按"没命中"断链）
  bool hasHit(TodoDto t, Set<String> path) {
    if (hit(t)) return true;
    if (!path.add(t.objectId)) return false;
    final r = (byParent[t.objectId] ?? const <TodoDto>[]).any(
      (c) => hasHit(c, path),
    );
    path.remove(t.objectId);
    return r;
  }

  final emitted = <String>{};
  TodoNode make(TodoDto t) {
    emitted.add(t.objectId);
    final kids = <TodoNode>[];
    for (final c in byParent[t.objectId] ?? const <TodoDto>[]) {
      if (emitted.contains(c.objectId)) continue; // 环：断开
      if (!hasHit(c, <String>{})) continue; // 筛选：不命中且后代也不命中的整枝不要
      kids.add(make(c));
    }
    return TodoNode(t, kids, contextOnly: !hit(t));
  }

  final out = <TodoNode>[];
  // 第一轮：真正的根（没有父 / 父不在这一批里）
  for (final t in rows) {
    if (emitted.contains(t.objectId) || hasParent[t.objectId]!) continue;
    if (!hasHit(t, <String>{})) continue;
    out.add(make(t));
  }
  // 第二轮：谁都到不了的（成环）→ 提到顶层，不能丢
  for (final t in rows) {
    if (emitted.contains(t.objectId)) continue;
    if (!hasHit(t, <String>{})) continue;
    out.add(make(t));
  }
  return out;
}

/// 把树按"展开状态"压成可直接给 ListView 的线性表（深度优先）。
///
/// [collapsed] 里放的是**收起来**的节点 id（默认全展开）。
List<({TodoNode node, int depth})> flattenTodoTree(
  List<TodoNode> nodes,
  Set<String> collapsed,
) {
  final out = <({TodoNode node, int depth})>[];
  void walk(List<TodoNode> level, int depth) {
    for (final n in level) {
      out.add((node: n, depth: depth));
      if (n.hasChildren && !collapsed.contains(n.todo.objectId)) {
        walk(n.children, depth + 1);
      }
    }
  }

  walk(nodes, 0);
  return out;
}
