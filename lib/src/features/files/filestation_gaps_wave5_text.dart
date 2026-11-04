// 文件模块 wave5（`SYNO.FileStation.ThumbInfo` 照片元数据）新增界面文案：
// **key + 中文原文**。
//
// 约定与 `filestation_gaps_wave1..4_text.dart` 一致：`.arb` 与 `lib/l10n/gen/**`
// 在本批次**禁碰**（ARB 归编排器），所以新文案一律 `key + 中文原文`，走
// `dataText`（`lib/src/core/i18n/data_text.dart`）。ARB 里补上同名 key 后，
// 注入的翻译表会自动把中文原文换成当前语言译文；没补上时回落中文原文。
//
// ## 中文原文出处
//   * 「EXIF」/「IPTC」/「XMP」是**标准名**（国际通用缩写），三种语言下都不译；
//   * 字段标签（相机型号/拍摄时间/光圈/ISO/镜头/曝光时间/焦距/GPS）逐条对照
//     Synology Photos 与 File Station 官方 Web 语言包里的通用词条语义直译
//     —— 真机只拿到了**空态**（见 `FileStationApi.thumbInfo` 注释），
//     **非空回包没取证**，所以这里**只**为 Exiv2 标准键名准备标签，
//     认不出的键一律**原样显示原始键名**（不猜中文、不吞信息）。
//
// ⚠️ 本文件的 key 里**没有**占位符（`dataText` 不做参数替换）。
import '../../core/i18n/data_text.dart';

/// 取本批新文案的译文；[zh] 是中文原文（回落值）。
String fsGap5(String key, String zh) => dataText(key, zh);

/// 本批次新增的 ARB key（下一步照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class FsGap5TextKeys {
  /// 面板与空态
  static const thumbInfoSection = 'fsGap5ThumbInfoSection';
  static const thumbInfoEmpty = 'fsGap5ThumbInfoEmpty';
  static const thumbInfoLoading = 'fsGap5ThumbInfoLoading';

  /// 三个块的标准名（三种语言都不译）
  static const blockExif = 'fsGap5ThumbInfoExif';
  static const blockIptc = 'fsGap5ThumbInfoIptc';
  static const blockXmp = 'fsGap5ThumbInfoXmp';

  /// 认得的标准键的标签（认不出 → 原样显示键名）
  static const labelCamera = 'fsGap5ThumbInfoCamera';
  static const labelLens = 'fsGap5ThumbInfoLens';
  static const labelTakenAt = 'fsGap5ThumbInfoTakenAt';
  static const labelAperture = 'fsGap5ThumbInfoAperture';
  static const labelIso = 'fsGap5ThumbInfoIso';
  static const labelExposure = 'fsGap5ThumbInfoExposure';
  static const labelFocalLength = 'fsGap5ThumbInfoFocalLength';
  static const labelGps = 'fsGap5ThumbInfoGps';
  static const labelSoftware = 'fsGap5ThumbInfoSoftware';
  static const labelMake = 'fsGap5ThumbInfoMake';
  static const labelOrientation = 'fsGap5ThumbInfoOrientation';
}
