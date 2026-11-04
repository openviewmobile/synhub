// 相册「相机备份后台化 + 双落点」新增界面文案：**key + 中文原文**。
//
// 与 `photo_p0_text.dart` / `photo_p1_text.dart` / `photo_c2_text.dart` 同一套约定：
// `.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**，所以新文案走 `dataText`
// （key + 中文原文；装了翻译器就出译文，否则回落中文）。每一条的 key 就是要
// 追加的 ARB key，清单见 `docs/photo-backup-background.md` 的「需并入的 ARB key」。
//
// 复用原则：能复用既有 `pb*` / `photo*` key 的**一律复用**（例如 `pbWifiOnly`、
// `pbAutoBackup`、`setNotConnected`），本文件只放"确实没有的"那几条。
import '../../core/i18n/data_text.dart';

/// 取本批新文案（key 见 [PhotoBackupTextKeys]）
String pbText(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{n}` / `{name}` / `{error}` …）
String pbTextFill(String key, String zh, Map<String, String> values) {
  var out = pbText(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（维护者统一并库时照抄）
abstract final class PhotoBackupTextKeys {
  // ---- P43 上传质量档
  static const uploadQuality = 'pbUploadQuality';
  static const uploadQualityHint = 'pbUploadQualityHint';
  static const uploadQualityOriginal = 'pbUploadQualityOriginal';
  static const uploadQualityHigh = 'pbUploadQualityHigh';
  static const uploadQualityMedium = 'pbUploadQualityMedium';
  static const uploadQualityLow = 'pbUploadQualityLow';

  // ---- 落点选择
  static const destinationTitle = 'pbDestinationTitle';
  static const destinationDrive = 'pbDestinationDrive';
  static const destinationPhotos = 'pbDestinationPhotos';
  static const destinationDriveDesc = 'pbDestinationDriveDesc';
  static const destinationPhotosDesc = 'pbDestinationPhotosDesc';
  static const destinationSwitched = 'pbDestinationSwitched';
  static const targetPathLabel = 'pbTargetPathLabel';

  // ---- 落点降级（105/160 隐藏 + 原因；102/103 只影响该选项）
  static const targetDriveMissing = 'pbTargetDriveMissing';
  static const targetPhotosMissing = 'pbTargetPhotosMissing';
  static const targetNoPermission = 'pbTargetNoPermission';
  static const targetUnavailable = 'pbTargetUnavailable';

  // ---- 备份范围 / 官方同构
  static const dcimOnly = 'pbDcimOnly';

  // ---- D72 按日期分目录（官方 `BackupStructure` 三个取值，字面量照抄）
  static const structure = 'pbStructure';
  static const structureNone = 'pbStructureNone';
  static const structureYear = 'pbStructureYear';
  static const structureYearMonth = 'pbStructureYearMonth';
  static const dcimOnlyHint = 'pbDcimOnlyHint';
  static const serialHint = 'pbSerialHint';
  static const dedupMd5Hint = 'pbDedupMd5Hint';

  // ---- 后台约束
  static const chargeOnly = 'pbChargeOnly';
  static const chargeOnlyHint = 'pbChargeOnlyHint';
  static const screenOffOnly = 'pbScreenOffOnly';
  static const screenOffOnlyHint = 'pbScreenOffOnlyHint';
  static const chargeBlocked = 'pbChargeBlocked';

  // ---- 后台状态卡片
  static const backgroundTitle = 'pbBackgroundTitle';
  static const backgroundScheduled = 'pbBackgroundScheduled';
  static const backgroundNotScheduled = 'pbBackgroundNotScheduled';
  static const backgroundCharging = 'pbBackgroundCharging';
  static const backgroundNotCharging = 'pbBackgroundNotCharging';
  static const backgroundScreenOn = 'pbBackgroundScreenOn';
  static const backgroundScreenOff = 'pbBackgroundScreenOff';
  static const backgroundBatteryHint = 'pbBackgroundBatteryHint';
  static const backgroundGrantBattery = 'pbBackgroundGrantBattery';
  static const backgroundLastResult = 'pbBackgroundLastResult';
  static const backgroundRunNow = 'pbBackgroundRunNow';
  static const backgroundUnsupported = 'pbBackgroundUnsupported';
  static const backgroundDevice = 'pbBackgroundDevice';
  static const backgroundBlocked = 'pbBackgroundBlocked';
}
