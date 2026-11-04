// C3（NoteStation 补齐）新增界面文案：**key + 中文原文**。
//
// 与 C1（Drive）/ C2（Photos）同一套约定：`.arb` 与 `lib/l10n/gen/**` 在本批次
// **禁碰**，所以新文案走数据层的 `dataText.dart`（key + 中文原文；装了翻译器就出
// 译文，否则回落中文）。每一条的 key 就是要追加的 ARB key；需要交给维护者并入的
// key/中文/英文/占位符清单见 `docs/note-c3-implementation.md` 的「ARB key 清单」。
//
// 已经存在的文案（取消 / 删除 / 重试 / 加载失败 / 搜索 …）一律继续走 `context.t`。
import '../../core/i18n/data_text.dart';

/// 取 C3 新文案（key 见 [NoteC3TextKeys]）
String noteC3(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{name}` / `{count}` / `{error}` / `{version}` …）
String noteC3Fill(String key, String zh, Map<String, String> values) {
  var out = noteC3(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批次新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class NoteC3TextKeys {
  // ---- 导出 ----
  static const export = 'noteC3Export';
  static const exportTitle = 'noteC3ExportTitle';
  static const exportWord = 'noteC3ExportWord';
  static const exportWordHint = 'noteC3ExportWordHint';
  static const exportNote = 'noteC3ExportNote';
  static const exportNoteHint = 'noteC3ExportNoteHint';
  static const exportNotebook = 'noteC3ExportNotebook';
  static const exportDest = 'noteC3ExportDest';
  static const exportDestHint = 'noteC3ExportDestHint';
  static const exportSaveConfig = 'noteC3ExportSaveConfig';
  static const exportTodo = 'noteC3ExportTodo';
  static const exportStarted = 'noteC3ExportStarted';
  static const exportOpened = 'noteC3ExportOpened';
  static const exportEmpty = 'noteC3ExportEmpty';
  static const exportFailed = 'noteC3ExportFailed';
  static const exportNotebookDone = 'noteC3ExportNotebookDone';

  // ---- 导入 ----
  static const import = 'noteC3Import';
  static const importTitle = 'noteC3ImportTitle';
  static const importEnex = 'noteC3ImportEnex';
  static const importEnexHint = 'noteC3ImportEnexHint';
  static const importNotebook = 'noteC3ImportNotebook';
  static const importNotebookHint = 'noteC3ImportNotebookHint';
  static const importEvernote = 'noteC3ImportEvernote';
  static const importEvernoteHint = 'noteC3ImportEvernoteHint';
  static const importing = 'noteC3Importing';
  static const importProgress = 'noteC3ImportProgress';
  static const importApplying = 'noteC3ImportApplying';
  static const importDone = 'noteC3ImportDone';
  static const importFailed = 'noteC3ImportFailed';
  static const importCancelled = 'noteC3ImportCancelled';
  static const importStop = 'noteC3ImportStop';
  static const importOverwriteHint = 'noteC3ImportOverwriteHint';
  static const importFileMissing = 'noteC3ImportFileMissing';

  // ---- 版本历史 ----
  static const versionTitle = 'noteC3VersionTitle';
  static const versionLabel = 'noteC3VersionLabel';
  static const versionEmpty = 'noteC3VersionEmpty';
  static const versionRestore = 'noteC3VersionRestore';
  static const versionRestoreConfirm = 'noteC3VersionRestoreConfirm';
  static const versionRestoreBody = 'noteC3VersionRestoreBody';
  static const versionRestored = 'noteC3VersionRestored';
  static const versionRestoreFailed = 'noteC3VersionRestoreFailed';
  static const versionCopyToNew = 'noteC3VersionCopyToNew';

  // ---- 网页剪藏 ----
  static const clip = 'noteC3Clip';
  static const clipTitle = 'noteC3ClipTitle';
  static const clipUrl = 'noteC3ClipUrl';
  static const clipName = 'noteC3ClipName';
  static const clipNotebook = 'noteC3ClipNotebook';
  static const clipHint = 'noteC3ClipHint';
  static const clipInvalidUrl = 'noteC3ClipInvalidUrl';
  static const clipSaved = 'noteC3ClipSaved';
  static const clipModeSimple = 'noteC3ClipModeSimple';
  static const clipModeFull = 'noteC3ClipModeFull';

  // ---- Evernote 向导（批次 A：夸大修正）----
  static const importEvernoteBrowserFailed = 'noteC3ImportEvernoteBrowserFailed';
  static const importEvernoteMerge = 'noteC3ImportEvernoteMerge';
  static const importEvernoteMergeHint = 'noteC3ImportEvernoteMergeHint';
  static const importEvernoteLock = 'noteC3ImportEvernoteLock';

  // ---- 编辑器补齐（批次 A：格式能力）----
  static const editorFormatBlock = 'noteAEditorFormatBlock';
  static const editorContent = 'noteAEditorContent';
  static const editorFontSize = 'noteAEditorFontSize';
  static const editorNoteLink = 'noteAEditorNoteLink';
  static const editorNoteLinkTitle = 'noteAEditorNoteLinkTitle';
  static const editorNoteLinkEmpty = 'noteAEditorNoteLinkEmpty';
  static const editorHorizontalRule = 'noteAEditorHorizontalRule';
  static const editorFileAttachment = 'noteAEditorFileAttachment';
  static const editorFilePickFailed = 'noteAEditorFilePickFailed';
  static const editorAttachments = 'noteAEditorAttachments';
  static const editorAttachmentDelete = 'noteAEditorAttachmentDelete';
  static const editorAttachmentDeleteConfirm =
      'noteAEditorAttachmentDeleteConfirm';
  static const editorAttachmentDeleteFailed =
      'noteAEditorAttachmentDeleteFailed';
  static const editorAttachmentDownload = 'noteAEditorAttachmentDownload';
  static const editorAttachmentDownloadFailed =
      'noteAEditorAttachmentDownloadFailed';
  static const editorAttachmentEmpty = 'noteAEditorAttachmentEmpty';

  // ---- 可用性 / 权限 ----
  static const noPermission = 'noteC3NoPermission';
  static const noPermissionHint = 'noteC3NoPermissionHint';
  static const sessionHint = 'noteC3SessionHint';
  static const notConnected = 'noteC3NotConnected';
  static const actionFailed = 'noteC3ActionFailed';

  /// 错误文案后面的「（错误码 N）」—— 只有括号与错误码本身
  static const errorCodeSuffix = 'noteC3ErrorCodeSuffix';

  /// 「{message}：{error}」（冒号随语言变，不能用全角硬编码）
  static const messageWithError = 'noteC3MessageWithError';
}
