// Drive **D12 团队文件夹回收站**新增界面文案：**key + 中文原文**，与
// `drive_c1_text.dart` / `drive_g6_text.dart` 等同构。
//
// 已存在的文案（恢复 / 取消 / 原位置 / 删除于 / 永久删除 …）**一律继续走
// `context.t` 或 `driveC1(...)`**，不在本文件里重复。
import '../../core/i18n/data_text.dart';

/// 取 D12 新文案（key 见 [DriveRecycleTextKeys]）
String driveRecycle(String key, String zh) => dataText(key, zh);

/// 带 `{...}` 占位符的文案填充
String driveRecycleFill(String key, String zh, Map<String, String> values) {
  var out = driveRecycle(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批次新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class DriveRecycleTextKeys {
  // 入口 / 团队文件夹选择
  static const entry = 'driveD12TeamTrashEntry';
  static const title = 'driveD12TeamTrashTitle';
  static const pickFolder = 'driveD12TeamTrashPickFolder';
  static const noTeamFolders = 'driveD12TeamTrashNoTeamFolders';
  static const noTeamFoldersBody = 'driveD12TeamTrashNoTeamFoldersBody';
  static const loadFailed = 'driveD12TeamTrashLoadFailed';

  // 团队文件夹内的回收站
  static const emptyTitle = 'driveD12TeamTrashEmptyTitle';
  static const emptyBody = 'driveD12TeamTrashEmptyBody';
  static const count = 'driveD12TeamTrashCount';
  static const itemCount = 'driveD12TeamTrashItemCount';
  static const noEmptyAction = 'driveD12TeamTrashNoEmptyAction';
}
