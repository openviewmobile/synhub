// Drive G4 的 provider / 运行时编排（D21 计算机、D22 本地文件、
// D31 打包下载、D34 发送副本、D35 压缩并发送）。
//
// 本文件刻意放在 `features/drive/`（本批**只许改** `features/drive/**` 与
// `data/drive_api.dart`）；`features/files/drive_providers.dart` 属并行批次，
// 这里只**只读引用**它的 `driveApiProvider`。
//
// 能力门控沿用既有统一机制（`driveFilesCapabilityAvailable`，
// fail-open：未检测/网络失败不隐藏；只有能力表明确缺 API 才隐藏）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/provider_retry.dart';
import '../../data/drive_api.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../files/drive_providers.dart' show driveApiProvider;
import 'drive_send_bridge.dart';
import '../../core/user_facing_error.dart';

/// 计算机列表（D21）：`Files/list_backup_tasks` v3。
final driveComputersProvider =
    FutureProvider.autoDispose<({List<DriveEntryDto> items, int total})>((
      ref,
    ) async {
      final api = ref.watch(driveApiProvider);
      if (api == null) {
        throw StateError('not connected');
      }
      return api.listBackupTasks();
    }, retry: noRetry);

/// 把下载回来的字节**落成本地文件**并返回其绝对路径。
///
/// 抽成可注入签名是为了让离线用例不必碰 `path_provider` 的平台通道
/// （`flutter test` 里它永不返回，会把用例卡死）。
typedef DriveLocalWriter =
    Future<String> Function(String name, List<int> bytes);

