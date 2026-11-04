// Wave5 笔记缺口补齐的新界面文案：**key + 中文原文**。
//
// 与 A / B / C3 / drawing / wave2 / wave3 / wave4 各批同一套约定：`.arb` 与
// `lib/l10n/gen/**` 在本批次**禁碰**，新文案走数据层的 `dataText.dart`
// （key + 中文原文；装了翻译器出译文，否则回落中文）。每条的 key 就是要追加的
// ARB key；需要并入的 key/中文/占位符清单见本批报告。
//
// 已经存在的文案（取消 / 删除 / 保存 / 刷新 / 搜索 …）一律继续走 `context.t`。
import '../../core/i18n/data_text.dart';

/// 取 Wave5 新文案
String noteWave5(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{error}` / `{count}` / `{ok}` / `{fail}` / `{parent}` …）
String noteWave5Fill(String key, String zh, Map<String, String> values) {
  var out = noteWave5(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class NoteWave5TextKeys {
  // ---- I2：改口令（Android `Note/copy` ENCRYPT_TO_ENCRYPT 路线）----
  static const changePassword = 'noteWave5ChangePassword';
  static const changePasswordTitle = 'noteWave5ChangePasswordTitle';
  static const oldPassword = 'noteWave5OldPassword';
  static const newPassword = 'noteWave5NewPassword';
  static const confirmPassword = 'noteWave5ConfirmPassword';
  static const changePasswordDone = 'noteWave5ChangePasswordDone';
  static const changePasswordFailed = 'noteWave5ChangePasswordFailed';
  static const unlockFailed = 'noteWave5UnlockFailed';
  static const passwordMismatch = 'noteWave5PasswordMismatch';
  static const passwordRequired = 'noteWave5PasswordRequired';
  static const newPasswordRequired = 'noteWave5NewPasswordRequired';
  static const passwordUnchanged = 'noteWave5PasswordUnchanged';
  static const changePasswordNoContent = 'noteWave5ChangePasswordNoContent';

  // ---- A13：笔记信息（大小 / 时间 / 来源；内部 id 一律不上屏）----
  static const infoTitle = 'noteWave5InfoTitle';
  static const infoSize = 'noteWave5InfoSize';
  static const infoCreated = 'noteWave5InfoCreated';
  static const infoModified = 'noteWave5InfoModified';
  static const infoSource = 'noteWave5InfoSource';
  static const infoNotebook = 'noteWave5InfoNotebook';
  static const infoTags = 'noteWave5InfoTags';
  static const infoOwner = 'noteWave5InfoOwner';
  static const infoEncrypted = 'noteWave5InfoEncrypted';
  static const infoUnset = 'noteWave5InfoUnset';
  static const topLevel = 'noteWave5TopLevel';

  // ---- N3：来源链接查看 / 编辑（`Note/set` 的 `source_url`）----
  static const sourceUrlEdit = 'noteWave5SourceUrlEdit';
  static const sourceUrlHint = 'noteWave5SourceUrlHint';
  static const sourceUrlSaved = 'noteWave5SourceUrlSaved';
  static const sourceUrlInvalid = 'noteWave5SourceUrlInvalid';
  static const sourceUrlOpenFailed = 'noteWave5SourceUrlOpenFailed';
  static const sourceUrlOpenFailedDetail =
      'noteWave5SourceUrlOpenFailedDetail';
  static const sourceUrlOpen = 'noteWave5SourceUrlOpen';

  // ---- A14：归档 / 取消归档笔记本（`Notebook.Polling:archive` v1）----
  static const archive = 'noteWave5Archive';
  static const unarchive = 'noteWave5Unarchive';
  static const archived = 'noteWave5Archived';
  static const unarchived = 'noteWave5Unarchived';
  static const showArchived = 'noteWave5ShowArchived';
  static const archiveFailed = 'noteWave5ArchiveFailed';

  // ---- A8：清空回收站（`Note/delete` v3 数组 `object_id`）----
  static const emptyRecycleDone = 'noteWave5EmptyRecycleDone';
  static const emptyRecyclePartial = 'noteWave5EmptyRecyclePartial';

  // ---- F9：列表 / 网格视图切换 ----
  static const viewList = 'noteWave5ViewList';
  static const viewGrid = 'noteWave5ViewGrid';

  // ---- F4：子标签（标题 `/` 分层；`Tag/set` 无 parent 字段）----
  static const showSubTags = 'noteWave5ShowSubTags';
  static const subTagOf = 'noteWave5SubTagOf';

  // ---- G4：标签 + 操作符搜索（`Note/list` 的 `tag`+`tag_operator`）----
  static const tagOperatorOr = 'noteWave5TagOperatorOr';
  static const tagOperatorAnd = 'noteWave5TagOperatorAnd';
  static const filterByTags = 'noteWave5FilterByTags';
  static const clearTagFilter = 'noteWave5ClearTagFilter';
}
