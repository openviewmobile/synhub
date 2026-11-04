// G3/G7 新增界面文案：**key + 中文原文**（与 `note_wave4_text.dart` 同约定）。
//
// `.arb` 里补上同名 key 后由 `l10n.dart` 的 `setCurrentText` 注入译文；
// 没补上时回落中文原文（纯 Dart 与单测都走回落）。
// 本批已同步写入 `lib/l10n/app_zh.arb` 与 `lib/l10n/app_en.arb`；
// `lib/l10n/gen/**` 由父 agent 统一重生成（本批不碰生成代码）。
import '../../core/i18n/data_text.dart';

/// 取本批新文案
String noteAdv(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{count}` / `{error}`）
String noteAdvFill(String key, String zh, Map<String, String> values) {
  var out = noteAdv(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key。
abstract final class NoteAdvTextKeys {
  // ---- 入口 / 标题 ----
  static const entry = 'noteAdvSearchEntry';
  static const title = 'noteAdvSearchTitle';

  // ---- 条件：关键词 / 标题 ----
  static const keyword = 'noteAdvSearchKeyword';
  static const keywordHint = 'noteAdvSearchKeywordHint';
  static const titleLabel = 'noteAdvSearchTitleLabel';
  static const titleHint = 'noteAdvSearchTitleHint';

  // ---- 条件：标签（G4 操作符 + G7 子标签）----
  static const tags = 'noteAdvSearchTags';
  static const tagsAny = 'noteAdvSearchTagsAny';
  static const tagAnd = 'noteAdvSearchTagAnd';
  static const tagOr = 'noteAdvSearchTagOr';
  static const includeSubTags = 'noteAdvSearchIncludeSubTags';
  static const includeSubTagsHint = 'noteAdvSearchIncludeSubTagsHint';
  static const excludeTags = 'noteAdvSearchExcludeTags';
  static const excludeTagsHint = 'noteAdvSearchExcludeTagsHint';

  // ---- 条件：笔记本 ----
  static const notebooks = 'noteAdvSearchNotebooks';
  static const notebooksAny = 'noteAdvSearchNotebooksAny';

  // ---- 条件：时间 ----
  static const timeModified = 'noteAdvSearchTimeModified';
  static const timeCreated = 'noteAdvSearchTimeCreated';
  static const dateFrom = 'noteAdvSearchDateFrom';
  static const dateTo = 'noteAdvSearchDateTo';
  static const dateInvalid = 'noteAdvSearchDateInvalid';

  // ---- 动作 / 结果态 ----
  static const run = 'noteAdvSearchRun';
  static const clear = 'noteAdvSearchClear';
  static const prompt = 'noteAdvSearchPrompt';
  static const promptHint = 'noteAdvSearchPromptHint';
  static const empty = 'noteAdvSearchEmpty';
  static const emptyHint = 'noteAdvSearchEmptyHint';
  static const failed = 'noteAdvSearchFailed';
  static const selectedCount = 'noteAdvSearchSelectedCount';
  static const resultsCount = 'noteAdvSearchResultsCount';
}
