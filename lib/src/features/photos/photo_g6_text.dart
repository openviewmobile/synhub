// 相册 **G6 批次**新增界面文案：**key + 中文原文**。
//
// 两个功能：
//   * 用户后台任务 `SYNO.Foto.BackgroundTask.Info:list_user_task`（v1）；
//   * 迁移状态 `SYNO.Foto.Migration:get_status`（v1）。
//
// 与 `photo_p0_text.dart` / `photo_c2_text.dart` / `photo_wave2_text.dart` /
// `photo_recent_text.dart` 同一套约定：新文案走数据层的 `data_text.dart`
// （key + 中文原文；装了翻译器就出译文，否则回落中文）。每一条的 key 就是要
// 追加的 ARB key，全表见交付报告 `docs/g6-wiring-report.md`。
//
// 复用原则：能复用既有 key 的一律复用 —— 加载失败 / 重试直接复用
// `photoLoadFailed` / `photoRetry`（`PhotoAsync` 内部已走它们）。
import '../../core/i18n/data_text.dart';

/// 取 G6 新文案（key 见 [PhotoG6TextKeys]）
String photoG6(String key, String zh) => dataText(key, zh);

/// 带 `{...}` 占位符的文案填充（**绝不把占位符当字面量送进 UI**）
String photoG6Fill(String key, String zh, Map<String, String> values) {
  var out = photoG6(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// G6 新增的 ARB key（已同步进 `app_zh.arb` / `app_en.arb`）
abstract final class PhotoG6TextKeys {
  // ---- 后台任务（`BackgroundTask.Info:list_user_task`）
  static const tasksTitle = 'photoG6TasksTitle';
  static const tasksEntry = 'photoG6TasksEntry';
  static const tasksEntryHint = 'photoG6TasksEntryHint';
  static const tasksEmptyTitle = 'photoG6TasksEmptyTitle';
  static const tasksEmptyBody = 'photoG6TasksEmptyBody';
  static const taskOperationCopy = 'photoG6TaskOperationCopy';
  static const taskOperationMove = 'photoG6TaskOperationMove';
  static const taskStatusWaiting = 'photoG6TaskStatusWaiting';
  static const taskStatusProcessing = 'photoG6TaskStatusProcessing';
  static const taskStatusAborting = 'photoG6TaskStatusAborting';
  static const taskStatusDone = 'photoG6TaskStatusDone';
  static const taskProgress = 'photoG6TaskProgress';
  static const taskErrors = 'photoG6TaskErrors';
  static const taskUnknownType = 'photoG6TaskUnknownType';

  // ---- 迁移状态（`Migration:get_status`）
  static const migrationTitle = 'photoG6MigrationTitle';
  static const migrationEntry = 'photoG6MigrationEntry';
  static const migrationEntryHint = 'photoG6MigrationEntryHint';
  static const migrationStatusDone = 'photoG6MigrationStatusDone';
  static const migrationStatusRunning = 'photoG6MigrationStatusRunning';
  static const migrationStatusFailed = 'photoG6MigrationStatusFailed';
  static const migrationStatusUnknown = 'photoG6MigrationStatusUnknown';
  static const migrationStagePhotoStation = 'photoG6MigrationStagePhotoStation';
  static const migrationStageMomentsPersonal =
      'photoG6MigrationStageMomentsPersonal';
  static const migrationStageBoth = 'photoG6MigrationStageBoth';
  static const migrationProgress = 'photoG6MigrationProgress';
  static const migrationIdleTitle = 'photoG6MigrationIdleTitle';
  static const migrationIdleBody = 'photoG6MigrationIdleBody';
}
