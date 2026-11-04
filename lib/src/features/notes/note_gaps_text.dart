// Wave2 笔记缺口补齐的新界面文案：**key + 中文原文**。
//
// 与 C3 / A / B / drawing 各批同一套约定：`.arb` 与 `lib/l10n/gen/**` 在本批次
// **禁碰**，新文案走数据层的 `dataText.dart`（key + 中文原文；装了翻译器出译文，
// 否则回落中文）。每条的 key 就是要追加的 ARB key；需要并入的
// key/zh/en/占位符清单见 `docs/note-gaps-wave2.md` 的「ARB key 清单」。
//
// 已经存在的文案（取消 / 删除 / 保存 / 刷新 / 搜索 …）一律继续走 `context.t`。
import '../../core/i18n/data_text.dart';

/// 取 Wave2 新文案
String noteGaps(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{count}` / `{name}` / `{ok}` / `{fail}` …）
String noteGapsFill(String key, String zh, Map<String, String> values) {
  var out = noteGaps(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class NoteGapsTextKeys {
  // ---- A12 多选批量 ----
  static const selectAll = 'noteGapsSelectAll';
  static const invertSelection = 'noteGapsInvertSelection';
  static const selectedCount = 'noteGapsSelectedCount';
  static const batchDelete = 'noteGapsBatchDelete';
  static const batchDeleteConfirm = 'noteGapsBatchDeleteConfirm';
  static const batchMove = 'noteGapsBatchMove';
  static const batchMoveTitle = 'noteGapsBatchMoveTitle';
  static const batchDeleted = 'noteGapsBatchDeleted';
  static const batchMoved = 'noteGapsBatchMoved';
  static const batchPartial = 'noteGapsBatchPartial';
  static const batchFailed = 'noteGapsBatchFailed';

  // ---- F7 排序 ----
  static const sort = 'noteGapsSort';
  static const sortByTitle = 'noteGapsSortByTitle';
  static const sortByCtime = 'noteGapsSortByCtime';
  static const sortByMtime = 'noteGapsSortByMtime';
  static const sortAsc = 'noteGapsSortAsc';
  static const sortDesc = 'noteGapsSortDesc';

  // ---- C9/G5 附件文本搜索 ----
  static const attachmentSearch = 'noteGapsAttachmentSearch';
  static const attachmentView = 'noteGapsAttachmentView';
  static const attachmentTextEmpty = 'noteGapsAttachmentTextEmpty';
  static const attachmentTextFailed = 'noteGapsAttachmentTextFailed';

  // ---- N7 默认字号 ----
  static const defaultFontSize = 'noteGapsDefaultFontSize';
  static const defaultFontSizeSet = 'noteGapsDefaultFontSizeSet';

  // ---- C4/C5 录音 / 录像附件 ----
  static const recordAudio = 'noteGapsRecordAudio';
  static const recordAudioStart = 'noteGapsRecordAudioStart';
  static const recordAudioStop = 'noteGapsRecordAudioStop';
  static const recordAudioDenied = 'noteGapsRecordAudioDenied';
  static const recordAudioFailed = 'noteGapsRecordAudioFailed';
  static const recordAudioFileName = 'noteGapsRecordAudioFileName';
  static const recordVideo = 'noteGapsRecordVideo';

  // ---- J8/L2 分享面板剪藏 ----
  static const shareClip = 'noteGapsShareClip';
  static const shareClipNoNotebook = 'noteGapsShareClipNoNotebook';
  static const shareClipDone = 'noteGapsShareClipDone';
  static const shareClipFailed = 'noteGapsShareClipFailed';
  static const shareClipTitle = 'noteGapsShareClipTitle';
}
