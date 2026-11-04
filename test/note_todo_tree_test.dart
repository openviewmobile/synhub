// 待办层级（`parent_id`）纯函数：边角情况离线钉死。
//
// 这些"脏数据"在真机上真会出现（别的客户端删了父任务、同步只拉到子任务、
// 老版本数据成环），界面绝不能因此丢任务或递归爆栈。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/features/notes/note_todo_tree.dart';

TodoDto _t(String id, {String? parent, bool done = false, String title = ''}) =>
    TodoDto(
      objectId: id,
      title: title.isEmpty ? '任务$id' : title,
      done: done,
      parentId: parent ?? '',
    );

void main() {
  group('buildTodoTree', () {
    test('父子按 parent_id 归位，顺序保持服务端给的顺序', () {
      final nodes = buildTodoTree([
        _t('P1', title: '搬家'),
        _t('C1', parent: 'P1'),
        _t('C2', parent: 'P1'),
        _t('P2', title: '报销'),
      ]);
      expect(nodes.map((n) => n.todo.objectId), ['P1', 'P2']);
      expect(nodes.first.children.map((n) => n.todo.objectId), ['C1', 'C2']);
      expect(nodes.first.descendantCount, 2);
      expect(nodes.first.hasChildren, isTrue);
      expect(nodes.first.children.first.hasChildren, isFalse);
    });

    test('父任务不在这一批里 → 子任务提到顶层（宁可平铺也不丢）', () {
      final nodes = buildTodoTree([_t('C1', parent: 'GONE')]);
      expect(nodes.length, 1);
      expect(nodes.single.todo.objectId, 'C1');
    });

    test('成环数据断开，不递归爆栈', () {
      // A.parent = B，B.parent = A
      final nodes = buildTodoTree([_t('A', parent: 'B'), _t('B', parent: 'A')]);
      // 两个都能画出来（至少一个变成根），不抛异常
      final ids = <String>[];
      void walk(List<TodoNode> level) {
        for (final n in level) {
          ids.add(n.todo.objectId);
          walk(n.children);
        }
      }

      walk(nodes);
      expect(ids.toSet(), {'A', 'B'});
    });

    test('筛选：只留命中的节点 + 它的祖先（祖先标 contextOnly）', () {
      final nodes = buildTodoTree([
        _t('P1', done: true, title: '搬家'),
        _t('C1', parent: 'P1', done: true),
        _t('C2', parent: 'P1', done: false),
        _t('X1', done: true, title: '别的'),
      ], done: false);
      expect(nodes.single.todo.objectId, 'P1');
      expect(nodes.single.contextOnly, isTrue, reason: '父自己不匹配，只是上下文');
      expect(nodes.single.children.single.todo.objectId, 'C2');
      expect(nodes.single.children.single.contextOnly, isFalse);
    });

    test('筛选：整枝都不命中就整枝不出现', () {
      final nodes = buildTodoTree([
        _t('P1', done: true),
        _t('C1', parent: 'P1', done: true),
      ], done: false);
      expect(nodes, isEmpty);
    });

    test('进度统计只数子孙（不含自己）', () {
      final nodes = buildTodoTree([
        _t('P1'),
        _t('C1', parent: 'P1', done: true),
        _t('C2', parent: 'P1', done: false),
        _t('G1', parent: 'C2', done: true),
      ]);
      final root = nodes.single;
      expect(root.descendantCount, 3);
      expect(root.doneDescendants, 2);
      expect(root.children[0].doneDescendants, 0);
      expect(root.children[1].doneDescendants, 1);
    });
  });

  group('flattenTodoTree', () {
    test('默认全展开，深度优先', () {
      final tree = buildTodoTree([
        _t('P1'),
        _t('C1', parent: 'P1'),
        _t('G1', parent: 'C1'),
        _t('P2'),
      ]);
      final flat = flattenTodoTree(tree, const {});
      expect(flat.map((e) => '${e.node.todo.objectId}@${e.depth}'), [
        'P1@0',
        'C1@1',
        'G1@2',
        'P2@0',
      ]);
    });

    test('收起来的节点：自己不画子，兄弟照画', () {
      final tree = buildTodoTree([_t('P1'), _t('C1', parent: 'P1'), _t('P2')]);
      final flat = flattenTodoTree(tree, {'P1'});
      expect(flat.map((e) => e.node.todo.objectId), ['P1', 'P2']);
    });
  });
}
