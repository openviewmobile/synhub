// ★★★ ③Drive **D65「同步任务 / 同步设备管理」** —— 第 217 轮。
//
// ## 官方证据（`docs/drive-apk391113-evidence.md`；208 轮取证）
// 官方「同步任务」**不是**服务端任务列表，而是**本地目录同步引擎**：
//   `ShowSyncTaskActivity` → `sync/fragment/DriveSyncTaskListFragment` →
//   `DriveSyncTaskListViewModel`，数据源是 APK 自带的 **Room 库**
//   `sync/db/SyncDB` + `sync/db/entities/TaskInfo`
//   （字段 `local_root` / `remote_root` / `remote_root_change_id` / `status` /
//    `auto_sync_enabled` / `auto_sync_interval` / `conflict_rename` /
//    `conflict_keep_latest` / `ignore_local_remove` / `index_home` /
//    `limit_size` / `https` / `deleted`），
//   执行器是 `sync/core/SyncRunner`（`doUpload` / `doDownload` /
//   `doRemoveLocal` / `doRemoveRemote` / `doRename*`）。
//   ⇒ **没有** `SYNO.SynologyDrive.Sync.*` 服务端 API（catalog 里 0 命中，
//   本轮实测复核过），所以 Mock 只能覆盖它用到的那半边 ——
//   远端列举走既有的 `SYNO.SynologyDrive.Files.list`。
//
// ## 本文件的口径（诚实边界）
// 本轮把**任务模型 + 任务存储 + 同步差异决策（纯函数）** 做出来：
//   * 模型字段与官方 `TaskInfo` **逐字段对齐**（含 snake_case 序列化键）；
//   * `planDriveSync` 是官方 `SyncRunner` 四个动作的**决策层**（不碰 IO）；
//   * 真正的**文件搬运/后台常驻服务**（`DriveFileWatchService`、
//     分块续传、冲突副本落盘）**仍未实现** ⇒ D65 保持 🟠，不冒充 ✅。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'drive_gaps_text.dart';

/// 官方 `TaskInfo.status`（Room 列 `status`；字符串值取自 smali 常量）。
enum DriveSyncStatus {
  idle('idle', '空闲'),
  syncing('syncing', '同步中'),
  paused('paused', '已暂停'),
  error('error', '出错'),
  done('done', '已完成');

  const DriveSyncStatus(this.wire, this.label);

  /// 官方落库的字符串值（**别改**：要与 Room 里的行兼容）
  final String wire;
  final String label;
}

DriveSyncStatus driveSyncStatusOf(String? wire) {
  for (final s in DriveSyncStatus.values) {
    if (s.wire == wire) return s;
  }
  return DriveSyncStatus.idle;
}

/// 冲突策略（官方是**两个独立布尔**：`conflict_rename` / `conflict_keep_latest`）。
enum DriveSyncConflict {
  /// 保留双方，本地生成冲突副本（官方 `doRenameLocal`）
  rename('rename', '保留两份（重命名冲突副本）'),

  /// 新者胜（官方比 `modified_time`）
  keepLatest('keepLatest', '以较新的一份为准');

  const DriveSyncConflict(this.wire, this.label);
  final String wire;
  final String label;
}

/// 一个同步任务（官方 `TaskInfo` 的等价物；键名保持官方 snake_case）。
class DriveSyncTask {
  const DriveSyncTask({
    required this.id,
    required this.localRoot,
    required this.remoteRoot,
    this.remoteRootChangeId = '',
    this.status = DriveSyncStatus.idle,
    this.autoSyncEnabled = true,
    this.autoSyncInterval = kDriveSyncDefaultIntervalMinutes,
    this.conflict = DriveSyncConflict.rename,
    this.ignoreLocalRemove = false,
    this.indexHome = true,
    this.limitSize = 0,
    this.https = true,
    this.deleted = false,
    this.lastSyncAtMs = 0,
  });

  final String id;

  /// 官方 `local_root`：本地目录（绝对路径）
  final String localRoot;

  /// 官方 `remote_root`：远端目录（Drive 路径，如 `/mydrive/项目`）
  final String remoteRoot;

  /// 官方 `remote_root_change_id`：远端变更游标（增量同步用）
  final String remoteRootChangeId;

  final DriveSyncStatus status;

  /// 官方 `auto_sync_enabled`
  final bool autoSyncEnabled;

  /// 官方 `auto_sync_interval`（分钟）
  final int autoSyncInterval;

  /// 官方 `conflict_rename` / `conflict_keep_latest` 的归一化
  final DriveSyncConflict conflict;

  /// 官方 `ignore_local_remove`：本地删了**不**跟着删远端
  final bool ignoreLocalRemove;

  /// 官方 `index_home`：同时纳入 home 目录索引
  final bool indexHome;