/// 默认实现：写到应用临时目录的 `drive_transfer/` 子目录。
Future<String> defaultDriveLocalWriter(String name, List<int> bytes) async {
  final dir = await getTemporaryDirectory();
  final sub = Directory('${dir.path}/drive_transfer');
  if (!await sub.exists()) {
    await sub.create(recursive: true);
  }
  final file = File('${sub.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

final driveLocalWriterProvider = Provider<DriveLocalWriter>(
  (ref) => defaultDriveLocalWriter,
);

/// 一次「打包下载 / 发送副本 / 压缩并发送」的结果。
enum DriveTransferStatus { done, noHandler, failed }

/// 结果 + 给 UI 的消息（消息由 UI 层按语言取，这里只带原始错误串）。
class DriveTransferOutcome {
  const DriveTransferOutcome(this.status, [this.detail = '']);

  final DriveTransferStatus status;

  /// 失败原因 / 保存位置（UI 决定怎么展示）
  final String detail;

  bool get isDone => status == DriveTransferStatus.done;
}

/// G4 的**下载 + 落盘/分享**动作。所有依赖都可注入，因此完全离线可测。
class DriveTransferActions {
  DriveTransferActions({
    required this.api,
    required this.writer,
    required this.bridge,
  });

  final DriveApi api;
  final DriveLocalWriter writer;
  final DriveSendBridge bridge;

  /// 打包下载（D31）：多选/整目录 → 服务端打包 → 存进系统「下载」目录。
  ///
  /// 官方是**两段式**（`ArchiveHelper.archiveWithObservable`）：
  ///   1. `FileArchiveWork` → `Files/download {files, force_download, archive_name,
  ///      decrypt}` 拿 `task_id`；
  ///   2. 再把该任务下载成本地 `<fileName>.zip`（`ArchiveHelper.prepareTargetFile`
  ///      逐字是 `fileName + ".zip"`）。
  ///   3. 存进「下载」目录（原版 `DownloadFragment` 的 DOWNLOAD 语义）。
  Future<DriveTransferOutcome> saveArchive({
    required List<String> fileIds,
    required String archiveName,
  }) async {
    if (fileIds.isEmpty) {
      return const DriveTransferOutcome(
        DriveTransferStatus.failed,
        'empty-selection',
      );
    }
    final zipName = archiveName.endsWith('.zip')
        ? archiveName
        : '$archiveName.zip';
    try {
      final bytes = await _archiveBytes(fileIds, archiveName);
      final path = await writer(zipName, bytes);
      final uri = await bridge.saveToDownloads(
        path: path,
        name: zipName,
        mime: 'application/zip',
      );
      if (uri == null) {
        // 桥不可用 / 落盘被系统拒：**明确失败**，不装成功
        return DriveTransferOutcome(DriveTransferStatus.noHandler, path);
      }
      return DriveTransferOutcome(DriveTransferStatus.done, zipName);
    } catch (e) {
      return DriveTransferOutcome(DriveTransferStatus.failed, userFacingError(e));
    }
  }

  /// 压缩并发送（D35）：与 [saveArchive] 同样的打包字节，但走 `ACTION_SEND`
  /// 分享面板（官方 `FileAction.ArchiveAndSend` + `Intent.createChooser`）。
  Future<DriveTransferOutcome> shareArchive({
    required List<String> fileIds,
    required String archiveName,
  }) async {
    if (fileIds.isEmpty) {
      return const DriveTransferOutcome(
        DriveTransferStatus.failed,
        'empty-selection',
      );
    }
    final zipName = archiveName.endsWith('.zip')
        ? archiveName
        : '$archiveName.zip';
    try {
      final bytes = await _archiveBytes(fileIds, archiveName);
      final path = await writer(zipName, bytes);
      final ok = await bridge.share(
        path: path,
        name: zipName,
        mime: 'application/zip',
      );
      return ok
          ? DriveTransferOutcome(DriveTransferStatus.done, zipName)
          : DriveTransferOutcome(DriveTransferStatus.noHandler, path);
    } catch (e) {
      return DriveTransferOutcome(DriveTransferStatus.failed, userFacingError(e));
    }
  }

  /// 发送副本（D34）：把**单个**条目下载成本地文件后交给系统分享面板
  /// （官方 `FileAction.SendACopy` → `KtUtils` 的 `ACTION_SEND`；
  /// 目标文件由 `Files/download` 的 `force_download=true` 保证是原文件字节）。
  Future<DriveTransferOutcome> sendCopy({required DriveEntryDto entry}) async {
    try {
      final url = api.downloadUrl(fileId: entry.fileId);
      final bytes = await api.api.getBytes(url);
      final name = entry.name.isEmpty ? 'download' : entry.name;
      final path = await writer(name, bytes);
      final ok = await bridge.share(
        path: path,
        name: name,
        mime: 'application/octet-stream',
      );
      return ok
          ? DriveTransferOutcome(DriveTransferStatus.done, name)
          : DriveTransferOutcome(DriveTransferStatus.noHandler, path);
    } catch (e) {
      return DriveTransferOutcome(DriveTransferStatus.failed, userFacingError(e));
    }
  }

  /// 打包字节：先走官方**一段式**（`Files/download` 带 `archive_name` 的
  /// 可续传下载，即 `ApiSynoDriveFiles.setAsDownload` 的 `archive_name` 变体，
  /// `FileDownloadWork` 下载目录/多选时用的就是它）；一段式失败才回落官方
  /// **两段式**（`setAsArchiveFiles` 建任务 → 按 `task_id` 取，
  /// `ArchiveHelper.archiveWithObservable` 用的那条）。两条路的参数都逐字来自
  /// 反编译原文，**没有猜测字段**。
  Future<Uint8List> _archiveBytes(
    List<String> fileIds,
    String archiveName,
  ) async {
    final direct = api.archiveDownloadUrl(
      fileIds: fileIds,
      archiveName: archiveName,
    );
    try {
      final bytes = await api.api.getBytes(direct);
      return Uint8List.fromList(bytes);
    } catch (_) {
      // 一段式不认 → 走两段式（建任务失败时它自己会抛真实错误）
    }
    final taskId = await api.createArchiveTask(
      fileIds: fileIds,
      archiveName: archiveName,
    );
    final url = api.archiveTaskDownloadUrl(taskId: taskId);
    final bytes = await api.api.getBytes(url);
    return Uint8List.fromList(bytes);
  }
}

/// 未连接时为 `null`（页面显示"未连接"而不是崩）。
final driveTransferActionsProvider = Provider<DriveTransferActions?>((ref) {
  final api = ref.watch(driveApiProvider);
  if (api == null) return null;
  return DriveTransferActions(
    api: api,
    writer: ref.watch(driveLocalWriterProvider),
    bridge: ref.watch(driveSendBridgeProvider),
  );
});
