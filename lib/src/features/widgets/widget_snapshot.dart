// Android 主屏小组件（P66 相册 / N1 笔记）的**数据映射纯函数层**。
//
// 本文件是"小组件该显示什么"的唯一真相来源，**不依赖 Flutter / Android**：
//   * 只 import `dart:convert` 与数据层文案 [dataText]（纯 Dart，见
//     `lib/src/core/i18n/data_text.dart`）；
//   * 所以可以在普通单测里直接调用（`test/widget_snapshot_test.dart`），
//     也能被 `dart run tool/*.dart` 这类纯 Dart VM 探针加载。
//
// 平台侧的对应实现见：
//   * Android Kotlin：`android/app/src/main/kotlin/com/openviewai/synhub/
//     WidgetSnapshotStore.kt`（把同一份 JSON 解析成 RemoteViews 能用的行）；
//   * Dart 通道：`lib/src/features/widgets/widget_bridge.dart`。
//
// ## 为什么是"快照"而不是小组件自己去连 NAS
// 小组件跑在**launcher 进程**里，既没有登录会话（`_sid`），也没有自签证书
// 信任链与 Dio 客户端。让 `AppWidgetProvider` 直连 NAS 等于把鉴权与证书逻辑
// 在 Kotlin 里重写一遍（且小组件刷新时 NAS 不可达就会空着）。
// 因此：**App 运行时**把"最近 N 张照片 / 最近笔记 / 未完成待办"压成一份 JSON
// 快照推给 Android 侧落盘（SharedPreferences），小组件只渲染落盘的快照。
// 离线 / 未登录 / 未连接时小组件仍然能画出**明确的人话占位**，不会白屏。
//
// ## 契约（版本号写死在 [kWidgetSnapshotVersion]）
// ```json
// {
//   "v": 1,
//   "updatedAt": 1700000000000,
//   "loggedIn": true,
//   "connected": true,
//   "photos": [{"id":"1","name":"IMG_0001.JPG","takenAt":1700000000,
//               "thumbPath":"/data/.../widget_thumbs/1.jpg","video":false}],
//   "notes":  [{"id":"n1","title":"购物清单","mtime":1700000000,"encrypted":false}],
//   "todos":  [{"id":"t1","noteId":"n1","title":"买菜","due":1700000000,"done":false}],
//   "notebooks": [{"id":"b1","name":"工作","count":12,"mtime":1700000000}]
// }
// ```
// **向后兼容**：多出来的键忽略；缺的键取默认；`photos`/`notes`/`todos`/`notebooks`
// 不是数组就当空数组（不抛）。这是"快照可能是旧版本 App 写的"的现实防御。
library;

import 'dart:convert';

import '../../core/i18n/data_text.dart';

/// 快照格式版本。Kotlin 侧 `WidgetSnapshotStore.parse` 只认这个值；
/// 不认识就整份丢弃（宁可不显示，也不显示错行）。
const int kWidgetSnapshotVersion = 1;

/// 相册小组件显示的缩略图张数（2×2 网格）。
const int kWidgetPhotoLimit = 4;

/// 笔记小组件显示的条数。
const int kWidgetNoteLimit = 4;

/// 待办小组件显示的条数。
const int kWidgetTodoLimit = 4;

/// 笔记本小组件显示的条数（官方 `NotebookAppWidgetProvider`）。
const int kWidgetNotebookLimit = 4;

/// 小组件类别（决定"该显示哪种占位文案"）。
enum WidgetKind { photos, notes, todos, notebooks }

/// 快照为什么画不出内容。
///
/// ⚠️ 这里的枚举是**行为契约**：Kotlin 侧 `WidgetSnapshotStore.Placeholder`
/// 有一份逐字对应的枚举，两边改动必须同步（见该文件头注释）。
enum WidgetPlaceholder {
  /// 没登录（或 App 从没推过快照）→ 让用户先打开 App 登录。
  notLoggedIn,

  /// 已登录但当前连不上 NAS → 说明是连接问题，不是"没有数据"。
  notConnected,

  /// 连上了但相册里一张照片都没有。
  noPhotos,

  /// 连上了但一条笔记都没有。
  noNotes,

  /// 连上了但一条未完成待办都没有。
  noTodos,

  /// 连上了但一个笔记本都没有（笔记本小组件）。
  ///
  /// ★ 第 107 轮 N1 补齐：官方 `NotebookAppWidgetProvider` +
  ///   `NotebookListAppWidgetAdapter`（dex 取证）。
  noNotebooks,
}