  /// 官方 `limit_size`：超过这个字节数的文件不同步（0 = 不限）
  final int limitSize;

  /// 官方 `https`
  final bool https;

  /// 官方 `deleted`（软删；列表默认过滤）
  final bool deleted;

  final int lastSyncAtMs;

  DriveSyncTask copyWith({
    DriveSyncStatus? status,
    String? remoteRootChangeId,
    bool? autoSyncEnabled,
    int? autoSyncInterval,
    DriveSyncConflict? conflict,
    bool? ignoreLocalRemove,
    bool? indexHome,
    int? limitSize,
    bool? https,
    bool? deleted,
    int? lastSyncAtMs,
  }) => DriveSyncTask(
    id: id,
    localRoot: localRoot,
    remoteRoot: remoteRoot,
    remoteRootChangeId: remoteRootChangeId ?? this.remoteRootChangeId,
    status: status ?? this.status,
    autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
    autoSyncInterval: autoSyncInterval ?? this.autoSyncInterval,
    conflict: conflict ?? this.conflict,
    ignoreLocalRemove: ignoreLocalRemove ?? this.ignoreLocalRemove,
    indexHome: indexHome ?? this.indexHome,
    limitSize: limitSize ?? this.limitSize,
    https: https ?? this.https,
    deleted: deleted ?? this.deleted,
    lastSyncAtMs: lastSyncAtMs ?? this.lastSyncAtMs,
  );

  /// 官方 Room 的列名（**存盘/读盘都用它**，便于与官方库对照）
  Map<String, Object?> toJson() => {
    'id': id,
    'local_root': localRoot,
    'remote_root': remoteRoot,
    'remote_root_change_id': remoteRootChangeId,
    'status': status.wire,
    'auto_sync_enabled': autoSyncEnabled,
    'auto_sync_interval': autoSyncInterval,
    'conflict_rename': conflict == DriveSyncConflict.rename,
    'conflict_keep_latest': conflict == DriveSyncConflict.keepLatest,
    'ignore_local_remove': ignoreLocalRemove,
    'index_home': indexHome,
    'limit_size': limitSize,
    'https': https,
    'deleted': deleted,
    'last_sync_at': lastSyncAtMs,
  };

  static DriveSyncTask fromJson(Map<String, Object?> j) => DriveSyncTask(
    id: '${j['id'] ?? ''}',
    localRoot: '${j['local_root'] ?? ''}',
    remoteRoot: '${j['remote_root'] ?? ''}',
    remoteRootChangeId: '${j['remote_root_change_id'] ?? ''}',
    status: driveSyncStatusOf(j['status'] as String?),
    autoSyncEnabled: j['auto_sync_enabled'] == true,
    autoSyncInterval:
        (j['auto_sync_interval'] as num?)?.toInt() ??
        kDriveSyncDefaultIntervalMinutes,
    conflict: j['conflict_keep_latest'] == true
        ? DriveSyncConflict.keepLatest
        : DriveSyncConflict.rename,
    ignoreLocalRemove: j['ignore_local_remove'] == true,
    indexHome: j['index_home'] != false,
    limitSize: (j['limit_size'] as num?)?.toInt() ?? 0,
    https: j['https'] != false,
    deleted: j['deleted'] == true,
    lastSyncAtMs: (j['last_sync_at'] as num?)?.toInt() ?? 0,
  );

  /// 本地目录的**末段名**（列表里给用户看）
  String get localName => localRoot
      .split(RegExp(r'[/\\]'))
      .where((e) => e.isNotEmpty)
      .fold<String>('', (_, e) => e);
}

/// 官方默认同步间隔（分钟）—— `auto_sync_interval` 的初值
const int kDriveSyncDefaultIntervalMinutes = 30;

/// 官方可选间隔档（APK 里的下拉：10/30/60/…分钟）
const List<int> kDriveSyncIntervalChoices = [5, 10, 30, 60, 240, 720];

/// 校验结果：合法则 [error] 为 null。
class DriveSyncValidation {
  const DriveSyncValidation(this.error);

  final String? error;

  bool get ok => error == null;
}

