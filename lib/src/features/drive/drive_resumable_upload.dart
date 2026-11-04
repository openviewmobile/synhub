// ★ **③Drive 第 51 轮：D24 —— 把分片续传做成"可复用的服务"，逐字对齐官方两步流程**
//
// ## 官方模型（`FileUploadRecoverableWork.java:99-135`，本轮已核对）
//
// 官方**不是**客户端分片循环，而是**两步顺序工作**：
//
// ```
// onPrepareRequestWork(index):
//   index 0 → 若 recoverableSupported:
//               建 dummy 文件 → FileUploadedSizeWork(taskId, dummyFile)
//               建 dummy 失败 ⇒ mOffset = -1（回落普通上传）
//   index 1 → FileUploadWork(..., getOffset(), taskId)   // 一次传完 offset 之后
//
// onDoneRequestWork(index 0):
//   mOffset = FileUploadedSizeWork.getUploadedSize()
//
// getOffset():
//   if (!recoverableSupported || taskType.isOCR()) return -1L
//   return mOffset
// ```
//
// ⇒ **"分片"来自重试**：每次重试都重新探测已收字节，从那里续。
// 客户端自己**不切块**。
//
// ## 为什么把它抽成独立服务而不是塞进 Widget
// 这段逻辑有三条**容易写错且错得很安静**的路径：
// ① 能力位为假时**必须**走普通上传（不是报错）；
// ② 探测**失败**时要回落 `offset = -1`（官方就是这么做，不是抛给用户）；
// ③ 探测回来 `offset >= total` 说明**服务端已经收完了** ⇒ 不能再传一遍。
// 放在 Widget 里就测不到这三条。本文件把它们做成纯函数/纯服务，
// 由 `test/drive_resumable_upload_service_test.dart` 直接钉。
//
// ⚠️ 本文件**不上传任何字节**给真机，只编排 [DriveApi] 的调用；
// 真机调用由调用方决定（本轮只接 Mock）。
import 'dart:io';

import '../../data/drive_api.dart';

/// 一次续传编排的结果。
typedef DriveResumableUploadOutcome = ({
  /// 真正发出去的那次请求用的 offset（`-1` 表示走了普通整文件上传）
  int offset,

  /// 文件 id
  String id,

  /// 服务端回的文件哈希（可能为空）
  String hash,

  /// 是否走了分片续传分支
  bool resumed,
});

/// 判断一个文件**该不该**走分片续传。
///
/// 官方判据（`FileUploadRecoverableWork.getOffset()`）：只有
/// `recoverableSupported`（= `Files.maxVersion >= 9`，见 [DriveApi.isSupportRecoverableTransfer]）
/// 才返回真实 offset；否则返回 `-1L` ⇒ 走普通上传。
///
/// [thresholdBytes] 是"多小算小文件"的本地阈值 —— 官方没有这个判断
/// （它一律先探测），但**每次上传都多发一个探测请求**对 KB 级文件是纯浪费，
/// 而且会让服务端多建一个临时任务。所以这里保守地只对大文件启用。
/// ⚠️ 这是**我方策略选择**，不是官方行为，故写成参数便于调整与说明。
bool shouldResumeUpload({
  required int fileSizeBytes,
  required bool serverSupportsRecoverable,
  int thresholdBytes = 5 * 1024 * 1024,
}) => serverSupportsRecoverable && fileSizeBytes >= thresholdBytes;

