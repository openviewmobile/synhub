// `SYNO.FileStation.PhotoUpload / upload` 的回包模型。
//
// 真机正向样本（本会话只读探针，**空文件**上传到已存在的共享根 `/home`；已当场删除残留）：
// ```json
// {"data":{"blSkip":false,"file":"probe_dsh.bin","pid":31101,"progress":1},"success":true}
// ```
// ⇒ `data` 里是**上传进度句柄**，不是最终文件条目：
//   * `file`  —— 文件名（**不是**路径）；
//   * `pid`   —— 服务端上传进程号（内部 id，**不上屏**）；
//   * `progress` / `blSkip` —— 进度与"是否因冲突被跳过"。
//
// 反例（同一探针）：
//   * `path` 不存在 → `{"error":{"code":408}}`（路径不存在，不是参数错）；
//   * 声明 `size` 与实际字节数不符 → `{"error":{"code":414}}`。
class FilePhotoUploadResult {
  const FilePhotoUploadResult({
    this.fileName,
    this.pid,
    this.progress,
    this.skipped = false,
  });

  /// 服务端回带的上传文件名。
  final String? fileName;

  /// 服务端上传进程号 —— **内部 id，绝不上屏**（规程 §4.3）。
  final int? pid;

  /// 进度（真机 `1`；语义未取证，只原样保留）。
  final int? progress;

  /// `blSkip` —— 因同名冲突被跳过（配合 `overwrite` 策略）。
  final bool skipped;

  static FilePhotoUploadResult fromJson(Map<String, dynamic> json) {
    final raw = json['file'];
    return FilePhotoUploadResult(
      fileName: raw == null ? null : '$raw',
      pid: json['pid'] is num ? (json['pid'] as num).toInt() : null,
      progress: json['progress'] is num
          ? (json['progress'] as num).toInt()
          : null,
      skipped: json['blSkip'] == true,
    );
  }
}