/// 任务校验（官方 `DriveSyncTaskListViewModel` 保存前那一套）：
/// 本/远端必填、远端必须在 Drive 根下、**同目录不能重复**、
/// **本地根之间不能互相包含**（否则一个文件被两个任务抢）。
DriveSyncValidation validateDriveSyncTask(
  DriveSyncTask task,
  List<DriveSyncTask> existing,
) {
  if (task.localRoot.trim().isEmpty) {
    return DriveSyncValidation(
      driveGap('driveSyncNeedLocalFolder', '请选择本地文件夹'),
    );
  }
  if (task.remoteRoot.trim().isEmpty) {
    return DriveSyncValidation(
      driveGap('driveSyncNeedRemoteFolder', '请选择远端文件夹'),
    );
  }
  if (!normalizeDriveRemoteRoot(task.remoteRoot).startsWith('/')) {
    return DriveSyncValidation(
      driveGap('driveSyncRemoteMustStartSlash', '远端路径要以 / 开头'),
    );
  }
  final local = normalizeDriveLocalRoot(task.localRoot);
  final remote = normalizeDriveRemoteRoot(task.remoteRoot);
  for (final other in existing) {
    if (other.id == task.id || other.deleted) continue;
    if (normalizeDriveRemoteRoot(other.remoteRoot) == remote) {
      return const DriveSyncValidation('这个远端目录已经被另一个同步任务占用');
    }
    final o = normalizeDriveLocalRoot(other.localRoot);
    if (o == local || o.startsWith('$local/') || local.startsWith('$o/')) {
      return const DriveSyncValidation('本地目录不能与已有任务互相包含');
    }
  }
  if (task.autoSyncEnabled && task.autoSyncInterval <= 0) {
    return DriveSyncValidation(
      driveGap('driveSyncIntervalPositive', '自动同步间隔要大于 0 分钟'),
    );
  }
  return const DriveSyncValidation(null);
}

