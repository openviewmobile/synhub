// Drive **G4 批次**（D21 计算机 / D22 本地文件 / D31 打包下载 /
// D34 发送副本 / D35 压缩并发送 / D40 公开链接密码校验 / D72 备份日期分层）
// 新增界面文案：**key + 中文原文**，与 `drive_wave2_text.dart` /
// `drive_c1_text.dart` 同构。
//
// 为什么不用 `context.t`：这些 key 已经**同步追加进**
// `lib/l10n/app_zh.arb` / `app_en.arb`，`setCurrentText` 注入的翻译表会自动
// 把中文原文换成当前语言译文；取不到就回落中文（`dataText` 约定）。
// 带 `{...}` 的一律走 [driveG4Fill]，绝不把占位符当字面量送进 UI。
import '../../core/i18n/data_text.dart';

/// 取 G4 新文案（key 见 [DriveG4TextKeys]）
String driveG4(String key, String zh) => dataText(key, zh);

/// 带 `{...}` 占位符的文案填充
String driveG4Fill(String key, String zh, Map<String, String> values) {
  var out = driveG4(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// G4 新增的 ARB key（已同步进 `app_zh.arb` / `app_en.arb`）
abstract final class DriveG4TextKeys {
  // ---- D21 计算机（`Files/list_backup_tasks` v3）
  static const computersTitle = 'driveG4ComputersTitle';
  static const computersEntry = 'driveG4ComputersEntry';
  static const computersEntrySubtitle = 'driveG4ComputersEntrySubtitle';
  static const computersEmpty = 'driveG4ComputersEmpty';
  static const computersEmptyBody = 'driveG4ComputersEmptyBody';
  static const computersLoadFailed = 'driveG4ComputersLoadFailed';
  static const computersCount = 'driveG4ComputersCount';
  static const computersDevice = 'driveG4ComputersDevice';

  // ---- D22 本地文件（客户端本地目录 → 上传 Drive）
  static const localFilesTitle = 'driveG4LocalFilesTitle';
  static const localFilesEntry = 'driveG4LocalFilesEntry';
  static const localFilesEntrySubtitle = 'driveG4LocalFilesEntrySubtitle';
  static const localFilesEmpty = 'driveG4LocalFilesEmpty';
  static const localFilesEmptyBody = 'driveG4LocalFilesEmptyBody';
  static const localFilesListFailed = 'driveG4LocalFilesListFailed';
  static const localFilesUnavailable = 'driveG4LocalFilesUnavailable';
  static const localFilesUnavailableBody = 'driveG4LocalFilesUnavailableBody';
  static const localFilesUpload = 'driveG4LocalFilesUpload';
  static const localFilesUploading = 'driveG4LocalFilesUploading';
  static const localFilesUploaded = 'driveG4LocalFilesUploaded';
  static const localFilesUploadFailed = 'driveG4LocalFilesUploadFailed';
  static const localFilesNotConnected = 'driveG4LocalFilesNotConnected';
  static const localFilesTarget = 'driveG4LocalFilesTarget';

  // ---- D31 / D35 打包下载 / 压缩并发送
  static const archiveTitle = 'driveG4ArchiveTitle';
  static const archiveDownload = 'driveG4ArchiveDownload';
  static const archiveDownloading = 'driveG4ArchiveDownloading';
  static const archiveNameLabel = 'driveG4ArchiveNameLabel';
  static const archiveSaveFailed = 'driveG4ArchiveSaveFailed';
  static const archiveSaved = 'driveG4ArchiveSaved';
  static const archiveShare = 'driveG4ArchiveShare';
  static const archiveShareFailed = 'driveG4ArchiveShareFailed';
  static const archiveNoHandler = 'driveG4ArchiveNoHandler';
  static const archiveNoSelection = 'driveG4ArchiveNoSelection';

  // ---- D34 发送副本
  static const sendCopy = 'driveG4SendCopy';
  static const sendCopySaved = 'driveG4SendCopySaved';

  // ---- D40 公开链接密码校验
  static const passwordVerifyTitle = 'driveG4PasswordVerifyTitle';
  static const passwordVerifyHint = 'driveG4PasswordVerifyHint';
  static const passwordVerifyAction = 'driveG4PasswordVerifyAction';
  static const passwordVerifyOk = 'driveG4PasswordVerifyOk';
  static const passwordVerifyBad = 'driveG4PasswordVerifyBad';
  static const passwordVerifyEmpty = 'driveG4PasswordVerifyEmpty';
}
