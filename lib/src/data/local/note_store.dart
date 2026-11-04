// 笔记模块的本地缓存（Drift）—— local-first。
//
// 与文件模块的 `FileStore` 同一套思路：
//   * **列表**：服务端整份拉回来 → 事务里 diff 落库（新增/更新/删掉本地多余的）；
//   * **正文**：`Note/get` 拿到的正文也落库，断网时能看能搜；
//   * **离线写**：离线时的保存/删除进 `notePendingRows` 队列，联网后重放。
//
// 键的选择：`object_id` 是服务端给的全局唯一 id（笔记/笔记本/待办都唯一），
// 直接当主键；`ver` 是乐观锁，离线改动只标 `dirty`，不伪造 `ver`。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../dto/note_dto.dart';
import 'database.dart';

/// 离线写操作的类型（与 `NotePendingRows.kind` 一一对应）。
enum NotePendingKind {
  create('create'),
  set('set'),
  delete('delete'),
  todoCreate('todo_create'),
  todoSet('todo_set'),
  todoDelete('todo_delete');

  const NotePendingKind(this.value);

  final String value;

  static NotePendingKind? parse(String v) =>
      NotePendingKind.values.where((e) => e.value == v).firstOrNull;
}

/// 一次"双向冲突"：本地有未推送的改动，服务端也在我们改过之后动过同一条笔记。
///
/// 判定依据是**乐观锁版本**：离线保存时我们保留改动前的 `ver`（不伪造版本），
/// 所以 `dirty` 行的 `ver` = "我基于哪个版本改的"，服务端 `Note/list` 里的
/// `ver` = "服务端现在是什么版本"；两者不同 = 两边都改过。
class NoteConflictDraft {
  const NoteConflictDraft({
    required this.objectId,
    required this.title,
    required this.baseVer,
    required this.serverVer,
    required this.localContent,
  });

  final String objectId;
  final String title;

  /// 我们本地改动所基于的版本（`dirty` 行的 `ver`）
  final String baseVer;

  /// 服务端当前版本
  final String serverVer;

  /// 本地（还没推上去）的正文 HTML
  final String localContent;
}

class NotePendingAction {
  const NotePendingAction({
    required this.id,
    required this.kind,
    required this.objectId,
    required this.payload,
    required this.createdAt,
  });

  final int id;
  final NotePendingKind kind;
  final String objectId;
  final Map<String, dynamic> payload;
  final int createdAt;
}

class NoteStore {
  NoteStore(this.db, {this.accountKey = ''});

  final ChatDatabase db;

  /// ★ N5（236 轮）：这个 store 只读写**本账号**的笔记数据。
  ///
  /// 多 NAS 共用同一个本地库 ⇒ 不给账号维度，A 的笔记会在 B 登录时被
  /// `mergeNoteList` 的 diff 当成"服务端删了"，同 id 的行还会互相覆盖。
  /// 默认空串 = 单账号/未登录（兼容老库）。
  final String accountKey;

  int _now() => DateTime.now().millisecondsSinceEpoch;

  // ------------------------------------------------------------- 笔记列表

  /// 本地全部笔记（回收站里的也在，调用方自己过滤）。
  Future<List<NoteDto>> notes() async {
    final rows = await _noteQuery().get();
    return _sorted(rows);
  }

  Stream<List<NoteDto>> watchNotes() => _noteQuery().watch().map(_sorted);

  /// 本账号的笔记行查询（所有读路径都必须经过它）
  SimpleSelectStatement<$NoteCacheRowsTable, NoteCacheRow> _noteQuery() =>
      db.select(db.noteCacheRows)
        ..where((t) => t.accountKey.equals(accountKey));

  List<NoteDto> _sorted(List<NoteCacheRow> rows) {
    final out = rows.map(_fromRow).toList()
      ..sort((a, b) => b.mtime.compareTo(a.mtime));
    return out;
  }

