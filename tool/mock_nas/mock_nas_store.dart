// Mock NAS 的**有状态业务后端**（`tool/mock_nas/mock_nas_server.dart` 的兄弟模块）。
//
// 目的：把 mock 从「能力表 + 空 data」升级成**可断言的端到端后端** ——
// 写方法（`Note/delete`、`FileStation.Delete/start`、`DownloadStation2.Task/delete`
// …）真的改内存状态，"操作后状态正确"因此可以被断言，而**不碰任何真实 NAS**。
//
// 设计：
//   * **零三方依赖**（只用 `dart:convert`），可被 `dart <file>` 直接加载；
//   * 参数是 DSM 的「Gson 二次编码」形态 —— 字符串带引号、数组/对象整体是
//     JSON 文本。本文件用 [MockParams] 统一解码：能 `jsonDecode` 就解，
//     否则按裸串处理（路径/关键字这类本来就不是 JSON）。
//   * [MockNasStore.reply] 返回 `null` 表示「本 store 不管这个 API」，
//     由 server 回落到通用的空 `data` 成功。
//
// ⚠️ 这里只实现 **`lib/src/data/` 真的在调用**的 API 家族/方法，不铺开仿真。
//    事实来源是仓库自身的客户端代码 + `docs/api-server-authoritative.md`。

import 'dart:convert';

/// DSM 参数解码器：值可能是 JSON 文本（Gson 二次编码）或裸串。
class MockParams {
  MockParams(this.raw);

  final Map<String, String> raw;

  bool has(String key) => raw.containsKey(key);

  /// 解一个参数：能当 JSON 解就当 JSON（`"x"`→`x`、`[1,2]`→List、`true`→bool），
  /// 解不了就是原串（路径、关键字、URL）。
  Object? j(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v.isEmpty) return v;
    try {
      return jsonDecode(v);
    } catch (_) {
      return v;
    }
  }

  String str(String key, [String fallback = '']) {
    final v = j(key);
    if (v == null) return fallback;
    return '$v';
  }

  int i(String key, [int fallback = 0]) {
    final v = j(key);
    if (v is num) return v.toInt();
    if (v is bool) return v ? 1 : 0;
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  bool b(String key, [bool fallback = false]) {
    final v = j(key);
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == 'true' || v == '1';
    return fallback;
  }

  /// 字符串数组（`object_id`/`path`/`id` 这类既可能是标量也可能是数组）。
  List<String> strs(String key) {
    final v = j(key);
    if (v is List) return [for (final e in v) '$e'];
    if (v == null) return const [];
    return ['$v'];
  }

  List<int> ints(String key) {
    final v = j(key);
    if (v is List) {
      final out = <int>[];
      for (final e in v) {
        final n = e is num ? e.toInt() : int.tryParse('$e');
        if (n != null) out.add(n);
      }
      return out;
    }
    if (v is num) return [v.toInt()];
    final n = int.tryParse('$v');
    return n == null ? const [] : [n];
  }
}

// ============================================================ 领域对象

class MockNote {
  MockNote({
    required this.id,
    required this.title,
    required this.parentId,
    this.content = '',
    this.brief = '',
    this.ctime = 0,
    this.mtime = 0,
    this.ver = '1.0',
    this.encrypt = false,
    List<String>? tags,
    this.recycle = false,
    this.latitude,
    this.longitude,
    this.location,
    this.sourceUrl,
    this.individualShared = false,
    this.individualJoined = false,
    Map<String, Map<String, dynamic>>? attachments,
  }) : tags = tags ?? <String>[],
       attachments = attachments ?? <String, Map<String, dynamic>>{};

  final String id;
  String title;
  String parentId;
  String content;
  String brief;
  int ctime;
  int mtime;
  String ver;
  bool encrypt;
  List<String> tags;
  bool recycle;
  double? latitude;
  double? longitude;
  String? location;
  String? sourceUrl;
  bool individualShared;
  bool individualJoined;
  final Map<String, Map<String, dynamic>> attachments;

  Map<String, dynamic> toJson({bool withContent = true}) => {
    'object_id': id,
    'title': title,
    'parent_id': parentId,
    'old_parent_id': parentId,
    if (withContent) 'content': content,
    'brief': brief,
    'ctime': ctime,
    'mtime': mtime,
    'ver': ver,
    'encrypt': encrypt,
    'tag': tags,
    'recycle': recycle,
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
    if (location != null) 'location': location,
    if (sourceUrl != null) 'source_url': sourceUrl,
    'owner': {'name': 'mock', 'uid': 1000},
    'individual_shared': individualShared,
    'individual_joined': individualJoined,
    'link_id': 'mocklink-$id',
    'attachment': attachments,
  };
}

class MockNotebook {
  MockNotebook({
    required this.id,
    required this.title,
    this.archive = false,
    this.preset = false,
    this.stack,
    this.ctime = 0,
    this.mtime = 0,
  });

  final String id;
  String title;
  bool archive;
  bool preset;
  String? stack;
  int ctime;
  int mtime;
  String ver = '1.0';

  Map<String, dynamic> toJson() => {
    'object_id': id,
    'title': title,
    'parent_id': null,
    'archive': archive,
    'preset': preset,
    if (stack != null) 'stack': stack,
    'ctime': ctime,
    'mtime': mtime,
    'ver': ver,
  };
}

class MockTodo {
  MockTodo({
    required this.id,
    required this.title,
    this.done = false,
    this.star = false,
    this.comment = '',
    this.priority = -1,
    this.dueDate = -1,
    this.reminderOffset = 0,
    this.noteId = '',
    this.parentId = '',
  });

  final String id;
  String title;
  bool done;
  bool star;
  String comment;
  int priority;
  int dueDate;
  int reminderOffset;
  String noteId;
  String parentId;

  Map<String, dynamic> toJson() => {
    'object_id': id,
    'title': title,
    'done': done,
    'star': star,
    'comment': comment,
    'priority': priority,
    'due_date': dueDate,
    'reminder_offset': reminderOffset,
    'note_id': noteId,
    'parent_id': parentId,
  };
}

class MockTag {
  MockTag({required this.id, required this.title, required this.category});

  final String id;
  String title;
  final String category;

  Map<String, dynamic> toJson(List<String> noteIds) => {
    'tag_id': id,
    'title': title,
    'category': category,
    'items': noteIds,
  };
}

class MockFsNode {
  MockFsNode({
    required this.path,
    required this.isDir,
    this.size = 0,
    this.mtime = 0,
  });

  String path;
  final bool isDir;
  int size;
  int mtime;

  String get name => path.split('/').where((s) => s.isNotEmpty).last;
  String get parent {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }
}

class MockPhoto {
  MockPhoto({
    required this.id,
    required this.filename,
    this.filesize = 0,
    this.time = 0,
    this.folderId = '0',
    this.type = 'photo',
    this.favorite = false,
    List<String>? albumIds,
  }) : albumIds = albumIds ?? <String>[];

  final String id;
  String filename;
  int filesize;
  int time;
  String folderId;
  final String type;
  bool favorite;
  final List<String> albumIds;

  Map<String, dynamic> toJson() => {
    'id': id,
    'filename': filename,
    'filesize': filesize,
    'time': time,
    'indexed_time': time,
    'folder_id': folderId,
    'type': type,
    'owner_user_id': '1',
    'album_ids': albumIds,
    'additional': {
      'favorite': favorite,
      'thumbnail': {
        'cache_key': 'mock-$id',
        'unit_id': int.tryParse(id) ?? 1,
        'm': 0,
      },
      // N4/Foto：`gps` 是**键存在性**语义 —— 只有给了坐标才放这个键。
    },
  };
}

class MockAlbum {
  MockAlbum({
    required this.id,
    required this.name,
    this.itemCount = 0,
    this.type = 'normal',
  });

  final String id;
  String name;
  int itemCount;
  final String type;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'item_count': itemCount,
    'shared': false,
    'owner_user_id': '1',
    'type': type,
    'additional': <String, dynamic>{},
  };
}

class MockFolder {
  MockFolder({required this.id, required this.name, this.parentId = '0'});

  final String id;
  String name;
  String parentId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'parent_id': parentId,
    'shared': false,
    'owner_user_id': '1',
    'item_count': 0,
  };
}

