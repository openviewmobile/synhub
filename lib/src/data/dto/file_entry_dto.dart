// File Station 的文件条目 / 任务 / 分享链接 VO。
//
// 反编译出处（字段名逐一对照）：
//   * `com/synology/DSfile/vos/Share.java` —— 列表项与 `additional`
//   * `com/synology/DSfile/vos/TaskListVo.java` —— `BackgroundTask.list`
//   * `com/synology/DSfile/vos/ShareLink.java` / `ShareLinksVo.java` —— `Sharing.list`
// 服务端权威方法表：docs/api-server-authoritative.md §2（FileStation 1.5.1-2410）。
//
// ⚠️ `additional` 是「按需下发」的：请求里没要的字段服务端就不给，
//    所以这里全部按可空/默认值处理，不要假定一定有。
import '../../core/i18n/data_text.dart';
import '../../core/json_coerce.dart';
import 'file_mount_dto.dart' show FileWormState;
import 'file_prop_dto.dart' show kImageExtensions;

/// 排序键（`sort_by`）。取值来自官方 APK 的调用点（`WebApiConnectionManager`）。
enum FileSortBy {
  name('name'),
  size('size'),
  mtime('mtime'),
  user('user'),
  group('group'),
  type('type'),
  crtime('crtime');

  const FileSortBy(this.value);
  final String value;
}

/// 排序方向（`sort_direction`）
enum FileSortDirection {
  asc('asc'),
  desc('desc');

  const FileSortDirection(this.value);
  final String value;
}

/// 列表里要服务端附带哪些 `additional` 字段。
///
/// 服务端 `SYNO.FileStation.List.so` 里能抠出这些键：
/// `size real_path owner time perm mount_point_type volume_status indexed
/// hybrid_share worm_share description`。
abstract final class FileAdditional {
  static const String size = 'size';
  static const String realPath = 'real_path';
  static const String owner = 'owner';
  static const String time = 'time';
  static const String perm = 'perm';
  static const String mountPointType = 'mount_point_type';
  static const String volumeStatus = 'volume_status';
  static const String indexed = 'indexed';
  static const String hybridShare = 'hybrid_share';
  static const String wormShare = 'worm_share';
  static const String description = 'description';

  /// 浏览目录时的默认集合 —— 照抄官方 `getFiles` 调用点
  static const List<String> browse = [
    size,
    time,
    mountPointType,
    wormShare,
    owner,
    perm,
  ];

  /// 收藏 / 虚拟目录（官方那两处只要 real_path + time）
  static const List<String> light = [realPath, time];
}

/// 一个文件或文件夹（`List.list` / `list_share` / `getinfo` 的条目）。
class FileEntryDto {
  const FileEntryDto({
    required this.name,
    required this.path,
    this.isDir = false,
    this.status,
    this.code = 0,
    this.size = 0,
    this.mtime = 0,
    this.crtime = 0,
    this.atime = 0,
    this.ctime = 0,
    this.owner,
    this.group,
    this.uid = 0,
    this.gid = 0,
    this.realPath,
    this.mountPointType,
    this.volumeStatus,
    this.isWormShare = false,
    this.wormState,
    this.description,
    this.canRead = false,
    this.canWrite = false,
    this.canExecute = false,
    this.disableDownload = false,
    bool? permKnown,
  }) : _permKnown = permKnown;

  final String name;
  final String path;
  final bool isDir;

  /// 共享文件的状态（`status`），`code` 非 0 时说明这个挂载点不可用
  final String? status;
  final int code;

  final int size;
  final int mtime;
  final int crtime;
  final int atime;
  final int ctime;

  final String? owner;
  final String? group;
  final int uid;
  final int gid;

  final String? realPath;

  /// `shared_folder` / `external` / ... —— 官方用它区分「共享文件夹根」
  final String? mountPointType;
  final String? volumeStatus;

  final bool isWormShare;
  final String? wormState;
  final String? description;

  final bool canRead;
  final bool canWrite;
  final bool canExecute;

  /// `perm.adv_right.disable_download` —— 管理员禁掉了下载
  final bool disableDownload;