  Future<NoteDto?> note(String objectId) async {
    final row = await (db.select(db.noteCacheRows)..where(
          (t) => t.objectId.equals(objectId) & t.accountKey.equals(accountKey),
        ))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  /// 用服务端返回的笔记元数据 **diff** 落库（官方 `SyncPullCallable` 的做法）。
  ///
  /// * 本地没有 → 插入；
  /// * 本地有且 `mtime`/`ctime` 不同 → 更新元数据，**清掉 `hasContent`**
  ///   （正文变了，得重新抓一次）；
  /// * 本地有、服务端这次没给 → 删掉（服务端真的没了）；
  /// * `dirty`（离线改过、还没推上去）的行**不动**，免得覆盖用户刚改的内容，
  ///   但会做**冲突探测**：服务端版本也从我们改的那个版本变走了 → 两边都改了，
  ///   记进 [conflictsOut] 交给界面让用户选（见 `note_conflict_page.dart`）。
  ///
  /// 返回"正文需要重新抓"的笔记 id 列表。
  Future<List<NoteDto>> mergeNoteList(
    List<NoteDto> remote, {
    bool replaceAll = true,
    List<NoteConflictDraft>? conflictsOut,
  }) async {
    final now = _now();
    final needContent = <NoteDto>[];
    await db.transaction(() async {
      final localRows = await _noteQuery().get();
      final local = {for (final r in localRows) r.objectId: r};
      final remoteIds = remote.map((e) => e.objectId).toSet();

      for (final n in remote) {
        final row = local[n.objectId];
        if (row == null) {
          // ⚠️ `Note/list` 的 data 里**没有**正文（只有 brief），所以新行一律
          // 标 `hasContent: false`，让调用方去 `Note/get` 补。
          await db
              .into(db.noteCacheRows)
              .insert(
                _companion(n, syncedAt: now, hasContent: false, content: ''),
              );
          needContent.add(n);
          continue;
        }
        if (row.dirty) {
          // 本地有未推送的改动 → 不覆盖，但要看看服务端是不是也动了（两边都改）
          if (n.ver.isNotEmpty && row.ver.isNotEmpty && n.ver != row.ver) {
            conflictsOut?.add(
              NoteConflictDraft(
                objectId: n.objectId,
                title: n.title.isEmpty ? row.title : n.title,
                baseVer: row.ver,
                serverVer: n.ver,
                localContent: row.content,
              ),
            );
          }
          continue;
        }
        final changed =
            row.mtime != n.mtime ||
            row.title != n.title ||
            row.notebookId != n.parentId ||
            row.recycle != n.recycle ||
            row.encrypt != n.encrypt;
        if (changed) {
          // mtime 变了 → 正文也变了，清掉等重抓
          await db
              .into(db.noteCacheRows)
              .insertOnConflictUpdate(
                _companion(n, syncedAt: now, hasContent: false, content: ''),
              );
          needContent.add(n);
        } else if (!row.hasContent) {
          // 元数据没变，但正文还没缓存过（上次只拉了列表）→ 也得补
          needContent.add(n);
        }
      }

      if (replaceAll) {
        final gone = localRows
            .where(
              (r) =>
                  !remoteIds.contains(r.objectId) &&
                  r.objectId.isNotEmpty &&
                  !r.dirty,
            )
            .map((r) => r.objectId)
            .toList();
        if (gone.isNotEmpty) {
          await (db.delete(db.noteCacheRows)..where(
                (t) => t.objectId.isIn(gone) & t.accountKey.equals(accountKey),
              ))
              .go();
        }
      }
    });
    return needContent;
  }

  /// 缓存一条笔记的正文（`Note/get` 回来之后调）。
  Future<void> putNote(NoteDto note, {bool dirty = false}) async {
    await db
        .into(db.noteCacheRows)
        .insertOnConflictUpdate(
          _companion(
            note,
            syncedAt: _now(),
            hasContent: note.hasContent,
            dirty: dirty,
          ),
        );
  }

  /// 离线改动：本地立即生效（标记 `dirty`），等联网推上去。
  Future<void> putDirty(NoteDto note) async {
    await db
        .into(db.noteCacheRows)
        .insertOnConflictUpdate(
          _companion(
            note,
            syncedAt: _now(),
            hasContent: note.hasContent,
            dirty: true,
          ),
        );
  }

  /// 离线删除：本地直接抹掉，只在队列里留一条待推送的 delete。
  Future<void> removeNote(String objectId) async {
    await (db.delete(db.noteCacheRows)..where(
          (t) => t.objectId.equals(objectId) & t.accountKey.equals(accountKey),
        ))
        .go();
  }

  Future<void> clearNoteContent(String objectId) async {
    await (db.update(db.noteCacheRows)..where(
          (t) => t.objectId.equals(objectId) & t.accountKey.equals(accountKey),
        ))
        .write(const NoteCacheRowsCompanion(hasContent: Value(false)));
  }

  // ------------------------------------------------------------- 笔记本

  Future<List<NotebookDto>> notebooks() async {
    final rows = await (db.select(db.notebookCacheRows)
          ..where((t) => t.accountKey.equals(accountKey)))
        .get();
    return rows.map(_notebookFromRow).toList();
  }

  Future<void> replaceNotebooks(List<NotebookDto> list) async {
    final now = _now();
    await db.transaction(() async {
      final keep = list.map((e) => e.objectId).toList();
      final del = db.delete(db.notebookCacheRows);
      del.where((t) => t.accountKey.equals(accountKey));
      if (keep.isNotEmpty) {
        del.where((t) => t.accountKey.equals(accountKey) & t.objectId.isNotIn(keep));
      }
      await del.go();
      for (final n in list) {
        await db
            .into(db.notebookCacheRows)
            .insertOnConflictUpdate(
              NotebookCacheRowsCompanion.insert(
                accountKey: Value(accountKey),
                objectId: n.objectId,
                title: Value(n.title),
                preset: Value(n.preset),
                archive: Value(n.archive),
                ver: Value(n.ver),
                mtime: Value(n.mtime),
                syncedAt: Value(now),
              ),
            );
      }
    });
  }

  // ------------------------------------------------------------- 待办

  Future<List<TodoDto>> todos() async {
    final rows = await (db.select(db.todoCacheRows)
          ..where((t) => t.accountKey.equals(accountKey)))
        .get();
    return rows.map(_todoFromRow).toList();
  }

  Future<void> replaceTodos(List<TodoDto> list) async {
    final now = _now();
    await db.transaction(() async {
      final keep = list.map((e) => e.objectId).toList();
      final del = db.delete(db.todoCacheRows);
      del.where((t) => t.accountKey.equals(accountKey));
      if (keep.isNotEmpty) {
        del.where((t) => t.accountKey.equals(accountKey) & t.objectId.isNotIn(keep));
      }
      await del.go();
      for (final t in list) {
        await db
            .into(db.todoCacheRows)
            .insertOnConflictUpdate(_todoCompanion(t, syncedAt: now));
      }
    });
  }

  Future<void> putTodo(TodoDto todo, {bool dirty = false}) async {
    await db
        .into(db.todoCacheRows)
        .insertOnConflictUpdate(
          _todoCompanion(todo, syncedAt: _now(), dirty: dirty),
        );
  }

  Future<void> removeTodo(String objectId) async {
    await (db.delete(db.todoCacheRows)..where(
          (t) => t.objectId.equals(objectId) & t.accountKey.equals(accountKey),
        ))
        .go();
  }

  // ------------------------------------------------------------- 离线队列

  Future<int> enqueue(
    NotePendingKind kind,
    String objectId,
    Map<String, dynamic> payload,
  ) => db
      .into(db.notePendingRows)
      .insert(
        NotePendingRowsCompanion.insert(
          accountKey: Value(accountKey),
          kind: kind.value,
          objectId: Value(objectId),
          payloadJson: Value(jsonEncode(payload)),
          createdAt: Value(_now()),
        ),
      );

  Future<List<NotePendingAction>> pending() async {
    final rows = await (db.select(db.notePendingRows)
          ..where((t) => t.accountKey.equals(accountKey))
          ..orderBy([(t) => OrderingTerm(expression: t.id)]))
        .get();
    return rows
        .map(
          (r) => NotePendingAction(
            id: r.id,
            kind: NotePendingKind.parse(r.kind) ?? NotePendingKind.set,
            objectId: r.objectId,
            payload: _decodeMap(r.payloadJson),
            createdAt: r.createdAt,
          ),
        )
        .toList();
  }

  Future<int> pendingCount() async {
    final rows = await (db.select(db.notePendingRows)
          ..where((t) => t.accountKey.equals(accountKey)))
        .get();
    return rows.length;
  }

  Future<void> removePending(int id) async {
    await (db.delete(db.notePendingRows)..where(
          (t) => t.id.equals(id) & t.accountKey.equals(accountKey),
        ))
        .go();
  }

  /// 扔掉某条笔记**所有**待推送的改动（冲突里"以服务端为准"用）
  Future<void> removePendingFor(String objectId) async {
    await (db.delete(db.notePendingRows)..where(
          (t) => t.objectId.equals(objectId) & t.accountKey.equals(accountKey),
        ))
        .go();
  }

  /// 某条笔记到目前为止攒下的待推送动作（从早到晚）
  Future<List<NotePendingAction>> pendingFor(String objectId) async {
    final all = await pending();
    return all.where((a) => a.objectId == objectId).toList();
  }

  Future<void> clearPending() async => (db.delete(db.notePendingRows)
        ..where((t) => t.accountKey.equals(accountKey)))
      .go();

  Future<void> clearAll() async {
    await db.transaction(() async {
      // 只清**本账号**（别的 NAS 的缓存不该被顺手删掉）
      await (db.delete(db.noteCacheRows)
            ..where((r) => r.accountKey.equals(accountKey)))
          .go();
      await (db.delete(db.notebookCacheRows)
            ..where((r) => r.accountKey.equals(accountKey)))
          .go();
      await (db.delete(db.todoCacheRows)
            ..where((r) => r.accountKey.equals(accountKey)))
          .go();
      await (db.delete(db.notePendingRows)
            ..where((r) => r.accountKey.equals(accountKey)))
          .go();
    });
  }

  /// 本地搜索（断网时至少能搜到缓存过的标题/正文）。
  Future<List<NoteDto>> search(String keyword) async {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return notes();
    final all = await notes();
    return all
        .where(
          (n) =>
              n.title.toLowerCase().contains(kw) ||
              n.brief.toLowerCase().contains(kw) ||
              (!n.encrypt && n.content.toLowerCase().contains(kw)),
        )
        .toList();
  }

  // ------------------------------------------------------------- 行 ↔ DTO

  NoteCacheRowsCompanion _companion(
    NoteDto n, {
    required int syncedAt,
    bool? hasContent,
    String? content,
    String? attachmentsJson,
    bool? dirty,
  }) => NoteCacheRowsCompanion.insert(
    accountKey: Value(accountKey),
    objectId: n.objectId,
    notebookId: Value(n.parentId),
    title: Value(n.title),
    brief: Value(n.brief),
    content: Value(content ?? n.content),
    hasContent: Value(hasContent ?? n.hasContent),
    tagsJson: Value(jsonEncode(n.tags)),
    attachmentsJson: Value(attachmentsJson ?? jsonEncode(_attachmentJson(n))),
    encrypt: Value(n.encrypt),
    recycle: Value(n.recycle),
    ver: Value(n.ver),
    ctime: Value(n.ctime),
    mtime: Value(n.mtime),
    ownerName: Value(n.ownerName ?? ''),
    dirty: Value(dirty ?? false),
    syncedAt: Value(syncedAt),
  );

  static Map<String, dynamic> _attachmentJson(NoteDto n) => {
    for (final e in n.attachments.entries)
      e.key: {
        'file_id': e.value.fileId,
        'ref': e.value.ref,
        'name': e.value.name,
        'type': e.value.type,
        'size': e.value.size,
      },
  };

  NoteDto _fromRow(NoteCacheRow r) => NoteDto(
    objectId: r.objectId,
    title: r.title,
    parentId: r.notebookId,
    content: r.content,
    brief: r.brief,
    ctime: r.ctime,
    mtime: r.mtime,
    ver: r.ver,
    encrypt: r.encrypt,
    tags: _decodeList(r.tagsJson),
    recycle: r.recycle,
    ownerName: r.ownerName.isEmpty ? null : r.ownerName,
    hasContent: r.hasContent,
    attachments: _attachmentsOf(r.attachmentsJson),
  );

  NotebookDto _notebookFromRow(NotebookCacheRow r) => NotebookDto(
    objectId: r.objectId,
    title: r.title,
    preset: r.preset,
    archive: r.archive,
    ver: r.ver,
    mtime: r.mtime,
  );

  TodoCacheRowsCompanion _todoCompanion(
    TodoDto t, {
    required int syncedAt,
    bool? dirty,
  }) => TodoCacheRowsCompanion.insert(
    accountKey: Value(accountKey),
    objectId: t.objectId,
    title: Value(t.title),
    comment: Value(t.comment),
    done: Value(t.done),
    star: Value(t.star),
    priority: Value(t.priority),
    dueDate: Value(t.dueDate),
    reminderOffset: Value(t.reminderOffset),
    noteId: Value(t.noteId),
    parentId: Value(t.parentId),
    dirty: Value(dirty ?? false),
    syncedAt: Value(syncedAt),
  );

  TodoDto _todoFromRow(TodoCacheRow r) => TodoDto(
    objectId: r.objectId,
    title: r.title,
    comment: r.comment,
    done: r.done,
    star: r.star,
    priority: r.priority,
    dueDate: r.dueDate,
    reminderOffset: r.reminderOffset,
    noteId: r.noteId,
    parentId: r.parentId,
  );

  static List<String> _decodeList(String json) {
    try {
      final v = jsonDecode(json);
      return v is List ? v.map((e) => '$e').toList() : const [];
    } catch (_) {
      return const [];
    }
  }

  static Map<String, dynamic> _decodeMap(String json) {
    try {
      final v = jsonDecode(json);
      return v is Map ? v.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  static Map<String, NoteAttachmentDto> _attachmentsOf(String json) {
    final map = _decodeMap(json);
    final out = <String, NoteAttachmentDto>{};
    map.forEach((key, value) {
      if (value is! Map) return;
      final m = value.cast<String, dynamic>();
      out[key] = NoteAttachmentDto(
        fileId: asText(m['file_id'] ?? key),
        ref: asText(m['ref']),
        name: asText(m['name']),
        type: asText(m['type']),
        size: asEpoch(m['size']),
      );
    });
    return out;
  }
}