class MockDownloadTask {
  MockDownloadTask({
    required this.id,
    required this.title,
    required this.type,
    this.status = 2,
    this.size = 0,
    this.destination = '/volume1/downloads',
    this.priority = 'normal',
    this.uri = '',
    this.sizeDownloaded = 0,
    this.sizeUploaded = 0,
    this.speedDownload = 0,
    this.speedUpload = 0,
    this.maxDownloadRate = 0,
    this.maxUploadRate = 0,
    this.seedingRatio = 0,
    this.seedingInterval = 0,
    this.maxPeers = 0,
    this.extractPassword = '',
    this.username = '',
    this.password = '',
  });

  final String id;
  String title;
  String type;
  int status;
  int size;
  String destination;
  String priority;
  String uri;
  int sizeDownloaded;
  int sizeUploaded;
  int speedDownload;
  int speedUpload;
  int maxDownloadRate;
  int maxUploadRate;
  int seedingRatio;
  int seedingInterval;
  int maxPeers;
  String extractPassword;
  String username;
  String password;
  int createdTime = 0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'type': type,
    'status': status,
    'size': size,
    'username': username.isEmpty ? 'mock' : username,
    'additional': {
      'detail': {
        'destination': destination,
        'priority': priority,
        'uri': uri,
        'hash': 'MOCKHASH$id',
        'connected_peers': 1,
        'total_peers': 2,
        'connected_seeders': 1,
        'connected_leechers': 1,
        'started_time': createdTime,
        'created_time': createdTime,
        'completed_time': 0,
        'waiting_seconds': 0,
        'last_seen_complete': 0,
      },
      'transfer': {
        'size_downloaded': sizeDownloaded,
        'size_uploaded': sizeUploaded,
        'speed_download': speedDownload,
        'speed_upload': speedUpload,
        'total_pieces': 10,
        'downloaded_pieces': 4,
        'seed_elapsed': 0,
      },
    },
  };
}

// ============================================================ Store

/// 有状态 mock 后端。
///
/// 全部状态都在内存里、随进程消失 —— **mock 上的写操作永远不会碰到真实数据**。
class MockNasStore {
  MockNasStore({this.mediaSize = 1048576}) {
    _seed();
  }

  /// `FileStation.Download` 内置合成媒体的大小（与 server 一致）。
  final int mediaSize;

  // ---- 会话（由 server 维护 loginSeq，这里只做业务状态）
  // ---- 笔记
  final Map<String, MockNote> notes = {};
  final Map<String, MockNotebook> notebooks = {};
  final Map<String, MockTodo> todos = {};
  final Map<String, MockTag> tags = {};
  final List<Map<String, dynamic>> shortcuts = [];
  final Map<String, List<Map<String, dynamic>>> versions = {};
  final Map<String, bool> searchAttachmentEnabled = {'enabled': false};

  // ---- 文件
  final Map<String, MockFsNode> fs = {};

  // ---- 下载
  final Map<String, MockDownloadTask> downloadTasks = {};
  final List<String> captchaTaskIds = [];
  final Map<String, Map<String, dynamic>> rssFeeds = {};
  final List<Map<String, dynamic>> rssItems = [];
  // 从 1000 起 —— 种子数据用的是 `n-1` / `ds-1` 这类小号 id，错开防撞。
  int _seq = 1000;

  // ---- 相册
  final Map<String, MockPhoto> photos = {};
  final Map<String, MockAlbum> albums = {};
  final Map<String, MockFolder> folders = {};

  /// 相册列表默认排序（`Browse.Album/get|set_album_list_order`）—— 真的持久。
  String albumListOrderBy = 'create_time';
  String albumListOrderDirection = 'desc';

  String _next(String prefix) => '$prefix-${++_seq}';

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  void _seed() {
    final now = _now;
    // 笔记本：一个普通 + 一个归档 + 一个预设（"我的记事本"）
    notebooks['nb-1'] = MockNotebook(
      id: 'nb-1',
      title: '工作',
      ctime: now - 90000,
      mtime: now - 100,
    );
    notebooks['nb-2'] = MockNotebook(
      id: 'nb-2',
      title: '归档库',
      archive: true,
      ctime: now - 80000,
      mtime: now - 200,
    );
    notebooks['nb-default'] = MockNotebook(
      id: 'nb-default',
      title: '',
      preset: true,
      ctime: now - 99999,
      mtime: now - 99999,
    );

    notes['n-1'] = MockNote(
      id: 'n-1',
      title: '周会纪要',
      parentId: 'nb-1',
      content: '<p>本周进度</p>',
      brief: '本周进度',
      ctime: now - 5000,
      mtime: now - 50,
      ver: '3.0',
      tags: ['tag-work'],
      attachments: {
        'file-1': {
          'file_id': 'file-1',
          'name': 'spec.txt',
          'size': 128,
          'type': 'text/plain',
          'ctime': now - 5000,
          'mtime': now - 50,
        },
      },
    );
    notes['n-2'] = MockNote(
      id: 'n-2',
      title: '读书笔记',
      parentId: 'nb-1',
      content: '<p>第一章</p>',
      brief: '第一章',
      ctime: now - 4000,
      mtime: now - 40,
      ver: '2.0',
      tags: ['tag-read', 'tag-work'],
    );
    notes['n-3'] = MockNote(
      id: 'n-3',
      title: '已删草稿',
      parentId: 'nb-1',
      recycle: true,
      ctime: now - 3000,
      mtime: now - 30,
      ver: '1.0',
    );

    versions['n-1'] = [
      {
        'id': 'v-3',
        'version': '3.0',
        'author': 'mock',
        'mtime': now - 50,
        'commit_msg': 'Flutter',
        'last_version': true,
      },
      {
        'id': 'v-2',
        'version': '2.0',
        'author': 'mock',
        'mtime': now - 500,
        'commit_msg': 'desktop',
        'last_version': false,
      },
      {
        'id': 'v-1',
        'version': '1.0',
        'author': 'mock',
        'mtime': now - 5000,
        'commit_msg': 'desktop',
        'last_version': false,
      },
    ];

    tags['tag-work'] = MockTag(id: 'tag-work', title: '工作', category: 'note');
    tags['tag-read'] = MockTag(id: 'tag-read', title: '阅读', category: 'note');

    todos['t-1'] = MockTodo(
      id: 't-1',
      title: '写周报',
      dueDate: now + 86400,
      priority: 200,
      star: true,
      comment: '周五前',
    );
    todos['t-2'] = MockTodo(
      id: 't-2',
      title: '订机票',
      done: true,
      priority: 100,
    );

    shortcuts.add({
      'id': 'sc-1',
      'category': 'note',
      'title': '周会纪要',
      'items': ['n-1'],
      'owner': {'name': 'mock'},
    });

    // ---- 文件系统：与旧 mock 的 List 输出保持兼容（selftest/probe 依赖）
    for (final path in ['/home', '/home/Books', '/home/Photos', '/mock-share']) {
      fs[path] = MockFsNode(path: path, isDir: true, mtime: now);
    }
    fs['/home/Books/mock-clip.mp4'] = MockFsNode(
      path: '/home/Books/mock-clip.mp4',
      isDir: false,
      size: mediaSize,
      mtime: now,
    );
    fs['/home/Books/session-expiry.txt'] = MockFsNode(
      path: '/home/Books/session-expiry.txt',
      isDir: false,
      size: 64,
      mtime: now,
    );

    // ---- 下载任务：一条在跑、一条已完成、一条错误（覆盖 A/B 组判据）
    downloadTasks['ds-1'] = MockDownloadTask(
      id: 'ds-1',
      title: 'mock-linux.iso',
      type: 'http',
      status: 2,
      size: 4096,
      sizeDownloaded: 1024,
      speedDownload: 512,
      uri: 'https://example.invalid/mock-linux.iso',
    )..createdTime = now - 600;
    downloadTasks['ds-2'] = MockDownloadTask(
      id: 'ds-2',
      title: 'mock-ubuntu.torrent',
      type: 'bt',
      status: 5,
      size: 8192,
      sizeDownloaded: 8192,
      destination: '/volume1/downloads/bt',
    )..createdTime = now - 500;
    downloadTasks['ds-3'] = MockDownloadTask(
      id: 'ds-3',
      title: 'mock-broken.nzb',
      type: 'nzb',
      status: 114,
      size: 100,
    )..createdTime = now - 400;
    downloadTasks['ds-4'] = MockDownloadTask(
      id: 'ds-4',
      title: 'mock-captcha.torrent',
      type: 'bt',
      status: 15,
      size: 2048,
    )..createdTime = now - 300;
    captchaTaskIds.add('ds-4');

    rssItems.addAll([
      {
        'id': 'item-1',
        'feed_id': 'feed-1',
        'title': 'Mock RSS Item A',
        'url': 'https://example.invalid/rss-a.torrent',
        'link': 'https://example.invalid/post-a',
        'date': 1893456000,
        'size': 4096,
        'is_new': true,
      },
      {
        'id': 'item-2',
        'feed_id': 'feed-1',
        'title': 'Mock RSS Item B',
        'url': 'https://example.invalid/rss-b.torrent',
        'link': 'https://example.invalid/post-b',
        'date': 1893456001,
        'size': 8192,
        'is_new': false,
      },
    ]);
    rssFeeds['feed-1'] = {
      'id': 'feed-1',
      'title': 'Mock Feed',
      'url': 'https://example.invalid/rss',
      'enabled': true,
      'item_count': 2,
      'is_updating': true,
      'last_update': 1893456000,
      'username': 'mock',
    };

    // ---- 相册
    albums['a-1'] = MockAlbum(id: 'a-1', name: '旅行', itemCount: 2);
    albums['a-2'] = MockAlbum(id: 'a-2', name: '空相册', itemCount: 0);
    photos['1'] = MockPhoto(
      id: '1',
      filename: 'IMG_0001.jpg',
      filesize: 2048,
      time: now - 86400,
      favorite: true,
      albumIds: ['a-1'],
    );
    photos['2'] = MockPhoto(
      id: '2',
      filename: 'IMG_0002.jpg',
      filesize: 4096,
      time: now - 3600,
      albumIds: ['a-1'],
    );
    folders['10'] = MockFolder(id: '10', name: 'root', parentId: '0');
    folders['11'] = MockFolder(id: '11', name: '手机备份', parentId: '10');
  }

