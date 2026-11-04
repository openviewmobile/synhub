// Mock NAS 端到端验证 · **笔记模块**（`lib/src/data/note_api.dart`）。
//
// 每个 `test` 对应 `docs/parity-final-gap-table.md` 里一行 🟡 —— 判据是
// 「发出真实请求 → mock 响应 → App 侧状态/DTO 正确」，并且对**写操作**额外
// 断言 mock 内存状态真的变了（"操作后状态正确"）。
//
// ⚠️ 全部只连 127.0.0.1 的进程内 mock；**不对任何真实 NAS 发起请求**。
// ⚠️ 这是**离线端到端**证据，不等于真机证据（真机网络策略/权限/版本仍未验）。

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/note_api.dart';

import 'support/mock_nas_harness.dart';

Future<MockNasHarness> _boot() =>
    startMockNasHarness(declaredApis: const {'note'});

void main() {
  group('笔记 · 回收站 / 批量 / 复制 / 移动', () {
    test('A7 回收站列表与还原（Note/restore）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final before = await note.listNotes();
      final recycled = before.notes.where((n) => n.recycle).toList();
      expect(recycled.map((n) => n.objectId), contains('n-3'));

      await note.restoreNote('n-3');

      final after = await note.listNotes();
      expect(
        after.notes.firstWhere((n) => n.objectId == 'n-3').recycle,
        isFalse,
      );
      expect(h.store.notes['n-3']!.recycle, isFalse);
    });

    test('A8 清空回收站（Note/delete v3 整筐数组 recycle:false）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final recycled = (await note.listNotes()).notes
          .where((n) => n.recycle)
          .map((n) => n.objectId)
          .toList();
      expect(recycled, isNotEmpty);

      final result = await note.deleteNotes(recycled, recycle: false);
      expect(result.hasFailure, isFalse);

      final after = await note.listNotes();
      expect(after.notes.where((n) => n.recycle), isEmpty);
      for (final id in recycled) {
        expect(h.store.notes.containsKey(id), isFalse);
      }
    });

    test('A9 复制笔记（Note/copy）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final newId = await note.copyNote('n-1');
      expect(newId, isNotEmpty);
      expect(newId, isNot('n-1'));

      final copy = await note.getNote(newId);
      expect(copy.title, contains('副本'));
      expect(copy.parentId, 'nb-1');
      expect(copy.tags, contains('tag-work'));
      expect(h.store.notes.containsKey(newId), isTrue);
    });

    test('A11 移动到其他笔记本（Note/set parent_id）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final current = await note.getNote('n-2');
      await note.setNote(objectId: 'n-2', ver: current.ver, parentId: 'nb-2');

      final moved = await note.getNote('n-2');
      expect(moved.parentId, 'nb-2');
      expect(h.store.notes['n-2']!.parentId, 'nb-2');
    });

    test('A12 多选批量删除 + 批量移动（Note/delete|set v3 数组）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      expect(note.supportsNoteBatch, isTrue);

      final moved = await note.moveNotes(['n-1', 'n-2'], parentId: 'nb-2');
      expect(moved.hasFailure, isFalse);
      expect(h.store.notes['n-1']!.parentId, 'nb-2');
      expect(h.store.notes['n-2']!.parentId, 'nb-2');

      // 批量删除默认进回收站（recycle=true），列表里仍在但 `recycle` 为真
      final deleted = await note.deleteNotes(['n-1', 'n-2']);
      expect(deleted.hasFailure, isFalse);
      final recycled = (await note.listNotes()).notes
          .where((n) => n.recycle)
          .map((n) => n.objectId);
      expect(recycled, containsAll(['n-1', 'n-2']));
      expect(h.store.notes['n-1']!.recycle, isTrue);
      expect(h.store.notes['n-2']!.recycle, isTrue);
    });

    test('A13 笔记信息 · 来源链接写入（Note/set source_url）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final current = await note.getNote('n-1');
      await note.setNote(
        objectId: 'n-1',
        ver: current.ver,
        sourceUrl: 'https://example.invalid/source',
      );
      expect(
        (await note.getNote('n-1')).sourceUrl,
        'https://example.invalid/source',
      );
    });

    test('N3 来源链接可被清空（空串清空 source_url）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      var current = await note.getNote('n-1');
      await note.setNote(
        objectId: 'n-1',
        ver: current.ver,
        sourceUrl: 'https://example.invalid/a',
      );
      current = await note.getNote('n-1');
      await note.setNote(objectId: 'n-1', ver: current.ver, sourceUrl: '');
      expect((await note.getNote('n-1')).sourceUrl, isNull);
    });

    test('N4 位置/地理标签（Note/set latitude+longitude+location）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final current = await note.getNote('n-1');
      await note.setNote(
        objectId: 'n-1',
        ver: current.ver,
        latitude: 25.033,
        longitude: 121.5654,
        location: '台北',
      );

      final read = await note.getNote('n-1');
      expect(read.latitude, closeTo(25.033, 0.0001));
      expect(read.longitude, closeTo(121.5654, 0.0001));
      expect(read.location, '台北');
      expect(h.store.notes['n-1']!.latitude, closeTo(25.033, 0.0001));
    });
  });

  group('笔记 · 笔记本（归档 / Shelf）', () {
    test('A14 归档标记（Notebook.Polling/archive + Notebook 列表过滤）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      await note.archiveNotebook('nb-1', enable: true);

      final visible = await note.listNotebooks();
      expect(visible.map((n) => n.objectId), isNot(contains('nb-1')));

      final all = await note.listNotebooks(includeArchived: true);
      final nb1 = all.firstWhere((n) => n.objectId == 'nb-1');
      expect(nb1.archive, isTrue);
      expect(h.store.notebooks['nb-1']!.archive, isTrue);

      await note.archiveNotebook('nb-1', enable: false);
      expect(
        (await note.listNotebooks()).map((n) => n.objectId),
        contains('nb-1'),
      );
    });

    test('F2 子笔记本 / Shelf（Notebook/set v2 stack）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      await note.setNotebookStack('nb-1', stack: '项目');
      expect((await note.getNotebook('nb-1')).stack, '项目');
      expect(h.store.notebooks['nb-1']!.stack, '项目');

      // null = 移出 Shelf
      await note.setNotebookStack('nb-1');
      expect((await note.getNotebook('nb-1')).stack, isNull);
    });
  });

  group('笔记 · 版本', () {
    test('H3 回滚到某版本（Note.Version/restore，参数是 ver）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final versions = await note.listVersions('n-1');
      expect(versions.map((v) => v['version']), contains('2.0'));

      await note.restoreVersion('n-1', '2.0');
      expect((await note.getNote('n-1')).ver, '2.0');
      expect(h.store.notes['n-1']!.ver, '2.0');
    });

    test('H4 某版本复制为新笔记（Note/copy + ver）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final newId = await note.copyNote('n-1', ver: '2.0', title: '周会纪要 v2');
      expect(newId, isNotEmpty);
      final copy = await note.getNote(newId);
      expect(copy.title, '周会纪要 v2');
      expect(copy.objectId, newId);
    });
  });

  group('笔记 · 待办', () {
    test('E1 独立待办聚合列表（Todo/list）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);
      final todos = await note.listTodos();
      expect(todos.length, greaterThanOrEqualTo(2));
      expect(todos.map((t) => t.title), contains('写周报'));
    });

    test('E2 创建 / 编辑 / 删除待办（Todo create+set+delete）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final created = await note.createTodo(title: '买咖啡');
      expect(created.objectId, isNotEmpty);
      expect(created.title, '买咖啡');
      expect(h.store.todos.containsKey(created.objectId), isTrue);

      await note.updateTodo(objectId: created.objectId, title: '买咖啡豆');
      final after = await note.listTodos();
      expect(
        after.firstWhere((t) => t.objectId == created.objectId).title,
        '买咖啡豆',
      );

      await note.deleteTodos([created.objectId]);
      expect(h.store.todos.containsKey(created.objectId), isFalse);
      expect(
        (await note.listTodos()).map((t) => t.objectId),
        isNot(contains(created.objectId)),
      );
    });

    test('E3 完成状态（Todo/set done）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final todo = (await note.listTodos()).firstWhere((t) => !t.done);
      await note.setTodoDone(todo, true);

      final done = await note.listTodos(done: true);
      expect(done.map((t) => t.objectId), contains(todo.objectId));
      expect(h.store.todos[todo.objectId]!.done, isTrue);

      await note.setTodoDone(todo, false);
      expect(h.store.todos[todo.objectId]!.done, isFalse);
    });

    test('E4 截止日期（Todo due_date）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final created = await note.createTodo(title: '交房租', dueDate: 1893456000);
      expect(created.dueDate, 1893456000);

      final read = (await note.listTodos()).firstWhere(
        (t) => t.objectId == created.objectId,
      );
      expect(read.dueDate, 1893456000);
      expect(h.store.todos[created.objectId]!.dueDate, 1893456000);
    });

    test('E4b 逾期待办列表（Todo/list_timeout）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final overdue = await note.createTodo(title: '过期任务', dueDate: 1);
      final timeout = await note.listTimeoutTodos();
      expect(timeout.todos.map((t) => t.objectId), contains(overdue.objectId));
    });

    test('E7 优先级（Todo priority 枚举）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final created = await note.createTodo(title: '高优先', priority: 300);
      expect(created.priority, 300);
      await note.updateTodo(objectId: created.objectId, priority: 100);
      final read = (await note.listTodos()).firstWhere(
        (t) => t.objectId == created.objectId,
      );
      expect(read.priority, 100);
      expect(h.store.todos[created.objectId]!.priority, 100);
    });

    test('E8 星标（Todo star）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final created = await note.createTodo(title: '星标任务');
      await note.updateTodo(objectId: created.objectId, star: true);
      final read = (await note.listTodos()).firstWhere(
        (t) => t.objectId == created.objectId,
      );
      expect(read.star, isTrue);
      expect(h.store.todos[created.objectId]!.star, isTrue);
    });

    test('E9 备注（Todo comment）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final created = await note.createTodo(title: '带备注');
      await note.updateTodo(objectId: created.objectId, comment: '记得带伞');
      final read = (await note.listTodos()).firstWhere(
        (t) => t.objectId == created.objectId,
      );
      expect(read.comment, '记得带伞');
      expect(h.store.todos[created.objectId]!.comment, '记得带伞');
    });

    test('E10 子任务（Todo parent_id）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final parent = await note.createTodo(title: '父任务');
      final child = await note.createTodo(
        title: '子任务',
        parentId: parent.objectId,
      );
      expect(child.parentId, parent.objectId);

      final all = await note.listTodos();
      expect(
        all.where((t) => t.parentId == parent.objectId).map((t) => t.title),
        contains('子任务'),
      );
      expect(h.store.todos[child.objectId]!.parentId, parent.objectId);
    });
  });

  group('笔记 · 附件 / 搜索 / 导出', () {
    test('C7 附件删除（Note/set attachment[action=delete]）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final before = await note.getNote('n-1');
      expect(before.attachments.keys, contains('file-1'));

      final updated = await note.deleteNoteAttachments(
        objectId: 'n-1',
        ver: before.ver,
        fileIds: const ['file-1'],
      );
      expect(updated?.attachments.keys, isNot(contains('file-1')));
      expect(h.store.notes['n-1']!.attachments, isEmpty);
    });

    test('C9 附件文本搜索（Setting/set + Note/get_attachment_text v4）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      expect(note.supportsAttachmentText(), isTrue);

      await note.setSearchAttachment(true);
      expect(await note.searchAttachmentEnabled(), isTrue);
      expect(h.store.searchAttachmentEnabled['enabled'], isTrue);

      final text = await note.attachmentText('n-1', 'file-1');
      expect(text, contains('spec.txt'));
    });

    test('K1 .nsx 单条导出（Export.Note start→status）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final taskId = await note.startNoteExport('n-1');
      expect(taskId, isNotEmpty);

      final status = await note.noteExportStatus(taskId);
      expect(status.finish, isTrue);
      expect(status.filename, endsWith('.nsx'));
    });
  });

  group('笔记 · 标签与快捷方式', () {
    test('G4 标签 + 操作符过滤（Note/list tag + tag_operator）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      final or = await note.listNotes(
        tags: const ['tag-work'],
        tagOperator: NoteStationApi.tagOperatorOr,
      );
      expect(or.notes.map((n) => n.objectId), containsAll(['n-1', 'n-2']));

      final and = await note.listNotes(
        tags: const ['tag-work', 'tag-read'],
        tagOperator: NoteStationApi.tagOperatorAnd,
      );
      expect(and.notes.map((n) => n.objectId), containsAll(['n-2']));
      expect(and.notes.map((n) => n.objectId), isNot(contains('n-1')));
    });

    test('F5 快捷方式写入 / 取消（Shortcut set+delete）', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      final note = NoteStationApi(h.api);

      await note.setShortcut(objectId: 'n-2');
      final withShortcut = await note.listShortcuts();
      expect(withShortcut.expand((s) => s.itemIds), contains('n-2'));

      await note.deleteShortcut(objectId: 'n-2');
      final after = await note.listShortcuts();
      expect(after.expand((s) => s.itemIds), isNot(contains('n-2')));
    });
  });
}
