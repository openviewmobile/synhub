// 相册 AI 美化（图生图）批次②新增界面文案：**key + 中文原文**。
//
// 与 `photo_p0_text.dart` / `photo_p1_text.dart` 同一套约定：`.arb` 与
// `lib/l10n/gen/**` 在本批次**禁碰**，新文案走数据层的 `dataText.dart`
// （装了翻译器出译文，否则回落中文）。每条的 key 就是要并入 `.arb` 的 key，
// 清单见 `docs/photo-ai-image-edit-batch2.md` §⑨（**只列本批新增**）。
//
// 复用原则：批次①的 51 个 key（`imageEdit*` / `imgEditErr*`）与既有的
// `actionCancel` / `actionSaveFailed` / `photoNotConnected` 等**一律复用**，
// 本文件只放"确实没有的"那几条。
import '../../core/i18n/data_text.dart';

/// 取批次②新文案（key 见 [PhotoAiEditTextKeys]）
String photoAiEdit(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充（`{host}` / `{count}` / `{error}` …）
String photoAiEditFill(String key, String zh, Map<String, String> values) {
  var out = photoAiEdit(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class PhotoAiEditTextKeys {
  // 入口 / 并发
  static const entryTitle = 'imageEditEntryTitle';
  static const entryTooltip = 'imageEditEntryTooltip';
  static const busyTooltip = 'imageEditBusyTooltip';
  static const singleOnly = 'imageEditSingleOnly';

  // 每次发送前的固定横幅（不可折叠，**逐字**写出发送对象与主机名）
  static const sendBanner = 'imageEditSendBanner';
  static const sendBannerLocalNote = 'imageEditSendBannerLocalNote';
  static const sendSummary = 'imageEditSendSummary';
  static const sendSummaryBytes = 'imageEditSendSummaryBytes';

  // 一次性同意
  static const consentTitle = 'imageEditConsentTitle';
  static const consentBody = 'imageEditConsentBody';
  static const consentAgree = 'imageEditConsentAgree';
  static const consentRefuse = 'imageEditConsentRefuse';

  // 提示词面板
  static const panelTitle = 'imageEditPanelTitle';
  static const presetLabel = 'imageEditPresetLabel';
  static const promptLabel = 'imageEditPromptLabel';
  static const promptHint = 'imageEditPromptHint';
  static const promptCounter = 'imageEditPromptCounter';
  static const strengthLabel = 'imageEditStrengthLabel';
  static const variantsLabel = 'imageEditVariantsLabel';
  static const variantsCostUnknown = 'imageEditVariantsCostUnknown';
  static const variantsCostLocal = 'imageEditVariantsCostLocal';
  static const variantsCostKnown = 'imageEditVariantsCostKnown';
  static const quotaLine = 'imageEditQuotaLine';
  static const start = 'imageEditStart';
  static const allowMobile = 'imageEditAllowMobile';

  // 进行中
  static const running = 'imageEditRunning';
  static const runningElapsed = 'imageEditRunningElapsed';
  static const stop = 'imageEditStop';

  // 结果 / 预览 / 保存
  static const resultTitle = 'imageEditResultTitle';
  static const variantOf = 'imageEditVariantOf';
  static const holdToCompare = 'imageEditHoldToCompare';
  static const saveAsNewPhoto = 'imageEditSaveAsNewPhoto';
  static const saveToDevice = 'imageEditSaveToDevice';
  static const savedToTimeline = 'imageEditSavedToTimeline';
  static const savedToDeviceOpened = 'imageEditSavedToDeviceOpened';
  static const saveFailed = 'imageEditSaveFailed';

  // 设置页卡片
  // 第 255 轮：设置**独立成页**（用户要求拆开，不再混在大语言模型页）
  static const settingsEntry = 'imageEditSettingsEntry';
  static const settingsEntryOff = 'imageEditSettingsEntryOff';
  static const settingsEntryOn = 'imageEditSettingsEntryOn';
  static const settingsPageIntro = 'imageEditSettingsPageIntro';
  static const settingsSeparateNote = 'imageEditSettingsSeparateNote';

  static const settingsTitle = 'imageEditSettingsTitle';
  static const settingsEnable = 'imageEditSettingsEnable';
  static const settingsEnableHint = 'imageEditSettingsEnableHint';
  static const settingsBackend = 'imageEditSettingsBackend';
  static const settingsBaseUrl = 'imageEditSettingsBaseUrl';
  static const settingsModel = 'imageEditSettingsModel';
  static const settingsKey = 'imageEditSettingsKey';
  static const settingsDailyCap = 'imageEditSettingsDailyCap';
  static const settingsCapOff = 'imageEditSettingsCapOff';
  static const settingsCapValue = 'imageEditSettingsCapValue';
  static const settingsWifiOnly = 'imageEditSettingsWifiOnly';
  static const settingsConsentDone = 'imageEditSettingsConsentDone';
  static const settingsConsentMissing = 'imageEditSettingsConsentMissing';
  static const settingsRevoke = 'imageEditSettingsRevoke';
  static const settingsRevoked = 'imageEditSettingsRevoked';
  static const settingsLoadFailed = 'imageEditSettingsLoadFailed';
}
