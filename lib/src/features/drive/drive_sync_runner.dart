// ★★★ ③Drive **D65「同步任务」的文件搬运执行器** —— 第 220 轮。
//
// 第 217 轮做了任务模型 / 存储 / 差异决策 / 界面；本轮把 `planDriveSync`
// 的结论**真的执行**掉：
//
//   `SyncRunner`（官方 smali）的四个动作 → 本文件的四个 IO 原语
//     doUpload       → `upload`
//     doDownload     → `download`
//     doRemoveLocal  → `removeLocal`
//     doRemoveRemote → `removeRemote`
//     doRenameLocal  → `renameLocalConflict`（冲突副本）
//
// 设计要点（都是为了能**离线/Mock 验证**）：
//   * IO 抽成两个接口（`DriveSyncRemoteIo` / `DriveSyncLocalIo`），
//     执行器只做"按计划派发 + 单条失败不影响其他条"；
//   * 真实实现各一份：`LocalDriveSyncIo`（dart:io）与 `DriveApiSyncIo`
//     （走**已 Mock 核实**的 `Files/{get,create,upload,delete}` + `downloadUrl`）；
//   * ⚠️ 仍**没有**后台常驻文件监听（官方 `DriveFileWatchService`）——
//     台账保持 🟠，只把"执行器"这块补上。
import 'dart:io';

import '../../data/drive_api.dart';
import '../../dsm/webapi.dart' show DsmApiException;
import 'drive_gaps_text.dart';
import 'drive_sync_task.dart';

/// 远端（Drive）侧的 IO 原语，路径一律是**相对任务远端根的相对路径**。
abstract class DriveSyncRemoteIo {
  /// 确保相对目录存在（父子都建）；返回末级目录的 file_id。
  Future<String> ensureFolder(String relDir);

  Future<void> upload({
    required String localPath,
    required String relPath,
  });

  Future<void> download({
    required String relPath,
    required String localPath,
  });

  Future<void> removeRemote(String relPath);
}

/// 本地侧的 IO 原语。
abstract class DriveSyncLocalIo {
  Future<void> removeLocal(String relPath);

  /// 冲突副本：`报告.docx` → `报告 (冲突 20261001-120000).docx`
  Future<String> renameLocalConflict(String relPath, String stamp);

  String absolutePath(String relPath);
}

class DriveSyncActionOutcome {
  const DriveSyncActionOutcome({
    required this.action,
    required this.ok,
    this.error,
  });

  final DriveSyncAction action;
  final bool ok;
  final String? error;
}

class DriveSyncRunResult {
  const DriveSyncRunResult(this.outcomes);

  final List<DriveSyncActionOutcome> outcomes;

  int get executed => outcomes.where((o) => o.ok).length;
  int get failed =>
      outcomes.where((o) => !o.ok).length;
  bool get allOk => failed == 0;

  /// 失败了哪些（给界面显示）
  List<DriveSyncActionOutcome> get failures =>
      outcomes.where((o) => !o.ok).toList();
}

/// **执行**一次同步计划。单条失败**不中断**其余（官方的 `SyncRunner` 也是
/// 逐条推进并记录错误），失败原因原样带回给界面。
class DriveSyncExecutor {
  const DriveSyncExecutor({required this.remote, required this.local});

  final DriveSyncRemoteIo remote;
  final DriveSyncLocalIo local;

  Future<DriveSyncRunResult> run(
    DriveSyncDiff diff, {
    String stamp = '',
    void Function(DriveSyncAction action, int done, int total)? onProgress,
  }) async {
    final todo = diff.actions
        .where((a) => a.kind != DriveSyncActionKind.skip)
        .toList();
    final out = <DriveSyncActionOutcome>[];
    final s = stamp.isEmpty ? _defaultStamp() : stamp;
    for (var i = 0; i < todo.length; i++) {
      final a = todo[i];
      onProgress?.call(a, i, todo.length);
      try {
        await _one(a, s);
        out.add(DriveSyncActionOutcome(action: a, ok: true));
      } catch (e) {
        out.add(
          DriveSyncActionOutcome(action: a, ok: false, error: '$e'),
        );
      }
    }
    onProgress?.call(
      todo.isEmpty
          ? const DriveSyncAction(DriveSyncActionKind.skip, '', '')
          : todo.last,
      todo.length,
      todo.length,
    );
    return DriveSyncRunResult(out);
  }

