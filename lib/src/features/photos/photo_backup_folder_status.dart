// ★★★ D78「失败原因分类」—— 第 100 轮按**官方分类学**补齐证书/配额/权限分支。
//
// ## 官方证据（`SynologyDrive 3.9.0-1113`，smali 一级来源）
// * `com/synology/dsdrive/backup/BackupFolderStatus$Type.smali` —— **9 型**：
//   `Success / Init / NoNetwork / Error / CertificateMismatch /
//    MyDriveDisabled / BackupFolderBlock / DeviceFolderBlock / EndFolderBlock`
// * dex 字符串 `backup_status_*`：
//   `enabled`、`enabled_next_time`、`running`、
//   `wait_charge`、`wait_network`、`wait_wifi`、
//   `error_certificate`、`error_no_quota`、`error_no_permission`、
//   `error_general`、`error_unknown`
//
// ## 映射口径（每条都写依据；没有证据的不映射）
// * `HandshakeException` → certificateMismatch（TLS 握手失败即证书不匹配）；
// * `SocketException` → noNetwork（连不上即无网络）；
// * `DsmApiException 105` → noPermission（官方串 `backup_status_error_no_permission`）；
// * `DsmApiException 115`（notAllowUpload）→ noQuota：⚠️ **弱依据** —— 115 的
//   官方语义是"不允许上传"，与配额相邻但**不等价**；官方 dex 里有
//   `error_no_quota` 串但我方**未取证**到"配额用哪个码"。
//   ⇒ 先归 noQuota 并**在此明示是弱映射**，待取证后再收窄。
// * `DsmApiException 160`（无 app 权限）→ myDriveDisabled（弱映射，同上明示）。
// * 认不出 → unknown，**不硬猜**。
import 'dart:io';

import '../../dsm/webapi.dart';

/// 官方 `BackupFolderStatus` 分类学的我方对应。
enum PhotoBackupFolderStatus {
  init_('backup_status_enabled'),
  running('backup_status_running'),
  success('backup_status_enabled'),
  noNetwork('backup_status_wait_network'),
  waitWifi('backup_status_wait_wifi'),
  waitCharge('backup_status_wait_charge'),
  certificateMismatch('backup_status_error_certificate'),
  noQuota('backup_status_error_no_quota'),
  noPermission('backup_status_error_no_permission'),
  myDriveDisabled('backup_status_error_general'),
  backupFolderBlock('backup_status_error_no_permission'),
  deviceFolderBlock('backup_status_error_no_permission'),
  endFolderBlock('backup_status_error_no_permission'),
  error('backup_status_error_general'),
  unknown('backup_status_error_unknown');

  const PhotoBackupFolderStatus(this.officialStatusKey);

  /// 官方 dex 里的 `backup_status_*` 字符串（对齐锚点）。
  final String officialStatusKey;

  /// `CertificateMismatch` 起都算"备份出错了"（官方 `isError()` 的口径按
  /// `Type` 里错误族成员判断；这里按枚举顺序近似，错误族集中在尾部前段）。
  bool get isError => switch (this) {
    certificateMismatch ||
    noQuota ||
    noPermission ||
    myDriveDisabled ||
    backupFolderBlock ||
    deviceFolderBlock ||
    endFolderBlock ||
    error => true,
    _ => false,
  };

  /// 把异常翻成官方分类学里的状态。认不出 → `unknown`，不硬猜。
  ///
  /// ★ 教训：方法参数叫 `error`，枚举值又叫 `error` ——
  ///   第一次写时 switch 臂里 `=> error` 返回的是**参数**（Object），
  ///   编译器当场抓出来。这里改成 `errorStatus` 避免同名遮蔽。
  static PhotoBackupFolderStatus classify(Object? error) {
    const errorStatus = PhotoBackupFolderStatus.error;
    if (error == null) return init_;
    if (error is HandshakeException) return certificateMismatch;
    if (error is SocketException) return noNetwork;
    if (error is DsmApiException) {
      return switch (error.code) {
        DsmErrorCode.noPermission => noPermission,
        // ⚠️ 弱映射：115 = notAllowUpload，配额码未取证（见文件头）
        DsmErrorCode.notAllowUpload => noQuota,
        // ⚠️ 弱映射：160 = 无 app 权限，与"MyDrive 被停用"不等价
        DsmErrorCode.noAppPrivilege => myDriveDisabled,
        DsmErrorCode.sessionTimeout ||
        DsmErrorCode.sessionInterrupt ||
        DsmErrorCode.sidNotFound ||
        DsmErrorCode.unknown => errorStatus,
        _ => errorStatus,
      };
    }
    return unknown;
  }
}