/// 按官方两步流程做一次**可续传上传**。
///
/// 流程（与官方 `FileUploadRecoverableWork` 一一对应）：
/// 1. 不满足条件 ⇒ `offset = -1`，走 [DriveApi.uploadFile]（普通整文件）；
/// 2. 满足 ⇒ 建临时 dummy 文件 → [DriveApi.getUploadedSize] 探测；
///    * 探测**抛异常** ⇒ `offset = -1` 回落普通上传（官方 `mOffset = -1`）；
///    * 探测回 `offset >= total` ⇒ 服务端已收完，**不再重传**，返回 `resumed: true`；
///    * 否则 ⇒ 带 `offset` 调 [DriveApi.uploadChunk]（一次传完余量）。
///
/// [tempDir] 用于放 dummy 文件；为空时用系统临时目录。dummy 必定被删除。
Future<DriveResumableUploadOutcome> driveResumableUpload(
  DriveApi drive, {
  required String folderId,
  required String filePath,
  required String fileName,
  required String taskId,
  int? modifiedTimeSeconds,
  String conflictAction = 'version',
  bool mute = false,
  String? sharingToken,
  String? mimeType,
  void Function(int sent, int total)? onProgress,
  String? tempDir,
  int thresholdBytes = 5 * 1024 * 1024,
}) async {
  final size = File(filePath).lengthSync();
  final canResume = shouldResumeUpload(
    fileSizeBytes: size,
    serverSupportsRecoverable: drive.isSupportRecoverableTransfer,
    thresholdBytes: thresholdBytes,
  );

  var offset = -1;
  if (canResume) {
    offset = await _probeOffset(
      drive,
      taskId: taskId,
      tempDir: tempDir,
      fileName: fileName,
    );
    // 探测到一个"已经 >= 全长的偏移"：服务端其实收完了。
    if (offset >= size) {
      return (offset: offset, id: '', hash: '', resumed: true);
    }
  }

  // ---- 普通整文件分支（官方 offset <= -1 那条）----
  // 官方在这里走 `FileUploadWork`（`Files/upload`，版本 `min(8,maxVersion)`）。
  // 第 52 轮已实现 [DriveApi.uploadFile]，所以**不再**抛 FallbackRequired。
  if (offset <= -1) {
    final r = await drive.uploadFile(
      folderId: folderId,
      filePath: filePath,
      fileName: fileName,
      modifiedTimeSeconds: modifiedTimeSeconds,
      conflictAction: conflictAction,
      mute: mute,
      sharingToken: sharingToken,
      mimeType: mimeType,
      onProgress: onProgress,
    );
    return (offset: -1, id: r.id, hash: r.hash, resumed: false);
  }

  final r = await drive.uploadChunk(
    folderId: folderId,
    filePath: filePath,
    fileName: fileName,
    taskId: taskId,
    offset: offset,
    modifiedTimeSeconds: modifiedTimeSeconds,
    conflictAction: conflictAction,
    mute: mute,
    sharingToken: sharingToken,
    mimeType: mimeType,
    onProgress: onProgress,
  );
  return (offset: offset, id: r.id, hash: r.hash, resumed: true);
}

/// 探测已收字节；**任何失败都回落 `-1`**（官方的 `mOffset = -1L` 语义）。
///
/// 官方在 `onPrepareRequestWork` 里对 dummy 文件的创建整体 try/catch，
/// 失败就 `mOffset = -1L` 并返回 `DummyWork` —— 也就是说
/// **"探测不了"不是错误，只是没得续**。这里保持一致。
Future<int> _probeOffset(
  DriveApi drive, {
  required String taskId,
  required String fileName,
  String? tempDir,
}) async {
  // dummy 文件名带上 taskId，避免并发上传互相覆盖。
  final dir = tempDir ?? Directory.systemTemp.path;
  final dummy = File('$dir/.drive-upload-dummy-$taskId');
  try {
    await dummy.writeAsBytes(const [0], flush: true);
  } catch (_) {
    return -1; // 官方：建 dummy 失败 ⇒ mOffset = -1
  }
  try {
    return await drive.getUploadedSize(
      taskId: taskId,
      dummyFilePath: dummy.path,
      dummyFileName: fileName,
    );
  } catch (_) {
    return -1; // 探测失败 ⇒ 回落普通上传，不打扰用户
  } finally {
    try {
      if (dummy.existsSync()) await dummy.delete();
    } catch (_) {
      // 删不掉不影响结果
    }
  }
}