  /// `additional.perm.acl` 到位了没有。
  ///
  /// `canWrite` 缺省是 `false`，**缺权限数据时不能当成"只读"**（老服务器 /
  /// 只请求了 `light` additional 时根本没有 `perm`）——所以只读角标要同时看
  /// 这一位，见 [isReadOnly]。
  /// 显式传入的"权限数据是否到位"；为 `null` 时按 [permKnown] 的兜底规则推导。
  final bool? _permKnown;

  /// 权限数据（`additional.perm.acl`）到位了没有。
  ///
  /// 两条来源：
  ///   * 内存里（[FileEntryDto.fromJson]）直接看 `acl` 是否存在 —— 显式传入；
  ///   * **从本地缓存表还原**时没有这一列（`database.dart:184-214` 只存了
  ///     `canRead/canWrite/canExecute`），所以兜底规则是"三个 acl 位全为
  ///     false 就当没有权限数据"。服务端只要给了 `acl`，`read` 基本恒为
  ///     true，因此三个全 false 只会是"这次没请求 perm"。
  bool get permKnown => _permKnown ?? (canRead || canWrite || canExecute);

  /// WORM 状态码（`additional.worm_state`，线上是 0..9 的下标）。
  /// 没开 WriteOnce 的共享不给这个字段 → `null`。
  int? get wormStateCode {
    final raw = wormState;
    if (raw == null || raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  /// 官方 `WormVo.Worm.State.isLocked()`：锁定的文件**不许删除/改名/移动**。
  ///
  /// 证据：`ResourceListFragment.java:2657-2682 getBasicFileActions()` —— 锁定态
  /// （IMMUTABLE_LOCKED / APPENDABLE_LOCKED / WEAK_*_LOCKED）只保留 COPY；
  /// 过期态（EXPIRED_*）才恢复 DELETE/RENAME。
  bool get wormLocked {
    final code = wormStateCode;
    // 线上是 0..9 下标，先翻译成 `WormVo.State.value` 位掩码再判 `& 32`
    return code != null &&
        FileWormState.isLocked(FileWormState.normalize(code));
  }

  /// 只读（有权限数据 + 不可写）。用于列表角标（审计 P1-11）。
  bool get isReadOnly => permKnown && !canWrite;

  /// 扩展名（小写，不含点）
  String get extension {
    final i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return '';
    return name.substring(i + 1).toLowerCase();
  }

  /// 图片（用聊天那边的白名单，保持一致）
  bool get showsThumbnail => !isDir && kImageExtensions.contains(extension);

  /// 挂载点（共享文件夹 / 外接设备）根目录
  bool get isMountPoint => mountPointType != null && mountPointType!.isNotEmpty;

  /// 人类可读大小
  String get humanSize => formatSize(size);

  /// `2026-09-18 10:50` 这种时间戳（`mtime` 是**秒**）
  DateTime? get modifiedAt =>
      mtime > 0 ? DateTime.fromMillisecondsSinceEpoch(mtime * 1000) : null;

  factory FileEntryDto.fromJson(Map<String, dynamic> json) {
    final additional = json['additional'] is Map
        ? Map<String, dynamic>.from(json['additional'] as Map)
        : const <String, dynamic>{};
    final time = additional['time'] is Map
        ? Map<String, dynamic>.from(additional['time'] as Map)
        : const <String, dynamic>{};
    final owner = additional['owner'] is Map
        ? Map<String, dynamic>.from(additional['owner'] as Map)
        : const <String, dynamic>{};
    // perm 真机给的是 `{posix: 644, is_acl_mode: false, acl: {...}, adv_right: {...}}`
    final perm = additional['perm'] is Map
        ? Map<String, dynamic>.from(additional['perm'] as Map)
        : const <String, dynamic>{};
    final acl = perm['acl'] is Map
        ? Map<String, dynamic>.from(perm['acl'] as Map)
        : const <String, dynamic>{};
    final adv = perm['adv_right'] is Map
        ? Map<String, dynamic>.from(perm['adv_right'] as Map)
        : const <String, dynamic>{};

    return FileEntryDto(
      name: '${json['name'] ?? ''}',
      path: '${json['path'] ?? ''}',
      // `Extract.list`（归档内容清单）用的是 `is_dir`，其它接口是 `isdir`
      isDir: json['isdir'] == true || json['is_dir'] == true,
      status: json['status'] == null ? null : '${json['status']}',
      code: _int(json['code']),
      // 归档条目把 size/mtime 放在**顶层**（`pack_size` 是压缩后大小），
      // 所以这里要回退读顶层，不能只看 additional。
      size: additional['size'] != null
          ? _int(additional['size'])
          : _int(json['size']),
      mtime: time['mtime'] != null
          ? _int(time['mtime'])
          : _parseTime(json['mtime']),
      crtime: _int(time['crtime']),
      atime: _int(time['atime']),
      ctime: _int(time['ctime']),
      owner: owner['user'] == null ? null : '${owner['user']}',
      group: owner['group'] == null ? null : '${owner['group']}',
      uid: _int(owner['uid']),
      gid: _int(owner['gid']),
      realPath: additional['real_path'] == null
          ? null
          : '${additional['real_path']}',
      mountPointType: additional['mount_point_type'] == null
          ? null
          : '${additional['mount_point_type']}',
      volumeStatus: additional['volume_status'] == null
          ? null
          : '${additional['volume_status']}',
      isWormShare: additional['is_worm_share'] == true,
      wormState: additional['worm_state'] == null
          ? null
          : '${additional['worm_state']}',
      description: additional['description'] == null
          ? null
          : '${additional['description']}',
      canRead: acl['read'] == true,
      canWrite: acl['write'] == true,
      canExecute: acl['exec'] == true,
      disableDownload: adv['disable_download'] == true,
      permKnown: perm['acl'] is Map,
    );
  }

  /// 下载用的路径列表（`path` 参数要的是 JSON 数组串）
  static String encodePaths(List<String> paths) =>
      '[${paths.map((p) => '"${_escapeJson(p)}"').join(',')}]';

  static String _escapeJson(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  /// 秒时间戳（`List.list`）或 `"2026-09-18 13:16:20"`（`Extract.list`）→ 秒。
  ///
  /// 字符串那个是**服务端本地时间**，没有时区信息，按本地时间解析（与 DSM
  /// 网页显示一致）；只有归档清单会走到这条路。
  static int _parseTime(Object? raw) {
    if (raw is int) return raw;
    if (raw is String && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
      if (parsed != null) {
        return parsed.millisecondsSinceEpoch ~/ 1000;
      }
    }
    return 0;
  }
}

/// `#recycle` 回收站路径判定（P0-2）。
///
/// 证据：
/// * 官方 DS file `util/Common.java:75` `RECYCLE_BIN_TITLE = "#recycle"`；
/// * 官方前端 `ui/file_browser/RecycleBin.js`
///   `isInRecycleBinFolder`：`p.split("/")` 后第 2 段（`/share/#recycle`）或
///   home 型共享的第 3 段（`/home/user/#recycle`）是 `#recycle`；
///   `getShare`/还原目标都从同一套分段推出来。
///
/// 这里把分段规则集中一处，UI 与动作控制器共用，避免两边各写一套。
abstract final class RecyclePath {
  static const String segment = '#recycle';

  /// 路径里有没有 `#recycle` 这一段
  static bool isInRecycleBin(String path) {
    if (path.isEmpty) return false;
    return _segments(path).contains(segment);
  }

  /// `/share/#recycle` 这种"回收站根"
  static bool isRecycleRoot(String path) {
    if (path.isEmpty) return false;
    final segs = _segments(path);
    return segs.isNotEmpty && segs.last == segment;
  }

  /// 回收站所属的共享文件夹名；不在回收站里返回 null。
  static String? shareOf(String path) {
    final segs = _segments(path);
    final i = segs.indexOf(segment);
    if (i < 1) return null;
    return segs[i - 1];
  }

  /// 还原目标目录：**先去掉文件名、再去掉 `#recycle` 这一段**
  /// （`RecycleBin.js` 的 `doRestore`：`i.pop()` 后 `splice(indexOf('#recycle'),1)`）。
  ///
  /// `/share/#recycle/a.txt` → `/share`；`/share/#recycle/dir/a.txt` → `/share/dir`。
  static String restoreDest(String path) {
    final segs = _segments(path);
    final i = segs.indexOf(segment);
    if (i < 0) return path;
    segs.removeAt(i);
    if (segs.isNotEmpty) segs.removeLast(); // 去掉被还原条目的文件名
    return segs.isEmpty ? '/' : '/${segs.join('/')}';
  }

  /// 该路径所属的 `#recycle` 根（`/share/#recycle/dir` → `/share/#recycle`）。
  static String? rootOf(String path) {
    final segs = _segments(path);
    final i = segs.indexOf(segment);
    if (i < 0) return null;
    return '/${segs.sublist(0, i + 1).join('/')}';
  }

  /// 去掉首尾斜杠后的分段（空串 → 空列表）
  static List<String> _segments(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList();
}

/// `List.list` / `List.list_share` / `Favorite.list` / `VirtualFolder.list` 的统一返回。
class FileListResult {
  const FileListResult({
    this.total = 0,
    this.offset = 0,
    this.entries = const [],
    this.finished,
  });

  final int total;
  final int offset;
  final List<FileEntryDto> entries;

  /// `SYNO.FileStation.Search:list` 回包顶层的 `finished`：
  /// **三态** —— `true` 搜完了 / `false` 服务端还在跑 / `null` 服务端没回这个字段
  /// （`List.list` 等其它接口根本不带它）。
  ///
  /// ★ r135 真机取证：搜索是**异步**的，`list` 在跑的时候会回
  /// `finished:false` + 已命中的部分结果。调用方原来不看这个位、
  /// 只轮询 ~1.2 秒就下结论 ⇒ 在 `/home/Video` 搜 `Citizen` 先显示
  /// 「No matching files」、过十几秒再点一次才命中（`Citizen Kane (1941).mkv`）。
  /// 所以"没这个位"和"false"必须能分开：前者是老服务端，退回旧的宽限策略。
  final bool? finished;

  /// 服务端**明确**说还没搜完（`false`）。`null`（不知道）不算 —— 见上面。
  bool get stillRunning => finished == false;

  bool get isEmpty => entries.isEmpty;
  bool get hasMore => offset + entries.length < total;

  factory FileListResult.fromJson(Map<String, dynamic> json) {
    // `files`（List.list）/ `shares`（list_share）/ `folders`（部分接口）/
    // `favorites`（Favorite.list，真机实测就是这个键 —— 早先漏了它，
    // 表现是"收藏页永远空"，虽然 add/delete 都成功）/
    // `items`（Extract.list，⚠️ 形状未经实证，见 docs/api-server-authoritative.md §11）
    final raw =
        json['files'] ??
        json['shares'] ??
        json['folders'] ??
        json['favorites'] ??
        json['items'];
    final list = raw is List
        ? raw
              .whereType<Map>()
              .map((e) => FileEntryDto.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : <FileEntryDto>[];
    return FileListResult(
      total: _int(json['total']),
      offset: _int(json['offset']),
      entries: list,
      // 宽松助手：数字/字符串 '1'/'true' 也算真；缺失或脏值 → null（"不知道"）
      finished: jsonBool(json['finished']),
    );
  }
}

/// 后台任务（`SYNO.FileStation.BackgroundTask.list`）。
///
/// 字段照抄 `TaskListVo.Task`：`taskid api method version finished progress
/// processed_num processing_path crtime path params errors`。
/// 服务端**只有** `list` / `clear_finished` 两个方法。
class FileTaskDto {
  const FileTaskDto({
    required this.taskId,
    this.api = '',
    this.method = '',
    this.version = 0,
    this.finished = false,
    this.progress = 0,
    this.processedNum = 0,
    this.processingPath = '',
    this.createdTime = '',
    this.path = '',
    this.params = const {},
    this.errors = const [],
  });

  final String taskId;
  final String api;
  final String method;
  final int version;
  final bool finished;

  /// 0.0 ~ 1.0
  final double progress;
  final int processedNum;
  final String processingPath;
  final String createdTime;

  /// 任务对象路径（压缩/复制/删除的源）
  final String path;

  /// 原始参数（`path` / `dest_folder_path` / `remove_src` …）
  final Map<String, dynamic> params;

  /// `[{code, path}]` —— 失败的文件
  final List<FileTaskError> errors;

  /// 任务类型的中文说明
  ///
  /// 数据层拿不到 `BuildContext`，按 docs §4.6 走 `data_text.dart` 的 [dataText]；
  /// 没装翻译器就回落中文原文。
  String get label => switch (method) {
    'start' when api.endsWith('Compress') => dataText(
      'dtoFileTaskCompress',
      '压缩',
    ),
    'start' when api.endsWith('Extract') => dataText(
      'dtoFileTaskExtract',
      '解压',
    ),
    'start' when api.endsWith('CopyMove') =>
      params['remove_src'] == true
          ? dataText('dtoActionMove', '移动')
          : dataText('dtoActionCopy', '复制'),
    'delete' ||
    'start' when api.endsWith('Delete') => dataText('dtoActionDelete', '删除'),
    'start' when api.endsWith('DirSize') => dataText('dtoFileTaskSize', '统计大小'),
    'start' when api.endsWith('MD5') => dataText(
      'dtoFileTaskChecksum',
      '计算校验值',
    ),
    _ => api.replaceFirst('SYNO.FileStation.', ''),
  };

  factory FileTaskDto.fromJson(Map<String, dynamic> json) => FileTaskDto(
    taskId: '${json['taskid'] ?? ''}',
    api: '${json['api'] ?? ''}',
    method: '${json['method'] ?? ''}',
    version: _int(json['version']),
    finished: json['finished'] == true,
    progress: _double(json['progress']),
    processedNum: _int(json['processed_num']),
    processingPath: '${json['processing_path'] ?? ''}',
    createdTime: '${json['crtime'] ?? ''}',
    path: '${json['path'] ?? ''}',
    params: json['params'] is Map
        ? Map<String, dynamic>.from(json['params'] as Map)
        : const {},
    errors: json['errors'] is List
        ? (json['errors'] as List)
              .whereType<Map>()
              .map((e) => FileTaskError.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const [],
  );
}

/// 任务里的单个失败项
class FileTaskError {
  const FileTaskError({this.code = 0, this.path = ''});
  final int code;
  final String path;

  factory FileTaskError.fromJson(Map<String, dynamic> json) =>
      FileTaskError(code: _int(json['code']), path: '${json['path'] ?? ''}');
}

/// 任务列表返回
class FileTaskListResult {
  const FileTaskListResult({
    this.total = 0,
    this.offset = 0,
    this.tasks = const [],
  });
  final int total;
  final int offset;
  final List<FileTaskDto> tasks;

  factory FileTaskListResult.fromJson(Map<String, dynamic> json) {
    final raw = json['tasks'];
    return FileTaskListResult(
      total: _int(json['total']),
      offset: _int(json['offset']),
      tasks: raw is List
          ? raw
                .whereType<Map>()
                .map((e) => FileTaskDto.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
    );
  }
}

/// 分享链接（`SYNO.FileStation.Sharing.list`）。
///
/// 字段照抄 `ShareLink.java`：`id path name url isFolder status has_password
/// date_available date_expired link_owner uid qrcode error`。
class ShareLinkDto {
  const ShareLinkDto({
    required this.id,
    this.path = '',
    this.name = '',
    this.url = '',
    this.isFolder = false,
    this.status = '',
    this.hasPassword = false,
    this.passwordKnown = false,
    this.dateAvailable = '',
    this.dateExpired = '',
    this.expiryKnown = false,
    this.linkOwner = '',
    this.uid = 0,
    this.qrcode = '',
    this.error = 0,
  });

  final String id;
  final String path;
  final String name;
  final String url;
  final bool isFolder;
  final String status;
  final bool hasPassword;

  /// `has_password` **这个键在不在**（不是"密码是什么"）。
  /// ⚠️ 缺键与 `false` 是两件事：前者 = 服务端没说，后者 = 服务端说没有密码。
  final bool passwordKnown;
  final String dateAvailable;
  final String dateExpired;

  /// `date_expired` **这个键在不在**。缺键时 [dateExpired] 也是空串，
  /// 但"空串"只该读成"没说"，**不许**直接读成"永久"（r306 真机教训）。
  final bool expiryKnown;
  final String linkOwner;
  final int uid;
  final String qrcode;
  final int error;

  /// `status`：`valid` / `invalid` / `broken`（官方 VO 里是裸字符串）
  bool get isValid => status.isEmpty || status == 'valid';

  factory ShareLinkDto.fromJson(Map<String, dynamic> json) => ShareLinkDto(
    id: '${json['id'] ?? ''}',
    path: '${json['path'] ?? ''}',
    name: '${json['name'] ?? ''}',
    url: '${json['url'] ?? ''}',
    isFolder: json['isFolder'] == true,
    status: '${json['status'] ?? ''}',
    hasPassword: json['has_password'] == true,
    passwordKnown: json.containsKey('has_password'),
    dateAvailable: '${json['date_available'] ?? ''}',
    dateExpired: '${json['date_expired'] ?? ''}',
    expiryKnown: json.containsKey('date_expired'),
    linkOwner: '${json['link_owner'] ?? ''}',
    uid: _int(json['uid']),
    qrcode: '${json['qrcode'] ?? ''}',
    error: _int(json['error']),
  );

  /// `Sharing.list` 的返回是 `{links: [...], total, offset}`
  static List<ShareLinkDto> parseList(Map<String, dynamic> json) {
    final raw = json['links'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => ShareLinkDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

/// 「共享给我的」条目（`SYNO.FileStation.Sharing / list_share_me`，wave3）。
///
/// 字段名**逐一取自官方 Web 前端的 reader**，不是臆造：
/// `/tmp/spk/export_FileStation/ui/file_browser/FileBrowser.js` 的
/// `SYNO.FileStation.SharingManager.Common.createStore`（同一 store 同时服务
/// `list` 与 `list_share_me`，root 固定 `links`）：
///
/// ```js
/// reader: new Ext.data.JsonReader({root:"links"},[
///   {name:"id"},{name:"url"},{name:"link_owner"},{name:"path"},{name:"name"},
///   {name:"expire_at",mapping:"date_expired"},
///   {name:"start_at",mapping:"date_available"},
///   {name:"expire_times"},{name:"protect_users"},{name:"protect_groups"},
///   {name:"status"},{name:"protect_type"},{name:"qrcode"},{name:"isFolder"},
///   {name:"enable_upload"},{name:"request_name"},{name:"request_info"},
///   {name:"limit_size"},{name:"project_name"}])
/// ```
///
/// 即线上回包用 `date_expired` / `date_available` 两个名字，官方前端在读取时
/// 改名成 `expire_at` / `start_at`（列模型用的是改名后的 `expire_at`）。
/// 这里**按线上原名解析**（`date_expired` / `date_available`），
/// getter 名沿用官方前端的 `expireAt` / `startAt`。
///
/// ⚠️ `id` 是内部标识，**只在 Key 与测试断言里出现，绝不上屏**。
class SharedWithMeLinkDto {
  const SharedWithMeLinkDto({
    required this.id,
    this.url = '',
    this.linkOwner = '',
    this.path = '',
    this.name = '',
    this.dateExpired = '',
    this.dateAvailable = '',
    this.expireTimes = 0,
    this.protectUsers = const [],
    this.protectGroups = const [],
    this.status = '',
    this.protectType = '',
    this.qrcode = '',
    this.isFolder = false,
    this.enableUpload = false,
    this.requestName = '',
    this.requestInfo = '',
    this.limitSize = 0,
    this.projectName = '',
  });

  /// 内部 id（`link_id`）—— 不上屏
  final String id;
  final String url;
  final String linkOwner;
  final String path;
  final String name;

  /// 线上字段 `date_expired`（官方 reader 改名 `expire_at`）
  final String dateExpired;

  /// 线上字段 `date_available`（官方 reader 改名 `start_at`）
  final String dateAvailable;

  final int expireTimes;
  final List<String> protectUsers;
  final List<String> protectGroups;

  /// `ok` / `broken` / `expired` / `inactive`（官方列模型的分支逐字）
  final String status;

  /// `none` / `password` …
  final String protectType;
  final String qrcode;
  final bool isFolder;
  final bool enableUpload;
  final String requestName;
  final String requestInfo;
  final int limitSize;

  /// 分享来源应用的包名（官方 `getTypeArray` 的取值）：
  /// `SYNO.SDS.App.FileStation3.Instance` / `SYNO.SDS.App.SharingUpload.Application`
  /// / `SYNO.SDS.PDFViewer.Application`。
  final String projectName;

  /// 有密码保护（`protect_type` 非 `none` 且非空）
  bool get hasPassword =>
      protectType.isNotEmpty && protectType.toLowerCase() != 'none';

  /// 官方列模型：只有 `broken` / `expired` / `inactive` 是异常，其余画成
  /// `status_ok`（空 status 也当正常 —— 老服务端不给这个字段）。
  bool get isOk =>
      status != 'broken' && status != 'expired' && status != 'inactive';

  factory SharedWithMeLinkDto.fromJson(Map<String, dynamic> json) =>
      SharedWithMeLinkDto(
        id: '${json['id'] ?? ''}',
        url: '${json['url'] ?? ''}',
        linkOwner: '${json['link_owner'] ?? ''}',
        path: '${json['path'] ?? ''}',
        name: '${json['name'] ?? ''}',
        // 线上原名，见类文档
        dateExpired: '${json['date_expired'] ?? ''}',
        dateAvailable: '${json['date_available'] ?? ''}',
        expireTimes: _int(json['expire_times']),
        protectUsers: _stringList(json['protect_users']),
        protectGroups: _stringList(json['protect_groups']),
        status: '${json['status'] ?? ''}',
        protectType: '${json['protect_type'] ?? ''}',
        qrcode: '${json['qrcode'] ?? ''}',
        isFolder: json['isFolder'] == true,
        enableUpload: json['enable_upload'] == true,
        requestName: '${json['request_name'] ?? ''}',
        requestInfo: '${json['request_info'] ?? ''}',
        limitSize: _int(json['limit_size']),
        projectName: '${json['project_name'] ?? ''}',
      );
}

/// `Sharing/list_share_me` 的整包返回：`{links, total, offset}`。
///
/// 真机回包（本机为空）：
/// `{"data":{"links":[],"offset":0,"total":0},"success":true}`
/// —— 空 `links` 是**正常的空态**，不是错误。
class SharedWithMeListResult {
  const SharedWithMeListResult({
    this.links = const [],
    this.total = 0,
    this.offset = 0,
  });

  final List<SharedWithMeLinkDto> links;
  final int total;
  final int offset;

  bool get isEmpty => links.isEmpty;

  factory SharedWithMeListResult.fromJson(Map<String, dynamic> json) {
    final raw = json['links'];
    return SharedWithMeListResult(
      links: raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (e) => SharedWithMeLinkDto.fromJson(
                    Map<String, dynamic>.from(e),
                  ),
                )
                .toList()
          : const [],
      total: _int(json['total']),
      offset: _int(json['offset']),
    );
  }
}

/// `List<dynamic>` → `List<String>`（`protect_users` / `protect_groups`），
/// 非数组回空表。
List<String> _stringList(Object? v) {
  if (v is! List) return const [];
  return v.map((e) => '$e').toList();
}

/// 任务/列表里通用的启动返回：`{taskid: "..."}` 或 `[{taskid: ...}]`
class FileTaskStart {
  const FileTaskStart({this.taskIds = const []});
  final List<String> taskIds;

  bool get isEmpty => taskIds.isEmpty;

  factory FileTaskStart.fromJson(Map<String, dynamic> json) {
    final single = json['taskid'];
    if (single != null) return FileTaskStart(taskIds: ['$single']);
    final raw = json['taskids'] ?? json['tasks'];
    if (raw is List) {
      return FileTaskStart(
        taskIds: raw
            .whereType<Map>()
            .map((e) => '${Map<String, dynamic>.from(e)['taskid'] ?? ''}')
            .where((e) => e.isNotEmpty)
            .toList(),
      );
    }
    return const FileTaskStart();
  }
}

/// MD5 校验任务的状态（`SYNO.FileStation.MD5 / status`）。
///
/// 形态照抄官方 FileStation Web 客户端的 `CalcMD5Callback`：
/// 跑到 `finished: true` 才有 `md5`；出错时回包里带 `errors`。
class FileMd5Status {
  const FileMd5Status({
    this.finished = false,
    this.md5 = '',
    this.errorCount = 0,
  });

  final bool finished;

  /// 32 位小写十六进制；没算完/算失败时是空串
  final String md5;

  /// `errors` 数组长度（>0 表示有文件算不了，比如无权限）
  final int errorCount;

  bool get failed => errorCount > 0 && !finished;

  factory FileMd5Status.fromJson(Map<String, dynamic> json) {
    final errors = json['errors'];
    return FileMd5Status(
      finished: json['finished'] == true,
      md5: '${json['md5'] ?? ''}',
      errorCount: errors is List ? errors.length : 0,
    );
  }
}

/// `SYNO.FileStation.Property.ACLOwner / get` 的返回。
///
/// 官方 Web 端拿到的是 `{name, type("user"/"group"), value("user:name"),
/// hasPrivilege}`；没权限时服务端直接回 `403`（不在这里表达）。
class FileAclOwnerDto {
  const FileAclOwnerDto({
    this.name = '',
    this.type = '',
    this.value = '',
    this.hasPrivilege = false,
  });

  final String name;

  /// `user` / `group`
  final String type;

  /// `user:名字`
  final String value;

  /// 当前登录用户能不能改所有者
  final bool hasPrivilege;

  /// 给 UI 用的一行字：`user:foo`
  String get label =>
      value.isNotEmpty ? value : (name.isEmpty ? '' : '$type:$name');

  factory FileAclOwnerDto.fromJson(Map<String, dynamic> json) =>
      FileAclOwnerDto(
        name: '${json['name'] ?? ''}',
        type: '${json['type'] ?? ''}',
        value: '${json['value'] ?? ''}',
        hasPrivilege: json['hasPrivilege'] == true,
      );
}

/// `SYNO.FileStation.Search` 的启动返回（`{taskid, offset, finished}`）
class FileSearchStart {
  const FileSearchStart({
    this.taskId = '',
    this.finished = false,
    this.offset = 0,
  });
  final String taskId;
  final bool finished;
  final int offset;

  factory FileSearchStart.fromJson(Map<String, dynamic> json) =>
      FileSearchStart(
        taskId: '${json['taskid'] ?? ''}',
        finished: json['finished'] == true,
        offset: _int(json['offset']),
      );
}

/// `SYNO.FileStation.CheckPermission.write` 的返回
class FileWritePermission {
  const FileWritePermission({
    this.isWritable = false,
    this.reason = '',
    this.skipPrompt = false,
  });

  /// 能写吗。
  ///
  /// 真机（DSM 7.4 / DS923+）**不返回** `is_writable`：可写 → `{blSkip:false}`，
  /// 只读 → 抛 `401`。所以判据是"调用是否成功"（[callSucceeded]），
  /// `is_writable` 只是兼容老版本/其它分支的字段。
  final bool isWritable;

  final String reason;

  /// 服务端的 `blSkip`：为 true 表示客户端"不必再弹确认框"
  final bool skipPrompt;

  factory FileWritePermission.fromJson(
    Map<String, dynamic> json, {
    bool callSucceeded = false,
  }) => FileWritePermission(
    isWritable: json['is_writable'] == true || callSucceeded,
    reason: '${json['reason'] ?? ''}',
    skipPrompt: json['blSkip'] == true,
  );
}

/// `SYNO.FileStation.DirSize.start` 的返回
class FileDirSizeStart {
  const FileDirSizeStart({this.taskId = ''});
  final String taskId;

  factory FileDirSizeStart.fromJson(Map<String, dynamic> json) =>
      FileDirSizeStart(taskId: '${json['taskid'] ?? ''}');
}

/// 带缩略图的条目 —— `SYNO.FileStation.Thumb.get` 返回的是**图片二进制**，
/// 不在 JSON 里，所以这里只提供 URL 构造（见 `FileStationApi.thumbnailUrl`）。

/// 单元大小 / 进度用的数值解析
int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}

double _double(Object? v) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  return double.tryParse('$v') ?? 0;
}

/// 人类可读大小（与聊天附件保持同一套规则）
String formatSize(int size) {
  if (size <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = size.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(value >= 10 ? 0 : 1);
  return '$text ${units[unit]}';
}
