// Synology Drive 的文件条目 VO（P0.1「文件」第二来源）。
//
// 权威来源（两层，缺一不可）：
//   * NAS 上装的 **SynologyDrive 4.2.0-30058** SPK：方法/版本表见
//     `docs/api-server-authoritative.md` §5；官方 Web 端的
//     `drive/synodrive_common.js`（`SYNO.SDS.Drive.WebAPIDesc`）给出**版本与参数名**；
//   * 真机实测（`tool/drive_probe.dart`，见 `docs/api-server-authoritative.md` §5.1）：
//     回包形状是 `{items, total}`，条目字段如下。
//
// ⚠️ Drive 与 FileStation 的三处关键差异（写错就"能列出来但打不开"）：
//   1. **路径是 `id:<file_id>`**（官方 `Utils.getPathId`），`path` 字段是相对
//      `/mydrive` 的（`/drive-probe/a.txt`），`display_path` 才是 `/mydrive/...`；
//   2. `file_id` / `version_id` / `sync_id` 在 JSON 里是**字符串**（大整数，别转 int）；
//   3. 大小字段叫 **`size`**（不是 FileStation 的 `additional.size`）。
import 'drive_label_dto.dart';

/// Drive 条目的排序键（官方列表接口的 `sort_by`）
enum DriveSortBy {
  name('name'),
  size('size'),
  modifiedTime('modified_time'),
  createdTime('created_time');

  const DriveSortBy(this.value);
  final String value;
}

/// 一个 Drive 条目（文件或文件夹）
class DriveEntryDto {
  const DriveEntryDto({
    required this.fileId,
    required this.name,
    required this.type,
    required this.path,
    required this.displayPath,
    required this.parentId,
    required this.size,
    required this.modifiedTime,
    required this.createdTime,
    required this.contentType,
    required this.starred,
    required this.shared,
    required this.owner,
    required this.canDownload,
    required this.canPreview,
    required this.canWrite,
    required this.capabilities,
    this.canLock = true,
    this.isLocked = false,
    this.lockUserName = '',
    this.lockUserDisplayName = '',
    this.permanentLink = '',
    this.versionId = '',
    this.revisionCount = 0,
    this.dsmPath = '',
    this.labels = const [],
    this.recycledTime = 0,
    this.thumbnail = '',
    this.snippet = '',
  });

  /// `file_id`（字符串形态；请求时用 `id:<file_id>`）
  final String fileId;
  final String name;

  /// `"file"` / `"dir"`
  final String type;

  /// 相对 `/mydrive` 的路径（如 `/drive-probe/a.txt`）
  final String path;

  /// `/mydrive/...` 形态的展示路径
  final String displayPath;
  final String parentId;
  final int size;

  /// epoch 秒
  final int modifiedTime;
  final int createdTime;

  /// `"document"` / `"image"` / `"video"` / `"dir"` / …（官方 `content_type`）
  final String contentType;
  final bool starred;
  final bool shared;

  /// 所有者的显示名（官方 `owner.display_name`，空则退回 `owner.name`）
  final String owner;
  final bool canDownload;
  final bool canPreview;
  final bool canWrite;

  /// `capabilities.can_lock`：**服务端允许对这个节点上锁**（≠ 当前已锁）。
  ///
  /// 原文证据：官方权限判定 `checkLockNode` / `checkUnLockNode`
  /// （`drive/synodrive.js:91090` 起）读的就是 `capabilities.can_lock`，
  /// 且加锁额外要求 `can_write`。缺省（服务端没给）按官方语义取 `true`，
  /// 但真正的开关由 [isLocked] + 能力位共同决定。
  final bool canLock;

  /// `node_locking.is_locked`：当前是否已被（某人）锁住。
  ///
  /// 原文证据：`node_locking` 对象在官方前端被读作
  /// `{is_locked, lock_user:{name, display_name}}`（`drive/synodrive.js:91090`、
  /// `synodrive_common.js:78606` 的 `getFileLockingTooltip`）。
  final bool isLocked;