/// 相册小组件里的一张照片（缩略图已由 App 落到本机磁盘，见 [thumbPath]）。
class WidgetPhotoEntry {
  const WidgetPhotoEntry({
    required this.id,
    required this.name,
    this.takenAt = 0,
    this.thumbPath,
    this.isVideo = false,
  });

  /// `FotoItemDto.id`
  final String id;
  final String name;

  /// 拍摄时间（秒，服务端 `time`）
  final int takenAt;

  /// 本机缩略图文件的**绝对路径**。
  ///
  /// `null` = 这一张还没有本机缩略图（App 还没把它下下来）→ 小组件画占位图标，
  /// **不**去联网、**不**留白。Kotlin 侧会再判一次文件是否存在/可读。
  final String? thumbPath;

  final bool isVideo;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'takenAt': takenAt,
    'thumbPath': thumbPath,
    'video': isVideo,
  };

  static WidgetPhotoEntry fromJson(Map<String, dynamic> j) => WidgetPhotoEntry(
    id: _str(j['id']),
    name: _str(j['name']),
    takenAt: _int(j['takenAt']),
    thumbPath: _strOrNull(j['thumbPath']),
    isVideo: j['video'] == true,
  );

  /// 小组件格子里显示的标题（文件名可能很长，这里只做空值兜底）。
  String get displayName =>
      name.trim().isEmpty ? dataText('dtoShortcutUntitled', '未命名') : name.trim();
}

/// 笔记小组件里的一条笔记。
class WidgetNoteEntry {
  const WidgetNoteEntry({
    required this.id,
    required this.title,
    this.mtime = 0,
    this.encrypted = false,
    this.notebookId = '',
    this.notebookName = '',
  });

  final String id;
  final String title;

  /// 修改时间（秒，服务端 `mtime`）
  final int mtime;

  /// 加密笔记（小组件只显示标题，绝不显示正文 —— 正文是密文，也无从解密）。
  final bool encrypted;

  /// 所属笔记本 id —— ★ 第 109 轮的**语义更正**：官方
  /// `NotebookAppWidgetProvider`（label = `widget_notebook` = "List of notes"）
  /// 列的是**某个笔记本里的笔记**，配置页 `NotebookListAppWidgetActivity`
  /// 让用户选本 ⇒ 快照必须带笔记本 id 才能按本过滤。
  final String notebookId;

  /// 笔记本名（小组件副标题；空则不显示）。
  final String notebookName;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'mtime': mtime,
    'encrypted': encrypted,
    'notebookId': notebookId,
    'notebookName': notebookName,
  };

  static WidgetNoteEntry fromJson(Map<String, dynamic> j) => WidgetNoteEntry(
    id: _str(j['id']),
    title: _str(j['title']),
    mtime: _int(j['mtime']),
    encrypted: j['encrypted'] == true,
    notebookId: _str(j['notebookId']),
    notebookName: _str(j['notebookName']),
  );

  String get displayTitle =>
      title.trim().isEmpty ? dataText('dtoNoteUntitled', '无标题笔记') : title.trim();
}

/// 笔记本小组件里的一个笔记本（官方 `NotebookAppWidgetProvider`）。
///
/// ★ 第 107 轮 N1 补齐。字段刻意只有三项：
///   * [id] 点击落点（`notebook:<id>`）；
///   * [name] 标题；
///   * [count] 笔记本里的笔记数（官方 adapter 也会显示数量）。
/// **不带笔记正文**（主屏可见性 + 加密笔记是密文）。
class WidgetNotebookEntry {
  const WidgetNotebookEntry({
    required this.id,
    required this.name,
    this.count = 0,
    this.mtime = 0,
  });

  final String id;
  final String name;

  /// 笔记本里的笔记条数（服务端 `NoteStation.Notebook:list` 的计数；没有就是 0）。
  final int count;

  /// 修改时间（秒）；用于"最近使用在前"的排序。
  final int mtime;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'count': count,
    'mtime': mtime,
  };

  static WidgetNotebookEntry fromJson(Map<String, dynamic> j) =>
      WidgetNotebookEntry(
        id: _str(j['id']),
        name: _str(j['name']),
        count: _int(j['count']),
        mtime: _int(j['mtime']),
      );

  String get displayName => name.trim().isEmpty
      ? dataText('widgetNotebookUntitled', '未命名笔记本')
      : name.trim();
}

