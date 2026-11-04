// Drive **wave2**（普通用户级功能）新增界面文案：**key + 中文原文**。
//
// 为什么不用 `context.t`：本批**禁碰 `.arb` 与 `lib/l10n/gen/**`**，所以新文案
// 沿用仓库既有的 `dataText` 约定（key + 中文原文，语言切换时由
// `setCurrentText` 注入译文，取不到就回落中文）。与 `drive_p0_text.dart` /
// `drive_c1_text.dart` / `drive_gaps_text.dart` 同构。
//
// 每一条的 key 就是要追加的 ARB key（全表见交付报告）。带 `{...}` 的条目一律
// 通过 [driveWave2Fill] 填充，绝不把占位符当字面量送进 UI。
import '../../core/i18n/data_text.dart';
import '../../data/dto/drive_quota_dto.dart';

/// 取 wave2 新文案（key 见 [DriveWave2TextKeys]）
String driveWave2(String key, String zh) => dataText(key, zh);

/// 带 `{used}` / `{total}` 等占位符的文案填充
String driveWave2Fill(String key, String zh, Map<String, String> values) {
  var out = driveWave2(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 「已用 / 配额」的一句话摘要。
///
/// **不限额的表达是硬要求**：`quota <= 0` 时官方只显示已用量、不显示总容量
/// （见 [DriveQuotaShareDto] 顶部证据），所以这里返回"已使用 X"而**不是**
/// "X / 0 B"。`formatSize` 由 UI 注入（`driveHumanSize`），数据层不碰 Flutter。
String driveQuotaUsageLine(
  DriveQuotaShareDto share,
  String Function(int bytes) formatSize,
) {
  final used = formatSize(share.usedBytes);
  if (!share.hasQuota) {
    return driveWave2Fill(DriveWave2TextKeys.quotaUsed, '已使用 {used}', {
      'used': used,
    });
  }
  return driveWave2Fill(DriveWave2TextKeys.quotaUsedOf, '{total} 中已使用 {used}', {
    'used': used,
    'total': formatSize(share.quotaBytes),
  });
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class DriveWave2TextKeys {
  // ---- 配额 / 用量（Info:quota v2）
  static const quotaTitle = 'driveWave2QuotaTitle';
  static const quotaEntry = 'driveWave2QuotaEntry';
  static const quotaMyDrive = 'driveWave2QuotaMyDrive';
  static const quotaUnlimited = 'driveWave2QuotaUnlimited';
  static const quotaUsed = 'driveWave2QuotaUsed';
  static const quotaUsedOf = 'driveWave2QuotaUsedOf';
  static const quotaPercent = 'driveWave2QuotaPercent';
  static const quotaEmpty = 'driveWave2QuotaEmpty';
  static const quotaLoadFailed = 'driveWave2QuotaLoadFailed';
  static const quotaRefresh = 'driveWave2QuotaRefresh';
  static const quotaOtherShares = 'driveWave2QuotaOtherShares';

  // ---- 转成 Office 格式（Files:convert_office v1）
  static const convertTitle = 'driveWave2ConvertTitle';
  static const convertEntry = 'driveWave2ConvertEntry';
  static const convertTarget = 'driveWave2ConvertTarget';
  static const convertTargetDocx = 'driveWave2ConvertTargetDocx';
  static const convertSubmit = 'driveWave2ConvertSubmit';
  static const convertSubmitting = 'driveWave2ConvertSubmitting';
  static const convertSubmitted = 'driveWave2ConvertSubmitted';
  static const convertFinished = 'driveWave2ConvertFinished';
  static const convertFailed = 'driveWave2ConvertFailed';
  static const convertUnavailable = 'driveWave2ConvertUnavailable';
  static const convertClose = 'driveWave2ConvertClose';

  // ---- 目录条目数（`Files:count_files` v11，只读）
  static const folderItemCount = 'driveWave2FolderItemCount';
  static const folderItemCountValue = 'driveWave2FolderItemCountValue';
  static const folderItemCountUnavailable =
      'driveWave2FolderItemCountUnavailable';

  // ---- 申请访问权（`Files:request_access` v11，**写操作**）
  static const requestAccess = 'driveWave2RequestAccess';
  static const requestAccessConfirmTitle =
      'driveWave2RequestAccessConfirmTitle';
  static const requestAccessConfirmMessage =
      'driveWave2RequestAccessConfirmMessage';
  static const requestAccessConfirm = 'driveWave2RequestAccessConfirm';
  static const requestAccessCancel = 'driveWave2RequestAccessCancel';
  static const requestAccessSent = 'driveWave2RequestAccessSent';
  static const requestAccessFailed = 'driveWave2RequestAccessFailed';
}