  /// `node_locking.lock_user.name`（账号名）
  final String lockUserName;

  /// `node_locking.lock_user.display_name`（显示名）
  final String lockUserDisplayName;

  /// 原样保留 `capabilities`（后续版本/共享页面要用）
  final Map<String, dynamic> capabilities;

  /// 官方 `permanent_link`：Drive 给每个文件发的**稳定短链 id**。
  ///
  /// 它是 Office 只读预览的钥匙 —— `SYNO.Office.File.extract` 只认这个值
  /// （`path`/`id:`/`object_id` 真机全失败，见 `lib/src/data/office_api.dart`）。
  final String permanentLink;

  /// `version_id`（服务端全局变更号；最新版本的标识，版本历史里用来标"当前"）
  final String versionId;

  /// `revisions`：这个文件有几个版本（0/缺省表示服务端没给）
  final int revisionCount;

  /// `dsm_path`：同一份文件在 DSM 文件系统里的路径（用 FileStation 直接读写
  /// Drive 里的文件时要用；个人空间的 `/mydrive/x` 对应 `/home/Drive/x`）
  final String dsmPath;

  /// 已打的标签（`Files/list`/`Files/get` 回的都是**标签对象数组**，
  /// 不是 id 列表——真机 2026-09-19 确认）
  final List<DriveLabelDto> labels;

  /// `recycled_time`：**进回收站的时间**（epoch 秒；不在回收站时为 0）。
  ///
  /// 原文证据：官方 `drive/synodrive_common.js` 的回收站列表
  /// `ViewStore.Recycle`：`{name:"recycled_time"}` 读字段、
  /// 默认排序 `{field:"recycled_time", direction:"DESC"}`，列定义
  /// `recycle:["name","recycled_time","mtime","owner_name","size","display_path"]`
  /// （`/tmp/spk/export_SynologyDrive/drive/synodrive_common.js:487841` 与
  /// `:416046`）。普通 `Files/list` 不回它，只有在 `Trash/list` 里有意义。
  final int recycledTime;

  /// `thumbnail`：服务端在 `Files/list` 里**可能**带的缩略图直链。
  ///
  /// 字段名证据：官方 Web 端的列表 reader 里就有一个名为 `thumbnail` 的计算字段
  /// （`drive/synodrive_common.js` 的 `{name:"thumbnail",convert:function(e,t){…}}`），
  /// 缩略图模板 `getThumbImg()` 先读 `e.thumbnail`、没有才现拼
  /// `get_thumbnail` 直链。
  ///
  /// ⚠️ **未取证**：服务端是否真的会在回包里下发这个字段、以及
  /// `Files/list` 的 `field` 参数该取什么值，都没有真机原文；所以这里只做
  /// **"有则用、没有就回落到既有的 `get_thumbnail` 直链"**（见
  /// `drive_browse_view.dart` 的网格缩略图）。空串 = 服务端没给。
  final String thumbnail;

  /// `content_snippet`：**内容搜索的命中片段**（服务端高亮后的文本）。
  ///
  /// 字段名证据：官方 `/tmp/drive-apk/jadx/.../api/response/FileInfoVo.java:19`
  /// 就有一个名为 **`content_snippet`** 的 String 字段（无 `@SerializedName`
  /// ⇒ Gson 按字段名映射）。
  ///
  /// ⚠️ 请求参数里也有一个同名的 `content_snippet`（布尔开关，
  /// `ApiSynoDriveFiles.java:130` `SEARCH_KEY__SNIPPET_QUERY="content_snippet"`）
  /// —— **一个是开关、一个是回包文本**，别混。
  ///
  /// 只有**内容搜索**（服务端真的读了文件）才会有值；文件名搜索、列表、
  /// 最近等场景一律为空串 ⇒ UI 必须"有则显示"。
  final String snippet;

  bool get isDir => type == 'dir';

  /// 官方列表里的 `path` 是相对个人空间根的，给"面包屑/相对路径"用
  String get relativePath => path;

  /// 请求参数用的 path id（官方 `SYNO.SDS.Drive.Utils.getPathId`）
  String get pathId => 'id:$fileId';

