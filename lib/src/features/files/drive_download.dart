// ★ D26：**Drive 下载的断点续传**（官方 `ConnectionManager` 的 Range 语义）。
//
// ## 官方逐字证据（Drive 3.9.0-1113 反编译，`sylib` 就在官方 APK 里）
//
// `smali_classes4/com/synology/sylib/syapi/webapi/net/ConnectionManager.smali`：
//   * `:27` `HEADER_RANGE = "RANGE"`；
//   * `:301-309`（可恢复下载 `isTypeRecoverable`）：
//     `file = File(getDownloadFileName())` → `file.length()` →
//     日志 `"Set range header to <len>"` → `putHeader("RANGE", "bytes=<len>-")`；
//     不可恢复时用 `File.createTempFile("temp.", ".download", cacheDir)`；
//   * `:659-667`（`copy`）：`RandomAccessFile(file, "rw")`，
//     **若 headers 里含 `RANGE` 则 `seek(file.length())`**，否则从 0 写；
//   * `:328-331` 下载出错时**删掉**该临时文件。
//   ⇒ 续传 = 「本地残留长度 → `Range: bytes=<len>-` → seek 到同一偏移继续写」。
//
// ## 为什么复用 FileStation 的引擎
//
// `file_download_resume.dart` 的 [FileDownloadResumer] 就是照官方
// `DownloadTask` 做的（`.sydownload` 临时文件 + Range + 206 校验 + 诚实降级），
// 它**只吃一个 URL**，与是 Drive 还是 FileStation 无关。
// 之前 Drive 的「下载」走 `api.getBytes(url)`：整份进内存、无进度、无暂停、
// 断了从头再来 —— 这正是 D26 记 ❌ 的原因；这里把它接进同一条引擎与
// **同一个任务列表**（进度 / 暂停 / 继续 / 取消 / 重试 / 完成后打开）。
//
// §5.1：本文件只做**读**（HTTP GET / Range GET），没有任何变更动词。
import 'package:flutter/material.dart';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/media/cache_service.dart' show humanBytes;
import '../../core/system_open.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../drive/drive_c1_text.dart';
import 'office_export.dart' show officeDownloadDirProvider;
import 'file_download.dart';
import 'file_download_resume.dart';
import 'file_download_tasks.dart';
import 'file_providers.dart';
import 'filestation_p0b_text.dart';

/// Drive 文件下载的**落点/来源标签**（同时是续传元数据的 key 前缀）。
///
/// `drive` = Drive 直链（`Files/download`，工程文件会被转码成 OOXML/PDF）；
/// `native` = FileStation 真实路径的原生字节（`.osheet` 这类只有这条才是原文件）。
enum DriveDownloadChannel { drive, native }

/// **核心**：把一次 Drive 下载交给 [FileDownloadTaskList]（断点续传引擎）。
///
/// 依赖全部显式传入（`list` / `fetcher` / `store` / `directory`）——
/// 这样**纯离线单测**可以直接构造，不必搭 widget 树；
/// 界面侧用 [downloadResumableWithUi] 从 `ref` 里取这些依赖。
///
/// [resumeKey] 是续传元数据的 key：**同一条目 + 同一条通道**才算同一份下载
/// （Drive 直链与 FileStation 原生字节是两份不同内容，不能互相续）。
Future<FileDownloadResult> downloadResumable({
  required FileDownloadTaskList list,
  required RangeByteFetcher fetcher,
  required Directory directory,
  required String resumeKey,
  required String url,
  required String saveName,
}) async {
  final task = list.start(
    sourcePath: resumeKey,
    name: saveName,
    runner: (path, {required FileDownloadSession session}) async {
      return FileDownloadResumer(
        fetcher: fetcher,
        store: FileResumeStore(directory),
      ).download(
        sourcePath: resumeKey,
        url: url,
        fileName: saveName,
        directory: directory,
        onProgress: session.report,
        cancelToken: session.cancelToken,
        // ★ DA100：问「这次取消是不是暂停引起的」，而不是「现在还在暂停吗」
        isPaused: () => session.pauseRequestedForInFlightRequest,
      );
    },
  );

  await task.settled;
  // 与 FileStation 的 `downloadFileEntry` **逐字同构**：ok 的 message 是
  // 「状态说明」（续传/整份重下），不是路径；路径走 `task.localPath`。
  switch (task.status) {
    case FileDownloadTaskStatus.cancelled:
      return const FileDownloadResult(FileDownloadStatus.cancelled);
    case FileDownloadTaskStatus.failed:
      return FileDownloadResult(FileDownloadStatus.failed, task.error);
    case FileDownloadTaskStatus.done:
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

/// 上一次下载的落盘路径（任务列表里按文件名找最新完成的那条）。
///
/// 不把路径塞进 [FileDownloadResult.message]：那条约定在 FileStation 侧是
/// 「状态说明」（续传/整份重下），两处必须同构。
Future<String> _lastDownloadPath(WidgetRef ref, String name) async {
  final dir = await ref.read(officeDownloadDirProvider)();
  return '${dir.path}/$name';
}

/// 下载 + 提示 +（可选）打开的**界面侧总入口**（Drive 源）。
///
/// 与 FileStation 的 `downloadFileEntry` 同构：任务列表里能看到进度、能暂停、
/// 能从断点继续；完成后按 [openAfter] 决定是否交给系统应用。
Future<void> downloadResumableWithUi(
  BuildContext context,
  WidgetRef ref, {
  required String resumeKey,
  required String url,
  required String saveName,
  required String usageName,
  int usageSize = 0,
  DriveDownloadChannel channel = DriveDownloadChannel.drive,
  bool transcoded = false,
  bool openAfter = false,
}) async {
  final t = context.t;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final list = ref.read(fileDownloadTaskListProvider);
    // 先碰 context（开任务列表），再 await —— 避免"跨 await 用 context"
    if (!list.dialogOpen) {
      openFileDownloadTasksDialog(context, list);
    }
    final directory = await ref.read(officeDownloadDirProvider)();
    final result = await downloadResumable(
      list: list,
      fetcher: ref.read(rangeByteFetcherProvider),
      directory: directory,
      resumeKey: resumeKey,
      url: url,
      saveName: saveName,
    );
    switch (result.status) {
      case FileDownloadStatus.cancelled:
        return;
      case FileDownloadStatus.failed:
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              t.fileDownloadFailed(describeFileError(result.message ?? '')),
            ),
          ),
        );
        return;
      case FileDownloadStatus.ok:
        trackFile(
          ref,
          UsageModule.drive,
          UsageAction.download,
          usageName,
          size: usageSize,
          detail: {
            'open_after': openAfter,
            'channel': channel.name,
            if (result.restarted) 'full_restart': true,
          },
        );
        if (openAfter) {
          await ref.read(systemOpenProvider)(
            await _lastDownloadPath(ref, saveName),
          );
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              transcoded
                  ? driveC1Fill(
                      'officeDownloadConvertedNotice',
                      '已转换为 Office 格式：保存为 {name}',
                      {'name': saveName},
                    )
                  : (openAfter
                        ? t.photoOpenedWith(saveName)
                        : t.driveDownloaded(saveName)),
            ),
          ),
        );
        return;
    }
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(t.fileDownloadFailed(describeFileError(e)))),
    );
  }
}