/// 待办小组件里的一条待办。
class WidgetTodoEntry {
  const WidgetTodoEntry({
    required this.id,
    required this.title,
    this.noteId = '',
    this.due = 0,
    this.done = false,
  });

  final String id;
  final String title;

  /// 所属笔记 id（点击回到那条笔记）
  final String noteId;

  /// 截止时间（秒，服务端 `due_date`）。`0` = 没有截止日期。
  final int due;
  final bool done;

  bool get hasDue => due > 0;

  Map<String, Object?> toJson() => {
    'id': id,
    'noteId': noteId,
    'title': title,
    'due': due,
    'done': done,
  };

  static WidgetTodoEntry fromJson(Map<String, dynamic> j) => WidgetTodoEntry(
    id: _str(j['id']),
    noteId: _str(j['noteId']),
    title: _str(j['title']),
    due: _int(j['due']),
    done: j['done'] == true,
  );

  String get displayTitle =>
      title.trim().isEmpty ? dataText('widgetTodoUntitled', '未命名待办') : title.trim();
}

/// 推给 Android 小组件的一份快照。
class WidgetSnapshot {
  const WidgetSnapshot({
    this.loggedIn = false,
    this.connected = false,
    this.photos = const [],
    this.notes = const [],
    this.todos = const [],
    this.notebooks = const [],
    this.updatedAt = 0,
  });

  final bool loggedIn;
  final bool connected;
  final List<WidgetPhotoEntry> photos;
  final List<WidgetNoteEntry> notes;
  final List<WidgetTodoEntry> todos;
  final List<WidgetNotebookEntry> notebooks;

  /// 生成时间（毫秒）。小组件用来显示"更新于…"。
  final int updatedAt;

  Map<String, Object?> toJson() => {
    'v': kWidgetSnapshotVersion,
    'updatedAt': updatedAt,
    'loggedIn': loggedIn,
    'connected': connected,
    'photos': [for (final p in photos) p.toJson()],
    'notes': [for (final n in notes) n.toJson()],
    'todos': [for (final t in todos) t.toJson()],
    'notebooks': [for (final b in notebooks) b.toJson()],
  };
}

/// 快照 → JSON 字符串。推送通道与落盘都用它。
String encodeWidgetSnapshot(WidgetSnapshot snapshot) =>
    jsonEncode(snapshot.toJson());

/// JSON 字符串 → 快照。
///
/// ⚠️ **绝不抛**：空串 / 半截 JSON / 版本不认识 / 类型不对，一律返回 `null`。
/// 调用方拿到 `null` 就走 [widgetPhotoPlaceholder] 的"未登录"占位分支。
WidgetSnapshot? decodeWidgetSnapshot(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final map = decoded.cast<String, dynamic>();
  // 版本不匹配：宁可不显示，也不按错的字段名硬塞
  if (_int(map['v']) != kWidgetSnapshotVersion) return null;
  return WidgetSnapshot(
    loggedIn: map['loggedIn'] == true,
    connected: map['connected'] == true,
    photos: _listOf(map['photos'], WidgetPhotoEntry.fromJson),
    notes: _listOf(map['notes'], WidgetNoteEntry.fromJson),
    todos: _listOf(map['todos'], WidgetTodoEntry.fromJson),
    notebooks: _listOf(map['notebooks'], WidgetNotebookEntry.fromJson),
    updatedAt: _int(map['updatedAt']),
  );
}

// --------------------------------------------------------------- 纯映射函数