  // ------------------------------------------------------------ 入口

  /// 处理一个 DSM WebAPI 调用。
  ///
  /// 返回完整响应体（`{success:…, data:…}` / `{success:false,error:{code}}`）；
  /// 返回 `null` 表示本 store 不管这个 API。
  Map<String, dynamic>? reply(
    String api,
    String method,
    Map<String, String> rawParams,
  ) {
    final p = MockParams(rawParams);
    switch (api) {
      // ---------------------------------------------------------- 笔记
      case 'SYNO.NoteStation.Notebook':
        return _notebook(method, p);
      case 'SYNO.NoteStation.Notebook.Polling':
        return _notebookPolling(method, p);
      case 'SYNO.NoteStation.Note':
        return _note(method, p);
      case 'SYNO.NoteStation.Note.Version':
        return _noteVersion(method, p);
      case 'SYNO.NoteStation.Note.Polling':
        return _notePolling(method, p);
      case 'SYNO.NoteStation.Tag':
        return _tag(method, p);
      case 'SYNO.NoteStation.Todo':
        return _todo(method, p);
      case 'SYNO.NoteStation.Shortcut':
        return _shortcut(method, p);
      case 'SYNO.NoteStation.FTS':
        return _fts(method, p);
      case 'SYNO.NoteStation.Info':
        return _noteInfo(method, p);
      case 'SYNO.NoteStation.Setting':
        return _noteSetting(method, p);
      case 'SYNO.NoteStation.Export.Note':
      case 'SYNO.NoteStation.Export.Notebook':
      case 'SYNO.NoteStation.Import.Enex':
      case 'SYNO.NoteStation.Import.Notebook':
        return _noteTransfer(api, method, p);
      case 'SYNO.NoteStation.Note.Encrypt':
        return _ok({'token': 'MOCK-UNLOCK-TOKEN'});
      // ---------------------------------------------------------- 文件
      case 'SYNO.FileStation.List':
        return _fsList(method, p);
      case 'SYNO.FileStation.Delete':
        return _fsDelete(method, p);
      case 'SYNO.FileStation.CopyMove':
        return _fsCopyMove(method, p);
      case 'SYNO.FileStation.CreateFolder':
        return _fsCreateFolder(method, p);
      case 'SYNO.FileStation.Rename':
        return _fsRename(method, p);
      case 'SYNO.FileStation.CheckExist':
        return _fsCheckExist(method, p);
      case 'SYNO.FileStation.BackgroundTask':
        return _fsBackgroundTask(method, p);
      case 'SYNO.Core.RecycleBin':
        // `start {id:<共享文件夹名>}` —— 清空该共享的回收站（不可恢复）
        if (method == 'start') {
          final share = p.str('id');
          final recycle = '/$share/#recycle';
          fs.removeWhere((k, _) => k == recycle || k.startsWith('$recycle/'));
          return _ok({});
        }
        return _err(103);
      // ---------------------------------------------------------- 下载
      case 'SYNO.DownloadStation2.Task':
        return _dsTask(method, p);
      case 'SYNO.DownloadStation2.Task.Statistic':
        return _dsStatistic(method, p);
      case 'SYNO.DownloadStation2.Settings.Location':
        return _ok({'default_destination': '/volume1/downloads'});
      case 'SYNO.DownloadStation2.Task.BT':
        return _dsBt(method, p);
      case 'SYNO.DownloadStation2.Task.BT.Tracker':
        return _dsTracker(method, p);
      case 'SYNO.DownloadStation2.Task.BT.Peer':
        return _dsPeer(method, p);
      case 'SYNO.DownloadStation2.Task.BT.File':
        return _dsFile(method, p);
      case 'SYNO.DownloadStation2.Task.NZB.Log':
        return _ok({'nzblog': 'mock nzb log'});
      case 'SYNO.DownloadStation2.Task.NZB.File':
        return _ok({
          'items': [
            {'name': 'mock.nzb.001', 'size': 512},
          ],
          'total': 1,
        });
      case 'SYNO.DownloadStation2.Task.List':
        return _dsCreateList(method, p);
      case 'SYNO.DownloadStation2.Task.List.Polling':
        // `download`：用选中的下标真正开下载 → 回 task_id
        if (method == 'download') {
          final listId = p.str('list_id');
          final ids = createLists[listId];
          if (ids == null) return _err(404);
          for (final id in ids) {
            downloadTasks[id]?.status = 2;
          }
          createLists.remove(listId);
          return _ok({'task_id': ids.isEmpty ? '' : ids.first});
        }
        return _err(103);
      case 'SYNO.DownloadStation2.Captcha':
        return _dsCaptcha(method, p);
      case 'SYNO.DownloadStation2.BTSearch':
        return _dsBtSearch(method, p);
      case 'SYNO.DownloadStation.BTSearch':
        return _dsBtSearchLegacy(method, p);
      case 'SYNO.DownloadStation2.RSS.Feed':
        return _dsRssFeed(method, p);
      case 'SYNO.DownloadStation2.RSS.Item':
        return _dsRssItem(method, p);
      // ---------------------------------------------------------- 相册
      case 'SYNO.Foto.Browse.Item':
        return _photoItem(method, p);
      case 'SYNO.Foto.Browse.Album':
        return _photoAlbum(method, p);
      case 'SYNO.Foto.Browse.NormalAlbum':
        return _photoNormalAlbum(method, p);
      case 'SYNO.Foto.Browse.Folder':
        return _photoFolder(method, p);
      case 'SYNO.Foto.Browse.Favorites':
        return _ok({'list': <dynamic>[], 'total': 0});
    }
    return null;
  }

  Map<String, dynamic> _ok(Map<String, dynamic> data) => {
    'success': true,
    'data': data,
  };

  Map<String, dynamic> _err(int code) => {
    'success': false,
    'error': {'code': code},
  };

  // ============================================================ 笔记

