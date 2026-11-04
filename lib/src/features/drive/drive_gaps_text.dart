// Drive「wave1 剩余可直接做项」新增界面文案：**key + 中文原文**。
//
// 为什么不用 `context.t`：本批**禁碰 `.arb` 与 `lib/l10n/gen/**`**，所以新文案
// 沿用仓库既有的 `dataText` 约定（key + 中文原文，语言切换时由
// `setCurrentText` 注入译文，取不到就回落中文）。与 `drive_p0_text.dart` /
// `drive_c1_text.dart` 同构。
//
// 每一条的 key 就是要追加的 ARB key（清单见 `docs/drive-gaps-wave1.md` 的
// "需并入的 ARB key" 小节）。**占位符只出现在带 `Fill` 的条目**，且都通过
// [driveGapFill] 填充，绝不把 `{...}` 当字面量送进 UI。
import '../../core/i18n/data_text.dart';

/// 取 wave1 新文案（key 见 [DriveGapTextKeys]）
String driveGap(String key, String zh) => dataText(key, zh);

/// 带 `{name}` / `{error}` 等占位符的文案填充
String driveGapFill(String key, String zh, Map<String, String> values) {
  var out = driveGap(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class DriveGapTextKeys {
  // ---- D19 排序
  static const sortTitle = 'driveGapSortTitle';
  static const sortDefault = 'driveGapSortDefault';
  static const sortName = 'driveGapSortName';
  static const sortSize = 'driveGapSortSize';
  static const sortModified = 'driveGapSortModified';
  static const sortCreated = 'driveGapSortCreated';
  static const sortAscending = 'driveGapSortAscending';
  static const sortDescending = 'driveGapSortDescending';

  // ---- D18 视图切换
  static const viewList = 'driveGapViewList';
  static const viewGrid = 'driveGapViewGrid';

  // ---- D51 搜索历史
  static const searchHistoryTitle = 'driveGapSearchHistoryTitle';
  static const searchHistoryClear = 'driveGapSearchHistoryClear';

  // ---- D43 请求文件：上传者目录命名策略
  static const requestIdentifierTitle = 'driveGapRequestIdentifierTitle';
  static const requestIdentifierCreateFolder =
      'driveGapRequestIdentifierCreateFolder';
  static const requestIdentifierAddPrefix =
      'driveGapRequestIdentifierAddPrefix';

  // ---- D60 / D59 文本文件新建 / 编辑
  static const newTextFile = 'driveGapNewTextFile';
  static const newTextFileHint = 'driveGapNewTextFileHint';
  // D56（第 64 轮）：新建空白 Office 节点
  static const newOfficeDoc = 'driveGapNewOfficeDoc';
  static const newOfficeDocHint = 'driveGapNewOfficeDocHint';
  static const newOfficeSheet = 'driveGapNewOfficeSheet';
  static const newOfficeSheetHint = 'driveGapNewOfficeSheetHint';
  // ★ 第 257 轮：官方 Web 客户端「新建」菜单是三种类型 + 从模板 + 加密新建
  static const newOfficeSlides = 'driveGapNewOfficeSlides';
  static const newOfficeSlidesHint = 'driveGapNewOfficeSlidesHint';
  static const newFromTemplate = 'driveGapNewFromTemplate';
  static const newFromTemplateHint = 'driveGapNewFromTemplateHint';
  // ★ 第 258 轮：从模板新建前解析父目录失败时的提示（不硬发坏 parent_id）
  static const templateParentUnresolved = 'driveGapTemplateParentUnresolved';
  static const newEncrypted = 'driveGapNewEncrypted';
  static const newEncryptedHint = 'driveGapNewEncryptedHint';
  static const encryptedDoc = 'driveGapEncryptedDoc';
  static const encryptedSheet = 'driveGapEncryptedSheet';
  static const encryptedSlides = 'driveGapEncryptedSlides';
  static const encryptedTemplate = 'driveGapEncryptedTemplate';
  static const encryptedPasswordTitle = 'driveGapEncryptedPasswordTitle';
  static const encryptedPassword = 'driveGapEncryptedPassword';
  static const encryptedPasswordConfirm = 'driveGapEncryptedPasswordConfirm';
  static const encryptedPasswordEmpty = 'driveGapEncryptedPasswordEmpty';
  static const encryptedPasswordMismatch = 'driveGapEncryptedPasswordMismatch';
  static const templateLibraryEncryptedTitle =
      'driveGapTemplateLibraryEncryptedTitle';
  static const officeNodeCreated = 'driveGapOfficeNodeCreated';
  static const officeNodeNoFolderId = 'driveGapOfficeNodeNoFolderId';
  static const textEditorTitle = 'driveGapTextEditorTitle';
  static const textEditorLoadFailed = 'driveGapTextEditorLoadFailed';
  static const textEditorSave = 'driveGapTextEditorSave';
  static const textEditorSaved = 'driveGapTextEditorSaved';
  static const textEditorSaveFailed = 'driveGapTextEditorSaveFailed';
  static const textEditorNotEditable = 'driveGapTextEditorNotEditable';
  static const textEditorReadOnly = 'driveGapTextEditorReadOnly';
  // ★ DA209（r627）：空草稿必须有一句“从哪开始”的提示 —— 原来 hintText: ''，
  // 新建文本文件打开后是一块和页面同色的空白（边界 1.40:1、无光标、无提示）。
  static const textEditorHint = 'driveGapTextEditorHint';
  static const editText = 'driveGapEditText';
  static const textCreated = 'driveGapTextCreated';

  // ---- D81 首次运行范围说明
  static const scopeTitle = 'driveGapScopeTitle';
  static const scopeIntro = 'driveGapScopeIntro';
  static const scopeMyDriveTitle = 'driveGapScopeMyDriveTitle';
  static const scopeMyDriveBody = 'driveGapScopeMyDriveBody';
  static const scopeSharedTitle = 'driveGapScopeSharedTitle';
  static const scopeSharedBody = 'driveGapScopeSharedBody';
  static const scopeTeamTitle = 'driveGapScopeTeamTitle';
  static const scopeTeamBody = 'driveGapScopeTeamBody';
  static const scopeDismiss = 'driveGapScopeDismiss';
}
