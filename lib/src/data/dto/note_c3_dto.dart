// C3（NoteStation 补齐）的数据对象：版本历史 / 导出任务 / 导入任务 / Evernote。
//
// **字段名逐字取自官方包**（NoteStation-x86_64-2.6.10-3938），出处集中写在
// `note_api.dart` 对应方法上方与 `docs/note-c3-implementation.md`。
// 解析一律容错：服务端这些接口的字段经常缺省，缺了给默认值、不抛。
library;

import 'note_dto.dart' show asEpoch, asText, asTextOrNull;

/// 一条历史版本（`SYNO.NoteStation.Note.Version/list` 的 `versions[]`）。
///
/// 官方 Web 的 `Ext.data.JsonReader`（`ui/notestation.js`，`Info.History.Window`）：
/// ```js
/// reader:new Ext.data.JsonReader({root:"versions",totalProperty:"total",
///   idProperty:"id"},["id","author","version","mtime","commit_msg","last_version"])
/// ```
/// 预览内容时官方用 `note.version` 当 `Note/get` 的 `ver`
/// （同文件 `History.Preview.Window.loadNote`：
/// `getNote({object_id:…,ver:historyList[i].version,…})`）。
class NoteVersionDto {
  const NoteVersionDto({
    this.id = '',
    this.version = '',
    this.author = '',
    this.mtime = 0,
    this.device = '',
    this.listable = true,
    this.lastVersion = '',
  });

  /// 版本行的 `id`（官方 `idProperty:"id"`，仅作行标识）
  final String id;

  /// `ver` 字符串 —— 预览时要回传给 `Note/get`，回滚时回传给 `Note.Version/restore`
  final String version;
  final String author;
  final int mtime;

  /// `commit_msg.device`（官方历史表格的「设备名称」列）
  final String device;

  /// `commit_msg.listable`：官方列表按它过滤（`filterBy(t=>!0===t.data.commit_msg.listable)`）
  final bool listable;
  final String lastVersion;

  static NoteVersionDto fromJson(Map<String, dynamic> j) {
    final commit = j['commit_msg'];
    final commitMap = commit is Map ? commit : const {};
    return NoteVersionDto(
      id: asText(j['id']),
      version: asText(j['version']),
      author: asText(j['author']),
      mtime: asEpoch(j['mtime']),
      device: asText(commitMap['device']),
      listable: commitMap.containsKey('listable')
          ? commitMap['listable'] == true
          : true,
      lastVersion: asText(j['last_version']),
    );
  }
}

/// 导出任务（`Export.Word` / `Export.Note` 的 `start` → `{task_id}`，
/// `status` → `{finish, filename}`）。
///
/// 官方 `ui/notestation.js` 的 `pollingExportWordStatus` / `pollingExportNoteStatus`：
/// `i.finish ? pollingExportDone(...) : Ext.defer(...,1200)`，完成时把
/// `o.filename` 交给 `downloadWebAPI` 的 `filename`。
class NoteExportTaskDto {
  const NoteExportTaskDto({
    this.taskId = '',
    this.finish = false,
    this.filename = '',
  });

  final String taskId;
  final bool finish;
  final String filename;

  static NoteExportTaskDto fromJson(Map<String, dynamic> j) =>
      NoteExportTaskDto(
        taskId: asText(j['task_id']),
        finish: j['finish'] == true,
        filename: asText(j['filename']),
      );
}

/// 导入/导出进度（`Import.Notebook`、`Import.Enex`、`Export.Notebook` 的 `status`）。
///
/// 官方 `updateNotebookStatus`：`e.finish`；未完成时读 `e.data.current` /
/// `e.data.total`；完成时读 `e.data.finish_time`。
class NoteImportStatusDto {
  const NoteImportStatusDto({
    this.finish = false,
    this.success = true,
    this.current = 0,
    this.total = 0,
    this.finishTime = 0,
    this.errorCode = 0,
  });

