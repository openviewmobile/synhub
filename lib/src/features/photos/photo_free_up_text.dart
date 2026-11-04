// 相册「释放手机空间」新增界面文案：**key + 中文原文**。
//
// 与 `photo_backup_text.dart` / `photo_g6_text.dart` 同一套约定：新文案走
// `dataText`（key + 中文原文；装了翻译器就出译文，否则回落中文）。每一条的 key
// 就是要追加的 ARB key，清单见交付报告 `docs/photo-free-up-space-report.md`。
//
// ## 纪律：**用户语言，零工程词**
//
// 界面上不允许出现 `MediaStore` / `createDeleteRequest` / `clearCache` /
// `FreeUpSpaceActivity` / `content://` 之类的实现细节；平台能力的差异一律用
// "系统确认框 / 到系统设置里手动清理"这种人话表达。
//
// 复用原则：能复用既有 key 的一律复用（`photoRetry`、`photoClose`、
// `pbPermissionPartial`、`setNotConnected` 等），本文件只放确实没有的。
import '../../core/i18n/data_text.dart';

/// 取本功能新文案（key 见 [PhotoFreeUpTextKeys]）
String freeUpText(String key, String zh) => dataText(key, zh);

/// 带 `{...}` 占位符的文案填充（**绝不把占位符当字面量送进 UI**）
String freeUpTextFill(String key, String zh, Map<String, String> values) {
  var out = freeUpText(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本功能新增的 ARB key（编排者并库时照抄）。
abstract final class PhotoFreeUpTextKeys {
  // ---- 入口
  static const title = 'photoFreeUpTitle';
  static const entry = 'photoFreeUpEntry';
  static const entryHint = 'photoFreeUpEntryHint';

  // ---- 说明（官方 `str_explain_free_up_space` 同构）
  static const explainTitle = 'photoFreeUpExplainTitle';
  static const explainBody = 'photoFreeUpExplainBody';

  // ---- 可释放量 / 统计
  static const reclaimable = 'photoFreeUpReclaimable';
  static const counts = 'photoFreeUpCounts';
  static const rescan = 'photoFreeUpRescan';
  static const scanning = 'photoFreeUpScanning';
  static const progress = 'photoFreeUpProgress';

  // ---- 动作 / 结局
  static const start = 'photoFreeUpStart';
  static const cancelled = 'photoFreeUpCancelled';
  static const deleted = 'photoFreeUpDeleted';
  static const deletedSomeFailed = 'photoFreeUpDeletedSomeFailed';
  static const failed = 'photoFreeUpFailed';
  static const nothingToFree = 'photoFreeUpNothingToFree';
  static const cacheCleared = 'photoFreeUpCacheCleared';

  // ---- 空态 / 降级
  static const noPermissionTitle = 'photoFreeUpNoPermissionTitle';
  static const notConnected = 'photoFreeUpNotConnected';
  static const noTarget = 'photoFreeUpNoTarget';
  static const nothingTitle = 'photoFreeUpNothingTitle';
  static const nothingBody = 'photoFreeUpNothingBody';

  // ---- 平台能力（只用人话）
  static const unsupportedTitle = 'photoFreeUpUnsupportedTitle';
  static const unsupportedBody = 'photoFreeUpUnsupportedBody';
  static const settingsOnlyTitle = 'photoFreeUpSettingsOnlyTitle';
  static const settingsOnlyBody = 'photoFreeUpSettingsOnlyBody';
  static const openSettings = 'photoFreeUpOpenSettings';
  static const settingsFailed = 'photoFreeUpSettingsFailed';

  // ---- 逐项状态
  static const itemReasonLedger = 'photoFreeUpItemReasonLedger';
  static const itemReasonRemote = 'photoFreeUpItemReasonRemote';
  static const itemStatePending = 'photoFreeUpItemStatePending';
  static const itemStateDeleted = 'photoFreeUpItemStateDeleted';
  static const itemStateKept = 'photoFreeUpItemStateKept';
}
