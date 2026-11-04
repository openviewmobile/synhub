// File Station P0-a（数据安全与核心缺口）新增界面文案：**key + 中文原文**。
//
// 约定与 `drive_c1_text.dart` / `service_text.dart` 一致：`.arb` 与
// `lib/l10n/gen/**` 在本批次**禁碰**，所以新文案一律 `key + 中文原文`，走
// `dataText`（`lib/src/core/i18n/data_text.dart`）。ARB 里补上同名 key 后，
// `setCurrentText` 注入的翻译表会自动把中文原文换成当前语言译文；
// 没补上时回落中文原文。
//
// 现有 key 清单（交给父 agent 并入 ARB）：
//   * `fsP0ConflictTitle`        —— 上传冲突面板标题
//   * `fsP0ConflictBody`         —— 冲突说明（占位符 `{name}`）
//   * `fsP0ConflictOverwrite`    —— 冲突选项：覆盖
//   * `fsP0ConflictRename`       —— 冲突选项：重命名
//   * `fsP0ConflictSkip`         —— 冲突选项：跳过
//   * `fsP0UploadRenamed`        —— 自动重命名后的提示（占位符 `{name}`）
//   * `fsP0RecycleBin`           —— 回收站入口
//   * `fsP0RecycleEmpty`         —— 清空回收站
//   * `fsP0RecycleEmptyConfirm`  —— 清空二次确认（必须说明不可恢复）
//   * `fsP0RecycleEmptyDone`     —— 清空完成提示
//   * `fsP0RecycleRestore`       —— 还原
//   * `fsP0RecycleRestoreConfirm`—— 还原确认
//   * `fsP0RecycleRestored`      —— 还原完成提示
//   * `fsP0DeleteForever`        —— 永久删除
//   * `fsP0DeleteForeverConfirm` —— 永久删除二次确认（不可恢复）
//   * `fsP0ShareAdd`             —— 创建分享链接入口
//   * `fsP0ShareCreateTitle`     —— 创建分享链接面板标题
//   * `fsP0SharePasswordEnable`  —— 启用密码保护
//   * `fsP0SharePasswordLabel`   —— 密码输入框
//   * `fsP0ShareValidity`        —— 有效期
//   * `fsP0SharePermanent`       —— 永久有效
//   * `fsP0ShareDays`            —— 有效天数（占位符 `{days}`）
//   * `fsP0ShareCreatedTitle`    —— 创建成功标题
//   * `fsP0ShareCopyUrl`         —— 复制链接
//   * `fsP0ShareCreateFailed`    —— 创建失败
import '../../core/i18n/data_text.dart';

/// 取 P0-a 新文案的译文；[zh] 是中文原文（回落值）。
String fsP0a(String key, String zh) => dataText(key, zh);

/// 带 `{name}` / `{days}` 占位符的文案填充助手。
String fsP0aFill(String key, String zh, Map<String, String> values) {
  var out = fsP0a(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批次新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class FsP0aTextKeys {
  // 上传冲突
  static const conflictTitle = 'fsP0ConflictTitle';
  static const conflictBody = 'fsP0ConflictBody';
  static const conflictOverwrite = 'fsP0ConflictOverwrite';
  static const conflictRename = 'fsP0ConflictRename';
  static const conflictSkip = 'fsP0ConflictSkip';
  static const uploadRenamed = 'fsP0UploadRenamed';

  // 回收站
  static const recycleBin = 'fsP0RecycleBin';
  static const recycleEmpty = 'fsP0RecycleEmpty';
  static const recycleEmptyConfirm = 'fsP0RecycleEmptyConfirm';
  static const recycleEmptyDone = 'fsP0RecycleEmptyDone';
  static const recycleRestore = 'fsP0RecycleRestore';
  static const recycleRestoreConfirm = 'fsP0RecycleRestoreConfirm';
  static const recycleRestored = 'fsP0RecycleRestored';
  static const deleteForever = 'fsP0DeleteForever';
  static const deleteForeverConfirm = 'fsP0DeleteForeverConfirm';

  // 分享链接
  static const shareAdd = 'fsP0ShareAdd';
  static const shareCreateTitle = 'fsP0ShareCreateTitle';
  static const sharePasswordEnable = 'fsP0SharePasswordEnable';
  static const sharePasswordLabel = 'fsP0SharePasswordLabel';
  static const shareValidity = 'fsP0ShareValidity';
  static const sharePermanent = 'fsP0SharePermanent';
  static const shareDays = 'fsP0ShareDays';
  static const shareCreatedTitle = 'fsP0ShareCreatedTitle';
  static const shareCopyUrl = 'fsP0ShareCopyUrl';
  static const shareCreateFailed = 'fsP0ShareCreateFailed';
}