  final bool finish;
  final bool success;
  final int current;
  final int total;
  final int finishTime;
  final int errorCode;

  /// 进度百分比（0–100；`total<=0` 时 0）
  int get percent {
    if (total <= 0) return 0;
    final p = (100 * current / total).floor();
    return p < 0 ? 0 : (p > 100 ? 100 : p);
  }

  static NoteImportStatusDto fromJson(Map<String, dynamic> j) {
    final data = j['data'];
    final d = data is Map ? data : const {};
    final err = j['error'];
    return NoteImportStatusDto(
      finish: j['finish'] == true,
      success: j.containsKey('success') ? j['success'] == true : true,
      current: asEpoch(d['current']),
      total: asEpoch(d['total']),
      finishTime: asEpoch(d['finish_time']),
      errorCode: err is Map ? asEpoch(err['code']) : asEpoch(err),
    );
  }
}

/// Evernote 云导入的整体状态（`Import.Evernote/get_status`）。
///
/// 官方 `updateEvernoteStatus`（`ui/notestation.js`）读的字段：
/// `token` / `last_error` / `notebook_left` / `notebook_count` /
/// `note_left` / `note_count` / `importing`。
/// `last_error === 19` 官方显示「等待…」（`import.waiting`）。
class NoteEvernoteStatusDto {
  const NoteEvernoteStatusDto({
    this.token = 0,
    this.lastError = 0,
    this.notebookLeft = 0,
    this.notebookCount = 0,
    this.noteLeft = 0,
    this.noteCount = 0,
    this.importing = '',
    this.lock = '',
  });

  final int token;
  final int lastError;
  final int notebookLeft;
  final int notebookCount;
  final int noteLeft;
  final int noteCount;

  /// 当前导入锁（官方 `Import.Evernote/get_status` 的 `importing`）
  final String importing;

  /// `Import.Evernote/import_lock` 回的 `lock`
  final String lock;

  /// 还在导入中（有 `importing` 锁，或还有剩余笔记/笔记本）
  bool get active => importing.isNotEmpty || notebookLeft > 0 || noteLeft > 0;

  /// 官方 `19 === last_error` = 等待中
  bool get waiting => lastError == 19;

  static NoteEvernoteStatusDto fromJson(Map<String, dynamic> j) =>
      NoteEvernoteStatusDto(
        token: asEpoch(j['token']),
        lastError: asEpoch(j['last_error']),
        notebookLeft: asEpoch(j['notebook_left']),
        notebookCount: asEpoch(j['notebook_count']),
        noteLeft: asEpoch(j['note_left']),
        noteCount: asEpoch(j['note_count']),
        importing: asTextOrNull(j['importing']) ?? '',
        lock: asTextOrNull(j['lock']) ?? '',
      );
}

/// Evernote 云端笔记本（`Import.Evernote/list_notebooks` 的 `notebooks[]`）。
///
/// 官方 `SelectNotebook` 的 reader：`root:"notebooks", idProperty:"guid"`，
/// 字段 `["guid","name","checked","ctime","mtime","stack"]`。
class NoteEvernoteNotebookDto {
  const NoteEvernoteNotebookDto({
    this.guid = '',
    this.name = '',
    this.stack = '',
    this.checked = false,
    this.ctime = 0,
    this.mtime = 0,
  });

  final String guid;
  final String name;
  final String stack;
  final bool checked;
  final int ctime;
  final int mtime;

  String get displayName =>
      name.trim().isEmpty ? (stack.trim().isEmpty ? guid : stack) : name;

  static NoteEvernoteNotebookDto fromJson(Map<String, dynamic> j) =>
      NoteEvernoteNotebookDto(
        guid: asText(j['guid']),
        name: asText(j['name']),
        stack: asText(j['stack']),
        checked: j['checked'] == true,
        ctime: asEpoch(j['ctime']),
        mtime: asEpoch(j['mtime']),
      );
}
