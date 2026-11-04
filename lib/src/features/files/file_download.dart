// 文件下载的公共入口：**多任务列表**（进度 / 暂停 / 继续 / 取消 / 重试 / 完成后打开）
// + 断点续传 + 落盘。
//
// W1-3 起这里不再是一次性的模态进度框，而是把任务交给
// `file_download_tasks.dart` 的 `FileDownloadTaskList`：
//   * 多个下载共存、互不覆盖（并发 1，其余排队）；
//   * 失败可**重试**、完成后可**点开**；
//   * 传输仍然复用既有引擎（`.sydownload` 临时文件 + `.resume.json` + `Range`），
//     **没有**另造一套下载。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/media/cache_service.dart' show humanBytes;
import '../../core/system_open.dart';
import '../../data/dto/file_entry_dto.dart';
import 'file_download_resume.dart';
import 'file_download_tasks.dart';
import 'file_providers.dart';
import 'filestation_p0b_text.dart';

/// 下载结果：给调用方决定怎么提示。
enum FileDownloadStatus {
  ok,

  /// 用户自己点了取消
  cancelled,

  /// 失败，[FileDownloadResult.message] 是给用户看的文案
  failed,
}

class FileDownloadResult {
  const FileDownloadResult(
    this.status, [
    this.message,
    this.restarted = false,
  ]);

  final FileDownloadStatus status;
  final String? message;

  /// 服务端不支持 Range → 本次是整份重下（调用方据此换文案）
  final bool restarted;

  bool get isOk => status == FileDownloadStatus.ok;
}

/// 把 [entry] 加入下载任务列表并等它结束。
///
/// 界面上是**一个共享的任务列表**（不是每来一个下载就叠一个进度框）：
/// 第二次下载时列表里会同时出现两条任务，前一条的进度不会被覆盖。
///
/// [openAfter] 为真时下完用系统应用打开。
Future<FileDownloadResult> downloadFileEntry(
  BuildContext context,
  FileEntryDto entry, {
  required FileActionsController actions,
  bool openAfter = false,
}) async {
  final list = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(fileDownloadTaskListProvider);
  final task = list.start(
    sourcePath: entry.path,
    name: entry.name,
    runner: (path, {required FileDownloadSession session}) =>
        actions.download(path, session: session),
  );
  if (!list.dialogOpen) {
    // 与文件页顶栏的常驻入口共用同一条打开路径（`dialogOpen` 去重，
    // 不会因为"入口 + 新下载"同时发生而叠两层列表）。
    openFileDownloadTasksDialog(context, list);
  }

  await task.settled;
  switch (task.status) {
    case FileDownloadTaskStatus.cancelled:
      return const FileDownloadResult(FileDownloadStatus.cancelled);
    case FileDownloadTaskStatus.failed:
      return FileDownloadResult(FileDownloadStatus.failed, task.error);
    case FileDownloadTaskStatus.done:
      if (openAfter && (task.localPath?.isNotEmpty ?? false)) {
        await defaultSystemOpen(task.localPath!);
      }
      if (task.fullRestart) {
        return FileDownloadResult(
          FileDownloadStatus.ok,
          fsP0b(
            FsP0bTextKeys.downloadRestarted,
            '服务端不支持断点续传，已重新完整下载。',
          ),
          true,
        );
      }
      if (task.resumedFrom > 0) {
        return FileDownloadResult(
          FileDownloadStatus.ok,
          fsP0bFill(FsP0bTextKeys.downloadResumed, '已从 {size} 处继续下载。', {
            'size': humanBytes(task.resumedFrom),
          }),
        );
      }
      return const FileDownloadResult(FileDownloadStatus.ok);
    case FileDownloadTaskStatus.queued:
    case FileDownloadTaskStatus.running:
    case FileDownloadTaskStatus.paused:
      // `settled` 只在终态完成 → 这里不可达（穷尽 switch 用）
      return const FileDownloadResult(FileDownloadStatus.ok);
  }
}
