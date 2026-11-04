// 小组件快照的**采集与推送**（把 App 内存里的 DTO 变成推给 Android 的 JSON）。
//
// 分成两半，界线很清楚：
//   * **纯映射**（[widgetPhotoEntryOf] / [widgetNoteEntryOf] / [widgetTodoEntryOf]
//     / [widgetNotebookEntryOf]
//     + `widget_snapshot.dart` 里的取最近 N 条 / 占位判定）—— 可单测，
//     不碰网络、不碰文件、不碰平台；
//   * **副作用**（[WidgetSnapshotPublisher.publish] / [WidgetThumbStore]）——
//     把 DTO 映射成条目、尽力把缩略图落到本机磁盘、编码、过通道。
//
// ## 缩略图为什么要"落盘"
// 相册缩略图走的是**带 `_sid` 鉴权 + 自签证书**的 Dio 请求
// （`photoThumbProvider` → `FotoApi.thumbnailUrl`）。launcher 进程里的
// `AppWidgetProvider` 既没有 `_sid` 也没有证书信任链，**不可能**自己去取图。
// 所以：App 运行时把最近 N 张的缩略图字节写到
// `<app support dir>/widget_thumbs/<itemId>.jpg`，快照里只带**本机绝对路径**；
// Kotlin 侧直接 `BitmapFactory.decodeFile`。
// 取不到（离线 / 服务端 105 / 该张还没缩略图）→ `thumbPath = null`，
// 小组件画占位图标（**不留白、不崩**）。
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../data/dto/foto_dto.dart';
import '../../data/dto/note_dto.dart';
import 'widget_bridge.dart';
import 'widget_snapshot.dart';

/// 取某张照片的缩略图字节；拿不到就返回 `null`（**不要抛**）。
typedef WidgetPhotoBytes = Future<Uint8List?> Function(FotoItemDto item);

// --------------------------------------------------------------- 纯适配函数

/// `FotoItemDto` → 小组件相册条目（**[thumbPath] 由副作用层后补**）。
///
/// 纯函数：同样输入永远同样输出，单测直接断言。
WidgetPhotoEntry widgetPhotoEntryOf(FotoItemDto item) => WidgetPhotoEntry(
  id: item.id,
  name: item.filename,
  takenAt: item.time,
  isVideo: item.isVideo,
);

/// `NoteDto` → 小组件笔记条目。
///
/// ⚠️ **只带标题，绝不带正文**：加密笔记在服务端就是密文，小组件进程也没有
/// 解密密钥；而且主屏是"别人一眼能看见"的地方，带正文等于泄露。
WidgetNoteEntry widgetNoteEntryOf(
  NoteDto note, {
  Map<String, String> notebookNames = const {},
}) {
  final parent = note.parentId.trim();
  return WidgetNoteEntry(
    id: note.objectId,
    title: note.title,
    mtime: note.mtime,
    encrypted: note.encrypt,
    // ★ 第 109 轮：官方 `NotebookAppWidgetProvider` 需要按本过滤
    notebookId: parent,
    notebookName: notebookNames[parent] ?? '',
  );
}

/// `NotebookDto` → 小组件笔记本条目（★ 第 107 轮 N1 补齐，
/// 官方 `NotebookAppWidgetProvider` 对应物）。
///
/// 只带 名称 + 数量 + 时间：主屏是公开可见的地方，不带任何笔记内容。
WidgetNotebookEntry widgetNotebookEntryOf(NotebookDto notebook) =>
    WidgetNotebookEntry(
      id: notebook.objectId,
      name: notebook.title,
      count: 0, // 服务端 `Notebook:list` 不给计数时保守为 0（不编造）
      mtime: notebook.mtime,
    );

/// `TodoDto` → 小组件待办条目。
WidgetTodoEntry widgetTodoEntryOf(TodoDto todo) => WidgetTodoEntry(
  id: todo.objectId,
  title: todo.title,
  noteId: todo.noteId,
  due: todo.dueDate,
  done: todo.done,
);

// --------------------------------------------------------------- 缩略图磁盘缓存

/// `widget_thumbs/` 的读写。
class WidgetThumbStore {
  WidgetThumbStore({Future<Directory> Function()? baseDirectory})
    : _base = baseDirectory ?? getApplicationSupportDirectory;

  /// 目录名。FileProvider 的 `<files-path>` 盖得住它（Android 上
  /// `getApplicationSupportDirectory()` = `<dataDir>/files`），
  /// 但本批**不用** content://（`setImageViewBitmap` 更可靠，见 Kotlin 侧注释）。
  static const String dirName = 'widget_thumbs';

  final Future<Directory> Function() _base;

