// Wave4 笔记缺口补齐的新界面文案：**key + 中文原文**。
//
// 与 C3 / A / B / drawing / wave2 / wave3 各批同一套约定：`.arb` 与
// `lib/l10n/gen/**` 在本批次**禁碰**，新文案走数据层的 `dataText.dart`
// （key + 中文原文；装了翻译器出译文，否则回落中文）。每条的 key 就是要追加的
// ARB key；需要并入的 key/中文/占位符清单见 `docs/note-wave4-implementation.md`
// 的「ARB key 清单」。
//
// 已经存在的文案（取消 / 删除 / 保存 / 刷新 / 搜索 …）一律继续走 `context.t`。
import '../../core/i18n/data_text.dart';

/// 取 Wave4 新文案
String noteWave4(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{name}` / `{error}` …）
String noteWave4Fill(String key, String zh, Map<String, String> values) {
  var out = noteWave4(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class NoteWave4TextKeys {
  // ---- G1：全文检索（`NoteStation.FTS : search` v1）----
  static const ftsEntry = 'noteWave4FtsEntry';
  static const ftsTitle = 'noteWave4FtsTitle';
  static const ftsHint = 'noteWave4FtsHint';
  static const ftsPrompt = 'noteWave4FtsPrompt';
  static const ftsEmpty = 'noteWave4FtsEmpty';
  static const ftsEmptyHint = 'noteWave4FtsEmptyHint';
  static const ftsFailed = 'noteWave4FtsFailed';

  // ---- F5：快捷方式写入 / 跳转 ----
  static const shortcutAdd = 'noteWave4ShortcutAdd';
  static const shortcutRemove = 'noteWave4ShortcutRemove';
  static const shortcutAdded = 'noteWave4ShortcutAdded';
  static const shortcutRemoved = 'noteWave4ShortcutRemoved';
  static const shortcutFailed = 'noteWave4ShortcutFailed';
  static const shortcutDeleteConfirm = 'noteWave4ShortcutDeleteConfirm';
  static const shortcutNoTarget = 'noteWave4ShortcutNoTarget';

  // ---- C5：从相机 / 视频新建 ----
  static const newFromCamera = 'noteWave4NewFromCamera';
  static const newFromVideo = 'noteWave4NewFromVideo';

  // ---- 导出任务态（不谎报完成）----
  static const exportSubmitted = 'noteWave4ExportSubmitted';
  static const exportSaved = 'noteWave4ExportSaved';
  static const exportSubsystem = 'noteWave4ExportSubsystem';
}
