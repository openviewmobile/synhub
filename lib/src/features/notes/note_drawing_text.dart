// 笔记手绘/涂鸦的新增界面文案：**key + 中文原文**。
//
// 与 C1/C2/C3 同一套约定：`.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**，所以
// 新文案走数据层的 `dataText.dart`（key + 中文原文；装了翻译器就出译文，否则回落
// 中文）。每一条的 key 就是要追加的 ARB key；需要并入的 key/中文/英文/占位符清单
// 见 `docs/note-drawing-implementation.md` 的「ARB key 清单」。
//
// 已存在的文案（取消 / 保存 / 附件 …）继续走 `context.t`。
import '../../core/i18n/data_text.dart';

/// 取手绘文案（key 见 [NoteDrawingTextKeys]）
String noteDrawingText(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{error}` 等）
String noteDrawingFill(String key, String zh, Map<String, String> values) {
  var out = noteDrawingText(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批次新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class NoteDrawingTextKeys {
  // ---- 入口 ----
  static const entry = 'noteDrawEntry';
  static const entryHint = 'noteDrawEntryHint';

  // ---- 绘图板 ----
  static const title = 'noteDrawTitle';
  static const brush = 'noteDrawBrush';
  static const eraser = 'noteDrawEraser';
  static const color = 'noteDrawColor';
  static const width = 'noteDrawWidth';
  static const undo = 'noteDrawUndo';
  static const redo = 'noteDrawRedo';
  static const clear = 'noteDrawClear';
  static const background = 'noteDrawBackground';
  static const backgroundWhite = 'noteDrawBackgroundWhite';
  static const backgroundTransparent = 'noteDrawBackgroundTransparent';
  static const hint = 'noteDrawHint';

  /// ★ r716（`D23`）：桌面宿主用**指针**措辞（拖拽/撤销），不把手机手势硬塞给桌面。
  static const hintDesktop = 'noteDrawHintDesktop';
  static const insert = 'noteDrawInsert';
  static const empty = 'noteDrawEmpty';

  // ---- 失败 / 降级 ----
  static const exportFailed = 'noteDrawExportFailed';
  static const insertFailed = 'noteDrawInsertFailed';
  static const unavailable = 'noteDrawUnavailable';
  static const unavailableHint = 'noteDrawUnavailableHint';
}