  Map<String, dynamic> _notebook(String method, MockParams p) {
    switch (method) {
      case 'list':
        final includeArchived = (p.j('filter') is Map)
            ? ((p.j('filter') as Map)['archive'] == true)
            : false;
        final list = notebooks.values
            .where((n) => includeArchived || !n.archive)
            .map((n) => n.toJson())
            .toList();
        return _ok({
          'notebooks': list,
          'offset': 0,
          'total': list.length,
        });
      case 'get':
        final nb = notebooks[p.str('object_id')];
        if (nb == null) return _err(408);
        return _ok(nb.toJson());
      case 'create':
        final id = _next('nb');
        final now = _now;
        notebooks[id] = MockNotebook(
          id: id,
          title: p.str('title'),
          ctime: p.i('ctime', now),
          mtime: now,
        );
        return _ok({'object_id': id});
      case 'set':
        final nb = notebooks[p.str('object_id')];
        if (nb == null) return _err(408);
        if (p.has('title')) nb.title = p.str('title');
        // `stack` 总是发（null/空串 = 移出 Shelf）
        if (p.has('stack')) {
          final s = p.str('stack');
          nb.stack = s.isEmpty ? null : s;
        }
        nb.mtime = _now;
        return _ok({});
      case 'delete':
        final id = p.str('object_id');
        notebooks.remove(id);
        return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _notebookPolling(String method, MockParams p) {
    switch (method) {
      case 'archive':
        final nb = notebooks[p.str('object_id')];
        if (nb == null) return _err(408);
        nb.archive = p.b('enable');
        nb.mtime = _now;
        return _ok({'task_id': _next('task')});
      case 'archive_status':
        return _ok({'finish': true, 'success': true});
      case 'archive_stop':
        return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _note(String method, MockParams p) {
    switch (method) {
      case 'list':
        var all = notes.values.toList();
        // G4：`tag` + `tag_operator`（and / or）服务端过滤
        final wanted = p.strs('tag');
        if (wanted.isNotEmpty) {
          final and = p.str('tag_operator', 'or') == 'and';
          all = all
              .where(
                (n) => and
                    ? wanted.every(n.tags.contains)
                    : wanted.any(n.tags.contains),
              )
              .toList();
        }
        final list = all.map((n) => n.toJson(withContent: false)).toList();
        return _ok({'notes': list, 'offset': 0, 'total': list.length});
      case 'get':
        final n = notes[p.str('object_id')];
        if (n == null) return _err(408);
        // `ver` 指定时按版本表返回题目（内容不做版本仿真，只回同一份题目）
        return _ok(n.toJson());
      case 'create':
        final id = p.str('object_id').isEmpty ? _next('n') : p.str('object_id');
        final now = _now;
        final note = MockNote(
          id: id,
          title: p.str('title'),
          parentId: p.str('parent_id'),
          content: p.str('content'),
          brief: p.str('brief'),
          ctime: p.i('ctime', now),
          mtime: p.i('mtime', now),
          encrypt: p.b('encrypt'),
          latitude: _doubleOrNull(p.j('latitude')),
          longitude: _doubleOrNull(p.j('longitude')),
          location: p.has('location') ? p.str('location') : null,
          sourceUrl: p.has('source_url') ? p.str('source_url') : null,
        );
        notes[id] = note;
        versions[id] = [
          {
            'id': 'v-1',
            'version': note.ver,
            'author': 'mock',
            'mtime': now,
            'commit_msg': 'Flutter',
            'last_version': true,
          },
        ];
        return _ok({'object_id': id, 'ver': note.ver});
      case 'set':
        final ids = p.strs('object_id');
        final data = <dynamic>[];
        final errors = <dynamic>[];
        for (final id in ids) {
          final n = notes[id];
          if (n == null) {
            errors.add({'code': 408, 'object_id': id});
            continue;
          }
          if (p.has('title')) n.title = p.str('title');
          if (p.has('content')) n.content = p.str('content');
          if (p.has('brief')) n.brief = p.str('brief');
          if (p.has('parent_id')) n.parentId = p.str('parent_id');
          if (p.has('tag')) {
            n.tags = p.strs('tag');
            for (final t in n.tags) {
              tags.putIfAbsent(
                t,
                () => MockTag(id: t, title: t, category: 'note'),
              );
            }
          }
          if (p.has('encrypt')) n.encrypt = p.b('encrypt');
          if (p.has('source_url')) {
            final s = p.str('source_url');
            n.sourceUrl = s.isEmpty ? null : s;
          }
          if (p.has('latitude')) n.latitude = _doubleOrNull(p.j('latitude'));
          if (p.has('longitude')) n.longitude = _doubleOrNull(p.j('longitude'));
          if (p.has('location')) n.location = p.str('location');
          // C7：附件增删（`attachment: [{action, name, file_id, ref, …}]`）
          final atts = p.j('attachment');
          if (atts is List) {
            for (final raw in atts) {
              if (raw is! Map) continue;
              final action = '${raw['action'] ?? 'create'}';
              final fileId = '${raw['file_id'] ?? raw['name'] ?? ''}';
              if (fileId.isEmpty) continue;
              if (action == 'delete') {
                n.attachments.remove(fileId);
              } else {
                n.attachments[fileId] = {
                  'file_id': fileId,
                  'name': '${raw['name'] ?? fileId}',
                  'size': 64,
                  'type': 'application/octet-stream',
                  'ref': '${raw['ref'] ?? ''}',
                  'ctime': _now,
                  'mtime': _now,
                };
              }
            }
          }
          n.mtime = p.i('mtime', _now);
          // 每次写都推进 ver（乐观锁语义：客户端必须回传上次拿到的 ver）
          n.ver = _bumpVersion(n.ver);
          versions.putIfAbsent(id, () => []).insert(0, {
            'id': 'v-${versions[id]!.length + 1}',
            'version': n.ver,
            'author': 'mock',
            'mtime': n.mtime,
            'commit_msg': 'Flutter',
            'last_version': true,
          });
          data.add(n.toJson());
        }
        return _ok({'data': data, 'errors': errors});
      case 'delete':
        final recycle = p.b('recycle', true);
        for (final id in p.strs('object_id')) {
          final n = notes[id];
          if (n == null) continue;
          if (recycle) {
            n.recycle = true;
          } else {
            notes.remove(id);
            versions.remove(id);
          }
        }
        return _ok({});
      case 'restore':
        for (final id in p.strs('object_id')) {
          notes[id]?.recycle = false;
        }
        return _ok({});
      case 'copy':
        final src = notes[p.str('object_id')];
        if (src == null) return _err(408);
        final id = _next('n');
        final now = _now;
        final copy = MockNote(
          id: id,
          title: p.has('title') && p.str('title').isNotEmpty
              ? p.str('title')
              : '${src.title} (副本)',
          parentId: p.has('parent_id') ? p.str('parent_id') : src.parentId,
          content: p.has('content') ? p.str('content') : src.content,
          brief: src.brief,
          ctime: now,
          mtime: now,
          encrypt: p.has('encrypt') ? p.b('encrypt') : src.encrypt,
          tags: [...src.tags],
        );
        notes[id] = copy;
        versions[id] = [
          {
            'id': 'v-1',
            'version': copy.ver,
            'author': 'mock',
            'mtime': now,
            'commit_msg': 'Flutter',
            'last_version': true,
          },
        ];
        return _ok({'object_id': id});
      case 'get_attachment_text':
        final n = notes[p.str('object_id')];
        final fid = p.str('file_id');
        final att = n?.attachments[fid];
        return _ok({
          'text': att == null ? '' : 'mock attachment text for ${att['name']}',
        });
      case 'restore_version':
        return _ok({});
    }
    return _err(103);
  }

  String _bumpVersion(String ver) {
    final major = int.tryParse(ver.split('.').first) ?? 1;
    return '${major + 1}.0';
  }

  double? _doubleOrNull(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse('$v');
  }

  /// `Note.Polling`：`<op>` 起任务 → `<op>_status` 回 `finish` → `<op>_stop`。
  ///
  /// mock 里任务**同步完成**：起任务时就落状态，`*_status` 直接回
  /// `{finish:true, success:true, data:[noteVo…]}`（`_runPolling` 的终态形状）。
  Map<String, dynamic> _notePolling(String method, MockParams p) {
    if (method == 'set' || method == 'create') {
      final delegate = method == 'set' ? _note('set', p) : _note('create', p);
      if (delegate['success'] != true) return delegate;
      final data = method == 'set'
          ? ((delegate['data'] as Map)['data'] as List)
          : [_note('get', p)['data']];
      final taskId = _next('nptask');
      _pollingPayloads[taskId] = data;
      return _ok({'task_id': taskId});
    }
    if (method == 'copy') {
      final res = _note('copy', p);
      if (res['success'] != true) return res;
      final taskId = _next('nptask');
      _pollingPayloads[taskId] = [
        _note('get', MockParams({'object_id': '"${(res['data'] as Map)['object_id']}"'}))['data'],
      ];
      return _ok({'task_id': taskId});
    }
    if (method.endsWith('_status')) {
      final taskId = p.str('task_id');
      final data = _pollingPayloads[taskId];
      if (data == null) {
        return _ok({'finish': true, 'success': false, 'error': {'code': 408}});
      }
      return _ok({'finish': true, 'success': true, 'data': data});
    }
    if (method.endsWith('_stop')) return _ok({});
    return _err(103);
  }

  final Map<String, List<dynamic>> _pollingPayloads = {};

  Map<String, dynamic> _noteVersion(String method, MockParams p) {    switch (method) {
      case 'list':
        final id = p.str('object_id');
        final list = versions[id] ?? const <Map<String, dynamic>>[];
        return _ok({
          'versions': list,
          'count': list.length,
          'offset': 0,
          'total': list.length,
        });
      case 'restore':
        final id = p.str('object_id');
        final n = notes[id];
        if (n == null) return _err(408);
        n.ver = p.str('ver', n.ver);
        return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _tag(String method, MockParams p) {
    switch (method) {
      case 'list':
        final list = tags.values.map((t) {
          final ids = notes.values
              .where((n) => !n.recycle && n.tags.contains(t.id))
              .map((n) => n.id)
              .toList();
          return t.toJson(ids);
        }).toList();
        return _ok({'tags': list, 'total': list.length});
      case 'set':
        final t = tags[p.str('tag_id')];
        if (t == null) return _err(101);
        t.title = p.str('title');
        return _ok({});
      case 'delete':
        tags.remove(p.str('tag_id'));
        return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _todo(String method, MockParams p) {
    switch (method) {
      case 'list':
        final f = p.j('filter');
        final wantDone = f is Map ? f['done'] : null;
        final list = todos.values
            .where((t) => wantDone == null || t.done == (wantDone == true))
            .map((t) => t.toJson())
            .toList();
        return _ok({
          'todos': list,
          'count': list.length,
          'offset': 0,
          'total': list.length,
        });
      case 'list_timeout':
        // 超时（截止日期已过且未完成）
        final now = _now;
        final list = todos.values
            .where((t) => !t.done && t.dueDate > 0 && t.dueDate < now)
            .map((t) => t.toJson())
            .toList();
        return _ok({
          'todos': list,
          'count': list.length,
          'offset': 0,
          'total': list.length,
        });
      case 'create':
        final id = _next('t');
        final parentId = p.str('parent_id');
        final t = MockTodo(
          id: id,
          title: p.str('title'),
          done: p.b('done'),
          dueDate: p.i('due_date', -1),
          priority: p.i('priority', -1),
          reminderOffset: p.i('reminder_offset'),
          noteId: p.str('note_id'),
          comment: p.str('comment'),
          star: p.b('star'),
          parentId: parentId,
        );
        todos[id] = t;
        return _ok(t.toJson());
      case 'set':
        for (final id in p.strs('object_id')) {
          final t = todos[id];
          if (t == null) continue;
          if (p.has('title')) t.title = p.str('title');
          if (p.has('done')) t.done = p.b('done');
          if (p.has('star')) t.star = p.b('star');
          if (p.has('comment')) t.comment = p.str('comment');
          if (p.has('priority')) t.priority = p.i('priority', -1);
          if (p.has('due_date')) t.dueDate = p.i('due_date', -1);
          if (p.has('reminder_offset')) {
            t.reminderOffset = p.i('reminder_offset');
          }
          if (p.has('note_id')) t.noteId = p.str('note_id');
          if (p.has('parent_id')) t.parentId = p.str('parent_id');
        }
        return _ok({});
      case 'delete':
        for (final id in p.strs('object_id')) {
          todos.remove(id);
        }
        return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _shortcut(String method, MockParams p) {
    switch (method) {
      case 'list':
        return _ok({
          'shortcuts': shortcuts,
          'offset': 0,
          'total': shortcuts.length,
        });
      case 'set':
        final objectId = p.has('object_id') ? p.str('object_id') : '';
        final tagId = p.has('tag_id') ? p.str('tag_id') : '';
        final title = objectId.isNotEmpty
            ? (notes[objectId]?.title ?? '')
            : (tags[tagId]?.title ?? '');
        shortcuts.add({
          'id': _next('sc'),
          'category': objectId.isNotEmpty ? 'note' : 'tag',
          'title': title,
          'items': [if (objectId.isNotEmpty) objectId else tagId],
          'owner': {'name': 'mock'},
        });
        return _ok({});
      case 'delete':
        final objectId = p.has('object_id') ? p.str('object_id') : '';
        final tagId = p.has('tag_id') ? p.str('tag_id') : '';
        final target = objectId.isNotEmpty ? objectId : tagId;
        shortcuts.removeWhere(
          (s) => (s['items'] as List).any((e) => '$e' == target),
        );
        return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _fts(String method, MockParams p) {
    final kw = p.str('keyword').toLowerCase();
    final list = notes.values
        .where(
          (n) =>
              !n.recycle &&
              (kw.isEmpty ||
                  n.title.toLowerCase().contains(kw) ||
                  n.content.toLowerCase().contains(kw)),
        )
        .map((n) => n.toJson(withContent: false))
        .toList();
    return _ok({'matches': list, 'offset': 0, 'total': list.length});
  }

  Map<String, dynamic> _noteInfo(String method, MockParams p) {
    switch (method) {
      case 'get':
        return _ok({
          'username': 'mock',
          'uid': 1000,
          'is_admin': false,
          'hash': 'MOCKHASH',
          'version': '2.6.10',
          'allow_share': true,
          'search_precisely': false,
        });
      case 'setting':
        return _ok({'search_attachment': searchAttachmentEnabled['enabled']});
    }
    return _err(103);
  }

  /// 导出 / 导入的 `start` / `status` / `stop`（mock 同步完成）。
  Map<String, dynamic> _noteTransfer(String api, String method, MockParams p) {
    switch (method) {
      case 'start':
        return _ok({'task_id': _next('ntx')});
      case 'status':
        if (api == 'SYNO.NoteStation.Export.Note') {
          return _ok({
            'task_id': p.str('task_id'),
            'finish': true,
            'filename': 'mock-export.nsx',
          });
        }
        return _ok({
          'finish': true,
          'success': true,
          'data': {
            'current': 1,
            'total': 1,
            'finish_time': _now,
          },
        });
      case 'stop':
        return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _noteSetting(String method, MockParams p) {
    if (method == 'get') {
      return _ok({'search_attachment': searchAttachmentEnabled['enabled']});
    }
    if (method == 'set') {
      if (p.has('search_attachment')) {
        searchAttachmentEnabled['enabled'] = p.b('search_attachment');
      }
      return _ok({});
    }
    return _err(103);
  }

  // ============================================================ 文件

  Map<String, dynamic> _entry(MockFsNode n) => {
    'name': n.name,
    'path': n.path,
    'isdir': n.isDir,
    'additional': {
      'size': n.isDir ? 4096 : n.size,
      'time': {'mtime': n.mtime, 'crtime': n.mtime, 'atime': n.mtime, 'ctime': n.mtime},
      'owner': {'user': 'mock', 'group': 'users'},
      'perm': {'posix': n.isDir ? 755 : 644, 'is_acl_mode': false},
    },
  };

  List<MockFsNode> _children(String folder, {bool recursive = false}) {
    final prefix = folder == '/' ? '/' : '$folder/';
    return fs.values
        .where((n) {
          if (!n.path.startsWith(prefix) || n.path == folder) return false;
          final rel = n.path.substring(prefix.length);
          return recursive || !rel.contains('/');
        })
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Map<String, dynamic> _fsList(String method, MockParams p) {
    if (method == 'list_share') {
      final shares = [fs['/home'], fs['/mock-share']]
          .whereType<MockFsNode>()
          .map(_entry)
          .toList();
      return _ok({'shares': shares, 'total': shares.length, 'offset': 0});
    }
    if (method == 'getinfo') {
      final path = p.str('path');
      final n = fs[path];
      if (n == null) {
        // 旧 mock 对未知路径也回一条（合成媒体大小），保持宽容
        final name = path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;
        return _ok({
          'files': [
            {
              'name': name,
              'path': path,
              'isdir': !name.contains('.'),
              'additional': {
                'size': mediaSize,
                'time': {'mtime': _now},
                'owner': {'user': 'mock', 'group': 'users'},
                'perm': {'posix': 644, 'is_acl_mode': false},
              },
            },
          ],
        });
      }
      return _ok({'files': [_entry(n)]});
    }
    // method == 'list'
    final folder = p.str('folder_path', '/home');
    final all = _children(folder);
    final limit = p.i('limit');
    final offset = p.i('offset');
    final sliced = limit > 0
        ? all.skip(offset).take(limit).toList()
        : all.skip(offset).toList();
    return _ok({
      'files': sliced.map(_entry).toList(),
      'total': all.length,
      'offset': offset,
    });
  }

  Map<String, dynamic> _fsDelete(String method, MockParams p) {
    if (method == 'start') {
      // 真机语义：`Delete/start` = **进回收站**（`/<share>/#recycle/…`）
      for (final path in p.strs('path')) {
        _moveIntoRecycle(path);
      }
      return _ok({'taskid': _next('fstask')});
    }
    if (method == 'delete') {
      // `Delete/delete` = **永久删除**（回收站内条目用）
      for (final path in p.strs('path')) {
        _removeRecursive(path);
      }
      return _ok({});
    }
    return _err(103);
  }

  /// 把一条路径（含子树）搬到所属共享根的 `#recycle` 下。
  void _moveIntoRecycle(String path) {
    final node = fs[path];
    if (node == null) return;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return;
    final recycleDir = '/${segments.first}/#recycle';
    fs.putIfAbsent(
      recycleDir,
      () => MockFsNode(path: recycleDir, isDir: true, mtime: _now),
    );
    fs.putIfAbsent(
      '/${segments.first}/#recycle/@eaDir',
      () => MockFsNode(
        path: '/${segments.first}/#recycle/@eaDir',
        isDir: true,
        mtime: _now,
      ),
    );
    final newPath = '$recycleDir/${node.name}';
    final oldPrefix = '${node.path}/';
    final moves = <String, MockFsNode>{};
    for (final k in fs.keys.toList()) {
      if (k.startsWith(oldPrefix)) {
        moves['$newPath/${k.substring(oldPrefix.length)}'] = MockFsNode(
          path: '$newPath/${k.substring(oldPrefix.length)}',
          isDir: fs[k]!.isDir,
          size: fs[k]!.size,
          mtime: fs[k]!.mtime,
        );
        fs.remove(k);
      }
    }
    fs.remove(node.path);
    node.path = newPath;
    fs[newPath] = node;
    fs.addAll(moves);
  }

  void _removeRecursive(String path) {
    fs.remove(path);
    final prefix = '$path/';
    fs.removeWhere((k, _) => k.startsWith(prefix));
  }

  Map<String, dynamic> _fsCopyMove(String method, MockParams p) {
    if (method != 'start') return _err(103);
    final dest = p.str('dest_folder_path');
    if (!fs.containsKey(dest) || !(fs[dest]!.isDir)) return _err(408);
    final removeSrc = p.b('remove_src');
    for (final path in p.strs('path')) {
      final node = fs[path];
      if (node == null) continue;
      final targets = [node, ..._children(path, recursive: true)];
      for (final t in targets) {
        final rel = t.path.substring(path.length);
        final newPath = '$dest/${node.name}$rel';
        fs[newPath] = MockFsNode(
          path: newPath,
          isDir: t.isDir,
          size: t.size,
          mtime: t.mtime,
        );
      }
      if (removeSrc) _removeRecursive(path);
    }
    return _ok({'taskid': _next('fstask')});
  }

  Map<String, dynamic> _fsCreateFolder(String method, MockParams p) {
    if (method != 'create') return _err(103);
    final folderPath = p.str('folder_path');
    final names = p.strs('name');
    if (folderPath.isEmpty || names.isEmpty) return _err(114);
    if (!fs.containsKey(folderPath)) return _err(408);
    final created = <Map<String, dynamic>>[];
    for (final name in names) {
      final path = '$folderPath/$name';
      final node = MockFsNode(path: path, isDir: true, mtime: _now);
      fs[path] = node;
      created.add(_entry(node));
    }
    return _ok({'folders': created});
  }

  Map<String, dynamic> _fsRename(String method, MockParams p) {
    if (method != 'rename') return _err(103);
    final paths = p.strs('path');
    final names = p.strs('name');
    for (var i = 0; i < paths.length && i < names.length; i++) {
      final node = fs[paths[i]];
      if (node == null) continue;
      final parent = node.parent;
      final newPath = parent == '/' ? '/${names[i]}' : '$parent/${names[i]}';
      // 连带改名子节点
      final oldPrefix = '${node.path}/';
      final moves = <String, MockFsNode>{};
      for (final k in fs.keys.toList()) {
        if (k == node.path) continue;
        if (k.startsWith(oldPrefix)) {
          final moved = MockFsNode(
            path: '$newPath/${k.substring(oldPrefix.length)}',
            isDir: fs[k]!.isDir,
            size: fs[k]!.size,
            mtime: fs[k]!.mtime,
          );
          moves[moved.path] = moved;
          fs.remove(k);
        }
      }
      fs.remove(node.path);
      node.path = newPath;
      fs[newPath] = node;
      fs.addAll(moves);
    }
    return _ok({});
  }

  Map<String, dynamic> _fsCheckExist(String method, MockParams p) {
    return _ok({
      'files': [
        for (final path in p.strs('path')) {'path': path, 'exist': fs.containsKey(path)},
      ],
    });
  }

  Map<String, dynamic> _fsBackgroundTask(String method, MockParams p) {
    // mock 的文件任务同步完成 —— 列表恒为空，任务已即时生效。
    return _ok({'tasks': <dynamic>[], 'total': 0, 'offset': 0});
  }

  // ============================================================ 下载

  Map<String, dynamic> _dsTask(String method, MockParams p) {
    switch (method) {
      case 'list':
        var list = downloadTasks.values.toList();
        if (p.has('status')) {
          final statuses = p.ints('status').toSet();
          if (statuses.isNotEmpty) {
            list = list.where((t) => statuses.contains(t.status)).toList();
          }
        }
        if (p.has('keyword')) {
          final kw = p.str('keyword').toLowerCase();
          list = list
              .where((t) => t.title.toLowerCase().contains(kw))
              .toList();
        }
        if (p.has('sort_by')) {
          final by = p.str('sort_by');
          final desc = p.str('order', 'asc') == 'desc';
          list.sort((a, b) {
            final cmp = switch (by) {
              'title' => a.title.compareTo(b.title),
              'size' => a.size.compareTo(b.size),
              'status' => a.status.compareTo(b.status),
              _ => a.createdTime.compareTo(b.createdTime),
            };
            return desc ? -cmp : cmp;
          });
        } else {
          list.sort((a, b) => a.createdTime.compareTo(b.createdTime));
        }
        final total = list.length;
        final offset = p.i('offset');
        final limit = p.i('limit', total);
        final sliced = limit > 0
            ? list.skip(offset).take(limit).toList()
            : list.skip(offset).toList();
        return _ok({
          'task': sliced.map((t) => t.toJson()).toList(),
          'total': total,
        });
      case 'get':
        final ids = p.strs('id');
        final list = ids
            .map((id) => downloadTasks[id])
            .whereType<MockDownloadTask>()
            .map((t) => t.toJson())
            .toList();
        return _ok({'task': list, 'total': list.length});
      case 'create':
        return _dsCreate(p);
      case 'pause':
        _setStatus(p.strs('id'), 3);
        return _ok({});
      case 'resume':
        _setStatus(p.strs('id'), 2);
        return _ok({});
      case 'pause_condition':
        for (final t in downloadTasks.values) {
          if (t.type != 'emule') t.status = 3;
        }
        return _ok({});
      case 'resume_condition':
        for (final t in downloadTasks.values) {
          if (t.type != 'emule' && t.status == 3) t.status = 2;
        }
        return _ok({});
      case 'delete':
        for (final id in p.strs('id')) {
          downloadTasks.remove(id);
          captchaTaskIds.remove(id);
        }
        return _ok({});
      case 'delete_condition':
        final statuses = p.ints('status').toSet();
        downloadTasks.removeWhere((id, t) {
          if (t.type == 'emule') return false;
          final match = statuses.isEmpty || statuses.contains(t.status);
          if (match) captchaTaskIds.remove(id);
          return match;
        });
        return _ok({});
      case 'edit':
        final ids = p.strs('id');
        if (ids.isEmpty) return _err(114);
        if (!p.has('destination') && !p.has('priority')) return _err(114);
        for (final id in ids) {
          final t = downloadTasks[id];
          if (t == null) continue;
          if (p.has('destination')) t.destination = p.str('destination');
          if (p.has('priority')) t.priority = p.str('priority');
          if (p.has('extract_password')) {
            t.extractPassword = p.str('extract_password');
          }
        }
        return _ok({});
    }
    return _err(103);
  }

  void _setStatus(List<String> ids, int status) {
    for (final id in ids) {
      final t = downloadTasks[id];
      if (t != null) t.status = status;
    }
  }

  Map<String, dynamic> _dsCreate(MockParams p) {
    final type = p.str('type'); // 'url' | 'file'（Gson 串已解）
    final kind = type == 'file'
        ? (p.strs('file').firstOrNull ?? 'bt')
        : _kindOf(p.strs('url').firstOrNull ?? '');
    final urls = p.strs('url');
    final dest = p.str('destination', '/volume1/downloads');
    final created = <String>[];
    if (urls.isEmpty) return _err(114);
    for (final u in urls) {
      final id = _next('ds');
      downloadTasks[id] = MockDownloadTask(
        id: id,
        title: _titleOf(u),
        type: kind,
        status: 2,
        size: 1024,
        destination: dest,
        uri: u,
        extractPassword: p.str('extract_password'),
        username: Uri.decodeComponent(p.str('username')),
        password: Uri.decodeComponent(p.str('password')),
      )..createdTime = _now;
      created.add(id);
    }
    // `type=file` 时字段 `file` 是「文件在哪个 multipart 字段」，用它当类型线索
    if (type == 'file') {
      final f = p.strs('file').firstOrNull ?? 'torrent';
      final id = created.first;
      downloadTasks[id]!.type = f == 'nzb' ? 'nzb' : 'bt';
    }
    final wantsList = p.b('create_list');
    if (wantsList) {
      final listId = _next('dl-list');
      createLists[listId] = created;
      return _ok({'list_id': listId});
    }
    return _ok({});
  }

  String _kindOf(String url) {
    final lower = url.toLowerCase();
    if (lower.startsWith('magnet:') || lower.startsWith('ed2k://')) return 'bt';
    return 'http';
  }

  String _titleOf(String url) {
    final clean = Uri.tryParse(url)?.pathSegments.lastOrNull ?? url;
    return clean.isEmpty ? url : clean;
  }

  Map<String, dynamic> _dsStatistic(String method, MockParams p) {
    if (method != 'get') return _err(103);
    var down = 0;
    var up = 0;
    for (final t in downloadTasks.values) {
      down += t.speedDownload;
      up += t.speedUpload;
    }
    return _ok({'download_rate': down, 'upload_rate': up});
  }

  Map<String, dynamic> _dsBt(String method, MockParams p) {
    // `get` 发标量、`set` 发**数组**（官方 `task_id:[id]`）—— 两种都收。
    final id = p.strs('task_id').firstOrNull ?? '';
    final t = downloadTasks[id];
    if (t == null) return _err(404);
    if (method == 'get') {
      return _ok({
        'is_active_torrent': t.status != 3,
        'max_upload_rate': t.maxUploadRate,
        'max_download_rate': t.maxDownloadRate,
        'seeding_ratio': t.seedingRatio,
        'seeding_interval': t.seedingInterval,
        'max_peers': t.maxPeers,
        'destination': t.destination,
        'priority': t.priority,
      });
    }
    if (method == 'set') {
      if (p.has('max_upload_rate')) t.maxUploadRate = p.i('max_upload_rate');
      if (p.has('max_download_rate')) {
        t.maxDownloadRate = p.i('max_download_rate');
      }
      if (p.has('seeding_ratio')) t.seedingRatio = p.i('seeding_ratio');
      if (p.has('seeding_interval')) {
        t.seedingInterval = p.i('seeding_interval');
      }
      if (p.has('max_peers')) t.maxPeers = p.i('max_peers');
      if (p.has('destination')) t.destination = p.str('destination');
      if (p.has('priority')) t.priority = p.str('priority');
      return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _dsTracker(String method, MockParams p) {
    if (method != 'list') return _err(103);
    final id = p.str('task_id');
    if (!downloadTasks.containsKey(id)) return _err(404);
    return _ok({
      'items': [
        {
          'id': 'tr-1',
          'url': 'https://tracker.example.invalid/announce',
          'status': 0,
          'update_timer': 1800,
          'seeds': 3,
          'peers': 5,
        },
      ],
      'total': 1,
    });
  }

  Map<String, dynamic> _dsPeer(String method, MockParams p) {
    if (method != 'list') return _err(103);
    final id = p.str('task_id');
    if (!downloadTasks.containsKey(id)) return _err(404);
    return _ok({
      'items': [
        {
          'ip': '10.0.0.9',
          'client': 'mock-agent/1.0',
          'progress': 0.5,
          'speed_download': 128,
          'speed_upload': 16,
        },
      ],
      'total': 1,
    });
  }

  Map<String, dynamic> _dsFile(String method, MockParams p) {
    if (method == 'list') {
      final id = p.str('task_id');
      if (!downloadTasks.containsKey(id)) return _err(404);
      return _ok({
        'items': [
          {'index': 0, 'name': 'mock.bin', 'size': 1024, 'size_downloaded': 512, 'priority': 'normal', 'wanted': true},
          {'index': 1, 'name': 'readme.txt', 'size': 64, 'size_downloaded': 0, 'priority': 'low', 'wanted': false},
        ],
        'total': 2,
      });
    }
    if (method == 'copy') {
      final id = p.str('task_id');
      if (!downloadTasks.containsKey(id)) return _err(404);
      return _ok({});
    }
    return _err(103);
  }

  /// `Task.List` —— 建任务时 `create_list:true` 得到的可挑选文件列表。
  final Map<String, List<String>> createLists = {};

  Map<String, dynamic> _dsCreateList(String method, MockParams p) {
    final listId = p.str('list_id');
    final ids = createLists[listId];
    if (ids == null) return _err(404);
    switch (method) {
      case 'get':
        return _ok({
          'files': [
            for (var i = 0; i < ids.length; i++)
              {
                'index': i,
                'name': downloadTasks[ids[i]]?.title ?? ids[i],
                'size': downloadTasks[ids[i]]?.size ?? 0,
                'download_url': '',
                'enable': true,
              },
          ],
          'total': ids.length,
        });
      case 'download':
        // 非轮询版：开任务（`destination` 必填 —— 真机 120 就是这个）
        if (!p.has('destination')) return _err(120);
        for (final id in ids) {
          downloadTasks[id]?.status = 2;
        }
        createLists.remove(listId);
        return _ok({});
      case 'delete':
        for (final id in ids) {
          downloadTasks.remove(id);
        }
        createLists.remove(listId);
        return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _dsCaptcha(String method, MockParams p) {
    switch (method) {
      case 'list':
        return _ok({'task_ids': captchaTaskIds});
      case 'set':
        final id = p.str('task_id');
        if (!downloadTasks.containsKey(id)) return _err(404);
        captchaTaskIds.remove(id);
        downloadTasks[id]!.status = 2;
        return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _dsBtSearch(String method, MockParams p) {
    switch (method) {
      case 'start':
        return _ok({'id': _next('bts')});
      case 'list':
        return _ok({
          'results': [
            {
              'result_id': 'r-1',
              'title': 'Mock Search Result',
              'size': 4096,
              'date': _now * 1000,
              'seeds': 10,
              'peers': 2,
              'provider': 'mock-module',
              'dlurl': 'magnet:?xt=urn:btih:MOCK',
              'page': 'https://example.invalid/detail/1',
            },
          ],
          'total': 1,
          'is_running': false,
          'search_done': true,
        });
      case 'stop':
        return _ok({});
      case 'list_category':
        return _ok({
          'categories': ['software', 'movie'],
        });
      case 'list_plugin_status':
        return _ok({'plugins': <dynamic>[], 'can_connect': true});
    }
    return _err(103);
  }

  /// 老一代 `SYNO.DownloadStation.BTSearch`（`DownloadStation/btsearch.cgi`）。
  Map<String, dynamic> _dsBtSearchLegacy(String method, MockParams p) {
    switch (method) {
      case 'start':
        return _ok({'taskid': _next('bts-legacy')});
      case 'list':
        return _ok({
          'finished': true,
          'items': [
            {
              'id': 'legacy-1',
              'title': 'Mock Legacy Result',
              'size': '4096',
              'date': _now,
              'seeds': 5,
              'peers': 1,
              'leechs': 1,
              'module_id': 'mock-module',
              'module_title': 'Mock Module',
              'download_uri': 'magnet:?xt=urn:btih:LEGACY',
              'external_link': 'https://example.invalid/legacy/1',
            },
          ],
          'offset': 0,
          'total': 1,
        });
      case 'getModule':
        return _ok({
          'modules': [
            {'module_id': 'mock-module', 'module_title': 'Mock Module', 'enabled': true},
            {'module_id': 'disabled-module', 'module_title': 'Disabled', 'enabled': false},
          ],
        });
    }
    return _err(103);
  }

  /// `RSS.Item / list {feed_id, offset, limit}` —— 订阅源条目。
  Map<String, dynamic> _dsRssItem(String method, MockParams p) {
    if (method == 'clear') {
      final feedId = p.str('feed_id');
      rssItems.removeWhere((x) => x['feed_id'] == feedId);
      return _ok({});
    }
    if (method != 'list') return _err(103);
    final feedId = p.str('feed_id');
    final all = rssItems.where((x) => feedId.isEmpty || x['feed_id'] == feedId).toList();
    final total = all.length;
    final offset = p.i('offset');
    final limit = p.i('limit');
    final sliced = limit > 0 ? all.skip(offset).take(limit).toList() : all.skip(offset).toList();
    return _ok({'items': sliced, 'total': total});
  }

  Map<String, dynamic> _dsRssFeed(String method, MockParams p) {
    switch (method) {
      case 'update':
      case 'updateall':
        // 真的把 `is_updating` 落回 false（同步完成）
        final ids = p.strs('id');
        for (final key in rssFeeds.keys.toList()) {
          if (method == 'updateall' || ids.contains(key)) {
            rssFeeds[key] = {
              ...rssFeeds[key]!,
              'is_updating': false,
              'last_update': _now,
            };
          }
        }
        return _ok({});
      case 'list':
        return _ok({
          'items': rssFeeds.values.toList(),
          'total': rssFeeds.length,
          'offset': 0,
        });
      case 'add':
        final id = _next('feed');
        rssFeeds[id] = {
          'id': id,
          'title': p.str('title', p.str('url')),
          'url': p.str('url'),
          'enabled': true,
          'item_count': 0,
        };
        return _ok({'id': id});
      case 'set':
        for (final id in p.strs('id')) {
          final f = rssFeeds[id];
          if (f == null) continue;
          if (p.has('title')) f['title'] = p.str('title');
          if (p.has('enabled')) f['enabled'] = p.b('enabled');
        }
        return _ok({});
      case 'delete':
        for (final id in p.strs('id')) {
          rssFeeds.remove(id);
        }
        return _ok({});
    }
    return _err(103);
  }

  // ============================================================ 相册

  Map<String, dynamic> _photoItem(String method, MockParams p) {
    switch (method) {
      case 'list':
        var list = photos.values.toList();
        if (p.has('album_id')) {
          final aid = p.str('album_id');
          list = list.where((x) => x.albumIds.contains(aid)).toList();
        }
        if (p.has('folder_id')) {
          final fid = p.str('folder_id');
          list = list.where((x) => x.folderId == fid).toList();
        }
        if (p.b('favorite')) {
          list = list.where((x) => x.favorite).toList();
        }
        if (p.has('id')) {
          final ids = p.strs('id');
          // 真机教训：`Browse.Item/list` 的 `id` 过滤**不生效** —— mock 保留该行为
          // （给 id 也会把全部照片吐回来），避免测试依赖未取证的服务端语义。
          if (ids.isEmpty) list = [];
        }
        list.sort(
          (a, b) => p.str('sort_direction', 'desc') == 'desc'
              ? b.time.compareTo(a.time)
              : a.time.compareTo(b.time),
        );
        final total = list.length;
        final offset = p.i('offset');
        final limit = p.i('limit');
        final sliced = limit > 0
            ? list.skip(offset).take(limit).toList()
            : list.skip(offset).toList();
        return _ok({
          'list': sliced.map((x) => x.toJson()).toList(),
          'total': total,
        });
      case 'set_favorite':
        final fav = p.b('favorite');
        for (final id in p.strs('id')) {
          photos[id]?.favorite = fav;
        }
        return _ok({});
      case 'delete':
        for (final id in p.strs('id')) {
          photos.remove(id);
        }
        return _ok({'error_list': <dynamic>[]});
      case 'move':
        final target = p.str('target_folder_id');
        for (final id in p.strs('id')) {
          photos[id]?.folderId = target;
        }
        return _ok({'error_list': <dynamic>[]});
      case 'copy':
        final target = p.str('target_folder_id');
        final copies = <dynamic>[];
        for (final id in p.strs('id')) {
          final src = photos[id];
          if (src == null) continue;
          final newId = _next('p');
          photos[newId] = MockPhoto(
            id: newId,
            filename: src.filename,
            filesize: src.filesize,
            time: src.time,
            folderId: target,
            type: src.type,
          );
          copies.add({'id': newId});
        }
        return _ok({'error_list': <dynamic>[], 'list': copies});
      case 'set':
        // 旋转（`rotate_action`）—— 只受理，不改 mock 状态（像素级旋转无意义）
        return _ok({});
    }
    return _err(103);
  }

  /// `Browse.NormalAlbum`：列表 + 加/删成员。
  Map<String, dynamic> _photoNormalAlbum(String method, MockParams p) {
    switch (method) {
      case 'list':
        final list = albums.values.map((a) => a.toJson()).toList();
        return _ok({'list': list, 'total': list.length});
      case 'add_item':
        final a = albums[p.str('id')];
        if (a == null) return _err(404);
        for (final id in p.strs('item')) {
          final photo = photos[id];
          if (photo == null) continue;
          if (!photo.albumIds.contains(a.id)) photo.albumIds.add(a.id);
        }
        a.itemCount = photos.values.where((x) => x.albumIds.contains(a.id)).length;
        return _ok({'error_list': <dynamic>[]});
      case 'delete_item':
        final a = albums[p.str('id')];
        if (a == null) return _err(404);
        for (final id in p.strs('item')) {
          photos[id]?.albumIds.remove(a.id);
        }
        a.itemCount = photos.values.where((x) => x.albumIds.contains(a.id)).length;
        return _ok({'error_list': <dynamic>[]});
    }
    return _err(103);
  }

  Map<String, dynamic> _photoAlbum(String method, MockParams p) {    switch (method) {
      case 'list':
        final list = albums.values.map((a) => a.toJson()).toList();
        return _ok({'list': list, 'total': list.length});
      case 'create':
        final id = _next('a');
        albums[id] = MockAlbum(id: id, name: p.str('name'));
        return _ok({'album': albums[id]!.toJson()});
      case 'set':
        final a = albums[p.str('id')];
        if (a == null) return _err(404);
        if (p.has('name')) a.name = p.str('name');
        return _ok({});
      case 'delete':
        for (final id in p.strs('id')) {
          albums.remove(id);
        }
        return _ok({});
      case 'get_album_list_order':
        return _ok({
          'album_list_sort_by': albumListOrderBy,
          'album_list_sort_direction': albumListOrderDirection,
        });
      case 'set_album_list_order':
        albumListOrderBy = p.str('album_list_sort_by', albumListOrderBy);
        albumListOrderDirection = p.str(
          'album_list_sort_direction',
          albumListOrderDirection,
        );
        return _ok({});
    }
    return _err(103);
  }

  Map<String, dynamic> _photoFolder(String method, MockParams p) {
    switch (method) {
      case 'list':
        final parent = p.str('id', '0');
        final list = folders.values
            .where((f) => f.parentId == parent)
            .map((f) => f.toJson())
            .toList();
        return _ok({'list': list, 'total': list.length});
      case 'get':
        final root = folders['10']!;
        return _ok({'folder': root.toJson()});
      case 'create':
        final id = _next('f');
        final target = p.str('target_id');
        if (target == '0') return _err(120);
        folders[id] = MockFolder(id: id, name: p.str('name'), parentId: target);
        return _ok({'folder': folders[id]!.toJson()});
      case 'rename':
        final f = folders[p.str('id')];
        if (f == null) return _err(404);
        f.name = p.str('name');
        return _ok({'folder': f.toJson()});
      case 'delete':
        for (final id in p.strs('id')) {
          folders.remove(id);
        }
        return _ok({});
    }
    return _err(103);
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