  Future<Directory> _dir() async {
    final base = await _base();
    final dir = Directory('${base.path}/$dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 存一张缩略图。**任何异常（磁盘满 / 权限）都吞成 `null`**。
  Future<String?> save(String itemId, Uint8List bytes) async {
    if (itemId.isEmpty || bytes.isEmpty) return null;
    try {
      final dir = await _dir();
      final file = File('${dir.path}/${_safeName(itemId)}.jpg');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// 删掉不在 [keepIds] 里的缩略图（快照只保留最近 N 张，旧图不该常驻）。
  Future<void> prune(Set<String> keepIds) async {
    try {
      final dir = await _dir();
      if (!await dir.exists()) return;
      final keep = {for (final id in keepIds) '${_safeName(id)}.jpg'};
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.isEmpty ? '' : e.uri.pathSegments.last;
        if (keep.contains(name)) continue;
        try {
          await e.delete();
        } catch (_) {
          // 单个文件删不掉不影响其余
        }
      }
    } catch (_) {
      // 目录都列不了就算了：过期缩略图占的那点空间不值得打断流程
    }
  }

  /// 文件名白名单化：服务端 item id 一般是数字，但**不能假设**（防路径穿越）。
  static String _safeName(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

// --------------------------------------------------------------- 推送器

/// 把当前 App 数据压成快照并推给 Android。
class WidgetSnapshotPublisher {
  WidgetSnapshotPublisher({
    required this.bridge,
    WidgetThumbStore? thumbs,
    DateTime Function()? now,
  }) : thumbs = thumbs ?? WidgetThumbStore(),
       _now = now ?? DateTime.now;

  final WidgetBridge bridge;
  final WidgetThumbStore thumbs;
  final DateTime Function() _now;

  /// 推送一次快照，返回"平台是否收下"（`false` = 没装/未实现/落盘失败）。
  ///
  /// [photoBytes] 为空时**不下载任何缩略图**，只推"文件名 + 时间"，
  /// 小组件显示占位图标（离线也可用，测试也走这条路径）。
  Future<bool> publish({
    required bool loggedIn,
    required bool connected,
    Iterable<FotoItemDto> photos = const [],
    Iterable<NoteDto> notes = const [],
    Iterable<TodoDto> todos = const [],
    Iterable<NotebookDto> notebooks = const [],
    WidgetPhotoBytes? photoBytes,
  }) async {
    // 1) 纯映射：先只在内存里算"最近 N 张 / 条"
    final photoEntries = recentWidgetPhotos(photos.map(widgetPhotoEntryOf));
    // 笔记本名映射：先建表再映射（只多一次 O(n)）
    final notebookNames = {
      for (final b in notebooks)
        if (b.objectId.trim().isNotEmpty) b.objectId: b.title,
    };
    final noteEntries = recentWidgetNotes(
      notes.map((n) => widgetNoteEntryOf(n, notebookNames: notebookNames)),
    );
    final todoEntries = widgetPendingTodos(todos.map(widgetTodoEntryOf));
    final notebookEntries = widgetNotebooks(
      notebooks.map(widgetNotebookEntryOf),
    );

    // 2) 尽力补本机缩略图。离线 / 未登录时不试（省一次必然失败的请求）。
    final resolved = <WidgetPhotoEntry>[];
    if (photoBytes != null && loggedIn && connected) {
      final byId = {for (final p in photos) p.id: p};
      for (final entry in photoEntries) {
        resolved.add(await _withThumb(entry, byId[entry.id], photoBytes));
      }
      await thumbs.prune(photoEntries.map((e) => e.id).toSet());
    } else {
      resolved.addAll(photoEntries);
    }

    final snapshot = WidgetSnapshot(
      loggedIn: loggedIn,
      connected: connected,
      photos: resolved,
      notes: noteEntries,
      todos: todoEntries,
      notebooks: notebookEntries,
      updatedAt: _now().millisecondsSinceEpoch,
    );
    return bridge.pushSnapshot(encodeWidgetSnapshot(snapshot));
  }

  Future<WidgetPhotoEntry> _withThumb(
    WidgetPhotoEntry entry,
    FotoItemDto? source,
    WidgetPhotoBytes fetch,
  ) async {
    if (source == null) return entry;
    try {
      final bytes = await fetch(source);
      if (bytes == null || bytes.isEmpty) return entry;
      final path = await thumbs.save(entry.id, bytes);
      if (path == null) return entry;
      return WidgetPhotoEntry(
        id: entry.id,
        name: entry.name,
        takenAt: entry.takenAt,
        thumbPath: path,
        isVideo: entry.isVideo,
      );
    } catch (_) {
      // 一张缩略图失败不能拖垮整次推送
      return entry;
    }
  }
}
