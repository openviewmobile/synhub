// C1（Drive 补齐）新增界面文案：**key + 中文原文**。
//
// 为什么不用 `context.t`：本批次的界面文案里有相当一部分 ARB 里还没有
// （`.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**）。这里沿用数据层的
// `data_text.dart` 约定（key + 中文原文，语言切换时由 `setCurrentText` 注入
// 译文，取不到就回落中文），把新文案集中在一处，方便下一步**批量补 ARB**：
// 每一条的 key 就是要追加的 ARB key（见
// `docs/workspace-expansion-evaluation.md` 实施记录里的"待追加 ARB key"清单）。
//
// 已经存在的文案（恢复 / 清空回收站 / 取消 / 重试 …）**一律继续走 `context.t`**，
// 不在本文件里重复。
import '../../core/i18n/data_text.dart';

/// 取 C1 新文案（key 见 [DriveC1TextKeys]）
String driveC1(String key, String zh) => dataText(key, zh);

/// 带一个 `{name}` / `{error}` 占位符的文案的填充助手
String driveC1Fill(String key, String zh, Map<String, String> values) {
  var out = driveC1(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批次新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class DriveC1TextKeys {
  // 回收站
  static const deletedAt = 'driveC1DeletedAt';
  static const originalPath = 'driveC1OriginalPath';
  static const deleteForever = 'driveC1DeleteForever';
  static const deleteForeverConfirm = 'driveC1DeleteForeverConfirm';
  static const deleteForeverBody = 'driveC1DeleteForeverBody';
  static const deleteForeverFailed = 'driveC1DeleteForeverFailed';
  static const restored = 'driveC1Restored';
  static const restoreOneFailed = 'driveC1RestoreOneFailed';

  // 高级共享
  static const advanceSharing = 'driveC1AdvanceSharing';
  static const advanceSharingEntry = 'driveC1AdvanceSharingEntry';
  static const advanceSharingIntro = 'driveC1AdvanceSharingIntro';
  static const advanceSharingEmpty = 'driveC1AdvanceSharingEmpty';
  static const closeLink = 'driveC1CloseLink';
  static const closeLinkConfirm = 'driveC1CloseLinkConfirm';
  static const closeLinkBody = 'driveC1CloseLinkBody';
  static const linkExpiryNone = 'driveC1LinkExpiryNone';
  static const linkExpiry = 'driveC1LinkExpiry';
  static const linkPasswordOn = 'driveC1LinkPasswordOn';
  // D39（第 60 轮）：访问密码设置
  static const linkPassword = 'driveC1LinkPassword';
  static const linkPasswordHint = 'driveC1LinkPasswordHint';
  static const linkPasswordSaved = 'driveC1LinkPasswordSaved';
  static const linkPasswordCleared = 'driveC1LinkPasswordCleared';
  static const clearLinkPassword = 'driveC1ClearLinkPassword';
  static const clearLinkPasswordHint = 'driveC1ClearLinkPasswordHint';
  // D39（第 61 轮）：有效期编辑
  static const linkExpiryEdit = 'driveC1LinkExpiryEdit';
  static const linkExpiryAdd = 'driveC1LinkExpiryAdd';
  static const linkExpiryClear = 'driveC1LinkExpiryClear';
  static const linkExpirySaved = 'driveC1LinkExpirySaved';
  static const linkExpiryCleared = 'driveC1LinkExpiryCleared';
  static const linkClosed = 'driveC1LinkClosed';
  static const roleUpdated = 'driveC1RoleUpdated';
  static const actionFailed = 'driveC1ActionFailed';

  // 请求文件
  static const fileRequests = 'driveC1FileRequests';
  static const fileRequestsEntry = 'driveC1FileRequestsEntry';
  static const fileRequestsEmpty = 'driveC1FileRequestsEmpty';
  static const newFileRequest = 'driveC1NewFileRequest';
  static const requestTitle = 'driveC1RequestTitle';
  static const requestTitleHint = 'driveC1RequestTitleHint';
  static const requestCreated = 'driveC1RequestCreated';
  static const closeRequest = 'driveC1CloseRequest';
  static const reopenRequest = 'driveC1ReopenRequest';
  static const requestClosed = 'driveC1RequestClosed';
  static const requestReopened = 'driveC1RequestReopened';
  static const requestDeleted = 'driveC1RequestDeleted';
  static const requestDeleteConfirm = 'driveC1RequestDeleteConfirm';
  static const requestDeleteBody = 'driveC1RequestDeleteBody';

  // 通知
  static const notifications = 'driveC1Notifications';
  static const notificationsEntry = 'driveC1NotificationsEntry';
  static const notificationsEmpty = 'driveC1NotificationsEmpty';
  static const clearNotifications = 'driveC1ClearNotifications';
  static const clearNotificationsConfirm = 'driveC1ClearNotificationsConfirm';
  static const notificationsCleared = 'driveC1NotificationsCleared';

  // 团队文件夹成员
  static const teamMembers = 'driveC1TeamMembers';
  static const teamMembersEntry = 'driveC1TeamMembersEntry';
  static const teamMembersEmpty = 'driveC1TeamMembersEmpty';
  static const teamMembersPick = 'driveC1TeamMembersPick';

  // 文件锁（Files.lock / request_unlock）
  static const lock = 'driveC1Lock';
  static const unlock = 'driveC1Unlock';
  static const requestUnlock = 'driveC1RequestUnlock';
  static const lockedBy = 'driveC1LockedBy';
  static const locked = 'driveC1Locked';
  static const unlocked = 'driveC1Unlocked';
  static const unlockRequested = 'driveC1UnlockRequested';
  static const lockFailed = 'driveC1LockFailed';
}