  Future<void> _one(DriveSyncAction a, String stamp) async {
    final dir = _parentOf(a.path);
    switch (a.kind) {
      case DriveSyncActionKind.upload:
        // 先保证相对目录在远端存在，再传文件
        await remote.ensureFolder(dir);
        await remote.upload(
          localPath: local.absolutePath(a.path),
          relPath: a.path,
        );
      case DriveSyncActionKind.download:
        await remote.download(
          relPath: a.path,
          localPath: local.absolutePath(a.path),
        );
      case DriveSyncActionKind.removeLocal:
        await local.removeLocal(a.path);
      case DriveSyncActionKind.removeRemote:
        await remote.removeRemote(a.path);
      case DriveSyncActionKind.renameLocal:
        await local.renameLocalConflict(a.path, stamp);
      case DriveSyncActionKind.skip:
        break;
    }
  }

  static String _parentOf(String relPath) {
    final i = relPath.lastIndexOf('/');
    return i < 0 ? '' : relPath.substring(0, i);
  }

  static String _defaultStamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}-'
        '${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }
}

/// 冲突副本命名（单独抽出来 ⇒ 用例能钉住格式）
String driveSyncConflictName(String relPath, String stamp) {
  final slash = relPath.lastIndexOf('/');
  final dir = slash < 0 ? '' : relPath.substring(0, slash + 1);
  final name = slash < 0 ? relPath : relPath.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  final base = dot <= 0 ? name : name.substring(0, dot);
  final ext = dot <= 0 ? '' : name.substring(dot);
  return driveGapFill(
    'driveSyncConflictDupName',
    '{dir}{base} (冲突 {stamp}){ext}',
    {'dir': dir, 'base': base, 'stamp': stamp, 'ext': ext},
  );
}

// ------------------------------------------------------------ 真实实现

/// `dart:io` 实现（本地根 + 相对路径）
class LocalDriveSyncIo implements DriveSyncLocalIo {
  const LocalDriveSyncIo(this.root);

  final String root;

  @override
  String absolutePath(String relPath) =>
      '${normalizeDriveLocalRoot(root)}/$relPath';

  @override
  Future<void> removeLocal(String relPath) async {
    final f = File(absolutePath(relPath));
    if (await f.exists()) {
      await f.delete();
      return;
    }
    final d = Directory(absolutePath(relPath));
    if (await d.exists()) await d.delete(recursive: true);
  }

  @override
  Future<String> renameLocalConflict(String relPath, String stamp) async {
    final target = File(absolutePath(driveSyncConflictName(relPath, stamp)));
    await target.parent.create(recursive: true);
    await File(absolutePath(relPath)).rename(target.path);
    return target.path;
  }
}

/// `DriveApi` 实现。远端路径 → file_id 的解析走 `Files/get`（官方语义），
/// 目录不存在时 `Files/create`（`type=dir`）；上传/删除走既有已核实接口。
class DriveApiSyncIo implements DriveSyncRemoteIo {
  DriveApiSyncIo(this.api, {required this.remoteRoot});

  final DriveApi api;
  final String remoteRoot;

  @override
  Future<String> ensureFolder(String relDir) async {
    if (relDir.isEmpty) {
      // 任务远端根自身
      final root = await api.get(path: normalizeDriveRemoteRoot(remoteRoot));
      return root.fileId;
    }
    var current = normalizeDriveRemoteRoot(remoteRoot);
    var id = '';
    for (final part in relDir.split('/').where((e) => e.isNotEmpty)) {
      current = '$current/$part';
      try {
        id = (await api.get(path: current)).fileId;
      } on DsmApiException catch (e) {
        // 不存在就建（官方 `Files/create` type=dir）
        if (e.code == 0 || e.code == 1000 || e.code == 408) {
          id = (await api.createFolder(path: current)).fileId;
        } else {
          rethrow;
        }
      }
    }
    return id;
  }

  @override
  Future<void> upload({
    required String localPath,
    required String relPath,
  }) async {
    final dir = relPath.contains('/')
        ? relPath.substring(0, relPath.lastIndexOf('/'))
        : '';
    final folderId = await ensureFolder(dir);
    final name = relPath.split('/').last;
    await api.uploadFile(
      folderId: folderId,
      filePath: localPath,
      fileName: name,
      conflictAction: 'version',
    );
  }

  @override
  Future<void> download({
    required String relPath,
    required String localPath,
  }) async {
    final entry = await api.get(
      path: '${normalizeDriveRemoteRoot(remoteRoot)}/$relPath',
    );
    final bytes = await api.api.getBytes(
      api.downloadUrl(fileId: entry.fileId, isPreview: false),
    );
    final f = File(localPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  @override
  Future<void> removeRemote(String relPath) async {
    final entry = await api.get(
      path: '${normalizeDriveRemoteRoot(remoteRoot)}/$relPath',
    );
    await api.delete(fileIds: [entry.fileId]);
  }
}
