// ★★★ ④笔记 **N5「多账号」** —— 第 236 轮。
//
// 事实：本地库是**同一个** `synhub.sqlite`，而 App 支持多个 NAS 配置
// （`NasStore` 里存 profiles，`session.activeNasId` 是当前激活的那个）。
// 在 236 轮之前，笔记缓存表只按 `objectId` 键 ⇒ 切换 NAS 时：
//   ① A 的笔记会**留在列表里**（看起来像 B 的）；
//   ② B 的 `Note/list` diff 会把 A 的缓存行当成"服务端删了"**删掉**；
//   ③ 同 id 的行互相覆盖；离线队列会把 A 的改动推到 B。
//
// 本轮给四张表加 `account_key`（笔记/笔记本/待办主键 = (account_key, id)），
// 并把 `noteStoreProvider` 绑到 `activeNasId`。这里逐条断言隔离行为。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/local/note_store.dart';

ChatDatabase _db() => ChatDatabase(NativeDatabase.memory());

NoteDto _note(String id, {String title = 't'}) => NoteDto(
  objectId: id,
  title: title,
  parentId: 'nb1',
  content: '正文$id',
  brief: '摘要',
  ctime: 1,
  mtime: 1,
  ver: 'v1',
  hasContent: true,
);

void main() {
  late ChatDatabase db;
  late NoteStore a;
  late NoteStore b;

  setUp(() {
    db = _db();
    a = NoteStore(db, accountKey: 'nas-A');
    b = NoteStore(db, accountKey: 'nas-B');
  });

  tearDown(() => db.close());

  group('N5 多账号隔离 · 笔记', () {
    test('★ A 写的笔记，B 读不到（也不出现在 B 的列表里）', () async {
      await a.putNote(_note('n1', title: 'A 的笔记'));
      expect((await a.notes()).map((e) => e.objectId), ['n1']);
      expect(await b.notes(), isEmpty, reason: 'B 不该看到 A 的缓存');
    });

    test('★ 同一个 objectId 在两个账号下**互不覆盖**（复合主键）', () async {
      await a.putNote(_note('same', title: 'A 的同名'));
      await b.putNote(_note('same', title: 'B 的同名'));
      expect((await a.note('same'))!.title, 'A 的同名');
      expect((await b.note('same'))!.title, 'B 的同名');
    });

    test('★ B 的全量 diff **不会删掉 A 的行**（这是最危险的旧行为）', () async {
      await a.putNote(_note('a1'));
      await a.putNote(_note('a2'));
      // B 拉到自己的列表（没有 a1/a2）→ 只清 B 自己的地盘
      await b.mergeNoteList([_note('b1')]);
      expect((await a.notes()).map((e) => e.objectId).toSet(), {'a1', 'a2'});
      expect((await b.notes()).map((e) => e.objectId).toSet(), {'b1'});
    });

    test('A 的删除只删 A 的（B 的同行还在）', () async {
      await a.putNote(_note('x'));
      await b.putNote(_note('x'));
      await a.removeNote('x');
      expect(await a.note('x'), isNull);
      expect(await b.note('x'), isNotNull);
    });

    test('清空正文也只作用在本账号', () async {
      await a.putNote(_note('x'));
      await b.putNote(_note('x'));
      await a.clearNoteContent('x');
      expect((await a.note('x'))!.hasContent, isFalse);
      expect((await b.note('x'))!.hasContent, isTrue);
    });

    test('watchNotes 也是按账号的流', () async {
      await a.putNote(_note('a-only'));
      final seen = await b.watchNotes().first;
      expect(seen, isEmpty);
      expect((await a.watchNotes().first).single.objectId, 'a-only');
    });

    test('本地搜索不跨账号', () async {
      await a.putNote(_note('s1', title: '季度总结'));
      expect((await a.search('季度')).single.objectId, 's1');
      expect(await b.search('季度'), isEmpty);
    });
  });

  group('N5 多账号隔离 · 笔记本 / 待办', () {
    test('笔记本 replace 只影响本账号', () async {
      await a.replaceNotebooks([
        const NotebookDto(objectId: 'nb1', title: 'A 的笔记本', preset: false),
      ]);
      await b.replaceNotebooks([
        const NotebookDto(objectId: 'nb2', title: 'B 的笔记本', preset: false),
      ]);
      expect((await a.notebooks()).single.title, 'A 的笔记本');
      expect((await b.notebooks()).single.title, 'B 的笔记本');
    });

    test('待办 replace / 删除也只影响本账号', () async {
      await a.replaceTodos([const TodoDto(objectId: 't1', title: 'A 的待办')]);
      await b.replaceTodos([const TodoDto(objectId: 't1', title: 'B 的待办')]);
      expect((await a.todos()).single.title, 'A 的待办');
      await a.removeTodo('t1');
      expect(await a.todos(), isEmpty);
      expect((await b.todos()).single.title, 'B 的待办');
    });
  });

  group('N5 多账号隔离 · 离线队列 & 清空', () {
    test('★ A 的待推送改动不会被 B 看到（推错账号 = 把 A 的改写到 B）', () async {
      await a.enqueue(NotePendingKind.set, 'n1', {'title': 'A 改的'});
      expect(await a.pendingCount(), 1);
      expect(await b.pendingCount(), 0);
      expect(await b.pending(), isEmpty);
    });

    test('B 清空队列不动 A 的', () async {
      await a.enqueue(NotePendingKind.set, 'n1', const {});
      await b.clearPending();
      expect(await a.pendingCount(), 1);
      expect(await b.pendingCount(), 0);
    });

    test('clearAll 只清本账号（别的 NAS 缓存不该被顺手删）', () async {
      await a.putNote(_note('a1'));
      await b.putNote(_note('b1'));
      await a.clearAll();
      expect(await a.notes(), isEmpty);
      expect((await b.notes()).single.objectId, 'b1');
    });

    test('默认 accountKey = 空串（单账号 / 未登录：老库行为不变）', () async {
      final legacy = NoteStore(db);
      await legacy.putNote(_note('l1'));
      expect((await legacy.notes()).single.objectId, 'l1');
      // 空账号与具名账号也互不串
      expect(await a.notes(), isEmpty);
    });
  });
}
