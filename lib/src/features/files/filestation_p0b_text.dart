// File Station P0-b（下载续传 / 回收站冲突探测 / 高级搜索 / 加密压缩解压）新增
// 界面文案：**key + 中文原文**。
//
// 约定与 `filestation_p0a_text.dart` 一致：`.arb` 与 `lib/l10n/gen/**` 在本批次
// **禁碰**，所以新文案一律 `key + 中文原文`，走 `dataText`
// （`lib/src/core/i18n/data_text.dart`）。ARB 里补上同名 key 后，
// `setCurrentText` 注入的翻译表会自动把中文原文换成当前语言译文；
// 没补上时回落中文原文。
//
// 现有 key 清单（交给父 agent 并入 ARB，见
// `docs/filestation-p0b-implementation.md` §7）：
//   * `fsP0bDownloadPause`      —— 下载暂停
//   * `fsP0bDownloadResume`     —— 下载继续
//   * `fsP0bDownloadPausedTip`  —— 暂停说明：已下载部分保留，可继续
//   * `fsP0bDownloadResumed`    —— 续传提示（占位符 `{size}`）
//   * `fsP0bDownloadRestarted`  —— 服务端不支持 Range，已整份重下
//   * `fsP0bDownloadIncomplete` —— 收完字节数与总长不符
//   * `fsP0bRestoreConflictTitle`—— 还原冲突面板标题
//   * `fsP0bRestoreConflictBody` —— 还原冲突说明（占位符 `{count}`）
//   * `fsP0bRestoreOverwrite`   —— 还原冲突：覆盖
//   * `fsP0bRestoreSkip`        —— 还原冲突：跳过
//   * `fsP0bCompressPasswordEnable` —— 压缩：启用密码
//   * `fsP0bCompressPasswordLabel`  —— 压缩：密码输入框
//   * `fsP0bPasswordConfirmLabel`   —— 压缩：确认密码
//   * `fsP0bPasswordMismatch`       —— 两次密码不一致
//   * `fsP0bPasswordEmpty`          —— 密码为空
//   * `fsP0bExtractPasswordLabel`   —— 解压：密码输入框
//   * `fsP0bExtractPasswordHint`    —— 解压：密码留空说明
//   * `fsP0bSearchFilter`       —— 搜索：筛选入口
//   * `fsP0bSearchFilterActive` —— 搜索：已启用筛选
//   * `fsP0bSearchType`         —— 搜索：类型
//   * `fsP0bSearchTypeAny`      —— 搜索类型：任意
//   * `fsP0bSearchTypeFolder`   —— 搜索类型：文件夹
//   * `fsP0bSearchTypeFile`     —— 搜索类型：任意文件
//   * `fsP0bSearchTypeDocuments`—— 搜索类型：文档
//   * `fsP0bSearchTypeVideos`   —— 搜索类型：视频
//   * `fsP0bSearchTypePictures` —— 搜索类型：图片
//   * `fsP0bSearchTypeAudio`    —— 搜索类型：音频
//   * `fsP0bSearchTypeExtension`—— 搜索类型：自定义扩展名
//   * `fsP0bSearchExtensionHint`—— 自定义扩展名提示
//   * `fsP0bSearchSize`         —— 搜索：大小（MB）
//   * `fsP0bSearchSizeFrom`     —— 搜索：最小
//   * `fsP0bSearchSizeTo`       —— 搜索：最大
//   * `fsP0bSearchSizeInvalid`  —— 最小大于最大
//   * `fsP0bSearchDate`         —— 搜索：修改时间
//   * `fsP0bSearchDateFrom`     —— 搜索：起始日期
//   * `fsP0bSearchDateTo`       —— 搜索：结束日期
//   * `fsP0bSearchDateInvalid`  —— 起始晚于结束
//   * `fsP0bSearchOwner`        —— 搜索：所有者
//   * `fsP0bSearchOwnerHint`    —— 所有者提示
//   * `fsP0bSearchApply`        —— 应用筛选
//   * `fsP0bSearchClear`        —— 清除筛选
import '../../core/i18n/data_text.dart';

/// 取 P0-b 新文案的译文；[zh] 是中文原文（回落值）。
String fsP0b(String key, String zh) => dataText(key, zh);

/// 带占位符的文案填充助手（`{size}` / `{count}`）。
String fsP0bFill(String key, String zh, Map<String, String> values) {
  var out = fsP0b(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批次新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）
abstract final class FsP0bTextKeys {
  // 下载断点续传
  static const downloadPause = 'fsP0bDownloadPause';
  static const downloadResume = 'fsP0bDownloadResume';
  static const downloadPausedTip = 'fsP0bDownloadPausedTip';
  static const downloadResumed = 'fsP0bDownloadResumed';
  static const downloadRestarted = 'fsP0bDownloadRestarted';
  static const downloadIncomplete = 'fsP0bDownloadIncomplete';

  // 回收站还原冲突
  static const restoreConflictTitle = 'fsP0bRestoreConflictTitle';
  static const restoreConflictBody = 'fsP0bRestoreConflictBody';
  static const restoreOverwrite = 'fsP0bRestoreOverwrite';
  static const restoreSkip = 'fsP0bRestoreSkip';

  // 加密压缩 / 解压
  static const compressPasswordEnable = 'fsP0bCompressPasswordEnable';
  static const compressPasswordLabel = 'fsP0bCompressPasswordLabel';
  static const passwordConfirmLabel = 'fsP0bPasswordConfirmLabel';
  static const passwordMismatch = 'fsP0bPasswordMismatch';
  static const passwordEmpty = 'fsP0bPasswordEmpty';
  static const extractPasswordLabel = 'fsP0bExtractPasswordLabel';
  static const extractPasswordHint = 'fsP0bExtractPasswordHint';

  // 高级搜索
  static const searchFilter = 'fsP0bSearchFilter';
  static const searchFilterActive = 'fsP0bSearchFilterActive';
  static const searchType = 'fsP0bSearchType';
  static const searchTypeAny = 'fsP0bSearchTypeAny';
  static const searchTypeFolder = 'fsP0bSearchTypeFolder';
  static const searchTypeFile = 'fsP0bSearchTypeFile';
  static const searchTypeDocuments = 'fsP0bSearchTypeDocuments';
  static const searchTypeVideos = 'fsP0bSearchTypeVideos';
  static const searchTypePictures = 'fsP0bSearchTypePictures';
  static const searchTypeAudio = 'fsP0bSearchTypeAudio';
  static const searchTypeExtension = 'fsP0bSearchTypeExtension';
  static const searchExtensionHint = 'fsP0bSearchExtensionHint';
  static const searchSize = 'fsP0bSearchSize';
  static const searchSizeFrom = 'fsP0bSearchSizeFrom';
  static const searchSizeTo = 'fsP0bSearchSizeTo';
  static const searchSizeInvalid = 'fsP0bSearchSizeInvalid';
  static const searchDate = 'fsP0bSearchDate';
  static const searchDateFrom = 'fsP0bSearchDateFrom';
  static const searchDateTo = 'fsP0bSearchDateTo';
  static const searchDateInvalid = 'fsP0bSearchDateInvalid';
  static const searchOwner = 'fsP0bSearchOwner';
  static const searchOwnerHint = 'fsP0bSearchOwnerHint';
  static const searchApply = 'fsP0bSearchApply';
  static const searchClear = 'fsP0bSearchClear';
}