  /// 扩展名（小写，无点）
  String get extension {
    final i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return '';
    return name.substring(i + 1).toLowerCase();
  }

  /// 人类可读大小（目录不显示大小）
  String get humanSize => isDir ? '' : driveHumanSize(size);

  /// [forceType]：**由调用方声明这一批条目是什么**，覆盖回包里的 `type`。
  ///
  /// 为什么需要：`TeamFolders/list` 的条目**不带 `type` 字段**，而下面的
  /// 兜底是"空 `type` ⇒ `'file'`" ⇒ 团队文件夹会被当成文件（真机取证：
  /// 选中的是目录却进了"用系统应用打开"的预览页，大小列显示 `0 B`）。
  /// 团队文件夹**按定义就是目录**（官方 APK 本地表
  /// `CREATE TABLE team_folder(name, team_id, file_id, disable_download, drive_type)`
  /// 里 `file_id` 与 `file` 表同键 ⇒ 它就是 Drive 里的一个目录节点），
  /// 所以这一批在边界上直接声明为 `dir`，不靠回包字段猜。
  static DriveEntryDto fromJson(
    Map<String, dynamic> json, {
    String? forceType,
  }) {
    final owner = (json['owner'] as Map?)?.cast<String, dynamic>() ?? const {};
    final caps =
        (json['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {};
    final locking =
        (json['node_locking'] as Map?)?.cast<String, dynamic>() ?? const {};
    final lockUser =
        (locking['lock_user'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DriveEntryDto(
      fileId: _str(json['file_id']),
      name: _str(json['name']),
      type: forceType ?? (_str(json['type']).isEmpty ? 'file' : _str(json['type'])),
      path: _str(json['path']),
      displayPath: _str(json['display_path']),
      parentId: _str(json['parent_id']),
      size: _int(json['size']),
      modifiedTime: _int(json['modified_time']),
      createdTime: _int(json['created_time']),
      contentType: _str(json['content_type']),
      starred: _bool(json['starred']),
      shared: _bool(json['shared']),
      owner: _str(owner['display_name']).isEmpty
          ? _str(owner['name'])
          : _str(owner['display_name']),
      canDownload: _bool(caps['can_download'], fallback: true),
      canPreview: _bool(caps['can_preview'], fallback: true),
      canWrite: _bool(caps['can_write']),
      capabilities: caps,
      canLock: _bool(caps['can_lock'], fallback: true),
      isLocked: _bool(locking['is_locked']),
      lockUserName: _str(lockUser['name']),
      lockUserDisplayName: _str(lockUser['display_name']),
      permanentLink: _str(json['permanent_link']),
      versionId: _str(json['version_id']),
      revisionCount: _int(json['revisions']),
      dsmPath: _str(json['dsm_path']),
      labels: [
        for (final e in (json['labels'] as List?) ?? const [])
          if (e is Map) DriveLabelDto.fromJson(e.cast<String, dynamic>()),
      ],
      recycledTime: _int(json['recycled_time']),
      thumbnail: _str(json['thumbnail']),
      snippet: _str(json['content_snippet']),
    );
  }

  /// `{items, total}` 形态的回包
  static ({List<DriveEntryDto> items, int total}) listFromJson(
    Map<String, dynamic> data, {
    String? forceType,
  }) {
    final raw = (data['items'] as List?) ?? const [];
    final items = raw
        .whereType<Map>()
        .map(
          (e) => DriveEntryDto.fromJson(
            e.cast<String, dynamic>(),
            forceType: forceType,
          ),
        )
        .toList(growable: false);
    return (items: items, total: _int(data['total']));
  }
}

/// 人类可读大小（Drive 的版本列表与条目列表共用一份，避免两处算得不一样）
String driveHumanSize(int size) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = size.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  final s = u == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(v >= 100 ? 0 : 1);
  return '$s ${units[u]}';
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}

String _str(Object? v) => v == null ? '' : '$v';

bool _bool(Object? v, {bool fallback = false}) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return fallback;
}
