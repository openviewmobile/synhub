// ★★ ④笔记 N5（236 轮）：**v13 → v14 迁移**必须真跑一次。
//
// 起因：这一版把三张笔记表的**主键**从 `(object_id)` 改成
// `(account_key, object_id)` —— `addColumn` 改不了主键，迁移里走的是
// `alterTable`（SQLite 12 步重建）。这种改动**只有真跑一次升级**才看得见问题：
// 列的默认值、复合主键、老行的账号归属、以及"别的账号读不到"。
//
// 做法：建当前版本的库 → 把三张表按 **v13 的 DDL**（无 account_key、
// 主键只有 object_id）重建并灌入老数据 → 在键值表写下当前激活的 NAS id
// → `PRAGMA user_version = 13` → 用当前代码重新打开 ⇒ 触发 v14 迁移。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/local/note_store.dart';

Future<String> _ddl(ChatDatabase db, String table) async {
  final rows = await db
      .customSelect(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?",
        variables: [Variable<String>(table)],
      )
      .get();
  return rows.single.read<String>('sql');
}

/// 把当前 DDL 改回 v13：去掉 `account_key` 列定义 + 还原单列主键。
///
/// ⚠️ drift 生成的是**单行** DDL（不是多行），所以只能按子串处理
/// （236 轮第一版按行切，DUPLICATE COLUMN 才发现）。
String _v13Ddl(String ddl) {
  var out = ddl.replaceAll('"account_key" TEXT NOT NULL DEFAULT \'\', ', '');
  out = out.replaceAll(
    'PRIMARY KEY ("account_key", "object_id")',
    'PRIMARY KEY ("object_id")',
  );
  assert(!out.contains('"account_key"'), 'v13 DDL 里不该还有 account_key');
  return out;
}

/// 复合主键里 object_id 的 pk 序号（0 = 不是主键）
Future<int> _pkIndex(ChatDatabase db, String table, String column) async {
  final rows = await db.customSelect("PRAGMA table_info('$table')").get();
  for (final r in rows) {
    if (r.read<String>('name') == column) return r.read<int>('pk');
  }
  return -1;
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('note-v14-migration');
    file = File('${dir.path}/chat.sqlite');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('★ v13 → v14：三张表重建为复合主键，老行补成"当前激活的 NAS"', () async {
    final fresh = ChatDatabase(NativeDatabase(file));
    final note = NoteStore(fresh);
    await note.enqueue(NotePendingKind.set, 'n1', const {'title': '待推送'});
    // 老库里的数据（v13 时还没有账号概念）
    final ddls = <String, String>{};
    for (final t in ['note_cache_rows', 'notebook_cache_rows', 'todo_cache_rows']) {
      ddls[t] = _v13Ddl(await _ddl(fresh, t));
    }
    final pendingDdl = _v13Ddl(await _ddl(fresh, 'note_pending_rows'));
    // 键值表里写下"当前激活的 NAS"（迁移按它给老行归属）
    await fresh.customStatement(
      "INSERT OR REPLACE INTO key_value_rows (key, value) VALUES "
      "('nas_active_id', 'nas-A')",
    );
    await fresh.customStatement(
      "INSERT INTO note_cache_rows (object_id, title, content) "
      "VALUES ('legacy-note', '老笔记', '老正文')",
    );
    await fresh.customStatement(
      "INSERT INTO notebook_cache_rows (object_id, title) VALUES ('legacy-nb', '老本')",
    );
    await fresh.customStatement(
      "INSERT INTO todo_cache_rows (object_id, title) VALUES ('legacy-todo', '老待办')",
    );
    // 按 v13 DDL 重建（这样主键也回到单列，模拟真实老库）
    for (final e in ddls.entries) {
      await fresh.customStatement('DROP TABLE ${e.key}');
      await fresh.customStatement(e.value);
    }
    await fresh.customStatement('DROP TABLE note_pending_rows');
    await fresh.customStatement(pendingDdl);
    await fresh.customStatement(
      "INSERT INTO note_cache_rows (object_id, title, content) "
      "VALUES ('legacy-note', '老笔记', '老正文')",
    );
    await fresh.customStatement(
      "INSERT INTO notebook_cache_rows (object_id, title) VALUES ('legacy-nb', '老本')",
    );
    await fresh.customStatement(
      "INSERT INTO todo_cache_rows (object_id, title) VALUES ('legacy-todo', '老待办')",
    );
    await fresh.customStatement(
      "INSERT INTO note_pending_rows (kind, object_id, payload_json) "
      "VALUES ('set', 'legacy-note', '{}')",
    );
    await fresh.customStatement('PRAGMA user_version = 13');
    await fresh.close();

    // ---- 用当前代码打开 ⇒ 触发 v14 迁移 ----
    final db = ChatDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final notColumns = await db.customSelect("PRAGMA table_info('note_cache_rows')").get();
    expect(
      notColumns.any((r) => r.read<String>('name') == 'account_key'),
      isTrue,
      reason: 'v14：笔记表要有 account_key',
    );
    expect(
      await _pkIndex(db, 'note_cache_rows', 'account_key'),
      greaterThan(0),
      reason: 'account_key 必须是主键的一部分',
    );
    expect(
      await _pkIndex(db, 'note_cache_rows', 'object_id'),
      greaterThan(0),
      reason: 'object_id 仍然是主键的一部分（复合）',
    );
    expect(await _pkIndex(db, 'todo_cache_rows', 'account_key'), greaterThan(0));
    expect(await _pkIndex(db, 'notebook_cache_rows', 'account_key'), greaterThan(0));

    // 老行保留 + 归属到当前激活的 NAS
    final a = NoteStore(db, accountKey: 'nas-A');
    final b = NoteStore(db, accountKey: 'nas-B');
    expect((await a.notes()).single.objectId, 'legacy-note');
    expect((await a.notebooks()).single.objectId, 'legacy-nb');
    expect((await a.todos()).single.objectId, 'legacy-todo');
    expect(await a.pendingCount(), 1, reason: '老队列不能被迁移吞掉');
    expect(await b.notes(), isEmpty, reason: '归属必须落在当前 NAS，不能变成"人人可见"');
    expect(await b.pendingCount(), 0);
  });

  test('v13 → v14：键值表里没有激活 NAS 时，老行留空串（不伪造归属）', () async {
    final fresh = ChatDatabase(NativeDatabase(file));
    final ddls = <String, String>{};
    for (final t in ['note_cache_rows', 'notebook_cache_rows', 'todo_cache_rows']) {
      ddls[t] = _v13Ddl(await _ddl(fresh, t));
    }
    // 队列表也要回到 v13（PK 没变，但 v13 没有 account_key 列）
    ddls['note_pending_rows'] = _v13Ddl(await _ddl(fresh, 'note_pending_rows'));
    for (final e in ddls.entries) {
      await fresh.customStatement('DROP TABLE ${e.key}');
      await fresh.customStatement(e.value);
    }
    await fresh.customStatement(
      "INSERT INTO note_cache_rows (object_id, title) VALUES ('x', '无主笔记')",
    );
    await fresh.customStatement('PRAGMA user_version = 13');
    await fresh.close();

    final db = ChatDatabase(NativeDatabase(file));
    addTearDown(db.close);
    // 空账号 = 老库默认视图，仍能看到（不丢数据）
    final legacy = NoteStore(db);
    expect((await legacy.notes()).single.objectId, 'x');
    expect(await NoteStore(db, accountKey: 'nas-A').notes(), isEmpty);
  });
}