/// **取最近 N 张照片**（相册小组件的核心映射）。
///
/// 规则（可单测，见 `test/widget_snapshot_test.dart`）：
///   * 按 `takenAt` **降序**（服务端时间轴也是这个顺序）；
///   * 时间相同的按 `id` 升序 —— 保证**同一份输入永远同一份输出**（稳定排序），
///     否则小组件每次刷新都换一张图，看起来像在闪；
///   * 按 `id` **去重**（分页合并后可能重复）；
///   * `id` 为空的条目直接丢弃（点不开、也存不了缩略图）；
///   * `limit <= 0` → 空列表。
List<WidgetPhotoEntry> recentWidgetPhotos(
  Iterable<WidgetPhotoEntry> items, {
  int limit = kWidgetPhotoLimit,
}) {
  if (limit <= 0) return const [];
  final seen = <String>{};
  final out = <WidgetPhotoEntry>[];
  for (final e in items) {
    if (!_hasId(e.id)) continue;
    if (!seen.add(e.id)) continue;
    out.add(e);
  }
  out.sort((a, b) {
    final byTime = b.takenAt.compareTo(a.takenAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// **取最近 N 条笔记**（笔记小组件）。规则同上，时间字段是 `mtime`。
List<WidgetNoteEntry> recentWidgetNotes(
  Iterable<WidgetNoteEntry> items, {
  int limit = kWidgetNoteLimit,
}) {
  if (limit <= 0) return const [];
  final seen = <String>{};
  final out = <WidgetNoteEntry>[];
  for (final e in items) {
    if (!_hasId(e.id)) continue;
    if (!seen.add(e.id)) continue;
    out.add(e);
  }
  out.sort((a, b) {
    final byTime = b.mtime.compareTo(a.mtime);
    if (byTime != 0) return byTime;
    return a.id.compareTo(b.id);
  });
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// **某个笔记本里的最近 N 条笔记**（官方 `NotebookAppWidgetProvider`，
/// label = "List of notes"）。
///
/// [notebookId] 为空 ⇒ **不过滤**（配置页还没选 / 用户选"全部笔记"）；
/// 过滤后再套 [recentWidgetNotes] 的排序纪律。
List<WidgetNoteEntry> widgetNotesInNotebook(
  Iterable<WidgetNoteEntry> items, {
  required String notebookId,
  int limit = kWidgetNoteLimit,
}) {
  final id = notebookId.trim();
  final scoped = id.isEmpty ? items : items.where((e) => e.notebookId == id);
  return recentWidgetNotes(scoped, limit: limit);
}

/// **取最近 N 条未完成待办**（待办小组件）。
///
/// 规则：
///   * **先滤掉已完成**（`done == true`）——小组件是"还没做的事"清单；
///   * 有截止时间的排在没截止时间的前面（`due` 升序 = 最紧急在前）；
///   * 都没截止时间时按 `id` 升序（稳定）；
///   * 按 `id` 去重、空 id 丢弃。
List<WidgetTodoEntry> widgetPendingTodos(
  Iterable<WidgetTodoEntry> items, {
  int limit = kWidgetTodoLimit,
}) {
  if (limit <= 0) return const [];
  final seen = <String>{};
  final out = <WidgetTodoEntry>[];
  for (final e in items) {
    if (!_hasId(e.id) || e.done) continue;
    if (!seen.add(e.id)) continue;
    out.add(e);
  }
  out.sort((a, b) {
    if (a.hasDue != b.hasDue) return a.hasDue ? -1 : 1;
    if (a.hasDue && b.hasDue) {
      final byDue = a.due.compareTo(b.due);
      if (byDue != 0) return byDue;
    }
    return a.id.compareTo(b.id);
  });
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// **取最近 N 个笔记本**（笔记本小组件）。
///
/// 规则：按 `mtime` 降序（最近动过的在前）、同时间按 `id` 升序（稳定）、
/// 去重、空 id 丢弃 —— 与笔记/照片同一套排序纪律，
/// 保证"同一份输入永远同一份输出"（否则小组件每次刷新都在跳）。
List<WidgetNotebookEntry> widgetNotebooks(
  Iterable<WidgetNotebookEntry> items, {
  int limit = kWidgetNotebookLimit,
}) {
  if (limit <= 0) return const [];
  final seen = <String>{};
  final out = <WidgetNotebookEntry>[];
  for (final e in items) {
    if (!_hasId(e.id)) continue;
    if (!seen.add(e.id)) continue;
    out.add(e);
  }
  out.sort((a, b) {
    final byTime = b.mtime.compareTo(a.mtime);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// 笔记本小组件的占位判定（同 [widgetPhotoPlaceholder] 的顺序）。
WidgetPlaceholder? widgetNotebookPlaceholder(WidgetSnapshot? snapshot) {
  if (snapshot == null || !snapshot.loggedIn) {
    return WidgetPlaceholder.notLoggedIn;
  }
  if (!snapshot.connected) return WidgetPlaceholder.notConnected;
  if (snapshot.notebooks.isEmpty) return WidgetPlaceholder.noNotebooks;
  return null;
}

// --------------------------------------------------------------- 占位策略

/// 相册小组件能不能画出内容；`null` = **能**，非空 = 要显示的占位原因。
///
/// 判定顺序（先登录、再连接、最后空数据）—— 顺序本身是行为契约：
/// 未登录时说"连不上 NAS"会误导用户去查网络。
WidgetPlaceholder? widgetPhotoPlaceholder(WidgetSnapshot? snapshot) {
  if (snapshot == null || !snapshot.loggedIn) {
    return WidgetPlaceholder.notLoggedIn;
  }
  if (!snapshot.connected) return WidgetPlaceholder.notConnected;
  if (snapshot.photos.isEmpty) return WidgetPlaceholder.noPhotos;
  return null;
}

/// 笔记小组件的占位判定（同 [widgetPhotoPlaceholder] 的顺序）。
WidgetPlaceholder? widgetNotePlaceholder(WidgetSnapshot? snapshot) {
  if (snapshot == null || !snapshot.loggedIn) {
    return WidgetPlaceholder.notLoggedIn;
  }
  if (!snapshot.connected) return WidgetPlaceholder.notConnected;
  if (snapshot.notes.isEmpty) return WidgetPlaceholder.noNotes;
  return null;
}

/// 待办小组件的占位判定。
///
/// ⚠️ 与相册/笔记不同：**待办为空是常态**（今天没事做），所以"连上了但一条
/// 未完成待办都没有"显示的是"没有待办"这句正常的空态，不是错误。
WidgetPlaceholder? widgetTodoPlaceholder(WidgetSnapshot? snapshot) {
  if (snapshot == null || !snapshot.loggedIn) {
    return WidgetPlaceholder.notLoggedIn;
  }
  if (!snapshot.connected) return WidgetPlaceholder.notConnected;
  if (snapshot.todos.isEmpty) return WidgetPlaceholder.noTodos;
  return null;
}

/// 占位原因 → **人话**（对应用户当前语言）。
///
/// `key + 中文原文` 走 [dataText]：没装翻译器（纯 Dart 单测 / 探针）回落中文；
/// Flutter 层装了就用当前语言。ARB key 见 `lib/l10n/app_en.arb` /
/// `app_zh.arb`（`widgetPlaceholder*`）。
String widgetPlaceholderText(WidgetPlaceholder placeholder, WidgetKind kind) {
  // 占位原因里"未登录/未连接"与类别无关，只有"空数据"按类别分文案。
  switch (placeholder) {
    case WidgetPlaceholder.notLoggedIn:
      return dataText('widgetPlaceholderNotLoggedIn', switch (kind) {
        WidgetKind.photos => '打开 App 登录后，这里会显示最近的照片',
        WidgetKind.notes => '打开 App 登录后，这里会显示最近的笔记',
        WidgetKind.todos => '打开 App 登录后，这里会显示未完成的待办',
        WidgetKind.notebooks => '打开 App 登录后，这里会显示笔记本',
      });
    case WidgetPlaceholder.notConnected:
      return dataText('widgetPlaceholderNotConnected', switch (kind) {
        WidgetKind.photos => '还没连接 NAS，连接后这里会显示最近的照片',
        WidgetKind.notes => '还没连接 NAS，连接后这里会显示最近的笔记',
        WidgetKind.todos => '还没连接 NAS，连接后这里会显示未完成的待办',
        WidgetKind.notebooks => '还没连接 NAS，连接后这里会显示笔记本',
      });
    case WidgetPlaceholder.noPhotos:
      return dataText('widgetPlaceholderNoPhotos', '相册里还没有照片');
    case WidgetPlaceholder.noNotes:
      return dataText('widgetPlaceholderNoNotes', '还没有笔记，点一下就能新建');
    case WidgetPlaceholder.noTodos:
      return dataText('widgetPlaceholderNoTodos', '没有未完成的待办');
    case WidgetPlaceholder.noNotebooks:
      return dataText('widgetPlaceholderNoNotebooks', '还没有笔记本');
  }
}

/// 小组件标题（"相册" / "笔记" / "待办" / "笔记本"）。
String widgetTitleText(WidgetKind kind) => switch (kind) {
  WidgetKind.photos => dataText('navPhotos', '相册'),
  WidgetKind.notes => dataText('wsNotes', '笔记'),
  WidgetKind.todos => dataText('widgetTodosTitle', '待办'),
  WidgetKind.notebooks => dataText('widgetNotebooksTitle', '笔记本'),
};

/// "新建笔记"快捷方式按钮的文字。
String widgetNewNoteText() => dataText('widgetNewNote', '新建笔记');

// --------------------------------------------------------------- 点击目标

/// 小组件点进来要打开的落点。
enum WidgetTargetKind {
  /// 只切到相册 tab
  photos,

  /// 只切到笔记 tab
  notes,

  /// 切到笔记 tab 并新建一条笔记
  newNote,

  /// 打开某一张照片（`photo:<itemId>`）
  photo,

  /// 打开某一条笔记（`note:<objectId>`）
  note,

  /// 打开某条待办所属的笔记（`todo:<noteId>`）
  todo,

  /// 打开某个笔记本（`notebook:<objectId>`）—— ★ N1（107 轮）
  notebook,

  /// ★ N1（110 轮）：官方 `ShortcutAppWidgetProvider`（"Quickstart"）
  /// 6 格动作栏的 5 个动作（第 6 格是 App logo = 只打开 App）。
  /// 官方 `res/layout/appwidget_shortcut.xml` 的按钮 id：
  /// `app` / `new_camera` / `new_audio` / `new_att` / `new_plain` / `todos`。
  newCamera,
  newAudio,
  newAttachment,
  newTodo,
}

/// 一次小组件点击的落点。
///
/// 序列化形式（Kotlin 侧 `WidgetBridge.EXTRA_TARGET` 逐字对应）：
/// `photos` / `notes` / `note_new` / `photo:<id>` / `note:<id>` / `todo:<id>`
class WidgetTarget {
  const WidgetTarget(this.kind, [this.id = '']);

  final WidgetTargetKind kind;
  final String id;

  /// 存进 Intent extra 的字符串。
  String encode() => switch (kind) {
    WidgetTargetKind.photos => 'photos',
    WidgetTargetKind.notes => 'notes',
    WidgetTargetKind.newNote => 'note_new',
    WidgetTargetKind.photo => 'photo:$id',
    WidgetTargetKind.note => 'note:$id',
    WidgetTargetKind.todo => 'todo:$id',
    WidgetTargetKind.notebook => 'notebook:$id',
    // 动作栏落点（无参数，`id` 恒为空）
    WidgetTargetKind.newCamera => 'note_camera',
    WidgetTargetKind.newAudio => 'note_audio',
    WidgetTargetKind.newAttachment => 'note_att',
    WidgetTargetKind.newTodo => 'todo_list',
  };

  @override
  bool operator ==(Object other) =>
      other is WidgetTarget && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'WidgetTarget(${encode()})';
}

/// 解析小组件点击目标。**不认识 / 为空一律返回 `null`**（调用方忽略即可，
/// 绝不能让一个坏 extra 把 App 打崩）。
WidgetTarget? parseWidgetTarget(String? raw) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty) return null;
  switch (s) {
    case 'photos':
      return const WidgetTarget(WidgetTargetKind.photos);
    case 'notes':
      return const WidgetTarget(WidgetTargetKind.notes);
    case 'note_new':
      return const WidgetTarget(WidgetTargetKind.newNote);
    case 'note_camera':
      return const WidgetTarget(WidgetTargetKind.newCamera);
    case 'note_audio':
      return const WidgetTarget(WidgetTargetKind.newAudio);
    case 'note_att':
      return const WidgetTarget(WidgetTargetKind.newAttachment);
    case 'todo_list':
      return const WidgetTarget(WidgetTargetKind.newTodo);
  }
  final at = s.indexOf(':');
  if (at <= 0) return null;
  final head = s.substring(0, at);
  final id = s.substring(at + 1).trim();
  if (id.isEmpty) return null;
  return switch (head) {
    'photo' => WidgetTarget(WidgetTargetKind.photo, id),
    'note' => WidgetTarget(WidgetTargetKind.note, id),
    'todo' => WidgetTarget(WidgetTargetKind.todo, id),
    'notebook' => WidgetTarget(WidgetTargetKind.notebook, id),
    _ => null,
  };
}

// --------------------------------------------------------------- 内部工具

String _str(Object? v) => v == null ? '' : '$v';

/// id 是不是"真的能用来点开 / 存缩略图"。
///
/// 纯空串**和只含空白**的 id 都算无效（服务端偶尔会回 `" "` 这种脏值）：
/// 前者点不开，后者会存出一个名字全是下划线的缩略图文件。
bool _hasId(String id) => id.trim().isNotEmpty;

String? _strOrNull(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

List<T> _listOf<T>(Object? raw, T Function(Map<String, dynamic>) parse) {
  if (raw is! List) return const [];
  final out = <T>[];
  for (final e in raw) {
    if (e is Map) {
      // 单条坏数据丢弃，不影响其余条目（防"一条脏数据整个小组件空白"）
      try {
        out.add(parse(e.cast<String, dynamic>()));
      } catch (_) {
        // 忽略这一条
      }
    }
  }
  return out;
}