/// 本地路径归一化（去尾斜杠、统一分隔符）
String normalizeDriveLocalRoot(String p) {
  var s = p.trim().replaceAll('\\', '/');
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 远端路径归一化（与 Drive 的 `/mydrive` 编码一致，去掉尾斜杠）
String normalizeDriveRemoteRoot(String p) {
  var s = p.trim();
  if (s.isEmpty) return s;
  if (!s.startsWith('/')) s = '/$s';
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

// ------------------------------------------------------------ 差异决策（纯函数）

enum DriveSyncActionKind {
  upload('upload', '上传'),
  download('download', '下载'),
  removeLocal('removeLocal', '删本地'),
  removeRemote('removeRemote', '删远端'),
  renameLocal('renameLocal', '本地生成冲突副本'),
  skip('skip', '跳过');

  const DriveSyncActionKind(this.wire, this.label);
  final String wire;
  final String label;
}

/// 本地侧的一个条目（`SyncRunner` 的扫描结果）
class DriveSyncLocalEntry {
  const DriveSyncLocalEntry({
    required this.path,
    required this.isDir,
    required this.size,
    required this.modifiedMs,
    this.hash = '',
  });

  /// 相对本地根的路径（`a/b.txt`）
  final String path;
  final bool isDir;
  final int size;
  final int modifiedMs;
  final String hash;
}

/// 远端侧的一个条目（来自 `Files/list`）
class DriveSyncRemoteEntry {
  const DriveSyncRemoteEntry({
    required this.path,
    required this.isDir,
    required this.size,
    required this.modifiedMs,
    this.changeId = '',
  });

  final String path;
  final bool isDir;
  final int size;
  final int modifiedMs;
  final String changeId;
}

class DriveSyncAction {
  const DriveSyncAction(this.kind, this.path, this.reason);

  final DriveSyncActionKind kind;
  final String path;
  final String reason;
}

class DriveSyncDiff {
  const DriveSyncDiff(this.actions);

  final List<DriveSyncAction> actions;

  int get uploads => _count(DriveSyncActionKind.upload);
  int get downloads => _count(DriveSyncActionKind.download);
  int get removes => _count(DriveSyncActionKind.removeLocal) +
      _count(DriveSyncActionKind.removeRemote);
  int get conflicts => _count(DriveSyncActionKind.renameLocal);
  bool get isEmpty => actions.every((a) => a.kind == DriveSyncActionKind.skip);

  int _count(DriveSyncActionKind k) =>
      actions.where((a) => a.kind == k).length;
}

/// **同步决策**：官方 `SyncRunner` 的 `doUpload/doDownload/doRemoveLocal/
/// doRemoveRemote/doRenameLocal` 的判定层（纯函数，不碰 IO）。
///
/// 规则（与官方语义一致）：
///   * 只有本地有 → `upload`；只有远端有 → `download`（但
///     `ignore_local_remove` 为真时**不**因本地缺失就删远端，改为网络优先）；
///   * 两边都有且"看起来一样"（大小 + 修改时间）→ 跳过；
///   * 两边都有但不一样：`keepLatest` → 新者胜；`rename` → 本地留冲突副本；
///   * 超过 `limit_size`（>0 时）→ 跳过并给理由。
DriveSyncDiff planDriveSync({
  required List<DriveSyncLocalEntry> local,
  required List<DriveSyncRemoteEntry> remote,
  required DriveSyncTask task,
  int mtimeSlackMs = 2000,
}) {
  final actions = <DriveSyncAction>[];
  final byPath = <String, DriveSyncRemoteEntry>{
    for (final r in remote) r.path: r,
  };
  final oversized = task.limitSize > 0;

  for (final l in local) {
    if (l.isDir) continue;
    if (oversized && l.size > task.limitSize) {
      actions.add(
        DriveSyncAction(
          DriveSyncActionKind.skip,
          l.path,
          '超过 ${task.limitSize} 字节上限',
        ),
      );
      continue;
    }
    final r = byPath.remove(l.path);
    if (r == null) {
      actions.add(DriveSyncAction(DriveSyncActionKind.upload, l.path, '本地新增'));
      continue;
    }
    final same = l.size == r.size &&
        (l.modifiedMs - r.modifiedMs).abs() <= mtimeSlackMs;
    if (same) {
      actions.add(DriveSyncAction(DriveSyncActionKind.skip, l.path, '两端一致'));
      continue;
    }
    if (task.conflict == DriveSyncConflict.keepLatest) {
      final localNewer = l.modifiedMs >= r.modifiedMs;
      actions.add(
        DriveSyncAction(
          localNewer ? DriveSyncActionKind.upload : DriveSyncActionKind.download,
          l.path,
          localNewer
              ? driveGap('driveSyncLocalNewer', '本地较新')
              : driveGap('driveSyncRemoteNewer', '远端较新'),
        ),
      );
    } else {
      actions.add(
        DriveSyncAction(
          DriveSyncActionKind.renameLocal,
          l.path,
          '两端都改过 ⇒ 生成冲突副本',
        ),
      );
    }
  }

  for (final r in byPath.values) {
    if (r.isDir) continue;
    if (task.ignoreLocalRemove) {
      actions.add(
        DriveSyncAction(
          DriveSyncActionKind.download,
          r.path,
          '本地缺失但开启了"忽略本地删除" ⇒ 以远端为准',
        ),
      );
    } else {
      actions.add(
        DriveSyncAction(DriveSyncActionKind.removeRemote, r.path, '本地已删除'),
      );
    }
  }

  actions.sort((a, b) => a.path.compareTo(b.path));
  return DriveSyncDiff(actions);
}

/// 后台调度决策：这个任务**现在**该不该自动跑（官方按 `auto_sync_enabled`
/// + `auto_sync_interval` + 上次成功时间）。
bool driveSyncDue(DriveSyncTask task, DateTime now) {
  if (!task.autoSyncEnabled || task.deleted) return false;
  if (task.status == DriveSyncStatus.syncing) return false;
  if (task.lastSyncAtMs <= 0) return true;
  final elapsed = now.millisecondsSinceEpoch - task.lastSyncAtMs;
  return elapsed >= task.autoSyncInterval * 60 * 1000;
}

/// 到下一次该跑还有多久（给状态页显示；已经该跑回 0）。
Duration driveSyncNextIn(DriveSyncTask task, DateTime now) {
  if (!task.autoSyncEnabled || task.lastSyncAtMs <= 0) return Duration.zero;
  final due = task.lastSyncAtMs + task.autoSyncInterval * 60 * 1000;
  final left = due - now.millisecondsSinceEpoch;
  return Duration(milliseconds: math.max(0, left));
}

// ------------------------------------------------------------ 存储

/// 任务存储（官方是 Room `SyncDB`；我们用 JSON 文件 —— 键名与 Room 列一致）。
abstract class DriveSyncTaskStore {
  Future<List<DriveSyncTask>> load();
  Future<void> save(List<DriveSyncTask> tasks);
}

class MemoryDriveSyncTaskStore implements DriveSyncTaskStore {
  MemoryDriveSyncTaskStore([List<DriveSyncTask>? initial])
    : _tasks = [...?initial];

  List<DriveSyncTask> _tasks;

  /// 给用例断言"真的写进去了"
  List<DriveSyncTask> get snapshot => List.unmodifiable(_tasks);

  @override
  Future<List<DriveSyncTask>> load() async => List.of(_tasks);

  @override
  Future<void> save(List<DriveSyncTask> tasks) async => _tasks = [...tasks];
}

/// JSON 文件存储（默认落在应用文档目录；可注入路径 ⇒ 用例离线验证）
class JsonDriveSyncTaskStore implements DriveSyncTaskStore {
  JsonDriveSyncTaskStore(this.file);

  final File file;

  @override
  Future<List<DriveSyncTask>> load() async {
    if (!await file.exists()) return [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return [];
      return [
        for (final e in raw)
          if (e is Map)
            DriveSyncTask.fromJson(Map<String, Object?>.from(e)),
      ];
    } catch (_) {
      // 坏文件不该让整个页面打不开：当作空表（下次保存会覆盖）
      return [];
    }
  }

  @override
  Future<void> save(List<DriveSyncTask> tasks) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode([for (final t in tasks) t.toJson()]),
    );
  }
}
